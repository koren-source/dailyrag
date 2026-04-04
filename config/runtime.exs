import Config

env_file =
  case File.read(Path.expand("../.env", __DIR__)) do
    {:ok, content} ->
      content
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        trimmed = String.trim(line)

        cond do
          trimmed == "" or String.starts_with?(trimmed, "#") ->
            acc

          true ->
            case String.split(trimmed, "=", parts: 2) do
              [key, value] ->
                Map.put(acc, key, String.trim(value, ~s('")))

              _ ->
                acc
            end
        end
      end)

    {:error, _} ->
      %{}
  end

env = Map.merge(env_file, System.get_env())

config :dailyrag,
  anthropic_api_key: Map.get(env, "ANTHROPIC_API_KEY", ""),
  claude_model: Map.get(env, "CLAUDE_MODEL", "claude-sonnet-4-6"),
  slack_bot_token: Map.get(env, "SLACK_BOT_TOKEN"),
  sheet_id: Map.get(env, "GOOGLE_SHEET_ID", "1nbVDvlICkkgzb-X678q6F2Y87ZiOV0B_xAobXtLsJd0"),
  slack_channel: Map.get(env, "SLACK_RAG_BUILDER_CHANNEL", "C0ALMSS92FK"),
  python_path: Map.get(env, "PYTHON_PATH", "python3"),
  google_credentials_path:
    Map.get(
      env,
      "GOOGLE_CREDENTIALS_PATH",
      "/Users/q/.openclaw/workspace/credentials/google-token.json"
    ),
  google_oauth_path:
    Map.get(
      env,
      "GOOGLE_OAUTH_PATH",
      "/Users/q/.openclaw/workspace/credentials/google-oauth.json"
    )
