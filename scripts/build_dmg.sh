#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist" 2>/dev/null || echo "0.2.0")"
APP_NAME="QuikCal"
# 0.3.9: installer named after the product (QuikCal-<version>.dmg), not the
# legacy "Quiet Calendar" name.
DMG_NAME="QuikCal-${VERSION}.dmg"
DIST="$ROOT/dist"
STAGE="$DIST/dmg-stage"
DMG_PATH="$DIST/$DMG_NAME"

echo "==> Building app bundle"
"$ROOT/scripts/build_app.sh"

APP_SRC="$ROOT/build/${APP_NAME}.app"
if [[ ! -d "$APP_SRC" ]]; then
  echo "Missing app at $APP_SRC" >&2
  exit 1
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_SRC/Contents/Info.plist")"
if [[ "$BUNDLE_ID" != "com.quietcalendar.app" ]]; then
  echo "Refusing to package unexpected bundle id: $BUNDLE_ID" >&2
  exit 1
fi

# Distributable DMGs must be IDENTITY-signed (stable Team-ID designated
# requirement). Ad-hoc builds churn the code identity per build and orphan
# TCC grants — refuse unless explicitly overridden for local development.
BUILT_TEAM="$(codesign -dvv "$APP_SRC" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
if [[ -z "$BUILT_TEAM" && "${QUIKCAL_ALLOW_ADHOC_DMG:-0}" != "1" ]]; then
  echo "Refusing to package ad-hoc signed app into a distributable DMG." >&2
  echo "(explicit local-dev override: QUIKCAL_ALLOW_ADHOC_DMG=1 — never for owner-facing artifacts)" >&2
  exit 1
fi
echo "==> Built app TeamIdentifier: ${BUILT_TEAM:-<ad-hoc override>}"

echo "==> Staging DMG contents"
rm -rf "$STAGE"
mkdir -p "$STAGE" "$DIST"
ditto "$APP_SRC" "$STAGE/${APP_NAME}.app"
ln -s /Applications "$STAGE/Applications"

# Remove prior versioned DMG with same name
rm -f "$DMG_PATH"

echo "==> Creating DMG with hdiutil"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "==> Verifying DMG (read-only attach)"
# Unique mount point so we never confuse this attach with another Quiet Calendar volume.
OWN_MOUNT="$DIST/dmg-verify-mount-$$"
mkdir -p "$OWN_MOUNT"
hdiutil attach "$DMG_PATH" -readonly -nobrowse -mountpoint "$OWN_MOUNT" >/tmp/quietcalendar-dmg-attach.txt
cat /tmp/quietcalendar-dmg-attach.txt
MOUNT_POINT="$OWN_MOUNT"
if [[ -z "$MOUNT_POINT" || ! -d "$MOUNT_POINT/${APP_NAME}.app" ]]; then
  echo "Could not determine mount point / app missing" >&2
  if [[ -d "$OWN_MOUNT" ]]; then hdiutil detach "$OWN_MOUNT" || true; fi
  exit 1
fi

cleanup() {
  if [[ -n "${MOUNT_POINT:-}" ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null \
      || hdiutil detach "$MOUNT_POINT" -force 2>/dev/null \
      || true
    # Own mountpoint directory (not /Volumes/…) may remain empty after detach.
    if [[ -d "$MOUNT_POINT" && "$MOUNT_POINT" == "$DIST"/dmg-verify-mount-* ]]; then
      rmdir "$MOUNT_POINT" 2>/dev/null || true
    fi
  fi
}
trap cleanup EXIT

echo "==> Checking mounted contents at: $MOUNT_POINT"
ls -la "$MOUNT_POINT"
test -d "$MOUNT_POINT/${APP_NAME}.app"
test -L "$MOUNT_POINT/Applications"
MOUNTED_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$MOUNT_POINT/${APP_NAME}.app/Contents/Info.plist")"
test "$MOUNTED_ID" = "com.quietcalendar.app"
MOUNTED_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MOUNT_POINT/${APP_NAME}.app/Contents/Info.plist")"
test "$MOUNTED_VER" = "$VERSION"

MOUNTED_APP="$MOUNT_POINT/${APP_NAME}.app"

# As-shipped signature checks on the MOUNTED app: same team as the built app,
# and a certificate/team-anchored designated requirement (NOT cdhash
# equality) so TCC grants survive future rebuilds.
MOUNTED_TEAM="$(codesign -dvv "$MOUNTED_APP" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
MOUNTED_AUTHORITY="$(codesign -dvv "$MOUNTED_APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
MOUNTED_DR="$(codesign -d -r - "$MOUNTED_APP" 2>/dev/null | sed -n 's/^designated => //p' | tail -1)"
echo "Mounted app TeamIdentifier: $MOUNTED_TEAM"
echo "Mounted app authority: $MOUNTED_AUTHORITY"
echo "Mounted app designated requirement: $MOUNTED_DR"
if [[ -n "${BUILT_TEAM:-}" ]]; then
  test "$MOUNTED_TEAM" = "$BUILT_TEAM"
  if [[ "$MOUNTED_DR" == *"anchor apple generic"* \
     && ( "$MOUNTED_DR" == *"certificate leaf[subject.CN]"* || "$MOUNTED_DR" == *"certificate leaf[subject.OU]"* ) \
     && "$MOUNTED_DR" != *"cdhash"* ]]; then
    :
  else
    echo "Mounted app designated requirement is not certificate/team anchored" >&2
    exit 1
  fi
fi
codesign --verify --strict "$MOUNTED_APP"
echo "Mounted app signature: valid (codesign --verify --strict)"

# The public Desktop OAuth client ID must survive into the DMG so sign-in is
# configured on a plain Finder launch (no env export). Public identifier only.
MOUNTED_CLIENT_ID="$(/usr/libexec/PlistBuddy -c 'Print :GoogleDesktopOAuthClientID' "$MOUNTED_APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ -z "${MOUNTED_CLIENT_ID//[[:space:]]/}" ]]; then
  echo "Mounted app missing GoogleDesktopOAuthClientID" >&2
  exit 1
