#!/usr/bin/env python3
"""Single fixed pass on the frozen held-out set (heldout_qwen35_4b_v2.json).

No prompt tuning against this set: the protocol is hash-frozen in
HELDOUT_PROTOCOL_SHA256.txt before any inference. Results (raw outputs only,
no scores) are written to model-research/qwen35-4b/heldout_results_<ts>.json.
Scoring runs through the shipped Swift PhraseValidator (see RegressionReplayTests)
so the product metrics measure the actual app pipeline, not a python mirror.
"""
import argparse, hashlib, json, time, urllib.request
from pathlib import Path

# Repo root is derived from this file's own location
# (scripts/models/<name>.py -> parents[2] == repo root) so the script is
# portable across machines and checkout locations.
BASE = str(Path(__file__).resolve().parents[2])
PROTOCOL = f"{BASE}/model-research/qwen35-4b/heldout_qwen35_4b_v2.json"
OUTDIR = f"{BASE}/model-research/qwen35-4b"

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=None)
    args = ap.parse_args()
    proto_bytes = open(PROTOCOL, "rb").read()
    digest = hashlib.sha256(proto_bytes).hexdigest()
    frozen = open(f"{OUTDIR}/HELDOUT_PROTOCOL_SHA256.txt").read().split()[0]
    assert digest == frozen, f"Protocol changed after freeze: {digest} != {frozen}"
    proto = json.loads(proto_bytes)
    cases = proto["cases"][: args.limit] if args.limit else proto["cases"]
    results = []
    for c in cases:
        payload = {
            "model": proto["model"],
            "messages": [
                {"role": "system", "content": proto["system_prompt"]},
                {"role": "user", "content": c["transcript"]},
            ],
            "stream": False,
            "think": False,
            "format": proto["schema"],
            "options": {"temperature": proto["temperature"], "num_predict": proto["num_predict"]},
        }
        t0 = time.time()
        req = urllib.request.Request("http://127.0.0.1:11434/api/chat", data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=300) as r:
            raw = json.load(r)
        wall = time.time() - t0
        content = raw.get("message", {}).get("content", "")
        results.append({
            "id": c["id"], "category": c["category"], "transcript": c["transcript"],
            "wall_seconds": wall, "done_reason": raw.get("done_reason"),
            "prompt_eval_count": raw.get("prompt_eval_count"), "eval_count": raw.get("eval_count"),
            "raw_response": raw, "content": content,
        })
        print(c["id"], "done_reason=", raw.get("done_reason"), "wall=", round(wall, 3), "eval_tokens=", raw.get("eval_count"))
    import datetime
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    out = f"{OUTDIR}/heldout_results_{ts}.json"
    with open(out, "w") as f:
        json.dump({"protocol_sha256": digest, "results": results}, f, indent=2)
    print("saved", out)

if __name__ == "__main__":
    main()
