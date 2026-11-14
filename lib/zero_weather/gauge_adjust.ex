defmodule ZeroWeather.GaugeAdjust do
  @moduledoc """
  Checks the radar against the nearest rain gauge and, when there is enough rain to compare, scales the forecast's
  rain *rates* (not the chance of rain) by the ratio of what the gauge caught to what the radar estimated.

  The comparison uses the radar frames already in the cache (no extra downloads): for every 10-minute gauge record
  that has at least one cached frame inside its interval, the radar estimate is that frame's rate at the gauge times
  the interval length. Only the records of the last 30 minutes are used.

  The factor is damped on purpose, because one gauge sits some kilometres from the point and light showers are
  patchy: `factor = 1 + w * (ratio - 1)` with `ratio = (gauge + 0.1) / (radar + 0.1)` clamped to 0.5..2, and
  `w = min(1, max(gauge, radar) / 3 mm)`. With less than 0.5 mm in the window nothing is adjusted. On the one
  day of RMI data checked (about 1.5 mm in total over eight hours) the radar and the gauge agreed to within 7%, so
  the correction is expected to matter only in real rain.

  The dew-point test (`ZeroWeather.Gauges.virga_risk?/1`) is reported next to it as context.
  """

  alias ZeroWeather.{Cache, RmiRadar}

  @window_min 30
  @min_mm 0.5
  @full_weight_mm 3.0
  @clamp {0.5, 2.0}
  @light_mm_h 0.5
  @virga_fade_min 60
  @virga_start 0.5

  @doc false
  def virga_factor(lead_min) when is_number(lead_min),
    do:
      @virga_start + (1 - @virga_start) * min(max(lead_min, 0), @virga_fade_min) / @virga_fade_min

  @doc "Applies the gauge comparison to a nowcast result. Passes errors and missing gauges through untouched."
  def apply({:ok, nowcast}, {:ok, gauge}) do
    {:ok, adjust(nowcast, gauge)}
  rescue
    _ -> {:ok, nowcast}
  end

  def apply(result, _gauge), do: result

  @doc false
  def adjust(%{radar_source: :rmi, series: series} = nowcast, gauge) do
    info = compare(gauge)
    factor = info.factor

    series =
      if factor == 1.0,
        do: series,
        else:
          Enum.map(series, fn p ->
            Map.merge(p, %{
              mm_h: Float.round(p.mm_h * factor, 3),
              mean_mm_h: Float.round(p.mean_mm_h * factor, 3)
            })
          end)

    nowcast
    |> Map.put(:series, series)
    |> put_in([:diagnostics, :gauge], info)
  end

  def adjust(nowcast, gauge) do
    info = %{
      station: gauge.station,
      compared: false,
      factor: 1.0,
      note: "the radar source is not RMI's, so there is no gauge comparison",
      min_mm: @min_mm,
      full_weight_mm: @full_weight_mm,
      virga_risk: false,
      stations: [],
      window_min: @window_min,
      paired: 0,
      gauge_mm: 0.0,
      radar_mm: 0.0
    }

    put_in(nowcast, [:diagnostics, :gauge], info)
  end

  @doc "Comparison of the recent records of the close gauges with the cached radar frames at each station."
  def compare(%{records: _} = gauge) do
    stations = Map.get(gauge, :stations) || [gauge]
    newest = stations |> Enum.map(&(&1.records |> hd() |> Map.fetch!(:unix))) |> Enum.max()
    cutoff = newest - @window_min * 60

    per_station =
      for st <- stations do
        rows =
          for r <- st.records, r.unix > cutoff, r.mm != nil do
            rates =
              for t <- (r.unix - 300)..r.unix//300,
                  {:ok, frame} <- [Cache.get({:rmi_frame, t})],
                  do: RmiRadar.rate_at(frame, st.station_lat, st.station_lon)

            radar_mm = if rates == [], do: nil, else: Enum.sum(rates) / length(rates) / 6

            %{
              time: r.time,
              gauge_mm: r.mm,
              radar_mm: radar_mm && Float.round(radar_mm, 3),
              frames: length(rates)
            }
          end

        paired = Enum.filter(rows, & &1.radar_mm)

        %{
          station: st.station,
          distance_km: Map.get(st, :distance_km),
          intervals: rows,
          paired: length(paired),
          gauge_mm:
            paired |> Enum.map(& &1.gauge_mm) |> Enum.sum() |> Kernel.*(1.0) |> Float.round(2),
          radar_mm:
            paired |> Enum.map(& &1.radar_mm) |> Enum.sum() |> Kernel.*(1.0) |> Float.round(2)
        }
      end

    paired = per_station |> Enum.map(& &1.paired) |> Enum.sum()
    gauge_mm = per_station |> Enum.map(& &1.gauge_mm) |> Enum.sum()
    radar_mm = per_station |> Enum.map(& &1.radar_mm) |> Enum.sum()

    base = %{
      station: gauge.station,
      stations: per_station,
      window_min: @window_min,
      intervals: hd(per_station).intervals,
      paired: paired,
      gauge_mm: Float.round(gauge_mm * 1.0, 2),
      radar_mm: Float.round(radar_mm * 1.0, 2),
      min_mm: @min_mm,
      full_weight_mm: @full_weight_mm,
      virga_risk: ZeroWeather.Gauges.virga_risk?(gauge),
      virga_light_mm_h: @light_mm_h,
      virga_start: @virga_start,
      virga_fade_min: @virga_fade_min
    }

    cond do
      paired < 2 ->
        Map.merge(base, %{
          compared: false,
          factor: 1.0,
          note: "too few cached radar frames to compare with the gauges"
        })

      max(gauge_mm, radar_mm) < @min_mm ->
        Map.merge(base, %{
          compared: true,
          applied: false,
          factor: 1.0,
          note: "less than #{@min_mm} mm in the window; nothing to correct"
        })

      true ->
        {lo, hi} = @clamp
        ratio = ((gauge_mm + 0.1) / (radar_mm + 0.1)) |> max(lo) |> min(hi)
        w = min(1.0, max(gauge_mm, radar_mm) / @full_weight_mm)
        factor = 1 + w * (ratio - 1)

        Map.merge(base, %{
          compared: true,
          applied: true,
          ratio: Float.round(ratio, 3),
          weight: Float.round(w, 3),
          factor: Float.round(factor, 3),
          note: "rain rates scaled by the factor; chance untouched"
        })
    end
  end
end
