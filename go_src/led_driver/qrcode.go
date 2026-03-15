package main

import (
	"log"

	qrcode "github.com/skip2/go-qrcode"
)

// renderQRCode generates a QR code for cmd.Data and renders it centered on
// the display. Uses white modules on a black background.
// Scale is chosen automatically: 2px/module if it fits, 1px/module otherwise.
func (d *Display) renderQRCode(cmd Command) {
	d.matrix.Clear()

	if cmd.Data == "" {
		sendResponse("error", "no QR data provided")
		return
	}

	// Generate QR code with low error correction for minimum module count.
	qr, err := qrcode.New(cmd.Data, qrcode.Low)
	if err != nil {
		log.Printf("QR generation error: %v", err)
		sendResponse("error", err.Error())
		return
	}

	qr.DisableBorder = true
	bitmap := qr.Bitmap()
	qrSize := len(bitmap) // number of modules per side

	// Pick a scale that fits within the display dimensions.
	scale := 1
	if qrSize*2 <= d.width && qrSize*2 <= d.height {
		scale = 2
	}

	// Center the QR code on the display.
	totalSize := qrSize * scale
	offsetX := (d.width - totalSize) / 2
	offsetY := (d.height - totalSize) / 2

	for qy, row := range bitmap {
		for qx, module := range row {
			if module {
				// Dark (filled) module → draw white
				for sy := 0; sy < scale; sy++ {
					for sx := 0; sx < scale; sx++ {
						px := offsetX + qx*scale + sx
						py := offsetY + qy*scale + sy
						d.matrix.SetPixel(px, py, 255, 255, 255)
					}
				}
			}
			// Light module → already black from Clear()
		}
	}

	d.matrix.Render()
	sendResponse("ok", "")
}
