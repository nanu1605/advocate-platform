import 'package:advocate_app/core/theme/app_theme.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Overridden in main() with the loaded instance.
final prefsProvider = Provider<SharedPreferences>(
  (_) => throw UnimplementedError('prefsProvider must be overridden'),
);

@immutable
class AppSettings {
  const AppSettings({
    this.locale,
    this.theme = AppThemeMode.system,
    this.reduceMotion = false,
    this.haptics = true,
    this.consentVersion,
  });

  /// null until the user picks a language on the first screen.
  final Locale? locale;
  final AppThemeMode theme;
  final bool reduceMotion;
  final bool haptics;

  /// Version of the privacy notice the user accepted on this device (server keeps the record).
  final String? consentVersion;

  AppSettings copyWith({
    Locale? locale,
    AppThemeMode? theme,
    bool? reduceMotion,
    bool? haptics,
    String? consentVersion,
  }) => AppSettings(
    locale: locale ?? this.locale,
    theme: theme ?? this.theme,
    reduceMotion: reduceMotion ?? this.reduceMotion,
    haptics: haptics ?? this.haptics,
    consentVersion: consentVersion ?? this.consentVersion,
  );
}

class SettingsController extends Notifier<AppSettings> {
  static const _locale = 'settings.locale';
  static const _theme = 'settings.theme';
  static const _reduceMotion = 'settings.reduce_motion';
  static const _haptics = 'settings.haptics';
  static const _consent = 'settings.consent_version';

  SharedPreferences get _prefs => ref.read(prefsProvider);

  @override
  AppSettings build() {
    final p = _prefs;
    final code = p.getString(_locale);
    return AppSettings(
      locale: code == null ? null : Locale(code),
      theme:
          AppThemeMode.values.asNameMap()[p.getString(_theme)] ??
          AppThemeMode.system,
      reduceMotion: p.getBool(_reduceMotion) ?? false,
      haptics: p.getBool(_haptics) ?? true,
      consentVersion: p.getString(_consent),
    );
  }

  Future<void> setLocale(Locale locale) async {
    state = state.copyWith(locale: locale);
    await _prefs.setString(_locale, locale.languageCode);
  }

  Future<void> setTheme(AppThemeMode theme) async {
    state = state.copyWith(theme: theme);
    await _prefs.setString(_theme, theme.name);
  }

  Future<void> setReduceMotion({required bool value}) async {
    state = state.copyWith(reduceMotion: value);
    await _prefs.setBool(_reduceMotion, value);
  }

  Future<void> setHaptics({required bool value}) async {
    state = state.copyWith(haptics: value);
    await _prefs.setBool(_haptics, value);
  }

  Future<void> setConsentVersion(String version) async {
    state = state.copyWith(consentVersion: version);
    await _prefs.setString(_consent, version);
  }

  /// Sign-out keeps device preferences (language, theme) but forgets per-account state.
  Future<void> clearAccountState() async {
    state = AppSettings(
      locale: state.locale,
      theme: state.theme,
      reduceMotion: state.reduceMotion,
      haptics: state.haptics,
    );
    await _prefs.remove(_consent);
  }
}

final settingsProvider = NotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);
