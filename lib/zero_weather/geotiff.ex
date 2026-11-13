defmodule ZeroWeather.GeoTiff do
  @moduledoc """
  Minimal reader for the single-band, uncompressed 32-bit float GeoTIFFs that RMI's GeoServer (WCS) returns:
  strips or tiles, either byte order, georeferencing from `ModelTransformation` or `ModelPixelScale` + `ModelTiepoint`.
  Returns the raster as a binary of float32 values in the file's byte order (row-major) plus the affine geotransform, so a
  0.01 degree grid of 900 x 540 cells stays at 2 MB and individual cells are read without building a list.
  """

  @doc """
  Decodes a GeoTIFF. `{:ok, %{width, height, data, lon0, lat0, dlon, dlat}}` where `data` is
  `width * height` float32 values (byte order in `endian`), `(lon0, lat0)` is the top-left corner of the top-left cell and
  `dlon` / `dlat` are the (positive) cell sizes in degrees (rows go south).
  """
  def decode(<<order::binary-size(2), 42::16-big, _::binary>> = file)
      when order in ["MM", "II"] do
    endian = if order == "MM", do: :big, else: :little

    with {:ok, tags} <- read_tags(file, endian),
         {:ok, width, height} <- dims(tags),
         :ok <- check_format(tags),
         {:ok, geo} <- geotransform(tags, file, endian),
         {:ok, data} <- raster(tags, file, endian, width, height) do
      {:ok, Map.merge(%{width: width, height: height, data: data, endian: endian}, geo)}
    end
  end

  def decode(_), do: {:error, :not_a_tiff}

  @doc "Float value at integer cell (column, row); `nil` outside the raster or where the file holds NaN."
  def cell(%{width: w, height: h, data: data, endian: endian}, x, y)
      when x >= 0 and y >= 0 and x < w and y < h do
    case binary_part(data, (y * w + x) * 4, 4) do
      <<v::float-32-big>> when endian == :big -> v
      <<v::float-32-little>> when endian == :little -> v
      _nan -> nil
    end
  end

  def cell(_raster, _x, _y), do: nil

  # -- IFD -------------------------------------------------------------------------------------

  defp read_tags(file, endian) do
    ifd_offset = u32(binary_part(file, 4, 4), endian)
    count = u16(binary_part(file, ifd_offset, 2), endian)

    tags =
      for i <- 0..(count - 1), into: %{} do
        e = binary_part(file, ifd_offset + 2 + i * 12, 12)
        tag = u16(binary_part(e, 0, 2), endian)
        type = u16(binary_part(e, 2, 2), endian)
        n = u32(binary_part(e, 4, 4), endian)
        size = type_size(type) * n

        raw =
          if size <= 4,
            do: binary_part(e, 8, size),
            else: binary_part(file, u32(binary_part(e, 8, 4), endian), size)

        {tag, values(type, n, raw, endian)}
      end

    {:ok, tags}
  rescue
    _ -> {:error, :bad_ifd}
  end

  defp type_size(t) when t in [1, 2, 6, 7], do: 1
  defp type_size(t) when t in [3, 8], do: 2
  defp type_size(t) when t in [4, 9, 11], do: 4
  defp type_size(t) when t in [5, 10, 12, 16], do: 8
  defp type_size(_), do: 1

  defp values(3, n, raw, endian),
    do: for(i <- 0..(n - 1), do: u16(binary_part(raw, i * 2, 2), endian))

  defp values(4, n, raw, endian),
    do: for(i <- 0..(n - 1), do: u32(binary_part(raw, i * 4, 4), endian))

  defp values(12, n, raw, endian),
    do: for(i <- 0..(n - 1), do: f64(binary_part(raw, i * 8, 8), endian))

  defp values(_type, _n, raw, _endian), do: raw

  defp u16(<<v::16-big>>, :big), do: v
  defp u16(<<v::16-little>>, :little), do: v
  defp u32(<<v::32-big>>, :big), do: v
  defp u32(<<v::32-little>>, :little), do: v
  defp f64(<<v::float-64-big>>, :big), do: v
  defp f64(<<v::float-64-little>>, :little), do: v

  # -- layout ----------------------------------------------------------------------------------

  defp dims(%{256 => [w], 257 => [h]}), do: {:ok, w, h}
  defp dims(_), do: {:error, :no_dimensions}

  defp check_format(tags) do
    bits = tags |> Map.get(258, [0]) |> hd()
    compression = tags |> Map.get(259, [1]) |> hd()
    samples = tags |> Map.get(277, [1]) |> hd()
    format = tags |> Map.get(339, [1]) |> hd()

    cond do
      bits != 32 or format != 3 -> {:error, {:unsupported_sample_format, bits, format}}
      compression != 1 -> {:error, {:unsupported_compression, compression}}
      samples != 1 -> {:error, {:unsupported_samples, samples}}
      true -> :ok
    end
  end

  defp geotransform(%{34264 => [a, _b, _c, d, _e, f, _g, h | _]}, _file, _endian) do
    # ModelTransformation: x = a*i + d, y = f*j + h
    {:ok, %{lon0: d, lat0: h, dlon: a, dlat: abs(f)}}
  end

  defp geotransform(%{33550 => [sx, sy | _], 33922 => [i, j, _k, x, y | _]}, _file, _endian) do
    {:ok, %{lon0: x - i * sx, lat0: y + j * sy, dlon: sx, dlat: sy}}
  end

  defp geotransform(_tags, _file, _endian), do: {:error, :no_georeference}

  defp raster(%{324 => offsets, 325 => counts} = tags, file, _endian, w, h) do
    [tw] = tags[322]
    [th] = tags[323]
    across = div(w + tw - 1, tw)
    down = div(h + th - 1, th)

    if length(offsets) != across * down or Enum.any?(counts, &(&1 != tw * th * 4)) do
      {:error, :unexpected_tiles}
    else
      tiles = offsets |> Enum.map(&binary_part(file, &1, tw * th * 4)) |> List.to_tuple()

      data =
        for y <- 0..(h - 1), into: <<>> do
          ty = div(y, th)
          ly = rem(y, th)

          row =
            for tx <- 0..(across - 1), into: <<>> do
              binary_part(elem(tiles, ty * across + tx), ly * tw * 4, tw * 4)
            end

          binary_part(row, 0, w * 4)
        end

      {:ok, data}
    end
  end

  defp raster(%{273 => offsets, 279 => counts}, file, _endian, w, h) do
    data =
      Enum.zip(offsets, counts)
      |> Enum.map(fn {o, c} -> binary_part(file, o, c) end)
      |> IO.iodata_to_binary()

    if byte_size(data) >= w * h * 4,
      do: {:ok, binary_part(data, 0, w * h * 4)},
      else: {:error, :short_strips}
  end

  defp raster(_tags, _file, _endian, _w, _h), do: {:error, :no_raster_data}
end
