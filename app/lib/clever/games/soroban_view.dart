import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// Soroban course board: a dark-wood abacus with a gold beam, played by swiping beads toward or
/// away from the beam (tap works too), plus the problem panel, live hints and a typed-answer
/// keypad for reading and anzan problems. All checking, steps, hints, timing and stars live in
/// Rust (`core/src/games/soroban.rs`); this widget sends the per-rod digits after every move.
///
/// Feel: each bead is a damped spring that clicks against the beam / frame (small bounce +
/// haptic tick on impact). A dragged group follows the finger and flies home on release when it
/// travelled a third of the way or was flicked. Running a finger along the beam sweeps rods clear,
/// as on a real soroban; the "Sıfırla" button does the same sweep from left to right.
Widget sorobanView(BuildContext context, GameSession s) => _SorobanBoard(key: ObjectKey(s), session: s);

class _SorobanBoard extends StatefulWidget {
  final GameSession session;
  const _SorobanBoard({super.key, required this.session});

  @override
  State<_SorobanBoard> createState() => _SorobanBoardState();
}

/// Visual bead positions of one rod: 0 = resting away from the beam, 1 = touching the beam.
class _RodVis {
  double h = 0, hv = 0;
  final List<double> e = [0, 0, 0, 0];
  final List<double> ev = [0, 0, 0, 0];

  _RodVis();
  _RodVis.of(int d) {
    snap(d);
  }

  void snap(int d) {
    h = d >= 5 ? 1 : 0;
    hv = 0;
    for (var i = 0; i < 4; i++) {
      e[i] = i < d % 5 ? 1 : 0;
      ev[i] = 0;
    }
  }
}

/// A finger on the abacus: either a bead group being dragged or a sweep along the beam.
class _Touch {
  final bool sweep;
  final int rod;
  final bool heaven;
  final int bead;
  final Offset start;
  int dir = 0; // +1 toward the beam, -1 away, 0 undecided
  List<int> group = const [];
  bool dead = false;
  double progress = 0;
  double lastX;
  _Touch.sweep(this.start)
      : sweep = true,
        rod = -1,
        heaven = false,
        bead = 0,
        lastX = start.dx;
  _Touch.bead(this.rod, this.heaven, this.bead, this.start)
      : sweep = false,
        lastX = start.dx;
}

/// Abacus geometry for a given box and rod count (shared by painting and hit testing).
class _Geom {
  final Size size;
  final int rods;
  late final double border, pitch, beadW, beadH, beamH, left, top, frameW, frameH;
  late final double innerLeft, innerTop, beamTop, beamBottom, innerBottom;
  static const labelTop = 20.0, labelBottom = 24.0;

  /// Heights in bead units: heaven = bead + 1.15 travel (+ a hair), earth = 4 beads + 1.45 travel.
  static const _heavenU = 2.2, _earthU = 5.45;

  _Geom(this.size, this.rods) {
    final availH = math.max(80.0, size.height - labelTop - labelBottom);
    final w = size.width - 20; // side margin
    border = (w * 0.03).clamp(9.0, 15.0);
    var p = math.min((w - 2 * border) / rods, 76.0);
    var bw = p * 0.9;
    // Narrow rods get relatively taller beads so they stay easy to grab.
    var bh = bw * (0.6 + (rods - 7) * 0.024).clamp(0.6, 0.76);
    double need(double bh) => bh * (_heavenU + _earthU) + math.max(7.0, bh * 0.4) + 2 * border;
    if (need(bh) > availH) {
      bh = math.max(6.0, (availH - 2 * border - 7.0) / (_heavenU + _earthU + 0.4));
      if (bw > bh * 2.3) {
        bw = bh * 2.3;
        p = math.min(p, bw / 0.9);
      }
    }
    pitch = p;
    beadW = bw;
    beadH = bh;
    beamH = math.max(7.0, bh * 0.4);
    frameW = pitch * rods + 2 * border;
    frameH = beadH * (_heavenU + _earthU) + beamH + 2 * border;
    left = (size.width - frameW) / 2;
    top = labelTop + math.max(0.0, (availH - frameH) / 2);
    innerLeft = left + border;
    innerTop = top + border;
    beamTop = innerTop + beadH * _heavenU;
    beamBottom = beamTop + beamH;
    innerBottom = beamBottom + beadH * _earthU;
  }

  double get innerW => pitch * rods;
  double rodX(int r) => innerLeft + pitch * (r + 0.5);
  double get heavenRest => innerTop + beadH * 0.05;
  double get heavenActive => beamTop - beadH;
  double get heavenTravel => heavenActive - heavenRest;
  double heavenTop(double p) => heavenRest + heavenTravel * p;
  double earthActive(int i) => beamBottom + i * beadH;
  double earthRest(int i) => innerBottom - (4 - i) * beadH;
  double get earthTravel => earthRest(0) - earthActive(0);
  double earthTop(int i, double p) => earthRest(i) + (earthActive(i) - earthRest(i)) * p;
  Rect get frame => Rect.fromLTWH(left, top, frameW, frameH);
  int? rodAt(double x) {
    if (x < innerLeft - pitch * 0.2 || x > innerLeft + innerW + pitch * 0.2) return null;
    return ((x - innerLeft) / pitch).floor().clamp(0, rods - 1);
  }
}

