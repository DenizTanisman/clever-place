import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// Shikaku board. Drag from one corner to the opposite corner to draw a rectangle (live preview
/// shows its area: gold = exactly one number and the area matches, bordeaux = not). A rectangle
/// drawn over others replaces them. Tap a rectangle to remove it; tap an empty "1" to box it.
///
/// Everything above the static grid is one [CustomPainter] fed by a [_ShikakuFx] model; a
/// [Ticker] runs only while something moves. Motion:
/// * the drag preview's corners glide after the finger (≈80 ms) inside a marching dashed border;
/// * a released rectangle snaps from the preview into place with a slight overshoot and a soft
///   colour wash spreading from where the drag began; a rectangle that matches no number shakes
///   and flashes bordeaux; a release that places nothing shakes and fades out;
/// * removed / replaced rectangles shrink away;
/// * a number whose rectangle is right gets a small gold check and a ring of light;
/// * the hint rectangle pulses gold; winning plays a diagonal wave of light.
Widget shikakuView(BuildContext context, GameSession s) => _ShikakuBoard(session: s);

const double _tauFollow = 0.027; // ≈80 ms to catch up with the finger
const double _snapDur = 0.28;
const double _washDur = 0.36;
const double _badDur = 0.40;
const double _ghostDur = 0.38;
const double _outDur = 0.20;
const double _checkDelay = 0.12;
const double _checkDur = 0.42;
const double _winSpan = 0.55;
const double _winCell = 0.32;

class _ShikakuBoard extends StatefulWidget {
  final GameSession session;
  const _ShikakuBoard({required this.session});

  @override
  State<_ShikakuBoard> createState() => _ShikakuBoardState();
}

/// Soft jewel tints for placed rectangles.
const _tints = [
  Color(0xFF2E8B6E), // emerald
  Color(0xFF3A5BA8), // sapphire
  Color(0xFF8A4FB0), // amethyst
  Color(0xFFB0445E), // ruby
  Color(0xFFC08A3A), // topaz
  Color(0xFF2F9AA8), // aquamarine
  Color(0xFF7FA83A), // peridot
  Color(0xFFB06A8A), // rose quartz
];

class _R {
  final int r0, c0, r1, c1;
  const _R(this.r0, this.c0, this.r1, this.c1);
  int get area => (r1 - r0 + 1) * (c1 - c0 + 1);
  bool contains(int r, int c) => r >= r0 && r <= r1 && c >= c0 && c <= c1;
  bool touches(_R o) {
    final rowsOverlap = r0 <= o.r1 && o.r0 <= r1;
    final colsOverlap = c0 <= o.c1 && o.c0 <= c1;
    return (rowsOverlap && (c1 + 1 == o.c0 || o.c1 + 1 == c0)) || (colsOverlap && (r1 + 1 == o.r0 || o.r1 + 1 == r0));
  }

  /// Bounds in cell units (right/bottom exclusive).
  Rect get units => Rect.fromLTRB(c0.toDouble(), r0.toDouble(), c1 + 1.0, r1 + 1.0);

  @override
  bool operator ==(Object o) => o is _R && o.r0 == r0 && o.c0 == c0 && o.r1 == r1 && o.c1 == c1;
  @override
  int get hashCode => Object.hash(r0, c0, r1, c1);
}

class _Placed {
  final _R r;
  final bool ok;
  final Color tint;
  const _Placed(this.r, this.ok, this.tint);
}

class _In {
  final double at;
  final Rect? from; // preview geometry at release (cell units)
  final Offset origin; // where the wash starts (cell units)
  _In(this.at, this.from, this.origin);
}

class _Out {
  final _Placed p;
  final double at;
  _Out(this.p, this.at);
}

class _ShikakuFx extends ChangeNotifier {
  double now = 0;
  int rows = 0, cols = 0;
  List<List<int>> clues = const [];
  List<_Placed> rects = const [];
  List<bool> clueDone = const [];
  _R? hint;

