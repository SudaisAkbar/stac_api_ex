defmodule Mix.Tasks.Stac.BackfillTemporal do
  @moduledoc """
  Backfill the temporal columns on existing items and canonicalize the datetime
  strings stored in `properties`. See `StacApi.Data.TemporalBackfill` for what it
  changes and why.

  Idempotent — a second run over already-consistent data reports zero rows.

  ## Examples

      mix stac.backfill_temporal --dry-run
      mix stac.backfill_temporal
      mix stac.backfill_temporal --batch-size 2000

  In production the app runs as a release, where Mix is unavailable. Use the
  release entry point instead:

      bin/stac_api eval 'StacApi.Release.backfill_temporal(["--dry-run"])'
      bin/stac_api eval 'StacApi.Release.backfill_temporal()'
  """

  use Mix.Task

  alias StacApi.Data.TemporalBackfill

  @shortdoc "Backfill item temporal columns and normalize properties datetimes"

  @switches [dry_run: :boolean, batch_size: :integer]

  @impl Mix.Task
  def run(args) do
    {opts, _argv} = OptionParser.parse!(args, strict: @switches)

    Mix.Task.run("app.start")

    if Keyword.get(opts, :dry_run, false) do
      Mix.shell().info("DRY RUN — no changes will be written")
    end

    opts
    |> TemporalBackfill.run()
    |> TemporalBackfill.report(opts)
  end
end
