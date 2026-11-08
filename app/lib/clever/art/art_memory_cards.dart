import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../card_kit.dart';
import 'game_art.dart';

/// Medallion illustrations for: nback palace digit_span corsi pairs scene_quiz word_list batak okey blof blackjack.
final Map<String, GameArtPainter> memoryCardsArt = {
  'nback': _box(_nback),
  'palace': _box(_palace),
  'digit_span': _box(_digitSpan),
  'corsi': _box(_corsi),
  'pairs': _box(_pairs),
  'scene_quiz': _box(_sceneQuiz),
  'word_list': _box(_wordList),
  'batak': _box(_batak),
  'okey': _box(_okey),
  'blof': _box(_blof),
  'blackjack': _box(_blackjack),
};

// ---------------------------------------------------------------------------------------------
// Shared helpers (all coordinates in a 100 × 100 design box, scaled by `u`).

/// Wraps a painter that draws in a 100 × 100 design box (centre = (50, 50), safe radius ≈ 40).
GameArtPainter _box(void Function(Canvas canvas, Color tint) draw) => (canvas, s, tint) {
      canvas.save();
      canvas.scale(s.width / 100);
      draw(canvas, tint);
      canvas.restore();
    };

/// Text centred at [c] with lining figures; optional gold [shader] and dark [stroke] outline.
void _glyph(Canvas canvas, String s, Offset c, double size,
    {Color color = ArtKit.ink,
    Shader? shader,
    String family = 'Cormorant',
    FontWeight weight = FontWeight.w700,
    Color? stroke,
    double strokeWidth = 0,
    double dy = 0}) {
  TextPainter build(Paint? fg) => TextPainter(
        text: TextSpan(
          text: s,
          style: TextStyle(
            fontFamily: family,
            fontSize: size,
            fontWeight: weight,
            height: 1.0,
            color: fg == null ? color : null,
            foreground: fg,
            fontFeatures: const [FontFeature.liningFigures()],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
  final probe = build(null);
  final at = c - Offset(probe.width / 2, probe.height / 2) + Offset(0, dy * size);
  if (stroke != null && strokeWidth > 0) {
    build(Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeJoin = StrokeJoin.round
          ..color = stroke)
        .paint(canvas, at);
  }
  if (shader != null) {
    build(Paint()..shader = shader).paint(canvas, at);
  } else {
    probe.paint(canvas, at);
  }
}

/// Runs [draw] with the canvas rotated by [angle] around [c].
void _rotated(Canvas canvas, Offset c, double angle, void Function() draw) {
  canvas.save();
  canvas.translate(c.dx, c.dy);
  canvas.rotate(angle);
  canvas.translate(-c.dx, -c.dy);
  draw();
  canvas.restore();
}

double _deg(double d) => d * math.pi / 180;

const _ivoryHi = Color(0xFFFFFCF3);
const _ivoryLo = Color(0xFFEADCB8);
const _goldEdge = Color(0xFF8E6A2A);

/// A playing card centred at [c] (width [w], poker aspect), rotated by [angle].
/// [content] paints the face inside the card's (unrotated) rect.
void _card(Canvas canvas, Offset c, double w, double angle,
    {bool faceUp = true, void Function(Rect r)? content, bool glow = false, double? height}) {
  final h = height ?? w / CardKit.aspect;
  final rect = Rect.fromCenter(center: c, width: w, height: h);
  final rr = RRect.fromRectAndRadius(rect, Radius.circular(w * 0.13));
  // Shadow in world space (unrotated offset), shape rotated.
  _rotated(canvas, c + Offset(0, w * 0.07), angle, () {
    canvas.drawRRect(
        rr.shift(Offset(0, w * 0.07)),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.5)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.08));
  });
  _rotated(canvas, c, angle, () {
    if (glow) {
      canvas.drawRRect(
          rr.inflate(w * 0.06),
          Paint()
            ..color = ArtKit.goldLight.withValues(alpha: 0.75)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.09));
    }
    if (faceUp) {
      canvas.drawRRect(
          rr,
          Paint()
            ..shader = const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [_ivoryHi, Color(0xFFF6EDD6), _ivoryLo],
              stops: [0, 0.55, 1],
            ).createShader(rect));
      content?.call(rect);
      canvas.drawRRect(
          rr.deflate(w * 0.015),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1.8, w * 0.055)
            ..color = glow ? ArtKit.gold : _goldEdge.withValues(alpha: 0.8));
    } else {
      _cardBack(canvas, rr, w);
    }
  });
}

