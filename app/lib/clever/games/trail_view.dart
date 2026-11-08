import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// İz Sürme board: labelled circles on a velvet board, tapped one by one in order.
///
/// A tap is hit-tested here (nearest circle within 1.25 r; the core owns the rules) and sent as
/// `{"tap": i}`. When the core accepts it, a gold line grows from the previous circle to the new one
/// over ~220 ms with a bright head, and the circle pops. A wrong tap flashes that circle bordeaux
/// with a medium haptic and counts an error. Taps on empty board or on circles already on the path
/// do nothing.
Widget trailView(BuildContext context, GameSession s) => _TrailBoard(key: ObjectKey(s), session: s);

const _gold = Color(0xFFE2B85A);
const _ruby = Color(0xFFD0405E);

class _TrailBoard extends StatefulWidget {
  final GameSession session;
  const _TrailBoard({super.key, required this.session});

  @override
  State<_TrailBoard> createState() => _TrailBoardState();
}

class _C {
  final Offset p;
  final String label;
  final int color;
  final double rot;
  const _C(this.p, this.label, this.color, this.rot);
}

class _TrailBoardState extends State<_TrailBoard> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;

  // Board transform (unit → local).
  double _scale = 1;
  Offset _origin = Offset.zero;

  /// How long a new line segment takes to grow (seconds).
  static const _grow = 0.22;

  int _errSerial = 0;
  int _okSerial = 0;
  double _errAt = -10;
  int? _errCircle;
  double _okAt = -10;
  int? _okCircle;
  double _doneAt = -1;
  int _lastCount = 0;

  GameSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    _errSerial = (s.state['err_serial'] as num?)?.toInt() ?? 0;
    _okSerial = (s.state['ok_serial'] as num?)?.toInt() ?? 0;
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  bool _animating(double now) =>
      now - _errAt < 0.6 || now - _okAt < 0.5 || (_doneAt >= 0 && now - _doneAt < 1.6);

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1000.0;
    _lastTick = elapsed;
    final phase = s.state['phase'];
    if (!s.finished && (phase == 'countdown' || phase == 'run')) {
      s.tick(dt);
    } else if (_animating(_now)) {
      setState(() {});
    }
  }

  // ------------------------------------------------------------------ state helpers

  List<_C> _circles(Map<String, dynamic> st) => [
        for (final c in (st['circles'] as List? ?? const []))
          _C(
            Offset(((c as Map)['x'] as num).toDouble(), (c['y'] as num).toDouble()),
            c['label'] as String,
            (c['color'] as num?)?.toInt() ?? 0,
            (c['rot'] as num?)?.toDouble() ?? 0,
          ),
      ];

  List<int> _path(Map<String, dynamic> st) => [for (final i in (st['path'] as List? ?? const [])) (i as num).toInt()];

  double _radius(Map<String, dynamic> st) => (st['radius'] as num?)?.toDouble() ?? 0.06;

  Offset _toUnit(Offset local) => (local - _origin) / _scale;

  void _sync(Map<String, dynamic> st, double now) {
    final es = (st['err_serial'] as num?)?.toInt() ?? 0;
    if (es != _errSerial) {
      _errSerial = es;
      _errAt = now;
      _errCircle = (st['last_wrong'] as num?)?.toInt();
      HapticFeedback.mediumImpact();
    }
    final os = (st['ok_serial'] as num?)?.toInt() ?? 0;
    if (os != _okSerial) {
      _okSerial = os;
      _okAt = now;
      final path = _path(st);
      _okCircle = path.isEmpty ? null : path.last;
      HapticFeedback.selectionClick();
    }
    if (st['phase'] == 'countdown') {
      final k = (((st['countdown_ms'] as num?) ?? 0) / 1000).ceil();
      if (k != _lastCount && k >= 1 && k <= 3) HapticFeedback.selectionClick();
      _lastCount = k;
    }
    if (st['phase'] == 'done' && _doneAt < 0) {
      _doneAt = now;
      HapticFeedback.heavyImpact();
    }
  }

  // ------------------------------------------------------------------ input

  /// A tap: the nearest circle within 1.25 r goes to the core, which judges it.
  void _down(PointerDownEvent e) {
    final st = s.state;
    if (s.finished || st['phase'] != 'run') return;
    final u = _toUnit(e.localPosition);
    final circles = _circles(st);
    final r = _radius(st);
    int? best;
    var bestD = double.infinity;
    for (var i = 0; i < circles.length; i++) {
      final d = (circles[i].p - u).distance;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    if (best == null || bestD > r * 1.25) return;
    if (_path(st).contains(best)) return; // already on the path: nothing to do
    s.act({'tap': best});
    setState(() {});
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final st = s.state;
    final now = _now;
    _sync(st, now);
    final phase = st['phase'] as String? ?? 'intro';
    final aspect = (st['aspect'] as num?)?.toDouble() ?? 1.45;
    return Stack(
      children: [
        Column(
          children: [
            _header(st),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 14),
                child: LayoutBuilder(builder: (context, box) {
                  _scale = math.min(box.maxWidth, box.maxHeight / aspect);
                  final size = Size(_scale, _scale * aspect);
                  _origin = Offset((box.maxWidth - size.width) / 2, (box.maxHeight - size.height) / 2);
                  return Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: _down,
                    child: CustomPaint(
                      size: box.biggest,
                      painter: _TrailPainter(
                        circles: _circles(st),
                        path: _path(st),
                        radius: _radius(st),
                        scale: _scale,
                        origin: _origin,
                        boardSize: size,
                        // The newest segment grows from the previous circle after each correct tap.
                        grow: Curves.easeOutCubic.transform(((now - _okAt) / _grow).clamp(0.0, 1.0)),
                        colorVariant: st['variant'] == 'color',
                        errCircle: _errCircle,
                        errT: now - _errAt,
                        okCircle: _okCircle,
                        okT: now - _okAt,
                        doneT: _doneAt < 0 ? -1 : now - _doneAt,
                        won: st['status'] == 'won',
                      ),
                    ),
                  );
                }),
              ),
            ),
          ],
        ),
        if (phase == 'countdown') Positioned.fill(child: IgnorePointer(child: _Countdown(st))),
        if (phase == 'intro') Positioned.fill(child: _intro(st)),
      ],
    );
  }

  Widget _header(Map<String, dynamic> st) {
    final done = (st['done'] as num?)?.toInt() ?? 0;
    final total = (st['seq_len'] as num?)?.toInt() ?? 1;
    final errors = (st['errors'] as num?)?.toInt() ?? 0;
    final el = ((st['elapsed_ms'] as num?) ?? 0) / 1000;
    final par = ((st['par_ms'] as num?) ?? 1) / 1000;
    final limit = ((st['limit_ms'] as num?) ?? 1) / 1000;
    final over = el > par;
    String f(double x) => x.toStringAsFixed(1).replaceAll('.', ',');
    final timeColor = el > par * 1.5 ? Lux.bordeauxLight : (over ? const Color(0xFFE8B86A) : Lux.goldLight);
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 4),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(f(el),
                  style:
                      Lux.numeral(40, color: timeColor).copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('sn · hedef ${f(par)}', style: Lux.ui(13, color: Lux.muted)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('$done / $total', style: Lux.ui(18, weight: FontWeight.w700)),
                    Text('Hata $errors', style: Lux.ui(13, color: errors == 0 ? Lux.muted : Lux.bordeauxLight)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Time bar: the gold notch marks par; the bar ends at the time limit.
          LayoutBuilder(builder: (context, box) {
            final w = box.maxWidth;
            return SizedBox(
              height: 8,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: Stack(children: [
                        const Positioned.fill(child: ColoredBox(color: Color(0xFF2A2015))),
                        FractionallySizedBox(
                          widthFactor: (el / limit).clamp(0.0, 1.0),
                          child: DecoratedBox(
                            decoration: over
                                ? BoxDecoration(color: timeColor)
                                : const BoxDecoration(gradient: Lux.goldGradient),
                          ),
                        ),
                      ]),
                    ),
                  ),
                  Positioned(
                    left: w * (par / limit).clamp(0.0, 1.0) - 1,
                    top: -3,
                    bottom: -3,
                    child: Container(width: 2, color: Lux.goldLight),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _intro(Map<String, dynamic> st) {
    final variant = st['variant'] as String? ?? 'a';
    final start = st['start_label'] ?? '1';
    final how = switch (variant) {
      'a' => 'Sayılara küçükten büyüğe sırayla dokun: 1, 2, 3…',
      'a_rev' => 'Geriye say: en büyük sayıdan ($start) başlayıp 1\'e kadar sırayla dokun.',
      'b' => 'Sayı ve harfe dönüşümlü dokun: 1-A-2-B-3-C… Türk alfabesiyle: C\'den sonra Ç, G\'den sonra Ğ, I\'dan sonra İ…',
      'b_rev' => 'B dizisine sondan başa dokun: $start ile başla, 1\'de bitir.',
      _ => 'Her sayı iki renkte var. 1\'den başla, her adımda renk değiştir: '
          '${st['start_color'] == 1 ? 'yakut 1, altın 2, yakut 3' : 'altın 1, yakut 2, altın 3'}…',
    };
    return _CardOverlay(
      heading: st['title'] as String? ?? 'İz Sürme',
      button: 'Başla',
      onPressed: () {
        HapticFeedback.selectionClick();
        s.act({'start': true});
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(how, textAlign: TextAlign.center, style: Lux.ui(16, weight: FontWeight.w500)),
          const SizedBox(height: 10),
          Text(
            'Sıradaki daireye dokun: doğruysa çizgi bir önceki daireden ona uzanır. '
            'Yanlış daireye dokunmak hata sayılır; her yanlış dokunuş ayrı sayılır.',
            textAlign: TextAlign.center,
            style: Lux.ui(14, color: Lux.ink),
          ),
          if ((st['circles'] as List? ?? const []).length > ((st['seq_len'] as num?)?.toInt() ?? 0)) ...[
            const SizedBox(height: 8),
            Text('Dizide olmayan tuzak daireler var: onlara dokunma.',
                textAlign: TextAlign.center, style: Lux.ui(14, color: Lux.bordeauxLight)),
          ],
          const SizedBox(height: 10),
          Text('3 yıldız: hedef sürede, hatasız · 2 yıldız: 1,5 katı süre, en çok 2 hata',
              textAlign: TextAlign.center, style: Lux.ui(13, color: Lux.muted)),
        ],
      ),
    );
  }
}

class _TrailPainter extends CustomPainter {
  final List<_C> circles;
  final List<int> path;
  final double radius, scale;
  final Offset origin;
  final Size boardSize;
  /// 0..1: how much of the newest segment (path[-2] to path[-1]) is drawn.
  final double grow;
  final bool colorVariant;
  final int? errCircle;
  final double errT;
  final int? okCircle;
  final double okT, doneT;
  final bool won;

  _TrailPainter({
    required this.circles,
    required this.path,
    required this.radius,
    required this.scale,
    required this.origin,
    required this.boardSize,
    required this.grow,
    required this.colorVariant,
    required this.errCircle,
    required this.errT,
    required this.okCircle,
    required this.okT,
    required this.doneT,
    required this.won,
  });

  static final Map<String, TextPainter> _labels = {};
  static final Paint _p = Paint();

  Offset _loc(Offset u) => origin + u * scale;

  TextPainter _label(String text, double size, Color color) {
    final key = '$text|${size.round()}|${color.toARGB32()}';
    if (_labels.length > 400) _labels.clear();
    return _labels[key] ??= (TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'Jost',
          fontSize: size,
          fontWeight: FontWeight.w600,
          color: color,
          height: 1,
          fontFeatures: const [FontFeature.liningFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout());
  }

  @override
  void paint(Canvas canvas, Size size) {
    final r = radius * scale;
    final board = RRect.fromRectAndRadius(origin & boardSize, const Radius.circular(20));
    canvas.drawRRect(board, _p..color = const Color(0x33000000));
    canvas.drawRRect(
      board,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Lux.gold.withValues(alpha: 0.25),
    );

    final inPath = path.toSet();
    // The path; its newest segment grows from the previous circle.
    Offset? head;
    if (path.length >= 2) {
      final line = Path()..moveTo(_loc(circles[path[0]].p).dx, _loc(circles[path[0]].p).dy);
      for (var k = 1; k < path.length; k++) {
        var q = _loc(circles[path[k]].p);
        if (k == path.length - 1 && grow < 1) {
          q = Offset.lerp(_loc(circles[path[k - 1]].p), q, grow)!;
          head = q;
        }
        line.lineTo(q.dx, q.dy);
      }
      canvas.drawPath(
        line,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.34
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = Lux.gold.withValues(alpha: 0.22)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.18),
      );
      canvas.drawPath(
        line,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.13
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = Lux.goldLight,
      );
    }
    // Bright head while the newest segment is still growing.
    if (head != null) {
      canvas.drawCircle(
          head,
          r * 0.3,
          _p
            ..color = Lux.goldLight.withValues(alpha: 0.45)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.15));
      _p.maskFilter = null;
      canvas.drawCircle(head, r * 0.13, _p..color = Colors.white.withValues(alpha: 0.9));
    }

    for (var i = 0; i < circles.length; i++) {
      final c = circles[i];
      final center = _loc(c.p);
      final done = inPath.contains(i);
      var scaleK = 1.0;
      // The tapped circle pops as the growing line reaches it.
      final pop = okT - 0.15;
      if (i == okCircle && pop >= 0 && pop < 0.3) scaleK = 1 + 0.14 * math.sin(math.pi * pop / 0.3);
      // Win wave: circles pulse in path order.
      if (doneT >= 0 && won && done) {
        final k = path.indexOf(i) / math.max(1, path.length);
        final u = (doneT - k * 0.7) / 0.35;
        if (u > 0 && u < 1) scaleK = 1 + 0.18 * math.sin(math.pi * u);
      }
      final rr = r * scaleK;
      final base = colorVariant ? (c.color == 1 ? _ruby : _gold) : _gold;
      // Shadow.
      canvas.drawCircle(
          center.translate(0, rr * 0.1),
          rr,
          _p
            ..color = Colors.black.withValues(alpha: 0.4)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, rr * 0.12));
      _p.maskFilter = null;
      final Color body;
      if (done) {
        body = colorVariant ? base : _gold;
      } else {
        body = colorVariant ? Color.lerp(const Color(0xFF0B2A21), base, 0.42)! : const Color(0xFF0B2E24);
      }
      canvas.drawCircle(
        center,
        rr,
        _p
          ..shader = RadialGradient(
            center: const Alignment(-0.35, -0.4),
            radius: 1.0,
            colors: [Color.lerp(body, Colors.white, done ? 0.45 : 0.12)!, body, Color.lerp(body, Colors.black, 0.55)!],
            stops: const [0, 0.55, 1],
          ).createShader(Rect.fromCircle(center: center, radius: rr)),
      );
      _p.shader = null;
      canvas.drawCircle(
        center,
        rr - 0.8,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = done ? 2 : 1.4
          ..color = (colorVariant && !done ? base : Lux.goldLight).withValues(alpha: done ? 0.9 : 0.65),
      );
      // Error flash.
      if (i == errCircle && errT >= 0 && errT < 0.55) {
        final k = 1 - errT / 0.55;
        canvas.drawCircle(
            center,
            rr * (1 + 0.25 * (1 - k)),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 4 * k + 1
              ..color = Lux.bordeauxLight.withValues(alpha: k));
        canvas.drawCircle(center, rr, _p..color = Lux.bordeaux.withValues(alpha: 0.45 * k));
      }
      // Label.
      final fs = r * (c.label.length >= 2 ? 0.86 : 1.0);
      final ink = done ? const Color(0xFF1E1505) : Lux.ink;
      final tp = _label(c.label, fs, ink);
      canvas.save();
      canvas.translate(center.dx, center.dy);
      if (c.rot != 0) canvas.rotate(c.rot * math.pi / 180);
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_TrailPainter old) => true;
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
