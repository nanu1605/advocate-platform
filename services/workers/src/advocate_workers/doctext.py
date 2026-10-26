"""A document's text, page by page, and its chunks (spec §12.4, F15, F28). No database here: text.py runs it.

A PDF page's text comes from its text layer when it has one, and from OCR when it is a scan. Hindi typed in the Kruti
Dev or DevLys fonts reads as Latin garble in a text layer; the runs drawn in those fonts are converted, and a page
whose fonts aren't named but whose text reads as Kruti Dev is converted whole. Images are OCR'd; DOCX text is read
from its XML. Pages are cut into chunks of about 400 tokens with 50 of overlap, each knowing its page and the
paragraph numbers it covers."""

import ctypes
import io
import math
import re
import shutil
import subprocess
import zipfile
from collections.abc import Callable
from dataclasses import dataclass
from xml.etree import ElementTree

import pypdfium2 as pdfium
import pypdfium2.raw as pdfium_c

from advocate_shared.krutidev import convert, looks_like_krutidev

DOCX = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
OCR_DPI = 300
MIN_LETTERS = 30  # a page with fewer letters in its text layer is a scan (a stamp or page number aside)
LEGACY_FONT = re.compile(r"kruti|devlys", re.IGNORECASE)
CHUNK_TOKENS = 400
OVERLAP_TOKENS = 50

type Ocr = Callable[[bytes], str]  # an image (PNG, JPEG or PGM) -> its text


class OcrUnavailable(Exception):
    """No OCR engine here: the document waits (text_status ocr_pending) and is tried again later."""


class Unreadable(Exception):
    """A damaged or password-protected file: there is no text to get."""


def tesseract(image: bytes) -> str:
    """Tesseract `hin+eng` (spec §5 stack, the fallback OCR); the worker image installs it with both languages."""
    exe = shutil.which("tesseract")
    if exe is None:
        raise OcrUnavailable
    done = subprocess.run(  # noqa: S603 - a fixed program, the image on stdin
        [exe, "stdin", "stdout", "-l", "hin+eng", "--psm", "3", "--dpi", str(OCR_DPI)],
        input=image,
        capture_output=True,
        timeout=300,
        check=False,
    )
    if done.returncode != 0:
        raise OcrUnavailable(done.stderr.decode(errors="replace")[-500:])
    return done.stdout.decode("utf-8", errors="replace")


@dataclass(frozen=True)
class Reading:
    pages: list[str]
    ocr_pages: int = 0  # pages that needed OCR
    legacy_font: bool = False  # Kruti Dev or DevLys text was converted


def read(data: bytes, mime: str, ocr: Ocr = tesseract) -> Reading:
    """The text of each page of a PDF, image or DOCX. Raises OcrUnavailable when a page needs OCR and there is none,
    and Unreadable for a file that can't be opened."""
    if mime == DOCX:
        return Reading([_docx_text(data)])
    if mime.startswith("image/"):
        return Reading([ocr(data)], ocr_pages=1)
    try:
        pdf = pdfium.PdfDocument(data)
    except pdfium.PdfiumError as e:
        raise Unreadable from e
    pages, ocr_pages, legacy = [], 0, False
    try:
        for i in range(len(pdf)):
            page = pdf[i]
            try:
                text, converted = _page_text(page)
                if sum(c.isalpha() for c in text) < MIN_LETTERS:
                    text, converted = ocr(_render(page)), False
                    ocr_pages += 1
            finally:
                page.close()
            pages.append(text)
            legacy |= converted
    finally:
        pdf.close()
    return Reading(pages, ocr_pages, legacy)


def _page_text(page: pdfium.PdfPage) -> tuple[str, bool]:
    """The page's text layer, its legacy-font runs converted. True when something was converted."""
    textpage = page.get_textpage()
    try:
        n = textpage.count_chars()
        chars = [chr(pdfium_c.FPDFText_GetUnicode(textpage.raw, i)) for i in range(n)]
        if not any("A" <= c <= "z" for c in chars):  # nothing a legacy font could have written
            return "".join(chars), False
        buf = ctypes.create_string_buffer(256)
        flags = ctypes.c_int()
        runs: list[tuple[str | None, list[str]]] = []  # (legacy font name or None, characters)
        for i, c in enumerate(chars):
            size = pdfium_c.FPDFText_GetFontInfo(textpage.raw, i, buf, len(buf), ctypes.byref(flags))
            name = buf.value.decode("latin-1") if size else ""
            font = name if LEGACY_FONT.search(name) else None
            if c.isspace() and runs:
                font = runs[-1][0]  # spaces join the run they are in
            if runs and runs[-1][0] == font:
                runs[-1][1].append(c)
            else:
                runs.append((font, [c]))
    finally:
        textpage.close()
    if any(font for font, _ in runs):
        text = "".join(
            convert("".join(cs), devlys="devlys" in font.lower()) if font else "".join(cs) for font, cs in runs
        )
        return text, True
    text = "".join(chars)
    # ponytail: a page with unnamed fonts that reads as Kruti Dev is converted whole, English on it too
    if looks_like_krutidev(text):
        return convert(text), True
    return text, False