/// The emerald-and-gold card back (same family as the in-game deck).
void _cardBack(Canvas canvas, RRect rr, double w) {
  final rect = rr.outerRect;
  canvas.drawRRect(
      rr,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1A7656), Color(0xFF0B3D2E), Color(0xFF052419)],
          stops: [0, 0.55, 1],
        ).createShader(rect));
  canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.8, w * 0.06)
        ..shader = ArtKit.goldShader(rect));
  final inner = rr.deflate(w * 0.14);
  canvas.drawRRect(
      inner,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.2, w * 0.04)
        ..color = ArtKit.gold.withValues(alpha: 0.75));
  final c = rect.center;
  canvas.drawPath(CardKit.suitPath(2, c, w * 0.44), Paint()..shader = ArtKit.goldShader(rect));
  canvas.drawCircle(c, w * 0.05, Paint()..color = const Color(0xFF0B3D2E));
}

/// A card face with a big rank and a big suit pip (readable at medallion size).
void _faceRankSuit(Canvas canvas, Rect r, String rank, int suit, {bool bigPip = true}) {
  final w = r.width;
  final col = CardKit.suitColor(suit);
  _glyph(canvas, rank, Offset(r.left + w * 0.3, r.top + r.height * 0.24), w * 0.52, color: col);
  if (bigPip) {
    canvas.drawPath(
        CardKit.suitPath(suit, Offset(r.left + w * 0.58, r.top + r.height * 0.66), w * 0.56), Paint()..color = col);
  } else {
    canvas.drawPath(
        CardKit.suitPath(suit, Offset(r.left + w * 0.3, r.top + r.height * 0.47), w * 0.28), Paint()..color = col);
  }
}

Paint _goldFill(Rect r) => Paint()..shader = ArtKit.goldShader(r);

Paint _outline(double width, [Color color = const Color(0xFF4A3410)]) => Paint()
  ..style = PaintingStyle.stroke
  ..strokeWidth = width
  ..strokeJoin = StrokeJoin.round
  ..color = color;

const _o = Offset.new;

// ---------------------------------------------------------------------------------------------
// nback: a stream of lacquer cards; the front one carries a big gold digit.

void _lacquerCard(Canvas canvas, Offset c, double w, double h, String digit, double alpha) {
  final rect = Rect.fromCenter(center: c, width: w, height: h);
  final rr = RRect.fromRectAndRadius(rect, Radius.circular(w * 0.16));
  final layer = alpha < 1;
  if (layer) canvas.saveLayer(rect.inflate(w * 0.4), Paint()..color = Colors.white.withValues(alpha: alpha));
  ArtKit.shadow(canvas, Path()..addRRect(rr), blur: w * 0.08, offset: Offset(0, w * 0.08), alpha: 0.55);
  canvas.drawRRect(
      rr,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2E376F), Color(0xFF141940), Color(0xFF080A1C)],
        ).createShader(rect));
  canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(rect.left + w * 0.12, rect.top + w * 0.1, w * 0.76, h * 0.28), Radius.circular(w * 0.1)),
      Paint()..color = Colors.white.withValues(alpha: 0.07));
  canvas.drawRRect(
      rr.deflate(w * 0.035),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.075
        ..shader = ArtKit.goldShader(rect));
  _glyph(canvas, digit, c, w * 1.05,
      shader: ArtKit.goldShader(rect.deflate(w * 0.15)),
      stroke: const Color(0xFF04050D),
      strokeWidth: w * 0.07,
      dy: 0.03);
  if (layer) canvas.restore();
}

