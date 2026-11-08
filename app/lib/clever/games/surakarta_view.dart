import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// Surakarta board against the AI.
///
/// Layout: opponent strip (rank medallion, "düşünüyor…", the pearls it has taken) · the lacquered
/// board with the two inlaid circuits (emerald inner, gold outer) and their corner loops · your strip
/// (the garnets you have taken, no-capture counter) · undo / hint.
///
/// Input: drag a pearl (primary) or tap it, then tap a target. While a piece is held, its steps show
/// as gold dots and its captures as marching dashes along the exact circuit path, loops included.
///
/// Motion: every move (yours and the AI's) is replayed from `last_move`: steps glide on a short
/// eased curve; captures race along the path at near-constant speed with a comet trail, hit the
/// victim with a burst, the victim shatters and a copy flies into the captor's tray. Pieces land with
/// a squash. A Ticker runs only while something moves; the AI is asked for its move (off the UI
/// isolate) after a human-like pause once the previous animation has finished.
Widget surakartaView(BuildContext context, GameSession s) => _SurakartaBoard(session: s);

const _emerald = Color(0xFF3FE3A9);
const _emeraldDeep = Color(0xFF0B5E43);
const _loopGold = Color(0xFFE9C163);
const _loopGoldDeep = Color(0xFF6E4E14);
const _garnet = Color(0xFFA51D40);
const _rose = Color(0xFFFF7896);
const _pearlTrail = Color(0xFFFFE7B0);

/// Corner centres in grid units (x = column, y = row): 0 TL, 1 TR, 2 BR, 3 BL.
const _corners = [Offset(0, 0), Offset(5, 0), Offset(5, 5), Offset(0, 5)];

/// Margin around the 5×5-cell grid, in cells: outer loop radius (2) + room for pieces and glow.
const double _margin = 2.55;

Offset _g(int idx) => Offset((idx % 6).toDouble(), (idx ~/ 6).toDouble());
int _idx(Object? v) {
  final l = v as List;
  return (l[0] as num).toInt() * 6 + (l[1] as num).toInt();
}

/// Board geometry: grid point (x = c, y = r) ↔ pixels.
class _Geo {
  final Rect board;
  final double cell;
  final Offset origin;
  _Geo(this.board)
      : cell = board.width / (5 + 2 * _margin),
        origin = board.topLeft + Offset(board.width / (5 + 2 * _margin) * _margin, board.width / (5 + 2 * _margin) * _margin);

  Offset px(Offset g) => origin + g * cell;
  Offset grid(Offset p) => (p - origin) / cell;

  int? pointAt(Offset p, double tol) {
    final g = grid(p);
    final c = g.dx.round(), r = g.dy.round();
    if (r < 0 || r > 5 || c < 0 || c > 5) return null;
    if ((g - Offset(c.toDouble(), r.toDouble())).distance > tol) return null;
    return r * 6 + c;
  }

  @override
  bool operator ==(Object other) => other is _Geo && other.board == board;
  @override
  int get hashCode => board.hashCode;
}

/// A polyline in grid units with arc-length parametrisation.
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

  /// Converts a core path (`[{"pt":[r,c]}, {"arc":{corner,circuit}}, …]`) into points; each loop
  /// becomes a finely sampled 270° arc around its corner.
  static List<Offset> fromPath(List path) {
    final out = <Offset>[];
    Map? arc;
    for (final seg in path) {
      final m = seg as Map;
      if (m['pt'] is List) {
        final l = m['pt'] as List;
        final p = Offset((l[1] as num).toDouble(), (l[0] as num).toDouble());
        if (arc != null && out.isNotEmpty) {
          final k = arc['circuit'] == 'inner' ? 1.0 : 2.0;
          final c = _corners[(arc['corner'] as num).toInt()];
          final a0 = math.atan2(out.last.dy - c.dy, out.last.dx - c.dx);
          final a1 = math.atan2(p.dy - c.dy, p.dx - c.dx);
          var d = a1 - a0;
          while (d > math.pi) {
            d -= 2 * math.pi;
          }
          while (d <= -math.pi) {
            d += 2 * math.pi;
          }
          final sweep = d > 0 ? d - 2 * math.pi : d + 2 * math.pi;
          const n = 36;
          for (var i = 1; i < n; i++) {
            final a = a0 + sweep * i / n;
            out.add(c + Offset(math.cos(a), math.sin(a)) * k);
          }
        }
        out.add(p);
        arc = null;
      } else if (m['arc'] is Map) {
        arc = m['arc'] as Map;
      }
    }
    return out;
  }
}

class _Mv {
  final int to;
  final bool capture;
  final List<Offset>? path;

  /// Corner loops the capture path runs through (0 for a step).
  final int loops;
  _Mv(this.to, this.capture, this.path, this.loops);
}

int _loopCount(Object? path) => path is List ? path.where((s) => s is Map && s['arc'] is Map).length : 0;

/// A move being replayed.
class _MoveAnim {
  final int from, to;
  final bool you, capture;
  final _Poly poly;
  final double start, dur;
  _MoveAnim(this.from, this.to, this.you, this.capture, this.poly, this.start, this.dur);

  double u(double now) => ((now - start) / dur).clamp(0.0, 1.0);
  bool done(double now) => now >= start + dur;

  double dist(double now) {
    final x = u(now);
    // Captures: near-constant speed with a soft start and stop. Steps: lift, glide, settle.
    final e = capture ? 0.78 * x + 0.22 * Curves.easeInOutCubic.transform(x) : const Cubic(0.4, 0.0, 0.2, 1.0).transform(x);
    return e * poly.length;
  }
}

class _Burst {
  final Offset g;
  final double at;
  final bool victimYou;
  _Burst(this.g, this.at, this.victimYou);
}

class _TrayFlight {
  final Offset g;
  final double at;
  final bool victimYou; // a pearl flies to the AI's tray, a garnet to yours
  final int slot;
  _TrayFlight(this.g, this.at, this.victimYou, this.slot);
  static const dur = 0.62;
  bool done(double now) => now >= at + dur;
}

class _Landing {
  final int idx;
  final double at, strength;
  _Landing(this.idx, this.at, this.strength);
}

class _Return {
  final int idx;
  final Offset fromG;
  final double at;
  _Return(this.idx, this.fromG, this.at);
  static const dur = 0.24;
}

class _SurakartaBoard extends StatefulWidget {
  final GameSession session;
  const _SurakartaBoard({required this.session});

  @override
  State<_SurakartaBoard> createState() => _SurakartaBoardState();
}