  // Drag preview.
  _R? target;
  bool valid = false;
  Rect vis = Rect.zero;
  double alpha = 0;

  final ins = <_R, _In>{};
  final bad = <_R, double>{};
  final outs = <_Out>[];
  Rect? ghost;
  double ghostAt = -10;
  final clueAt = <int, double>{};
  double winAt = -1;

  void repaint() => notifyListeners();

  bool step(double dt) {
    var moving = false;
    final t = target;
    if (t != null) {
      final k = 1 - math.exp(-dt / _tauFollow);
      final goal = t.units;
      double ch(double v, double g) {
        final d = g - v;
        if (d.abs() < 0.002) return g;
        moving = true;
        return v + d * k;
      }

      vis = Rect.fromLTRB(ch(vis.left, goal.left), ch(vis.top, goal.top), ch(vis.right, goal.right), ch(vis.bottom, goal.bottom));
      alpha = alpha + (1 - alpha) * (1 - math.exp(-dt / 0.03));
      if (alpha > 0.995) alpha = 1;
      moving = true; // marching dashes while a drag is live
    }
    ins.removeWhere((_, v) => now - v.at > math.max(_snapDur, _washDur));
    bad.removeWhere((_, at) => now - at > _badDur);
    outs.removeWhere((o) => now - o.at > _outDur);
    if (ghost != null && now - ghostAt > _ghostDur) ghost = null;
    clueAt.removeWhere((_, at) => now - at > _checkDelay + _checkDur);
    final winning = winAt >= 0 && now < winAt + _winSpan + _winCell;
    return moving || ins.isNotEmpty || bad.isNotEmpty || outs.isNotEmpty || ghost != null || clueAt.isNotEmpty || winning || hint != null;
  }

  double pulse([double hz = 0.9]) => 0.5 + 0.5 * math.sin(now * 2 * math.pi * hz);
}

class _ShikakuBoardState extends State<_ShikakuBoard> with SingleTickerProviderStateMixin {
  (int, int)? _dragStart;
  (int, int)? _dragEnd;

  final _ShikakuFx _fx = _ShikakuFx();
  final _Glyphs _glyphs = _Glyphs();
  late final Ticker _ticker = createTicker((_) => _onTick());
  final Stopwatch _watch = Stopwatch()..start();
  double get _now => _watch.elapsedMicroseconds / 1e6;
  double _lastTick = 0;

  Map<String, dynamic>? _seen;
  List<_Placed>? _prevRects;
  List<bool> _prevDone = const [];
  bool _prevWon = false;
  // Set at release so the next state's new rectangle animates out of the preview.
  Rect? _releaseFrom;
  Offset? _releaseOrigin;

  GameSession get s => widget.session;

  @override
  void didUpdateWidget(covariant _ShikakuBoard old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      _dragStart = _dragEnd = null;
      _seen = null;
      _prevRects = null;
      _fx
        ..target = null
        ..alpha = 0
        ..ins.clear()
        ..bad.clear()
        ..outs.clear()
        ..ghost = null
        ..clueAt.clear()
        ..winAt = -1;
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _fx.dispose();
    super.dispose();
  }

  void _kick() {
    if (!_ticker.isActive) {
      _lastTick = _now;
      _ticker.start();
    }
  }

  void _onTick() {
    final now = _now;
    final dt = (now - _lastTick).clamp(0.0, 0.05);
    _lastTick = now;
    _fx.now = now;
    final busy = _fx.step(dt);
    _fx.repaint();
    if (!busy) _ticker.stop();
  }

  _R? get _preview {
    final a = _dragStart, b = _dragEnd;
    if (a == null || b == null) return null;
    return _R(math.min(a.$1, b.$1), math.min(a.$2, b.$2), math.max(a.$1, b.$1), math.max(a.$2, b.$2));
  }

