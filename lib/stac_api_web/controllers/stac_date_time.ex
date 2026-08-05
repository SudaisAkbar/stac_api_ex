defmodule StacApiWeb.STACDateTime do
  @moduledoc """
  Renders stored timestamps as the RFC 3339 strings STAC requires.

  STAC Common Metadata's `created` / `updated` must carry an offset. A UTC
  `DateTime` renders as `2026-08-05T21:48:19Z`, which satisfies that; a
  `NaiveDateTime` renders as `2026-08-05T21:48:19`, which does not — silently.
  All schemas now declare `:utc_datetime` (see `StacApi.Schema`), so the
  `NaiveDateTime` clause is only a guard for anything not yet converted.
  """

  @doc """
  Format a timestamp as RFC 3339, or `nil` if there is nothing to format.
  """
  def to_rfc3339(nil), do: nil
  def to_rfc3339(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  def to_rfc3339(%NaiveDateTime{} = naive) do
    naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
  end
end
