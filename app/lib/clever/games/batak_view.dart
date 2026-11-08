import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../card_kit.dart';
import '../core_bridge.dart';
import '../lux.dart';

/// İhaleli Batak table: you (South) against three AI opponents.
///
/// Layout: a green felt with a gold rim; opponents left (Kerem), top (Selin), right (Murat) with
/// name medallions, bid / trick counters and a breathing "thinking" glow; the trick in the centre;
/// your hand fanned along the bottom. Drag a card up onto the felt to play it (the felt rim glows
/// gold for a legal card, bordeaux for an illegal one; a refused card flies back), or tap a card
/// to lift it and tap it again to play.
///
/// The view mirrors core events (`last_action`, numbered by `serial`): played cards fly in from
/// their seat (or from where you dropped them), a finished trick holds for a moment with the
/// winning card glowing and then sweeps to the winner; bids show as bubbles at the seat; a new
/// deal flies your cards in from the centre. AI turns are requested with
/// `session.actAsync({'ai': true})` (off the UI isolate) after the animations settle plus a
/// human-feeling pause of 500–900 ms.
///
/// The eye toggle ("Açık oyna") shows every hand as a small fan and the AI's "Neden?" lines; the
/// score pill opens the score sheet.
Widget batakView(BuildContext context, GameSession s) => _BatakTable(key: ObjectKey(s), session: s);

const _names = ['Sen', 'Kerem', 'Selin', 'Murat'];
const _suitOrder = [0, 1, 3, 2]; // maça, kupa, sinek, karo: alternating colours in the hand
const _feltA = Color(0xFF1D6B4C);
const _feltB = Color(0xFF0B3B29);
const _feltC = Color(0xFF062417);

int _int(Object? v, [int d = 0]) => (v as num?)?.toInt() ?? d;
int _cid(int s, int r) => s * 13 + r - 2;

class _C {
  final int s, r;
  const _C(this.s, this.r);
  int get id => _cid(s, r);
  static _C? of(Object? v) {
    if (v is List && v.length == 2) return _C(_int(v[0]), _int(v[1]));
    return null;
  }

  static List<_C> list(Object? v) => [
        if (v is List)
          for (final e in v)
            if (of(e) case final c?) c
      ];
}

/// A card on the table (trick area).
class _TC {
  final _C c;
  final int seat;
  final Offset from;
  _TC(this.c, this.seat, this.from);
}

class _Geo {
  final Size size;
  final Rect felt;
  final double handW, handH, tableW, tableH, miniW, miniH;
  final Offset center;
  _Geo(this.size, this.felt, this.handW, this.handH, this.tableW, this.tableH, this.miniW, this.miniH, this.center);

  static const topBar = 48.0;

  factory _Geo.fit(Size sz) {
    final handW = math.min(sz.width / 5.3, sz.height * 0.15 * CardKit.aspect);
    final handH = handW / CardKit.aspect;
    final felt = Rect.fromLTRB(4, topBar, sz.width - 4, sz.height - handH - 26);
    final tableW = math.min(felt.width * 0.19, felt.height * 0.17 * CardKit.aspect);
    final miniW = math.min(30.0, felt.width * 0.075);
    return _Geo(sz, felt, handW, handH, tableW, tableW / CardKit.aspect, miniW, miniW / CardKit.aspect,
        Offset(felt.center.dx, felt.center.dy + felt.height * 0.02));
  }

  double get handTop => size.height - handH - 16;

  /// Where a seat's cards live (AI: centre of its mini fan; you: the hand).
  Offset seatAnchor(int seat) => switch (seat) {
        0 => Offset(size.width / 2, handTop + handH * 0.4),
        1 => Offset(felt.left + 30, felt.center.dy - 10),
        2 => Offset(felt.center.dx + 24, felt.top + 34),
        _ => Offset(felt.right - 30, felt.center.dy - 10),
      };

  /// Medallion centre of a seat.
  Offset medal(int seat) => switch (seat) {
        0 => Offset(felt.left + 38, felt.bottom - 66),
        1 => Offset(felt.left + 36, felt.center.dy - 158),
        2 => Offset(felt.center.dx - 112, felt.top + 40),
        _ => Offset(felt.right - 36, felt.center.dy - 158),
      };

  Offset slot(int seat) => switch (seat) {
        0 => center + Offset(0, tableH * 0.44),
        1 => center + Offset(-tableW * 0.72, 0),
        2 => center + Offset(0, -tableH * 0.44),
        _ => center + Offset(tableW * 0.72, 0),
      };

  static double slotAngle(int seat) => const [0.03, -0.14, 0.05, 0.12][seat];
}

class _BatakTable extends StatefulWidget {
  final GameSession session;
  const _BatakTable({super.key, required this.session});

  @override
  State<_BatakTable> createState() => _BatakTableState();
}