class _SurakartaBoardState extends State<_SurakartaBoard> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) => _onTick());
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;

  GameSession get s => widget.session;

  _Geo? _geo;
  Offset _aiTray = Offset.zero, _youTray = Offset.zero;

  int _seenPly = -1;
  String _boardSig = '';
  _MoveAnim? _anim;
  final List<_Burst> _bursts = [];
  final List<_TrayFlight> _flights = [];
  final List<_Landing> _landings = [];
  _Return? _return;
  (int, Offset)? _pendingDrop;

  int? _sel;
  int? _dragIdx, _hover;
  Offset _dragPos = Offset.zero, _grab = Offset.zero;
  int? _shakeIdx;
  double _shakeAt = -10;

  Timer? _aiTimer;
  bool _aiInFlight = false, _hintBusy = false;
  double _endAt = -1;

  @override
  void initState() {
    super.initState();
    final lm = s.state['last_move'];
    _seenPly = lm is Map ? (lm['ply'] as num).toInt() : -1;
    _boardSig = _sig();
    s.addListener(_onSession);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeScheduleAi());
  }

  @override
  void didUpdateWidget(covariant _SurakartaBoard old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      old.session.removeListener(_onSession);
      widget.session.addListener(_onSession);
      _aiTimer?.cancel();
      _aiTimer = null;
      _aiInFlight = false;
      _anim = null;
      _bursts.clear();
      _flights.clear();
      _landings.clear();
      _return = null;
      _sel = null;
      _dragIdx = null;
      _endAt = -1;
      final lm = s.state['last_move'];
      _seenPly = lm is Map ? (lm['ply'] as num).toInt() : -1;
      _boardSig = _sig();
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

  void _kick() {
    if (!_ticker.isActive) _ticker.start();
  }

  bool _busy(double now) =>
      _anim != null ||
      _return != null ||
      _bursts.isNotEmpty ||
      _flights.isNotEmpty ||
      _landings.isNotEmpty ||
      _dragIdx != null ||
      _sel != null ||
      s.state['hint'] is Map ||
      now - _shakeAt < 0.5 ||
      (_endAt >= 0 && now - _endAt < 1.6);

  bool get _yourTurn => !s.finished && s.state['turn'] == 'you';
  bool get _canInput => _yourTurn && _anim == null && !_aiInFlight && _aiTimer == null && !_hintBusy;

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
      _anim = null;
      _bursts.clear();
      _flights.clear();
      _landings.clear();
      _return = null;
      _sel = null;
      _endAt = -1;
    }
    _boardSig = sig;
    _maybeScheduleAi();
    if (mounted) setState(() {});
  }

  void _startMove(Map lm) {
    final from = _idx(lm['from']), to = _idx(lm['to']);
    final capture = lm['capture'] == true;
    final you = lm['who'] == 'you';
    var pts = capture && lm['path'] is List ? _Poly.fromPath(lm['path'] as List) : [_g(from), _g(to)];
    final drop = _pendingDrop;
    _pendingDrop = null;
    if (drop != null && drop.$1 == from) {
      // Dropped from the finger: a step settles from there; a capture first slips back to its
      // point, then runs the loop.
      pts = capture ? [drop.$2, ...pts] : [drop.$2, _g(to)];
    }
    final poly = _Poly(pts);
    final double dur = capture
        ? (0.3 + poly.length / 8.5).clamp(0.6, 2.8)
        : (drop != null ? (0.12 + poly.length * 0.12).clamp(0.14, 0.3) : 0.34);
    _anim = _MoveAnim(from, to, you, capture, poly, _now, dur);
    _sel = null;
    _kick();
  }

  void _onTick() {
    final now = _now;
    final a = _anim;
    if (a != null && a.done(now)) {
      _anim = null;
      if (a.capture) {
        _bursts.add(_Burst(_g(a.to), now, !a.you));
        final captured = s.state['captured'] as Map? ?? const {};
        final count = ((a.you ? captured['you'] : captured['ai']) as num?)?.toInt() ?? 1;
        _flights.add(_TrayFlight(_g(a.to), now + 0.1, !a.you, (count - 1).clamp(0, 11)));
        _landings.add(_Landing(a.to, now, 1.0));
        HapticFeedback.heavyImpact();
      } else {
        _landings.add(_Landing(a.to, now, 0.7));
        HapticFeedback.selectionClick();
      }
      if (s.finished && _endAt < 0) {
        _endAt = now + 0.25;
        Future.delayed(const Duration(milliseconds: 250), () {
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
    final r = _return;
    if (r != null && now - r.at >= _Return.dur) _return = null;
    _bursts.removeWhere((b) => now - b.at > 0.75);
    final landed = _flights.where((f) => f.done(now)).toList();
    if (landed.isNotEmpty) {
      HapticFeedback.lightImpact();
      _flights.removeWhere((f) => f.done(now));
    }
    _landings.removeWhere((l) => now - l.at > 0.5);
    if (!_busy(now)) _ticker.stop();
    if (mounted) setState(() {});
  }

  void _maybeScheduleAi() {
    if (!mounted || s.finished || s.state['ai_pending'] != true) return;
    if (_aiTimer != null || _aiInFlight || _anim != null) return;
    final cx = (s.state['complexity'] as num?)?.toDouble() ?? 0.3;
    final jitter = ((_seenPly * 7919 + 13) % 97) / 97.0;
    final ms = (450 + 420 * cx + 230 * jitter).clamp(450, 1100).round();
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

  List<List<int>> _board() => [
        for (final row in s.state['board'] as List) [for (final v in row as List) (v as num).toInt()]
      ];

  Object? _movesSrc;
  Map<int, List<_Mv>> _movesCache = const {};

  /// Legal moves of the side to move, grouped by origin (parsed once per state).
  Map<int, List<_Mv>> _moves() {
    final ms = s.state['moves'];
    if (identical(ms, _movesSrc)) return _movesCache;
    final out = <int, List<_Mv>>{};
    _movesSrc = ms;
    _movesCache = out;
    if (ms is! List) return out;
    for (final m in ms) {
      final mm = m as Map;
      final cap = mm['capture'] == true;
      out.putIfAbsent(_idx(mm['from']), () => []).add(_Mv(_idx(mm['to']), cap,
          cap && mm['path'] is List ? _Poly.fromPath(mm['path'] as List) : null, _loopCount(mm['path'])));
    }
    return out;
  }

  bool _legal(int from, int to) => (_moves()[from] ?? const []).any((m) => m.to == to);

  List<int> _pt(int i) => [i ~/ 6, i % 6];

  void _shake(int i) {
    HapticFeedback.mediumImpact();
    _shakeIdx = i;
    _shakeAt = _now;
    _kick();
  }

  void _panStart(Offset p) {
    final geo = _geo;
    if (geo == null || !_canInput) return;
    final i = geo.pointAt(p, 0.6);
    if (i == null || _board()[i ~/ 6][i % 6] != 1) return;
    HapticFeedback.selectionClick();
    setState(() {
      _dragIdx = i;
      _sel = i;
      _hover = i;
      _dragPos = geo.px(_g(i));
      _grab = p - _dragPos;
    });
    _kick();
  }

  void _panUpdate(Offset p) {
    final geo = _geo;
    if (geo == null || _dragIdx == null) return;
    final pos = p - _grab;
    final h = geo.pointAt(pos, 0.6);
    if (h != _hover && h != null && h != _dragIdx) HapticFeedback.selectionClick();
    setState(() {
      _dragPos = pos;
      _hover = h;
    });
  }

  void _panEnd() {
    final geo = _geo;
    final i = _dragIdx;
    if (geo == null || i == null) return;
    final to = _hover;
    final dropG = geo.grid(_dragPos);
    _dragIdx = null;
    _hover = null;
    if (to != null && to != i && _legal(i, to)) {
      _pendingDrop = (i, dropG);
      _sel = null;
      s.act({'from': _pt(i), 'to': _pt(to)});
    } else {
      _return = _Return(i, dropG, _now);
      if (to != null && to != i) {
        s.act({'from': _pt(i), 'to': _pt(to)}); // rejected: the core explains why (toast)
        _shake(i);
      }
    }
    if (mounted) setState(() {});
    _kick();
  }

  void _tap(Offset p) {
    final geo = _geo;
    if (geo == null || !_canInput) return;
    final i = geo.pointAt(p, 0.6);
    if (i == null) {
      setState(() => _sel = null);
      return;
    }
    final v = _board()[i ~/ 6][i % 6];
    final sel = _sel;
    if (v == 1) {
      HapticFeedback.selectionClick();
      setState(() => _sel = sel == i ? null : i);
      _kick();
      return;
    }
    if (sel == null) return;
    if (_legal(sel, i)) {
      setState(() => _sel = null);
      s.act({'from': _pt(sel), 'to': _pt(i)});
    } else {
      s.act({'from': _pt(sel), 'to': _pt(i)});
      _shake(sel);
      setState(() {});
    }
  }

  void _showLoopHelp(BuildContext context) {
    HapticFeedback.selectionClick();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Lux.panel,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const LuxHeading('Halka ile alış'),
              const SurakartaLoopDemo(size: 240),
              const SizedBox(height: 14),
              for (final line in _loopHelpLines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(line, style: Lux.ui(14, color: Lux.ink)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static const _loopHelpLines = [
    'Taşın bir devre çizgisi boyunca istediği kadar gider ve en az bir köşe halkasını dolaşır. Yol boş olmalı; '
        'ilk çarptığı taş rakibinse onu alır.',
    'İki yön de geçerli: rakibe doğru değil, ondan uzaklaşıp geriye doğru gidip halkadan dönerek de vurabilirsin. '
        'Yol birden çok halkadan ve taşın kendi başladığı noktanın üstünden geçebilir.',
    'Alışı olan taşının köşesinde altın halka işareti yanar. Taşa dokununca alabileceği her rakip altın halkayla '
        'çevrilir ve yolu kesik çizgiyle görünür; "×2" gibi bir sayı yolun kaç halkadan geçtiğini söyler.',
    'Taşının çevresinde bordo kesik halka varsa rakip onu halkadan alabilir.',
  ];

  Future<void> _askHint() async {
    if (!_canInput) return;
    setState(() {
      _hintBusy = true;
      _sel = null;
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
    if (st['board'] is! List) return const SizedBox();
    final captured = st['captured'] as Map? ?? const {};
    final counts = st['counts'] as Map? ?? const {};
    final quiet = (st['quiet'] as num?)?.toInt() ?? 0;
    final quietLimit = (st['quiet_limit'] as num?)?.toInt() ?? 40;
    final rank = (st['title'] as String?) ?? '';
    final thinking = _aiTimer != null || _aiInFlight;
    final playing = !s.finished;
    final canCapture = _canInput && _moves().values.any((l) => l.any((m) => m.capture));

    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(builder: (context, box) {
            final w = box.maxWidth, h = box.maxHeight;
            const topH = 64.0, botH = 58.0, gap = 8.0;
            final size = math.min(w - 8, h - topH - botH - 2 * gap).clamp(120.0, 2000.0);
            final y0 = ((h - (topH + botH + 2 * gap + size)) / 2).clamp(0.0, 400.0);
            final left = (w - size) / 2;
            final boardRect = Rect.fromLTWH(left, y0 + topH + gap, size, size);
            final geo = _Geo(boardRect);
            _geo = geo;
            final stripLeft = math.max(8.0, left + size * 0.03);
            final stripW = math.min(w - 16, size * 0.94);
            const trayW = 6 * 15.0;
            _aiTray = Offset(stripLeft + stripW - trayW - 12, y0 + 26);
            final botTop = boardRect.bottom + gap;
            _youTray = Offset(stripLeft + stripW * 0.5 - trayW / 2 + 10, botTop + 22);

            final now = _now;
            final flyingToAi = _flights.where((f) => f.victimYou).length;
            final flyingToYou = _flights.length - flyingToAi;
            final aiTaken = (((captured['ai'] as num?)?.toInt() ?? 0) - flyingToAi).clamp(0, 12);
            final youTaken = (((captured['you'] as num?)?.toInt() ?? 0) - flyingToYou).clamp(0, 12);
            if (_busy(now)) _kick();

            return Stack(
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
                                  : Text(
                                      playing ? '${counts['ai'] ?? 12} taş' : '${counts['ai'] ?? 0} taş kaldı',
                                      style: Lux.ui(12, color: Lux.muted, spacing: 0.8)),
                            ],
                          ),
                        ),
                        SizedBox(
                          width: trayW + 4,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              const SizedBox(height: 4),
                              Text('ALDIĞI  $aiTaken', style: Lux.ui(10, color: Lux.muted, spacing: 1.4)),
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
                    active: _yourTurn && _anim == null && !thinking,
                    activeColor: Lux.gold,
                    child: Row(
                      children: [
                        SizedBox(
                          width: stripW * 0.30,
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
                                  style: Lux.ui(14,
                                      color: _yourTurn ? Lux.goldLight : Lux.muted, weight: FontWeight.w600)),
                              canCapture
                                  ? FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.centerLeft,
                                      child: Text('Halkadan alış var',
                                          maxLines: 1, style: Lux.ui(12, color: Lux.goldLight, weight: FontWeight.w600)))
                                  : Text('${counts['you'] ?? 12} taşın', style: Lux.ui(12, color: Lux.muted, spacing: 0.8)),
                            ],
                          ),
                        ),
                        Expanded(
                          child: Column(
                            children: [
                              const SizedBox(height: 4),
                              Text('ALDIĞIN  $youTaken', style: Lux.ui(10, color: Lux.muted, spacing: 1.4)),
                            ],
                          ),
                        ),
                        SizedBox(
                          width: stripW * 0.24,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text('SESSİZ HAMLE', maxLines: 1, style: Lux.ui(10, color: Lux.muted, spacing: 1.4))),
                              Text('$quiet / $quietLimit',
                                  style: Lux.numeral(18,
                                      color: quiet >= quietLimit - 10 ? Lux.bordeauxLight : Lux.goldLight)),
                              const SizedBox(height: 3),
                              _QuietBar(quiet / quietLimit),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Static board.
                Positioned.fromRect(
                  rect: boardRect,
                  child: RepaintBoundary(child: CustomPaint(painter: _BoardPainter(boardRect.size))),
                ),
                // Pieces, highlights and effects.
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(painter: _DynPainter(this, geo, now, aiTaken, youTaken)),
                  ),
                ),
                Positioned.fromRect(
                  rect: boardRect,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    // Pick the piece up where the finger went down, not where the slop was crossed.
                    dragStartBehavior: DragStartBehavior.down,
                    onTapUp: (d) => _tap(d.localPosition + boardRect.topLeft),
                    onPanStart: (d) => _panStart(d.localPosition + boardRect.topLeft),
                    onPanUpdate: (d) => _panUpdate(d.localPosition + boardRect.topLeft),
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
                          setState(() => _sel = null);
                          s.act({'undo': true});
                        }
                      : null),
              const SizedBox(width: 24),
              RimIconButton(_hintBusy ? Icons.hourglass_top_rounded : Icons.lightbulb_outline_rounded,
                  tooltip: 'İpucu: en iyi hamle (yıldızı 1\'e düşürür)', onPressed: _canInput ? _askHint : null),
              const SizedBox(width: 24),
              RimIconButton(Icons.all_inclusive_rounded,
                  tooltip: 'Halka ile alış nasıl yapılır?', onPressed: () => _showLoopHelp(context)),
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

class _QuietBar extends StatelessWidget {
  final double v;
  const _QuietBar(this.v);

  @override
  Widget build(BuildContext context) {
    final c = v >= 0.75 ? Lux.bordeauxLight : Lux.gold;
    return SizedBox(
      width: 64,
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

/// Lacquer panel, faint grid, and the two inlaid circuits with their corner loops.
class _BoardPainter extends CustomPainter {
  final Size size;
  _BoardPainter(this.size);

  @override
  void paint(Canvas canvas, Size sz) {
    final geo = _Geo(Offset.zero & sz);
    final rect = Offset.zero & sz;
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(sz.width * 0.07));
    canvas.drawRRect(
      rr.shift(const Offset(0, 8)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.6)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
    );
    canvas.drawRRect(
      rr,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.25, -0.35),
          radius: 1.1,
          colors: [Color(0xFF12302A), Color(0xFF081A15), Color(0xFF030A08)],
          stops: [0, 0.55, 1],
        ).createShader(rect),
    );
    // Lacquer sheen.
    canvas.save();
    canvas.clipRRect(rr);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white.withValues(alpha: 0.07), Colors.white.withValues(alpha: 0.0), Colors.white.withValues(alpha: 0.025)],
          stops: const [0, 0.45, 1],
        ).createShader(rect),
    );
    canvas.restore();
    // Gold rim + inner hairline.
    canvas.drawRRect(
      rr.deflate(1),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..shader = Lux.foil.createShader(rect),
    );
    canvas.drawRRect(
      rr.deflate(6),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = Lux.gold.withValues(alpha: 0.22),
    );

    final cell = geo.cell;
    // Faint grid (all six lines each way).
    final grid = Paint()
      ..color = Lux.gold.withValues(alpha: 0.16)
      ..strokeWidth = 1;
    for (var i = 0; i < 6; i++) {
      canvas.drawLine(geo.px(Offset(i.toDouble(), 0)), geo.px(Offset(i.toDouble(), 5)), grid);
      canvas.drawLine(geo.px(Offset(0, i.toDouble())), geo.px(Offset(5, i.toDouble())), grid);
    }

    void circuit(int k, Color c, Color deep) {
      final path = Path();
      for (final line in [k, 5 - k]) {
        path.moveTo(geo.px(Offset(0, line.toDouble())).dx, geo.px(Offset(0, line.toDouble())).dy);
        path.lineTo(geo.px(Offset(5, line.toDouble())).dx, geo.px(Offset(5, line.toDouble())).dy);
        path.moveTo(geo.px(Offset(line.toDouble(), 0)).dx, geo.px(Offset(line.toDouble(), 0)).dy);
        path.lineTo(geo.px(Offset(line.toDouble(), 5)).dx, geo.px(Offset(line.toDouble(), 5)).dy);
      }
      for (var corner = 0; corner < 4; corner++) {
        final ctr = geo.px(_corners[corner]);
        path.addArc(Rect.fromCircle(center: ctr, radius: k * cell), math.pi / 2 * (corner + 1), 1.5 * math.pi);
      }
      final w = math.max(2.0, cell * 0.075);
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = w * 2.4
            ..color = Colors.black.withValues(alpha: 0.6));
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = w * 1.8
            ..color = c.withValues(alpha: 0.35)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 1.6));
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = w
            ..color = deep);
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = w * 0.62
            ..color = c);
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(0.6, w * 0.2)
            ..color = Color.lerp(c, Colors.white, 0.6)!.withValues(alpha: 0.8));
    }

    circuit(2, _loopGold, _loopGoldDeep);
    circuit(1, _emerald, _emeraldDeep);

    // Inlaid studs at every intersection.
    for (var r = 0; r < 6; r++) {
      for (var c = 0; c < 6; c++) {
        final p = geo.px(Offset(c.toDouble(), r.toDouble()));
        canvas.drawCircle(p, cell * 0.085, Paint()..color = const Color(0xFF020806));
        canvas.drawCircle(
            p,
            cell * 0.085,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1
              ..color = Lux.gold.withValues(alpha: 0.55));
      }
    }
  }

  @override
  bool shouldRepaint(_BoardPainter old) => old.size != size;
}

