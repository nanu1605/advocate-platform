import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// The screen a feedback note was sent from, as a route pattern (spec §10.2): "/cases/:id", never an id, a join
/// code or a name. [location] is the top page's matched pattern (`GoRouterState.fullPath`) or a plain
/// location: the query and fragment are dropped, a parameter stays as `:name`, and any segment that isn't a
/// lower-case route word ("cases", "sign-in") becomes `:id`.
String screenPattern(String location) {
  final word = RegExp(r'^(:[a-zA-Z]+|[a-z]+(-[a-z]+)*)$');
  String scrub(String s) => word.hasMatch(s) ? s : ':id';
  final path = location.split(RegExp('[?#]')).first;
  return '/${path.split('/').where((s) => s.isNotEmpty).map(scrub).join('/')}';
}

/// The installed version ("0.1.0"), for Settings' About and feedback.
final appVersionProvider = FutureProvider<String>(
  (_) async => (await PackageInfo.fromPlatform()).version,
);

/// The feedback note being written, kept while the app runs, so a note that couldn't be sent (offline) is still
/// there next time.
class FeedbackDraft extends Notifier<String> {
  @override
  String build() => '';

  String get text => state;
  set text(String value) => state = value;
}

final feedbackDraftProvider = NotifierProvider<FeedbackDraft, String>(
  FeedbackDraft.new,
);
