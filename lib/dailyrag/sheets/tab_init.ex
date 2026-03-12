defmodule DailyRag.Sheets.TabInit do
  alias DailyRag.Sheets.Client
  alias DailyRag.Sheets.Schema
  alias DailyRag.Util

  @spec ensure_tabs!(String.t()) :: :ok
  def ensure_tabs!(sheet_id) do
    existing_tabs =
      case Client.list_tabs(sheet_id) do
        {:ok, tabs} -> tabs
        {:error, reason} -> raise "failed to list tabs: #{inspect(reason)}"
      end

    Enum.each(required_tabs(), fn {tab, headers} ->
      unless tab in existing_tabs do
        :ok = Client.create_tab(sheet_id, tab)
        :ok = Client.append_rows(sheet_id, "#{tab}!A:Z", [headers])
      end
    end)

    seed_brand_config!(sheet_id)
    seed_discovery_keywords!(sheet_id)
    :ok
  end

  @spec seed_brand_config!(String.t()) :: :ok
  def seed_brand_config!(sheet_id) do
    case Client.read_range(sheet_id, "Brand_Config!A:F") do
      {:ok, rows} when length(rows) <= 1 ->
        Client.append_rows(sheet_id, "Brand_Config!A:F", brand_seed_data())

      {:ok, _rows} ->
        :ok

      {:error, reason} ->
        raise "failed to seed Brand_Config: #{inspect(reason)}"
    end
  end

  @spec seed_discovery_keywords!(String.t()) :: :ok
  def seed_discovery_keywords!(sheet_id) do
    case Client.read_range(sheet_id, "Discovery_Keywords!A:D") do
      {:ok, rows} when length(rows) <= 1 ->
        Client.append_rows(sheet_id, "Discovery_Keywords!A:D", discovery_keyword_seed_data())

      {:ok, _rows} ->
        :ok

      {:error, reason} ->
        raise "failed to seed Discovery_Keywords: #{inspect(reason)}"
    end
  end

  defp required_tabs do
    %{
      "Brand_Config" => Schema.brand_config_headers(),
      "Discovery_Keywords" => Schema.discovery_keywords_headers(),
      "Discovery_Queue" => Schema.discovery_queue_headers(),
      "Supplements_Daily" => Schema.daily_headers(),
      "HomeServices_Daily" => Schema.daily_headers(),
      "Daily_Report" => Schema.daily_report_headers()
    }
  end

  defp brand_seed_data do
    today = Util.today()

    [
      {"AG1", "supplements"},
      {"Onnit", "supplements"},
      {"Momentous", "supplements"},
      {"Thorne", "supplements"},
      {"Jocko Fuel", "supplements"},
      {"Transparent Labs", "supplements"},
      {"Legion Athletics", "supplements"},
      {"Ryse Supps", "supplements"},
      {"Garden of Life", "supplements"},
      {"Leaf Filter", "home_services"},
      {"Bath Fitter", "home_services"},
      {"Renewal by Andersen", "home_services"},
      {"Empire Today", "home_services"},
      {"Stanley Steemer", "home_services"},
      {"ServPro", "home_services"},
      {"1-800-GOT-JUNK", "home_services"},
      {"Mr. Rooter", "home_services"},
      {"TWO MEN AND A TRUCK", "home_services"}
    ]
    |> Enum.map(fn {brand_name, vertical} ->
      page_id = "PLACEHOLDER"
      [brand_name, vertical, meta_library_url(page_id), page_id, "active", today]
    end)
  end

  defp discovery_keyword_seed_data do
    today = Util.today()

    [
      {"supplements", "supplements"},
      {"protein powder", "supplements"},
      {"pre workout", "supplements"},
      {"creatine", "supplements"},
      {"greens powder", "supplements"},
      {"vitamins", "supplements"},
      {"nootropics", "supplements"},
      {"roofing", "home_services"},
      {"HVAC", "home_services"},
      {"plumbing", "home_services"},
      {"gutter guards", "home_services"},
      {"window replacement", "home_services"},
      {"pest control", "home_services"},
      {"lawn care", "home_services"},
      {"house cleaning", "home_services"}
    ]
    |> Enum.map(fn {keyword, vertical} -> [keyword, vertical, "active", today] end)
  end

  defp meta_library_url(page_id) do
    "https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&view_all_page_id=#{page_id}"
  end
end
