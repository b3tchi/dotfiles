// overlay/shell.qml — thin ShellRoot wrapper (sp017 T6 / dotfiles-evnv.6).
//
// The launcher / switcher / projects dialog logic lives ONCE in
// config/Overlay.qml. On desktop the overlay runs as a SEPARATE process
// (`quickshell -p overlay`, qs-overlay.sh); over RDP (QS_RDP=1) config/shell.qml
// hosts the same Overlay {} in the main instance (adr0004 dual-session). This
// file is the desktop entry point and nothing more — a pure wrapper. Overlay.qml
// and Common/ resolve through sibling RELATIVE symlinks (overlay/Overlay.qml ->
// ../config/Overlay.qml, overlay/Common -> ../config/Common) so the rotz deploy
// link carries them and fresh clones work without rotz. Do NOT reintroduce
// dialog logic here — the drift this kills (sp017) must not come back.
import Quickshell
ShellRoot { Overlay {} }