class _BatakTableState extends State<_BatakTable> with TickerProviderStateMixin {
  GameSession get s => widget.session;
  Map<String, dynamic> get st => s.state;

  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;
  final _rand = math.Random();

  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300));
  late final AnimationController _back = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));

  _Geo? _geo;

  // Event mirror.
  int _seenSerial = -1;
  int _handNo = 0;
  final List<_TC> _table = [];
  int? _sweepWinner; // trick sweeping (or about to) to this seat
  bool _sweeping = false;
  int _winnerCardId = -1;
  int _trickSeq = 0; // bumps whenever the table display is reset, so stale sweep timers skip
  double _busyUntil = 0;
  final Map<int, (String, double)> _bubbles = {};
  final Map<int, Offset> _flyFrom = {};
  int _gen = 0;

  // Input.
  int? _selected;
  int? _dragId;
  Offset _drag = Offset.zero;
  Offset _backFrom = Offset.zero;
  int? _backId;
  bool _overTable = false;

  // AI pacing.
  bool _aiBusy = false;
  int? _thinkingSeat;
  bool _hintBusy = false;

  // Open play.
  bool _open = false;

  @override
  void initState() {
    super.initState();
    _seenSerial = _int(st['serial']);
    _handNo = _int(st['hand_no']);
    _syncTable(force: true);
    s.addListener(_onSession);
    _back.addListener(() => setState(() {}));
    _back.addStatusListener((a) {
      if (a == AnimationStatus.completed) setState(() => _backId = null);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeScheduleAi());
  }

  @override
  void dispose() {
    _gen++;
    s.removeListener(_onSession);
    _pulse.dispose();
    _back.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------------------------
  // Events

  void _onSession() {
    if (!mounted) return;
    final serial = _int(st['serial']);
    if (serial != _seenSerial) {
      _seenSerial = serial;
      _onEvent(st['last_action'] as Map?);
      // Panels (bid, trump, summary) appear once the animations have settled.
      if (_busyUntil > _now) _at(_busyUntil + 0.02, () {});
    }
    setState(() {});
    _maybeScheduleAi();
  }

  void _at(double t, VoidCallback f) {
    final g = _gen;
    final ms = ((t - _now) * 1000).clamp(0, 10000).round();
    Future.delayed(Duration(milliseconds: ms), () {
      if (!mounted || g != _gen) return;
      setState(f);
    });
  }

  void _onEvent(Map? ev) {
    final now = _now;
    if (ev == null) return;
    final kind = ev['kind'] as String? ?? '';
    final seat = _int(ev['seat']);
    final handNo = _int(st['hand_no']);
    if (kind == 'deal' || handNo != _handNo) {
      _handNo = handNo;
      _gen++;
      _trickSeq++;
      _table.clear();
      _sweepWinner = null;
      _sweeping = false;
      _selected = null;
      _bubbles.clear();
      _busyUntil = now + 0.4 + 13 * 0.055;
      return;
    }
    switch (kind) {
      case 'bid':
      case 'pass':
        _bubbles[seat] = (kind == 'pass' ? 'Pas' : '${_int(ev['bid'])}', now + 1.5);
        _busyUntil = math.max(_busyUntil, now + 0.35);
        if (seat != 0) HapticFeedback.selectionClick();
        _at(now + 1.55, () {});
      case 'trump':
        final t = _int(ev['trump']);
        _bubbles[seat] = ('Koz ${CardKit.suitNames[t]}', now + 1.8);
        _busyUntil = math.max(_busyUntil, now + 0.6);
        HapticFeedback.lightImpact();
        _at(now + 1.85, () {});
      case 'play':
        final c = _C.of(ev['card']);
        if (c == null) return;
        final g = _geo;
        final from = _flyFrom.remove(c.id) ?? g?.seatAnchor(seat) ?? Offset.zero;
        // A sweep still pending from the previous trick: finish it now.
        if (_sweepWinner != null) {
          _table.clear();
          _sweepWinner = null;
          _sweeping = false;
          _trickSeq++;
        }
        _table.add(_TC(c, seat, from));
        if (seat != 0) HapticFeedback.selectionClick();
        final w = ev['trick_winner'];
        if (w != null) {
          final winner = _int(w);
          _sweepWinner = winner;
          final lt = st['last_trick'] as Map?;
          _winnerCardId = -1;
          for (final e in (lt?['cards'] as List? ?? const [])) {
            if (_int((e as Map)['seat']) == winner) _winnerCardId = _C.of(e['card'])?.id ?? -1;
          }
          final land = now + 0.34;
          final seq = _trickSeq;
          _at(land + 0.05, () {
            if (winner == 0) HapticFeedback.lightImpact();
          });
          _at(land + 0.8, () {
            if (seq == _trickSeq) _sweeping = true;
          });
          _at(land + 0.8 + 0.46, () {
            if (seq != _trickSeq) return;
            _table.clear();
            _sweepWinner = null;
            _sweeping = false;
            _trickSeq++;
          });
          _busyUntil = land + 0.8 + 0.5;
        } else {
          _busyUntil = math.max(_busyUntil, now + 0.36);
        }
      default:
        break;
    }
  }

  /// When nothing is animating, the table shows exactly the core's trick.
  void _syncTable({bool force = false}) {
    if (_sweepWinner != null && !force) return;
    final g = _geo;
    final cards = (st['trick'] as Map?)?['cards'] as List? ?? const [];
    final want = [for (final e in cards) (_C.of((e as Map)['card'])!, _int(e['seat']))];
    final same = want.length == _table.length &&
        [for (var i = 0; i < want.length; i++) want[i].$1.id == _table[i].c.id].every((x) => x);
    if (same) return;
    _table
      ..clear()
      ..addAll([for (final (c, seat) in want) _TC(c, seat, g?.slot(seat) ?? Offset.zero)]);
  }

  // -------------------------------------------------------------------------------------------
  // AI pacing

  void _maybeScheduleAi() {
    if (!mounted || _aiBusy || s.finished || st['ai_pending'] != true) return;
    _aiBusy = true;
    final seat = _int(st['seat']);
    final wait = math.max(0.0, _busyUntil - _now);
    final pause = 0.5 + _rand.nextDouble() * 0.4;
    final session = s;
    final g = _gen;
    Future.delayed(Duration(milliseconds: (wait * 1000).round()), () {
      if (!mounted || !identical(session, s)) return;
      setState(() => _thinkingSeat = seat);
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    });
    Future.delayed(Duration(milliseconds: ((wait + pause) * 1000).round()), () async {
      if (!mounted || !identical(session, s)) return;
      if (g != _gen && st['ai_pending'] != true) {
        setState(() => _aiBusy = false);
        return;
      }
      // Animations may have been extended meanwhile (e.g. the trick sweep).
      final more = _busyUntil - _now;
      if (more > 0) await Future.delayed(Duration(milliseconds: (more * 1000).round()));
      if (!mounted) return;
      if (st['ai_pending'] != true) {
        setState(() {
          _aiBusy = false;
          _thinkingSeat = null;
        });
        return;
      }
      final ok = await s.actAsync({'ai': true});
      if (!mounted) return;
      setState(() {
        _aiBusy = false;
        _thinkingSeat = null;
      });
      _pulse.stop();
      if (ok) WidgetsBinding.instance.addPostFrameCallback((_) => _maybeScheduleAi());
    });
  }

  // -------------------------------------------------------------------------------------------
  // Player actions

  bool get _yourTurn => !s.finished && st['turn'] == 'you' && !_aiBusy && st['phase'] != 'summary';
  bool get _yourPlay => _yourTurn && st['phase'] == 'play';

  Set<int> get _legal => {for (final c in _C.list(st['legal'])) c.id};

  void _play(_C c, Offset from) {
    if (!_yourPlay) return;
    // Let the previous trick finish sweeping first; the card waits lifted in the hand.
    final wait = _busyUntil - _now;
    if (wait > 0.05) {
      final g = _gen;
      setState(() => _selected = c.id);
      Future.delayed(Duration(milliseconds: (wait * 1000).round() + 10), () {
        if (mounted && g == _gen && _selected == c.id) _play(c, from);
      });
      return;
    }
    _flyFrom[c.id] = from;
    final ok = s.act({
      'play': [c.s, c.r]
    });
    if (ok) {
      HapticFeedback.selectionClick();
      _selected = null;
    } else {
      _flyFrom.remove(c.id);
      HapticFeedback.mediumImpact();
    }
  }

  void _bid(int n) {
    if (!_yourTurn) return;
    HapticFeedback.selectionClick();
    s.act({'bid': n});
  }

  void _trump(int t) {
    if (!_yourTurn) return;
    HapticFeedback.selectionClick();
    s.act({'trump': t});
  }

  Future<void> _hint() async {
    if (!_yourTurn || _hintBusy) return;
    setState(() => _hintBusy = true);
    await s.actAsync({'hint': true});
    if (mounted) setState(() => _hintBusy = false);
  }

  // -------------------------------------------------------------------------------------------
  // Build

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, cons) {
      final g = _Geo.fit(cons.biggest);
      _geo = g;
      _syncTable();
      final now = _now;
      final phase = st['phase'] as String? ?? 'bid';
      final hands = [for (var i = 0; i < 4; i++) _C.list((st['hands'] as List?)?[i])];
      final children = <Widget>[
        Positioned.fromRect(rect: g.felt, child: _Felt(glow: _dragId != null && _overTable ? (_dragLegal ? 1 : -1) : 0)),
        Positioned(left: 8, right: 8, top: 4, height: _Geo.topBar - 8, child: _topBar(phase)),
        for (final seat in [1, 2, 3]) ..._seat(g, seat, hands[seat], now),
        _southMedal(g),
        ..._tableCards(g),
        ..._bubbleWidgets(g, now),
        if (_centerPanel(g, phase, now) case final w?) w,
        _bottomInfo(g, phase),
        ..._hand(g, hands[0], now),
      ];
      return Stack(clipBehavior: Clip.none, children: children);
    });
  }

  // ---- Top bar --------------------------------------------------------------------------------

  Widget _topBar(String phase) {
    final scores = [for (var i = 0; i < 4; i++) _int((st['scores'] as List?)?[i])];
    final rank = 1 + scores.where((x) => x > scores[0]).length;
    final trump = st['trump'];
    final decl = st['declarer'];
    return Row(
      children: [
        _Pill(
          onTap: _showSheet,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.leaderboard_rounded, size: 16, color: Lux.gold),
            const SizedBox(width: 6),
            Text('${scores[0]}', style: Lux.numeral(18)),
            const SizedBox(width: 4),
            Text('$rank.', style: Lux.ui(12, color: Lux.muted)),
          ]),
        ),
        const SizedBox(width: 6),
        _Pill(
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text('Koz', style: Lux.ui(12, color: Lux.muted)),
            const SizedBox(width: 6),
            if (trump == null)
              Text('—', style: Lux.ui(14, color: Lux.muted))
            else
              _SuitIcon(_int(trump), size: 18, onDark: true),
          ]),
        ),
        const SizedBox(width: 6),
        if (decl != null)
          Flexible(
            child: _Pill(
              child: Text('${_names[_int(decl)]} · ${_int(st['contract'])}',
                  overflow: TextOverflow.ellipsis, style: Lux.ui(13, color: Lux.goldLight)),
            ),
          )
        else
          const Spacer(),
        if (decl != null) const Spacer(),
        _ToolButton(
          icon: _open ? Icons.visibility_rounded : Icons.visibility_off_rounded,
          tooltip: 'Açık oyna',
          active: _open,
          onTap: () => setState(() => _open = !_open),
        ),
        const SizedBox(width: 6),
        _ToolButton(
          icon: Icons.lightbulb_outline_rounded,
          tooltip: 'İpucu',
          busy: _hintBusy,
          onTap: _yourTurn ? _hint : null,
        ),
      ],
    );
  }

  // ---- Seats ----------------------------------------------------------------------------------

  List<Widget> _seat(_Geo g, int seat, List<_C> hand, double now) {
    final count = _int((st['counts'] as List?)?[seat]);
    final out = <Widget>[];
    // Mini hand: backs, or faces in open play.
    final cards = _open ? _sorted(hand) : List.generate(count, (_) => null);
    final n = cards.length;
    final vertical = seat != 2;
    final a = g.seatAnchor(seat);
    final step = vertical ? g.miniH * 0.27 : g.miniW * 0.42;
    final span = n <= 1 ? 0.0 : step * (n - 1);
    for (var i = 0; i < n; i++) {
      final c = cards[i];
      final off = -span / 2 + i * step;
      final center = vertical ? Offset(a.dx, a.dy + off) : Offset(a.dx + off, a.dy);
      out.add(Positioned(
        key: ValueKey('m$seat-$i'),
        left: center.dx - g.miniW / 2,
        top: center.dy - g.miniH / 2,
        width: g.miniW,
        height: g.miniH,
        child: IgnorePointer(
          child: c == null
              ? const PlayingCard.back()
              : PlayingCard(suit: c.s, rank: c.r),
        ),
      ));
    }
    out.add(_medalFor(g, seat, now));
    return out;
  }

  Widget _medalFor(_Geo g, int seat, double now) {
    final m = g.medal(seat);
    final thinking = _thinkingSeat == seat && _aiBusy;
    const w = 78.0;
    return Positioned(
      left: m.dx - w / 2,
      top: m.dy - 30,
      width: w,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (context, _) => _SeatMedal(
            name: _names[seat],
            glyph: _names[seat][0],
            breath: thinking ? _pulse.value : 0,
            thinking: thinking,
            badges: _badges(seat),
            declarer: st['declarer'] != null && _int(st['declarer']) == seat,
            dealer: _int(st['dealer']) == seat,
          ),
        ),
      ),
    );
  }

  List<String> _badges(int seat) {
    final phase = st['phase'];
    final bids = st['bids'] as List? ?? const [];
    final b = bids.length > seat ? bids[seat] : null;
    final tricks = _int((st['tricks'] as List?)?[seat]);
    final out = <String>[];
    if (phase == 'bid') {
      if (b != null) out.add(_int(b) == 0 ? 'Pas' : '${_int(b)}');
    } else {
      final decl = st['declarer'] != null && _int(st['declarer']) == seat;
      out.add(decl ? '$tricks/${_int(st['contract'])}' : '$tricks el');
    }
    return out;
  }

  Widget _southMedal(_Geo g) => _medalFor(g, 0, _now);

  // ---- Table ----------------------------------------------------------------------------------

  List<Widget> _tableCards(_Geo g) {
    final sweepTo = _sweeping && _sweepWinner != null ? g.medal(_sweepWinner!) : null;
    final full = _sweepWinner != null && _table.length == 4;
    return [
      for (final t in _table)
        _TableCard(
          key: ValueKey('t${t.c.id}'),
          suit: t.c.s,
          rank: t.c.r,
          from: t.from,
          to: g.slot(t.seat),
          width: g.tableW,
          angle: _Geo.slotAngle(t.seat),
          sweepTo: sweepTo,
          glow: full && t.c.id == _winnerCardId,
        ),
    ];
  }

  List<Widget> _bubbleWidgets(_Geo g, double now) {
    final out = <Widget>[];
    for (final e in _bubbles.entries) {
      if (e.value.$2 < now) continue;
      final m = g.medal(e.key);
      final dx = switch (e.key) { 1 => 44.0, 3 => -44.0, 2 => 0.0, _ => 30.0 };
      final dy = switch (e.key) { 2 => 44.0, 0 => -48.0, _ => 42.0 };
      out.add(Positioned(
        key: ValueKey('b${e.key}-${e.value.$1}'),
        left: m.dx + dx - 60,
        top: m.dy + dy - 16,
        width: 120,
        child: IgnorePointer(child: Center(child: _Bubble(e.value.$1))),
      ));
    }
    return out;
  }

  // ---- Centre panels (bid, trump, summary, status) ----------------------------------------------

  Widget? _centerPanel(_Geo g, String phase, double now) {
    final w = math.min(g.felt.width * 0.72, 330.0);
    Widget at(Widget child, {double dy = 0}) => Positioned(
          left: g.center.dx - w / 2,
          top: g.center.dy - 100 + dy,
          width: w,
          child: child,
        );
    if (phase == 'summary' && st['hand_result'] is Map && now >= _busyUntil) {
      return Positioned(
        left: g.center.dx - (w + 40) / 2,
        top: g.felt.top + 112,
        width: w + 40,
        child: _SummaryPanel(
          st: st,
          onNext: st['match_over'] == true ? null : () => s.act({'next': true}),
        ),
      );
    }
    if (phase == 'bid' && _yourTurn && now >= _busyUntil) {
      return at(_BidPanel(
        options: [for (final o in (st['bid_options'] as List? ?? const [])) _int(o)],
        canPass: st['can_pass'] == true,
        high: _int(st['high_bid']),
        highSeat: st['high_seat'] == null ? null : _int(st['high_seat']),
        hint: _hintBid,
        onBid: _bid,
      ));
    }
    if (phase == 'trump' && _yourTurn && now >= _busyUntil) {
      final hand = _C.list((st['hands'] as List?)?[0]);
      return at(_TrumpPanel(
        counts: [for (var s = 0; s < 4; s++) hand.where((c) => c.s == s).length],
        hint: _hintTrump,
        onPick: _trump,
      ));
    }
    if ((phase == 'bid' || phase == 'trump') && !_yourTurn) {
      final seat = _int(st['seat']);
      final high = _int(st['high_bid']);
      final hs = st['high_seat'];
      final line = phase == 'trump'
          ? '${_names[seat]} kozu seçiyor…'
          : hs == null
              ? 'İhale: ${_names[seat]} düşünüyor…'
              : 'En yüksek: ${_names[_int(hs)]} $high';
      return Positioned(
        left: g.center.dx - w / 2,
        top: g.center.dy - 22,
        width: w,
        child: IgnorePointer(
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.28),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: Lux.line),
              ),
              child: Text(line, style: Lux.ui(15, color: Lux.goldLight)),
            ),
          ),
        ),
      );
    }
    return null;
  }

  int? get _hintBid {
    final h = st['hint'];
    if (h is Map && (h['kind'] == 'bid' || h['kind'] == 'pass')) return _int(h['bid']);
    return null;
  }

  int? get _hintTrump {
    final h = st['hint'];
    if (h is Map && h['kind'] == 'trump') return _int(h['trump']);
    return null;
  }

  int? get _hintCard {
    final h = st['hint'];
    if (h is Map && h['kind'] == 'play') return _C.of(h['card'])?.id;
    return null;
  }

  // ---- Bottom info: whose turn, hint text, "Neden?" lines ---------------------------------------

  Widget _bottomInfo(_Geo g, String phase) {
    final lines = <Widget>[];
    final hint = st['hint'];
    if (hint is Map && _yourTurn) {
      lines.add(_InfoBox(
        icon: Icons.lightbulb_rounded,
        text: hint['text'] as String? ?? '',
        gold: true,
      ));
    }
    if (_open) {
      final reasons = st['reasons'] as List? ?? const [];
      final last = st['last_action'] as Map?;
      final lastSeat = last == null ? -1 : _int(last['seat']);
      final rs = <(int, String)>[
        for (final seat in [1, 2, 3])
          if (reasons.length > seat && reasons[seat] is String) (seat, reasons[seat] as String),
      ];
      if (rs.isNotEmpty) {
        lines.add(_WhyBox(entries: rs, latest: lastSeat));
      }
    }
    if (lines.isEmpty && phase == 'play' && _yourPlay && _table.length < 4) {
      lines.add(Center(
        child: Text('Sıra sende: kartı masaya sürükle ya da iki kez dokun',
            textAlign: TextAlign.center, style: Lux.ui(13, color: Lux.goldLight.withValues(alpha: 0.85))),
      ));
    }
    return Positioned(
      left: g.felt.left + 82,
      right: g.felt.right > 0 ? g.size.width - g.felt.right + 8 : 8,
      bottom: g.size.height - g.felt.bottom + 8,
      child: IgnorePointer(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final l in lines) Padding(padding: const EdgeInsets.only(top: 4), child: l),
        ]),
      ),
    );
  }

  // ---- Your hand ------------------------------------------------------------------------------

  List<_C> _sorted(List<_C> h) {
    final v = [...h];
    v.sort((a, b) {
      final sa = _suitOrder.indexOf(a.s), sb = _suitOrder.indexOf(b.s);
      return sa != sb ? sa - sb : b.r - a.r;
    });
    return v;
  }

  bool get _dragLegal => _dragId != null && _legal.contains(_dragId);

  List<Widget> _hand(_Geo g, List<_C> raw, double now) {
    final hand = _sorted(raw);
    final n = hand.length;
    if (n == 0) return const [];
    final cw = g.handW, ch = g.handH;
    final avail = g.size.width - 26;
    final step = n > 1 ? math.min(cw * 0.66, (avail - cw) / (n - 1)) : 0.0;
    final total = cw + step * (n - 1);
    final x0 = (g.size.width - total) / 2;
    final legal = _legal;
    final yourPlay = _yourPlay;
    final hintId = _hintCard;
    final deck = g.center;
    final widgets = <(int, Widget)>[];
    for (var i = 0; i < n; i++) {
      final c = hand[i];
      final d = i - (n - 1) / 2;
      final lifted = c.id == _selected;
      final x = x0 + i * step;
      final y = g.handTop + d * d * 0.28 - (lifted ? ch * 0.2 : 0);
      final angle = d * 0.017;
      final dim = yourPlay && !legal.contains(c.id);
      final glow = (yourPlay && lifted) || c.id == hintId;
      var offset = Offset.zero;
      if (c.id == _dragId) offset = _drag;
      if (c.id == _backId) offset = _backFrom * (1 - Curves.easeOutBack.transform(_back.value));
      final slotCenter = Offset(x + cw / 2, y + ch / 2);
      final dealDelay = 55 * i;
      final dealDur = 380 + dealDelay;
      final card = TweenAnimationBuilder<double>(
        key: ValueKey('deal$_handNo'),
        tween: Tween(begin: 0, end: 1),
        duration: Duration(milliseconds: dealDur),
        curve: Interval(dealDelay / dealDur, 1, curve: Curves.easeOutCubic),
        builder: (context, t, child) => Transform.translate(
          offset: (deck - slotCenter) * (1 - t),
          child: Transform.rotate(angle: angle + (1 - t) * 0.8, child: child),
        ),
        child: PlayingCard(suit: c.s, rank: c.r, dim: dim, highlight: glow),
      );
      widgets.add((
        c.id == _dragId || c.id == _backId ? 1000 : i,
        AnimatedPositioned(
          key: ValueKey('h${c.id}'),
          duration: Duration(milliseconds: c.id == _dragId ? 0 : 200),
          curve: Curves.easeOutCubic,
          left: x,
          top: y,
          width: cw,
          height: ch,
          child: Transform.translate(
            offset: offset,
            child: Transform.scale(
              scale: c.id == _dragId ? 1.12 : 1,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _tapCard(c, slotCenter),
                onPanStart: (_) => _dragStart(c),
                onPanUpdate: (u) => _dragUpdate(u.delta, g, slotCenter),
                onPanEnd: (_) => _dragEnd(c, slotCenter),
                onPanCancel: () => _dragEnd(c, slotCenter, cancel: true),
                child: card,
              ),
            ),
          ),
        ),
      ));
    }
    widgets.sort((a, b) => a.$1 - b.$1);
    return [for (final w in widgets) w.$2];
  }

  void _tapCard(_C c, Offset center) {
    if (!_yourPlay) {
      if (_yourTurn) return;
      return;
    }
    if (_selected == c.id) {
      _play(c, center + const Offset(0, -20));
    } else {
      HapticFeedback.selectionClick();
      setState(() => _selected = c.id);
    }
  }

  void _dragStart(_C c) {
    if (!_yourPlay) return;
    setState(() {
      _dragId = c.id;
      _drag = Offset.zero;
      _selected = c.id;
      _overTable = false;
    });
  }

  void _dragUpdate(Offset delta, _Geo g, Offset center) {
    if (_dragId == null) return;
    setState(() {
      _drag += delta;
      final p = center + _drag;
      final over = p.dy < g.handTop - g.handH * 0.05;
      if (over != _overTable) {
        _overTable = over;
        HapticFeedback.selectionClick();
      }
    });
  }

  void _dragEnd(_C c, Offset center, {bool cancel = false}) {
    if (_dragId != c.id) return;
    final drop = center + _drag;
    final over = _overTable && !cancel;
    final legal = _legal.contains(c.id);
    setState(() {
      _dragId = null;
      _overTable = false;
    });
    if (over && legal) {
      _play(c, drop);
      _drag = Offset.zero;
      return;
    }
    if (over && !legal) {
      // Let the core explain why (toast), then fly back.
      _play(c, drop);
    }
    _backFrom = _drag;
    _backId = c.id;
    _drag = Offset.zero;
    _back.forward(from: 0);
  }

  // ---- Score sheet ----------------------------------------------------------------------------

  void _showSheet() {
    HapticFeedback.selectionClick();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => ListenableBuilder(
        listenable: s,
        builder: (context, _) => _ScoreSheet(st: s.state),
      ),
    );
  }
}

