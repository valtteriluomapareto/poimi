#!/usr/bin/env bash
#
# check-fake-release-isolation.sh
#
# Enforces D30: the test-double photo library (`FakePhotoLibrary` and any sibling
# `Fake*` doubles) must be compiled ONLY under Debug and be inert in Release — it
# must never ship. The language-level, build-config-agnostic way to guarantee that
# is to wrap each such source in `#if DEBUG … #endif`. This guard asserts exactly
# that for every app source whose name marks it a fake double.
#
# No fakes exist yet (they arrive with issue #21); the check passes trivially now and
# becomes load-bearing the moment a `Fake*.swift` lands. The composition-root swap
# flag's release-inertness (issue #23) is verified the same way once it exists.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="${REPO_ROOT}/App"

if [ ! -d "${APP_DIR}" ]; then
    echo "OK: no app sources yet."
    exit 0
fi

# Files whose name marks them a test double (case-insensitive 'fake'). Built with a
# read loop, not `mapfile` (absent in macOS's stock bash 3.2).
fake_files=()
while IFS= read -r f; do
    [ -n "${f}" ] && fake_files+=("${f}")
done < <(find "${APP_DIR}" -name '*.swift' | grep -iE '/[^/]*fake[^/]*\.swift$' || true)

if [ "${#fake_files[@]}" -eq 0 ]; then
    echo "OK: no Fake* sources present yet (guard is inert until issue #21)."
    exit 0
fi

violations=0
for file in "${fake_files[@]}"; do
    if ! grep -Eq '^[[:space:]]*#if[[:space:]]+DEBUG' "${file}"; then
        echo "::error file=${file}::Fake double must be wrapped in '#if DEBUG' so it cannot ship in Release (D30)."
        violations=$((violations + 1))
    fi
done

if [ "${violations}" -gt 0 ]; then
    echo "FAIL: ${violations} fake double(s) not Debug-gated."
    exit 1
fi
echo "OK: all ${#fake_files[@]} Fake* source(s) are #if DEBUG-gated (release-inert, D30)."
