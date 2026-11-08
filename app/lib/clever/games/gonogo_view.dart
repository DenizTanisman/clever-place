import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// Dur ya da Geç: one big stage that is entirely a touch target. A pearl shape appears in the centre,
/// round or square; it may carry an emerald or burgundy arrow. Round = tap, square = do nothing,
/// emerald arrow = swipe that way, burgundy arrow = swipe the other way. The rules and timing live in
/// Rust (`judge`); this widget only turns pointer events into `press` / `tap` / `swipe` actions.
///
/// Input: a raw pointer-down sends `press` (inside a window it buys the core's grace time). Moving
/// past a small threshold commits a swipe in the dominant direction at once; lifting without moving
/// commits a tap. A pointer that lands during the gap is an early response, sent at pointer-down. If
/// the trial ended while the finger was down (timed out), the release is dropped so one slow tap is
/// never punished twice.
///
/// Feedback: a correct answer pops the shape (a swiped shape flies off in the swipe direction) with a
/// gold ring; an error flashes the stage bordeaux, shakes the shape, names the mistake and, on arrow
/// trials, shows the right direction as a small gold arrow.
Widget gonogoView(BuildContext context, GameSession s) => _GoNoGoBoard(key: ObjectKey(s), session: s);

const _pearl = Color(0xFFEDE6D2);
const _emerald = Color(0xFF1E9E66);
const _emeraldLight = Color(0xFF7FD6A4);
const _burgundy = Color(0xFF8B1E3F);
const _burgundyLight = Color(0xFFD9708E);

const _goodResults = {'hit', 'swipe_ok', 'reject'};

double _num(Object? v, [double d = 0]) => (v as num?)?.toDouble() ?? d;

/// Unit vector of a direction key (screen coordinates, y down).
Offset _dirVec(String? dir) => switch (dir) {
      'up' => const Offset(0, -1),
      'down' => const Offset(0, 1),
      'left' => const Offset(-1, 0),
      _ => const Offset(1, 0),
    };

class _Fb {
  final String result;
  final double at;
  final Map<String, dynamic>? stim;
  final String? input;
  final String? wantDir;
  const _Fb(this.result, this.at, this.stim, this.input, this.wantDir);
  bool get good => _goodResults.contains(result);
}

class _GoNoGoBoard extends StatefulWidget {
  final GameSession session;
  const _GoNoGoBoard({super.key, required this.session});

  @override
  State<_GoNoGoBoard> createState() => _GoNoGoBoardState();
}

