defmodule StacApi.Temporal do
  @moduledoc """
  Parsing and rendering of STAC temporal values.

  STAC follows RFC 3339 §5.6 and requires an explicit UTC offset — `2024-05-01T18:27:48Z`
  or `2024-05-01T18:27:48+00:00`. A string without one (`2024-05-01T18:27:48`) is not a
  valid STAC date-time, and interpreting it silently is how time zone bugs get in.

  Two parsers, deliberately different, because the cost of being wrong differs:

    * `parse_rfc3339/1` — **strict**, for write paths. An offset is required; anything
      else is an error the caller turns into a 400. Accepting a naive string here would
      mean guessing a time zone and persisting the guess.

    * `parse_query/1` — **lenient**, for the `datetime` query parameter and the HTML
      browser form (`<input type="datetime-local">` emits `YYYY-MM-DDTHH:MM`). A naive
      value is read as UTC and a bare date as midnight UTC. A wrong guess here costs one
      query's results, not stored data.
  """

  @doc """
  Strict RFC 3339 parse for write paths. Requires an explicit UTC offset.
  """
  @spec parse_rfc3339(term()) :: {:ok, DateTime.t()} | {:error, String.t()}
  def parse_rfc3339(%DateTime{} = datetime), do: {:ok, datetime}

  def parse_rfc3339(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      {:error, :missing_offset} ->
        {:error, ~s(must carry a UTC offset, e.g. "2024-05-01T18:27:48Z")}

      {:error, _reason} ->
        {:error, ~s(is not a valid RFC 3339 date-time, e.g. "2024-05-01T18:27:48Z")}
    end
  end

  def parse_rfc3339(_other), do: {:error, "must be an RFC 3339 date-time string"}

  @doc """
  Lenient parse for query parameters and the browser UI. See the module doc for why
  this differs from `parse_rfc3339/1`.
  """
  @spec parse_query(term()) :: {:ok, DateTime.t()} | {:error, String.t()}
  def parse_query(value) when is_binary(value) do
    padded = pad_seconds(value)

    with {:error, _} <- from_rfc3339(padded),
         {:error, _} <- from_naive(padded),
         {:error, _} <- from_date(padded) do
      {:error, ~s(is not a valid date-time, e.g. "2024-05-01T18:27:48Z")}
    end
  end

  def parse_query(_other), do: {:error, "must be a date-time string"}

  @doc """
  Render as an RFC 3339 UTC string, or `nil`.
  """
  @spec to_rfc3339(DateTime.t() | nil) :: String.t() | nil
  def to_rfc3339(nil), do: nil
  def to_rfc3339(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  @doc """
  Parse the STAC API `datetime` query parameter.

  Accepts a single instant, or an interval separated by `/` where either end may be
  `..` (or empty) to mean open. Returns `{:instant, datetime}` or
  `{:interval, start_or_nil, end_or_nil}`.
  """
  @spec parse_datetime_param(term()) ::
          {:ok, {:instant, DateTime.t()} | {:interval, DateTime.t() | nil, DateTime.t() | nil}}
          | {:error, String.t()}
  def parse_datetime_param(value) when is_binary(value) do
    case String.split(value, "/") do
      [single] ->
        with {:ok, datetime} <- parse_query(single), do: {:ok, {:instant, datetime}}

      [start_str, end_str] ->
        with {:ok, start_dt} <- parse_open_end(start_str),
             {:ok, end_dt} <- parse_open_end(end_str) do
          validate_interval(start_dt, end_dt)
        end

      _ ->
        {:error, ~s(must be a date-time or an interval with a single "/" separator)}
    end
  end

  def parse_datetime_param(_other), do: {:error, "must be a date-time or interval string"}

  defp parse_open_end(str) when str in ["..", ""], do: {:ok, nil}
  defp parse_open_end(str), do: parse_query(str)

  defp validate_interval(nil, nil),
    do: {:error, ~s(interval must bound at least one end; ".." on both sides matches everything)}

  defp validate_interval(start_dt, end_dt) do
    if start_dt && end_dt && DateTime.compare(start_dt, end_dt) == :gt do
      {:error, "interval start must not be later than its end"}
    else
      {:ok, {:interval, start_dt, end_dt}}
    end
  end

  defp from_rfc3339(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, reason} -> {:error, reason}
    end
  end

  defp from_naive(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp from_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}
      {:error, reason} -> {:error, reason}
    end
  end

  # "2024-05-01T18:27" -> "2024-05-01T18:27:00", preserving any offset suffix.
  defp pad_seconds(str) do
    case Regex.run(~r/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2})($|[Z+\-].*$)/, str) do
      [_, prefix, rest] -> prefix <> ":00" <> rest
      _ -> str
    end
  end
end
