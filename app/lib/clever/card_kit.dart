import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'lux.dart';

/// Shared French-deck card art for the card games (Batak, 21, Blöf).
///
/// Suits are drawn as vector paths (never Unicode ♠♥♦♣ — Android renders those as emoji).
/// Suit ids: 0 = maça (♠), 1 = kupa (♥), 2 = karo (♦), 3 = sinek (♣).
/// Ranks: 2..10, 11 = J (Vale), 12 = Q (Kız), 13 = K (Papaz), 14 = A (As).
///
/// The face adapts to its size: from ~56 px wide it shows the classic pip layout, court panels and
/// an ornate ace; below that (opponent fans, score sheets) a big index and one centre pip, so a
/// card stays readable at any size. In an overlapping hand only the left strip shows — the corner
/// index is drawn large for exactly that case.
class CardKit {
  CardKit._();

  /// Card aspect ratio (width / height), the standard poker 63 × 88 mm.
  static const double aspect = 63 / 88;

  static const suitNames = ['Maça', 'Kupa', 'Karo', 'Sinek'];

  static bool isRed(int suit) => suit == 1 || suit == 2;

  static Color suitColor(int suit) => isRed(suit) ? const Color(0xFFB3213A) : const Color(0xFF16231D);

  static String rankLabel(int rank) => switch (rank) {
        11 => 'J',
        12 => 'Q',
        13 => 'K',
        14 => 'A',
        _ => '$rank',
      };

  /// Turkish name, e.g. "Kupa Papaz", "Maça 7".
  static String name(int suit, int rank) {
    final r = switch (rank) { 11 => 'Vale', 12 => 'Kız', 13 => 'Papaz', 14 => 'As', _ => '$rank' };
    return '${suitNames[suit]} $r';
  }

  /// Suit shape centred in a unit box (−0.5..0.5), scaled to [size] and translated to [c].
  static Path suitPath(int suit, Offset c, double size) {
    final p = Path();
    switch (suit) {
      case 1: // heart
        p.moveTo(0, 0.44);
        p.cubicTo(-0.2, 0.27, -0.5, 0.07, -0.5, -0.17);
        p.cubicTo(-0.5, -0.37, -0.36, -0.47, -0.235, -0.47);
        p.cubicTo(-0.115, -0.47, -0.03, -0.39, 0, -0.27);
        p.cubicTo(0.03, -0.39, 0.115, -0.47, 0.235, -0.47);
        p.cubicTo(0.36, -0.47, 0.5, -0.37, 0.5, -0.17);
        p.cubicTo(0.5, 0.07, 0.2, 0.27, 0, 0.44);
        p.close();
      case 2: // diamond
        p.moveTo(0, -0.5);
        p.quadraticBezierTo(0.15, -0.2, 0.38, 0);
        p.quadraticBezierTo(0.15, 0.2, 0, 0.5);
        p.quadraticBezierTo(-0.15, 0.2, -0.38, 0);
        p.quadraticBezierTo(-0.15, -0.2, 0, -0.5);
        p.close();
      case 0: // spade
        p.moveTo(0, -0.5);
        p.cubicTo(0.16, -0.3, 0.48, -0.13, 0.48, 0.1);
        p.cubicTo(0.48, 0.27, 0.36, 0.36, 0.24, 0.36);
        p.cubicTo(0.14, 0.36, 0.07, 0.31, 0.04, 0.24);
        p.quadraticBezierTo(0.06, 0.4, 0.17, 0.5);
        p.lineTo(-0.17, 0.5);
        p.quadraticBezierTo(-0.06, 0.4, -0.04, 0.24);
        p.cubicTo(-0.07, 0.31, -0.14, 0.36, -0.24, 0.36);
        p.cubicTo(-0.36, 0.36, -0.48, 0.27, -0.48, 0.1);
        p.cubicTo(-0.48, -0.13, -0.16, -0.3, 0, -0.5);
        p.close();
      default: // club
        p.addOval(Rect.fromCircle(center: const Offset(0, -0.255), radius: 0.215));
        p.addOval(Rect.fromCircle(center: const Offset(-0.255, 0.085), radius: 0.215));
        p.addOval(Rect.fromCircle(center: const Offset(0.255, 0.085), radius: 0.215));
        p.addRect(const Rect.fromLTRB(-0.1, -0.12, 0.1, 0.12));
        final stem = Path()
          ..moveTo(-0.045, 0.05)
          ..lineTo(0.045, 0.05)
          ..quadraticBezierTo(0.06, 0.38, 0.17, 0.5)
          ..lineTo(-0.17, 0.5)
          ..quadraticBezierTo(-0.06, 0.38, -0.045, 0.05)
          ..close();
        p.addPath(stem, Offset.zero);
        p.fillType = PathFillType.nonZero;
    }
    final m = Matrix4.identity()
      ..translateByDouble(c.dx, c.dy, 0, 1)
      ..scaleByDouble(size, size, 1, 1);
    return p.transform(m.storage);
  }

