defmodule StacApiWeb.ItemJSON do
  @moduledoc """
  STAC JSON representation of a `StacApi.Data.Item`.

  Single source of truth for the item payload returned by
  `StacApiWeb.ItemsCrudController` (create / show / update / patch / index).
  Links and assets are passed in by the caller: links come from
  `StacApiWeb.DynamicLinkGenerator` and vary per request, assets are
  reconstructed from the normalized `item_assets` table.

  Note this is deliberately *not* the same rendering as
  `StacApi.Data.Search.serialize_item_for_api/1`, which serves the public read
  API. That one uses string keys, converts `Geo` structs to plain GeoJSON,
  merges `datetime` into `properties`, and echoes the stored links rather than
  generated ones. Unifying the two is worthwhile but changes payloads on one
  side or the other, so it is not part of this extraction.
  """

  alias StacApi.Data.Item

  @doc """
  Render an item as a STAC Item (GeoJSON Feature) object.
  """
  def to_stac(%Item{} = item, links, assets) do
    %{
      type: "Feature",
      stac_version: item.stac_version || "1.0.0",
      stac_extensions: item.stac_extensions || [],
      id: item.id,
      geometry: item.geometry,
      bbox: item.bbox,
      properties: item.properties || %{},
      assets: assets,
      collection: item.collection_id,
      links: links
    }
  end
end
