#!/usr/bin/env bash
#
# guard-selftests.sh
#
# Meta-tests for the CI guards (codebase-checkup Layer 0 / Layer 1 harness, issue #213).
#
# A guard is only trustworthy if it actually FAILS on a violation — a guard that
# silently stopped matching (a renamed path, a broken regex) would pass CI forever
# while the invariant rots. This proves each guard both PASSES a clean tree and
# FAILS an injected violation.
#
# Each guard resolves its repo root from its own location (SCRIPT_DIR/..) and scans
# fixed subpaths, so we copy the guard into a throwaway temp skeleton, drop clean /
# violation fixtures beside it, and assert the exit code. The real repo tree is never
# touched (no violation is ever committed — the review's Layer-1 safety note).
#
#     ./Scripts/tests/guard-selftests.sh
#
# Exit 0 iff every guard passes-clean AND fails-on-violation.
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARDS_DIR="${REPO_ROOT}/Scripts"
fails=0
tmpdirs=()
cleanup() { for d in "${tmpdirs[@]:-}"; do [ -n "${d}" ] && rm -rf "${d}"; done; }
trap cleanup EXIT

# skeleton <guard>  →  prints a fresh temp dir with Scripts/<guard> copied in.
skeleton() {
    local guard="$1" dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/checkup-guard.XXXXXX")"
    tmpdirs+=("${dir}")
    mkdir -p "${dir}/Scripts"
    cp "${GUARDS_DIR}/${guard}" "${dir}/Scripts/${guard}"
    printf '%s' "${dir}"
}

# assert <desc> <dir> <guard> <zero|nonzero>  →  run the guard in its skeleton, check exit.
assert() {
    local desc="$1" dir="$2" guard="$3" want="$4" code
    ( "${dir}/Scripts/${guard}" ) >/dev/null 2>&1
    code=$?
    local ok=0
    case "${want}" in
        zero)    [ "${code}" -eq 0 ] && ok=1 ;;
        nonzero) [ "${code}" -ne 0 ] && ok=1 ;;
    esac
    if [ "${ok}" -eq 1 ]; then
        echo "  PASS  ${desc} (exit ${code})"
    else
        echo "  FAIL  ${desc} (exit ${code}, wanted ${want})"
        fails=$((fails + 1))
    fi
}

echo "== check-curation-boundary.sh =="
d="$(skeleton check-curation-boundary.sh)"; mkdir -p "${d}/Curation/Sources"
printf 'import Foundation\npublic let clean = 1\n' > "${d}/Curation/Sources/Clean.swift"
assert "clean domain passes" "${d}" check-curation-boundary.sh zero
printf 'import UIKit\npublic let bad = 1\n' > "${d}/Curation/Sources/BadImport.swift"
assert "forbidden import fails" "${d}" check-curation-boundary.sh nonzero
rm -f "${d}/Curation/Sources/BadImport.swift"
printf 'import Foundation\n@MainActor final class Bad {}\n' > "${d}/Curation/Sources/BadActor.swift"
assert "@MainActor fails" "${d}" check-curation-boundary.sh nonzero

echo "== check-liquid-glass.sh =="
d="$(skeleton check-liquid-glass.sh)"; mkdir -p "${d}/App/PoimiApp"
printf 'import SwiftUI\nstruct V: View { var body: some View { Text("x") } }\n' > "${d}/App/PoimiApp/Clean.swift"
assert "clean UI passes" "${d}" check-liquid-glass.sh zero
printf 'import SwiftUI\nlet bg = Color.clear.background(.thinMaterial)\n' > "${d}/App/PoimiApp/BadMaterial.swift"
assert "material fallback fails" "${d}" check-liquid-glass.sh nonzero
rm -f "${d}/App/PoimiApp/BadMaterial.swift"
printf 'import SwiftUI\nlet gate = { if #available(iOS 27, *) { } }\n' > "${d}/App/PoimiApp/BadGate.swift"
assert "version gate fails" "${d}" check-liquid-glass.sh nonzero

echo "== check-fake-release-isolation.sh =="
d="$(skeleton check-fake-release-isolation.sh)"; mkdir -p "${d}/App/PoimiApp"
printf '#if DEBUG\nstruct FakeThing {}\n#endif\n' > "${d}/App/PoimiApp/FakeThing.swift"
assert "DEBUG-gated fake passes" "${d}" check-fake-release-isolation.sh zero
printf 'struct FakeThing {}\n' > "${d}/App/PoimiApp/FakeThing.swift"
assert "ungated fake fails" "${d}" check-fake-release-isolation.sh nonzero
rm -f "${d}/App/PoimiApp/FakeThing.swift"
printf 'let args = ["-PoimiUseFakeLibrary"]\n' > "${d}/App/PoimiApp/Launch.swift"
assert "ungated -Poimi flag fails" "${d}" check-fake-release-isolation.sh nonzero

echo "== check-no-grouping-in-views.sh =="
d="$(skeleton check-no-grouping-in-views.sh)"; mkdir -p "${d}/App/PoimiApp"
printf 'import SwiftUI\nstruct FooView: View { var body: some View { Text("x") } }\n' > "${d}/App/PoimiApp/FooView.swift"
assert "view without grouping passes" "${d}" check-no-grouping-in-views.sh zero
printf 'import SwiftUI\nstruct BarView: View { let g = DayGrouping.groups(for: []) }\n' > "${d}/App/PoimiApp/BarView.swift"
assert "grouping in a view fails" "${d}" check-no-grouping-in-views.sh nonzero

echo
if [ "${fails}" -eq 0 ]; then
    echo "OK: all guard self-tests passed (each guard passes clean + fails on a violation)."
    exit 0
fi
echo "FAIL: ${fails} guard self-test assertion(s) failed."
exit 1
