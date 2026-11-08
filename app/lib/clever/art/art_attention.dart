import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'game_art.dart';

/// Medallion illustrations for: schulte stroop tracking gonogo color_gates task_switch trail rsvp change_spot.
final Map<String, GameArtPainter> attentionArt = {
  'schulte': _schulte,
  'stroop': _stroop,
  'tracking': _tracking,
  'gonogo': _gonogo,
  'color_gates': _colorGates,
  'task_switch': _taskSwitch,
  'trail': _trail,
  'rsvp': _rsvp,
  'change_spot': _changeSpot,
};

// ------------------------------------------------------------------ shared bits

const _velvet = Color(0xFF0B2A21);
const _onyx = Color(0xFF15100A);
const _moonstone = Color(0xFF7FA9C8);
const _burgundy = Color(0xFF8B1E3F);

/// Cormorant numerals/letters centred at [o], with lining figures (oldstyle "1" reads as "I" when tiny).
void _numeral(Canvas c, String s, Offset o, double size, Color color) {
  final tp = TextPainter(
    text: TextSpan(
      text: s,
      style: TextStyle(
        fontFamily: 'Cormorant',
        fontSize: size,
        fontWeight: FontWeight.w700,
        color: color,
        height: 1.0,
        fontFeatures: const [FontFeature.liningFigures()],
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(c, o - Offset(tp.width / 2, tp.height / 2));
}

/// A dark velvet panel with a gold-leaf frame (boards, plaques, picture frames).
void _panel(Canvas c, Rect r, double k, {Color fill = _velvet, double radius = 0.14, double frame = 2.2}) {
  final rr = RRect.fromRectAndRadius(r, Radius.circular(r.shortestSide * radius));
  ArtKit.shadow(c, Path()..addRRect(rr), blur: 2.5 * k, offset: Offset(0, 2.2 * k), alpha: 0.5);
  c.drawRRect(
    rr,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color.lerp(fill, Colors.white, 0.10)!, fill, Color.lerp(fill, Colors.black, 0.5)!],
        stops: const [0, 0.45, 1],
      ).createShader(r),
  );
  c.drawRRect(
    rr.deflate(frame * k * 0.5),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = frame * k
      ..shader = ArtKit.goldShader(r),
  );
}

/// A gold-leaf ring with a dark under-stroke so it lifts off any ground.
void _goldRing(Canvas c, Offset o, double r, double w) {
  c.drawCircle(
      o,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 1.7
        ..color = Colors.black.withValues(alpha: 0.35));
  c.drawCircle(
      o,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..shader = ArtKit.goldShader(Rect.fromCircle(center: o, radius: r + w)));
}

/// A soft radial glow (cheap: a gradient, no blur).
void _glow(Canvas c, Offset o, double r, Color color, {double alpha = 0.7}) {
  c.drawCircle(
    o,
    r,
    Paint()
      ..shader = RadialGradient(
        colors: [color.withValues(alpha: alpha), color.withValues(alpha: 0)],
      ).createShader(Rect.fromCircle(center: o, radius: r)),
  );
}

/// A gold line with a dark under-stroke.
void _goldLine(Canvas c, Path p, double w) {
  c.drawPath(
    p.shift(Offset(0, w * 0.35)),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = Colors.black.withValues(alpha: 0.4),
  );
  ArtKit.goldStroke(c, p, w);
}

/// A solid arrow from [from] to [to]: shaft width [shaft], head half-width [head].
Path _arrow(Offset from, Offset to, double shaft, double head) {
  final d = to - from;
  final dir = d / d.distance;
  final n = Offset(-dir.dy, dir.dx);
  final hb = to - dir * (head * 1.25);
  final s = shaft / 2;
  return Path()
    ..addPolygon([
      from + n * s,
      hb + n * s,
      hb + n * head,
      to,
      hb - n * head,
      hb - n * s,
      from - n * s,
    ], true);
}

/// Fills [p] with a lit gradient of [color] and a darker edge.
void _jewelFill(Canvas c, Path p, Color color, double k) {
  final b = p.getBounds();
  c.drawPath(
    p,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color.lerp(color, Colors.white, 0.4)!, color, Color.lerp(color, Colors.black, 0.4)!],
      ).createShader(b),
  );
  c.drawPath(
    p,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9 * k
      ..strokeJoin = StrokeJoin.round
      ..color = Color.lerp(color, Colors.black, 0.6)!.withValues(alpha: 0.8),
  );
}

