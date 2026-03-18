# ✈ AeroVision

A real-time flight tracking LED display built on a Raspberry Pi Zero 2 W. AeroVision polls live ADS-B data and renders a full flight information card — callsign, aircraft type, route, altitude, speed, heading, departure/arrival times, and a progress bar — on a 64×64 HUB75 LED matrix panel.

<img width="1488" height="1374" alt="image" src="https://github.com/user-attachments/assets/01382963-573e-428d-83d1-d45acb1d65aa" />


```
┌────────────────────────────────────────────────────────────────┐
│  ┌──────────┐  AA 1234         ← Flight # (white)              │
│  │          │                                                   │
│  │  ✈ icon  │  B738            ← Aircraft type (gray)          │
│  │  16×16   │                                                   │
│  └──────────┘  RDU▸SLC         ← Route (white)                 │
│────────────────────────────────────────────────────────────────│
│  FL350                                              450KT      │
│                                                                 │
│  045°                                                -500      │
│                                                                 │
│  14:30                                              18:45      │
│  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░          │
└────────────────────────────────────────────────────────────────┘
```

A web-based configuration UI (Phoenix LiveView) is served directly from the device on port 80, accessible at `http://aerovision.local` from any device on your network.

---

## Hardware

### Shopping List

| Component | Notes | Approximate Cost |
|-----------|-------|-----------------|
| **Raspberry Pi Zero 2 W** | The main compute board | ~$15 |
| **64×64 HUB75 LED Panel** | P3 or P2.5 pitch, 1/32 scan rate, indoor | ~$25–40 |
| **SEENGREAT RGB Matrix Adapter Board rev 3.8** | Routes power through the HAT to the Pi | ~$15 |
| **5V 4A (or greater) power supply** | Barrel jack (5.5mm/2.1mm), powers panel + Pi via HAT | ~$10 |
| **MicroSD card** | 8GB minimum, 16GB+ recommended (UHS-I Speed Class 3) | ~$8 |
| **MicroSD card reader** | For flashing firmware from your computer | ~$5 |
| **Momentary push button** (optional) | Short press = QR code, long press = AP mode | ~$1 |
| **Jumper wires** (optional, for button) | 2× female-to-female dupont wires | ~$1 |

> **Panel selection tip**: Look for panels described as "64×64 P3 indoor HUB75" or "64×64 P2.5 indoor HUB75". The "P3" or "P2.5" refers to the pixel pitch (3mm or 2.5mm between LEDs). Avoid outdoor panels — they are much brighter and draw more power. Common sources: AliExpress, Adafruit, Amazon.

The provided 3D printed enclosure was only tested on the Waveshare 64x64 P3 pitch LED panel.

---

## Wiring

### SEENGREAT HAT → Raspberry Pi

The SEENGREAT RGB Matrix Adapter Board is a HAT (Hardware Attached on Top) — it plugs directly onto the Pi's **40-pin GPIO header**. No individual wires needed for this connection. Make sure all 40 pins are aligned before pressing down.

```
Raspberry Pi Zero 2 W
┌─────────────────────────────────┐
│  [●●●●●●●●●●●●●●●●●●●●] GPIO  │
└──────────────┬──────────────────┘
               │ 40-pin GPIO header
               ▼
┌─────────────────────────────────┐
│   SEENGREAT RGB Matrix HAT      │
│   rev 3.8                       │
│                                 │
│  [HUB75 OUTPUT]  [PWR IN 5V]   │
└─────────┬──────────┬────────────┘
          │          │
          │ HUB75    │ 5V 4A+ PSU
          │ ribbon   │ barrel jack
          ▼          ▼
┌─────────────────────────────────┐
│   64×64 HUB75 LED Panel         │
│   [HUB75 INPUT]  [PWR SCREW]   │
└─────────────────────────────────┘
```

### HUB75 Panel Connection

1. Connect the **HUB75 ribbon cable** from the HAT's **output port** (labeled "OUTPUT" or "P1") to the LED panel's **input port** (usually labeled "IN" or marked with an arrow).
2. The ribbon connector is keyed — it only fits one way. Don't force it.
3. Some panels have two HUB75 connectors (IN and OUT) for daisy-chaining. Connect to the **IN** port only.

