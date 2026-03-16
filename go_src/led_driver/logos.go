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

// ── United Airlines logo ─────────────────────────────────────────────────────
//
// The United logo is a stylised globe on a dark blue background. White arcs
// suggest latitude lines on a tilted sphere, with the globe occupying the
// lower-left portion of the square.
//
//   - Background → dark blue  {0, 40, 95}
//   - Globe arcs → white      {255, 255, 255}
//
// Shape layout (B = blue, w = white):
//
//	col:  0123456789ABCDEF
//	row0: BBBBBBBBBBBBBBBB
//	row1: BBBBwBBBBBBBBBBB
//	row2: BBBBBwwBBBBBBBBB
//	row3: BBwBBBBwwBBBBBBB
//	row4: BBBwBBBBBwBBBBBB
//	row5: wBBBwBBBBBwBBBBB
//	row6: BwBBBBwBBBBwBBBB
//	row7: BBwBBBBwBBBBBwBB
//	row8: wBBwBBBBwBBBBBBB
//	row9: BwBBBwBBBwBBBBBB
//	rowA: BBwBBBwBBBwBBBBB
//	rowB: wBBwBBBBwBBBwBBB
//	rowC: BwBBwBBBBwBBBwBB
//	rowD: wBwBBwBBBBwBBBwB
//	rowE: BwBwBBwBBBBwBBBw
//	rowF: wwBwBBwBBwBBwBBw

// buildUnitedLogo constructs and returns the 16×16 United Airlines globe logo.
func buildUnitedLogo() [16][16][3]uint8 {
	type px = [3]uint8

	blue := px{0, 40, 95}      // background — United dark blue
	white := px{255, 255, 255} // globe arcs

	// Start with a solid blue background.
	var icon [16][16][3]uint8
	for row := 0; row < 16; row++ {
		for col := 0; col < 16; col++ {
			icon[row][col] = blue
		}
	}

	// set writes colour to icon[row][col], guarding against out-of-bounds.
	set := func(row, col int, color px) {
		if row >= 0 && row < 16 && col >= 0 && col < 16 {
			icon[row][col] = color
		}
	}

	// White pixels forming the curved globe arcs.
	// Listed row-by-row as column positions.
	globePixels := []struct {
		row  int
		cols []int
	}{
		{1, []int{4}},
		{2, []int{5, 6}},
		{3, []int{2, 7, 8}},
		{4, []int{3, 9}},
		{5, []int{0, 4, 10}},
		{6, []int{1, 6, 11}},
		{7, []int{2, 7, 13}},
		{8, []int{0, 3, 8}},
		{9, []int{1, 5, 9}},
		{10, []int{2, 6, 10}},
		{11, []int{0, 3, 8, 12}},
		{12, []int{1, 4, 9, 13}},
		{13, []int{0, 2, 5, 10, 14}},
		{14, []int{1, 3, 6, 11, 15}},
		{15, []int{0, 1, 3, 6, 9, 12, 15}},
	}
	for _, rp := range globePixels {
		for _, col := range rp.cols {
			set(rp.row, col, white)
		}
	}

	return icon
}

// ── American Airlines logo ───────────────────────────────────────────────────
//
// The American Airlines logo is a stylised eagle head in profile, oriented
// diagonally from upper-left to lower-right. Three colour zones:
//   • Light blue {0, 170, 231} — upper wing (top of blade)
//   • Dark blue  {0, 75, 145}  — lower wing (bottom of blade)
//   • Silver     {190, 210, 225} — eagle head / connector
//   • Red        {209, 52, 42}  — beak / lower body
//
// Shape layout (L = light blue, D = dark blue, S = silver, R = red, . = transparent):
//
//	col:  0123456789ABCDEF
//	row0: .LLL............
//	row1: .LLLL...........
//	row2: ..LLLL..........
//	row3: ..DLLLL.........
//	row4: ...DDLLL........
//	row5: ....DDDL........
//	row6: .....DDD........
//	row7: ......DSSS......
//	row8: .......SSS......
//	row9: .......SSRR.....
//	rowA: ........RRRR....
//	rowB: ........RRRRR...
//	rowC: .........RRRRR..
//	rowD: ..........RRRRR.
//	rowE: ..........RRRRRR
//	rowF: ...........RRRRR

