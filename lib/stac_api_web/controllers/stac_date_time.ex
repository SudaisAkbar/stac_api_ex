defmodule StacApiWeb.STACDateTime do
  @moduledoc """
  Renders stored timestamps as the RFC 3339 strings STAC requires.

  STAC Common Metadata's `created` / `updated` must carry an offset. A UTC
  `DateTime` renders as `2026-08-05T21:48:19.248683Z`, which satisfies that; a
  `NaiveDateTime` renders without the offset, which does not — silently. Every
  schema declares `:utc_datetime_usec` via `StacApi.Schema` and the columns are
  `timestamptz`, so only `DateTime` reaches here.
  """

  @doc """
  Format a timestamp as RFC 3339, or `nil` if there is nothing to format.
  """
  def to_rfc3339(nil), do: nil
  def to_rfc3339(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
