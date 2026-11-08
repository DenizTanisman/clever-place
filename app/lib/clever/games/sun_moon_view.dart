import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// Güneş & Ay board. Tap a cell to cycle empty → sun → moon → empty; long-press clears it.
/// Rule breaks (three in a row, too many of one symbol in a line, a broken =/× sign) glow bordeaux.
/// Breaks caused by the cell being edited are held back while it is cycled (sun is the way to moon):
/// they show once another cell is tapped or [_holdFor] passes without a further tap there. The core
/// reports those held-back sets in `deferred`; mistakes are only counted by the core on leaving a cell.
///
/// The board is a single [CustomPainter] fed by a [_SunMoonFx] model; a [Ticker] runs only while
/// something animates. Events are derived by diffing consecutive `state` maps:
/// * a sun spins in a quarter turn, a moon swings in like a pendulum (easeOutBack); the symbol
///   being replaced spins / sinks away at the same time, so cycling reads as one motion;
/// * new rule breaks shake gently, then cells, lines and signs keep pulsing bordeaux until fixed;
/// * a full, rule-abiding row or column shimmers outward from the last symbol;
/// * the hint cell pulses gold; winning plays a diagonal wave of light.
Widget sunMoonView(BuildContext context, GameSession s) => _SunMoonBoard(session: s);

const double _inDur = 0.25;
const double _outDur = 0.15;
const double _shakeDur = 0.38;
const double _sweepCell = 0.30;
const double _sweepStep = 0.04;
const double _winSpan = 0.55;
const double _winCell = 0.32;
const double _tau = 0.06;
const Duration _holdFor = Duration(milliseconds: 1500);

class _SunMoonBoard extends StatefulWidget {
  final GameSession session;
  const _SunMoonBoard({required this.session});

  @override
  State<_SunMoonBoard> createState() => _SunMoonBoardState();
}

class _Sym {
  final int value;
  final double at;
  _Sym(this.value, this.at);
}

class _Sweep {
  final List<int> cells;
  final List<double> delay;
  final bool row;
  final double start;
  _Sweep(this.cells, this.delay, this.row, this.start);
  double get end => start + delay.fold<double>(0, math.max) + _sweepCell;
}

class _SunMoonFx extends ChangeNotifier {
  double now = 0;
  int n = 0;
  List<int> cells = const [];
  List<bool> fixed = const [];
  List<List> edges = const [];
  int? hintCell;

  List<double> bad = const [], badT = const [];
  List<double> row = const [], rowT = const [];
  List<double> col = const [], colT = const [];
  List<double> edge = const [], edgeT = const [];

  final symIn = <int, _Sym>{};
  final symOut = <int, _Sym>{};
  final shake = <int, (double, double)>{}; // cell → (start, strength)
  final sweeps = <_Sweep>[];
  double winAt = -1;

  void resize(int n, int edgeCount) {
    if (this.n == n && bad.length == n * n && edge.length == edgeCount) return;
    this.n = n;
    bad = List.filled(n * n, 0);
    badT = List.filled(n * n, 0);
    row = List.filled(n, 0);
    rowT = List.filled(n, 0);
    col = List.filled(n, 0);
    colT = List.filled(n, 0);
    edge = List.filled(edgeCount, 0);
    edgeT = List.filled(edgeCount, 0);
    symIn.clear();
    symOut.clear();
    shake.clear();
    sweeps.clear();
    winAt = -1;
  }

  void repaint() => notifyListeners();

  static bool _chase(List<double> v, List<double> t, double k) {
    var moving = false;
    for (var i = 0; i < v.length; i++) {
      final d = t[i] - v[i];
      if (d == 0) continue;
      if (d.abs() < 0.004) {
        v[i] = t[i];
      } else {
        v[i] += d * k;
        moving = true;
      }
    }
    return moving;
  }

  void settle() {
    bad.setAll(0, badT);
    row.setAll(0, rowT);
    col.setAll(0, colT);
    edge.setAll(0, edgeT);
  }

  bool get pulsing =>
      badT.any((v) => v > 0) || rowT.any((v) => v > 0) || colT.any((v) => v > 0) || edgeT.any((v) => v > 0) || hintCell != null;

