defmodule DailyRag.Slack do
  @api_url "https://slack.com/api/chat.postMessage"

  alias DailyRag.Util

  @spec post(String.t()) :: :ok | {:error, term()}
  def post(text), do: send_payload(%{text: text})

  @spec post_blocks(String.t(), [map()]) :: :ok | {:error, term()}
  def post_blocks(text, blocks), do: send_payload(%{text: text, blocks: blocks})

  @spec daily_summary(map()) :: String.t()
  def daily_summary(stats) do
    errors =
      stats
      |> Map.get(:errors, [])
      |> Enum.join(" | ")

    """
    DailyRag daily run complete for #{Map.get(stats, :date, DailyRag.Util.today())}
    Brands scraped: #{Map.get(stats, :brands_scraped, 0)}
    Brands segmented today: #{Map.get(stats, :brands_segmented, []) |> Enum.join(", ")}
    Segmentation queue: #{Map.get(stats, :segmentation_queue, "")}
    Total new ads: #{Map.get(stats, :total_new_ads, 0)}
    Total segmented: #{Map.get(stats, :total_segmented, 0)}
    Total decayed ads: #{Map.get(stats, :total_decayed_ads, 0)}
    Supplements new/decayed: #{Map.get(stats, :supplements_new, 0)}/#{Map.get(stats, :supplements_decayed, 0)}
    Home services new/decayed: #{Map.get(stats, :home_services_new, 0)}/#{Map.get(stats, :home_services_decayed, 0)}
    Total active tracked: #{Map.get(stats, :total_active_tracked, 0)}
    Total RAG entries: #{Map.get(stats, :total_rag_entries, 0)}
    Confidence upgrades: #{Map.get(stats, :confidence_upgrades, 0)}
    Errors: #{if errors == "", do: "0", else: errors}
    Duration (s): #{Map.get(stats, :duration_s, 0)}
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
