import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/features/case_page/case_page_text.dart';
import 'package:advocate_app/features/case_page/client_tab.dart';
import 'package:advocate_app/ui/status_pill.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../fakes.dart';

/// The case page's pure rules and text (spec §4.3, §5.10).
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final hi = lookupAppLocalizations(const Locale('hi'));
  const enL = Locale('en');
  const hiL = Locale('hi');
  final today = DateTime.utc(2026, 11, 5);

  setUpAll(() async {
    await initializeDateFormatting('en_IN');
    await initializeDateFormatting('hi');
  });

  test('a ?tab= name picks the tab; anything else is the timeline', () {
    expect(CaseTab.of('notes'), CaseTab.notes);
    expect(CaseTab.of('client'), CaseTab.client);
    expect(CaseTab.of('brief'), CaseTab.timeline);
    expect(CaseTab.of(null), CaseTab.timeline);
  });

  test('pills: Listed today or tomorrow, Disposed, New order', () {
    List<PillKind> pills(CaseInfo c, {bool newOrder = false}) =>
        casePills(c, today, newOrder: newOrder);
    expect(pills(caseInfo(1, nextDate: today)), [PillKind.listed]);
    expect(pills(caseInfo(1, nextDate: DateTime.utc(2026, 11, 6))), [
      PillKind.listed,
    ]);
    expect(pills(caseInfo(1, nextDate: DateTime.utc(2026, 11, 7))), isEmpty);
    expect(pills(caseInfo(1, nextDate: DateTime.utc(2026, 11, 4))), isEmpty);
    expect(
      pills(
        caseInfo(1, courtStatus: 'disposed', nextDate: today),
        newOrder: true,
      ),
      [PillKind.disposed, PillKind.newOrder],
    );
    // Transferred says so in the status line, not with the Disposed pill.
    expect(pills(caseInfo(1, courtStatus: 'transferred')), isEmpty);
  });

  test('status line: court status, archived, where the data comes from', () {
    expect(
      caseStatusLine(en, enL, caseInfo(1, status: 'archived'), today),
      'Pending · Archived · Updated Wed, 4 Nov, 7:42 pm from the official record',
    );
    expect(
      caseStatusLine(
        en,
        enL,
        caseInfo(1, courtFetchedAt: DateTime.utc(2026, 11, 5, 3)),
        today,
      ),
      'Pending · Updated 8:30 am from the official record',
    );
    expect(
      caseStatusLine(hi, hiL, caseInfo(1, tracking: 'manual'), today),
      '${hi.foundPending} · ${hi.casesManualCase}',
    );
  });

  test('timeline dates: "28 Oct 2026" / "28 अक्टूबर 2026"', () {
    final d = DateTime.utc(2026, 10, 28);
    expect(timelineDate(enL, d), '28 Oct 2026');
    expect(timelineDate(hiL, d), '28 अक्टूबर 2026');
  });

  group('hearings', () {
    test("the court value wins; the user's shows where it differs", () {
      final h = CaseHearing(
        id: 'h',
        date: DateTime.utc(2026, 10, 28),
        courtNo: '12',
        itemNo: '7',
        purpose: 'Arguments',
        userPurpose: 'Final arguments',
        outcome: 'Adjourned',
        userOutcome: 'Adjourned',
        nextDate: today,
        userNextDate: DateTime.utc(2026, 11, 6),
        userNote: 'Bring the paper book',
      );
      expect(hearingTitle(en, h), 'Hearing · Arguments');
      expect(hearingLines(en, enL, h), [
        'You noted: Final arguments',
        'Court 12 · Item 7',
        'Outcome: Adjourned',
        'Next date: Thu, 5 Nov 2026',
        'You noted: Fri, 6 Nov 2026',
        'Note: Bring the paper book',
      ]);
    });

    test("without court values the user's show plainly", () {
      final h = CaseHearing(
        id: 'h',
        date: today,
        userPurpose: 'Evidence',
        userNextDate: DateTime.utc(2026, 11, 20),
      );
      expect(hearingTitle(hi, h), '${hi.casePageHearing} · Evidence');
      expect(hearingLines(en, enL, h), ['Next date: Fri, 20 Nov 2026']);
      expect(hearingLines(en, enL, CaseHearing(id: 'x', date: today)), isEmpty);
    });
  });

  test('task due: an IST day, with a time unless midnight', () {
    final day = DateTime(2026, 11, 6);
    expect(taskDueAt(day), DateTime.utc(2026, 11, 5, 18, 30));
    expect(taskDueAt(day, hour: 11, minute: 30), DateTime.utc(2026, 11, 6, 6));
    expect(taskDueText(enL, taskDueAt(day)), 'Fri, 6 Nov 2026');
    expect(
      taskDueText(enL, taskDueAt(day, hour: 17, minute: 45)),
      'Fri, 6 Nov 2026, 5:45 pm',
    );
    expect(
      taskDueText(hiL, taskDueAt(day, hour: 17, minute: 45)),
      'शुक्र, 6 नवंबर 2026, शाम 5:45',
    );
  });

  test('documents: kind, size and why one cannot open', () {
    expect(fileSizeText(1000), '1 KB');
    expect(fileSizeText(245760), '240 KB');
    expect(fileSizeText(2516582), '2.4 MB');
    expect(
      documentLine(
        en,
        const CaseDocument(
          id: 'd',
          title: 't',
          kind: 'pleading',
          sizeBytes: 2516582,
        ),
      ),
      'Pleadings · 2.4 MB',
    );
    expect(
      documentLine(
        hi,
        const CaseDocument(id: 'd', title: 't', uploadStatus: 'quarantined'),
      ),
      '${hi.casesDocOther} · ${hi.casePageDocQuarantined}',
    );
    expect(
      documentLine(
        en,
        const CaseDocument(id: 'd', title: 't', uploadStatus: 'pending'),
      ),
      'Other · ${en.casePageDocChecking}',
    );
  });

  test('client language labels', () {
    expect(clientLanguageLabel(en, 'hi'), 'Hindi');
    expect(clientLanguageLabel(hi, 'en'), hi.casePageLangEn);
    expect(clientLanguageLabel(en, null), isNull);
  });
}
