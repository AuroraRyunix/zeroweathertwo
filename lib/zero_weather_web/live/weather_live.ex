defmodule ZeroWeatherWeb.WeatherLive do
  use ZeroWeatherWeb, :live_view

  alias ZeroWeather.{Weather, Radar, Locations, Nowcast, RadarNowcast}

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
  def handle_async(:own_nowcast, {:ok, {key, result}}, socket) do
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

      {:noreply,
       socket
       |> assign(:own_nowcast, own)
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
        {{loc.lat, loc.lon}, RadarNowcast.get(loc.lat, loc.lon)}
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

  @doc "Tooltip text of one minute of the strip."
  def nowcast_tooltip(point) do
    base = "#{point.time} · #{point.mm_h} mm/h"

    case Map.get(point, :chance) do
      nil -> base
      chance -> "#{base} · #{chance}% chance of rain nearby"
    end
  end

  @doc "One sentence about the estimated drift of the rain."
  def motion_text(%{known: true, speed_km_h: speed, from: from}) when speed >= 1.0,
    do: "🧭 Rain is drifting from the #{from} at #{speed} km/h"

  def motion_text(%{known: true}), do: "🧭 Rain is almost stationary"

  def motion_text(_),
    do: "🧭 Drift unknown (too little rain nearby to track), so rain is assumed to stay put"

  @doc "One-line version of the countdown for the hero card."
  def radar_hero_text(%{headline: headline, detail: nil}), do: headline
  def radar_hero_text(%{headline: headline, detail: detail}), do: "#{headline} #{detail}"

  @doc """
  Bars of the precipitation chart: the 1-minute steps of our radar nowcast (expected rate and chance), or the
  Open-Meteo 15-minute timeline when no radar nowcast is available. Returns `{source, steps}`.
  """
  def chart_steps(%{series: [_ | _] = series}, _timeline) do
    steps =
      series
      |> Enum.with_index()
      |> Enum.map(fn {point, i} ->
        %{
          time: point.time,
          label: if(rem(i, 15) == 0, do: point.time, else: ""),
          show_prob: rem(i, 10) == 0,
          precip_mm: Float.round((Map.get(point, :mean_mm_h) || point.mm_h) * 1.0, 2),
          probability: Map.get(point, :chance, 0)
        }
      end)

    {:one_minute, steps}
  end

  def chart_steps(_nowcast, timeline) do
    {:fifteen_minute, Enum.map(timeline || [], &Map.put(&1, :label, &1.time))}
  end

  @doc "Local (Belgian) clock time of an ISO8601 UTC timestamp."
  def local_clock(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Nowcast.local_time(dt)
      _ -> "--:--"
    end
  end

  # Square-root scale so light drizzle is still visible next to a downpour (5 mm/h = full height).
  def strip_height(mm_h) when mm_h < 0.05, do: 3
  def strip_height(mm_h), do: min(100, max(8, round(:math.sqrt(mm_h / 5.0) * 100)))

  @doc "Bars fade with the chance of rain (own nowcast); Buienradar points carry no chance and stay solid."
  def strip_opacity(%{chance: chance}) when is_number(chance),
    do: Float.round(0.25 + 0.75 * min(max(chance, 0), 100) / 100, 2)

  def strip_opacity(_point), do: 1.0

  def strip_color(mm_h) when mm_h < 0.05, do: "bg-slate-800/60"
  def strip_color(mm_h) when mm_h <= 1.0, do: "bg-sky-400"
  def strip_color(mm_h) when mm_h <= 4.0, do: "bg-blue-500"
  def strip_color(_mm_h), do: "bg-purple-600"

  @doc "A handful of evenly spaced points of the series to label the time axis."
  def strip_labels([]), do: []

  def strip_labels(series) do
    last = length(series) - 1

    [0, 30, 60, 90, last]
    |> Enum.filter(&(&1 <= last))
    |> Enum.uniq()
    |> Enum.map(&Enum.at(series, &1))
  end

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
