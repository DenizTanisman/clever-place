import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// N-Back. Two boards, both rendering the Rust core's state (timing and scoring live in Rust):
///
/// - **Level mode** ([_SingleBoard]): one huge gold-leaf item (digit, letter or two-digit number)
///   in a big velvet card; the whole card is the "match" button. A hit washes the card gold, a
///   false alarm shakes it bordeaux, a missed match leaves a small bordeaux ring after its trial.
///   Bottom row: error-budget pips (left) and a trophy hit counter x/10 (right). An optional
///   "N geride" helper strip (off by default; using it caps the result at 1 star).
/// - **Endless mode** ([_DualBoard]): the dual position + digit 3×3 grid with Konum / Rakam
///   buttons, Jaeggi-style adaptive blocks.
///
/// Both use the same calm intro card ("Başla") and the 3-2-1 countdown, and a Ticker that drives
/// `session.tick(dt)` only while a run or countdown is active.
Widget nbackView(BuildContext context, GameSession s) => s.mode == 'endless'
    ? _DualBoard(key: ObjectKey(s), session: s)
    : _SingleBoard(key: ObjectKey(s), session: s);

const _fadeInMs = 90.0;
const _fadeOutMs = 150.0;
const _flashSecs = 0.28;

double _num(Object? v, [double fallback = 0]) => (v as num?)?.toDouble() ?? fallback;
int _int(Object? v, [int fallback = 0]) => (v as num?)?.toInt() ?? fallback;

/// Remembers the last shown stimulus so it can fade out after the core hides it, and derives a
/// 0..1 brightness from the core's trial clock (frame-exact; never changes the response window).
class _StimFade<T> {
  T? value;
  int trial = -1;

  void sync(Map<String, dynamic> st, T? Function(Object stim) read) {
    final stim = st['stim'];
    if (stim != null) {
      value = read(stim);
      trial = _int(st['trial'], -1);
    }
  }

  double level(Map<String, dynamic> st) {
    if (st['phase'] != 'run') return 0;
    final t = _num(st['t_ms']);
    final stimMs = _num(st['stim_ms'], 500);
    if (st['stim'] != null) return Curves.easeOut.transform((t / _fadeInMs).clamp(0.0, 1.0));
    if (_int(st['trial'], -2) != trial || t < stimMs) return 0;
    final out = 1 - (t - stimMs) / _fadeOutMs;
    return out <= 0 ? 0 : Curves.easeIn.transform(out.clamp(0.0, 1.0));
  }
}

/// Countdown haptics: a selection click on each of 3-2-1.
class _CountdownClicks {
  int _last = 0;
  void sync(Map<String, dynamic> st) {
    if (st['phase'] == 'countdown') {
      final k = (_num(st['countdown_ms']) / 1000).ceil();
      if (k != _last && k >= 1 && k <= 3) HapticFeedback.selectionClick();
      _last = k;
    } else {
      _last = 0;
    }
  }
}

// =====================================================================================
// Level mode: single stimulus, the card is the button
// =====================================================================================

const _setNoun = {'digits': 'rakam', 'letters': 'harf', 'numbers': 'sayı'};
const _setPlural = {'digits': 'rakamlar', 'letters': 'harfler', 'numbers': 'sayılar'};

class _SingleBoard extends StatefulWidget {
  final GameSession session;
  const _SingleBoard({super.key, required this.session});

  @override
  State<_SingleBoard> createState() => _SingleBoardState();
}

