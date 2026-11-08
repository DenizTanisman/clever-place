import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../card_kit.dart';
import '../core_bridge.dart';
import '../lux.dart';

/// Blöf table: you (bottom) against Selin (left), Kerem (top) and Defne (right).
///
/// The core owns every rule; this view renders `state` and animates each core event (`event`,
/// numbered by `serial`): claimed cards fly face down from a seat to the pile, every action pops a
/// speech bubble at its seat, a challenge plays a reveal (the cards flip one by one, a lie glows
/// bordeaux and the truth gold, a verdict banner, then the whole pile slides to whoever took it),
/// and a pile nobody answered burns away.
///
/// Input: tap cards to select (1–4), or sweep a finger across the fan to select several; drag the
/// selection up onto the table to play it (the pile glows gold when the play is legal, bordeaux when
/// not, and an illegal drop flies back) — or use "Koy". When you start a round, pick the rank in
/// the strip above your hand. "Blöf!" challenges the last play, "Pas" passes.
///
/// The eye toggle ("Açık oyna") reveals every hand, the true pile and each AI's reason ("Neden?").
/// The hint (lamp) asks the core for the best move from *your* information and turns on the
/// probability helper ("olasılık") for every later claim.
///
/// AI turns: `session.actAsync({'ai': true})` (off the UI isolate) once the current animation has
/// finished plus a 500–900 ms "thinking" pause while the seat glows.
Widget blofView(BuildContext context, GameSession s) => _BlofTable(key: ObjectKey(s), session: s);

const _seatTint = [Color(0xFFC9A24A), Color(0xFF2E8C7A), Color(0xFF9C2B4A), Color(0xFF6A4E9E)];

String _rankName(int r) => switch (r) { 11 => 'Vale', 12 => 'Kız', 13 => 'Papaz', 14 => 'As', _ => '$r' };

int _int(Object? v, [int d = 0]) => (v as num?)?.toInt() ?? d;

class _Card {
  final int s, r;
  const _Card(this.s, this.r);
  int get id => s * 13 + r - 2;
  List<int> get json => [s, r];
}

List<_Card> _cards(Object? v) => [
      for (final e in (v as List?) ?? const [])
        if (e is List && e.length == 2) _Card(_int(e[0]), _int(e[1])),
    ];

/// Table geometry for one layout size.
class _Geo {
  final Size size;
  final double tableBottom, stripTop, handTop, barTop, cw, ch, pw, ph;
  final Offset pile;
  final List<Offset> seats;
  _Geo._(this.size, this.tableBottom, this.stripTop, this.handTop, this.barTop, this.cw, this.ch, this.pw, this.ph,
      this.pile, this.seats);

  factory _Geo.fit(Size size) {
    final w = size.width, h = size.height;
    const barH = 60.0, stripH = 50.0;
    final cw = (w / 5.4).clamp(46.0, 84.0);
    final ch = cw / CardKit.aspect;
    final handH = ch + 30;
    final barTop = h - barH;
    final handTop = barTop - handH;
    final stripTop = handTop - stripH;
    final tb = stripTop;
    final pw = (w * 0.15).clamp(42.0, 66.0);
    final ph = pw / CardKit.aspect;
    final pile = Offset(w / 2, tb * 0.52);
    return _Geo._(size, tb, stripTop, handTop, barTop, cw, ch, pw, ph, pile, [
      Offset(w / 2, handTop + handH / 2),
      Offset(42, tb * 0.40),
      Offset(w / 2, 42),
      Offset(w - 42, tb * 0.40),
    ]);
  }

  Rect get pileRect => Rect.fromCenter(center: pile, width: pw * 2.4, height: ph * 1.9);
}

class _Slot {
  final double x, y, angle;
  const _Slot(this.x, this.y, this.angle);
}

class _Bubble {
  final String text, kind;
  final int serial;
  const _Bubble(this.text, this.kind, this.serial);
}

class _Flight {
  final Offset from, to;
  final int n;
  const _Flight(this.from, this.to, this.n);
}

class _BlofTable extends StatefulWidget {
  final GameSession session;
  const _BlofTable({super.key, required this.session});

  @override
  State<_BlofTable> createState() => _BlofTableState();
}

class _BlofTableState extends State<_BlofTable> with TickerProviderStateMixin {
  GameSession get s => widget.session;
  Map<String, dynamic> get st => s.state;

  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;
  final _rand = math.Random();

  // Selection & options.
  final Set<int> _sel = {};
  int? _rank;
  bool _open = false;
  bool _hintMode = false;
  Object? _seenHint;

  // Events.
  int _seenSerial = -1;
  final Map<int, _Bubble> _bubbles = {};
  Map<String, dynamic>? _lastAiEvent;

  // Animations.
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
  late final AnimationController _fly = AnimationController(vsync: this, duration: const Duration(milliseconds: 480));
  late final AnimationController _rv = AnimationController(vsync: this);
  late final AnimationController _burn = AnimationController(vsync: this, duration: const Duration(milliseconds: 850));
  late final AnimationController _back = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
  _Flight? _flight;
  Map<String, dynamic>? _reveal;
  double _revealMs = 0;
  int _burnN = 0;
  double _busyUntil = 0;
  bool _revealBuzzed = false;

  // AI pacing.
  bool _aiBusy = false;
  double _thinkFrom = -1;

  // Drag & sweep.
  _Geo? _geo;
  Offset? _panStart;
  int? _panCard;
  String? _panMode; // 'drag' | 'select' | 'deselect'
  int? _lastSweep;
  Offset _drag = Offset.zero;
  Offset _grab = Offset.zero;
  Offset? _dropFrom;
  Offset _backFrom = Offset.zero;
  List<_Card> _backCards = const [];

