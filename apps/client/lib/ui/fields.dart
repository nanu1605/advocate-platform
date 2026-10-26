import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Indian mobile: 10 digits starting 6–9.
bool isValidIndianMobile(String s) => RegExp(r'^[6-9]\d{9}$').hasMatch(s);

/// Caps a field at [max] Unicode code points, the way the API counts (`max_length`). Flutter's own limit counts what
/// a reader sees as one character: "कि" is one of those but two code points, so a Hindi text it allows can be refused.
/// Cuts at a character boundary; waits while an input method is composing, like Flutter's.
class CodePointLimit extends TextInputFormatter {
  const CodePointLimit(this.max);

  final int max;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.runes.length <= max ||
        (newValue.composing.isValid && !newValue.composing.isCollapsed)) {
      return newValue;
    }
    // An edit inside a full field changes nothing.
    if (oldValue.text.runes.length == max) return oldValue;
    var runes = 0;
    final kept = newValue.text.characters
        .takeWhile((c) => (runes += c.runes.length) <= max)
        .string;
    return TextEditingValue(
      text: kept,
      selection: TextSelection.collapsed(offset: kept.length),
    );
  }
}

/// Text field with inline error announced to screen readers (spec §5.9).
class AppTextField extends StatelessWidget {
  const AppTextField({
    required this.label,
    this.controller,
    this.hint,
    this.error,
    this.keyboardType,
    this.inputFormatters,
    this.prefixText,
    this.prefixIcon,
    this.suffix,
    this.autofillHints,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.obscure = false,
    this.style,
    this.textInputAction,
    super.key,
  });

  final String label;
  final TextEditingController? controller;
  final String? hint;
  final String? error;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final String? prefixText;
  final IconData? prefixIcon;
  final Widget? suffix;
  final Iterable<String>? autofillHints;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final bool obscure;
  final TextStyle? style;
  final TextInputAction? textInputAction;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    autofocus: autofocus,
    obscureText: obscure,
    keyboardType: keyboardType,
    inputFormatters: inputFormatters,
    autofillHints: autofillHints,
    onChanged: onChanged,
    onSubmitted: onSubmitted,
    textInputAction: textInputAction,
    style: style ?? context.text.bodyLarge,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      errorText: error,
      errorMaxLines: 3,
      prefixText: prefixText,
      prefixIcon: prefixIcon == null ? null : Icon(prefixIcon),
      suffixIcon: suffix,
    ),
  );
}

/// +91 prefix, digits only, max 10.
class PhoneField extends StatelessWidget {
  const PhoneField({
    required this.controller,
    this.error,
    this.onSubmitted,
    super.key,
  });

  final TextEditingController controller;
  final String? error;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) => AppTextField(
    controller: controller,
    label: context.l10n.phoneLabel,
    hint: context.l10n.phoneHint,
    error: error,
    prefixText: '+91 ',
    keyboardType: TextInputType.phone,
    autofillHints: const [AutofillHints.telephoneNumberNational],
    inputFormatters: [
      FilteringTextInputFormatter.digitsOnly,
      LengthLimitingTextInputFormatter(10),
    ],
    textInputAction: TextInputAction.done,
    onSubmitted: onSubmitted,
    autofocus: true,
  );
}

/// One 6-digit field with SMS one-time-code autofill.
class OtpField extends StatelessWidget {
  const OtpField({
    required this.controller,
    this.error,
    this.onCompleted,
    super.key,
  });

  final TextEditingController controller;
  final String? error;
  final ValueChanged<String>? onCompleted;

  @override
  Widget build(BuildContext context) => AppTextField(
    controller: controller,
    label: context.l10n.otpLabel,
    error: error,
    keyboardType: TextInputType.number,
    autofillHints: const [AutofillHints.oneTimeCode],
    inputFormatters: [
      FilteringTextInputFormatter.digitsOnly,
      LengthLimitingTextInputFormatter(6),
    ],
    style: context.text.titleLarge?.copyWith(letterSpacing: 8),
    autofocus: true,
    onChanged: (v) {
      if (v.length == 6) onCompleted?.call(v);
    },
  );
}

/// DD-MM-YYYY entry with a calendar picker in the current language.
class DateField extends StatefulWidget {
  const DateField({
    required this.onChanged,
    this.initial,
    this.label,
    this.firstDate,
    this.lastDate,
    this.controller,
    super.key,
  });

  final ValueChanged<DateTime?> onChanged;
  final DateTime? initial;
  final String? label;
  final DateTime? firstDate;
  final DateTime? lastDate;

  /// Holds what was typed (set its text instead of [initial]), e.g. so a form can refuse a date that doesn't
  /// parse: [onChanged] gets null for both an empty and an invalid entry.
  final TextEditingController? controller;

  @override
  State<DateField> createState() => _DateFieldState();
}

class _DateFieldState extends State<DateField> {
  late final _own = TextEditingController(
    text: widget.initial == null ? '' : Formats.entry(widget.initial!),
  );
  TextEditingController get _controller => widget.controller ?? _own;
  String? _error;

  @override
  void dispose() {
    _own.dispose();
    super.dispose();
  }

  void _parse(String s) {
    final d = Formats.parseEntry(s);
    setState(
      () => _error = s.isEmpty || d != null ? null : context.l10n.dateInvalid,
    );
    widget.onChanged(d);
  }

  Future<void> _pick() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: Formats.parseEntry(_controller.text) ?? now,
      firstDate: widget.firstDate ?? DateTime(now.year - 30),
      lastDate: widget.lastDate ?? DateTime(now.year + 5),
    );
    if (picked == null) return;
    _controller.text = Formats.entry(picked);
    _parse(_controller.text);
  }

  @override
  Widget build(BuildContext context) => AppTextField(
    controller: _controller,
    label: widget.label ?? context.l10n.dateLabel,
    hint: context.l10n.dateHint,
    error: _error,
    keyboardType: TextInputType.datetime,
    inputFormatters: [
      FilteringTextInputFormatter.allow(RegExp(r'[\d-]')),
      LengthLimitingTextInputFormatter(10),
    ],
    onChanged: _parse,
    suffix: IconButton(
      tooltip: context.l10n.dateLabel,
      icon: const Icon(AppIcons.calendarBlank),
      onPressed: _pick,
    ),
  );
}

/// Search box. Hindi/English transliteration matching plugs in through [onChanged] consumers (P1 search keys).
class SearchField extends StatelessWidget {
  const SearchField({
    required this.hint,
    this.controller,
    this.focusNode,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    super.key,
  });

  final String hint;
  final TextEditingController? controller;

  /// e.g. for Ctrl+F (spec §5.12).
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    focusNode: focusNode,
    autofocus: autofocus,
    onChanged: onChanged,
    onSubmitted: onSubmitted,
    textInputAction: TextInputAction.search,
    style: context.text.bodyLarge,
    decoration: InputDecoration(
      hintText: hint,
      // Often the box's only label: it wraps rather than cut off at 200% text (spec §5.9).
      hintMaxLines: 2,
      prefixIcon: Icon(AppIcons.magnifyingGlass, color: context.colors.ink2),
      isDense: true,
    ),
  );
}
