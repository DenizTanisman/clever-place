import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// Towers of Hanoi board. Tap a peg to lift its top disk, tap another peg to drop it.
///
/// Motion model: every disk has a visual position that chases its logical slot. A move between
/// pegs flies along a cubic Bézier arc (up → across → down), lands with a damped squash-and-stretch
/// and a small dust ring; lifting overshoots slightly and the held disk hovers; an illegal drop
/// shakes the held disk. Each disk animates independently, so fast play never waits on animation.
Widget hanoiView(BuildContext context, GameSession s) => _HanoiBoard(session: s);

class _HanoiBoard extends StatefulWidget {
  final GameSession session;
  const _HanoiBoard({required this.session});

  @override
  State<_HanoiBoard> createState() => _HanoiBoardState();
}

/// One disk's journey: a cubic Bézier from p0 to p3 over [dur] seconds.
class _Flight {
  final Offset p0, p1, p2, p3;
  final double start, dur;
  final Curve curve;
  final double landing; // squash strength on arrival (0 = none)
  _Flight(this.p0, this.p1, this.p2, this.p3, this.start, this.dur, this.curve, this.landing);

  double progress(double now) => ((now - start) / dur).clamp(0.0, 1.0);
  bool done(double now) => now >= start + dur;

  Offset at(double now) {
    final e = curve.transform(progress(now));
    final u = 1 - e;
    return p0 * (u * u * u) + p1 * (3 * u * u * e) + p2 * (3 * u * e * e) + p3 * (e * e * e);
  }
}

class _Landing {
  final double at, strength;
  _Landing(this.at, this.strength);
}

class _HanoiBoardState extends State<_HanoiBoard> with SingleTickerProviderStateMixin {
  int? _selected;

  // Drag and drop: the disk follows the finger; release over a peg to drop it there.
  int? _dragDisk, _dragFrom, _hoverPeg, _released;
  Offset _dragPos = Offset.zero, _grab = Offset.zero;
  double _pegW = 1;
  Offset Function(int)? _visualFn;
  late final Ticker _ticker = createTicker((_) => _onTick());
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;

  final Map<int, _Flight> _flights = {};
  final Map<int, _Landing> _landings = {};
  final Map<int, Offset> _targets = {};
  Size? _layout;
  int _layoutKey = 0;
  int? _shakeDisk;
  double _shakeAt = -10;
  double _winAt = -1;

  GameSession get s => widget.session;

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  bool _busy(double now) =>
      _flights.isNotEmpty ||
      _landings.values.any((l) => now - l.at < 0.6) ||
      now - _shakeAt < 0.5 ||
      _selected != null ||
      _dragDisk != null ||
      s.state['hint'] is List ||
      (_winAt >= 0 && now - _winAt < 2.2);

  void _kick() {
    if (!_ticker.isActive) _ticker.start();
  }

  void _onTick() {
    final now = _now;
    // Retire finished flights; arcs end in a landing.
    final done = [for (final e in _flights.entries) if (e.value.done(now)) e.key];
    for (final k in done) {
      final f = _flights.remove(k)!;
      if (f.landing > 0) {
        _landings[k] = _Landing(f.start + f.dur, f.landing);
        HapticFeedback.lightImpact();
      }
    }
    _landings.removeWhere((_, l) => now - l.at > 0.7);
    if (!_busy(now)) _ticker.stop();
    if (mounted) setState(() {});
  }

  int? _topDisk(List<List<int>> pegs, int peg) => pegs[peg].isEmpty ? null : pegs[peg].last;

  int _pegAt(double x, int n) => (x / _pegW).floor().clamp(0, n - 1);

  static bool _legal(List<List<int>> pegs, int from, int to, bool adjacent) =>
      from != to &&
      (!adjacent || (from - to).abs() == 1) &&
      pegs[from].isNotEmpty &&
      (pegs[to].isEmpty || pegs[to].last > pegs[from].last);