// =================================================================================================
// Widgets

class _Felt extends StatelessWidget {
  final int glow; // 1 legal drop, -1 illegal, 0 none
  const _Felt({required this.glow});

  @override
  Widget build(BuildContext context) {
    final rim = glow > 0 ? Lux.goldLight : (glow < 0 ? Lux.bordeauxLight : Lux.gold);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        gradient: const RadialGradient(
          center: Alignment(0, -0.15),
          radius: 0.95,
          colors: [_feltA, _feltB, _feltC],
          stops: [0, 0.65, 1],
        ),
        border: Border.all(color: rim.withValues(alpha: glow == 0 ? 0.85 : 1), width: glow == 0 ? 2.2 : 3),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.55), blurRadius: 24, offset: const Offset(0, 10)),
          if (glow != 0) BoxShadow(color: rim.withValues(alpha: 0.45), blurRadius: 26),
        ],
      ),
      child: Stack(children: [
        Positioned.fill(
          child: Container(
            margin: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(25),
              border: Border.all(color: Lux.gold.withValues(alpha: 0.22)),
            ),
          ),
        ),
        Positioned.fill(child: CustomPaint(painter: _FeltPainter())),
      ]),
    );
  }
}

/// Faint woven felt texture plus a gold ring around the trick area.
class _FeltPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = math.Random(3);
    final p = Paint()..color = Colors.white.withValues(alpha: 0.018);
    for (var i = 0; i < 900; i++) {
      canvas.drawCircle(Offset(r.nextDouble() * size.width, r.nextDouble() * size.height), 0.7, p);
    }
    final c = Offset(size.width / 2, size.height * 0.52);
    final rr = math.min(size.width, size.height) * 0.3;
    canvas.drawCircle(
        c,
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Lux.gold.withValues(alpha: 0.13));
    canvas.drawCircle(
        c,
        rr * 0.93,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6
          ..color = Lux.gold.withValues(alpha: 0.08));
  }

  @override
  bool shouldRepaint(_FeltPainter old) => false;
}

