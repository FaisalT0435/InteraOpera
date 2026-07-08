"""meridian-slm — mock inference server.

Simulates a self-hosted small LLM behind an OpenAI-compatible API.
Treat this process as if it were vLLM serving a fine-tuned model on a GPU
node: it has a model version, realistic latency behaviour, and exposes
Prometheus metrics including simulated GPU/KV-cache gauges.

Two answering modes (see the starter README for the exact protocol):
- direct: the prompt is a bare question; the model answers from its
  fine-tuned knowledge.
- grounded (RAG): the prompt contains a "Context:" block; the model answers
  ONLY from that context and refuses when the answer is not present.

Do NOT modify the answer or latency logic — the platform work around this
service is the assignment. Adding instrumentation is fine.
"""

import asyncio
import json
import os
import random
import time
import uuid
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

MODEL_VERSION = os.environ.get("MODEL_VERSION", "1.0")
MODEL_NAME = f"meridian-slm:{MODEL_VERSION}"

# Per-token generation delay. 1.1 is the quantized build (faster).
PER_TOKEN_DELAY = {"1.0": 0.030, "1.1": 0.018, "2.0": 0.030}.get(MODEL_VERSION, 0.030)
BASE_DELAY = 0.12

# Grounded (RAG) mode: a prompt containing this marker is answered ONLY from
# the context that follows it. See the starter README for the protocol.
GROUNDED_MARKER = "Context:"
MAX_CONTEXT_CHARS = 4000
REFUSAL = "I cannot find the answer to this question in the provided context."

ANSWERS = json.loads((Path(__file__).parent / "answers.json").read_text())
BY_PROMPT = {a["prompt"].strip().lower(): a for a in ANSWERS}


def _normalize(text: str) -> str:
    return " ".join(text.split())

app = FastAPI(title="meridian-slm mock inference server")

REQUESTS = Counter(
    "model_requests_total", "Completion requests served", ["status"]
)
LATENCY = Histogram(
    "model_request_duration_seconds",
    "Completion request latency",
    buckets=[0.1, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0],
)
TOKENS = Counter("model_tokens_generated_total", "Completion tokens generated")
IN_FLIGHT = Gauge("model_requests_in_flight", "Requests currently being served")
GPU_UTIL = Gauge(
    "model_gpu_utilization_ratio", "Simulated GPU utilization (0.0-1.0)"
)
KV_CACHE = Gauge(
    "model_kv_cache_usage_ratio", "Simulated KV-cache usage (0.0-1.0)"
)
QUEUE_DEPTH = Gauge("model_queue_depth", "Simulated scheduler queue depth")

_inflight = 0
_fault = {"mode": "off", "rate": 0.0, "ms": 0}


def _update_simulated_gauges() -> None:
    GPU_UTIL.set(min(1.0, 0.07 + _inflight * 0.11))
    KV_CACHE.set(min(1.0, 0.12 + _inflight * 0.08))
    QUEUE_DEPTH.set(max(0, _inflight - 4))


_update_simulated_gauges()


@app.get("/healthz")
async def healthz():
    return {"status": "ok", "model": MODEL_NAME}


@app.get("/version")
async def version():
    return {"model": "meridian-slm", "version": MODEL_VERSION}


@app.get("/metrics")
async def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/admin/fault")
async def set_fault(request: Request):
    """Fault injection for testing alerting. Modes:
    {"mode": "error", "rate": 0.3}    -> fail that fraction of requests with 500
    {"mode": "latency", "ms": 3000}   -> add fixed latency to every request
    {"mode": "off"}                    -> clear
    """
    body = await request.json()
    mode = body.get("mode", "off")
    if mode not in ("error", "latency", "off"):
        return JSONResponse({"error": f"unknown mode: {mode}"}, status_code=400)
    _fault["mode"] = mode
    _fault["rate"] = float(body.get("rate", 0.0))
    _fault["ms"] = int(body.get("ms", 0))
    return {"fault": dict(_fault)}


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    global _inflight
    payload = await request.json()
    messages = payload.get("messages", [])
    prompt = ""
    for message in reversed(messages):
        if message.get("role") == "user":
            prompt = str(message.get("content", ""))
            break

    _inflight += 1
    _update_simulated_gauges()
    started = time.perf_counter()
    status = "200"
    try:
        if _fault["mode"] == "error" and random.random() < _fault["rate"]:
            status = "500"
            return JSONResponse(
                {"error": {"message": "simulated inference fault", "type": "server_error"}},
                status_code=500,
            )

        grounded = GROUNDED_MARKER in prompt
        if grounded:
            question_part, _, context_part = prompt.partition(GROUNDED_MARKER)
            question = question_part.strip()
            if question.lower().startswith("question:"):
                question = question[len("question:"):].strip()
            context = _normalize(context_part)
            if len(context) > MAX_CONTEXT_CHARS:
                status = "400"
                return JSONResponse(
                    {
                        "error": {
                            "message": f"context length exceeded: grounded requests accept at most {MAX_CONTEXT_CHARS} characters of context",
                            "type": "context_length_exceeded",
                        }
                    },
                    status_code=400,
                )
            entry = BY_PROMPT.get(question.lower())
        else:
            context = ""
            entry = BY_PROMPT.get(prompt.strip().lower())

        extra_delay = 0.0
        if entry is not None and MODEL_VERSION == "2.0" and entry["id"] % 3 == 0:
            # The 2.0 fine-tune regressed on part of the domain: it produces a
            # confident wrong answer after a long "reasoning" stall — and in
            # grounded mode it ignores the provided context (a faithfulness
            # regression).
            answer = entry["wrong"]
            extra_delay = 2.5
        elif grounded:
            if entry is not None and _normalize(entry["answer"]) in context:
                answer = entry["answer"]
            else:
                answer = REFUSAL
        elif entry is not None:
            answer = entry["answer"]
        else:
            answer = "I don't have that information in the Meridian knowledge base."

        completion_tokens = len(answer.split())
        delay = BASE_DELAY + completion_tokens * PER_TOKEN_DELAY + extra_delay
        if _fault["mode"] == "latency":
            delay += _fault["ms"] / 1000.0
        await asyncio.sleep(delay)

        TOKENS.inc(completion_tokens)
        prompt_tokens = len(prompt.split())
        return {
            "id": f"chatcmpl-{uuid.uuid4().hex[:24]}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": MODEL_NAME,
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": answer},
                    "finish_reason": "stop",
                }
            ],
            "usage": {
                "prompt_tokens": prompt_tokens,
                "completion_tokens": completion_tokens,
                "total_tokens": prompt_tokens + completion_tokens,
            },
        }
    finally:
        _inflight -= 1
        _update_simulated_gauges()
        REQUESTS.labels(status=status).inc()
        LATENCY.observe(time.perf_counter() - started)
