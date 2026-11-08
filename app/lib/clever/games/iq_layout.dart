import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../lux.dart';

/// Draws the text-category layouts of the IQ game: figures whose JSON has a `"layout"` key
/// (schemas documented in core/src/games/iq/common.rs). Figures without `"layout"` belong to the
/// figural painter (`IqFigure`). Shapes are painted (the UI font has no geometric glyphs).
class IqLayout extends StatelessWidget {
  final Map<String, dynamic> json;
  final double width;

  /// Compact rendering for option cards.
  final bool compact;
  const IqLayout(this.json, {super.key, required this.width, this.compact = false});

  static bool handles(Map<String, dynamic> json) => json['layout'] is String;

  @override
  Widget build(BuildContext context) {
    final body = switch (json['layout']) {
      'series' => _series(),
      'grid' => _grid(),
      'triangles' => _triangles(inverted: false),
      'itriangles' => _triangles(inverted: true),
      'wheel' => _wheel(),
      'star' => _star(),
      'diamonds' => _diamonds(),
      'corners' => _corners(),
      'pairs' => _pairs(),
      'pyramid' => _pyramid(),
      'equations' => _equations(),
      'scales' => _scales(),
      'symbols' => _symbols(),
      'code' => _code(),
      'clues' => _clues(),
      'clock' => _clock(),
      _ => const SizedBox.shrink(),
    };
    if (json['alphabet'] == true) {
      return Column(mainAxisSize: MainAxisSize.min, children: [body, const SizedBox(height: 12), AlphabetStrip(width: width)]);
    }
    return body;
  }

  List<String> _strs(Object? v) => [for (final x in (v as List? ?? const [])) x == null ? '' : '$x'];

  // ---------------------------------------------------------------- series and grids

