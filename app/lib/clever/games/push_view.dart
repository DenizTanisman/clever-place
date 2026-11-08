import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// İtiş board against the AI.
///
/// Layout: opponent strip (rank medallion, "düşünüyor…", pearls it has pushed off) · the hexagonal
/// tray (smoked-ebony plate with 61 carved dimples, an obsidian gutter all round, a gold bezel) ·
/// your strip (garnets you have pushed off, no-capture counter) · undo / hint.
///
/// Input (drag first): touch one of your pearls and sweep across up to three in a row to select
/// them; keep sweeping past the line (or start a new drag on the selection) to shove the group:
/// it follows the finger, the six direction chevrons around it glow gold when that way is legal
/// and bordeaux when not; release to move. Taps work too: tap pearls to build the line, then tap a
/// chevron or the cell a pearl should step into.
///
/// Motion: every move (yours and the AI's) is replayed from `last_move`: plain moves slide; a push
/// winds up and thrusts, the shoved garnets/pearls jolt forward with a small impact ring; a marble
/// pushed off tips over the edge into the gutter with a clack and rolls along it to its slot.
/// A Ticker runs only while something moves; the AI is asked (off the UI isolate) after a short,
/// human-like pause once the previous animation has finished.
Widget pushView(BuildContext context, GameSession s) => _PushBoard(session: s);

const _garnet = Color(0xFFA51D40);
const _rose = Color(0xFFFF7896);
const _pearlGlow = Color(0xFFFFE7B0);

const double _sqrt3_2 = 0.8660254037844386;

// Tray geometry, in units of the cell spacing (perpendicular margins beyond the outer cell centres).
const double _mField = 0.55;
const double _gutterW = 0.80;
const double _rimW = 0.24;
const double _mGutter = _mField + _gutterW;
const double _mRim = _mGutter + _rimW;
double _circ(double m) => 4 + m / _sqrt3_2;
final double _rGutterLine = _circ(_mField + _gutterW / 2);
final double _unitsW = 2 * _circ(_mRim);
const double _unitsH = 2 * (4 * _sqrt3_2 + _mRim);
const double _marbleR = 0.45;
const double _gutterMarbleR = 0.31;
const double _slotGap = 0.72;

/// Axial directions (q, r), counter-clockwise from east on screen.
const _dirs = [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)];

/// Cells in core order: rows r = −4…4 from the top, q ascending.
final List<(int, int)> _cells = [
  for (var r = -4; r <= 4; r++)
    for (var q = math.max(-4, -4 - r); q <= math.min(4, 4 - r); q++) (q, r)
];
final Map<int, int> _idxByKey = {for (var i = 0; i < _cells.length; i++) _key(_cells[i].$1, _cells[i].$2): i};
int _key(int q, int r) => (q + 4) * 9 + (r + 4);
int _at(int q, int r) => _idxByKey[_key(q, r)] ?? -1;
int _nb(int i, int d) => _at(_cells[i].$1 + _dirs[d].$1, _cells[i].$2 + _dirs[d].$2);

/// Cell centre in board units (x right, y down; neighbours are 1 apart).
Offset _u(int i) => Offset(_cells[i].$1 + _cells[i].$2 / 2, _cells[i].$2 * _sqrt3_2);
Offset _dirU(int d) => Offset(_dirs[d].$1 + _dirs[d].$2 / 2, _dirs[d].$2 * _sqrt3_2);
int _ring(int i) {
  final (q, r) = _cells[i];
  return math.max(q.abs(), math.max(r.abs(), (q + r).abs()));
}

int _cellOf(Object? v) {
  final l = v as List;
  return _at((l[0] as num).toInt(), (l[1] as num).toInt());
}

int? _dirBetween(int a, int b) {
  final dq = _cells[b].$1 - _cells[a].$1, dr = _cells[b].$2 - _cells[a].$2;
  for (var d = 0; d < 6; d++) {
    if (_dirs[d].$1 == dq && _dirs[d].$2 == dr) return d;
  }
  return null;
}

/// True when the cells form a straight, gap-free line of 1–3.
bool _isLine(List<int> cs) {
  if (cs.isEmpty || cs.length > 3) return false;
  if (cs.length == 1) return true;
  if (cs.length == 2) return _dirBetween(cs[0], cs[1]) != null;
  for (final m in cs) {
    final o = cs.where((x) => x != m).toList();
    if (o.length != 2) return false;
    final d = _dirBetween(m, o[0]);
    if (d != null && _dirBetween(m, o[1]) == (d + 3) % 6) return true;
  }
  return false;
}

String _moveKey(Iterable<int> cells, int dir) => '${(cells.toList()..sort()).join(',')}|$dir';

/// Hexagon vertex k (flat-top: k·60°, y down) for circumradius [r].
Offset _hexV(int k, double r) => Offset(math.cos(k * math.pi / 3), math.sin(k * math.pi / 3)) * r;

Path _hexPath(Offset c, double r, double round) {
  final path = Path();
  for (var k = 0; k < 6; k++) {
    final v = c + _hexV(k, r);
    final prev = c + _hexV((k + 5) % 6, r);
    final next = c + _hexV((k + 1) % 6, r);
    final a = v + (prev - v) / (prev - v).distance * round;
    final b = v + (next - v) / (next - v).distance * round;
    if (k == 0) {
      path.moveTo(a.dx, a.dy);
    } else {
      path.lineTo(a.dx, a.dy);
    }
    path.quadraticBezierTo(v.dx, v.dy, b.dx, b.dy);
  }
  return path..close();
}

/// Gutter centre line: perimeter parameter ↔ point (units), and the rolling path between two points.
class _Gutter {
  static double get r => _rGutterLine;
  static double get perim => 6 * r;

  static double param(Offset p) {
    var best = double.infinity;
    var at = 0.0;
    for (var k = 0; k < 6; k++) {
      final a = _hexV(k, r), b = _hexV((k + 1) % 6, r);
      final ab = b - a;
      final w = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / (ab.distanceSquared)).clamp(0.0, 1.0);
      final d = (a + ab * w - p).distance;
      if (d < best) {
        best = d;
        at = (k + w) * r;
      }
    }
    return at;
  }

  static Offset point(double s) {
    final x = s % perim;
    final k = (x / r).floor() % 6;
    final w = (x - k * r) / r;
    return Offset.lerp(_hexV(k, r), _hexV((k + 1) % 6, r), w)!;
  }

  /// Polyline along the gutter from [a] to [b], the shorter way round.
  static List<Offset> path(Offset a, Offset b) {
    final sa = param(a), sb = param(b);
    var f = (sb - sa) % perim;
    final fwd = f <= perim / 2;
    if (!fwd) f = perim - f;
    final pts = <Offset>[a];
    final step = r / 6;
    for (var d = step; d < f; d += step) {
      pts.add(point(fwd ? sa + d : sa - d));
    }
    pts.add(b);
    return pts;
  }

  /// Where a ray from [p] along unit [u] crosses the gutter centre line.
  static Offset hit(Offset p, Offset u) {
    var bestT = double.infinity;
    for (var k = 0; k < 6; k++) {
      final a = _hexV(k, r), b = _hexV((k + 1) % 6, r);
      final e = b - a;
      final den = u.dx * e.dy - u.dy * e.dx;
      if (den.abs() < 1e-9) continue;
      final ap = a - p;
      final t = (ap.dx * e.dy - ap.dy * e.dx) / den;
      final w = (ap.dx * u.dy - ap.dy * u.dx) / den;
      if (t > 0 && w >= -1e-6 && w <= 1 + 1e-6 && t < bestT) bestT = t;
    }
    return bestT.isFinite ? p + u * bestT : p + u;
  }

  /// Resting slot [i] (0..5) for a pushed-off marble: garnets you took on the bottom edge, pearls
  /// the AI took on the top edge.
  static Offset slot(bool pearl, int i) {
    final y = r * _sqrt3_2 * (pearl ? -1 : 1);
    return Offset((i - 2.5) * _slotGap, y);
  }
}