class _GoNoGoBoardState extends State<_GoNoGoBoard> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;

  int _fbSerial = 0;
  _Fb? _fb;
  Map<String, dynamic>? _lastStim;
  int _lastCount = 0;
  int _lives = 3;
  double _lifeLostAt = -10;
  double _doneAt = -1;

  // The one pointer we follow.
  int? _pointer;
  Offset _downAt = Offset.zero;
  int _downTrial = -1;
  bool _consumed = false;

  GameSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    _fbSerial = ((s.state['fb'] as Map?)?['serial'] as num?)?.toInt() ?? 0;
    _lives = (s.state['lives'] as num?)?.toInt() ?? 3;
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  static const _timed = {'countdown', 'run'};

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1000.0;
    _last = elapsed;
    final phase = s.state['phase'] as String? ?? 'intro';
    if (!s.finished && _timed.contains(phase)) {
      s.tick(dt.clamp(0, 50).toDouble());
    } else {
      final now = _now;
      final busy = (_fb != null && now - _fb!.at < 0.8) || (_doneAt >= 0 && now - _doneAt < 1.2);
      if (busy) {
        setState(() {});
      } else if (s.finished) {
        _ticker.stop();
      }
    }
  }

  // ------------------------------------------------------------------ input

  int get _trial => (s.state['trial'] as num?)?.toInt() ?? 0;

  void _down(PointerDownEvent e) {
    if (_pointer != null) return;
    final st = s.state;
    if (s.finished || st['phase'] != 'run') return;
    _pointer = e.pointer;
    _downAt = e.localPosition;
    _downTrial = _trial;
    _consumed = false;
    if (st['stage'] == 'window') {
      s.act({'press': true});
    } else {
      // Nothing on screen yet: this is an early response, judged right away.
      _consumed = true;
      s.act({'tap': true});
    }
  }

  void _move(PointerMoveEvent e, double threshold) {
    if (e.pointer != _pointer || _consumed) return;
    final d = e.localPosition - _downAt;
    if (d.distance < threshold) return;
    _consumed = true;
    if (_trial != _downTrial || s.finished) return;
    final dir = d.dx.abs() >= d.dy.abs() ? (d.dx > 0 ? 'right' : 'left') : (d.dy > 0 ? 'down' : 'up');
    s.act({'swipe': dir});
  }

  void _up(PointerEvent e, {bool cancel = false}) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    if (_consumed || cancel) return;
    _consumed = true;
    // The trial timed out while the finger was down: drop the release.
    if (_trial != _downTrial || s.finished || s.state['phase'] != 'run') return;
    s.act({'tap': true});
  }

  // ------------------------------------------------------------------ sync

  void _sync(Map<String, dynamic> st, double now) {
    final stim = st['stim'];
    if (stim is Map) _lastStim = Map<String, dynamic>.from(stim);
    final fb = st['fb'];
    if (fb is Map) {
      final serial = (fb['serial'] as num?)?.toInt() ?? 0;
      if (serial != _fbSerial && serial > 0) {
        _fbSerial = serial;
        final result = fb['result'] as String? ?? '';
        _fb = _Fb(result, now, result == 'early' ? null : _lastStim, fb['input'] as String?, fb['dir'] as String?);
        if (result == 'hit' || result == 'swipe_ok') {
          HapticFeedback.lightImpact();
        } else if (!_goodResults.contains(result)) {
          HapticFeedback.mediumImpact();
        }
      }
    }
    final lives = (st['lives'] as num?)?.toInt();
    if (lives != null && lives < _lives) _lifeLostAt = now;
    if (lives != null) _lives = lives;
    if (st['phase'] == 'countdown') {
      final k = (_num(st['countdown_ms']) / 1000).ceil();
      if (k != _lastCount && k >= 1 && k <= 3) HapticFeedback.selectionClick();
      _lastCount = k;
    }
    if (st['phase'] == 'done' && _doneAt < 0) {
      _doneAt = now;
      if (st['status'] == 'won') HapticFeedback.heavyImpact();
    }
  }

  // ------------------------------------------------------------------ build

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
            Expanded(
              child: LayoutBuilder(builder: (context, box) {
                final size = Size(box.maxWidth, box.maxHeight);
                final threshold = math.max(22.0, size.shortestSide * 0.05);
                return Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _down,
                  onPointerMove: (e) => _move(e, threshold),
                  onPointerUp: _up,
                  onPointerCancel: (e) => _up(e, cancel: true),
                  child: CustomPaint(size: size, painter: _StagePainter(st: st, fb: _fb, now: now)),
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

  Widget _header(Map<String, dynamic> st, double now) {
    final endless = st['mode'] == 'endless';
    final trial = (st['trial'] as num?)?.toInt() ?? 1;
    final trials = (st['trials'] as num?)?.toInt() ?? 20;
    final phase = st['phase'] as String? ?? 'intro';
    final lives = (st['lives'] as num?)?.toInt() ?? 0;
    final progress = endless ? 0.0 : ((trial - 1) / trials).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 4),
      child: Column(
        children: [
          Row(
            children: [
              if (endless) ...[
                FoilText('${(st['score'] as num?)?.toInt() ?? 0}',
                    style: Lux.ui(30, weight: FontWeight.w700)
                        .copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                const SizedBox(width: 12),
                for (var i = 0; i < 3; i++) _LifeGem(alive: i < lives, justLost: i == lives && now - _lifeLostAt < 0.5),
              ] else
                Text(phase == 'intro' ? '$trials uyaran' : '${math.min(trial, trials)} / $trials',
                    style: Lux.ui(17, weight: FontWeight.w700)),
              const Spacer(),
              Flexible(
                child: Text(st['title'] as String? ?? '',
                    overflow: TextOverflow.ellipsis, style: Lux.ui(14, color: Lux.goldLight, weight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!endless)
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                height: 5,
                child: Stack(
                  children: [
                    const Positioned.fill(child: ColoredBox(color: Color(0xFF0A2A20))),
                    AnimatedFractionallySizedBox(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      widthFactor: progress,
                      alignment: Alignment.centerLeft,
                      child: const DecoratedBox(decoration: BoxDecoration(gradient: Lux.goldGradient)),
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
    final stats = st['stats'] is Map ? st['stats'] as Map : const {};
    final rules = st['rules'] is Map ? st['rules'] as Map : const {};
    final rt = st['mean_rt'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _RuleLegend(arrows: rules['arrows'] == true, burgundy: rules['burgundy'] == true),
          const SizedBox(height: 8),
          Text(
            'Yanlış ${stats['false_responses'] ?? 0} · Kaçan ${stats['omissions'] ?? 0}'
            '${rt is num ? ' · ${rt.round()} ms' : ''}',
            style: Lux.ui(13, color: Lux.muted).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ],
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
    final endless = st['mode'] == 'endless';
    final rules = st['rules'] is Map ? st['rules'] as Map : const {};
    final arrows = endless || rules['arrows'] == true;
    final burgundy = endless || rules['burgundy'] == true;
    final lures = rules['lures'] == true;
    final fresh = {for (final r in (st['new_rules'] as List? ?? const [])) r as String};
    final features = [for (final f in (st['features'] as List? ?? const [])) f as String];
    final goal = st['rt_goal'];
    final rows = <Widget>[
      const _RuleRow(icon: _StimIcon(round: true), text: 'Yuvarlak: ekrana dokun'),
      _RuleRow(
        icon: _StimIcon(round: false, arrow: lures ? 'up' : null, emerald: true),
        text: lures ? 'Köşeli: hiçbir şey yapma, üstünde ok olsa bile' : 'Köşeli: hiçbir şey yapma',
        isNew: fresh.contains('lures'),
      ),
      if (arrows)
        _RuleRow(
          icon: const _StimIcon(round: true, arrow: 'right', emerald: true),
          text: 'Zümrüt ok: okun gösterdiği yöne kaydır',
          isNew: fresh.contains('arrows'),
        ),
      if (burgundy)
        _RuleRow(
          icon: const _StimIcon(round: true, arrow: 'right', emerald: false),
          text: 'Bordo ok: tam tersi yöne kaydır',
          isNew: fresh.contains('burgundy'),
        ),
    ];
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
          padding: const EdgeInsets.all(20),
          child: LuxCard(
            highlight: true,
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(Lux.upper(endless ? 'Sonsuz akış' : st['title'] as String? ?? 'Dur ya da geç'),
                    textAlign: TextAlign.center, style: Lux.display(22, spacing: 1.5)),
                const SizedBox(height: 14),
                ...rows,
                const SizedBox(height: 6),
                Text(
                  endless
                      ? 'Her hata bir can götürür; 3 can. Doğru gittikçe akış hızlanır, hata yapınca yavaşlar.'
                      : 'Bir tepki yetişmezse "kaçırdın" sayılır. Emin değilsen köşelide elini çekmek her zaman doğrudur.',
                  textAlign: TextAlign.center,
                  style: Lux.ui(14, color: Lux.ink),
                ),
                if (!endless) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Yıldız: doğruluk %90 ve ort. tepki ${goal is num ? '${goal.round()} ms' : ''} altı 3 · %80 2 · %70 1',
                    textAlign: TextAlign.center,
                    style: Lux.ui(13, color: Lux.muted),
                  ),
                ],
                if (features.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    alignment: WrapAlignment.center,
                    children: [
                      for (final f in features)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: f.startsWith('Yeni') ? Lux.goldLight : Lux.line),
                          ),
                          child: Text(f, style: Lux.ui(12, color: Lux.goldLight)),
                        ),
                    ],
                  ),
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

// ------------------------------------------------------------------ small widgets

class _RuleRow extends StatelessWidget {
  final Widget icon;
  final String text;
  final bool isNew;
  const _RuleRow({required this.icon, required this.text, this.isNew = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(width: 48, height: 48, child: icon),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: Lux.ui(15, weight: FontWeight.w600))),
          if (isNew)
            Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), gradient: Lux.goldGradient),
              child: Text(Lux.upper('Yeni'), style: Lux.ui(11, color: const Color(0xFF2A1D05), weight: FontWeight.w700)),
            ),
        ],
      ),
    );
  }
}

/// Compact always-visible reminder of the rules in force.
class _RuleLegend extends StatelessWidget {
  final bool arrows;
  final bool burgundy;
  const _RuleLegend({required this.arrows, required this.burgundy});

  @override
  Widget build(BuildContext context) {
    Widget chip(Widget icon, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 22, height: 22, child: icon),
          const SizedBox(width: 4),
          Text(label, style: Lux.ui(12, color: Lux.muted)),
        ]);
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      alignment: WrapAlignment.center,
      children: [
        chip(const _StimIcon(round: true), 'dokun'),
        chip(const _StimIcon(round: false), 'dur'),
        if (arrows) chip(const _StimIcon(round: true, arrow: 'up', emerald: true), 'aynı yön'),
        if (burgundy) chip(const _StimIcon(round: true, arrow: 'up', emerald: false), 'ters yön'),
      ],
    );
  }
}

