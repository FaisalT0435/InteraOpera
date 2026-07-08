"""
Corpus ingestion pipeline.
Loads markdown documents from corpus/, chunks them, embeds with a local
sentence-transformers model, and uploads to Qdrant.
"""

import logging
import os
from pathlib import Path

from qdrant_client import QdrantClient
from qdrant_client.models import Distance, PointStruct, VectorParams
from sentence_transformers import SentenceTransformer

logger = logging.getLogger(__name__)

CORPUS_DIR = Path(os.environ.get("CORPUS_DIR", "/corpus"))
COLLECTION_NAME = "meridian-corpus"
EMBEDDING_MODEL = "sentence-transformers/all-MiniLM-L6-v2"
VECTOR_SIZE = 384  # all-MiniLM-L6-v2 output dimension

# Chunking parameters
CHUNK_SIZE = 512      # characters (not tokens — simpler, works well here)
CHUNK_OVERLAP = 64    # characters

_model: SentenceTransformer | None = None


def _get_model() -> SentenceTransformer:
    global _model
    if _model is None:
        logger.info(f"Loading embedding model: {EMBEDDING_MODEL}")
        _model = SentenceTransformer(EMBEDDING_MODEL)
    return _model


def _chunk_text(text: str, chunk_size: int = CHUNK_SIZE, overlap: int = CHUNK_OVERLAP) -> list[str]:
    """Split text into overlapping chunks."""
    chunks = []
    start = 0
    while start < len(text):
        end = start + chunk_size
        chunk = text[start:end].strip()
        if chunk:
            chunks.append(chunk)
        start += chunk_size - overlap
    return chunks


def _load_corpus(corpus_dir: Path) -> list[dict]:
    """Load all .md and .txt files from corpus directory."""
    docs = []
    for fpath in sorted(corpus_dir.glob("*.md")) + sorted(corpus_dir.glob("*.txt")):
        text = fpath.read_text(encoding="utf-8")
        docs.append({"source": fpath.name, "text": text})
        logger.info(f"Loaded corpus file: {fpath.name} ({len(text)} chars)")
    return docs


def run_ingestion(qdrant_url: str = "http://localhost:6333") -> int:
    """
    Full ingestion pipeline:
    1. Load corpus files
    2. Chunk each document
    3. Embed chunks with local model
    4. Upload to Qdrant (recreate collection for idempotency)

    Returns number of chunks indexed.
    """
    client = QdrantClient(url=qdrant_url)
    model = _get_model()

    # Load documents
    docs = _load_corpus(CORPUS_DIR)
    if not docs:
        raise RuntimeError(f"No corpus files found in {CORPUS_DIR}")

    # Build chunks with metadata
    all_chunks = []
    point_id = 0
    for doc in docs:
        chunks = _chunk_text(doc["text"])
        for chunk_idx, chunk_text in enumerate(chunks):
            all_chunks.append({
                "id": point_id,
                "text": chunk_text,
                "source": doc["source"],
                "chunk_index": chunk_idx,
            })
            point_id += 1

    logger.info(f"Total chunks to index: {len(all_chunks)}")

    # Embed all chunks
    texts = [c["text"] for c in all_chunks]
    logger.info("Embedding chunks...")
    embeddings = model.encode(texts, batch_size=32, show_progress_bar=False)

    # Recreate collection (idempotent re-ingestion)
    existing = [c.name for c in client.get_collections().collections]
    if COLLECTION_NAME in existing:
        logger.info(f"Dropping existing collection: {COLLECTION_NAME}")
        client.delete_collection(COLLECTION_NAME)

    client.create_collection(
        collection_name=COLLECTION_NAME,
        vectors_config=VectorParams(size=VECTOR_SIZE, distance=Distance.COSINE),
    )
    logger.info(f"Created collection: {COLLECTION_NAME}")

    # Upload points in batches
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

    BATCH_SIZE = 100
    for i in range(0, len(points), BATCH_SIZE):
        batch = points[i : i + BATCH_SIZE]
        client.upsert(collection_name=COLLECTION_NAME, points=batch)

    logger.info(f"Ingestion complete: {len(points)} chunks indexed into '{COLLECTION_NAME}'")
    return len(points)
