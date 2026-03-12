defmodule DailyRag.Util do
  @spec atomic_write!(String.t(), String.t()) :: :ok
  def atomic_write!(path, content) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    tmp_path = path <> ".tmp"
    File.write!(tmp_path, content)
    File.rename!(tmp_path, path)
    :ok
  end

  @spec ensure_data_dir!() :: :ok
  def ensure_data_dir! do
    File.mkdir_p!("data")
    :ok
  end

  @spec today() :: String.t()
  def today, do: Date.utc_today() |> Date.to_iso8601()

  @spec parse_date(String.t()) :: Date.t()
  def parse_date(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} ->
        date

      {:error, reason} ->
        raise ArgumentError, "invalid ISO8601 date #{inspect(date_string)}: #{inspect(reason)}"
    end
  end

  @spec utc_now() :: String.t()
  def utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  @spec req_connect_options() :: keyword()
  def req_connect_options do
    [
      transport_opts: [
        cacertfile: System.get_env("SSL_CERT_FILE", "/opt/homebrew/etc/openssl@3/cert.pem")
      ]
    ]
  end
end