/// Pieces, selection, previews, the moving piece with its comet trail, bursts and tray flights.
class _DynPainter extends CustomPainter {
  final _SurakartaBoardState st;
  final _Geo geo;
  final double now;
  final int aiTaken, youTaken;
  _DynPainter(this.st, this.geo, this.now, this.aiTaken, this.youTaken);

  double get cell => geo.cell;
  double get pr => cell * 0.36;

  @override
  void paint(Canvas canvas, Size size) {
    final state = st.s.state;
    final board = st._board();
    final anim = st._anim;
    final pulse = 0.5 + 0.5 * math.sin(now * 5.2);
    final moves = st._yourTurn ? st._moves() : <int, List<_Mv>>{};

    _trays(canvas);

    // Last-move ghost (when nothing is moving).
    final lm = state['last_move'];
    if (anim == null && lm is Map) {
      final from = _idx(lm['from']), to = _idx(lm['to']);
      final you = lm['who'] == 'you';
      final col = (you ? _pearlTrail : _rose).withValues(alpha: 0.38);
      final pts = lm['capture'] == true && lm['path'] is List ? _Poly.fromPath(lm['path'] as List) : [_g(from), _g(to)];
      _polyline(canvas, pts, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.5, cell * 0.05)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = col);
      final fp = geo.px(_g(from));
      canvas.drawCircle(
          fp,
          pr * 0.82,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4
            ..color = (you ? Lux.goldLight : _rose).withValues(alpha: 0.4));
      canvas.drawCircle(fp, pr * 0.16, Paint()..color = (you ? Lux.goldLight : _rose).withValues(alpha: 0.35));
    }

