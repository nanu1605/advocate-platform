import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/case_text.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/order_summary.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import '../helpers.dart';

/// The Cases list and case page rules (spec §4.3) as pure functions.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('en_IN');
    await initializeDateFormatting('hi');
  });

  final today = DateTime.utc(2026, 11, 5); // testNow's IST day
  DateTime day(int d) => DateTime.utc(2026, 11, d);

  group('next date', () {
    test('the court date for auto and off; the next hearing for manual', () {
      final court = day(12);
      final hearing = day(9);
      expect(
        nextDateOf(
          tracking: 'auto',
          today: today,
          courtNext: court,
          manualNext: hearing,
        ),
        court,
      );
      expect(
        nextDateOf(tracking: 'off', today: today, courtNext: court),
        court,
      );
      expect(
        nextDateOf(
          tracking: 'manual',
          today: today,
          courtNext: court,
          manualNext: hearing,
        ),
        hearing,
      );
      expect(
        nextDateOf(tracking: 'manual', today: today, courtNext: court),
        isNull,
      );
    });

    test('a court date already past is no next date; today still is', () {
      expect(
        nextDateOf(tracking: 'auto', today: today, courtNext: day(2)),
        isNull,
      );
      expect(
        nextDateOf(tracking: 'off', today: today, courtNext: day(4)),
        isNull,
      );
      expect(
        nextDateOf(tracking: 'auto', today: today, courtNext: today),
        today,
      );
    });
  });

  group('sections', () {
    CaseSection of(CaseInfo c) => sectionOf(c, today);

    test('by next date in IST days', () {
      expect(of(caseInfo(1, nextDate: day(5))), CaseSection.today);
      expect(of(caseInfo(1, nextDate: day(6))), CaseSection.thisWeek);
      expect(of(caseInfo(1, nextDate: day(11))), CaseSection.thisWeek);
      expect(of(caseInfo(1, nextDate: day(12))), CaseSection.later);
      expect(of(caseInfo(1, nextDate: day(4))), CaseSection.noNextDate);
      expect(of(caseInfo(1)), CaseSection.noNextDate);
    });

    test('disposed and transferred, then archived, win over dates', () {
      expect(
        of(caseInfo(1, nextDate: day(5), courtStatus: 'disposed')),
        CaseSection.disposed,
      );
      expect(of(caseInfo(1, courtStatus: 'transferred')), CaseSection.disposed);
      expect(
        of(
          caseInfo(
            1,
            nextDate: day(5),
            courtStatus: 'disposed',
            status: 'archived',
          ),
        ),
        CaseSection.archived,
      );
      // A manual case has no court status: pending.
      expect(
        of(caseInfo(1, tracking: 'manual', nextDate: day(5))),
        CaseSection.today,
      );
    });

    test('caseSections: in order, empty ones left out, archived only under the filter', () {
      final cases = [
        caseInfo(1, nextDate: day(20)),
        caseInfo(2, nextDate: day(5)),
        caseInfo(3, status: 'archived', nextDate: day(5)),
        caseInfo(4, courtStatus: 'disposed'),
        caseInfo(5, nextDate: day(7)),
      ];
      List<(CaseSection, String)> run(CaseFilter f) => [
        for (final s in caseSections(cases, f, today))
          (s.section, s.cases.map((c) => c.id).join(',')),
      ];
      expect(run(const CaseFilter()), [
        (CaseSection.today, 'm-2'),
        (CaseSection.thisWeek, 'm-5'),
        (CaseSection.later, 'm-1'),
        (CaseSection.disposed, 'm-4'),
      ]);
      expect(run(const CaseFilter(status: CaseStatusFilter.archived)), [
        (CaseSection.archived, 'm-3'),
      ]);
      expect(run(const CaseFilter(status: CaseStatusFilter.disposed)), [
        (CaseSection.disposed, 'm-4'),
      ]);
      expect(
        run(const CaseFilter(status: CaseStatusFilter.pending))
            .map((s) => s.$1),
        [CaseSection.today, CaseSection.thisWeek, CaseSection.later],
      );
    });
  });

  group('search', () {
    bool hit(CaseInfo c, String q) => CaseQuery(q).matches(c);

    test('transliteration both ways, on titles and client names', () {
      final english = caseInfo(1, title: 'Ramesh Sharma v. State of MP');
      final hindi = caseInfo(
        2,
        title: 'रमेश शर्मा बनाम म.प्र. राज्य',
        clients: [(id: 'cl-9', name: 'सुरेश पटेल')],
      );
      expect(hit(english, 'sharma'), isTrue);
      expect(hit(english, 'शर्मा'), isTrue);
      expect(hit(hindi, 'sharma'), isTrue);
      expect(hit(hindi, 'Suresh Patel'), isTrue);
      expect(hit(hindi, 'patel'), isTrue);
      expect(hit(english, 'verma'), isFalse);
      expect(hit(english, 'वर्मा'), isFalse);
      expect(hit(english, ''), isTrue);
    });

    test('case number, label and CNR, typed loosely', () {
      final c = caseInfo(7); // WP 1007/2024, MPHC010000000007
      expect(hit(c, '1007'), isTrue);
      expect(hit(c, 'wp 1007/2024'), isTrue);
      expect(hit(c, 'MPHC010000000007'), isTrue);
      expect(hit(c, 'mphc-0100 0000 0007'), isTrue);
      expect(hit(c, '1008'), isFalse);
      expect(hit(c, 'suresh'), isTrue); // its client
    });

    test('40 auto cases and 2 manual: "sharma" and "शर्मा" find the same '
        'ones, by section', () {
      final cases = [
        for (var n = 1; n <= 40; n++)
          caseInfo(
            n,
            title: n.isEven ? 'Gupta v. State of MP' : 'Verma v. Union',
            clients: [if (n == 7) (id: 'cl-7', name: 'राकेश शर्मा')],
            nextDate: day(5 + n % 10),
          ),
        caseInfo(
          41,
          tracking: 'manual',
          courtName: 'Family Court, Indore',
          title: 'Sunita Sharma v. Rajesh Sharma',
          nextDate: day(5),
        ),
        caseInfo(42, tracking: 'manual', title: 'रमेश शर्मा बनाम राज्य'),
      ];
      List<(CaseSection, String)> found(String q) => [
        for (final s in caseSections(cases, CaseFilter(query: q), today))
          for (final c in s.cases) (s.section, c.id),
      ];
      final expected = [
        (CaseSection.today, 'm-41'),
        (CaseSection.later, 'm-7'), // its client
        (CaseSection.noNextDate, 'm-42'),
      ];
      expect(found('sharma'), expected);
      expect(found('शर्मा'), expected);
      expect(found('Sharma '), expected);
    });

    test('search keys are built once per case, not per query', () {
      final c = caseInfo(1);
      expect(identical(c.searchKeys, c.searchKeys), isTrue);
    });

    test('clients by name (transliterated) or phone digits', () {
      const clients = [
        ClientInfo(id: 'a', name: 'Suresh Patel', phone: '98765 43210'),
        ClientInfo(id: 'b', name: 'नेहा वर्मा', searchKey: 'neh vrm'),
      ];
      List<String> ids(String q) => [
        for (final c in searchClients(clients, q)) c.id,
      ];
      expect(ids(''), ['a', 'b']);
      expect(ids('suresh'), ['a']);
      expect(ids('सुरेश'), ['a']);
      expect(ids('verma'), ['b']);
      expect(ids('543'), ['a']);
      expect(ids('xyz'), isEmpty);
    });
  });

  group('filters and sorts', () {
    final a = caseInfo(
      1,
      nextDate: day(9),
      assigneeId: 'user-2',
      updatedAt: DateTime.utc(2026, 10, 30),
    );
    final b = caseInfo(
      10,
      court: testCourts[3],
      nextDate: day(6),
      clients: [(id: 'cl-2', name: 'Neha Verma')],
      updatedAt: DateTime.utc(2026, 11, 4),
    );
    final c = caseInfo(
      2,
      caseNumber: '2',
      updatedAt: DateTime.utc(2026, 11, 3),
    );

    test('court, client and assignee', () {
      bool pass(CaseInfo x, CaseFilter f) => passesFilter(x, f);
      expect(pass(b, CaseFilter(courtId: testCourts[3].id)), isTrue);
      expect(pass(a, CaseFilter(courtId: testCourts[3].id)), isFalse);
      expect(pass(b, const CaseFilter(clientId: 'cl-2')), isTrue);
      expect(pass(a, const CaseFilter(clientId: 'cl-2')), isFalse);
      expect(pass(a, const CaseFilter(assigneeId: 'user-2')), isTrue);
      expect(pass(b, const CaseFilter(assigneeId: 'user-2')), isFalse);
    });

    test('copyWith clears with null and keeps what is left out', () {
      const f = CaseFilter(courtId: 'c1', assigneeId: 'u1', query: 'x');
      expect(f.copyWith(courtId: null).courtId, isNull);
      expect(f.copyWith(courtId: null).assigneeId, 'u1');
      expect(f.copyWith(sort: CaseSort.caseNumber).query, 'x');
      expect(f.filtering, isTrue);
      expect(const CaseFilter(query: 'x').filtering, isFalse);
    });

    test(
      'next date (undated last), recently updated, case number (numeric)',
      () {
        List<String> sorted(CaseSort s) =>
            ([a, b, c]..sort(caseComparator(s))).map((x) => x.id).toList();
        expect(sorted(CaseSort.nextDate), ['m-10', 'm-1', 'm-2']);
        expect(sorted(CaseSort.recentlyUpdated), ['m-10', 'm-2', 'm-1']);
        expect(sorted(CaseSort.caseNumber), ['m-2', 'm-1', 'm-10']);
        expect(compareNatural('WP 2/2024', 'WP 10/2024'), lessThan(0));
        expect(compareNatural('CRA 9/2025', 'WP 1/2020'), lessThan(0));
      },
    );
  });

  group('timeline', () {
    test('newest first; an order before the hearing it followed', () {
      final items = timelineOf(
        [
          CaseHearing(id: 'h1', date: day(1)),
          CaseHearing(id: 'h2', date: day(28 - 20)),
        ],
        [CaseOrder(id: 'o1', date: day(8)), const CaseOrder(id: 'o0')],
      );
      expect(
        items.map(
          (e) => switch (e) {
            CaseHearing(:final id) => id,
            CaseOrder(:final id) => id,
          },
        ),
        ['o1', 'h2', 'h1', 'o0'],
      );
    });

    test('court values win; differing user values are "you noted"', () {
      expect(courtWins('Admission', 'Final hearing'), (
        value: 'Admission',
        noted: 'Final hearing',
      ));
      expect(courtWins('Admission', 'Admission'), (
        value: 'Admission',
        noted: null,
      ));
      expect(courtWins(null, 'Final hearing'), (
        value: 'Final hearing',
        noted: null,
      ));
      expect(courtWins<DateTime>(day(12), day(14)).noted, day(14));
    });

    test('the next date purpose: that hearing, else the stage', () {
      final c = caseInfo(1, nextDate: day(12), stage: 'Arguments');
      expect(
        nextPurposeOf(c, [CaseHearing(id: 'h', date: day(1))]),
        'Arguments',
      );
      expect(
        nextPurposeOf(c, [
          CaseHearing(id: 'h', date: day(12), userPurpose: 'Reply'),
        ]),
        'Reply',
      );
      expect(
        nextPurposeOf(c, [
          CaseHearing(
            id: 'h',
            date: day(12),
            purpose: 'Admission',
            userPurpose: 'Reply',
          ),
        ]),
        'Admission',
      );
    });
  });

  group('text', () {
    final en = lookupAppLocalizations(const Locale('en'));
    final hi = lookupAppLocalizations(const Locale('hi'));
    const enL = Locale('en');
    const hiL = Locale('hi');

    test('where the data comes from', () {
      final fetched = caseInfo(1); // 7:42 pm IST on Wed 4 Nov
      expect(
        caseUpdatedText(en, enL, fetched, today: day(4)),
        en.updatedFromRecord('7:42 pm'),
      );
      expect(
        caseUpdatedText(en, enL, fetched, today: today),
        en.casesUpdatedOn('Wed, 4 Nov', '7:42 pm'),
      );
      expect(
        caseUpdatedText(hi, hiL, fetched),
        hi.casesUpdatedOn('बुध, 4 नवंबर', 'शाम 7:42'),
      );
      expect(
        caseUpdatedText(en, enL, caseInfo(1, tracking: 'manual')),
        en.casesManualCase,
      );
      expect(
        caseUpdatedText(en, enL, caseInfo(1, tracking: 'off')),
        en.casesTrackingOff,
      );
      final never = CaseInfo(id: 'm', cnr: 'MPHC010000000001');
      expect(caseUpdatedText(en, enL, never), en.casesAwaitingRecord);
    });

    test('share text: no title unless asked, never clients (en)', () {
      final c = caseInfo(1, nextDate: day(12), judge: 'Justice A');
      expect(
        caseShareText(en, enL, c, titles: false, purpose: 'Admission'),
        [
          'WP 1001/2024',
          'MPHC Indore · Court 12',
          'Next date: Thu, 12 Nov 2026 · Admission',
          'Status: Pending',
          'Updated Wed, 4 Nov, 7:42 pm from the official record',
        ].join('\n'),
      );
      final withTitle = caseShareText(en, enL, c, titles: true);
      expect(withTitle.split('\n').take(2), [
        'WP 1001/2024',
        'Sharma v. State of MP',
      ]);
      for (final text in [
        withTitle,
        caseShareText(en, enL, c, titles: false),
      ]) {
        expect(text, isNot(contains('Suresh')));
      }
    });

    test('share text in Hindi; disposed has no next date line', () {
      final c = caseInfo(1, courtStatus: 'disposed');
      expect(
        caseShareText(hi, hiL, c, titles: false),
        [
          'WP 1001/2024',
          'MPHC इंदौर · कोर्ट 12',
          'स्थिति: निराकृत',
          'आधिकारिक रिकॉर्ड से बुध, 4 नवंबर, शाम 7:42 पर अपडेट',
        ].join('\n'),
      );
      expect(
        caseShareText(hi, hiL, caseInfo(1), titles: false),
        contains(hi.casesNoNextDate),
      );
    });

    test('a manual case without a number shares its title only when asked', () {
      final c = caseInfo(
        1,
        tracking: 'manual',
        caseType: null,
        caseNumber: '',
        courtName: 'Family Court, Dewas',
        courtNo: null,
        title: 'Demo v. Demo',
        nextDate: day(20),
      );
      final off = caseShareText(en, enL, c, titles: false).split('\n');
      expect(off.take(2), [en.boardShareNoNumber, 'Family Court, Dewas']);
      expect(off.last, en.casesManualCase);
      expect(
        caseShareText(en, enL, c, titles: true).split('\n').first,
        'Demo v. Demo',
      );
    });

    test('labels for every section, sort, status filter and kind', () {
      for (final l in [en, hi]) {
        for (final s in CaseSection.values) {
          expect(caseSectionLabel(l, s), isNotEmpty);
        }
        for (final s in CaseSort.values) {
          expect(caseSortLabel(l, s), isNotEmpty);
        }
        for (final s in CaseStatusFilter.values) {
          expect(caseStatusFilterLabel(l, s), isNotEmpty);
        }
        expect({
          for (final k in documentKinds) documentKindLabel(l, k),
        }, hasLength(documentKinds.length));
        expect({
          for (final k in deadlineKinds) deadlineKindLabel(l, k),
        }, hasLength(deadlineKinds.length));
      }
    });
  });

  test("an order summary's points carry their pages, from its source ids", () {
    final s = OrderSummaryView.fromJson(const {
      'title': 'Order dated 28-10-2026',
      'court': 'MPHC Indore',
      'order_date': '2026-10-28',
      'judges': ['Justice A. B. Sharma'],
      'header_sources': ['S1'],
      'outcome': null,
      'gist': {
        'text': 'Notice issued.',
        'sources': ['S3', 'S1', 'S2'],
      },
      'directions': [
        {
          'text': 'File a reply.',
          'sources': ['S2', 'S9'], // S9 has no page: left out
          'who': 'the respondents',
          'by_when': 'within 4 weeks',
        },
      ],
      'next_date': {
        'date': '2026-12-02',
        'sources': ['S2'],
      },
      'relief': null,
      'key_reasons': [],
      'authorities_cited_in_document': [
        {
          'text': '(2019) 5 SCC 123',
          'sources': ['S3'],
        },
      ],
      'next_steps_for_us': [],
      // Two chunks of page 2 are two sources.
      'source_pages': {'S1': 1, 'S2': 2, 'S3': 2},
    });
    expect(
      (s.title, s.court, s.orderDate),
      ('Order dated 28-10-2026', 'MPHC Indore', DateTime.utc(2026, 10, 28)),
    );
    expect(s.judges, ['Justice A. B. Sharma']);
    expect(s.headerPages, [1]);
    expect(s.outcome, isNull);
    expect(s.gist?.pages, [1, 2]);
    final d = s.directions.single;
    expect(
      (d.text, d.who, d.byWhen),
      ('File a reply.', 'the respondents', 'within 4 weeks'),
    );
    expect(d.pages, [2]);
    expect(s.nextDate, DateTime.utc(2026, 12, 2));
    expect(s.nextDatePages, [2]);
    expect(s.authorities.single.pages, [2]);
    expect(s.relief, isNull);
    expect([...s.keyReasons, ...s.nextSteps], isEmpty);
  });
}
