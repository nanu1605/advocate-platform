import 'dart:async';
import 'dart:convert';

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_theme.dart';
import 'package:advocate_app/data/auth.dart';
import 'package:advocate_app/features/lock/app_lock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

export 'fakes.dart';

/// Loads every font in FontManifest.json (Mukta, Phosphor, Material Icons) so tests render real glyphs.
Future<void> loadAppFonts() async {
  final manifest = json.decode(
    await rootBundle.loadString('FontManifest.json'),
  ) as List<dynamic>;
  for (final entry in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(entry['family'] as String);
    for (final font in (entry['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
}

const Map<String, AppThemeMode> themes = {
  'light': AppThemeMode.light,
  'dark': AppThemeMode.dark,
  'sunlight': AppThemeMode.sunlight,
};

/// A themed, localised host for one widget, with a fixed text scale.
Widget host(
  Widget child, {
  AppThemeMode theme = AppThemeMode.light,
  String locale = 'en',
  double scale = 1,
  Key? boundaryKey,
  double width = 400,
  double? height,
}) {
  final colors = colorsFor(theme, Brightness.light);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTheme(colors, reduceMotion: false),
    locale: Locale(locale),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: boundaryKey,
            child: SizedBox(
              width: width,
              height: height,
              child: Material(
                color: colors.bg,
                child: Padding(padding: const EdgeInsets.all(16), child: child),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class FakeAuth implements AuthRepository {
  FakeAuth({this.signedIn = false});

  final _changes = StreamController<bool>.broadcast();
  bool signedIn;
  final sent = <String>[];

  @override
  bool get isSignedIn => signedIn;

  @override
  String? get accessToken => signedIn ? 'token' : null;

  @override
  String? get userId => signedIn ? 'user-1' : null;

  @override
  Stream<bool> get changes => _changes.stream;

  @override
  Future<void> sendOtp(String phone) async => sent.add(phone);

  @override
  Future<void> verifyOtp(String phone, String code) async {
    if (code != '123456') {
      // What Supabase Auth returns for a wrong or expired code.
      throw const AuthException(
        'Token has expired or is invalid',
        statusCode: '403',
      );
    }
    signedIn = true;
    _changes.add(true);
  }

  @override
  Future<void> signOut() async {
    signedIn = false;
    _changes.add(false);
  }
}

class MemoryLockStore extends LockStore {
  LockMethod? method;
  String? hash;
  String? salt;
  int timeout = 5;

  @override
  Future<AppLockState> load() async =>
      AppLockState(method: method, timeoutMinutes: timeout);

  @override
  Future<void> saveMethod(
    LockMethod method, {
    String? pinHash,
    String? salt,
  }) async {
    this.method = method;
    hash = pinHash;
    this.salt = salt;
  }

  @override
  Future<(String?, String?)> pin() async => (hash, salt);

  @override
  Future<void> saveTimeout(int minutes) async => timeout = minutes;

  @override
  Future<void> clear() async {
    method = null;
    hash = null;
    salt = null;
  }
}

class FakeDeviceAuth extends DeviceAuth {
  FakeDeviceAuth({this.isAvailable = false, this.succeeds = true});

  final bool isAvailable;
  final bool succeeds;

  @override
  Future<bool> available() async => isAvailable;

  @override
  Future<bool> authenticate(String reason) async => succeeds;
}
