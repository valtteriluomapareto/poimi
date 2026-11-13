#!/usr/bin/env bash
#
# check-fake-release-isolation.sh
#
# Enforces D30 (both halves of the Phase-1 exit criterion):
#   1. The test-double photo library (`FakePhotoLibrary` and any sibling `Fake*` doubles)
#      is compiled ONLY under Debug and inert in Release — guaranteed by wrapping each such
#      source in `#if DEBUG … #endif`.
#   2. The debug-only launch flags (`-PoimiUseFakeLibrary`, `-PoimiScreen`, `-PoimiControl`, …) are
#      themselves referenced only behind `#if DEBUG`, so a release build neither compiles the
#      fake/harness nor honors the flags.
#   3. Every control-plane source (`App/PoimiApp/Control/`, #296) is `#if DEBUG` as a whole file.
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

# 2. Any source referencing a `-Poimi*` launch flag must be #if DEBUG-gated. The pattern matches
#    every such flag (the fake swap, the screenshot harness's `-PoimiScreen`, the spike's
#    `-PoimiSpike*`, and any added later) so the guard can't fall behind a new flag.
flag_count=0
while IFS= read -r file; do
    [ -z "${file}" ] && continue
    flag_count=$((flag_count + 1))
    requires_debug_gate "${file}" "a -Poimi* debug launch flag must be referenced only behind '#if DEBUG' so it is inert in Release"
done < <(grep -rlE '\-Poimi[A-Za-z]+' "${APP_DIR}" --include='*.swift' --exclude-dir=PoimiAppTests 2>/dev/null || true)

# 3. The control plane (`App/PoimiApp/Control/`, #296) is DEBUG-only as WHOLE files: the first code
#    line (after the header comment) is `#if DEBUG` and the last non-blank line is `#endif`. Stricter
#    than (1)/(2) on purpose — "a `#if DEBUG` somewhere" would let a Release-visible type slip in
#    above or below the gate.
control_count=0
while IFS= read -r file; do
    [ -z "${file}" ] && continue
    control_count=$((control_count + 1))
    first="$(grep -vE '^[[:space:]]*(//.*)?$' "${file}" | head -1 | sed -E 's/[[:space:]]+$//')"
    last="$(grep -vE '^[[:space:]]*$' "${file}" | tail -1 | sed -E 's/[[:space:]]+$//')"
    if [ "${first}" != "#if DEBUG" ] || [ "${last}" != "#endif" ]; then
        echo "::error file=${file}::control-plane source must be wrapped WHOLE in '#if DEBUG' … '#endif' (first code line / last line) so none of it ships in Release (D30)."
        violations=$((violations + 1))
    fi
done < <(find "${APP_DIR}" -path '*/PoimiAppTests/*' -prune -o -path '*/Control/*' -name '*.swift' -print)

if [ "${violations}" -gt 0 ]; then
    echo "FAIL: ${violations} release-isolation violation(s)."
    exit 1
fi
echo "OK: ${fake_count} Fake* source(s), ${flag_count} flag reference(s) and ${control_count} control-plane file(s) are #if DEBUG-gated (release-inert, D30)."
