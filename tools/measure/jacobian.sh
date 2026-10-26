#!/usr/bin/env bash
# Measures whether the Gerstner displacement map folds over itself.
# See tools/measure/jacobian.luau for what and why.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LUAU="$ROOT/.tools/bin/luau"
OUT="$(mktemp /tmp/brine-jacobian-XXXXXX.luau)"
[ -x "$LUAU" ] || { echo "run: bash tools/setup-tools.sh" >&2; exit 1; }
{
	cat "$ROOT/tools/measure/shim.luau"; echo
	echo "-- ==== real module: Gerstner/init.luau ===="
	echo "local Gerstner = (function()"
	cat "$ROOT/src/ReplicatedStorage/Gerstner/init.luau"
	echo "end)()"; echo
	cat "$ROOT/tools/measure/stubs.luau"; echo
	cat "$ROOT/tools/measure/jacobian.luau"
} >"$OUT"
"$LUAU" "$OUT"; s=$?; rm -f "$OUT"; exit $s
