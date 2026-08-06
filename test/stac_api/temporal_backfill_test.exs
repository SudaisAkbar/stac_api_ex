defmodule StacApi.Data.TemporalBackfillTest do
  use StacApiWeb.ConnCase, async: false

  alias StacApi.Data.{Catalog, Collection, Item, TemporalBackfill}

  setup do
    {:ok, _} = Repo.insert(Catalog.changeset(%Catalog{}, %{"id" => "bf-cat", "title" => "C"}))

    {:ok, _} =
      Repo.insert(
        Collection.changeset(%Collection{}, %{
          "id" => "bf-coll",
          "title" => "C",
          "catalog_id" => "bf-cat"
        })
      )

    :ok
  end

  # Insert straight through Ecto to reproduce the legacy shape: temporal values
  # present in properties, columns empty. The API can no longer produce this.
  defp legacy_item(id, properties) do
    {:ok, item} =
      Repo.insert(
        Item.changeset(%Item{}, %{
          "id" => id,
          "collection_id" => "bf-coll",
          "geometry" => %Geo.Point{coordinates: {0, 0}, srid: 4326},
          "properties" => properties
        })
      )

    item
  end

  test "populates the datetime column from properties" do
    legacy_item("bf-instant", %{"datetime" => "2024-05-01T18:27:48Z"})

    stats = TemporalBackfill.run()

    assert stats.rows == 1
    assert stats.columns == 1
    assert Repo.get(Item, "bf-instant").datetime == ~U[2024-05-01 18:27:48.000000Z]
  end

  test "populates start/end columns for range items" do
    legacy_item("bf-range", %{
      "datetime" => nil,
      "start_datetime" => "2024-05-01T18:27:00Z",
      "end_datetime" => "2024-05-01T18:28:30Z"
    })

    TemporalBackfill.run()

    item = Repo.get(Item, "bf-range")
    assert item.datetime == nil
    assert item.start_datetime == ~U[2024-05-01 18:27:00.000000Z]
    assert item.end_datetime == ~U[2024-05-01 18:28:30.000000Z]
  end

  test "rescues naive values as UTC and counts them as lenient" do
    legacy_item("bf-naive", %{"datetime" => "2024-05-01T18:27:48"})

    stats = TemporalBackfill.run()

    assert stats.lenient == 1
    item = Repo.get(Item, "bf-naive")
    assert item.datetime == ~U[2024-05-01 18:27:48.000000Z]
    # …and the stored string is canonicalized, so it would now pass a write
    assert item.properties["datetime"] == "2024-05-01T18:27:48Z"
    assert stats.properties == 1
  end

  test "canonicalizes a non-UTC offset in properties" do
    legacy_item("bf-offset", %{"datetime" => "2024-05-01T21:27:48+03:00"})

    TemporalBackfill.run()

    item = Repo.get(Item, "bf-offset")
    assert item.datetime == ~U[2024-05-01 18:27:48.000000Z]
    assert item.properties["datetime"] == "2024-05-01T18:27:48Z"
  end

  test "leaves unparseable values alone rather than failing the run" do
    legacy_item("bf-garbage", %{"datetime" => "not-a-date"})
    legacy_item("bf-good", %{"datetime" => "2024-05-01T18:27:48Z"})

    stats = TemporalBackfill.run()

    assert stats.rows == 1
    assert Repo.get(Item, "bf-garbage").datetime == nil
    assert Repo.get(Item, "bf-good").datetime == ~U[2024-05-01 18:27:48.000000Z]
  end

  test "is idempotent" do
    legacy_item("bf-idem", %{"datetime" => "2024-05-01T18:27:48Z"})

    assert TemporalBackfill.run().rows == 1
    assert TemporalBackfill.run().rows == 0
  end

  test "dry run reports without writing" do
    legacy_item("bf-dry", %{"datetime" => "2024-05-01T18:27:48Z"})

    stats = TemporalBackfill.run(dry_run: true)

    assert stats.rows == 1
    assert Repo.get(Item, "bf-dry").datetime == nil
  end
end
