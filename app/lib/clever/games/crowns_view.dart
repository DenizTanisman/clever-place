import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// Crowns board. Tap: empty → X → crown → empty. Drag across cells to cross many out at once
/// (a drag that starts on an X erases X's instead). Rules, conflicts and hints come from Rust.
///
/// Layers (bottom → top): static region tints · animated rule-break overlays, shimmers and the
/// victory wave · static gold region borders · animated marks, sparkles and hint frames.
/// Both animated layers are painters driven by one [_CrownsFx] model; a [Ticker] runs only while
/// something moves (or a rule is broken, which pulses). Events come from diffing what is shown
/// (state plus the live drag), so every X drawn during a drag animates the moment it is added:
/// * crowns drop in from slightly above with an overshoot and a burst of gold sparkles;
/// * X marks draw in as two quick strokes; removed marks shrink away;
/// * broken rows / columns / regions and clashing crowns pulse bordeaux (fading in and out);
/// * a row, column or region that is finished shimmers outward from its crown(s);
/// * winning plays a diagonal wave of light across the board.
Widget crownsView(BuildContext context, GameSession s) => _CrownsBoard(session: s);

/// Jewel tints in the same order as `REGION_NAMES` in `core/src/games/crowns.rs`
/// (Zümrüt, Safir, Ametist, Yakut, Kehribar, Akuamarin, Turmalin, Yeşim, Lal, Opal, Lacivert).
const _jewels = [
  Color(0xFF1E6A4E), // emerald
  Color(0xFF22428A), // sapphire
  Color(0xFF5E3C8E), // amethyst
  Color(0xFF8E1F3C), // ruby
  Color(0xFF9C6A1C), // amber
  Color(0xFF237F87), // aquamarine
  Color(0xFF8B3A72), // tourmaline
  Color(0xFF557A2E), // jade
  Color(0xFF9A4A28), // spinel (copper red)
  Color(0xFF5E7088), // opal
  Color(0xFF2B2F66), // navy
];

const double _crownDur = 0.34; // drop + overshoot
const double _sparkDelay = 0.10; // sparkles burst as the crown lands
const double _sparkDur = 0.40;
const double _xDur = 0.12; // two strokes, 60 ms each
const double _outDur = 0.16;
const double _sweepCell = 0.30;
const double _sweepStep = 0.045;
const double _winSpan = 0.55;
const double _winCell = 0.32;
const double _tau = 0.06; // rule-break fade time constant

class _CrownsBoard extends StatefulWidget {
  final GameSession session;
  const _CrownsBoard({required this.session});

  @override
  State<_CrownsBoard> createState() => _CrownsBoardState();
}

class _Out {
  final int mark;
  final bool bad;
  final double at;
  _Out(this.mark, this.bad, this.at);
}

class _Sweep {
  final List<int> cells;
  final List<double> delay;
  final double start;
  _Sweep(this.cells, this.delay, this.start);
  double get end => start + delay.fold<double>(0, math.max) + _sweepCell;
}

class _CrownsFx extends ChangeNotifier {
  double now = 0;
  int n = 0;
  List<int> shown = const [];
  Set<int> conflicts = const {};
  Set<int> hintCells = const {};
  Set<int> badRows = const {}, badCols = const {};

  // Rule-break intensities (chased 0 ↔ 1).
  List<double> badCell = const [], badCellT = const [];
  List<double> clash = const [], clashT = const [];
  List<double> rowGlow = const [], rowGlowT = const [];
  List<double> colGlow = const [], colGlowT = const [];

  final crownIn = <int, double>{};
  final xIn = <int, double>{};
  final outs = <int, _Out>{};
  final sweeps = <_Sweep>[];
  double winAt = -1;

  void resize(int n) {
    if (this.n == n && badCell.length == n * n) return;
    this.n = n;
    badCell = List.filled(n * n, 0);
    badCellT = List.filled(n * n, 0);
    clash = List.filled(n * n, 0);
    clashT = List.filled(n * n, 0);
    rowGlow = List.filled(n, 0);
    rowGlowT = List.filled(n, 0);
    colGlow = List.filled(n, 0);
    colGlowT = List.filled(n, 0);
    crownIn.clear();
    xIn.clear();
    outs.clear();
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
    badCell.setAll(0, badCellT);
    clash.setAll(0, clashT);
    rowGlow.setAll(0, rowGlowT);
    colGlow.setAll(0, colGlowT);
  }

