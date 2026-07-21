#!/usr/bin/env bash
#
# check-curation-boundary.sh
#
# Enforces the domain boundary invariant (D14/D21): the pure `Curation` package
# must stay free of platform frameworks and main-actor isolation, so it remains
# fully unit-testable with no simulator and no real photo library.
#
# Fails (exit 1) if any Swift source under Curation/Sources OR Curation/Tests
# imports a forbidden framework or uses @MainActor. (Tests are scanned too: a
# test that imported Photos/SwiftData would re-couple the domain to a platform.)
# Run locally or from CI:
#
#     ./Scripts/check-curation-boundary.sh
#
# This is a heuristic guard implemented in pure bash (no toolchain dependency),
# not a Swift lexer. It defends against the realistic ways a forbidden import or
# main-actor attribute can sneak in (block comments, trailing comments,
# semicolon-joined statements, submodule imports, @preconcurrency import) while
# avoiding the realistic false positives (doc/line comments that *discuss* the
# boundary). String-literal mentions are a known residual: a forbidden token
# embedded only inside a "..." literal could still trip the check, but that does
# not occur in this pure value package and is not worth a full lexer.
#
set -euo pipefail

# Resolve repo root from this script's location so it works from any CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Scan both production sources AND tests. A test target can import platform
# frameworks just as easily as a source file, so the boundary must cover both.
SCAN_DIRS=(
    "${REPO_ROOT}/Curation/Sources"
    "${REPO_ROOT}/Curation/Tests"
)

# Forbidden imports (whole-word match on the module name after `import`).
# MapKit/Contacts/CoreGraphics are pre-emptive (no current violation, #213 Layer 1): CLGeocoder is
# soft-deprecated toward MapKit's MKReverseGeocodingRequest and CLPlacemark exposes a Contacts
# CNPostalAddress, so a future geocoding migration is the realistic path a geo/geometry framework
# would first reach the pure domain — and AssetRef deliberately avoids CGSize (uses PixelSize).
FORBIDDEN_IMPORTS=(Photos PhotoKit PhotosUI SwiftData UIKit SwiftUI AppKit Combine CoreLocation MapKit Contacts CoreGraphics)

status=0

# Collect Swift sources across all scan dirs.
SWIFT_FILES=()
for dir in "${SCAN_DIRS[@]}"; do
    [[ -d "${dir}" ]] || continue
    while IFS= read -r -d '' f; do
        SWIFT_FILES+=("$f")
    done < <(find "${dir}" -name '*.swift' -type f -print0)
done

if [[ "${#SWIFT_FILES[@]}" -eq 0 ]]; then
    echo "error: no Swift sources found to scan under Curation/Sources or Curation/Tests" >&2
    exit 2
fi

# strip_comments <file>: emit the file's "code" view with comments removed so
# that prose mentioning forbidden tokens (the doc comment that explains *why*
# Curation avoids @MainActor and Photos, for example) cannot trip the matchers.
#
# Handled, in order:
#   1. `/* ... */` block comments, including multi-line ones — collapsed to a
#      space so tokens on either side don't accidentally fuse.
#   2. trailing/full `//` line comments — everything from `//` to EOL dropped.
#
# Implemented with awk (POSIX, ships everywhere bash does) using a tiny state
# machine for the multi-line block-comment case. Line numbers are preserved
# (blanked lines are kept) so reported hits map back to the original file.
strip_comments() {
    awk '
        BEGIN { in_block = 0 }
        {
            line = $0
            out = ""
            i = 1
            n = length(line)
            while (i <= n) {
                two = substr(line, i, 2)
                if (in_block) {
                    if (two == "*/") { in_block = 0; out = out " "; i += 2 }
                    else { i += 1 }
                } else {
                    if (two == "/*") { in_block = 1; out = out " "; i += 2 }
                    else if (two == "//") { break }   # rest of line is a comment
                    else { out = out substr(line, i, 1); i += 1 }
                }
            }
            print out
        }
    ' "$1"
}

# matches_code <file> <regex>: true if the comment-stripped code matches.
matches_code() {
    strip_comments "$1" | grep -qE "$2"
}

# report_code <file> <regex>: print offending lines (with original line numbers
# and file prefix) from the comment-stripped view.
report_code() {
    strip_comments "$1" | grep -nE "$2" | sed "s#^#${1}: #"
}

for file in "${SWIFT_FILES[@]}"; do
    for module in "${FORBIDDEN_IMPORTS[@]}"; do
        # Match an `import <module>` token *anywhere* on a line (not just at line
        # start) so a semicolon-joined statement like `let x = 1; import Photos`
        # is caught. A leading attribute such as `@preconcurrency import` is
        # tolerated by the optional `@attr ` prefix. The module name must be
        # whole-word: a trailing boundary of whitespace, `.` (submodule import
        # like `import Photos.PHAsset`), `;`, or end-of-string — so module names
        # that merely *start* with a forbidden one (SwiftDataKit, PhotosUtilities,
        # UIKitBridge) do NOT match.
        import_re="(^|[[:space:]]|;)(@[A-Za-z_]+[[:space:]]+)?import[[:space:]]+${module}([[:space:]]|\.|;|$)"
        if matches_code "${file}" "${import_re}"; then
            report_code "${file}" "${import_re}" >&2
            echo "error: Curation must not import ${module} (domain boundary, D14/D21)" >&2
            status=1
        fi
    done

    # Forbid @MainActor *as an attribute*. Anchor to attribute position: `@MainActor`
    # at the very start of a token (start-of-line/whitespace/`(`/`;` before the `@`),
    # so a doc/line comment that merely mentions "@MainActor" (already stripped) or a
    # symbol containing the substring won't match. Comment stripping above removes the
    # realistic prose false positive; this anchoring is the second line of defence.
    mainactor_re="(^|[[:space:]]|\(|;)@MainActor([[:space:]]|\(|$)"
    if matches_code "${file}" "${mainactor_re}"; then
        report_code "${file}" "${mainactor_re}" >&2
        echo "error: Curation must not use @MainActor (it is platform/UI-agnostic)" >&2
        status=1
    fi
done

if [[ "${status}" -eq 0 ]]; then
    echo "OK: Curation imports no forbidden frameworks and uses no @MainActor."
fi

exit "${status}"
