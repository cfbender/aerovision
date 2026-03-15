//go:build emulator

package main

import (
	"bytes"
	"fmt"
	"os"
)

// TerminalMatrix renders the pixel buffer to stderr using ANSI 24-bit true
// color escape sequences and the Unicode upper-half block character ▀ (U+2580).
//
// Each terminal character cell represents 2 vertical pixels:
//   - Foreground color  = top pixel    → \033[38;2;R;G;Bm
//   - Background color  = bottom pixel → \033[48;2;R;G;Bm
//
// A 64×64 LED display becomes 64 columns × 32 rows in the terminal.
type TerminalMatrix struct {
	width, height int
	pixels        [][]termPixel
	brightness    int
}

type termPixel struct {
	r, g, b uint8
}

// NewTerminalMatrix initialises a TerminalMatrix and prepares the terminal.
func NewTerminalMatrix(config *MatrixConfig) (Matrix, error) {
	w := config.Cols * config.ChainLength
	h := config.Rows * config.Parallel

	pixels := make([][]termPixel, h)
	for i := range pixels {
		pixels[i] = make([]termPixel, w)
	}

	// Hide cursor and clear screen before first frame.
	fmt.Fprint(os.Stderr, "\033[?25l")
	fmt.Fprint(os.Stderr, "\033[2J")

	return &TerminalMatrix{
		width:      w,
		height:     h,
		pixels:     pixels,
		brightness: config.Brightness,
	}, nil
}

func (m *TerminalMatrix) SetPixel(x, y int, r, g, b uint8) {
	if x >= 0 && x < m.width && y >= 0 && y < m.height {
		// Apply brightness scaling at write time so Render is a pure read.
		br := float64(m.brightness) / 100.0
		m.pixels[y][x] = termPixel{
			r: uint8(float64(r) * br),
			g: uint8(float64(g) * br),
			b: uint8(float64(b) * br),
		}
	}
}

func (m *TerminalMatrix) SetBrightness(brightness int) {
	if brightness < 0 {
		brightness = 0
	}
	if brightness > 100 {
		brightness = 100
	}
	m.brightness = brightness
}

func (m *TerminalMatrix) Clear() {
	for y := range m.pixels {
		for x := range m.pixels[y] {
			m.pixels[y][x] = termPixel{0, 0, 0}
		}
	}
}

// Render writes the full frame to stderr atomically.
// Uses ▀ (U+2580 UPPER HALF BLOCK) so that each character cell encodes two
// vertical pixels: foreground = top pixel, background = bottom pixel.
func (m *TerminalMatrix) Render() {
	var buf bytes.Buffer

	// Move to top-left corner (home cursor).
	buf.WriteString("\033[H")

	// Header line.
	buf.WriteString("\033[1;36m AeroVision 64\xc3\x9764 Preview \033[0m\n")

	// Top border.
	buf.WriteString("\033[90m┌")
	for x := 0; x < m.width; x++ {
		buf.WriteString("─")
	}
	buf.WriteString("┐\033[0m\n")

	// Pixel rows — two LED rows per terminal line.
	for y := 0; y < m.height; y += 2 {
		buf.WriteString("\033[90m│\033[0m") // left border

		for x := 0; x < m.width; x++ {
			top := m.pixels[y][x]

			// Bottom pixel is black when height is odd (shouldn't happen for 64px).
			var bot termPixel
			if y+1 < m.height {
				bot = m.pixels[y+1][x]
			}

			topBlack := top.r == 0 && top.g == 0 && top.b == 0
			botBlack := bot.r == 0 && bot.g == 0 && bot.b == 0

			if topBlack && botBlack {
				// Both pixels off — emit a plain space with reset attributes
				// to avoid carrying stale colors across runs.
				buf.WriteString("\033[0m ")
			} else {
				// Foreground = top pixel color, Background = bottom pixel color.
				// ▀ = upper half block → top half is foreground, lower half is background.
				fmt.Fprintf(&buf, "\033[38;2;%d;%d;%dm\033[48;2;%d;%d;%dm▀",
					top.r, top.g, top.b,
					bot.r, bot.g, bot.b)
			}
		}

		buf.WriteString("\033[0m\033[90m│\033[0m\n") // reset attributes + right border
	}

	// Bottom border.
	buf.WriteString("\033[90m└")
	for x := 0; x < m.width; x++ {
		buf.WriteString("─")
	}
	buf.WriteString("┘\033[0m\n")

	// Status line.
	fmt.Fprintf(&buf, "\033[90m Brightness: %d%%  Press Ctrl+C to exit\033[0m\n", m.brightness)

	// Write entire frame to stderr in one call to minimise flicker.
	os.Stderr.Write(buf.Bytes())
}

func (m *TerminalMatrix) Close() {
	// Restore terminal state: show cursor, reset attributes, clear screen.
	fmt.Fprint(os.Stderr, "\033[?25h")
	fmt.Fprint(os.Stderr, "\033[0m")
	fmt.Fprint(os.Stderr, "\033[2J\033[H")
}
