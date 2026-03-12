defmodule Goth do
  use GenServer

  alias DailyRag.Util

  @token_url "https://oauth2.googleapis.com/token"

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    source = Keyword.fetch!(opts, :source)
    GenServer.start_link(__MODULE__, source, name: name)
  end

  def fetch(server) do
    GenServer.call(server, :fetch, 30_000)
  end

  @impl true
  def init({:refresh_token, credentials}) do
    {:ok, %{credentials: credentials, token: nil}}
  end

  @impl true
  def handle_call(:fetch, _from, state) do
    case ensure_token(state) do
      {:ok, token, next_state} -> {:reply, {:ok, token}, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp ensure_token(%{token: %{expires_at: expires_at} = token} = state) do
    if DateTime.compare(expires_at, DateTime.add(DateTime.utc_now(), 60, :second)) == :gt do
      {:ok, token, state}
    else
      refresh_token(state)
    end
  end

  defp ensure_token(state), do: refresh_token(state)

  defp refresh_token(%{credentials: credentials} = state) do
    body =
      URI.encode_query(%{
        "client_id" => credentials["client_id"],
        "client_secret" => credentials["client_secret"],
        "refresh_token" => credentials["refresh_token"],
        "grant_type" => "refresh_token"
      })

    case Req.post(@token_url,
           headers: [{"content-type", "application/x-www-form-urlencoded"}],
           body: body,
           retry: false,
           connect_options: Util.req_connect_options()
         ) do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => access_token} = body_resp}} ->
        expires_in = body_resp["expires_in"] || 3600

        token = %{
          token: access_token,
          expires_at: DateTime.add(DateTime.utc_now(), expires_in, :second)
        }

        {:ok, token, %{state | token: token}}

      {:ok, %Req.Response{} = response} ->
        {:error, response}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
