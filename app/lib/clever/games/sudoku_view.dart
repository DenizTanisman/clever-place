import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// Classic 9×9 Sudoku board. Tap a cell, then a digit. Notes mode turns digits into pencil marks.
/// All rules (mistakes, note clean-up, hints, win) live in Rust; this widget only renders `state`.
///
/// Motion model: the whole board is one [CustomPainter] driven by an [_SudokuFx] model. A
/// [Ticker] runs only while something animates and repaints just that painter (no widget
/// rebuilds per frame). Events are derived by diffing consecutive `state` maps:
/// * a new digit pops in (0.6 → 1, easeOutBack) with a soft gold ring ripple;
/// * a wrong digit flashes bordeaux and shakes (damped sine) with a medium haptic;
/// * a finished row / column / box gets a gold shimmer that spreads out from the last digit;
/// * selection glides between cells; peer, same-digit, focus and conflict tints cross-fade;
/// * notes fade in and out; an erased digit shrinks away; the hint cell pulses gold;
/// * winning plays a diagonal wave of light across the board.
Widget sudokuView(BuildContext context, GameSession s) => _SudokuBoard(session: s);

const double _popDur = 0.22;
const double _ringDur = 0.42;
const double _wrongDur = 0.36;
const double _ghostDur = 0.16;
const double _sweepCell = 0.30; // one cell's shimmer
const double _sweepStep = 0.035; // delay per cell of distance from the trigger
const double _winSpan = 0.55; // first → last diagonal
const double _winCell = 0.32;
const double _tauTint = 0.045; // highlight cross-fade time constant (≈140 ms to settle)
const double _tauSel = 0.04; // selection glide time constant
const double _tauNote = 0.04;

class _SudokuBoard extends StatefulWidget {
  final GameSession session;
  const _SudokuBoard({required this.session});

  @override
  State<_SudokuBoard> createState() => _SudokuBoardState();
}

/// A digit that was just removed and fades out.
class _Ghost {
  final int digit;
  final Color color;
  final FontWeight weight;
  final double at;
  _Ghost(this.digit, this.color, this.weight, this.at);
}

/// A shimmer running across one finished unit.
class _Sweep {
  final List<int> cells;
  final List<double> delay;
  final List<Offset> dir;
  final double start;
  _Sweep(this.cells, this.delay, this.dir, this.start);
  double get end => start + delay.fold<double>(0, math.max) + _sweepCell;
}

/// Everything the painter needs: a snapshot of the board plus all animation records.
class _SudokuFx extends ChangeNotifier {
  double now = 0;
  List<int> values = const [];
  List<int> fixed = const [];
  Set<int> wrong = const {};
  int selValue = 0;
  int? hintCell;

  final peer = List<double>.filled(81, 0), peerT = List<double>.filled(81, 0);
  final same = List<double>.filled(81, 0), sameT = List<double>.filled(81, 0);
  final focus = List<double>.filled(81, 0), focusT = List<double>.filled(81, 0);
  final conflict = List<double>.filled(81, 0), conflictT = List<double>.filled(81, 0);
  final noteA = List<double>.filled(810, 0), noteT = List<double>.filled(810, 0);
  double selX = 0, selY = 0, selTX = 0, selTY = 0, selA = 0, selAT = 0;

  final pop = <int, double>{};
  final ring = <int, double>{};
  final shake = <int, double>{};
  final ghosts = <int, _Ghost>{};
  final sweeps = <_Sweep>[];
  double winAt = -1;

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