class _Pill extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  const _Pill({required this.child, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: Lux.cardDeep.withValues(alpha: 0.9),
            border: Border.all(color: onTap != null ? Lux.gold.withValues(alpha: 0.6) : Lux.line),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active, busy;
  const _ToolButton({required this.icon, required this.tooltip, this.onTap, this.active = false, this.busy = false});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? Lux.gold.withValues(alpha: 0.22) : Lux.card,
              border: Border.all(color: Lux.gold.withValues(alpha: enabled ? (active ? 1 : 0.6) : 0.2)),
            ),
            child: busy
                ? const Padding(
                    padding: EdgeInsets.all(10),
                    child: CircularProgressIndicator(strokeWidth: 2, color: Lux.gold),
                  )
                : Icon(icon, size: 20, color: enabled ? (active ? Lux.goldLight : Lux.gold) : Lux.muted.withValues(alpha: 0.4)),
          ),
        ),
      ),
    );
  }
}

class _SuitIcon extends StatelessWidget {
  final int suit;
  final double size;
  final bool onDark;
  const _SuitIcon(this.suit, {this.size = 20, this.onDark = false});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _SuitPainter(suit, onDark)),
      );
}

class _SuitPainter extends CustomPainter {
  final int suit;
  final bool onDark;
  _SuitPainter(this.suit, this.onDark);

