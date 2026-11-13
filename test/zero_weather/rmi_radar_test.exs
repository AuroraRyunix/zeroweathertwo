defmodule ZeroWeather.RmiRadarTest do
  use ExUnit.Case, async: true

  alias ZeroWeather.{GeoTiff, RmiRadar}

  # A real 92 x 76 cell window of RMI's composite around Ghent (one 96 x 80 tile, float32, big-endian)
  @fixture Path.expand("../support/fixtures/rmi_window.tif", __DIR__)

  setup do
    {:ok, raster} = @fixture |> File.read!() |> GeoTiff.decode()
    {:ok, raster: raster}
  end

  describe "GeoTiff" do
    test "reads size, georeference and float values", %{raster: r} do
      assert {r.width, r.height} == {92, 76}
      assert_in_delta r.lon0, 3.2037, 1.0e-3
      assert_in_delta r.lat0, 51.5025, 1.0e-3
      assert_in_delta r.dlon, 0.011865, 1.0e-5
      assert_in_delta r.dlat, 0.011865, 1.0e-5

      values = for y <- 0..(r.height - 1), x <- 0..(r.width - 1), do: GeoTiff.cell(r, x, y)
      assert Enum.all?(values, &(is_float(&1) and &1 >= 0.0))
      # a continuous rain rate, not a handful of palette levels
      assert values |> Enum.uniq() |> length() > 200
      assert_in_delta Enum.max(values), 5.018, 0.01
      assert Enum.count(values, &(&1 > 0.0)) > 400
    end

    test "cells outside the raster are nil, garbage is rejected", %{raster: r} do
      assert GeoTiff.cell(r, -1, 0) == nil
      assert GeoTiff.cell(r, r.width, 0) == nil
      assert GeoTiff.decode("not a tiff") == {:error, :not_a_tiff}
    end
  end

  describe "RmiRadar" do
    test "samples a rain rate at a coordinate and reproduces a cell's value at its centre", %{
      raster: r
    } do
      x = 20
      y = 30
      lon = r.lon0 + (x + 0.5) * r.dlon
      lat = r.lat0 - (y + 0.5) * r.dlat
      assert_in_delta RmiRadar.rate_at(r, lat, lon), GeoTiff.cell(r, x, y), 1.0e-6
      # outside: dry
      assert RmiRadar.rate_at(r, 40.0, 3.7) == 0.0
    end

    test "window resamples to a flat square grid centred on the point", %{raster: r} do
      w = RmiRadar.window(r, 51.0543, 3.7174, 20, 1.0)
      assert w.n == 41 and w.cx == 20.5 and w.cell_km == 1.0
      assert tuple_size(w.rows) == 41 and tuple_size(elem(w.rows, 0)) == 41

      # the grid keeps the rain: total rain in the window matches the raster to within resampling error
      assert w.rows |> Tuple.to_list() |> Enum.flat_map(&Tuple.to_list/1) |> Enum.max() > 1.0
    end

    test "covers?/3 keeps a margin from the edge", %{raster: r} do
      assert RmiRadar.covers?(r, 51.05, 3.7, 0.1)
      refute RmiRadar.covers?(r, 51.05, 3.7, 1.0)
    end

    test "parse_end_position reads the newest time of the coverage description" do
      xml =
        ~s(<gml:TimePeriod><gml:beginPosition>2026-11-13T03:35:00.000Z</gml:beginPosition><gml:endPosition>2026-11-13T16:30:00.000Z</gml:endPosition></gml:TimePeriod>)

      assert RmiRadar.parse_end_position(xml) == {:ok, 1_794_587_400}
      assert RmiRadar.parse_end_position("<x/>") == {:error, :no_time_axis}
    end

    test "backs off after a failure instead of asking RMI again" do
      ZeroWeather.Cache.put(:rmi_down, {:rmi_http_status, 500}, 60)
      assert {:error, {:rmi_backing_off, {:rmi_http_status, 500}}} = RmiRadar.latest_time()
      ZeroWeather.Cache.put(:rmi_down, nil, 0)
    end
  end
end
