"""A document's text, page by page, and its chunks (spec §12.4, F15, F28). No database here: text.py runs it.

A PDF page's text comes from its text layer when it has one, and from OCR when it is a scan. Hindi typed in the Kruti
Dev or DevLys fonts reads as Latin garble in a text layer; the runs drawn in those fonts are converted, and a page
whose fonts aren't named but whose text reads as Kruti Dev is converted whole; a DOCX's runs likewise, by the font
each has from its styles. A PDF page that can't be loaded or OCR'd is left empty and the rest are read, but pages
that won't load at the end (a page count that lies) are dropped. Images are OCR'd; DOCX text is read from its XML.
Pages are cut into chunks of about 400 tokens with 50 of overlap, each knowing its page and the paragraph numbers it
covers."""

import ctypes
import io
import itertools
import math
import re
import shutil
import subprocess
import zipfile
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from xml.etree import ElementTree

import pypdfium2 as pdfium
import pypdfium2.raw as pdfium_c
import structlog

from advocate_shared.krutidev import convert, looks_like_krutidev

DOCX = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
OCR_DPI = 300
MIN_LETTERS = 30  # a page with fewer letters in its text layer is a scan (a stamp or page number aside)
# ponytail: pages in a row that won't load end the file (its /Count can claim a million); real ones after are lost
MAX_UNLOADED = 20
LEGACY_FONT = re.compile(r"kruti|devlys", re.IGNORECASE)
CHUNK_TOKENS = 400
OVERLAP_TOKENS = 50

log = structlog.get_logger()

# An image (PNG, JPEG or PGM) -> its text. Raises OcrUnavailable without an engine (or its languages), and
# subprocess.SubprocessError when it fails on this image.
type Ocr = Callable[[bytes], str]


class OcrUnavailable(Exception):
    """No OCR engine here: the document waits (text_status ocr_pending) and is tried again later. Only for a missing
    engine or language pack: an image it fails on (an error, a timeout) fails that page alone."""


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
    if b"Failed loading language" in done.stderr:  # every image would fail, or lose its Hindi if English loaded
        raise OcrUnavailable
    done.check_returncode()  # CalledProcessError, like TimeoutExpired: this image's page fails, not the engine
    return done.stdout.decode("utf-8", errors="replace")


@dataclass(frozen=True)
class Reading:
    pages: list[str]
    ocr_pages: int = 0  # pages that needed OCR
    legacy_font: bool = False  # Kruti Dev or DevLys text was converted


def read(data: bytes, mime: str, ocr: Ocr = tesseract) -> Reading:
    """The text of each page of a PDF, image or DOCX. Raises OcrUnavailable when a page needs OCR and there is none,
    and Unreadable for a file that can't be opened. A PDF page that can't be loaded or OCR'd is left empty, unless
    only such pages follow it (logged once)."""
    if mime == DOCX:
        text, legacy = _docx_text(data)
        return Reading([text], legacy_font=legacy)
    if mime.startswith("image/"):
        return Reading([ocr(data)], ocr_pages=1)
    try:
        pdf = pdfium.PdfDocument(data)
    except pdfium.PdfiumError as e:
        raise Unreadable from e
    pages, ocr_pages, legacy = [], 0, False
    failed: list[tuple[int, str]] = []  # (page number, error)
    loaded = 0  # the pages up to the last one that loaded
    try:
        for i in range(len(pdf)):
            if i - loaded == MAX_UNLOADED:
                break
            try:
                page = pdf[i]
                loaded = i + 1
                try:
                    text, converted = _page_text(page)
                    if sum(c.isalpha() for c in text) < MIN_LETTERS:
                        ocr_pages += 1
                        text, converted = ocr(_render(page)), False
                finally:
                    page.close()
            except (pdfium.PdfiumError, subprocess.SubprocessError) as e:
                failed.append((i + 1, type(e).__name__))
                text, converted = "", False  # the page keeps its number
            pages.append(text)
            legacy |= converted
    finally:
        pdf.close()
    if failed:
        log.warning("pages_unreadable", count=len(failed), first=failed[0][0], error=failed[0][1])
    if not loaded:
        raise Unreadable
    return Reading(pages[:loaded], ocr_pages, legacy)


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
        pieces: list[tuple[str | None, str]] = []
        for i, c in enumerate(chars):
            size = pdfium_c.FPDFText_GetFontInfo(textpage.raw, i, buf, len(buf), ctypes.byref(flags))
            name = buf.value.decode("latin-1") if size else ""
            font = name if LEGACY_FONT.search(name) else None
            if c.isspace() and pieces:
                font = pieces[-1][0]  # spaces join the run they are in
            pieces.append((font, c))
    finally:
        textpage.close()
    return _converted(pieces)


