#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# measure-weston-load.sh: measure weston's CPU and memory load over time.
#
# Measure weston's CPU and memory load while the guests render, to check it leaves
# headroom on the shared V3D.
#
# Method:
#   - start weston-simple-egl (V3D direct GPU pipeline)
#   - start weston-terminal (GUI client)
#   - sample weston-debug frame timing for the given duration
#   - report average / minimum / maximum weston CPU usage
#
# Usage:
#   measure-weston-load.sh [duration-sec]
# Default duration: 60 s

set -e

DURATION="${1:-60}"
LOG="/tmp/weston-fps-$(date +%s).log"

echo "[load-measure] Renderer: $(grep -E '^renderer' /etc/xdg/weston/weston.ini 2>/dev/null || echo 'default (gl)')"
echo "[load-measure] Duration: ${DURATION}s"
echo "[load-measure] Log: $LOG"

# 1. start weston-simple-egl in the background
weston-simple-egl &
EGL_PID=$!
echo "[load-measure] weston-simple-egl PID=$EGL_PID"

# 2. start weston-terminal (GUI load)
if command -v weston-terminal >/dev/null 2>&1; then
    weston-terminal &
    TERM_PID=$!
    echo "[load-measure] weston-terminal PID=$TERM_PID"
fi

# 3. record the start time and CPU usage
START="$(date +%s)"
echo "[load-measure] Sampling for ${DURATION}s..."

# Get frame timing via the weston debug protocol (if available).
# Fallback: top -bn N for the weston process CPU usage.
TOP_INTERVAL=5
SAMPLES=$((DURATION / TOP_INTERVAL))

for i in $(seq 1 $SAMPLES); do
    NOW="$(date +%s)"
    ELAPSED=$((NOW - START))
    if [ "$ELAPSED" -ge "$DURATION" ]; then break; fi

    # CPU usage (weston process)
    CPU="$(top -b -n 1 -p $(pidof weston | tr ' ' ',') 2>/dev/null \
            | tail -n +8 | awk '{sum += $9} END { printf "%.1f", sum }')"
    # memory usage (weston RSS)
    MEM="$(ps -o rss= -p $(pidof weston | head -1) 2>/dev/null | awk '{print int($1/1024)}')"
    # 1-second load average
    LOAD="$(awk '{print $1}' /proc/loadavg)"

    printf "[%4ds] weston CPU=%5s%% RSS=%4sMB load=%s\n" "$ELAPSED" "$CPU" "$MEM" "$LOAD" | tee -a "$LOG"
    sleep $TOP_INTERVAL
done

# 4. cleanup
kill $EGL_PID 2>/dev/null || true
kill $TERM_PID 2>/dev/null || true

# 5. summarize results
echo ""
echo "[load-measure] ===== Summary ====="
echo "Log: $LOG"
echo ""
if [ -f "$LOG" ]; then
    awk '
        /weston CPU/ {
            cpu = $4; sub("%", "", cpu); sub("CPU=", "", cpu);
            sum += cpu; count++;
            if (count == 1 || cpu < min) min = cpu;
            if (cpu > max) max = cpu;
        }
        END {
            if (count > 0) {
                printf "weston CPU usage: avg=%.1f%% min=%.1f%% max=%.1f%% samples=%d\n",
                       sum/count, min, max, count;
            }
        }
    ' "$LOG"
fi

echo ""
echo "[load-measure] Done. Next: optionally start weston-simple-egl manually and inspect the animation."
echo ""
echo "Acceptance criteria (pixman production):"
echo "  - weston CPU < 80% sustained = the compositor has spare headroom"
echo "  - weston CPU > 95% sustained = possible framerate drop, consider another renderer"
