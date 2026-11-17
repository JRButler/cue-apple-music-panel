#!/usr/bin/env bash
#
# sign-and-notarise.sh — prepare Cue.app for another Mac.
#
# Adapted from ScreenRecorderPlus's script of the same name. Its checks are
# kept rather than rewritten: each one exists because something went wrong
# once, and none of them are obvious from the outside.
#
# Run manually after a release build, not on every build: notarisation is a
# network round trip to Apple that takes minutes.
#
#   ./tools/sign-and-notarise.sh
#   ./tools/sign-and-notarise.sh --dry-run    # everything except submitting
#
# Prerequisites, both one-off and PER-MACHINE rather than per-project:
#   1. A "Developer ID Application" certificate in the login keychain.
#   2. A stored notarytool credential profile, created once with
#      `xcrun notarytool store-credentials`. It holds an Apple ID credential
#      rather than anything project-specific, so a profile stored for another
#      app notarises this one perfectly well.
#
#      The profile name therefore differs per machine and does not belong in a
#      public repo. Name yours in tools/local.env (gitignored; see
#      tools/local.env.example), or pass it per run:
#
#   CUE_NOTARY_PROFILE=SomeOtherName ./tools/sign-and-notarise.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="Cue"
ARCHIVE="build/${SCHEME}.xcarchive"
DIST_DIR="build/dist"
APP_PATH="${DIST_DIR}/${SCHEME}.app"
ZIP_PATH="build/${SCHEME}.zip"
# Per-machine settings, kept out of the repo. The only one so far is which
# stored notarytool profile to use.
# shellcheck source=/dev/null
[ -f tools/local.env ] && . tools/local.env

NOTARY_PROFILE="${CUE_NOTARY_PROFILE:-Cue}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

say()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31mERROR: %s\033[0m\n\n' "$1" >&2; exit 1; }

mkdir -p build

# ---------------------------------------------------------------------------
say "Archiving"

# Archive rather than a plain build: the archive action applies the
# install-time settings, and it is what the export step consumes.
rm -rf "$ARCHIVE"
xcodebuild -project Cue.xcodeproj -scheme "$SCHEME" -configuration Release \
    -archivePath "$ARCHIVE" archive \
    > build/archive.log 2>&1 || fail "Archive failed. See build/archive.log"

# ---------------------------------------------------------------------------
say "Exporting with Developer ID"

rm -rf "$DIST_DIR"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist tools/ExportOptions.plist \
    -exportPath "$DIST_DIR" \
    > build/export.log 2>&1 || fail "Export failed. See build/export.log"

# ---------------------------------------------------------------------------
say "Checking the bundle is structurally an app"

# Apple's notary service checks for malware, NOT for whether the bundle is
# well-formed. It will happily notarise something Gatekeeper then rejects on
# the recipient's machine — after the round trip, and after you have sent it.
PLIST="$APP_PATH/Contents/Info.plist"
[ -f "$PLIST" ] || fail "No Info.plist in $APP_PATH"

BUNDLE_TYPE=$(/usr/libexec/PlistBuddy -c "Print :CFBundlePackageType" "$PLIST" 2>/dev/null || true)
[ "$BUNDLE_TYPE" = "APPL" ] || fail "CFBundlePackageType is '$BUNDLE_TYPE', expected APPL."

BUNDLE_EXECUTABLE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PLIST" 2>/dev/null || true)
[ -x "$APP_PATH/Contents/MacOS/$BUNDLE_EXECUTABLE" ] \
    || fail "CFBundleExecutable is '$BUNDLE_EXECUTABLE' but there is no executable of that name."

# Cue is an agent: no Dock icon, menu bar only. If LSUIElement is ever lost the
# app still runs, so nothing fails — it just starts appearing in the Dock and
# the Cmd-Tab switcher, which is not what this app is.
LSUI=$(/usr/libexec/PlistBuddy -c "Print :LSUIElement" "$PLIST" 2>/dev/null || true)
[ "$LSUI" = "true" ] || fail "LSUIElement is '$LSUI', expected true. Cue is a menu bar agent."

# Without this, the first Apple Event prompts with a blank reason, which looks
# like a bug rather than a request.
APPLE_EVENTS_USAGE=$(/usr/libexec/PlistBuddy -c "Print :NSAppleEventsUsageDescription" "$PLIST" 2>/dev/null || true)
[ -n "$APPLE_EVENTS_USAGE" ] || fail "NSAppleEventsUsageDescription is missing; the Automation prompt needs it."

# Output is captured to variables before being searched, deliberately. Piping
# into `grep -q` under `set -o pipefail` reports the PIPELINE as failed whenever
# grep matches: grep exits early, codesign takes SIGPIPE, and pipefail surfaces
# that. It fails a perfectly signed bundle — and on the get-task-allow check it
# fails in the dangerous direction, silently skipping the thing it exists for.
SIGN_INFO=$(codesign -dvvv "$APP_PATH" 2>&1)
ENTITLEMENTS=$(codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null || true)

# get-task-allow is what a debug build carries so a debugger can attach. Apple
# rejects it outright, and xcodebuild injects it unless told not to — which is
# why Release sets CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO.
case "$ENTITLEMENTS" in
    *get-task-allow*) fail "The bundle carries com.apple.security.get-task-allow, which fails notarisation." ;;