def _converted(pieces: list[tuple[str | None, str]]) -> tuple[str, bool]:
    """Text in pieces, each with its legacy font's name, '' for another named font, or None for a font not known: each
    run in a legacy font converted whole (so an i-matra typed before its consonant finds it), or, with none, the text
    in unknown fonts when it reads as Kruti Dev. True when something was converted."""
    runs = [(font, "".join(t for _, t in run)) for font, run in itertools.groupby(pieces, key=lambda p: p[0])]
    if any(font for font, _ in runs):
        return "".join(convert(t, devlys="devlys" in font.lower()) if font else t for font, t in runs), True
    # ponytail: text in unknown fonts that reads as Kruti Dev is converted whole, English in it too
    if looks_like_krutidev("".join(t for font, t in runs if font is None)):
        return "".join(convert(t) if font is None else t for font, t in runs), True
    return "".join(t for _, t in runs), False


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
RUN_TEXT = {f"{W}tab": "\t", f"{W}br": "\n", f"{W}cr": "\n", f"{W}noBreakHyphen": "-"}  # besides w:t


def _docx_text(data: bytes) -> tuple[str, bool]:
    """A DOCX's paragraphs, one per line (it has no pages until it is laid out), its runs in a legacy font converted
    as a PDF's are. A run's font is its own, else its paragraph style's (or the default paragraph style's), else the
    document's default. True when something was converted."""
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            root = ElementTree.fromstring(z.read("word/document.xml"))  # noqa: S314 - a scanned upload, no DTDs
            styled = "word/styles.xml" in z.namelist()
            sheet = ElementTree.fromstring(z.read("word/styles.xml") if styled else b"<styles/>")  # noqa: S314
    except (zipfile.BadZipFile, KeyError, ElementTree.ParseError) as e:
        raise Unreadable from e
    styles = {s.get(f"{W}styleId"): s for s in sheet.iter(f"{W}style") if s.get(f"{W}styleId")}
    default = next(
        (i for i, s in styles.items() if s.get(f"{W}type") == "paragraph" and s.get(f"{W}default") in ("1", "true")),
        None,
    )
    doc_default = sheet.find(f"{W}docDefaults/{W}rPrDefault/{W}rPr")
    pieces: list[tuple[str | None, str]] = []
    for n, p in enumerate(root.iter(f"{W}p")):
        if n:
            pieces.append((None, "\n"))
        style = p.find(f"{W}pPr/{W}pStyle")
        style_id = None if style is None else style.get(f"{W}val")
        inherited = [*_based(styles, style_id if style_id in styles else default), doc_default]
        for run in p.iter(f"{W}r"):
            text = "".join((e.text or "") if e.tag == f"{W}t" else RUN_TEXT.get(e.tag, "") for e in run)
            pieces.append((_font([run.find(f"{W}rPr"), *inherited]), text))
    return _converted(pieces)


def _based(styles: dict[str | None, ElementTree.Element], style_id: str | None) -> list[ElementTree.Element | None]:
    """A style's w:rPr, then those of the styles it is based on."""
    out, seen = [], set()
    while style_id in styles and style_id not in seen:  # a style can be based on itself, or loop
        seen.add(style_id)
        out.append(styles[style_id].find(f"{W}rPr"))
        based = styles[style_id].find(f"{W}basedOn")
        style_id = None if based is None else based.get(f"{W}val")
    return out


def _font(levels: Iterable[ElementTree.Element | None]) -> str | None:
    """The font the nearest of these w:rPr names, as _converted takes it: a legacy font's name, '' for another font,
    or None when none names one or it is the theme's (not read here)."""
    for rpr in levels:
        fonts = None if rpr is None else rpr.find(f"{W}rFonts")
        if fonts is None:
            continue
        names = [name for name in (fonts.get(f"{W}ascii"), fonts.get(f"{W}hAnsi")) if name]
        if names:
            return next((name for name in names if LEGACY_FONT.search(name)), "")
        if fonts.get(f"{W}asciiTheme") or fonts.get(f"{W}hAnsiTheme"):
            return None
    return None


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
WORD = re.compile(r"\S{1,100}")  # a longer run (a hash, a text layer without spaces) is cut every 100 characters
SPACES = re.compile(r"[^\S\n]+")  # a form aligned with spaces or tabs
BREAKS = re.compile(r"\s*\n\s*")  # blank lines


def _tokens(word: str) -> int:
    """About how many BGE-M3 tokens a word takes: one per four characters."""
    # ponytail: a character estimate; count with the model's tokenizer if chunks overflow the reranker's 512
    return max(1, math.ceil(len(word) / 4))


def chunks(pages: list[str]) -> list[Chunk]:
    """Chunks of about CHUNK_TOKENS tokens, OVERLAP_TOKENS shared with the one before, never across a page. Each
    lists the paragraph it starts in (carried over from earlier pages) and those that start inside it. Whitespace is
    squeezed to one space or line break and long words are cut, so a chunk stays under about 2,200 characters, far
    below the embedder's 8,000 (services/embedder Text)."""
    out: list[Chunk] = []
    current: str | None = None  # the paragraph the text so far is in
    for page_no, raw in enumerate(pages, 1):
        page = BREAKS.sub("\n", SPACES.sub(" ", raw))
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
