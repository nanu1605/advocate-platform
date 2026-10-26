import 'dart:math';

import 'package:advocate_app/core/krutidev.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';

/// Offers to convert Hindi typed in the Kruti Dev font (spec §12.11): a paste from an old document shows as
/// "U;k;ky;" instead of न्यायालय. Only the Kruti Dev text pasted (or typed in at once) is converted, so English
/// already in the field stays as it is; in a field that holds Kruti Dev when it opens, the paragraphs that look like
/// it. Nothing is converted without the tap, which can be undone in the field and leaves the cursor in
/// [focusNode]'s field.
class KrutidevOffer extends StatefulWidget {
  const KrutidevOffer(this.controller, {required this.focusNode, super.key});

  final TextEditingController controller;
  final FocusNode focusNode;

  @override
  State<KrutidevOffer> createState() => _KrutidevOfferState();
}

class _KrutidevOfferState extends State<KrutidevOffer> {
  late String _text = widget.controller.text;

  /// Where the Kruti Dev text is, as [start, end) in [_text], in order: moved and resized with each edit.
  late List<(int, int)> _ranges = _paragraphs(_text);

  /// The paragraphs of [text] that look like Kruti Dev; the whole of it only when none does on its own but the
  /// whole does (short lines), so an English line in a saved note stays English.
  static List<(int, int)> _paragraphs(String text) {
    final ranges = <(int, int)>[];
    var at = 0;
    for (final p in text.split('\n')) {
      if (looksLikeKrutidev(p)) ranges.add((at, at + p.length));
      at += p.length + 1;
    }
    return ranges.isEmpty && looksLikeKrutidev(text)
        ? [(0, text.length)]
        : ranges;
  }

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

  /// Finds the edit (the text between what the old and new text share at each end) and moves the ranges after it.
  /// A range the edit falls inside takes it in, so a fix inside a paste keeps it; text inserted elsewhere that looks
  /// like Kruti Dev is a new range. A range goes once it no longer looks like Kruti Dev.
  /// ponytail: an edit whose first or last letters repeat the text beside it is placed off by them; the selection
  /// would pin it down if that matters.
  void _check() {
    final (old, text) = (_text, widget.controller.text);
    if (old == text) return;
    _text = text;
    var start = 0;
    while (start < old.length &&
        start < text.length &&
        old.codeUnitAt(start) == text.codeUnitAt(start)) {
      start++;
    }
    var end = 0;
    while (end < old.length - start &&
        end < text.length - start &&
        old.codeUnitAt(old.length - 1 - end) ==
            text.codeUnitAt(text.length - 1 - end)) {
      end++;
    }
    final oldEnd = old.length - end;
    final delta = text.length - old.length;
    final inside = [
      for (final r in _ranges)
        if (r.$1 < oldEnd && r.$2 > start) r,
    ];
    final (from, to) = inside.isEmpty
        ? (start, oldEnd + delta)
        : (min(inside.first.$1, start), max(inside.last.$2, oldEnd) + delta);
    final shown = _ranges.isNotEmpty;
    _ranges = [
      for (final r in _ranges)
        if (r.$2 <= start) r,
      if (looksLikeKrutidev(text.substring(from, to))) (from, to),
      for (final (a, b) in _ranges)
        if (a >= oldEnd) (a + delta, b + delta),
    ];
    if (_ranges.isNotEmpty != shown) setState(() {});
  }

  /// Converts the ranges, last first so the earlier ones stay put, as one edit with the cursor after the last: a
  /// valid selection, which the field's undo history needs (a bare `text =` drops it, and the field then puts the
  /// cursor at the end).
  void _convert() {
    final old = _text;
    var text = old;
    for (final (a, b) in _ranges.reversed) {
      text = text.replaceRange(a, b, krutidevToUnicode(text.substring(a, b)));
    }
    // Nothing after the last range changed.
    final cursor = text.length - (old.length - _ranges.last.$2);
    _text = text; // the change below is this one: nothing left to convert
    setState(() => _ranges = []);
    widget.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: cursor),
    );
    // The button goes with the offer: keep the keyboard in the field.
    widget.focusNode.requestFocus();
    announce(context, context.l10n.krutidevConverted);
  }

  @override
  Widget build(BuildContext context) {
    if (_ranges.isEmpty) return const SizedBox.shrink();
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
