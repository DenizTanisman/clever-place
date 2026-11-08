import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'game_art.dart';

/// Medallion illustrations for: sudoku crowns sun_moon shikaku water_sort hanoi falling_blocks block_grid gem_merge math soroban corridor push morris surakarta cube.
///
/// Every painter draws in a 100 × 100 unit box (centre 50, 50); [_scaled] maps it onto the disc.
/// Important content stays within ~38 units of the centre, clear of the darkened rim.
final Map<String, GameArtPainter> logicArt = {
  'sudoku': _scaled(_sudoku),
  'crowns': _scaled(_crowns),
  'sun_moon': _scaled(_sunMoon),
  'shikaku': _scaled(_shikaku),
  'water_sort': _scaled(_waterSort),
  'hanoi': _scaled(_hanoi),
  'falling_blocks': _scaled(_fallingBlocks),
  'block_grid': _scaled(_blockGrid),
  'gem_merge': _scaled(_gemMerge),
  'math': _scaled(_math),
  'soroban': _scaled(_soroban),
  'corridor': _scaled(_corridor),
  'push': _scaled(_push),
  'morris': _scaled(_morris),
  'surakarta': _scaled(_surakarta),
  'cube': _scaled(_cube),
};

GameArtPainter _scaled(void Function(Canvas canvas, Color tint) draw) => (canvas, size, tint) {
      canvas.save();
      canvas.scale(size.width / 100, size.height / 100);
      draw(canvas, tint);
      canvas.restore();
    };

// ---------------------------------------------------------------------------------------------
// Private materials shared by this set.

const _onyx = Color(0xFF26242C);
const _ebony = Color(0xFF1B140D);
const _walnut = Color(0xFF4A2C15);
const _navy = Color(0xFF1B2552);
const _garnet = Color(0xFFA51D40);
const _rosewood = Color(0xFFC98250);

/// A dark lacquer plate with a gold-leaf rim: the board every grid game sits on.
void _plate(Canvas c, Rect r, {double radius = 7, Color color = _ebony, double rim = 2.2}) {
  final rr = RRect.fromRectAndRadius(r, Radius.circular(radius));
  final path = Path()..addRRect(rr);
  ArtKit.shadow(c, path, blur: 3, offset: const Offset(0, 3), alpha: 0.55);
  c.drawRRect(
    rr,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color.lerp(color, Colors.white, 0.14)!, color, Color.lerp(color, Colors.black, 0.45)!],
      ).createShader(r),
  );
  ArtKit.goldStroke(c, path, rim);
}

/// Cells of an n × n grid laid inside [r] with [pad] margin and [gap] between cells.
Rect _cell(Rect r, int n, int col, int row, {double pad = 2.6, double gap = 2}) {
  final s = (r.width - pad * 2 - gap * (n - 1)) / n;
  return Rect.fromLTWH(r.left + pad + col * (s + gap), r.top + pad + row * (s + gap), s, s);
}

/// Spans cells (c0,r0)…(c1,r1) inclusive as one rectangle.
Rect _span(Rect r, int n, int c0, int r0, int c1, int r1, {double pad = 2.6, double gap = 2}) =>
    _cell(r, n, c0, r0, pad: pad, gap: gap).expandToInclude(_cell(r, n, c1, r1, pad: pad, gap: gap));

/// Display text (Cormorant bold, lining figures) filled with a vertical gradient, with a soft drop.
void _richText(Canvas c, String s, Offset center, double size,
    {List<Color> colors = const [ArtKit.goldLight, ArtKit.gold, ArtKit.goldDeep], double dropAlpha = 0.5}) {
  TextPainter painter(Color color) => TextPainter(
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
  final tp = painter(Colors.white);
  // Lining figures sit high in the line box: nudge down so the glyph is optically centred.
  final o = center - Offset(tp.width / 2, tp.height / 2 - size * 0.04);
  if (dropAlpha > 0) painter(Colors.black.withValues(alpha: dropAlpha)).paint(c, o + Offset(0, size * 0.06));
  final bounds = (o & tp.size).inflate(2);
  c.saveLayer(bounds, Paint());
  tp.paint(c, o);
  c.drawRect(
    bounds,
    Paint()
      ..blendMode = BlendMode.srcIn
      ..shader =
          LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: colors).createShader(bounds),
  );
  c.restore();
}

const _inkDigits = [Color(0xFF6E4A10), Color(0xFF4A2F06)];
const _ivoryDigits = [Colors.white, ArtKit.ivory, Color(0xFFE8D9B5)];