  bool step(double dt) {
    final k = 1 - math.exp(-dt / _tau);
    var moving = _chase(bad, badT, k);
    moving |= _chase(row, rowT, k);
    moving |= _chase(col, colT, k);
    moving |= _chase(edge, edgeT, k);
    symIn.removeWhere((_, s) => now - s.at > _inDur);
    symOut.removeWhere((_, s) => now - s.at > _outDur);
    shake.removeWhere((_, s) => now - s.$1 > _shakeDur);
    sweeps.removeWhere((s) => now > s.end);
    final winning = winAt >= 0 && now < winAt + _winSpan + _winCell;
    return moving || symIn.isNotEmpty || symOut.isNotEmpty || shake.isNotEmpty || sweeps.isNotEmpty || winning || pulsing;
  }

  double pulse([double hz = 1.1]) => 0.5 + 0.5 * math.sin(now * 2 * math.pi * hz);

  double win(int r, int c) {
    if (winAt < 0) return 0;
    final u = (now - winAt - (r + c) / math.max(1, 2 * n - 2) * _winSpan) / _winCell;
    return u <= 0 || u >= 1 ? 0 : math.sin(math.pi * u);
  }
}

class _SunMoonBoardState extends State<_SunMoonBoard> with SingleTickerProviderStateMixin {
  final _SunMoonFx _fx = _SunMoonFx();
  late final Ticker _ticker = createTicker((_) => _onTick());
  final Stopwatch _watch = Stopwatch()..start();
  double get _now => _watch.elapsedMicroseconds / 1e6;
  double _lastTick = 0;

  Map<String, dynamic>? _seen;
  List<int>? _prevCells;
  Set<int> _prevBad = const {}, _prevBadRows = const {}, _prevBadCols = const {};
  List<bool> _prevDone = const [];
  bool _prevWon = false;
  bool _seenHeld = false;

  /// Cell the player is cycling right now; its rule breaks stay hidden until [_editTimer] fires.
  int? _editCell;
  Timer? _editTimer;

  GameSession get s => widget.session;

