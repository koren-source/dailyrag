defmodule DailyRag.Segmenter do
  @moduledoc false

  require Logger

  alias DailyRag.Util

  @anthropic_version "2023-06-01"
  @max_ads_per_run 20
  @max_tokens 4_096
  @temperature 0
  @request_timeout_ms 30_000
  @retry_delays_ms [0, 2_000, 5_000, 10_000]
  @rate_limit_delay_ms 1_000

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
    ads
    |> Enum.take(@max_ads_per_run)
    |> Enum.map(&normalize_ad(&1, brand_name, vertical))
    |> Enum.reduce({[], false}, fn ad, {acc, has_called_api?} ->
      maybe_rate_limit(ad, has_called_api?)

      case segment_once(ad) do
        {:ok, segments, called_api?} ->
          {acc ++ segments, has_called_api? or called_api?}

        {:error, reason, called_api?} ->
          Logger.warning("segmentation failed for #{ad["ad_id"]}: #{inspect(reason)}")
          {acc, has_called_api? or called_api?}
      end
    end)
    |> then(fn {segments, _has_called_api?} -> {:ok, segments} end)
  end

  defp maybe_rate_limit(%{"copy_source" => "copy_unavailable"}, _has_called_api?), do: :ok
  defp maybe_rate_limit(_ad, false), do: :ok
  defp maybe_rate_limit(_ad, true), do: sleep_fun().(@rate_limit_delay_ms)

  defp segment_once(%{"copy_source" => "copy_unavailable"}), do: {:ok, [], false}

  defp segment_once(%{"copy" => copy}) when not is_binary(copy) or copy == "",
    do: {:ok, [], false}

  defp segment_once(ad) do
    payload = request_payload(ad)

    case request_with_retries(payload) do
      {:ok, body} ->
        with {:ok, text} <- extract_response_text(body),
             {:ok, segments} <- parse_segments(text, ad["ad_id"]) do
          {:ok, segments, true}
        else
          {:error, reason} -> {:error, reason, true}
        end

      {:error, reason} ->
        {:error, reason, true}
    end
  end

  defp request_with_retries(payload) do
    Enum.reduce_while(@retry_delays_ms, {:error, :unknown}, fn delay_ms, _acc ->
      if delay_ms > 0, do: sleep_fun().(delay_ms)

      case request_fun().(payload) do
        {:ok, body} ->
          {:halt, {:ok, body}}

        {:error, reason} ->
          Logger.warning("anthropic request failed: #{inspect(reason)}")
          {:cont, {:error, reason}}
      end
    end)
  end

  defp default_request(payload) do
    with {:ok, api_key} <- anthropic_api_key() do
      task =
        Task.async(fn ->
          Req.post(api_url(),
            headers: [
              {"x-api-key", api_key},
              {"anthropic-version", @anthropic_version},
              {"content-type", "application/json"}
            ],
            json: payload,
            connect_options: Util.req_connect_options(),
            retry: false
          )
        end)

      case Task.yield(task, @request_timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, %Req.Response{status: 200, body: body}}} ->
          {:ok, body}

        {:ok, {:ok, %Req.Response{status: status, body: body}}} ->
          {:error, {:http_error, status, body}}

        {:ok, {:error, reason}} ->
          {:error, reason}

        nil ->
          {:error, :timeout}
      end
    end
  end

  defp extract_response_text(%{"content" => content}) when is_list(content) do
    case Enum.find(content, &(Map.get(&1, "type") == "text")) do
      %{"text" => text} when is_binary(text) and text != "" -> {:ok, text}
      _ -> {:error, :missing_text_block}
    end
  end

  defp extract_response_text(_body), do: {:error, :unexpected_response_shape}

  defp request_payload(ad) do
    %{
      model: model(),
      max_tokens: @max_tokens,
      temperature: @temperature,
      system: "You are a video ad segmentation expert for Cutbox.ai. Return only valid JSON arrays.",
      messages: [
        %{
          role: "user",
          content: build_prompt(ad)
        }
      ]
    }
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

    RESPOND WITH ONLY a JSON array. No markdown, no explanation, no preamble:
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

  defp parse_segments(text, ad_id) when is_binary(text) do
    cleaned =
      text
      |> String.replace(~r/^```json\s*/m, "")
      |> String.replace(~r/^```\s*/m, "")
      |> String.replace(~r/\s*```$/m, "")
      |> String.trim()

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

  defp anthropic_api_key do
    case Application.get_env(:dailyrag, :anthropic_api_key) do
      api_key when is_binary(api_key) and api_key != "" -> {:ok, api_key}
      _ -> {:error, :missing_anthropic_api_key}
    end
  end

  defp model,
    do: Application.get_env(:dailyrag, :anthropic_model, "claude-opus-4-0-20250514")

  defp api_url,
    do: Application.get_env(:dailyrag, :anthropic_api_url, "https://api.anthropic.com/v1/messages")

  defp request_fun,
    do: Application.get_env(:dailyrag, :anthropic_request_fun, &default_request/1)

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