class _StimIcon extends StatelessWidget {
  final bool round;
  final String? arrow;
  final bool emerald;
  const _StimIcon({required this.round, this.arrow, this.emerald = true});

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _IconPainter(round, arrow, emerald));
}

class _IconPainter extends CustomPainter {
  final bool round;
  final String? arrow;
  final bool emerald;
  _IconPainter(this.round, this.arrow, this.emerald);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide * 0.44;
    _drawBody(canvas, round, c, r, 1);
    if (arrow != null) _drawArrow(canvas, c, r * 1.25, arrow!, emerald, 1);
  }

  @override
  bool shouldRepaint(_IconPainter old) => old.round != round || old.arrow != arrow || old.emerald != emerald;
}

class _LifeGem extends StatelessWidget {
  final bool alive;
  final bool justLost;
  const _LifeGem({required this.alive, required this.justLost});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: AnimatedScale(
        scale: alive ? 1 : (justLost ? 1.35 : 0.8),
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutBack,
        child: AnimatedOpacity(
          opacity: alive ? 1 : 0.28,
          duration: const Duration(milliseconds: 380),
          child: CustomPaint(size: const Size.square(20), painter: GemPainter(alive ? Lux.gold : Lux.bordeaux)),
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

// ------------------------------------------------------------------ drawing

final Paint _sp = Paint();

Path _bodyPath(bool round, Offset c, double r) {
  if (round) return Path()..addOval(Rect.fromCircle(center: c, radius: r));
  // Angular square: crisp corners, same visual weight as the disc.
  final h = r * 0.88;
  return Path()
    ..addRRect(RRect.fromRectAndRadius(
        Rect.fromCenter(center: c, width: 2 * h, height: 2 * h), Radius.circular(r * 0.06)));
}

/// Pearl body (round or square): shadow, radial gradient and a gold hairline rim.
void _drawBody(Canvas canvas, bool round, Offset c, double r, double alpha, {Color? tint, double glow = 0}) {
  if (alpha <= 0.004) return;
  final base = tint == null ? _pearl : Color.lerp(_pearl, tint, 0.5)!;
  final path = _bodyPath(round, c, r);
  if (glow > 0) {
    canvas.drawPath(
        path,
        _sp
          ..color = Lux.goldLight.withValues(alpha: 0.3 * glow * alpha)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.3));
  }
  canvas.drawPath(
      path.shift(Offset(0, r * 0.1)),
      _sp
        ..color = Colors.black.withValues(alpha: 0.4 * alpha)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.12));
  _sp
    ..maskFilter = null
    ..color = const Color(0xFF000000);
  _sp.shader = RadialGradient(
    center: const Alignment(-0.35, -0.4),
    radius: 1.1,
    colors: [
      Colors.white.withValues(alpha: alpha),
      base.withValues(alpha: alpha),
      Color.lerp(base, const Color(0xFF6E5B3A), 0.55)!.withValues(alpha: alpha),
    ],
    stops: const [0, 0.5, 1],
  ).createShader(Rect.fromCircle(center: c, radius: r * 1.1));
  canvas.drawPath(path, _sp);
  _sp.shader = null;
  canvas.drawPath(
      path,
      _sp
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.2, r * 0.04)
        ..color = Lux.gold.withValues(alpha: 0.8 * alpha));
  _sp.style = PaintingStyle.fill;
}

