/// Case text shared by the Cases list, the case page and sharing, so all say the same thing in both languages.
library;

import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:flutter/widgets.dart';

String caseSectionLabel(AppLocalizations l, CaseSection s) => switch (s) {
  CaseSection.today => l.casesSectionToday,
  CaseSection.thisWeek => l.casesSectionThisWeek,
  CaseSection.later => l.casesSectionLater,
  CaseSection.noNextDate => l.casesSectionNoNextDate,
  CaseSection.disposed => l.casesSectionDisposed,
  CaseSection.archived => l.casesSectionArchived,
};

String caseSortLabel(AppLocalizations l, CaseSort s) => switch (s) {
  CaseSort.nextDate => l.casesSortNextDate,
  CaseSort.recentlyUpdated => l.casesSortUpdated,
  CaseSort.caseNumber => l.casesSortNumber,
};

String caseStatusFilterLabel(AppLocalizations l, CaseStatusFilter s) =>
    switch (s) {
      CaseStatusFilter.pending => l.foundPending,
      CaseStatusFilter.disposed => l.statusDisposed,
      CaseStatusFilter.archived => l.casesSectionArchived,
    };

/// The court's status of [c]: Disposed, Transferred, else Pending (manual cases included).
String caseStatusText(AppLocalizations l, CaseInfo c) =>
    switch (c.courtStatus) {
      'disposed' => l.statusDisposed,
      'transferred' => l.foundTransferred,
      _ => l.foundPending,
    };

/// Where the case's data comes from (spec §4.3 header): "Updated 7:42 pm from the official record" (the date too
/// unless it was on [today], an IST day; always when null, as in shared text), "Manual case", "Tracking off", or
/// "Waiting for the official record" before the first fetch.
String caseUpdatedText(
  AppLocalizations l,
  Locale locale,
  CaseInfo c, {
  DateTime? today,
}) {
  if (c.manual) return l.casesManualCase;
  if (c.trackingOff) return l.casesTrackingOff;
  final at = c.courtFetchedAt;
  if (at == null) return l.casesAwaitingRecord;
  final f = Formats(locale);
  final ist = istOf(at);
  return istDay(ist) == today
      ? l.updatedFromRecord(f.time(ist))
      : l.casesUpdatedOn(f.shortDate(ist), f.time(ist));
}

/// "Pleadings", "Orders"… for a document kind (see [documentKinds]).
String documentKindLabel(AppLocalizations l, String kind) => switch (kind) {
  'pleading' => l.casesDocPleading,
  'order' => l.casesDocOrder,
  'evidence' => l.casesDocEvidence,
  'annexure' => l.casesDocAnnexure,
  'correspondence' => l.casesDocCorrespondence,
  _ => l.casesDocOther,
};

/// "Limitation", "Filing"… for a deadline kind (see [deadlineKinds]).
String deadlineKindLabel(AppLocalizations l, String kind) => switch (kind) {
  'limitation' => l.casesDeadlineLimitation,
  'compliance' => l.casesDeadlineCompliance,
  'filing' => l.casesDeadlineFiling,
  _ => l.casesDeadlineOther,
};

/// "Share case status" text (spec §4.3, §13.2): case number, court, next date with [purpose], status and the last
/// update. The title (party names) only when [titles]; never clients. A manual case with no number or CNR shows
/// as "Case without a number" unless titles are on.
String caseShareText(
  AppLocalizations l,
  Locale locale,
  CaseInfo c, {
  required bool titles,
  String? purpose,
}) {
  final f = Formats(locale);
  final court = c.courtLabel(locale) ?? l.foundOtherCourt;
  final next = c.nextDate;
  return [
    if (c.numbered)
      c.caseLabel
    else if (titles && c.title != null)
      c.title!
    else
      l.boardShareNoNumber,
    if (titles && c.numbered && c.title != null) c.title!,
    [court, if (c.courtNo != null) l.courtNo(c.courtNo!)].join(' · '),
    if (next != null && !c.disposed)
      [l.casesShareNext(f.date(next)), ?purpose].join(' · ')
    else if (!c.disposed)
      l.casesNoNextDate,
    l.casesShareStatus(caseStatusText(l, c)),
    caseUpdatedText(l, locale, c),
  ].join('\n');
}