class _Poly {
  final List<Offset> pts;
  final List<double> cum;
  _Poly._(this.pts, this.cum);

  factory _Poly(List<Offset> pts) {
    final cum = <double>[0];
    for (var i = 1; i < pts.length; i++) {
      cum.add(cum.last + (pts[i] - pts[i - 1]).distance);
    }
    return _Poly._(pts, cum);
  }

  double get length => cum.last;

  Offset at(double d) {
    if (pts.length == 1 || d <= 0) return pts.first;
    if (d >= length) return pts.last;
    var lo = 0, hi = cum.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (cum[mid] <= d) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final seg = cum[hi] - cum[lo];
    final t = seg <= 0 ? 0.0 : (d - cum[lo]) / seg;
    return Offset.lerp(pts[lo], pts[hi], t)!;
  }
}

/// Board geometry: units ↔ pixels.
class _Geo {
  final Offset center;
  final double s;
  const _Geo(this.center, this.s);

  Offset px(Offset u) => center + u * s;
  Offset unit(Offset p) => (p - center) / s;

  /// Nearest cell to a pixel point (null when clearly off the field).
  int? cellAt(Offset p) {
    final u = unit(p);
    var best = -1;
    var bd = double.infinity;
    for (var i = 0; i < _cells.length; i++) {
      final d = (_u(i) - u).distanceSquared;
      if (d < bd) {
        bd = d;
        best = i;
      }
    }
    return bd <= 0.62 * 0.62 ? best : null;
  }
}

class _Mv {
  final List<int> line; // tail → head
  final int dir;
  final bool inline;
  final List<int> pushed;
  final List<int> pushedTo; // −1 = off the board
  final bool captured;
  _Mv(this.line, this.dir, this.inline, this.pushed, this.pushedTo, this.captured);

  static _Mv parse(Map m) => _Mv(
        [for (final c in m['line'] as List) _cellOf(c)],
        (m['dir'] as num).toInt(),
        m['kind'] == 'inline',
        [for (final c in (m['pushed'] as List? ?? const [])) _cellOf(c)],
        [for (final c in (m['pushed_to'] as List? ?? const [])) c == null ? -1 : _cellOf(c)],
        m['captured'] == true,
      );
}

/// A marble sliding between two cells.
class _Sprite {
  final bool pearl;
  final Offset from, to;
  final int toIdx;
  final double start, dur;
  final int kind; // 0 pusher (wind-up + thrust), 1 shoved (jolt), 2 plain slide
  _Sprite(this.pearl, this.from, this.to, this.toIdx, this.start, this.dur, this.kind);

  static const _thrust = Cubic(0.62, -0.32, 0.38, 1.0);
  static const _slide = Cubic(0.4, 0.0, 0.2, 1.0);

  bool done(double now) => now >= start + dur;
  double u(double now) => ((now - start) / dur).clamp(0.0, 1.0);

  Offset at(double now) {
    final x = u(now);
    final e = switch (kind) {
      0 => _thrust.transform(x),
      1 => Curves.easeOutBack.transform(x),
      _ => _slide.transform(x),
    };
    return from + (to - from) * e;
  }
}

/// A marble shoved off the board: over the edge into the gutter, then rolling to its slot.
class _Fall {
  final bool pearl;
  final Offset from, edge;
  final _Poly roll;
  final double start, t1, t2;
  final int slot;
  bool clacked = false;
  _Fall(this.pearl, this.from, this.edge, this.roll, this.start, this.t1, this.t2, this.slot);

  bool done(double now) => now >= t2;
}

class _Impact {
  final Offset at;
  final double t;
  final bool onPearl;
  bool felt = false;
  _Impact(this.at, this.t, this.onPearl);
}

class _Landing {
  final int idx;
  final double at, strength;
  _Landing(this.idx, this.at, this.strength);
}

enum _Drag { none, selecting, moving }

class _PushBoard extends StatefulWidget {
  final GameSession session;
  const _PushBoard({required this.session});

  @override
  State<_PushBoard> createState() => _PushBoardState();
}

