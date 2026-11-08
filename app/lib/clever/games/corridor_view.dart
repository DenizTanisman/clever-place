import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// Duvar Yarışı board against the AI.
///
/// Layout: opponent strip (rank medallion, "düşünüyor…", its shortest path and its obsidian walls) ·
/// the lacquered 9×9 board with recessed gold-rimmed squares and dark grooves · your strip (turn,
/// your path, the gold wall tray with its orientation toggle) · undo / "yolum" / hint.
///
/// Input (raw pointer events, so a second finger can rotate a wall mid-drag):
/// - your pawn: drag it (primary) or tap it, then tap a glowing target; targets can also be tapped
///   directly;
/// - walls: drag a bar out of your tray; it floats above the finger and snaps to the nearest groove
///   slot — green-gold ghost when legal, bordeaux when not. Rotate with the round button, a tap on the
///   tray, or a second finger tap while dragging. Drop places it with a thunk.
///
/// Motion: every move is replayed from `last_move`: pawn steps glide, jumps arc; AI walls slide in
/// from its tray and slam into the groove. A gold sweep runs along the goal row on a win. A Ticker
/// runs only while something moves; the AI is asked for its move (off the UI isolate) after a
/// human-like pause.
Widget corridorView(BuildContext context, GameSession s) => _CorridorBoard(session: s);

const _rose = Color(0xFFFF7896);
const _garnet = Color(0xFFA51D40);
const _jade = Color(0xFFD2EC8E);
const _grooveRatio = 0.26;

(int, int) _rc(Object? v) {
  final l = v as List;
  return ((l[0] as num).toInt(), (l[1] as num).toInt());
}

Offset _g((int, int) rc) => Offset(rc.$2.toDouble(), rc.$1.toDouble());

/// Board geometry: squares, grooves and groove crossings ↔ pixels.
class _Geo {
  final Rect board;
  final double pad, cs, gw;
  _Geo._(this.board, this.pad, this.cs, this.gw);

  factory _Geo(Rect board) {
    final pad = board.width * 0.045;
    final cs = (board.width - 2 * pad) / (9 + 8 * _grooveRatio);
    return _Geo._(board, pad, cs, cs * _grooveRatio);
  }

  double get step => cs + gw;
  Offset get origin => board.topLeft + Offset(pad, pad);

  /// Centre of the square at grid position g (x = column, y = row; fractional allowed).
  Offset cell(Offset g) => origin + Offset(g.dx * step + cs / 2, g.dy * step + cs / 2);

  Rect cellRect(int r, int c) => Rect.fromLTWH(origin.dx + c * step, origin.dy + r * step, cs, cs);

  /// Groove crossing below-right of square (r, c), r, c in 0..7.
  Offset crossing(int r, int c) => origin + Offset((c + 1) * step - gw / 2, (r + 1) * step - gw / 2);

  Size wallSize(bool h) {
    final len = 2 * cs + gw - cs * 0.08;
    final th = gw * 0.92;
    return h ? Size(len, th) : Size(th, len);
  }

  Rect wallRect(int r, int c, bool h) {
    final sz = wallSize(h);
    return Rect.fromCenter(center: crossing(r, c), width: sz.width, height: sz.height);
  }

  (int, int)? cellAt(Offset p) {
    final x = (p.dx - origin.dx + gw / 2) / step;
    final y = (p.dy - origin.dy + gw / 2) / step;
    if (x < 0 || y < 0) return null;
    final c = x.floor(), r = y.floor();
    if (r > 8 || c > 8) return null;
    return (r, c);
  }

  /// Nearest groove crossing to p, or null when p is too far from the board.
  (int, int)? anchorNear(Offset p) {
    if (!board.inflate(cs * 0.4).contains(p)) return null;
    final c = ((p.dx - origin.dx + gw / 2) / step - 1).round().clamp(0, 7);
    final r = ((p.dy - origin.dy + gw / 2) / step - 1).round().clamp(0, 7);
    return (r, c);
  }

  @override
  bool operator ==(Object other) => other is _Geo && other.board == board;
  @override
  int get hashCode => board.hashCode;
}

class _Wall {
  final int r, c;
  final bool h, you;
  const _Wall(this.r, this.c, this.h, this.you);
  bool same(_Wall o) => o.r == r && o.c == c && o.h == h;
}

/// A pawn move being replayed (grid coordinates).
class _PawnAnim {
  final bool you, jump;
  final Offset from, to;
  final double start, dur;
  _PawnAnim(this.you, this.jump, this.from, this.to, this.start, this.dur);
  double u(double now) => ((now - start) / dur).clamp(0.0, 1.0);
  bool done(double now) => now >= start + dur;
  Offset at(double now) => Offset.lerp(from, to, const Cubic(0.4, 0.0, 0.2, 1.0).transform(u(now)))!;
  double lift(double now) => math.sin(math.pi * u(now)) * (jump ? 1.0 : 0.45);
}

/// The AI's wall flying in from its tray.
class _WallAnim {
  final _Wall w;
  final Offset fromPx;
  final double start, dur;
  _WallAnim(this.w, this.fromPx, this.start, this.dur);
  double u(double now) => ((now - start) / dur).clamp(0.0, 1.0);
  bool done(double now) => now >= start + dur;
}

class _Slam {
  final _Wall w;
  final double at;
  _Slam(this.w, this.at);
}

class _Landing {
  final bool you;
  final double at, strength;
  _Landing(this.you, this.at, this.strength);
}

/// A dropped piece flying back where it came from (pixels).
class _Return {
  final bool wall, h;
  final Offset from, to;
  final double at;
  _Return(this.wall, this.h, this.from, this.to, this.at);
  static const dur = 0.26;
}

class _CorridorBoard extends StatefulWidget {
  final GameSession session;
  const _CorridorBoard({required this.session});

  @override
  State<_CorridorBoard> createState() => _CorridorBoardState();
}

