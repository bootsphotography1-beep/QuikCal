#!/bin/zsh
# Packaging acceptance: codesigned packaged helper + Quiet Calendar–owned AS weights ONLY.
# Missing prerequisite → clear FAIL (exit 1). No vendor CLI / Hex AS fallback.
# Skip of the gated unit test is NOT an integration pass — this script fails closed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/Quiet Calendar.app"
HELPER="$APP/Contents/Resources/SpeechRuntime/QuietCalendarTranscribe"
MODEL="${QUIET_CALENDAR_MODEL_PATH:-$HOME/Library/Application Support/QuietCalendar/models/parakeet-unified-en-0.6b-Q8_0.gguf}"
HEX_MODEL="$HOME/Library/Application Support/hex/models/parakeet-unified-en-0.6b-Q8_0.gguf"
FIXTURE="$ROOT/local-models/stt-fixtures/SYNTHETIC_NOT_MIC_meeting_noon_sturm_16k_mono.wav"
OUT_DIR="$ROOT/local-models/stt-fixtures"
STDOUT_CAPTURE="$OUT_DIR/ACCEPT_0.2.3_packaged_helper_stdout.txt"
TRANSCRIPT_CAPTURE="$OUT_DIR/ACCEPT_0.2.3_packaged_transcript.txt"

fail() {
  echo "FAIL packaging acceptance: $*" >&2
  exit 1
}

echo "==> Prereq: packaged app + codesigned helper"
[[ -d "$APP" ]] || fail "missing app bundle at $APP (run scripts/build_app.sh or build_dmg.sh first)"
[[ -x "$HELPER" ]] || fail "missing packaged helper at $HELPER"
codesign --verify --verbose=2 "$HELPER" 2>/tmp/qc-accept-codesign.txt \
  || fail "helper codesign verify failed (see /tmp/qc-accept-codesign.txt)"
# Refuse unsigned-only Resources sibling mistaken for package when APP helper missing already checked.

echo "==> Prereq: QC-owned Application Support model (no Hex fallback)"
[[ -f "$MODEL" ]] || fail "QC Application Support model missing at $MODEL"
if [[ "$(cd "$(dirname "$MODEL")" && pwd)/$(basename "$MODEL")" == "$(cd "$(dirname "$HEX_MODEL")" 2>/dev/null && pwd)/$(basename "$HEX_MODEL")" ]]; then
  fail "refusing Hex Application Support path as QC-owned model"
fi
# Path must live under QuietCalendar Application Support unless explicitly overridden for QC.
case "$MODEL" in
  *"/QuietCalendar/models/"*) ;;
  *)
    if [[ -z "${QUIET_CALENDAR_MODEL_PATH:-}" ]]; then
      fail "model path is not under QuietCalendar/models: $MODEL"
    fi
    ;;
esac

echo "==> Prereq: synthetic fixture WAV"
[[ -f "$FIXTURE" ]] || fail "synthetic fixture missing at $FIXTURE"

echo "==> Run packaged helper (Metal, -q) on synthetic fixture"
mkdir -p "$OUT_DIR"
set +e
"$HELPER" -m "$MODEL" -q --timestamps none --backend metal "$FIXTURE" \
  >"$STDOUT_CAPTURE" 2>/tmp/qc-accept-helper-stderr.txt
HELPER_EC=$?
set -e
[[ $HELPER_EC -eq 0 ]] || fail "helper exit $HELPER_EC (stderr: /tmp/qc-accept-helper-stderr.txt)"

echo "==> Extract transcript via Swift extractTranscript (same as app)"
# Drive the gated Swift test which uses ProcessParakeetTranscribeClient.extractTranscript.
export QC_RUN_PACKAGED_SYNTHETIC=1
set +e
swift test --filter packagedHelperSyntheticAcceptanceQCOwnedOnly > /tmp/qc-accept-swift-test.txt 2>&1
SWIFT_EC=$?
set -e
cat /tmp/qc-accept-swift-test.txt
[[ $SWIFT_EC -eq 0 ]] || fail "swift packaged acceptance test failed (exit $SWIFT_EC)"

# Also assert raw CLI stdout → extract has no text: contamination using a tiny inline check
# mirroring the observed fixture contract (defense in depth vs test filter miss).
python3 - <<'PY' "$STDOUT_CAPTURE" "$TRANSCRIPT_CAPTURE"
import sys
path, out = sys.argv[1], sys.argv[2]
raw = open(path, "r", encoding="utf-8", errors="replace").read()
transcript = None
lines = raw.splitlines()
for i in range(len(lines) - 1, -1, -1):
    line = lines[i]
    if line.lstrip().lower().startswith("text:"):
        val = line.lstrip().split(":", 1)[1]
        if val.startswith(" "):
            val = val[1:]
        parts = [val]
        j = i + 1
        while j < len(lines):
            nxt = lines[j]
            low = nxt.lstrip().lower()
            diag = (
                low.startswith(("samples:", "duration:", "sample rate", "backend:", "name:",
                                "license:", "max audio:", "realtime:", "note:", "audio:",
                                "model:", "run:", "text:", "tokens:", "segments:"))
            )
            if diag:
                break
            parts.append(nxt)
            j += 1
        transcript = "\n".join(parts).strip()
        break
if transcript is None or transcript == "" or transcript == "(empty)":
    print("FAIL packaging acceptance: no usable text: transcript in helper stdout", file=sys.stderr)
    sys.exit(1)
if transcript.lower().startswith("text:"):
    print(f"FAIL packaging acceptance: text: prefix leaked into transcript: {transcript!r}", file=sys.stderr)
    sys.exit(1)
for bad in ("realtime:", "audio:", "model:"):
    if bad in transcript.lower():
        print(f"FAIL packaging acceptance: diagnostic {bad!r} in transcript: {transcript!r}", file=sys.stderr)
        sys.exit(1)
low = transcript.lower()
if not any(k in low for k in ("meeting", "noon", "sturm")):
    print(f"FAIL packaging acceptance: unexpected transcript content: {transcript!r}", file=sys.stderr)
    sys.exit(1)
open(out, "w", encoding="utf-8").write(transcript + "\n")
print(f"ACCEPT transcript: {transcript!r}")
PY

echo "==> PASS packaged synthetic acceptance (not production / not live mic)"
echo "stdout: $STDOUT_CAPTURE"
echo "transcript: $TRANSCRIPT_CAPTURE"
cat "$TRANSCRIPT_CAPTURE"
