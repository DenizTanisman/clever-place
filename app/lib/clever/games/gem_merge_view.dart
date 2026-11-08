import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// Mücevher Birleştir: touch the jar to aim (a dotted guide follows your finger), release to drop.
///
/// The core runs the physics; it is ticked once per display frame with the real frame time, so
/// positions are already at frame rate and need no interpolation. Everything else is derived here
/// by diffing consecutive states (the core keeps gems in a stable order: survivors keep their
/// relative order, drops and merge results are appended):
/// - each gem gets a view-side id, a vertical speed estimate and its birth time;
/// - a dropped gem squashes once when its fall is stopped abruptly (+ light haptic);
/// - a merge pulls the two parents together, flashes a ring, pops the child 0.7 → 1.0, throws
///   sparkles in the child's colour and floats a "+points" label;
/// - a new best tier shows a gold banner with the gem's name;
/// - the danger line breathes bordeaux when settled gems approach it.
/// Gem bodies are lit from a fixed top-left light (the facets roll, the highlight does not).
Widget gemMergeView(BuildContext context, GameSession s) => _GemMerge(key: ObjectKey(s), session: s);

/// Tier colours 1..11 (Kuvars, Ametist, Sitrin, Akuamarin, Granat, Peridot, Topaz, Safir, Zümrüt,
/// Yakut, Elmas).
const _tierColors = <Color>[
  Color(0xFFE7B9C6),
  Color(0xFF9A5BD3),
  Color(0xFFE9B931),
  Color(0xFF4CC4DA),
  Color(0xFF9E1F3A),
  Color(0xFF8DC740),
  Color(0xFFE7802B),
  Color(0xFF2452C8),
  Color(0xFF0F9A63),
  Color(0xFFD0123A),
  Color(0xFFDDEFFF),
];
const _tierNames = <String>[
  'Kuvars', 'Ametist', 'Sitrin', 'Akuamarin', 'Granat', 'Peridot', 'Topaz', 'Safir', 'Zümrüt', 'Yakut', 'Elmas', //
];

/// Same radii / values as the core (`RADII`, `VALUES`, `BIG_BONUS` in gem_merge.rs).
const _radii = <double>[4.4, 5.8, 7.4, 8.9, 10.6, 12.8, 15.0, 17.6, 20.4, 23.8, 27.8];
const _values = <int>[1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 66];
const _bigBonus = 200;
const _spawnY = 14.0;

/// First tier whose first appearance earns a banner (drops are tiers 1–5).
const _bannerFrom = 6;

Color _tierColor(int t) => _tierColors[(t - 1).clamp(0, 10)];
double _radius(int t) => _radii[(t - 1).clamp(0, 10)];

/// Jewel sprites, rendered once per tier and pixel size, in two layers: the lit body (never
/// rotated, so the light stays put) and the cut facets (rotated with the gem as it rolls).
class _Sprites {
  static final Map<int, ui.Image> _bodies = {};
  static final Map<int, ui.Image> _facets = {};
  static final Map<int, TextPainter> _labels = {};
  static ui.Image? _spec;
  static final Paint _img = Paint()..filterQuality = FilterQuality.medium;

  static int _px(double px) => px.round().clamp(6, 600);

  static ui.Image body(int tier, double px) {
    final s = _px(px);
    return _bodies[tier * 1000 + s] ??= _renderBody(tier, s.toDouble());
  }

  static ui.Image facets(int tier, double px) {
    final s = _px(px);
    return _facets[tier * 1000 + s] ??= _renderFacets(tier, s.toDouble());
  }

  /// Soft white specular blob, drawn on top of every gem (light-fixed).
  static ui.Image spec() => _spec ??= () {
        const s = 96.0;
        final rec = ui.PictureRecorder();
        final c = Canvas(rec);
        c.drawOval(
          const Rect.fromLTWH(0, 0, s, s),
          Paint()
            ..shader = const RadialGradient(colors: [Color(0xFFFFFFFF), Color(0x66FFFFFF), Color(0x00FFFFFF)], stops: [0, 0.45, 1])
                .createShader(const Rect.fromLTWH(0, 0, s, s)),
        );
        return rec.endRecording().toImageSync(s.toInt(), s.toInt());
      }();