  /// Advances the chased values; returns true while anything is still in motion.
  bool step(double dt) {
    final kt = 1 - math.exp(-dt / _tauTint);
    final ks = 1 - math.exp(-dt / _tauSel);
    final kn = 1 - math.exp(-dt / _tauNote);
    var moving = _chase(peer, peerT, kt);
    moving |= _chase(same, sameT, kt);
    moving |= _chase(focus, focusT, kt);
    moving |= _chase(conflict, conflictT, kt);
    moving |= _chase(noteA, noteT, kn);
    double ch(double v, double t, double k, double eps) {
      final d = t - v;
      if (d.abs() < eps) return t;
      moving = true;
      return v + d * k;
    }

    selX = ch(selX, selTX, ks, 0.002);
    selY = ch(selY, selTY, ks, 0.002);
    selA = ch(selA, selAT, kt, 0.004);

    pop.removeWhere((_, t) => now - t > _popDur);
    ring.removeWhere((_, t) => now - t > _ringDur);
    shake.removeWhere((_, t) => now - t > _wrongDur);
    ghosts.removeWhere((_, g) => now - g.at > _ghostDur);
    sweeps.removeWhere((s) => now > s.end);
    final winning = winAt >= 0 && now < winAt + _winSpan + _winCell;
    return moving ||
        pop.isNotEmpty ||
        ring.isNotEmpty ||
        shake.isNotEmpty ||
        ghosts.isNotEmpty ||
        sweeps.isNotEmpty ||
        winning ||
        hintCell != null;
  }

  void settle() {
    for (final (v, t) in [(peer, peerT), (same, sameT), (focus, focusT), (conflict, conflictT), (noteA, noteT)]) {
      v.setAll(0, t);
    }
    selX = selTX;
    selY = selTY;
    selA = selAT;
  }
}

/// The 27 units: rows, columns, boxes.
final List<List<int>> _units = [
  for (var r = 0; r < 9; r++) [for (var c = 0; c < 9; c++) r * 9 + c],
  for (var c = 0; c < 9; c++) [for (var r = 0; r < 9; r++) r * 9 + c],
  for (var b = 0; b < 9; b++)
    [
      for (var k = 0; k < 9; k++) ((b ~/ 3) * 3 + k ~/ 3) * 9 + (b % 3) * 3 + k % 3,
    ],
];

class _SudokuBoardState extends State<_SudokuBoard> with SingleTickerProviderStateMixin {
  int? _sel;
  bool _notes = false;
  Timer? _clock;

  final _SudokuFx _fx = _SudokuFx();
  final _Glyphs _glyphs = _Glyphs();
  late final Ticker _ticker = createTicker((_) => _onTick());
  final Stopwatch _watch = Stopwatch()..start();
  double get _now => _watch.elapsedMicroseconds / 1e6;
  double _lastTick = 0;

  // Previous state snapshot for event diffing.
  Map<String, dynamic>? _seen;
  List<int>? _prevValues;
  Set<int> _prevWrong = const {};
  List<int> _prevFixed = const [];
  List<bool> _prevDone = List<bool>.filled(27, false);
  bool _prevWon = false;

  GameSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    // The clock lives in Rust (`tick`); 250 ms matches the core's per-tick clamp.
    _clock = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted || s.loading || s.finished) return;
      final life = WidgetsBinding.instance.lifecycleState;
      if (life != null && life != AppLifecycleState.resumed) return;
      s.tick(250);
    });
  }

  @override
  void didUpdateWidget(covariant _SudokuBoard old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      _sel = null;
      _notes = false;
      _seen = null;
      _prevValues = null;
      _fx.pop.clear();
      _fx.ring.clear();
      _fx.shake.clear();
      _fx.ghosts.clear();
      _fx.sweeps.clear();
      _fx.winAt = -1;
    }
  }

  @override
  void dispose() {
    _clock?.cancel();
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

  List<int> _ints(String key) => [for (final v in (s.state[key] as List? ?? const [])) (v as num).toInt()];

  void _digit(int d) {
    final sel = _sel;
    if (sel == null || s.finished) return;
    HapticFeedback.selectionClick();
    s.act(_notes ? {'note': sel, 'digit': d} : {'set': sel, 'digit': d});
  }

  /// Derives one-shot events (pops, mistakes, finished units, win) from the state change.
  void _diff(List<int> values, List<int> fixed, Set<int> wrong, bool won) {
    final now = _now;
    _fx.now = now;
    final prev = _prevValues;
    final done = [for (final u in _units) u.every((c) => values[c] != 0 && !wrong.contains(c))];
    if (prev == null || prev.length != 81) {
      _prevValues = values;
      _prevWrong = wrong;
      _prevFixed = fixed;
      _prevDone = done;
      _prevWon = won;
      return;
    }
    var mistake = false;
    final changed = <int>[];
    for (var i = 0; i < 81; i++) {
      final pv = prev[i], v = values[i];
      if (pv == v) continue;
      changed.add(i);
      if (v != 0) {
        _fx.ghosts.remove(i);
        _fx.pop[i] = now;
        if (wrong.contains(i)) {
          _fx.shake[i] = now;
          mistake = true;
        } else {
          _fx.ring[i] = now;
        }
      } else {
        final f = i < _prevFixed.length ? _prevFixed[i] : 0;
        _fx.ghosts[i] = _Ghost(pv, _digitColor(f, _prevWrong.contains(i)), f == 1 ? FontWeight.w700 : FontWeight.w600, now);
        _fx.pop.remove(i);
      }
    }
    if (mistake) HapticFeedback.mediumImpact();
    if (changed.isNotEmpty) {
      for (var u = 0; u < 27; u++) {
        if (!done[u] || _prevDone[u]) continue;
        final cells = _units[u];
        final trig = cells.firstWhere(changed.contains, orElse: () => cells[4]);
        final tr = trig ~/ 9, tc = trig % 9;
        _fx.sweeps.add(_Sweep(
          cells,
          [
            for (final c in cells)
              _sweepStep * math.sqrt(math.pow(c ~/ 9 - tr, 2) + math.pow(c % 9 - tc, 2)),
          ],
          [
            for (final c in cells)
              _dirOf(u < 9 ? Offset((c % 9 - tc).toDouble(), 0) : u < 18 ? Offset(0, (c ~/ 9 - tr).toDouble()) : Offset((c % 9 - tc).toDouble(), (c ~/ 9 - tr).toDouble()), u),
          ],
          now,
        ));
      }
    }
    if (won && !_prevWon) {
      _fx.winAt = now + 0.18;
      HapticFeedback.lightImpact();
    } else if (!won) {
      _fx.winAt = -1;
    }
    _prevValues = values;
    _prevWrong = wrong;
    _prevFixed = fixed;
    _prevDone = done;
    _prevWon = won;
  }

  static Offset _dirOf(Offset d, int unit) {
    if (d == Offset.zero) return unit < 9 ? const Offset(1, 0) : unit < 18 ? const Offset(0, 1) : const Offset(0.7071, 0.7071);
    return d / d.distance;
  }

  /// Pushes the latest board into the fx model and updates every chased target.
  void _sync(List<int> values, List<int> fixed, List<int> notes, Set<int> wrong, Set<int> conflicts, int? hintCell,
      Set<int> focusCells, int selValue) {
    final st = s.state;
    final fresh = !identical(st, _seen);
    final first = _prevValues == null;
    if (fresh) {
      _seen = st;
      _diff(values, fixed, wrong, st['status'] == 'won');
    }
    final fx = _fx;
    fx.values = values;
    fx.fixed = fixed;
    fx.wrong = wrong;
    fx.selValue = selValue;
    fx.hintCell = hintCell;
    final sel = _sel;
    for (var i = 0; i < 81; i++) {
      final r = i ~/ 9, c = i % 9;
      var peer = 0.0, same = 0.0;
      if (sel != null && i != sel) {
        final sr = sel ~/ 9, sc = sel % 9;
        if (sr == r || sc == c || (sr ~/ 3 == r ~/ 3 && sc ~/ 3 == c ~/ 3)) peer = 1;
        if (selValue != 0 && values[i] == selValue) same = 1;
      }
      fx.peerT[i] = peer;
      fx.sameT[i] = same;
      fx.focusT[i] = focusCells.contains(i) ? 1 : 0;
      fx.conflictT[i] = conflicts.contains(i) ? 1 : 0;
      final mask = values[i] == 0 ? notes[i] : 0;
      for (var d = 1; d <= 9; d++) {
        fx.noteT[i * 10 + d] = mask & (1 << d) != 0 ? 1 : 0;
      }
    }
    if (sel != null) {
      if (fx.selAT == 0 && fx.selA < 0.05) {
        // Appearing from nothing: start in place and fade in.
        fx.selX = (sel % 9).toDouble();
        fx.selY = (sel ~/ 9).toDouble();
      }
      fx.selTX = (sel % 9).toDouble();
      fx.selTY = (sel ~/ 9).toDouble();
      fx.selAT = 1;
    } else {
      fx.selAT = 0;
    }
    if (first) fx.settle();
    fx.now = _now;
    if (fx.step(0)) _kick();
  }

  @override
  Widget build(BuildContext context) {
    final st = s.state;
    final values = _ints('values');
    if (values.length != 81) return const SizedBox();
    final fixed = _ints('fixed');
    final notes = _ints('notes');
    final wrong = _ints('wrong').toSet();
    final conflicts = _ints('conflicts').toSet();
    final remaining = _ints('remaining');
    final hint = st['hint'] is Map ? Map<String, dynamic>.from(st['hint'] as Map) : null;
    final hintCell = (hint?['cell'] as num?)?.toInt();
    final focus = <int>{for (final f in (hint?['focus'] as List? ?? const [])) (f as num).toInt()};
    final sel = _sel;
    final selValue = sel == null ? 0 : values[sel];
    final elapsed = (st['elapsed'] as num?)?.toInt() ?? 0;
    final canEdit = sel != null && fixed[sel] == 0 && !s.finished;
    _sync(values, fixed, notes, wrong, conflicts, hintCell, focus, selValue);

    return Column(
      children: [
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _stat('Hata', '${st['mistakes'] ?? 0}', warn: (st['mistakes'] as num? ?? 0) > 0),
            const SizedBox(width: 30),
            _stat('İpucu', '${st['hints'] ?? 0}'),
            const SizedBox(width: 30),
            _stat('Süre', '${elapsed ~/ 60}:${(elapsed % 60).toString().padLeft(2, '0')}'),
          ],
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: LayoutBuilder(builder: (context, box) {
              final size = math.min(box.maxWidth, box.maxHeight);
              return Center(
                child: SizedBox(
                  width: size,
                  height: size,
                  child: _board(size),
                ),
              );
            }),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: hint == null ? const SizedBox(width: double.infinity) : _hintCard(hint),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _tool(Icons.undo_rounded, 'Geri al',
                  st['can_undo'] == true && !s.finished ? () => s.act({'undo': true}) : null),
              _tool(Icons.backspace_outlined, 'Sil', canEdit ? () => s.act({'erase': sel}) : null),
              _tool(Icons.edit_note_rounded, _notes ? 'Not: açık' : 'Not', s.finished ? null : () => setState(() => _notes = !_notes),
                  active: _notes),
              _tool(Icons.auto_fix_high_rounded, 'Tüm notlar', s.finished ? null : () => s.act({'fill_notes': true})),
              _tool(Icons.lightbulb_outline_rounded, 'İpucu', s.finished ? null : () {
                HapticFeedback.selectionClick();
                if (s.act({'hint': true})) {
                  final h = s.state['hint'];
                  final c = h is Map ? (h['cell'] as num?)?.toInt() : null;
                  if (c != null) setState(() => _sel = c);
                }
              }),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 18),
          child: Row(
            children: [
              for (var d = 1; d <= 9; d++)
                Expanded(
                  child: _padKey(d, remaining.length == 9 ? remaining[d - 1] : 0, highlighted: selValue == d,
                      enabled: canEdit),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _board(double size) {
    final cs = size / 9;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.55), blurRadius: 22, offset: const Offset(0, 10)),
          BoxShadow(color: Lux.gold.withValues(alpha: 0.08), blurRadius: 30),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Tap-down selects at once: the glide starts while the finger is still on the glass.
          onTapDown: (d) {
            final c = (d.localPosition.dx / cs).floor(), r = (d.localPosition.dy / cs).floor();
            if (r < 0 || c < 0 || r > 8 || c > 8) return;
            final i = r * 9 + c;
            HapticFeedback.selectionClick();
            setState(() => _sel = _sel == i ? null : i);
          },
          child: RepaintBoundary(
            child: CustomPaint(size: Size.square(size), painter: _BoardPainter(_fx, _glyphs)),
          ),
        ),
      ),
    );
  }

  Widget _hintCard(Map<String, dynamic> hint) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: const Color(0xFF1E1710),
            border: Border.all(color: Lux.gold.withValues(alpha: 0.45)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.lightbulb_rounded, color: Lux.gold, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(hint['text']?.toString() ?? '',
                    style: Lux.ui(13.5, color: Lux.ink, weight: FontWeight.w500)),
              ),
            ],
          ),
        ),
      );

  Widget _tool(IconData icon, String label, VoidCallback? onTap, {bool active = false}) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: active ? [BoxShadow(color: Lux.gold.withValues(alpha: 0.55), blurRadius: 14)] : null,
            ),
            child: RimIconButton(icon, tooltip: label, onPressed: onTap),
          ),
          const SizedBox(height: 4),
          Text(label, style: Lux.ui(11, color: active ? Lux.goldLight : Lux.muted, spacing: 0.6)),
        ],
      );

  Widget _padKey(int d, int left, {required bool highlighted, required bool enabled}) {
    final done = left <= 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2.5),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: enabled ? (done ? 0.35 : 1) : 0.55,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: enabled ? () => _digit(d) : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              height: 62,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: highlighted
                      ? [const Color(0xFF4A3814), const Color(0xFF241A0C)]
                      : [const Color(0xFF261D12), const Color(0xFF15100A)],
                ),
                border: Border.all(color: highlighted ? Lux.gold : Lux.line, width: highlighted ? 1.3 : 1),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('$d',
                      style: Lux.ui(_notes ? 20 : 26,
                          color: _notes ? Lux.muted : Lux.goldLight, weight: FontWeight.w700, spacing: 0)),
                  Text(done ? '✓' : '$left', style: Lux.ui(10.5, color: Lux.muted, spacing: 0)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _stat(String label, String value, {bool warn = false}) => Column(
        children: [
          Text(value, style: Lux.ui(22, color: warn ? Lux.bordeauxLight : Lux.goldLight, weight: FontWeight.w700)),
          Text(label, style: Lux.ui(12, color: Lux.muted, spacing: 1)),
        ],
      );
}

