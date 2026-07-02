#!/usr/bin/env bash
#
# coverage-summary.sh — an ADVISORY code-coverage report (issue #110). NOT a gate.
#
# Per D28 the project deliberately doesn't over-gate; this only *surfaces* coverage in the CI step
# summary. It reports the tiers where line coverage is actually meaningful, and is honest about the
# one where it isn't:
#
#   • Curation (pure domain)   — the primary signal; unit/property-tested via `swift test`. Clean.
#   • App store tier           — the stores + model (State/, Persistence/, CandidateStore): pure
#                                logic co-located in the app target, exercised by the integration tier.
#   • PoimiApp.app (overall)   — context only, expected LOW: SwiftUI view bodies are eyeballed via the
#                                screenshot harness (D26/D27), not unit-tested. We do not gate on it.
#
# Inputs (produced by the CI test steps):
#   $1 = path to the app test result bundle (default build/PoimiApp.xcresult), from
#        `xcodebuild test … -enableCodeCoverage YES -resultBundlePath <path>`.
#   Curation coverage from `swift test --package-path Curation --enable-code-coverage` (this script
#   locates the JSON via `--show-codecov-path`).
#
# Requires jq + xcrun (present on the macos-26 CI image). ALWAYS exits 0 — advisory, never blocks CI.
#
set -uo pipefail

XCRESULT="${1:-build/PoimiApp.xcresult}"
# Pure-logic files in the app target (no SwiftUI view bodies) — the store tier worth a coverage signal.
LOGIC_RE='/State/|/Persistence/|/Review/CandidateStore\.swift'

pct1() { awk 'BEGIN { printf "%.1f", '"$1"' }'; }   # one-decimal format, locale-independent

echo "## Code coverage (advisory)"
echo
echo "_Not a gate (D28). SwiftUI view bodies are eyeballed via the screenshot harness (D26/D27), not"
echo "unit-tested — so the app-target % is low **by design**. The meaningful signals are the pure"
echo "domain and the store tier below._"
echo

# --- Curation (pure domain) -------------------------------------------------
echo "### Curation — pure domain"
if cov_json="$(swift test --package-path Curation --show-codecov-path 2>/dev/null)" && [ -f "$cov_json" ]; then
  read -r pct covered count < <(jq -r '.data[0].totals.lines | "\(.percent) \(.covered) \(.count)"' "$cov_json" 2>/dev/null)
  if [ -n "${pct:-}" ] && [ "$pct" != "null" ]; then
    echo "**$(pct1 "$pct")%** lines ($covered / $count)"
  else
    echo "_Coverage JSON present but unparseable._"
  fi
else
  echo "_No Curation coverage data (was \`swift test --enable-code-coverage\` run?)._"
fi
echo

# --- App store tier + overall (context) ------------------------------------
echo "### App — store tier"
if [ -d "$XCRESULT" ] && report="$(xcrun xccov view --report --json "$XCRESULT" 2>/dev/null)"; then
  # Per-file coverage for the pure-logic files, plus their aggregate.
  echo "| File | Lines |"
  echo "| --- | --- |"
  echo "$report" | jq -r --arg re "$LOGIC_RE" '
    [.targets[].files[] | select(.path | test($re))] | sort_by(.name)[]
    | "| \(.name) | \((.lineCoverage * 100) | (. * 10 | round / 10))% |"'
  agg="$(echo "$report" | jq -r --arg re "$LOGIC_RE" '
    [.targets[].files[] | select(.path | test($re))]
    | (map(.coveredLines) | add) as $c | (map(.executableLines) | add) as $e
    | if $e > 0 then "\($c) \($e) \(($c / $e) * 100)" else empty end')"
  if [ -n "$agg" ]; then
    read -r c e p <<< "$agg"
    echo
    echo "**Aggregate: $(pct1 "$p")%** ($c / $e lines)"
  fi

  echo
  echo "<details><summary>All targets (context)</summary>"
  echo
  echo "| Target | Line coverage |"
  echo "| --- | --- |"
  echo "$report" | jq -r '.targets[] | "| \(.name) | \((.lineCoverage * 100) | (. * 10 | round / 10))% |"'
  echo
  echo "_\`PoimiApp.app\` overall is low because it includes view bodies (not unit-tested, D26/D27); the"
  echo "\`Curation\` row here is only what the **app** tests exercise — its real coverage is the pure-domain"
  echo "number above (its own \`swift test\` suite)._"
  echo "</details>"
else
  echo "_No app coverage data at \`$XCRESULT\`._"
fi

exit 0
