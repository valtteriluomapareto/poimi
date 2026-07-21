#!/usr/bin/env bash
#
# check-photos-sacrosanct.sh
#
# Enforces the "Photos are sacrosanct" invariant (D31): Poimi curates INTO a native
# Photos album (create-or-find + addAssets) but must NEVER remove from, or delete
# out of, the user's photo library. Export is one-way; deleting a Poimi project
# touches only our own SwiftData record, never the user's photos/albums/originals.
#
# This is the single most safety-critical invariant — a regression risks the user's
# irreplaceable library — yet it had no automated guard (review-only) until #213
# Layer 1. This grep-guard fails (exit 1) if a destructive PhotoKit call appears in
# the app sources.
#
#     ./Scripts/check-photos-sacrosanct.sh
#
# Forbidden tokens (PHAssetChangeRequest / PHAssetCollectionChangeRequest destructive
# APIs). A conscious, reviewed exception can opt a line out with a trailing
# `// photos-sacrosanct-ok` marker (mirrors the Liquid Glass guard) — but that should
# essentially never happen in this app.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCAN_DIR="${REPO_ROOT}/App/PoimiApp"

if [ ! -d "${SCAN_DIR}" ]; then
    echo "OK: no app sources to scan yet (${SCAN_DIR} absent)."
    exit 0
fi

# Destructive PhotoKit library mutations. `deleteAssets` deletes originals from the
# whole library; `removeAssets` strips them from an album; `removeFromAlbum` is a
# defensive catch-all for any future helper. Word-ish boundaries keep `deleteAssets`
# from matching an unrelated `deleteAssetsFromOurCache`-style name only if such a name
# lacks the token — the tokens here are PhotoKit-specific enough to be safe.
FORBIDDEN_REGEX='(deleteAssets|removeAssets|removeFromAlbum)\b'
OPT_OUT_MARKER='photos-sacrosanct-ok'

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
            echo "::error file=${file},line=${lineno}::Photos-sacrosanct invariant (D31): destructive PhotoKit call — Poimi never removes/deletes from the user's library. Mark a reviewed exception with // ${OPT_OUT_MARKER}"
            echo "  ${file}:${lineno}: ${line}"
            violations=$((violations + 1))
        fi
    done < "${file}"
done < <(find "${SCAN_DIR}" -name '*.swift' -type f -print0)

if [ "${violations}" -gt 0 ]; then
    echo "FAIL: ${violations} photos-sacrosanct violation(s)."
    exit 1
fi
echo "OK: no destructive PhotoKit calls in app UI (Photos sacrosanct, D31)."
