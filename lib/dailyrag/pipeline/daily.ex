defmodule DailyRag.Pipeline.Daily do
  require Logger

  alias DailyRag.{Checkpoint, Decay, Dedup, Scraper, Segmenter, Slack, Util}
  alias DailyRag.Sheets.{Client, Schema, TabInit}

  @spec run(map()) :: :ok | {:error, term()}
  def run(opts) do
    started_at = System.monotonic_time(:second)
    sheet_id = Application.fetch_env!(:dailyrag, :sheet_id)
    dry_run = Map.get(opts, :dry_run, false)
    verbose = Map.get(opts, :verbose, false)

    Util.ensure_data_dir!()
    TabInit.ensure_tabs!(sheet_id)
    retry_pending_writes(sheet_id, dry_run, verbose)

    with {:ok, brands} <- load_brands(sheet_id, opts),
         {brands_to_process, stats} <- apply_recovery(brands, opts),
         {final_stats, final_dedup, final_decay} <-
           process_brands(sheet_id, brands_to_process, stats, Dedup.load(), Decay.load(), opts),
         {:ok, upgrades} <- apply_confidence_upgrades(sheet_id, dry_run, verbose),
         :ok <- append_daily_report(sheet_id, final_stats, upgrades, started_at, dry_run),
         :ok <- maybe_post_summary(final_stats, upgrades, started_at, dry_run) do
      unless dry_run do
        Dedup.save!(final_dedup)
        Decay.save!(final_decay)
        Checkpoint.clear!()
      end

      :ok
    end
  end

  defp load_brands(sheet_id, opts) do
    with {:ok, rows} <- Client.read_range(sheet_id, "Brand_Config!A:F") do
      all_active =
        rows
        |> Enum.drop(1)
        |> Enum.map(&Schema.parse_brand_config_row/1)
        |> Enum.filter(&(&1.status == "active"))

      brands = select_brands(all_active, opts)
      {:ok, brands}
    end
  end

  # --brand flag: run specific brand
  defp select_brands(brands, %{brand: name}) when is_binary(name) and name != "" do
    Enum.filter(brands, &(&1.brand_name == name))
  end

  # No flag: rotate — one brand per day
  defp select_brands(brands, _opts) when length(brands) > 0 do
    rotation = DailyRag.Rotation.load()
    {brand, new_rotation} = DailyRag.Rotation.next_brand(brands, rotation)
    DailyRag.Rotation.save!(new_rotation)
    Logger.info("Brand rotation: running #{brand.brand_name} (index #{new_rotation["index"]} of #{length(brands)})")
    [brand]
  end

  defp select_brands([], _opts), do: []

  defp apply_recovery(brands, %{recover: true}) do
    case Checkpoint.load() do
      %{"current_brand_index" => index, "stats" => stats} ->
        {Enum.drop(brands, index), normalize_stats(stats)}

      _ ->
        {brands, fresh_stats()}
    end
  end

  defp apply_recovery(brands, _opts), do: {brands, fresh_stats()}

  defp process_brands(sheet_id, brands, stats, dedup_index, decay_cache, opts) do
    Enum.with_index(brands)
    |> Enum.reduce({stats, dedup_index, decay_cache}, fn {brand, index},
                                                         {acc_stats, acc_dedup, acc_decay} ->
      log_verbose(opts, "Processing #{brand.brand_name}...")

      case process_brand(sheet_id, brand, acc_dedup, acc_decay, opts) do
        {:ok, brand_stats, next_dedup, next_decay} ->
          merged_stats = merge_stats(acc_stats, brand_stats)

          unless Map.get(opts, :dry_run, false) do
            Checkpoint.save!(%{
              "version" => 1,
              "started_at" => Util.utc_now(),
              "completed_brands" => Enum.take(brands, index + 1) |> Enum.map(& &1.brand_name),
              "current_brand_index" => index + 1,
              "stats" => merged_stats
            })
          end

          {merged_stats, next_dedup, next_decay}

        {:error, reason} ->
          Logger.warning("Brand #{brand.brand_name} failed: #{inspect(reason)}")
          {Map.update!(acc_stats, :errors, &(&1 + 1)), acc_dedup, acc_decay}
      end
    end)
  end

  defp process_brand(sheet_id, brand, dedup_index, decay_cache, opts) do
    dry_run = Map.get(opts, :dry_run, false)

    with {:ok, ads} <- Scraper.scrape_ads(brand.meta_library_url) do
      ad_ids = Enum.map(ads, &to_string(&1["ad_id"]))
      new_ads = Dedup.filter_new(dedup_index, ads)
      {disappeared_ids, _new_ids} = Decay.diff(decay_cache, brand.brand_name, ad_ids)
      maybe_post_canary(decay_cache, brand.brand_name, ad_ids, dry_run)

      segments =
        case Segmenter.segment_ads(brand.brand_name, brand.vertical, new_ads) do
          {:ok, parsed_segments} ->
            enrich_segments(parsed_segments, brand)

          {:error, reason} ->
            Logger.warning("Segmentation failed for #{brand.brand_name}: #{inspect(reason)}")
            []
        end

      rows = build_rows(sheet_id, brand.vertical, segments)

      if dry_run do
        log_verbose(
          %{verbose: true},
          "Rows for #{brand.brand_name}: #{inspect(rows, pretty: true, limit: :infinity)}"
        )

        {:ok,
         %{
           brands_processed: 1,
           new_ads: length(new_ads),
           decayed: length(disappeared_ids),
           errors: 0
         }, dedup_index, decay_cache}
      else
        :ok = maybe_append_rows(sheet_id, brand.vertical, rows)
        :ok = maybe_mark_inactive(sheet_id, brand.vertical, disappeared_ids)

        updated_dedup =
          Dedup.add(dedup_index, brand.brand_name, Enum.map(new_ads, &to_string(&1["ad_id"])))

        updated_decay = Decay.update(decay_cache, brand.brand_name, ad_ids)

        {:ok,
         %{
           brands_processed: 1,
           new_ads: length(new_ads),
           decayed: length(disappeared_ids),
           errors: 0
         }, updated_dedup, updated_decay}
      end
    end
  end

  defp enrich_segments(segments, brand) do
    Enum.map(segments, fn segment ->
      %{
        "segment_type" => segment["segment_type"],
        "vertical" => brand.vertical,
        "format" => segment["format"],
        "principle" => segment["principle"],
        "transcript" => segment["transcript"],
        "why_it_works" => segment["why_it_works"],
        "source_category" => "brand",
        "confidence" => "emerging",
        "brand_source_detail" => brand.brand_name,
        "notes" => "",
        "date_discovered" => Util.today(),
        "last_seen" => Util.today(),
        "status" => "active",
        "ad_id" => segment["source_ad_id"]
      }
    end)
  end

  defp build_rows(sheet_id, vertical, segments) do
    tab = Schema.tab_for_vertical(vertical)
    start_entry = next_entry_number(sheet_id, tab)

    segments
    |> Enum.with_index(start_entry)
    |> Enum.map(fn {segment, entry_number} -> Schema.build_daily_row(segment, entry_number) end)
  end

  defp next_entry_number(sheet_id, tab) do
    case Client.read_range(sheet_id, "#{tab}!A:A") do
      {:ok, rows} -> max(length(rows), 1)
      {:error, _} -> 1
    end
  end

  defp maybe_append_rows(_sheet_id, _vertical, []), do: :ok

  defp maybe_append_rows(sheet_id, vertical, rows) do
    tab = Schema.tab_for_vertical(vertical)

    case Client.append_rows(sheet_id, "#{tab}!A:O", rows) do
      :ok ->
        :ok

      {:error, reason} ->
        Checkpoint.record_failed_write!(%{
          "type" => "append",
          "tab" => tab,
          "range" => "#{tab}!A:O",
          "rows" => rows,
          "error" => inspect(reason)
        })
    end
  end

  defp maybe_mark_inactive(_sheet_id, _vertical, []), do: :ok

  defp maybe_mark_inactive(sheet_id, vertical, disappeared_ids) do
    tab = Schema.tab_for_vertical(vertical)

    with {:ok, rows} <- Client.read_range(sheet_id, "#{tab}!A:O") do
      updates =
        rows
        |> Enum.drop(1)
        |> Enum.with_index(2)
        |> Enum.flat_map(fn {row, row_index} ->
          if Enum.at(row, 14, "") in disappeared_ids and Enum.at(row, 13, "") == "active" do
            [
              %{range: "#{tab}!N#{row_index}", values: [["inactive"]]},
              %{range: "#{tab}!M#{row_index}", values: [[Util.today()]]}
            ]
          else
            []
          end
        end)

      if updates == [], do: :ok, else: Client.batch_update(sheet_id, updates)
    end
  end

  defp apply_confidence_upgrades(sheet_id, dry_run, verbose) do
    rows =
      ["Supplements_Daily", "HomeServices_Daily"]
      |> Enum.flat_map(fn tab ->
        case Client.read_range(sheet_id, "#{tab}!A:O") do
          {:ok, tab_rows} ->
            tab_rows
            |> Enum.drop(1)
            |> Enum.with_index(2)
            |> Enum.map(fn {row, row_index} ->
              %{
                "tab" => tab,
                "row_index" => row_index,
                "confidence" => Enum.at(row, 8, ""),
                "date_discovered" => Enum.at(row, 11, ""),
                "status" => Enum.at(row, 13, "")
              }
            end)

          {:error, _} ->
            []
        end
      end)

    updates =
      rows
      |> Enum.group_by(& &1["tab"])
      |> Enum.flat_map(fn {tab, tab_rows} ->
        Decay.confidence_upgrades(tab_rows, Date.utc_today())
        |> Enum.map(fn {row_index, new_confidence} ->
          %{range: "#{tab}!I#{row_index}", values: [[new_confidence]]}
        end)
      end)

    log_verbose(%{verbose: verbose}, "Confidence updates: #{inspect(updates)}")

    cond do
      updates == [] ->
        {:ok, 0}

      dry_run ->
        {:ok, length(updates)}

      true ->
        case Client.batch_update(sheet_id, updates) do
          :ok -> {:ok, length(updates)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp append_daily_report(sheet_id, stats, upgrades, started_at, dry_run) do
    duration = System.monotonic_time(:second) - started_at

    row = [
      [
        Util.today(),
        Integer.to_string(stats.brands_processed),
        Integer.to_string(stats.new_ads),
        Integer.to_string(stats.decayed),
        Integer.to_string(upgrades),
        Integer.to_string(stats.errors),
        Integer.to_string(duration),
        ""
      ]
    ]

    if dry_run, do: :ok, else: Client.append_rows(sheet_id, "Daily_Report!A:H", row)
  end

  defp maybe_post_summary(stats, upgrades, started_at, dry_run) do
    duration = System.monotonic_time(:second) - started_at

    text =
      Slack.daily_summary(%{
        date: Util.today(),
        brands_processed: stats.brands_processed,
        new_ads: stats.new_ads,
        decayed: stats.decayed,
        upgrades: upgrades,
        errors: stats.errors,
        duration_s: duration
      })

    if dry_run, do: :ok, else: Slack.post(text)
  end

  defp retry_pending_writes(_sheet_id, true, _verbose), do: :ok

  defp retry_pending_writes(sheet_id, false, verbose) do
    pending = Checkpoint.pending_writes()

    if pending != [] do
      log_verbose(%{verbose: verbose}, "Retrying #{length(pending)} pending writes")

      Enum.each(pending, fn write ->
        case write["type"] do
          "append" -> Client.append_rows(sheet_id, write["range"], write["rows"])
          _ -> :ok
        end
      end)

      Checkpoint.clear_pending_writes!()
    end

    :ok
  end

  defp maybe_post_canary(cache, brand_name, ad_ids, false) do
    if Decay.canary_warning?(cache, brand_name, ad_ids) do
      yesterday_count = cache |> Map.get("brands", %{}) |> Map.get(brand_name, []) |> length()
      Slack.post(Slack.canary_warning(brand_name, yesterday_count))
    end
  end

  defp maybe_post_canary(_cache, _brand_name, _ad_ids, true), do: :ok

  defp log_verbose(%{verbose: true}, message), do: Logger.info(message)
  defp log_verbose(_, _message), do: :ok

  defp fresh_stats, do: %{brands_processed: 0, new_ads: 0, decayed: 0, errors: 0}

  defp normalize_stats(stats) do
    %{
      brands_processed: stats["brands_processed"] || 0,
      new_ads: stats["new_ads"] || 0,
      decayed: stats["decayed"] || 0,
      errors: stats["errors"] || 0
    }
  end

  defp merge_stats(left, right), do: Map.merge(left, right, fn _key, a, b -> a + b end)
end
