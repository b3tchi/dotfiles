//go:build !windows

package main

// runHealth is --health's production entry point on X11.
func runHealth(display string) (int, string) {
	return health(display, defaultHealthProbes())
}

// runRecoverCmd refuses: `hotkeyd recover` is the Windows panic chord's
// (sp012 Task 7). On X11 that is hotkeyd-panic.sh recover.
func runRecoverCmd(argv []string) int {
	daemonLog("recover is only available in a Windows build; on X11 use hotkeyd-panic.sh recover")
	return 2
}
