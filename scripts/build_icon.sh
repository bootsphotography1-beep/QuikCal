#!/bin/zsh
set -euo pipefail

# Derives the macOS app icon (.icns) from the committed master artwork.
#
# Master artwork (the single source of truth for the QuikCal logo):
#   Resources/AppIcon/quikcal-app-icon.png
#
# The master is scaled AS-IS into every representation macOS asks for:
# no crop, no padding, no recolour, no redesign — artwork, aspect ratio
# and alpha are preserved exactly. The .iconset working directory is a
# throwaway temp dir (never left in the repo); only the finished .icns
# lands in the gitignored build/ output dir.
#
# Output: build/AppIcon.icns  (copied into the bundle by build_app.sh)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MASTER="$ROOT/Resources/AppIcon/quikcal-app-icon.png"
OUT_DIR="$ROOT/build"
OUT="$OUT_DIR/AppIcon.icns"

if [[ ! -f "$MASTER" ]]; then
  echo "Missing master app icon artwork: $MASTER" >&2
  exit 1
fi
for tool in sips iconutil; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing required tool: $tool" >&2; exit 1; }
done

MASTER_SHA="$(shasum -a 256 "$MASTER" | awk '{print $1}')"
MASTER_DIM="$(sips -g pixelWidth -g pixelHeight "$MASTER" 2>/dev/null | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w"x"h}')"
MASTER_ALPHA="$(sips -g hasAlpha "$MASTER" 2>/dev/null | awk '/hasAlpha/{print $2}')"
if [[ "$MASTER_ALPHA" != "yes" ]]; then
  echo "Refusing to build icon: master artwork has no alpha channel ($MASTER_ALPHA)" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

emit() {
  local name="$1" size="$2"
  sips -z "$size" "$size" "$MASTER" --out "$ICONSET/$name" >/dev/null
}

# The exact representation set iconutil requires for a macOS .icns.
emit icon_16x16.png 16
emit icon_16x16@2x.png 32
emit icon_32x32.png 32
emit icon_32x32@2x.png 64
emit icon_128x128.png 128
emit icon_128x128@2x.png 256
emit icon_256x256.png 256
emit icon_256x256@2x.png 512
emit icon_512x512.png 512
emit icon_512x512@2x.png 1024

# Verify every generated representation kept its alpha before packaging.
for f in "$ICONSET"/*.png; do
  a="$(sips -g hasAlpha "$f" 2>/dev/null | awk '/hasAlpha/{print $2}')"
  [[ "$a" == "yes" ]] || { echo "Refusing to build icon: $f lost its alpha channel" >&2; exit 1; }
done

iconutil -c icns "$ICONSET" -o "$OUT"

echo "==> App icon built from master artwork"
echo "    master:   $MASTER ($MASTER_DIM, alpha=$MASTER_ALPHA)"
echo "    master sha256: $MASTER_SHA"
echo "    icns:     $OUT"
sips -g pixelWidth -g pixelHeight -g hasAlpha "$OUT" 2>/dev/null | sed 's/^/    /'
shasum -a 256 "$OUT" | sed 's/^/    icns sha256: /'
