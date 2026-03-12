defmodule DailyRag.Slack do
  @api_url "https://slack.com/api/chat.postMessage"

  alias DailyRag.Util

  @spec post(String.t()) :: :ok | {:error, term()}
  def post(text), do: send_payload(%{text: text})

  @spec post_blocks(String.t(), [map()]) :: :ok | {:error, term()}
  def post_blocks(text, blocks), do: send_payload(%{text: text, blocks: blocks})

  @spec daily_summary(map()) :: String.t()
  def daily_summary(stats) do
    warnings =
      stats
      |> Map.get(:warnings, [])
      |> Enum.map(&"- #{&1}")
      |> Enum.join("\n")

    """
    DailyRag daily run complete for #{Map.get(stats, :date, DailyRag.Util.today())}
    Brands processed: #{Map.get(stats, :brands_processed, 0)}
    New ads found: #{Map.get(stats, :new_ads, 0)}
    Ads decayed: #{Map.get(stats, :decayed, 0)}
    Confidence upgrades: #{Map.get(stats, :upgrades, 0)}
    Errors: #{Map.get(stats, :errors, 0)}
    Duration (s): #{Map.get(stats, :duration_s, 0)}
    #{if warnings == "", do: "", else: "Warnings:\n#{warnings}"}
    """
    |> String.trim()
  end

  @spec discovery_summary(map()) :: String.t()
  def discovery_summary(stats) do
    """
    DailyRag discovery run complete for #{Map.get(stats, :date, DailyRag.Util.today())}
    Keywords processed: #{Map.get(stats, :keywords_processed, 0)}
    New brands queued: #{Map.get(stats, :new_brands, 0)}
    Promoted brands: #{Map.get(stats, :promoted, 0)}
    Errors: #{Map.get(stats, :errors, 0)}
    """
    |> String.trim()
  end

  @spec canary_warning(String.t(), integer()) :: String.t()
  def canary_warning(brand_name, yesterday_count) do
    "DailyRag canary warning: #{brand_name} had #{yesterday_count} ads yesterday and 0 today. Scraper DOM/GraphQL may have changed."
  end

  defp send_payload(payload) do
    token = Application.fetch_env!(:dailyrag, :slack_bot_token)
    channel = Application.fetch_env!(:dailyrag, :slack_channel)

    case Req.post(@api_url,
           headers: [{"authorization", "Bearer #{token}"}],
           json: Map.put(payload, :channel, channel),
           connect_options: Util.req_connect_options()
         ) do
      {:ok, %Req.Response{status: 200, body: %{"ok" => true}}} -> :ok
      {:ok, %Req.Response{status: 200, body: body}} -> {:error, body}
      {:ok, %Req.Response{} = response} -> {:error, response}
      {:error, reason} -> {:error, reason}
    end
  end
end
