package main

import (
	"fmt"
	"log"
	"math/rand"
	"sync"
	"time"
)

// Display owns the rendering logic for the 64×64 LED panel.
type Display struct {
	matrix   Matrix
	width    int
	height   int
	animStop chan struct{} // non-nil when an animation goroutine is running
	animMu   sync.Mutex
}

// NewDisplay creates a Display backed by the given matrix.
func NewDisplay(matrix Matrix, width, height int) *Display {
	return &Display{
		matrix: matrix,
		width:  width,
		height: height,
	}
}

// stopAnim cancels any running animation goroutine and waits for it to exit.
func (d *Display) stopAnim() {
	d.animMu.Lock()
	ch := d.animStop
	d.animStop = nil
	d.animMu.Unlock()
	if ch != nil {
		close(ch)
		// Give the goroutine a moment to exit cleanly
		time.Sleep(20 * time.Millisecond)
	}
}

// HandleCommand dispatches an inbound Command to the appropriate renderer.
func (d *Display) HandleCommand(cmd Command) {
	// Stop any running animation before processing the next command,
	// unless the next command is itself an animation.
	if cmd.Cmd != "scan_anim" && cmd.Cmd != "ping" {
		d.stopAnim()
	}

	switch cmd.Cmd {
	case "flight_card":
		d.renderFlightCard(cmd)
	case "qr":
		d.renderQRCode(cmd)
	case "clear":
		d.renderClear()
		sendResponse("ok", "")
	case "text":
		d.renderText(cmd)
		sendResponse("ok", "")
	case "brightness":
		d.setBrightness(cmd)
		sendResponse("ok", "")
	case "scan_anim":
		d.renderScanAnim()
		sendResponse("ok", "")
	case "ap_screen":
		d.renderAPScreen(cmd)
		sendResponse("ok", "")
	case "connecting_screen":
		d.renderConnectingScreen(cmd)
		sendResponse("ok", "")
	case "ping":
		sendResponse("ok", "")
	default:
		log.Printf("Unknown command: %q", cmd.Cmd)
		sendResponse("error", fmt.Sprintf("unknown command: %s", cmd.Cmd))
	}
}