fi
echo "Mounted app client ID: ${MOUNTED_CLIENT_ID:0:12}…${MOUNTED_CLIENT_ID: -10}"
# No client secret anywhere in the bundle.
if grep -RIl "client_secret" "$MOUNTED_APP/Contents" >/dev/null 2>&1; then
  echo "Refusing to ship a bundle containing client_secret" >&2
  exit 1
fi

test -x "$MOUNTED_APP/Contents/MacOS/QuietCalendar"
test -x "$MOUNTED_APP/Contents/Resources/SpeechRuntime/QuietCalendarTranscribe"
# Sparkle update framework must survive into the DMG, still strictly valid.
test -d "$MOUNTED_APP/Contents/Frameworks/Sparkle.framework"
codesign --verify --strict "$MOUNTED_APP/Contents/Frameworks/Sparkle.framework"
MOUNTED_FEED="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$MOUNTED_APP/Contents/Info.plist" 2>/dev/null || true)"
MOUNTED_PUBKEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$MOUNTED_APP/Contents/Info.plist" 2>/dev/null || true)"
test "$MOUNTED_FEED" = "https://github.com/bootsphotography1-beep/QuikCal/releases/latest/download/appcast.xml"
test -n "$MOUNTED_PUBKEY"
echo "Mounted app Sparkle feed + EdDSA public key: present"
test -f "$MOUNTED_APP/Contents/Resources/Notices/LICENSE-transcribe.cpp.txt"
test -f "$MOUNTED_APP/Contents/Resources/Notices/LICENSE-ggml.txt"
test -f "$MOUNTED_APP/Contents/Resources/Notices/NOTICE-NVIDIA-Parakeet.txt"
# No Parakeet weights inside DMG until licensing review
if find "$MOUNTED_APP" -name '*.gguf' | grep -q .; then
  echo "DMG must not contain GGUF weights" >&2
  exit 1
fi
# Helper is self-contained (system frameworks only) — Frameworks may be empty.
echo "==> otool helper linkage"
otool -L "$MOUNTED_APP/Contents/Resources/SpeechRuntime/QuietCalendarTranscribe" | head -20

SRC_EXE_HASH="$(shasum -a 256 "$APP_SRC/Contents/MacOS/QuietCalendar" | awk '{print $1}')"
DMG_EXE_HASH="$(shasum -a 256 "$MOUNTED_APP/Contents/MacOS/QuietCalendar" | awk '{print $1}')"
test "$SRC_EXE_HASH" = "$DMG_EXE_HASH"
echo "Executable SHA-256 (build == DMG): $DMG_EXE_HASH"

SRC_HELPER_HASH="$(shasum -a 256 "$APP_SRC/Contents/Resources/SpeechRuntime/QuietCalendarTranscribe" | awk '{print $1}')"
DMG_HELPER_HASH="$(shasum -a 256 "$MOUNTED_APP/Contents/Resources/SpeechRuntime/QuietCalendarTranscribe" | awk '{print $1}')"
test "$SRC_HELPER_HASH" = "$DMG_HELPER_HASH"
echo "Helper SHA-256 (build == DMG): $DMG_HELPER_HASH"

hdiutil verify "$DMG_PATH"

cleanup
trap - EXIT
MOUNT_POINT=""

rm -rf "$STAGE"

echo "Built DMG: $DMG_PATH"
ls -lh "$DMG_PATH"
echo "Note: signed with an existing Apple Development identity (Team ${BUILT_TEAM:-?}) — NOT Developer ID, NOT notarized."
echo "Gatekeeper caveat: first open on a machine may still warn (right-click > Open, or System Settings > Privacy & Security > Open Anyway)."
echo "Accessibility caveat: the FIRST stable-signed install needs a one-time fresh Accessibility grant; future identity-signed updates keep it."
