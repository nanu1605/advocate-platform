# 0007 — Phosphor icons from vendored fonts instead of phosphor_flutter

Status: accepted

## Context
Spec §5.8/§7.1 names Phosphor icons via `phosphor_flutter`. Its latest release (2.1.0, May 2024) does not compile on
Flutter 3.47: `PhosphorIconData extends IconData`, and `IconData` is now a final class.

## Decision
Keep the Phosphor icon set (MIT) but bundle its Regular, Fill and Bold fonts in `apps/client/assets/fonts/Phosphor/`
(licence included) and declare only the icons we use as `IconData` constants in `lib/ui/icons.dart`.
`inlineIconSize()` there scales inline icons with the user's text size.

## Consequences
- No third-party Dart code for icons; icon tree-shaking still works (const `IconData`).
- Adding an icon = look up its code point on phosphoricons.com and add one constant.
