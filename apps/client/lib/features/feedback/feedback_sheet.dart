import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/feedback.dart';
import 'package:advocate_app/data/sync/sync.dart';
import 'package:advocate_app/features/case_page/sheet_form.dart';
import 'package:advocate_app/features/onboarding/onboarding_layout.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:advocate_app/ui/sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// The longest note the API takes (spec §10.2, `POST /v1/feedback`).
const feedbackMaxLength = 4000;

/// "Send feedback" (spec §10.2): a note, with the screen it came from (a route pattern, captured now, before the
/// sheet covers it) and the app version. It needs a connection; a note that couldn't go stays in memory.
Future<void> showFeedbackSheet(BuildContext context) {
  // The top page's pattern, a pushed one included (a case opened from Today): the router's own fullPath leaves
  // pushed pages out.
  final screen = screenPattern(GoRouter.of(context).state.fullPath ?? '');
  return showAppBottomSheet<void>(
    context,
    builder: (_) => _FeedbackSheet(screen),
  );
}

class _FeedbackSheet extends ConsumerStatefulWidget {
  const _FeedbackSheet(this.screen);

  final String screen;

  @override
  ConsumerState<_FeedbackSheet> createState() => _FeedbackSheetState();
}

class _FeedbackSheetState extends ConsumerState<_FeedbackSheet> {
  late final _text = TextEditingController(
    text: ref.read(feedbackDraftProvider),
  );
  String? _error;
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _fail(String message) {
    setState(() => _error = message);
    announce(context, message);
  }

  Future<void> _send() async {
    final l = context.l10n;
    final note = _text.text.trim();
    final offline = ref.read(syncViewProvider).value?.offline ?? false;
    if (note.isEmpty || offline) {
      _fail(note.isEmpty ? l.feedbackEmpty : l.errorNeedsNetwork);
      return;
    }
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final draft = ref.read(feedbackDraftProvider.notifier);
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await ref
          .read(apiClientProvider)
          .sendFeedback(
            note: note,
            screen: widget.screen,
            appVersion: ref.read(appVersionProvider).value,
            orgId: ref.read(currentOrgIdProvider),
          );
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        _fail(e.code == 'RATE_LIMITED' ? l.feedbackTooMany : errorText(l, e));
      }
      return;
    }
    draft.text = '';
    // The sheet may have been swiped away while the note was sending.
    if (mounted) navigator.pop();
    messenger.showSnackBar(SnackBar(content: Text(l.feedbackThanks)));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final version = ref.watch(appVersionProvider).value ?? '…';
    return SheetForm(
      title: l.navFeedback,
      saveLabel: _sending ? l.feedbackSending : l.feedbackSend,
      onSave: _sending ? null : _send,
      children: [
        Text(l.feedbackIntro, style: context.text.bodyMedium),
        TextField(
          controller: _text,
          autofocus: true,
          minLines: 4,
          maxLines: 10,
          // Counted in code points, as the API counts (not maxLength's characters).
          inputFormatters: const [CodePointLimit(feedbackMaxLength)],
          buildCounter:
              (_, {required currentLength, required isFocused, maxLength}) {
                final n = _text.text.runes.length;
                return Text(
                  '$n/$feedbackMaxLength',
                  semanticsLabel: MaterialLocalizations.of(context)
                      .remainingTextFieldCharacterCount(feedbackMaxLength - n),
                  style: context.text.bodySmall,
                );
              },
          textCapitalization: TextCapitalization.sentences,
          style: context.text.bodyLarge,
          onChanged: (s) => ref.read(feedbackDraftProvider.notifier).text = s,
          decoration: InputDecoration(
            labelText: l.feedbackNote,
            alignLabelWithHint: true,
            errorText: _error,
            errorMaxLines: 4,
          ),
        ),
        Text(
          l.feedbackAttached(widget.screen, version),
          style: context.text.bodySmall,
        ),
      ],
    );
  }
}
