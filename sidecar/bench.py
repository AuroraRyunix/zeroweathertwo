import json, sys, time
import numpy as np
from multiprocessing import Pool
sys.path.insert(0, "/Users/aurora/Projects/zeroweathertwo/sidecar")
import engine

meta = json.load(open("/tmp/zwscripts/fx/meta.json"))[::2]

def work(m):
    a = np.fromfile("/tmp/zwscripts/fx/" + m["file"], dtype="<f4").reshape(5, m["n"], m["n"])
    r = engine.run(a, 1.0, 5, 24, 20, 7, m["cx"], m["cy"])
    return {"point": m["point"], "origin": m["origin"], "truth": m["truth"], "now": float(m["truth"][0]) , "leads": r["leads"], "sec": r["seconds"]["total"]}

if __name__ == "__main__":
    t = time.time()
    with Pool(int(sys.argv[1]) if len(sys.argv) > 1 else 6) as p:
        out = p.map(work, meta, chunksize=2)
    json.dump(out, open("/tmp/zwscripts/steps_out.json", "w"))
    print("done", len(out), "cases in", round(time.time() - t), "s; mean per case", round(np.mean([o["sec"] for o in out]), 1))
