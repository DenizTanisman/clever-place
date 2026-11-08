import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// Görev Değiştirme board. The cue (a lit zone, a coloured frame, or nothing on cue-free levels)
/// tells which rule applies; the digit / digit+letter target appears after the cue–target interval;
/// two big buttons answer left / right and list what each side means under every rule.
///
/// Timing lives in Rust: the view ticks the core every frame, shows the cue and the target exactly
/// when the state says so (no fade-in on onsets, which would shorten the cue–target interval), and
/// only decorates the feedback (rim flash, shake, "doğrusu" line) after an answer.
Widget taskSwitchView(BuildContext context, GameSession s) => _TaskSwitchBoard(key: ObjectKey(s), session: s);

/// Our own jewel colours per rule.
const _ruleColors = {
  'parity': Color(0xFFE2B85A), // gold
  'magnitude': Color(0xFF6E9BF0), // sapphire
  'vowel': Color(0xFFB98AF0), // amethyst
  'case': Color(0xFFEA7090), // ruby
};

Color _ruleColor(String? key) => _ruleColors[key] ?? Lux.gold;

class _TaskSwitchBoard extends StatefulWidget {
  final GameSession session;
  const _TaskSwitchBoard({super.key, required this.session});

  @override
  State<_TaskSwitchBoard> createState() => _TaskSwitchBoardState();
}

