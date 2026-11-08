import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../card_kit.dart';
import '../core_bridge.dart';
import '../lux.dart';

/// 21 — blackjack against the dealer, as a strategy trainer.
///
/// Layout (top → bottom): an info strip (chips, hand number, accuracy, the "Açık oyna" eye and, in
/// count mode, the count toggle), the felt (a U-shaped table with a padded rail and the gold arc
/// print, the shoe at the top-right, dealer cards on top, a middle zone for the open deck / coach
/// card, the player's hands and betting circle near the rail) and a thumb-zone control bar that
/// changes with the phase (chip tray + Dağıt, action buttons, insurance, next hand).
///
/// Cards are identified by the core's `id`s: every new id flies out of the shoe along an arc
/// (staggered, so a deal reads as four separate cards), landed cards glide when the layout shifts
/// (splits), vanished cards sweep off to the discard side, and the hole card flips when revealed.
/// Dealer steps (`{"ai":true}`, one card per call) run off the UI isolate after the previous card
/// has landed plus a short dealer pause. Bets: drag a chip onto the betting circle (or tap it).
Widget blackjackView(BuildContext context, GameSession s) => _BlackjackTable(key: ObjectKey(s), session: s);

const _flightDur = 0.42;
const _dealGap = 0.2;
const _flipDur = 0.34;

const _chipValues = [10, 25, 50, 100];

int _int(Object? v, [int d = 0]) => (v as num?)?.toInt() ?? d;
double _dbl(Object? v, [double d = 0]) => (v as num?)?.toDouble() ?? d;

String _fmt(num v) {
  final neg = v < 0;
  final a = v.abs();
  final whole = a.floor();
  final half = (a - whole) > 0.25;
  final s = whole.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
    b.write(s[i]);
  }
  if (half) b.write(',5');
  return '${neg ? '−' : ''}$b';
}

String _signed(num v) => v > 0 ? '+${_fmt(v)}' : (v == 0 ? '±0' : _fmt(v));

class _Face {
  final int suit, rank;
  const _Face(this.suit, this.rank);
}

class _Ghost {
  final Offset from;
  final _Face face;
  final bool down;
  final double at;
  _Ghost(this.from, this.face, this.down, this.at);
}

class _BlackjackTable extends StatefulWidget {
  final GameSession session;
  const _BlackjackTable({super.key, required this.session});

  @override
  State<_BlackjackTable> createState() => _BlackjackTableState();
}

class _BlackjackTableState extends State<_BlackjackTable> with SingleTickerProviderStateMixin {
  GameSession get s => widget.session;
  Map<String, dynamic> get st => s.state;

  late final Ticker _ticker = createTicker((_) => _onTick());
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;
  final _rand = math.Random();

  // Card motion model.
  final Map<int, double> _dealAt = {};
  final Map<int, _Face> _faces = {};
  final Map<int, Offset> _vis = {};
  final Map<int, Offset> _targets = {};
  final Map<int, bool> _wasDown = {};
  final List<_Ghost> _ghosts = [];
  double _lastScheduled = -10;
  int? _flipId;
  double _flipAt = -10;
  double _lastTick = 0;

  // Layout (felt-local).
  Size _felt = Size.zero;
  double _cw = 60;

  // UI state.
  bool _eye = false;
  bool _showCount = false;
  bool _aiBusy = false;
  String _entry = '';
  bool _chipHover = false;
  int _quizSeen = 0;
  double _quizAt = -10;
  int _feedbackSeen = 0;

  @override
  void initState() {
    super.initState();
    s.addListener(_sync);
    _quizSeen = _int((st['quiz'] as Map?)?['serial']);
    _feedbackSeen = _int((st['feedback'] as Map?)?['serial']);
    _sync();
  }

  @override
  void dispose() {
    s.removeListener(_sync);
    _ticker.dispose();
    super.dispose();
  }

  bool get _openMode => st['open'] == true;
  bool get _openVisible => _openMode || _eye;
  String get _phase => (st['phase'] as String?) ?? 'bet';
  String get _mode => (st['mode'] as String?) ?? 'classic';

  void _kick() {
    if (!_ticker.isActive) {
      _lastTick = _now;
      _ticker.start();
    }
  }

  // ---------------------------------------------------------------------------------------------
  // State diff → animations

  Iterable<Map> _tableCards() sync* {
    final d = st['dealer'];
    if (d is Map) {
      for (final c in (d['cards'] as List? ?? const [])) {
        yield c as Map;
      }
    }
    for (final h in (st['hands'] as List? ?? const [])) {
      for (final c in ((h as Map)['cards'] as List? ?? const [])) {
        yield c as Map;
      }
    }
  }

  void _sync() {
    if (!mounted) return;
    final now = _now;
    final seen = <int>{};
    // Deal order = id order (player, dealer up, player, hole…), whatever the state's layout.
    final cards = _tableCards().toList()..sort((a, b) => _int(a['id']).compareTo(_int(b['id'])));
    for (final c in cards) {
      final id = _int(c['id']);
      seen.add(id);
      final down = c['down'] == true;
      if (!_faces.containsKey(id)) {
        final at = math.max(now, _lastScheduled + _dealGap);
        _lastScheduled = at;
        _dealAt[id] = at;
        _wasDown[id] = down;
        if (!down && _isHoleId(id)) {
          // Dealt and revealed in the same step (a blackjack settles at once): land face down, flip.
          _flipId = id;
          _flipAt = at + _flightDur + 0.3;
          _lastScheduled = _flipAt + _flipDur - _dealGap + 0.05;
        }
      } else if (_wasDown[id] == true && !down) {
        // Hole card revealed: flip it once it has landed.
        _flipId = id;
        _flipAt = math.max(now, (_dealAt[id] ?? now) + _flightDur);
        _lastScheduled = math.max(_lastScheduled, _flipAt + _flipDur - _dealGap + 0.05);
        _wasDown[id] = false;
      }
      _faces[id] = _Face(_int(c['s']), _int(c['r']));
    }
    final gone = _faces.keys.where((id) => !seen.contains(id)).toList();
    for (final id in gone) {
      final from = _vis[id];
      if (from != null) _ghosts.add(_Ghost(from, _faces[id]!, false, now + _rand.nextDouble() * 0.08));
      _faces.remove(id);
      _dealAt.remove(id);
      _vis.remove(id);
      _wasDown.remove(id);
    }
    if (gone.isNotEmpty) _lastScheduled = math.max(_lastScheduled, now + 0.15);
    final q = st['quiz'];
    if (q is Map && _int(q['serial']) != _quizSeen) {
      _quizSeen = _int(q['serial']);
      _quizAt = now;
      _entry = '';
      HapticFeedback.mediumImpact();
    }
    final fb = st['feedback'];
    if (fb is Map && _int(fb['serial']) != _feedbackSeen) {
      _feedbackSeen = _int(fb['serial']);
      if (_mode == 'coach' || (_mode == 'count' && fb['correct'] != true)) {
        fb['correct'] == true ? HapticFeedback.lightImpact() : HapticFeedback.mediumImpact();
      }
    }
    _kick();
    _maybeDealer();
  }

