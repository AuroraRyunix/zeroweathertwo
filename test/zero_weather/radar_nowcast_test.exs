defmodule ZeroWeather.RadarNowcastTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias ZeroWeather.{Cache, Png, RadarColors, RadarGrid, RadarNowcast}

  # -- helpers ---------------------------------------------------------------------------------

  # PNG encoder for tests: RGBA 8-bit, every scanline filtered with the given filter type (0-4)
  defp encode_png(width, height, rgba, filter) do
    stride = width * 4

    rows =
      for y <- 0..(height - 1) do
        row = binary_part(rgba, y * stride, stride)

        prev =
          if y == 0,
            do: :binary.copy(<<0>>, stride),
            else: binary_part(rgba, (y - 1) * stride, stride)

        <<filter>> <> apply_filter(filter, row, prev)
      end

    <<137, 80, 78, 71, 13, 10, 26, 10>> <>
      chunk("IHDR", <<width::32, height::32, 8, 6, 0, 0, 0>>) <>
      chunk("IDAT", :zlib.compress(IO.iodata_to_binary(rows))) <> chunk("IEND", <<>>)
  end

  defp chunk(type, data),
    do: <<byte_size(data)::32>> <> type <> data <> <<:erlang.crc32(type <> data)::32>>

  defp apply_filter(0, row, _prev), do: row

  defp apply_filter(type, row, prev) do
    bytes = :binary.bin_to_list(row)
    prevs = :binary.bin_to_list(prev)

    bytes
    |> Enum.with_index()
    |> Enum.map(fn {x, i} ->
      a = if i >= 4, do: Enum.at(bytes, i - 4), else: 0
      b = Enum.at(prevs, i)
      c = if i >= 4, do: Enum.at(prevs, i - 4), else: 0

      predictor =
        case type do
          1 -> a
          2 -> b
          3 -> (a + b) >>> 1
          4 -> paeth(a, b, c)
        end

      band(x - predictor, 255)
    end)
    |> :erlang.list_to_binary()
  end

  defp paeth(a, b, c) do
    p = a + b - c
    {pa, pb, pc} = {abs(p - a), abs(p - b), abs(p - c)}

    cond do
      pa <= pb and pa <= pc -> a
      pb <= pc -> b
      true -> c
    end
  end

  # window grid from a function (x, y) -> mm/h; the point sits at the window centre
  defp grid(n, fun) do
    rows = for y <- 0..(n - 1), do: List.to_tuple(for x <- 0..(n - 1), do: fun.(x, y) * 1.0)
    %{n: n, cx: n / 2, cy: n / 2, cell_km: 1.5, lat: 51.05, lon: 3.72, rows: List.to_tuple(rows)}
  end

  # a round shower of `radius` cells and 2 mm/h around (bx, by)
  defp blob(bx, by, radius \\ 3) do
    fn x, y ->
      if (x + 0.5 - bx) ** 2 + (y + 0.5 - by) ** 2 <= radius * radius, do: 2.0, else: 0.0
    end
  end

  # -- PNG ---------------------------------------------------------------------------------------

  describe "ZeroWeather.Png" do
    test "decodes every scanline filter type back to the original pixels" do
      width = 7
      height = 5

      rgba =
        for i <- 0..(width * height * 4 - 1),
            into: <<>>,
            do: <<rem(i * 37 + div(i, 5) * 11, 256)>>

      for filter <- 0..4 do
        assert {:ok, %{width: ^width, height: ^height, rgba: ^rgba}} =
                 Png.decode(encode_png(width, height, rgba, filter))
      end
    end

    test "rejects non-PNG data and unsupported formats" do
      assert {:error, :not_a_png} = Png.decode("not a png")

      gray =
        <<137, 80, 78, 71, 13, 10, 26, 10>> <>
          chunk("IHDR", <<1::32, 1::32, 8, 0, 0, 0, 0>>) <> chunk("IEND", <<>>)

      assert {:error, {:unsupported_png, _}} = Png.decode(gray)
    end

    test "channel/2 extracts one channel" do
      rgba = <<1, 2, 3, 4, 5, 6, 7, 8>>
      {:ok, img} = Png.decode(encode_png(2, 1, rgba, 0))
      assert Png.channel(img, 0) == <<1, 5>>
      assert Png.channel(img, 3) == <<4, 8>>
    end
  end

  # -- colours / grid --------------------------------------------------------------------------------

  describe "RadarColors" do
    test "maps RainViewer palette pixels to dBZ and rain rate" do
      # from RainViewer's published Universal Blue table
      assert RadarColors.dbz(<<127, 191, 255, 255>>) == 20
      assert RadarColors.dbz(<<63, 127, 255, 255>>) == 35
      assert RadarColors.dbz(<<0, 0, 0, 0>>) == nil
      assert RadarColors.dbz(<<1, 2, 3, 255>>) == nil

      # Marshall-Palmer: 20 dBZ is about 0.65 mm/h, 35 dBZ about 5.6 mm/h
      assert_in_delta RadarColors.rate(<<127, 191, 255, 255>>), 0.65, 0.02
      assert_in_delta RadarColors.rate(<<63, 127, 255, 255>>), 5.6, 0.2
      assert RadarColors.rate(<<0, 0, 0, 0>>) == 0.0
    end
  end

  describe "RadarGrid" do
    test "geometry: Ghent is in zoom-7 tile 65/42 and cells are about 0.77 km" do
      {px, py} = RadarGrid.world_px(51.0543, 3.7174)
      assert {trunc(px / 512), trunc(py / 512)} == {65, 42}
      assert_in_delta RadarGrid.cell_km(51.05), 0.77, 0.02
    end

    test "downsample averages pixel rain rates into cells (units of 0.01 mm/h)" do
      echo = <<127, 191, 255, 255>>
      none = <<0, 0, 0, 0>>

      # top-left 2x2 pixels (= cell 0,0) fully raining, the cell next to it half raining (left column of its 2x2 block)
      rgba =
        for y <- 0..511, x <- 0..511, into: <<>> do
          cond do
            y < 2 and x < 2 -> echo
            y < 2 and x == 2 -> echo
            true -> none
          end
        end

      cells = RadarGrid.downsample(%{width: 512, height: 512, rgba: rgba})
      <<c00::16, c10::16, _::binary>> = cells
      assert byte_size(cells) == 256 * 256 * 2
      assert_in_delta c00, 65, 2
      assert_in_delta c10, 32, 2
    end

    test "coarsen averages 2x2 cells and doubles the cell size" do
      rows =
        for y <- 0..4,
            do: List.to_tuple(for x <- 0..4, do: if(x < 2 and y < 2, do: 4.0, else: 0.0))

      grid = %{
        n: 5,
        cx: 2.5,
        cy: 2.5,
        cell_km: 0.75,
        lat: 51.0,
        lon: 3.0,
        rows: List.to_tuple(rows)
      }

      c = RadarGrid.coarsen(grid)
      assert c.n == 2 and c.cell_km == 1.5 and c.cx == 1.25
      assert RadarGrid.cell(c, 0, 0) == 4.0
      assert RadarGrid.cell(c, 1, 0) == 0.0
    end

    test "window assembles cached tiles and locate/sample find the point again" do
      lat = 51.0543
      lon = 3.7174
      host = "https://example.invalid"
      path = "/v2/radar/test-window"
      # one cell with 3.0 mm/h at tile 65/42, cell (30, 60); every other tile cell is dry
      {px, py} = RadarGrid.world_px(lat, lon)
      cell_x = trunc(px / 2) - 65 * 256
      cell_y = trunc(py / 2) - 42 * 256
      dry = :binary.copy(<<0, 0>>, 256 * 256)
      offset = (cell_y * 256 + cell_x) * 2

      wet =
        binary_part(dry, 0, offset) <>
          <<300::16>> <> binary_part(dry, offset + 2, byte_size(dry) - offset - 2)

      for tx <- 64..66, ty <- 41..43 do
        Cache.put(
          {:radar_tile, path, 7, tx, ty},
          if({tx, ty} == {65, 42}, do: wet, else: dry),
          60
        )
      end

      assert {:ok, grid} = RadarGrid.window(host, path, lat, lon, 20)
      assert grid.n == 41
      {x, y} = RadarGrid.locate(grid, lat, lon)
      assert_in_delta x, grid.cx, 1.0e-9
      assert RadarGrid.cell(grid, floor(x), floor(y)) == 3.0
      assert RadarGrid.cell(grid, 0, 0) == 0.0
      assert RadarGrid.cell(grid, -1, 0) == 0.0
    end
  end

  # -- motion + advection ----------------------------------------------------------------------------------

  describe "motion estimation" do
    test "recovers a shower moving east at 2 cells per frame" do
      older = grid(81, blob(25, 40, 6))
      newer = grid(81, blob(27, 40, 6))
      assert {:ok, motion} = RadarNowcast.estimate_motion(newer, older)
      assert_in_delta motion.dx, 2.0, 0.3
      assert_in_delta motion.dy, 0.0, 0.3
      assert motion.quality > 0.9
    end

    test "recovers diagonal motion (south-east, 3 cells east and 1 cell south)" do
      older = grid(81, blob(25, 35, 6))
      newer = grid(81, blob(28, 36, 6))
      assert {:ok, motion} = RadarNowcast.estimate_motion(newer, older)
      assert_in_delta motion.dx, 3.0, 0.4
      assert_in_delta motion.dy, 1.0, 0.4
    end

    test "reports when there is no rain to track" do
      assert {:error, :not_enough_rain} =
               RadarNowcast.estimate_motion(
                 grid(81, fn _, _ -> 0.0 end),
                 grid(81, fn _, _ -> 0.0 end)
               )
    end

    test "motion chain falls back safely without rain" do
      dry = grid(81, fn _, _ -> 0.0 end)

      assert %{dx: +0.0, dy: +0.0, quality: +0.0, reason: :not_enough_rain} =
               RadarNowcast.estimate_motion_chain([dry, dry, dry])
    end
  end

  describe "advection forecast" do
    @frame_time 1_800_000_000

    defp model(newest_blob, motion),
      do: %{
        grid: grid(121, newest_blob),
        frame_time: @frame_time,
        motion: motion,
        lat: 51.05,
        lon: 3.72
      }

    test "a shower 30 cells upwind moving east at 2 cells/frame reaches the point after about 150 minutes" do
      # too far for the 2-hour horizon: stays dry
      fc =
        RadarNowcast.forecast(
          model(blob(30, 60.5), %{dx: 2.0, dy: 0.0, quality: 0.9}),
          DateTime.from_unix!(@frame_time)
        )

      assert fc.summary.state == :dry
    end

    test "a shower 12 cells upwind arrives after roughly an hour and the summary counts down to it" do
      # 0.2 cells/min: the centre (12.5 cells away) is over the point after ~62 min, the edge (3 cells) after ~47;
      # the growing smoothing disk (0.8 + lead/30 cells) sees it a bit earlier
      fc =
        RadarNowcast.forecast(
          model(blob(48, 60.5), %{dx: 2.0, dy: 0.0, quality: 0.9}),
          DateTime.from_unix!(@frame_time)
        )

      assert fc.summary.state == :rain_soon

      # "likely" needs half of the (growing) smoothing disk to be wet, so it starts after the first edge (~47 min)
      assert fc.summary.starts_in_min in 45..62
      # ...but a real chance is mentioned earlier instead of claiming it stays dry until then
      assert fc.summary.detail =~ "(a chance from"
      assert fc.summary.headline =~ "Dry for the next"
      assert fc.motion.known
      assert fc.motion.from == "W"
      assert_in_delta fc.motion.speed_km_h, 1.5 * 2 * 6, 0.2
    end

    test "rain already over the point is reported as raining now and easing" do
      fc =
        RadarNowcast.forecast(
          model(blob(60.5, 60.5), %{dx: 2.0, dy: 0.0, quality: 0.9}),
          DateTime.from_unix!(@frame_time)
        )

      assert fc.summary.state == :raining
      assert fc.summary.headline =~ "Raining now"

      # the 3-cell shower drifts off at 0.2 cells/min: the point leaves it after ~15 min, the smoothing disk after ~23
      assert fc.summary.ends_in_min in 15..30
    end

    test "without a trustworthy motion the rain stays where it is (persistence)" do
      fc =
        RadarNowcast.forecast(
          model(blob(60.5, 60.5), %{dx: 0.0, dy: 0.0, quality: 0.0, reason: :not_enough_rain}),
          DateTime.from_unix!(@frame_time)
        )

      assert fc.motion.known == false
      assert fc.summary.state == :raining

      # persistence is only ~55% reliable after an hour, so the confident "raining" ends in the second hour
      assert fc.summary.ends_in_min in 55..95
      assert fc.summary.detail =~ "Rain likely easing around"
    end

    test "the forecast is shorter for fast rain so it never looks beyond the window" do
      fast = model(blob(60.5, 60.5), %{dx: 12.0, dy: 0.0, quality: 0.9})
      fc = RadarNowcast.forecast(fast, DateTime.from_unix!(@frame_time))
      assert length(fc.series) < 120
      assert length(fc.series) >= 1
    end

    test "series entries carry the time, rate and chance and the result is JSON-safe" do
      fc =
        RadarNowcast.forecast(
          model(blob(48, 60.5), %{dx: 2.0, dy: 0.0, quality: 0.9}),
          DateTime.from_unix!(@frame_time)
        )

      assert %{time: <<_::binary-size(5)>>, mm_h: mm_h, chance: chance} = hd(fc.series)
      assert is_float(mm_h) and chance in 0..100
      assert %{"method" => "radar-advection"} = fc |> Jason.encode!() |> Jason.decode!()
    end
  end

  describe "calibrated chance" do
    test "is bounded, monotonic in the raw share and less confident further ahead" do
      for tau <- [10, 30, 55, 90, 120] do
        values = for raw <- 0..100//10, do: RadarNowcast.calibrate(raw, tau)
        assert values == Enum.sort(values)
        assert Enum.all?(values, &(&1 >= 0 and &1 <= 100))
      end

      assert RadarNowcast.calibrate(150, 10) == RadarNowcast.calibrate(100, 10)
      assert RadarNowcast.calibrate(-5, 10) == RadarNowcast.calibrate(0, 10)

      sure = for tau <- [10, 35, 55, 100], do: RadarNowcast.calibrate(100, tau)
      assert sure == Enum.sort(sure, :desc)

      # reality check from the replay: a raw 100% is ~98% right at +10 min, but only ~55% at +55 min
      assert_in_delta RadarNowcast.calibrate(100, 10), 98, 1
      assert_in_delta RadarNowcast.calibrate(100, 55), 55, 1
    end

    test "rain that only arrives late in the forecast is reported as possible, not certain" do
      # 20 cells upwind at 0.2 cells/min: the shower core reaches the point after ~100 minutes
      fc =
        RadarNowcast.forecast(
          model(blob(40.5, 60.5), %{dx: 2.0, dy: 0.0, quality: 0.9}),
          DateTime.from_unix!(@frame_time)
        )

      assert fc.summary.state == :rain_possible
      assert fc.summary.headline =~ "Dry for the next"
      assert fc.summary.detail =~ "Rain possible from"
      assert fc.summary.chance_pct in 25..49
    end

    test "series points report the rate where it rains, the calibrated chance and the raw share" do
      fc =
        RadarNowcast.forecast(
          model(blob(60.5, 60.5), %{dx: 0.0, dy: 0.0, quality: 0.0}),
          DateTime.from_unix!(@frame_time)
        )

      assert %{mm_h: rate, mean_mm_h: mean, chance: chance, chance_raw: raw} = hd(fc.series)
      assert rate >= 1.5 and mean <= rate
      assert raw == 100 and chance in 90..100
    end
  end
end
