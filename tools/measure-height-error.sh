#!/usr/bin/env bash
# Runs BRINE's REAL ocean module under the plain Luau interpreter and reports
# the physics-vs-mesh height error (prompt 02, suspect S2).
#
# It assembles one file from five parts, in order:
#   1. tools/measure/shim.luau        Vector3 / Vector2 for a headless VM
#   2. src/.../Gerstner/init.luau     the real module, wrapped so its
#                                     `return Gerstner` becomes our local
#   3. tools/measure/stubs.luau       Settings / HeightLookup / game stubs
#   4. src/.../WaveFloat.luau         the real solver, verbatim
#   5. tools/measure/height-error.luau the measurement
#
# Nothing in src/ is modified. The Luau source is used verbatim, so this
# measures the shipped math, not a reimplementation of it.
#
# Usage: bash tools/measure-height-error.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LUAU="$ROOT/.tools/bin/luau"
OUT="$(mktemp /tmp/brine-height-error-XXXXXX.luau)"

if [ ! -x "$LUAU" ]; then
	echo "luau not found at $LUAU" >&2
	echo "run: bash tools/setup-tools.sh" >&2
	exit 1
fi

{
	cat "$ROOT/tools/measure/shim.luau"
	echo
	echo "-- ==== real module: src/ReplicatedStorage/Gerstner/init.luau (verbatim) ===="
	echo "local Gerstner = (function()"
	cat "$ROOT/src/ReplicatedStorage/Gerstner/init.luau"
	echo "end)()"
	echo
	cat "$ROOT/tools/measure/stubs.luau"
	echo
	echo "-- ==== real solver: src/ReplicatedStorage/FloatingObjectGeneration/WaveFloat.luau ===="
	echo "local WaveFloat = (function()"
	cat "$ROOT/src/ReplicatedStorage/FloatingObjectGeneration/WaveFloat.luau"
	echo "end)()"
	echo
	cat "$ROOT/tools/measure/height-error.luau"
} >"$OUT"

"$LUAU" "$OUT"
status=$?
rm -f "$OUT"
exit $status
