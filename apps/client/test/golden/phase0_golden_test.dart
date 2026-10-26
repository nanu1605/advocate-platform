@Tags(['golden'])
library;

import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';
import 'scene_goldens.dart';

/// Phase 0 first-run goldens (spec §4.1, §15.2): the welcome (language), phone number, code, consent, app lock setup
/// and lock screens on a phone × light/dark/sunlight × en/hi × text scale 1.0/2.0. Reference images are rendered on
/// Windows; CI runs this file on windows-latest.
void main() {
  setUpAll(loadAppFonts);
  sceneGoldens('phase0', {
    'welcome': 'welcome',
    'sign-in phone': 'phone',
    'sign-in code': 'code',
    'consent': 'consent',
    'app lock setup': 'app_lock',
    'lock screen': 'lock',
  });
}
