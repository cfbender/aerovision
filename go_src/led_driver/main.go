package main

import (
	"flag"
	"io"
	"log"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	// Log to stderr (stdout is reserved for IPC protocol)
	log.SetOutput(os.Stderr)
	log.SetPrefix("[led_driver] ")

	// Command-line flags with SEENGREAT-compatible defaults
	rows := flag.Int("led-rows", 64, "LED panel rows")
	cols := flag.Int("led-cols", 64, "LED panel columns")
	chain := flag.Int("led-chain", 1, "Number of daisy-chained panels")
	parallel := flag.Int("led-parallel", 1, "Number of parallel chains")
	brightness := flag.Int("led-brightness", 80, "Brightness (0-100)")
	gpioMapping := flag.String("led-gpio-mapping", "regular", "GPIO mapping name")
	noHwPulse := flag.Bool("led-no-hardware-pulse", true, "Disable hardware pulse")
	slowdownGpio := flag.Int("led-slowdown-gpio", 1, "GPIO slowdown factor")
	preview := flag.Bool("preview", false, "Render display to terminal with ANSI colors (emulator mode)")
	demo := flag.Bool("demo", false, "Show a sample flight card and enter preview mode (implies --preview)")
	previewIpc := flag.Bool("preview-ipc", false, "Send rendered frames back over stdout as IPC packets (implies --preview)")
	previewPixelsFlag := flag.Bool("preview-pixels", false, "Send pixel data back over stdout as IPC packets (implies --preview)")
	limitRefresh := flag.Int("led-limit-refresh", 0, "Limit refresh rate to this frequency in Hz (0=no limit)")
	pwmBits := flag.Int("led-pwm-bits", 11, "PWM bits used for brightness level (1-11)")
	pwmLsbNs := flag.Int("led-pwm-lsb-nanoseconds", 130, "PWM LSB nanoseconds (baseline time for lowest bit)")
	pwmDitherBits := flag.Int("led-pwm-dither-bits", 0, "Time dithering of lower bits (0=no dithering)")
	showRefresh := flag.Bool("led-show-refresh", false, "Show refresh rate on stderr")
	flag.Parse()

	// Redirect C's stdout to a pipe when --led-show-refresh is enabled.
	// Must happen before NewMatrix() which spawns the hzeller refresh thread.
	redirectCStdout(*showRefresh)

	// --demo implies --preview.
	if *demo {
		*preview = true
	}

	if *previewIpc {
		*preview = true
		previewIPC = true
	}

	if *previewPixelsFlag {
		*preview = true
		previewPixels = true
		previewIPC = false // pixels mode supersedes ipc mode
		log.SetOutput(io.Discard)
	}

	// In preview-ipc mode, suppress all stderr output — the ANSI frames are
	// sent back over stdout as IPC packets, so nothing should go to the terminal.
	if *previewIpc {
		log.SetOutput(io.Discard)
	}

	// Activate terminal rendering when --preview or --demo is requested.
	// previewMode is defined in matrix.go and read by matrix_stub.go (emulator builds).
	// On real hardware builds the variable exists but NewMatrix ignores it.
	if *preview {
		previewMode = true
	}

	// When --preview-pixels is set, use an in-memory software matrix that sends
	// pixel data back over stdout. This works on both emulator and real-hardware
	// builds — no GPIO or hardware init is performed.
	var matrix Matrix
	if *previewPixelsFlag {
		matrix = NewSoftwareMatrix(*cols**chain, *rows**parallel)
	} else {
		config := &MatrixConfig{
			Rows:              *rows,
			Cols:              *cols,
			ChainLength:       *chain,
			Parallel:          *parallel,
			Brightness:        *brightness,
			HardwareMapping:   *gpioMapping,
			DisableHWPulse:    *noHwPulse,
			SlowdownGPIO:      *slowdownGpio,
			LimitRefreshHz:    *limitRefresh,
			PWMBits:           *pwmBits,
			PWMLSBNanoseconds: *pwmLsbNs,
			PWMDitherBits:     *pwmDitherBits,
			ShowRefreshRate:   *showRefresh,
		}
		var err error
		matrix, err = NewMatrix(config)
		if err != nil {
			log.Fatalf("Failed to initialize matrix: %v", err)
		}
	}
	defer matrix.Close()

	display := NewDisplay(matrix, *cols, *rows)

	// Handle signals for clean shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGTERM, syscall.SIGINT)

	// --demo: render a sample flight card immediately.
	if *demo {
		alt := 35000
		spd := 450
		hdg := 45
		vr := -500
		sampleCmd := Command{
			Cmd:         "flight_card",
			Airline:     "AMERICAN",
			Flight:      "AA 1234",
			Aircraft:    "B738",
			RouteOrigin: "RDU",
			RouteDest:   "SLC",
			AltitudeFt:  &alt,
			SpeedKt:     &spd,
			BearingDeg:  &hdg,
			VRateFpm:    &vr,
			DepTime:     "14:30",
			ArrTime:     "18:45",
			Progress:    0.65,
		}
		display.HandleCommand(sampleCmd)

		// When stdin is a real terminal (not a pipe), skip the IPC read loop
		// and just wait for Ctrl+C.
		stat, _ := os.Stdin.Stat()
		if stat != nil && (stat.Mode()&os.ModeCharDevice) != 0 {
			log.Println("Demo mode: displaying sample flight card. Press Ctrl+C to exit.")
			sig := <-sigChan
			log.Printf("Received signal: %v", sig)
			matrix.Clear()
			matrix.Render()
			log.Println("Shutdown complete")
			return
		}
		// If stdin is a pipe, fall through to the normal read loop so
		// additional commands can be processed.
	}

	// Run protocol read loop in goroutine
	done := make(chan struct{})
	go func() {
		readLoop(func(cmd Command) {
			display.HandleCommand(cmd)
		})
		close(done)
	}()

	// Wait for either stdin EOF or signal
	select {
	case <-done:
		log.Println("Protocol loop ended")
	case sig := <-sigChan:
		log.Printf("Received signal: %v", sig)
	}

	matrix.Clear()
	matrix.Render()
	log.Println("Shutdown complete")
}