/// A bold arrow of length [len] centred at [c], pointing [dir], in emerald or burgundy.
void _drawArrow(Canvas canvas, Offset c, double len, String dir, bool emerald, double alpha, {Color? tint}) {
  if (alpha <= 0.004) return;
  var ink = emerald ? _emerald : _burgundy;
  if (tint != null) ink = Color.lerp(ink, tint, 0.4)!;
  final light = emerald ? _emeraldLight : _burgundyLight;
  final w = len, h = len * 0.72;
  final p = Path()
    ..moveTo(-0.5 * w, -0.15 * h)
    ..lineTo(0.06 * w, -0.15 * h)
    ..lineTo(0.06 * w, -0.5 * h)
    ..lineTo(0.5 * w, 0)
    ..lineTo(0.06 * w, 0.5 * h)
    ..lineTo(0.06 * w, 0.15 * h)
    ..lineTo(-0.5 * w, 0.15 * h)
    ..close();
  final angle = switch (dir) { 'down' => math.pi / 2, 'left' => math.pi, 'up' => -math.pi / 2, _ => 0.0 };
  canvas.save();
  canvas.translate(c.dx, c.dy);
  canvas.rotate(angle);
  _sp.shader = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [light.withValues(alpha: alpha), ink.withValues(alpha: alpha), Color.lerp(ink, Colors.black, 0.35)!.withValues(alpha: alpha)],
  ).createShader(Rect.fromCenter(center: Offset.zero, width: w, height: h));
  canvas.drawPath(p, _sp);
  _sp.shader = null;
  canvas.drawPath(
      p,
      _sp
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = math.max(1.0, w * 0.035)
        ..color = Color.lerp(ink, Colors.black, 0.45)!.withValues(alpha: alpha));
  _sp.style = PaintingStyle.fill;
  canvas.restore();
}

