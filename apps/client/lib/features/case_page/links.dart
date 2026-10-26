import 'dart:async';

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/ui/app_scaffold.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens [Uri] outside the app (the official portal, a client's `tel:`); false when nothing could open it. Tests
/// override it.
final openExternalProvider = Provider<Future<bool> Function(Uri)>(
  (_) =>
      (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);

/// Opens [path] in another section (a case's client, a client's case): over this page on a phone, so Back returns
/// here (spec §5.1 "Never stuck"); on a wide window the rail moves to that section's list and item instead.
void openInSection(BuildContext context, String path) {
  if (sizeClassOf(MediaQuery.sizeOf(context).width) == SizeClass.expanded) {
    context.go(path);
  } else {
    unawaited(context.push(path));
  }
}

/// Shows [message] in a snackbar, replacing the one showing ([showSnack]).
void showMessage(BuildContext context, String message) =>
    showSnack(ScaffoldMessenger.of(context), message);

/// Opens [uri] outside the app, or says it couldn't.
Future<void> openExternal(BuildContext context, WidgetRef ref, Uri uri) async {
  final message = context.l10n.errorGeneric;
  final opened = await ref
      .read(openExternalProvider)(uri)
      .catchError((Object _) => false);
  if (!opened && context.mounted) showMessage(context, message);
}
