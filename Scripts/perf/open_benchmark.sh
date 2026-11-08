#!/bin/bash
# Measures how long the app takes to put a directory on screen, and how much memory it holds.
#
#   Scripts/perf/open_benchmark.sh <directory> [app-path]
#
# The app is started with -ApplePersistenceIgnoreState YES: without it AppKit restores the
# previously opened directory and the measurements are meaningless.
set -euo pipefail

DIR=${1:?usage: open_benchmark.sh <directory> [app-path]}
APP=${2:-"/Applications/Nimble Commander-Fork.app/Contents/MacOS/Nimble Commander-Fork"}
LOG=$(mktemp -t nc_open_benchmark)

pkill -x "$(basename "$APP")" 2>/dev/null || true
for _ in $(seq 1 60); do pgrep -x "$(basename "$APP")" >/dev/null || break; sleep 0.2; done
sleep 2

cd /
NC_PERF_LOG=1 "$APP" -ApplePersistenceIgnoreState YES > "$LOG" 2>&1 &
sleep 7

PID=$(pgrep -x "$(basename "$APP")" | head -1)
BEFORE=$(vmmap -summary "$PID" 2>/dev/null | awk '/Physical footprint:/{print $3; exit}')

open -a "$APP" "$DIR"
sleep 16

AFTER=$(vmmap -summary "$PID" 2>/dev/null | awk '/Physical footprint:/{print $3; exit}')

echo "baseline footprint:  $BEFORE"
echo "loaded footprint:    $AFTER"
echo
grep -E '\[perf\] (preview|fetch|prepare|ui) ' "$LOG" | tail -8

pkill -x "$(basename "$APP")" 2>/dev/null || true
rm -f "$LOG"
