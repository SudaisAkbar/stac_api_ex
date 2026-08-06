defmodule StacApi.Repo.Migrations.AddStartEndDatetimeToItems do
  @moduledoc """
  Promotes STAC `start_datetime` / `end_datetime` from JSONB text to real
  `timestamptz` columns. See issue #20.

  They were only ever read by casting `properties->>'start_datetime'` to
  `timestamptz` inside the collection-extent query, which meant a naive string
  was interpreted in the session `TimeZone` and an unparseable one raised —
  taking the whole temporal extent with it. Typed columns remove the cast, make
  the values indexable for temporal search, and let bad input be rejected at the
  edge instead of failing later in SQL.

  Additive and nullable, so no table rewrite: this takes a brief `ACCESS
  EXCLUSIVE` lock for the catalog update only. Existing rows are populated
  separately by `mix stac.backfill_temporal`, which parses in Elixir and can be
  run and re-run outside a migration window.
  """
  use Ecto.Migration

  def change do
    alter table(:items) do
      add :start_datetime, :timestamptz
      add :end_datetime, :timestamptz
    end

    create index(:items, [:start_datetime])
    create index(:items, [:end_datetime])
  end
end