// renderFlightCard renders the full 64×64 TheFlightWall-style flight card.
func (d *Display) renderFlightCard(cmd Command) {
	d.matrix.Clear()

	// ══════════════════════════════════════════════════════════════════════
	// UPPER CARD — 5×7 font, logo + 3 text rows with 4px gaps
	// ══════════════════════════════════════════════════════════════════════

	// ── Airline logo (16×16) at (0, 12) ──────────────────────────────────
	drawPlaneIcon(d.matrix, 0, 12)

	// ── Flight number at (20, 2) — white ─────────────────────────────────
	if cmd.Flight != "" {
		drawString(d.matrix, 20, 2, truncate(cmd.Flight, 7), 255, 255, 255)
	}

	// ── Aircraft type at (20, 13) — gray ─────────────────────────────────
	if cmd.Aircraft != "" {
		drawString(d.matrix, 20, 13, truncate(cmd.Aircraft, 7), 150, 150, 150)
	}

	// ── Route at (20, 24) — white, format "RDU▸SLC" ─────────────────────
	if cmd.RouteOrigin != "" || cmd.RouteDest != "" {
		origin := truncate(cmd.RouteOrigin, 4)
		dest := truncate(cmd.RouteDest, 4)
		routeStr := origin + "\u25b8" + dest
		drawString(d.matrix, 20, 24, truncate(routeStr, 7), 255, 255, 255)
	}

	// ══════════════════════════════════════════════════════════════════════
	// DIVIDER
	// ══════════════════════════════════════════════════════════════════════

	for x := 2; x <= 61; x++ {
		d.matrix.SetPixel(x, 35, 40, 40, 40)
	}

	// ══════════════════════════════════════════════════════════════════════
	// LOWER CARD — 4×5 small font, 3 data rows with 2px gaps
	// ══════════════════════════════════════════════════════════════════════

	// ── Telemetry row 1 at y=38: altitude (left) + speed (right) ─────────
	if cmd.AltitudeFt != nil && *cmd.AltitudeFt != 0 {
		altStr := formatAltitude(*cmd.AltitudeFt)
		drawStringSmall(d.matrix, 2, 38, altStr, 0, 200, 100)
	}
	if cmd.SpeedKt != nil && *cmd.SpeedKt != 0 {
		spdStr := fmt.Sprintf("%dKT", *cmd.SpeedKt)
		spdX := 62 - stringWidthSmall(spdStr)
		drawStringSmall(d.matrix, spdX, 38, spdStr, 0, 200, 100)
	}

	// ── Telemetry row 2 at y=45: bearing (left) + vrate (right) ──────────
	if cmd.BearingDeg != nil {
		hdgStr := fmt.Sprintf("%03d", *cmd.BearingDeg)
		drawStringSmall(d.matrix, 2, 45, hdgStr, 0, 200, 100)
		// Draw degree symbol
		drawCharSmall(d.matrix, 2+stringWidthSmall(hdgStr), 45, '°', 0, 200, 100)
	}
	// Vertical rate (right-aligned) — red if descending, green if climbing
	if cmd.VRateFpm != nil && *cmd.VRateFpm != 0 {
		vr := *cmd.VRateFpm
		var vsStr string
		var vr2, vg2 uint8
		if vr > 0 {
			vsStr = fmt.Sprintf("+%d", vr)
			vr2, vg2 = 0, 200
		} else {
			vsStr = fmt.Sprintf("%d", vr)
			vr2, vg2 = 220, 40
		}
		vsX := 62 - stringWidthSmall(vsStr)
		drawStringSmall(d.matrix, vsX, 45, vsStr, vr2, vg2, 0)
	}

	// ── Times row at y=52: departure (left) + arrival (right) ────────────
	if cmd.DepTime != "" {
		drawStringSmall(d.matrix, 2, 52, cmd.DepTime, 120, 120, 120)
	}
	if cmd.ArrTime != "" {
		arrX := 62 - stringWidthSmall(cmd.ArrTime)
		drawStringSmall(d.matrix, arrX, 52, cmd.ArrTime, 120, 120, 120)
	}

	// ── Progress bar at y=60-61 (2px tall), x=2..61 (60px wide) ─────────
	barX0, barX1 := 2, 61
	barWidth := barX1 - barX0 + 1 // 60 pixels
	progress := cmd.Progress
	if progress < 0 {
		progress = 0
	}
	if progress > 1 {
		progress = 1
	}
	filledPixels := int(float64(barWidth) * progress)

	for x := barX0; x <= barX1; x++ {
		var pr, pg, pb uint8
		if x-barX0 < filledPixels {
			pr, pg, pb = 0, 255, 80 // bright green
		} else {
			pr, pg, pb = 30, 30, 30 // dark gray
		}
		d.matrix.SetPixel(x, 60, pr, pg, pb)
		d.matrix.SetPixel(x, 61, pr, pg, pb)
	}

	d.matrix.Render()
	sendResponse("ok", "")
}

// renderClear fills the entire display with black.
func (d *Display) renderClear() {
	d.matrix.Clear()
	d.matrix.Render()
}

// renderText draws arbitrary text for debugging purposes.
func (d *Display) renderText(cmd Command) {
	r := uint8(cmd.Color[0])
	g := uint8(cmd.Color[1])
	b := uint8(cmd.Color[2])
	if r == 0 && g == 0 && b == 0 {
		r, g, b = 255, 255, 255 // default to white if no color specified
	}
	drawString(d.matrix, cmd.X, cmd.Y, cmd.Text, r, g, b)
	d.matrix.Render()
}

// setBrightness adjusts display brightness.
func (d *Display) setBrightness(cmd Command) {
	v := cmd.Value
	if v < 0 {
		v = 0
	}
	if v > 100 {
		v = 100
	}
	d.matrix.SetBrightness(v)
}

// planeSprites holds the 4 rotated variants of the plane icon, one per
// diagonal heading. Index matches the animDir constants below.
var planeSprites = buildPlaneSprites()

