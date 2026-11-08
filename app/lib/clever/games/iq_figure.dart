import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../lux.dart';

/// Draws an IQ-question figure from the JSON produced by core/src/games/iq/figural.rs.
///
/// Figure JSON (every figure is an object with a kind `k`; `w`/`h` give its extent in option
/// units, so a 3×3 matrix is 3×3 and every option is 1×1 — draw at `size = w × unitPx` for a
/// consistent scale; `IqFigure.aspectOf` gives w/h):
///
/// * `cell` `{items:[…]}` — one frame (0..1 coordinates, y down). Items:
///   - shape `{s, x, y, r, rot, f, c?, ko?, m?}`: s ∈ circle, triangle, square, pentagon, hexagon,
///     heptagon, octagon, diamond, star, cross, arrow; `r` circumradius; `rot` degrees clockwise;
///     f ∈ none, solid, stripes, dots, half; `c` = "gold" (default ivory); `ko` knocks out what is
///     underneath; `m` marks a marker (drawn like any shape).
///   - line `{s:"line", x1, y1, x2, y2}`.
/// * `q` — the "?" cell. `sep` `{t}` — a separator glyph such as "→".
/// * `grid` `{rows, cols, cells:[figure…], colw?}` — row-major sub-figures; cells and "?" get a
///   framed box.
/// * `cube` `{top, front, right}` — isometric cube, each face `{sym, rot}`; sym ∈ dot, ring,
///   square, plus, target, diamond, dots4 (symmetric) or arrow, triangle, half, corner (oriented; rot
///   = quarter turns clockwise from the face's up: back edge on top, top edge on the sides).
/// * `net` `{cols, rows, cells:[{x, y, sym, rot}]}` — a flat cube net (y down, rot clockwise).
/// * `fold` `{n, panels:[{poly, line, arrow} …, {poly, holes}]}` — paper folding steps on an n×n
///   sheet (y down): paper outline, dashed fold line, arrow from the moving part to where it
///   lands; the last panel shows the folded paper with the punched holes.
/// * `sheet` `{n, holes}` — an unfolded sheet with holes.
/// * `stack` `{dims:[W, D, H], cubes:[[x, y, z]…]}` — isometric unit cubes on a W×D floor plate;
///   x runs right-down, y right-up, z up.
/// * `sticks` `{vw, vh, sticks:[[x1, y1, x2, y2]…]}` — matchsticks in a vw×vh box (head at x2,y2).
/// * `poly` `{n, cells:[[x, y]…], abs?}` — a polyomino in an n×n frame (centred unless `abs`).
/// * `assembly` `{target:[[x, y]…], pieces:[{t, cells}], n, tn}` — target shape above six
///   labelled pieces, all at one cell size.
class IqFigure extends StatelessWidget {
  final Map<String, dynamic> json;
  final double size;
  const IqFigure(this.json, {super.key, this.size = 120});

  /// Width / height of a figure.
  static double aspectOf(Map<String, dynamic> json) {
    final w = (json['w'] as num?)?.toDouble() ?? 1;
    final h = (json['h'] as num?)?.toDouble() ?? 1;
    return h <= 0 ? 1 : w / h;
  }

  @override
  Widget build(BuildContext context) {
    final a = aspectOf(json);
    return SizedBox(
      width: size,
      height: size / a,
      child: CustomPaint(painter: IqFigurePainter(json)),
    );
  }
}

class IqFigurePainter extends CustomPainter {
  final Map<String, dynamic> json;
  IqFigurePainter(this.json);

  @override
  void paint(Canvas canvas, Size size) {
    paintFigure(canvas, Offset.zero & size, json, framed: false);
  }

  @override
  bool shouldRepaint(covariant IqFigurePainter old) => old.json != json;
}

// ---------------------------------------------------------------------------------- palette

class _C {
  static const ink = Lux.ink;
  static const gold = Lux.gold;
  static const goldLight = Lux.goldLight;
  static const box = Color(0xFF07291F);
  static const boxEdge = Color(0x66D4A94E);
  static const knock = Color(0xFF07291F);
  static const faceTop = Color(0xFF2E8467);
  static const faceFront = Color(0xFF1C604B);
  static const faceRight = Color(0xFF11463A);
  static const paper = Color(0xFFEDE4CB);
  static const paperBack = Color(0xFFCFC3A2);
  static const paperInk = Color(0xFF0E4636);
  static const hole = Color(0xFF03190F);
  static const wood = Color(0xFFE9D3A0);
  static const head = Lux.bordeauxLight;
}

