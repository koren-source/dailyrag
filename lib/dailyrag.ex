defmodule DailyRag do
  @version "0.1.0"

  def version, do: @version

  def load_env do
    env_path = Path.join(File.cwd!(), ".env")

    if File.exists?(env_path) do
      env_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.each(fn line ->
        trimmed = String.trim(line)

        cond do
          trimmed == "" or String.starts_with?(trimmed, "#") ->
            :ok

          true ->
            case String.split(trimmed, "=", parts: 2) do
              [key, value] -> System.put_env(key, String.trim(value, ~s('")))
              _ -> :ok
            end
        end
      end)
    end
  end
end