func buildPlaneSprites() [4][16][16][3]uint8 {
	const n = 16
	type icon = [n][n][3]uint8
	ne := planeIcon // original: nose points NE (top-right)

	rotate90CW := func(src icon) icon {
		// 90° clockwise: new[col][n-1-row] = old[row][col]
		// Nose was top-right (row0,col15) → bottom-right (row15,col15) = SE
		var dst icon
		for row := 0; row < n; row++ {
			for col := 0; col < n; col++ {
				dst[col][n-1-row] = src[row][col]
			}
		}
		return dst
	}

	rotate90CCW := func(src icon) icon {
		// 90° counter-clockwise: new[n-1-col][row] = old[row][col]
		// Nose was top-right (row0,col15) → top-left (row0,col0) = NW
		var dst icon
		for row := 0; row < n; row++ {
			for col := 0; col < n; col++ {
				dst[n-1-col][row] = src[row][col]
			}
		}
		return dst
	}

	rotate180 := func(src icon) icon {
		// 180°: new[n-1-row][n-1-col] = old[row][col]
		// Nose was top-right (row0,col15) → bottom-left (row15,col0) = SW
		var dst icon
		for row := 0; row < n; row++ {
			for col := 0; col < n; col++ {
				dst[n-1-row][n-1-col] = src[row][col]
			}
		}
		return dst
	}

	return [4]icon{
		ne,              // 0 = NE: dx=+1, dy=-1
		rotate90CW(ne),  // 1 = SE: dx=+1, dy=+1
		rotate180(ne),   // 2 = SW: dx=-1, dy=+1
		rotate90CCW(ne), // 3 = NW: dx=-1, dy=-1
	}
}

// drawPlaneSprite draws a rotated plane sprite at (x, y).
func drawPlaneSprite(m Matrix, x, y, dir int) {
	sprite := planeSprites[dir]
	for row := 0; row < 16; row++ {
		for col := 0; col < 16; col++ {
			px := sprite[row][col]
			if px[0] != 0 || px[1] != 0 || px[2] != 0 {
				m.SetPixel(x+col, y+row, px[0], px[1], px[2])
			}
		}
	}
}

// animPass holds the parameters for one crossing of the display.
type animPass struct {
	startX, startY int // sprite top-left at t=0 (may be off-screen)
	endX, endY     int // sprite top-left at t=1 (may be off-screen)
	dir            int // sprite rotation index (0=NE,1=SE,2=SW,3=NW)
}

// randomPass picks a random diagonal direction and a random starting position
// along the entry edge, returning a fully-specified animPass.
func randomPass() animPass {
	const s = 16 // sprite size
	dir := rand.Intn(4)

	// For each direction, the plane enters from one pair of edges.
	// Entry positions are randomised along the entry edge so the plane
	// crosses somewhere in the middle half of the display (not always corner).
	switch dir {
	case 0: // NE: enter bottom-left, exit top-right; dx=+, dy=-
		// Entry: x off left (-s), y randomised in lower half
		sy := 32 + rand.Intn(17) // 32..48
		return animPass{-s, sy, 64, sy - (64 + s), dir}
	case 1: // SE: enter top-left, exit bottom-right; dx=+, dy=+
		// Entry: x off left (-s), y randomised in upper half
		sy := rand.Intn(17) // 0..16
		return animPass{-s, sy, 64, sy + (64 + s), dir}
	case 2: // SW: enter top-right, exit bottom-left; dx=-, dy=+
		// Entry: x off right (64), y randomised in upper half
		sy := rand.Intn(17) // 0..16
		return animPass{64, sy, -s, sy + (64 + s), dir}
	default: // NW: enter bottom-right, exit top-left; dx=-, dy=-
		// Entry: x off right (64), y randomised in lower half
		sy := 32 + rand.Intn(17) // 32..48
		return animPass{64, sy, -s, sy - (64 + s), dir}
	}
}

