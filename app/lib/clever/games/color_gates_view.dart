import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// Renk Kapıları: jewel discs slide down gold-inlaid glass rods into jewelled gate rings. The whole
/// lane column is the tap target (any finger, several at once); a tap turns that gate to the next
/// palette colour. Timing and rules live in Rust; this widget only renders and sends `{"tap":i}`.
///
/// Rendering: disc positions come from the core clock (`t`, spawn, duration), so motion is exact at
/// any refresh rate. Discs and gate bands are pre-rendered per colour and size (glossy faceted gems
/// with an engraved shape mark per colour for colour-blind safety); trails grow with speed. Effects
/// are diffed from the state: gold sparks and a bright ring when a disc passes, a bordeaux crack,
/// flying shards and a lane shake on an error, a soft mist when a ghost is kept out, a short
/// turn-and-crossfade when a gate changes, gold arcs before a swap and a lifted glide during it.
Widget colorGatesView(BuildContext context, GameSession s) => _ColorGates(key: ObjectKey(s), session: s);

/// Our palette, in cycle order. Hue and lightness both differ; each also has a shape mark.
const _gems = <Color>[
  Color(0xFFE5484D), // ruby · circle
  Color(0xFF3E9BFF), // sapphire · diamond
  Color(0xFFFFC53D), // topaz · triangle
  Color(0xFFB45CFF), // amethyst · square
  Color(0xFFF2EEE6), // pearl · four-point star
];

Color _gem(int c) => _gems[c.clamp(0, _gems.length - 1)];

/// Engraved shape mark for colour [c], centred on [o] with half-size [h].
Path _mark(int c, Offset o, double h) {
  final p = Path();
  switch (c) {
    case 0:
      p.addOval(Rect.fromCircle(center: o, radius: h * 0.78));
    case 1:
      p
        ..moveTo(o.dx, o.dy - h)
        ..lineTo(o.dx + h * 0.8, o.dy)
        ..lineTo(o.dx, o.dy + h)
        ..lineTo(o.dx - h * 0.8, o.dy)
        ..close();
    case 2:
      p
        ..moveTo(o.dx, o.dy - h * 0.95)
        ..lineTo(o.dx + h * 0.95, o.dy + h * 0.7)
        ..lineTo(o.dx - h * 0.95, o.dy + h * 0.7)
        ..close();
    case 3:
      p.addRRect(RRect.fromRectAndRadius(Rect.fromCircle(center: o, radius: h * 0.72), Radius.circular(h * 0.12)));
    default:
      for (var i = 0; i < 8; i++) {
        final a = -math.pi / 2 + i * math.pi / 4;
        final rr = i.isEven ? h : h * 0.36;
        final pt = o + Offset(math.cos(a) * rr, math.sin(a) * rr);
        if (i == 0) {
          p.moveTo(pt.dx, pt.dy);
        } else {
          p.lineTo(pt.dx, pt.dy);
        }
      }
      p.close();
  }
  return p;
}

// Effect timings (seconds).
const double _gateTurn = 0.16;
const double _passDur = 0.30;
const double _crackDur = 0.65;
const double _shakeDur = 0.36;
const double _sparkLife = 0.55;
const double _swapDur = 0.42;
const double _laneDur = 0.6;
const double _tapGlow = 0.22;
const double _winDur = 1.1;

double _ease(double k) => Curves.easeOutCubic.transform(k.clamp(0.0, 1.0));

List<int> _ints(Object? v) => v is List ? [for (final e in v) (e as num).toInt()] : const [];

/// Repaint signal for the painter.
class _Frame extends ChangeNotifier {
  void ping() => notifyListeners();
}

/// Spark in disc-radius units relative to the gate centre of [lane]; position is analytic.
class _Spark {
  final int lane;
  final double dx, dy, vx, vy, born, life, size;
  final Color color;
  const _Spark(this.lane, this.dx, this.dy, this.vx, this.vy, this.born, this.life, this.size, this.color);
}

/// A finished disc: continues through the portal (pass), shatters (error) or mists away (ghost).
class _Exit {
  final int lane, color, kind;
  final double born, dur;
  const _Exit(this.lane, this.color, this.kind, this.born, this.dur);
}

class _GateTurn {
  final int from, to;
  final double born;
  const _GateTurn(this.from, this.to, this.born);
}

/// Pre-rendered glossy jewels, one image per (colour, kind, pixel size).
class _Jewels {
  static final Map<int, ui.Image> _cache = {};
  static final Paint _paint = Paint()..filterQuality = FilterQuality.medium;

  static ui.Image _get(int c, int kind, double px) {
    final size = px.round().clamp(8, 420);
    final key = (c * 4 + kind) * 1000 + size;
    return _cache[key] ??= switch (kind) {
      0 => _disc(c, size.toDouble()),
      1 => _ghost(c, size.toDouble()),
      _ => _gate(c, size.toDouble()),
    };
  }

