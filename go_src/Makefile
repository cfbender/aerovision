.PHONY: build build-arm build-host clean

# The hzeller C library is cloned and built here automatically.
HZELLER_DIR  := $(CURDIR)/.hzeller
HZELLER_LIB  := $(HZELLER_DIR)/lib/librgbmatrix.a
HZELLER_INC  := $(HZELLER_DIR)/include
# Note: headers live directly in HZELLER_INC — no copy step needed

# Pinned commit for reproducibility.
HZELLER_REPO := https://github.com/hzeller/rpi-rgb-led-matrix.git

# ---------------------------------------------------------------------------
# Toolchain detection
#
# Prefer the Nerves-bundled aarch64 toolchain (already downloaded by
# `mix deps.get` for the rpi0_2 target). Fall back to a system-installed
# arm-linux-gnueabihf toolchain if present.
# ---------------------------------------------------------------------------
NERVES_TOOLCHAIN := $(HOME)/.nerves/artifacts/nerves_toolchain_aarch64_nerves_linux_gnu-darwin_arm-13.2.0/bin
NERVES_CC  := $(NERVES_TOOLCHAIN)/aarch64-nerves-linux-gnu-gcc
NERVES_CXX := $(NERVES_TOOLCHAIN)/aarch64-nerves-linux-gnu-g++

ifeq ($(wildcard $(NERVES_CC)),)
  # Nerves toolchain not found — fall back to system arm-linux-gnueabihf
  ARM_CC  := arm-linux-gnueabihf-gcc
  ARM_CXX := arm-linux-gnueabihf-g++
  ARM_AR  := arm-linux-gnueabihf-gcc-ar
  ARM_ARCH := arm
  ARM_GOARM := 7
  ARM_CPU_ARCH_FLAGS := -march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard
else
  # Use the Nerves aarch64 toolchain
  ARM_CC  := $(NERVES_CC)
  ARM_CXX := $(NERVES_CXX)
  ARM_AR  := $(NERVES_TOOLCHAIN)/aarch64-nerves-linux-gnu-gcc-ar
  ARM_ARCH := arm64
  ARM_GOARM :=
  ARM_CPU_ARCH_FLAGS := -march=armv8-a
endif

# Default target: build for the host machine (emulator mode, no C library).
build: build-host

# ---------------------------------------------------------------------------
# Host build — emulator mode, no C library required.
# ---------------------------------------------------------------------------
build-host:
	@echo "Building led_driver for host (emulator mode)..."
	cd led_driver && \
	go build -tags emulator -o ../../priv/led_driver .

# ---------------------------------------------------------------------------
# ARM build — fetches + builds hzeller automatically, then cross-compiles.
# ---------------------------------------------------------------------------
build-arm: $(HZELLER_LIB)
	@echo "Cross-compiling led_driver for ARM ($(ARM_ARCH))..."
	cd led_driver && \
	CGO_ENABLED=1 \
	CC="$(ARM_CC)" \
	CXX="$(ARM_CXX)" \
	GOOS=linux \
	GOARCH=$(ARM_ARCH) \
	$(if $(ARM_GOARM),GOARM=$(ARM_GOARM),) \
	CGO_CFLAGS="-I$(HZELLER_INC)" \
	CGO_LDFLAGS="-L$(HZELLER_DIR)/lib -lrgbmatrix -lrt -lm -lpthread -lstdc++" \
	go build -o ../../priv/led_driver .

# Clone and compile the hzeller C library for ARM if not already present.
$(HZELLER_LIB):
	@echo "Fetching hzeller/rpi-rgb-led-matrix..."
	@if [ ! -d "$(HZELLER_DIR)/.git" ]; then \
		git clone --depth 1 $(HZELLER_REPO) $(HZELLER_DIR); \
	fi
	@echo "Building librgbmatrix.a for $(ARM_ARCH) with -O3 + LTO..."
	$(MAKE) -C $(HZELLER_DIR)/lib \
		CC="$(ARM_CC)" \
		CXX="$(ARM_CXX)" \
		AR="$(ARM_AR)" \
		CPU_ARCH_FLAGS="$(ARM_CPU_ARCH_FLAGS)" \
		librgbmatrix.a
	@echo "librgbmatrix.a built successfully."

clean:
	rm -f ../../priv/led_driver
	rm -rf $(HZELLER_DIR)
	cd led_driver && go clean
