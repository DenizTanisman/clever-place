import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// Mental Aritmetik board: timer ring, big gold question, answer field, feedback flash and a
/// custom numeric keypad at thumb height. All checking/timing/scoring lives in Rust.
///
/// Motion: questions slide up and out while the next rises in; typed digits pop; keys press down;
/// a correct answer flashes the answer box green-gold, floats "+points" and feeds a streak flame;
/// a wrong one shakes the box in bordeaux and fades the correct answer in below. The timer ring is
/// redrawn every frame from the core's clock and throbs once per second in the last ten seconds.
/// Every effect is time-based and purely visual: input is never held back.
Widget mathView(BuildContext context, GameSession s) => _MathBoard(key: ObjectKey(s), session: s);

class _MathBoard extends StatefulWidget {
  final GameSession session;
  const _MathBoard({super.key, required this.session});

  @override
  State<_MathBoard> createState() => _MathBoardState();
}

class _MathBoardState extends State<_MathBoard> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;

  String _input = '';
  int _popIndex = -1; // index of the character typed last (pops in), -1 = none
  int _typeSerial = 0;
  int _seenSerial = 0;
  bool _showCard = false;

  // Last answer feedback.
  double _fbAt = -10;
  bool _fbOk = false;
  bool _fbSkipped = false;
  int _fbPoints = 0;
  String _fbGiven = '';

  // Streak flame.
  int _streakSeen = 0;
  double _streakAt = -10;
  double _flame = 0; // smoothed flame size 0..1

  double _winAt = -1;

  GameSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    final last = s.state['last'];
    if (last is Map) _seenSerial = (last['serial'] as num).toInt();
    _streakSeen = (s.state['streak'] as num?)?.toInt() ?? 0;
    _flame = _flameTarget(_streakSeen);
    s.addListener(_onSession);
  }

  @override
  void dispose() {
    s.removeListener(_onSession);
    _ticker.dispose();
    super.dispose();
  }

  double _flameTarget(int streak) => streak <= 0 ? 0 : 0.55 + 0.45 * math.min(streak, 10) / 10;

  bool _animating(double now) =>
      now - _fbAt < 1.9 || (_winAt >= 0 && now - _winAt < 0.9) || (_flame - _flameTarget(_streakSeen)).abs() > 0.01;

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1000.0;
    _lastTick = elapsed;
    _flame += (_flameTarget(_streakSeen) - _flame) * (1 - math.exp(-dt / 120));
    if (s.finished || s.state['phase'] != 'play') {
      // The core is idle; keep the last effects (and the win celebration) running.
      if (_animating(_now)) setState(() {});
      return;
    }
    s.tick(dt);
  }

  /// Turn state changes into one-shot effects (answer feedback, streak, win).
  void _onSession() {
    final st = s.state;
    final now = _now;
    final last = st['last'];
    if (last is Map) {
      final serial = (last['serial'] as num).toInt();
      if (serial != _seenSerial) {
        _seenSerial = serial;
        _fbAt = now;
        _fbOk = last['correct'] == true;
        _fbSkipped = last['skipped'] == true;
        _fbPoints = (last['points'] as num?)?.toInt() ?? 0;
        _fbGiven = (last['given'] as String?) ?? '';
        if (_fbOk) {
          HapticFeedback.selectionClick();
        } else {
          HapticFeedback.mediumImpact();
        }
      }
    }
    final streak = (st['streak'] as num?)?.toInt() ?? 0;
    if (streak != _streakSeen) {
      if (streak > _streakSeen) _streakAt = now;
      _streakSeen = streak;
    }
    if (st['status'] == 'won' && _winAt < 0) {
      _winAt = now;
      HapticFeedback.heavyImpact();
    }
  }

  void _key(String k) {
    if (s.finished || s.state['phase'] != 'play') return;
    HapticFeedback.selectionClick();
    setState(() {
      final before = _input.length;
      switch (k) {
        case '⌫':
          if (_input.isNotEmpty) _input = _input.substring(0, _input.length - 1);
        case '−':
          _input = _input.startsWith('-') ? _input.substring(1) : '-$_input';
        case ',':
          if (!_input.contains(',')) _input = '${_input.isEmpty || _input == '-' ? '${_input}0' : _input},';
        default:
          if (_input.replaceAll(RegExp(r'[-,]'), '').length < 12) _input += k;
      }
      if (_input.length > before && k != '−') {
        _popIndex = _input.length - 1;
        _typeSerial++;
      } else if (k == '−' && _input.startsWith('-')) {
        _popIndex = 0;
        _typeSerial++;
      } else {
        _popIndex = -1;
      }
    });
  }

  void _submit() {
    if (s.finished || _input.isEmpty || _input == '-') return;
    if (s.act({'answer': _input})) {
      setState(() {
        _input = '';
        _popIndex = -1;
      });
    }
  }

  void _skip() {
    if (s.finished || s.state['phase'] != 'play') return;
    HapticFeedback.lightImpact();
    if (s.act({'skip': true})) {
      setState(() {
        _input = '';
        _popIndex = -1;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = s.state;
    final phase = st['phase'] as String? ?? 'intro';
    final last = st['last'] is Map ? Map<String, dynamic>.from(st['last'] as Map) : null;
    final serial = (last?['serial'] as num?)?.toInt() ?? 0;
    final trick = st['trick'] is Map ? Map<String, dynamic>.from(st['trick'] as Map) : null;
    final now = _now;

    Widget? card;
    if (phase == 'intro') {
      card = KeyedSubtree(key: const ValueKey('intro'), child: _introCard(st, trick, start: true));
    } else if (phase == 'play' && _showCard && trick != null) {
      card = KeyedSubtree(key: const ValueKey('trick'), child: _introCard(st, trick, start: false));
    }

    return Stack(
      children: [
        Column(
          children: [
            _topRow(st, now),
            Expanded(child: _questionArea(st, last, serial, now)),
            _keypad(phase == 'play' && !s.finished),
          ],
        ),
        Positioned.fill(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 240),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, a) {
              final leaving = child.key != card?.key;
              final faded = FadeTransition(opacity: a, child: child);
              // A closing card never swallows taps meant for the keypad.
              return leaving ? IgnorePointer(child: faded) : faded;
            },
            layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, if (current != null) current]),
            child: card ?? const SizedBox.shrink(key: ValueKey('none')),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ top row

  Widget _topRow(Map<String, dynamic> st, double now) {
    final limit = (st['limit_ms'] as num?)?.toDouble() ?? 1;
    final remaining = (st['remaining_ms'] as num?)?.toDouble() ?? 0;
    final elapsed = (st['elapsed_ms'] as num?)?.toDouble() ?? 0;
    final par = (st['par_ms'] as num?)?.toDouble();
    final total = st['total'] as num?;
    final index = (st['index'] as num?)?.toInt() ?? 0;
    final streak = (st['streak'] as num?)?.toInt() ?? 0;
    final endless = st['mode'] == 'endless';
    final hasTrick = st['trick'] is Map;
    final playing = st['phase'] == 'play' && !s.finished;
    // Last ten seconds: one throb per second, peaking right as the second ticks over.
    var pulse = 0.0;
    if (playing && remaining > 0 && remaining < 10000) {
      final into = 1 - (remaining % 1000) / 1000;
      pulse = math.exp(-into * 6);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
      child: Row(
        children: [
          SizedBox(
            width: 74,
            height: 74,
            child: CustomPaint(
              painter: _TimerRing(
                fraction: (remaining / limit).clamp(0.0, 1.0),
                parFraction: par == null ? null : (par / limit).clamp(0.0, 1.0),
                overPar: par != null && elapsed > par,
                pulse: pulse,
              ),
              child: Center(
                child: Transform.scale(
                  scale: 1 + 0.14 * pulse,
                  child: Text('${(remaining / 1000).ceil()}',
                      style: Lux.ui(24, color: remaining < 10000 ? Lux.bordeauxLight : Lux.goldLight, weight: FontWeight.w700)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  endless ? '${st['score'] ?? 0} puan' : 'Soru ${math.min(index + 1, total?.toInt() ?? 0)} / $total',
                  style: Lux.ui(18, color: Lux.ink, weight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  endless
                      ? 'Zorluk ${st['tier']} · Doğru ${st['correct']}'
                      : 'Doğru ${st['correct']} · Yanlış ${(st['wrong'] as num) + (st['skipped'] as num)}',
                  style: Lux.ui(13, color: Lux.muted),
                ),
                if (!endless && total != null) ...[
                  const SizedBox(height: 6),
                  _progressBar(index / total.toDouble()),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _StreakFlame(streak: streak, size: _flame, now: now, bumpAt: _streakAt),
              if (hasTrick)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: GestureDetector(
                    onTap: () => setState(() => _showCard = true),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20), border: Border.all(color: Lux.gold.withValues(alpha: 0.6))),
                      child: Text('Hile', style: Lux.ui(12, color: Lux.gold)),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _progressBar(double f) => ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: SizedBox(
          height: 5,
          child: Stack(
            children: [
              const Positioned.fill(child: ColoredBox(color: Color(0xFF2A2015))),
              AnimatedFractionallySizedBox(
                duration: const Duration(milliseconds: 420),
                curve: Curves.easeOutCubic,
                widthFactor: f.clamp(0.0, 1.0),
                child: const DecoratedBox(decoration: BoxDecoration(gradient: Lux.goldGradient)),
              ),
            ],
          ),
        ),
      );

  // ------------------------------------------------------------------ question

  Widget _questionArea(Map<String, dynamic> st, Map<String, dynamic>? last, int serial, double now) {
    final q = st['question'] is Map ? Map<String, dynamic>.from(st['question'] as Map) : null;
    final unit = (q?['unit'] as String?) ?? '';
    return LayoutBuilder(builder: (context, box) {
      final big = (box.maxHeight * 0.2).clamp(34.0, 64.0);
      final key = ValueKey('${st['index']}-${q?['text']}');
      return Stack(
        clipBehavior: Clip.none,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (q != null) ...[
                  Text(Lux.upper(q['label'] as String), style: Lux.ui(12, color: Lux.gold, spacing: 2.2, weight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(q['prompt'] as String, textAlign: TextAlign.center, style: Lux.ui(16, color: Lux.muted)),
                  const SizedBox(height: 10),
                  // Outgoing question lifts and fades; the next one rises in from below.
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, a) {
                      final incoming = child.key == key;
                      final from = incoming ? const Offset(0, 0.45) : const Offset(0, -0.45);
                      return FadeTransition(
                        opacity: a,
                        child: SlideTransition(position: Tween(begin: from, end: Offset.zero).animate(a), child: child),
                      );
                    },
                    layoutBuilder: (current, previous) =>
                        Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [...previous, if (current != null) current]),
                    child: FittedBox(
                      key: key,
                      fit: BoxFit.scaleDown,
                      child: ShaderMask(
                        shaderCallback: (r) => Lux.goldGradient.createShader(r),
                        child: Text(q['text'] as String,
                            maxLines: 1, style: Lux.display(big, color: Colors.white, spacing: 1.5)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  _answerField(unit, now),
                ],
                const SizedBox(height: 12),
                SizedBox(height: 54, child: _feedback(last, serial)),
              ],
            ),
          ),
          if (_winAt >= 0 && now - _winAt < 0.9)
            Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _WinBurst(now - _winAt)))),
        ],
      );
    });
  }

  Widget _answerField(String unit, double now) {
    final t = now - _fbAt;
    final ok = _fbOk;
    // Flash envelope: quick rise, ~0.5 s decay.
    final flash = t >= 0 && t < 0.55 ? math.pow(1 - t / 0.55, 2).toDouble() : 0.0;
    final shake = !ok && t >= 0 && t < 0.35 ? math.sin(t * 52) * 9 * math.exp(-t * 9) : 0.0;
    final tone = ok ? Color.lerp(Lux.good, Lux.gold, 0.35)! : Lux.bordeaux;
    final rim = Color.lerp(Lux.gold.withValues(alpha: 0.55), ok ? Lux.good : Lux.bordeauxLight, flash)!;
    final glow = Color.lerp(Lux.gold.withValues(alpha: 0.12), tone.withValues(alpha: 0.55), flash)!;
    final bg = Color.lerp(const Color(0xFF120D08), tone, 0.16 * flash)!;

    // While the field is still empty, the answer just given lingers and fades (green or bordeaux).
    final ghost = _input.isEmpty && !_fbSkipped && _fbGiven.isNotEmpty && t >= 0 && t < 0.5;
    Widget value;
    if (ghost) {
      final a = 1 - Curves.easeIn.transform(t / 0.5);
      value = Opacity(
        opacity: a,
        child: Text(_fbGiven.replaceAll('-', '−'),
            style: Lux.ui(34, color: ok ? Lux.good : Lux.bordeauxLight, weight: FontWeight.w700).copyWith(
              decoration: ok ? null : TextDecoration.lineThrough,
              decorationColor: Lux.bordeauxLight,
            )),
      );
    } else if (_input.isEmpty) {
      value = Text('?', style: Lux.ui(34, color: Lux.muted.withValues(alpha: 0.5), weight: FontWeight.w700));
    } else {
      final style = Lux.ui(34, color: Lux.ink, weight: FontWeight.w700);
      final chars = _input.replaceAll('-', '−').split('');
      value = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < chars.length; i++)
            if (i == _popIndex)
              TweenAnimationBuilder<double>(
                key: ValueKey('pop$_typeSerial'),
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 170),
                builder: (context, v, child) => Opacity(
                  opacity: (v * 2.5).clamp(0.0, 1.0),
                  child: Transform.translate(
                    offset: Offset(0, 6 * (1 - Curves.easeOutCubic.transform(v))),
                    child: Transform.scale(scale: 0.55 + 0.45 * Curves.easeOutBack.transform(v), child: child),
                  ),
                ),
                child: Text(chars[i], style: style),
              )
            else
              Text(chars[i], style: style),
        ],
      );
    }

    final box = Container(
      constraints: const BoxConstraints(minWidth: 180),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: bg,
        border: Border.all(color: rim, width: 1.3 + 0.7 * flash),
        boxShadow: [BoxShadow(color: glow, blurRadius: 16 + 14 * flash)],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          value,
          if (unit.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(unit, style: Lux.ui(18, color: Lux.muted)),
          ],
        ],
      ),
    );

    // "+points" rises from the box after a correct answer (positioned: never moves the layout).
    final showPts = ok && _fbPoints > 0 && t >= 0 && t < 0.85;
    return Transform.translate(
      offset: Offset(shake, 0),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          box,
          if (showPts)
            Positioned(
              top: -30 - 26 * Curves.easeOutCubic.transform(t / 0.85),
              child: IgnorePointer(
                child: Opacity(
                  opacity: (t < 0.08 ? t / 0.08 : (t > 0.5 ? 1 - (t - 0.5) / 0.35 : 1.0)).clamp(0.0, 1.0),
                  child: Transform.scale(
                    scale: 0.8 + 0.2 * Curves.easeOutBack.transform((t / 0.25).clamp(0.0, 1.0)),
                    child: FoilText('+$_fbPoints', style: Lux.numeral(26)),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _feedback(Map<String, dynamic>? last, int serial) {
    if (last == null) return const SizedBox();
    final ok = last['correct'] == true;
    final skipped = last['skipped'] == true;
    final pts = (last['points'] as num?)?.toInt() ?? 0;
    final text = ok
        ? (pts > 0 ? 'Doğru · +$pts' : 'Doğru')
        : '${skipped ? 'Geçildi' : 'Yanlış'} · ${last['text']} = ${last['answer']}';
    return TweenAnimationBuilder<double>(
      key: ValueKey(serial),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 1800),
      builder: (context, t, _) {
        final color = ok ? Lux.gold : Lux.bordeaux;
        final double opacity;
        final double scale;
        final double lift;
        if (ok) {
          final pop = Curves.easeOutBack.transform((t * 4).clamp(0.0, 1.0));
          opacity = t < 0.75 ? 1.0 : 1 - (t - 0.75) / 0.25;
          scale = 0.8 + 0.2 * pop;
          lift = 0;
        } else {
          // The correct answer is revealed softly and stays readable.
          final fin = Curves.easeOutCubic.transform((t / 0.2).clamp(0.0, 1.0));
          final out = t < 0.8 ? 0.0 : (t - 0.8) / 0.2;
          opacity = fin * (1 - 0.45 * out);
          scale = 0.97 + 0.03 * fin;
          lift = 6 * (1 - fin);
        }
        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, lift),
            child: Transform.scale(
              scale: scale,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    color: color.withValues(alpha: 0.16),
                    border: Border.all(color: color.withValues(alpha: 0.8)),
                    boxShadow: [BoxShadow(color: color.withValues(alpha: 0.35 * (1 - t)), blurRadius: 22)],
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(text,
                        maxLines: 1,
                        style: Lux.ui(17, color: ok ? Lux.goldLight : const Color(0xFFFFD6DF), weight: FontWeight.w700)),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------------ keypad

  Widget _keypad(bool enabled) {
    const rows = [
      ['7', '8', '9', '⌫'],
      ['4', '5', '6', '−'],
      ['1', '2', '3', ','],
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 14),
      child: AnimatedOpacity(
        opacity: enabled ? 1 : 0.45,
        duration: const Duration(milliseconds: 200),
        child: Column(
          children: [
            for (final r in rows)
              Row(children: [for (final k in r) Expanded(child: _KeyButton(label: k, onTap: () => _key(k), accent: !_isDigit(k)))]),
            Row(
              children: [
                Expanded(child: _KeyButton(label: 'Geç', onTap: _skip, accent: true, small: true)),
                Expanded(child: _KeyButton(label: '0', onTap: () => _key('0'))),
                Expanded(flex: 2, child: _KeyButton(label: 'Tamam', onTap: _submit, primary: true, small: true)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  bool _isDigit(String k) => k.length == 1 && k.codeUnitAt(0) >= 48 && k.codeUnitAt(0) <= 57;

  // ------------------------------------------------------------------ cards

  Widget _introCard(Map<String, dynamic> st, Map<String, dynamic>? trick, {required bool start}) {
    final endless = st['mode'] == 'endless';
    final lines = (trick?['text'] as String?)?.split('\n') ?? const <String>[];
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.55),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            builder: (context, t, child) => Opacity(
              opacity: t,
              child: Transform.translate(
                offset: Offset(0, 14 * (1 - t)),
                child: Transform.scale(scale: 0.94 + 0.06 * t, child: child),
              ),
            ),
            child: LuxCard(
              highlight: true,
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (trick != null) ...[
                    Text(Lux.upper('Hile kartı'), style: Lux.ui(12, color: Lux.gold, spacing: 2.4, weight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Text(trick['title'] as String, style: Lux.display(19, spacing: 1)),
                    const SizedBox(height: 14),
                    for (final l in lines)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(l, style: Lux.ui(16, color: Lux.ink, weight: FontWeight.w500)),
                      ),
                  ] else ...[
                    Text(endless ? 'Sprint' : (st['title'] as String? ?? ''), style: Lux.display(20, spacing: 1)),
                    const SizedBox(height: 12),
                    Text(
                      endless
                          ? '60 saniye. Doğru cevaplar seriyi büyütür, seri zorluğu ve puanı artırır. Yanlışta zorluk düşer.'
                          : '${st['total']} soru. Yanlış cevapta doğrusu gösterilir ve sıradaki soruya geçilir.',
                      style: Lux.ui(16, color: Lux.ink, weight: FontWeight.w500),
                    ),
                  ],
                  if (start && !endless) ...[
                    const SizedBox(height: 6),
                    Text(st['goal'] as String? ?? '', style: Lux.ui(14, color: Lux.muted)),
                  ],
                  const SizedBox(height: 18),
                  Center(
                    child: GoldButton(
                      start ? 'Başla' : 'Devam',
                      icon: start ? Icons.play_arrow_rounded : Icons.close_rounded,
                      onPressed: () {
                        if (start) {
                          s.act({'start': true});
                        } else {
                          setState(() => _showCard = false);
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

/// Keypad key: sinks to 94 % on touch-down (~80 ms) and springs back; the tap itself is handled
/// exactly as before, so typing speed is never limited by the animation.
class _KeyButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final bool accent;
  final bool primary;
  final bool small;
  const _KeyButton({required this.label, required this.onTap, this.accent = false, this.primary = false, this.small = false});

  @override
  State<_KeyButton> createState() => _KeyButtonState();
}

class _KeyButtonState extends State<_KeyButton> with SingleTickerProviderStateMixin {
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 80),
    reverseDuration: const Duration(milliseconds: 160),
  );
  bool _down = false;

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  void _setDown(bool d) {
    _down = d;
    if (d) {
      _press.forward();
    } else if (_press.isAnimating && _press.status == AnimationStatus.forward) {
      // A very quick tap still shows the full press before springing back.
      _press.forward().whenComplete(() {
        if (!_down && mounted) _press.reverse();
      });
    } else {
      _press.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = widget.primary;
    final fg = primary ? const Color(0xFF1A1206) : (widget.accent ? Lux.gold : Lux.ink);
    final label = widget.label;
    return Padding(
      padding: const EdgeInsets.all(4),
      child: AnimatedBuilder(
        animation: _press,
        builder: (context, child) {
          final p = _press.value;
          return Transform.scale(
            scale: 1 - 0.06 * p,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: (primary ? Lux.gold : Lux.goldLight).withValues(alpha: 0.22 * p),
                    blurRadius: 14,
                  ),
                ],
              ),
              child: child,
            ),
          );
        },
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            splashColor: Lux.gold.withValues(alpha: 0.2),
            onTapDown: (_) => _setDown(true),
            onTapUp: (_) => _setDown(false),
            onTapCancel: () => _setDown(false),
            onTap: widget.onTap,
            child: Ink(
              height: 62,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
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
                    ? Icon(Icons.backspace_outlined, color: fg, size: 24)
                    : Text(label, style: Lux.ui(widget.small ? 19 : 28, color: fg, weight: FontWeight.w700)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Timer ring: gold arc for the remaining time, a small tick for the par (3-star) time, a bright
/// bead on the arc's head, and a bordeaux throb ([pulse]) in the last ten seconds.
class _TimerRing extends CustomPainter {
  final double fraction;
  final double? parFraction;
  final bool overPar;
  final double pulse;
  _TimerRing({required this.fraction, this.parFraction, this.overPar = false, this.pulse = 0});

  static final Paint _track = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 6
    ..color = const Color(0xFF2A2015);
  static final Paint _arc = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  static final Paint _fill = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 5;
    canvas.drawCircle(c, r, _track);
    final rect = Rect.fromCircle(center: c, radius: r);
    final color = fraction < 0.2 ? Lux.bordeauxLight : (overPar ? Lux.goldDeep : Lux.gold);
    final sweep = 2 * math.pi * fraction;
    if (pulse > 0.01) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        sweep,
        false,
        _arc
          ..strokeWidth = 6 + 8 * pulse
          ..shader = null
          ..color = Lux.bordeaux.withValues(alpha: 0.55 * pulse)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
      _arc.maskFilter = null;
    }
    canvas.drawArc(
      rect,
      -math.pi / 2,
      sweep,
      false,
      _arc
        ..strokeWidth = 6 + 1.5 * pulse
        ..shader = SweepGradient(
          startAngle: -math.pi / 2,
          endAngle: 3 * math.pi / 2,
          colors: [Color.lerp(color, Colors.white, 0.3)!, color],
          transform: const GradientRotation(-math.pi / 2),
        ).createShader(rect),
    );
    _arc.shader = null;
    if (fraction > 0.003) {
      final a = -math.pi / 2 + sweep;
      final head = c + Offset(math.cos(a), math.sin(a)) * r;
      canvas.drawCircle(head, 4.5, _fill..color = Color.lerp(color, Colors.white, 0.6)!.withValues(alpha: 0.35));
      canvas.drawCircle(head, 2.2, _fill..color = Color.lerp(color, Colors.white, 0.75)!);
    }
    final pf = parFraction;
    if (pf != null) {
      // Par marker: remaining-time fraction at which the par time is reached.
      final a = -math.pi / 2 + 2 * math.pi * (1 - pf);
      final p1 = c + Offset(math.cos(a), math.sin(a)) * (r - 6);
      final p2 = c + Offset(math.cos(a), math.sin(a)) * (r + 6);
      canvas.drawLine(
          p1,
          p2,
          _fill
            ..strokeWidth = 2
            ..color = Lux.goldLight);
    }
  }

  @override
  bool shouldRepaint(_TimerRing old) =>
      old.fraction != fraction || old.parFraction != parFraction || old.overPar != overPar || old.pulse != pulse;
}

/// Streak counter: a flickering gold flame that grows with the streak (fixed footprint, so the
/// header never shifts) and a number that pops on every new step.
class _StreakFlame extends StatelessWidget {
  final int streak;
  final double size; // smoothed 0..1
  final double now, bumpAt;
  const _StreakFlame({required this.streak, required this.size, required this.now, required this.bumpAt});

  @override
  Widget build(BuildContext context) {
    final bump = now - bumpAt;
    final kick = bump >= 0 && bump < 0.45 ? math.exp(-bump * 9) : 0.0;
    return SizedBox(
      width: 66,
      height: 34,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          SizedBox(
            width: 26,
            height: 34,
            child: CustomPaint(painter: _FlamePainter(size: size, now: now, kick: kick)),
          ),
          SizedBox(
            width: 36,
            child: streak > 0
                ? Transform.scale(
                    scale: 1 + 0.35 * kick,
                    alignment: Alignment.centerLeft,
                    child: Text(' $streak',
                        style: Lux.ui(17, color: Color.lerp(Lux.goldLight, Colors.white, 0.6 * kick)!, weight: FontWeight.w700)),
                  )
                : null,
          ),
        ],
      ),
    );
  }
}

class _FlamePainter extends CustomPainter {
  final double size, now, kick;
  _FlamePainter({required this.size, required this.now, required this.kick});

  static final Paint _p = Paint();

  @override
  void paint(Canvas canvas, Size box) {
    if (size <= 0.02) return;
    final s = size * (1 + 0.25 * kick);
    final h = box.height * 0.92 * s;
    final w = box.width * 0.62 * s;
    final base = Offset(box.width / 2, box.height - 2);
    final flick = math.sin(now * 9.0) * 0.5 + math.sin(now * 13.7) * 0.5;
    Path flame(double hw, double hh, double sway) {
      final tip = base + Offset(sway * hw, -hh);
      return Path()
        ..moveTo(base.dx, base.dy)
        ..cubicTo(base.dx - hw * 1.1, base.dy - hh * 0.15, base.dx - hw * 0.7, base.dy - hh * 0.65, tip.dx, tip.dy)
        ..cubicTo(base.dx + hw * 0.75, base.dy - hh * 0.6, base.dx + hw * 1.1, base.dy - hh * 0.15, base.dx, base.dy)
        ..close();
    }

    canvas.drawCircle(base - Offset(0, h * 0.35), w * 0.9,
        _p
          ..shader = null
          ..color = Lux.gold.withValues(alpha: (0.18 + 0.25 * kick) * size)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7));
    _p.maskFilter = null;
    final outer = flame(w / 2, h * (1 + 0.04 * flick), 0.18 * flick);
    final bounds = Rect.fromLTWH(base.dx - w / 2, base.dy - h, w, h);
    canvas.drawPath(
      outer,
      _p
        ..shader = const LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xFFA3203F), Color(0xFFD4A94E), Color(0xFFF0D69A)],
          stops: [0, 0.45, 1],
        ).createShader(bounds),
    );
    _p.shader = null;
    final inner = flame(w * 0.24, h * (0.55 + 0.03 * flick), -0.12 * flick);
    canvas.drawPath(inner, _p..color = const Color(0xFFFFF4D6).withValues(alpha: 0.9));
  }

  @override
  bool shouldRepaint(_FlamePainter old) => old.size != size || old.now != now || old.kick != kick;
}

/// Win celebration (~0.8 s): a gold bloom behind the answer and sparks fanning out.
class _WinBurst extends CustomPainter {
  final double t;
  _WinBurst(this.t);

  static final Paint _p = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final u = (t / 0.85).clamp(0.0, 1.0);
    final c = Offset(size.width / 2, size.height * 0.5);
    final e = Curves.easeOutCubic.transform(u);
    final bloom = math.sin(math.pi * u);
    canvas.drawCircle(
        c,
        size.shortestSide * (0.25 + 0.25 * e),
        _p
          ..shader = null
          ..color = Lux.gold.withValues(alpha: 0.22 * bloom)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 40));
    _p.maskFilter = null;
    canvas.drawCircle(
        c,
        size.shortestSide * (0.1 + 0.5 * e),
        _p
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5 * (1 - u) + 0.5
          ..color = Lux.goldLight.withValues(alpha: 0.7 * (1 - u)));
    _p.style = PaintingStyle.fill;
    for (var i = 0; i < 22; i++) {
      final a = i * 2 * math.pi / 22 + (i.isEven ? 0.08 : -0.05);
      final sp = 0.65 + 0.35 * ((i * 7) % 5) / 4;
      final d = size.shortestSide * (0.12 + 0.48 * sp * e);
      final p = c + Offset(math.cos(a) * d, math.sin(a) * d * 0.8 + 24 * u * u);
      final r = (3.2 * (1 - u) + 0.8);
      _p.color = (i % 3 == 0 ? Lux.goldLight : Lux.gold).withValues(alpha: 1 - u * u);
      canvas.drawPath(
        Path()
          ..moveTo(p.dx, p.dy - r * 2)
          ..lineTo(p.dx + r * 0.55, p.dy)
          ..lineTo(p.dx, p.dy + r * 2)
          ..lineTo(p.dx - r * 0.55, p.dy)
          ..close(),
        _p,
      );
    }
  }

  @override
  bool shouldRepaint(_WinBurst old) => old.t != t;
}
