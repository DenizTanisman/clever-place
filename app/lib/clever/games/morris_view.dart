import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// Cırtcak (Nine Men's Morris) against the core's AI.
///
/// The view keeps its own model of *which* stone is where (stable ids for the 18 stones, in hand,
/// on a point or in a captured tray) and animates each core event (`last_move`, numbered by `ply`)
/// onto it: placements arc in from the tray, AI moves lift → glide → land with a squash, a closed
/// mill flashes a gold beam across its three points, a taken stone pops into shards and flies to
/// the captor's tray. Anything it can't explain as the next event (undo, restart) snaps.
///
/// Input: drag a stone from your tray onto a point (placing) or drag a stone along a line
/// (moving); the hovered point glows gold when legal and bordeaux when not, and an illegal drop
/// flies back. Tapping works too: tap a point to place, tap a stone then a target to move, tap an
/// opponent stone to take it after a mill.
///
/// The AI is asked to move (`session.actAsync({'ai': true})`, off the UI isolate) after your
/// move has landed plus a human-feeling pause of 450–1100 ms. The Ticker runs only while
/// something moves or pulses.
Widget morrisView(BuildContext context, GameSession s) => _MorrisBoard(key: ObjectKey(s), session: s);

/// 7×7 grid coordinates of the 24 points (same numbering as the core).
const List<(int, int)> _xy = [
  (0, 0), (3, 0), (6, 0), (1, 1), (3, 1), (5, 1), (2, 2), (3, 2), (4, 2), (0, 3), (1, 3), (2, 3),
  (4, 3), (5, 3), (6, 3), (2, 4), (3, 4), (4, 4), (1, 5), (3, 5), (5, 5), (0, 6), (3, 6), (6, 6),
];

const _roman = ['I', 'II', 'III', 'IV', 'V', 'VI'];

const _garnet = Color(0xFF8E1F3C);
const _garnetLight = Color(0xFFE0708C);
const _ivory = Color(0xFFF4ECDD);

/// Board geometry for one layout size. Side 0 = you (bottom tray), side 1 = AI (top tray).
class _Geo {
  final Size size;
  final Rect board, topTray, botTray;
  final double m, cell, r, tr;
  _Geo(this.size, this.board, this.topTray, this.botTray, this.m, this.cell, this.r, this.tr);

  factory _Geo.fit(Size s) {
    const pad = 8.0, gap = 12.0;
    final cell = math.min((s.width - 2 * pad) / 7.2, (s.height - 2 * pad - 2 * gap) / 9.2);
    final side = cell * 7.2;
    final trayH = cell * 1.0;
    final total = side + 2 * (trayH + gap);
    final left = (s.width - side) / 2;
    final top = (s.height - total) / 2;
    final board = Rect.fromLTWH(left, top + trayH + gap, side, side);
    return _Geo(
      s,
      board,
      Rect.fromLTWH(left, top, side, trayH),
      Rect.fromLTWH(left, board.bottom + gap, side, trayH),
      cell * 0.6,
      cell,
      cell * 0.39,
      cell * 0.3,
    );
  }

  Offset pt(int p) => board.topLeft + Offset(m + _xy[p].$1 * cell, m + _xy[p].$2 * cell);
  Rect tray(int side) => side == 0 ? botTray : topTray;
  Offset hand(int side, int i) {
    final t = tray(side);
    return Offset(t.left + 12 + tr + i * tr * 1.5, t.center.dy);
  }

  Offset captured(int side, int i) {
    final t = tray(side);
    return Offset(t.right - 12 - tr - i * tr * 1.05, t.center.dy);
  }

  int? hit(Offset p, [double k = 0.62]) {
    int? best;
    var bd = cell * k;
    for (var i = 0; i < 24; i++) {
      final d = (pt(i) - p).distance;
      if (d < bd) {
        bd = d;
        best = i;
      }
    }
    return best;
  }
}

class _Slot {
  final Offset c;
  final double r;
  const _Slot(this.c, this.r);
}

/// A stone's journey: cubic Bézier p0→p3 with a height profile (lift) and a radius change.
class _Flight {
  final Offset p0, p1, p2, p3;
  final double r0, r1, start, dur, landing, lift;
  final Curve curve;
  final bool decay; // height falls from `lift` to 0 (a drop) instead of rising and falling (an arc)
  _Flight(this.p0, this.p1, this.p2, this.p3, this.r0, this.r1, this.start, this.dur, this.curve,
      {this.landing = 1, this.lift = 0.6, this.decay = false});

  double get end => start + dur;
  double t(double now) => ((now - start) / dur).clamp(0.0, 1.0);
  Offset at(double now) {
    final e = curve.transform(t(now));
    final u = 1 - e;
    return p0 * (u * u * u) + p1 * (3 * u * u * e) + p2 * (3 * u * e * e) + p3 * (e * e * e);
  }

  double radius(double now) => r0 + (r1 - r0) * Curves.easeInOut.transform(t(now));
  double height(double now) {
    final k = t(now);
    if (now < start) return 0;
    return decay ? lift * (1 - k) : lift * math.sin(math.pi * k);
  }
}

class _Ev {
  final int who;
  final String kind;
  final int? moved, captured;
  final List<List<int>> mills;
  final bool dropped;
  _Ev(this.who, this.kind, this.moved, this.captured, this.mills, this.dropped);
}

class _MillFx {
  final List<int> pts;
  final double at;
  final int owner;
  _MillFx(this.pts, this.at, this.owner);
}

class _Burst {
  final Offset c;
  final double r, at;
  final int owner;
  _Burst(this.c, this.r, this.at, this.owner);
}

class _Dust {
  final Offset c;
  final double r, at, strength;
  _Dust(this.c, this.r, this.at, this.strength);
}

class _MorrisBoard extends StatefulWidget {
  final GameSession session;
  const _MorrisBoard({super.key, required this.session});

  @override
  State<_MorrisBoard> createState() => _MorrisBoardState();
}

class _MorrisBoardState extends State<_MorrisBoard> with SingleTickerProviderStateMixin {
  GameSession get s => widget.session;

  late final Ticker _ticker = createTicker((_) => _onTick());
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;
  final _rand = math.Random(7);

  // Stone identity model.
  final List<int?> _at = List<int?>.filled(24, null);
  final List<List<int>> _hand = [[], []];
  final List<List<int>> _capt = [[], []]; // captured BY side
  final Map<int, int> _owner = {}; // id → 0 you / 1 ai
  int _nextId = 0;
  int _seenPly = 0;
  int _seenVersion = -1;
  final List<_Ev> _events = [];

  // Motion.
  final Map<int, _Slot> _targets = {};
  final Map<int, _Flight> _flights = {};
  final Map<int, double> _landings = {};
  final Map<int, double> _pops = {};
  final Map<int, String> _plans = {};
  final List<_MillFx> _millFx = [];
  final List<_Burst> _bursts = [];
  final List<_Dust> _dust = [];
  final List<(double, int)> _buzz = []; // (time, 0 light / 1 mill / 2 capture / 3 end)
  Size? _layout;
  _Geo? _geo;

  // Input.
  int? _selected; // point
  int? _dragId, _dragFrom, _hover;
  Offset _dragPos = Offset.zero, _grab = Offset.zero;
  int? _dropId;
  int? _shakeId;
  double _shakeAt = -10;

