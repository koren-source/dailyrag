defmodule DailyRag.Dedup do
  @moduledoc """
  Local dedup index backed by a JSON file.
  Tracks all ad_ids ever processed to avoid re-segmenting.
  """

  @path "data/dedup_index.json"

  def load do
    case File.read(@path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"processed_ids" => ids}} when is_list(ids) ->
            MapSet.new(ids)

          _ ->
            MapSet.new()
        end

      {:error, _} ->
        MapSet.new()
    end
  end

  def save(index) do
    File.mkdir_p!("data")
    ids = index |> MapSet.to_list() |> Enum.sort()
    data = Jason.encode!(%{"processed_ids" => ids}, pretty: true)
    File.write!(@path, data)
  end

  def filter_new(ads, index) do
    Enum.reject(ads, fn ad -> MapSet.member?(index, ad["ad_id"]) end)
  end

  def add_ids(index, ads) do
    Enum.reduce(ads, index, fn ad, acc -> MapSet.put(acc, ad["ad_id"]) end)
  end
end
