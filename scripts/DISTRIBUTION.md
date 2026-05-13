# Distributing Sims

To ship Sims to teammates so it opens on their Mac without
Gatekeeper warnings, the app must be:

1. signed with a **Developer ID Application** certificate
2. built with **hardened runtime** enabled
3. submitted to Apple's **notary service** and stapled

This repo is configured for that flow. Two one-time setup steps below
cover the things only you can do (your developer team, your notary
credentials). After that, `scripts/release.sh` does the rest.

> Important: recipients still need **Xcode installed** on their Mac.
> Sims is a shell around CoreSimulator/SimulatorKit — those
> frameworks ship with Xcode. No Xcode = no simulator runtimes to
> stream. The Command Line Tools alone are not enough.

---

## One-time setup

### 1. Configure `Sims/Local.xcconfig`

The team ID and bundle ID live in a gitignored file so the repo stays
free of per-developer identifiers. Copy the example and fill it in:

```sh
cp Sims/Local.xcconfig.example Sims/Local.xcconfig
```

Edit `Sims/Local.xcconfig` and set:

```
PRODUCT_BUNDLE_IDENTIFIER = com.yourname.sims
DEVELOPMENT_TEAM = ABC1234567
```

Find your Team ID in Xcode → Settings → Accounts → select your team,
or:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

Without `Local.xcconfig` the project still builds Debug (ad-hoc signed)
using a fallback bundle ID. Release / notarization needs it.

### 2. Create a "Developer ID Application" certificate

Easiest path is through Xcode:

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

Notary service auth uses an app-specific password tied to your Apple
ID, not your account password.

1. Go to <https://account.apple.com> → sign in
2. **Sign-In and Security** → **App-Specific Passwords**
3. **Generate an app-specific password**, label it e.g. `Sims Notary`
4. Copy the password (format `xxxx-xxxx-xxxx-xxxx`) — you can't see it
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

If you want to use a different profile name, copy `.env.example`
to `.env` (also gitignored) and override `NOTARY_PROFILE`.

---

## Cutting a release

```sh
./scripts/release.sh
```

The script will:

1. Read `DEVELOPMENT_TEAM` from `Sims/Local.xcconfig` and render
   `scripts/ExportOptions.plist` from the tracked template
2. `xcodebuild archive` (Release config, universal binary)
3. `xcodebuild -exportArchive` with the rendered ExportOptions
   → produces a Developer ID-signed `Sims.app`
4. Zip it up for upload
5. `xcrun notarytool submit … --wait` — Apple's notary service
   inspects the binary and either approves it or returns a log of
   problems. Takes 1–10 minutes for a small app like this.
6. `xcrun stapler staple` — embeds the notarization ticket so the
   first-launch check works **offline**
7. `spctl --assess` — final Gatekeeper sanity check

Outputs:

- `dist/Sims.app` — the bundle
- `dist/Sims.zip` — same, zipped for AirDrop / email / cloud upload

Either works for distribution. Recipients double-click to launch, no
right-click-Open dance, no quarantine flag to strip.

---

## Bumping the version

Before each release, bump `MARKETING_VERSION` (and optionally
`CURRENT_PROJECT_VERSION`) in `Sims.xcodeproj/project.pbxproj`.
Notary doesn't enforce uniqueness, but you'll thank yourself later
when bug reports cite a version number.

---

## Troubleshooting

### "errSecInternalComponent" during signing

The signing identity in your keychain is locked or the keychain is
locked. Unlock:

```sh
security unlock-keychain login.keychain
```

### Notary status "Invalid"

```sh
xcrun notarytool log <submission-id> --keychain-profile SimsNotary
```

The log JSON tells you which file/issue tripped the check — usually
either a missing entitlement (we need
`com.apple.security.cs.disable-library-validation` because we
`dlopen` CoreSimulator and SimulatorKit) or a binary that wasn't
signed with hardened runtime.

### "code object is not signed at all" on a nested helper

Re-run the archive — the export step re-signs everything from scratch.
If it persists, run `codesign --display --verbose=4` on the unsigned
binary to see what's missing.
