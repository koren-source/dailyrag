defmodule DailyRag.Segmenter do
  @moduledoc false

  require Logger

  @default_claude_bin "/opt/homebrew/bin/claude"
  @default_model "claude-opus-4-0-20250514"
  @max_ads_per_run 20
  @batch_size 10
  @claude_timeout_ms 600_000
  @retry_delays_ms [0, 2_000, 5_000, 10_000]

  @approved_principles """
  Hook: curiosity-gap, pattern-interrupt, bold-claim, problem-callout, social-proof-open, contrarian, question, before-after, urgency, identity-callout
  Body: problem-agitate-solve, story-arc, feature-to-benefit, objection-handling, education, demonstration, comparison, stacking
  CTA: direct-ask, urgency-scarcity, risk-reversal, next-step-framing, value-recap, social-proof-close
  Social Proof: testimonial-result, authority-credential, volume-proof, case-study, user-generated
  Education: myth-bust, how-it-works, insider-knowledge, framework-teach, stat-drop
  Offer: stack, anchor-discount, urgency-scarcity, risk-reversal, comparison-value
  B-roll Direction: proof-of-work, lifestyle-aspiration, problem-visualization, scale-demonstration, environment-context
  """

  @spec max_ads_per_run() :: pos_integer()
  def max_ads_per_run, do: @max_ads_per_run

  @spec segment(map()) :: {:ok, [map()]} | {:error, term()}
  def segment(ad) do
    normalized = normalize_ad(ad)
    segment_ads(normalized["brand"], normalized["vertical"], [normalized])
  end

  @spec segment_ads(String.t(), String.t(), [map()]) :: {:ok, [map()]} | {:error, term()}
  def segment_ads(brand_name, vertical, ads) do
    ads
    |> Enum.take(@max_ads_per_run)
    |> Enum.map(&normalize_ad(&1, brand_name, vertical))
    |> Enum.reject(&skip_segmentation?/1)
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      case segment_batch(brand_name, vertical, batch) do
        {:ok, segments} -> {:cont, {:ok, acc ++ segments}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp skip_segmentation?(%{"copy_source" => "copy_unavailable"}), do: true
  defp skip_segmentation?(%{"copy" => copy}) when not is_binary(copy), do: true
  defp skip_segmentation?(%{"copy" => copy}), do: String.trim(copy) == ""
  defp skip_segmentation?(_ad), do: false

  defp segment_batch(_brand_name, _vertical, []), do: {:ok, []}

  defp segment_batch(brand_name, vertical, ads_batch) do
    prompt = build_prompt(brand_name, vertical, ads_batch)

    with {:ok, output} <- request_with_retries(prompt) do
      parse_segments(output)
    end
  end

  defp request_with_retries(prompt) do
    Enum.reduce_while(@retry_delays_ms, {:error, :unknown}, fn delay_ms, _acc ->
      if delay_ms > 0, do: Process.sleep(delay_ms)

      case call_claude(prompt) do
        {:ok, output} ->
          {:halt, {:ok, output}}

        {:error, reason} ->
          Logger.warning("claude CLI request failed: #{inspect(reason)}")
          {:cont, {:error, reason}}
      end
    end)
  end

  defp call_claude(prompt) do
    tmp_path = prompt_tmp_path()
    File.write!(tmp_path, prompt)

    task =
      Task.async(fn ->
        System.cmd(
          "sh",
          ["-c", ~s|"#{claude_bin()}" --print --model "#{model()}" < "#{tmp_path}"|],
          stderr_to_stdout: true
        )
      end)

    try do
      case Task.yield(task, @claude_timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {output, 0}} ->
          {:ok, String.trim(output)}

        {:ok, {output, exit_code}} ->
          {:error, {:cli_error, exit_code, String.trim(output)}}

        nil ->
          {:error, :timeout}
      end
    after
      File.rm(tmp_path)
    end
  end

  defp build_prompt(brand_name, vertical, ads_batch) do
    ads_text =
      ads_batch
      |> Enum.with_index(1)
      |> Enum.map(fn {ad, index} ->
        """
        AD #{index}
        - Ad ID: #{ad["ad_id"]}
        - Brand: #{brand_name}
        - Vertical: #{vertical}
        - Ad Start Date: #{ad["start_date"]}
        - Copy Source: #{ad["copy_source"]}
        - Media Format: #{ad["format"]}
        - Headline: #{ad["headline"]}

        TRANSCRIPT:
        "#{ad["copy"]}"
        """
        |> String.trim()
      end)
      |> Enum.join("\n\n")

    """
    You are a video ad segmentation expert for Cutbox.ai. Given Meta ad transcripts, break each ad into distinct segments and tag each one.

    ADS:
    #{ads_text}

    INSTRUCTIONS:
    1. Identify each distinct segment in each transcript (hook, body, cta, education, social-proof, offer, b-roll-direction).
    2. A typical ad has at minimum one hook, one body, and one cta.
    3. For each segment, provide ALL of these fields:
       - source_ad_id: the exact Ad ID for the ad this segment came from
       - segment_type: hook | body | cta | education | social-proof | offer | b-roll-direction
       - format: talking-head | voiceover | text-on-screen | ugc | interview | testimonial | demo | mixed
       - principle: 1-3 from the approved list below, comma-separated
       - transcript: the exact words from that segment
       - why_it_works: 1-2 sentences explaining the persuasion technique
    4. Return one flat JSON array containing segments for all ads in this batch.

    APPROVED PRINCIPLES:
    #{@approved_principles}

    RESPOND WITH ONLY a JSON array. No markdown, no explanation, no preamble:
    [
      {
        "source_ad_id": "123",
        "segment_type": "hook",
        "format": "talking-head",
        "principle": "bold-claim, curiosity-gap",
        "transcript": "I gained 20 pounds of muscle in 90 days and I'm going to show you exactly how.",
        "why_it_works": "Opens with a specific, measurable result that creates both credibility and curiosity about the method."
      }
    ]
    """
    |> String.trim()
  end

  defp parse_segments(text) when is_binary(text) do
    cleaned =
      text
      |> String.replace(~r/^```json\s*/m, "")
      |> String.replace(~r/^```\s*/m, "")
      |> String.replace(~r/\s*```$/m, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, segments} when is_list(segments) ->
        {:ok, Enum.map(segments, &validate_segment/1)}

      {:ok, _other} ->
        {:error, :not_a_list}

      {:error, reason} ->
        {:error, {:json_parse, reason}}
    end
  end

  defp parse_segments(_text), do: {:error, :missing_text}

  defp validate_segment(segment) when is_map(segment) do
    %{
      "segment_type" => value_as_string(segment["segment_type"], "body"),
      "format" => value_as_string(segment["format"], "mixed"),
      "principle" => normalize_principle(segment["principle"]),
      "transcript" => value_as_string(segment["transcript"]),
      "why_it_works" => value_as_string(segment["why_it_works"]),
      "source_ad_id" => value_as_string(segment["source_ad_id"])
    }
  end

  defp normalize_principle(values) when is_list(values) do
    values
    |> Enum.map(&value_as_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
  end

  defp normalize_principle(value), do: value_as_string(value)

  defp normalize_ad(ad, brand_name \\ nil, vertical \\ nil) do
    %{
      "ad_id" => get_value(ad, ["ad_id", :ad_id], ""),
      "brand" => get_value(ad, ["brand", :brand], brand_name || ""),
      "vertical" => get_value(ad, ["vertical", :vertical], vertical || ""),
      "copy" => get_value(ad, ["copy", :copy], ""),
      "copy_source" => get_value(ad, ["copy_source", :copy_source], "copy_unavailable"),
      "start_date" => get_value(ad, ["start_date", :start_date], ""),
      "headline" => get_value(ad, ["headline", :headline], ""),
      "format" => get_value(ad, ["format", :format], ""),
      "video_url" => get_value(ad, ["video_url", :video_url], "")
    }
  end

  defp prompt_tmp_path do
    name = "dailyrag-claude-#{System.unique_integer([:positive, :monotonic])}.txt"
    Path.join(System.tmp_dir!(), name)
  end

  defp claude_bin do
    Application.get_env(:dailyrag, :claude_bin, @default_claude_bin)
  end

  defp model do
    Application.get_env(
      :dailyrag,
      :claude_model,
      Application.get_env(:dailyrag, :anthropic_model, @default_model)
    )
  end

  defp value_as_string(nil, default), do: default

  defp value_as_string(value, _default) do
    value
    |> to_string()
    |> String.trim()
  end

  defp value_as_string(value), do: value_as_string(value, "")

  defp get_value(map, [key | rest], default) do
    case Map.get(map, key) do
      nil -> get_value(map, rest, default)
      value -> value
    end
  end

  defp get_value(_map, [], default), do: default
end
