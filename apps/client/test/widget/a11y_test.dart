import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/core/theme/app_theme.dart';
import 'package:advocate_app/core/theme/tokens.g.dart';
import 'package:advocate_app/features/dev_kitchen_sink/kitchen_sink.dart';
import 'package:advocate_app/features/onboarding/onboarding_layout.dart';
import 'package:advocate_app/ui/case_card.dart';
import 'package:advocate_app/ui/focus_ring.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/tiles.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';
import 'today_test.dart' show sampleDiary;

/// The size of a 2 dp band of the focus colour (between two rounded rects, or a 2 dp stroke round an icon button's
/// stadium), or null for any other canvas call.
Size? _ringSize(Symbol method, List<dynamic> args) {
  final Paint paint;
  final RRect outer;
  final double width;
  if (method == #drawDRRect) {
    paint = args[2] as Paint;
    outer = args[0] as RRect;
    width = (outer.width - (args[1] as RRect).width) / 2;
  } else if (method == #drawRRect) {
    paint = args[1] as Paint;
    outer = args[0] as RRect;
    width = paint.style == PaintingStyle.stroke ? paint.strokeWidth : 0;
  } else {
    return null;
  }
  final ring =
      paint.color.toARGB32() == lightColors.focus.toARGB32() &&
      width == Radii.focusRing;
  return ring ? outer.outerRect.size : null;
}

/// The sizes of the focus rings [object] and its children paint.
Set<Size> _ringSizes(RenderObject object) {
  final sizes = <Size>{};
  expect(
    object,
    paints..everything((method, args) {
      sizes.addAll([?_ringSize(method, args)]);
      return true;
    }),
  );
  return sizes;
}

/// How many focus rings [object] and its children paint. A chip draws its border twice (its Material and its ink),
/// so rings of one size count once.
int _rings(RenderObject object) => _ringSizes(object).length;

