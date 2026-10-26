import 'dart:async';
import 'dart:math' as math;

import 'package:advocate_app/core/clock.dart';
import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/notifications.dart';
import 'package:advocate_app/features/case_page/links.dart';
import 'package:advocate_app/ui/focus_ring.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/section_header.dart';
import 'package:advocate_app/ui/skeleton.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// /notifications (spec §13): the user's notifications in the current org, newest first, by the IST day they came
/// (Today, Yesterday, Earlier). Unread rows are bold with a dot; a tap marks the row and anything folded under it
/// read, then opens its link if it is one of the app's routes. Rows sharing a collapse key show only the newest
/// ("+2 earlier"). [kind] shows one kind (the dashboard's New orders). Rows come from the synced database and
/// `read_at` is written locally (uploaded later), so it all works offline. Never log a row's title or body.
class NotificationCentre extends ConsumerWidget {
  const NotificationCentre({this.kind, super.key});

  /// e.g. `new_order`; null = every kind.
  final String? kind;

  void _open(BuildContext context, WidgetRef ref, AppNotification n) {
    if (n.unread) {
      unawaited(ref.read(notificationWriterProvider).markRead(n.ids));
    }
    if (n.link case final link?) unawaited(context.push(link));
  }

  void _markAll(
    BuildContext context,
    WidgetRef ref,
    List<AppNotification> unread,
  ) {
    final l = context.l10n;
    final writer = ref.read(notificationWriterProvider);
    // Filtered to one kind, only what is on screen, and the message says so (the bell may still count others).
    final filter = kind;
    if (filter == null) {
      unawaited(writer.markAllRead());
      showMessage(context, l.notifCentreAllRead);
    } else {
      unawaited(writer.markRead([for (final n in unread) ...n.ids]));
      showMessage(
        context,
        l.notifCentreKindRead(notificationKindLabel(l, filter)),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final centre = ref.watch(notificationCentreProvider);
    final today = ref.watch(istTodayProvider);
    final items = [
      for (final n in centre.value ?? const <AppNotification>[])
        if (kind == null || n.kind == kind) n,
    ];
    final unread = [
      for (final n in items)
        if (n.unread) n,
    ];

    final Widget body;
    if (centre.hasError && !centre.hasValue) {
      body = ErrorState(
        message: errorText(l, centre.error),
        onRetry: () => ref.invalidate(notificationRowsProvider),
      );
    } else if (!centre.hasValue) {
      body = ListView(
        padding: const EdgeInsets.all(16),
        children: const [_SkeletonRows()],
      );
    } else if (items.isEmpty) {
      body = ListView(
        children: [
          EmptyState(
            icon: AppIcons.bell,
            message: kind == null ? l.notifCentreEmpty : l.notifCentreEmptyKind,
            actionLabel: kind == null ? null : l.notifCentreShowAll,
            onAction: () => context.go('/notifications'),
          ),
        ],
      );
    } else {
      final rows = <Object>[
        for (final s in notificationSections(items, today)) ...[
          s.day,
          for (final n in s.items) (n, s.day),
        ],
      ];
      // Windows: a readable column (as Today) that still scrolls from anywhere in the window.
      body = LayoutBuilder(
        builder: (context, box) {
          final side = math.max(16, (box.maxWidth - 720) / 2).toDouble();
          return ListView.builder(
            padding: EdgeInsets.fromLTRB(side, 0, side, 24),
            itemCount: rows.length,
            itemBuilder: (context, i) => switch (rows[i]) {
              final NotificationDay d => SectionHeader(switch (d) {
                NotificationDay.today => l.relToday,
                NotificationDay.yesterday => l.relYesterday,
                NotificationDay.earlier => l.notifCentreEarlier,
              }, key: ValueKey(d)),
              (final AppNotification n, final NotificationDay d) =>
                _NotificationTile(
                  n,
                  key: ValueKey(n.id),
                  earlier: d == NotificationDay.earlier,
                  onTap: () => _open(context, ref, n),
                  onMarkRead: () => unawaited(
                    ref.read(notificationWriterProvider).markRead(n.ids),
                  ),
                ),
              _ => const SizedBox.shrink(),
            },
          );
        },
      );
    }

    final filter = kind;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.navNotifications),
        actions: [
          IconButton(
            tooltip: l.notifCentreMarkAll,
            icon: const Icon(AppIcons.checks),
            onPressed: unread.isEmpty
                ? null
                : () => _markAll(context, ref, unread),
          ),
          IconButton(
            tooltip: l.navNotificationSettings,
            icon: const Icon(AppIcons.gear),
            onPressed: () => unawaited(context.push('/settings/notifications')),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // One kind only (the dashboard's New orders): the selected chip says which; a tap shows every kind.
          if (filter != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: FilterChip(
                selected: true,
                label: Text(notificationKindLabel(l, filter)),
                tooltip: l.notifCentreShowAll,
                onSelected: (_) => context.go('/notifications'),
              ),
            ),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// The bell in Today's app bar (spec §5.3): opens the centre; the badge counts unread notifications (a folded group
/// once). Screen readers hear "Notifications, 3 unread".
class NotificationBell extends ConsumerWidget {
  const NotificationBell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final count = ref.watch(unreadNotificationCountProvider);
    return IconButton(
      tooltip: count == 0 ? l.navNotifications : l.notifBellUnread(count),
      icon: ExcludeSemantics(
        child: Badge.count(
          count: count,
          isLabelVisible: count > 0,
          child: const Icon(AppIcons.bell),
        ),
      ),
      onPressed: () => unawaited(context.push('/notifications')),
    );
  }
}

/// The icon for a notification's kind.
IconData _icon(String kind) => switch (kind) {
  'tomorrow_board' || 'next_date_set' => AppIcons.calendarBlank,
  'today_morning' => AppIcons.calendarCheck,
  'listed_unexpectedly' => AppIcons.warning,
  'new_order' => AppIcons.fileText,
  'status_changed' => AppIcons.gavel,
  'deadline_due' => AppIcons.clock,
  'sync_issue' => AppIcons.cloudWarning,
  _ => AppIcons.bell,
};

/// One notification: the row's title (bold while unread) and body as the server wrote them, when it came, and how
/// many older updates are folded under it. Unread rows have a dot, swipe to mark read, and a menu that does the
/// same (for keyboards and screen readers).
class _NotificationTile extends StatelessWidget {
  const _NotificationTile(
    this.n, {
    required this.earlier,
    required this.onTap,
    required this.onMarkRead,
    super.key,
  });

  final AppNotification n;

  /// In the Earlier group: the date, not the time.
  final bool earlier;
  final VoidCallback onTap;
  final VoidCallback onMarkRead;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = context.colors;
    final f = Formats(Localizations.localeOf(context));
    final title = n.title ?? notificationKindLabel(l, n.kind);
    final at = n.createdAt == null ? null : istOf(n.createdAt!);
    // ponytail: folded updates are only counted ("+2 earlier"), not listed; add an expand if users ask for the
    // older wording (the newest one already says where the case stands).
    final meta = [
      if (at != null)
        if (earlier) f.shortDate(at) else f.time(at),
      if (n.earlier.isNotEmpty) l.notifCentreFolded(n.earlier.length),
    ].join(' · ');
    final tile = FocusRing(
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(_icon(n.kind), color: n.unread ? c.primary : c.ink2),
        title: Text(
          title,
          style: context.text.bodyLarge?.copyWith(
            fontWeight: n.unread ? FontWeight.w700 : null,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (n.body case final body?)
              Text(body, style: context.text.bodyMedium),
            if (meta.isNotEmpty)
              Text(
                meta,
                style: context.text.bodySmall?.copyWith(color: c.ink2),
              ),
          ],
        ),
        trailing: n.unread
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    label: l.notifCentreUnread,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: c.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  PopupMenuButton<bool>(
                    tooltip: l.notifCentreMoreActions(title),
                    icon: const Icon(AppIcons.dotsThreeVertical),
                    onSelected: (_) => onMarkRead(),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: true,
                        child: Text(l.notifCentreMarkRead),
                      ),
                    ],
                  ),
                ],
              )
            : null,
        onTap: onTap,
      ),
    );
    if (!n.unread) return tile;
    // A swipe marks it read and the row stays (it only loses its dot).
    return Dismissible(
      key: ValueKey('swipe-${n.id}'),
      confirmDismiss: (_) async {
        onMarkRead();
        return false;
      },
      background: const _SwipeBackground(
        alignment: AlignmentDirectional.centerStart,
      ),
      secondaryBackground: const _SwipeBackground(
        alignment: AlignmentDirectional.centerEnd,
      ),
      child: tile,
    );
  }
}

/// "Mark as read" behind a row being swiped.
class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({required this.alignment});

  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    final s = context.colors.of(StatusKind.success);
    return ColoredBox(
      color: s.bg,
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(AppIcons.checks, color: s.fg),
              const SizedBox(width: 8),
              Text(
                context.l10n.notifCentreMarkRead,
                style: context.text.bodyMedium?.copyWith(color: s.fg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Loading: rows shaped like notifications.
class _SkeletonRows extends StatelessWidget {
  const _SkeletonRows();

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var i = 0; i < 5; i++)
        const Padding(
          padding: EdgeInsets.only(bottom: 20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Skeleton(width: 24, height: 24),
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Skeleton(width: 160),
                    SizedBox(height: 8),
                    Skeleton(),
                    SizedBox(height: 8),
                    Skeleton(width: 80, height: 12),
                  ],
                ),
              ),
            ],
          ),
        ),
    ],
  );
}