  @override
  void initState() {
    super.initState();
    _seenSerial = _int((st['event'] as Map?)?['serial'], -1);
    _seenHint = st['hint'];
    s.addListener(_onSession);
    _back.addStatusListener((st) {
      if (st == AnimationStatus.completed && mounted) setState(() => _backCards = const []);
    });
    _rv.addStatusListener((st) {
      if (st == AnimationStatus.completed && mounted) setState(() => _reveal = null);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeScheduleAi());
  }

  @override
  void dispose() {
    s.removeListener(_onSession);
    _pulse.dispose();
    _fly.dispose();
    _rv.dispose();
    _burn.dispose();
    _back.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------------------------
  // Session events

  void _onSession() {
    if (!mounted) return;
    final ev = st['event'];
    final serial = _int((ev as Map?)?['serial'], -1);
    if (serial != _seenSerial && ev is Map) {
      _seenSerial = serial;
      _onEvent(Map<String, dynamic>.from(ev));
    }
    final hint = st['hint'];
    if (hint != null && !identical(hint, _seenHint) && hint.toString() != _seenHint.toString()) {
      _seenHint = hint;
      _applyHint(Map<String, dynamic>.from(hint as Map));
    } else if (hint == null) {
      _seenHint = null;
    }
    // Drop selections that are no longer in the hand.
    final ids = _cards(st['hand']).map((c) => c.id).toSet();
    _sel.removeWhere((id) => !ids.contains(id));
    if (st['can_lead'] != true) _rank = null;
    setState(() {});
    _maybeScheduleAi();
  }

  void _onEvent(Map<String, dynamic> ev) {
    final kind = ev['kind'] as String? ?? '';
    final seat = _int(ev['seat']);
    final serial = _int(ev['serial']);
    final text = ev['text'] as String? ?? '';
    if (seat != 0) _lastAiEvent = ev;
    final g = _geo;
    switch (kind) {
      case 'lead':
      case 'play':
        if (kind == 'lead') _bubbles.clear();
        _bubbles[seat] = _Bubble(text, kind, serial);
        if (g != null) {
          final from = seat == 0 ? (_dropFrom ?? g.seats[0] - Offset(0, g.ch * 0.2)) : g.seats[seat];
          _flight = _Flight(from, g.pile, _int(ev['count'], 1));
          _fly.forward(from: 0);
          _busyUntil = math.max(_busyUntil, _now + 0.5);
        }
        _dropFrom = null;
        HapticFeedback.selectionClick();
      case 'pass':
        _bubbles[seat] = _Bubble(text, kind, serial);
        final burned = _int(ev['burned']);
        if (burned > 0) {
          _burnN = burned;
          _burn.forward(from: 0);
          _busyUntil = math.max(_busyUntil, _now + 0.9);
          Future.delayed(const Duration(milliseconds: 900), () {
            if (mounted && _seenSerial == serial) setState(() => _bubbles.clear());
          });
        }
      case 'challenge':
        _bubbles[seat] = _Bubble('Blöf!', kind, serial);
        final rv = ev['reveal'];
        if (rv is Map) {
          _reveal = Map<String, dynamic>.from(rv);
          final n = _cards(rv['cards']).length;
          _revealMs = 350.0 + n * 380 + 1000 + 560;
          _rv.duration = Duration(milliseconds: _revealMs.round());
          _rv.forward(from: 0);
          _revealBuzzed = false;
          _busyUntil = math.max(_busyUntil, _now + _revealMs / 1000 + 0.1);
          HapticFeedback.mediumImpact();
          Future.delayed(Duration(milliseconds: _revealMs.round()), () {
            if (mounted && _seenSerial == serial) setState(() => _bubbles.clear());
          });
        }
    }
    if (ev['win'] == true) {
      final delay = math.max(0.0, _busyUntil - _now);
      Future.delayed(Duration(milliseconds: (delay * 1000).round()), HapticFeedback.heavyImpact);
    }
  }

  void _applyHint(Map<String, dynamic> h) {
    _hintMode = true;
    final kind = h['kind'] as String? ?? '';
    if (kind == 'lead' || kind == 'play') {
      _sel
        ..clear()
        ..addAll(_cards(h['cards']).map((c) => c.id));
      if (kind == 'lead') _rank = _int(h['rank']);
    } else {
      _sel.clear();
    }
  }

  // ---------------------------------------------------------------------------------------------
  // AI pacing

  bool get _thinking => _aiBusy && _now >= _thinkFrom;

  void _maybeScheduleAi() {
    if (!mounted || _aiBusy || s.finished || st['ai_pending'] != true) return;
    _aiBusy = true;
    final wait = math.max(0.0, _busyUntil - _now) + 0.05;
    final hard = st['final'] == true || _int(st['pile_count']) >= 6;
    final pause = 0.5 + _rand.nextDouble() * 0.3 + (hard ? 0.1 : 0.0);
    _thinkFrom = _now + wait;
    _pulse.repeat(reverse: true);
    final session = s;
    Future.delayed(Duration(milliseconds: ((wait + pause) * 1000).round()), () async {
      if (!mounted || !identical(session, s)) return;
      if (st['ai_pending'] != true || s.finished) {
        setState(() => _aiBusy = false);
        _pulse.stop();
        return;
      }
      final ok = await s.actAsync({'ai': true});
      if (!mounted) return;
      _pulse.stop();
      setState(() => _aiBusy = false);
      if (ok) WidgetsBinding.instance.addPostFrameCallback((_) => _maybeScheduleAi());
    });
  }

  // ---------------------------------------------------------------------------------------------
  // Player actions

  bool get _yourTurn => !s.finished && st['turn'] == 'you' && !_aiBusy;
  bool get _canLead => _yourTurn && st['can_lead'] == true;
  bool get _canPlay => _yourTurn && st['can_play'] == true;
  bool get _canChallenge => _yourTurn && st['can_challenge'] == true;
  bool get _canPass => _yourTurn && st['can_pass'] == true;

  List<_Card> get _hand => _cards(st['hand']);
  List<_Card> get _selCards => _hand.where((c) => _sel.contains(c.id)).toList();

  int? get _effectiveRank {
    if (_rank != null) return _rank;
    final sel = _selCards;
    if (sel.isNotEmpty && sel.every((c) => c.r == sel.first.r) && !_deadRanks.contains(sel.first.r)) return sel.first.r;
    return null;
  }

  Set<int> get _deadRanks => {for (final r in (st['dead_ranks'] as List?) ?? const []) _int(r)};

  bool get _playLegal {
    final n = _sel.length;
    if (n < 1 || n > 4) return false;
    if (_canPlay) return true;
    return _canLead && _effectiveRank != null;
  }

  bool _play() {
    if (!_yourTurn) return false;
    final cards = _selCards;
    final action = <String, dynamic>{'play': [for (final c in cards) c.json]};
    if (st['can_lead'] == true) {
      final r = _effectiveRank;
      if (r != null) action['rank'] = r;
    }
    final ok = s.act(action);
    if (ok) {
      _sel.clear();
      _rank = null;
      HapticFeedback.lightImpact();
    } else {
      HapticFeedback.mediumImpact();
    }
    return ok;
  }

  void _challenge() {
    if (!_canChallenge) return;
    _sel.clear();
    s.act({'challenge': true});
  }

  void _pass() {
    if (!_canPass) return;
    _sel.clear();
    s.act({'pass': true});
  }

  void _hint() {
    if (!_yourTurn) {
      setState(() => _hintMode = !_hintMode);
      return;
    }
    if (_hintMode && st['hint'] != null) {
      setState(() => _hintMode = false);
      return;
    }
    s.act({'hint': true});
  }

  void _toggle(int id) {
    if (s.finished) return;
    setState(() {
      if (_sel.contains(id)) {
        _sel.remove(id);
      } else if (_sel.length < 4) {
        _sel.add(id);
      }
    });
    HapticFeedback.selectionClick();
  }

  // ---------------------------------------------------------------------------------------------
  // Hand fan

  List<_Slot> _fan(_Geo g, List<_Card> hand) {
    final n = hand.length;
    final w = g.size.width;
    final avail = w - 20 - g.cw;
    final step = n > 1 ? math.min(g.cw * 0.6, avail / (n - 1)) : 0.0;
    final total = g.cw + step * (n - 1);
    final x0 = (w - total) / 2;
    final spread = math.min(0.2, 0.025 * n);
    return [
      for (var i = 0; i < n; i++)
        () {
          final t = n > 1 ? i / (n - 1) * 2 - 1 : 0.0;
          final lift = _sel.contains(hand[i].id) ? g.ch * 0.22 : 0.0;
          return _Slot(x0 + i * step, g.handTop + 16 + t * t * 9 - lift, t * spread);
        }(),
    ];
  }

  int? _cardAt(Offset p) {
    final g = _geo;
    if (g == null) return null;
    final hand = _hand;
    final slots = _fan(g, hand);
    for (var i = hand.length - 1; i >= 0; i--) {
      final r = Rect.fromLTWH(slots[i].x, slots[i].y, g.cw, g.ch);
      if (r.inflate(4).contains(p)) return i;
    }
    // Below / between cards: nearest by x.
    if (p.dy > g.handTop - 10 && hand.isNotEmpty) {
      var best = 0;
      var bd = double.infinity;
      for (var i = 0; i < hand.length; i++) {
        final d = (slots[i].x + g.cw / 2 - p.dx).abs();
        if (d < bd) {
          bd = d;
          best = i;
        }
      }
      if (bd < g.cw) return best;
    }
    return null;
  }

  void _onPanStart(DragStartDetails d) {
    if (s.finished) return;
    _panStart = d.localPosition;
    _panCard = _cardAt(d.localPosition);
    _panMode = null;
    _lastSweep = null;
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final start = _panStart;
    if (start == null) return;
    final p = d.localPosition;
    final hand = _hand;
    if (_panMode == null) {
      final delta = p - start;
      if (delta.distance < 9) return;
      final i = _panCard;
      if (delta.dy < -6 && delta.dy.abs() > delta.dx.abs() && i != null) {
        // Drag the selection (the touched card joins it) towards the table.
        if (!_sel.contains(hand[i].id)) {
          if (_sel.length >= 4) _sel.clear();
          _sel.add(hand[i].id);
        }
        _panMode = 'drag';
        final g = _geo!;
        final slot = _fan(g, hand)[i];
        _grab = start - Offset(slot.x, slot.y);
        HapticFeedback.selectionClick();
      } else if (i != null) {
        _panMode = _sel.contains(hand[i].id) ? 'deselect' : 'select';
        _sweep(i);
        final j = _cardAt(p);
        if (j != null && j != i) {
          final step = j > i ? 1 : -1;
          for (var k = i + step; k != j + step; k += step) {
            _sweep(k);
          }
        }
      } else {
        _panMode = 'none';
      }
    }
    if (_panMode == 'drag') {
      setState(() => _drag = p);
    } else if (_panMode == 'select' || _panMode == 'deselect') {
      final i = _cardAt(p);
      final from = _lastSweep;
      if (i != null && from != null) {
        // Cover every card between the last one and this one (fast sweeps skip cards).
        final step = i >= from ? 1 : -1;
        for (var k = from + step; k != i + step; k += step) {
          _sweep(k);
        }
      }
    }
  }

  void _sweep(int i) {
    _lastSweep = i;
    final id = _hand[i].id;
    final want = _panMode == 'select';
    if (want == _sel.contains(id)) return;
    if (want && _sel.length >= 4) return;
    setState(() => want ? _sel.add(id) : _sel.remove(id));
    HapticFeedback.selectionClick();
  }

  void _onPanEnd(DragEndDetails d) {
    if (_panMode == 'drag') {
      final g = _geo!;
      final over = _drag.dy < g.tableBottom;
      final ghost = _drag - _grab;
      if (over && _playLegal) {
        _dropFrom = ghost + Offset(g.cw / 2, g.ch / 2);
        if (!_play()) _flyBack(ghost);
      } else {
        if (over) {
          HapticFeedback.mediumImpact();
          if (!_yourTurn) {
            // nothing: the toast would only repeat what the status line says
          } else if (_canLead && _effectiveRank == null) {
            s.act({'play': [for (final c in _selCards) c.json]}); // core explains: pick a rank
          }
        }
        _flyBack(ghost);
      }
    }
    setState(() {
      _panStart = null;
      _panMode = null;
      _panCard = null;
    });
  }

  void _flyBack(Offset from) {
    _backFrom = from;
    _backCards = _selCards;
    _back.forward(from: 0);
  }

  // ---------------------------------------------------------------------------------------------
  // Build

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      if (!box.hasBoundedHeight || box.maxWidth < 200 || box.maxHeight < 360) return const SizedBox();
      final g = _geo = _Geo.fit(box.biggest);
      return AnimatedBuilder(
        animation: Listenable.merge([_pulse, _fly, _rv, _burn, _back]),
        builder: (context, _) => Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(child: CustomPaint(painter: _FeltPainter(g))),
            ..._centre(g),
            for (var i = 1; i < 4; i++) _seat(g, i),
            if (_showAll)
              Positioned(
                right: g.seats[2].dx + 50,
                top: g.seats[2].dy - 30,
                child: IgnorePointer(child: _openHand(2, 7)),
              ),
            ..._corners(g),
            ..._bubbleWidgets(g),
            _bottomPanels(g),
            _strip(g),
            ..._handWidgets(g),
            Positioned(left: 0, right: 0, top: g.handTop - 12, height: g.barTop - g.handTop + 12, child: _handGestures()),
            _bar(g),
            ..._flightWidgets(g),
            if (_reveal != null && _rv.isAnimating) ..._revealWidgets(g),
            if (_burn.isAnimating) ..._burnWidgets(g),
            if (_panMode == 'drag') _ghost(g, _drag - _grab, _selCards),
            if (_backCards.isNotEmpty && _back.isAnimating)
              _ghost(g, Offset.lerp(_backFrom, Offset(g.size.width / 2 - g.cw / 2, g.handTop + 10), Curves.easeOut.transform(_back.value))!,
                  _backCards),
          ],
        ),
      );
    });
  }

  bool get _showAll => _open || s.finished;

  Widget _handGestures() => GestureDetector(
        behavior: HitTestBehavior.translucent,
        dragStartBehavior: DragStartBehavior.down,
        onTapUp: (d) {
          final g = _geo;
          if (g == null) return;
          final p = d.localPosition + Offset(0, g.handTop - 12);
          final i = _cardAt(p);
          if (i != null) _toggle(_hand[i].id);
        },
        onPanStart: (d) {
          final g = _geo!;
          _onPanStart(DragStartDetails(globalPosition: d.globalPosition, localPosition: d.localPosition + Offset(0, g.handTop - 12)));
        },
        onPanUpdate: (d) {
          final g = _geo!;
          _onPanUpdate(DragUpdateDetails(
              globalPosition: d.globalPosition, delta: d.delta, localPosition: d.localPosition + Offset(0, g.handTop - 12)));
        },
        onPanEnd: _onPanEnd,
      );

  // --- Centre of the table: claim plate, pile, counters, open-play pile truth.

  List<Widget> _centre(_Geo g) {
    final rank = st['rank'] == null ? null : _int(st['rank']);
    var pileN = _int(st['pile_count']);
    if (_fly.isAnimating && _flight != null) pileN = math.max(0, pileN - _flight!.n);
    if (_reveal != null && _rv.isAnimating) pileN = 0;
    final dragging = _panMode == 'drag';
    final overTable = dragging && _drag.dy < g.tableBottom;
    final glow = overTable ? (_playLegal ? Lux.gold : Lux.bordeaux) : null;
    final dead = _deadRanks.toList()..sort();
    final burned = _int(st['burned']);
    final last = st['last_play'] as Map?;
    final names = (st['names'] as List?)?.cast<String>() ?? const ['Sen', 'Selin', 'Kerem', 'Defne'];
    return [
      // Claim plate.
      Positioned(
        left: 0,
        right: 0,
        top: g.pile.dy - g.ph * 0.5 - 98,
        child: Column(
          children: [
            Text(Lux.upper(rank == null ? 'Yeni tur' : 'Söylenen'), style: Lux.ui(11, color: Lux.muted, spacing: 2)),
            const SizedBox(height: 2),
            if (rank != null)
              FoilText(_rankName(rank), style: Lux.display(rank > 10 ? 30 : 36))
            else
              Text(_canLead ? 'Turu sen açıyorsun' : '—', style: Lux.ui(15, color: Lux.goldLight)),
            if (last != null)
              Text('Son: ${names[_int(last['seat'])]} · ${_int(last['count'])} kart',
                  style: Lux.ui(12, color: Lux.muted)),
          ],
        ),
      ),
      // Drop zone glow.
      if (glow != null)
        Positioned.fromRect(
          rect: g.pileRect.inflate(10),
          child: IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: glow.withValues(alpha: 0.9), width: 2),
                boxShadow: [BoxShadow(color: glow.withValues(alpha: 0.45), blurRadius: 26, spreadRadius: 2)],
              ),
            ),
          ),
        ),
      // Pile.
      ..._pileStack(g, g.pile, pileN, 1.0),
      Positioned(
        left: 0,
        right: 0,
        top: g.pile.dy + g.ph * 0.62,
        child: Column(
          children: [
            Text(pileN == 0 ? 'Yığın boş' : 'Yığın: $pileN kart', style: Lux.ui(13, color: Lux.goldLight, weight: FontWeight.w600)),
            if (dead.isNotEmpty || burned > 0)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  [
                    if (dead.isNotEmpty) 'Ölü: ${dead.map(_rankName).join(', ')}',
                    if (burned > 0) 'Yanan: $burned',
                  ].join('  ·  '),
                  style: Lux.ui(11, color: Lux.muted),
                ),
              ),
            if (_showAll) _pileTruth(g),
          ],
        ),
      ),
    ];
  }

  List<Widget> _pileStack(_Geo g, Offset c, int n, double scale) {
    final shown = math.min(n, 7);
    return [
      for (var i = 0; i < shown; i++)
        Positioned(
          left: c.dx - g.pw * scale / 2 + (i - shown / 2) * 2.2 * scale,
          top: c.dy - g.ph * scale / 2 - i * 2.0 * scale,
          width: g.pw * scale,
          height: g.ph * scale,
          child: IgnorePointer(
            child: Transform.rotate(angle: math.sin(i * 2.3) * 0.12, child: const PlayingCard.back()),
          ),
        ),
    ];
  }

  Widget _pileTruth(_Geo g) {
    final pile = (st['pile'] as List?) ?? const [];
    if (pile.isEmpty) return const SizedBox();
    final names = (st['names'] as List?)?.cast<String>() ?? const ['Sen', 'Selin', 'Kerem', 'Defne'];
    final rows = pile.length > 2 ? pile.sublist(pile.length - 2) : pile;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        children: [
          for (final p in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(width: 44, child: Text(names[_int((p as Map)['seat'])], style: Lux.ui(11, color: Lux.muted), textAlign: TextAlign.right)),
                  const SizedBox(width: 6),
                  for (final c in _cards(p['cards']))
                    Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: _MiniCard(c, width: 20, bad: c.r != _int(p['rank'])),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // --- Opponent seats.

  Widget _seat(_Geo g, int i) {
    final names = (st['names'] as List?)?.cast<String>() ?? const ['Sen', 'Selin', 'Kerem', 'Defne'];
    final counts = (st['counts'] as List?) ?? const [0, 0, 0, 0];
    var count = _int(counts[i]);
    final rv = _reveal;
    if (rv != null && _rv.isAnimating && _int(rv['taker']) == i) {
      count = count - _int(rv['count']) + 4 * ((rv['discards'] as List?)?.length ?? 0);
    }
    final active = !s.finished && _int(st['seat']) == i;
    final thinking = active && _thinking;
    final glow = thinking ? 0.45 + 0.55 * _pulse.value : (active ? 0.35 : 0.0);
    final won = s.finished && _int(st['winner'], -1) == i;
    final c = g.seats[i];
    final side = i != 2;
    const w = 96.0;
    return Positioned(
      left: (c.dx - w / 2).clamp(0.0, g.size.width - w),
      top: c.dy - 30,
      width: w,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                if (glow > 0) BoxShadow(color: Lux.gold.withValues(alpha: 0.6 * glow), blurRadius: 10 + 16 * glow, spreadRadius: 2 * glow),
                if (won) BoxShadow(color: Lux.goldLight.withValues(alpha: 0.8), blurRadius: 30, spreadRadius: 4),
              ],
            ),
            child: Monogram(names[i].substring(0, 1), size: 48, tint: _seatTint[i]),
          ),
          const SizedBox(height: 3),
          Text(names[i], style: Lux.ui(13, color: active ? Lux.goldLight : Lux.ink, weight: FontWeight.w600)),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 11, height: 15, child: PlayingCard.back()),
              const SizedBox(width: 4),
              Text('$count', style: Lux.numeral(17, color: count <= 2 ? Lux.bordeauxLight : Lux.goldLight)),
            ],
          ),
          if (thinking)
            Text('düşünüyor${'.' * (1 + (_now * 2.5).floor() % 3)}', style: Lux.ui(11, color: Lux.muted)),
          if (_showAll && side) Padding(padding: const EdgeInsets.only(top: 4), child: _openHand(i, 5)),
        ],
      ),
    );
  }

  Widget _openHand(int i, int perRow) {
    final hands = (st['hands'] as List?) ?? const [];
    if (i >= hands.length) return const SizedBox();
    final cards = _cards(hands[i]);
    final rows = <List<_Card>>[];
    for (var k = 0; k < cards.length; k += perRow) {
      rows.add(cards.sublist(k, math.min(cards.length, k + perRow)));
    }
    const mw = 20.0;
    const step = 13.5;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in rows)
          SizedBox(
            width: mw + step * (perRow - 1),
            height: mw / CardKit.aspect + 2,
            child: Stack(
              children: [
                for (var k = 0; k < row.length; k++) Positioned(left: k * step, top: 0, child: _MiniCard(row[k], width: mw)),
              ],
            ),
          ),
      ],
    );
  }

  // --- Speech bubbles.

  List<Widget> _bubbleWidgets(_Geo g) {
    final out = <Widget>[];
    for (final e in _bubbles.entries) {
      final i = e.key;
      final b = e.value;
      final c = g.seats[i];
      final challenge = b.kind == 'challenge';
      final pass = b.kind == 'pass';
      late final Alignment anchor;
      late final Offset at;
      switch (i) {
        case 0:
          at = Offset(g.size.width / 2, g.stripTop - 8);
          anchor = Alignment.bottomCenter;
        case 1:
          at = Offset(c.dx + 30, c.dy);
          anchor = Alignment.centerLeft;
        case 2:
          at = Offset(c.dx + 52, c.dy + 2);
          anchor = Alignment.centerLeft;
        default:
          at = Offset(c.dx - 30, c.dy);
          anchor = Alignment.centerRight;
      }
      final bubble = TweenAnimationBuilder<double>(
        key: ValueKey('b${b.serial}'),
        tween: Tween(begin: 0, end: 1),
        duration: Duration(milliseconds: challenge ? 520 : 380),
        curve: Curves.elasticOut,
        builder: (context, t, child) => Transform.scale(scale: 0.4 + 0.6 * t, alignment: anchor, child: Opacity(opacity: t.clamp(0, 1), child: child)),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: challenge ? 16 : 12, vertical: challenge ? 9 : 6),
          decoration: BoxDecoration(
            color: challenge ? Lux.bordeaux : (pass ? const Color(0xEE0B2A21) : const Color(0xF2F6EDD6)),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: challenge ? Lux.bordeauxLight : Lux.gold.withValues(alpha: pass ? 0.4 : 0.9), width: 1.2),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 10, offset: const Offset(0, 4))],
          ),
          child: Text(
            b.text,
            style: challenge
                ? Lux.display(22, color: Colors.white)
                : Lux.ui(15, color: pass ? Lux.muted : const Color(0xFF2A1D05), weight: FontWeight.w700),
          ),
        ),
      );
      const bw = 160.0;
      final left = switch (anchor) {
        Alignment.centerLeft => at.dx,
        Alignment.centerRight => at.dx - bw,
        _ => at.dx - bw / 2,
      };
      out.add(Positioned(
        left: left.clamp(0.0, g.size.width - bw),
        top: anchor == Alignment.bottomCenter ? at.dy - 44 : at.dy - 22,
        width: bw,
        height: 44,
        child: IgnorePointer(child: Align(alignment: anchor, child: bubble)),
      ));
    }
    return out;
  }

  // --- Reason ("Neden?") and hint / odds panels at the bottom of the felt.

  Widget _bottomPanels(_Geo g) {
    final names = (st['names'] as List?)?.cast<String>() ?? const ['Sen', 'Selin', 'Kerem', 'Defne'];
    final ai = _lastAiEvent;
    final reason = ai?['reason'] as String? ?? '';
    final hint = st['hint'] as Map?;
    final odds = st['odds'] as Map?;
    final panels = <Widget>[];
    if (_open && reason.isNotEmpty) {
      panels.add(_panel(
        Text.rich(TextSpan(children: [
          TextSpan(text: 'Neden? ', style: Lux.ui(13, color: Lux.gold, weight: FontWeight.w700)),
          TextSpan(text: '${names[_int(ai!['seat'])]}: ', style: Lux.ui(13, color: Lux.goldLight, weight: FontWeight.w600)),
          TextSpan(text: reason, style: Lux.ui(13, color: Lux.ink)),
        ])),
      ));
    }
    if (_hintMode && !s.finished) {
      final ht = hint?['text'] as String?;
      final ot = odds?['text'] as String?;
      if (ht != null || ot != null) {
        panels.add(_panel(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.lightbulb_rounded, size: 15, color: Lux.gold),
                  const SizedBox(width: 6),
                  Text(Lux.upper(ht != null ? 'Öneri' : 'Olasılık'), style: Lux.ui(11, color: Lux.gold, weight: FontWeight.w700, spacing: 1.6)),
                  const Spacer(),
                  if (odds != null) _oddsMeter((odds['p_lie'] as num?)?.toDouble() ?? 0, odds['certain'] == true),
                ],
              ),
              const SizedBox(height: 4),
              Text(ht ?? ot!, style: Lux.ui(13, color: Lux.ink)),
            ],
          ),
          highlight: true,
        ));
      }
    }
    if (panels.isEmpty) return const SizedBox();
    return Positioned(
      left: 10,
      right: 10,
      bottom: g.size.height - g.tableBottom + 4,
      child: Column(mainAxisSize: MainAxisSize.min, children: panels),
    );
  }

  Widget _oddsMeter(double p, bool certain) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('yalan', style: Lux.ui(11, color: Lux.muted)),
        const SizedBox(width: 5),
        Container(
          width: 64,
          height: 6,
          decoration: BoxDecoration(color: Lux.cardDeep, borderRadius: BorderRadius.circular(3), border: Border.all(color: Lux.line)),
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: certain ? 1 : p.clamp(0.02, 1.0),
            child: Container(decoration: BoxDecoration(color: Color.lerp(Lux.gold, Lux.bordeauxLight, p)!, borderRadius: BorderRadius.circular(3))),
          ),
        ),
        const SizedBox(width: 5),
        Text(certain ? 'kesin' : '%${(p * 100).round()}', style: Lux.ui(11, color: Lux.goldLight, weight: FontWeight.w700)),
      ],
    );
  }

  Widget _panel(Widget child, {bool highlight = false}) => Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
        decoration: BoxDecoration(
          color: const Color(0xEE05241C),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: highlight ? Lux.gold.withValues(alpha: 0.7) : Lux.line),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 12, offset: const Offset(0, 5))],
        ),
        child: child,
      );

  // --- Strip above the hand: rank picker when you lead, status otherwise.

  Widget _strip(_Geo g) {
    Widget child;
    if (_canLead) {
      final counts = <int, int>{};
      for (final c in _hand) {
        counts[c.r] = (counts[c.r] ?? 0) + 1;
      }
      final dead = _deadRanks;
      final eff = _effectiveRank;
      final chipW = ((g.size.width - 16) / 13 - 4).clamp(22.0, 40.0);
      child = Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var r = 2; r <= 14; r++)
              _rankChip(r, counts[r] ?? 0, dead.contains(r), _rank == r || (_rank == null && eff == r),
                  auto: _rank == null && eff == r, width: chipW),
          ],
        ),
      );
    } else {
      child = Center(child: Text(_status(), textAlign: TextAlign.center, style: Lux.ui(14, color: _yourTurn ? Lux.goldLight : Lux.muted, weight: FontWeight.w600)));
    }
    return Positioned(left: 0, right: 0, top: g.stripTop, height: g.handTop - g.stripTop, child: child);
  }

  Widget _rankChip(int r, int have, bool dead, bool on, {bool auto = false, double width = 38}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: GestureDetector(
        onTap: dead
            ? null
            : () {
                setState(() => _rank = _rank == r ? null : r);
                HapticFeedback.selectionClick();
              },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: width,
          decoration: BoxDecoration(
            gradient: on && !auto ? Lux.foil : null,
            color: on && !auto ? null : (dead ? const Color(0x22000000) : Lux.card),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: on ? Lux.goldLight : (dead ? Lux.lineFaint : Lux.line), width: on ? 1.6 : 1),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Text(CardKit.rankLabel(r),
                  style: Lux.numeral(width < 30 ? 15 : 18,
                      color: dead ? Lux.muted.withValues(alpha: 0.35) : (on && !auto ? const Color(0xFF2A1D05) : Lux.goldLight))),
              if (have > 0 && !dead)
                Positioned(
                  right: 3,
                  top: 2,
                  child: Text('$have', style: Lux.ui(9, color: on && !auto ? const Color(0xFF2A1D05) : Lux.good, weight: FontWeight.w700)),
                ),
              if (dead) Container(height: 1.2, width: width * 0.7, color: Lux.bordeaux.withValues(alpha: 0.7)),
            ],
          ),
        ),
      ),
    );
  }

  String _status() {
    final names = (st['names'] as List?)?.cast<String>() ?? const ['Sen', 'Selin', 'Kerem', 'Defne'];
    if (s.finished) {
      final w = _int(st['winner'], -1);
      if (w == 0) return 'Elini bitirdin!';
      if (w > 0) return '${names[w]} elini bitirdi';
      return 'Berabere';
    }
    final seat = _int(st['seat']);
    final rank = st['rank'] == null ? null : _rankName(_int(st['rank']));
    final fin = st['final'] == true;
    if (seat != 0 || _aiBusy) {
      return _thinking ? '${names[seat]} düşünüyor…' : 'Sıra: ${names[seat]}';
    }
    if (fin) {
      final last = st['last_play'] as Map?;
      return '${names[_int(last?['seat'])]} son kartlarını koydu: Blöf! de ya da geç';
    }
    final n = _sel.length;
    if (n == 0) return 'Sıra sende · $rank: kart seç, Blöf! de ya da pas geç';
    return '$n kart seçili · "${_claimText(n, _int(st['rank']))}" diye koy';
  }

  String _claimText(int k, int r) => '${const ['Hiç', 'Bir', 'İki', 'Üç', 'Dört'][k.clamp(0, 4)]} tane ${_rankName(r)}';

  // --- Your hand.

  List<Widget> _handWidgets(_Geo g) {
    final hand = _hand;
    final slots = _fan(g, hand);
    final dragging = _panMode == 'drag';
    final hintIds = <int>{
      if (_hintMode && st['hint'] is Map) ..._cards((st['hint'] as Map)['cards']).map((c) => c.id),
    };
    final dimAll = !_yourTurn && !s.finished;
    return [
      for (var i = 0; i < hand.length; i++)
        AnimatedPositioned(
          key: ValueKey('h${hand[i].id}'),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          left: slots[i].x,
          top: slots[i].y,
          width: g.cw,
          height: g.ch,
          child: IgnorePointer(
            child: Opacity(
              opacity: dragging && _sel.contains(hand[i].id) ? 0.25 : 1,
              child: Transform.rotate(
                angle: slots[i].angle,
                alignment: Alignment.bottomCenter,
                child: Stack(
                  children: [
                    PlayingCard(suit: hand[i].s, rank: hand[i].r, highlight: _sel.contains(hand[i].id), dim: dimAll && !_sel.contains(hand[i].id)),
                    if (hintIds.contains(hand[i].id))
                      Positioned(
                        right: 3,
                        top: 3,
                        child: Container(width: 9, height: 9, decoration: const BoxDecoration(color: Lux.good, shape: BoxShape.circle)),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
    ];
  }

  Widget _ghost(_Geo g, Offset topLeft, List<_Card> cards) {
    return Positioned(
      left: topLeft.dx,
      top: topLeft.dy,
      width: g.cw + 14.0 * math.max(0, cards.length - 1),
      height: g.ch + 8,
      child: IgnorePointer(
        child: Stack(
          children: [
            for (var k = 0; k < cards.length; k++)
              Positioned(
                left: k * 14.0,
                top: (k - (cards.length - 1) / 2).abs() * 2,
                width: g.cw,
                height: g.ch,
                child: Transform.rotate(
                  angle: (k - (cards.length - 1) / 2) * 0.07,
                  child: PlayingCard(suit: cards[k].s, rank: cards[k].r, highlight: true),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // --- Table corners: open play toggle and the history log.

  List<Widget> _corners(_Geo g) => [
        Positioned(
          left: 6,
          top: 4,
          child: _CornerButton(
            icon: _open ? Icons.visibility_rounded : Icons.visibility_off_outlined,
            label: 'Açık oyna',
            on: _open,
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _open = !_open);
            },
          ),
        ),
        Positioned(
          right: 6,
          top: 4,
          child: _CornerButton(icon: Icons.history_rounded, label: 'Geçmiş', on: false, onTap: () => _showLog(context)),
        ),
      ];

  // --- Action bar.

  Widget _bar(_Geo g) {
    final fin = st['final'] == true;
    final n = _sel.length;
    return Positioned(
      left: 8,
      right: 8,
      top: g.barTop,
      height: g.size.height - g.barTop,
      child: Row(
        children: [
          RimIconButton(_hintMode ? Icons.lightbulb_rounded : Icons.lightbulb_outline_rounded,
              tooltip: 'İpucu · olasılık', onPressed: s.finished ? null : _hint),
          const Spacer(),
          if (_canPass) ...[
            _PillButton(fin ? 'Geç' : 'Pas', onTap: _pass),
            const SizedBox(width: 6),
          ],
          if (_canChallenge) ...[
            _BlofButton(onPressed: _challenge, pulse: fin || (st['hint'] is Map && (st['hint'] as Map)['kind'] == 'challenge')),
            const SizedBox(width: 6),
          ],
          if ((_canPlay || _canLead) && n > 0)
            GoldButton(n > 4 ? 'En çok 4' : 'Koy ($n)', onPressed: _playLegal ? () => _play() : null),
        ],
      ),
    );
  }

  void _showLog(BuildContext context) {
    final names = (st['names'] as List?)?.cast<String>() ?? const ['Sen', 'Selin', 'Kerem', 'Defne'];
    final log = ((st['log'] as List?) ?? const []).reversed.toList();
    final open = _open;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Lux.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: Column(
            children: [
              const LuxHeading('Geçmiş'),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: log.length,
                  itemBuilder: (context, i) {
                    final l = log[i] as Map;
                    final kind = l['kind'] as String? ?? '';
                    final seat = _int(l['seat']);
                    final reason = l['reason'] as String? ?? '';
                    final system = const {'reveal', 'burn', 'discard', 'win', 'start', 'last', 'draw'}.contains(kind);
                    final color = switch (kind) {
                      'challenge' => Lux.bordeauxLight,
                      'reveal' || 'win' => Lux.gold,
                      'pass' => Lux.muted,
                      _ => Lux.ink,
                    };
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(system ? '${l['text']}' : '${names[seat]}: ${l['text']}',
                              style: Lux.ui(14, color: color, weight: system ? FontWeight.w500 : FontWeight.w600)),
                          if (open && reason.isNotEmpty && seat != 0)
                            Text('Neden? $reason', style: Lux.ui(12, color: Lux.muted)),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Animations: flights, reveal, burn.

  List<Widget> _flightWidgets(_Geo g) {
    final f = _flight;
    if (f == null || !_fly.isAnimating) return const [];
    final t = Curves.easeInOutCubic.transform(_fly.value);
    final mid = Offset.lerp(f.from, f.to, 0.5)! - const Offset(0, 40);
    final p = _bezier(f.from, mid, f.to, t);
    final scale = 0.9 + 0.25 * math.sin(math.pi * t);
    return [
      for (var k = 0; k < f.n; k++)
        Positioned(
          left: p.dx - g.pw * scale / 2 + (k - (f.n - 1) / 2) * 7 * (1 - t),
          top: p.dy - g.ph * scale / 2,
          width: g.pw * scale,
          height: g.ph * scale,
          child: IgnorePointer(child: Transform.rotate(angle: (1 - t) * 0.5 + k * 0.05, child: const PlayingCard.back())),
        ),
    ];
  }

  Offset _bezier(Offset a, Offset b, Offset c, double t) {
    final u = 1 - t;
    return a * (u * u) + b * (2 * u * t) + c * (t * t);
  }

  List<Widget> _revealWidgets(_Geo g) {
    final rv = _reveal!;
    final names = (st['names'] as List?)?.cast<String>() ?? const ['Sen', 'Selin', 'Kerem', 'Defne'];
    final cards = _cards(rv['cards']);
    final rank = _int(rv['rank']);
    final lie = rv['lie'] == true;
    final taker = _int(rv['taker']);
    final count = _int(rv['count']);
    final ms = _rv.value * _revealMs;
    final n = cards.length;
    final flipsEnd = 350.0 + n * 380;
    final verdictAt = flipsEnd + 120;
    final slideAt = flipsEnd + 1000;
    final slide = ((ms - slideAt) / 560).clamp(0.0, 1.0);
    final se = Curves.easeInCubic.transform(slide);
    if (ms >= verdictAt && !_revealBuzzed) {
      _revealBuzzed = true;
      (lie ? HapticFeedback.heavyImpact : HapticFeedback.mediumImpact)();
    }
    final dest = taker == 0 ? g.seats[0] : g.seats[taker];
    final rw = (g.size.width * 0.17).clamp(48.0, 74.0);
    final rh = rw / CardKit.aspect;
    const gap = 8.0;
    final rowW = n * rw + (n - 1) * gap;
    final rowTop = g.pile.dy - rh - g.ph * 0.15;
    final out = <Widget>[
      // Dim the table a little.
      Positioned.fill(
        child: IgnorePointer(
          child: ColoredBox(color: Colors.black.withValues(alpha: 0.28 * (1 - se) * math.min(1, ms / 250))),
        ),
      ),
      // The pile being taken.
      ..._pileStack(g, Offset.lerp(g.pile, dest, se)!, count - n, 1 - 0.55 * se),
    ];
    for (var k = 0; k < n; k++) {
      final c = cards[k];
      final f = ((ms - 350 - k * 380) / 300).clamp(0.0, 1.0);
      final angle = math.pi * (1 - Curves.easeInOut.transform(f));
      final face = angle < math.pi / 2;
      final bad = c.r != rank;
      final home = Offset(g.size.width / 2 - rowW / 2 + k * (rw + gap), rowTop);
      final pos = Offset.lerp(home, dest - Offset(rw / 2, rh / 2), se)!;
      final glowOn = ms >= verdictAt ? math.min(1.0, (ms - verdictAt) / 250) * (1 - se) : 0.0;
      final gc = bad ? Lux.bordeaux : Lux.gold;
      out.add(Positioned(
        left: pos.dx,
        top: pos.dy,
        width: rw * (1 - 0.5 * se),
        height: rh * (1 - 0.5 * se),
        child: IgnorePointer(
          child: Opacity(
            opacity: 1 - 0.6 * se,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(rw * 0.1),
                boxShadow: [
                  if (glowOn > 0) BoxShadow(color: gc.withValues(alpha: 0.85 * glowOn), blurRadius: 22, spreadRadius: 3 * glowOn),
                ],
              ),
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.0012)
                  ..rotateY(angle),
                child: face
                    ? Stack(
                        children: [
                          PlayingCard(suit: c.s, rank: c.r),
                          if (glowOn > 0)
                            Positioned.fill(
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(rw * 0.09),
                                  border: Border.all(color: (bad ? Lux.bordeauxLight : Lux.goldLight).withValues(alpha: glowOn), width: 2.5),
                                ),
                              ),
                            ),
                        ],
                      )
                    : const PlayingCard.back(),
              ),
            ),
          ),
        ),
      ));
    }
    if (ms >= verdictAt) {
      final t = math.min(1.0, (ms - verdictAt) / 380);
      final e = Curves.elasticOut.transform(t);
      final who = taker == 0 ? 'Yığını sen aldın' : 'Yığını ${names[taker]} aldı';
      out.add(Positioned(
        left: 0,
        right: 0,
        top: rowTop + rh + 10,
        child: IgnorePointer(
          child: Opacity(
            opacity: t.clamp(0, 1) * (1 - se),
            child: Transform.scale(
              scale: 0.6 + 0.4 * e,
              child: Column(
                children: [
                  Text(lie ? 'YALAN!' : 'DOĞRU!',
                      style: Lux.display(34, color: lie ? Lux.bordeauxLight : Lux.goldLight, spacing: 3)
                          .copyWith(shadows: [Shadow(color: (lie ? Lux.bordeaux : Lux.gold).withValues(alpha: 0.9), blurRadius: 18)])),
                  Text('$who · $count kart', style: Lux.ui(13, color: Lux.ink, weight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ),
      ));
    }
    return out;
  }

  List<Widget> _burnWidgets(_Geo g) {
    final t = _burn.value;
    final n = math.min(_burnN, 6);
    return [
      for (var k = 0; k < n; k++)
        Positioned(
          left: g.pile.dx - g.pw / 2 + (k - n / 2) * 6 * (1 + t * 3),
          top: g.pile.dy - g.ph / 2 - t * 50 - k * 3,
          width: g.pw * (1 - 0.4 * t),
          height: g.ph * (1 - 0.4 * t),
          child: IgnorePointer(
            child: Opacity(
              opacity: (1 - t).clamp(0, 1),
              child: Container(
                decoration: BoxDecoration(boxShadow: [
                  BoxShadow(color: const Color(0xFFE08A3C).withValues(alpha: 0.6 * math.sin(math.pi * t)), blurRadius: 18, spreadRadius: 2),
                ]),
                child: Transform.rotate(angle: (k - n / 2) * 0.2 * t, child: const PlayingCard.back()),
              ),
            ),
          ),
        ),
      Positioned(
        left: 0,
        right: 0,
        top: g.pile.dy - 12,
        child: IgnorePointer(
          child: Opacity(
            opacity: math.sin(math.pi * t).clamp(0, 1),
            child: Text('Yandı', textAlign: TextAlign.center, style: Lux.display(24, color: const Color(0xFFF3B36A))),
          ),
        ),
      ),
    ];
  }
}

/// The big bordeaux "Blöf!" button (pulses when it is the move the moment calls for).
class _BlofButton extends StatefulWidget {
  final VoidCallback onPressed;
  final bool pulse;
  const _BlofButton({required this.onPressed, this.pulse = false});

  @override
  State<_BlofButton> createState() => _BlofButtonState();
}

class _BlofButtonState extends State<_BlofButton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void initState() {
    super.initState();
    if (widget.pulse) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_BlofButton old) {
    super.didUpdateWidget(old);
    if (widget.pulse && !_c.isAnimating) _c.repeat(reverse: true);
    if (!widget.pulse && _c.isAnimating) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final p = widget.pulse ? _c.value : 0.0;
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(40),
            onTap: () {
              HapticFeedback.heavyImpact();
              widget.onPressed();
            },
            child: Ink(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(40),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFD13A5E), Color(0xFF7A1430)],
                ),
                border: Border.all(color: Color.lerp(Lux.bordeauxLight, Lux.goldLight, p)!, width: 1.4 + p),
                boxShadow: [
                  BoxShadow(color: Lux.bordeaux.withValues(alpha: 0.45 + 0.35 * p), blurRadius: 12 + 10 * p, offset: const Offset(0, 4)),
                ],
              ),
              child: Text('Blöf!', style: Lux.display(20, color: Colors.white, spacing: 1)),
            ),
          ),
        );
      },
    );
  }
}

/// Outlined gold pill (for "Pas" / "Geç").
class _PillButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _PillButton(this.label, {required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(40),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(40),
            color: const Color(0x22000000),
            border: Border.all(color: Lux.gold.withValues(alpha: 0.7)),
          ),
          child: Text(label, style: Lux.ui(15, color: Lux.goldLight, weight: FontWeight.w600, spacing: 0.8)),
        ),
      ),
    );
  }
}

/// Small round toggle in a table corner, with its label underneath.
class _CornerButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool on;
  final VoidCallback onTap;
  const _CornerButton({required this.icon, required this.label, required this.on, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: on ? Lux.gold.withValues(alpha: 0.22) : Lux.card,
                border: Border.all(color: on ? Lux.goldLight : Lux.gold.withValues(alpha: 0.5)),
                boxShadow: [
                  BoxShadow(color: (on ? Lux.gold : Colors.black).withValues(alpha: on ? 0.35 : 0.4), blurRadius: on ? 12 : 6),
                ],
              ),
              child: Icon(icon, size: 20, color: on ? Lux.goldLight : Lux.gold),
            ),
            const SizedBox(height: 2),
            Text(label, style: Lux.ui(10, color: on ? Lux.goldLight : Lux.muted)),
          ],
        ),
      ),
    );
  }
}

