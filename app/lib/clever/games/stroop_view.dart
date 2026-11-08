import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// Renk–Kelime (Stroop) board: a dark ink stage in the middle (fixation cross, then the coloured
/// word, with the RENK / KELİME rule cue on switching levels) and big colour-swatch buttons at
/// thumb height. Trials, deadlines, scoring and the Stroop effect are computed in Rust.
///
/// Answers fire on pointer-down. Feedback: the tapped swatch glows gold (correct) or flashes
/// bordeaux and shakes (wrong) while the right swatch is outlined; the word lifts away on a hit and
/// shakes on a miss; a timeout fades "Süre!" in. The thin rail under the stage is the word's time.
Widget stroopView(BuildContext context, GameSession s) => _StroopBoard(key: ObjectKey(s), session: s);

/// Ink colours by core index (KIRMIZI, MAVİ, YEŞİL, SARI, MOR, TURUNCU): vivid, clearly separated in
/// hue and bright enough to read on the near-black stage.
const _inks = [
  Color(0xFFF2434D),
  Color(0xFF3F8CFF),
  Color(0xFF3CCB6A),
  Color(0xFFFFD43B),
  Color(0xFFB36BFF),
  Color(0xFFFF8A1F),
];

class _StroopBoard extends StatefulWidget {
  final GameSession session;
  const _StroopBoard({super.key, required this.session});

  @override
  State<_StroopBoard> createState() => _StroopBoardState();
}

