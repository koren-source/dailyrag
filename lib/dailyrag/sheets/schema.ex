defmodule DailyRag.Sheets.Schema do
  alias DailyRag.Util

  @spec daily_headers() :: [String.t()]
  def daily_headers do
    [
      "Entry#",
      "Segment Type",
      "Vertical",
      "Format",
      "Principle",
      "Transcript",
      "Why It Works",
      "Source Category",
      "Confidence",
      "Brand/Source Detail",
      "Notes",
      "date_discovered",
      "last_seen",
      "status",
      "ad_id"
    ]
  end

  @spec brand_config_headers() :: [String.t()]
  def brand_config_headers do
    ["brand_name", "vertical", "meta_library_url", "status", "date_added", "source"]
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
      "Date",
      "Brands Scraped",
      "Brands Segmented Today",
      "Segmentation Queue",
      "Total New Ads",
      "Total Segmented",
      "Total Decayed Ads",
      "Supplements New",
      "Home Services New",
      "Supplements Decayed",
      "Home Services Decayed",
      "Brand Breakdown (New)",
      "Brand Breakdown (Decayed)",
      "Total Active Tracked",
      "Total RAG Entries",
      "Errors"
    ]
  end

  @spec build_daily_row(map(), integer(), String.t()) :: [String.t()]
  def build_daily_row(segment, entry_number, vertical) do
    prefix = if vertical == "dtc-supplements", do: "SD", else: "HD"
    entry_str = "#{prefix}-#{String.pad_leading(Integer.to_string(entry_number), 4, "0")}"

    [
      entry_str,
      string(segment, "segment_type"),
      string(segment, "vertical"),
      string(segment, "format"),
      string(segment, "principle"),
      string(segment, "transcript"),
      string(segment, "why_it_works"),
      string(segment, "source_category", "brand"),
      string(segment, "confidence", "emerging"),
      string(segment, "brand_source_detail", string(segment, "brand_name")),
      string(segment, "notes"),
      string(segment, "date_discovered", Util.today()),
      string(segment, "last_seen", Util.today()),
      string(segment, "status", "active"),
      string(segment, "ad_id", string(segment, "source_ad_id"))
    ]
  end

  @spec parse_brand_config_row([String.t()]) :: map()
  def parse_brand_config_row(row) do
    %{
      brand_name: Enum.at(row, 0, ""),
      vertical: Enum.at(row, 1, ""),
      meta_library_url: Enum.at(row, 2, ""),
      status: Enum.at(row, 3, ""),
      date_added: Enum.at(row, 4, ""),
      source: Enum.at(row, 5, "")
    }
  end

  @spec tab_for_vertical(String.t()) :: String.t()
  def tab_for_vertical("supplements"), do: "Supplements_Daily"
  def tab_for_vertical("dtc-supplements"), do: "Supplements_Daily"
  def tab_for_vertical("home_services"), do: "HomeServices_Daily"
  def tab_for_vertical("home-services"), do: "HomeServices_Daily"

  def tab_for_vertical(vertical),
    do: raise(ArgumentError, "unsupported vertical #{inspect(vertical)}")

  defp string(map, key, default \\ "") do
    Map.get(map, key) || Map.get(map, String.to_atom(key), default) || default
  end
end
