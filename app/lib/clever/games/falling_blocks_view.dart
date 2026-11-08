import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';
import 'falling_blocks_gesture.dart';

/// Düşen Bloklar: a 10×20 well of jewel tiles. Gestures on the well: tap = rotate clockwise,
/// drag left/right = move cell by cell, slow drag down = soft drop, fast flick down = hard drop,
/// flick up = hold, two-finger tap = rotate counter-clockwise. Buttons below do the same.
/// A downward swipe locks to vertical and drops in the column it started in ([WellGesture]).
///
/// Motion model (all visual — the core state is always drawn "now", input is never delayed):
/// every state update from Rust is diffed against the previous one in [_FallingBlocksState._onSession].
/// - The active piece keeps a visual residual (offset in cells + rotation angle) that eases to zero:
///   ~70 ms per lateral move / gravity step, ~90 ms for a quarter turn about the piece's centroid.
/// - Hard drop: a fading light trail per column, a small damped kick of the whole well, medium haptic.
/// - Lock: the locked cells flash gold (light haptic for a soft lock).
/// - Line clear: rows flash white-gold, dissolve outward from the centre column throwing gold sparks,
///   then the stack above falls into place (easeOutCubic) once the core removes the rows.
/// - Multi-line / T-spin / combo: a floating label rises and fades; quads and T-spins flash harder.
/// - Win: a gold wave sweeps up the well before the shared result card appears.
Widget fallingBlocksView(BuildContext context, GameSession s) => _FallingBlocks(key: ObjectKey(s), session: s);

/// Deep jewel colour per piece kind (1..7 = I O T S Z J L, 8 = garbage). Our own palette.
const _jewels = <Color>[
  Color(0xFF000000),
  Color(0xFF13915A), // I emerald
  Color(0xFFB8173B), // O ruby
  Color(0xFF2346B8), // T sapphire
  Color(0xFFD99A1E), // S topaz
  Color(0xFF8A3FC4), // Z amethyst
  Color(0xFFD2508A), // J tourmaline
  Color(0xFF1B9DAE), // L aquamarine
  Color(0xFF4E463F), // garbage: smoky quartz
];

/// Spawn-orientation cells (display only, for the hold / next panels).
const _shapes = <List<List<int>>>[
  [],
  [[0, 0], [1, 0], [2, 0], [3, 0]],
  [[0, 0], [1, 0], [0, 1], [1, 1]],
  [[1, 0], [0, 1], [1, 1], [2, 1]],
  [[1, 0], [2, 0], [0, 1], [1, 1]],
  [[0, 0], [1, 0], [1, 1], [2, 1]],
  [[0, 0], [0, 1], [1, 1], [2, 1]],
  [[2, 0], [0, 1], [1, 1], [2, 1]],
];

// Animation timings (seconds).
const double _moveDur = 0.07;
const double _turnDur = 0.09;
const double _spawnDur = 0.09;
const double _trailDur = 0.18;
const double _kickDur = 0.15;
const double _lockDur = 0.12;
const double _clearDur = 0.28; // matches the core's CLEAR_MS
const double _fallDur = 0.16;
const double _riseDur = 0.12;
const double _labelDur = 0.8;
const double _winDur = 0.8;
const double _sparkGravity = 14; // cells / s²

double _ease(double at, double dur, double now) => Curves.easeOutCubic.transform(((now - at) / dur).clamp(0.0, 1.0));

List<int> _ints(Object? v) => v is List ? [for (final e in v) (e as num).toInt()] : const [];

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Repaint signal for the painters: pinged by the ticker while effects run.
class _Frame extends ChangeNotifier {
  void ping() => notifyListeners();
}

/// A spark of gold dust, in cell units; position is analytic (no per-frame state).
class _Spark {
  final double x, y, vx, vy, born, life, size;
  const _Spark(this.x, this.y, this.vx, this.vy, this.born, this.life, this.size);
}

/// Pre-rendered glossy beveled jewel tiles, one image per (kind, pixel size).
class _Tiles {
  static final Map<int, ui.Image> _cache = {};

  static ui.Image get(int kind, double px) {
    final size = px.round().clamp(4, 400);
    final key = kind * 1000 + size;
    return _cache[key] ??= _render(kind, size.toDouble());
  }