/// A four-point sparkle in pale gold.
void _sparkle(Canvas c, Offset p, double r) {
  final path = Path()
    ..moveTo(p.dx, p.dy - r)
    ..quadraticBezierTo(p.dx, p.dy, p.dx + r, p.dy)
    ..quadraticBezierTo(p.dx, p.dy, p.dx, p.dy + r)
    ..quadraticBezierTo(p.dx, p.dy, p.dx - r, p.dy)
    ..quadraticBezierTo(p.dx, p.dy, p.dx, p.dy - r)
    ..close();
  c.drawPath(path, Paint()..color = ArtKit.goldLight);
}

/// A horizontal pill with cylinder shading (hanoi disks, gold bars).
void _pill(Canvas c, Rect r, Color color, {bool shadowed = true}) {
  final rr = RRect.fromRectAndRadius(r, Radius.circular(r.height / 2));
  if (shadowed) ArtKit.shadow(c, Path()..addRRect(rr), blur: 1.6, offset: const Offset(0, 1.6), alpha: 0.5);
  c.drawRRect(
    rr,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color.lerp(color, Colors.white, 0.5)!, color, Color.lerp(color, Colors.black, 0.55)!],
        stops: const [0, 0.42, 1],
      ).createShader(r),
  );
  c.drawRRect(
    RRect.fromRectAndRadius(
        Rect.fromLTWH(r.left + r.height * 0.5, r.top + r.height * 0.16, r.width - r.height, r.height * 0.22),
        Radius.circular(r.height * 0.11)),
    Paint()..color = Colors.white.withValues(alpha: 0.45),
  );
}

/// A gold-leaf filled path with a deep-gold edge.
void _goldFill(Canvas c, Path path, {double edge = 1.0, bool shadowed = true}) {
  if (shadowed) ArtKit.shadow(c, path, blur: 2, offset: const Offset(0, 2), alpha: 0.5);
  c.drawPath(path, Paint()..shader = ArtKit.goldShader(path.getBounds()));
  if (edge > 0) {
    c.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = edge
        ..strokeJoin = StrokeJoin.round
        ..color = ArtKit.goldDeep,
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Grid puzzles.

void _sudoku(Canvas c, Color tint) {
  const board = Rect.fromLTWH(21, 21, 58, 58);
  _plate(c, board);
  const digits = {(0, 0): '5', (2, 0): '3', (1, 1): '9', (0, 2): '8', (2, 2): '1'};
  for (var row = 0; row < 3; row++) {
    for (var col = 0; col < 3; col++) {
      final r = _cell(board, 3, col, row);
      final selected = col == 1 && row == 1;
      ArtKit.tile(c, r, selected ? ArtKit.gold : ArtKit.ivory, radius: 0.16, shadowed: false);
      final d = digits[(col, row)];
      if (d != null) _richText(c, d, r.center, 18, colors: _inkDigits, dropAlpha: 0);
    }
  }
}

/// A gold crown centred at [p], [w] wide.
void _crown(Canvas c, Offset p, double w) {
  final x = p.dx, y = p.dy;
  final body = Path()
    ..moveTo(x - 0.46 * w, y + 0.2 * w)
    ..lineTo(x - 0.5 * w, y - 0.22 * w)
    ..lineTo(x - 0.22 * w, y + 0.02 * w)
    ..lineTo(x, y - 0.34 * w)
    ..lineTo(x + 0.22 * w, y + 0.02 * w)
    ..lineTo(x + 0.5 * w, y - 0.22 * w)
    ..lineTo(x + 0.46 * w, y + 0.2 * w)
    ..close();
  final band = Path()
    ..addRRect(RRect.fromRectAndRadius(
        Rect.fromLTRB(x - 0.47 * w, y + 0.14 * w, x + 0.47 * w, y + 0.32 * w), Radius.circular(0.04 * w)));
  final all = Path.combine(PathOperation.union, body, band);
  _goldFill(c, all, edge: w * 0.03);
  for (final t in [Offset(x - 0.5 * w, y - 0.25 * w), Offset(x, y - 0.38 * w), Offset(x + 0.5 * w, y - 0.25 * w)]) {
    ArtKit.ball(c, t, w * 0.075, ArtKit.goldLight, shadowed: false);
  }
  ArtKit.ball(c, Offset(x, y + 0.23 * w), w * 0.065, ArtKit.ruby, shadowed: false);
  ArtKit.ball(c, Offset(x - 0.27 * w, y + 0.23 * w), w * 0.05, ArtKit.emerald, shadowed: false);
  ArtKit.ball(c, Offset(x + 0.27 * w, y + 0.23 * w), w * 0.05, ArtKit.sapphire, shadowed: false);
}

void _crowns(Canvas c, Color tint) {
  const board = Rect.fromLTWH(21, 21, 58, 58);
  _plate(c, board);
  const regions = [
    [ArtKit.emerald, ArtKit.emerald, ArtKit.sapphire],
    [ArtKit.ruby, ArtKit.emerald, ArtKit.sapphire],
    [ArtKit.ruby, ArtKit.ruby, ArtKit.sapphire],
  ];
  for (var row = 0; row < 3; row++) {
    for (var col = 0; col < 3; col++) {
      ArtKit.tile(c, _cell(board, 3, col, row), regions[row][col], radius: 0.16, shadowed: false);
    }
  }
  _crown(c, const Offset(50, 53), 40);
}

void _sun(Canvas c, Offset p, double r) {
  final rays = Path();
  for (var i = 0; i < 8; i++) {
    final a = i * math.pi / 4;
    rays.addPolygon([
      p + Offset.fromDirection(a - 0.32, r * 0.62),
      p + Offset.fromDirection(a, r),
      p + Offset.fromDirection(a + 0.32, r * 0.62),
    ], true);
  }
  _goldFill(c, rays, edge: 0, shadowed: false);
  final disc = Path()..addOval(Rect.fromCircle(center: p, radius: r * 0.56));
  _goldFill(c, disc, edge: 0.8, shadowed: false);
  c.drawCircle(p + Offset(-r * 0.18, -r * 0.2), r * 0.16, Paint()..color = Colors.white.withValues(alpha: 0.55));
}

void _moon(Canvas c, Offset p, double r) {
  final outer = Path()..addOval(Rect.fromCircle(center: p, radius: r));
  final bite = Path()..addOval(Rect.fromCircle(center: p + Offset(r * 0.5, -r * 0.32), radius: r * 0.8));
  final crescent = Path.combine(PathOperation.difference, outer, bite);
  final b = crescent.getBounds();
  c.drawPath(
    crescent,
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Colors.white, Color(0xFFD9DEE8), Color(0xFF8D97AC)],
      ).createShader(b),
  );
  c.drawPath(
    crescent,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = const Color(0xFF5C6680),
  );
}

