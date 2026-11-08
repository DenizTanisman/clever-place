import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// Sözel ve Sosyal Zeka board. One item at a time on a calm Lux card: a section chip (Sözel / Sosyal
/// / Duygusal) with the item's kind, the prompt and four option buttons. After an answer, the picked
/// option turns green or red, the right one glows gold, and a "Neden?" panel explains the key.
/// Emotion-management items add a note that their key reflects EI research consensus. The player
/// moves on with "Devam"; there is no timer. A level is 10 items (9–10 right → 3 stars, 8 → 2,
/// 7 → 1, fewer: lost). In Karışık the top row shows the streak and the lives left. When a level
/// ends, the board lists the 10 items with their right answers. Rust owns content and scoring.
Widget verbalSocialView(BuildContext context, GameSession s) => VerbalSocialBoard(key: ObjectKey(s), session: s);

/// Shown under the "Neden?" text for emotion-management (STEM-style) items.
const kConsensusNote = 'Bu cevap duygusal zekâ araştırmalarındaki uzman görüşüne göre en etkili olanı.';

class VerbalSocialBoard extends StatefulWidget {
  final GameSession session;
  const VerbalSocialBoard({super.key, required this.session});

  @override
  State<VerbalSocialBoard> createState() => _VerbalSocialBoardState();
}

class _VerbalSocialBoardState extends State<VerbalSocialBoard> {
  final _scroll = ScrollController();
  String _key = '';
  /// False for a moment after a new item appears, so a double tap on "Devam" can't land on it.
  bool _armed = true;
  Timer? _arm;

  GameSession get s => widget.session;