  static ui.Image _render(int kind, double s) {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final base = _jewels[kind];
    final light = Color.lerp(base, Colors.white, 0.45)!;
    final dark = Color.lerp(base, Colors.black, 0.55)!;
    final outer = RRect.fromRectAndRadius(Rect.fromLTWH(s * 0.03, s * 0.03, s * 0.94, s * 0.94), Radius.circular(s * 0.16));
    c.drawRRect(
      outer,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [light, base, dark],
          stops: const [0, 0.5, 1],
        ).createShader(outer.outerRect),
    );
    // Bevel: lighter top-left edges, darker bottom-right edges around an inner table facet.
    final inset = s * 0.17;
    final o = outer.outerRect;
    final inner = Rect.fromLTRB(o.left + inset, o.top + inset, o.right - inset, o.bottom - inset);
    final top = Path()
      ..moveTo(o.left, o.top)
      ..lineTo(o.right, o.top)
      ..lineTo(inner.right, inner.top)
      ..lineTo(inner.left, inner.top)
      ..close();
    final left = Path()
      ..moveTo(o.left, o.top)
      ..lineTo(inner.left, inner.top)
      ..lineTo(inner.left, inner.bottom)
      ..lineTo(o.left, o.bottom)
      ..close();
    final bottom = Path()
      ..moveTo(o.left, o.bottom)
      ..lineTo(inner.left, inner.bottom)
      ..lineTo(inner.right, inner.bottom)
      ..lineTo(o.right, o.bottom)
      ..close();
    final right = Path()
      ..moveTo(o.right, o.top)
      ..lineTo(o.right, o.bottom)
      ..lineTo(inner.right, inner.bottom)
      ..lineTo(inner.right, inner.top)
      ..close();
    c.save();
    c.clipRRect(outer);
    c.drawPath(top, Paint()..color = Colors.white.withValues(alpha: 0.32));
    c.drawPath(left, Paint()..color = Colors.white.withValues(alpha: 0.16));
    c.drawPath(bottom, Paint()..color = Colors.black.withValues(alpha: 0.38));
    c.drawPath(right, Paint()..color = Colors.black.withValues(alpha: 0.24));
    c.restore();
    final table = RRect.fromRectAndRadius(inner, Radius.circular(s * 0.06));
    c.drawRRect(
      table,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.4, -0.5),
          radius: 1.1,
          colors: [Color.lerp(base, Colors.white, 0.3)!, base, Color.lerp(base, Colors.black, 0.3)!],
        ).createShader(inner),
    );
    // Specular glint and a fine light rim.
    c.drawOval(
      Rect.fromLTWH(inner.left + s * 0.04, inner.top + s * 0.03, inner.width * 0.5, inner.height * 0.28),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.38)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.03),
    );
    c.drawRRect(
      outer,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.03
        ..color = Color.lerp(base, Colors.white, 0.6)!.withValues(alpha: 0.45),
    );
    return rec.endRecording().toImageSync(s.toInt(), s.toInt());
  }

  static final Paint _paint = Paint()..filterQuality = FilterQuality.medium;

  /// Draws a tile into [r]. [px] is the nominal (unscaled) cell size: animated, scaled tiles reuse
  /// the image rendered for that size instead of rasterising a new one per frame.
  static void draw(Canvas canvas, int kind, Rect r, double dpr, {double opacity = 1, double? px}) {
    if (opacity <= 0.004 || r.width <= 0.5) return;
    final img = get(kind, (px ?? r.width) * dpr);
    _paint.color = Color.fromRGBO(255, 255, 255, opacity.clamp(0.0, 1.0));
    canvas.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), r, _paint);
  }
}

class _FallingBlocks extends StatefulWidget {
  final GameSession session;
  const _FallingBlocks({super.key, required this.session});

  @override
  State<_FallingBlocks> createState() => _FallingBlocksState();
}