  @override
  void didUpdateWidget(covariant _SunMoonBoard old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      _seen = null;
      _prevCells = null;
      _fx.resize(0, 0);
      _endEdit();
    }
  }

  @override
  void dispose() {
    _editTimer?.cancel();
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

  /// The player touched cell [i]: hold back its rule breaks, restarting the grace period.
  void _beginEdit(int i) {
    _editCell = i;
    _editTimer?.cancel();
    _editTimer = Timer(_holdFor, () {
      if (!mounted) return;
      setState(() => _editCell = null);
    });
  }

  void _endEdit() {
    _editTimer?.cancel();
    _editTimer = null;
    _editCell = null;
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

  /// [badCells]… are the breaks on display (possibly with the edited cell's held back); [liveCells]…
  /// are the real ones, so a line never shimmers as finished while a held-back break sits in it.
  void _sync(int n, List<int> cells, List<bool> fixed, List<List> edges, Set<int> badCells, Set<int> badRows,
      Set<int> badCols, Set<int> badEdges, Set<int> liveCells, Set<int> liveRows, Set<int> liveCols, bool held,
      int? hintCell, bool won) {
    final now = _now;
    final fx = _fx..now = now;
    final prev = _prevCells;
    final first = prev == null || prev.length != n * n || fx.n != n;
    fx.resize(n, edges.length);

    final st = s.state;
    // Re-diff on a new state and also when held-back breaks are revealed (timer), so they shake.
    if (!identical(st, _seen) || held != _seenHeld) {
      _seen = st;
      _seenHeld = held;
      final done = [
        for (var r = 0; r < n; r++)
          !liveRows.contains(r) && [for (var c = 0; c < n; c++) r * n + c].every((i) => cells[i] != 0 && !liveCells.contains(i)),
        for (var c = 0; c < n; c++)
          !liveCols.contains(c) && [for (var r = 0; r < n; r++) r * n + c].every((i) => cells[i] != 0 && !liveCells.contains(i)),
      ];
      if (!first) {
        final changed = <int>[];
        for (var i = 0; i < n * n; i++) {
          final a = prev[i], b = cells[i];
          if (a == b) continue;
          changed.add(i);
          if (a != 0) fx.symOut[i] = _Sym(a, now);
          if (b != 0) {
            fx.symIn[i] = _Sym(b, now);
          } else {
            fx.symIn.remove(i);
          }
        }
        // New rule breaks: a gentle shake (stronger on the offending cells) and a light tap.
        var broke = false;
        void jolt(int i, double strength) {
          if (cells[i] == 0) return;
          final old = fx.shake[i];
          if (old == null || old.$2 < strength || now - old.$1 > 0.1) fx.shake[i] = (now, strength);
        }

        for (final r in badRows.difference(_prevBadRows)) {
          broke = true;
          for (var c = 0; c < n; c++) {
            jolt(r * n + c, 0.6);
          }
        }
        for (final c in badCols.difference(_prevBadCols)) {
          broke = true;
          for (var r = 0; r < n; r++) {
            jolt(r * n + c, 0.6);
          }
        }
        for (final i in badCells.difference(_prevBad)) {
          broke = true;
          jolt(i, 1.0);
        }
        if (broke) HapticFeedback.lightImpact();

        if (won && !_prevWon) {
          fx.winAt = now + 0.2;
          fx.sweeps.clear();
        } else if (!won && changed.isNotEmpty && _prevDone.length == done.length) {
          for (var u = 0; u < done.length; u++) {
            if (!done[u] || _prevDone[u]) continue;
            final isRow = u < n;
            final line = isRow ? [for (var c = 0; c < n; c++) u * n + c] : [for (var r = 0; r < n; r++) r * n + (u - n)];
            final trig = line.firstWhere(changed.contains, orElse: () => line[n ~/ 2]);
            fx.sweeps.add(_Sweep(
              line,
              [for (final i in line) _sweepStep * (isRow ? (i % n - trig % n).abs() : (i ~/ n - trig ~/ n).abs())],
              isRow,
              now + 0.06,
            ));
          }
        }
      }
      if (!won) fx.winAt = -1;
      _prevCells = cells;
      _prevBad = badCells;
      _prevBadRows = badRows;
      _prevBadCols = badCols;
      _prevDone = done;
      _prevWon = won;
    }

    for (var i = 0; i < n * n; i++) {
      fx.badT[i] = badCells.contains(i) ? 1 : 0;
    }
    for (var k = 0; k < n; k++) {
      fx.rowT[k] = badRows.contains(k) ? 1 : 0;
      fx.colT[k] = badCols.contains(k) ? 1 : 0;
    }
    for (var k = 0; k < edges.length; k++) {
      fx.edgeT[k] = badEdges.contains(k) ? 1 : 0;
    }
    fx.cells = cells;
    fx.fixed = fixed;
    fx.edges = edges;
    fx.hintCell = hintCell;
    if (first) fx.settle();
    if (fx.step(0)) _kick();
  }

  int? _cellAt(Offset p, double cell, int n) {
    final r = (p.dy / cell).floor(), c = (p.dx / cell).floor();
    if (r < 0 || c < 0 || r >= n || c >= n) return null;
    return r * n + c;
  }

  @override
  Widget build(BuildContext context) {
    final st = s.state;
    final n = (st['size'] as num).toInt();
    final cells = [for (final v in st['cells'] as List) (v as num).toInt()];
    final fixed = [for (final v in st['fixed'] as List) v == true];
    final edges = [for (final e in st['edges'] as List) e as List];
    Set<int> ints(Map m, String k) => {for (final v in (m[k] as List?) ?? const []) (v as num).toInt()};
    final liveCells = ints(st, 'bad_cells'), liveRows = ints(st, 'bad_rows'), liveCols = ints(st, 'bad_cols');
    // While the player is still cycling a cell, show the breaks as if that cell were empty.
    final deferred = st['deferred'] is Map ? st['deferred'] as Map : null;
    final held = _editCell != null && deferred != null && (deferred['cell'] as num?)?.toInt() == _editCell;
    final shown = held ? deferred : st;
    final badCells = ints(shown, 'bad_cells');
    final badRows = ints(shown, 'bad_rows');
    final badCols = ints(shown, 'bad_cols');
    final badEdges = ints(shown, 'bad_edges');
    final hint = st['hint'] is Map ? st['hint'] as Map : null;
    final hintCell = hint == null ? null : (hint['cell'] as num).toInt();
    _sync(n, cells, fixed, edges, badCells, badRows, badCols, badEdges, liveCells, liveRows, liveCols, held, hintCell,
        st['status'] == 'won');

    return Column(
      children: [
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _stat('Dolu', '${st['filled']}/${st['total']}'),
            const SizedBox(width: 28),
            _stat('İpucu', '${st['hints']}'),
            const SizedBox(width: 28),
            _stat('Hata', '${st['mistakes']}'),
          ],
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: hint == null
              ? const SizedBox(width: double.infinity, height: 8)
              : Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: _HintBanner(text: hint['text'] as String),
                ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: LayoutBuilder(builder: (context, box) {
              final side = math.min(box.maxWidth, box.maxHeight);
              final cell = side / n;
              return Center(
                child: Container(
                  width: side,
                  height: side,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Lux.gold.withValues(alpha: 0.55), width: 1.4),
                    boxShadow: [BoxShadow(color: Lux.gold.withValues(alpha: 0.12), blurRadius: 24)],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(13),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: s.finished
                          ? null
                          : (d) {
                              final i = _cellAt(d.localPosition, cell, n);
                              if (i == null || fixed[i]) return;
                              HapticFeedback.selectionClick();
                              _beginEdit(i);
                              s.act({'cycle': i});
                            },
                      onLongPressStart: s.finished
                          ? null
                          : (d) {
                              final i = _cellAt(d.localPosition, cell, n);
                              if (i == null || fixed[i] || cells[i] == 0) return;
                              HapticFeedback.selectionClick();
                              _beginEdit(i);
                              s.act({'set': i, 'value': 0});
                            },
                      child: RepaintBoundary(
                        child: CustomPaint(size: Size.square(side), painter: _BoardPainter(_fx)),
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
                  tooltip: 'Geri al', onPressed: st['can_undo'] == true && !s.finished
                      ? () {
                          _endEdit();
                          s.act({'undo': true});
                        }
                      : null),
              const SizedBox(width: 24),
              RimIconButton(Icons.lightbulb_outline_rounded,
                  tooltip: 'İpucu: sıradaki çıkarım', onPressed: s.finished
                      ? null
                      : () {
                          _endEdit();
                          s.act({'hint': true});
                        }),
            ],
          ),
        ),
      ],
    );
  }

  Widget _stat(String label, String value) => Column(
        children: [
          Text(value, style: Lux.ui(22, color: Lux.goldLight, weight: FontWeight.w700)),
          Text(label, style: Lux.ui(12, color: Lux.muted, spacing: 1)),
        ],
      );
}

