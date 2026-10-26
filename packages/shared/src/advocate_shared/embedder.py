"""The embedder service's client (services/embedder): BGE-M3 vectors and reranker scores. Without EMBEDDER_URL there
is none, and search falls back to full text alone (spec §12.4: hybrid when the embedder is there)."""

import httpx

from advocate_shared.settings import get_settings

TIMEOUT_S = 120  # a batch of chunks on CPU


class Embedder:
    def __init__(self, url: str, transport: httpx.AsyncBaseTransport | None = None):
        self.url, self.transport = url.rstrip("/"), transport

    async def _post(self, path: str, body: dict) -> dict:
        async with httpx.AsyncClient(base_url=self.url, transport=self.transport, timeout=TIMEOUT_S) as c:
            r = await c.post(path, json=body)
            r.raise_for_status()
            return r.json()

    async def embed(self, texts: list[str]) -> list[list[float]]:
        """Unit-length 1024-d vectors. Raises httpx.HTTPError when the service is down or refuses."""
        return (await self._post("/embed", {"texts": texts}))["vectors"]

    async def rerank(self, query: str, passages: list[str]) -> list[float]:
        return (await self._post("/rerank", {"query": query, "passages": passages}))["scores"]


def configured() -> Embedder | None:
    """The embedder this deployment uses, or None. Tests replace it."""
    url = get_settings().embedder_url
    return Embedder(url) if url else None


def vector(v: list[float]) -> str:
    """A vector as pgvector's text form, for `cast(:v as extensions.vector)`."""
    return "[" + ",".join(f"{x:.7f}" for x in v) + "]"