class _PushBoardState extends State<_PushBoard> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) => _onTick());
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;

  GameSession get s => widget.session;

  _Geo? _geo;

  int _seenPly = -1;
  String _boardSig = '';
  final List<_Sprite> _sprites = [];
  final List<_Fall> _falls = [];
  final List<_Impact> _impacts = [];
  final List<_Landing> _landings = [];
  double _animUntil = -1;

  // Selection and dragging.
  List<int> _sel = [];
  _Drag _drag = _Drag.none;
  Offset _anchor = Offset.zero, _finger = Offset.zero;
  int? _dragDir;
  int? _lastDragDir;
  // How far (units) the finger must travel before a release plays the move: a drag that grows out
  // of a selection sweep must clearly reach into the next cell, so an overshoot never moves.
  double _commitMin = 0.42;
  // Spring-back of a rejected or too-short drag: offset (units) and start time.
  Offset _returnOff = Offset.zero;
  double _returnAt = -10;
  // A committed drag: the offset the group was shown at when released.
  Offset? _pendingDrop;
  double _shakeAt = -10;

  Timer? _aiTimer;
  bool _aiInFlight = false, _hintBusy = false;
  double _endAt = -1;

  @override
  void initState() {
    super.initState();
    _resetSeen();
    s.addListener(_onSession);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeScheduleAi());
  }

  void _resetSeen() {
    final lm = s.state['last_move'];
    _seenPly = lm is Map ? (lm['ply'] as num).toInt() : -1;
    _boardSig = _sig();
  }

  @override
  void didUpdateWidget(covariant _PushBoard old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      old.session.removeListener(_onSession);
      widget.session.addListener(_onSession);
      _aiTimer?.cancel();
      _aiTimer = null;
      _aiInFlight = false;
      _clearAnims();
      _sel = [];
      _drag = _Drag.none;
      _endAt = -1;
      _resetSeen();
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeScheduleAi());
    }
  }

  @override
  void dispose() {
    s.removeListener(_onSession);
    _aiTimer?.cancel();
    _ticker.dispose();
    super.dispose();
  }

  String _sig() => '${s.state['board']}';

  void _clearAnims() {
    _sprites.clear();
    _falls.clear();
    _impacts.clear();
    _landings.clear();
    _animUntil = -1;
  }

  void _kick() {
    if (!_ticker.isActive) _ticker.start();
  }

  bool get _animating => _sprites.isNotEmpty || _falls.isNotEmpty || _now < _animUntil;

  bool _busy(double now) =>
      _animating ||
      _impacts.isNotEmpty ||
      _landings.isNotEmpty ||
      _drag != _Drag.none ||
      _sel.isNotEmpty ||
      s.state['hint'] is Map ||
      now - _returnAt < 0.3 ||
      now - _shakeAt < 0.5 ||
      (_endAt >= 0 && now - _endAt < 1.8);

  bool get _yourTurn => !s.finished && s.state['turn'] == 'you';
  bool get _canInput => _yourTurn && !_animating && !_aiInFlight && _aiTimer == null && !_hintBusy;

  // ------------------------------------------------------------------------------------------
  // State parsing

  Object? _boardSrc;
  List<int> _vals = List.filled(61, 0);

  List<int> _board() {
    final b = s.state['board'];
    if (identical(b, _boardSrc)) return _vals;
    _boardSrc = b;
    final out = List.filled(61, 0);
    if (b is List) {
      for (final e in b) {
        final l = e as List;
        final i = _at((l[0] as num).toInt(), (l[1] as num).toInt());
        if (i >= 0) out[i] = (l[2] as num).toInt();
      }
    }
    _vals = out;
    return out;
  }

  Object? _movesSrc;
  Map<String, _Mv> _movesCache = const {};

  Map<String, _Mv> _moves() {
    final ms = s.state['moves'];
    if (identical(ms, _movesSrc)) return _movesCache;
    _movesSrc = ms;
    final out = <String, _Mv>{};
    if (ms is List) {
      for (final m in ms) {
        final mv = _Mv.parse(m as Map);
        out[_moveKey(mv.line, mv.dir)] = mv;
      }
    }
    _movesCache = out;
    return out;
  }

  _Mv? _legal(List<int> sel, int dir) => sel.isEmpty ? null : _moves()[_moveKey(sel, dir)];

  // ------------------------------------------------------------------------------------------
  // Session → animations

  void _onSession() {
    final lm = s.state['last_move'];
    final ply = lm is Map ? (lm['ply'] as num).toInt() : -1;
    final sig = _sig();
    if (lm is Map && ply > _seenPly) {
      _seenPly = ply;
      _startMove(lm);
    } else if (sig != _boardSig) {
      // Undo: show the new position at once.
      _seenPly = math.max(_seenPly, ply);
      _clearAnims();
      _sel = [];
      _endAt = -1;
    }
    _boardSig = sig;
    _maybeScheduleAi();
    if (mounted) setState(() {});
  }

  void _startMove(Map lm) {
    final mv = _Mv.parse(lm);
    final you = lm['who'] == 'you';
    final now = _now;
    final u = _dirU(mv.dir);
    final drop = _pendingDrop;
    _pendingDrop = null;
    final pushing = mv.pushed.isNotEmpty;
    final double d = drop != null ? (0.16 + 0.14 * (1 - drop.distance).clamp(0.0, 1.0)) : (pushing ? 0.5 : 0.32);
    final contact = drop != null ? now : now + d * 0.34;
    for (final c in mv.line) {
      final to = _nb(c, mv.dir);
      if (to < 0) continue;
      _sprites.add(_Sprite(you, _u(c) + (drop ?? Offset.zero), _u(to), to, now, d, drop != null ? 2 : (pushing ? 0 : 2)));
    }
    final captured = s.state['captured'] as Map? ?? const {};
    for (var k = 0; k < mv.pushed.length; k++) {
      final c = mv.pushed[k];
      final to = k < mv.pushedTo.length ? mv.pushedTo[k] : -1;
      final from = _u(c) + (drop ?? Offset.zero);
      if (to >= 0) {
        _sprites.add(_Sprite(!you, from, _u(to), to, contact, drop != null ? d : d * 0.72, drop != null ? 2 : 1));
      } else {
        // Over the edge, into the gutter, and round to the next free slot.
        final edge = _Gutter.hit(_u(c), u);
        final taken = ((you ? captured['you'] : captured['ai']) as num?)?.toInt() ?? 1;
        final slot = (taken - 1).clamp(0, 5);
        final pearl = !you;
        final target = _Gutter.slot(pearl, slot);
        final roll = _Poly(_Gutter.path(edge, target));
        final t1 = contact + 0.26;
        final t2 = t1 + (0.25 + roll.length / 7.5).clamp(0.35, 1.25);
        _falls.add(_Fall(pearl, from, edge, roll, contact, t1, t2, slot));
      }
    }
    if (pushing) {
      final head = mv.line.last;
      _impacts.add(_Impact(_u(head) + u * 0.5, contact, !you));
    }
    _animUntil = now + d + 0.02;
    _sel = [];
    _kick();
  }

  void _onTick() {
    final now = _now;
    final arrived = _sprites.where((sp) => sp.done(now)).toList();
    if (arrived.isNotEmpty) {
      _sprites.removeWhere((sp) => sp.done(now));
      for (final sp in arrived) {
        _landings.add(_Landing(sp.toIdx, now, sp.kind == 1 ? 1.0 : 0.6));
      }
      if (_sprites.isEmpty) HapticFeedback.selectionClick();
    }
    for (final im in _impacts) {
      if (!im.felt && now >= im.t) {
        im.felt = true;
        HapticFeedback.mediumImpact();
      }
    }
    _impacts.removeWhere((im) => now - im.t > 0.55);
    for (final f in _falls) {
      if (!f.clacked && now >= f.t1) {
        f.clacked = true;
        HapticFeedback.heavyImpact();
      }
    }
    final settled = _falls.where((f) => f.done(now)).toList();
    if (settled.isNotEmpty) {
      HapticFeedback.lightImpact();
      _falls.removeWhere((f) => f.done(now));
    }
    _landings.removeWhere((l) => now - l.at > 0.5);
    if (!_animating && s.finished && _endAt < 0) {
      _endAt = now + 0.2;
      Future.delayed(const Duration(milliseconds: 200), () {
        if (!mounted) return;
        if (s.status == 'won') {
          HapticFeedback.heavyImpact();
        } else {
          HapticFeedback.mediumImpact();
        }
      });
    }
    if (!_animating) _maybeScheduleAi();
    if (!_busy(now)) _ticker.stop();
    if (mounted) setState(() {});
  }

  void _maybeScheduleAi() {
    if (!mounted || s.finished || s.state['ai_pending'] != true) return;
    if (_aiTimer != null || _aiInFlight || _animating) return;
    final cx = (s.state['complexity'] as num?)?.toDouble() ?? 0.3;
    final jitter = ((_seenPly * 7919 + 13) % 97) / 97.0;
    final ms = (480 + 400 * cx + 220 * jitter).clamp(450, 1100).round();
    _aiTimer = Timer(Duration(milliseconds: ms), () async {
      _aiTimer = null;
      if (!mounted || s.finished || s.state['ai_pending'] != true) return;
      _aiInFlight = true;
      setState(() {});
      await s.actAsync({'ai': true});
      _aiInFlight = false;
      if (mounted) setState(() {});
    });
    setState(() {});
  }

  // ------------------------------------------------------------------------------------------
  // Input

  List<List<int>> _qr(List<int> cs) => [
        for (final c in cs) [_cells[c].$1, _cells[c].$2]
      ];

  void _shake() {
    HapticFeedback.mediumImpact();
    _shakeAt = _now;
    _kick();
  }

  /// Plays the selection in [dir]; on an illegal choice the core's reason shows as a toast.
  void _play(int dir, {Offset? dropOffset}) {
    if (_sel.isEmpty) return;
    final mv = _legal(_sel, dir);
    if (mv != null) {
      _pendingDrop = dropOffset;
      s.act({'line': _qr(mv.line), 'dir': dir});
    } else {
      s.act({'line': _qr(_sel), 'dir': dir});
      if (dropOffset != null) {
        _returnOff = dropOffset;
        _returnAt = _now;
      }
      _shake();
    }
  }

  Offset _centroid(List<int> cs) {
    var c = Offset.zero;
    for (final i in cs) {
      c += _u(i);
    }
    return c / cs.length.toDouble();
  }

  /// Where the chevron for [dir] sits around the selection (units).
  Offset _arrowPos(List<int> cs, int dir) {
    final c = _centroid(cs);
    final u = _dirU(dir);
    var ext = 0.0;
    for (final i in cs) {
      final p = _u(i) - c;
      ext = math.max(ext, p.dx * u.dx + p.dy * u.dy);
    }
    return c + u * (ext + 0.66);
  }

  /// True while a release would play the dragged move (far enough along a direction).
  bool get _dragReady {
    final geo = _geo;
    if (_drag != _Drag.moving || _dragDir == null || geo == null) return false;
    return ((_finger - _anchor) / geo.s).distance >= _commitMin;
  }

  int? _dirOf(Offset v) {
    if (v.distance < 0.28) return null;
    final a = math.atan2(-v.dy, v.dx);
    return ((a / (math.pi / 3)).round() % 6 + 6) % 6;
  }

  /// The selection's displayed offset while it is being dragged (units).
  Offset _dragOffset() {
    if (_drag != _Drag.moving) return Offset.zero;
    final geo = _geo;
    if (geo == null) return Offset.zero;
    final v = (_finger - _anchor) / geo.s;
    final d = _dirOf(v);
    if (d == null) return v * 0.3;
    final u = _dirU(d);
    final proj = (v.dx * u.dx + v.dy * u.dy).clamp(0.0, 0.92);
    final legal = _legal(_sel, d) != null;
    final along = u * (legal ? proj : proj * 0.22);
    // A touch of the finger's sideways drift keeps it feeling attached.
    final side = (v - u * (v.dx * u.dx + v.dy * u.dy)) * 0.12;
    return along + side;
  }

  void _panStart(Offset p) {
    final geo = _geo;
    if (geo == null || !_canInput) return;
    final c = geo.cellAt(p);
    final board = _board();
    _commitMin = 0.42;
    if (c != null && _sel.contains(c)) {
      _drag = _Drag.moving;
      _anchor = p;
      _finger = p;
    } else if (c != null && board[c] == 1) {
      HapticFeedback.selectionClick();
      _sel = [c];
      _drag = _Drag.selecting;
      _anchor = geo.px(_u(c));
      _finger = p;
    } else if (_sel.isNotEmpty && _sel.any((i) => (geo.px(_u(i)) - p).distance < geo.s * 1.25)) {
      _drag = _Drag.moving;
      _anchor = p;
      _finger = p;
    } else {
      _sel = [];
      _drag = _Drag.none;
    }
    _dragDir = null;
    _lastDragDir = null;
    setState(() {});
    _kick();
  }

  void _panUpdate(Offset p) {
    final geo = _geo;
    if (geo == null || _drag == _Drag.none) return;
    _finger = p;
    if (_drag == _Drag.selecting) {
      final c = geo.cellAt(p);
      final board = _board();
      if (c != null && board[c] == 1) {
        if (_sel.contains(c)) {
          final k = _sel.indexOf(c);
          if (k < _sel.length - 1) {
            _sel = _sel.sublist(0, k + 1);
            HapticFeedback.selectionClick();
          }
        } else if (_isLine([..._sel, c])) {
          _sel = [..._sel, c];
          HapticFeedback.selectionClick();
        }
        _anchor = geo.px(_u(_sel.last));
      } else {
        final last = geo.px(_u(_sel.last));
        if ((p - last).distance > geo.s * 0.55) {
          _drag = _Drag.moving;
          _anchor = last;
          _commitMin = 0.64;
        }
      }
    }
    if (_drag == _Drag.moving) {
      // Sliding onto another of your marbles that extends the line grows the selection instead
      // (a group can never move into its own marbles, so nothing is lost).
      final c = geo.cellAt(p);
      if (c != null &&
          _board()[c] == 1 &&
          !_sel.contains(c) &&
          _isLine([..._sel, c]) &&
          (geo.px(_u(c)) - p).distance < geo.s * 0.42) {
        _sel = [..._sel, c];
        _drag = _Drag.selecting;
        _anchor = geo.px(_u(c));
        _dragDir = null;
        _lastDragDir = null;
        HapticFeedback.selectionClick();
        setState(() {});
        return;
      }
      final d = _dirOf((_finger - _anchor) / geo.s);
      _dragDir = d;
      if (d != null && d != _lastDragDir) {
        HapticFeedback.selectionClick();
        _lastDragDir = d;
      }
    }
    setState(() {});
  }

  void _panEnd() {
    final geo = _geo;
    if (geo == null) return;
    if (_drag == _Drag.moving) {
      final off = _dragOffset();
      final v = (_finger - _anchor) / geo.s;
      final d = _dirOf(v);
      _drag = _Drag.none;
      _dragDir = null;
      if (d != null && v.distance >= _commitMin) {
        _play(d, dropOffset: off);
      } else {
        _returnOff = off;
        _returnAt = _now;
      }
    } else {
      _drag = _Drag.none;
    }
    if (mounted) setState(() {});
    _kick();
  }

  void _tap(Offset p) {
    final geo = _geo;
    if (geo == null || !_canInput) return;
    // Chevrons first.
    if (_sel.isNotEmpty) {
      for (var d = 0; d < 6; d++) {
        if ((geo.px(_arrowPos(_sel, d)) - p).distance < geo.s * 0.3) {
          _play(d);
          setState(() {});
          return;
        }
      }
    }
    final c = geo.cellAt(p);
    if (c == null) {
      setState(() => _sel = []);
      return;
    }
    final board = _board();
    if (board[c] == 1) {
      HapticFeedback.selectionClick();
      setState(() {
        if (_sel.contains(c)) {
          final rest = _sel.where((x) => x != c).toList();
          _sel = _isLine(rest) ? rest : [];
        } else if (_isLine([..._sel, c])) {
          _sel = [..._sel, c];
        } else {
          _sel = [c];
        }
      });
      _kick();
      return;
    }
    // Tapping the cell a selected marble would step into plays that direction.
    if (_sel.isNotEmpty) {
      for (final i in _sel) {
        final d = _dirBetween(i, c);
        if (d != null) {
          _play(d);
          setState(() {});
          return;
        }
      }
    }
    setState(() => _sel = []);
  }

  Future<void> _askHint() async {
    if (!_canInput) return;
    setState(() {
      _hintBusy = true;
      _sel = [];
    });
    await s.actAsync({'hint': true});
    if (!mounted) return;
    final h = s.state['hint'];
    setState(() {
      _hintBusy = false;
      if (h is Map) _sel = [for (final c in h['line'] as List) _cellOf(c)];
    });
    _kick();
  }

  // ------------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final st = s.state;
    if (st['board'] is! List) return const SizedBox();
    final captured = st['captured'] as Map? ?? const {};
    final counts = st['counts'] as Map? ?? const {};
    final target = (st['target'] as num?)?.toInt() ?? 6;
    final quiet = (st['quiet'] as num?)?.toInt() ?? 0;
    final quietLimit = (st['quiet_limit'] as num?)?.toInt() ?? 100;
    final rank = (st['title'] as String?) ?? '';
    final thinking = _aiTimer != null || _aiInFlight;
    final playing = !s.finished;

    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(builder: (context, box) {
            final w = box.maxWidth, h = box.maxHeight;
            const topH = 64.0, botH = 58.0, gap = 8.0;
            final sc = math.min((w - 6) / _unitsW, (h - topH - botH - 2 * gap) / _unitsH).clamp(8.0, 200.0);
            final bw = sc * _unitsW, bh = sc * _unitsH;
            final y0 = ((h - (topH + botH + 2 * gap + bh)) / 2).clamp(0.0, 400.0);
            final boardRect = Rect.fromLTWH((w - bw) / 2, y0 + topH + gap, bw, bh);
            final geo = _Geo(boardRect.center, sc);
            _geo = geo;
            final stripW = math.min(w - 16, bw * 0.96);
            final stripLeft = (w - stripW) / 2;
            final botTop = boardRect.bottom + gap;

            final now = _now;
            final fallingPearls = _falls.where((f) => f.pearl).length;
            final fallingGarnets = _falls.length - fallingPearls;
            final aiTaken = (((captured['ai'] as num?)?.toInt() ?? 0) - fallingPearls).clamp(0, 14);
            final youTaken = (((captured['you'] as num?)?.toInt() ?? 0) - fallingGarnets).clamp(0, 14);
            if (_busy(now)) _kick();

            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: stripLeft,
                  width: stripW,
                  top: y0,
                  height: topH,
                  child: _Strip(
                    active: thinking,
                    activeColor: _rose,
                    child: Row(
                      children: [
                        _OpponentBadge(rank: rank, thinking: thinking),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(rank, style: Lux.display(19, color: Lux.ink)),
                              const SizedBox(height: 2),
                              thinking
                                  ? const _ThinkingText(key: ValueKey('think'))
                                  : Text('${counts['ai'] ?? 14} bilye',
                                      style: Lux.ui(12, color: Lux.muted, spacing: 0.8)),
                            ],
                          ),
                        ),
                        _Tally(label: 'DÜŞÜRDÜĞÜ', taken: aiTaken, target: target, pearls: true),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: stripLeft,
                  width: stripW,
                  top: botTop,
                  height: botH,
                  child: _Strip(
                    active: _yourTurn && !_animating && !thinking,
                    activeColor: Lux.gold,
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  !playing
                                      ? 'Oyun bitti'
                                      : _yourTurn
                                          ? 'Sıra sende'
                                          : 'Rakip oynuyor',
                                  style: Lux.ui(14, color: _yourTurn ? Lux.goldLight : Lux.muted, weight: FontWeight.w600)),
                              Text('${counts['you'] ?? 14} bilyen', style: Lux.ui(12, color: Lux.muted, spacing: 0.8)),
                            ],
                          ),
                        ),
                        _Tally(label: 'DÜŞÜRDÜĞÜN', taken: youTaken, target: target, pearls: false),
                        const SizedBox(width: 14),
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text('SESSİZ', style: Lux.ui(10, color: Lux.muted, spacing: 1.4)),
                            Text('$quiet/$quietLimit',
                                style: Lux.numeral(16, color: quiet >= quietLimit - 20 ? Lux.bordeauxLight : Lux.goldLight)),
                            const SizedBox(height: 3),
                            _QuietBar(quiet / quietLimit),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned.fromRect(
                  rect: boardRect,
                  child: RepaintBoundary(child: CustomPaint(painter: _TrayPainter(boardRect.size))),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(painter: _DynPainter(this, geo, now, aiTaken, youTaken)),
                  ),
                ),
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    dragStartBehavior: DragStartBehavior.down,
                    onTapUp: (d) => _tap(d.localPosition),
                    onPanStart: (d) => _panStart(d.localPosition),
                    onPanUpdate: (d) => _panUpdate(d.localPosition),
                    onPanEnd: (_) => _panEnd(),
                    onPanCancel: _panEnd,
                  ),
                ),
              ],
            );
          }),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              RimIconButton(Icons.undo_rounded,
                  tooltip: 'Geri al (yıldızı 1\'e düşürür)',
                  onPressed: st['can_undo'] == true && _canInput
                      ? () {
                          setState(() => _sel = []);
                          s.act({'undo': true});
                        }
                      : null),
              const SizedBox(width: 24),
              RimIconButton(_hintBusy ? Icons.hourglass_top_rounded : Icons.lightbulb_outline_rounded,
                  tooltip: 'İpucu: en iyi hamle (yıldızı 1\'e düşürür)', onPressed: _canInput ? _askHint : null),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Strip widgets

