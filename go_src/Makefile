.PHONY: build build-arm build-host clean

# Path to the compiled rpi-rgb-led-matrix library (only needed for ARM build).
RPI_RGB_LIB ?= /opt/rpi-rgb-led-matrix

# Default target: build for host with emulator stub (no C library needed).
build: build-host

# Cross-compile for Raspberry Pi Zero 2 W (ARMv7 hard-float ABI).
# Requires arm-linux-gnueabihf toolchain and the rpi-rgb-led-matrix library
# pre-compiled for ARM at $(RPI_RGB_LIB).
build-arm:
	@echo "Cross-compiling led_driver for ARM (ARMv7)..."
	cd led_driver && \
	CGO_ENABLED=1 \
	CC=arm-linux-gnueabihf-gcc \
	CXX=arm-linux-gnueabihf-g++ \
	GOOS=linux \
	GOARCH=arm \
	GOARM=7 \
	CGO_CFLAGS="-I$(RPI_RGB_LIB)/include" \
	CGO_LDFLAGS="-L$(RPI_RGB_LIB)/lib -lrgbmatrix -lrt -lm -lpthread -lstdc++" \
	go build -o ../../priv/led_driver .

# Build for the host machine using the emulator stub matrix.
# Works on macOS and Linux without any C library dependencies.
build-host:
	@echo "Building led_driver for host (emulator mode)..."
	cd led_driver && \
	go build -tags emulator -o ../../priv/led_driver .

clean:
	rm -f ../../priv/led_driver
	cd led_driver && go clean
