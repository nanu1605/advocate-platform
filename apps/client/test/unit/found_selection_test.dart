import 'package:advocate_app/data/courts.dart';
import 'package:advocate_app/data/found_cases.dart';
import 'package:advocate_app/features/found_cases/add_by_cnr.dart';
import 'package:advocate_app/features/found_cases/found_selection.dart';
import 'package:advocate_app/ui/selectable_row.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _indore = 'c-indore';
const _district = 'c-district';
const _supreme = 'c-supreme';

/// The courts provider's order: High Courts, district courts, then the Supreme Court.
const _courts = [
  Court(id: _indore, level: 'HC', name: '', shortName: 'MPHC Indore'),
  Court(
    id: _district,
    level: 'DC',
    name: '',
    shortName: 'District Court Indore',
  ),
  Court(id: _supreme, level: 'SC', name: '', shortName: 'Supreme Court'),
];

/// Found case [n] (id `fc-n`, number 100n), by default a pending, high-confidence WP 2024 at MPHC Indore.
FoundCase foundCase(
  int n, {
  String? courtId = _indore,
  String caseType = 'WP',
  int? caseYear = 2024,
  String status = 'pending',
  String confidence = 'high',
  String title = 'Sharma v. State of MP',
}) => FoundCase(
  id: 'fc-$n',
  cnr: 'MPHC01${n.toString().padLeft(10, '0')}',
  courtId: courtId,
  caseType: caseType,
  caseNumber: '${1000 + n}',
  caseYear: caseYear,
  title: title,
  caseStatus: status,
  confidence: confidence,
);