double _n(dynamic v, [double d = 0]) => (v as num?)?.toDouble() ?? d;

Map<String, dynamic> _m(dynamic v) => (v as Map).cast<String, dynamic>();

List<dynamic> _l(dynamic v) => (v as List?) ?? const [];

/// Paint any figure into `r`.
void paintFigure(Canvas c, Rect r, Map<String, dynamic> j, {bool framed = true}) {
  switch (j['k']) {
    case 'grid':
      _grid(c, r, j);
    case 'cell':
      if (framed) _frame(c, r);
      _cell(c, _square(r.deflate(r.shortestSide * (framed ? 0.04 : 0.02))), j);
    case 'q':
      _frame(c, r, q: true);
      _text(c, '?', r.center, r.shortestSide * 0.55, _C.gold, serif: true);
    case 'sep':
      if (j['t'] == '→') {
        _sepArrow(c, r);
      } else {
        _text(c, j['t'] as String? ?? '', r.center, r.shortestSide * 0.42, _C.gold);
      }
    case 'cube':
      _cube(c, _square(r), j);
    case 'net':
      _net(c, r, j);
    case 'fold':
      _fold(c, r, j);
    case 'sheet':
      _sheet(c, _square(r).deflate(r.shortestSide * 0.08), _n(j['n'], 4), _l(j['holes']), null, null);
    case 'stack':
      _stack(c, r, j);
    case 'sticks':
      _sticks(c, r, j);
    case 'poly':
      _poly(c, _square(r), j);
    case 'assembly':
      _assembly(c, r, j);
  }
}

/// A drawn "→" (the UI fonts have no arrow glyph).
void _sepArrow(Canvas c, Rect r) {
  final s = math.min(r.width, r.height);
  final a = r.center - Offset(s * 0.3, 0), b = r.center + Offset(s * 0.3, 0);
  final pen = Paint()
    ..color = _C.gold
    ..strokeWidth = math.max(2.0, s * 0.05)
    ..strokeCap = StrokeCap.round
    ..style = PaintingStyle.stroke
    ..strokeJoin = StrokeJoin.round;
  c.drawLine(a, b, pen);
  c.drawPath(
    Path()
      ..moveTo(b.dx - s * 0.14, b.dy - s * 0.12)
      ..lineTo(b.dx, b.dy)
      ..lineTo(b.dx - s * 0.14, b.dy + s * 0.12),
    pen,
  );
}

Rect _square(Rect r) => Rect.fromCenter(center: r.center, width: r.shortestSide, height: r.shortestSide);

void _frame(Canvas c, Rect r, {bool q = false}) {
  final rr = RRect.fromRectAndRadius(r.deflate(r.shortestSide * 0.03), Radius.circular(r.shortestSide * 0.08));
  c.drawRRect(rr, Paint()..color = _C.box);
  c.drawRRect(
    rr,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.2, r.shortestSide * 0.012)
      ..color = q ? _C.gold : _C.boxEdge,
  );
}

