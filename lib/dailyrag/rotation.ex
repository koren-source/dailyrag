defmodule DailyRag.Rotation do
  @moduledoc """
  Tracks which brand to process today.
  Cycles through all active brands sequentially, one per day.
  State stored in data/brand_rotation.json.
  """

  @rotation_path "data/brand_rotation.json"

  def load do
    case File.read(@rotation_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> data
          _ -> fresh()
        end
      _ -> fresh()
    end
  end

  def save!(state) do
    DailyRag.Util.ensure_data_dir!()
    tmp = @rotation_path <> ".tmp"
    File.write!(tmp, Jason.encode!(state, pretty: true))
    File.rename!(tmp, @rotation_path)
  end

  # Returns the brand name to process today given the list of active brands.
  # Advances index if last_run was not today.
  def next_brand(brands, state) do
    today = Date.utc_today() |> Date.to_string()
    last_run = Map.get(state, "last_run")
    current_index = Map.get(state, "index", 0)

    index =
      if last_run == today do
        # Already ran today — return same brand (idempotent re-run)
        current_index
      else
        # New day — advance to next brand
        rem(current_index + 1, length(brands))
      end

    brand = Enum.at(brands, index)
    {brand, %{"index" => index, "last_run" => today}}
  end

  defp fresh, do: %{"index" => -1, "last_run" => nil}
end
