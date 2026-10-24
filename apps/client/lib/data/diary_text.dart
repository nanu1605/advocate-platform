/// Diary text shared by Today and Tomorrow's Board, so both say the same thing in both languages.
library;

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/diary.dart';
import 'package:flutter/widgets.dart';

/// "WP 1234 of 2024" for screen readers, which otherwise read "1234/2024" as a fraction.
String spokenCaseLabel(AppLocalizations l, String caseLabel) {
  final m = RegExp(r'^(.+)/(\d{4})$').firstMatch(caseLabel);
  return m == null ? caseLabel : l.diaryCaseOfYear(m[1]!, m[2]!);
}

/// "Court 12, item 23", "Court 12" or "Item 23"; null when neither is known yet.
String? positionText(AppLocalizations l, DiaryEntry e) =>
    switch ((e.courtNo, e.itemNo)) {
      (final c?, final i?) => l.diaryCourtItem(c, i),
      (final c?, null) => l.courtNo(c),
      (null, final i?) => l.itemNo(i),
      (null, null) => null,
    };

/// A diary row for screen readers (spec §5.9): "WP 1234 of 2024. MP High Court Indore. Court 12, item 23. Clash."
/// It says what the row shows: no item number yet (spec §5.4), and a proxy arranged.
String diaryRowLabel(AppLocalizations l, Locale locale, DiaryEntry e) {
  final stop = locale.languageCode == 'hi' ? '।' : '.';
  return [
    spokenCaseLabel(l, e.caseLabel),
    ?e.court?.spokenLabel(locale, l.highCourt),
    ?positionText(l, e),
    if (e.itemNo == null) l.todayNoItem,
    if (e.clash) l.statusClash,
    if (e.proxyArranged) l.boardProxyArranged,
  ].map((s) => '$s$stop').join(' ');
}

/// Why [e] clashes (spec §4.2): the other cases and courts with their estimated times, and that the times are
/// estimates. Null when it doesn't clash. [day] is the diary it belongs to.
String? clashExplanation(
  AppLocalizations l,
  Locale locale,
  DiaryEntry e,
  List<DiaryEntry> day,
) {
  if (e.clashWith.isEmpty) return null;
  final f = Formats(locale);
  return l.diaryClashExplain(
    [
      for (final o in day)
        if (e.clashWith.contains(o.matterId))
          l.diaryClashOther(
            o.caseLabel,
            o.court?.label(locale) ?? '—',
            // A clash needs both slots.
            f.time(DateTime.utc(2000).add(o.slot!)),
          ),
    ].join(', '),
  );
}