  bool _isHoleId(int id) {
    final d = ((st['dealer'] as Map?)?['cards'] as List?) ?? const [];
    return d.length > 1 && _int((d[1] as Map)['id']) == id;
  }

  /// The hole card is still shown face down (state may already say revealed while we animate).
  bool get _holeHiddenVisually {
    final d = ((st['dealer'] as Map?)?['cards'] as List?) ?? const [];
    if (d.length < 2) return false;
    final hole = d[1] as Map;
    return hole['down'] == true || (_int(hole['id']) == _flipId && _now < _flipAt + _flipDur * 0.5);
  }

  double _animEnd() {
    var end = _now;
    for (final t in _dealAt.values) {
      end = math.max(end, t + _flightDur);
    }
    if (_flipId != null) end = math.max(end, _flipAt + _flipDur);
    return end;
  }

  void _maybeDealer() {
    if (!mounted || _aiBusy || s.finished || st['ai_pending'] != true) return;
    _aiBusy = true;
    final now = _now;
    final wait = math.max(0.0, _animEnd() - now);
    final dealerCards = ((st['dealer'] as Map?)?['cards'] as List?)?.length ?? 0;
    final pause = dealerCards <= 2 ? 0.5 + _rand.nextDouble() * 0.2 : 0.6 + _rand.nextDouble() * 0.3;
    final session = s;
    Future.delayed(Duration(milliseconds: ((wait + pause) * 1000).round()), () async {
      if (!mounted || !identical(session, s)) return;
      if (st['ai_pending'] != true) {
        _aiBusy = false;
        return;
      }
      final ok = await s.actAsync({'ai': true});
      if (!mounted) return;
      _aiBusy = false;
      if (ok) WidgetsBinding.instance.addPostFrameCallback((_) => _maybeDealer());
    });
  }