  void _dragStart(Offset p, List<List<int>> pegs) {
    if (s.finished) return;
    final i = _pegAt(p.dx, pegs.length);
    if (pegs[i].isEmpty) return;
    final sz = pegs[i].last;
    final v = _visualFn?.call(sz) ?? p;
    HapticFeedback.selectionClick();
    setState(() {
      _flights.remove(sz);
      _selected = null;
      _dragDisk = sz;
      _dragFrom = i;
      _hoverPeg = i;
      _grab = p - v;
      _dragPos = v;
    });
    _kick();
  }

  void _dragUpdate(Offset p, int n) {
    if (_dragDisk == null) return;
    final hover = _pegAt(p.dx, n);
    if (hover != _hoverPeg) HapticFeedback.selectionClick();
    setState(() {
      _dragPos = p - _grab;
      _hoverPeg = hover;
    });
  }

  void _dragEnd() {
    final sz = _dragDisk;
    if (sz == null) return;
    final from = _dragFrom!, to = _hoverPeg ?? from;
    // The settle flight starts exactly where the finger let go.
    _targets[sz] = _dragPos;
    _released = sz;
    _dragDisk = null;
    _dragFrom = null;
    _hoverPeg = null;
    if (to != from && !s.finished) {
      final ok = s.act({'from': from, 'to': to});
      if (!ok) {
        HapticFeedback.mediumImpact();
        _shakeDisk = sz;
        _shakeAt = _now;
      }
    }
    if (mounted) setState(() {});
    _kick();
  }

