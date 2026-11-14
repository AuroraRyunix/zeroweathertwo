defmodule ZeroWeather.VerifierTest do
  use ExUnit.Case, async: true

  alias ZeroWeather.Verifier

  defp entry(chance, raw, persist, lead),
    do: %{chance: chance, raw: raw, persist: persist, lead: lead, lat: 51.0, lon: 3.7}

  test "Brier scores, climatology and reliability from scored outcomes" do
    band = Verifier.band_of(15)
    assert band == {10, 20}

    # four outcomes: two forecast at 90% (one rained), two at 10% (none rained)
    stats =
      [
        {entry(90, 100, true, 15), true},
        {entry(90, 100, true, 15), false},
        {entry(10, 0, false, 15), false},
        {entry(10, 0, false, 15), false}
      ]
      |> Enum.reduce(%{}, fn {e, obs}, acc -> Verifier.add(acc, band, e, obs) end)

    state = %{
      started_at: "t",
      origins: 1,
      points: ["X"],
      last_seen: nil,
      last_error: nil,
      pending: %{},
      stats: stats
    }

    report = Verifier.report(state)
    b = Enum.find(report.bands, &(&1.lead == "10-20"))

    assert b.n == 4
    assert b.wet_pct == 25.0
    # (0.1² + 0.9² + 0.1² + 0.1²) / 4
    assert b.brier_calibrated == 0.21
    # persistence: rain forecast twice (1 hit, 1 miss), dry twice: (0 + 1 + 0 + 0) / 4
    assert b.brier_persistence == 0.25
    assert b.brier_climatology == 0.1875
    assert Enum.find(b.reliability, &(&1.bin == "90-100")).observed_pct == 50.0
    assert report.scored == 4
  end

  test "snapshot is nil when the verifier is not running" do
    assert Verifier.snapshot() == nil
  end
end

defmodule ZeroWeather.IncaTest do
  use ExUnit.Case, async: true

  alias ZeroWeather.Inca

  # 4x4 raster of float32, 0.01 degree cells, top-left (3.0 E, 51.04 N): -1 everywhere except a wet 2x2 block
  defp raster do
    vals = for j <- 0..3, i <- 0..3, do: if(i in 1..2 and j in 1..2, do: 1.5, else: -1.0)
    data = for v <- vals, into: <<>>, do: <<v::float-32-little>>

    %{
      width: 4,
      height: 4,
      data: data,
      endian: :little,
      lon0: 3.0,
      lat0: 51.04,
      dlon: 0.01,
      dlat: 0.01
    }
  end

  test "-1 counts as dry; share is taken over the 3x3 cells around the point" do
    # cell (1,1): lon 3.015, lat 51.025
    %{point: p, share: s} = Inca.at(raster(), 51.025, 3.015)
    assert p == 1.5
    # 3x3 around (1,1) covers i 0..2, j 0..2: wet cells (1,1) (2,1) (1,2) (2,2) = 4 of 9
    assert_in_delta s, 4 / 9, 1.0e-9
    %{point: p2, share: s2} = Inca.at(raster(), 51.035, 3.005)
    assert p2 == 0.0
    assert s2 > 0.0 and s2 < 0.5
  end
end
