defmodule ZeroWeather.RmiRadar do
  @moduledoc """
  The Belgian radar rainfall composite of the Royal Meteorological Institute (RMI/KMI), straight from its open-data
  WCS: a real float rain-rate grid (mm/h, 0.0119 degree cells, about 1.3 x 0.8 km, every 5 minutes, all of Belgium
  and surroundings), not a rendered image. This replaces the palette-decoded RainViewer tiles as the input of the
  nowcast; RainViewer remains only as a fallback and for the map pictures.

  A full composite is about 1.9 MB. Frames are fetched once and shared by every viewer (cached by timestamp), so a
  new 5-minute frame costs one download for the whole app.
  """

  alias ZeroWeather.{Cache, GeoTiff}

  @wcs "https://opendata.meteo.be/service/wcs"
  @coverage "radar__belgian_rainfall_composite"
  @frame_ttl 3_600
  @latest_ttl 30
  @failure_ttl 20
  # after an upstream failure, leave RMI alone for a while instead of retrying on every page refresh
  @down_ttl 90

  @doc "Unix time of the newest composite (cached 30 s)."
  def latest_time do
    case Cache.get(:rmi_down) do
      {:ok, reason} -> {:error, {:rmi_backing_off, reason}}
      :error -> fetch_latest_time()
    end
  end

  defp fetch_latest_time do
    result =
      Cache.fetch(:rmi_latest, @latest_ttl, fn ->
        with {:ok, %{status: 200, body: body}} <-
               Req.get(@wcs,
                 params: [
                   service: "WCS",
                   version: "2.0.1",
                   request: "DescribeCoverage",
                   coverageId: @coverage
                 ],
                 receive_timeout: 8_000,
                 retry: false,
                 decode_body: false
               ),
             {:ok, unix} <- parse_end_position(body) do
          {:ok, unix}
        else
          {:ok, %{status: status}} -> {:error, {:rmi_http_status, status}}
          {:error, reason} -> {:error, {:rmi_unreachable, reason}}
        end
      end)

    with {:error, reason} <- result do
      Cache.put(:rmi_down, reason, @down_ttl)
      {:error, reason}
    end
  end

  @doc false
  def parse_end_position(xml) when is_binary(xml) do
    with [_, stamp] <- Regex.run(~r{<gml:endPosition[^>]*>([^<]+)</gml:endPosition>}, xml),
         {:ok, dt, _} <- DateTime.from_iso8601(String.trim(stamp)) do
      {:ok, DateTime.to_unix(dt)}
    else
      _ -> {:error, :no_time_axis}
    end
  end

  @doc "The whole composite at a unix time (a multiple of 300 s), decoded and cached."
  def frame(unix) when is_integer(unix) do
    case Cache.get({:rmi_frame_failed, unix}) do
      {:ok, reason} ->
        {:error, {:recently_failed, reason}}

      :error ->
        case Cache.fetch({:rmi_frame, unix}, @frame_ttl, fn -> fetch_frame(unix) end) do
          {:ok, frame} ->
            {:ok, frame}

          {:error, reason} ->
            Cache.put({:rmi_frame_failed, unix}, reason, @failure_ttl)
            {:error, reason}
        end
    end
  end

  defp fetch_frame(unix) do
    stamp = unix |> DateTime.from_unix!() |> Calendar.strftime("%Y-%m-%dT%H:%M:%S.000Z")

    with {:ok, %{status: 200, body: body}} when is_binary(body) <-
           Req.get(@wcs,
             params: [
               {:service, "WCS"},
               {:version, "2.0.1"},
               {:request, "GetCoverage"},
               {:coverageId, @coverage},
               {:format, "image/tiff"},
               {:subset, "time(\"#{stamp}\")"}
             ],
             receive_timeout: 20_000,
             retry: false,
             decode_body: false
           ),
         {:ok, raster} <- GeoTiff.decode(body) do
      {:ok, Map.put(raster, :time, unix)}
    else
      {:ok, %{status: status}} -> {:error, {:rmi_http_status, status}}
      {:error, reason} -> {:error, {:rmi_frame_failed, reason}}
    end
  end

  # -- sampling ------------------------------------------------------------------------------------

  @doc "Rain rate (mm/h) at a coordinate: bilinear between cell centres, 0.0 outside the raster or on NaN cells."
  def rate_at(raster, lat, lon) do
    fx = (lon - raster.lon0) / raster.dlon - 0.5
    fy = (raster.lat0 - lat) / raster.dlat - 0.5
    x0 = floor(fx)
    y0 = floor(fy)
    tx = fx - x0
    ty = fy - y0

    v00 = cell(raster, x0, y0)
    v10 = cell(raster, x0 + 1, y0)
    v01 = cell(raster, x0, y0 + 1)
    v11 = cell(raster, x0 + 1, y0 + 1)

    v00 * (1 - tx) * (1 - ty) + v10 * tx * (1 - ty) + v01 * (1 - tx) * ty + v11 * tx * ty
  end

  defp cell(raster, x, y) do
    case GeoTiff.cell(raster, x, y) do
      nil -> 0.0
      v when v < 0 -> 0.0
      v -> v * 1.0
    end
  end

  @doc """
  A square window of `2 * half + 1` cells of `cell_km` centred on a point, resampled from the lat/lon raster to a
  local flat grid (x east, y south; same shape as `ZeroWeather.RadarGrid` windows, so the advection code is shared).
  """
  def window(raster, lat, lon, half, cell_km) do
    n = 2 * half + 1
    km_lat = 111.195
    km_lon = km_lat * :math.cos(lat * :math.pi() / 180)

    rows =
      for j <- 0..(n - 1) do
        dlat = -(j + 0.5 - n / 2) * cell_km / km_lat

        for i <- 0..(n - 1) do
          dlon = (i + 0.5 - n / 2) * cell_km / km_lon
          rate_at(raster, lat + dlat, lon + dlon)
        end
        |> List.to_tuple()
      end

    %{n: n, cx: n / 2, cy: n / 2, cell_km: cell_km, lat: lat, lon: lon, rows: List.to_tuple(rows)}
  end

  @doc "True when the point lies inside the raster with a margin (degrees), i.e. the composite can serve it."
  def covers?(raster, lat, lon, margin_deg \\ 0.5) do
    lon >= raster.lon0 + margin_deg and
      lon <= raster.lon0 + raster.width * raster.dlon - margin_deg and
      lat <= raster.lat0 - margin_deg and
      lat >= raster.lat0 - raster.height * raster.dlat + margin_deg
  end
end