### Power

The SEENGREAT HAT has a barrel jack (5.5mm outer / 2.1mm inner, center positive) that powers **both** the Pi and the LED panel through the HAT — you only need one power connection.

> ⚠️ **Power requirement**: A 64×64 LED panel at full white can draw up to 2A. A Pi Zero 2 W draws ~200mA. Use a **5V 4A (20W)** supply at minimum. Using an underpowered supply causes flickering, crashes, or panel damage.

The panel also has its own power screw terminals. When using the SEENGREAT HAT for power routing, **do not** connect a separate power supply to the panel's screw terminals at the same time.

### Optional: Physical Button

A push button provides two hardware shortcuts:

- **Short press** (<1 second): Display a QR code with the device's IP address on the LED panel for 10 seconds. Only works when connected to WiFi.
- **Long press** (≥3 seconds): Force the device back into AP/setup mode

Wiring:
```
Button pin 1  ──────────────  GPIO 26 (Pin 37 on the 40-pin header)
Button pin 2  ──────────────  GND (Pin 39 on the 40-pin header)
```

The firmware uses an internal pull-up resistor, so no external resistor is needed. The button is **active low** (circuit closes when pressed).

```
Pi 40-pin header (right edge, bottom of board)
...
Pin 37  GPIO26 ──┐
Pin 38  GPIO20   ├── connect button between these two pins
Pin 39  GND   ──┘
Pin 40  GPIO21
```

---

## API Keys

AeroVision uses two data sources — one for each display mode. Both are optional but at least one must be configured.

### Flight Enrichment (automatic, no API key needed)

Flight enrichment — airline name, aircraft type, route, departure/arrival times, and flight status — is provided automatically by scraping **FlightAware** and **FlightStats** public flight tracker pages. No API key or account is needed. This works in both nearby and tracked modes.

The Skylink API (below) is only used as a paid fallback when both free sources fail for a given flight.

### Skylink API (Tracked mode + enrichment)

Skylink provides ADS-B position data in **tracked mode** (polling every 5 minutes by callsign) and serves as a paid fallback for flight enrichment when the free scrapers (FlightAware, FlightStats) both fail. The free tier allows ~1,000 API calls per month.

