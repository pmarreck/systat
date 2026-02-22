#!/usr/bin/env bash
# Smoke test: launch systat, verify it doesn't crash, kill it.
# Usage: ./scripts/smoke_test.sh [path-to-binary]
set -euo pipefail

BINARY="${1:-zig-out/bin/systat}"
WAIT_SECONDS=3

if [ ! -x "$BINARY" ]; then
	echo "FAIL: binary not found or not executable: $BINARY"
	exit 1
fi

echo "Smoke test: launching $BINARY..."
"$BINARY" &
PID=$!

# Give it time to init and render first frames
sleep "$WAIT_SECONDS"

# Check if still running (not crashed)
if kill -0 "$PID" 2>/dev/null; then
	echo "PASS: systat (pid $PID) survived ${WAIT_SECONDS}s without crashing"
	kill "$PID" 2>/dev/null || true
	wait "$PID" 2>/dev/null || true
	exit 0
else
	# Process died — check how
	wait "$PID" 2>/dev/null
	EXIT_CODE=$?
	if [ $EXIT_CODE -gt 128 ]; then
		SIGNAL=$((EXIT_CODE - 128))
		echo "FAIL: systat crashed with signal $SIGNAL (exit code $EXIT_CODE)"
	else
		echo "FAIL: systat exited prematurely with code $EXIT_CODE"
	fi
	exit 1
fi
