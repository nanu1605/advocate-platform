/// Kruti Dev 010 / DevLys 010 text to Unicode (spec §12.11, F28). Hindi typed in these legacy fonts is Latin-1
/// characters drawn as Devanagari, so a paste reads "U;k;ky;" for न्यायालय.
///
/// The same algorithm as `packages/shared/src/advocate_shared/krutidev.py`, which has the notes; both are tested
/// against `config/fixtures/krutidev.json`, so change them together. The table and the clean-up rules here were
/// generated from the Python module's, entry for entry.
library;

const _ikar = '\u{e001}'; // 'f': i-matra typed before its consonant cluster
const _reph = '\u{e002}'; // 'Z': reph typed after the cluster (and its vowel signs) it goes before
const _ikarAnus = '\u{e003}';
const _ikarReph = '\u{e004}';
const _ikarRephAnus = '\u{e005}';
const Map<String, String> _ikars = {
  _ikar: '\u{93f}',
  _ikarAnus: '\u{93f}\u{902}',
  _ikarReph: '\u{93f}$_reph',
  _ikarRephAnus: '\u{93f}$_reph\u{902}',
};

const Map<String, String> _table = {
  'vks': 'ओ',
  'vkS': 'औ',
  'vk': 'आ',
  'v\u{201a}': 'ऑ',
  ',s': 'ऐ',
  'bZ': 'ई',
  'b\u{b1}': 'ईं',
  'AA': '॥',
  'fa': _ikarAnus,
  'v': 'अ',
  'b': 'इ',
  '\u{c3}': 'ई',
  'm': 'उ',
  '\u{c5}': 'ऊ',
  ',': 'ए',
  '_': 'ऋ',
  'd': 'क',
  'x': 'ग',
  '\u{c4}': 'घ',
  '\u{b3}': 'ङ',
  'p': 'च',
  'N': 'छ',
  't': 'ज',
  '>': 'झ',
  '\u{a5}': 'ञ',
  '\u{b4}': 'ञ',
  'V': 'ट',
  'B': 'ठ',
  'M': 'ड',
  '<': 'ढ',
  'r': 'त',
  'n': 'द',
  'u': 'न',
  'i': 'प',
  'Q': 'फ',
  'c': 'ब',
  '\u{d2}': 'भ',
  '\u{90}': 'भ',
  'e': 'म',
  ';': 'य',
  'j': 'र',
  'y': 'ल',
  'G': 'ळ',
  'o': 'व',
  'l': 'स',
  'g': 'ह',
  'D': 'क\u{94d}',
  '[': 'ख\u{94d}',
  'X': 'ग\u{94d}',
  '?': 'घ\u{94d}',
  'P': 'च\u{94d}',
  'T': 'ज\u{94d}',
  '\u{f7}': 'झ\u{94d}',
  '\u{d6}': 'झ\u{94d}',
  '.': 'ण\u{94d}',
  'R': 'त\u{94d}',
  'F': 'थ\u{94d}',
  '/': 'ध\u{94d}',
  '\u{cb}': 'ध\u{94d}',
  '\u{e8}': 'ध\u{94d}',
  'U': 'न\u{94d}',
  'I': 'प\u{94d}',
  '\u{b6}': 'फ\u{94d}',
  'C': 'ब\u{94d}',
  'H': 'भ\u{94d}',
  'E': 'म\u{94d}',
  '\u{b8}': 'य\u{94d}',
  '\u{da}': 'र\u{94d}',
  'Y': 'ल\u{94d}',
  'O': 'व\u{94d}',
  "'": 'श\u{94d}',
  '\u{dc}': 'श\u{94d}',
  '\u{201c}': 'श\u{94d}',
  '\u{201d}': 'श\u{94d}',
  '"': 'ष\u{94d}',
  '\u{2018}': 'ष\u{94d}',
  '\u{2019}': 'ष\u{94d}',
  'L': 'स\u{94d}',
  '\u{ba}': 'ह\u{94d}',
  '{': 'क\u{94d}ष\u{94d}',
  'K': 'ज\u{94d}ञ',
  'J': 'श\u{94d}र',
  '=': 'त\u{94d}र',
  '\u{ab}': 'त\u{94d}र\u{94d}',
  '\u{d8}': 'क\u{94d}र',
  '\u{e7}': 'प\u{94d}र',
  '\u{c1}': 'प\u{94d}र',
  '\u{dd}': 'फ\u{94d}र',
  '\u{e6}': 'द\u{94d}र',
  '\u{a3}': 'ख\u{94d}र',
  ')': 'द\u{94d}ध',
  '|': 'द\u{94d}य',
  '}': 'द\u{94d}व',
  '\u{e4}': 'क\u{94d}त',
  '\u{f4}': 'क\u{94d}क',
  '\u{e9}': 'न\u{94d}न',
  '\u{2122}': 'न\u{94d}न\u{94d}',
  '\u{d9}': 'त\u{94d}त\u{94d}',
  '\u{178}': 'त\u{94d}त\u{94d}',
  '\u{e0}': 'ह\u{94d}न',
  '\u{e1}': 'ह\u{94d}य',
  '\u{e3}': 'ह\u{94d}म',
  '\u{cc}': 'द\u{94d}द',
  '\u{ed}': 'द\u{94d}द',
  '\u{cd}': 'ट\u{94d}ट',
  '\u{ea}': 'ट\u{94d}ट',
  '\u{ce}': 'ट\u{94d}ठ',
  '\u{eb}': 'ट\u{94d}ठ',
  '\u{f0}': 'ठ\u{94d}ठ',
  '\u{cf}': 'ड\u{94d}ड',
  '\u{ec}': 'ड\u{94d}ड',
  '\u{d4}': 'ड\u{94d}ढ',
  '\u{ef}': 'ड\u{94d}ढ',
  '\u{f3}': 'स\u{94d}त\u{94d}र',
  '\u{f9}': 'द\u{94d}म',
  '\u{2dc}': 'द\u{94d}भ',
  '\u{f6}': 'द\u{94d}भ',
  '#': 'रु',
  ':': 'रू',
  '\u{2014}': 'कृ',
  '\u{d1}': 'कृ',
  '\u{2013}': 'दृ',
  '\u{e2}': 'हृ',
  'z': '\u{94d}र',
  '\u{aa}': '\u{94d}र',
  '\u{d3}': '\u{94d}य',
  '\u{ee}': '\u{94d}य',
  '~': '\u{94d}',
  'k': 'ा',
  'f': _ikar,
  'h': 'ी',
  'q': 'ु',
  'w': 'ू',
  '`': 'ृ',
  '\u{a4}': 'ॄ',
  '\u{a7}': 'ॄ',
  's': 'े',
  '\u{a2}': 'े',
  'S': 'ै',
  '\u{a8}': 'ाे',
  '\u{ae}': 'ाे',
  '\u{a9}': 'ाै',
  'W': 'ॅ',
  '\u{201a}': 'ाॅ',
  'a': 'ं',
  '\u{a1}': 'ँ',
  '+': '\u{93c}',
  '\u{b7}': 'ऽ',
  '\u{2219}': 'ऽ',
  'Z': _reph,
  '\u{b1}': '$_rephं',
  '\u{c6}': _ikarReph,
  '\u{c7}': _ikarAnus,
  '\u{c9}': _ikarRephAnus,
  '\u{c8}': 'ीं',
  '\u{ca}': 'ी$_reph',
  '\u{203a}': 'ै$_rephं',
  '\u{f5}': 'ै$_rephं',
  '\u{e5}': '०',
  '\u{152}': '०',
  '\u{192}': '१',
  '\u{201e}': '२',
  '\u{2026}': '३',
  '\u{2020}': '४',
  '\u{2021}': '५',
  '\u{2c6}': '६',
  '\u{2030}': '७',
  '\u{160}': '८',
  '\u{2039}': '९',
  'A': '।',
  '-': '.',
  '&': '-',
  ']': ',',
  '(': ';',
  r'\': '?',
  '@': '/',
  r'$': '+',
  '^': '\u{2018}',
  '*': '\u{2019}',
  '\u{df}': '\u{201c}',
  '\u{de}': '\u{201d}',
  '\u{bc}': '(',
  '\u{bd}': ')',
  '\u{be}': '=',
  '\u{bf}': '{',
  '\u{f8}': '{',
  '\u{c0}': '}',
  '\u{bb}': '\u{f7}',
  '\u{f1}': '॰',
  '\u{db}': '\u{2022}',
};

