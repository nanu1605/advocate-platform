"""Reading a document's pages and cutting them into chunks (spec §12.4, F15, F28); no database."""

import io
import itertools
import math
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest
from pdfs import make_docx, make_pdf
from structlog.testing import capture_logs

from advocate_shared.retrieval import fold
from advocate_workers import doctext

ENGLISH = ["IN THE HIGH COURT OF MADHYA PRADESH AT INDORE", "WRIT PETITION No. 1234 of 2024"]
LEGACY = [
    "izdj.k esa ;kfpdkdrkZ dh vksj ls vf/koDrk mifLFkr gSA",
    "U;k;ky; us vkns'k fn;k fd vkosnd dks tekur ij fjgk fd;k tk,A",
]
CAUSE_TITLE = "W.P. No. 1234/2023 Ramesh Kumar versus State of Madhya Pradesh"
KRUTI_DEV = '<w:rPr><w:rFonts w:ascii="Kruti Dev 010" w:hAnsi="Kruti Dev 010"/></w:rPr>'
THEME = '<w:rPr><w:rFonts w:asciiTheme="minorHAnsi" w:hAnsiTheme="minorHAnsi"/></w:rPr>'  # Word's own default


def no_ocr(_: bytes) -> str:
    raise AssertionError("no page here needs OCR")


def test_reads_the_text_layer_and_converts_only_the_kruti_dev_runs():
    pdf = make_pdf([[("Helvetica", ENGLISH), ("KrutiDev010", LEGACY)]])
    r = doctext.read(pdf, "application/pdf", no_ocr)
    assert (len(r.pages), r.ocr_pages, r.legacy_font) == (1, 0, True)
    page = " ".join(r.pages[0].split())
    assert "IN THE HIGH COURT OF MADHYA PRADESH AT INDORE" in page
    assert "प्रकरण में याचिकाकर्ता की ओर से अधिवक्ता उपस्थित है।" in page
    assert "न्यायालय ने आदेश दिया कि आवेदक को जमानत पर रिहा किया जाए।" in page


def test_devlys_uses_its_own_table():
    pdf = make_pdf([[("DevLys010", ["“kjr dk lafo/kku] mPp U;k;ky; ds vkns'k ds vuqlkj dk;Zokgh gksxhA"])]])
    page = doctext.read(pdf, "application/pdf", no_ocr).pages[0]
    assert page.startswith("भारत का संविधान")


def test_unnamed_fonts_are_converted_when_the_page_reads_as_kruti_dev():
    pdf = make_pdf([[("F1", LEGACY)]])
    r = doctext.read(pdf, "application/pdf", no_ocr)
    assert r.legacy_font and "न्यायालय ने आदेश" in r.pages[0]
    english = doctext.read(make_pdf([[("F1", ENGLISH)]]), "application/pdf", no_ocr)
    assert not english.legacy_font and "HIGH COURT" in english.pages[0]


def test_a_scanned_page_goes_to_ocr_as_a_greyscale_image():
    seen: list[bytes] = []

    def ocr(image: bytes) -> str:
        seen.append(image)
        return "आवेदक को ज़मानत पर रिहा किया जाए"

    r = doctext.read(make_pdf([[("Helvetica", ENGLISH * 2)], []]), "application/pdf", ocr)
    assert r.ocr_pages == 1 and r.pages[1] == "आवेदक को ज़मानत पर रिहा किया जाए"
    header, _, pixels = seen[0].partition(b"\n255\n")
    width, height = map(int, header.split()[1:])
    assert header.startswith(b"P5") and len(pixels) == width * height
    assert (width, height) == (math.ceil(595 * 300 / 72), math.ceil(842 * 300 / 72))  # 300 dpi


def test_without_an_ocr_engine_a_scan_waits():
    def none(_: bytes) -> str:
        raise doctext.OcrUnavailable

    with pytest.raises(doctext.OcrUnavailable):
        doctext.read(make_pdf([[]]), "application/pdf", none)


def test_a_page_that_cannot_be_loaded_is_left_empty():
    pdf = make_pdf([[("Helvetica", ENGLISH)]] * 3)
    broken = re.sub(rb"(/Kids \[\d+ 0 R) \d+", rb"\1 99", pdf)  # page 2 is an object that isn't there
    r = doctext.read(broken, "application/pdf", no_ocr)
    assert [bool(p) for p in r.pages] == [True, False, True]  # the pages keep their numbers


def test_a_page_count_that_lies_reads_the_real_pages_and_logs_once():
    pdf = re.sub(rb"/Count \d+", b"/Count 1000000", make_pdf([[("Helvetica", ENGLISH)]] * 2))
    with capture_logs() as logs:
        r = doctext.read(pdf, "application/pdf", no_ocr)
    assert len(r.pages) == 2 and all(r.pages)
    assert logs == [
        {"event": "pages_unreadable", "log_level": "warning", "count": doctext.MAX_UNLOADED, "first": 3,
         "error": "PdfiumError"}
    ]  # fmt: skip