  Widget _series() {
    final terms = _strs(json['terms']);
    final long = terms.any((t) => t.length > 3);
    // Fit the whole row on one line when possible.
    final fit = (width - 6.0 * (terms.length - 1)) / terms.length;
    final size = math.max(34.0, math.min(long ? 52.0 : 46.0, fit));
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 6,
      runSpacing: 8,
      children: [for (final t in terms) _Chip(t, minWidth: size, height: size)],
    );
  }

  Widget _grid() {
    final rows = [for (final r in (json['rows'] as List? ?? const [])) _strs(r)];
    final cols = rows.fold<int>(0, (m, r) => math.max(m, r.length));
    final cell = math.min(72.0, (width - 8) / math.max(cols, 1) - 6);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final r in rows)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [for (final t in r) Padding(padding: const EdgeInsets.all(3), child: _Chip(t, minWidth: cell, height: cell * 0.78))],
          ),
      ],
    );
  }

  Widget _pairs() {
    final items = [for (final r in (json['items'] as List? ?? const [])) _strs(r)];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final p in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Chip(p.isNotEmpty ? p[0] : '', minWidth: 74, height: 44),
                const Padding(padding: EdgeInsets.symmetric(horizontal: 10), child: Icon(Icons.arrow_forward_rounded, color: Lux.gold, size: 22)),
                _Chip(p.length > 1 ? p[1] : '', minWidth: 74, height: 44),
              ],
            ),
          ),
      ],
    );
  }

  Widget _pyramid() {
    final rows = [for (final r in (json['rows'] as List? ?? const [])) _strs(r)];
    final n = rows.isEmpty ? 1 : rows.last.length;
    final w = math.min(70.0, (width - 10) / n - 4);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final r in rows)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [for (final t in r) Padding(padding: const EdgeInsets.all(2), child: _Chip(t, minWidth: w, height: 40, radius: 6))],
          ),
      ],
    );
  }

  // ---------------------------------------------------------------- equations and shapes

  Widget _token(String t, double size) {
    if (t.startsWith('#')) return ShapeGlyph(t.substring(1), size: size);
    if (t == '(+)') return SizedBox.square(dimension: size * 0.9, child: CustomPaint(painter: _CircledPlus()));
    if (t == '?') return _Chip('?', minWidth: size * 1.3, height: size * 1.2);
    final op = const {'+', '−', '×', '÷', '=', ','}.contains(t);
    return Text(t, style: op ? Lux.ui(size * 0.8, color: Lux.goldLight, weight: FontWeight.w600) : Lux.numeral(size * 0.95, color: Lux.ink));
  }

  Widget _equations() {
    final rows = [for (final r in (json['rows'] as List? ?? const [])) _strs(r)];
    final longest = rows.fold<int>(1, (m, r) => math.max(m, r.length));
    final size = math.min(30.0, width / (longest * 1.45));
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: size * 0.28,
              children: [for (final t in r) _token(t, size)],
            ),
          ),
      ],
    );
  }

  Widget _symbols() {
    final items = _strs(json['items']);
    final size = compact ? math.min(30.0, width / (items.length + 1)) : 34.0;
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 4,
      runSpacing: 4,
      children: [for (final s in items) ShapeGlyph(s, size: size)],
    );
  }

  Widget _scales() {
    final scales = [for (final s in (json['scales'] as List? ?? const [])) Map<String, dynamic>.from(s as Map)];
    final ask = json['ask'] is Map ? Map<String, dynamic>.from(json['ask'] as Map) : null;
    final all = [...scales, if (ask != null) ask];
    const h = 92.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < all.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: SizedBox(
              width: width,
              height: h,
              child: _ScaleView(left: _strs(all[i]['left']), right: _strs(all[i]['right']), asking: i == all.length - 1 && ask != null),
            ),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------- figures with numbers

  Widget _triangles({required bool inverted}) {
    final items = [for (final t in (json['items'] as List? ?? const [])) Map<String, dynamic>.from(t as Map)];
    final w = math.min(150.0, (width - 16) / 2);
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final t in items) SizedBox(width: w, height: w * 0.92, child: CustomPaint(painter: _TrianglePainter(t, inverted: inverted))),
      ],
    );
  }

  Widget _diamonds() {
    final items = [for (final t in (json['items'] as List? ?? const [])) Map<String, dynamic>.from(t as Map)];
    final w = math.min(140.0, (width - 16) / 2);
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 12,
      runSpacing: 12,
      children: [for (final t in items) SizedBox.square(dimension: w, child: CustomPaint(painter: _DiamondPainter(t)))],
    );
  }

  Widget _corners() {
    final items = [for (final t in (json['items'] as List? ?? const [])) Map<String, dynamic>.from(t as Map)];
    final w = math.min(140.0, (width - 16) / 2);
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 12,
      runSpacing: 12,
      children: [for (final t in items) SizedBox.square(dimension: w, child: CustomPaint(painter: _CornersPainter(t)))],
    );
  }

  Widget _wheel() {
    final ring = _strs(json['ring']);
    final center = json['center'] == null ? null : '${json['center']}';
    final d = math.min(width, 260.0);
    return SizedBox.square(dimension: d, child: CustomPaint(painter: _WheelPainter(ring, center)));
  }

  Widget _star() {
    final d = math.min(width, 270.0);
    return SizedBox.square(dimension: d, child: CustomPaint(painter: _StarPainter(_strs(json['tips']), _strs(json['wedges']))));
  }

  Widget _clock() {
    final d = math.min(width * 0.6, 180.0);
    return SizedBox.square(
      dimension: d,
      child: CustomPaint(painter: _ClockPainter((json['h'] as num?)?.toInt() ?? 0, (json['m'] as num?)?.toInt() ?? 0)),
    );
  }

  // ---------------------------------------------------------------- text layouts

  Widget _code() {
    final rows = [for (final r in (json['rows'] as List? ?? const [])) _strs(r)];
    final q = _strs(json['query']);
    Widget line(List<String> r, {bool query = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Chip(r.isNotEmpty ? r[0] : '', minWidth: 90, height: 42, spaced: true),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.arrow_forward_rounded, color: Lux.gold, size: 20)),
              _Chip(r.length > 1 ? r[1] : '', minWidth: 90, height: 42, spaced: true, highlight: query),
            ],
          ),
        );
    return Column(mainAxisSize: MainAxisSize.min, children: [for (final r in rows) line(r), if (q.isNotEmpty) line(q, query: true)]);
  }

  Widget _clues() {
    final lines = _strs(json['lines']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < lines.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  margin: const EdgeInsets.only(right: 10, top: 1),
                  decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Lux.gold.withValues(alpha: 0.6))),
                  child: Text('${i + 1}', style: Lux.ui(12, color: Lux.goldLight, weight: FontWeight.w600)),
                ),
                Expanded(child: Text(lines[i], style: Lux.ui(16.5, color: Lux.ink))),
              ],
            ),
          ),
        if (json['note'] is String)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(json['note'] as String, style: Lux.ui(12.5, color: Lux.muted)),
          ),
      ],
    );
  }
}

