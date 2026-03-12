defmodule DailyRag.Segmentation do
  @moduledoc """
  Claude Sonnet 4.6 API integration for ad copy segmentation.
  Breaks raw ad copy into structured segments with analysis.
  """

  require Logger

  @api_url "https://api.anthropic.com/v1/messages"
  @model "claude-sonnet-4-6"
  @max_tokens 4096

  def segment_ad(brand_name, vertical, raw_copy, days_running) do
    api_key = System.get_env("ANTHROPIC_API_KEY")

    unless api_key do
      {:error, "ANTHROPIC_API_KEY not set"}
    else
      call_claude(api_key, brand_name, vertical, raw_copy, days_running)
    end
  end

  defp call_claude(api_key, brand_name, vertical, raw_copy, days_running) do
    body = %{
      "model" => @model,
      "max_tokens" => @max_tokens,
      "system" => system_prompt(),
      "messages" => [
        %{
          "role" => "user",
          "content" => user_prompt(brand_name, vertical, raw_copy, days_running)
        }
      ]
    }

    case Req.post(@api_url,
           headers: [
             {"x-api-key", api_key},
             {"anthropic-version", "2023-06-01"},
             {"content-type", "application/json"}
           ],
           json: body,
           receive_timeout: 60_000
         ) do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_response(resp_body)

      {:ok, %{status: status, body: resp_body}} ->
        Logger.error("Claude API error #{status}: #{inspect(resp_body)}")
        {:error, "Claude API returned #{status}"}

      {:error, reason} ->
        Logger.error("Claude API request failed: #{inspect(reason)}")
        {:error, "Claude API request failed: #{inspect(reason)}"}
    end
  end

  defp parse_response(%{"content" => [%{"text" => text} | _]}) do
    # Strip markdown code fences if present
    cleaned =
      text
      |> String.trim()
      |> String.replace(~r/^```json\s*/i, "")
      |> String.replace(~r/\s*```$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, segments} when is_list(segments) -> {:ok, segments}
      {:ok, _} -> {:error, "Claude returned non-array JSON"}
      {:error, reason} -> {:error, "Failed to parse Claude response: #{inspect(reason)}"}
    end
  end

  defp parse_response(other) do
    {:error, "Unexpected Claude response format: #{inspect(other)}"}
  end

  defp system_prompt do
    """
    You are an expert direct response advertising analyst. Your job is to analyze Meta ad copy and break it into structured segments. You must produce SHARP, SPECIFIC analysis — not generic observations.

    BAD: "Creates urgency"
    GOOD: "Triple-threat problem callout hits all 3 buyer objections simultaneously: taste, efficacy, price"

    BAD: "Builds social proof"
    GOOD: "Stacks 3 micro-credibility signals in 8 words: clinical study + athlete endorsement + review count"

    Every "Why It Works" must name the SPECIFIC mechanism, not just the category.
    """
  end

  defp user_prompt(brand_name, vertical, raw_copy, days_running) do
    """
    Analyze this Meta ad copy from #{brand_name} (#{vertical} vertical). Ad has been running for #{days_running} days.

    AD COPY:
    #{raw_copy}

    Return a JSON array of segments. Each segment must have:
    - segment_type: one of [hook, body, CTA, offer, social_proof, education, b_roll_direction]
    - principle: the advertising principle at work (be specific)
    - transcript: the exact text for this segment
    - why_it_works: sharp, specific analysis of why this segment is effective (2-3 sentences, name the mechanism)
    - format: detected ad format if determinable from copy (text-on-screen, talking-head, voiceover, etc.) or "unknown"

    Return ONLY valid JSON. No markdown, no explanation.
    """
  end
end
