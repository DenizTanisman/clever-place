import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// Hızlı Akış board: one fixed window where letters flash back to back, then a keypad / option
/// grid to report the targets.
///
/// Timing precision: the core advances the stream on every tick from accumulated dt; this view
/// renders exactly the item in `state` on every frame, as a large crisp glyph with no transition,
/// fade or scaling (any smoothing would blend neighbouring items and change the effective rate).
/// Decoration is limited to the phases between streams (fixation cross, answer keys, feedback
/// chips, the per-lag chart at the end).
Widget rsvpView(BuildContext context, GameSession s) => _RsvpBoard(key: ObjectKey(s), session: s);

const _ivory = Color(0xFFF4EEDC);
const _ruby = Color(0xFFE5506F);

class _RsvpBoard extends StatefulWidget {
  final GameSession session;
  const _RsvpBoard({super.key, required this.session});

  @override
  State<_RsvpBoard> createState() => _RsvpBoardState();
}

class _RsvpBoardState extends State<_RsvpBoard> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;

  int _seenSerial = 0;
  double _fbAt = -10;
  double _doneAt = -1;
  int _lastCount = 0;

  GameSession get s => widget.session;

  static const _timed = {'countdown', 'fixation', 'stream', 'feedback'};

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
    if (!s.finished && _timed.contains(s.state['phase'])) {
      s.tick(dt);
    } else if (_now - _fbAt < 0.5 || (_doneAt >= 0 && _now - _doneAt < 1.4)) {
      setState(() {});
    }
  }

  void _sync(Map<String, dynamic> st, double now) {
    final last = st['last'];
    if (last is Map) {
      final serial = (last['serial'] as num).toInt();
      if (serial != _seenSerial) {
        _seenSerial = serial;
        _fbAt = now;
        final hits = [for (final h in (last['hits'] as List)) h == true];
        hits.every((h) => h) ? HapticFeedback.lightImpact() : HapticFeedback.mediumImpact();
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
            _header(st),
            Expanded(
              child: LayoutBuilder(builder: (context, box) {
                final side = math.min(box.maxWidth - 48, box.maxHeight - 12);
                return Center(child: SizedBox(width: side, height: side, child: _window(st, side, now)));
              }),
            ),
            SizedBox(height: 300, child: _panel(st)),
          ],
        ),
        if (phase == 'countdown') Positioned.fill(child: IgnorePointer(child: _Countdown(st))),
        if (phase == 'intro') Positioned.fill(child: _intro(st)),
      ],
    );
  }

  // ------------------------------------------------------------------ header

  Widget _header(Map<String, dynamic> st) {
    final stream = (st['stream'] as num?)?.toInt() ?? 0;
    final streams = (st['streams'] as num?)?.toInt() ?? 16;
    final results = st['last'] == null ? 0 : stream + (st['phase'] == 'fixation' || st['phase'] == 'stream' ? 0 : 1);
    final t2 = (((st['t2_given_t1'] as num?) ?? 0) * 100).round();
    final t1 = (((st['t1_acc'] as num?) ?? 0) * 100).round();
    final set = [for (final x in (st['target_set'] as List? ?? const [])) x as String];
    final kind = st['kind'];
    final hint = kind == 'digit'
        ? 'Hedef: rakamlar'
        : kind == 'color'
            ? 'Hedef: yakut renkli harfler'
            : 'Hedef harfler: ${set.join(' ')}';
    final done = st['phase'] == 'done' ? streams : results.clamp(0, streams);
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 2),
      child: Column(
        children: [
          Row(
            children: [
              Text('Akış ${math.min(stream + 1, streams)} / $streams', style: Lux.ui(15, weight: FontWeight.w700)),
              const SizedBox(width: 10),
              Expanded(
                  child: Text('saniyede ${st['rate']} harf',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: Lux.ui(14, color: Lux.goldLight))),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 6,
              child: Stack(children: [
                const Positioned.fill(child: ColoredBox(color: Color(0xFF2A2015))),
                FractionallySizedBox(
                  widthFactor: (done / streams).clamp(0.0, 1.0),
                  child: const DecoratedBox(decoration: BoxDecoration(gradient: Lux.goldGradient)),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Lux.ui(13, color: kind == 'color' ? _ruby : Lux.muted, weight: FontWeight.w600)),
              ),
              if (results > 0) Text('T1 %$t1 · T2|T1 %$t2', style: Lux.ui(12, color: Lux.muted)),
            ],
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ window

  Widget _window(Map<String, dynamic> st, double side, double now) {
    final phase = st['phase'] as String? ?? 'intro';
    Widget content;
    switch (phase) {
      case 'stream':
        final item = st['item'];
        content = item is Map
            ? Text(
                item['ch'] as String,
                style: TextStyle(
                  fontFamily: 'Jost',
                  fontSize: side * 0.5,
                  fontWeight: FontWeight.w600,
                  color: item['red'] == true ? _ruby : _ivory,
                  height: 1,
                  fontFeatures: const [FontFeature.liningFigures()],
                ),
                textHeightBehavior:
                    const TextHeightBehavior(applyHeightToFirstAscent: false, applyHeightToLastDescent: false),
              )
            : const SizedBox();
      case 'fixation':
      case 'countdown':
        content = Text('+',
            style: TextStyle(fontFamily: 'Jost', fontSize: side * 0.18, color: Lux.gold.withValues(alpha: 0.8)));
      case 'answer':
        content = Text('?', style: Lux.display(side * 0.3, color: Lux.gold.withValues(alpha: 0.35)));
      case 'feedback':
        content = _feedback(st, side, now);
      case 'done':
        content = _lagChart(st, side, now - _doneAt);
      default:
        content = const SizedBox();
    }
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        color: const Color(0xFF040F0B),
        border: Border.all(color: Lux.gold.withValues(alpha: 0.4), width: 1.2),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 18, offset: const Offset(0, 8))],
      ),
      alignment: Alignment.center,
      child: content,
    );
  }

  Widget _feedback(Map<String, dynamic> st, double side, double now) {
    final last = st['last'];
    if (last is! Map) return const SizedBox();
    final syms = [for (final x in last['symbols'] as List) x as String];
    final hits = [for (final h in last['hits'] as List) h == true];
    final picked = [for (final x in last['picked'] as List) x as String];
    final wrong = picked.where((p) => !syms.contains(p)).toList();
    final t = ((now - _fbAt) / 0.3).clamp(0.0, 1.0);
    final chip = side * 0.2;
    return Opacity(
      opacity: t,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(Lux.upper('Hedefler'), style: Lux.ui(12, color: Lux.gold, weight: FontWeight.w600, spacing: 2.2)),
          const SizedBox(height: 10),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < syms.length; i++) ...[
                if (i > 0) Icon(Icons.chevron_right_rounded, color: Lux.muted.withValues(alpha: 0.6)),
                _chip(syms[i], hits[i] ? Lux.good : Lux.bordeauxLight, chip,
                    hits[i] ? Icons.check_rounded : Icons.close_rounded),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Text('Gecikme ${last['lag']} (T1 → T2 arası ${last['lag']} harf)', style: Lux.ui(14, color: Lux.ink)),
          if (wrong.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Akışta yoktu: ${wrong.join(' ')}', style: Lux.ui(13, color: Lux.bordeauxLight)),
            ),
        ],
      ),
    );
  }

  Widget _chip(String sym, Color c, double size, IconData icon) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.22),
          color: c.withValues(alpha: 0.14),
          border: Border.all(color: c, width: 1.6),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Text(sym,
                style: TextStyle(
                    fontFamily: 'Jost', fontSize: size * 0.52, fontWeight: FontWeight.w600, color: Lux.ink, height: 1)),
            Positioned(right: 3, bottom: 3, child: Icon(icon, size: size * 0.24, color: c)),
          ],
        ),
      );

  /// T2|T1 per lag — the attentional-blink curve of this run.
  Widget _lagChart(Map<String, dynamic> st, double side, double t) {
    final lags = [for (final l in (st['lags'] as List? ?? const [])) Map<String, dynamic>.from(l as Map)];
    final grow = Curves.easeOutCubic.transform((t / 0.9).clamp(0.0, 1.0));
    final h = side * 0.5;
    return Padding(
      padding: EdgeInsets.all(side * 0.07),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(Lux.upper('Gecikmeye göre T2'),
              style: Lux.ui(12, color: Lux.gold, weight: FontWeight.w600, spacing: 2.2)),
          SizedBox(height: side * 0.04),
          SizedBox(
            height: h + 40,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final l in lags)
                  Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        (l['n'] as num) == 0 ? '–' : '%${(100 * (l['ok'] as num) / (l['n'] as num)).round()}',
                        style: Lux.ui(11, color: Lux.muted),
                      ),
                      const SizedBox(height: 3),
                      Container(
                        width: side * 0.07,
                        height: math.max(2, h * grow * ((l['n'] as num) == 0 ? 0 : (l['ok'] as num) / (l['n'] as num))),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(3),
                          gradient: (l['lag'] == 2 || l['lag'] == 3)
                              ? const LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [_ruby, Lux.bordeaux])
                              : Lux.goldGradient,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text('${l['lag']}', style: Lux.ui(13, weight: FontWeight.w700)),
                    ],
                  ),
              ],
            ),
          ),
          Text('Gecikme (harf)', style: Lux.ui(11, color: Lux.muted)),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ panel

  Widget _panel(Map<String, dynamic> st) {
    final phase = st['phase'] as String? ?? 'intro';
    if (phase != 'answer' && phase != 'feedback') {
      final txt = switch (phase) {
        'stream' => '',
        'fixation' => 'Gözün artıda. Yumuşak bak, harfleri okumaya çalışma.',
        'done' => '',
        _ => 'Gözün merkezde · yumuşak odak',
      };
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 30),
          child: Text(txt, textAlign: TextAlign.center, style: Lux.ui(15, color: Lux.muted)),
        ),
      );
    }
    final options = [for (final o in (st['options'] as List? ?? const [])) o as String];
    final picked = [for (final o in (st['picked'] as List? ?? const [])) o as String];
    final targets = (st['targets'] as num?)?.toInt() ?? 2;
    final answering = phase == 'answer';
    final last = st['last'] is Map ? Map<String, dynamic>.from(st['last'] as Map) : null;
    final truth =
        !answering && last != null ? [for (final x in last['symbols'] as List) x as String] : const <String>[];
    final lastPicked =
        !answering && last != null ? [for (final x in last['picked'] as List) x as String] : const <String>[];
    final perRow = options.length > 8 ? 5 : 4;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        children: [
          Text(
            answering ? 'Gördüğün hedefleri seç (en çok $targets) · sıra önemli değil' : ' ',
            style: Lux.ui(13, color: Lux.muted),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: LayoutBuilder(builder: (context, box) {
              const gap = 8.0;
              final rows = (options.length / perRow).ceil();
              final w = (box.maxWidth - gap * (perRow - 1)) / perRow;
              final h = math.min(64.0, (box.maxHeight - gap * (rows - 1)) / math.max(1, rows));
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                alignment: WrapAlignment.center,
                children: [
                  for (final o in options)
                    _Key(
                      label: o,
                      width: w,
                      height: h,
                      selected: answering ? picked.contains(o) : lastPicked.contains(o),
                      verdict: answering
                          ? null
                          : truth.contains(o)
                              ? true
                              : lastPicked.contains(o)
                                  ? false
                                  : null,
                      onTap: answering
                          ? () {
                              HapticFeedback.selectionClick();
                              s.act({'pick': o});
                            }
                          : null,
                    ),
                ],
              );
            }),
          ),
          const SizedBox(height: 6),
          Opacity(
            opacity: answering ? 1 : 0,
            child: GoldButton(
              picked.isEmpty ? 'Göremedim' : 'Onayla (${picked.length}/$targets)',
              icon: Icons.check_rounded,
              outlined: picked.isEmpty,
              onPressed: answering
                  ? () {
                      HapticFeedback.selectionClick();
                      s.act({'submit': true});
                    }
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ intro

  Widget _intro(Map<String, dynamic> st) {
    final n = (st['targets'] as num?)?.toInt() ?? 2;
    final set = [for (final x in (st['target_set'] as List? ?? const [])) x as String];
    final what = switch (st['kind']) {
      'digit' => 'Akan harflerin arasında $n rakam var. Hangilerini gördün?',
      'color' => 'Akışta $n harf yakut renkte. Onlar hangi harflerdi?',
      _ => 'Hedef harfler: ${set.join('  ')}\nAkışta bunlardan $n tanesi geçecek. Hangileri?',
    };
    return _CardOverlay(
      heading: st['title'] as String? ?? 'Hızlı Akış',
      button: 'Başla',
      onPressed: () {
        HapticFeedback.selectionClick();
        s.act({'start': true});
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(what, textAlign: TextAlign.center, style: Lux.ui(16, weight: FontWeight.w500)),
          const SizedBox(height: 10),
          Text(
            'Harfler aynı noktada saniyede ${st['rate']} hızla akar. Gözünü artıda tut, '
            'akış bitince hedefleri seç. İkinci hedef birinciden hemen sonra gelirse kaçırmak normaldir: '
            'buna dikkat kırpması denir.',
            textAlign: TextAlign.center,
            style: Lux.ui(14),
          ),
          if (st['lookalike'] == true) ...[
            const SizedBox(height: 8),
            Text('Bu bölümde benzer şekiller var: O/0, I/1, S/5, Z/2, B/8, G/6.',
                textAlign: TextAlign.center, style: Lux.ui(14, color: Lux.bordeauxLight)),
          ],
          const SizedBox(height: 10),
          Text('${st['streams']} akış · 3★: T1 ve T2|T1 %85 · %60 altı kaybettirir',
              textAlign: TextAlign.center, style: Lux.ui(13, color: Lux.muted)),
        ],
      ),
    );
  }
}

class _Key extends StatelessWidget {
  final String label;
  final double width, height;
  final bool selected;
  final bool? verdict; // feedback: true = was a target, false = wrong pick
  final VoidCallback? onTap;
  const _Key({
    required this.label,
    required this.width,
    required this.height,
    required this.selected,
    required this.verdict,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final v = verdict;
    final rim = v == true
        ? Lux.good
        : v == false
            ? Lux.bordeauxLight
            : (selected ? Lux.gold : Lux.gold.withValues(alpha: 0.4));
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: onTap == null ? null : (_) => onTap!(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: width,
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: selected && v == null
              ? Lux.goldGradient
              : const LinearGradient(colors: [Color(0xFF1E1710), Color(0xFF120D08)]),
          color: null,
          border: Border.all(color: rim, width: selected || v != null ? 2 : 1.2),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 8, offset: const Offset(0, 4))],
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'Jost',
            fontSize: height * 0.5,
            fontWeight: FontWeight.w600,
            height: 1,
            color: selected && v == null ? const Color(0xFF2A1D05) : Lux.ink,
            decoration: v == false ? TextDecoration.lineThrough : null,
            decorationColor: Lux.bordeauxLight,
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
