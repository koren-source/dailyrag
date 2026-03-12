defmodule DailyRag.Sheets do
  @moduledoc """
  Google Sheets API integration using OAuth2 token refresh.
  Handles tab creation, reading, writing, and appending to the master sheet.
  """

  require Logger

  @base_url "https://sheets.googleapis.com/v4/spreadsheets"

  @required_tabs [
    "Brand_Config",
    "Discovery_Keywords",
    "Discovery_Queue",
    "Supplements_Daily",
    "HomeServices_Daily",
    "Daily_Report"
  ]

  @brand_config_headers [
    "brand_name",
    "vertical",
    "meta_library_url",
    "status",
    "date_added",
    "source",
    "notes"
  ]

  @discovery_keywords_headers ["keyword", "vertical", "status", "date_added"]

  @daily_headers [
    "Entry #",
    "Segment Type",
    "Vertical",
    "Format",
    "Principle",
    "Transcript",
    "Why It Works",
    "Source Category",
    "Confidence",
    "Brand / Source Detail",
    "Notes",
    "date_discovered",
    "last_seen",
    "status",
    "ad_id"
  ]

  @daily_report_headers [
    "Date",
    "Total New Ads",
    "Total Decayed Ads",
    "Supplements New",
    "Home Services New",
    "Supplements Decayed",
    "Home Services Decayed",
    "Brand Breakdown (New)",
    "Brand Breakdown (Decayed)",
    "Total Active Tracked",
    "Total RAG Entries",
    "Errors"
  ]

  @initial_brands_supplements [
    {"BuckedUp", "dtc-supplements"},
    {"Ghost", "dtc-supplements"},
    {"Ryse", "dtc-supplements"},
    {"C4 Energy", "dtc-supplements"},
    {"Bloom Nutrition", "dtc-supplements"},
    {"Alani Nu", "dtc-supplements"},
    {"1st Phorm", "dtc-supplements"},
    {"Transparent Labs", "dtc-supplements"},
    {"Gorilla Mind", "dtc-supplements"},
    {"Raw Nutrition", "dtc-supplements"}
  ]

  @initial_brands_home_services [
    {"LeafFilter", "home-services"},
    {"Renewal by Andersen", "home-services"},
    {"TruGreen", "home-services"},
    {"SimpliSafe", "home-services"},
    {"American Home Shield", "home-services"},
    {"Remi Construction", "home-services"},
    {"Power Home Remodeling", "home-services"},
    {"Trex", "home-services"}
  ]

  @supplements_keywords [
    "pre workout",
    "protein powder",
    "creatine",
    "BCAAs",
    "fat burner",
    "greens powder",
    "collagen supplement",
    "energy drink",
    "sports nutrition",
    "mass gainer",
    "amino acids",
    "multivitamin fitness",
    "post workout recovery"
  ]

  @home_services_keywords [
    "roofing contractor",
    "gutter installation",
    "window replacement",
    "HVAC repair",
    "lawn care service",
    "home security system",
    "deck builder",
    "solar installation",
    "home warranty",
    "siding replacement",
    "water damage restoration",
    "pest control",
    "garage door repair"
  ]

  # --- Public API ---

  def sheet_id do
    Application.get_env(
      :dailyrag,
      :sheet_id,
      "1nbVDvlICkkgzb-X678q6F2Y87ZiOV0B_xAobXtLsJd0"
    )
  end

  def ensure_tabs do
    Logger.info("Ensuring all required tabs exist...")

    case get_metadata() do
      {:ok, metadata} ->
        existing =
          metadata["sheets"]
          |> Enum.map(fn s -> s["properties"]["title"] end)

        missing = @required_tabs -- existing

        if missing != [] do
          Logger.info("Creating missing tabs: #{inspect(missing)}")
          requests = Enum.map(missing, fn title -> add_sheet_request(title) end)

          case batch_update(requests) do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, "Failed to create tabs: #{inspect(reason)}"}
          end
        else
          :ok
        end
        |> case do
          :ok -> initialize_tabs(existing)
          error -> error
        end

      {:error, reason} ->
        {:error, "Failed to get sheet metadata: #{inspect(reason)}"}
    end
  end

  def read_brands do
    case get_values("Brand_Config!A2:G") do
      {:ok, %{"values" => rows}} ->
        brands =
          Enum.map(rows, fn row ->
            %{
              "brand_name" => Enum.at(row, 0, ""),
              "vertical" => Enum.at(row, 1, ""),
              "meta_library_url" => Enum.at(row, 2, ""),
              "status" => Enum.at(row, 3, ""),
              "date_added" => Enum.at(row, 4, ""),
              "source" => Enum.at(row, 5, ""),
              "notes" => Enum.at(row, 6, "")
            }
          end)
          |> Enum.filter(fn b -> b["status"] == "active" end)

        {:ok, brands}

      {:ok, _} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def read_discovery_keywords do
    case get_values("Discovery_Keywords!A2:D") do
      {:ok, %{"values" => rows}} ->
        keywords =
          Enum.map(rows, fn row ->
            %{
              "keyword" => Enum.at(row, 0, ""),
              "vertical" => Enum.at(row, 1, ""),
              "status" => Enum.at(row, 2, ""),
              "date_added" => Enum.at(row, 3, "")
            }
          end)
          |> Enum.filter(fn k -> k["status"] == "active" end)

        {:ok, keywords}

      {:ok, _} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def append_daily_rows(tab, rows) do
    case append_rows("#{tab}!A:O", rows) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def get_next_entry_number(tab) do
    prefix = if tab == "Supplements_Daily", do: "SD", else: "HD"

    case get_values("#{tab}!A:A") do
      {:ok, %{"values" => rows}} ->
        last =
          rows
          |> List.flatten()
          |> Enum.filter(&String.starts_with?(&1, prefix))
          |> Enum.map(fn entry ->
            entry
            |> String.replace(~r/^[A-Z]+-/, "")
            |> String.to_integer()
          end)
          |> Enum.max(fn -> 0 end)

        last + 1

      _ ->
        1
    end
  end

  def read_daily_sheet(tab) do
    case get_values("#{tab}!A2:O") do
      {:ok, %{"values" => rows}} -> {:ok, rows}
      {:ok, _} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  def update_cell(tab, row_num, col_letter, value) do
    range = "#{tab}!#{col_letter}#{row_num}"

    case put_values(range, [[value]]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def update_row_status(tab, row_num, status, last_seen) do
    # N = status (col 14), M = last_seen (col 13)
    with :ok <- update_cell(tab, row_num, "N", status),
         :ok <- update_cell(tab, row_num, "M", last_seen) do
      :ok
    end
  end

  def update_confidence(tab, row_num, confidence) do
    update_cell(tab, row_num, "I", confidence)
  end

  def find_rows_by_ad_id(tab, ad_id) do
    case get_values("#{tab}!O:O") do
      {:ok, %{"values" => rows}} ->
        rows
        |> Enum.with_index(1)
        |> Enum.filter(fn {row, _idx} -> List.first(row) == ad_id end)
        |> Enum.map(fn {_row, idx} -> idx + 1 end)

      _ ->
        []
    end
  end

  def append_discovery_queue_rows(rows) do
    append_rows("Discovery_Queue!A:F", rows)
  end

  def read_discovery_queue do
    case get_values("Discovery_Queue!A2:F") do
      {:ok, %{"values" => rows}} -> {:ok, rows}
      {:ok, _} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  def append_brand_config_rows(rows) do
    append_rows("Brand_Config!A:G", rows)
  end

  def append_daily_report_row(row) do
    append_rows("Daily_Report!A:L", [row])
  end

  def read_all_brand_names do
    case get_values("Brand_Config!A2:A") do
      {:ok, %{"values" => rows}} -> {:ok, List.flatten(rows)}
      {:ok, _} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Tab Initialization ---

  defp initialize_tabs(existing_before) do
    today = Date.utc_today() |> Date.to_iso8601()

    # Initialize Brand_Config if it was just created or is empty
    with :ok <- maybe_init_brand_config(existing_before, today),
         :ok <- maybe_init_discovery_keywords(existing_before, today),
         :ok <- maybe_init_daily("Supplements_Daily", existing_before),
         :ok <- maybe_init_daily("HomeServices_Daily", existing_before),
         :ok <- maybe_init_daily_report(existing_before),
         :ok <- maybe_init_discovery_queue(existing_before) do
      :ok
    end
  end

  defp maybe_init_brand_config(_existing_before, today) do
    case get_values("Brand_Config!A1:G1") do
      {:ok, %{"values" => [_headers | _]}} ->
        :ok

      _ ->
        Logger.info("Initializing Brand_Config with headers and starter brands...")
        lib_url = fn name ->
          encoded = URI.encode(name)
          "https://www.facebook.com/ads/library/?active_status=active&ad_type=all&country=US&q=#{encoded}"
        end

        brand_rows =
          (@initial_brands_supplements ++ @initial_brands_home_services)
          |> Enum.map(fn {name, vertical} ->
            [name, vertical, lib_url.(name), "active", today, "seed", ""]
          end)

        all_rows = [@brand_config_headers | brand_rows]

        case put_values("Brand_Config!A1:G#{length(all_rows)}", all_rows) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp maybe_init_discovery_keywords(_existing_before, today) do
    case get_values("Discovery_Keywords!A1:D1") do
      {:ok, %{"values" => [_headers | _]}} ->
        :ok

      _ ->
        Logger.info("Initializing Discovery_Keywords...")

        keyword_rows =
          Enum.map(@supplements_keywords, fn kw ->
            [kw, "dtc-supplements", "active", today]
          end) ++
            Enum.map(@home_services_keywords, fn kw ->
              [kw, "home-services", "active", today]
            end)

        all_rows = [@discovery_keywords_headers | keyword_rows]

        case put_values("Discovery_Keywords!A1:D#{length(all_rows)}", all_rows) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp maybe_init_daily(tab, _existing_before) do
    case get_values("#{tab}!A1:O1") do
      {:ok, %{"values" => [_headers | _]}} ->
        :ok

      _ ->
        Logger.info("Initializing #{tab} headers...")

        case put_values("#{tab}!A1:O1", [@daily_headers]) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp maybe_init_daily_report(_existing_before) do
    case get_values("Daily_Report!A1:L1") do
      {:ok, %{"values" => [_headers | _]}} ->
        :ok

      _ ->
        Logger.info("Initializing Daily_Report headers...")

        case put_values("Daily_Report!A1:L1", [@daily_report_headers]) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp maybe_init_discovery_queue(_existing_before) do
    headers = ["brand_name", "vertical", "meta_library_url", "status", "date_found", "keyword_source"]

    case get_values("Discovery_Queue!A1:F1") do
      {:ok, %{"values" => [_headers | _]}} ->
        :ok

      _ ->
        Logger.info("Initializing Discovery_Queue headers...")

        case put_values("Discovery_Queue!A1:F1", [headers]) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # --- Low-Level Sheets API ---

  def get_metadata do
    api_request(:get, "")
  end

  def get_values(range) do
    api_request(:get, "/values/#{URI.encode(range)}")
  end

  def put_values(range, values) do
    api_request(:put, "/values/#{URI.encode(range)}?valueInputOption=USER_ENTERED",
      json: %{"values" => values}
    )
  end

  def append_rows(range, values) do
    api_request(
      :post,
      "/values/#{URI.encode(range)}:append?valueInputOption=USER_ENTERED&insertDataOption=INSERT_ROWS",
      json: %{"values" => values}
    )
  end

  def batch_update(requests) do
    api_request(:post, ":batchUpdate", json: %{"requests" => requests})
  end

  defp add_sheet_request(title) do
    %{"addSheet" => %{"properties" => %{"title" => title}}}
  end

  # --- Auth & HTTP ---

  defp api_request(method, path, opts \\ []) do
    url = "#{@base_url}/#{sheet_id()}#{path}"
    do_request(method, url, opts, _retries = 3, _refreshed = false)
  end

  defp do_request(_method, _url, _opts, 0, _refreshed) do
    {:error, "Sheets API: max retries exceeded"}
  end

  defp do_request(method, url, opts, retries, refreshed) do
    token = get_access_token()
    headers = [{"authorization", "Bearer #{token}"} | Keyword.get(opts, :headers, [])]
    req_opts = Keyword.put(opts, :headers, headers)

    case Req.request([method: method, url: url] ++ req_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: 401}} when not refreshed ->
        Logger.info("Sheets token expired, refreshing...")
        refresh_access_token()
        do_request(method, url, opts, retries, true)

      {:ok, %{status: 429}} ->
        wait = trunc(:math.pow(2, 4 - retries) * 1000)
        Logger.warning("Sheets rate limited, waiting #{wait}ms...")
        Process.sleep(wait)
        do_request(method, url, opts, retries - 1, refreshed)

      {:ok, %{status: status, body: _body}} when status >= 500 ->
        wait = trunc(:math.pow(2, 4 - retries) * 1000)
        Logger.warning("Sheets server error #{status}, retrying in #{wait}ms...")
        Process.sleep(wait)
        do_request(method, url, opts, retries - 1, refreshed)

      {:ok, %{status: status, body: body}} ->
        Logger.error("Sheets API error #{status}: #{inspect(body)}")
        {:error, "Sheets API #{status}: #{inspect(body)}"}

      {:error, reason} ->
        Logger.error("Sheets request failed: #{inspect(reason)}")

        if retries > 1 do
          Process.sleep(1000)
          do_request(method, url, opts, retries - 1, refreshed)
        else
          {:error, "Sheets request failed: #{inspect(reason)}"}
        end
    end
  end

  defp get_access_token do
    # Check process dictionary cache first
    case Process.get(:sheets_access_token) do
      nil ->
        token = read_token_from_file()
        Process.put(:sheets_access_token, token)
        token

      token ->
        token
    end
  end

  defp read_token_from_file do
    path = Application.get_env(:dailyrag, :google_credentials_path)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> data["token"] || data["access_token"] || ""
          _ -> ""
        end

      {:error, _} ->
        Logger.error("Cannot read Google credentials from #{path}")
        ""
    end
  end

  defp refresh_access_token do
    cred_path = Application.get_env(:dailyrag, :google_credentials_path)
    oauth_path = Application.get_env(:dailyrag, :google_oauth_path)

    with {:ok, cred_raw} <- File.read(cred_path),
         {:ok, cred_data} <- Jason.decode(cred_raw),
         {:ok, oauth_raw} <- File.read(oauth_path),
         {:ok, oauth_data} <- Jason.decode(oauth_raw) do
      client = oauth_data["installed"] || oauth_data

      case Req.post("https://oauth2.googleapis.com/token",
             form: [
               grant_type: "refresh_token",
               refresh_token: cred_data["refresh_token"],
               client_id: client["client_id"],
               client_secret: client["client_secret"]
             ]
           ) do
        {:ok, %{status: 200, body: %{"access_token" => new_token}}} ->
          # Update cached token
          Process.put(:sheets_access_token, new_token)

          # Save to file
          updated = Map.put(cred_data, "token", new_token)
          File.write!(cred_path, Jason.encode!(updated, pretty: true))
          Logger.info("Google token refreshed successfully")
          :ok

        {:ok, %{status: status, body: body}} ->
          Logger.error("Token refresh failed (#{status}): #{inspect(body)}")
          {:error, "Token refresh failed"}

        {:error, reason} ->
          Logger.error("Token refresh request failed: #{inspect(reason)}")
          {:error, reason}
      end
    else
      error ->
        Logger.error("Cannot read credential files for refresh: #{inspect(error)}")
        {:error, "Cannot read credential files"}
    end
  end
end