  void _tapPeg(int i, List<List<int>> pegs) {
    if (s.finished) return;
    final sel = _selected;
    if (sel == null) {
      if (pegs[i].isNotEmpty) {
        HapticFeedback.selectionClick();
        setState(() => _selected = i);
      }
      return;
    }
    if (sel == i) {
      setState(() => _selected = null);
      return;
    }
    final ok = s.act({'from': sel, 'to': i});
    if (ok) {
      setState(() => _selected = null);
    } else {
      // Keep it in hand and shake: the player can pick another peg straight away.
      HapticFeedback.mediumImpact();
      setState(() {
        _shakeDisk = _topDisk(pegs, sel);
        _shakeAt = _now;
      });
      _kick();
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = s.state;
    final pegs = [for (final p in st['pegs'] as List) [for (final d in p as List) (d as num).toInt()]];
    final disks = (st['disks'] as num).toInt();
    final target = (st['target'] as num).toInt();
    final hint = st['hint'] is List ? [for (final h in st['hint'] as List) (h as num).toInt()] : null;
    final adjacent = st['adjacent_only'] == true;
    final won = st['status'] == 'won';

    return Column(
      children: [
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _stat('Hamle', '${st['moves']}'),
            const SizedBox(width: 28),
            _stat('En az', '${st['optimal']}'),
            const SizedBox(width: 28),
            _stat('Kalan (en iyi)', '${st['remaining_optimal']}'),
          ],
        ),
        if (adjacent)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('Bu bölümde disk sadece yanındaki direğe gidebilir',
                style: Lux.ui(13, color: Lux.bordeauxLight)),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
            child: LayoutBuilder(builder: (context, box) {
              final now = _now;
              final w = box.maxWidth, h = box.maxHeight;
              final n = pegs.length;
              final pegW = w / n;
              final baseY = h * 0.80;
              final diskH = ((h * 0.6) / (disks + 1.5)).clamp(12.0, 52.0);
              final postTop = baseY - diskH * (disks + 1.2);
              final hoverY = postTop - diskH * 1.6;
              double dwOf(int size) => pegW * (0.3 + 0.64 * size / disks);

              // A new layout (rotation, first frame) snaps everything into place without animating.
              final size = Size(w, h);
              if (_layout != size) {
                _layout = size;
                _layoutKey++;
                _targets.clear();
                _flights.clear();
              }

              // Where each disk should be right now.
              final slots = <int, Offset>{};
              final pegOf = <int, int>{};
              for (var p = 0; p < n; p++) {
                for (var k = 0; k < pegs[p].length; k++) {
                  final sz = pegs[p][k];
                  final cx = pegW * p + pegW / 2;
                  final lifted = k == pegs[p].length - 1 && _selected == p;
                  slots[sz] = Offset(cx - dwOf(sz) / 2, lifted ? hoverY : baseY - diskH * (k + 1));
                  pegOf[sz] = p;
                }
              }

              Offset visual(int sz) =>
                  sz == _dragDisk ? _dragPos : (_flights[sz]?.at(now) ?? _targets[sz] ?? slots[sz]!);
              _pegW = pegW;
              _visualFn = visual;

              // Launch flights for every disk whose slot changed.
              for (final e in slots.entries) {
                final sz = e.key, to = e.value;
                if (sz == _dragDisk) continue;
                final prev = _targets[sz];
                if (prev == null) {
                  _targets[sz] = to;
                  continue;
                }
                if ((prev - to).distanceSquared < 0.25) continue;
                final from = visual(sz);
                _targets[sz] = to;
                if (sz == _released) {
                  // Dropped from the finger: glide straight into the slot and land.
                  final d = (to - from).distance;
                  _flights[sz] = _Flight(from, Offset.lerp(from, to, 1 / 3)!, Offset.lerp(from, to, 2 / 3)!, to, now,
                      (0.13 + d / 2400).clamp(0.13, 0.3), Curves.easeOutCubic, 0.85);
                  continue;
                }
                final pegDist = ((to.dx - from.dx).abs() / pegW).round();
                if (pegDist >= 1) {
                  // Arc: control points straight above both ends, tuned so the apex clears the posts.
                  final apex = hoverY - diskH * 0.35;
                  final c = (apex - 0.125 * from.dy - 0.125 * to.dy) / 0.75;
                  _flights[sz] = _Flight(from, Offset(from.dx, c), Offset(to.dx, c), to, now,
                      0.30 + 0.06 * pegDist, const Cubic(0.45, 0.0, 0.25, 1.0), 1.0);
                } else if (to.dy < from.dy) {
                  // Lift: quick rise with a little overshoot.
                  _flights[sz] = _Flight(from, Offset.lerp(from, to, 1 / 3)!, Offset.lerp(from, to, 2 / 3)!, to, now, 0.22,
                      Curves.easeOutBack, 0);
                } else {
                  // Put back down: accelerate like a falling weight, then a soft bump.
                  _flights[sz] = _Flight(from, Offset.lerp(from, to, 1 / 3)!, Offset.lerp(from, to, 2 / 3)!, to, now, 0.2,
                      Curves.easeInCubic, 0.55);
                }
              }
              _targets.removeWhere((k, _) => !slots.containsKey(k));
              _released = null;

              if (won && _winAt < 0) {
                final lastLanding = _flights.values.fold<double>(now, (m, f) => math.max(m, f.start + f.dur));
                _winAt = lastLanding + 0.08;
              } else if (!won) {
                _winAt = -1;
              }
              if (_busy(now)) _kick();

              final children = <Widget>[];
              final pulse = 0.5 + 0.5 * math.sin(now * 5.5);

              children.add(Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) => _tapPeg(_pegAt(d.localPosition.dx, n), pegs),
                  onPanStart: (d) => _dragStart(d.localPosition, pegs),
                  onPanUpdate: (d) => _dragUpdate(d.localPosition, n),
                  onPanEnd: (_) => _dragEnd(),
                  onPanCancel: _dragEnd,
                ),
              ));
              final dragLegal = _dragDisk != null && _hoverPeg != null && _hoverPeg != _dragFrom
                  ? _legal(pegs, _dragFrom!, _hoverPeg!, adjacent)
                  : null;

              // Peg posts.
              for (var i = 0; i < n; i++) {
                final cx = pegW * i + pegW / 2;
                final isHint = hint != null && (hint[0] == i || hint[1] == i);
                final isSel = _selected == i;
                final winGlow = won && i == target && _winAt >= 0 && now >= _winAt;
                final hover = _hoverPeg == i && _hoverPeg != _dragFrom ? dragLegal : null;
                final bad = hover == false;
                final hot = isSel || isHint || winGlow || hover == true;
                children.add(Positioned(
                  left: cx - 4,
                  top: postTop,
                  width: 8,
                  height: baseY - postTop,
                  child: IgnorePointer(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        gradient: LinearGradient(colors: [
                          bad ? Lux.bordeauxLight : (hot ? Lux.goldLight : Lux.goldDeep),
                          bad ? Lux.bordeaux : (hot ? Lux.gold : const Color(0xFF5A4413)),
                        ]),
                        boxShadow: isHint || winGlow
                            ? [BoxShadow(color: Lux.gold.withValues(alpha: 0.35 + 0.45 * pulse), blurRadius: 10 + 10 * pulse)]
                            : hover != null
                                ? [BoxShadow(color: (bad ? Lux.bordeaux : Lux.gold).withValues(alpha: 0.7), blurRadius: 16)]
                                : null,
                      ),
                    ),
                  ),
                ));
                children.add(Positioned(
                  left: cx - pegW * 0.45,
                  top: baseY + 6,
                  width: pegW * 0.9,
                  child: IgnorePointer(
                    child: Text(i == target ? 'HEDEF' : '${i + 1}',
                        textAlign: TextAlign.center,
                        style: Lux.ui(12, color: i == target ? Lux.gold : Lux.muted, spacing: 2)),
                  ),
                ));
              }
              // Base.
              children.add(Positioned(
                left: 4,
                right: 4,
                top: baseY,
                height: 6,
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(3), gradient: Lux.goldGradient),
                  ),
                ),
              ));

              // Dust rings where disks just landed.
              for (final e in _landings.entries) {
                final k = now - e.value.at;
                if (k < 0 || k > 0.45 || !slots.containsKey(e.key)) continue;
                final pos = slots[e.key]!;
                final dw = dwOf(e.key);
                final t = k / 0.45;
                final rw = dw * (1.0 + 0.35 * Curves.easeOut.transform(t));
                children.add(Positioned(
                  left: pos.dx + dw / 2 - rw / 2,
                  top: pos.dy + diskH - 2 - diskH * 0.22,
                  width: rw,
                  height: diskH * 0.44,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.all(Radius.elliptical(rw / 2, diskH * 0.22)),
                        border: Border.all(
                            color: Lux.goldLight.withValues(alpha: 0.55 * (1 - t) * e.value.strength), width: 1.5),
                      ),
                    ),
                  ),
                ));
              }

              // Disks: the moving ones are painted last so they fly over everything.
              final order = slots.keys.toList()
                ..sort((a, b) {
                  final fa = a == _dragDisk ? 2 : (_flights.containsKey(a) || (_selected != null && pegOf[a] == _selected) ? 1 : 0);
                  final fb = b == _dragDisk ? 2 : (_flights.containsKey(b) || (_selected != null && pegOf[b] == _selected) ? 1 : 0);
                  return fa != fb ? fa - fb : b - a;
                });
              for (final sz in order) {
                var pos = visual(sz);
                final dw = dwOf(sz);
                final flying = _flights.containsKey(sz);
                final held = !flying && _selected != null && pegOf[sz] == _selected && pegs[_selected!].last == sz;
                if (held) pos += Offset(0, math.sin(now * 2 * math.pi * 0.75) * diskH * 0.07);
                if (sz == _shakeDisk) {
                  final k = now - _shakeAt;
                  if (k < 0.45) pos += Offset(math.sin(k * 48) * 7 * math.exp(-k * 7), 0);
                }
                // Victory: a ripple of hops up the finished tower.
                if (_winAt >= 0 && pegOf[sz] == target) {
                  final idx = pegs[target].indexOf(sz);
                  final local = now - _winAt - 0.07 * idx;
                  if (local > 0 && local < 0.36) pos -= Offset(0, math.sin(math.pi * local / 0.36) * diskH * 0.55);
                }
                final dragging = sz == _dragDisk;
                var sx = dragging ? 1.07 : 1.0, sy = dragging ? 1.07 : 1.0;
                final land = _landings[sz];
                if (land != null) {
                  final k = now - land.at;
                  if (k >= 0) {
                    final sq = 0.16 * land.strength * math.exp(-k * 10) * math.cos(k * 30);
                    sx = 1 + sq;
                    sy = 1 - sq;
                  }
                } else if (flying) {
                  // Stretch slightly along the direction of travel while airborne.
                  final f = _flights[sz]!;
                  if (f.landing >= 1) {
                    final p = f.progress(now);
                    final st = 0.06 * math.sin(math.pi * p);
                    sx = 1 - st;
                    sy = 1 + st;
                  }
                }
                final t = disks == 1 ? 0.0 : (sz - 1) / (disks - 1);
                final color = Color.lerp(Lux.gold, Lux.bordeaux, t)!;
                final glow = held || flying || dragging || (_winAt >= 0 && now >= _winAt && pegOf[sz] == target);
                children.add(Positioned(
                  key: ValueKey('disk$sz-$_layoutKey'),
                  left: pos.dx,
                  top: pos.dy,
                  width: dw,
                  height: diskH - 2,
                  child: IgnorePointer(
                    child: Transform(
                      alignment: Alignment.bottomCenter,
                      transform: Matrix4.diagonal3Values(sx, sy, 1),
                      child: CustomPaint(
                        painter: _DiskPainter(color: color, label: diskH > 18 ? '$sz' : null, glow: glow),
                      ),
                    ),
                  ),
                ));
              }
              return Stack(clipBehavior: Clip.none, children: children);
            }),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              RimIconButton(Icons.undo_rounded, tooltip: 'Geri al (hamle sayılır)',
                  onPressed: st['can_undo'] == true && !s.finished
                      ? () {
                          setState(() => _selected = null);
                          s.act({'undo': true});
                        }
                      : null),
              const SizedBox(width: 24),
              RimIconButton(Icons.lightbulb_outline_rounded, tooltip: 'İpucu: en iyi hamle',
                  onPressed: s.finished
                      ? null
                      : () {
                          s.act({'hint': true});
                          _kick();
                        }),
            ],
          ),
        ),
      ],
    );
  }

  Widget _stat(String label, String value) => Column(
        children: [
          Text(value, style: Lux.ui(24, color: Lux.goldLight, weight: FontWeight.w700)),
          Text(label, style: Lux.ui(12, color: Lux.muted, spacing: 1)),
        ],
      );
}

