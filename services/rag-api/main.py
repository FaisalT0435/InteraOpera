"""
Meridian RAG Chat Service.
Ingests corpus into Qdrant, retrieves relevant passages, and grounds
answers via the meridian-slm model server.
"""

import logging
import os
import time

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from pydantic import BaseModel

from ingestion import run_ingestion
from retriever import retrieve

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

MODEL_SERVER_URL = os.environ.get("MODEL_SERVER_URL", "http://localhost:8001")
QDRANT_URL = os.environ.get("QDRANT_URL", "http://localhost:6333")
AUTO_INGEST = os.environ.get("AUTO_INGEST", "true").lower() == "true"

# Grounded prompt format as per starter README
GROUNDED_MARKER = "Context:"
MAX_CONTEXT_CHARS = 3800  # safe margin below 4000
REFUSAL_PHRASE = "I cannot find the answer to this question in the provided context."

app = FastAPI(title="Meridian RAG Chat Service")

# ── Prometheus metrics ────────────────────────────────────────────────────────
RAG_REQUESTS = Counter("rag_requests_total", "RAG chat requests", ["status"])
RAG_LATENCY = Histogram(
    "rag_request_duration_seconds",
    "RAG request latency",
    buckets=[0.1, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0],
)
RETRIEVAL_LATENCY = Histogram(
    "rag_retrieval_duration_seconds",
    "Vector store retrieval latency",
    buckets=[0.01, 0.05, 0.1, 0.25, 0.5, 1.0],
)
CONTEXT_TOKENS = Histogram(
    "rag_context_chars",
    "Characters in assembled context per request",
    buckets=[100, 300, 600, 1000, 2000, 3000, 4000],
)

# ── Shared async HTTP client (connection pooling) ─────────────────────────────
http_client = httpx.AsyncClient(
    limits=httpx.Limits(max_keepalive_connections=20, max_connections=100),
    timeout=httpx.Timeout(30.0),
)


# ── Schemas ───────────────────────────────────────────────────────────────────
class ChatRequest(BaseModel):
    question: str


class Citation(BaseModel):
    source: str
    passage: str


class ChatResponse(BaseModel):
    answer: str
    citations: list[Citation]


# ── Startup ───────────────────────────────────────────────────────────────────
@app.on_event("startup")
async def startup():
    if AUTO_INGEST:
        logger.info("AUTO_INGEST=true — running corpus ingestion on startup...")
        try:
            run_ingestion(qdrant_url=QDRANT_URL)
            logger.info("Ingestion complete.")
        except Exception as e:
            logger.warning(f"Ingestion failed (will retry on /v1/rag/ingest): {e}")


# ── Endpoints ─────────────────────────────────────────────────────────────────
@app.get("/health")
async def health():
    return {"status": "ok", "service": "rag-api"}


@app.get("/metrics")
async def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/v1/rag/ingest")
async def ingest():
    """Trigger corpus re-ingestion into Qdrant."""
    try:
        run_ingestion(qdrant_url=QDRANT_URL)
        return {"status": "ok", "message": "Ingestion complete"}
    except Exception as e:
        logger.error(f"Ingestion error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/v1/rag/chat", response_model=ChatResponse)
async def rag_chat(req: ChatRequest):
    started = time.perf_counter()
    status = "200"

    try:
        question = req.question.strip()
        if not question:
            raise HTTPException(status_code=400, detail="question must not be empty")

        # ── Step 1: Retrieve relevant passages ────────────────────────────────
        t0 = time.perf_counter()
        passages = retrieve(question, qdrant_url=QDRANT_URL, top_k=8)
        RETRIEVAL_LATENCY.observe(time.perf_counter() - t0)

        if not passages:
            # No passages found — surface refusal
            RAG_REQUESTS.labels(status="200").inc()
            return ChatResponse(answer=REFUSAL_PHRASE, citations=[])

        # ── Step 2: Assemble grounded prompt ─────────────────────────────────
        context_parts = [p["text"] for p in passages]
        context_text = "\n---\n".join(context_parts)

        # Trim to max context window
        if len(context_text) > MAX_CONTEXT_CHARS:
            context_text = context_text[:MAX_CONTEXT_CHARS]

        CONTEXT_TOKENS.observe(len(context_text))

        # Grounded prompt format per starter README
        grounded_prompt = f"{question}\n\n{GROUNDED_MARKER}\n{context_text}"

        # ── Step 3: Call model server ─────────────────────────────────────────
        payload = {
            "model": "meridian-slm",
            "messages": [{"role": "user", "content": grounded_prompt}],
        }
        resp = await http_client.post(
            f"{MODEL_SERVER_URL}/v1/chat/completions", json=payload
        )

        if resp.status_code != 200:
            status = str(resp.status_code)
            raise HTTPException(
                status_code=502,
                detail=f"Model server returned {resp.status_code}: {resp.text}",
            )

        data = resp.json()
        answer = data["choices"][0]["message"]["content"]

        # ── Step 4: Handle refusal ────────────────────────────────────────────
        is_refusal = REFUSAL_PHRASE.lower() in answer.lower()
        citations = (
            []
            if is_refusal
            else [Citation(source=p["source"], passage=p["text"]) for p in passages]
        )

        return ChatResponse(answer=answer, citations=citations)

    except HTTPException:
        status = "4xx"
        raise
    except Exception as e:
        status = "500"
        logger.error(f"RAG chat error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        RAG_REQUESTS.labels(status=status).inc()
        RAG_LATENCY.observe(time.perf_counter() - started)