class _HintBanner extends StatelessWidget {
  final String text;
  const _HintBanner({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
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
  }
}

/// Cells, line glows, shimmers, symbols and edge signs in one pass.
class _BoardPainter extends CustomPainter {
  final _SunMoonFx fx;
  _BoardPainter(this.fx) : super(repaint: fx);

  static const _sunNear = SunPainter(dim: 0.08), _sunFixed = SunPainter();
  static const _moonNear = MoonPainter(dim: 0.08), _moonFixed = MoonPainter();

  /// Recorded symbol art per (symbol, fixed, size): the crescent's path boolean and the rays are
  /// built once, not on every animation frame.
  static final Map<String, ui.Picture> _pics = {};

  static ui.Picture _pic(int value, bool fixed, Size size) {
    final key = '$value|$fixed|${size.width.toStringAsFixed(1)}';
    final hit = _pics[key];
    if (hit != null) return hit;
    if (_pics.length >= 12) {
      for (final p in _pics.values) {
        p.dispose();
      }
      _pics.clear();
    }
    final rec = ui.PictureRecorder();
    final painter = value == 1 ? (fixed ? _sunFixed : _sunNear) : (fixed ? _moonFixed : _moonNear);
    painter.paint(Canvas(rec), size);
    return _pics[key] = rec.endRecording();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final n = fx.n;
    final cells = fx.cells;
    if (n == 0 || cells.length != n * n || fx.fixed.length != n * n || fx.bad.length != n * n) return;
    final cs = size.width / n;
    final now = fx.now;
    final pulse = fx.pulse();
    final hint = fx.hintCell;
    final hintPulse = fx.pulse(0.9);

    // 1 · Cell tiles.
    for (var i = 0; i < n * n; i++) {
      final r = i ~/ n, c = i % n;
      final tile = RRect.fromRectAndRadius(Rect.fromLTWH(c * cs, r * cs, cs, cs).deflate(1.5), const Radius.circular(8));
      final fixed = fx.fixed[i];
      final b = fx.bad[i];
      final hinted = hint == i;
      final base = fixed ? const Color(0xFF2A2015) : const Color(0xFF17110B);
      if (b > 0.01) {
        canvas.drawRRect(
          tile,
          Paint()
            ..color = Lux.bordeaux.withValues(alpha: b * (0.35 + 0.3 * pulse))
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4 + 4 * pulse),
        );
      }
      if (hinted) {
        canvas.drawRRect(
          tile.inflate(1),
          Paint()
            ..color = Lux.gold.withValues(alpha: 0.3 + 0.35 * hintPulse)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4 + 4 * hintPulse),
        );
      }
      canvas.drawRRect(tile, Paint()..color = b > 0 ? Color.lerp(base, Lux.bordeaux, b * (0.25 + 0.15 * pulse))! : base);
      final idle = fixed ? Lux.gold.withValues(alpha: 0.28) : Lux.line;
      var border = b > 0 ? Color.lerp(idle, Lux.bordeauxLight.withValues(alpha: 0.9), b)! : idle;
      var bw = 1.0 + 0.6 * b;
      if (hinted) {
        border = Lux.goldLight.withValues(alpha: 0.7 + 0.3 * hintPulse);
        bw = 1.6;
      }
      canvas.drawRRect(
        tile,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = bw
          ..color = border,
      );
    }

