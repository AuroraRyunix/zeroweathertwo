defmodule ZeroWeather.Locations do
  @moduledoc """
  The one preset (Ghent); any other point comes from the browser's location.
  """

  @presets [
    %{id: "ghent", name: "Ghent", region: "East Flanders", lat: 51.0543, lon: 3.7174}
  ]

  def list, do: @presets

  def default, do: hd(@presets)

  def find_by_id(id) do
    Enum.find(@presets, &(&1.id == id)) || default()
  end
end
