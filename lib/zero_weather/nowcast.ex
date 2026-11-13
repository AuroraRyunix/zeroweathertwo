defmodule ZeroWeather.Nowcast do
  @moduledoc """
  Point rain nowcast from Buienradar's public "raintext" feed.

  The feed returns 24 lines (5-minute steps, about 2 hours), one per slot, as `PPP|HH:MM`:

      000|14:45
      087|14:50   # rain starts
      077|14:55
      000|15:00

  `HH:MM` is the local Belgian/Dutch clock and `PPP` is a raw value; the rain rate is
  `mm/h = 10 ** ((PPP - 109) / 32)` (0 means dry).

  From the 5-minute snapshots this module builds a continuous 1-minute timeline by linear
  interpolation and turns it into a countdown such as "Dry for the next 48 minutes." plus
  "Rain starting at 14:48, lasting 8 minutes, peak 0.2 mm/h.".

  Everything except `get/3` is pure, so it can be tested with a fixed `now`.
  """

  alias ZeroWeather.Cache

  @feed_url "https://gadgets.buienradar.nl/data/raintext/"
  @user_agent "ZeroWeather/0.1 (+https://weather.zerotwo.cloud)"
  # Buienradar updates every 5 minutes; 55 s keeps a 1-minute poll fresh without hammering it
  # (the cache is shared by every connected viewer).
  @cache_ttl 55
  # mm/h at or above which a minute counts as rain
  @rain_threshold 0.1
  @max_horizon_min 120

  @doc """
  Fetches (cached) the feed for a point and builds the 1-minute series and summary for `now`.

  The raw feed is cached, the series is rebuilt on every call, so the countdown is minute-accurate
  even when the cached feed is a few seconds old.
  """
  def get(lat, lon, now \\ DateTime.utc_now()) when is_number(lat) and is_number(lon) do
    # The feed has ~1 km resolution; two decimals also gives a sensible cache key.
    lat = Float.round(lat * 1.0, 2)
    lon = Float.round(lon * 1.0, 2)

    case Cache.fetch({:buienradar_raintext, lat, lon}, @cache_ttl, fn -> fetch_raw(lat, lon) end) do
      {:ok, %{slots: slots, fetched_at: fetched_at}} -> {:ok, build(slots, fetched_at, now)}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  @doc "Builds the result map (5-minute slots, 1-minute series, summary) from parsed slots."
  def build(slots, %DateTime{} = fetched_at, %DateTime{} = now) do
    anchored = anchor_slots(slots, now)
    series = series(anchored, now)

    %{
      source: "Buienradar",
      fetched_at: DateTime.to_iso8601(fetched_at),
      generated_at: DateTime.to_iso8601(now),
      slots: Enum.map(anchored, fn s -> %{time: s.time, mm_h: Float.round(s.mm_h, 2)} end),
      series: series,
      summary: summarize(series)
    }
  end

  defp fetch_raw(lat, lon) do
    request =
      Req.get(@feed_url,
        params: [lat: lat, lon: lon],
        headers: [{"user-agent", @user_agent}],
        receive_timeout: 4_000,
        retry: false
      )

    case request do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        with {:ok, slots} <- parse(body) do
          {:ok, %{slots: slots, fetched_at: DateTime.utc_now()}}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  # -- Parsing ---------------------------------------------------------------------------

  @doc "Parses the raw feed body into slots. Malformed lines are ignored."
  def parse(body) when is_binary(body) do
    slots =
      body
      |> String.split(["\r\n", "\n"], trim: true)
      |> Enum.flat_map(&parse_line/1)

    case slots do
      [] -> {:error, :empty_feed}
      slots -> {:ok, slots}
    end
  end

  defp parse_line(line) do
    with [raw, clock] <- line |> String.trim() |> String.split("|"),
         {raw, ""} <- Integer.parse(raw),
         [hour, minute] <- String.split(clock, ":"),
         {hour, ""} <- Integer.parse(hour),
         {minute, ""} <- Integer.parse(minute),
         true <- raw in 0..255 and hour in 0..23 and minute in 0..59 do
      [
        %{
          raw: raw,
          hour: hour,
          minute: minute,
          time: format_clock(hour, minute),
          mm_h: raw_to_mm_h(raw)
        }
      ]
    else
      _ -> []
    end
  end

  @doc "Raw feed value to rain rate in mm/h."
  def raw_to_mm_h(0), do: 0.0
  def raw_to_mm_h(raw) when is_integer(raw) and raw > 0, do: :math.pow(10, (raw - 109) / 32)

  # -- Time handling (Belgium/Netherlands share the EU DST rule) ------------------------------

  @doc "Offset of the Belgian clock from UTC in minutes (60 in winter, 120 in summer) at a UTC instant."
  def local_offset_minutes(%DateTime{} = utc) do
    if DateTime.compare(utc, dst_boundary(utc.year, 3)) != :lt and
         DateTime.compare(utc, dst_boundary(utc.year, 10)) == :lt do
      120
    else
      60
    end
  end

  # DST starts/ends on the last Sunday of March/October at 01:00 UTC.
  defp dst_boundary(year, month) do
    last_day = Date.new!(year, month, 31)
    sunday = Date.add(last_day, -rem(Date.day_of_week(last_day), 7))
    DateTime.new!(sunday, ~T[01:00:00], "Etc/UTC")
  end

  defp to_local_naive(%DateTime{} = utc) do
    utc |> DateTime.add(local_offset_minutes(utc) * 60, :second) |> DateTime.to_naive()
  end

  defp local_to_utc(%NaiveDateTime{} = local) do
    as_utc = DateTime.from_naive!(local, "Etc/UTC")

    DateTime.add(
      as_utc,
      -local_offset_minutes(DateTime.add(as_utc, -3600, :second)) * 60,
      :second
    )
  end

  @doc """
  Gives every slot a UTC instant (`:at`). The feed only carries a clock time, so the first slot is
  placed on the calendar day closest to `now`, and later slots roll over midnight when the clock wraps.
  """
  def anchor_slots([], _now), do: []

  def anchor_slots([first | _] = slots, %DateTime{} = now) do
    start_date = initial_date(first, to_local_naive(now))

    {anchored, _} =
      Enum.map_reduce(slots, {start_date, nil}, fn slot, {date, prev} ->
        naive = slot_naive(date, slot)

        {date, naive} =
          if prev != nil and NaiveDateTime.compare(naive, prev) == :lt do
            next = Date.add(date, 1)
            {next, slot_naive(next, slot)}
          else
            {date, naive}
          end

        {Map.put(slot, :at, local_to_utc(naive)), {date, naive}}
      end)

    anchored
  end

  defp slot_naive(date, slot), do: NaiveDateTime.new!(date, Time.new!(slot.hour, slot.minute, 0))

  defp initial_date(first, local_now) do
    today = NaiveDateTime.to_date(local_now)
    diff = NaiveDateTime.diff(slot_naive(today, first), local_now, :second)

    cond do
      diff < -12 * 3600 -> Date.add(today, 1)
      diff > 12 * 3600 -> Date.add(today, -1)
      true -> today
    end
  end

  # -- 1-minute interpolated series ---------------------------------------------------------

  @doc """
  Linearly interpolates the 5-minute slots to one point per minute, from the current minute until the
  last slot (at most `horizon` minutes). Before the first slot the first value is held.
  """
  def series(anchored, now, horizon \\ @max_horizon_min)
  def series([], _now, _horizon), do: []

  def series(anchored, %DateTime{} = now, horizon) do
    points = Enum.map(anchored, fn s -> {DateTime.to_unix(s.at), s.mm_h} end)
    {last_unix, _} = List.last(points)
    start_unix = div(DateTime.to_unix(now), 60) * 60
    last_index = min(div(last_unix - start_unix, 60), horizon - 1)

    if last_index < 0 do
      []
    else
      for i <- 0..last_index do
        t = start_unix + i * 60
        at = DateTime.from_unix!(t)

        %{
          at: DateTime.to_iso8601(at),
          time: local_time(at),
          mm_h: points |> interpolate(t) |> Float.round(3)
        }
      end
    end
  end

  defp interpolate([{t0, v0} | _], t) when t <= t0, do: v0
  defp interpolate([{_, v}], _t), do: v

  defp interpolate([{t0, v0}, {t1, v1} | _], t) when t <= t1,
    do: v0 + (v1 - v0) * (t - t0) / (t1 - t0)

  defp interpolate([_ | rest], t), do: interpolate(rest, t)

  # -- Countdown summary -----------------------------------------------------------------

  @doc "Turns the 1-minute series into a headline/detail countdown and the numbers behind it."
  def summarize([]), do: %{state: :unknown, headline: "Radar nowcast unavailable", detail: nil}

  def summarize([current | _] = series) do
    horizon = length(series)

    if rain?(current),
      do: summarize_raining(series, horizon),
      else: summarize_dry(series, horizon)
  end

  defp summarize_dry(series, horizon) do
    case Enum.find_index(series, &rain?/1) do
      nil ->
        %{
          state: :dry,
          headline: "Dry for the next #{span_text(horizon)}.",
          detail: nil,
          horizon_min: horizon
        }

      start_idx ->
        {rain, after_rain} = series |> Enum.drop(start_idx) |> Enum.split_while(&rain?/1)
        start = hd(rain)
        peak = Enum.max_by(rain, & &1.mm_h)
        duration = length(rain)
        ended? = after_rain != []

        %{
          state: :rain_soon,
          headline: dry_headline(start_idx),
          detail:
            "Rain starting at #{start.time}, lasting #{duration_text(duration, ended?)}, " <>
              "peak #{fmt_rate(peak.mm_h)} mm/h.",
          starts_in_min: start_idx,
          starts_at: start.time,
          duration_min: duration,
          lasts_beyond_horizon: not ended?,
          peak_mm_h: Float.round(peak.mm_h, 1),
          peak_at: peak.time,
          horizon_min: horizon
        }
    end
  end

  defp summarize_raining([current | _] = series, horizon) do
    {rain, after_rain} = Enum.split_while(series, &rain?/1)
    peak = Enum.max_by(rain, & &1.mm_h)

    base = %{
      state: :raining,
      headline: "Raining now (#{fmt_rate(current.mm_h)} mm/h).",
      rate_mm_h: Float.round(current.mm_h, 1),
      peak_mm_h: Float.round(peak.mm_h, 1),
      peak_at: peak.time,
      horizon_min: horizon
    }

    case after_rain do
      [] ->
        Map.merge(base, %{
          detail:
            "Rain continuing for the next #{span_text(horizon)}, peak #{fmt_rate(peak.mm_h)} mm/h.",
          ends_in_min: nil
        })

      [easing | _] ->
        ends_in = length(rain)

        Map.merge(base, %{
          detail:
            "Easing below #{@rain_threshold} mm/h at #{easing.time} (in #{minutes_text(ends_in)}), " <>
              "peak #{fmt_rate(peak.mm_h)} mm/h.",
          ends_in_min: ends_in,
          ends_at: easing.time
        })
    end
  end

  defp rain?(point), do: point.mm_h >= @rain_threshold

  defp dry_headline(1), do: "Dry for the next minute."
  defp dry_headline(n), do: "Dry for the next #{minutes_text(n)}."

  defp duration_text(minutes, true), do: minutes_text(minutes)
  defp duration_text(minutes, false), do: "#{minutes}+ minutes"

  defp minutes_text(1), do: "1 minute"
  defp minutes_text(n), do: "#{n} minutes"

  # The series is capped at ~2 hours; say "2 hours" instead of "119 minutes".
  defp span_text(minutes) when minutes >= 110, do: "2 hours"
  defp span_text(minutes), do: minutes_text(minutes)

  defp fmt_rate(mm_h), do: mm_h |> Float.round(1) |> Float.to_string()

  defp format_clock(hour, minute) do
    String.pad_leading(Integer.to_string(hour), 2, "0") <>
      ":" <> String.pad_leading(Integer.to_string(minute), 2, "0")
  end

  @doc "HH:MM on the Belgian clock for a UTC instant."
  def local_time(%DateTime{} = utc) do
    utc |> DateTime.add(local_offset_minutes(utc) * 60, :second) |> Calendar.strftime("%H:%M")
  end
end
