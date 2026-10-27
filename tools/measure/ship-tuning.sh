#!/usr/bin/env bash
# Per-hull handling table: top speed, acceleration, coast and turn radius.
# Runs the real src/ReplicatedStorage/ShipHandling/ShipDrive.luau under plain Luau.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LUAU="$ROOT/.tools/bin/luau"
OUT="$(mktemp /tmp/brine-ships-XXXXXX.luau)"
[ -x "$LUAU" ] || { echo "run: bash tools/setup-tools.sh" >&2; exit 1; }
{
	cat "$ROOT/tools/measure/shim.luau"; echo
	echo "-- ==== real module: ShipHandling/ShipDrive.luau ===="
	echo "local ShipDrive = (function()"
	cat "$ROOT/src/ReplicatedStorage/ShipHandling/ShipDrive.luau"
	echo "end)()"; echo
	cat "$ROOT/tools/measure/ship-tuning.luau"
} >"$OUT"
"$LUAU" "$OUT"; s=$?; rm -f "$OUT"; exit $s