    // 2 · Lines with too many of one symbol: a breathing bordeaux veil and outline.
    void lineGlow(Rect r, double a) {
      if (a <= 0.01) return;
      canvas.drawRect(r, Paint()..color = Lux.bordeaux.withValues(alpha: a * (0.10 + 0.08 * pulse)));
      canvas.drawRRect(
        RRect.fromRectAndRadius(r.deflate(1), const Radius.circular(9)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Lux.bordeauxLight.withValues(alpha: a * (0.45 + 0.4 * pulse))
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 1.5 + 2 * pulse),
      );
    }

    for (var k = 0; k < n; k++) {
      lineGlow(Rect.fromLTWH(0, k * cs, size.width, cs), fx.row[k]);
      lineGlow(Rect.fromLTWH(k * cs, 0, cs, size.height), fx.col[k]);
    }

    // 3 · Shimmers on finished lines and the victory wave.
    final glow = List<double>.filled(n * n, 0);
    for (final sw in fx.sweeps) {
      for (var k = 0; k < sw.cells.length; k++) {
        final u = (now - sw.start - sw.delay[k]) / _sweepCell;
        if (u <= 0 || u >= 1) continue;
        final i = sw.cells[k];
        final env = math.sin(math.pi * u);
        final rect = Rect.fromLTWH((i % n) * cs, (i ~/ n) * cs, cs, cs).deflate(1.5);
        final p = -0.3 + 1.6 * u;
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(8)),
          Paint()
            ..shader = LinearGradient(
              begin: sw.row ? Alignment.centerLeft : Alignment.topCenter,
              end: sw.row ? Alignment.centerRight : Alignment.bottomCenter,
              colors: [
                Lux.goldLight.withValues(alpha: 0.08 * env),
                Lux.goldLight.withValues(alpha: 0.45 * env),
                Lux.goldLight.withValues(alpha: 0.08 * env),
              ],
              stops: [(p - 0.35).clamp(0.0, 1.0), p.clamp(0.0, 1.0), (p + 0.35).clamp(0.0, 1.0)],
            ).createShader(rect),
        );
        glow[i] = math.max(glow[i], env);
      }
    }
    if (fx.winAt >= 0) {
      for (var i = 0; i < n * n; i++) {
        final w = fx.win(i ~/ n, i % n);
        if (w <= 0) continue;
        final rect = Rect.fromLTWH((i % n) * cs, (i ~/ n) * cs, cs, cs).deflate(1.5);
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(8)),
          Paint()
            ..shader = RadialGradient(colors: [
              Lux.goldLight.withValues(alpha: 0.45 * w),
              Lux.gold.withValues(alpha: 0.14 * w),
            ]).createShader(rect),
        );
        glow[i] = math.max(glow[i], w);
      }
    }

    // 4 · Symbols: leaving ones first, then the current ones with their entrance motion.
    for (var i = 0; i < n * n; i++) {
      final r = i ~/ n, c = i % n;
      final cell = Rect.fromLTWH(c * cs, r * cs, cs, cs);
      final box = cell.deflate(8.5);
      var shake = 0.0;
      final sk = fx.shake[i];
      if (sk != null) {
        final k = now - sk.$1;
        if (k >= 0 && k < _shakeDur) shake = math.sin(k * 2 * math.pi * 8) * cs * 0.055 * sk.$2 * math.exp(-k * 8);
      }
      final out = fx.symOut[i];
      if (out != null) {
        final t = ((now - out.at) / _outDur).clamp(0.0, 1.0);
        final e = Curves.easeInCubic.transform(t);
        if (out.value == 1) {
          _symbol(canvas, box, out.value, fx.fixed[i], alpha: 1 - e, scale: 1 - 0.5 * e, angle: math.pi / 4 * e);
        } else {
          _symbol(canvas, box, out.value, fx.fixed[i],
              alpha: 1 - e, scale: 1 - 0.4 * e, shift: Offset(0, cs * 0.12 * e));
        }
      }
      final v = cells[i];
      if (v == 0) continue;
      var alpha = 1.0, scale = 1.0, angle = 0.0;
      Offset? pivot;
      final enter = fx.symIn[i];
      if (enter != null) {
        final t = ((now - enter.at) / _inDur).clamp(0.0, 1.0);
        final b = Curves.easeOutBack.transform(t);
        alpha = Curves.easeOut.transform(math.min(1.0, t * 3));
        if (v == 1) {
          // Sun: a quarter turn into place.
          angle = -math.pi / 2 * (1 - b);
          scale = 0.5 + 0.5 * b;
        } else {
          // Moon: swings in from the side, hanging from a point above the cell.
          angle = 0.6 * (1 - b);
          scale = 0.7 + 0.3 * b;
          pivot = Offset(cell.center.dx, cell.top - cs * 0.15);
        }
      }
      if (glow[i] > 0) scale *= 1 + 0.08 * glow[i];
      _symbol(canvas, box, v, fx.fixed[i],
          alpha: alpha, scale: scale, angle: angle, pivot: pivot, shift: Offset(shake, 0));
    }

    // 5 · Edge signs on the shared border of two cells.
    final badge = (cs * 0.34).clamp(14.0, 26.0);
    for (var k = 0; k < fx.edges.length && k < fx.edge.length; k++) {
      final e = fx.edges[k];
      final a = (e[0] as num).toInt(), b = (e[1] as num).toInt();
      final eq = e[2] == '=';
      final ra = a ~/ n, ca = a % n, rb = b ~/ n;
      final center = ra == rb ? Offset((ca + 1) * cs, (ra + 0.5) * cs) : Offset((ca + 0.5) * cs, (ra + 1) * cs);
      _sign(canvas, center, badge, eq, fx.edge[k], pulse);
    }
  }

  void _symbol(Canvas canvas, Rect box, int value, bool fixed,
      {double alpha = 1, double scale = 1, double angle = 0, Offset? pivot, Offset shift = Offset.zero}) {
    if (alpha <= 0.01) return;
    final layered = alpha < 0.99;
    if (layered) {
      canvas.saveLayer(box.inflate(box.width * 0.6), Paint()..color = Color.fromRGBO(0, 0, 0, alpha));
    }
    canvas.save();
    final c = box.center + shift;
    final p = pivot == null ? c : pivot + shift;
    canvas.translate(p.dx, p.dy);
    if (angle != 0) canvas.rotate(angle);
    canvas.translate(c.dx - p.dx, c.dy - p.dy);
    if (scale != 1) canvas.scale(scale);
    canvas.translate(-box.width / 2, -box.height / 2);
    canvas.drawPicture(_pic(value, fixed, box.size));
    canvas.restore();
    if (layered) canvas.restore();
  }

  void _sign(Canvas canvas, Offset c, double d, bool eq, double bad, double pulse) {
    final r = d / 2;
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawCircle(
      c.translate(0, bad > 0.01 ? 0 : 1),
      r,
      Paint()
        ..color = Color.lerp(Colors.black.withValues(alpha: 0.6), Lux.bordeaux.withValues(alpha: 0.4 + 0.4 * pulse), bad)!
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2 + bad * (4 + 4 * pulse)),
    );
    final gold = [Lux.goldLight, Lux.gold, Lux.goldDeep];
    final ruby = [Lux.bordeauxLight, Lux.bordeaux, Lux.bordeaux];
    canvas.drawCircle(
      c,
      r * (1 + 0.06 * bad * pulse),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [for (var k = 0; k < 3; k++) Color.lerp(gold[k], ruby[k], bad)!],
        ).createShader(rect),
    );
    final p = Paint()
      ..color = const Color(0xFF1A1206)
      ..strokeWidth = d * 0.12
      ..strokeCap = StrokeCap.round;
    final q = d * 0.2;
    if (eq) {
      canvas.drawLine(c + Offset(-q, -q * 0.55), c + Offset(q, -q * 0.55), p);
      canvas.drawLine(c + Offset(-q, q * 0.55), c + Offset(q, q * 0.55), p);
    } else {
      canvas.drawLine(c + Offset(-q, -q), c + Offset(q, q), p);
      canvas.drawLine(c + Offset(-q, q), c + Offset(q, -q), p);
    }
  }

  @override
  bool shouldRepaint(_BoardPainter old) => true;
}

