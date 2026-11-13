defmodule ZeroWeatherWeb.Router do
  use ZeroWeatherWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ZeroWeatherWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ZeroWeatherWeb do
    pipe_through :browser

    live "/", WeatherLive
  end

  scope "/api/v1", ZeroWeatherWeb do
    pipe_through :api

    get "/health", ApiController, :health
    get "/locations", ApiController, :locations
    get "/nowcast", ApiController, :nowcast
    get "/radar", ApiController, :radar
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:zero_weather, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ZeroWeatherWeb.Telemetry
    end
  end
end