  void _onTick() {
    final now = _now;
    final dt = (now - _lastTick).clamp(0.0, 0.05);
    _lastTick = now;
    _ghosts.removeWhere((g) => now - g.at > 0.5);
    var moving = false;
    final k = 1 - math.exp(-dt * 16);
    for (final e in _targets.entries) {
      final at = _dealAt[e.key];
      if (at == null || now < at + _flightDur) continue;
      final v = _vis[e.key];
      if (v == null) {
        _vis[e.key] = e.value;
      } else if ((v - e.value).distance > 0.3) {
        _vis[e.key] = Offset.lerp(v, e.value, k)!;
        moving = true;
      } else {
        _vis[e.key] = e.value;
      }
    }
    final busy = moving ||
        _ghosts.isNotEmpty ||
        _dealAt.values.any((t) => now < t + _flightDur + 0.05) ||
        now < _flipAt + _flipDur + 0.05 ||
        _aiBusy ||
        now - _quizAt < 4.5;
    if (!busy) _ticker.stop();
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------------------------------------
  // Actions

  void _act(Map<String, dynamic> a) {
    HapticFeedback.selectionClick();
    final ok = s.act(a);
    if (!ok) HapticFeedback.mediumImpact();
  }

  void _addChip(int v) {
    if (_phase != 'bet') return;
    _act({'bet': _int(st['bet']) + v});
  }

  void _toggleEye() {
    if (_openMode) return;
    setState(() => _eye = !_eye);
    if (_eye && st['peeked'] != true) s.act({'reveal': true});
  }

  // ---------------------------------------------------------------------------------------------
  // Geometry (felt-local coordinates)

  Size get _cardSize => Size(_cw, _cw / CardKit.aspect);

  Offset get _shoeMouth => Offset(_felt.width - 70, 18);

  double get _dealerTop => _felt.height * 0.035;

  /// Top-left of every card on the table (dealer + hands) and the hand anchors.
  void _layoutCards(List hands, List dealerCards) {
    _targets.clear();
    final w = _felt.width, h = _felt.height;
    // Dealer: a horizontal fan centred at the top.
    final dc = dealerCards.length;
    final ddx = _cw * 0.56;
    final dLeft = w / 2 - (_cw + ddx * math.max(0, dc - 1)) / 2;
    for (var i = 0; i < dc; i++) {
      _targets[_int((dealerCards[i] as Map)['id'])] = Offset(dLeft + i * ddx, _dealerTop);
    }
    // Hands: side by side; cards cascade up and to the right.
    final n = hands.length;
    if (n == 0) return;
    final pc = _playerCw(hands);
    final ph = pc / CardKit.aspect;
    final baseTop = h * 0.8 - ph;
    for (var i = 0; i < n; i++) {
      final cards = (hands[i] as Map)['cards'] as List;
      final k = cards.length;
      final cx = _handCx(i, n);
      final width = pc + (k - 1) * pc * 0.3;
      final left = cx - width / 2;
      final lift = i == _int(st['active']) && _phase == 'play' ? -8.0 : 0.0;
      for (var j = 0; j < k; j++) {
        _targets[_int((cards[j] as Map)['id'])] = Offset(left + j * pc * 0.3, baseTop - j * pc * 0.17 + lift);
      }
    }
  }

  double _handCx(int i, int n) {
    final w = _felt.width;
    final span = n == 1 ? 0.0 : w * (n == 2 ? 0.5 : 0.76);
    return n == 1 ? w / 2 : w / 2 - span / 2 + span * i / (n - 1);
  }

  double _playerCw(List hands) {
    final n = math.max(1, hands.length);
    var kmax = 2;
    for (final h in hands) {
      kmax = math.max(kmax, ((h as Map)['cards'] as List).length);
    }
    final slot = _felt.width / n;
    return math.min(_cw, slot * 0.9 / (1 + 0.3 * (kmax - 1)));
  }

  bool _isPlayerCard(int id) {
    for (final h in (st['hands'] as List? ?? const [])) {
      for (final c in ((h as Map)['cards'] as List)) {
        if (_int((c as Map)['id']) == id) return true;
      }
    }
    return false;
  }

  // ---------------------------------------------------------------------------------------------
  // Build

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _infoStrip(),
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            _felt = Size(c.maxWidth, c.maxHeight);
            _cw = math.min(c.maxWidth * 0.18, c.maxHeight * 0.15 * CardKit.aspect);
            return _table();
          }),
        ),
        _controls(),
      ],
    );
  }

  Widget _infoStrip() {
    final counters = (st['counters'] as Map?) ?? const {};
    final acc = counters['accuracy'];
    final chips = _dbl(st['chips'], 1000);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 8, 4),
      child: Row(
        children: [
          const SizedBox(width: 22, height: 22, child: CustomPaint(painter: _ChipPainter(100))),
          const SizedBox(width: 8),
          TweenAnimationBuilder<double>(
            tween: Tween(end: chips),
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeOutCubic,
            builder: (context, v, _) => Text(_fmt((v * 2).round() / 2), style: Lux.numeral(24)),
          ),
          const SizedBox(width: 12),
          Text('El ${_int(st['hand_no'], 1)}/${_int(st['hands_total'], 40)}', style: Lux.ui(13, color: Lux.muted)),
          if (acc != null) ...[
            const SizedBox(width: 10),
            Text('Doğru %$acc', style: Lux.ui(13, color: Lux.goldLight)),
          ],
          const Spacer(),
          if (_mode == 'count')
            _toggle(Icons.calculate_outlined, _showCount, 'Sayım', 'Sayımı göster / gizle',
                () => setState(() => _showCount = !_showCount)),
          _toggle(_openVisible ? Icons.visibility_rounded : Icons.visibility_off_outlined, _openVisible, 'Açık',
              _openMode ? 'Açık deste masası' : 'Açık oyna: kapalı kart ve sıradaki kartlar', _openMode ? null : _toggleEye),
        ],
      ),
    );
  }

  Widget _toggle(IconData icon, bool on, String label, String tip, VoidCallback? onTap) {
    return Tooltip(
      message: tip,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.only(left: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: on ? Lux.gold.withValues(alpha: 0.18) : Colors.transparent,
            border: Border.all(color: on ? Lux.gold : Lux.line),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 18, color: on ? Lux.goldLight : Lux.muted),
            const SizedBox(width: 4),
            Text(label, style: Lux.ui(12, color: on ? Lux.goldLight : Lux.muted)),
          ]),
        ),
      ),
    );
  }

  Widget _table() {
    final now = _now;
    final hands = (st['hands'] as List?) ?? const [];
    final dealer = (st['dealer'] as Map?) ?? const {};
    final dealerCards = (dealer['cards'] as List?) ?? const [];
    _layoutCards(hands, dealerCards);
    final w = _felt.width, h = _felt.height;
    final cs = _cardSize;
    final animDone = now >= _animEnd() - 0.01;
    final thinking = st['ai_pending'] == true;

    final children = <Widget>[
      Positioned.fill(child: CustomPaint(painter: _FeltPainter(insurance: st['insurance']?['offered'] == true))),
      // Dealer glow while the dealer plays.
      if (thinking)
        Positioned(
          left: w / 2 - w * 0.35,
          top: _dealerTop - 20,
          width: w * 0.7,
          height: cs.height + 40,
          child: IgnorePointer(
            child: Opacity(
              opacity: 0.35 + 0.25 * math.sin(now * 5).abs(),
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(colors: [Color(0x66F0D69A), Color(0x00F0D69A)]),
                ),
              ),
            ),
          ),
        ),
      // The shoe.
      Positioned(
        left: w - 74,
        top: 4,
        width: 66,
        height: 84,
        child: CustomPaint(
          painter: _ShoePainter(
            fill: _int(st['shoe_left'], 312) / math.max(1, _int(st['shoe_total'], 312)),
            cut: 1 - _int(st['cut_left']) / math.max(1, _int(st['shoe_total'], 312)),
          ),
        ),
      ),
      // Dealer total pill.
      if (dealerCards.isNotEmpty)
        Positioned(
          left: 0,
          right: 0,
          top: _dealerTop + cs.height + 6,
          child: Center(
            child: AnimatedOpacity(
              opacity: dealerCards.any((c) => now >= (_dealAt[_int((c as Map)['id'])] ?? 0) + _flightDur * 0.8) ? 1 : 0,
              duration: const Duration(milliseconds: 160),
              child: _pill(_dealerLabel(dealer), prefix: 'Krupiye'),
            ),
          ),
        ),
      ..._betCircles(hands),
      ..._handPills(hands, animDone),
    ];

    // Cards (dealer first so player cards overlap the felt print correctly).
    final ids = _targets.keys.toList()..sort();
    for (final id in ids) {
      final at = _dealAt[id] ?? now;
      if (now < at) continue;
      final face = _faces[id];
      if (face == null) continue;
      final target = _targets[id]!;
      final player = _isPlayerCard(id);
      final size = player ? Size(_playerCw(hands), _playerCw(hands) / CardKit.aspect) : cs;
      Offset pos;
      var rot = 0.0;
      final t = ((now - at) / _flightDur).clamp(0.0, 1.0);
      if (t < 1) {
        final e = Curves.easeOutCubic.transform(t);
        final from = _shoeMouth - Offset(size.width * 0.6, 0);
        final ctrl = Offset((from.dx + target.dx) / 2, math.min(from.dy, target.dy) - 30);
        pos = _quad(from, ctrl, target, e);
        rot = (1 - e) * -0.9;
      } else {
        pos = _vis[id] ?? target;
      }
      children.add(Positioned(
        left: pos.dx,
        top: pos.dy,
        width: size.width,
        height: size.height,
        child: Transform.rotate(angle: rot, child: _card(id, face, t < 1, hands)),
      ));
    }
    for (final g in _ghosts) {
      final t = ((now - g.at) / 0.45).clamp(0.0, 1.0);
      final e = Curves.easeInCubic.transform(t);
      final to = Offset(-cs.width * 1.2, h * 0.1);
      children.add(Positioned(
        left: g.from.dx + (to.dx - g.from.dx) * e,
        top: g.from.dy + (to.dy - g.from.dy) * e,
        width: cs.width,
        height: cs.height,
        child: Opacity(
          opacity: (1 - t).clamp(0.0, 1.0),
          child: Transform.rotate(angle: -0.6 * e, child: const PlayingCard.back()),
        ),
      ));
    }

    children.add(_middleZone(animDone));
    if (_mode == 'count' && _showCount) children.add(_countOverlay());
    if (_phase == 'play' || _phase == 'insurance') {
      children.add(Positioned(
        left: 6,
        bottom: 6,
        child: RimIconButton(Icons.lightbulb_outline_rounded, tooltip: 'İpucu', onPressed: () => _act({'hint': true})),
      ));
    }
    if (_phase == 'count_quiz' && animDone) children.add(_quizPad());
    return Stack(clipBehavior: Clip.none, children: children);
  }

  static Offset _quad(Offset a, Offset c, Offset b, double t) {
    final u = 1 - t;
    return a * (u * u) + c * (2 * u * t) + b * (t * t);
  }

  String _dealerLabel(Map dealer) {
    final cards = (dealer['cards'] as List?) ?? const [];
    var label = (dealer['label'] as String?) ?? '';
    final hidden = _holeHiddenVisually;
    if (hidden && cards.isNotEmpty) {
      final r = _int((cards[0] as Map)['r']);
      label = r == 14 ? 'Yumuşak 11' : '${r >= 11 ? 10 : r}';
    }
    if (hidden && _openVisible) return '$label · (${_int(dealer['full_total'])})';
    return label;
  }

  Widget _card(int id, _Face face, bool flying, List hands) {
    final dealer = (st['dealer'] as Map?) ?? const {};
    final dcards = (dealer['cards'] as List?) ?? const [];
    final isHole = dcards.length > 1 && _int((dcards[1] as Map)['id']) == id;
    final now = _now;
    final down = isHole && ((dcards[1] as Map)['down'] == true || (id == _flipId && now < _flipAt));
    // Active hand highlight.
    var highlight = false;
    var dim = false;
    final active = _int(st['active']);
    for (var i = 0; i < hands.length; i++) {
      final hm = hands[i] as Map;
      if ((hm['cards'] as List).any((c) => _int((c as Map)['id']) == id)) {
        highlight = _phase == 'play' && i == active && hands.length > 1;
        dim = hm['state'] == 'bust' && !flying;
      }
    }
    if (down) {
      if (_openVisible) {
        return Stack(fit: StackFit.expand, children: [
          Opacity(opacity: 0.86, child: PlayingCard(suit: face.suit, rank: face.rank)),
          Positioned(
            right: 3,
            top: 3,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(color: Color(0xCC05271D), shape: BoxShape.circle),
              child: const Icon(Icons.visibility_rounded, size: 12, color: Lux.goldLight),
            ),
          ),
        ]);
      }
      return const PlayingCard.back();
    }
    if (id == _flipId && now < _flipAt + _flipDur) {
      final t = ((now - _flipAt) / _flipDur).clamp(0.0, 1.0);
      final sx = (1 - 2 * t).abs().clamp(0.02, 1.0);
      return Transform.scale(
        scaleX: sx,
        child: t < 0.5 && !_openVisible ? const PlayingCard.back() : PlayingCard(suit: face.suit, rank: face.rank),
      );
    }
    return PlayingCard(suit: face.suit, rank: face.rank, highlight: highlight, dim: dim);
  }

  Widget _pill(String text, {bool gold = false, String? prefix, Color? color, double? chip}) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: gold ? Lux.gold.withValues(alpha: 0.9) : const Color(0xCC04211A),
        border: Border.all(color: color ?? (gold ? Lux.goldLight : Lux.gold.withValues(alpha: 0.6))),
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 6, offset: Offset(0, 2))],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (prefix != null) ...[
          Text(Lux.upper(prefix), style: Lux.ui(9.5, color: gold ? const Color(0xFF2A1D05) : Lux.muted, spacing: 1.2)),
          const SizedBox(width: 6),
        ],
        Text(text, style: Lux.ui(13, color: color ?? (gold ? const Color(0xFF2A1D05) : Lux.goldLight), weight: FontWeight.w600)),
        if (chip != null) ...[
          const SizedBox(width: 6),
          SizedBox(width: 13, height: 13, child: CustomPaint(painter: _ChipPainter(chip >= 100 ? 100 : chip >= 50 ? 50 : 25, label: false))),
          const SizedBox(width: 3),
          Text(_fmt(chip), style: Lux.ui(11.5, color: gold ? const Color(0xFF2A1D05) : Lux.ink)),
        ],
      ]),
    );
  }

  List<Widget> _handPills(List hands, bool animDone) {
    final out = <Widget>[];
    final n = hands.length;
    final active = _int(st['active']);
    for (var i = 0; i < n; i++) {
      final hm = hands[i] as Map;
      final cx = _handCx(i, n);
      final isActive = _phase == 'play' && i == active;
      // Total pill (shown once the hand's cards have landed).
      final ids = (hm['cards'] as List).map((c) => _int((c as Map)['id']));
      final landed = ids.every((id) => _now >= (_dealAt[id] ?? 0) + _flightDur * 0.8);
      final label = (hm['label'] as String?) ?? '';
      out.add(Positioned(
        left: cx - 80,
        width: 160,
        top: _felt.height * 0.8 + 4,
        child: Center(
          child: AnimatedOpacity(
            opacity: landed && label.isNotEmpty ? 1 : 0,
            duration: const Duration(milliseconds: 160),
            child: _pill(label + (hm['doubled'] == true ? ' · ×2' : ''),
                gold: isActive, color: hm['state'] == 'bust' ? Lux.bordeauxLight : null, chip: n > 1 ? _dbl(hm['bet']) : null),
          ),
        ),
      ));
      // Result badge after settlement.
      final res = hm['result'] as String?;
      if (res != null && _phase == 'settle' && animDone) {
        final net = _dbl(hm['net']);
        final (txt, col) = switch (res) {
          'blackjack' => ('Blackjack ${_signed(net)}', Lux.goldLight),
          'win' => ('Kazandın ${_signed(net)}', Lux.goldLight),
          'push' => ('Berabere ±0', Lux.ink),
          'bust' => ('Battı ${_signed(net)}', Lux.bordeauxLight),
          _ => ('Kaybettin ${_signed(net)}', Lux.bordeauxLight),
        };
        final pc = _playerCw(hands);
        out.add(Positioned(
          left: cx - 90,
          width: 180,
          top: _felt.height * 0.8 - pc / CardKit.aspect - 34,
          child: Center(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 420),
              curve: Curves.easeOutBack,
              builder: (context, t, child) => Transform.scale(scale: 0.6 + 0.4 * t, child: Opacity(opacity: t.clamp(0, 1), child: child)),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: const Color(0xEE05241C),
                  border: Border.all(color: col.withValues(alpha: 0.8), width: 1.2),
                  boxShadow: const [BoxShadow(color: Color(0x88000000), blurRadius: 10, offset: Offset(0, 4))],
                ),
                child: Text(txt, style: Lux.ui(13.5, color: col, weight: FontWeight.w700)),
              ),
            ),
          ),
        ));
      }
    }
    return out;
  }

  /// Betting circle: the drop target in the bet phase, the wager in front of a single hand.
  /// (Split hands show their wagers in their total pills.)
  List<Widget> _betCircles(List hands) {
    final w = _felt.width, h = _felt.height;
    if (_phase == 'bet' || hands.isEmpty) {
      final bet = _phase == 'bet' ? _int(st['bet']) : 0;
      final r = math.min(w * 0.15, h * 0.095);
      final c = Offset(w / 2, h * 0.7);
      return [
        Positioned(
          left: c.dx - r * 1.3,
          top: c.dy - r * 1.3,
          width: r * 2.6,
          height: r * 2.6,
          child: DragTarget<int>(
            onWillAcceptWithDetails: (d) {
              if (!_chipHover) setState(() => _chipHover = true);
              return _phase == 'bet';
            },
            onLeave: (_) => setState(() => _chipHover = false),
            onAcceptWithDetails: (d) {
              setState(() => _chipHover = false);
              _addChip(d.data);
            },
            builder: (context, cand, rej) => GestureDetector(
              onTap: _phase == 'bet' && bet > 0 ? () => _act({'bet': 0}) : null,
              child: CustomPaint(painter: _BetCirclePainter(bet: bet, hover: _chipHover, active: _phase == 'bet')),
            ),
          ),
        ),
      ];
    }
    if (hands.length > 1) return const [];
    final r = math.min(w * 0.1, h * 0.055);
    final c = Offset(w / 2, h * 0.905);
    return [
      Positioned(
        left: c.dx - r * 1.3,
        top: c.dy - r * 1.3,
        width: r * 2.6,
        height: r * 2.6,
        child: IgnorePointer(
          child: CustomPaint(painter: _BetCirclePainter(bet: _dbl((hands[0] as Map)['bet']), hover: false, active: false)),
        ),
      ),
    ];
  }

  // ---------------------------------------------------------------------------------------------
  // Middle zone: open deck, coach card, hint, open-play comparison, count quiz result

  Widget _middleZone(bool animDone) {
    final h = _felt.height;
    final items = <Widget>[];
    final next = (st['next_cards'] as List?) ?? const [];
    if (_openVisible && next.isNotEmpty && _phase != 'done') {
      items.add(_openDeckRow(next));
    }
    final info = _infoCard(animDone);
    items.add(AnimatedSwitcher(
      duration: const Duration(milliseconds: 360),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, a) => FadeTransition(
        opacity: a,
        child: SlideTransition(position: Tween(begin: const Offset(0, 0.35), end: Offset.zero).animate(a), child: child),
      ),
      child: info ?? const SizedBox(key: ValueKey('none')),
    ));
    final dealerBottom = _dealerTop + _cardSize.height + 34;
    final hands = (st['hands'] as List?) ?? const [];
    var maxCards = 2;
    for (final hm in hands) {
      maxCards = math.max(maxCards, ((hm as Map)['cards'] as List).length);
    }
    final pc = _playerCw(hands);
    final playerTop = h * 0.8 - pc / CardKit.aspect - pc * 0.17 * (maxCards - 1) - 10;
    return Positioned(
      left: 12,
      right: 12,
      top: dealerBottom,
      height: math.max(60, playerTop - dealerBottom),
      child: Column(
        mainAxisAlignment: hands.isEmpty ? MainAxisAlignment.center : MainAxisAlignment.start,
        children: [
          for (final w in items) Flexible(child: w),
        ],
      ),
    );
  }

  Widget _openDeckRow(List next) {
    final sw = _cw * 0.5;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(Lux.upper('Açık deste'), style: Lux.ui(10, color: Lux.gold, spacing: 1.6)),
          const SizedBox(width: 8),
          for (var i = 0; i < next.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: SizedBox(
                width: sw,
                child: PlayingCard(
                  suit: _int((next[i] as Map)['s']),
                  rank: _int((next[i] as Map)['r']),
                  highlight: i == 0,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget? _infoCard(bool animDone) {
    final phase = _phase;
    if (phase == 'count_quiz' || phase == 'done') return null;
    final hint = st['hint'];
    if (hint is Map && (phase == 'play' || phase == 'insurance')) {
      return _note(
        key: ValueKey('hint${hint['best']}${st['active']}'),
        tone: _Tone.gold,
        title: 'İpucu · ${hint['best_label']}',
        body: hint['reason'] as String? ?? '',
        extra: hint['deviation'] as String?,
      );
    }
    final oh = st['open_hint'];
    if (_openVisible && oh is Map && (phase == 'play' || phase == 'insurance')) {
      final same = oh['same'] == true;
      return _note(
        key: ValueKey('open${oh['best']}${oh['bs']}${oh['reason']}'),
        tone: same ? _Tone.gold : _Tone.violet,
        title: same ? 'Açık bilgi · ${oh['best_label']}' : 'Temel: ${oh['bs_label']}  ·  Açık bilgi: ${oh['best_label']}',
        body: oh['reason'] as String? ?? '',
      );
    }
    final fb = st['feedback'];
    final showFb = _mode == 'coach' || (_mode == 'count' && fb is Map && (fb['correct'] != true || fb['deviation'] != null));
    if (fb is Map && showFb && phase != 'bet') {
      final ok = fb['correct'] == true;
      return _note(
        key: ValueKey('fb${fb['serial']}'),
        tone: ok ? _Tone.gold : _Tone.bordeaux,
        title: ok ? 'Doğru · ${fb['action_label']}' : 'Yanlış · Doğrusu: ${fb['best_label']}',
        body: fb['reason'] as String? ?? '',
        extra: fb['deviation'] as String?,
        icon: ok ? Icons.check_circle_rounded : Icons.cancel_rounded,
      );
    }
    final q = st['quiz'];
    if (q is Map && phase == 'bet' && _now - _quizAt < 4.5) {
      final ok = q['correct'] == true;
      final actual = _int(q['actual']);
      return _note(
        key: ValueKey('quiz${q['serial']}'),
        tone: ok ? _Tone.gold : _Tone.bordeaux,
        title: ok ? 'Doğru sayım: ${actual > 0 ? '+' : ''}$actual' : 'Sayım ${actual > 0 ? '+' : ''}$actual olmalıydı',
        body: 'Gerçek sayım ${q['true_count_text']} (${_fmtDeck(_dbl(q['decks_left']))} deste kaldı).'
            '${ok ? '' : ' Senin cevabın: ${_int(q['answer']) > 0 ? '+' : ''}${q['answer']}.'}',
        icon: ok ? Icons.check_circle_rounded : Icons.cancel_rounded,
      );
    }
    if (phase == 'bet' && st['shuffled'] == true) {
      return _note(
        key: const ValueKey('shuffle'),
        tone: _Tone.gold,
        title: 'Deste karıştırıldı',
        body: _mode == 'count' ? 'Kesme kartı çıktı: yeni sabot, sayım sıfırdan başlar.' : 'Kesme kartı çıktı: yeni sabot.',
        icon: Icons.shuffle_rounded,
      );
    }
    if (phase == 'insurance' && animDone) {
      return _note(
        key: const ValueKey('ins'),
        tone: _Tone.gold,
        title: 'Krupiye As gösteriyor',
        body: 'Sigorta ister misin? Bahsinin yarısı; krupiyede blackjack varsa 2:1 öder.',
        icon: Icons.shield_outlined,
      );
    }
    return null;
  }

  String _fmtDeck(double d) => d.toStringAsFixed(1).replaceAll('.', ',');

  Widget _note({required Key key, required _Tone tone, required String title, required String body, String? extra, IconData? icon}) {
    final (bg, rim, ink) = switch (tone) {
      _Tone.gold => (const Color(0xF0082E23), Lux.gold, Lux.goldLight),
      _Tone.bordeaux => (const Color(0xF02A0F17), Lux.bordeaux, Lux.bordeauxLight),
      _Tone.violet => (const Color(0xF01C1430), const Color(0xFFB79CE8), const Color(0xFFDCCBFF)),
    };
    return Container(
      key: key,
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: rim.withValues(alpha: 0.85), width: 1.2),
        boxShadow: const [BoxShadow(color: Color(0x99000000), blurRadius: 16, offset: Offset(0, 6))],
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              if (icon != null) ...[Icon(icon, size: 18, color: ink), const SizedBox(width: 6)],
              Expanded(child: Text(title, style: Lux.ui(15, color: ink, weight: FontWeight.w700))),
            ]),
            const SizedBox(height: 4),
            Text(body, style: Lux.ui(13, color: Lux.ink)),
            if (extra != null) ...[
              const SizedBox(height: 4),
              Text(extra, style: Lux.ui(12.5, color: Lux.goldLight, weight: FontWeight.w600)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _countOverlay() {
    final rc = _int(st['running_count']);
    return Positioned(
      left: 8,
      top: 6,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
          decoration: BoxDecoration(
            color: const Color(0xDD03190F),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Lux.gold.withValues(alpha: 0.7)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Sayım ${rc > 0 ? '+' : ''}$rc', style: Lux.numeral(19)),
              Text('Gerçek ${st['true_count_text'] ?? '0,0'}', style: Lux.ui(12, color: Lux.goldLight)),
              Text('${_fmtDeck(_dbl(st['decks_left']))} deste', style: Lux.ui(11, color: Lux.muted)),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------------------------
  // Count quiz number pad

  Widget _quizPad() {
    Widget key(String label, VoidCallback onTap, {bool gold = false, IconData? icon}) => Padding(
          padding: const EdgeInsets.all(4),
          child: Material(
            color: gold ? Lux.gold.withValues(alpha: 0.2) : Lux.cardDeep,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () {
                HapticFeedback.selectionClick();
                onTap();
              },
              child: Container(
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Lux.gold.withValues(alpha: gold ? 0.9 : 0.4)),
                ),
                child: icon != null
                    ? Icon(icon, color: Lux.ink, size: 22)
                    : Text(label, style: Lux.numeral(24, color: gold ? Lux.goldLight : Lux.ink)),
              ),
            ),
          ),
        );
    void digit(int d) => setState(() {
          final neg = _entry.startsWith('-');
          final body = '${neg ? _entry.substring(1) : _entry}$d';
          if (body.length > 2) return;
          _entry = '${neg ? '-' : ''}${int.parse(body)}';
        });
    final shown = _entry.isEmpty ? '?' : (_entry.startsWith('-') ? '−${_entry.substring(1)}' : (_entry == '0' ? '0' : '+$_entry'));
    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0x99000000),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: LuxCard(
              highlight: true,
              padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(Lux.upper('Sayım kaç?'), style: Lux.display(22)),
                  const SizedBox(height: 2),
                  Text('Hi-Lo: 2–6 = +1, 7–9 = 0, 10/As = −1', style: Lux.ui(12, color: Lux.muted)),
                  const SizedBox(height: 10),
                  Text(shown, style: Lux.numeral(44)),
                  const SizedBox(height: 8),
                  for (final row in const [
                    [1, 2, 3],
                    [4, 5, 6],
                    [7, 8, 9],
                  ])
                    Row(children: [for (final d in row) Expanded(child: key('$d', () => digit(d)))]),
                  Row(children: [
                    Expanded(
                      child: key('±', () {
                        setState(() {
                          if (_entry.isEmpty || _entry == '0') {
                            _entry = '-';
                          } else {
                            _entry = _entry.startsWith('-') ? _entry.substring(1) : '-$_entry';
                          }
                        });
                      }),
                    ),
                    Expanded(child: key('0', () => digit(0))),
                    Expanded(
                      child: key('', () {
                        setState(() => _entry = _entry.isEmpty ? '' : _entry.substring(0, _entry.length - 1));
                      }, icon: Icons.backspace_outlined),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  GoldButton('Onayla', icon: Icons.check_rounded, onPressed: () {
                    final v = int.tryParse(_entry == '-' ? '' : _entry);
                    if (v == null) {
                      HapticFeedback.mediumImpact();
                      return;
                    }
                    _act({'count_answer': v});
                  }),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------------------------
  // Thumb-zone controls

  Widget _controls() {
    final phase = _phase;
    Widget body;
    switch (phase) {
      case 'bet':
        body = _betControls();
      case 'insurance':
        final cost = _dbl((st['insurance'] as Map?)?['cost']);
        body = Row(children: [
          Expanded(child: _bigButton('Sigorta al', Icons.shield_rounded, () => _act({'insurance': true}), sub: _fmt(cost))),
          const SizedBox(width: 10),
          Expanded(child: _bigButton('Sigorta yok', Icons.block_rounded, () => _act({'insurance': false}), primary: true)),
        ]);
      case 'play':
        final can = (st['can'] as Map?) ?? const {};
        body = Row(children: [
          Expanded(child: _bigButton('Kart', Icons.add_rounded, () => _act({'hit': true}), primary: true)),
          const SizedBox(width: 8),
          Expanded(child: _bigButton('Dur', Icons.pan_tool_alt_rounded, () => _act({'stand': true}), primary: true)),
          const SizedBox(width: 8),
          Expanded(child: _bigButton('İkiye katla', Icons.exposure_plus_2_rounded, can['double'] == true ? () => _act({'double': true}) : null)),
          const SizedBox(width: 8),
          Expanded(child: _bigButton('Böl', Icons.call_split_rounded, can['split'] == true ? () => _act({'split': true}) : null)),
        ]);
      case 'dealer':
        body = const SizedBox(
          height: 64,
          child: Center(child: _DealerThinking(color: Lux.goldLight, text: 'Krupiye oynuyor')),
        );
      case 'settle':
        final animDone = _now >= _animEnd() - 0.01;
        final last = _int(st['hand_no']) >= _int(st['hands_total'], 40);
        body = AnimatedOpacity(
          opacity: animDone ? 1 : 0.3,
          duration: const Duration(milliseconds: 200),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text((st['message'] as String?) ?? '', style: Lux.ui(16, color: _dbl(st['round_net']) >= 0 ? Lux.goldLight : Lux.bordeauxLight, weight: FontWeight.w700)),
                  Text('El ${_int(st['hand_no'])}/${_int(st['hands_total'], 40)} bitti', style: Lux.ui(12.5, color: Lux.muted)),
                ],
              ),
            ),
            GoldButton(last ? 'Sonucu gör' : 'Sonraki el', icon: Icons.arrow_forward_rounded, onPressed: animDone ? () => _act({'next': true}) : null),
          ]),
        );
      case 'count_quiz':
        body = SizedBox(height: 64, child: Center(child: Text('Sayımı gir', style: Lux.ui(15, color: Lux.muted))));
      default:
        body = const SizedBox(height: 64);
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
      constraints: const BoxConstraints(minHeight: 96),
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x0003190F), Color(0xCC03190F)]),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: KeyedSubtree(key: ValueKey(phase), child: body),
      ),
    );
  }

  Widget _betControls() {
    final bet = _int(st['bet']);
    final advice = (st['bet_advice'] as Map?)?['text'] as String?;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_mode == 'count' && _showCount && advice != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(advice, textAlign: TextAlign.center, style: Lux.ui(12.5, color: Lux.goldLight)),
          ),
        Row(
          children: [
            for (final v in _chipValues)
              Expanded(
                child: Center(
                  child: Draggable<int>(
                    data: v,
                    feedback: SizedBox(width: 64, height: 64, child: CustomPaint(painter: _ChipPainter(v, lifted: true))),
                    childWhenDragging: Opacity(opacity: 0.35, child: _trayChip(v)),
                    onDragStarted: HapticFeedback.selectionClick,
                    child: GestureDetector(onTap: () => _addChip(v), child: _trayChip(v)),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            GoldButton('Temizle', outlined: true, onPressed: bet > 0 ? () => _act({'bet': 0}) : null),
            const SizedBox(width: 10),
            Expanded(
              child: Text(bet > 0 ? 'Bahis: ${_fmt(bet)}' : 'Fişi çembere sürükle',
                  textAlign: TextAlign.center, style: Lux.ui(14, color: Lux.muted)),
            ),
            GoldButton('Dağıt', icon: Icons.style_rounded, onPressed: bet >= _int(st['min_bet'], 10) ? () => _act({'deal': true}) : null),
          ],
        ),
      ],
    );
  }

  Widget _trayChip(int v) => SizedBox(width: 56, height: 56, child: CustomPaint(painter: _ChipPainter(v)));

  Widget _bigButton(String label, IconData icon, VoidCallback? onTap, {bool primary = false, String? sub}) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.35,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Ink(
            height: 68,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: primary && enabled ? Lux.foil : Lux.velvetCard,
              border: Border.all(color: Lux.gold.withValues(alpha: primary ? 0.95 : 0.6), width: 1.2),
              boxShadow: const [BoxShadow(color: Color(0x88000000), blurRadius: 10, offset: Offset(0, 4))],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 22, color: primary && enabled ? const Color(0xFF2A1D05) : Lux.goldLight),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(sub == null ? label : '$label · $sub',
                      style: Lux.ui(13.5, color: primary && enabled ? const Color(0xFF2A1D05) : Lux.ink, weight: FontWeight.w700)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _Tone { gold, bordeaux, violet }

class _DealerThinking extends StatefulWidget {
  final Color color;
  final String text;
  const _DealerThinking({required this.color, required this.text});

  @override
  State<_DealerThinking> createState() => _DealerThinkingState();
}

class _DealerThinkingState extends State<_DealerThinking> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();

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
        final n = (_c.value * 4).floor();
        return Text('${widget.text}${'.' * n}${' ' * (3 - math.min(3, n))}', style: Lux.ui(15, color: widget.color));
      },
    );
  }
}