/// A number / letter tile. "?" is drawn in gold.
class _Chip extends StatelessWidget {
  final String text;
  final double minWidth;
  final double height;
  final double radius;
  final bool spaced;
  final bool highlight;
  const _Chip(this.text, {required this.minWidth, required this.height, this.radius = 12, this.spaced = false, this.highlight = false});

  @override
  Widget build(BuildContext context) {
    final q = text == '?';
    final hot = q || highlight;
    final size = (height * 0.5).clamp(14.0, 26.0);
    return Container(
      constraints: BoxConstraints(minWidth: minWidth, minHeight: height),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        color: hot ? Lux.gold.withValues(alpha: 0.16) : const Color(0x33000000),
        border: Border.all(color: hot ? Lux.gold : Lux.gold.withValues(alpha: 0.35), width: hot ? 1.5 : 1),
      ),
      // Shrink-wrapped centring: the chip keeps its own size inside a Wrap.
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: Text(
          text,
          style: spaced
              ? Lux.ui(size * 0.85, color: hot ? Lux.goldLight : Lux.ink, weight: FontWeight.w600, spacing: 2.2)
              : Lux.numeral(size * 1.05, color: hot ? Lux.goldLight : Lux.ink),
        ),
      ),
    );
  }
}

/// The 29-letter Turkish alphabet with positions, as a hint strip.
class AlphabetStrip extends StatelessWidget {
  final double width;
  const AlphabetStrip({super.key, required this.width});

  static const letters = [
    'A', 'B', 'C', 'Ç', 'D', 'E', 'F', 'G', 'Ğ', 'H', 'I', 'İ', 'J', 'K', 'L', 'M', 'N', 'O', 'Ö', 'P', 'R', 'S', 'Ş', 'T', 'U', //
    'Ü', 'V', 'Y', 'Z',
  ];

  @override
  Widget build(BuildContext context) {
    final cell = math.max(22.0, math.min(30.0, (width - 4) / 10 - 2));
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 2,
      runSpacing: 3,
      children: [
        for (var i = 0; i < letters.length; i++)
          Container(
            width: cell,
            padding: const EdgeInsets.symmetric(vertical: 2),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(5), color: Lux.lineFaint),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(letters[i], style: Lux.ui(12.5, color: Lux.ink, weight: FontWeight.w600)),
                Text('${i + 1}', style: Lux.ui(8.5, color: Lux.muted)),
              ],
            ),
          ),
      ],
    );
  }
}

/// A painted shape token: t triangle, s square, c circle, d diamond, h hexagon.
class ShapeGlyph extends StatelessWidget {
  final String kind;
  final double size;
  const ShapeGlyph(this.kind, {super.key, required this.size});

  @override
  Widget build(BuildContext context) => SizedBox.square(dimension: size, child: CustomPaint(painter: ShapePainter(kind)));
}

class ShapePainter extends CustomPainter {
  final String kind;
  ShapePainter(this.kind);

  static const colors = {
    't': Color(0xFFE0526B),
    's': Color(0xFF4F86E0),
    'c': Color(0xFFF0B34A),
    'd': Color(0xFF3FBF83),
    'h': Color(0xFFA772E0),
  };

