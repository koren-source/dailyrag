defmodule Mix.Tasks.Dailyrag do
  use Mix.Task

  @shortdoc "Run the DailyRag enrichment pipeline"

  @switches [
    dry_run: :boolean,
    brand: :string,
    recover: :boolean,
    discover: :boolean,
    verbose: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    if Enum.any?(args, &(&1 in ["--help", "-h"])) do
      Mix.shell().info("""
      mix dailyrag [--dry-run] [--brand NAME] [--recover] [--discover] [--verbose]
      """)
    else
      {opts, _, _} = OptionParser.parse(args, switches: @switches)
      Mix.Task.run("app.start")

      opts_map = %{
        dry_run: Keyword.get(opts, :dry_run, false),
        brand: Keyword.get(opts, :brand),
        recover: Keyword.get(opts, :recover, false),
        discover: Keyword.get(opts, :discover, false),
        verbose: Keyword.get(opts, :verbose, false)
      }

      if opts_map.discover do
        DailyRag.Pipeline.Discovery.run(opts_map)
      else
        DailyRag.Pipeline.Daily.run(opts_map)
      end
    end
  end
end
