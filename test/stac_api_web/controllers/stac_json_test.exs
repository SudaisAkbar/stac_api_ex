defmodule StacApiWeb.StacJSONTest do
  use ExUnit.Case, async: true

  alias StacApi.Data.{Catalog, Collection, Item}
  alias StacApiWeb.{CatalogJSON, CollectionJSON, ItemJSON}

  @links [%{"rel" => "self", "href" => "/stac/api/v1/x", "type" => "application/json"}]
  @created ~U[2026-04-09 13:52:11Z]
  @updated ~U[2026-08-05 21:48:19Z]

  describe "CatalogJSON.to_stac/2" do
    test "renders the STAC catalog fields" do
      catalog = %Catalog{
        id: "cat",
        title: "Cat",
        description: "desc",
        stac_version: "1.1.0",
        extent: %{"spatial" => %{"bbox" => [[-180, -90, 180, 90]]}},
        inserted_at: @created,
        updated_at: @updated
      }

      assert CatalogJSON.to_stac(catalog, @links) == %{
               stac_version: "1.1.0",
               type: "Catalog",
               id: "cat",
               title: "Cat",
               description: "desc",
               extent: %{"spatial" => %{"bbox" => [[-180, -90, 180, 90]]}},
               created: "2026-04-09T13:52:11Z",
               updated: "2026-08-05T21:48:19Z",
               links: @links
             }
    end

    test "renders created/updated as RFC 3339 at the top level" do
      catalog = %Catalog{id: "cat", inserted_at: @created, updated_at: @updated}
      stac = CatalogJSON.to_stac(catalog, [])

      assert stac.created == "2026-04-09T13:52:11Z"
      assert stac.updated == "2026-08-05T21:48:19Z"
    end

    test "defaults stac_version and keeps nil fields" do
      stac = CatalogJSON.to_stac(%Catalog{id: "bare"}, [])

      assert stac.stac_version == "1.0.0"
      assert stac.title == nil
      assert Map.has_key?(stac, :extent)
    end
  end

  describe "CollectionJSON.to_stac/3" do
    test "renders the STAC collection fields" do
      collection = %Collection{
        id: "coll",
        title: "Coll",
        description: "desc",
        license: "CC-BY-4.0",
        keywords: ["a"],
        providers: [%{"name" => "UT"}],
        summaries: %{"gsd" => [10]},
        stac_extensions: ["ext"],
        stac_version: "1.0.0",
        catalog_id: "cat"
      }

      stac = CollectionJSON.to_stac(collection, @links)

      assert stac.type == "Collection"
      assert stac.id == "coll"
      assert stac.catalog_id == "cat"
      assert stac.license == "CC-BY-4.0"
      assert stac.keywords == ["a"]
      assert stac.providers == [%{"name" => "UT"}]
      assert stac.summaries == %{"gsd" => [10]}
      assert stac.stac_extensions == ["ext"]
      assert stac.links == @links
    end

    test "renders created/updated as RFC 3339 at the top level" do
      collection = %Collection{id: "coll", inserted_at: @created, updated_at: @updated}
      stac = CollectionJSON.to_stac(collection, [])

      assert stac.created == "2026-04-09T13:52:11Z"
      assert stac.updated == "2026-08-05T21:48:19Z"
    end

    test "defaults stac_version and stac_extensions" do
      stac = CollectionJSON.to_stac(%Collection{id: "bare"}, [])

      assert stac.stac_version == "1.0.0"
      assert stac.stac_extensions == []
    end

    test "keeps nil fields by default (write actions)" do
      stac = CollectionJSON.to_stac(%Collection{id: "bare"}, [])

      assert Map.has_key?(stac, :title)
      assert stac.title == nil
    end

    test "drops nil fields with drop_nils: true (read actions)" do
      stac = CollectionJSON.to_stac(%Collection{id: "bare"}, [], drop_nils: true)

      refute Map.has_key?(stac, :title)
      refute Map.has_key?(stac, :license)
      refute Map.has_key?(stac, :catalog_id)
      assert stac.id == "bare"
      assert stac.stac_extensions == []
    end

    test "keeps catalog_id under drop_nils when the collection has one" do
      stac = CollectionJSON.to_stac(%Collection{id: "coll", catalog_id: "cat"}, [], drop_nils: true)

      assert stac.catalog_id == "cat"
    end
  end

  describe "ItemJSON.to_stac/3" do
    test "renders the STAC item fields" do
      item = %Item{
        id: "item",
        collection_id: "coll",
        stac_version: "1.0.0",
        stac_extensions: ["ext"],
        bbox: [24.0, 58.0, 25.0, 59.0],
        properties: %{"datetime" => "2023-06-15T10:00:00Z"}
      }

      assets = %{"data" => %{"href" => "https://example.org/data.tif"}}
      stac = ItemJSON.to_stac(item, @links, assets)

      assert stac.type == "Feature"
      assert stac.id == "item"
      assert stac.collection == "coll"
      assert stac.bbox == [24.0, 58.0, 25.0, 59.0]
      assert stac.properties == %{"datetime" => "2023-06-15T10:00:00Z"}
      assert stac.assets == assets
      assert stac.links == @links
    end

    test "defaults stac_version, stac_extensions and properties" do
      stac = ItemJSON.to_stac(%Item{id: "bare"}, [], %{})

      assert stac.stac_version == "1.0.0"
      assert stac.stac_extensions == []
      assert stac.properties == %{}
      assert stac.geometry == nil
    end

    test "puts created/updated inside properties, not at the top level" do
      item = %Item{
        id: "item",
        properties: %{"datetime" => "2023-06-15T10:00:00Z"},
        inserted_at: @created,
        updated_at: @updated
      }

      stac = ItemJSON.to_stac(item, [], %{})

      assert stac.properties["created"] == "2026-04-09T13:52:11Z"
      assert stac.properties["updated"] == "2026-08-05T21:48:19Z"
      assert stac.properties["datetime"] == "2023-06-15T10:00:00Z"
      refute Map.has_key?(stac, :created)
      refute Map.has_key?(stac, :updated)
    end

    test "server timestamps win over client-supplied created/updated" do
      item = %Item{
        id: "item",
        properties: %{"created" => "1999-01-01T00:00:00Z", "updated" => "1999-01-01T00:00:00Z"},
        inserted_at: @created,
        updated_at: @updated
      }

      stac = ItemJSON.to_stac(item, [], %{})

      assert stac.properties["created"] == "2026-04-09T13:52:11Z"
      assert stac.properties["updated"] == "2026-08-05T21:48:19Z"
    end

    test "omits created/updated rather than emitting nulls into properties" do
      stac = ItemJSON.to_stac(%Item{id: "unsaved", properties: %{"a" => 1}}, [], %{})

      assert stac.properties == %{"a" => 1}
    end
  end
end
