#!/bin/zsh
# QuikCal release PUBLISH — explicit human action only (2026-11-08).
#
# Uploads the prepared Sparkle update assets as a GitHub release:
#   - QuikCal-<version>.zip   (appcast enclosure — immutable, version-specific)
#   - appcast.xml             (EdDSA-signed feed; served via
#                              releases/latest/download/appcast.xml)
#   - QuikCal-<version>.dmg   (human installer, optional asset)
#
# This script NEVER runs automatically (no CI, no per-commit push) and never
# publishes SOURCE. It only creates the GitHub release + assets for an
# already-reviewed, already-prepared (scripts/prepare_release_assets.sh) set.
#
# Usage: scripts/publish_release.sh [--confirm] [--with-dmg]
#   --confirm    actually publish; without it the script only prints a plan.
#   --with-dmg   also upload dist/QuikCal-<version>.dmg as a release asset.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REPO="bootsphotography1-beep/QuikCal"
CONFIRM=0; WITH_DMG=0
for arg in "$@"; do
  case "$arg" in
    --confirm) CONFIRM=1 ;;
    --with-dmg) WITH_DMG=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
TAG="v${VERSION}"
OUT="$ROOT/dist/release-v${VERSION}"
ZIP="$OUT/QuikCal-${VERSION}.zip"
APPCAST="$OUT/appcast.xml"
DMG="$ROOT/dist/QuikCal-${VERSION}.dmg"

[[ -f "$ZIP" && -f "$APPCAST" ]] || {
  echo "Missing prepared assets in $OUT — run scripts/prepare_release_assets.sh first." >&2
  exit 1
}

# The repo must already have source pushed (source publication is a separate,
# explicit owner action). A release needs a commit to tag.
EMPTY="$(gh repo view "$REPO" --json isEmpty --jq .isEmpty)"
if [[ "$EMPTY" = "true" ]]; then
  echo "Refusing to publish: $REPO is empty — push the reviewed source first (separate owner action)." >&2
  exit 1
fi

PLAN=(
  gh release create "$TAG" "$REPO"
  --title "QuikCal ${VERSION}"
  --notes "See the release notes in the appcast / app."
)
ASSETS=("$ZIP" "$APPCAST")
if [[ "$WITH_DMG" = "1" ]]; then
  [[ -f "$DMG" ]] || { echo "Missing $DMG" >&2; exit 1; }
  ASSETS+=("$DMG")
fi

echo "==> Publish plan (tag $TAG on $REPO):"
printf '  %s\n' "${PLAN[@]}" "${ASSETS[@]}"
if [[ "$CONFIRM" != "1" ]]; then
  echo "NOT published — re-run with --confirm to publish after independent review."
  exit 0
fi

gh release create "$TAG" "${ASSETS[@]}" --repo "$REPO" \
  --title "QuikCal ${VERSION}" \
  --notes "QuikCal ${VERSION}. Sparkle update feed: appcast.xml (EdDSA-signed; enclosure QuikCal-${VERSION}.zip)."
echo "Published: https://github.com/$REPO/releases/tag/$TAG"
echo "Stable feed live at: https://github.com/$REPO/releases/latest/download/appcast.xml"
