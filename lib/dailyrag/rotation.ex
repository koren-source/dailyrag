defmodule DailyRag.Rotation do
  @moduledoc """
  Tracks which brands to segment today.
  Cycles through all active brands sequentially in fixed-size batches of 3 per day.
  Each brand processes up to 20 new ads per run (see Segmenter.max_ads_per_run/0).
  State stored in data/brand_rotation.json.
  """

  @rotation_path "data/brand_rotation.json"

  def load do
    case File.read(@rotation_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> normalize_state(data)
          _ -> fresh()
        end

      _ ->
        fresh()
    end
  end

  def save!(state) do
    state
    |> Jason.encode!(pretty: true)
    |> then(&DailyRag.Util.atomic_write!(@rotation_path, &1))
  end

  @spec next_brands([term()], map(), pos_integer()) :: {[term()], map()}
  def next_brands(brands, state, count \\ 3)
  def next_brands([], state, _count), do: {[], normalize_state(state)}

  def next_brands(brands, state, count) when is_list(brands) and count > 0 do
    today = Date.utc_today() |> Date.to_iso8601()
    state = normalize_state(state)

    if state["last_run"] == today and state["last_brands"] != [] do
      selected =
        state["last_brands"]
        |> Enum.map(&find_brand(brands, &1))
        |> Enum.reject(&is_nil/1)

      {selected, state}
    else
      total = length(brands)
      start_index = rem(max(state["index"], 0), total)

      selected =
        0..(min(count, total) - 1)
        |> Enum.map(fn offset -> Enum.at(brands, rem(start_index + offset, total)) end)

      next_state = %{
        "index" => rem(start_index + count, total),
        "last_run" => today,
        "last_brands" => Enum.map(selected, &brand_name/1)
      }

      {selected, next_state}
    end
  end

  @spec next_brand([term()], map()) :: {term() | nil, map()}
  def next_brand(brands, state) do
    case next_brands(brands, state, 1) do
      {[brand], next_state} -> {brand, next_state}
      {[], next_state} -> {nil, next_state}
    end
  end

  defp normalize_state(state) do
    fresh()
    |> Map.merge(state || %{})
    |> Map.update!("index", fn
      value when is_integer(value) -> value
      _ -> 0
    end)
    |> Map.update!("last_brands", fn
      value when is_list(value) -> value
      _ -> []
    end)
  end

  defp find_brand(brands, brand_name), do: Enum.find(brands, &(brand_name(&1) == brand_name))
  defp brand_name(%{brand_name: brand_name}), do: brand_name
  defp brand_name(%{"brand_name" => brand_name}), do: brand_name
  defp brand_name(other), do: other
  defp fresh, do: %{"index" => 0, "last_run" => nil, "last_brands" => []}
end
