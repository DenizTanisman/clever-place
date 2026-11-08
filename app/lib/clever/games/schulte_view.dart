import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// Schulte table board: a square grid of velvet tiles with a gold fixation point at the centre,
/// a live clock, the "Sıradaki" pill and a found-progress rail. Order, timing, penalties and stars
/// live in Rust; this widget only renders and forwards taps.
///
/// Input fires on pointer-down (no tap-up wait) and is hit-tested over the whole grid, so fast
/// tapping is never held back by animations. Motion: a tile sinks on touch, a correct tile glows
/// gold, a wrong tap flashes the tile bordeaux, shakes the grid and floats "+2 sn" off the clock;
/// a reshuffle fades the new symbols in; the win sends a gold ripple out from the centre.
Widget schulteView(BuildContext context, GameSession s) => _SchulteBoard(key: ObjectKey(s), session: s);

/// Second ink of the two-colour (Gorbov–Schulte) tables: a warm red that stays readable on velvet.
const _redInk = Color(0xFFFF6168);

class _SchulteBoard extends StatefulWidget {
  final GameSession session;
  const _SchulteBoard({super.key, required this.session});

  @override
  State<_SchulteBoard> createState() => _SchulteBoardState();
}

class _SchulteBoardState extends State<_SchulteBoard> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;

  int _seenSerial = 0;
  double _fbAt = -10;
  bool _fbOk = true;
  int _fbCell = -1;
  double _errAt = -10;

  int _pressCell = -1;
  double _pressAt = -10;

  int _layoutSeen = 0;
  double _layoutAt = -10;

  int _lastCount = 0;
  double _winAt = -1;

  GameSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    final last = s.state['last'];
    if (last is Map) _seenSerial = (last['serial'] as num).toInt();
    _layoutSeen = (s.state['layout_serial'] as num?)?.toInt() ?? 0;
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  bool _animating(double now) =>
      now - _fbAt < 0.6 || now - _pressAt < 0.25 || now - _errAt < 0.9 || (_winAt >= 0 && now - _winAt < 1.6);

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1000.0;
    _lastTick = elapsed;
    final phase = s.state['phase'];
    if (s.finished || !(phase == 'run' || phase == 'countdown')) {
      if (_animating(_now)) setState(() {});
      return;
    }
    s.tick(dt);
  }

  /// Turn state changes into one-shot effects.
  void _sync(Map<String, dynamic> st, double now) {
    final last = st['last'];
    if (last is Map) {
      final serial = (last['serial'] as num).toInt();
      if (serial != _seenSerial) {
        _seenSerial = serial;
        _fbAt = now;
        _fbOk = last['ok'] == true;
        _fbCell = (last['cell'] as num).toInt();
        if (_fbOk) {
          HapticFeedback.lightImpact();
        } else {
          _errAt = now;
          HapticFeedback.mediumImpact();
        }
      }
    }
    final ls = (st['layout_serial'] as num?)?.toInt() ?? 0;
    if (ls != _layoutSeen) {
      _layoutSeen = ls;
      _layoutAt = now;
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

  void _tap(int cell) {
    if (s.finished || s.state['phase'] != 'run') return;
    _pressCell = cell;
    _pressAt = _now;
    s.act({'tap': cell});
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
            Expanded(child: _gridArea(st, now)),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 18),
              child: Text(
                'Gözün ortadaki noktada kalsın · sembolleri çevre görüşünle bul',
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
    final elapsed = (st['elapsed_ms'] as num?)?.toDouble() ?? 0;
    final par = (st['par_ms'] as num?)?.toDouble() ?? 1;
    final remaining = (st['remaining_ms'] as num?)?.toDouble() ?? 0;
    final total = (st['total'] as num?)?.toInt() ?? 1;
    final found = (st['found'] as num?)?.toInt() ?? 0;
    final errors = (st['errors'] as num?)?.toInt() ?? 0;
    final next = st['next'] is Map ? Map<String, dynamic>.from(st['next'] as Map) : null;
    final overPar = elapsed > par;
    final running = st['phase'] == 'run' && !s.finished;
    final te = now - _errAt;
    final errKick = te >= 0 && te < 0.5 ? math.exp(-te * 7) : 0.0;
    final lowTime = running && remaining < 10000;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Clock (penalties included) + par.
              Expanded(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _clockText(elapsed),
                          style: Lux.numeral(32,
                                  color: Color.lerp(lowTime ? Lux.bordeauxLight : (overPar ? Lux.gold : Lux.goldLight),
                                      Lux.bordeauxLight, errKick)!)
                              .copyWith(
                                  fontFeatures: const [FontFeature.tabularFigures(), FontFeature.liningFigures()]),
                        ),
                        const SizedBox(height: 3),
                        // A wrong tap briefly swaps the par line for the penalty, popping in bordeaux.
                        if (te >= 0 && te < 0.9)
                          Transform.scale(
                            scale: 0.8 + 0.2 * Curves.easeOutBack.transform((te / 0.2).clamp(0.0, 1.0)),
                            alignment: Alignment.centerLeft,
                            child: Text('+${(((st['penalty_ms'] as num?) ?? 2000) / 1000).round()} sn ceza',
                                style: Lux.ui(12.5, color: Lux.bordeauxLight, weight: FontWeight.w700)),
                          )
                        else
                          Text(
                            lowTime ? 'Kalan ${(remaining / 1000).ceil()} sn' : 'Hedef ${_clockText(par)}',
                            style: Lux.ui(12.5, color: lowTime ? Lux.bordeauxLight : Lux.muted),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              _nextPill(st, next),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Transform.scale(
                      scale: 1 + 0.25 * errKick,
                      alignment: Alignment.centerRight,
                      child: Text('Hata $errors',
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
          _progressBar(found / total),
        ],
      ),
    );
  }

  Widget _nextPill(Map<String, dynamic> st, Map<String, dynamic>? next) {
    final label = next?['label'] as String?;
    final red = (next?['color'] as num?)?.toInt() == 1;
    final ink = red ? _redInk : Lux.ink;
    return Container(
      constraints: const BoxConstraints(minWidth: 118),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        color: const Color(0x33000000),
        border: Border.all(color: Lux.gold.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text('Sıradaki', style: Lux.ui(12, color: Lux.gold, spacing: 0.8)),
          const SizedBox(width: 8),
          SizedBox(
            width: 34,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 140),
              transitionBuilder: (child, a) => FadeTransition(
                opacity: a,
                child: ScaleTransition(scale: Tween(begin: 0.6, end: 1.0).animate(a), child: child),
              ),
              child: Text(
                label ?? '–',
                key: ValueKey('${next?['index']}'),
                textAlign: TextAlign.center,
                style: Lux.numeral(26, color: label == null ? Lux.muted : ink),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _progressBar(double f) => ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: SizedBox(
          height: 4,
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
      );

  // ------------------------------------------------------------------ grid

  Widget _gridArea(Map<String, dynamic> st, double now) {
    final n = (st['size'] as num?)?.toInt() ?? 5;
    final cells = st['cells'] is List ? (st['cells'] as List).cast<Map>() : null;
    final dimFound = st['dim_found'] == true;
    return LayoutBuilder(builder: (context, box) {
      final side = math.min(box.maxWidth - 24, box.maxHeight - 16).clamp(120.0, 2000.0);
      final gap = (side * 0.014).clamp(3.0, 7.0);
      final tile = (side - gap * (n + 1)) / n;
      final te = now - _errAt;
      final shake = te >= 0 && te < 0.4 ? math.sin(te * 54) * 9 * math.exp(-te * 9) : 0.0;
      final tw = _winAt >= 0 ? now - _winAt : -1.0;
      final center = (n - 1) / 2;
      final children = <Widget>[];
      for (var i = 0; i < n * n; i++) {
        final r = i ~/ n, c = i % n;
        final dist = math.sqrt(math.pow(r - center, 2) + math.pow(c - center, 2));
        // Win ripple: each ring of tiles lights up a little later.
        var ripple = 0.0;
        if (tw >= 0) {
          final local = tw - dist * 0.07;
          if (local >= 0 && local < 0.6) ripple = math.sin(math.pi * local / 0.6);
        }
        children.add(Positioned(
          left: gap + c * (tile + gap),
          top: gap + r * (tile + gap),
          width: tile,
          height: tile,
          child: _tile(i, tile, cells?[i], dimFound, ripple, now),
        ));
      }
      return Center(
        child: Transform.translate(
          offset: Offset(shake, 0),
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) {
              final p = e.localPosition;
              final c = ((p.dx - gap / 2) / (tile + gap)).floor();
              final r = ((p.dy - gap / 2) / (tile + gap)).floor();
              if (c < 0 || r < 0 || c >= n || r >= n) return;
              _tap(r * n + c);
            },
            child: SizedBox(
              width: side,
              height: side,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  color: const Color(0xFF041C14),
                  border: Border.all(color: Lux.gold.withValues(alpha: 0.55), width: 1.2),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 24, offset: const Offset(0, 10))
                  ],
                ),
                child: Stack(
                  children: [
                    ...children,
                    Positioned.fill(
                      child: IgnorePointer(
                        child:
                            CustomPaint(painter: _Fixation(n: n, gap: gap, tile: tile, t: now, active: cells != null)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget _tile(int i, double tile, Map? cell, bool dimFound, double ripple, double now) {
    final tp = now - _pressAt;
    final pressed = i == _pressCell && tp >= 0 && tp < 0.2;
    final press = pressed ? (tp < 0.05 ? tp / 0.05 : 1 - (tp - 0.05) / 0.15).clamp(0.0, 1.0) : 0.0;
    final tf = now - _fbAt;
    final fb = i == _fbCell && tf >= 0 && tf < 0.45 ? math.pow(1 - tf / 0.45, 2).toDouble() : 0.0;
    final tone = _fbOk ? Lux.gold : Lux.bordeaux;
    final found = cell?['found'] == true;

    var bg = const Color(0xFF0B3A2E);
    bg = Color.lerp(bg, tone, (_fbOk ? 0.35 : 0.6) * fb)!;
    bg = Color.lerp(bg, Lux.gold, 0.45 * ripple)!;
    final rim = Color.lerp(Lux.line, _fbOk ? Lux.goldLight : Lux.bordeauxLight, fb)!;

    Widget? label;
    if (cell != null) {
      final red = (cell['color'] as num?)?.toInt() == 1;
      final scale = (cell['scale'] as num?)?.toDouble() ?? 1;
      final rot = (cell['rot'] as num?)?.toDouble() ?? 0;
      final fadeIn = 0.35 + 0.65 * ((now - _layoutAt) / 0.1).clamp(0.0, 1.0);
      final dim = dimFound && found ? 0.28 : 1.0;
      label = Opacity(
        opacity: dim * fadeIn,
        child: Transform.rotate(
          angle: rot * math.pi / 180,
          child: Text(
            cell['label'] as String,
            style: TextStyle(
              fontFamily: 'Jost',
              fontSize: tile * 0.44 * scale,
              fontWeight: FontWeight.w600,
              color: red ? _redInk : Lux.ink,
              height: 1,
              fontFeatures: const [FontFeature.liningFigures()],
            ),
          ),
        ),
      );
    }

    return Transform.scale(
      scale: 1 - 0.07 * press,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(tile * 0.16),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color.lerp(bg, Colors.white, 0.05 + 0.04 * press)!, Color.lerp(bg, Colors.black, 0.35)!],
          ),
          border: Border.all(color: rim, width: 1 + 0.8 * fb),
          boxShadow: [
            if (fb > 0.01) BoxShadow(color: tone.withValues(alpha: 0.5 * fb), blurRadius: 14 * fb),
            if (ripple > 0.01) BoxShadow(color: Lux.gold.withValues(alpha: 0.45 * ripple), blurRadius: 16 * ripple),
          ],
        ),
        child: Center(child: label),
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
    final total = (st['total'] as num?)?.toInt() ?? 25;
    final order = st['order'] as String? ?? 'asc';
    final par = (st['par_ms'] as num?)?.toDouble() ?? 0;
    final penalty = (((st['penalty_ms'] as num?) ?? 2000) / 1000).round();
    final red = total ~/ 2;
    final how = switch (order) {
      'desc' => '$total\'den 1\'e, geriye doğru sırayla dokun.',
      'alpha' => 'Harfleri alfabe sırasıyla bul: A, B, C, Ç, D… (Ğ ve I yok).',
      'gorbov' =>
        'İki dizi iç içe: beyazlar 1\'den yukarı, kırmızılar $red\'den aşağı. Sıra: beyaz 1, kırmızı $red, beyaz 2, kırmızı ${red - 1}…',
      _ => '1\'den $total\'e kadar sırayla dokun.',
    };
    final lines = <String>[
      how,
      'Gözünü ortadaki altın noktada tut; sembolleri çevre görüşünle yakala.',
      if (st['styled'] == true) 'Boyutlar ve açılar karışık: sadece sembolün kendisine bak.',
      if (st['shuffle'] == true) 'Her doğru dokunuşta tablo yeniden karışır.',
      if (st['dim_found'] == true) 'Bulduğun semboller soluklaşır.',
      'Yanlış dokunuş +$penalty sn. 3 yıldız için ${_clockText(par)} altında bitir.',
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
                Text(Lux.upper(st['title'] as String? ?? 'Schulte'),
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

/// `m:ss,t`, e.g. `0:23,4`.
String _clockText(double ms) {
  final tenths = (ms / 100).round().clamp(0, 1 << 30);
  final m = tenths ~/ 600;
  final sec = (tenths ~/ 10) % 60;
  return '$m:${sec.toString().padLeft(2, '0')},${tenths % 10}';
}

/// Central fixation point: a breathing gold dot on the grid's centre (even grids sit on a line
/// crossing); on odd grids a thin ring around the centre tile, so the symbol stays readable.
class _Fixation extends CustomPainter {
  final int n;
  final double gap, tile, t;
  final bool active;
  _Fixation({required this.n, required this.gap, required this.tile, required this.t, required this.active});

  static final Paint _p = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final breathe = 0.5 + 0.5 * math.sin(t * 2.2);
    final a = active ? 0.85 : 0.55;
    if (n.isEven) {
      canvas.drawCircle(
          c,
          9 + 3 * breathe,
          _p
            ..style = PaintingStyle.fill
            ..color = Lux.gold.withValues(alpha: 0.28 * a)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
      _p.maskFilter = null;
      canvas.drawCircle(c, 4.2, _p..color = Lux.goldLight.withValues(alpha: a));
      canvas.drawCircle(
          c,
          4.2,
          _p
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = Lux.goldDeep);
      _p.style = PaintingStyle.fill;
    } else {
      final r = tile * 0.47;
      canvas.drawCircle(
          c,
          r,
          _p
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4 + 0.6 * breathe
            ..color = Lux.gold.withValues(alpha: (0.45 + 0.25 * breathe) * a));
      _p.style = PaintingStyle.fill;
    }
  }

  @override
  bool shouldRepaint(_Fixation old) => old.t != t || old.active != active || old.tile != tile || old.n != n;
}
