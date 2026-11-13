defmodule ZeroWeatherWeb.ApiController do
  use ZeroWeatherWeb, :controller

  alias ZeroWeather.{Weather, Radar, Locations, Nowcast}

  def health(conn, _params) do
    json(conn, %{
      status: "ok",
      app: "zero_weather",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  def locations(conn, _params) do
    json(conn, %{locations: Locations.list()})
  end

  def radar(conn, _params) do
    case Radar.get_radar_meta() do
      {:ok, meta} ->
        json(conn, meta)

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Failed to fetch radar metadata", reason: inspect(reason)})
    end
  end

  def nowcast(conn, params) do
    lat = parse_float(params["lat"])
    lon = parse_float(params["lon"])

    cond do
      is_nil(lat) or is_nil(lon) ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Missing or invalid 'lat' and 'lon' query parameters"})

      lat < 49.0 or lat > 52.0 or lon < 2.0 or lon > 7.0 ->
        # Still return forecast, but add a notice if outside Belgium
        serve_forecast(conn, lat, lon)

      true ->
        serve_forecast(conn, lat, lon)
    end
  end

  defp serve_forecast(conn, lat, lon) do
    case Weather.get_nowcast(lat, lon) do
      {:ok, data} ->
        json(conn, Map.put(data, :radar_nowcast, radar_nowcast(lat, lon)))

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Failed to retrieve nowcast", details: inspect(reason)})
    end
  end

  # 5-minute Buienradar radar nowcast with a 1-minute countdown; an error here must not fail the whole response
  defp radar_nowcast(lat, lon) do
    case Nowcast.get(lat, lon) do
      {:ok, nowcast} -> nowcast
      {:error, reason} -> %{error: "Radar nowcast unavailable", details: inspect(reason)}
    end
  end

  defp parse_float(nil), do: nil
  defp parse_float(val) when is_float(val), do: val
  defp parse_float(val) when is_integer(val), do: val * 1.0

  defp parse_float(val) when is_binary(val) do
    case Float.parse(val) do
      {num, _} -> num
      :error -> nil
    end
  end
end
