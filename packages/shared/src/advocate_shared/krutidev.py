"""Kruti Dev 010 / DevLys 010 text to Unicode (spec §12.11, F28). Hindi typed in these legacy fonts is Latin-1
characters drawn as Devanagari, so a PDF's text layer or a paste reads "U;k;ky;" for न्यायालय.

The table comes from the fonts' own glyphs, cross-checked against SIL's TECkit maps (MIT) and the widely used
converters; no converter code was copied. `apps/client/lib/core/krutidev.dart` is the same algorithm; both are tested
against `config/fixtures/krutidev.json`, so change them together.

Conversion: undo PDF and clipboard artefacts, one longest-match pass through the table (with placeholders for the
i-matra typed before its consonant and the reph typed after its cluster), clean-up rules, then the two reorderings."""

# ruff: noqa: RUF001, RUF003 (the legacy font's characters are lookalikes by nature)

import re
import unicodedata

IKAR = ""  # 'f': i-matra typed before its consonant cluster
REPH = ""  # 'Z': reph typed after the cluster (and its vowel signs) it goes before
IKAR_ANUS = ""  # Ç, 'fa': i-matra + anusvara
IKAR_REPH = ""  # Æ: i-matra + reph
IKAR_REPH_ANUS = ""  # É: i-matra + reph + anusvara
IKARS = {IKAR: "ि", IKAR_ANUS: "िं", IKAR_REPH: "ि" + REPH, IKAR_REPH_ANUS: "ि" + REPH + "ं"}

