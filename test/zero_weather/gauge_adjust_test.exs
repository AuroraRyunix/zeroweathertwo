defmodule ZeroWeather.GaugeAdjustTest do
  use ExUnit.Case, async: false

  alias ZeroWeather.{Cache, GaugeAdjust}

  # a tiny raster whose bilinear sample is `rate` everywhere
  defp raster(time, rate) do
    %{
      width: 2,
      height: 2,
      data:
        <<rate::float-32-little, rate::float-32-little, rate::float-32-little,
          rate::float-32-little>>,
      endian: :little,
      lon0: 3.0,
      lat0: 52.0,
      dlon: 1.0,
      dlat: -1.0,
      time: time
    }
  end

  defp gauge(mm_each) do
    base = 1_800_000_000

    %{
      station: "Test",
      station_lat: 51.5,
      station_lon: 3.5,
      depression: 1.0,
      records: for(k <- 0..2, do: %{unix: base - k * 600, time: "t#{k}", mm: mm_each})
    }
  end

  test "too little rain: no correction" do
    base = 1_800_000_000
    for k <- 0..5, do: Cache.put({:rmi_frame, base - k * 300}, raster(base - k * 300, 0.1), 60)
    info = GaugeAdjust.compare(gauge(0.02))
    assert info.factor == 1.0
    refute info[:applied]
  end

  test "radar reading half of what the gauge caught scales rates up, damped" do
    base = 1_800_000_000

    # radar 6 mm/h = 1 mm per 10 min per record... use 3 mm/h = 0.5 mm per interval; gauge 1 mm per interval
    for k <- 0..8, do: Cache.put({:rmi_frame, base - k * 300}, raster(base - k * 300, 3.0), 60)
    info = GaugeAdjust.compare(gauge(1.0))
    assert info.applied
    assert info.ratio > 1.5 and info.ratio <= 2.0
    assert info.factor > 1.0 and info.factor <= info.ratio
  end
end
