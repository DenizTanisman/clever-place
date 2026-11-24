import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'game_art.dart';

/// Medallion illustration for Dönen Sayılar: two gold rings turning opposite ways, carrying numbered
/// pearl discs, with a gold point in the middle.
final Map<String, GameArtPainter> donenSayilarArt = {
  'donen_sayilar': (canvas, s, tint) {
    final k = s.width / 100;
    final c = Offset(50 * k, 50 * k);

    void arrowArc(double r, double start, double sweep) {
      final rect = Rect.fromCircle(center: c, radius: r);
      ArtKit.goldStroke(canvas, Path()..addArc(rect, start, sweep), 3 * k);
      final end = start + sweep;
      final tip = c + Offset.fromDirection(end, r);
      final dir = end + (sweep > 0 ? math.pi / 2 : -math.pi / 2);
      final head = Path()
        ..moveTo(tip.dx + math.cos(dir) * 5 * k, tip.dy + math.sin(dir) * 5 * k)
        ..lineTo(tip.dx + math.cos(dir + 2.5) * 5 * k, tip.dy + math.sin(dir + 2.5) * 5 * k)
        ..lineTo(tip.dx + math.cos(dir - 2.5) * 5 * k, tip.dy + math.sin(dir - 2.5) * 5 * k)
        ..close();
      canvas.drawPath(head, Paint()..color = ArtKit.gold);
    }

    void pearl(double r, double angle, String label, {bool lit = false}) {
      final p = c + Offset.fromDirection(angle, r);
      ArtKit.ball(canvas, p, 12 * k, lit ? ArtKit.gold : ArtKit.pearl);
      ArtKit.text(canvas, label, p + Offset(0, 0.4 * k), 17 * k, color: ArtKit.ink);
    }

    arrowArc(36 * k, -2.5, 2.1);
    arrowArc(36 * k, 0.75, 1.5);
    arrowArc(19 * k, 2.4, -2.0);
    arrowArc(19 * k, -0.6, -1.5);

    pearl(36 * k, -0.25, '1', lit: true);
    pearl(36 * k, 2.55, '3');
    pearl(19 * k, 1.5, '2');
    pearl(19 * k, -2.55, '4');

    canvas.drawCircle(c, 3.2 * k, Paint()..color = ArtKit.goldLight);
  },
};
