// matrix_software.go — compiled on ALL targets (no build tag).
//
// SoftwareMatrix is an in-memory pixel buffer used when --preview-pixels is
// passed. It tracks the full 64×64 canvas in memory and sends the pixel array
// as a JSON IPC packet on every Render(). No hardware access is performed.
//
// On target builds this is used by PreviewServer to get a software-rendered
// copy of each frame without touching the real matrix hardware.

package main

import (
	"encoding/json"
	"os"
	"sync"
)

type SoftwareMatrix struct {
	width  int
	height int
	pixels [][]pixel
	mu     sync.Mutex
}

type pixel struct {
	R, G, B uint8
}

func NewSoftwareMatrix(width, height int) *SoftwareMatrix {
	pixels := make([][]pixel, height)
	for y := range pixels {
		pixels[y] = make([]pixel, width)
	}
	return &SoftwareMatrix{
		width:  width,
		height: height,
		pixels: pixels,
	}
}

func (m *SoftwareMatrix) SetPixel(x, y int, r, g, b uint8) {
	if x >= 0 && x < m.width && y >= 0 && y < m.height {
		m.mu.Lock()
		m.pixels[y][x] = pixel{r, g, b}
		m.mu.Unlock()
	}
}

func (m *SoftwareMatrix) SetBrightness(_ int) {}

func (m *SoftwareMatrix) Clear() {
	m.mu.Lock()
	for y := range m.pixels {
		for x := range m.pixels[y] {
			m.pixels[y][x] = pixel{}
		}
	}
	m.mu.Unlock()
}

// Render serialises the pixel buffer as a JSON IPC packet and writes it to
// stdout using the 4-byte big-endian length-prefix protocol.
func (m *SoftwareMatrix) Render() {
	m.mu.Lock()
	flat := make([][3]uint8, 0, m.width*m.height)
	for y := 0; y < m.height; y++ {
		for x := 0; x < m.width; x++ {
			p := m.pixels[y][x]
			flat = append(flat, [3]uint8{p.R, p.G, p.B})
		}
	}
	m.mu.Unlock()

	msg := map[string]interface{}{
		"status": "pixels",
		"pixels": flat,
	}

	data, err := json.Marshal(msg)
	if err != nil {
		return
	}

	writeMessage(os.Stdout, data) //nolint:errcheck
}

func (m *SoftwareMatrix) Close() {}
