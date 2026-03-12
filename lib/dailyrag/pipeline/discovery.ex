defmodule DailyRag.Pipeline.Discovery do
  require Logger

  alias DailyRag.Scraper
  alias DailyRag.Sheets.Client
  alias DailyRag.Sheets.TabInit
  alias DailyRag.Slack
  alias DailyRag.Util

  @spec run(map()) :: :ok | {:error, term()}
  def run(opts) do
    sheet_id = Application.fetch_env!(:dailyrag, :sheet_id)
    dry_run = Map.get(opts, :dry_run, false)
    verbose = Map.get(opts, :verbose, false)

    TabInit.ensure_tabs!(sheet_id)

    keywords =
      read_rows(sheet_id, "Discovery_Keywords!A:C")
      |> Enum.filter(&(Enum.at(&1, 2, "") == "active"))

    existing_brands =
      read_rows(sheet_id, "Brand_Config!A:F")
      |> Enum.map(&String.downcase(Enum.at(&1, 0, "")))
      |> MapSet.new()

    queued_brands =
      read_rows(sheet_id, "Discovery_Queue!A:G")
      |> Enum.map(&String.downcase(Enum.at(&1, 0, "")))
      |> MapSet.new()

    discovered =
      Enum.flat_map(keywords, fn row ->
        keyword = Enum.at(row, 0, "")
        vertical = Enum.at(row, 1, "")
        log(verbose, "Searching keyword #{keyword}")

        case Scraper.scrape_discovery(keyword) do
          {:ok, brands} ->
            Enum.reject(brands, fn brand ->
              name = String.downcase(brand["brand_name"] || "")
              MapSet.member?(existing_brands, name) or MapSet.member?(queued_brands, name)
            end)
            |> Enum.map(fn brand ->
              brand
              |> Map.put("vertical", vertical)
              |> Map.put("keyword_source", keyword)
            end)

          {:error, reason} ->
            Logger.warning("discovery scrape failed for #{keyword}: #{inspect(reason)}")
            []
        end
      end)
      |> Enum.uniq_by(&String.downcase(&1["brand_name"]))

    unless dry_run or discovered == [] do
      rows =
        Enum.map(discovered, fn brand ->
          [
            brand["brand_name"],
            brand["vertical"],
            brand["meta_library_url"],
            brand["page_id"],
            Util.today(),
            brand["keyword_source"],
            "pending"
          ]
        end)

      Client.append_rows(sheet_id, "Discovery_Queue!A:G", rows)
    end

    promoted = promote_approved(sheet_id, dry_run)

    unless dry_run do
      Slack.post(
        Slack.discovery_summary(%{
          date: Util.today(),
          keywords_processed: length(keywords),
          new_brands: length(discovered),
          promoted: length(promoted),
          errors: 0
        })
      )
    end

    :ok
  end

  defp promote_approved(sheet_id, dry_run) do
    queue_rows = read_rows(sheet_id, "Discovery_Queue!A:G")

    approved =
      queue_rows
      |> Enum.with_index(2)
      |> Enum.filter(fn {row, _row_index} -> Enum.at(row, 6, "") == "approved" end)

    unless dry_run or approved == [] do
      brand_rows =
        Enum.map(approved, fn {row, _row_index} ->
          [
            Enum.at(row, 0, ""),
            Enum.at(row, 1, ""),
            Enum.at(row, 2, ""),
            "active",
            Util.today(),
            "discovery"
          ]
        end)

      updates =
        Enum.map(approved, fn {_row, row_index} ->
          %{range: "Discovery_Queue!G#{row_index}", values: [["promoted"]]}
        end)

      Client.append_rows(sheet_id, "Brand_Config!A:F", brand_rows)
      Client.batch_update(sheet_id, updates)
    end

    approved
  end

  defp read_rows(sheet_id, range) do
    case Client.read_range(sheet_id, range) do
      {:ok, [_header | rows]} -> rows
      {:ok, []} -> []
      {:ok, rows} -> rows
      {:error, reason} -> raise "failed to read #{range}: #{inspect(reason)}"
    end
  end

  defp log(true, message), do: Logger.info(message)
  defp log(false, _message), do: :ok
end