// -------------------------------------------------------------------------------------------------
// Painters

/// U-shaped felt: straight dealer edge at the top, a semicircular player rail at the bottom, a
/// padded leather rail with gold piping and the table print in gold along concentric arcs.
class _FeltPainter extends CustomPainter {
  final bool insurance;
  const _FeltPainter({required this.insurance});

  Path _shape(Size s, double inset) {
    final w = s.width, h = s.height;
    final r = w / 2 - inset;
    final cy = h - w / 2;
    return Path()
      ..moveTo(inset, 0)
      ..lineTo(w - inset, 0)
      ..lineTo(w - inset, cy)
      ..arcTo(Rect.fromCircle(center: Offset(w / 2, cy), radius: r), 0, math.pi, false)
      ..lineTo(inset, 0)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final outer = _shape(size, 2);
    final felt = _shape(size, 16);
    // Rail.
    canvas.drawPath(outer.shift(const Offset(0, 4)), Paint()..color = Colors.black.withValues(alpha: 0.5)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
    canvas.drawPath(
        outer,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF2B1A10), Color(0xFF3B2416), Color(0xFF1B0F08)],
          ).createShader(Offset.zero & size));
    // Felt.
    canvas.drawPath(
        felt,
        Paint()
          ..shader = const RadialGradient(
            center: Alignment(0, -0.1),
            radius: 0.9,
            colors: [Color(0xFF16774F), Color(0xFF0D5639), Color(0xFF073523)],
            stops: [0, 0.6, 1],
          ).createShader(Offset.zero & size));
    // Woven texture.
    canvas.save();
    canvas.clipPath(felt);
    final thread = Paint()
      ..color = const Color(0x07FFFFFF)
      ..strokeWidth = 1;
    for (double x = -h; x < w; x += 4) {
      canvas.drawLine(Offset(x, 0), Offset(x + h, h), thread);
    }
    canvas.restore();
    // Gold piping.
    canvas.drawPath(felt, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.6..color = Lux.gold.withValues(alpha: 0.85));
    canvas.drawPath(_shape(size, 22), Paint()..style = PaintingStyle.stroke..strokeWidth = 0.8..color = Lux.gold.withValues(alpha: 0.25));

    // Table print: arcs concentric with the rail, centred above the felt.
    final c = Offset(w / 2, h * 0.02);
    final r1 = h * 0.47;
    _arcText(canvas, c, r1, "KRUPİYE 17'DE DURUR · BLACKJACK 3:2", Lux.ui(math.min(15, w * 0.036), color: Lux.gold.withValues(alpha: 0.78), weight: FontWeight.w700, spacing: 1.6));
    final r2 = r1 + h * 0.06;
    final band = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = h * 0.042
      ..color = Lux.gold.withValues(alpha: insurance ? 0.16 : 0.07);
    canvas.drawArc(Rect.fromCircle(center: c, radius: r2), math.pi / 2 - 0.62, 1.24, false, band);
    _arcText(canvas, c, r2, 'SİGORTA 2:1 ÖDER', Lux.ui(math.min(11, w * 0.027), color: Lux.goldLight.withValues(alpha: insurance ? 0.85 : 0.45), weight: FontWeight.w600, spacing: 2.2));
  }

  void _arcText(Canvas canvas, Offset c, double r, String text, TextStyle style) {
    final glyphs = <TextPainter>[];
    var total = 0.0;
    for (final ch in text.characters) {
      final tp = TextPainter(text: TextSpan(text: ch, style: style), textDirection: TextDirection.ltr)..layout();
      glyphs.add(tp);
      total += tp.width;
    }
    var theta = math.pi / 2 + total / r / 2;
    for (final tp in glyphs) {
      final half = tp.width / 2 / r;
      theta -= half;
      final p = c + Offset(math.cos(theta), math.sin(theta)) * r;
      canvas.save();
      canvas.translate(p.dx, p.dy);
      canvas.rotate(theta - math.pi / 2);
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
      theta -= half;
    }
  }

  @override
  bool shouldRepaint(_FeltPainter old) => old.insurance != insurance;
}

