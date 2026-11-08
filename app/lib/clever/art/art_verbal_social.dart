import 'package:flutter/material.dart';

import 'game_art.dart';

/// Medallion illustration for Sözel ve Sosyal Zeka: a large ivory speech bubble with a gold "A"
/// (words), and a small ruby heart in a gold-rimmed second bubble (people and feelings) tucked at
/// its lower right.
final Map<String, GameArtPainter> verbalSocialArt = {
  'verbal_social': (canvas, s, tint) {
    canvas.save();
    canvas.scale(s.width / 100);
    _paint(canvas);
    canvas.restore();
  },
};

Paint _outline(double width, [Color color = const Color(0xFF4A3410)]) => Paint()
  ..style = PaintingStyle.stroke
  ..strokeWidth = width
  ..strokeJoin = StrokeJoin.round
  ..strokeCap = StrokeCap.round
  ..color = color;

/// A speech bubble: rounded body plus a tail ending at [tip].
Path _bubble(Rect body, double radius, Offset tailA, Offset tip, Offset tailB) {
  final rr = Path()..addRRect(RRect.fromRectAndRadius(body, Radius.circular(radius)));
  final tail = Path()
    ..moveTo(tailA.dx, tailA.dy)
    ..quadraticBezierTo((tailA.dx + tip.dx) / 2, (tailA.dy + tip.dy) / 2, tip.dx, tip.dy)
    ..quadraticBezierTo((tailB.dx + tip.dx) / 2, (tailB.dy + tip.dy) / 2 - 2, tailB.dx, tailB.dy)
    ..close();
  return Path.combine(PathOperation.union, rr, tail);
}

/// A heart centred at [c], [w] wide.
Path _heart(Offset c, double w) {
  final h = w * 0.9;
  final top = c.dy - h * 0.32;
  return Path()
    ..moveTo(c.dx, c.dy + h * 0.5)
    ..cubicTo(c.dx - w * 0.62, c.dy + h * 0.05, c.dx - w * 0.52, top - h * 0.42, c.dx, top)
    ..cubicTo(c.dx + w * 0.52, top - h * 0.42, c.dx + w * 0.62, c.dy + h * 0.05, c.dx, c.dy + h * 0.5)
    ..close();
}

void _paint(Canvas canvas) {
  // Main bubble (ivory, gold rim) with the tail down-left.
  const a = Rect.fromLTRB(14, 18, 74, 62);
  final pa = _bubble(a, 13, const Offset(24, 60), const Offset(18, 76), const Offset(38, 61));
  ArtKit.shadow(canvas, pa, blur: 3.2, offset: const Offset(0, 3), alpha: 0.5);
  canvas.drawPath(
      pa,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFFFCF3), Color(0xFFF3E6C8), Color(0xFFD9C79E)],
          stops: [0, 0.6, 1],
        ).createShader(a));
  canvas.drawPath(pa, _outline(2.4)..shader = ArtKit.goldShader(a.inflate(2)));
  // The "A": gold leaf with a dark keyline so it reads at 44 px.
  final glyph = Path()
    ..moveTo(32, 54)
    ..lineTo(44, 25)
    ..lineTo(56, 54);
  final bar = Path()
    ..moveTo(36.8, 44)
    ..lineTo(51.2, 44);
  for (final p in [glyph, bar]) {
    canvas.drawPath(p, _outline(8.2, const Color(0xFF3A2410)));
  }
  for (final p in [glyph, bar]) {
    ArtKit.goldStroke(canvas, p, 5.4);
  }
  // Small bubble with a ruby heart, overlapping the lower right.
  const b = Rect.fromLTRB(56, 52, 86, 78);
  final pb = _bubble(b, 9, const Offset(76, 76), const Offset(84, 86), const Offset(82, 72));
  ArtKit.shadow(canvas, pb, blur: 3, offset: const Offset(0, 3), alpha: 0.55);
  canvas.drawPath(pb, Paint()..shader = ArtKit.goldShader(b.inflate(4)));
  canvas.drawPath(pb, _outline(1.3, const Color(0xFF6A4A14)));
  final heart = _heart(const Offset(71, 66), 15);
  final hb = heart.getBounds();
  canvas.drawPath(
      heart,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.4),
          radius: 0.9,
          colors: [Color.lerp(ArtKit.ruby, Colors.white, 0.45)!, ArtKit.ruby, Color.lerp(ArtKit.ruby, Colors.black, 0.45)!],
          stops: const [0, 0.5, 1],
        ).createShader(hb));
  canvas.drawPath(heart, _outline(1.0, const Color(0xFF5A1020)));
  canvas.drawCircle(const Offset(67.2, 62.4), 1.5, Paint()..color = Colors.white.withValues(alpha: 0.8));
}