class _Strip extends StatelessWidget {
  final bool active;
  final Color activeColor;
  final Widget child;
  const _Strip({required this.active, required this.activeColor, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xCC0B2A21), Color(0xCC04140F)],
        ),
        border: Border.all(color: active ? activeColor.withValues(alpha: 0.75) : Lux.line, width: active ? 1.3 : 1),
        boxShadow: [
          BoxShadow(
              color: active ? activeColor.withValues(alpha: 0.22) : Colors.black.withValues(alpha: 0.35),
              blurRadius: active ? 18 : 12,
              offset: const Offset(0, 4)),
        ],
      ),
      child: child,
    );
  }
}

/// "DÜŞÜRDÜĞÜN 2/6" with six small sockets that fill as marbles fall.
class _Tally extends StatelessWidget {
  final String label;
  final int taken, target;
  final bool pearls;
  const _Tally({required this.label, required this.taken, required this.target, required this.pearls});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text('$label  ${math.min(taken, target)}/$target', style: Lux.ui(10, color: Lux.muted, spacing: 1.2)),
        const SizedBox(height: 5),
        SizedBox(
          width: target * 13.0,
          height: 11,
          child: CustomPaint(painter: _TallyPainter(taken, target, pearls)),
        ),
      ],
    );
  }
}

