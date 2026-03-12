defmodule DailyRag.Dedup do
  alias DailyRag.Util

  @path "data/dedup_index.json"

  @spec load() :: map()
  def load do
    case File.read(path()) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{"ads" => ads} = index} when is_map(ads) ->
            Map.put_new(index, "version", 1)

          _ ->
            empty_index()
        end

      {:error, _} ->
        empty_index()
    end
  end

  @spec known?(map(), String.t()) :: boolean()
  def known?(%{"ads" => ads}, ad_id) when is_binary(ad_id), do: Map.has_key?(ads, ad_id)
  def known?(_, _), do: false

  @spec add(map(), String.t(), [String.t()]) :: map()
  def add(index, brand_name, ad_ids) do
    ads =
      Enum.reduce(ad_ids, Map.get(index, "ads", %{}), fn ad_id, acc ->
        Map.put_new(acc, ad_id, %{"brand" => brand_name, "first_seen" => Util.today()})
      end)

    index
    |> Map.put("version", 1)
    |> Map.put("ads", ads)
  end

  @spec save!(map()) :: :ok
  def save!(index) do
    index
    |> Jason.encode!(pretty: true)
    |> then(&Util.atomic_write!(path(), &1))
  end

  @spec filter_new(map(), [map()]) :: [map()]
  def filter_new(index, ads) do
    Enum.reject(ads, fn ad -> known?(index, Map.get(ad, "ad_id", "")) end)
  end

  defp empty_index, do: %{"version" => 1, "ads" => %{}}
  defp path, do: Application.get_env(:dailyrag, :dedup_path, @path)
end
