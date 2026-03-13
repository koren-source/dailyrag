defmodule DailyRag.Sheets.SchemaTest do
  use ExUnit.Case, async: true

  alias DailyRag.Sheets.Schema

  test "header lists have correct lengths" do
    assert length(Schema.daily_headers()) == 11
    assert length(Schema.brand_config_headers()) == 5
    assert length(Schema.discovery_keywords_headers()) == 3
    assert length(Schema.discovery_queue_headers()) == 7
    assert length(Schema.daily_report_headers()) == 8
  end

  test "build_daily_row produces 11-element list" do
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
          "ad_id" => "123"
        },
        1
      )

    assert length(row) == 11
    assert Enum.at(row, 0) == "1"
    assert Enum.at(row, 1) == "Problem-Solution"
  end

  test "parse_brand_config_row parses fields" do
    parsed =
      Schema.parse_brand_config_row([
        "AG1",
        "supplements",
        "AG1 protein",
        "https://example.com",
        "TRUE"
      ])

    assert parsed.brand_name == "AG1"
    assert parsed.vertical == "dtc-supplements"
    assert parsed.active == true
  end
end
