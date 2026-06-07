#!/usr/bin/env bash
# Run all GDScript test suites for OpenStreetMap Racer via gdUnit4.
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

"${GODOT}" --headless --path "${PROJECT_DIR}" \
	-s addons/gdUnit4/bin/GdUnitCmdTool.gd \
	--ignoreHeadlessMode \
	-a tests
