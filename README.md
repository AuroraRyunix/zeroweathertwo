# ⚡ ZeroWeather Belgium

A high-performance, real-time meteorological nowcasting and radar web application built for Belgium (with dedicated presets for **Ghent**, **Brussels**, Antwerp, Liège, Bruges, and arbitrary GPS coordinates).

Written in **100% Elixir & Phoenix LiveView**, running on **Bandit**, with an in-memory ETS cache and zero database dependencies. Ideal for lightweight deployment on **VMware vSphere** and **VMware Photon OS**.

---

## 🌟 Key Features

- **🌧️ Own Rain Nowcast with a Live Countdown (radar advection, 1-minute resolution):**
  - We compute the nowcast ourselves. Input is the Belgian radar rain-rate composite of the Royal Meteorological Institute (RMI), real float mm/h on a 1.3 km grid every 5 minutes, read from RMI's open-data WCS with a pure-Elixir GeoTIFF reader (`ZeroWeather.RmiRadar`, `ZeroWeather.GeoTiff`) and resampled to a 1 km grid around the point. RMI publishes in bursts (the newest frame was up to ~30 minutes old in a measurement), so when RainViewer has a frame more than 5 minutes newer, RainViewer is used instead: its tiles are decoded with a pure-Elixir PNG decoder and its published dBZ palette table, converted to rain rate (Marshall-Palmer) and averaged into ~0.75 km cells (`ZeroWeather.RadarGrid`).
  - The rain's **drift** is estimated by normalised cross-correlation between the newest frame and the previous ones (sub-cell refinement, two frame pairs combined); the newest frame is then **advected** along that drift to the chosen point, sampled once per minute over a disk that grows with lead time (`ZeroWeather.RadarNowcast`).
  - Live countdown that updates every minute: *"Dry for the next 46 minutes. Rain starting at 14:48, lasting 8 minutes, peak 0.2 mm/h."*, plus the estimated drift (*"Rain is drifting from the NW at 26 km/h"*).
  - Buienradar's finished 5-minute point forecast (`ZeroWeather.Nowcast`) is shown as a cross-check and is the instant fallback while the radar nowcast is computed, or if the radar tiles are unavailable.
  - Each minute carries a **calibrated chance of rain** (the raw share of the smoothing disk that is wet is overconfident further ahead; `RadarNowcast.calibrate/2`). Rain is called "likely" at 50% or more, "possible" at 25% or more.
  - Validation, replay of RMI's own radar (9,354 forecast/outcome pairs, 10 Belgian cities, one day of mostly light showers, 664 wet outcomes; Brier score, lower is better): 0.021 at +5..20 min, 0.043 at +45..60, 0.055 at +65..90 and 0.058 at +95..125, against 0.068 / 0.068 / 0.064 / 0.062 for always predicting the base rate. So there is real skill up to about an hour and little beyond it. The calibration tables were fitted earlier on RainViewer data and hold up on RMI's; a re-fit on one half and test on the other did not beat them reliably (better by ~5% at short leads, worse at 45-60 min), so they were kept. One day of weather is a small sample.
  - Not done yet: growth and decay of showers (intensity is held constant), rain-gauge correction of the radar and a dew-point (virga) correction. The nearest RMI ground station (Melle) is shown next to the forecast for reference (`ZeroWeather.Gauges`), but is not used to correct it.
  - Also returned by `GET /api/v1/nowcast` as `radar_nowcast` (own) and `buienradar_nowcast` (cross-check).
- **⏱️ 15-Minute Rain Nowcast Timeline:**
  - High-resolution precipitation forecasts in 15-minute intervals for the next 3 hours.
  - Custom SVG rain bar chart with intensity color coding (Light $<1$ mm/h, Moderate $1-4$ mm/h, Heavy $>4$ mm/h).
  - Rain probability tags and intelligent human-readable summary (*e.g., "Rain starting in ~15 min (peak ~2.4 mm/h at 11:30)"*).
- **📡 Real-Time Live Radar Composite:**
  - Doppler radar composite covering Belgium and cross-border approaches (Northern France, southern North Sea, Netherlands).
  - Timeline scrubber from **Past (-60m)** to **Live** to **Nowcast (+30m)**.
  - Interactive Leaflet.js animation with play/pause loop.
- **📍 Instant Presets & Browser Geolocation:**
  - Quick-switch pills for Ghent, Brussels, Antwerp, Bruges, Liège, Namur, Leuven, Hasselt, Mons, and Ostend.
  - **My GPS** button for one-click HTML5 geolocation anywhere in Belgium.
- **🍃 Live Air Quality & Atmospheric Metrics:**
  - European Air Quality Index (EAQI) + $\text{PM}_{2.5}$, $\text{PM}_{10}$, $\text{NO}_2$, and $\text{O}_3$ metrics.
  - Surface barometric pressure, elevation, wind speed & direction.