void _sunMoon(Canvas c, Color tint) {
  const board = Rect.fromLTWH(22, 22, 56, 56);
  _plate(c, board);
  for (var row = 0; row < 2; row++) {
    for (var col = 0; col < 2; col++) {
      final r = _cell(board, 2, col, row, gap: 2.4);
      ArtKit.tile(c, r, _navy, radius: 0.16, shadowed: false);
      if ((row + col).isEven) {
        _sun(c, r.center, r.width * 0.42);
      } else {
        _moon(c, r.center + const Offset(-0.6, 0.6), r.width * 0.32);
      }
    }
  }
}

void _shikaku(Canvas c, Color tint) {
  const board = Rect.fromLTWH(21, 21, 58, 58);
  _plate(c, board);
  final parts = [
    (_span(board, 3, 0, 0, 1, 0), ArtKit.topaz, '2', _cell(board, 3, 1, 0)),
    (_span(board, 3, 2, 0, 2, 2), ArtKit.emerald, '3', _cell(board, 3, 2, 1)),
    (_span(board, 3, 0, 1, 1, 2), ArtKit.sapphire, '4', _cell(board, 3, 0, 2)),
  ];
  for (final (r, color, n, at) in parts) {
    ArtKit.tile(c, r, color, radius: 0.1, shadowed: false);
    // Faint cell seams inside each rectangle keep the grid readable.
    final seam = Paint()
      ..color = Colors.black.withValues(alpha: 0.22)
      ..strokeWidth = 1.2;
    final s = _cell(board, 3, 0, 0).width + 2;
    for (var x = r.left + s - 1; x < r.right - 2; x += s) {
      c.drawLine(Offset(x, r.top + 2), Offset(x, r.bottom - 2), seam);
    }
    for (var y = r.top + s - 1; y < r.bottom - 2; y += s) {
      c.drawLine(Offset(r.left + 2, y), Offset(r.right - 2, y), seam);
    }
    c.drawCircle(at.center, at.width * 0.44, Paint()..color = Colors.black.withValues(alpha: 0.3));
    _richText(c, n, at.center, 17.5, colors: _ivoryDigits, dropAlpha: 0.0);
  }
}

// ---------------------------------------------------------------------------------------------
// Sorting & stacking.

