//go:build !emulator

package main

/*
#cgo CXXFLAGS: -std=c++17
#cgo LDFLAGS: -lrgbmatrix -lstdc++ -lm -lpthread -lrt

#include "led-matrix-c.h"
#include <stdlib.h>
#include <string.h>

struct RGBLedMatrix* new_matrix(int rows, int cols, int chain, int parallel,
                                int brightness, const char* mapping,
                                int no_hw_pulse, int slowdown,
                                int limit_refresh_hz,
                                int pwm_bits, int pwm_lsb_nanoseconds,
                                int pwm_dither_bits, int show_refresh_rate) {
    struct RGBLedMatrixOptions opts;
    memset(&opts, 0, sizeof(opts));
    opts.rows                     = rows;
    opts.cols                     = cols;
    opts.chain_length             = chain;
    opts.parallel                 = parallel;
    opts.brightness               = brightness;
    opts.hardware_mapping         = mapping;
    opts.disable_hardware_pulsing = no_hw_pulse;
    opts.limit_refresh_rate_hz    = limit_refresh_hz;
    opts.pwm_bits                 = pwm_bits;
    opts.pwm_lsb_nanoseconds      = pwm_lsb_nanoseconds;
    opts.pwm_dither_bits          = pwm_dither_bits;
    opts.show_refresh_rate        = show_refresh_rate;

    struct RGBLedRuntimeOptions rt_opts;
    memset(&rt_opts, 0, sizeof(rt_opts));
    rt_opts.gpio_slowdown   = slowdown;
    rt_opts.drop_privileges = 0;

    return led_matrix_create_from_options_and_rt_options(&opts, &rt_opts);
}
*/
import "C"
import (
	"fmt"
	"unsafe"
)

// RealMatrix uses double-buffering to eliminate flicker.
//
// hzeller's library supports offscreen canvases that can be swapped
// atomically with led_matrix_swap_on_vsync. The pattern is:
//  1. Draw everything onto the offscreen canvas.
//  2. Call Render() → swap_on_vsync atomically makes it visible and
//     returns the old display canvas as the new offscreen canvas.
//
// This means Clear()+draw+Render() never shows a black frame — the
// display only ever shows complete frames.
type RealMatrix struct {
	matrix    *C.struct_RGBLedMatrix
	offscreen *C.struct_LedCanvas // draw target; swapped on Render()
	width     int
	height    int
}

func NewMatrix(config *MatrixConfig) (Matrix, error) {
	mapping := C.CString(config.HardwareMapping)
	defer C.free(unsafe.Pointer(mapping))

	noHWPulse := C.int(0)
	if config.DisableHWPulse {
		noHWPulse = 1
	}

	showRefresh := C.int(0)
	if config.ShowRefreshRate {
		showRefresh = 1
	}

	m := C.new_matrix(
		C.int(config.Rows),
		C.int(config.Cols),
		C.int(config.ChainLength),
		C.int(config.Parallel),
		C.int(config.Brightness),
		mapping,
		noHWPulse,
		C.int(config.SlowdownGPIO),
		C.int(config.LimitRefreshHz),
		C.int(config.PWMBits),
		C.int(config.PWMLSBNanoseconds),
		C.int(config.PWMDitherBits),
		showRefresh,
	)
	if m == nil {
		return nil, fmt.Errorf("led_matrix_create_from_options failed — are you running as root?")
	}

	// Create an offscreen canvas for double-buffering.
	offscreen := C.led_matrix_create_offscreen_canvas(m)

	return &RealMatrix{
		matrix:    m,
		offscreen: offscreen,
		width:     config.Cols * config.ChainLength,
		height:    config.Rows * config.Parallel,
	}, nil
}

// SetPixel draws to the offscreen canvas — not visible until Render().
func (m *RealMatrix) SetPixel(x, y int, r, g, b uint8) {
	if x >= 0 && x < m.width && y >= 0 && y < m.height {
		C.led_canvas_set_pixel(m.offscreen, C.int(x), C.int(y),
			C.uint8_t(r), C.uint8_t(g), C.uint8_t(b))
	}
}

func (m *RealMatrix) SetBrightness(brightness int) {
	C.led_matrix_set_brightness(m.matrix, C.uint8_t(brightness))
}

// Clear wipes the offscreen canvas — not visible until Render().
func (m *RealMatrix) Clear() {
	C.led_canvas_clear(m.offscreen)
}

// Render atomically swaps the offscreen canvas onto the display.
// The old display canvas becomes the new offscreen canvas, ready for
// the next frame. No black frame is ever shown.
func (m *RealMatrix) Render() {
	m.offscreen = C.led_matrix_swap_on_vsync(m.matrix, m.offscreen)
}

func (m *RealMatrix) Close() {
	C.led_matrix_delete(m.matrix)
}
