#!/usr/bin/env bash
#
# check-curation-boundary.sh
#
# Enforces the domain boundary invariant (D14/D21): the pure `Curation` package
# must stay free of platform frameworks and main-actor isolation, so it remains
# fully unit-testable with no simulator and no real photo library.
#
# Fails (exit 1) if any Swift source under Curation/Sources imports a forbidden
# framework or uses @MainActor. Run locally or from CI:
#
#     ./Scripts/check-curation-boundary.sh
#
set -euo pipefail

# Resolve repo root from this script's location so it works from any CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCES_DIR="${REPO_ROOT}/Curation/Sources"

if [[ ! -d "${SOURCES_DIR}" ]]; then
    echo "error: Curation sources not found at ${SOURCES_DIR}" >&2
    exit 2
fi

# Forbidden imports (whole-word match on the module name after `import`).
FORBIDDEN_IMPORTS=(Photos PhotoKit PhotosUI SwiftData UIKit SwiftUI AppKit Combine CoreLocation)

status=0

# Collect Swift sources, then strip full-line `//` comments before matching so that
# the doc comments (which legitimately discuss the forbidden APIs) don't trip the
# check. This is a heuristic guard, not a parser; block comments / string literals
# mentioning these tokens are rare in this pure package and not worth a real lexer.
SWIFT_FILES=()
while IFS= read -r -d '' f; do
    SWIFT_FILES+=("$f")
done < <(find "${SOURCES_DIR}" -name '*.swift' -type f -print0)

# code_only <file>: echo the file with whole-line comments removed (keeps line numbers
# via grep -n done by the caller on the original file for forbidden hits).
matches_code() {
    # $1 = file, $2 = extended regex
    # Drop lines whose first non-space chars are `//`, then match.
    grep -vE '^[[:space:]]*//' "$1" | grep -nE "$2" >/dev/null
}

report_code() {
    # $1 = file, $2 = extended regex (prints offending lines with file + content)
    grep -vE '^[[:space:]]*//' "$1" | grep -nE "$2" | sed "s#^#${1}: #"
}

for file in "${SWIFT_FILES[@]}"; do
    for module in "${FORBIDDEN_IMPORTS[@]}"; do
        import_re="^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)?import[[:space:]]+${module}([[:space:]]|\.|$)"
        if matches_code "${file}" "${import_re}"; then
            report_code "${file}" "${import_re}" >&2
            echo "error: Curation must not import ${module} (domain boundary, D14/D21)" >&2
            status=1
        fi
    done

    # Forbid @MainActor as an attribute (free of main-actor isolation).
    if matches_code "${file}" "@MainActor"; then
        report_code "${file}" "@MainActor" >&2
        echo "error: Curation must not use @MainActor (it is platform/UI-agnostic)" >&2
        status=1
    fi
done

if [[ "${status}" -eq 0 ]]; then
    echo "OK: Curation imports no forbidden frameworks and uses no @MainActor."
fi

exit "${status}"
