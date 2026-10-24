import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Now, as an instant; tests override it.
final clockProvider = Provider<DateTime Function()>((_) => DateTime.now);

/// India time (spec §11.5): "today", "tomorrow" and the evening switch are IST (UTC+05:30, no daylight saving)
/// whatever zone the device is in. An IST value here is a UTC [DateTime] whose fields read as IST wall-clock
/// time, so date arithmetic never meets a DST jump and formatting prints the IST fields.
const istOffset = Duration(hours: 5, minutes: 30);

/// IST wall-clock time of [instant].
DateTime istOf(DateTime instant) => instant.toUtc().add(istOffset);

/// The IST day [ist] falls in, at 00:00.
DateTime istDay(DateTime ist) => DateTime.utc(ist.year, ist.month, ist.day);

/// The instant an IST wall-clock time (e.g. a day from [istDay]) happens.
DateTime istInstant(DateTime ist) => ist.subtract(istOffset);

/// `YYYY-MM-DD`, the synced tables' date format.
String isoDate(DateTime day) => day.toIso8601String().substring(0, 10);

/// A synced timestamptz (with or without a zone; none means UTC) as a UTC instant.
DateTime? parseInstant(Object? v) {
  if (v is! String || v.isEmpty) return null;
  final zoned = RegExp(r'(Z|[+-]\d\d(:?\d\d)?)$').hasMatch(v);
  return DateTime.tryParse(zoned ? v : '${v}Z')?.toUtc();
}

/// A synced date (`YYYY-MM-DD`) as an IST day (see [istDay]).
DateTime? parseDay(Object? v) {
  final d = v is String ? DateTime.tryParse(v) : null;
  return d == null ? null : DateTime.utc(d.year, d.month, d.day);
}

/// IST now, updated on each minute (the hero card, the evening switch and the day all follow it), and re-read when
/// the app resumes: Dart timers stop while the device sleeps, so a phone opened in the morning would otherwise show
/// last night for up to a minute.
class IstNow extends Notifier<DateTime> {
  Timer? _tick;

  @override
  DateTime build() {
    final clock = ref.watch(clockProvider);
    void update() {
      final now = clock();
      state = istOf(now);
      _schedule(now, update);
    }

    final lifecycle = AppLifecycleListener(onResume: update);
    ref.onDispose(() {
      _tick?.cancel();
      lifecycle.dispose();
    });
    final now = clock();
    _schedule(now, update);
    return istOf(now);
  }

  /// The next tick lands just after the next whole minute (IST minutes are UTC minutes), so 18:30 and midnight
  /// switch on time.
  void _schedule(DateTime now, void Function() update) {
    _tick?.cancel();
    _tick = Timer(
      Duration(milliseconds: 60000 - now.millisecondsSinceEpoch % 60000),
      update,
    );
  }
}

final istNowProvider = NotifierProvider<IstNow, DateTime>(IstNow.new);

/// Today in IST at 00:00; changes at midnight IST.
final istTodayProvider = Provider<DateTime>(
  (ref) => istDay(ref.watch(istNowProvider)),
);

final istTomorrowProvider = Provider<DateTime>(
  (ref) => ref.watch(istTodayProvider).add(const Duration(days: 1)),
);