void _nback(Canvas canvas, Color tint) {
  // Fanned wide enough that the earlier digits stay readable behind the current one.
  _lacquerCard(canvas, _o(21, 42), 22, 31, '3', 0.5);
  _lacquerCard(canvas, _o(36, 46), 27, 38, '5', 0.78);
  _lacquerCard(canvas, _o(61, 52), 37, 51, '7', 1);
}

// ---------------------------------------------------------------------------------------------
// palace: a marble-and-gold temple with jewels placed on its doorsteps.

void _palace(Canvas canvas, Color tint) {
  const marble = [Color(0xFFFFFBF0), Color(0xFFE9DEC4), Color(0xFFB9A98A)];
  Paint marbleFill(Rect r, {bool vertical = false}) => Paint()
    ..shader = LinearGradient(
      begin: vertical ? Alignment.topCenter : Alignment.centerLeft,
      end: vertical ? Alignment.bottomCenter : Alignment.centerRight,
      colors: marble,
      stops: const [0, 0.45, 1],
    ).createShader(r);
  final deep = _outline(1.4, const Color(0xFF3E2C0C));

  // Whole-temple shadow.
  final silhouette = Path()
    ..moveTo(50, 16)
    ..lineTo(84, 40)
    ..lineTo(84, 80)
    ..lineTo(16, 80)
    ..lineTo(16, 40)
    ..close();
  ArtKit.shadow(canvas, silhouette, blur: 3, offset: const Offset(0, 3), alpha: 0.4);

  // Dark interior between the columns.
  canvas.drawRect(const Rect.fromLTRB(22, 46, 78, 69), Paint()..color = const Color(0xFF1E1404));
  // Warm light spilling from the doorways.
  for (final x in [34.5, 50.0, 65.5]) {
    final r = Rect.fromLTRB(x - 4.5, 52, x + 4.5, 69);
    canvas.drawRRect(
        RRect.fromRectAndCorners(r, topLeft: const Radius.circular(4.5), topRight: const Radius.circular(4.5)),
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF6A4A12), Color(0xFFE9B85A)],
          ).createShader(r));
  }
  // Columns.
  for (final x in [27.0, 42.0, 58.0, 73.0]) {
    final r = Rect.fromLTRB(x - 4.2, 47, x + 4.2, 69);
    canvas.drawRect(r, marbleFill(r));
    canvas.drawLine(
        Offset(x, 49),
        Offset(x, 67),
        Paint()
          ..color = const Color(0x55806A44)
          ..strokeWidth = 1.2);
    final cap = Rect.fromLTRB(x - 5.6, 46, x + 5.6, 49.5);
    canvas.drawRect(cap, _goldFill(cap));
  }
  // Entablature and pediment.
  const ent = Rect.fromLTRB(18, 39.5, 82, 46.5);
  canvas.drawRect(ent, _goldFill(ent));
  canvas.drawRect(ent, deep);
  final ped = Path()
    ..moveTo(15, 40)
    ..lineTo(50, 16)
    ..lineTo(85, 40)
    ..close();
  canvas.drawPath(ped, _goldFill(const Rect.fromLTRB(15, 16, 85, 40)));
  canvas.drawPath(ped, deep);
  final tymp = Path()
    ..moveTo(26, 36.5)
    ..lineTo(50, 21.5)
    ..lineTo(74, 36.5)
    ..close();
  canvas.drawPath(tymp, marbleFill(const Rect.fromLTRB(26, 21, 74, 37), vertical: true));
  ArtKit.gem(canvas, const Offset(50, 31.5), 4.2, ArtKit.ruby, sides: 8);
  // Steps.
  const s1 = Rect.fromLTRB(19, 69, 81, 74);
  const s2 = Rect.fromLTRB(15, 74, 85, 79.5);
  for (final r in [s2, s1]) {
    canvas.drawRect(r, marbleFill(r, vertical: true));
    canvas.drawRect(r, _outline(0.9, const Color(0x996A5838)));
  }
  // Jewels on the doorsteps.
  ArtKit.gem(canvas, const Offset(34.5, 68.5), 5.4, ArtKit.sapphire);
  ArtKit.gem(canvas, const Offset(50, 68.5), 5.4, ArtKit.emerald);
  ArtKit.gem(canvas, const Offset(65.5, 68.5), 5.4, ArtKit.amethyst);
}