/// The dealing shoe: a dark box with gold rim, card backs inside (fill level) and the red cut
/// card marker.
class _ShoePainter extends CustomPainter {
  final double fill, cut;
  const _ShoePainter({required this.fill, required this.cut});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final body = RRect.fromRectAndCorners(Rect.fromLTWH(w * 0.08, h * 0.12, w * 0.86, h * 0.8),
        topLeft: const Radius.circular(6), topRight: const Radius.circular(14), bottomLeft: const Radius.circular(6), bottomRight: const Radius.circular(6));
    canvas.drawRRect(body.shift(const Offset(0, 3)), Paint()..color = Colors.black.withValues(alpha: 0.5)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
    canvas.drawRRect(
        body,
        Paint()
          ..shader = const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF3A2414), Color(0xFF140B05)])
              .createShader(body.outerRect));
    // Cards inside (stack of backs; height = fill).
    final inner = Rect.fromLTWH(w * 0.2, h * 0.2, w * 0.62, h * 0.64);
    final filled = Rect.fromLTRB(inner.left, inner.bottom - inner.height * fill.clamp(0.0, 1.0), inner.right, inner.bottom);
    canvas.drawRect(filled, Paint()..color = const Color(0xFF0F5A43));
    final lines = Paint()
      ..color = Lux.gold.withValues(alpha: 0.35)
      ..strokeWidth = 0.8;
    for (var y = filled.top + 2; y < filled.bottom; y += 3) {
      canvas.drawLine(Offset(filled.left, y), Offset(filled.right, y), lines);
    }
    // Cut card marker.
    final cy = inner.bottom - inner.height * (1 - cut).clamp(0.0, 1.0);
    canvas.drawLine(Offset(inner.left - 3, cy), Offset(inner.right + 3, cy), Paint()..color = const Color(0xFFE0405F)..strokeWidth = 2);
    canvas.drawRRect(body, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.4..color = Lux.gold);
    // Mouth.
    canvas.drawRect(Rect.fromLTWH(w * 0.02, h * 0.2, w * 0.1, h * 0.3), Paint()..color = Lux.goldDeep);
  }

  @override
  bool shouldRepaint(_ShoePainter old) => old.fill != fill || old.cut != cut;
}

