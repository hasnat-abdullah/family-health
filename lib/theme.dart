import 'package:flutter/material.dart';

import 'data/models.dart';

/// Avatar colours for family members (picked in order, never generated).
const memberColors = [
  Color(0xff2a78d6), // blue
  Color(0xffeb6834), // orange
  Color(0xff1baf7a), // aqua
  Color(0xffeda100), // yellow
  Color(0xffe87ba4), // magenta
  Color(0xff008300), // green
  Color(0xff6250d6), // violet
  Color(0xffe34948), // red
];

/// Status colours are reserved for result flags and always paired with an icon + label.
class StatusColors {
  static const good = Color(0xff0ca30c);
  static const critical = Color(0xffd03b3b);
  static const goodText = Color(0xff006300);

  /// An AI reading that still needs checking against the original.
  static const warning = Color(0xffb26a00);

  static Color forFlag(ResultFlag f, Brightness b) => switch (f) {
    ResultFlag.normal => b == Brightness.light ? goodText : good,
    ResultFlag.low || ResultFlag.high => critical,
    ResultFlag.unknown => b == Brightness.light ? const Color(0xff52514e) : const Color(0xffc3c2b7),
  };
}

/// Chart colours tuned for each surface.
class ChartColors {
  const ChartColors._(this.line, this.band, this.grid, this.axisText);
  final Color line;
  final Color band;
  final Color grid;
  final Color axisText;

  static ChartColors of(BuildContext context) => Theme.of(context).brightness == Brightness.light
      ? const ChartColors._(Color(0xff2a78d6), Color(0x1f0ca30c), Color(0xffe6e5e0), Color(0xff52514e))
      : const ChartColors._(Color(0xff3987e5), Color(0x2e0ca30c), Color(0xff2e2e2b), Color(0xffc3c2b7));
}

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xff2a78d6), brightness: brightness);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
    // 48dp touch targets on every platform (iPad, touch Macs, phones), not desktop's compact 40.
    materialTapTargetSize: MaterialTapTargetSize.padded,
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
  );
}
