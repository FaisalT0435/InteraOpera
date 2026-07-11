"""
Retriever using fastembed (ONNX) — lightweight alternative to PyTorch.
"""

import logging
import os

from fastembed import TextEmbedding
from qdrant_client import QdrantClient
from qdrant_client.models import ScoredPoint

from ingestion import COLLECTION_NAME, EMBEDDING_MODEL, _get_embedder

logger = logging.getLogger(__name__)

SCORE_THRESHOLD = 0.30


def retrieve(
    question: str,
    qdrant_url: str = "http://localhost:6333",
    top_k: int = 5,
) -> list[dict]:
    embedder = _get_embedder()
    client = QdrantClient(url=qdrant_url)

    # fastembed.embed returns a generator — take first result
    query_vector = list(embedder.embed([question]))[0].tolist()

    results: list[ScoredPoint] = client.search(
        collection_name=COLLECTION_NAME,
        query_vector=query_vector,
        limit=top_k,
        score_threshold=SCORE_THRESHOLD,
    )

    passages = [
        {
            "text": hit.payload["text"],
            "source": hit.payload["source"],
            "chunk_index": hit.payload.get("chunk_index", 0),
            "score": hit.score,
        }
        for hit in results
    ]

    logger.info(f"Retrieved {len(passages)} passages for: '{question[:60]}'")
    return passages
