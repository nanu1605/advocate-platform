/// Client rules the Clients list, the profile and its edit sheet share (spec §4.3 Clients). The client reads and
/// writes live with task 9's in `cases.dart`: [clientsProvider], [clientProvider], [clientCasesProvider],
/// [searchClients] and [CaseWriter]'s client methods.
library;

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/cases.dart';

/// The longest name the edit sheet takes.
const clientNameMax = 200;

/// Why a client field can't be saved; [clientFieldErrorText] says it.
enum ClientFieldError { nameRequired, nameTooLong, phoneInvalid, emailInvalid }

/// An Indian mobile number as stored, `+91` and 10 digits, from what was typed: 10 digits starting 6–9, with or
/// without +91 (or 91, or a leading 0), spaces and dashes ignored. Null when it isn't one.
String? normalizePhone(String input) {
  var digits = input.replaceAll(RegExp(r'[\s\-().]'), '');
  if (digits.startsWith('+91')) {
    digits = digits.substring(3);
  } else if (digits.length == 12 && digits.startsWith('91')) {
    digits = digits.substring(2);
  } else if (digits.length == 11 && digits.startsWith('0')) {
    digits = digits.substring(1);
  }
  return RegExp(r'^[6-9]\d{9}$').hasMatch(digits) ? '+91$digits' : null;
}

/// The edit sheet's checks, inline per field: a name (at most [clientNameMax] characters), and if given, an Indian
/// mobile number ([normalizePhone]) and an email's shape.
({ClientFieldError? name, ClientFieldError? phone, ClientFieldError? email})
validateClient({required String name, String phone = '', String email = ''}) {
  final n = name.trim();
  return (
    name: n.isEmpty
        ? ClientFieldError.nameRequired
        : n.length > clientNameMax
        ? ClientFieldError.nameTooLong
        : null,
    phone: phone.trim().isEmpty || normalizePhone(phone) != null
        ? null
        : ClientFieldError.phoneInvalid,
    email:
        email.trim().isEmpty ||
            RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s.]+$').hasMatch(email.trim())
        ? null
        : ClientFieldError.emailInvalid,
  );
}

/// `tel:` for a stored phone, from its digits (and a leading +); null without digits.
Uri? telUri(String? phone) {
  final p = (phone ?? '').replaceAll(RegExp(r'[^\d+]'), '');
  final digits = p.replaceAll('+', '');
  if (digits.isEmpty) return null;
  return Uri(scheme: 'tel', path: p.startsWith('+') ? '+$digits' : digits);
}

String clientFieldErrorText(AppLocalizations l, ClientFieldError e) =>
    switch (e) {
      ClientFieldError.nameRequired => l.clientsDataNameRequired,
      ClientFieldError.nameTooLong => l.clientsDataNameTooLong(clientNameMax),
      ClientFieldError.phoneInvalid => l.clientsDataPhoneInvalid,
      ClientFieldError.emailInvalid => l.clientsDataEmailInvalid,
    };