/// Laid-out glyph cache. Alpha is quantised so fades reuse a small set of painters.
class _Glyphs {
  final Map<String, TextPainter> _m = {};

  TextPainter get(String text, double size, Color color, FontWeight weight, double alpha) {
    final a = (alpha.clamp(0.0, 1.0) * 20).round() / 20;
    final key = '$text|${size.toStringAsFixed(1)}|${color.toARGB32()}|${weight.value}|$a';
    final hit = _m[key];
    if (hit != null) return hit;
    if (_m.length > 900) _m.clear();
    return _m[key] = TextPainter(
      text: TextSpan(text: text, style: Lux.ui(size, color: color.withValues(alpha: color.a * a), weight: weight, spacing: 0)),
      textDirection: TextDirection.ltr,
    )..layout();
  }
}

void _drawGlyph(Canvas canvas, TextPainter tp, Offset center, double scale) {
  if (scale == 1) {
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
    return;
  }
  canvas.save();
  canvas.translate(center.dx, center.dy);
  canvas.scale(scale);
  tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
  canvas.restore();
}

/// Cells, highlights, digits, notes, grid lines and all effects in one pass.
class _BoardPainter extends CustomPainter {
  final _SudokuFx fx;
  final _Glyphs glyphs;
  _BoardPainter(this.fx, this.glyphs) : super(repaint: fx);

