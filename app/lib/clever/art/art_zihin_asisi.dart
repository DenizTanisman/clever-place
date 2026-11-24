import 'package:flutter/material.dart';

import 'game_art.dart';

/// Medallion illustration for Zihin Aşısı: a gold shield with an ivory check mark.
final Map<String, GameArtPainter> zihinAsisiArt = {
  'zihin_asisi': (canvas, s, tint) {
    canvas.save();
    canvas.scale(s.width / 100);
    final shield = Path()
      ..moveTo(50, 16)
      ..cubicTo(60, 23, 71, 26, 80, 26)
      ..cubicTo(80, 56, 70, 75, 50, 86)
      ..cubicTo(30, 75, 20, 56, 20, 26)
      ..cubicTo(29, 26, 40, 23, 50, 16)
      ..close();
    canvas.drawPath(
      shield,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF2D58A), Color(0xFFB98A2E)],
        ).createShader(const Rect.fromLTWH(20, 16, 60, 70)),
    );
    canvas.drawPath(
      shield,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = const Color(0xFF4A3410),
    );
    canvas.drawPath(
      Path()
        ..moveTo(36, 50)
        ..lineTo(47, 62)
        ..lineTo(66, 38),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0xFFFFF8E6),
    );
    canvas.restore();
  },
};