    // Selected / dragged piece: legal steps and capture paths.
    final sel = st._dragIdx ?? st._sel;
    // Badges drawn on top of the pieces: (point, loops) of capture targets / capturing pieces.
    final targetBadges = <(int, int)>[];
    final capturerBadges = <int>[];
    if (sel != null && anim == null) {
      final list = moves[sel] ?? const <_Mv>[];
      // While dragging over a capture target, its path is bright and the others step back.
      final hover = st._dragIdx != null ? st._hover : null;
      final focus = list.where((m) => m.capture && m.to == hover).firstOrNull;
      for (final m in list) {
        if (m.capture && m.path != null && m != focus) {
          _dashes(canvas, m.path!, focus == null ? const Color(0xFFFFF4DA) : const Color(0x88FFF4DA), now);
        }
      }
      if (focus?.path != null) _dashes(canvas, focus!.path!, Lux.goldLight, now, width: 1.35);
      for (final m in list) {
        final p = geo.px(_g(m.to));
        if (m.capture) {
          final rr = pr * (1.2 + 0.07 * pulse);
          canvas.drawCircle(
              p,
              rr * 1.25,
              Paint()
                ..color = _loopGold.withValues(alpha: 0.28 + 0.22 * pulse)
                ..maskFilter = MaskFilter.blur(BlurStyle.normal, pr * 0.5));
          canvas.drawCircle(
              p,
              rr,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = math.max(2.4, cell * 0.08)
                ..color = Lux.goldLight.withValues(alpha: 0.7 + 0.3 * pulse));
          targetBadges.add((m.to, m.loops));
        } else {
          canvas.drawCircle(
              p,
              cell * 0.16,
              Paint()
                ..color = Lux.gold.withValues(alpha: 0.35)
                ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
          canvas.drawCircle(p, cell * 0.095, Paint()..color = Lux.goldLight.withValues(alpha: 0.85));
        }
      }
      // Halo on the held piece's home point.
      canvas.drawCircle(
          geo.px(_g(sel)),
          pr * 1.25,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = Lux.gold.withValues(alpha: 0.45 + 0.4 * pulse));
    } else if (anim == null && st._canInput) {
      // Nothing selected on your turn: mark every piece that has a loop capture, and your pieces
      // the opponent could take.
      for (final e in moves.entries) {
        if (e.value.any((m) => m.capture)) capturerBadges.add(e.key);
      }
      for (final t in (state['threats'] as List? ?? const [])) {
        _dashedRing(canvas, geo.px(_g(_idx(t))), pr * 1.24, _rose.withValues(alpha: 0.5 + 0.3 * pulse));
      }
    }

    // Hint.
    final hint = state['hint'];
    if (hint is Map && anim == null) {
      final from = _idx(hint['from']), to = _idx(hint['to']);
      final pts = hint['capture'] == true && hint['path'] is List ? _Poly.fromPath(hint['path'] as List) : [_g(from), _g(to)];
      _dashes(canvas, pts, const Color(0xFFFFF4DA), now);
      for (final i in [from, to]) {
        canvas.drawCircle(
            geo.px(_g(i)),
            pr * (1.25 + 0.12 * pulse),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.6
              ..color = Lux.gold.withValues(alpha: 0.5 + 0.45 * pulse)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5));
      }
    }