  @override
  void paint(Canvas canvas, Size size) {
    final col = onDark ? (CardKit.isRed(suit) ? const Color(0xFFFF8098) : Lux.ink) : CardKit.suitColor(suit);
    canvas.drawPath(CardKit.suitPath(suit, size.center(Offset.zero), size.width), Paint()..color = col);
  }

  @override
  bool shouldRepaint(_SuitPainter old) => old.suit != suit || old.onDark != onDark;
}

class _SeatMedal extends StatelessWidget {
  final String name, glyph;
  final double breath;
  final bool thinking, declarer, dealer;
  final List<String> badges;
  const _SeatMedal({
    required this.name,
    required this.glyph,
    required this.breath,
    required this.thinking,
    required this.badges,
    required this.declarer,
    required this.dealer,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  if (thinking) BoxShadow(color: Lux.goldLight.withValues(alpha: 0.25 + 0.45 * breath), blurRadius: 10 + 16 * breath, spreadRadius: 1 + 3 * breath),
                ],
              ),
              child: Monogram(glyph, size: 46, tint: declarer ? const Color(0xFF8E1F3C) : const Color(0xFF2E4A8F)),
            ),
            if (declarer)
              Positioned(
                top: -9,
                child: Icon(Icons.workspace_premium_rounded, size: 18, color: Lux.goldLight, shadows: [Shadow(color: Colors.black.withValues(alpha: 0.6), blurRadius: 4)]),
              ),
            if (dealer)
              Positioned(
                right: -2,
                bottom: -2,
                child: Container(
                  width: 17,
                  height: 17,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: Lux.cardDeep, border: Border.all(color: Lux.gold)),
                  child: Text('D', style: Lux.ui(9, color: Lux.goldLight, weight: FontWeight.w700)),
                ),
              ),
          ],
        ),
        const SizedBox(height: 3),
        Text(thinking ? '$name…' : name,
            style: Lux.ui(12.5, color: thinking ? Lux.goldLight : Lux.ink, weight: FontWeight.w600)),
        for (final b in badges)
          Container(
            margin: const EdgeInsets.only(top: 2),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: Colors.black.withValues(alpha: 0.35),
              border: Border.all(color: Lux.line),
            ),
            child: Text(b, style: Lux.ui(11.5, color: Lux.goldLight)),
          ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  final String text;
  const _Bubble(this.text);

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutBack,
      builder: (context, t, child) => Transform.scale(scale: 0.6 + 0.4 * t, child: Opacity(opacity: t.clamp(0, 1), child: child)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: text == 'Pas' ? null : Lux.foil,
          color: text == 'Pas' ? Lux.cardDeep : null,
          border: Border.all(color: Lux.gold),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 10, offset: const Offset(0, 4))],
        ),
        child: Text(text, style: Lux.ui(15, color: text == 'Pas' ? Lux.goldLight : const Color(0xFF2A1D05), weight: FontWeight.w700)),
      ),
    );
  }
}

