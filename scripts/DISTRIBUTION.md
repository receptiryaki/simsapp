# Distributing Sims

Sims releases are signed with a **Developer ID Application**
certificate, built with **hardened runtime**, and submitted to
Apple's **notary service** so they open on any Mac without
Gatekeeper warnings.

There are two paths to actually produce a release:

- **GitHub Actions (default).** Tag-driven, hands-free. The
  workflow at `.github/workflows/release.yml` signs, notarises,
  staples, and publishes a GitHub Release.
- **Local script (fallback).** `./scripts/release.sh` runs the
  same pipeline from your Mac. Useful for debugging the build, or
  when CI is unavailable.

This file covers the one-time setup for both paths, then how to
cut a release.

> Important: recipients still need **Xcode installed** on their
> Mac. Sims is a shell around CoreSimulator/SimulatorKit — those
> frameworks ship with Xcode. No Xcode = no simulator runtimes to
> stream. The Command Line Tools alone are not enough.

---

## Path A: CI release setup (one-time)

After this is set up, cutting a release is just "push a tag" — see
[Cutting a release](#cutting-a-release) below.

You'll need:

- Your Apple Developer membership (the same $99/yr account you use
  for Xcode signing)
- `gh` (GitHub CLI) authenticated against this repo
- ~15 minutes

### 1. Export your Developer ID Application cert

Open **Keychain Access** → **login** keychain → **My Certificates**
tab. Find `Developer ID Application: <your name> (<TEAM_ID>)` and
click the `▶` next to it; a private key should appear underneath.
If there's no private key, the cert was imported without it and
the export below won't work — go back to the issuing machine.

Right-click the certificate row → **Export "Developer ID
Application: …"** → save as `.p12` to `~/Desktop/sims-developer-id.p12`.
Set an export password (any string; you'll paste it as a secret in
step 3). Enter your Mac login password when prompted.

### 2. Generate an App Store Connect API key

The notary service authenticates via an App Store Connect API key.
"App Store Connect" is Apple's name for the whole developer
dashboard — we're only using the notarisation corner of it.

1. Sign in at <https://appstoreconnect.apple.com>
2. Top menu → **Users and Access** → **Integrations** tab
3. Left sidebar: **Team Keys** (also called "App Store Connect API")
4. Click **+** → name it `Sims CI`, role **Developer** (lowest
   privilege that works for notarytool) → **Generate**
5. **Download the `.p8` file immediately** — Apple only lets you
   download it once. Save somewhere safe; you'll need it again if
   you ever re-set up CI.
6. From the same page, note down:
   - **Key ID** (10 chars, shown next to your key in the list)
   - **Issuer ID** (UUID shown at the top of the page)

### 3. Upload secrets to the repo

From the repo directory, run these one at a time. Replace `…`
placeholders with your actual values.

```sh
# 1. Developer ID cert (base64-encoded .p12)
base64 -i ~/Desktop/sims-developer-id.p12 | gh secret set DEVELOPER_ID_CERT_P12

# 2. The export password from step 1
gh secret set DEVELOPER_ID_CERT_PASSWORD --body '…'

# 3. App Store Connect API key (.p8 file from step 2)
base64 -i ~/Downloads/AuthKey_XXXXXXXXXX.p8 | gh secret set APP_STORE_CONNECT_API_KEY_P8

# 4. Key ID
gh secret set APP_STORE_CONNECT_API_KEY_ID --body '…'

# 5. Issuer ID
gh secret set APP_STORE_CONNECT_API_ISSUER_ID --body '…'

# 6. Apple Developer Team ID
gh secret set DEVELOPMENT_TEAM --body '…'
```

Verify with `gh secret list` — you should see all six names. Values
are encrypted at upload; GitHub never shows them again, and they're
only exposed to workflow runs.

### 4. Clean up

```sh
rm ~/Desktop/sims-developer-id.p12
# Keep the AuthKey_XXX.p8 in a safe place — Apple won't let you
# redownload it. If you lose it, you'll need to revoke that key
# in App Store Connect and generate a new one.
```

---

## Path B: Local release setup (one-time)

Only needed if you'll run `./scripts/release.sh` locally. If you're
using CI exclusively, skip to [Cutting a release](#cutting-a-release).

### 1. Configure `Sims/Local.xcconfig`

The team ID and bundle ID live in a gitignored file so the repo
stays free of per-developer identifiers. Copy the example and fill
it in:

```sh
cp Sims/Local.xcconfig.example Sims/Local.xcconfig
```

Edit `Sims/Local.xcconfig` and set:

```
PRODUCT_BUNDLE_IDENTIFIER = com.yourname.sims
DEVELOPMENT_TEAM = ABC1234567
```

Find your Team ID in Xcode → Settings → Accounts → select your
team, or:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

Without `Local.xcconfig` the project still builds Debug (ad-hoc
signed) using a fallback bundle ID. Release / notarisation needs it.

### 2. Create a "Developer ID Application" certificate

If you already did step A.1, the same cert in your login keychain
works here — no extra action. Otherwise:

1. Xcode → Settings → **Accounts**
2. Select your Apple ID and choose your team
3. Click **Manage Certificates…**
4. Click **+** in the bottom-left → **Developer ID Application**
5. Done. The cert lands in your login keychain automatically.

Verify:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

You should see one row with your name and team ID.

### 3. Generate an app-specific password

The local script uses an Apple-ID + app-specific-password pair (the
older notarytool auth method) instead of the App Store Connect API
key. Both work — the script just defaults to the simpler local flow.

1. Go to <https://account.apple.com> → sign in
2. **Sign-In and Security** → **App-Specific Passwords**
3. **Generate an app-specific password**, label it e.g. `Sims Notary`
4. Copy the password (`xxxx-xxxx-xxxx-xxxx`) — you can't see it
   again after closing the dialog

### 4. Store the credentials in your keychain

```sh
xcrun notarytool store-credentials SimsNotary \
  --apple-id "<your-apple-id>" \
  --team-id "<your-team-id>" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

This saves the credentials under the profile name `SimsNotary`
which `scripts/release.sh` looks for. The password is stored
encrypted in your login keychain; the script never sees it.

If you want a different profile name, copy `.env.example` to `.env`
(also gitignored) and override `NOTARY_PROFILE`.

---

## Cutting a release

### Standard flow (CI)

1. Branch off `main`:

   ```sh
   git checkout -b release/v0.2.0
   ```

2. Bump `MARKETING_VERSION` in `Sims/Sims.xcconfig` to the new
   version, e.g. `MARKETING_VERSION = 0.2.0`.

3. In `CHANGELOG.md`:
   - rename `## [Unreleased]` to `## [0.2.0] - YYYY-MM-DD`
   - add a fresh empty `## [Unreleased]` above it
   - add link references at the bottom for both

4. Commit, push, open + squash-merge the PR.

5. Tag from `main` and push:

   ```sh
   git checkout main && git pull
   git tag v0.2.0
   git push origin v0.2.0
   ```

The `Release` workflow takes over and:

- verifies the tag matches `MARKETING_VERSION`,
- imports the Developer ID cert from secrets into a temp keychain,
- archives (Release, universal binary), exports with Developer ID
  signing,
- submits to notarytool with the App Store Connect API key, waits
  for approval (1–10 min usually, capped at 30 min),
- staples the ticket and runs `spctl --assess` as a final check,
- creates a GitHub Release titled `Sims v0.2.0` with the `[0.2.0]`
  block from CHANGELOG.md as the body, and `Sims.zip` attached.

Watch it with `gh run watch` or open the Actions tab. Total run
time is typically 8–15 minutes (notarytool dominates).

### Fallback (local script)

```sh
./scripts/release.sh
```

The script:

1. Reads `DEVELOPMENT_TEAM` from `Sims/Local.xcconfig` and renders
   `scripts/ExportOptions.plist` from the tracked template.
2. `xcodebuild archive` (Release config, universal binary).
3. `xcodebuild -exportArchive` with the rendered ExportOptions
   → Developer ID-signed `Sims.app`.
4. Zips it for upload.
5. `xcrun notarytool submit … --wait` — Apple's notary service
   inspects the binary and either approves it or returns a log of
   problems. 1–10 min for an app this size.
6. `xcrun stapler staple` — embeds the notarisation ticket so the
   first-launch check works **offline**.
7. `spctl --assess` — final Gatekeeper sanity check.

Outputs:

- `dist/Sims.app` — the bundle
- `dist/Sims.zip` — same, zipped for AirDrop / email / cloud upload

To publish this manually as a GitHub Release:

```sh
gh release create v0.2.0 dist/Sims.zip --notes "$(awk '/^## \[0.2.0\]/,/^## \[/' CHANGELOG.md | sed '$d')"
```

---

## Bumping the version

The version is one value in `Sims/Sims.xcconfig`:

```
MARKETING_VERSION = 0.1.0
```

`CURRENT_PROJECT_VERSION` follows it via `$(MARKETING_VERSION)`, and
`Info.plist` references both via `$(...)` expansion. One xcconfig
edit propagates to:

- the artifact's `CFBundleShortVersionString` and `CFBundleVersion`,
- the CI tag-verification check (so you can't ship a tag that
  disagrees with the source of truth),
- the GitHub Release title (via the tag).

The version is **not** in `Sims.xcodeproj/project.pbxproj` — the
target-level pbxproj settings used to pin it, but they were
removed so xcconfig wins unambiguously.

---

## Troubleshooting

### CI fails at "Verify tag matches Sims.xcconfig"

The pushed tag (e.g. `v0.2.0`) doesn't match `MARKETING_VERSION` in
the checked-out commit. Two paths:

- Bump the xcconfig and re-tag:

  ```sh
  # delete the bad tag
  git tag -d v0.2.0
  git push origin :refs/tags/v0.2.0
  # fix xcconfig, commit (via a PR if main is protected), then re-tag
  ```

- Or re-tag to match the xcconfig value (rare — only if you tagged
  the wrong version).

### `errSecInternalComponent` during signing (local)

The signing identity in your keychain is locked, or the keychain
itself is locked:

```sh
security unlock-keychain login.keychain
```

### Notary status `Invalid`

```sh
# Local
xcrun notarytool log <submission-id> --keychain-profile SimsNotary

# CI — the workflow logs include the submission ID
xcrun notarytool log <id> \
  --key AuthKey_XXX.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
```

The log JSON tells you which file/issue tripped the check — usually
either a missing entitlement (we need
`com.apple.security.cs.disable-library-validation` because we
`dlopen` CoreSimulator and SimulatorKit) or a binary that wasn't
signed with hardened runtime.

### "code object is not signed at all" on a nested helper

Re-run the archive — the export step re-signs everything from
scratch. If it persists, run `codesign --display --verbose=4` on
the unsigned binary to see what's missing.

### CI says my secrets are wrong

`gh secret list` only shows names + last-updated timestamps, never
values. To verify a secret's contents, re-set it. The Developer ID
cert in particular is fiddly because of the base64 step:

```sh
# Re-export from Keychain Access as in step A.1
base64 -i ~/Desktop/sims-developer-id.p12 | gh secret set DEVELOPER_ID_CERT_P12
# Re-set the password — must match the new export
gh secret set DEVELOPER_ID_CERT_PASSWORD --body '…'
```

### Want to re-run a release for the same tag

The workflow has a `workflow_dispatch` trigger. From the Actions
tab → `Release` workflow → **Run workflow** → enter the existing
tag (e.g. `v0.2.0`) → **Run**. Delete the existing GitHub Release
first (`gh release delete v0.2.0`) if it was already partly created.
