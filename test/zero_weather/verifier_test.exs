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
