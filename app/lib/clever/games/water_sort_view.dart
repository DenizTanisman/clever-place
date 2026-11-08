import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// Renk Tüpleri board. Tap a tube to lift it, tap another to pour. Colours only (no symbols);
/// hidden layers show a "?".
///
/// Pour choreography (one clock, three phases):
///   A  0.00–0.30  the lifted tube arcs over to the target while tilting towards it;
///   B  0.30–0.74  it keeps its lip pinned above the target's mouth and tilts further as it drains;
///                 a tapering stream falls, splashes and the target fills with a rippling surface;
///   C  0.74–1.00  it swings home, rights itself with a small overshoot and the liquid sloshes.
/// Liquid surfaces stay level with gravity: each layer's surface is solved from its volume against
/// the tilted tube outline, so the colour bands slide towards the lip exactly like real liquid.
/// Taps never get lost: moves made while a pour is running (any number, any colours) join a queue
/// and play one after another; each is sent to the core only when its turn comes, so it is checked
/// against the state left by the pours before it (an illegal one shakes and is dropped). Queued
/// sources stay lifted and their targets glow; undo first cancels the queue, then undoes pours.
Widget waterSortView(BuildContext context, GameSession s) => _WaterBoard(session: s);

/// Rich jewel colours (index = colour id − 1).
const _liquids = [
  Color(0xFFD7263D), // ruby
  Color(0xFF2E5EAA), // sapphire
  Color(0xFF1E9E6A), // emerald
  Color(0xFFF28C28), // amber
  Color(0xFF8E5BD0), // amethyst
  Color(0xFF2EC4C4), // turquoise
  Color(0xFFF06EAA), // rose
  Color(0xFFA7D046), // lime
  Color(0xFFFFE15A), // lemon
  Color(0xFFE8E4D8), // pearl
  Color(0xFF8B5A2B), // bronze
  Color(0xFF6C7A89), // slate
  Color(0xFF556B2F), // olive
  Color(0xFF6A1B4D), // plum
];

Color _liquid(int id) => id <= 0 ? const Color(0xFF3A3530) : _liquids[(id - 1) % _liquids.length];

const double _phaseA = 0.30, _phaseB = 0.74;

/// Pour length on its own, and while more pours wait behind it (keeps a long queue brisk).
const double _pourDur = 0.92, _pourDurQueued = 0.78;

class _WaterBoard extends StatefulWidget {
  final GameSession session;
  const _WaterBoard({required this.session});

  @override
  State<_WaterBoard> createState() => _WaterBoardState();
}

class _Pour {
  final int from, to, color, amount;
  final double start, dur;
  bool finished = false;
  bool landed = false;
  _Pour(this.from, this.to, this.color, this.amount, this.start, this.dur);
  double u(double now) => ((now - start) / dur).clamp(0.0, 1.0);
}

class _WaterBoardState extends State<_WaterBoard> with SingleTickerProviderStateMixin {
  int? _sel;
  int _serial = 0;
  _Pour? _pour;

  /// Moves waiting for the running pour to finish, oldest first. Not yet sent to the core.
  final List<(int, int)> _queue = [];
  late final Ticker _ticker = createTicker((_) => _onTick());
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;

  final Map<int, double> _slosh = {}; // tube → time a slosh started
  final Map<int, double> _sloshAmp = {};
  final Map<int, double> _pop = {}; // tube → time it was completed
  int? _shakeTube;
  double _shakeAt = -10;

  GameSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    _serial = _currentSerial();
    s.addListener(_onSession);
  }

  @override
  void dispose() {
    s.removeListener(_onSession);
    _ticker.dispose();
    super.dispose();
  }

  int _currentSerial() {
    final lp = s.state['last_pour'];
    return lp is Map ? (lp['serial'] as num).toInt() : -1;
  }

  void _kick() {
    if (!_ticker.isActive) _ticker.start();
  }

  bool _busy(double now) =>
      _pour != null ||
      _slosh.values.any((t) => now - t < 1.4) ||
      _pop.values.any((t) => now - t < 1.0) ||
      now - _shakeAt < 0.5;

  void _onSession() {
    final lp = s.state['last_pour'];
    final serial = lp is Map ? (lp['serial'] as num).toInt() : -1;
    if (serial == _serial) return;
    _serial = serial;
    if (lp is Map) {
      final from = (lp['from'] as num).toInt(), to = (lp['to'] as num).toInt();
      _pour = _Pour(from, to, (lp['color'] as num).toInt(), (lp['amount'] as num).toInt(), _now,
          _queue.isEmpty ? _pourDur : _pourDurQueued);
      _kick();
    } else {
      _pour = null; // undo / restart: show the new state at once
      _queue.clear();
    }
  }

  void _onTick() {
    final now = _now;
    final p = _pour;
    if (p != null && !p.finished) {
      final u = p.u(now);
      if (u >= _phaseB && !p.landed) {
        p.landed = true;
        _slosh[p.to] = now;
        _sloshAmp[p.to] = 0.10;
        if (_isComplete(p.to)) {
          _pop[p.to] = now;
          HapticFeedback.mediumImpact();
        } else {
          HapticFeedback.lightImpact();
        }
      }
      if (u >= 1) {
        p.finished = true;
        _slosh[p.from] = now;
        _sloshAmp[p.from] = 0.22;
        _pour = null;
        _advance();
      }
    }
    _slosh.removeWhere((_, t) => now - t > 1.6);
    _pop.removeWhere((_, t) => now - t > 1.2);
    if (!_busy(now)) _ticker.stop();
    if (mounted) setState(() {});
  }

  bool _isComplete(int i) {
    final c = s.state['complete'];
    return c is List && i < c.length && c[i] == true;
  }

  /// Sends queued moves to the core until one starts a pour (or the queue runs dry). A move that
  /// became illegal because of the pours before it shakes its tube and is dropped.
  void _advance() {
    while (_pour == null && _queue.isNotEmpty) {
      if (s.finished) {
        _queue.clear();
        break;
      }
      final (from, to) = _queue.removeAt(0);
      _doPour(from, to, queued: true);
    }
    if (mounted) setState(() {});
  }

  /// [queued]: the move waited behind other pours, so on failure the player has likely moved on;
  /// don't re-lift its tube, just shake it.
  void _doPour(int from, int to, {bool queued = false}) {
    final ok = s.act({'from': from, 'to': to});
    if (ok) {
      HapticFeedback.selectionClick();
      if (!queued) setState(() => _sel = null);
    } else {
      HapticFeedback.mediumImpact();
      setState(() {
        if (!queued) _sel = from;
        _shakeTube = from;
        _shakeAt = _now;
      });
      _kick();
    }
  }

  /// Tubes as they will look once every queued move has played (best guess: layers still hidden
  /// can't be predicted, and the core has the final say when each move's turn comes).
  List<List<int>> _projected(List<List<int>> tubes, int cap) {
    if (_queue.isEmpty) return tubes;
    final t = [for (final x in tubes) [...x]];
    for (final (from, to) in _queue) {
      if (from >= t.length || to >= t.length) continue;
      final a = t[from], b = t[to];
      if (a.isEmpty || a.last == 0 || b.length >= cap || (b.isNotEmpty && b.last != a.last)) continue;
      var run = 0;
      while (run < a.length && a[a.length - 1 - run] == a.last) {
        run++;
      }
      final k = math.min(run, cap - b.length);
      for (var j = 0; j < k; j++) {
        b.add(a.removeLast());
      }
    }
    return t;
  }

  bool _touchedByQueue(int i) => _queue.any((m) => m.$1 == i || m.$2 == i);

  void _tap(int i, List<List<int>> tubes, List<bool> complete, int cap) {
    if (s.finished) return;
    final sel = _sel;
    if (sel == null) {
      // Judge the tap against the board as the queue will leave it.
      final proj = _projected(tubes, cap);
      final t = proj[i];
      final done = _touchedByQueue(i)
          ? t.length == cap && t.every((c) => c != 0 && c == t.first)
          : complete[i];
      if (t.isNotEmpty && !done) {
        HapticFeedback.selectionClick();
        setState(() => _sel = i);
      }
      return;
    }
    if (sel == i) {
      setState(() => _sel = null);
      return;
    }
    if (_pour == null && _queue.isEmpty) {
      _doPour(sel, i);
      return;
    }
    // A pour is running: queue the move; it plays as soon as the ones before it are done.
    HapticFeedback.selectionClick();
    setState(() {
      _queue.add((sel, i));
      _sel = null;
    });
  }

  void _undo() {
    setState(() {
      _sel = null;
      if (_queue.isNotEmpty) {
        // Cancel the planned moves first; the running pour stays.
        _queue.clear();
        HapticFeedback.selectionClick();
      } else {
        s.act({'undo': true});
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final st = s.state;
    final cap = (st['cap'] as num).toInt();
    final tubes = [
      for (final t in st['tubes'] as List) [for (final c in t as List) (c as num).toInt()]
    ];
    final hidden = [for (final h in st['hidden'] as List) (h as num).toInt()];
    final complete = [for (final c in st['complete'] as List) c == true];
    final hint = st['hint'] is List ? [for (final h in st['hint'] as List) (h as num).toInt()] : null;
    final hintText = st['hint_text'] as String?;
    final stuck = st['stuck'] == true;
    final n = tubes.length;

    return Column(
      children: [
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _stat('Hamle', '${st['moves']}'),
            const SizedBox(width: 28),
            _stat('Hedef', '${st['par']}'),
            const SizedBox(width: 28),
            _stat('Tamam', '${complete.where((c) => c).length}/${tubes.fold<int>(0, (a, t) => a + t.length) ~/ cap}'),
          ],
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          child: (hintText == null && !stuck)
              ? const SizedBox(width: double.infinity, height: 8)
              : Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: _banner(stuck ? 'Yasal dökme kalmadı — geri al ya da yeniden başla.' : hintText!),
                ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: LayoutBuilder(builder: (context, box) {
              final now = _now;
              final w = box.maxWidth, h = box.maxHeight;
              final rows = n <= 6 ? 1 : (n <= 18 ? 2 : 3);
              final perRow = (n / rows).ceil();
              final slotW = w / perRow;
              final rowH = h / rows;
              final tubeW = math.min(slotW * 0.6, 58.0);
              final unit = math.min((rowH * 0.80) / (cap + 0.9), tubeW * 1.25);
              final tubeH = unit * (cap + 0.55);
              final lip = unit * 0.18;
              Offset topLeft(int i) {
                final r = i ~/ perRow, c = i % perRow;
                final inRow = r == rows - 1 ? n - perRow * (rows - 1) : perRow;
                final rowLeft = (w - inRow * slotW) / 2;
                return Offset(rowLeft + c * slotW + (slotW - tubeW) / 2, r * rowH + (rowH - tubeH) / 2 + rowH * 0.04);
              }

              Offset centerOf(int i) => topLeft(i) + Offset(tubeW / 2, tubeH / 2);
              // World position of the pouring lip corner for a tube centred at c, rotated by a.
              Offset rot(Offset v, double a) =>
                  Offset(v.dx * math.cos(a) - v.dy * math.sin(a), v.dx * math.sin(a) + v.dy * math.cos(a));

              final children = <Widget>[];
              Widget? moving;
              _FxPainter? fx;
              final p = _pour;
              final u = p?.u(now) ?? 1.0;
              final fxSparkles = <(Offset, double, double)>[]; // (rim centre, t, tube width)

              for (var i = 0; i < n; i++) {
                final base = topLeft(i);
                var segs = <(int, double)>[for (final c in tubes[i]) (c, 1.0)];
                var center = centerOf(i);
                var angle = 0.0;
                var tilt = 0.0; // liquid-only extra tilt (slosh)
                var symbols = 1.0;
                var scale = 1.0;
                var shine = -1.0;
                final pourHere = p != null && (i == p.from || i == p.to);

                if (p != null && i == p.from) {
                  final dir = centerOf(p.to).dx >= center.dx ? 1.0 : -1.0;
                  final before = (tubes[i].length + p.amount) / cap;
                  final after = tubes[i].length / cap;
                  final aStart = dir * (0.95 + 0.45 * (1 - before));
                  final aEnd = dir * math.min(1.55, 1.15 + 0.45 * (1 - after));
                  final corner = Offset(dir > 0 ? tubeW / 2 : -tubeW / 2, lip - tubeH / 2);
                  final tgt = topLeft(p.to);
                  final mouth = Offset(tgt.dx + tubeW / 2 + dir * tubeW * 0.08, tgt.dy - unit * 0.55);
                  Offset pourCenter(double a) => mouth - rot(corner, a);
                  // From the rest slot: the lifted look comes from the tube's slide easing back to 0.
                  final start = center;
                  double drained;
                  if (u < _phaseA) {
                    final k = u / _phaseA;
                    final e = Curves.easeInOutCubic.transform(k);
                    final end = pourCenter(aStart);
                    final ctrl = Offset((start.dx + end.dx) / 2, math.min(start.dy, end.dy) - tubeH * 0.22);
                    center = _quad(start, ctrl, end, e);
                    angle = aStart * Curves.easeInOutCubic.transform(((k - 0.2) / 0.8).clamp(0.0, 1.0));
                    drained = 0;
                  } else if (u < _phaseB) {
                    final k = (u - _phaseA) / (_phaseB - _phaseA);
                    final e = Curves.easeInOutSine.transform(k);
                    angle = aStart + (aEnd - aStart) * e;
                    center = pourCenter(angle);
                    drained = e;
                    // Stream from the lip to the rising surface of the target.
                    final surf = tgt.dy + tubeH - 2.5 - unit * (tubes[p.to].length - p.amount + p.amount * e);
                    final head = (k / 0.14).clamp(0.0, 1.0);
                    final tail = ((k - 0.86) / 0.14).clamp(0.0, 1.0);
                    fx = _FxPainter(
                      color: _liquid(p.color),
                      lip: mouth,
                      x: tgt.dx + tubeW / 2,
                      top: mouth.dy + (surf - mouth.dy) * Curves.easeIn.transform(tail),
                      bottom: mouth.dy + (surf - mouth.dy) * Curves.easeIn.transform(head),
                      surf: surf,
                      width: tubeW * 0.16,
                      phase: k,
                      tubeW: tubeW,
                      unit: unit,
                    );
                  } else {
                    final k = (u - _phaseB) / (1 - _phaseB);
                    final e = Curves.easeInOutCubic.transform(k);
                    final from = pourCenter(aEnd);
                    final ctrl = Offset((from.dx + center.dx) / 2, math.min(from.dy, center.dy) - tubeH * 0.12);
                    center = _quad(from, ctrl, centerOf(i), e);
                    angle = aEnd * (1 - const Cubic(0.3, 1.35, 0.55, 1.0).transform(k));
                    drained = 1;
                  }
                  segs = [...segs, (p.color, p.amount * (1 - drained))];
                  symbols = 1 - (angle.abs() / 0.35).clamp(0.0, 1.0);
                } else if (p != null && i == p.to) {
                  final k = ((u - _phaseA) / (_phaseB - _phaseA)).clamp(0.0, 1.0);
                  final e = Curves.easeInOutSine.transform(k);
                  final keep = segs.length - p.amount;
                  segs = [...segs.take(keep.clamp(0, segs.length)), (p.color, p.amount * e)];
                  if (k > 0 && k < 1) tilt = 0.07 * math.sin(now * 26) * math.sin(math.pi * k);
                }

                // Slosh after moving or receiving: a damped tilt of the liquid surface only.
                final sl = _slosh[i];
                if (sl != null && !(p != null && i == p.from)) {
                  final k = now - sl;
                  tilt += (_sloshAmp[i] ?? 0.15) * math.exp(-k * 4.2) * math.sin(k * 15);
                }
                // Completion: a little pop, a shine sweep and sparks from the rim.
                final pop = _pop[i];
                if (pop != null) {
                  final k = now - pop;
                  if (k < 0.38) scale = 1 + 0.07 * math.sin(math.pi * k / 0.38);
                  if (k < 0.7) shine = k / 0.7;
                  if (k < 0.9) fxSparkles.add((base + Offset(tubeW / 2, lip), k / 0.9, tubeW));
                }
                // Illegal pour: shake the lifted tube.
                if (i == _shakeTube) {
                  final k = now - _shakeAt;
                  if (k < 0.45) center += Offset(math.sin(k * 46) * 6 * math.exp(-k * 7), 0);
                }

                // The running pour's tubes stay put (the stream aims at the target's resting mouth);
                // a selection or queued move on them lifts as soon as the pour is over.
                final lifted = _sel == i && !pourHere;
                final isHint = hint != null && hint.contains(i);
                final queuedHere = _queue.any((m) => m.$1 == i);
                final queuedTarget = !queuedHere && _queue.any((m) => m.$2 == i);
                final raised = lifted || (queuedHere && !pourHere);
                final painter = _TubePainter(
                  segments: segs,
                  cap: cap,
                  unit: unit,
                  hidden: hidden[i],
                  complete: complete[i] && (p == null || u >= _phaseB || i != p.to),
                  glow: _sel == i ? 1 : (queuedHere ? 0.8 : (isHint ? 0.7 : (queuedTarget ? 0.45 : 0))),
                  angle: angle,
                  tilt: tilt,
                  symbols: symbols,
                  shine: shine,
                );
                final tube = Positioned(
                  key: ValueKey('tube$i'),
                  left: center.dx - tubeW / 2,
                  top: center.dy - tubeH / 2,
                  width: tubeW,
                  height: tubeH,
                  // The slide stays in the tree for the pouring tube too, so its lift eases out
                  // into the pour arc and a queued lift eases in after it, never snapping.
                  child: IgnorePointer(
                    child: AnimatedSlide(
                      duration: const Duration(milliseconds: 200),
                      curve: raised ? Curves.easeOutBack : Curves.easeOutCubic,
                      offset: Offset(0, raised ? -0.16 : 0),
                      child: pourHere && i == p.from
                          ? Transform.rotate(angle: angle, child: CustomPaint(painter: painter))
                          : Transform.scale(scale: scale, child: CustomPaint(painter: painter)),
                    ),
                  ),
                );
                if (p != null && i == p.from) {
                  moving = tube;
                } else {
                  children.add(tube);
                }
                // Generous tap target: the whole slot column.
                children.add(Positioned(
                  left: base.dx - (slotW - tubeW) / 2,
                  top: base.dy - unit,
                  width: slotW,
                  height: tubeH + unit * 1.6,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _tap(i, tubes, complete, cap),
                  ),
                ));
              }
              if (fx != null || fxSparkles.isNotEmpty) {
                children.add(Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(painter: (fx ?? _FxPainter.none())..sparkles = fxSparkles),
                  ),
                ));
              }
              if (moving != null) children.add(moving);
              if (_busy(now)) _kick();
              return Stack(clipBehavior: Clip.none, children: children);
            }),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              RimIconButton(Icons.undo_rounded,
                  tooltip: 'Geri al (hamle sayılır)',
                  onPressed: (st['can_undo'] == true || _queue.isNotEmpty) && !s.finished ? _undo : null),
              const SizedBox(width: 24),
              RimIconButton(Icons.lightbulb_outline_rounded,
                  tooltip: 'İpucu (en fazla 2★)', onPressed: s.finished ? null : () => s.act({'hint': true})),
              const SizedBox(width: 24),
              RimIconButton(Icons.add_rounded,
                  tooltip: 'Ek boş tüp (en fazla 2★)',
                  badge: st['extra_used'] == true ? null : '1',
                  onPressed: s.finished || st['extra_used'] == true ? null : () => s.act({'extra_tube': true})),
            ],
          ),
        ),
      ],
    );
  }

  static Offset _quad(Offset a, Offset c, Offset b, double t) {
    final u = 1 - t;
    return a * (u * u) + c * (2 * u * t) + b * (t * t);
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

/// Stream, splash droplets and completion sparks, painted in board coordinates.
class _FxPainter extends CustomPainter {
  final Color color;
  final Offset lip;
  final double x, top, bottom, surf, width, phase, tubeW, unit;
  List<(Offset, double, double)> sparkles = const [];
  _FxPainter({
    required this.color,
    required this.lip,
    required this.x,
    required this.top,
    required this.bottom,
    required this.surf,
    required this.width,
    required this.phase,
    required this.tubeW,
    required this.unit,
  });
  _FxPainter.none()
      : color = Colors.transparent,
        lip = Offset.zero,
        x = 0,
        top = 0,
        bottom = 0,
        surf = 0,
        width = 0,
        phase = -1,
        tubeW = 0,
        unit = 0;

  @override
  void paint(Canvas canvas, Size size) {
    if (phase >= 0 && bottom - top > 0.5) {
      // Tapering stream with a bright core; it bends from the lip into a vertical fall.
      final w0 = width, w1 = width * 0.62;
      final path = Path()
        ..moveTo(lip.dx - w0 / 2, top)
        ..quadraticBezierTo(x - w0 / 2, top + (bottom - top) * 0.25, x - w1 / 2, bottom)
        ..lineTo(x + w1 / 2, bottom)
        ..quadraticBezierTo(x + w0 / 2, top + (bottom - top) * 0.25, lip.dx + w0 / 2, top)
        ..close();
      final rect = Rect.fromLTRB(x - w0, top, x + w0, bottom);
      canvas.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(colors: [
            Color.lerp(color, Colors.black, 0.25)!,
            Color.lerp(color, Colors.white, 0.35)!,
            color,
            Color.lerp(color, Colors.black, 0.3)!,
          ], stops: const [0, 0.35, 0.6, 1]).createShader(rect),
      );
      canvas.drawLine(Offset(x - w1 * 0.12, top + (bottom - top) * 0.2), Offset(x - w1 * 0.12, bottom - 2),
          Paint()
            ..color = Colors.white.withValues(alpha: 0.35)
            ..strokeWidth = math.max(1, w1 * 0.18)
            ..strokeCap = StrokeCap.round);
      // Splash: droplets hopping off the impact point while the stream lands.
      if (phase > 0.12 && phase < 0.95 && bottom >= surf - 1) {
        final drop = Paint()..color = Color.lerp(color, Colors.white, 0.15)!;
        for (var i = 0; i < 6; i++) {
          final t = (phase * 4.0 + i / 6) % 1.0;
          final side = (i.isEven ? 1 : -1) * (0.25 + 0.5 * ((i * 37) % 10) / 10);
          final pos = Offset(x + side * tubeW * 0.32 * t, surf - math.sin(math.pi * t) * unit * 0.38);
          canvas.drawCircle(pos, tubeW * 0.045 * (1 - t) + 0.6, drop);
        }
        // Foam ring at impact.
        canvas.drawOval(
          Rect.fromCenter(center: Offset(x, surf), width: tubeW * 0.5, height: unit * 0.12),
          Paint()..color = Colors.white.withValues(alpha: 0.22),
        );
      }
    }
    // Completion sparks: gold diamonds bursting up from the rim and fading.
    for (final (rim, t, tw) in sparkles) {
      final e = Curves.easeOutCubic.transform(t);
      final paint = Paint()..color = Lux.goldLight.withValues(alpha: (1 - t) * 0.95);
      for (var i = 0; i < 8; i++) {
        final a = -math.pi / 2 + (i - 3.5) * 0.32;
        final dist = tw * (0.5 + 0.9 * e) * (0.75 + 0.25 * ((i * 53) % 7) / 7);
        final c = rim + Offset(math.cos(a), math.sin(a)) * dist + Offset(0, tw * 0.6 * t * t);
        final r = tw * 0.07 * (1 - t * 0.6);
        final d = Path()
          ..moveTo(c.dx, c.dy - r * 1.6)
          ..lineTo(c.dx + r, c.dy)
          ..lineTo(c.dx, c.dy + r * 1.6)
          ..lineTo(c.dx - r, c.dy)
          ..close();
        canvas.drawPath(d, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_FxPainter old) => true;
}

/// Glass tube with liquid layers. `segments` = (colour id, height in layer units) bottom → top;
/// colour 0 = hidden layer. The first `hidden` whole layers are drawn as unknown.
///
/// The painter draws in the tube's own (unrotated) frame; [angle] is the tube's rotation, used to
/// keep the liquid level with world gravity, and [tilt] adds a slosh to the surface only.
class _TubePainter extends CustomPainter {
  final List<(int, double)> segments;
  final int cap;
  final double unit;
  final int hidden;
  final bool complete;
  final double glow;
  final double angle;
  final double tilt;
  final double symbols;
  final double shine;
  _TubePainter({
    required this.segments,
    required this.cap,
    required this.unit,
    required this.hidden,
    required this.complete,
    required this.glow,
    this.angle = 0,
    this.tilt = 0,
    this.symbols = 1,
    this.shine = -1,
  });

  /// Inner outline: straight walls and a semicircular bottom, as a polygon.
  List<Offset> _outline(double w, double h, double lip) {
    const inset = 2.5;
    final x0 = inset, x1 = w - inset, top = lip + inset, bot = h - inset;
    final r = (x1 - x0) / 2;
    final pts = <Offset>[Offset(x0, top), Offset(x1, top), Offset(x1, bot - r)];
    const segs = 14;
    for (var i = 1; i < segs; i++) {
      final a = math.pi * i / segs; // 0 → right, π → left, through the bottom
      pts.add(Offset(x0 + r + r * math.cos(a), bot - r + r * math.sin(a)));
    }
    pts.add(Offset(x0, bot - r));
    return pts;
  }

  /// Keep the part of [poly] where p·n ≥ c (Sutherland–Hodgman against one half-plane).
  static List<Offset> _clip(List<Offset> poly, Offset n, double c) {
    final out = <Offset>[];
    for (var i = 0; i < poly.length; i++) {
      final a = poly[i], b = poly[(i + 1) % poly.length];
      final da = a.dx * n.dx + a.dy * n.dy - c, db = b.dx * n.dx + b.dy * n.dy - c;
      if (da >= 0) out.add(a);
      if ((da >= 0) != (db >= 0)) out.add(Offset.lerp(a, b, da / (da - db))!);
    }
    return out;
  }

  static double _area(List<Offset> p) {
    var s = 0.0;
    for (var i = 0; i < p.length; i++) {
      final a = p[i], b = p[(i + 1) % p.length];
      s += a.dx * b.dy - b.dx * a.dy;
    }
    return s.abs() / 2;
  }

  /// Surface offset s such that the liquid {p·g ≥ s} inside [poly] has the given area.
  static double _level(List<Offset> poly, Offset g, double area, double lo, double hi) {
    var a = lo, b = hi; // a: full, b: empty
    for (var it = 0; it < 26; it++) {
      final m = (a + b) / 2;
      if (_area(_clip(poly, g, m)) > area) {
        a = m;
      } else {
        b = m;
      }
    }
    return (a + b) / 2;
  }

  Path _path(List<Offset> pts) => Path()..addPolygon(pts, true);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final lip = unit * 0.18;
    final body = RRect.fromRectAndCorners(
      Rect.fromLTWH(0, lip, w, h - lip),
      topLeft: Radius.circular(w * 0.12),
      topRight: Radius.circular(w * 0.12),
      bottomLeft: Radius.circular(w / 2),
      bottomRight: Radius.circular(w / 2),
    );
    if (complete || glow > 0) {
      canvas.drawRRect(
        body.inflate(4),
        Paint()
          ..color = (complete ? Lux.gold : Lux.goldLight).withValues(alpha: complete ? 0.45 : 0.4 * glow)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
      );
    }
    // Glass interior.
    canvas.drawRRect(body, Paint()..color = Colors.white.withValues(alpha: 0.05));

    final poly = _outline(w, h, lip);
    final bot = h - 2.5;
    // Gravity in the tube's frame (+ slosh), pointing "down" into the liquid.
    final a = angle + tilt;
    final g = Offset(math.sin(a), math.cos(a));
    var lo = double.infinity, hi = -double.infinity;
    for (final p in poly) {
      final d = p.dx * g.dx + p.dy * g.dy;
      lo = math.min(lo, d);
      hi = math.max(hi, d);
    }
    final upright = a.abs() < 1e-4;

    // Cumulative volumes from the upright geometry, then surfaces for the current tilt.
    final levels = <double>[]; // surface offset after each segment
    final layerTopsY = <double>[]; // upright y of each segment's top (for symbols)
    var cum = 0.0;
    for (final (_, units) in segments) {
      cum += units;
      final y = bot - cum * unit;
      layerTopsY.add(y);
      if (upright) {
        levels.add(y);
      } else {
        final vol = _area(_clip(poly, const Offset(0, 1), y));
        levels.add(_level(poly, g, vol, lo, hi));
      }
    }

    // Paint top layer first (largest region), lower layers over it.
    for (var i = segments.length - 1; i >= 0; i--) {
      final (color, units) = segments[i];
      if (units <= 0.001) continue;
      final region = _clip(poly, g, levels[i]);
      if (region.length < 3) continue;
      var layerIndex = 0;
      for (var j = 0; j < i; j++) {
        if (segments[j].$2 >= 0.999) layerIndex++;
      }
      final isHidden = color == 0 || (units >= 0.999 && layerIndex < hidden);
      final base = isHidden ? const Color(0xFF34302B) : _liquid(color);
      canvas.drawPath(
        _path(region),
        Paint()
          ..shader = LinearGradient(
            colors: [Color.lerp(base, Colors.black, 0.25)!, Color.lerp(base, Colors.white, 0.12)!, base, Color.lerp(base, Colors.black, 0.35)!],
            stops: const [0, 0.35, 0.6, 1],
          ).createShader(Rect.fromLTWH(0, 0, w, h)),
      );
    }
    // Meniscus lines on every boundary (brighter on the free surface).
    for (var i = 0; i < segments.length; i++) {
      if (segments[i].$2 <= 0.001) continue;
      final band = _clip(_clip(poly, g, levels[i]), -g, -(levels[i] + 2.0));
      if (band.length >= 3) {
        canvas.drawPath(
            _path(band), Paint()..color = Colors.white.withValues(alpha: i == segments.length - 1 ? 0.3 : 0.16));
      }
    }
    // Symbols (fade out while tilted; they'd be meaningless mid-pour).
    if (symbols > 0.02) {
      var below = bot;
      var layerIndex = 0;
      for (var i = 0; i < segments.length; i++) {
        final (color, units) = segments[i];
        final top = layerTopsY[i];
        if (units >= 0.6) {
          final c = Offset(w / 2, (top + below) / 2);
          final sz = math.min(w * 0.36, unit * 0.42);
          final isHidden = color == 0 || (units >= 0.999 && layerIndex < hidden);
          if (isHidden) _drawQuestion(canvas, c, sz);
        }
        below = top;
        if (units >= 0.999) layerIndex++;
      }
    }
    // Completion shine: a diagonal light sweep across the glass.
    if (shine >= 0 && shine <= 1) {
      canvas.save();
      canvas.clipRRect(body);
      final x = -w + (w * 3) * Curves.easeInOut.transform(shine);
      final r = Rect.fromLTWH(x, 0, w * 0.7, h);
      canvas.drawRect(
        Rect.fromLTWH(0, 0, w, h),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: 0.45), Colors.white.withValues(alpha: 0)],
          ).createShader(r),
      );
      canvas.restore();
    }
    // Glass highlights and rim.
    canvas.drawRRect(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = Colors.white.withValues(alpha: 0.38),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.14, lip + unit * 0.2, w * 0.13, h - lip - unit * 0.9), Radius.circular(w)),
      Paint()..color = Colors.white.withValues(alpha: 0.16),
    );
    final rim = RRect.fromRectAndRadius(Rect.fromLTWH(-w * 0.08, 0, w * 1.16, lip * 1.6), Radius.circular(lip));
    if (complete) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(-w * 0.1, -lip * 1.4, w * 1.2, lip * 3), Radius.circular(lip * 1.5)),
        Paint()..shader = Lux.goldGradient.createShader(Rect.fromLTWH(-w * 0.1, -lip * 1.4, w * 1.2, lip * 3)),
      );
    } else {
      canvas.drawRRect(rim, Paint()..color = Colors.white.withValues(alpha: 0.28));
    }
  }

  void _drawQuestion(Canvas canvas, Offset c, double sz) {
    final tp = TextPainter(
      text: TextSpan(text: '?', style: TextStyle(fontSize: sz * 1.3, fontWeight: FontWeight.w800, color: Lux.muted)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_TubePainter old) =>
      old.segments.length != segments.length ||
      !_sameSegs(old.segments, segments) ||
      old.cap != cap ||
      old.unit != unit ||
      old.hidden != hidden ||
      old.complete != complete ||
      old.glow != glow ||
      old.angle != angle ||
      old.tilt != tilt ||
      old.symbols != symbols ||
      old.shine != shine;

  static bool _sameSegs(List<(int, double)> a, List<(int, double)> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