void _waterSort(Canvas c, Color tint) {
  const tubes = [
    [ArtKit.ruby, ArtKit.topaz, ArtKit.ruby, ArtKit.emerald],
    [ArtKit.emerald, ArtKit.emerald, ArtKit.amethyst],
    [ArtKit.topaz, ArtKit.amethyst, ArtKit.ruby, ArtKit.topaz],
  ];
  const w = 13.0, top = 25.0, bottom = 77.0, layer = 11.0;
  for (var i = 0; i < 3; i++) {
    final x = 31.0 + i * 19;
    final body = RRect.fromRectAndCorners(
      Rect.fromLTRB(x - w / 2, top, x + w / 2, bottom),
      bottomLeft: const Radius.circular(w / 2),
      bottomRight: const Radius.circular(w / 2),
    );
    final path = Path()..addRRect(body);
    ArtKit.shadow(c, path, blur: 2.2, offset: const Offset(0, 2.4), alpha: 0.5);
    // Glass interior.
    c.drawRRect(body, Paint()..color = const Color(0xFF0B2A30).withValues(alpha: 0.55));
    c.save();
    c.clipRRect(body.deflate(1.4));
    var y = bottom;
    for (final color in tubes[i]) {
      final band = Rect.fromLTRB(x - w / 2, y - layer, x + w / 2, y);
      c.drawRect(
        band,
        Paint()
          ..shader = LinearGradient(
            colors: [
              Color.lerp(color, Colors.black, 0.35)!,
              Color.lerp(color, Colors.white, 0.18)!,
              color,
              Color.lerp(color, Colors.black, 0.45)!
            ],
            stops: const [0, 0.3, 0.6, 1],
          ).createShader(band),
      );
      y -= layer;
    }
    // Meniscus on the top layer.
    c.drawRect(Rect.fromLTRB(x - w / 2, y, x + w / 2, y + 1.4), Paint()..color = Colors.white.withValues(alpha: 0.35));
    c.restore();
    // Glass rim and highlight.
    c.drawRRect(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = Colors.white.withValues(alpha: 0.7),
    );
    c.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(x - w / 2 + 2.4, top + 4, 2.2, bottom - top - 12), const Radius.circular(1.1)),
      Paint()..color = Colors.white.withValues(alpha: 0.55),
    );
    _pill(c, Rect.fromCenter(center: Offset(x, top), width: w + 3.6, height: 3.8), ArtKit.gold, shadowed: false);
  }
}

void _hanoi(Canvas c, Color tint) {
  // Polished walnut base with a gold top edge.
  const base = Rect.fromLTRB(17, 64, 83, 72);
  final baseRR = RRect.fromRectAndRadius(base, const Radius.circular(3));
  ArtKit.shadow(c, Path()..addRRect(baseRR), blur: 2.5, offset: const Offset(0, 2.5), alpha: 0.55);
  c.drawRRect(
    baseRR,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color.lerp(_walnut, Colors.white, 0.25)!, _walnut, Color.lerp(_walnut, Colors.black, 0.5)!],
      ).createShader(base),
  );
  final grain = Paint()
    ..color = Colors.black.withValues(alpha: 0.25)
    ..strokeWidth = 0.7
    ..style = PaintingStyle.stroke;
  c.drawLine(const Offset(22, 68.5), const Offset(46, 68), grain);
  c.drawLine(const Offset(54, 69.5), const Offset(78, 69), grain);
  c.drawRect(const Rect.fromLTRB(18, 64, 82, 65.2), Paint()..shader = ArtKit.goldShader(base));
  // Gold pegs.
  for (final x in [24.0, 50.0, 76.0]) {
    final peg = Rect.fromLTRB(x - 1.9, 30, x + 1.9, 64.5);
    c.drawRRect(
      RRect.fromRectAndRadius(peg, const Radius.circular(1.9)),
      Paint()
        ..shader = const LinearGradient(colors: [ArtKit.goldDeep, ArtKit.goldLight, ArtKit.gold, ArtKit.goldDeep])
            .createShader(peg),
    );
    ArtKit.ball(c, Offset(x, 30), 2.6, ArtKit.gold, shadowed: false);
  }
  // Stack on the middle peg, the smallest disk already moved to the right.
  const h = 8.0;
  final disks = [(50.0, 38.0, ArtKit.ruby), (50.0, 29.0, ArtKit.sapphire), (50.0, 20.0, ArtKit.emerald)];
  var y = 64.0;
  for (final (x, w, color) in disks) {
    _pill(c, Rect.fromLTWH(x - w / 2, y - h, w, h), color);
    y -= h;
  }
  _pill(c, const Rect.fromLTWH(76 - 6.5, 64 - h, 13, h), ArtKit.amethyst);
}

// ---------------------------------------------------------------------------------------------
// Block puzzles.