class _CorridorBoardState extends State<_CorridorBoard> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) => _onTick());
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;

  GameSession get s => widget.session;

  _Geo? _geo;
  Rect _trayRect = Rect.zero, _rotRect = Rect.zero;
  Offset _aiTray = Offset.zero;

  int _seenPly = -1;
  String _boardSig = '';
  _PawnAnim? _pawnAnim;
  _WallAnim? _wallAnim;
  final List<_Slam> _slams = [];
  final List<_Landing> _landings = [];
  _Return? _return;
  Offset? _pendingDrop; // pixel position a dragged pawn was released at

  // Orientation of the wall in hand (true = horizontal) and its rotation animation.
  bool _h = true;
  double _rotAt = -10;

  // Pointer tracking.
  int? _primary;
  Offset _downPos = Offset.zero;
  String? _downOn; // 'pawn' | 'tray' | 'rot' | 'board'
  bool _dragging = false;

  // Pawn drag / selection.
  bool _sel = false;
  bool _pawnDrag = false;
  Offset _dragPos = Offset.zero, _grab = Offset.zero;
  (int, int)? _hover;

  // Wall drag.
  bool _wallDrag = false;
  Offset _wallPos = Offset.zero; // centre of the floating wall
  (int, int)? _anchor;

  double _shakeAt = -10;
  bool _showPath = false;

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
  void didUpdateWidget(covariant _CorridorBoard old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      old.session.removeListener(_onSession);
      widget.session.addListener(_onSession);
      _aiTimer?.cancel();
      _aiTimer = null;
      _aiInFlight = false;
      _clearAnims();
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

  void _clearAnims() {
    _pawnAnim = null;
    _wallAnim = null;
    _slams.clear();
    _landings.clear();
    _return = null;
    _sel = false;
    _pawnDrag = false;
    _wallDrag = false;
    _primary = null;
    _dragging = false;
  }

  String _sig() => '${s.state['pawns']}|${(s.state['walls'] as List?)?.length}';

  void _kick() {
    if (!_ticker.isActive) _ticker.start();
  }

  bool _busy(double now) =>
      _pawnAnim != null ||
      _wallAnim != null ||
      _return != null ||
      _slams.isNotEmpty ||
      _landings.isNotEmpty ||
      _pawnDrag ||
      _wallDrag ||
      _sel ||
      _showPath ||
      s.state['hint'] is Map ||
      now - _shakeAt < 0.5 ||
      now - _rotAt < 0.3 ||
      (_endAt >= 0 && now - _endAt < 2.2);

  bool get _yourTurn => !s.finished && s.state['turn'] == 'you';
  bool get _animating => _pawnAnim != null || _wallAnim != null;
  bool get _canInput => _yourTurn && !_animating && !_aiInFlight && _aiTimer == null && !_hintBusy;

  // ------------------------------------------------------------------------------------------
  // State accessors

  (int, int) _pawn(bool you) => _rc((s.state['pawns'] as Map)[you ? 'you' : 'ai']);

  List<_Wall> _walls() => [
        for (final w in (s.state['walls'] as List? ?? const []))
          _Wall((w['r'] as num).toInt(), (w['c'] as num).toInt(), w['o'] == 'h', w['who'] == 'you'),
      ];

  int _left(bool you) => (((s.state['walls_left'] as Map?)?[you ? 'you' : 'ai']) as num?)?.toInt() ?? 0;

  List<(int, int)> _targets() => [for (final t in (s.state['targets'] as List? ?? const [])) _rc(t)];

  bool _isTarget((int, int) rc) => _targets().contains(rc);

  bool _slotLegal((int, int) a, bool h) {
    final ws = s.state['wall_slots'];
    if (ws is! Map) return false;
    final str = ws[h ? 'h' : 'v'] as String? ?? '';
    final i = a.$1 * 8 + a.$2;
    return i < str.length && str[i] == '1';
  }

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
      // Undo or restart: show the new position at once.
      _seenPly = math.max(_seenPly, ply);
      _clearAnims();
      _endAt = -1;
    }
    _boardSig = sig;
    _maybeScheduleAi();
    if (mounted) setState(() {});
  }

  void _startMove(Map lm) {
    final you = lm['who'] == 'you';
    final now = _now;
    _sel = false;
    if (lm['kind'] == 'wall') {
      final l = lm['wall'] as List;
      final w = _Wall((l[0] as num).toInt(), (l[1] as num).toInt(), l[2] == 'h', you);
      if (you) {
        _slam(w, now);
      } else {
        _wallAnim = _WallAnim(w, _aiTray, now, 0.55);
      }
    } else {
      final from = _g(_rc(lm['from'])), to = _g(_rc(lm['to']));
      final jump = lm['jump'] == true;
      final drop = _pendingDrop;
      _pendingDrop = null;
      final geo = _geo;
      if (you && drop != null && geo != null) {
        // Settle from where the finger let go.
        final dg = Offset((drop.dx - geo.origin.dx - geo.cs / 2) / geo.step, (drop.dy - geo.origin.dy - geo.cs / 2) / geo.step);
        final d = (dg - to).distance;
        _pawnAnim = _PawnAnim(true, false, dg, to, now, (0.1 + d * 0.12).clamp(0.12, 0.26));
      } else {
        _pawnAnim = _PawnAnim(you, jump, from, to, now, jump ? 0.5 : 0.32);
      }
    }
    _kick();
  }

  void _slam(_Wall w, double at) {
    _slams.add(_Slam(w, at));
    HapticFeedback.heavyImpact();
  }

  void _onTick() {
    final now = _now;
    final pa = _pawnAnim;
    if (pa != null && pa.done(now)) {
      _pawnAnim = null;
      _landings.add(_Landing(pa.you, now, pa.jump ? 1.0 : 0.6));
      HapticFeedback.selectionClick();
      _afterMove(now);
    }
    final wa = _wallAnim;
    if (wa != null && wa.done(now)) {
      _wallAnim = null;
      _slam(wa.w, now);
      _afterMove(now);
    }
    final r = _return;
    if (r != null && now - r.at >= _Return.dur) _return = null;
    _slams.removeWhere((x) => now - x.at > 0.55);
    _landings.removeWhere((l) => now - l.at > 0.5);
    if (!_busy(now)) _ticker.stop();
    if (mounted) setState(() {});
  }

  void _afterMove(double now) {
    if (s.finished && _endAt < 0) {
      _endAt = now + 0.15;
      Future.delayed(const Duration(milliseconds: 150), () {
        if (!mounted) return;
        if (s.status == 'won') {
          HapticFeedback.heavyImpact();
        } else {
          HapticFeedback.mediumImpact();
        }
      });
    }
    _maybeScheduleAi();
  }

  void _maybeScheduleAi() {
    if (!mounted || s.finished || s.state['ai_pending'] != true) return;
    if (_aiTimer != null || _aiInFlight || _animating) return;
    final cx = (s.state['complexity'] as num?)?.toDouble() ?? 0.3;
    final jitter = ((_seenPly * 7919 + 13) % 97) / 97.0;
    final ms = (450 + 450 * cx + 200 * jitter).clamp(450, 1100).round();
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

  void _rotate() {
    HapticFeedback.selectionClick();
    _h = !_h;
    _rotAt = _now;
    if (_wallDrag) _updateWall(_wallPos);
    _kick();
    setState(() {});
  }

  bool _onPawn(Offset p) {
    final geo = _geo;
    if (geo == null) return false;
    final c = geo.cell(_g(_pawn(true)));
    // The piece stands up: accept its base square and its head above it.
    return Rect.fromCenter(center: c - Offset(0, geo.cs * 0.15), width: geo.cs * 1.15, height: geo.cs * 1.35).contains(p);
  }

  void _down(PointerDownEvent e) {
    final p = e.localPosition;
    if (_primary != null) {
      // A second finger while carrying a wall turns it.
      if (_wallDrag) _rotate();
      return;
    }
    _primary = e.pointer;
    _downPos = p;
    _dragging = false;
    if (_rotRect.contains(p)) {
      _downOn = 'rot';
    } else if (_trayRect.inflate(8).contains(p)) {
      _downOn = 'tray';
    } else if (_canInput && _onPawn(p)) {
      _downOn = 'pawn';
    } else {
      _downOn = 'board';
    }
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _primary) return;
    final p = e.localPosition;
    if (!_dragging) {
      if ((p - _downPos).distance < kTouchSlop * 0.6) return;
      _dragging = true;
      if (_downOn == 'pawn' && _canInput) {
        _startPawnDrag(_downPos);
      } else if (_downOn == 'tray' && _canInput && _left(true) > 0) {
        _startWallDrag();
      }
    }
    if (_pawnDrag) {
      _updatePawn(p);
    } else if (_wallDrag) {
      _updateWall(_floating(p));
    }
  }

  void _up(PointerUpEvent e) {
    if (e.pointer != _primary) return;
    _primary = null;
    if (_pawnDrag) {
      _dropPawn();
    } else if (_wallDrag) {
      _dropWall();
    } else if (!_dragging) {
      _tap(_downOn, e.localPosition);
    }
    _dragging = false;
  }

  void _cancel(PointerCancelEvent e) {
    if (e.pointer != _primary) return;
    _primary = null;
    _dragging = false;
    if (_pawnDrag) {
      _hover = null;
      _dropPawn();
    } else if (_wallDrag) {
      _anchor = null;
      _dropWall();
    }
  }

  /// Where the carried wall floats for a finger at p: above the finger so it stays visible.
  Offset _floating(Offset p) => p - Offset(0, (_geo?.cs ?? 30) * 1.15);

  void _startPawnDrag(Offset p) {
    final geo = _geo!;
    HapticFeedback.selectionClick();
    _pawnDrag = true;
    _sel = true;
    final c = geo.cell(_g(_pawn(true)));
    _dragPos = c;
    _grab = p - c;
    _hover = _pawn(true);
    _kick();
    setState(() {});
  }

  void _updatePawn(Offset p) {
    final geo = _geo;
    if (geo == null) return;
    final pos = p - _grab;
    final h = geo.cellAt(pos);
    if (h != _hover && h != null && h != _pawn(true)) HapticFeedback.selectionClick();
    setState(() {
      _dragPos = pos;
      _hover = h;
    });
  }

  void _dropPawn() {
    final to = _hover;
    final here = _pawn(true);
    _pawnDrag = false;
    _hover = null;
    if (to != null && to != here && _isTarget(to) && _canInput) {
      _pendingDrop = _dragPos;
      _sel = false;
      s.act({'to': [to.$1, to.$2]});
    } else {
      final geo = _geo;
      if (geo != null) _return = _Return(false, true, _dragPos, geo.cell(_g(here)), _now);
      if (to != null && to != here && _canInput) {
        s.act({'to': [to.$1, to.$2]}); // rejected: the core explains why (toast)
        _shake();
      }
    }
    _kick();
    if (mounted) setState(() {});
  }

  void _startWallDrag() {
    HapticFeedback.selectionClick();
    _wallDrag = true;
    _sel = false;
    _updateWall(_floating(_downPos));
    _kick();
  }

  void _updateWall(Offset centre) {
    final geo = _geo;
    if (geo == null) return;
    final a = geo.anchorNear(centre);
    if (a != _anchor && a != null) HapticFeedback.selectionClick();
    setState(() {
      _wallPos = centre;
      _anchor = a;
    });
  }

  void _dropWall() {
    final a = _anchor;
    final geo = _geo;
    _wallDrag = false;
    _anchor = null;
    if (a != null && geo != null && _canInput) {
      if (_slotLegal(a, _h)) {
        s.act({'wall': [a.$1, a.$2, _h ? 'h' : 'v']});
      } else {
        s.act({'wall': [a.$1, a.$2, _h ? 'h' : 'v']}); // rejected: toast explains
        HapticFeedback.mediumImpact();
        _return = _Return(true, _h, geo.wallRect(a.$1, a.$2, _h).center, _trayRect.center, _now);
      }
    } else {
      _return = _Return(true, _h, _wallPos, _trayRect.center, _now);
    }
    _kick();
    if (mounted) setState(() {});
  }

  void _shake() {
    HapticFeedback.mediumImpact();
    _shakeAt = _now;
    _kick();
  }

  void _tap(String? on, Offset p) {
    if (on == 'rot' || on == 'tray') {
      _rotate();
      return;
    }
    final geo = _geo;
    if (geo == null || !_canInput) return;
    if (on == 'pawn') {
      HapticFeedback.selectionClick();
      setState(() => _sel = !_sel);
      _kick();
      return;
    }
    final rc = geo.cellAt(p);
    if (rc == null) {
      setState(() => _sel = false);
      return;
    }
    if (_isTarget(rc)) {
      setState(() => _sel = false);
      s.act({'to': [rc.$1, rc.$2]});
    } else if (_sel) {
      s.act({'to': [rc.$1, rc.$2]});
      _shake();
      setState(() {});
    }
  }

  Future<void> _askHint() async {
    if (!_canInput) return;
    setState(() {
      _hintBusy = true;
      _sel = false;
    });
    await s.actAsync({'hint': true});
    if (!mounted) return;
    setState(() => _hintBusy = false);
    _kick();
  }

  // ------------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final st = s.state;
    if (st['pawns'] is! Map) return const SizedBox();
    final path = st['path'] as Map? ?? const {};
    final rank = (st['title'] as String?) ?? '';
    final thinking = _aiTimer != null || _aiInFlight;
    final playing = !s.finished;
    final aiPath = (path['ai'] as num?)?.toInt() ?? 0;
    final myPath = (path['you'] as num?)?.toInt() ?? 0;

    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(builder: (context, box) {
            final w = box.maxWidth, h = box.maxHeight;
            const topH = 62.0, botH = 82.0, gap = 8.0;
            final size = math.min(w - 8, h - topH - botH - 2 * gap).clamp(120.0, 2000.0);
            final y0 = ((h - (topH + botH + 2 * gap + size)) / 2).clamp(0.0, 400.0);
            final left = (w - size) / 2;
            final boardRect = Rect.fromLTWH(left, y0 + topH + gap, size, size);
            final geo = _Geo(boardRect);
            _geo = geo;
            final stripLeft = math.max(8.0, left + size * 0.02);
            final stripW = math.min(w - 16, size * 0.96);
            final botTop = boardRect.bottom + gap;
            // AI tray (painted): right part of the top strip.
            _aiTray = Offset(stripLeft + stripW - 16 - 9 * 9.0 - 4, y0 + topH / 2);
            // Your tray (painted) and the rotate button.
            const rotD = 46.0;
            _rotRect = Rect.fromCenter(center: Offset(stripLeft + stripW - 12 - rotD / 2, botTop + botH / 2), width: rotD, height: rotD);
            final trayW = math.min(150.0, _rotRect.left - 10 - (stripLeft + stripW * 0.36));
            _trayRect = Rect.fromLTWH(_rotRect.left - 10 - trayW, botTop + 12, trayW, botH - 24);

            final now = _now;
            if (_busy(now)) _kick();

            return Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _down,
              onPointerMove: _move,
              onPointerUp: _up,
              onPointerCancel: _cancel,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // Opponent strip.
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
                                    : Text('Yolu $aiPath adım', style: Lux.ui(12, color: Lux.muted, spacing: 0.8)),
                              ],
                            ),
                          ),
                          SizedBox(
                            width: 9 * 9.0 + 34,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text('DUVAR  ${_left(false)}', style: Lux.ui(10, color: Lux.muted, spacing: 1.4)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Your strip.
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
                          SizedBox(
                            width: stripW * 0.34,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                      !playing
                                          ? 'Oyun bitti'
                                          : _yourTurn
                                              ? 'Sıra sende'
                                              : 'Rakip oynuyor',
                                      style: Lux.ui(14,
                                          color: _yourTurn ? Lux.goldLight : Lux.muted, weight: FontWeight.w600)),
                                ),
                                const SizedBox(height: 2),
                                Text('Yolun $myPath adım', style: Lux.ui(12, color: Lux.muted, spacing: 0.8)),
                                Text('DUVAR  ${_left(true)}', style: Lux.ui(10, color: Lux.muted, spacing: 1.4)),
                              ],
                            ),
                          ),
                          const Spacer(),
                        ],
                      ),
                    ),
                  ),
                  // Rotate button (input handled by the Listener).
                  Positioned.fromRect(
                    rect: _rotRect,
                    child: IgnorePointer(child: _RotateButton(horizontal: _h, enabled: _left(true) > 0 && playing)),
                  ),
                  // Static board.
                  Positioned.fromRect(
                    rect: boardRect,
                    child: RepaintBoundary(child: CustomPaint(painter: _BoardPainter(boardRect.size))),
                  ),
                  // Pieces, walls, highlights, trays and effects.
                  Positioned.fill(
                    child: IgnorePointer(child: CustomPaint(painter: _DynPainter(this, geo, now))),
                  ),
                ],
              ),
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
                          setState(() => _sel = false);
                          s.act({'undo': true});
                        }
                      : null),
              const SizedBox(width: 18),
              _PathToggle(on: _showPath, onTap: () => setState(() => _showPath = !_showPath)),
              const SizedBox(width: 18),
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

