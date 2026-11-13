defmodule ZeroWeatherWeb.PageControllerTest do
  use ZeroWeatherWeb.ConnCase

  test "GET / loads ZeroWeather LiveView", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "ZeroWeather"
    assert html_response(conn, 200) =~ "Belgium"
  end
end
