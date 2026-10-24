/// Build-time configuration (`--dart-define-from-file=env.local.json`, written by `just setup`).
abstract final class Config {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const apiUrl = String.fromEnvironment('API_URL');

  /// Empty disables offline sync (the app still runs on the API).
  static const powersyncUrl = String.fromEnvironment('POWERSYNC_URL');

  static bool get hasBackend =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty && apiUrl.isNotEmpty;
}
