# Seed file: create a private catalog, a collection and a sample item for manual testing
alias StacApi.Repo
alias StacApi.Data.{Catalog, Collection, Item}

# Ensure Repo is started when running via `mix run`
Application.ensure_all_started(:stac_api)

repo = Repo

# Create private catalog
catalog_id = "lgeo_internal"
collection_id = "science_project_a"
item_id = "science_project_a_item_1"

catalog = repo.get(Catalog, catalog_id)
if is_nil(catalog) do
  IO.puts("Inserting catalog #{catalog_id} (private)")
  repo.insert!(%Catalog{id: catalog_id, title: "LGeo Internal", description: "Private catalog for internal projects", private: true, depth: 0})
else
  IO.puts("Catalog #{catalog_id} already exists")
end

collection = repo.get(Collection, collection_id)
if is_nil(collection) do
  IO.puts("Inserting collection #{collection_id} (under #{catalog_id})")
  repo.insert!(%Collection{id: collection_id, title: "Science Project A", description: "A test collection", catalog_id: catalog_id})
else
  IO.puts("Collection #{collection_id} already exists")
end

item = repo.get(Item, item_id)
if is_nil(item) do
  IO.puts("Inserting item #{item_id} into collection #{collection_id}")
  geom = %Geo.Point{coordinates: {24.0, 59.0}, srid: 4326}
  repo.insert!(%Item{id: item_id, geometry: geom, collection_id: collection_id, properties: %{"title" => "Test Item 1", "description" => "Test item in private collection"}})
else
  IO.puts("Item #{item_id} already exists")
end

IO.puts("Seeding complete")
