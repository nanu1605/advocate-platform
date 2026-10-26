import json
from pathlib import Path

import pytest

from advocate_shared.krutidev import convert, looks_like_krutidev

FIXTURE = json.loads((Path(__file__).parents[3] / "config/fixtures/krutidev.json").read_text("utf-8"))


def test_fixture_has_100_vectors():
    assert len(FIXTURE["vectors"]) == 100


@pytest.mark.parametrize("v", FIXTURE["vectors"], ids=lambda v: v["unicode"])
def test_kruti_dev_converts(v):
    assert convert(v["legacy"]) == v["unicode"], v["rule"]


@pytest.mark.parametrize("v", FIXTURE["devlys"], ids=lambda v: v["unicode"])
def test_devlys_reads_its_own_quote_slots(v):
    assert convert(v["legacy"], devlys=True) == v["unicode"]
    assert convert(v["legacy"]) != v["unicode"]


@pytest.mark.parametrize("text", FIXTURE["detect"]["legacy"])
def test_detects_kruti_dev_text(text):
    assert looks_like_krutidev(text)


@pytest.mark.parametrize("text", FIXTURE["detect"]["other"])
def test_leaves_other_text_alone(text):
    assert not looks_like_krutidev(text)


def test_unicode_text_passes_through():
    assert convert("न्यायालय 302") == "न्यायालय 302"
