import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// Çoklu Takip: a velvet arena of identical moonstone orbs. The core owns physics and timing; the
/// view ticks it every frame and draws the positions it returns (already interpolated between
/// physics steps, so motion is smooth at 120 Hz).
///
/// Motion & feel: orbs pop in with a staggered spring at the start of each round; targets glow
/// gold and breathe during the cue, then melt back into the crowd over the last 350 ms. Colour
/// lures flash in and out (~0.5 s), the digit probe pops onto its orb. Taps pick the nearest orb
/// (generous radius) with a gold ring that snaps in; the reveal marks hits gold, false picks
/// bordeaux with a small shake and missed targets with a pulsing dashed ring. Occluder bands are
/// opaque velvet with gilt edges, drawn over the orbs.
Widget trackingView(BuildContext context, GameSession s) => _TrackingBoard(key: ObjectKey(s), session: s);

/// Neutral orb colour (moonstone blue) and the colour-lure palette (indices from Rust).
const _moonstone = Color(0xFF5B90B6);
const _lureColors = [Color(0xFFD0405E), Color(0xFF3FBF7F), Color(0xFFA066D8), Color(0xFFE39A3B)];

List<int> _ints(Object? v) => v is List ? [for (final e in v) (e as num).toInt()] : const [];
double _num(Object? v, [double d = 0]) => (v as num?)?.toDouble() ?? d;

// ------------------------------------------------------------------ sprites

/// Pre-rendered glossy orbs (one image per kind and pixel size). Kinds: 0 shadow, 1 moonstone,
/// 2 gold, 3 bordeaux, 4..7 lures, 8 gold glow, 9 bordeaux glow. Every image is 1.6 × the orb
/// diameter, orb centred, so glows and shadows have room.
class _Sprites {
  static final Map<int, ui.Image> _cache = {};
  static final Paint _paint = Paint()..filterQuality = FilterQuality.medium;

  static Color _color(int kind) => switch (kind) {
        2 => Lux.gold,
        3 => Lux.bordeaux,
        >= 4 && <= 7 => _lureColors[kind - 4],
        8 => Lux.goldLight,
        9 => Lux.bordeauxLight,
        _ => _moonstone,
      };

  static ui.Image get(int kind, double px) {
    final size = px.round().clamp(8, 512);
    return _cache[kind * 1000 + size] ??= _render(kind, size.toDouble());
  }

  static ui.Image _render(int kind, double d) {
    final side = (d * 1.6).ceil();
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final o = Offset(side / 2, side / 2);
    final r = d / 2;
    final base = _color(kind);
    if (kind == 0) {
      c.drawCircle(
          o.translate(0, r * 0.14),
          r * 1.02,
          Paint()
            ..color = Colors.black.withValues(alpha: 0.5)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.16));
    } else if (kind >= 8) {
      c.drawCircle(
          o,
          r * 1.25,
          Paint()
            ..color = base.withValues(alpha: 0.55)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.32));
    } else {
      final rect = Rect.fromCircle(center: o, radius: r);
      c.drawCircle(
        o,
        r,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.36, -0.42),
            radius: 1.05,
            colors: [Color.lerp(base, Colors.white, 0.55)!, base, Color.lerp(base, Colors.black, 0.62)!],
            stops: const [0, 0.48, 1],
          ).createShader(rect),
      );
      // Bounce light from below and a fine rim.
      c.drawCircle(
        o,
        r,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(0.35, 0.9),
            radius: 0.7,
            colors: [Color.lerp(base, Colors.white, 0.3)!.withValues(alpha: 0.45), base.withValues(alpha: 0)],
          ).createShader(rect),
      );
      c.drawCircle(
        o,
        r - d * 0.012,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = d * 0.024
          ..color = (kind == 2 ? Lux.goldLight : Colors.white).withValues(alpha: kind == 2 ? 0.6 : 0.22),
      );
      c.drawOval(
        Rect.fromCenter(center: o.translate(-r * 0.3, -r * 0.42), width: r * 0.82, height: r * 0.46),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.5)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.09),
      );
      c.drawCircle(o.translate(-r * 0.4, -r * 0.46), r * 0.08, Paint()..color = Colors.white.withValues(alpha: 0.85));
    }
    return rec.endRecording().toImageSync(side, side);
  }

  /// Draws sprite [kind] for an orb of radius [r] (canvas units) centred at [c].
  static void draw(Canvas canvas, int kind, Offset c, double r, double dpr, {double opacity = 1, double scale = 1}) {
    if (opacity <= 0.004 || scale <= 0.01) return;
    final img = get(kind, 2 * r * dpr);
    final half = r * 1.6 * scale;
    _paint.color = Color.fromRGBO(255, 255, 255, opacity.clamp(0.0, 1.0));
    canvas.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        Rect.fromCenter(center: c, width: half * 2, height: half * 2), _paint);
  }
}

