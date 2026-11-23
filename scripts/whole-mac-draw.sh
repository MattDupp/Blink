#!/bin/bash
# What the whole Mac draws while Blink Monitor is in one state, then in another.
#
#   scripts/whole-mac-draw.sh counting paused counting
#   scripts/whole-mac-draw.sh thorough light thorough paused
#   PHASE=300 scripts/whole-mac-draw.sh ...         seconds of each phase (default 300)
#
# WHY IT EXISTS. `BlinkReplay --cost` and `--cost-of` say what the app's own process
# does: instructions, a share of a core, the processor's energy. A battery pays for more
# than that. MEASURED 23 November 2026: the processor's energy for the app is 0.05 W, and
# the Mac draws about 2 W more while the app counts a face in view than while it is
# paused. Code that halved the instructions did not move those 2 W (docs/LESSONS.md,
# number 10). So a claim about the battery is judged here, not on instructions.
#
# HOW. The battery reports what the Mac draws as a whole ("SystemLoad", in milliwatts),
# with a new figure about once a minute. No administrator is needed, no camera is opened
# and no app is touched: YOU put the app in each state when the script says so. The words
# on the command line are only names for the phases.
#
# FOR A RESULT THAT MEANS SOMETHING
#   - on the battery, with the screen's brightness left alone;
#   - the same windows in front from start to end: the screen is the largest consumer;
#   - touch nothing but what changes the app's state, and stay in the camera's view;
#   - put the state you care about on both sides of the other (counting paused counting):
#     if its two phases differ, the Mac drifted and the run says little;
#   - compare within one run only. The Mac's resting level moved from 1.9 to 5.1 W
#     between runs of the same afternoon.
set -u

[ $# -ge 2 ] || { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
LABELS=("$@")
PHASE="${PHASE:-300}"
STEP=5          # seconds between two notes
SETTLE=70       # a figure that appears earlier in a phase may still describe the one before

battery() { ioreg -rw0 -c AppleSmartBattery; }
get() { printf '%s' "$L" | grep -o "\"$1\"[ ]*=[ ]*[0-9A-Za-z]*" | head -1 | sed 's/.*=[ ]*//'; }

L=$(battery)
[ -n "$(get SystemLoad)" ] || { echo "This Mac does not report what it draws (no SystemLoad figure from its battery)."; exit 1; }
[ "$(get ExternalConnected)" = No ] || { echo "Unplug the charger: on the charger the figure is not what the battery gives."; exit 1; }

# The app, if it runs: its processor time is noted beside the Mac's draw, with that of
# macOS's camera process and of the process that draws the screen, to say who worked.
APP=$(pgrep -x BlinkMonitor | head -1)
cpus() {
    ps -axo pid=,cputime=,comm= | awk -v app="${APP:-none}" '
        function secs(t,   a, n, i, s) { n = split(t, a, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + a[i]; return s }
        $1 == app { a = secs($2) }
        $3 ~ /\/cameracaptured$/ { c += secs($2) }
        $3 ~ /\/WindowServer$/ { w += secs($2) }
        END { printf "%.2f,%.2f,%.2f", a, c, w }'
}

mkdir -p build/whole-mac-draw
OUT="build/whole-mac-draw/$(date +%Y%m%d-%H%M)-$(IFS=-; echo "${LABELS[*]}").csv"

# Start on a whole minute, at least a minute away: the changes are then easy to follow
# on a clock, with the sound off.
now=$(date +%s)
START=$(( (now + 119) / 60 * 60 ))
echo "Put the app in its first state now: ${LABELS[0]}. Then change it at these times:"
i=0
for label in "${LABELS[@]}"; do
    printf '  %s  %s\n' "$(date -r $((START + i * PHASE)) +%H:%M)" "$label"
    i=$((i + 1))
done
printf '  %s  finished\n\n' "$(date -r $((START + ${#LABELS[@]} * PHASE)) +%H:%M)"

# Nobody touches the Mac for minutes: without this the screen would dim, then sleep, and
# that would dwarf what is measured. It ends with the recording (and by itself, at worst).
caffeinate -d -i -t $(( ${#LABELS[@]} * PHASE + 300 )) &
AWAKE=$!
trap 'kill "$AWAKE" 2>/dev/null' EXIT

echo "seconds,phase,label,system_load_mw,charger,app_cpu_s,camera_cpu_s,screen_cpu_s" > "$OUT"
/bin/sleep $((START - $(date +%s)))

last=-1
while :; do
    el=$(( $(date +%s) - START ))
    [ "$el" -ge $(( PHASE * ${#LABELS[@]} )) ] && break
    p=$((el / PHASE))
    if [ "$p" -ne "$last" ]; then
        printf '\a%s  now: %s\n' "$(date +%H:%M)" "${LABELS[$p]}"
        [ "$last" -ge 0 ] && say "Now: ${LABELS[$p]}" &
        last=$p
    fi
    L=$(battery)
    echo "$el,$p,${LABELS[$p]},$(get SystemLoad),$(get ExternalConnected),$(cpus)" >> "$OUT"
    /bin/sleep $STEP
done
printf '\a%s  finished\n\n' "$(date +%H:%M)"

awk -F, -v phase="$PHASE" -v settle="$SETTLE" '
NR > 1 {
    p = $2; t = $1 - p * phase; lab[p] = $3; if (p > top) top = p
    if ($5 != "No") plugged = 1
    if (!(p in a0)) { a0[p] = $6; c0[p] = $7; w0[p] = $8; t0[p] = $1 }
    a1[p] = $6; c1[p] = $7; w1[p] = $8; t1[p] = $1
    if ($4 != prev) {      # a new figure from the battery
        if (t >= settle) { n[p]++; s[p] += $4; if (min[p] == "" || $4 < min[p]) min[p] = $4; if ($4 > max[p]) max[p] = $4 }
        prev = $4
    }
}
END {
    for (p = 0; p <= top; p++) {
        d = t1[p] - t0[p]; if (d <= 0) d = 1
        if (n[p] > 0) printf "%-10s %5.2f W  (%d figures, %.2f to %.2f)", lab[p], s[p] / n[p] / 1000, n[p], min[p] / 1000, max[p] / 1000
        else printf "%-10s no figure after %d s: make the phases longer", lab[p], settle
        printf "   processor, of one core: app %4.1f%%, camera process %4.1f%%, screen %4.1f%%\n", 100 * (a1[p] - a0[p]) / d, 100 * (c1[p] - c0[p]) / d, 100 * (w1[p] - w0[p]) / d
    }
    if (plugged) print "The charger was connected during part of the run: do it again on the battery."
}' "$OUT"
echo "Every note is in $OUT"