/// DevLys 010 draws two of Kruti Dev 010's quote slots differently and leaves three blank.
final Map<String, String> _devlys = {
  ..._table,
  '\u{2019}': 'श्',
  '\u{201c}': 'भ',
  '\u{90}': '',
  '\u{2018}': '',
  '\u{201d}': '',
};

final RegExp _keys = RegExp(
  (_table.keys.toList()..sort((a, b) => b.length - a.length))
      .map(RegExp.escape)
      .join('|'),
);

final List<(RegExp, String)> _cleanup = [
  (
    RegExp(
      r'\s+(?=[ऀ-ःऺ-\u094d॑-ॗॢॣ]|'
      '$_reph)',
    ),
    '',
  ),
  (
    RegExp(
      '([$_ikar$_ikarAnus$_ikarReph$_ikarRephAnus'
      r'])\s+',
    ),
    r'$1',
  ),
  (RegExp('इ$_reph'), 'ई'),
  (
    RegExp('$_reph([ािीुूृॄेैोौॅॉंँ]+)'),
    r'$1'
        '$_reph',
  ),
  (RegExp('([ंँ]+)([ाीुूृॄेैोौॉ]+)'), r'$2$1'),
  (RegExp('ॅा'), 'ाॅ'),
  (RegExp(r'\u094d\u093c'), '\u{93c}\u{94d}'),
  (RegExp(r'\u094d\u094dरा'), '\u{94d}र'),
  (RegExp(r'\u094d\u094d'), '\u{94d}'),
  (RegExp(r'\u094dा'), ''),
  (RegExp('ॅं'), 'ँ'),
  (RegExp('ाे'), 'ो'),
  (RegExp('ाै'), 'ौ'),
  (RegExp('ाॅ'), 'ॉ'),
  (RegExp('ाा'), 'ा'),
  (RegExp('ंं+'), 'ं'),
  (RegExp('अा'), 'आ'),
  (RegExp('अो'), 'ओ'),
  (RegExp('अौ'), 'औ'),
  (RegExp('[अआ]ॉ|आॅ'), 'ऑ'),
  (RegExp('एे'), 'ऐ'),
];

