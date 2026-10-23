import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:flutter/material.dart';

@immutable
class PaletteCommand {
  const PaletteCommand({
    required this.label,
    required this.icon,
    required this.run,
    this.shortcut,
  });

  final String label;
  final IconData icon;
  final VoidCallback run;
  final String? shortcut;
}

/// Ctrl+K command bar (desktop, spec §5.12). Enter runs the top match.
Future<void> showCommandPalette(
  BuildContext context,
  List<PaletteCommand> commands,
) => showDialog<void>(
  context: context,
  builder: (_) => CommandPalette(commands: commands),
);

class CommandPalette extends StatefulWidget {
  const CommandPalette({required this.commands, super.key});

  final List<PaletteCommand> commands;

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  String _query = '';

  List<PaletteCommand> get _matches {
    final q = _query.trim().toLowerCase();
    return q.isEmpty
        ? widget.commands
        : widget.commands
              .where((c) => c.label.toLowerCase().contains(q))
              .toList();
  }

  void _run(PaletteCommand c) {
    Navigator.of(context).pop();
    c.run();
  }

  @override
  Widget build(BuildContext context) {
    final matches = _matches;
    return Dialog(
      alignment: const Alignment(0, -0.6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 440),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SearchField(
                hint: context.l10n.commandPaletteHint,
                autofocus: true,
                onChanged: (v) => setState(() => _query = v),
                onSubmitted: (_) {
                  if (matches.isNotEmpty) _run(matches.first);
                },
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final c in matches)
                      ListTile(
                        leading: Icon(c.icon),
                        title: Text(c.label),
                        trailing: c.shortcut == null
                            ? null
                            : Text(
                                c.shortcut!,
                                style: context.text.labelMedium?.copyWith(
                                  color: context.colors.ink2,
                                ),
                              ),
                        onTap: () => _run(c),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
