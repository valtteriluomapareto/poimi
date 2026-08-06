# TestFlight deployment — full setup runbook

Every command and click needed to stand up (and re-establish) the GitHub Actions → TestFlight
pipeline for Poimi. The pipeline itself is `.github/workflows/testflight.yml` + `fastlane/Fastfile`
(issue #135). This doc is the **one-time human setup** those cannot do themselves, plus how to run a
deploy and how to recover.

> **Threat model / where secrets live.** Nothing secret is committed. Signing certs live **encrypted**
> in a private repo (`poimi-match`); the decrypt password + API key + git token live only in the
> GitHub `testflight` **Environment secrets** and in your password manager. This doc uses
> `<PLACEHOLDERS>` for anything account-specific — never paste real key contents into it.

---

## 0. Architecture in one paragraph

A manually-dispatched workflow on a GitHub-hosted macOS runner: it installs fastlane (pinned), pulls
the Apple **Distribution certificate + App Store provisioning profile** (created once by `match` and
stored encrypted in `poimi-match`), imports them into a throwaway keychain, **forces manual signing**,
archives a Release build with the build number = the Actions run number, and uploads to **TestFlight
(internal)** — then polls App Store Connect until the build is `VALID`. Auth to Apple is an **App Store
Connect API key** (no Apple ID / 2FA). A protected `testflight` Environment gates the run behind a
required reviewer.

**Fixed identifiers** (already in `App/PoimiApp.xcodeproj/project.pbxproj` + `fastlane/Appfile`):

| Thing | Value |
| --- | --- |
| Bundle id | `com.valtteriluoma.poimi` |
| Apple Developer Team | `N4FKQHR5AC` |
| Certs repo (private) | `valtteriluomapareto/poimi-match` |
| App repo | `valtteriluomapareto/poimi` |

---

## 1. Prerequisites

- **Paid Apple Developer Program** membership on team `N4FKQHR5AC` (the hard gate — nothing uploads
  without it).
- **A real app icon** — `AppIcon.appiconset` must hold a 1024×1024 opaque PNG (App Store Connect
  rejects any upload with a missing/empty icon). See §6.
- Local tools on a Mac (only for the one-time `match` seed):
  - [`gh`](https://cli.github.com) authenticated: `gh auth status` (needs repo + secret scopes).
  - A modern Ruby (system Ruby 2.6 is too old). Homebrew: `brew install ruby` →
    `/opt/homebrew/opt/ruby/bin`. Verify: `/opt/homebrew/opt/ruby/bin/ruby -v` (≥ 3.3).

---

## 2. Apple web setup (App Store Connect + Developer portal)

### 2.1 Register the App ID
[developer.apple.com → Certificates, Identifiers & Profiles → Identifiers](https://developer.apple.com/account/resources/identifiers/list) → **+**
- **App IDs → App**
- Description `Poimi`; **Explicit** Bundle ID `com.valtteriluoma.poimi`
- Capabilities: none (Photos access is Info.plist usage strings, not an App ID capability) → **Register**

### 2.2 Create the App Store Connect app record
[appstoreconnect.apple.com → Apps](https://appstoreconnect.apple.com/apps) → **+ → New App**
- Platform **iOS**; Name `Poimi` (must be App-Store-unique); primary language your choice
- Bundle ID **com.valtteriluoma.poimi**; SKU `poimi` (any unique string); Access Full → **Create**

### 2.3 Create the App Store Connect API key (auth)
App Store Connect → **Users and Access → Integrations → App Store Connect API → Team Keys → Generate API Key**
- Name `Poimi CI`; Access **App Manager** (sufficient — it can create signing resources during the
  `match` seed; Admin is **not** required)
- **Generate**, then record three things:
  - **Issuer ID** — the UUID above the keys table (same for all your keys)
  - **Key ID** — 10 chars on the key row (the downloaded file is `AuthKey_<KEYID>.p8`)
  - **Download the `.p8`** — ⚠️ **once only**; save it to your password manager

---

## 3. The `match` certs repo (one-time, from a Mac)

`match` stores the signing cert + profile **encrypted** in a private git repo. CI only reads it.

### 3.1 Create the private repo
```sh
gh repo create valtteriluomapareto/poimi-match --private \
  --description "Encrypted fastlane match certs/profiles for Poimi — DO NOT make public"
```

### 3.2 Install fastlane locally (pinned)
```sh
cd ~/personal/poimi
export PATH="/opt/homebrew/opt/ruby/bin:$PATH"     # modern Ruby, not system 2.6
gem install bundler:$(grep -A1 'BUNDLED WITH' Gemfile.lock | tail -1 | tr -d ' ') --no-document
bundle config set --local path vendor/bundle
bundle install
bundle exec fastlane --version                      # confirm it runs
```

### 3.3 Choose + save a MATCH_PASSWORD
This passphrase encrypts the certs repo. **Generate one and save it in your password manager** — you
need it again to re-seed or rotate, and it becomes the `MATCH_PASSWORD` secret.
```sh
openssl rand -hex 20        # copy the output into your password manager as MATCH_PASSWORD
```

### 3.4 Build the API-key JSON (for `match` auth, not committed)
Put it in a scratch dir outside the repo; delete it afterwards.
```sh
KEYID=<KEYID>; ISSUER=<ISSUER_ID>          # from step 2.3
python3 - "$KEYID" "$ISSUER" > /tmp/asc_api_key.json <<'PY'
import json, os, sys
key = open(os.path.expanduser("~/Downloads/AuthKey_%s.p8" % sys.argv[1])).read()
json.dump({"key_id": sys.argv[1], "issuer_id": sys.argv[2], "key": key, "in_house": False}, sys.stdout)
PY
```

### 3.5 Seed match (creates + pushes the cert + profile)
> ⚠️ **`--git_branch main` is not optional.** The Fastfile pins `match(... git_branch: "main")` because
> match defaults to `master`. Seed and lane MUST use the same branch, or CI checks out an empty branch
> and "can't find a valid code signing identity" (see §6).
```sh
export PATH="/opt/homebrew/opt/ruby/bin:$PATH"
export MATCH_PASSWORD='<the passphrase from 3.3>'
bundle exec fastlane match appstore \
  --git_url https://github.com/valtteriluomapareto/poimi-match.git \
  --git_branch main \
  --app_identifier com.valtteriluoma.poimi \
  --team_id N4FKQHR5AC \
  --api_key_path /tmp/asc_api_key.json \
  --readonly false
```
Success looks like: `Successfully decrypted certificates repo` → `Installed Certificate` →
`All required keys, certificates and provisioning profiles are installed 🙌`, and `poimi-match` now
contains `certs/distribution/*.{cer,p12}` and `profiles/appstore/*.mobileprovision`. The profile is
named **`match AppStore com.valtteriluoma.poimi`** (the Fastfile's `PROFILE_NAME`).

Then clean up: `rm /tmp/asc_api_key.json`.

---

## 4. GitHub: protected environment + secrets

### 4.1 Create the protected `testflight` environment (with a required reviewer)
```sh
MY_ID=$(gh api user --jq .id)     # your GitHub user id (must have write access)
printf '{"reviewers":[{"type":"User","id":%s}],"deployment_branch_policy":null}' "$MY_ID" \
  | gh api -X PUT repos/valtteriluomapareto/poimi/environments/testflight --input -
```
This makes every dispatched deploy **pause for your approval** before any secret is exposed.

### 4.2 Set the six Environment secrets
Run from the repo dir (so `gh` infers the repo). The identifier/URL ones can use `--body`; the
**credential** ones are piped from files so they never hit your shell history or a transcript.
```sh
cd ~/personal/poimi

# identifiers / URL (not secret material, but scoped to the environment anyway)
gh secret set ASC_KEY_ID    --env testflight --body '<KEYID>'
gh secret set ASC_ISSUER_ID --env testflight --body '<ISSUER_ID>'
gh secret set MATCH_GIT_URL --env testflight --body 'https://github.com/valtteriluomapareto/poimi-match.git'

# the .p8, base64 with NO trailing newline (fastlane decodes it via is_key_content_base64: true)
base64 -i ~/Downloads/AuthKey_<KEYID>.p8 | tr -d '\n' | gh secret set ASC_KEY_CONTENT_BASE64 --env testflight

# MATCH_PASSWORD — pipe via stdin, NO trailing newline (a stray \n breaks decryption)
printf '%s' '<the passphrase from 3.3>' | gh secret set MATCH_PASSWORD --env testflight
```

### 4.3 The git token for `MATCH_GIT_BASIC_AUTHORIZATION`
CI runs in the `poimi` repo; its built-in `GITHUB_TOKEN` **cannot** read a *different* private repo
(`poimi-match`), so a cross-repo token is required.

1. Create a **fine-grained PAT**:
   [github.com/settings/personal-access-tokens/new](https://github.com/settings/personal-access-tokens/new)
   - Name `poimi-match CI read`; Resource owner `valtteriluomapareto`; Expiration ~1 year
   - Repository access → **Only select repositories → `poimi-match`**
   - Permissions → Repository permissions → **Contents: Read-only**
   - Generate; copy the `github_pat_…`
2. Set the secret (base64 of `username:token`) — run in your own terminal so the PAT isn't logged:
   ```sh
   read -rs "PAT?Paste PAT then Enter: " && \
     printf 'valtteriluomapareto:%s' "$PAT" | base64 | tr -d '\n' \
     | gh secret set MATCH_GIT_BASIC_AUTHORIZATION --env testflight --repo valtteriluomapareto/poimi && \
     unset PAT && echo "✓ set"
   ```
   *(zsh syntax for the silent prompt; bash uses `read -rsp 'Paste PAT: ' PAT`.)*

### 4.4 Verify all six
```sh
gh secret list --env testflight
# expect: ASC_ISSUER_ID, ASC_KEY_CONTENT_BASE64, ASC_KEY_ID,
#         MATCH_GIT_BASIC_AUTHORIZATION, MATCH_GIT_URL, MATCH_PASSWORD
```

---

## 5. Running a deploy

### 5.1 Validate signing first (`build_only`, no upload)
```sh
gh workflow run testflight.yml -f lane=build_only        # runs from the default branch (main)
RID=$(gh run list --workflow=testflight.yml --limit 1 --json databaseId --jq '.[0].databaseId')
```

### 5.2 Approve the reviewer gate
Either click **Review deployments → Approve** in the run's Actions page, or via API:
```sh
ENVID=$(gh api "repos/valtteriluomapareto/poimi/actions/runs/$RID/pending_deployments" --jq '.[0].environment.id')
printf '{"environment_ids":[%s],"state":"approved","comment":"deploy"}' "$ENVID" \
  | gh api -X POST "repos/valtteriluomapareto/poimi/actions/runs/$RID/pending_deployments" --input -
gh run watch "$RID"
```

### 5.3 Ship it (`beta` — build + upload + poll)
```sh
gh workflow run testflight.yml -f lane=beta      # then approve the gate as in 5.2
```
On success the run summary shows `TestFlight identity <MARKETING_VERSION> (<run number>)` and the build
appears under App Store Connect → TestFlight (internal testers). The lane fails the run if ASC marks
the build `INVALID`/`FAILED` or it doesn't reach `VALID` within 30 min.

### 5.4 Bumping the marketing version
The build number is the Actions run number (automatic). The **marketing** version is human-owned:
```sh
Scripts/bump-version.sh patch     # or minor | major | X.Y.Z  → commit in its own PR
```
`Scripts/check-version.sh` (in CI) asserts every `MARKETING_VERSION` occurrence is an identical semver.

### 5.5 Uploading marketing screenshots (`upload_screenshots`)
The `upload_screenshots` lane pushes **only the screenshots** to App Store Connect — never the binary, the
textual metadata, or a review submission. The screenshots are generated on a Mac (iOS 26 sims + your real
photos; see [Scripts/framing/README.md](../../Scripts/framing/README.md)) and the **final framed set is
committed** to the repo (`screenshots/appstore/framed/`), so the upload itself needs no Mac.

Prerequisites:
- Regenerate + **commit** the framed set: `Scripts/appstore-screenshots.sh`, then
  `node Scripts/framing/frame-all.mjs`, then commit `screenshots/appstore/framed/`. The lane aborts if the
  set is missing and pre-checks every image is an accepted size (1320×2868 / 2064×2752) — it never pushes a
  partial or empty set.
- An **editable App Store version** exists in App Store Connect (a version in *Prepare for Submission* —
  screenshots attach to it; create one under App Store Connect → your app → **+ Version** if needed).

**Preferred — via CI:** run `.github/workflows/upload-screenshots.yml` (Actions → **Upload to App Store** →
Run workflow) and approve the `testflight` reviewer gate. It reuses this environment's `ASC_*` secrets (no
match/signing secrets needed) and runs on Linux — deliver only talks to the ASC API, so no Xcode.

**Local alternative:** with the API key exported (`base64 -i` on macOS emits a single line):
```sh
export ASC_KEY_ID=<key-id> ASC_ISSUER_ID=<issuer-id>
export ASC_KEY_CONTENT_BASE64="$(base64 -i <AuthKey_XXXX.p8>)"
bundle exec fastlane upload_screenshots
```
ASC infers each device slot from the image dimensions (1320×2868 → iPhone 6.9″, 2064×2752 → iPad 13″), the
`<locale>` folders (`en-US`, `fi`) map to ASC localizations (missing ones are auto-created), and the `NN_`
prefix sets display order. `overwrite_screenshots` **clears all existing screenshot slots for en-US + fi
before uploading** (other locales untouched) — so always upload a COMPLETE set; anything not present
locally ends up empty in ASC. It does **not** submit for review.

**Duplicates (a deliver quirk, #230).** deliver's presence-check after upload races ASC's processing
(~6 s wait vs ~10–17 s to register a 16-image set), decides the upload failed, and re-uploads the whole
set — so you end up with **2× of every screenshot**. The lane fixes this automatically: after uploading
it deletes same-named duplicates (keeping the lowest-position one per file name per slot, preserving the
`NN_` order). Because the dedup runs in that same ASC-processing window, it then **verifies** — re-checks
each locale's screenshot count against the committed set and retries with a settle wait until they match,
**failing the run loudly** if it can't converge — so a duplicate can never survive silently. If a listing
is *already* duplicated (e.g. from an earlier run), clean it without re-uploading via the
**`dedup_screenshots`** lane (run the workflow with `lane = dedup_screenshots`). It's idempotent and only
ever removes same-named duplicates, so it can't delete a wanted screenshot.

### 5.6 Uploading text metadata (`upload_metadata`)
The App Store **version-localization text** (`description` / `keywords` / `marketing_url` /
`support_url`) lives as `fastlane/metadata/<locale>/*.txt` — the repo is the source of truth (#236). The
`upload_metadata` lane pushes them to the editable version via deliver: **text only** — no binary, no
screenshots, no submission. The managed field list + the sharp edges (**an empty file WIPES the field**;
the in-review lock; drift reverting ASC hand-edits) are documented in
[`fastlane/metadata/README.md`](../../fastlane/metadata/README.md).

**Run it:** Actions → **Upload to App Store** → Run workflow → `lane = upload_metadata` → approve the
gate. Locally: `bundle exec fastlane upload_metadata` (ASC key exported as above). The lane pre-flights
every managed file for non-emptiness + char limits, and reuses the same editable-version prerequisite.

**NOT managed by the lane** (stay in ASC): the **App-Information** group — app **name** (set to
`Poimi: Photo Album Curation`), **subtitle**, and **privacy URL** — because deliver's app-info write
returns `No data` on a brand-new app's first version (revisit after v1 exists). Also `promotional_text`
(the live-edit escape hatch), release notes (per-update), pricing, age rating, the App Privacy label,
categories, and App Review notes.

### 5.7 App Store release checklist (submit for review)
The end-to-end release, tying the lanes together. There is **no CI submit lane** — the final "Submit"
is a deliberate manual step in ASC (deferred by [#239]; the safe-automation design lives there for
if/when updates get frequent). The one safety that matters: set the version to **"Manually release this
version"** so an approval doesn't auto-launch you.

**One-time setup (first release), in ASC — the lanes don't do these:**
- App record + bundle id (§2). Pricing & availability (Poimi = **free**). Age-rating questionnaire.
- **App Privacy** "nutrition label": Poimi collects nothing and photos stay on device (PhotoKit) — declare
  accordingly (this is a required, ASC-only, one-time step; App Review checks it).
- Category: **Photo & Video** (primary); secondary optional (Lifestyle / Productivity).
- **App-Information** text (manual, per §5.6 / #236): **name** `Poimi: Photo Album Curation`, **subtitle**,
  **privacy URL**. Export compliance is already `NO` (guarded, #136) — no per-submit prompt.

**Every release:**
1. **Version** — `Scripts/bump-version.sh <major|minor|patch>` in a PR; merge to `main` (`check-version.sh` gates). `main`'s `MARKETING_VERSION` = the release version.
2. **Build** — run **TestFlight** (`lane = beta`) → approve the gate → a build at `MARKETING_VERSION` (build no. = run no.) lands in TestFlight and is polled to `VALID` (§5.3).
3. **Test** — install from TestFlight (internal) and smoke-test the **exact** build you'll ship.
4. **ASC version** — ensure an editable App Store version exists whose version string **exactly equals** `MARKETING_VERSION` (e.g. `1.0.0`) — create/rename it if needed (a `1.0` vs `1.0.0` mismatch makes the build unselectable). Set it to **"Manually release this version."**
5. **Assets + text** — run **Upload to App Store** → `upload_screenshots` (self-dedups) and `upload_metadata` (§5.5–5.6). Eyeball the listing in both locales.
6. **Attach** the tested build to the version.
7. **App Review Information** — note that the app needs **Photos access** (grant when prompted on launch; no account/login). No demo account needed.
8. **Submit** for review.
9. **After approval** — it parks in **Pending Developer Release**; click **Release** when you're ready.

**Abort ladder (if something's wrong):**
- In review → **Reject / Remove from Review** in ASC.
- Approved, manual release → it's in **Pending Developer Release**; just don't click Release — fix + resubmit.
- Accidentally released → **Remove from Sale** + ship an expedited fix.

**Updates only:** add "What's New" (`release_notes`) — not valid on the first version.

[#239]: https://github.com/valtteriluomapareto/poimi/issues/239

---

## 6. Troubleshooting (things that actually bit us)

- **`Couldn't find a valid code signing identity … creating one for you now` → readonly crash** (often
  with a scary `[match] errSecInternalComponent if not possible to prompt for keychain password` line) —
  this is almost always a **git branch mismatch**, NOT a keychain problem. `match` defaults to branch
  **`master`**, but a GitHub repo's default branch is **`main`**, so match checks out an *empty* branch
  and finds no cert. Fix: the Fastfile's `match(... git_branch: "main")` MUST equal the branch you seeded
  (§3.5 seeds `main`). ⚠️ `errSecInternalComponent` is a **generic hint fastlane appends to any signing
  failure** — do not go down the keychain/OpenSSL rabbit hole; check the `git_branch` in the `match`
  summary first.
- **ASC upload rejected: `Missing required icon file … '120x120'` (validation 409)** — the app has no
  usable app icon. `App/PoimiApp/Resources/Assets.xcassets/AppIcon.appiconset` must contain a real
  **1024×1024 opaque** PNG (single-size is fine — Xcode generates the device sizes). An empty icon slot
  fails every upload.
- **`No such file or directory … project.pbxproj (Errno::ENOENT)` in `marketing_version`** — fastlane
  evaluates the Fastfile with CWD = `fastlane/`, and `build_app`/gym changes the CWD again mid-run, so a
  *relative* path breaks. The Fastfile resolves the pbxproj via a defensive candidate search (anchored to
  `FastlaneCore::FastlaneFolder.path`). Don't use a bare relative path.
- **`422 Invalid request` when approving a deployment via API** — you forgot `--input -`, so `gh api`
  sent an empty body. Pipe the JSON with `--input -`.
- **`match` decryption fails on CI** — `MATCH_PASSWORD` has a trailing newline, or differs from the
  seed passphrase. Re-set it with `printf '%s'` (no newline).
- **`bundler (X) not found`** — the runner/local Ruby's bundler differs from `BUNDLED WITH` in
  `Gemfile.lock`. `gem install bundler:<that version>`.

---

## 7. Rotation & recovery — what lives where

| Secret | Stored in | Rotate by |
| --- | --- | --- |
| ASC API key (`.p8`) | your password manager + `ASC_KEY_CONTENT_BASE64`/`ASC_KEY_ID`/`ASC_ISSUER_ID` | revoke in ASC → new key (2.3) → re-set the three secrets |
| `MATCH_PASSWORD` | your password manager + the `MATCH_PASSWORD` secret | `fastlane match change_password`, then re-set the secret |
| Signing cert/profile | encrypted in `poimi-match` | re-run the seed (3.5); `fastlane match nuke appstore` to revoke+recreate |
| Git PAT | the `MATCH_GIT_BASIC_AUTHORIZATION` secret | new fine-grained PAT (4.3) → re-set the secret |

**If you lose `MATCH_PASSWORD`:** you can't decrypt `poimi-match`. Recreate it — delete the repo
contents (or `fastlane match nuke appstore` to also revoke the Apple cert), choose a new password, and
re-seed (§3.3–3.5), then re-set the `MATCH_PASSWORD` secret. Certificates are limited per team, so
prefer `change_password` over nuke when you still have the old password.