/// Tiny face-up card for open play (opponent hands, the true pile).
class _MiniCard extends StatelessWidget {
  final _Card c;
  final double width;
  final bool bad;
  const _MiniCard(this.c, {required this.width, this.bad = false});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: width / CardKit.aspect,
      child: CustomPaint(painter: _MiniPainter(c.s, c.r, bad)),
    );
  }
}

/// A legible miniature: big rank over a suit shape (the full card face is unreadable this small).
class _MiniPainter extends CustomPainter {
  final int suit, rank;
  final bool bad;
  _MiniPainter(this.suit, this.rank, this.bad);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final r = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(w * 0.14));
    canvas.drawRRect(r.shift(const Offset(0, 1)), Paint()..color = Colors.black.withValues(alpha: 0.35));
    canvas.drawRRect(r, Paint()..color = bad ? const Color(0xFFF6D3DB) : const Color(0xFFFBF4E2));
    canvas.drawRRect(
        r.deflate(0.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = bad ? 1.6 : 0.8
          ..color = bad ? Lux.bordeaux : Lux.goldDeep);
    final col = CardKit.suitColor(suit);
    final tp = TextPainter(
      text: TextSpan(
        text: CardKit.rankLabel(rank),
        style: TextStyle(fontFamily: 'Jost', fontSize: w * (rank == 10 ? 0.5 : 0.6), fontWeight: FontWeight.w700, color: col, height: 1),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset((w - tp.width) / 2, h * 0.1));
    canvas.drawPath(CardKit.suitPath(suit, Offset(w / 2, h * 0.72), w * 0.46), Paint()..color = col);
  }

  @override
  bool shouldRepaint(_MiniPainter old) => old.suit != suit || old.rank != rank || old.bad != bad;
}

