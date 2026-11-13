# STEPS ensemble experiment (not deployed)

`engine.py` runs pysteps' STEPS ensemble (Lucas-Kanade motion, cascade decomposition, autoregressive growth and decay,
noise, perturbed motion) on a 201 km window of RMI radar and reduces it to probabilities at one point;
`server.py` serves it over HTTP, `Dockerfile` packages it. `bench.py` and `compare.py` score it against the advection
nowcast on the same points, origins and leads (a replay of 13 November 2026 RMI frames, 80 cases, 1,920 pairs, 152 wet).

Brier score (lower is better), 20 members, no calibration of the ensemble:

| lead (min) | advection (calibrated) | STEPS | 50/50 blend |
|---|---|---|---|
| 5-20   | 0.0231 | 0.0228 | 0.0221 |
| 25-40  | 0.0287 | 0.0406 | 0.0324 |
| 45-60  | 0.0519 | 0.0523 | 0.0507 |
| 65-90  | 0.0620 | 0.0612 | 0.0604 |
| 95-120 | 0.0620 | 0.0596 | 0.0597 |

On this sample STEPS is no better than the calibrated advection forecast and costs about 10 s of CPU per point and a
container with roughly 1 GB, so it is not wired in. A blend gains 2 to 4% except around +30 min; with 152 wet outcomes
that is within noise. Worth re-running on a rainier day (heavier, growing showers are where STEPS should help).
Build notes: pysteps needs a C compiler; on macOS `-fopenmp` has to be removed from its `setup.py`.