void _text(Canvas c, String t, Offset centre, double size, Color color, {bool serif = false, FontWeight? weight}) {
  final tp = TextPainter(
    text: TextSpan(
      text: t,
      style: serif ? Lux.display(size, color: color) : Lux.ui(size, color: color, weight: weight ?? FontWeight.w600),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(c, centre - Offset(tp.width / 2, tp.height / 2));
}

double _stroke(double px) => math.max(1.6, px * 0.028);

// -------------------------------------------------------------------------------------- grid

void _grid(Canvas c, Rect r, Map<String, dynamic> j) {
  final rows = (j['rows'] as num).toInt();
  final cols = (j['cols'] as num).toInt();
  final colw = j['colw'] != null ? _l(j['colw']).map((e) => _n(e)).toList() : List.filled(cols, 1.0);
  final total = colw.fold<double>(0, (a, b) => a + b);
  final unit = math.min(r.width / total, r.height / rows);
  final ox = r.left + (r.width - unit * total) / 2;
  final oy = r.top + (r.height - unit * rows) / 2;
  final cells = _l(j['cells']);
  for (var i = 0; i < rows; i++) {
    var x = ox;
    for (var k = 0; k < cols; k++) {
      final cr = Rect.fromLTWH(x, oy + i * unit, unit * colw[k], unit);
      final idx = i * cols + k;
      if (idx < cells.length) paintFigure(c, cr.deflate(unit * 0.03), _m(cells[idx]));
      x += unit * colw[k];
    }
  }
}

// -------------------------------------------------------------------------------------- cell

void _cell(Canvas c, Rect r, Map<String, dynamic> j) {
  final s = r.width;
  final sw = _stroke(s);
  for (final raw in _l(j['items'])) {
    final it = _m(raw);
    final color = it['c'] == 'gold' ? _C.gold : _C.ink;
    if (it['s'] == 'line') {
      c.drawLine(
        r.topLeft + Offset(_n(it['x1']) * s, _n(it['y1']) * s),
        r.topLeft + Offset(_n(it['x2']) * s, _n(it['y2']) * s),
        Paint()
          ..color = color
          ..strokeWidth = sw * 1.1
          ..strokeCap = StrokeCap.round,
      );
      continue;
    }
    final centre = r.topLeft + Offset(_n(it['x']) * s, _n(it['y']) * s);
    final rad = _n(it['r']) * s;
    final path = shapePath(it['s'] as String, rad, _n(it['rot']));
    drawFilled(c, path.shift(centre), it['f'] as String? ?? 'none', color, rad, sw,
        knockout: it['ko'] == true, centre: centre, rot: _n(it['rot']));
  }
}

/// Outline of a shape centred at the origin with circumradius `r`, rotated `rot` degrees.
Path shapePath(String s, double r, double rot) {
  final p = Path();
  List<Offset> reg(int n, [double start = -math.pi / 2]) => [
        for (var i = 0; i < n; i++) Offset(math.cos(start + 2 * math.pi * i / n), math.sin(start + 2 * math.pi * i / n))
      ];
  List<Offset> pts;
  switch (s) {
    case 'circle':
      p.addOval(Rect.fromCircle(center: Offset.zero, radius: r));
      return p;
    case 'square':
      pts = reg(4, -math.pi / 4);
    case 'diamond':
      pts = const [Offset(0, -1), Offset(0.62, 0), Offset(0, 1), Offset(-0.62, 0)];
    case 'star':
      pts = [
        for (var i = 0; i < 10; i++)
          Offset(math.cos(-math.pi / 2 + math.pi * i / 5), math.sin(-math.pi / 2 + math.pi * i / 5)) *
              (i.isEven ? 1.0 : 0.45),
      ];
    case 'cross':
      const a = 0.3;
      pts = const [
        Offset(-a, -1), Offset(a, -1), Offset(a, -a), Offset(1, -a), Offset(1, a), Offset(a, a), //
        Offset(a, 1), Offset(-a, 1), Offset(-a, a), Offset(-1, a), Offset(-1, -a), Offset(-a, -a),
      ];
    case 'arrow':
      pts = const [
        Offset(0, -1), Offset(0.62, -0.18), Offset(0.22, -0.18), Offset(0.22, 0.95), //
        Offset(-0.22, 0.95), Offset(-0.22, -0.18), Offset(-0.62, -0.18),
      ];
    case 'triangle':
      pts = reg(3);
      // centre the triangle's bounding box vertically a little
      pts = [for (final q in pts) q + const Offset(0, 0.12)];
    case 'pentagon':
      pts = reg(5);
    case 'hexagon':
      pts = reg(6);
    case 'heptagon':
      pts = reg(7);
    case 'octagon':
      pts = reg(8, -math.pi / 2 + math.pi / 8);
    default:
      pts = reg(4, -math.pi / 4);
  }
  final a = rot * math.pi / 180;
  final ca = math.cos(a), sa = math.sin(a);
  for (var i = 0; i < pts.length; i++) {
    final q = pts[i] * r;
    final o = Offset(q.dx * ca - q.dy * sa, q.dx * sa + q.dy * ca);
    i == 0 ? p.moveTo(o.dx, o.dy) : p.lineTo(o.dx, o.dy);
  }
  p.close();
  return p;
}

/// Fill `path` with a pattern (patterns, not hue, carry the meaning) and outline it.
void drawFilled(Canvas c, Path path, String fill, Color color, double r, double sw,
    {bool knockout = false, Offset? centre, double rot = 0}) {
  final b = path.getBounds();
  if (knockout) c.drawPath(path, Paint()..color = _C.knock);
  switch (fill) {
    case 'solid':
      c.drawPath(path, Paint()..color = color);
    case 'stripes':
      c.save();
      c.clipPath(path);
      final gap = math.max(4.0, r * 0.3);
      final pen = Paint()
        ..color = color
        ..strokeWidth = math.max(1.5, sw * 0.8);
      for (var x = b.left - b.height; x < b.right + b.height; x += gap) {
        c.drawLine(Offset(x, b.bottom), Offset(x + b.height, b.top), pen);
      }
      c.restore();
    case 'dots':
      c.save();
      c.clipPath(path);
      final gap = math.max(5.5, r * 0.4);
      final dot = Paint()..color = color;
      final rad = math.max(1.8, gap * 0.22);
      var row = 0;
      for (var y = b.top + gap / 2; y < b.bottom; y += gap, row++) {
        for (var x = b.left + (row.isOdd ? gap / 2 : 0) + gap / 4; x < b.right; x += gap) {
          c.drawCircle(Offset(x, y), rad, dot);
        }
      }
      c.restore();
    case 'half':
      c.save();
      c.clipPath(path);
      // left half in the shape's own frame (it turns with the shape)
      c.drawPath(_halfPlane(centre ?? b.center, r * 2, rot), Paint()..color = color);
      c.restore();
  }
  c.drawPath(
    path,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = sw
      ..strokeJoin = StrokeJoin.round
      ..color = color,
  );
}

Path _halfPlane(Offset centre, double size, double rotDeg) {
  final a = rotDeg * math.pi / 180;
  final ca = math.cos(a), sa = math.sin(a);
  Offset t(double x, double y) => centre + Offset(x * ca - y * sa, x * sa + y * ca);
  return Path()
    ..moveTo(t(-size, -size).dx, t(-size, -size).dy)
    ..lineTo(t(0, -size).dx, t(0, -size).dy)
    ..lineTo(t(0, size).dx, t(0, size).dy)
    ..lineTo(t(-size, size).dx, t(-size, size).dy)
    ..close();
}

// -------------------------------------------------------------------------------------- cube

const _c30 = 0.8660254;

/// Glyph on a unit face, local coordinates −1..1 with y down (up = −y).
void _glyph(Canvas c, String sym, double unitPx) {
  final sw = math.max(1.6, unitPx * 0.08) / (unitPx);
  final ink = Paint()..color = _C.ink;
  final gold = Paint()..color = _C.goldLight;
  final pen = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = sw * 2.2
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..color = _C.ink;
  switch (sym) {
    case 'dot':
      c.drawCircle(Offset.zero, 0.42, ink);
    case 'ring':
      c.drawCircle(Offset.zero, 0.46, pen);
    case 'square':
      c.drawRect(const Rect.fromLTRB(-0.45, -0.45, 0.45, 0.45), pen);
    case 'plus':
      c.drawLine(const Offset(0, -0.58), const Offset(0, 0.58), pen..strokeWidth = sw * 3.2);
      c.drawLine(const Offset(-0.58, 0), const Offset(0.58, 0), pen);
    case 'target':
      c.drawCircle(Offset.zero, 0.5, pen);
      c.drawCircle(Offset.zero, 0.17, ink);
    case 'diamond':
      c.drawPath(
          Path()
            ..moveTo(0, -0.58)
            ..lineTo(0.58, 0)
            ..lineTo(0, 0.58)
            ..lineTo(-0.58, 0)
            ..close(),
          ink);
    case 'dots4':
      for (final o in const [Offset(-0.33, -0.33), Offset(0.33, -0.33), Offset(-0.33, 0.33), Offset(0.33, 0.33)]) {
        c.drawCircle(o, 0.16, ink);
      }
    case 'arrow':
      c.drawPath(shapePath('arrow', 0.66, 0), gold);
    case 'triangle':
      c.drawPath(
          Path()
            ..moveTo(0, -0.6)
            ..lineTo(0.52, 0.42)
            ..lineTo(-0.52, 0.42)
            ..close(),
          gold);
    case 'half':
      c.drawRect(const Rect.fromLTRB(-0.48, -0.48, 0.48, 0), gold);
      c.drawRect(const Rect.fromLTRB(-0.48, -0.48, 0.48, 0.48), pen..color = _C.goldLight);
    case 'corner':
      c.drawPath(
          Path()
            ..moveTo(-0.42, -0.55)
            ..lineTo(-0.42, 0.42)
            ..lineTo(0.5, 0.42),
          pen
            ..color = _C.goldLight
            ..strokeWidth = sw * 3.6
            ..strokeCap = StrokeCap.square);
  }
}

/// Draw `sym` on a parallelogram face with centre `o` and half-axes `s` (right) and `t` (up).
void _faceGlyph(Canvas c, Offset o, Offset s, Offset t, Map<String, dynamic> g, double unitPx) {
  c.save();
  // local (lx, ly) with y down → o + lx·s − ly·t
  final m = Matrix4.identity();
  m.setEntry(0, 0, s.dx);
  m.setEntry(1, 0, s.dy);
  m.setEntry(0, 1, -t.dx);
  m.setEntry(1, 1, -t.dy);
  m.setEntry(0, 3, o.dx);
  m.setEntry(1, 3, o.dy);
  c.transform(m.storage);
  c.rotate(_n(g['rot']) * math.pi / 2);
  _glyph(c, g['sym'] as String? ?? '', unitPx);
  c.restore();
}

void _cube(Canvas c, Rect r, Map<String, dynamic> j) {
  final e = math.min(r.width / (2 * _c30), r.height / 2) * 0.86;
  final ex = Offset(_c30 * e, 0.5 * e), ey = Offset(_c30 * e, -0.5 * e), ez = Offset(0, -e);
  final origin = r.center - (ex + ey + ez) / 2;
  Offset p(double x, double y, double z) => origin + ex * x + ey * y + ez * z;
  final edge = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = math.max(1.5, e * 0.035)
    ..strokeJoin = StrokeJoin.round
    ..color = _C.gold;
  Path quad(List<Offset> q) => Path()..addPolygon(q, true);
  final top = quad([p(0, 0, 1), p(1, 0, 1), p(1, 1, 1), p(0, 1, 1)]);
  final front = quad([p(0, 0, 0), p(1, 0, 0), p(1, 0, 1), p(0, 0, 1)]);
  final right = quad([p(1, 0, 0), p(1, 1, 0), p(1, 1, 1), p(1, 0, 1)]);
  c.drawPath(top, Paint()..color = _C.faceTop);
  c.drawPath(front, Paint()..color = _C.faceFront);
  c.drawPath(right, Paint()..color = _C.faceRight);
  final u = e / 2;
  if (j['top'] != null) _faceGlyph(c, p(.5, .5, 1), ex / 2 * 0.92, ey / 2 * 0.92, _m(j['top']), u);
  if (j['front'] != null) _faceGlyph(c, p(.5, 0, .5), ex / 2 * 0.92, ez / 2 * 0.92, _m(j['front']), u);
  if (j['right'] != null) _faceGlyph(c, p(1, .5, .5), ey / 2 * 0.92, ez / 2 * 0.92, _m(j['right']), u);
  for (final f in [top, front, right]) {
    c.drawPath(f, edge);
  }
}

// --------------------------------------------------------------------------------------- net

void _net(Canvas c, Rect r, Map<String, dynamic> j) {
  final cols = _n(j['cols'], 4), rows = _n(j['rows'], 3);
  final cs = math.min(r.width / cols, r.height / rows) * 0.96;
  final o = r.center - Offset(cs * cols / 2, cs * rows / 2);
  final edge = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = math.max(1.5, cs * 0.03)
    ..color = _C.gold;
  for (final raw in _l(j['cells'])) {
    final cell = _m(raw);
    final rect = Rect.fromLTWH(o.dx + _n(cell['x']) * cs, o.dy + _n(cell['y']) * cs, cs, cs);
    c.drawRect(rect, Paint()..color = _C.faceFront);
    _faceGlyph(c, rect.center, Offset(cs / 2 * 0.82, 0), Offset(0, -cs / 2 * 0.82), cell, cs / 2);
    c.drawRect(rect, edge);
  }
}

// -------------------------------------------------------------------------------------- fold

List<Offset> _pts(dynamic v) => [for (final p in _l(v)) Offset(_n((p as List)[0]), _n(p[1]))];

void _sheet(Canvas c, Rect r, double n, List<dynamic> holes, List<Offset>? poly, Map<String, dynamic>? panel) {
  final u = r.width / n;
  Offset m(Offset p) => r.topLeft + p * u;
  // ghost of the full sheet
  if (poly != null) {
    c.drawRect(
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = _C.paper.withValues(alpha: 0.22),
    );
  }
  final outline = Path()
    ..addPolygon((poly ?? [Offset.zero, Offset(n, 0), Offset(n, n), Offset(0, n)]).map(m).toList(), true);
  c.drawPath(outline, Paint()..color = _C.paper);
  // faint unit grid
  c.save();
  c.clipPath(outline);
  final grid = Paint()
    ..color = _C.paperInk.withValues(alpha: 0.16)
    ..strokeWidth = 1;
  for (var i = 1; i < n; i++) {
    c.drawLine(m(Offset(i.toDouble(), 0)), m(Offset(i.toDouble(), n)), grid);
    c.drawLine(m(Offset(0, i.toDouble())), m(Offset(n, i.toDouble())), grid);
  }
  c.restore();
  if (panel != null && panel['line'] != null) {
    final l = _pts(panel['line']);
    final a = m(l[0]), b = m(l[1]);
    // moving side shaded
    _dashed(
        c,
        a,
        b,
        Paint()
          ..color = _C.paperInk
          ..strokeWidth = math.max(1.6, u * 0.09));
    final ar = _pts(panel['arrow']);
    _curvedArrow(c, m(ar[0]), m(ar[1]), u);
  }
  c.drawPath(
    outline,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.5, u * 0.06)
      ..color = _C.paperBack,
  );
  for (final h in _pts(holes)) {
    c.drawCircle(m(h), u * 0.27, Paint()..color = _C.hole);
    c.drawCircle(
      m(h),
      u * 0.27,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.2, u * 0.05)
        ..color = _C.paperInk,
    );
  }
}

