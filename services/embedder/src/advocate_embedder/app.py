"""The embedder (spec §12.4; stack: services/embedder): BGE-M3 dense vectors and bge-reranker-v2-m3 scores over HTTP,
on CPU. The API sends it questions and the workers case-file chunks, inside the private network. It keeps nothing
and logs no text.

    uvicorn --factory advocate_embedder.app:app       the real models (the `models` extra)
    create_app(FakeModels())                           tests, and CI, which never downloads a model"""

from typing import Annotated, Protocol

from fastapi import FastAPI
from pydantic import BaseModel, Field

DIM = 1024  # BGE-M3 dense; document_chunks.embedding is vector(1024)
Text = Annotated[str, Field(min_length=1, max_length=8000)]  # a chunk is ~400 tokens; this bounds a bad request


class Models(Protocol):
    def embed(self, texts: list[str]) -> list[list[float]]:
        """Unit-length vectors of DIM floats, one per text."""
        ...

    def rerank(self, query: str, passages: list[str]) -> list[float]:
        """A relevance score per passage; higher is more relevant."""
        ...


class EmbedIn(BaseModel):
    texts: list[Text] = Field(min_length=1, max_length=64)


class EmbedOut(BaseModel):
    vectors: list[list[float]]


class RerankIn(BaseModel):
    query: Annotated[str, Field(min_length=1, max_length=2000)]
    passages: list[Text] = Field(min_length=1, max_length=64)


class RerankOut(BaseModel):
    scores: list[float]


def create_app(models: Models) -> FastAPI:
    api = FastAPI(title="advocate_embedder", version="0.0.0")

    # Plain functions: FastAPI runs them in its thread pool, and the models serialise themselves.
    @api.post("/embed")
    def embed(body: EmbedIn) -> EmbedOut:
        return EmbedOut(vectors=models.embed(body.texts))

    @api.post("/rerank")
    def rerank(body: RerankIn) -> RerankOut:
        return RerankOut(scores=models.rerank(body.query, body.passages))

    @api.get("/healthz", include_in_schema=False)
    def healthz() -> dict:
        return {"ok": True}

    return api


def app() -> FastAPI:
    from advocate_embedder.models import BgeModels  # torch: only in the embedder image

    return create_app(BgeModels())
