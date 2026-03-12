defmodule DailyRag.Pipeline do
  @moduledoc """
  Main daily pipeline orchestrator.
  Scrapes brands, dedupes, segments with Claude, writes to Sheets, tracks decay.
  """

  require Logger

  alias DailyRag.{Scraper, Dedup, Decay, Segmentation, Sheets, Slack}

  @checkpoint_path "data/checkpoint.json"
  @failed_writes_path "data/failed_writes.json"

  def run(opts) do
    dry_run = opts[:dry_run] || false
    brand_filter = opts[:brand]
    recover = opts[:recover] || false
    verbose = opts[:verbose] || false

    log(verbose, "Starting daily pipeline — #{Date.utc_today()}")
    log(verbose, "Mode: #{if dry_run, do: "DRY RUN", else: "LIVE"}")

    # 1. Ensure sheets exist (always run — this is setup, not pipeline writes)
    case Sheets.ensure_tabs() do
      :ok -> log(verbose, "Sheets tabs verified")
      {:error, reason} -> Logger.error("Tab setup failed: #{inspect(reason)}")
    end

    # 2. Load brands
    brands = load_brands(brand_filter, verbose)

    if brands == [] do
      Logger.error("No brands to process")
      post_error_summary(dry_run)
      :error
    else
      run_pipeline(brands, opts, verbose, dry_run, recover)
    end
  end

  defp run_pipeline(brands, opts, verbose, dry_run, recover) do
    # 3. Load checkpoint if recovering
    completed_brands =
      if recover do
        case load_checkpoint() do
          {:ok, checkpoint} ->
            log(verbose, "Recovering — skipping #{length(checkpoint["completed_brands"])} brands")
            checkpoint["completed_brands"] || []

          _ ->
            []
        end
      else
        []
      end

    brands = Enum.reject(brands, fn b -> b["brand_name"] in completed_brands end)
    log(verbose, "Processing #{length(brands)} brands")

    # 4. Load dedup + decay
    dedup_index = Dedup.load()
    decay_cache = Decay.load()

    # 5. Process each brand
    {results, final_dedup, final_decay, errors} =
      process_brands(brands, dedup_index, decay_cache, opts, verbose)

    # 6. Confidence promotion
    unless dry_run do
      log(verbose, "Running confidence promotion...")
      promote_all_confidence(verbose)
    end

    # 7. Save state
    unless dry_run do
      Dedup.save(final_dedup)
      Decay.save(final_decay)
      clear_checkpoint()
      log(verbose, "State saved")
    end

    # 8. Build and post summary
    summary = build_summary(results, errors)

    unless dry_run do
      write_daily_report(summary)
      slack_text = format_slack_summary(summary)
      Slack.post_message(slack_text)
    end

    log(verbose, "Pipeline complete")
    log(verbose, format_slack_summary(summary))
    summary
  end

  # --- Brand Loading ---

  defp load_brands(brand_filter, verbose) do
    case Sheets.read_brands() do
      {:ok, brands} ->
        brands =
          if brand_filter do
            Enum.filter(brands, fn b -> b["brand_name"] == brand_filter end)
          else
            brands
          end

        log(verbose, "Loaded #{length(brands)} active brands")
        brands

      {:error, reason} ->
        Logger.error("Failed to load brands: #{inspect(reason)}")
        []
    end
  end

  # --- Brand Processing Loop ---

  defp process_brands(brands, dedup_index, decay_cache, opts, verbose) do
    dry_run = opts[:dry_run] || false

    Enum.reduce(brands, {[], dedup_index, decay_cache, []}, fn brand,
                                                                {results, dedup, decay, errors} ->
      brand_name = brand["brand_name"]
      vertical = brand["vertical"]
      url = brand["meta_library_url"]

      log(verbose, "Processing: #{brand_name} (#{vertical})")

      case process_single_brand(brand_name, vertical, url, dedup, decay, opts, verbose) do
        {:ok, brand_result, new_dedup, new_decay} ->
          unless dry_run, do: save_checkpoint(brand_name, results)
          {[brand_result | results], new_dedup, new_decay, errors}

        {:error, reason} ->
          Logger.error("Brand #{brand_name} failed: #{inspect(reason)}")
          error = %{"brand" => brand_name, "error" => inspect(reason)}
          {results, dedup, decay, [error | errors]}
      end
    end)
  end

  defp process_single_brand(brand_name, vertical, url, dedup_index, decay_cache, opts, verbose) do
    dry_run = opts[:dry_run] || false
    today = Date.utc_today() |> Date.to_iso8601()

    # 1. Scrape
    log(verbose, "  Scraping #{brand_name}...")

    case Scraper.scrape(url) do
      {:ok, ads} ->
        log(verbose, "  Found #{length(ads)} ads")

        # DOM change canary check
        yesterday_count = length(decay_cache[brand_name] || [])

        if Decay.canary_check(brand_name, yesterday_count, length(ads)) do
          warning =
            "⚠️ DOM CANARY: #{brand_name} had #{yesterday_count} ads yesterday, 0 today. Possible Meta page structure change."

          Logger.warning(warning)
          unless dry_run, do: Slack.post_message(warning)
        end

        # 2. Detect decay
        today_ids = Enum.map(ads, & &1["ad_id"])
        decayed_ids = Decay.detect_decayed(brand_name, today_ids, decay_cache)
        log(verbose, "  Decayed: #{length(decayed_ids)} ads")

        # Mark decayed in sheets
        unless dry_run or decayed_ids == [] do
          mark_decayed(vertical, decayed_ids, today, verbose)
        end

        # 3. Dedup
        new_ads = Dedup.filter_new(ads, dedup_index)
        log(verbose, "  New (after dedup): #{length(new_ads)} ads")

        # 4. Segment new ads with Claude
        segments = segment_new_ads(new_ads, brand_name, vertical, verbose)

        # 5. Write to sheets
        unless dry_run or segments == [] do
          write_segments_to_sheet(segments, brand_name, vertical, today, verbose)
        end

        # 6. Update dedup + decay
        new_dedup = Dedup.add_ids(dedup_index, new_ads)
        new_decay = Decay.update_cache(decay_cache, brand_name, today_ids)

        result = %{
          "brand" => brand_name,
          "vertical" => vertical,
          "total_scraped" => length(ads),
          "new_ads" => length(new_ads),
          "segments_written" => length(segments),
          "decayed" => length(decayed_ids)
        }

        {:ok, result, new_dedup, new_decay}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Segmentation ---

  defp segment_new_ads([], _brand_name, _vertical, _verbose), do: []

  defp segment_new_ads(ads, brand_name, vertical, verbose) do
    Enum.flat_map(ads, fn ad ->
      raw_copy = ad["copy"] || ""

      if String.trim(raw_copy) == "" do
        log(verbose, "  Skipping ad #{ad["ad_id"]} — empty copy")
        []
      else
        days_running = calculate_days_running(ad["start_date"])
        log(verbose, "  Segmenting ad #{ad["ad_id"]} (#{days_running} days)...")

        case Segmentation.segment_ad(brand_name, vertical, raw_copy, days_running) do
          {:ok, segments} ->
            Enum.map(segments, fn seg ->
              Map.merge(seg, %{
                "ad_id" => ad["ad_id"],
                "brand_name" => brand_name,
                "start_date" => ad["start_date"],
                "days_running" => days_running
              })
            end)

          {:error, reason} ->
            Logger.error("Segmentation failed for ad #{ad["ad_id"]}: #{inspect(reason)}")
            []
        end
      end
    end)
  end

  defp calculate_days_running(nil), do: 0
  defp calculate_days_running(""), do: 0

  defp calculate_days_running(start_date_str) do
    case Date.from_iso8601(start_date_str) do
      {:ok, start_date} -> max(Date.diff(Date.utc_today(), start_date), 0)
      _ -> 0
    end
  end

  # --- Sheet Writing ---

  defp write_segments_to_sheet(segments, brand_name, vertical, today, verbose) do
    tab = daily_tab(vertical)
    next_num = Sheets.get_next_entry_number(tab)
    prefix = if vertical == "dtc-supplements", do: "SD", else: "HD"

    rows =
      segments
      |> Enum.with_index()
      |> Enum.map(fn {seg, idx} ->
        entry_num = "#{prefix}-#{String.pad_leading(Integer.to_string(next_num + idx), 4, "0")}"
        days = seg["days_running"] || 0

        confidence =
          cond do
            days >= 30 -> "verified"
            days >= 14 -> "curated"
            true -> "emerging"
          end

        [
          entry_num,
          seg["segment_type"] || "",
          vertical,
          seg["format"] || "unknown",
          seg["principle"] || "",
          seg["transcript"] || "",
          seg["why_it_works"] || "",
          "ad-library",
          confidence,
          "#{brand_name} / Lib ID #{seg["ad_id"]}",
          "Auto-segmented by Claude",
          today,
          today,
          "active",
          seg["ad_id"] || ""
        ]
      end)

    case Sheets.append_daily_rows(tab, rows) do
      :ok ->
        log(verbose, "  Wrote #{length(rows)} segments to #{tab}")

      {:error, reason} ->
        Logger.error("Failed to write to #{tab}: #{inspect(reason)}")
        cache_failed_write(tab, rows)
    end
  end

  defp mark_decayed(vertical, decayed_ids, _today, _verbose) do
    tab = daily_tab(vertical)
    yesterday = Date.utc_today() |> Date.add(-1) |> Date.to_iso8601()

    Enum.each(decayed_ids, fn ad_id ->
      row_nums = Sheets.find_rows_by_ad_id(tab, ad_id)

      Enum.each(row_nums, fn row_num ->
        case Sheets.update_row_status(tab, row_num, "inactive", yesterday) do
          :ok -> :ok
          {:error, reason} -> Logger.error("Failed to mark decay for #{ad_id}: #{inspect(reason)}")
        end
      end)
    end)
  end

  # --- Confidence Promotion ---

  defp promote_all_confidence(verbose) do
    Enum.each(["Supplements_Daily", "HomeServices_Daily"], fn tab ->
      case Sheets.read_daily_sheet(tab) do
        {:ok, rows} ->
          promote_rows(tab, rows, verbose)

        {:error, reason} ->
          Logger.error("Failed to read #{tab} for promotion: #{inspect(reason)}")
      end
    end)
  end

  defp promote_rows(tab, rows, verbose) do
    rows
    |> Enum.with_index(2)
    |> Enum.each(fn {row, row_num} ->
      status = Enum.at(row, 13, "")
      date_discovered = Enum.at(row, 11, "")
      current_confidence = Enum.at(row, 8, "")

      if status == "active" and date_discovered != "" do
        case Date.from_iso8601(date_discovered) do
          {:ok, disc_date} ->
            days = Date.diff(Date.utc_today(), disc_date)

            new_confidence =
              cond do
                days >= 30 -> "verified"
                days >= 14 -> "curated"
                true -> "emerging"
              end

            # Never downgrade
            if should_promote?(current_confidence, new_confidence) do
              log(verbose, "  Promoting #{tab} row #{row_num}: #{current_confidence} -> #{new_confidence}")
              Sheets.update_confidence(tab, row_num, new_confidence)
            end

          _ ->
            :ok
        end
      end
    end)
  end

  defp should_promote?(current, new) do
    rank = %{"emerging" => 1, "curated" => 2, "verified" => 3}
    (rank[new] || 0) > (rank[current] || 0)
  end

  # --- Daily Report ---

  defp write_daily_report(summary) do
    row = [
      Date.utc_today() |> Date.to_iso8601(),
      to_string(summary.total_new),
      to_string(summary.total_decayed),
      to_string(summary.supplements_new),
      to_string(summary.home_services_new),
      to_string(summary.supplements_decayed),
      to_string(summary.home_services_decayed),
      summary.brand_breakdown_new,
      summary.brand_breakdown_decayed,
      to_string(summary.total_active),
      to_string(summary.total_entries),
      summary.errors_text
    ]

    case Sheets.append_daily_report_row(row) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.error("Failed to write daily report: #{inspect(reason)}")
    end
  end

  # --- Summary Building ---

  defp build_summary(results, errors) do
    supplements_results = Enum.filter(results, &(&1["vertical"] == "dtc-supplements"))
    home_services_results = Enum.filter(results, &(&1["vertical"] == "home-services"))

    total_new = Enum.sum(Enum.map(results, & &1["new_ads"]))
    total_decayed = Enum.sum(Enum.map(results, & &1["decayed"]))

    supplements_new = Enum.sum(Enum.map(supplements_results, & &1["new_ads"]))
    home_services_new = Enum.sum(Enum.map(home_services_results, & &1["new_ads"]))
    supplements_decayed = Enum.sum(Enum.map(supplements_results, & &1["decayed"]))
    home_services_decayed = Enum.sum(Enum.map(home_services_results, & &1["decayed"]))

    total_active = Enum.sum(Enum.map(results, & &1["total_scraped"]))

    brand_new =
      results
      |> Enum.filter(&(&1["new_ads"] > 0))
      |> Enum.map(&"#{&1["brand"]}: (#{&1["new_ads"]} new)")
      |> Enum.join(" | ")

    brand_decayed =
      results
      |> Enum.filter(&(&1["decayed"] > 0))
      |> Enum.map(&"#{&1["brand"]}: (#{&1["decayed"]} stopped)")
      |> Enum.join(" | ")

    zero_new =
      results
      |> Enum.filter(&(&1["new_ads"] == 0))
      |> Enum.map(& &1["brand"])

    zero_active =
      results
      |> Enum.filter(&(&1["total_scraped"] == 0))
      |> Enum.map(& &1["brand"])

    errors_text =
      if errors == [] do
        "none"
      else
        Enum.map(errors, &"#{&1["brand"]}: #{&1["error"]}") |> Enum.join("; ")
      end

    %{
      date: Date.utc_today() |> Date.to_iso8601(),
      total_new: total_new,
      total_decayed: total_decayed,
      supplements_new: supplements_new,
      home_services_new: home_services_new,
      supplements_decayed: supplements_decayed,
      home_services_decayed: home_services_decayed,
      total_active: total_active,
      total_entries: Enum.sum(Enum.map(results, & &1["segments_written"])),
      brand_breakdown_new: if(brand_new == "", do: "none", else: brand_new),
      brand_breakdown_decayed: if(brand_decayed == "", do: "none", else: brand_decayed),
      zero_new_brands: zero_new,
      zero_active_brands: zero_active,
      errors: errors,
      errors_text: errors_text
    }
  end

  defp format_slack_summary(summary) do
    zero_new = if summary.zero_new_brands == [], do: "none", else: Enum.join(summary.zero_new_brands, ", ")
    zero_active = if summary.zero_active_brands == [], do: "none", else: Enum.join(summary.zero_active_brands, ", ")

    errors_section =
      if summary.errors != [] do
        error_lines =
          Enum.map(summary.errors, fn e -> "  #{e["brand"]}: #{e["error"]}" end)
          |> Enum.join("\n")

        "\nErrors:\n#{error_lines}"
      else
        ""
      end

    """
    Daily RAG Update — #{summary.date}
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    New entries: #{summary.total_new}
      #{summary.brand_breakdown_new}

    Decayed ads: #{summary.total_decayed}
      #{summary.brand_breakdown_decayed}

    Brands with zero new ads: #{zero_new}
    Brands with zero active ads (⚠️ possible scrape issue): #{zero_active}

    Total active ads tracked: #{summary.total_active}
    Total entries in RAG: #{summary.total_entries}#{errors_section}
    """
    |> String.trim()
  end

  defp post_error_summary(dry_run) do
    unless dry_run do
      Slack.post_message("⚠️ Daily RAG pipeline failed to load any brands. Check Brand_Config sheet.")
    end
  end

  # --- Checkpoint ---

  defp save_checkpoint(brand_name, results_so_far) do
    File.mkdir_p!("data")
    completed = Enum.map(results_so_far, & &1["brand"]) ++ [brand_name]

    checkpoint = %{
      "date" => Date.utc_today() |> Date.to_iso8601(),
      "completed_brands" => completed,
      "last_brand" => brand_name
    }

    File.write!(@checkpoint_path, Jason.encode!(checkpoint, pretty: true))
  end

  defp load_checkpoint do
    case File.read(@checkpoint_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} ->
            if data["date"] == Date.utc_today() |> Date.to_iso8601() do
              {:ok, data}
            else
              {:error, :stale_checkpoint}
            end

          _ ->
            {:error, :invalid_checkpoint}
        end

      {:error, _} ->
        {:error, :no_checkpoint}
    end
  end

  defp clear_checkpoint do
    File.rm(@checkpoint_path)
  end

  defp cache_failed_write(tab, rows) do
    File.mkdir_p!("data")

    existing =
      case File.read(@failed_writes_path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, data} -> data
            _ -> []
          end

        _ ->
          []
      end

    entry = %{
      "tab" => tab,
      "rows" => rows,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    File.write!(@failed_writes_path, Jason.encode!([entry | existing], pretty: true))
    Logger.warning("Cached failed write to #{@failed_writes_path}")
  end

  # --- Helpers ---

  defp daily_tab("dtc-supplements"), do: "Supplements_Daily"
  defp daily_tab("home-services"), do: "HomeServices_Daily"
  defp daily_tab(_), do: "Supplements_Daily"

  defp log(true, msg), do: Logger.info(msg)
  defp log(false, _msg), do: :ok
end
