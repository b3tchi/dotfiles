//go:build !windows

package main

import "os"

// defaultInput is the key source a non-Windows build starts with.
const defaultInput = "x11"

// defaultDisplay is resolveDisplay's last tier: $DISPLAY, then ":0".
func defaultDisplay() string {
	if d := os.Getenv("DISPLAY"); d != "" {
		return d
	}
	return ":0"
}

// runWin32 refuses: RegisterHotKey exists only in a Windows build.
func runWin32() int {
	daemonLog("--input win32 is only available in a Windows build (GOOS=windows)")
	return 2
}