  /// Draws colour [c] as a disc (kind 0), ghost (1) or gate band (2) into a square [r].
  static void draw(Canvas canvas, int c, int kind, Rect r, double dpr, {double opacity = 1}) {
    if (opacity <= 0.004 || r.width < 1) return;
    final img = _get(c, kind, r.width * dpr);
    _paint.color = Color.fromRGBO(255, 255, 255, opacity.clamp(0.0, 1.0));
    canvas.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), r, _paint);
  }

  static ui.Image _disc(int ci, double s) {
    final rec = ui.PictureRecorder();
    final cv = Canvas(rec);
    final c = Offset(s / 2, s / 2);
    final r = s / 2 * 0.96;
    final base = _gem(ci);
    final light = Color.lerp(base, Colors.white, 0.55)!;
    final dark = Color.lerp(base, Colors.black, 0.58)!;
    final bounds = Rect.fromCircle(center: c, radius: r);
    cv.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.45),
          radius: 1.05,
          colors: [light, base, dark],
          stops: const [0, 0.5, 1],
        ).createShader(bounds),
    );
    // Crown facets: alternating light / dark wedges around the table.
    const n = 12;
    for (var i = 0; i < n; i++) {
      final a0 = i * 2 * math.pi / n - math.pi / 2;
      final a1 = a0 + 2 * math.pi / n;
      final path = Path()
        ..moveTo(c.dx + math.cos(a0) * r * 0.64, c.dy + math.sin(a0) * r * 0.64)
        ..arcTo(bounds, a0, a1 - a0, false)
        ..lineTo(c.dx + math.cos(a1) * r * 0.64, c.dy + math.sin(a1) * r * 0.64)
        ..close();
      final lit = math.cos(a0 + math.pi / n + 2.3) * 0.5 + 0.5; // light from the top-left
      cv.drawPath(
        path,
        Paint()
          ..color = i.isEven
              ? Colors.white.withValues(alpha: 0.05 + 0.16 * lit)
              : Colors.black.withValues(alpha: 0.06 + 0.16 * (1 - lit)),
      );
    }
    final table = Rect.fromCircle(center: c, radius: r * 0.62);
    cv.drawCircle(
      c,
      r * 0.62,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.4, -0.5),
          radius: 1.1,
          colors: [Color.lerp(base, Colors.white, 0.35)!, base, Color.lerp(base, Colors.black, 0.3)!],
        ).createShader(table),
    );
    cv.drawCircle(
        c,
        r * 0.62,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.03
          ..color = Colors.white.withValues(alpha: 0.28));
    // Engraved mark.
    final m = _mark(ci, c, r * 0.3);
    cv.drawPath(m.shift(Offset(0, r * 0.025)), Paint()..color = Colors.white.withValues(alpha: 0.22));
    cv.drawPath(m, Paint()..color = Color.lerp(base, Colors.black, 0.5)!.withValues(alpha: 0.62));
    // Gold rim and specular glint.
    cv.drawCircle(
        c,
        r - r * 0.03,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.06
          ..color = Lux.goldLight.withValues(alpha: 0.55));
    cv.drawOval(
      Rect.fromCenter(center: c + Offset(-r * 0.3, -r * 0.42), width: r * 0.78, height: r * 0.36),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.42)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.06),
    );
    return rec.endRecording().toImageSync(s.toInt(), s.toInt());
  }

  static ui.Image _ghost(int ci, double s) {
    final rec = ui.PictureRecorder();
    final cv = Canvas(rec);
    final c = Offset(s / 2, s / 2);
    final r = s / 2 * 0.96;
    final base = _gem(ci);
    cv.drawCircle(c, r * 0.8, Paint()..color = base.withValues(alpha: 0.10));
    // Hollow faceted ring, broken into segments: reads as "only an outline".
    final ring = Rect.fromCircle(center: c, radius: r * 0.86);
    const n = 10;
    for (var i = 0; i < n; i++) {
      final a0 = i * 2 * math.pi / n - math.pi / 2 + 0.06;
      cv.drawArc(
        ring,
        a0,
        2 * math.pi / n - 0.12,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.2
          ..strokeCap = StrokeCap.butt
          ..color = Color.lerp(base, i.isEven ? Colors.white : Colors.black, 0.18)!,
      );
    }
    cv.drawCircle(
        c,
        r * 0.97,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.03
          ..color = Colors.white.withValues(alpha: 0.35));
    cv.drawCircle(
        c,
        r * 0.75,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.025
          ..color = Colors.white.withValues(alpha: 0.25));
    cv.drawPath(
        _mark(ci, c, r * 0.3),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.07
          ..strokeJoin = StrokeJoin.round
          ..color = base);
    return rec.endRecording().toImageSync(s.toInt(), s.toInt());
  }

  /// Gate band: gold outer bezel, faceted colour band with gold studs, inner gold bezel. The
  /// image's half-size is 1.42 disc radii.
  static ui.Image _gate(int ci, double s) {
    final rec = ui.PictureRecorder();
    final cv = Canvas(rec);
    final c = Offset(s / 2, s / 2);
    final u = s / 2 / 1.42;
    final base = _gem(ci);
    final light = Color.lerp(base, Colors.white, 0.45)!;
    final dark = Color.lerp(base, Colors.black, 0.5)!;
    Paint ring(double r0, double r1, Shader shader) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = r1 - r0
      ..shader = shader;
    final box = Rect.fromCircle(center: c, radius: 1.42 * u);
    cv.drawCircle(
      c,
      1.36 * u,
      ring(
          1.30 * u,
          1.42 * u,
          const SweepGradient(colors: [
            Color(0xFF7D5A1B), Color(0xFFF1D48B), Color(0xFFB98A35), Color(0xFFFBE7B0),
            Color(0xFF9C7228), Color(0xFFE3C278), Color(0xFF7D5A1B),
          ]).createShader(box)),
    );
    cv.drawCircle(
      c,
      1.17 * u,
      ring(
          1.04 * u,
          1.30 * u,
          SweepGradient(
            colors: [light, base, dark, base, light, base, dark, base, light],
          ).createShader(box)),
    );
    // Radial facet lines across the band.
    final facet = Paint()
      ..strokeWidth = u * 0.025
      ..color = Colors.black.withValues(alpha: 0.22);
    for (var i = 0; i < 16; i++) {
      final a = i * math.pi / 8;
      final d = Offset(math.cos(a), math.sin(a));
      cv.drawLine(c + d * (1.05 * u), c + d * (1.29 * u), facet);
    }
    // Inner glow of the band (gives it depth).
    cv.drawCircle(
        c,
        1.08 * u,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = u * 0.05
          ..color = Colors.white.withValues(alpha: 0.18));
    // Studs.
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4 + math.pi / 8;
      final p = c + Offset(math.cos(a), math.sin(a)) * (1.17 * u);
      cv.drawCircle(p, u * 0.065, Paint()..color = const Color(0xFF6F4F17));
      cv.drawCircle(p.translate(-u * 0.012, -u * 0.012), u * 0.05, Paint()..color = Lux.goldLight);
      cv.drawCircle(p.translate(-u * 0.022, -u * 0.022), u * 0.018, Paint()..color = Colors.white.withValues(alpha: 0.85));
    }
    cv.drawCircle(
        c,
        1.02 * u,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = u * 0.045
          ..color = Lux.gold);
    // Highlight across the upper-left of the band.
    cv.drawArc(
      Rect.fromCircle(center: c, radius: 1.22 * u),
      math.pi * 1.05,
      math.pi * 0.45,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = u * 0.07
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withValues(alpha: 0.32)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, u * 0.03),
    );
    return rec.endRecording().toImageSync(s.toInt(), s.toInt());
  }
}