// ---------------------------------------------------------------------------------------------
// digit_span: a row of ivory number tiles and a gold "say it back" return arrow.

void _digitSpan(Canvas canvas, Color tint) {
  const ink = Color(0xFF16294A);
  final digits = ['4', '7', '2'];
  for (var i = 0; i < 3; i++) {
    final r = Rect.fromLTWH(16.5 + i * 23, 24, 20, 29);
    ArtKit.tile(canvas, r, const Color(0xFFF4EAD2), radius: 0.2);
    _glyph(canvas, digits[i], r.center, 27, color: ink, dy: 0.03);
  }
  // Return arrow underneath.
  final arc = Path()
    ..moveTo(71, 60)
    ..quadraticBezierTo(70, 76, 50, 76)
    ..quadraticBezierTo(35, 76, 31.5, 66);
  canvas.drawPath(
      arc.shift(const Offset(0, 1.6)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5.4
        ..strokeCap = StrokeCap.round
        ..color = Colors.black.withValues(alpha: 0.35));
  ArtKit.goldStroke(canvas, arc, 5.4);
  final head = Path()
    ..moveTo(24, 66)
    ..lineTo(31, 56.5)
    ..lineTo(38.5, 66.5)
    ..close();
  ArtKit.shadow(canvas, head, blur: 1.5, offset: const Offset(0, 1.6), alpha: 0.35);
  canvas.drawPath(head, _goldFill(head.getBounds()));
}

// ---------------------------------------------------------------------------------------------
// corsi: scattered jade blocks, three lit in gold with their order.

void _corsi(Canvas canvas, Color tint) {
  const jade = Color(0xFF2E5446);
  final blocks = <(Offset, double, int)>[
    (const Offset(31, 33), -8, 1),
    (const Offset(62, 28), 6, 0),
    (const Offset(50, 51), -4, 0),
    (const Offset(73, 53), 9, 2),
    (const Offset(28, 62), 5, 0),
    (const Offset(53, 74), -7, 3),
  ];
  // Faint gold trail through the lit order.
  final trail = Path()
    ..moveTo(31, 33)
    ..lineTo(73, 53)
    ..lineTo(53, 74);
  canvas.drawPath(
      trail,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeJoin = StrokeJoin.round
        ..color = ArtKit.goldLight.withValues(alpha: 0.45));
  for (final (c, a, n) in blocks) {
    _rotated(canvas, c, _deg(a), () {
      final r = Rect.fromCenter(center: c, width: 18, height: 18);
      if (n > 0) {
        canvas.drawCircle(
            c,
            13,
            Paint()
              ..color = ArtKit.gold.withValues(alpha: 0.55)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
        ArtKit.tile(canvas, r, ArtKit.gold, radius: 0.22);
        _glyph(canvas, '$n', c, 16, color: const Color(0xFF2A1D05), family: 'Jost', dy: 0.02);
      } else {
        ArtKit.tile(canvas, r, jade, radius: 0.22);
      }
    });
  }
}

// ---------------------------------------------------------------------------------------------
// pairs: a 3 × 2 spread of face-down cards with two matching ruby cards turned up.

void _pairs(Canvas canvas, Color tint) {
  const w = 19.0, h = 25.0, gap = 4.0;
  const x0 = 50 - (3 * w + 2 * gap) / 2, y0 = 50 - (2 * h + gap) / 2;
  for (var row = 0; row < 2; row++) {
    for (var col = 0; col < 3; col++) {
      final c = Offset(x0 + col * (w + gap) + w / 2, y0 + row * (h + gap) + h / 2);
      final up = (row == 0 && col == 1) || (row == 1 && col == 0);
      _card(canvas, c, w, 0, height: h, faceUp: up, glow: up, content: (r) {
        ArtKit.gem(canvas, r.center, 7, ArtKit.ruby);
      });
    }
  }
}

// ---------------------------------------------------------------------------------------------
// scene_quiz: a gold-framed little scene of three hatted figures, and a question badge.

void _sceneQuiz(Canvas canvas, Color tint) {
  const pic = Rect.fromLTRB(18, 29, 72, 74);
  final frame = RRect.fromRectAndRadius(pic, const Radius.circular(3));
  ArtKit.shadow(canvas, Path()..addRRect(frame.inflate(2.5)), blur: 3, offset: const Offset(0, 3), alpha: 0.5);
  canvas.save();
  canvas.clipRRect(frame);
  canvas.drawRect(
      pic,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF8FC2E8), Color(0xFFF3E6C4)],
        ).createShader(pic));
  canvas.drawOval(const Rect.fromLTRB(4, 60, 86, 92), Paint()..color = const Color(0xFF3E7F45));
  // Figures: (x, body colour, hat kind).
  const skin = Color(0xFFF1CFA6);
  for (final (x, body, hat) in [
    (31.0, ArtKit.ruby, 0),
    (45.0, ArtKit.sapphire, 1),
    (59.0, ArtKit.emerald, 2),
  ]) {
    final torso = Path()
      ..moveTo(x - 7, 76)
      ..lineTo(x - 6, 60)
      ..quadraticBezierTo(x, 55, x + 6, 60)
      ..lineTo(x + 7, 76)
      ..close();
    canvas.drawPath(
        torso,
        Paint()
          ..shader = LinearGradient(
            colors: [Color.lerp(body, Colors.white, 0.3)!, Color.lerp(body, Colors.black, 0.35)!],
          ).createShader(torso.getBounds()));
    ArtKit.ball(canvas, Offset(x, 50), 5, skin, shadowed: false);
    final hp = Paint();
    switch (hat) {
      case 0: // top hat
        hp.color = const Color(0xFF161210);
        canvas.drawRRect(RRect.fromLTRBR(x - 7, 45, x + 7, 47, const Radius.circular(1)), hp);
        canvas.drawRect(Rect.fromLTRB(x - 4.2, 36.5, x + 4.2, 45.5), hp);
        canvas.drawRect(Rect.fromLTRB(x - 4.2, 43, x + 4.2, 44.5), Paint()..color = ArtKit.ruby);
      case 1: // gold bowler
        final bowl = Rect.fromLTRB(x - 5, 40, x + 5, 50);
        canvas.drawArc(bowl, math.pi, math.pi, true, _goldFill(bowl));
        canvas.drawRRect(RRect.fromLTRBR(x - 7.5, 44.5, x + 7.5, 46.8, const Radius.circular(1.2)), _goldFill(bowl));
      default: // wide straw hat with a dark band: reads as a hat even at hub size
        const straw = Color(0xFFD9A441);
        canvas.drawOval(Rect.fromLTRB(x - 10.5, 42.5, x + 10.5, 48), Paint()..color = const Color(0xFF8A5A17));
        canvas.drawOval(Rect.fromLTRB(x - 10, 42, x + 10, 47), Paint()..color = straw);
        canvas.drawRRect(RRect.fromLTRBR(x - 5.5, 35.5, x + 5.5, 45, const Radius.circular(3.5)), Paint()..color = straw);
        canvas.drawRect(Rect.fromLTRB(x - 5.5, 41.5, x + 5.5, 44), Paint()..color = const Color(0xFF3B2410));
    }
  }
  canvas.restore();
  canvas.drawRRect(
      frame.inflate(1.2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.2
        ..shader = ArtKit.goldShader(pic.inflate(3)));
  canvas.drawRRect(frame.inflate(3.3), _outline(0.8, const Color(0xAA3E2C0C)));
  // Question badge.
  const bc = Offset(70, 31);
  ArtKit.ball(canvas, bc, 12, ArtKit.ruby);
  canvas.drawCircle(bc, 12, _outline(1.8)..shader = ArtKit.goldShader(Rect.fromCircle(center: bc, radius: 12)));
  _glyph(canvas, '?', bc, 21, color: ArtKit.ivory, dy: 0.04);
}