/// Draws a stimulus map from the core (`{shape, arrow: {dir, color}|null}`).
void _drawStim(Canvas canvas, Map<String, dynamic> s, Offset c, double r, double alpha,
    {Color? tint, double glow = 0}) {
  _drawBody(canvas, s['shape'] == 'round', c, r, alpha, tint: tint, glow: glow);
  final a = s['arrow'];
  if (a is Map) _drawArrow(canvas, c, r * 1.3, a['dir'] as String? ?? 'right', a['color'] == 'emerald', alpha, tint: tint);
}

class _StagePainter extends CustomPainter {
  final Map<String, dynamic> st;
  final _Fb? fb;
  final double now;
  _StagePainter({required this.st, required this.fb, required this.now});

  static final Paint _p = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final centre = rect.center;
    final unit = math.min(size.width, size.height);
    final r = unit * 0.2;
    final phase = st['phase'] as String? ?? '';
    final stage = st['stage'] as String?;
    final stageMs = _num(st['stage_ms']);
    final f = fb;
    final fbAge = f == null ? 99.0 : now - f.at;

    // Quick stage flash: soft gold when right, bordeaux when wrong.
    if (f != null && fbAge < 0.3 && f.result != 'reject') {
      final k = 1 - fbAge / 0.3;
      _p.shader = RadialGradient(
        radius: 0.85,
        colors: [(f.good ? Lux.gold : Lux.bordeaux).withValues(alpha: (f.good ? 0.16 : 0.3) * k * k), Colors.transparent],
      ).createShader(rect);
      canvas.drawRect(rect, _p);
      _p.shader = null;
    }

