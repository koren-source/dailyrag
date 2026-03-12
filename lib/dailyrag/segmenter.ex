defmodule DailyRag.Segmenter do
  require Logger

  alias DailyRag.Util

  @api_url "https://api.anthropic.com/v1/messages"
  @model "claude-sonnet-4-6"

  @spec segment_ads(String.t(), String.t(), [map()]) :: {:ok, [map()]} | {:error, term()}
  def segment_ads(brand_name, vertical, ads) do
    ads
    |> Enum.chunk_every(10)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      case call_claude(brand_name, vertical, batch) do
        {:ok, segments} -> {:cont, {:ok, acc ++ segments}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp call_claude(brand_name, vertical, ads_batch) do
    body = %{
      model: @model,
      max_tokens: 4096,
      system: system_prompt(),
      messages: [%{role: "user", content: build_user_prompt(brand_name, vertical, ads_batch)}]
    }

    do_call(body, 3, 2_000)
  end

  defp do_call(_body, 0, _delay), do: {:error, :max_retries}

  defp do_call(body, attempts, delay) do
    headers = [
      {"x-api-key", Application.fetch_env!(:dailyrag, :anthropic_api_key)},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]

    req_module = Application.get_env(:dailyrag, :segmenter_http_client, Req)

    case req_module.post(@api_url,
           headers: headers,
           json: body,
           connect_options: Util.req_connect_options()
         ) do
      {:ok, %Req.Response{status: 200, body: resp_body}} ->
        text = get_in(resp_body, ["content", Access.at(0), "text"])
        parse_segments(text)

      {:ok, %Req.Response{status: status, body: _resp_body}}
      when status in [429, 500, 502, 503, 529] ->
        Logger.warning("retrying Claude request after status #{status}")
        Process.sleep(delay)
        do_call(body, attempts - 1, delay * 2)

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        {:error, {:api_error, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
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
        headline = if ad["headline"] in [nil, ""], do: "", else: "\nHeadline: #{ad["headline"]}"
        "--- Ad #{i} (ID: #{ad["ad_id"]}) ---\n#{ad["copy"]}#{headline}"
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