  @override
  void dispose() {
    _arm?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _answer(int i) {
    if (s.state['phase'] != 'question' || s.finished) return;
    if (!_armed) return;
    final ok = s.act({'answer': i});
    if (!ok) return;
    final last = s.state['last'];
    if (last is Map && last['correct'] == true) {
      HapticFeedback.lightImpact();
    } else {
      HapticFeedback.mediumImpact();
    }
    // Bring the explanation into view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 420), curve: Curves.easeOutCubic);
      }
    });
  }

  void _next() {
    HapticFeedback.selectionClick();
    if (s.act({'next': true}) && _scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final st = s.state;
    final q = st['question'] is Map ? Map<String, dynamic>.from(st['question'] as Map) : null;
    final phase = st['phase'] as String? ?? 'question';
    final key = '${st['q_index']}|$phase';
    if (key != _key) {
      if (phase == 'question' && _key.isNotEmpty) {
        _armed = false;
        _arm?.cancel();
        _arm = Timer(const Duration(milliseconds: 300), () => _armed = true);
      }
      _key = key;
    }
    if (q == null) return const SizedBox.expand();
    if (phase == 'done' && st['mode'] != 'endless') return _review(st);
    final last = st['last'] is Map ? Map<String, dynamic>.from(st['last'] as Map) : null;
    final feedback = phase == 'feedback' || phase == 'done';
    final options = [for (final o in (q['options'] as List? ?? const [])) '$o'];
    return Column(
      children: [
        _progress(st),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            switchInCurve: Curves.easeOutCubic,
            transitionBuilder: (child, a) => FadeTransition(
              opacity: a,
              child: SlideTransition(position: Tween(begin: const Offset(0, 0.03), end: Offset.zero).animate(a), child: child),
            ),
            child: SingleChildScrollView(
              key: ValueKey('item${st['q_index']}'),
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _promptCard(q),
                  const SizedBox(height: 14),
                  for (var i = 0; i < options.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 9),
                      child: _Option(
                        label: options[i],
                        state: _optState(i, last, feedback),
                        onTap: () => _answer(i),
                      ),
                    ),
                  if (feedback && last != null) ...[
                    const SizedBox(height: 6),
                    _whyPanel(last, consensus: q['consensus'] == true),
                    const SizedBox(height: 14),
                    if (phase == 'feedback')
                      Center(
                        child: GoldButton(_isLast(st) ? 'Sonucu gör' : 'Devam',
                            icon: Icons.arrow_forward_rounded, onPressed: _next),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  bool _isLast(Map<String, dynamic> st) {
    final n = (st['q_count'] as num?)?.toInt() ?? 0;
    final idx = (st['q_index'] as num?)?.toInt() ?? 0;
    if (st['mode'] == 'endless') return ((st['lives'] as num?)?.toInt() ?? 1) <= 0;
    return n > 0 && idx >= n - 1;
  }

  // ------------------------------------------------------------------ top row

  Widget _progress(Map<String, dynamic> st) {
    final answers = [for (final a in (st['answers'] as List? ?? const [])) a == true];
    if (st['mode'] == 'endless') {
      final lives = (st['lives'] as num?)?.toInt() ?? 0;
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
        child: Row(
          children: [
            Text('Seri', style: Lux.ui(13, color: Lux.muted)),
            const SizedBox(width: 6),
            Text('${st['streak'] ?? 0}', style: Lux.numeral(22)),
            const SizedBox(width: 14),
            Text('En iyi ${st['best_streak'] ?? 0}', style: Lux.ui(13, color: Lux.muted)),
            const Spacer(),
            for (var i = 0; i < 3; i++)
              Padding(
                padding: const EdgeInsets.only(left: 3),
                child: Icon(i < lives ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                    size: 18, color: i < lives ? Lux.bordeauxLight : Lux.muted.withValues(alpha: 0.5)),
              ),
          ],
        ),
      );
    }
    final n = (st['q_count'] as num?)?.toInt() ?? 10;
    final idx = (st['q_index'] as num?)?.toInt() ?? 0;
    final right = answers.where((a) => a).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
      child: Row(
        children: [
          for (var i = 0; i < n; i++)
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                height: 6,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  color: i < answers.length
                      ? (answers[i] ? Lux.good : Lux.bordeauxLight)
                      : (i == idx ? Lux.gold.withValues(alpha: 0.7) : Lux.lineFaint),
                ),
              ),
            ),
          const SizedBox(width: 10),
          Text('$right doğru', style: Lux.ui(13, color: Lux.muted)),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ item

  static Color sectionColor(String? section) => switch (section) {
        'sosyal' => const Color(0xFF8FC3F0),
        'duygusal' => Lux.bordeauxLight,
        _ => Lux.goldLight,
      };

  Widget _promptCard(Map<String, dynamic> q) {
    final color = sectionColor(q['section'] as String?);
    return LuxCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: color.withValues(alpha: 0.75)),
                  color: color.withValues(alpha: 0.1),
                ),
                child: Text('${q['section_label'] ?? ''}', style: Lux.ui(12, color: color, weight: FontWeight.w700, spacing: 0.6)),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text('${q['subtype_label'] ?? ''}',
                    overflow: TextOverflow.ellipsis, style: Lux.ui(12, color: Lux.muted, weight: FontWeight.w500)),
              ),
              const Spacer(),
              if (q['difficulty'] == 'zor') Text('Zor', style: Lux.ui(11, color: Lux.muted.withValues(alpha: 0.8))),
            ],
          ),
          const SizedBox(height: 12),
          Text('${q['prompt'] ?? ''}', style: Lux.ui(17, color: Lux.ink).copyWith(height: 1.42)),
        ],
      ),
    );
  }

  /// 0 idle · 1 the right answer (gold) · 2 picked and right (green) · 3 picked and wrong (red) · 4 dimmed.
  int _optState(int i, Map<String, dynamic>? last, bool feedback) {
    if (!feedback || last == null) return 0;
    final given = (last['given'] as num?)?.toInt();
    final answer = (last['answer'] as num?)?.toInt();
    if (i == given && i == answer) return 2;
    if (i == given) return 3;
    if (i == answer) return 1;
    return 4;
  }

  Widget _whyPanel(Map<String, dynamic> last, {required bool consensus}) {
    final right = last['correct'] == true;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 13, 16, 15),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: const Color(0x33000000),
        border: Border.all(color: (right ? Lux.good : Lux.bordeauxLight).withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(right ? Icons.check_circle_rounded : Icons.cancel_rounded, size: 20, color: right ? Lux.good : Lux.bordeauxLight),
              const SizedBox(width: 8),
              Text(right ? 'Doğru' : 'Olmadı', style: Lux.ui(16, color: right ? Lux.good : Lux.bordeauxLight, weight: FontWeight.w700)),
              const Spacer(),
              Text('Neden?', style: Lux.display(20, color: Lux.goldLight, italic: true)),
            ],
          ),
          const SizedBox(height: 8),
          Text('${last['why'] ?? ''}', style: Lux.ui(15, color: Lux.ink).copyWith(height: 1.4)),
          if (consensus) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 1),
                  child: Icon(Icons.info_outline_rounded, size: 15, color: Lux.muted),
                ),
                const SizedBox(width: 6),
                Expanded(child: Text(kConsensusNote, style: Lux.ui(12.5, color: Lux.muted).copyWith(height: 1.35))),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ done: review

  Widget _review(Map<String, dynamic> st) {
    final rows = [for (final r in (st['review'] as List? ?? const [])) Map<String, dynamic>.from(r as Map)];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 120),
      children: [
        if (st['summary'] is String)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(st['summary'] as String, textAlign: TextAlign.center, style: Lux.ui(14, color: Lux.muted)),
          ),
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: LuxCard(
              padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
              radius: 14,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(r['correct'] == true ? Icons.check_rounded : Icons.close_rounded,
                      size: 20, color: r['correct'] == true ? Lux.good : Lux.bordeauxLight),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${r['section_label']}', style: Lux.ui(11, color: Lux.muted, weight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text('${r['prompt']}'.split('\n').last,
                            maxLines: 2, overflow: TextOverflow.ellipsis, style: Lux.ui(13.5, color: Lux.ink)),
                        const SizedBox(height: 3),
                        Text('${r['answer_text']}', style: Lux.ui(13, color: Lux.goldLight, weight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _Option extends StatefulWidget {
  final String label;
  final int state;
  final VoidCallback onTap;
  const _Option({required this.label, required this.state, required this.onTap});

  @override
  State<_Option> createState() => _OptionState();
}

class _OptionState extends State<_Option> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 380));

  @override
  void didUpdateWidget(_Option old) {
    super.didUpdateWidget(old);
    if (old.state == 0 && widget.state != 0 && widget.state != 4) _a.forward(from: 0);
  }

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (Color border, Color fill, Color text) = switch (widget.state) {
      1 => (Lux.gold, const Color(0x33D4A94E), Lux.goldLight),
      2 => (Lux.good, const Color(0x332E8F5E), Colors.white),
      3 => (Lux.bordeauxLight, const Color(0x44A3203F), const Color(0xFFFFD6DF)),
      4 => (Lux.lineFaint, Colors.transparent, Lux.muted.withValues(alpha: 0.6)),
      _ => (Lux.gold.withValues(alpha: 0.45), const Color(0x22000000), Lux.ink),
    };
    return AnimatedBuilder(
      animation: _a,
      builder: (context, child) {
        final t = _a.value;
        // A wrong pick shakes once; the right answer pops.
        final shake = widget.state == 3 ? math.sin(t * 15) * 6 * (1 - t) : 0.0;
        final pop = widget.state == 1 || widget.state == 2 ? 1 + 0.035 * math.sin(math.pi * t) : 1.0;
        return Transform.translate(offset: Offset(shake, 0), child: Transform.scale(scale: pop, child: child));
      },
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: widget.state == 0 ? widget.onTap : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: fill,
              border: Border.all(color: border, width: widget.state == 0 || widget.state == 4 ? 1 : 1.8),
            ),
            child: Text(widget.label, style: Lux.ui(15.5, color: text, weight: FontWeight.w600).copyWith(height: 1.3)),
          ),
        ),
      ),
    );
  }
}
