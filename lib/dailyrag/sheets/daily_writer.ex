defmodule DailyRag.Sheets.DailyWriter do
  alias DailyRag.Sheets.{Client, Schema}

  @spec read_brand_config() :: {:ok, [map()]} | {:error, term()}
  def read_brand_config, do: read_brand_config(sheet_id())

  @spec read_brand_config(String.t()) :: {:ok, [map()]} | {:error, term()}
  def read_brand_config(sheet_id) do
    with {:ok, rows} <- Client.read_range(sheet_id, "Brand_Config!A:E") do
      brands =
        rows
        |> Enum.drop(1)
        |> Enum.map(&Schema.parse_brand_config_row/1)
        |> Enum.filter(& &1.active)

      {:ok, brands}
    end
  end

  @spec write_segments([map()], String.t()) :: :ok | {:error, term()}
  def write_segments(segments, vertical), do: write_segments(segments, vertical, sheet_id())

  @spec write_segments([map()], String.t(), String.t()) :: :ok | {:error, term()}
  def write_segments([], _vertical, _sheet_id), do: :ok

  def write_segments(segments, vertical, sheet_id) do
    tab = Schema.tab_for_vertical(vertical)
    start_entry = next_entry_number(sheet_id, tab)

    rows =
      segments
      |> Enum.with_index(start_entry)
      |> Enum.map(fn {segment, entry_number} -> Schema.build_daily_row(segment, entry_number) end)

    Client.append_rows(sheet_id, "#{tab}!A:K", rows)
  end

  @spec write_daily_report(map()) :: :ok | {:error, term()}
  def write_daily_report(report), do: write_daily_report(report, sheet_id())

  @spec write_daily_report(map(), String.t()) :: :ok | {:error, term()}
  def write_daily_report(report, sheet_id) do
    Client.append_rows(sheet_id, "Daily_Report!A:H", [Schema.build_daily_report_row(report)])
  end

  defp next_entry_number(sheet_id, tab) do
    case Client.read_range(sheet_id, "#{tab}!A:A") do
      {:ok, rows} when rows == [] -> 1
      {:ok, rows} -> max(length(rows), 1)
      {:error, _reason} -> 1
    end
  end

  defp sheet_id, do: Application.fetch_env!(:dailyrag, :sheet_id)
end