void _dashed(Canvas c, Offset a, Offset b, Paint p) {
  final d = b - a;
  final len = d.distance;
  if (len == 0) return;
  final dir = d / len;
  final dash = math.max(5.0, p.strokeWidth * 3), gap = dash * 0.7;
  for (var t = 0.0; t < len; t += dash + gap) {
    c.drawLine(a + dir * t, a + dir * math.min(len, t + dash), p..strokeCap = StrokeCap.butt);
  }
}

void _curvedArrow(Canvas c, Offset a, Offset b, double u) {
  final mid = (a + b) / 2;
  final d = b - a;
  final normal = Offset(-d.dy, d.dx) / (d.distance == 0 ? 1 : d.distance);
  final ctrl = mid + normal * d.distance * 0.35;
  final pen = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = math.max(2.0, u * 0.1)
    ..strokeCap = StrokeCap.round
    ..color = Lux.goldDeep;
  final path = Path()
    ..moveTo(a.dx, a.dy)
    ..quadraticBezierTo(ctrl.dx, ctrl.dy, b.dx, b.dy);
  c.drawPath(path, pen);
  final tangent = b - ctrl;
  final ang = math.atan2(tangent.dy, tangent.dx);
  final hl = math.max(7.0, u * 0.45);
  final head = Path()
    ..moveTo(b.dx, b.dy)
    ..lineTo(b.dx - hl * math.cos(ang - 0.45), b.dy - hl * math.sin(ang - 0.45))
    ..lineTo(b.dx - hl * math.cos(ang + 0.45), b.dy - hl * math.sin(ang + 0.45))
    ..close();
  c.drawPath(head, Paint()..color = Lux.goldDeep);
  c.drawCircle(a, math.max(2.5, u * 0.12), Paint()..color = Lux.goldDeep);
}

