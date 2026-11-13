defmodule ZeroWeather.Prewarm do
  @moduledoc """
  Keeps our own nowcast for the default location warm, so the first visitor (or the first one after a deploy) does
  not wait for the radar tiles to download and decode. Runs every 4 minutes (a new radar frame arrives every 10).
  """
  use GenServer

  @interval 240_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    send(self(), :warm)
    {:ok, nil}
  end

  @impl true
  def handle_info(:warm, state) do
    loc = ZeroWeather.Locations.default()
    # errors are fine here: the page falls back to Buienradar and says why
    _ = ZeroWeather.RadarNowcast.get(loc.lat, loc.lon)
    Process.send_after(self(), :warm, @interval)
    {:noreply, state}
  end
end
