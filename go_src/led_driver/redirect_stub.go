//go:build emulator

package main

// redirectCStdout is a no-op on emulator builds.
// The dup2/pipe approach is Linux-specific and unnecessary without real hardware.
func redirectCStdout(enabled bool) {}
