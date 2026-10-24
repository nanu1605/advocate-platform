import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/diary.dart';
import 'package:advocate_app/features/board/board_share.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../helpers.dart';

/// Shared board text (spec §4.2 AC "the shared text reads correctly in Hindi and English", §13.2 minimum content).
void main() {
  setUpAll(() async {
    await initializeDateFormatting('en');
    await initializeDateFormatting('hi');
  });
  final day = DateTime.utc(2026, 11, 6);
  final district = testCourts[3];
  final board = [
    diaryEntry(2, courtNo: '7', item: 41, assigneeName: 'Neha Verma'),
    diaryEntry(1, item: 23),
    diaryEntry(3, court: district, courtNo: '5', item: 8),
    // A manual case with no number or CNR: its label is its title (party names).
    DiaryEntry(
      matterId: 'm-9',
      caseLabel: 'Gupta v. Jain',
      title: 'Gupta v. Jain',
      courtId: district.id,
      court: district,
      courtNo: '5',
      client: 'Anil Gupta',
      tracking: 'manual',
    ),
  ];
  String text(String locale, List<DiaryEntry> entries, {bool titles = false}) =>
      boardShareText(
        lookupAppLocalizations(Locale(locale)),
        Locale(locale),
        day,
        entries,
        titles: titles,
        note: entries.boardBuilt ? null : 'NOTE',
      );

  test('English: case numbers and court positions only', () {
    expect(
      text('en', board),
      "Tomorrow's board · Fri, 6 Nov\n"
      'MPHC Indore\n'
      '• WP 1002/2024 — Court 7, item 41\n'
      '• WP 1001/2024 — Court 12, item 23\n'
      '\n'
      'District Court Indore\n'
      '• WP 1003/2024 — Court 5, item 8\n'
      '• Case without a number — Court 5',
    );
  });

  test('Hindi: court Hindi, Latin case numbers', () {
    expect(
      text('hi', board),
      'कल का बोर्ड · शुक्र, 6 नवंबर\n'
      'MPHC इंदौर\n'
      '• WP 1002/2024 — कोर्ट 7, आइटम 41\n'
      '• WP 1001/2024 — कोर्ट 12, आइटम 23\n'
      '\n'
      'जिला कोर्ट इंदौर\n'
      '• WP 1003/2024 — कोर्ट 5, आइटम 8\n'
      '• बिना नंबर का केस — कोर्ट 5',
    );
  });

  test('titles only when opted in; never clients or assignees', () {
    for (final locale in ['en', 'hi']) {
      final off = text(locale, board);
      final on = text(locale, board, titles: true);
      expect(off, isNot(contains('Sharma v. State of MP')));
      expect(off, isNot(contains('Gupta v. Jain')));
      expect(on, contains('• WP 1001/2024 — '));
      expect(on, contains('\n  Sharma v. State of MP\n'));
      expect(on, contains('• Gupta v. Jain — '));
      for (final s in [on, off]) {
        for (final secret in ['Suresh Patel', 'Anil Gupta', 'Neha Verma']) {
          expect(s, isNot(contains(secret)), reason: '$locale $secret');
        }
      }
    }
    expect(
      text('en', board.take(1).toList(), titles: true),
      "Tomorrow's board · Fri, 6 Nov\n"
      'MPHC Indore\n'
      '• WP 1002/2024 — Court 7, item 41\n'
      '  Sharma v. State of MP',
    );
  });

  test('before the board is built: positions known so far, then the note', () {
    expect(
      text('en', [diaryEntry(4, boarded: false)]),
      "Tomorrow's board · Fri, 6 Nov\n"
      'MPHC Indore\n'
      '• WP 1004/2024 — Court 12\n'
      '\n'
      'NOTE',
    );
    expect(
      text('hi', [diaryEntry(4, boarded: false, courtNo: null)]),
      'कल का बोर्ड · शुक्र, 6 नवंबर\nMPHC इंदौर\n• WP 1004/2024\n\nNOTE',
    );
  });

  test('empty board', () {
    expect(
      boardShareText(
        lookupAppLocalizations(const Locale('en')),
        const Locale('en'),
        day,
        const [],
        titles: false,
      ),
      "Tomorrow's board · Fri, 6 Nov\nNothing listed for tomorrow",
    );
  });
}