void _fold(Canvas c, Rect r, Map<String, dynamic> j) {
  final panels = _l(j['panels']);
  final n = _n(j['n'], 4);
  final pw = r.width / panels.length;
  final side = math.min(pw, r.height) * 0.8;
  for (var i = 0; i < panels.length; i++) {
    final p = _m(panels[i]);
    final centre = Offset(r.left + pw * (i + 0.5), r.center.dy);
    final pr = Rect.fromCenter(center: centre, width: side, height: side);
    final last = i == panels.length - 1;
    _sheet(c, pr, n, last ? _l(p['holes']) : const [], _pts(p['poly']), last ? null : p);
    if (i > 0) _text(c, '›', Offset(r.left + pw * i, r.center.dy), side * 0.28, _C.gold);
    _text(c, last ? 'del' : '${i + 1}', Offset(centre.dx, pr.bottom + (r.height - side) / 4), side * 0.12, Lux.muted);
  }
}

// ------------------------------------------------------------------------------------- stack

void _stack(Canvas c, Rect r, Map<String, dynamic> j) {
  final dims = _l(j['dims']).map((e) => _n(e)).toList();
  final w = dims[0], d = dims[1];
  // fit to the stack's real height (the box height only matters to the question)
  final h = _l(j['cubes']).fold<double>(1, (m, q) => math.max(m, _n((q as List)[2]) + 1));
  // projected extent of the W×D×H box in edge units
  final minX = 0.0, maxX = (w + d) * _c30;
  final minY = -0.5 * d - h, maxY = 0.5 * w;
  final e = math.min(r.width / (maxX - minX), r.height / (maxY - minY)) * 0.94;
  final ex = Offset(_c30 * e, 0.5 * e), ey = Offset(_c30 * e, -0.5 * e), ez = Offset(0, -e);
  final origin = Offset(
    r.center.dx - (minX + maxX) / 2 * e,
    r.center.dy - (minY + maxY) / 2 * e,
  );
  Offset p(double x, double y, double z) => origin + ex * x + ey * y + ez * z;
  final edge = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = math.max(1.5, e * 0.05)
    ..strokeJoin = StrokeJoin.round
    ..color = _C.gold;
  // floor plate with its unit grid
  final floor = Path()..addPolygon([p(0, 0, 0), p(w, 0, 0), p(w, d, 0), p(0, d, 0)], true);
  c.drawPath(floor, Paint()..color = const Color(0xFF0A3A2C));
  final gp = Paint()
    ..color = _C.gold.withValues(alpha: 0.35)
    ..strokeWidth = 1;
  for (var i = 0; i <= w; i++) {
    c.drawLine(p(i.toDouble(), 0, 0), p(i.toDouble(), d, 0), gp);
  }
  for (var k = 0; k <= d; k++) {
    c.drawLine(p(0, k.toDouble(), 0), p(w, k.toDouble(), 0), gp);
  }
  final cubes = [
    for (final q in _l(j['cubes'])) [_n((q as List)[0]), _n(q[1]), _n(q[2])],
  ]..sort((a, b) => (a[0] - a[1] + a[2]).compareTo(b[0] - b[1] + b[2]));
  for (final q in cubes) {
    final x = q[0], y = q[1], z = q[2];
    Path quad(List<Offset> l) => Path()..addPolygon(l, true);
    final top = quad([p(x, y, z + 1), p(x + 1, y, z + 1), p(x + 1, y + 1, z + 1), p(x, y + 1, z + 1)]);
    final front = quad([p(x, y, z), p(x + 1, y, z), p(x + 1, y, z + 1), p(x, y, z + 1)]);
    final right = quad([p(x + 1, y, z), p(x + 1, y + 1, z), p(x + 1, y + 1, z + 1), p(x + 1, y, z + 1)]);
    c.drawPath(top, Paint()..color = _C.paper);
    c.drawPath(front, Paint()..color = const Color(0xFFB9AD8C));
    c.drawPath(right, Paint()..color = const Color(0xFF8C8268));
    for (final f in [top, front, right]) {
      c.drawPath(f, edge..color = _C.paperInk);
    }
  }
}

