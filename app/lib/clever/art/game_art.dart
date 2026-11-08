import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'art_attention.dart';
import 'art_iq.dart';
import 'art_logic.dart';
import 'art_memory_cards.dart';
import 'art_verbal_social.dart';

/// Paints one game's illustration inside the medallion's enamel disc.
///
/// [canvas] is already clipped to the disc; [size] is the disc's square box (diameter × diameter);
/// [tint] is the game's enamel colour (`GameInfo.tint`). Draw in that box: centre = size / 2.
/// Keep it a bold, readable miniature of the real game: it must still read at 44 px.
typedef GameArtPainter = void Function(Canvas canvas, Size size, Color tint);

/// Every game's illustration, by game id. Games without an entry fall back to their text glyph.
final Map<String, GameArtPainter> kGameArt = {
  ...logicArt,
  ...attentionArt,
  ...memoryCardsArt,
  ...iqArt,
  ...verbalSocialArt,
};

/// The enamel disc of a medallion with the game's illustration on it.
class GameArtDisc extends StatelessWidget {
  final String id;
  final Color tint;
  const GameArtDisc({super.key, required this.id, required this.tint});

  static bool has(String id) => kGameArt.containsKey(id);

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _DiscPainter(id, tint), child: const SizedBox.expand());
}

class _DiscPainter extends CustomPainter {
  final String id;
  final Color tint;
  _DiscPainter(this.id, this.tint);

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2;
    final c = Offset(size.width / 2, size.height / 2);
    final disc = Rect.fromCircle(center: c, radius: r);
    canvas.save();
    canvas.clipPath(Path()..addOval(disc));
    // Enamel ground: the game's tint, lit from the top left.
    canvas.drawRect(
      disc,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.45),
          radius: 1.0,
          colors: [Color.lerp(tint, Colors.white, 0.18)!, tint, Color.lerp(tint, Colors.black, 0.62)!],
          stops: const [0, 0.48, 1],
        ).createShader(disc),
    );
    kGameArt[id]?.call(canvas, Size.square(r * 2), tint);
    // Glaze: a soft top highlight and an inner rim shadow, shared by every medallion.
    canvas.drawOval(
      Rect.fromLTWH(c.dx - r * 0.78, c.dy - r * 0.98, r * 1.56, r * 0.9),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white.withValues(alpha: 0.22), Colors.white.withValues(alpha: 0)],
        ).createShader(Rect.fromLTWH(c.dx - r, c.dy - r, r * 2, r)),
    );
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.38)],
          stops: const [0.78, 1],
        ).createShader(disc),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DiscPainter old) => old.id != id || old.tint != tint;
}

/// Shared drawing helpers so all medallions look like one set: jewel-like solids, gold, ivory,
/// soft drop shadows. Coordinates are in the painter's box; `u` = size.width / 100 is a handy unit.
class ArtKit {
  ArtKit._();

  static const gold = Color(0xFFE9C46A);
  static const goldDeep = Color(0xFF9C7322);
  static const goldLight = Color(0xFFFBE7B0);
  static const ivory = Color(0xFFFFF6E0);
  static const ink = Color(0xFF1B1408);
  static const ruby = Color(0xFFC0263D);
  static const emerald = Color(0xFF1F9E66);
  static const sapphire = Color(0xFF2F62C8);
  static const amethyst = Color(0xFF8E4CC9);
  static const topaz = Color(0xFFF0A93B);
  static const pearl = Color(0xFFEDE7DA);

