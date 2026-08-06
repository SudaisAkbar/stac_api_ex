defmodule StacApi.TemporalTest do
  use ExUnit.Case, async: true

  alias StacApi.Temporal

  describe "parse_rfc3339/1 (write paths)" do
    test "accepts UTC and normalizes other offsets" do
      assert {:ok, ~U[2024-05-01 18:27:48Z]} = Temporal.parse_rfc3339("2024-05-01T18:27:48Z")
      assert {:ok, ~U[2024-05-01 18:27:48Z]} = Temporal.parse_rfc3339("2024-05-01T18:27:48+00:00")
      assert {:ok, ~U[2024-05-01 18:27:48Z]} = Temporal.parse_rfc3339("2024-05-01T21:27:48+03:00")
    end

    test "keeps sub-second precision" do
      assert {:ok, dt} = Temporal.parse_rfc3339("2024-05-01T18:27:48.123456Z")
      assert dt.microsecond == {123_456, 6}
    end

    test "passes a DateTime through" do
      assert {:ok, ~U[2024-05-01 18:27:48Z]} = Temporal.parse_rfc3339(~U[2024-05-01 18:27:48Z])
    end

    test "rejects a value with no offset, naming the problem" do
      assert {:error, message} = Temporal.parse_rfc3339("2024-05-01T18:27:48")
      assert message =~ "UTC offset"
    end

    test "rejects a bare date and other non-datetimes" do
      assert {:error, _} = Temporal.parse_rfc3339("2024-05-01")
      assert {:error, _} = Temporal.parse_rfc3339("not-a-date")
      assert {:error, _} = Temporal.parse_rfc3339(42)
      assert {:error, _} = Temporal.parse_rfc3339(nil)
    end
  end

  describe "parse_query/1 (query paths)" do
    test "accepts what the strict parser accepts" do
      assert {:ok, ~U[2024-05-01 18:27:48Z]} = Temporal.parse_query("2024-05-01T18:27:48Z")
    end

    test "reads a naive value as UTC" do
      assert {:ok, ~U[2024-05-01 18:27:48Z]} = Temporal.parse_query("2024-05-01T18:27:48")
    end

    test "reads a bare date as midnight UTC" do
      assert {:ok, ~U[2024-05-01 00:00:00Z]} = Temporal.parse_query("2024-05-01")
    end

    test "pads the minute-precision value the browser date picker emits" do
      assert {:ok, ~U[2024-05-01 18:27:00Z]} = Temporal.parse_query("2024-05-01T18:27")
    end

    test "still rejects nonsense" do
      assert {:error, _} = Temporal.parse_query("last-tuesday")
    end
  end

  describe "parse_datetime_param/1" do
    test "single instant" do
      assert {:ok, {:instant, ~U[2024-05-01 18:27:48Z]}} =
               Temporal.parse_datetime_param("2024-05-01T18:27:48Z")
    end

    test "closed interval" do
      assert {:ok, {:interval, ~U[2024-01-01 00:00:00Z], ~U[2024-12-31 00:00:00Z]}} =
               Temporal.parse_datetime_param("2024-01-01T00:00:00Z/2024-12-31T00:00:00Z")
    end

    test "open start and open end via .." do
      assert {:ok, {:interval, nil, ~U[2024-12-31 00:00:00Z]}} =
               Temporal.parse_datetime_param("../2024-12-31T00:00:00Z")

      assert {:ok, {:interval, ~U[2024-01-01 00:00:00Z], nil}} =
               Temporal.parse_datetime_param("2024-01-01T00:00:00Z/..")
    end

    test "rejects an interval open at both ends" do
      assert {:error, message} = Temporal.parse_datetime_param("../..")
      assert message =~ "at least one end"
    end

    test "rejects a reversed interval" do
      assert {:error, message} =
               Temporal.parse_datetime_param("2024-12-31T00:00:00Z/2024-01-01T00:00:00Z")

      assert message =~ "later than"
    end

    test "rejects more than one separator" do
      assert {:error, message} = Temporal.parse_datetime_param("2024-01-01Z/2024-06-01Z/2024-12-01Z")
      assert message =~ "single"
    end
  end

  describe "to_rfc3339/1" do
    test "renders UTC with the offset STAC requires" do
      assert Temporal.to_rfc3339(~U[2024-05-01 18:27:48Z]) == "2024-05-01T18:27:48Z"
    end

    test "keeps sub-second precision when present" do
      assert Temporal.to_rfc3339(~U[2024-05-01 18:27:48.123456Z]) == "2024-05-01T18:27:48.123456Z"
    end

    test "passes nil through" do
      assert Temporal.to_rfc3339(nil) == nil
    end
  end
end
