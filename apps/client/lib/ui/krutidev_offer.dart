import 'package:advocate_app/core/krutidev.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';

/// Offers to convert the text in [controller] once it reads as Hindi typed in the Kruti Dev font (spec §12.11): a
/// paste from an old document shows as "U;k;ky;" instead of न्यायालय. Nothing is converted without the tap.
class KrutidevOffer extends StatefulWidget {
  const KrutidevOffer(this.controller, {super.key});

  final TextEditingController controller;

  @override
  State<KrutidevOffer> createState() => _KrutidevOfferState();
}

class _KrutidevOfferState extends State<KrutidevOffer> {
  late bool _shown = looksLikeKrutidev(widget.controller.text);

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_check);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_check);
    super.dispose();
  }

  void _check() {
    final shown = looksLikeKrutidev(widget.controller.text);
    if (shown != _shown) setState(() => _shown = shown);
  }

  void _convert() {
    widget.controller.text = krutidevToUnicode(widget.controller.text);
    announce(context, context.l10n.krutidevConverted);
  }

  @override
  Widget build(BuildContext context) {
    if (!_shown) return const SizedBox.shrink();
    final c = context.colors;
    final l = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                AppIcons.translate,
                size: inlineIconSize(context, 18),
                color: c.ink2,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(l.krutidevFound, style: context.text.bodySmall),
              ),
            ],
          ),
          TextButton(onPressed: _convert, child: Text(l.krutidevConvert)),
        ],
      ),
    );
  }
}
