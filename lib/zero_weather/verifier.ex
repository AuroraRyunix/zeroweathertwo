defmodule ZeroWeather.Verifier do
  @moduledoc """
  Live verification of our own forecast against what the radar then shows.

  Every time RMI publishes a new composite (checked every minute, one origin per 10 minutes) the model forecasts, for
  a handful of Belgian points, the chance of rain 10, 15, ..., 120 minutes ahead. When the frame for such a target
  time arrives, the outcome (radar rate at the point of 0.1 mm/h or more) is scored. This builds, while the server
  runs, the same Brier scores and reliability table as the hindcast, on fresh data, and it is shown in the UI.

  Scores kept per lead band: the Brier score of the calibrated chance, of the raw share of the disk, of "it keeps
  doing what it does now" (persistence) and of always predicting the observed average rain frequency (climatology).
  Lower is better; a forecast with skill beats climatology and persistence.

  State lives in memory only (it restarts with the server) and is reported with the time it started.
  The target is the radar itself, not a rain gauge: this scores the extrapolation, not the radar's accuracy.
  """
  use GenServer

  alias ZeroWeather.{RadarNowcast, RmiRadar}

  @tick 60_000
  @origin_step 600
  @leads Enum.to_list(10..120//5)
  @bands [{10, 20}, {25, 40}, {45, 60}, {65, 90}, {95, 125}]
  @bins [{0, 4}, {5, 14}, {15, 29}, {30, 49}, {50, 69}, {70, 89}, {90, 100}]
  @max_catch_up 6
  @inca_step 1800

  @points [
    {"Ghent", 51.0543, 3.7174},
    {"Bruges", 51.2093, 3.2247},
    {"Antwerp", 51.2194, 4.4025},
    {"Brussels", 50.8503, 4.3517},
    {"Kortrijk", 50.828, 3.265},
    {"Leuven", 50.8798, 4.7005}
  ]

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Scores so far, or nil when the verifier is not running."
  def snapshot do
    GenServer.call(__MODULE__, :snapshot, 2_000)
  catch
    :exit, _ -> nil
  end

  @doc false
  def bands, do: @bands
  @doc false
  def bins, do: @bins

  @impl true
  def init(_) do
    Process.send_after(self(), :tick, 20_000)

    {:ok,
     %{
       started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
       last_seen: nil,
       origins: 0,
       pending: %{},
       stats: %{},
       last_error: nil,
       points: Enum.map(@points, &elem(&1, 0))
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, report(state), state}

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick)

    state =
      try do
        step(state)
      rescue
        e -> %{state | last_error: Exception.message(e)}
      end

    {:noreply, state}
  end

  defp step(state) do
    with {:ok, newest} <- RmiRadar.latest_time() do
      times = new_times(state.last_seen, newest)

      Enum.reduce(times, state, fn t, st ->
        case RmiRadar.frame(t) do
          {:ok, frame} ->
            st |> score(t, frame) |> maybe_forecast(t, frame) |> Map.put(:last_seen, t)

          {:error, reason} ->
            %{st | last_error: inspect(reason)}
        end
      end)
    else
      {:error, reason} -> %{state | last_error: inspect(reason)}
    end
  end

  # every 5-minute frame since the last one we saw (at most a few: the feed arrives in bursts)
  defp new_times(nil, newest), do: [newest]

  defp new_times(last, newest) when newest > last do
    (last + 300)..newest//300 |> Enum.take(-@max_catch_up)
  end

  defp new_times(_, _), do: []

  defp score(state, t, frame) do
    {due, rest} = Map.pop(state.pending, t, [])

    stats =
      Enum.reduce(due, state.stats, fn e, acc ->
        obs = RmiRadar.rate_at(frame, e.lat, e.lon) >= 0.1
        add(acc, band_of(e.lead), e, obs)
      end)

    %{state | pending: rest, stats: stats}
  end

  defp maybe_forecast(state, t, frame) do
    if rem(t, @origin_step) != 0 do
      state
    else
      older = for k <- [1, 2], {:ok, f} <- [RmiRadar.frame(t - k * @origin_step)], do: f

      if length(older) < 2 do
        state
      else
        inca_frames = inca_frames(t)

        entries =
          for {name, lat, lon} <- @points,
              {:ok, model} <- [RadarNowcast.model_from_rasters([frame | older], lat, lon)],
              fc = RadarNowcast.forecast(model, DateTime.from_unix!(t + 300)),
              {p, i} <- Enum.with_index(fc.series),
              rem(i, 5) == 0 and (5 + i) in @leads,
              do:
                {t + (5 + i) * 60,
                 %{
                   point: name,
                   lat: lat,
                   lon: lon,
                   lead: 5 + i,
                   chance: p.chance,
                   raw: p.chance_raw,
                   persist: RmiRadar.rate_at(frame, lat, lon) >= 0.1,
                   inca: inca_at(inca_frames, t + (5 + i) * 60, lat, lon)
                 }}

        pending =
          Enum.reduce(entries, state.pending, fn {tt, e}, acc ->
            Map.update(acc, tt, [e], &[e | &1])
          end)

        %{state | pending: pending, origins: state.origins + 1}
      end
    end
  end

  # INCA's forecast for the valid times of this origin's leads, only every 30 minutes (one small request per lead) and
  # only for times still in the future, because for earlier ones it shows its analysis, not a forecast
  defp inca_frames(t) do
    if rem(t, @inca_step) == 0 do
      now = System.os_time(:second)

      for lead <- 20..120//10,
          valid = t + lead * 60,
          valid > now,
          {:ok, f} <- [ZeroWeather.Inca.frame(valid)],
          into: %{} do
        {valid, f}
      end
    else
      %{}
    end
  end

  defp inca_at(frames, valid, lat, lon) do
    case Map.get(frames, valid) do
      nil -> nil
      raster -> ZeroWeather.Inca.at(raster, lat, lon)
    end
  end

  @doc false
  def band_of(lead), do: Enum.find(@bands, fn {lo, hi} -> lead >= lo and lead <= hi end)

  @doc false
  def add(stats, nil, _e, _obs), do: stats

  def add(stats, band, e, obs) do
    y = if obs, do: 1.0, else: 0.0
    pc = e.chance / 100
    pr = e.raw / 100
    pp = if e.persist, do: 1.0, else: 0.0
    bin = Enum.find_index(@bins, fn {lo, hi} -> e.chance >= lo and e.chance <= hi end)
    stats = add_inca(stats, band, e, y)

    Map.update(
      stats,
      band,
      new_band(bin, e, y, pc, pr, pp),
      fn s ->
        %{
          s
          | n: s.n + 1,
            wet: s.wet + y,
            bs_cal: s.bs_cal + (pc - y) ** 2,
            bs_raw: s.bs_raw + (pr - y) ** 2,
            bs_persist: s.bs_persist + (pp - y) ** 2,
            bins:
              Map.update(s.bins, bin, {1, y, e.chance}, fn {n, w, c} ->
                {n + 1, w + y, c + e.chance}
              end)
        }
      end
    )
  end

  # INCA rows: its 3x3 share and its point value as forecasts, with our own chance on the very same rows
  defp add_inca(stats, band, %{inca: %{share: share, point: point}} = e, y) do
    inc = fn m ->
      %{
        m
        | n: m.n + 1,
          bs_share: m.bs_share + (share - y) ** 2,
          bs_point: m.bs_point + (if(point >= 0.1, do: 1.0, else: 0.0) - y) ** 2,
          bs_ours: m.bs_ours + (e.chance / 100 - y) ** 2,
          wet: m.wet + y
      }
    end

    Map.update(
      stats,
      {:inca, band},
      inc.(%{n: 0, wet: 0.0, bs_share: 0.0, bs_point: 0.0, bs_ours: 0.0}),
      inc
    )
  end

  defp add_inca(stats, _band, _e, _y), do: stats

  defp new_band(bin, e, y, pc, pr, pp) do
    %{
      n: 1,
      wet: y,
      bs_cal: (pc - y) ** 2,
      bs_raw: (pr - y) ** 2,
      bs_persist: (pp - y) ** 2,
      bins: %{bin => {1, y, e.chance}}
    }
  end

  defp inca_report(nil), do: nil

  defp inca_report(m) do
    %{
      n: m.n,
      wet: trunc(m.wet),
      brier_inca_share: Float.round(m.bs_share / m.n, 4),
      brier_inca_point: Float.round(m.bs_point / m.n, 4),
      brier_ours_same_rows: Float.round(m.bs_ours / m.n, 4)
    }
  end

  @doc false
  def report(state) do
    bands =
      for {lo, hi} = b <- @bands do
        s = Map.get(state.stats, b)
        inca = Map.get(state.stats, {:inca, b})

        if s do
          base = s.wet / s.n

          %{
            lead: "#{lo}-#{hi}",
            n: s.n,
            wet_pct: Float.round(base * 100, 1),
            brier_calibrated: Float.round(s.bs_cal / s.n, 4),
            brier_raw: Float.round(s.bs_raw / s.n, 4),
            brier_persistence: Float.round(s.bs_persist / s.n, 4),
            brier_climatology: Float.round(base * (1 - base), 4),
            inca: inca_report(inca),
            reliability:
              for {{blo, bhi}, i} <- Enum.with_index(@bins),
                  {n, w, c} <- [Map.get(s.bins, i, {0, 0.0, 0})] do
                %{
                  bin: "#{blo}-#{bhi}",
                  n: n,
                  mean_forecast: if(n > 0, do: Float.round(c / n, 1)),
                  observed_pct: if(n > 0, do: Float.round(w / n * 100, 1))
                }
              end
          }
        else
          %{lead: "#{lo}-#{hi}", n: 0}
        end
      end

    %{
      started_at: state.started_at,
      origins: state.origins,
      points: state.points,
      scored: bands |> Enum.map(& &1.n) |> Enum.sum(),
      pending: state.pending |> Map.values() |> Enum.map(&length/1) |> Enum.sum(),
      last_frame: state.last_seen,
      last_error: state.last_error,
      bands: bands
    }
  end
end