// ---------------------------------------------------------------------------------------------
// word_list: a parchment scroll with an ink list, and a gold quill.

void _wordList(Canvas canvas, Color tint) {
  const sheet = Rect.fromLTRB(25, 22, 67, 78);
  const parchment = [Color(0xFFFBF0D2), Color(0xFFEBD7A6), Color(0xFFCFB27A)];
  ArtKit.shadow(canvas, Path()..addRect(sheet.inflate(3)), blur: 3, offset: const Offset(0, 3), alpha: 0.45);
  canvas.drawRect(
      sheet,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: parchment,
          stops: [0, 0.6, 1],
        ).createShader(sheet));
  // Rolls at top and bottom.
  for (final y in [21.0, 79.0]) {
    final roll = RRect.fromLTRBR(21, y - 4, 71, y + 4, const Radius.circular(4));
    canvas.drawRRect(
        roll,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFFFF6DC), Color(0xFFD9BC82), Color(0xFF8E6A36)],
          ).createShader(roll.outerRect));
    for (final x in [21.0, 71.0]) {
      final knob = Rect.fromCircle(center: Offset(x, y), radius: 4.2);
      canvas.drawOval(knob, _goldFill(knob));
    }
  }
  // Ink lines with gold bullets.
  const ink = Color(0xFF4A3420);
  final lineP = Paint()
    ..strokeWidth = 3.4
    ..strokeCap = StrokeCap.round
    ..color = ink;
  for (final (y, end) in [(33.0, 60.0), (43.0, 56.0), (53.0, 61.0), (63.0, 52.0)]) {
    canvas.drawCircle(Offset(31.5, y), 2.6, _goldFill(Rect.fromCircle(center: Offset(31.5, y), radius: 2.6)));
    canvas.drawCircle(Offset(31.5, y), 2.6, _outline(0.7, const Color(0xFF6A4A14)));
    canvas.drawLine(Offset(37, y), Offset(end, y), lineP);
  }
  // Quill: a feather lying across the right edge.
  _rotated(canvas, const Offset(66, 52), _deg(28), () {
    final vane = Path()
      ..moveTo(66, 82)
      ..cubicTo(58, 66, 58, 38, 66, 20)
      ..cubicTo(75, 38, 75, 64, 66, 82)
      ..close();
    ArtKit.shadow(canvas, vane, blur: 2.5, offset: const Offset(0, 2.5), alpha: 0.45);
    canvas.drawPath(
        vane,
        Paint()
          ..shader = const LinearGradient(
            colors: [Color(0xFFFFFDF5), Color(0xFFE8DCC2), Color(0xFFB8A785)],
            stops: [0, 0.5, 1],
          ).createShader(const Rect.fromLTRB(59, 20, 74, 82)));
    // Barb notches.
    final notch = Paint()
      ..strokeWidth = 1.2
      ..color = const Color(0x886A5838);
    for (final y in [34.0, 46.0, 58.0]) {
      canvas.drawLine(Offset(66, y + 4), Offset(71.5, y), notch);
      canvas.drawLine(Offset(66, y + 6), Offset(60.5, y + 2), notch);
    }
    ArtKit.goldStroke(
        canvas,
        Path()
          ..moveTo(66, 24)
          ..lineTo(66, 88),
        2.2);
    final nib = Path()
      ..moveTo(63.5, 82)
      ..lineTo(68.5, 82)
      ..lineTo(66, 92)
      ..close();
    canvas.drawPath(nib, _goldFill(nib.getBounds()));
  });
}

