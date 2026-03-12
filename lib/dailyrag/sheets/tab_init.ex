defmodule DailyRag.Sheets.TabInit do
  alias DailyRag.Sheets.Client
  alias DailyRag.Sheets.Schema

  @spec ensure_tabs!(String.t()) :: :ok
  def ensure_tabs!(sheet_id) do
    existing_tabs =
      case Client.list_tabs(sheet_id) do
        {:ok, tabs} -> tabs
        {:error, reason} -> raise "failed to list tabs: #{inspect(reason)}"
      end

    Enum.each(required_tabs(), fn {tab, headers} ->
      unless tab in existing_tabs do
        :ok = Client.create_tab(sheet_id, tab)
      end

      :ok = Client.update_range(sheet_id, "#{tab}!A1:Z1", [headers])
    end)

    :ok
  end

  defp required_tabs do
    %{
      "Brand_Config" => Schema.brand_config_headers(),
      "Discovery_Keywords" => Schema.discovery_keywords_headers(),
      "Discovery_Queue" => Schema.discovery_queue_headers(),
      "Supplements_Daily" => Schema.daily_headers(),
      "HomeServices_Daily" => Schema.daily_headers(),
      "Daily_Report" => Schema.daily_report_headers()
    }
  end
end