  static Path path(String kind, Rect r) {
    final c = r.center;
    final s = r.shortestSide / 2 * 0.86;
    switch (kind) {
      case 't':
        return Path()
          ..moveTo(c.dx, c.dy - s)
          ..lineTo(c.dx + s * 0.95, c.dy + s * 0.75)
          ..lineTo(c.dx - s * 0.95, c.dy + s * 0.75)
          ..close();
      case 's':
        return Path()..addRRect(RRect.fromRectAndRadius(Rect.fromCircle(center: c, radius: s * 0.78), Radius.circular(s * 0.12)));
      case 'd':
        return Path()
          ..moveTo(c.dx, c.dy - s)
          ..lineTo(c.dx + s * 0.8, c.dy)
          ..lineTo(c.dx, c.dy + s)
          ..lineTo(c.dx - s * 0.8, c.dy)
          ..close();
      case 'h':
        return Path()..addPolygon([for (var i = 0; i < 6; i++) c + Offset.fromDirection(math.pi / 6 + i * math.pi / 3, s * 0.92)], true);
      default:
        return Path()..addOval(Rect.fromCircle(center: c, radius: s * 0.82));
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    final p = path(kind, r);
    final col = colors[kind] ?? Lux.gold;
    canvas.drawPath(
      p,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.3, -0.4),
          colors: [Color.lerp(col, Colors.white, 0.35)!, col, Color.lerp(col, Colors.black, 0.4)!],
          stops: const [0, 0.55, 1],
        ).createShader(r),
    );
    canvas.drawPath(
      p,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, size.shortestSide * 0.05)
        ..color = Colors.white.withValues(alpha: 0.75),
    );
  }

  @override
  bool shouldRepaint(ShapePainter old) => old.kind != kind;
}

