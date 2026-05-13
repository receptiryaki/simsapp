#!/usr/bin/env bash
# Build, sign, notarize, and staple a distributable Sims.app.
#
# Prerequisites (one-time, see scripts/DISTRIBUTION.md):
#   1. Sims/Local.xcconfig with your DEVELOPMENT_TEAM
#      (copy Sims/Local.xcconfig.example, fill in)
#   2. "Developer ID Application" cert in your login keychain
#   3. notarytool keychain profile (default name "SimsNotary") — created
#      via `xcrun notarytool store-credentials SimsNotary` with your
#      Apple ID, app-specific password, and team ID
#
# Optionally source ./.env to override NOTARY_PROFILE.
#
# Output:
#   dist/Sims.app             — notarized, stapled, ready to ship
#   dist/Sims.zip             — zipped for upload/transfer
#
# Re-runnable. Wipes dist/ and build/ each run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Load optional .env (gitignored) for NOTARY_PROFILE etc.
if [[ -f "$ROOT/.env" ]]; then
	set -a
	# shellcheck source=/dev/null
	source "$ROOT/.env"
	set +a
fi

SCHEME="Sims"
PROJECT="Sims.xcodeproj"
CONFIG="Release"
NOTARY_PROFILE="${NOTARY_PROFILE:-SimsNotary}"

BUILD_DIR="$ROOT/build"
DIST_DIR="$ROOT/dist"
ARCHIVE_PATH="$BUILD_DIR/Sims.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
EXPORT_OPTIONS_TEMPLATE="$ROOT/scripts/ExportOptions.plist.template"
EXPORT_OPTIONS="$ROOT/scripts/ExportOptions.plist"
LOCAL_XCCONFIG="$ROOT/Sims/Local.xcconfig"

# Resolve DEVELOPMENT_TEAM from Local.xcconfig — single source of truth
# shared with Xcode (no duplication, no risk of drift).
if [[ ! -f "$LOCAL_XCCONFIG" ]]; then
	echo "Missing $LOCAL_XCCONFIG."
	echo "  cp Sims/Local.xcconfig.example Sims/Local.xcconfig"
	echo "  # then fill in DEVELOPMENT_TEAM and PRODUCT_BUNDLE_IDENTIFIER"
	exit 1
fi
TEAM_ID="$(awk -F= '/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=/ { gsub(/[[:space:]]/, "", $2); print $2 }' "$LOCAL_XCCONFIG" | tail -1)"
if [[ -z "$TEAM_ID" ]]; then
	echo "DEVELOPMENT_TEAM not set in $LOCAL_XCCONFIG."
	exit 1
fi

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

say() { printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }

# Render ExportOptions.plist from template using TEAM_ID. The rendered
# plist is gitignored so the team ID never enters the repo.
say "Rendering ExportOptions.plist (team $TEAM_ID)"
sed "s/__TEAM_ID__/$TEAM_ID/" "$EXPORT_OPTIONS_TEMPLATE" > "$EXPORT_OPTIONS"

say "Archiving (Release, universal)"
if command -v xcbeautify >/dev/null 2>&1; then
	set -o pipefail
	xcodebuild \
		-project "$PROJECT" \
		-scheme "$SCHEME" \
		-configuration "$CONFIG" \
		-destination "generic/platform=macOS" \
		-archivePath "$ARCHIVE_PATH" \
		archive \
		| xcbeautify
else
	xcodebuild \
		-project "$PROJECT" \
		-scheme "$SCHEME" \
		-configuration "$CONFIG" \
		-destination "generic/platform=macOS" \
		-archivePath "$ARCHIVE_PATH" \
		archive
fi

say "Exporting (Developer ID)"
xcodebuild \
	-exportArchive \
	-archivePath "$ARCHIVE_PATH" \
	-exportOptionsPlist "$EXPORT_OPTIONS" \
	-exportPath "$EXPORT_PATH"

APP_PATH="$EXPORT_PATH/Sims.app"
test -d "$APP_PATH" || { echo "Export produced no Sims.app"; exit 1; }

say "Verifying signature locally"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --display --verbose=4 "$APP_PATH" 2>&1 | grep -E "Authority|TeamIdentifier|Timestamp|Runtime" || true

ZIP_FOR_NOTARY="$BUILD_DIR/Sims-for-notary.zip"
say "Zipping for notarytool ($ZIP_FOR_NOTARY)"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_FOR_NOTARY"

say "Submitting to notarytool (this can take 1–10 min)"
xcrun notarytool submit "$ZIP_FOR_NOTARY" \
	--keychain-profile "$NOTARY_PROFILE" \
	--wait

say "Stapling ticket onto the .app"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

say "Final Gatekeeper assessment"
spctl --assess --type execute --verbose=2 "$APP_PATH" 2>&1 || {
	echo "spctl rejected the app — notarization may not have completed cleanly"
	exit 1
}

say "Copying to dist/"
cp -R "$APP_PATH" "$DIST_DIR/Sims.app"
ditto -c -k --keepParent "$DIST_DIR/Sims.app" "$DIST_DIR/Sims.zip"

du -sh "$DIST_DIR/Sims.app" "$DIST_DIR/Sims.zip"

echo
echo "Done. Ship: $DIST_DIR/Sims.zip"