/// A card on the felt: flies in from its seat, glows if it wins, then sweeps to the winner.
class _TableCard extends StatefulWidget {
  final int suit, rank;
  final Offset from, to;
  final double width, angle;
  final Offset? sweepTo;
  final bool glow;
  const _TableCard({
    super.key,
    required this.suit,
    required this.rank,
    required this.from,
    required this.to,
    required this.width,
    required this.angle,
    required this.sweepTo,
    required this.glow,
  });

  @override
  State<_TableCard> createState() => _TableCardState();
}

class _TableCardState extends State<_TableCard> with TickerProviderStateMixin {
  late final AnimationController _fly = AnimationController(vsync: this, duration: const Duration(milliseconds: 330));
  late final AnimationController _sweep = AnimationController(vsync: this, duration: const Duration(milliseconds: 440));
  Offset? _sweepTo;

  @override
  void initState() {
    super.initState();
    if ((widget.from - widget.to).distanceSquared < 1) {
      _fly.value = 1;
    } else {
      _fly.forward();
    }
    if (widget.sweepTo != null) {
      _sweepTo = widget.sweepTo;
      _sweep.forward();
    }
  }

  @override
  void didUpdateWidget(_TableCard old) {
    super.didUpdateWidget(old);
    if (widget.sweepTo != null && _sweepTo == null) {
      _sweepTo = widget.sweepTo;
      _sweep.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _fly.dispose();
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.width, h = w / CardKit.aspect;
    return AnimatedBuilder(
      animation: Listenable.merge([_fly, _sweep]),
      builder: (context, child) {
        final f = Curves.easeOutCubic.transform(_fly.value);
        final sw = Curves.easeInCubic.transform(_sweep.value);
        // A slight arc while flying in.
        final base = Offset.lerp(widget.from, widget.to, f)! + Offset(0, -math.sin(math.pi * f) * h * 0.18);
        final p = _sweepTo == null ? base : Offset.lerp(base, _sweepTo, sw)!;
        final scale = (1.08 - 0.08 * f) * (1 - 0.55 * sw);
        final angle = widget.angle * f + (1 - f) * 0.5;
        return Positioned(
          left: p.dx - w / 2,
          top: p.dy - h / 2,
          width: w,
          height: h,
          child: IgnorePointer(
            child: Opacity(
              opacity: (1 - sw * 0.9).clamp(0, 1),
              child: Transform.rotate(angle: angle, child: Transform.scale(scale: scale, child: child)),
            ),
          ),
        );
      },
      child: PlayingCard(suit: widget.suit, rank: widget.rank, highlight: widget.glow),
    );
  }
}

class _BidPanel extends StatelessWidget {
  final List<int> options;
  final bool canPass;
  final int high;
  final int? highSeat;
  final int? hint;
  final ValueChanged<int> onBid;
  const _BidPanel({required this.options, required this.canPass, required this.high, required this.highSeat, required this.hint, required this.onBid});