/// Glowing gold medallion with short rays.
class SunPainter extends CustomPainter {
  final double dim;
  const SunPainter({this.dim = 0});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = math.min(size.width, size.height) / 2;
    canvas.drawCircle(c, r * 0.9,
        Paint()..color = Lux.gold.withValues(alpha: 0.35)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7));
    // Rays.
    final ray = Paint()..color = Color.lerp(Lux.gold, Lux.goldDeep, 0.2 + dim)!;
    for (var k = 0; k < 12; k++) {
      final a = k * math.pi / 6;
      final dir = Offset(math.cos(a), math.sin(a));
      final perp = Offset(-dir.dy, dir.dx);
      final path = Path()
        ..moveTo(c.dx + dir.dx * r * 0.98, c.dy + dir.dy * r * 0.98)
        ..lineTo(c.dx + dir.dx * r * 0.62 + perp.dx * r * 0.12, c.dy + dir.dy * r * 0.62 + perp.dy * r * 0.12)
        ..lineTo(c.dx + dir.dx * r * 0.62 - perp.dx * r * 0.12, c.dy + dir.dy * r * 0.62 - perp.dy * r * 0.12)
        ..close();
      canvas.drawPath(path, ray);
    }
    final disc = r * 0.62;
    canvas.drawCircle(
      c,
      disc,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.4),
          colors: [
            Color.lerp(const Color(0xFFFFF4C2), Lux.goldDeep, dim)!,
            Color.lerp(Lux.gold, Lux.goldDeep, dim)!,
            const Color(0xFF7A5512),
          ],
          stops: const [0, 0.6, 1],
        ).createShader(Rect.fromCircle(center: c, radius: disc)),
    );
    canvas.drawCircle(
      c,
      disc,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.06
        ..color = Lux.goldLight.withValues(alpha: 0.8),
    );
    canvas.drawCircle(
      c.translate(-disc * 0.3, -disc * 0.35),
      disc * 0.25,
      Paint()..color = Colors.white.withValues(alpha: 0.4)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
    );
  }

  @override
  bool shouldRepaint(SunPainter old) => old.dim != dim;
}

/// Cool silver-blue crescent with a soft halo.
class MoonPainter extends CustomPainter {
  final double dim;
  const MoonPainter({this.dim = 0});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = math.min(size.width, size.height) / 2 * 0.82;
    canvas.drawCircle(c, r,
        Paint()..color = const Color(0xFF7FA6E0).withValues(alpha: 0.28)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7));
    final outer = Path()..addOval(Rect.fromCircle(center: c, radius: r));
    final inner = Path()..addOval(Rect.fromCircle(center: c.translate(r * 0.48, -r * 0.3), radius: r * 0.82));
    final crescent = Path.combine(PathOperation.difference, outer, inner);
    canvas.drawPath(
      crescent,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(const Color(0xFFF1F5FF), const Color(0xFF8DA2C4), dim)!,
            Color.lerp(const Color(0xFFA9C0E6), const Color(0xFF6B82A8), dim)!,
            const Color(0xFF3E5A8A),
          ],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
    canvas.drawPath(
      crescent,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.06
        ..color = const Color(0xFFDDE7FA).withValues(alpha: 0.7),
    );
  }

  @override
  bool shouldRepaint(MoonPainter old) => old.dim != dim;
}
