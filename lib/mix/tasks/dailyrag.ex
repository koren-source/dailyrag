defmodule Mix.Tasks.Dailyrag do
  @moduledoc """
  Main entry point for the DailyRag pipeline.

  ## Usage

      mix dailyrag [options]

  ## Options

      --dry-run      Run full pipeline but don't write to Sheets or dedup index
      --brand NAME   Run for a single brand only (exact match from Brand_Config)
      --recover      Resume from last successful brand checkpoint
      --discover     Run the weekly brand discovery workflow
      --verbose      Extended logging to stdout
  """

  use Mix.Task

  @shortdoc "Run the DailyRag ad enrichment pipeline"

  @switches [
    dry_run: :boolean,
    brand: :string,
    recover: :boolean,
    discover: :boolean,
    verbose: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    # Start required applications
    Mix.Task.run("app.start")

    # Load .env
    DailyRag.load_env()

    # Parse CLI flags
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    opts = Enum.into(opts, %{})

    if opts[:discover] do
      DailyRag.Discovery.run(opts)
    else
      DailyRag.Pipeline.run(opts)
    end
  end
end