  bool get pulsing => badCellT.any((v) => v > 0) || clashT.any((v) => v > 0) || hintCells.isNotEmpty;

  bool step(double dt) {
    final k = 1 - math.exp(-dt / _tau);
    var moving = _chase(badCell, badCellT, k);
    moving |= _chase(clash, clashT, k);
    moving |= _chase(rowGlow, rowGlowT, k);
    moving |= _chase(colGlow, colGlowT, k);
    crownIn.removeWhere((_, t) => now - t > _sparkDelay + _sparkDur);
    xIn.removeWhere((_, t) => now - t > _xDur);
    outs.removeWhere((_, o) => now - o.at > _outDur);
    sweeps.removeWhere((s) => now > s.end);
    final winning = winAt >= 0 && now < winAt + _winSpan + _winCell;
    return moving || crownIn.isNotEmpty || xIn.isNotEmpty || outs.isNotEmpty || sweeps.isNotEmpty || winning || pulsing;
  }

  double pulse([double hz = 1.1]) => 0.5 + 0.5 * math.sin(now * 2 * math.pi * hz);

  double win(int r, int c) {
    if (winAt < 0) return 0;
    final u = (now - winAt - (r + c) / math.max(1, 2 * n - 2) * _winSpan) / _winCell;
    return u <= 0 || u >= 1 ? 0 : math.sin(math.pi * u);
  }
}

class _CrownsBoardState extends State<_CrownsBoard> with SingleTickerProviderStateMixin {
  final Set<int> _drag = {};
  String _dragMark = 'x';
  int? _downCell;

  final _CrownsFx _fx = _CrownsFx();
  late final Ticker _ticker = createTicker((_) => _onTick());
  final Stopwatch _watch = Stopwatch()..start();
  double get _now => _watch.elapsedMicroseconds / 1e6;
  double _lastTick = 0;

  List<int>? _lastShown;
  Map<String, dynamic>? _seen;
  List<bool> _prevDone = const [];
  bool _prevWon = false;

  GameSession get s => widget.session;

