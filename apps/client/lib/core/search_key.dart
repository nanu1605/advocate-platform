/// Search keys for Hindi/English transliteration search (spec §4.3, §9.1):
/// "Sharma" and "शर्मा" get the same key.
///
/// Same algorithm as `packages/shared/src/advocate_shared/search_key.py`,
/// which explains it; both are tested against
/// `config/fixtures/translit_pairs.yaml`, so change them together.
library;

// dart format off
const _consonants = {
  'क': 'k', 'ख': 'kh', 'ग': 'g', 'घ': 'gh', 'ङ': 'n',
  'च': 'ch', 'छ': 'chh', 'ज': 'j', 'झ': 'jh', 'ञ': 'n',
  'ट': 't', 'ठ': 'th', 'ड': 'd', 'ढ': 'dh', 'ण': 'n',
  'त': 't', 'थ': 'th', 'द': 'd', 'ध': 'dh', 'न': 'n',
  'प': 'p', 'फ': 'ph', 'ब': 'b', 'भ': 'bh', 'म': 'm',
  'य': 'y', 'र': 'r', 'ल': 'l', 'ळ': 'l', 'व': 'v',
  'श': 'sh', 'ष': 'sh', 'स': 's', 'ह': 'h',
  // precomposed nukta letters
  '\u0958': 'k', '\u0959': 'kh', '\u095a': 'g', '\u095b': 'j',
  '\u095c': 'r', '\u095d': 'rh', '\u095e': 'ph', '\u095f': 'y',
};
const _nuktaConsonants = {'ड': 'r', 'ढ': 'rh'};
const _matras = {
  'ा': 'a', 'ि': 'i', 'ी': 'i', 'ु': 'u', 'ू': 'u', 'ृ': 'ri',
  'े': 'e', 'ै': 'ai', 'ो': 'o', 'ौ': 'au', 'ॅ': 'e', 'ॉ': 'o',
};
final Map<String, String> _signs = {
  'अ': 'a', 'आ': 'a', 'इ': 'i', 'ई': 'i', 'उ': 'u', 'ऊ': 'u', 'ऋ': 'ri',
  'ए': 'e', 'ऐ': 'ai', 'ओ': 'o', 'औ': 'au', 'ऍ': 'e', 'ऑ': 'o',
  'ं': 'n', 'ँ': 'n', '\u0903': '', 'ऽ': '', '\u093c': '', '\u200c': '', '\u200d': '',
  for (var d = 0; d < 10; d++) String.fromCharCode(0x966 + d): '$d',
};
// dart format on
const _virama = '्';
const _nukta = '\u093c';

final _rules = [
  (RegExp('qui'), 'ki'),
  (RegExp('q'), 'k'),
  (RegExp('x'), 'ks'),
  (RegExp('z'), 'j'),
  (RegExp('w'), 'v'),
  (RegExp('ph'), 'f'),
  (RegExp('ngh'), 'n'),
  (RegExp('m(?=[bp])'), 'n'),
  (RegExp('(?<=[bcdfgjklmnpqrstvxyz])h+'), ''),
  (RegExp('e(?=r[bcdfgjklmnpqstvxyz])'), 'a'),
  (RegExp('ee'), 'i'),
  (RegExp('oo'), 'u'),
  (RegExp('ai'), 'e'),
  (RegExp('[ao]u'), 'o'),
  (RegExp(r'ey$'), 'e'),
  (RegExp(r'(?<=[bcdfghjklmnpqrstvxz])y$'), 'i'),
  (RegExp(r'ore$'), 'or'),
  (RegExp(r'(.)(?=\1)'), ''),
  (RegExp('a'), ''),
];

/// The normalised Latin phonetic key stored in `search_key` columns and
/// computed for every search query.
String searchKey(String text) =>
    _romanise(text)
        .toLowerCase()
        .split(RegExp('[^a-z0-9]+'))
        .map(_fold)
        .where((k) => k.isNotEmpty)
        .join(' ');

String _romanise(String input) {
  final text = input.replaceAll('ज्ञ', 'ग्य');
  String at(int i) => i < text.length ? text[i] : '';
  final out = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    var latin = _consonants[c];
    if (latin == null) {
      out.write(_signs[c] ?? c);
      continue;
    }
    if (at(i + 1) == _nukta) {
      latin = _nuktaConsonants[c] ?? latin;
      i++;
    }
    final next = at(i + 1);
    final matra = _matras[next];
    out.write(latin + (matra ?? (next == _virama ? '' : 'a')));
    if (matra != null || next == _virama) i++;
  }
  return out.toString();
}

String _fold(String word) {
  if (word.contains(RegExp('[0-9]'))) return word;
  return _rules.fold(word, (w, rule) => w.replaceAll(rule.$1, rule.$2));
}
