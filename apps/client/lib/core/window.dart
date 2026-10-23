import 'dart:ui';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

const _minSize = Size(1024, 640);
const _key = 'window.bounds';

/// Windows: minimum 1024 × 640 and the window reopens where it was left (spec §5.2).
Future<void> setUpWindow(SharedPreferences prefs) async {
  await windowManager.ensureInitialized();
  final saved = prefs.getStringList(_key)?.map(double.tryParse).toList();
  final bounds = saved != null && saved.length == 4 && !saved.contains(null)
      ? Rect.fromLTWH(saved[0]!, saved[1]!, saved[2]!, saved[3]!)
      : null;
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      minimumSize: _minSize,
      size: Size(1280, 800),
      center: true,
    ),
    () async {
      if (bounds != null &&
          bounds.width >= _minSize.width &&
          bounds.height >= _minSize.height) {
        await windowManager.setBounds(bounds);
      }
      await windowManager.show();
      await windowManager.focus();
    },
  );
  windowManager.addListener(_BoundsSaver(prefs));
}

class _BoundsSaver extends WindowListener {
  _BoundsSaver(this._prefs);

  final SharedPreferences _prefs;

  Future<void> _save() async {
    if (await windowManager.isMaximized() ||
        await windowManager.isMinimized()) {
      return;
    }
    final b = await windowManager.getBounds();
    await _prefs.setStringList(
      _key,
      [b.left, b.top, b.width, b.height].map((v) => '$v').toList(),
    );
  }

  @override
  void onWindowResized() => _save();

  @override
  void onWindowMoved() => _save();
}
