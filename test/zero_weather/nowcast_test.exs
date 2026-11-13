defmodule ZeroWeather.NowcastTest do
  use ExUnit.Case, async: true

  alias ZeroWeather.Nowcast

  # 24 slots of 5 minutes starting at 14:05 (like the real feed), `overrides` maps "HH:MM" => raw value.
  defp feed(overrides \\ %{}, start_minutes \\ 14 * 60 + 5) do
    Enum.map_join(0..23, "\n", fn i ->
      minutes = start_minutes + i * 5
      clock = clock(rem(div(minutes, 60), 24), rem(minutes, 60))
      raw = Map.get(overrides, clock, 0)
      String.pad_leading(Integer.to_string(raw), 3, "0") <> "|" <> clock
    end)
  end

  defp clock(h, m) do
    String.pad_leading(Integer.to_string(h), 2, "0") <>
      ":" <> String.pad_leading(Integer.to_string(m), 2, "0")
  end

  defp build(body, now) do
    {:ok, slots} = Nowcast.parse(body)
    Nowcast.build(slots, now, now)
  end

  # 13:02:30 UTC is 14:02:30 on the Belgian winter clock
  @now ~U[2026-11-13 13:02:30Z]

  describe "parse/1 and raw_to_mm_h/1" do
    test "parses the 24 slots of the feed" do
      assert {:ok, slots} = Nowcast.parse(feed(%{"14:50" => 87, "14:55" => 77}))
      assert length(slots) == 24
      assert hd(slots).time == "14:05"
      assert List.last(slots).time == "16:00"
    end

    test "ignores malformed lines, accepts CRLF, rejects an empty feed" do
      assert {:ok, [slot]} = Nowcast.parse("garbage\r\n087|14:50\r\n12|99:99\r\nabc|14:55\r\n")
      assert slot.time == "14:50"
      assert {:error, :empty_feed} = Nowcast.parse("")
      assert {:error, :empty_feed} = Nowcast.parse("<html>not the feed</html>")
    end

    test "converts raw values to mm/h with 10^((raw-109)/32)" do
      assert Nowcast.raw_to_mm_h(0) == 0.0
      assert_in_delta Nowcast.raw_to_mm_h(77), 0.1, 1.0e-9
      assert_in_delta Nowcast.raw_to_mm_h(87), 0.2054, 1.0e-4
      assert_in_delta Nowcast.raw_to_mm_h(109), 1.0, 1.0e-9
    end
  end

  describe "local clock handling" do
    test "winter is UTC+1, summer UTC+2, with the switch on the last Sunday at 01:00 UTC" do
      assert Nowcast.local_offset_minutes(~U[2026-11-13 12:00:00Z]) == 60
      assert Nowcast.local_offset_minutes(~U[2026-07-01 12:00:00Z]) == 120
      assert Nowcast.local_offset_minutes(~U[2026-03-29 00:59:59Z]) == 60
      assert Nowcast.local_offset_minutes(~U[2026-03-29 01:00:00Z]) == 120
      assert Nowcast.local_offset_minutes(~U[2026-10-25 00:59:59Z]) == 120
      assert Nowcast.local_offset_minutes(~U[2026-10-25 01:00:00Z]) == 60
    end

    test "anchors the first slot to an instant in winter and summer" do
      {:ok, slots} = Nowcast.parse(feed())
      assert hd(Nowcast.anchor_slots(slots, @now)).at == ~U[2026-11-13 13:05:00Z]

      assert hd(Nowcast.anchor_slots(slots, ~U[2026-07-01 12:02:30Z])).at ==
               ~U[2026-07-01 12:05:00Z]
    end

    test "rolls over midnight" do
      # local 23:58 on Nov 13; the feed's first slot is already 00:00 of the next day
      {:ok, slots} = Nowcast.parse("000|00:00\n000|00:05")
      [a, b] = Nowcast.anchor_slots(slots, ~U[2026-11-13 22:58:00Z])
      assert a.at == ~U[2026-11-13 23:00:00Z]
      assert b.at == ~U[2026-11-13 23:05:00Z]

      # clock wraps inside the feed
      {:ok, slots} = Nowcast.parse("000|23:55\n000|00:00")
      [a, b] = Nowcast.anchor_slots(slots, ~U[2026-11-13 22:50:00Z])
      assert a.at == ~U[2026-11-13 22:55:00Z]
      assert b.at == ~U[2026-11-13 23:00:00Z]
    end
  end

  describe "1-minute series" do
    test "starts at the current minute and interpolates linearly between the 5-minute slots" do
      result = build(feed(%{"14:50" => 87, "14:55" => 77}), @now)
      series = result.series
      by_time = Map.new(series, &{&1.time, &1.mm_h})

      assert hd(series).time == "14:02"
      assert hd(series).mm_h == 0.0
      # the series ends at the last slot (16:00) and never exceeds the 2 hour horizon
      assert List.last(series).time == "16:00"
      assert length(series) == 119

      assert_in_delta by_time["14:45"], 0.0, 1.0e-9
      assert_in_delta by_time["14:48"], 0.123, 0.001
      assert_in_delta by_time["14:50"], 0.205, 0.001
      assert_in_delta by_time["14:55"], 0.1, 0.001
      assert_in_delta by_time["14:58"], 0.04, 0.001
    end

    test "is empty when the data is older than the whole feed" do
      result = build(feed(), ~U[2026-11-13 20:00:00Z])
      assert result.series == []
      assert result.summary.state == :unknown
    end
  end

  describe "summary" do
    test "dry now, rain coming: countdown, start, duration and peak" do
      summary = build(feed(%{"14:50" => 87, "14:55" => 77}), @now).summary

      assert summary.state == :rain_soon
      assert summary.headline == "Dry for the next 46 minutes."
      assert summary.detail == "Rain starting at 14:48, lasting 8 minutes, peak 0.2 mm/h."
      assert summary.starts_in_min == 46
      assert summary.starts_at == "14:48"
      assert summary.duration_min == 8
      assert summary.peak_at == "14:50"
      assert summary.peak_mm_h == 0.2
      refute summary.lasts_beyond_horizon
    end

    test "the countdown moves with the clock (1-minute resolution)" do
      body = feed(%{"14:50" => 87, "14:55" => 77})
      later = build(body, ~U[2026-11-13 13:03:30Z]).summary
      assert later.starts_in_min == 45
      assert later.headline == "Dry for the next 45 minutes."
    end

    test "singular minute" do
      # 14:05 is dry, the ramp to 0.5 mm/h at 14:10 first reaches 0.1 mm/h at 14:06
      summary = build(feed(%{"14:10" => 100}), ~U[2026-11-13 13:05:30Z]).summary
      assert summary.state == :rain_soon
      assert summary.starts_at == "14:06"
      assert summary.starts_in_min == 1
      assert summary.headline == "Dry for the next minute."
    end

    test "dry for the whole feed" do
      summary = build(feed(), @now).summary
      assert summary.state == :dry
      assert summary.headline == "Dry for the next 2 hours."
      assert summary.detail == nil
    end

    test "raining now and easing off" do
      body = feed(%{"14:05" => 100, "14:10" => 100, "14:15" => 100})
      summary = build(body, ~U[2026-11-13 13:07:00Z]).summary

      assert summary.state == :raining
      assert summary.headline == "Raining now (0.5 mm/h)."
      assert summary.ends_at == "14:20"
      assert summary.ends_in_min == 13
      assert summary.peak_mm_h == 0.5
      assert summary.detail =~ "Easing below 0.1 mm/h at 14:20 (in 13 minutes)"
    end

    test "rain that never ends within the feed" do
      body =
        feed(
          Map.new(0..23, fn i ->
            {clock(rem(div(14 * 60 + 5 + i * 5, 60), 24), rem(14 * 60 + 5 + i * 5, 60)), 100}
          end)
        )

      summary = build(body, @now).summary

      assert summary.state == :raining
      assert summary.ends_in_min == nil
      assert summary.detail == "Rain continuing for the next 2 hours, peak 0.5 mm/h."
    end

    test "rain that starts and lasts beyond the feed horizon" do
      body = feed(%{"15:50" => 100, "15:55" => 100, "16:00" => 100})
      summary = build(body, @now).summary

      assert summary.state == :rain_soon
      assert summary.lasts_beyond_horizon
      assert summary.detail =~ "lasting "
      assert summary.detail =~ "+ minutes"
    end
  end

  test "build/3 output can be encoded as JSON (it is returned by the API)" do
    result = build(feed(%{"14:50" => 87}), @now)

    assert %{"source" => "Buienradar", "summary" => %{"state" => "rain_soon"}} =
             result |> Jason.encode!() |> Jason.decode!()
  end
end