@pytest.mark.parametrize(
    "error", [subprocess.TimeoutExpired("tesseract", 300), subprocess.CalledProcessError(1, "tesseract")]
)
def test_a_page_ocr_fails_on_is_left_empty(error):
    calls = iter([error, None])

    def ocr(_: bytes) -> str:
        if failure := next(calls):
            raise failure
        return "आवेदक को ज़मानत पर रिहा किया जाए"

    r = doctext.read(make_pdf([[], []]), "application/pdf", ocr)
    assert (r.pages, r.ocr_pages) == (["", "आवेदक को ज़मानत पर रिहा किया जाए"], 2)


def test_a_tesseract_error_fails_the_image_not_the_engine(monkeypatch):
    monkeypatch.setattr(shutil, "which", lambda _: sys.executable)  # exits 2: it has no script named "stdin"
    with pytest.raises(subprocess.CalledProcessError):
        doctext.tesseract(b"P5\n1 1\n255\n\x00")


@pytest.mark.parametrize("code", [1, 0])  # 1: no language loaded; 0: it read on in English alone
def test_a_missing_language_pack_is_a_missing_engine(monkeypatch, tmp_path, code):
    (tmp_path / "stdin").write_text(
        f"import sys; sys.stderr.write(\"Failed loading language 'hin'\"); sys.exit({code})"
    )
    monkeypatch.chdir(tmp_path)  # the stand-in runs ./stdin, the first argument
    monkeypatch.setattr(shutil, "which", lambda _: sys.executable)
    with pytest.raises(doctext.OcrUnavailable):
        doctext.tesseract(b"P5\n1 1\n255\n\x00")


def test_images_are_ocred_and_docx_is_read():
    assert doctext.read(b"jpeg", "image/jpeg", lambda _: "text").pages == ["text"]
    docx = make_docx(["1. The petitioner", "जमानत आवेदन"])
    assert doctext.read(docx, doctext.DOCX, no_ocr).pages == ["1. The petitioner\nजमानत आवेदन"]


def test_docx_tabs_breaks_and_hyphens_separate_words():
    docx = make_docx(["Ramesh Kumar\nS/o Suresh\nR/o Indore", "Petitioner\tRamesh", "Cr.A.\N{NON-BREAKING HYPHEN}123"])
    r = doctext.read(docx, doctext.DOCX, no_ocr)
    assert r.pages == ["Ramesh Kumar\nS/o Suresh\nR/o Indore\nPetitioner\tRamesh\nCr.A.-123"]


def test_docx_runs_in_a_legacy_font_are_converted():
    docx = make_docx(
        [
            [
                ("Times New Roman", "Bail application: "),
                ("Kruti Dev 010", "U;k;ky; us vkns'k f"),
                ("Kruti Dev 010", "n;k"),
            ],
            [("DevLys 010", "“kjr dk lafo/kku")],
        ]
    )
    r = doctext.read(docx, doctext.DOCX, no_ocr)
    assert r.legacy_font
    assert r.pages == ["Bail application: न्यायालय ने आदेश दिया\nभारत का संविधान"]  # a run split mid-word too

    unnamed = doctext.read(make_docx(LEGACY), doctext.DOCX, no_ocr)  # no styles.xml: the font isn't known
    assert unnamed.legacy_font and "न्यायालय ने आदेश दिया" in unnamed.pages[0]


@pytest.mark.parametrize(
    ("styles", "style"),
    [
        (  # the document's default, under a default paragraph style based on itself
            f"<w:docDefaults><w:rPrDefault>{KRUTI_DEV}</w:rPrDefault></w:docDefaults>"
            '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:basedOn w:val="Normal"/></w:style>',
            None,
        ),
        (  # the default paragraph style, over the theme's font
            f"<w:docDefaults><w:rPrDefault>{THEME}</w:rPrDefault></w:docDefaults>"
            f'<w:style w:type="paragraph" w:default="1" w:styleId="Normal">{KRUTI_DEV}</w:style>',
            None,
        ),
        (  # the paragraph's style, by the style it is based on, over the default paragraph style
            '<w:style w:type="paragraph" w:default="1" w:styleId="Normal">'
            '<w:rPr><w:rFonts w:ascii="Times New Roman"/></w:rPr></w:style>'
            f'<w:style w:type="paragraph" w:styleId="HindiBase">{KRUTI_DEV}</w:style>'
            '<w:style w:type="paragraph" w:styleId="Hindi"><w:basedOn w:val="HindiBase"/></w:style>',
            "Hindi",
        ),
    ],
    ids=["document default", "default paragraph style", "paragraph style"],
)
def test_docx_runs_take_their_font_from_the_styles(styles, style):
    docx = make_docx([[("Times New Roman", CAUSE_TITLE)], LEGACY[1], [("Kruti Dev 010", "tekur")]], styles, style)
    r = doctext.read(docx, doctext.DOCX, no_ocr)
    assert r.pages == [f"{CAUSE_TITLE}\nन्यायालय ने आदेश दिया कि आवेदक को जमानत पर रिहा किया जाए।\nजमानत"]