  double _win(int r, int c) {
    if (fx.winAt < 0) return 0;
    final u = (fx.now - fx.winAt - (r + c) / 16 * _winSpan) / _winCell;
    return u <= 0 || u >= 1 ? 0 : math.sin(math.pi * u);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final values = fx.values;
    if (values.length != 81 || fx.fixed.length != 81) return;
    final now = fx.now;
    final cs = size.width / 9;
    final fill = Paint();

    // 1 · Cell backgrounds with cross-faded tints and the bordeaux mistake flash.
    for (var i = 0; i < 81; i++) {
      final r = i ~/ 9, c = i % 9;
      var bg = ((r ~/ 3) + (c ~/ 3)).isEven ? const Color(0xFF18120C) : const Color(0xFF201810);
      if (fx.peer[i] > 0) bg = Color.lerp(bg, Lux.gold, 0.09 * fx.peer[i])!;
      if (fx.same[i] > 0) bg = Color.lerp(bg, Lux.gold, 0.24 * fx.same[i])!;
      if (fx.focus[i] > 0) bg = Color.lerp(bg, Lux.goldLight, 0.12 * fx.focus[i])!;
      if (fx.conflict[i] > 0) bg = Color.lerp(bg, Lux.bordeaux, 0.5 * fx.conflict[i])!;
      final sk = fx.shake[i];
      if (sk != null) {
        final k = now - sk;
        if (k >= 0 && k < _wrongDur) {
          final flash = math.min(1.0, k / 0.04) * math.exp(-k * 6);
          bg = Color.lerp(bg, Lux.bordeaux, 0.7 * flash)!;
        }
      }
      fill.color = bg;
      canvas.drawRect(Rect.fromLTWH(c * cs, r * cs, cs, cs), fill);
    }

    // 2 · Shimmer along finished units, then the victory wave.
    final glow = List<double>.filled(81, 0);
    for (final sw in fx.sweeps) {
      for (var k = 0; k < sw.cells.length; k++) {
        final u = (now - sw.start - sw.delay[k]) / _sweepCell;
        if (u <= 0 || u >= 1) continue;
        final i = sw.cells[k];
        final env = math.sin(math.pi * u);
        final rect = Rect.fromLTWH((i % 9) * cs, (i ~/ 9) * cs, cs, cs);
        canvas.drawRect(rect, Paint()..color = Lux.goldLight.withValues(alpha: 0.10 * env));
        final p = -0.3 + 1.6 * u;
        final d = sw.dir[k];
        canvas.drawRect(
          rect,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment(-d.dx, -d.dy),
              end: Alignment(d.dx, d.dy),
              colors: [
                Lux.goldLight.withValues(alpha: 0),
                Lux.goldLight.withValues(alpha: 0.42 * env),
                Lux.goldLight.withValues(alpha: 0),
              ],
              stops: [(p - 0.3).clamp(0.0, 1.0), p.clamp(0.0, 1.0), (p + 0.3).clamp(0.0, 1.0)],
            ).createShader(rect),
        );
        glow[i] = math.max(glow[i], env);
      }
    }
    if (fx.winAt >= 0) {
      for (var i = 0; i < 81; i++) {
        final w = _win(i ~/ 9, i % 9);
        if (w <= 0) continue;
        final rect = Rect.fromLTWH((i % 9) * cs, (i ~/ 9) * cs, cs, cs);
        canvas.drawRect(
          rect,
          Paint()
            ..shader = RadialGradient(colors: [
              Lux.goldLight.withValues(alpha: 0.42 * w),
              Lux.gold.withValues(alpha: 0.16 * w),
            ]).createShader(rect),
        );
        glow[i] = math.max(glow[i], w);
      }
    }

