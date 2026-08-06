defmodule StacApi.Data.TemporalBackfill do
  @moduledoc """
  Backfills the temporal columns on existing items and canonicalizes the datetime
  strings stored in `properties`. See issue #20.

  Rows written before the STAC temporal work can be inconsistent in three ways:

    * `items.datetime` is null even though `properties.datetime` has a value —
      the write path used to read a top-level `datetime` that conformant clients
      never send.
    * `items.start_datetime` / `items.end_datetime` are null because those values
      only ever lived in the `properties` JSONB.
    * `properties` datetime strings may lack a UTC offset, which is not valid
      STAC and used to be interpreted against the database session's time zone.

  Values are parsed leniently here — a naive string is read as UTC, which is what
  the old code effectively did on a UTC session — because the goal is to rescue
  data already written, not to reject it. Every value that needed that leniency
  is counted, since those rows would now be refused on write.

  This module holds the logic rather than the Mix task, because production runs
  as a release where Mix is unavailable. `Mix.Tasks.Stac.BackfillTemporal` and
  `StacApi.Release.backfill_temporal/1` are both thin wrappers over `run/1`.
  """

  import Ecto.Query

  alias StacApi.Data.Item
  alias StacApi.Repo
  alias StacApi.Temporal

  @type stats :: %{rows: non_neg_integer(), columns: non_neg_integer(), properties: non_neg_integer(), lenient: non_neg_integer()}

  @doc """
  Run the backfill.

  Options:

    * `:dry_run` — plan the changes and report without writing (default `false`)
    * `:batch_size` — rows fetched per round trip (default `500`)

  Returns the stats map, and is safe to run repeatedly: a second run over
  already-consistent data reports zero rows.
  """
  @spec run(keyword()) :: stats()
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    batch_size = Keyword.get(opts, :batch_size, 500)

    stream =
      Repo.stream(
        from(i in Item,
          select: %{
            id: i.id,
            datetime: i.datetime,
            start_datetime: i.start_datetime,
            end_datetime: i.end_datetime,
            properties: i.properties
          }
        ),
        max_rows: batch_size
      )

    {:ok, stats} =
      Repo.transaction(
        fn ->
          stream
          |> Stream.map(&plan_row/1)
          |> Stream.reject(&is_nil/1)
          |> Enum.reduce(new_stats(), fn plan, stats ->
            unless dry_run?, do: apply_plan(plan)
            tally(stats, plan)
          end)
        end,
        timeout: :infinity
      )

    stats
  end

  @doc """
  Print a human-readable summary of `run/1`'s result.

  Uses `IO.puts/1` rather than `Mix.shell/0` so it works inside a release.
  """
  @spec report(stats(), keyword()) :: :ok
  def report(stats, opts \\ []) do
    verb = if Keyword.get(opts, :dry_run, false), do: "would change", else: "changed"

    IO.puts("""

    Rows #{verb}:            #{stats.rows}
      temporal columns:    #{stats.columns}
      properties strings:  #{stats.properties}

    Values that parsed only leniently (missing a UTC offset): #{stats.lenient}
    """)

    if stats.lenient > 0 do
      IO.puts(
        "Those values were read as UTC. Writes now reject them, so the source that " <>
          "produced them should be fixed to emit RFC 3339 with an offset.\n"
      )
    end

    :ok
  end

  # Returns nil when a row is already consistent, so untouched rows cost nothing.
  defp plan_row(row) do
    properties = row.properties || %{}

    parsed = %{
      "datetime" => parse(properties["datetime"]),
      "start_datetime" => parse(properties["start_datetime"]),
      "end_datetime" => parse(properties["end_datetime"])
    }

    normalized_properties =
      Enum.reduce(["datetime", "start_datetime", "end_datetime"], properties, fn key, acc ->
        case parsed[key] do
          {:ok, datetime, _lenient?} -> Map.put(acc, key, Temporal.to_rfc3339(datetime))
          _ -> acc
        end
      end)

    columns = %{
      datetime: value_of(parsed["datetime"]) || row.datetime,
      start_datetime: value_of(parsed["start_datetime"]) || row.start_datetime,
      end_datetime: value_of(parsed["end_datetime"]) || row.end_datetime
    }

    # Compare instants, not structs: a value parsed from "…:48Z" carries
    # microsecond precision {0, 0} while the stored column carries {0, 6}, so
    # struct inequality would report every row as changed.
    changed_columns? =
      not (same_instant?(columns.datetime, row.datetime) and
             same_instant?(columns.start_datetime, row.start_datetime) and
             same_instant?(columns.end_datetime, row.end_datetime))

    changed_properties? = normalized_properties != properties

    if changed_columns? or changed_properties? do
      %{
        id: row.id,
        columns: columns,
        properties: normalized_properties,
        changed_columns?: changed_columns?,
        changed_properties?: changed_properties?,
        lenient?: Enum.any?(parsed, fn {_k, v} -> match?({:ok, _, true}, v) end)
      }
    end
  end

  defp parse(nil), do: :none

  defp parse(value) when is_binary(value) do
    case Temporal.parse_rfc3339(value) do
      {:ok, datetime} ->
        {:ok, datetime, false}

      {:error, _} ->
        case Temporal.parse_query(value) do
          {:ok, datetime} -> {:ok, datetime, true}
          {:error, _} -> :unparseable
        end
    end
  end

  defp parse(_), do: :unparseable

  defp value_of({:ok, datetime, _lenient?}), do: datetime
  defp value_of(_), do: nil

  defp same_instant?(nil, nil), do: true
  defp same_instant?(nil, _), do: false
  defp same_instant?(_, nil), do: false
  defp same_instant?(a, b), do: DateTime.compare(a, b) == :eq

  defp apply_plan(plan) do
    Repo.update_all(
      from(i in Item, where: i.id == ^plan.id),
      set: [
        datetime: plan.columns.datetime,
        start_datetime: plan.columns.start_datetime,
        end_datetime: plan.columns.end_datetime,
        properties: plan.properties
      ]
    )
  end

  defp new_stats, do: %{rows: 0, columns: 0, properties: 0, lenient: 0}

  defp tally(stats, plan) do
    %{
      rows: stats.rows + 1,
      columns: stats.columns + if(plan.changed_columns?, do: 1, else: 0),
      properties: stats.properties + if(plan.changed_properties?, do: 1, else: 0),
      lenient: stats.lenient + if(plan.lenient?, do: 1, else: 0)
    }
  end
end