esac

# Apple Events is the entitlement the whole app depends on. Losing it does not
# fail the build; it fails every Apple Event at runtime, on the user's machine.
case "$ENTITLEMENTS" in
    *apple-events*) ;;
    *) fail "The bundle has no com.apple.security.automation.apple-events entitlement, so it cannot drive Music." ;;
esac

# Hardened runtime is required, and signing without a secure timestamp fails
# notarisation with a message that does not obviously say so.
case "$SIGN_INFO" in
    *"flags="*runtime*) ;;
    *) fail "Hardened runtime is not enabled on the signed bundle." ;;
esac
case "$SIGN_INFO" in
    *Timestamp=*) ;;
    *) fail "The signature has no secure timestamp." ;;
esac

codesign --verify --strict --verbose=2 "$APP_PATH"
echo "  $BUNDLE_EXECUTABLE, $BUNDLE_TYPE, agent, hardened runtime, timestamped,"
echo "  apple-events entitled, no get-task-allow"

# ---------------------------------------------------------------------------
say "Version"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
echo "  $VERSION ($BUILD)"

# Refuse to ship a version already tagged, so two different builds cannot wear
# the same version.
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    fail "v$VERSION is already tagged, so this would be a second, different build
  wearing a version someone already has. Bump MARKETING_VERSION and
  CURRENT_PROJECT_VERSION in the project before shipping."
fi

if [ "$DRY_RUN" = "1" ]; then
    say "Dry run — stopping before submission"
    echo "  Signed and verified: $APP_PATH"
    echo "  Re-run without --dry-run to notarise."
    exit 0
fi

# ---------------------------------------------------------------------------
say "Submitting for notarisation (this takes a few minutes)"

# ditto, not zip: it preserves the bundle structure and extended attributes a
# plain zip mangles, which shows up later as a bundle that will not validate.
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

if ! xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait; then
    fail "Notarisation failed. For the reason:
  xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE

  'A required agreement is missing or has expired' means the Apple Developer
  Program agreements need accepting at developer.apple.com — nothing in this
  project can fix that.

  'No Keychain password item found' means the profile name is wrong. It is per
  Apple ID rather than per project, so one stored for another app works here:
      CUE_NOTARY_PROFILE=<existing-name> $0"
fi

# ---------------------------------------------------------------------------
say "Stapling"

# Embeds the ticket INTO the bundle so Gatekeeper can validate without a
# network round trip. Without it the app still passes, but only on a machine
# that is online the first time it opens it.
xcrun stapler staple "$APP_PATH"

# Re-zip AFTER stapling — the submission zip does not contain the ticket, and
# shipping that one is the most common way to end up wondering why a notarised
# app still warns.
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

# ---------------------------------------------------------------------------
say "Verifying as Gatekeeper will see it"

spctl -a -vvv -t install "$APP_PATH"
xcrun stapler validate "$APP_PATH"

say "Done"
echo "  Signed, notarised and stapled: $APP_PATH"
echo "  Ready to send:                 $ZIP_PATH"