class _ColorGates extends StatefulWidget {
  final GameSession session;
  const _ColorGates({super.key, required this.session});

  @override
  State<_ColorGates> createState() => _ColorGatesState();
}

class _ColorGatesState extends State<_ColorGates> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  final Stopwatch _clock = Stopwatch()..start();
  final _frame = _Frame();
  final _rng = math.Random();
  bool _paused = false;

  double get _now => _clock.elapsedMicroseconds / 1e6;
  GameSession get s => widget.session;

  // Previous state, for diffing.
  int _lastEv = 0;
  List<int> _pTp = const [];
  List<int> _pGates = const [];
  int _pSwap = 0;
  int _pLanes = 2;
  int _pCount = 0;
  String _pStatus = 'playing';
  final Map<int, int> _discColor = {};

  // Effects.
  final List<_Spark> _sparks = [];
  final List<_Exit> _exits = [];
  final Map<int, _GateTurn> _turns = {};
  final Map<int, double> _shakeAt = {};
  final Map<int, double> _tapAt = {};
  final Map<int, double> _flashAt = {};
  final Map<int, double> _changedAt = {};
  double _swapAt = -10;
  List<int> _swapPerm = const [];
  double _laneFrom = 2, _laneAt = -10;
  double _winAt = -10;
  double _lostAt = -10;
  double _livesHitAt = -10;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _snapshot();
    s.addListener(_onSession);
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    s.removeListener(_onSession);
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && !s.finished && s.state['phase'] == 'run') _setPaused(true);
  }

  void _setPaused(bool p) {
    if (_paused == p) return;
    setState(() => _paused = p);
  }

  String get _phase => s.state['phase'] as String? ?? 'intro';

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1000.0;
    _last = elapsed;
    final ph = _phase;
    final live = !_paused && !s.finished && !s.loading && (ph == 'countdown' || ph == 'run');
    if (live) {
      s.tick(dt.clamp(0, 100).toDouble());
    }
    final now = _now;
    _sparks.removeWhere((p) => now - p.born > p.life);
    _exits.removeWhere((e) => now - e.born > math.max(_crackDur, _passDur) + 0.1);
    if (!live) _frame.ping();
    if (s.finished && now - _winAt > _winDur && now - _lostAt > 1.0 && _sparks.isEmpty && _exits.isEmpty) {
      _ticker.stop();
    }
  }

  // ---- input ----

  void _tap(int lane) {
    if (_paused || s.finished || _phase != 'run') return;
    final lanes = (s.state['lanes'] as num?)?.toInt() ?? 2;
    if (lane < 0 || lane >= lanes) return;
    HapticFeedback.selectionClick();
    _tapAt[lane] = _now;
    s.act({'tap': lane});
  }

  // ---- state diffing ----

  void _snapshot() {
    final st = s.state;
    final ev = st['ev'] as List? ?? const [];
    for (final e in ev) {
      _lastEv = math.max(_lastEv, ((e as List)[0] as num).toInt());
    }
    _pTp = _ints(st['tp']);
    _pGates = _ints(st['gates']);
    _pLanes = (st['lanes'] as num?)?.toInt() ?? 2;
    _laneFrom = _pLanes.toDouble();
    final swd = _ints(st['swd']);
    _pSwap = swd.isNotEmpty ? swd[0] : 0;
    _pStatus = st['status'] as String? ?? 'playing';
  }

  void _onSession() {
    final st = s.state;
    final now = _now;
    // Countdown haptics.
    if (st['phase'] == 'countdown') {
      final k = (((st['cd'] as num?) ?? 0) / 1000).ceil();
      if (k != _pCount && k >= 1 && k <= 3) HapticFeedback.selectionClick();
      _pCount = k;
    }
    // Lane count (endless): slide the layout.
    final lanes = (st['lanes'] as num?)?.toInt() ?? 2;
    if (lanes != _pLanes) {
      _laneFrom = _laneVis(now);
      _laneAt = now;
      _pLanes = lanes;
    }
    final gates = _ints(st['gates']);
    final tp = _ints(st['tp']);
    // Swap: gates glide to their new lanes.
    final swd = _ints(st['swd']);
    if (swd.isNotEmpty && swd[0] != _pSwap) {
      _pSwap = swd[0];
      _swapAt = now - swd[1] / 1000.0;
      _swapPerm = swd.sublist(2);
      HapticFeedback.lightImpact();
    }
    // Taps: the gate turns from its previous colour.
    for (var i = 0; i < tp.length && i < gates.length; i++) {
      final before = i < _pTp.length ? _pTp[i] : 0;
      if (tp[i] != before && i < _pGates.length) {
        _turns[i] = _GateTurn(_pGates[i], gates[i], now);
      }
    }
    _pTp = tp;
    _pGates = gates;
    // Colour changes of falling discs (flash when a chameleon turns).
    final seen = <int>{};
    for (final row in st['d'] as List? ?? const []) {
      final r = row as List;
      final id = (r[0] as num).toInt();
      final c = (r[2] as num).toInt();
      seen.add(id);
      final prev = _discColor[id];
      if (prev != null && prev != c) _changedAt[id] = now;
      _discColor[id] = c;
    }
    _discColor.removeWhere((id, _) => !seen.contains(id));
    _changedAt.removeWhere((id, at) => now - at > 1);
    // Gate events.
    for (final e in st['ev'] as List? ?? const []) {
      final v = _ints(e);
      if (v[0] <= _lastEv) continue;
      _lastEv = v[0];
      _event(v[1], v[2], v[3], v[4] / 1000.0, now);
    }
    final status = st['status'] as String? ?? 'playing';
    if (status != _pStatus) {
      _pStatus = status;
      if (status == 'won') {
        _winAt = now;
        HapticFeedback.heavyImpact();
        _burstAll(now);
      } else if (status == 'lost') {
        _lostAt = now;
        HapticFeedback.mediumImpact();
      }
      if (!_ticker.isActive) _ticker.start();
    }
  }

  void _event(int lane, int kind, int color, double dur, double now) {
    _exits.add(_Exit(lane, color, kind, now, dur));
    if (kind == 0 || kind == 2) {
      HapticFeedback.lightImpact();
      _flashAt[lane] = now;
      final n = kind == 0 ? 14 : 8;
      for (var i = 0; i < n; i++) {
        final a = _rng.nextDouble() * math.pi * 2;
        final sp = 2.2 + _rng.nextDouble() * 3.4;
        final gold = kind == 2 || i % 3 != 0;
        _sparks.add(_Spark(
          lane,
          math.cos(a) * 1.05,
          math.sin(a) * 1.05,
          math.cos(a) * sp,
          math.sin(a) * sp - 1.2,
          now,
          _sparkLife * (0.6 + _rng.nextDouble() * 0.6),
          0.05 + _rng.nextDouble() * 0.07,
          gold ? (i.isEven ? Lux.goldLight : Lux.gold) : Color.lerp(_gem(color), Colors.white, 0.4)!,
        ));
      }
    } else {
      HapticFeedback.mediumImpact();
      _shakeAt[lane] = now;
      _livesHitAt = now;
    }
  }

  void _burstAll(double now) {
    final lanes = _pLanes;
    for (var l = 0; l < lanes; l++) {
      for (var i = 0; i < 18; i++) {
        final a = -math.pi / 2 + (_rng.nextDouble() - 0.5) * 2.2;
        final sp = 3 + _rng.nextDouble() * 5;
        _sparks.add(_Spark(l, 0, -1.2, math.cos(a) * sp, math.sin(a) * sp, now + _rng.nextDouble() * 0.25,
            0.9 + _rng.nextDouble() * 0.4, 0.05 + _rng.nextDouble() * 0.08, i.isEven ? Lux.goldLight : Lux.gold));
      }
    }
  }

  /// Visual lane count (animated when lanes join in endless).
  double _laneVis(double now) {
    final k = _ease((now - _laneAt) / _laneDur);
    return _laneFrom + (_pLanes - _laneFrom) * k;
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    final st = s.state;
    final phase = _phase;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final lanes = (st['lanes'] as num?)?.toInt() ?? 2;
    return Stack(
      children: [
        Column(
          children: [
            _hud(st),
            Expanded(
              child: LayoutBuilder(builder: (context, box) {
                final w = box.maxWidth;
                final h = box.maxHeight;
                return Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (e) => _tap((e.localPosition.dx / (w / lanes)).floor()),
                  child: RepaintBoundary(
                    child: CustomPaint(
                      size: Size(w, h),
                      painter: _BoardPainter(fx: this, st: st, dpr: dpr, repaint: _frame),
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 10),
          ],
        ),
        if (phase == 'countdown') Positioned.fill(child: IgnorePointer(child: _countdown(st))),
        if (phase == 'intro') Positioned.fill(child: _introCard(st)),
        if (_paused && phase == 'run' && !s.finished) Positioned.fill(child: _pauseCard()),
      ],
    );
  }

  Widget _hud(Map<String, dynamic> st) {
    final lives = (st['lives'] as num?)?.toInt() ?? 3;
    final maxLives = (st['max_lives'] as num?)?.toInt() ?? 3;
    final endless = st['mode'] == 'endless';
    final resolved = (st['resolved'] as num?)?.toInt() ?? 0;
    final total = (st['total'] as num?)?.toInt() ?? 0;
    final passed = (st['passed'] as num?)?.toInt() ?? 0;
    final streak = (st['streak'] as num?)?.toInt() ?? 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 12, 4),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: _frame,
            builder: (context, _) {
              final k = ((_now - _livesHitAt) / 0.5).clamp(0.0, 1.0);
              final shake = k < 1 ? math.sin(k * 30) * (1 - k) * 4 : 0.0;
              return Transform.translate(
                offset: Offset(shake, 0),
                child: Row(
                  children: [
                    for (var i = 0; i < maxLives; i++)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 260),
                          opacity: i < lives ? 1 : 0.28,
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CustomPaint(
                              painter: GemPainter(i < lives ? Lux.bordeaux : const Color(0xFF3A2A2E), glow: i < lives ? 0.5 : 0),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          Expanded(
            child: Column(
              children: [
                Text(endless ? '$passed' : '$resolved / $total',
                    style: Lux.numeral(24).copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                Text(endless ? 'GEÇEN DİSK' : 'DİSK', style: Lux.ui(10.5, color: Lux.muted, spacing: 1.4)),
              ],
            ),
          ),
          SizedBox(
            width: 64,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: streak >= 5 ? 1 : 0,
              child: Column(
                children: [
                  Text('$streak', style: Lux.numeral(20, color: Lux.gold)),
                  Text('SERİ', style: Lux.ui(10.5, color: Lux.muted, spacing: 1.4)),
                ],
              ),
            ),
          ),
          RimIconButton(_paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
              tooltip: _paused ? 'Devam' : 'Duraklat',
              onPressed: s.finished || _phase != 'run' ? null : () => _setPaused(!_paused)),
        ],
      ),
    );
  }

  Widget _countdown(Map<String, dynamic> st) {
    final ms = (st['cd'] as num?)?.toDouble() ?? 0;
    final k = (ms / 1000).ceil().clamp(1, 3);
    final p = ((k * 1000 - ms) / 1000).clamp(0.0, 1.0);
    final inT = Curves.easeOutBack.transform((p / 0.22).clamp(0.0, 1.0));
    final outT = Curves.easeInCubic.transform(((p - 0.62) / 0.38).clamp(0.0, 1.0));
    final scale = (0.55 + 0.45 * inT) * (1 + 0.5 * outT);
    final opacity = (p / 0.12).clamp(0.0, 1.0) * (1 - outT);
    final dim = k == 1 ? 1 - outT : 1.0;
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.3 * dim),
      child: Center(
        child: CustomPaint(
          painter: _CountRing(p),
          child: SizedBox(
            width: 200,
            height: 200,
            child: Center(
              child: Transform.scale(
                scale: scale,
                child: Opacity(opacity: opacity, child: Text('$k', style: Lux.display(104, color: Lux.goldLight))),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _introCard(Map<String, dynamic> st) {
    final notes = [for (final n in st['notes'] as List? ?? const []) n as String];
    final k = (st['k'] as num?)?.toInt() ?? 3;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final endless = st['mode'] == 'endless';
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => ColoredBox(
        color: Colors.black.withValues(alpha: 0.55 * t),
        child: Opacity(opacity: t, child: Transform.scale(scale: 0.95 + 0.05 * t, child: child)),
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: LuxCard(
            highlight: true,
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(Lux.upper(endless ? 'Sonsuz yağmur' : (st['title'] as String? ?? 'Renk Kapıları')),
                    textAlign: TextAlign.center, style: Lux.display(22, spacing: 1.5)),
                const SizedBox(height: 14),
                for (final n in notes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 8, right: 8),
                          child: Container(
                              width: 5, height: 5, decoration: const BoxDecoration(color: Lux.gold, shape: BoxShape.circle)),
                        ),
                        Expanded(child: Text(n, style: Lux.ui(15.5, weight: FontWeight.w500))),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                Text('KAPI SIRASI', style: Lux.ui(11, color: Lux.gold, weight: FontWeight.w600, spacing: 2)),
                const SizedBox(height: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < k; i++) ...[
                      SizedBox(width: 30, height: 30, child: CustomPaint(painter: _GemIcon(i, dpr))),
                      if (i < k - 1)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: Icon(Icons.chevron_right_rounded, size: 18, color: Lux.gold.withValues(alpha: 0.7)),
                        ),
                    ],
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Icon(Icons.replay_rounded, size: 16, color: Lux.muted.withValues(alpha: 0.8)),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
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

  Widget _pauseCard() {
    return ColoredBox(
      color: const Color(0xE6031A12),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(Lux.upper('Duraklatıldı'), style: Lux.display(20)),
            const SizedBox(height: 16),
            GoldButton('Devam', icon: Icons.play_arrow_rounded, onPressed: () => _setPaused(false)),
          ],
        ),
      ),
    );
  }
}

/// Small disc icon (intro legend).
class _GemIcon extends CustomPainter {
  final int color;
  final double dpr;
  _GemIcon(this.color, this.dpr);

  @override
  void paint(Canvas canvas, Size size) => _Jewels.draw(canvas, color, 0, Offset.zero & size, dpr);

  @override
  bool shouldRepaint(_GemIcon old) => old.color != color;
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
    canvas.drawCircle(c, r, _paint..strokeWidth = 1.2..color = Lux.gold.withValues(alpha: 0.18 * fade));
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), -math.pi / 2, 2 * math.pi * Curves.easeInOut.transform(p), false,
        _paint..strokeWidth = 2.4..color = Lux.goldLight.withValues(alpha: 0.75 * fade));
  }

  @override
  bool shouldRepaint(_CountRing old) => old.p != p;
}

class _BoardPainter extends CustomPainter {
  final _ColorGatesState fx;
  final Map<String, dynamic> st;
  final double dpr;
  _BoardPainter({required this.fx, required this.st, required this.dpr, required Listenable repaint})
      : super(repaint: repaint);

  static final Paint _p = Paint();
  static final Paint _stroke = Paint()..style = PaintingStyle.stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final now = fx._now;
    final lanes = (st['lanes'] as num?)?.toInt() ?? 2;
    final k = (st['k'] as num?)?.toInt() ?? 3;
    final gates = _ints(st['gates']);
    final t = (st['t'] as num?)?.toDouble() ?? 0;
    final nVis = fx._laneVis(now);
    final w = size.width;
    final h = size.height;
    final laneW = w / nVis;
    // Disc radius and the vertical path.
    final r = math.min(laneW * 0.28, h * 0.05).clamp(10.0, 60.0);
    final gateR = r * 1.42;
    final previewR = r * 0.36;
    final gy = h - previewR * 2 - r * 0.55 - gateR;
    final y0 = r * 1.1;
    double laneX(int i) => laneW * (i + 0.5);
    double laneAlpha(int i) => i < nVis.floor() ? 1.0 : (nVis - i).clamp(0.0, 1.0);
    double shake(int lane) {
      final at = fx._shakeAt[lane];
      if (at == null) return 0;
      final q = (now - at) / _shakeDur;
      if (q < 0 || q >= 1) return 0;
      return math.sin(q * math.pi * 7) * (1 - q) * r * 0.22;
    }

    // Gate positions (swap glide).
    final swapK = (now - fx._swapAt) / _swapDur;
    Offset gatePos(int i) {
      final base = Offset(laneX(i) + shake(i), gy);
      if (swapK >= 0 && swapK < 1 && i < fx._swapPerm.length && fx._swapPerm[i] != i) {
        final e = Curves.easeInOutCubic.transform(swapK);
        final from = laneX(fx._swapPerm[i]);
        return Offset(from + (base.dx - from) * e, gy - math.sin(math.pi * e) * r * 1.3);
      }
      return base;
    }

    // 1. Lane glow on tap.
    for (var i = 0; i < lanes; i++) {
      final at = fx._tapAt[i];
      if (at == null) continue;
      final q = (now - at) / _tapGlow;
      if (q < 0 || q >= 1) continue;
      final rect = Rect.fromLTWH(laneX(i) - laneW / 2, 0, laneW, h);
      _p.color = Colors.white;
      _p.shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [Lux.goldLight.withValues(alpha: 0.10 * (1 - q)), Lux.gold.withValues(alpha: 0)],
      ).createShader(rect);
      canvas.drawRect(rect, _p);
      _p.shader = null;
    }

    // 2. Rods.
    for (var i = 0; i < lanes; i++) {
      final a = laneAlpha(i);
      if (a <= 0) continue;
      final x = laneX(i) + shake(i);
      final gc = i < gates.length ? _gem(gates[i]) : Lux.gold;
      _rod(canvas, x, r * 0.2, gy - gateR * 0.9, math.max(6.0, r * 0.34), gc, a);
    }

    // 3. Swap warning: gold arcs from each moving gate to its destination.
    final sw = _ints(st['sw']);
    if (sw.isNotEmpty) {
      final until = sw[0] / 1000.0;
      final perm = sw.sublist(1);
      final pulse = 0.55 + 0.45 * math.sin(now * 14);
      final strength = (1 - until).clamp(0.25, 1.0);
      for (var i = 0; i < perm.length && i < lanes; i++) {
        if (perm[i] == i) continue;
        final from = Offset(laneX(perm[i]), gy - gateR * 1.15);
        final to = Offset(laneX(i), gy - gateR * 1.15);
        final mid = Offset((from.dx + to.dx) / 2, gy - gateR * 1.15 - r * 1.6 - (to.dx - from.dx).abs() * 0.12);
        final path = Path()
          ..moveTo(from.dx, from.dy)
          ..quadraticBezierTo(mid.dx, mid.dy, to.dx, to.dy);
        _dashed(canvas, path, Lux.goldLight.withValues(alpha: 0.75 * strength * pulse), r * 0.09);
        // Arrow head at the destination.
        final dir = (to - mid);
        final ang = math.atan2(dir.dy, dir.dx);
        final head = Path()
          ..moveTo(to.dx, to.dy)
          ..lineTo(to.dx - math.cos(ang - 0.45) * r * 0.42, to.dy - math.sin(ang - 0.45) * r * 0.42)
          ..lineTo(to.dx - math.cos(ang + 0.45) * r * 0.42, to.dy - math.sin(ang + 0.45) * r * 0.42)
          ..close();
        _p.color = Lux.goldLight.withValues(alpha: 0.85 * strength * pulse);
        canvas.drawPath(head, _p);
      }
    }

    // 4. Gate halos and portal interiors (behind the discs).
    for (var i = 0; i < lanes && i < gates.length; i++) {
      final a = laneAlpha(i);
      if (a <= 0) continue;
      final c = gatePos(i);
      final gc = _gem(gates[i]);
      final flash = fx._flashAt[i];
      final fq = flash == null ? 1.0 : ((now - flash) / 0.35).clamp(0.0, 1.0);
      _stroke
        ..strokeWidth = r * 0.5
        ..color = gc.withValues(alpha: (0.22 + 0.45 * (1 - fq)) * a)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * (0.45 + 0.4 * (1 - fq)));
      canvas.drawCircle(c, gateR * 0.98, _stroke);
      _stroke.maskFilter = null;
      _p.color = Colors.white;
      _p.shader = RadialGradient(
        colors: [Color.lerp(gc, Colors.black, 0.72)!.withValues(alpha: a), const Color(0xFF020C08).withValues(alpha: a)],
      ).createShader(Rect.fromCircle(center: c, radius: r * 1.04));
      canvas.drawCircle(c, r * 1.04, _p);
      _p.shader = null;
      // Engraved mark of the gate colour, faint (the band carries the colour).
      _p.color = gc.withValues(alpha: 0.38 * a);
      canvas.drawPath(_mark(gates[i], c, r * 0.36), _p);
    }

    // 5. Discs.
    final discs = st['d'] as List? ?? const [];
    final pathLen = gy - y0;
    for (final row in discs) {
      final d = row as List;
      final id = (d[0] as num).toInt();
      final lane = (d[1] as num).toInt();
      final col = (d[2] as num).toInt();
      final flags = (d[3] as num).toInt();
      final spawn = (d[5] as num).toDouble();
      final dur = math.max(1.0, (d[6] as num).toDouble());
      final chMs = (d[7] as num).toDouble();
      final next = (d[8] as num).toInt();
      final p = ((t - spawn) / dur).clamp(0.0, 1.0);
      final x = laneX(lane) + shake(lane);
      final y = y0 + pathLen * p;
      final ghost = flags & 1 != 0;
      final a = laneAlpha(lane) * (p < 0.06 ? p / 0.06 : 1.0);
      final speed = pathLen / dur; // px per ms
      // Motion trail: longer at speed.
      final trail = (speed * 70).clamp(0.0, r * 2.4);
      if (trail > r * 0.3) {
        final tr = Rect.fromLTRB(x - r * 0.62, y - r * 0.2 - trail, x + r * 0.62, y);
        _p.color = Colors.white;
        _p.shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [_gem(col).withValues(alpha: (ghost ? 0.12 : 0.3) * a), _gem(col).withValues(alpha: 0)],
        ).createShader(tr);
        canvas.drawRRect(RRect.fromRectAndRadius(tr, Radius.circular(r * 0.6)), _p);
        _p.shader = null;
      }
      final rect = Rect.fromCircle(center: Offset(x, y), radius: r);
      // Shimmer warning: the next colour glows around and grows inside the disc.
      if (flags & 2 != 0 && next >= 0) {
        final q = (1 - chMs / 600).clamp(0.0, 1.0);
        final pulse = 0.5 + 0.5 * math.sin(now * 26);
        _p.color = _gem(next).withValues(alpha: (0.25 + 0.35 * pulse) * a);
        _p.maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.35);
        canvas.drawCircle(Offset(x, y), r * (1.1 + 0.15 * pulse), _p);
        _p.maskFilter = null;
        _Jewels.draw(canvas, col, ghost ? 1 : 0, rect, dpr, opacity: a);
        canvas.save();
        canvas.translate(x, y);
        canvas.rotate(now * 7);
        _stroke
          ..strokeWidth = r * 0.16
          ..color = _gem(next).withValues(alpha: 0.9 * a);
        for (var j = 0; j < 3; j++) {
          canvas.drawArc(Rect.fromCircle(center: Offset.zero, radius: r * 0.82), j * math.pi * 2 / 3, math.pi / 3, false, _stroke);
        }
        canvas.restore();
        final inner = r * (0.25 + 0.4 * q);
        _Jewels.draw(canvas, next, 0, Rect.fromCircle(center: Offset(x, y), radius: inner), dpr, opacity: a * (0.6 + 0.4 * q));
      } else {
        _Jewels.draw(canvas, col, ghost ? 1 : 0, rect, dpr, opacity: a);
        final changed = fx._changedAt[id];
        if (changed != null && now - changed < 0.25) {
          final q = (now - changed) / 0.25;
          _stroke
            ..strokeWidth = r * 0.12 * (1 - q)
            ..color = Colors.white.withValues(alpha: 0.8 * (1 - q));
          canvas.drawCircle(Offset(x, y), r * (1 + 0.5 * q), _stroke);
        }
      }
    }

    // 6. Exits: passing discs sink through the portal, ghosts mist away (drawn under the band).
    for (final e in fx._exits) {
      final q = (now - e.born) / _passDur;
      if (q < 0 || q >= 1 || e.lane >= lanes) continue;
      final c = gatePos(e.lane);
      if (e.kind == 0) {
        final y = c.dy + (pathLen / (e.dur * 1000)) * (now - e.born) * 1000;
        final rr = r * (1 - 0.35 * q);
        canvas.save();
        canvas.clipRect(Rect.fromLTRB(0, c.dy - r * 1.5, w, h));
        _Jewels.draw(canvas, e.color, 0, Rect.fromCircle(center: Offset(c.dx, y), radius: rr), dpr, opacity: 1 - q);
        canvas.restore();
      } else if (e.kind == 2) {
        final rr = r * (1 + 0.6 * q);
        _Jewels.draw(canvas, e.color, 1, Rect.fromCircle(center: c, radius: rr), dpr, opacity: (1 - q) * 0.8);
      }
    }

    // 7. Gate bands (in front of the discs: the disc enters the ring).
    for (var i = 0; i < lanes && i < gates.length; i++) {
      final a = laneAlpha(i);
      if (a <= 0) continue;
      final c = gatePos(i);
      final rect = Rect.fromCircle(center: c, radius: gateR);
      final flash = fx._flashAt[i];
      final fq = flash == null ? 1.0 : ((now - flash) / 0.35).clamp(0.0, 1.0);
      final turn = fx._turns[i];
      final tq = turn == null ? 1.0 : (now - turn.born) / _gateTurn;
      if (turn != null && tq >= 0 && tq < 1) {
        // Turn by an eighth with a little overshoot; the colour crossfades in the first 45%.
        final rot = Curves.easeOutBack.transform(tq) * math.pi / 4;
        final mix = (tq / 0.45).clamp(0.0, 1.0);
        canvas.save();
        canvas.translate(c.dx, c.dy);
        canvas.rotate(rot - math.pi / 4);
        final rr = Rect.fromCircle(center: Offset.zero, radius: gateR * (1 + 0.06 * math.sin(math.pi * tq)));
        _Jewels.draw(canvas, turn.from, 2, rr, dpr, opacity: a * (1 - mix));
        _Jewels.draw(canvas, gates[i], 2, rr, dpr, opacity: a * mix);
        canvas.restore();
      } else {
        _Jewels.draw(canvas, gates[i], 2, rect, dpr, opacity: a);
      }
      if (fq < 1) {
        _stroke
          ..strokeWidth = r * 0.14 * (1 - fq)
          ..color = Lux.goldLight.withValues(alpha: 0.9 * (1 - fq) * a);
        canvas.drawCircle(c, gateR * (1 + 0.25 * fq), _stroke);
      }
      // Next colour preview.
      final nc = (gates[i] + 1) % k;
      final pc = Offset(c.dx, c.dy + gateR + r * 0.3 + previewR);
      _p.color = Lux.gold.withValues(alpha: 0.5 * a);
      final tip = Path()
        ..moveTo(pc.dx - previewR * 0.35, pc.dy - previewR * 1.55)
        ..lineTo(pc.dx + previewR * 0.35, pc.dy - previewR * 1.55)
        ..lineTo(pc.dx, pc.dy - previewR * 1.18)
        ..close();
      canvas.drawPath(tip, _p);
      _Jewels.draw(canvas, nc, 0, Rect.fromCircle(center: pc, radius: previewR), dpr, opacity: 0.85 * a);
    }

    // 8. Errors: crack lines and shards over the gate.
    for (final e in fx._exits) {
      if (e.kind != 1 && e.kind != 3) continue;
      final q = (now - e.born) / _crackDur;
      if (q < 0 || q >= 1 || e.lane >= lanes) continue;
      final c = gatePos(e.lane);
      final rnd = math.Random(e.born.hashCode ^ e.lane);
      final grow = _ease(q / 0.25);
      final fade = q < 0.55 ? 1.0 : 1 - (q - 0.55) / 0.45;
      _p.color = Lux.bordeaux.withValues(alpha: 0.45 * fade);
      _p.maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.5);
      canvas.drawCircle(c, gateR * 1.1, _p);
      _p.maskFilter = null;
      _stroke
        ..strokeWidth = math.max(1.2, r * 0.07)
        ..strokeJoin = StrokeJoin.round
        ..color = Lux.bordeauxLight.withValues(alpha: 0.95 * fade);
      for (var j = 0; j < 7; j++) {
        final a0 = j * math.pi * 2 / 7 + rnd.nextDouble() * 0.6;
        final path = Path()..moveTo(c.dx + math.cos(a0) * r * 0.2, c.dy + math.sin(a0) * r * 0.2);
        var a = a0;
        final len = gateR * (0.9 + rnd.nextDouble() * 0.5) * grow;
        for (var s = 1; s <= 4; s++) {
          a += (rnd.nextDouble() - 0.5) * 0.7;
          final d = len * s / 4;
          path.lineTo(c.dx + math.cos(a) * d, c.dy + math.sin(a) * d);
        }
        canvas.drawPath(path, _stroke);
      }
      // Shards of the failed disc.
      final gq = (now - e.born);
      for (var j = 0; j < 7; j++) {
        final a = rnd.nextDouble() * math.pi * 2;
        final sp = r * (4 + rnd.nextDouble() * 5);
        final sx = c.dx + math.cos(a) * sp * gq;
        final sy = c.dy - r * 0.6 + math.sin(a) * sp * gq + 0.5 * r * 22 * gq * gq;
        final sz = r * (0.16 + rnd.nextDouble() * 0.14);
        canvas.save();
        canvas.translate(sx, sy);
        canvas.rotate(gq * 9 + j);
        _p.color = _gem(e.color).withValues(alpha: (e.kind == 3 ? 0.55 : 0.95) * fade);
        canvas.drawPath(
            Path()
              ..moveTo(0, -sz)
              ..lineTo(sz * 0.8, sz * 0.6)
              ..lineTo(-sz * 0.7, sz * 0.5)
              ..close(),
            _p);
        canvas.restore();
      }
    }

    // 9. Sparks.
    for (final sp in fx._sparks) {
      final age = now - sp.born;
      if (age < 0 || sp.lane >= lanes) continue;
      final q = age / sp.life;
      if (q >= 1) continue;
      final c = gatePos(sp.lane);
      final x = c.dx + (sp.dx + sp.vx * age) * r;
      final y = c.dy + (sp.dy + sp.vy * age + 0.5 * 6 * age * age) * r;
      _p.color = sp.color.withValues(alpha: (1 - q) * (1 - q));
      canvas.drawCircle(Offset(x, y), sp.size * r * (1 - 0.4 * q), _p);
    }

    // 10. Win: a gold wave climbs every rod.
    final wq = (now - fx._winAt) / _winDur;
    if (wq >= 0 && wq < 1) {
      for (var i = 0; i < lanes; i++) {
        final x = laneX(i);
        final yy = gy - (gy + r * 2) * _ease(wq);
        final rect = Rect.fromLTRB(x - laneW * 0.4, yy - r * 3, x + laneW * 0.4, yy + r * 3);
        _p.color = Colors.white;
        _p.shader = RadialGradient(
          colors: [Lux.goldLight.withValues(alpha: 0.5 * (1 - wq)), Lux.gold.withValues(alpha: 0)],
        ).createShader(rect);
        canvas.drawOval(rect, _p);
        _p.shader = null;
      }
    }
  }

  /// Gold-inlaid glass rod from [top] to [bottom] at [x], tinted near the gate with [gc].
  void _rod(Canvas canvas, double x, double top, double bottom, double rw, Color gc, double a) {
    final rect = Rect.fromLTRB(x - rw / 2, top, x + rw / 2, bottom);
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(rw / 2));
    // Soft luminous halo around the glass.
    _p.color = const Color(0xFF7FD6A4).withValues(alpha: 0.10 * a);
    _p.maskFilter = MaskFilter.blur(BlurStyle.normal, rw * 0.9);
    canvas.drawRRect(rr.inflate(rw * 0.4), _p);
    _p.maskFilter = null;
    // Glass body: dark edges, a lit core.
    _p.color = Colors.white;
    _p.shader = LinearGradient(
      colors: [
        const Color(0xFF0B2A20).withValues(alpha: 0.9 * a),
        const Color(0xFF3E8A6E).withValues(alpha: 0.55 * a),
        const Color(0xFF1C5A45).withValues(alpha: 0.5 * a),
        const Color(0xFF041510).withValues(alpha: 0.92 * a),
      ],
      stops: const [0, 0.32, 0.55, 1],
    ).createShader(rect);
    canvas.drawRRect(rr, _p);
    // The gate colour rises faintly up the rod (links lane and gate at a glance).
    final tint = Rect.fromLTRB(rect.left, bottom - (bottom - top) * 0.45, rect.right, bottom);
    _p.color = Colors.white;
    _p.shader = LinearGradient(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: [gc.withValues(alpha: 0.55 * a), gc.withValues(alpha: 0)],
    ).createShader(tint);
    canvas.drawRRect(RRect.fromRectAndRadius(tint, Radius.circular(rw / 2)), _p);
    _p.shader = null;
    // Glass highlight streak.
    _p.color = Colors.white.withValues(alpha: 0.24 * a);
    canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTRB(x - rw * 0.3, top + rw, x - rw * 0.1, bottom - rw), Radius.circular(rw)), _p);
    // Gold inlay hairlines.
    _p.color = Colors.white;
    _p.shader = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Lux.goldDeep.withValues(alpha: 0.2 * a), Lux.goldLight.withValues(alpha: 0.85 * a), Lux.gold.withValues(alpha: 0.9 * a)],
    ).createShader(rect);
    final hw = math.max(1.2, rw * 0.12);
    canvas.drawRect(Rect.fromLTWH(rect.left - hw * 0.5, top, hw, bottom - top), _p);
    canvas.drawRect(Rect.fromLTWH(rect.right - hw * 0.5, top, hw, bottom - top), _p);
    _p.shader = null;
    // Gold collars along the rod.
    const n = 5;
    for (var j = 1; j < n; j++) {
      final y = top + (bottom - top) * j / n;
      final collar = Rect.fromCenter(center: Offset(x, y), width: rw * 1.7, height: rw * 0.42);
      _p.color = Colors.white;
      _p.shader = Lux.foil.createShader(collar);
      _p.color = Colors.white.withValues(alpha: a);
      canvas.drawRRect(RRect.fromRectAndRadius(collar, Radius.circular(rw * 0.2)), _p);
      _p.shader = null;
    }
  }

  void _dashed(Canvas canvas, Path path, Color color, double width) {
    _stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..color = color;
    for (final m in path.computeMetrics()) {
      final dash = width * 2.6;
      for (var d = 0.0; d < m.length; d += dash * 2) {
        canvas.drawPath(m.extractPath(d, math.min(d + dash, m.length)), _stroke);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
