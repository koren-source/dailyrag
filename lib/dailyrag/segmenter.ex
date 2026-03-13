defmodule DailyRag.Segmenter do
  require Logger

  @model "claude-sonnet-4-6"
  @default_claude_bin "/opt/homebrew/bin/claude"

  # Max new ads to segment per brand per daily run.
  # 3 brands × 20 ads = up to 60 segments per daily pipeline run.
  # Ads are processed in batches of @batch_size to stay within the Claude CLI timeout.
  # NOTE: Ad Library scrape output can contain lots of raw HTML/CSS noise; we sanitize +
  # truncate per-ad text before sending to Claude to keep prompts fast + stable.
  @max_ads_per_run 20
  @batch_size 5
  @claude_timeout_ms 1_200_000
  @max_chars_per_ad 1_500
  @max_chars_headline 200

  @spec max_ads_per_run() :: pos_integer()
  def max_ads_per_run, do: @max_ads_per_run

  @spec segment_ads(String.t(), String.t(), [map()]) :: {:ok, [map()]} | {:error, term()}
  def segment_ads(brand_name, vertical, ads) do
    ads
    |> Enum.take(@max_ads_per_run)
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      case call_claude(brand_name, vertical, batch) do
        {:ok, segments} -> {:cont, {:ok, acc ++ segments}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp call_claude(brand_name, vertical, ads_batch) do
    prompt = system_prompt() <> "\n\n" <> build_user_prompt(brand_name, vertical, ads_batch)
    do_call(prompt, 3, 2_000)
  end

  defp normalize_text(text, max_len) when is_binary(text) do
    text
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.replace(~r/\bActive\b/i, " ")
    |> String.trim()
    |> String.slice(0, max_len)
  end

  defp normalize_text(_, _max_len), do: ""

  defp do_call(_prompt, 0, _delay), do: {:error, :max_retries}

  defp do_call(prompt, attempts, delay) do
    # Uses the claude CLI with OAuth subscription — no API key required.
    # Wrapped in Task for a bounded timeout so we never hang the daily pipeline.
    task =
      Task.async(fn ->
        System.cmd(claude_bin(), ["--print", "--model", @model, prompt], stderr_to_stdout: false)
      end)

    case Task.await(task, @claude_timeout_ms) do
      {output, 0} ->
        parse_segments(String.trim(output))

      {output, exit_code} when exit_code in [1, 2] ->
        Logger.warning(
          "claude CLI returned exit #{exit_code}, retrying. Output: #{String.slice(output, 0, 200)}"
        )

        Process.sleep(delay)
        do_call(prompt, attempts - 1, delay * 2)

      {output, exit_code} ->
        {:error, {:cli_error, exit_code, String.slice(output, 0, 500)}}
    end
  end

  defp system_prompt do
    """
    You are an expert performance marketing analyst specializing in Meta ads
    across supplements, home services, and DTC verticals. You analyze ad
    creative (copy and structure) to extract actionable intelligence for
    creative strategists.

    For each ad, produce a JSON object with these exact keys:
    - "segment_type": The creative angle category. Use one of: "Problem-Solution",
      "Social Proof/UGC", "Before/After Transformation", "Authority/Expert",
      "Urgency/Scarcity", "Educational/How-To", "Listicle/Reasons Why",
      "Emotional Story", "Comparison/Alternative", "Offer/Discount Lead",
      "Fear/Risk Awareness", "Curiosity Gap"
    - "principle": The core psychological or marketing principle at work (1-2 sentences).
    - "transcript": The full ad copy, cleaned (no emoji spam, fix formatting,
      preserve the actual words).
    - "why_it_works": Sharp, specific analysis of WHY this ad is effective. Not
      generic platitudes. Reference specific lines or techniques in the ad.
      A creative strategist should be able to read this and immediately know what
      to replicate. 2-4 sentences.
    - "format": Best guess at ad format: "video", "static_image", "carousel",
      "collection", "stories", "reel"

    Return ONLY a valid JSON array. No markdown, no code fences, no explanation
    outside the JSON. If an ad contains multiple distinct hooks or angles, create
    one segment per angle. Most ads produce 1-2 segments.
    """
  end

  defp build_user_prompt(brand_name, vertical, ads_batch) do
    ads_text =
      ads_batch
      |> Enum.with_index(1)
      |> Enum.map(fn {ad, i} ->
        copy = normalize_text(ad["copy"], @max_chars_per_ad)
        headline = normalize_text(ad["headline"], @max_chars_headline)

        headline_line = if headline == "", do: "", else: "\nHeadline: #{headline}"
        copy_text = if copy == "", do: "[no readable copy extracted]", else: copy

        "--- Ad #{i} (ID: #{ad["ad_id"]}) ---\n#{copy_text}#{headline_line}"
      end)
      |> Enum.join("\n\n")

    """
    Analyze the following #{length(ads_batch)} Meta ad(s) from brand "#{brand_name}"
    in the #{vertical} vertical.

    #{ads_text}

    Return a JSON array of segment objects. Include the ad_id in each segment
    object as "source_ad_id" so I can trace which ad produced which segment.
    """
  end

  defp parse_segments(text) when is_binary(text) do
    cleaned =
      text
      |> String.replace(~r/^```json\s*/m, "")
      |> String.replace(~r/\s*```$/m, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, segments} when is_list(segments) ->
        {:ok, Enum.map(segments, &validate_segment/1)}

      {:ok, _} ->
        {:error, :not_a_list}

      {:error, reason} ->
        {:error, {:json_parse, reason}}
    end
  end

  defp parse_segments(_), do: {:error, :missing_text}

  defp claude_bin do
    Application.get_env(:dailyrag, :claude_bin, @default_claude_bin)
  end

  defp validate_segment(seg) when is_map(seg) do
    %{
      "segment_type" => seg["segment_type"] || "unknown",
      "principle" => seg["principle"] || "",
      "transcript" => seg["transcript"] || "",
      "why_it_works" => seg["why_it_works"] || "",
      "format" => seg["format"] || "unknown",
      "source_ad_id" => seg["source_ad_id"] || ""
    }
  end
end
