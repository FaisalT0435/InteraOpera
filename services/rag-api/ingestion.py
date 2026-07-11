"""
Corpus ingestion pipeline.
Uses fastembed (ONNX-based, ~100MB) instead of PyTorch sentence-transformers
to keep the Docker image lean while maintaining retrieval quality.
"""

import logging
import os
from pathlib import Path

from fastembed import TextEmbedding
from qdrant_client import QdrantClient
from qdrant_client.models import Distance, PointStruct, VectorParams

logger = logging.getLogger(__name__)

CORPUS_DIR = Path(os.environ.get("CORPUS_DIR", "/corpus"))
COLLECTION_NAME = "meridian-corpus"

# all-MiniLM-L6-v2 via fastembed — same model, ONNX runtime (~60MB vs ~1.5GB PyTorch)
EMBEDDING_MODEL = "sentence-transformers/all-MiniLM-L6-v2"
VECTOR_SIZE = 384

# Chunking parameters
CHUNK_SIZE = 512
CHUNK_OVERLAP = 64

_embedder: TextEmbedding | None = None


def _get_embedder() -> TextEmbedding:
    global _embedder
    if _embedder is None:
        logger.info(f"Loading embedding model via fastembed: {EMBEDDING_MODEL}")
        _embedder = TextEmbedding(model_name=EMBEDDING_MODEL)
    return _embedder


def _chunk_text(text: str, chunk_size: int = CHUNK_SIZE, overlap: int = CHUNK_OVERLAP) -> list[str]:
    chunks = []
    start = 0
    while start < len(text):
        chunk = text[start : start + chunk_size].strip()
        if chunk:
            chunks.append(chunk)
        start += chunk_size - overlap
    return chunks


def _load_corpus(corpus_dir: Path) -> list[dict]:
    docs = []
    for fpath in sorted(list(corpus_dir.glob("*.md")) + list(corpus_dir.glob("*.txt"))):
        text = fpath.read_text(encoding="utf-8")
        docs.append({"source": fpath.name, "text": text})
        logger.info(f"Loaded: {fpath.name} ({len(text)} chars)")
    return docs


def run_ingestion(qdrant_url: str = "http://localhost:6333") -> int:
    client = QdrantClient(url=qdrant_url)
    embedder = _get_embedder()

    docs = _load_corpus(CORPUS_DIR)
    if not docs:
        raise RuntimeError(f"No corpus files found in {CORPUS_DIR}")

    all_chunks = []
    point_id = 0
    for doc in docs:
        for chunk_idx, chunk_text in enumerate(_chunk_text(doc["text"])):
            all_chunks.append({
                "id": point_id,
                "text": chunk_text,
                "source": doc["source"],
                "chunk_index": chunk_idx,
            })
            point_id += 1

    logger.info(f"Total chunks: {len(all_chunks)}")

    # Embed with fastembed (returns a generator)
    texts = [c["text"] for c in all_chunks]
    embeddings = list(embedder.embed(texts))

    # Recreate collection
    existing = [c.name for c in client.get_collections().collections]
    if COLLECTION_NAME in existing:
        client.delete_collection(COLLECTION_NAME)

    client.create_collection(
        collection_name=COLLECTION_NAME,
        vectors_config=VectorParams(size=VECTOR_SIZE, distance=Distance.COSINE),
    )

    # Upload in batches
    points = [
        PointStruct(
            id=chunk["id"],
            vector=embeddings[i].tolist(),
            payload={
                "text": chunk["text"],
                "source": chunk["source"],
                "chunk_index": chunk["chunk_index"],
            },
        )
        for i, chunk in enumerate(all_chunks)
    ]

    for i in range(0, len(points), 100):
        client.upsert(collection_name=COLLECTION_NAME, points=points[i : i + 100])

    logger.info(f"Ingestion complete: {len(points)} chunks indexed.")
    return len(points)
