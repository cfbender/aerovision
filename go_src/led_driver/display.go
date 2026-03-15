package main

import (
	"fmt"
	"log"
)

// Display owns the rendering logic for the 64×64 LED panel.
type Display struct {
	matrix Matrix
	width  int
	height int
}

// NewDisplay creates a Display backed by the given matrix.
func NewDisplay(matrix Matrix, width, height int) *Display {
	return &Display{
		matrix: matrix,
		width:  width,
		height: height,
	}
}

// HandleCommand dispatches an inbound Command to the appropriate renderer.
func (d *Display) HandleCommand(cmd Command) {
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

	// ── Airline logo (16×16) at (2, 2) ───────────────────────────────────
	drawPlaneIcon(d.matrix, 2, 2)

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
