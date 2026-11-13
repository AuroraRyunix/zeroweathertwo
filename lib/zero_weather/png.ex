defmodule ZeroWeather.Png do
  @moduledoc """
  Minimal pure-Elixir PNG decoder for radar tiles: 8-bit, non-interlaced RGBA (what RainViewer serves).

  Radar nowcasting only needs the pixel values, so there is deliberately no native image dependency
  (it keeps the Alpine release image small and the build simple).
  """
  import Bitwise

  @signature <<137, 80, 78, 71, 13, 10, 26, 10>>

  @type t :: %{width: pos_integer(), height: pos_integer(), rgba: binary()}

  @doc "Decodes an RGBA PNG. Returns `{:ok, %{width:, height:, rgba:}}` or `{:error, reason}`."
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(<<@signature, rest::binary>>) do
    with {:ok, chunks} <- read_chunks(rest, []),
         {:ok, width, height} <- header(chunks) do
      idat = for {"IDAT", data} <- chunks, into: <<>>, do: data

      try do
        raw = :zlib.uncompress(idat)
        stride = width * 4

        if byte_size(raw) != height * (stride + 1) do
          {:error, :unexpected_data_size}
        else
          {:ok, %{width: width, height: height, rgba: unfilter(raw, height, stride)}}
        end
      rescue
        e -> {:error, {:decode_failed, Exception.message(e)}}
      catch
        kind, reason -> {:error, {:decode_failed, {kind, reason}}}
      end
    end
  end

  def decode(_), do: {:error, :not_a_png}

  @doc "One channel (0 = R, 1 = G, 2 = B, 3 = A) of a decoded image as a `width * height` byte binary."
  @spec channel(t(), 0..3) :: binary()
  def channel(%{rgba: rgba}, 0), do: for(<<v, _, _, _ <- rgba>>, into: <<>>, do: <<v>>)
  def channel(%{rgba: rgba}, 1), do: for(<<_, v, _, _ <- rgba>>, into: <<>>, do: <<v>>)
  def channel(%{rgba: rgba}, 2), do: for(<<_, _, v, _ <- rgba>>, into: <<>>, do: <<v>>)
  def channel(%{rgba: rgba}, 3), do: for(<<_, _, _, v <- rgba>>, into: <<>>, do: <<v>>)

  # -- chunk / header parsing -------------------------------------------------------------

  defp read_chunks(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp read_chunks(
         <<len::32, type::binary-size(4), data::binary-size(len), _crc::32, rest::binary>>,
         acc
       ) do
    read_chunks(rest, [{type, data} | acc])
  end

  defp read_chunks(_, _), do: {:error, :truncated_png}

  defp header(chunks) do
    case List.keyfind(chunks, "IHDR", 0) do
      {"IHDR", <<w::32, h::32, 8, 6, 0, 0, 0>>} ->
        {:ok, w, h}

      {"IHDR", <<_::64, depth, type, _::binary>>} ->
        {:error, {:unsupported_png, bit_depth: depth, colour_type: type}}

      _ ->
        {:error, :missing_ihdr}
    end
  end

  # -- scanline unfiltering (4 bytes per pixel) ---------------------------------------------

  defp unfilter(raw, height, stride) do
    zero_row = :binary.copy(<<0>>, stride)
    rows(stride, raw, height, zero_row, [])
  end

  defp rows(_stride, _raw, 0, _prev, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp rows(stride, <<type, data::binary>>, n, prev, acc) do
    row = binary_part(data, 0, stride)
    rest = binary_part(data, stride, byte_size(data) - stride)
    cur = row(type, row, prev)
    rows(stride, rest, n - 1, cur, [cur | acc])
  end

  defp row(0, row, _prev), do: row
  defp row(1, row, _prev), do: sub(row, 0, 0, 0, 0, [])
  defp row(2, row, prev), do: up(row, prev, [])
  defp row(3, row, prev), do: avg(row, prev, 0, 0, 0, 0, [])
  defp row(4, row, prev), do: paeth(row, prev, 0, 0, 0, 0, 0, 0, 0, 0, [])

  defp sub(<<r, g, b, a, rest::binary>>, lr, lg, lb, la, acc) do
    r = band(r + lr, 255)
    g = band(g + lg, 255)
    b = band(b + lb, 255)
    a = band(a + la, 255)
    sub(rest, r, g, b, a, [<<r, g, b, a>> | acc])
  end

  defp sub(<<>>, _, _, _, _, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp up(<<x, row::binary>>, <<u, prev::binary>>, acc),
    do: up(row, prev, [band(x + u, 255) | acc])

  defp up(<<>>, <<>>, acc), do: acc |> Enum.reverse() |> :erlang.list_to_binary()

  defp avg(<<r, g, b, a, rest::binary>>, <<ur, ug, ub, ua, prev::binary>>, lr, lg, lb, la, acc) do
    r = band(r + ((lr + ur) >>> 1), 255)
    g = band(g + ((lg + ug) >>> 1), 255)
    b = band(b + ((lb + ub) >>> 1), 255)
    a = band(a + ((la + ua) >>> 1), 255)
    avg(rest, prev, r, g, b, a, [<<r, g, b, a>> | acc])
  end

  defp avg(<<>>, <<>>, _, _, _, _, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp paeth(
         <<r, g, b, a, rest::binary>>,
         <<ur, ug, ub, ua, prev::binary>>,
         lr,
         lg,
         lb,
         la,
         ulr,
         ulg,
         ulb,
         ula,
         acc
       ) do
    r = band(r + paeth_predictor(lr, ur, ulr), 255)
    g = band(g + paeth_predictor(lg, ug, ulg), 255)
    b = band(b + paeth_predictor(lb, ub, ulb), 255)
    a = band(a + paeth_predictor(la, ua, ula), 255)
    paeth(rest, prev, r, g, b, a, ur, ug, ub, ua, [<<r, g, b, a>> | acc])
  end

  defp paeth(<<>>, <<>>, _, _, _, _, _, _, _, _, acc),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp paeth_predictor(a, b, c) do
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)

    cond do
      pa <= pb and pa <= pc -> a
      pb <= pc -> b
      true -> c
    end
  end
end