class _TallyPainter extends CustomPainter {
  final int taken, target;
  final bool pearls;
  _TallyPainter(this.taken, this.target, this.pearls);

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < target; i++) {
      final c = Offset(6.5 + i * 13.0, size.height / 2);
      if (i < taken) {
        _paintMarble(canvas, c, 5.2, pearls);
      } else {
        canvas.drawCircle(c, 4.6, Paint()..color = const Color(0xFF050302));
        canvas.drawCircle(
            c,
            4.6,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 0.8
              ..color = Lux.gold.withValues(alpha: 0.35));
      }
    }
  }

  @override
  bool shouldRepaint(_TallyPainter old) => old.taken != taken || old.target != target;
}

class _QuietBar extends StatelessWidget {
  final double v;
  const _QuietBar(this.v);

  @override
  Widget build(BuildContext context) {
    final c = v >= 0.8 ? Lux.bordeauxLight : Lux.gold;
    return SizedBox(
      width: 54,
      height: 4,
      child: DecoratedBox(
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(2), color: Lux.lineFaint),
        child: Align(
          alignment: Alignment.centerLeft,
          child: AnimatedFractionallySizedBox(
            duration: const Duration(milliseconds: 300),
            widthFactor: v.clamp(0.0, 1.0),
            child: DecoratedBox(decoration: BoxDecoration(borderRadius: BorderRadius.circular(2), color: c)),
          ),
        ),
      ),
    );
  }
}

/// Garnet medallion with the rank's initial; breathes while the AI thinks.
class _OpponentBadge extends StatefulWidget {
  final String rank;
  final bool thinking;
  const _OpponentBadge({required this.rank, required this.thinking});

  @override
  State<_OpponentBadge> createState() => _OpponentBadgeState();
}