  @override
  void didUpdateWidget(covariant _CrownsBoard old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      _drag.clear();
      _lastShown = null;
      _seen = null;
      _fx.resize(0);
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

  List<int> _ints(dynamic v) => [for (final x in (v as List? ?? const [])) (x as num).toInt()];

  int? _cellAt(Offset p, double cs, int n) {
    final c = (p.dx / cs).floor(), r = (p.dy / cs).floor();
    if (r < 0 || c < 0 || r >= n || c >= n) return null;
    return r * n + c;
  }

  void _addDrag(int? c, List<int> marks) {
    if (c == null || marks[c] == 2) return;
    if (_drag.add(c)) {
      HapticFeedback.selectionClick();
      setState(() {});
    }
  }

  void _endDrag() {
    if (_drag.isNotEmpty) s.act({'drag': _drag.toList(), 'mark': _dragMark});
    setState(_drag.clear);
  }

  /// Which units are finished: exactly k crowns, no clash inside, unit not flagged.
  List<bool> _done(int n, int k, List<int> regions, List<int> marks, Set<int> conflicts, Set<int> badRows,
      Set<int> badCols, Set<int> badRegions) {
    final rc = List.filled(n, 0), cc = List.filled(n, 0), gc = List.filled(n, 0);
    final rBad = List.filled(n, false), cBad = List.filled(n, false), gBad = List.filled(n, false);
    for (var i = 0; i < n * n; i++) {
      if (marks[i] != 2) continue;
      final r = i ~/ n, c = i % n, g = regions[i] % n;
      rc[r]++;
      cc[c]++;
      gc[g]++;
      if (conflicts.contains(i)) {
        rBad[r] = cBad[c] = gBad[g] = true;
      }
    }
    return [
      for (var r = 0; r < n; r++) rc[r] == k && !rBad[r] && !badRows.contains(r),
      for (var c = 0; c < n; c++) cc[c] == k && !cBad[c] && !badCols.contains(c),
      for (var g = 0; g < n; g++) gc[g] == k && !gBad[g] && !badRegions.contains(g),
    ];
  }

  void _sync(int n, List<int> regions, List<int> marks, List<int> shown, Set<int> conflicts, Set<int> badRows,
      Set<int> badCols, Set<int> badRegions, Set<int> hintCells) {
    final now = _now;
    final fx = _fx..now = now;
    final first = _lastShown == null || _lastShown!.length != n * n || fx.n != n;
    fx.resize(n);

    // Mark transitions (state and live drag alike).
    final prev = _lastShown;
    if (!first && prev != null) {
      for (var i = 0; i < n * n; i++) {
        final a = prev[i], b = shown[i];
        if (a == b) continue;
        if (a != 0) fx.outs[i] = _Out(a, fx.conflicts.contains(i), now);
        fx.crownIn.remove(i);
        fx.xIn.remove(i);
        if (b == 2) fx.crownIn[i] = now;
        if (b == 1) fx.xIn[i] = now;
        if (b != 0) fx.outs.remove(i);
      }
    }
    _lastShown = shown;

    // Finished units and the win, from the committed state only.
    final st = s.state;
    if (!identical(st, _seen)) {
      _seen = st;
      final k = (st['k'] as num?)?.toInt() ?? 1;
      final done = _done(n, k, regions, marks, conflicts, badRows, badCols, badRegions);
      final won = st['status'] == 'won';
      if (!first && _prevDone.length == done.length) {
        if (won && !_prevWon) {
          fx.winAt = now + 0.2;
          fx.sweeps.clear();
        } else if (!won) {
          for (var u = 0; u < done.length; u++) {
            if (!done[u] || _prevDone[u]) continue;
            final cells = <int>[
              for (var i = 0; i < n * n; i++)
                if (u < n ? i ~/ n == u : u < 2 * n ? i % n == u - n : regions[i] % n == u - 2 * n) i,
            ];
            final crowns = cells.where((i) => marks[i] == 2).toList();
            double dist(int i) => crowns.fold<double>(99, (m, c) {
                  final dr = (i ~/ n - c ~/ n).toDouble(), dc = (i % n - c % n).toDouble();
                  return math.min(m, math.sqrt(dr * dr + dc * dc));
                });
            fx.sweeps.add(_Sweep(cells, [for (final i in cells) _sweepStep * dist(i)], now + 0.08));
          }
        }
      }
      if (!won) fx.winAt = -1;
      _prevDone = done;
      _prevWon = won;
    }

    // Rule-break targets.
    for (var i = 0; i < n * n; i++) {
      final r = i ~/ n, c = i % n;
      final bad = badRows.contains(r) || badCols.contains(c) || badRegions.contains(regions[i] % n);
      fx.badCellT[i] = bad ? 1 : 0;
      fx.clashT[i] = conflicts.contains(i) && shown[i] == 2 ? 1 : 0;
    }
    for (var r = 0; r < n; r++) {
      fx.rowGlowT[r] = badRows.contains(r) ? 1 : 0;
      fx.colGlowT[r] = badCols.contains(r) ? 1 : 0;
    }
    fx.shown = shown;
    fx.conflicts = conflicts;
    fx.hintCells = hintCells;
    fx.badRows = badRows;
    fx.badCols = badCols;
    if (first) fx.settle();
    if (fx.step(0)) _kick();
  }

  @override
  Widget build(BuildContext context) {
    final st = s.state;
    final n = (st['n'] as num?)?.toInt() ?? 0;
    final regions = _ints(st['regions']);
    final marks = _ints(st['marks']);
    if (n == 0 || regions.length != n * n || marks.length != n * n) return const SizedBox();
    final conflicts = _ints(st['conflicts']).toSet();
    final bad = st['bad_units'] is Map ? st['bad_units'] as Map : const {};
    final badRows = _ints(bad['rows']).toSet();
    final badCols = _ints(bad['cols']).toSet();
    final badRegions = _ints(bad['regions']).toSet();
    final hint = st['hint'] is Map ? Map<String, dynamic>.from(st['hint'] as Map) : null;
    final hintCells = <int>{
      ..._ints(hint?['crowns']),
      ..._ints(hint?['xs']),
      ..._ints(hint?['clear']),
    };
    final focus = _ints(hint?['focus']).toSet();
    final shown = [
      for (var i = 0; i < n * n; i++)
        _drag.contains(i) && marks[i] != 2 ? (_dragMark == 'x' ? 1 : 0) : marks[i],
    ];
    _sync(n, regions, marks, shown, conflicts, badRows, badCols, badRegions, hintCells);

    return Column(
      children: [
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _stat('Taç', '${st['crowns'] ?? 0}/${st['crowns_total'] ?? n}'),
            const SizedBox(width: 30),
            _stat('İpucu', '${st['hints'] ?? 0}'),
            const SizedBox(width: 30),
            _stat('Düzeltme', '${st['corrections'] ?? 0}'),
          ],
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: LayoutBuilder(builder: (context, box) {
              final size = math.min(box.maxWidth, box.maxHeight);
              final cs = size / n;
              return Center(
                child: SizedBox(
                  width: size,
                  height: size,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: s.finished
                        ? null
                        : (d) {
                            final c = _cellAt(d.localPosition, cs, n);
                            if (c == null) return;
                            s.act({'cycle': c});
                            final now = _ints(s.state['marks']);
                            if (c < now.length && now[c] == 2) {
                              HapticFeedback.lightImpact();
                            } else {
                              HapticFeedback.selectionClick();
                            }
                          },
                    onPanDown: (d) => _downCell = _cellAt(d.localPosition, cs, n),
                    onPanStart: s.finished
                        ? null
                        : (d) {
                            final first = _downCell ?? _cellAt(d.localPosition, cs, n);
                            if (first == null) return;
                            _dragMark = marks[first] == 1 ? 'empty' : 'x';
                            _drag.clear();
                            _addDrag(first, marks);
                            _addDrag(_cellAt(d.localPosition, cs, n), marks);
                          },
                    onPanUpdate: s.finished ? null : (d) => _addDrag(_cellAt(d.localPosition, cs, n), marks),
                    onPanEnd: s.finished ? null : (_) => _endDrag(),
                    onPanCancel: () => setState(_drag.clear),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(color: Colors.black.withValues(alpha: 0.55), blurRadius: 22, offset: const Offset(0, 10)),
                          BoxShadow(color: Lux.gold.withValues(alpha: 0.08), blurRadius: 30),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _RegionPainter(n: n, regions: regions, focus: focus, over: false),
                              ),
                            ),
                            Positioned.fill(
                              child: RepaintBoundary(
                                child: CustomPaint(painter: _UnderFxPainter(_fx)),
                              ),
                            ),
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _RegionPainter(n: n, regions: regions, focus: const {}, over: true),
                              ),
                            ),
                            Positioned.fill(
                              child: RepaintBoundary(
                                child: CustomPaint(painter: _MarksPainter(_fx)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
        Text('Dokun: boş → X → taç   ·   Sürükle: X koy / kaldır',
            style: Lux.ui(12, color: Lux.muted, weight: FontWeight.w500)),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: hint == null ? const SizedBox(width: double.infinity) : _hintCard(hint),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _tool(Icons.undo_rounded, 'Geri al',
                  st['can_undo'] == true && !s.finished ? () => s.act({'undo': true}) : null),
              _tool(Icons.layers_clear_rounded, 'Temizle',
                  !s.finished && marks.any((m) => m != 0) ? () => _confirmClear(context) : null),
              _tool(Icons.lightbulb_outline_rounded, 'İpucu', s.finished
                  ? null
                  : () {
                      HapticFeedback.selectionClick();
                      s.act({'hint': true});
                    }),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Lux.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: Lux.line)),
        title: Text('Tahta temizlensin mi?', style: Lux.ui(19, weight: FontWeight.w700)),
        content: Text('Bütün taçlar ve X işaretleri silinir. Geri al ile dönebilirsin.',
            style: Lux.ui(15, color: Lux.muted, weight: FontWeight.w500)),
        actions: [
          GoldButton('Vazgeç', outlined: true, onPressed: () => Navigator.pop(ctx, false)),
          GoldButton('Temizle', onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok == true && mounted) s.act({'clear': true});
  }

  Widget _hintCard(Map<String, dynamic> hint) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
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
                child: Text(hint['text']?.toString() ?? '', style: Lux.ui(13.5, color: Lux.ink, weight: FontWeight.w500)),
              ),
            ],
          ),
        ),
      );

  Widget _tool(IconData icon, String label, VoidCallback? onTap) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RimIconButton(icon, tooltip: label, onPressed: onTap),
          const SizedBox(height: 4),
          Text(label, style: Lux.ui(11, color: Lux.muted, spacing: 0.6)),
        ],
      );

  Widget _stat(String label, String value) => Column(
        children: [
          Text(value, style: Lux.ui(22, color: Lux.goldLight, weight: FontWeight.w700)),
          Text(label, style: Lux.ui(12, color: Lux.muted, spacing: 1)),
        ],
      );
}

