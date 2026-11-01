#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Run every PC-side check that needs neither a build nor a board, in one command:
# both boards' memory maps, the guests' MACs, DomZ's static half (which runs the
# yaml drift check first), the internal-reference lint and build.sh's syntax. Each
# check's own output is shown only when it fails. Exit status: the number of failed
# checks (0 = all passed).
cd "$(dirname "$0")/.." || exit 1
failed=0
run() {
	local name=$1; shift
	local out
	if out=$("$@" 2>&1); then
		echo "PASS: $name"
	else
		echo "FAIL: $name"
		printf '%s\n' "$out" | sed 's/^/      /'
		failed=$((failed + 1))
	fi
}
run "check-memory-map.py (Raspberry Pi 5)" python3 tools/check-memory-map.py
run "check-rpi4-memory-map.py" python3 tools/check-rpi4-memory-map.py
run "check-net-macs.py" python3 tools/check-net-macs.py
run "check-domz.sh --quick" ./tools/check-domz.sh --quick
run "check-no-internal-refs.py" python3 tools/check-no-internal-refs.py
run "bash -n build.sh" bash -n build.sh
echo
echo "$failed check(s) failed"
exit "$failed"
