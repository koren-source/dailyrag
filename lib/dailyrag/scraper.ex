defmodule DailyRag.Scraper do
  @moduledoc """
  Port wrapper for the Python Meta Ad Library scraper sidecar.
  Calls priv/scraper/scrape_ads.py with a URL, returns parsed JSON ads.
  """

  require Logger

  @timeout 180_000

  def scrape(url) do
    python = System.find_executable("python3") || "python3"
    script = scraper_path()

    unless File.exists?(script) do
      {:error, "Scraper script not found at #{script}"}
    else
      run_scraper(python, script, url)
    end
  end

  defp scraper_path do
    case :code.priv_dir(:dailyrag) do
      {:error, _} ->
        Path.join([File.cwd!(), "priv", "scraper", "scrape_ads.py"])

      dir ->
        Path.join([to_string(dir), "scraper", "scrape_ads.py"])
    end
  end

  defp run_scraper(python, script, url) do
    port =
      Port.open({:spawn_executable, python}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [script, url]
      ])

    collect_output(port, "")
  end

  defp collect_output(port, acc) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, acc <> data)

      {^port, {:exit_status, 0}} ->
        parse_output(acc)

      {^port, {:exit_status, code}} ->
        Logger.error("Scraper exited with code #{code}: #{String.slice(acc, 0, 500)}")
        {:error, "Scraper exited with code #{code}: #{String.slice(acc, 0, 500)}"}
    after
      @timeout ->
        Port.close(port)
        {:error, "Scraper timeout after #{div(@timeout, 1000)}s"}
    end
  end

  defp parse_output(raw) do
    # Strip any log lines before JSON — Scrapling may print INFO lines to stdout
    raw = String.trim(raw)

    # Find the start of the JSON array or object
    json_start = find_json_start(raw)

    case json_start do
      nil ->
        {:error, "No JSON found in scraper output: #{String.slice(raw, 0, 200)}"}

      idx ->
        json_str = String.slice(raw, idx, String.length(raw) - idx) |> String.trim()

        cond do
          String.starts_with?(json_str, "[") ->
            case Jason.decode(json_str) do
              {:ok, ads} when is_list(ads) -> {:ok, ads}
              {:error, reason} -> {:error, "JSON parse error: #{inspect(reason)}"}
            end

          String.starts_with?(json_str, "{") ->
            case Jason.decode(json_str) do
              {:ok, %{"error" => msg}} -> {:error, msg}
              {:ok, _} -> {:error, "Unexpected JSON object from scraper"}
              {:error, reason} -> {:error, "JSON parse error: #{inspect(reason)}"}
            end

          true ->
            {:error, "Unexpected scraper output: #{String.slice(json_str, 0, 200)}"}
        end
    end
  end

  defp find_json_start(raw) do
    # Look for the first line that starts with [ or { (the actual JSON)
    # Skip log lines like "[2026-03-12 12:30:00] INFO: ..."
    raw
    |> String.split("\n")
    |> Enum.reduce_while(0, fn line, offset ->
      trimmed = String.trim(line)

      cond do
        String.starts_with?(trimmed, "[{") or String.starts_with?(trimmed, "{\"") ->
          {:halt, offset}

        String.starts_with?(trimmed, "[") and String.contains?(trimmed, "\"ad_id\"") ->
          {:halt, offset}

        true ->
          {:cont, offset + String.length(line) + 1}
      end
    end)
    |> then(fn
      offset when is_integer(offset) ->
        if offset < String.length(raw), do: offset, else: nil

      _ ->
        nil
    end)
  end
end
