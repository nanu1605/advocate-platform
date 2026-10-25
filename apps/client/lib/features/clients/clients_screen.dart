import 'dart:async';

import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/features/case_page/sheet_form.dart';
import 'package:advocate_app/features/clients/client_profile.dart';
import 'package:advocate_app/features/lock/app_lock.dart';
import 'package:advocate_app/ui/app_scaffold.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/skeleton.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:advocate_app/ui/tiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// The Clients list's search, kept while the app runs and shared by its pages (`/clients` and the list beside
/// `/clients/:id` on a wide window).
final _queryProvider = NotifierProvider<_Query, String>(_Query.new);

class _Query extends Notifier<String> {
  @override
  String build() => '';

  String get query => state;
  set query(String query) => state = query;
}

/// The list's scroll offset, shared by its pages like the search.
final Provider<PageStorageBucket> _listStorageProvider = Provider(
  (_) => PageStorageBucket(),
);

/// Clients (spec §4.3, `/clients`): the org's clients by name ([clientsProvider]) with how many live cases each
/// has and their phone, searched by name (transliterated through the stored `search_key`: "sharma" finds "शर्मा")
/// or phone digits; Add client. Reads the synced database, so it works offline. On a window ≥ 840 dp `/clients/:id`
/// shows the list beside the profile of [selectedId] (spec §5.3 Windows), as Cases does. Keys (spec §5.12): Ctrl+F
/// finds, Up/Down move through the rows (from the search box too), Enter opens.
class ClientsScreen extends ConsumerStatefulWidget {
  const ClientsScreen({this.selectedId, super.key});

  /// The client open beside the list (wide windows); null on `/clients`.
  final String? selectedId;

  @override
  ConsumerState<ClientsScreen> createState() => _ClientsScreenState();
}

class _ClientsScreenState extends ConsumerState<ClientsScreen> {
  late final TextEditingController _search;
  final _searchFocus = FocusNode();
  late final PageStorageBucket _storage = ref.read(_listStorageProvider);

  @override
  void initState() {
    super.initState();
    _search = TextEditingController(text: ref.read(_queryProvider));
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Ctrl+F focuses search while the list is the page on top and the app isn't locked (as on Cases).
  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent ||
        e.logicalKey != LogicalKeyboardKey.keyF ||
        !HardwareKeyboard.instance.isControlPressed ||
        !mounted ||
        ModalRoute.isCurrentOf(context) == false ||
        ref.read(appLockProvider).locked) {
      return false;
    }
    _searchFocus.requestFocus();
    _search.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _search.text.length,
    );
    return true;
  }

  /// Add client, then its profile; [name] fills the name (what was searched for).
  Future<void> _add({String? name}) async {
    final id = await showClientSheet(context, name: name);
    if (id != null && mounted) context.go('/clients/$id');
  }

  @override
  Widget build(BuildContext context) {
    final wide =
        sizeClassOf(MediaQuery.sizeOf(context).width) == SizeClass.expanded;
    final hasClients = ref.watch(clientsProvider).value?.isNotEmpty ?? true;
    final list = _list(context, wide: wide);
    final id = widget.selectedId;
    if (!wide || (id == null && !hasClients)) return list;
    return Row(
      children: [
        SizedBox(width: 360, child: list),
        VerticalDivider(width: 1, color: context.colors.line),
        Expanded(
          child: id == null
              ? Scaffold(
                  body: EmptyState(
                    icon: AppIcons.users,
                    message: context.l10n.clientsPick,
                  ),
                )
              : ClientProfile(key: ValueKey(id), clientId: id, pane: true),
        ),
      ],
    );
  }

  Widget _list(BuildContext context, {required bool wide}) {
    final l = context.l10n;
    final async = ref.watch(clientsProvider);
    final query = ref.watch(_queryProvider);
    // A client deleted from its profile leaves the list while its Undo shows.
    final hidden = ref.watch(hiddenRowsProvider);
    ref.listen(_queryProvider, (_, q) {
      if (_search.text != q) _search.text = q;
    });
    final all = [
      for (final c in async.value ?? const <ClientInfo>[])
        if (!hidden.contains(c.id)) c,
    ];
    final shown = searchClients(all, query);
    final empty = async.hasValue && all.isEmpty;

    final Widget body;
    if (async.hasError && !async.hasValue) {
      body = ErrorState(
        message: errorText(l, async.error),
        onRetry: () => ref.invalidate(clientsProvider),
      );
    } else if (!async.hasValue) {
      body = ListView(
        padding: const EdgeInsets.all(16),
        children: const [SkeletonCaseList()],
      );
    } else if (empty || shown.isEmpty) {
      body = ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          EmptyState(
            icon: empty ? AppIcons.users : AppIcons.magnifyingGlass,
            message: empty ? l.clientsEmpty : l.clientsNoMatch,
            actionLabel: l.clientsAdd,
            onAction: () => unawaited(_add(name: empty ? null : query.trim())),
          ),
        ],
      );
    } else {
      // ponytail: rows appear without spec §5.5's stagger, as on Cases.
      body = ListView.builder(
        key: const PageStorageKey('clients.list'),
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
        itemCount: shown.length,
        itemBuilder: (context, i) {
          final c = shown[i];
          final selected = c.id == widget.selectedId;
          return Padding(
            key: ValueKey(c.id),
            padding: const EdgeInsets.only(bottom: 4),
            child: ClientTile(
              name: c.name,
              caseCount: c.caseCount,
              phone: c.phone == null ? null : phoneText(c.phone!),
              selected: selected,
              // Keyboard focus stays on the client just opened when its page replaces the list's.
              autofocus: selected,
              semanticsLabel: clientRowLabel(l, c),
              onTap: () => context.go('/clients/${c.id}'),
            ),
          );
        },
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l.navClients),
        // Beside a profile, the profile's own app bar has the actions.
        automaticallyImplyLeading: !wide,
        actions: [
          // The empty list's own button adds the first client.
          if (!empty)
            // Fits the 360 dp list pane at 200% text: a label too long ends in "…" (screen readers hear it all).
            Flexible(
              child: Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: TextButton.icon(
                  onPressed: () => unawaited(_add()),
                  icon: const Icon(AppIcons.plus),
                  label: Text(
                    l.clientsAdd,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (all.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                      _searchFocus.focusInDirection(TraversalDirection.down),
                },
                child: SearchField(
                  hint: l.clientsSearchHint,
                  controller: _search,
                  focusNode: _searchFocus,
                  onChanged: (q) => ref.read(_queryProvider.notifier).query = q,
                ),
              ),
            ),
          Expanded(
            child: PageStorage(bucket: _storage, child: body),
          ),
        ],
      ),
    );
  }
}
