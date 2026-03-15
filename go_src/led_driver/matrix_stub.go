//go:build emulator

package main

import (
	"log"
)

// StubMatrix is a no-op in-memory matrix used for development on macOS/Linux
// without the rpi-rgb-led-matrix C library.
type StubMatrix struct {
	width, height int
	pixels        [][]stubPixel
	brightness    int
}

type stubPixel struct {
	r, g, b uint8
}

func NewMatrix(config *MatrixConfig) (Matrix, error) {
	if previewMode {
		return NewTerminalMatrix(config)
	}

	w := config.Cols * config.ChainLength
	h := config.Rows * config.Parallel

	pixels := make([][]stubPixel, h)
	for i := range pixels {
		pixels[i] = make([]stubPixel, w)
	}

	log.Printf("Stub matrix initialized: %dx%d, brightness=%d", w, h, config.Brightness)
	return &StubMatrix{
		width:      w,
		height:     h,
		pixels:     pixels,
		brightness: config.Brightness,
	}, nil
}

func (m *StubMatrix) SetPixel(x, y int, r, g, b uint8) {
	if x >= 0 && x < m.width && y >= 0 && y < m.height {
		m.pixels[y][x] = stubPixel{r, g, b}
	}
}

func (m *StubMatrix) SetBrightness(brightness int) {
	m.brightness = brightness
	log.Printf("Brightness set to %d", brightness)
}

func (m *StubMatrix) Clear() {
	for y := range m.pixels {
		for x := range m.pixels[y] {
			m.pixels[y][x] = stubPixel{0, 0, 0}
		}
	}
}

func (m *StubMatrix) Render() {
	// Count non-black pixels for debug logging
	count := 0
	for y := range m.pixels {
		for x := range m.pixels[y] {
			p := m.pixels[y][x]
			if p.r > 0 || p.g > 0 || p.b > 0 {
				count++
			}
		}
	}
	log.Printf("Render: %d active pixels", count)
}

func (m *StubMatrix) Close() {
	log.Println("Matrix closed")
}
