defmodule DailyRag.Scraper do
  defp script_path, do: Path.join(:code.priv_dir(:dailyrag), "scraper/scrape_ads.py")

  defp discovery_script_path,
    do: Path.join(:code.priv_dir(:dailyrag), "scraper/scrape_discovery.py")

  @spec scrape_ads(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def scrape_ads(url), do: run_python(script_path(), url)

  @spec scrape_discovery(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def scrape_discovery(keyword), do: run_python(discovery_script_path(), keyword)

  defp run_python(script, arg) do
    python = Application.get_env(:dailyrag, :python_path, "python3")

    cond do
      not File.exists?(script) ->
        {:error, "scraper script not found: #{script}"}

      System.find_executable(python) == nil ->
        {:error, "python executable not found: #{python}"}

      true ->
        case System.cmd(python, [script, arg],
               stderr_to_stdout: true,
               env: [{"PYTHONDONTWRITEBYTECODE", "1"}],
               timeout: 120_000
             ) do
          {output, 0} ->
            case Jason.decode(output) do
              {:ok, ads} when is_list(ads) ->
                {:ok, ads}

              {:ok, %{"error" => msg}} ->
                {:error, msg}

              {:error, _} ->
                {:error, "Invalid JSON from scraper: #{String.slice(output, 0, 200)}"}
            end

          {output, _exit_code} ->
            case Jason.decode(output) do
              {:ok, %{"error" => msg}} -> {:error, msg}
              _ -> {:error, "Scraper crashed: #{String.slice(output, 0, 200)}"}
            end
        end
    end
  end
end