class _SorobanBoardState extends State<_SorobanBoard> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;

  List<int> _digits = const [];
  List<_RodVis> _vis = const [];
  final Map<int, double> _holdUntil = {};
  final Map<int, int> _holdDigit = {};
  _Touch? _touch;
  _Geom? _geom;
  double _lastClick = -1;

  String _input = '';
  int _seenSerial = 0;
  double _fbAt = -10;
  bool _fbOk = false;
  int _seenIndex = -1;
  bool _showLesson = false;
  double _winAt = -1;

  GameSession get s => widget.session;
  Map<String, dynamic> get st => s.state;
  Map<String, dynamic>? get _problem => st['problem'] is Map ? Map<String, dynamic>.from(st['problem'] as Map) : null;
  bool get _interactive => st['interactive'] == true && !s.finished;

  @override
  void initState() {
    super.initState();
    final last = st['last'];
    if (last is Map) _seenSerial = (last['serial'] as num).toInt();
    _seenIndex = (st['index'] as num?)?.toInt() ?? 0;
    _syncDigits(snap: true);
    _ticker = createTicker(_onTick)..start();
    s.addListener(_onSession);
  }

  @override
  void dispose() {
    s.removeListener(_onSession);
    _ticker.dispose();
    super.dispose();
  }

  List<int> _stateRods() => [for (final d in (st['rods'] as List? ?? const [])) (d as num).toInt()];

  void _syncDigits({bool snap = false}) {
    final rods = _stateRods();
    if (rods.isEmpty) return;
    if (_vis.length != rods.length) {
      _vis = [for (final d in rods) _RodVis.of(d)];
      _digits = List.of(rods);
      return;
    }
    if (_touch != null) return;
    _digits = List.of(rods);
    if (snap) {
      for (var r = 0; r < rods.length; r++) {
        _vis[r].snap(rods[r]);
      }
    }
  }

  void _onSession() {
    final now = _now;
    final last = st['last'];
    if (last is Map) {
      final serial = (last['serial'] as num).toInt();
      if (serial != _seenSerial) {
        _seenSerial = serial;
        _fbAt = now;
        _fbOk = last['correct'] == true;
        if (_fbOk) {
          HapticFeedback.lightImpact();
        } else {
          HapticFeedback.mediumImpact();
        }
      }
    }
    final index = (st['index'] as num?)?.toInt() ?? 0;
    if (index != _seenIndex) {
      _seenIndex = index;
      _input = '';
      _touch = null;
      _holdUntil.clear();
    }
    if (st['status'] == 'won' && _winAt < 0) {
      _winAt = now;
      HapticFeedback.heavyImpact();
    }
    _syncDigits();
  }

  // ------------------------------------------------------------------ physics

  int _targetDigit(int r, double now) {
    final hold = _holdUntil[r];
    if (hold != null) {
      if (now < hold) return _holdDigit[r] ?? _digits[r];
      _holdUntil.remove(r);
    }
    return _digits[r];
  }

  bool _settled = true;

  void _stepPhysics(double dt) {
    final now = _now;
    var settled = true;
    const k = 1100.0, c = 2 * 33.2 * 0.82; // ω ≈ 33 rad/s, slightly under-damped
    final steps = math.max(1, (dt / (1 / 240)).ceil());
    final h = dt / steps;
    final t = _touch;
    for (var r = 0; r < _vis.length; r++) {
      final v = _vis[r];
      final d = _targetDigit(r, now);
      final dragHeaven = t != null && !t.sweep && t.rod == r && t.heaven && t.group.isNotEmpty;
      final dragEarth = t != null && !t.sweep && t.rod == r && !t.heaven ? t.group : const <int>[];
      if (!dragHeaven) {
        final target = d >= 5 ? 1.0 : 0.0;
        for (var i = 0; i < steps; i++) {
          final a = k * (target - v.h) - c * v.hv;
          v.hv += a * h;
          v.h += v.hv * h;
          v.h = _wall(v.h, v.hv, (nv) => v.hv = nv);
        }
        if ((v.h - target).abs() < 0.0015 && v.hv.abs() < 0.02) {
          v.h = target;
          v.hv = 0;
        } else {
          settled = false;
        }
      }
      for (var b = 0; b < 4; b++) {
        if (dragEarth.contains(b)) continue;
        final target = b < d % 5 ? 1.0 : 0.0;
        for (var i = 0; i < steps; i++) {
          final a = k * (target - v.e[b]) - c * v.ev[b];
          v.ev[b] += a * h;
          v.e[b] += v.ev[b] * h;
          v.e[b] = _wall(v.e[b], v.ev[b], (nv) => v.ev[b] = nv);
        }
        if ((v.e[b] - target).abs() < 0.0015 && v.ev[b].abs() < 0.02) {
          v.e[b] = target;
          v.ev[b] = 0;
        } else {
          settled = false;
        }
      }
    }
    _settled = settled && _holdUntil.isEmpty;
  }

  /// Beads stop hard at the beam and at the frame: a small bounce and, when fast, a haptic click.
  double _wall(double x, double v, void Function(double) setV) {
    if (x > 1 || x < 0) {
      final speed = v.abs();
      setV(-v * 0.22);
      if (speed > 2.6 && _now - _lastClick > 0.035) {
        _lastClick = _now;
        HapticFeedback.selectionClick();
      }
      return x > 1 ? 1 : 0;
    }
    return x;
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1000.0;
    _lastTick = elapsed;
    if (dt <= 0) return;
    _stepPhysics(math.min(dt, 50) / 1000.0);
    final playing = st['phase'] == 'practice' && !s.finished;
    if (playing) {
      s.tick(dt); // rebuilds through the session listener
    } else if (!_settled || _touch != null || (_winAt >= 0 && _now - _winAt < 1.6) || _now - _fbAt < 2.0) {
      if (mounted) setState(() {});
    }
  }

  // ------------------------------------------------------------------ input

  void _send() {
    final ok = s.act({'rods': List<int>.from(_digits)});
    if (!ok) _syncDigits();
  }

  /// Nearest earth bead (by current visual position) to a y coordinate.
  int _earthBeadAt(_Geom g, int rod, double y) {
    var best = 0;
    var bestD = double.infinity;
    for (var i = 0; i < 4; i++) {
      final cy = g.earthTop(i, _vis[rod].e[i]) + g.beadH / 2;
      final d = (cy - y).abs();
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  void _panStart(DragStartDetails d) {
    final g = _geom;
    if (g == null || !_interactive) return;
    final p = d.localPosition;
    final rod = g.rodAt(p.dx);
    if (rod == null || p.dy < g.top || p.dy > g.top + g.frameH) return;
    final beamC = (g.beamTop + g.beamBottom) / 2;
    if ((p.dy - beamC).abs() < g.beamH * 0.5 + 5) {
      _touch = _Touch.sweep(p);
      _sweepTo(g, p.dx);
      return;
    }
    if (p.dy < g.beamTop) {
      _touch = _Touch.bead(rod, true, 0, p);
    } else {
      _touch = _Touch.bead(rod, false, _earthBeadAt(g, rod, p.dy), p);
    }
  }

  void _sweepTo(_Geom g, double x) {
    final t = _touch!;
    final a = math.min(t.lastX, x), b = math.max(t.lastX, x);
    var changed = false;
    for (var r = 0; r < g.rods; r++) {
      final rx = g.rodX(r);
      if (rx + g.pitch * 0.35 >= a && rx - g.pitch * 0.35 <= b && _digits[r] != 0) {
        _digits[r] = 0;
        changed = true;
      }
    }
    if (changed) HapticFeedback.selectionClick();
    t.lastX = x;
  }

  void _panUpdate(DragUpdateDetails d) {
    final g = _geom;
    final t = _touch;
    if (g == null || t == null) return;
    final p = d.localPosition;
    if (t.sweep) {
      _sweepTo(g, p.dx);
      return;
    }
    if (t.dead) return;
    final dy = p.dy - t.start.dy;
    final toward = t.heaven ? dy : -dy;
    final x = _digits[t.rod];
    if (t.dir == 0) {
      if (dy.abs() < 3) return;
      t.dir = toward > 0 ? 1 : -1;
      if (t.heaven) {
        t.group = (t.dir > 0 && x < 5) || (t.dir < 0 && x >= 5) ? const [0] : const [];
      } else {
        final e = x % 5, k = t.bead;
        if (t.dir > 0 && k >= e) {
          t.group = [for (var i = e; i <= k; i++) i];
        } else if (t.dir < 0 && k < e) {
          t.group = [for (var i = k; i < e; i++) i];
        }
      }
      if (t.group.isEmpty) {
        t.dead = true;
        return;
      }
      HapticFeedback.selectionClick();
    }
    final travel = t.heaven ? g.heavenTravel : g.earthTravel;
    t.progress = (toward * t.dir / travel).clamp(0.0, 1.0);
    final base = t.dir > 0 ? 0.0 : 1.0;
    final pos = base + t.dir * t.progress;
    final v = _vis[t.rod];
    if (t.heaven) {
      v.h = pos;
      v.hv = 0;
    } else {
      for (final i in t.group) {
        v.e[i] = pos;
        v.ev[i] = 0;
      }
    }
  }

  void _panEnd(DragEndDetails d) {
    final g = _geom;
    final t = _touch;
    _touch = null;
    if (g == null || t == null) return;
    if (t.sweep) {
      _send();
      return;
    }
    if (t.dead || t.group.isEmpty) return;
    final travel = t.heaven ? g.heavenTravel : g.earthTravel;
    final vy = d.velocity.pixelsPerSecond.dy;
    final vNorm = (t.heaven ? vy : -vy) / travel * t.dir; // travels per second, + = intended way
    final commit = t.progress > 0.33 || (vNorm > 2.5 && t.progress > 0.03);
    final v = _vis[t.rod];
    if (commit) {
      final x = _digits[t.rod];
      final int nd;
      if (t.heaven) {
        nd = x >= 5 ? x - 5 : x + 5;
        v.hv = t.dir * math.max(vNorm, 3.2);
      } else {
        final ne = t.dir > 0 ? t.bead + 1 : t.bead;
        nd = (x >= 5 ? 5 : 0) + ne;
        for (final i in t.group) {
          v.ev[i] = t.dir * math.max(vNorm, 3.2);
        }
      }
      _digits[t.rod] = nd;
      if (t.progress > 0.85) HapticFeedback.selectionClick();
      _send();
    }
  }

  void _tap(TapUpDetails d) {
    final g = _geom;
    if (g == null || !_interactive) return;
    final p = d.localPosition;
    final rod = g.rodAt(p.dx);
    if (rod == null || p.dy < g.innerTop || p.dy > g.innerBottom) return;
    if (p.dy >= g.beamTop - 2 && p.dy <= g.beamBottom + 2) return;
    final x = _digits[rod];
    final v = _vis[rod];
    int nd;
    if (p.dy < g.beamTop) {
      nd = x >= 5 ? x - 5 : x + 5;
      v.hv = nd >= 5 ? 4.0 : -4.0;
    } else {
      final k = _earthBeadAt(g, rod, p.dy);
      final e = x % 5;
      final ne = k < e ? k : k + 1;
      nd = (x >= 5 ? 5 : 0) + ne;
      for (var i = math.min(e, ne); i < math.max(e, ne); i++) {
        v.ev[i] = ne > e ? 4.0 : -4.0;
      }
    }
    if (nd == x) return;
    _digits[rod] = nd;
    _send();
  }

  void _sweepButton() {
    if (!_interactive) return;
    final p = _problem;
    final from = (p?['check_from'] as num?)?.toInt() ?? 0;
    final now = _now;
    final old = List<int>.from(_digits);
    var any = false;
    for (var r = from; r < old.length; r++) {
      if (old[r] != 0) any = true;
      _holdDigit[r] = old[r];
      _holdUntil[r] = now + (r - from) * 0.04;
    }
    if (!any) return;
    HapticFeedback.selectionClick();
    s.act({'clear': true});
  }

  void _key(String k) {
    if (s.finished || st['phase'] != 'practice') return;
    HapticFeedback.selectionClick();
    setState(() {
      if (k == '⌫') {
        if (_input.isNotEmpty) _input = _input.substring(0, _input.length - 1);
      } else if (_input.length < 9) {
        _input = _input == '0' ? k : '$_input$k';
      }
    });
  }

  void _submitTyped() {
    if (_input.isEmpty || s.finished) return;
    if (s.act({'answer': int.parse(_input)})) setState(() => _input = '');
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final phase = st['phase'] as String? ?? 'lesson';
    final p = _problem;
    final typed = p?['input'] == 'typed';
    final hint = st['hint'] is Map ? Map<String, dynamic>.from(st['hint'] as Map) : null;
    final lessonOpen = phase == 'lesson' || _showLesson;

    return Stack(
      children: [
        Column(
          children: [
            _header(),
            _problemPanel(p),
            Expanded(child: _abacusArea(p, hint)),
            if (!typed) _hintLine(hint),
            if (typed) _typedControls(p) else _boardControls(p),
          ],
        ),
        Positioned.fill(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 240),
            child: lessonOpen
                ? KeyedSubtree(
                    key: const ValueKey('lesson'),
                    child: _lessonCard(start: phase == 'lesson'),
                  )
                : const SizedBox.shrink(key: ValueKey('none')),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ header

  static String _fmtTime(num ms) {
    final s = (ms / 1000).ceil();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  Widget _header() {
    final index = (st['index'] as num?)?.toInt() ?? 0;
    final total = (st['total'] as num?)?.toInt() ?? 1;
    final correct = st['correct'] ?? 0;
    final wrong = st['wrong'] ?? 0;
    final elapsed = (st['elapsed_ms'] as num?) ?? 0;
    final par = (st['par_ms'] as num?) ?? 1;
    final over = elapsed > par;
    final done = st['phase'] == 'done';
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 14, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Soru ${math.min(index + 1, total)} / $total',
                  style: Lux.ui(16, color: Lux.ink, weight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text('Doğru $correct · Yanlış $wrong', style: Lux.ui(12, color: Lux.muted)),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: SizedBox(
                    height: 4,
                    child: Stack(
                      children: [
                        const Positioned.fill(child: ColoredBox(color: Color(0xFF2A2015))),
                        AnimatedFractionallySizedBox(
                          duration: const Duration(milliseconds: 380),
                          curve: Curves.easeOutCubic,
                          widthFactor: ((done ? total : index) / total).clamp(0.0, 1.0),
                          child: const DecoratedBox(decoration: BoxDecoration(gradient: Lux.goldGradient)),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _fmtTime(elapsed),
                style: Lux.ui(18, color: over ? Lux.bordeauxLight : Lux.goldLight, weight: FontWeight.w700),
              ),
              Text('hedef ${_fmtTime(par)}', style: Lux.ui(11, color: Lux.muted)),
            ],
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: () => setState(() => _showLesson = true),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Lux.gold.withValues(alpha: 0.6)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.menu_book_rounded, size: 15, color: Lux.gold),
                  const SizedBox(width: 5),
                  Text('Ders', style: Lux.ui(13, color: Lux.gold)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ problem panel

  Widget _label(String s) => Text(
        Lux.upper(s),
        style: Lux.ui(11, color: Lux.gold, spacing: 2.0, weight: FontWeight.w700),
        textAlign: TextAlign.center,
      );

  Widget _problemPanel(Map<String, dynamic>? p) {
    Widget body;
    if (p == null) {
      body = const SizedBox(height: 60);
    } else {
      final kind = p['kind'] as String;
      final flash = p['flash'] is Map ? Map<String, dynamic>.from(p['flash'] as Map) : null;
      final stepLabel = p['step_label'] as String?;
      final children = <Widget>[_label(p['prompt'] as String? ?? '')];
      if (flash != null && flash['done'] != true) {
        children.add(_flashBox(flash));
      } else if (kind == 'set') {
        children.add(_bigText(p['text'] as String));
      } else if (kind == 'calc' ||
          kind == 'anzan' ||
          ((kind == 'flash' || kind == 'flash_anzan') && p['terms'] == null)) {
        if (p['terms'] is List) {
          children.add(_termChips(p));
        } else {
          children.add(
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                kind == 'flash' ? 'Sonucu abaküste bırak, Tamam\'a dokun' : 'Sonucu yaz',
                style: Lux.ui(16, color: Lux.goldLight, weight: FontWeight.w600),
              ),
            ),
          );
        }
      } else if (kind == 'mul' || kind == 'div') {
        children.add(_bigText(p['text'] as String));
      }
      if (stepLabel != null && (kind == 'mul' || kind == 'div')) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              stepLabel,
              textAlign: TextAlign.center,
              style: Lux.ui(13, color: Lux.goldLight),
            ),
          ),
        );
      }
      if (p['input'] == 'typed') children.add(_answerBox());
      body = Column(mainAxisSize: MainAxisSize.min, children: children);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            child: Center(child: body),
          ),
          Positioned(top: -6, left: 0, right: 0, child: IgnorePointer(child: _feedback())),
        ],
      ),
    );
  }

  Widget _bigText(String t) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: ShaderMask(
            shaderCallback: (r) => Lux.goldGradient.createShader(r),
            child: Text(t, maxLines: 1, style: Lux.display(40, color: Colors.white, spacing: 1.5)),
          ),
        ),
      );

  Widget _termChips(Map<String, dynamic> p) {
    final terms = [for (final t in p['terms'] as List) (t as num).toInt()];
    final kind = p['kind'];
    final step = (p['step'] as num?)?.toInt() ?? 0;
    final tracked = kind == 'calc';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 6,
        runSpacing: 6,
        children: [for (var i = 0; i < terms.length; i++) _chip(terms[i], i, step, tracked)],
      ),
    );
  }

  Widget _chip(int t, int i, int step, bool tracked) {
    final text = i == 0 ? '$t' : (t < 0 ? '− ${-t}' : '+ $t');
    // Term 0 is preset on the board; term i is done once step >= i.
    final done = tracked && i <= step && i > 0;
    final preset = tracked && i == 0;
    final current = tracked && i == step + 1;
    final color = current ? Lux.goldLight : (done || preset ? Lux.muted : Lux.ink);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: current ? Lux.gold.withValues(alpha: 0.16) : const Color(0x22000000),
        border: Border.all(color: current ? Lux.gold : Lux.line, width: current ? 1.4 : 1),
        boxShadow: current ? [BoxShadow(color: Lux.gold.withValues(alpha: 0.3), blurRadius: 12)] : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            style: Lux.ui(22, color: color, weight: FontWeight.w700),
          ),
          if (done) ...[const SizedBox(width: 4), const Icon(Icons.check_rounded, size: 15, color: Lux.good)],
        ],
      ),
    );
  }

  Widget _flashBox(Map<String, dynamic> f) {
    final count = (f['count'] as num).toInt();
    final index = (f['index'] as num).toInt();
    final value = f['value'] as num?;
    final lead = f['lead'] == true;
    final text = lead ? 'Hazır…' : (value == null ? '' : (value < 0 ? '− ${-value}' : '$value'));
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 220,
            height: 74,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: const Color(0xFF120D08),
              border: Border.all(color: Lux.gold.withValues(alpha: 0.55)),
            ),
            child: value == null
                ? Text(text, style: Lux.ui(18, color: Lux.muted))
                : TweenAnimationBuilder<double>(
                    key: ValueKey('flash$index'),
                    tween: Tween(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 160),
                    builder: (context, t, child) => Opacity(
                      opacity: t,
                      child: Transform.scale(scale: 0.85 + 0.15 * t, child: child),
                    ),
                    child: ShaderMask(
                      shaderCallback: (r) => Lux.goldGradient.createShader(r),
                      child: Text(text, style: Lux.display(42, color: Colors.white, spacing: 1.5)),
                    ),
                  ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < count; i++)
                Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.symmetric(horizontal: 2.5),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < index ? Lux.gold.withValues(alpha: 0.5) : (i == index ? Lux.goldLight : Lux.line),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _answerBox() {
    return Container(
      margin: const EdgeInsets.only(top: 10),
      constraints: const BoxConstraints(minWidth: 160),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: const Color(0xFF120D08),
        border: Border.all(color: Lux.gold.withValues(alpha: 0.55), width: 1.3),
      ),
      child: Text(
        _input.isEmpty ? '?' : _input,
        textAlign: TextAlign.center,
        style: Lux.ui(30, color: _input.isEmpty ? Lux.muted.withValues(alpha: 0.5) : Lux.ink, weight: FontWeight.w700),
      ),
    );
  }

  Widget _feedback() {
    final last = st['last'] is Map ? Map<String, dynamic>.from(st['last'] as Map) : null;
    if (last == null) return const SizedBox();
    final ok = last['correct'] == true;
    final note = last['note'] as String?;
    final what = last['text'] as String? ?? '';
    final plain = what == 'Kur' || what == 'Okuma';
    final text = ok ? 'Doğru' : 'Yanlış · ${plain ? 'doğrusu ' : '$what = '}${last['answer']} · senin ${last['given']}';
    return TweenAnimationBuilder<double>(
      key: ValueKey(last['serial']),
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: ok ? 1300 : 2600),
      builder: (context, t, _) {
        final fadeIn = Curves.easeOutBack.transform((t * 6).clamp(0.0, 1.0));
        final fadeOut = t < 0.75 ? 1.0 : 1 - (t - 0.75) / 0.25;
        final color = ok ? Lux.gold : Lux.bordeaux;
        return Opacity(
          opacity: (fadeOut * (t * 6).clamp(0.0, 1.0)).clamp(0.0, 1.0),
          child: Transform.scale(
            scale: 0.85 + 0.15 * fadeIn,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: Color.lerp(const Color(0xFF0B1A14), color, 0.25),
                  border: Border.all(color: color.withValues(alpha: 0.9)),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 14)],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        text,
                        maxLines: 1,
                        style: Lux.ui(16, color: ok ? Lux.goldLight : const Color(0xFFFFD6DF), weight: FontWeight.w700),
                      ),
                    ),
                    if (note != null)
                      Text(
                        note,
                        textAlign: TextAlign.center,
                        style: Lux.ui(12, color: const Color(0xFFFFD6DF)),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------------ abacus

  Widget _abacusArea(Map<String, dynamic>? p, Map<String, dynamic>? hint) {
    final hidden = st['abacus'] == 'hidden';
    final rodsCount = (st['rods_count'] as num?)?.toInt() ?? 7;
    final now = _now;
    final won = _winAt >= 0;
    final winGlow = won ? math.max(0.0, 1 - (now - _winAt) / 1.6) : 0.0;
    final fbT = now - _fbAt;
    final flash = fbT >= 0 && fbT < 0.6 ? math.pow(1 - fbT / 0.6, 2).toDouble() : 0.0;

    if (hidden) {
      final ghost = st['ghost'] is Map ? Map<String, dynamic>.from(st['ghost'] as Map) : null;
      return LayoutBuilder(
        builder: (context, box) {
          final size = Size(box.maxWidth, box.maxHeight);
          final g = _Geom(size, rodsCount);
          if (ghost == null) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.visibility_off_outlined, color: Lux.muted.withValues(alpha: 0.45), size: 30),
                  const SizedBox(height: 8),
                  Text('Soroban artık zihninde', style: Lux.ui(14, color: Lux.muted.withValues(alpha: 0.7))),
                ],
              ),
            );
          }
          final digits = [for (final d in ghost['rods'] as List) (d as num).toInt()];
          return CustomPaint(
            size: size,
            painter: _AbacusPainter(
              g: g,
              vis: [for (final d in digits) _RodVis.of(d)],
              digits: digits,
              now: now,
              opacity: (ghost['opacity'] as num).toDouble(),
            ),
          );
        },
      );
    }

    if (_vis.length != rodsCount) _syncDigits(snap: true);
    return LayoutBuilder(
      builder: (context, box) {
        final size = Size(box.maxWidth, box.maxHeight);
        final g = _Geom(size, rodsCount);
        _geom = g;
        final unitsRod = p?['units_rod'] as num?;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: _tap,
          onPanStart: _panStart,
          onPanUpdate: _panUpdate,
          onPanEnd: _panEnd,
          onPanCancel: () => _touch = null,
          child: CustomPaint(
            size: size,
            painter: _AbacusPainter(
              g: g,
              vis: _vis,
              digits: _digits,
              now: now,
              showValues: st['show_values'] == true,
              refLen: (p?['ref_len'] as num?)?.toInt() ?? 0,
              checkFrom: (p?['check_from'] as num?)?.toInt() ?? 0,
              unitsRod: unitsRod?.toInt(),
              refLabel: p?['ref_label'] as String?,
              areaLabel: p?['area_label'] as String?,
              hint: hint,
              glow: math.max(winGlow, _fbOk ? flash : 0),
              badGlow: _fbOk ? 0 : flash,
              locked: !_interactive,
            ),
          ),
        );
      },
    );
  }

  Widget _hintLine(Map<String, dynamic>? hint) {
    final guided = st['guided'] == true;
    return SizedBox(
      height: 46,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: hint == null
            ? const SizedBox.shrink()
            : Container(
                key: ValueKey('${hint['rod']}${hint['delta']}${hint['formula']}'),
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: Lux.gold.withValues(alpha: 0.08),
                  border: Border.all(color: Lux.gold.withValues(alpha: 0.35)),
                ),
                child: Row(
                  children: [
                    Icon(guided ? Icons.school_outlined : Icons.lightbulb_outline_rounded, size: 18, color: Lux.gold),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              hint['text'] as String? ?? '',
                              maxLines: 1,
                              style: Lux.ui(14, color: Lux.ink, weight: FontWeight.w600),
                            ),
                          ),
                          if ((hint['formula'] as String?)?.isNotEmpty == true)
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                hint['formula'] as String,
                                maxLines: 1,
                                style: Lux.ui(12, color: Lux.goldLight),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  // ------------------------------------------------------------------ controls

  Widget _boardControls(Map<String, dynamic>? p) {
    final playing = st['phase'] == 'practice' && !s.finished;
    final kind = p?['kind'] as String?;
    final flash = p?['flash'] is Map ? Map<String, dynamic>.from(p!['flash'] as Map) : null;
    final flashing = flash != null && flash['done'] != true;
    final canHint = playing && kind != 'flash' && st['hint'] == null;
    final hasStart = kind == 'calc' || kind == 'mul' || kind == 'div' || kind == 'set';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 14),
      child: Row(
        children: [
          _ToolButton(icon: Icons.cleaning_services_outlined, label: 'Sıfırla', onTap: playing ? _sweepButton : null),
          _ToolButton(
            icon: Icons.restart_alt_rounded,
            label: 'Baştan',
            onTap: playing && hasStart
                ? () {
                    HapticFeedback.selectionClick();
                    s.act({'reset': true});
                  }
                : null,
          ),
          _ToolButton(
            icon: Icons.lightbulb_outline_rounded,
            label: 'İpucu',
            onTap: canHint
                ? () {
                    HapticFeedback.selectionClick();
                    s.act({'hint': true});
                  }
                : null,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Center(
              child: GoldButton(
                'Tamam',
                icon: Icons.check_rounded,
                onPressed: playing && !flashing
                    ? () {
                        _touch = null;
                        s.act({'rods': List<int>.from(_digits), 'submit': true});
                      }
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _typedControls(Map<String, dynamic>? p) {
    final flash = p?['flash'] is Map ? Map<String, dynamic>.from(p!['flash'] as Map) : null;
    final enabled = st['phase'] == 'practice' && !s.finished && (flash == null || flash['done'] == true);
    const rows = [
      ['7', '8', '9'],
      ['4', '5', '6'],
      ['1', '2', '3'],
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: AnimatedOpacity(
        opacity: enabled ? 1 : 0.4,
        duration: const Duration(milliseconds: 200),
        child: IgnorePointer(
          ignoring: !enabled,
          child: Column(
            children: [
              for (final r in rows)
                Row(
                  children: [
                    for (final k in r)
                      Expanded(
                        child: _Key(label: k, onTap: () => _key(k)),
                      ),
                  ],
                ),
              Row(
                children: [
                  Expanded(
                    child: _Key(label: '⌫', onTap: () => _key('⌫'), accent: true),
                  ),
                  Expanded(
                    child: _Key(label: '0', onTap: () => _key('0')),
                  ),
                  Expanded(
                    child: _Key(label: 'Tamam', onTap: _submitTyped, primary: true),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ lesson card

  Widget _lessonCard({required bool start}) {
    final lesson = st['lesson'] is Map ? Map<String, dynamic>.from(st['lesson'] as Map) : const <String, dynamic>{};
    final lines = (lesson['text'] as String? ?? '').split('\n');
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.6),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            builder: (context, t, child) => Opacity(
              opacity: t,
              child: Transform.translate(offset: Offset(0, 14 * (1 - t)), child: child),
            ),
            child: LuxCard(
              highlight: true,
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    Lux.upper('Ders · ${st['section'] ?? ''}'),
                    style: Lux.ui(12, color: Lux.gold, spacing: 2.2, weight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(lesson['title'] as String? ?? '', style: Lux.display(21, spacing: 0.6)),
                  const SizedBox(height: 14),
                  for (final l in lines)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 9),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 8, right: 9),
                            child: Container(
                              width: 5,
                              height: 5,
                              decoration: const BoxDecoration(color: Lux.gold, shape: BoxShape.circle),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              l,
                              style: Lux.ui(15.5, color: Lux.ink, weight: FontWeight.w500),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (start) ...[
                    const SizedBox(height: 4),
                    Text(st['goal'] as String? ?? '', style: Lux.ui(13, color: Lux.muted)),
                  ],
                  const SizedBox(height: 16),
                  Center(
                    child: GoldButton(
                      start ? 'Başla' : 'Devam',
                      icon: start ? Icons.play_arrow_rounded : Icons.close_rounded,
                      onPressed: () {
                        if (start) {
                          s.act({'start': true});
                        } else {
                          setState(() => _showLesson = false);
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small labelled round tool (Sıfırla / Baştan / İpucu).
class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _ToolButton({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final on = onTap != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Lux.card,
                  border: Border.all(color: Lux.gold.withValues(alpha: on ? 0.6 : 0.2)),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 8, offset: const Offset(0, 3)),
                  ],
                ),
                child: Icon(icon, size: 21, color: on ? Lux.goldLight : Lux.muted.withValues(alpha: 0.4)),
              ),
              const SizedBox(height: 3),
              Text(label, style: Lux.ui(11, color: on ? Lux.muted : Lux.muted.withValues(alpha: 0.4))),
            ],
          ),
        ),
      ),
    );
  }
}

/// Keypad key for typed answers.
class _Key extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool accent;
  final bool primary;
  const _Key({required this.label, required this.onTap, this.accent = false, this.primary = false});

  @override
  Widget build(BuildContext context) {
    final fg = primary ? const Color(0xFF1A1206) : (accent ? Lux.gold : Lux.ink);
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          splashColor: Lux.gold.withValues(alpha: 0.2),
          onTap: onTap,
          child: Ink(
            height: 54,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: primary
                  ? Lux.goldGradient
                  : const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFF2A2116), Color(0xFF16100A)],
                    ),
              border: Border.all(color: primary ? Colors.transparent : Lux.line),
            ),
            child: Center(
              child: label == '⌫'
                  ? Icon(Icons.backspace_outlined, color: fg, size: 22)
                  : Text(
                      label,
                      style: Lux.ui(primary ? 18 : 26, color: fg, weight: FontWeight.w700),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The instrument: dark lacquered wood frame with grain, brass rods, a gold-leaf beam with unit
/// dots every third rod, bicone beads, hint arrows and optional labels.
class _AbacusPainter extends CustomPainter {
  final _Geom g;
  final List<_RodVis> vis;
  final List<int> digits;
  final double now;
  final double opacity;
  final bool showValues;
  final int refLen;
  final int checkFrom;
  final int? unitsRod;
  final String? refLabel, areaLabel;
  final Map<String, dynamic>? hint;
  final double glow, badGlow;
  final bool locked;

  _AbacusPainter({
    required this.g,
    required this.vis,
    required this.digits,
    required this.now,
    this.opacity = 1,
    this.showValues = false,
    this.refLen = 0,
    this.checkFrom = 0,
    this.unitsRod,
    this.refLabel,
    this.areaLabel,
    this.hint,
    this.glow = 0,
    this.badGlow = 0,
    this.locked = false,
  });

  static const _bead = Color(0xFF8E4426);
  static final Paint _p = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    if (vis.length != g.rods) return;
    final ghost = opacity < 0.999;
    if (ghost) {
      canvas.saveLayer(Offset.zero & size, Paint()..color = Colors.white.withValues(alpha: opacity));
    }
    final frame = RRect.fromRectAndRadius(g.frame, Radius.circular(g.border * 0.9));

    // Glow (correct answer / win) or bordeaux pulse (wrong answer) behind the frame.
    if (glow > 0.01 || badGlow > 0.01) {
      final c =
          glow >= badGlow ? Lux.gold.withValues(alpha: 0.55 * glow) : Lux.bordeaux.withValues(alpha: 0.6 * badGlow);
      canvas.drawRRect(
        frame.inflate(4),
        Paint()
          ..color = c
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
      );
    }
    // Drop shadow + wood.
    canvas.drawRRect(
      frame.shift(const Offset(0, 8)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.55)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );
    canvas.drawRRect(
      frame,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF4A2715), Color(0xFF2B160B), Color(0xFF3A1E10), Color(0xFF1C0E06)],
          stops: [0, 0.4, 0.7, 1],
        ).createShader(g.frame),
    );
    // Wood grain: faint wavy lines along the frame.
    canvas.save();
    canvas.clipRRect(frame);
    final grain = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var i = 0; i < 26; i++) {
      final y0 = g.top + g.frameH * (i + 0.5) / 26;
      final path = Path()..moveTo(g.left, y0);
      for (var x = 0.0; x <= g.frameW; x += 12) {
        path.lineTo(g.left + x, y0 + math.sin(x / 37 + i * 1.7) * 2.2 + math.sin(x / 11 + i) * 0.6);
      }
      grain.color = (i.isEven ? const Color(0x16FFD9A0) : const Color(0x14000000));
      canvas.drawPath(path, grain);
    }
    canvas.restore();
    // Gold edges.
    canvas.drawRRect(
      frame.deflate(0.8),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Lux.gold.withValues(alpha: 0.55),
    );

    // Inner well.
    final inner = Rect.fromLTRB(g.innerLeft, g.innerTop, g.innerLeft + g.innerW, g.innerBottom);
    canvas.drawRect(
      inner,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0E0704), Color(0xFF1A0E07), Color(0xFF0E0704)],
        ).createShader(inner),
    );
    canvas.drawRect(
      inner,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Lux.goldDeep.withValues(alpha: 0.7),
    );
    if (refLen > 0) {
      final ref = Rect.fromLTRB(g.innerLeft, g.innerTop, g.innerLeft + g.pitch * refLen, g.innerBottom);
      canvas.drawRect(ref, Paint()..color = Lux.bordeaux.withValues(alpha: 0.12));
    }
    // Hinted rod: a soft column of light.
    final hintRod = (hint?['rod'] as num?)?.toInt();
    final pulse = 0.5 + 0.5 * math.sin(now * 5.2);
    if (hintRod != null && hintRod < g.rods) {
      final col = Rect.fromLTRB(
        g.rodX(hintRod) - g.pitch / 2,
        g.innerTop,
        g.rodX(hintRod) + g.pitch / 2,
        g.innerBottom,
      );
      canvas.drawRect(col, Paint()..color = Lux.gold.withValues(alpha: 0.06 + 0.05 * pulse));
    }

    // Rods.
    final rodW = math.max(2.0, g.pitch * 0.055);
    for (var r = 0; r < g.rods; r++) {
      final x = g.rodX(r);
      final rr = Rect.fromLTRB(x - rodW / 2, g.innerTop, x + rodW / 2, g.innerBottom);
      canvas.drawRect(
        rr,
        Paint()
          ..shader = const LinearGradient(
            colors: [Color(0xFF6E5228), Color(0xFFD9B670), Color(0xFF6E5228)],
          ).createShader(rr),
      );
    }

    // Beam (reckoning bar) with unit dots.
    final beam = Rect.fromLTRB(g.innerLeft - 1, g.beamTop, g.innerLeft + g.innerW + 1, g.beamBottom);
    canvas.drawRect(beam.shift(const Offset(0, 2)), Paint()..color = Colors.black.withValues(alpha: 0.5));
    canvas.drawRect(beam, Paint()..shader = Lux.foil.createShader(beam));
    canvas.drawRect(
      Rect.fromLTWH(beam.left, beam.top, beam.width, beam.height * 0.35),
      Paint()..color = Colors.white.withValues(alpha: 0.18),
    );
    for (var r = 0; r < g.rods; r++) {
      if ((g.rods - 1 - r) % 3 != 0) continue;
      final c = Offset(g.rodX(r), beam.center.dy);
      final rad = math.max(1.8, g.beamH * 0.2);
      canvas.drawCircle(c, rad, Paint()..color = const Color(0xFF2A1805));
      canvas.drawCircle(
        c.translate(-rad * 0.3, -rad * 0.3),
        rad * 0.35,
        Paint()..color = Colors.white.withValues(alpha: 0.35),
      );
    }

    // Beads.
    final hintBead = hint?['bead'] as String?;
    final hintDelta = (hint?['delta'] as num?)?.toInt() ?? 0;
    for (var r = 0; r < g.rods; r++) {
      final v = vis[r];
      final cx = g.rodX(r);
      final d = digits[r];
      final hinted = <int>{};
      var hintHeaven = false;
      if (hintRod == r) {
        if (hintBead == 'heaven') {
          hintHeaven = true;
        } else {
          final e = d % 5;
          if (hintDelta > 0) {
            for (var i = e; i < e + hintDelta && i < 4; i++) {
              hinted.add(i);
            }
          } else {
            for (var i = math.max(0, e + hintDelta); i < e; i++) {
              hinted.add(i);
            }
          }
        }
      }
      _drawBead(canvas, cx, g.heavenTop(v.h), hintHeaven ? pulse : -1);
      for (var i = 0; i < 4; i++) {
        _drawBead(canvas, cx, g.earthTop(i, v.e[i]), hinted.contains(i) ? pulse : -1);
      }
      // Arrows.
      if (hintHeaven) {
        final y = g.heavenTop(v.h) + g.beadH / 2;
        _arrow(canvas, Offset(cx, y), hintDelta > 0, pulse);
      } else if (hinted.isNotEmpty) {
        final ys = hinted.map((i) => g.earthTop(i, v.e[i]) + g.beadH / 2);
        final y = hintDelta > 0 ? ys.reduce(math.min) : ys.reduce(math.max);
        _arrow(canvas, Offset(cx, y), hintDelta < 0, pulse);
      }
    }

    // Labels above (reference factor / work area) and below (values, units marker).
    if (refLen > 0 && refLabel != null) {
      _text(
        canvas,
        refLabel!,
        Offset(g.innerLeft + g.pitch * refLen / 2, g.top - 4),
        11,
        Lux.bordeauxLight,
        above: true,
      );
    }
    if (areaLabel != null) {
      final x0 = g.innerLeft + g.pitch * checkFrom;
      _text(canvas, areaLabel!, Offset((x0 + g.innerLeft + g.innerW) / 2, g.top - 4), 11, Lux.gold, above: true);
    }
    final below = g.top + g.frameH + 3;
    if (showValues) {
      for (var r = 0; r < g.rods; r++) {
        _text(
          canvas,
          '${digits[r]}',
          Offset(g.rodX(r), below),
          12,
          Lux.muted.withValues(alpha: digits[r] == 0 ? 0.3 : 0.6),
        );
      }
    }
    final u = unitsRod;
    if (u != null && u < g.rods) {
      final x = g.rodX(u);
      final tri = Path()
        ..moveTo(x, below)
        ..lineTo(x - 5, below + 7)
        ..lineTo(x + 5, below + 7)
        ..close();
      canvas.drawPath(tri, Paint()..color = Lux.gold);
      _text(canvas, 'birler', Offset(x, below + 8), 10, Lux.goldLight);
    }
    if (locked && !ghost) {
      // A faint veil when the beads can't be moved (reading problems, lesson, finished).
      canvas.drawRect(inner, Paint()..color = Colors.black.withValues(alpha: 0.08));
    }
    if (ghost) canvas.restore();
  }

  void _drawBead(Canvas canvas, double cx, double top, double hintPulse) {
    final w = g.beadW, h = g.beadH * 0.94;
    final cy = top + g.beadH / 2;
    final path = Path()
      ..moveTo(cx - w / 2, cy)
      ..lineTo(cx - w * 0.23, cy - h / 2)
      ..lineTo(cx + w * 0.23, cy - h / 2)
      ..lineTo(cx + w / 2, cy)
      ..lineTo(cx + w * 0.23, cy + h / 2)
      ..lineTo(cx - w * 0.23, cy + h / 2)
      ..close();
    final rect = Rect.fromLTWH(cx - w / 2, cy - h / 2, w, h);
    // Shadow.
    canvas.drawPath(
      path.shift(Offset(0, h * 0.12)),
      _p
        ..shader = null
        ..color = Colors.black.withValues(alpha: 0.45),
    );
    final body = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color.lerp(_bead, Colors.white, 0.38)!,
          Color.lerp(_bead, Colors.white, 0.08)!,
          Color.lerp(_bead, Colors.black, 0.25)!,
          Color.lerp(_bead, Colors.black, 0.6)!,
        ],
        stops: const [0, 0.47, 0.53, 1],
      ).createShader(rect)
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, body);
    // Soften the corners: stroke the same shape with a round join.
    canvas.drawPath(
      path,
      body
        ..style = PaintingStyle.stroke
        ..strokeWidth = h * 0.16,
    );
    body.style = PaintingStyle.fill;
    // Ridge and specular highlight.
    canvas.drawLine(
      Offset(cx - w * 0.46, cy),
      Offset(cx + w * 0.46, cy),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.16)
        ..strokeWidth = 0.8,
    );
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx - w * 0.14, cy - h * 0.26), width: w * 0.3, height: h * 0.16),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.28)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5),
    );
    if (hintPulse >= 0) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6 + 1.2 * hintPulse
          ..strokeJoin = StrokeJoin.round
          ..color = Lux.goldLight.withValues(alpha: 0.65 + 0.35 * hintPulse),
      );
    }
  }

  /// Gold chevron on a bead pointing up or down, bobbing in the direction of motion.
  void _arrow(Canvas canvas, Offset bead, bool down, double pulse) {
    // Drawn on the bead itself (rods are too close for a side arrow), nudging the way to push.
    final s = math.max(8.0, math.min(g.beadH * 0.9, g.beadW * 0.5));
    final bob = (down ? 1 : -1) * g.beadH * 0.12 * pulse;
    final c = Offset(bead.dx, bead.dy + bob);
    final dir = down ? 1.0 : -1.0;
    final path = Path()
      ..moveTo(c.dx - s * 0.45, c.dy - dir * s * 0.2)
      ..lineTo(c.dx, c.dy + dir * s * 0.32)
      ..lineTo(c.dx + s * 0.45, c.dy - dir * s * 0.2);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.34
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.black.withValues(alpha: 0.6),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = Lux.goldLight,
    );
  }

  void _text(Canvas canvas, String t, Offset at, double size, Color color, {bool above = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: Lux.upper(t),
        style: Lux.ui(size, color: color, weight: FontWeight.w600, spacing: 1.2),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(at.dx - tp.width / 2, above ? at.dy - tp.height : at.dy));
  }

  @override
  bool shouldRepaint(_AbacusPainter old) => true;
}
