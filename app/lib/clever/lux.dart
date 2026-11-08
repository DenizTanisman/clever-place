import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'art/game_art.dart';

/// Clever Place design kit — "Zümrüt Kadife" (emerald velvet + antique gold leaf).
///
/// Every game screen draws from these tokens and widgets. Names are stable: game views written
/// against the earlier palette pick up the new look automatically.
class Lux {
  Lux._();

  // Velvet
  static const bg0 = Color(0xFF03190F);
  static const bg1 = Color(0xFF0E4636);
  static const panel = Color(0xFF062A21);
  static const card = Color(0xFF0B3A2E);
  static const cardDeep = Color(0xFF05241C);
  static const velvetLight = Color(0xFF1E6B52);

  // Ink
  static const ink = Color(0xFFF1EAD6);
  static const muted = Color(0xFF9FB8A8);

  // Antique gold
  static const gold = Color(0xFFD4A94E);
  static const goldLight = Color(0xFFF0D69A);
  static const goldDeep = Color(0xFF7D5A1B);

  // Accents (kept names: bordeaux = ruby for errors / opponent pieces)
  static const bordeaux = Color(0xFFA3203F);
  static const bordeauxLight = Color(0xFFE77A93);
  static const line = Color(0x40D4A94E);
  static const lineFaint = Color(0x22D4A94E);
  static const good = Color(0xFF7FD6A4);
  static const bad = Color(0xFFE77A93);

  /// Gold leaf: several light/dark bands so it reads as metal, not as a flat yellow.
  static const foil = LinearGradient(
    begin: Alignment(-1, -0.6),
    end: Alignment(1, 0.6),
    colors: [
      Color(0xFF7D5A1B),
      Color(0xFFF1D48B),
      Color(0xFFB98A35),
      Color(0xFFFBE7B0),
      Color(0xFF9C7228),
      Color(0xFFE3C278)
    ],
    stops: [0, 0.25, 0.45, 0.6, 0.8, 1],
  );
  static const goldGradient = foil;

  static const velvetCard = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF0E4636), Color(0xFF062A21)],
  );

  /// Display face: Cormorant Garamond (italic for brand-level titles).
  static TextStyle display(double size, {Color color = gold, double spacing = 0.4, bool italic = false}) => TextStyle(
        fontFamily: 'Cormorant',
        fontSize: size * 1.12,
        fontWeight: FontWeight.w700,
        fontStyle: italic ? FontStyle.italic : FontStyle.normal,
        color: color,
        letterSpacing: spacing,
        height: 1.05,
        fontFeatures: const [FontFeature.liningFigures()],
      );

  /// UI / numbers face: Jost.
  static TextStyle ui(double size, {Color color = ink, FontWeight weight = FontWeight.w500, double spacing = 0.2}) =>
      TextStyle(fontFamily: 'Jost', fontSize: size * 0.94, fontWeight: weight, color: color, letterSpacing: spacing);

  /// Serif numerals for scores, digits on boards, big stats.
  static TextStyle numeral(double size, {Color color = goldLight}) => TextStyle(
        fontFamily: 'Cormorant',
        fontSize: size * 1.15,
        fontWeight: FontWeight.w700,
        color: color,
        height: 1,
        fontFeatures: const [FontFeature.liningFigures()],
      );

  /// Turkish-aware uppercase (dotted İ).
  static String upper(String s) => s.replaceAll('i', 'İ').replaceAll('ı', 'I').toUpperCase();
}

/// Emerald velvet background: lit from the top-left, vignetted, with a faint woven texture.
class LuxBackground extends StatelessWidget {
  final Widget child;
  const LuxBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: const _VelvetPainter(), child: child);
  }
}

class _VelvetPainter extends CustomPainter {
  const _VelvetPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = Lux.bg0);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.6, -1.0),
          radius: 1.25,
          colors: [Color(0xFF17604A), Color(0xFF0A3529), Color(0x00031A14)],
          stops: [0, 0.45, 1],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(1.1, 1.1),
          radius: 0.9,
          colors: [Color(0x99000000), Color(0x00000000)],
        ).createShader(rect),
    );
    // Woven velvet: very faint diagonal threads.
    final thread = Paint()
      ..color = const Color(0x06FFFFFF)
      ..strokeWidth = 1;
    for (double x = -size.height; x < size.width; x += 5) {
      canvas.drawLine(Offset(x, 0), Offset(x + size.height, size.height), thread);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Gold-leaf text.
class FoilText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final TextAlign? align;
  const FoilText(this.text, {super.key, required this.style, this.align});

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (r) => Lux.foil.createShader(r),
      child: Text(text, style: style.copyWith(color: Colors.white), textAlign: align),
    );
  }
}

