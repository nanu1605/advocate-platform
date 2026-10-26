"""Reading a document's pages and cutting them into chunks (spec §12.4, F15, F28); no database."""

import io
import itertools
import math
import shutil
from pathlib import Path

import pytest
from pdfs import make_docx, make_pdf

from advocate_shared.retrieval import fold
from advocate_workers import doctext

ENGLISH = ["IN THE HIGH COURT OF MADHYA PRADESH AT INDORE", "WRIT PETITION No. 1234 of 2024"]
LEGACY = [
    "izdj.k esa ;kfpdkdrkZ dh vksj ls vf/koDrk mifLFkr gSA",
    "U;k;ky; us vkns'k fn;k fd vkosnd dks tekur ij fjgk fd;k tk,A",
]


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


def test_images_are_ocred_and_docx_is_read():
    assert doctext.read(b"jpeg", "image/jpeg", lambda _: "text").pages == ["text"]
    docx = make_docx(["1. The petitioner", "जमानत आवेदन"])
    assert doctext.read(docx, doctext.DOCX, no_ocr).pages == ["1. The petitioner\nजमानत आवेदन"]


@pytest.mark.parametrize(("data", "mime"), [(b"not a pdf", "application/pdf"), (b"not a zip", doctext.DOCX)])
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