class _StroopBoardState extends State<_StroopBoard> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;

  int _seenSerial = 0;
  double _fbAt = -10;
  bool _fbOk = true;
  bool _fbTimeout = false;
  int? _fbAnswer;
  int _fbExpected = -1;
  int _fbRt = 0;

  // The word on screen is kept after the core hides it, for the exit animation.
  Map<String, dynamic>? _word;
  int _wordTrial = -1;

  int _pressColor = -1;
  double _pressAt = -10;

  int _lastCount = 0;
  double _winAt = -1;

  GameSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    final last = s.state['last'];
    if (last is Map) _seenSerial = (last['serial'] as num).toInt();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  bool _animating(double now) => now - _fbAt < 0.7 || now - _pressAt < 0.25 || (_winAt >= 0 && now - _winAt < 1.0);

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

  void _sync(Map<String, dynamic> st, double now) {
    final last = st['last'];
    if (last is Map) {
      final serial = (last['serial'] as num).toInt();
      if (serial != _seenSerial) {
        _seenSerial = serial;
        _fbAt = now;
        _fbOk = last['ok'] == true;
        _fbTimeout = last['timeout'] == true;
        _fbAnswer = (last['answer'] as num?)?.toInt();
        _fbExpected = (last['expected'] as num?)?.toInt() ?? -1;
        _fbRt = (last['rt'] as num?)?.toInt() ?? 0;
        if (_fbOk) {
          HapticFeedback.lightImpact();
        } else {
          HapticFeedback.mediumImpact();
        }
      }
    }
    final stim = st['stim'];
    if (stim is Map) {
      _word = Map<String, dynamic>.from(stim);
      _wordTrial = (st['trial'] as num?)?.toInt() ?? -1;
    }
    if (st['phase'] == 'countdown') {
      final k = (((st['countdown_ms'] as num?) ?? 0) / 1000).ceil();
      if (k != _lastCount && k >= 1 && k <= 3) HapticFeedback.selectionClick();
      _lastCount = k;
    }
    if (st['status'] == 'won' && _winAt < 0) {
      _winAt = now;
      HapticFeedback.heavyImpact();
    }
  }

  void _answer(int color) {
    final st = s.state;
    // Taps between words (fixation) are ignored rather than rejected: no toast mid-run.
    if (s.finished || st['phase'] != 'run' || st['sub'] != 'stim') return;
    _pressColor = color;
    _pressAt = _now;
    s.act({'answer': color});
  }

  @override
  Widget build(BuildContext context) {
    final st = s.state;
    final now = _now;
    _sync(st, now);
    final phase = st['phase'] as String? ?? 'intro';
    final buttons = [for (final b in (st['buttons'] as List? ?? const [])) (b as num).toInt()];
    return Stack(
      children: [
        Column(
          children: [
            _header(st, now),
            Expanded(child: _stage(st, now)),
            _buttonPad(buttons, phase == 'run' && !s.finished, now),
          ],
        ),
        if (phase == 'countdown') Positioned.fill(child: IgnorePointer(child: _countdown(st))),
        if (phase == 'intro') Positioned.fill(child: _introCard(st)),
      ],
    );
  }

  // ------------------------------------------------------------------ header

  Widget _header(Map<String, dynamic> st, double now) {
    final endless = st['mode'] == 'endless';
    final trial = (st['trial'] as num?)?.toInt() ?? 0;
    final trials = (st['trials'] as num?)?.toInt();
    final correct = (st['correct'] as num?)?.toInt() ?? 0;
    final wrong = ((st['wrong'] as num?)?.toInt() ?? 0) + ((st['timeouts'] as num?)?.toInt() ?? 0);
    final meanRt = (st['mean_rt'] as num?)?.toInt();
    final par = (st['par_rt'] as num?)?.toInt();
    final effect = (st['interference_ms'] as num?)?.toInt();
    final remaining = (st['remaining_ms'] as num?)?.toDouble() ?? 0;
    final limit = (st['limit_ms'] as num?)?.toDouble() ?? 60000;
    final tf = now - _fbAt;
    final kick = tf >= 0 && tf < 0.4 ? math.exp(-tf * 8) : 0.0;

    final stats = <String>[
      'Doğru $correct',
      if (wrong > 0) 'Hata $wrong',
      if (meanRt != null) 'Ort. $meanRt ms',
      if (effect != null) 'Stroop ${effect >= 0 ? '+' : '−'}${effect.abs()} ms',
    ];

    Widget left;
    if (endless) {
      final secs = (remaining / 1000).ceil();
      left = Row(
        children: [
          SizedBox(
            width: 56,
            height: 56,
            child: CustomPaint(
              painter: _Ring((remaining / limit).clamp(0.0, 1.0), low: remaining < 10000),
              child: Center(
                child: Text('$secs',
                    style: Lux.ui(19,
                        color: remaining < 10000 ? Lux.bordeauxLight : Lux.goldLight, weight: FontWeight.w700)),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Transform.scale(
                scale: 1 + (_fbOk ? 0.12 : 0) * kick,
                alignment: Alignment.centerLeft,
                child: Text('${st['score'] ?? 0} puan', style: Lux.ui(19, weight: FontWeight.w700)),
              ),
              Text('Zorluk ${st['stage'] ?? 1}', style: Lux.ui(12.5, color: Lux.muted)),
            ],
          ),
        ],
      );
    } else {
      left = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Kelime ${math.min(trial + 1, trials ?? 1)} / ${trials ?? '–'}',
              style: Lux.ui(18, weight: FontWeight.w700)),
          if (par != null) Text('Hedef ort. $par ms', style: Lux.ui(12.5, color: Lux.muted)),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: left),
              _rtChip(now),
            ],
          ),
          const SizedBox(height: 8),
          if (!endless && trials != null) _progressBar(trial / trials),
          const SizedBox(height: 6),
          SizedBox(
            height: 18,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(stats.join('  ·  '), style: Lux.ui(13, color: Lux.muted)),
            ),
          ),
        ],
      ),
    );
  }

  /// Reaction time of the last answer, popping in green-gold or bordeaux.
  Widget _rtChip(double now) {
    final tf = now - _fbAt;
    if (tf < 0 || tf > 1.6) return const SizedBox(width: 92, height: 34);
    final inT = Curves.easeOutBack.transform((tf / 0.18).clamp(0.0, 1.0));
    final out = tf > 1.2 ? (tf - 1.2) / 0.4 : 0.0;
    final color = _fbOk ? Lux.gold : Lux.bordeauxLight;
    final text = _fbTimeout ? 'Süre!' : (_fbOk ? '$_fbRt ms' : 'Yanlış');
    return SizedBox(
      width: 92,
      height: 34,
      child: Opacity(
        opacity: (1 - out).clamp(0.0, 1.0),
        child: Transform.scale(
          scale: 0.7 + 0.3 * inT,
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: color.withValues(alpha: 0.14),
              border: Border.all(color: color.withValues(alpha: 0.8)),
            ),
            child: Text(text,
                style: Lux.ui(14, color: _fbOk ? Lux.goldLight : const Color(0xFFFFD6DF), weight: FontWeight.w700)),
          ),
        ),
      ),
    );
  }

  Widget _progressBar(double f) => ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: SizedBox(
          height: 4,
          child: Stack(
            children: [
              const Positioned.fill(child: ColoredBox(color: Color(0xFF0A2B21))),
              AnimatedFractionallySizedBox(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.centerLeft,
                widthFactor: f.clamp(0.0, 1.0),
                child: const DecoratedBox(decoration: BoxDecoration(gradient: Lux.goldGradient)),
              ),
            ],
          ),
        ),
      );

  // ------------------------------------------------------------------ stage

  Widget _stage(Map<String, dynamic> st, double now) {
    final sub = st['sub'] as String?;
    final cue = st['cue'] as String?;
    final t = (st['t_ms'] as num?)?.toDouble() ?? 0;
    final deadline = (st['deadline_ms'] as num?)?.toDouble() ?? 1;
    final running = st['phase'] == 'run' && !s.finished;
    final showing = sub == 'stim';
    final trial = (st['trial'] as num?)?.toInt() ?? 0;
    final wordRule = cue == 'word';
    final rim = cue == null ? Lux.gold.withValues(alpha: 0.5) : (wordRule ? Lux.ink.withValues(alpha: 0.85) : Lux.gold);

    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth - 32;
      final h = box.maxHeight - 20;
      final base = (w / 6.2).clamp(30.0, 74.0);

      // Word: present → full; just answered → exit animation; timeout → fade.
      Widget? word;
      final wm = _word;
      if (wm != null) {
        final current = showing && _wordTrial == trial;
        final tf = now - _fbAt;
        double opacity = 0, dy = 0, dx = 0, scale = 1;
        if (current) {
          final inT = Curves.easeOut.transform((t / 70).clamp(0.0, 1.0));
          opacity = inT;
          scale = 0.96 + 0.04 * inT;
        } else if (tf >= 0 && tf < 0.28 && _wordTrial == trial - 1) {
          final u = tf / 0.28;
          opacity = 1 - Curves.easeIn.transform(u);
          if (_fbOk) {
            dy = -18 * Curves.easeOutCubic.transform(u);
            scale = 1 + 0.06 * u;
          } else {
            dx = math.sin(tf * 60) * 10 * math.exp(-tf * 10);
          }
        }
        if (opacity > 0.01) {
          final ink = _inks[((wm['ink'] as num?)?.toInt() ?? 0).clamp(0, _inks.length - 1)];
          final size = base * ((wm['size'] as num?)?.toDouble() ?? 1);
          final x = (wm['x'] as num?)?.toDouble() ?? 0;
          final y = (wm['y'] as num?)?.toDouble() ?? 0;
          word = Align(
            alignment: Alignment(x, y),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Transform.translate(
                offset: Offset(dx, dy),
                child: Transform.scale(
                  scale: scale,
                  child: Opacity(
                    opacity: opacity.clamp(0.0, 1.0),
                    child: Text(
                      wm['word'] as String? ?? '',
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        fontFamily: 'Jost',
                        fontSize: size,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5,
                        color: ink,
                        height: 1,
                        shadows: [
                          Shadow(color: Colors.black.withValues(alpha: 0.6), blurRadius: 6, offset: const Offset(0, 2))
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }
      }

      final fixing = running && sub == 'fix';
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          children: [
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  color: const Color(0xFF020E09),
                  border: Border.all(color: rim, width: wordRule ? 2.2 : 1.3),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.55), blurRadius: 22, offset: const Offset(0, 10)),
                  ],
                ),
                child: Stack(
                  children: [
                    if (wordRule)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Container(
                            margin: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(17),
                              border: Border.all(color: Lux.ink.withValues(alpha: 0.35)),
                            ),
                          ),
                        ),
                      ),
                    if (cue != null && running)
                      Positioned(top: 14, left: 0, right: 0, child: Center(child: _cuePill(cue))),
                    // The cross fades in once the previous word has left, so the two never compete.
                    if (fixing)
                      Center(
                        child: Opacity(
                          opacity: ((t - 120) / 100).clamp(0.0, 1.0),
                          child: Text('+',
                              style: Lux.ui(math.min(h, w) * 0.12, color: Lux.muted, weight: FontWeight.w300)),
                        ),
                      ),
                    if (word != null)
                      Positioned.fill(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(14, cue != null ? 56 : 14, 14, 14),
                          child: word,
                        ),
                      ),
                    if (_fbTimeout && now - _fbAt < 0.6 && running)
                      Center(
                        child: Opacity(
                          opacity: (1 - (now - _fbAt) / 0.6).clamp(0.0, 1.0),
                          child: Text('Süre!', style: Lux.display(34, color: Lux.bordeauxLight)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Time left for this word.
            SizedBox(
              height: 3,
              child: LayoutBuilder(builder: (context, b) {
                final f = showing ? (1 - t / deadline).clamp(0.0, 1.0) : (running ? 1.0 : 0.0);
                return Align(
                  alignment: Alignment.center,
                  child: Container(
                    width: b.maxWidth * f,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      color: (f < 0.25 ? Lux.bordeauxLight : Lux.gold).withValues(alpha: showing ? 0.7 : 0.25),
                    ),
                  ),
                );
              }),
            ),
          ],
        ),
      );
    });
  }

  Widget _cuePill(String cue) {
    final word = cue == 'word';
    final color = word ? Lux.ink : Lux.gold;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.85), width: 1.3),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(word ? Icons.text_fields_rounded : Icons.water_drop_rounded, size: 17, color: color),
          const SizedBox(width: 6),
          Text(word ? 'KELİME' : 'RENK', style: Lux.ui(15, color: color, weight: FontWeight.w700, spacing: 2)),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ buttons

  Widget _buttonPad(List<int> buttons, bool enabled, double now) {
    final k = buttons.length;
    final perRow = k == 4 ? 2 : 3;
    final rows = <List<int>>[];
    for (var i = 0; i < k; i += perRow) {
      rows.add(buttons.sublist(i, math.min(i + perRow, k)));
    }
    final height = rows.length == 1 ? 104.0 : 84.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 18),
      child: AnimatedOpacity(
        opacity: enabled ? 1 : 0.5,
        duration: const Duration(milliseconds: 200),
        child: LayoutBuilder(builder: (context, box) {
          final cellW = box.maxWidth / perRow;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final r in rows)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final c in r) SizedBox(width: cellW, height: height, child: _swatch(c, now)),
                  ],
                ),
            ],
          );
        }),
      ),
    );
  }

  Widget _swatch(int color, double now) {
    final ink = _inks[color.clamp(0, _inks.length - 1)];
    final tp = now - _pressAt;
    final press = color == _pressColor && tp >= 0 && tp < 0.2
        ? (tp < 0.05 ? tp / 0.05 : 1 - (tp - 0.05) / 0.15).clamp(0.0, 1.0)
        : 0.0;
    final tf = now - _fbAt;
    final fb = tf >= 0 && tf < 0.5 ? math.pow(1 - tf / 0.5, 2).toDouble() : 0.0;
    final mine = _fbAnswer == color;
    final hit = mine && _fbOk ? fb : 0.0;
    final miss = mine && !_fbOk ? fb : 0.0;
    // After a miss or timeout the correct swatch is outlined briefly, so the mapping is learned.
    final reveal = !_fbOk && color == _fbExpected && tf >= 0 && tf < 0.7 ? 1 - tf / 0.7 : 0.0;
    final shake = miss > 0 ? math.sin(tf * 60) * 7 * math.exp(-tf * 10) : 0.0;
    final rim = hit > 0
        ? Color.lerp(Lux.gold.withValues(alpha: 0.5), Lux.goldLight, hit)!
        : miss > 0
            ? Color.lerp(Lux.gold.withValues(alpha: 0.5), Lux.bordeauxLight, miss)!
            : reveal > 0
                ? Color.lerp(Lux.gold.withValues(alpha: 0.5), Colors.white, reveal)!
                : Lux.gold.withValues(alpha: 0.5);

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => _answer(color),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Transform.translate(
          offset: Offset(shake, 0),
          child: Transform.scale(
            scale: 1 - 0.06 * press + 0.03 * hit,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color.lerp(ink, Colors.white, 0.28 + 0.1 * press)!,
                    ink,
                    Color.lerp(ink, Colors.black, 0.45)!,
                  ],
                  stops: const [0, 0.5, 1],
                ),
                border: Border.all(color: rim, width: 1.4 + 1.6 * math.max(hit, math.max(miss, reveal))),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 10, offset: const Offset(0, 5)),
                  if (hit > 0.01) BoxShadow(color: Lux.gold.withValues(alpha: 0.55 * hit), blurRadius: 20 * hit),
                  if (miss > 0.01) BoxShadow(color: Lux.bordeaux.withValues(alpha: 0.7 * miss), blurRadius: 20 * miss),
                ],
              ),
              child: Stack(
                children: [
                  // Glossy highlight: a soft sheen across the top third.
                  Positioned(
                    left: 10,
                    right: 10,
                    top: 6,
                    height: 16,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.white.withValues(alpha: 0.32), Colors.white.withValues(alpha: 0)],
                        ),
                      ),
                    ),
                  ),
                  if (miss > 0.01)
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          color: Lux.bordeaux.withValues(alpha: 0.35 * miss),
                        ),
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

  // ------------------------------------------------------------------ overlays

  Widget _countdown(Map<String, dynamic> st) {
    final ms = (st['countdown_ms'] as num?)?.toDouble() ?? 0;
    final k = (ms / 1000).ceil().clamp(1, 3);
    final p = ((k * 1000 - ms) / 1000).clamp(0.0, 1.0);
    final inT = Curves.easeOutBack.transform((p / 0.22).clamp(0.0, 1.0));
    final outT = Curves.easeInCubic.transform(((p - 0.62) / 0.38).clamp(0.0, 1.0));
    final scale = (0.55 + 0.45 * inT) * (1 + 0.5 * outT);
    final opacity = (p / 0.12).clamp(0.0, 1.0) * (1 - outT);
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.3 * (k == 1 ? 1 - outT : 1.0)),
      child: Center(
        child: Transform.scale(
          scale: scale,
          child: Opacity(opacity: opacity, child: Text('$k', style: Lux.display(110, color: Lux.goldLight))),
        ),
      ),
    );
  }

  Widget _introCard(Map<String, dynamic> st) {
    final endless = st['mode'] == 'endless';
    final notes = [for (final n in (st['notes'] as List? ?? const [])) n as String];
    final palette = [for (final c in (st['colors'] as List? ?? const [])) Map<String, dynamic>.from(c as Map)];
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => ColoredBox(
        color: Colors.black.withValues(alpha: 0.55 * t),
        child: Opacity(opacity: t, child: Transform.scale(scale: 0.95 + 0.05 * t, child: child)),
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: LuxCard(
            highlight: true,
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(Lux.upper(endless ? 'Sprint · 60 sn' : (st['title'] as String? ?? 'Renk–Kelime')),
                    textAlign: TextAlign.center, style: Lux.display(21, spacing: 1.2)),
                const SizedBox(height: 14),
                // The colours in play, each word written in its own ink: a calm preview.
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 12,
                  runSpacing: 6,
                  children: [
                    for (var i = 0; i < palette.length; i++)
                      Text(palette[i]['name'] as String,
                          style: TextStyle(
                              fontFamily: 'Jost', fontSize: 15, fontWeight: FontWeight.w700, color: _inks[i])),
                  ],
                ),
                const SizedBox(height: 14),
                for (final l in notes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 7, right: 10),
                          child: Container(
                              width: 5,
                              height: 5,
                              decoration: const BoxDecoration(color: Lux.gold, shape: BoxShape.circle)),
                        ),
                        Expanded(child: Text(l, style: Lux.ui(15.5, weight: FontWeight.w500))),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
                GoldButton('Başla', icon: Icons.play_arrow_rounded, onPressed: () {
                  HapticFeedback.selectionClick();
                  s.act({'start': true});
                }),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Sprint timer ring: gold arc of the remaining time, bordeaux in the last ten seconds.
class _Ring extends CustomPainter {
  final double fraction;
  final bool low;
  _Ring(this.fraction, {this.low = false});

  static final Paint _p = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 4;
    canvas.drawCircle(
        c,
        r,
        _p
          ..strokeWidth = 5
          ..color = const Color(0xFF0A2B21));
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), -math.pi / 2, 2 * math.pi * fraction, false,
        _p..color = low ? Lux.bordeauxLight : Lux.gold);
  }

  @override
  bool shouldRepaint(_Ring old) => old.fraction != fraction || old.low != low;
}