/// Lacquered disk: vertical body gradient, a glossy top highlight, thin rim and drop shadow.
class _DiskPainter extends CustomPainter {
  final Color color;
  final String? label;
  final bool glow;
  _DiskPainter({required this.color, required this.label, required this.glow});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final r = Radius.circular(h / 2);
    final body = RRect.fromRectAndRadius(Offset.zero & size, r);
    canvas.drawRRect(
      body.shift(Offset(0, glow ? 6 : 2.5)),
      Paint()
        ..color = (glow ? color.withValues(alpha: 0.55) : Colors.black.withValues(alpha: 0.55))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, glow ? 12 : 3.5),
    );
    canvas.drawRRect(
      body,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(color, Colors.white, 0.42)!,
            color,
            Color.lerp(color, Colors.black, 0.18)!,
            Color.lerp(color, Colors.black, 0.5)!,
          ],
          stops: const [0, 0.42, 0.75, 1],
        ).createShader(Offset.zero & size),
    );
    // Gloss band.
    final gloss = RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.12, h * 0.1, w * 0.76, h * 0.26), Radius.circular(h * 0.13));
    canvas.drawRRect(
      gloss,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white.withValues(alpha: 0.5), Colors.white.withValues(alpha: 0.0)],
        ).createShader(gloss.outerRect),
    );
    canvas.drawRRect(
      body.deflate(0.6),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Color.lerp(color, Colors.white, 0.55)!.withValues(alpha: 0.5),
    );
    if (label != null) {
      final tp = TextPainter(
        text: TextSpan(text: label, style: Lux.ui(h * 0.52, color: const Color(0xFF1A1206), weight: FontWeight.w800)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset((w - tp.width) / 2, (h - tp.height) / 2));
    }
  }

  @override
  bool shouldRepaint(_DiskPainter old) => old.color != color || old.label != label || old.glow != glow;
}
