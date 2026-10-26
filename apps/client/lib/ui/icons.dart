import 'package:flutter/widgets.dart';

/// Phosphor icons (MIT, assets/fonts/Phosphor/LICENSE), regular weight by default (spec §5.8).
/// The phosphor_flutter package no longer builds on current Flutter, so the fonts are vendored and
/// only the icons the app uses are declared. To add one, take its code point from
/// https://phosphoricons.com (or the Phosphor font's cmap) and add a constant here.
abstract final class AppIcons {
  static const archive = IconData(0xe00c, fontFamily: 'PhosphorRegular');
  static const arrowClockwise = IconData(0xe036, fontFamily: 'PhosphorRegular');
  static const arrowCounterClockwise = IconData(
    0xe038,
    fontFamily: 'PhosphorRegular',
  );
  static const arrowsClockwise = IconData(
    0xe094,
    fontFamily: 'PhosphorRegular',
  );
  static const arrowsLeftRight = IconData(
    0xe0a0,
    fontFamily: 'PhosphorRegular',
  );
  static const arrowSquareIn = IconData(0xe5dc, fontFamily: 'PhosphorRegular');
  static const arrowSquareOut = IconData(0xe5de, fontFamily: 'PhosphorRegular');
  static const bank = IconData(0xe0b4, fontFamily: 'PhosphorRegular');
  static const bell = IconData(0xe0ce, fontFamily: 'PhosphorRegular');
  static const briefcaseFill = IconData(0xe0ee, fontFamily: 'PhosphorFill');
  static const briefcase = IconData(0xe0ee, fontFamily: 'PhosphorRegular');
  static const calendarBlankFill = IconData(0xe10a, fontFamily: 'PhosphorFill');
  static const calendarBlank = IconData(0xe10a, fontFamily: 'PhosphorRegular');
  static const calendarCheck = IconData(0xe712, fontFamily: 'PhosphorRegular');
  static const camera = IconData(0xe10e, fontFamily: 'PhosphorRegular');
  static const caretDown = IconData(0xe136, fontFamily: 'PhosphorRegular');
  static const caretLeft = IconData(0xe138, fontFamily: 'PhosphorRegular');
  static const caretRight = IconData(0xe13a, fontFamily: 'PhosphorRegular');
  static const caretUp = IconData(0xe13c, fontFamily: 'PhosphorRegular');
  static const chatCircleTextFill = IconData(
    0xe16e,
    fontFamily: 'PhosphorFill',
  );
  static const chartBar = IconData(0xe150, fontFamily: 'PhosphorRegular');
  static const chatCircleText = IconData(0xe16e, fontFamily: 'PhosphorRegular');
  static const chatTeardropText = IconData(
    0xe178,
    fontFamily: 'PhosphorRegular',
  );
  static const checks = IconData(0xe53a, fontFamily: 'PhosphorRegular');
  static const checkCircleFill = IconData(0xe184, fontFamily: 'PhosphorFill');
  static const checkSquare = IconData(0xe186, fontFamily: 'PhosphorRegular');
  static const circle = IconData(0xe18a, fontFamily: 'PhosphorRegular');
  static const circleNotch = IconData(0xeb44, fontFamily: 'PhosphorRegular');
  static const clock = IconData(0xe19a, fontFamily: 'PhosphorRegular');
  static const clockCounterClockwise = IconData(
    0xe1a0,
    fontFamily: 'PhosphorRegular',
  );
  static const cloudArrowUp = IconData(0xe1ae, fontFamily: 'PhosphorRegular');
  static const cloudCheck = IconData(0xe1b0, fontFamily: 'PhosphorRegular');
  static const cloudWarning = IconData(0xea98, fontFamily: 'PhosphorRegular');
  static const coffee = IconData(0xe1c2, fontFamily: 'PhosphorRegular');
  static const copy = IconData(0xe1ca, fontFamily: 'PhosphorRegular');
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
  static const downloadSimple = IconData(0xe20c, fontFamily: 'PhosphorRegular');
  static const downloadSimpleFill = IconData(
    0xe20c,
    fontFamily: 'PhosphorFill',
  );
  static const envelope = IconData(0xe214, fontFamily: 'PhosphorRegular');
  static const fileDoc = IconData(0xeb1e, fontFamily: 'PhosphorRegular');
  static const fileImage = IconData(0xea24, fontFamily: 'PhosphorRegular');
  static const filePdf = IconData(0xe702, fontFamily: 'PhosphorRegular');
  static const filePlus = IconData(0xe236, fontFamily: 'PhosphorRegular');
  static const fileText = IconData(0xe23a, fontFamily: 'PhosphorRegular');
  static const filesFill = IconData(0xe710, fontFamily: 'PhosphorFill');
  static const files = IconData(0xe710, fontFamily: 'PhosphorRegular');
  static const fingerprint = IconData(0xe23e, fontFamily: 'PhosphorRegular');
  static const flag = IconData(0xe244, fontFamily: 'PhosphorRegular');
  static const folderSimple = IconData(0xe25a, fontFamily: 'PhosphorRegular');
  static const funnel = IconData(0xe266, fontFamily: 'PhosphorRegular');
  static const gavel = IconData(0xea32, fontFamily: 'PhosphorRegular');
  static const gearFill = IconData(0xe270, fontFamily: 'PhosphorFill');
  static const gear = IconData(0xe270, fontFamily: 'PhosphorRegular');
  static const handshake = IconData(0xe582, fontFamily: 'PhosphorRegular');
  static const image = IconData(0xe2ca, fontFamily: 'PhosphorRegular');
  static const info = IconData(0xe2ce, fontFamily: 'PhosphorRegular');
  static const lockSimple = IconData(0xe308, fontFamily: 'PhosphorRegular');
  static const magnifyingGlass = IconData(
    0xe30c,
    fontFamily: 'PhosphorRegular',
  );
  static const magnifyingGlassMinus = IconData(
    0xe30e,
    fontFamily: 'PhosphorRegular',
  );
  static const magnifyingGlassPlus = IconData(
    0xe310,
    fontFamily: 'PhosphorRegular',
  );
  static const mapPin = IconData(0xe316, fontFamily: 'PhosphorRegular');
  static const microphone = IconData(0xe326, fontFamily: 'PhosphorRegular');
  static const password = IconData(0xe752, fontFamily: 'PhosphorRegular');
  static const pencilSimple = IconData(0xe3b4, fontFamily: 'PhosphorRegular');
  static const phone = IconData(0xe3b8, fontFamily: 'PhosphorRegular');
  static const plusBold = IconData(0xe3d4, fontFamily: 'PhosphorBold');
  static const plus = IconData(0xe3d4, fontFamily: 'PhosphorRegular');
  static const question = IconData(0xe3e8, fontFamily: 'PhosphorRegular');
  static const quotes = IconData(0xe660, fontFamily: 'PhosphorRegular');
  static const sealCheck = IconData(0xe606, fontFamily: 'PhosphorRegular');
  static const sealQuestion = IconData(0xe608, fontFamily: 'PhosphorRegular');
  static const sealWarning = IconData(0xe60c, fontFamily: 'PhosphorRegular');
  static const shareNetwork = IconData(0xe408, fontFamily: 'PhosphorRegular');
  static const shieldWarning = IconData(0xe412, fontFamily: 'PhosphorRegular');
  static const sparkle = IconData(0xe6a2, fontFamily: 'PhosphorRegular');
  static const squaresFour = IconData(0xe464, fontFamily: 'PhosphorRegular');
  static const stop = IconData(0xe46c, fontFamily: 'PhosphorRegular');
  static const sunFill = IconData(0xe472, fontFamily: 'PhosphorFill');
  static const sun = IconData(0xe472, fontFamily: 'PhosphorRegular');
  static const sunDimFill = IconData(0xe474, fontFamily: 'PhosphorFill');
  static const sunDim = IconData(0xe474, fontFamily: 'PhosphorRegular');
  static const translate = IconData(0xe4a2, fontFamily: 'PhosphorRegular');
  static const trash = IconData(0xe4a6, fontFamily: 'PhosphorRegular');
  static const tray = IconData(0xe4aa, fontFamily: 'PhosphorRegular');
  static const userPlus = IconData(0xe4d0, fontFamily: 'PhosphorRegular');
  static const userSwitch = IconData(0xe756, fontFamily: 'PhosphorRegular');
  static const usersFill = IconData(0xe4d6, fontFamily: 'PhosphorFill');
  static const users = IconData(0xe4d6, fontFamily: 'PhosphorRegular');
  static const usersThree = IconData(0xe68e, fontFamily: 'PhosphorRegular');
  static const warning = IconData(0xe4e0, fontFamily: 'PhosphorRegular');
  static const warningCircle = IconData(0xe4e2, fontFamily: 'PhosphorRegular');
  static const waveform = IconData(0xe802, fontFamily: 'PhosphorRegular');
  static const whatsappLogo = IconData(0xe5d0, fontFamily: 'PhosphorRegular');
  static const wifiSlash = IconData(0xe4f2, fontFamily: 'PhosphorRegular');
  static const windowsLogo = IconData(0xe692, fontFamily: 'PhosphorRegular');
  static const x = IconData(0xe4f6, fontFamily: 'PhosphorRegular');
  static const xCircle = IconData(0xe4f8, fontFamily: 'PhosphorRegular');
}

/// Size for an icon that sits inline with text: grows with the user's text scale (up to 200%).
double inlineIconSize(BuildContext context, double base) =>
    MediaQuery.textScalerOf(context).scale(base);
