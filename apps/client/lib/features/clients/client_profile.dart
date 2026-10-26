import 'dart:async';

import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/clients.dart';
import 'package:advocate_app/data/diary_text.dart';
import 'package:advocate_app/features/case_page/client_tab.dart';
import 'package:advocate_app/features/case_page/links.dart';
import 'package:advocate_app/features/case_page/sheet_form.dart';
import 'package:advocate_app/features/cases/cases_screen.dart';
import 'package:advocate_app/ui/case_card.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:advocate_app/ui/focus_ring.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/krutidev_offer.dart';
import 'package:advocate_app/ui/section_header.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:advocate_app/ui/skeleton.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:advocate_app/ui/tiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// A stored phone as people read it: "+91 98765 43210".
String phoneText(String phone) {
  final m = RegExp(r'^\+91(\d{5})(\d{5})$').firstMatch(phone);
  return m == null ? phone : '+91 ${m[1]} ${m[2]}';
}

/// A Clients list row for screen readers (spec §5.9): "Ramesh Sharma. 2 cases. +91 98765 43210."
String clientRowLabel(AppLocalizations l, ClientInfo c) {
  final stop = l.localeName.startsWith('hi') ? '।' : '.';
  return [
    c.name,
    l.linkedCases(c.caseCount),
    if (c.phone != null) phoneText(c.phone!),
  ].map((s) => '$s$stop').join(' ');
}

/// A client's profile (spec §4.3 Clients, `/clients/:id`; beside the list on wide windows when [pane]): name,
/// phone (tap to call), the WhatsApp opt-in, email, address, preferred language, notes and the linked cases (open,
/// link, unlink with Undo). Edit and Delete (with Undo) in the app bar. Local reads and writes, so it works
/// offline. Send update (P2) and the fee summary (P3) are not here yet.
class ClientProfile extends ConsumerWidget {
  const ClientProfile({required this.clientId, this.pane = false, super.key});

  final String clientId;

  /// The detail pane beside the list (spec §5.3 Windows): no back arrow.
  final bool pane;