class _FallingBlocksState extends State<_FallingBlocks> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  bool _paused = false;
  final _frame = _Frame();
  final _rng = math.Random();

  // Gesture tracking on the well.
  final Map<int, Offset> _pointers = {};
  int _primary = -1;
  bool _multi = false;
  late final WellGesture _gesture = WellGesture(_send);
  final Stopwatch _clock = Stopwatch()..start();
  double _cell = 24;

  double get _now => _clock.elapsedMicroseconds / 1e6;

  // Previous state, for diffing.
  String _pBoard = '';
  List<int> _pCur = const [];
  int _pGd = 0;
  List<int> _pClr = const [];
  int _pEv = 0;
  bool _pCh = true;
  String _pStatus = 'playing';

  // Active piece: residual offset (cells) and angle (radians) that ease to zero.
  double _ox = 0, _oy = 0, _oAt = -10, _oDur = _moveDur;
  double _ang = 0, _angAt = -10;
  double _spawnAt = -10;
  int _turnHint = 1;

  // Hard drop trail + well kick.
  bool _hdPending = false;
  List<int> _trail = const [];
  int _trailGd = 0;
  double _trailAt = -10;
  double _kickAt = -10;

  // Lock flash: [x0, y0, x1, y1, ...] of the cells that just locked.
  List<int> _lockCells = const [];
  double _lockAt = -10;
  bool _lockHard = false;

  // Line clear: dissolve, then the stack above falls by _rowShift[y] rows.
  List<int> _clearRows = const [];
  double _clearAt = -10;
  bool _clearing = false;
  bool _clearStrong = false;
  String? _boardOverride;
  int _pendingEnd = 0; // 1 = drop the override when the dissolve ends (won), 2 = compact it ourselves (game over)
  final Float64List _rowShift = Float64List(20);
  double _fallAt = -10;
  double _riseAt = -10;

  final List<_Spark> _sparks = [];

  String _label = '';
  double _labelAt = -10;
  double _labelRow = 6;
  bool _labelStrong = false;

  double _winAt = -1;
  bool _winBuzzed = false;

  GameSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _snapshot();
    s.addListener(_onSession);
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    s.removeListener(_onSession);
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && !s.finished) _setPaused(true);
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1000.0;
    _last = elapsed;
    if (!_paused && !s.finished && !s.loading) s.tick(dt.clamp(0, 100).toDouble());
    final now = _now;
    _housekeep(now);
    final busy = _fxBusy(now);
    if (busy) _frame.ping();
    if (s.finished && !busy) _ticker.stop();
  }

  void _setPaused(bool p) {
    if (_paused == p) return;
    setState(() => _paused = p);
  }

  bool get _live => !_paused && !s.finished && !s.loading;

  void _act(String a) {
    if (!_live) return;
    if (a == 'cw') _turnHint = 1;
    if (a == 'ccw') _turnHint = -1;
    if (a == 'hd') {
      final cur = _ints(s.state['cur']);
      if (cur.length == 9) {
        _trail = cur;
        _trailGd = (s.state['gd'] as num?)?.toInt() ?? 0;
        _hdPending = true;
      }
    }
    s.act({'a': a});
    if (_hdPending) {
      _hdPending = false;
      final now = _now;
      _trailAt = now;
      _kickAt = now;
      HapticFeedback.mediumImpact();
      _ensureTicker();
    }
  }

  // ---- effects: state diffing ----

  void _snapshot() {
    final st = s.state;
    _pBoard = (st['b'] as String?) ?? '';
    _pCur = _ints(st['cur']);
    _pGd = (st['gd'] as num?)?.toInt() ?? 0;
    _pClr = _ints(st['clr']);
    _pEv = (st['ev'] as num?)?.toInt() ?? 0;
    _pCh = st['ch'] == true;
    _pStatus = s.status;
  }

  void _onSession() {
    final st = s.state;
    final now = _now;
    final board = (st['b'] as String?) ?? '';
    final cur = _ints(st['cur']);
    final clr = _ints(st['clr']);
    final ev = (st['ev'] as num?)?.toInt() ?? 0;
    final et = (st['et'] as String?) ?? '';
    final ch = st['ch'] == true;
    final status = s.status;

    final boardChanged = board != _pBoard;
    // Garbage rise: everything moved up one row and a new bottom row came in.
    final rise = boardChanged &&
        board.length == 200 &&
        _pBoard.length == 200 &&
        board.substring(0, 190) == _pBoard.substring(10);
    // The only other board changes are a lock (piece written in) and row removal (no piece then).
    final locked = _pCur.length == 9 && boardChanged && !rise;
    final held = !locked && _pCh && !ch;

    if (rise) {
      _riseAt = now;
      _fallAt = -10;
    }
    if (locked) {
      _lockCells = [
        for (var c = 0; c < 4; c++) ...[_pCur[1 + c * 2], _pCur[2 + c * 2] + _pGd]
      ];
      _lockAt = now;
      _lockHard = _hdPending;
      _fallAt = -10; // new cells are in place: stop shifting rows visually
      if (!_hdPending) HapticFeedback.lightImpact();
    }

    // Active piece motion.
    if (cur.length == 9) {
      final fresh = _pCur.length != 9 || locked || held || cur[0] != _pCur[0];
      if (fresh) {
        _ox = 0;
        _oy = -0.45;
        _oAt = now;
        _oDur = _spawnDur;
        _ang = 0;
        _angAt = -10;
        _spawnAt = now;
        _gesture.newPiece();
      } else if (!_same(cur, _pCur)) {
        _follow(_pCur, cur, now);
      }
    }

    final strongText = et.contains('T-dönüş') || et.contains('Dörtlü') || et.contains('Tam temizlik');
    final newEvent = ev != _pEv && et.isNotEmpty;

    // Line clear: the core keeps the full rows in place for 280 ms.
    if (clr.isNotEmpty && !_same(clr, _pClr)) {
      _startClear(clr, now, clr.length >= 4 || (newEvent && strongText));
    } else if (clr.isEmpty && _pClr.isNotEmpty && _clearing && _pendingEnd == 0) {
      _startFall(now); // rows removed: let the stack above fall into place
    }
    // A winning lock removes its rows at once: replay the clear from a snapshot.
    if (locked && clr.isEmpty && status == 'won' && _pBoard.length == 200) {
      final b = _pBoard.codeUnits.toList();
      for (var c = 0; c < 8; c += 2) {
        final x = _lockCells[c], y = _lockCells[c + 1];
        if (x >= 0 && x < 10 && y >= 0 && y < 20) b[y * 10 + x] = 48 + _pCur[0];
      }
      final rows = [
        for (var y = 0; y < 20; y++)
          if (Iterable<int>.generate(10).every((x) => b[y * 10 + x] != 48)) y
      ];
      if (rows.isNotEmpty) {
        _boardOverride = String.fromCharCodes(b);
        _startClear(rows, now, rows.length >= 4 || (newEvent && strongText));
        _pendingEnd = 1;
      }
    }
    // The game ended while rows were still flashing (time up / piece budget): finish the clear here.
    if (status != 'playing' && _pStatus == 'playing' && clr.isNotEmpty) _pendingEnd = 2;

    if (newEvent) {
      _label = Lux.upper(et);
      _labelAt = now;
      _labelStrong = strongText || clr.length >= 4;
      if (_clearing) {
        _labelRow = _clearRows.fold<int>(0, (a, y) => a + y) / _clearRows.length + 0.5;
      } else if (locked) {
        _labelRow = (_lockCells[1] + _lockCells[3] + _lockCells[5] + _lockCells[7]) / 4 + 0.5;
      } else {
        _labelRow = 6;
      }
    }

    if (status == 'won' && _pStatus != 'won') {
      var at = now;
      if (_clearing) at = math.max(at, _clearAt + _clearDur + _fallDur * 0.6);
      _winAt = at;
      _winBuzzed = false;
      for (var i = 0; i < 18; i++) {
        _sparks.add(_Spark(_rng.nextDouble() * 10, 20.3, (_rng.nextDouble() - 0.5) * 3, -(12 + _rng.nextDouble() * 10),
            at + _rng.nextDouble() * 0.4, 0.55 + _rng.nextDouble() * 0.35, 0.05 + _rng.nextDouble() * 0.06));
      }
    }

    _pBoard = board;
    _pCur = cur;
    _pGd = (st['gd'] as num?)?.toInt() ?? 0;
    _pClr = clr;
    _pEv = ev;
    _pCh = ch;
    _pStatus = status;
    _ensureTicker();
  }

  void _ensureTicker() {
    if (!_ticker.isActive && _fxBusy(_now)) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _startClear(List<int> rows, double now, bool strong) {
    _clearRows = rows;
    _clearAt = now;
    _clearing = true;
    _clearStrong = strong;
    if (strong) {
      HapticFeedback.heavyImpact();
    } else {
      HapticFeedback.mediumImpact();
    }
    final per = strong ? 7 : 4;
    for (final y in rows) {
      for (var i = 0; i < per; i++) {
        final dir = i.isEven ? 1.0 : -1.0;
        _sparks.add(_Spark(
          5 + dir * _rng.nextDouble() * 0.6,
          y + 0.3 + _rng.nextDouble() * 0.4,
          dir * (5 + _rng.nextDouble() * 11),
          -(1.5 + _rng.nextDouble() * 5),
          now + 0.07 + _rng.nextDouble() * 0.1,
          0.38 + _rng.nextDouble() * 0.35,
          0.045 + _rng.nextDouble() * 0.06,
        ));
      }
    }
  }

  void _startFall(double now) {
    _clearing = false;
    final rows = _clearRows;
    var dst = 19;
    for (var y = 19; y >= 0; y--) {
      if (rows.contains(y)) continue;
      _rowShift[dst] = (dst - y).toDouble();
      dst--;
    }
    for (; dst >= 0; dst--) {
      _rowShift[dst] = rows.length.toDouble();
    }
    _fallAt = now;
  }

  void _housekeep(double now) {
    if (_clearing && _pendingEnd != 0 && now - _clearAt >= _clearDur) {
      _boardOverride = _pendingEnd == 2 ? _compact((s.state['b'] as String?) ?? '', _clearRows) : null;
      _pendingEnd = 0;
      _startFall(now);
    }
    if (_sparks.isNotEmpty) _sparks.removeWhere((p) => now - p.born > p.life);
    if (_winAt >= 0 && !_winBuzzed && now >= _winAt) {
      _winBuzzed = true;
      HapticFeedback.mediumImpact();
    }
  }

  static String _compact(String board, List<int> rows) {
    if (board.length != 200) return board;
    final kept = StringBuffer();
    for (var y = 0; y < 20; y++) {
      if (!rows.contains(y)) kept.write(board.substring(y * 10, y * 10 + 10));
    }
    return '0' * (200 - kept.length) + kept.toString();
  }

  bool _fxBusy(double now) =>
      now - _oAt < _oDur ||
      now - _angAt < _turnDur ||
      now - _trailAt < _trailDur ||
      now - _kickAt < _kickDur ||
      now - _lockAt < 0.2 ||
      _clearing ||
      now - _fallAt < _fallDur ||
      now - _riseAt < _riseDur ||
      _sparks.isNotEmpty ||
      now - _labelAt < _labelDur ||
      (_winAt >= 0 && now - _winAt < _winDur + 0.05);

  // ---- active piece residuals ----

  Offset _residual(double now) {
    final k = 1 - _ease(_oAt, _oDur, now);
    return k == 0 ? Offset.zero : Offset(_ox * k, _oy * k);
  }

  double _angResidual(double now) => _ang * (1 - _ease(_angAt, _turnDur, now));

  /// The same piece moved or turned: keep it where it is drawn now and let it glide to the new cells.
  void _follow(List<int> a, List<int> b, double now) {
    final turn = _turn(a, b);
    if (turn == null) {
      _ox = _oy = 0;
      _ang = 0;
      return;
    }
    final r = _residual(now);
    final ca = _centroid(a), cb = _centroid(b);
    final dx = ca.dx + r.dx - cb.dx, dy = ca.dy + r.dy - cb.dy;
    if (turn != 0) {
      _ang = _angResidual(now) - turn * math.pi / 2;
      _angAt = now;
    }
    if (dx.abs() > 1e-6 || dy.abs() > 1e-6) {
      _ox = dx.clamp(-20.0, 20.0);
      _oy = dy.clamp(-24.0, 24.0);
      _oAt = now;
      _oDur = _moveDur;
    }
  }

  static Offset _centroid(List<int> c) {
    var x = 0, y = 0;
    for (var i = 0; i < 4; i++) {
      x += c[1 + i * 2];
      y += c[2 + i * 2];
    }
    return Offset(x / 4 + 0.5, y / 4 + 0.5);
  }

  /// Cells relative to the centroid, ×8 so they stay integers.
  static List<(int, int)> _rel(List<int> c) {
    var sx = 0, sy = 0;
    for (var i = 0; i < 4; i++) {
      sx += 2 * c[1 + i * 2] + 1;
      sy += 2 * c[2 + i * 2] + 1;
    }
    return [for (var i = 0; i < 4; i++) (4 * (2 * c[1 + i * 2] + 1) - sx, 4 * (2 * c[2 + i * 2] + 1) - sy)];
  }

  static bool _sameSet(List<(int, int)> a, List<(int, int)> b) => a.every(b.contains);

  /// 0 = pure translation, 1 = clockwise quarter turn, -1 = counter-clockwise, null = unrelated.
  int? _turn(List<int> a, List<int> b) {
    final ra = _rel(a), rb = _rel(b);
    if (_sameSet(ra, rb)) return 0;
    final cw = _sameSet([for (final p in ra) (-p.$2, p.$1)], rb);
    final ccw = _sameSet([for (final p in ra) (p.$2, -p.$1)], rb);
    if (cw && ccw) return _turnHint; // S / Z / I: both turns give the same cells
    if (cw) return 1;
    if (ccw) return -1;
    return null;
  }

  double _kickOffset(double now) {
    final k = (now - _kickAt) / _kickDur;
    if (k < 0 || k >= 1) return 0;
    const a = 3.5;
    if (k < 0.2) return a * Curves.easeOut.transform(k / 0.2);
    final u = (k - 0.2) / 0.8;
    return a * math.exp(-u * 4.5) * math.cos(u * 7.5);
  }

  // ---- gestures ----

  /// Sends a gesture action; true when the active piece changed (a lateral step that really moved).
  bool _send(String a) {
    final before = _ints(s.state['cur']);
    _act(a);
    return !_same(before, _ints(s.state['cur']));
  }

  void _down(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 1) {
      _primary = e.pointer;
      _multi = false;
      _gesture.down(_clock.elapsedMilliseconds, e.position);
    } else {
      _multi = true;
    }
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _primary || _multi || !_live) return;
    _gesture.move(_clock.elapsedMilliseconds, e.position);
  }

  void _up(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_multi) {
      if (_pointers.isEmpty && !_gesture.moved) _act('ccw');
      if (_pointers.isEmpty) _multi = false;
      _gesture.cancel();
      return;
    }
    if (e.pointer != _primary) return;
    if (e is PointerCancelEvent) {
      _gesture.cancel();
      return;
    }
    _gesture.up(_clock.elapsedMilliseconds);
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    final st = s.state;
    final board = (st['b'] as String?) ?? '';
    final cur = _ints(st['cur']);
    final gd = (st['gd'] as num?)?.toInt() ?? 0;
    final hold = (st['hold'] as num?)?.toInt() ?? 0;
    final canHold = st['ch'] == true;
    final next = _ints(st['nx']);
    final lock = (st['lk'] as num?)?.toDouble() ?? 0;
    final hud = st['hud'] as List? ?? const [];
    final dpr = MediaQuery.devicePixelRatioOf(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 4),
          child: Row(
            children: [
              for (var i = 0; i < hud.length; i++)
                Expanded(child: _stat(i, '${(hud[i] as List)[0]}', '${hud[i][1]}')),
              RimIconButton(_paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                  tooltip: _paused ? 'Devam' : 'Duraklat', onPressed: s.finished ? null : () => _setPaused(!_paused)),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(builder: (context, box) {
            final side = (box.maxWidth * 0.145).clamp(52.0, 92.0);
            final maxWellW = box.maxWidth - 2 * side - 24;
            final wellW = (box.maxHeight - 16) / 2 < maxWellW ? (box.maxHeight - 16) / 2 : maxWellW;
            final wellH = wellW * 2;
            _cell = wellW / 10;
            _gesture.cell = _cell;
            final labelSize = wellW * 0.068;
            return Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: side,
                    child: GestureDetector(
                      onTap: canHold ? () => _act('hold') : null,
                      child: _panel('SAKLA', [hold], dpr, dim: !canHold),
                    ),
                  ),
                  const SizedBox(width: 4),
                  AnimatedBuilder(
                    animation: _frame,
                    builder: (context, child) =>
                        Transform.translate(offset: Offset(0, _kickOffset(_now)), child: child),
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        gradient: Lux.goldGradient,
                        boxShadow: [BoxShadow(color: Lux.gold.withValues(alpha: 0.25), blurRadius: 18)],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: SizedBox(
                          width: wellW,
                          height: wellH,
                          child: Listener(
                            behavior: HitTestBehavior.opaque,
                            onPointerDown: _down,
                            onPointerMove: _move,
                            onPointerUp: _up,
                            onPointerCancel: _up,
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: RepaintBoundary(
                                    child: CustomPaint(
                                      painter: _WellPainter(
                                        fx: this,
                                        board: board,
                                        cur: cur,
                                        gd: gd,
                                        lock: lock,
                                        dpr: dpr,
                                        repaint: _frame,
                                      ),
                                    ),
                                  ),
                                ),
                                if (_label.isNotEmpty)
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    top: (_labelRow * _cell - labelSize * 1.6).clamp(wellH * 0.06, wellH * 0.78),
                                    child: IgnorePointer(child: _floatingLabel(labelSize)),
                                  ),
                                if (_paused)
                                  Positioned.fill(
                                    child: ColoredBox(
                                      color: const Color(0xF20A0705),
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Text(Lux.upper('Duraklatıldı'), style: Lux.display(18)),
                                          const SizedBox(height: 16),
                                          GoldButton('Devam',
                                              icon: Icons.play_arrow_rounded, onPressed: () => _setPaused(false)),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  SizedBox(width: side, child: _panel('SIRADAKİ', next, dpr)),
                ],
              ),
            );
          }),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _RepeatButton(icon: Icons.chevron_left_rounded, onFire: () => _act('l')),
              _RepeatButton(icon: Icons.chevron_right_rounded, onFire: () => _act('r')),
              _RepeatButton(icon: Icons.rotate_left_rounded, onFire: () => _act('ccw'), repeat: false),
              _RepeatButton(icon: Icons.rotate_right_rounded, onFire: () => _act('cw'), repeat: false),
              _RepeatButton(icon: Icons.keyboard_arrow_down_rounded, onFire: () => _act('d')),
              _RepeatButton(icon: Icons.vertical_align_bottom_rounded, onFire: () => _act('hd'), repeat: false, accent: true),
              _RepeatButton(icon: Icons.swap_vert_rounded, onFire: () => _act('hold'), repeat: false, enabled: canHold),
            ],
          ),
        ),
      ],
    );
  }

  /// Event text (multi-line, T-spin, combo): pops in, rises and fades.
  Widget _floatingLabel(double size) {
    final strong = _labelStrong;
    final text = Text(
      _label,
      textAlign: TextAlign.center,
      style: Lux.display(strong ? size * 1.25 : size, color: strong ? const Color(0xFFFFF3D2) : Lux.goldLight, spacing: 1.5)
          .copyWith(shadows: [
        Shadow(color: Lux.gold.withValues(alpha: strong ? 0.95 : 0.6), blurRadius: strong ? 18 : 10),
        const Shadow(color: Color(0xCC000000), blurRadius: 4, offset: Offset(0, 2)),
      ]),
    );
    return AnimatedBuilder(
      animation: _frame,
      builder: (context, child) {
        final k = (_now - _labelAt) / _labelDur;
        if (k < 0 || k >= 1) return const SizedBox.shrink();
        final opacity = k < 0.12 ? k / 0.12 : (k > 0.55 ? 1 - (k - 0.55) / 0.45 : 1.0);
        final scale = 0.72 + 0.28 * Curves.easeOutBack.transform((k / 0.22).clamp(0.0, 1.0));
        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, -size * 2.2 * Curves.easeOutCubic.transform(k)),
            child: Transform.scale(scale: scale, child: child),
          ),
        );
      },
      child: text,
    );
  }

  Widget _stat(int i, String label, String value) => Column(
        children: [
          _Roll(value, key: ValueKey('hud$i$label'), style: Lux.ui(20, color: Lux.goldLight, weight: FontWeight.w700)),
          Text(label, style: Lux.ui(11, color: Lux.muted, spacing: 1)),
        ],
      );

  Widget _panel(String title, List<int> kinds, double dpr, {bool dim = false}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: const Color(0xFF120D08),
        border: Border.all(color: Lux.line),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(title, style: Lux.ui(11, color: Lux.gold, weight: FontWeight.w700, spacing: 1.2)),
          ),
          const SizedBox(height: 6),
          for (var i = 0; i < kinds.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: AspectRatio(
                aspectRatio: 1.6,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 160),
                  opacity: dim ? 0.35 : 1,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: ScaleTransition(scale: Tween(begin: 0.86, end: 1.0).animate(anim), child: child),
                    ),
                    layoutBuilder: (current, previous) =>
                        Stack(alignment: Alignment.center, children: [...previous, if (current != null) current]),
                    child: SizedBox.expand(
                      key: ValueKey(kinds[i]),
                      child: CustomPaint(painter: _MiniPiecePainter(kinds[i], dpr, i == 0 ? 1 : 0.75)),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _WellPainter extends CustomPainter {
  final _FallingBlocksState fx;
  final String board;
  final List<int> cur;
  final int gd;
  final double lock;
  final double dpr;
  _WellPainter({
    required this.fx,
    required this.board,
    required this.cur,
    required this.gd,
    required this.lock,
    required this.dpr,
    required Listenable repaint,
  }) : super(repaint: repaint);

  static final Map<int, ui.Picture> _bgCache = {};
  static final Paint _fill = Paint();
  static final Paint _stroke = Paint()..style = PaintingStyle.stroke;
  static final Paint _shade = Paint();

  /// Velvet-black well with its faint gold grid, recorded once per size.
  static ui.Picture _background(Size size) {
    final key = (size.width * 4).round() * 100000 + (size.height * 4).round();
    return _bgCache[key] ??= () {
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      final cell = size.width / 10;
      final bg = Offset.zero & size;
      canvas.drawRect(
        bg,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF15100B), Color(0xFF0B0806)],
          ).createShader(bg),
      );
      final grid = Paint()
        ..color = Lux.gold.withValues(alpha: 0.06)
        ..strokeWidth = 1;
      for (var x = 1; x < 10; x++) {
        canvas.drawLine(Offset(x * cell, 0), Offset(x * cell, size.height), grid);
      }
      for (var y = 1; y < 20; y++) {
        canvas.drawLine(Offset(0, y * cell), Offset(size.width, y * cell), grid);
      }
      return rec.endRecording();
    }();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final now = fx._now;
    final cell = size.width / 10;
    canvas.drawPicture(_background(size));
    final b = fx._boardOverride ?? board;

    // Stack: rows fall after a clear and glide up when garbage rises.
    final fallK = 1 - _ease(fx._fallAt, _fallDur, now);
    final riseK = 1 - _ease(fx._riseAt, _riseDur, now);
    final clearing = fx._clearing;
    final rows = fx._clearRows;
    for (var y = 0; y < 20 && y * 10 < b.length; y++) {
      if (clearing && rows.contains(y)) {
        _dissolveRow(canvas, size, b, y, cell, now);
        continue;
      }
      final yy = y - (fallK > 0 ? fx._rowShift[y] * fallK : 0) + riseK;
      for (var x = 0; x < 10; x++) {
        final i = y * 10 + x;
        if (i >= b.length) break;
        final k = b.codeUnitAt(i) - 48;
        if (k > 0 && k <= 8) _Tiles.draw(canvas, k, Rect.fromLTWH(x * cell, yy * cell, cell, cell), dpr, px: cell);
      }
    }

    // Gold flash on the cells that just locked.
    final lockDur = fx._lockHard ? 0.16 : _lockDur;
    final lk = (now - fx._lockAt) / lockDur;
    if (lk >= 0 && lk < 1 && fx._lockCells.length == 8) {
      final a = math.pow(1 - lk, 1.6).toDouble();
      _fill.color = Lux.goldLight.withValues(alpha: 0.55 * a);
      _stroke
        ..strokeWidth = 1.6
        ..color = Colors.white.withValues(alpha: 0.75 * a);
      for (var c = 0; c < 8; c += 2) {
        final r = RRect.fromRectAndRadius(
            Rect.fromLTWH(fx._lockCells[c] * cell, fx._lockCells[c + 1] * cell, cell, cell).deflate(1),
            Radius.circular(cell * 0.16));
        canvas.drawRRect(r, _fill);
        canvas.drawRRect(r, _stroke);
      }
    }

    // Hard-drop light trail: one beam per column, its tail retracting into the landed piece.
    final tk = (now - fx._trailAt) / _trailDur;
    final trail = fx._trail;
    if (tk >= 0 && tk < 1 && trail.length == 9 && fx._trailGd > 0) {
      final col = Color.lerp(_jewels[trail[0].clamp(0, 8)], Lux.goldLight, 0.55)!;
      final e = Curves.easeOutCubic.transform(tk);
      final g = fx._trailGd;
      for (var x = 0; x < 10; x++) {
        var minY = 99;
        for (var c = 0; c < 4; c++) {
          if (trail[1 + c * 2] == x && trail[2 + c * 2] < minY) minY = trail[2 + c * 2];
        }
        if (minY == 99) continue;
        final w = cell * (0.86 - 0.3 * e);
        final top = (minY + g * e * 0.85) * cell;
        final bottom = (minY + g + 0.35) * cell;
        if (bottom - top < 1) continue;
        final rect = Rect.fromLTRB((x + 0.5) * cell - w / 2, top, (x + 0.5) * cell + w / 2, bottom);
        _shade.shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter,
            [col.withValues(alpha: 0), col.withValues(alpha: 0.55 * (1 - tk) * (1 - tk))]);
        canvas.drawRect(rect, _shade);
      }
      _shade.shader = null;
    }

    if (cur.length == 9) {
      final res = fx._residual(now);
      final ang = fx._angResidual(now);
      // Ghost: follows the piece sideways and through turns, pulses gently.
      if (gd > 0) {
        final pulse = 0.5 + 0.5 * math.sin(now * math.pi * 2 * 0.8);
        final col = _jewels[cur[0].clamp(0, 8)];
        _stroke
          ..strokeWidth = 1.6
          ..color = Color.lerp(col, Colors.white, 0.35)!.withValues(alpha: 0.5 + 0.28 * pulse);
        _fill.color = col.withValues(alpha: 0.08 + 0.08 * pulse);
        _piece(canvas, cell, res.dx, gd.toDouble(), ang, (r) {
          final rr = RRect.fromRectAndRadius(r.deflate(2), Radius.circular(cell * 0.15));
          canvas.drawRRect(rr, _fill);
          canvas.drawRRect(rr, _stroke);
        });
      }
      // Active piece (dims slightly as the lock delay runs out).
      final appear = _ease(fx._spawnAt, _spawnDur, now);
      _shade.color = Colors.black.withValues(alpha: 0.28 * lock);
      _piece(canvas, cell, res.dx, res.dy, ang, (r) {
        _Tiles.draw(canvas, cur[0], r, dpr, opacity: appear, px: cell);
        if (lock > 0.05) canvas.drawRect(r.deflate(1), _shade);
      });
    }

    // Win: a band of gold light sweeps up the well, glinting every tile it passes.
    if (fx._winAt >= 0) {
      final w = (now - fx._winAt) / _winDur;
      if (w >= 0 && w < 1) {
        final yc = 21.5 - 23.5 * Curves.easeInOutSine.transform(w);
        final fade = math.sin(math.pi * w).clamp(0.0, 1.0);
        final band = Rect.fromLTRB(0, (yc - 3) * cell, size.width, (yc + 3) * cell);
        _shade.shader = ui.Gradient.linear(band.topCenter, band.bottomCenter, [
          Lux.goldLight.withValues(alpha: 0),
          Lux.goldLight.withValues(alpha: 0.24 * fade + 0.06),
          Lux.goldLight.withValues(alpha: 0),
        ], const [0, 0.5, 1]);
        canvas.drawRect(band, _shade);
        _shade.shader = null;
        for (var i = 0; i < b.length && i < 200; i++) {
          if (b.codeUnitAt(i) == 48) continue;
          final y = i ~/ 10;
          final d = ((y + 0.5) - yc).abs();
          if (d > 2.2) continue;
          final q = 1 - d / 2.2;
          _fill.color = const Color(0xFFFFF1CC).withValues(alpha: 0.55 * q * q);
          canvas.drawRRect(
              RRect.fromRectAndRadius(Rect.fromLTWH((i % 10) * cell, y * cell, cell, cell).deflate(cell * 0.06),
                  Radius.circular(cell * 0.16)),
              _fill);
        }
      }
    }

    // Gold sparks.
    for (final p in fx._sparks) {
      final t = now - p.born;
      if (t < 0 || t > p.life) continue;
      final o = Offset((p.x + p.vx * t) * cell, (p.y + p.vy * t + 0.5 * _sparkGravity * t * t) * cell);
      final a = 1 - t / p.life;
      _fill.color = Lux.gold.withValues(alpha: 0.28 * a);
      canvas.drawCircle(o, p.size * cell * 2.4, _fill);
      _fill.color = const Color(0xFFFFF4D6).withValues(alpha: 0.95 * a);
      canvas.drawCircle(o, p.size * cell, _fill);
    }

    // Quad / T-spin: a brief wash over the whole well.
    if (clearing && fx._clearStrong) {
      final t = ((now - fx._clearAt) / _clearDur).clamp(0.0, 1.0);
      _fill.color = Lux.goldLight.withValues(alpha: 0.16 * (1 - t) * (1 - t));
      canvas.drawRect(Offset.zero & size, _fill);
    }
  }

  /// Draws the four cells of the active piece about its centroid, offset by (ox, oy) cells and
  /// turned by [ang]; [cellRect] paints one cell given its rect in the rotated frame.
  void _piece(Canvas canvas, double cell, double ox, double oy, double ang, void Function(Rect) cellRect) {
    var mx = 0.0, my = 0.0;
    for (var c = 0; c < 4; c++) {
      mx += cur[1 + c * 2];
      my += cur[2 + c * 2];
    }
    mx /= 4;
    my /= 4;
    canvas.save();
    canvas.translate((mx + 0.5 + ox) * cell, (my + 0.5 + oy) * cell);
    if (ang.abs() > 1e-4) canvas.rotate(ang);
    for (var c = 0; c < 4; c++) {
      cellRect(Rect.fromLTWH((cur[1 + c * 2] - mx - 0.5) * cell, (cur[2 + c * 2] - my - 0.5) * cell, cell, cell));
    }
    canvas.restore();
  }

  /// A clearing row: white-gold flash, then the tiles shrink away outward from the centre column.
  void _dissolveRow(Canvas canvas, Size size, String b, int y, double cell, double now) {
    final t = ((now - fx._clearAt) / _clearDur).clamp(0.0, 1.0);
    if (t >= 1) return;
    final strong = fx._clearStrong;
    final flash = t < 0.3 ? Curves.easeOut.transform(t / 0.3) : 1.0;
    final g = ((t - 0.22) / 0.78).clamp(0.0, 1.0);
    final front = g * 1.3;
    _fill.color = Color.lerp(Lux.goldLight, Colors.white, strong ? 0.6 : 0.3)!
        .withValues(alpha: (strong ? 0.42 : 0.28) * flash * (1 - g));
    canvas.drawRect(Rect.fromLTWH(0, y * cell, size.width, cell), _fill);
    final wash = strong ? Colors.white : const Color(0xFFFFF0C8);
    for (var x = 0; x < 10; x++) {
      final i = y * 10 + x;
      if (i >= b.length) break;
      final k = b.codeUnitAt(i) - 48;
      if (k <= 0 || k > 8) continue;
      final d = (x + 0.5 - 5).abs() / 5;
      final q = ((front - d) / 0.35).clamp(0.0, 1.0);
      if (q >= 1) continue;
      final sc = 1 + 0.06 * flash - 0.9 * Curves.easeIn.transform(q);
      final r = Rect.fromCenter(center: Offset((x + 0.5) * cell, (y + 0.5) * cell), width: cell * sc, height: cell * sc);
      _Tiles.draw(canvas, k, r, dpr, opacity: 1 - q, px: cell);
      _fill.color = wash.withValues(alpha: (strong ? 0.85 : 0.7) * flash * (1 - q));
      canvas.drawRRect(RRect.fromRectAndRadius(r.deflate(cell * 0.04 * sc), Radius.circular(cell * 0.16 * sc)), _fill);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class _MiniPiecePainter extends CustomPainter {
  final int kind;
  final double dpr;
  final double opacity;
  _MiniPiecePainter(this.kind, this.dpr, this.opacity);

  @override
  void paint(Canvas canvas, Size size) {
    if (kind <= 0 || kind > 7) return;
    final cells = _shapes[kind];
    var w = 0, h = 0;
    for (final c in cells) {
      if (c[0] + 1 > w) w = c[0] + 1;
      if (c[1] + 1 > h) h = c[1] + 1;
    }
    final cell = (size.width / 4.2) < (size.height / 2.4) ? size.width / 4.2 : size.height / 2.4;
    final ox = (size.width - w * cell) / 2, oy = (size.height - h * cell) / 2;
    for (final c in cells) {
      _Tiles.draw(canvas, kind, Rect.fromLTWH(ox + c[0] * cell, oy + c[1] * cell, cell, cell), dpr, opacity: opacity);
    }
  }

  @override
  bool shouldRepaint(_MiniPiecePainter old) => old.kind != kind || old.opacity != opacity || old.dpr != dpr;
}

/// Small rim button that fires once on press and, if [repeat], keeps firing while held
/// (170 ms delay, then every 55 ms) — like a key with auto-repeat.
class _RepeatButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onFire;
  final bool repeat;
  final bool accent;
  final bool enabled;
  const _RepeatButton({required this.icon, required this.onFire, this.repeat = true, this.accent = false, this.enabled = true});

  @override
  State<_RepeatButton> createState() => _RepeatButtonState();
}

class _RepeatButtonState extends State<_RepeatButton> {
  Timer? _timer;
  bool _down = false;

  void _start() {
    if (!widget.enabled) return;
    setState(() => _down = true);
    widget.onFire();
    if (!widget.repeat) return;
    _timer = Timer(const Duration(milliseconds: 170), () {
      _timer = Timer.periodic(const Duration(milliseconds: 55), (_) => widget.onFire());
    });
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    if (_down) setState(() => _down = false);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.enabled;
    return Listener(
      onPointerDown: (_) => _start(),
      onPointerUp: (_) => _stop(),
      onPointerCancel: (_) => _stop(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: widget.accent && on ? Lux.goldGradient : null,
          color: widget.accent && on ? null : (_down ? const Color(0xFF3A2C12) : const Color(0xFF1E1710)),
          border: Border.all(color: _down ? Lux.gold : Lux.line),
          boxShadow: _down ? [BoxShadow(color: Lux.gold.withValues(alpha: 0.35), blurRadius: 10)] : null,
        ),
        child: Icon(widget.icon,
            size: 26,
            color: !on
                ? Lux.muted.withValues(alpha: 0.4)
                : widget.accent
                    ? const Color(0xFF1A1206)
                    : Lux.goldLight),
      ),
    );
  }
}

