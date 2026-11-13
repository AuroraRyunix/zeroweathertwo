defmodule ZeroWeather.GaugesTest do
  use ExUnit.Case, async: true

  alias ZeroWeather.Gauges

  # Shape of RMI's aws:aws_10min GeoJSON features (values copied from a real Melle record)
  defp feature(time, precip, t, rh),
    do: %{
      "properties" => %{
        "code" => 6434,
        "timestamp" => time,
        "precip_quantity" => precip,
        "temp_dry_shelter_avg" => t,
        "humidity_rel_shelter_avg" => rh
      }
    }

  test "parse keeps the numbers and sorts newest first" do
    {:ok, [a, b]} =
      Gauges.parse([
        feature("2026-11-13T16:20:00Z", 0, 6.8881, 79.508423),
        feature("2026-11-13T16:30:00Z", 0.4, 6.264333, 81.69389)
      ])

    assert a.time == "2026-11-13T16:30:00Z" and b.time == "2026-11-13T16:20:00Z"
    assert a.precip_mm_10min == 0.4 and a.temperature == 6.264333
    assert Gauges.parse([]) == {:error, :no_records}
  end

  test "dew point follows the Magnus formula" do
    # 6.26 C at 81.7 % -> about 3.5 C
    assert_in_delta Gauges.dew_point(6.264333, 81.69389), 3.4, 0.2
    # saturated air: dew point equals temperature
    assert_in_delta Gauges.dew_point(10.0, 100.0), 10.0, 0.1
    assert Gauges.dew_point(nil, 50) == nil
  end

  test "virga risk needs a dew-point depression of 8 degrees or more" do
    assert Gauges.virga_risk?(%{depression: 9.5})
    refute Gauges.virga_risk?(%{depression: 2.8})
    refute Gauges.virga_risk?(nil)
  end

  test "nearest station is found within 60 km only" do
    assert {:ok, %{name: "Melle"}, d} = Gauges.nearest(51.0543, 3.7174)
    assert d < 15
    assert Gauges.nearest(50.63, 5.58) == {:error, :no_station_nearby}
  end
end
