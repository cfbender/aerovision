package main

// logos.go — Airline logo pixel art and the dispatch system for the LED matrix.
//
// Each logo is a [16][16][3]uint8 array where each element is an {r, g, b}
// colour triple. A zero value {0, 0, 0} is treated as transparent (the pixel
// is not written to the matrix), matching the same convention used by
// buildPlaneIcon() in fonts.go.
//
// Adding a new airline logo:
//  1. Write a buildXXXLogo() function that returns a [16][16][3]uint8.
//  2. Register it in the init() function below with its ICAO operator code.
//
// The ICAO operator code (e.g. "DAL" for Delta Air Lines) is the three-letter
// designator assigned by ICAO and used in flight identifiers such as "DAL123".

// ── Delta Air Lines logo ─────────────────────────────────────────────────────
//
// The Delta logo is an upward-pointing delta/arrow silhouette split vertically
// down the centreline:
//   • Columns 0-7  → bright red  {200, 16, 46}
//   • Columns 8-15 → dark crimson {139, 26, 43}
//
// Shape layout (# = coloured pixel, . = transparent):
//
//	col:  0123456789ABCDEF
//	row0: .......##.......   ← apex (2 px)
//	row1: ......####......
//	row2: .....######.....
//	row3: ....########....
//	row4: ...##########...
//	row5: ..############..
//	row6: .##############.   ← solid (14 px)
//	row7: ######....######   ← notch begins (4 px gap)
//	row8: #####......#####   ← notch widens (6 px gap)
//	row9: ................   ← transparent gap
//	rowA: .......##.......   ← lower chevron tip
//	rowB: ..############..   ← solid band
//	rowC: .##############.   ← wider band
//	rowD: ################   ← full-width base
//	rowE: ................
//	rowF: ................
//
// The upper section is a chevron: a solid triangle from rows 0–5 with a
// triangular notch cut from the bottom in rows 6–8. The lower section is a
// solid widening band with a small pointed tip at row 10.

// buildDeltaLogo constructs and returns the 16×16 Delta Air Lines logo.
func buildDeltaLogo() [16][16][3]uint8 {
	type px = [3]uint8

	red := px{200, 16, 46}     // left half  — bright red
	crimson := px{139, 26, 43} // right half — dark crimson

	var icon [16][16][3]uint8

	// set writes colour to icon[row][col], guarding against out-of-bounds.
	set := func(row, col int, color px) {
		if row >= 0 && row < 16 && col >= 0 && col < 16 {
			icon[row][col] = color
		}
	}

	// colorFor returns the correct half-colour based on the column position.
	// Columns 0-7 are the left (red) half; columns 8-15 are the right (crimson).
	colorFor := func(col int) px {
		if col < 8 {
			return red
		}
		return crimson
	}

	// ── Upper chevron (rows 0-8) ─────────────────────────────────────────
	// Solid expanding triangle from rows 0-5, then a V-shaped notch is cut
	// from the bottom centre in rows 6-8 to form the chevron shape.

	// Rows 0-5: solid triangle, apex at top-centre expanding 1 px each side.
	solidRows := []struct{ row, colStart, colEnd int }{
		{0, 7, 8},  // 2 px wide
		{1, 6, 9},  // 4 px wide
		{2, 5, 10}, // 6 px wide
		{3, 4, 11}, // 8 px wide
		{4, 3, 12}, // 10 px wide
		{5, 2, 13}, // 12 px wide
		{6, 1, 14}, // 14 px wide
	}
	for _, r := range solidRows {
		for col := r.colStart; col <= r.colEnd; col++ {
			set(r.row, col, colorFor(col))
		}
	}

	// Rows 7-8: chevron arms with a growing centre notch.
	// Row 7: left arm cols 0-5, gap 6-9, right arm cols 10-15
	// Row 8: left arm cols 0-4, gap 5-10, right arm cols 11-15
	notchRows := []struct{ row, leftStart, leftEnd, rightStart, rightEnd int }{
		{7, 0, 5, 10, 15},
		{8, 0, 4, 11, 15},
	}
	for _, r := range notchRows {
		for col := r.leftStart; col <= r.leftEnd; col++ {
			set(r.row, col, colorFor(col))
		}
		for col := r.rightStart; col <= r.rightEnd; col++ {
			set(r.row, col, colorFor(col))
		}
	}

	// Row 9: transparent gap — no pixels written.

	// ── Lower chevron (rows 10-13) ───────────────────────────────────────
	// Small pointed tip at row 10, then a solid widening band.
	lowerRows := []struct{ row, colStart, colEnd int }{
		{10, 7, 8},  // 2 px tip
		{11, 2, 13}, // 12 px band
		{12, 1, 14}, // 14 px band
		{13, 0, 15}, // 16 px full-width base
	}
	for _, r := range lowerRows {
		for col := r.colStart; col <= r.colEnd; col++ {
			set(r.row, col, colorFor(col))
		}
	}

	// Rows 14-15 remain transparent.

	return icon
}

// ── Airline logo registry ─────────────────────────────────────────────────────

// airlineLogos maps ICAO operator codes (e.g. "DAL") to their 16×16 pixel-art
// logos. Populated once at program start by init().
var airlineLogos map[string][16][16][3]uint8

func init() {
	airlineLogos = map[string][16][16][3]uint8{
		"DAL": buildDeltaLogo(), // Delta Air Lines
	}
}

// ── Drawing helpers ───────────────────────────────────────────────────────────

// drawLogo draws any 16×16 logo array onto the matrix at position (x, y).
// Pixels with colour {0, 0, 0} are treated as transparent and skipped,
// preserving whatever background was already on the matrix at those positions.
func drawLogo(m Matrix, x, y int, logo [16][16][3]uint8) {
	for row := 0; row < 16; row++ {
		for col := 0; col < 16; col++ {
			px := logo[row][col]
			if px[0] != 0 || px[1] != 0 || px[2] != 0 {
				m.SetPixel(x+col, y+row, px[0], px[1], px[2])
			}
		}
	}
}

// drawAirlineLogo draws the 16×16 logo for the given ICAO operator code at
// position (x, y) on the matrix. If no logo is registered for that operator
// the generic airplane icon is drawn instead as a fallback.
func drawAirlineLogo(m Matrix, x, y int, operator string) {
	if logo, ok := airlineLogos[operator]; ok {
		drawLogo(m, x, y, logo)
		return
	}
	// Fallback: generic airplane silhouette from fonts.go.
	drawPlaneIcon(m, x, y)
}
