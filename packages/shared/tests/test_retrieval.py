"""Snippets for search hits (spec §12.4): around the word the search matched on, not a common word before it."""

from advocate_shared.retrieval import snippet

FILLER = "वादी की ओर से साक्षी की गवाही प्रस्तुत की गई। " * 8


def test_a_snippet_centres_on_a_word_the_search_matched():
    s = snippet(FILLER + "आवेदक को जमानत पर रिहा किया जाए।", "सुरेश की जमानत")
    assert "जमानत" in s and s.startswith("…")
    s = snippet(
        "The petitioner Ram Lal, a resident of Jaipur. " * 6 + "Bail granted on a bond.", "bail granted on a bond"
    )
    assert "Bail granted" in s


def test_a_query_of_common_words_alone_still_finds_them():
    assert "की" in snippet("x" * 300 + " अदालत की कार्यवाही", "की")