  /// Classic pip positions for 2..10 in a unit pip box (x, y in 0..1).
  static const Map<int, List<(double, double)>> _pips = {
    2: [(0.5, 0), (0.5, 1)],
    3: [(0.5, 0), (0.5, 0.5), (0.5, 1)],
    4: [(0, 0), (1, 0), (0, 1), (1, 1)],
    5: [(0, 0), (1, 0), (0.5, 0.5), (0, 1), (1, 1)],
    6: [(0, 0), (1, 0), (0, 0.5), (1, 0.5), (0, 1), (1, 1)],
    7: [(0, 0), (1, 0), (0.5, 0.25), (0, 0.5), (1, 0.5), (0, 1), (1, 1)],
    8: [(0, 0), (1, 0), (0.5, 0.25), (0, 0.5), (1, 0.5), (0.5, 0.75), (0, 1), (1, 1)],
    9: [(0, 0), (1, 0), (0, 1 / 3), (1, 1 / 3), (0.5, 0.5), (0, 2 / 3), (1, 2 / 3), (0, 1), (1, 1)],
    10: [(0, 0), (1, 0), (0.5, 1 / 6), (0, 1 / 3), (1, 1 / 3), (0, 2 / 3), (1, 2 / 3), (0.5, 5 / 6), (0, 1), (1, 1)],
  };
}

/// A single playing card. [faceUp] false draws the emerald-and-gold back. [highlight] adds a gold
/// glow (selected / playable); [dim] greys it (not playable). Size comes from the parent (keep the
/// [CardKit.aspect] ratio, e.g. with `AspectRatio`).
class PlayingCard extends StatelessWidget {
  final int suit;
  final int rank;
  final bool faceUp;
  final bool highlight;
  final bool dim;

  const PlayingCard({super.key, required this.suit, required this.rank, this.faceUp = true, this.highlight = false, this.dim = false});

  const PlayingCard.back({super.key})
      : suit = 0,
        rank = 0,
        faceUp = false,
        highlight = false,
        dim = false;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: CardKit.aspect,
      child: CustomPaint(painter: CardPainter(suit: suit, rank: rank, faceUp: faceUp, highlight: highlight, dim: dim)),
    );
  }
}

class CardPainter extends CustomPainter {
  final int suit, rank;
  final bool faceUp, highlight, dim;
  CardPainter({required this.suit, required this.rank, this.faceUp = true, this.highlight = false, this.dim = false});