class _RotateButton extends StatelessWidget {
  final bool horizontal, enabled;
  const _RotateButton({required this.horizontal, required this.enabled});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Lux.card,
          border: Border.all(color: Lux.gold.withValues(alpha: 0.65)),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 8, offset: const Offset(0, 3))],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            const Icon(Icons.rotate_90_degrees_ccw_rounded, size: 34, color: Color(0x55F0D69A)),
            AnimatedRotation(
              turns: horizontal ? 0 : 0.25,
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutBack,
              child: Container(
                width: 22,
                height: 6,
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(3), gradient: Lux.foil),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Yolum" pill: shows / hides your shortest path on the board.
class _PathToggle extends StatelessWidget {
  final bool on;
  final VoidCallback onTap;
  const _PathToggle({required this.on, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(30),
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(30),
            color: on ? const Color(0x33D4A94E) : Lux.card,
            border: Border.all(color: Lux.gold.withValues(alpha: on ? 0.9 : 0.5)),
            boxShadow: [
              BoxShadow(
                  color: on ? Lux.gold.withValues(alpha: 0.25) : Colors.black.withValues(alpha: 0.4),
                  blurRadius: on ? 12 : 6,
                  offset: const Offset(0, 3)),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.more_vert_rounded, size: 18, color: on ? Lux.goldLight : Lux.muted),
              const SizedBox(width: 4),
              Text('yolum', style: Lux.ui(14, color: on ? Lux.goldLight : Lux.muted, weight: FontWeight.w600, spacing: 0.8)),
            ],
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
    final glyph = widget.rank.isEmpty ? '∞' : widget.rank.substring(0, 1);
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

/// "düşünüyor…" with three dots that rise in turn.
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

/// Lacquered panel, dark grooves, recessed gold-rimmed squares, goal-row inlays, crossing studs.
class _BoardPainter extends CustomPainter {
  final Size size;
  _BoardPainter(this.size);

  @override
  void paint(Canvas canvas, Size sz) {
    final rect = Offset.zero & sz;
    final geo = _Geo(rect);
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(sz.width * 0.045));
    canvas.drawRRect(
      rr.shift(const Offset(0, 9)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.65)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
    );
    // Black lacquer with a warm depth.
    canvas.drawRRect(
      rr,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.3, -0.4),
          radius: 1.15,
          colors: [Color(0xFF1C1712), Color(0xFF0B0907), Color(0xFF030202)],
          stops: [0, 0.55, 1],
        ).createShader(rect),
    );
    canvas.save();
    canvas.clipRRect(rr);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white.withValues(alpha: 0.08), Colors.white.withValues(alpha: 0.0), Colors.white.withValues(alpha: 0.03)],
          stops: const [0, 0.42, 1],
        ).createShader(rect),
    );
    canvas.restore();
    canvas.drawRRect(
      rr.deflate(1),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..shader = Lux.foil.createShader(rect),
    );
    canvas.drawRRect(
      rr.deflate(geo.pad * 0.45),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = Lux.gold.withValues(alpha: 0.2),
    );

    // Groove bed: one dark recessed field under all squares.
    final field = Rect.fromLTWH(geo.origin.dx, geo.origin.dy, 9 * geo.cs + 8 * geo.gw, 9 * geo.cs + 8 * geo.gw);
    final fieldR = RRect.fromRectAndRadius(field.inflate(geo.gw * 0.35), Radius.circular(geo.cs * 0.12));
    canvas.drawRRect(fieldR, Paint()..color = const Color(0xFF010101));
    canvas.drawRRect(
        fieldR,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Lux.gold.withValues(alpha: 0.25));

    // Goal inlays: your goal (top) in gold, the AI's goal (bottom) in rose.
    void goalBar(double y, Color c) {
      final r = Rect.fromLTWH(field.left + geo.cs * 0.2, y - 1.6, field.width - geo.cs * 0.4, 3.2);
      canvas.drawRRect(
          RRect.fromRectAndRadius(r.inflate(3), const Radius.circular(4)),
          Paint()
            ..color = c.withValues(alpha: 0.35)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(2)), Paint()..color = c.withValues(alpha: 0.85));
    }

    goalBar(field.top - geo.pad * 0.55, Lux.goldLight);
    goalBar(field.bottom + geo.pad * 0.55, _rose);

    final cs = geo.cs;
    final rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.8, cs * 0.025)
      ..color = Lux.gold.withValues(alpha: 0.5);
    for (var r = 0; r < 9; r++) {
      for (var c = 0; c < 9; c++) {
        final cell = geo.cellRect(r, c);
        final rr2 = RRect.fromRectAndRadius(cell, Radius.circular(cs * 0.12));
        final goal = r == 0 || r == 8;
        // Recessed square: darker towards the top-left (shadowed lip), a lit lower-right edge.
        canvas.drawRRect(
            rr2,
            Paint()
              ..shader = LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: goal
                    ? (r == 0
                        ? const [Color(0xFF0E0B07), Color(0xFF2A2214), Color(0xFF3A2F1A)]
                        : const [Color(0xFF0E0709), Color(0xFF24131A), Color(0xFF331A22)])
                    : const [Color(0xFF0A0806), Color(0xFF1D1813), Color(0xFF29221A)],
                stops: const [0, 0.55, 1],
              ).createShader(cell));
        canvas.save();
        canvas.clipRRect(rr2);
        canvas.drawRRect(
            rr2.shift(Offset(cs * 0.06, cs * 0.06)),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = cs * 0.1
              ..color = Colors.black.withValues(alpha: 0.55)
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, cs * 0.05));
        canvas.restore();
        canvas.drawRRect(rr2, rim);
        // Fine highlight on the lit lip.
        canvas.drawLine(
            Offset(cell.left + cs * 0.18, cell.bottom - 0.6),
            Offset(cell.right - cs * 0.14, cell.bottom - 0.6),
            Paint()
              ..strokeWidth = 0.8
              ..color = Lux.goldLight.withValues(alpha: 0.25));
      }
    }
    // Studs at the groove crossings (where walls are anchored).
    for (var r = 0; r < 8; r++) {
      for (var c = 0; c < 8; c++) {
        final p = geo.crossing(r, c);
        canvas.drawCircle(p, geo.gw * 0.16, Paint()..color = Lux.gold.withValues(alpha: 0.35));
      }
    }
  }

  @override
  bool shouldRepaint(_BoardPainter old) => old.size != size;
}