// ------------------------------------------------------------------------------------ sticks

void _sticks(Canvas c, Rect r, Map<String, dynamic> j) {
  final vw = _n(j['vw'], 1), vh = _n(j['vh'], 1);
  final u = math.min(r.width / (vw + 0.3), r.height / (vh + 0.3));
  final o = r.center - Offset(vw * u / 2, vh * u / 2);
  final body = Paint()
    ..color = _C.wood
    ..strokeWidth = math.max(3.0, u * 0.075)
    ..strokeCap = StrokeCap.round;
  final head = Paint()..color = _C.head;
  for (final raw in _l(j['sticks'])) {
    final s = (raw as List).map((e) => _n(e)).toList();
    var a = o + Offset(s[0], s[1]) * u, b = o + Offset(s[2], s[3]) * u;
    final d = b - a;
    final inset = d / d.distance * (u * 0.065);
    a += inset;
    b -= inset;
    c.drawLine(a, b, body);
    c.drawOval(
        Rect.fromCenter(center: b - inset * 0.6, width: body.strokeWidth * 1.9, height: body.strokeWidth * 1.9), head);
  }
}

// -------------------------------------------------------------------------------------- poly

void _cells(Canvas c, Offset o, double cs, List<Offset> cells, {Color fill = _C.gold}) {
  final f = Paint()..color = fill;
  final edge = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = math.max(1.5, cs * 0.06)
    ..color = _C.box;
  for (final q in cells) {
    final rect = Rect.fromLTWH(o.dx + q.dx * cs, o.dy + q.dy * cs, cs, cs);
    c.drawRect(rect, f);
    c.drawRect(rect, edge);
  }
}