# (legacy, unicode): one left-to-right pass takes the longest key at each position, so the order here doesn't matter.
# fmt: off
PAIRS = [
    # --- multi-character sequences (must win over their prefixes) ---
    ("vks", "ओ"), ("vkS", "औ"), ("vk", "आ"), ("v‚", "ऑ"), (",s", "ऐ"),
    ("bZ", "ई"), ("b±", "ईं"), ("AA", "॥"), ("fa", IKAR_ANUS),
    # --- independent vowels ---
    ("v", "अ"), ("b", "इ"), ("Ã", "ई"), ("m", "उ"), ("Å", "ऊ"), (",", "ए"), ("_", "ऋ"),
    # --- full consonants ---
    ("d", "क"), ("x", "ग"), ("Ä", "घ"), ("³", "ङ"), ("p", "च"), ("N", "छ"), ("t", "ज"),
    (">", "झ"), ("¥", "ञ"), ("´", "ञ"), ("V", "ट"), ("B", "ठ"), ("M", "ड"), ("<", "ढ"),
    ("r", "त"), ("n", "द"), ("u", "न"), ("i", "प"), ("Q", "फ"), ("c", "ब"), ("Ò", "भ"),
    ("\x90", "भ"), ("e", "म"), (";", "य"), ("j", "र"), ("y", "ल"), ("G", "ळ"), ("o", "व"),
    ("l", "स"), ("g", "ह"),
    # --- half forms (consonant + virama); a following 'k' bar makes them full ---
    ("D", "क्"), ("[", "ख्"), ("X", "ग्"), ("?", "घ्"), ("P", "च्"), ("T", "ज्"),
    ("÷", "झ्"), ("Ö", "झ्"), (".", "ण्"), ("R", "त्"), ("F", "थ्"), ("/", "ध्"),
    ("Ë", "ध्"), ("è", "ध्"), ("U", "न्"), ("I", "प्"), ("¶", "फ्"), ("C", "ब्"),
    ("H", "भ्"), ("E", "म्"), ("¸", "य्"), ("Ú", "र्"), ("Y", "ल्"), ("O", "व्"),
    ("'", "श्"), ("Ü", "श्"), ("“", "श्"), ("”", "श्"),  # “ ” = श् in KD 010
    ('"', "ष्"), ("‘", "ष्"), ("’", "ष्"),  # ‘ ’ = ष् in KD 010
    ("L", "स्"), ("º", "ह्"),
    # --- conjunct ligatures ---
    ("{", "क्ष्"), ("K", "ज्ञ"), ("J", "श्र"), ("=", "त्र"), ("«", "त्र्"), ("Ø", "क्र"),
    ("ç", "प्र"), ("Á", "प्र"), ("Ý", "फ्र"), ("æ", "द्र"), ("£", "ख्र"), (")", "द्ध"),
    ("|", "द्य"), ("}", "द्व"), ("ä", "क्त"), ("ô", "क्क"), ("é", "न्न"), ("™", "न्न्"),
    ("Ù", "त्त्"), ("Ÿ", "त्त्"), ("à", "ह्न"), ("á", "ह्य"), ("ã", "ह्म"), ("Ì", "द्द"),
    ("í", "द्द"), ("Í", "ट्ट"), ("ê", "ट्ट"), ("Î", "ट्ठ"), ("ë", "ट्ठ"), ("ð", "ठ्ठ"),
    ("Ï", "ड्ड"), ("ì", "ड्ड"), ("Ô", "ड्ढ"), ("ï", "ड्ढ"), ("ó", "स्त्र"), ("ù", "द्म"),
    ("˜", "द्भ"), ("ö", "द्भ"),
    # --- consonant + vowel ligatures ---
    ("#", "रु"), (":", "रू"), ("—", "कृ"), ("Ñ", "कृ"), ("–", "दृ"), ("â", "हृ"),
    # --- subjoined forms ---
    ("z", "्र"), ("ª", "्र"), ("Ó", "्य"), ("î", "्य"), ("~", "्"),
    # --- dependent vowel signs (o/au are bar + stroke; cleaned up later) ---
    ("k", "ा"), ("f", IKAR), ("h", "ी"), ("q", "ु"), ("w", "ू"), ("`", "ृ"), ("¤", "ॄ"),
    ("§", "ॄ"), ("s", "े"), ("¢", "े"), ("S", "ै"), ("¨", "ाे"), ("®", "ाे"), ("©", "ाै"),
    ("W", "ॅ"), ("‚", "ाॅ"),
    # --- signs and combined glyphs ---
    ("a", "ं"), ("¡", "ँ"), ("+", "़"), ("·", "ऽ"), ("∙", "ऽ"), ("Z", REPH), ("±", REPH + "ं"),
    ("Æ", IKAR_REPH), ("Ç", IKAR_ANUS), ("É", IKAR_REPH_ANUS), ("È", "ीं"), ("Ê", "ी" + REPH),
    ("›", "ै" + REPH + "ं"), ("õ", "ै" + REPH + "ं"),
    # --- Devanagari digits (ASCII 0-9 render as Latin digits and pass through) ---
    ("å", "०"), ("Œ", "०"), ("ƒ", "१"), ("„", "२"), ("…", "३"), ("†", "४"), ("‡", "५"),
    ("ˆ", "६"), ("‰", "७"), ("Š", "८"), ("‹", "९"),
    # --- punctuation ---
    ("A", "।"), ("-", "."), ("&", "-"), ("]", ","), ("(", ";"), ("\\", "?"), ("@", "/"),
    ("$", "+"), ("^", "‘"), ("*", "’"), ("ß", "“"), ("Þ", "”"),
    ("¼", "("), ("½", ")"), ("¾", "="), ("¿", "{"), ("ø", "{"), ("À", "}"), ("»", "÷"),
    ("ñ", "॰"), ("Û", "•"),
    # '%' is contextual (visarga, or ':' after a digit / space); handled in tokenize()
]
# fmt: on
TABLE = dict(PAIRS)
# DevLys 010 draws two of Kruti Dev 010's quote slots differently and leaves three blank.
DEVLYS = TABLE | {"’": "श्", "“": "भ", "\x90": "", "‘": "", "”": ""}
_KEYS = re.compile("|".join(re.escape(k) for k in sorted(TABLE, key=len, reverse=True)))

CONS = "[क-हक़-य़]"
CLUSTER = re.compile(f"{CONS}़?(?:्{CONS}़?)*")
POST = set("ािीुूृॄेैोौॅॉंँ़")  # signs that follow a cluster in Unicode order
MARK = "[ऀ-ःऺ-्॑-ॗॢॣ]"