Color _chipColor(int v) => switch (v) {
      100 => const Color(0xFF17191C),
      50 => const Color(0xFF1F3F7A),
      25 => const Color(0xFFA3203F),
      10 => const Color(0xFFE9DFC6),
      _ => const Color(0xFFC97A8A),
    };

/// A casino chip: coloured body, six edge inlays, a gold inner ring and the value.
class _ChipPainter extends CustomPainter {
  final int value;
  final bool lifted, label;
  const _ChipPainter(this.value, {this.lifted = false, this.label = true});

  @override
  void paint(Canvas canvas, Size size) =>
      paintChip(canvas, size.center(Offset.zero), size.shortestSide / 2 * 0.92, value, lifted: lifted, label: label);

  static void paintChip(Canvas canvas, Offset c, double r, int value, {bool lifted = false, bool label = true}) {
    final col = _chipColor(value);
    final light = value == 10;
    canvas.drawCircle(c + Offset(0, r * (lifted ? 0.25 : 0.08)), r,
        Paint()..color = Colors.black.withValues(alpha: lifted ? 0.45 : 0.5)..maskFilter = MaskFilter.blur(BlurStyle.normal, r * (lifted ? 0.3 : 0.1)));
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.3, -0.4),
            colors: [Color.lerp(col, Colors.white, 0.25)!, col, Color.lerp(col, Colors.black, 0.45)!],
            stops: const [0, 0.55, 1],
          ).createShader(Rect.fromCircle(center: c, radius: r)));
    final inlay = Paint()..color = light ? const Color(0xFF1F3F7A) : const Color(0xFFF4ECDD);
    for (var i = 0; i < 6; i++) {
      final a = i * math.pi / 3;
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(a);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(0, -r * 0.84), width: r * 0.3, height: r * 0.26), Radius.circular(r * 0.05)), inlay);
      canvas.restore();
    }
    canvas.drawCircle(c, r * 0.64, Paint()..style = PaintingStyle.stroke..strokeWidth = r * 0.07..color = Lux.gold);
    canvas.drawCircle(c, r, Paint()..style = PaintingStyle.stroke..strokeWidth = math.max(1, r * 0.05)..color = Lux.goldDeep);
    if (label) {
      final tp = TextPainter(
        text: TextSpan(
          text: '$value',
          style: TextStyle(fontFamily: 'Cormorant', fontSize: r * (value >= 100 ? 0.62 : 0.72), fontWeight: FontWeight.w700, color: light ? const Color(0xFF2A1D05) : Lux.goldLight, height: 1),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(_ChipPainter old) => old.value != value || old.lifted != lifted || old.label != label;
}

/// Betting circle with the wager as a stack of chips (largest at the bottom).
class _BetCirclePainter extends CustomPainter {
  final num bet;
  final bool hover, active;
  const _BetCirclePainter({required this.bet, required this.hover, required this.active});

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2.6;
    final c = Offset(size.width / 2, size.height / 2 + r * 0.12);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = hover ? 3 : 1.8
      ..color = hover ? Lux.goldLight : Lux.gold.withValues(alpha: active ? 0.85 : 0.45);
    if (hover) {
      canvas.drawCircle(c, r * 1.15, Paint()..color = Lux.gold.withValues(alpha: 0.25)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12));
    }
    canvas.drawCircle(c, r, Paint()..color = const Color(0x22000000));
    canvas.drawCircle(c, r, ring);
    canvas.drawCircle(c, r * 0.86, Paint()..style = PaintingStyle.stroke..strokeWidth = 0.8..color = Lux.gold.withValues(alpha: 0.3));
    if (bet <= 0) {
      if (active) {
        final tp = TextPainter(
          text: TextSpan(text: 'BAHİS', style: Lux.ui(r * 0.32, color: Lux.gold.withValues(alpha: 0.7), weight: FontWeight.w600, spacing: 1.4)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
      }
      return;
    }
    // Decompose into chips.
    var rest = bet.floor();
    final chips = <int>[];
    for (final v in const [100, 50, 25, 10, 5]) {
      while (rest >= v && chips.length < 12) {
        chips.add(v);
        rest -= v;
      }
    }
    final cr = r * 0.62;
    final step = cr * 0.16;
    final shown = chips.take(10).toList();
    for (var i = 0; i < shown.length; i++) {
      _ChipPainter.paintChip(canvas, c - Offset(0, i * step), cr, shown[i], label: i == shown.length - 1);
    }
    final tp = TextPainter(
      text: TextSpan(text: _fmt(bet), style: Lux.ui(r * 0.34, color: Lux.goldLight, weight: FontWeight.w700)),
      textDirection: TextDirection.ltr,
    )..layout();
    final box = Rect.fromCenter(center: c + Offset(0, r * 0.78), width: tp.width + 12, height: tp.height + 2);
    canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(8)), Paint()..color = const Color(0xDD03190F));
    tp.paint(canvas, box.center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_BetCirclePainter old) => old.bet != bet || old.hover != hover || old.active != active;
}
