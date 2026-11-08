import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';
import 'iq_figure.dart';
import 'iq_layout.dart';

/// IQ Soruları board: a calm question card (category chip, medium/hard hint, a quiet per-question
/// clock with no pressure), the question figure, then options as tappable cards (text or figure)
/// or a number pad for typed answers. After answering, the right option glows green, a wrong pick
/// turns bordeaux, and a "Neden?" panel explains the rule; "Devam" moves on. Level mode shows a
/// 20-step progress rail; Karışık mode shows the streak and three hearts.
///
/// Figures with a `"layout"` key are this game's text layouts ([IqLayout]); every other figure
/// belongs to the figural painter ([IqFigure]).
Widget iqView(BuildContext context, GameSession s) => _IqBoard(key: ObjectKey(s), session: s);

/// One figure, whichever painter owns it.
Widget iqFigure(Map<String, dynamic> json, double width, {bool compact = false}) =>
    IqLayout.handles(json) ? IqLayout(json, width: width, compact: compact) : IqFigure(json, size: width);

class _IqBoard extends StatefulWidget {
  final GameSession session;
  const _IqBoard({super.key, required this.session});

  @override
  State<_IqBoard> createState() => _IqBoardState();
}

class _IqBoardState extends State<_IqBoard> {
  GameSession get s => widget.session;
  final Stopwatch _watch = Stopwatch();
  Timer? _timer;
  String _qKey = '';
  String _typed = '';
  String _phase = '';

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _watch.isRunning) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _sync(Map<String, dynamic> st) {
    final q = st['question'] is Map ? st['question'] as Map : const {};
    final key = '${st['mode']}|${st['q_index']}|${q['prompt']}';
    if (key != _qKey) {
      _qKey = key;
      _typed = '';
      _watch
        ..reset()
        ..start();
    }
    final ph = st['phase'] as String? ?? '';
    if (ph != _phase) {
      final prev = _phase;
      _phase = ph;
      if (ph != 'question') _watch.stop();
      if (prev == 'question' && ph != 'question') {
        final last = st['last'];
        if (last is Map) last['correct'] == true ? HapticFeedback.lightImpact() : HapticFeedback.mediumImpact();
      }
    }
  }

  void _answer(int i) {
    if (s.state['phase'] != 'question' || s.finished) return;
    HapticFeedback.selectionClick();
    s.act({'answer': i});
  }

  void _submitTyped() {
    final v = int.tryParse(_typed);
    if (v == null || s.state['phase'] != 'question') return;
    HapticFeedback.selectionClick();
    s.act({'typed': v});
  }

  void _key(String k) {
    HapticFeedback.selectionClick();
    setState(() {
      if (k == '<') {
        if (_typed.isNotEmpty) _typed = _typed.substring(0, _typed.length - 1);
      } else if (_typed.length < 6) {
        _typed = _typed == '0' ? k : _typed + k;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final st = s.state;
    _sync(st);
    final q = st['question'] is Map ? Map<String, dynamic>.from(st['question'] as Map) : null;
    if (q == null) return const SizedBox.expand();
    final phase = st['phase'] as String? ?? 'question';
    final feedback = phase == 'feedback' || phase == 'done';
    final last = st['last'] is Map ? Map<String, dynamic>.from(st['last'] as Map) : null;
    final typed = q['typed'] == true;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth - 32;
      return Column(
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 6), child: _header(st)),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                switchInCurve: Curves.easeOutCubic,
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(position: Tween(begin: const Offset(0, 0.03), end: Offset.zero).animate(a), child: child),
                ),
                child: KeyedSubtree(
                  key: ValueKey(_qKey),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _questionCard(q, w),
                      const SizedBox(height: 14),
                      if (typed) _typedAnswer(feedback, last) else _options(q, w, feedback, last),
                      if (feedback && last != null) ...[const SizedBox(height: 14), _whyPanel(last, q)],
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (typed && !feedback) _numberPad(),
          if (phase == 'feedback')
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              child: SizedBox(
                width: double.infinity,
                child: Center(
                  child: GoldButton('Devam', icon: Icons.arrow_forward_rounded, onPressed: () {
                    HapticFeedback.selectionClick();
                    s.act({'next': true});
                  }),
                ),
              ),
            ),
        ],
      );
    });
  }

  // ---------------------------------------------------------------- header

  Widget _header(Map<String, dynamic> st) {
    if (st['mode'] == 'endless') {
      final lives = (st['lives'] as num?)?.toInt() ?? 0;
      final streak = (st['streak'] as num?)?.toInt() ?? 0;
      final best = (st['best_streak'] as num?)?.toInt() ?? 0;
      return Row(
        children: [
          Icon(Icons.local_fire_department_rounded, color: streak > 0 ? Lux.gold : Lux.muted, size: 22),
          const SizedBox(width: 4),
          Text('Seri $streak', style: Lux.ui(16, color: Lux.goldLight, weight: FontWeight.w700)),
          const SizedBox(width: 10),
          Text('En iyi $best', style: Lux.ui(13, color: Lux.muted)),
          const Spacer(),
          for (var i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.only(left: 2),
              child: Icon(i < lives ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  size: 20, color: i < lives ? Lux.bordeauxLight : Lux.muted.withValues(alpha: 0.5)),
            ),
          const SizedBox(width: 10),
          if (!s.finished)
            TextButton(
              onPressed: () => s.act({'finish': true}),
              style: TextButton.styleFrom(foregroundColor: Lux.goldLight, padding: const EdgeInsets.symmetric(horizontal: 8)),
              child: Text('Bitir', style: Lux.ui(14, color: Lux.goldLight, weight: FontWeight.w600)),
            ),
        ],
      );
    }
    final n = (st['q_count'] as num?)?.toInt() ?? 20;
    final idx = (st['q_index'] as num?)?.toInt() ?? 0;
    final answers = [for (final a in (st['answers'] as List? ?? const [])) a == true];
    final correct = answers.where((a) => a).length;
    return Row(
      children: [
        Expanded(
          child: Row(
            children: [
              for (var i = 0; i < n; i++)
                Expanded(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    height: i == idx && st['phase'] == 'question' ? 8 : 6,
                    margin: const EdgeInsets.symmetric(horizontal: 1.5),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      color: i < answers.length
                          ? (answers[i] ? Lux.good.withValues(alpha: 0.85) : Lux.bordeauxLight.withValues(alpha: 0.8))
                          : (i == idx ? Lux.gold.withValues(alpha: 0.7) : Lux.lineFaint),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Text('${(idx + 1).clamp(1, n)}/$n', style: Lux.ui(13, color: Lux.muted, weight: FontWeight.w600)),
        const SizedBox(width: 8),
        Icon(Icons.check_rounded, size: 16, color: Lux.good.withValues(alpha: 0.9)),
        Text('$correct', style: Lux.ui(13, color: Lux.good, weight: FontWeight.w600)),
      ],
    );
  }

  // ---------------------------------------------------------------- question

  String _clock() {
    final sec = _watch.elapsed.inSeconds;
    return '${sec ~/ 60}:${(sec % 60).toString().padLeft(2, '0')}';
  }

  Widget _questionCard(Map<String, dynamic> q, double w) {
    final fig = q['figure'] is Map ? Map<String, dynamic>.from(q['figure'] as Map) : null;
    final hard = q['hard'] == true;
    return LuxCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: Lux.gold.withValues(alpha: 0.10),
                  border: Border.all(color: Lux.gold.withValues(alpha: 0.55)),
                ),
                child: Text('${q['cat_name'] ?? ''}', style: Lux.ui(12.5, color: Lux.goldLight, weight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              Text(hard ? 'zor' : 'orta', style: Lux.ui(12, color: Lux.muted.withValues(alpha: 0.75))),
              const Spacer(),
              Icon(Icons.schedule_rounded, size: 14, color: Lux.muted.withValues(alpha: 0.6)),
              const SizedBox(width: 3),
              Text(_clock(),
                  style: Lux.ui(12, color: Lux.muted.withValues(alpha: 0.7)).copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ),
          const SizedBox(height: 12),
          Text('${q['prompt'] ?? ''}', style: Lux.ui(18, color: Lux.ink, weight: FontWeight.w500)),
          if (fig != null) ...[
            const SizedBox(height: 16),
            Center(child: iqFigure(fig, w - 32)),
          ],
        ],
      ),
    );
  }

  /// 0 idle · 1 the right answer (after answering) · 2 picked and wrong · 3 dimmed.
  int _optState(int i, bool feedback, Map<String, dynamic>? last) {
    if (!feedback || last == null) return 0;
    final given = (last['given'] as num?)?.toInt();
    final answer = (last['answer'] as num?)?.toInt();
    if (i == answer) return 1;
    if (i == given) return 2;
    return 3;
  }

  Widget _options(Map<String, dynamic> q, double w, bool feedback, Map<String, dynamic>? last) {
    final opts = [for (final o in (q['options'] as List? ?? const [])) Map<String, dynamic>.from(o as Map)];
    final figures = opts.any((o) => o['figure'] is Map);
    final long = opts.any((o) => '${o['text'] ?? ''}'.length > 9);
    if (long && !figures) {
      return Column(
        children: [
          for (var i = 0; i < opts.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _OptionCard(state: _optState(i, feedback, last), onTap: () => _answer(i), wide: true, child: _optionBody(opts[i], w, wide: true)),
            ),
        ],
      );
    }
    final cols = figures ? 2 : (opts.length == 5 ? 3 : 2);
    final cw = (w - 12.0 * (cols - 1)) / cols;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      alignment: WrapAlignment.center,
      children: [
        for (var i = 0; i < opts.length; i++)
          SizedBox(
            width: cw,
            height: figures ? cw * 0.78 : 66,
            child: _OptionCard(state: _optState(i, feedback, last), onTap: () => _answer(i), child: _optionBody(opts[i], cw - 20)),
          ),
      ],
    );
  }

  Widget _optionBody(Map<String, dynamic> o, double w, {bool wide = false}) {
    if (o['figure'] is Map) {
      return Center(child: iqFigure(Map<String, dynamic>.from(o['figure'] as Map), w, compact: true));
    }
    final t = '${o['text'] ?? ''}';
    final numeric = RegExp(r'^[\d−\-:,° ]+$').hasMatch(t);
    return Align(
      alignment: wide ? Alignment.centerLeft : Alignment.center,
      child: Text(
        t,
        textAlign: wide ? TextAlign.left : TextAlign.center,
        style: numeric && !wide ? Lux.numeral(26, color: Lux.ink) : Lux.ui(wide ? 16 : 18, color: Lux.ink, weight: FontWeight.w600),
      ),
    );
  }

  // ---------------------------------------------------------------- typed answers

  Widget _typedAnswer(bool feedback, Map<String, dynamic>? last) {
    final correct = last?['correct'] == true;
    final shown = feedback ? '${last?['typed_value'] ?? ''}' : _typed;
    final color = !feedback ? Lux.gold : (correct ? Lux.good : Lux.bordeauxLight);
    return Center(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 200,
        height: 64,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: color.withValues(alpha: 0.10),
          border: Border.all(color: color.withValues(alpha: 0.8), width: 1.5),
        ),
        child: Text(shown.isEmpty ? 'Cevabını yaz' : shown,
            style: shown.isEmpty ? Lux.ui(15, color: Lux.muted) : Lux.numeral(34, color: feedback ? color : Lux.goldLight)),
      ),
    );
  }

  Widget _numberPad() {
    Widget key(String k, {IconData? icon, VoidCallback? onTap, bool primary = false}) => Expanded(
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Material(
              color: primary ? Lux.gold.withValues(alpha: 0.22) : const Color(0x22000000),
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: onTap ?? () => _key(k),
                child: Container(
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Lux.gold.withValues(alpha: primary ? 0.9 : 0.35)),
                  ),
                  child: icon != null ? Icon(icon, color: Lux.goldLight) : Text(k, style: Lux.numeral(26, color: Lux.ink)),
                ),
              ),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        children: [
          for (final row in const [
            ['1', '2', '3'],
            ['4', '5', '6'],
            ['7', '8', '9'],
          ])
            Row(children: [for (final k in row) key(k)]),
          Row(children: [
            key('<', icon: Icons.backspace_outlined),
            key('0'),
            key('ok', icon: Icons.check_rounded, primary: true, onTap: _typed.isEmpty ? null : _submitTyped),
          ]),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- feedback

  Widget _whyPanel(Map<String, dynamic> last, Map<String, dynamic> q) {
    final correct = last['correct'] == true;
    final value = last['answer_value'];
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: (correct ? const Color(0xFF1F6B4A) : const Color(0xFF5A1626)).withValues(alpha: 0.35),
        border: Border.all(color: (correct ? Lux.good : Lux.bordeauxLight).withValues(alpha: 0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(correct ? Icons.check_circle_rounded : Icons.cancel_rounded, color: correct ? Lux.good : Lux.bordeauxLight, size: 22),
              const SizedBox(width: 8),
              Text(correct ? 'Doğru!' : (value != null ? 'Olmadı: doğrusu $value' : 'Olmadı'),
                  style: Lux.ui(17, color: correct ? Lux.good : Lux.bordeauxLight, weight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 10),
          Text('Neden?', style: Lux.ui(13, color: Lux.goldLight, weight: FontWeight.w700, spacing: 0.8)),
          const SizedBox(height: 4),
          Text('${last['why'] ?? ''}', style: Lux.ui(15.5, color: Lux.ink)),
        ],
      ),
    );
  }
}

class _OptionCard extends StatelessWidget {
  final int state;
  final VoidCallback onTap;
  final Widget child;
  final bool wide;
  const _OptionCard({required this.state, required this.onTap, required this.child, this.wide = false});

  @override
  Widget build(BuildContext context) {
    final (Color border, Color fill) = switch (state) {
      1 => (Lux.good, const Color(0x332E8F5E)),
      2 => (Lux.bordeauxLight, const Color(0x44A3203F)),
      3 => (Lux.lineFaint, Colors.transparent),
      _ => (Lux.gold.withValues(alpha: 0.4), const Color(0x22000000)),
    };
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 220),
      opacity: state == 3 ? 0.45 : 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: state == 0 ? onTap : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: EdgeInsets.symmetric(horizontal: wide ? 16 : 8, vertical: wide ? 14 : 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: fill,
              border: Border.all(color: border, width: state == 1 || state == 2 ? 1.8 : 1),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