# In order, after the table pass and before the reorderings.
CLEANUP = [
    (re.compile(rf"\s+(?={MARK}|{REPH})"), ""),  # PDF extraction splits a sign from its letter: "vkb Z"
    (re.compile(f"([{IKAR}{IKAR_ANUS}{IKAR_REPH}{IKAR_REPH_ANUS}])\\s+"), r"\1"),
    (re.compile(f"इ{REPH}"), "ई"),  # "b Z", split by extraction
    (re.compile(f"{REPH}([ािीुूृॄेैोौॅॉंँ]+)"), rf"\1{REPH}"),  # the reph goes after the vowel signs: "lokZsPp"
    (re.compile("([ंँ]+)([ाीुूृॄेैोौॉ]+)"), r"\2\1"),  # a nasal typed before its vowel sign: "eas"
    (re.compile("ॅा"), "ाॅ"),
    (re.compile("़्"), "़्"),  # the nukta before the virama: "T+" = ज़्
    (re.compile("््रा"), "्र"),  # half form + z + bar = full form + rakar: "Izk"
    (re.compile("््"), "्"),  # half form + z or ~
    (re.compile("्ा"), ""),  # half form + bar = full consonant: "Dk", "'k", "{k"
    (re.compile("ॅं"), "ँ"),  # candra + dot, before ाॅ becomes ॉ: "ikWap"
    (re.compile("ाे"), "ो"),
    (re.compile("ाै"), "ौ"),
    (re.compile("ाॅ"), "ॉ"),
    (re.compile("ाा"), "ा"),
    (re.compile("ंं+"), "ं"),
    (re.compile("अा"), "आ"),
    (re.compile("अो"), "ओ"),
    (re.compile("अौ"), "औ"),
    (re.compile("[अआ]ॉ|आॅ"), "ऑ"),
    (re.compile("एे"), "ऐ"),
]

# '%' draws both the visarga and the colon. A word-final visarga stays only in these words; mid-word (दुःख) always.
# ponytail: a word list (adverbs in -तः, not participles in -ित/-ुत); search treats a final ः and ':' alike anyway
VISARGA_WORDS = re.compile(r"(?:अतः|पुनः|प्रायः|क्रमशः|वस्तुतः|नमः|.*[^िु]तः)")
FINAL_VISARGA = re.compile(r"[ऀ-ॿ]+ः(?![ऀ-ॿ])")


def _normalise(s: str) -> str:
    """Undo PDF and clipboard artefacts: symbol-font private-use characters (U+F020-F0FF) and raw C1 bytes."""
    out = []
    for ch in s:
        o = ord(ch)
        if 0xF020 <= o <= 0xF0FF:
            ch, o = chr(o - 0xF000), o - 0xF000
        if 0x80 <= o <= 0x9F and o != 0x90:
            try:
                ch = bytes([o]).decode("cp1252")
            except UnicodeDecodeError:
                pass
        out.append(ch)
    return "".join(out)


def _tokenise(s: str, table: dict[str, str]) -> str:
    out: list[str] = []
    i = 0
    while i < len(s):
        if s[i] == "%":  # a visarga after Devanagari, else a colon ("10%30")
            out.append("ः" if out and "ऀ" <= out[-1][-1:] <= "ॿ" else ":")
            i += 1
        elif m := _KEYS.match(s, i):
            out.append(table[m[0]])
            i = m.end()
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def _place_ikar(s: str) -> str:
    """Each i-matra placeholder goes after the whole cluster that follows it: "fLFkfr" = स्थिति."""
    out: list[str] = []
    i = 0
    while i < len(s):
        if s[i] in IKARS:
            if m := CLUSTER.match(s, i + 1):
                out.append(m[0] + IKARS[s[i]])
                i = m.end()
                continue
            out.append(IKARS[s[i]])  # a stray 'f' with no consonant after it
        else:
            out.append(s[i])
        i += 1
    return "".join(out)