  static const _ivoryTop = Color(0xFFFFFCF3);
  static const _ivoryBottom = Color(0xFFF2E8D2);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final r = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(w * 0.085));
    // Soft contact shadow (two layers: tight + ambient).
    canvas.drawRRect(r.shift(Offset(0, w * 0.035)),
        Paint()..color = Colors.black.withValues(alpha: 0.32)..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.05));
    canvas.drawRRect(r.shift(Offset(0, w * 0.012)),
        Paint()..color = Colors.black.withValues(alpha: 0.25)..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.012));
    if (highlight) {
      canvas.drawRRect(r.inflate(w * 0.035),
          Paint()..color = Lux.gold.withValues(alpha: 0.6)..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.07));
    }
    if (!faceUp) {
      _back(canvas, size, r);
    } else {
      _face(canvas, size, r);
    }
    canvas.drawRRect(
        r.deflate(0.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.0, w * (highlight ? 0.035 : 0.014))
          ..color = highlight ? Lux.goldLight : const Color(0xFF8E6A2A).withValues(alpha: faceUp ? 0.75 : 0.95));
    if (dim) canvas.drawRRect(r, Paint()..color = const Color(0xFF04140D).withValues(alpha: 0.42));
  }

  // -------------------------------------------------------------------------------------------
  // Back

  void _back(Canvas canvas, Size size, RRect r) {
    final w = size.width, h = size.height;
    canvas.drawRRect(
        r,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF13654B), Color(0xFF0A3F2E), Color(0xFF052419)],
            stops: [0, 0.55, 1],
          ).createShader(Offset.zero & size));
    final inner = r.deflate(w * 0.075);
    canvas.save();
    canvas.clipRRect(inner);
    // Guilloché lattice: two families of fine diagonal lines.
    final lattice = Paint()
      ..color = Lux.gold.withValues(alpha: 0.24)
      ..strokeWidth = math.max(0.6, w * 0.009);
    final step = w * 0.11;
    for (var x = -h; x < w + h; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x + h * 0.7, h), lattice);
      canvas.drawLine(Offset(x + h * 0.7, 0), Offset(x, h), lattice);
    }
    // Lattice knots.
    if (w >= 40) {
      final dot = Paint()..color = Lux.goldLight.withValues(alpha: 0.35);
      for (var y = step / 2; y < h; y += step * 0.7 * 1.0) {
        for (var x = step / 2; x < w; x += step) {
          canvas.drawCircle(Offset(x + (((y / (step * 0.7)).round()).isOdd ? step / 2 : 0), y), w * 0.008, dot);
        }
      }
    }
    // Vignette.
    canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = RadialGradient(colors: [Colors.transparent, Colors.black.withValues(alpha: 0.35)], stops: const [0.55, 1])
              .createShader(Offset.zero & size));
    canvas.restore();
    canvas.drawRRect(inner,
        Paint()..style = PaintingStyle.stroke..strokeWidth = math.max(1.0, w * 0.018)..color = Lux.gold.withValues(alpha: 0.85));
    canvas.drawRRect(inner.deflate(w * 0.035),
        Paint()..style = PaintingStyle.stroke..strokeWidth = math.max(0.5, w * 0.007)..color = Lux.gold.withValues(alpha: 0.45));
    // Centre medallion: gold bezel, enamel, four-suit rosette.
    final c = size.center(Offset.zero);
    final mr = w * 0.2;
    canvas.drawCircle(c, mr * 1.08, Paint()..color = Colors.black.withValues(alpha: 0.4)..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.03));
    canvas.drawCircle(c, mr, Paint()..shader = Lux.foil.createShader(Rect.fromCircle(center: c, radius: mr)));
    canvas.drawCircle(
        c,
        mr * 0.84,
        Paint()
          ..shader = const RadialGradient(center: Alignment(-0.3, -0.4), colors: [Color(0xFF16704F), Color(0xFF04261A)])
              .createShader(Rect.fromCircle(center: c, radius: mr * 0.84)));
    final gold = Paint()..color = Lux.goldLight;
    if (w >= 34) {
      for (var k = 0; k < 4; k++) {
        final a = -math.pi / 2 + k * math.pi / 2;
        final pc = c + Offset(math.cos(a), math.sin(a)) * mr * 0.46;
        canvas.drawPath(CardKit.suitPath(k, pc, mr * 0.42), gold);
      }
      canvas.drawCircle(c, mr * 0.1, gold);
    } else {
      canvas.drawPath(CardKit.suitPath(2, c, mr * 0.9), gold);
    }
  }

  // -------------------------------------------------------------------------------------------
  // Face

  void _face(Canvas canvas, Size size, RRect r) {
    final w = size.width, h = size.height;
    canvas.drawRRect(
        r,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_ivoryTop, _ivoryBottom],
          ).createShader(Offset.zero & size));
    // Paper sheen along the top edge.
    canvas.save();
    canvas.clipRRect(r);
    canvas.drawRect(
        Rect.fromLTWH(0, 0, w, h * 0.35),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.white.withValues(alpha: 0.55), Colors.white.withValues(alpha: 0)],
          ).createShader(Rect.fromLTWH(0, 0, w, h * 0.35)));
    canvas.restore();

    final col = CardKit.suitColor(suit);
    final fill = Paint()..color = col;
    final small = w < 56;

    // Corner indices: top-left and (rotated) bottom-right. Large so a fanned hand reads at a glance.
    void index(bool flip) {
      canvas.save();
      if (flip) {
        canvas.translate(w, h);
        canvas.rotate(math.pi);
      }
      final label = CardKit.rankLabel(rank);
      final fs = w * (small ? 0.4 : (label.length > 1 ? 0.225 : 0.255));
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: col,
            fontSize: fs,
            fontWeight: FontWeight.w700,
            height: 1,
            fontFamily: 'Cormorant',
            letterSpacing: label.length > 1 ? -fs * 0.08 : 0,
            fontFeatures: const [FontFeature.liningFigures()],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final cx = w * (small ? 0.24 : 0.13);
      tp.paint(canvas, Offset(math.max(w * 0.035, cx - tp.width / 2), h * 0.04));
      final pip = w * (small ? 0.26 : 0.13);
      canvas.drawPath(CardKit.suitPath(suit, Offset(cx, h * 0.04 + tp.height + pip * 0.62), pip), fill);
      canvas.restore();
    }

    index(false);
    if (!small) index(true);

    final c = Offset(w / 2, h / 2);
    if (small) {
      canvas.drawPath(CardKit.suitPath(suit, Offset(w * 0.6, h * 0.66), w * 0.5), fill);
      return;
    }
    if (rank == 14) {
      _ace(canvas, size, c, col);
    } else if (rank >= 11) {
      _court(canvas, size, c, col);
    } else {
      _pipsLayout(canvas, size, fill);
    }
  }

  void _pipsLayout(Canvas canvas, Size size, Paint fill) {
    final w = size.width, h = size.height;
    final box = Rect.fromLTRB(w * 0.345, h * 0.205, w * 0.655, h * 0.795);
    final pip = w * (rank >= 9 ? 0.165 : 0.18);
    for (final (x, y) in CardKit._pips[rank] ?? const <(double, double)>[]) {
      final p = Offset(box.left + x * box.width, box.top + y * box.height);
      if (y > 0.5) {
        canvas.save();
        canvas.translate(p.dx, p.dy);
        canvas.rotate(math.pi);
        canvas.drawPath(CardKit.suitPath(suit, Offset.zero, pip), fill);
        canvas.restore();
      } else {
        canvas.drawPath(CardKit.suitPath(suit, p, pip), fill);
      }
    }
  }

  void _ace(Canvas canvas, Size size, Offset c, Color col) {
    final w = size.width;
    // Gold filigree ring with small beads, then the big pip.
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, w * 0.014)
      ..shader = Lux.foil.createShader(Rect.fromCircle(center: c, radius: w * 0.36));
    canvas.drawCircle(c, w * 0.34, ring);
    canvas.drawCircle(c, w * 0.305, ring..strokeWidth = math.max(0.6, w * 0.006));
    final bead = Paint()..color = const Color(0xFFB98A35);
    for (var k = 0; k < 16; k++) {
      final a = k * math.pi / 8;
      canvas.drawCircle(c + Offset(math.cos(a), math.sin(a)) * w * 0.322, w * 0.011, bead);
    }
    final pipPath = CardKit.suitPath(suit, c, w * 0.42);
    canvas.drawPath(pipPath.shift(Offset(0, w * 0.012)), Paint()..color = Colors.black.withValues(alpha: 0.18)..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.012));
    canvas.drawPath(
        pipPath,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color.lerp(col, Colors.white, 0.22)!, col, Color.lerp(col, Colors.black, 0.25)!],
          ).createShader(Rect.fromCircle(center: c, radius: w * 0.21)));
  }

  /// Court cards: our own design — a framed enamel panel with a crown / tiara / plume emblem,
  /// the big serif letter and the suit, mirrored top/bottom like a double-headed court.
  void _court(Canvas canvas, Size size, Offset c, Color col) {
    final w = size.width, h = size.height;
    final panel = RRect.fromRectAndRadius(Rect.fromCenter(center: c, width: w * 0.6, height: h * 0.66), Radius.circular(w * 0.05));
    canvas.drawRRect(
        panel,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [col.withValues(alpha: 0.05), col.withValues(alpha: 0.16), col.withValues(alpha: 0.05)],
          ).createShader(panel.outerRect));
    final frame = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, w * 0.016)
      ..shader = Lux.foil.createShader(panel.outerRect);
    canvas.drawRRect(panel, frame);
    canvas.drawRRect(panel.deflate(w * 0.03), Paint()..style = PaintingStyle.stroke..strokeWidth = math.max(0.5, w * 0.006)..color = const Color(0xFFB98A35));
    // Diagonal split line (double-headed court).
    canvas.drawLine(panel.outerRect.centerLeft + Offset(w * 0.04, 0), panel.outerRect.centerRight - Offset(w * 0.04, 0),
        Paint()..color = const Color(0xFFB98A35).withValues(alpha: 0.6)..strokeWidth = math.max(0.5, w * 0.006));

    void half(bool flip) {
      canvas.save();
      if (flip) {
        canvas.translate(w, h);
        canvas.rotate(math.pi);
      }
      final top = panel.outerRect.top;
      final hh = panel.outerRect.height / 2;
      // Emblem.
      final e = Offset(w / 2, top + hh * 0.26);
      _emblem(canvas, e, w * 0.3, col);
      // Letter.
      final tp = TextPainter(
        text: TextSpan(
          text: CardKit.rankLabel(rank),
          style: TextStyle(
            color: col,
            fontSize: w * 0.3,
            fontWeight: FontWeight.w700,
            fontStyle: FontStyle.italic,
            height: 1,
            fontFamily: 'Cormorant',
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(w * 0.42 - tp.width / 2, top + hh * 0.5 - tp.height * 0.08));
      canvas.drawPath(CardKit.suitPath(suit, Offset(w * 0.62, top + hh * 0.72), w * 0.13), Paint()..color = col);
      canvas.restore();
    }

    half(false);
    half(true);
  }

  void _emblem(Canvas canvas, Offset c, double s, Color col) {
    final gold = Paint()..shader = Lux.foil.createShader(Rect.fromCenter(center: c, width: s, height: s * 0.6));
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.6, s * 0.03)
      ..color = const Color(0xFF6F4F17);
    final p = Path();
    switch (rank) {
      case 13: // crown: five points
        final b = c.dy + s * 0.2, t = c.dy - s * 0.22;
        p.moveTo(c.dx - s * 0.5, b);
        p.lineTo(c.dx - s * 0.5, t + s * 0.1);
        p.lineTo(c.dx - s * 0.28, c.dy - s * 0.02);
        p.lineTo(c.dx - s * 0.14, t);
        p.lineTo(c.dx, c.dy - s * 0.04);
        p.lineTo(c.dx + s * 0.14, t);
        p.lineTo(c.dx + s * 0.28, c.dy - s * 0.02);
        p.lineTo(c.dx + s * 0.5, t + s * 0.1);
        p.lineTo(c.dx + s * 0.5, b);
        p.close();
        canvas.drawPath(p, gold);
        canvas.drawPath(p, outline);
        for (final dx in [-0.5, -0.14, 0.14, 0.5]) {
          canvas.drawCircle(Offset(c.dx + dx * s, (dx.abs() > 0.3 ? t + s * 0.1 : t) - s * 0.04), s * 0.055, gold);
        }
        canvas.drawCircle(Offset(c.dx, c.dy + s * 0.08), s * 0.07, Paint()..color = col);
      case 12: // tiara: an arch with three jewels
        p.moveTo(c.dx - s * 0.48, c.dy + s * 0.18);
        p.quadraticBezierTo(c.dx, c.dy - s * 0.42, c.dx + s * 0.48, c.dy + s * 0.18);
        p.quadraticBezierTo(c.dx, c.dy - s * 0.08, c.dx - s * 0.48, c.dy + s * 0.18);
        p.close();
        canvas.drawPath(p, gold);
        canvas.drawPath(p, outline);
        canvas.drawCircle(Offset(c.dx, c.dy - s * 0.2), s * 0.08, Paint()..color = col);
        canvas.drawCircle(Offset(c.dx - s * 0.24, c.dy - s * 0.05), s * 0.05, Paint()..color = col);
        canvas.drawCircle(Offset(c.dx + s * 0.24, c.dy - s * 0.05), s * 0.05, Paint()..color = col);
      default: // plume: a feather over a band
        p.moveTo(c.dx - s * 0.36, c.dy + s * 0.2);
        p.lineTo(c.dx + s * 0.36, c.dy + s * 0.2);
        p.lineTo(c.dx + s * 0.3, c.dy + s * 0.04);
        p.lineTo(c.dx - s * 0.3, c.dy + s * 0.04);
        p.close();
        canvas.drawPath(p, gold);
        canvas.drawPath(p, outline);
        final f = Path()
          ..moveTo(c.dx - s * 0.05, c.dy + s * 0.04)
          ..cubicTo(c.dx - s * 0.3, c.dy - s * 0.15, c.dx - s * 0.05, c.dy - s * 0.4, c.dx + s * 0.28, c.dy - s * 0.38)
          ..cubicTo(c.dx + s * 0.05, c.dy - s * 0.25, c.dx + s * 0.1, c.dy - s * 0.08, c.dx + s * 0.05, c.dy + s * 0.04)
          ..close();
        canvas.drawPath(f, Paint()..color = col.withValues(alpha: 0.85));
        canvas.drawPath(f, outline);
    }
  }

  @override
  bool shouldRepaint(CardPainter old) =>
      old.suit != suit || old.rank != rank || old.faceUp != faceUp || old.highlight != highlight || old.dim != dim;
}
