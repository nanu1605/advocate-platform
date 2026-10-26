"""The real models, on CPU, loaded from the image (downloaded at build, HF_HUB_OFFLINE at run): BGE-M3 (MIT) for dense
vectors and bge-reranker-v2-m3 (Apache-2.0) for reranking. Needs the `models` extra."""

import threading

from sentence_transformers import CrossEncoder, SentenceTransformer  # pyright: ignore[reportMissingImports] - the models extra

EMBED_MODEL = "BAAI/bge-m3"
RERANK_MODEL = "BAAI/bge-reranker-v2-m3"


class BgeModels:
    def __init__(self) -> None:
        self.encoder = SentenceTransformer(EMBED_MODEL, device="cpu")
        self.reranker = CrossEncoder(RERANK_MODEL, device="cpu", max_length=512)
        # One request at a time: torch already uses every core, and parallel requests only thrash.
        self.lock = threading.Lock()

    def embed(self, texts: list[str]) -> list[list[float]]:
        with self.lock:
            return self.encoder.encode(texts, normalize_embeddings=True, batch_size=16).tolist()

    def rerank(self, query: str, passages: list[str]) -> list[float]:
        with self.lock:
            return self.reranker.predict([(query, p) for p in passages], batch_size=16).tolist()