// ------------------------------------------------------------------ schulte

/// A gilt 3×3 board of velvet tiles with scattered gold numerals; the "1" tile already found (gold).
void _schulte(Canvas c, Size s, Color tint) {
  final k = s.width / 100;
  const nums = ['7', '2', '9', '4', '1', '6', '8', '3', '5'];
  const side = 58.0, gap = 2.4;
  const t = (side - gap * 2) / 3;
  const x0 = 50 - side / 2, y0 = 50 - side / 2;
  _panel(c, Rect.fromLTWH((x0 - 3) * k, (y0 - 3) * k, (side + 6) * k, (side + 6) * k), k, radius: 0.1, frame: 2.0);
  for (var i = 0; i < 9; i++) {
    final r = Rect.fromLTWH((x0 + (i % 3) * (t + gap)) * k, (y0 + (i ~/ 3) * (t + gap)) * k, t * k, t * k);
    final found = nums[i] == '1';
    ArtKit.tile(c, r, found ? ArtKit.gold : const Color(0xFF184A38), radius: 0.16, shadowed: false);
    _numeral(c, nums[i], r.center + Offset(0, 0.4 * k), 16 * k, found ? ArtKit.ink : ArtKit.goldLight);
  }
}

// ------------------------------------------------------------------ stroop

/// An onyx plaque with "MAVİ" in ruby ink; below, three swatches with the ruby one ringed gold.
void _stroop(Canvas c, Size s, Color tint) {
  final k = s.width / 100;
  final plaque = Rect.fromLTWH(14 * k, 24 * k, 72 * k, 38 * k);
  _panel(c, plaque, k, fill: _onyx, radius: 0.2);
  ArtKit.text(c, 'MAVİ', plaque.center + Offset(0, 0.8 * k), 23 * k,
      color: const Color(0xFFF2434D), family: 'Jost', weight: FontWeight.w700);
  const swatches = [Color(0xFFE5484D), Color(0xFF3F8CFF), Color(0xFFFFC53D)];
  for (var i = 0; i < 3; i++) {
    final o = Offset((34 + i * 16) * k, 75 * k);
    ArtKit.ball(c, o, 5.6 * k, swatches[i]);
    if (i == 0) _goldRing(c, o, 8.2 * k, 1.8 * k);
  }
}

// ------------------------------------------------------------------ tracking

/// Moonstone orbs streaking across the arena; two targets ringed and glowing gold.
void _tracking(Canvas c, Size s, Color tint) {
  final k = s.width / 100;
  // (x, y, direction of motion in radians, target)
  const orbs = [
    (33.0, 36.0, 0.5, true),
    (63.0, 31.0, 2.6, false),
    (67.0, 62.0, -2.2, true),
    (36.0, 66.0, -0.4, false),
    (53.0, 48.0, 0.15, false),
  ];
  // Velvet arena with a gilt edge.
  final ctr = Offset(50 * k, 50 * k);
  final arena = Rect.fromCircle(center: ctr, radius: 38.5 * k);
  ArtKit.shadow(c, Path()..addOval(arena), blur: 2.5 * k, offset: Offset(0, 2 * k), alpha: 0.5);
  c.drawOval(
    arena,
    Paint()
      ..shader = const RadialGradient(
        center: Alignment(-0.2, -0.3),
        colors: [Color(0xFF1C3550), Color(0xFF0C1828)],
      ).createShader(arena),
  );
  _goldRing(c, ctr, 37.5 * k, 2.0 * k);
  const r = 8.8;
  c.save();
  c.clipPath(Path()..addOval(arena.deflate(2.5 * k)));
  for (final (x, y, a, target) in orbs) {
    final o = Offset(x * k, y * k);
    final dir = Offset.fromDirection(a + math.pi, 1);
    final tone = target ? ArtKit.gold : const Color(0xFFA9CDE6);
    final back = o + dir * (26 * k);
    final n = Offset.fromDirection(a + math.pi / 2, r * 0.8 * k);
    c.drawPath(
      Path()..addPolygon([o + n, back, o - n], true),
      Paint()..shader = ui.Gradient.linear(o, back, [tone.withValues(alpha: 0.55), tone.withValues(alpha: 0)]),
    );
    for (final (d, sc, al) in [(2.1, 0.62, 0.22), (1.25, 0.8, 0.42)]) {
      c.drawCircle(o + dir * (d * r * k), r * sc * k, Paint()..color = tone.withValues(alpha: al));
    }
  }
  c.restore();
  for (final (x, y, _, target) in orbs) {
    final o = Offset(x * k, y * k);
    if (target) _glow(c, o, r * 2.0 * k, ArtKit.goldLight, alpha: 0.6);
    ArtKit.ball(c, o, r * k, target ? const Color(0xFFE2B85A) : _moonstone);
    if (target) _goldRing(c, o, (r + 2.4) * k, 1.8 * k);
  }
}