    final stim = st['stim'] is Map ? Map<String, dynamic>.from(st['stim'] as Map) : null;
    if (stim != null) {
      final u = Curves.easeOutCubic.transform((stageMs / 70).clamp(0.0, 1.0));
      _drawStim(canvas, stim, centre, r * (0.84 + 0.16 * u), (stageMs / 40).clamp(0.0, 1.0), glow: 0.5);
    } else if (f?.stim != null && fbAge < 0.28) {
      final u = (fbAge / 0.28).clamp(0.0, 1.0);
      final s = f!.stim!;
      if (f.good) {
        final swiped = f.input != null && f.input != 'tap';
        if (swiped) {
          // The shape flies off the way it was swiped.
          final off = _dirVec(f.input) * unit * 0.45 * Curves.easeOutCubic.transform(u);
          _drawStim(canvas, s, centre + off, r, 1 - u);
        } else {
          _drawStim(canvas, s, centre, r * (1 + 0.1 * Curves.easeOutCubic.transform(u)), 1 - u);
        }
      } else {
        final shake = math.sin(u * math.pi * 5) * unit * 0.03 * (1 - u);
        _drawStim(canvas, s, centre.translate(shake, 0), r, 1 - u * u, tint: Lux.bordeaux);
      }
    } else if (phase == 'run' && stage == 'iti') {
      // Fixation: a small gold cross, breathing slightly.
      final f = Paint()
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = Lux.gold.withValues(alpha: 0.35 + 0.1 * math.sin(now * 5));
      final l = unit * 0.025;
      canvas.drawLine(centre.translate(-l, 0), centre.translate(l, 0), f);
      canvas.drawLine(centre.translate(0, -l), centre.translate(0, l), f);
    }

    // Gold ring burst on a correct tap or swipe.
    if (f != null && (f.result == 'hit' || f.result == 'swipe_ok') && fbAge < 0.36) {
      final u = Curves.easeOutCubic.transform((fbAge / 0.36).clamp(0.0, 1.0));
      canvas.drawCircle(
          centre,
          unit * (0.22 + 0.18 * u),
          _p
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3 * (1 - u) + 0.5
            ..color = Lux.goldLight.withValues(alpha: 0.7 * (1 - u)));
      _p.style = PaintingStyle.fill;
    }

    // Error label, plus the right direction on arrow trials.
    if (f != null && fbAge < 0.75) {
      final label = switch (f.result) {
        'omission' => 'Kaçırdın',
        'early' => 'Erken',
        'commission' => 'Köşeli: dokunma',
        'wrong_dir' => 'Ters yön',
        'need_swipe' => 'Kaydırmalıydın',
        'need_tap' => 'Dokunmalıydın',
        _ => null,
      };
      if (label != null) {
        final u = (fbAge / 0.75).clamp(0.0, 1.0);
        final a = 1 - u * u;
        final tp = TextPainter(
          text: TextSpan(text: label, style: Lux.ui(18, color: Lux.bordeauxLight.withValues(alpha: a), weight: FontWeight.w700)),
          textDirection: TextDirection.ltr,
        )..layout();
        final y = size.height * 0.8 - 16 * u;
        tp.paint(canvas, Offset(centre.dx - tp.width / 2, y));
        final want = f.wantDir;
        if (want != null && (f.result == 'wrong_dir' || f.result == 'need_swipe' || f.result == 'omission')) {
          _drawHint(canvas, Offset(centre.dx, y - unit * 0.07), unit * 0.08, want, a);
        }
      }
    }
  }

  /// A small gold arrow showing the direction that was wanted.
  void _drawHint(Canvas canvas, Offset c, double len, String dir, double alpha) {
    final v = _dirVec(dir);
    final from = c - v * len * 0.5, to = c + v * len * 0.5;
    final paint = Paint()
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..color = Lux.goldLight.withValues(alpha: alpha);
    canvas.drawLine(from, to, paint);
    final n = Offset(-v.dy, v.dx);
    canvas.drawLine(to, to - v * len * 0.35 + n * len * 0.3, paint);
    canvas.drawLine(to, to - v * len * 0.35 - n * len * 0.3, paint);
  }

  @override
  bool shouldRepaint(_StagePainter old) => true;
}
