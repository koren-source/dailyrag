defmodule DailyRag.Decay do
  alias DailyRag.Util

  @path "data/decay_cache.json"

  @spec load() :: map()
  def load do
    case File.read(path()) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{"brands" => brands} = cache} when is_map(brands) ->
            cache
            |> Map.put_new("version", 1)
            |> Map.put_new("date", Util.today())

          _ ->
            empty_cache()
        end

      {:error, _} ->
        empty_cache()
    end
  end

  @spec diff(map(), String.t(), [String.t()]) :: {[String.t()], [String.t()]}
  def diff(cache, brand_name, todays_ad_ids) do
    yesterday_ids = cache |> Map.get("brands", %{}) |> Map.get(brand_name, [])
    yesterday = MapSet.new(yesterday_ids)
    today = MapSet.new(todays_ad_ids)

    {MapSet.difference(yesterday, today) |> MapSet.to_list(),
     MapSet.difference(today, yesterday) |> MapSet.to_list()}
  end

  @spec update(map(), String.t(), [String.t()]) :: map()
  def update(cache, brand_name, todays_ad_ids) do
    brands = cache |> Map.get("brands", %{}) |> Map.put(brand_name, Enum.uniq(todays_ad_ids))

    cache
    |> Map.put("version", 1)
    |> Map.put("date", Util.today())
    |> Map.put("brands", brands)
  end

  @spec save!(map()) :: :ok
  def save!(cache) do
    cache
    |> Jason.encode!(pretty: true)
    |> then(&Util.atomic_write!(path(), &1))
  end

  @spec canary_warning?(map(), String.t(), [String.t()]) :: boolean()
  def canary_warning?(cache, brand_name, todays_ad_ids) do
    yesterday_ids = cache |> Map.get("brands", %{}) |> Map.get(brand_name, [])
    length(yesterday_ids) >= 5 and todays_ad_ids == []
  end

  @spec confidence_upgrades([map()], Date.t()) :: [{integer(), String.t()}]
  def confidence_upgrades(rows, today) do
    Enum.reduce(rows, [], fn row, acc ->
      if Map.get(row, "status", "active") != "active" do
        acc
      else
        row_index = row["row_index"] || row[:row_index]
        discovered = row["date_discovered"] || row[:date_discovered] || ""
        confidence = row["confidence"] || row[:confidence] || "emerging"

        new_confidence =
          discovered
          |> safe_parse_date()
          |> maybe_upgrade(confidence, today)

        if row_index && new_confidence && new_confidence != confidence do
          [{row_index, new_confidence} | acc]
        else
          acc
        end
      end
    end)
    |> Enum.reverse()
  end

  defp maybe_upgrade(nil, _confidence, _today), do: nil

  defp maybe_upgrade(discovered, confidence, today) do
    age_days = Date.diff(today, discovered)

    cond do
      confidence == "verified" -> "verified"
      age_days >= 30 -> "verified"
      confidence == "curated" and age_days >= 30 -> "verified"
      age_days >= 14 and confidence in ["emerging", ""] -> "curated"
      true -> confidence
    end
  end

  defp safe_parse_date(""), do: nil

  defp safe_parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp empty_cache, do: %{"version" => 1, "date" => Util.today(), "brands" => %{}}
  defp path, do: Application.get_env(:dailyrag, :decay_path, @path)
end
