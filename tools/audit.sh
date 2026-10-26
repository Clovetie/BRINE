#!/usr/bin/env bash
# audit.sh — Run every BRINE analysis tool in one shot and write a combined
# report. Designed to be run by a future AI or in CI after any code change so
# it can answer "did I break the wiring, are there dead knobs, what's hot?"
#
#   bash tools/audit.sh                 # print everything to stdout
#   bash tools/audit.sh --json          # also write JSON reports into tools/reports/
#
# Each tool is independent; a single failure does not stop the others.

set -uo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TOOLS_DIR/.." && pwd)"
REPORT_DIR="$TOOLS_DIR/reports"

json=0
for arg in "$@"; do
	case "$arg" in
		--json) json=1 ;;
		*) : ;;
	esac
done

echo "==================================================================="
echo " BRINE audit — repo analysis for future iterations"
echo " root: $ROOT"
echo "-------------------------------------------------------------------"
echo ""

run() {
	local name="$1"; shift
	echo ""
	echo "─ [$name] $*"
	"$@"
	echo "──────────────────────────────────────────────"
}

if [ "$json" = "1" ]; then
	mkdir -p "$REPORT_DIR"
	echo "Writing JSON reports into $REPORT_DIR"
fi

# 1. Project / Rojo layout validation (catches layout mistakes + EditZone bug).
if [ "$json" = "1" ]; then
	run "validate-project" node "$TOOLS_DIR/validate-project.js" --json "$REPORT_DIR/project-validation.json"
else
	run "validate-project" node "$TOOLS_DIR/validate-project.js"
fi

# 2. Call graph: dependencies + orphaned/public-surface detection.
if [ "$json" = "1" ]; then
	run "call-graph" node "$TOOLS_DIR/call-graph.js" --json "$REPORT_DIR/call-graph.json"
else
	run "call-graph" node "$TOOLS_DIR/call-graph.js"
fi

# 3. Code metrics / complexity trend.
if [ "$json" = "1" ]; then
	run "metrics" node "$TOOLS_DIR/metrics.js" --json "$REPORT_DIR/metrics.json"
else
	run "metrics" node "$TOOLS_DIR/metrics.js"
fi

# 4. Dead config knobs.
if [ "$json" = "1" ]; then
	run "find-dead-config" node "$TOOLS_DIR/find-dead-config.js" --json "$REPORT_DIR/dead-config.json"
else
	run "find-dead-config" node "$TOOLS_DIR/find-dead-config.js"
fi

# 5. Hot-loop / per-frame risk scan.
if [ "$json" = "1" ]; then
	run "hot-loop-scan" node "$TOOLS_DIR/hot-loop-scan.js" --json "$REPORT_DIR/hot-loop-scan.json"
else
	run "hot-loop-scan" node "$TOOLS_DIR/hot-loop-scan.js"
fi

# 6. Syntax check (the project's own Luau-subset parser).
echo ""
echo "─ [check-syntax] node tools/check-syntax.js"
node "$TOOLS_DIR/check-syntax.js"
echo "──────────────────────────────────────────────"

# 7. Optional: model evaluation gate (fail-closed). Only run if files exist.
if [ -f "$TOOLS_DIR/models.example.json" ] && [ -f "$TOOLS_DIR/evaluation-suite.example.json" ]; then
	echo ""
	echo "─ [evaluate-models] candidate preflight gate"
	node "$TOOLS_DIR/evaluate-models.js" --models "$TOOLS_DIR/models.example.json" --suite "$TOOLS_DIR/evaluation-suite.example.json" --output "$REPORT_DIR/evaluation-report.json"
	echo "──────────────────────────────────────────────"
fi

echo ""
echo "==================================================================="
echo " audit complete."
if [ "$json" = "1" ]; then echo " JSON reports in $REPORT_DIR"; fi
echo "==================================================================="
