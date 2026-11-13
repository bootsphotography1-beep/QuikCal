#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> swift build -c release"
swift build -c release

APP="$ROOT/build/QuikCal.app"
HELPER_SRC="$ROOT/Resources/SpeechRuntime/QuietCalendarTranscribe"
if [[ ! -x "$HELPER_SRC" ]]; then
  # Fall back to pinned Metal runtime artifact
  HELPER_SRC="$ROOT/vendor/local-models/transcribe.cpp/build/bin/transcribe-cli"
fi
if [[ ! -x "$HELPER_SRC" ]]; then
  echo "Missing QuietCalendarTranscribe / transcribe-cli helper" >&2
  exit 1
fi

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p \
  "$APP/Contents/MacOS" \
  "$APP/Contents/Resources/SpeechRuntime" \
  "$APP/Contents/Resources/Notices" \
  "$APP/Contents/Frameworks"

cp "$ROOT/.build/release/QuietCalendar" "$APP/Contents/MacOS/QuietCalendar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Public Desktop OAuth client ID must be present so a Finder launch works
# without any environment export. Public by design (no secret, PKCE flow).
CLIENT_ID="$(/usr/libexec/PlistBuddy -c 'Print :GoogleDesktopOAuthClientID' "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ -z "${CLIENT_ID//[[:space:]]/}" ]]; then
  echo "Refusing to package: Info.plist missing GoogleDesktopOAuthClientID" >&2
  exit 1
fi
echo "==> Client ID configured: ${CLIENT_ID:0:12}…${CLIENT_ID: -10} (public Desktop client, no secret)"

# App icon: derived from the committed master artwork (Resources/AppIcon/
# quikcal-app-icon.png) so every normal build ships the same logo.
"$ROOT/scripts/build_icon.sh"
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
if [[ ! -f "$APP/Contents/Resources/AppIcon.icns" ]]; then
  echo "Refusing to package: app icon (AppIcon.icns) missing from the bundle" >&2
  exit 1
fi
echo "==> Bundled AppIcon.icns (Info.plist CFBundleIconFile=AppIcon)"

# Bundled speech helper (statically linked Metal runtime — no extra dylibs required).
cp "$HELPER_SRC" "$APP/Contents/Resources/SpeechRuntime/QuietCalendarTranscribe"
chmod 755 "$APP/Contents/Resources/SpeechRuntime/QuietCalendarTranscribe"
if [[ -f "$ROOT/Resources/SpeechRuntime/QuietCalendarTranscribe.sha256" ]]; then
  cp "$ROOT/Resources/SpeechRuntime/QuietCalendarTranscribe.sha256" \
    "$APP/Contents/Resources/SpeechRuntime/QuietCalendarTranscribe.sha256"
fi
if [[ -f "$ROOT/Resources/SpeechRuntime/parakeet-model-manifest.json" ]]; then
  cp "$ROOT/Resources/SpeechRuntime/parakeet-model-manifest.json" \
    "$APP/Contents/Resources/SpeechRuntime/parakeet-model-manifest.json"
fi

# MIT / ggml / NVIDIA notices (weights themselves are NOT copied into the app/DMG).
cp "$ROOT/Resources/Notices/"* "$APP/Contents/Resources/Notices/" 2>/dev/null || true

# Sparkle 2 framework (SwiftPM binary artifact, resolved by Package.resolved).
# Copied with ditto so the Versions/Current symlink structure is preserved
# EXACTLY — Sparkle's helpers and code signing depend on it. Only the
# framework ships; the signing tools stay in .build (never in the bundle).
SPARKLE_SRC="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ -d "$SPARKLE_SRC" ]]; then
  ditto "$SPARKLE_SRC" "$APP/Contents/Frameworks/Sparkle.framework"
  echo "==> Bundled Sparkle.framework (manual Check for Updates…)"
else
  echo "Refusing to build: Sparkle.framework artifact missing (swift package resolve)" >&2
  exit 1
fi

# Relative rpath for future Frameworks payloads (empty today; helper is self-contained).
install_name_tool -add_rpath "@executable_path/../Frameworks" \
  "$APP/Contents/MacOS/QuietCalendar" 2>/dev/null || true
install_name_tool -add_rpath "@executable_path/../Resources/SpeechRuntime" \
  "$APP/Contents/MacOS/QuietCalendar" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Codesigning.
# Default: identity-based signing with the EXISTING valid Apple Development
# identity, giving a stable certificate/Team-ID designated requirement so
# TCC (Accessibility) grants survive future rebuilds. Fails explicitly when
# the identity is missing or ambiguous — never silently falls back to ad-hoc.
# Optional explicit development ad-hoc mode (never for distributable DMGs):
#   QUIKCAL_SIGN_MODE=adhoc scripts/build_app.sh
# Identity discovery is read-only (names only; no key extraction).
# ---------------------------------------------------------------------------
SIGN_MODE="${QUIKCAL_SIGN_MODE:-identity}"
if [[ "$SIGN_MODE" == "adhoc" ]]; then
  echo "==> EXPLICIT ad-hoc development signing (QUIKCAL_SIGN_MODE=adhoc) — do NOT ship DMGs built this way" >&2
  SIGN_IDENTITY="-"
