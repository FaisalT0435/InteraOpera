#!/usr/bin/env python3
"""
Evaluation gate for gated model rollout.

Evaluates a deployed model version against the acceptance set,
measuring accuracy and p95 latency on both direct and RAG paths.
Returns PROMOTE or ROLLBACK decision with full evidence.

Usage:
    python eval/gate.py \
        --gateway-url http://localhost:8000 \
        --rag-url http://localhost:8080 \
        --eval-set eval/eval_set.jsonl \
        --output evidence/rollout-1.1-20240101.json
"""

import argparse
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import httpx
import numpy as np

# Thresholds from Meridian service agreement
ACCURACY_THRESHOLD = 0.90   # >= 90%
LATENCY_P95_MS = 1200       # <= 1200ms
ERROR_RATE_MAX = 0.01       # < 1%

TIMEOUT_SECS = 30.0


def load_eval_set(path: str) -> list[dict]:
    items = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                items.append(json.loads(line))
    return items


def call_gateway(client: httpx.Client, url: str, question: str) -> tuple[str, float]:
    """Call gateway direct path. Returns (answer, latency_seconds)."""
    payload = {
        "model": "meridian-slm",
        "messages": [{"role": "user", "content": question}],
    }
    t0 = time.perf_counter()
    resp = client.post(f"{url}/v1/chat/completions", json=payload, timeout=TIMEOUT_SECS)
    latency = time.perf_counter() - t0
    resp.raise_for_status()
    answer = resp.json()["choices"][0]["message"]["content"]
    return answer, latency


def call_rag(client: httpx.Client, url: str, question: str) -> tuple[str, float]:
    """Call RAG chat endpoint. Returns (answer, latency_seconds)."""
    t0 = time.perf_counter()
    resp = client.post(
        f"{url}/v1/rag/chat",
        json={"question": question},
        timeout=TIMEOUT_SECS,
    )
    latency = time.perf_counter() - t0
    resp.raise_for_status()
    answer = resp.json()["answer"]
    return answer, latency


def evaluate(
    gateway_url: str,
    rag_url: str,
    eval_set: list[dict],
    verbose: bool = True,
) -> dict:
    """Run full evaluation. Returns evidence dict."""

    direct_correct = []
    direct_latencies = []
    direct_errors = 0

    rag_correct = []
    rag_latencies = []
    rag_errors = 0

    with httpx.Client() as client:
        for item in eval_set:
            question = item["prompt"]
            expected = item["expected"]
            qid = item["id"]

            # ── Direct path ───────────────────────────────────────────────
            try:
                answer, latency = call_gateway(client, gateway_url, question)
                direct_latencies.append(latency)
                correct = answer.strip() == expected.strip()
                direct_correct.append(correct)
                if verbose:
                    status = "✓" if correct else "✗"
                    print(f"  [{status}] Q{qid} direct  ({latency*1000:.0f}ms): {answer[:60]}")
            except Exception as e:
                direct_errors += 1
                direct_correct.append(False)
                if verbose:
                    print(f"  [!] Q{qid} direct  ERROR: {e}")

            # ── RAG path ──────────────────────────────────────────────────
            try:
                answer, latency = call_rag(client, rag_url, question)
                rag_latencies.append(latency)
                correct = answer.strip() == expected.strip()
                rag_correct.append(correct)
                if verbose:
                    status = "✓" if correct else "✗"
                    print(f"  [{status}] Q{qid} rag     ({latency*1000:.0f}ms): {answer[:60]}")
            except Exception as e:
                rag_errors += 1
                rag_correct.append(False)
                if verbose:
                    print(f"  [!] Q{qid} rag     ERROR: {e}")

    n = len(eval_set)

    direct_accuracy = sum(direct_correct) / n if n > 0 else 0.0
    direct_p95_ms = float(np.percentile(direct_latencies, 95)) * 1000 if direct_latencies else 9999
    direct_error_rate = direct_errors / n if n > 0 else 1.0

    rag_accuracy = sum(rag_correct) / n if n > 0 else 0.0
    rag_p95_ms = float(np.percentile(rag_latencies, 95)) * 1000 if rag_latencies else 9999
    rag_error_rate = rag_errors / n if n > 0 else 1.0

    # Gate decision: ALL thresholds must pass
    direct_pass = (
        direct_accuracy >= ACCURACY_THRESHOLD
        and direct_p95_ms <= LATENCY_P95_MS
        and direct_error_rate <= ERROR_RATE_MAX
    )
    rag_pass = rag_accuracy >= ACCURACY_THRESHOLD

    decision = "PROMOTE" if (direct_pass and rag_pass) else "ROLLBACK"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "decision": decision,
        "thresholds": {
            "accuracy_min": ACCURACY_THRESHOLD,
            "p95_latency_max_ms": LATENCY_P95_MS,
            "error_rate_max": ERROR_RATE_MAX,
        },
        "direct_path": {
            "accuracy": round(direct_accuracy, 4),
            "p95_latency_ms": round(direct_p95_ms, 1),
            "error_rate": round(direct_error_rate, 4),
            "questions_total": n,
            "questions_correct": sum(direct_correct),
            "pass": direct_pass,
        },
        "rag_path": {
            "accuracy": round(rag_accuracy, 4),
            "p95_latency_ms": round(rag_p95_ms, 1),
            "error_rate": round(rag_error_rate, 4),
            "questions_total": n,
            "questions_correct": sum(rag_correct),
            "pass": rag_pass,
        },
        "overall_pass": decision == "PROMOTE",
    }


def main():
    parser = argparse.ArgumentParser(description="Meridian model evaluation gate")
    parser.add_argument("--gateway-url", default="http://localhost:8000")
    parser.add_argument("--rag-url", default="http://localhost:8080")
    parser.add_argument("--eval-set", default="eval/eval_set.jsonl")
    parser.add_argument("--output", default=None, help="Path to save evidence JSON")
    parser.add_argument("--version", default="unknown", help="Model version being evaluated")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    eval_set = load_eval_set(args.eval_set)
    print(f"\n==> Evaluating model version: {args.version}")
    print(f"    Gateway: {args.gateway_url}")
    print(f"    RAG API: {args.rag_url}")
    print(f"    Eval set: {len(eval_set)} questions\n")

    evidence = evaluate(
        gateway_url=args.gateway_url,
        rag_url=args.rag_url,
        eval_set=eval_set,
        verbose=not args.quiet,
    )
    evidence["version"] = args.version

    # Print summary
    print("\n" + "=" * 60)
    print(f"  DECISION: {evidence['decision']}")
    print("=" * 60)
    print(f"  Direct path accuracy : {evidence['direct_path']['accuracy']*100:.1f}% (need ≥90%)")
    print(f"  Direct path p95      : {evidence['direct_path']['p95_latency_ms']:.0f}ms (need ≤1200ms)")
    print(f"  RAG path accuracy    : {evidence['rag_path']['accuracy']*100:.1f}% (need ≥90%)")
    print("=" * 60 + "\n")

    # Save evidence
    if args.output:
        out_path = Path(args.output)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(evidence, indent=2))
        print(f"Evidence saved to: {args.output}")

    # Exit code: 0=PROMOTE, 1=ROLLBACK
    sys.exit(0 if evidence["decision"] == "PROMOTE" else 1)


if __name__ == "__main__":
    main()
