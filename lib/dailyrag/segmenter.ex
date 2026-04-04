defmodule DailyRag.Segmenter do
  @moduledoc false

  require Logger

  @default_model "claude-sonnet-4-6"
  @max_ads_per_run 20
  @retry_delays_ms [0, 2_000, 5_000, 10_000]
  @rate_limit_delay_ms 1_000
  @claude_timeout_ms 600_000

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
    case segment_once(normalize_ad(ad)) do
      {:ok, segments, _called_api?} -> {:ok, segments}
      {:error, reason, _called_api?} -> {:error, reason}
    end
  end

  @spec segment_ads(String.t(), String.t(), [map()]) :: {:ok, [map()]}
  def segment_ads(brand_name, vertical, ads) do
    normalized =
      ads
      |> Enum.take(@max_ads_per_run)
      |> Enum.map(&normalize_ad(&1, brand_name, vertical))
      |> Enum.reject(fn ad ->
        ad["copy_source"] == "copy_unavailable" or
          not is_binary(ad["copy"]) or String.trim(ad["copy"]) == ""
      end)

    if normalized == [] do
      {:ok, []}
    else
      prompt = build_batch_prompt(normalized)

      case call_claude_with_retries(prompt) do
        {:ok, text} ->
          case parse_batch_segments(text, normalized) do
            {:ok, segments} ->
              {:ok, segments}

            {:error, reason} ->
              Logger.warning("batch parse failed: #{inspect(reason)}, falling back to per-ad")
              segment_ads_serial(normalized)
          end

        {:error, reason} ->
          Logger.warning("batch claude call failed: #{inspect(reason)}, falling back to per-ad")
          segment_ads_serial(normalized)
      end
    end
  end

  defp segment_ads_serial(ads) do
    result =
      Enum.reduce(ads, {[], false}, fn ad, {acc, has_called_api?} ->
        maybe_rate_limit(ad, has_called_api?)

        case segment_once(ad) do
          {:ok, segments, called_api?} ->
            {acc ++ segments, has_called_api? or called_api?}

          {:error, reason, called_api?} ->
            Logger.warning("segmentation failed for #{ad["ad_id"]}: #{inspect(reason)}")
            {acc, has_called_api? or called_api?}
        end
      end)

    {segments, _} = result
    {:ok, segments}
  end

  defp maybe_rate_limit(%{"copy_source" => "copy_unavailable"}, _has_called_api?), do: :ok
  defp maybe_rate_limit(_ad, false), do: :ok
  defp maybe_rate_limit(_ad, true), do: sleep_fun().(@rate_limit_delay_ms)

  defp segment_once(%{"copy_source" => "copy_unavailable"}), do: {:ok, [], false}
  defp segment_once(%{"copy" => copy}) when not is_binary(copy), do: {:ok, [], false}
  defp segment_once(%{"copy" => copy}) when is_binary(copy) and byte_size(copy) == 0, do: {:ok, [], false}

  defp segment_once(ad) do
    if String.trim(ad["copy"]) == "" do
      {:ok, [], false}
    else
      prompt = build_prompt(ad)

      case call_claude_with_retries(prompt) do
        {:ok, text} ->
          case parse_segments(text, ad["ad_id"]) do
            {:ok, segments} -> {:ok, segments, true}
            {:error, reason} -> {:error, reason, true}
          end

        {:error, reason} ->
          {:error, reason, true}
      end
    end
  end

  defp call_claude_with_retries(prompt) do
    Enum.reduce_while(@retry_delays_ms, {:error, :unknown}, fn delay_ms, _acc ->
      if delay_ms > 0, do: sleep_fun().(delay_ms)

      case call_claude(prompt) do
        {:ok, text} ->
          {:halt, {:ok, text}}

        {:error, reason} when reason in [:rate_limited, :overloaded] ->
          Logger.warning("claude call failed (rate limited/overloaded): #{inspect(reason)}, sleeping 15s before retry")
          sleep_fun().(15_000)
          {:cont, {:error, reason}}

        {:error, reason} ->
          Logger.warning("claude call failed: #{inspect(reason)}")
          {:cont, {:error, reason}}
      end
    end)
  end

  defp call_claude(prompt) do
    api_key = Application.get_env(:dailyrag, :anthropic_api_key, "")

    body = %{
      model: model(),
      max_tokens: 8192,
      messages: [%{role: "user", content: prompt}]
    }

    task =
      Task.async(fn ->
        Req.post("https://api.anthropic.com/v1/messages",
          json: body,
          headers: [
            {"x-api-key", api_key},
            {"anthropic-version", "2023-06-01"}
          ],
          receive_timeout: @claude_timeout_ms
        )
      end)

    case Task.yield(task, @claude_timeout_ms + 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}}} ->
        {:ok, String.trim(text)}

      {:ok, {:ok, %{status: 429}}} ->
        {:error, :rate_limited}

      {:ok, {:ok, %{status: 529}}} ->
        {:error, :overloaded}

      {:ok, {:ok, %{status: status, body: body}}} ->
        {:error, {:api_error, status, inspect(body)}}

      {:ok, {:error, reason}} ->
        {:error, {:req_error, reason}}

      nil ->
        {:error, :claude_timeout}
    end
  end

  defp build_prompt(ad) do
    """
    You are a video ad segmentation expert for Cutbox.ai. Given a video ad transcript, break it into distinct segments and tag each one.

    TRANSCRIPT:
    "#{ad["copy"]}"

    METADATA:
    - Brand: #{ad["brand"]}
    - Vertical: #{ad["vertical"]}
    - Ad ID: #{ad["ad_id"]}
    - Ad Start Date: #{ad["start_date"]}
    - Copy Source: #{ad["copy_source"]}

    INSTRUCTIONS:
    1. Identify each distinct segment in the transcript (hook, body, CTA, education, social-proof, offer, b-roll-direction)
    2. A typical video ad has at minimum: one hook + one body + one CTA
    3. For each segment, provide:
       - segment_type: hook | body | cta | education | social-proof | offer | b-roll-direction
       - format: talking-head | voiceover | text-on-screen | ugc | interview | testimonial | demo | mixed
       - principle: 1-3 from the approved list below, comma-separated
       - transcript: the EXACT words from that segment
       - why_it_works: 1-2 sentences explaining the persuasion technique

    APPROVED PRINCIPLES:
    #{@approved_principles}

    RESPOND WITH ONLY a JSON array. No markdown, no code fences, no explanation, no preamble. Start your response with [ and end with ]:
    [
      {
        "segment_type": "hook",
        "format": "talking-head",
        "principle": "bold-claim, curiosity-gap",
        "transcript": "I gained 20 pounds of muscle in 90 days and I'm going to show you exactly how.",
        "why_it_works": "Opens with a specific, measurable result that creates both credibility and curiosity about the method."
      }
    ]
    """
  end

  defp build_batch_prompt(ads) do
    ads_section =
      ads
      |> Enum.map_join("\n\n", fn ad ->
        """
        AD_ID: #{ad["ad_id"]}
        Brand: #{ad["brand"]} | Vertical: #{ad["vertical"]} | Start: #{ad["start_date"]} | Source: #{ad["copy_source"]}
        TRANSCRIPT:
        #{ad["copy"]}
        """
      end)

    """
    You are a video ad segmentation expert for Cutbox.ai. Segment each ad transcript below into distinct parts and tag each segment.

    For each segment provide:
    - segment_type: hook | body | cta | education | social-proof | offer | b-roll-direction
    - format: talking-head | voiceover | text-on-screen | ugc | interview | testimonial | demo | mixed
    - principle: 1-3 from the approved list, comma-separated
    - transcript: the EXACT words from that segment
    - why_it_works: 1-2 sentences on the persuasion technique used

    APPROVED PRINCIPLES:
    #{@approved_principles}

    A typical video ad has at minimum: hook + body + CTA.

    ADS TO SEGMENT:
    #{ads_section}

    RESPOND WITH ONLY a JSON object. Keys must be the EXACT AD_ID values from the input above — do NOT add any prefix like "ad_". Each value is an array of segment objects. No markdown, no code fences, no explanation. Start your response with { and end with }:
    {
      "<exact AD_ID from input>": [
        {
          "segment_type": "hook",
          "format": "talking-head",
          "principle": "bold-claim, curiosity-gap",
          "transcript": "exact words here",
          "why_it_works": "explanation here"
        }
      ]
    }
    """
  end

  defp parse_batch_segments(text, ads) when is_binary(text) do
    cleaned =
      text
      |> String.replace(~r/^```json\s*/m, "")
      |> String.replace(~r/^```\s*/m, "")
      |> String.replace(~r/\s*```$/m, "")
      |> String.trim()
      |> then(fn s ->
        case Regex.run(~r/\{.*\}/s, s) do
          [match] -> match
          nil -> s
        end
      end)

    case Jason.decode(cleaned) do
      {:ok, result} when is_map(result) ->
        segments =
          Enum.flat_map(ads, fn ad ->
            ad_id = ad["ad_id"]

            segs =
              Map.get(result, ad_id) ||
                Map.get(result, "ad_#{ad_id}") ||
                Map.get(result, "ad-#{ad_id}") ||
                Map.get(result, "AD_#{ad_id}")

            case segs do
              segs when is_list(segs) ->
                Enum.map(segs, &validate_segment(&1, ad_id))

              _ ->
                Logger.warning(
                  "no segments returned for ad_id=#{ad_id} (response keys: #{inspect(Map.keys(result) |> Enum.take(5))})"
                )

                []
            end
          end)

        {:ok, segments}

      {:ok, _other} ->
        {:error, :not_a_map}

      {:error, reason} ->
        {:error, {:json_parse, reason}}
    end
  end

  defp parse_batch_segments(_text, _ads), do: {:error, :missing_text}

  defp parse_segments(text, ad_id) when is_binary(text) do
    cleaned =
      text
      |> String.replace(~r/^```json\s*/m, "")
      |> String.replace(~r/^```\s*/m, "")
      |> String.replace(~r/\s*```$/m, "")
      |> String.trim()
      |> then(fn s ->
        case Regex.run(~r/\[.*\]/s, s) do
          [match] -> match
          nil -> s
        end
      end)

    case Jason.decode(cleaned) do
      {:ok, segments} when is_list(segments) ->
        {:ok, Enum.map(segments, &validate_segment(&1, ad_id))}

      {:ok, _other} ->
        {:error, :not_a_list}

      {:error, reason} ->
        {:error, {:json_parse, reason}}
    end
  end

  defp parse_segments(_text, _ad_id), do: {:error, :missing_text}

  defp validate_segment(segment, ad_id) when is_map(segment) do
    %{
      "segment_type" => normalize_segment_type(value_as_string(segment["segment_type"])),
      "format" => normalize_format(value_as_string(segment["format"])),
      "principle" => normalize_principle(segment["principle"]),
      "transcript" => value_as_string(segment["transcript"]),
      "why_it_works" => value_as_string(segment["why_it_works"]),
      "source_ad_id" => ad_id
    }
  end

  defp normalize_segment_type(""), do: "body"

  defp normalize_segment_type(value) do
    value
    |> String.downcase()
    |> String.replace("_", "-")
  end

  defp normalize_format(""), do: "mixed"
  defp normalize_format(value), do: value |> String.downcase() |> String.replace("_", "-")

  defp normalize_principle(values) when is_list(values) do
    values
    |> Enum.map(&value_as_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
  end

  defp normalize_principle(value), do: value_as_string(value)

  defp value_as_string(nil), do: ""
  defp value_as_string(value) when is_binary(value), do: String.trim(value)
  defp value_as_string(value), do: value |> to_string() |> String.trim()

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

  defp model do
    Application.get_env(:dailyrag, :claude_model, @default_model)
  end

  defp sleep_fun,
    do: Application.get_env(:dailyrag, :segmenter_sleep_fun, &Process.sleep/1)

  defp get_value(map, [key | rest], default) do
    case Map.get(map, key) do
      nil -> get_value(map, rest, default)
      value -> value
    end
  end

  defp get_value(_map, [], default), do: default
end
