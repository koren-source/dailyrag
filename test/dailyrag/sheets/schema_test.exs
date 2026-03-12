defmodule DailyRag.Sheets.SchemaTest do
  use ExUnit.Case, async: true

  alias DailyRag.Sheets.Schema

  test "header lists have correct lengths" do
    assert length(Schema.daily_headers()) == 15
    assert length(Schema.brand_config_headers()) == 6
    assert length(Schema.discovery_keywords_headers()) == 3
    assert length(Schema.discovery_queue_headers()) == 7
    assert length(Schema.daily_report_headers()) == 16
  end

  test "build_daily_row produces 15-element list" do
    row =
      Schema.build_daily_row(
        %{
          "segment_type" => "Problem-Solution",
          "vertical" => "supplements",
          "format" => "video",
          "principle" => "Specificity",
          "transcript" => "Transcript",
          "why_it_works" => "Works",
          "brand_name" => "AG1",
          "date_discovered" => "2026-03-12",
          "last_seen" => "2026-03-12",
          "ad_id" => "123"
        },
        1,
        "dtc-supplements"
      )

    assert length(row) == 15
    assert Enum.at(row, 0) == "SD-0001"
    assert Enum.at(row, 14) == "123"
  end

  test "parse_brand_config_row roundtrips" do
    parsed =
      Schema.parse_brand_config_row([
        "AG1",
        "supplements",
        "https://example.com",
        "active",
        "2026-03-12",
        "manual"
      ])

    assert parsed.brand_name == "AG1"
    assert parsed.status == "active"
    assert parsed.source == "manual"
  end
end
