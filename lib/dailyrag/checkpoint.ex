defmodule DailyRag.Checkpoint do
  alias DailyRag.Util

  @cp_path "data/checkpoint.json"
  @fw_path "data/failed_writes.json"

  @spec save!(map()) :: :ok
  def save!(state) do
    state
    |> Map.put_new("version", 1)
    |> Jason.encode!(pretty: true)
    |> then(&Util.atomic_write!(checkpoint_path(), &1))
  end

  @spec load() :: map() | nil
  def load do
    case File.read(checkpoint_path()) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, state} when is_map(state) -> state
          _ -> nil
        end

      {:error, _} ->
        nil
    end
  end

  @spec clear!() :: :ok
  def clear! do
    case File.rm(checkpoint_path()) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise File.Error, reason: reason, action: "remove file", path: checkpoint_path()
    end
  end

  @spec record_failed_write!(map()) :: :ok
  def record_failed_write!(write_info) do
    writes =
      pending_writes()
      |> Kernel.++([Map.put_new(write_info, "timestamp", Util.utc_now())])

    %{"pending" => writes}
    |> Jason.encode!(pretty: true)
    |> then(&Util.atomic_write!(failed_writes_path(), &1))
  end

  @spec pending_writes() :: [map()]
  def pending_writes do
    case File.read(failed_writes_path()) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{"pending" => writes}} when is_list(writes) -> writes
          _ -> []
        end

      {:error, _} ->
        []
    end
  end

  @spec clear_pending_writes!() :: :ok
  def clear_pending_writes! do
    %{"pending" => []}
    |> Jason.encode!(pretty: true)
    |> then(&Util.atomic_write!(failed_writes_path(), &1))
  end

  defp checkpoint_path, do: Application.get_env(:dailyrag, :checkpoint_path, @cp_path)
  defp failed_writes_path, do: Application.get_env(:dailyrag, :failed_writes_path, @fw_path)
end
