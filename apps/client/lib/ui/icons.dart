import 'package:flutter/widgets.dart';

/// Phosphor icons (MIT, assets/fonts/Phosphor/LICENSE), regular weight by default (spec §5.8).
/// The phosphor_flutter package no longer builds on current Flutter, so the fonts are vendored and
/// only the icons the app uses are declared. To add one, take its code point from
/// https://phosphoricons.com (or the Phosphor font's cmap) and add a constant here.
abstract final class AppIcons {
  static const archive = IconData(0xe00c, fontFamily: 'PhosphorRegular');
  static const arrowClockwise = IconData(0xe036, fontFamily: 'PhosphorRegular');
  static const arrowsClockwise = IconData(
    0xe094,
    fontFamily: 'PhosphorRegular',
  );
  static const arrowsLeftRight = IconData(
    0xe0a0,
    fontFamily: 'PhosphorRegular',
  );
  static const bank = IconData(0xe0b4, fontFamily: 'PhosphorRegular');
  static const bell = IconData(0xe0ce, fontFamily: 'PhosphorRegular');
  static const briefcaseFill = IconData(0xe0ee, fontFamily: 'PhosphorFill');
  static const briefcase = IconData(0xe0ee, fontFamily: 'PhosphorRegular');
  static const calendarBlankFill = IconData(0xe10a, fontFamily: 'PhosphorFill');
  static const calendarBlank = IconData(0xe10a, fontFamily: 'PhosphorRegular');
  static const calendarCheck = IconData(0xe712, fontFamily: 'PhosphorRegular');
  static const caretDown = IconData(0xe136, fontFamily: 'PhosphorRegular');
  static const caretRight = IconData(0xe13a, fontFamily: 'PhosphorRegular');
  static const caretUp = IconData(0xe13c, fontFamily: 'PhosphorRegular');
  static const chatCircleTextFill = IconData(
    0xe16e,
    fontFamily: 'PhosphorFill',
  );
  static const chatCircleText = IconData(0xe16e, fontFamily: 'PhosphorRegular');
  static const checkCircleFill = IconData(0xe184, fontFamily: 'PhosphorFill');
  static const checkSquare = IconData(0xe186, fontFamily: 'PhosphorRegular');
  static const circle = IconData(0xe18a, fontFamily: 'PhosphorRegular');
  static const circleNotch = IconData(0xeb44, fontFamily: 'PhosphorRegular');
  static const clock = IconData(0xe19a, fontFamily: 'PhosphorRegular');
  static const clockCounterClockwise = IconData(
    0xe1a0,
    fontFamily: 'PhosphorRegular',
  );
  static const cloudCheck = IconData(0xe1b0, fontFamily: 'PhosphorRegular');
  static const cloudWarning = IconData(0xea98, fontFamily: 'PhosphorRegular');
  static const coffee = IconData(0xe1c2, fontFamily: 'PhosphorRegular');
  static const dotsThreeCircleFill = IconData(
    0xe200,
    fontFamily: 'PhosphorFill',
  );
  static const dotsThreeCircle = IconData(
    0xe200,
    fontFamily: 'PhosphorRegular',
  );
  static const dotsThreeVertical = IconData(
    0xe208,
    fontFamily: 'PhosphorRegular',
  );
  static const downloadSimpleFill = IconData(
    0xe20c,
    fontFamily: 'PhosphorFill',
  );
  static const filePdf = IconData(0xe702, fontFamily: 'PhosphorRegular');
  static const filePlus = IconData(0xe236, fontFamily: 'PhosphorRegular');
  static const fileText = IconData(0xe23a, fontFamily: 'PhosphorRegular');
  static const filesFill = IconData(0xe710, fontFamily: 'PhosphorFill');
  static const files = IconData(0xe710, fontFamily: 'PhosphorRegular');
  static const fingerprint = IconData(0xe23e, fontFamily: 'PhosphorRegular');
  static const folderSimple = IconData(0xe25a, fontFamily: 'PhosphorRegular');
  static const funnel = IconData(0xe266, fontFamily: 'PhosphorRegular');
  static const gavel = IconData(0xea32, fontFamily: 'PhosphorRegular');
  static const gearFill = IconData(0xe270, fontFamily: 'PhosphorFill');
  static const gear = IconData(0xe270, fontFamily: 'PhosphorRegular');
  static const handshake = IconData(0xe582, fontFamily: 'PhosphorRegular');
  static const image = IconData(0xe2ca, fontFamily: 'PhosphorRegular');
  static const lockSimple = IconData(0xe308, fontFamily: 'PhosphorRegular');
  static const magnifyingGlass = IconData(
    0xe30c,
    fontFamily: 'PhosphorRegular',
  );
  static const mapPin = IconData(0xe316, fontFamily: 'PhosphorRegular');
  static const password = IconData(0xe752, fontFamily: 'PhosphorRegular');
  static const pencilSimple = IconData(0xe3b4, fontFamily: 'PhosphorRegular');
  static const plusBold = IconData(0xe3d4, fontFamily: 'PhosphorBold');
  static const plus = IconData(0xe3d4, fontFamily: 'PhosphorRegular');
  static const question = IconData(0xe3e8, fontFamily: 'PhosphorRegular');
  static const shareNetwork = IconData(0xe408, fontFamily: 'PhosphorRegular');
  static const squaresFour = IconData(0xe464, fontFamily: 'PhosphorRegular');
  static const sunFill = IconData(0xe472, fontFamily: 'PhosphorFill');
  static const sun = IconData(0xe472, fontFamily: 'PhosphorRegular');
  static const sunDimFill = IconData(0xe474, fontFamily: 'PhosphorFill');
  static const sunDim = IconData(0xe474, fontFamily: 'PhosphorRegular');
  static const tray = IconData(0xe4aa, fontFamily: 'PhosphorRegular');
  static const userSwitch = IconData(0xe756, fontFamily: 'PhosphorRegular');
  static const usersFill = IconData(0xe4d6, fontFamily: 'PhosphorFill');
  static const users = IconData(0xe4d6, fontFamily: 'PhosphorRegular');
  static const warning = IconData(0xe4e0, fontFamily: 'PhosphorRegular');
  static const warningCircle = IconData(0xe4e2, fontFamily: 'PhosphorRegular');
  static const wifiSlash = IconData(0xe4f2, fontFamily: 'PhosphorRegular');
  static const windowsLogo = IconData(0xe692, fontFamily: 'PhosphorRegular');
}

/// Size for an icon that sits inline with text: grows with the user's text scale (up to 200%).
double inlineIconSize(BuildContext context, double base) =>
    MediaQuery.textScalerOf(context).scale(base);
