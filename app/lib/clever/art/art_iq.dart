import 'package:flutter/material.dart';

import 'game_art.dart';

/// Medallion illustration for the IQ game: a 3 × 3 matrix of ivory tiles holding a small shape
/// pattern (one shape per row, growing count per column) with the last cell in gold leaf and a "?".
final Map<String, GameArtPainter> iqArt = {
  'iq': _box(_iq),
};

/// Wraps a painter that draws in a 100 × 100 design box (centre = (50, 50), safe radius ≈ 40).
GameArtPainter _box(void Function(Canvas canvas, Color tint) draw) => (canvas, s, tint) {
      canvas.save();
      canvas.scale(s.width / 100);
      draw(canvas, tint);
      canvas.restore();
    };

void _dot(Canvas canvas, Offset c, double r, Color col, int kind) {
  final p = Paint()..color = col;
  switch (kind) {
    case 0:
      canvas.drawCircle(c, r, p);
    case 1:
      canvas.drawRect(Rect.fromCircle(center: c, radius: r * 0.85), p);
    default:
      canvas.drawPath(
        Path()
          ..moveTo(c.dx, c.dy - r)
          ..lineTo(c.dx + r, c.dy + r * 0.8)
          ..lineTo(c.dx - r, c.dy + r * 0.8)
          ..close(),
        p,
      );
  }
}

void _iq(Canvas canvas, Color tint) {
  const cell = 19.0;
  const gap = 3.5;
  const total = cell * 3 + gap * 2;
  const x0 = 50 - total / 2;
  const y0 = 50 - total / 2;
  // Frame plate under the matrix.
  final plate = RRect.fromRectAndRadius(const Rect.fromLTWH(x0 - 4, y0 - 4, total + 8, total + 8), const Radius.circular(6));
  ArtKit.shadow(canvas, Path()..addRRect(plate), blur: 3, offset: const Offset(0, 2.5), alpha: 0.5);
  canvas.drawRRect(plate, Paint()..color = Color.lerp(tint, Colors.black, 0.45)!);
  canvas.drawRRect(
    plate,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..shader = ArtKit.goldShader(plate.outerRect),
  );
  const colors = [ArtKit.ruby, ArtKit.sapphire, ArtKit.emerald];
  for (var row = 0; row < 3; row++) {
    for (var col = 0; col < 3; col++) {
      final r = Rect.fromLTWH(x0 + col * (cell + gap), y0 + row * (cell + gap), cell, cell);
      final last = row == 2 && col == 2;
      if (last) {
        final rr = RRect.fromRectAndRadius(r, const Radius.circular(3.5));
        canvas.drawRRect(rr, Paint()..shader = ArtKit.goldShader(r));
        canvas.drawRRect(
          rr,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.9
            ..color = ArtKit.goldDeep,
        );
        ArtKit.text(canvas, '?', r.center + const Offset(0, 0.5), 17, color: ArtKit.ink);
        continue;
      }
      ArtKit.tile(canvas, r, ArtKit.ivory, radius: 0.18, shadowed: false);
      // Row = shape, column = count (1, 2, 3).
      final n = col + 1;
      final rad = n == 1 ? 4.2 : (n == 2 ? 3.3 : 2.7);
      for (var k = 0; k < n; k++) {
        final dx = n == 1 ? 0.0 : (k - (n - 1) / 2) * (rad * 2.2);
        _dot(canvas, r.center + Offset(dx, 0.5), rad, colors[row], row);
      }
    }
  }
}
