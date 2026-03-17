# AeroVision

Flight tracking LED display for Raspberry Pi Zero 2 W with a 64×64 HUB75 LED panel.

## Architecture

- **OS/Runtime**: Elixir on Nerves (nerves_system_rpi0_2)
- **Web UI**: Phoenix LiveView served by Bandit on port 80
- **Flight Data**: OpenSky Network (nearby ADS-B, 30s) + Skylink API (tracked ADS-B, 5min + flight status enrichment for all modes). Automatic cross-fallback if a source has no credentials.
- **Display Driver**: Go binary using hzeller/rpi-rgb-led-matrix, communicates via length-prefixed JSON over stdio
- **Networking**: VintageNet with AP mode fallback (SSID: "AeroVision-Setup")
- **Hardware**: SEENGREAT RGB Matrix Adapter Board rev 3.8 (regular GPIO mapping)

## Development

### Prerequisites
- Elixir 1.19.5-otp-28, Erlang/OTP 28.3.1
- Go 1.26.0
- Node.js (managed by esbuild/tailwind via mix assets)

A `mise.toml` in the project root pins these versions. Run `mise install` to install them automatically.

### Host Development (no hardware needed)
```bash
mix deps.get
mix assets.setup
cd go_src && make build-host && cd ..
iex -S mix phx.server
# Visit http://localhost:4000
```

### Building for Target
```bash
export MIX_TARGET=rpi0_2
mix deps.get
mix firmware
mix firmware.burn  # or mix upload (for OTA)
```

### Building the Go Binary for Target
```bash
cd go_src
RPI_RGB_LIB=/path/to/rpi-rgb-led-matrix make build-arm
```

## Project Structure

```
mise.toml                   # Pinned tool versions
lib/
  aerovision/
    application.ex          # OTP supervision tree
    config/store.ex         # CubDB persistent config
    network/manager.ex      # WiFi + AP mode management
    flight/
      skylink/
        adsb.ex             # Skylink ADS-B poller (tracked mode, 5min)
        flight_status.ex    # Flight status enrichment + CubDB cache
      opensky.ex            # OpenSky ADS-B poller (nearby mode, 30s, OAuth2)
      airport_timezones.ex  # Static IATA → IANA timezone map (~90 airports)
      tracker.ex            # Flight state aggregation + synthetic no-ADS-B entries
      state_vector.ex       # ADS-B data model (imperial units; from_skylink/1, from_opensky/1)
      flight_info.ex        # Enriched flight data model (includes :status field)
      tracked_flight.ex     # Combined display model
      geo_utils.ex          # Haversine, unit conversions
    display/
      driver.ex             # Go Port driver (packet:4 IPC)
      renderer.ex           # Frame builder (64×64 layout)
    gpio/button.ex          # Physical button handler
  aerovision_web/
    live/
      dashboard_live.ex     # Live flight dashboard
      settings_live.ex      # Configuration UI
      setup_live.ex         # WiFi setup (AP mode)
go_src/led_driver/          # Go display binary
```

## PubSub Topics
- `"flights"` — ADS-B state vectors (`{:flights_raw, [%StateVector{}]}`) from either OpenSky or Skylink.ADSB, plus enrichment results (`{:flight_enriched, callsign, %FlightInfo{}}`) from Skylink.FlightStatus
- `"display"` — rendered flight list for LED display (`{:display_flights, [%TrackedFlight{}]}`)
- `"config"` — configuration changes (`{:config_changed, key, value}`) and usage counters (`{:skylink_usage, count}`)
- `"network"` — WiFi/AP mode status (`{:network, :connected, ip}` | `{:network, :ap_mode}`)
- `"gpio"` — button press events

## Display Protocol (Elixir ↔ Go)
4-byte big-endian length-prefixed JSON over stdin/stdout.

Commands:
- `flight_card` — full flight info card (64×64 layout)
- `scan_anim` — idle scanning animation (goroutine, loops until next command)
- `ap_screen` — WiFi setup help screen with scrolling URL
- `connecting_screen` — "Connecting to `<SSID>`…" screen
- `qr` — QR code with device IP
- `clear` — blank screen
- `text` — raw text at coordinates
- `brightness` — adjust LED brightness

## Config Keys

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `:location_lat` | float | 35.7721 | Center latitude for nearby scan |
| `:location_lon` | float | -78.63861 | Center longitude for nearby scan |
| `:radius_km` | number | 40.234 | Scan radius in kilometers |
| `:display_mode` | atom | `:nearby` | `:nearby` or `:tracked` |
| `:display_brightness` | integer | 80 | LED brightness percent (1–100) |
| `:display_cycle_seconds` | integer | 8 | Seconds per flight on LED panel |
| `:timezone` | string | `"America/New_York"` | IANA timezone for displayed times |
| `:units` | atom | `:imperial` | `:imperial` or `:metric` |
| `:tracked_flights` | list | `[]` | ICAO callsign strings to track (e.g. `"DAL1192"`) |
| `:airline_filters` | list | `[]` | ICAO prefix strings for nearby filtering (e.g. `"AAL"`) |
| `:airport_filters` | list | `[]` | IATA/ICAO codes for nearby filtering (e.g. `"RDU"`) |
| `:skylink_api_key` | string | nil | RapidAPI key — tracked ADS-B + flight status enrichment |
| `:opensky_client_id` | string | nil | OpenSky username — nearby ADS-B (30s polling) |
| `:opensky_client_secret` | string | nil | OpenSky password — nearby ADS-B (30s polling) |
| `:wifi_ssid` | string | nil | WiFi SSID (saved by SetupLive) |
| `:wifi_password` | string | nil | WiFi password |

