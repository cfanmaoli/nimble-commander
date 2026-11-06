#!/bin/bash
# Measures the response to a single directory change (a file appearing) in the directory the app
# currently shows.
#
#   Scripts/perf/change_benchmark.sh <directory> [app-path]
set -euo pipefail

DIR=${1:?usage: change_benchmark.sh <directory> [app-path]}
APP=${2:-"/Applications/Nimble Commander-Fork.app/Contents/MacOS/Nimble Commander-Fork"}
LOG=$(mktemp -t nc_change_benchmark)

pkill -x "$(basename "$APP")" 2>/dev/null || true
for _ in $(seq 1 60); do pgrep -x "$(basename "$APP")" >/dev/null || break; sleep 0.2; done
sleep 2

cd /
NC_PERF_LOG=1 "$APP" -ApplePersistenceIgnoreState YES > "$LOG" 2>&1 &
sleep 6
open -a "$APP" "$DIR"
sleep 12

for n in 1 2 3; do
    : > "$DIR/.perf_probe_$n"
    sleep 1.5
done

grep -E '\[perf\] (incr|change)' "$LOG" | tail -8

for n in 1 2 3; do rm -f "$DIR/.perf_probe_$n"; done
pkill -x "$(basename "$APP")" 2>/dev/null || true
rm -f "$LOG"