/// cp1252's characters for the bytes 0x80-0x9F, where some PDFs and clipboards leave them raw.
const List<int?> _cp1252 = [
  0x20ac,
  null,
  0x201a,
  0x0192,
  0x201e,
  0x2026,
  0x2020,
  0x2021,
  0x02c6,
  0x2030,
  0x0160,
  0x2039,
  0x0152,
  null,
  0x017d,
  null,
  null,
  0x2018,
  0x2019,
  0x201c,
  0x201d,
  0x2022,
  0x2013,
  0x2014,
  0x02dc,
  0x2122,
  0x0161,
  0x203a,
  0x0153,
  null,
  0x017e,
  0x0178,
];

const _cons = '[\u{915}-\u{939}\u{958}-\u{95f}]';
final RegExp _cluster = RegExp('$_cons\u{93c}?(?:\u{94d}$_cons\u{93c}?)*');
const _post = 'ािीुूृॄेैोौॅॉंँ\u{93c}';

/// '%' draws both the visarga and the colon; a word-final visarga stays only in these words.
final RegExp _visargaWords = RegExp(
  r'^(?:अतः|पुनः|प्रायः|क्रमशः|वस्तुतः|नमः|.*[^िु]तः)$',
);
final RegExp _finalVisarga = RegExp('[ऀ-ॿ]+ः(?![ऀ-ॿ])');

bool _isDevanagari(int c) => c >= 0x900 && c <= 0x97f;

bool _isCons(String ch) {
  final c = ch.codeUnitAt(0);
  return (c >= 0x915 && c <= 0x939) || (c >= 0x958 && c <= 0x95f);
}

String _normalise(String s) {
  final out = StringBuffer();
  for (var o in s.runes) {
    if (o >= 0xf020 && o <= 0xf0ff) o -= 0xf000;
    if (o >= 0x80 && o <= 0x9f && o != 0x90) o = _cp1252[o - 0x80] ?? o;
    out.writeCharCode(o);
  }
  return out.toString();
}

String _tokenise(String s, Map<String, String> table) {
  final out = StringBuffer();
  var last = '';
  var i = 0;
  while (i < s.length) {
    final m = s[i] == '%' ? null : _keys.matchAsPrefix(s, i);
    if (s[i] == '%') {
      // A visarga after Devanagari, else a colon ("10%30").
      last = last.isNotEmpty && _isDevanagari(last.codeUnitAt(last.length - 1))
          ? 'ः'
          : ':';
      i++;
    } else if (m != null) {
      last = table[m[0]]!;
      i = m.end;
    } else {
      last = s[i];
      i++;
    }
    out.write(last);
  }
  return out.toString();
}

String _placeIkar(String s) {
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final ikar = _ikars[s[i]];
    if (ikar == null) {
      out.write(s[i]);
      i++;
      continue;
    }
    final m = _cluster.matchAsPrefix(s, i + 1);
    if (m == null) {
      out.write(ikar); // a stray 'f' with no consonant after it
      i++;
    } else {
      out
        ..write(m[0])
        ..write(ikar);
      i = m.end;
    }
  }
  return out.toString();
}

