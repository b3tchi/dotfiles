#!/data/data/com.termux/files/usr/bin/bash
# Run this in Termux (outside proot) to provide real /proc stats
# to the quickshell bar inside proot.
STATS_FILE="${TMPDIR:-/tmp}/qs-stats"

while true; do
    read _ u1 n1 s1 i1 w1 q1 f1 _ < /proc/stat
    sleep 2
    read _ u2 n2 s2 i2 w2 q2 f2 _ < /proc/stat

    t1=$((u1+n1+s1+i1+w1+q1+f1))
    t2=$((u2+n2+s2+i2+w2+q2+f2))
    dt=$((t2-t1))
    di=$((i2-i1))
    cpu=$(( dt > 0 ? (dt-di)*100/dt : 0 ))

    ram=$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "%.0f", (t-a)/t*100}' /proc/meminfo)
    disk=$(df /data 2>/dev/null | awk 'NR==2{print $5}' | tr -d '%')
    load=$(awk '{print $1}' /proc/loadavg)

    printf '%s\n%s\n%s\n%s\n' "$cpu" "$ram" "${disk:-0}" "$load" > "$STATS_FILE.tmp"
    mv "$STATS_FILE.tmp" "$STATS_FILE"
done