/// Found cases selection (spec §4.1): defaults, ticks, groups, ranges, Add all vs a selection, filters, pages.
void main() {
  final cases = [
    foundCase(1),
    foundCase(2, confidence: 'low', title: 'Gupta v. Jain'),
    foundCase(3, courtId: _district, caseType: 'CS', caseYear: 2019),
    foundCase(4, courtId: _supreme, status: 'disposed'),
    foundCase(5, status: 'disposed', title: 'Verma v. State'),
  ];
  Set<String> ids(Iterable<FoundCase> cs) => {for (final c in cs) c.id};

  group('defaults and ticks', () {
    test('pending + high ticked; low and disposed unticked', () {
      final s = FoundSelection(cases, const {});
      expect(ids(s.selected), {'fc-1', 'fc-3'});
      expect(ids(s.pending), {'fc-1', 'fc-2', 'fc-3'});
      expect(s.lowPending, 1);
    });

    test('explicit ticks win over defaults', () {
      final s = FoundSelection(cases, const {'fc-1': false, 'fc-4': true});
      expect(ids(s.selected), {'fc-3', 'fc-4'});
    });

    test('Select all is every pending match; None unticks everything', () {
      final s = FoundSelection(cases, const {'fc-5': true});
      final all = s.selectAll(on: true);
      expect(all, {
        'fc-1': true,
        'fc-2': true,
        'fc-3': true,
        'fc-4': false,
        'fc-5': false,
      });
      expect(FoundSelection(cases, all).isAllPending, isTrue);
      expect(s.selectAll(on: false).values, everyElement(isFalse));
    });

    test('a group checkbox is tri-state over its rows', () {
      bool? value(int selected, int total) => GroupHeader(
        title: '',
        selectedCount: selected,
        total: total,
        onSelectAll: (_) {},
      ).value;
      expect(value(0, 3), isFalse);
      expect(value(2, 3), isNull);
      expect(value(3, 3), isTrue);
    });
  });

  group('Shift-click range', () {
    final visible = cases.take(4).toList();

    test('rows from the anchor to the clicked row take its new state', () {
      final s = FoundSelection(cases, const {});
      // fc-3 is ticked, so the range unticks.
      expect(s.range(visible, 'fc-1', visible[2]), {
        'fc-1': false,
        'fc-2': false,
        'fc-3': false,
      });
      // Upwards works too; fc-4 (disposed) is unticked, so the range ticks.
      expect(s.range(visible, 'fc-3', visible[3]), {
        'fc-3': true,
        'fc-4': true,
      });
      expect(s.range(visible, 'fc-4', visible[1]).keys, [
        'fc-2',
        'fc-3',
        'fc-4',
      ]);
    });

    test('without an anchor on screen it toggles the one row', () {
      final s = FoundSelection(cases, const {});
      expect(s.range(visible, null, visible[0]), {'fc-1': false});
      expect(s.range(visible, 'gone', visible[1]), {'fc-2': true});
    });
  });

  group('Add all vs a selection (spec §4.1 AC)', () {
    test(
      'every pending match reads as "Add all" but still goes as its ids',
      () {
        final ticked = FoundSelection(cases, const {'fc-2': true});
        final viaSelectAll = FoundSelection(
          cases,
          FoundSelection(cases, const {}).selectAll(on: true),
        );
        for (final s in [ticked, viaSelectAll]) {
          expect(s.isAllPending, isTrue);
          expect(s.selectedIds.toSet(), ids(s.pending));
        }
      },
    );

    test('anything else is a selection, never "all"', () {
      final some = FoundSelection(cases, const {});
      expect(some.isAllPending, isFalse);
      expect(some.selectedIds, ['fc-1', 'fc-3']);
      // Every pending match plus a disposed one is not "Add all": disposed cases never are.
      final withDisposed = FoundSelection(cases, const {
        'fc-2': true,
        'fc-4': true,
      });
      expect(withDisposed.isAllPending, isFalse);
      expect(withDisposed.selectedIds, hasLength(4));
      final none = FoundSelection(
        cases,
        FoundSelection(cases, const {}).selectAll(on: false),
      );
      expect(none.isAllPending, isFalse);
      expect(none.selectedIds, isEmpty);
    });

    test('nothing pending is never "all"', () {
      final s = FoundSelection([foundCase(9, status: 'disposed')], const {});
      expect(s.isAllPending, isFalse);
    });
  });

  test('allowance: over only when more is selected than remains', () {
    final s = FoundSelection(cases, const {}); // 2 selected
    expect(s.overAllowance(null), isFalse);
    expect(s.overAllowance(2), isFalse);
    expect(s.overAllowance(1), isTrue);
    expect(s.overAllowance(0), isTrue);
  });

  group('groups', () {
    test('pending by court in courts order, then one Disposed group', () {
      final groups = groupFound(cases, _courts);
      expect(groups.map((g) => g.key), [_indore, _district, disposedGroup]);
      expect(ids(groups.first.cases), {'fc-1', 'fc-2'});
      expect(groups.first.court?.shortName, 'MPHC Indore');
      expect(ids(groups.last.cases), {'fc-4', 'fc-5'});
    });

    test('a court that has not synced yet goes last, without a name', () {
      final groups = groupFound([
        foundCase(1, courtId: 'unknown'),
        foundCase(2, courtId: _supreme),
      ], _courts);
      expect(groups.map((g) => g.key), [_supreme, 'unknown']);
      expect(groups.last.court, isNull);
    });

    test('a cause-list-only row (no court, number or year) parses, groups and shows its CNR', () {
      final row = FoundCase.fromRow(const {
        'id': 'fc-9',
        'cnr': 'MPIN010000012026',
        'court_id': null,
        'case_type': null,
        'case_number': null,
        'case_year': null,
        'case_status': 'transferred',
      });
      expect(row.caseLabel, 'MPIN010000012026');
      expect(foundCase(1).caseLabel, 'WP 1001/2024');
      expect(foundCase(1, caseYear: null).caseLabel, 'WP 1001');
      final groups = groupFound([row, foundCase(2, courtId: null)], _courts);
      expect(groups.map((g) => g.key), [
        '',
        disposedGroup,
      ]); // other court, then the folded non-pending rows
      expect(const FoundFilter(status: 'disposed').apply([row]), [row]);
      expect(const FoundFilter(status: 'pending').apply([row]), isEmpty);
    });
  });

  group('search and filters', () {
    List<String> find(FoundFilter f) => [for (final c in f.apply(cases)) c.id];

    test('search by party matches Hindi and English spellings', () {
      expect(find(const FoundFilter(query: 'Gupta')), ['fc-2']);
      expect(find(const FoundFilter(query: 'गुप्ता')), ['fc-2']);
      expect(find(const FoundFilter(query: 'वर्मा')), ['fc-5']);
      expect(find(const FoundFilter(query: 'sharm')), ['fc-1', 'fc-3', 'fc-4']);
    });

    test('search by case number, type or year', () {
      expect(find(const FoundFilter(query: '1003')), ['fc-3']);
      expect(find(const FoundFilter(query: 'CS 1003/2019')), ['fc-3']);
      expect(find(const FoundFilter(query: 'wp 1002')), ['fc-2']);
      expect(find(const FoundFilter(query: '  ')), hasLength(5));
    });

    test('filters by court, year, status and confidence', () {
      expect(find(const FoundFilter(courtId: _district)), ['fc-3']);
      expect(find(const FoundFilter(year: 2019)), ['fc-3']);
      expect(find(const FoundFilter(status: 'disposed')), ['fc-4', 'fc-5']);
      expect(find(const FoundFilter(confidence: 'low')), ['fc-2']);
      expect(
        find(
          const FoundFilter(
            courtId: _indore,
            status: 'pending',
            query: 'state',
          ),
        ),
        ['fc-1'],
      );
      expect(const FoundFilter(year: 2019, query: 'x').count, 1);
      expect(
        const FoundFilter(
          courtId: 'c',
          year: 1,
          status: 's',
          confidence: 'c',
        ).withQuery('q').count,
        4,
      );
    });
  });

  test('over 300 results, groups show 100 rows a page', () {
    expect(shownInGroup(total: 300, groupSize: 250, pages: 1), 250);
    expect(shownInGroup(total: 301, groupSize: 250, pages: 1), 100);
    expect(shownInGroup(total: 301, groupSize: 250, pages: 2), 200);
    expect(shownInGroup(total: 301, groupSize: 250, pages: 3), 250);
    expect(shownInGroup(total: 301, groupSize: 40, pages: 1), 40);
  });

  test('a High Court is said in full; other courts as they are', () {
    final hc = _courts.first;
    expect(
      hc.spokenLabel(const Locale('en'), 'High Court'),
      'MP High Court Indore',
    );
    const hi = Court(
      id: 'x',
      level: 'HC',
      name: '',
      shortName: 'MPHC Indore',
      shortNameHi: 'MPHC इंदौर',
    );
    expect(
      hi.spokenLabel(const Locale('hi'), 'हाई कोर्ट'),
      'MP हाई कोर्ट इंदौर',
    );
    expect(
      _courts[1].spokenLabel(const Locale('en'), 'High Court'),
      'District Court Indore',
    );
  });

  test(
    'CNR: spaces and hyphens stripped, uppercased, 4 letters + 12 digits',
    () {
      expect(normalizeCnr('mphc01-0012 3420 24'), 'MPHC010012342024');
      expect(normalizeCnr(' MPHC010012342024\n'), 'MPHC010012342024');
      expect(normalizeCnr('MPHC01001234202'), isNull); // 15
      expect(normalizeCnr('MPHC0100123420245'), isNull); // 17
      expect(normalizeCnr('MP1C010012342024'), isNull);
      expect(normalizeCnr('MPHC01001234202O'), isNull); // letter O
      expect(normalizeCnr(''), isNull);
    },
  );
}
