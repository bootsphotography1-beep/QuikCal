#!/usr/bin/env python3
"""Frozen synthetic calendar-intent eval against local Ollama loopback only.

Preregistered cases + scoring live in preregistered_cases.json (written before outcomes).
No calendar writes. No remote hosts. Does not change Ollama defaults.
"""
from __future__ import annotations

import argparse
import json
import re
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[2]
CASES_PATH = Path(__file__).resolve().parent / "preregistered_cases.json"
OUT_DIR = ROOT / "local-models" / "eval-results"
OLLAMA = "http://127.0.0.1:11434/api/chat"

ALLOWED_KEYS = {"title", "date", "start_time", "duration_minutes", "location"}
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
TIME_RE = re.compile(r"^\d{2}:\d{2}$")


def load_cases() -> dict[str, Any]:
    return json.loads(CASES_PATH.read_text())


def system_prompt(template: str, today: str) -> str:
    return template.replace("{today}", today)


def call_ollama(model: str, system: str, user: str, timeout: float = 60.0) -> tuple[dict[str, Any], float, str | None]:
    body = {
        "model": model,
        "stream": False,
        "format": "json",
        "options": {"temperature": 0, "num_predict": 220},
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
    }
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        OLLAMA,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode()
        latency = time.perf_counter() - t0
        envelope = json.loads(raw)
        content = None
        msg = envelope.get("message") or {}
        if isinstance(msg.get("content"), str):
            content = msg["content"]
        elif isinstance(envelope.get("response"), str):
            content = envelope["response"]
        return envelope, latency, content
    except Exception as e:  # noqa: BLE001 — record harness failures
        latency = time.perf_counter() - t0
        return {"error": str(e)}, latency, None


def parse_intent_json(text: str | None) -> tuple[dict[str, Any] | None, list[str]]:
    errors: list[str] = []
    if text is None or not str(text).strip():
        return None, ["empty output"]
    try:
        obj = json.loads(text)
    except json.JSONDecodeError:
        return None, ["not valid JSON"]
    if not isinstance(obj, dict):
        return None, ["expected a JSON object"]
    extra = sorted(set(obj) - ALLOWED_KEYS)
    if extra:
        errors.append(f"unexpected fields: {extra}")
    if "title" not in obj:
        errors.append("missing title")
        return obj, errors
    title = obj.get("title")
    if not isinstance(title, str) or not title.strip():
        errors.append("title must be non-empty string")
    for key in ("date", "start_time", "location"):
        val = obj.get(key, None)
        if val is None:
            continue
        if not isinstance(val, str):
            errors.append(f"{key} must be string or null")
        elif key == "date" and not DATE_RE.match(val):
            errors.append("date must be YYYY-MM-DD")
        elif key == "start_time" and not TIME_RE.match(val):
            errors.append("start_time must be HH:MM")
    dur = obj.get("duration_minutes", None)
    if dur is not None:
        if type(dur) is not int and not (isinstance(dur, float) and dur == int(dur)):
            if isinstance(dur, bool):
                errors.append("duration_minutes must be integer or null")
            elif not isinstance(dur, (int, float)):
                errors.append("duration_minutes must be integer or null")
            else:
                errors.append("duration_minutes must be whole number")
        else:
            ival = int(dur)
            if ival < 5 or ival > 720:
                errors.append("duration_minutes out of bounds 5-720")
    return obj, errors


