//go:build !emulator

package main

import (
	"log"
	"os"
	"syscall"
)

// redirectCStdout redirects C-level stdout (fd 1) to /dev/null,
// preserving the original fd for Go's os.Stdout (IPC with Elixir).
// Must be called BEFORE any C library initialization (NewMatrix).
//
// This prevents the hzeller library's printf (show_refresh_rate)
// from writing to the IPC pipe or blocking the real-time refresh thread.
//
// When enabled=false, this is a no-op.
func redirectCStdout(enabled bool) {
	if !enabled {
		return
	}

	// Step 1: Save original fd 1 (the Elixir Port's IPC pipe)
	savedFd, err := syscall.Dup(1)
	if err != nil {
		log.Fatalf("redirectCStdout: dup(1) failed: %v", err)
	}

	// Step 2: Open /dev/null for writing
	devNull, err := syscall.Open("/dev/null", syscall.O_WRONLY, 0)
	if err != nil {
		log.Fatalf("redirectCStdout: open /dev/null failed: %v", err)
	}

	// Step 3: Redirect fd 1 to /dev/null.
	// After this, C's printf() writes to /dev/null — zero overhead, never blocks.
	// Note: Dup3 (not Dup2) is required for linux/arm64 compatibility.
	if err := syscall.Dup3(devNull, 1, 0); err != nil {
		log.Fatalf("redirectCStdout: dup3() failed: %v", err)
	}
	syscall.Close(devNull) // fd 1 is the /dev/null fd now

	// Step 4: Reassign Go's os.Stdout to the saved original fd.
	// All existing IPC code (writeMessage, sendResponse) uses os.Stdout,
	// so this transparently preserves the protocol.
	os.Stdout = os.NewFile(uintptr(savedFd), "/dev/stdout")

	log.Println("C stdout redirected to /dev/null (show_refresh_rate safe)")
}
