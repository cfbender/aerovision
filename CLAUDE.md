# AeroVision

Flight tracking LED display for Raspberry Pi Zero 2 W with a 64×64 HUB75 LED panel.

## Architecture

- **OS/Runtime**: Elixir on Nerves (nerves_system_rpi0_2)
- **Web UI**: Phoenix LiveView served by Bandit on port 80
- **Flight Data**: OpenSky Network (ADS-B) + FlightAware AeroAPI (enrichment)
- **Display Driver**: Go binary using hzeller/rpi-rgb-led-matrix, communicates via length-prefixed JSON over stdio
- **Networking**: VintageNet with AP mode fallback (SSID: "AeroVision-Setup")
- **Hardware**: SEENGREAT RGB Matrix Adapter Board rev 3.8 (regular GPIO mapping)

## Development

### Prerequisites
- Elixir 1.17+, Erlang/OTP 27+
- Go 1.22+
- Node.js 20+ (for esbuild/tailwind)

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
lib/
  aerovision/
    application.ex          # OTP supervision tree
    config/store.ex         # CubDB persistent config
    network/manager.ex      # WiFi + AP mode management
    flight/
      opensky.ex            # OpenSky ADS-B poller (OAuth2)
      aero_api.ex           # FlightAware enrichment (cached)
      tracker.ex            # Flight state aggregation
      state_vector.ex       # ADS-B data model
      flight_info.ex        # Enriched flight data model
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
- `"flights"` — raw OpenSky data + enrichment results
- `"display"` — rendered flight list for LED display (`{:display_flights, [%TrackedFlight{}]}`)
- `"config"` — configuration changes (`{:config_changed, key, value}`)
- `"network"` — WiFi/AP mode status (`{:network, :connected, ip}` | `{:network, :ap_mode}`)
- `"gpio"` — button press events

## Display Protocol (Elixir ↔ Go)
4-byte big-endian length-prefixed JSON over stdin/stdout.

Commands:
- `flight_card` — full flight info card (64×64 layout)
- `qr` — QR code with device IP
- `clear` — blank screen
- `text` — raw text at coordinates
- `brightness` — adjust LED brightness

## Config Keys

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `:location_lat` | float | 35.7796 | Center latitude for nearby scan |
| `:location_lon` | float | -78.6382 | Center longitude for nearby scan |
| `:radius_km` | number | 50 | Scan radius in kilometers |
| `:display_mode` | atom | `:nearby` | `:nearby` or `:tracked` |
| `:display_brightness` | integer | 80 | LED brightness percent (1–100) |
| `:display_cycle_seconds` | integer | 8 | Seconds per flight on LED panel |
| `:tracked_flights` | list | `[]` | Callsign strings to track |
| `:airline_filters` | list | `[]` | ICAO prefix strings (e.g. `"AAL"`) |
| `:opensky_client_id` | string | nil | OpenSky OAuth2 client ID |
| `:opensky_client_secret` | string | nil | OpenSky OAuth2 client secret |
| `:aeroapi_key` | string | nil | FlightAware AeroAPI key |
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
- Sections: Location, Display Mode, Tracked Flights, Airline Filters, Display Settings, API Keys, System
- Saves immediately via `phx-submit` handlers calling `Config.Store.put/2`
- System section shows firmware version, uptime, IP; has reboot button (target only)

### SetupLive (`/setup`)
- Shown when device is in AP mode (connect to "AeroVision-Setup" network)
- Subscribes to `"network"` PubSub topic
- WiFi scanner (target only; shows placeholder on host)
- Select network from scan results → pre-fills SSID field
- Calls `Network.Manager.connect_wifi/2` on form submit
- Redirects to `/` on successful connection

## Host vs Target Guards

Use `Application.get_env(:aerovision, :target, :host) != :host` to guard target-only code.
All GenServer calls to `Network.Manager` and `Nerves.Runtime` should be wrapped in `try/rescue`
to handle the case where these processes are not running in development.
