defmodule DailyRag.Scraper do
  defp script_path, do: Path.join(:code.priv_dir(:dailyrag), "scraper/scrape_ads.py")

  @spec scrape_ads(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def scrape_ads(url), do: run_python(script_path(), ["brand", url])

  @spec scrape_discovery(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def scrape_discovery(keyword) do
    url = "https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&q=#{URI.encode(keyword)}"
    run_python(script_path(), ["discovery", url])
  end

  defp run_python(script, arg) do
    python = Application.get_env(:dailyrag, :python_path, "python3")

    cond do
      not File.exists?(script) ->
        {:error, "scraper script not found: #{script}"}

      System.find_executable(python) == nil ->
        {:error, "python executable not found: #{python}"}

      true ->
        args = if is_list(arg), do: arg, else: [arg]
        task = Task.async(fn ->
          System.cmd(python, [script | args],
            env: [{"PYTHONDONTWRITEBYTECODE", "1"}]
          )
        end)
        case Task.await(task, 120_000) do
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
