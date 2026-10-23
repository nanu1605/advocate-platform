import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/settings/settings.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/features/onboarding/onboarding_layout.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Version of the itemised notice below; bump it when the notice text changes (stored in `consents`).
const consentNoticeVersion = 'v1';

/// Itemised privacy notice (spec §4.1 step 3, §15.4). Account + case processing is required;
/// WhatsApp alerts and analytics are separate, optional and off by default.
class ConsentScreen extends ConsumerStatefulWidget {
  const ConsentScreen({super.key});

  @override
  ConsumerState<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends ConsumerState<ConsentScreen> {
  bool _required = false;
  bool _whatsapp = false;
  bool _analytics = false;
  bool _busy = false;
  String? _error;

  Future<void> _agree() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(apiClientProvider)
          .postConsents(
            version: consentNoticeVersion,
            decisions: {
              'account_processing': true,
              'whatsapp_alerts': _whatsapp,
              'analytics': _analytics,
            },
          );
      await ref
          .read(settingsProvider.notifier)
          .setConsentVersion(consentNoticeVersion);
    } on ApiException catch (e) {
      if (mounted) {
        setState(
          () => _error = e.code == 'NETWORK'
              ? context.l10n.errorNetwork
              : context.l10n.errorGeneric,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    Widget item(IconData icon, String title, String body) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: context.colors.ink2),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.text.titleSmall),
                Text(body, style: context.text.bodyLarge),
              ],
            ),
          ),
        ],
      ),
    );
    return OnboardingLayout(
      title: l.consentTitle,
      subtitle: l.consentIntro,
      primary: BusyButton(
        label: l.agreeContinue,
        busy: _busy,
        onPressed: _required ? _agree : null,
      ),
      children: [
        item(AppIcons.folderSimple, l.consentWhatTitle, l.consentWhat),
        item(AppIcons.question, l.consentWhyTitle, l.consentWhy),
        item(AppIcons.mapPin, l.consentWhereTitle, l.consentWhere),
        // ponytail: "Read the full privacy policy" link waits for the lawyer-drafted policy URL (spec §15.9).
        const Divider(),
        CheckboxListTile(
          value: _required,
          onChanged: (v) => setState(() => _required = v ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          title: Text(l.consentRequired),
        ),
        SwitchListTile(
          value: _whatsapp,
          onChanged: (v) => setState(() => _whatsapp = v),
          contentPadding: EdgeInsets.zero,
          title: Text(l.consentWhatsapp),
        ),
        SwitchListTile(
          value: _analytics,
          onChanged: (v) => setState(() => _analytics = v),
          contentPadding: EdgeInsets.zero,
          title: Text(l.consentAnalytics),
        ),
        if (_error != null)
          Semantics(
            liveRegion: true,
            child: Text(
              _error!,
              style: context.text.bodyLarge?.copyWith(
                color: context.colors.of(StatusKind.urgent).fg,
              ),
            ),
          ),
      ],
    );
  }
}
