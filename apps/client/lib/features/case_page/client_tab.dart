import 'dart:async';

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/features/case_page/links.dart';
import 'package:advocate_app/features/case_page/sheet_form.dart';
import 'package:advocate_app/features/onboarding/onboarding_layout.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:advocate_app/ui/tiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// "Hindi" / "English" for a client's preferred language; null when not set.
String? clientLanguageLabel(AppLocalizations l, String? language) =>
    switch (language) {
      'hi' => l.casePageLangHi,
      'en' => l.casePageLangEn,
      _ => null,
    };

/// Client (spec §4.3): the case's clients with phone (tap to call) and language; link an existing client or a new
/// one, unlink with Undo. A row opens the client's profile (`/clients/:id`). A sliver for the case page.
class ClientTab extends ConsumerWidget {
  const ClientTab(this.c, {super.key});

  final CaseInfo c;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final async = ref.watch(caseClientsProvider(c.id));
    void link() => unawaited(showLinkClientSheet(context, matterId: c.id));
    final waiting = tabWaiting(context, [
      async,
    ], onRetry: () => ref.invalidate(caseClientsProvider(c.id)));
    if (waiting != null) return waiting;
    final links = async.requireValue;
    if (links.isEmpty) {
      return SliverToBoxAdapter(
        child: EmptyState(
          icon: AppIcons.users,
          message: l.casePageClientsEmpty,
          actionLabel: l.casePageLinkClient,
          onAction: link,
        ),
      );
    }
    return SliverList.list(
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            onPressed: link,
            icon: const Icon(AppIcons.plus),
            label: Text(l.casePageLinkClient),
          ),
        ),
        for (final x in links) _Client(x, matterId: c.id),
      ],
    );
  }
}

class _Client extends ConsumerWidget {
  const _Client(this.link, {required this.matterId});

  final LinkedClient link;
  final String matterId;

  void _unlink(BuildContext context, WidgetRef ref) {
    final writer = ref.read(caseWriterProvider);
    final client = link.client;
    unawaited(writer.unlinkClient(link.linkId));
    showUndoSnackbar(
      context,
      message: context.l10n.casePageUnlinked(client.name),
      onUndo: () => unawaited(writer.linkClient(matterId, client.id)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final client = link.client;
    final phone = client.phone;
    final sub = [?phone, ?clientLanguageLabel(l, client.language)].join(' · ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      minVerticalPadding: 12,
      leading: Avatar(client.name),
      title: Text(client.name, style: context.text.titleSmall),
      subtitle: sub.isEmpty ? null : Text(sub, style: context.text.bodySmall),
      onTap: () => openInSection(context, '/clients/${client.id}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (phone != null)
            IconButton(
              tooltip: l.casePageCall(client.name),
              icon: const Icon(AppIcons.phone),
              onPressed: () => unawaited(
                openExternal(context, ref, Uri(scheme: 'tel', path: phone)),
              ),
            ),
          PopupMenuButton<bool>(
            tooltip: l.boardMoreActions(client.name),
            icon: const Icon(AppIcons.dotsThreeVertical),
            onSelected: (_) => _unlink(context, ref),
            itemBuilder: (_) => [
              PopupMenuItem(value: true, child: Text(l.casePageUnlink)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Link client: search the org's clients by name (with transliteration) or phone, or create one (name required;
/// phone and language optional) and link it. Local writes; a new client gets its `search_key`.
Future<void> showLinkClientSheet(
  BuildContext context, {
  required String matterId,
}) => showAppBottomSheet<void>(
  context,
  builder: (_) => _LinkClientSheet(matterId),
);

class _LinkClientSheet extends ConsumerStatefulWidget {
  const _LinkClientSheet(this.matterId);

  final String matterId;

  @override
  ConsumerState<_LinkClientSheet> createState() => _LinkClientSheetState();
}

class _LinkClientSheetState extends ConsumerState<_LinkClientSheet> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  String _query = '';
  String? _language;
  String? _nameError;
  String? _phoneError;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _link(String clientId) async {
    final navigator = Navigator.of(context);
    await ref.read(caseWriterProvider).linkClient(widget.matterId, clientId);
    navigator.pop();
  }

  Future<void> _create() async {
    final l = context.l10n;
    final name = _name.text.trim();
    final phone = _phone.text;
    setState(() {
      _nameError = name.isEmpty ? l.casePageClientNameEmpty : null;
      _phoneError = phone.isEmpty || isValidIndianMobile(phone)
          ? null
          : l.phoneInvalid;
    });
    if (_nameError ?? _phoneError case final error?) {
      announce(context, error);
      return;
    }
    final id = await ref
        .read(caseWriterProvider)
        .createClient(
          name: name,
          phone: phone.isEmpty ? null : '+91$phone',
          language: _language,
        );
    await _link(id);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final linked = {
      for (final x
          in ref.watch(caseClientsProvider(widget.matterId)).value ??
              const <LinkedClient>[])
        x.client.id,
    };
    final all = ref.watch(clientsProvider).value ?? const <ClientInfo>[];
    final matches = [
      for (final c in searchClients(all, _query))
        if (!linked.contains(c.id)) c,
    ];
    return SheetForm(
      title: l.casePageLinkClient,
      saveLabel: l.casePageCreateLink,
      onSave: () => unawaited(_create()),
      children: [
        if (all.isNotEmpty) ...[
          SearchField(
            hint: l.casePageSearchClients,
            onChanged: (v) => setState(() => _query = v),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ponytail: the first 20 matches; typing narrows it.
              for (final c in matches.take(20))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Avatar(c.name),
                  title: Text(c.name),
                  subtitle: c.phone == null ? null : Text(c.phone!),
                  onTap: () => unawaited(_link(c.id)),
                ),
              if (matches.isEmpty) Text(l.casePageNoClientMatch),
            ],
          ),
        ],
        Semantics(
          header: true,
          child: Text(l.casePageNewClient, style: context.text.titleMedium),
        ),
        AppTextField(
          controller: _name,
          label: l.casePageClientName,
          error: _nameError,
        ),
        AppTextField(
          controller: _phone,
          label: l.phoneLabel,
          hint: l.phoneHint,
          error: _phoneError,
          prefixText: '+91 ',
          keyboardType: TextInputType.phone,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(10),
          ],
        ),
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
      ],
    );
  }
}