  // AI turn + last AI move ghost.
  bool _aiBusy = false;
  double _thinkFrom = -1;
  (int?, int?, int?)? _ghost; // from, to, removed
  double _endAt = -1;
  String _lastStatus = 'playing';

  @override
  void initState() {
    super.initState();
    _rebuild(s.state);
    _seenVersion = _int(s.state['version']);
    _lastStatus = s.status;
    if (s.finished) _endAt = 0;
    s.addListener(_onSession);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeScheduleAi());
  }

  @override
  void dispose() {
    s.removeListener(_onSession);
    _ticker.dispose();
    _boardPic?.dispose();
    super.dispose();
  }

  static int _int(Object? v, [int d = 0]) => (v as num?)?.toInt() ?? d;
  static int? _intOrNull(Object? v) => (v as num?)?.toInt();

  // ---------------------------------------------------------------------------------------------
  // Model

  void _rebuild(Map<String, dynamic> st) {
    _at.fillRange(0, 24, null);
    for (final l in [..._hand, ..._capt]) {
      l.clear();
    }
    _owner.clear();
    _targets.clear();
    _flights.clear();
    _landings.clear();
    _pops.clear();
    _plans.clear();
    _millFx.clear();
    _bursts.clear();
    _events.clear();
    _selected = null;
    _dragId = null;
    int mk(int side) {
      final id = _nextId++;
      _owner[id] = side;
      return id;
    }

    final board = st['board'] as List? ?? const [];
    for (var p = 0; p < board.length && p < 24; p++) {
      final v = _int(board[p]);
      if (v > 0) _at[p] = mk(v - 1);
    }
    final hand = st['hand'] as List? ?? const [0, 0];
    final capt = st['captured'] as List? ?? const [0, 0];
    for (var side = 0; side < 2; side++) {
      for (var i = 0; i < _int(hand[side]); i++) {
        _hand[side].add(mk(side));
      }
      // Side `side` captured stones of the other side.
      for (var i = 0; i < _int(capt[side]); i++) {
        _capt[side].add(mk(1 - side));
      }
    }
    final lm = st['last_move'];
    _seenPly = lm is Map ? _int(lm['ply']) : 0;
    _ghost = null;
  }

  bool _consistent(Map<String, dynamic> st) {
    final board = st['board'] as List;
    for (var p = 0; p < 24; p++) {
      final id = _at[p];
      final v = id == null ? 0 : _owner[id]! + 1;
      if (v != _int(board[p])) return false;
    }
    final hand = st['hand'] as List, capt = st['captured'] as List;
    for (var side = 0; side < 2; side++) {
      if (_hand[side].length != _int(hand[side]) || _capt[side].length != _int(capt[side])) return false;
    }
    return true;
  }

  bool _applyEvent(Map lm, Map<String, dynamic> st) {
    final who = lm['who'] == 'you' ? 0 : 1;
    final kind = lm['kind'] as String? ?? '';
    final from = _intOrNull(lm['from']), to = _intOrNull(lm['to']), removed = _intOrNull(lm['removed']);
    int? moved;
    if (kind == 'place') {
      if (to == null || _hand[who].isEmpty || _at[to] != null) return false;
      moved = _hand[who].removeLast();
      _at[to] = moved;
    } else if (kind == 'move') {
      if (from == null || to == null || _at[from] == null || _at[to] != null) return false;
      moved = _at[from];
      _at[from] = null;
      _at[to] = moved;
    }
    int? captured;
    if (removed != null) {
      captured = _at[removed];
      if (captured == null) return false;
      _at[removed] = null;
      _capt[who].add(captured);
    }
    if (!_consistent(st)) return false;
    final mills = [
      for (final m in (lm['mills'] as List? ?? const [])) [for (final p in m as List) _int(p)]
    ];
    _events.add(_Ev(who, kind, moved, captured, mills, moved != null && moved == _dropId));
    if (who == 1) {
      _ghost = (from, to, removed);
    } else if (kind != 'remove') {
      _ghost = null;
    }
    return true;
  }

  void _onSession() {
    final st = s.state;
    final ver = _int(st['version'], -1);
    if (ver == _seenVersion) return;
    _seenVersion = ver;
    final lm = st['last_move'];
    final ply = lm is Map ? _int(lm['ply']) : 0;
    if (lm is Map && ply == _seenPly + 1) {
      if (_applyEvent(lm, st)) {
        _seenPly = ply;
      } else {
        _rebuild(st);
      }
      _selected = null;
    } else if (ply != _seenPly || !_consistent(st)) {
      _rebuild(st);
    }
    if (s.status != _lastStatus) {
      _lastStatus = s.status;
      _endAt = s.finished ? -2 : -1; // -2: set after this frame's flights are known
    }
    if (mounted) setState(() {});
    _kick();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_endAt == -2) {
        _endAt = _animEnd() + 0.1;
        _buzz.add((_endAt, 3));
      }
      _maybeScheduleAi();
    });
  }

  double _animEnd() {
    var end = _now;
    for (final f in _flights.values) {
      end = math.max(end, f.end);
    }
    for (final m in _millFx) {
      end = math.max(end, m.at + 0.55);
    }
    for (final b in _bursts) {
      end = math.max(end, b.at + 0.3);
    }
    return end;
  }

  void _maybeScheduleAi() {
    if (!mounted || _aiBusy || s.finished || s.state['ai_pending'] != true) return;
    _aiBusy = true;
    final now = _now;
    final wait = math.max(0.0, _animEnd() - now) + 0.1;
    final n = _int(s.state['ai_moves'], 12);
    final pause = (0.45 + math.min(0.42, n * 0.011) + _rand.nextDouble() * 0.25).clamp(0.45, 1.1);
    _thinkFrom = now + wait;
    final session = s;
    _kick();
    Future.delayed(Duration(milliseconds: ((wait + pause) * 1000).round()), () async {
      if (!mounted || !identical(session, s)) return;
      if (s.state['ai_pending'] != true) {
        setState(() => _aiBusy = false);
        return;
      }
      final ok = await s.actAsync({'ai': true});
      if (!mounted) return;
      setState(() => _aiBusy = false);
      if (ok) WidgetsBinding.instance.addPostFrameCallback((_) => _maybeScheduleAi());
    });
  }

  // ---------------------------------------------------------------------------------------------
  // Motion

  void _kick() {
    if (!_ticker.isActive) _ticker.start();
  }

  bool get _thinking => _aiBusy && _now >= _thinkFrom;

  bool _busy(double now) {
    final st = s.state;
    return _flights.isNotEmpty ||
        _landings.values.any((t) => now - t < 0.6) ||
        _millFx.isNotEmpty ||
        _bursts.isNotEmpty ||
        _dust.isNotEmpty ||
        _buzz.isNotEmpty ||
        _aiBusy ||
        _dragId != null ||
        _selected != null ||
        now - _shakeAt < 0.5 ||
        st['hint'] is Map ||
        (st['pending_remove'] == true && !s.finished) ||
        (_endAt >= 0 && now - _endAt < 3.0) ||
        _endAt == -2;
  }

  void _onTick() {
    final now = _now;
    final done = [for (final e in _flights.entries) if (now >= e.value.end) e.key];
    for (final id in done) {
      final f = _flights.remove(id)!;
      if (f.landing > 0) {
        _landings[id] = f.end;
        _dust.add(_Dust(f.p3, f.r1, f.end, f.landing));
        HapticFeedback.lightImpact();
      }
    }
    _buzz.sort((a, b) => a.$1.compareTo(b.$1));
    while (_buzz.isNotEmpty && _buzz.first.$1 <= now) {
      final k = _buzz.removeAt(0).$2;
      if (k == 1) HapticFeedback.mediumImpact();
      if (k == 2) HapticFeedback.heavyImpact();
      if (k == 3) {
        if (s.status == 'won') {
          HapticFeedback.heavyImpact();
          Future.delayed(const Duration(milliseconds: 140), HapticFeedback.heavyImpact);
        } else {
          HapticFeedback.mediumImpact();
        }
      }
    }
    _landings.removeWhere((_, t) => now - t > 0.7);
    _pops.removeWhere((_, t) => now - t > 0.6);
    _millFx.removeWhere((m) => now - m.at > 1.0);
    _bursts.removeWhere((b) => now - b.at > 0.7);
    _dust.removeWhere((d) => now - d.at > 0.5);
    if (!_busy(now)) _ticker.stop();
    if (mounted) setState(() {});
  }

  _Slot _slotOf(_Geo g, int id, Map<int, (int, int, int)> where) {
    final w = where[id]!;
    return switch (w.$1) {
      0 => _Slot(g.pt(w.$2), g.r),
      1 => _Slot(g.hand(w.$3, w.$2), g.tr),
      _ => _Slot(g.captured(w.$3, w.$2), g.tr),
    };
  }

  Offset _vis(int id, double now) =>
      id == _dragId ? _dragPos : (_flights[id]?.at(now) ?? _targets[id]?.c ?? Offset.zero);
  double _visR(int id, double now, _Geo g) =>
      id == _dragId ? g.r * 1.06 : (_flights[id]?.radius(now) ?? _targets[id]?.r ?? g.r);

  bool _known(int id) => id == _dragId || _flights.containsKey(id) || _targets.containsKey(id);

  Offset _arcCtrl(Offset a, Offset b, double k, double up) {
    final p = Offset.lerp(a, b, k)!;
    return p - Offset(0, up);
  }

  void _launchEvent(_Ev ev, Map<int, _Slot> slots, double now, _Geo g) {
    var land = now;
    final moved = ev.moved;
    if (moved != null && slots.containsKey(moved)) {
      final to = slots[moved]!;
      final from = _known(moved) ? _vis(moved, now) : to.c;
      final r0 = _visR(moved, now, g);
      final d = (to.c - from).distance;
      _Flight f;
      if (ev.dropped) {
        f = _Flight(from, Offset.lerp(from, to.c, 1 / 3)!, Offset.lerp(from, to.c, 2 / 3)!, to.c, r0, to.r, now,
            (0.12 + d / 2600).clamp(0.12, 0.26), Curves.easeOutCubic,
            landing: 0.85, lift: 0.9, decay: true);
      } else if (ev.who == 1) {
        final up = math.min(d * 0.28, g.cell * 1.3);
        f = _Flight(from, _arcCtrl(from, to.c, 0.25, up), _arcCtrl(from, to.c, 0.75, up), to.c, r0, to.r, now,
            (0.5 + d / 1500).clamp(0.5, 0.82), const Cubic(0.55, 0.0, 0.25, 1.0),
            landing: 1.0, lift: 1.0);
      } else {
        final up = math.min(d * 0.2, g.cell * 0.9);
        f = _Flight(from, _arcCtrl(from, to.c, 0.25, up), _arcCtrl(from, to.c, 0.75, up), to.c, r0, to.r, now,
            (0.26 + d / 2200).clamp(0.26, 0.46), const Cubic(0.45, 0.0, 0.25, 1.0),
            landing: 0.9, lift: 0.6);
      }
      _flights[moved] = f;
      _targets[moved] = to;
      land = f.end;
      if (ev.who == 0) HapticFeedback.selectionClick();
    }
    if (ev.mills.isNotEmpty) {
      for (final m in ev.mills) {
        _millFx.add(_MillFx(m, land, ev.who));
      }
      _buzz.add((land, 1));
    }
    final cap = ev.captured;
    if (cap != null && slots.containsKey(cap)) {
      final to = slots[cap]!;
      final from = _known(cap) ? _vis(cap, now) : to.c;
      final popAt = ev.kind == 'remove' ? now : land + (ev.mills.isNotEmpty ? 0.42 : 0.12);
      _pops[cap] = popAt;
      _bursts.add(_Burst(from, g.r, popAt, _owner[cap]!));
      _buzz.add((popAt, 2));
      final d = (to.c - from).distance;
      final up = math.min(d * 0.3, g.cell * 1.6);
      _flights[cap] = _Flight(from, _arcCtrl(from, to.c, 0.3, up), _arcCtrl(from, to.c, 0.8, up * 0.6), to.c, g.r,
          to.r, popAt + 0.2, (0.45 + d / 2400).clamp(0.45, 0.7), Curves.easeInOutCubic,
          landing: 0.4, lift: 0.8);
      _targets[cap] = to;
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Input

  Map<String, dynamic> get _st => s.state;
  bool get _yourTurn => !s.finished && _st['turn'] == 'you' && !_aiBusy;
  bool get _pending => _st['pending_remove'] == true;
  bool get _placing => _st['can_place'] == true;

  List<int> _targetsOf(int p) {
    final t = _st['targets'];
    if (t is! List || p >= t.length) return const [];
    return [for (final x in t[p] as List) _int(x)];
  }

  bool _legal(int? from, int? to) {
    if (to == null) return false;
    final board = _st['board'] as List;
    if (from == null) return _placing && _int(board[to]) == 0;
    return _targetsOf(from).contains(to);
  }

  void _shake(int? id) {
    HapticFeedback.mediumImpact();
    _shakeId = id;
    _shakeAt = _now;
    _kick();
  }

  void _dragStart(Offset p) {
    final g = _geo;
    if (g == null || !_yourTurn || _pending) return;
    if (_placing) {
      if (!g.botTray.inflate(14).contains(p) || _hand[0].isEmpty) return;
      final id = _hand[0].last;
      _flights.remove(id);
      _dragFrom = null;
      _dragId = id;
      _grab = Offset(0, -g.r * 1.25);
      _dragPos = p + _grab;
    } else {
      final pt = g.hit(p);
      if (pt == null || _at[pt] == null || _owner[_at[pt]] != 0) return;
      final id = _at[pt]!;
      _flights.remove(id);
      _dragFrom = pt;
      _dragId = id;
      _grab = (_targets[id]?.c ?? g.pt(pt)) - p;
      _dragPos = p + _grab;
    }
    _selected = null;
    _hover = null;
    HapticFeedback.selectionClick();
    setState(() {});
    _kick();
  }

  void _dragUpdate(Offset p) {
    final g = _geo;
    if (_dragId == null || g == null) return;
    final pos = p + _grab;
    final h = g.hit(pos, 0.6);
    if (h != _hover && h != null && h != _dragFrom) HapticFeedback.selectionClick();
    setState(() {
      _dragPos = pos;
      _hover = h;
    });
  }

  void _dragEnd() {
    final id = _dragId, g = _geo;
    if (id == null || g == null) return;
    final from = _dragFrom, to = _hover;
    _targets[id] = _Slot(_dragPos, g.r * 1.06);
    _dragId = null;
    _dragFrom = null;
    _hover = null;
    var ok = false;
    if (to != null && to != from && _legal(from, to)) {
      _dropId = id;
      ok = s.act(from == null ? {'place': to} : {'from': from, 'to': to});
      _dropId = null;
    } else if (to != null && to != from) {
      // Let the core explain why (toast), unless it's just the opponent's turn.
      if (_yourTurn) s.act(from == null ? {'place': to} : {'from': from, 'to': to});
    }
    if (!ok) {
      _plans[id] = 'back';
      if (to != null && to != from) _shake(id);
    }
    if (mounted) setState(() {});
    _kick();
  }

  void _tap(Offset p) {
    final g = _geo;
    if (g == null || s.finished) return;
    if (!_yourTurn) {
      HapticFeedback.selectionClick();
      return;
    }
    final pt = g.hit(p);
    final board = _st['board'] as List;
    if (_pending) {
      if (pt == null || _int(board[pt]) != 2) return;
      if (!s.act({'remove': pt})) _shake(_at[pt]);
      return;
    }
    if (_placing) {
      if (pt == null) return;
      s.act({'place': pt});
      return;
    }
    if (pt == null) {
      setState(() => _selected = null);
      return;
    }
    if (_int(board[pt]) == 1) {
      HapticFeedback.selectionClick();
      setState(() => _selected = _selected == pt ? null : pt);
      _kick();
      return;
    }
    final sel = _selected;
    if (sel == null) return;
    if (!s.act({'from': sel, 'to': pt})) _shake(_at[sel]);
  }

  // ---------------------------------------------------------------------------------------------
  // Build

  @override
  Widget build(BuildContext context) {
    final st = _st;
    final now = _now;
    return Column(
      children: [
        _strip(st, now),
        Expanded(
          child: LayoutBuilder(builder: (context, box) {
            final size = Size(box.maxWidth, box.maxHeight);
            final g = _geo != null && _layout == size ? _geo! : _Geo.fit(size);
            final relayout = _layout != size;
            if (relayout) {
              _layout = size;
              _geo = g;
              _flights.clear();
              _boardPic?.dispose();
              _boardPic = null;
            }
            // Where every stone belongs right now: (0 point / 1 hand / 2 captured, index, side).
            final where = <int, (int, int, int)>{};
            for (var p = 0; p < 24; p++) {
              final id = _at[p];
              if (id != null) where[id] = (0, p, 0);
            }
            for (var side = 0; side < 2; side++) {
              for (var i = 0; i < _hand[side].length; i++) {
                where[_hand[side][i]] = (1, i, side);
              }
              for (var i = 0; i < _capt[side].length; i++) {
                where[_capt[side][i]] = (2, i, side);
              }
            }
            final slots = {for (final id in where.keys) id: _slotOf(g, id, where)};
            if (relayout) {
              _targets
                ..clear()
                ..addAll(slots);
            }
            for (final ev in _events) {
              _launchEvent(ev, slots, now, g);
            }
            _events.clear();
            for (final e in slots.entries) {
              final id = e.key, to = e.value;
              if (id == _dragId) continue;
              final prev = _targets[id];
              if (prev == null) {
                _targets[id] = to;
                continue;
              }
              if ((prev.c - to.c).distanceSquared < 0.25 && (prev.r - to.r).abs() < 0.01) continue;
              final from = _vis(id, now);
              final r0 = _visR(id, now, g);
              final plan = _plans.remove(id);
              _flights[id] = plan == 'back'
                  ? _Flight(from, Offset.lerp(from, to.c, 0.33)!, Offset.lerp(from, to.c, 0.66)!, to.c, r0, to.r, now,
                      0.3, Curves.easeOutBack, landing: 0.5, lift: 0.7, decay: true)
                  : _Flight(from, Offset.lerp(from, to.c, 0.33)!, Offset.lerp(from, to.c, 0.66)!, to.c, r0, to.r, now,
                      0.26, Curves.easeInOutCubic, landing: 0.3, lift: 0.3);
              _targets[id] = to;
            }
            _targets.removeWhere((k, _) => !slots.containsKey(k));
            if (_busy(now)) _kick();
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => _tap(d.localPosition),
              onPanStart: (d) => _dragStart(d.localPosition),
              onPanUpdate: (d) => _dragUpdate(d.localPosition),
              onPanEnd: (_) => _dragEnd(),
              onPanCancel: _dragEnd,
              child: CustomPaint(size: size, painter: _FnPainter((c, _) => _paint(c, g, now, st, slots))),
            );
          }),
        ),
        _statusLine(st),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              RimIconButton(Icons.undo_rounded,
                  tooltip: 'Geri al (en fazla 1★)',
                  onPressed: st['can_undo'] == true && !_aiBusy && !s.finished && _dragId == null
                      ? () {
                          setState(() => _selected = null);
                          s.act({'undo': true});
                        }
                      : null),
              const SizedBox(width: 28),
              RimIconButton(Icons.lightbulb_outline_rounded,
                  tooltip: 'İpucu: en iyi hamle (en fazla 1★)',
                  onPressed: _yourTurn && st['hint'] is! Map
                      ? () {
                          s.act({'hint': true});
                          _kick();
                        }
                      : null),
            ],
          ),
        ),
      ],
    );
  }

  Widget _strip(Map<String, dynamic> st, double now) {
    final rank = st['rank'] as String? ?? '';
    final idx = _int(st['rank_index']).clamp(0, 5);
    final thinking = _thinking;
    final breath = thinking ? 0.5 + 0.5 * math.sin(now * 4.2) : 0.0;
    final capt = st['captured'] as List? ?? const [0, 0];
    String sub;
    if (s.finished) {
      sub = s.status == 'won' ? 'Yenildi' : (s.status == 'lost' ? 'Kazandı' : 'Berabere');
    } else if (_aiBusy || st['turn'] == 'ai') {
      sub = 'düşünüyor';
    } else {
      sub = 'Sıra sende';
    }
    // Fixed height: the board below must never resize (that would snap every animation).
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      child: Container(
        height: 66,
        padding: const EdgeInsets.fromLTRB(10, 0, 14, 0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: const LinearGradient(colors: [Color(0xFF2A0F18), Color(0xFF0B2A21)]),
          border: Border.all(color: Color.lerp(Lux.line, _garnetLight, breath * 0.6)!),
          boxShadow: [
            BoxShadow(color: _garnet.withValues(alpha: 0.10 + 0.30 * breath), blurRadius: 10 + 14 * breath),
          ],
        ),
        child: Row(
          children: [
            Monogram(_roman[idx], size: 44, tint: Color.lerp(const Color(0xFF5E1428), _garnet, breath)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(rank, maxLines: 1, overflow: TextOverflow.ellipsis, style: Lux.display(23, color: Lux.goldLight)),
                  Row(
                    children: [
                      Flexible(
                        child: Text(sub,
                            maxLines: 1,
                            overflow: TextOverflow.clip,
                            style: Lux.ui(13,
                                color: sub == 'Sıra sende' ? Lux.gold : (thinking ? _garnetLight : Lux.muted),
                                weight: FontWeight.w600)),
                      ),
                      for (var i = 0; i < 3; i++)
                        Opacity(
                          opacity: sub != 'düşünüyor'
                              ? 0
                              : thinking
                                  ? (0.25 + 0.75 * math.max(0, math.sin(now * 6.5 - i * 0.9))).clamp(0.0, 1.0)
                                  : 0.25,
                          child: Text('.', style: Lux.ui(13, color: _garnetLight, weight: FontWeight.w800)),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            _counter(0, _int(capt[0]), 'Aldığın'),
            const SizedBox(width: 14),
            _counter(1, _int(capt[1]), 'Aldığı'),
          ],
        ),
      ),
    );
  }

  /// Captured counter: a stone of the captured colour and the number.
  Widget _counter(int captor, int n, String label) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CustomPaint(size: const Size(16, 16), painter: _StoneIcon(1 - captor)),
              const SizedBox(width: 5),
              Text('$n', style: Lux.ui(19, color: Lux.goldLight, weight: FontWeight.w700)),
            ],
          ),
          Text(label, style: Lux.ui(11, color: Lux.muted, spacing: 0.6)),
        ],
      );

  Widget _statusLine(Map<String, dynamic> st) {
    String text;
    var color = Lux.muted;
    if (s.finished) {
      text = st['end_reason'] as String? ?? '';
      color = s.status == 'won' ? Lux.gold : (s.status == 'lost' ? Lux.bordeauxLight : Lux.goldLight);
    } else if (st['turn'] != 'you' || _aiBusy) {
      text = 'Rakibin sırası';
    } else if (_pending) {
      text = 'Değirmen! Rakibin parlayan taşlarından birini al';
      color = Lux.gold;
    } else if (_placing) {
      text = 'Taş yerleştir: tepsiden sürükle ya da noktaya dokun';
      color = Lux.ink;
    } else if ((st['flying'] as List?)?.first == true) {
      text = 'Uçuş! Taşın istediği boş noktaya gidebilir';
      color = Lux.goldLight;
    } else {
      text = 'Bir taşını çizgi boyunca komşu boş noktaya kaydır';
      color = Lux.ink;
    }
    final extra = <String>[];
    final drawIn = _int(st['draw_in'], -1);
    if (!s.finished && drawIn >= 0 && drawIn <= 30) extra.add('Taş alınmazsa ${(drawIn / 2).ceil()} tur sonra berabere');
    if (!s.finished && _int(st['repeats']) >= 2) extra.add('Bu konum ${st['repeats']}. kez');
    // Fixed height: a status text that wraps must never resize (and so snap) the board.
    return SizedBox(
      height: 54,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 2, 18, 0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: Text(text,
                  key: ValueKey(text),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Lux.ui(14, color: color, weight: FontWeight.w600)),
            ),
            if (extra.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(extra.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Lux.ui(12, color: Lux.bordeauxLight)),
              ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------------------------
  // Painting

  ui.Picture? _boardPic;

  ui.Picture _boardPicture(_Geo g) {
    final rec = ui.PictureRecorder();
    _paintBoard(Canvas(rec), g);
    return rec.endRecording();
  }

  void _paint(Canvas canvas, _Geo g, double now, Map<String, dynamic> st, Map<int, _Slot> slots) {
    canvas.drawPicture(_boardPic ??= _boardPicture(g));
    final pulse = 0.5 + 0.5 * math.sin(now * 5.2);
    final yourTurn = _yourTurn;
    final board = st['board'] as List;

    // Standing mills: a soft glow along the line (only once their stones have settled).
    for (final m in st['mills'] as List? ?? const []) {
      final pts = [for (final p in (m as Map)['points'] as List) _int(p)];
      if (pts.any((p) => _at[p] == null || _flights.containsKey(_at[p]))) continue;
      final owner = _int(m['owner']) - 1;
      final paint = Paint()
        ..color = (owner == 0 ? Lux.gold : _garnetLight).withValues(alpha: 0.28)
        ..strokeWidth = g.r * 0.5
        ..strokeCap = StrokeCap.round
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, g.r * 0.25);
      canvas.drawLine(g.pt(pts.first), g.pt(pts.last), paint);
    }

    // Last AI move ghost: dashed trail from the vacated point, ring where it was.
    final gh = _ghost;
    final ghostTo = gh?.$2;
    final landed = ghostTo == null || _at[ghostTo] == null || !_flights.containsKey(_at[ghostTo]);
    if (gh != null && landed && yourTurn && st['hint'] is! Map) {
      final from = gh.$1, to = gh.$2, rem = gh.$3;
      if (from != null && to != null) {
        _dashed(canvas, g.pt(from), g.pt(to), Paint()
          ..color = _garnetLight.withValues(alpha: 0.38)
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round, g.r * 0.9);
        canvas.drawCircle(g.pt(from), g.r * 0.82, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3
          ..color = _garnetLight.withValues(alpha: 0.35));
      } else if (to != null) {
        canvas.drawCircle(g.pt(to), g.r * 1.18, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = _garnetLight.withValues(alpha: 0.32));
      }
      if (rem != null && _at[rem] == null) {
        canvas.drawCircle(g.pt(rem), g.r * 0.8, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = _ivory.withValues(alpha: 0.22));
      }
    }

    // Legal targets of the dragged / selected stone (or every empty point while placing by drag).
    final src = _dragId != null ? _dragFrom : _selected;
    final showDots = (_dragId != null) || (_selected != null);
    if (showDots) {
      final dots = src == null
          ? [for (var p = 0; p < 24; p++) if (_int(board[p]) == 0) p]
          : _targetsOf(src);
      for (final p in dots) {
        final c = g.pt(p);
        canvas.drawCircle(c, g.r * 0.42, Paint()
          ..color = Lux.gold.withValues(alpha: 0.18 + 0.12 * pulse)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, g.r * 0.2));
        canvas.drawCircle(c, g.r * 0.2, Paint()..color = Lux.goldLight.withValues(alpha: 0.85));
      }
    }
    // Drag hover: gold when legal, bordeaux when not.
    final hv = _hover;
    if (_dragId != null && hv != null && hv != _dragFrom) {
      final ok = _legal(_dragFrom, hv);
      final col = ok ? Lux.gold : Lux.bordeaux;
      canvas.drawCircle(g.pt(hv), g.r * 1.45, Paint()
        ..color = col.withValues(alpha: 0.5)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, g.r * 0.5));
      canvas.drawCircle(g.pt(hv), g.r * 1.32, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..color = ok ? Lux.goldLight : Lux.bordeauxLight);
    }
    // Hint: gold rings on from/to (+ arrow), garnet ring on the stone to take.
    final hint = st['hint'];
    if (hint is Map && yourTurn) {
      final hf = _intOrNull(hint['from']), ht = _intOrNull(hint['to']), hr = _intOrNull(hint['remove']);
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..color = Lux.goldLight.withValues(alpha: 0.55 + 0.45 * pulse);
      final halo = Paint()
        ..color = Lux.gold.withValues(alpha: 0.25 + 0.3 * pulse)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, g.r * 0.45);
      if (!_pending) {
        if (hf != null) {
          canvas.drawCircle(g.pt(hf), g.r * 1.2, halo);
          canvas.drawCircle(g.pt(hf), g.r * 1.12, ring);
        }
        if (ht != null) {
          canvas.drawCircle(g.pt(ht), g.r * 1.2, halo);
          canvas.drawCircle(g.pt(ht), g.r * 0.9, ring);
          if (hf != null) _arrow(canvas, g.pt(hf), g.pt(ht), g.r, ring);
          if (hf == null && _hand[0].isNotEmpty) {
            canvas.drawCircle(g.hand(0, _hand[0].length - 1), g.tr * 1.35, halo);
          }
        }
      }
      if (hr != null && (_pending || hf != null || ht != null)) {
        canvas.drawCircle(g.pt(hr), g.r * 1.32, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4
          ..color = _garnetLight.withValues(alpha: 0.5 + 0.5 * pulse));
      }
    }

    // Stones.
    final removable = _pending && yourTurn
        ? {for (final p in st['removable'] as List? ?? const []) _int(p)}
        : const <int>{};
    final pointOf = <int, int>{};
    for (var p = 0; p < 24; p++) {
      if (_at[p] != null) pointOf[_at[p]!] = p;
    }
    final won = s.status == 'won', lost = s.status == 'lost', draw = s.status == 'draw';
    final endK = _endAt >= 0 ? now - _endAt : -1.0;
    final draws = <(double, VoidCallback)>[];
    for (final id in slots.keys) {
      final owner = _owner[id]!;
      var c = _vis(id, now);
      var r = _visR(id, now, g);
      final f = _flights[id];
      var lift = id == _dragId ? 1.0 : (f?.height(now) ?? 0.0);
      var glow = 0.0;
      var glowColor = Lux.gold;
      var sx = 1.0, sy = 1.0;
      final p = pointOf[id];
      if (p != null && p == _selected) {
        lift = 0.45 + 0.08 * math.sin(now * 2 * math.pi * 0.8);
        glow = 0.8;
      }
      if (p != null && removable.contains(p)) {
        glow = 0.45 + 0.55 * pulse;
        glowColor = Lux.bordeauxLight;
        r *= 1 + 0.04 * pulse;
      }
      final land = _landings[id];
      if (land != null && f == null) {
        final k = now - land;
        if (k >= 0) {
          final sq = 0.16 * math.exp(-k * 10) * math.cos(k * 30);
          sx = 1 + sq;
          sy = 1 - sq;
        }
      }
      final pop = _pops[id];
      if (pop != null && now >= pop && now - pop < 0.22) {
        final k = (now - pop) / 0.22;
        r *= 1 + 0.28 * math.sin(math.pi * k);
        glow = 1 - k;
        glowColor = Colors.white;
      }
      if (id == _shakeId) {
        final k = now - _shakeAt;
        if (k < 0.45) c += Offset(math.sin(k * 48) * 6 * math.exp(-k * 7), 0);
      }
      // End of game: your stones hop in a ripple and glow (win); the opponent's smoulder (loss).
      if (endK >= 0 && p != null && endK < 3.0) {
        if (won && owner == 0) {
          final local = endK - 0.06 * _xy[p].$1 - 0.04 * _xy[p].$2;
          if (local > 0 && local < 0.42) lift = math.max(lift, math.sin(math.pi * local / 0.42) * 0.9);
          glow = math.max(glow, 0.6 * (1 - endK / 3));
        } else if (lost && owner == 1) {
          glow = math.max(glow, (0.35 + 0.35 * pulse) * (1 - endK / 3));
          glowColor = _garnetLight;
        } else if (draw) {
          glow = math.max(glow, 0.3 * (1 - endK / 3));
        }
      }
      final cc = c, rr = r, ll = lift, gg = glow, gc = glowColor, xx = sx, yy = sy;
      final layer = id == _dragId ? 3.0 : (f != null && now >= f.start ? 2.0 : (lift > 0 ? 1.0 : 0.0));
      draws.add((layer + (p == null ? -0.5 : 0), () => _paintStone(canvas, cc, rr, owner, lift: ll, glow: gg, glowColor: gc, sx: xx, sy: yy)));
    }
    draws.sort((a, b) => a.$1.compareTo(b.$1));
    for (final d in draws) {
      d.$2();
    }

    // Effects.
    for (final d in _dust) {
      final k = (now - d.at) / 0.45;
      if (k < 0 || k > 1) continue;
      canvas.drawCircle(d.c, d.r * (1.0 + 0.6 * Curves.easeOut.transform(k)), Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Lux.goldLight.withValues(alpha: 0.5 * (1 - k) * d.strength));
    }
    for (final m in _millFx) {
      _paintMill(canvas, g, m, now);
    }
    for (final b in _bursts) {
      _paintBurst(canvas, b, now);
    }
    if (won && endK >= 0 && endK < 3.0) {
      final rnd = math.Random(3);
      for (var i = 0; i < 26; i++) {
        final x = g.board.left + rnd.nextDouble() * g.board.width;
        final y0 = g.board.top + rnd.nextDouble() * g.board.height;
        final ph = rnd.nextDouble() * 2;
        final k = ((endK + ph) % 1.4) / 1.4;
        final a = math.sin(math.pi * k) * (1 - endK / 3);
        _sparkle(canvas, Offset(x, y0 - k * g.cell * 0.6), g.r * (0.18 + 0.2 * rnd.nextDouble()), a);
      }
    }
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Paint p, double trim) {
    final d = b - a;
    final len = d.distance;
    if (len < 2 * trim) return;
    final u = d / len;
    var t = trim;
    while (t < len - trim) {
      final e = math.min(t + 6, len - trim);
      canvas.drawLine(a + u * t, a + u * e, p);
      t += 11;
    }
  }

  void _arrow(Canvas canvas, Offset a, Offset b, double r, Paint p) {
    final d = b - a;
    final len = d.distance;
    if (len < 3 * r) return;
    final u = d / len;
    final s = a + u * (r * 1.2), e = b - u * (r * 1.05);
    canvas.drawLine(s, e, p);
    final n = Offset(-u.dy, u.dx);
    final path = Path()
      ..moveTo(e.dx, e.dy)
      ..lineTo((e - u * r * 0.45 + n * r * 0.3).dx, (e - u * r * 0.45 + n * r * 0.3).dy)
      ..moveTo(e.dx, e.dy)
      ..lineTo((e - u * r * 0.45 - n * r * 0.3).dx, (e - u * r * 0.45 - n * r * 0.3).dy);
    canvas.drawPath(path, p);
  }

  void _paintMill(Canvas canvas, _Geo g, _MillFx m, double now) {
    final k = now - m.at;
    if (k < 0 || k > 1.0) return;
    final a = g.pt(m.pts.first), b = g.pt(m.pts.last);
    final e = Curves.easeOutCubic.transform((k / 0.32).clamp(0.0, 1.0));
    final fade = k < 0.35 ? 1.0 : (1 - (k - 0.35) / 0.65).clamp(0.0, 1.0);
    final head = Offset.lerp(a, b, e)!;
    final core = m.owner == 0 ? Lux.goldLight : const Color(0xFFFFC2D0);
    final glowC = m.owner == 0 ? Lux.gold : _garnetLight;
    canvas.drawLine(a, head, Paint()
      ..color = glowC.withValues(alpha: 0.55 * fade)
      ..strokeWidth = g.r * 0.9
      ..strokeCap = StrokeCap.round
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, g.r * 0.45));
    canvas.drawLine(a, head, Paint()
      ..color = core.withValues(alpha: 0.95 * fade)
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round);
    // A ring flashes around each stone as the beam reaches it.
    for (var i = 0; i < 3; i++) {
      final at = i / 2 * 0.32;
      final kk = k - at;
      if (kk < 0 || kk > 0.5) continue;
      final t = kk / 0.5;
      canvas.drawCircle(g.pt(m.pts[i]), g.r * (1.0 + 0.55 * Curves.easeOut.transform(t)), Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0 * (1 - t) + 0.5
        ..color = core.withValues(alpha: 0.8 * (1 - t)));
    }
    if (k < 0.32) _sparkle(canvas, head, g.r * 0.45, 1 - k / 0.32 * 0.4);
  }

  void _paintBurst(Canvas canvas, _Burst b, double now) {
    final k = (now - b.at) / 0.6;
    if (k < 0 || k > 1) return;
    final e = Curves.easeOutCubic.transform(k);
    final fade = 1 - k;
    canvas.drawCircle(b.c, b.r * (1 + 1.1 * e), Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3 * fade
      ..color = Colors.white.withValues(alpha: 0.7 * fade));
    final rnd = math.Random(b.c.dx.round() * 31 + b.c.dy.round());
    final base = b.owner == 0 ? _ivory : const Color(0xFF3A0E1C);
    final edge = b.owner == 0 ? const Color(0xFFB9A88E) : _garnetLight;
    for (var i = 0; i < 10; i++) {
      final ang = i / 10 * math.pi * 2 + rnd.nextDouble() * 0.5;
      final dist = b.r * (0.4 + 1.5 * e * (0.7 + 0.6 * rnd.nextDouble()));
      final c = b.c + Offset(math.cos(ang), math.sin(ang)) * dist + Offset(0, b.r * 0.8 * k * k);
      final sz = b.r * (0.22 + 0.16 * rnd.nextDouble()) * (1 - 0.5 * k);
      final rot = ang + k * (rnd.nextDouble() * 8 - 4);
      final path = Path()
        ..moveTo(c.dx + math.cos(rot) * sz, c.dy + math.sin(rot) * sz)
        ..lineTo(c.dx + math.cos(rot + 2.3) * sz * 0.7, c.dy + math.sin(rot + 2.3) * sz * 0.7)
        ..lineTo(c.dx + math.cos(rot + 4.1) * sz * 0.8, c.dy + math.sin(rot + 4.1) * sz * 0.8)
        ..close();
      canvas.drawPath(path, Paint()..color = Color.lerp(base, edge, rnd.nextDouble())!.withValues(alpha: fade));
    }
  }

  void _sparkle(Canvas canvas, Offset c, double s, double a) {
    if (a <= 0) return;
    final p = Paint()..color = Lux.goldLight.withValues(alpha: a.clamp(0.0, 1.0));
    final path = Path()
      ..moveTo(c.dx, c.dy - s)
      ..quadraticBezierTo(c.dx, c.dy, c.dx + s, c.dy)
      ..quadraticBezierTo(c.dx, c.dy, c.dx, c.dy + s)
      ..quadraticBezierTo(c.dx, c.dy, c.dx - s, c.dy)
      ..quadraticBezierTo(c.dx, c.dy, c.dx, c.dy - s)
      ..close();
    canvas.drawPath(path, p);
  }
}

