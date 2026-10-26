"""Stand-in models for tests and CI (no download, no torch): texts sharing words get close vectors, and a passage
scores by the share of the query's words it holds. Deterministic, so search results can be asserted."""

import hashlib
import math
import re

from advocate_embedder.app import DIM

_PUNCT = re.compile(r"^[^\w]+|[^\w]+$")


def words(text: str) -> list[str]:
    return [w for w in (_PUNCT.sub("", t.lower()) for t in text.split()) if w]


class FakeModels:
    def embed(self, texts: list[str]) -> list[list[float]]:
        out = []
        for t in texts:
            v = [0.0] * DIM
            for w in words(t):
                h = int.from_bytes(hashlib.sha256(w.encode()).digest()[:8])
                v[h % DIM] += 1.0 if h & 1 << 63 else -1.0
            norm = math.sqrt(sum(x * x for x in v)) or 1.0
            out.append([x / norm for x in v])
        return out

    def rerank(self, query: str, passages: list[str]) -> list[float]:
        q = set(words(query))
        return [len(q & set(words(p))) / (len(q) or 1) for p in passages]
