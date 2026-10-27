"""Pages rebuilt from chunks, page ids and proposal keys (ADR 0023): the parts of order_ai that need no database."""

from datetime import date

from advocate_shared.order_ai import dedupe_key, join_pages, source_pages
from legal_ai.contracts import Action
from legal_ai.prompts import Source


def test_chunks_are_laid_onto_their_page_by_the_overlap():
    page = "1. Heard counsel. The respondents shall file a reply within four weeks. List on 12.11.2026."
    chunks = [(1, page[:40]), (1, page[27:70]), (1, page[58:]), (3, "Page three.")]  # chunk ends repeat
    assert join_pages(chunks) == [Source("order", page, page=1), Source("order", "Page three.", page=3)]


def test_a_blank_page_keeps_the_page_numbers_and_ids_map_to_them():
    sources = join_pages([(1, "One"), (3, "Three")])  # page 2 had no text
    assert source_pages(sources) == {"S1": 1, "S2": 3}


def test_a_proposal_key_ignores_case_and_spacing_but_not_the_date():
    action = Action(kind="deadline", title="Respondents to  file reply", due=None, sources=["S1"])
    same = Action(kind="deadline", title=" respondents to file Reply ", due=None, sources=["S2"])
    key = dedupe_key("c1", action, date(2026, 11, 17))
    assert key.startswith("order:c1:") and len(key) == len("order:c1:") + 12
    assert dedupe_key("c1", same, date(2026, 11, 17)) == key
    assert dedupe_key("c1", action, date(2026, 11, 18)) != key
    assert dedupe_key("c2", action, date(2026, 11, 17)) != key
