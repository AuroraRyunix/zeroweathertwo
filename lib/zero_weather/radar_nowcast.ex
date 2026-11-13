defmodule ZeroWeather.RadarNowcast do
  @moduledoc """
  Our own rain nowcast, computed from the radar frames themselves.

  1. The newest radar frames (RainViewer, one every 10 minutes) are decoded into a rain-rate grid of about
     0.75 km cells around the point (`ZeroWeather.RadarGrid`).
  2. The rain's **drift** is estimated by finding the shift that best maps the previous frame onto the newest one
     (normalised cross-correlation over the rain cells near the point, with sub-cell refinement; two frame pairs are
     combined when they agree).
  3. The newest frame is **advected** along that drift: the rain that will be over the point `t` minutes from now is the
     rain that is `drift * t` upstream of it now. It is sampled once per minute, over a disk that grows with lead time
     (about 1.3 km at the start, 7 km after 2 hours) so the forecast gets smoother, like the real uncertainty.
  4. The 1-minute series goes through the same countdown summary as the Buienradar feed (`ZeroWeather.Nowcast`).

  Intensity is kept constant (no growth or decay of showers), so skill drops with lead time, mostly after an hour.
  """

  alias ZeroWeather.{Cache, Nowcast, Radar, RadarGrid, RmiRadar}

  # window half size in (0.75 km) cells (~150 km): enough upstream distance for 2 hours at ~65 km/h
  @half 200
  # Motion is tracked on a 2x2-averaged copy of the grids (1.5 km cells); these constants are in those cells
  # cells around the point used to track the motion (~70 km)
  @motion_half 45
  # largest shift searched per frame step, in cells (~18 km per 10 min = 108 km/h)
  @max_shift 12
  @frame_seconds 600
  @min_rain_cells 40
  @min_quality 0.45
  @rain_threshold 0.1
  @horizon_min 120
  # smoothing disk radius in km = base + lead_minutes * growth (the forecast gets less certain with lead time);
  # kept in km so the calibration below holds whatever the cell size
  @smooth_base_km 1.2
  @smooth_per_min_km 0.05

  # The share of the smoothing disk that is raining is only a rough probability. Checked against 3,500 forecast/outcome
  # pairs from a replay of real radar, it is well calibrated up to ~20 minutes ahead and increasingly overconfident
  # after that (a raw 85-100% rained only ~55% of the time at +50..+60 min). These tables map the raw share (%) to the
  # observed frequency (%) at three lead times; they are blended linearly in between.
  @calibration [
    {15, [{0, 1}, {10, 9}, {25, 22}, {42, 30}, {57, 60}, {75, 78}, {100, 98}]},
    {35, [{0, 2}, {8, 10}, {25, 24}, {42, 38}, {57, 50}, {75, 64}, {100, 86}]},
    {55, [{0, 4}, {8, 9}, {25, 15}, {42, 22}, {57, 33}, {75, 36}, {100, 55}]}
  ]
  # No data beyond an hour: assume confidence keeps shrinking, to 80% of the +55 min table at +120 min.
  @late_shrink 0.2
  # A minute counts as rain when it is at least this likely (percent); "possible" below that
  @likely 50
  @possible 25
  @model_ttl 900
  # RMI composite: window half size in 1 km cells (~150 km), and how far from the raster edge a point must be
  @rmi_half 150
  @rmi_cell_km 1.0
  @rmi_margin_deg 1.5
  # RainViewer must be this many seconds newer before it is preferred over the (more accurate) RMI float data
  @prefer_rmi_margin 300
  @max_frame_age 45 * 60

  @doc """
  Builds the forecast for a point. Returns `{:ok, map}` (same shape as `ZeroWeather.Nowcast.get/3`, plus
  `motion`, `frame_time` and `method`) or `{:error, reason}`.
  """
  def get(lat, lon, now \\ DateTime.utc_now()) when is_number(lat) and is_number(lon) do
    lat = Float.round(lat * 1.0, 2)
    lon = Float.round(lon * 1.0, 2)

    case rmi_model(lat, lon, now) do
      {:ok, model} ->
        {:ok, forecast(model, now)}

      {:error, _rmi_reason} ->
        # RMI unreachable, outside its composite or behind RainViewer: use the RainViewer tiles instead
        with {:ok, meta} <- Radar.get_radar_meta(),
             {:ok, frames} <- pick_frames(meta, now),
             {:ok, model} <- model(meta.host, frames, lat, lon) do
          {:ok, forecast(model, now)}
        end
    end
  end

  # -- primary source: RMI's float rain-rate composite (5-minute steps) ---------------------------

  defp rmi_model(lat, lon, now) do
    with true <- Application.get_env(:zero_weather, :rmi_radar, true) || {:error, :rmi_disabled},
         {:ok, newest} <- RmiRadar.latest_time(),
         :ok <- check_fresh(newest, now),
         :ok <- not_behind_rainviewer(newest) do
      Cache.fetch({:radar_nowcast_model, :rmi, lat, lon, newest}, @model_ttl, fn ->
        build_rmi_model(newest, lat, lon)
      end)
    end
  end

  # RMI publishes in bursts (the newest frame was up to 30 minutes old in a measurement): when RainViewer has a frame
  # that is clearly newer, the staler float data would forecast the past, so use RainViewer then.
  defp not_behind_rainviewer(rmi_newest) do
    with {:ok, meta} <- Radar.get_radar_meta(),
         [_ | _] = past <- Enum.reject(meta.frames, & &1.is_nowcast),
         rv_newest = past |> Enum.map(& &1.time) |> Enum.max(),
         true <- rv_newest > rmi_newest + @prefer_rmi_margin do
      {:error, :rainviewer_is_fresher}
    else
      _ -> :ok
    end
  end

  defp check_fresh(newest, now),
    do: if(DateTime.to_unix(now) - newest > @max_frame_age, do: {:error, :radar_stale}, else: :ok)

  defp build_rmi_model(newest, lat, lon) do
    # newest frame plus the ones 10 and 20 minutes earlier (the motion code works on 10-minute pairs)
    times = [newest, newest - @frame_seconds, newest - 2 * @frame_seconds]

    frames = Enum.map(times, &RmiRadar.frame/1)

    case Enum.find(frames, &match?({:error, _}, &1)) do
      {:error, reason} ->
        {:error, reason}

      nil ->
        [{:ok, newest_frame} | _] = frames

        if RmiRadar.covers?(newest_frame, lat, lon, @rmi_margin_deg) do
          grids =
            for {:ok, f} <- frames, do: RmiRadar.window(f, lat, lon, @rmi_half, @rmi_cell_km)

          {:ok,
           %{
             grid: hd(grids),
             frame_time: newest,
             motion:
               grids |> Enum.map(&RadarGrid.coarsen/1) |> estimate_motion_chain() |> fine_motion(),
             lat: lat,
             lon: lon,
             radar_source: :rmi,
             source: "RMI radar composite (5-minute float rain rate), own advection nowcast"
           }}
        else
          {:error, :outside_rmi_coverage}
        end
    end
  end

  # -- frames ----------------------------------------------------------------------------------

  defp pick_frames(meta, now) do
    past = meta.frames |> Enum.reject(& &1.is_nowcast) |> Enum.sort_by(& &1.time, :desc)

    case past do
      [newest | _] = all ->
        if DateTime.to_unix(now) - newest.time > @max_frame_age do
          {:error, :radar_stale}
        else
          # newest frame plus up to two earlier ones at (roughly) 10 and 20 minutes before it
          frames =
            [0, 1, 2]
            |> Enum.map(fn k ->
              Enum.find(all, &(abs(&1.time - (newest.time - k * @frame_seconds)) < 150))
            end)
            |> Enum.reject(&is_nil/1)

          if length(frames) >= 2, do: {:ok, frames}, else: {:error, :not_enough_frames}
        end

      [] ->
        {:error, :no_frames}
    end
  end

  # -- model: grid + motion, cached per location and newest frame -----------------------------

  defp model(host, [newest | _] = frames, lat, lon) do
    Cache.fetch({:radar_nowcast_model, lat, lon, newest.time}, @model_ttl, fn ->
      build_model(host, frames, lat, lon)
    end)
  end

  defp build_model(host, [newest | _] = frames, lat, lon) do
    grids =
      frames
      |> Task.async_stream(fn f -> {f.time, RadarGrid.window(host, f.path, lat, lon, @half)} end,
        max_concurrency: 1,
        timeout: 60_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, {time, {:ok, grid}}} -> {time, grid}
        {:ok, {_time, {:error, reason}}} -> {:error, reason}
        {:exit, reason} -> {:error, {:radar_task, reason}}
      end)

    case Enum.find(grids, &match?({:error, _}, &1)) do
      {:error, reason} ->
        {:error, reason}

      nil ->
        [{_, g0} | _older] = grids

        {:ok,
         %{
           grid: g0,
           frame_time: newest.time,
           motion:
             fine_motion(estimate_motion_chain(Enum.map(grids, &RadarGrid.coarsen(elem(&1, 1))))),
           lat: lat,
           lon: lon
         }}
    end
  end

  # motion was found in coarse (2x2) cells: express the shift in the full-resolution cells of the model grid
  defp fine_motion(%{dx: dx, dy: dy} = motion), do: %{motion | dx: dx * 2, dy: dy * 2}

  # -- motion estimation -------------------------------------------------------------------------

  @doc """
  Drift in cells per frame step, from a list of grids ordered newest first. Pairs that agree are averaged.
  Returns `%{dx:, dy:, quality:}` (dx to the east, dy to the south) or `%{dx: 0.0, dy: 0.0, quality: 0.0, reason: ...}`
  when there is not enough rain to track.
  """
  def estimate_motion_chain([newest, older | rest]) do
    first = estimate_motion(newest, older)

    second =
      case rest do
        [oldest | _] -> estimate_motion(older, oldest)
        [] -> {:error, :no_pair}
      end

    case {first, second} do
      {{:ok, a}, {:ok, b}} ->
        if :math.sqrt(:math.pow(a.dx - b.dx, 2) + :math.pow(a.dy - b.dy, 2)) <= 2.5 do
          w = a.quality + b.quality

          %{
            dx: (a.dx * a.quality + b.dx * b.quality) / w,
            dy: (a.dy * a.quality + b.dy * b.quality) / w,
            quality: min(a.quality, b.quality)
          }
        else
          a
        end

      {{:ok, a}, _} ->
        a

      {{:error, reason}, {:ok, b}} when reason in [:not_enough_rain, :low_correlation] ->
        Map.put(b, :reason, :older_pair_only)

      {{:error, reason}, _} ->
        %{dx: 0.0, dy: 0.0, quality: 0.0, reason: reason}
    end
  end

  @doc "Drift between two grids (`newer` and `older`, one frame apart) by normalised cross-correlation."
  def estimate_motion(newer, older) do
    nz = rain_cells(newer, @motion_half)
    nz = if length(nz) < @min_rain_cells, do: rain_cells(newer, @half), else: nz

    if length(nz) < @min_rain_cells do
      {:error, :not_enough_rain}
    else
      old = compress(older)
      norm0 = nz |> Enum.map(fn {_, _, f} -> f * f end) |> Enum.sum()

      scores =
        for dy <- -@max_shift..@max_shift, dx <- -@max_shift..@max_shift, into: %{} do
          {dot, norm1} =
            Enum.reduce(nz, {0.0, 0.0}, fn {x, y, f0}, {d, n1} ->
              f1 = value(old, x - dx, y - dy)
              {d + f0 * f1, n1 + f1 * f1}
            end)

          {{dx, dy}, if(norm1 > 0.0, do: dot / :math.sqrt(norm0 * norm1), else: 0.0)}
        end

      {{bx, by}, best} = Enum.max_by(scores, fn {_, s} -> s end)

      if best < @min_quality do
        {:error, :low_correlation}
      else
        {:ok,
         %{
           dx: bx + refine(scores, bx, by, :x),
           dy: by + refine(scores, bx, by, :y),
           quality: best
         }}
      end
    end
  end

  # parabolic sub-cell refinement along one axis; 0.0 on the edge of the search range
  defp refine(scores, bx, by, axis) do
    {lo, hi} =
      case axis do
        :x -> {Map.get(scores, {bx - 1, by}), Map.get(scores, {bx + 1, by})}
        :y -> {Map.get(scores, {bx, by - 1}), Map.get(scores, {bx, by + 1})}
      end

    mid = Map.fetch!(scores, {bx, by})

    if is_nil(lo) or is_nil(hi) do
      0.0
    else
      denom = lo - 2 * mid + hi
      if denom >= -1.0e-9, do: 0.0, else: max(-0.5, min(0.5, 0.5 * (lo - hi) / denom))
    end
  end

  # cells with rain around the grid centre as {x, y, compressed intensity}
  defp rain_cells(grid, radius) do
    cx = round(grid.cx)
    cy = round(grid.cy)

    for y <- max(cy - radius, 0)..min(cy + radius, grid.n - 1),
        x <- max(cx - radius, 0)..min(cx + radius, grid.n - 1),
        v = RadarGrid.cell(grid, x, y),
        v >= @rain_threshold,
        do: {x, y, :math.log(1 + v)}
  end

  # grid of compressed intensities (log keeps the heavy cores from dominating the match)
  defp compress(%{rows: rows} = grid) do
    compressed =
      rows
      |> Tuple.to_list()
      |> Enum.map(fn row ->
        row |> Tuple.to_list() |> Enum.map(&:math.log(1 + &1)) |> List.to_tuple()
      end)
      |> List.to_tuple()

    %{grid | rows: compressed}
  end

  defp value(grid, x, y), do: RadarGrid.cell(grid, x, y)

  # -- advection forecast ------------------------------------------------------------------------------

  @doc """
  Builds the 1-minute series and summary for `now` from a model (`grid`, `frame_time`, `motion`).

  Options (used to tune the forecast against hindcasts): `:smooth_base` and `:smooth_per_min` (radius of the
  smoothing disk in cells = base + lead * per_min) and `:decay_min` (rain rate decays by `exp(-lead / decay_min)`).
  """
  def forecast(model, now, opts \\ [])

  def forecast(
        %{grid: grid, frame_time: frame_time, motion: motion, lat: lat, lon: lon} = model,
        %DateTime{} = now,
        opts
      ) do
    cell_km = grid.cell_km

    # options are in cells of a 1.5 km grid (as in the hindcast scripts); the disk is defined in km
    smooth_base = Keyword.get(opts, :smooth_base, @smooth_base_km / 1.5) * 1.5 / cell_km
    smooth_rate = Keyword.get(opts, :smooth_per_min, @smooth_per_min_km / 1.5) * 1.5 / cell_km
    decay_min = Keyword.get(opts, :decay_min)

    # drift in cells per minute
    vx = motion.dx / (@frame_seconds / 60)
    vy = motion.dy / (@frame_seconds / 60)

    speed_km_h =
      :math.sqrt(motion.dx * motion.dx + motion.dy * motion.dy) * cell_km * 3600 / @frame_seconds

    # do not look further upstream than the window allows (leave a 10% margin)
    max_lead =
      if speed_km_h < 1.0,
        do: @horizon_min,
        else: min(@horizon_min, trunc(div(grid.n, 2) * cell_km * 0.9 / (speed_km_h / 60)))

    start = div(DateTime.to_unix(now), 60) * 60

    series =
      for i <- 0..(max(max_lead, 1) - 1) do
        t = start + i * 60
        tau = (t - frame_time) / 60

        {mean, raw_chance, rate_if_rain} =
          sample_disk(
            grid,
            grid.cx - vx * tau,
            grid.cy - vy * tau,
            smooth_base + tau * smooth_rate
          )

        decay = if decay_min, do: :math.exp(-tau / decay_min), else: 1.0
        at = DateTime.from_unix!(t)

        %{
          at: DateTime.to_iso8601(at),
          time: Nowcast.local_time(at),
          # typical rate where it rains; the bar chart shows it with the chance as opacity
          mm_h: Float.round(rate_if_rain * decay, 3),
          mean_mm_h: Float.round(mean * decay, 3),
          chance: round(calibrate(raw_chance * 100, tau)),
          chance_raw: round(raw_chance * 100)
        }
      end

    %{
      source: Map.get(model, :source, "RainViewer radar, own advection nowcast"),
      radar_source: Map.get(model, :radar_source, :rainviewer),
      method: "radar-advection",
      frame_time: DateTime.from_unix!(frame_time) |> DateTime.to_iso8601(),
      frame_age_min: Float.round((DateTime.to_unix(now) - frame_time) / 60, 1),
      generated_at: DateTime.to_iso8601(now),
      location: %{lat: lat, lon: lon},
      motion: describe_motion(motion, speed_km_h),
      series: series,
      summary:
        Nowcast.summarize(series,
          rain?: &(&1.chance >= @likely),
          possible?: &(&1.chance >= @possible)
        )
    }
  end

  @doc """
  Calibrated probability of rain (percent) from the raw share of the smoothing disk that is raining (percent),
  for a lead time in minutes since the radar frame. See the notes on `@calibration`.
  """
  def calibrate(raw_pct, tau_min) when is_number(raw_pct) and is_number(tau_min) do
    raw = raw_pct |> max(0) |> min(100)
    [{t0, tab0}, {t1, tab1}, {t2, tab2}] = @calibration

    base =
      cond do
        tau_min <= t0 ->
          interpolate_table(tab0, raw)

        tau_min >= t2 ->
          interpolate_table(tab2, raw)

        tau_min <= t1 ->
          blend(
            interpolate_table(tab0, raw),
            interpolate_table(tab1, raw),
            (tau_min - t0) / (t1 - t0)
          )

        true ->
          blend(
            interpolate_table(tab1, raw),
            interpolate_table(tab2, raw),
            (tau_min - t1) / (t2 - t1)
          )
      end

    late = if tau_min > t2, do: min(tau_min - t2, 65) / 65 * @late_shrink, else: 0.0
    base * (1 - late)
  end

  defp blend(a, b, w), do: a + (b - a) * w

  defp interpolate_table(table, x) do
    [{x0, y0}, {x1, y1}] =
      table
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.find(fn [{a, _}, {b, _}] -> x >= a and x <= b end)

    y0 + (y1 - y0) * (x - x0) / (x1 - x0)
  end

  # mean rain rate, share of the disk that is raining, and the mean rate over the raining samples only
  defp sample_disk(grid, x, y, radius) do
    r = ceil(radius)

    samples =
      for ox <- -r..r,
          oy <- -r..r,
          ox * ox + oy * oy <= radius * radius,
          do: RadarGrid.sample(grid, x + ox, y + oy)

    n = length(samples)
    wet = Enum.filter(samples, &(&1 >= @rain_threshold))
    rate_if_rain = if wet == [], do: 0.0, else: Enum.sum(wet) / length(wet)
    {Enum.sum(samples) / n, length(wet) / n, rate_if_rain}
  end

  defp describe_motion(%{quality: quality} = motion, speed_km_h) do
    if quality < @min_quality or speed_km_h < 1.0 do
      %{
        known: quality >= @min_quality,
        speed_km_h: Float.round(speed_km_h, 1),
        quality: Float.round(quality * 1.0, 2),
        reason: Map.get(motion, :reason)
      }
    else
      # compass bearing the rain moves TOWARD (x east, y south in grid coordinates)
      toward = :math.atan2(motion.dx, -motion.dy) * 180 / :math.pi()
      toward = if toward < 0, do: toward + 360, else: toward

      %{
        known: true,
        speed_km_h: Float.round(speed_km_h, 1),
        toward_deg: round(toward),
        from: compass(rem(round(toward) + 180, 360)),
        quality: Float.round(quality, 2)
      }
    end
  end

  defp compass(deg) do
    Enum.at(~w(N NE E SE S SW W NW), rem(round(deg / 45), 8))
  end
end
