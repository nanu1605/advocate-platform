import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens [Uri] outside the app (the official portal, an order's or document's file, a client's `tel:`); false when
/// nothing could open it. Tests override it.
final openExternalProvider = Provider<Future<bool> Function(Uri)>(
  (_) =>
      (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);

/// Shows [message] in a snackbar, replacing the one showing.
void showMessage(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));

/// Opens [uri] outside the app, or says it couldn't.
Future<void> openExternal(BuildContext context, WidgetRef ref, Uri uri) async {
  final message = context.l10n.errorGeneric;
  final opened = await ref
      .read(openExternalProvider)(uri)
      .catchError((Object _) => false);
  if (!opened && context.mounted) showMessage(context, message);
}

/// Gets a short-lived file link from the API with [url] and opens it outside the app (the in-app viewer is task
/// 10), or says why not: offline, not ready, not published. Never puts a title in the link.
Future<void> openFromApi(
  BuildContext context,
  WidgetRef ref,
  Future<String> Function(ApiClient api, String orgId) url,
) async {
  final l = context.l10n;
  final org = ref.read(currentOrgIdProvider);
  try {
    if (org == null) throw const ApiException('NOT_A_MEMBER');
    final link = await url(ref.read(apiClientProvider), org);
    if (context.mounted) await openExternal(context, ref, Uri.parse(link));
  } on ApiException catch (e) {
    if (context.mounted) showMessage(context, errorText(l, e));
  }
}