void _poly(Canvas c, Rect r, Map<String, dynamic> j) {
  final n = _n(j['n'], 4);
  final cells = _pts(j['cells']);
  final cs = r.width * 0.9 / n;
  if (j['abs'] == true) {
    final o = r.center - Offset(cs * n / 2, cs * n / 2);
    final gp = Paint()
      ..color = _C.gold.withValues(alpha: 0.18)
      ..strokeWidth = 1;
    for (var i = 0; i <= n; i++) {
      c.drawLine(o + Offset(i * cs, 0), o + Offset(i * cs, n * cs), gp);
      c.drawLine(o + Offset(0, i * cs), o + Offset(n * cs, i * cs), gp);
    }
    _cells(c, o, cs, cells);
    return;
  }
  final w = cells.map((e) => e.dx).reduce(math.max) + 1, h = cells.map((e) => e.dy).reduce(math.max) + 1;
  _cells(c, r.center - Offset(w * cs / 2, h * cs / 2), cs, cells);
}

// ---------------------------------------------------------------------------------- assembly

void _assembly(Canvas c, Rect r, Map<String, dynamic> j) {
  final target = _pts(j['target']);
  final pieces = _l(j['pieces']).map(_m).toList();
  final n = _n(j['n'], 3), tn = _n(j['tn'], 4);
  final topH = r.height * 0.4;
  final rowH = (r.height - topH) / 2;
  final pw = r.width / 3;
  final cs = math.min(math.min(topH * 0.88 / tn, pw * 0.7 / n), rowH * 0.8 / n);
  final tw = target.map((e) => e.dx).reduce(math.max) + 1, th = target.map((e) => e.dy).reduce(math.max) + 1;
  final tc = Offset(r.center.dx, r.top + topH / 2);
  _cells(c, tc - Offset(tw * cs / 2, th * cs / 2), cs, target, fill: _C.ink);
  for (var i = 0; i < pieces.length; i++) {
    final p = pieces[i];
    final cells = _pts(p['cells']);
    final col = i % 3, row = i ~/ 3;
    final box = Rect.fromLTWH(r.left + col * pw, r.top + topH + row * rowH, pw, rowH);
    _frame(c, box.deflate(2));
    final w = cells.map((e) => e.dx).reduce(math.max) + 1, h = cells.map((e) => e.dy).reduce(math.max) + 1;
    final pc = box.center + Offset(box.width * 0.07, box.height * 0.05);
    _cells(c, pc - Offset(w * cs / 2, h * cs / 2), cs, cells);
    _text(c, p['t'] as String? ?? '', box.topLeft + Offset(box.width * 0.1, box.height * 0.17), rowH * 0.18,
        _C.goldLight);
  }
}