class _SingleBoardState extends State<_SingleBoard> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;

  final _stim = _StimFade<String>();
  final _clicks = _CountdownClicks();

  int _fbSerial = 0;
  String _fbResult = '';
  String? _fbLure;
  double _fbAt = -10;
  Offset _tapAt = Offset.zero;
  double _tapAt0 = -10;
  double _earlyAt = -10;
  double _doneAt = -1;
  int _lastHits = 0;
  double _hitPulseAt = -10;

  GameSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    // Existing feedback is history, not news.
    final fb = s.state['feedback'];
    if (fb is Map) _fbSerial = _int(fb['serial']);
    _lastHits = _int(s.state['hits']);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  bool _animating(double now) =>
      now - _fbAt < 1.9 || now - _tapAt0 < 0.6 || now - _earlyAt < 1.6 || now - _hitPulseAt < 0.5 || (_doneAt >= 0 && now - _doneAt < 1.6);

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1000.0;
    _lastTick = elapsed;
    final phase = s.state['phase'];
    if (s.finished || !(phase == 'run' || phase == 'countdown')) {
      if (_animating(_now)) setState(() {});
      return;
    }
    s.tick(dt);
  }

  void _onPointerDown(PointerDownEvent e) {
    final st = s.state;
    if (s.finished || st['phase'] != 'run') return;
    // The response goes to the core first; the visuals follow it.
    final early = st['can_match'] != true;
    s.act({'match': true});
    _tapAt = e.localPosition;
    _tapAt0 = _now;
    if (early) {
      _earlyAt = _now;
      HapticFeedback.selectionClick();
    }
  }

  void _sync(Map<String, dynamic> st, double now) {
    _clicks.sync(st);
    _stim.sync(st, (v) => v as String);
    final fb = st['feedback'];
    if (fb is Map) {
      final serial = _int(fb['serial']);
      if (serial > 0 && serial != _fbSerial) {
        _fbSerial = serial;
        _fbResult = fb['result'] as String? ?? '';
        _fbLure = fb['lure_kind'] as String?;
        _fbAt = now;
        if (_fbResult == 'hit') {
          HapticFeedback.lightImpact();
        } else {
          HapticFeedback.mediumImpact();
        }
      }
    }
    final hits = _int(st['hits']);
    if (hits != _lastHits) {
      if (hits > _lastHits) _hitPulseAt = now;
      _lastHits = hits;
    }
    if (st['phase'] == 'done' && _doneAt < 0) {
      _doneAt = now;
      if (st['status'] == 'won') HapticFeedback.heavyImpact();
    }
  }

  void _toggleHelper(bool on) {
    HapticFeedback.selectionClick();
    s.act({'helper': on});
  }

  @override
  Widget build(BuildContext context) {
    final st = s.state;
    final now = _now;
    _sync(st, now);
    final phase = st['phase'] as String? ?? 'intro';
    return Stack(
      children: [
        Column(
          children: [
            _topStrip(st),
            _helperStrip(st),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _onPointerDown,
                  child: _card(st, now),
                ),
              ),
            ),
            _bottomRow(st, now),
          ],
        ),
        if (phase == 'countdown') Positioned.fill(child: IgnorePointer(child: _countdownOverlay(st))),
        if (phase == 'intro') Positioned.fill(child: _introCard(st)),
      ],
    );
  }

  // ------------------------------------------------------------------ top

  Widget _topStrip(Map<String, dynamic> st) {
    final n = _int(st['n'], 1);
    final helper = st['helper'] == true;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 10, 14, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          FoilText('$n', style: Lux.display(44, spacing: 0)),
          const SizedBox(width: 6),
          Text(Lux.upper('back'), style: Lux.display(17, spacing: 2)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(st['set_label'] as String? ?? '', style: Lux.ui(13, color: Lux.muted)),
              ],
            ),
          ),
          IconButton(
            tooltip: helper ? 'N geride şeridini kapat' : 'N geride şeridi (açıkken en fazla 1 yıldız)',
            onPressed: s.finished ? null : () => _toggleHelper(!helper),
            icon: Icon(helper ? Icons.visibility_rounded : Icons.visibility_off_outlined,
                color: helper ? Lux.goldLight : Lux.muted.withValues(alpha: 0.7), size: 22),
          ),
        ],
      ),
    );
  }

  /// "N geride" helper: the previous N items, oldest (the one to compare with) first.
  Widget _helperStrip(Map<String, dynamic> st) {
    final on = st['helper'] == true;
    final n = _int(st['n'], 1);
    final recent = [for (final v in (st['recent'] as List? ?? const [])) v as String];
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      child: !on
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
              child: Column(
                children: [
                  LayoutBuilder(builder: (context, box) {
                    final chip = math.min(38.0, (box.maxWidth - 4.0 * n) / n);
                    // Align so the oldest slot is always the leftmost; pad with empty slots.
                    final slots = List<String?>.filled(n, null);
                    for (var i = 0; i < recent.length && i < n; i++) {
                      slots[n - recent.length + i] = recent[i];
                    }
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < n; i++)
                          Container(
                            width: chip,
                            height: chip,
                            margin: const EdgeInsets.symmetric(horizontal: 2),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              color: i == 0 ? const Color(0x33D4A94E) : const Color(0x22000000),
                              border: Border.all(color: i == 0 ? Lux.gold : Lux.line, width: i == 0 ? 1.3 : 1),
                            ),
                            child: Text(slots[i] ?? '·',
                                style: Lux.ui(chip * 0.42, color: i == 0 ? Lux.goldLight : Lux.muted, weight: FontWeight.w700)),
                          ),
                      ],
                    );
                  }),
                  const SizedBox(height: 3),
                  Text('Soldaki = $n geride · yardım açıkken en fazla 1 yıldız', style: Lux.ui(11, color: Lux.muted)),
                ],
              ),
            ),
    );
  }

  // ------------------------------------------------------------------ card

  Widget _card(Map<String, dynamic> st, double now) {
    final done = st['phase'] == 'done';
    final fbAge = now - _fbAt;
    // False alarm: a short damped horizontal shake.
    var shake = 0.0;
    if (_fbResult == 'false_alarm' && fbAge >= 0 && fbAge < 0.42) {
      final d = 1 - fbAge / 0.42;
      shake = math.sin(fbAge * math.pi * 2 * 8.5) * 11 * d * d;
    }
    // Press: sink fast, release slowly.
    final tapAge = now - _tapAt0;
    final press = tapAge < 0 || tapAge > 0.3 ? 0.0 : (tapAge < 0.06 ? tapAge / 0.06 : 1 - (tapAge - 0.06) / 0.24);
    return LayoutBuilder(builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      return Transform.translate(
        offset: Offset(shake, 0),
        child: Transform.scale(
          scale: 1 - 0.018 * press,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const LuxCard(highlight: true, radius: 28, padding: EdgeInsets.zero, child: SizedBox.expand()),
              Positioned.fill(
                child: IgnorePointer(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: CustomPaint(
                      painter: _CardFx(
                        result: _fbResult,
                        fbAge: fbAge,
                        tapAt: _tapAt,
                        tapAge: tapAge,
                        winAge: done && st['status'] == 'won' ? now - _doneAt : -1,
                      ),
                    ),
                  ),
                ),
              ),
              if (!done) Positioned.fill(child: IgnorePointer(child: _stimulus(st, size))),
              if (!done) Positioned(left: 0, right: 0, bottom: 18, child: IgnorePointer(child: _cardFooter(st, now))),
              if (done) Positioned.fill(child: IgnorePointer(child: _results(st, now - _doneAt))),
            ],
          ),
        ),
      );
    });
  }

  Widget _stimulus(Map<String, dynamic> st, Size size) {
    final level = _stim.level(st);
    final text = _stim.value;
    final running = st['phase'] == 'run';
    // Fixation point while blank keeps the eyes on the card centre.
    final dot = Center(
      child: Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(shape: BoxShape.circle, color: Lux.gold.withValues(alpha: running ? 0.28 : 0.12)),
      ),
    );
    if (text == null || level <= 0.003) return dot;
    final chars = text.length;
    final font = math.min(size.height * 0.5, size.width * (chars == 1 ? 0.62 : 0.48)) / 1.12;
    final style = Lux.display(font, spacing: 0).copyWith(height: 1.0);
    return Stack(
      fit: StackFit.expand,
      children: [
        Opacity(opacity: 1 - level, child: dot),
        Center(
          child: Opacity(
            opacity: level,
            child: Transform.scale(
              scale: 0.93 + 0.07 * level,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Soft drop shadow, then the foil body, then a specular sheen on the upper half.
                  Transform.translate(
                    offset: Offset(0, font * 0.035),
                    child: Text(text,
                        style: style.copyWith(
                          color: Colors.black.withValues(alpha: 0.55),
                          shadows: [Shadow(color: Colors.black.withValues(alpha: 0.6), blurRadius: font * 0.08)],
                        )),
                  ),
                  FoilText(text, style: style),
                  ShaderMask(
                    blendMode: BlendMode.srcIn,
                    shaderCallback: (r) => LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.white.withValues(alpha: 0.42), Colors.white.withValues(alpha: 0)],
                      stops: const [0, 0.48],
                    ).createShader(r),
                    child: Text(text, style: style.copyWith(color: Colors.white)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Small muted line at the bottom of the card: "fill the window" during the first N trials,
  /// and a gentle note after an ignored early tap.
  Widget _cardFooter(Map<String, dynamic> st, double now) {
    final n = _int(st['n'], 1);
    final trial = _int(st['trial']);
    final earlyAge = now - _earlyAt;
    final fbAge = now - _fbAt;
    String? text;
    var alpha = 0.0;
    var color = Lux.muted;
    if (_fbResult == 'false_alarm' && _fbLure != null && fbAge >= 0 && fbAge < 1.8) {
      // After a false alarm on a lure: name the trap, so the player learns what fooled them.
      text = 'Çeldirici · ${_lureExplain(_fbLure!, n)}';
      alpha = fbAge < 1.4 ? 1 : 1 - (fbAge - 1.4) / 0.4;
      color = Lux.bordeauxLight;
    } else if (earlyAge >= 0 && earlyAge < 1.5) {
      text = 'İlk $n uyaranda eşleşme olmaz';
      alpha = earlyAge < 1.1 ? 1 : 1 - (earlyAge - 1.1) / 0.4;
    } else if (st['phase'] == 'run' && trial < n) {
      text = 'Diziyi doldur · ${trial + 1} / $n';
      alpha = 0.8;
    }
    return AnimatedOpacity(
      opacity: text == null ? 0 : alpha.clamp(0.0, 1.0),
      duration: const Duration(milliseconds: 120),
      child: Text(text ?? '', textAlign: TextAlign.center, style: Lux.ui(13, color: color, spacing: 0.6)),
    );
  }

  static String _lureExplain(String kind, int n) => switch (kind) {
        'n-1' => '${n - 1} önceki ile aynı (n−1)',
        'n+1' => '${n + 1} önceki ile aynı (n+1)',
        _ => 'hep bundan sonra gelen, ama $n önce değil (sıra)',
      };

  Widget _results(Map<String, dynamic> st, double t) {
    final won = st['status'] == 'won';
    final u = Curves.easeOutCubic.transform((t / 0.9).clamp(0.0, 1.0));
    final appear = Curves.easeOutBack.transform((t / 0.4).clamp(0.0, 1.0));
    final rt = st['avg_rt_ms'];
    final secs = (_num(st['elapsed_ms']) / 1000).round();
    final tiles = <(String, String, Color)>[
      ('Doğru', '${(_int(st['hits']) * u).round()}', Lux.goldLight),
      ('Yanlış', '${_int(st['false_alarms'])}', Lux.bordeauxLight),
      ('Kaçırılan', '${_int(st['misses'])}', Lux.bordeauxLight),
      ('Verimlilik', '%${(_num(st['efficiency']) * 100 * u).round()}', Lux.goldLight),
      ('Süre', '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}', Lux.ink),
      ('Ort. tepki', rt == null ? '–' : '${_int(rt)} ms', Lux.ink),
    ];
    return Opacity(
      opacity: (t / 0.25).clamp(0.0, 1.0),
      child: Transform.scale(
        scale: 0.9 + 0.1 * appear,
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(Lux.upper(won ? '${st['n']}-back tamam' : 'Haklar bitti'),
                  style: Lux.display(24, color: won ? Lux.gold : Lux.bordeauxLight, spacing: 1.4)),
              const SizedBox(height: 18),
              for (var r = 0; r < 3; r++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      for (var c = 0; c < 2; c++) Expanded(child: _statTile(tiles[r * 2 + c])),
                    ],
                  ),
                ),
              if (st['lure_summary'] is String) ...[
                const SizedBox(height: 12),
                Text(st['lure_summary'] as String,
                    textAlign: TextAlign.center, style: Lux.ui(14, color: Lux.bordeauxLight, weight: FontWeight.w600)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _statTile((String, String, Color) t) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 5),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: const Color(0x33000000),
          border: Border.all(color: Lux.line),
        ),
        child: Column(
          children: [
            Text(Lux.upper(t.$1), style: Lux.ui(11, color: Lux.muted, weight: FontWeight.w600, spacing: 1.6)),
            const SizedBox(height: 4),
            Text(t.$2,
                style: Lux.numeral(30, color: t.$3).copyWith(fontFeatures: const [FontFeature.tabularFigures(), FontFeature.liningFigures()])),
          ],
        ),
      );

  // ------------------------------------------------------------------ bottom row

  Widget _bottomRow(Map<String, dynamic> st, double now) {
    final budget = _int(st['error_budget'], 2);
    final left = _int(st['errors_left'], budget);
    final hits = _int(st['hits']);
    final goal = _int(st['goal_hits'], 17);
    final pulseAge = now - _hitPulseAt;
    final pulse = pulseAge >= 0 && pulseAge < 0.45 ? math.sin(math.pi * pulseAge / 0.45) : 0.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
      child: Row(
        children: [
          // Error budget: ⊘ + remaining count + pips.
          Icon(Icons.block_rounded, color: left <= 1 ? Lux.bordeauxLight : Lux.muted, size: 22),
          const SizedBox(width: 6),
          Text('$left', style: Lux.numeral(28, color: left <= 1 ? Lux.bordeauxLight : Lux.ink)),
          const SizedBox(width: 10),
          for (var i = 0; i < budget; i++) _Pip(on: i < left, small: budget > 3),
          const Spacer(),
          // Trophy counter: x/10 with a segmented bar.
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  FoilText('$hits', style: Lux.numeral(32)),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(' / $goal', style: Lux.ui(15, color: Lux.muted, weight: FontWeight.w600)),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < goal; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 260),
                      width: goal > 12 ? 4.5 : 8,
                      height: 4,
                      margin: EdgeInsets.only(left: goal > 12 ? 2 : 2.5),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(2),
                        gradient: i < hits ? Lux.foil : null,
                        color: i < hits ? null : Lux.line,
                      ),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(width: 10),
          Transform.scale(
            scale: 1 + 0.22 * pulse,
            child: Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Lux.cardDeep,
                border: Border.all(color: Lux.gold.withValues(alpha: 0.55 + 0.45 * pulse), width: 1.2),
                boxShadow: [
                  BoxShadow(color: Lux.gold.withValues(alpha: 0.45 * pulse), blurRadius: 18),
                  BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 8, offset: const Offset(0, 4)),
                ],
              ),
              child: ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (r) => Lux.foil.createShader(r),
                child: const Icon(Icons.emoji_events_rounded, size: 26, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ intro

  Widget _introCard(Map<String, dynamic> st) {
    final n = _int(st['n'], 1);
    final set = st['set'] as String? ?? 'digits';
    final noun = _setNoun[set] ?? 'rakam';
    final budget = _int(st['error_budget'], 2);
    final goal = _int(st['goal_hits'], 17);
    final period = (_num(st['period_ms'], 2500) / 1000).toStringAsFixed(1).replaceAll('.', ',');
    final back = n == 1 ? 'bir önceki' : '$n adım önceki';
    return _overlayCard(
      heading: '$n-back',
      body: 'Kartta tek tek ${_setPlural[set] ?? 'rakamlar'} belirecek. Gördüğün $noun $back $noun ile aynıysa '
          'kartın herhangi bir yerine dokun.\n'
          '$goal eşleşme yakala. Yanlış dokunuş ve kaçırılan eşleşme birer hak götürür; $budget hakkın var, '
          'sonuncusu gidince bölüm biter.\n'
          'Tempo $period sn · ilk $n uyaranda eşleşme olmaz.'
          '${st['lures'] == true ? '\nDikkat: çeldiriciler var. Bir adım erken ya da geç gelen tekrarlar ve "hep bundan sonra bu geliyordu" dediğin diziler eşleşme değildir.' : ''}'
          '\nHatasız 3, tek hatayla 2 yıldız.',
      button: 'Başla',
      cardKey: 'intro',
      onStart: () {
        HapticFeedback.selectionClick();
        s.act({'start': true});
      },
    );
  }
}

/// One error-budget pip: a ruby gem while available, a hollow ring once spent.
class _Pip extends StatelessWidget {
  final bool on;
  final bool small;
  const _Pip({required this.on, this.small = false});

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: on ? 1 : 0.7,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutBack,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        width: small ? 12 : 15,
        height: small ? 12 : 15,
        margin: EdgeInsets.only(right: small ? 4 : 6),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: on
              ? const RadialGradient(
                  center: Alignment(-0.35, -0.4),
                  colors: [Color(0xFFF4A3B6), Lux.bordeaux, Color(0xFF4A0E1C)],
                  stops: [0, 0.55, 1],
                )
              : null,
          border: Border.all(color: on ? Lux.goldLight.withValues(alpha: 0.6) : Lux.muted.withValues(alpha: 0.35), width: 1),
        ),
      ),
    );
  }
}

/// Card effects: press ripple from the finger, gold wash on a hit, bordeaux wash on a false alarm,
/// a small bordeaux ring after a missed match, and a gold bloom when the level is won.
class _CardFx extends CustomPainter {
  final String result;
  final double fbAge, tapAge, winAge;
  final Offset tapAt;
  _CardFx({required this.result, required this.fbAge, required this.tapAt, required this.tapAge, required this.winAge});

  static final Paint _p = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final c = size.center(Offset.zero);
    // Press ripple.
    if (tapAge >= 0 && tapAge < 0.5) {
      final far = [Offset.zero, Offset(size.width, 0), Offset(0, size.height), Offset(size.width, size.height)]
          .map((o) => (o - tapAt).distance)
          .reduce(math.max);
      final e = Curves.easeOutCubic.transform(tapAge / 0.5);
      canvas.drawCircle(tapAt, far * (0.08 + 0.92 * e), _p..color = Lux.goldLight.withValues(alpha: 0.13 * (1 - tapAge / 0.5)));
    }
    // Hit / false alarm wash and rim.
    if ((result == 'hit' || result == 'false_alarm') && fbAge >= 0 && fbAge < 0.6) {
      final col = result == 'hit' ? Lux.gold : Lux.bordeaux;
      final a = math.pow(1 - fbAge / 0.6, 2).toDouble();
      canvas.drawRect(
        rect,
        _p
          ..shader = RadialGradient(
            colors: [col.withValues(alpha: (result == 'hit' ? 0.34 : 0.4) * a), col.withValues(alpha: 0.06 * a)],
          ).createShader(rect),
      );
      _p.shader = null;
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect.deflate(2), const Radius.circular(26)),
        _p
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5 * a + 0.5
          ..color = (result == 'hit' ? Lux.goldLight : Lux.bordeauxLight).withValues(alpha: 0.9 * a),
      );
      _p.style = PaintingStyle.fill;
    }
    // Miss: a small ring that blooms and fades in the centre.
    if (result == 'miss' && fbAge >= 0 && fbAge < 0.8) {
      final t = fbAge / 0.8;
      final r = size.shortestSide * (0.1 + 0.08 * Curves.easeOutCubic.transform(t));
      canvas.drawCircle(
        c,
        r,
        _p
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = Lux.bordeauxLight.withValues(alpha: 0.85 * (1 - t)),
      );
      _p.style = PaintingStyle.fill;
    }
    // Win bloom: a gold ring rolls out from the centre.
    if (winAge >= 0 && winAge < 1.0) {
      final t = winAge / 1.0;
      final far = (Offset.zero - c).distance;
      canvas.drawCircle(
        c,
        far * Curves.easeOutCubic.transform(t),
        _p
          ..style = PaintingStyle.stroke
          ..strokeWidth = 18 * (1 - t) + 1
          ..color = Lux.goldLight.withValues(alpha: 0.45 * (1 - t))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
      _p
        ..style = PaintingStyle.fill
        ..maskFilter = null;
    }
  }

  @override
  bool shouldRepaint(_CardFx old) =>
      old.result != result || old.fbAge != fbAge || old.tapAge != tapAge || old.tapAt != tapAt || old.winAge != winAge;
}