    // 3 · Gliding selection.
    if (fx.selA > 0.01) {
      final a = fx.selA;
      final rect = Rect.fromLTWH(fx.selX * cs, fx.selY * cs, cs, cs).deflate(1.2);
      final rr = RRect.fromRectAndRadius(rect, Radius.circular(cs * 0.12));
      canvas.drawRRect(rr, Paint()..color = Lux.gold.withValues(alpha: 0.32 * a));
      canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = Lux.goldLight.withValues(alpha: 0.75 * a),
      );
    }

    // 4 · Pencil marks (each fades on its own).
    final pad = cs * 0.04, sub = (cs - 2 * pad) / 3, nfs = cs * 0.25;
    for (var i = 0; i < 81; i++) {
      final base = i * 10;
      for (var d = 1; d <= 9; d++) {
        final a = fx.noteA[base + d];
        if (a < 0.03) continue;
        final hot = fx.selValue == d;
        final tp = glyphs.get('$d', nfs, hot ? Lux.goldLight : Lux.muted, hot ? FontWeight.w800 : FontWeight.w600, a);
        final k = d - 1;
        final center = Offset((i % 9) * cs + pad + (k % 3 + 0.5) * sub, (i ~/ 9) * cs + pad + (k ~/ 3 + 0.5) * sub);
        _drawGlyph(canvas, tp, center, 0.85 + 0.15 * a);
      }
    }

    // 5 · Digits (pop-in, mistake shake, win bounce) and fading ghosts of erased digits.
    final dfs = cs * 0.62;
    for (var i = 0; i < 81; i++) {
      final r = i ~/ 9, c = i % 9;
      var center = Offset((c + 0.5) * cs, (r + 0.5) * cs);
      final v = values[i];
      if (v == 0) {
        final g = fx.ghosts[i];
        if (g == null) continue;
        final t = ((now - g.at) / _ghostDur).clamp(0.0, 1.0);
        final tp = glyphs.get('${g.digit}', dfs, g.color, g.weight, 1 - Curves.easeIn.transform(t));
        _drawGlyph(canvas, tp, center, 1 - 0.3 * Curves.easeIn.transform(t));
        continue;
      }
      final f = fx.fixed[i];
      var scale = 1.0, alpha = 1.0;
      final p = fx.pop[i];
      if (p != null) {
        final t = ((now - p) / _popDur).clamp(0.0, 1.0);
        scale = 0.6 + 0.4 * Curves.easeOutBack.transform(t);
        alpha = Curves.easeOut.transform(math.min(1.0, t * 2.2));
      }
      final sk = fx.shake[i];
      if (sk != null) {
        final k = now - sk;
        if (k >= 0 && k < _wrongDur) center += Offset(math.sin(k * 2 * math.pi * 9) * cs * 0.08 * math.exp(-k * 9), 0);
      }
      if (glow[i] > 0) scale *= 1 + 0.08 * glow[i];
      final tp = glyphs.get('$v', dfs, _digitColor(f, fx.wrong.contains(i)),
          f == 1 ? FontWeight.w700 : FontWeight.w600, alpha);
      _drawGlyph(canvas, tp, center, scale);
    }

    // 6 · Grid: thin cell lines plus gold 3×3 box lines.
    final thin = Paint()
      ..color = Lux.gold.withValues(alpha: 0.13)
      ..strokeWidth = 1;
    for (var i = 1; i < 9; i++) {
      if (i % 3 == 0) continue;
      canvas.drawLine(Offset(i * cs, 0), Offset(i * cs, size.height), thin);
      canvas.drawLine(Offset(0, i * cs), Offset(size.width, i * cs), thin);
    }
    final board = Offset.zero & size;
    final gold = Paint()
      ..shader = Lux.goldGradient.createShader(board)
      ..strokeWidth = math.max(2.2, cs * 0.05)
      ..strokeCap = StrokeCap.round;
    for (final i in [3, 6]) {
      canvas.drawLine(Offset(i * cs, 0), Offset(i * cs, size.height), gold);
      canvas.drawLine(Offset(0, i * cs), Offset(size.width, i * cs), gold);
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(board.deflate(1.2), const Radius.circular(11)),
      Paint()
        ..shader = Lux.goldGradient.createShader(board)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4,
    );

    // 7 · Ripples and the pulsing hint glow ride on top of the grid.
    for (final e in fx.ring.entries) {
      final t = ((now - e.value) / _ringDur).clamp(0.0, 1.0);
      if (t >= 1) continue;
      final i = e.key;
      final center = Offset((i % 9 + 0.5) * cs, (i ~/ 9 + 0.5) * cs);
      final rad = cs * (0.3 + 0.42 * Curves.easeOutCubic.transform(t));
      canvas.drawCircle(
        center,
        rad,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6 + cs * 0.05 * (1 - t)
          ..color = Lux.goldLight.withValues(alpha: 0.55 * math.pow(1 - t, 1.6).toDouble()),
      );
    }
    final h = fx.hintCell;
    if (h != null && h >= 0 && h < 81) {
      final pulse = 0.5 + 0.5 * math.sin(now * 2 * math.pi * 0.9);
      final rr = RRect.fromRectAndRadius(
          Rect.fromLTWH((h % 9) * cs, (h ~/ 9) * cs, cs, cs).deflate(1.5), Radius.circular(cs * 0.12));
      canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 + 2 * pulse
          ..color = Lux.gold.withValues(alpha: 0.3 + 0.35 * pulse)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 + 3 * pulse),
      );
      canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = Lux.goldLight.withValues(alpha: 0.65 + 0.35 * pulse),
      );
    }
  }

  @override
  bool shouldRepaint(_BoardPainter old) => true;
}

/// Given digits ink, hint digits green, wrong digits bordeaux, player digits gold.
Color _digitColor(int f, bool isWrong) => f == 1
      ? Lux.ink
      : isWrong
          ? Lux.bordeauxLight
          : f == 2
              ? Lux.good
              : Lux.goldLight;
