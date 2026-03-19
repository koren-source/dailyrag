defmodule DailyRag.Pipeline.Daily do
  @moduledoc false

  require Logger

  alias DailyRag.{Decay, Dedup, Rotation, Scraper, Segmenter, Slack, Util}
  alias DailyRag.Sheets.DailyWriter

  @pipeline_timeout_ms :timer.minutes(180)
  @brand_segment_timeout_ms :timer.minutes(15)

  @spec run() :: :ok | {:error, term()}
  def run, do: run(%{})

  @spec run(map()) :: :ok | {:error, term()}
  def run(opts) do
    {:ok, tracker} = Agent.start_link(fn -> tracker_state() end)
    task = Task.Supervisor.async_nolink(DailyRag.TaskSupervisor, fn -> do_run(opts, tracker) end)

    try do
      case Task.yield(task, @pipeline_timeout_ms) do
        {:ok, result} ->
          result

        nil ->
          Task.shutdown(task, :brutal_kill)
          handle_timeout(opts, tracker)
      end
    after
      Agent.stop(tracker, :normal)
    end
  end

  @spec health_check() :: :ok | :abort
  def health_check, do: health_check([])

  @spec health_check(keyword()) :: :ok | :abort
  def health_check(opts) do
    case DailyWriter.read_brand_config() do
      {:ok, brands} ->
        canaries = pick_canary_brands(brands, 3)
        limit = Keyword.get(opts, :limit, 5)

        results =
          Enum.map(canaries, fn brand ->
            case Scraper.scrape_brand(brand, limit: limit) do
              {:ok, ads} when ads != [] -> {:ok, brand.brand_name, length(ads)}
              {:ok, []} -> {:fail, brand.brand_name, :zero_ads}
              {:error, reason} -> {:fail, brand.brand_name, reason}
            end
          end)

        successes = Enum.filter(results, &match?({:ok, _, _}, &1))
        failures = Enum.filter(results, &match?({:fail, _, _}, &1))

        Enum.each(failures, fn {:fail, name, reason} ->
          Logger.warning("Health check canary failed: #{name} - #{inspect(reason)}")
        end)

        if successes == [] do
          names = Enum.map_join(canaries, ", ", & &1.brand_name)

          alert(
            "DailyRag health check failed: all #{length(canaries)} canaries returned 0 ads (#{names}). Aborting daily run."
          )

          :abort
        else
          passed =
            Enum.map_join(successes, ", ", fn {:ok, name, count} ->
              "#{name}(#{count})"
            end)

          Logger.info("Health check passed: #{passed}")
          :ok
        end

      {:error, reason} ->
        alert("DailyRag health check failed: #{inspect(reason)}")
        :abort
    end
  end

  defp do_run(opts, tracker) do
    started_at = System.monotonic_time(:second)
    dry_run = Map.get(opts, :dry_run, false)

    Util.ensure_data_dir!()
    update_tracker(tracker, %{phase: "loading_brand_config"})

    with {:ok, brands} <- load_active_brands(opts),
         :ok <- validate_brand_override(brands, opts),
         :ok <- health_check(limit: Map.get(opts, :limit, 5)),
         {brands_to_segment, rotation_state} <- select_segmentation_brands(brands, opts),
         scrape_state <-
           scrape_all_brands(brands_to_segment, Dedup.load(), Decay.load(), tracker, opts),
         segment_state <-
           process_rotating_brands(
             brands_to_segment,
             scrape_state.new_ads_by_brand,
             tracker,
             opts
           ) do
      duration_seconds = System.monotonic_time(:second) - started_at

      unless dry_run do
        Dedup.save!(scrape_state.dedup_index)
        Decay.save!(scrape_state.decay_cache)
        Rotation.save!(rotation_state)
      end

      report =
        %{
          "run_date" => Util.today(),
          "brands_scraped" => scrape_state.brands_scraped,
          "new_ads_found" => scrape_state.new_ads_found,
          "ads_transcribed" => segment_state.ads_transcribed,
          "segments_written" => segment_state.segments_written,
          "errors" => format_errors(scrape_state.errors ++ segment_state.errors),
          "duration_seconds" => duration_seconds,
          "status" =>
            derive_status(
              format_errors(scrape_state.errors ++ segment_state.errors),
              segment_state.segments_written,
              scrape_state.new_ads_found
            )
        }

      if report["segments_written"] == 0 and not dry_run do
        cond do
          report["new_ads_found"] == 0 ->
            Logger.info(
              "No new ads found across #{report["brands_scraped"]} brands — nothing to segment."
            )

          report["errors"] != "" ->
            alert(
              "🔴 DailyRag — #{report["run_date"]}: #{report["new_ads_found"]} new ads found but wrote 0 segments. " <>
                "Errors: #{report["errors"]}"
            )

          true ->
            alert(
              "⚠️ DailyRag — #{report["run_date"]}: #{report["new_ads_found"]} new ads found but wrote 0 segments (no errors). " <>
                "Check segmenter logs."
            )
        end
      end

      update_tracker(tracker, report)

      unless dry_run do
        :ok = DailyWriter.write_daily_report(report)
        :ok = Slack.post(summary_text(report, brands_to_segment))
      end

      :ok
    else
      :abort ->
        report =
          %{
            "run_date" => Util.today(),
            "brands_scraped" => tracker_value(tracker, :brands_scraped),
            "new_ads_found" => tracker_value(tracker, :new_ads_found),
            "ads_transcribed" => tracker_value(tracker, :ads_transcribed),
            "segments_written" => tracker_value(tracker, :segments_written),
            "errors" => format_errors(["health_check_failed" | tracker_value(tracker, :errors)]),
            "duration_seconds" => System.monotonic_time(:second) - started_at,
            "status" => "aborted"
          }

        unless dry_run do
          :ok = DailyWriter.write_daily_report(report)
        end

        {:error, :health_check_failed}

      {:error, reason} ->
        report =
          %{
            "run_date" => Util.today(),
            "brands_scraped" => tracker_value(tracker, :brands_scraped),
            "new_ads_found" => tracker_value(tracker, :new_ads_found),
            "ads_transcribed" => tracker_value(tracker, :ads_transcribed),
            "segments_written" => tracker_value(tracker, :segments_written),
            "errors" => format_errors([inspect(reason) | tracker_value(tracker, :errors)]),
            "duration_seconds" => System.monotonic_time(:second) - started_at,
            "status" => "failed"
          }

        unless dry_run do
          :ok = DailyWriter.write_daily_report(report)
          alert("DailyRag daily run failed: #{inspect(reason)}")
        end

        {:error, reason}
    end
  end

  defp load_active_brands(opts) do
    with {:ok, brands} <- DailyWriter.read_brand_config() do
      brand_override = Map.get(opts, :brand)

      filtered =
        cond do
          is_binary(brand_override) and brand_override != "" ->
            Enum.filter(brands, &(&1.brand_name == brand_override))

          true ->
            brands
        end

      {:ok, filtered}
    end
  end

  defp validate_brand_override([], %{brand: name}) when is_binary(name) and name != "",
    do: {:error, {:brand_not_found, name}}

  defp validate_brand_override(_brands, _opts), do: :ok

  defp select_segmentation_brands(brands, %{brand: name}) when is_binary(name) and name != "" do
    {Enum.filter(brands, &(&1.brand_name == name)), Rotation.load()}
  end

  defp select_segmentation_brands(brands, _opts) do
    Rotation.next_rotating_brands(brands, Rotation.load())
  end

  defp scrape_all_brands(brands, dedup_index, decay_cache, tracker, opts) do
    Logger.info("Phase 1: scraping #{length(brands)} brands")

    brands
    |> Enum.with_index()
    |> Enum.reduce(initial_scrape_state(dedup_index, decay_cache), fn {brand, idx}, acc ->
      if idx > 0 do
        delay_ms = 30_000 + :rand.uniform(30_000)
        Logger.info("Inter-brand delay: #{delay_ms}ms before #{brand.brand_name}")
        Process.sleep(delay_ms)
      end

      update_tracker(tracker, %{phase: "phase_1_scrape", brand: brand.brand_name})

      case Scraper.scrape_brand(brand, limit: Map.get(opts, :limit, 30)) do
        {:ok, ads} ->
          ad_ids = Enum.map(ads, &(&1["ad_id"] || ""))
          new_ads = Dedup.filter_new(acc.dedup_index, ads) |> Enum.map(&enrich_ad(&1, brand))
          {disappeared_ids, _} = Decay.diff(acc.decay_cache, brand.brand_name, ad_ids)

          maybe_alert_canary(acc.decay_cache, brand.brand_name, ad_ids)

          next_acc = %{
            acc
            | dedup_index:
                Dedup.add(acc.dedup_index, brand.brand_name, Enum.map(new_ads, & &1["ad_id"])),
              decay_cache: Decay.update(acc.decay_cache, brand.brand_name, ad_ids),
              brand_results:
                acc.brand_results ++
                  [
                    %{
                      brand: brand,
                      active_count: length(ads),
                      new_ads_count: length(new_ads),
                      decayed_ids: disappeared_ids
                    }
                  ],
              new_ads_by_brand: Map.put(acc.new_ads_by_brand, brand.brand_name, new_ads),
              brands_scraped: acc.brands_scraped + 1,
              new_ads_found: acc.new_ads_found + length(new_ads)
          }

          update_tracker(tracker, %{
            brands_scraped: next_acc.brands_scraped,
            new_ads_found: next_acc.new_ads_found
          })

          Logger.info("[#{brand.brand_name}] scraped #{length(ads)} ads, #{length(new_ads)} new")

          next_acc

        {:error, :timeout} ->
          Logger.warning("Scrape timeout for #{brand.brand_name}, retrying after 45s...")
          Process.sleep(45_000)

          case Scraper.scrape_brand(brand, limit: Map.get(opts, :limit, 30)) do
            {:ok, ads} ->
              ad_ids = Enum.map(ads, &(&1["ad_id"] || ""))
              new_ads = Dedup.filter_new(acc.dedup_index, ads) |> Enum.map(&enrich_ad(&1, brand))
              {disappeared_ids, _} = Decay.diff(acc.decay_cache, brand.brand_name, ad_ids)
              maybe_alert_canary(acc.decay_cache, brand.brand_name, ad_ids)

              next_acc = %{
                acc
                | dedup_index:
                    Dedup.add(acc.dedup_index, brand.brand_name, Enum.map(new_ads, & &1["ad_id"])),
                  decay_cache: Decay.update(acc.decay_cache, brand.brand_name, ad_ids),
                  brand_results:
                    acc.brand_results ++
                      [
                        %{
                          brand: brand,
                          active_count: length(ads),
                          new_ads_count: length(new_ads),
                          decayed_ids: disappeared_ids
                        }
                      ],
                  new_ads_by_brand: Map.put(acc.new_ads_by_brand, brand.brand_name, new_ads),
                  brands_scraped: acc.brands_scraped + 1,
                  new_ads_found: acc.new_ads_found + length(new_ads)
              }

              update_tracker(tracker, %{
                brands_scraped: next_acc.brands_scraped,
                new_ads_found: next_acc.new_ads_found
              })

              Logger.info(
                "[#{brand.brand_name}] retry succeeded — scraped #{length(ads)} ads, #{length(new_ads)} new"
              )

              next_acc

            {:error, retry_reason} ->
              error = "#{brand.brand_name}: #{inspect(retry_reason)} (after retry)"

              Logger.warning(
                "Retry also failed for #{brand.brand_name}: #{inspect(retry_reason)}"
              )

              append_tracker_error(tracker, error)
              %{acc | errors: acc.errors ++ [error]}
          end

        {:error, reason} ->
          error = "#{brand.brand_name}: #{inspect(reason)}"
          Logger.warning("scrape failed for #{brand.brand_name}: #{inspect(reason)}")
          append_tracker_error(tracker, error)
          %{acc | errors: acc.errors ++ [error]}
      end
    end)
  end

  defp process_rotating_brands(brands, new_ads_by_brand, tracker, opts) do
    Logger.info("Phase 2: segmenting #{length(brands)} brands")

    Enum.reduce(brands, %{ads_transcribed: 0, segments_written: 0, errors: []}, fn brand, acc ->
      update_tracker(tracker, %{phase: "phase_2_segment", brand: brand.brand_name})
      ads = Map.get(new_ads_by_brand, brand.brand_name, [])
      segment_start = System.monotonic_time(:second)

      Logger.info("[#{brand.brand_name}] segmentation started - #{length(ads)} ads to process")

      task =
        Task.Supervisor.async_nolink(DailyRag.TaskSupervisor, fn ->
          segment_brand(brand, ads, opts)
        end)

      case Task.yield(task, @brand_segment_timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, transcribed_count, segments_count}} ->
          next_acc = %{
            ads_transcribed: acc.ads_transcribed + transcribed_count,
            segments_written: acc.segments_written + segments_count,
            errors: acc.errors
          }

          update_tracker(tracker, %{
            ads_transcribed: next_acc.ads_transcribed,
            segments_written: next_acc.segments_written
          })

          segment_duration = System.monotonic_time(:second) - segment_start

          Logger.info(
            "[#{brand.brand_name}] segmentation complete - #{segments_count} segments in #{segment_duration}s"
          )

          next_acc

        {:ok, {:error, reason, transcribed_count}} ->
          error = "#{brand.brand_name}: #{inspect(reason)}"
          Logger.warning("segmentation failed for #{brand.brand_name}: #{inspect(reason)}")
          append_tracker_error(tracker, error)

          next_acc = %{
            ads_transcribed: acc.ads_transcribed + transcribed_count,
            segments_written: acc.segments_written,
            errors: acc.errors ++ [error]
          }

          update_tracker(tracker, %{ads_transcribed: next_acc.ads_transcribed})
          next_acc

        {:exit, reason} ->
          error = "#{brand.brand_name}: segmentation task exited #{inspect(reason)}"
          Logger.warning(error)
          append_tracker_error(tracker, error)
          %{acc | errors: acc.errors ++ [error]}

        nil ->
          segment_duration = System.monotonic_time(:second) - segment_start

          error =
            "#{brand.brand_name}: segmentation timed out after #{div(@brand_segment_timeout_ms, 60_000)} minutes (#{segment_duration}s elapsed)"

          Logger.warning(error)
          append_tracker_error(tracker, error)
          %{acc | errors: acc.errors ++ [error]}
      end
    end)
  end

  defp segment_brand(_brand, [], _opts), do: {:ok, 0, 0}

  defp segment_brand(brand, ads, opts) do
    transcribed_ads = Scraper.transcribe_batch(ads, max_concurrency: 3)

    transcribed_count =
      Enum.count(transcribed_ads, &(&1["copy_source"] == "whisper_transcript"))

    case Segmenter.segment_ads(brand.brand_name, brand.vertical, transcribed_ads) do
      {:ok, raw_segments} ->
        if raw_segments == [] and length(transcribed_ads) > 0 do
          segmentable =
            Enum.count(transcribed_ads, fn ad ->
              ad["copy_source"] != "copy_unavailable" and
                is_binary(ad["copy"]) and String.trim(ad["copy"] || "") != ""
            end)

          Logger.warning(
            "[#{brand.brand_name}] segmenter returned 0 segments from #{length(transcribed_ads)} transcribed ads " <>
              "(#{segmentable} had usable copy) — likely ad_id key mismatch or empty Claude response"
          )
        end

        segments = enrich_segments(raw_segments, transcribed_ads, brand)

        case maybe_write_segments(segments, brand.vertical, opts) do
          :ok ->
            {:ok, transcribed_count, length(segments)}

          {:error, reason} ->
            {:error, reason, transcribed_count}
        end

      {:error, reason} ->
        {:error, reason, transcribed_count}
    end
  end

  defp maybe_write_segments(_segments, _vertical, %{dry_run: true}), do: :ok
  defp maybe_write_segments([], _vertical, _opts), do: :ok

  defp maybe_write_segments(segments, vertical, _opts),
    do: DailyWriter.write_segments(segments, vertical)

  defp enrich_ad(ad, brand) do
    ad
    |> Map.put("brand", brand.brand_name)
    |> Map.put("vertical", brand.vertical)
  end

  defp enrich_segments(segments, ads, brand) do
    ads_by_id = Map.new(ads, fn ad -> {ad["ad_id"], ad} end)
    run_date = Util.today()

    Enum.map(segments, fn segment ->
      ad = Map.get(ads_by_id, segment["source_ad_id"], %{})

      %{
        "segment_type" => segment["segment_type"],
        "vertical" => brand.vertical,
        "format" => segment["format"],
        "principle" => segment["principle"],
        "transcript" => segment["transcript"],
        "why_it_works" => segment["why_it_works"],
        "source_category" => "ad-library",
        "confidence" => confidence_for(ad["start_date"]),
        "brand_source_detail" => "#{brand.brand_name} / ad_#{segment["source_ad_id"]}",
        "notes" => build_notes(ad, run_date)
      }
    end)
  end

  defp build_notes(ad, run_date) do
    [
      "ad_start_date=#{Map.get(ad, "start_date", "")}",
      "media_format=#{Map.get(ad, "format", "")}",
      "copy_source=#{Map.get(ad, "copy_source", "")}",
      "run_date=#{run_date}"
    ]
    |> Enum.join("; ")
  end

  defp confidence_for(start_date) do
    case Date.from_iso8601(start_date || "") do
      {:ok, date} ->
        if Date.diff(Date.utc_today(), date) >= 60, do: "verified", else: "curated"

      _ ->
        "curated"
    end
  end

  defp handle_timeout(opts, tracker) do
    dry_run = Map.get(opts, :dry_run, false)
    phase = tracker_value(tracker, :phase)
    brand = tracker_value(tracker, :brand)
    message = "DailyRag timed out during #{phase}#{if brand, do: " for #{brand}", else: ""}."

    report =
      %{
        "run_date" => Util.today(),
        "brands_scraped" => tracker_value(tracker, :brands_scraped),
        "new_ads_found" => tracker_value(tracker, :new_ads_found),
        "ads_transcribed" => tracker_value(tracker, :ads_transcribed),
        "segments_written" => tracker_value(tracker, :segments_written),
        "errors" => format_errors([message | tracker_value(tracker, :errors)]),
        "duration_seconds" => div(@pipeline_timeout_ms, 1_000),
        "status" => "timeout"
      }

    unless dry_run do
      :ok = DailyWriter.write_daily_report(report)
      alert(message)
    end

    {:error, :timeout}
  end

  defp summary_text(report, brands_to_segment) do
    header = status_header(report["status"], report)

    body = """
    #{header}
    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    Brands scraped: #{report["brands_scraped"]}
    New ads found: #{report["new_ads_found"]}
    Ads transcribed: #{report["ads_transcribed"]}
    Segments written: #{report["segments_written"]}
    Rotating brands: #{Enum.map_join(brands_to_segment, ", ", & &1.brand_name)}
    Duration: #{report["duration_seconds"]}s
    """

    body =
      if report["errors"] != "" do
        body <> "\n⚠️ Errors: #{report["errors"]}"
      else
        body
      end

    String.trim(body)
  end

  defp status_header("success", report),
    do: "✅ DailyRag — #{report["run_date"]}"

  defp status_header("no_new_ads", report),
    do: "✅ DailyRag — #{report["run_date"]} — no new ads today"

  defp status_header("empty", report),
    do: "⚠️ DailyRag — #{report["run_date"]} — 0 segments written"

  defp status_header("partial_failure", report),
    do: "⚠️ DailyRag — #{report["run_date"]} — partial failure"

  defp status_header("failed", report),
    do: "🔴 DailyRag — #{report["run_date"]} — FAILED (0 segments, errors present)"

  defp status_header(status, report),
    do: "DailyRag — #{report["run_date"]} — #{status}"

  defp derive_status(errors, segments_written) do
    cond do
      errors != "" and segments_written > 0 -> "partial_failure"
      errors != "" and segments_written == 0 -> "failed"
      segments_written == 0 -> "empty"
      true -> "success"
    end
  end

  defp derive_status(errors, segments_written, new_ads_found) do
    cond do
      errors != "" and segments_written > 0 -> "partial_failure"
      errors != "" and segments_written == 0 -> "failed"
      new_ads_found == 0 and segments_written == 0 -> "no_new_ads"
      segments_written == 0 -> "empty"
      true -> "success"
    end
  end

  defp format_errors([]), do: ""
  defp format_errors(errors), do: Enum.reject(errors, &(&1 in [nil, ""])) |> Enum.join(" | ")

  defp pick_canary_brands(brands, count) do
    preferred = ["BuckedUp", "Ghost", "RYSE"]

    preferred_brands =
      preferred
      |> Enum.map(fn name -> Enum.find(brands, &(&1.brand_name == name)) end)
      |> Enum.reject(&is_nil/1)

    if length(preferred_brands) >= count do
      Enum.take(preferred_brands, count)
    else
      remaining = Enum.reject(brands, &(&1.brand_name in preferred))

      (preferred_brands ++ Enum.take(Enum.shuffle(remaining), count - length(preferred_brands)))
      |> Enum.take(count)
    end
  end

  defp maybe_alert_canary(decay_cache, brand_name, ad_ids) do
    if Decay.canary_warning?(decay_cache, brand_name, ad_ids) do
      yesterday_count =
        decay_cache |> Map.get("brands", %{}) |> Map.get(brand_name, []) |> length()

      alert(Slack.canary_warning(brand_name, yesterday_count))
    end
  end

  defp alert(message) do
    Logger.warning(message)
    Slack.post(message)
  end

  defp tracker_state do
    %{
      phase: "boot",
      brand: nil,
      brands_scraped: 0,
      new_ads_found: 0,
      ads_transcribed: 0,
      segments_written: 0,
      errors: []
    }
  end

  defp update_tracker(tracker, attrs) do
    Agent.update(tracker, &Map.merge(&1, attrs))
  end

  defp append_tracker_error(tracker, error) do
    Agent.update(tracker, fn state -> Map.update!(state, :errors, &(&1 ++ [error])) end)
  end

  defp tracker_value(tracker, key) do
    Agent.get(tracker, &Map.get(&1, key))
  end

  defp initial_scrape_state(dedup_index, decay_cache) do
    %{
      dedup_index: dedup_index,
      decay_cache: decay_cache,
      brand_results: [],
      new_ads_by_brand: %{},
      brands_scraped: 0,
      new_ads_found: 0,
      errors: []
    }
  end
end
