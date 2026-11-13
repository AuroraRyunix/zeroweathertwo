defmodule ZeroWeather.Radar do
  @moduledoc """
  Manages radar imagery metadata and tile streams.
  """
  alias ZeroWeather.Cache

  @rainviewer_api "https://api.rainviewer.com/public/weather-maps.json"
  @cache_ttl 120 # 2 minutes

  @doc """
  Fetches the latest radar metadata including past frames and nowcast projections.
  """
  def get_radar_meta do
    Cache.fetch(:radar_metadata, @cache_ttl, fn ->
      fetch_from_upstream()
    end)
  end

  defp fetch_from_upstream do
    case Req.get(@rainviewer_api, receive_timeout: 8000) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        host = body["host"] || "https://tilecache.rainviewer.com"
        radar = body["radar"] || %{}
        past = radar["past"] || []
        nowcast = radar["nowcast"] || []

        frames =
          (past ++ nowcast)
          |> Enum.map(fn frame ->
            %{
              time: frame["time"],
              iso_time: DateTime.from_unix!(frame["time"]) |> DateTime.to_iso8601(),
              path: frame["path"],
              tile_url_template: "#{host}#{frame["path"]}/512/{z}/{x}/{y}/2/1_1.png",
              is_nowcast: frame in nowcast
            }
          end)

        latest_past = List.last(past)

        meta = %{
          generated_at: body["generated"],
          host: host,
          frames: frames,
          latest_frame:
            if latest_past do
              %{
                time: latest_past["time"],
                iso_time: DateTime.from_unix!(latest_past["time"]) |> DateTime.to_iso8601(),
                tile_url_template: "#{host}#{latest_past["path"]}/512/{z}/{x}/{y}/2/1_1.png"
              }
            else
              nil
            end
        }

        {:ok, meta}

      other ->
        {:error, {:upstream_failed, other}}
    end
  end
end
