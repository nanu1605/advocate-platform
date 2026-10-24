"""Search keys for Hindi/English transliteration search (spec §4.3, §9.1): "Sharma" and "शर्मा" get the same key.

Devanagari is romanised letter by letter, then both scripts go through the same phonetic folding: aspiration,
long vowels, doubled letters and every "a" are dropped, so schwa deletion ("राजकुमार" = "Rajkumar") stops mattering.
Keys are only compared with other keys, never shown. `apps/client/lib/core/search_key.dart` is the same algorithm;
both are tested against `config/fixtures/translit_pairs.yaml`, so change them together."""

import re

CONSONANTS = {
    "क": "k", "ख": "kh", "ग": "g", "घ": "gh", "ङ": "n",
    "च": "ch", "छ": "chh", "ज": "j", "झ": "jh", "ञ": "n",
    "ट": "t", "ठ": "th", "ड": "d", "ढ": "dh", "ण": "n",
    "त": "t", "थ": "th", "द": "d", "ध": "dh", "न": "n",
    "प": "p", "फ": "ph", "ब": "b", "भ": "bh", "म": "m",
    "य": "y", "र": "r", "ल": "l", "ळ": "l", "व": "v",
    "श": "sh", "ष": "sh", "स": "s", "ह": "h",
    "\u0958": "k", "\u0959": "kh", "\u095a": "g", "\u095b": "j",  # precomposed nukta letters
    "\u095c": "r", "\u095d": "rh", "\u095e": "ph", "\u095f": "y",
}  # fmt: skip
NUKTA_CONSONANTS = {"ड": "r", "ढ": "rh"}  # ड़ and ढ़ written as base letter + nukta
MATRAS = {
    "ा": "a", "ि": "i", "ी": "i", "ु": "u", "ू": "u", "ृ": "ri",
    "े": "e", "ै": "ai", "ो": "o", "ौ": "au", "ॅ": "e", "ॉ": "o",
}  # fmt: skip
SIGNS = {
    "अ": "a", "आ": "a", "इ": "i", "ई": "i", "उ": "u", "ऊ": "u", "ऋ": "ri",
    "ए": "e", "ऐ": "ai", "ओ": "o", "औ": "au", "ऍ": "e", "ऑ": "o",
    "ं": "n", "ँ": "n", "\u0903": "", "ऽ": "", "\u093c": "", "\u200c": "", "\u200d": "",
}  # fmt: skip
SIGNS |= {chr(0x966 + d): str(d) for d in range(10)}  # Devanagari digits
VIRAMA = "्"

# Applied in order to each lower-case Latin word.
RULES = [
    (r"qui", "ki"),  # Siddiqui
    (r"q", "k"),
    (r"x", "ks"),
    (r"z", "j"),
    (r"w", "v"),
    (r"ph", "f"),
    (r"ngh", "n"),  # Singh = सिंह
    (r"m(?=[bp])", "n"),  # Ambika = अंबिका
    (r"(?<=[bcdfgjklmnpqrstvxyz])h+", ""),  # aspiration: bh = b, sh = s, chh = c
    (r"e(?=r[bcdfgjklmnpqstvxyz])", "a"),  # Verma = वर्मा
    (r"ee", "i"),
    (r"oo", "u"),
    (r"ai", "e"),
    (r"[ao]u", "o"),
    (r"ey$", "e"),  # Pandey = पांडे
    (r"(?<=[bcdfghjklmnpqrstvxz])y$", "i"),  # Choudhary = चौधरी
    (r"ore$", "or"),  # Kishore = किशोर
    (r"(.)(?=\1)", ""),  # doubled letters
    (r"a", ""),
]


def search_key(text: str) -> str:
    words = re.split(r"[^a-z0-9]+", _romanise(text).lower())
    return " ".join(k for w in words if (k := _fold(w)))


def _romanise(text: str) -> str:
    text = text.replace("ज्ञ", "ग्य")  # gya, as in Gyanendra
    out: list[str] = []
    i = 0
    while i < len(text):
        c = text[i]
        if c in CONSONANTS:
            latin = CONSONANTS[c]
            if text[i + 1 : i + 2] == "\u093c":
                latin = NUKTA_CONSONANTS.get(c, latin)
                i += 1
            nxt = text[i + 1 : i + 2]
            out.append(latin + MATRAS.get(nxt, "" if nxt == VIRAMA else "a"))
            if nxt in MATRAS or nxt == VIRAMA:
                i += 1
        else:
            out.append(SIGNS.get(c, c))
        i += 1
    return "".join(out)


def _fold(word: str) -> str:
    if re.search(r"[0-9]", word):  # case numbers and CNRs stay as typed
        return word
    for pattern, repl in RULES:
        word = re.sub(pattern, repl, word)
    return word
