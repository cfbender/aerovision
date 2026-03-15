package main

// previewMode controls whether the emulator renders to terminal using ANSI colors.
// Set by the --preview / --demo flags in main.go.
// Only meaningful for emulator builds; ignored by the real hardware matrix.
var previewMode bool

// MatrixConfig holds LED matrix hardware configuration
type MatrixConfig struct {
	Rows            int
	Cols            int
	ChainLength     int
	Parallel        int
	Brightness      int
	HardwareMapping string
	DisableHWPulse  bool
	SlowdownGPIO    int
}

// Matrix is the interface for LED matrix operations
type Matrix interface {
	SetPixel(x, y int, r, g, b uint8)
	SetBrightness(brightness int)
	Clear()
	Render()
	Close()
}