void main() {
  setUpAll(loadAppFonts);
  final en = lookupAppLocalizations(const Locale('en'));
  const card = CaseCardData(
    caseNumber: 'WP 1234/2024',
    title: 'Sharma v. State',
    court: 'MPHC Indore',
  );

  group('focus ring (spec §5.9)', () {
    final controls = {
      'button': find.byType(FilledButton),
      'icon button': find.byType(IconButton),
      'chip': find.byType(FilterChip),
      'list row': find.byType(ClientTile),
      'case card': find.byType(CaseCard),
    };

    void expectRingOn(WidgetTester tester, String? focused) {
      for (final MapEntry(key: name, value: finder) in controls.entries) {
        expect(
          _rings(tester.renderObject(finder)),
          name == focused ? 1 : 0,
          reason: '$name, with ${focused ?? 'nothing'} focused',
        );
      }
    }

    testWidgets('Tab rings each control in turn; touch shows none', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        host(
          Column(
            children: [
              FilledButton(onPressed: () {}, child: const Text('Continue')),
              IconButton(
                tooltip: 'Sunlight',
                onPressed: () {},
                icon: const Icon(AppIcons.sun),
              ),
              FilterChip(label: const Text('Listed'), onSelected: (_) {}),
              ClientTile(name: 'Ramesh Sharma', caseCount: 2, onTap: () {}),
              CaseCard(card, variant: CaseCardVariant.compact, onTap: () {}),
            ],
          ),
          height: 800,
        ),
      );
      expectRingOn(tester, null);

      // A phone starts in touch mode: focus that no key gave shows no ring.
      Focus.of(tester.element(find.text('WP 1234/2024'))).requestFocus();
      await tester.pumpAndSettle();
      expect(FocusManager.instance.highlightMode, FocusHighlightMode.touch);
      expectRingOn(tester, null);
      FocusManager.instance.primaryFocus!.unfocus();
      await tester.pumpAndSettle();

      for (final name in controls.keys) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        expectRingOn(tester, name);
      }

      // A touch puts the app back in touch mode: the card keeps focus but loses its ring.
      await tester.tapAt(const Offset(390, 790));
      await tester.pumpAndSettle();
      expect(FocusManager.instance.highlightMode, FocusHighlightMode.touch);
      expectRingOn(tester, null);
    });

    testWidgets(
      'a click shows no ring, and focus follows the selection (Windows)',
      (tester) async {
        var selected = 0;
        const numbers = ['WP 1001/2024', 'WP 1002/2024'];
        await tester.pumpWidget(
          host(
            StatefulBuilder(
              builder: (context, setState) => Column(
                children: [
                  for (final (i, n) in numbers.indexed)
                    CaseCard(
                      CaseCardData(caseNumber: n, title: '', court: 'MPHC'),
                      variant: CaseCardVariant.compact,
                      selected: selected == i,
                      autofocus: selected == i,
                      onTap: () => setState(() => selected = i),
                    ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final cards = find.byType(CaseCard);
        // The selected card's 2 dp primary border counts as one (the focus colour is the primary).
        int rings(int i) => _rings(tester.renderObject(cards.at(i)));
        String? focused() => FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<CaseCard>()
            ?.data
            .caseNumber;
        expect(focused(), numbers[0]);

        // A mouse leaves Flutter's highlight mode as it was: the click alone hides the ring.
        await tester.tap(cards.at(1), kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
        expect(
          FocusManager.instance.highlightMode,
          FocusHighlightMode.traditional,
        );
        expect([rings(0), rings(1)], [0, 1]);
        expect(focused(), numbers[1], reason: 'focus follows the case opened');

        // A key brings the ring back, on the case now open.
        await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pumpAndSettle();
        expect([rings(0), rings(1)], [0, 2]);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'focus follows the selection in the clients list too (Windows)',
      (tester) async {
        var selected = 0;
        const names = ['Ramesh Sharma', 'Anita Joshi'];
        await tester.pumpWidget(
          host(
            StatefulBuilder(
              builder: (context, setState) => Column(
                children: [
                  for (final (i, name) in names.indexed)
                    ClientTile(
                      name: name,
                      caseCount: 1,
                      selected: selected == i,
                      autofocus: selected == i,
                      onTap: () => setState(() => selected = i),
                    ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        String? focused() => FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<ClientTile>()
            ?.name;
        expect(focused(), names[0]);
        await tester.tap(find.text(names[1]), kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
        expect(focused(), names[1], reason: 'focus follows the client opened');
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets('every row Tab stops on shows the ring: Today, More, '
        'Settings, notification settings', (tester) async {
      for (final location in [
        '/today',
        '/more',
        '/settings',
        '/settings/notifications',
      ]) {
        await pumpApp(
          tester,
          location: location,
          size: const Size(1280, 800),
          // Today's sample day has new orders, items needing attention and tomorrow's link.
          overrides:
              (location == '/today' ? sampleDiary() : FakeDiary()).overrides,
        );
        final seen = <FocusNode>{};
        var rows = 0;
        while (true) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pumpAndSettle();
          final node = FocusManager.instance.primaryFocus!;
          if (!seen.add(node) || seen.length > 100) break;
          // A row's own tap target, not a button or switch inside it.
          Widget? owner;
          node.context!.visitAncestorElements((e) {
            final w = e.widget;
            if (w is ListTile ||
                w is ButtonStyleButton ||
                w is IconButton ||
                w is PopupMenuButton ||
                w is Switch ||
                w is Checkbox) {
              owner = w;
              return false;
            }
            return true;
          });
          if (owner is! ListTile) continue;
          rows++;
          final ring = find.ancestor(
            of: find.byElementPredicate((e) => e == node.context),
            matching: find.byType(FocusRing),
          );
          expect(ring, findsWidgets, reason: '$location: ${node.context}');
          expect(_rings(tester.renderObject(ring.first)), 1, reason: location);
        }
        expect(rows, greaterThan(0), reason: location);
      }
    });

    testWidgets("Material's own destinations get the app's ring", (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(lightColors, reduceMotion: false),
          builder: (context, child) => DestinationFocusRing(child: child!),
          home: DefaultTabController(
            length: 2,
            child: Scaffold(
              body: Row(
                children: [
                  NavigationRail(
                    selectedIndex: 0,
                    onDestinationSelected: (_) {},
                    labelType: NavigationRailLabelType.all,
                    destinations: const [
                      NavigationRailDestination(
                        icon: Icon(AppIcons.sun),
                        label: Text('Today'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(AppIcons.sun),
                        label: Text('Cases'),
                      ),
                    ],
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        const TabBar(
                          tabs: [
                            Tab(text: 'Timeline'),
                            Tab(text: 'Notes'),
                          ],
                        ),
                        SegmentedButton<int>(
                          segments: const [
                            ButtonSegment(value: 0, label: Text('Day')),
                            ButtonSegment(value: 1, label: Text('Week')),
                          ],
                          selected: const {0},
                          onSelectionChanged: (_) {},
                        ),
                        PopupMenuButton<int>(
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 0, child: Text('Archive')),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final app = find.byType(DestinationFocusRing);
      Size ringOf(FocusNode node) => node.rect.deflate(Radii.focusRing).size;
      bool inside<T extends Widget>(FocusNode node) =>
          node.context!.findAncestorWidgetOfExactType<T>() != null;
      expect(_rings(tester.renderObject(app)), 0);

      // Two rail destinations, two tabs and two segments, in reading order, each ringed 2 dp inside its own box; the
      // menu button has the theme's ring, outside, and the app's stays off it.
      final ringed = <Type>[];
      late FocusNode button;
      for (var i = 0; i < 10; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        final node = FocusManager.instance.primaryFocus!;
        final rings = _ringSizes(tester.renderObject(app));
        if (inside<PopupMenuButton<int>>(node)) {
          button = node;
          expect(rings, isNot(contains(ringOf(button))));
          break;
        }
        ringed.add(
          inside<NavigationRail>(node)
              ? NavigationRail
              : inside<TabBar>(node)
              ? TabBar
              : SegmentedButton<int>,
        );
        expect(rings, {ringOf(node)}, reason: '${ringed.last}');
      }
      expect(ringed..sort((a, b) => '$a'.compareTo('$b')), [
        NavigationRail,
        NavigationRail,
        SegmentedButton<int>,
        SegmentedButton<int>,
        TabBar,
        TabBar,
      ]);

      // The open menu's item.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      final item = FocusManager.instance.primaryFocus!;
      expect(inside<PopupMenuItem<int>>(item), isTrue);
      expect(_ringSizes(tester.renderObject(app)), contains(ringOf(item)));

      // After a touch, a destination with focus shows none.
      await tester.tapAt(const Offset(790, 590));
      await tester.pumpAndSettle();
      Focus.of(tester.element(find.text('Cases'))).requestFocus();
      await tester.pumpAndSettle();
      expect(
        inside<NavigationRail>(FocusManager.instance.primaryFocus!),
        isTrue,
      );
      expect(_rings(tester.renderObject(app)), 0);
    });

    testWidgets('a button inside a row takes the ring from the row', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          CaseCard(
            card,
            variant: CaseCardVariant.hero,
            onTap: () {},
            actions: [
              FilledButton(onPressed: () {}, child: const Text('Open')),
            ],
          ),
        ),
      );
      final hero = tester.renderObject(find.byType(CaseCard));
      final button = find.byType(FilledButton);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(_rings(hero), 1);
      expect(_rings(tester.renderObject(button)), 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(_rings(tester.renderObject(button)), 1);
      expect(_rings(hero), 1, reason: "the button's ring only");
    });
  });

  testWidgets(
    'the desktop command bar: 48 dp, and a screen reader can open it',
    (tester) async {
      tester.view.physicalSize = const Size(1132, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final handle = tester.ensureSemantics();
      final desktop = kitSections.firstWhere((s) => s.id == 'scaffold_desktop');
      await tester.pumpWidget(
        host(Builder(builder: desktop.build), width: 1132, height: 640),
      );
      await tester.pump();
      // Its own node: the label and tap no longer merge into the page around it.
      final bar = find.bySemanticsLabel('${en.commandPaletteHint} (Ctrl+K)');
      expect(
        tester.getSemantics(bar),
        isSemantics(isButton: true, hasTapAction: true),
      );
      expect(tester.getSize(bar).height, greaterThanOrEqualTo(48));
      handle.dispose();
    },
  );

  testWidgets('reduce motion in the app: a sheet appears without sliding', (
    tester,
  ) async {
    await pumpApp(tester, overrides: FakeDiary().overrides);
    final sheet = find.byType(BottomSheet);
    Future<(double, double)> openAddSheet() async {
      await tester.tap(find.text(en.navAdd));
      await tester.pump();
      final first = tester.getTopLeft(sheet).dy;
      await tester.pumpAndSettle();
      final settled = tester.getTopLeft(sheet).dy;
      Navigator.of(tester.element(sheet)).pop();
      await tester.pumpAndSettle();
      return (first, settled);
    }

    // By default it slides up: its first frame is lower than where it settles.
    final (slideFrom, slideTo) = await openAddSheet();
    expect(slideFrom, greaterThan(slideTo));

    // The app's own toggle (settings.reduce_motion), not the OS flag.
    await container(tester)
        .read(settingsProvider.notifier)
        .setReduceMotion(value: true);
    await tester.pumpAndSettle();
    final (first, settled) = await openAddSheet();
    expect(first, settled);
  });

  testWidgets('a step notice is said once: announced on Windows and iOS, a '
      'live region on Android', (tester) async {
    final handle = tester.ensureSemantics();
    const message = 'No internet connection';
    bool live() =>
        tester.getSemantics(find.text(message)).flagsCollection.isLiveRegion;

    // Android: no announcements, so a live region.
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures();
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(host(const StepNotice(message)));
    await tester.pump();
    expect(live(), isTrue);

    final announced = captureAnnouncements(tester);
    await tester.pumpWidget(host(const SizedBox()));
    await tester.pumpWidget(host(const StepNotice(message)));
    await tester.pump();
    expect(announced, [message]);
    expect(live(), isFalse, reason: 'iOS would read it a second time');
    handle.dispose();
  });

  testWidgets('the OS reduce-motion flag, turned on while the app runs, '
      'stops page transitions too', (tester) async {
    await pumpApp(tester, overrides: FakeDiary().overrides);
    PageTransitionsBuilder? transition() {
      final theme = Theme.of(tester.element(find.byType(Scaffold).first));
      return theme.pageTransitionsTheme.builders[theme.platform];
    }

    expect(transition(), isA<FadeForwardsPageTransitionsBuilder>());

    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpAndSettle();
    expect(transition(), isNot(isA<FadeForwardsPageTransitionsBuilder>()));
  });

  testWidgets("haptics off: Flutter's own long-press buzz is off too", (
    tester,
  ) async {
    final buzzes = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') buzzes.add(call.arguments);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pumpApp(tester, overrides: FakeDiary().overrides);
    Future<void> longPressSunlight() async {
      await tester.longPress(find.byTooltip(en.sunlightToggle));
      await tester.pump(
        const Duration(seconds: 3),
      ); // the tooltip shows, then hides
      await tester.pumpAndSettle();
    }

    await longPressSunlight();
    expect(buzzes, hasLength(1), reason: 'haptics on: the tooltip buzzes');

    await container(tester)
        .read(settingsProvider.notifier)
        .setHaptics(value: false);
    await tester.pumpAndSettle();
    await longPressSunlight();
    expect(buzzes, hasLength(1), reason: 'haptics off: no new buzz');
  });

  test('the theme passes haptics off to every themeable feedback', () {
    final t = buildTheme(lightColors, reduceMotion: false, haptics: false);
    for (final style in [
      t.filledButtonTheme.style,
      t.outlinedButtonTheme.style,
      t.textButtonTheme.style,
      t.iconButtonTheme.style,
    ]) {
      expect(style!.enableFeedback, isFalse);
    }
    expect(t.listTileTheme.enableFeedback, isFalse);
    expect(t.tooltipTheme.enableFeedback, isFalse);
    expect(t.floatingActionButtonTheme.enableFeedback, isFalse);
  });
}
