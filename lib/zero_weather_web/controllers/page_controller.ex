defmodule ZeroWeatherWeb.PageController do
  use ZeroWeatherWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
