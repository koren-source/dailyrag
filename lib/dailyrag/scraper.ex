defmodule DailyRag.Scraper do
  @moduledoc false

  require Logger

  @scrape_timeout_ms 180_000
  @transcribe_timeout_ms 240_000

  @spec scrape_brand(map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def scrape_brand(brand, opts \\ []) do
    with {:ok, args} <- build_scrape_args(brand, opts),
         {:ok, ads} <- run_json(playwright_script_path(), args, @scrape_timeout_ms),
         true <- is_list(ads) do
      {:ok, Enum.map(ads, &normalize_ad/1)}
    else
      false -> {:error, :invalid_scraper_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec scrape_ads(String.t()) :: {:ok, [map()]} | {:error, term()}
  def scrape_ads(url), do: scrape_brand(%{url: url})

  @spec transcribe_ad(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def transcribe_ad(ad, opts \\ []) do
    if media_format(ad) != "video" do
      {:ok, headline_fallback(ad)}
    else
      case video_url(ad) do
        "" ->
          {:ok, headline_fallback(ad)}

        url ->
          args = [
            "--ad_id",
            ad_id(ad),
            "--video_url",
            url,
            "--model",
            Keyword.get(opts, :model, "small")
          ]

          case run_json(transcriber_script_path(), args, @transcribe_timeout_ms) do
            {:ok, %{} = response} -> {:ok, merge_transcription(ad, response)}
            {:error, reason} -> {:ok, headline_fallback(Map.put(ad, "transcription_error", inspect(reason)))}
          end
      end
    end
  end

  @spec transcribe_batch([map()], keyword()) :: [map()]
  def transcribe_batch(ads, opts \\ []) do
    max_concurrency = Keyword.get(opts, :max_concurrency, 3)
    timeout = Keyword.get(opts, :timeout_ms, @transcribe_timeout_ms)

    ads
    |> Task.async_stream(
      fn ad -> transcribe_ad(ad, opts) end,
      max_concurrency: max_concurrency,
      timeout: timeout,
      ordered: true
    )
    |> Enum.map(fn
      {:ok, {:ok, ad}} ->
        ad

      {:ok, {:error, reason}} ->
        Logger.warning("transcribe_ad failed: #{inspect(reason)}")
        %{"copy" => nil, "copy_source" => "copy_unavailable", "error" => inspect(reason)}

      {:exit, reason} ->
        Logger.warning("transcribe_batch task exited: #{inspect(reason)}")
        %{"copy" => nil, "copy_source" => "copy_unavailable", "error" => inspect(reason)}
    end)
    |> Enum.zip(ads)
    |> Enum.map(fn
      {%{"copy_source" => "copy_unavailable", "error" => error}, original_ad} ->
        headline_fallback(Map.put(original_ad, "transcription_error", error))

      {result, _original_ad} ->
        result
    end)
  end

  @spec scrape_discovery(String.t()) :: {:ok, [map()]} | {:error, term()}
  def scrape_discovery(_keyword), do: {:error, :discovery_not_supported}

  defp build_scrape_args(brand, opts) do
    limit = brand |> get_value([:limit, "limit"], Keyword.get(opts, :limit, 30)) |> to_string()

    cond do
      present?(url = get_value(brand, [:ad_library_url, :url, "ad_library_url", "url"])) ->
        {:ok, ["--url", url, "--limit", limit]}

      present?(
        query =
          get_value(brand, [:search_query, :brand_name, :name, "search_query", "brand_name", "name"])
      ) ->
        {:ok, ["--brand", query, "--limit", limit]}

      true ->
        {:error, :missing_scrape_target}
    end
  end

  defp normalize_ad(ad) do
    %{
      "ad_id" => ad |> get_value(["ad_id", :ad_id], "") |> to_string(),
      "format" => ad |> get_value(["format", :format], "static_image") |> to_string(),
      "headline" => ad |> get_value(["headline", :headline], "") |> to_string(),
      "video_url" => ad |> get_value(["video_url", :video_url], "") |> to_string(),
      "start_date" => ad |> get_value(["start_date", :start_date], "") |> to_string()
    }
  end

  defp merge_transcription(ad, response) do
    transcript = get_value(response, ["transcript", :transcript], nil)
    copy_source = get_value(response, ["copy_source", :copy_source], "copy_unavailable")
    error = get_value(response, ["error", :error], nil)

    cond do
      is_binary(transcript) and String.trim(transcript) != "" and copy_source == "whisper_transcript" ->
        ad
        |> Map.put("copy", transcript)
        |> Map.put("copy_source", "whisper_transcript")
        |> Map.put("error", error)

      true ->
        headline_fallback(
          ad
          |> Map.put("error", error)
          |> Map.put("transcription_error", error)
        )
    end
  end

  defp headline_fallback(ad) do
    headline = ad |> get_value(["headline", :headline], "") |> to_string() |> String.trim()

    if headline == "" do
      ad
      |> Map.put("copy", nil)
      |> Map.put("copy_source", "copy_unavailable")
    else
      ad
      |> Map.put("copy", headline)
      |> Map.put("copy_source", "headline_fallback")
    end
  end

  defp ad_id(ad), do: ad |> get_value(["ad_id", :ad_id], "") |> to_string()
  defp media_format(ad), do: ad |> get_value(["format", :format], "") |> to_string()
  defp video_url(ad), do: ad |> get_value(["video_url", :video_url], "") |> to_string()

  defp run_json(script_path, args, timeout_ms) do
    python = Application.get_env(:dailyrag, :python_path, "python3")

    cond do
      not File.exists?(script_path) ->
        {:error, {:missing_script, script_path}}

      System.find_executable(python) == nil ->
        {:error, {:missing_python, python}}

      true ->
        task =
          Task.async(fn ->
            System.cmd(python, [script_path | args],
              env: [{"PYTHONDONTWRITEBYTECODE", "1"}]
            )
          end)

        case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, {output, 0}} ->
            Jason.decode(output)

          {:ok, {output, exit_code}} ->
            case Jason.decode(output) do
              {:ok, decoded} -> {:error, {:script_failed, exit_code, decoded}}
              {:error, _reason} -> {:error, {:script_failed, exit_code, String.trim(output)}}
            end

          nil ->
            {:error, :timeout}
        end
    end
  end

  defp playwright_script_path,
    do: Path.join(:code.priv_dir(:dailyrag), "scraper/playwright_scraper.py")

  defp transcriber_script_path,
    do: Path.join(:code.priv_dir(:dailyrag), "scraper/transcriber.py")

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp get_value(map, keys, default \\ nil)

  defp get_value(map, [key | rest], default) do
    case Map.get(map, key) do
      nil -> get_value(map, rest, default)
      value -> value
    end
  end

  defp get_value(_map, [], default), do: default
end