class _DynPainter extends CustomPainter {
  final _CorridorBoardState st;
  final _Geo geo;
  final double now;
  _DynPainter(this.st, this.geo, this.now);

  double get cs => geo.cs;

  @override
  void paint(Canvas canvas, Size size) {
    final state = st.s.state;
    final pulse = 0.5 + 0.5 * math.sin(now * 5.2);
    final pa = st._pawnAnim;
    final wa = st._wallAnim;
    final canInput = st._canInput;

    _trays(canvas);

    // Last move: a faint trace of the pawn's way, or a soft glow under the new wall.
    final lm = state['last_move'];
    if (pa == null && wa == null && lm is Map && lm['kind'] == 'move') {
      final you = lm['who'] == 'you';
      final a = geo.cell(_g(_rc(lm['from']))), b = geo.cell(_g(_rc(lm['to'])));
      final col = (you ? Lux.goldLight : _rose).withValues(alpha: 0.35);
      canvas.drawLine(
          a,
          b,
          Paint()
            ..strokeWidth = math.max(1.5, cs * 0.05)
            ..strokeCap = StrokeCap.round
            ..color = col);
      canvas.drawCircle(
          a,
          cs * 0.2,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4
            ..color = col);
    }

    // Your shortest path.
    if (st._showPath && state['my_path'] is List) {
      final pts = [for (final p in state['my_path'] as List) geo.cell(_g(_rc(p)))];
      if (pts.length > 1) {
        final path = Path()..moveTo(pts.first.dx, pts.first.dy);
        for (final p in pts.skip(1)) {
          path.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(
            path,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = cs * 0.08
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.round
              ..color = Lux.goldLight.withValues(alpha: 0.28));
        for (var i = 1; i < pts.length; i++) {
          final k = (now * 2.2 - i * 0.18) % 1.0;
          final glow = 0.55 + 0.45 * math.max(0.0, math.cos(k * 2 * math.pi));
          canvas.drawCircle(pts[i], cs * 0.1, Paint()..color = Lux.goldLight.withValues(alpha: 0.95 * glow));
        }
      }
    }

    // Pawn targets: subtle on your turn, bright when the pawn is held.
    final held = st._sel || st._pawnDrag;
    if (canInput && !st._wallDrag) {
      for (final t in st._targets()) {
        final p = geo.cell(_g(t));
        if (held) {
          canvas.drawCircle(
              p,
              cs * 0.32,
              Paint()
                ..color = Lux.gold.withValues(alpha: 0.18 + 0.12 * pulse)
                ..maskFilter = MaskFilter.blur(BlurStyle.normal, cs * 0.12));
          canvas.drawCircle(
              p,
              cs * 0.26,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.8
                ..color = Lux.goldLight.withValues(alpha: 0.55 + 0.35 * pulse));
          canvas.drawCircle(p, cs * 0.08, Paint()..color = Lux.goldLight.withValues(alpha: 0.9));
        } else {
          canvas.drawCircle(p, cs * 0.075, Paint()..color = Lux.goldLight.withValues(alpha: 0.42));
        }
      }
    }

    // Pawn drag hover: gold when legal, bordeaux when not.
    final hv = st._hover;
    if (st._pawnDrag && hv != null && hv != st._pawn(true)) {
      final ok = st._isTarget(hv);
      final r = geo.cellRect(hv.$1, hv.$2);
      canvas.drawRRect(
          RRect.fromRectAndRadius(r.inflate(2), Radius.circular(cs * 0.16)),
          Paint()
            ..color = (ok ? Lux.gold : Lux.bordeaux).withValues(alpha: 0.4)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, cs * 0.18));
      canvas.drawRRect(
          RRect.fromRectAndRadius(r, Radius.circular(cs * 0.12)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.6
            ..color = ok ? Lux.goldLight : Lux.bordeauxLight);
    }

    // Hint.
    final hint = state['hint'];
    if (hint is Map && pa == null && wa == null) {
      if (hint['kind'] == 'wall' && hint['wall'] is List) {
        final l = hint['wall'] as List;
        final r = geo.wallRect((l[0] as num).toInt(), (l[1] as num).toInt(), l[2] == 'h');
        _ghost(canvas, r, Lux.goldLight, 0.45 + 0.4 * pulse);
      } else if (hint['to'] is List) {
        final p = geo.cell(_g(_rc(hint['to'])));
        canvas.drawCircle(
            p,
            cs * (0.36 + 0.04 * pulse),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.6
              ..color = Lux.gold.withValues(alpha: 0.5 + 0.45 * pulse)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5));
      }
    }

    // Placed walls (the one flying in is drawn later).
    for (final w in st._walls()) {
      if (wa != null && wa.w.same(w)) continue;
      var r = geo.wallRect(w.r, w.c, w.h);
      double glow = 0;
      for (final sl in st._slams) {
        if (!sl.w.same(w)) continue;
        final k = now - sl.at;
        final sc = 1 + 0.12 * math.exp(-k * 14) * math.cos(k * 40).abs();
        r = Rect.fromCenter(center: r.center, width: r.width * sc, height: r.height * sc);
        glow = math.max(0, 1 - k / 0.55);
        _dust(canvas, r, k);
      }
      if (lm is Map && lm['kind'] == 'wall' && wa == null) {
        final l = lm['wall'] as List;
        if (w.r == (l[0] as num).toInt() && w.c == (l[1] as num).toInt() && w.h == (l[2] == 'h')) {
          glow = math.max(glow, 0.3);
        }
      }
      _wall(canvas, r, w.you, glow: glow);
    }

    // Win sweep along the winner's goal row.
    final endT = st._endAt >= 0 ? now - st._endAt : -1.0;
    final status = state['status'];
    if (endT >= 0 && endT < 2.2 && (status == 'won' || status == 'lost')) {
      _sweep(canvas, status == 'won' ? 0 : 8, status == 'won' ? Lux.goldLight : _rose, endT);
    }

    // Pawns (lower rows drawn last: the pieces stand up).
    final you = st._pawn(true), ai = st._pawn(false);
    final drawn = <(bool, Offset, double)>[];
    if (!(pa != null && !pa.you)) drawn.add((false, _g(ai), 0));
    if (!(pa != null && pa.you) && !st._pawnDrag && !(st._return != null && !st._return!.wall)) {
      drawn.add((true, _g(you), 0));
    }
    if (pa != null) drawn.add((pa.you, pa.at(now), pa.lift(now)));
    drawn.sort((a, b) => a.$2.dy.compareTo(b.$2.dy));
    for (final (isYou, g, lift) in drawn) {
      var p = geo.cell(g);
      if (isYou && now - st._shakeAt < 0.45) {
        final k = now - st._shakeAt;
        p += Offset(math.sin(k * 48) * cs * 0.1 * math.exp(-k * 7), 0);
      }
      var sx = 1.0, sy = 1.0;
      for (final l in st._landings) {
        if (l.you != isYou) continue;
        final k = now - l.at;
        final q = 0.16 * l.strength * math.exp(-k * 10) * math.cos(k * 30);
        sx = 1 + q;
        sy = 1 - q;
      }
      var glow = 0.0;
      if (endT >= 0 && endT < 2.2 && ((status == 'won' && isYou) || (status == 'lost' && !isYou))) {
        glow = math.sin(math.pi * (endT / 2.2).clamp(0.0, 1.0));
      }
      final selected = isYou && st._sel && pa == null;
      _pawn(canvas, p, isYou,
          lift: math.max(lift, selected ? 0.25 : 0), glow: math.max(glow, selected ? 0.45 + 0.3 * pulse : 0), sx: sx, sy: sy);
    }

    // Returning piece / wall.
    final ret = st._return;
    if (ret != null) {
      final t = Curves.easeOutBack.transform(((now - ret.at) / _Return.dur).clamp(0.0, 1.0));
      final p = Offset.lerp(ret.from, ret.to, t)!;
      if (ret.wall) {
        final sz = geo.wallSize(ret.h);
        final k = 1 - 0.6 * t;
        _wall(canvas, Rect.fromCenter(center: p, width: sz.width * k, height: sz.height * k), true);
      } else {
        _pawn(canvas, p, true, lift: 0.5 * (1 - t));
      }
    }

    // AI wall flying in from its tray.
    if (wa != null) {
      final u = Curves.easeInOutCubic.transform(wa.u(now));
      final target = geo.wallRect(wa.w.r, wa.w.c, wa.w.h);
      final ctrl = Offset((wa.fromPx.dx + target.center.dx) / 2, math.min(wa.fromPx.dy, target.center.dy) - cs * 0.5);
      final p = Offset.lerp(Offset.lerp(wa.fromPx, ctrl, u)!, Offset.lerp(ctrl, target.center, u)!, u)!;
      final tray = Size(geo.gw * 0.6, cs * 1.0);
      final w = tray.width + (target.width - tray.width) * u;
      final h = tray.height + (target.height - tray.height) * u;
      _wall(canvas, Rect.fromCenter(center: p, width: w, height: h), false, lift: 1 - u, glow: 0.6);
    }

    // Dragged pawn follows the finger.
    if (st._pawnDrag) {
      _pawn(canvas, st._dragPos, true, lift: 1, sx: 1.1, sy: 1.1, glow: 0.55);
    }

    // Carried wall: ghost in the slot (legal / illegal) or floating under the finger.
    if (st._wallDrag) {
      final a = st._anchor;
      if (a != null) {
        final ok = st._slotLegal(a, st._h);
        final r = geo.wallRect(a.$1, a.$2, st._h);
        _ghost(canvas, r, ok ? _jade : Lux.bordeauxLight, ok ? 0.85 : 0.75);
        if (!ok) {
          // A small cross over the illegal slot.
          final c = r.center, d = geo.gw * 0.7;
          final x = Paint()
            ..strokeWidth = 2.2
            ..strokeCap = StrokeCap.round
            ..color = Lux.bordeauxLight;
          canvas.drawLine(c + Offset(-d, -d), c + Offset(d, d), x);
          canvas.drawLine(c + Offset(d, -d), c + Offset(-d, d), x);
        }
      } else {
        final sz = geo.wallSize(st._h);
        _wall(canvas, Rect.fromCenter(center: st._wallPos, width: sz.width, height: sz.height), true, lift: 1, glow: 0.3);
      }
    }
  }