/// Felt table: an oval of deep green baize with a gold rail, under the pile.
class _FeltPainter extends CustomPainter {
  final _Geo g;
  _FeltPainter(this.g);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 120 || g.tableBottom < 140) return;
    final w = size.width;
    final oval = Rect.fromLTRB(14, 12, w - 14, g.tableBottom - 10);
    final rr = RRect.fromRectAndRadius(oval, Radius.circular(math.min(oval.width, oval.height) * 0.45));
    canvas.drawRRect(rr.shift(const Offset(0, 8)),
        Paint()..color = Colors.black.withValues(alpha: 0.5)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18));
    // Rail.
    canvas.drawRRect(rr.inflate(7), Paint()..shader = Lux.foil.createShader(oval.inflate(7)));
    canvas.drawRRect(rr.inflate(2.5), Paint()..color = const Color(0xFF3A2A0E));
    // Baize.
    canvas.drawRRect(
      rr,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(0, -0.2),
          radius: 0.85,
          colors: [Color(0xFF17694F), Color(0xFF0C4535), Color(0xFF062A20)],
          stops: [0, 0.6, 1],
        ).createShader(oval),
    );
    canvas.drawRRect(
        rr.deflate(10),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Lux.gold.withValues(alpha: 0.22));
    // Pile seat ring.
    canvas.drawOval(
        Rect.fromCenter(center: g.pile, width: g.pw * 2.1, height: g.ph * 1.45),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = Lux.gold.withValues(alpha: 0.28));
  }

  @override
  bool shouldRepaint(_FeltPainter old) => old.g.size != g.size;
}
