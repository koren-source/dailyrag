defmodule DailyRag.Slack do
  @moduledoc """
  Slack integration — posts messages to #rag-builder via Bot token.
  """

  require Logger

  @api_url "https://slack.com/api/chat.postMessage"

  def post_message(text) do
    token = System.get_env("SLACK_BOT_TOKEN")
    channel = Application.get_env(:dailyrag, :slack_channel, "C0ALMSS92FK")

    unless token do
      Logger.warning("SLACK_BOT_TOKEN not set — skipping Slack post")
      {:error, :no_token}
    else
      do_post(token, channel, text)
    end
  end

  defp do_post(token, channel, text) do
    case Req.post(@api_url,
           headers: [
             {"authorization", "Bearer #{token}"},
             {"content-type", "application/json"}
           ],
           json: %{"channel" => channel, "text" => text}
         ) do
      {:ok, %{status: 200, body: %{"ok" => true}}} ->
        :ok

      {:ok, %{body: %{"ok" => false, "error" => error}}} ->
        Logger.error("Slack API error: #{error}")
        {:error, error}

      {:ok, %{status: status}} ->
        Logger.error("Slack HTTP error: #{status}")
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        Logger.error("Slack request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
