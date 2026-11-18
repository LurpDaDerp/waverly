#!/bin/bash
# Measures what a running Waverly costs: CPU and macOS "Energy Impact" of the app, its
# two Python helpers (hud-core, hud-engine) and its page's WebContent process, plus
# the whole Mac's battery discharge, over a given time. For checking battery drain
# before / after a change, with the Mac on battery and Waverly running in the background.
#
# Usage: scripts/power_bench.sh [-d SECONDS] [-i INTERVAL] [-a APP_NAME] [-w WEBCONTENT_PID]
#   -d  how long to measure (default 300 s)
#   -i  sampling interval for battery power and energy impact (default 10 s)
#   -a  the app's process name (default Waverly)
#   -w  the page's WebContent pid (default: the one the app logged at its last page load)
#
# Battery power is Voltage x InstantAmperage from the AppleSmartBattery registry entry;
# it is the whole Mac (display, Wi-Fi, other apps), so compare runs made under the same
# conditions (brightness, other apps quiet), or run once with Waverly quit as a baseline.
# Energy Impact is the POWER column of top(1), the number Activity Monitor shows.
# The app also logs a "power:" line every minute (camera mode, Vision runs, active
# seconds, the app's CPU time): the last ones are shown at the end.
set -euo pipefail

DURATION=300
INTERVAL=10
APP_NAME=Waverly
WEB_PID=""
while getopts "d:i:a:w:h" opt; do
  case $opt in
    d) DURATION=$OPTARG ;;
    i) INTERVAL=$OPTARG ;;
    a) APP_NAME=$OPTARG ;;
    w) WEB_PID=$OPTARG ;;
    *) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 2 ;;
  esac
done
LOG="$HOME/Library/Logs/$APP_NAME/app.log"

APP_PID=$(pgrep -x "$APP_NAME" | head -1 || true)
[ -n "$APP_PID" ] || { echo "$APP_NAME is not running"; exit 1; }
CORE_PID=$(pgrep -P "$APP_PID" -f "hud\.core" | head -1 || true)
ENGINE_PID=$(pgrep -P "$APP_PID" -f "hud\.engine" | head -1 || true)
if [ -z "$WEB_PID" ] && [ -f "$LOG" ]; then
  WEB_PID=$(grep -o "web content pid [0-9]*" "$LOG" | tail -1 | awk '{print $4}' || true)
fi
if [ -n "$WEB_PID" ] && ! ps -p "$WEB_PID" -o command= 2>/dev/null | grep -q WebContent; then
  WEB_PID=""                                     # stale (the page was reloaded since): not measured
fi

NAMES=("$APP_NAME (app)" "hud-core" "hud-engine" "WebContent (page)")
PIDS=("$APP_PID" "${CORE_PID:-}" "${ENGINE_PID:-}" "${WEB_PID:-}")

# ps cumulative CPU time ([[dd-]hh:]mm:ss.cc) in seconds; empty if the process is gone
cpu_seconds() {
  [ -n "$1" ] || return 0
  ps -o time= -p "$1" 2>/dev/null | awk '{
    t = $1; d = 0
    if (index(t, "-")) { split(t, a, "-"); d = a[1]; t = a[2] }
    n = split(t, p, ":"); s = 0
    for (i = 1; i <= n; i++) s = s * 60 + p[i]
    printf "%.2f", s + d * 86400 }'
}

# whole-Mac battery power in watts (negative = discharging) and whether the adapter is connected
battery_sample() {
  ioreg -rn AppleSmartBattery | awk -F' = ' '
    /"Voltage" =/ { v = $2 }
    /"InstantAmperage" =/ { ia = $2 }
    /"Amperage" =/ { a = $2 }
    /"ExternalConnected" =/ { ext = $2 }
    /"AppleRawMaxCapacity" =/ { cap = $2 }
    END { if (ia == "") ia = a; print v, ia, ext, cap }'
}

ON_AC=$(battery_sample | awk '{print $3}')
[ -n "$ON_AC" ] || { echo "no battery found (a desktop Mac?): only CPU and energy impact are measured"; }
echo "measuring $APP_NAME for ${DURATION} s (every ${INTERVAL} s)..."
[ "$ON_AC" = "Yes" ] && echo "note: the power adapter is connected; battery power then shows charging, not drain"
for k in "${!NAMES[@]}"; do
  printf "  %-20s pid %s\n" "${NAMES[$k]}" "${PIDS[$k]:-(not found)}"
done