  (int, int)? _cellAt(Offset p, double cell, int rows, int cols) {
    final r = (p.dy / cell).floor(), c = (p.dx / cell).floor();
    if (r < 0 || c < 0 || r >= rows || c >= cols) return null;
    return (r, c);
  }

  (int, int) _clampCell(Offset p, double cell, int rows, int cols) =>
      ((p.dy / cell).floor().clamp(0, rows - 1), (p.dx / cell).floor().clamp(0, cols - 1));

  bool _isValid(_R r, List<List<int>> clues) {
    final inside = clues.where((c) => r.contains(c[0], c[1])).toList();
    return inside.length == 1 && inside.first[2] == r.area;
  }

  /// The preview did not become a rectangle: it shakes and fades where it was.
  void _reject() {
    final now = _now;
    _fx
      ..ghost = _fx.vis
      ..ghostAt = now
      ..now = now;
    HapticFeedback.mediumImpact();
    _kick();
  }

  void _sync(int rows, int cols, List<List<int>> clues, List<_Placed> rects, _R? hint, bool won) {
    final now = _now;
    final fx = _fx..now = now;
    final st = s.state;
    if (!identical(st, _seen)) {
      _seen = st;
      final done = [
        for (final c in clues) rects.any((p) => p.ok && p.r.contains(c[0], c[1])),
      ];
      final prev = _prevRects;
      if (prev != null && fx.rows == rows && fx.cols == cols) {
        final before = {for (final p in prev) p.r};
        final after = {for (final p in rects) p.r};
        for (final p in prev) {
          if (!after.contains(p.r)) fx.outs.add(_Out(p, now));
        }
        var placedBad = false, placedOk = false;
        for (final p in rects) {
          if (before.contains(p.r)) continue;
          final from = _releaseFrom;
          fx.ins[p.r] = _In(now, from, _releaseOrigin ?? p.r.units.center);
          if (p.ok) {
            placedOk = true;
          } else {
            fx.bad[p.r] = now;
            placedBad = true;
          }
        }
        if (placedBad) {
          HapticFeedback.mediumImpact();
        } else if (placedOk) {
          HapticFeedback.lightImpact();
        }
        if (_prevDone.length == done.length) {
          for (var k = 0; k < done.length; k++) {
            if (done[k] && !_prevDone[k]) fx.clueAt[k] = now;
          }
        }
        if (won && !_prevWon) fx.winAt = now + 0.22;
      }
      if (!won) fx.winAt = -1;
      _releaseFrom = null;
      _releaseOrigin = null;
      _prevRects = rects;
      _prevDone = done;
      _prevWon = won;
      fx.clueDone = done;
    }
    fx.rows = rows;
    fx.cols = cols;
    fx.clues = clues;
    fx.rects = rects;
    fx.hint = hint;

    final p = _preview;
    if (p != null) {
      if (fx.target == null) {
        fx.vis = p.units;
        fx.alpha = 0;
      }
      fx.target = p;
      fx.valid = _isValid(p, clues);
    } else {
      fx.target = null;
      fx.alpha = 0;
    }
    if (fx.step(0)) _kick();
  }