// buildAmericanLogo constructs and returns the 16×16 American Airlines eagle logo.
func buildAmericanLogo() [16][16][3]uint8 {
	type px = [3]uint8

	lightBlue := px{0, 170, 231} // upper wing
	darkBlue := px{0, 75, 145}   // lower wing
	silver := px{190, 210, 225}  // eagle head / connector
	red := px{209, 52, 42}       // beak / lower body

	var icon [16][16][3]uint8

	// set writes colour to icon[row][col], guarding against out-of-bounds.
	set := func(row, col int, color px) {
		if row >= 0 && row < 16 && col >= 0 && col < 16 {
			icon[row][col] = color
		}
	}

	// ── Blue wing (rows 0-6) ─────────────────────────────────────────────
	// Light blue at the top, transitioning to dark blue at the bottom.
	// The wing is a blade shape sweeping from upper-left downward.
	wingPixels := []struct {
		row   int
		cols  []int
		color px
	}{
		{0, []int{1, 2, 3}, lightBlue},
		{1, []int{1, 2, 3, 4}, lightBlue},
		{2, []int{2, 3, 4, 5}, lightBlue},
		{3, []int{2, 4, 5, 6, 7}, lightBlue},
		{3, []int{3}, darkBlue},
		{4, []int{5, 6, 7}, lightBlue},
		{4, []int{3, 4}, darkBlue},
		{5, []int{7}, lightBlue},
		{5, []int{4, 5, 6}, darkBlue},
		{6, []int{5, 6, 7}, darkBlue},
		{7, []int{6}, darkBlue},
	}
	for _, wp := range wingPixels {
		for _, col := range wp.cols {
			set(wp.row, col, wp.color)
		}
	}

	// ── Silver head (rows 7-9) ───────────────────────────────────────────
	silverPixels := []struct {
		row  int
		cols []int
	}{
		{7, []int{7, 8, 9}},
		{8, []int{7, 8, 9}},
		{9, []int{7, 8}},
	}
	for _, sp := range silverPixels {
		for _, col := range sp.cols {
			set(sp.row, col, silver)
		}
	}

	// ── Red beak (rows 9-15) ─────────────────────────────────────────────
	redPixels := []struct {
		row  int
		cols []int
	}{
		{9, []int{9, 10}},
		{10, []int{8, 9, 10, 11}},
		{11, []int{8, 9, 10, 11, 12}},
		{12, []int{9, 10, 11, 12, 13}},
		{13, []int{10, 11, 12, 13, 14}},
		{14, []int{10, 11, 12, 13, 14, 15}},
		{15, []int{11, 12, 13, 14, 15}},
	}
	for _, rp := range redPixels {
		for _, col := range rp.cols {
			set(rp.row, col, red)
		}
	}

	return icon
}

// ── Southwest Airlines logo ──────────────────────────────────────────────────
//
// The Southwest logo is a heart shape filled with three diagonal colour bands:
//   • Gold   {252, 181, 20} — upper-right wedge
//   • Red    {220, 41, 30}  — dominant middle band
//   • Blue   {48, 68, 139}  — lower-left area
//
// The band boundaries run diagonally (upper-left to lower-right). Each pixel
// inside the heart is assigned a colour based on (col - row):
//   col - row >= 3  → gold
//   col - row >= -4 → red
//   col - row <  -4 → blue
//
// Shape layout (Y = gold, R = red, B = blue, . = transparent):
//
//	col:  0123456789ABCDEF
//	row0: ................
//	row1: ..RRRR..RYYY....
//	row2: .RRRRRY.YYYYYY..
//	row3: .RRRRRRYYYYYYY..
//	row4: .RRRRRRRYYYYYYY.
//	row5: .RRRRRRRRYYYYY..
//	row6: .BRRRRRRRRRYYYY.
//	row7: ..BRRRRRRRRYYY..
//	row8: ..BBBRRRRRRRYY..
//	row9: ...BBBBRRRRRR...
//	rowA: ....BBBBRRRR....
//	rowB: .....BBBRR......
//	rowC: ......BBRR......
//	rowD: .......BB.......
//	rowE: ................
//	rowF: ................

