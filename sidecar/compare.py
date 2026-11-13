import json, numpy as np
steps = json.load(open("/tmp/zwscripts/steps_out.json"))
ex = {(r["point"], r["origin"], r["lead"]): r for r in json.load(open("/tmp/zwscripts/elixir_rows.json"))}
bands = [(5, 20), (25, 40), (45, 60), (65, 90), (95, 120)]
rows = []
for c in steps:
    for k, l in enumerate(c["leads"]):
        lead = l["lead_min"]
        e = ex.get((c["point"], c["origin"], lead))
        if e is None: continue
        y = 1.0 if c["truth"][k] >= 0.1 else 0.0
        rows.append(dict(lead=lead, y=y, e=e["chance"]/100, raw=e["raw"]/100, pers=1.0 if e["now_rain"] else 0.0,
                         sp=l["p_point"], sd=l["p_disk"], sa=l["p_member_any"]))
print(len(rows), "pairs, wet", int(sum(r["y"] for r in rows)))
def b(rs, f): return float(np.mean([(r[f]-r["y"])**2 for r in rs]))
print("lead      n  wet%  ours(cal) ours(raw) persist  steps(pt) steps(disk) steps(any) clim")
for lo, hi in bands:
    rs = [r for r in rows if lo <= r["lead"] <= hi]
    if not rs: continue
    base = np.mean([r["y"] for r in rs])
    print(f"{lo:3d}-{hi:<3d} {len(rs):5d} {base*100:5.1f}  {b(rs,'e'):.4f}    {b(rs,'raw'):.4f}   {b(rs,'pers'):.4f}   {b(rs,'sp'):.4f}    {b(rs,'sd'):.4f}     {b(rs,'sa'):.4f}    {base*(1-base):.4f}")
print("\nblend 50/50 of ours(cal) and steps(disk):")
for r in rows: r["bl"] = 0.5*r["e"] + 0.5*r["sd"]
for lo, hi in bands:
    rs = [r for r in rows if lo <= r["lead"] <= hi]
    print(f"{lo:3d}-{hi:<3d} ours {b(rs,'e'):.4f}  steps {b(rs,'sd'):.4f}  blend {b(rs,'bl'):.4f}")