class _CircledPlus extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 1.5;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Lux.goldLight;
    canvas.drawCircle(c, r, p);
    canvas.drawLine(c - Offset(r * 0.55, 0), c + Offset(r * 0.55, 0), p);
    canvas.drawLine(c - Offset(0, r * 0.55), c + Offset(0, r * 0.55), p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ------------------------------------------------------------------ painters

void _label(Canvas canvas, String s, Offset c, double size, {bool hot = false}) {
  final q = s == '?';
  final tp = TextPainter(
    text: TextSpan(
      text: s,
      style: TextStyle(
        fontFamily: 'Cormorant',
        fontSize: size,
        fontWeight: FontWeight.w700,
        color: q || hot ? Lux.goldLight : Lux.ink,
        height: 1,
        fontFeatures: const [FontFeature.liningFigures()],
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  if (q) {
    canvas.drawCircle(c, size * 0.62, Paint()..color = Lux.gold.withValues(alpha: 0.18));
    canvas.drawCircle(
        c,
        size * 0.62,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3
          ..color = Lux.gold);
  }
  tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
}

Paint _line([double w = 1.6]) => Paint()
  ..style = PaintingStyle.stroke
  ..strokeWidth = w
  ..strokeJoin = StrokeJoin.round
  ..color = Lux.gold.withValues(alpha: 0.75);

Paint get _fill => Paint()..color = const Color(0x26000000);

class _TrianglePainter extends CustomPainter {
  final Map<String, dynamic> t;
  final bool inverted;
  _TrianglePainter(this.t, {required this.inverted});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final f = w * 0.15;
    if (!inverted) {
      final top = Offset(w / 2, h * 0.06), l = Offset(w * 0.06, h * 0.94), r = Offset(w * 0.94, h * 0.94);
      final p = Path()..addPolygon([top, r, l], true);
      canvas.drawPath(p, _fill);
      canvas.drawPath(p, _line());
      _label(canvas, '${t['top']}', Offset(w / 2, h * 0.30), f);
      _label(canvas, '${t['left']}', Offset(w * 0.24, h * 0.80), f);
      _label(canvas, '${t['right']}', Offset(w * 0.76, h * 0.80), f);
      _label(canvas, '${t['mid']}', Offset(w / 2, h * 0.63), f * 1.15, hot: true);
    } else {
      final l = Offset(w * 0.06, h * 0.06), r = Offset(w * 0.94, h * 0.06), b = Offset(w / 2, h * 0.94);
      final p = Path()..addPolygon([l, r, b], true);
      canvas.drawPath(p, _fill);
      canvas.drawPath(p, _line());
      _label(canvas, '${t['left']}', Offset(w * 0.27, h * 0.22), f);
      _label(canvas, '${t['right']}', Offset(w * 0.73, h * 0.22), f);
      _label(canvas, '${t['bottom']}', Offset(w / 2, h * 0.58), f * 1.15, hot: true);
    }
  }

  @override
  bool shouldRepaint(_TrianglePainter old) => old.t != t;
}

class _DiamondPainter extends CustomPainter {
  final Map<String, dynamic> t;
  _DiamondPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final c = Offset(w / 2, w / 2);
    final r = w * 0.46;
    final pts = [c + Offset(0, -r), c + Offset(r, 0), c + Offset(0, r), c + Offset(-r, 0)];
    final p = Path()..addPolygon(pts, true);
    canvas.drawPath(p, _fill);
    canvas.drawPath(p, _line());
    canvas.drawLine(pts[0], pts[2], _line(1));
    canvas.drawLine(pts[1], pts[3], _line(1));
    final f = w * 0.14;
    _label(canvas, '${t['top']}', c + Offset(0, -r * 0.5), f);
    _label(canvas, '${t['bottom']}', c + Offset(0, r * 0.5), f);
    _label(canvas, '${t['left']}', c + Offset(-r * 0.5, 0), f);
    _label(canvas, '${t['right']}', c + Offset(r * 0.5, 0), f);
  }

  @override
  bool shouldRepaint(_DiamondPainter old) => old.t != t;
}

class _CornersPainter extends CustomPainter {
  final Map<String, dynamic> t;
  _CornersPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final rect = Rect.fromLTWH(w * 0.2, w * 0.2, w * 0.6, w * 0.6);
    canvas.drawRect(rect, _fill);
    canvas.drawRect(rect, _line());
    final f = w * 0.13;
    _label(canvas, '${t['tl']}', Offset(w * 0.1, w * 0.1), f);
    _label(canvas, '${t['tr']}', Offset(w * 0.9, w * 0.1), f);
    _label(canvas, '${t['br']}', Offset(w * 0.9, w * 0.9), f);
    _label(canvas, '${t['bl']}', Offset(w * 0.1, w * 0.9), f);
    _label(canvas, '${t['mid']}', Offset(w / 2, w / 2), f * 1.15, hot: true);
  }

  @override
  bool shouldRepaint(_CornersPainter old) => old.t != t;
}

class _WheelPainter extends CustomPainter {
  final List<String> ring;
  final String? center;
  _WheelPainter(this.ring, this.center);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 3;
    final inner = center == null ? 0.0 : r * 0.34;
    final n = math.max(ring.length, 1);
    canvas.drawCircle(c, r, _fill);
    canvas.drawCircle(c, r, _line());
    for (var i = 0; i < n; i++) {
      final a = -math.pi / 2 + (i - 0.5) * 2 * math.pi / n;
      canvas.drawLine(c + Offset.fromDirection(a, inner), c + Offset.fromDirection(a, r), _line(1.1));
    }
    if (center != null) {
      canvas.drawCircle(c, inner, Paint()..color = Lux.gold.withValues(alpha: 0.12));
      canvas.drawCircle(c, inner, _line());
      _label(canvas, center!, c, r * 0.24, hot: true);
    }
    for (var i = 0; i < ring.length; i++) {
      final a = -math.pi / 2 + i * 2 * math.pi / n;
      _label(canvas, ring[i], c + Offset.fromDirection(a, (r + inner) / 2 + (center == null ? r * 0.12 : 0)), r * 0.19);
    }
  }

  @override
  bool shouldRepaint(_WheelPainter old) => old.ring != ring || old.center != center;
}

class _StarPainter extends CustomPainter {
  final List<String> tips;
  final List<String> wedges;
  _StarPainter(this.tips, this.wedges);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final n = math.max(tips.length, 1);
    final rayEnd = r * 0.70;
    final hub = r * 0.12;
    canvas.drawCircle(c, hub, _line(1.4));
    for (var i = 0; i < n; i++) {
      final a = -math.pi / 2 + i * 2 * math.pi / n;
      canvas.drawLine(c + Offset.fromDirection(a, hub), c + Offset.fromDirection(a, rayEnd), _line(1.8));
      _label(canvas, tips[i], c + Offset.fromDirection(a, r * 0.86), r * 0.16, hot: tips[i] == '?');
    }
    for (var i = 0; i < wedges.length; i++) {
      final a = -math.pi / 2 + (i + 0.5) * 2 * math.pi / n;
      _label(canvas, wedges[i], c + Offset.fromDirection(a, r * 0.42), r * 0.14);
    }
  }

  @override
  bool shouldRepaint(_StarPainter old) => old.tips != tips || old.wedges != wedges;
}

