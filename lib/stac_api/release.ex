defmodule StacApi.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :stac_api

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Backfill item temporal columns and canonicalize `properties` datetime strings.

  The release equivalent of `mix stac.backfill_temporal`, which is unavailable in
  production because a release ships without Mix. Accepts the same switches, as a
  list of strings:

      bin/stac_api eval 'StacApi.Release.backfill_temporal(["--dry-run"])'
      bin/stac_api eval 'StacApi.Release.backfill_temporal()'
      bin/stac_api eval 'StacApi.Release.backfill_temporal(["--batch-size", "2000"])'

  Run it **after** migrating and deploying: it populates the columns that make
  pre-existing items findable by temporal search. Safe to repeat — a second run
  over consistent data reports zero rows. Returns the stats map.
  """
  def backfill_temporal(args \\ []) do
    load_app()

    {opts, _argv} = OptionParser.parse!(args, strict: [dry_run: :boolean, batch_size: :integer])

    {:ok, stats, _apps} =
      Ecto.Migrator.with_repo(StacApi.Repo, fn _repo ->
        if Keyword.get(opts, :dry_run, false) do
          IO.puts("DRY RUN — no changes will be written")
        end

        stats = StacApi.Data.TemporalBackfill.run(opts)
        StacApi.Data.TemporalBackfill.report(stats, opts)
        stats
      end)

    stats
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