void _fallingBlocks(Canvas c, Color tint) {
  const cell = 10.4, x0 = 24.0, y0 = 24.0;
  Rect at(int col, int row) => Rect.fromLTWH(x0 + col * cell + 0.5, y0 + row * cell + 0.5, cell - 1, cell - 1);
  const well = Rect.fromLTRB(x0 - 1, y0 - 3, x0 + 5 * cell + 1, y0 + 5 * cell + 1);
  final wellRR =
      RRect.fromRectAndCorners(well, bottomLeft: const Radius.circular(3), bottomRight: const Radius.circular(3));
  ArtKit.shadow(c, Path()..addRRect(wellRR), blur: 3, offset: const Offset(0, 3), alpha: 0.5);
  c.drawRRect(
    wellRR,
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF241A10), Color(0xFF120C06)],
      ).createShader(well),
  );
  // The stack with a T-shaped hole.
  const stack = [
    (0, 4, ArtKit.sapphire),
    (1, 4, ArtKit.emerald),
    (3, 4, ArtKit.ruby),
    (4, 4, ArtKit.sapphire),
    (0, 3, ArtKit.ruby),
    (4, 3, ArtKit.emerald),
  ];
  for (final (col, row, color) in stack) {
    ArtKit.tile(c, at(col, row), color, radius: 0.16, shadowed: false);
  }
  // Falling T with motion trails.
  final trail = Paint()
    ..strokeWidth = 1.4
    ..strokeCap = StrokeCap.round
    ..color = ArtKit.goldLight.withValues(alpha: 0.35);
  c.drawLine(Offset(at(1, 0).center.dx, y0 - 2), Offset(at(1, 0).center.dx, y0 + 0.5), trail);
  c.drawLine(Offset(at(3, 0).center.dx, y0 - 2), Offset(at(3, 0).center.dx, y0 + 0.5), trail);
  for (final (col, row) in [(1, 0), (2, 0), (3, 0), (2, 1)]) {
    ArtKit.tile(c, at(col, row).shift(const Offset(0, 1.5)), ArtKit.topaz, radius: 0.16);
  }
  // Gold well walls.
  ArtKit.goldStroke(
    c,
    Path()
      ..moveTo(well.left, well.top + 1)
      ..lineTo(well.left, well.bottom)
      ..lineTo(well.right, well.bottom)
      ..lineTo(well.right, well.top + 1),
    2.6,
  );
}

void _blockGrid(Canvas c, Color tint) {
  const board = Rect.fromLTWH(21, 21, 58, 58);
  _plate(c, board, color: const Color(0xFF15161E));
  const filled = {
    (0, 0): ArtKit.ruby,
    (1, 0): ArtKit.ruby,
    (3, 0): ArtKit.emerald,
    (3, 1): ArtKit.emerald,
    (2, 0): ArtKit.emerald,
    (0, 2): ArtKit.sapphire,
    (1, 2): ArtKit.sapphire,
    (0, 3): ArtKit.sapphire,
    (1, 3): ArtKit.sapphire,
    (3, 3): ArtKit.topaz,
    (2, 3): ArtKit.topaz,
  };
  for (var row = 0; row < 4; row++) {
    for (var col = 0; col < 4; col++) {
      final r = _cell(board, 4, col, row, gap: 1.8);
      final color = filled[(col, row)];
      if (color != null) {
        ArtKit.tile(c, r, color, radius: 0.18, shadowed: false);
      } else {
        final rr = RRect.fromRectAndRadius(r, const Radius.circular(2));
        c.drawRRect(rr, Paint()..color = Colors.black.withValues(alpha: 0.45));
        c.drawRRect(
          rr.deflate(0.6),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.9
            ..color = Colors.white.withValues(alpha: 0.12),
        );
      }
    }
  }
}

void _gemMerge(Canvas c, Color tint) {
  ArtKit.gem(c, const Offset(31, 36), 12, ArtKit.sapphire);
  ArtKit.gem(c, const Offset(69, 36), 12, ArtKit.sapphire);
  // Gold merge strokes flowing into the bigger gem.
  ArtKit.goldStroke(
    c,
    Path()
      ..moveTo(38, 47)
      ..quadraticBezierTo(42, 52, 45, 50),
    3.0,
  );
  ArtKit.goldStroke(
    c,
    Path()
      ..moveTo(62, 47)
      ..quadraticBezierTo(58, 52, 55, 50),
    3.0,
  );
  ArtKit.gem(c, const Offset(50, 63), 19, ArtKit.emerald, sides: 8);
  _sparkle(c, const Offset(50, 30), 5.5);
  _sparkle(c, const Offset(71, 60), 3.6);
  _sparkle(c, const Offset(29, 62), 3.2);
}

// ---------------------------------------------------------------------------------------------
// Numbers.

void _math(Canvas c, Color tint) {
  const left = Rect.fromLTWH(19, 37, 22, 26);
  const right = Rect.fromLTWH(59, 37, 22, 26);
  ArtKit.tile(c, left, ArtKit.ivory, radius: 0.2);
  ArtKit.tile(c, right, ArtKit.ivory, radius: 0.2);
  _richText(c, '7', left.center, 22, colors: _inkDigits, dropAlpha: 0);
  _richText(c, '5', right.center, 22, colors: _inkDigits, dropAlpha: 0);
  // Gold plus between the tiles.
  Path bar(double w, double h) => Path()
    ..addRRect(RRect.fromRectAndRadius(
        Rect.fromCenter(center: const Offset(50, 50), width: w, height: h), const Radius.circular(1.5)));
  _goldFill(c, Path.combine(PathOperation.union, bar(13, 4.2), bar(4.2, 13)), edge: 0.8);
  // Small gold × and ÷ above and below, the other operations.
  final cross = Path()
    ..moveTo(46.5, 24.5)
    ..lineTo(53.5, 31.5)
    ..moveTo(53.5, 24.5)
    ..lineTo(46.5, 31.5);
  ArtKit.goldStroke(c, cross, 2.6);
  ArtKit.goldStroke(
      c,
      Path()
        ..moveTo(45, 72)
        ..lineTo(55, 72),
      2.6);
  c.drawCircle(const Offset(50, 68.2), 1.6, Paint()..color = ArtKit.gold);
  c.drawCircle(const Offset(50, 75.8), 1.6, Paint()..color = ArtKit.gold);
}

