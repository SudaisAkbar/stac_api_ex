defmodule StacApi.Repo.Migrations.ConvertTimestampsToTimestamptz do
  @moduledoc """
  Converts every timestamp column from `timestamp(0) without time zone` to
  `timestamptz(6)`. See issue #20.

  Two reasons:

    * `items.datetime` was compared against `timestamptz` values cast out of the
      `properties` JSONB in `update_collection_extent/1`. Postgres resolves that
      mix using the *session* `TimeZone`, so collection temporal extents were
      correct only because the session happens to be UTC.

    * The columns were second-precision, which bounds how finely `updated` can
      detect a concurrent write. Widening to (6) pairs with `StacApi.Schema`
      moving to `:utc_datetime_usec`.

  ## The USING clause is load-bearing

  Postgres's implicit `timestamp -> timestamptz` conversion interprets the naive
  value in the session `TimeZone`. Every value in these columns was written by
  Ecto as UTC, so `AT TIME ZONE 'UTC'` states that explicitly and makes the
  result independent of who runs the migration and from where. Without it, the
  same migration silently produces different data on a non-UTC session.

  ## Locking

  Changing a column's type rewrites the table and holds `ACCESS EXCLUSIVE` for
  the duration — reads and writes to that table block. This runs inside a
  transaction, so a failure rolls back cleanly, but check table sizes before
  running it against production and schedule a window accordingly.
  """
  use Ecto.Migration

  @conversions [
    {"catalogs", ["inserted_at", "updated_at"]},
    {"collections", ["inserted_at", "updated_at"]},
    {"items", ["inserted_at", "updated_at", "datetime"]},
    {"item_assets", ["inserted_at", "updated_at", "created_at"]}
  ]

  def up do
    for {table, columns} <- @conversions do
      execute(alter_columns(table, columns, "timestamptz(6)"))
    end
  end

  def down do
    for {table, columns} <- @conversions do
      execute(alter_columns(table, columns, "timestamp(0)"))
    end
  end

  # Both directions carry `AT TIME ZONE 'UTC'`: going up it declares the stored
  # naive values as UTC, going down it renders the instant back as UTC wall time.
  defp alter_columns(table, columns, type) do
    changes =
      columns
      |> Enum.map(fn column ->
        ~s(ALTER COLUMN "#{column}" TYPE #{type} USING "#{column}" AT TIME ZONE 'UTC')
      end)
      |> Enum.join(",\n  ")

    ~s(ALTER TABLE "#{table}"\n  #{changes})
  end
end
