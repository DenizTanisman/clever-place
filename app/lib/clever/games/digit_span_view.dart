import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// Sayı Dizisi board: trial rail, a stage where the digits appear one by one as big glowing gold
/// numerals, answer slots, and a big keypad at thumb height. Timing, sequences and checking live in
/// Rust; the view only renders the core's clock (`show.t_ms`) and forwards key presses.
///
/// Motion: each symbol blooms in with a soft halo and a small springy pulse, then fades before the
/// next slot (envelope derived from the core's clock, so presentation timing is exact). Dots under
/// the stage count the sequence. Typed symbols pop into their slots; keys sink on touch. After a
/// trial the slots turn green or bordeaux position by position and the correct order is shown.
Widget digitSpanView(BuildContext context, GameSession s) => _DigitSpanBoard(key: ObjectKey(s), session: s);

class _DigitSpanBoard extends StatefulWidget {
  final GameSession session;
  const _DigitSpanBoard({super.key, required this.session});

  @override
  State<_DigitSpanBoard> createState() => _DigitSpanBoardState();
}

class _DigitSpanBoardState extends State<_DigitSpanBoard> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;

  String? _lastSymbol;
  int _seenSerial = 0;
  double _fbAt = -10;
  int _pressSerial = 0;

  GameSession get s => widget.session;

  static const _timed = {'countdown', 'ready', 'show', 'distract', 'feedback'};

  @override
  void initState() {
    super.initState();
    final last = s.state['last'];
    if (last is Map) _seenSerial = (last['serial'] as num).toInt();
    s.addListener(_onSession);
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    s.removeListener(_onSession);
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1000.0;
    _lastTick = elapsed;
    final phase = s.state['phase'] as String? ?? 'intro';
    if (!s.finished && _timed.contains(phase)) {
      s.tick(dt);
    } else if (_now - _fbAt < 1.2) {
      setState(() {});
    }
  }

  void _onSession() {
    final last = s.state['last'];
    if (last is Map) {
      final serial = (last['serial'] as num).toInt();
      if (serial != _seenSerial) {
        _seenSerial = serial;
        _fbAt = _now;
        if (last['correct'] == true) {
          HapticFeedback.lightImpact();
        } else {
          HapticFeedback.mediumImpact();
        }
      }
    }
  }

  List<String> _strings(Object? v) => v is List ? v.map((e) => e.toString()).toList() : const [];

  void _key(String k) {
    final st = s.state;
    if (st['phase'] != 'recall') return;
    final need = (st['need'] as num?)?.toInt() ?? 0;
    if (_strings(st['input']).length >= need) return;
    HapticFeedback.selectionClick();
    _pressSerial++;
    s.act({'key': k});
  }

  void _back() {
    if (s.state['phase'] != 'recall' || _strings(s.state['input']).isEmpty) return;
    HapticFeedback.selectionClick();
    s.act({'back': true});
  }

  void _submit() {
    final st = s.state;
    if (st['phase'] != 'recall') return;
    final need = (st['need'] as num?)?.toInt() ?? 0;
    if (_strings(st['input']).length != need) return;
    s.act({'submit': true});
  }

  @override
  Widget build(BuildContext context) {
    final st = s.state;
    final phase = st['phase'] as String? ?? 'intro';
    final letters = st['variant'] == 'letter_number';
    return Stack(
      children: [
        Column(
          children: [
            _header(st),
            Expanded(child: _stage(st, phase)),
            if (phase == 'distract') _judgeButtons() else _keypad(st, letters, phase == 'recall' && !s.finished),
          ],
        ),
        if (phase == 'intro') Positioned.fill(child: _introCard(st)),
        if (phase == 'countdown') Positioned.fill(child: IgnorePointer(child: _countdown(st))),
      ],
    );
  }

  // ------------------------------------------------------------------ header

  Widget _header(Map<String, dynamic> st) {
    final endless = st['mode'] == 'endless';
    final results = (st['results'] as List?)?.cast<bool>() ?? const <bool>[];
    final trials = (st['trials'] as num?)?.toInt();
    final trial = (st['trial'] as num?)?.toInt() ?? 0;
    final span = (st['span'] as num?)?.toInt() ?? 0;
    final unit = st['variant'] == 'letter_number' ? 'simge' : 'rakam';
    final title = endless ? '${st['variant_label']} dizi' : 'Deneme ${math.min(trial + 1, trials ?? 1)} / $trials';
    final sub = endless
        ? 'Uzunluk $span${st['forward_span'] != null ? ' · İleri sonucun ${st['forward_span']}' : ''}'
        : '$span $unit · ${st['instruction']}';
    final slots = endless ? results.length + 1 : (trials ?? 0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Lux.ui(18, weight: FontWeight.w700))),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < slots; i++)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: _TrialDot(state: i < results.length ? (results[i] ? 1 : 2) : (i == results.length ? 3 : 0)),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(sub, maxLines: 2, style: Lux.ui(13.5, color: Lux.muted)),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ stage

  Widget _stage(Map<String, dynamic> st, String phase) {
    return LayoutBuilder(builder: (context, box) {
      final big = (math.min(box.maxHeight * 0.5, box.maxWidth * 0.55)).clamp(80.0, 210.0);
      Widget child;
      switch (phase) {
        case 'show':
          child = _showStage(st, big);
        case 'distract':
          child = _distractStage(st);
        case 'recall':
          child = _recallStage(st);
        case 'feedback':
          child = _feedbackStage(st);
        case 'ready':
          child = Text('Hazır', style: Lux.display(28, color: Lux.muted));
        default:
          child = _restingStage(st, big);
      }
      return Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Center(child: child));
    });
  }

  Widget _restingStage(Map<String, dynamic> st, double big) {
    final last = st['last'] is Map ? Map<String, dynamic>.from(st['last'] as Map) : null;
    if (s.finished && last != null) return _feedbackStage(st);
    return Opacity(opacity: 0.25, child: FoilText('·', style: Lux.numeral(big * 0.6)));
  }

  Widget _showStage(Map<String, dynamic> st, double big) {
    final show = Map<String, dynamic>.from(st['show'] as Map);
    final period = (st['period_ms'] as num).toDouble();
    final on = (st['on_ms'] as num).toDouble();
    final t = (show['t_ms'] as num).toDouble();
    final count = (show['count'] as num).toInt();
    final idx = (show['index'] as num).toInt();
    final sym = show['symbol'] as String?;
    if (sym != null) _lastSymbol = sym;
    final local = t - idx * period;
    double env;
    if (sym != null) {
      env = (local / 90).clamp(0.0, 1.0);
    } else {
      env = idx < count ? (1 - (local - on) / 140).clamp(0.0, 1.0) : (1 - (t - count * period + period - on) / 140).clamp(0.0, 1.0);
    }
    final pulse = Curves.easeOutBack.transform((local / 220).clamp(0.0, 1.0));
    final scale = 0.8 + 0.2 * pulse;
    final halo = env * (1 - 0.45 * (local / on).clamp(0.0, 1.0));
    final shown = _lastSymbol ?? '';
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: big * 1.5,
          height: big * 1.35,
          child: CustomPaint(
            painter: _HaloPainter(halo),
            child: Center(
              child: Opacity(
                opacity: env,
                child: Transform.scale(
                  scale: scale,
                  child: FoilText(shown, style: Lux.numeral(big).copyWith(shadows: [
                    Shadow(color: Lux.gold.withValues(alpha: 0.55 * halo), blurRadius: 28),
                  ])),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        _countDots(count, idx, sym != null),
      ],
    );
  }

  Widget _countDots(int count, int idx, bool visible) {
    return Wrap(
      spacing: 7,
      runSpacing: 7,
      alignment: WrapAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: i == idx && visible ? 12 : 8,
            height: i == idx && visible ? 12 : 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i < idx || (i == idx && visible) ? Lux.gold : Lux.line,
              boxShadow: [if (i == idx && visible) BoxShadow(color: Lux.gold.withValues(alpha: 0.6), blurRadius: 10)],
            ),
          ),
      ],
    );
  }

  Widget _distractStage(Map<String, dynamic> st) {
    final d = Map<String, dynamic>.from(st['distract'] as Map);
    final f = ((d['remaining_ms'] as num) / (d['limit_ms'] as num)).toDouble().clamp(0.0, 1.0);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(Lux.upper('Ara görev ${(d['index'] as num).toInt() + 1}/${d['count']}'),
            style: Lux.ui(12, color: Lux.gold, spacing: 2.2, weight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text('Bu işlem doğru mu? Diziyi aklında tut.', style: Lux.ui(15, color: Lux.muted)),
        const SizedBox(height: 18),
        TweenAnimationBuilder<double>(
          key: ValueKey('eq${d['index']}${d['text']}'),
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          builder: (context, v, child) =>
              Opacity(opacity: v, child: Transform.translate(offset: Offset(0, 12 * (1 - v)), child: child)),
          child: FittedBox(fit: BoxFit.scaleDown, child: FoilText(d['text'] as String, style: Lux.display(48, spacing: 1.5))),
        ),
        const SizedBox(height: 22),
        SizedBox(width: 220, child: _bar(f, f < 0.3 ? Lux.bordeauxLight : Lux.gold)),
      ],
    );
  }

  Widget _bar(double f, Color c) => ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: SizedBox(
          height: 5,
          child: Stack(children: [
            const Positioned.fill(child: ColoredBox(color: Color(0xFF16201A))),
            FractionallySizedBox(widthFactor: f, child: ColoredBox(color: c)),
          ]),
        ),
      );

  Widget _recallStage(Map<String, dynamic> st) {
    final need = (st['need'] as num).toInt();
    final input = _strings(st['input']);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(Lux.upper(st['variant_label'] as String? ?? ''),
            style: Lux.ui(12, color: Lux.gold, spacing: 2.4, weight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(st['instruction'] as String? ?? '', textAlign: TextAlign.center, style: Lux.ui(16, color: Lux.ink)),
        const SizedBox(height: 20),
        _slots(need, (i) => i < input.length ? input[i] : null, (i) => null, popIndex: input.length - 1),
        const SizedBox(height: 14),
        Text('${input.length} / $need', style: Lux.ui(13, color: Lux.muted)),
      ],
    );
  }

  /// One row of answer slots. [color] returns a verdict tint per slot (null = neutral).
  Widget _slots(int n, String? Function(int) value, Color? Function(int) color, {int popIndex = -1}) {
    return LayoutBuilder(builder: (context, box) {
      final w = ((box.maxWidth - (n - 1) * 6) / n).clamp(20.0, 46.0);
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < n; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            _slot(w, value(i), color(i), pop: i == popIndex),
          ],
        ],
      );
    });
  }

  Widget _slot(double w, String? v, Color? tint, {bool pop = false}) {
    final filled = v != null;
    final rim = tint ?? (filled ? Lux.gold.withValues(alpha: 0.8) : Lux.line);
    Widget text = Text(v ?? '', style: Lux.numeral(w * 0.72, color: tint == null ? Lux.goldLight : Lux.ink));
    if (pop && filled) {
      text = TweenAnimationBuilder<double>(
        key: ValueKey('pop$_pressSerial'),
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 180),
        builder: (context, t, child) =>
            Opacity(opacity: (t * 2.5).clamp(0.0, 1.0), child: Transform.scale(scale: 0.55 + 0.45 * Curves.easeOutBack.transform(t), child: child)),
        child: text,
      );
    }
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: w,
      height: w * 1.3,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(w * 0.22),
        color: tint != null ? tint.withValues(alpha: 0.16) : const Color(0xFF0A2219),
        border: Border.all(color: rim, width: filled ? 1.4 : 1),
        boxShadow: [if (filled && tint == null) BoxShadow(color: Lux.gold.withValues(alpha: 0.18), blurRadius: 10)],
      ),
      child: text,
    );
  }

  Widget _feedbackStage(Map<String, dynamic> st) {
    final last = st['last'] is Map ? Map<String, dynamic>.from(st['last'] as Map) : null;
    if (last == null) return const SizedBox();
    final ok = last['correct'] == true;
    final exp = _strings(last['expected']);
    final given = _strings(last['given']);
    final seq = _strings(last['sequence']);
    final t = _now - _fbAt;
    final shake = !ok && t < 0.35 ? math.sin(t * 50) * 8 * math.exp(-t * 9) : 0.0;
    final reordered = st['variant'] != 'forward';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (s.state['phase'] == 'feedback') s.act({'next': true});
      },
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TweenAnimationBuilder<double>(
            key: ValueKey('fb${last['serial']}'),
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 360),
            builder: (context, v, child) => Transform.scale(scale: 0.8 + 0.2 * Curves.easeOutBack.transform(v), child: child),
            child: Text(ok ? 'Doğru' : 'Olmadı', style: Lux.display(34, color: ok ? Lux.gold : Lux.bordeauxLight)),
          ),
          if (last['distract_ok'] == false) ...[
            const SizedBox(height: 4),
            Text('Ara görevde hata var', style: Lux.ui(13, color: Lux.bordeauxLight)),
          ],
          const SizedBox(height: 16),
          Transform.translate(
            offset: Offset(shake, 0),
            child: _slots(exp.length, (i) => i < given.length ? given[i] : '', (i) => i < given.length && given[i] == exp[i] ? Lux.good : Lux.bordeauxLight),
          ),
          if (!ok) ...[
            const SizedBox(height: 14),
            Text('Doğrusu', style: Lux.ui(12, color: Lux.muted, spacing: 1.5)),
            const SizedBox(height: 6),
            _slots(exp.length, (i) => exp[i], (i) => null),
          ],
          if (reordered) ...[
            const SizedBox(height: 12),
            Text('Gösterilen: ${seq.join(' ')}', style: Lux.ui(14, color: Lux.muted)),
          ],
          const SizedBox(height: 14),
          Text(s.finished ? '' : 'Devam için dokun', style: Lux.ui(12, color: Lux.muted.withValues(alpha: 0.7))),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ input

  Widget _keypad(Map<String, dynamic> st, bool letters, bool enabled) {
    final need = (st['need'] as num?)?.toInt() ?? 0;
    final full = _strings(st['input']).length == need && need > 0;
    final rows = <List<String>>[
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
    ];
    final keyH = letters ? 52.0 : 62.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 14),
      child: AnimatedOpacity(
        opacity: enabled ? 1 : 0.4,
        duration: const Duration(milliseconds: 200),
        child: IgnorePointer(
          ignoring: !enabled,
          child: Column(
            children: [
              if (letters)
                for (final r in [_letterRow(0), _letterRow(5)])
                  Row(children: [for (final k in r) Expanded(child: _Key(label: k, height: keyH, accent: true, onTap: () => _key(k)))]),
              for (final r in rows)
                Row(children: [for (final k in r) Expanded(child: _Key(label: k, height: keyH, onTap: () => _key(k)))]),
              Row(
                children: [
                  Expanded(child: _Key(label: '⌫', height: keyH, accent: true, onTap: _back)),
                  Expanded(
                    child: letters
                        ? _Key(label: '', height: keyH, onTap: () {}, blank: true)
                        : _Key(label: '0', height: keyH, onTap: () => _key('0')),
                  ),
                  Expanded(child: _Key(label: 'Tamam', height: keyH, primary: full, small: true, onTap: _submit)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static const _letters = ['A', 'B', 'D', 'E', 'K', 'L', 'M', 'R', 'S', 'T'];
  List<String> _letterRow(int from) => _letters.sublist(from, from + 5);

  Widget _judgeButtons() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
      child: Row(
        children: [
          Expanded(child: _Key(label: 'Yanlış', height: 76, accent: true, onTap: () => _judge(false))),
          Expanded(child: _Key(label: 'Doğru', height: 76, primary: true, onTap: () => _judge(true))),
        ],
      ),
    );
  }

  void _judge(bool v) {
    HapticFeedback.selectionClick();
    s.act({'judge': v});
  }

  // ------------------------------------------------------------------ overlays

  Widget _introCard(Map<String, dynamic> st) {
    final endless = st['mode'] == 'endless';
    final period = ((st['period_ms'] as num?)?.toDouble() ?? 1000) / 1000;
    final pace = period.toStringAsFixed(2).replaceAll('.', ',');
    final body = endless
        ? 'Önce ileri, sonra geri dizi. Her dizi saniyede bir rakam akar. Üst üste iki doğru diziyi bir uzatır, '
            'bir yanlış bir kısaltır. Aynı uzunlukta iki kez yanılınca o bölüm biter.\n\n'
            'Puan = 10 × ileri kapasiten + 15 × geri kapasiten.'
        : '${st['instruction']}.\n\nSimgeler tek tek gelir (her $pace sn\'de bir). Dizi bitince klavyeden yaz ve Tamam\'a bas.'
            '${(st['title'] as String? ?? '').contains('ara görev') ? '\n\nDizi ile cevap arasında kısa bir işlem sorusu var: cevapla ama diziyi bırakma.' : ''}';
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.55),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            builder: (context, t, child) => Opacity(opacity: t, child: Transform.scale(scale: 0.94 + 0.06 * t, child: child)),
            child: LuxCard(
              highlight: true,
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(Lux.upper(endless ? 'Kapasite testi' : (st['title'] as String? ?? '')),
                      textAlign: TextAlign.center, style: Lux.display(22, spacing: 1.5)),
                  const SizedBox(height: 14),
                  Text(body, textAlign: TextAlign.center, style: Lux.ui(16, weight: FontWeight.w500)),
                  if (!endless) ...[
                    const SizedBox(height: 10),
                    Text(st['goal'] as String? ?? '', textAlign: TextAlign.center, style: Lux.ui(14, color: Lux.muted)),
                  ],
                  const SizedBox(height: 18),
                  GoldButton('Başla', icon: Icons.play_arrow_rounded, onPressed: () {
                    HapticFeedback.selectionClick();
                    s.act({'start': true});
                  }),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _countdown(Map<String, dynamic> st) {
    final ms = (st['countdown_ms'] as num?)?.toDouble() ?? 0;
    final k = (ms / 1000).ceil().clamp(1, 3);
    final p = ((k * 1000 - ms) / 1000).clamp(0.0, 1.0);
    final inT = Curves.easeOutBack.transform((p / 0.22).clamp(0.0, 1.0));
    final outT = Curves.easeInCubic.transform(((p - 0.62) / 0.38).clamp(0.0, 1.0));
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.35 * (k == 1 ? 1 - outT : 1.0)),
      child: Center(
        child: Transform.scale(
          scale: (0.55 + 0.45 * inT) * (1 + 0.5 * outT),
          child: Opacity(
            opacity: ((p / 0.12).clamp(0.0, 1.0) * (1 - outT)).toDouble(),
            child: Text('$k', style: Lux.display(110, color: Lux.goldLight)),
          ),
        ),
      ),
    );
  }
}

/// Trial rail dot: 0 pending, 1 correct, 2 wrong, 3 current.
class _TrialDot extends StatelessWidget {
  final int state;
  const _TrialDot({required this.state});

  @override
  Widget build(BuildContext context) {
    final color = switch (state) { 1 => Lux.good, 2 => Lux.bordeauxLight, 3 => Lux.gold, _ => Lux.line };
    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      width: state == 3 ? 13 : 10,
      height: state == 3 ? 13 : 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: state == 0 || state == 3 ? Colors.transparent : color,
        border: Border.all(color: color, width: 1.6),
        boxShadow: [if (state == 3) BoxShadow(color: Lux.gold.withValues(alpha: 0.5), blurRadius: 8)],
      ),
    );
  }
}

/// Soft radial halo behind the shown digit.
class _HaloPainter extends CustomPainter {
  final double a;
  _HaloPainter(this.a);

  @override
  void paint(Canvas canvas, Size size) {
    if (a <= 0.01) return;
    final c = size.center(Offset.zero);
    final r = size.shortestSide * 0.48;
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(colors: [
          Lux.gold.withValues(alpha: 0.28 * a),
          Lux.gold.withValues(alpha: 0.08 * a),
          Lux.gold.withValues(alpha: 0),
        ], stops: const [0, 0.5, 1])
            .createShader(Rect.fromCircle(center: c, radius: r)),
    );
    canvas.drawCircle(c, r * 0.86, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = Lux.goldLight.withValues(alpha: 0.22 * a));
  }

  @override
  bool shouldRepaint(_HaloPainter old) => old.a != a;
}

