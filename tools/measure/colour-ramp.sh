#!/usr/bin/env bash
# Runs the REAL src/ReplicatedStorage/Gerstner/Helper.luau under the plain Luau interpreter and
# reports how much of the TROUGH -> CREST colour range the ocean's height ramp actually uses.
#
# Assembled in this order, because Helper reads workspace.Camera and its wave table at LOAD time:
#   1 tools/measure/shim.luau          Vector3 / Vector2
#   2 real Gerstner/init.luau          wrapped, so the stub can build its wave table with it
#   3 tools/measure/ramp-stubs.luau    Color3 / Camera / workspace / Settings
#   4 real Gerstner/Helper.luau        wrapped, `return Helper` becomes a local
#   5 tools/measure/colour-ramp.luau   the measurement
# Nothing in src/ is modified.
#
# Usage: bash tools/measure/colour-ramp.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LUAU="$ROOT/.tools/bin/luau"
OUT="$(mktemp /tmp/brine-colour-ramp-XXXXXX.luau)"

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
	cat "$ROOT/tools/measure/ramp-stubs.luau"
	echo
	echo "-- ==== real module: src/ReplicatedStorage/Gerstner/Helper.luau (verbatim) ===="
	echo "local Helper = (function()"
	cat "$ROOT/src/ReplicatedStorage/Gerstner/Helper.luau"
	echo "end)()"
	echo
	cat "$ROOT/tools/measure/colour-ramp.luau"
} >"$OUT"

"$LUAU" "$OUT"
status=$?
rm -f "$OUT"
exit $status
