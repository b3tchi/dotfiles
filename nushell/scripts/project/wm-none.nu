# Stand-in for ~/.local/bin/wm-ipc.nu where it is not installed (Windows):
# `use` needs a module at parse time, so the project module falls back to this
# one. No window manager answers here.
export def ipc [command: string] {
	null
}
