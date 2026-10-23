from pathlib import Path

import pytest
import yaml

from advocate_shared.search_key import search_key

FIXTURE = yaml.safe_load((Path(__file__).parents[3] / "config/fixtures/translit_pairs.yaml").read_text("utf-8"))


def test_fixture_has_50_pairs():
    assert len(FIXTURE["pairs"]) == 50


@pytest.mark.parametrize("pair", FIXTURE["pairs"], ids=lambda p: p["en"][0])
def test_hindi_and_english_share_a_key(pair):
    spellings = [pair["hi"], *pair["en"]]
    assert {s: search_key(s) for s in spellings} == dict.fromkeys(spellings, pair["key"])


@pytest.mark.parametrize("case", FIXTURE["other"], ids=lambda c: c["key"] or "empty")
def test_other_inputs(case):
    assert search_key(case["text"]) == case["key"]