// renderConnectingScreen shows a "Connecting to <SSID>" message while
// VintageNet is associating with a new WiFi network.
func (d *Display) renderConnectingScreen(cmd Command) {
	d.matrix.Clear()

	cyan := [3]uint8{0, 200, 220}
	white := [3]uint8{255, 255, 255}
	gray := [3]uint8{120, 120, 120}

	drawStringSmall(d.matrix, 2, 8, "Connecting to:", gray[0], gray[1], gray[2])

	ssid := cmd.SSID
	if ssid == "" {
		ssid = "WiFi"
	}

	// Center the SSID; split at hyphen if too wide
	ssidWidth := stringWidthSmall(ssid)
	if ssidWidth <= 60 {
		x := (64 - ssidWidth) / 2
		drawStringSmall(d.matrix, x, 22, ssid, white[0], white[1], white[2])
	} else {
		line1, line2 := ssid, ""
		for i, ch := range ssid {
			if ch == '-' && i > 0 {
				line1 = ssid[:i]
				line2 = ssid[i:]
				break
			}
		}
		w1 := stringWidthSmall(line1)
		drawStringSmall(d.matrix, (64-w1)/2, 18, line1, white[0], white[1], white[2])
		if line2 != "" {
			w2 := stringWidthSmall(line2)
			drawStringSmall(d.matrix, (64-w2)/2, 26, line2, white[0], white[1], white[2])
		}
	}

	// Divider
	for x := 2; x <= 61; x++ {
		d.matrix.SetPixel(x, 36, 40, 40, 40)
	}

	drawStringSmall(d.matrix, 2, 42, "This page will", gray[0], gray[1], gray[2])
	drawStringSmall(d.matrix, 2, 49, "disconnect.", gray[0], gray[1], gray[2])
	drawStringSmall(d.matrix, 2, 56, "aerovision.local", cyan[0], cyan[1], cyan[2])

	d.matrix.Render()
}

// renderScanAnim starts a looping animation: the plane flies across the
// display on a random diagonal heading, with a new random direction and
// entry position chosen on each pass. The sprite is rotated to always
// face the direction of travel. Runs until the next command cancels it.
//
// If the animation is already running this is a no-op — the existing
// goroutine continues uninterrupted, avoiding a disruptive restart.
func (d *Display) renderScanAnim() {
	d.animMu.Lock()
	already := d.animStop != nil
	d.animMu.Unlock()
	if already {
		return
	}

	stop := make(chan struct{})
	d.animMu.Lock()
	d.animStop = stop
	d.animMu.Unlock()

	go func() {
		const (
			steps   = 80 // frames per pass
			frameMs = 40 // ~25 fps
		)

		pass := randomPass()
		step := 0

		ticker := time.NewTicker(frameMs * time.Millisecond)
		defer ticker.Stop()

		for {
			select {
			case <-stop:
				return
			case <-ticker.C:
				t := float64(step) / float64(steps)
				x := int(float64(pass.startX) + t*float64(pass.endX-pass.startX))
				y := int(float64(pass.startY) + t*float64(pass.endY-pass.startY))

				d.matrix.Clear()

				// Subtle trail — 3 ghost dots behind the sprite centre
				trailColors := [][3]uint8{
					{0, 80, 100},
					{0, 120, 140},
					{0, 160, 180},
				}
				for i, tc := range trailColors {
					trailT := t - float64(i+1)*0.06
					if trailT >= 0 {
						tx := int(float64(pass.startX) + trailT*float64(pass.endX-pass.startX))
						ty := int(float64(pass.startY) + trailT*float64(pass.endY-pass.startY))
						cx := tx + 8
						cy := ty + 8
						if cx >= 0 && cx < 64 && cy >= 0 && cy < 64 {
							d.matrix.SetPixel(cx, cy, tc[0], tc[1], tc[2])
						}
					}
				}

				drawPlaneSprite(d.matrix, x, y, pass.dir)
				d.matrix.Render()

				step++
				if step > steps {
					step = 0
					pass = randomPass()
				}
			}
		}
	}()
}