## Hardware Notes
- SEENGREAT HAT: `--led-gpio-mapping=regular` (default), `--led-no-hardware-pulse`
- Must disable audio: `dtparam=audio=off` in /boot/config.txt
- Recommended: `isolcpus=3` in /boot/cmdline.txt
- 64×64 panel, 1/32 scan rate, P3 or P2.5 pitch

## LiveView Overview

### DashboardLive (`/`)
- Subscribes to `"display"` and `"network"` PubSub topics
- Displays live flight cards grid with callsign, airline, aircraft, alt, speed, heading, route, progress
- Shows network mode badge and IP address in status bar
- Handles `{:display_flights, flights}` messages to update flight list in real time

### SettingsLive (`/settings`)
- Subscribes to `"config"` PubSub topic
- Section order: **Display Mode** (always), Location (nearby only), Tracked Flights (always), Airline Filters (nearby only), Airport Filters (nearby only), Display Settings, API Keys, WiFi, System
- Location/airline/airport filter sections are hidden when `display_mode == :tracked`
- Display Settings includes timezone selector with quick-pick buttons (ET/CT/MT/PT/UTC)
- API Keys card has separate Skylink and OpenSky credential fields
- System section has **Purge Flight Cache** button (`FlightStatus.clear_cache()` + `Tracker.clear_flights()`), reboot, and shutdown
- Saves immediately via `phx-submit` handlers calling `Config.Store.put/2`

### SetupLive (`/setup`)
- Shown when device is in AP mode (connect to "AeroVision-Setup" network)
- Subscribes to `"network"` PubSub topic
- WiFi scanner (target only; shows placeholder on host)
- Select network from scan results → pre-fills SSID field
- Calls `Network.Manager.connect_wifi/2` on form submit
- Redirects to `/` on successful connection

## ADS-B Source Selection

Two pollers run concurrently but only one polls at a time per mode:

| Mode | Primary | Fallback (if primary has no creds) |
|------|---------|-------------------------------------|
| `:nearby` | `Flight.OpenSky` (30s, bbox) | `Skylink.ADSB` (30s, bbox) |
| `:tracked` | `Skylink.ADSB` (5min, per-callsign) | `Flight.OpenSky` (30s, global + callsign filter) |

Each poller calls `should_poll?(state)` before scheduling its timer — if not active, it goes idle with `poll_timer: nil`. Credential changes broadcast `{:config_changed, :opensky_client_id, _}` etc., which both pollers subscribe to and re-evaluate.

Both sources broadcast identical `{:flights_raw, vectors}` messages — `Tracker` has no knowledge of which source produced the data.

### Tracked Mode: Enrichment-Only Flights

In tracked mode, `Tracker` creates **synthetic** `%TrackedFlight{}` entries for tracked callsigns that have no ADS-B data (e.g., flights over oceans). These have `%StateVector{callsign: callsign}` with all telemetry fields nil. The display shows enrichment data (airline, route, times, progress) with `"---"` for altitude/speed/bearing. When ADS-B coverage returns, the real state vector seamlessly replaces the synthetic one.

Injection points in `Tracker`:
1. After each `{:flights_raw}` poll — `inject_missing_tracked/3`
2. When `{:flight_enriched}` arrives for a callsign not yet in flights
3. When the tracked flights config changes

### StateVector Units

All `StateVector` fields are in **imperial units** regardless of source:
- `baro_altitude` — feet
- `velocity` — knots
- `vertical_rate` — ft/min

`StateVector.from_skylink/1` — Skylink already returns imperial.
`StateVector.from_opensky/1` — converts from metric (OpenSky returns meters/m·s⁻¹).

### Flight Status Parsing Notes

Skylink Flight Status returns:
- Airport field as `"TPA • Tampa"` — parsed by `split_airport_field/1` into `iata: "TPA"`, `city: "Tampa"`
- Times as local clock strings (`"07:30"`, `"17 Mar"`) — `parse_datetime/3` converts to UTC using `AirportTimezones.timezone_for(iata)` + `DateTime.new/3` + `DateTime.shift_zone/2`
- Status as freeform string (`"Departed 07:36"`, `"En Route"`, `"Landed"`) — cache invalidation uses arrival time math, not status string matching

## Host vs Target Guards

Use `Application.get_env(:aerovision, :target, :host) != :host` to guard target-only code.
All GenServer calls to `Network.Manager` and `Nerves.Runtime` should be wrapped in `try/rescue`
to handle the case where these processes are not running in development.
