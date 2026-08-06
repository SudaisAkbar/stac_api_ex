defmodule StacApi.Schema do
  @moduledoc """
  Shared base for the STAC Ecto schemas.

  Exists so the timestamp type is decided in one place. It previously was not:
  `catalogs` declared `timestamps(type: :utc_datetime)` while `collections` and
  `items` used the plain default (`:naive_datetime`), which meant the same
  concept came back as `%DateTime{}` from one table and `%NaiveDateTime{}` from
  another.

  That distinction reaches the wire. `NaiveDateTime` has no offset, so both
  `to_iso8601/1` and `Jason` render it as `2026-08-05T21:48:19` — not valid
  RFC 3339, and therefore not STAC-conformant, with nothing to signal the
  problem. A UTC `DateTime` renders as `2026-08-05T21:48:19Z`. Using
  `:utc_datetime` everywhere makes the correct rendering the default rather
  than something each serializer has to remember.

  The columns are `timestamptz(6)`, so the type is microsecond-precision. That
  matters for clients that use `updated` to detect a concurrent write: at second
  precision, a read and a write inside the same second are indistinguishable.
  The type and the column precision have to agree — declaring `_usec` over a
  `timestamp(0)` column just makes Postgres truncate on write and hand back a
  fake `.000000`.
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      @timestamps_opts [type: :utc_datetime_usec]
    end
  end
end