- **⚡ Sub-Millisecond In-Memory Caching:**
  - In-memory ETS cache (`ZeroWeather.Cache`) with rolling TTLs. No external Redis needed.
- **🚀 Pure Elixir Architecture:**
  - LiveView updates seamlessly over WebSockets.
  - No bloated client-side frameworks—pure server-rendered interactive UI.

---

## 🏗️ Architecture

```
                       [ Upstream Data Streams ]
                                  │
         ┌────────────────────────┼────────────────────────┐
         ▼                        ▼                        ▼
 [ RainViewer Radar ]     [ Open-Meteo / DWD ]     [ Copernicus EAQI ]
  (5-10m tiles + nowcast)  (15m rain & wind)       (PM2.5, PM10, NO2)
         │                        │                        │
         └────────────────────────┼────────────────────────┘
                                  │
                                  ▼
                   ┌──────────────────────────────┐
                   │   ZeroWeather.Cache (ETS)    │
                   │   Rolling in-memory buffer   │
                   └──────────────┬───────────────┘
                                  │
         ┌────────────────────────┴────────────────────────┐
         ▼                                                 ▼
 [ Phoenix LiveView ]                             [ REST API v1 ]
  • Reactive SVG rain chart                        • GET /api/v1/nowcast
  • Interactive Leaflet radar map                  • GET /api/v1/radar
  • Countdown refreshes every minute               • GET /api/v1/locations
```

---

## 🚀 Getting Started Locally

### Prerequisites
- Elixir 1.17+ and Erlang/OTP 27+

### Setup & Run
```bash
# 1. Clone the repository
git clone https://github.com/AuroraRyunix/zeroweathertwo.git
cd zeroweathertwo

# 2. Install dependencies & build assets
mix setup

# 3. Start the Phoenix server
mix phx.server
```

Open [http://localhost:4000](http://localhost:4000) in your browser.

---

## ☸️ Deploying on VMware Tanzu (TKG / Kubernetes)

Because ZeroWeather is completely stateless and has zero database dependencies, it is a perfect workload for Tanzu:

- **Resource footprint:** `50m` CPU / `64Mi` memory per replica.
- **High Availability:** 2 replicas scheduled across your vSphere worker nodes.
- **Probes:** Pre-configured liveness and readiness probes on `/api/v1/health`.
- **Automatic Builds:** Pushing to `main` triggers GitHub Actions to build and publish the image to GitHub Packages (`ghcr.io/auroraryunix/zeroweathertwo:latest`).

### Deploy to Tanzu:
```bash
# Switch to your Tanzu Guest Cluster context
kubectl apply -f k8s/zeroweather.yaml

# Watch the rollout
kubectl get pods -l app=zeroweather -w
```

---

## 🐳 Deploying with Docker / Photon OS

The project includes an ultra-lean multi-stage `Dockerfile` and `docker-compose.yml`:

```bash
# Build and run container
docker compose up -d

# Check health
curl http://localhost:4000/api/v1/health
```

The compiled release container consumes only **~40–50 MB of RAM** and requires no external database.

---

## 🔌 REST API Endpoints

### 1. Point Nowcast
```bash
GET /api/v1/nowcast?lat=51.0543&lon=3.7174
```
**Response:**
```json
{
  "lat": 51.0543,
  "lon": 3.7174,
  "elevation": 12.0,
  "current": {
    "temperature": 12.4,
    "humidity": 76,
    "precipitation": 0.0,
    "wind_speed": 18.2,
    "wind_direction": 220,
    "condition_text": "Partly cloudy",
    "condition_icon": "⛅"
  },
  "summary": "Dry: No rain expected in the next 3 hours.",
  "timeline": [
    { "time": "11:15", "precip_mm": 0.0, "probability": 0, "intensity_label": "dry" },
    { "time": "11:30", "precip_mm": 0.2, "probability": 25, "intensity_label": "light" },
    { "time": "11:45", "precip_mm": 1.4, "probability": 60, "intensity_label": "moderate" }
  ],
  "air_quality": {
    "eaqi": 42,
    "label": "Moderate",
    "pm2_5": 8.4,
    "pm10": 18.2
  }
}
```

### 2. Radar Frames Metadata
```bash
GET /api/v1/radar
```

### 3. Preset Locations
```bash
GET /api/v1/locations
```

### 4. Health Check
```bash
GET /api/v1/health
```

---

## 🧪 Testing

Run the full ExUnit test suite:
```bash
mix test
```

---

## 📄 License
MIT License. Open source for all Belgian weather enthusiasts.


## Maths panel, gauge check, live verification

The page shows the forecast's maths (radar field, motion pairs, per-5-minute table, calibration tables). `GaugeAdjust` compares the Melle gauge with the radar and damps a rate correction only above 0.5 mm. `Verifier` scores our forecasts at six places against later RMI frames while the server runs (Brier vs persistence and climatology). A STEPS ensemble (pysteps) was benchmarked and not adopted yet: see `sidecar/README.md`.
