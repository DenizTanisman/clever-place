import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';
import 'scene_painter.dart';

/// Değişimi Yakala board. Flicker variant: one big picture that alternates A → blank → B → blank
/// (frame chosen by the core's clock, swapped instantly — no fades, that is the paradigm).
/// Side-by-side variant: A above B, tap a difference on either. Rust owns timing, hit testing and
/// scoring; this widget converts taps to canvas units (1000 × 800) and draws feedback: a bordeaux
/// cross for a miss, a gold ring for a find, and during the reveal both versions alternate slowly
/// with every change circled and named.
Widget changeSpotView(BuildContext context, GameSession s) => _ChangeBoard(key: ObjectKey(s), session: s);

const _mask = Color(0xFF8D8A85);

class _ChangeBoard extends StatefulWidget {
  final GameSession session;
  const _ChangeBoard({super.key, required this.session});

  @override
  State<_ChangeBoard> createState() => _ChangeBoardState();
}

class _ChangeBoardState extends State<_ChangeBoard> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;

  /// Local timestamps of the taps of the current round (index-aligned with state `taps`).
  final List<double> _tapAt = [];
  int _round = -1;
  String _phase = '';
  double _phaseAt = 0;
  final Map<int, double> _foundAt = {};
  int _lastCount = 0;

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
    if (!s.finished && (ph == 'countdown' || ph == 'ready' || ph == 'run' || ph == 'reveal')) {
      s.tick(dt);
    } else if (_now - _phaseAt < 6 || _tapAt.any((t) => _now - t < 1)) {
      setState(() {});
    }
  }

  void _sync(Map<String, dynamic> st) {
    final round = (st['round'] as num?)?.toInt() ?? 0;
    if (round != _round) {
      _round = round;
      _tapAt.clear();
      _foundAt.clear();
    }
    final taps = st['taps'] as List? ?? const [];
    while (_tapAt.length < taps.length) {
      _tapAt.add(_now);
    }
    final changes = st['changes'] as List? ?? const [];
    for (var i = 0; i < changes.length; i++) {
      if ((changes[i] as Map)['found'] == true) _foundAt.putIfAbsent(i, () => _now);
    }
    final ph = st['phase'] as String? ?? 'intro';
    if (ph != _phase) {
      _phase = ph;
      _phaseAt = _now;
      if (ph == 'reveal') {
        st['result'] == 'found' ? HapticFeedback.lightImpact() : HapticFeedback.mediumImpact();
      }
      if (ph == 'done' && st['status'] == 'won') HapticFeedback.heavyImpact();
    }
    if (ph == 'countdown') {
      final k = (((st['countdown_ms'] as num?) ?? 0) / 1000).ceil();
      if (k != _lastCount && k >= 1 && k <= 3) HapticFeedback.selectionClick();
      _lastCount = k;
    }
  }

  void _tap(Offset local, Size box) {
    if (s.state['phase'] != 'run' || s.finished) return;
    final x = (local.dx / box.width * SceneArt.w).clamp(0.0, SceneArt.w);
    final y = (local.dy / box.height * SceneArt.h).clamp(0.0, SceneArt.h);
    HapticFeedback.selectionClick();
    if (s.act({
      'tap': {'x': x, 'y': y}
    })) {
      final taps = s.state['taps'] as List? ?? const [];
      final hit = taps.isNotEmpty && (taps.last as Map)['hit'] == true;
      hit ? HapticFeedback.lightImpact() : HapticFeedback.mediumImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = s.state;
    _sync(st);
    final phase = st['phase'] as String? ?? 'intro';
    final side = st['variant'] == 'side';
    return Stack(
      children: [
        Column(
          children: [
            _header(st),
            Expanded(
              child: LayoutBuilder(builder: (context, box) {
                return Center(child: side ? _sidePictures(st, box) : _flickerPicture(st, box));
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
    final rounds = (st['rounds'] as num?)?.toInt() ?? 1;
    final n = (st['n_changes'] as num?)?.toInt() ?? 1;
    final found = (st['found_n'] as num?)?.toInt() ?? 0;
    final wrong = (st['round_wrong'] as num?)?.toInt() ?? 0;
    final maxWrong = (st['max_wrong'] as num?)?.toInt() ?? 3;
    final missed = (st['missed_rounds'] as num?)?.toInt() ?? 0;
    final t = (st['t_ms'] as num?)?.toDouble() ?? 0;
    final limit = (st['round_ms'] as num?)?.toDouble() ?? 1;
    final left = ((limit - t) / 1000).clamp(0, 999).ceil();
    final frac = (1 - t / limit).clamp(0.0, 1.0);
    final urgent = st['phase'] == 'run' && left <= 5;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
      child: Column(
        children: [
          Row(
            children: [
              Text('Tur $round', style: Lux.display(24, color: Lux.goldLight)),
              Text(' / $rounds', style: Lux.ui(15, color: Lux.muted)),
              const SizedBox(width: 12),
              for (var i = 0; i < rounds; i++)
                Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.only(right: 4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < round - 1 ? Lux.gold.withValues(alpha: 0.8) : Lux.line,
                  ),
                ),
              const Spacer(),
              if (n > 1) ...[
                Text('Fark ', style: Lux.ui(13, color: Lux.muted)),
                Text('$found/$n', style: Lux.ui(16, weight: FontWeight.w700, color: Lux.goldLight)),
                const SizedBox(width: 14),
              ],
              Tooltip(
                message: 'Yanlış dokunuş hakkı',
                child: Row(
                  children: [
                    for (var i = 0; i < maxWrong; i++)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 11,
                        height: 11,
                        margin: const EdgeInsets.only(left: 4),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i < wrong ? Lux.bordeaux : Colors.transparent,
                          border: Border.all(color: i < wrong ? Lux.bordeauxLight : Lux.gold.withValues(alpha: 0.6), width: 1.2),
                        ),
                      ),
                  ],
                ),
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
                  const Positioned.fill(child: ColoredBox(color: Color(0xFF0B2A20))),
                  FractionallySizedBox(
                    widthFactor: frac,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: urgent ? null : Lux.goldGradient,
                        color: urgent ? Lux.bordeauxLight : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(missed > 0 ? 'Kaçan tur: $missed (2. kaçış bölümü bitirir)' : 'Kaçan tur yok',
                  style: Lux.ui(12, color: missed > 0 ? Lux.bordeauxLight : Lux.muted)),
              const Spacer(),
              Text('$left sn', style: Lux.ui(12, color: urgent ? Lux.bordeauxLight : Lux.muted, weight: FontWeight.w600)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _footer(Map<String, dynamic> st) {
    final phase = st['phase'] as String? ?? 'intro';
    final side = st['variant'] == 'side';
    String text;
    Color color = Lux.muted;
    if (phase == 'reveal') {
      final res = st['result'];
      final labels = [
        for (final c in (st['changes'] as List? ?? const []))
          if ((c as Map)['label'] is String) c['label'] as String
      ];
      final head = res == 'found'
          ? 'Buldun!'
          : res == 'timeout'
              ? 'Süre doldu.'
              : '3 yanlış dokunuş.';
      text = '$head ${labels.join(' · ')}';
      color = res == 'found' ? Lux.good : Lux.bordeauxLight;
    } else if (phase == 'run') {
      text = side ? 'Farkı gördüğün yere dokun (üstte ya da altta)' : 'Değişen yere dokun';
    } else if (phase == 'ready') {
      text = 'Yeni sahne geliyor…';
    } else {
      text = '';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      child: SizedBox(
        height: 44,
        child: Center(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Text(text,
                key: ValueKey(text), textAlign: TextAlign.center, maxLines: 2, style: Lux.ui(15, color: color, weight: FontWeight.w600)),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ pictures

  Size _fit(double maxW, double maxH) {
    var w = maxW;
    var h = w / SceneArt.aspect;
    if (h > maxH) {
      h = maxH;
      w = h * SceneArt.aspect;
    }
    return Size(w, h);
  }

  Map<String, dynamic>? _scene(Map<String, dynamic> st, String k) => st[k] is Map ? Map<String, dynamic>.from(st[k] as Map) : null;

  Widget _flickerPicture(Map<String, dynamic> st, BoxConstraints box) {
    final size = _fit(box.maxWidth - 24, box.maxHeight - 8);
    final a = _scene(st, 'scene_a');
    final b = _scene(st, 'scene_b');
    final phase = st['phase'] as String? ?? 'intro';
    String frame = st['frame'] as String? ?? 'b';
    if (phase == 'reveal' || phase == 'done') {
      // Alternate slowly (no mask) so the change is easy to see.
      frame = ((_now - _phaseAt) / 0.7).floor().isEven ? 'b' : 'a';
    }
    final hidden = phase == 'ready' || phase == 'intro' || phase == 'countdown' || frame == 'mask';
    return _framed(
      size,
      Stack(
        fit: StackFit.expand,
        children: [
          // Both pictures always paint (the visible one on top), so their rasters are warm before
          // the first swap and a flicker frame is just a blit.
          if (frame == 'a') ...[
            if (b != null) SceneView(scene: b, radius: 0),
            if (a != null) SceneView(scene: a, radius: 0),
          ] else ...[
            if (a != null) SceneView(scene: a, radius: 0),
            if (b != null) SceneView(scene: b, radius: 0),
          ],
          if (hidden) const ColoredBox(color: _mask),
          if (phase == 'ready') Center(child: Text('Tur ${st['round']}', style: Lux.display(40, color: const Color(0xFFF4EFE4)))),
          if (!hidden) _overlay(st, size),
          if (a != null && !hidden) _sceneNo(st),
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _tap(d.localPosition, size),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sidePictures(Map<String, dynamic> st, BoxConstraints box) {
    final size = _fit(box.maxWidth - 24, (box.maxHeight - 14) / 2);
    final a = _scene(st, 'scene_a');
    final b = _scene(st, 'scene_b');
    final phase = st['phase'] as String? ?? 'intro';
    final hidden = phase == 'ready' || phase == 'intro' || phase == 'countdown';
    Widget pic(Map<String, dynamic>? sc, String tag) => _framed(
          size,
          Stack(
            fit: StackFit.expand,
            children: [
              if (sc != null) SceneView(scene: sc, radius: 0),
              if (hidden) const ColoredBox(color: _mask),
              if (phase == 'ready' && tag == 'A')
                Center(child: Text('Tur ${st['round']}', style: Lux.display(34, color: const Color(0xFFF4EFE4)))),
              if (!hidden) _overlay(st, size),
              Positioned(
                left: 8,
                top: 6,
                child: Text(tag, style: Lux.display(18, color: Colors.white.withValues(alpha: 0.75))),
              ),
              if (sc != null && !hidden && tag == 'B') _sceneNo(st),
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _tap(d.localPosition, size),
                ),
              ),
            ],
          ),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [pic(a, 'A'), const SizedBox(height: 10), pic(b, 'B')],
    );
  }

  Widget _framed(Size size, Widget child) {
    return Container(
      width: size.width,
      height: size.height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Lux.gold.withValues(alpha: 0.55), width: 1.2),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 18, offset: const Offset(0, 8))],
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(13), child: child),
    );
  }

  Widget _sceneNo(Map<String, dynamic> st) => Positioned(
        right: 8,
        bottom: 5,
        child: IgnorePointer(
          child: Text('Sahne #${st['scene_no']}',
              style: Lux.ui(10, color: Colors.white.withValues(alpha: 0.7), weight: FontWeight.w500)
                  .copyWith(shadows: const [Shadow(color: Color(0x99000000), blurRadius: 3)])),
        ),
      );

  Widget _overlay(Map<String, dynamic> st, Size size) {
    final changes = [for (final c in (st['changes'] as List? ?? const [])) Map<String, dynamic>.from(c as Map)];
    final taps = [for (final t in (st['taps'] as List? ?? const [])) Map<String, dynamic>.from(t as Map)];
    final phase = st['phase'] as String? ?? '';
    return IgnorePointer(
      child: CustomPaint(
        painter: _Marks(
          changes: changes,
          foundAt: Map.of(_foundAt),
          taps: taps,
          tapAt: List.of(_tapAt),
          now: _now,
          reveal: phase == 'reveal' || phase == 'done',
          revealAt: _phaseAt,
          missed: st['result'] != null && st['result'] != 'found',
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
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.3),
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

  Widget _introCard(Map<String, dynamic> st) {
    final side = st['variant'] == 'side';
    final n = (st['n_changes'] as num?)?.toInt() ?? 1;
    final rounds = (st['rounds'] as num?)?.toInt() ?? 1;
    final secs = (((st['round_ms'] as num?) ?? 30000) / 1000).round();
    final show = (st['show_ms'] as num?)?.toInt() ?? 800;
    final what = n == 1 ? 'bir şey' : '$n şey';
    final body = side
        ? 'Üstte A, altta B resmi var; aralarında $n fark var. Farkı gördüğün yere dokun — hangi resimde olduğu fark etmez.'
        : 'Resim yanıp sönecek: A (${(show / 1000).toStringAsFixed(1).replaceAll('.', ',')} sn), kısa boşluk, B, boşluk… '
            'İki resim arasında $what değişiyor. Değişen yere dokun.';
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
                Text(Lux.upper(side ? 'Yan yana' : 'Yanıp sönme'), style: Lux.display(22, spacing: 1.5)),
                const SizedBox(height: 14),
                Text(body, textAlign: TextAlign.center, style: Lux.ui(16)),
                const SizedBox(height: 10),
                Text('$rounds tur · tur başına $secs sn · en fazla 3 yanlış dokunuş. 2 tur kaçarsa bölüm biter.',
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

/// Feedback marks in canvas units: tap crosses / bursts, rings around found and revealed changes.
class _Marks extends CustomPainter {
  final List<Map<String, dynamic>> changes;
  final Map<int, double> foundAt;
  final List<Map<String, dynamic>> taps;
  final List<double> tapAt;
  final double now;
  final bool reveal;
  final double revealAt;
  final bool missed;
  _Marks({
    required this.changes,
    required this.foundAt,
    required this.taps,
    required this.tapAt,
    required this.now,
    required this.reveal,
    required this.revealAt,
    required this.missed,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / SceneArt.w;
    canvas.save();
    canvas.scale(k);
    // Rings around changes.
    for (var i = 0; i < changes.length; i++) {
      final c = changes[i];
      final bb = c['bbox'];
      if (bb is! List) continue;
      final r = Rect.fromLTWH((bb[0] as num).toDouble(), (bb[1] as num).toDouble(), (bb[2] as num).toDouble(), (bb[3] as num).toDouble());
      final found = c['found'] == true;
      final t0 = found ? (foundAt[i] ?? now) : revealAt;
      final age = now - t0;
      final grow = Curves.easeOutBack.transform((age / 0.35).clamp(0.0, 1.0));
      final pulse = reveal ? 0.5 + 0.5 * math.sin((now - revealAt) * 6) : 1.0;
      final color = found ? Lux.goldLight : Lux.bordeauxLight;
      final ring = Rect.fromCenter(
          center: r.center, width: math.max(r.width, 46) * (1.25 + 0.25 * (1 - grow)) + 24, height: math.max(r.height, 46) * (1.2 + 0.25 * (1 - grow)) + 24);
      canvas.drawOval(
          ring,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 10 / k * 0.5
            ..color = Colors.black.withValues(alpha: 0.35 * grow)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
      canvas.drawOval(
          ring,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = (3.2 + 1.6 * pulse) / k
            ..color = color.withValues(alpha: grow.clamp(0.0, 1.0)));
    }
    // Taps.
    for (var i = 0; i < taps.length && i < tapAt.length; i++) {
      final age = now - tapAt[i];
      if (age > 1.0) continue;
      final p = Offset((taps[i]['x'] as num).toDouble(), (taps[i]['y'] as num).toDouble());
      final hit = taps[i]['hit'] == true;
      final a = (1 - age).clamp(0.0, 1.0);
      if (hit) {
        canvas.drawCircle(p, (14 + 60 * age) / k, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 / k
          ..color = Lux.goldLight.withValues(alpha: a));
      } else {
        final d = 16 / k * (1 + 0.2 * age);
        final paint = Paint()
          ..strokeWidth = 4 / k
          ..strokeCap = StrokeCap.round
          ..color = Lux.bordeauxLight.withValues(alpha: a);
        final dx = math.sin(age * 40) * 4 * (1 - age) / k; // small shake
        canvas.drawLine(p + Offset(-d + dx, -d), p + Offset(d + dx, d), paint);
        canvas.drawLine(p + Offset(d + dx, -d), p + Offset(-d + dx, d), paint);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_Marks old) => true;
}