  /// Soft delete with Undo (task 9's pattern): back where the profile was opened from (the list, or a case it was
  /// opened over), which leaves the client out until the delete is written when the snackbar closes.
  void _delete(BuildContext context, WidgetRef ref) {
    deleteWithUndo(context, ref, clientId, (w) => w.deleteClient(clientId));
    if (!pane && context.canPop()) {
      context.pop();
    } else {
      context.go('/clients');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final async = ref.watch(clientProvider(clientId));
    final c = async.value;
    if (c == null) {
      return Scaffold(
        appBar: AppBar(automaticallyImplyLeading: !pane),
        body: async.isLoading
            ? ListView(
                padding: const EdgeInsets.all(16),
                children: const [SkeletonCaseList(count: 2)],
              )
            : async.hasError
            ? ErrorState(
                message: errorText(l, async.error),
                onRetry: () => ref.invalidate(clientProvider(clientId)),
              )
            : EmptyState(
                icon: AppIcons.users,
                message: l.clientsRemoved,
                actionLabel: l.clientsBack,
                onAction: () => context.go('/clients'),
              ),
      );
    }

    final f = Formats(Localizations.localeOf(context));
    final phone = c.phone;
    final email = c.email;
    final address = c.address;
    final language = clientLanguageLabel(l, c.language);
    final notes = c.notes;
    final agreedAt = c.whatsappOptInAt;
    Widget detail(IconData icon, String value, String label, {Uri? open}) =>
        FocusRing(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(icon, color: context.colors.ink2),
            title: Text(value, style: context.text.bodyLarge),
            subtitle: Text(label, style: context.text.bodySmall),
            onTap: open == null
                ? null
                : () => unawaited(openExternal(context, ref, open)),
          ),
        );

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !pane,
        actions: [
          IconButton(
            tooltip: l.clientsEdit,
            icon: const Icon(AppIcons.pencilSimple),
            onPressed: () => unawaited(showClientSheet(context, client: c)),
          ),
          PopupMenuButton<bool>(
            tooltip: l.boardMoreActions(c.name),
            icon: const Icon(AppIcons.dotsThreeVertical),
            onSelected: (_) => _delete(context, ref),
            itemBuilder: (_) => [
              PopupMenuItem(value: true, child: Text(l.clientsDelete)),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Row(
            children: [
              // Grows with the text so large initials stay inside the circle (spec §5.9).
              Avatar(
                c.name,
                size: 24 + MediaQuery.textScalerOf(context).scale(32),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(c.name, style: context.text.headlineSmall),
                    ),
                    Text(
                      l.linkedCases(c.caseCount),
                      style: context.text.bodyMedium?.copyWith(
                        color: context.colors.ink2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (phone != null)
            detail(
              AppIcons.phone,
              phoneText(phone),
              l.clientsCallHint,
              open: telUri(phone),
            ),
          // For P2's case updates; a number is needed to turn it on, and it can always be turned off.
          FocusRing(
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: Icon(
                AppIcons.whatsappLogo,
                color: context.colors.ink2,
              ),
              title: Text(l.clientsWhatsapp, style: context.text.bodyLarge),
              subtitle: Text(
                [
                  if (phone == null && !c.whatsappOptIn)
                    l.clientsWhatsappNeedsPhone
                  else
                    l.clientsWhatsappHint,
                  if (c.whatsappOptIn && agreedAt != null)
                    l.clientsWhatsappAgreed(f.date(istDay(istOf(agreedAt)))),
                ].join('\n'),
                style: context.text.bodySmall,
              ),
              value: c.whatsappOptIn,
              onChanged: phone == null && !c.whatsappOptIn
                  ? null
                  : (on) => unawaited(
                      ref
                          .read(caseWriterProvider)
                          .setClientWhatsapp(c.id, optIn: on),
                    ),
            ),
          ),
          if (email != null)
            detail(
              AppIcons.envelope,
              email,
              l.clientsEmail,
              open: Uri(scheme: 'mailto', path: email),
            ),
          if (address != null)
            detail(AppIcons.mapPin, address, l.clientsAddress),
          if (language != null)
            detail(AppIcons.translate, language, l.casePageClientLanguage),
          if (notes != null) ...[
            SectionHeader(l.clientsNotes),
            Text(notes, style: context.text.bodyLarge),
          ],
          const SizedBox(height: 8),
          _Cases(c),
        ],
      ),
    );
  }
}

/// The client's cases (live, archived ones too) by next date: open one, link another, or unlink with Undo.
class _Cases extends ConsumerWidget {
  const _Cases(this.client);

  final ClientInfo client;

  void _unlink(BuildContext context, WidgetRef ref, ClientCase x) {
    final writer = ref.read(caseWriterProvider);
    unawaited(writer.unlinkClient(x.linkId));
    showUndoSnackbar(
      context,
      message: context.l10n.clientsUnlinked(x.c.caseLabel),
      onUndo: () => unawaited(writer.linkClient(x.c.id, client.id)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final locale = Localizations.localeOf(context);
    final today = ref.watch(istTodayProvider);
    final me = ref.watch(currentUserIdProvider);
    final async = ref.watch(clientCasesProvider(client.id));
    final cases = async.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          l.clientsCases,
          count: cases?.length,
          actionLabel: l.clientsLinkCase,
          onAction: () =>
              unawaited(showLinkCaseSheet(context, clientId: client.id)),
        ),
        if (cases == null && async.hasError)
          ErrorState(
            message: errorText(l, async.error),
            onRetry: () => ref.invalidate(clientLinksProvider(client.id)),
          )
        else if (cases == null)
          const SkeletonCaseList(count: 2)
        else if (cases.isEmpty)
          Text(l.clientsCasesEmpty, style: context.text.bodyLarge)
        else
          for (final x in cases)
            Padding(
              key: ValueKey(x.linkId),
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: CaseCard(
                      _cardData(l, locale, x.c),
                      variant: CaseCardVariant.compact,
                      today: today,
                      semanticsLabel: caseRowLabel(l, locale, x.c, me: me),
                      onTap: () => openInSection(context, '/cases/${x.c.id}'),
                    ),
                  ),
                  PopupMenuButton<bool>(
                    tooltip: l.boardMoreActions(x.c.caseLabel),
                    icon: const Icon(AppIcons.dotsThreeVertical),
                    onSelected: (_) => _unlink(context, ref, x),
                    itemBuilder: (_) => [
                      PopupMenuItem(value: true, child: Text(l.casePageUnlink)),
                    ],
                  ),
                ],
              ),
            ),
      ],
    );
  }
}