1. Go to **[rapidapi.com/skylink-api-skylink-api-default/api/skylink-api](https://rapidapi.com/skylink-api-skylink-api-default/api/skylink-api)**
2. Sign in or create a free RapidAPI account
3. Subscribe to the Skylink API (free tier available)
4. Your key is shown under **Security → X-RapidAPI-Key**
5. Enter it in the setup wizard or under **Settings → API Keys**

### OpenSky Network (Nearby mode)

OpenSky is used in **nearby mode** (polling every 30 seconds by bounding box). It's free and has generous rate limits for regional scanning.

1. Register at **[opensky-network.org](https://opensky-network.org)**
2. Your username is the **Client ID** and your password is the **Client Secret**
3. Enter both in the setup wizard or under **Settings → API Keys**

If OpenSky credentials are not configured, AeroVision falls back to Skylink for nearby mode. If Skylink is not configured, OpenSky is used for tracked mode (global fetch filtered by callsign).

---

## Development Setup (No Hardware Required)

You can run AeroVision on your development machine to iterate on the web UI and flight data pipeline without any hardware.

### Prerequisites

- **Elixir 1.19.5-otp-28** and **Erlang/OTP 28.3.1**
- **Go 1.26.0**
- **Git**

The repo includes a `mise.toml` with pinned versions. If you use [mise](https://mise.jdx.dev/), run `mise install` in the project root to get the correct toolchain automatically. Otherwise install manually via [asdf](https://github.com/asdf-vm/asdf), [Homebrew](https://brew.sh), or [golang.org/dl](https://golang.org/dl/).

### Quick Start

```bash
# Clone the repo
git clone https://github.com/yourusername/aerovision
cd aerovision

# Install dependencies, set up assets, and copy timezone data
mix setup

# Build assets for development
mix assets.build

# Build the Go display driver in emulator mode (no LED hardware needed)
cd go_src && make build-host && cd ..

# Start the server
iex -S mix phx.server
```

> **Note**: `mix setup` runs `deps.get`, `assets.setup`, and copies the host's IANA timezone database into `rootfs_overlay/` for Nerves firmware builds. The timezone directory is gitignored, so `mix setup` must be run on every fresh clone.

Visit **[http://localhost:4000](http://localhost:4000)** — the setup wizard will guide you through configuration.

> **Note**: In development mode, WiFi management (VintageNet) is disabled. The WiFi step of the setup wizard can be skipped.

### Configuration via Environment Variables

All settings can be seeded from a `.env` file in the project root at **build time** — values are compiled into the firmware so no file needs to be copied to the device. Values are only applied if the setting hasn't already been saved through the UI — manual changes always take precedence.

```bash
# API Keys
SKYLINK_API_KEY=your-rapidapi-key-here   # tracked mode ADS-B + enrichment
OPENSKY_CLIENT_ID=your-username          # nearby mode ADS-B (free)
OPENSKY_CLIENT_SECRET=your-password      # nearby mode ADS-B (free)

# WiFi — pre-configuring these skips the setup wizard on first boot
WIFI_SSID=MyHomeNetwork
WIFI_PASSWORD=mysecretpassword

# Location
LOCATION_LAT=35.7721
LOCATION_LON=-78.63861
RADIUS_MI=25                           # miles  (takes priority over RADIUS_KM)
RADIUS_KM=40.234                       # km     (used if RADIUS_MI is not set)

# Display
DISPLAY_BRIGHTNESS=80                  # 1–100
DISPLAY_CYCLE_SECONDS=8                # seconds per flight card
DISPLAY_MODE=nearby                    # nearby | tracked
TIMEZONE=America/New_York              # IANA timezone for displayed times

# Flight filters
UNITS=imperial                         # imperial | metric
TRACKED_FLIGHTS=AAL123,DAL456          # comma-separated callsigns
AIRLINE_FILTERS=AAL,DAL                # comma-separated ICAO operator codes
AIRPORT_FILTERS=RDU,CLT                # comma-separated IATA/ICAO codes
```

Place the `.env` file in the project root before running `mix firmware`. The values are read at build time by `config/config.exs` and baked into the firmware image — the device reads them from application config at startup, not from any file on disk.

### Terminal Display Preview

Preview exactly what the LED panel will show, rendered in your terminal using ANSI true color and Unicode half-block characters:

```bash
# Show a sample flight card
./priv/led_driver --demo
```

### Live Preview in the Browser

When the server is running, visit **[http://localhost:4000/preview](http://localhost:4000/preview)** to see a live 64×64 pixel grid that mirrors exactly what the LED panel is rendering, updated in real time via WebSocket.

---

## Building for Raspberry Pi

### Prerequisites

Install the Nerves toolchain on your development machine:

```bash
# Install Nerves bootstrap archive
mix archive.install hex nerves_bootstrap

# macOS: install fwup (firmware update tool)
brew install fwup

# Ubuntu/Debian
sudo apt install fwup
```

For the Go cross-compilation, you'll need the ARM C/C++ toolchain:

```bash
# macOS
brew install arm-linux-gnueabihf-binutils

# Ubuntu/Debian
sudo apt install gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf
```

### Step 1: Build the Go LED Driver for ARM

The Makefile handles everything — it automatically clones and compiles the `hzeller/rpi-rgb-led-matrix` C library using the Nerves-bundled aarch64 toolchain (already downloaded when you ran `mix deps.get`), then cross-compiles the Go binary:

```bash
cd go_src
make build-arm
```

This produces `priv/led_driver` — the ARM binary included in the Nerves firmware image. The C library source is downloaded into `go_src/.hzeller/` (gitignored) on first run. No manual library installation required.

### Step 2: Build the Nerves Firmware

Create a `.env` file in the project root with your settings (see [Configuration via Environment Variables](#configuration-via-environment-variables)), then:

```bash
# Set the target to Raspberry Pi Zero 2 W
export MIX_TARGET=rpi0_2
export MIX_ENV=prod

# Fetch target-specific dependencies
mix deps.get

# Build firmware (automatically runs assets.deploy first)
mix build
```

This produces `_build/rpi0_2_prod/nerves/images/aerovision.fw`.

### Step 3: Flash to SD Card

```bash
# macOS — replace diskN with your SD card device (check with `diskutil list`)
sudo fwup -a -i _build/rpi0_2_prod/nerves/images/aerovision.fw -d /dev/diskN -t complete

# Or use the convenience alias (runs assets.deploy → firmware → burn):
mix firmware.burn
```

> ⚠️ **Double-check the device path** — flashing the wrong disk will erase it permanently.

### Convenience Aliases

| Alias | Expands to |
|-------|------------|
| `mix setup` | `deps.get` → `assets.setup` → copy zoneinfo |
| `mix build` | `assets.deploy` → `firmware` |
| `mix deploy` | `assets.deploy` → `firmware` → `upload aerovision.local` |
| `mix firmware.burn` | `assets.deploy` → `firmware` → `firmware.burn` |
| `mix firmware.upload` | `assets.deploy` → `firmware` → `firmware.ssh` |
| `mix precommit` | `format` → `compile --warnings-as-errors` → `test` |

### Over-the-Air Updates (OTA)

After the first flash, you can push updates over WiFi without removing the SD card:

```bash
# One-command deploy (assets.deploy → firmware → upload):
MIX_TARGET=rpi0_2 MIX_ENV=prod mix deploy
```

The device will reboot into the new firmware automatically.

---

## First Boot & Configuration

### Step 1: Power On

Insert the flashed SD card into the Pi, connect the SEENGREAT HAT (with panel and power), and power on via the HAT's barrel jack. The LED panel may briefly flash white during boot — this is normal.

Boot takes approximately **30–60 seconds** on first power-on.

If you pre-configured `WIFI_SSID` and `WIFI_PASSWORD` in your `.env` before building, the device will connect automatically on first boot — no setup wizard needed.

### Step 2: Connect to the Setup Network

If no WiFi credentials are configured, the device starts in **AP mode** and shows the connection instructions on the LED panel:

1. On your phone or laptop, open WiFi settings
2. Connect to the network: **`AeroVision-Setup`** (open network, no password)
3. Your device will be assigned an IP in the `192.168.24.x` range

The LED panel displays the SSID and URL (`http://192.168.24.1`) while in AP mode. If the URL is too long to fit, it scrolls across the panel.

### Step 3: Open the Setup Wizard

Navigate to **[http://192.168.24.1](http://192.168.24.1)** in your browser.

The setup wizard walks you through three steps. **The device stays in AP mode for the entire wizard** — WiFi connection is deferred until you finish all steps, so you won't lose your browser session mid-setup.

**Step 1 — WiFi**
Tap **Scan** to find nearby networks, or type your SSID manually. Enter your password and tap **Save & Continue**. The credentials are saved immediately but the connection doesn't happen yet.

**Step 2 — API Keys**
Enter your Skylink API key and/or OpenSky credentials. At least one source must be configured. See the [API Keys](#api-keys) section above.

**Step 3 — Location**
Enter your latitude, longitude, and search radius. AeroVision will scan for all flights within this radius of your location.

> **Tip**: Use [latlong.net](https://www.latlong.net/) or Google Maps (right-click → "What's here?") to find your coordinates.

After completing setup, the device reboots to apply the WiFi configuration (a limitation of the Pi Zero 2 W's WiFi driver). Reconnect your laptop/phone to your home WiFi and navigate to **[http://aerovision.local](http://aerovision.local)**. Flight data will begin appearing within 15–30 seconds.

### Display States

| State | What you see on the panel |
|-------|--------------------------|
| **AP / Setup mode** | "CONNECT TO: AeroVision-Setup" with scrolling URL |
| **Connecting to WiFi** | "Connecting to `<SSID>`…" with `aerovision.local` reminder |
| **Scanning for flights** | Animated top-down airplane sprite flying across the display in a random direction |
| **Flight data** | Full flight card cycling through nearby flights |
| **QR code** | Device IP as a scannable QR code (short button press, WiFi connected only) |

A device log viewer (RingLogger output) is available in real time at **[http://aerovision.local/logs](http://aerovision.local/logs)**.

### Physical Button Usage

| Press | Action |
|-------|--------|
| **Short press** (<1 second) | Show QR code with device IP on the LED panel for 10 seconds (only when connected to WiFi) |
| **Long press** (≥3 seconds) | Force device back into AP/setup mode |

The QR code is useful when the device's IP address changes and you can't reach `aerovision.local`.

---

## Configuration

All settings are accessible at **[http://aerovision.local/settings](http://aerovision.local/settings)**. Settings are stored in a JSON file at `/data/aerovision/config/settings.json` on the device's writable partition. The file is written atomically (write-then-rename), so settings survive unexpected power loss and firmware updates.

Settings are organized with **Display Mode** at the top so you can quickly switch between nearby and tracked. Location, airline, and airport filters are hidden when in tracked mode since they don't apply.

| Setting | Default | Description |
|---------|---------|-------------|
| **Display Mode** | Nearby | `Nearby` = all flights in radius; `Tracked` = specific callsigns only |
| **Location** — Latitude | 35.7721 | Center of the nearby search area |
| **Location** — Longitude | -78.63861 | Center of the nearby search area |
| **Location** — Radius | 50 km | How far out to scan for flights (nearby mode only) |
| **Tracked Flights** | (empty) | Callsigns to monitor in Tracked mode (e.g., `DAL1192`). Flights are shown even when outside ADS-B coverage — enrichment data (route, times, progress) is displayed with `---` for live telemetry. |
| **Airline Filters** | (empty) | Filter Nearby mode by ICAO operator prefix (e.g., `AAL` for American) |
| **Airport Filters** | (empty) | Filter by origin or destination IATA/ICAO code (e.g., `RDU`) |
| **Brightness** | 80% | LED panel brightness (1–100) |
| **Cycle Interval** | 8 seconds | How long each flight is displayed before cycling |
| **Timezone** | America/New_York | IANA timezone for departure/arrival time display. Quick-select buttons for ET/CT/MT/PT/UTC. |
| **Units** | Imperial | `Imperial` (ft, kt) or `Metric` (m, km/h) |
| **Skylink API Key** | (none) | RapidAPI key — tracked mode ADS-B + flight status enrichment for all modes |
| **OpenSky Client ID** | (none) | OpenSky username — nearby mode ADS-B (30s updates) |
| **OpenSky Client Secret** | (none) | OpenSky password — nearby mode ADS-B (30s updates) |
| **WiFi SSID** | (none) | Home network name |

The Settings page also includes a **🗑️ Purge Flight Cache** button under the System section (clears enrichment cache and tracked flights, useful when data appears stale) and **Reboot** / **Shut Down** buttons. Shut Down powers off the Pi safely.

### Finding Airline ICAO Codes

For airline filters, use the ICAO operator code (3 letters), not the IATA code (2 letters):

| Airline | ICAO Code | IATA Code |
|---------|-----------|-----------|
| American Airlines | `AAL` | `AA` |
| Delta Air Lines | `DAL` | `DL` |
| United Airlines | `UAL` | `UA` |
| Southwest Airlines | `SWA` | `WN` |
| JetBlue Airways | `JBU` | `B6` |
| Alaska Airlines | `ASA` | `AS` |
| FedEx | `FDX` | `FX` |
| UPS Airlines | `UPS` | `5X` |

A full list is available on [Wikipedia](https://en.wikipedia.org/wiki/List_of_airline_codes).

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Nerves (Linux on Pi)                      │
│                                                             │
│  AeroVision.Application (OTP Supervisor)                    │
│    ├── Config.Store          JSON file on /data partition   │
│    ├── Network.Manager       WiFi + AP fallback (VintageNet)│
│    ├── Flight.Skylink.FlightStatus  Enrichment pipeline + ETS cache │
│    ├── Flight.Skylink.ADSB         ADS-B poller (tracked, 5min) │
│    ├── Flight.OpenSky              ADS-B poller (nearby, 30s)   │
│    ├── Flight.Tracker        State aggregation + filtering  │
│    ├── Display.Driver        Go port manager (packet:4)     │
│    ├── Display.Renderer      Frame builder + display modes  │
│    ├── Display.PreviewServer Pixel relay for /preview page  │
│    ├── GPIO.Button           Physical button handler        │
│    └── AeroVisionWeb.Endpoint  Phoenix + LiveView on :80    │
│                                       │                     │
│                          4-byte length-prefixed JSON        │
│                                       ▼                     │
│  led_driver (Go binary)               ←─ stdin commands     │
│    hzeller/rpi-rgb-led-matrix  ──▶  SEENGREAT HAT           │
└───────────────────────────────────────┼─────────────────────┘
                                        ▼
                              64×64 HUB75 LED Panel
```

**Data flow**:
1. `OpenSky` polls every 30 seconds in nearby mode (bounding box); `Skylink.ADSB` polls every 5 minutes in tracked mode (by callsign). Each source only polls when active — they don't overlap. Automatic cross-fallback if a source has no credentials.
2. Both sources broadcast `{:flights_raw, vectors}` on the same PubSub topic. `Tracker` consumes from both.
3. `Tracker` requests enrichment for new flights via `FlightStatus`. In nearby mode, only the 5 closest flights get enrichment requests (not all flights in the radius) to reduce unnecessary API/scraping load. `FlightStatus` runs a 3-source enrichment waterfall: **FlightAware** (HTML scraping, free, primary) → **FlightStats** (HTML scraping, free, fallback) → **Skylink API** (paid, final fallback). FlightAware and FlightStats require no API key — they scrape public flight tracker pages. Skylink is only used when both free sources fail and an API key is configured. Enrichment data is cached in ETS for 24 hours. In tracked mode, flights with stale data (>30 minutes old) are automatically re-enriched to keep ETAs and status current during long flights. Flights with terminal status (Landed, Cancelled) skip re-enrichment. When both free sources return permanent failures for a callsign, it is negatively cached to avoid repeated futile requests.
4. `Renderer` builds display commands and sends them to `Driver`
5. `Driver` forwards commands to the Go binary via stdin (4-byte length-prefixed JSON)
6. The Go binary renders to the LED matrix using double-buffered vsync swaps

**NTP sync gate**: The Pi Zero 2W has no real-time clock — on boot, the system clock starts at firmware build time until NTP syncs. `AeroVision.TimeSync.synchronized?/0` gates all HTTPS callers (`FlightStatus`, `ADSB`, `OpenSky`) to prevent TLS certificate validation failures from clock skew.

**Display commands**:
- `flight_card` — renders a full flight information card
- `scan_anim` — starts the idle scanning animation (goroutine, looping)
- `ap_screen` — WiFi setup help screen with scrolling URL
- `connecting_screen` — "Connecting to `<SSID>`…" screen
- `qr` — QR code display
- `brightness` — adjusts panel brightness

**Rendering**: The Go binary uses hzeller's double-buffering API (`led_matrix_create_offscreen_canvas` + `led_matrix_swap_on_vsync`). All drawing happens on an invisible offscreen canvas; `Render()` swaps it to the display atomically at vsync, eliminating flicker from the clear→draw cycle.

**Idle animation**: When no flights are in range, the `scan_anim` goroutine flies a 16×16 top-down airplane sprite across the display. Each pass picks a random cardinal diagonal (NE/SE/SW/NW) and entry position. The sprite is pre-rotated at startup into all 4 orientations using pixel-level rotation of the NE master sprite. The animation goroutine checks if it's already running before starting — sending `scan_anim` repeatedly (e.g. on each ADS-B poll) does not restart or interrupt the animation.

**Settings storage**: Configuration is written atomically to `settings.json` using write-then-rename. A crash mid-write leaves the previous file untouched. Flight enrichment data (Skylink FlightStatus responses) is cached separately in CubDB — cache loss on a bad shutdown is harmless.

**Build-time config injection**: `config/config.exs` reads `.env` at `mix firmware` time and compiles the values into the firmware as application config (`Application.get_env(:aerovision, :env_seeds)`). The device reads from application config at startup — no file I/O needed on the device.

For full technical details, see [AGENTS.md](AGENTS.md).

---

## Troubleshooting

### LED panel doesn't light up
- Verify the barrel jack power supply is 5V and at least 4A
- Check that the HUB75 ribbon cable is connected to the **input** port on the panel (not output)
- Confirm the SEENGREAT HAT is fully seated on the Pi's 40-pin GPIO header
- Try a different power supply — cheap supplies often can't sustain 4A

### LED panel flickers
The Pi Zero 2 W (BCM2710A1) toggles GPIO faster than some panels' shift registers can track. The firmware is already tuned for this with `--led-slowdown-gpio=2` and `--led-limit-refresh=100`, but if you still see flicker:
- Try increasing `slowdown_gpio` to 3 or 4 in `config/rpi0_2.exs` and rebuilding
- Reduce `limit_refresh_hz` to 80 or 60 for more consistent timing under load
- Verify the power supply is adequate — voltage sag under load causes display instability
- Otherwise, this is a known issue effectively. The real fix would be running the led driver on it's own Pi, and send commands some other way. The resource constraints here cause some slight flickering especially in the dithered sections, regardless of optimizations.

### No flights appearing on the display
1. Verify at least one ADS-B source is configured in **Settings → API Keys**
   - **Nearby mode**: OpenSky credentials (preferred) or Skylink API key
   - **Tracked mode**: Skylink API key (preferred) or OpenSky credentials
2. Verify your location is set correctly — the default is Raleigh, NC (nearby mode only)
3. Try increasing the radius (e.g., 100km for rural areas) in nearby mode
4. In tracked mode, the flight card appears even without ADS-B coverage (shows enrichment data). If it's missing entirely, the callsign may not be found by the Flight Status API — verify it's the correct ICAO callsign (e.g., `DAL1192`, not `DL1192`)
5. Use **Settings → System → 🗑️ Purge Flight Cache** if enrichment data appears stale

### WiFi setup wizard drops connection during scan
This was a known issue where saving WiFi credentials would immediately trigger a reconnect, dropping the AP. It's fixed — credentials are saved but the actual connection is deferred until you complete all wizard steps.

### WiFi won't connect / device won't appear on network after setup
The Pi Zero 2 W's brcmfmac WiFi driver cannot switch from AP mode to station mode at runtime without a reboot. After completing the setup wizard, the device automatically reboots to apply the WiFi configuration. This is expected behaviour — wait for the reboot (10–15 seconds), then reconnect your laptop to your home WiFi and navigate to `http://aerovision.local`.

If it still won't connect after reboot:
- Long-press the physical button (≥3 seconds) to force AP mode
- Connect to `AeroVision-Setup` and reconfigure WiFi at `http://192.168.24.1`
- Double-check SSID and password (case-sensitive)

### Settings reset after reboot
Settings are stored at `/data/aerovision/config/settings.json`. If this file is missing or unreadable, defaults are used. Check that the `/data` partition is mounted and writable. The file is never wiped by a firmware update — only a factory reset (`Config.Store.reset()` in IEx) clears it.

### Can't connect to aerovision.local
- mDNS/Bonjour must be enabled. macOS has this by default. On Windows, install [Bonjour for Windows](https://support.apple.com/kb/DL999). On Linux: `sudo apt install avahi-daemon`
- Short-press the physical button to show the QR code with the direct IP address on the LED panel
- Check your router's DHCP client list for a device named `aerovision`

### Preview page not working
The `/preview` page works on both host and the real device. On the device, a separate `led_driver` process is spawned with `--preview-pixels` (software rendering only, no GPIO access) and relays pixel data to the browser via WebSocket. If the preview is blank, check that the `led_driver` binary exists at `priv/led_driver` in the firmware.

### OTA update fails
- Ensure the device and your laptop are on the same network
- Try using the IP address directly: `mix upload 192.168.1.x` instead of `aerovision.local`
- SSH into the device: `ssh nerves.local` or `ssh 192.168.1.x`

### Flights not loading on first boot (NTP sync)
The Pi Zero 2W has no real-time clock. On first boot, the system clock starts at the firmware build time until NTP synchronizes over WiFi (typically 5–15 seconds after connecting). During this window, HTTPS requests fail because TLS certificate validation sees the server certificate as "expired". This is handled automatically — all API callers wait for NTP sync before making requests. If flights don't appear within 30 seconds of WiFi connecting, check the device logs at `http://aerovision.local/logs` for NTP or TLS errors.

---

## Project Structure

```
aerovision/
├── mise.toml                     # Pinned tool versions (Elixir, Erlang, Go)
├── lib/
│   ├── aerovision/
│   │   ├── application.ex        # OTP supervision tree
│   │   ├── db.ex                 # CubDB wrapper (enrichment cache)
│   │   ├── time_sync.ex          # NTP sync gate for HTTPS callers (apply/3 wrapper)
│   │   ├── config/store.ex       # Atomic JSON settings, build-time env seeding
│   │   ├── network/manager.ex    # WiFi + AP mode (VintageNet)
│   │   ├── flight/
│   │   │   ├── flightaware.ex         # FlightAware scraper (primary enrichment, free)
│   │   │   ├── flightstats.ex         # FlightStats scraper (fallback enrichment, free)
│   │   │   ├── airline_codes.ex       # ICAO↔IATA airline code mapping
│   │   │   ├── flight_info.ex         # %FlightInfo{} and %Airport{} structs
│   │   │   ├── skylink/
│   │   │   │   ├── adsb.ex            # Skylink ADS-B poller (tracked mode, 5min)
│   │   │   │   └── flight_status.ex   # Enrichment pipeline + ETS/CubDB cache
│   │   │   ├── opensky.ex             # OpenSky ADS-B poller (nearby mode, 30s)
│   │   │   ├── airport_timezones.ex   # IATA → IANA timezone static map
│   │   │   ├── tracker.ex             # State aggregation + filtering
│   │   │   └── geo_utils.ex           # Haversine, unit conversion
│   │   ├── display/
│   │   │   ├── driver.ex         # Go Port manager, PubSub relay
│   │   │   ├── renderer.ex       # Display mode state machine
│   │   │   └── preview_server.ex # Software pixel relay for /preview
│   │   └── gpio/button.ex        # Physical button (nanosecond timestamps)
│   ├── aerovision_web/
│   │   └── live/
│   │       ├── dashboard_live.ex # Flight dashboard + deferred-connect setup wizard
│   │       ├── settings_live.ex  # Full configuration UI + reboot/shutdown
│   │       ├── setup_live.ex     # WiFi-only setup page
│   │       ├── logs_live.ex       # Device log viewer (RingLogger)
│   │       └── preview_live.ex   # Live 64×64 pixel grid preview
│   └── host_stubs/
│       └── target_stubs.ex       # Circuits.GPIO, VintageNet, Nerves stubs (host only)
├── go_src/
│   ├── Makefile                  # Auto-downloads hzeller lib, uses Nerves toolchain
│   └── led_driver/
│       ├── main.go               # Entry point; --preview-pixels uses SoftwareMatrix
│       ├── matrix.go             # Matrix interface
│       ├── matrix_real.go        # hzeller double-buffered hardware (target)
│       ├── matrix_software.go    # In-memory software renderer (preview, all targets)
│       ├── matrix_stub.go        # Silent stub (emulator builds)
│       ├── matrix_term.go        # ANSI terminal preview (emulator builds)
│       ├── protocol.go           # 4-byte length-prefixed JSON IPC
│       ├── display.go            # All rendering: flight card, animations, screens
│       ├── fonts.go              # 5×7 and 4×5 bitmap fonts, plane sprite, clipped draw
│       └── qrcode.go             # QR code generation
├── config/
│   ├── config.exs                # Shared config + build-time .env injection
│   ├── dev.exs                   # Dev overrides (host-only code reloader etc.)
│   ├── host.exs                  # Host (non-Nerves) endpoint config
│   ├── prod.exs                  # Production config
│   └── rpi0_2.exs                # Nerves target: GPIO slowdown, refresh rate cap
├── assets/
│   ├── js/app.js                 # Phoenix LiveView JS + PixelGrid hook
│   ├── css/app.css               # Tailwind v4
│   └── vendor/                   # topbar, heroicons plugin
├── rootfs_overlay/               # Files overlaid onto Nerves root FS (zoneinfo/ is gitignored, generated by mix setup)
└── priv/
    └── led_driver                # Compiled Go binary (included in firmware)
```

---

## License

MIT License — see [LICENSE](LICENSE) for details.
