defmodule ZeroWeatherWeb.WeatherLive do
  use ZeroWeatherWeb, :live_view

  alias ZeroWeather.{Weather, Radar, Locations, Nowcast}

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
      |> assign(:radar_nowcast, fetch_radar_nowcast(default_loc, nil))
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
          |> push_event("change-radar-frame", %{tileUrl: frame && frame.tile_url_template})

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
        |> push_event("change-radar-frame", %{tileUrl: frame && frame.tile_url_template})

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
      |> assign(:frames, radar_meta.frames || [])

    {:noreply, socket}
  end

  @impl true
  def handle_info(:nowcast_tick, socket) do
    loc = socket.assigns.active_location
    schedule_nowcast_tick()

    {:noreply,
     assign(socket, :radar_nowcast, fetch_radar_nowcast(loc, socket.assigns.radar_nowcast))}
  end

  defp load_location(socket, loc) do
    case Weather.get_nowcast(loc.lat, loc.lon) do
      {:ok, weather} ->
        socket =
          socket
          |> assign(:active_location, loc)
          |> assign(:weather, weather)
          |> assign(:radar_nowcast, fetch_radar_nowcast(loc, nil))
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

  # Keeps the previous nowcast when the feed is briefly unavailable.
  defp fetch_radar_nowcast(loc, fallback) do
    case Nowcast.get(loc.lat, loc.lon) do
      {:ok, nowcast} -> nowcast
      _ -> fallback
    end
  end

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

  # Square-root scale so light drizzle is still visible next to a downpour (5 mm/h = full height).
  def strip_height(mm_h) when mm_h < 0.05, do: 3
  def strip_height(mm_h), do: min(100, max(8, round(:math.sqrt(mm_h / 5.0) * 100)))

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

  def format_frame_time(frame) do
    dt = DateTime.from_unix!(frame.time)
    formatted = Calendar.strftime(dt, "%H:%M")
    if frame.is_nowcast, do: "#{formatted} (Nowcast)", else: "#{formatted} (Radar)"
  end
end