// ------------------------------------------------------------------ gonogo

/// A pearl disc bearing an emerald arrow (go) beside a pearl square with a burgundy cross (stop).
void _gonogo(Canvas c, Size s, Color tint) {
  final k = s.width / 100;
  const pearl = Color(0xFFEDE6D2);
  // Round = go.
  final co = Offset(31 * k, 50 * k);
  ArtKit.ball(c, co, 17 * k, pearl);
  final arrow = _arrow(Offset(21 * k, 50 * k), Offset(43 * k, 50 * k), 5.6 * k, 7.6 * k);
  _jewelFill(c, arrow, ArtKit.emerald, k);
  // Square = never.
  final sq = Rect.fromCenter(center: Offset(69.5 * k, 50 * k), width: 30 * k, height: 30 * k);
  ArtKit.tile(c, sq, pearl, radius: 0.16);
  final cx = sq.center;
  for (final d in [Offset(8 * k, 8 * k), Offset(8 * k, -8 * k)]) {
    c.drawLine(
        cx - d + Offset(0, 0.8 * k),
        cx + d + Offset(0, 0.8 * k),
        Paint()
          ..strokeWidth = 5.6 * k
          ..strokeCap = StrokeCap.round
          ..color = Colors.black.withValues(alpha: 0.25));
    c.drawLine(
        cx - d,
        cx + d,
        Paint()
          ..strokeWidth = 5.2 * k
          ..strokeCap = StrokeCap.round
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFC8466A), _burgundy, Color(0xFF5A0F26)],
          ).createShader(sq));
  }
}

// ------------------------------------------------------------------ color gates