/// A linked case's compact card, as on the Cases list.
CaseCardData _cardData(AppLocalizations l, Locale locale, CaseInfo c) =>
    CaseCardData(
      caseNumber: c.caseLabel,
      title: c.numbered ? c.title ?? '' : '',
      court: c.courtLabel(locale) ?? l.foundOtherCourt,
      courtNo: c.courtNo,
      nextDate: c.disposed ? null : c.nextDate,
      assignee: c.assigneeName,
      state: c.courtStatus == 'disposed'
          ? CaseCardState.disposed
          : c.manual
          ? CaseCardState.manual
          : CaseCardState.normal,
    );

/// Link case, the client's side of task 9's Link client: the org's unarchived cases not linked yet, by number,
/// party, client or CNR (with transliteration). A local write.
Future<void> showLinkCaseSheet(
  BuildContext context, {
  required String clientId,
}) =>
    showAppBottomSheet<void>(context, builder: (_) => _LinkCaseSheet(clientId));

class _LinkCaseSheet extends ConsumerStatefulWidget {
  const _LinkCaseSheet(this.clientId);

  final String clientId;

  @override
  ConsumerState<_LinkCaseSheet> createState() => _LinkCaseSheetState();
}

class _LinkCaseSheetState extends ConsumerState<_LinkCaseSheet> {
  var _query = CaseQuery('');

  Future<void> _link(String matterId) async {
    final navigator = Navigator.of(context);
    await ref.read(caseWriterProvider).linkClient(matterId, widget.clientId);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final linked = {
      for (final x
          in ref.watch(clientLinksProvider(widget.clientId)).value ??
              const <({String linkId, String matterId})>[])
        x.matterId,
    };
    final matches = [
      for (final c in ref.watch(casesProvider).value ?? const <CaseInfo>[])
        if (!c.archived && !linked.contains(c.id) && _query.matches(c)) c,
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(l.clientsLinkCase, style: context.text.titleLarge),
        ),
        const SizedBox(height: 16),
        SearchField(
          hint: l.searchCasesHint,
          autofocus: true,
          onChanged: (v) => setState(() => _query = CaseQuery(v)),
        ),
        const SizedBox(height: 8),
        // ponytail: the first 30 matches; typing narrows it.
        for (final c in matches.take(30))
          FocusRing(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                c.caseLabel,
                semanticsLabel: spokenCaseLabel(l, c.caseLabel),
              ),
              subtitle: c.title == null || c.title == c.caseLabel
                  ? null
                  : Text(
                      c.title!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
              onTap: () => unawaited(_link(c.id)),
            ),
          ),
        if (matches.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(l.clientsNoCaseMatch, style: context.text.bodyLarge),
          ),
      ],
    );
  }
}

/// Add client, or edit [client] (spec §4.3 Clients): name (required, at most [clientNameMax] characters), Indian
/// mobile number (10 digits, +91 optional), email, address, preferred language and notes, checked inline and
/// announced ([validateClient]). Local writes; the `search_key` follows the name. Returns the new client's id after
/// Add; [name] fills the name of a new one.
Future<String?> showClientSheet(
  BuildContext context, {
  ClientInfo? client,
  String? name,
}) => showAppBottomSheet<String>(
  context,
  builder: (_) => _ClientSheet(client: client, name: name),
);