class _ClockPainter extends CustomPainter {
  final int h, m;
  _ClockPainter(this.h, this.m);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 3;
    canvas.drawCircle(c, r, Paint()..color = const Color(0x33000000));
    canvas.drawCircle(c, r, _line(2));
    for (var i = 0; i < 60; i++) {
      final a = i * math.pi / 30;
      final big = i % 5 == 0;
      canvas.drawLine(c + Offset.fromDirection(a, r * (big ? 0.84 : 0.92)), c + Offset.fromDirection(a, r * 0.97), _line(big ? 2 : 0.8));
    }
    for (var i = 1; i <= 12; i++) {
      final a = -math.pi / 2 + i * math.pi / 6;
      _label(canvas, '$i', c + Offset.fromDirection(a, r * 0.70), r * 0.16);
    }
    final ma = -math.pi / 2 + m * math.pi / 30;
    final ha = -math.pi / 2 + ((h % 12) + m / 60) * math.pi / 6;
    final hand = Paint()
      ..strokeCap = StrokeCap.round
      ..color = Lux.goldLight;
    canvas.drawLine(c, c + Offset.fromDirection(ha, r * 0.5), hand..strokeWidth = r * 0.07);
    canvas.drawLine(c, c + Offset.fromDirection(ma, r * 0.78), hand..strokeWidth = r * 0.04);
    canvas.drawCircle(c, r * 0.05, Paint()..color = Lux.gold);
  }

  @override
  bool shouldRepaint(_ClockPainter old) => old.h != h || old.m != m;
}

/// One balance scale: beam on a post, a pan of shapes at each end; the asked one shows "?".
class _ScaleView extends StatelessWidget {
  final List<String> left;
  final List<String> right;
  final bool asking;
  const _ScaleView({required this.left, required this.right, required this.asking});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      final pan = w * 0.40;
      Widget group(List<String> g) {
        if (g.length == 1 && g.first == '?') return const _Chip('?', minWidth: 40, height: 36);
        final size = math.min(28.0, pan / math.max(g.length, 1) - 3);
        return Wrap(spacing: 2, alignment: WrapAlignment.center, children: [for (final s in g) ShapeGlyph(s, size: size)]);
      }

      return Stack(
        children: [
          Positioned.fill(child: CustomPaint(painter: _BeamPainter(asking))),
          Positioned(left: 0, width: pan, top: 4, height: 46, child: Center(child: group(left))),
          Positioned(right: 0, width: pan, top: 4, height: 46, child: Center(child: group(right))),
        ],
      );
    });
  }
}

class _BeamPainter extends CustomPainter {
  final bool asking;
  _BeamPainter(this.asking);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final p = _line(2.2);
    if (asking) p.color = Lux.goldLight;
    final beamY = h * 0.62;
    canvas.drawLine(Offset(w * 0.05, beamY), Offset(w * 0.95, beamY), p);
    canvas.drawLine(Offset(w / 2, beamY), Offset(w / 2, h * 0.95), p);
    canvas.drawLine(Offset(w * 0.42, h * 0.95), Offset(w * 0.58, h * 0.95), p);
    final tri = Path()
      ..moveTo(w / 2, beamY - 7)
      ..lineTo(w / 2 + 7, beamY + 4)
      ..lineTo(w / 2 - 7, beamY + 4)
      ..close();
    canvas.drawPath(tri, Paint()..color = Lux.gold);
    for (final x in [w * 0.20, w * 0.80]) {
      final pan = Path()
        ..moveTo(x - w * 0.17, beamY - 4)
        ..quadraticBezierTo(x, beamY + 10, x + w * 0.17, beamY - 4);
      canvas.drawPath(pan, p);
    }
  }

  @override
  bool shouldRepaint(_BeamPainter old) => old.asking != asking;
}
