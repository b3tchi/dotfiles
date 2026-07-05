#!/data/data/com.termux/files/usr/bin/bash
# Stop the Termux remote desktop (xrdp + Xvnc + i3).
: "${PREFIX:=/data/data/com.termux/files/usr}"
export PATH="$PREFIX/bin:$PATH" LD_LIBRARY_PATH="$PREFIX/lib"
DISP=1
pkill -x xrdp 2>/dev/null && echo "stopped xrdp" || echo "xrdp not running"
pkill -x xrdp-sesman 2>/dev/null && echo "stopped xrdp-sesman" || true
vncserver -kill ":$DISP" 2>/dev/null && echo "stopped Xvnc :$DISP" || pkill -f "Xvnc :$DISP" 2>/dev/null && echo "killed Xvnc :$DISP" || echo "Xvnc not running"
pkill -x i3 2>/dev/null && echo "stopped i3" || true