  @override
  Widget build(BuildContext context) {
    final st = s.state;
    final rows = (st['rows'] as num).toInt();
    final cols = (st['cols'] as num).toInt();
    final clues = [
      for (final c in st['clues'] as List) [for (final v in c as List) (v as num).toInt()]
    ];
    final raw = <(_R, bool)>[
      for (final m in st['rects'] as List)
        (
          _R((m['r0'] as num).toInt(), (m['c0'] as num).toInt(), (m['r1'] as num).toInt(), (m['c1'] as num).toInt()),
          m['ok'] == true
        )
    ];
    final hint = st['hint'] is Map ? st['hint'] as Map : null;
    final hintRect = hint == null
        ? null
        : (() {
            final v = [for (final x in hint['rect'] as List) (x as num).toInt()];
            return _R(v[0], v[1], v[2], v[3]);
          })();
    final tints = _assignTints(raw.map((e) => e.$1).toList(), clues);
    final rects = [for (var k = 0; k < raw.length; k++) _Placed(raw[k].$1, raw[k].$2, tints[k])];
    _sync(rows, cols, clues, rects, hintRect, st['status'] == 'won');

    return Column(
      children: [
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _stat('Kaplanan', '${st['covered']}/${st['total']}'),
            const SizedBox(width: 28),
            _stat('İpucu', '${st['hints']}'),
            const SizedBox(width: 28),
            _stat('Hatalı', '${st['mistakes']}'),
          ],
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: hint == null
              ? const SizedBox(width: double.infinity, height: 8)
              : Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: _banner(hint['text'] as String),
                ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 12, 10, 0),
            child: LayoutBuilder(builder: (context, box) {
              final cell = math.min(box.maxWidth / cols, box.maxHeight / rows);
              final w = cell * cols, h = cell * rows;
              return Center(
                child: SizedBox(
                  width: w,
                  height: h,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: s.finished
                        ? null
                        : (d) {
                            final rc = _cellAt(d.localPosition, cell, rows, cols);
                            if (rc == null) return;
                            if (rects.any((e) => e.r.contains(rc.$1, rc.$2))) {
                              HapticFeedback.selectionClick();
                              s.act({'remove_at': [rc.$1, rc.$2]});
                            } else if (clues.any((c) => c[0] == rc.$1 && c[1] == rc.$2 && c[2] == 1)) {
                              // A stray tap elsewhere is ignored so it never counts as a mistake.
                              _releaseOrigin = Offset(rc.$2 + 0.5, rc.$1 + 0.5);
                              s.act({'place': [rc.$1, rc.$2, rc.$1, rc.$2]});
                            }
                          },
                    onPanStart: s.finished
                        ? null
                        : (d) {
                            final rc = _cellAt(d.localPosition, cell, rows, cols);
                            if (rc == null) return;
                            HapticFeedback.selectionClick();
                            setState(() {
                              _dragStart = rc;
                              _dragEnd = rc;
                            });
                          },
                    onPanUpdate: (d) {
                      if (_dragStart == null) return;
                      final rc = _clampCell(d.localPosition, cell, rows, cols);
                      if (rc != _dragEnd) {
                        HapticFeedback.selectionClick();
                        setState(() => _dragEnd = rc);
                      }
                    },
                    onPanEnd: (_) {
                      final p = _preview;
                      final start = _dragStart;
                      final from = _fx.vis;
                      setState(() {
                        _dragStart = null;
                        _dragEnd = null;
                      });
                      if (p == null || s.finished) return;
                      // A jittery 1×1 "drag" off a 1-clue is treated like a stray tap.
                      if (p.area == 1 && !clues.any((c) => c[0] == p.r0 && c[1] == p.c0 && c[2] == 1)) {
                        _reject();
                        return;
                      }
                      _releaseFrom = from;
                      _releaseOrigin = start == null ? null : Offset(start.$2 + 0.5, start.$1 + 0.5);
                      if (!s.act({'place': [p.r0, p.c0, p.r1, p.c1]})) {
                        _releaseFrom = null;
                        _releaseOrigin = null;
                        _reject();
                      }
                    },
                    onPanCancel: () => setState(() {
                      _dragStart = null;
                      _dragEnd = null;
                    }),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: [BoxShadow(color: Lux.gold.withValues(alpha: 0.10), blurRadius: 22)],
                      ),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned.fill(child: CustomPaint(painter: _GridPainter(rows, cols, cell))),
                          Positioned.fill(
                            child: RepaintBoundary(child: CustomPaint(painter: _BoardPainter(_fx, _glyphs))),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              RimIconButton(Icons.undo_rounded,
                  tooltip: 'Geri al', onPressed: st['can_undo'] == true && !s.finished ? () => s.act({'undo': true}) : null),
              const SizedBox(width: 24),
              RimIconButton(Icons.lightbulb_outline_rounded,
                  tooltip: 'İpucu: doğru bir dikdörtgen', onPressed: s.finished ? null : () => s.act({'hint': true})),
            ],
          ),
        ),
      ],
    );
  }

  /// Stable, neighbour-aware tints: start from the tint of the number inside, step past tints
  /// already used by touching rectangles.
  List<Color> _assignTints(List<_R> rects, List<List<int>> clues) {
    final out = <Color>[];
    for (var k = 0; k < rects.length; k++) {
      final r = rects[k];
      final ci = clues.indexWhere((c) => r.contains(c[0], c[1]));
      var t = (ci < 0 ? k : ci * 3) % _tints.length;
      final used = <Color>{
        for (var j = 0; j < k; j++)
          if (rects[j].touches(r)) out[j]
      };
      for (var tries = 0; tries < _tints.length && used.contains(_tints[t]); tries++) {
        t = (t + 1) % _tints.length;
      }
      out.add(_tints[t]);
    }
    return out;
  }

  Widget _banner(String text) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Lux.gold.withValues(alpha: 0.5)),
          gradient: const LinearGradient(colors: [Color(0xFF2A2012), Color(0xFF15100B)]),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.lightbulb_rounded, color: Lux.gold, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: Lux.ui(14, color: Lux.ink, weight: FontWeight.w500))),
          ],
        ),
      );

  Widget _stat(String label, String value) => Column(
        children: [
          Text(value, style: Lux.ui(22, color: Lux.goldLight, weight: FontWeight.w700)),
          Text(label, style: Lux.ui(12, color: Lux.muted, spacing: 1)),
        ],
      );
}

