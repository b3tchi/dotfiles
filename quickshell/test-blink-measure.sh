#!/bin/sh
# Measure the region-screenshot overlay's open/exit blink objectively.
#
# Records the X display at 60fps while driving the full open -> whole -> exit
# flow, then prints per-frame average luma. Blinks show up as luma excursions
# from the desktop baseline, so "it blinks" becomes a number you can compare
# before and after a change.
#
# Usage:  ./test-blink-measure.sh [out.mkv]
# Needs:  ffmpeg + ffprobe, an X session with the overlay installed.
#
# Reading the output — on a 2560x1440 xrdp desktop, baseline luma ~42:
#   open  black gap  luma ~16 (limited-range Y=16 IS black) for N frames
#   exit  expose storm  luma spikes ABOVE baseline when an underlying app
#         repaints white before drawing its content (Firefox does this).
#         Content-dependent: it only flashes when something actually repaints,
#         so a clean run does NOT prove the storm is fixed — vary what's on
#         screen and re-run before drawing conclusions (dotfiles-ed3).
#
# History: open gap was 83ms (5 frames) before dotfiles-02h, 33ms (2 frames)
# after. The residual 2 frames are X clearing the freshly mapped window to its
# black background pixel plus Qt's first paint; `color: transparent` does NOT
# help (no compositor for the ARGB visual — it measures 5 frames again).
set -e
OUT="${1:-/tmp/blink.mkv}"
: "${DISPLAY:=:0}"
export DISPLAY

GEOM=$(xrandr 2>/dev/null | awk '/\*/{print $1; exit}')
[ -n "$GEOM" ] || GEOM=2560x1440

# ffv1 = lossless; an inter-frame codec would smear the very dips we measure.
# Downscale first: only whole-frame average luma matters, and 60fps of lossless
# 2560x1440 would be GBs of I/O on a virtual Xorg with no GPU — dropped frames
# would fake the very gaps we are hunting.
ffmpeg -y -f x11grab -framerate 60 -video_size "$GEOM" -i "$DISPLAY" \
    -t 8 -vf scale=480:270 -c:v ffv1 -pix_fmt yuv420p "$OUT" >/dev/null 2>&1 &
FF=$!
sleep 1

i3-msg 'mode "screenshot"; exec --no-startup-id ~/.dotfiles/quickshell/qs-screenshot.sh' >/dev/null 2>&1
sleep 3
~/.dotfiles/quickshell/qs-shot-action.sh whole >/dev/null 2>&1

wait $FF
# Safety net: never leave the session stuck in the mode if a step misfired.
i3-msg mode default >/dev/null 2>&1

echo "recorded: $OUT"
echo
echo "frames deviating >2.0 luma from the previous frame:"
ffprobe -v error -f lavfi -i "movie=$OUT,signalstats" \
    -show_entries frame=pts_time:frame_tags=lavfi.signalstats.YAVG \
    -of csv=p=0 2>/dev/null |
    awk -F, 'NR>1 && (($2-prev)>2.0 || (prev-$2)>2.0) {
                 printf "  t=%.3f  luma=%6.2f  delta=%+7.2f\n", $1, $2, $2-prev
             } {prev=$2}
             END { printf "\nframes=%d\n", NR }'
