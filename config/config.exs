import Config

config :dailyrag,
  sheet_id: System.get_env("GOOGLE_SHEET_ID") || "1nbVDvlICkkgzb-X678q6F2Y87ZiOV0B_xAobXtLsJd0",
  slack_channel: System.get_env("SLACK_RAG_BUILDER_CHANNEL") || "C0ALMSS92FK",
  google_credentials_path:
    System.get_env("GOOGLE_CREDENTIALS_PATH") ||
      "/Users/q/.openclaw/workspace/credentials/google-token.json",
  google_oauth_path:
    System.get_env("GOOGLE_OAUTH_PATH") ||
      "/Users/q/.openclaw/workspace/credentials/google-oauth.json"
