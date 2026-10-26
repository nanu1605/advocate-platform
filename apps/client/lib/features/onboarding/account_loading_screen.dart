import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:advocate_app/ui/skeleton.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// /loading: while GET /v1/me loads after sign-in, so the router never guesses the onboarding step; or, when it
/// failed with nothing cached, the offline/error state with Retry (spec §5.4). [AccountController] retries by
/// itself on reconnect.
class AccountLoadingScreen extends ConsumerWidget {
  const AccountLoadingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final account = ref.watch(accountProvider);
    void retry() => ref.invalidate(accountProvider);
    final error = account.isLoading ? null : account.error;
    final offline =
        error is ApiException && error.code == 'NETWORK' ||
        (ref.watch(syncViewProvider).value?.offline ?? false);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            if (offline) const OfflineBanner(steps: true),
            Expanded(
              child: error != null
                  ? ErrorState(
                      message: error is ApiException && error.code == 'NETWORK'
                          ? l.errorNetwork
                          : errorText(l, error),
                      onRetry: retry,
                    )
                  : AnnouncedText(
                      l.accountLoading,
                      child: const Padding(
                        padding: EdgeInsets.fromLTRB(16, 24, 16, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Skeleton(width: 240, height: 36),
                            SizedBox(height: 16),
                            Skeleton(),
                            SizedBox(height: 8),
                            Skeleton(width: 200),
                            SizedBox(height: 32),
                            Skeleton(height: 56),
                            SizedBox(height: 12),
                            Skeleton(height: 56),
                          ],
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