  static ui.Image _renderBody(int tier, double s) {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final col = _tierColor(tier);
    final center = Offset(s / 2, s / 2);
    final r = s / 2 * 0.97;
    final bounds = Rect.fromCircle(center: center, radius: r);
    c.drawCircle(
      center,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.3, -0.35),
          radius: 1.0,
          colors: [Color.lerp(col, Colors.white, 0.5)!, col, Color.lerp(col, Colors.black, 0.6)!],
          stops: const [0, 0.5, 1],
        ).createShader(bounds),
    );
    // Inner reflected light along the lower-right girdle.
    c.drawCircle(
      center,
      r * 0.92,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.1
        ..shader = SweepGradient(
          colors: [
            Colors.white.withValues(alpha: 0.0),
            Colors.white.withValues(alpha: 0.16),
            Colors.white.withValues(alpha: 0.0),
            Colors.white.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.18, 0.36, 1.0],
        ).createShader(bounds),
    );
    c.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.025
        ..color = Color.lerp(col, Colors.black, 0.5)!.withValues(alpha: 0.7),
    );
    return rec.endRecording().toImageSync(s.toInt(), s.toInt());
  }

  static ui.Image _renderFacets(int tier, double s) {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final col = _tierColor(tier);
    final center = Offset(s / 2, s / 2);
    final r = s / 2 * 0.97;
    // Brilliant-style cut: a polygonal table and crown facets fanning out to the girdle.
    final n = 6 + (tier % 3) * 2; // 6, 8 or 10 facets
    final table = <Offset>[];
    final girdle = <Offset>[];
    for (var i = 0; i < n; i++) {
      final a = -math.pi / 2 + i * 2 * math.pi / n;
      table.add(center + Offset(math.cos(a), math.sin(a)) * r * 0.5);
      final b = a + math.pi / n;
      girdle.add(center + Offset(math.cos(b), math.sin(b)) * r * 0.98);
    }
    for (var i = 0; i < n; i++) {
      final a = table[i], b = table[(i + 1) % n], g = girdle[i];
      final light = math.cos(-math.pi / 2 + (i + 0.5) * 2 * math.pi / n + math.pi * 0.75);
      final tri = Path()
        ..moveTo(a.dx, a.dy)
        ..lineTo(b.dx, b.dy)
        ..lineTo(g.dx, g.dy)
        ..close();
      c.drawPath(tri, Paint()..color = (light > 0 ? Colors.white : Colors.black).withValues(alpha: 0.16 * light.abs()));
      final g0 = girdle[(i - 1 + n) % n];
      final kite = Path()
        ..moveTo(a.dx, a.dy)
        ..lineTo(g.dx, g.dy)
        ..lineTo(center.dx + (a.dx - center.dx) * 1.96, center.dy + (a.dy - center.dy) * 1.96)
        ..lineTo(g0.dx, g0.dy)
        ..close();
      c.drawPath(kite, Paint()..color = Colors.white.withValues(alpha: 0.05 + 0.05 * (i % 2)));
    }
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.012
      ..color = Colors.white.withValues(alpha: 0.26);
    final tablePath = Path()..addPolygon(table, true);
    c.drawPath(
      tablePath,
      Paint()
        ..shader = RadialGradient(
          colors: [Color.lerp(col, Colors.white, 0.3)!.withValues(alpha: 0.75), col.withValues(alpha: 0.55)],
        ).createShader(Rect.fromCircle(center: center, radius: r * 0.5)),
    );
    c.drawPath(tablePath, edge);
    for (var i = 0; i < n; i++) {
      c.drawLine(table[i], girdle[i], edge);
      c.drawLine(table[(i + 1) % n], girdle[i], edge);
    }
    if (tier == 11) {
      final star = Paint()
        ..color = Colors.white.withValues(alpha: 0.85)
        ..strokeWidth = s * 0.012;
      final p = center + Offset(r * 0.3, -r * 0.3);
      c.drawLine(p - Offset(r * 0.22, 0), p + Offset(r * 0.22, 0), star);
      c.drawLine(p - Offset(0, r * 0.22), p + Offset(0, r * 0.22), star);
    }
    return rec.endRecording().toImageSync(s.toInt(), s.toInt());
  }

  static TextPainter label(int tier, double radius) {
    final size = (radius * 0.62).clamp(7.0, 40.0).roundToDouble();
    final key = tier * 1000 + size.toInt();
    return _labels[key] ??= (TextPainter(
      text: TextSpan(
        text: '$tier',
        style: Lux.ui(size,
            color: (tier == 1 || tier == 3 || tier == 11 ? const Color(0xFF2A1B10) : Colors.white).withValues(alpha: 0.55),
            weight: FontWeight.w800),
      ),
      textDirection: TextDirection.ltr,
    )..layout());
  }

  static void _blit(Canvas canvas, ui.Image img, Rect dst) =>
      canvas.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), dst, _img);

  /// Draws one gem. [base] is the tier's full radius (picks the cached sprite, so animated sizes never
  /// re-render sprites); [radius] is the drawn size. [sx]/[sy] squash around the gem's bottom point.
  static void draw(Canvas canvas, int tier, Offset c, double radius, double angle, double dpr,
      {double? base, double opacity = 1, double sx = 1, double sy = 1, double specular = 0.22, bool showLabel = true}) {
    final b = base ?? radius;
    final px = b * 2 * dpr;
    _img.color = Color.fromRGBO(255, 255, 255, opacity.clamp(0.0, 1.0));
    final squashed = sx != 1 || sy != 1;
    canvas.save();
    if (squashed) {
      canvas.translate(c.dx, c.dy + radius);
      canvas.scale(sx, sy);
      canvas.translate(0, -radius);
    } else {
      canvas.translate(c.dx, c.dy);
    }
    final dst = Rect.fromCircle(center: Offset.zero, radius: radius);
    _blit(canvas, body(tier, px), dst);
    canvas.rotate(angle);
    _blit(canvas, facets(tier, px), dst);
    canvas.rotate(-angle);
    if (specular > 0) {
      _img.color = Color.fromRGBO(255, 255, 255, (specular * opacity).clamp(0.0, 1.0));
      _blit(canvas, spec(), Rect.fromCenter(center: Offset(-radius * 0.34, -radius * 0.42), width: radius * 0.82, height: radius * 0.5));
    }
    canvas.restore();
    if (showLabel && b > 7 && opacity > 0.5) {
      final tp = label(tier, b);
      tp.paint(canvas, c + Offset(0, squashed ? radius * (1 - sy) : 0) - Offset(tp.width / 2, tp.height / 2));
    }
  }
}

