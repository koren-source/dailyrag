defmodule DailyRag.SeedSheet do
  alias DailyRag.Sheets.{Client, TabInit}

  @brand_rows [
    ["BuckedUp", "dtc-supplements", "https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&q=BuckedUp", "active", "2026-03-12", "manual"],
    ["Ghost", "dtc-supplements", "https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&q=Ghost+energy", "active", "2026-03-12", "manual"],
    ["Ryse", "dtc-supplements", "https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&q=Ryse+Supps", "active", "2026-03-12", "manual"],
    ["C4 Energy", "dtc-supplements", "https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&q=C4+Energy", "active", "2026-03-12", "manual"],
    ["Bloom Nutrition", "dtc-supplements", "https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&q=Bloom+Nutrition", "active", "2026-03-12", "manual"],
    ["Alani Nu", "dtc-supplements", "https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&q=Alani+Nu", "active", "2026-03-12", "manual"],
    ["1st Phorm", "dtc-supplements", "https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&q=1st+Phorm", "active", "2026-03-12", "manual"],
    ["Transparent Labs", "dtc-supplements", "https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&q=Transparent+Labs", "active", "2026-03-12", "manual"],
    ["Gorilla Mind", "dtc-supplements", "https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&q=Gorilla+Mind", "active", "2026-03-12", "manual"],
    ["Raw Nutrition", "dtc-supplements", "https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&q=Raw+Nutrition", "active", "2026-03-12", "manual"],
    ["LeafFilter", "home-services", "https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&q=LeafFilter", "active", "2026-03-12", "manual"],
    ["Renewal by Andersen", "home-services", "https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&q=Renewal+by+Andersen", "active", "2026-03-12", "manual"],
    ["TruGreen", "home-services", "https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&q=TruGreen", "active", "2026-03-12", "manual"],
    ["SimpliSafe", "home-services", "https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&q=SimpliSafe", "active", "2026-03-12", "manual"],
    ["American Home Shield", "home-services", "https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&q=American+Home+Shield", "active", "2026-03-12", "manual"],
    ["Remi Construction", "home-services", "https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&q=Remi+Construction", "active", "2026-03-12", "manual"],
    ["Power Home Remodeling", "home-services", "https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&q=Power+Home+Remodeling", "active", "2026-03-12", "manual"],
    ["Trex", "home-services", "https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&q=Trex+decking", "active", "2026-03-12", "manual"]
  ]

  @keyword_rows [
    ["pre workout", "dtc-supplements", "active"],
    ["protein powder", "dtc-supplements", "active"],
    ["creatine", "dtc-supplements", "active"],
    ["BCAAs", "dtc-supplements", "active"],
    ["fat burner", "dtc-supplements", "active"],
    ["greens powder", "dtc-supplements", "active"],
    ["collagen supplement", "dtc-supplements", "active"],
    ["energy drink", "dtc-supplements", "active"],
    ["sports nutrition", "dtc-supplements", "active"],
    ["mass gainer", "dtc-supplements", "active"],
    ["amino acids", "dtc-supplements", "active"],
    ["multivitamin fitness", "dtc-supplements", "active"],
    ["post workout recovery", "dtc-supplements", "active"],
    ["roofing contractor", "home-services", "active"],
    ["gutter installation", "home-services", "active"],
    ["window replacement", "home-services", "active"],
    ["HVAC repair", "home-services", "active"],
    ["lawn care service", "home-services", "active"],
    ["home security system", "home-services", "active"],
    ["deck builder", "home-services", "active"],
    ["solar installation", "home-services", "active"],
    ["home warranty", "home-services", "active"],
    ["siding replacement", "home-services", "active"],
    ["water damage restoration", "home-services", "active"],
    ["pest control", "home-services", "active"],
    ["garage door repair", "home-services", "active"]
  ]

  def run do
    start_apps()
    configure_env()

    sheet_id = Application.fetch_env!(:dailyrag, :sheet_id)
    TabInit.ensure_tabs!(sheet_id)

    seed_if_empty(sheet_id, "Brand_Config!A:F", @brand_rows, "Brand_Config")
    seed_if_empty(sheet_id, "Discovery_Keywords!A:C", @keyword_rows, "Discovery_Keywords")
  end

  defp seed_if_empty(sheet_id, range, rows_to_append, label) do
    case Client.read_range(sheet_id, range) do
      {:ok, rows} when length(rows) <= 1 ->
        :ok = Client.append_rows(sheet_id, range, rows_to_append)
        IO.puts("Seeded #{label} with #{length(rows_to_append)} rows")

      {:ok, rows} ->
        IO.puts("Skipped #{label}; already has #{max(length(rows) - 1, 0)} data rows")

      {:error, reason} ->
        raise "failed to seed #{label}: #{inspect(reason)}"
    end
  end

  defp start_apps do
    [:crypto, :asn1, :public_key, :ssl, :inets, :logger, :telemetry, :mime, :nimble_pool, :mint, :hpax, :finch, :req]
    |> Enum.each(fn app ->
      case Application.ensure_all_started(app) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, reason} -> raise "failed to start #{app}: #{inspect(reason)}"
      end
    end)
  end

  defp configure_env do
    Application.put_env(:dailyrag, :slack_bot_token, System.get_env("SLACK_BOT_TOKEN"))
    Application.put_env(:dailyrag, :sheet_id, System.get_env("GOOGLE_SHEET_ID"))
    Application.put_env(:dailyrag, :slack_channel, System.get_env("SLACK_RAG_BUILDER_CHANNEL"))
    Application.put_env(:dailyrag, :python_path, System.get_env("PYTHON_PATH", "python3"))
    Application.put_env(:dailyrag, :google_credentials_path, System.get_env("GOOGLE_CREDENTIALS_PATH"))
    Application.put_env(:dailyrag, :google_oauth_path, System.get_env("GOOGLE_OAUTH_PATH"))
  end
end

DailyRag.SeedSheet.run()