// ------------------------------------------------------------------ board

class _TrackingBoard extends StatefulWidget {
  final GameSession session;
  const _TrackingBoard({super.key, required this.session});

  @override
  State<_TrackingBoard> createState() => _TrackingBoardState();
}

class _TrackingBoardState extends State<_TrackingBoard> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;

  final Map<int, double> _pickAt = {};
  int _serial = 0;
  int _lastCount = 0;
  double _doneAt = -1;
  double _probeAt = -1;
  double _phaseAt = 0;
  String _phase = '';

  GameSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    _serial = (s.state['serial'] as num?)?.toInt() ?? 0;
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  static const _timed = {'countdown', 'show', 'run', 'feedback'};

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1000.0;
    _last = elapsed;
    final phase = s.state['phase'] as String? ?? 'intro';
    if (!s.finished && _timed.contains(phase)) {
      s.tick(dt.clamp(0, 50).toDouble());
    } else if (_busy(_now, phase)) {
      setState(() {});
    } else if (s.finished) {
      _ticker.stop();
    }
  }

  /// Idle phases still animate pick rings, the reveal and the win sweep.
  bool _busy(double now, String phase) =>
      _pickAt.values.any((t) => now - t < 0.4) || (_doneAt >= 0 && now - _doneAt < 1.6) || now - _phaseAt < 0.45;

  void _sync(Map<String, dynamic> st, double now) {
    final phase = st['phase'] as String? ?? 'intro';
    if (phase != _phase) {
      if (phase == 'show') _pickAt.clear();
      if (phase == 'recall') HapticFeedback.selectionClick();
      _phase = phase;
      _phaseAt = now;
    }
    final serial = (st['serial'] as num?)?.toInt() ?? 0;
    if (serial != _serial) {
      _serial = serial;
      final last = st['last'];
      final perfect = last is Map && last['hits'] == last['k'] && last['probe_ok'] != false;
      perfect ? HapticFeedback.lightImpact() : HapticFeedback.mediumImpact();
    }
    if (phase == 'countdown') {
      final k = (_num(st['countdown_ms']) / 1000).ceil();
      if (k != _lastCount && k >= 1 && k <= 3) HapticFeedback.selectionClick();
      _lastCount = k;
    }
    if (st['probe'] is Map) {
      if (_probeAt < 0) _probeAt = now;
    } else {
      _probeAt = -1;
    }
    if (phase == 'done' && _doneAt < 0) {
      _doneAt = now;
      if (st['status'] == 'won') HapticFeedback.heavyImpact();
    }
  }

  void _tapArena(Offset local, double scale) {
    final st = s.state;
    if (st['phase'] != 'recall' || s.finished) return;
    final pos = _ints(st['pos']);
    final r = _num(st['radius'], 50);
    final p = Offset(local.dx / scale, local.dy / scale);
    var best = -1;
    var bestD = double.infinity;
    for (var i = 0; i * 2 + 1 < pos.length; i++) {
      final d = (Offset(pos[i * 2] / 10, pos[i * 2 + 1] / 10) - p).distance;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    if (best < 0 || bestD > r * 1.7) return;
    HapticFeedback.selectionClick();
    final wasPicked = _ints(st['picked']).contains(best);
    if (!wasPicked) _pickAt[best] = _now;
    s.act({'pick': best});
  }

  @override
  Widget build(BuildContext context) {
    final st = s.state;
    final now = _now;
    _sync(st, now);
    final phase = st['phase'] as String? ?? 'intro';
    final arena = _ints(st['arena']);
    final aw = arena.length == 2 ? arena[0].toDouble() : 1000.0;
    final ah = arena.length == 2 ? arena[1].toDouble() : 1300.0;
    final dpr = MediaQuery.devicePixelRatioOf(context);

    return Stack(
      children: [
        Column(
          children: [
            _header(st),
            Expanded(
              child: LayoutBuilder(builder: (context, box) {
                final scale = math.min((box.maxWidth - 28) / aw, (box.maxHeight - 8) / ah);
                final w = aw * scale, h = ah * scale;
                return Center(
                  child: SizedBox(
                    width: w,
                    height: h,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapDown: (d) => _tapArena(d.localPosition, scale),
                            child: CustomPaint(
                              painter: _ArenaPainter(
                                st: st,
                                scale: scale,
                                dpr: dpr,
                                now: now,
                                pickAt: _pickAt,
                                doneT: _doneAt < 0 ? -1 : now - _doneAt,
                                probeT: _probeAt < 0 ? 0 : now - _probeAt,
                                // Once the orbs stop, the bands thin out so hidden orbs can be picked.
                                occluderAlpha: const {'intro', 'countdown', 'show', 'run'}.contains(phase)
                                    ? 1
                                    : 1 - 0.75 * Curves.easeOut.transform(((now - _phaseAt) / 0.35).clamp(0.0, 1.0)),
                              ),
                            ),
                          ),
                        ),
                        if (phase == 'feedback' || phase == 'done')
                          Positioned(left: 0, right: 0, top: 14, child: IgnorePointer(child: _verdict(st))),
                        if (phase == 'probe') Positioned.fill(child: _probePad()),
                      ],
                    ),
                  ),
                );
              }),
            ),
            _footer(st),
          ],
        ),
        if (phase == 'countdown') Positioned.fill(child: IgnorePointer(child: _countdown(st))),
        if (phase == 'intro') Positioned.fill(child: _introCard(st)),
      ],
    );
  }

  // ------------------------------------------------------------------ header / footer

  Widget _header(Map<String, dynamic> st) {
    final round = (st['round'] as num?)?.toInt() ?? 1;
    final rounds = (st['rounds'] as num?)?.toInt() ?? 4;
    final results = (st['results'] as List?) ?? const [];
    final phase = st['phase'] as String? ?? 'intro';
    final len = _num(st['phase_len']);
    final progress =
        (phase == 'show' || phase == 'run') && len > 0 ? (_num(st['phase_ms']) / len).clamp(0.0, 1.0) : 0.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 6),
      child: Column(
        children: [
          Row(
            children: [
              for (var i = 0; i < rounds; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _RoundPip(
                    state: i < results.length
                        ? ((results[i] as Map)['perfect'] == true ? 2 : 1)
                        : (i == round - 1 && phase != 'intro' && phase != 'countdown' ? 3 : 0),
                  ),
                ),
              const SizedBox(width: 6),
              Text('Tur ${math.min(round, rounds)} / $rounds', style: Lux.ui(15, weight: FontWeight.w600)),
              const Spacer(),
              Text(
                switch (phase) {
                  'show' => 'Altınları aklında tut',
                  'run' => 'İzle',
                  'recall' => 'Hedefleri seç',
                  'probe' => 'Rakam',
                  'feedback' => 'Sonuç',
                  _ => '',
                },
                style: Lux.ui(14, color: phase == 'show' ? Lux.goldLight : Lux.muted),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 5,
              child: Stack(
                children: [
                  const Positioned.fill(child: ColoredBox(color: Color(0xFF0A2A20))),
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: phase == 'run' ? 1 - progress : progress,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: phase == 'run'
                            ? const LinearGradient(colors: [Color(0xFF3C6E8F), Color(0xFF8FC1DE)])
                            : Lux.goldGradient,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer(Map<String, dynamic> st) {
    final phase = st['phase'] as String? ?? 'intro';
    final k = (st['k'] as num?)?.toInt() ?? 0;
    final picked = _ints(st['picked']).length;
    final String text;
    Color color = Lux.muted;
    switch (phase) {
      case 'show':
        text = '$k altın küre: hedeflerin bunlar';
        color = Lux.goldLight;
      case 'run':
        text =
            st['has_probe'] == true ? 'Hedefleri izle · bir kürede rakam belirecek' : 'Hedefleri izle, gözünü ayırma';
      case 'recall':
        text = 'Hedefleri seç · $picked / $k';
        color = Lux.ink;
      case 'probe':
        text = 'Hareket sırasında hangi rakam belirdi?';
        color = Lux.ink;
      default:
        text = '';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: SizedBox(
        height: 26,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: Text(text, key: ValueKey(text), style: Lux.ui(16, color: color, weight: FontWeight.w600)),
        ),
      ),
    );
  }

  Widget _verdict(Map<String, dynamic> st) {
    final last = st['last'];
    if (last is! Map) return const SizedBox();
    final hits = (last['hits'] as num?)?.toInt() ?? 0;
    final k = (last['k'] as num?)?.toInt() ?? 0;
    final probeOk = last['probe_ok'];
    final perfect = hits == k && probeOk != false;
    final parts = <String>[perfect ? 'Kusursuz' : '$hits / $k doğru'];
    if (probeOk is bool) {
      parts.add(probeOk ? 'Rakam ${last['digit']} ✓' : 'Rakam ${last['digit']} · sen ${last['answer']}');
    }
    return Center(
      child: TweenAnimationBuilder<double>(
        key: ValueKey('v${st['serial']}'),
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 360),
        curve: Curves.easeOutBack,
        builder: (context, t, child) => Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.translate(
              offset: Offset(0, -8 * (1 - t)), child: Transform.scale(scale: 0.9 + 0.1 * t, child: child)),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: const Color(0xE6062A21),
            border: Border.all(color: (perfect ? Lux.gold : Lux.bordeauxLight).withValues(alpha: 0.85), width: 1.2),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 14, offset: const Offset(0, 6))
            ],
          ),
          child: Text(parts.join('  ·  '),
              style: Lux.ui(15, color: perfect ? Lux.goldLight : const Color(0xFFFFD6DF), weight: FontWeight.w700)),
        ),
      ),
    );
  }

  Widget _probePad() {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => ColoredBox(
        color: Colors.black.withValues(alpha: 0.45 * t),
        child: Opacity(opacity: t, child: Transform.scale(scale: 0.94 + 0.06 * t, child: child)),
      ),
      child: Center(
        child: LuxCard(
          highlight: true,
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(Lux.upper('Hangi rakam?'), style: Lux.display(20, spacing: 1.4)),
              const SizedBox(height: 14),
              for (var row = 0; row < 3; row++)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var c = 1; c <= 3; c++)
                      _DigitKey(row * 3 + c, onTap: (d) {
                        HapticFeedback.selectionClick();
                        s.act({'probe': d});
                      }),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ overlays

  Widget _countdown(Map<String, dynamic> st) {
    final ms = _num(st['countdown_ms']);
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
        child: CustomPaint(
          painter: _CountRing(p),
          child: SizedBox(
            width: 220,
            height: 220,
            child: Center(
              child: Transform.scale(
                scale: scale,
                child: Opacity(opacity: opacity, child: Text('$k', style: Lux.display(110, color: Lux.goldLight))),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _introCard(Map<String, dynamic> st) {
    final k = (st['k'] as num?)?.toInt() ?? 3;
    final n = (st['n'] as num?)?.toInt() ?? 8;
    final secsRaw = _num(st['track_ms'], 5000) / 1000;
    final secs =
        secsRaw == secsRaw.roundToDouble() ? '${secsRaw.round()}' : secsRaw.toStringAsFixed(1).replaceAll('.', ',');
    final extras = <String>[
      if ((st['occluders'] as List?)?.isNotEmpty == true)
        'Perde: küreler altın kenarlı bantların arkasından geçer; çıkışı tahmin et.',
      if (st['lures'] == true) 'Renk tuzağı: bazı küreler bir an renk değiştirir. Aldanma, hedefin değişmez.',
      if (st['has_probe'] == true) 'Rakam: hareket sırasında bir kürede bir rakam belirir. Seçimden sonra sorulur.',
    ];
    final body = Lux.ui(16, weight: FontWeight.w500);
    return TweenAnimationBuilder<double>(
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
                Text(Lux.upper('$k hedef · $n küre'),
                    textAlign: TextAlign.center, style: Lux.display(22, spacing: 1.5)),
                const SizedBox(height: 14),
                Text(
                  '$k küre altın parlayacak: onlar hedeflerin. Sonra hepsi aynı görünür ve $secs saniye hareket eder. '
                  'Durunca $k hedefe dokun.\n4 tur · 4 kusursuz tur 3 yıldız, 3 → 2, 2 → 1.',
                  textAlign: TextAlign.center,
                  style: body,
                ),
                for (final e in extras) ...[
                  const SizedBox(height: 8),
                  Text(e, textAlign: TextAlign.center, style: Lux.ui(14, color: Lux.goldLight)),
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
    );
  }
}

/// Round marker: 0 pending, 1 imperfect (bordeaux), 2 perfect (gold), 3 current (gold outline).
class _RoundPip extends StatelessWidget {
  final int state;
  const _RoundPip({required this.state});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutBack,
      width: state == 3 ? 15 : 13,
      height: state == 3 ? 15 : 13,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: state == 2 ? Lux.goldGradient : null,
        color: state == 1 ? Lux.bordeaux : (state == 0 || state == 3 ? const Color(0xFF0A2A20) : null),
        border: Border.all(
          color: state == 3 ? Lux.goldLight : (state == 1 ? Lux.bordeauxLight : Lux.gold.withValues(alpha: 0.45)),
          width: state == 3 ? 1.6 : 1,
        ),
      ),
    );
  }
}

class _DigitKey extends StatelessWidget {
  final int d;
  final ValueChanged<int> onTap;
  const _DigitKey(this.d, {required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(5),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTapDown: (_) => onTap(d),
          child: Ink(
            width: 62,
            height: 58,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: const Color(0xFF0A2A20),
              border: Border.all(color: Lux.gold.withValues(alpha: 0.6)),
            ),
            child: Center(child: Text('$d', style: Lux.numeral(30))),
          ),
        ),
      ),
    );
  }
}

/// Thin gold ring that sweeps once around each countdown digit.
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

// ------------------------------------------------------------------ arena painter

class _ArenaPainter extends CustomPainter {
  final Map<String, dynamic> st;
  final double scale, dpr, now, doneT, probeT, occluderAlpha;
  final Map<int, double> pickAt;
  _ArenaPainter({
    required this.st,
    required this.scale,
    required this.dpr,
    required this.now,
    required this.pickAt,
    required this.doneT,
    required this.probeT,
    required this.occluderAlpha,
  });

  static final Paint _p = Paint();
  static final Map<String, TextPainter> _digits = {};

  TextPainter _digit(int d, double r) {
    final key = '$d@${r.round()}';
    return _digits[key] ??= (TextPainter(
      text: TextSpan(
        text: '$d',
        style: TextStyle(
          fontFamily: 'Jost',
          fontSize: r * 1.25,
          fontWeight: FontWeight.w800,
          color: const Color(0xFFFFF8E6),
          shadows: const [Shadow(color: Color(0xCC000000), blurRadius: 4, offset: Offset(0, 1))],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout());
  }

  void _background(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rr = RRect.fromRectAndRadius(rect, const Radius.circular(22));
    canvas.drawRRect(
        rr.shift(const Offset(0, 6)),
        _p
          ..color = Colors.black.withValues(alpha: 0.5)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10));
    _p
      ..maskFilter = null
      ..color = const Color(0xFF000000);
    canvas.drawRRect(
      rr,
      _p
        ..shader = const RadialGradient(
          center: Alignment(-0.2, -0.35),
          radius: 1.1,
          colors: [Color(0xFF0F4535), Color(0xFF062A21), Color(0xFF031A13)],
          stops: [0, 0.6, 1],
        ).createShader(rect),
    );
    _p.shader = null;
    // Faint concentric guide rings: a calm visual centre to anchor the gaze.
    final c = rect.center;
    for (var i = 1; i <= 4; i++) {
      canvas.drawCircle(
          c,
          size.shortestSide * 0.13 * i,
          _p
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = Lux.gold.withValues(alpha: 0.05));
    }
    canvas.drawCircle(
        c,
        2.2,
        _p
          ..style = PaintingStyle.fill
          ..color = Lux.gold.withValues(alpha: 0.22));
    canvas.drawRRect(
        rr.deflate(0.7),
        _p
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = Lux.gold.withValues(alpha: 0.7));
    canvas.drawRRect(
        rr.deflate(5),
        _p
          ..strokeWidth = 1
          ..color = Lux.gold.withValues(alpha: 0.14));
    _p.style = PaintingStyle.fill;
  }

  void _occluders(Canvas canvas, Size size) {
    final bands = (st['occluders'] as List? ?? const []);
    if (bands.isEmpty || occluderAlpha <= 0.01) return;
    final fade = occluderAlpha < 0.999;
    if (fade) canvas.saveLayer(Offset.zero & size, Paint()..color = Color.fromRGBO(255, 255, 255, occluderAlpha));
    _bands(canvas, size, bands);
    if (fade) canvas.restore();
  }

  void _bands(Canvas canvas, Size size, List bands) {
    for (final b in bands) {
      final l = b as List;
      final rect = Rect.fromLTRB(0, _num(l[0]) * scale, size.width, _num(l[1]) * scale);
      canvas.save();
      canvas.clipRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(22)));
      canvas.drawRect(
          rect.inflate(3),
          _p
            ..color = Colors.black.withValues(alpha: 0.4)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
      _p
        ..maskFilter = null
        ..color = const Color(0xFF000000);
      canvas.drawRect(
        rect,
        _p
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1A5C47), Color(0xFF0B3A2E), Color(0xFF07291F)],
          ).createShader(rect),
      );
      _p.shader = null;
      // Woven threads.
      canvas.clipRect(rect);
      _p
        ..color = Colors.white.withValues(alpha: 0.035)
        ..strokeWidth = 1;
      for (double x = -rect.height; x < size.width; x += 7) {
        canvas.drawLine(Offset(x, rect.top), Offset(x + rect.height, rect.bottom), _p);
      }
      canvas.restore();
      final edge = Paint()
        ..strokeWidth = 1.4
        ..shader =
            const LinearGradient(colors: [Color(0x00D4A94E), Color(0xFFD4A94E), Color(0x00D4A94E)]).createShader(rect);
      canvas.drawLine(rect.topLeft, rect.topRight, edge);
      canvas.drawLine(rect.bottomLeft, rect.bottomRight, edge);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    _background(canvas, size);
    final pos = _ints(st['pos']);
    final n = pos.length ~/ 2;
    if (n == 0) {
      _occluders(canvas, size);
      return;
    }
    final phase = st['phase'] as String? ?? '';
    final r = _num(st['radius'], 50) * scale;
    final phaseMs = _num(st['phase_ms']);
    final phaseLen = _num(st['phase_len'], 1);
    final targets = _ints(st['targets']).toSet();
    final picked = _ints(st['picked']).toSet();
    final reveal = phase == 'feedback' || phase == 'done';
    final lures = <int, (int, double)>{
      for (final sw in (st['swaps'] as List? ?? const [])) _ints(sw)[0]: (_ints(sw)[1], _num((sw as List)[2])),
    };
    final probe = st['probe'] is Map ? Map<String, dynamic>.from(st['probe'] as Map) : null;

    Offset at(int i) => Offset(pos[i * 2] / 10 * scale, pos[i * 2 + 1] / 10 * scale);

    // Cue: gold that breathes, then melts into moonstone over the last 350 ms.
    var gold = 0.0;
    var breathe = 0.0;
    if (phase == 'show') {
      gold = ((phaseLen - phaseMs) / 350).clamp(0.0, 1.0);
      breathe = 0.5 + 0.5 * math.sin(phaseMs / 1000 * math.pi * 2.2);
    }

    for (var i = 0; i < n; i++) {
      final c0 = at(i);
      // Staggered pop-in when a round's layout appears.
      var sc = 1.0;
      if (phase == 'show') {
        final u = ((phaseMs - 22.0 * i) / 300).clamp(0.0, 1.0);
        sc = Curves.easeOutBack.transform(u);
      }
      if (sc <= 0.01) continue;
      var c = c0;
      final isT = targets.contains(i);
      final isP = picked.contains(i);
      // A false pick shakes once when revealed.
      if (reveal && isP && !isT && phase == 'feedback') {
        final u = (phaseMs / 380).clamp(0.0, 1.0);
        c = c.translate(math.sin(u * math.pi * 6) * r * 0.16 * (1 - u), 0);
      }
      _Sprites.draw(canvas, 0, c, r, dpr, scale: sc);
      if (phase == 'show' && isT) {
        _Sprites.draw(canvas, 8, c, r, dpr, opacity: gold * (0.55 + 0.45 * breathe), scale: sc * (1 + 0.06 * breathe));
      }
      if (reveal && isT && isP) _Sprites.draw(canvas, 8, c, r, dpr, opacity: 0.8);
      if (reveal && isP && !isT) _Sprites.draw(canvas, 9, c, r, dpr, opacity: 0.75);
      _Sprites.draw(canvas, 1, c, r, dpr, scale: sc);
      // Colour overlays.
      double over = 0;
      var kind = 2;
      if (phase == 'show' && isT) {
        over = gold;
      } else if (reveal && isT) {
        over = isP ? 1 : 0.8;
      } else if (reveal && isP) {
        kind = 3;
        over = 1;
      } else if (lures.containsKey(i)) {
        final (col, age) = lures[i]!;
        kind = 4 + col % 4;
        over = age < 80 ? age / 80 : (age > 330 ? ((480 - age) / 150).clamp(0.0, 1.0) : 1.0);
      } else if (isP) {
        kind = 2;
        over = 0.42;
      }
      if (over > 0) _Sprites.draw(canvas, kind, c, r, dpr, opacity: over, scale: sc);

      // Picked ring (snaps in) during recall / probe.
      if (isP && (phase == 'recall' || phase == 'probe')) {
        final t0 = pickAt[i];
        final u = t0 == null ? 1.0 : ((now - t0) / 0.18).clamp(0.0, 1.0);
        final e = Curves.easeOutBack.transform(u);
        canvas.drawCircle(
            c,
            r * (1.42 - 0.22 * e),
            _p
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.6
              ..color = Lux.goldLight.withValues(alpha: 0.95 * u));
        if (u < 1) {
          canvas.drawCircle(
              c,
              r * (1.2 + 0.6 * u),
              _p
                ..strokeWidth = 1.5
                ..color = Lux.goldLight.withValues(alpha: 0.5 * (1 - u)));
        }
        _p.style = PaintingStyle.fill;
      }
      // Missed target: a pulsing dashed gold ring.
      if (reveal && isT && !isP) {
        final pulse = 0.6 + 0.4 * math.sin(now * math.pi * 4);
        _dashedRing(canvas, c, r * 1.32, Lux.goldLight.withValues(alpha: 0.9 * pulse));
      }
      if (reveal && isT && isP) {
        canvas.drawCircle(
            c,
            r * 1.3,
            _p
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.2
              ..color = Lux.goldLight);
        _p.style = PaintingStyle.fill;
      }
      // Digit probe.
      if (probe != null && probe['orb'] == i) {
        final d = (probe['digit'] as num).toInt();
        final tp = _digit(d, r);
        canvas.save();
        canvas.translate(c.dx, c.dy);
        final pop = 0.5 + 0.5 * Curves.easeOutBack.transform((probeT / 0.12).clamp(0.0, 1.0));
        canvas.scale(pop);
        tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
        canvas.restore();
      }
    }
    _occluders(canvas, size);

    // Win: a gold ring sweeps out from the centre.
    if (doneT >= 0 && doneT < 1.2 && st['status'] == 'won') {
      final u = Curves.easeOutCubic.transform((doneT / 1.2).clamp(0.0, 1.0));
      final maxR = (Offset.zero & size).center.distance;
      canvas.drawCircle(
          size.center(Offset.zero),
          maxR * u,
          _p
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3 + 10 * (1 - u)
            ..color = Lux.goldLight.withValues(alpha: 0.5 * (1 - u)));
      _p.style = PaintingStyle.fill;
    }
  }

  void _dashedRing(Canvas canvas, Offset c, double r, Color color) {
    _p
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..color = color;
    const dashes = 14;
    final rect = Rect.fromCircle(center: c, radius: r);
    final spin = now * 0.8;
    for (var k = 0; k < dashes; k++) {
      final a = spin + k * 2 * math.pi / dashes;
      canvas.drawArc(rect, a, math.pi / dashes, false, _p);
    }
    _p.style = PaintingStyle.fill;
  }

  @override
  bool shouldRepaint(_ArenaPainter old) => true;
}
