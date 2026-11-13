defmodule ZeroWeatherWeb.ApiControllerTest do
  use ZeroWeatherWeb.ConnCase

  test "GET /api/v1/health", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/health")
    assert json_response(conn, 200)["status"] == "ok"
  end

  test "GET /api/v1/locations", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/locations")
    resp = json_response(conn, 200)
    assert is_list(resp["locations"])
    assert Enum.any?(resp["locations"], &(&1["id"] == "ghent"))
    assert Enum.any?(resp["locations"], &(&1["id"] == "brussels"))
  end

  test "GET /api/v1/radar", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/radar")
    resp = json_response(conn, 200)
    assert Map.has_key?(resp, "frames")
  end

  test "GET /api/v1/nowcast for Ghent", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/nowcast?lat=51.0543&lon=3.7174")
    resp = json_response(conn, 200)
    assert Map.has_key?(resp, "current")
    assert Map.has_key?(resp, "timeline")
    assert Map.has_key?(resp, "summary")
  end
end
