// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/zero_weather"
import topbar from "../vendor/topbar"

const Hooks = {
  ...colocatedHooks,
  RadarMap: {
    mounted() {
      const lat = parseFloat(this.el.dataset.lat) || 51.0543
      const lon = parseFloat(this.el.dataset.lon) || 3.7174
      const tileUrl = this.el.dataset.tileUrl

      if (typeof L === "undefined") {
        console.error("Leaflet not loaded")
        return
      }

      this.map = L.map(this.el, {
        zoomControl: true,
        attributionControl: false
      }).setView([lat, lon], 8)

      L.control.attribution({prefix: false}).addTo(this.map)

      // Base layer: Esri World Dark Gray (no API key). CARTO's basemaps now return an "API key required" tile.
      const esri = "https://server.arcgisonline.com/ArcGIS/rest/services/Canvas"
      L.tileLayer(`${esri}/World_Dark_Gray_Base/MapServer/tile/{z}/{y}/{x}`, {
        maxZoom: 19,
        maxNativeZoom: 16,
        attribution: "Tiles &copy; Esri &mdash; Esri, HERE, Garmin, FAO, NOAA, USGS, &copy; OpenStreetMap contributors"
      }).addTo(this.map)

      // Place labels live in their own pane so they stay above the radar overlay
      this.map.createPane("labels")
      this.map.getPane("labels").style.zIndex = 650
      this.map.getPane("labels").style.pointerEvents = "none"
      L.tileLayer(`${esri}/World_Dark_Gray_Reference/MapServer/tile/{z}/{y}/{x}`, {
        pane: "labels",
        maxZoom: 19,
        maxNativeZoom: 16
      }).addTo(this.map)

      // RainViewer's free radar tiles only exist up to zoom 7 (higher zooms return a "not supported" image),
      // so cap the native zoom and let Leaflet scale the zoom-7 tiles up.
      const radarTiles = (url) =>
        L.tileLayer(url, {
          opacity: 0.7,
          zIndex: 10,
          maxNativeZoom: 7,
          attribution: '<a href="https://www.rainviewer.com/" target="_blank" rel="noopener">RainViewer</a>'
        })

      // Radar Overlay Layer
      if (tileUrl) {
        this.radarLayer = radarTiles(tileUrl).addTo(this.map)
      }

      // Location Marker
      this.marker = L.circleMarker([lat, lon], {
        radius: 8,
        fillColor: "#38bdf8",
        color: "#ffffff",
        weight: 2,
        opacity: 1,
        fillOpacity: 0.9
      }).addTo(this.map)

      // Event from LiveView to change radar frame
      this.handleEvent("change-radar-frame", ({ tileUrl }) => {
        if (this.radarLayer) {
          this.map.removeLayer(this.radarLayer)
        }
        if (tileUrl) {
          this.radarLayer = radarTiles(tileUrl).addTo(this.map)
        }
      })

      // Event from LiveView to pan to new location
      this.handleEvent("pan-location", ({ lat, lon, name }) => {
        this.map.setView([lat, lon], 9)
        if (this.marker) {
          this.marker.setLatLng([lat, lon])
        }
      })
    },
    destroyed() {
      if (this.map) {
        this.map.remove()
      }
    }
  },

  Geolocation: {
    mounted() {
      this.el.addEventListener("click", () => {
        if ("geolocation" in navigator) {
          this.el.classList.add("loading")
          navigator.geolocation.getCurrentPosition(
            (pos) => {
              this.el.classList.remove("loading")
              this.pushEvent("set_coords", {
                lat: pos.coords.latitude,
                lon: pos.coords.longitude,
                name: "My Location"
              })
            },
            (err) => {
              this.el.classList.remove("loading")
              alert("Could not access location: " + err.message)
            }
          )
        }
      })
    }
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks,
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

