defmodule ZeroWeatherWeb.WeatherLive do
  use ZeroWeatherWeb, :live_view

  alias ZeroWeather.{Weather, Radar, Locations, Nowcast, RadarNowcast, Gauges}

  # 3 minutes
  @refresh_interval 180_000
  # 750ms per radar frame
  @animation_speed 750

  @impl true
  def mount(_params, _session, socket) do
    # Ghent
    default_loc = Locations.default()
    locations = Locations.list()

    radar_meta =
      case Radar.get_radar_meta() do
        {:ok, meta} -> meta
        _ -> %{frames: [], latest_frame: nil}
      end

    frames = radar_meta.frames || []
    # Default to last past frame (live radar)
    latest_past_idx =
      Enum.find_index(Enum.reverse(frames), fn f -> not f.is_nowcast end)

    active_frame_idx =
      if latest_past_idx do
        length(frames) - 1 - latest_past_idx
      else
        max(0, length(frames) - 1)
      end

    weather =
      case Weather.get_nowcast(default_loc.lat, default_loc.lon) do
        {:ok, data} -> data
        _ -> nil
      end

    if connected?(socket) do
      schedule_refresh()
      schedule_nowcast_tick()
    end

    socket =
      socket
      |> assign(:page_title, "#{default_loc.name} · Real-time Nowcast")
      |> assign(:locations, locations)
      |> assign(:active_location, default_loc)
      |> assign(:weather, weather)
      |> assign(:buienradar, fetch_buienradar(default_loc, nil))
      |> assign(:own_nowcast, nil)
      |> assign(:own_loading, connected?(socket))
      |> assign(:own_error, nil)
      |> assign(:gauge, nil)
      |> pick_nowcast()
      |> start_own_nowcast(default_loc)
      |> assign(:radar_meta, radar_meta)
      |> assign(:frames, frames)
      |> assign(:active_frame_index, active_frame_idx)
      |> assign(:is_playing, false)
      |> assign(:error_message, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("select_location", %{"id" => id}, socket) do
    loc = Locations.find_by_id(id)
    load_location(socket, loc)
  end

  @impl true
  def handle_event("set_coords", %{"lat" => lat, "lon" => lon, "name" => name}, socket) do
    loc = %{
      id: "custom",
      name: name || "Selected Point",
      region: "Custom Coordinates",
      lat: Float.round(lat * 1.0, 4),
      lon: Float.round(lon * 1.0, 4)
    }

    load_location(socket, loc)
  end

  @impl true
  def handle_event("set_frame", %{"index" => idx_str}, socket) do
    case Integer.parse(idx_str) do
      {idx, _} when idx >= 0 ->
        frame = Enum.at(socket.assigns.frames, idx)

        socket =
          socket
          |> assign(:active_frame_index, idx)
          |> push_event("change-radar-frame", frame_event(frame))

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_play", _params, socket) do
    is_playing = !socket.assigns.is_playing

    if is_playing do
      Process.send_after(self(), :tick_animation, @animation_speed)
    end

    {:noreply, assign(socket, :is_playing, is_playing)}
  end

  @impl true
  def handle_info(:tick_animation, socket) do
    if socket.assigns.is_playing and length(socket.assigns.frames) > 0 do
      next_idx = rem(socket.assigns.active_frame_index + 1, length(socket.assigns.frames))
      frame = Enum.at(socket.assigns.frames, next_idx)

      Process.send_after(self(), :tick_animation, @animation_speed)

      socket =
        socket
        |> assign(:active_frame_index, next_idx)
        |> push_event("change-radar-frame", frame_event(frame))

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    loc = socket.assigns.active_location

    weather =
      case Weather.get_nowcast(loc.lat, loc.lon) do
        {:ok, data} -> data
        _ -> socket.assigns.weather
      end

    radar_meta =
      case Radar.get_radar_meta() do
        {:ok, meta} -> meta
        _ -> socket.assigns.radar_meta
      end

    schedule_refresh()

    socket =
      socket
      |> assign(:weather, weather)
      |> assign(:radar_meta, radar_meta)
      |> refresh_frames()

    {:noreply, socket}
  end

  @impl true
  def handle_info(:nowcast_tick, socket) do
    loc = socket.assigns.active_location
    schedule_nowcast_tick()

    socket =
      socket
      |> assign(:buienradar, fetch_buienradar(loc, socket.assigns.buienradar))
      |> pick_nowcast()
      |> start_own_nowcast(loc)

    {:noreply, socket}
  end

  # Result of our own radar nowcast (computed off the LiveView process: it may need to fetch radar tiles).
  @impl true
  def handle_async(:own_nowcast, {:ok, {key, result, gauge}}, socket) do
    loc = socket.assigns.active_location

    if key != {loc.lat, loc.lon} do
      # a result for a location we have already left
      {:noreply, socket}
    else
      own =
        case result do
          {:ok, own} -> own
          {:error, _reason} -> keep_if_recent(socket.assigns.own_nowcast)
        end

      error = with {:error, reason} <- result, do: reason_text(reason)

      {:noreply,
       socket
       |> assign(:own_nowcast, own)
       |> assign(:own_error, if(is_binary(error), do: error))
       |> assign(:gauge, with({:ok, g} <- gauge, do: g, else: (_ -> nil)))
       |> assign(:own_loading, false)
       |> pick_nowcast()
       |> refresh_frames()}
    end
  end

  def handle_async(:own_nowcast, {:exit, _reason}, socket) do
    own = keep_if_recent(socket.assigns.own_nowcast)

    {:noreply,
     socket
     |> assign(:own_nowcast, own)
     |> assign(:own_loading, false)
     |> pick_nowcast()
     |> refresh_frames()}
  end

  # Radar frames plus our forecast frames. The index follows the frame the user is looking at (by time).
  defp refresh_frames(socket) do
    past = socket.assigns.radar_meta.frames || []
    frames = with_forecast(past, socket.assigns.own_nowcast)
    old = Enum.at(socket.assigns.frames, socket.assigns.active_frame_index)

    idx =
      case old &&
             Enum.find_index(
               frames,
               &(&1.time == old.time and &1[:forecast_min] == old[:forecast_min])
             ) do
        i when is_integer(i) -> i
        _ -> min(socket.assigns.active_frame_index, max(length(frames) - 1, 0))
      end

    socket |> assign(:frames, frames) |> assign(:active_frame_index, idx)
  end

  @forecast_steps [10, 20, 30, 40, 50, 60]

  @doc """
  Appends forecast frames (+10 .. +60 min): the newest radar image moved along the estimated drift.
  Only when the drift is known; the shift (km east / north) is applied in the browser.
  """
  def with_forecast(frames, %{motion: %{known: true, speed_km_h: v, toward_deg: toward}})
      when v >= 1.0 do
    case Enum.filter(frames, &(not &1.is_nowcast)) |> List.last() do
      nil ->
        frames

      latest ->
        rad = toward * :math.pi() / 180

        frames ++
          for min <- @forecast_steps do
            km = v * min / 60

            latest
            |> Map.put(:is_nowcast, true)
            |> Map.put(:forecast_min, min)
            |> Map.put(:time, latest.time + min * 60)
            |> Map.put(:shift_km, %{east: km * :math.sin(rad), north: km * :math.cos(rad)})
          end
    end
  end

  def with_forecast(frames, _own), do: frames

  @doc "Payload for the map hook: tile url and the drift shift (km) for forecast frames."
  def frame_event(nil), do: %{tileUrl: nil, shiftEast: 0, shiftNorth: 0}

  def frame_event(frame) do
    shift = Map.get(frame, :shift_km, %{east: 0, north: 0})

    %{
      tileUrl: frame.tile_url_template,
      shiftEast: Float.round(shift.east * 1.0, 2),
      shiftNorth: Float.round(shift.north * 1.0, 2)
    }
  end

  defp reason_text(:radar_stale), do: "the newest radar image is too old"
  defp reason_text(:no_frames), do: "no radar images available"
  defp reason_text(:not_enough_frames), do: "not enough radar images yet"
  defp reason_text({:recently_failed, _}), do: "the radar server did not answer (retrying)"
  defp reason_text(other), do: "radar error: #{inspect(other) |> String.slice(0, 80)}"

  defp load_location(socket, loc) do
    case Weather.get_nowcast(loc.lat, loc.lon) do
      {:ok, weather} ->
        socket =
          socket
          |> assign(:active_location, loc)
          |> assign(:weather, weather)
          |> assign(:buienradar, fetch_buienradar(loc, nil))
          |> assign(:own_nowcast, nil)
          |> assign(:own_loading, true)
          |> assign(:own_error, nil)
          |> pick_nowcast()
          |> start_own_nowcast(loc)
          |> assign(:page_title, "#{loc.name} · Real-time Nowcast")
          |> assign(:error_message, nil)
          |> push_event("pan-location", %{lat: loc.lat, lon: loc.lon, name: loc.name})

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :error_message, "Failed to load weather: #{inspect(reason)}")}
    end
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end

  # Tick just after every full minute so the countdown changes on the minute.
  defp schedule_nowcast_tick do
    Process.send_after(
      self(),
      :nowcast_tick,
      60_000 - rem(System.system_time(:millisecond), 60_000) + 1_500
    )
  end

  # Buienradar's finished point forecast: instant, used as fallback and as a cross-check.
  # Keeps the previous result when the feed is briefly unavailable.
  defp fetch_buienradar(loc, fallback) do
    case Nowcast.get(loc.lat, loc.lon) do
      {:ok, nowcast} -> nowcast
      _ -> fallback
    end
  end

  # Our own radar nowcast is the primary source; Buienradar fills in until it is ready (or if it fails).
  defp pick_nowcast(socket) do
    assign(socket, :radar_nowcast, socket.assigns.own_nowcast || socket.assigns.buienradar)
  end

  defp start_own_nowcast(socket, loc) do
    if connected?(socket) do
      start_async(socket, :own_nowcast, fn ->
        {{loc.lat, loc.lon}, RadarNowcast.get(loc.lat, loc.lon), Gauges.latest(loc.lat, loc.lon)}
      end)
    else
      socket
    end
  end

  # After a failed update keep the last own result for a short while, then fall back to Buienradar.
  defp keep_if_recent(nil), do: nil

  defp keep_if_recent(%{generated_at: generated_at} = own) do
    case DateTime.from_iso8601(generated_at) do
      {:ok, dt, _} -> if DateTime.diff(DateTime.utc_now(), dt) < 180, do: own, else: nil
      _ -> nil
    end
  end

  @doc "True for our own radar-advection nowcast (as opposed to the Buienradar feed)."
  def own?(%{method: "radar-advection"}), do: true
  def own?(_), do: false

  @doc "True when the ground station reports air dry enough that light rain evaporates before it lands."
  def virga_risk?(gauge), do: Gauges.virga_risk?(gauge)

  @doc "One sentence about the estimated drift of the rain."
  def motion_text(%{known: true, speed_km_h: speed, from: from}) when speed >= 1.0,
    do: "Rain is drifting from the #{from} at #{speed} km/h"

  def motion_text(%{known: true}), do: "Rain is almost stationary"

  def motion_text(_),
    do: "Unknown (too little rain nearby to track), so rain is assumed to stay put"

  @doc "One-line version of the countdown for the hero card."
  def radar_hero_text(%{headline: headline, detail: nil}), do: headline
  def radar_hero_text(%{headline: headline, detail: detail}), do: "#{headline} #{detail}"

  @doc "Local (Belgian) clock time of an ISO8601 UTC timestamp."
  def local_clock(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Nowcast.local_time(dt)
      _ -> "--:--"
    end
  end

  @chart %{w: 720, h: 240, left: 44, right: 676, top: 30, bottom: 206}

  @doc """
  Geometry of the rain graph: one bar per minute (expected rain rate, mm/h) and, when the series carries it, a line
  for the calibrated chance of rain (right axis, 0 to 100 %).
  """
  def rain_chart(series) do
    %{left: left, right: right, top: top, bottom: bottom} = @chart
    n = max(length(series), 1)
    width = (right - left) * 1.0
    height = (bottom - top) * 1.0
    step = width / n

    rate = fn p -> Map.get(p, :mean_mm_h) || p.mm_h end
    ymax = series |> Enum.map(rate) |> Enum.max(fn -> 0 end) |> nice_max()
    has_chance = Enum.any?(series, &is_number(Map.get(&1, :chance)))

    bars =
      series
      |> Enum.with_index()
      |> Enum.map(fn {p, i} ->
        r = rate.(p)
        h = min(height, r / ymax * height)

        %{
          x: Float.round(left + i * step, 2),
          y: Float.round(bottom - h, 2),
          w: Float.round(max(step - 0.4, 0.5), 2),
          h: Float.round(h, 2),
          title:
            "#{p.time} · #{r} mm/h" <>
              if(has_chance, do: " · #{Map.get(p, :chance, 0)}% chance", else: "")
        }
      end)

    line =
      if has_chance do
        series
        |> Enum.with_index()
        |> Enum.map_join(" ", fn {p, i} ->
          y = bottom - Map.get(p, :chance, 0) / 100 * height
          "#{Float.round(left + (i + 0.5) * step, 1)},#{Float.round(y, 1)}"
        end)
      end

    %{
      w: @chart.w,
      h: @chart.h,
      left: left,
      right: right,
      top: top,
      bottom: bottom,
      bars: bars,
      line: line,
      has_chance: has_chance,
      guide_y: bottom - height / 2,
      y_ticks: for(f <- [0, 0.5, 1], do: %{y: bottom - f * height, label: format_axis(ymax * f)}),
      chance_ticks:
        for(f <- [0, 0.5, 1], do: %{y: bottom - f * height, label: "#{round(f * 100)}%"}),
      x_ticks:
        for(
          i <- [0, 30, 60, 90, 119],
          p = Enum.at(series, i),
          do: %{x: Float.round(left + (i + 0.5) * step, 1), label: p.time}
        )
    }
  end

  defp nice_max(peak) when peak <= 1.0, do: 1.0
  defp nice_max(peak) when peak <= 2.0, do: 2.0
  defp nice_max(peak) when peak <= 5.0, do: 5.0
  defp nice_max(peak) when peak <= 10.0, do: 10.0
  defp nice_max(peak), do: Float.ceil(peak / 10) * 10

  defp format_axis(v),
    do: v |> Float.round(1) |> then(&if(&1 == trunc(&1), do: trunc(&1), else: &1))

  def current_frame(frames, index) do
    Enum.at(frames, index)
  end

  def format_frame_time(nil), do: "--:--"

  def format_frame_time(%{forecast_min: min} = frame) do
    "#{Nowcast.local_time(DateTime.from_unix!(frame.time))} (Forecast +#{min} min)"
  end

  def format_frame_time(frame) do
    formatted = Nowcast.local_time(DateTime.from_unix!(frame.time))
    if frame.is_nowcast, do: "#{formatted} (Nowcast)", else: "#{formatted} (Radar)"
  end
end
