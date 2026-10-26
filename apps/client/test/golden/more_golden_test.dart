@Tags(['golden'])
library;

import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';
import 'scene_goldens.dart';

/// More and Settings goldens (spec §5.2) on a phone × light/dark/sunlight × en/hi × text scale 1.0/2.0. Reference
/// images are rendered on Windows; CI runs this file on windows-latest.
void main() {
  setUpAll(loadAppFonts);
  sceneGoldens('more', {'more': 'more', 'settings': 'settings'});
}