class _OpponentBadgeState extends State<_OpponentBadge> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void initState() {
    super.initState();
    if (widget.thinking) _c.repeat();
  }

  @override
  void didUpdateWidget(_OpponentBadge old) {
    super.didUpdateWidget(old);
    if (widget.thinking && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.thinking && _c.isAnimating) {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glyph = widget.rank.isEmpty ? '⬢' : widget.rank.substring(0, 1);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final b = widget.thinking ? 0.5 - 0.5 * math.cos(_c.value * 2 * math.pi) : 0.0;
        return DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: _rose.withValues(alpha: 0.55 * b), blurRadius: 6 + 14 * b, spreadRadius: 1 + 2 * b)],
          ),
          child: child,
        );
      },
      child: Monogram(glyph, size: 44, tint: _garnet),
    );
  }
}

class _ThinkingText extends StatefulWidget {
  const _ThinkingText({super.key});

  @override
  State<_ThinkingText> createState() => _ThinkingTextState();
}

class _ThinkingTextState extends State<_ThinkingText> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('düşünüyor', style: Lux.ui(12, color: _rose, spacing: 0.8)),
          for (var i = 0; i < 3; i++)
            Transform.translate(
              offset: Offset(0, -3 * math.max(0, math.sin((_c.value - i * 0.18) * 2 * math.pi))),
              child: Text('.', style: Lux.ui(14, color: _rose, weight: FontWeight.w800)),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Painting

/// The tray: gold bezel, obsidian gutter, smoked-ebony plate with wood grain and carved dimples.
class _TrayPainter extends CustomPainter {
  final Size size;
  _TrayPainter(this.size);

  @override
  void paint(Canvas canvas, Size sz) {
    final rect = Offset.zero & sz;
    final s = sz.width / _unitsW;
    final c = sz.center(Offset.zero);
    final rRim = _circ(_mRim) * s, rGut = _circ(_mGutter) * s, rField = _circ(_mField) * s;

    // Drop shadow.
    canvas.drawPath(
        _hexPath(c + Offset(0, s * 0.25), rRim, s * 0.55),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.65)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.5));

    // Gold bezel with a bright bevel on top and a darker one below.
    final rim = _hexPath(c, rRim, s * 0.55);
    canvas.drawPath(rim, Paint()..shader = Lux.foil.createShader(rect));
    canvas.drawPath(
        rim,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.05
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.white.withValues(alpha: 0.55), Colors.white.withValues(alpha: 0.0), Colors.black.withValues(alpha: 0.45)],
          ).createShader(rect));
    canvas.drawPath(
        _hexPath(c, rRim - s * _rimW * 0.55 / _sqrt3_2, s * 0.45),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(0.8, s * 0.025)
          ..color = const Color(0xFF5E4214).withValues(alpha: 0.8));

    // Obsidian gutter, carved: dark, with an inner shadow along its outer lip.
    final gut = _hexPath(c, rGut, s * 0.42);
    canvas.drawPath(
        gut,
        Paint()
          ..shader = const RadialGradient(
            center: Alignment(-0.2, -0.35),
            radius: 0.9,
            colors: [Color(0xFF1B1714), Color(0xFF0A0807), Color(0xFF020101)],
            stops: [0, 0.6, 1],
          ).createShader(rect));
    canvas.save();
    canvas.clipPath(gut);
    canvas.drawPath(
        gut,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.35
          ..color = Colors.black.withValues(alpha: 0.85)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.18));
    // Glassy reflection running round the groove.
    canvas.drawPath(
        _hexPath(c, _rGutterLine * s + s * 0.12, s * 0.4),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.07
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.white.withValues(alpha: 0.10), Colors.white.withValues(alpha: 0.02), Colors.white.withValues(alpha: 0.07)],
          ).createShader(rect)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.05));
    canvas.restore();

    // The raised plate casts a soft shadow into the gutter.
    final field = _hexPath(c, rField, s * 0.38);
    canvas.drawPath(
        field.shift(Offset(0, s * 0.08)),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.9)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.16));
    canvas.drawPath(
        field,
        Paint()
          ..shader = const RadialGradient(
            center: Alignment(-0.3, -0.45),
            radius: 1.05,
            colors: [Color(0xFF3A2416), Color(0xFF22140B), Color(0xFF110905)],
            stops: [0, 0.55, 1],
          ).createShader(rect));
    canvas.save();
    canvas.clipPath(field);
    // Wood grain: long, gently waving fibres.
    final grain = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.6, s * 0.022);
    final rnd = math.Random(17);
    for (var k = 0; k < 64; k++) {
      final y0 = c.dy - rField + (2 * rField) * k / 64 + rnd.nextDouble() * s * 0.2;
      final amp = s * (0.08 + 0.18 * rnd.nextDouble());
      final ph = rnd.nextDouble() * math.pi * 2;
      final wl = s * (3.5 + 3 * rnd.nextDouble());
      final path = Path()..moveTo(c.dx - rField, y0);
      for (var x = -rField; x <= rField; x += s * 0.3) {
        path.lineTo(c.dx + x, y0 + amp * math.sin(ph + x / wl * 2 * math.pi) + amp * 0.4 * math.sin(ph * 1.7 + x / (wl * 0.37)));
      }
      grain.color = (k.isEven ? const Color(0xFF000000) : const Color(0xFFFFD8A8)).withValues(alpha: k.isEven ? 0.16 : 0.035);
      canvas.drawPath(path, grain);
    }
    // Lacquer sheen.
    canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.white.withValues(alpha: 0.09), Colors.white.withValues(alpha: 0.0), Colors.white.withValues(alpha: 0.03)],
            stops: const [0, 0.5, 1],
          ).createShader(rect));
    canvas.restore();
    canvas.drawPath(
        field,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.0, s * 0.035)
          ..shader = Lux.foil.createShader(rect));
    canvas.drawPath(
        _hexPath(c, rField - s * 0.12, s * 0.32),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.7
          ..color = Lux.gold.withValues(alpha: 0.18));

    // Carved dimples: shadowed upper-left wall, lit lower-right lip.
    final dr = s * 0.38;
    for (var i = 0; i < _cells.length; i++) {
      final p = c + _u(i) * s;
      final r = Rect.fromCircle(center: p, radius: dr);
      canvas.drawCircle(
          p,
          dr,
          Paint()
            ..shader = const RadialGradient(
              center: Alignment(0.25, 0.3),
              radius: 1.0,
              colors: [Color(0xFF1C110A), Color(0xFF0C0704), Color(0xFF040201)],
              stops: [0, 0.6, 1],
            ).createShader(r));
      canvas.drawCircle(
          p,
          dr,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1.0, s * 0.045)
            ..shader = LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Colors.black.withValues(alpha: 0.75), const Color(0x00000000), const Color(0xFFFFD9A0).withValues(alpha: 0.28)],
              stops: const [0, 0.5, 1],
            ).createShader(r));
      if (_ring(i) == 0) {
        canvas.drawCircle(
            p,
            dr + s * 0.07,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 0.8
              ..color = Lux.gold.withValues(alpha: 0.4));
      }
    }
    // Empty gutter sockets for the six trophies of each side.
    for (final pearl in [true, false]) {
      for (var k = 0; k < 6; k++) {
        final p = c + _Gutter.slot(pearl, k) * s;
        canvas.drawCircle(
            p,
            s * (_gutterMarbleR + 0.04),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 0.8
              ..color = Lux.gold.withValues(alpha: 0.16));
      }
    }
  }

  @override
  bool shouldRepaint(_TrayPainter old) => old.size != size;
}

/// Marbles, selection, chevrons, previews and every moving thing.
class _DynPainter extends CustomPainter {
  final _PushBoardState st;
  final _Geo geo;
  final double now;
  final int aiTaken, youTaken;
  _DynPainter(this.st, this.geo, this.now, this.aiTaken, this.youTaken);

