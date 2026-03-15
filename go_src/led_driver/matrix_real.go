//go:build !emulator

package main

import (
	"fmt"
	"image/color"

	rgbmatrix "github.com/mcuadros/go-rpi-rgb-led-matrix"
)

type RealMatrix struct {
	matrix *rgbmatrix.RGBLedMatrix
	canvas *rgbmatrix.Canvas
	config *MatrixConfig
}

func NewMatrix(config *MatrixConfig) (Matrix, error) {
	matrixConfig := &rgbmatrix.DefaultConfig
	matrixConfig.Rows = config.Rows
	matrixConfig.Cols = config.Cols
	matrixConfig.ChainLength = config.ChainLength
	matrixConfig.Parallel = config.Parallel
	matrixConfig.Brightness = config.Brightness
	matrixConfig.HardwareMapping = config.HardwareMapping
	matrixConfig.DisableHardwarePulsing = config.DisableHWPulse

	// Note: SlowdownGPIO is set via C API flags at matrix creation time.
	// The go-rpi-rgb-led-matrix library passes runtime args through os.Args
	// or the RGBLedMatrixOptions struct. We rely on the binary flag parsing.

	m, err := rgbmatrix.NewRGBLedMatrix(matrixConfig)
	if err != nil {
		return nil, fmt.Errorf("failed to create RGB matrix: %w", err)
	}

	canvas := rgbmatrix.NewCanvas(m)

	return &RealMatrix{
		matrix: m,
		canvas: canvas,
		config: config,
	}, nil
}

func (m *RealMatrix) SetPixel(x, y int, r, g, b uint8) {
	m.canvas.Set(x, y, color.RGBA{R: r, G: g, B: b, A: 255})
}

func (m *RealMatrix) SetBrightness(brightness int) {
	// Brightness is a config-level setting; runtime changes require C API access.
	// For now this is a no-op; the value takes effect on next matrix init.
	_ = brightness
}

func (m *RealMatrix) Clear() {
	bounds := m.canvas.Bounds()
	black := color.RGBA{R: 0, G: 0, B: 0, A: 255}
	for y := bounds.Min.Y; y < bounds.Max.Y; y++ {
		for x := bounds.Min.X; x < bounds.Max.X; x++ {
			m.canvas.Set(x, y, black)
		}
	}
}

func (m *RealMatrix) Render() {
	m.canvas.Render()
}

func (m *RealMatrix) Close() {
	m.canvas.Close()
}