// =====================================================================================
// Shared overlays
// =====================================================================================

Widget _countdownOverlay(Map<String, dynamic> st) {
  final ms = _num(st['countdown_ms']);
  final k = (ms / 1000).ceil().clamp(1, 3);
  final p = ((k * 1000 - ms) / 1000).clamp(0.0, 1.0); // progress through this digit
  // Pop in (0–0.22), hold, then scale out and fade (0.62–1).
  final inT = Curves.easeOutBack.transform((p / 0.22).clamp(0.0, 1.0));
  final outT = Curves.easeInCubic.transform(((p - 0.62) / 0.38).clamp(0.0, 1.0));
  final scale = (0.55 + 0.45 * inT) * (1 + 0.5 * outT);
  final opacity = (p / 0.12).clamp(0.0, 1.0) * (1 - outT);
  final dim = k == 1 ? 1 - outT : 1.0;
  return ColoredBox(
    color: Colors.black.withValues(alpha: 0.35 * dim),
    child: Center(
      child: CustomPaint(
        painter: _CountRing(p),
        child: SizedBox(
          width: 220,
          height: 220,
          child: Center(
            child: Transform.scale(
              scale: scale,
              child: Opacity(
                opacity: opacity,
                child: Text('$k', style: Lux.display(110, color: Lux.goldLight)),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _overlayCard({
  required String heading,
  required String body,
  required String button,
  required String cardKey,
  required VoidCallback onStart,
  Widget? extra,
}) {
  return TweenAnimationBuilder<double>(
    key: ValueKey(cardKey),
    tween: Tween(begin: 0, end: 1),
    duration: const Duration(milliseconds: 280),
    curve: Curves.easeOutCubic,
    builder: (context, t, child) => ColoredBox(
      color: Colors.black.withValues(alpha: 0.55 * t),
      child: Opacity(opacity: t, child: Transform.scale(scale: 0.95 + 0.05 * t, child: child)),
    ),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: LuxCard(
          highlight: true,
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(Lux.upper(heading), textAlign: TextAlign.center, style: Lux.display(22, spacing: 1.5)),
              const SizedBox(height: 14),
              if (extra != null) extra,
              Text(body, textAlign: TextAlign.center, style: Lux.ui(16, weight: FontWeight.w500).copyWith(height: 1.4)),
              const SizedBox(height: 18),
              GoldButton(button, icon: Icons.play_arrow_rounded, onPressed: onStart),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Thin gold ring that sweeps once around each countdown digit.
class _CountRing extends CustomPainter {
  final double p;
  _CountRing(this.p);

  static final Paint _paint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide * 0.42;
    final fade = p < 0.1 ? p / 0.1 : (p > 0.8 ? (1 - p) / 0.2 : 1.0);
    canvas.drawCircle(c, r, _paint..strokeWidth = 1.2..color = Lux.gold.withValues(alpha: 0.18 * fade));
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), -math.pi / 2, 2 * math.pi * Curves.easeInOut.transform(p), false,
        _paint..strokeWidth = 2.4..color = Lux.goldLight.withValues(alpha: 0.75 * fade));
  }

  @override
  bool shouldRepaint(_CountRing old) => old.p != p;
}

// =====================================================================================
// Endless mode: dual position + digit grid
// =====================================================================================

const _modLabels = {'position': 'Konum', 'digit': 'Rakam'};
const _modIcons = {'position': Icons.grid_view_rounded, 'digit': Icons.pin_outlined};

class _DualBoard extends StatefulWidget {
  final GameSession session;
  const _DualBoard({super.key, required this.session});

  @override
  State<_DualBoard> createState() => _DualBoardState();
}

class _Flash {
  final int serial;
  final String result;
  final double at;
  const _Flash(this.serial, this.result, this.at);
}

class _DualBoardState extends State<_DualBoard> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;
  final Map<String, _Flash> _flash = {};
  final _stim = _StimFade<(int?, Object?)>();
  final _clicks = _CountdownClicks();
  double _doneAt = -1;

  GameSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    final fb = s.state['feedback'];
    if (fb is Map) {
      fb.forEach((k, v) => _flash[k as String] = _Flash(_int((v as Map)['serial']), v['result'] as String, -10));
    }
  }

  bool _animating(double now) =>
      _flash.values.any((f) => now - f.at < 0.7) || (_doneAt >= 0 && now - _doneAt < 1.4);

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1000.0;
    _lastTick = elapsed;
    final phase = s.state['phase'];
    if (s.finished || !(phase == 'run' || phase == 'countdown')) {
      if (_animating(_now)) setState(() {});
      return;
    }
    s.tick(dt);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _press(String mod) {
    if (s.finished || s.state['phase'] != 'run') return;
    HapticFeedback.selectionClick();
    s.act({'match': mod});
  }

  void _sync(Map<String, dynamic> st, double now) {
    final fb = st['feedback'];
    if (fb is Map) {
      fb.forEach((k, v) {
        final serial = _int((v as Map)['serial']);
        final prev = _flash[k];
        if (serial > 0 && (prev == null || prev.serial != serial)) {
          _flash[k as String] = _Flash(serial, v['result'] as String, now);
          if (v['result'] == 'hit') {
            HapticFeedback.lightImpact();
          } else {
            HapticFeedback.mediumImpact();
          }
        }
      });
    }
    _clicks.sync(st);
    _stim.sync(st, (v) {
      final m = v as Map;
      return ((m['pos'] as num?)?.toInt(), m['digit']);
    });
    if (st['phase'] == 'done' && _doneAt < 0) _doneAt = now;
  }

  @override
  Widget build(BuildContext context) {
    final st = s.state;
    final now = _now;
    _sync(st, now);
    final phase = st['phase'] as String? ?? 'intro';
    final mods = [for (final m in (st['modalities'] as List? ?? const [])) m as String];
    final n = _int(st['n'], 1);

    return Stack(
      children: [
        Column(
          children: [
            _header(st, n, mods),
            Expanded(
              child: LayoutBuilder(builder: (context, box) {
                final side = math.min(box.maxWidth - 40, box.maxHeight - 16);
                return Center(
                  child: SizedBox(
                    width: side,
                    height: side,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(child: _grid(st, side)),
                        if (_doneAt >= 0) Positioned.fill(child: IgnorePointer(child: _finalScore(st, now - _doneAt))),
                      ],
                    ),
                  ),
                );
              }),
            ),
            _buttons(mods, phase == 'run', now),
          ],
        ),
        if (phase == 'countdown') Positioned.fill(child: IgnorePointer(child: _countdownOverlay(st))),
        if (phase == 'intro' || phase == 'break') Positioned.fill(child: _card(st, phase, n)),
      ],
    );
  }

  Widget _header(Map<String, dynamic> st, int n, List<String> mods) {
    final trial = _int(st['trial']);
    final trials = _int(st['trials'], 1);
    final history = [for (final h in (st['n_history'] as List? ?? const [])) (h as num).toInt()];
    // Continuous progress: completed trials plus the fraction of the running one.
    var progress = trial.toDouble();
    if (st['phase'] == 'run' && trial < trials) {
      progress += (_num(st['t_ms']) / _num(st['period_ms'], 3000)).clamp(0.0, 1.0);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 4),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              FoilText('$n', style: Lux.display(54, spacing: 0)),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(Lux.upper('back'), style: Lux.display(18, spacing: 2)),
              ),
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('Blok ${st['block']} / ${st['blocks']}', style: Lux.ui(16, weight: FontWeight.w700)),
                  Text(mods.map((m) => _modLabels[m]).join(' · '), style: Lux.ui(13, color: Lux.muted)),
                  if (history.isNotEmpty) Text('N: ${history.join(' → ')}', style: Lux.ui(12, color: Lux.goldLight)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 6,
              child: Stack(
                children: [
                  const Positioned.fill(child: ColoredBox(color: Color(0xFF2A2015))),
                  FractionallySizedBox(
                    widthFactor: (progress / trials).clamp(0.0, 1.0),
                    child: const DecoratedBox(decoration: BoxDecoration(gradient: Lux.goldGradient)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text('Uyaran ${math.min(trial + 1, trials)} / $trials', style: Lux.ui(12, color: Lux.muted)),
              const Spacer(),
              if (trial >= n && st['phase'] == 'run')
                Text('Doğruluk %${(_num(st['accuracy']) * 100).round()}', style: Lux.ui(12, color: Lux.muted)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _grid(Map<String, dynamic> st, double side) {
    final level = _stim.level(st);
    final v = _stim.value;
    final gap = side * 0.035;
    final cell = (side - gap * 4) / 3;
    return Stack(
      children: [
        Positioned.fill(child: RepaintBoundary(child: CustomPaint(painter: _GridBase(gap: gap, cell: cell)))),
        Positioned.fill(
          child: CustomPaint(
            painter: _GridLight(
              gap: gap,
              cell: cell,
              lit: level > 0 ? v?.$1 : null,
              level: level,
              digit: v?.$2 == null ? null : '${v!.$2}',
            ),
          ),
        ),
      ],
    );
  }

  /// Final mean N, counting up over the grid.
  Widget _finalScore(Map<String, dynamic> st, double t) {
    final u = Curves.easeOutCubic.transform((t / 0.9).clamp(0.0, 1.0));
    final appear = Curves.easeOutBack.transform((t / 0.35).clamp(0.0, 1.0));
    final mean = _num(st['score']) / 100;
    return Center(
      child: Opacity(
        opacity: (t / 0.2).clamp(0.0, 1.0),
        child: Transform.scale(
          scale: 0.8 + 0.2 * appear,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              color: const Color(0xE6062A21),
              border: Border.all(color: Lux.gold.withValues(alpha: 0.8), width: 1.2),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 18, offset: const Offset(0, 8))],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(Lux.upper('Ortalama N'), style: Lux.ui(12, color: Lux.gold, weight: FontWeight.w600, spacing: 2.2)),
                const SizedBox(height: 4),
                FoilText((mean * u).toStringAsFixed(1).replaceAll('.', ','),
                    style: Lux.numeral(52).copyWith(fontFeatures: const [FontFeature.tabularFigures(), FontFeature.liningFigures()])),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buttons(List<String> mods, bool active, double now) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 18),
      child: Row(
        children: [
          for (final m in mods)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: _ResponseButton(
                  label: _modLabels[m] ?? m,
                  icon: _modIcons[m] ?? Icons.circle,
                  enabled: active,
                  pressed: (s.state['pressed'] as Map?)?[m] == true,
                  flash: _flashColor(m, now),
                  onTap: () => _press(m),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Gold for a hit, bordeaux for a false alarm or a miss: a sharp rim flash with a softer glow.
  (Color, double, double)? _flashColor(String mod, double now) {
    final f = _flash[mod];
    if (f == null) return null;
    final age = now - f.at;
    if (age < 0 || age > 0.6) return null;
    final rim = age < _flashSecs ? 1 - age / _flashSecs : 0.0;
    final glow = 1 - age / 0.6;
    return (f.result == 'hit' ? Lux.gold : Lux.bordeauxLight, rim * rim, glow * glow);
  }

  Widget _card(Map<String, dynamic> st, String phase, int n) {
    final last = st['last_block'] is Map ? Map<String, dynamic>.from(st['last_block'] as Map) : null;
    final period = (_num(st['period_ms'], 3000) / 1000).toStringAsFixed(1).replaceAll('.', ',');
    void start() {
      HapticFeedback.selectionClick();
      s.act({'start': true});
    }

    if (phase == 'break' && last != null) {
      final acc = (_num(last['accuracy']) * 100).round();
      final change = _int(last['change']);
      return _overlayCard(
        heading: 'Blok ${_int(st['block']) - 1} bitti',
        cardKey: 'break${st['block']}',
        extra: Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: acc.toDouble()),
            duration: const Duration(milliseconds: 900),
            curve: Curves.easeOutCubic,
            builder: (context, v, _) => Text('Doğruluk %${v.round()} · ${last['n']}-back',
                textAlign: TextAlign.center,
                style: Lux.ui(16, weight: FontWeight.w500).copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
          ),
        ),
        body: change > 0
            ? 'Harika! N bir artıyor: $n-back.'
            : change < 0
                ? 'N bir azalıyor: $n-back. Ritmi yeniden kur.'
                : 'N aynı kalıyor: $n-back.',
        button: 'Sonraki blok',
        onStart: start,
      );
    }
    return _overlayCard(
      heading: 'İkili $n-back',
      cardKey: 'intro',
      body: 'Her uyaranda ızgarada bir hücre yanar, içinde bir rakam görünür. Konum $n adım öncekiyle aynıysa '
          'Konum, rakam aynıysa Rakam düğmesine bas (ikisi de olabilir). Uyaran yarım saniye görünür; '
          'cevap için $period sn içinde basman yeter.\n'
          '10 blok. %90 ve üstü N\'i artırır, %75 altı azaltır. Puan = ortalama N × 100.',
      button: 'Başla',
      onStart: start,
    );
  }
}

Rect _cellRect(int i, double gap, double cell) =>
    Rect.fromLTWH(gap + (i % 3) * (cell + gap), gap + (i ~/ 3) * (cell + gap), cell, cell);

/// The nine unlit cells (static; repaints only when the size changes).
class _GridBase extends CustomPainter {
  final double gap, cell;
  _GridBase({required this.gap, required this.cell});

  @override
  void paint(Canvas canvas, Size size) {
    final shadow = Paint()
      ..color = Colors.black.withValues(alpha: 0.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    final rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = Lux.gold.withValues(alpha: 0.35);
    for (var i = 0; i < 9; i++) {
      final rect = _cellRect(i, gap, cell);
      final rr = RRect.fromRectAndRadius(rect, Radius.circular(cell * 0.16));
      canvas.drawRRect(rr.shift(const Offset(0, 4)), shadow);
      canvas.drawRRect(
        rr,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0E4636), Color(0xFF05241C)],
          ).createShader(rect),
      );
      canvas.drawRRect(rr.deflate(0.6), rim);
    }
  }

  @override
  bool shouldRepaint(_GridBase old) => old.gap != gap || old.cell != cell;
}

/// The lit cell's bloom with its digit.
class _GridLight extends CustomPainter {
  final double gap, cell, level;
  final int? lit;
  final String? digit;
  _GridLight({required this.gap, required this.cell, required this.lit, required this.level, required this.digit});

  static final Paint _p = Paint();
  static final Paint _layer = Paint();
  static final Map<String, TextPainter> _digits = {};

  TextPainter _digit(String d) {
    final key = '$d@${cell.round()}';
    return _digits[key] ??= (TextPainter(
      text: TextSpan(
        text: d,
        style: TextStyle(
          fontFamily: 'Cormorant',
          fontSize: cell * 0.62,
          fontWeight: FontWeight.w700,
          color: const Color(0xFF2A1D05),
          fontFeatures: const [FontFeature.liningFigures()],
          shadows: [Shadow(color: Colors.white.withValues(alpha: 0.4), blurRadius: 6)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout());
  }

  @override
  void paint(Canvas canvas, Size size) {
    final i = lit;
    final a = level;
    if (i == null || a <= 0.003) return;
    const glow = Lux.gold;
    final rect = _cellRect(i, gap, cell);
    final c = rect.center;
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(cell * 0.16));
    canvas.save();
    final sc = 0.97 + 0.03 * a; // a slight swell as it lights
    canvas.translate(c.dx, c.dy);
    canvas.scale(sc, sc);
    canvas.translate(-c.dx, -c.dy);
    canvas.drawRRect(
      rr.inflate(cell * 0.05 * a),
      _p
        ..shader = null
        ..color = glow.withValues(alpha: 0.55 * a)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, cell * 0.14),
    );
    _p.maskFilter = null;
    canvas.drawRRect(
      rr,
      _p
        ..shader = LinearGradient(
          begin: const Alignment(-1, -0.6),
          end: const Alignment(1, 0.6),
          colors: [for (final col in Lux.foil.colors) col.withValues(alpha: a)],
          stops: Lux.foil.stops,
        ).createShader(rect),
    );
    _p.shader = null;
    canvas.drawRRect(
      rr.deflate(1),
      _p
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Lux.goldLight.withValues(alpha: a),
    );
    _p.style = PaintingStyle.fill;
    final d = digit;
    if (d != null) {
      final tp = _digit(d);
      final pos = c - Offset(tp.width / 2, tp.height / 2);
      if (a < 0.995) {
        canvas.saveLayer(rect, _layer..color = Colors.white.withValues(alpha: a));
        tp.paint(canvas, pos);
        canvas.restore();
      } else {
        tp.paint(canvas, pos);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GridLight old) =>
      old.level != level || old.lit != lit || old.digit != digit || old.cell != cell;
}

/// Response button: sinks on touch-down with a ripple from the finger; its rim flashes the result.
class _ResponseButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final bool enabled;
  final bool pressed;
  final (Color, double, double)? flash; // colour, rim strength, glow strength
  final VoidCallback onTap;
  const _ResponseButton({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.pressed,
    required this.flash,
    required this.onTap,
  });

  @override
  State<_ResponseButton> createState() => _ResponseButtonState();
}

class _ResponseButtonState extends State<_ResponseButton> with TickerProviderStateMixin {
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 70),
    reverseDuration: const Duration(milliseconds: 200),
  );
  late final AnimationController _ripple = AnimationController(vsync: this, duration: const Duration(milliseconds: 460));
  Offset _rippleAt = Offset.zero;
  bool _down = false;

  @override
  void dispose() {
    _press.dispose();
    _ripple.dispose();
    super.dispose();
  }

  void _onDown(PointerDownEvent d) {
    if (!widget.enabled) return;
    // The response is sent first; the animation only follows it.
    widget.onTap();
    _down = true;
    _rippleAt = d.localPosition;
    _ripple.forward(from: 0);
    _press.forward();
  }

  void _onUp() {
    _down = false;
    if (_press.status == AnimationStatus.forward) {
      _press.forward().whenComplete(() {
        if (!_down && mounted) _press.reverse();
      });
    } else {
      _press.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.flash;
    final base = widget.pressed ? const Color(0xFF155A45) : Lux.cardDeep;
    final bg = f == null ? base : Color.lerp(base, f.$1, 0.28 * f.$3)!;
    final rest = widget.pressed ? Lux.gold : Lux.gold.withValues(alpha: 0.5);
    final rim = f == null ? rest : Color.lerp(rest, f.$1, math.max(f.$2, 0.35 * f.$3))!;
    final rimW = 1.6 + 1.6 * (f?.$2 ?? 0);
    return AnimatedOpacity(
      opacity: widget.enabled ? 1 : 0.5,
      duration: const Duration(milliseconds: 180),
      // A raw pointer listener: no gesture-arena delay between the touch and the response.
      child: Listener(
        onPointerDown: _onDown,
        onPointerUp: (_) => _onUp(),
        onPointerCancel: (_) => _onUp(),
        child: AnimatedBuilder(
          animation: Listenable.merge([_press, _ripple]),
          builder: (context, child) {
            final p = _press.value;
            final rp = _ripple.value;
            return Transform.scale(
              scale: 1 - 0.05 * p,
              child: Container(
                height: 92,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  color: bg,
                  border: Border.all(color: rim, width: rimW),
                  boxShadow: [
                    if (f != null) BoxShadow(color: f.$1.withValues(alpha: 0.5 * f.$3), blurRadius: 22),
                    BoxShadow(color: Colors.black.withValues(alpha: 0.45 - 0.15 * p), blurRadius: 10 - 4 * p, offset: Offset(0, 5 - 3 * p)),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (rp > 0 && rp < 1) CustomPaint(painter: _RipplePainter(_rippleAt, rp)),
                      child!,
                    ],
                  ),
                ),
              ),
            );
          },
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.icon, color: Lux.goldLight, size: 26),
              const SizedBox(height: 4),
              Text(widget.label, style: Lux.ui(18, weight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }
}

class _RipplePainter extends CustomPainter {
  final Offset at;
  final double t;
  _RipplePainter(this.at, this.t);

  static final Paint _p = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final far = [Offset.zero, Offset(size.width, 0), Offset(0, size.height), Offset(size.width, size.height)]
        .map((o) => (o - at).distance)
        .reduce(math.max);
    final e = Curves.easeOutCubic.transform(t);
    canvas.drawCircle(at, far * (0.15 + 0.85 * e), _p..color = Lux.goldLight.withValues(alpha: 0.2 * (1 - t)));
  }

  @override
  bool shouldRepaint(_RipplePainter old) => old.t != t || old.at != at;
}