  /// Wall trays: your gold bars (bottom strip, they rotate with the chosen orientation) and the
  /// AI's obsidian bars (top strip).
  void _trays(Canvas canvas) {
    // AI tray: a row of upright obsidian bars.
    final aiLeft = st._left(false);
    for (var i = 0; i < 10; i++) {
      final c = st._aiTray + Offset(i * 9.0, -2);
      final r = Rect.fromCenter(center: c, width: 4.5, height: 20);
      if (i < aiLeft) {
        _wall(canvas, r, false, small: true);
      } else {
        canvas.drawRRect(
            RRect.fromRectAndRadius(r.deflate(1), const Radius.circular(2)),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 0.7
              ..color = Lux.gold.withValues(alpha: 0.18));
      }
    }
    // Your tray: 5 × 2 slots; bars turn to show the orientation in hand.
    final tr = st._trayRect;
    if (tr.width <= 10) return;
    var left = st._left(true);
    if (st._wallDrag || (st._return?.wall ?? false)) left -= 1;
    final k = ((now - st._rotAt) / 0.26).clamp(0.0, 1.0);
    final e = Curves.easeOutBack.transform(k);
    final ang = st._h ? (1 - e) * math.pi / 2 : e * math.pi / 2;
    final colW = tr.width / 5;
    final bar = Size(math.min(colW * 0.8, 24), 5);
    final glowOn = st._canInput && left > 0;
    if (glowOn) {
      canvas.drawRRect(
          RRect.fromRectAndRadius(tr, const Radius.circular(12)),
          Paint()
            ..color = Lux.gold.withValues(alpha: 0.06 + 0.04 * math.sin(now * 2.4))
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
    }
    canvas.drawRRect(
        RRect.fromRectAndRadius(tr, const Radius.circular(12)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8
          ..color = Lux.gold.withValues(alpha: glowOn ? 0.4 : 0.15));
    for (var i = 0; i < 10; i++) {
      final c = Offset(tr.left + colW * (i % 5 + 0.5), tr.top + tr.height * (i < 5 ? 0.3 : 0.7));
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(ang);
      final r = Rect.fromCenter(center: Offset.zero, width: bar.width, height: bar.height);
      if (i < left) {
        _wall(canvas, r, true, small: true);
      } else {
        canvas.drawRRect(
            RRect.fromRectAndRadius(r, const Radius.circular(2)),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 0.7
              ..color = Lux.gold.withValues(alpha: 0.16));
      }
      canvas.restore();
    }
  }

  void _ghost(Canvas canvas, Rect r, Color c, double a) {
    final rr = RRect.fromRectAndRadius(r, Radius.circular(math.min(r.width, r.height) * 0.4));
    canvas.drawRRect(
        rr.inflate(3),
        Paint()
          ..color = c.withValues(alpha: 0.35 * a)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, cs * 0.15));
    canvas.drawRRect(rr, Paint()..color = c.withValues(alpha: 0.45 * a));
    canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = c.withValues(alpha: 0.95 * a));
  }

