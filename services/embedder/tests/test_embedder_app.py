"""The embedder's HTTP contract, with the fake models (the real ones only run in the embedder image)."""

import math

import pytest
from httpx import ASGITransport, AsyncClient

from advocate_embedder.app import DIM, create_app
from advocate_embedder.fake import FakeModels


@pytest.fixture
async def client():
    async with AsyncClient(transport=ASGITransport(app=create_app(FakeModels())), base_url="http://embedder") as c:
        yield c


async def test_embeds_unit_vectors(client):
    r = await client.post("/embed", json={"texts": ["Reply within four weeks", "जमानत आवेदन"]})
    assert r.status_code == 200
    vectors = r.json()["vectors"]
    assert [len(v) for v in vectors] == [DIM, DIM]
    assert all(math.isclose(sum(x * x for x in v), 1.0) for v in vectors)


async def test_reranks_by_relevance(client):
    r = await client.post(
        "/rerank",
        json={"query": "bail application", "passages": ["The bail application is allowed.", "Reply in four weeks."]},
    )
    scores = r.json()["scores"]
    assert scores[0] > scores[1]


async def test_bounds_requests(client):
    assert (await client.post("/embed", json={"texts": []})).status_code == 422
    assert (await client.post("/embed", json={"texts": ["x"] * 65})).status_code == 422
    assert (await client.post("/embed", json={"texts": ["x" * 8001]})).status_code == 422
    assert (await client.post("/rerank", json={"query": "", "passages": ["x"]})).status_code == 422