/// A gem as the view tracks it across states.
class _Gem {
  final int id;
  final double born;
  double x, y, ang;
  int tier, scale;
  double vy = 0; // units / s, estimated from consecutive states
  bool falling = false; // dropped by the player and not yet stopped
  double popAt = -10; // merge child: time it appeared
  double squashAt = -10, squashK = 0;
  _Gem(this.id, this.born, this.x, this.y, this.tier, this.ang, this.scale);
}

/// A merge parent pulled into the merge point while it fades.
class _Ghost {
  final double x, y, tx, ty, ang, at;
  final int tier;
  _Ghost(this.x, this.y, this.tx, this.ty, this.ang, this.tier, this.at);
}

class _Burst {
  final double x, y, at;
  final int tier, points;
  final Float64List dirs; // angle, speed pairs
  _Burst(this.x, this.y, this.tier, this.points, this.at, this.dirs);
}

class _GemMerge extends StatefulWidget {
  final GameSession session;
  const _GemMerge({super.key, required this.session});

  @override
  State<_GemMerge> createState() => _GemMergeState();
}

class _GemMergeState extends State<_GemMerge> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  bool _paused = false;
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;
  final _rand = math.Random(7);

  double? _aimTarget; // container units, where the finger is
  double _aimVis = -1; // smoothed, what is drawn
  bool _touching = false;
  double? _pendingDrop;
  double _scale = 1;

  // State diffing.
  Map<String, dynamic>? _seen;
  bool _primed = false;
  int _seenFx = 0;
  int _nextId = 0;
  List<_Gem> _gems = [];
  List<_Gem> _spare = [];
  final List<double> _freshFx = []; // x, y, tier triples from the latest state
  final List<_Ghost> _ghosts = [];
  final List<_Burst> _bursts = [];
  double _near = 0; // 0..1: how close settled gems are to the danger line
  int _bestTier = 0;
  int _bannerTier = 0;
  double _bannerAt = -10;
  double _winAt = -1;
  double _curAt = -10; // when the aiming gem was replaced (after a drop)
  double _curAlpha = 1;
  int _dropSerial = 0;

  GameSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    for (final f in (s.state['fx'] as List? ?? const [])) {
      _seenFx = math.max(_seenFx, ((f as List)[0] as num).toInt());
    }
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker(_onTick)..start();
    _sync(0);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && !s.finished) _setPaused(true);
  }

  void _setPaused(bool p) {
    if (_paused == p) return;
    setState(() => _paused = p);
  }

  bool _animating(double now) =>
      _bursts.isNotEmpty ||
      _ghosts.isNotEmpty ||
      now - _bannerAt < 1.8 ||
      (_winAt >= 0 && now - _winAt < 1.0) ||
      _gems.any((g) => now - g.squashAt < 0.5 || now - g.popAt < 0.35);

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1000.0;
    _last = elapsed;
    if (_paused || s.loading) return;
    final now = _now;
    _prune(now);
    if (s.finished) {
      _sync(0);
      if (_animating(now)) setState(() {});
      return;
    }
    // Aim: follow the finger with a ~40 ms lag so the gem glides instead of jittering.
    final target = _aimTarget;
    if (target != null) {
      if (_aimVis < 0) _aimVis = target;
      _aimVis += (target - _aimVis) * (1 - math.exp(-dt / 40));
    }
    final ready = ((s.state['cd'] as num?) ?? 0) <= 0;
    _curAlpha += ((ready ? 1.0 : 0.3) - _curAlpha) * (1 - math.exp(-dt / 70));

    final step = dt.clamp(0, 100).toDouble();
    s.tick(step);
    _sync(math.min(step, 1000 / 30)); // the core integrates at most 1/30 s per tick
    final pending = _pendingDrop;
    if (pending != null && ((s.state['cd'] as num?) ?? 0) <= 0) {
      _pendingDrop = null;
      if (s.act({'a': 'drop', 'x': pending})) {
        HapticFeedback.selectionClick();
        _dropSerial++;
        _curAt = now;
        _curAlpha = 0.3;
        _sync(0);
      }
    }
  }

  void _prune(double now) {
    _bursts.removeWhere((b) => now - b.at > 0.95);
    _ghosts.removeWhere((g) => now - g.at > 0.16);
  }

  /// Diff the latest core state against what we tracked: match gems, spawn effects.
  void _sync(double physMs) {
    final st = s.state;
    if (identical(st, _seen)) return;
    _seen = st;
    final now = _now;
    final g = st['g'] as List? ?? const [];
    final n = g.length ~/ 5;

    // New merges since the last state.
    _freshFx.clear();
    for (final f in (st['fx'] as List? ?? const [])) {
      final l = f as List;
      final id = (l[0] as num).toInt();
      if (id <= _seenFx) continue;
      _seenFx = id;
      _freshFx
        ..add((l[1] as num) / 100)
        ..add((l[2] as num) / 100)
        ..add((l[3] as num).toDouble());
    }

    final prev = _gems;
    final next = _spare..clear();
    var i = 0;
    for (var j = 0; j < n; j++) {
      final x = (g[j * 5] as num) / 100;
      final y = (g[j * 5 + 1] as num) / 100;
      final tier = (g[j * 5 + 2] as num).toInt();
      final ang = (g[j * 5 + 3] as num) / 100;
      final sc = (g[j * 5 + 4] as num).toInt();
      // Survivors keep their order, so the match is the nearest same-tier gem a few slots ahead.
      _Gem? m;
      var mi = -1;
      var best = 18.0 * 18.0;
      for (var k = i; k < prev.length && k < i + 12; k++) {
        final p = prev[k];
        if (p.tier != tier) continue;
        final d = (p.x - x) * (p.x - x) + (p.y - y) * (p.y - y);
        if (d < best) {
          best = d;
          m = p;
          mi = k;
        }
      }
      if (m != null) {
        for (var k = i; k < mi; k++) {
          _died(prev[k], now);
        }
        i = mi + 1;
        if (physMs > 0) {
          final vy = (y - m.y) / physMs * 1000;
          if (m.falling) {
            if (m.vy > 90 && vy < m.vy * 0.4) {
              // First impact: the fall was stopped abruptly.
              m.falling = false;
              m.squashAt = now;
              m.squashK = (m.vy / 380).clamp(0.35, 1.0);
              HapticFeedback.lightImpact();
            } else if (now - m.born > 3) {
              m.falling = false;
            }
          }
          m.vy = vy;
        }
        m
          ..x = x
          ..y = y
          ..ang = ang
          ..scale = sc;
        next.add(m);
      } else {
        final gem = _Gem(_nextId++, _primed ? now : -10, x, y, tier, ang, sc);
        if (_primed) {
          if (_fxAt(x, y, tier, 3.5) >= 0) {
            gem.popAt = now;
          } else if (tier <= 5 && (y - _spawnY).abs() < 6) {
            gem.falling = true;
          }
        }
        next.add(gem);
      }
    }
    for (var k = i; k < prev.length; k++) {
      _died(prev[k], now);
    }
    _spare = prev;
    _gems = next;

    // Merge effects.
    var heavy = false;
    for (var k = 0; k + 2 < _freshFx.length; k += 3) {
      final x = _freshFx[k], y = _freshFx[k + 1];
      final tier = _freshFx[k + 2].toInt();
      final child = next.any((gm) => gm.popAt == now && gm.tier == tier && (gm.x - x).abs() < 3.5);
      final points = child || tier < 11 ? _values[tier - 1] : _bigBonus + _values[10];
      final count = 6 + (tier ~/ 3).clamp(0, 4);
      final dirs = Float64List(count * 2);
      for (var d = 0; d < count; d++) {
        dirs[d * 2] = (d + _rand.nextDouble() * 0.7) * 2 * math.pi / count;
        dirs[d * 2 + 1] = 0.6 + _rand.nextDouble() * 0.7;
      }
      _bursts.add(_Burst(x, y, tier, points, now, dirs));
      if (tier >= 6) heavy = true;
      if (tier > _bestTier) {
        if (_primed && tier >= _bannerFrom) {
          _bannerTier = tier;
          _bannerAt = now;
        }
        _bestTier = tier;
      }
    }
    if (_freshFx.isNotEmpty) {
      heavy ? HapticFeedback.mediumImpact() : HapticFeedback.lightImpact();
    }

    // Danger proximity: settled gems (not the one in flight) within ~12 units of the line.
    final dl = (st['dl'] as num?)?.toDouble() ?? 26;
    var near = 0.0;
    for (final gm in next) {
      if (gm.falling || now - gm.born < 0.9) continue;
      final top = gm.y - _radius(gm.tier);
      near = math.max(near, (1 - (top - dl) / 12).clamp(0.0, 1.0));
    }
    _near = near;

    if (!_primed) {
      _primed = true;
      for (final gm in next) {
        _bestTier = math.max(_bestTier, gm.tier);
      }
      _bestTier = math.max(_bestTier, 5);
    }
    if (st['status'] == 'won' && _winAt < 0) {
      _winAt = now;
      HapticFeedback.heavyImpact();
    }
  }

  /// Index of a fresh merge of [tier] within [reach] units of (x, y), or -1.
  int _fxAt(double x, double y, int tier, double reach) {
    for (var k = 0; k + 2 < _freshFx.length; k += 3) {
      if (_freshFx[k + 2].toInt() != tier) continue;
      final dx = _freshFx[k] - x, dy = _freshFx[k + 1] - y;
      if (dx * dx + dy * dy < reach * reach) return k;
    }
    return -1;
  }

  void _died(_Gem gm, double now) {
    // A parent of a fresh merge: the child is one tier up (two top-tier gems vanish as tier 11).
    // Positions are from the previous state, so a fast parent may be a frame's travel away.
    final reach = _radius(gm.tier) * 2 + 16;
    var k = _fxAt(gm.x, gm.y, math.min(gm.tier + 1, 11), reach);
    if (k < 0 && gm.tier == 11) k = _fxAt(gm.x, gm.y, 11, reach);
    if (k < 0) return;
    _ghosts.add(_Ghost(gm.x, gm.y, _freshFx[k], _freshFx[k + 1], gm.ang, gm.tier, now));
  }

  bool get _live => !_paused && !s.finished && !s.loading;

  void _aimAt(Offset local, double width) {
    final cur = (s.state['cur'] as num?)?.toInt() ?? 1;
    final r = _radius(cur);
    _aimTarget = (local.dx / _scale).clamp(r, width - r);
  }

  @override
  Widget build(BuildContext context) {
    _sync(0);
    final st = s.state;
    final w = (st['w'] as num?)?.toDouble() ?? 100;
    final h = (st['h'] as num?)?.toDouble() ?? 140;
    final dl = (st['dl'] as num?)?.toDouble() ?? 26;
    final cur = (st['cur'] as num?)?.toInt() ?? 1;
    final next = (st['nx'] as num?)?.toInt() ?? 1;
    final cd = (st['cd'] as num?)?.toDouble() ?? 0;
    final warn = (st['warn'] as num?)?.toDouble() ?? 0;
    final hud = st['hud'] as List? ?? const [];
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final now = _now;
    if (_aimVis < 0 && _aimTarget == null) _aimVis = w / 2;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 4),
          child: Row(
            children: [
              for (final it in hud) Expanded(child: _stat('${(it as List)[0]}', '${it[1]}')),
              Column(
                children: [
                  SizedBox(
                    width: 34,
                    height: 34,
                    child: TweenAnimationBuilder<double>(
                      key: ValueKey(_dropSerial),
                      tween: Tween(begin: 0, end: 1),
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOutBack,
                      builder: (context, t, child) => Transform.scale(scale: 0.55 + 0.45 * t, child: child),
                      child: CustomPaint(painter: _SingleGemPainter(next, dpr)),
                    ),
                  ),
                  Text('Sıradaki', style: Lux.ui(11, color: Lux.muted, spacing: 1)),
                ],
              ),
              const SizedBox(width: 10),
              RimIconButton(_paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                  tooltip: _paused ? 'Devam' : 'Duraklat', onPressed: s.finished ? null : () => _setPaused(!_paused)),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
            child: LayoutBuilder(builder: (context, box) {
              _scale = math.min(box.maxWidth / w, box.maxHeight / h);
              final size = Size(w * _scale, h * _scale);
              return Center(
                child: SizedBox.fromSize(
                  size: size,
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (e) {
                      if (!_live) return;
                      setState(() {
                        _touching = true;
                        _aimAt(e.localPosition, w);
                      });
                    },
                    onPointerMove: (e) {
                      if (!_live) return;
                      _aimAt(e.localPosition, w);
                    },
                    onPointerUp: (e) {
                      if (!_live || !_touching) return;
                      _aimAt(e.localPosition, w);
                      _touching = false;
                      _pendingDrop = _aimTarget;
                    },
                    onPointerCancel: (_) => _touching = false,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: RepaintBoundary(
                            child: CustomPaint(
                              painter: _JarPainter(
                                scale: _scale,
                                w: w,
                                h: h,
                                danger: dl,
                                gems: _gems,
                                ghosts: _ghosts,
                                bursts: _bursts,
                                cur: cur,
                                aim: _aimVis < 0 ? w / 2 : _aimVis,
                                ready: cd <= 0 && _live,
                                curAlpha: _live ? _curAlpha : 0.25,
                                curPop: ((now - _curAt) / 0.26).clamp(0.0, 1.0),
                                touching: _touching,
                                warn: warn,
                                near: _near,
                                winT: _winAt < 0 ? -1 : now - _winAt,
                                now: now,
                                dpr: dpr,
                              ),
                            ),
                          ),
                        ),
                        if (_bannerTier > 0 && now - _bannerAt < 1.75) _banner(now, size),
                        if (_paused)
                          Positioned.fill(
                            child: ColoredBox(
                              color: const Color(0xF20A0705),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(Lux.upper('Duraklatıldı'), style: Lux.display(18)),
                                  const SizedBox(height: 16),
                                  GoldButton('Devam', icon: Icons.play_arrow_rounded, onPressed: () => _setPaused(false)),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }

  /// "Yeni mücevher" banner: springs in, holds, then lifts away.
  Widget _banner(double now, Size size) {
    final t = now - _bannerAt;
    final inT = Curves.easeOutBack.transform((t / 0.32).clamp(0.0, 1.0));
    final out = Curves.easeIn.transform(((t - 1.3) / 0.42).clamp(0.0, 1.0));
    final tier = _bannerTier;
    return Positioned(
      left: 0,
      right: 0,
      top: size.height * 0.30 - 14 * out,
      child: IgnorePointer(
        child: Opacity(
          opacity: ((t / 0.16).clamp(0.0, 1.0) * (1 - out)),
          child: Transform.scale(
            scale: 0.84 + 0.16 * inT,
            child: Center(
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 18, 9),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xF0155A45), Color(0xF0062A21)],
                  ),
                  border: Border.all(color: Lux.gold.withValues(alpha: 0.85), width: 1.2),
                  boxShadow: [
                    BoxShadow(color: _tierColor(tier).withValues(alpha: 0.35), blurRadius: 24),
                    BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 14, offset: const Offset(0, 6)),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 34,
                      height: 34,
                      child: CustomPaint(painter: _SingleGemPainter(tier, MediaQuery.devicePixelRatioOf(context), full: true)),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(Lux.upper('Yeni mücevher · $tier. seviye'),
                            style: Lux.ui(10, color: Lux.gold, weight: FontWeight.w600, spacing: 1.8)),
                        const SizedBox(height: 2),
                        FoilText(_tierNames[tier - 1], style: Lux.display(24, spacing: 1)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _stat(String label, String value) => Column(
        children: [
          Text(value, style: Lux.ui(20, color: Lux.goldLight, weight: FontWeight.w700)),
          Text(label, style: Lux.ui(11, color: Lux.muted, spacing: 1)),
        ],
      );
}

class _SingleGemPainter extends CustomPainter {
  final int tier;
  final double dpr;
  final bool full;
  _SingleGemPainter(this.tier, this.dpr, {this.full = false});

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2 * (full ? 0.95 : (0.55 + 0.09 * tier.clamp(1, 5)));
    _Sprites.draw(canvas, tier, size.center(Offset.zero), r, 0, dpr, showLabel: !full);
  }

  @override
  bool shouldRepaint(_SingleGemPainter old) => old.tier != tier || old.dpr != dpr || old.full != full;
}

/// Cheap deterministic hash in 0..1 for particle layouts that must not allocate per frame.
double _hash(int i) {
  final v = math.sin(i * 12.9898 + 78.233) * 43758.5453;
  return v - v.floorToDouble();
}

class _JarPainter extends CustomPainter {
  final double scale, w, h, danger, aim, warn, near, curAlpha, curPop, winT, now, dpr;
  final List<_Gem> gems;
  final List<_Ghost> ghosts;
  final List<_Burst> bursts;
  final int cur;
  final bool ready, touching;
  _JarPainter({
    required this.scale,
    required this.w,
    required this.h,
    required this.danger,
    required this.gems,
    required this.ghosts,
    required this.bursts,
    required this.cur,
    required this.aim,
    required this.ready,
    required this.curAlpha,
    required this.curPop,
    required this.touching,
    required this.warn,
    required this.near,
    required this.winT,
    required this.now,
    required this.dpr,
  });

  static final Paint _fill = Paint();
  static final Paint _stroke = Paint()..style = PaintingStyle.stroke;
  static final Paint _layer = Paint();
  static Size? _cachedSize;
  static Shader? _bgShader, _wallShader;
  static final Map<int, TextPainter> _pointLabels = {};

  TextPainter _points(int p, double fontSize) {
    final key = p * 100 + fontSize.round();
    return _pointLabels[key] ??= (TextPainter(
      text: TextSpan(
        text: '+$p',
        style: Lux.numeral(fontSize, color: Lux.goldLight).copyWith(
          shadows: [Shadow(color: Colors.black.withValues(alpha: 0.7), blurRadius: 4, offset: const Offset(0, 1))],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout());
  }

  @override
  void paint(Canvas canvas, Size size) {
    final jar = Offset.zero & size;
    if (_cachedSize != size) {
      _cachedSize = size;
      _bgShader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF120D09), Color(0xFF1B140D), Color(0xFF0C0806)],
      ).createShader(jar);
      _wallShader = Lux.goldGradient.createShader(jar);
    }
    final k = (scale / 3.5).clamp(0.7, 1.6); // effect size per screen density of the jar

    // Dark glass interior with a faint vertical sheen.
    canvas.drawRRect(
      RRect.fromRectAndCorners(jar, bottomLeft: const Radius.circular(10), bottomRight: const Radius.circular(10)),
      _fill..shader = _bgShader,
    );
    _fill.shader = null;
    canvas.drawRect(Rect.fromLTWH(size.width * 0.08, 0, size.width * 0.05, size.height),
        _fill..color = Colors.white.withValues(alpha: 0.025));

    // Danger line: breathes bordeaux as settled gems approach; pulses fast once the overflow
    // timer runs.
    final dy = danger * scale;
    final breath = 0.5 + 0.5 * math.sin(now * 2 * math.pi * 1.1);
    final heat = math.max(warn, near * (0.35 + 0.65 * breath));
    if (warn > 0) {
      final pulse = 0.5 + 0.5 * math.sin(now * 11);
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, dy),
          _fill..color = Lux.bordeaux.withValues(alpha: (0.10 + 0.25 * warn) * (0.6 + 0.4 * pulse)));
    }
    if (heat > 0.01) {
      // Soft glow hugging the line from below.
      final band = Rect.fromLTWH(0, dy - 10 * k, size.width, 20 * k);
      canvas.drawRect(
        band,
        _fill
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Lux.bordeaux.withValues(alpha: 0),
              Lux.bordeaux.withValues(alpha: 0.32 * heat),
              Lux.bordeaux.withValues(alpha: 0),
            ],
          ).createShader(band),
      );
      _fill.shader = null;
    }
    _stroke
      ..strokeWidth = 1.6 + 0.8 * heat
      ..strokeCap = StrokeCap.butt
      ..color = Color.lerp(Lux.bordeaux, Lux.bordeauxLight, heat)!.withValues(alpha: 0.55 + 0.45 * heat);
    for (var x = 0.0; x < size.width; x += 12) {
      canvas.drawLine(Offset(x, dy), Offset(math.min(x + 6, size.width), dy), _stroke);
    }

    // Aim guide: dotted line from the waiting gem down to where it will first touch.
    final crU = _radius(cur);
    final cr = crU * scale;
    final ax = aim * scale;
    if (ready) {
      var land = h - crU;
      for (final g in gems) {
        if (g.falling) continue;
        final rr = _radius(g.tier) + crU;
        final dx = (g.x - aim).abs();
        if (dx >= rr || g.y < _spawnY) continue;
        final yc = g.y - math.sqrt(rr * rr - dx * dx);
        if (yc < land) land = yc;
      }
      final top = _spawnY * scale + cr + 5;
      final end = math.max(top, (land + crU) * scale);
      final len = end - top;
      final a0 = touching ? 0.6 : 0.24;
      for (var y = top; y < end; y += 9 * k) {
        final f = len <= 0 ? 0.0 : (y - top) / len;
        canvas.drawCircle(Offset(ax, y), 1.4 * k, _fill..color = Lux.goldLight.withValues(alpha: a0 * (1 - 0.5 * f)));
      }
      if (len > 8) {
        canvas.drawCircle(Offset(ax, end), 3.2 * k,
            _stroke
              ..strokeWidth = 1.2
              ..color = Lux.goldLight.withValues(alpha: a0 * 0.8));
      }
    }

    // Merge parents sliding into each other (under everything else).
    for (final gh in ghosts) {
      final t = ((now - gh.at) / 0.14).clamp(0.0, 1.0);
      if (t >= 1) continue;
      final e = Curves.easeInCubic.transform(t);
      final x = gh.x + (gh.tx - gh.x) * e * 0.85, y = gh.y + (gh.ty - gh.y) * e * 0.85;
      final base = _radius(gh.tier) * scale;
      _Sprites.draw(canvas, gh.tier, Offset(x * scale, y * scale), base * (1 - 0.3 * e), gh.ang, dpr,
          base: base, opacity: 1 - t, showLabel: false);
    }

    // Gems.
    for (final g in gems) {
      final tier = g.tier;
      if (tier < 1 || tier > 11) continue;
      final base = _radius(tier) * scale;
      var r = base * g.scale / 100;
      final pt = now - g.popAt;
      if (pt >= 0 && pt < 0.32) r = base * (0.7 + 0.3 * Curves.easeOutBack.transform(pt / 0.32));
      var sx = 1.0, sy = 1.0;
      final qt = now - g.squashAt;
      if (qt >= 0 && qt < 0.5) {
        final sq = 0.15 * g.squashK * math.exp(-qt * 11) * math.cos(qt * 32);
        sx = 1 + sq;
        sy = 1 - sq;
      }
      // Slow specular breathing, phase-shifted per gem.
      final spec = 0.16 + 0.16 * (0.5 + 0.5 * math.sin(now * 0.9 + g.id * 1.93));
      final c = Offset(g.x * scale, g.y * scale);
      _Sprites.draw(canvas, tier, c, r, g.ang, dpr, base: base, sx: sx, sy: sy, specular: spec);
      // Occasional star glint on the highlight.
      final ph = (now * 0.12 + g.id * 0.618) % 1.0;
      if (ph < 0.05 && r > 6) {
        final a = math.sin(math.pi * ph / 0.05);
        final p = c + Offset(-r * 0.36, -r * 0.42);
        final arm = r * 0.42 * a;
        _stroke
          ..strokeWidth = 1.1 * k
          ..strokeCap = StrokeCap.round
          ..color = Colors.white.withValues(alpha: 0.85 * a);
        canvas.drawLine(p - Offset(arm, 0), p + Offset(arm, 0), _stroke);
        canvas.drawLine(p - Offset(0, arm * 0.8), p + Offset(0, arm * 0.8), _stroke);
        canvas.drawCircle(p, 1.4 * k * a, _fill..color = Colors.white.withValues(alpha: 0.9 * a));
      }
    }

    // The gem waiting to drop: pops in after each drop, brightens when ready.
    final pop = 0.55 + 0.45 * Curves.easeOutBack.transform(curPop);
    _Sprites.draw(canvas, cur, Offset(ax, _spawnY * scale), cr * pop, 0, dpr, base: cr, opacity: curAlpha);

    // Merge bursts: flash ring, sparkles in the child's colour, rising "+points".
    for (final b in bursts) {
      final t = now - b.at;
      final c = Offset(b.x * scale, b.y * scale);
      final r = _radius(b.tier) * scale;
      final col = Color.lerp(_tierColor(b.tier), Colors.white, 0.45)!;
      if (t < 0.25) {
        final u = t / 0.25;
        final e = Curves.easeOutCubic.transform(u);
        if (u < 0.45) {
          canvas.drawCircle(c, r * (0.95 + 0.25 * e), _fill..color = Colors.white.withValues(alpha: 0.42 * (1 - u / 0.45)));
        }
        canvas.drawCircle(
          c,
          r * (0.85 + 1.05 * e),
          _stroke
            ..strokeWidth = (4.5 * (1 - u) + 0.6) * k
            ..color = Color.lerp(Colors.white, col, u)!.withValues(alpha: 0.9 * (1 - u)),
        );
      }
      if (t < 0.62) {
        final u = t / 0.62;
        final e = Curves.easeOutCubic.transform(u);
        _fill.color = col.withValues(alpha: 1 - u * u);
        final d = b.dirs;
        for (var i = 0; i + 1 < d.length; i += 2) {
          final dist = r * (0.9 + 1.25 * d[i + 1] * e);
          final p = c + Offset(math.cos(d[i]) * dist, math.sin(d[i]) * dist + 9 * k * u * u);
          final s = (2.8 * (1 - u) + 0.8) * k;
          final path = Path()
            ..moveTo(p.dx, p.dy - s * 2)
            ..lineTo(p.dx + s * 0.55, p.dy)
            ..lineTo(p.dx, p.dy + s * 2)
            ..lineTo(p.dx - s * 0.55, p.dy)
            ..close()
            ..moveTo(p.dx - s * 2, p.dy)
            ..lineTo(p.dx, p.dy + s * 0.55)
            ..lineTo(p.dx + s * 2, p.dy)
            ..lineTo(p.dx, p.dy - s * 0.55)
            ..close();
          canvas.drawPath(path, _fill);
        }
      }
      if (t < 0.9) {
        final u = t / 0.9;
        final alpha = u < 0.1 ? u / 0.1 : (u > 0.6 ? 1 - (u - 0.6) / 0.4 : 1.0);
        final tp = _points(b.points, (11 + 2.2 * math.sqrt(b.tier.toDouble())) * k);
        final rise = 26 * k * Curves.easeOutCubic.transform(u);
        final pos = c - Offset(tp.width / 2, r * 0.35 + tp.height + rise);
        canvas.saveLayer(Rect.fromLTWH(pos.dx - 4, pos.dy - 4, tp.width + 8, tp.height + 8),
            _layer..color = Colors.white.withValues(alpha: alpha.clamp(0.0, 1.0)));
        tp.paint(canvas, pos);
        canvas.restore();
      }
    }

    // Win: a gold light sweeps up the jar and sparks rise from the floor.
    var flare = 0.0;
    if (winT >= 0 && winT < 1.0) {
      final u = winT / 1.0;
      flare = math.sin(math.pi * u);
      final cy = size.height * (1.15 - 1.4 * Curves.easeInOutCubic.transform(u));
      final band = Rect.fromLTWH(0, cy - 40 * k, size.width, 80 * k);
      canvas.save();
      canvas.clipRect(jar);
      canvas.drawRect(
        band,
        _fill
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Lux.goldLight.withValues(alpha: 0),
              Lux.goldLight.withValues(alpha: 0.22 * flare),
              Lux.goldLight.withValues(alpha: 0),
            ],
          ).createShader(band),
      );
      _fill.shader = null;
      canvas.restore();
      for (var i = 0; i < 26; i++) {
        final delay = _hash(i + 7) * 0.35;
        final v = (winT - delay) / 0.6;
        if (v <= 0 || v >= 1) continue;
        final x = (0.06 + 0.88 * _hash(i)) * size.width;
        final y = size.height * (0.98 - 0.25 * _hash(i + 31)) - v * size.height * (0.25 + 0.2 * _hash(i + 3));
        final s = (1.4 + 1.6 * _hash(i + 13)) * k * (1 - 0.5 * v);
        final a = math.sin(math.pi * v);
        canvas.drawCircle(Offset(x, y), s, _fill..color = (i.isEven ? Lux.goldLight : Lux.gold).withValues(alpha: 0.9 * a));
      }
    }

    // Gold walls (open top).
    final wall = Path()
      ..moveTo(1.5, 0)
      ..lineTo(1.5, size.height - 10)
      ..arcToPoint(Offset(11.5, size.height - 1.5), radius: const Radius.circular(10), clockwise: false)
      ..lineTo(size.width - 11.5, size.height - 1.5)
      ..arcToPoint(Offset(size.width - 1.5, size.height - 10), radius: const Radius.circular(10), clockwise: false)
      ..lineTo(size.width - 1.5, 0);
    canvas.drawPath(
      wall,
      _stroke
        ..strokeWidth = 4 + 4 * flare
        ..strokeCap = StrokeCap.butt
        ..color = Lux.gold.withValues(alpha: 0.35 + 0.5 * flare)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6 + 6 * flare),
    );
    _stroke.maskFilter = null;
    canvas.drawPath(
      wall,
      _fill
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..shader = _wallShader,
    );
    _fill
      ..style = PaintingStyle.fill
      ..shader = null;
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
