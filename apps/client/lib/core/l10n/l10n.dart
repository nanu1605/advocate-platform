import 'package:advocate_app/core/l10n/gen/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

export 'package:advocate_app/core/l10n/gen/app_localizations.dart';

extension L10nContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}

/// Display formats from spec §5.10: "Thu, 5 Nov 2026" / "गुरु, 5 नवंबर 2026", 12-hour time,
/// Indian digit grouping, Western digits in both languages.
class Formats {
  Formats(this.locale);

  final Locale locale;

  bool get _hi => locale.languageCode == 'hi';
  String get _tag => _hi ? 'hi' : 'en_IN';

  String date(DateTime d) =>
      DateFormat(_hi ? 'EEE, d MMMM y' : 'EEE, d MMM y', _tag).format(d);

  String shortDate(DateTime d) =>
      DateFormat(_hi ? 'EEE, d MMMM' : 'EEE, d MMM', _tag).format(d);

  /// "7:30 pm" / "शाम 7:30".
  String time(DateTime t) {
    if (!_hi) return DateFormat('h:mm a', 'en_IN').format(t).toLowerCase();
    final h = t.hour;
    final part = h < 4
        ? 'रात'
        : h < 12
        ? 'सुबह'
        : h < 17
        ? 'दोपहर'
        : h < 20
        ? 'शाम'
        : 'रात';
    return '$part ${DateFormat('h:mm', 'hi').format(t)}';
  }

  /// ₹1,25,000 (paise in, rupees out).
  String money(int paise) => NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: paise % 100 == 0 ? 0 : 2,
  ).format(paise / 100);

  /// DD-MM-YYYY numeric entry format (spec §5.10).
  static String entry(DateTime d) => DateFormat('dd-MM-yyyy').format(d);

  static DateTime? parseEntry(String s) {
    final m = RegExp(r'^(\d{2})-(\d{2})-(\d{4})$').firstMatch(s.trim());
    if (m == null) return null;
    final (d, mo, y) = (int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
    final parsed = DateTime(y, mo, d);
    return parsed.day == d && parsed.month == mo ? parsed : null;
  }
}