def _render(page: pdfium.PdfPage) -> bytes:
    """The page as a greyscale PGM image at OCR_DPI, which Tesseract reads from stdin."""
    bitmap = page.render(scale=OCR_DPI / 72, grayscale=True)  # pyright: ignore[reportArgumentType] - a float works
    try:
        width, height, stride = bitmap.width, bitmap.height, bitmap.stride
        raw = bytes(bitmap.buffer)
    finally:
        bitmap.close()
    rows = b"".join(raw[y * stride : y * stride + width] for y in range(height))
    return b"P5\n%d %d\n255\n" % (width, height) + rows


W = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"


def _docx_text(data: bytes) -> str:
    """A DOCX's paragraphs, one per line (it has no pages until it is laid out)."""
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            root = ElementTree.fromstring(z.read("word/document.xml"))  # noqa: S314 - a scanned upload, no DTDs
    except (zipfile.BadZipFile, KeyError, ElementTree.ParseError) as e:
        raise Unreadable from e
    return "\n".join("".join(t.text or "" for t in p.iter(f"{W}t")) for p in root.iter(f"{W}p"))


def language(pages: list[str]) -> str | None:
    """'hi', 'en' or 'mixed' by the share of Devanagari among letters; None with no letters."""
    dev = lat = 0
    for p in pages:
        for c in p:
            if c.isalpha():
                dev += "ऀ" <= c <= "ॿ"
                lat += c.isascii()
    if dev + lat == 0:
        return None
    share = dev / (dev + lat)
    return "hi" if share >= 0.7 else "en" if share <= 0.3 else "mixed"


@dataclass(frozen=True)
class Chunk:
    page_no: int
    chunk_no: int
    paras: list[str]
    text: str


# A numbered paragraph at the start of a line: "12. The", "12.1 The", "(4) The", "para 5. The"; not "302 IPC" or
# "12.05.2010". Devanagari digits read as Western.
PARA = re.compile(
    r"^[ 	]*(?:para(?:graph)?\.?[ 	]*)?\(?(\d{1,3}(?:\.\d{1,2})+|\d{1,3}(?=[.)]))[.)]?[ 	]+\S",
    re.IGNORECASE | re.MULTILINE,
)
DIGITS = str.maketrans("०१२३४५६७८९", "0123456789")
WORD = re.compile(r"\S+")


def _tokens(word: str) -> int:
    """About how many BGE-M3 tokens a word takes: one per four characters."""
    # ponytail: a character estimate; count with the model's tokenizer if chunks overflow the reranker's 512
    return max(1, math.ceil(len(word) / 4))


def chunks(pages: list[str]) -> list[Chunk]:
    """Chunks of about CHUNK_TOKENS tokens, OVERLAP_TOKENS shared with the one before, never across a page. Each
    lists the paragraph it starts in (carried over from earlier pages) and those that start inside it."""
    out: list[Chunk] = []
    current: str | None = None  # the paragraph the text so far is in
    for page_no, page in enumerate(pages, 1):
        starts = [(m.start(), m[1]) for m in PARA.finditer(page.translate(DIGITS))]
        words = list(WORD.finditer(page))
        i, chunk_no = 0, 0
        while i < len(words):
            j, size = i, 0
            while j < len(words) and (size < CHUNK_TOKENS or j == i):
                size += _tokens(words[j][0])
                j += 1
            begin, end = words[i].start(), words[j - 1].end()
            paras = [p for at, p in starts if at <= begin]
            paras = ([paras[-1]] if paras else [current] if current else []) + [
                p for at, p in starts if begin < at < end
            ]
            out.append(Chunk(page_no, chunk_no, list(dict.fromkeys(paras)), page[begin:end]))
            chunk_no += 1
            if j == len(words):
                break
            back, k = 0, j  # step back for the overlap
            while k > i + 1 and back < OVERLAP_TOKENS:
                k -= 1
                back += _tokens(words[k][0])
            i = k
        if starts:
            current = starts[-1][1]
    return out