else
  DEV_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development:" || true)"
  if [[ -z "$DEV_IDENTITIES" ]]; then
    echo "Refusing to build: no valid Apple Development identity found (security find-identity -v -p codesigning)." >&2
    echo "For local development only, run with QUIKCAL_SIGN_MODE=adhoc — never for distributable DMGs." >&2
    exit 1
  fi
  DEV_IDENTITY_COUNT="$(printf '%s\n' "$DEV_IDENTITIES" | grep -c "Apple Development:")"
  if [[ "$DEV_IDENTITY_COUNT" -ne 1 ]]; then
    echo "Refusing to build: $DEV_IDENTITY_COUNT valid Apple Development identities found — ambiguous, resolve manually." >&2
    exit 1
  fi
  SIGN_IDENTITY="$(printf '%s\n' "$DEV_IDENTITIES" | sed -E 's/.*"(.*)"[[:space:]]*$/\1/')"
  echo "==> Identity-based codesign with: $SIGN_IDENTITY"
fi

echo "==> Codesign (Sparkle nested XPC/helpers first, then speech helper, then bundle — inside-out)"
SPARKLE_B="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$SPARKLE_B/XPCServices/Downloader.xpc"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$SPARKLE_B/XPCServices/Installer.xpc"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$SPARKLE_B/Updater.app"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$SPARKLE_B/Autoupdate"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP/Contents/Frameworks/Sparkle.framework"
codesign --verify --strict "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
  "$APP/Contents/Resources/SpeechRuntime/QuietCalendarTranscribe"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP"
if [[ "$SIGN_MODE" == "adhoc" ]]; then
  echo "Signature: ad-hoc (development only — cdhash identity churns per build)"
else
  SIGN_TEAM="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
  SIGN_DR="$(codesign -d -r - "$APP" 2>/dev/null | sed -n 's/^designated => //p' | tail -1)"
  echo "TeamIdentifier: $SIGN_TEAM"
  echo "Designated requirement: $SIGN_DR"
  # The designated requirement MUST anchor on the certificate (subject.CN or
  # subject.OU) — NOT on a per-build cdhash — that is exactly what makes TCC
  # grants survive rebuilds.
  if [[ "$SIGN_DR" == *"anchor apple generic"* \
     && ( "$SIGN_DR" == *"certificate leaf[subject.CN]"* || "$SIGN_DR" == *"certificate leaf[subject.OU]"* ) \
     && "$SIGN_DR" != *"cdhash"* ]]; then
    echo "Designated requirement is certificate-anchored (stable across rebuilds)"
  else
    echo "Refusing to build: designated requirement is not certificate/team anchored." >&2
    echo "DR was: $SIGN_DR" >&2
    exit 1
  fi
fi

echo "Built: $APP"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"

# Essential Sparkle distribution checks (0.3.18–0.3.19): the executable must
# link the bundled framework via @rpath, and the public update config must be
# present in the shipped Info.plist (feed URL exact; EdDSA PUBLIC key only;
# 0.3.19 notify-only automatic checks).
otool -L "$APP/Contents/MacOS/QuietCalendar" | grep -q "@rpath/Sparkle.framework" \
  || { echo "Refusing to ship: executable does not link @rpath/Sparkle.framework" >&2; exit 1; }
FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist" 2>/dev/null || true)"
ED_PUBKEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ "$FEED_URL" == "https://github.com/bootsphotography1-beep/QuikCal/releases/latest/download/appcast.xml" ]] \
  || { echo "Refusing to ship: unexpected/missing SUFeedURL: $FEED_URL" >&2; exit 1; }
[[ -n "${ED_PUBKEY//[[:space:]]/}" ]] \
  || { echo "Refusing to ship: missing SUPublicEDKey" >&2; exit 1; }
# 0.3.19 (owner-approved): automatic CHECKS on by default (also suppresses
# Sparkle's second-launch consent prompt), and automatic download/install
# structurally disallowed — notify-only via the native update alert.
AUTO_CHECKS="$(/usr/libexec/PlistBuddy -c 'Print :SUEnableAutomaticChecks' "$APP/Contents/Info.plist" 2>/dev/null || true)"
ALLOW_AUTO_INSTALL="$(/usr/libexec/PlistBuddy -c 'Print :SUAllowsAutomaticUpdates' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ "$AUTO_CHECKS" == "true" ]] \
  || { echo "Refusing to ship: SUEnableAutomaticChecks must be true (default-on automatic checks)" >&2; exit 1; }
[[ "$ALLOW_AUTO_INSTALL" == "false" ]] \
  || { echo "Refusing to ship: SUAllowsAutomaticUpdates must be false (never silent download/install)" >&2; exit 1; }
echo "Sparkle feed: $FEED_URL"
echo "Sparkle EdDSA public key: $ED_PUBKEY"
echo "Sparkle automatic checks: default ON, notify-only (automatic download/install disallowed)"

shasum -a 256 "$APP/Contents/MacOS/QuietCalendar"
shasum -a 256 "$APP/Contents/Resources/SpeechRuntime/QuietCalendarTranscribe"
ls -la "$APP/Contents/Resources/Notices"
ls -la "$APP/Contents/Resources/SpeechRuntime"
# Confirm no unexpected bundled weight files
if find "$APP" -name '*.gguf' | grep -q .; then
  echo "Refusing to ship GGUF weights inside app bundle until licensing review" >&2
  exit 1
fi