    // Drag hover: gold if legal, bordeaux if not.
    final drag = st._dragIdx;
    final hover = st._hover;
    if (drag != null && hover != null && hover != drag) {
      final ok = (moves[drag] ?? const <_Mv>[]).any((m) => m.to == hover);
      final c = ok ? Lux.gold : Lux.bordeaux;
      final p = geo.px(_g(hover));
      canvas.drawCircle(
          p,
          pr * 1.9,
          Paint()
            ..color = c.withValues(alpha: 0.5)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12));
      canvas.drawCircle(
          p,
          pr * 1.5,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.8
            ..color = ok ? Lux.goldLight : Lux.bordeauxLight);
    }

    // Static pieces.
    final endT = st._endAt >= 0 ? now - st._endAt : -1.0;
    final won = state['status'] == 'won';
    for (var i = 0; i < 36; i++) {
      final v = board[i ~/ 6][i % 6];
      if (v == 0) continue;
      if (anim != null && i == anim.to) continue;
      if (i == drag) continue;
      final ret = st._return;
      if (ret != null && ret.idx == i) continue;
      var p = geo.px(_g(i));
      if (i == st._shakeIdx) {
        final k = now - st._shakeAt;
        if (k < 0.45) p += Offset(math.sin(k * 48) * cell * 0.12 * math.exp(-k * 7), 0);
      }
      var sx = 1.0, sy = 1.0;
      for (final l in st._landings) {
        if (l.idx != i) continue;
        final k = now - l.at;
        final sq = 0.18 * l.strength * math.exp(-k * 10) * math.cos(k * 30);
        sx = 1 + sq;
        sy = 1 - sq;
      }
      var glow = 0.0;
      if (endT >= 0 && endT < 1.6 && ((won && v == 1) || (!won && v == 2))) {
        // End ripple: the winner's pieces light up from the board centre outwards.
        final d = (_g(i) - const Offset(2.5, 2.5)).distance / 3.6;
        final k = endT - d * 0.5;
        if (k > 0 && k < 0.7) glow = math.sin(math.pi * k / 0.7);
      }
      final held = st._sel == i && anim == null;
      _piece(canvas, p, v == 1, sx: sx, sy: sy, glow: math.max(glow, held ? 0.5 + 0.3 * pulse : 0), lift: held ? 0.25 : 0);
    }

    // Loop badges: on capture targets of the held piece, and on your pieces that can capture.
    for (final (i, loops) in targetBadges) {
      _loopBadge(canvas, geo.px(_g(i)) + Offset(pr * 0.82, -pr * 0.82), pr * 0.46, loops);
    }
    for (final i in capturerBadges) {
      final p = geo.px(_g(i));
      canvas.drawCircle(
          p,
          pr * 1.14,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6
            ..color = Lux.goldLight.withValues(alpha: 0.75));
      _loopBadge(canvas, p + Offset(pr * 0.82, -pr * 0.82), pr * 0.42, 1);
    }

    // Victim waiting at the target until the hit.
    if (anim != null && anim.capture) {
      _piece(canvas, geo.px(_g(anim.to)), !anim.you);
    }

    // Bursts and shards.
    for (final b in st._bursts) {
      _burst(canvas, b);
    }

    // Returning (illegal drop) piece.
    final ret = st._return;
    if (ret != null) {
      final t = Curves.easeOutBack.transform(((now - ret.at) / _Return.dur).clamp(0.0, 1.0));
      _piece(canvas, geo.px(Offset.lerp(ret.fromG, _g(ret.idx), t)!), true, lift: 0.4 * (1 - t));
    }

    // Moving piece with its comet trail.
    if (anim != null) {
      final d = anim.dist(now);
      final head = anim.poly.at(d);
      if (anim.capture) {
        // Faint wake along everything travelled so far, then the bright comet tail.
        final wake = <Offset>[];
        for (var x = 0.0; x < d; x += 0.12) {
          wake.add(anim.poly.at(x));
        }
        wake.add(head);
        _polyline(canvas, wake, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = cell * 0.07
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = (anim.you ? _pearlTrail : _rose).withValues(alpha: 0.22));
        const tail = 1.8;
        const n = 18;
        for (var k = n; k >= 1; k--) {
          final x = d - tail * k / n;
          if (x < 0) continue;
          final f = 1 - k / n;
          canvas.drawCircle(
              geo.px(anim.poly.at(x)),
              pr * (0.25 + 0.6 * f),
              Paint()
                ..color = (anim.you ? _pearlTrail : _rose).withValues(alpha: 0.05 + 0.3 * f)
                ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 + 4 * f));
        }
      }
      final u = anim.u(now);
      final lift = math.sin(math.pi * u) * (anim.capture ? 0.7 : 1.0);
      _piece(canvas, geo.px(head), anim.you, lift: lift, glow: anim.capture ? 0.9 : 0.35, sx: 1 + 0.1 * lift, sy: 1 + 0.1 * lift);
    }

    // Dragged piece follows the finger.
    if (drag != null) {
      _piece(canvas, st._dragPos, true, lift: 1, sx: 1.12, sy: 1.12, glow: 0.6);
    }

    // Captured pieces flying to their tray.
    for (final f in st._flights) {
      final k = ((now - f.at) / _TrayFlight.dur).clamp(0.0, 1.0);
      if (now < f.at) continue;
      final e = Curves.easeInOutCubic.transform(k);
      final a = geo.px(f.g);
      final b = _slot(f.victimYou, f.slot);
      final ctrl = Offset((a.dx + b.dx) / 2 + (b.dx - a.dx) * 0.2, math.min(a.dy, b.dy) - cell * 1.6);
      final p = Offset.lerp(Offset.lerp(a, ctrl, e)!, Offset.lerp(ctrl, b, e)!, e)!;
      final r = pr + (5.5 - pr) * e;
      _gem(canvas, p, r, f.victimYou, glow: 0.8 * (1 - e) + 0.2);
    }
  }

  Offset _slot(bool pearl, int i) {
    final o = pearl ? st._aiTray : st._youTray;
    return o + Offset((i % 6) * 15.0 + 7, (i ~/ 6) * 14.0 + 12);
  }

  void _trays(Canvas canvas) {
    for (final (pearl, taken) in [(true, aiTaken), (false, youTaken)]) {
      for (var i = 0; i < 12; i++) {
        final p = _slot(pearl, i);
        if (i < taken) {
          _gem(canvas, p, 5.5, pearl);
        } else {
          canvas.drawCircle(
              p,
              4,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 0.8
                ..color = Lux.gold.withValues(alpha: 0.22));
        }
      }
    }
  }

  void _polyline(Canvas canvas, List<Offset> pts, Paint paint) {
    if (pts.length < 2) return;
    final path = Path()..moveTo(geo.px(pts.first).dx, geo.px(pts.first).dy);
    for (final p in pts.skip(1)) {
      final q = geo.px(p);
      path.lineTo(q.dx, q.dy);
    }
    canvas.drawPath(path, paint);
  }

  /// Marching dashes along a path (capture preview).
  void _dashes(Canvas canvas, List<Offset> pts, Color color, double now, {double width = 1}) =>
      _drawDashes(canvas, geo, pts, color, now, width: width);

  void _loopBadge(Canvas canvas, Offset c, double r, int loops) => _drawLoopBadge(canvas, c, r, loops);

  /// Eight short arcs: "this piece is under fire".
  void _dashedRing(Canvas canvas, Offset c, double r, Color color) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.6, cell * 0.06)
      ..strokeCap = StrokeCap.round
      ..color = color;
    for (var i = 0; i < 8; i++) {
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), i * math.pi / 4 + 0.12, math.pi / 4 - 0.34, false, paint);
    }
  }

  void _burst(Canvas canvas, _Burst b) {
    final t = ((now - b.at) / 0.75).clamp(0.0, 1.0);
    final e = Curves.easeOutCubic.transform(t);
    final c = geo.px(b.g);
    final col = b.victimYou ? _rose : Lux.goldLight;
    canvas.drawCircle(
        c,
        cell * (0.3 + 0.95 * e),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(0.5, 4 * (1 - t))
          ..color = col.withValues(alpha: 0.85 * (1 - t)));
    canvas.drawCircle(
        c,
        cell * 0.55 * (1 - t),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.5 * (1 - t))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
    // Sparks.
    final spark = Paint()
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..color = col.withValues(alpha: 1 - t);
    for (var i = 0; i < 12; i++) {
      final a = i * math.pi / 6 + 0.2;
      final dir = Offset(math.cos(a), math.sin(a));
      final r0 = cell * (0.35 + 0.8 * e), r1 = cell * (0.5 + 1.15 * e);
      canvas.drawLine(c + dir * r0, c + dir * r1, spark);
    }
    // Shards of the victim, spinning outwards and falling.
    final shard = b.victimYou ? const Color(0xFFEFE7D6) : _garnet;
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4 + 0.4 + (i.isEven ? 0.15 : -0.1);
      final dist = cell * (0.15 + 0.95 * e) * (0.75 + 0.35 * ((i * 37) % 10) / 10);
      final p = c + Offset(math.cos(a), math.sin(a)) * dist + Offset(0, cell * 0.9 * t * t);
      final s = pr * 0.32 * (1 - 0.6 * t);
      final rot = a + t * (i.isEven ? 7 : -6);
      final path = Path()
        ..moveTo(p.dx + math.cos(rot) * s, p.dy + math.sin(rot) * s)
        ..lineTo(p.dx + math.cos(rot + 2.3) * s * 0.7, p.dy + math.sin(rot + 2.3) * s * 0.7)
        ..lineTo(p.dx + math.cos(rot + 4.1) * s * 0.9, p.dy + math.sin(rot + 4.1) * s * 0.9)
        ..close();
      canvas.drawPath(path, Paint()..color = shard.withValues(alpha: 1 - t));
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.7
            ..color = Colors.white.withValues(alpha: 0.5 * (1 - t)));
    }
  }

  void _piece(Canvas canvas, Offset p, bool pearl,
      {double sx = 1, double sy = 1, double glow = 0, double lift = 0}) {
    final r = pr;
    // Drop shadow grows and softens with lift.
    canvas.drawOval(
      Rect.fromCenter(center: p + Offset(0, r * (0.22 + 0.35 * lift)), width: r * 2 * (1 + 0.1 * lift), height: r * 1.7),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.55 - 0.15 * lift)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2.5 + 5 * lift),
    );
    final c = p - Offset(0, r * 0.18 * lift);
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.scale(sx, sy);
    _gem(canvas, Offset.zero, r, pearl, glow: glow);
    canvas.restore();
  }

  void _gem(Canvas canvas, Offset c, double r, bool pearl, {double glow = 0}) => _drawGem(canvas, c, r, pearl, glow: glow);

  @override
  bool shouldRepaint(_DynPainter old) => true;
}