  @override
  Widget build(BuildContext context) {
    final min = options.isEmpty ? 14 : options.first;
    final sub = highSeat == null
        ? (canPass ? 'Henüz ihale yok · en az 4' : 'Herkes pas dedi: dağıtan olarak en az 4 almalısın')
        : 'En yüksek: ${_names[highSeat!]} $high · sen en az $min';
    return _Panel(
      title: 'İhale',
      subtitle: sub,
      child: Column(
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              for (var n = 4; n <= 13; n++)
                _NumButton(
                  label: '$n',
                  enabled: options.contains(n),
                  hinted: hint == n,
                  onTap: () => onBid(n),
                ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: _NumButton(label: 'Pas', wide: true, enabled: canPass, hinted: hint == 0, onTap: () => onBid(0)),
          ),
        ],
      ),
    );
  }
}

class _NumButton extends StatelessWidget {
  final String label;
  final bool enabled, hinted, wide;
  final VoidCallback onTap;
  const _NumButton({required this.label, required this.enabled, required this.onTap, this.hinted = false, this.wide = false});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.3,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: enabled ? onTap : null,
          child: Container(
            width: wide ? null : 46,
            height: 50,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: hinted ? Lux.foil : const LinearGradient(colors: [Color(0xFF155A45), Color(0xFF07301F)]),
              border: Border.all(color: Lux.gold.withValues(alpha: hinted ? 1 : 0.7), width: hinted ? 2 : 1),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 8, offset: const Offset(0, 4))],
            ),
            child: Text(label,
                style: wide
                    ? Lux.ui(17, color: hinted ? const Color(0xFF2A1D05) : Lux.goldLight, weight: FontWeight.w600)
                    : Lux.numeral(26, color: hinted ? const Color(0xFF2A1D05) : Lux.goldLight)),
          ),
        ),
      ),
    );
  }
}

class _TrumpPanel extends StatelessWidget {
  final List<int> counts;
  final int? hint;
  final ValueChanged<int> onPick;
  const _TrumpPanel({required this.counts, required this.hint, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: 'Kozu seç',
      subtitle: 'İhale senin. Koz olacak rengi seç — ilk eli sen açarsın.',
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final s in _suitOrder)
            Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => onPick(s),
                child: Container(
                  width: 62,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    color: const Color(0xFFFFF8EA),
                    border: Border.all(color: hint == s ? Lux.goldLight : Lux.goldDeep, width: hint == s ? 3 : 1.4),
                    boxShadow: [
                      if (hint == s) BoxShadow(color: Lux.gold.withValues(alpha: 0.6), blurRadius: 14),
                      BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 8, offset: const Offset(0, 4)),
                    ],
                  ),
                  child: Column(children: [
                    _SuitIcon(s, size: 34),
                    const SizedBox(height: 4),
                    Text(CardKit.suitNames[s], style: Lux.ui(12.5, color: const Color(0xFF2A1D05), weight: FontWeight.w600)),
                    Text('${counts[s]} kart', style: Lux.ui(11.5, color: const Color(0xFF6B5A3A))),
                  ]),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  const _Panel({required this.title, this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutBack,
      builder: (context, t, c) => Transform.scale(scale: 0.9 + 0.1 * t, child: Opacity(opacity: t.clamp(0, 1), child: c)),
      child: LuxCard(
        highlight: true,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(Lux.upper(title), style: Lux.display(20, color: Lux.gold)),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle!, textAlign: TextAlign.center, style: Lux.ui(13, color: Lux.muted)),
            ],
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _SummaryPanel extends StatelessWidget {
  final Map<String, dynamic> st;
  final VoidCallback? onNext;
  const _SummaryPanel({required this.st, required this.onNext});

  @override
  Widget build(BuildContext context) {
    final r = st['hand_result'] as Map;
    final d = _int(r['declarer']);
    final made = r['made'] == true;
    final tricks = [for (var i = 0; i < 4; i++) _int((r['tricks'] as List)[i])];
    final deltas = [for (var i = 0; i < 4; i++) _int((r['deltas'] as List)[i])];
    final scores = [for (var i = 0; i < 4; i++) _int((st['scores'] as List)[i])];
    final batan = {for (final b in (r['batanlar'] as List? ?? const [])) _int(b)};
    final head = Lux.ui(11.5, color: Lux.muted, weight: FontWeight.w600);
    return _Panel(
      title: '${_int(st['hand_no'])}. el bitti',
      subtitle: '${_names[d]} · ihale ${_int(r['contract'])} · koz ${CardKit.suitNames[_int(r['trump'])]} · ${made ? 'tuttu' : 'battı'}',
      child: Column(children: [
        Table(
          columnWidths: const {0: FlexColumnWidth(1.6), 1: FlexColumnWidth(1), 2: FlexColumnWidth(1), 3: FlexColumnWidth(1.1), 4: FlexColumnWidth(1.1)},
          children: [
            TableRow(children: [
              Text('Oyuncu', style: head),
              Text('İhale', style: head, textAlign: TextAlign.center),
              Text('Aldı', style: head, textAlign: TextAlign.center),
              Text('Puan', style: head, textAlign: TextAlign.center),
              Text('Toplam', style: head, textAlign: TextAlign.right),
            ]),
            for (var i = 0; i < 4; i++)
              TableRow(
                decoration: BoxDecoration(
                  color: batan.contains(i) ? Lux.bordeaux.withValues(alpha: 0.28) : null,
                  borderRadius: BorderRadius.circular(6),
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Text(_names[i], style: Lux.ui(14, color: batan.contains(i) ? Lux.bordeauxLight : (i == 0 ? Lux.goldLight : Lux.ink), weight: FontWeight.w600)),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Text(i == d ? '${_int(r['contract'])}' : '—', textAlign: TextAlign.center, style: Lux.ui(14, color: Lux.ink)),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Text('${tricks[i]}', textAlign: TextAlign.center, style: Lux.ui(14, color: Lux.ink)),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Text(deltas[i] >= 0 ? '+${deltas[i]}' : '${deltas[i]}',
                        textAlign: TextAlign.center,
                        style: Lux.ui(14, color: deltas[i] < 0 ? Lux.bordeauxLight : Lux.good, weight: FontWeight.w600)),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Text('${scores[i]}', textAlign: TextAlign.right, style: Lux.numeral(17)),
                  ),
                ],
              ),
          ],
        ),
        if (batan.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Batan: ${batan.map((b) => _names[b]).join(', ')}', style: Lux.ui(13, color: Lux.bordeauxLight, weight: FontWeight.w600)),
        ],
        const SizedBox(height: 12),
        if (onNext != null)
          GoldButton('Sonraki el', icon: Icons.arrow_forward_rounded, onPressed: onNext)
        else
          Text('Maç bitti', style: Lux.ui(14, color: Lux.goldLight)),
      ]),
    );
  }
}

class _InfoBox extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool gold;
  const _InfoBox({required this.icon, required this.text, this.gold = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
      decoration: BoxDecoration(
        color: const Color(0xE0071F15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: gold ? Lux.gold : Lux.line),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 16, color: Lux.gold),
        const SizedBox(width: 7),
        Expanded(child: Text(text, style: Lux.ui(12.5, color: Lux.ink))),
      ]),
    );
  }
}

