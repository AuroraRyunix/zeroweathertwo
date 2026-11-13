defmodule ZeroWeather.Locations do
  @moduledoc """
  Curated Belgian preset locations with precise coordinates.
  """

  @presets [
    %{id: "ghent", name: "Ghent", region: "East Flanders", lat: 51.0543, lon: 3.7174},
    %{id: "brussels", name: "Brussels", region: "Brussels-Capital", lat: 50.8503, lon: 4.3517},
    %{id: "antwerp", name: "Antwerp", region: "Antwerp", lat: 51.2194, lon: 4.4025},
    %{id: "bruges", name: "Bruges", region: "West Flanders", lat: 51.2093, lon: 3.2247},
    %{id: "liege", name: "Liège", region: "Wallonia", lat: 50.6326, lon: 5.5797},
    %{id: "namur", name: "Namur", region: "Wallonia", lat: 50.4674, lon: 4.8720},
    %{id: "leuven", name: "Leuven", region: "Flemish Brabant", lat: 50.8798, lon: 4.7005},
    %{id: "hasselt", name: "Hasselt", region: "Limburg", lat: 50.9311, lon: 5.3378},
    %{id: "mons", name: "Mons", region: "Hainaut", lat: 50.4541, lon: 3.9567},
    %{id: "ostend", name: "Ostend", region: "Belgian Coast", lat: 51.2154, lon: 2.9287}
  ]

  def list, do: @presets

  def default, do: hd(@presets)

  def find_by_id(id) do
    Enum.find(@presets, &(&1.id == id)) || default()
  end
end