/// Marching dashes along a path in grid units, over a dark channel that keeps them readable on top
/// of either circuit.
void _drawDashes(Canvas canvas, _Geo geo, List<Offset> pts, Color color, double now, {double width = 1}) {
  if (pts.length < 2) return;
  final cell = geo.cell;
  final path = Path()..moveTo(geo.px(pts.first).dx, geo.px(pts.first).dy);
  for (final p in pts.skip(1)) {
    final q = geo.px(p);
    path.lineTo(q.dx, q.dy);
  }
  final dash = cell * 0.18, gap = cell * 0.14;
  final period = dash + gap;
  final phase = (now * cell * 1.6) % period;
  final paint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = math.max(1.8, cell * 0.075) * width
    ..strokeCap = StrokeCap.round
    ..color = color;
  canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(4, cell * 0.17) * width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0xCC020806));
  canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(5, cell * 0.22) * width
        ..color = color.withValues(alpha: 0.16 * width)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
  for (final m in path.computeMetrics()) {
    for (var d = phase - period; d < m.length; d += period) {
      final a = math.max(0.0, d), b = math.min(m.length, d + dash);
      if (b > a) canvas.drawPath(m.extractPath(a, b), paint);
    }
  }
}

/// A 270° loop with an arrowhead: the sign for "captures round a corner loop".
void _drawLoopIcon(Canvas canvas, Offset c, double s, Color color) {
  final w = math.max(1.2, s * 0.34);
  const start = math.pi * 0.85, sweep = math.pi * 1.5;
  canvas.drawArc(
      Rect.fromCircle(center: c, radius: s),
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..strokeCap = StrokeCap.round
        ..color = color);
  const a = start + sweep;
  final nrm = Offset(math.cos(a), math.sin(a));
  final tan = Offset(-math.sin(a), math.cos(a)); // direction of travel (increasing angle)
  final tip = c + nrm * s;
  final h = s * 0.7;
  final head = Path()
    ..moveTo(tip.dx + tan.dx * h, tip.dy + tan.dy * h)
    ..lineTo(tip.dx + nrm.dx * h * 0.75 - tan.dx * h * 0.15, tip.dy + nrm.dy * h * 0.75 - tan.dy * h * 0.15)
    ..lineTo(tip.dx - nrm.dx * h * 0.75 - tan.dx * h * 0.15, tip.dy - nrm.dy * h * 0.75 - tan.dy * h * 0.15)
    ..close();
  canvas.drawPath(head, Paint()..color = color);
}

