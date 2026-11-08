import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';
import 'scene_painter.dart';

/// Sahne Hafızası board: look at the scene while a gold ring counts the seconds down ("Hazırım"
/// ends the look early), then answer one question at a time — a 4-number picker for counts, a
/// list of options for the rest. Chained questions carry a "Zincir 2/3" badge. The first question
/// is the key: answering it wrong ends the level. After every answer the right option glows gold,
/// a wrong pick shakes in bordeaux; the next question follows after a short pause (tap to skip).
/// When the level ends the scene is shown again for review. Rust owns timing and scoring.
Widget sceneQuizView(BuildContext context, GameSession s) => _QuizBoard(key: ObjectKey(s), session: s);

class _QuizBoard extends StatefulWidget {
  final GameSession session;
  const _QuizBoard({super.key, required this.session});

  @override
  State<_QuizBoard> createState() => _QuizBoardState();
}

class _QuizBoardState extends State<_QuizBoard> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;

  String _phase = '';
  double _phaseAt = 0;
  int _shownSecond = -1;

  GameSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration e) {
    final dt = (e - _last).inMicroseconds / 1000.0;
    _last = e;
    final ph = s.state['phase'];
    if (!s.finished && (ph == 'show' || ph == 'feedback')) {
      s.tick(dt);
    } else if (_now - _phaseAt < 1.5) {
      setState(() {});
    }
  }

  void _sync(Map<String, dynamic> st) {
    final ph = st['phase'] as String? ?? 'intro';
    if (ph != _phase) {
      final prev = _phase;
      _phase = ph;
      _phaseAt = _now;
      if ((ph == 'feedback' || ph == 'done') && prev == 'question') {
        final last = st['last'];
        if (last is Map) last['correct'] == true ? HapticFeedback.lightImpact() : HapticFeedback.mediumImpact();
      }
      if (ph == 'done' && st['status'] == 'won') HapticFeedback.heavyImpact();
      if (ph == 'question' && prev == 'show') HapticFeedback.selectionClick();
    }
    if (ph == 'show') {
      final left = ((((st['show_ms'] as num?) ?? 0) - ((st['t_ms'] as num?) ?? 0)) / 1000).ceil();
      if (left != _shownSecond && left <= 3 && left >= 1) HapticFeedback.selectionClick();
      _shownSecond = left;
    }
  }

  void _answer(int i) {
    if (s.state['phase'] != 'question' || s.finished) return;
    // Guard against a "continue" tap landing on the next question's options just as the feedback
    // pause auto-advances.
    if (_now - _phaseAt < 0.35) return;
    HapticFeedback.selectionClick();
    s.act({'answer': i});
  }

  @override
  Widget build(BuildContext context) {
    final st = s.state;
    _sync(st);
    final phase = st['phase'] as String? ?? 'intro';
    return Stack(
      children: [
        Column(
          children: [
            _progress(st),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 280),
                switchInCurve: Curves.easeOutCubic,
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(position: Tween(begin: const Offset(0, 0.04), end: Offset.zero).animate(a), child: child),
                ),
                child: switch (phase) {
                  'show' => KeyedSubtree(key: const ValueKey('show'), child: _looking(st)),
                  'question' || 'feedback' => KeyedSubtree(key: ValueKey('q${st['q_index']}'), child: _question(st)),
                  'done' => KeyedSubtree(key: const ValueKey('done'), child: _review(st)),
                  _ => const SizedBox.expand(),
                },
              ),
            ),
          ],
        ),
        if (phase == 'intro') Positioned.fill(child: _introCard(st)),
      ],
    );
  }

  // ------------------------------------------------------------------ progress

  Widget _progress(Map<String, dynamic> st) {
    final n = (st['q_count'] as num?)?.toInt() ?? 0;
    final idx = (st['q_index'] as num?)?.toInt() ?? 0;
    final answers = [for (final a in (st['answers'] as List? ?? const [])) a == true];
    final chain = (st['chain_len'] as num?)?.toInt() ?? 0;
    final phase = st['phase'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
      child: Row(
        children: [
          for (var i = 0; i < n; i++) ...[
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: i == 0 ? 30 : 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(11),
                color: i < answers.length ? (answers[i] ? const Color(0xFF1F6B4A) : const Color(0xFF5A1626)) : Colors.transparent,
                border: Border.all(
                  color: i < answers.length
                      ? (answers[i] ? Lux.good : Lux.bordeauxLight)
                      : (i == idx && phase == 'question' ? Lux.goldLight : Lux.line),
                  width: i == idx && phase == 'question' ? 1.6 : 1,
                ),
              ),
              child: i == 0
                  ? Icon(Icons.key_rounded, size: 13, color: i < answers.length ? Colors.white : Lux.gold)
                  : Text('${i + 1}', style: Lux.ui(11, color: Lux.muted, weight: FontWeight.w600)),
            ),
            if (i < chain - 1) Container(width: 10, height: 2, color: Lux.gold.withValues(alpha: 0.6)) else const SizedBox(width: 8),
          ],
          const Spacer(),
          Text('${st['setting'] ?? ''}', style: Lux.ui(13, color: Lux.muted)),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ looking

  Widget _looking(Map<String, dynamic> st) {
    final scene = st['scene'] is Map ? Map<String, dynamic>.from(st['scene'] as Map) : null;
    final showMs = (st['show_ms'] as num?)?.toDouble() ?? 1;
    final t = (st['t_ms'] as num?)?.toDouble() ?? 0;
    final left = ((showMs - t) / 1000).clamp(0.0, 999.0);
    final frac = (1 - t / showMs).clamp(0.0, 1.0);
    return LayoutBuilder(builder: (context, box) {
      var w = box.maxWidth - 20;
      var h = w / SceneArt.aspect;
      final maxH = box.maxHeight - 150;
      if (h > maxH) {
        h = maxH;
        w = h * SceneArt.aspect;
      }
      return Column(
        children: [
          const Spacer(),
          Container(
            width: w,
            height: h,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Lux.gold.withValues(alpha: 0.55), width: 1.2),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 18, offset: const Offset(0, 8))],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(13),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (scene != null) SceneView(scene: scene, radius: 0),
                  Positioned(
                    right: 8,
                    bottom: 5,
                    child: Text('Sahne #${st['scene_no']}',
                        style: Lux.ui(10, color: Colors.white.withValues(alpha: 0.7))
                            .copyWith(shadows: const [Shadow(color: Color(0x99000000), blurRadius: 3)])),
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 18),
            child: Row(
              children: [
                SizedBox(
                  width: 64,
                  height: 64,
                  child: CustomPaint(
                    painter: _Ring(frac, urgent: left <= 3),
                    child: Center(
                      child: Text(left >= 10 ? '${left.ceil()}' : left.toStringAsFixed(1).replaceAll('.', ','),
                          style: Lux.numeral(22, color: left <= 3 ? Lux.bordeauxLight : Lux.goldLight)
                              .copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text('İyi bak: kimde ne var, kim nerede, kaç tane?', style: Lux.ui(14, color: Lux.muted)),
                ),
                GoldButton('Hazırım', onPressed: () {
                  HapticFeedback.selectionClick();
                  s.act({'ready': true});
                }),
              ],
            ),
          ),
        ],
      );
    });
  }

  // ------------------------------------------------------------------ question

  Widget _question(Map<String, dynamic> st) {
    final q = st['question'] is Map ? Map<String, dynamic>.from(st['question'] as Map) : null;
    if (q == null) return const SizedBox.expand();
    final idx = (st['q_index'] as num?)?.toInt() ?? 0;
    final chainStep = (q['chain_step'] as num?)?.toInt() ?? 0;
    final chain = (st['chain_len'] as num?)?.toInt() ?? 0;
    final options = [for (final o in (q['options'] as List? ?? const [])) '$o'];
    final numeric = q['numeric'] == true;
    final last = st['last'] is Map ? Map<String, dynamic>.from(st['last'] as Map) : null;
    final feedback = st['phase'] == 'feedback' || st['phase'] == 'done';
    final fbFrac =
        st['phase'] == 'feedback' ? (((st['fb_ms'] as num?) ?? 0) / ((st['feedback_ms'] as num?) ?? 2200)).clamp(0.0, 1.0).toDouble() : 0.0;
    final age = _now - _phaseAt;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: st['phase'] == 'feedback' ? () => s.act({'next': true}) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (idx == 0)
                  _badge(Icons.key_rounded, 'Kilit soru', Lux.gold)
                else
                  Text('Soru ${idx + 1}', style: Lux.ui(13, color: Lux.muted, weight: FontWeight.w600)),
                const SizedBox(width: 8),
                if (chainStep > 0) _badge(Icons.link_rounded, 'Zincir $chainStep/$chain', Lux.goldLight),
              ],
            ),
            const SizedBox(height: 14),
            Text(q['text'] as String? ?? '', style: Lux.display(26, color: Lux.ink)),
            if (q['note'] is String) ...[
              const SizedBox(height: 6),
              Text(q['note'] as String, style: Lux.ui(13, color: Lux.muted)),
            ],
            if (idx == 0 && !feedback) ...[
              const SizedBox(height: 8),
              Text('Bunu bilemezsen bölüm biter.', style: Lux.ui(12, color: Lux.bordeauxLight)),
            ],
            const Spacer(),
            if (numeric)
              Row(
                children: [
                  for (var i = 0; i < options.length; i++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        child: _Option(
                          label: options[i],
                          big: true,
                          state: _optState(i, last, feedback),
                          age: age,
                          onTap: () => _answer(i),
                        ),
                      ),
                    ),
                ],
              )
            else
              for (var i = 0; i < options.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _Option(label: options[i], state: _optState(i, last, feedback), age: age, onTap: () => _answer(i)),
                ),
            const SizedBox(height: 14),
            SizedBox(
              height: 74,
              child: st['phase'] != 'feedback'
                  ? null
                  : Column(children: [
                      Text(last?['correct'] == true ? 'Doğru!' : 'Olmadı — doğrusu altın çerçevede.',
                          textAlign: TextAlign.center,
                          style: Lux.ui(16, color: last?['correct'] == true ? Lux.good : Lux.bordeauxLight, weight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: fbFrac,
                          minHeight: 3,
                          backgroundColor: Lux.lineFaint,
                          valueColor: const AlwaysStoppedAnimation(Lux.gold),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text('Devam etmek için dokun', textAlign: TextAlign.center, style: Lux.ui(12, color: Lux.muted)),
                    ]),
            ),
          ],
        ),
      ),
    );
  }

  /// 0 idle · 1 correct answer (gold) · 2 picked & right (green) · 3 picked & wrong (bordeaux) · 4 dimmed.
  int _optState(int i, Map<String, dynamic>? last, bool feedback) {
    if (!feedback || last == null) return 0;
    final given = (last['given'] as num?)?.toInt();
    final answer = (last['answer'] as num?)?.toInt();
    if (i == given && i == answer) return 2;
    if (i == given) return 3;
    if (i == answer) return 1;
    return 4;
  }

  Widget _badge(IconData icon, String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.7)),
          color: color.withValues(alpha: 0.08),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(text, style: Lux.ui(12, color: color, weight: FontWeight.w600)),
          ],
        ),
      );

  // ------------------------------------------------------------------ done: review

  Widget _review(Map<String, dynamic> st) {
    final scene = st['scene'] is Map ? Map<String, dynamic>.from(st['scene'] as Map) : null;
    final lost = st['status'] == 'lost';
    final q = st['question'] is Map ? Map<String, dynamic>.from(st['question'] as Map) : null;
    final last = st['last'] is Map ? Map<String, dynamic>.from(st['last'] as Map) : null;
    String? correct;
    if (q != null && last != null) {
      final opts = q['options'] as List? ?? const [];
      final a = (last['answer'] as num?)?.toInt() ?? 0;
      if (a < opts.length) correct = '${opts[a]}';
    }
    return LayoutBuilder(builder: (context, box) {
      final w = math.min(box.maxWidth - 20, (box.maxHeight - 140) * SceneArt.aspect);
      return Column(
        children: [
          const SizedBox(height: 6),
          if (lost && q != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 10),
              child: Text('${q['text']}  →  $correct',
                  textAlign: TextAlign.center, style: Lux.ui(15, color: Lux.bordeauxLight, weight: FontWeight.w600)),
            ),
          if (scene != null)
            Container(
              width: w,
              height: w / SceneArt.aspect,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: (lost ? Lux.bordeauxLight : Lux.gold).withValues(alpha: 0.6), width: 1.2),
              ),
              child: SceneView(scene: scene, radius: 13),
            ),
          const SizedBox(height: 10),
          Text('Sahneye bir daha bak', style: Lux.ui(13, color: Lux.muted)),
        ],
      );
    });
  }

  // ------------------------------------------------------------------ intro

  Widget _introCard(Map<String, dynamic> st) {
    final secs = (((st['show_ms'] as num?) ?? 10000) / 1000);
    final n = (st['q_count'] as num?)?.toInt() ?? 3;
    final chain = (st['chain_len'] as num?)?.toInt() ?? 0;
    final secsText = secs == secs.roundToDouble() ? '${secs.round()}' : secs.toStringAsFixed(1).replaceAll('.', ',');
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.55),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: LuxCard(
            highlight: true,
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(Lux.upper('Sahne Hafızası'), style: Lux.display(22, spacing: 1.5)),
                const SizedBox(height: 14),
                Text('Bir sahne $secsText saniye görünecek. Sonra sahne kapanır ve $n soru gelir.',
                    textAlign: TextAlign.center, style: Lux.ui(16)),
                if (chain > 0) ...[
                  const SizedBox(height: 8),
                  Text('İlk $chain soru bir zincir: her biri bir öncekinin cevabını daraltır (kaç şapka → kaçı kırmızı…).',
                      textAlign: TextAlign.center, style: Lux.ui(14, color: Lux.goldLight)),
                ],
                const SizedBox(height: 10),
                Text('İlk soru kilit: yanlışsa bölüm biter ve sonraki bölüm açılmaz. Diğer sorular yıldızı belirler.',
                    textAlign: TextAlign.center, style: Lux.ui(13, color: Lux.muted)),
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
    );
  }
}

