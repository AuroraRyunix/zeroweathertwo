defmodule ZeroWeather.RadarGrid do
  @moduledoc """
  Turns RainViewer's radar tiles into a coarse rain-rate grid around a point.

  The tiles are rendered with RainViewer's fixed "Universal Blue" palette; `ZeroWeather.RadarColors` inverts their
  published dBZ table, so every pixel becomes a real reflectivity and then a rain rate (Marshall-Palmer). Pixels are
  averaged into cells of `@downsample` x `@downsample` pixels (about 0.75 km at Belgian latitudes) with
  `ZeroWeather.Png`. Decoded tiles are cached, so every viewer shares them.

  Coordinates: everything lives in the Web-Mercator *cell grid* at zoom `@zoom`
  (x grows to the east, y grows to the south), which makes tile lookups and distances trivial.
  """

  alias ZeroWeather.{Cache, Png, RadarColors}

  @zoom 7
  @tile_px 512
  @downsample 2
  @cells_per_tile div(@tile_px, @downsample)
  @world_px 65_536
  @tile_ttl 2_700
  @failure_ttl 45

  @doc "Cells per tile edge."
  def cells_per_tile, do: @cells_per_tile

  # -- geometry --------------------------------------------------------------------------

  @doc "Web-Mercator pixel coordinates at the grid zoom."
  def world_px(lat, lon) do
    rad = lat * :math.pi() / 180
    x = (lon + 180) / 360 * @world_px
    y = (1 - :math.log(:math.tan(rad) + 1 / :math.cos(rad)) / :math.pi()) / 2 * @world_px
    {x, y}
  end

  @doc "Ground size of one grid cell in kilometres at a latitude."
  def cell_km(lat) do
    40_075.016686 * :math.cos(lat * :math.pi() / 180) / @world_px * @downsample
  end

  # -- one tile ----------------------------------------------------------------------------

  @doc """
  Downsampled rain rates of one tile as a binary of `cells_per_tile ** 2` unsigned 16-bit values
  (units of 0.01 mm/h, row-major), cached.
  """
  def tile_cells(host, path, x, y) do
    case Cache.get({:radar_tile_failed, path, x, y}) do
      {:ok, reason} ->
        {:error, {:recently_failed, reason}}

      :error ->
        case Cache.fetch({:radar_tile, path, @zoom, x, y}, @tile_ttl, fn ->
               fetch_tile(host, path, x, y)
             end) do
          {:ok, cells} ->
            {:ok, cells}

          {:error, reason} ->
            # do not hammer the tile server: skip this tile for a short while (it also covers HTTP 429)
            Cache.put({:radar_tile_failed, path, x, y}, reason, @failure_ttl)
            {:error, reason}
        end
    end
  end

  defp fetch_tile(host, path, x, y) do
    url = "#{host}#{path}/#{@tile_px}/#{@zoom}/#{x}/#{y}/0/0_0.png"

    with {:ok, %{status: 200, body: body}} when is_binary(body) <-
           Req.get(url,
             receive_timeout: 8_000,
             retry: false,
             decode_body: false,
             headers: [{"user-agent", "ZeroWeather/0.1"}]
           ),
         {:ok, img} <- Png.decode(body) do
      {:ok, downsample(img)}
    else
      {:ok, %{status: status}} -> {:error, {:tile_http_status, status}}
      {:error, reason} -> {:error, {:tile_failed, reason}}
    end
  end

  @doc false
  def downsample(%{width: @tile_px, height: @tile_px, rgba: rgba}) do
    stride = @tile_px * 4
    area = @downsample * @downsample

    for cy <- 0..(@cells_per_tile - 1), into: <<>> do
      # sum the rain rate of each 4-pixel run of the 4 rows that make up this cell row
      sums =
        Enum.reduce(0..(@downsample - 1), List.duplicate(0.0, @cells_per_tile), fn dy, acc ->
          row = binary_part(rgba, (cy * @downsample + dy) * stride, stride)

          for(<<px::binary-size(4) <- row>>, do: RadarColors.rate(px))
          |> Enum.chunk_every(@downsample)
          |> Enum.map(&Enum.sum/1)
          |> Enum.zip_with(acc, &(&1 + &2))
        end)

      for sum <- sums, into: <<>>, do: <<min(round(sum / area * 100), 65_535)::16>>
    end
  end

  @doc """
  Averages 2x2 cells of a window into one (cells twice as large). Used to track motion, which does not need the
  full resolution and would be 16 times more expensive on it.
  """
  def coarsen(%{n: n, rows: rows} = grid) do
    m = div(n, 2)

    coarse =
      for j <- 0..(m - 1) do
        top = elem(rows, 2 * j)
        bottom = elem(rows, 2 * j + 1)

        List.to_tuple(
          for i <- 0..(m - 1) do
            (elem(top, 2 * i) + elem(top, 2 * i + 1) + elem(bottom, 2 * i) +
               elem(bottom, 2 * i + 1)) / 4
          end
        )
      end

    %{
      grid
      | n: m,
        cx: grid.cx / 2,
        cy: grid.cy / 2,
        cell_km: grid.cell_km * 2,
        rows: List.to_tuple(coarse)
    }
  end

  # -- window around a point -----------------------------------------------------------------

  @doc """
  Builds a `(2 * half + 1)` square window of rain-rate cells centred on a point.

  Returns `{:ok, grid}` where `grid` has the fields `n`, `cx`, `cy` (the point's position in window cells),
  `cell_km`, `lat`, `lon` and `rows` (tuple of tuples of mm/h floats), or `{:error, reason}` when a tile is missing.
  """
  def window(host, path, lat, lon, half) do
    {px, py} = world_px(lat, lon)
    gx = px / @downsample
    gy = py / @downsample
    n = 2 * half + 1
    ox = floor(gx) - half
    oy = floor(gy) - half
    tiles = tiles_for(lat, lon, half)

    fetched =
      tiles
      |> Task.async_stream(fn {tx, ty} -> {{tx, ty}, tile_cells(host, path, tx, ty)} end,
        max_concurrency: 3,
        timeout: 15_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, {key, {:ok, cells}}} -> {key, cells}
        {:ok, {key, error}} -> {key, error}
        {:exit, reason} -> {:error, {:tile_task, reason}}
      end)

    case Enum.find(fetched, fn {_k, v} -> not is_binary(v) end) do
      nil -> {:ok, assemble(Map.new(fetched), ox, oy, n, gx - ox, gy - oy, lat, lon)}
      {_key, error} -> {:error, error}
      other -> {:error, other}
    end
  end

  @doc "The `{x, y}` tiles a window of `half` cells around a point needs."
  def tiles_for(lat, lon, half) do
    {px, py} = world_px(lat, lon)
    ox = floor(px / @downsample) - half
    oy = floor(py / @downsample) - half
    n = 2 * half + 1

    for ty <- div_floor(oy, @cells_per_tile)..div_floor(oy + n - 1, @cells_per_tile),
        tx <- div_floor(ox, @cells_per_tile)..div_floor(ox + n - 1, @cells_per_tile),
        do: {tx, ty}
  end

  defp assemble(tiles, ox, oy, n, cx, cy, lat, lon) do
    rows =
      for gy <- oy..(oy + n - 1) do
        ty = div_floor(gy, @cells_per_tile)
        ly = gy - ty * @cells_per_tile

        0..(n - 1)
        |> Enum.map(fn i ->
          gx = ox + i
          tx = div_floor(gx, @cells_per_tile)
          lx = gx - tx * @cells_per_tile
          <<v::16>> = binary_part(Map.fetch!(tiles, {tx, ty}), (ly * @cells_per_tile + lx) * 2, 2)
          v / 100
        end)
        |> List.to_tuple()
      end

    %{n: n, cx: cx, cy: cy, cell_km: cell_km(lat), lat: lat, lon: lon, rows: List.to_tuple(rows)}
  end

  defp div_floor(a, b), do: Integer.floor_div(a, b)

  # -- sampling ----------------------------------------------------------------------------------

  @doc "Window cell coordinates (floats) of a geographic point, for use with `sample/3`."
  def locate(%{cx: cx, cy: cy, lat: lat0, lon: lon0}, lat, lon) do
    {cpx, cpy} = world_px(lat0, lon0)
    {ppx, ppy} = world_px(lat, lon)
    {cx + (ppx - cpx) / @downsample, cy + (ppy - cpy) / @downsample}
  end

  @doc "Rain rate (mm/h) at an integer cell, 0.0 outside the window."
  def cell(%{n: n, rows: rows}, x, y) when x >= 0 and y >= 0 and x < n and y < n do
    rows |> elem(y) |> elem(x)
  end

  def cell(_grid, _x, _y), do: 0.0

  @doc "Bilinear sample at fractional window coordinates (cell centres are at integer + 0.5)."
  def sample(grid, x, y) do
    fx = x - 0.5
    fy = y - 0.5
    x0 = floor(fx)
    y0 = floor(fy)
    tx = fx - x0
    ty = fy - y0

    cell(grid, x0, y0) * (1 - tx) * (1 - ty) + cell(grid, x0 + 1, y0) * tx * (1 - ty) +
      cell(grid, x0, y0 + 1) * (1 - tx) * ty + cell(grid, x0 + 1, y0 + 1) * tx * ty
  end
end
