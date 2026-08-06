defmodule StacApiWeb.ItemsCrudControllerTest do
  use StacApiWeb.ConnCase, async: true

  setup %{conn: conn} do
    auth_conn = authenticated_conn(conn)
    
    catalog_params = %{
      "id" => "test-catalog",
      "title" => "Test Catalog",
      "description" => "Test"
    }
    post(auth_conn, ~p"/stac/manage/v1/catalogs", catalog_params)

    collection_params = %{
      "id" => "test-collection",
      "title" => "Test Collection",
      "description" => "Test",
      "license" => "CC-BY-4.0",
      "catalog_id" => "test-catalog",
      "extent" => %{
        "spatial" => %{"bbox" => [[-180, -90, 180, 90]]},
        "temporal" => %{"interval" => [["2020-01-01T00:00:00Z", "2024-12-31T23:59:59Z"]]}
      }
    }
    post(auth_conn, ~p"/stac/manage/v1/collections", collection_params)

    {:ok, conn: auth_conn}
  end

  describe "collection temporal extent" do
    test "is unaffected by a non-UTC session TimeZone", %{conn: conn} do
      # update_collection_extent/1 compares items.datetime against timestamptz
      # values cast out of properties. While the columns were `timestamp without
      # time zone`, Postgres resolved that mix using the session TimeZone, so
      # this extent came out shifted by the session's offset (3h for Tallinn in
      # June). Both sides are timestamptz now, making the result an instant
      # comparison that no session setting can move.
      Repo.query!("SET LOCAL TimeZone = 'Europe/Tallinn'", [])

      post(conn, ~p"/stac/manage/v1/items", %{
        "id" => "tz-sensitive-item",
        "collection_id" => "test-collection",
        "geometry" => %{"type" => "Point", "coordinates" => [0, 0]},
        "properties" => %{"datetime" => "2024-06-15T10:00:00Z"}
      })

      collection = Repo.get(StacApi.Data.Collection, "test-collection")
      [[min_datetime, max_datetime]] = collection.extent["temporal"]["interval"]

      assert min_datetime == "2024-06-15T10:00:00Z"
      assert max_datetime == "2024-06-15T10:00:00Z"
    end
  end

  describe "STAC temporal conformance" do
    defp item_params(id, properties) do
      %{
        "type" => "Feature",
        "id" => id,
        "collection" => "test-collection",
        "stac_version" => "1.0.0",
        "geometry" => %{"type" => "Point", "coordinates" => [0, 0]},
        "properties" => properties
      }
    end

    test "accepts a spec-shaped item and populates the datetime column", %{conn: conn} do
      conn = post(conn, ~p"/stac/manage/v1/items", item_params("spec-item", %{"datetime" => "2024-05-01T18:27:48Z"}))
      assert json_response(conn, 201)

      item = Repo.get(StacApi.Data.Item, "spec-item")
      assert item.datetime == ~U[2024-05-01 18:27:48.000000Z]
      assert item.start_datetime == nil
      assert item.end_datetime == nil
    end

    test "accepts a range item and populates start/end columns", %{conn: conn} do
      params =
        item_params("range-item", %{
          "datetime" => nil,
          "start_datetime" => "2024-05-01T18:27:00Z",
          "end_datetime" => "2024-05-01T18:28:30Z"
        })

      assert json_response(post(conn, ~p"/stac/manage/v1/items", params), 201)

      item = Repo.get(StacApi.Data.Item, "range-item")
      assert item.datetime == nil
      assert item.start_datetime == ~U[2024-05-01 18:27:00.000000Z]
      assert item.end_datetime == ~U[2024-05-01 18:28:30.000000Z]
    end

    test "normalizes a non-UTC offset to canonical UTC in stored properties", %{conn: conn} do
      params = item_params("offset-item", %{"datetime" => "2024-05-01T21:27:48+03:00"})
      assert json_response(post(conn, ~p"/stac/manage/v1/items", params), 201)

      item = Repo.get(StacApi.Data.Item, "offset-item")
      assert item.datetime == ~U[2024-05-01 18:27:48.000000Z]
      assert item.properties["datetime"] == "2024-05-01T18:27:48Z"

      # …and every endpoint renders the same string
      manage = json_response(get(conn, ~p"/stac/manage/v1/items/offset-item"), 200)
      assert manage["properties"]["datetime"] == "2024-05-01T18:27:48Z"

      public =
        json_response(get(build_conn(), ~p"/stac/api/v1/collections/test-collection/items/offset-item"), 200)

      assert public["properties"]["datetime"] == "2024-05-01T18:27:48Z"
    end

    test "preserves sub-second precision", %{conn: conn} do
      params = item_params("usec-item", %{"datetime" => "2024-05-01T18:27:48.123456Z"})
      assert json_response(post(conn, ~p"/stac/manage/v1/items", params), 201)

      assert Repo.get(StacApi.Data.Item, "usec-item").datetime == ~U[2024-05-01 18:27:48.123456Z]
    end

    for {label, value} <- [
          {"a naive datetime", "2024-05-01T18:27:48"},
          {"a bare date", "2024-05-01"},
          {"an unparseable string", "not-a-date"}
        ] do
      test "rejects #{label} instead of storing null", %{conn: conn} do
        params = item_params("bad-item", %{"datetime" => unquote(value)})
        conn = post(conn, ~p"/stac/manage/v1/items", params)

        assert response = json_response(conn, 400)
        assert response["error"] =~ "properties.datetime"
        refute Repo.get(StacApi.Data.Item, "bad-item")
      end
    end

    test "rejects a null datetime without a range", %{conn: conn} do
      conn = post(conn, ~p"/stac/manage/v1/items", item_params("no-time", %{"datetime" => nil}))

      assert response = json_response(conn, 400)
      assert response["error"] =~ "start_datetime"
    end

    test "rejects a range missing its end", %{conn: conn} do
      params =
        item_params("half-range", %{"datetime" => nil, "start_datetime" => "2024-05-01T18:27:00Z"})

      assert response = json_response(post(conn, ~p"/stac/manage/v1/items", params), 400)
      assert response["error"] =~ "both required"
    end

    test "rejects a reversed range", %{conn: conn} do
      params =
        item_params("reversed", %{
          "datetime" => nil,
          "start_datetime" => "2024-05-01T18:28:30Z",
          "end_datetime" => "2024-05-01T18:27:00Z"
        })

      assert response = json_response(post(conn, ~p"/stac/manage/v1/items", params), 400)
      assert response["error"] =~ "must not be later than"
    end

    test "rejects a naive start_datetime", %{conn: conn} do
      params =
        item_params("naive-range", %{
          "datetime" => nil,
          "start_datetime" => "2024-05-01T18:27:00",
          "end_datetime" => "2024-05-01T18:28:30Z"
        })

      assert response = json_response(post(conn, ~p"/stac/manage/v1/items", params), 400)
      assert response["error"] =~ "properties.start_datetime"
      assert response["error"] =~ "UTC offset"
    end

    test "bulk import rejects a non-conformant feature", %{conn: conn} do
      conn =
        post(conn, ~p"/stac/manage/v1/items/import", %{
          "features" => [
            item_params("bulk-ok", %{"datetime" => "2024-05-01T18:27:48Z"}),
            item_params("bulk-bad", %{"datetime" => "2024-05-01T18:27:48"})
          ]
        })

      assert response = json_response(conn, 200)
      assert response["imported"] == 1
      assert response["failed"] == 1
      assert Repo.get(StacApi.Data.Item, "bulk-ok")
      refute Repo.get(StacApi.Data.Item, "bulk-bad")
    end

    test "an instant item contributes a closed collection extent", %{conn: conn} do
      post(conn, ~p"/stac/manage/v1/items", item_params("extent-item", %{"datetime" => "2024-05-01T18:27:48Z"}))

      collection = Repo.get(StacApi.Data.Collection, "test-collection")
      assert [["2024-05-01T18:27:48Z", "2024-05-01T18:27:48Z"]] = collection.extent["temporal"]["interval"]
    end

    test "a range item contributes its full span to the collection extent", %{conn: conn} do
      params =
        item_params("extent-range", %{
          "datetime" => nil,
          "start_datetime" => "2024-05-01T18:27:00Z",
          "end_datetime" => "2024-05-01T18:28:30Z"
        })

      post(conn, ~p"/stac/manage/v1/items", params)

      collection = Repo.get(StacApi.Data.Collection, "test-collection")
      assert [["2024-05-01T18:27:00Z", "2024-05-01T18:28:30Z"]] = collection.extent["temporal"]["interval"]
    end
  end

  describe "POST /items - create item" do
    test "creates an item successfully", %{conn: conn} do
      params = %{
        "id" => "test-item",
        "collection_id" => "test-collection",
        "stac_version" => "1.0.0",
        "geometry" => %{"type" => "Point", "coordinates" => [0, 0]},
        "bbox" => [-1, -1, 1, 1],
        "properties" => %{"datetime" => "2024-01-01T12:00:00Z", "description" => "Test item", "source" => "test"}
      }

      conn = post(conn, ~p"/stac/manage/v1/items", params)

      assert response = json_response(conn, 201)
      assert response["success"] == true
      assert response["data"]["id"] == "test-item"
      assert response["data"]["type"] == "Feature"
      assert response["data"]["collection"] == "test-collection"
      assert response["data"]["geometry"]["type"] == "Point"
    end

    test "creates an item with assets", %{conn: conn} do
      params = %{
        "id" => "item-with-assets",
        "collection_id" => "test-collection",
        "geometry" => %{"type" => "Point", "coordinates" => [10, 10]},
        "bbox" => [9, 9, 11, 11],
        "properties" => %{"datetime" => "2024-01-02T12:00:00Z", "description" => "Item with assets"},
        "assets" => %{
          "thumbnail" => %{
            "href" => "https://example.com/thumb.jpg",
            "type" => "image/jpeg",
            "title" => "Thumbnail"
          },
          "data" => %{
            "href" => "https://example.com/data.tif",
            "type" => "image/tiff",
            "roles" => ["data"]
          }
        }
      }

      conn = post(conn, ~p"/stac/manage/v1/items", params)

      assert response = json_response(conn, 201)
      assert response["success"] == true
      assert is_map(response["data"]["assets"])
      assert response["data"]["assets"]["thumbnail"]["href"] == "https://example.com/thumb.jpg"
    end

    test "returns 409 when item ID already exists", %{conn: conn} do
      params = %{
        "id" => "duplicate-item",
        "collection_id" => "test-collection",
        "geometry" => %{"type" => "Point", "coordinates" => [0, 0]},
        "bbox" => [-1, -1, 1, 1],
        "properties" => %{"datetime" => "2024-01-01T12:00:00Z"}
      }

      post(conn, ~p"/stac/manage/v1/items", params)

      conn = post(conn, ~p"/stac/manage/v1/items", params)
      assert response = json_response(conn, 409)
      assert response["error"] =~ "already exists"
    end

    test "returns 400 when missing required field (id)", %{conn: conn} do
      params = %{
        "collection_id" => "test-collection",
        "geometry" => %{"type" => "Point", "coordinates" => [0, 0]},
        "bbox" => [-1, -1, 1, 1],
        "properties" => %{"datetime" => "2024-01-01T12:00:00Z"}
      }

      conn = post(conn, ~p"/stac/manage/v1/items", params)
      assert response = json_response(conn, 400)
      assert response["error"] =~ "id"
    end

    test "returns 400 when missing required field (geometry)", %{conn: conn} do
      params = %{
        "id" => "no-geometry-item",
        "collection_id" => "test-collection",
        "bbox" => [-1, -1, 1, 1],
        "properties" => %{"datetime" => "2024-01-01T12:00:00Z"}
      }

      conn = post(conn, ~p"/stac/manage/v1/items", params)
      assert response = json_response(conn, 400)
      assert response["error"] =~ "geometry"
    end

    test "returns 400 when collection does not exist", %{conn: conn} do
      params = %{
        "id" => "orphan-item",
        "collection_id" => "non-existent-collection",
        "geometry" => %{"type" => "Point", "coordinates" => [0, 0]},
        "bbox" => [-1, -1, 1, 1],
        "properties" => %{"datetime" => "2024-01-01T12:00:00Z"}
      }

      conn = post(conn, ~p"/stac/manage/v1/items", params)
      assert response = json_response(conn, 400)
      assert response["error"] =~ "collection"
    end
  end

  describe "GET /items - list all items" do
    setup %{conn: conn} do
      item1_params = %{
        "id" => "item-1",
        "collection_id" => "test-collection",
        "geometry" => %{"type" => "Point", "coordinates" => [0, 0]},
        "bbox" => [-1, -1, 1, 1],
        "properties" => %{"datetime" => "2024-01-01T12:00:00Z", "description" => "First"}
      }

      item2_params = %{
        "id" => "item-2",
        "collection_id" => "test-collection",
        "geometry" => %{"type" => "Point", "coordinates" => [10, 10]},
        "bbox" => [9, 9, 11, 11],
        "properties" => %{"datetime" => "2024-01-02T12:00:00Z", "description" => "Second"}
      }

      post(conn, ~p"/stac/manage/v1/items", item1_params)
      post(conn, ~p"/stac/manage/v1/items", item2_params)

      :ok
    end

    test "returns all items", %{conn: conn} do
      conn = get(conn, ~p"/stac/manage/v1/items")
      assert response = json_response(conn, 200)

      assert response["type"] == "FeatureCollection"
      assert is_list(response["features"])
      assert length(response["features"]) >= 2
    end

    test "returns items with proper GeoJSON structure", %{conn: conn} do
      conn = get(conn, ~p"/stac/manage/v1/items")
      response = json_response(conn, 200)

      features = response["features"]
      item = Enum.find(features, &(&1["id"] == "item-1"))

      assert item["type"] == "Feature"
      assert item["id"] == "item-1"
      assert item["geometry"]
      assert item["bbox"]
      assert item["properties"]
      assert item["collection"]
    end

    test "supports pagination with limit parameter", %{conn: conn} do
      conn = get(conn, ~p"/stac/manage/v1/items?limit=1")
      assert response = json_response(conn, 200)

      assert length(response["features"]) <= 1
      assert response["context"]["limit"] == 1
    end
  end

  describe "GET /items/:id - show specific item" do
    setup %{conn: conn} do
      item_params = %{
        "id" => "show-item",
        "collection_id" => "test-collection",
        "geometry" => %{"type" => "Point", "coordinates" => [5, 5]},
        "bbox" => [4, 4, 6, 6],
        "properties" => %{"datetime" => "2024-01-15T12:00:00Z", "description" => "Show test"}
      }

      post(conn, ~p"/stac/manage/v1/items", item_params)

      :ok
    end

    test "returns a specific item", %{conn: conn} do
      conn = get(conn, ~p"/stac/manage/v1/items/show-item")
      assert response = json_response(conn, 200)

      assert response["id"] == "show-item"
      assert response["type"] == "Feature"
      assert response["geometry"]["type"] == "Point"
      assert response["properties"]["description"] == "Show test"
    end

    test "returns item with STAC properties", %{conn: conn} do
      conn = get(conn, ~p"/stac/manage/v1/items/show-item")
      response = json_response(conn, 200)

      assert response["stac_version"]
      assert response["type"] == "Feature"
      assert response["id"]
      assert response["geometry"]
      assert response["bbox"]
      assert response["properties"]
      assert response["collection"]
      assert is_list(response["links"])
    end

    test "returns 404 for non-existent item", %{conn: conn} do
      conn = get(conn, ~p"/stac/manage/v1/items/non-existent")
      assert response = json_response(conn, 404)
      assert response["error"] =~ "not found"
    end
  end

  describe "PUT /items/:id - update item (full replacement)" do
    setup %{conn: conn} do
      item_params = %{
        "id" => "update-item",
        "collection_id" => "test-collection",
        "geometry" => %{"type" => "Point", "coordinates" => [0, 0]},
        "bbox" => [-1, -1, 1, 1],
        "properties" => %{"datetime" => "2024-01-01T12:00:00Z", "description" => "Original"}
      }

      post(conn, ~p"/stac/manage/v1/items", item_params)

      :ok
    end

    test "fully replaces an item", %{conn: conn} do
      update_params = %{
        "id" => "update-item",
        "type" => "Feature",
        "collection_id" => "test-collection",
        "geometry" => %{"type" => "Point", "coordinates" => [10, 10]},
        "bbox" => [9, 9, 11, 11],
        "properties" => %{"datetime" => "2024-01-02T12:00:00Z", "description" => "Updated"},
        "stac_version" => "1.0.0"
      }

      conn = put(conn, ~p"/stac/manage/v1/items/update-item", update_params)

      assert response = json_response(conn, 200)
      assert response["success"] == true
      assert response["data"]["properties"]["description"] == "Updated"
      assert response["data"]["geometry"]["coordinates"] == [10.0, 10.0]
    end

    test "returns 404 when updating non-existent item", %{conn: conn} do
      params = %{
        "id" => "non-existent",
        "collection_id" => "test-collection",
        "geometry" => %{"type" => "Point", "coordinates" => [0, 0]},
        "bbox" => [-1, -1, 1, 1],
        "properties" => %{"datetime" => "2024-01-01T12:00:00Z"},
        "stac_version" => "1.0.0"
      }

      conn = put(conn, ~p"/stac/manage/v1/items/non-existent", params)
      assert json_response(conn, 404)
    end
  end

  describe "PATCH /items/:id - partial update item" do
    setup %{conn: conn} do
      item_params = %{
        "id" => "patch-item",
        "collection_id" => "test-collection",
        "geometry" => %{"type" => "Point", "coordinates" => [0, 0]},
        "bbox" => [-1, -1, 1, 1],
        "properties" => %{"datetime" => "2024-01-01T12:00:00Z", "description" => "Original", "source" => "test"}
      }

      post(conn, ~p"/stac/manage/v1/items", item_params)

      :ok
    end

    test "partially updates an item", %{conn: conn} do
      patch_params = %{
        "id" => "patch-item",
        "properties" => %{
          "datetime" => "2024-01-01T12:00:00Z",
          "description" => "Patched",
          "source" => "test"
        }
      }

      conn = patch(conn, ~p"/stac/manage/v1/items/patch-item", patch_params)

      assert response = json_response(conn, 200)
      assert response["success"] == true
      assert response["data"]["properties"]["description"] == "Patched"
      assert response["data"]["properties"]["source"] == "test"
    end

    test "rejects a properties replacement that would drop the item's datetime", %{conn: conn} do
      # PATCH replaces `properties` wholesale rather than merging, so omitting
      # datetime here would silently erase the item's temporal information.
      conn =
        patch(conn, ~p"/stac/manage/v1/items/patch-item", %{
          "id" => "patch-item",
          "properties" => %{"description" => "No datetime"}
        })

      assert response = json_response(conn, 400)
      assert response["error"] =~ "properties.datetime is required"
    end

    test "leaves temporal fields untouched when properties are not supplied", %{conn: conn} do
      before = json_response(get(conn, ~p"/stac/manage/v1/items/patch-item"), 200)

      patch(conn, ~p"/stac/manage/v1/items/patch-item", %{
        "id" => "patch-item",
        "bbox" => [-2, -2, 2, 2]
      })

      after_patch = json_response(get(conn, ~p"/stac/manage/v1/items/patch-item"), 200)

      assert after_patch["properties"]["datetime"] == before["properties"]["datetime"]
      assert after_patch["bbox"] == [-2, -2, 2, 2]
    end

    test "returns 404 when patching non-existent item", %{conn: conn} do
      params = %{"id" => "non-existent", "properties" => %{"description" => "Test"}}

      conn = patch(conn, ~p"/stac/manage/v1/items/non-existent", params)
      assert json_response(conn, 404)
    end
  end

  describe "DELETE /items/:id - delete item" do
    setup %{conn: conn} do
      item_params = %{
        "id" => "delete-item",
        "collection_id" => "test-collection",
        "geometry" => %{"type" => "Point", "coordinates" => [0, 0]},
        "bbox" => [-1, -1, 1, 1],
        "properties" => %{"datetime" => "2024-01-01T12:00:00Z"}
      }

      post(conn, ~p"/stac/manage/v1/items", item_params)

      :ok
    end

    test "deletes an item successfully", %{conn: conn} do
      conn = delete(conn, ~p"/stac/manage/v1/items/delete-item")

      assert response = json_response(conn, 200)
      assert response["success"] == true
      assert response["message"] =~ "deleted successfully"

      # Verify it's gone
      get_conn = get(authenticated_conn(build_conn()), ~p"/stac/manage/v1/items/delete-item")
      assert json_response(get_conn, 404)
    end

    test "returns 404 when deleting non-existent item", %{conn: conn} do
      conn = delete(conn, ~p"/stac/manage/v1/items/non-existent")
      assert json_response(conn, 404)
    end
  end

  describe "POST /items/import - bulk import items" do
    test "imports multiple items at once", %{conn: conn} do
      params = %{
        "features" => [
          %{
            "id" => "bulk-item-1",
            "collection_id" => "test-collection",
            "geometry" => %{"type" => "Point", "coordinates" => [0, 0]},
            "bbox" => [-1, -1, 1, 1],
            "properties" => %{"datetime" => "2024-01-01T12:00:00Z", "description" => "Bulk 1"}
          },
          %{
            "id" => "bulk-item-2",
            "collection_id" => "test-collection",
            "geometry" => %{"type" => "Point", "coordinates" => [10, 10]},
            "bbox" => [9, 9, 11, 11],
            "properties" => %{"datetime" => "2024-01-02T12:00:00Z", "description" => "Bulk 2"}
          }
        ]
      }

      conn = post(conn, ~p"/stac/manage/v1/items/import", params)

      assert response = json_response(conn, 200)
      assert response["success"] == true
      assert response["imported"] == 2
      assert response["total"] == 2

      # Verify items were created
      get_conn = get(authenticated_conn(build_conn()), ~p"/stac/manage/v1/items/bulk-item-1")
      assert json_response(get_conn, 200)
    end

    test "reports failures when importing items with invalid data", %{conn: conn} do
      params = %{
        "features" => [
          %{
            "id" => "valid-bulk-item",
            "collection_id" => "test-collection",
            "geometry" => %{"type" => "Point", "coordinates" => [0, 0]},
            "bbox" => [-1, -1, 1, 1],
            "properties" => %{"datetime" => "2024-01-01T12:00:00Z"}
          },
          %{
            # Missing collection_id
            "id" => "invalid-bulk-item",
            "geometry" => %{"type" => "Point", "coordinates" => [0, 0]},
            "bbox" => [-1, -1, 1, 1],
            "properties" => %{"datetime" => "2024-01-01T12:00:00Z"}
          }
        ]
      }

      conn = post(conn, ~p"/stac/manage/v1/items/import", params)

      assert response = json_response(conn, 200)
      assert response["total"] == 2
      assert response["imported"] == 1
      assert response["failed"] == 1
    end

    test "returns 400 when features array is empty", %{conn: conn} do
      params = %{"features" => []}

      conn = post(conn, ~p"/stac/manage/v1/items/import", params)
      assert response = json_response(conn, 400)
      assert response["error"] =~ "at least one"
    end
  end

  describe "Item with assets" do
    test "creates and retrieves item with assets", %{conn: conn} do
      item_params = %{
        "id" => "asset-item",
        "collection_id" => "test-collection",
        "geometry" => %{"type" => "Point", "coordinates" => [0, 0]},
        "bbox" => [-1, -1, 1, 1],
        "properties" => %{"datetime" => "2024-01-01T12:00:00Z"},
        "assets" => %{
          "thumbnail" => %{
            "href" => "https://example.com/thumb.jpg",
            "type" => "image/jpeg",
            "title" => "Thumbnail",
            "roles" => ["thumbnail"]
          }
        }
      }

      post_conn = post(conn, ~p"/stac/manage/v1/items", item_params)
      assert json_response(post_conn, 201)

      # Retrieve and verify assets
      get_conn = get(conn, ~p"/stac/manage/v1/items/asset-item")
      response = json_response(get_conn, 200)

      assert is_map(response["assets"])
      assert response["assets"]["thumbnail"]["href"] == "https://example.com/thumb.jpg"
    end
  end

  describe "Item geometry handling" do
    test "handles Point geometry", %{conn: conn} do
      params = %{
        "id" => "point-item",
        "collection_id" => "test-collection",
        "geometry" => %{"type" => "Point", "coordinates" => [0, 0]},
        "bbox" => [-1, -1, 1, 1],
        "properties" => %{"datetime" => "2024-01-01T12:00:00Z"}
      }

      conn = post(conn, ~p"/stac/manage/v1/items", params)
      assert response = json_response(conn, 201)
      assert response["data"]["geometry"]["type"] == "Point"
    end

    test "handles Polygon geometry", %{conn: conn} do
      params = %{
        "id" => "polygon-item",
        "collection_id" => "test-collection",
        "geometry" => %{
          "type" => "Polygon",
          "coordinates" => [[
            [0, 0],
            [1, 0],
            [1, 1],
            [0, 1],
            [0, 0]
          ]]
        },
        "bbox" => [0, 0, 1, 1],
        "properties" => %{"datetime" => "2024-01-01T12:00:00Z"}
      }

      conn = post(conn, ~p"/stac/manage/v1/items", params)
      assert response = json_response(conn, 201)
      assert response["data"]["geometry"]["type"] == "Polygon"
    end
  end

  describe "Private catalog item access" do
    setup %{conn: conn} do
      # Create a private catalog
      private_catalog_params = %{
        "id" => "private-catalog",
        "title" => "Private Catalog",
        "description" => "Private",
        "private" => true
      }
      post(conn, ~p"/stac/manage/v1/catalogs", private_catalog_params)

      # Create a collection in the private catalog
      private_collection_params = %{
        "id" => "private-collection",
        "title" => "Private Collection",
        "description" => "Private",
        "license" => "CC-BY-4.0",
        "catalog_id" => "private-catalog"
      }
      post(conn, ~p"/stac/manage/v1/collections", private_collection_params)

      # Create an item in the private collection
      item_params = %{
        "id" => "private-item",
        "collection_id" => "private-collection",
        "geometry" => %{"type" => "Point", "coordinates" => [0, 0]},
        "bbox" => [-1, -1, 1, 1],
        "properties" => %{"datetime" => "2024-01-01T12:00:00Z"}
      }
      post(conn, ~p"/stac/manage/v1/items", item_params)

      :ok
    end

    test "rejects unauthenticated access to GET /items (manage endpoint requires auth)", %{} do
      unauth_conn = build_conn()
      conn = get(unauth_conn, ~p"/stac/manage/v1/items")
      assert json_response(conn, 401)
    end

    test "rejects unauthenticated access to GET /items/:id (manage endpoint requires auth)", %{} do
      unauth_conn = build_conn()
      conn = get(unauth_conn, ~p"/stac/manage/v1/items/private-item")
      assert json_response(conn, 401)
    end
  end

  describe "STAC created/updated" do
    setup %{conn: conn} do
      post(conn, ~p"/stac/manage/v1/items", %{
        "id" => "timestamped-item",
        "collection_id" => "test-collection",
        "geometry" => %{"type" => "Point", "coordinates" => [0, 0]},
        "properties" => %{"datetime" => "2024-01-01T12:00:00Z", "description" => "Timestamped"}
      })

      :ok
    end

    test "GET nests RFC 3339 created/updated inside properties", %{conn: conn} do
      conn = get(conn, ~p"/stac/manage/v1/items/timestamped-item")
      assert response = json_response(conn, 200)

      assert {:ok, _, 0} = DateTime.from_iso8601(response["properties"]["created"])
      assert {:ok, _, 0} = DateTime.from_iso8601(response["properties"]["updated"])

      # STAC keeps these in properties for items, unlike collections and catalogs
      refute Map.has_key?(response, "created")
      refute Map.has_key?(response, "updated")
    end

    test "existing properties survive alongside the timestamps", %{conn: conn} do
      conn = get(conn, ~p"/stac/manage/v1/items/timestamped-item")
      response = json_response(conn, 200)

      assert response["properties"]["description"] == "Timestamped"
      assert response["properties"]["datetime"] == "2024-01-01T12:00:00Z"
    end

    test "PATCH keeps created stable and reports a fresh updated", %{conn: conn} do
      before = json_response(get(conn, ~p"/stac/manage/v1/items/timestamped-item"), 200)

      patched =
        conn
        |> patch(~p"/stac/manage/v1/items/timestamped-item", %{
          "id" => "timestamped-item",
          "properties" => %{"datetime" => "2024-01-01T12:00:00Z", "description" => "Patched"}
        })
        |> json_response(200)

      assert patched["data"]["properties"]["created"] == before["properties"]["created"]
      assert {:ok, updated, 0} = DateTime.from_iso8601(patched["data"]["properties"]["updated"])
      assert {:ok, created, 0} = DateTime.from_iso8601(patched["data"]["properties"]["created"])
      assert DateTime.compare(updated, created) in [:gt, :eq]
    end

    test "microsecond precision survives the round trip", %{conn: conn} do
      conn = get(conn, ~p"/stac/manage/v1/items/timestamped-item")
      response = json_response(conn, 200)

      {:ok, created, 0} = DateTime.from_iso8601(response["properties"]["created"])

      # timestamptz(6) + :utc_datetime_usec — second precision would make two
      # writes inside the same second indistinguishable for conflict detection.
      assert {_value, 6} = created.microsecond
    end

    test "index exposes created/updated per feature", %{conn: conn} do
      conn = get(conn, ~p"/stac/manage/v1/items")
      response = json_response(conn, 200)

      item = Enum.find(response["features"], &(&1["id"] == "timestamped-item"))
      assert {:ok, _, 0} = DateTime.from_iso8601(item["properties"]["created"])
    end
  end
end