/// Dark gold-rimmed badge with the loop sign; a pill with "×N" when the path runs through N ≥ 2 loops.
void _drawLoopBadge(Canvas canvas, Offset c, double r, int loops) {
  TextPainter? tp;
  if (loops >= 2) {
    tp = TextPainter(
      text: TextSpan(text: '×$loops', style: Lux.ui(r * 1.05, color: Lux.goldLight, weight: FontWeight.w700, spacing: 0)),
      textDirection: TextDirection.ltr,
    )..layout();
  }
  final extra = tp == null ? 0.0 : tp.width + r * 0.35;
  final rect = RRect.fromLTRBR(c.dx - r, c.dy - r, c.dx + r + extra, c.dy + r, Radius.circular(r));
  canvas.drawRRect(
      rect.shift(Offset(0, r * 0.15)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.55)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.3));
  canvas.drawRRect(rect, Paint()..color = const Color(0xF2061A14));
  canvas.drawRRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, r * 0.14)
        ..color = _loopGold);
  _drawLoopIcon(canvas, c, r * 0.5, Lux.goldLight);
  tp?.paint(canvas, Offset(c.dx + r * 0.95, c.dy - tp.height / 2));
}

/// Glossy pearl (yours) or garnet (the AI's).
void _drawGem(Canvas canvas, Offset c, double r, bool pearl, {double glow = 0}) {
    if (glow > 0) {
      canvas.drawCircle(
          c,
          r * 1.45,
          Paint()
            ..color = (pearl ? Lux.goldLight : _rose).withValues(alpha: 0.45 * glow)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.7));
    }
    final rect = Rect.fromCircle(center: c, radius: r);
    final colors = pearl
        ? const [Color(0xFFFFFFFF), Color(0xFFF1E9D8), Color(0xFFC9BC9F), Color(0xFF5E5442)]
        : const [Color(0xFFFFA3B6), Color(0xFFB8223F), Color(0xFF5E0A1F), Color(0xFF1E0309)];
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.38, -0.45),
            radius: 1.05,
            colors: colors,
            stops: pearl ? const [0, 0.22, 0.64, 1] : const [0, 0.3, 0.74, 1],
          ).createShader(rect));
    if (pearl) {
      // Nacre: a faint iridescent ring.
      canvas.drawCircle(
          c,
          r * 0.72,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = r * 0.34
            ..shader = const SweepGradient(colors: [
              Color(0x38FFB6D9),
              Color(0x38A8E6FF),
              Color(0x38C8FFD9),
              Color(0x38FFE6A8),
              Color(0x38FFB6D9),
            ]).createShader(rect));
    } else if (r > 8) {
      // Garnet facets: a dark inner table.
      final facet = Path();
      for (var i = 0; i < 6; i++) {
        final a = i * math.pi / 3 + math.pi / 6;
        final q = c + Offset(math.cos(a), math.sin(a)) * r * 0.55;
        if (i == 0) {
          facet.moveTo(q.dx, q.dy);
        } else {
          facet.lineTo(q.dx, q.dy);
        }
      }
      facet.close();
      canvas.drawPath(
          facet,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.8
            ..color = const Color(0x24FFC2CF));
    }
    canvas.drawCircle(
        c,
        r - 0.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1
          ..color = Lux.goldLight.withValues(alpha: pearl ? 0.35 : 0.45));
    // Specular highlight + a smaller hot spot; a soft reflected light underneath.
    canvas.drawOval(
        Rect.fromCenter(center: c + Offset(-r * 0.3, -r * 0.42), width: r * 0.62, height: r * 0.36),
        Paint()
          ..color = Colors.white.withValues(alpha: pearl ? 0.7 : 0.55)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.08 + 0.5));
    canvas.drawCircle(c + Offset(-r * 0.36, -r * 0.46), r * 0.08, Paint()..color = Colors.white.withValues(alpha: 0.9));
    canvas.drawArc(
        Rect.fromCircle(center: c, radius: r * 0.8),
        math.pi * 0.2,
        math.pi * 0.6,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.12
          ..color = (pearl ? const Color(0xFFFFF4DC) : const Color(0xFFFF6F8E)).withValues(alpha: 0.22)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.08 + 0.5));
}

