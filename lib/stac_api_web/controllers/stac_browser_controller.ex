defmodule StacApiWeb.StacBrowserController do
  use StacApiWeb, :controller
  require Logger
  alias StacApi.Repo
  alias StacApi.Data.{Catalog, Collection, Item, Search}
  import Ecto.Query

  plug :assign_browse_authenticated

  def landing(conn, _params) do
    conn
    |> render(:landing)
  end

  def index(conn, _params) do
    authenticated = conn.assigns[:browse_authenticated] || false

    catalogs_query =
      if authenticated do
        from(c in Catalog, where: c.depth == 0, order_by: [asc: c.id])
      else
        from(c in Catalog,
          where: c.depth == 0 and (c.private == false or is_nil(c.private)),
          order_by: [asc: c.id]
        )
      end

    catalogs = Repo.all(catalogs_query)

    root_collections =
      Repo.all(
        from(c in Collection,
          where: is_nil(c.catalog_id),
          order_by: [asc: c.id]
        )
      )

    items =
      catalogs
      |> Enum.map(fn catalog ->
        %{
          id: catalog.id,
          title: catalog.title || catalog.id,
          description: catalog.description,
          type: "Catalog",
          path: "catalog/#{catalog.id}",
          is_directory: true
        }
      end)

    collection_items =
      root_collections
      |> Enum.map(fn collection ->
        item_count =
          Repo.aggregate(
            from(i in Item, where: i.collection_id == ^collection.id),
            :count,
            :id
          )

        %{
          id: collection.id,
          title: collection.title || collection.id,
          description: collection.description,
          type: "Collection",
          path: "collection/#{collection.id}",
          is_directory: true,
          item_count: item_count
        }
      end)

    all_items = items ++ collection_items

    conn
    |> assign(:items, all_items)
    |> assign(:current_path, "")
    |> assign(:breadcrumbs, [%{name: "Home", path: ""}])
    |> assign(:collection_path, nil)
    |> assign(:current_type, :root)
    |> assign(:current_entity, nil)
    |> render(:index)
  end

  def show(conn, %{"path" => path_segments}) when is_list(path_segments) do
    path = Enum.join(path_segments, "/")
    browse_path(conn, path)
  end

  def show(conn, %{"path" => path}) when is_binary(path) do
    browse_path(conn, path)
  end

  def show(conn, _params) do
    redirect(conn, to: ~p"/stac/web/browse")
  end

  def search(conn, params) do
    search_params = normalize_search_params(params)

    case search_params do
      %{} when map_size(search_params) == 0 ->
        conn
        |> assign(:search_results, [])
        |> assign(:search_params, %{})
        |> assign(:total_count, 0)
        |> render(:search)

      _ ->
        authenticated = conn.assigns[:browse_authenticated] || false
        items = Search.search(search_params, authenticated)
        total_count = Search.count_search_results(search_params, authenticated)

        conn
        |> assign(:search_results, items)
        |> assign(:search_params, search_params)
        |> assign(:total_count, total_count)
        |> render(:search)
    end
  end

  def search_api(conn, params) do
    search_params = normalize_search_params(params)

    authenticated = conn.assigns[:browse_authenticated] || false

    items = Search.search(search_params, authenticated)
    total_count = Search.count_search_results(search_params, authenticated)

    features = Enum.map(items, &Search.serialize_item_for_api/1)

    response = %{
      "type" => "FeatureCollection",
      "features" => features,
      "context" => %{
        "returned" => length(features),
        "matched" => total_count,
        "limit" => parse_int(search_params["limit"] || "10")
      }
    }

    conn
    |> put_resp_content_type("application/geo+json")
    |> json(response)
  end

  defp browse_path(conn, path) do
    case parse_path(path) do
      {:catalog, catalog_id} ->
        show_catalog(conn, catalog_id, path)

      {:collection, collection_id} ->
        show_collection(conn, collection_id, path)

      {:item, collection_id, item_id} ->
        show_item(conn, collection_id, item_id, path)

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Invalid path")
        |> redirect(to: ~p"/stac/web/browse")
    end
  end

  defp parse_path(path) do
    case String.split(path, "/", trim: true) do
      ["catalog", catalog_id] ->
        {:catalog, catalog_id}

      ["collection", collection_id] ->
        {:collection, collection_id}

      ["collection", collection_id, "item", item_id] ->
        {:item, collection_id, item_id}

      _ ->
        {:error, :invalid_path}
    end
  end

  defp show_catalog(conn, catalog_id, path) do
    case Repo.get(Catalog, catalog_id) do
      nil ->
        conn
        |> put_flash(:error, "Catalog not found")
        |> redirect(to: ~p"/stac/web/browse")

      catalog ->
        authenticated = conn.assigns[:browse_authenticated] || false

        if catalog.private == true && !authenticated do
          conn
          |> put_flash(:error, "Catalog not found")
          |> redirect(to: ~p"/stac/web/browse")
        else
          child_catalogs =
            Repo.all(
              from(c in Catalog,
                where: c.parent_catalog_id == ^catalog_id,
                where: ^authenticated or (c.private == false or is_nil(c.private)),
                order_by: [asc: c.id]
              )
            )

          collections_query =
            if authenticated do
              from(c in Collection, where: c.catalog_id == ^catalog_id, order_by: [asc: c.id])
            else
              from(c in Collection,
                left_join: cat in Catalog,
                on: c.catalog_id == cat.id,
                where:
                  c.catalog_id == ^catalog_id and (is_nil(cat.private) or cat.private != true),
                order_by: [asc: c.id]
              )
            end

          collections = Repo.all(collections_query)

          catalog_items =
            child_catalogs
            |> Enum.map(fn child_catalog ->
              %{
                id: child_catalog.id,
                title: child_catalog.title || child_catalog.id,
                description: child_catalog.description,
                type: "Catalog",
                path: "catalog/#{child_catalog.id}",
                is_directory: true
              }
            end)

          collection_items =
            collections
            |> Enum.map(fn collection ->
              item_count =
                Repo.aggregate(
                  from(i in Item, where: i.collection_id == ^collection.id),
                  :count,
                  :id
                )

              %{
                id: collection.id,
                title: collection.title || collection.id,
                description: collection.description,
                type: "Collection",
                path: "collection/#{collection.id}",
                is_directory: true,
                item_count: item_count
              }
            end)

          all_items = catalog_items ++ collection_items
          breadcrumbs = build_breadcrumbs_from_catalog(catalog)

          conn
          |> assign(:items, all_items)
          |> assign(:current_path, path)
          |> assign(:breadcrumbs, breadcrumbs)
          |> assign(:collection_path, nil)
          |> assign(:current_type, :catalog)
          |> assign(:current_entity, catalog)
          |> render(:index)
        end
    end
  end

  defp show_collection(conn, collection_id, path) do
    case Repo.get(Collection, collection_id) do
      nil ->
        conn
        |> put_flash(:error, "Collection not found")
        |> redirect(to: ~p"/stac/web/browse")

      collection ->
        # Return early if the parent catalog is private and the session is not authenticated
        case ensure_collection_visible(conn, collection) do
          {:halt, conn} ->
            conn

          {:ok, _conn} ->
            items_query =
              from(i in Item,
                where: i.collection_id == ^collection_id,
                order_by: [desc: i.datetime],
                limit: 100
              )

            items = Repo.all(items_query)

            item_entries =
              items
              |> Enum.map(fn item ->
                %{
                  id: item.id,
                  title: get_in(item.properties, ["title"]) || item.id,
                  description: get_in(item.properties, ["description"]),
                  type: "Item",
                  path: "#{path}/item/#{item.id}",
                  is_directory: false,
                  datetime: item.datetime,
                  properties: item.properties
                }
              end)

            breadcrumbs = build_breadcrumbs_from_collection(collection)

            conn
            |> assign(:items, item_entries)
            |> assign(:current_path, path)
            |> assign(:breadcrumbs, breadcrumbs)
            |> assign(:collection_path, collection_id)
            |> assign(:current_type, :collection)
            |> assign(:current_entity, collection)
            |> render(:index)
        end
    end
  end

  defp show_item(conn, collection_id, item_id, path) do
    case Repo.get(Item, item_id) do
      nil ->
        conn
        |> put_flash(:error, "Item not found")
        |> redirect(to: ~p"/stac/web/browse")

      item ->
        if item.collection_id != collection_id do
          conn
          |> put_flash(:error, "Item not found in this collection")
          |> redirect(to: ~p"/stac/web/browse")
        else
          collection = Repo.get(Collection, collection_id)

          case ensure_collection_visible(conn, collection) do
            {:halt, conn} ->
              conn

            {:ok, _conn} ->
              assets = reconstruct_item_assets(item.id, item.stac_extensions || [])

              item_data = %{
                type: "Feature",
                stac_version: item.stac_version || "1.0.0",
                stac_extensions: item.stac_extensions || [],
                id: item.id,
                geometry: item.geometry,
                bbox: item.bbox,
                properties: item.properties || %{},
                assets: assets,
                collection: item.collection_id
              }

              breadcrumbs = build_breadcrumbs_from_item(item, collection)

              conn
              |> assign(:item, item_data)
              |> assign(:current_path, path)
              |> assign(:breadcrumbs, breadcrumbs)
              |> assign(:collection_path, collection_id)
              |> assign(:current_type, :item)
              |> assign(:current_entity, item)
              |> render(:item)
          end
        end
    end
  end

  # Recursively walks up the catalog ancestor chain, building crumbs deepest-first.
  defp catalog_ancestor_crumbs(nil), do: []

  defp catalog_ancestor_crumbs(catalog_id) do
    case Repo.get(Catalog, catalog_id) do
      nil ->
        []

      catalog ->
        catalog_ancestor_crumbs(catalog.parent_catalog_id) ++
          [%{name: catalog.title || catalog.id, path: "catalog/#{catalog.id}"}]
    end
  end

  defp build_breadcrumbs_from_catalog(catalog) do
    [%{name: "Home", path: ""}] ++
      catalog_ancestor_crumbs(catalog.parent_catalog_id) ++
      [%{name: catalog.title || catalog.id, path: "catalog/#{catalog.id}"}]
  end

  defp build_breadcrumbs_from_collection(collection) do
    catalog_crumbs = catalog_ancestor_crumbs(collection.catalog_id)

    [%{name: "Home", path: ""}] ++
      catalog_crumbs ++
      [%{name: collection.title || collection.id, path: "collection/#{collection.id}"}]
  end

  defp build_breadcrumbs_from_item(item, collection) do
    collection_breadcrumbs = build_breadcrumbs_from_collection(collection)
    item_title = get_in(item.properties, ["title"]) || item.id

    collection_breadcrumbs ++
      [%{name: item_title, path: "collection/#{collection.id}/item/#{item.id}"}]
  end

  defp reconstruct_item_assets(item_id, stac_extensions) do
    assets = Repo.all(from(a in StacApi.Data.ItemAsset, where: a.item_id == ^item_id))

    Enum.reduce(assets, %{}, fn asset, acc ->
      asset_data = StacApi.Data.ItemAsset.to_stac_asset(asset, stac_extensions)
      Map.put(acc, asset.asset_key, asset_data)
    end)
  end

  defp ensure_collection_visible(conn, collection) do
    authenticated = conn.assigns[:browse_authenticated] || false

    if collection && collection.catalog_id do
      case Repo.get(Catalog, collection.catalog_id) do
        nil ->
          {:ok, conn}

        catalog ->
          if catalog.private == true && !authenticated do
            conn = conn |> put_flash(:error, "Not found") |> redirect(to: ~p"/stac/web/browse")
            {:halt, conn}
          else
            {:ok, conn}
          end
      end
    else
      {:ok, conn}
    end
  end

  defp normalize_search_params(params) do
    params
    |> Enum.into(%{}, fn
      {key, value} when is_atom(key) -> {to_string(key), value}
      {key, value} -> {key, value}
    end)
    |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
    |> Map.new()
    |> merge_datetime_range()
  end

  # Combine the form's `datetime_start` / `datetime_end` fields (HTML
  # `datetime-local` inputs that omit the timezone) into the single STAC
  # `datetime` parameter expected by `Search.search/1`. Missing sides become
  # the `..` open-range marker.
  defp merge_datetime_range(params) do
    start_str = params["datetime_start"]
    end_str = params["datetime_end"]

    params = Map.drop(params, ["datetime_start", "datetime_end"])

    case {present(start_str), present(end_str)} do
      {nil, nil} -> params
      {s, nil} -> Map.put(params, "datetime", "#{s}/..")
      {nil, e} -> Map.put(params, "datetime", "../#{e}")
      {s, e} -> Map.put(params, "datetime", "#{s}/#{e}")
    end
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(s) when is_binary(s), do: s

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {num, _} -> num
      :error -> 0
    end
  end

  defp parse_int(num) when is_integer(num), do: num
  defp parse_int(_), do: 0

  # Session-based simple browse unlock: check POSTed API key (read-write or read-only)
  def authenticate(conn, params) do
    api_key = Map.get(params, "api_key", "")
    return_to = safe_local_path(Map.get(params, "return_to", "/stac/web/browse"))
    valid_keys = get_valid_browse_keys()

    if api_key in valid_keys do
      conn
      |> put_session(:browse_authenticated, true)
      |> put_flash(:info, "Browse unlocked")
      |> redirect(to: return_to)
    else
      conn
      |> put_flash(:error, "Invalid API key")
      |> redirect(to: return_to)
    end
  end

  defp safe_local_path(path) when is_binary(path) do
    if Regex.match?(~r{\A/stac/web(/|\z)}, path) do
      path
    else
      "/stac/web/browse"
    end
  end

  defp safe_local_path(_), do: "/stac/web/browse"

  defp get_valid_browse_keys do
    api_keys = Application.get_env(:stac_api, :api_keys, %{})
    read_write = Map.get(api_keys, :read_write, []) || []
    read_only = Map.get(api_keys, :read_only, []) || []
    read_write ++ read_only
  end

  def logout(conn, _params) do
    conn
    |> delete_session(:browse_authenticated)
    |> put_flash(:info, "Private browsing locked")
    |> redirect(to: "/stac/web/browse")
  end

  defp assign_browse_authenticated(conn, _opts) do
    assign(conn, :browse_authenticated, get_session(conn, :browse_authenticated) == true)
  end
end
