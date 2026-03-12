defmodule DailyRag.DecayTest do
  use ExUnit.Case, async: false

  alias DailyRag.Decay

  test "diff detects disappeared and new ads" do
    cache = %{"version" => 1, "date" => "2026-03-11", "brands" => %{"AG1" => ["1", "2"]}}
    assert {["1"], ["3"]} = Decay.diff(cache, "AG1", ["2", "3"])
  end

  test "canary warning triggers correctly" do
    cache = %{"brands" => %{"AG1" => Enum.map(1..6, &Integer.to_string/1)}}
    assert Decay.canary_warning?(cache, "AG1", [])
    refute Decay.canary_warning?(cache, "AG1", ["1"])
  end

  test "confidence_upgrades computes 14 day and 30 day thresholds" do
    today = ~D[2026-03-12]

    rows = [
      %{row_index: 2, confidence: "emerging", date_discovered: "2026-02-26", status: "active"},
      %{row_index: 3, confidence: "curated", date_discovered: "2026-02-10", status: "active"},
      %{row_index: 4, confidence: "verified", date_discovered: "2026-01-01", status: "active"}
    ]

    assert [{2, "curated"}, {3, "verified"}] = Decay.confidence_upgrades(rows, today)
  end
end