// ---------------------------------------------------------------------------------------------
// batak: a fanned hand with the ace of spades (trump) on top, gold-glowing.

void _batak(Canvas canvas, Color tint) {
  const pivot = Offset(50, 100);
  const radius = 50.0;
  final hand = <(double, String, int)>[(-24, 'K', 1), (-8, 'Q', 2), (8, '10', 3), (24, 'A', 0)];
  for (var i = 0; i < hand.length; i++) {
    final (a, rank, suit) = hand[i];
    final c = pivot + Offset(math.sin(_deg(a)), -math.cos(_deg(a))) * radius;
    final top = i == hand.length - 1;
    _card(canvas, c, 28, _deg(a), glow: top, content: (r) {
      if (top) {
        final col = CardKit.suitColor(0);
        _glyph(canvas, rank, Offset(r.left + r.width * 0.28, r.top + r.height * 0.2), 15, color: col);
        final pip = CardKit.suitPath(0, Offset(r.center.dx + 1.5, r.center.dy + 5), 19);
        canvas.drawPath(pip, Paint()..color = col);
        canvas.drawPath(pip, _outline(1.4)..shader = ArtKit.goldShader(pip.getBounds()));
      } else {
        _faceRankSuit(canvas, r, rank, suit, bigPip: false);
      }
    });
  }
}

