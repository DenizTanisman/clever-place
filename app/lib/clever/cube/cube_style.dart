import 'package:flutter/material.dart';

import '../lux.dart';

/// The cube pages use Material widgets (segments, switches, chips, sheets); this gives them the
/// velvet-and-gold look of the rest of the game.
class CubeTheme extends StatelessWidget {
  final Widget child;
  const CubeTheme({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final scheme = base.colorScheme.copyWith(
      brightness: Brightness.dark,
      primary: Lux.gold,
      onPrimary: Lux.bg0,
      secondaryContainer: Lux.velvetLight,
      onSecondaryContainer: Lux.goldLight,
      surface: Lux.panel,
      onSurface: Lux.ink,
      onSurfaceVariant: Lux.muted,
      surfaceContainerLow: Lux.panel,
      surfaceContainerHighest: Lux.card,
      outline: Lux.line,
      outlineVariant: Lux.lineFaint,
    );
    return Theme(
      data: base.copyWith(
        colorScheme: scheme,
        textTheme: base.textTheme.apply(fontFamily: 'Jost', bodyColor: Lux.ink, displayColor: Lux.ink),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Lux.panel,
          modalBackgroundColor: Lux.panel,
          dragHandleColor: Lux.gold,
          showDragHandle: true,
        ),
        popupMenuTheme: PopupMenuThemeData(color: Lux.card, textStyle: Lux.ui(15)),
        listTileTheme: const ListTileThemeData(textColor: Lux.ink, iconColor: Lux.gold),
        chipTheme: ChipThemeData(
          backgroundColor: Lux.cardDeep,
          selectedColor: Lux.velvetLight,
          side: const BorderSide(color: Lux.line),
          labelStyle: Lux.ui(14),
          iconTheme: const IconThemeData(color: Lux.gold, size: 18),
        ),
      ),
      child: child,
    );
  }
}

/// Back arrow, the page title in foil, and an optional action on the right.
class CubeHeader extends StatelessWidget {
  final String title;
  final Widget? action;
  const CubeHeader(this.title, {super.key, this.action});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
      child: Row(
        children: [
          IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back, color: Lux.ink)),
          Expanded(child: FoilText(title, style: Lux.display(24, italic: true))),
          if (action != null) action!,
        ],
      ),
    );
  }
}

/// Move sequences (scrambles, algorithms): monospace so the turns line up.
TextStyle cubeMoves(double size, {Color color = Lux.goldLight}) =>
    TextStyle(fontFamily: 'monospace', fontSize: size, fontWeight: FontWeight.w600, color: color, height: 1.4);
