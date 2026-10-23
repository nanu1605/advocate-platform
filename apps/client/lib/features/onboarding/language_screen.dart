import 'package:advocate_app/core/brand/brand.g.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// First screen: two large buttons, हिंदी / English (spec §4.1 step 1). Shown in both scripts, so it needs
/// no prior language.
class LanguageScreen extends ConsumerWidget {
  const LanguageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> pick(String code) =>
        ref.read(settingsProvider.notifier).setLocale(Locale(code));
    final big = context.text.titleLarge;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  '${Brand.appNameHi} · ${Brand.appName}',
                  textAlign: TextAlign.center,
                  style: context.text.displaySmall,
                ),
                const SizedBox(height: 8),
                Text(
                  '${Brand.taglineHi}\n${Brand.tagline}',
                  textAlign: TextAlign.center,
                  style: context.text.bodyLarge?.copyWith(
                    color: context.colors.ink2,
                  ),
                ),
                const SizedBox(height: 32),
                Text(
                  'भाषा चुनें · Choose language',
                  textAlign: TextAlign.center,
                  style: context.text.titleMedium,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(64),
                    textStyle: big,
                  ),
                  onPressed: () => pick('hi'),
                  child: const Text('हिंदी'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(64),
                    textStyle: big,
                  ),
                  onPressed: () => pick('en'),
                  child: const Text('English'),
                ),
                const SizedBox(height: 32),
                Text(
                  '${Brand.poweredByHi} · ${Brand.poweredBy}',
                  textAlign: TextAlign.center,
                  style: context.text.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
