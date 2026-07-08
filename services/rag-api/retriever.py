"""
Retrieval layer: embed query and search Qdrant for relevant passages.
"""

import logging
import os

from qdrant_client import QdrantClient
from qdrant_client.models import ScoredPoint
from sentence_transformers import SentenceTransformer

from ingestion import COLLECTION_NAME, EMBEDDING_MODEL, _get_model

logger = logging.getLogger(__name__)

# Minimum cosine similarity score to include a passage
SCORE_THRESHOLD = 0.30


def retrieve(
    question: str,
    qdrant_url: str = "http://localhost:6333",
    top_k: int = 5,
) -> list[dict]:
    """
    Embed the question, search Qdrant for top-k passages above threshold.

    Returns list of dicts: {"text": str, "source": str, "score": float}
    """
    model = _get_model()
    client = QdrantClient(url=qdrant_url)

    # Embed the question
    query_vector = model.encode(question).tolist()

    # Search Qdrant
    results: list[ScoredPoint] = client.search(
        collection_name=COLLECTION_NAME,
        query_vector=query_vector,
        limit=top_k,
        score_threshold=SCORE_THRESHOLD,
    )

    passages = []
    for hit in results:
        passages.append({
            "text": hit.payload["text"],
            "source": hit.payload["source"],
            "chunk_index": hit.payload.get("chunk_index", 0),
            "score": hit.score,
        })

    logger.info(
        f"Retrieved {len(passages)} passages for question: '{question[:60]}...'"
    )
    return passages