class _Option extends StatelessWidget {
  final String label;
  final bool big;
  final int state;
  final double age;
  final VoidCallback onTap;
  const _Option({required this.label, required this.state, required this.age, required this.onTap, this.big = false});

  @override
  Widget build(BuildContext context) {
    final (Color border, Color fill, Color text) = switch (state) {
      1 => (Lux.gold, const Color(0x33D4A94E), Lux.goldLight),
      2 => (Lux.good, const Color(0x332E8F5E), Colors.white),
      3 => (Lux.bordeauxLight, const Color(0x44A3203F), const Color(0xFFFFD6DF)),
      4 => (Lux.lineFaint, Colors.transparent, Lux.muted.withValues(alpha: 0.6)),
      _ => (Lux.gold.withValues(alpha: 0.45), const Color(0x22000000), Lux.ink),
    };
    // A wrong pick shakes once; the right answer pops.
    final shake = state == 3 ? math.sin(age * 38) * 7 * (1 - (age / 0.4).clamp(0.0, 1.0)) : 0.0;
    final pop = state == 1 || state == 2 ? 1 + 0.06 * math.sin(math.pi * (age / 0.3).clamp(0.0, 1.0)) : 1.0;
    return Transform.translate(
      offset: Offset(shake, 0),
      child: Transform.scale(
        scale: pop,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(big ? 22 : 16),
            onTap: state == 0 ? onTap : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: big ? 78 : null,
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: big ? 0 : 15),
              alignment: big ? Alignment.center : Alignment.centerLeft,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(big ? 22 : 16),
                color: fill,
                border: Border.all(color: border, width: state == 0 || state == 4 ? 1 : 1.8),
              ),
              child: Text(label, style: big ? Lux.numeral(34, color: text) : Lux.ui(17, color: text, weight: FontWeight.w600)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Count-down ring for the look phase.
class _Ring extends CustomPainter {
  final double frac;
  final bool urgent;
  _Ring(this.frac, {required this.urgent});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 3;
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = Lux.lineFaint);
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      -math.pi / 2,
      2 * math.pi * frac,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round
        ..color = urgent ? Lux.bordeauxLight : Lux.gold,
    );
  }

  @override
  bool shouldRepaint(_Ring old) => old.frac != frac || old.urgent != urgent;
}