class _WhyBox extends StatelessWidget {
  final List<(int, String)> entries;
  final int latest;
  const _WhyBox({required this.entries, required this.latest});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
      decoration: BoxDecoration(
        color: const Color(0xE0071F15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Lux.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text('NEDEN?', style: Lux.ui(10.5, color: Lux.gold, weight: FontWeight.w700, spacing: 1.6)),
        for (final (seat, text) in entries)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: RichText(
              text: TextSpan(children: [
                TextSpan(text: '${_names[seat]}: ', style: Lux.ui(12, color: seat == latest ? Lux.goldLight : Lux.muted, weight: FontWeight.w700)),
                TextSpan(text: text, style: Lux.ui(12, color: seat == latest ? Lux.ink : Lux.muted)),
              ]),
            ),
          ),
      ]),
    );
  }
}

class _ScoreSheet extends StatelessWidget {
  final Map<String, dynamic> st;
  const _ScoreSheet({required this.st});

  @override
  Widget build(BuildContext context) {
    final rows = st['sheet'] as List? ?? const [];
    final scores = [for (var i = 0; i < 4; i++) _int((st['scores'] as List?)?[i])];
    final head = Lux.ui(12, color: Lux.muted, weight: FontWeight.w600);
    Widget cell(String t, {Color? color, TextAlign align = TextAlign.center, bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(t, textAlign: align, style: Lux.ui(14, color: color ?? Lux.ink, weight: bold ? FontWeight.w700 : FontWeight.w500)),
        );
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
        child: LuxCard(
          highlight: true,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(Lux.upper('Puan cetveli'), style: Lux.display(20)),
            const SizedBox(height: 2),
            Text('${_int(st['target'], 51)} puana ilk ulaşan ya da ${_int(st['max_hands'], 10)} el sonunda en yüksek puan kazanır',
                textAlign: TextAlign.center, style: Lux.ui(12.5, color: Lux.muted)),
            const SizedBox(height: 10),
            Flexible(
              child: SingleChildScrollView(
                child: Table(
                  columnWidths: const {0: FlexColumnWidth(0.8)},
                  children: [
                    TableRow(children: [
                      Text('El', style: head),
                      for (final n in _names) Text(n, style: head, textAlign: TextAlign.center),
                    ]),
                    for (final r in rows.cast<Map>())
                      TableRow(children: [
                        cell('${_int(r['hand'])}', align: TextAlign.left, color: Lux.muted),
                        for (var i = 0; i < 4; i++)
                          () {
                            final dlt = _int((r['deltas'] as List)[i]);
                            final decl = _int(r['declarer']) == i;
                            final made = r['made'] == true;
                            final txt = '${dlt >= 0 ? '+' : ''}$dlt${decl ? ' (${_int(r['contract'])})' : ''}';
                            return cell(txt, color: decl && !made ? Lux.bordeauxLight : (decl ? Lux.goldLight : Lux.ink), bold: decl);
                          }(),
                      ]),
                    TableRow(
                      decoration: const BoxDecoration(border: Border(top: BorderSide(color: Lux.gold))),
                      children: [
                        cell('Σ', align: TextAlign.left, color: Lux.gold, bold: true),
                        for (var i = 0; i < 4; i++) cell('${scores[i]}', color: i == 0 ? Lux.goldLight : Lux.ink, bold: true),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (rows.isEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Henüz biten el yok', style: Lux.ui(13, color: Lux.muted))),
            const SizedBox(height: 6),
            Text('Parantez: ihale · bordo: batan ihale', style: Lux.ui(11.5, color: Lux.muted)),
          ]),
        ),
      ),
    );
  }
}
