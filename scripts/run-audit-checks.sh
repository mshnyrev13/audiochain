#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
AUDIT_BIN="${1:-build-audit-candidate/AudioChain.app/Contents/MacOS/AudioChain}"
AUDIT_OUT="${2:-Audit/latest-run}"
mkdir -p "$AUDIT_OUT"
# No default device, nominal sample rate or physical buffer setters in these scenarios.
for check in self-test audit-regressions audit-signals audit-graph-bench audit-scan-tests session-history-test audit-project-tests; do
    "$AUDIT_BIN" "--$check" > "$AUDIT_OUT/$check.txt" 2>&1
done
# Real-time output is muted; diagnostics prefer a virtual Zoom device where available.
"$AUDIT_BIN" --audit-live-meters > "$AUDIT_OUT/live-meters.txt" 2>&1
"$AUDIT_BIN" --audit-state-tests > "$AUDIT_OUT/state.txt" 2>&1
"$AUDIT_BIN" --audit-devices > "$AUDIT_OUT/devices.json"
echo "Checks passed: $AUDIT_OUT"