/// Lacquered walnut board with gold inlay, recessed trays above and below.
void _paintBoard(Canvas canvas, _Geo g) {
  final b = g.board;
  final rr = RRect.fromRectAndRadius(b, Radius.circular(b.width * 0.045));
  canvas.drawRRect(rr.shift(const Offset(0, 8)), Paint()
    ..color = Colors.black.withValues(alpha: 0.6)
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16));
  canvas.drawRRect(
      rr,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF4B2415), Color(0xFF2A120A), Color(0xFF3F1E10), Color(0xFF1C0C06)],
          stops: [0, 0.38, 0.62, 1],
        ).createShader(b));
  // Wood grain: gently wavy, slightly diverging fibres.
  canvas.save();
  canvas.clipRRect(rr);
  final rnd = math.Random(11);
  for (var i = 0; i < 64; i++) {
    final y0 = b.top + (i + rnd.nextDouble()) * b.height / 64;
    final amp = b.height * (0.004 + 0.01 * rnd.nextDouble());
    final freq = 2 + rnd.nextDouble() * 3;
    final ph = rnd.nextDouble() * 6.28;
    final path = Path()..moveTo(b.left, y0);
    for (var x = 0.0; x <= b.width; x += b.width / 40) {
      path.lineTo(b.left + x, y0 + math.sin(x / b.width * freq * math.pi + ph) * amp + x / b.width * amp * 1.5);
    }
    final light = i.isEven;
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5 + rnd.nextDouble() * 1.4
          ..color = light
              ? const Color(0xFFFFC98A).withValues(alpha: 0.035 + 0.04 * rnd.nextDouble())
              : Colors.black.withValues(alpha: 0.07 + 0.08 * rnd.nextDouble()));
  }
  // Lacquer: a glossy sheen from the top and a soft specular bloom.
  canvas.drawRect(
      b,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white.withValues(alpha: 0.10), Colors.white.withValues(alpha: 0.0), Colors.black.withValues(alpha: 0.2)],
          stops: const [0, 0.45, 1],
        ).createShader(b));
  canvas.drawCircle(
      b.topLeft + Offset(b.width * 0.28, b.height * 0.16),
      b.width * 0.42,
      Paint()
        ..shader = RadialGradient(colors: [Colors.white.withValues(alpha: 0.07), Colors.white.withValues(alpha: 0.0)])
            .createShader(Rect.fromCircle(center: b.topLeft + Offset(b.width * 0.28, b.height * 0.16), radius: b.width * 0.42)));
  canvas.restore();
  // Gold frame.
  final foil = Paint()
    ..style = PaintingStyle.stroke
    ..shader = Lux.foil.createShader(b);
  canvas.drawRRect(rr.deflate(1.5), foil..strokeWidth = 3);
  canvas.drawRRect(rr.deflate(7), Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.8
    ..color = Lux.gold.withValues(alpha: 0.45));
  // Inlay: three squares and the four connectors, engraved then filled with gold leaf.
  final lines = <(Offset, Offset)>[];
  for (final sq in const [(0, 6), (1, 5), (2, 4)]) {
    final a = sq.$1, z = sq.$2;
    Offset at(int x, int y) => b.topLeft + Offset(g.m + x * g.cell, g.m + y * g.cell);
    lines.addAll([(at(a, a), at(z, a)), (at(z, a), at(z, z)), (at(z, z), at(a, z)), (at(a, z), at(a, a))]);
  }
  for (final c in const [(1, 7), (9, 11), (12, 14), (16, 22)]) {
    lines.add((g.pt(c.$1), g.pt(c.$2)));
  }
  final groove = Paint()
    ..strokeWidth = 4.6
    ..strokeCap = StrokeCap.square
    ..color = Colors.black.withValues(alpha: 0.55);
  final gold = Paint()
    ..strokeWidth = 2.6
    ..strokeCap = StrokeCap.square
    ..shader = Lux.foil.createShader(b);
  final shine = Paint()
    ..strokeWidth = 0.7
    ..color = Colors.white.withValues(alpha: 0.22);
  for (final l in lines) {
    canvas.drawLine(l.$1 + const Offset(0.6, 1.2), l.$2 + const Offset(0.6, 1.2), groove);
  }
  for (final l in lines) {
    canvas.drawLine(l.$1, l.$2, gold);
  }
  for (final l in lines) {
    canvas.drawLine(l.$1 - const Offset(0.5, 0.6), l.$2 - const Offset(0.5, 0.6), shine);
  }
  // Centre rosette.
  final cc = b.center;
  final star = Path();
  for (var i = 0; i < 16; i++) {
    final rad = i.isEven ? g.cell * 0.42 : g.cell * 0.16;
    final a = i / 16 * math.pi * 2 - math.pi / 2;
    final p = cc + Offset(math.cos(a), math.sin(a)) * rad;
    if (i == 0) {
      star.moveTo(p.dx, p.dy);
    } else {
      star.lineTo(p.dx, p.dy);
    }
  }
  star.close();
  canvas.drawPath(star, Paint()
    ..shader = Lux.foil.createShader(Rect.fromCircle(center: cc, radius: g.cell * 0.42))
    ..color = Colors.white.withValues(alpha: 0.5));
  canvas.drawCircle(cc, g.cell * 0.07, Paint()..color = const Color(0xFF2A120A));
  // Studs on the 24 points; crossroads (4 lines) a touch larger.
  for (var p = 0; p < 24; p++) {
    final c = g.pt(p);
    final big = const {4, 10, 13, 19}.contains(p);
    final r = g.r * (big ? 0.26 : 0.21);
    canvas.drawCircle(c + const Offset(0.6, 1.2), r, Paint()..color = Colors.black.withValues(alpha: 0.55));
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = const RadialGradient(
            center: Alignment(-0.35, -0.4),
            colors: [Color(0xFFFBE7B0), Color(0xFFD4A94E), Color(0xFF6F4F17)],
            stops: [0, 0.5, 1],
          ).createShader(Rect.fromCircle(center: c, radius: r)));
  }
  // Trays: velvet-lined grooves with a gold hairline.
  for (final t in [g.topTray, g.botTray]) {
    final tr = RRect.fromRectAndRadius(t, Radius.circular(t.height / 2));
    canvas.drawRRect(
        tr,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF051A14), Color(0xFF0B3328)],
          ).createShader(t));
    canvas.save();
    canvas.clipRRect(tr);
    canvas.drawRRect(tr.shift(const Offset(0, 3)), Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..color = Colors.black.withValues(alpha: 0.55)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    canvas.restore();
    canvas.drawRRect(tr, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Lux.gold.withValues(alpha: 0.4));
  }
}

