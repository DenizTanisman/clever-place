import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../i18n/lang.dart';
import '../lux.dart';

/// Dönen Sayılar board: a velvet dial with gold ring guides, upright number discs carried around the
/// rings, a countdown of the minute and the next star target. Rules, time and tap judging live in
/// Rust: each frame this widget places every number from its ring's current angle in the state, and
/// on a touch it only sends the point, in board units.
///
/// Input fires on pointer-down and covers the whole dial. Nothing marks the next number apart from
/// the core's optional cue on the 1. A correct number flashes gold and fades away; a wrong one flashes
/// bordeaux, shakes the dial and shows the penalty on the clock.
Widget donenSayilarView(BuildContext context, GameSession s) => DonenSayilarBoard(key: ObjectKey(s), session: s);

class DonenSayilarBoard extends StatefulWidget {
  final GameSession session;
  const DonenSayilarBoard({super.key, required this.session});

  @override
  State<DonenSayilarBoard> createState() => _DonenSayilarBoardState();
}

class _DonenSayilarBoardState extends State<DonenSayilarBoard> with SingleTickerProviderStateMixin {
  static const _fadeSeconds = 0.28;

  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;

  /// Frame time in seconds: effects run on the same clock as the rings' frames.
  double _now = 0;

  int _seenSerial = 0;
  double _fbAt = -10;
  bool _fbOk = true;
  int _fbNumber = -1;
  double _errAt = -10;

  int _boardSeen = 0;
  double _boardAt = -10;
  bool _runSeen = false;

  /// When each tapped number started fading (numbers of the current board).
  final Map<int, double> _fadeAt = {};

  int _lastCount = 0;
  double _winAt = -1;

  GameSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    final last = s.state['last'];
    if (last is Map) _seenSerial = (last['serial'] as num).toInt();
    _boardSeen = (s.state['board_serial'] as num?)?.toInt() ?? 0;
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  bool _animating(double now) => now - _fbAt < 0.6 || now - _errAt < 0.9 || (_winAt >= 0 && now - _winAt < 1.6);

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1000.0;
    _lastTick = elapsed;
    _now = elapsed.inMicroseconds / 1e6;
    final phase = s.state['phase'];
    if (s.finished || !(phase == 'run' || phase == 'countdown')) {
      if (_animating(_now)) setState(() {});
      return;
    }
    s.tick(dt);
  }

  /// Turn state changes into one-shot effects.
  void _sync(Map<String, dynamic> st, double now) {
    final serialBoard = (st['board_serial'] as num?)?.toInt() ?? 0;
    if (serialBoard != _boardSeen) {
      _boardSeen = serialBoard;
      _boardAt = now;
      _fadeAt.clear();
      _fbNumber = -1;
    }
    if (st['phase'] == 'run' && !_runSeen) {
      _runSeen = true;
      _boardAt = now;
    }
    final numbers = st['numbers'];
    if (numbers is List) {
      for (final raw in numbers) {
        final m = raw as Map;
        if (m['found'] == true) _fadeAt.putIfAbsent((m['n'] as num).toInt(), () => now);
      }
    }
    final last = st['last'];
    if (last is Map) {
      final serial = (last['serial'] as num).toInt();
      if (serial != _seenSerial) {
        _seenSerial = serial;
        _fbAt = now;
        _fbOk = last['ok'] == true;
        _fbNumber = (last['n'] as num).toInt();
        if (_fbOk) {
          HapticFeedback.lightImpact();
        } else {
          _errAt = now;
          HapticFeedback.mediumImpact();
        }
      }
    }
    if (st['phase'] == 'countdown') {
      final k = (((st['countdown_ms'] as num?) ?? 0) / 1000).ceil();
      if (k != _lastCount && k >= 1 && k <= 3) HapticFeedback.selectionClick();
      _lastCount = k;
    }
    if (st['status'] == 'won' && _winAt < 0) {
      _winAt = now;
      HapticFeedback.heavyImpact();
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
            _header(st, now),
            Expanded(child: _dial(st, now)),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 18),
              child: Text(
                t('Sırayı aklında tut · parmağını sayının gideceği yere götür'),
                textAlign: TextAlign.center,
                style: Lux.ui(13, color: Lux.muted.withValues(alpha: 0.8)),
              ),
            ),
          ],
        ),
        if (phase == 'countdown') Positioned.fill(child: IgnorePointer(child: _countdown(st))),
        if (phase == 'intro') Positioned.fill(child: _introCard(st)),
      ],
    );
  }

  // ------------------------------------------------------------------ header

  Widget _header(Map<String, dynamic> st, double now) {
    final remaining = (st['remaining_ms'] as num?)?.toDouble() ?? 0;
    final total = (st['total'] as num?)?.toInt() ?? 1;
    final found = (st['found'] as num?)?.toInt() ?? 0;
    final errors = (st['errors'] as num?)?.toInt() ?? 0;
    final running = st['phase'] == 'run' && !s.finished;
    final te = now - _errAt;
    final errKick = te >= 0 && te < 0.5 ? math.exp(-te * 7) : 0.0;
    final lowTime = running && remaining < 10000;
    final targets = st['targets'] is List ? (st['targets'] as List).map((e) => (e as num).toInt()).toList() : <int>[];

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _clockText(remaining),
                      style: Lux.numeral(32,
                              color: Color.lerp(lowTime ? Lux.bordeauxLight : Lux.goldLight, Lux.bordeauxLight, errKick)!)
                          .copyWith(fontFeatures: const [FontFeature.tabularFigures(), FontFeature.liningFigures()]),
                    ),
                    const SizedBox(height: 3),
                    if (te >= 0 && te < 0.9)
                      Text(tf('−{0} sn ceza', [(((st['penalty_ms'] as num?) ?? 2000) / 1000).round()]),
                          style: Lux.ui(12.5, color: Lux.bordeauxLight, weight: FontWeight.w700))
                    else
                      Text(t('Kalan süre'), style: Lux.ui(12.5, color: lowTime ? Lux.bordeauxLight : Lux.muted)),
                  ],
                ),
              ),
              _goalPill(st),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Transform.scale(
                      scale: 1 + 0.25 * errKick,
                      alignment: Alignment.centerRight,
                      child: Text(tf('Hata {0}', [errors]),
                          style: Lux.ui(17, color: errors > 0 ? Lux.bordeauxLight : Lux.ink, weight: FontWeight.w700)),
                    ),
                    const SizedBox(height: 3),
                    Text('$found / $total', style: Lux.ui(12.5, color: Lux.muted)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _progressBar(found / total, [for (final t in targets) t / total]),
        ],
      ),
    );
  }

  /// The next star target (levels) or the round number (endless). Never the next number.
  Widget _goalPill(Map<String, dynamic> st) {
    final goal = st['next_goal'] is Map ? Map<String, dynamic>.from(st['next_goal'] as Map) : null;
    final endless = st['mode'] == 'endless';
    return Container(
      constraints: const BoxConstraints(minWidth: 104),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        color: const Color(0x33000000),
        border: Border.all(color: Lux.gold.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (endless) ...[
            Text(t('Tur'), style: Lux.ui(12, color: Lux.gold, spacing: 0.8)),
            const SizedBox(width: 8),
            Text('${(st['stage'] as num?)?.toInt() ?? 1}', style: Lux.numeral(26, color: Lux.ink)),
          ] else if (goal != null) ...[
            StarRow((goal['stars'] as num).toInt(), size: 12),
            const SizedBox(width: 8),
            Text('${(goal['n'] as num).toInt()}', style: Lux.numeral(26, color: Lux.ink)),
          ] else
            Text(t('Tamam'), style: Lux.ui(15, color: Lux.gold, weight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _progressBar(double f, List<double> ticks) => SizedBox(
        height: 6,
        child: LayoutBuilder(
          builder: (context, box) => Stack(
            children: [
              Positioned.fill(
                top: 1,
                bottom: 1,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: Stack(
                    children: [
                      const Positioned.fill(child: ColoredBox(color: Color(0xFF0A2B21))),
                      AnimatedFractionallySizedBox(
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOutCubic,
                        alignment: Alignment.centerLeft,
                        widthFactor: f.clamp(0.0, 1.0),
                        child: const DecoratedBox(decoration: BoxDecoration(gradient: Lux.goldGradient)),
                      ),
                    ],
                  ),
                ),
              ),
              for (final t in ticks)
                Positioned(
                  left: (box.maxWidth * t - 1).clamp(0.0, box.maxWidth - 2),
                  top: 0,
                  bottom: 0,
                  width: 2,
                  child: ColoredBox(color: Lux.ink.withValues(alpha: 0.8)),
                ),
            ],
          ),
        ),
      );

  // ------------------------------------------------------------------ dial

  void _touch(Offset local, double side, double k) {
    if (s.finished || s.state['phase'] != 'run') return;
    final x = (local.dx - side / 2) / k;
    final y = (local.dy - side / 2) / k;
    s.act({
      'tap': [double.parse(x.toStringAsFixed(1)), double.parse(y.toStringAsFixed(1))]
    });
  }

  Widget _dial(Map<String, dynamic> st, double now) {
    final boardR = (st['board_r'] as num?)?.toDouble() ?? 1000;
    final rings = st['rings'] is List ? (st['rings'] as List).cast<Map>() : const <Map>[];
    final numbers = st['numbers'] is List ? (st['numbers'] as List).cast<Map>() : null;
    return LayoutBuilder(builder: (context, box) {
      final side = math.min(box.maxWidth - 16, box.maxHeight - 8).clamp(120.0, 2000.0);
      final k = side / 2 / boardR;
      final tr = ((st['token_r'] as num?)?.toDouble() ?? 100) * k;
      final te = now - _errAt;
      final shake = te >= 0 && te < 0.4 ? math.sin(te * 54) * 9 * math.exp(-te * 9) : 0.0;
      final radii = [for (final r in rings) (r['r'] as num).toDouble() * k];
      final tokens = <Widget>[];
      for (final m in numbers ?? const <Map>[]) {
        final n = (m['n'] as num).toInt();
        final found = m['found'] == true;
        final faded = found ? (now - (_fadeAt[n] ?? now)) / _fadeSeconds : 0.0;
        if (faded >= 1) continue;
        final ring = (m['ring'] as num).toInt();
        final a = (m['a'] as num).toDouble() + (rings[ring]['a'] as num).toDouble();
        final r = radii[ring];
        tokens.add(Positioned(
          key: ValueKey('n$n'),
          left: side / 2 + r * math.cos(a) - tr,
          top: side / 2 + r * math.sin(a) - tr,
          width: tr * 2,
          height: tr * 2,
          child: _token(n, tr, found, faded, m['cue'] == true, now),
        ));
      }
      return Center(
        child: Transform.translate(
          offset: Offset(shake, 0),
          child: Listener(
            key: const ValueKey('donen-dial'),
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) => _touch(e.localPosition, side, k),
            child: SizedBox(
              width: side,
              height: side,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _Dial(radii: radii, t: now, winAge: _winAt >= 0 ? now - _winAt : -1),
                    ),
                  ),
                  ...tokens,
                ],
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget _token(int n, double tr, bool found, double faded, bool cue, double now) {
    final tf = now - _fbAt;
    final wrong = !_fbOk && n == _fbNumber && tf >= 0 && tf < 0.45 ? math.pow(1 - tf / 0.45, 2).toDouble() : 0.0;
    final appear = ((now - _boardAt) / 0.3).clamp(0.0, 1.0);
    final breathe = 0.5 + 0.5 * math.sin(now * 3.2);

    var bg = found ? Color.lerp(const Color(0xFF0E4636), Lux.gold, 0.75)! : const Color(0xFF0E4636);
    bg = Color.lerp(bg, Lux.bordeaux, 0.75 * wrong)!;
    final rim = Color.lerp(
      cue ? Lux.gold.withValues(alpha: 0.65 + 0.35 * breathe) : Lux.line,
      Lux.bordeauxLight,
      wrong,
    )!;

    return Opacity(
      opacity: (found ? 1 - faded : appear).clamp(0.0, 1.0),
      child: Transform.scale(
        scale: found ? 1 + 0.25 * faded : 0.8 + 0.2 * appear,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              center: const Alignment(-0.35, -0.45),
              radius: 1.1,
              colors: [Color.lerp(bg, Colors.white, 0.14)!, Color.lerp(bg, Colors.black, 0.38)!],
            ),
            border: Border.all(color: rim, width: cue ? 1.6 : 1.1),
            boxShadow: [
              if (wrong > 0.01) BoxShadow(color: Lux.bordeaux.withValues(alpha: 0.55 * wrong), blurRadius: 12 * wrong),
            ],
          ),
          child: Center(
            child: Text(
              '$n',
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                fontFamily: 'Jost',
                fontSize: tr * 0.98,
                fontWeight: FontWeight.w600,
                color: Lux.ink,
                height: 1,
                fontFeatures: const [FontFeature.liningFigures()],
              ),
            ),
          ),
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
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.3 * (k == 1 ? 1 - outT : 1.0)),
      child: Center(
        child: Transform.scale(
          scale: scale,
          child: Opacity(opacity: opacity, child: Text('$k', style: Lux.display(110, color: Lux.goldLight))),
        ),
      ),
    );
  }

  Widget _introCard(Map<String, dynamic> st) {
    final penalty = (((st['penalty_ms'] as num?) ?? 2000) / 1000).round();
    final endless = st['mode'] == 'endless';
    final targets = st['targets'] is List ? (st['targets'] as List).map((e) => (e as num).toInt()).toList() : null;
    final maxErrors = st['max_errors'] is List ? (st['max_errors'] as List).map((e) => (e as num).toInt()).toList() : null;
    final lines = <String>[
      t('1\'den başla, sayılara büyüdükçe sırayla dokun. Sıradaki sayı işaretlenmez.'),
      t('Halkalar durmadan döner; her halka kendi hızında ve komşusunun tersine.'),
      if (st['reversing'] == true) t('Bazı halkalar yavaşlayıp yön değiştirir.'),
      if (st['first_cue'] == true) t('Yalnız 1 sayısının çevresinde ince bir işaret olur.'),
      tf('Dokunduğun sayı kaybolur. Yanlış sayıya dokunmak {0} saniye götürür.', [penalty]),
      if (targets != null && targets.length == 3)
        tf('1 yıldız {0}, 2 yıldız {1}, 3 yıldız {2} sayı.', [targets[0], targets[1], targets[2]]),
      if (maxErrors != null && maxErrors.length == 2 && !endless)
        tf('3 yıldız için en çok {0}, 2 yıldız için en çok {1} hata.', [maxErrors[0], maxErrors[1]]),
      if (endless) t('Her tam turda süren uzar, sıradaki tur zorlaşır. Süre biterse oyun biter.'),
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
          padding: const EdgeInsets.all(24),
          child: LuxCard(
            highlight: true,
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(Lux.upper(ct(st['title'] as String? ?? t('Dönen Sayılar'))),
                    textAlign: TextAlign.center, style: Lux.display(21, spacing: 1.2)),
                const SizedBox(height: 14),
                for (final l in lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 7, right: 10),
                          child: Container(
                              width: 5,
                              height: 5,
                              decoration: const BoxDecoration(color: Lux.gold, shape: BoxShape.circle)),
                        ),
                        Expanded(child: Text(l, style: Lux.ui(15.5, weight: FontWeight.w500))),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
                GoldButton(t('Başla'), icon: Icons.play_arrow_rounded, onPressed: () {
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

/// `m:ss,t`, e.g. `0:23,4`.
String _clockText(double ms) {
  final tenths = (ms / 100).round().clamp(0, 1 << 30);
  final m = tenths ~/ 600;
  final sec = (tenths ~/ 10) % 60;
  return '$m:${sec.toString().padLeft(2, '0')}${Lang.en ? '.' : ','}${tenths % 10}';
}

/// The dial under the numbers: velvet disc, gold rim, faint ring guides, a breathing gold point in
/// the middle and the gold ripple of a win.
class _Dial extends CustomPainter {
  final List<double> radii;
  final double t, winAge;
  _Dial({required this.radii, required this.t, required this.winAge});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final outer = size.width / 2;
    final rect = Rect.fromCircle(center: c, radius: outer);
    canvas.drawCircle(
      c,
      outer,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0xFF0A3327), Color(0xFF041C14)],
        ).createShader(rect),
    );
    canvas.drawCircle(
      c,
      outer - 0.8,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = Lux.gold.withValues(alpha: 0.6),
    );
    final guide = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Lux.lineFaint;
    for (final r in radii) {
      canvas.drawCircle(c, r, guide);
    }
    final breathe = 0.5 + 0.5 * math.sin(t * 2.2);
    canvas.drawCircle(
      c,
      7 + 3 * breathe,
      Paint()
        ..color = Lux.gold.withValues(alpha: 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    canvas.drawCircle(c, 3.6, Paint()..color = Lux.goldLight.withValues(alpha: 0.85));
    if (winAge >= 0 && winAge < 1.2) {
      final p = winAge / 1.2;
      canvas.drawCircle(
        c,
        outer * p,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 + 8 * (1 - p)
          ..color = Lux.gold.withValues(alpha: 0.55 * (1 - p)),
      );
    }
  }

  @override
  bool shouldRepaint(_Dial old) => old.t != t || old.winAge != winAge || old.radii.length != radii.length;
}
