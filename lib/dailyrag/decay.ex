defmodule DailyRag.Decay do
  @moduledoc """
  Decay tracking — detects ads that stopped running since yesterday.
  Uses a JSON cache mapping brand_name -> list of active ad_ids.
  """

  @path "data/decay_cache.json"

  def load do
    case File.read(@path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, cache} when is_map(cache) -> cache
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  def save(cache) do
    File.mkdir_p!("data")
    File.write!(@path, Jason.encode!(cache, pretty: true))
  end

  def detect_decayed(brand_name, today_ids, cache) do
    yesterday_ids = MapSet.new(cache[brand_name] || [])
    today_set = MapSet.new(today_ids)
    MapSet.difference(yesterday_ids, today_set) |> MapSet.to_list()
  end

  def update_cache(cache, brand_name, today_ids) do
    Map.put(cache, brand_name, today_ids)
  end

  def canary_check(_brand_name, yesterday_count, today_count) do
    yesterday_count >= 5 and today_count == 0
  end
end