// ---------------------------------------------------------------------------------------------
// okey: cream tiles with coloured numbers on a polished wooden rack.

void _okey(Canvas canvas, Color tint) {
  const inks = [Color(0xFFC4202F), Color(0xFF1B5CB6), Color(0xFF1E1D1B)];
  // Back panel of the rack behind the tiles.
  final back = RRect.fromLTRBR(14, 39, 86, 62, const Radius.circular(4));
  ArtKit.shadow(canvas, Path()..addRRect(back), blur: 2.5, offset: const Offset(0, 2.5), alpha: 0.45);
  canvas.drawRRect(
      back,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFA86A38), Color(0xFF6A3C18), Color(0xFF3E200C)],
        ).createShader(back.outerRect));
  canvas.drawRRect(back, _outline(0.9, const Color(0xFF2E1606)));
  for (var i = 0; i < 3; i++) {
    final r = Rect.fromLTWH(19 + i * 21, 27, 20, 31);
    final rr = RRect.fromRectAndRadius(r, const Radius.circular(3.5));
    ArtKit.shadow(canvas, Path()..addRRect(rr), blur: 2, offset: const Offset(0, 2), alpha: 0.5);
    canvas.drawRRect(
        rr,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFFFFBF0), Color(0xFFF3EAD5), Color(0xFFD9CBAA)],
            stops: [0, 0.5, 1],
          ).createShader(r));
    canvas.drawRRect(rr.deflate(0.5), _outline(1.0, const Color(0xFFB9A57E)));
    _glyph(canvas, '5', Offset(r.center.dx, r.top + 12), 21, color: inks[i], family: 'Jost', dy: 0.02);
    canvas.drawCircle(Offset(r.center.dx, r.top + 23.5), 2.6, _outline(1.4, inks[i]));
  }
  // Front ledge in polished walnut, with a highlight.
  final ledge = RRect.fromLTRBR(13, 56, 87, 70, const Radius.circular(4));
  ArtKit.shadow(canvas, Path()..addRRect(ledge), blur: 2.5, offset: const Offset(0, 2.5), alpha: 0.5);
  canvas.drawRRect(
      ledge,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFC88A4E), Color(0xFF8A5226), Color(0xFF4E2A10)],
          stops: [0, 0.45, 1],
        ).createShader(ledge.outerRect));
  canvas.drawLine(
      const Offset(17, 58.6),
      const Offset(83, 58.6),
      Paint()
        ..strokeWidth = 1.4
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withValues(alpha: 0.35));
  canvas.drawRRect(ledge, _outline(0.9, const Color(0xFF2E1606)));
  // Wood grain hints.
  final grain = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.9
    ..color = const Color(0x553A1C08);
  canvas.drawPath(
      Path()
        ..moveTo(22, 64)
        ..quadraticBezierTo(40, 61.5, 58, 64.5)
        ..quadraticBezierTo(70, 66.5, 80, 63.5),
      grain);
}

