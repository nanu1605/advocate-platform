"""Kruti Dev to Unicode (spec §12.11, F28): the converter's own vectors are in packages/shared/tests."""

from .conftest import auth


async def test_converts_kruti_dev_text(api, tokens):
    legacy = (
        "U;k;ky; us vkns'k fn;k fd vkosnd dks tekur ij fjgk fd;k tk,A izdj.k vkxkeh fnukad 20&11&2026 dks is'k gksA"
    )
    r = await api.post("/v1/text/krutidev-to-unicode", json={"text": legacy}, headers=auth(tokens["c"]))
    assert r.status_code == 200, r.text
    assert r.json() == {
        "text": "न्यायालय ने आदेश दिया कि आवेदक को जमानत पर रिहा किया जाए। प्रकरण आगामी दिनांक 20-11-2026 को पेश हो।",
        "detected": True,
    }

    r = await api.post("/v1/text/krutidev-to-unicode", json={"text": "“kjr", "devlys": True}, headers=auth(tokens["c"]))
    assert r.json() == {"text": "भारत", "detected": False}  # too short to tell, but converted as asked


async def test_needs_sign_in_and_bounded_text(api, tokens):
    assert (await api.post("/v1/text/krutidev-to-unicode", json={"text": "dk"})).status_code == 401
    h = auth(tokens["c"])
    assert (await api.post("/v1/text/krutidev-to-unicode", json={"text": ""}, headers=h)).status_code == 422
    r = await api.post("/v1/text/krutidev-to-unicode", json={"text": "k" * 20_001}, headers=h)
    assert r.status_code == 422
