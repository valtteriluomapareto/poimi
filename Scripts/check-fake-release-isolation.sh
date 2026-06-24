#!/usr/bin/env bash
#
# check-fake-release-isolation.sh
#
# Enforces D30 (both halves of the Phase-1 exit criterion):
#   1. The test-double photo library (`FakePhotoLibrary` and any sibling `Fake*` doubles)
#      is compiled ONLY under Debug and inert in Release — guaranteed by wrapping each such
#      source in `#if DEBUG … #endif`.
#   2. The debug-only launch flags (`-PoimiUseFakeLibrary`, `-PoimiScreen`) are themselves
#      referenced only behind `#if DEBUG`, so a release build neither compiles the fake/harness
#      nor honors the flags.
#
# Language-level, build-config-agnostic, and checkable with grep. Inert before the fake /
# flag exist; load-bearing the moment they land.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="${REPO_ROOT}/App"

if [ ! -d "${APP_DIR}" ]; then
    echo "OK: no app sources yet."
    exit 0
fi

violations=0

requires_debug_gate() {
    # $1 = file, $2 = human reason
    if ! grep -Eq '^[[:space:]]*#if[[:space:]]+DEBUG' "$1"; then
        echo "::error file=$1::$2 (D30)."
        violations=$((violations + 1))
    fi
}

# 1. Fake double sources (name contains 'fake', case-insensitive) must be #if DEBUG-gated.
fake_count=0
while IFS= read -r file; do
    [ -z "${file}" ] && continue
    fake_count=$((fake_count + 1))
    requires_debug_gate "${file}" "Fake double must be wrapped in '#if DEBUG' so it cannot ship in Release"
done < <(find "${APP_DIR}" -path '*/PoimiAppTests/*' -prune -o -name '*.swift' -print | grep -iE '/[^/]*fake[^/]*\.swift$' || true)

# 2. Any source referencing a debug-only launch flag must be #if DEBUG-gated. New debug flags
#    (the screenshot harness's `-PoimiScreen`, etc.) join this alternation as they land.
flag_count=0
while IFS= read -r file; do
    [ -z "${file}" ] && continue
    flag_count=$((flag_count + 1))
    requires_debug_gate "${file}" "a debug launch flag (-PoimiUseFakeLibrary / -PoimiScreen) must be referenced only behind '#if DEBUG' so it is inert in Release"
done < <(grep -rlE '\-Poimi(UseFakeLibrary|Screen)' "${APP_DIR}" --include='*.swift' --exclude-dir=PoimiAppTests 2>/dev/null || true)

if [ "${violations}" -gt 0 ]; then
    echo "FAIL: ${violations} release-isolation violation(s)."
    exit 1
fi
echo "OK: ${fake_count} Fake* source(s) and ${flag_count} flag reference(s) are #if DEBUG-gated (release-inert, D30)."