def test_docx_text_read_as_kruti_dev_leaves_runs_in_a_named_font_be():
    styles = f"<w:docDefaults><w:rPrDefault>{THEME}</w:rPrDefault></w:docDefaults>"  # the theme's font: unknown
    r = doctext.read(make_docx([[("Times New Roman", CAUSE_TITLE)], *LEGACY], styles), doctext.DOCX, no_ocr)
    assert r.legacy_font
    assert r.pages[0].startswith(f"{CAUSE_TITLE}\nप्रकरण में याचिकाकर्ता")


def test_a_theme_font_over_a_kruti_dev_default_is_not_kruti_dev():
    styles = (
        f"<w:docDefaults><w:rPrDefault>{KRUTI_DEV}</w:rPrDefault></w:docDefaults>"
        '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"/>'
        f'<w:style w:type="paragraph" w:styleId="Heading1"><w:basedOn w:val="Normal"/>{THEME}</w:style>'
    )
    r = doctext.read(make_docx(["BAIL APPLICATION"], styles, "Heading1"), doctext.DOCX, no_ocr)
    assert r.pages == ["BAIL APPLICATION"]


NO_PAGES = re.sub(rb"/Kids \[[^]]*\]", b"/Kids [99 0 R]", make_pdf([[("Helvetica", ENGLISH)]]))  # a missing page


@pytest.mark.parametrize(
    ("data", "mime"), [(b"not a pdf", "application/pdf"), (NO_PAGES, "application/pdf"), (b"not a zip", doctext.DOCX)]
)
def test_an_unreadable_file(data, mime):
    with pytest.raises(doctext.Unreadable):
        doctext.read(data, mime, no_ocr)


def test_language():
    assert doctext.language(["न्यायालय ने आदेश दिया"]) == "hi"
    assert doctext.language(["The court ordered"]) == "en"
    assert doctext.language(["न्यायालय ने आदेश दिया", "The court ordered"]) == "mixed"
    assert doctext.language(["", "12 / 34"]) is None


def words(n: int, start: int = 0) -> str:
    return " ".join(f"word{i:05d}" for i in range(start, start + n))  # 9 characters: 3 tokens each


def test_chunks_are_about_400_tokens_with_50_overlapping():
    parts = doctext.chunks([words(1000)])
    assert [(c.page_no, c.chunk_no) for c in parts] == [(1, i) for i in range(len(parts))]
    for c in parts:
        assert len(c.text.split()) * 3 <= doctext.CHUNK_TOKENS + 3
    for a, b in itertools.pairwise(parts):
        shared = set(a.text.split()) & set(b.text.split())
        assert doctext.OVERLAP_TOKENS <= len(shared) * 3 <= doctext.OVERLAP_TOKENS + 3
    assert parts[0].text.startswith("word00000") and parts[-1].text.endswith("word00999")


def test_chunks_stay_far_below_the_embedders_limit():
    form = ("Name:" + " " * 80 + "Ramesh\t\t\tKumar\n\n \n\n") * 300  # a form aligned with spaces, blank lines
    parts = doctext.chunks([form + "Annexure P-3 " + "A" * 9000 + " end"])  # a run with no spaces (a hash)
    assert max(len(c.text) for c in parts) < 2200  # the embedder takes at most 8000 (services/embedder Text)
    assert parts[0].text.startswith("Name: Ramesh Kumar\nName: Ramesh Kumar\n")
    assert "A" * 100 in parts[-2].text


def test_chunks_stay_on_their_page_and_know_their_paragraphs():
    page1 = "1. The petitioner filed\n" + words(20) + "\n2. The respondent\n" + words(200, 100)
    page2 = words(10, 400) + "\n२. Devanagari digits"
    parts = doctext.chunks([page1, "", page2])
    assert [(c.page_no, c.chunk_no, c.paras) for c in parts] == [(1, 0, ["1", "2"]), (1, 1, ["2"]), (3, 0, ["2"])]
    assert parts[-1].text.endswith("Devanagari digits")


@pytest.mark.skipif(shutil.which("tesseract") is None, reason="Tesseract is installed in the worker image and CI")
def test_tesseract_reads_hindi_and_english():
    from PIL import Image, ImageDraw, ImageFont, features

    if not features.check("raqm"):
        pytest.skip("Pillow without raqm can't shape Devanagari")
    font = Path(__file__).parents[3] / "apps/client/assets/fonts/Mukta/Mukta-Regular.ttf"
    image = Image.new("L", (1800, 400), 255)
    draw = ImageDraw.Draw(image)
    draw.text((60, 60), "BAIL APPLICATION ALLOWED", font=ImageFont.truetype(str(font), 64), fill=0)
    draw.text((60, 200), "आवेदक को जमानत पर रिहा किया जाए", font=ImageFont.truetype(str(font), 72), fill=0)
    png = io.BytesIO()
    image.save(png, "PNG")
    text = fold(doctext.tesseract(png.getvalue()))
    assert "application" in text and "जमानत" in text
