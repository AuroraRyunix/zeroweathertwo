defmodule ZeroWeatherWeb.WeatherLiveTest do
  # Uses the shared ETS cache with fixed keys, so it must not run in parallel with other cache users.
  use ZeroWeatherWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ZeroWeather.{Cache, Nowcast}

  # Ghent, as the default location: the cache keys use these rounded coordinates
  @weather_key {:nowcast, 51.054, 3.717}
  @buienradar_key {:buienradar_raintext, 51.05, 3.72}

  # A grid whose rain is a shower 12 cells upwind (west) of the point, drifting east
  defp own_model(frame_time) do
    n = 121

    rows =
      for y <- 0..(n - 1) do
        List.to_tuple(
          for x <- 0..(n - 1) do
            if (x + 0.5 - 48) ** 2 + (y + 0.5 - 60.5) ** 2 <= 9, do: 2.0, else: 0.0
          end
        )
      end

    %{
      grid: %{
        n: n,
        cx: n / 2,
        cy: n / 2,
        cell_km: 1.5,
        lat: 51.05,
        lon: 3.72,
        rows: List.to_tuple(rows)
      },
      frame_time: frame_time,
      motion: %{dx: 2.0, dy: 0.0, quality: 0.9},
      lat: 51.05,
      lon: 3.72
    }
  end

  setup do
    frame_time = System.os_time(:second) - 120

    frames =
      for k <- 0..2 do
        t = frame_time - k * 600

        %{
          time: t,
          iso_time: t |> DateTime.from_unix!() |> DateTime.to_iso8601(),
          path: "/v2/radar/live-test-#{k}",
          tile_url_template: "https://example.invalid/tiles/#{k}/{z}/{x}/{y}.png",
          is_nowcast: false
        }
      end

    Cache.put(
      :radar_metadata,
      %{
        generated_at: frame_time,
        host: "https://example.invalid",
        frames: Enum.reverse(frames),
        latest_frame: hd(frames)
      },
      120
    )

    Cache.put(
      @weather_key,
      %{
        lat: 51.054,
        lon: 3.717,
        elevation: 9.0,
        current: %{
          temperature: 9.0,
          humidity: 70,
          precipitation: 0.0,
          wind_speed: 8.0,
          wind_direction: 300,
          pressure: 1012.0,
          weather_code: 3,
          condition_text: "Overcast",
          condition_icon: "☁️"
        },
        timeline: [],
        summary: "Open-Meteo summary",
        air_quality: %{eaqi: 20, label: "Good", pm2_5: 5.0, pm10: 8.0, no2: 10.0, o3: 50.0},
        updated_at: DateTime.to_iso8601(DateTime.utc_now())
      },
      120
    )

    # Buienradar says: dry for now. 24 slots of 5 minutes starting at the next 5-minute mark, on the local clock
    now = DateTime.utc_now()
    first = DateTime.add(now, 300 - rem(DateTime.to_unix(now), 300), :second)

    slots =
      Enum.map_join(0..23, "\n", fn i ->
        "000|" <> Nowcast.local_time(DateTime.add(first, i * 300, :second))
      end)

    {:ok, parsed} = Nowcast.parse(slots)
    Cache.put(@buienradar_key, %{slots: parsed, fetched_at: DateTime.utc_now()}, 120)

    # our own model for the newest frame, so no tiles are fetched
    Cache.put({:radar_nowcast_model, 51.05, 3.72, frame_time}, own_model(frame_time), 120)

    :ok
  end

  test "shows our own radar nowcast once it is computed, with Buienradar as the cross-check", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/")

    # the page is usable straight away, on Buienradar's forecast
    assert html =~ "Rain countdown"
    assert html =~ "radar-nowcast-card"

    html = render_async(view)

    assert html =~ "Our own nowcast"
    assert html =~ "Rain is drifting from the W"
    assert html =~ "Cross-check, Buienradar"
    assert html =~ "Radar frame"
    # the shower reaches the point within the 2 hours, so the headline is a countdown
    assert html =~ "Dry for the next"
    assert html =~ "Rain starting at"
    refute html =~ "Computing our own radar nowcast"
  end

  test "falls back to Buienradar when our own nowcast cannot be built", %{conn: conn} do
    # no radar frames at all: the own nowcast fails, Buienradar keeps the card alive
    Cache.put(
      :radar_metadata,
      %{generated_at: 0, host: "https://example.invalid", frames: [], latest_frame: nil},
      120
    )

    {:ok, view, _html} = live(conn, ~p"/")
    html = render_async(view)

    assert html =~ "Rain countdown"
    assert html =~ "Buienradar 5-minute radar nowcast"
    refute html =~ "Our own nowcast"
    assert html =~ "Dry for the next 2 hours"
  end

  test "the slider gets forecast frames shifted along the drift once our nowcast is known", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")
    html = render_async(view)

    # the drift in the model is 2 cells / 10 min towards the east
    assert html =~ "Forecast (+60m)"
  end

  test "forecast frames carry the drift as an east/north shift in km" do
    past = [%{is_nowcast: false, time: 1000, tile_url_template: "t"}]
    motion = %{motion: %{known: true, speed_km_h: 30.0, toward_deg: 90}}

    frames = ZeroWeatherWeb.WeatherLive.with_forecast(past, motion)
    assert length(frames) == 7
    last = List.last(frames)
    assert last.forecast_min == 60 and last.is_nowcast
    assert_in_delta last.shift_km.east, 30.0, 0.01
    assert_in_delta last.shift_km.north, 0.0, 0.01
    assert ZeroWeatherWeb.WeatherLive.frame_event(last).shiftEast == 30.0

    # unknown drift: no forecast frames
    assert ZeroWeatherWeb.WeatherLive.with_forecast(past, %{motion: %{known: false}}) == past
    assert ZeroWeatherWeb.WeatherLive.with_forecast(past, nil) == past
  end

  test "moving the slider to a forecast frame updates the frame label", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    render_async(view)

    last =
      view
      |> element("#radar-frame-form input")
      |> render()
      |> then(&Regex.run(~r/max="(\d+)"/, &1))
      |> Enum.at(1)

    html = view |> form("#radar-frame-form", %{"index" => last}) |> render_change()

    assert html =~ "Forecast +60 min"
    assert_push_event(view, "change-radar-frame", %{shiftEast: east})
    assert east > 0
  end

  test "the precipitation chart uses 5-minute steps of our nowcast", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    html = render_async(view)

    assert html =~ "Precipitation Nowcast (Next 2 Hours)"
    assert html =~ "5-minute expected rain rate"
    refute html =~ "15-minute expected rainfall"
  end

  test "chart steps: 24 five-minute bars, or the 15-minute timeline as fallback" do
    series =
      for m <- 0..119,
          do: %{time: "12:#{m}", mm_h: 2.0, mean_mm_h: 1.0, chance: if(m < 5, do: 80, else: 5)}

    {:five_minute, steps} = ZeroWeatherWeb.WeatherLive.chart_steps(%{series: series}, [])
    assert length(steps) == 24
    assert hd(steps).probability == 80 and hd(steps).precip_mm == 1.0

    assert {:fifteen_minute, [%{label: "12:00"}]} =
             ZeroWeatherWeb.WeatherLive.chart_steps(nil, [%{time: "12:00"}])
  end
end
