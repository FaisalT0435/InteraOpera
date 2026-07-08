"""Simple async load generator for the Meridian inference stack.

Usage:
    python loadgen.py --url http://localhost:8000 --concurrency 8 --duration 30
    python loadgen.py --url http://localhost:8000 --concurrency 8 --duration 30 \
        --prompts ../eval/eval_set.jsonl

Sends chat-completion requests at the given concurrency and prints latency
percentiles, throughput, and error rate.
"""

import argparse
import asyncio
import json
import statistics
import time
from pathlib import Path

import httpx

DEFAULT_PROMPT = "What is the base currency of the Meridian Fixed Income Fund?"


def load_prompts(path: str | None) -> list[str]:
    if not path:
        return [DEFAULT_PROMPT]
    prompts = []
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line:
            prompts.append(json.loads(line)["prompt"])
    return prompts or [DEFAULT_PROMPT]


async def worker(
    client: httpx.AsyncClient,
    url: str,
    prompts: list[str],
    deadline: float,
    latencies: list[float],
    errors: list[str],
    counter: list[int],
) -> None:
    while time.perf_counter() < deadline:
        prompt = prompts[counter[0] % len(prompts)]
        counter[0] += 1
        body = {
            "model": "meridian-slm",
            "messages": [{"role": "user", "content": prompt}],
        }
        started = time.perf_counter()
        try:
            response = await client.post(
                f"{url}/v1/chat/completions", json=body, timeout=60.0
            )
            elapsed = time.perf_counter() - started
            if response.status_code == 200:
                latencies.append(elapsed)
            else:
                errors.append(f"HTTP {response.status_code}")
        except httpx.HTTPError as exc:
            errors.append(type(exc).__name__)


def percentile(sorted_values: list[float], pct: float) -> float:
    if not sorted_values:
        return 0.0
    index = min(len(sorted_values) - 1, int(len(sorted_values) * pct))
    return sorted_values[index]


async def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://localhost:8000")
    parser.add_argument("--concurrency", type=int, default=8)
    parser.add_argument("--duration", type=int, default=30, help="seconds")
    parser.add_argument("--prompts", default=None, help="path to eval_set.jsonl")
    args = parser.parse_args()

    prompts = load_prompts(args.prompts)
    latencies: list[float] = []
    errors: list[str] = []
    counter = [0]
    deadline = time.perf_counter() + args.duration

    started = time.perf_counter()
    async with httpx.AsyncClient() as client:
        await asyncio.gather(
            *[
                worker(client, args.url, prompts, deadline, latencies, errors, counter)
                for _ in range(args.concurrency)
            ]
        )
    wall = time.perf_counter() - started

    total = len(latencies) + len(errors)
    ordered = sorted(latencies)
    print(f"target          {args.url}")
    print(f"concurrency     {args.concurrency}")
    print(f"duration        {wall:.1f}s")
    print(f"requests        {total} ({len(errors)} errors, "
          f"{(len(errors) / total * 100 if total else 0):.1f}%)")
    print(f"throughput      {total / wall:.2f} req/s")
    if ordered:
        print(f"latency p50     {statistics.median(ordered) * 1000:.0f} ms")
        print(f"latency p95     {percentile(ordered, 0.95) * 1000:.0f} ms")
        print(f"latency p99     {percentile(ordered, 0.99) * 1000:.0f} ms")
        print(f"latency max     {ordered[-1] * 1000:.0f} ms")


if __name__ == "__main__":
    asyncio.run(main())