/// One soroban bead: a double cone seen from the side.
void _bead(Canvas c, Offset p, double w, double h, Color color) {
  final path = Path()
    ..moveTo(p.dx - w / 2, p.dy)
    ..lineTo(p.dx - w * 0.2, p.dy - h / 2)
    ..lineTo(p.dx + w * 0.2, p.dy - h / 2)
    ..lineTo(p.dx + w / 2, p.dy)
    ..lineTo(p.dx + w * 0.2, p.dy + h / 2)
    ..lineTo(p.dx - w * 0.2, p.dy + h / 2)
    ..close();
  final b = path.getBounds();
  c.drawPath(
    path,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color.lerp(color, Colors.white, 0.55)!, color, Color.lerp(color, Colors.black, 0.5)!],
        stops: const [0, 0.45, 1],
      ).createShader(b),
  );
  c.drawPath(
    path,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..color = Colors.black.withValues(alpha: 0.5),
  );
}

void _soroban(Canvas c, Color tint) {
  const frame = Rect.fromLTRB(19, 25, 81, 75);
  final frameRR = RRect.fromRectAndRadius(frame, const Radius.circular(4));
  ArtKit.shadow(c, Path()..addRRect(frameRR), blur: 3, offset: const Offset(0, 3), alpha: 0.55);
  c.drawRRect(
    frameRR,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color.lerp(_walnut, Colors.white, 0.2)!, _walnut, Color.lerp(_walnut, Colors.black, 0.55)!],
      ).createShader(frame),
  );
  const inner = Rect.fromLTRB(23.5, 29.5, 76.5, 70.5);
  c.drawRect(inner, Paint()..color = const Color(0xFF1E120A));
  ArtKit.goldStroke(c, Path()..addRRect(frameRR.deflate(0.8)), 1.4);
  const beamTop = 39.5, beamBottom = 43.5;
  const rods = [33.0, 50.0, 67.0];
  // Rods.
  for (final x in rods) {
    c.drawRect(
      Rect.fromLTRB(x - 0.9, inner.top, x + 0.9, inner.bottom),
      Paint()..color = const Color(0xFFB89A6A),
    );
  }
  // Values 1, 5 (+0), 3: heaven bead down on the middle rod, earth beads up where counted.
  const up = [1, 0, 3];
  const heavenDown = [false, true, false];
  const bw = 14.5, bh = 6.4;
  for (var i = 0; i < 3; i++) {
    final x = rods[i];
    final hy = heavenDown[i] ? beamTop - bh / 2 : inner.top + bh / 2;
    _bead(c, Offset(x, hy), bw, bh, heavenDown[i] ? ArtKit.gold : _rosewood);
    for (var k = 0; k < 4; k++) {
      final counted = k < up[i];
      final y = counted ? beamBottom + bh / 2 + k * bh : inner.bottom - bh / 2 - (3 - k) * bh;
      _bead(c, Offset(x, y), bw, bh, counted ? ArtKit.gold : _rosewood);
    }
  }
  // Gold reckoning bar.
  _pill(c, const Rect.fromLTRB(22, beamTop, 78, beamBottom), ArtKit.gold, shadowed: false);
}

// ---------------------------------------------------------------------------------------------
// Board games.

/// A turned pawn standing with its base centred at [p].
void _pawn(Canvas c, Offset p, double h, Color color) {
  final w = h * 0.62;
  final body = Path()
    ..moveTo(p.dx - w / 2, p.dy)
    ..quadraticBezierTo(p.dx - w * 0.42, p.dy - h * 0.18, p.dx - w * 0.16, p.dy - h * 0.55)
    ..lineTo(p.dx + w * 0.16, p.dy - h * 0.55)
    ..quadraticBezierTo(p.dx + w * 0.42, p.dy - h * 0.18, p.dx + w / 2, p.dy)
    ..close();
  ArtKit.shadow(c, body, blur: 1.5, offset: const Offset(0.8, 1.5), alpha: 0.6);
  c.drawPath(
    body,
    Paint()
      ..shader = LinearGradient(
        colors: [Color.lerp(color, Colors.white, 0.45)!, color, Color.lerp(color, Colors.black, 0.55)!],
        stops: const [0, 0.4, 1],
      ).createShader(body.getBounds()),
  );
  _pill(c, Rect.fromCenter(center: p, width: w * 1.1, height: h * 0.18), color, shadowed: false);
  ArtKit.ball(c, Offset(p.dx, p.dy - h * 0.7), h * 0.22, color, shadowed: false);
}

