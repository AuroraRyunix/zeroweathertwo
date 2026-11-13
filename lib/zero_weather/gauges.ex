defmodule ZeroWeather.Gauges do
  @moduledoc """
  Ground truth from RMI's automatic weather stations (10-minute records, open-data WFS `aws:aws_10min`): rain gauge,
  temperature and relative humidity, from which the dew point and the dew-point depression follow. The depression
  tells whether radar echoes can plausibly reach the ground (very dry air near the surface evaporates light rain, "virga").

  Only the stations listed in `@stations` are queried (RMI publishes 14 open stations; Melle is the one near Ghent).
  Nothing here changes the forecast yet: the values are shown next to it, because correcting the radar with them
  needs rain cases to validate against.
  """

  alias ZeroWeather.Cache

  @wfs "https://opendata.meteo.be/service/aws/wfs"
  @ttl 300
  @down_ttl 90
  @max_distance_km 60

  # code, name, latitude, longitude (approximate; used only for the distance check)
  @stations [%{code: 6434, name: "Melle", lat: 50.98, lon: 3.82}]

  @doc "Latest 10-minute records (newest first) of the nearest station within #{@max_distance_km} km."
  def latest(lat, lon) do
    do_latest(lat, lon)
  rescue
    # the gauge is a side note next to the forecast: whatever goes wrong here must never take the forecast down
    e -> {:error, {:gauge_failed, Exception.message(e)}}
  end

  defp do_latest(lat, lon) do
    with {:ok, station, distance} <- nearest(lat, lon),
         :error <- Cache.get(:gauges_down) |> down_error(),
         {:ok, records} <- records(station) do
      {:ok, summarize(station, distance, records)}
    end
  end

  defp down_error({:ok, reason}), do: {:error, {:rmi_backing_off, reason}}
  defp down_error(:error), do: :error

  @doc false
  def nearest(lat, lon) do
    @stations
    |> Enum.map(&{&1, distance_km(lat, lon, &1.lat, &1.lon)})
    |> Enum.min_by(&elem(&1, 1))
    |> case do
      {station, d} when d <= @max_distance_km -> {:ok, station, d}
      _ -> {:error, :no_station_nearby}
    end
  end

  defp records(station) do
    Cache.fetch({:gauge_records, station.code}, @ttl, fn ->
      if Application.get_env(:zero_weather, :rmi_radar, true) == false do
        {:error, :rmi_disabled}
      else
        with {:error, reason} = error <- fetch_records(station) do
          Cache.put(:gauges_down, reason, @down_ttl)
          error
        end
      end
    end)
  end

  defp fetch_records(station) do
    since =
      DateTime.utc_now() |> DateTime.add(-90 * 60) |> Calendar.strftime("%Y-%m-%dT%H:%M:%SZ")

    case Req.get(@wfs,
           params: [
             service: "WFS",
             version: "2.0.0",
             request: "GetFeature",
             typeNames: "aws:aws_10min",
             outputFormat: "application/json",
             cql_filter: "code=#{station.code} AND timestamp > '#{since}'",
             sortBy: "timestamp D",
             count: 9
           ],
           receive_timeout: 8_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"features" => features}}} -> parse(features)
      {:ok, %{status: status}} -> {:error, {:aws_http_status, status}}
      {:error, reason} -> {:error, {:aws_unreachable, reason}}
      other -> {:error, {:aws_unexpected, other}}
    end
  end

  @doc "Records from the GeoJSON `features` list of the WFS answer, newest first."
  def parse(features) when is_list(features) do
    records =
      features
      |> Enum.map(& &1["properties"])
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn p ->
        %{
          time: p["timestamp"],
          precip_mm_10min: number(p["precip_quantity"]),
          temperature: number(p["temp_dry_shelter_avg"]),
          humidity: number(p["humidity_rel_shelter_avg"])
        }
      end)
      |> Enum.sort_by(& &1.time, :desc)

    if records == [], do: {:error, :no_records}, else: {:ok, records}
  end

  defp number(v) when is_number(v), do: v * 1.0
  defp number(_), do: nil

  defp summarize(station, distance, [newest | _] = records) do
    td = dew_point(newest.temperature, newest.humidity)

    %{
      station: station.name,
      distance_km: Float.round(distance, 1),
      time: newest.time,
      temperature: newest.temperature,
      humidity: newest.humidity,
      dew_point: td,
      depression: if(td && newest.temperature, do: Float.round(newest.temperature - td, 1)),
      precip_mm_10min: newest.precip_mm_10min,
      # rain over the last hour (six 10-minute records), mm
      precip_mm_hour:
        records
        |> Enum.take(6)
        |> Enum.map(&(&1.precip_mm_10min || 0.0))
        |> Enum.sum()
        |> Float.round(1)
    }
  end

  @doc "Dew point in degrees Celsius (Magnus formula) from temperature (C) and relative humidity (%)."
  def dew_point(t, rh) when is_number(t) and is_number(rh) and rh > 0 do
    a = 17.62
    b = 243.12
    gamma = a * t / (b + t) + :math.log(rh / 100)
    Float.round(b * gamma / (a - gamma), 1)
  end

  def dew_point(_t, _rh), do: nil

  @doc "True when air near the ground is dry enough (depression of 8 degrees or more) that light rain can evaporate."
  def virga_risk?(%{depression: d}) when is_number(d), do: d >= 8.0
  def virga_risk?(_), do: false

  defp distance_km(lat1, lon1, lat2, lon2) do
    dlat = (lat2 - lat1) * 111.195
    dlon = (lon2 - lon1) * 111.195 * :math.cos((lat1 + lat2) / 2 * :math.pi() / 180)
    :math.sqrt(dlat * dlat + dlon * dlon)
  end
end
