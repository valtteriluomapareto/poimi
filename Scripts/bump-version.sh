#!/usr/bin/env bash
#
# bump-version.sh
#
# Bump the canonical marketing version (MARKETING_VERSION) in the Xcode project — the
# single source of truth for CFBundleShortVersionString / the About screen (issue #135).
# There is no agvtool path here: VERSIONING_SYSTEM is unset and the Info.plist is
# synthesized (GENERATE_INFOPLIST_FILE = YES), so we edit project.pbxproj directly and
# atomically, keeping ALL occurrences (app + test target, Debug + Release) in sync.
#
# The build number (CURRENT_PROJECT_VERSION / CFBundleVersion) is deliberately NOT
# touched — it is the auto-injected $GITHUB_RUN_NUMBER at archive time.
#
# Usage:
#   Scripts/bump-version.sh patch        # 0.1.0 -> 0.1.1
#   Scripts/bump-version.sh minor        # 0.1.0 -> 0.2.0
#   Scripts/bump-version.sh major        # 0.1.0 -> 1.0.0
#   Scripts/bump-version.sh 1.2.3        # set an explicit semver
#
# It prints old -> new and leaves the change UNCOMMITTED for a human to review / PR
# (the marketing version is a deliberate, human decision — never the release lane).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PBXPROJ="${REPO_ROOT}/App/PoimiApp.xcodeproj/project.pbxproj"

die() { echo "error: $1" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: $(basename "$0") <major|minor|patch|X.Y.Z>"
[ -f "${PBXPROJ}" ] || die "missing ${PBXPROJ}"

arg="$1"

# Current version = the single value all occurrences share. Refuse to guess if they drift.
# `|| true` so a no-match grep (exit 1 under `set -o pipefail`) doesn't abort before the
# explicit emptiness check below can print a friendly message.
current_values="$(grep -oE 'MARKETING_VERSION = [^;]+;' "${PBXPROJ}" \
    | sed -E 's/MARKETING_VERSION = //; s/;$//; s/^[[:space:]]+//; s/[[:space:]]+$//' || true)"
[ -n "${current_values}" ] || die "no MARKETING_VERSION found in ${PBXPROJ}"

unique="$(printf '%s\n' "${current_values}" | sort -u)"
[ "$(printf '%s\n' "${unique}" | grep -c .)" -eq 1 ] \
    || die "MARKETING_VERSION already drifts across configs; fix by hand first:"$'\n'"${current_values}"
current="${unique}"

printf '%s' "${current}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || die "current MARKETING_VERSION '${current}' is not semver MAJOR.MINOR.PATCH"

IFS='.' read -r major minor patch <<EOF
${current}
EOF

case "${arg}" in
    major) new="$((major + 1)).0.0" ;;
    minor) new="${major}.$((minor + 1)).0" ;;
    patch) new="${major}.${minor}.$((patch + 1))" ;;
    *)
        printf '%s' "${arg}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
            || die "'${arg}' is not one of major|minor|patch or an explicit X.Y.Z"
        new="${arg}"
        ;;
esac

[ "${new}" != "${current}" ] || die "new version '${new}' equals the current version; nothing to do"

# Atomic edit: write to a temp file, then move into place only on success.
tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT
sed -E "s/(MARKETING_VERSION = )${current}(;)/\\1${new}\\2/g" "${PBXPROJ}" > "${tmp}"

# Verify every occurrence flipped (count of the new value == original count).
orig_count="$(printf '%s\n' "${current_values}" | grep -c .)"
new_count="$(grep -cE "MARKETING_VERSION = ${new};" "${tmp}")"
[ "${new_count}" -eq "${orig_count}" ] \
    || die "expected to update ${orig_count} occurrence(s) but wrote ${new_count}; aborting (project.pbxproj unchanged)"

mv "${tmp}" "${PBXPROJ}"
trap - EXIT

echo "MARKETING_VERSION: ${current} -> ${new} (${orig_count} occurrences updated)"
echo "Review and commit the change (e.g. on a version-bump branch) — this script does not commit."
