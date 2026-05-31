#!/usr/bin/env bash
# Run all headless GDScript test suites for OpenStreetMap Racer.
#
# Usage:
#   tests/run_tests.sh            # uses `godot` from PATH
#   GODOT=/path/to/godot tests/run_tests.sh
#
# Exits non-zero if any suite fails, so it is safe to use in CI.
set -euo pipefail

GODOT="${GODOT:-godot}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

status=0
for test_file in "${SCRIPT_DIR}"/test_*.gd; do
	rel="res://tests/$(basename "${test_file}")"
	echo "── Running ${rel}"
	if ! "${GODOT}" --headless --path "${PROJECT_DIR}" --script "${rel}"; then
		status=1
	fi
done

if [ "${status}" -eq 0 ]; then
	echo "All test suites passed."
else
	echo "One or more test suites FAILED."
fi
exit "${status}"