/// Three gold-inlaid glass rods; jewel discs slide down into coloured gate rings.
void _colorGates(Canvas c, Size s, Color tint) {
  final k = s.width / 100;
  const lanes = [30.0, 50.0, 70.0];
  const gems = [Color(0xFFE5484D), Color(0xFF3E9BFF), Color(0xFFFFC53D)];
  const discY = [44.0, 26.0, 52.0];
  const gateY = 70.0;
  for (var i = 0; i < 3; i++) {
    final x = lanes[i] * k;
    final rod = Rect.fromLTRB(x - 2.6 * k, 12 * k, x + 2.6 * k, 88 * k);
    c.drawRRect(
      RRect.fromRectAndRadius(rod, Radius.circular(2.6 * k)),
      Paint()
        ..shader = LinearGradient(colors: [
          Colors.white.withValues(alpha: 0.35),
          Colors.white.withValues(alpha: 0.08),
          Colors.black.withValues(alpha: 0.25),
        ]).createShader(rod),
    );
    c.drawLine(
        Offset(x, 12 * k),
        Offset(x, 88 * k),
        Paint()
          ..strokeWidth = 1.2 * k
          ..shader = ArtKit.goldShader(rod));
  }
  // Gate bands: wide jewelled rings across each rod.
  for (var i = 0; i < 3; i++) {
    final r = Rect.fromCenter(center: Offset(lanes[i] * k, gateY * k), width: 16 * k, height: 7 * k);
    ArtKit.tile(c, r, gems[(i + 1) % 3], radius: 0.5);
    c.drawRRect(
        RRect.fromRectAndRadius(r, Radius.circular(3.5 * k)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3 * k
          ..shader = ArtKit.goldShader(r));
  }
  // Falling discs with speed trails.
  for (var i = 0; i < 3; i++) {
    final o = Offset(lanes[i] * k, discY[i] * k);
    final top = o - Offset(0, 16 * k);
    c.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTRB(o.dx - 5 * k, top.dy, o.dx + 5 * k, o.dy), Radius.circular(5 * k)),
      Paint()..shader = ui.Gradient.linear(top, o, [gems[i].withValues(alpha: 0), gems[i].withValues(alpha: 0.55)]),
    );
    ArtKit.gem(c, o, 7.6 * k, gems[i], sides: 8);
  }
}

// ------------------------------------------------------------------ task switch

/// A card split on the diagonal: a gold digit half and an amethyst letter half, with a gold swap arc.
void _taskSwitch(Canvas c, Size s, Color tint) {
  final k = s.width / 100;
  final card = Rect.fromLTWH(22 * k, 20 * k, 56 * k, 48 * k);
  final rr = RRect.fromRectAndRadius(card, Radius.circular(8 * k));
  ArtKit.shadow(c, Path()..addRRect(rr), blur: 2.5 * k, offset: Offset(0, 2.2 * k), alpha: 0.5);
  c.save();
  c.clipRRect(rr);
  final a = Path()
    ..moveTo(card.left, card.top)
    ..lineTo(card.right, card.top)
    ..lineTo(card.left, card.bottom)
    ..close();
  final b = Path()
    ..moveTo(card.right, card.top)
    ..lineTo(card.right, card.bottom)
    ..lineTo(card.left, card.bottom)
    ..close();
  _jewelFill(c, a, ArtKit.gold, k);
  _jewelFill(c, b, ArtKit.amethyst, k);
  c.restore();
  ArtKit.goldStroke(
      c,
      Path()
        ..moveTo(card.right, card.top)
        ..lineTo(card.left, card.bottom),
      1.8 * k);
  c.drawRRect(
      rr.deflate(1.0 * k),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0 * k
        ..shader = ArtKit.goldShader(card));
  _numeral(c, '7', Offset(36 * k, 35 * k), 22 * k, ArtKit.ink);
  ArtKit.text(c, 'A', Offset(64 * k, 54 * k), 21 * k, color: ArtKit.ivory);
  // Swap arc under the card, arrowheads at both ends.
  final arc = Path()
    ..moveTo(30 * k, 74 * k)
    ..quadraticBezierTo(50 * k, 88 * k, 70 * k, 74 * k);
  _goldLine(c, arc, 3.4 * k);
  for (final (tip, dir) in [(Offset(28 * k, 71 * k), -2.2), (Offset(72 * k, 71 * k), -0.94)]) {
    final head = _arrow(tip - Offset.fromDirection(dir, 8 * k), tip, 0.1, 5.2 * k);
    c.drawPath(head, Paint()..shader = ArtKit.goldShader(head.getBounds()));
  }
}

// ------------------------------------------------------------------ trail

/// Ivory nodes 1 · A · 2 · B, gold-rimmed, woven together by a gold line.
void _trail(Canvas c, Size s, Color tint) {
  final k = s.width / 100;
  const nodes = [('1', 30.0, 34.0), ('A', 66.0, 30.0), ('2', 34.0, 66.0), ('B', 69.0, 66.0)];
  final line = Path()..moveTo(nodes[0].$2 * k, nodes[0].$3 * k);
  for (final n in nodes.skip(1)) {
    line.lineTo(n.$2 * k, n.$3 * k);
  }
  _goldLine(c, line, 3.4 * k);
  const r = 11.5;
  for (final (label, x, y) in nodes) {
    final o = Offset(x * k, y * k);
    ArtKit.ball(c, o, r * k, ArtKit.ivory);
    _goldRing(c, o, (r - 0.9) * k, 1.9 * k);
    final letter = label.codeUnitAt(0) > 64;
    _numeral(c, label, o + Offset(0, 0.4 * k), 17 * k, letter ? _burgundy : ArtKit.ink);
  }
}

