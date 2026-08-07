defmodule StacApiWeb.StacBrowserControllerTest do
  use StacApiWeb.ConnCase, async: false

  alias StacApi.Data.Catalog

  test "browse page shows a visible unlock form for anonymous users", %{conn: conn} do
    conn = get(conn, ~p"/stac/web/browse")
    html = html_response(conn, 200)

    assert html =~ "Enter the read-only API key to unlock private browse data."
    assert html =~ ~s(action="/stac/web/auth")
    assert html =~ ~s(name="api_key")
    assert html =~ "Unlock private browse"
  end

  test "posting a valid read-only key stores browse session auth", %{conn: conn} do
    read_only_key =
      :stac_api
      |> Application.get_env(:api_keys, %{})
      |> Map.get(:read_only, [])
      |> List.first()

    assert is_binary(read_only_key)

    conn =
      post(conn, ~p"/stac/web/auth", %{
        "api_key" => read_only_key,
        "return_to" => "/stac/web/browse"
      })

    assert redirected_to(conn) =~ "/stac/web/browse"
    assert get_session(conn, :browse_authenticated) == true
  end

  test "invalid read-only key does not unlock browse session", %{conn: conn} do
    conn =
      post(conn, ~p"/stac/web/auth", %{
        "api_key" => "wrong-key",
        "return_to" => "/stac/web/browse"
      })

    assert redirected_to(conn) =~ "/stac/web/browse"
    assert get_session(conn, :browse_authenticated) != true
  end

  test "private catalog is hidden from unauthenticated browse and visible after unlock", %{conn: conn} do
    catalog =
      %Catalog{}
      |> Catalog.changeset(%{
        id: "private-browser-catalog",
        title: "Private Browser Catalog",
        private: true,
        depth: 0
      })
      |> Repo.insert!()

    unauth_conn = get(conn, ~p"/stac/web/browse")
    unauth_html = html_response(unauth_conn, 200)
    refute unauth_html =~ catalog.title

    auth_conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> put_session(:browse_authenticated, true)
      |> get(~p"/stac/web/browse")

    auth_html = html_response(auth_conn, 200)
    assert auth_html =~ catalog.title
  end
end
