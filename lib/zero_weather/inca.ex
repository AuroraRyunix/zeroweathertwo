defmodule ZeroWeather.Inca do
  @moduledoc """
  RMI's INCA-BE precipitation nowcast (open data WCS coverage `inca__Precipitation`, 10-minute valid times, about
  3.5 hours ahead, 1.3 km grid). Used only as an independent benchmark: the live verifier scores it next to our own
  forecast on the same outcomes. Only the latest run is served, so its history cannot be fetched afterwards; the
  verifier asks for it while it runs.

  Frames are requested for a small box around Flanders (about 50 kB instead of 7 MB for the whole domain). The values
  are mm/h with -1 where there is no precipitation (or no data), which counts as dry here.
  """

  alias ZeroWeather.{Cache, GeoTiff}

  @wcs "https://opendata.meteo.be/service/wcs"
  @box {50.7, 51.35, 3.1, 4.8}
  @ttl 900

  @doc "The Flanders box (south, north, west, east) INCA frames are cut to."
  def box, do: @box

  @doc "INCA's field at a valid time (unix, multiple of 600), cut to the box. Cached."
  def frame(valid_unix) when is_integer(valid_unix) do
    if Application.get_env(:zero_weather, :rmi_radar, true) == false do
      {:error, :disabled}
    else
      Cache.fetch({:inca_frame, valid_unix}, @ttl, fn -> fetch(valid_unix) end)
    end
  end

  defp fetch(valid_unix) do
    {s, n, w, e} = @box
    stamp = valid_unix |> DateTime.from_unix!() |> Calendar.strftime("%Y-%m-%dT%H:%M:%S.000Z")

    case Req.get(@wcs,
           params: [
             {:service, "WCS"},
             {:version, "2.0.1"},
             {:request, "GetCoverage"},
             {:coverageId, "inca__Precipitation"},
             {:format, "image/tiff"},
             {:subset, "time(\"#{stamp}\")"},
             {:subset, "Lat(#{s},#{n})"},
             {:subset, "Long(#{w},#{e})"}
           ],
           receive_timeout: 15_000,
           retry: false,
           decode_body: false
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> GeoTiff.decode(body)
      {:ok, %{status: status}} -> {:error, {:inca_http_status, status}}
      {:error, reason} -> {:error, {:inca_unreachable, reason}}
    end
  end

  @doc """
  INCA at a coordinate: `point` is the rate (mm/h) of the cell containing it, `share` the fraction of the 3 x 3 cells
  around it (about 4 km) that rain (at least 0.1 mm/h), usable as a probability.
  """
  def at(raster, lat, lon) do
    i = floor((lon - raster.lon0) / raster.dlon)
    j = floor((raster.lat0 - lat) / raster.dlat)

    cells = for dj <- -1..1, di <- -1..1, do: rate(raster, i + di, j + dj)

    %{point: rate(raster, i, j), share: Enum.count(cells, &(&1 >= 0.1)) / 9}
  end

  defp rate(raster, i, j) do
    case GeoTiff.cell(raster, i, j) do
      v when is_number(v) and v >= 0 -> v
      _ -> 0.0
    end
  end
end