def score_case(case: dict[str, Any], obj: dict[str, Any] | None, schema_errors: list[str]) -> dict[str, Any]:
    expect = case["expect"]
    failures: list[str] = []
    checks: dict[str, bool] = {}

    if obj is None:
        return {"pass": False, "failures": schema_errors or ["no object"], "checks": {"schema_valid": False}}

    schema_ok = not schema_errors
    checks["schema_valid"] = schema_ok
    if not schema_ok:
        failures.extend(schema_errors)

    if expect.get("unsupported_multi_event"):
        title = str(obj.get("title") or "")
        multi_ok = title == "UNSUPPORTED_MULTI_EVENT" and all(
            obj.get(k) is None for k in ("date", "start_time", "duration_minutes", "location")
        )
        # Fail-closed alternative: refuse by invalid/null-heavy output without fabricating a single event's full schedule
        fabricated_single = (
            isinstance(obj.get("date"), str)
            and isinstance(obj.get("start_time"), str)
            and title
            and title != "UNSUPPORTED_MULTI_EVENT"
        )
        ok = multi_ok or (expect.get("or_fail_closed") and not fabricated_single and (
            title == "UNSUPPORTED_MULTI_EVENT" or not schema_ok or obj.get("start_time") is None
        ))
        # Stricter product gate: only UNSUPPORTED_MULTI_EVENT or clearly not inventing a complete single event
        if multi_ok:
            checks["multi_event"] = True
        elif fabricated_single:
            checks["multi_event"] = False
            failures.append("silently fabricated/kept a single scheduled event from multi-event input")
        else:
            # Partial fail-closed: did not invent a full single event
            checks["multi_event"] = True
            checks["multi_event_fail_closed_partial"] = True
        return {
            "pass": checks.get("multi_event", False) and (multi_ok or checks.get("multi_event_fail_closed_partial")),
            "failures": failures,
            "checks": checks,
            "strict_unsupported": multi_ok,
        }

    title = str(obj.get("title") or "")
    if expect.get("title_nonempty"):
        ok = bool(title.strip())
        checks["title_nonempty"] = ok
        if not ok:
            failures.append("empty title")
    for frag in expect.get("title_contains") or []:
        ok = frag.lower() in title.lower()
        checks[f"title_contains:{frag}"] = ok
        if not ok:
            failures.append(f"title missing '{frag}'")
    for frag in expect.get("title_forbids") or []:
        ok = frag.lower() not in title.lower()
        checks[f"title_forbids:{frag}"] = ok
        if not ok:
            failures.append(f"title contains forbidden '{frag}'")

    for field in ("date", "start_time", "duration_minutes", "location"):
        if field not in expect:
            continue
        exp = expect[field]
        got = obj.get(field)
        ok = got == exp
        checks[f"{field}_exact"] = ok
        if not ok:
            failures.append(f"{field}: expected {exp!r} got {got!r}")

    if expect.get("forbid_invented_date") and obj.get("date") is not None:
        checks["forbid_invented_date"] = False
        failures.append(f"invented date {obj.get('date')!r}")
    elif expect.get("forbid_invented_date"):
        checks["forbid_invented_date"] = True

    if expect.get("forbid_invented_clock") and obj.get("start_time") is not None:
        checks["forbid_invented_clock"] = False
        failures.append(f"invented start_time {obj.get('start_time')!r}")
    elif expect.get("forbid_invented_clock"):
        checks["forbid_invented_clock"] = True

    if expect.get("ampm_must_clarify_or_null"):
        ok = obj.get("start_time") is None
        checks["ampm_null"] = ok
        if not ok:
            failures.append("AM/PM ambiguous but start_time was set")

    if expect.get("forbid_extra_keys"):
        extra = sorted(set(obj) - ALLOWED_KEYS)
        ok = not extra
        checks["no_extra_keys"] = ok
        if not ok:
            failures.append(f"extra keys {extra}")

    if expect.get("forbid_far_date"):
        d = obj.get("date")
        ok = not (isinstance(d, str) and d.startswith("2099"))
        checks["forbid_far_date"] = ok
        if not ok:
            failures.append("accepted injection far date")

    # Exact-match pass requires schema ok and no failures
    passed = schema_ok and not failures
    return {"pass": passed, "failures": failures, "checks": checks}


def model_footprint(model: str) -> dict[str, Any]:
    req = urllib.request.Request(f"http://127.0.0.1:11434/api/show", data=json.dumps({"name": model}).encode(), headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            info = json.loads(resp.read().decode())
        details = info.get("details") or {}
        return {
            "model": model,
            "family": details.get("family"),
            "parameter_size": details.get("parameter_size"),
            "quantization": details.get("quantization_level"),
            "license_head": (info.get("license") or "")[:80],
        }
    except Exception as e:  # noqa: BLE001
        return {"model": model, "error": str(e)}


def run_model(model: str, suite: dict[str, Any]) -> dict[str, Any]:
    ref = datetime.fromisoformat(suite["reference_now"])
    today = ref.date().isoformat()
    sys_p = system_prompt(suite["system_prompt_template"], today)
    results = []
    for case in suite["cases"]:
        envelope, latency, content = call_ollama(model, sys_p, case["input"])
        obj, schema_errors = parse_intent_json(content)
        scored = score_case(case, obj, schema_errors)
        results.append(
            {
                "id": case["id"],
                "input": case["input"],
                "latency_s": round(latency, 4),
                "raw_content": content,
                "parsed": obj,
                "schema_errors": schema_errors,
                "score": scored,
            }
        )
    passed = sum(1 for r in results if r["score"]["pass"])
    return {
        "model": model,
        "footprint": model_footprint(model),
        "n_cases": len(results),
        "n_pass": passed,
        "n_fail": len(results) - passed,
        "pass_rate": round(passed / len(results), 4) if results else 0.0,
        "results": results,
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", nargs="+", required=True)
    ap.add_argument("--tag", default="run")
    args = ap.parse_args()
    suite = load_cases()
    assert suite.get("frozen_before_outcomes") is True
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(ZoneInfo("America/Los_Angeles")).strftime("%Y%m%d-%H%M%S")
    summary = {
        "tag": args.tag,
        "stamp": stamp,
        "cases_path": str(CASES_PATH),
        "reference_now": suite["reference_now"],
        "timezone": suite["timezone"],
        "models": [],
    }
    for model in args.models:
        print(f"Evaluating {model} ...", flush=True)
        report = run_model(model, suite)
        summary["models"].append(
            {
                "model": model,
                "n_pass": report["n_pass"],
                "n_fail": report["n_fail"],
                "pass_rate": report["pass_rate"],
                "footprint": report["footprint"],
            }
        )
        out = OUT_DIR / f"{args.tag}_{model.replace(':', '_').replace('/', '_')}_{stamp}.json"
        out.write_text(json.dumps(report, indent=2))
        print(f"  {report['n_pass']}/{report['n_cases']} pass -> {out}", flush=True)
    summary_path = OUT_DIR / f"{args.tag}_summary_{stamp}.json"
    summary_path.write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
