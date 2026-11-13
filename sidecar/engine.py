"""STEPS ensemble nowcast of a radar window, reduced to numbers at one point.

Input: the last few radar fields (mm/h, oldest first, one every `step_min` minutes) on a flat grid of `cell_km` cells.
Steps: dB transform, Lucas-Kanade optical flow (a spatially varying motion field), then pysteps' STEPS: a cascade
decomposition of the field with an autoregressive model per scale (so small scales decay faster than large ones and
rain intensity evolves), stochastic noise that keeps the small-scale structure, perturbed motion, and `members`
equally likely futures. Probabilities at the point are the share of members (and of cells in a small disk) that rain.
"""
import contextlib
import io
import time
import numpy as np

THR = 0.1  # mm/h, a cell counts as raining at or above this
DB_ZERO = -15.0
DB_THR = 10.0 * np.log10(THR)


def to_db(r):
    out = np.full(r.shape, DB_ZERO, dtype="float64")
    wet = r >= THR
    out[wet] = 10.0 * np.log10(r[wet])
    return out


def from_db(db):
    rain = 10.0 ** (db / 10.0)
    rain[db < DB_THR - 1e-6] = 0.0
    return rain


def disk_mask(radius_cells):
    r = int(np.ceil(radius_cells))
    yy, xx = np.mgrid[-r : r + 1, -r : r + 1]
    return yy, xx, (yy * yy + xx * xx) <= radius_cells * radius_cells + 1e-9


def run(frames, cell_km, step_min, n_leads, members, seed, cx, cy, smooth_base_km=1.2, smooth_per_min_km=0.05):
    from pysteps import motion, nowcasts

    t0 = time.time()
    r = np.nan_to_num(frames.astype("float64"), nan=0.0)
    r[r < THR] = 0.0
    db = np.stack([to_db(f) for f in r])

    flow = motion.get_method("LK")(db)
    t_motion = time.time() - t0

    steps = nowcasts.get_method("steps")
    with contextlib.redirect_stdout(io.StringIO()):
        fc = steps(
            db[-3:],
            flow,
            n_leads,
            n_ens_members=members,
            n_cascade_levels=6,
            precip_thr=DB_THR,
            kmperpixel=cell_km,
            timestep=step_min,
            noise_method="nonparametric",
            vel_pert_method="bps",
            mask_method="incremental",
            seed=seed,
            num_workers=1,
            fft_method="numpy",
            return_output=True,
        )
    fc = from_db_all(np.nan_to_num(fc, nan=DB_ZERO))  # (members, leads, H, W) mm/h
    t_total = time.time() - t0

    ix, iy = int(round(cx - 0.5)), int(round(cy - 0.5))
    h, w = fc.shape[2], fc.shape[3]
    out = []
    for k in range(n_leads):
        lead = (k + 1) * step_min
        radius = (smooth_base_km + smooth_per_min_km * lead) / cell_km
        yy, xx, m = disk_mask(radius)
        ys = np.clip(iy + yy[m], 0, h - 1)
        xs = np.clip(ix + xx[m], 0, w - 1)
        pt = fc[:, k, iy, ix]
        near = fc[:, k][:, ys, xs]  # (members, cells in disk)
        wet_near = near >= THR
        out.append(
            {
                "lead_min": lead,
                "p_point": float((pt >= THR).mean()),
                "p_disk": float(wet_near.mean()),
                "p_member_any": float(wet_near.any(axis=1).mean()),
                "mean_mm_h": float(near.mean()),
                "rate_if_rain_mm_h": float(near[wet_near].mean()) if wet_near.any() else 0.0,
                "p90_mm_h": float(np.percentile(near.max(axis=1), 90)),
                "radius_km": round(float(radius * cell_km), 2),
            }
        )

    # mean flow near the point, in km/h (x east, y south)
    fx = float(np.nanmean(flow[0, max(iy - 20, 0) : iy + 20, max(ix - 20, 0) : ix + 20]))
    fy = float(np.nanmean(flow[1, max(iy - 20, 0) : iy + 20, max(ix - 20, 0) : ix + 20]))
    k_h = cell_km * 60.0 / step_min
    return {
        "leads": out,
        "motion": {"east_km_h": fx * k_h, "south_km_h": fy * k_h},
        "members": members,
        "seconds": {"motion": round(t_motion, 2), "total": round(t_total, 2)},
    }


def from_db_all(fc):
    return np.stack([np.stack([from_db(f) for f in m]) for m in fc])
