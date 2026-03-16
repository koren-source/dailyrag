defmodule DailyRag.Rotation do
  @moduledoc """
  Tracks which brands to segment today.
  Rotates supplement and home-services brands independently using brand-name completion state.
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

  @doc """
  Select brands for segmentation across all verticals.
  Returns {selected_brands, new_state} where selected_brands is a flat list
  of the selected brands for each vertical.
  """
  @spec next_rotating_brands([term()], map(), keyword()) :: {[term()], map()}
  def next_rotating_brands(brands, state, opts \\ []) do
    state = normalize_state(state)
    today = Date.utc_today() |> Date.to_iso8601()
    brands_by_vertical = Enum.group_by(brands, &vertical_key/1)

    supplements_count = Keyword.get(opts, :supplements_count, 2)
    home_services_count = Keyword.get(opts, :home_services_count, 3)

    vertical_configs = [
      {"dtc-supplements", supplements_count},
      {"home-services", home_services_count}
    ]

    {all_selected, new_verticals} =
      Enum.reduce(vertical_configs, {[], %{}}, fn {vertical, count}, {sel_acc, vert_acc} ->
        pool = Map.get(brands_by_vertical, vertical, [])
        vert_state = get_in(state, ["verticals", vertical]) || fresh_vertical()

        {selected, new_vert_state} = pick_from_vertical(pool, vert_state, count, today)

        {sel_acc ++ selected, Map.put(vert_acc, vertical, new_vert_state)}
      end)

    new_state = %{
      "completed" => state["completed"],
      "last_run" => today,
      "verticals" => new_verticals,
      "last_brands" => Enum.map(all_selected, &brand_name/1)
    }

    {all_selected, new_state}
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
      completed =
        state["completed"]
        |> Enum.filter(fn brand -> find_brand(brands, brand) != nil end)

      remaining = Enum.reject(brands, &(brand_name(&1) in completed))

      {remaining, completed} =
        if remaining == [] do
          {brands, []}
        else
          {remaining, completed}
        end

      selected = Enum.take(remaining, count)
      selected_names = Enum.map(selected, &brand_name/1)

      next_state = %{
        "completed" => completed ++ selected_names,
        "last_run" => today,
        "verticals" => state["verticals"],
        "last_brands" => selected_names
      }

      {selected, next_state}
    end
  end

  defp pick_from_vertical([], vert_state, _count, _today), do: {[], vert_state}

  defp pick_from_vertical(pool, vert_state, count, today) do
    if vert_state["last_run"] == today and vert_state["last_brands"] != [] do
      selected =
        vert_state["last_brands"]
        |> Enum.map(&find_brand(pool, &1))
        |> Enum.reject(&is_nil/1)

      {selected, vert_state}
    else
      pool_names = Enum.map(pool, &brand_name/1)

      completed =
        vert_state["completed"]
        |> Enum.filter(&(&1 in pool_names))

      remaining = Enum.reject(pool, &(brand_name(&1) in completed))

      {remaining, completed} =
        if remaining == [] do
          {pool, []}
        else
          {remaining, completed}
        end

      selected = Enum.take(remaining, count)
      selected_names = Enum.map(selected, &brand_name/1)

      new_vert_state = %{
        "completed" => completed ++ selected_names,
        "last_run" => today,
        "last_brands" => selected_names
      }

      {selected, new_vert_state}
    end
  end

  defp normalize_state(state) when is_map(state) do
    %{
      "completed" => safe_list(Map.get(state, "completed", [])),
      "last_run" => Map.get(state, "last_run"),
      "verticals" => normalize_verticals(Map.get(state, "verticals", %{})),
      "last_brands" => safe_list(Map.get(state, "last_brands", []))
    }
  end

  defp normalize_state(_), do: fresh()

  defp normalize_verticals(verticals) when is_map(verticals) do
    Map.new(verticals, fn {k, v} ->
      {k,
       %{
         "completed" => safe_list(Map.get(v, "completed", [])),
         "last_run" => Map.get(v, "last_run"),
         "last_brands" => safe_list(Map.get(v, "last_brands", []))
       }}
    end)
  end

  defp normalize_verticals(_), do: %{}

  defp safe_list(value) when is_list(value), do: value
  defp safe_list(_value), do: []

  defp fresh_vertical, do: %{"completed" => [], "last_run" => nil, "last_brands" => []}

  defp fresh do
    %{"completed" => [], "last_run" => nil, "verticals" => %{}, "last_brands" => []}
  end

  defp vertical_key(%{vertical: vertical}), do: vertical
  defp vertical_key(%{"vertical" => vertical}), do: vertical
  defp vertical_key(_), do: "unknown"

  defp find_brand(brands, name), do: Enum.find(brands, &(brand_name(&1) == name))
  defp brand_name(%{brand_name: brand_name}), do: brand_name
  defp brand_name(%{"brand_name" => brand_name}), do: brand_name
  defp brand_name(other), do: other
end