/// Static board art. `over == false`: velvet region tints and hint focus. `over == true`: thin
/// cell lines, thick gold region borders and the outer rim (drawn above the animated overlays).
class _RegionPainter extends CustomPainter {
  final int n;
  final List<int> regions;
  final Set<int> focus;
  final bool over;
  _RegionPainter({required this.n, required this.regions, required this.focus, required this.over});

  @override
  void paint(Canvas canvas, Size size) {
    final cs = size.width / n;
    final board = Offset.zero & size;
    if (!over) {
      canvas.drawRect(board, Paint()..color = const Color(0xFF0E0A06));
      for (var i = 0; i < n * n; i++) {
        final r = i ~/ n, c = i % n;
        final rect = Rect.fromLTWH(c * cs, r * cs, cs, cs);
        final base = _jewels[regions[i] % _jewels.length];
        final top = Color.lerp(base, Colors.white, 0.10)!;
        final bottom = Color.lerp(base, Colors.black, 0.42)!;
        canvas.drawRect(
          rect,
          Paint()
            ..shader = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [top, bottom])
                .createShader(rect),
        );
        if (focus.contains(i)) {
          canvas.drawRect(rect, Paint()..color = Lux.goldLight.withValues(alpha: 0.14));
        }
      }
      return;
    }
    // Thin cell lines.
    final thin = Paint()
      ..color = Colors.black.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (var i = 1; i < n; i++) {
      canvas.drawLine(Offset(i * cs, 0), Offset(i * cs, size.height), thin);
      canvas.drawLine(Offset(0, i * cs), Offset(size.width, i * cs), thin);
    }
    // Gold region borders.
    final gold = Paint()
      ..shader = Lux.goldGradient.createShader(board)
      ..strokeWidth = math.max(2.4, cs * 0.075)
      ..strokeCap = StrokeCap.round;
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        final i = r * n + c;
        if (c + 1 < n && regions[i] != regions[i + 1]) {
          canvas.drawLine(Offset((c + 1) * cs, r * cs), Offset((c + 1) * cs, (r + 1) * cs), gold);
        }
        if (r + 1 < n && regions[i] != regions[i + n]) {
          canvas.drawLine(Offset(c * cs, (r + 1) * cs), Offset((c + 1) * cs, (r + 1) * cs), gold);
        }
      }
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(board.deflate(1.4), const Radius.circular(11)),
      Paint()
        ..shader = Lux.goldGradient.createShader(board)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.8,
    );
  }

  @override
  bool shouldRepaint(_RegionPainter old) =>
      old.n != n || old.over != over || !_same(old.regions, regions) || !_sameSet(old.focus, focus);

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameSet(Set<int> a, Set<int> b) => a.length == b.length && a.containsAll(b);
}

