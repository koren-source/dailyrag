defmodule DailyRag.SegmentationBacklog do
  alias DailyRag.Util

  @path "data/segmentation_backlog.json"

  @spec load() :: map()
  def load do
    case File.read(path()) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{"brands" => brands} = backlog} when is_map(brands) ->
            Map.put_new(backlog, "version", 1)

          _ ->
            empty_backlog()
        end

      {:error, _} ->
        empty_backlog()
    end
  end

  @spec save!(map()) :: :ok
  def save!(backlog) do
    backlog
    |> Jason.encode!(pretty: true)
    |> then(&Util.atomic_write!(path(), &1))
  end

  @spec enqueue(map(), String.t(), [map()]) :: map()
  def enqueue(backlog, brand_name, ads) do
    existing = brand_ads(backlog, brand_name)

    merged =
      (existing ++ ads)
      |> Enum.reduce({MapSet.new(), []}, fn ad, {seen, acc} ->
        ad_id = ad_id(ad)

        cond do
          ad_id == "" ->
            {seen, acc}

          MapSet.member?(seen, ad_id) ->
            {seen, acc}

          true ->
            {MapSet.put(seen, ad_id), acc ++ [ad]}
        end
      end)
      |> elem(1)

    put_brand_ads(backlog, brand_name, merged)
  end

  @spec dequeue(map(), String.t(), non_neg_integer()) :: {[map()], map()}
  def dequeue(backlog, brand_name, count) when count >= 0 do
    ads = brand_ads(backlog, brand_name)
    {Enum.take(ads, count), put_brand_ads(backlog, brand_name, Enum.drop(ads, count))}
  end

  @spec queued_count(map(), String.t()) :: non_neg_integer()
  def queued_count(backlog, brand_name), do: backlog |> brand_ads(brand_name) |> length()

  @spec queue_counts(map()) :: %{optional(String.t()) => non_neg_integer()}
  def queue_counts(backlog) do
    backlog
    |> Map.get("brands", %{})
    |> Enum.map(fn {brand_name, ads} -> {brand_name, length(ads)} end)
    |> Map.new()
  end

  defp put_brand_ads(backlog, brand_name, []),
    do: update_in(backlog, ["brands"], &Map.delete(&1 || %{}, brand_name))

  defp put_brand_ads(backlog, brand_name, ads),
    do: put_in(backlog, ["brands", brand_name], ads)

  defp brand_ads(backlog, brand_name), do: get_in(backlog, ["brands", brand_name]) || []
  defp ad_id(%{"ad_id" => ad_id}) when is_binary(ad_id), do: ad_id
  defp ad_id(%{ad_id: ad_id}) when is_binary(ad_id), do: ad_id
  defp ad_id(_), do: ""
  defp empty_backlog, do: %{"version" => 1, "brands" => %{}}
  defp path, do: Application.get_env(:dailyrag, :segmentation_backlog_path, @path)
end