  double get s => geo.s;

  @override
  void paint(Canvas canvas, Size size) {
    final state = st.s.state;
    final board = st._board();
    final pulse = 0.5 + 0.5 * math.sin(now * 5.2);
    final animating = st._animating;

    // Trophies resting in the gutter.
    for (var k = 0; k < math.min(aiTaken, 6); k++) {
      _marble(canvas, geo.px(_Gutter.slot(true, k)), true, r: _gutterMarbleR * s, shadow: 0.6);
    }
    for (var k = 0; k < math.min(youTaken, 6); k++) {
      _marble(canvas, geo.px(_Gutter.slot(false, k)), false, r: _gutterMarbleR * s, shadow: 0.6);
    }

    // Last move: a faint wake from the vacated cells.
    final lm = state['last_move'];
    if (!animating && lm is Map) {
      final mv = _Mv.parse(lm);
      final you = lm['who'] == 'you';
      final col = (you ? _pearlGlow : _rose).withValues(alpha: 0.32);
      final destSet = {for (final c in mv.line) _nb(c, mv.dir)};
      for (final c in mv.line) {
        final to = _nb(c, mv.dir);
        if (to < 0) continue;
        canvas.drawLine(
            geo.px(_u(c)),
            geo.px(_u(to)),
            Paint()
              ..strokeWidth = math.max(1.5, s * 0.06)
              ..strokeCap = StrokeCap.round
              ..color = col);
        if (!destSet.contains(c)) {
          canvas.drawCircle(
              geo.px(_u(c)),
              s * 0.3,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.3
                ..color = col);
        }
      }
    }

    // Moving pieces hide their destination cells; a dragged group draws offset.
    final hidden = <int>{for (final sp in st._sprites) sp.toIdx};
    final dragging = st._drag == _Drag.moving;
    final off = st._dragOffset();
    final dragMv = dragging && st._dragDir != null ? st._legal(st._sel, st._dragDir!) : null;
    final pushedPreview = <int>{...?dragMv?.pushed};
    final retK = ((now - st._returnAt) / 0.28).clamp(0.0, 1.0);
    final retOff = retK < 1 ? st._returnOff * (1 - Curves.easeOutBack.transform(retK)) : Offset.zero;
    final shakeK = now - st._shakeAt;
    final shake = shakeK < 0.45 ? Offset(math.sin(shakeK * 46) * 0.1 * math.exp(-shakeK * 7), 0) : Offset.zero;
    final selSet = st._sel.toSet();

    // Selection glow under the marbles.
    if (st._sel.isNotEmpty && !animating) {
      for (final c in st._sel) {
        canvas.drawCircle(
            geo.px(_u(c) + (dragging ? off : retOff) + shake),
            s * 0.62,
            Paint()
              ..color = Lux.gold.withValues(alpha: 0.28 + 0.14 * pulse)
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.22));
      }
    }

    // Static marbles.
    final endT = st._endAt >= 0 ? now - st._endAt : -1.0;
    final won = state['status'] == 'won';
    for (var i = 0; i < _cells.length; i++) {
      final v = board[i];
      if (v == 0 || hidden.contains(i)) continue;
      var p = _u(i);
      var lift = 0.0;
      var glow = 0.0;
      if (selSet.contains(i) && !animating) {
        p += (dragging ? off : retOff) + shake;
        lift = dragging ? 0.9 : 0.35;
        glow = 0.35 + 0.25 * pulse;
      } else if (pushedPreview.contains(i)) {
        p += off;
      }
      var sx = 1.0, sy = 1.0;
      for (final l in st._landings) {
        if (l.idx != i) continue;
        final k = now - l.at;
        final q = 0.14 * l.strength * math.exp(-k * 10) * math.cos(k * 30);
        sx = 1 + q;
        sy = 1 - q;
      }
      if (endT >= 0 && endT < 1.8 && ((won && v == 1) || (!won && state['status'] == 'lost' && v == 2))) {
        final d = _u(i).distance / 4.2;
        final k = endT - d * 0.6;
        if (k > 0 && k < 0.7) glow = math.max(glow, math.sin(math.pi * k / 0.7));
      }
      _piece(canvas, geo.px(p), v == 1, lift: lift, glow: glow, sx: sx, sy: sy);
    }

    // Sliding marbles.
    for (final sp in st._sprites) {
      if (now < sp.start) {
        _piece(canvas, geo.px(sp.from), sp.pearl);
        continue;
      }
      final u = sp.u(now);
      final lift = sp.kind == 1 ? 0.0 : math.sin(math.pi * u) * 0.35;
      _piece(canvas, geo.px(sp.at(now)), sp.pearl, lift: lift, glow: sp.kind == 0 ? 0.25 * math.sin(math.pi * u) : 0);
    }

