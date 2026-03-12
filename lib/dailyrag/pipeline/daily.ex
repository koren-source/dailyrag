defmodule DailyRag.Pipeline.Daily do
  require Logger

  alias DailyRag.{Decay, Dedup, Rotation, Scraper, SegmentationBacklog, Segmenter, Slack, Util}
  alias DailyRag.Sheets.{Client, Schema, TabInit}

  @spec run(map()) :: :ok | {:error, term()}
  def run(opts) do
    started_at = System.monotonic_time(:second)
    sheet_id = Application.fetch_env!(:dailyrag, :sheet_id)
    dry_run = Map.get(opts, :dry_run, false)
    verbose = Map.get(opts, :verbose, false)

    Util.ensure_data_dir!()
    TabInit.ensure_tabs!(sheet_id)
    # TODO: implement --recover with checkpoint logic

    with {:ok, active_brands} <- load_active_brands(sheet_id),
         :ok <- validate_brand_override(active_brands, opts),
         {brands_to_segment, rotation_state, rotation_log} <- select_segmentation_brands(active_brands, opts),
         {:ok, scrape_result, dedup_index, decay_cache, backlog} <-
           scrape_all_brands(active_brands, Dedup.load(), Decay.load(), SegmentationBacklog.load(), opts),
         {:ok, segment_result, backlog} <-
           segment_rotating_brands(sheet_id, brands_to_segment, backlog, opts),
         :ok <- mark_inactive_ads(sheet_id, scrape_result.brand_results, dry_run),
         {:ok, upgrades} <- apply_confidence_upgrades(sheet_id, dry_run, verbose),
         {:ok, stats} <-
           build_run_stats(
             sheet_id,
             active_brands,
             brands_to_segment,
             scrape_result,
             segment_result,
             decay_cache,
             backlog,
             upgrades
           ),
         :ok <- append_daily_report(sheet_id, stats, dry_run),
         :ok <- maybe_post_summary(stats, started_at, dry_run) do
      log_verbose(%{verbose: verbose}, rotation_log)

      unless dry_run do
        Rotation.save!(rotation_state)
        Dedup.save!(dedup_index)
        Decay.save!(decay_cache)
        SegmentationBacklog.save!(backlog)
      end

      :ok
    end
  end

  defp load_active_brands(sheet_id) do
    with {:ok, rows} <- Client.read_range(sheet_id, "Brand_Config!A:F") do
      brands =
        rows
        |> Enum.drop(1)
        |> Enum.map(&Schema.parse_brand_config_row/1)
        |> Enum.filter(&(&1.status == "active"))

      {:ok, brands}
    end
  end

  defp validate_brand_override(brands, %{brand: name}) when is_binary(name) and name != "" do
    if Enum.any?(brands, &(&1.brand_name == name)) do
      :ok
    else
      {:error, {:brand_not_found, name}}
    end
  end

  defp validate_brand_override(_brands, _opts), do: :ok

  defp select_segmentation_brands(brands, %{brand: name}) when is_binary(name) and name != "" do
    selected = Enum.filter(brands, &(&1.brand_name == name))
    {selected, Rotation.load(), "Brand override: segmenting #{name}"}
  end

  defp select_segmentation_brands(brands, _opts) do
    rotation = Rotation.load()
    {selected, next_rotation} = Rotation.next_brands(brands, rotation, 3)

    log_line =
      "Brand rotation: segmenting #{Enum.map_join(selected, ", ", & &1.brand_name)} " <>
        "(next index #{next_rotation["index"]} of #{length(brands)})"

    {selected, next_rotation, log_line}
  end

  defp scrape_all_brands(brands, dedup_index, decay_cache, backlog, opts) do
    result =
      Enum.reduce(brands, fresh_scrape_result(dedup_index, decay_cache, backlog), fn brand, acc ->
        log_verbose(opts, "Scraping #{brand.brand_name}...")

        case scrape_brand(brand, acc.dedup_index, acc.decay_cache, acc.backlog, opts) do
          {:ok, brand_result, next_dedup, next_decay, next_backlog} ->
            %{acc | brand_results: acc.brand_results ++ [brand_result], dedup_index: next_dedup, decay_cache: next_decay, backlog: next_backlog}

          {:error, reason} ->
            error = "#{brand.brand_name}: #{inspect(reason)}"
            Logger.warning("Brand #{brand.brand_name} failed: #{inspect(reason)}")
            %{acc | brand_results: acc.brand_results ++ [failed_brand_result(brand)], errors: acc.errors ++ [error]}
        end
      end)

    {:ok, strip_scrape_state(result), result.dedup_index, result.decay_cache, result.backlog}
  end

  defp scrape_brand(brand, dedup_index, decay_cache, backlog, opts) do
    dry_run = Map.get(opts, :dry_run, false)

    with {:ok, ads} <- Scraper.scrape_ads(brand.meta_library_url) do
      ad_ids = Enum.map(ads, &to_string(&1["ad_id"]))
      new_ads = Dedup.filter_new(dedup_index, ads)
      {disappeared_ids, _new_ids} = Decay.diff(decay_cache, brand.brand_name, ad_ids)
      maybe_post_canary(decay_cache, brand.brand_name, ad_ids, dry_run)

      updated_dedup =
        Dedup.add(dedup_index, brand.brand_name, Enum.map(new_ads, &to_string(&1["ad_id"])))

      updated_decay = Decay.update(decay_cache, brand.brand_name, ad_ids)
      updated_backlog = SegmentationBacklog.enqueue(backlog, brand.brand_name, new_ads)

      {:ok,
       %{
         brand: brand,
         new_ads_count: length(new_ads),
         decayed_ids: disappeared_ids,
         active_count: length(ad_ids),
         error: nil
       }, updated_dedup, updated_decay, updated_backlog}
    end
  end

  defp segment_rotating_brands(sheet_id, brands, backlog, opts) do
    result =
      Enum.reduce(brands, %{total_segmented: 0, errors: [], backlog: backlog}, fn brand, acc ->
        queued = SegmentationBacklog.queued_count(acc.backlog, brand.brand_name)
        log_verbose(opts, "Segmenting #{brand.brand_name} from backlog (#{queued} queued)")

        {ads_to_segment, reduced_backlog} =
          SegmentationBacklog.dequeue(acc.backlog, brand.brand_name, Segmenter.max_ads_per_run())

        case segment_brand(sheet_id, brand, ads_to_segment, reduced_backlog, opts) do
          {:ok, brand_segmented, next_backlog} ->
            %{acc | total_segmented: acc.total_segmented + brand_segmented, backlog: next_backlog}

          {:error, reason, restored_backlog} ->
            error = "#{brand.brand_name}: #{inspect(reason)}"
            Logger.warning("Segmentation failed for #{brand.brand_name}: #{inspect(reason)}")
            %{acc | errors: acc.errors ++ [error], backlog: restored_backlog}
        end
      end)

    {:ok, %{total_segmented: result.total_segmented, errors: result.errors}, result.backlog}
  end

  defp segment_brand(_sheet_id, _brand, [], backlog, _opts), do: {:ok, 0, backlog}

  defp segment_brand(sheet_id, brand, ads_to_segment, backlog, opts) do
    dry_run = Map.get(opts, :dry_run, false)

    if dry_run do
      log_verbose(opts, "[dry-run] #{brand.brand_name}: would segment #{length(ads_to_segment)} ads (Claude skipped in dry-run)")
      {:ok, length(ads_to_segment), backlog}
    else
      with {:ok, parsed_segments} <- Segmenter.segment_ads(brand.brand_name, brand.vertical, ads_to_segment) do
        rows =
          parsed_segments
          |> enrich_segments(brand, ads_to_segment)
          |> build_rows(sheet_id, brand.vertical)

        case maybe_append_rows(sheet_id, brand.vertical, rows) do
          :ok -> {:ok, length(ads_to_segment), backlog}
          {:error, reason} -> {:error, reason, SegmentationBacklog.enqueue(backlog, brand.brand_name, ads_to_segment)}
        end
      else
        {:error, reason} ->
          {:error, reason, SegmentationBacklog.enqueue(backlog, brand.brand_name, ads_to_segment)}
      end
    end
  end

  defp mark_inactive_ads(_sheet_id, _brand_results, true), do: :ok

  defp mark_inactive_ads(sheet_id, brand_results, false) do
    brand_results
    |> Enum.reduce(:ok, fn brand_result, _acc ->
      maybe_mark_inactive(sheet_id, brand_result.brand.vertical, brand_result.decayed_ids)
    end)
  end

  defp enrich_segments(segments, brand, ads) do
    ads_by_id = Map.new(ads, fn ad -> {to_string(ad["ad_id"]), ad} end)

    Enum.map(segments, fn segment ->
      ad = Map.get(ads_by_id, to_string(segment["source_ad_id"]), %{})

      %{
        "segment_type" => segment["segment_type"],
        "vertical" => brand.vertical,
        "format" => segment["format"],
        "principle" => segment["principle"],
        "transcript" => segment["transcript"],
        "why_it_works" => segment["why_it_works"],
        "source_category" => "ad-library",
        "confidence" => initial_confidence(ad["start_date"]),
        "brand_source_detail" => "#{brand.brand_name} / Lib ID #{segment["source_ad_id"]}",
        "notes" => "",
        "date_discovered" => Util.today(),
        "last_seen" => Util.today(),
        "status" => "active",
        "ad_id" => segment["source_ad_id"]
      }
    end)
  end

  defp build_rows(segments, sheet_id, vertical) do
    tab = Schema.tab_for_vertical(vertical)
    start_entry = next_entry_number(sheet_id, tab)

    segments
    |> Enum.with_index(start_entry)
    |> Enum.map(fn {segment, entry_number} -> Schema.build_daily_row(segment, entry_number, vertical) end)
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
    Client.append_rows(sheet_id, "#{tab}!A:O", rows)
  end

  defp maybe_mark_inactive(_sheet_id, _vertical, []), do: :ok

  defp maybe_mark_inactive(sheet_id, vertical, disappeared_ids) do
    tab = Schema.tab_for_vertical(vertical)
    yesterday = Date.utc_today() |> Date.add(-1) |> Date.to_iso8601()

    with {:ok, rows} <- Client.read_range(sheet_id, "#{tab}!A:O") do
      updates =
        rows
        |> Enum.drop(1)
        |> Enum.with_index(2)
        |> Enum.flat_map(fn {row, row_index} ->
          if Enum.at(row, 14, "") in disappeared_ids and Enum.at(row, 13, "") == "active" do
            [
              %{range: "#{tab}!N#{row_index}", values: [["inactive"]]},
              %{range: "#{tab}!M#{row_index}", values: [[yesterday]]}
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

  defp build_run_stats(sheet_id, active_brands, brands_to_segment, scrape_result, segment_result, decay_cache, backlog, upgrades) do
    total_rag_entries =
      case total_rag_entries(sheet_id) do
        {:ok, total} -> total
        {:error, reason} -> return_error(reason)
      end

    queue_counts = SegmentationBacklog.queue_counts(backlog)
    new_breakdown = build_breakdown(scrape_result.brand_results, & &1.new_ads_count)
    decayed_breakdown = build_breakdown(scrape_result.brand_results, &(length(&1.decayed_ids)))

    {:ok,
     %{
       date: Util.today(),
       brands_scraped: length(active_brands),
       brands_segmented: Enum.map(brands_to_segment, & &1.brand_name),
       segmentation_queue: format_segmentation_queue(queue_counts),
       total_new_ads: Enum.sum(Enum.map(scrape_result.brand_results, & &1.new_ads_count)),
       total_segmented: segment_result.total_segmented,
       total_decayed_ads: Enum.sum(Enum.map(scrape_result.brand_results, &(length(&1.decayed_ids)))),
       supplements_new: vertical_total(scrape_result.brand_results, "dtc-supplements", & &1.new_ads_count),
       home_services_new: vertical_total(scrape_result.brand_results, "home-services", & &1.new_ads_count),
       supplements_decayed: vertical_total(scrape_result.brand_results, "dtc-supplements", &(length(&1.decayed_ids))),
       home_services_decayed: vertical_total(scrape_result.brand_results, "home-services", &(length(&1.decayed_ids))),
       brand_breakdown_new: new_breakdown,
       brand_breakdown_decayed: decayed_breakdown,
       total_active_tracked: active_tracked_count(decay_cache),
       total_rag_entries: total_rag_entries,
       confidence_upgrades: upgrades,
       errors: scrape_result.errors ++ segment_result.errors
     }}
  catch
    {:total_rag_entries_error, reason} -> {:error, reason}
  end

  defp append_daily_report(sheet_id, stats, dry_run) do
    row = [
      [
        stats.date,
        Integer.to_string(stats.brands_scraped),
        Enum.join(stats.brands_segmented, ", "),
        stats.segmentation_queue,
        Integer.to_string(stats.total_new_ads),
        Integer.to_string(stats.total_segmented),
        Integer.to_string(stats.total_decayed_ads),
        Integer.to_string(stats.supplements_new),
        Integer.to_string(stats.home_services_new),
        Integer.to_string(stats.supplements_decayed),
        Integer.to_string(stats.home_services_decayed),
        stats.brand_breakdown_new,
        stats.brand_breakdown_decayed,
        Integer.to_string(stats.total_active_tracked),
        Integer.to_string(stats.total_rag_entries),
        format_errors(stats.errors)
      ]
    ]

    if dry_run, do: :ok, else: Client.append_rows(sheet_id, "Daily_Report!A:P", row)
  end

  defp maybe_post_summary(stats, started_at, dry_run) do
    duration = System.monotonic_time(:second) - started_at

    text =
      Slack.daily_summary(
        stats
        |> Map.put(:duration_s, duration)
      )

    if dry_run, do: :ok, else: Slack.post(text)
  end

  defp total_rag_entries(sheet_id) do
    with {:ok, supplements} <- Client.read_range(sheet_id, "Supplements_Daily!A:A"),
         {:ok, home_services} <- Client.read_range(sheet_id, "HomeServices_Daily!A:A") do
      {:ok, max(length(supplements) - 1, 0) + max(length(home_services) - 1, 0)}
    end
  end

  defp vertical_total(brand_results, target_vertical, value_fun) do
    brand_results
    |> Enum.filter(&(normalize_vertical(&1.brand.vertical) == target_vertical))
    |> Enum.map(value_fun)
    |> Enum.sum()
  end

  defp build_breakdown(brand_results, value_fun) do
    brand_results
    |> Enum.map(fn result -> {result.brand.brand_name, value_fun.(result)} end)
    |> Enum.filter(fn {_brand_name, count} -> count > 0 end)
    |> Enum.map_join(", ", fn {brand_name, count} -> "#{brand_name} (#{count})" end)
  end

  defp format_segmentation_queue(queue_counts) do
    queue_counts
    |> Enum.filter(fn {_brand_name, count} -> count > 0 end)
    |> Enum.sort_by(fn {brand_name, _count} -> String.downcase(brand_name) end)
    |> Enum.map_join(", ", fn {brand_name, count} -> "#{brand_name} (#{count} queued)" end)
  end

  defp format_errors([]), do: ""
  defp format_errors(errors), do: Enum.join(errors, " | ")
  defp active_tracked_count(decay_cache), do: decay_cache |> Map.get("brands", %{}) |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
  defp normalize_vertical("supplements"), do: "dtc-supplements"
  defp normalize_vertical("dtc-supplements"), do: "dtc-supplements"
  defp normalize_vertical("home_services"), do: "home-services"
  defp normalize_vertical("home-services"), do: "home-services"
  defp normalize_vertical(other), do: other

  defp initial_confidence(start_date_str) do
    case Date.from_iso8601(start_date_str || "") do
      {:ok, start_date} ->
        age = Date.diff(Date.utc_today(), start_date)

        cond do
          age >= 30 -> "verified"
          age >= 14 -> "curated"
          true -> "emerging"
        end

      _ ->
        "emerging"
    end
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

  defp fresh_scrape_result(dedup_index, decay_cache, backlog) do
    %{brand_results: [], errors: [], dedup_index: dedup_index, decay_cache: decay_cache, backlog: backlog}
  end

  defp strip_scrape_state(result) do
    %{brand_results: result.brand_results, errors: result.errors}
  end

  defp failed_brand_result(brand) do
    %{brand: brand, new_ads_count: 0, decayed_ids: [], active_count: 0, error: :scrape_failed}
  end

  defp return_error(reason), do: throw({:total_rag_entries_error, reason})
end
