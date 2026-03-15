# ✈ AeroVision

A real-time flight tracking LED display built on a Raspberry Pi Zero 2 W. AeroVision polls live ADS-B data from the OpenSky Network and renders a full flight information card — callsign, aircraft type, route, altitude, speed, heading, departure/arrival times, and a progress bar — on a 64×64 HUB75 LED matrix panel.

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

- **Short press** (<1 second): Display a QR code with the device's IP address on the LED panel for 10 seconds
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

### OpenSky Network (Required — Free)

OpenSky Network provides real-time ADS-B position data for aircraft worldwide. AeroVision polls it every 15 seconds to find flights overhead.

1. Create a free account at **[opensky-network.org](https://opensky-network.org)**
2. Log in and go to **Account → My Account**
3. Scroll to **API credentials** or **OAuth2 clients**
4. Create a new OAuth2 client — you'll receive a **Client ID** and **Client Secret**
5. Enter these in the AeroVision setup wizard (Step 2: API Keys) or under **Settings → API Keys**

**Rate limits (free tier)**:
- ~400 API credits/day for registered users
- 1 credit per bounding box query (used by AeroVision)
- At 15-second polling intervals, that's ~5,760 queries/day — well within limits if you keep the poll interval at 60 seconds or higher for a busy bounding box

> **Note**: Anonymous access (no credentials) has stricter limits (~100 credits/day) and may be blocked entirely. Registering is free and strongly recommended.

---

### FlightAware AeroAPI (Optional — ~$0–2/month)

AeroAPI enriches each flight with the airline name, aircraft type, origin/destination airports, and departure/arrival times. Without it, AeroVision shows callsigns and positions only.

1. Go to **[flightaware.com/aeroapi/signup/personal](https://www.flightaware.com/aeroapi/signup/personal)**
2. Choose the **Personal** tier:
   - **Free up to $5/month** (or $10/month if you feed ADS-B data to FlightAware)
   - No monthly minimum
   - Personal/academic use only
3. Create or log into your FlightAware account
4. After signing up, visit the **[AeroAPI portal](https://www.flightaware.com/aeroapi/portal)**
5. Your **API key** is shown in the portal dashboard
6. Enter it in the AeroVision setup wizard or **Settings → API Keys**

**Cost estimate for AeroVision**:

AeroVision calls `GET /flights/{ident}` to enrich each new callsign it sees. This endpoint costs **$0.005 per result set**. Results are cached for 1 hour, so each unique flight is only queried once per hour.

- Typical overhead: 5–20 unique flights/hour = $0.025–0.10/hour
- Running 8 hours/day: ~$0.20–0.80/day → **$6–24/month worst case**
- In practice, most locations see 3–8 unique flights/hour → **well under $5/month**

> **Tip**: If you run AeroVision 24/7 and fly over a busy hub airport, monitor your AeroAPI usage in the portal for the first few days.

---

## Development Setup (No Hardware Required)

You can run AeroVision on your development machine to iterate on the web UI and flight data pipeline without any hardware.

### Prerequisites

- **Elixir 1.17+** and **Erlang/OTP 27+** — [install via asdf](https://github.com/asdf-vm/asdf) or [Homebrew](https://brew.sh)
- **Go 1.22+** — [golang.org/dl](https://golang.org/dl/)
- **Git**

### Quick Start

```bash
# Clone the repo
git clone https://github.com/yourusername/aerovision
cd aerovision

# Install Elixir dependencies and set up assets
mix deps.get
mix assets.setup
mix assets.build

# Build the Go display driver in emulator mode (no LED hardware needed)
cd go_src && make build-host && cd ..

# Start the server
iex -S mix phx.server
```

Visit **[http://localhost:4000](http://localhost:4000)** — the setup wizard will guide you through configuration.

> **Note**: In development mode, WiFi management (VintageNet) is disabled. The WiFi step of the setup wizard can be skipped.

### Terminal Display Preview

Preview exactly what the LED panel will show, rendered in your terminal using ANSI true color and Unicode half-block characters:

```bash
# Show a sample flight card
./priv/led_driver --demo
```

Output looks like:
```
AeroVision 64×64 Preview
┌────────────────────────────────────────────────────────────────┐
│  ████  AA 1234                                                 │
│  █  █  B738                                                    │
│  ████  RDU▸SLC                                                 │
│────────────────────────────────────────────────────────────────│
│  FL350                                              450KT      │
│  045°                                                -500      │
│  14:30                                              18:45      │
│  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░         │
└────────────────────────────────────────────────────────────────┘
 Brightness: 80%  Press Ctrl+C to exit
```

You can also pipe JSON commands to the binary for testing:

```bash
echo '{"cmd":"flight_card","flight":"UA 456","aircraft":"A321","route_origin":"SFO","route_dest":"ORD","altitude_ft":37000,"speed_kt":510,"bearing_deg":90,"progress":0.31}' \
  | ./priv/led_driver --preview
```

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

For the Go cross-compilation, you'll need the ARM toolchain:

```bash
# macOS
brew install arm-linux-gnueabihf-binutils

# Ubuntu/Debian
sudo apt install gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf
```

### Step 1: Build the rpi-rgb-led-matrix C Library for ARM

The Go LED driver links against the `hzeller/rpi-rgb-led-matrix` C++ library. You need to cross-compile it for ARM first:

```bash
# Clone the library
git clone https://github.com/hzeller/rpi-rgb-led-matrix.git /tmp/rpi-rgb-led-matrix
cd /tmp/rpi-rgb-led-matrix

# Cross-compile the static library for ARMv7
make CC=arm-linux-gnueabihf-gcc CXX=arm-linux-gnueabihf-g++ \
     CXXFLAGS="-march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard" \
     lib/librgbmatrix.a

# Create the directory structure the Makefile expects
sudo mkdir -p /opt/rpi-rgb-led-matrix/lib /opt/rpi-rgb-led-matrix/include
sudo cp lib/librgbmatrix.a /opt/rpi-rgb-led-matrix/lib/
sudo cp include/*.h /opt/rpi-rgb-led-matrix/include/
```

### Step 2: Build the Go LED Driver for ARM

```bash
cd go_src
RPI_RGB_LIB=/opt/rpi-rgb-led-matrix make build-arm
```

This produces `priv/led_driver` — the ARM binary that will be included in the Nerves firmware image.

### Step 3: Build the Nerves Firmware

```bash
# Set the target to Raspberry Pi Zero 2 W
export MIX_TARGET=rpi0_2

# Fetch target-specific dependencies
mix deps.get

# Compile and package the firmware
mix firmware
```

This produces `_build/rpi0_2_dev/nerves/images/aerovision.fw`.

### Step 4: Flash to SD Card

Insert your microSD card and run:

```bash
mix firmware.burn
```

Mix will detect available drives and ask you to confirm. **Double-check the drive path before confirming** — flashing the wrong drive will erase it.

Alternatively, use `fwup` directly:

```bash
fwup _build/rpi0_2_dev/nerves/images/aerovision.fw
```

### Over-the-Air Updates (OTA)

After the first flash, you can push updates over WiFi without removing the SD card:

```bash
export MIX_TARGET=rpi0_2
mix firmware
mix upload aerovision.local
```

The device will reboot into the new firmware automatically.

---

## First Boot & Configuration

### Step 1: Power On

Insert the flashed SD card into the Pi, connect the SEENGREAT HAT (with panel and power), and power on via the HAT's barrel jack. The LED panel may briefly flash white during boot — this is normal.

Boot takes approximately **30–60 seconds** on first power-on.

### Step 2: Connect to the Setup Network

Since no WiFi credentials are configured yet, the device starts in **AP mode**:

1. On your phone or laptop, open WiFi settings
2. Connect to the network: **`AeroVision-Setup`** (open network, no password)
3. Your device will be assigned an IP in the `192.168.24.x` range

### Step 3: Open the Setup Wizard

Navigate to **[http://192.168.24.1](http://192.168.24.1)** in your browser.

The setup wizard walks you through three steps:

**Step 1 — WiFi**
Enter your home network SSID and password. The device will connect and the AP network will disappear. You may be redirected automatically; if not, connect your device back to your home WiFi and navigate to **[http://aerovision.local](http://aerovision.local)**.

**Step 2 — API Keys**
Enter your OpenSky Client ID and Secret (required) and optionally your FlightAware AeroAPI key. See the [API Keys](#api-keys) section above for how to obtain these.

**Step 3 — Location**
Enter your latitude, longitude, and a search radius in kilometers. AeroVision will scan for all flights within this radius of your location. Default: Raleigh, NC (35.78, -78.64), 50km radius.

> **Tip**: Use [latlong.net](https://www.latlong.net/) or Google Maps (right-click → "What's here?") to find your coordinates.

After completing setup, the LED panel will begin displaying live flight data within 15–30 seconds.

### Physical Button Usage

| Press | Action |
|-------|--------|
| **Short press** (<1 second) | Show QR code with device IP on the LED panel for 10 seconds |
| **Long press** (≥3 seconds) | Force device back into AP/setup mode |

The QR code is useful when the device's IP address changes (e.g., after a router restart) and you can't reach `aerovision.local`.

---

## Configuration

All settings are accessible at **[http://aerovision.local/settings](http://aerovision.local/settings)**. Settings are persisted to the device's writable `/data` partition and survive firmware updates and reboots.

| Setting | Default | Description |
|---------|---------|-------------|
| **Location** — Latitude | 35.7796 | Center of the search area |
| **Location** — Longitude | -78.6382 | Center of the search area |
| **Location** — Radius | 50 km | How far out to scan for flights |
| **Display Mode** | Nearby | `Nearby` = all flights in radius; `Tracked` = specific callsigns only |
| **Tracked Flights** | (empty) | Callsigns to monitor in Tracked mode (e.g., `AAL123`) |
| **Airline Filters** | (empty) | Filter Nearby mode by ICAO operator prefix (e.g., `AAL` for American Airlines) |
| **Brightness** | 80% | LED panel brightness (1–100) |
| **Cycle Interval** | 8 seconds | How long each flight is displayed before cycling |
| **OpenSky Client ID** | (none) | OAuth2 client ID from opensky-network.org |
| **OpenSky Client Secret** | (none) | OAuth2 client secret from opensky-network.org |
| **AeroAPI Key** | (none) | FlightAware AeroAPI key (optional enrichment) |
| **WiFi SSID** | (none) | Home network name |

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

A full list is available at [airlinecodes.co.uk](https://www.airlinecodes.co.uk/).

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Nerves (Linux on Pi)                      │
│                                                             │
│  AeroVision.Application (OTP Supervisor)                    │
│    ├── Config.Store          CubDB on /data partition       │
│    ├── Network.Manager       WiFi + AP fallback (VintageNet)│
│    ├── Flight.AeroAPI        FlightAware enrichment cache   │
│    ├── Flight.OpenSky        ADS-B poller (15s interval)    │
│    ├── Flight.Tracker        State aggregation + filtering  │
│    ├── Display.Driver        Go port manager (packet:4)     │
│    ├── Display.Renderer      Frame builder (64×64 layout)   │
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
1. `OpenSky` polls the OpenSky Network API every 15 seconds, filtering by bounding box
2. `Tracker` merges new state vectors with enriched data from `AeroAPI`
3. `Renderer` builds a `flight_card` JSON command and sends it to `Driver`
4. `Driver` forwards the command to the Go binary via stdin (4-byte length-prefixed)
5. The Go binary renders the flight card onto the LED matrix

**Web UI**: The Phoenix LiveView app subscribes to PubSub topics and updates in real time as flights change. No page refresh needed.

For full technical details, see [CLAUDE.md](CLAUDE.md).

---

## Troubleshooting

### LED panel doesn't light up
- Verify the barrel jack power supply is 5V and at least 4A
- Check that the HUB75 ribbon cable is connected to the **input** port on the panel (not output)
- Confirm the SEENGREAT HAT is fully seated on the Pi's 40-pin GPIO header
- Try a different power supply — cheap supplies often can't sustain 4A

### LED panel shows garbage / flickering pixels
- Add `--led-slowdown-gpio=2` (or higher) to slow down GPIO switching for slower Pi models
- Verify audio is disabled: check that `dtparam=audio=off` is in `/boot/config.txt` (it should be set by the Nerves rootfs overlay)
- Try `--led-no-hardware-pulse` if not already set (it is by default for the SEENGREAT HAT)

### No flights appearing on the display
1. Check that your OpenSky credentials are entered correctly in Settings
2. Verify your location is set correctly — the default is Raleigh, NC
3. Try increasing the radius (e.g., 100km for rural areas)
4. Check if OpenSky is up: `curl "https://opensky-network.org/api/states/all?lamin=35&lomin=-79&lamax=36&lomax=-77"` from a terminal
5. In IEx on the device: `AeroVision.Flight.OpenSky.fetch_now()`

### Can't connect to aerovision.local
- mDNS/Bonjour must be enabled on your laptop. macOS has this by default. On Windows, install [Bonjour for Windows](https://support.apple.com/kb/DL999).
- On Linux: `sudo apt install avahi-daemon`
- Alternatively, short-press the physical button to show the QR code with the direct IP address on the LED panel

### WiFi won't connect / device won't appear on network
- Long-press the physical button (≥3 seconds) to force AP mode
- Connect to `AeroVision-Setup` and reconfigure WiFi at `http://192.168.24.1`
- Double-check that the SSID and password are correct (case-sensitive)

### Web UI is slow / unresponsive
The Pi Zero 2 W has a 1GHz quad-core ARM Cortex-A53 CPU and 512MB RAM. The web UI should be responsive for configuration. If it's very slow, the device may be under memory pressure — try reducing the OpenSky poll radius to limit the number of flights being tracked.

### OTA update fails
- Ensure the device and your laptop are on the same network
- Try using the IP address directly: `mix upload 192.168.1.x` instead of `aerovision.local`
- SSH into the device to check available space: `nerves_ssh` or via `mix ssh`

---

## Project Structure

```
aerovision/
├── lib/
│   ├── aerovision/
│   │   ├── application.ex        # OTP supervision tree
│   │   ├── config/store.ex       # CubDB persistent config
│   │   ├── network/manager.ex    # WiFi + AP mode (VintageNet)
│   │   ├── flight/
│   │   │   ├── opensky.ex        # OpenSky ADS-B poller
│   │   │   ├── aero_api.ex       # FlightAware enrichment
│   │   │   ├── tracker.ex        # State aggregation
│   │   │   └── geo_utils.ex      # Haversine, unit conversion
│   │   ├── display/
│   │   │   ├── driver.ex         # Go Port manager
│   │   │   └── renderer.ex       # Flight card frame builder
│   │   └── gpio/button.ex        # Physical button handler
│   └── aerovision_web/
│       └── live/
│           ├── dashboard_live.ex # Flight dashboard + setup wizard
│           ├── settings_live.ex  # Full configuration UI
│           └── setup_live.ex     # WiFi-only setup page
├── go_src/
│   ├── Makefile
│   └── led_driver/
│       ├── main.go               # Entry point, flags, demo mode
│       ├── matrix.go             # Matrix interface
│       ├── matrix_real.go        # hzeller rpi-rgb-led-matrix (target)
│       ├── matrix_stub.go        # Silent stub (emulator)
│       ├── matrix_term.go        # ANSI terminal preview (emulator)
│       ├── protocol.go           # 4-byte length-prefixed JSON IPC
│       ├── display.go            # 64×64 flight card rendering
│       ├── fonts.go              # 5×7 and 4×5 bitmap fonts
│       └── qrcode.go             # QR code generation
├── config/
│   ├── config.exs                # Shared configuration
│   ├── dev.exs                   # Development overrides
│   ├── host.exs                  # Host (non-Nerves) overrides
│   └── rpi0_2.exs                # Nerves target configuration
├── assets/
│   ├── js/app.js                 # Phoenix LiveView JS entrypoint
│   ├── css/app.css               # Tailwind v4 CSS
│   └── vendor/                   # topbar, heroicons plugin
├── rootfs_overlay/               # Files overlaid onto the Nerves root FS
└── priv/
    └── led_driver                # Compiled Go binary (included in firmware)
```

---

## License

MIT License — see [LICENSE](LICENSE) for details.
