import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// Corsi Blocks board: irregularly placed lacquered blocks on a velvet field. Timing, sequences,
/// drift and scoring live in Rust; this widget renders `state` and sends taps.
///
/// Motion: a lit block blooms gold over ~70 ms (from the core's flash clock `lit.t`, so it is
/// frame-exact) with a soft haptic, and fades over 160 ms once the core turns it off; distractor
/// flashes bloom bordeaux and give no haptic. Every tap echoes: the block sinks, flashes and sends a
/// ring outwards (gold when right, bordeaux with a shake when wrong). After a wrong tap the correct
/// order replays with numbers. Blocks glide between show and recall on drift levels (positions come
/// from the core every frame). A finished trial rolls a gold wave over the answer.
Widget corsiView(BuildContext context, GameSession s) => _CorsiBoard(key: ObjectKey(s), session: s);

const _timed = {'countdown', 'ready', 'show', 'drift', 'feedback', 'replay'};

class _Echo {
  final int block;
  final bool ok;
  final double at;
  const _Echo(this.block, this.ok, this.at);
}

class _CorsiBoard extends StatefulWidget {
  final GameSession session;
  const _CorsiBoard({super.key, required this.session});

  @override
  State<_CorsiBoard> createState() => _CorsiBoardState();
}

class _CorsiBoardState extends State<_CorsiBoard> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;

  // Current / fading flash.
  int _litKey = -1;
  int? _litBlock;
  String _litKind = 'target';
  double _litLevel = 0;
  double _litPeak = 0;
  double _litOffAt = -10;
  final Map<int, int> _replayLabels = {};

  final List<_Echo> _echoes = [];
  int _tapSerial = 0;
  String _phase = '';
  double _phaseAt = 0;
  int _lastCount = 0;
  double _doneAt = -1;
  int _trialKey = -1;

  GameSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    _tapSerial = ((s.state['last_tap'] as Map?)?['serial'] as num?)?.toInt() ?? 0;
    _phase = s.state['phase'] as String? ?? 'intro';
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  bool _animating(double now) =>
      now - _litOffAt < 0.3 ||
      _echoes.any((e) => now - e.at < 0.7) ||
      now - _phaseAt < 1.2 ||
      (_doneAt >= 0 && now - _doneAt < 1.6) ||
      _phase == 'recall'; // breathing cue on the board

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1000.0;
    _lastTick = elapsed;
    final phase = s.state['phase'] as String? ?? 'intro';
    if (!s.finished && _timed.contains(phase)) {
      s.tick(dt);
    } else if (_animating(_now)) {
      setState(() {});
    }
  }

  void _sync(Map<String, dynamic> st, double now) {
    final phase = st['phase'] as String? ?? 'intro';
    if (phase != _phase) {
      _phase = phase;
      _phaseAt = now;
      if (phase == 'recall') {
        // On mixed levels the order is revealed right now: make it felt.
        st['mixed'] == true ? HapticFeedback.mediumImpact() : HapticFeedback.selectionClick();
      }
      if (phase == 'feedback') HapticFeedback.lightImpact();
      if (phase == 'replay') _replayLabels.clear();
      if (phase == 'done' && _doneAt < 0) {
        _doneAt = now;
        if (st['status'] == 'won') HapticFeedback.heavyImpact();
      }
    }
    final trialKey = ((st['trial'] as num?)?.toInt() ?? 0) * 10 + (st['history'] as List? ?? const []).length;
    if (trialKey != _trialKey && (phase == 'ready' || phase == 'show' || phase == 'countdown' || phase == 'intro')) {
      _trialKey = trialKey;
      _replayLabels.clear();
      _echoes.clear();
    }
    if (phase == 'countdown') {
      final k = (((st['countdown_ms'] as num?) ?? 0) / 1000).ceil();
      if (k != _lastCount && k >= 1 && k <= 3) HapticFeedback.selectionClick();
      _lastCount = k;
    } else {
      _lastCount = 0;
    }
    final lit = st['lit'];
    if (lit is Map) {
      final key = (lit['key'] as num).toInt();
      final kind = lit['kind'] as String;
      if (key != _litKey) {
        _litKey = key;
        if (kind == 'target') HapticFeedback.lightImpact();
        if (kind == 'replay') {
          HapticFeedback.selectionClick();
          _replayLabels[(lit['block'] as num).toInt()] = (lit['index'] as num).toInt() + 1;
        }
      }
      _litBlock = (lit['block'] as num).toInt();
      _litKind = kind;
      final t = (lit['t'] as num).toDouble();
      // ~70 ms attack, then hold.
      final attack = 70 / (((st['interval_ms'] as num?)?.toDouble() ?? 900) * 0.6);
      _litLevel = Curves.easeOut.transform((t / attack).clamp(0.0, 1.0));
      _litPeak = _litLevel;
      _litOffAt = now;
    } else if (_litBlock != null) {
      final out = 1 - (now - _litOffAt) / 0.16;
      _litLevel = out <= 0 ? 0 : Curves.easeIn.transform(out.clamp(0.0, 1.0)) * _litPeak;
      if (out <= 0) _litBlock = null;
    }
    final lt = st['last_tap'];
    if (lt is Map) {
      final serial = (lt['serial'] as num).toInt();
      if (serial != _tapSerial) {
        _tapSerial = serial;
        final ok = lt['ok'] == true;
        _echoes.add(_Echo((lt['block'] as num).toInt(), ok, now));
        if (!ok) HapticFeedback.mediumImpact();
      }
    }
    _echoes.removeWhere((e) => now - e.at > 0.8);
  }

  void _tapAt(Offset p, List<Offset> centers, double sizePx) {
    if (s.finished || s.state['phase'] != 'recall') return;
    var best = -1;
    var bestD = double.infinity;
    for (var i = 0; i < centers.length; i++) {
      final d = (centers[i] - p).distance;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    if (best < 0 || bestD > sizePx * 0.75) return;
    final taps = [for (final t in (s.state['taps'] as List? ?? const [])) (t as num).toInt()];
    if (taps.contains(best)) return; // already tapped this trial: ignore quietly
    HapticFeedback.selectionClick();
    s.act({'tap': best});
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
            _header(st, now),
            // Mixed levels reserve a fixed slot, so the board never moves when the order appears.
            if (st['mixed'] == true) _orderBanner(st, phase, now),
            Expanded(child: _board(st, now)),
            _footer(st, phase),
          ],
        ),
        if (phase == 'countdown') Positioned.fill(child: IgnorePointer(child: _countdown(st))),
        if (phase == 'intro') Positioned.fill(child: _card(st)),
      ],
    );
  }

  // ------------------------------------------------------------------ header

  Widget _header(Map<String, dynamic> st, double now) {
    final endless = st['mode'] == 'endless';
    final reverse = st['reverse'] == true;
    final hidden = st['reverse'] == null;
    final span = (st['span'] as num?)?.toInt() ?? 0;
    final results = [for (final r in (st['results'] as List? ?? const [])) r == true];
    final trials = (st['trials'] as num?)?.toInt() ?? 0;
    final pulse = 0.5 + 0.5 * math.sin(now * 4);
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  FoilText('$span', style: Lux.numeral(44)),
                  const SizedBox(width: 6),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(Lux.upper('blok'), style: Lux.ui(13, color: Lux.gold, weight: FontWeight.w600, spacing: 2)),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(width: 14),
          if (hidden)
            // Mixed level, order not revealed yet.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: const Color(0x14D4A94E),
                border: Border.all(color: Lux.gold.withValues(alpha: 0.5), width: 1.2),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.shuffle_rounded, size: 16, color: Lux.muted),
                const SizedBox(width: 4),
                Text('Yön gizli', style: Lux.ui(14, color: Lux.muted, weight: FontWeight.w700)),
              ]),
            )
          else
            AnimatedContainer(
              duration: const Duration(milliseconds: 260),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: reverse ? const Color(0x33A3203F) : const Color(0x22D4A94E),
                border: Border.all(color: reverse ? Lux.bordeauxLight : Lux.gold, width: 1.2),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (reverse) const Icon(Icons.west_rounded, size: 16, color: Lux.bordeauxLight),
                  if (reverse) const SizedBox(width: 4),
                  Text(reverse ? 'Tersten' : 'Aynı sıra',
                      style:
                          Lux.ui(14, color: reverse ? const Color(0xFFFFD6DF) : Lux.goldLight, weight: FontWeight.w700)),
                  if (!reverse) const SizedBox(width: 4),
                  if (!reverse) const Icon(Icons.east_rounded, size: 16, color: Lux.goldLight),
                ],
              ),
            ),
          const Spacer(),
          if (endless)
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('İleri  ${_spanText(st['forward_span'], st['stage'] == 'forward')}', style: Lux.ui(14, color: Lux.goldLight)),
                Text('Geri  ${_spanText(st['backward_span'], st['stage'] == 'backward')}', style: Lux.ui(14, color: Lux.muted)),
              ],
            )
          else
            Row(
              children: [
                for (var i = 0; i < trials; i++)
                  Container(
                    width: 13,
                    height: 13,
                    margin: const EdgeInsets.only(left: 5),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: i < results.length && results[i] ? Lux.goldGradient : null,
                      color: i < results.length ? (results[i] ? null : Lux.bordeaux) : Colors.transparent,
                      border: Border.all(
                        color: i == results.length && !s.finished
                            ? Lux.goldLight.withValues(alpha: 0.5 + 0.5 * pulse)
                            : Lux.gold.withValues(alpha: 0.45),
                        width: 1.2,
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// Mixed levels: a quiet placeholder while the sequence is shown, then the order pops in when
  /// recall starts (scale + gold/bordeaux glow) and stays until the trial is over.
  Widget _orderBanner(Map<String, dynamic> st, String phase, double now) {
    final revealed = st['reverse'] is bool && const {'recall', 'feedback', 'replay'}.contains(phase);
    final reverse = st['reverse'] == true;
    final Widget child;
    if (!revealed) {
      child = Center(
        key: const ValueKey('hidden'),
        child: Text(
          phase == 'ready' || phase == 'show' || phase == 'drift' ? 'Sırayı izle · yön sonra açıklanacak' : '',
          style: Lux.ui(14, color: Lux.muted, weight: FontWeight.w600),
        ),
      );
    } else {
      final t = phase == 'recall' ? now - _phaseAt : 1.0;
      final inT = Curves.easeOutBack.transform((t / 0.35).clamp(0.0, 1.0));
      final glow = (1 - t / 0.7).clamp(0.0, 1.0);
      final ink = reverse ? Lux.bordeauxLight : Lux.goldLight;
      child = Center(
        key: ValueKey('shown$reverse'),
        child: Transform.scale(
          scale: 1.25 - 0.25 * inT,
          child: Opacity(
            opacity: (t / 0.12).clamp(0.0, 1.0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                color: reverse ? const Color(0x55A3203F) : const Color(0x33D4A94E),
                border: Border.all(color: ink, width: 1.6),
                boxShadow: [BoxShadow(color: ink.withValues(alpha: 0.55 * glow), blurRadius: 22, spreadRadius: 2)],
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(reverse ? Icons.west_rounded : Icons.east_rounded, size: 22, color: ink),
                const SizedBox(width: 8),
                Text(Lux.upper(reverse ? 'Ters sırada' : 'Aynı sırada'),
                    style: Lux.display(20, color: reverse ? const Color(0xFFFFD6DF) : Lux.goldLight, spacing: 1.4)),
              ]),
            ),
          ),
        ),
      );
    }
    return SizedBox(
      height: 54,
      child: AnimatedSwitcher(duration: const Duration(milliseconds: 160), child: child),
    );
  }

  String _spanText(Object? v, bool active) {
    final n = (v as num?)?.toInt() ?? 0;
    if (n > 0) return '$n';
    return active ? '…' : '—';
  }

  // ------------------------------------------------------------------ board

  Widget _board(Map<String, dynamic> st, double now) {
    final boardH = (st['board_h'] as num?)?.toDouble() ?? 1.25;
    final size = (st['block_size'] as num?)?.toDouble() ?? 0.15;
    final blocks = [
      for (final b in (st['blocks'] as List? ?? const []))
        Offset(((b as List)[0] as num).toDouble(), (b[1] as num).toDouble())
    ];
    final rot = [for (final r in (st['rot'] as List? ?? const [])) (r as num).toDouble()];
    final taps = [for (final t in (st['taps'] as List? ?? const [])) (t as num).toInt()];
    final phase = st['phase'] as String? ?? 'intro';
    final answer = st['answer'] is List ? [for (final a in st['answer'] as List) (a as num).toInt()] : const <int>[];
    final wrong = (st['wrong_block'] as num?)?.toInt();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      child: LayoutBuilder(builder: (context, box) {
        final k = math.min(box.maxWidth, box.maxHeight / boardH);
        final w = k, h = k * boardH;
        final ox = (box.maxWidth - w) / 2, oy = (box.maxHeight - h) / 2;
        final centers = [for (final b in blocks) Offset(ox + b.dx * k, oy + b.dy * k)];
        final sizePx = size * k;
        // Gold wave over the answer after a correct trial, over every block when the level is won.
        final waves = <int, double>{};
        if (phase == 'feedback') {
          for (var i = 0; i < answer.length; i++) {
            waves[answer[i]] = now - _phaseAt - 0.06 * i;
          }
        }
        if (_doneAt >= 0 && st['status'] == 'won') {
          for (var i = 0; i < blocks.length; i++) {
            final d = (blocks[i] - Offset(0.5, boardH / 2)).distance;
            waves[i] = now - _doneAt - 0.5 * d;
          }
        }
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _tapAt(d.localPosition, centers, sizePx),
          child: CustomPaint(
            size: Size(box.maxWidth, box.maxHeight),
            painter: _BoardPainter(
              field: Rect.fromLTWH(ox, oy, w, h),
              centers: centers,
              rot: rot,
              sizePx: sizePx,
              now: now,
              litBlock: _litBlock,
              litKind: _litKind,
              litLevel: _litLevel,
              taps: phase == 'recall' || phase == 'feedback' || phase == 'replay' ? taps : const [],
              replayLabels: phase == 'replay' || (phase == 'done' && _replayLabels.isNotEmpty) ? _replayLabels : const {},
              wrong: phase == 'replay' || phase == 'done' ? wrong : null,
              echoes: _echoes,
              waves: waves,
              recallT: phase == 'recall' ? now - _phaseAt : -1,
            ),
          ),
        );
      }),
    );
  }

  // ------------------------------------------------------------------ footer

  Widget _footer(Map<String, dynamic> st, String phase) {
    final reverse = st['reverse'] == true;
    final span = (st['span'] as num?)?.toInt() ?? 0;
    final taps = (st['taps'] as List? ?? const []).length;
    final distractors = (st['distractors'] as num?)?.toInt() ?? 0;
    String text;
    Color color = Lux.ink;
    switch (phase) {
      case 'ready':
        text = 'Hazır ol…';
        color = Lux.muted;
      case 'show':
        text = distractors > 0 ? 'İzle · bordoyu yok say' : 'İzle';
        color = Lux.goldLight;
      case 'drift':
        text = 'Bloklar kayıyor · gözünü ayırma';
        color = Lux.goldLight;
      case 'recall':
        text = '${reverse ? 'Tersten dokun' : 'Sıra sende'} · $taps / $span';
      case 'feedback':
        text = 'Doğru!';
        color = Lux.good;
      case 'replay':
        text = reverse ? 'Doğru ters sıra buydu' : 'Doğru sıra buydu';
        color = Lux.bordeauxLight;
      default:
        text = '';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 22),
      child: SizedBox(
        height: 34,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: Text(text, key: ValueKey(text), style: Lux.ui(20, color: color, weight: FontWeight.w600)),
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
    final dim = k == 1 ? 1 - outT : 1.0;
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.35 * dim),
      child: Center(
        child: Transform.scale(
          scale: scale,
          child: Opacity(opacity: opacity, child: Text('$k', style: Lux.display(110, color: Lux.goldLight))),
        ),
      ),
    );
  }

  Widget _card(Map<String, dynamic> st) {
    final endless = st['mode'] == 'endless';
    final reverse = st['reverse'] == true;
    final distractors = (st['distractors'] as num?)?.toInt() ?? 0;
    final drifting = st['drifting'] == true;
    final bodyStyle = Lux.ui(16, weight: FontWeight.w500);
    String heading;
    final lines = <String>[];
    if (endless) {
      if (st['stage'] == 'backward') {
        heading = 'Şimdi tersten';
        lines.add('İleri açıklığın: ${(st['forward_span'] as num?)?.toInt() ?? 0}.');
        lines.add('Aynı merdiven, ama bu kez yanan sırayı sondan başa dokun. Dizi yine 3 bloktan başlar.');
      } else {
        heading = 'Kapasite testi';
        lines.add('Klasik Corsi merdiveni: dizi 3 bloktan başlar. Her uzunlukta iki şansın var; biri doğruysa dizi bir uzar.');
        lines.add('İkisi de yanlışsa ileri aşama biter, aynı test tersten başlar.');
        lines.add('Puan = ileri açıklık + geri açıklık.');
      }
    } else {
      if (st['mixed'] == true) {
        heading = 'Karışık yön';
        lines.add('Bloklar tek tek altın rengi yanacak. Hangi yönde dokunacağın gösterim bitince '
            'üstte açıklanır: AYNI SIRADA ya da TERS SIRADA.');
        lines.add('Yön her denemede değişebilir; önceden bilemezsin. Sırayı iki ucundan da '
            'okunabilecek bir şekil olarak aklında tut.');
      } else {
        heading = reverse ? 'Tersten' : 'Aynı sıra';
        lines.add(reverse
            ? 'Bloklar tek tek altın rengi yanacak. Sonra onlara sondan başa doğru dokun.'
            : 'Bloklar tek tek altın rengi yanacak. Sonra onlara aynı sırayla dokun.');
      }
      if (distractors > 0) lines.add('Bordo yanan blokları yok say: onlar sıraya dahil değil.');
      if (drifting) lines.add('Gösterimden sonra bloklar yavaşça kayar: yeri değil, bloğun kendisini takip et.');
      lines.add('6 deneme · 6/6 doğru 3 yıldız, 5/6 iki yıldız; en az 3 doğru gerekir.');
    }
    return TweenAnimationBuilder<double>(
      key: ValueKey('card${st['stage']}'),
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
                for (final l in lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(l, textAlign: TextAlign.center, style: bodyStyle),
                  ),
                const SizedBox(height: 10),
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

/// Velvet field, lacquered blocks, the lit bloom, tap echoes and the replay numbers.
class _BoardPainter extends CustomPainter {
  final Rect field;
  final List<Offset> centers;
  final List<double> rot;
  final double sizePx, now, litLevel, recallT;
  final int? litBlock, wrong;
  final String litKind;
  final List<int> taps;
  final Map<int, int> replayLabels;
  final List<_Echo> echoes;
  final Map<int, double> waves;

  _BoardPainter({
    required this.field,
    required this.centers,
    required this.rot,
    required this.sizePx,
    required this.now,
    required this.litBlock,
    required this.litKind,
    required this.litLevel,
    required this.taps,
    required this.replayLabels,
    required this.wrong,
    required this.echoes,
    required this.waves,
    required this.recallT,
  });

  static final Paint _p = Paint();
  static final Paint _stroke = Paint()..style = PaintingStyle.stroke;
  static final Map<String, TextPainter> _labels = {};

  static const _jade = Color(0xFF2B4A3E);

  TextPainter _label(String text, double fs, Color c) {
    final key = '$text@${fs.round()}@${c.toARGB32()}';
    return _labels[key] ??= (TextPainter(
      text: TextSpan(text: text, style: Lux.numeral(fs, color: c)),
      textDirection: TextDirection.ltr,
    )..layout());
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Field: a soft inset panel so the blocks sit on something.
    final fr = RRect.fromRectAndRadius(field.inflate(sizePx * 0.15), Radius.circular(sizePx * 0.5));
    canvas.drawRRect(
      fr,
      _p
        ..shader = const RadialGradient(
          center: Alignment(-0.3, -0.5),
          radius: 1.2,
          colors: [Color(0x3317604A), Color(0x22041A12), Color(0x00000000)],
        ).createShader(fr.outerRect),
    );
    _p.shader = null;
    // Breathing rim while it's your turn.
    final rimA = recallT >= 0 ? 0.22 + 0.12 * math.sin(recallT * 3.2) : 0.12;
    canvas.drawRRect(fr, _stroke..strokeWidth = 1..color = Lux.gold.withValues(alpha: rimA));

    for (var i = 0; i < centers.length; i++) {
      _block(canvas, i);
    }
    // Echo rings above everything.
    for (final e in echoes) {
      if (e.block >= centers.length) continue;
      final k = (now - e.at) / 0.6;
      if (k < 0 || k > 1) continue;
      final c = centers[e.block];
      final r = sizePx * (0.55 + 0.75 * Curves.easeOutCubic.transform(k));
      canvas.drawCircle(
        c,
        r,
        _stroke
          ..strokeWidth = 2.2 * (1 - k) + 0.6
          ..color = (e.ok ? Lux.goldLight : Lux.bordeauxLight).withValues(alpha: 0.75 * (1 - k)),
      );
    }
  }

  double _echoAmount(int i, {bool? ok}) {
    var a = 0.0;
    for (final e in echoes) {
      if (e.block != i || (ok != null && e.ok != ok)) continue;
      final k = now - e.at;
      if (k >= 0 && k < 0.45) a = math.max(a, 1 - k / 0.45);
    }
    return a;
  }

  void _block(Canvas canvas, int i) {
    var c = centers[i];
    final s = sizePx;
    // Light sources.
    var light = 0.0;
    Color glow = Lux.gold;
    if (i == litBlock && litLevel > 0) {
      light = litLevel;
      glow = litKind == 'distractor' ? const Color(0xFFC0284E) : (litKind == 'replay' ? Lux.goldLight : Lux.gold);
      if (litKind == 'replay') light *= 0.85;
    }
    final wave = waves[i];
    if (wave != null && wave > 0 && wave < 0.5) {
      final w = math.sin(math.pi * wave / 0.5) * 0.8;
      if (w > light) {
        light = w;
        glow = Lux.gold;
      }
    }
    final okEcho = _echoAmount(i, ok: true);
    final badEcho = _echoAmount(i, ok: false);
    if (okEcho > light) {
      light = okEcho * 0.9;
      glow = Lux.goldLight;
    }
    if (badEcho > 0) {
      light = math.max(light, badEcho);
      glow = Lux.bordeaux;
      final k = 0.45 * (1 - badEcho);
      c += Offset(math.sin(k * 52) * s * 0.06 * badEcho, 0);
    }
    final isWrong = i == wrong;
    final tapIdx = taps.indexOf(i);
    // Tap sinks the block a touch.
    final sink = math.max(okEcho, badEcho);
    final scale = 1 + 0.05 * light - 0.05 * sink;

    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(i < rot.length ? rot[i] : 0);
    canvas.scale(scale, scale);
    final rect = Rect.fromCenter(center: Offset.zero, width: s, height: s);
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(s * 0.2));

    // Bloom.
    if (light > 0.01) {
      canvas.drawRRect(
        rr.inflate(s * 0.14 * light),
        _p
          ..color = glow.withValues(alpha: 0.8 * light)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.22),
      );
    }
    // Drop shadow.
    canvas.drawRRect(
      rr.shift(Offset(0, s * 0.07)),
      _p
        ..color = Colors.black.withValues(alpha: 0.5)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.06),
    );
    _p.maskFilter = null;

    // Lacquered body: jade at rest, lerps into the glow colour as it lights.
    final base = isWrong ? Color.lerp(_jade, Lux.bordeaux, 0.55)! : _jade;
    final body = Color.lerp(base, glow, light)!;
    canvas.drawRRect(
      rr,
      _p
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(body, Colors.white, 0.28 + 0.32 * light)!,
            body,
            Color.lerp(body, Colors.black, 0.45 - 0.25 * light)!,
          ],
          stops: const [0, 0.45, 1],
        ).createShader(rect),
    );
    _p.shader = null;
    // Bevel: inner face slightly inset with its own gradient.
    final inner = rr.deflate(s * 0.1);
    canvas.drawRRect(
      inner,
      _p
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(body, Colors.black, 0.08 - 0.08 * light)!,
            Color.lerp(body, Colors.white, 0.08 + 0.3 * light)!,
          ],
        ).createShader(inner.outerRect),
    );
    _p.shader = null;
    // Gloss.
    final gloss = RRect.fromRectAndRadius(
      Rect.fromLTWH(-s * 0.36, -s * 0.4, s * 0.72, s * 0.22),
      Radius.circular(s * 0.11),
    );
    canvas.drawRRect(
      gloss,
      _p
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white.withValues(alpha: 0.32 + 0.25 * light), Colors.white.withValues(alpha: 0)],
        ).createShader(gloss.outerRect),
    );
    _p.shader = null;
    // Gold rim.
    final rimColor = isWrong
        ? Lux.bordeauxLight
        : Color.lerp(Lux.gold.withValues(alpha: 0.85), Lux.goldLight, math.max(light, tapIdx >= 0 ? 0.6 : 0))!;
    canvas.drawRRect(rr.deflate(0.7), _stroke..strokeWidth = 1.3 + 1.2 * light..color = rimColor);

    // Labels: replay order (big) or your tap order (small, quiet).
    final label = replayLabels[i];
    if (label != null) {
      final tp = _label('$label', s * 0.36, light > 0.4 ? const Color(0xFF2A1D05) : Lux.goldLight);
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    } else if (tapIdx >= 0) {
      final tp = _label('${tapIdx + 1}', s * 0.22, Lux.goldLight.withValues(alpha: 0.85));
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BoardPainter old) => true;
}
