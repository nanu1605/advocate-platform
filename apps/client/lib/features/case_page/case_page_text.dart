/// Case page text and rules that tests check without a widget (spec §4.3, §5.10).
library;

import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/case_text.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/ui/status_pill.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

/// The case page tabs, by their `?tab=` names; anything else (e.g. P2's `brief`) opens the timeline.
enum CaseTab {
  timeline,
  documents,
  notes,
  client;

  static CaseTab of(String? name) =>
      CaseTab.values.asNameMap()[name] ?? CaseTab.timeline;
}

/// The header's pills: Listed when the next date is today or tomorrow (IST [today]), Disposed, New order when the
/// user has an unread order. Transferred and archived say so in the status line instead.
List<PillKind> casePills(CaseInfo c, DateTime today, {required bool newOrder}) {
  final next = c.nextDate;
  return [
    if (!c.disposed &&
        next != null &&
        !next.isBefore(today) &&
        next.difference(today).inDays <= 1)
      PillKind.listed,
    if (c.courtStatus == 'disposed') PillKind.disposed,
    if (newOrder) PillKind.newOrder,
  ];
}

/// "Pending · Updated 7:42 pm from the official record", with "Archived" when it is (spec §4.3 header).
String caseStatusLine(
  AppLocalizations l,
  Locale locale,
  CaseInfo c,
  DateTime today,
) => [
  caseStatusText(l, c),
  if (c.archived) l.casesSectionArchived,
  caseUpdatedText(l, locale, c, today: today),
].join(' · ');

/// "28 Oct 2026" / "28 अक्टूबर 2026": the timeline's date column.
String timelineDate(Locale locale, DateTime day) => locale.languageCode == 'hi'
    ? DateFormat('d MMMM y', 'hi').format(day)
    : DateFormat('d MMM y', 'en_IN').format(day);

/// "Hearing · Admission": the purpose, the court's first.
String hearingTitle(AppLocalizations l, CaseHearing h) =>
    [l.casePageHearing, ?courtWins(h.purpose, h.userPurpose).value].join(' · ');

/// What a hearing shows under its title (spec §4.3 Timeline): court and item number, outcome and next date, each
/// followed by "You noted: …" where the user's value differs from the court's, and the hearing note.
List<String> hearingLines(AppLocalizations l, Locale locale, CaseHearing h) {
  final f = Formats(locale);
  final purpose = courtWins(h.purpose, h.userPurpose);
  final outcome = courtWins(h.outcome, h.userOutcome);
  final next = courtWins(h.nextDate, h.userNextDate);
  final position = [
    if (h.courtNo != null) l.courtNo(h.courtNo!),
    if (h.itemNo != null) l.itemNo(h.itemNo!),
  ].join(' · ');
  return [
    if (purpose.noted != null) l.casePageYouNoted(purpose.noted!),
    if (position.isNotEmpty) position,
    if (outcome.value != null) l.casePageOutcome(outcome.value!),
    if (outcome.noted != null) l.casePageYouNoted(outcome.noted!),
    if (next.value != null) l.casesShareNext(f.date(next.value!)),
    if (next.noted != null) l.casePageYouNoted(f.date(next.noted!)),
    if (h.userNote != null) l.casePageNote(h.userNote!),
  ];
}

/// A task's due instant from an IST day and an optional time; midnight IST stands for "no time".
/// ponytail: a task really due at 12:00 am reads as date-only; store a has-time flag if that matters.
DateTime taskDueAt(DateTime day, {int? hour, int? minute}) => istInstant(
  DateTime.utc(day.year, day.month, day.day, hour ?? 0, minute ?? 0),
);

/// "Thu, 5 Nov 2026", with ", 10:30 am" when the task has a time (see [taskDueAt]).
String taskDueText(Locale locale, DateTime dueAt) {
  final f = Formats(locale);
  final ist = istOf(dueAt);
  final day = f.date(istDay(ist));
  return ist.hour == 0 && ist.minute == 0 ? day : '$day, ${f.time(ist)}';
}

/// "820 KB", "2.4 MB" (units read the same in Hindi).
String fileSizeText(int bytes) => bytes < 1024 * 1024
    ? '${(bytes / 1024).ceil()} KB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

/// A document's line under its title: kind, size, and why it can't open yet.
String documentLine(AppLocalizations l, CaseDocument d) => [
  documentKindLabel(l, d.kind),
  if (d.sizeBytes != null) fileSizeText(d.sizeBytes!),
  if (d.uploadStatus == 'pending') l.casePageDocChecking,
  if (d.uploadStatus == 'quarantined') l.casePageDocQuarantined,
].join(' · ');