void _corridor(Canvas c, Color tint) {
  const board = Rect.fromLTWH(22, 22, 56, 56);
  _plate(c, board, color: const Color(0xFF2A1A0E));
  const n = 5, gap = 2.8;
  for (var row = 0; row < n; row++) {
    for (var col = 0; col < n; col++) {
      final r = _cell(board, n, col, row, gap: gap);
      final rr = RRect.fromRectAndRadius(r, const Radius.circular(1.6));
      c.drawRRect(
        rr,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF9C6A3A), Color(0xFF6A4220)],
          ).createShader(r),
      );
    }
  }
  // Gold walls lying in the grooves, each two cells long.
  Rect hWall(int col, int row) {
    final a = _cell(board, n, col, row, gap: gap), b = _cell(board, n, col + 1, row, gap: gap);
    return Rect.fromLTRB(a.left, a.bottom - 0.6, b.right, a.bottom + gap + 0.6);
  }

  Rect vWall(int col, int row) {
    final a = _cell(board, n, col, row, gap: gap), b = _cell(board, n, col, row + 1, gap: gap);
    return Rect.fromLTRB(a.right - 0.6, a.top, a.right + gap + 0.6, b.bottom);
  }

  for (final w in [hWall(1, 1), hWall(2, 2), vWall(3, 2)]) {
    final path = Path()..addRRect(RRect.fromRectAndRadius(w, const Radius.circular(1.2)));
    _goldFill(c, path, edge: 0.6);
  }
  final ivoryAt = _cell(board, n, 2, 3, gap: gap), rubyAt = _cell(board, n, 1, 0, gap: gap);
  _pawn(c, Offset(rubyAt.center.dx, rubyAt.bottom), 19, _garnet);
  _pawn(c, Offset(ivoryAt.center.dx, ivoryAt.bottom), 19, ArtKit.ivory);
}

void _push(Canvas c, Color tint) {
  const d = 12.4, dy = d * 0.866, rr = 5.4;
  const center = Offset(50, 50);
  // Hexagonal wooden board with a gold rim (pointy left/right, rows run across).
  final hex = Path()
    ..addPolygon([for (var i = 0; i < 6; i++) center + Offset.fromDirection(i * math.pi / 3, 2 * d + rr + 3.6)], true);
  ArtKit.shadow(c, hex, blur: 3, offset: const Offset(0, 3), alpha: 0.55);
  c.drawPath(
    hex,
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF9A6A3C), Color(0xFF6E4524), Color(0xFF4A2C14)],
      ).createShader(hex.getBounds()),
  );
  ArtKit.goldStroke(c, hex, 2.2);
  for (var k = -2; k <= 2; k++) {
    final count = 5 - k.abs();
    for (var i = 0; i < count; i++) {
      final p = center + Offset((i - (count - 1) / 2) * d, k * dy);
      c.drawCircle(p, rr * 0.82, Paint()..color = Colors.black.withValues(alpha: 0.42));
      if (k < 0 || (k == 0 && i == 1)) {
        ArtKit.ball(c, p, rr, _onyx, shadowed: false);
      } else if (k > 0 || (k == 0 && i == 3)) {
        ArtKit.ball(c, p, rr, ArtKit.pearl, shadowed: false);
      }
    }
  }
}

void _morris(Canvas c, Color tint) {
  // Dark wooden roundel behind the board for contrast.
  final backing = Path()
    ..addRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(20, 20, 60, 60), const Radius.circular(9)));
  ArtKit.shadow(c, backing, blur: 3, offset: const Offset(0, 3), alpha: 0.5);
  c.drawPath(
    backing,
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF3A2414), Color(0xFF1E120A)],
      ).createShader(backing.getBounds()),
  );
  const halves = [25.0, 16.5, 8.0];
  final lines = Path();
  for (final h in halves) {
    lines.addRect(Rect.fromCenter(center: const Offset(50, 50), width: h * 2, height: h * 2));
  }
  lines
    ..moveTo(50, 25)
    ..lineTo(50, 42)
    ..moveTo(50, 58)
    ..lineTo(50, 75)
    ..moveTo(25, 50)
    ..lineTo(42, 50)
    ..moveTo(58, 50)
    ..lineTo(75, 50);
  ArtKit.goldStroke(c, lines, 2.4);
  // Stones: an ivory mill along the middle square's top, onyx stones elsewhere.
  for (final p in const [Offset(33.5, 33.5), Offset(50, 33.5), Offset(66.5, 33.5)]) {
    ArtKit.ball(c, p, 5.6, ArtKit.ivory);
  }
  for (final p in const [Offset(25, 50), Offset(58, 50), Offset(50, 75), Offset(66.5, 66.5)]) {
    ArtKit.ball(c, p, 5.6, _garnet);
  }
}