class _TaskSwitchBoardState extends State<_TaskSwitchBoard> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;

  // The last target shown, kept (dimmed) through the feedback stage.
  Map<String, dynamic>? _shown;
  int? _shownRule;
  int _seenSerial = 0;
  double _fbAt = -10;
  bool _fbCorrect = true;
  int _lastCount = 0;
  double _doneAt = -1;

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

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1000.0;
    _lastTick = elapsed;
    final phase = s.state['phase'];
    if (!s.finished && (phase == 'countdown' || phase == 'run')) {
      s.tick(dt);
    } else if (_now - _fbAt < 0.6 || (_doneAt >= 0 && _now - _doneAt < 1.2)) {
      setState(() {});
    }
  }

  void _answer(String side) {
    final st = s.state;
    if (s.finished || st['phase'] != 'run' || st['stage'] != 'target') return;
    HapticFeedback.selectionClick();
    s.act({'answer': side});
  }

  void _sync(Map<String, dynamic> st, double now) {
    if (st['stage'] == 'target' && st['target'] is Map) {
      _shown = Map<String, dynamic>.from(st['target'] as Map);
      _shownRule = (st['active_rule'] as num?)?.toInt();
    } else if (st['stage'] == 'cue') {
      _shown = null;
    }
    final last = st['last'];
    if (last is Map) {
      final serial = (last['serial'] as num).toInt();
      if (serial != _seenSerial) {
        _seenSerial = serial;
        _fbAt = now;
        _fbCorrect = last['correct'] == true;
        _fbCorrect ? HapticFeedback.lightImpact() : HapticFeedback.mediumImpact();
      }
    }
    if (st['phase'] == 'countdown') {
      final k = (((st['countdown_ms'] as num?) ?? 0) / 1000).ceil();
      if (k != _lastCount && k >= 1 && k <= 3) HapticFeedback.selectionClick();
      _lastCount = k;
    }
    if (st['phase'] == 'done' && _doneAt < 0) {
      _doneAt = now;
      if (st['status'] == 'won') HapticFeedback.heavyImpact();
    }
  }

  List<Map<String, dynamic>> _rules(Map<String, dynamic> st) =>
      [for (final r in (st['rules'] as List? ?? const [])) Map<String, dynamic>.from(r as Map)];

  @override
  Widget build(BuildContext context) {
    final st = s.state;
    final now = _now;
    _sync(st, now);
    final phase = st['phase'] as String? ?? 'intro';
    final rules = _rules(st);
    return Stack(
      children: [
        Column(
          children: [
            _header(st),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                child: LayoutBuilder(builder: (context, box) => _board(st, rules, box.biggest, now)),
              ),
            ),
            _buttons(st, rules),
          ],
        ),
        if (phase == 'countdown') Positioned.fill(child: IgnorePointer(child: _Countdown(st))),
        if (phase == 'intro') Positioned.fill(child: _intro(st, rules)),
        if (phase == 'done') Positioned.fill(child: IgnorePointer(child: _final(st, now - _doneAt))),
      ],
    );
  }

  // ------------------------------------------------------------------ header

  Widget _header(Map<String, dynamic> st) {
    final endless = st['mode'] == 'endless';
    final correct = (st['correct'] as num?)?.toInt() ?? 0;
    final errors = (st['errors'] as num?)?.toInt() ?? 0;
    final cost = (st['switch_cost_ms'] as num?)?.toInt();
    final small = Lux.ui(12, color: Lux.muted);
    if (endless) {
      final rem = ((st['remaining_ms'] as num?) ?? 60000) / 1000;
      final secs = rem.ceil();
      final low = secs <= 10 && st['phase'] == 'run';
      return Padding(
        padding: const EdgeInsets.fromLTRB(22, 10, 22, 2),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('0:${secs.toString().padLeft(2, '0')}',
                    style: Lux.numeral(44, color: low ? Lux.bordeauxLight : Lux.goldLight)
                        .copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('Puan ${(st['score'] as num?)?.toInt() ?? 0}', style: Lux.ui(18, weight: FontWeight.w700)),
                      Text('Seviye ${st['sprint_stage'] ?? 1} · Doğru $correct · Hata $errors',
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            _bar(1 - rem / 60, low ? Lux.bordeauxLight : null),
          ],
        ),
      );
    }
    final trial = (st['trial'] as num?)?.toInt() ?? 0;
    final trials = (st['trials'] as num?)?.toInt() ?? 32;
    final done = correct + errors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 2),
      child: Column(
        children: [
          Row(
            children: [
              Text('Deneme ${math.min(trial + 1, trials)} / $trials', style: Lux.ui(15, weight: FontWeight.w700)),
              const SizedBox(width: 10),
              Expanded(
                  child: Text('Doğru $correct · Hata $errors',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: Lux.ui(14, color: Lux.goldLight))),
            ],
          ),
          const SizedBox(height: 6),
          _bar(done / trials, null),
          const SizedBox(height: 4),
          Row(
            children: [
              if (st['cue'] == 'none') Text('Sıra: ${st['pattern']}', style: small),
              const SizedBox(width: 10),
              Expanded(
                child: Text(cost == null ? 'Geçiş maliyeti –' : 'Geçiş maliyeti $cost ms',
                    maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.end, style: small),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bar(double v, Color? tint) => ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: SizedBox(
          height: 6,
          child: Stack(
            children: [
              const Positioned.fill(child: ColoredBox(color: Color(0xFF2A2015))),
              FractionallySizedBox(
                widthFactor: v.clamp(0.0, 1.0),
                child: DecoratedBox(
                    decoration:
                        tint == null ? const BoxDecoration(gradient: Lux.goldGradient) : BoxDecoration(color: tint)),
              ),
            ],
          ),
        ),
      );

  // ------------------------------------------------------------------ board

  /// Feedback strength 0..1 (fades over 450 ms) and a shake offset for errors.
  (double, double) _fb(double now) {
    final age = now - _fbAt;
    if (age < 0 || age > 0.45) return (0, 0);
    final k = 1 - age / 0.45;
    final shake = _fbCorrect ? 0.0 : math.sin(age * 55) * 9 * k;
    return (k * k, shake);
  }

  Widget _board(Map<String, dynamic> st, List<Map<String, dynamic>> rules, Size size, double now) {
    final cue = st['cue'] as String? ?? 'zone';
    final stage = st['stage'] as String?;
    final active = (st['active_rule'] as num?)?.toInt();
    final labels = st['labels'] == true;
    final lit = stage == 'cue' || stage == 'target';
    final fb = _fb(now);
    final showTarget = stage == 'target' || stage == 'feedback';
    final target = showTarget ? _shown : null;
    final last = st['last'] is Map ? Map<String, dynamic>.from(st['last'] as Map) : null;

    if (cue == 'zone') {
      final n = rules.length;
      const gap = 10.0;
      List<Rect> rects;
      if (n == 4) {
        final w = (size.width - gap) / 2, h = (size.height - gap) / 2;
        rects = [
          for (var i = 0; i < 4; i++) Rect.fromLTWH((i % 2) * (w + gap), (i ~/ 2) * (h + gap), w, h),
        ];
      } else {
        final h = (size.height - gap * (n - 1)) / n;
        rects = [for (var i = 0; i < n; i++) Rect.fromLTWH(0, i * (h + gap), size.width, h)];
      }
      return Stack(
        children: [
          for (var i = 0; i < n; i++)
            Positioned.fromRect(
              rect: rects[i],
              child: _frame(
                rule: rules[i],
                glow: lit && active == i,
                tintRest: labels,
                label: labels ? rules[i]['question'] as String : null,
                target: (target != null && _shownRule == i) ? target : null,
                feedback: stage == 'feedback' && _shownRule == i ? fb : (0.0, 0.0),
                last: stage == 'feedback' && _shownRule == i ? last : null,
                rules: rules,
                stage: stage,
              ),
            ),
        ],
      );
    }

    // Colour / cue-free: one central frame.
    final rule = (active != null && active < rules.length) ? rules[active] : null;
    final colourCue = cue == 'color';
    final side = math.min(size.width, size.height - (colourCue && labels ? 64 : 34));
    return Column(
      children: [
        if (colourCue && labels)
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 14,
            runSpacing: 4,
            children: [
              for (final r in rules)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(color: _ruleColor(r['key'] as String?), shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                  Text(r['question'] as String, style: Lux.ui(13, color: Lux.ink)),
                ]),
            ],
          )
        else
          SizedBox(
            height: 24,
            child: Center(
              child: Text(
                cue == 'none'
                    ? (stage == 'feedback' && last != null && last['correct'] != true
                        ? 'Bu deneme: ${rules[(last['rule'] as num).toInt()]['question']}'
                        : 'İpucu yok · sıra ${st['pattern']}')
                    : '',
                style:
                    Lux.ui(13, color: stage == 'feedback' && last?['correct'] != true ? Lux.bordeauxLight : Lux.muted),
              ),
            ),
          ),
        const SizedBox(height: 10),
        Expanded(
          child: Center(
            child: SizedBox(
              width: side,
              height: side * 0.9,
              child: _frame(
                rule: colourCue ? rule : null,
                glow: colourCue && lit && rule != null,
                tintRest: false,
                label: null,
                target: target,
                feedback: stage == 'feedback' ? fb : (0.0, 0.0),
                last: stage == 'feedback' ? last : null,
                rules: rules,
                stage: stage,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _frame({
    required Map<String, dynamic>? rule,
    required bool glow,
    required bool tintRest,
    required String? label,
    required Map<String, dynamic>? target,
    required (double, double) feedback,
    required Map<String, dynamic>? last,
    required List<Map<String, dynamic>> rules,
    required String? stage,
  }) {
    final c = rule == null ? Lux.gold : _ruleColor(rule['key'] as String?);
    final (fbK, shake) = feedback;
    final fbColor = _fbCorrect ? Lux.good : Lux.bordeauxLight;
    var rim = glow ? c : (tintRest ? c.withValues(alpha: 0.3) : Lux.gold.withValues(alpha: 0.32));
    if (fbK > 0) rim = Color.lerp(rim, fbColor, fbK)!;
    final bg = glow ? Color.lerp(const Color(0xFF08261D), c, 0.16)! : const Color(0xFF061F18);
    return LayoutBuilder(builder: (context, box) {
      final glyph = math.min(box.maxWidth * 0.3, box.maxHeight * 0.5);
      return Transform.translate(
        offset: Offset(shake, 0),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            color: bg,
            border: Border.all(color: rim, width: glow || fbK > 0 ? 2.6 : 1.2),
            boxShadow: [
              if (glow) BoxShadow(color: c.withValues(alpha: 0.35), blurRadius: 26),
              if (fbK > 0) BoxShadow(color: fbColor.withValues(alpha: 0.4 * fbK), blurRadius: 24),
              BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 12, offset: const Offset(0, 6)),
            ],
          ),
          child: Stack(
            children: [
              if (label != null)
                Positioned(
                  left: 14,
                  top: 10,
                  right: 14,
                  child: Text(label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Lux.ui(13, color: glow ? c : c.withValues(alpha: 0.75), weight: FontWeight.w600)),
                ),
              if (target != null)
                Center(
                  child: Opacity(
                    opacity: stage == 'feedback' ? 0.4 : 1,
                    child: _Glyph(target, size: glyph),
                  ),
                ),
              if (last != null && last['correct'] != true)
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 10,
                  child: Text(
                    last['timeout'] == true ? 'Geç kaldın' : 'Doğrusu: ${_expectedLabel(last, rules)}',
                    textAlign: TextAlign.center,
                    style: Lux.ui(15, color: Lux.bordeauxLight, weight: FontWeight.w600),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }

  String _expectedLabel(Map<String, dynamic> last, List<Map<String, dynamic>> rules) {
    final ri = (last['rule'] as num?)?.toInt();
    if (ri == null || ri >= rules.length) return '';
    final r = rules[ri];
    return '${r[last['expected'] == 'left' ? 'left' : 'right']}';
  }

  // ------------------------------------------------------------------ buttons

  Widget _buttons(Map<String, dynamic> st, List<Map<String, dynamic>> rules) {
    final stage = st['stage'] as String?;
    final active = (st['active_rule'] as num?)?.toInt();
    // Highlight the active rule's meaning only when the cue already shows it openly.
    final hi = st['labels'] == true && st['cue'] != 'none' && (stage == 'cue' || stage == 'target') ? active : null;
    final enabled = st['phase'] == 'run' && stage == 'target';
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 18),
      child: Row(
        children: [
          for (final side in const ['left', 'right'])
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: _AnswerButton(
                  lines: [
                    for (var i = 0; i < rules.length; i++)
                      (rules[i][side] as String, _ruleColor(rules[i]['key'] as String?), hi == null ? null : hi == i),
                  ],
                  arrow: side == 'left' ? Icons.west_rounded : Icons.east_rounded,
                  enabled: enabled,
                  onDown: () => _answer(side),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ overlays

  Widget _intro(Map<String, dynamic> st, List<Map<String, dynamic>> rules) {
    final cue = st['cue'];
    final endless = st['mode'] == 'endless';
    final cueText = switch (cue) {
      'zone' => rules.length == 4
          ? 'Hedef hangi köşede çıkarsa o köşenin kuralı geçerli.'
          : 'Hedef hangi bölgede çıkarsa o bölgenin kuralı geçerli${rules.length == 2 ? ' (üst / alt)' : ' (üst / orta / alt)'}.',
      'color' => 'Hedeften hemen önce çerçeve kuralın rengini alır.',
      _ => 'İpucu yok. Kurallar ikişer deneme sırayla gelir (${st['pattern']}); sırayı kendin takip et.',
    };
    final zoneNames = rules.length == 4
        ? const ['Sol üst', 'Sağ üst', 'Sol alt', 'Sağ alt']
        : rules.length == 3
            ? const ['Üst', 'Orta', 'Alt']
            : const ['Üst', 'Alt'];
    return _CardOverlay(
      heading: endless ? 'Sprint · 60 saniye' : (st['title'] as String? ?? 'Görev Değiştirme'),
      button: 'Başla',
      onPressed: () {
        HapticFeedback.selectionClick();
        s.act({'start': true});
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < rules.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(color: _ruleColor(rules[i]['key'] as String?), shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text.rich(TextSpan(children: [
                      if (cue == 'zone') TextSpan(text: '${zoneNames[i]}: ', style: Lux.ui(14, color: Lux.muted)),
                      TextSpan(text: '${rules[i]['question']}  ', style: Lux.ui(15, weight: FontWeight.w600)),
                      TextSpan(
                          text: '← ${rules[i]['left']} · ${rules[i]['right']} →',
                          style: Lux.ui(14, color: Lux.goldLight)),
                    ])),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Text(cueText, textAlign: TextAlign.center, style: Lux.ui(15)),
          if (cue == 'zone' && st['labels'] != true) ...[
            const SizedBox(height: 6),
            Text('Bölge adları oyunda yazmayacak: şimdi ezberle.',
                textAlign: TextAlign.center, style: Lux.ui(14, color: Lux.bordeauxLight)),
          ],
          const SizedBox(height: 8),
          Text(
            endless
                ? 'Puan = doğru − hata. Her 8 doğruda yeni kural ya da daha kısa hazırlık.'
                : '${st['trials']} deneme · 3★: %90 doğruluk ve düşük geçiş maliyeti · %75 altı kaybettirir.',
            textAlign: TextAlign.center,
            style: Lux.ui(13, color: Lux.muted),
          ),
        ],
      ),
    );
  }

  Widget _final(Map<String, dynamic> st, double t) {
    final acc = (((st['accuracy'] as num?) ?? 0) * 100).round();
    final cost = (st['switch_cost_ms'] as num?)?.toInt();
    final rep = (st['rt_repeat_ms'] as num?)?.toInt();
    final sw = (st['rt_switch_ms'] as num?)?.toInt();
    final appear = Curves.easeOutBack.transform((t / 0.35).clamp(0.0, 1.0));
    final won = st['status'] == 'won' || st['mode'] == 'endless';
    return Center(
      child: Opacity(
        opacity: (t / 0.2).clamp(0.0, 1.0),
        child: Transform.scale(
          scale: 0.85 + 0.15 * appear,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              color: const Color(0xEE062A21),
              border: Border.all(color: (won ? Lux.gold : Lux.bordeauxLight).withValues(alpha: 0.8), width: 1.2),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(Lux.upper('Geçiş maliyeti'),
                    style: Lux.ui(12, color: Lux.gold, weight: FontWeight.w600, spacing: 2.2)),
                const SizedBox(height: 4),
                FoilText(cost == null ? '–' : '$cost ms', style: Lux.numeral(46)),
                const SizedBox(height: 6),
                Text('Tekrar ${rep ?? '–'} ms · Geçiş ${sw ?? '–'} ms', style: Lux.ui(14)),
                Text('Doğruluk %$acc', style: Lux.ui(14, color: Lux.muted)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Digit (+ letter) target, large and crisp, no animation.
class _Glyph extends StatelessWidget {
  final Map<String, dynamic> target;
  final double size;
  const _Glyph(this.target, {required this.size});

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontFamily: 'Jost',
      fontSize: size,
      fontWeight: FontWeight.w600,
      color: Lux.ink,
      height: 1,
      fontFeatures: const [FontFeature.liningFigures()],
    );
    final digit = '${target['digit']}';
    final letter = target['letter'] as String?;
    final text = letter == null ? digit : (target['letter_first'] == true ? '$letter$digit' : '$digit$letter');
    return Text(text, style: style, textHeightBehavior: const TextHeightBehavior(applyHeightToFirstAscent: false));
  }
}

class _AnswerButton extends StatefulWidget {
  /// (meaning, rule colour, highlighted: null = neutral / true / false).
  final List<(String, Color, bool?)> lines;
  final IconData arrow;
  final bool enabled;
  final VoidCallback onDown;
  const _AnswerButton({required this.lines, required this.arrow, required this.enabled, required this.onDown});

  @override
  State<_AnswerButton> createState() => _AnswerButtonState();
}

class _AnswerButtonState extends State<_AnswerButton> with SingleTickerProviderStateMixin {
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 60),
    reverseDuration: const Duration(milliseconds: 180),
  );

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.lines.length;
    final fs = n >= 4 ? 15.0 : (n == 3 ? 17.0 : 20.0);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) {
        // The answer goes out first; the press animation only follows it.
        widget.onDown();
        _press.forward();
      },
      onTapUp: (_) => _press.reverse(),
      onTapCancel: () => _press.reverse(),
      child: AnimatedBuilder(
        animation: _press,
        builder: (context, child) => Transform.scale(scale: 1 - 0.04 * _press.value, child: child),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 120),
          opacity: widget.enabled ? 1 : 0.62,
          child: Container(
            height: n >= 4 ? 150 : 132,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1E1710), Color(0xFF120D08)],
              ),
              border: Border.all(color: Lux.gold.withValues(alpha: widget.enabled ? 0.7 : 0.35), width: 1.4),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 12, offset: const Offset(0, 6))
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(widget.arrow, color: Lux.goldLight.withValues(alpha: 0.7), size: 20),
                const SizedBox(height: 4),
                for (final (text, color, hi) in widget.lines)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1.5),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                              color: color.withValues(alpha: hi == false ? 0.35 : 1), shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 7),
                        Flexible(
                          child: Text(
                            text,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Lux.ui(
                              hi == true ? fs + 2 : fs,
                              color: hi == false ? Lux.muted.withValues(alpha: 0.6) : (hi == true ? color : Lux.ink),
                              weight: hi == true ? FontWeight.w700 : FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Calm intro card over a dimmed board.
class _CardOverlay extends StatelessWidget {
  final String heading;
  final String button;
  final VoidCallback onPressed;
  final Widget child;
  const _CardOverlay({required this.heading, required this.button, required this.onPressed, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      builder: (context, t, c) => ColoredBox(
        color: Colors.black.withValues(alpha: 0.55 * t),
        child: Opacity(opacity: t, child: Transform.scale(scale: 0.95 + 0.05 * t, child: c)),
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: LuxCard(
            highlight: true,
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(Lux.upper(heading), textAlign: TextAlign.center, style: Lux.display(21, spacing: 1.4)),
                const SizedBox(height: 14),
                child,
                const SizedBox(height: 18),
                GoldButton(button, icon: Icons.play_arrow_rounded, onPressed: onPressed),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 3-2-1 countdown with a sweeping gold ring.
class _Countdown extends StatelessWidget {
  final Map<String, dynamic> st;
  const _Countdown(this.st);

  @override
  Widget build(BuildContext context) {
    final ms = (st['countdown_ms'] as num?)?.toDouble() ?? 0;
    final k = (ms / 1000).ceil().clamp(1, 3);
    final p = ((k * 1000 - ms) / 1000).clamp(0.0, 1.0);
    final inT = Curves.easeOutBack.transform((p / 0.22).clamp(0.0, 1.0));
    final outT = Curves.easeInCubic.transform(((p - 0.62) / 0.38).clamp(0.0, 1.0));
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.35 * (k == 1 ? 1 - outT : 1.0)),
      child: Center(
        child: CustomPaint(
          painter: _CountRing(p),
          child: SizedBox(
            width: 220,
            height: 220,
            child: Center(
              child: Transform.scale(
                scale: (0.55 + 0.45 * inT) * (1 + 0.5 * outT),
                child: Opacity(
                  opacity: (p / 0.12).clamp(0.0, 1.0) * (1 - outT),
                  child: Text('$k', style: Lux.display(110, color: Lux.goldLight)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

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
    canvas.drawCircle(
        c,
        r,
        _paint
          ..strokeWidth = 1.2
          ..color = Lux.gold.withValues(alpha: 0.18 * fade));
    canvas.drawArc(
        Rect.fromCircle(center: c, radius: r),
        -math.pi / 2,
        2 * math.pi * Curves.easeInOut.transform(p),
        false,
        _paint
          ..strokeWidth = 2.4
          ..color = Lux.goldLight.withValues(alpha: 0.75 * fade));
  }

  @override
  bool shouldRepaint(_CountRing old) => old.p != p;
}