class _ClientSheet extends ConsumerStatefulWidget {
  const _ClientSheet({this.client, this.name});

  final ClientInfo? client;
  final String? name;

  @override
  ConsumerState<_ClientSheet> createState() => _ClientSheetState();
}

class _ClientSheetState extends ConsumerState<_ClientSheet> {
  late final _name = TextEditingController(
    text: widget.client?.name ?? widget.name,
  );
  late final _phone = TextEditingController(
    text: widget.client?.phone == null ? '' : phoneText(widget.client!.phone!),
  );
  late final _email = TextEditingController(text: widget.client?.email);
  late final _address = TextEditingController(text: widget.client?.address);
  late final _notes = TextEditingController(text: widget.client?.notes);
  late String? _language = widget.client?.language;
  ({ClientFieldError? name, ClientFieldError? phone, ClientFieldError? email})
  _errors = (name: null, phone: null, email: null);

  @override
  void dispose() {
    for (final c in [_name, _phone, _email, _address, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  static String? _text(TextEditingController c) =>
      c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _save() async {
    final l = context.l10n;
    final errors = validateClient(
      name: _name.text,
      phone: _phone.text,
      email: _email.text,
    );
    setState(() => _errors = errors);
    if (errors.name ?? errors.phone ?? errors.email case final e?) {
      announce(context, clientFieldErrorText(l, e));
      return;
    }
    final navigator = Navigator.of(context);
    final writer = ref.read(caseWriterProvider);
    final phone = _text(_phone) == null ? null : normalizePhone(_phone.text);
    final client = widget.client;
    if (client == null) {
      final id = await writer.createClient(
        name: _name.text,
        phone: phone,
        language: _language,
        email: _text(_email),
        address: _text(_address),
        notes: _text(_notes),
      );
      navigator.pop(id);
    } else {
      await writer.updateClient(
        client.id,
        name: _name.text,
        phone: phone,
        language: _language,
        email: _text(_email),
        address: _text(_address),
        notes: _text(_notes),
      );
      navigator.pop();
    }
  }

  String? _error(ClientFieldError? e) =>
      e == null ? null : clientFieldErrorText(context.l10n, e);

  Widget _multiline(TextEditingController controller, String label) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextField(
        controller: controller,
        minLines: 2,
        maxLines: 6,
        textCapitalization: TextCapitalization.sentences,
        style: context.text.bodyLarge,
        decoration: InputDecoration(labelText: label, alignLabelWithHint: true),
      ),
      KrutidevOffer(controller),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return SheetForm(
      title: widget.client == null ? l.clientsAdd : l.clientsEdit,
      onSave: () => unawaited(_save()),
      children: [
        AppTextField(
          controller: _name,
          label: l.casePageClientName,
          error: _error(_errors.name),
          autofocus: widget.client == null,
        ),
        AppTextField(
          controller: _phone,
          label: l.phoneLabel,
          hint: l.phoneHint,
          error: _error(_errors.phone),
          keyboardType: TextInputType.phone,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[\d+\s\-]')),
            LengthLimitingTextInputFormatter(16),
          ],
        ),
        AppTextField(
          controller: _email,
          label: l.clientsEmail,
          error: _error(_errors.email),
          keyboardType: TextInputType.emailAddress,
        ),
        _multiline(_address, l.clientsAddress),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(l.casePageClientLanguage, style: context.text.labelLarge),
            for (final lang in ['hi', 'en'])
              ChoiceChip(
                label: Text(clientLanguageLabel(l, lang)!),
                selected: _language == lang,
                onSelected: (on) =>
                    setState(() => _language = on ? lang : null),
              ),
          ],
        ),
        _multiline(_notes, l.clientsNotes),
      ],
    );
  }
}