  void _dust(Canvas canvas, Rect r, double k) {
    final t = (k / 0.55).clamp(0.0, 1.0);
    final e = Curves.easeOutCubic.transform(t);
    final rr = RRect.fromRectAndRadius(r.inflate(cs * 0.35 * e), Radius.circular(cs * 0.2));
    canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(0.5, 3 * (1 - t))
          ..color = Lux.goldLight.withValues(alpha: 0.7 * (1 - t)));
    final spark = Paint()
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..color = Lux.goldLight.withValues(alpha: 0.9 * (1 - t));
    final horizontal = r.width > r.height;
    for (var i = 0; i < 6; i++) {
      final along = (i ~/ 2 - 1) * 0.42;
      final side = i.isEven ? -1.0 : 1.0;
      final base = horizontal
          ? Offset(r.center.dx + r.width * along, r.center.dy + side * r.height * 0.6)
          : Offset(r.center.dx + side * r.width * 0.6, r.center.dy + r.height * along);
      final dir = horizontal ? Offset(along * 0.4, side) : Offset(side, along * 0.4);
      canvas.drawLine(base + dir * cs * 0.1 * e, base + dir * cs * (0.1 + 0.3 * e), spark);
    }
  }

  void _sweep(Canvas canvas, int row, Color c, double t) {
    final a = geo.cellRect(row, 0), b = geo.cellRect(row, 8);
    final band = Rect.fromLTRB(a.left - geo.gw, a.top - geo.gw, b.right + geo.gw, a.bottom + geo.gw);
    final x = band.left + (band.width + cs * 3) * (t / 1.3).clamp(0.0, 1.0) - cs * 1.5;
    final fade = t < 1.4 ? 1.0 : (1 - (t - 1.4) / 0.8).clamp(0.0, 1.0);
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(band, Radius.circular(cs * 0.2)));
    canvas.drawRect(
        band,
        Paint()
          ..shader = LinearGradient(colors: [
            c.withValues(alpha: 0),
            c.withValues(alpha: 0.55 * fade),
            Colors.white.withValues(alpha: 0.65 * fade),
            c.withValues(alpha: 0.55 * fade),
            c.withValues(alpha: 0),
          ], stops: const [0, 0.35, 0.5, 0.65, 1]).createShader(Rect.fromLTWH(x - cs * 1.5, band.top, cs * 3, band.height)));
    canvas.drawRect(band, Paint()..color = c.withValues(alpha: 0.12 * fade * math.min(1, t * 2)));
    canvas.restore();
    canvas.drawRRect(
        RRect.fromRectAndRadius(band, Radius.circular(cs * 0.2)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = c.withValues(alpha: 0.8 * fade * math.min(1, t * 3)));
  }

  /// A wall bar: gold leaf (yours) or obsidian with a garnet edge (the AI's).
  void _wall(Canvas canvas, Rect r, bool gold, {double glow = 0, double lift = 0, bool small = false}) {
    final horizontal = r.width >= r.height;
    final th = math.min(r.width, r.height);
    final rr = RRect.fromRectAndRadius(r, Radius.circular(th * 0.38));
    if (!small) {
      canvas.drawRRect(
          rr.shift(Offset(th * 0.15, th * (0.35 + 1.2 * lift))),
          Paint()
            ..color = Colors.black.withValues(alpha: 0.6 - 0.2 * lift)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, th * (0.35 + 0.8 * lift)));
    }
    if (glow > 0) {
      canvas.drawRRect(
          rr.inflate(th * 0.4),
          Paint()
            ..color = (gold ? Lux.goldLight : _rose).withValues(alpha: 0.4 * glow)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, th * 0.9));
    }
    // Body: metal along the length, a bevel across the thickness.
    if (gold) {
      canvas.drawRRect(
          rr,
          Paint()
            ..shader = LinearGradient(
              begin: horizontal ? Alignment.centerLeft : Alignment.topCenter,
              end: horizontal ? Alignment.centerRight : Alignment.bottomCenter,
              colors: Lux.foil.colors,
              stops: Lux.foil.stops,
            ).createShader(r));
    } else {
      canvas.drawRRect(
          rr,
          Paint()
            ..shader = LinearGradient(
              begin: horizontal ? Alignment.centerLeft : Alignment.topCenter,
              end: horizontal ? Alignment.centerRight : Alignment.bottomCenter,
              colors: const [Color(0xFF151318), Color(0xFF3A3540), Color(0xFF0C0B0E), Color(0xFF2A2630), Color(0xFF09080A)],
              stops: const [0, 0.3, 0.55, 0.8, 1],
            ).createShader(r));
    }
    canvas.drawRRect(
        rr,
        Paint()
          ..shader = LinearGradient(
            begin: horizontal ? Alignment.topCenter : Alignment.centerLeft,
            end: horizontal ? Alignment.bottomCenter : Alignment.centerRight,
            colors: [
              Colors.white.withValues(alpha: gold ? 0.45 : 0.28),
              Colors.white.withValues(alpha: 0.0),
              Colors.black.withValues(alpha: 0.0),
              Colors.black.withValues(alpha: gold ? 0.45 : 0.6),
            ],
            stops: const [0, 0.35, 0.6, 1],
          ).createShader(r));
    canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = small ? 0.6 : 0.9
          ..color = gold ? const Color(0xFF6E4E14).withValues(alpha: 0.9) : _garnet.withValues(alpha: 0.85));
    if (!small) {
      // Specular streak along the top edge.
      final s = horizontal
          ? Rect.fromLTWH(r.left + r.width * 0.12, r.top + th * 0.16, r.width * 0.5, th * 0.16)
          : Rect.fromLTWH(r.left + th * 0.16, r.top + r.height * 0.12, th * 0.16, r.height * 0.5);
      canvas.drawRRect(RRect.fromRectAndRadius(s, Radius.circular(th * 0.1)),
          Paint()..color = Colors.white.withValues(alpha: gold ? 0.6 : 0.35));
    }
  }

  /// A tall glossy piece standing on its square: base, waisted body, gold collar, round head.
  void _pawn(Canvas canvas, Offset p, bool pearl, {double lift = 0, double glow = 0, double sx = 1, double sy = 1}) {
    final u = cs * 1.25;
    // Shadow on the board (grows and softens with lift).
    canvas.drawOval(
      Rect.fromCenter(center: p + Offset(u * 0.06, u * (0.26 + 0.18 * lift)), width: u * 0.7 * (1 + 0.15 * lift), height: u * 0.26),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.6 - 0.2 * lift)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2.5 + 5 * lift),
    );
    canvas.save();
    canvas.translate(p.dx, p.dy - u * 0.22 * lift + u * 0.25);
    canvas.scale(sx, sy);
    // Local coordinates: origin at the middle of the base.
    final light = pearl ? const Color(0xFFFFFFFF) : const Color(0xFFFF9AB0);
    final mid = pearl ? const Color(0xFFEDE4D0) : const Color(0xFFB21E41);
    final dark = pearl ? const Color(0xFF8E846E) : const Color(0xFF3A0410);
    if (glow > 0) {
      canvas.drawOval(
          Rect.fromCenter(center: Offset(0, -u * 0.35), width: u * 0.95, height: u * 1.05),
          Paint()
            ..color = (pearl ? Lux.goldLight : _rose).withValues(alpha: 0.45 * glow)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, u * 0.2));
    }
    final bodyRect = Rect.fromLTRB(-u * 0.3, -u * 0.62, u * 0.3, u * 0.06);
    final bodyShader = LinearGradient(
      colors: [dark, mid, light, mid, dark],
      stops: const [0, 0.22, 0.38, 0.62, 1],
    ).createShader(bodyRect);
    // Base disc.
    final base = Rect.fromCenter(center: Offset.zero, width: u * 0.6, height: u * 0.2);
    canvas.drawOval(base.shift(Offset(0, u * 0.03)), Paint()..color = Color.lerp(dark, Colors.black, 0.4)!);
    canvas.drawOval(base, Paint()..shader = bodyShader);
    canvas.drawOval(
        base,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.9
          ..color = Lux.gold.withValues(alpha: 0.7));
    // Waisted body.
    final body = Path()
      ..moveTo(-u * 0.22, -u * 0.02)
      ..quadraticBezierTo(-u * 0.07, -u * 0.12, -u * 0.075, -u * 0.4)
      ..lineTo(u * 0.075, -u * 0.4)
      ..quadraticBezierTo(u * 0.07, -u * 0.12, u * 0.22, -u * 0.02)
      ..arcToPoint(Offset(-u * 0.22, -u * 0.02), radius: Radius.elliptical(u * 0.22, u * 0.07))
      ..close();
    canvas.drawPath(body, Paint()..shader = bodyShader);
    // Gold collar.
    final collar = Rect.fromCenter(center: Offset(0, -u * 0.41), width: u * 0.26, height: u * 0.075);
    canvas.drawOval(collar, Paint()..shader = Lux.foil.createShader(collar));
    // Head.
    final hc = Offset(0, -u * 0.56);
    final hr = u * 0.155;
    final head = Rect.fromCircle(center: hc, radius: hr);
    canvas.drawCircle(
        hc,
        hr,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.38, -0.45),
            radius: 1.05,
            colors: [light, mid, dark],
            stops: const [0, 0.45, 1],
          ).createShader(head));
    if (pearl) {
      canvas.drawCircle(
          hc,
          hr * 0.7,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = hr * 0.3
            ..shader = const SweepGradient(colors: [
              Color(0x30FFB6D9),
              Color(0x30A8E6FF),
              Color(0x30C8FFD9),
              Color(0x30FFE6A8),
              Color(0x30FFB6D9),
            ]).createShader(head));
    }
    canvas.drawCircle(
        hc,
        hr - 0.4,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8
          ..color = Lux.goldLight.withValues(alpha: 0.4));
    canvas.drawOval(Rect.fromCenter(center: hc + Offset(-hr * 0.32, -hr * 0.42), width: hr * 0.6, height: hr * 0.34),
        Paint()..color = Colors.white.withValues(alpha: pearl ? 0.75 : 0.55));
    // Body sheen.
    canvas.drawLine(Offset(-u * 0.05, -u * 0.36), Offset(-u * 0.11, -u * 0.06),
        Paint()
          ..strokeWidth = u * 0.025
          ..strokeCap = StrokeCap.round
          ..color = Colors.white.withValues(alpha: pearl ? 0.5 : 0.3));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DynPainter old) => true;
}