/// Velvet card with a gold rim and an inner hairline (jewel-case double border).
class LuxCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final double radius;
  final bool highlight;
  const LuxCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.radius = 18,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: r,
        onTap: onTap,
        splashColor: Lux.gold.withValues(alpha: 0.14),
        highlightColor: Lux.gold.withValues(alpha: 0.06),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: r,
            gradient: highlight
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF155A45), Color(0xFF07301F)],
                  )
                : Lux.velvetCard,
            border:
                Border.all(color: highlight ? Lux.gold.withValues(alpha: 0.85) : Lux.line, width: highlight ? 1.2 : 1),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 22, offset: const Offset(0, 10)),
            ],
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    margin: const EdgeInsets.all(4.5),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(math.max(radius - 4.5, 2)),
                      border: Border.all(color: Lux.lineFaint),
                    ),
                  ),
                ),
              ),
              Padding(padding: padding, child: child),
            ],
          ),
        ),
      ),
    );
  }
}

/// Hero tag shared by a game's hub-card medallion and the medallion on its game page.
String monogramHeroTag(String gameId) => 'mono-$gameId';

/// Enamel medallion with a gold-leaf bezel — the game icon.
class Monogram extends StatelessWidget {
  final String glyph;
  final double size;
  final Color? tint;

  /// Game id: when that game has an illustration (`kGameArt`), it replaces the text glyph.
  final String? art;
  const Monogram(this.glyph, {super.key, this.size = 56, this.tint, this.art});

  @override
  Widget build(BuildContext context) {
    final c = tint ?? const Color(0xFFC9A24A);
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.065),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const SweepGradient(
          startAngle: 0,
          endAngle: math.pi * 2,
          colors: [
            Color(0xFF6F4F17),
            Color(0xFFF1D48B),
            Color(0xFFA77B2C),
            Color(0xFFFBE7B0),
            Color(0xFF7D5A1B),
            Color(0xFFE3C278),
            Color(0xFF6F4F17)
          ],
        ),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.55), blurRadius: size * 0.25, offset: Offset(0, size * 0.1)),
        ],
      ),
      child: art != null && GameArtDisc.has(art!)
          ? ClipOval(child: GameArtDisc(id: art!, tint: c))
          : Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  center: const Alignment(-0.3, -0.4),
                  radius: 0.95,
                  colors: [Color.lerp(c, Colors.white, 0.25)!, c, Color.lerp(c, Colors.black, 0.6)!],
                  stops: const [0, 0.5, 1],
                ),
              ),
              child: Text(
                glyph,
                style: TextStyle(
                  fontFamily: 'Cormorant',
                  fontSize: size * 0.46,
                  fontWeight: FontWeight.w700,
                  height: 1.0,
                  color: const Color(0xFFFFF8E6),
                  fontFeatures: const [FontFeature.liningFigures()],
                ),
                textHeightBehavior:
                    const TextHeightBehavior(applyHeightToFirstAscent: false, applyHeightToLastDescent: false),
              ),
            ),
    );
  }
}

/// Primary gold-leaf pill (with a slow sheen) or an outlined gold pill.
class GoldButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool outlined;
  const GoldButton(this.label, {super.key, this.icon, this.onPressed, this.outlined = false});

  @override
  State<GoldButton> createState() => _GoldButtonState();
}

class _GoldButtonState extends State<GoldButton> with SingleTickerProviderStateMixin {
  // Created only when a filled button first builds its sheen; outlined buttons never need it.
  AnimationController? _sheenCtl;
  AnimationController get _sheen =>
      _sheenCtl ??= AnimationController(vsync: this, duration: const Duration(milliseconds: 3600))..repeat();