String _placeReph(String text) {
  var s = text;
  var p = s.indexOf(_reph);
  while (p != -1) {
    var k = p;
    while (k > 0 && _post.contains(s[k - 1])) {
      k--;
    }
    if (k > 0 && _isCons(s[k - 1])) {
      k--;
      while (true) {
        if (k >= 2 && s[k - 1] == '\u{94d}' && _isCons(s[k - 2])) {
          k -= 2;
        } else if (k >= 3 &&
            s[k - 1] == '\u{94d}' &&
            s[k - 2] == '\u{93c}' &&
            _isCons(s[k - 3])) {
          k -= 3;
        } else {
          break;
        }
      }
    }
    s = '${s.substring(0, k)}र\u{94d}${s.substring(k, p)}${s.substring(p + 1)}';
    p = s.indexOf(_reph);
  }
  return s;
}

/// Kruti Dev 010 text ([devlys]: DevLys 010) as Unicode Devanagari. Only text known or detected to be in the legacy
/// font goes here: English letters would be converted too.
String krutidevToUnicode(String legacy, {bool devlys = false}) {
  var s = _tokenise(_normalise(legacy), devlys ? _devlys : _table);
  for (final (rx, template) in _cleanup) {
    s = s.replaceAllMapped(
      rx,
      (m) => template.replaceAllMapped(
        RegExp(r'\$(\d)'),
        (g) => m[int.parse(g[1]!)] ?? '',
      ),
    );
  }
  s = _placeReph(_placeIkar(s));
  s = s.replaceAllMapped(
    _finalVisarga,
    (m) => _visargaWords.hasMatch(m[0]!)
        ? m[0]!
        : '${m[0]!.substring(0, m[0]!.length - 1)}:',
  );
  // NFC: the only canonical compositions in Devanagari (the nukta letters U+0958-095F are composition exclusions).
  return s
      .replaceAll('न\u{93c}', '\u{929}')
      .replaceAll('र\u{93c}', '\u{931}')
      .replaceAll('ळ\u{93c}', '\u{934}');
}

/// Common Hindi words as Kruti Dev types them: के, को, की, पर, है, का, में, हैं, किया, से, और, नहीं ...
const _stopwords = {
  'ds',
  'dks',
  'dh',
  'ij',
  'gS',
  'dk',
  'esa',
  'gSa',
  'fd;k',
  'ls',
  'vkSj',
  'ugha', //
  'x;k',
  'fd',
  'gh',
  'Fkk',
  'Fkh',
  'Hkh',
  '}kjk',
  'djus',
  'dj',
  'tkus',
  ';g',
  'rks', //
  'bl',
  'og',
  'vuqlkj',
  'gks',
  'fd;s',
  'dksbZ',
  'rd',
  'mDr',
  'xbZ',
  'rFkk',
  'vFkok', //
};
final RegExp _edges = RegExp(r'^[\]A%&\-()¼½,.\d]+|[\]A%&\-()¼½,]+$');
final RegExp _latin = RegExp('[A-Za-z]');
final RegExp _devanagari = RegExp('[ऀ-ॿ]');
// Kruti Dev letters that are ASCII punctuation next to a letter, or Latin-1 and cp1252 symbols.
final RegExp _symbols = RegExp(
  r'''[A-Za-z][;'"/{}\[\]|=~`]|[;'"/{}\[\]|=~`][A-Za-z]|[¡-ÿŒ-ƒ–-›™]''',
);

/// Whether [text] reads as Hindi typed in Kruti Dev rather than English or romanised Hindi. It needs a paragraph
/// (about 200 characters); with under 20 Latin letters, or real Devanagari in it, the answer is no.
bool looksLikeKrutidev(String text) {
  final latin = _latin.allMatches(text).map((m) => m[0]!).toList();
  final devanagari = _devanagari.allMatches(text).length;
  if (latin.length < 20 || devanagari > 0.2 * (devanagari + latin.length)) {
    return false;
  }
  final words = [
    for (final w in text.split(RegExp(r'\s+')))
      if (w.replaceAll(_edges, '') case final t when t.isNotEmpty) t,
  ];
  final n = words.isEmpty ? 1 : words.length;
  final stop = words.where(_stopwords.contains).length / n;
  final symbols = words.where(_symbols.hasMatch).length / n;
  double share(String c) => latin.where((l) => l == c).length / latin.length;
  return stop >= 0.12 ||
      (share('k') >= 0.10 &&
          share('e') <= 0.09 &&
          share('a') <= 0.12 &&
          (symbols >= 0.05 || stop >= 0.03));
}
