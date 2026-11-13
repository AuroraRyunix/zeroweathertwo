"""Tiny HTTP front for engine.run: POST /nowcast?n=..&k=..&cell_km=..&step_min=..&leads=..&members=..&cx=..&cy=..&seed=..
with the k frames (oldest first) as little-endian float32 in the body. GET /health."""
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import numpy as np

import engine

LOCK = threading.Lock()  # one ensemble at a time: the container has a small CPU share


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if urlparse(self.path).path == "/health":
            self._send(200, {"ok": True})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        u = urlparse(self.path)
        if u.path != "/nowcast":
            return self._send(404, {"error": "not found"})
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        try:
            n, k = int(q["n"]), int(q["k"])
            length = int(self.headers.get("content-length", 0))
            raw = self.rfile.read(length)
            if len(raw) != 4 * n * n * k:
                return self._send(400, {"error": "body size does not match n and k"})
            frames = np.frombuffer(raw, dtype="<f4").reshape(k, n, n)
            with LOCK:
                res = engine.run(
                    frames,
                    float(q["cell_km"]),
                    int(q.get("step_min", 5)),
                    int(q.get("leads", 24)),
                    int(q.get("members", 24)),
                    int(q.get("seed", 1)),
                    float(q["cx"]),
                    float(q["cy"]),
                )
            self._send(200, res)
        except Exception as e:  # report, never crash the server
            self._send(500, {"error": f"{type(e).__name__}: {e}"})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 8090), Handler).serve_forever()
