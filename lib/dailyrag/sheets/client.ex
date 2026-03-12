defmodule DailyRag.Sheets.Client do
  require Logger

  alias DailyRag.Util

  @base "https://sheets.googleapis.com/v4/spreadsheets"

  def list_tabs(sheet_id) do
    request(:get, "#{@base}/#{sheet_id}?fields=sheets.properties.title")
    |> case do
      {:ok, %{"sheets" => sheets}} ->
        {:ok, Enum.map(sheets, &get_in(&1, ["properties", "title"]))}

      error ->
        error
    end
  end

  def read_range(sheet_id, range) do
    request(:get, "#{@base}/#{sheet_id}/values/#{URI.encode(range)}")
    |> case do
      {:ok, body} -> {:ok, Map.get(body, "values", [])}
      error -> error
    end
  end

  def append_rows(sheet_id, range, rows) do
    request(
      :post,
      "#{@base}/#{sheet_id}/values/#{URI.encode(range)}:append?valueInputOption=USER_ENTERED&insertDataOption=INSERT_ROWS",
      %{values: rows}
    )
    |> normalize_ok()
  end

  def update_range(sheet_id, range, values) do
    request(
      :put,
      "#{@base}/#{sheet_id}/values/#{URI.encode(range)}?valueInputOption=USER_ENTERED",
      %{values: values}
    )
    |> normalize_ok()
  end

  def batch_update(sheet_id, updates) do
    request(:post, "#{@base}/#{sheet_id}/values:batchUpdate", %{
      valueInputOption: "USER_ENTERED",
      data: updates
    })
    |> normalize_ok()
  end

  def create_tab(sheet_id, title) do
    request(:post, "#{@base}/#{sheet_id}:batchUpdate", %{
      requests: [%{addSheet: %{properties: %{title: title}}}]
    })
    |> normalize_ok()
  end

  defp normalize_ok({:ok, _body}), do: :ok
  defp normalize_ok(error), do: error

  defp request(method, url, body \\ nil, retries \\ 3, refreshed \\ false)

  defp request(_method, _url, _body, 0, _refreshed), do: {:error, :max_retries}

  defp request(method, url, body, retries, refreshed) do
    with {:ok, token} <- access_token() do
      headers = [{"authorization", "Bearer #{token}"}]
      opts = [headers: headers]
      opts = if body, do: Keyword.put(opts, :json, body), else: opts

      opts = Keyword.put(opts, :connect_options, Util.req_connect_options())

      case Req.request([method: method, url: url] ++ opts) do
        {:ok, %Req.Response{status: status, body: response_body}} when status in 200..299 ->
          {:ok, response_body}

        {:ok, %Req.Response{status: 401}} when not refreshed ->
          with :ok <- refresh_access_token() do
            request(method, url, body, retries, true)
          end

        {:ok, %Req.Response{status: status}}
        when status in [429, 500, 502, 503, 504] and retries > 1 ->
          Process.sleep(trunc(:math.pow(2, 4 - retries) * 1000))
          request(method, url, body, retries - 1, refreshed)

        {:ok, %Req.Response{status: status, body: response_body}} ->
          {:error, "Sheets API #{status}: #{inspect(response_body)}"}

        {:error, reason} when retries > 1 ->
          Logger.warning("Retrying Sheets request after error: #{inspect(reason)}")
          Process.sleep(trunc(:math.pow(2, 4 - retries) * 1000))
          request(method, url, body, retries - 1, refreshed)

        {:error, reason} ->
          {:error, "Sheets request failed: #{inspect(reason)}"}
      end
    end
  end

  defp access_token do
    path = Application.fetch_env!(:dailyrag, :google_credentials_path)

    with {:ok, raw} <- File.read(path),
         {:ok, json} <- Jason.decode(raw) do
      token = json["token"] || json["access_token"]
      if token in [nil, ""], do: {:error, :missing_google_token}, else: {:ok, token}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_google_token_file}
    end
  end

  defp refresh_access_token do
    token_path = Application.fetch_env!(:dailyrag, :google_credentials_path)
    oauth_path = Application.fetch_env!(:dailyrag, :google_oauth_path)

    with {:ok, token_raw} <- File.read(token_path),
         {:ok, token_json} <- Jason.decode(token_raw),
         {:ok, oauth_raw} <- File.read(oauth_path),
         {:ok, oauth_json} <- Jason.decode(oauth_raw) do
      client = oauth_json["installed"] || oauth_json

      case Req.post("https://oauth2.googleapis.com/token",
             form: [
               grant_type: "refresh_token",
               refresh_token: token_json["refresh_token"],
               client_id: client["client_id"],
               client_secret: client["client_secret"]
             ],
             connect_options: Util.req_connect_options()
           ) do
        {:ok, %Req.Response{status: 200, body: %{"access_token" => access_token}}} ->
          updated = Map.put(token_json, "token", access_token)
          File.write!(token_path, Jason.encode!(updated, pretty: true))
          :ok

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, "Google token refresh failed #{status}: #{inspect(body)}"}

        {:error, reason} ->
          {:error, "Google token refresh failed: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_google_oauth_files}
    end
  end
end