/// Glossy stone: ivory/pearl (owner 0) or obsidian with a garnet core (owner 1).
void _paintStone(Canvas canvas, Offset c, double r, int owner,
    {double lift = 0, double glow = 0, Color glowColor = Lux.gold, double sx = 1, double sy = 1}) {
  final rr = r * (1 + 0.12 * lift);
  final body = c - Offset(0, r * 0.28 * lift);
  // Shadow stays on the board; it widens and softens as the stone rises.
  canvas.drawOval(
      Rect.fromCenter(center: c + Offset(r * (0.08 + 0.25 * lift), r * (0.2 + 0.4 * lift)), width: rr * 2.0, height: rr * 1.8),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.5 - 0.2 * lift)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2 + 7 * lift));
  if (glow > 0) {
    canvas.drawCircle(body, rr * 1.32, Paint()
      ..color = glowColor.withValues(alpha: 0.5 * glow.clamp(0.0, 1.0))
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, rr * 0.4));
  }
  canvas.save();
  canvas.translate(body.dx, body.dy + rr);
  canvas.scale(sx, sy);
  canvas.translate(-body.dx, -body.dy - rr);
  final rect = Rect.fromCircle(center: body, radius: rr);
  if (owner == 0) {
    canvas.drawCircle(
        body,
        rr,
        Paint()
          ..shader = const RadialGradient(
            center: Alignment(-0.35, -0.45),
            radius: 1.05,
            colors: [Color(0xFFFFFFFF), Color(0xFFF4ECDD), Color(0xFFD8CAB0), Color(0xFF8F7E63)],
            stops: [0, 0.32, 0.74, 1],
          ).createShader(rect));
    // Pearl sheen: a faint rainbow sweep.
    canvas.drawCircle(
        body,
        rr * 0.92,
        Paint()
          ..shader = SweepGradient(colors: [
            const Color(0xFFFFC6D9).withValues(alpha: 0.16),
            Colors.transparent,
            const Color(0xFFBFEFFF).withValues(alpha: 0.16),
            Colors.transparent,
            const Color(0xFFFFE6A0).withValues(alpha: 0.18),
            const Color(0xFFFFC6D9).withValues(alpha: 0.16),
          ]).createShader(rect));
    canvas.drawCircle(body, rr - 0.6, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..color = const Color(0xFF6E5A3C).withValues(alpha: 0.45));
  } else {
    canvas.drawCircle(
        body,
        rr,
        Paint()
          ..shader = const RadialGradient(
            center: Alignment(-0.35, -0.45),
            radius: 1.05,
            colors: [Color(0xFFB34A66), Color(0xFF5C1529), Color(0xFF22070F), Color(0xFF070203)],
            stops: [0, 0.3, 0.7, 1],
          ).createShader(rect));
    // Garnet glow from inside, low on the stone.
    canvas.drawCircle(
        body + Offset(rr * 0.18, rr * 0.3),
        rr * 0.55,
        Paint()
          ..shader = RadialGradient(colors: [_garnetLight.withValues(alpha: 0.22), Colors.transparent])
              .createShader(Rect.fromCircle(center: body + Offset(rr * 0.18, rr * 0.3), radius: rr * 0.55)));
    canvas.drawCircle(body, rr - 0.6, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..color = _garnetLight.withValues(alpha: 0.38));
  }
  // Specular highlight.
  canvas.save();
  canvas.translate(body.dx - rr * 0.34, body.dy - rr * 0.42);
  canvas.rotate(-0.6);
  canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: rr * 0.62, height: rr * 0.34), Paint()
    ..color = Colors.white.withValues(alpha: owner == 0 ? 0.75 : 0.5)
    ..maskFilter = MaskFilter.blur(BlurStyle.normal, rr * 0.06));
  canvas.restore();
  canvas.restore();
}

class _StoneIcon extends CustomPainter {
  final int owner;
  const _StoneIcon(this.owner);
  @override
  void paint(Canvas canvas, Size size) => _paintStone(canvas, size.center(Offset.zero), size.width / 2, owner);
  @override
  bool shouldRepaint(_StoneIcon old) => old.owner != owner;
}

class _FnPainter extends CustomPainter {
  final void Function(Canvas, Size) fn;
  _FnPainter(this.fn);
  @override
  void paint(Canvas canvas, Size size) => fn(canvas, size);
  @override
  bool shouldRepaint(_FnPainter old) => true;
}
