defmodule DailyRag.Sheets.Schema do
  @spec daily_headers() :: [String.t()]
  def daily_headers do
    [
      "Entry #",
      "Segment Type",
      "Vertical",
      "Format",
      "Principle",
      "Transcript",
      "Why It Works",
      "Source Category",
      "Confidence",
      "Brand / Source Detail",
      "Notes"
    ]
  end

  @spec brand_config_headers() :: [String.t()]
  def brand_config_headers do
    ["brand_name", "vertical", "search_query", "ad_library_url", "active"]
  end

  @spec discovery_keywords_headers() :: [String.t()]
  def discovery_keywords_headers do
    ["keyword", "vertical", "status"]
  end

  @spec discovery_queue_headers() :: [String.t()]
  def discovery_queue_headers do
    [
      "brand_name",
      "vertical",
      "meta_library_url",
      "page_id",
      "discovered_date",
      "keyword_source",
      "status"
    ]
  end

  @spec daily_report_headers() :: [String.t()]
  def daily_report_headers do
    [
      "run_date",
      "brands_scraped",
      "new_ads_found",
      "ads_transcribed",
      "segments_written",
      "errors",
      "duration_seconds",
      "status"
    ]
  end

  @spec build_daily_row(map(), integer()) :: [String.t()]
  def build_daily_row(segment, entry_number) do
    [
      Integer.to_string(entry_number),
      string(segment, "segment_type"),
      string(segment, "vertical"),
      string(segment, "format"),
      string(segment, "principle"),
      string(segment, "transcript"),
      string(segment, "why_it_works"),
      string(segment, "source_category", "ad-library"),
      string(segment, "confidence", "curated"),
      string(segment, "brand_source_detail"),
      string(segment, "notes")
    ]
  end

  @spec build_daily_report_row(map()) :: [String.t()]
  def build_daily_report_row(report) do
    [
      string(report, "run_date"),
      integer_string(report, "brands_scraped"),
      integer_string(report, "new_ads_found"),
      integer_string(report, "ads_transcribed"),
      integer_string(report, "segments_written"),
      string(report, "errors"),
      integer_string(report, "duration_seconds"),
      string(report, "status", "success")
    ]
  end

  @spec parse_brand_config_row([String.t()]) :: map()
  def parse_brand_config_row(row) do
    brand_name = Enum.at(row, 0, "")
    vertical = row |> Enum.at(1, "") |> normalize_vertical()
    search_query = Enum.at(row, 2, "")
    ad_library_url = Enum.at(row, 3, "")

    %{
      brand_name: brand_name,
      name: brand_name,
      vertical: vertical,
      search_query: search_query,
      ad_library_url: ad_library_url,
      url: ad_library_url,
      active: parse_boolean(Enum.at(row, 4, "")),
      active_raw: Enum.at(row, 4, "")
    }
  end

  @spec tab_for_vertical(String.t()) :: String.t()
  def tab_for_vertical("supplements"), do: "Supplements_Daily"
  def tab_for_vertical("dtc-supplements"), do: "Supplements_Daily"
  def tab_for_vertical("home_services"), do: "HomeServices_Daily"
  def tab_for_vertical("home-services"), do: "HomeServices_Daily"

  def tab_for_vertical(vertical),
    do: raise(ArgumentError, "unsupported vertical #{inspect(vertical)}")

  defp parse_boolean(value) when value in [true, "TRUE", "true", "True", "1", 1, "yes", "YES"],
    do: true

  defp parse_boolean(_), do: false

  defp normalize_vertical("supplements"), do: "dtc-supplements"
  defp normalize_vertical("dtc-supplements"), do: "dtc-supplements"
  defp normalize_vertical("home_services"), do: "home-services"
  defp normalize_vertical("home-services"), do: "home-services"
  defp normalize_vertical(other), do: other

  defp integer_string(map, key) do
    map
    |> string(key, "0")
    |> to_string()
  end

  defp string(map, key, default \\ "") do
    Map.get(map, key) || Map.get(map, String.to_atom(key), default) || default
  end
end