def _is_cons(ch: str) -> bool:
    return re.fullmatch(CONS, ch) is not None


def _place_reph(s: str) -> str:
    """Each reph placeholder becomes र् before the cluster it follows, past its vowel signs: "lkeF;Z" = सामर्थ्य."""
    while (p := s.find(REPH)) != -1:
        k = p
        while k > 0 and s[k - 1] in POST:
            k -= 1
        if k > 0 and _is_cons(s[k - 1]):
            k -= 1
            while True:  # back over each "C ्" or "C ़ ्" before it
                if k >= 2 and s[k - 1] == "्" and _is_cons(s[k - 2]):
                    k -= 2
                elif k >= 3 and s[k - 1] == "्" and s[k - 2] == "़" and _is_cons(s[k - 3]):
                    k -= 3
                else:
                    break
        s = s[:k] + "र्" + s[k:p] + s[p + 1 :]
    return s


def convert(legacy: str, *, devlys: bool = False) -> str:
    """Kruti Dev 010 text (DevLys 010 with [devlys]) as Unicode Devanagari. Characters outside the table pass through,
    ASCII digits among them; but English letters don't, so only text known or detected to be in the legacy font goes
    here."""
    s = _tokenise(_normalise(legacy), DEVLYS if devlys else TABLE)
    for rx, rep in CLEANUP:
        s = rx.sub(rep, s)
    s = _place_reph(_place_ikar(s))
    s = FINAL_VISARGA.sub(lambda m: m[0] if VISARGA_WORDS.fullmatch(m[0]) else m[0][:-1] + ":", s)
    return unicodedata.normalize("NFC", s)


# Common Hindi words as Kruti Dev types them: के, को, की, पर, है, का, में, हैं, किया, से, और, नहीं ...
STOPWORDS = {
    "ds", "dks", "dh", "ij", "gS", "dk", "esa", "gSa", "fd;k", "ls", "vkSj", "ugha", "x;k", "fd", "gh", "Fkk",
    "Fkh", "Hkh", "}kjk", "djus", "dj", "tkus", ";g", "rks", "bl", "og", "vuqlkj", "gks", "fd;s", "dksbZ", "rd",
    "mDr", "xbZ", "rFkk", "vFkok",
}  # fmt: skip
_EDGES = re.compile(r"^[\]A%&\-()¼½,.\d]+|[\]A%&\-()¼½,]+$")
_LATIN = re.compile(r"[A-Za-z]")
_DEVANAGARI = re.compile(r"[ऀ-ॿ]")
# Kruti Dev letters that are ASCII punctuation next to a letter, or Latin-1 and cp1252 symbols.
_SYMBOLS = re.compile(r"[A-Za-z][;'\"/{}\[\]|=~`]|[;'\"/{}\[\]|=~`][A-Za-z]|[¡-ÿŒ-ƒ–-›™]")


def looks_like_krutidev(text: str) -> bool:
    """Whether [text] reads as Hindi typed in Kruti Dev rather than English or romanised Hindi. It needs a paragraph or
    a page (about 200 characters); with under 20 Latin letters, or real Devanagari in it, the answer is no.

    In Kruti Dev Hindi about a fifth of the letters are 'k' (the ā sign), 'e' (म) is rare and 'a' (the anusvara) is
    scarce, unlike English or romanised Hindi; common words such as "esa" (में) and Kruti Dev punctuation settle it."""
    latin = _LATIN.findall(text)
    devanagari = len(_DEVANAGARI.findall(text))
    if len(latin) < 20 or devanagari > 0.2 * (devanagari + len(latin)):
        return False
    words = [w for w in (_EDGES.sub("", w) for w in text.split()) if w]
    n = len(words) or 1
    stop = sum(w in STOPWORDS for w in words) / n
    symbols = sum(bool(_SYMBOLS.search(w)) for w in words) / n
    k, e, a = (latin.count(c) / len(latin) for c in "kea")
    return stop >= 0.12 or (k >= 0.10 and e <= 0.09 and a <= 0.12 and (symbols >= 0.05 or stop >= 0.03))