// renderAPScreen displays the WiFi setup screen when in AP mode.
// Static content fills the top half; the URL scrolls on the bottom half.
func (d *Display) renderAPScreen(cmd Command) {
	cyan := [3]uint8{0, 200, 220}
	white := [3]uint8{255, 255, 255}
	gray := [3]uint8{120, 120, 120}
	yellow := [3]uint8{255, 200, 0}

	ssid := cmd.SSID
	if ssid == "" {
		ssid = "AeroVision-Setup"
	}
	ip := cmd.IP
	if ip == "" {
		ip = "192.168.24.1"
	}
	url := "http://" + ip

	// drawStatic renders everything except the scrolling URL row.
	drawStatic := func(scrollX int) {
		d.matrix.Clear()

		// Header
		drawStringSmall(d.matrix, 2, 2, "CONNECT TO:", cyan[0], cyan[1], cyan[2])

		// SSID — split at hyphen if too wide
		ssidWidth := stringWidthSmall(ssid)
		if ssidWidth <= 60 {
			drawStringSmall(d.matrix, (64-ssidWidth)/2, 14, ssid, yellow[0], yellow[1], yellow[2])
		} else {
			line1, line2 := ssid, ""
			for i, ch := range ssid {
				if ch == '-' && i > 0 {
					line1 = ssid[:i]
					line2 = ssid[i:]
					break
				}
			}
			w1 := stringWidthSmall(line1)
			drawStringSmall(d.matrix, (64-w1)/2, 10, line1, yellow[0], yellow[1], yellow[2])
			if line2 != "" {
				w2 := stringWidthSmall(line2)
				drawStringSmall(d.matrix, (64-w2)/2, 17, line2, yellow[0], yellow[1], yellow[2])
			}
		}

		// Divider
		for x := 2; x <= 61; x++ {
			d.matrix.SetPixel(x, 27, 40, 40, 40)
		}

		// "Open browser:" label
		drawStringSmall(d.matrix, 2, 32, "Open browser:", gray[0], gray[1], gray[2])

		// Scrolling URL — clipped to display width
		drawStringSmallClipped(d.matrix, scrollX, 42, url, 0, 64, white[0], white[1], white[2])

		// "No password" note
		drawStringSmall(d.matrix, 2, 54, "No password", gray[0], gray[1], gray[2])

		d.matrix.Render()
	}

	urlWidth := stringWidthSmall(url)

	// If the URL fits, just draw it statically and return.
	if urlWidth <= 60 {
		drawStatic((64 - urlWidth) / 2)
		return
	}

	// URL is too wide — scroll it. The animation goroutine handles this.
	d.stopAnim()

	stop := make(chan struct{})
	d.animMu.Lock()
	d.animStop = stop
	d.animMu.Unlock()

	go func() {
		// Scroll: starts fully off the right edge, moves left until fully off left.
		// Then pauses briefly and loops.
		const (
			frameMs = 50   // ~20fps scroll
			pauseMs = 1000 // pause at start before scrolling
		)
		startX := 64
		endX := -(urlWidth + 4)

		ticker := time.NewTicker(frameMs * time.Millisecond)
		defer ticker.Stop()

		scrollX := startX
		pausing := true
		pauseFrames := pauseMs / frameMs

		for {
			select {
			case <-stop:
				d.matrix.Clear()
				d.matrix.Render()
				return
			case <-ticker.C:
				if pausing {
					drawStatic(startX)
					pauseFrames--
					if pauseFrames <= 0 {
						pausing = false
					}
					continue
				}

				drawStatic(scrollX)
				scrollX--

				if scrollX < endX {
					scrollX = startX
					pausing = true
					pauseFrames = pauseMs / frameMs
				}
			}
		}
	}()
}

// ── Formatting helpers ────────────────────────────────────────────────────

// formatAltitude formats an altitude in feet.
// At or above 18,000ft: "FL350" (flight level).
// Below 18,000ft: "12,500" (with comma thousands separator).
func formatAltitude(ft int) string {
	if ft < 0 {
		ft = -ft // absolute value for display
	}
	if ft >= 18000 {
		fl := (ft + 50) / 100 // round to nearest flight level
		return fmt.Sprintf("FL%d", fl)
	}
	// Format with comma for thousands
	if ft >= 1000 {
		thousands := ft / 1000
		hundreds := ft % 1000
		return fmt.Sprintf("%d,%03d", thousands, hundreds)
	}
	return fmt.Sprintf("%d", ft)
}

// truncate returns s limited to n runes.
func truncate(s string, n int) string {
	runes := []rune(s)
	if len(runes) <= n {
		return s
	}
	return string(runes[:n])
}