/// Broken units (pulsing bordeaux tint + hatching, so a broken unit never looks like a ruby
/// region), unit shimmers and the victory wave — under the gold borders.
class _UnderFxPainter extends CustomPainter {
  final _CrownsFx fx;
  _UnderFxPainter(this.fx) : super(repaint: fx);

  @override
  void paint(Canvas canvas, Size size) {
    final n = fx.n;
    if (n == 0 || fx.badCell.length != n * n) return;
    final cs = size.width / n;
    final now = fx.now;
    final pulse = fx.pulse();
    final hatch = Paint()..strokeWidth = math.max(1.2, cs * 0.04);
    for (var i = 0; i < n * n; i++) {
      final b = fx.badCell[i];
      if (b <= 0.01) continue;
      final rect = Rect.fromLTWH((i % n) * cs, (i ~/ n) * cs, cs, cs);
      canvas.drawRect(rect, Paint()..color = Lux.bordeaux.withValues(alpha: b * (0.26 + 0.2 * pulse)));
      canvas.save();
      canvas.clipRect(rect);
      hatch.color = Lux.bordeauxLight.withValues(alpha: b * (0.24 + 0.14 * pulse));
      for (var k = -1.0; k < 2; k += 0.25) {
        canvas.drawLine(rect.topLeft + Offset(k * cs, 0), rect.topLeft + Offset(k * cs + cs, cs), hatch);
      }
      canvas.restore();
    }
    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2.5 + 2 * pulse);
    for (var r = 0; r < n; r++) {
      final g = fx.rowGlow[r];
      if (g > 0.01) {
        glow.color = Lux.bordeauxLight.withValues(alpha: g * (0.6 + 0.35 * pulse));
        canvas.drawRect(Rect.fromLTWH(1.5, r * cs + 1.5, size.width - 3, cs - 3), glow);
      }
      final c = fx.colGlow[r];
      if (c > 0.01) {
        glow.color = Lux.bordeauxLight.withValues(alpha: c * (0.6 + 0.35 * pulse));
        canvas.drawRect(Rect.fromLTWH(r * cs + 1.5, 1.5, cs - 3, size.height - 3), glow);
      }
    }
    // Shimmer: a soft light band crosses each cell of the finished unit, rippling outward.
    for (final sw in fx.sweeps) {
      for (var k = 0; k < sw.cells.length; k++) {
        final u = (now - sw.start - sw.delay[k]) / _sweepCell;
        if (u <= 0 || u >= 1) continue;
        final i = sw.cells[k];
        final env = math.sin(math.pi * u);
        final rect = Rect.fromLTWH((i % n) * cs, (i ~/ n) * cs, cs, cs);
        final p = -0.3 + 1.6 * u;
        canvas.drawRect(rect, Paint()..color = Lux.goldLight.withValues(alpha: 0.12 * env));
        canvas.drawRect(
          rect,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Lux.goldLight.withValues(alpha: 0),
                Lux.goldLight.withValues(alpha: 0.45 * env),
                Lux.goldLight.withValues(alpha: 0),
              ],
              stops: [(p - 0.3).clamp(0.0, 1.0), p.clamp(0.0, 1.0), (p + 0.3).clamp(0.0, 1.0)],
            ).createShader(rect),
        );
      }
    }
    if (fx.winAt >= 0) {
      for (var i = 0; i < n * n; i++) {
        final w = fx.win(i ~/ n, i % n);
        if (w <= 0) continue;
        final rect = Rect.fromLTWH((i % n) * cs, (i ~/ n) * cs, cs, cs);
        canvas.drawRect(
          rect,
          Paint()
            ..shader = RadialGradient(colors: [
              Lux.goldLight.withValues(alpha: 0.45 * w),
              Lux.gold.withValues(alpha: 0.15 * w),
            ]).createShader(rect),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_UnderFxPainter old) => true;
}

/// Crowns, X's, their enter/exit motion, sparkles and pulsing hint frames.
class _MarksPainter extends CustomPainter {
  final _CrownsFx fx;
  _MarksPainter(this.fx) : super(repaint: fx);

  @override
  void paint(Canvas canvas, Size size) {
    final n = fx.n;
    final shown = fx.shown;
    if (n == 0 || shown.length != n * n || fx.clash.length != n * n) return;
    final cs = size.width / n;
    final now = fx.now;
    final pulse = fx.pulse(1.2);

    for (var i = 0; i < n * n; i++) {
      final r = i ~/ n, c = i % n;
      final cell = Rect.fromLTWH(c * cs, r * cs, cs, cs);
      final win = fx.win(r, c);

      // Exit motion of the previous mark.
      final o = fx.outs[i];
      if (o != null) {
        final t = ((now - o.at) / _outDur).clamp(0.0, 1.0);
        final e = Curves.easeInCubic.transform(t);
        _withAlpha(canvas, cell, 1 - e, () {
          if (o.mark == 2) {
            _crown(canvas, cell, 1 - 0.4 * e, Offset(0, -cs * 0.06 * e), o.bad, 0);
          } else {
            _x(canvas, cell, 1, 1 - 0.35 * e);
          }
        });
      }

      final m = shown[i];
      if (m == 2) {
        final at = fx.crownIn[i];
        var scale = 1.0, dy = 0.0, alpha = 1.0;
        if (at != null) {
          final t = ((now - at) / _crownDur).clamp(0.0, 1.0);
          dy = -cs * 0.26 * (1 - Curves.easeOutCubic.transform(t));
          scale = 0.55 + 0.45 * Curves.easeOutBack.transform(t);
          alpha = Curves.easeOut.transform(math.min(1.0, t * 3));
        }
        if (win > 0) {
          scale *= 1 + 0.12 * win;
          dy -= cs * 0.06 * win;
        }
        final clash = fx.clash[i];
        final halo = clash * (0.45 + 0.55 * pulse);
        _withAlpha(canvas, cell, alpha, () => _crown(canvas, cell, scale, Offset(0, dy), clash > 0.5, halo));
        if (at != null) _sparkles(canvas, cell.center, cs, now - at - _sparkDelay, i);
      } else if (m == 1) {
        final at = fx.xIn[i];
        final t = at == null ? 1.0 : ((now - at) / _xDur).clamp(0.0, 1.0);
        _x(canvas, cell, t, 1);
      }

      if (fx.hintCells.contains(i)) {
        final rr = RRect.fromRectAndRadius(cell.deflate(2), Radius.circular(cs * 0.1));
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
            ..strokeWidth = 2
            ..color = Lux.goldLight.withValues(alpha: 0.7 + 0.3 * pulse),
        );
      }
    }
  }

  void _withAlpha(Canvas canvas, Rect cell, double alpha, void Function() draw) {
    if (alpha <= 0.01) return;
    if (alpha >= 0.99) {
      draw();
      return;
    }
    canvas.saveLayer(cell.inflate(cell.width * 0.5), Paint()..color = Color.fromRGBO(0, 0, 0, alpha));
    draw();
    canvas.restore();
  }

  void _crown(Canvas canvas, Rect cell, double scale, Offset shift, bool bad, double halo) {
    final pad = cell.width * 0.14;
    final inner = cell.deflate(pad);
    canvas.save();
    canvas.translate(cell.center.dx + shift.dx, cell.center.dy + shift.dy);
    canvas.scale(scale);
    if (halo > 0.01) {
      canvas.drawCircle(
        Offset.zero,
        inner.width * (0.48 + 0.1 * halo),
        Paint()
          ..color = Lux.bordeaux.withValues(alpha: 0.6 * halo.clamp(0.0, 1.0))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
      );
    }
    canvas.translate(-inner.width / 2, -inner.height / 2);
    canvas.drawPicture(_pic(bad, inner.size));
    canvas.restore();
  }

  /// Recorded crown art per (bad, size), so animation frames only replay it.
  static final Map<String, ui.Picture> _pics = {};

  static ui.Picture _pic(bool bad, Size size) {
    final key = '$bad|${size.width.toStringAsFixed(1)}';
    final hit = _pics[key];
    if (hit != null) return hit;
    if (_pics.length >= 6) {
      for (final p in _pics.values) {
        p.dispose();
      }
      _pics.clear();
    }
    final rec = ui.PictureRecorder();
    CrownPainter(bad: bad, halo: 0).paint(Canvas(rec), size);
    return _pics[key] = rec.endRecording();
  }

  /// X drawn as two strokes; [t] 0 → 1 runs the first stroke then the second.
  void _x(Canvas canvas, Rect cell, double t, double scale) {
    final half = cell.width * (0.5 - 0.34) * scale;
    final c = cell.center;
    final p = Paint()
      ..color = Lux.ink.withValues(alpha: 0.5)
      ..strokeWidth = math.max(1.4, half * 2 * 0.14)
      ..strokeCap = StrokeCap.round;
    final a = Curves.easeOutCubic.transform((t * 2).clamp(0.0, 1.0));
    final b = Curves.easeOutCubic.transform((t * 2 - 1).clamp(0.0, 1.0));
    final s1 = c + Offset(-half, -half), e1 = c + Offset(half, half);
    if (a > 0) canvas.drawLine(s1, Offset.lerp(s1, e1, a)!, p);
    final s2 = c + Offset(half, -half), e2 = c + Offset(-half, half);
    if (b > 0) canvas.drawLine(s2, Offset.lerp(s2, e2, b)!, p);
  }

  /// A small burst of gold four-point glints flying out as the crown lands.
  void _sparkles(Canvas canvas, Offset center, double cs, double k, int seed) {
    if (k <= 0 || k >= _sparkDur) return;
    final t = k / _sparkDur;
    final e = Curves.easeOutCubic.transform(t);
    const count = 7;
    final base = (seed * 0.618) % 1 * math.pi * 2;
    final glint = Paint()..color = Lux.goldLight.withValues(alpha: (1 - t) * (1 - t) * 0.95);
    final halo = Paint()
      ..color = Lux.gold.withValues(alpha: 0.35 * (1 - t))
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5);
    for (var j = 0; j < count; j++) {
      final ang = base + j * 2 * math.pi / count + (j.isEven ? 0.12 : -0.12);
      final reach = cs * (0.16 + (j.isEven ? 0.40 : 0.32) * e);
      final p = center + Offset(math.cos(ang), math.sin(ang)) * reach;
      final s = cs * 0.075 * (1 - 0.6 * t);
      canvas.drawCircle(p, s * 0.9, halo);
      final star = Path()
        ..moveTo(p.dx, p.dy - s)
        ..lineTo(p.dx + s * 0.28, p.dy - s * 0.28)
        ..lineTo(p.dx + s, p.dy)
        ..lineTo(p.dx + s * 0.28, p.dy + s * 0.28)
        ..lineTo(p.dx, p.dy + s)
        ..lineTo(p.dx - s * 0.28, p.dy + s * 0.28)
        ..lineTo(p.dx - s, p.dy)
        ..lineTo(p.dx - s * 0.28, p.dy - s * 0.28)
        ..close();
      canvas.drawPath(star, glint);
    }
  }

  @override
  bool shouldRepaint(_MarksPainter old) => true;
}