// ---------------------------------------------------------------------------------------------
// Loop-capture demo (tutorial + in-game help)

class _DemoScene {
  final List<int> pearls, garnets;
  final int from, to;
  final List<Map<String, Object>> path;
  final String caption;
  const _DemoScene(this.pearls, this.garnets, this.from, this.to, this.path, this.caption);
}

Map<String, Object> _pt(int r, int c) => {
      'pt': [r, c]
    };
Map<String, Object> _arc(int corner) => {
      'arc': {'corner': corner, 'circuit': 'inner'}
    };

final _demoScenes = [
  // Backwards: (4,1) runs down, away from its target, loops round the bottom-left corner, passes its
  // own point and takes (4,3) from behind.
  _DemoScene(
    [25, 19, 34, 29],
    [27, 8, 3, 10],
    25,
    27,
    [_pt(4, 1), _pt(5, 1), _arc(3), _pt(4, 0), _pt(4, 1), _pt(4, 2), _pt(4, 3)],
    'Geriye yuvarlama: taş önce aşağı iner, sol alt halkadan döner, kendi noktasının üstünden geçip rakibi arkadan alır.',
  ),
  // Two loops: (4,0) → bottom-left loop → up column 1 → top-left loop → (1,2).
  _DemoScene(
    [24, 33, 27, 22],
    [8, 4, 11, 15],
    24,
    8,
    [
      _pt(4, 0), _arc(3), _pt(5, 1), _pt(4, 1), _pt(3, 1), _pt(2, 1), _pt(1, 1), _pt(0, 1), //
      _arc(0), _pt(1, 0), _pt(1, 1), _pt(1, 2),
    ],
    'İki halka: sol alt halkadan girer, sütunu baştan sona çıkar, sol üst halkadan dönüp alır.',
  ),
];

/// A small board that replays loop captures over and over: the pearl is picked up (target ring,
/// loop badge and dashed path appear), rides the circuit through its 270° loops, and takes the
/// garnet.
class SurakartaLoopDemo extends StatefulWidget {
  final double size;
  const SurakartaLoopDemo({super.key, this.size = 270});

  @override
  State<SurakartaLoopDemo> createState() => _SurakartaLoopDemoState();
}

class _SurakartaLoopDemoState extends State<SurakartaLoopDemo> with SingleTickerProviderStateMixin {
  static const _scene = 4.6; // seconds per scene
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: (_scene * _demoScenes.length * 1000).round()),
  )..repeat();
  late final List<_Poly> _polys = [for (final s in _demoScenes) _Poly(_Poly.fromPath(s.path))];

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value * _scene * _demoScenes.length;
        final i = (t ~/ _scene).clamp(0, _demoScenes.length - 1);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: widget.size,
              height: widget.size,
              child: CustomPaint(painter: _LoopDemoPainter(_demoScenes[i], _polys[i], t - i * _scene, t)),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: widget.size,
              child: Text(_demoScenes[i].caption, textAlign: TextAlign.center, style: Lux.ui(12.5, color: Lux.muted)),
            ),
          ],
        );
      },
    );
  }
}

class _LoopDemoPainter extends CustomPainter {
  final _DemoScene scene;
  final _Poly poly;
  final double t, clock;
  _LoopDemoPainter(this.scene, this.poly, this.t, this.clock);

  static const _pick = 0.9, _ride = 2.1, _hold = 0.6;

  @override
  void paint(Canvas canvas, Size size) {
    _BoardPainter(size).paint(canvas, size);
    final geo = _Geo(Offset.zero & size);
    final pr = geo.cell * 0.36;
    final riding = t >= _pick && t < _pick + _ride;
    final done = t >= _pick + _ride;
    final u = ((t - _pick) / _ride).clamp(0.0, 1.0);
    final d = (0.78 * u + 0.22 * Curves.easeInOutCubic.transform(u)) * poly.length;
    final pulse = 0.5 + 0.5 * math.sin(clock * 5.2);

    void piece(Offset p, bool pearl, {double glow = 0, double lift = 0}) {
      canvas.drawOval(
          Rect.fromCenter(center: p + Offset(0, pr * (0.22 + 0.35 * lift)), width: pr * 2, height: pr * 1.7),
          Paint()
            ..color = Colors.black.withValues(alpha: 0.5)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2.5 + 4 * lift));
      _drawGem(canvas, p - Offset(0, pr * 0.18 * lift), pr, pearl, glow: glow);
    }

    if (!done) _drawDashes(canvas, geo, poly.pts, const Color(0xFFFFF4DA), clock);
    for (final i in scene.pearls) {
      if (i == scene.from && (riding || done)) continue;
      piece(geo.px(_g(i)), true, glow: i == scene.from ? 0.5 + 0.3 * pulse : 0);
    }
    for (final i in scene.garnets) {
      if (i == scene.to && done) continue;
      piece(geo.px(_g(i)), false);
    }
    final target = geo.px(_g(scene.to));
    if (!done) {
      canvas.drawCircle(
          target,
          pr * (1.2 + 0.07 * pulse),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(2.0, geo.cell * 0.08)
            ..color = Lux.goldLight.withValues(alpha: 0.7 + 0.3 * pulse));
      _drawLoopBadge(canvas, target + Offset(pr * 0.82, -pr * 0.82), pr * 0.46, _loopCount(scene.path));
    }
    if (riding) {
      // Comet tail, then the pearl itself.
      for (var k = 14; k >= 1; k--) {
        final x = d - 1.6 * k / 14;
        if (x < 0) continue;
        final f = 1 - k / 14;
        canvas.drawCircle(
            geo.px(poly.at(x)),
            pr * (0.25 + 0.6 * f),
            Paint()
              ..color = _pearlTrail.withValues(alpha: 0.05 + 0.3 * f)
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2 + 3 * f));
      }
      piece(geo.px(poly.at(d)), true, glow: 0.9, lift: math.sin(math.pi * u) * 0.7);
    }
    if (done) {
      final k = ((t - _pick - _ride) / _hold).clamp(0.0, 1.0);
      canvas.drawCircle(
          target,
          geo.cell * (0.3 + 0.9 * k),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(0.5, 3.5 * (1 - k))
            ..color = Lux.goldLight.withValues(alpha: 0.85 * (1 - k)));
      piece(target, true);
    }
  }

  @override
  bool shouldRepaint(_LoopDemoPainter old) => true;
}