  /// Linear gold leaf for strokes and fills.
  static Shader goldShader(Rect r) => const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFFBE7B0), Color(0xFFE3B95A), Color(0xFF9C7322), Color(0xFFF1D48B)],
        stops: [0, 0.4, 0.75, 1],
      ).createShader(r);

  /// A soft shadow under a shape (draw it before the shape).
  static void shadow(Canvas canvas, Path path,
      {double blur = 3, Offset offset = const Offset(0, 2), double alpha = 0.45}) {
    canvas.drawPath(
      path.shift(offset),
      Paint()
        ..color = Colors.black.withValues(alpha: alpha)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur),
    );
  }

  /// A rounded tile with a bevel: lit face, darker edge, glossy top. `color` is the base.
  static void tile(Canvas canvas, Rect rect, Color color, {double radius = 0.18, bool shadowed = true}) {
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(rect.shortestSide * radius));
    final path = Path()..addRRect(rr);
    if (shadowed) shadow(canvas, path, blur: rect.shortestSide * 0.12, offset: Offset(0, rect.shortestSide * 0.08));
    canvas.drawRRect(
      rr,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.lerp(color, Colors.white, 0.35)!, color, Color.lerp(color, Colors.black, 0.45)!],
          stops: const [0, 0.5, 1],
        ).createShader(rect),
    );
    final inset = rect.shortestSide * 0.12;
    final top = RRect.fromRectAndRadius(
      Rect.fromLTWH(rect.left + inset, rect.top + inset * 0.6, rect.width - inset * 2, rect.height * 0.34),
      Radius.circular(rect.shortestSide * radius * 0.7),
    );
    canvas.drawRRect(top, Paint()..color = Colors.white.withValues(alpha: 0.22));
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.6, rect.shortestSide * 0.05)
        ..color = Color.lerp(color, Colors.black, 0.55)!.withValues(alpha: 0.8),
    );
  }

  /// A glossy sphere (marble, stone, bead) with a specular dot.
  static void ball(Canvas canvas, Offset c, double r, Color color, {bool shadowed = true}) {
    if (shadowed) {
      shadow(canvas, Path()..addOval(Rect.fromCircle(center: c, radius: r)),
          blur: r * 0.35, offset: Offset(0, r * 0.25));
    }
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.45),
          radius: 0.95,
          colors: [Color.lerp(color, Colors.white, 0.55)!, color, Color.lerp(color, Colors.black, 0.55)!],
          stops: const [0, 0.45, 1],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
    canvas.drawCircle(c + Offset(-r * 0.35, -r * 0.4), r * 0.22, Paint()..color = Colors.white.withValues(alpha: 0.75));
  }

  /// A faceted gem (top view): coloured polygon with lighter upper facets.
  static void gem(Canvas canvas, Offset c, double r, Color color, {int sides = 6}) {
    final pts = [for (var i = 0; i < sides; i++) c + Offset.fromDirection(-math.pi / 2 + i * 2 * math.pi / sides, r)];
    final outline = Path()..addPolygon(pts, true);
    shadow(canvas, outline, blur: r * 0.3, offset: Offset(0, r * 0.2));
    canvas.drawPath(outline, Paint()..color = Color.lerp(color, Colors.black, 0.25)!);
    for (var i = 0; i < sides; i++) {
      final a = pts[i], b = pts[(i + 1) % sides];
      final t = (math.sin(-math.pi / 2 + (i + 0.5) * 2 * math.pi / sides) + 1) / 2; // 0 top … 1 bottom
      canvas.drawPath(
        Path()..addPolygon([c, a, b], true),
        Paint()..color = Color.lerp(Color.lerp(color, Colors.white, 0.45)!, Color.lerp(color, Colors.black, 0.35)!, t)!,
      );
    }
    final table = [for (final p in pts) Offset.lerp(c, p, 0.48)!];
    canvas.drawPath(Path()..addPolygon(table, true), Paint()..color = Color.lerp(color, Colors.white, 0.3)!);
    canvas.drawCircle(c + Offset(-r * 0.2, -r * 0.25), r * 0.12, Paint()..color = Colors.white.withValues(alpha: 0.8));
  }

  /// Text centred at [c], e.g. a digit on a tile. family: 'Cormorant' (display) or 'Jost' (ui).
  static void text(Canvas canvas, String s, Offset c, double fontSize,
      {Color color = ivory, String family = 'Cormorant', FontWeight weight = FontWeight.w700}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(fontFamily: family, fontSize: fontSize, fontWeight: weight, color: color, height: 1.0),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
  }

  /// A gold-leaf stroke along [path].
  static void goldStroke(Canvas canvas, Path path, double width) {
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..shader = goldShader(path.getBounds().inflate(width)),
    );
  }
}