// ---------------------------------------------------------------------------------------------
// blof: two face-down cards behind a gold masquerade mask.

void _blof(Canvas canvas, Color tint) {
  _card(canvas, const Offset(40, 42), 29, _deg(-15), faceUp: false);
  _card(canvas, const Offset(60, 42), 29, _deg(13), faceUp: false);
  final mask = Path()
    ..moveTo(15, 55)
    ..cubicTo(24, 50, 38, 51, 50, 58)
    ..cubicTo(62, 51, 76, 50, 85, 55)
    ..cubicTo(84, 68, 74, 78, 63, 76)
    ..cubicTo(56, 75, 53, 71, 50, 69)
    ..cubicTo(47, 71, 44, 75, 37, 76)
    ..cubicTo(26, 78, 16, 68, 15, 55)
    ..close();
  final eyeL = Path()
    ..moveTo(28, 64)
    ..quadraticBezierTo(36, 57.5, 44, 64)
    ..quadraticBezierTo(36, 69, 28, 64)
    ..close();
  final eyeR = Path()
    ..moveTo(56, 64)
    ..quadraticBezierTo(64, 57.5, 72, 64)
    ..quadraticBezierTo(64, 69, 56, 64)
    ..close();
  final cut = Path.combine(PathOperation.difference, mask, Path.combine(PathOperation.union, eyeL, eyeR));
  ArtKit.shadow(canvas, cut, blur: 3, offset: const Offset(0, 3), alpha: 0.55);
  canvas.drawPath(cut, _goldFill(const Rect.fromLTRB(15, 50, 85, 78)));
  canvas.drawPath(cut, _outline(1.2, const Color(0xFF4A3410)));
  // Raised eyebrow over the right eye, level brow over the left.
  final brow = Path()
    ..moveTo(57, 50)
    ..quadraticBezierTo(65, 39.5, 74, 47);
  canvas.drawPath(
      brow.shift(const Offset(0, 1.4)), _outline(3.6, const Color(0x99000000))..strokeCap = StrokeCap.round);
  ArtKit.goldStroke(canvas, brow, 3.2);
  ArtKit.gem(canvas, const Offset(50, 63), 3.6, ArtKit.ruby, sides: 8);
}

// ---------------------------------------------------------------------------------------------
// blackjack: an ace and a king (21) with a ruby casino chip.

void _blackjack(Canvas canvas, Color tint) {
  _card(canvas, const Offset(40, 45), 32, _deg(-12), content: (r) => _faceRankSuit(canvas, r, 'A', 0));
  _card(canvas, const Offset(60, 47), 32, _deg(10), content: (r) => _faceRankSuit(canvas, r, 'K', 1));
  // Chip.
  const c = Offset(68, 70);
  const cr = 12.5;
  ArtKit.shadow(canvas, Path()..addOval(Rect.fromCircle(center: c, radius: cr)),
      blur: 2.5, offset: const Offset(0, 2.5));
  canvas.drawCircle(
      c,
      cr,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.3, -0.4),
          colors: [Color(0xFFE2546A), Color(0xFFA81F35), Color(0xFF5E0E1C)],
          stops: [0, 0.55, 1],
        ).createShader(Rect.fromCircle(center: c, radius: cr)));
  final stripe = Paint()..color = const Color(0xFFFFF4DE);
  for (var k = 0; k < 6; k++) {
    _rotated(canvas, c, k * math.pi / 3 + math.pi / 6, () {
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromCenter(center: c + const Offset(0, -cr + 2.6), width: 4.4, height: 5), const Radius.circular(1)),
          stripe);
    });
  }
  canvas.drawCircle(c, cr * 0.6, _outline(1.4)..shader = ArtKit.goldShader(Rect.fromCircle(center: c, radius: cr)));
  _glyph(canvas, '21', c, 10.5, color: ArtKit.goldLight, dy: 0.03);
}
