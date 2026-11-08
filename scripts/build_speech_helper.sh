#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$ROOT/vendor/local-models/transcribe.cpp"
BUILD="$ENGINE/build"

if ! command -v cmake >/dev/null 2>&1; then
  echo "Missing CMake. Install it using your normal development-tool workflow." >&2
  exit 1
fi

cmake -S "$ENGINE" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DTRANSCRIBE_BUILD_TESTS=OFF \
  -DTRANSCRIBE_BUILD_EXAMPLES=ON \
  -DTRANSCRIBE_BUILD_TOOLS=OFF \
  -DTRANSCRIBE_ENABLE_VALIDATION_HOOKS=OFF

cmake --build "$BUILD" --target transcribe-cli --parallel

HELPER="$BUILD/bin/transcribe-cli"
if [[ ! -x "$HELPER" ]]; then
  echo "Speech helper build did not produce an executable at $HELPER" >&2
  exit 1
fi

echo "Built the Parakeet-capable speech helper: $HELPER"
echo "No speech-model weights were downloaded or bundled."