// ------------------------------------------------------------------ rsvp

/// A stream of letter cards rushing in from the left, smaller with distance; the front card is
/// the target, lit gold.
void _rsvp(Canvas c, Size s, Color tint) {
  final k = s.width / 100;
  // Speed streaks behind the stream.
  for (final (y, x0, x1) in [(38.0, 14.0, 40.0), (62.0, 18.0, 44.0)]) {
    c.drawLine(
      Offset(x0 * k, y * k),
      Offset(x1 * k, y * k),
      Paint()
        ..strokeWidth = 2.2 * k
        ..strokeCap = StrokeCap.round
        ..shader = ui.Gradient.linear(Offset(x0 * k, 0), Offset(x1 * k, 0),
            [ArtKit.goldLight.withValues(alpha: 0), ArtKit.goldLight.withValues(alpha: 0.7)]),
    );
  }
  // (centre x, width, letter, opacity), back to front.
  const cards = [
    (23.0, 12.0, 'R', 0.6),
    (33.5, 16.0, 'T', 0.8),
    (46.0, 20.0, 'K', 0.95),
  ];
  for (final (x, w, l, op) in cards) {
    final r = Rect.fromCenter(center: Offset(x * k, 50 * k), width: w * k, height: w * 1.32 * k);
    c.saveLayer(r.inflate(4 * k), Paint()..color = Colors.white.withValues(alpha: op));
    ArtKit.tile(c, r, ArtKit.ivory, radius: 0.16);
    ArtKit.text(c, l, Offset(r.left + w * 0.36 * k, r.center.dy + 0.5 * k), w * 0.72 * k,
        color: ArtKit.ink, family: 'Jost', weight: FontWeight.w600);
    c.restore();
  }
  final front = Rect.fromCenter(center: Offset(65 * k, 50 * k), width: 27 * k, height: 35 * k);
  _glow(c, front.center, 27 * k, ArtKit.goldLight, alpha: 0.55);
  ArtKit.tile(c, front, ArtKit.gold, radius: 0.16);
  c.drawRRect(
      RRect.fromRectAndRadius(front.deflate(2.2 * k), Radius.circular(3 * k)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0 * k
        ..color = ArtKit.goldDeep.withValues(alpha: 0.8));
  ArtKit.text(c, 'X', front.center + Offset(0, 0.6 * k), 24 * k,
      color: ArtKit.ink, family: 'Jost', weight: FontWeight.w600);
}

// ------------------------------------------------------------------ change spot

/// Two framed little scenes side by side; the one difference circled in gold.
void _changeSpot(Canvas c, Size s, Color tint) {
  final k = s.width / 100;
  final frames = [Rect.fromLTWH(19 * k, 27 * k, 29 * k, 46 * k), Rect.fromLTWH(52 * k, 27 * k, 29 * k, 46 * k)];
  for (var i = 0; i < 2; i++) {
    final f = frames[i];
    _panel(c, f, k, radius: 0.16, frame: 1.8);
    final top = Offset(f.center.dx, f.top + f.height * 0.3);
    final bottom = Rect.fromCenter(center: Offset(f.center.dx, f.top + f.height * 0.72), width: 12 * k, height: 12 * k);
    ArtKit.ball(c, top, 6.4 * k, i == 0 ? ArtKit.topaz : ArtKit.ruby);
    ArtKit.tile(c, bottom, ArtKit.sapphire, radius: 0.18);
    if (i == 1) _goldRing(c, top, 9.4 * k, 1.9 * k);
  }
}