/// Keypad key: sinks on touch-down and springs back; taps are never delayed by the animation.
class _Key extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final double height;
  final bool accent;
  final bool primary;
  final bool small;
  final bool blank;
  const _Key({
    required this.label,
    required this.onTap,
    this.height = 62,
    this.accent = false,
    this.primary = false,
    this.small = false,
    this.blank = false,
  });

  @override
  State<_Key> createState() => _KeyState();
}

class _KeyState extends State<_Key> with SingleTickerProviderStateMixin {
  late final AnimationController _press;

  @override
  void initState() {
    super.initState();
    _press = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 80),
      reverseDuration: const Duration(milliseconds: 170),
    );
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.blank) return SizedBox(height: widget.height + 8);
    final primary = widget.primary;
    final fg = primary ? const Color(0xFF1A1206) : (widget.accent ? Lux.gold : Lux.ink);
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
                boxShadow: [BoxShadow(color: Lux.goldLight.withValues(alpha: 0.25 * p), blurRadius: 14)],
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
            onTapDown: (_) => _press.forward(),
            onTapUp: (_) => _press.forward().whenComplete(() {
              if (mounted) _press.reverse();
            }),
            onTapCancel: () => _press.reverse(),
            onTap: widget.onTap,
            child: Ink(
              height: widget.height,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: primary
                    ? Lux.goldGradient
                    : const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFF13402F), Color(0xFF07261C)],
                      ),
                border: Border.all(color: primary ? Colors.transparent : Lux.line),
              ),
              child: Center(
                child: widget.label == '⌫'
                    ? Icon(Icons.backspace_outlined, color: fg, size: 24)
                    : Text(widget.label, style: Lux.ui(widget.small ? 19 : 28, color: fg, weight: FontWeight.w700)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
