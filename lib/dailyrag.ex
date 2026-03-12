defmodule DailyRag do
  @moduledoc """
  DailyRag - Daily RAG enrichment pipeline for ad creative analysis.
  Scrapes Meta Ad Library, segments ads with Claude, writes to Google Sheets.
  """

  def load_env do
    env_path = Path.join(File.cwd!(), ".env")

    if File.exists?(env_path) do
      env_path
      |> DotenvParser.parse_file()
      |> Enum.each(fn {key, value} ->
        System.put_env(key, value)
      end)
    end
  end
end
