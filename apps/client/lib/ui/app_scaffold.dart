import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

@immutable
class NavDest {
  const NavDest(this.path, this.icon, this.selectedIcon, this.label);

  final String path;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// Window-size classes (spec §5.2).
enum SizeClass { compact, medium, expanded }

SizeClass sizeClassOf(double width) => width < 600
    ? SizeClass.compact
    : width < 840
    ? SizeClass.medium
    : SizeClass.expanded;

/// App shell (spec §5.11 #1): phone bottom bar with the centre action; rail on tablet/desktop;
/// command bar + keyboard shortcuts on desktop.
class AppScaffold extends StatelessWidget {
  const AppScaffold({
    required this.location,
    required this.phoneDestinations,
    required this.railDestinations,
    required this.onNavigate,
    required this.onCenterAction,
    required this.onCommandPalette,
    required this.child,
    this.centerIcon = AppIcons.plusBold,
    this.centerLabel,
    this.banner,
    this.onNewCase,
    super.key,
  });

  final String location;

  /// Phone: two on the left, centre action, the rest on the right (e.g. Today · Cases · (+) · More).
  final List<NavDest> phoneDestinations;
  final List<NavDest> railDestinations;
  final ValueChanged<String> onNavigate;
  final VoidCallback onCenterAction;
  final VoidCallback onCommandPalette;

  /// Ctrl+N (spec §5.12 "New case"); [onCenterAction] when null.
  final VoidCallback? onNewCase;
  final IconData centerIcon;
  final String? centerLabel;
  final Widget child;

  /// e.g. OfflineBanner.
  final Widget? banner;

  static int? _selected(List<NavDest> dests, String location) {
    for (var i = 0; i < dests.length; i++) {
      if (location == dests[i].path ||
          location.startsWith('${dests[i].path}/')) {
        return i;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final size = sizeClassOf(MediaQuery.sizeOf(context).width);
    final body = Column(
      children: [
        ?banner,
        Expanded(child: child),
      ],
    );
    return size == SizeClass.compact
        ? _phone(context, body)
        : _desktop(context, body, size);
  }

  Widget _phone(BuildContext context, Widget body) {
    final c = context.colors;
    final left = phoneDestinations.take(2).toList();
    final right = phoneDestinations.skip(2).toList();
    final dests = [...left, null, ...right];
    // Routes reached from "More" (calendar, clients…) keep "More" highlighted.
    final selected =
        _selected(phoneDestinations, location) ?? phoneDestinations.length - 1;
    final barIndex = selected < 2 ? selected : selected + 1;
    return Scaffold(
      body: SafeArea(bottom: false, child: body),
      bottomNavigationBar: NavigationBar(
        selectedIndex: barIndex,
        onDestinationSelected: (i) {
          final d = dests[i];
          if (d == null) {
            onCenterAction();
          } else {
            onNavigate(d.path);
          }
        },
        destinations: [
          for (final d in dests)
            if (d == null)
              NavigationDestination(
                icon: Container(
                  width: 56,
                  height: 40,
                  decoration: BoxDecoration(
                    color: c.primaryFill,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Icon(centerIcon, color: c.onPrimary),
                ),
                label: centerLabel ?? context.l10n.navAdd,
              )
            else
              NavigationDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selectedIcon, color: c.primary),
                label: d.label,
              ),
        ],
      ),
    );
  }

  Widget _desktop(BuildContext context, Widget body, SizeClass size) {
    final selected = _selected(railDestinations, location);
    final shortcuts = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyK, control: true):
          onCommandPalette,
      const SingleActivator(LogicalKeyboardKey.keyN, control: true):
          onNewCase ?? onCenterAction,
      for (var i = 0; i < railDestinations.length && i < 9; i++)
        SingleActivator(
          LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i),
          control: true,
        ): () =>
            onNavigate(railDestinations[i].path),
    };
    return CallbackShortcuts(
      bindings: shortcuts,
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: SafeArea(
            child: Row(
              children: [
                NavigationRail(
                  selectedIndex: selected,
                  labelType: NavigationRailLabelType.all,
                  leading: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: FloatingActionButton(
                      elevation: 0,
                      tooltip: centerLabel ?? context.l10n.navAdd,
                      onPressed: onCenterAction,
                      child: Icon(centerIcon),
                    ),
                  ),
                  onDestinationSelected: (i) =>
                      onNavigate(railDestinations[i].path),
                  destinations: [
                    for (final d in railDestinations)
                      NavigationRailDestination(
                        icon: Icon(d.icon),
                        selectedIcon: Icon(d.selectedIcon),
                        label: Text(d.label),
                      ),
                  ],
                ),
                VerticalDivider(width: 1, color: context.colors.line),
                Expanded(
                  child: Column(
                    children: [
                      if (size == SizeClass.expanded)
                        _CommandBar(onTap: onCommandPalette),
                      Expanded(child: body),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CommandBar extends StatelessWidget {
  const _CommandBar({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
      child: Semantics(
        button: true,
        label: '${context.l10n.commandPaletteHint} (Ctrl+K)',
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c.line, width: c.borderWidth),
            ),
            child: Row(
              children: [
                Icon(AppIcons.magnifyingGlass, color: c.ink2, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.l10n.commandPaletteHint,
                    style: context.text.bodyMedium?.copyWith(color: c.ink3),
                  ),
                ),
                Text(
                  'Ctrl+K',
                  style: context.text.labelMedium?.copyWith(color: c.ink2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
