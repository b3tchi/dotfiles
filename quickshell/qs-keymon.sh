#!/usr/bin/awk -f
# Parse xinput test-xi2 output, emit: press|release <keycode>
# Only RawKeyPress/RawKeyRelease to avoid duplicates
# Dedup consecutive identical events
BEGIN { type=""; last="" }
/RawKeyPress/  { type="press"; next }
/RawKeyRelease/ { type="release"; next }
/KeyPress|KeyRelease|FocusIn|FocusOut|DeviceChanged/ { type=""; next }
/detail:/ {
    if (type != "") {
        code = $2 + 0
        if (code == 64 || code == 23 || code == 133 || code == 134 || code == 108) {
            msg = type " " code
            if (msg != last) {
                print msg
                fflush()
                last = msg
            }
        }
        type = ""
    }
}
