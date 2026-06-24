#!/usr/bin/env bash
#
# check-liquid-glass.sh
#
# Enforces the "pure Liquid Glass" invariant (architecture §6; plan-review round-2):
# the app targets iOS 26 with no install base to protect, so glass chrome is native
# and there must be NO SDK-version availability gates and NO pre-glass material
# fallbacks (`.regularMaterial` & friends) standing in for `glassEffect`. This
# parallels the Curation boundary guard.
#
# Exempt:
#   • Reduce-Transparency / accessibility opaque appearances are a *different* axis
#     (every custom glass surface defines one) — those use opaque colors, not the
#     forbidden material/version patterns, so they don't trip this check.
#   • A deliberate, conscious fallback (the "drop a surface to plain material if an
#     API regresses" escape hatch) can opt a single line out with a trailing
#     `// liquid-glass-ok` marker.
#
# Heuristic bash guard (no toolchain dependency), mirroring check-curation-boundary.sh:
# it scans real app SwiftUI sources, skips whole-line comments (which merely discuss
# the rule), and skips lines carrying the opt-out marker.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Real app UI only. The throwaway Phase-0 Spike is not held to the glass invariant.
SCAN_DIR="${REPO_ROOT}/App/PoimiApp/Sources"

# Forbidden: iOS version-availability gates, and the pre-glass material APIs used as a
# version fallback.
FORBIDDEN_REGEX='#available\(iOS|(\.(ultraThin|thin|regular|thick|ultraThick)Material)\b'

OPT_OUT_MARKER='liquid-glass-ok'

if [ ! -d "${SCAN_DIR}" ]; then
    echo "OK: no app sources to scan yet (${SCAN_DIR} absent)."
    exit 0
fi

violations=0
while IFS= read -r -d '' file; do
    lineno=0
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        # Skip whole-line comments (they may discuss the rule) and opt-out lines.
        trimmed="${line#"${line%%[![:space:]]*}"}"
        case "${trimmed}" in
            //*) continue ;;
        esac
        case "${line}" in
            *"${OPT_OUT_MARKER}"*) continue ;;
        esac
        if printf '%s' "${line}" | grep -Eq "${FORBIDDEN_REGEX}"; then
            echo "::error file=${file},line=${lineno}::Liquid Glass invariant: forbidden version gate / material fallback — use glassEffect, or mark a conscious exception with // ${OPT_OUT_MARKER}"
            echo "  ${file}:${lineno}: ${line}"
            violations=$((violations + 1))
        fi
    done < "${file}"
done < <(find "${SCAN_DIR}" -name '*.swift' -print0)

if [ "${violations}" -gt 0 ]; then
    echo "FAIL: ${violations} Liquid Glass invariant violation(s)."
    exit 1
fi
echo "OK: no SDK-version gates or material fallbacks in app UI (pure Liquid Glass)."
