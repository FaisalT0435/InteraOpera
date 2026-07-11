"""meridian inference gateway.

Fronts the model server: single entrypoint for client traffic, request
accounting, and Prometheus metrics. Written by the application team; you
own running it in production.
"""

import os
import time
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Histogram,
    generate_latest,
)

MODEL_SERVER_URL = os.environ.get("MODEL_SERVER_URL", "http://localhost:8001")

# ── Fix: module-level shared async client with connection pool ────────────────
# Initialize it inside the FastAPI lifespan so it attaches to the correct
# async event loop created by uvicorn.
_http_client = None

@asynccontextmanager
async def lifespan(app: FastAPI):
    global _http_client
    _http_client = httpx.AsyncClient(
        limits=httpx.Limits(
            max_keepalive_connections=20,
            max_connections=100,
            keepalive_expiry=30,
        ),
        timeout=httpx.Timeout(30.0),
    )
    yield
    await _http_client.aclose()

app = FastAPI(title="meridian inference gateway", lifespan=lifespan)

REQUESTS = Counter(
    "gateway_requests_total", "Requests handled by the gateway", ["route", "status"]
)
LATENCY = Histogram(
    "gateway_request_duration_seconds",
    "Gateway request latency",
    ["route"],
    buckets=[0.1, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0],
)


@app.get("/healthz")
async def healthz():
    try:
        upstream = await _http_client.get(f"{MODEL_SERVER_URL}/healthz")
        upstream_ok = upstream.status_code == 200
    except httpx.RequestError:
        upstream_ok = False
    status = 200 if upstream_ok else 503
    return JSONResponse(
        {"status": "ok" if upstream_ok else "degraded", "model_server": upstream_ok},
        status_code=status,
    )


@app.get("/metrics")
async def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    payload = await request.json()
    started = time.perf_counter()
    status = "200"
    try:
        upstream = await _http_client.post(
            f"{MODEL_SERVER_URL}/v1/chat/completions", json=payload
        )
        status = str(upstream.status_code)
        return JSONResponse(upstream.json(), status_code=upstream.status_code)
    except httpx.RequestError as exc:
        status = "502"
        return JSONResponse(
            {"error": {"message": f"model server unreachable: {exc}", "type": "bad_gateway"}},
            status_code=502,
        )
    finally:
        REQUESTS.labels(route="/v1/chat/completions", status=status).inc()
        LATENCY.labels(route="/v1/chat/completions").observe(
            time.perf_counter() - started
        )