TMP=$(mktemp -d)
trap 'kill "${TOP_PID:-}" 2>/dev/null || true; rm -rf "$TMP"' EXIT

declare -a CPU0
for k in "${!PIDS[@]}"; do CPU0[$k]=$(cpu_seconds "${PIDS[$k]}"); done
START=$(date +%s)

# energy impact: one top sample per interval (the first has no deltas and is skipped)
SAMPLES=$(( DURATION / INTERVAL ))
[ "$SAMPLES" -ge 1 ] || SAMPLES=1
top -l $(( SAMPLES + 1 )) -s "$INTERVAL" -stats pid,power -n 1000 > "$TMP/top.txt" 2>/dev/null &
TOP_PID=$!

: > "$TMP/battery.txt"
for (( n = 0; n < SAMPLES; n++ )); do
  sleep "$INTERVAL"
  V="" I="" EXT="" CAP=""
  read -r V I EXT CAP < <(battery_sample) || true
  if [ -n "$V" ] && [ -n "$I" ]; then
    I=$(( I ))                                   # unsigned 64-bit in the registry -> signed
    echo "$V $I ${EXT:-?} ${CAP:-0}" >> "$TMP/battery.txt"
  fi
done
wait "$TOP_PID" 2>/dev/null || true
ELAPSED=$(( $(date +%s) - START ))

echo
printf "%-20s %7s %9s %10s %15s\n" "process" "pid" "CPU s" "avg CPU %" "energy impact"
TOTAL_CPU=0
TOTAL_POWER=0
for k in "${!PIDS[@]}"; do
  pid=${PIDS[$k]}
  if [ -z "$pid" ]; then
    printf "%-20s %7s %9s %10s %15s\n" "${NAMES[$k]}" "-" "-" "-" "-"
    continue
  fi
  c1=$(cpu_seconds "$pid")
  if [ -z "$c1" ] || [ -z "${CPU0[$k]}" ]; then
    printf "%-20s %7s %9s %10s %15s\n" "${NAMES[$k]}" "$pid" "(exited)" "-" "-"
    continue
  fi
  d=$(awk -v a="${CPU0[$k]}" -v b="$c1" 'BEGIN { printf "%.2f", b - a }')
  pct=$(awk -v d="$d" -v t="$ELAPSED" 'BEGIN { printf "%.2f", 100 * d / t }')
  # rows "PID POWER" after each sample header; skip the first sample
  pw=$(awk -v pid="$pid" '
    /^PID/ { sample++; next }
    sample > 1 && $1 == pid { sum += $2; n++ }
    END { if (n) printf "%.2f", sum / n; else printf "-" }' "$TMP/top.txt")
  printf "%-20s %7s %9s %10s %15s\n" "${NAMES[$k]}" "$pid" "$d" "$pct" "$pw"
  TOTAL_CPU=$(awk -v a="$TOTAL_CPU" -v b="$d" 'BEGIN { printf "%.2f", a + b }')
  [ "$pw" != "-" ] && TOTAL_POWER=$(awk -v a="$TOTAL_POWER" -v b="$pw" 'BEGIN { printf "%.2f", a + b }')
done
printf "%-20s %7s %9s %10s %15s\n" "total" "" "$TOTAL_CPU" \
  "$(awk -v d="$TOTAL_CPU" -v t="$ELAPSED" 'BEGIN { printf "%.2f", 100 * d / t }')" "$TOTAL_POWER"

echo
if [ -s "$TMP/battery.txt" ]; then
  awk '{ w = $1 * $2 / 1e6; s += w; n++; if (n == 1 || w < lo) lo = w; if (n == 1 || w > hi) hi = w
         if ($3 == "Yes") ac++; wh = $4 * $1 / 1e6 }
    END {
      printf "battery (whole Mac): average %+.2f W (min %+.2f, max %+.2f) over %d samples; negative = discharging\n", s / n, lo, hi, n
      if (s < 0 && wh > 0) printf "  = %.2f W drain: %.1f%% of this battery (%.0f Wh at full charge) per hour\n", -s / n, 100 * (-s / n) / wh, wh
      if (ac) printf "  (power adapter connected for %d of the samples)\n", ac
    }' "$TMP/battery.txt"
else
  echo "battery: no readings"
fi

if [ -f "$LOG" ]; then
  echo
  echo "the app's last power lines ($LOG):"
  grep "power: camera" "$LOG" | tail -$(( (ELAPSED + 59) / 60 )) | sed 's/^/  /'
fi
