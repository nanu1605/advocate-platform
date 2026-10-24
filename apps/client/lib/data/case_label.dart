/// "WP 1234/2024": case type, number and year (Latin script in both languages, Appendix C); the CNR when there
/// is no case number; '' when there is neither.
String caseLabelOf({
  String? caseType,
  String? caseNumber,
  int? caseYear,
  String? cnr,
}) {
  final number = caseNumber ?? '';
  if (number.isEmpty) return cnr ?? '';
  return [
    if ((caseType ?? '').isNotEmpty) caseType,
    if (caseYear == null) number else '$number/$caseYear',
  ].join(' ');
}