/// A small painted crown: three-pointed gold body with pearl tips and a gem on the band.
/// Turns bordeaux when it breaks a rule; [halo] (0–1, defaults to on when bad) sets the glow.
class CrownPainter extends CustomPainter {
  final bool bad;
  final double? halo;
  const CrownPainter({this.bad = false, this.halo});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final light = bad ? const Color(0xFFFFB3C4) : Lux.goldLight;
    final mid = bad ? Lux.bordeauxLight : Lux.gold;
    final deep = bad ? Lux.bordeaux : Lux.goldDeep;
    final bounds = Offset.zero & size;
    final glow = halo ?? (bad ? 1.0 : 0.0);
    if (glow > 0.01) {
      canvas.drawCircle(
        bounds.center,
        w * (0.48 + 0.1 * glow),
        Paint()
          ..color = Lux.bordeaux.withValues(alpha: 0.6 * glow.clamp(0.0, 1.0))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
      );
    }
    final body = Path()
      ..moveTo(w * 0.17, h * 0.72)
      ..lineTo(w * 0.08, h * 0.30)
      ..lineTo(w * 0.33, h * 0.50)
      ..lineTo(w * 0.50, h * 0.17)
      ..lineTo(w * 0.67, h * 0.50)
      ..lineTo(w * 0.92, h * 0.30)
      ..lineTo(w * 0.83, h * 0.72)
      ..close();
    canvas.drawPath(
      body.shift(Offset(0, h * 0.04)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
    );
    final fill = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [light, mid, deep],
      ).createShader(bounds);
    canvas.drawPath(body, fill);
    final band = RRect.fromRectAndRadius(Rect.fromLTRB(w * 0.15, h * 0.68, w * 0.85, h * 0.84), Radius.circular(h * 0.04));
    canvas.drawRRect(band, fill);
    final edge = Paint()
      ..color = const Color(0xFF3A2808).withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, w * 0.035)
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(body, edge);
    canvas.drawRRect(band, edge);
    // Pearl tips.
    for (final p in [Offset(w * 0.08, h * 0.27), Offset(w * 0.50, h * 0.14), Offset(w * 0.92, h * 0.27)]) {
      canvas.drawCircle(p, w * 0.065, Paint()..color = light);
      canvas.drawCircle(p, w * 0.065, edge);
    }
    // Gem on the band.
    canvas.drawCircle(Offset(w * 0.5, h * 0.76), w * 0.055, Paint()..color = bad ? Lux.goldLight : Lux.bordeaux);
  }

  @override
  bool shouldRepaint(CrownPainter old) => old.bad != bad || old.halo != halo;
}
