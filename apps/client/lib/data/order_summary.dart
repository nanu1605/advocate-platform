import 'package:advocate_app/core/clock.dart';
import 'package:flutter/foundation.dart';

/// One point of an order summary and the pages of the order it rests on (spec F07: every bullet links to its
/// source page). `who` and `byWhen` are a direction's, as the order words them.
typedef SummaryPoint = ({
  String text,
  List<int> pages,
  String? who,
  String? byWhen,
});

/// An order's AI summary (spec F07) as the pipeline stores it: legal_ai's `OrderSummary`, whose points cite source
/// ids ("S1"), and `source_pages`, each id's page. Here each point carries its pages instead.
@immutable
class OrderSummaryView {
  const OrderSummaryView({
    required this.title,
    required this.gist,
    this.court,
    this.orderDate,
    this.judges = const [],
    this.headerPages = const [],
    this.outcome,
    this.directions = const [],
    this.nextDate,
    this.nextDatePages = const [],
    this.relief,
    this.keyReasons = const [],
    this.authorities = const [],
    this.nextSteps = const [],
  });

  factory OrderSummaryView.fromJson(Map<String, Object?> j) {
    final pages = (j['source_pages'] as Map?) ?? const {};
    List<int> on(Object? sources) => {
      for (final s in sources as List? ?? const [])
        if (pages[s] case final int p) p,
    }.toList()..sort();
    SummaryPoint? point(Object? c) => c is Map
        ? (
            text: c['text'] as String? ?? '',
            pages: on(c['sources']),
            who: c['who'] as String?,
            byWhen: c['by_when'] as String?,
          )
        : null;
    List<SummaryPoint> points(Object? list) => [
      for (final c in list as List? ?? const []) ?point(c),
    ];
    final next = j['next_date'] as Map?;
    return OrderSummaryView(
      title: j['title'] as String? ?? '',
      court: j['court'] as String?,
      orderDate: parseDay(j['order_date']),
      judges: (j['judges'] as List? ?? const []).cast(),
      headerPages: on(j['header_sources']),
      outcome: point(j['outcome']),
      gist: point(j['gist']),
      directions: points(j['directions']),
      nextDate: parseDay(next?['date']),
      nextDatePages: on(next?['sources']),
      relief: point(j['relief']),
      keyReasons: points(j['key_reasons']),
      authorities: points(j['authorities_cited_in_document']),
      nextSteps: points(j['next_steps_for_us']),
    );
  }

  final String title;
  final String? court;
  final DateTime? orderDate;
  final List<String> judges;

  /// Where the title, court, date and judges are read.
  final List<int> headerPages;
  final SummaryPoint? outcome;
  final SummaryPoint? gist;

  /// Who must do what by when.
  final List<SummaryPoint> directions;
  final DateTime? nextDate;
  final List<int> nextDatePages;
  final SummaryPoint? relief;
  final List<SummaryPoint> keyReasons;

  /// Authorities the order cites: shown "As cited in this order — not verified" until the citation verifier (P5).
  final List<SummaryPoint> authorities;
  final List<SummaryPoint> nextSteps;
}
