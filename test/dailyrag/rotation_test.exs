defmodule DailyRag.RotationTest do
  use ExUnit.Case, async: true

  alias DailyRag.Rotation

  test "reuses the same selection when called twice on the same day" do
    brands = [%{brand_name: "A"}, %{brand_name: "B"}, %{brand_name: "C"}]

    {selected, state} = Rotation.next_brands(brands, %{}, 2)
    {selected_again, same_state} = Rotation.next_brands(brands, state, 2)

    assert Enum.map(selected, & &1.brand_name) == ["A", "B"]
    assert Enum.map(selected_again, & &1.brand_name) == ["A", "B"]
    assert same_state == state
  end

  test "advances by completed brand names instead of list index" do
    brands = [%{brand_name: "A"}, %{brand_name: "B"}, %{brand_name: "C"}, %{brand_name: "D"}]
    today = Date.utc_today() |> Date.to_iso8601()
    yesterday = Date.utc_today() |> Date.add(-1) |> Date.to_iso8601()

    state = %{
      "completed" => ["A", "B"],
      "last_run" => yesterday,
      "last_brands" => ["A", "B"]
    }

    reordered = [%{brand_name: "D"}, %{brand_name: "C"}, %{brand_name: "B"}, %{brand_name: "A"}]
    {selected, next_state} = Rotation.next_brands(reordered, state, 2)

    assert Enum.map(selected, & &1.brand_name) == ["D", "C"]
    assert next_state["completed"] == ["A", "B", "D", "C"]
    assert next_state["last_run"] == today
    assert next_state["last_brands"] == ["D", "C"]
  end

  test "ignores legacy index-based state and starts a fresh name-based cycle" do
    brands = [%{brand_name: "A"}, %{brand_name: "B"}, %{brand_name: "C"}]
    {selected, next_state} = Rotation.next_brands(brands, %{"index" => 2, "last_brands" => []}, 2)

    assert Enum.map(selected, & &1.brand_name) == ["A", "B"]
    assert Map.has_key?(next_state, "completed")
    refute Map.has_key?(next_state, "index")
  end
end