/// HUD value whose numbers roll to the new value (easeOutCubic) and glint when a count goes up.
/// Clock-like values (with ':') and values whose shape changes simply switch.
class _Roll extends StatefulWidget {
  final String value;
  final TextStyle style;
  const _Roll(this.value, {super.key, required this.style});

  @override
  State<_Roll> createState() => _RollState();
}

class _RollState extends State<_Roll> with SingleTickerProviderStateMixin {
  static final _num = RegExp(r'\d+');
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 420), value: 1);
  List<int> _from = const [], _to = const [];
  bool _up = false;

  static List<int> _nums(String s) => [for (final m in _num.allMatches(s)) int.tryParse(m[0]!) ?? 0];

  @override
  void initState() {
    super.initState();
    _from = _to = _nums(widget.value);
  }

  @override
  void didUpdateWidget(_Roll old) {
    super.didUpdateWidget(old);
    if (old.value == widget.value) return;
    final next = _nums(widget.value);
    final sameShape = !widget.value.contains(':') &&
        next.length == _to.length &&
        widget.value.replaceAll(_num, '#') == old.value.replaceAll(_num, '#');
    if (!sameShape) {
      _from = _to = next;
      _up = false;
      _c.value = 1;
      return;
    }
    final now = _current();
    _up = false;
    for (var i = 0; i < next.length; i++) {
      if (next[i] > now[i]) _up = true;
    }
    _from = now;
    _to = next;
    _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  List<int> _current() {
    final e = Curves.easeOutCubic.transform(_c.value);
    return [for (var i = 0; i < _to.length; i++) (_from[i] + (_to[i] - _from[i]) * e).round()];
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        var text = widget.value;
        if (_c.isAnimating) {
          final cur = _current();
          var i = 0;
          text = widget.value.replaceAllMapped(_num, (m) => i < cur.length ? '${cur[i++]}' : m[0]!);
        }
        final g = _up && _c.isAnimating ? math.sin(math.pi * _c.value) : 0.0;
        return Transform.scale(
          scale: 1 + 0.08 * g,
          child: Text(
            text,
            style: widget.style.copyWith(
              color: Color.lerp(widget.style.color, Colors.white, 0.55 * g),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        );
      },
    );
  }
}
