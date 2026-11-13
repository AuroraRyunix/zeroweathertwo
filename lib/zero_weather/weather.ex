defmodule ZeroWeather.Weather do
  @moduledoc """
  Fetches point weather nowcasts, 15-minute precipitation predictions,
  current conditions, and air quality metrics.
  """
  alias ZeroWeather.Cache

  @open_meteo_forecast "https://api.open-meteo.com/v1/forecast"
  @open_meteo_air "https://air-quality-api.open-meteo.com/v1/air-quality"
  @cache_ttl 180 # 3 minutes

  @doc """
  Retrieves a comprehensive point weather nowcast for given coordinates.
  """
  def get_nowcast(lat, lon) when is_number(lat) and is_number(lon) do
    # Round lat/lon to 3 decimal places (~100m) for effective caching
    cache_key = {:nowcast, Float.round(lat * 1.0, 3), Float.round(lon * 1.0, 3)}

    Cache.fetch(cache_key, @cache_ttl, fn ->
      fetch_weather_bundle(lat, lon)
    end)
  end

  defp fetch_weather_bundle(lat, lon) do
    forecast_task = Task.async(fn -> fetch_forecast(lat, lon) end)
    air_task = Task.async(fn -> fetch_air_quality(lat, lon) end)

    forecast_res = Task.await(forecast_task, 8000)
    air_res = Task.await(air_task, 8000)

    case forecast_res do
      {:ok, forecast} ->
        air_quality =
          case air_res do
            {:ok, air} -> air
            _ -> %{eaqi: nil, pm2_5: nil, pm10: nil, no2: nil, o3: nil, label: "Unavailable"}
          end

        payload = Map.put(forecast, :air_quality, air_quality)
        {:ok, payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_forecast(lat, lon) do
    params = [
      latitude: lat,
      longitude: lon,
      current: "temperature_2m,relative_humidity_2m,precipitation,weather_code,wind_speed_10m,wind_direction_10m,surface_pressure",
      minutely_15: "precipitation,precipitation_probability",
      forecast_days: 1,
      timezone: "auto"
    ]

    case Req.get(@open_meteo_forecast, params: params, receive_timeout: 6000) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        current = body["current"] || %{}
        minutely = body["minutely_15"] || %{}

        times = minutely["time"] || []
        precip = minutely["precipitation"] || []
        probs = minutely["precipitation_probability"] || []

        # Take next 12 intervals (next 3 hours in 15-minute steps)
        timeline =
          Enum.zip([times, precip, probs])
          |> Enum.take(12)
          |> Enum.map(fn {t, p, prob} ->
            p_val = if is_number(p), do: Float.round(p * 1.0, 2), else: 0.0
            prob_val = if is_number(prob), do: prob, else: 0

            # Extract HH:MM
            formatted_time =
              case String.split(t, "T") do
                [_, time_part] -> String.slice(time_part, 0, 5)
                _ -> t
              end

            %{
              raw_time: t,
              time: formatted_time,
              precip_mm: p_val,
              probability: prob_val,
              intensity_label: categorize_rain(p_val)
            }
          end)

        summary = summarize_timeline(current["precipitation"] || 0.0, timeline)

        data = %{
          lat: lat,
          lon: lon,
          elevation: body["elevation"],
          current: %{
            temperature: current["temperature_2m"],
            humidity: current["relative_humidity_2m"],
            precipitation: current["precipitation"],
            wind_speed: current["wind_speed_10m"],
            wind_direction: current["wind_direction_10m"],
            pressure: current["surface_pressure"],
            weather_code: current["weather_code"],
            condition_text: weather_code_to_text(current["weather_code"]),
            condition_icon: weather_code_to_icon(current["weather_code"])
          },
          timeline: timeline,
          summary: summary,
          updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        {:ok, data}

      other ->
        {:error, {:forecast_failed, other}}
    end
  end

  defp fetch_air_quality(lat, lon) do
    params = [
      latitude: lat,
      longitude: lon,
      current: "european_aqi,pm10,pm2_5,nitrogen_dioxide,ozone"
    ]

    case Req.get(@open_meteo_air, params: params, receive_timeout: 5000) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        cur = body["current"] || %{}
        aqi = cur["european_aqi"]

        {:ok,
         %{
           eaqi: aqi,
           label: eaqi_label(aqi),
           pm2_5: cur["pm2_5"],
           pm10: cur["pm10"],
           no2: cur["nitrogen_dioxide"],
           o3: cur["ozone"]
         }}

      other ->
        {:error, other}
    end
  end

  defp categorize_rain(mm) when mm <= 0.05, do: :dry
  defp categorize_rain(mm) when mm <= 1.0, do: :light
  defp categorize_rain(mm) when mm <= 4.0, do: :moderate
  defp categorize_rain(_mm), do: :heavy

  defp summarize_timeline(current_precip, timeline) do
    is_raining_now = current_precip > 0.05

    if is_raining_now do
      # Find when it stops
      dry_step = Enum.find_index(timeline, fn s -> s.precip_mm <= 0.05 end)

      case dry_step do
        nil ->
          "Rain continuing for the next 2+ hours."

        0 ->
          "Rain ending shortly."

        idx ->
          mins = idx * 15
          "Raining now (#{current_precip} mm/h), expected to stop in ~#{mins} min."
      end
    else
      # Check if rain is starting
      rain_step = Enum.find_index(timeline, fn s -> s.precip_mm > 0.05 end)

      case rain_step do
        nil ->
          "Dry: No rain expected in the next 3 hours."

        idx ->
          mins = idx * 15
          first_rain = Enum.at(timeline, idx)
          max_step = Enum.max_by(timeline, & &1.precip_mm)
          "Rain starting in ~#{mins} min (at #{first_rain.time}, peak ~#{max_step.precip_mm} mm/h)."
      end
    end
  end

  defp eaqi_label(nil), do: "Unknown"
  defp eaqi_label(aqi) when aqi <= 20, do: "Good"
  defp eaqi_label(aqi) when aqi <= 40, do: "Fair"
  defp eaqi_label(aqi) when aqi <= 60, do: "Moderate"
  defp eaqi_label(aqi) when aqi <= 80, do: "Poor"
  defp eaqi_label(_aqi), do: "Very Poor"

  defp weather_code_to_text(0), do: "Clear sky"
  defp weather_code_to_text(1), do: "Mainly clear"
  defp weather_code_to_text(2), do: "Partly cloudy"
  defp weather_code_to_text(3), do: "Overcast"
  defp weather_code_to_text(45), do: "Fog"
  defp weather_code_to_text(48), do: "Depositing rime fog"
  defp weather_code_to_text(51), do: "Light drizzle"
  defp weather_code_to_text(53), do: "Moderate drizzle"
  defp weather_code_to_text(55), do: "Dense drizzle"
  defp weather_code_to_text(61), do: "Slight rain"
  defp weather_code_to_text(63), do: "Moderate rain"
  defp weather_code_to_text(65), do: "Heavy rain"
  defp weather_code_to_text(71), do: "Slight snow"
  defp weather_code_to_text(73), do: "Moderate snow"
  defp weather_code_to_text(75), do: "Heavy snow"
  defp weather_code_to_text(80), do: "Slight rain showers"
  defp weather_code_to_text(81), do: "Moderate rain showers"
  defp weather_code_to_text(82), do: "Violent rain showers"
  defp weather_code_to_text(95), do: "Thunderstorm"
  defp weather_code_to_text(96), do: "Thunderstorm with slight hail"
  defp weather_code_to_text(99), do: "Thunderstorm with heavy hail"
  defp weather_code_to_text(_), do: "Variable"

  defp weather_code_to_icon(0), do: "☀️"
  defp weather_code_to_icon(1), do: "🌤️"
  defp weather_code_to_icon(2), do: "⛅"
  defp weather_code_to_icon(3), do: "☁️"
  defp weather_code_to_icon(45), do: "🌫️"
  defp weather_code_to_icon(48), do: "🌫️"
  defp weather_code_to_icon(code) when code in [51, 53, 55], do: "🌦️"
  defp weather_code_to_icon(code) when code in [61, 63, 65, 80, 81, 82], do: "🌧️"
  defp weather_code_to_icon(code) when code in [71, 73, 75], do: "🌨️"
  defp weather_code_to_icon(code) when code in [95, 96, 99], do: "⛈️"
  defp weather_code_to_icon(_), do: "🌡️"
end
