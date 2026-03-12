defmodule DailyRag.Discovery do
  @moduledoc """
  Weekly brand discovery workflow.
  Searches Meta Ad Library by keywords, finds new brands, queues for review.
  """

  require Logger

  alias DailyRag.{Scraper, Sheets, Slack}

  def run(opts) do
    verbose = opts[:verbose] || false
    dry_run = opts[:dry_run] || false

    log(verbose, "Starting weekly brand discovery — #{Date.utc_today()}")

    # 1. Ensure tabs exist
    unless dry_run do
      Sheets.ensure_tabs()
    end

    # 2. Read keywords
    keywords =
      case Sheets.read_discovery_keywords() do
        {:ok, kws} -> kws
        {:error, reason} ->
          Logger.error("Failed to load keywords: #{inspect(reason)}")
          []
      end

    if keywords == [] do
      Logger.error("No active keywords found")
      :error
    else
      run_discovery(keywords, opts, verbose, dry_run)
    end
  end

  defp run_discovery(keywords, _opts, verbose, dry_run) do
    # 3. Get existing brand names to diff against
    existing_brands =
      case Sheets.read_all_brand_names() do
        {:ok, names} -> MapSet.new(names |> Enum.map(&String.downcase/1))
        {:error, _} -> MapSet.new()
      end

    log(verbose, "Existing brands: #{MapSet.size(existing_brands)}")
    log(verbose, "Processing #{length(keywords)} keywords...")

    # 4. Scrape each keyword
    discovered =
      keywords
      |> Enum.flat_map(fn kw ->
        keyword = kw["keyword"]
        vertical = kw["vertical"]
        log(verbose, "  Keyword: #{keyword} (#{vertical})")

        url = build_search_url(keyword)

        case Scraper.scrape(url) do
          {:ok, ads} ->
            # Extract unique page names from results
            ads
            |> Enum.map(fn ad -> ad["page_name"] || "" end)
            |> Enum.filter(&(String.trim(&1) != ""))
            |> Enum.uniq()
            |> Enum.reject(fn name ->
              MapSet.member?(existing_brands, String.downcase(name))
            end)
            |> Enum.map(fn name ->
              %{
                "brand_name" => name,
                "vertical" => vertical,
                "keyword_source" => keyword
              }
            end)

          {:error, reason} ->
            Logger.error("  Scrape failed for keyword '#{keyword}': #{inspect(reason)}")
            []
        end
      end)
      |> deduplicate_discoveries()

    log(verbose, "Found #{length(discovered)} new brands")

    # 5. Write to Discovery_Queue
    unless dry_run or discovered == [] do
      write_to_queue(discovered, verbose)
    end

    # 6. Check for approved brands in queue
    unless dry_run do
      promote_approved_brands(verbose)
    end

    # 7. Post Slack summary
    unless dry_run do
      post_discovery_summary(discovered)
    end

    log(verbose, "Discovery complete")
    discovered
  end

  defp build_search_url(keyword) do
    encoded = URI.encode(keyword)
    "https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&q=#{encoded}"
  end

  defp deduplicate_discoveries(discoveries) do
    discoveries
    |> Enum.uniq_by(fn d -> String.downcase(d["brand_name"]) end)
  end

  defp write_to_queue(discoveries, verbose) do
    today = Date.utc_today() |> Date.to_iso8601()

    rows =
      Enum.map(discoveries, fn d ->
        url = build_search_url(d["brand_name"])

        [
          d["brand_name"],
          d["vertical"],
          url,
          "pending",
          today,
          d["keyword_source"]
        ]
      end)

    case Sheets.append_discovery_queue_rows(rows) do
      {:ok, _} -> log(verbose, "Wrote #{length(rows)} brands to Discovery_Queue")
      {:error, reason} -> Logger.error("Failed to write to Discovery_Queue: #{inspect(reason)}")
    end
  end

  defp promote_approved_brands(verbose) do
    case Sheets.read_discovery_queue() do
      {:ok, rows} ->
        approved =
          rows
          |> Enum.filter(fn row -> Enum.at(row, 3, "") == "approved" end)

        if approved != [] do
          today = Date.utc_today() |> Date.to_iso8601()

          brand_rows =
            Enum.map(approved, fn row ->
              name = Enum.at(row, 0, "")
              vertical = Enum.at(row, 1, "")
              url = Enum.at(row, 2, "")

              [name, vertical, url, "active", today, "discovery", ""]
            end)

          case Sheets.append_brand_config_rows(brand_rows) do
            {:ok, _} ->
              log(verbose, "Promoted #{length(brand_rows)} approved brands to Brand_Config")

            {:error, reason} ->
              Logger.error("Failed to promote brands: #{inspect(reason)}")
          end
        end

      {:error, reason} ->
        Logger.error("Failed to read Discovery_Queue: #{inspect(reason)}")
    end
  end

  defp post_discovery_summary(discovered) do
    date = Date.utc_today() |> Date.to_iso8601()

    if discovered == [] do
      Slack.post_message("""
      Weekly Discovery — #{date}
      ━━━━━━━━━━━━━━━━━━━━━━━
      No new brands found this week.
      """)
    else
      brand_list =
        discovered
        |> Enum.map(fn d -> "• #{d["brand_name"]} (#{d["vertical"]}, via: #{d["keyword_source"]})" end)
        |> Enum.join("\n")

      Slack.post_message("""
      Weekly Discovery — #{date}
      ━━━━━━━━━━━━━━━━━━━━━━━
      Found #{length(discovered)} new brands this week:
      #{brand_list}

      Review + approve in Discovery_Queue tab 👆
      """)
    end
  end

  defp log(true, msg), do: Logger.info(msg)
  defp log(false, _msg), do: :ok
end