  @override
  void dispose() {
    _sheenCtl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final fg = widget.outlined ? Lux.goldLight : const Color(0xFF2A1D05);
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.icon != null) ...[Icon(widget.icon, size: 18, color: fg), const SizedBox(width: 6)],
        Text(widget.label, style: Lux.ui(15, color: fg, weight: FontWeight.w600, spacing: 0.8)),
      ],
    );
    // The drop shadow sits outside the Material: ink is clipped to the Material's rectangle, so a
    // shadow drawn by the Ink showed up as translucent dark corners around the pill.
    final button = Material(
      type: MaterialType.transparency,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(40),
        onTap: widget.onPressed,
        child: widget.outlined
            ? Ink(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(40),
                  color: const Color(0x22000000),
                  border: Border.all(color: Lux.gold.withValues(alpha: 0.7)),
                ),
                child: content,
              )
            : AnimatedBuilder(
                animation: _sheen,
                builder: (context, child) {
                  final t = _sheen.value * 2 - 0.5;
                  return Ink(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(40),
                      gradient: LinearGradient(
                        begin: Alignment(-1 + t, -0.5),
                        end: Alignment(1 + t, 0.5),
                        colors: Lux.foil.colors,
                        stops: Lux.foil.stops,
                        tileMode: TileMode.mirror,
                      ),
                    ),
                    child: child,
                  );
                },
                child: content,
              ),
      ),
    );
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: widget.outlined
          ? button
          : DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(40),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 14, offset: const Offset(0, 6)),
                ],
              ),
              child: button,
            ),
    );
  }
}

/// Round gold-rimmed tool button (undo / hint / notes).
class RimIconButton extends StatelessWidget {
  final IconData icon;
  final String? tooltip;
  final VoidCallback? onPressed;
  final String? badge;
  const RimIconButton(this.icon, {super.key, this.tooltip, this.onPressed, this.badge});

  @override
  Widget build(BuildContext context) {
    final b = IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, color: onPressed == null ? Lux.muted.withValues(alpha: 0.4) : Lux.goldLight),
      style: IconButton.styleFrom(
        backgroundColor: Lux.card,
        side: BorderSide(color: Lux.gold.withValues(alpha: onPressed == null ? 0.2 : 0.6)),
        padding: const EdgeInsets.all(13),
        shadowColor: Colors.black,
        elevation: 6,
      ),
    );
    if (badge == null) return b;
    return Badge(label: Text(badge!), backgroundColor: Lux.bordeaux, child: b);
  }
}

class StarRow extends StatelessWidget {
  final int stars;
  final double size;
  const StarRow(this.stars, {super.key, this.size = 14});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        final on = i < stars;
        final icon = Icon(Icons.star_rounded, size: size, color: on ? Colors.white : Lux.muted.withValues(alpha: 0.28));
        return on
            ? ShaderMask(blendMode: BlendMode.srcIn, shaderCallback: (r) => Lux.foil.createShader(r), child: icon)
            : icon;
      }),
    );
  }
}

/// Section ornament: ✦ LABEL ✦ between fading gold rules.
class LuxHeading extends StatelessWidget {
  final String text;
  const LuxHeading(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    Widget rule(bool left) => Expanded(
          child: Container(
            height: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: left ? [Colors.transparent, Lux.gold] : [Lux.gold, Colors.transparent]),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 22, 4, 12),
      child: Row(
        children: [
          rule(true),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text('✦  ${Lux.upper(text)}  ✦',
                style: Lux.ui(12, color: Lux.gold, weight: FontWeight.w600, spacing: 2.4)),
          ),
          rule(false),
        ],
      ),
    );
  }
}

/// Polished jewel sphere for game pieces.
class GemPainter extends CustomPainter {
  final Color color;
  final double glow;
  const GemPainter(this.color, {this.glow = 0.0});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = math.min(size.width, size.height) / 2;
    if (glow > 0) {
      canvas.drawCircle(
          c,
          r * 1.12,
          Paint()
            ..color = color.withValues(alpha: 0.4 * glow)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9));
    }
    canvas.drawCircle(
        c.translate(0, r * 0.08),
        r,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    final body = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.35, -0.4),
        radius: 1.0,
        colors: [Color.lerp(color, Colors.white, 0.5)!, color, Color.lerp(color, Colors.black, 0.6)!],
        stops: const [0, 0.5, 1],
      ).createShader(Rect.fromCircle(center: c, radius: r));
    canvas.drawCircle(c, r, body);
    canvas.drawCircle(
      c,
      r - 0.6,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Lux.goldLight.withValues(alpha: 0.35),
    );
    canvas.drawCircle(
      c.translate(-r * 0.32, -r * 0.38),
      r * 0.22,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
  }

  @override
  bool shouldRepaint(GemPainter old) => old.color != color || old.glow != glow;
}