    // Impacts: a bright ring and sparks where the lines meet.
    for (final im in st._impacts) {
      final t = (now - im.t) / 0.5;
      if (t < 0 || t > 1) continue;
      final e = Curves.easeOutCubic.transform(t);
      final c = geo.px(im.at);
      final col = im.onPearl ? Lux.goldLight : _rose;
      canvas.drawCircle(
          c,
          s * (0.12 + 0.55 * e),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(0.5, 3.2 * (1 - t))
            ..color = col.withValues(alpha: 0.9 * (1 - t)));
      canvas.drawCircle(
          c,
          s * 0.3 * (1 - t),
          Paint()
            ..color = Colors.white.withValues(alpha: 0.55 * (1 - t))
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.15));
      final spark = Paint()
        ..strokeWidth = 1.4
        ..strokeCap = StrokeCap.round
        ..color = col.withValues(alpha: 1 - t);
      for (var k = 0; k < 8; k++) {
        final a = k * math.pi / 4 + 0.3;
        final d = Offset(math.cos(a), math.sin(a));
        canvas.drawLine(c + d * s * (0.2 + 0.5 * e), c + d * s * (0.3 + 0.75 * e), spark);
      }
    }

    // Marbles falling into the gutter and rolling to their slot.
    for (final f in st._falls) {
      if (now < f.start) {
        _piece(canvas, geo.px(f.from), f.pearl);
        continue;
      }
      if (now < f.t1) {
        // Tipping over the edge: speeds up, sinks and shrinks into the groove.
        final k = ((now - f.start) / (f.t1 - f.start)).clamp(0.0, 1.0);
        final e = Curves.easeIn.transform(k);
        final p = Offset.lerp(f.from, f.edge, e)!;
        final r = s * (_marbleR + (_gutterMarbleR - _marbleR) * e);
        _marble(canvas, geo.px(p), f.pearl, r: r, shadow: 1 - 0.4 * e);
      } else {
        final k = ((now - f.t1) / (f.t2 - f.t1)).clamp(0.0, 1.0);
        // A small bounce at the clack, then a roll that slows into the slot.
        final bounce = math.exp(-k * 9) * math.sin(k * 26) * 0.06;
        final d = Curves.easeOutCubic.transform(k) * f.roll.length;
        final p = f.roll.at(d);
        _marble(canvas, geo.px(p) + Offset(0, -bounce * s), f.pearl, r: s * _gutterMarbleR, shadow: 0.6, spin: d);
        if (now - f.t1 < 0.35) {
          final t = (now - f.t1) / 0.35;
          canvas.drawCircle(
              geo.px(f.edge),
              s * (0.2 + 0.5 * t),
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2 * (1 - t)
                ..color = Lux.goldLight.withValues(alpha: 0.7 * (1 - t)));
        }
      }
    }

    // Direction chevrons around the selection.
    if (st._sel.isNotEmpty && !animating && st._yourTurn && st._drag != _Drag.selecting) {
      final hint = state['hint'];
      final hintDir = hint is Map && _sameCells(hint['line'] as List, st._sel) ? (hint['dir'] as num).toInt() : -1;
      for (var d = 0; d < 6; d++) {
        final legal = st._legal(st._sel, d) != null;
        final active = dragging && st._dragDir == d && st._dragReady;
        _chevron(canvas, geo.px(_arrowPos(st._sel, d) + (dragging ? off * 0.5 : Offset.zero)), d, legal,
            active: active, hinted: d == hintDir, pulse: pulse);
      }
    } else if (st._drag == _Drag.selecting && st._sel.isNotEmpty) {
      // While sweeping: a soft thread through the chosen marbles.
      final pts = [for (final c in st._sel) geo.px(_u(c))];
      if (pts.length > 1) {
        final path = Path()..moveTo(pts.first.dx, pts.first.dy);
        for (final p in pts.skip(1)) {
          path.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(
            path,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = s * 0.12
              ..strokeCap = StrokeCap.round
              ..color = Lux.goldLight.withValues(alpha: 0.55));
      }
    }

    // Hint: rings on the suggested line.
    final hint = state['hint'];
    if (hint is Map && !animating) {
      for (final c in hint['line'] as List) {
        canvas.drawCircle(
            geo.px(_u(_cellOf(c))),
            s * (0.56 + 0.05 * pulse),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.4
              ..color = Lux.gold.withValues(alpha: 0.5 + 0.45 * pulse));
      }
    }
  }

  bool _sameCells(List a, List<int> b) {
    final x = [for (final c in a) _cellOf(c)]..sort();
    final y = [...b]..sort();
    return x.length == y.length && List.generate(x.length, (i) => x[i] == y[i]).every((e) => e);
  }

  Offset _arrowPos(List<int> cs, int d) => st._arrowPos(cs, d);

  void _chevron(Canvas canvas, Offset p, int d, bool legal,
      {bool active = false, bool hinted = false, double pulse = 0}) {
    final u = _dirU(d);
    final n = Offset(-u.dy, u.dx);
    final sz = s * (active ? 0.27 : 0.21) * (hinted ? 1 + 0.12 * pulse : 1);
    final tip = p + u * sz * 0.8;
    final a = p - u * sz * 0.5 + n * sz;
    final b = p - u * sz * 0.5 - n * sz;
    final path = Path()
      ..moveTo(a.dx, a.dy)
      ..lineTo(tip.dx, tip.dy)
      ..lineTo(b.dx, b.dy);
    if (legal) {
      // Dark halo keeps a live chevron readable over marbles and wood alike.
      canvas.drawCircle(p, sz * 1.15, Paint()..color = Colors.black.withValues(alpha: 0.5));
      canvas.drawCircle(
          p,
          sz * (1.5 + (active ? 0.4 : 0.15 * pulse)),
          Paint()
            ..color = Lux.gold.withValues(alpha: active ? 0.55 : 0.28)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, sz * 0.8));
    } else if (active) {
      canvas.drawCircle(
          p,
          sz * 1.7,
          Paint()
            ..color = Lux.bordeaux.withValues(alpha: 0.6)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, sz * 0.8));
    }
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(2.0, sz * (legal ? 0.42 : 0.3))
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = legal ? (active ? const Color(0xFFFFF4DA) : Lux.goldLight) : Lux.bordeauxLight.withValues(alpha: active ? 0.95 : 0.5));
  }

  void _piece(Canvas canvas, Offset p, bool pearl, {double lift = 0, double glow = 0, double sx = 1, double sy = 1}) {
    final r = s * _marbleR;
    canvas.drawOval(
      Rect.fromCenter(center: p + Offset(r * 0.12, r * (0.2 + 0.35 * lift)), width: r * 2 * (1 + 0.1 * lift), height: r * 1.75),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.6 - 0.15 * lift)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2 + 5 * lift),
    );
    final c = p - Offset(0, r * 0.2 * lift);
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.scale(sx * (1 + 0.06 * lift), sy * (1 + 0.06 * lift));
    if (glow > 0) {
      canvas.drawCircle(
          Offset.zero,
          r * 1.45,
          Paint()
            ..color = (pearl ? Lux.goldLight : _rose).withValues(alpha: 0.45 * glow)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.7));
    }
    _paintMarble(canvas, Offset.zero, r, pearl);
    canvas.restore();
  }

  void _marble(Canvas canvas, Offset p, bool pearl, {required double r, double shadow = 1, double spin = 0}) {
    canvas.drawCircle(
        p + Offset(r * 0.1, r * 0.22),
        r,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.55 * shadow)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.2));
    _paintMarble(canvas, p, r, pearl, spin: spin);
  }

  @override
  bool shouldRepaint(_DynPainter old) => true;
}

/// Glossy pearl (yours) or garnet glass (the AI's), lit from the upper left.
void _paintMarble(Canvas canvas, Offset c, double r, bool pearl, {double spin = 0}) {
  final rect = Rect.fromCircle(center: c, radius: r);
  final colors = pearl
      ? const [Color(0xFFFFFFFF), Color(0xFFF3ECDD), Color(0xFFCBBFA4), Color(0xFF5A5040)]
      : const [Color(0xFFFFA9BB), Color(0xFFBF2446), Color(0xFF5E0A1F), Color(0xFF1C0208)];
  canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.38, -0.45),
          radius: 1.05,
          colors: colors,
          stops: pearl ? const [0, 0.22, 0.66, 1] : const [0, 0.3, 0.74, 1],
        ).createShader(rect));
  if (pearl) {
    // Nacre: a faint iridescent ring that turns as the marble rolls.
    canvas.drawCircle(
        c,
        r * 0.7,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.36
          ..shader = SweepGradient(
            transform: GradientRotation(spin * 2.2),
            colors: const [Color(0x38FFB6D9), Color(0x38A8E6FF), Color(0x38C8FFD9), Color(0x38FFE6A8), Color(0x38FFB6D9)],
          ).createShader(rect));
  } else {
    // Glass depth: light gathers on the far side (caustic), the core stays dark.
    canvas.drawCircle(
        c + Offset(r * 0.28, r * 0.34),
        r * 0.42,
        Paint()
          ..color = const Color(0xFFFF5C7E).withValues(alpha: 0.32)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.25));
  }
  canvas.drawCircle(
      c,
      r - 0.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = Lux.goldLight.withValues(alpha: pearl ? 0.3 : 0.4));
  canvas.drawOval(
      Rect.fromCenter(center: c + Offset(-r * 0.3, -r * 0.42), width: r * 0.64, height: r * 0.36),
      Paint()
        ..color = Colors.white.withValues(alpha: pearl ? 0.72 : 0.6)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.08 + 0.4));
  canvas.drawCircle(c + Offset(-r * 0.36, -r * 0.47), r * 0.08, Paint()..color = Colors.white.withValues(alpha: 0.92));
  canvas.drawArc(
      Rect.fromCircle(center: c, radius: r * 0.8),
      math.pi * 0.2,
      math.pi * 0.6,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.12
        ..color = (pearl ? const Color(0xFFFFF4DC) : const Color(0xFFFF6F8E)).withValues(alpha: 0.24)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.08 + 0.5));
}
