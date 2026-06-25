#!/usr/bin/env bash
#
# check-no-grouping-in-views.sh
#
# Smoothness guard (docs/reviews/ui-smoothness-review.md, Finding 1).
#
# `DayGrouping.groups(...)` is an O(n log n) sort + bucket over the WHOLE candidate set. It
# must be computed exactly once, in `CandidateStore`, when the fetch settles to `.ready` — and
# never inside a SwiftUI `View`. A view `body` re-evaluates on incidental state writes (most
# sharply, the `.scrollPosition` anchor write on the review grid), so grouping in a body would
# recompute the whole timeline on the scroll/tap interaction hot path.
#
# Fails (exit 1) if `DayGrouping.groups(` appears in any `*View.swift` under App/PoimiApp,
# ignoring comments (so a doc comment that *mentions* the rule does not trip it).
#
#     ./Scripts/check-no-grouping-in-views.sh
#
# Pure-bash heuristic (no toolchain dependency), mirroring check-curation-boundary.sh.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCAN_DIR="${REPO_ROOT}/App/PoimiApp"

# strip_comments <file>: emit the file's code with `/* */` block and `//` line comments removed,
# preserving line numbers, so prose mentioning the rule cannot match. (Same state machine as the
# domain-boundary guard.)
strip_comments() {
    awk '
        BEGIN { in_block = 0 }
        {
            line = $0; out = ""; i = 1; n = length(line)
            while (i <= n) {
                two = substr(line, i, 2)
                if (in_block) {
                    if (two == "*/") { in_block = 0; out = out " "; i += 2 } else { i += 1 }
                } else {
                    if (two == "/*") { in_block = 1; out = out " "; i += 2 }
                    else if (two == "//") { break }
                    else { out = out substr(line, i, 1); i += 1 }
                }
            }
            print out
        }
    ' "$1"
}

pattern='DayGrouping\.groups[[:space:]]*\('
status=0

while IFS= read -r -d '' file; do
    if strip_comments "${file}" | grep -qE "${pattern}"; then
        strip_comments "${file}" | grep -nE "${pattern}" | sed "s#^#${file}: #" >&2
        echo "error: ${file} calls DayGrouping.groups inside a View — group once in CandidateStore, not in a body (smoothness, Finding 1)." >&2
        status=1
    fi
done < <(find "${SCAN_DIR}" -name '*View.swift' -type f -print0)

if [[ "${status}" -eq 0 ]]; then
    echo "OK: no SwiftUI View calls DayGrouping.groups (grouping stays in CandidateStore)."
fi

exit "${status}"
