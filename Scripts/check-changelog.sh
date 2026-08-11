#!/usr/bin/env bash
#
# check-changelog.sh
#
# Release-record guard (#182). Every shippable version needs a hand-curated CHANGELOG.md
# section, because that section is what the in-app "What's New" (#248) and the App Store
# release notes (#95) are authored from. This guard asserts that the current MARKETING_VERSION
# (the single source of truth in project.pbxproj — the same value check-version.sh validates)
# has a matching `## [x.y.z]` section in CHANGELOG.md.
#
# PURE working-tree check (no git history), by design: CI checks out shallow (fetch-depth 1) so
# there is no base ref to diff, and the guard self-test runs this in a non-git temp skeleton. It
# fires meaningfully only when the version was bumped without adding its section — a normal
# (no-bump) PR keeps the current version, whose section already exists, so it passes trivially.
#
# Accepts the bare heading `## [1.2.3]` and the dated form `## [1.2.3] — 2026-08-07`; a prefix
# collision (`## [1.2.30]`) does NOT satisfy version 1.2.3, via the mandatory closing bracket.
#
# Pure-bash heuristic (no toolchain dependency), mirroring the other Scripts/check-*.sh.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PBXPROJ="${REPO_ROOT}/App/PoimiApp.xcodeproj/project.pbxproj"
CHANGELOG="${REPO_ROOT}/CHANGELOG.md"

fail() {
    echo "::error::$1"
    echo "FAIL: $1"
    exit 1
}

[ -f "${PBXPROJ}" ] || fail "Missing ${PBXPROJ}."
[ -f "${CHANGELOG}" ] || fail "Missing CHANGELOG.md at the repo root — every version needs a hand-curated section (#182)."

# The current marketing version — the FIRST MARKETING_VERSION occurrence. check-version.sh already
# gates that every occurrence is an identical semver, so the first is authoritative here.
version="$(grep -oE 'MARKETING_VERSION = [^;]+;' "${PBXPROJ}" \
    | sed -E 's/MARKETING_VERSION = //; s/;$//; s/^[[:space:]]+//; s/[[:space:]]+$//' \
    | head -n1 || true)"

[ -n "${version}" ] || fail "No MARKETING_VERSION found in project.pbxproj."

# Escape the version's dots (regex metacharacters) before interpolating into the pattern.
escaped="${version//./\\.}"

# Match `## [<version>]` at the start of a line, with a MANDATORY closing bracket (so `## [1.2.30]`
# cannot satisfy `1.2.3`), optionally followed by whitespace + a date (`## [1.2.3] — 2026-08-07`).
if grep -Eq "^## \\[${escaped}\\]([[:space:]].*)?$" "${CHANGELOG}"; then
    echo "OK: CHANGELOG.md has a '## [${version}]' section."
    exit 0
fi

fail "CHANGELOG.md has no '## [${version}]' section. On a version bump, move [Unreleased] into a '## [${version}] — <date>' section in the same PR (#182)."