/// Laid-out text cache (numbers and the area label).
class _Glyphs {
  final Map<String, TextPainter> _m = {};

  TextPainter get(String text, double size, Color color, FontWeight weight) {
    final key = '$text|${size.toStringAsFixed(1)}|${color.toARGB32()}|${weight.value}';
    final hit = _m[key];
    if (hit != null) return hit;
    if (_m.length > 400) _m.clear();
    return _m[key] = TextPainter(
      text: TextSpan(text: text, style: Lux.ui(size, color: color, weight: weight)),
      textDirection: TextDirection.ltr,
    )..layout();
  }
}

/// Rectangles, preview, ghosts, numbers, checks and the win wave.
class _BoardPainter extends CustomPainter {
  final _ShikakuFx fx;
  final _Glyphs glyphs;
  _BoardPainter(this.fx, this.glyphs) : super(repaint: fx);

  @override
  void paint(Canvas canvas, Size size) {
    final rows = fx.rows, cols = fx.cols;
    if (rows == 0 || cols == 0) return;
    final cell = size.width / cols;
    final now = fx.now;
    Rect px(Rect u) => Rect.fromLTRB(u.left * cell, u.top * cell, u.right * cell, u.bottom * cell);

    // 1 · Rectangles leaving (shrink + fade).
    for (final o in fx.outs) {
      final t = ((now - o.at) / _outDur).clamp(0.0, 1.0);
      final e = Curves.easeInCubic.transform(t);
      final base = px(o.p.r.units).deflate(2);
      final rect = Rect.fromCenter(center: base.center, width: base.width * (1 - 0.2 * e), height: base.height * (1 - 0.2 * e));
      _rect(canvas, rect, cell, o.p.tint, o.p.ok, alpha: 1 - e);
    }

    // 2 · Placed rectangles (snap, wash, bad shake).
    for (final p in fx.rects) {
      final base = px(p.r.units).deflate(2);
      var rect = base;
      var wash = 1.0;
      Offset? origin;
      var flash = 0.0;
      final enter = fx.ins[p.r];
      if (enter != null) {
        final k = now - enter.at;
        final t = (k / _snapDur).clamp(0.0, 1.0);
        final b = Curves.easeOutBack.transform(t);
        final from = enter.from == null
            ? Rect.fromCenter(center: base.center, width: base.width * 0.86, height: base.height * 0.86)
            : px(enter.from!).deflate(1);
        rect = Rect.fromLTRB(
          from.left + (base.left - from.left) * b,
          from.top + (base.top - from.top) * b,
          from.right + (base.right - from.right) * b,
          from.bottom + (base.bottom - from.bottom) * b,
        );
        wash = Curves.easeOutCubic.transform((k / _washDur).clamp(0.0, 1.0));
        origin = enter.origin * cell;
      }
      final bad = fx.bad[p.r];
      if (bad != null) {
        final k = now - bad;
        if (k >= 0 && k < _badDur) {
          rect = rect.shift(Offset(math.sin(k * 2 * math.pi * 9) * cell * 0.09 * math.exp(-k * 8), 0));
          flash = math.exp(-k * 6);
        }
      }
      final isHint = fx.hint == p.r;
      _rect(canvas, rect, cell, p.tint, p.ok,
          wash: wash, origin: origin, flash: flash, highlight: isHint ? fx.pulse() : null);
    }

    // 3 · Hint rectangle that is not on the board: pulsing gold outline.
    final h = fx.hint;
    if (h != null && !fx.rects.any((p) => p.r == h)) {
      final pulse = fx.pulse();
      final rr = RRect.fromRectAndRadius(px(h.units).deflate(2), Radius.circular(cell * 0.18));
      canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..color = Lux.gold.withValues(alpha: 0.25 + 0.35 * pulse)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4 + 4 * pulse),
      );
      _dashed(canvas, rr, Lux.goldLight.withValues(alpha: 0.6 + 0.4 * pulse), 2, now * 14);
    }

    // 4 · Failed release: shakes and fades out.
    final g = fx.ghost;
    if (g != null) {
      final k = now - fx.ghostAt;
      final t = (k / _ghostDur).clamp(0.0, 1.0);
      final rect = px(g).deflate(1).shift(Offset(math.sin(k * 2 * math.pi * 9) * cell * 0.1 * math.exp(-k * 7), 0));
      final a = 1 - Curves.easeInCubic.transform(t);
      final rr = RRect.fromRectAndRadius(rect, Radius.circular(cell * 0.18));
      canvas.drawRRect(rr, Paint()..color = Lux.bordeauxLight.withValues(alpha: 0.22 * a));
      _dashed(canvas, rr, Lux.bordeauxLight.withValues(alpha: a), 2.4, 0);
    }

    // 5 · Live preview.
    if (fx.target != null && fx.alpha > 0.01) {
      final a = fx.alpha;
      final color = fx.valid ? Lux.gold : Lux.bordeauxLight;
      final rect = px(fx.vis).deflate(1);
      final rr = RRect.fromRectAndRadius(rect, Radius.circular(cell * 0.18));
      canvas.drawRRect(
        rr,
        Paint()
          ..color = color.withValues(alpha: 0.35 * a)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      );
      canvas.drawRRect(rr, Paint()..color = color.withValues(alpha: 0.18 * a));
      _dashed(canvas, rr, color.withValues(alpha: a), 2.4, now * 18);
    }

    // 6 · Victory wave over the glass, under the numbers.
    if (fx.winAt >= 0) {
      for (var r = 0; r < rows; r++) {
        for (var c = 0; c < cols; c++) {
          final u = (now - fx.winAt - (r + c) / math.max(1, rows + cols - 2) * _winSpan) / _winCell;
          if (u <= 0 || u >= 1) continue;
          final w = math.sin(math.pi * u);
          final rect = Rect.fromLTWH(c * cell, r * cell, cell, cell).deflate(1);
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, Radius.circular(cell * 0.14)),
            Paint()
              ..shader = RadialGradient(colors: [
                Lux.goldLight.withValues(alpha: 0.55 * w),
                Lux.gold.withValues(alpha: 0.18 * w),
              ]).createShader(rect),
          );
        }
      }
    }

    // 7 · Numbers and the checks of finished rectangles.
    for (var k = 0; k < fx.clues.length; k++) {
      final c = fx.clues[k];
      final center = Offset((c[1] + 0.5) * cell, (c[0] + 0.5) * cell);
      final covered = fx.rects.any((p) => p.r.contains(c[0], c[1]));
      final done = k < fx.clueDone.length && fx.clueDone[k];
      final rad = cell * 0.36;
      final at = fx.clueAt[k];
      final lt = at == null ? 1.0 : ((now - at - _checkDelay) / _checkDur).clamp(0.0, 1.0);
      if (done) {
        canvas.drawCircle(
          center,
          rad * 1.05,
          Paint()
            ..color = Lux.gold.withValues(alpha: 0.28 * Curves.easeOut.transform(lt))
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
        );
      }
      canvas.drawCircle(center, rad, Paint()..color = covered ? Colors.black.withValues(alpha: 0.25) : const Color(0xFF2A2015));
      canvas.drawCircle(
        center,
        rad,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = done ? Lux.gold.withValues(alpha: 0.75) : Lux.gold.withValues(alpha: covered ? 0.35 : 0.7),
      );
      final tp = glyphs.get('${c[2]}', cell * 0.42, covered ? Lux.ink : Lux.goldLight, FontWeight.w800);
      tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
      if (at != null && lt > 0 && lt < 1) {
        // A ring of light leaves the number once.
        canvas.drawCircle(
          center,
          rad * (1 + 0.9 * Curves.easeOutCubic.transform(lt)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.8 + 2 * (1 - lt)
            ..color = Lux.goldLight.withValues(alpha: 0.6 * (1 - lt) * (1 - lt)),
        );
      }
      if (done) _check(canvas, center + Offset(rad * 0.78, -rad * 0.78), cell * 0.13, Curves.easeOutBack.transform(math.min(1.0, lt * 1.7)));
    }

    // 8 · Area label above the preview (kept inside the board).
    if (fx.target != null && fx.alpha > 0.01) {
      const lw = 64.0, lh = 30.0;
      final v = px(fx.vis);
      final bh = size.height, bw = size.width;
      var top = v.top - lh - 6;
      if (top < 0) top = v.bottom + 6;
      if (top + lh > bh) top = v.top + 4;
      final left = (v.center.dx - lw / 2).clamp(0.0, math.max(0.0, bw - lw)).toDouble();
      final rect = Rect.fromLTWH(left, top, lw, lh);
      final rr = RRect.fromRectAndRadius(rect, const Radius.circular(15));
      canvas.drawRRect(rr.shift(const Offset(0, 2)),
          Paint()..color = Colors.black54..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
      canvas.drawRRect(
        rr,
        Paint()
          ..shader = (fx.valid ? Lux.goldGradient : const LinearGradient(colors: [Lux.bordeauxLight, Lux.bordeaux]))
              .createShader(rect),
      );
      final tp = glyphs.get('${fx.target!.area}', 17, fx.valid ? const Color(0xFF1A1206) : Colors.white, FontWeight.w800);
      tp.paint(canvas, rect.center - Offset(tp.width / 2, tp.height / 2));
    }
  }

  void _rect(Canvas canvas, Rect rect, double cell, Color tint, bool ok,
      {double alpha = 1, double wash = 1, Offset? origin, double flash = 0, double? highlight}) {
    if (alpha <= 0.01) return;
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(cell * 0.18));
    final hl = highlight ?? 0;
    final glow = highlight != null ? Lux.gold.withValues(alpha: (0.35 + 0.35 * hl) * alpha) : !ok ? Lux.bordeaux.withValues(alpha: (0.5 + 0.4 * flash) * alpha) : null;
    if (glow != null) {
      canvas.drawRRect(rr, Paint()..color = glow..maskFilter = MaskFilter.blur(BlurStyle.normal, highlight != null ? 10 + 6 * hl : 6));
    }
    // Colour wash: the fill spreads from the drag origin as a soft disc.
    final fill = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [tint.withValues(alpha: 0.55 * alpha), tint.withValues(alpha: 0.28 * alpha)],
      ).createShader(rect);
    if (wash < 1 && origin != null) {
      final far = [rect.topLeft, rect.topRight, rect.bottomLeft, rect.bottomRight]
          .map((p) => (p - origin).distance)
          .reduce(math.max);
      canvas.save();
      canvas.clipRRect(rr);
      canvas.drawCircle(origin, far * wash + 1, fill);
      // A brighter leading edge of the wash.
      canvas.drawCircle(
        origin,
        far * wash + 1,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = cell * 0.35
          ..color = Color.lerp(tint, Colors.white, 0.4)!.withValues(alpha: 0.28 * (1 - wash) * alpha)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, cell * 0.12),
      );
      canvas.restore();
    } else {
      canvas.drawRRect(rr, fill);
    }
    if (flash > 0.01) canvas.drawRRect(rr, Paint()..color = Lux.bordeaux.withValues(alpha: 0.45 * flash * alpha));
    final border = highlight != null
        ? Lux.goldLight
        : ok
            ? Lux.gold.withValues(alpha: 0.85)
            : Lux.bordeauxLight;
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = highlight != null ? 2.6 : 1.6
        ..color = border.withValues(alpha: border.a * alpha),
    );
  }

  /// Dashed outline; [phase] in logical pixels makes the dashes march.
  void _dashed(Canvas canvas, RRect rr, Color color, double width, double phase) {
    const dash = 7.0, gap = 5.0;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..color = color;
    final path = Path()..addRRect(rr);
    for (final m in path.computeMetrics()) {
      var d = -(phase % (dash + gap));
      while (d < m.length) {
        final a = math.max(0.0, d), b = math.min(m.length, d + dash);
        if (b > a) canvas.drawPath(m.extractPath(a, b), paint);
        d += dash + gap;
      }
    }
  }

  /// Small gold medal with a check mark; [t] is its pop-in scale.
  void _check(Canvas canvas, Offset c, double r, double t) {
    if (t <= 0.01) return;
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.scale(t);
    canvas.drawCircle(const Offset(0, 1), r, Paint()..color = Colors.black.withValues(alpha: 0.45)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5));
    canvas.drawCircle(Offset.zero, r, Paint()..shader = Lux.goldGradient.createShader(Rect.fromCircle(center: Offset.zero, radius: r)));
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.2, r * 0.32)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = const Color(0xFF1A1206);
    canvas.drawPath(
      Path()
        ..moveTo(-r * 0.45, 0)
        ..lineTo(-r * 0.1, r * 0.38)
        ..lineTo(r * 0.5, -r * 0.35),
      p,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BoardPainter old) => true;
}

class _GridPainter extends CustomPainter {
  final int rows, cols;
  final double cell;
  _GridPainter(this.rows, this.cols, this.cell);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & Size(cols * cell, rows * cell);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(8)), Paint()..color = const Color(0xFF15100B));
    final dot = Paint()..color = Lux.gold.withValues(alpha: 0.10);
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(c * cell + 1, r * cell + 1, cell - 2, cell - 2), Radius.circular(cell * 0.14)),
          Paint()..color = const Color(0xFF1C150E),
        );
        canvas.drawCircle(Offset((c + 0.5) * cell, (r + 0.5) * cell), 1.2, dot);
      }
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = Lux.gold.withValues(alpha: 0.55),
    );
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.rows != rows || old.cols != cols || old.cell != cell;
}
