import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../i18n/lang.dart';
import '../lux.dart';
import 'verbal_social_view.dart' show QuizOption;

/// Zihin Aşısı board. A technique level opens with a warning card (what the trick is, why it works,
/// how to answer it). Then each item shows an invented group-chat message as a bubble, a question
/// and four options; after an answer a "Neden?" panel names the technique. Rust owns content and
/// scoring.
Widget zihinAsisiView(BuildContext context, GameSession s) => ZihinAsisiBoard(key: ObjectKey(s), session: s);

class ZihinAsisiBoard extends StatefulWidget {
  final GameSession session;
  const ZihinAsisiBoard({super.key, required this.session});

  @override
  State<ZihinAsisiBoard> createState() => _ZihinAsisiBoardState();
}

class _ZihinAsisiBoardState extends State<ZihinAsisiBoard> {
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
    if (s.state['phase'] != 'question' || s.finished || !_armed) return;
    if (!s.act({'answer': i})) return;
    final last = s.state['last'];
    if (last is Map && last['correct'] == true) {
      HapticFeedback.lightImpact();
    } else {
      HapticFeedback.mediumImpact();
    }
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
    if (phase == 'intro' && st['intro'] is Map) return _intro(Map<String, dynamic>.from(st['intro'] as Map));
    final q = st['question'] is Map ? Map<String, dynamic>.from(st['question'] as Map) : null;
    if (q == null) return const SizedBox.expand();
    if (phase == 'done' && st['mode'] != 'endless') return _review(st);
    final last = st['last'] is Map ? Map<String, dynamic>.from(st['last'] as Map) : null;
    final feedback = phase == 'feedback' || phase == 'done';
    final options = [for (final o in (q['options'] as List? ?? const [])) '$o'];
    return Column(
      children: [
        _progress(st),
        Expanded(
          child: SingleChildScrollView(
            key: ValueKey('item${st['q_index']}'),
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _message(q),
                const SizedBox(height: 14),
                Text(ct('${q['ask'] ?? ''}'), style: Lux.ui(16, color: Lux.goldLight, weight: FontWeight.w700)),
                const SizedBox(height: 10),
                for (var i = 0; i < options.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 9),
                    child: QuizOption(label: options[i], state: _optState(i, last, feedback), onTap: () => _answer(i)),
                  ),
                if (feedback && last != null) ...[
                  const SizedBox(height: 6),
                  _why(last),
                  const SizedBox(height: 14),
                  if (phase == 'feedback')
                    Center(
                      child: GoldButton(_isLast(st) ? t('Sonucu gör') : t('Devam'), icon: Icons.arrow_forward_rounded, onPressed: _next),
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  bool _isLast(Map<String, dynamic> st) {
    if (st['mode'] == 'endless') return ((st['lives'] as num?)?.toInt() ?? 1) <= 0;
    final n = (st['q_count'] as num?)?.toInt() ?? 0;
    final idx = (st['q_index'] as num?)?.toInt() ?? 0;
    return n > 0 && idx >= n - 1;
  }

  int _optState(int i, Map<String, dynamic>? last, bool feedback) {
    if (!feedback || last == null) return 0;
    final given = (last['given'] as num?)?.toInt();
    final answer = (last['answer'] as num?)?.toInt();
    if (i == given && i == answer) return 2;
    if (i == given) return 3;
    if (i == answer) return 1;
    return 4;
  }

  Widget _intro(Map<String, dynamic> m) {
    Widget part(IconData icon, String title, String body) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(icon, size: 19, color: Lux.goldLight),
                const SizedBox(width: 8),
                Text(title, style: Lux.ui(15, color: Lux.goldLight, weight: FontWeight.w700)),
              ]),
              const SizedBox(height: 6),
              Text(body, style: Lux.ui(16, color: Lux.ink).copyWith(height: 1.42)),
            ],
          ),
        );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 120),
      children: [
        LuxCard(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t('Bugünün dozu'), style: Lux.ui(13, color: Lux.muted, weight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(ct('${m['name']}'), style: Lux.display(30, color: Lux.goldLight)),
              const SizedBox(height: 16),
              part(Icons.warning_amber_rounded, t('Nedir?'), '${m['what']}'),
              part(Icons.psychology_rounded, t('Neden işe yarar?'), '${m['why']}'),
              part(Icons.shield_rounded, t('Aşın'), '${m['defense']}'),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Center(child: GoldButton(t('Zayıf dozu al'), icon: Icons.arrow_forward_rounded, onPressed: () => s.act({'start': true}))),
      ],
    );
  }

  Widget _progress(Map<String, dynamic> st) {
    final answers = [for (final a in (st['answers'] as List? ?? const [])) a == true];
    if (st['mode'] == 'endless') {
      final lives = (st['lives'] as num?)?.toInt() ?? 0;
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
        child: Row(
          children: [
            Text(t('Seri'), style: Lux.ui(13, color: Lux.muted)),
            const SizedBox(width: 6),
            Text('${st['streak'] ?? 0}', style: Lux.numeral(22)),
            const Spacer(),
            for (var i = 0; i < 3; i++)
              Icon(i < lives ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  size: 18, color: i < lives ? Lux.bordeauxLight : Lux.muted.withValues(alpha: 0.5)),
          ],
        ),
      );
    }
    final n = (st['q_count'] as num?)?.toInt() ?? 10;
    final idx = (st['q_index'] as num?)?.toInt() ?? 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
      child: Row(
        children: [
          for (var i = 0; i < n; i++)
            Expanded(
              child: Container(
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
        ],
      ),
    );
  }

  Widget _message(Map<String, dynamic> q) => Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 15),
        decoration: const BoxDecoration(
          color: Color(0x33000000),
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(4),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(18),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${q['sender'] ?? ''}', style: Lux.ui(13, color: Lux.goldLight, weight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('${q['message'] ?? ''}', style: Lux.ui(17, color: Lux.ink).copyWith(height: 1.42)),
          ],
        ),
      );

  Widget _why(Map<String, dynamic> last) {
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
              Expanded(
                child: Text(ct('${last['technique_label'] ?? ''}'),
                    style: Lux.ui(16, color: right ? Lux.good : Lux.bordeauxLight, weight: FontWeight.w700)),
              ),
              Text(t('Neden?'), style: Lux.display(20, color: Lux.goldLight, italic: true)),
            ],
          ),
          const SizedBox(height: 8),
          Text('${last['why'] ?? ''}', style: Lux.ui(15, color: Lux.ink).copyWith(height: 1.4)),
        ],
      ),
    );
  }

  Widget _review(Map<String, dynamic> st) {
    final rows = [for (final r in (st['review'] as List? ?? const [])) Map<String, dynamic>.from(r as Map)];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 120),
      children: [
        if (st['summary'] is String)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(ct(st['summary'] as String), textAlign: TextAlign.center, style: Lux.ui(14, color: Lux.muted)),
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
                        Text(ct('${r['technique_label']}'), style: Lux.ui(12, color: Lux.goldLight, weight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text('${r['message']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: Lux.ui(13.5, color: Lux.ink)),
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