// buildSouthwestLogo constructs and returns the 16×16 Southwest Airlines heart logo.
func buildSouthwestLogo() [16][16][3]uint8 {
	type px = [3]uint8

	gold := px{252, 181, 20} // upper-right wedge
	red := px{220, 41, 30}   // middle band
	blue := px{48, 68, 139}  // lower-left area

	var icon [16][16][3]uint8

	// set writes colour to icon[row][col], guarding against out-of-bounds.
	set := func(row, col int, color px) {
		if row >= 0 && row < 16 && col >= 0 && col < 16 {
			icon[row][col] = color
		}
	}

	// The heart silhouette defined as row spans [colStart, colEnd].
	// A classic pixel-art heart centred in the 16×16 grid.
	heartRows := []struct{ row, colStart, colEnd int }{
		{1, 2, 5},  // left lobe
		{1, 8, 11}, // right lobe
		{2, 1, 6},  // left lobe wider
		{2, 8, 13}, // right lobe wider (gap at col 7 = cleft)
		{3, 1, 13}, // merged
		{4, 1, 14},
		{5, 1, 14},
		{6, 1, 14},
		{7, 2, 13},
		{8, 2, 13},
		{9, 3, 12},
		{10, 4, 11},
		{11, 5, 10},
		{12, 6, 9},
		{13, 7, 8},
	}

	// Fill each heart pixel with the appropriate diagonal band colour.
	for _, hr := range heartRows {
		for col := hr.colStart; col <= hr.colEnd; col++ {
			diag := col - hr.row
			var c px
			switch {
			case diag >= 3:
				c = gold
			case diag >= -4:
				c = red
			default:
				c = blue
			}
			set(hr.row, col, c)
		}
	}

	return icon
}

// ── Frontier Airlines logo ───────────────────────────────────────────────────
//
// The Frontier logo is a stylised "F" composed of three horizontal green bars
// stacked vertically. The left edges curve slightly (staggered columns) and
// the bottom bar is shorter, curving down and to the left.
//
//   • Green {35, 100, 67} — Frontier dark green
//
// Shape layout (G = green, . = transparent):
//
//	col:  0123456789ABCDEF
//	row0: ....GGGGGGGGGGGG   ← top bar
//	row1: ...GGGGGGGGGGGGG
//	row2: ..GGGGGGGGGGGGGG
//	row3: ................
//	row4: ................
//	row5: ...GGGGGGGGGGGGG   ← middle bar
//	row6: ..GGGGGGGGGGGGGG
//	row7: ..GGGGGGGGGGGGGG
//	row8: ................
//	row9: ................
//	rowA: ...GGGGGGGGGG...   ← bottom bar
//	rowB: ..GGGGGGGGGGG...
//	rowC: .GGGGGGGGGGGG...
//	rowD: .GGGGGGGGG......
//	rowE: ..GGGGGG........
//	rowF: ....GGGG........

// buildFrontierLogo constructs and returns the 16×16 Frontier Airlines "F" logo.
func buildFrontierLogo() [16][16][3]uint8 {
	type px = [3]uint8

	green := px{35, 100, 67} // Frontier dark green

	var icon [16][16][3]uint8

	// set writes colour to icon[row][col], guarding against out-of-bounds.
	set := func(row, col int, color px) {
		if row >= 0 && row < 16 && col >= 0 && col < 16 {
			icon[row][col] = color
		}
	}

	// Three horizontal bars defined as row spans [colStart, colEnd].
	bars := []struct{ row, colStart, colEnd int }{
		// Top bar (rows 0-2) — wide sweep to right edge
		{0, 4, 15},
		{1, 3, 15},
		{2, 2, 15},
		// Middle bar (rows 5-7) — similar width
		{5, 3, 15},
		{6, 2, 15},
		{7, 2, 15},
		// Bottom bar (rows 10-15) — shorter, curves down-left
		{10, 3, 12},
		{11, 2, 13},
		{12, 1, 13},
		{13, 1, 10},
		{14, 2, 8},
		{15, 4, 7},
	}
	for _, b := range bars {
		for col := b.colStart; col <= b.colEnd; col++ {
			set(b.row, col, green)
		}
	}

	return icon
}

// ── Airline logo registry ─────────────────────────────────────────────────────

// airlineLogos maps ICAO operator codes (e.g. "DAL") to their 16×16 pixel-art
// logos. Populated once at program start by init().
var airlineLogos map[string][16][16][3]uint8

func init() {
	airlineLogos = map[string][16][16][3]uint8{
		"AAL": buildAmericanLogo(),  // American Airlines
		"DAL": buildDeltaLogo(),     // Delta Air Lines
		"FFT": buildFrontierLogo(),  // Frontier Airlines
		"SWA": buildSouthwestLogo(), // Southwest Airlines
		"UAL": buildUnitedLogo(),    // United Airlines
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
