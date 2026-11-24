import 'package:flutter/material.dart';

import 'lux.dart';
import 'i18n/lang.dart';

/// Pieces of the "Zümrüt Rezerv" look shared by the game page and the level result screen.

/// "m:ss" (or "h:mm:ss") for a duration in milliseconds.
String clockTime(int ms) {
  final s = (ms / 1000).round();
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

/// How much faster a new record is: "0,4 sn", "14 sn", "1:05".
String recordGain(int ms) {
  if (ms < 1000) {
    final v = (ms / 1000).toStringAsFixed(1);
    return Lang.en ? '$v s' : '${v.replaceAll('.', ',')} sn';
  }
  if (ms < 60000) return Lang.en ? '${(ms / 1000).round()} s' : '${(ms / 1000).round()} sn';
  return clockTime(ms);
}

/// Gold leaf for wide buttons and the "next level" tile.
const reserveFoil = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFFB98A35), Color(0xFFF1D48B), Color(0xFFFBE7B0), Color(0xFFE3C278), Color(0xFF9C7228)],
  stops: [0, 0.4, 0.55, 0.72, 1],
);

/// Dark ink on gold leaf.
const reserveInk = Color(0xFF2A1D05);

/// Round 44 px button with a faint gold rim (back, close).
class RimCircleButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  const RimCircleButton(this.icon, {super.key, required this.tooltip, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, color: Lux.gold, size: 20),
      style: IconButton.styleFrom(
        fixedSize: const Size(44, 44),
        shape: const CircleBorder(),
        side: BorderSide(color: Lux.gold.withValues(alpha: 0.24)),
      ),
    );
  }
}

/// Full-width gold-leaf button, 56 px high: the one main action of a screen.
class FoilWideButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool iconAfter;
  final VoidCallback onPressed;
  const FoilWideButton(this.label, {super.key, this.icon, this.iconAfter = false, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final iconW = icon == null ? null : Icon(icon, size: 20, color: reserveInk);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(40),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.42), blurRadius: 26, offset: const Offset(0, 12))],
      ),
      child: Material(
        type: MaterialType.transparency,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Ink(
            height: 56,
            decoration: const BoxDecoration(gradient: reserveFoil),
            child: Stack(
              children: [
                // Light along the top edge, a darker lip at the bottom: reads as a pressed metal plate.
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: Container(height: 1, color: const Color(0xB3FFF8E6)),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(height: 2, color: const Color(0x597D5A1B)),
                ),
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (iconW != null && !iconAfter) ...[iconW, const SizedBox(width: 10)],
                        Flexible(
                          child: Text(label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Lux.ui(17, color: reserveInk, weight: FontWeight.w600, spacing: 0.3)),
                        ),
                        if (iconW != null && iconAfter) ...[const SizedBox(width: 10), iconW],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Outlined gold pill that fills its slot, 48 px high (secondary actions under [FoilWideButton]).
class OutlinePill extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  const OutlinePill(this.label, {super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      shape: StadiumBorder(side: BorderSide(color: Lux.gold.withValues(alpha: 0.42))),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          height: 48,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(label, maxLines: 1, style: Lux.ui(15, color: Lux.goldLight, weight: FontWeight.w500)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small tracked capitals (eyebrows above titles, labels under numbers).
TextStyle eyebrowStyle({Color color = Lux.gold, double size = 11.5}) =>
    Lux.ui(size, color: color, weight: FontWeight.w500, spacing: 3.2);