void _surakarta(Canvas c, Color tint) {
  const g = 13.0, s = g * 2 / 3; // grid half-extent, line spacing
  const o = Offset(50, 50);
  final grid = Path();
  for (final v in [-g, -s / 2, s / 2, g]) {
    grid
      ..moveTo(o.dx + v, o.dy - g)
      ..lineTo(o.dx + v, o.dy + g)
      ..moveTo(o.dx - g, o.dy + v)
      ..lineTo(o.dx + g, o.dy + v);
  }
  final inner = Path(), outer = Path();
  for (final sx in [-1.0, 1.0]) {
    for (final sy in [-1.0, 1.0]) {
      final corner = o + Offset(sx * g, sy * g);
      final start = sx < 0 ? 0.0 : math.pi;
      final sweep = -1.5 * math.pi * sx * sy;
      inner.addArc(Rect.fromCircle(center: corner, radius: s), start, sweep);
      outer.addArc(Rect.fromCircle(center: corner, radius: 2 * s), start, sweep);
    }
  }
  final shade = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 4.6
    ..color = Colors.black.withValues(alpha: 0.35);
  c.drawPath(outer.shift(const Offset(0, 1.4)), shade);
  c.drawPath(inner.shift(const Offset(0, 1.4)), shade);
  c.drawPath(
    grid,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..color = ArtKit.ivory.withValues(alpha: 0.9),
  );
  ArtKit.goldStroke(c, outer, 3.2);
  c.drawPath(
    inner,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2
      ..color = const Color(0xFFD9DEE8),
  );
  ArtKit.ball(c, o + const Offset(-g, -s / 2), 6, _garnet);
  ArtKit.ball(c, o + const Offset(s / 2, g), 6, ArtKit.ivory);
}

void _cube(Canvas c, Color tint) {
  const a = 31.0;
  const o = Offset(50, 52);
  final cos30 = math.cos(math.pi / 6);
  final up = o + const Offset(0, -a);
  final ur = o + Offset(a * cos30, -a / 2);
  final dr = o + Offset(a * cos30, a / 2);
  final dn = o + const Offset(0, a);
  final dl = o + Offset(-a * cos30, a / 2);
  final ul = o + Offset(-a * cos30, -a / 2);
  final hull = Path()..addPolygon([up, ur, dr, dn, dl, ul], true);
  ArtKit.shadow(c, hull, blur: 3, offset: const Offset(0, 3), alpha: 0.55);
  c.drawPath(hull, Paint()..color = const Color(0xFF0E0E12));
  c.drawPath(
    hull,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeJoin = StrokeJoin.round
      ..color = const Color(0xFF0E0E12),
  );

  // Each face: origin corner and two edge vectors; stickers are inset quads.
  void face(Offset origin, Offset e1, Offset e2, List<Color> colors, double light) {
    const inset = 0.09;
    for (var i = 0; i < 3; i++) {
      for (var j = 0; j < 3; j++) {
        Offset q(double u, double v) => origin + e1 * ((i + u) / 3) + e2 * ((j + v) / 3);
        final pts = [q(inset, inset), q(1 - inset, inset), q(1 - inset, 1 - inset), q(inset, 1 - inset)];
        final path = Path()..addPolygon(pts, true);
        final base = colors[j * 3 + i];
        final col = light >= 0 ? Color.lerp(base, Colors.white, light)! : Color.lerp(base, Colors.black, -light)!;
        c.drawPath(
          path,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color.lerp(col, Colors.white, 0.25)!, col, Color.lerp(col, Colors.black, 0.2)!],
            ).createShader(path.getBounds()),
        );
      }
    }
  }

  const w = ArtKit.pearl, r = ArtKit.ruby, b = ArtKit.sapphire, y = ArtKit.topaz, g = ArtKit.emerald;
  face(up, ul - up, ur - up, const [w, w, w, w, w, y, w, w, w], 0.08); // top
  face(ul, o - ul, dl - ul, const [r, r, r, r, r, r, g, r, r], 0.0); // left
  face(o, ur - o, dn - o, const [b, b, b, b, b, b, b, b, y], -0.18); // right
  // Specular edge along the top face's front corner.
  c.drawPath(
    Path()
      ..moveTo(ul.dx + 2, ul.dy)
      ..lineTo(o.dx, o.dy - 1)
      ..lineTo(ur.dx - 2, ur.dy),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9
      ..color = Colors.white.withValues(alpha: 0.25),
  );
}
