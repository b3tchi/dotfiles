---
description: Preview an image or file in the preview-d webview window (and print its localhost URL)
argument-hint: <path>
allowed-tools: Bash(preview:*)
---
Preview the file `$ARGUMENTS` for the user by running the preview wrapper:

`preview show "$ARGUMENTS"`

This ensures a `/`-rooted `preview-d` daemon is up, opens the preview-wv
window, sends the file, and prints a `http://127.0.0.1:4200/file/...?full`
URL. Report that URL back to the user (it's the browser-on-a-port fallback if
the GUI window doesn't appear — e.g. no graphical session).

If it fails because the `preview` or `preview-d` binary is missing, tell the
user to run `rotz install preview`.
