import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Shared renderer for the procedural scenes of `core/src/games/scene.rs` (Değişimi Yakala and
/// Sahne Hafızası).
///
/// Rust owns all geometry: every item arrives with its box in canvas units (1000 × 800) and people
/// with their part boxes (hat, head, hair, face, torso, legs, hand, bag, seat). This file only
/// decides how things look — a warm, flat vector illustration with soft shadows — and always draws
/// inside those boxes, so the change boxes Rust uses for tap detection match the picture.
///
/// Rendering is cached: the first paint of a scene records it into a `Picture`, rasterises it once
/// at the target pixel size (`toImageSync`) and keeps the image in a small LRU, so flicker frames
/// and rebuilds just blit an image.
class SceneArt {
  SceneArt._();

  static const double w = 1000;
  static const double h = 800;
  static const double aspect = w / h;

  static final Map<String, ui.Image> _cache = {};
  static const int _maxCache = 10;

  /// Cached raster of [scene] at [px] physical pixels.
  static ui.Image image(Map<String, dynamic> scene, Size px) {
    final key = '${scene['key']}@${px.width.round()}x${px.height.round()}';
    final hit = _cache.remove(key);
    if (hit != null) {
      _cache[key] = hit; // most recently used last
      return hit;
    }
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.scale(px.width / w, px.height / h);
    paintScene(c, scene);
    final pic = rec.endRecording();
    final img = pic.toImageSync(px.width.round().clamp(1, 8192), px.height.round().clamp(1, 8192));
    pic.dispose();
    _cache[key] = img;
    while (_cache.length > _maxCache) {
      final k = _cache.keys.first;
      _cache.remove(k)?.dispose();
    }
    return img;
  }

  /// Draw [scene] in canvas units (1000 × 800).
  static void paintScene(Canvas c, Map<String, dynamic> scene) {
    final set = scene['set'] as String? ?? 'kafe';
    final wall = (scene['wall'] as num?)?.toInt() ?? 0;
    final floor = (scene['floor'] as num?)?.toInt() ?? 0;
    final bg = (scene['bg'] as num?)?.toInt() ?? 0;
    c.save();
    c.clipRect(const Rect.fromLTWH(0, 0, w, h));
    _Background(c, set, wall, floor, bg).paint();
    final items = [for (final i in (scene['items'] as List? ?? const [])) Map<String, dynamic>.from(i as Map)];
    final byId = {for (final i in items) (i['id'] as num).toInt(): i};
    // Contact shadows first, so nothing is darkened twice.
    for (final it in items) {
      _shadow(c, it, byId);
    }
    for (final it in items) {
      _ItemPainter(c, it).paint();
    }
    // Warm light from the top-left and a soft vignette.
    const full = Rect.fromLTWH(0, 0, w, h);
    c.drawRect(
      full,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.7, -0.9),
          radius: 1.3,
          colors: [Color(0x1CFFF1D0), Color(0x00FFF1D0)],
        ).createShader(full),
    );
    c.drawRect(
      full,
      Paint()
        ..shader = const RadialGradient(
          radius: 0.95,
          colors: [Color(0x00000000), Color(0x00000000), Color(0x30000000)],
          stops: [0, 0.7, 1],
        ).createShader(full),
    );
    c.restore();
  }

  static void _shadow(Canvas c, Map<String, dynamic> it, Map<int, Map<String, dynamic>> byId) {
    final k = it['k'] as String;
    final r = (it['r'] as num).toInt();
    if (r == 3) return;
    final x = _d(it['x']), y = _d(it['y']), bw = _d(it['w']), bh = _d(it['h']), s = _d(it['s']);
    double foot = y + bh;
    double sw = bw;
    if (it['on'] != null) {
      final sup = byId[(it['on'] as num).toInt()];
      if (sup == null) return;
      final sk = sup['k'];
      if (sk == 'tree' || sk == 'lamp') return; // birds up high
      if (sk == 'table' && (k == 'cat' || k == 'dog')) {
        foot = y + bh;
      } else {
        // Objects on a surface: a tight contact shadow.
        c.drawOval(Rect.fromCenter(center: Offset(x + bw / 2, foot - 1), width: bw * 0.95, height: 6 * s),
            Paint()..color = const Color(0x33000000)..maskFilter = MaskFilter.blur(BlurStyle.normal, 2 * s));
        return;
      }
    }
    if (k == 'person') {
      final p = it['p'] as Map;
      if (p['sit'] == true) {
        final legs = _rect(p['parts']['legs']);
        foot = legs.top + 87 * s;
        sw = bw * 1.1;
      } else {
        sw = bw * 0.75;
      }
    }
    if (k == 'parasol' || k == 'lamp') sw = bw * 0.35;
    if (k == 'tree') sw = bw * 0.55;
    if (k == 'bench' && it['on'] == null) sw = bw * 1.02;
    c.drawOval(
      Rect.fromCenter(center: Offset(x + bw / 2, foot - 2 * s), width: sw, height: math.max(10, 16 * s)),
      Paint()
        ..color = const Color(0x40000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6 * s),
    );
  }
}

/// Paints a cached scene image to fill its box (keeps 5:4).
class SceneView extends StatelessWidget {
  final Map<String, dynamic> scene;
  final double radius;
  const SceneView({super.key, required this.scene, this.radius = 14});

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CustomPaint(painter: _ScenePainter(scene, dpr), size: Size.infinite),
    );
  }
}

class _ScenePainter extends CustomPainter {
  final Map<String, dynamic> scene;
  final double dpr;
  _ScenePainter(this.scene, this.dpr);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final img = SceneArt.image(scene, size * dpr);
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_ScenePainter old) => old.scene['key'] != scene['key'] || old.dpr != dpr;
}

// ------------------------------------------------------------------------------------------ colours

const _palette = {
  'kirmizi': Color(0xFFD6463E),
  'mavi': Color(0xFF3D78C9),
  'yesil': Color(0xFF4E9E5C),
  'sari': Color(0xFFEDC14A),
  'turuncu': Color(0xFFEC8637),
  'mor': Color(0xFF8A59B8),
  'pembe': Color(0xFFEE9BC0),
  'siyah': Color(0xFF2E2B2E),
  'beyaz': Color(0xFFF5F1E8),
  'gri': Color(0xFF9D9EA2),
  'kahve': Color(0xFF8B5A3A),
};

/// "kirmizi", "kirmizi:1" (lighter), "kirmizi:-1" (darker).
Color tone(Object? t) {
  final s = (t as String?) ?? 'gri';
  final i = s.indexOf(':');
  final base = _palette[i < 0 ? s : s.substring(0, i)] ?? const Color(0xFF9D9EA2);
  if (i < 0) return base;
  final shade = int.tryParse(s.substring(i + 1)) ?? 0;
  if (shade > 0) return Color.lerp(base, Colors.white, 0.26)!;
  if (shade < 0) return Color.lerp(base, Colors.black, 0.24)!;
  return base;
}

Color _dark(Color c, [double t = 0.25]) => Color.lerp(c, const Color(0xFF1A1210), t)!;
Color _light(Color c, [double t = 0.25]) => Color.lerp(c, Colors.white, t)!;
double _lum(Color c) => c.computeLuminance();

const _skins = [Color(0xFFF4D3B6), Color(0xFFE9BA90), Color(0xFFCB9064), Color(0xFF9E6642), Color(0xFF6F452B)];
const _hairs = {
  'siyah': Color(0xFF2B2422),
  'kahve': Color(0xFF6B4428),
  'sari': Color(0xFFE2BF73),
  'kizil': Color(0xFFB4512A),
  'gri': Color(0xFFBDB8B0),
};

double _d(Object? v) => (v as num?)?.toDouble() ?? 0;
Rect _rect(Object? v) {
  final l = v as List;
  return Rect.fromLTWH(_d(l[0]), _d(l[1]), _d(l[2]), _d(l[3]));
}

int _hash(int a, [int b = 0]) {
  var x = (a * 73856093) ^ (b * 19349663) ^ 0x5bd1e995;
  x = (x ^ (x >> 13)) * 0x5bd1e995;
  return (x ^ (x >> 15)) & 0x7fffffff;
}

Paint _fill(Color c) => Paint()..color = c;
Paint _stroke(Color c, double w) => Paint()
  ..color = c
  ..style = PaintingStyle.stroke
  ..strokeWidth = w
  ..strokeCap = StrokeCap.round
  ..strokeJoin = StrokeJoin.round;

// --------------------------------------------------------------------------------------- background

class _Background {
  final Canvas c;
  final String set;
  final int wall, floor, bg;
  _Background(this.c, this.set, this.wall, this.floor, this.bg);

  static const horizon = 440.0;

  void paint() {
    switch (set) {
      case 'park':
        _sky();
        _hills(const Color(0xFFA8CE96), const Color(0xFF8FBE7F));
        _grass();
        break;
      case 'plaj':
        _sky();
        _sea();
        _sand();
        break;
      case 'sokak':
        _sky();
        _facade();
        _pavement();
        break;
      default:
        _indoor();
    }
  }

  void _sky() {
    const r = Rect.fromLTWH(0, 0, 1000, horizon + 2);
    c.drawRect(
      r,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: bg == 3
              ? const [Color(0xFFF2C79B), Color(0xFFF7E3C4)] // golden hour
              : const [Color(0xFFA9D8EE), Color(0xFFE6F4F4)],
        ).createShader(r),
    );
    // Sun and clouds.
    final sun = Offset(160 + bg * 210.0, 95);
    c.drawCircle(sun, 70, Paint()..color = const Color(0x33FFF3C0)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30));
    c.drawCircle(sun, 34, _fill(const Color(0xFFFFE9A6)));
    for (var i = 0; i < 3; i++) {
      final cx = (bg * 337 + i * 310 + 120) % 1000.0;
      final cy = 70.0 + ((bg + i) % 3) * 38;
      _cloud(Offset(cx, cy), 1.0 - i * 0.15);
    }
  }

  void _cloud(Offset o, double k) {
    final p = _fill(const Color(0xF2FFFFFF));
    c.drawOval(Rect.fromCenter(center: o, width: 120 * k, height: 34 * k), p);
    c.drawCircle(o.translate(-22 * k, -12 * k), 22 * k, p);
    c.drawCircle(o.translate(14 * k, -16 * k), 27 * k, p);
  }

  void _hills(Color a, Color b) {
    final p1 = Path()..moveTo(0, horizon);
    for (double x = 0; x <= 1000; x += 50) {
      p1.lineTo(x, horizon - 40 - 28 * math.sin((x + bg * 90) / 160));
    }
    p1
      ..lineTo(1000, horizon)
      ..close();
    c.drawPath(p1, _fill(a));
    final p2 = Path()..moveTo(0, horizon);
    for (double x = 0; x <= 1000; x += 50) {
      p2.lineTo(x, horizon - 14 - 18 * math.sin((x + 300 + bg * 50) / 110));
    }
    p2
      ..lineTo(1000, horizon)
      ..close();
    c.drawPath(p2, _fill(b));
    // Distant tree dots.
    for (var i = 0; i < 9; i++) {
      final x = (i * 117 + bg * 41) % 1000.0;
      final y = horizon - 30 - (i % 3) * 8.0;
      c.drawCircle(Offset(x, y), 13, _fill(const Color(0xFF79AE6B)));
    }
  }

  void _grass() {
    const r = Rect.fromLTWH(0, horizon, 1000, 800 - horizon);
    c.drawRect(
      r,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF9CCB7C), Color(0xFF79B160)],
        ).createShader(r),
    );
    // A winding gravel path.
    final path = Path()
      ..moveTo(420 + bg * 30.0, horizon)
      ..cubicTo(380, 560, 700, 600, 560, 800)
      ..lineTo(820, 800)
      ..cubicTo(900, 620, 520, 560, 500 + bg * 30.0, horizon)
      ..close();
    c.drawPath(path, _fill(const Color(0xFFE6D6B0)));
    c.drawPath(path, _stroke(const Color(0x33806A40), 3));
    // Grass tufts.
    final tuft = _stroke(const Color(0xFF68A052), 2.2);
    for (var i = 0; i < 46; i++) {
      final x = (i * 97 + bg * 13) % 1000.0;
      final y = horizon + 20 + (i * 53 % 340).toDouble();
      c.drawLine(Offset(x, y), Offset(x - 4, y - 9), tuft);
      c.drawLine(Offset(x + 4, y), Offset(x + 6, y - 10), tuft);
    }
  }

  void _sea() {
    const r = Rect.fromLTWH(0, 340, 1000, horizon - 340 + 4);
    c.drawRect(
      r,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF3F97BE), Color(0xFF79C6D6)],
        ).createShader(r),
    );
    final wave = _stroke(const Color(0x88FFFFFF), 2.4);
    for (var row = 0; row < 4; row++) {
      final y = 356.0 + row * 22;
      for (double x = (row * 40 + bg * 20) % 120 - 60; x < 1000; x += 120) {
        c.drawArc(Rect.fromLTWH(x, y, 40, 10), math.pi, math.pi, false, wave);
      }
    }
    // A distant sail.
    final sx = 700.0 - bg * 140;
    c.drawPath(Path()..moveTo(sx, 300)..lineTo(sx, 345)..lineTo(sx + 30, 345)..close(), _fill(const Color(0xFFF7F2E6)));
    c.drawRect(Rect.fromLTWH(sx - 12, 345, 52, 8), _fill(const Color(0xFF7B4B33)));
  }

  void _sand() {
    const r = Rect.fromLTWH(0, horizon, 1000, 800 - horizon);
    c.drawRect(
      r,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFF2DFB0), Color(0xFFE8C98D)],
        ).createShader(r),
    );
    // Foam line and a few ripples in the sand.
    final foam = Path()..moveTo(0, horizon + 2);
    for (double x = 0; x <= 1000; x += 40) {
      foam.lineTo(x, horizon + 4 + 4 * math.sin(x / 37 + bg));
    }
    c.drawPath(foam, _stroke(const Color(0xCCFFFFFF), 5));
    final ripple = _stroke(const Color(0x22A07A3A), 2);
    for (var i = 0; i < 20; i++) {
      final x = (i * 151 + bg * 37) % 1000.0;
      final y = horizon + 40 + (i * 71 % 320).toDouble();
      c.drawArc(Rect.fromLTWH(x, y, 46, 10), math.pi * 1.1, math.pi * 0.8, false, ripple);
    }
  }

  void _facade() {
    const fac = [Color(0xFFDDA987), Color(0xFFCDB89C), Color(0xFFE6CCA0), Color(0xFFB9C4C7)];
    final col = fac[wall % 4];
    const r = Rect.fromLTWH(0, 40, 1000, horizon - 40);
    c.drawRect(r, _fill(col));
    // Roof line, cornice and a neighbour building.
    c.drawRect(const Rect.fromLTWH(0, 40, 1000, 16), _fill(_dark(col, 0.25)));
    c.drawRect(Rect.fromLTWH(bg.isEven ? 0 : 620, 40, 380, horizon - 40), _fill(_dark(col, 0.08)));
    // Brick or plaster texture.
    final line = _stroke(_dark(col, 0.12), 1.2);
    if (wall.isEven) {
      for (double y = 70; y < horizon; y += 22) {
        c.drawLine(Offset(0, y), Offset(1000, y), line);
        for (double x = (y ~/ 22).isEven ? 0 : 30; x < 1000; x += 60) {
          c.drawLine(Offset(x, y), Offset(x, y + 22), line);
        }
      }
    }
    // Shop awning band.
    c.drawRect(const Rect.fromLTWH(0, horizon - 26, 1000, 26), _fill(_dark(col, 0.32)));
  }

  void _pavement() {
    const r = Rect.fromLTWH(0, horizon, 1000, 800 - horizon);
    const paves = [Color(0xFFCFC8BD), Color(0xFFC4BEB6), Color(0xFFD7CDBE), Color(0xFFBFC3C2)];
    final col = paves[floor % 4];
    c.drawRect(r, _fill(col));
    final line = _stroke(_dark(col, 0.14), 1.6);
    _perspectiveGrid(line, 70);
    c.drawRect(const Rect.fromLTWH(0, horizon, 1000, 8), _fill(_dark(col, 0.25)));
  }

  /// Floor lines converging to a vanishing point above the middle.
  void _perspectiveGrid(Paint line, double step) {
    const vp = Offset(500, 120);
    for (double x = -1200; x <= 2200; x += step * 1.6) {
      final t = (horizon - vp.dy) / (800 - vp.dy);
      final top = Offset(vp.dx + (x - vp.dx) * t, horizon);
      c.drawLine(top, Offset(x, 800), line);
    }
    double y = horizon + 14;
    double gap = 18;
    while (y < 800) {
      c.drawLine(Offset(0, y), Offset(1000, y), line);
      gap *= 1.28;
      y += gap;
    }
  }

  void _indoor() {
    const walls = {
      'kafe': [Color(0xFFEAD7BC), Color(0xFFD9BF9C), Color(0xFFCADCC7), Color(0xFFE9C8B1)],
      'oda': [Color(0xFFE8DDCD), Color(0xFFD5DFE5), Color(0xFFEBD8CE), Color(0xFFDCE4D0)],
      'ofis': [Color(0xFFE2E5E6), Color(0xFFDBE2D8), Color(0xFFE9E2D3), Color(0xFFD6DDE6)],
      'mutfak': [Color(0xFFF0E6D2), Color(0xFFE1EADD), Color(0xFFF1DFD0), Color(0xFFDFE6EC)],
      'istasyon': [Color(0xFFE5DECB), Color(0xFFD8DDD6), Color(0xFFE8D9C2), Color(0xFFD3DADF)],
    };
    final wc = (walls[set] ?? walls['kafe']!)[wall % 4];
    const wr = Rect.fromLTWH(0, 0, 1000, horizon);
    c.drawRect(
      wr,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_light(wc, 0.08), _dark(wc, 0.06)],
        ).createShader(wr),
    );
    switch (set) {
      case 'oda':
        // Wallpaper: soft stripes or small diamonds.
        final p = _fill(_dark(wc, 0.05));
        if (bg.isEven) {
          for (double x = 0; x < 1000; x += 46) {
            c.drawRect(Rect.fromLTWH(x, 0, 18, horizon - 60), p);
          }
        } else {
          for (double y = 20; y < horizon - 70; y += 40) {
            for (double x = (y ~/ 40).isEven ? 20 : 40; x < 1000; x += 40) {
              c.drawPath(Path()..moveTo(x, y - 5)..lineTo(x + 5, y)..lineTo(x, y + 5)..lineTo(x - 5, y)..close(), p);
            }
          }
        }
        _wainscot(wc, 60);
        break;
      case 'mutfak':
        // Tiled backsplash.
        const tr = Rect.fromLTWH(0, 250, 1000, horizon - 250);
        c.drawRect(tr, _fill(_light(wc, 0.35)));
        final g = _stroke(_dark(wc, 0.12), 1.4);
        for (double y = 250; y <= horizon; y += 30) {
          c.drawLine(Offset(0, y), Offset(1000, y), g);
        }
        for (double x = 0; x <= 1000; x += 30) {
          c.drawLine(Offset(x, 250), Offset(x, horizon), g);
        }
        break;
      case 'istasyon':
        // Tiles, a dark lower band and a timetable board.
        final g = _stroke(_dark(wc, 0.07), 1.2);
        for (double y = 0; y < horizon; y += 36) {
          c.drawLine(Offset(0, y), Offset(1000, y), g);
        }
        c.drawRect(const Rect.fromLTWH(0, horizon - 110, 1000, 110), _fill(const Color(0xFF2F5B4E)));
        c.drawRect(const Rect.fromLTWH(0, horizon - 116, 1000, 6), _fill(const Color(0xFFD8B25A)));
        break;
      case 'kafe':
        // Wood panelling below, a chalk menu board above.
        _wainscot(wc, 120, wood: true);
        final mx = bg * 230.0 + 40;
        final menu = Rect.fromLTWH(mx, 40, 150, 34);
        c.drawRRect(RRect.fromRectAndRadius(menu, const Radius.circular(4)), _fill(const Color(0xFF2F3A34)));
        final chalk = _stroke(const Color(0xCCF2EEE2), 2);
        for (var i = 0; i < 3; i++) {
          c.drawLine(Offset(mx + 14, 50 + i * 8.0), Offset(mx + 80 + (i * 23 % 50), 50 + i * 8.0), chalk);
        }
        break;
      default:
        _wainscot(wc, 30);
    }
    // Floor.
    const fr = Rect.fromLTWH(0, horizon, 1000, 800 - horizon);
    final floors = {
      'kafe': [const Color(0xFFA9774E), const Color(0xFF8E6343), const Color(0xFFBA8B5F), const Color(0xFF9B6C4A)],
      'oda': [const Color(0xFFB98D63), const Color(0xFFA07650), const Color(0xFFC79D72), const Color(0xFF9C7556)],
      'ofis': [const Color(0xFF8F98A4), const Color(0xFF9DA39B), const Color(0xFFA19A8E), const Color(0xFF87909C)],
      'mutfak': [const Color(0xFFE9E2D4), const Color(0xFFDCD6CC), const Color(0xFFE8DCCB), const Color(0xFFD9DEE0)],
      'istasyon': [const Color(0xFFB9B5AD), const Color(0xFFADAAA4), const Color(0xFFC1B9AB), const Color(0xFFA9AEB0)],
    };
    final fc = (floors[set] ?? floors['kafe']!)[floor % 4];
    c.drawRect(
      fr,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_dark(fc, 0.1), fc],
        ).createShader(fr),
    );
    if (set == 'mutfak') {
      // Checker tiles in perspective.
      _perspectiveGrid(_stroke(_dark(fc, 0.18), 1.5), 64);
    } else if (set == 'ofis') {
      // Carpet: no planks, a subtle weave.
      final dot = _fill(_dark(fc, 0.06));
      for (double y = horizon + 10; y < 800; y += 14) {
        for (double x = (y ~/ 14).isEven ? 0 : 7; x < 1000; x += 14) {
          c.drawCircle(Offset(x, y), 1.3, dot);
        }
      }
    } else if (set == 'istasyon') {
      _perspectiveGrid(_stroke(_dark(fc, 0.12), 1.4), 90);
      c.drawRect(const Rect.fromLTWH(0, 786, 1000, 14), _fill(const Color(0xFFE8C341)));
    } else {
      // Planks.
      final plank = _stroke(_dark(fc, 0.16), 1.6);
      double y = horizon;
      double gap = 16;
      var row = 0;
      while (y < 800) {
        c.drawLine(Offset(0, y), Offset(1000, y), plank);
        final off = (row * 137) % 220;
        for (double x = off.toDouble(); x < 1000; x += 220) {
          c.drawLine(Offset(x, y), Offset(x, y + gap), plank);
        }
        y += gap;
        gap *= 1.16;
        row++;
      }
    }
    if (set == 'oda') {
      // A rug under the middle.
      const rugs = [Color(0xFFB2563F), Color(0xFF4F6E8E), Color(0xFF7E8C4A), Color(0xFF9B5A7A)];
      final rc = rugs[bg % 4];
      final rug = Path()
        ..moveTo(260, 520)
        ..lineTo(740, 520)
        ..lineTo(860, 760)
        ..lineTo(140, 760)
        ..close();
      c.drawPath(rug, _fill(rc));
      c.drawPath(rug, _stroke(_light(rc, 0.3), 6));
    }
    // Skirting board.
    c.drawRect(const Rect.fromLTWH(0, horizon - 10, 1000, 12), _fill(_dark(wc, 0.3)));
  }

  void _wainscot(Color wc, double hgt, {bool wood = false}) {
    final r = Rect.fromLTWH(0, horizon - hgt, 1000, hgt);
    final col = wood ? const Color(0xFF8C5E3F) : _dark(wc, 0.1);
    c.drawRect(r, _fill(col));
    c.drawRect(Rect.fromLTWH(0, horizon - hgt - 5, 1000, 5), _fill(_dark(col, 0.2)));
    if (wood) {
      final l = _stroke(_dark(col, 0.2), 2);
      for (double x = 30; x < 1000; x += 70) {
        c.drawLine(Offset(x, horizon - hgt + 4), Offset(x, horizon - 4), l);
      }
    }
  }
}

// ------------------------------------------------------------------------------------------- items

class _ItemPainter {
  final Canvas c;
  final Map<String, dynamic> it;
  late final String k = it['k'] as String;
  late final double x = _d(it['x']), y = _d(it['y']), w = _d(it['w']), h = _d(it['h']), s = _d(it['s']);
  late final Rect b = Rect.fromLTWH(x, y, w, h);
  late final Color t = tone(it['t']);
  late final Color t2 = tone(it['t2']);
  late final int v = (it['v'] as num?)?.toInt() ?? 0;
  late final int id = (it['id'] as num).toInt();
  _ItemPainter(this.c, this.it);

  void paint() {
    switch (k) {
      case 'window':
        return _window();
      case 'clock':
        return _clock();
      case 'frame':
        return _frame();
      case 'tree':
        return _tree();
      case 'shelf':
        return _shelf();
      case 'lamp':
        return _lamp();
      case 'plant':
        return _plant();
      case 'counter':
        return _counter();
      case 'table':
        return _table();
      case 'bench':
        return _bench();
      case 'parasol':
        return _parasol();
      case 'cup':
        return _cup(b, t);
      case 'book':
        return _book();
      case 'bag':
        return _bag();
      case 'umbrella':
        return _umbrellaClosed(Rect.fromLTWH(x, y, w, h), t);
      case 'ball':
        return _ball();
      case 'fruit':
        return _fruit();
      case 'vase':
        return _vase();
      case 'bottle':
        return _bottle();
      case 'laptop':
        return _laptop();
      case 'cat':
        return _cat();
      case 'dog':
        return _dog();
      case 'bird':
        return _bird(b, t);
      case 'person':
        return _PersonPainter(c, it).paint();
    }
  }

  // ---- wall

  void _window() {
    final wood = (v >> 1) & 1 == 1;
    final frame = wood ? const Color(0xFF9A6A45) : const Color(0xFFF7F3EA);
    c.drawRRect(RRect.fromRectAndRadius(b.inflate(6), const Radius.circular(6)), _fill(_dark(frame, 0.12)));
    c.drawRRect(RRect.fromRectAndRadius(b, const Radius.circular(4)), _fill(frame));
    final glass = b.deflate(12);
    c.drawRect(
      glass,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF9FD0EA), Color(0xFFDDEFF3)],
        ).createShader(glass),
    );
    // A view: soft hills and a cloud.
    c.save();
    c.clipRect(glass);
    c.drawOval(Rect.fromLTWH(glass.left - 40, glass.bottom - 50, glass.width * 0.9, 90), _fill(const Color(0xFFA9CF96)));
    c.drawOval(Rect.fromLTWH(glass.center.dx - 10, glass.bottom - 38, glass.width * 0.9, 80), _fill(const Color(0xFF93C080)));
    c.drawOval(Rect.fromLTWH(glass.left + 20, glass.top + 30, 60, 18), _fill(const Color(0xE6FFFFFF)));
    // Glass sheen.
    c.drawPath(
      Path()
        ..moveTo(glass.left + 20, glass.bottom)
        ..lineTo(glass.left + 70, glass.top)
        ..lineTo(glass.left + 95, glass.top)
        ..lineTo(glass.left + 45, glass.bottom)
        ..close(),
      _fill(const Color(0x22FFFFFF)),
    );
    c.restore();
    final bar = _fill(frame);
    c.drawRect(Rect.fromLTWH(b.center.dx - 4, glass.top, 8, glass.height), bar);
    c.drawRect(Rect.fromLTWH(glass.left, b.center.dy - 4, glass.width, 8), bar);
    // Sill.
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(b.left - 14, b.bottom, b.width + 28, 12), const Radius.circular(3)),
        _fill(_dark(frame, 0.08)));
    if (v & 1 == 1) {
      // Curtains, gathered with a tie-back.
      for (final left in [true, false]) {
        final cx0 = left ? b.left - 16 : b.right + 16;
        final dir = left ? 1.0 : -1.0;
        final p = Path()
          ..moveTo(cx0, b.top - 14)
          ..lineTo(cx0 + dir * 62, b.top - 14)
          ..quadraticBezierTo(cx0 + dir * 30, b.top + b.height * 0.45, cx0 + dir * 22, b.top + b.height * 0.55)
          ..quadraticBezierTo(cx0 + dir * 40, b.bottom - 10, cx0 + dir * 48, b.bottom + 14)
          ..lineTo(cx0, b.bottom + 14)
          ..close();
        c.drawPath(p, _fill(t));
        final fold = _stroke(_dark(t, 0.2), 2.2);
        for (var i = 1; i <= 2; i++) {
          c.drawLine(Offset(cx0 + dir * 12 * i, b.top - 10), Offset(cx0 + dir * 9 * i, b.bottom + 10), fold);
        }
        c.drawRRect(
            RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(cx0 + dir * 22, b.top + b.height * 0.56), width: 30, height: 8),
                const Radius.circular(4)),
            _fill(_dark(t, 0.3)));
      }
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(b.left - 26, b.top - 20, b.width + 52, 8), const Radius.circular(4)),
          _fill(const Color(0xFF6E4A33)));
    }
  }

  void _clock() {
    final ctr = b.center;
    final r = b.width / 2;
    c.drawCircle(ctr.translate(2, 4), r, Paint()..color = const Color(0x33000000)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    c.drawCircle(ctr, r, _fill(t));
    c.drawCircle(ctr, r * 0.82, _fill(const Color(0xFFFBF8F0)));
    final tick = _stroke(const Color(0xFF3A3434), r * 0.05);
    for (var i = 0; i < 12; i++) {
      final a = i * math.pi / 6;
      final l = i % 3 == 0 ? 0.62 : 0.68;
      c.drawLine(ctr + Offset(math.sin(a), -math.cos(a)) * r * l, ctr + Offset(math.sin(a), -math.cos(a)) * r * 0.76, tick);
    }
    final ha = (v % 12) * math.pi / 6;
    c.drawLine(ctr, ctr + Offset(math.sin(ha), -math.cos(ha)) * r * 0.42, _stroke(const Color(0xFF231F1F), r * 0.11));
    c.drawLine(ctr, ctr + Offset(0, -r * 0.62), _stroke(const Color(0xFF231F1F), r * 0.06));
    c.drawCircle(ctr, r * 0.07, _fill(const Color(0xFFC0392B)));
  }

  void _frame() {
    c.drawRect(b.shift(const Offset(3, 5)), Paint()..color = const Color(0x30000000)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    final fr = t2 == tone('sari') ? const Color(0xFFC9A04A) : t2;
    c.drawRect(b, _fill(fr));
    final art = b.deflate(9);
    c.drawRect(art, _fill(const Color(0xFFF6EFE0)));
    c.save();
    c.clipRect(art);
    switch (v % 3) {
      case 0: // mountains
        c.drawRect(art, _fill(_light(t, 0.7)));
        c.drawPath(
            Path()
              ..moveTo(art.left, art.bottom)
              ..lineTo(art.left + art.width * 0.35, art.top + art.height * 0.3)
              ..lineTo(art.left + art.width * 0.6, art.bottom)
              ..close(),
            _fill(t));
        c.drawPath(
            Path()
              ..moveTo(art.left + art.width * 0.35, art.bottom)
              ..lineTo(art.left + art.width * 0.7, art.top + art.height * 0.45)
              ..lineTo(art.right, art.bottom)
              ..close(),
            _fill(_dark(t, 0.25)));
        c.drawCircle(Offset(art.right - 18, art.top + 16), 9, _fill(const Color(0xFFF4C94E)));
        break;
      case 1: // sun / circle
        c.drawRect(art, _fill(_light(t, 0.55)));
        c.drawCircle(art.center, art.height * 0.32, _fill(t));
        c.drawRect(Rect.fromLTWH(art.left, art.center.dy + 8, art.width, art.height), _fill(_dark(t, 0.3)));
        break;
      default: // abstract bands
        for (var i = 0; i < 4; i++) {
          c.drawRect(Rect.fromLTWH(art.left + i * art.width / 4, art.top, art.width / 4, art.height),
              _fill(i.isEven ? t : _light(t, 0.45 + i * 0.1)));
        }
    }
    c.restore();
  }

  // ---- furniture

  void _tree() {
    final trunk = Rect.fromLTWH(b.center.dx - b.width * 0.07, b.top + b.height * 0.45, b.width * 0.14, b.height * 0.55);
    c.drawRRect(RRect.fromRectAndRadius(trunk, Radius.circular(8 * s)), _fill(const Color(0xFF7A5236)));
    c.drawLine(trunk.topCenter.translate(0, trunk.height * 0.25), trunk.topCenter.translate(b.width * 0.16, -4),
        _stroke(const Color(0xFF7A5236), 9 * s));
    const greens = [Color(0xFF5E9E4E), Color(0xFF4F8E46), Color(0xFF6FB05A)];
    final g = greens[v % 3];
    final cw = b.width, ch = b.height * 0.62;
    final top = b.top;
    final blobs = [
      Rect.fromLTWH(b.left + cw * 0.05, top + ch * 0.28, cw * 0.5, ch * 0.6),
      Rect.fromLTWH(b.left + cw * 0.45, top + ch * 0.3, cw * 0.5, ch * 0.6),
      Rect.fromLTWH(b.left + cw * 0.18, top, cw * 0.64, ch * 0.7),
      Rect.fromLTWH(b.left + cw * 0.22, top + ch * 0.42, cw * 0.56, ch * 0.58),
    ];
    for (final r in blobs) {
      c.drawOval(r, _fill(_dark(g, 0.12)));
    }
    for (final r in blobs) {
      c.drawOval(r.deflate(6 * s).shift(Offset(-4 * s, -5 * s)), _fill(g));
    }
    // Highlights.
    c.drawOval(Rect.fromLTWH(b.left + cw * 0.3, top + ch * 0.1, cw * 0.25, ch * 0.18), _fill(_light(g, 0.18)));
  }

  void _shelf() {
    final wood = t == tone('beyaz') ? const Color(0xFFF1ECE2) : const Color(0xFF8E5F3E);
    c.drawRect(b, _fill(_dark(wood, 0.15)));
    final inner = Rect.fromLTRB(b.left + 9 * s, b.top + 9 * s, b.right - 9 * s, b.bottom - 14 * s);
    c.drawRect(inner, _fill(_dark(wood, 0.38)));
    const levels = 4;
    final lh = inner.height / levels;
    const bookCols = ['kirmizi', 'mavi', 'yesil', 'sari', 'mor', 'turuncu', 'beyaz', 'kahve'];
    for (var lv = 0; lv < levels; lv++) {
      final base = inner.top + lh * (lv + 1);
      c.drawRect(Rect.fromLTWH(b.left, base - 6 * s, b.width, 7 * s), _fill(wood));
      var bx = inner.left + 4 * s;
      var n = 0;
      while (bx < inner.right - 12 * s) {
        final hh = _hash(id, lv * 31 + n);
        final bw = (9 + hh % 9) * s;
        final bh = lh * (0.55 + (hh >> 4) % 30 / 100);
        if (hh % 7 == 0) {
          bx += bw; // a gap
        } else if (bx + bw < inner.right - 2 * s) {
          final col = tone(bookCols[hh % bookCols.length]);
          c.drawRect(Rect.fromLTWH(bx, base - 6 * s - bh, bw, bh), _fill(_dark(col, 0.1)));
          c.drawRect(Rect.fromLTWH(bx + 1.5 * s, base - 6 * s - bh * 0.8, bw - 3 * s, 2 * s), _fill(_light(col, 0.4)));
        }
        bx += bw + 1.5 * s;
        n++;
      }
    }
  }

  void _lamp() {
    if (v == 1) {
      // Street lamp: dark pole, lantern.
      const pole = Color(0xFF2F3B36);
      final px = b.center.dx;
      c.drawRect(Rect.fromLTWH(px - 5 * s, b.top + 40 * s, 10 * s, b.height - 40 * s), _fill(pole));
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(px - 14 * s, b.bottom - 30 * s, 28 * s, 30 * s), Radius.circular(4 * s)), _fill(pole));
      final head = Rect.fromLTWH(px - 22 * s, b.top + 4 * s, 44 * s, 46 * s);
      final glow = t == tone('beyaz') ? const Color(0xFFFFF4D0) : _light(t, 0.4);
      c.drawCircle(head.center, 46 * s, Paint()..color = glow.withValues(alpha: 0.28)..maskFilter = MaskFilter.blur(BlurStyle.normal, 20 * s));
      c.drawPath(
          Path()
            ..moveTo(head.left, head.top + 10 * s)
            ..lineTo(head.right, head.top + 10 * s)
            ..lineTo(head.right - 6 * s, head.bottom)
            ..lineTo(head.left + 6 * s, head.bottom)
            ..close(),
          _fill(glow));
      c.drawPath(
          Path()
            ..moveTo(head.left - 6 * s, head.top + 12 * s)
            ..lineTo(head.center.dx, head.top - 6 * s)
            ..lineTo(head.right + 6 * s, head.top + 12 * s)
            ..close(),
          _fill(pole));
      c.drawLine(head.topCenter.translate(0, 10 * s), head.bottomCenter, _stroke(pole, 2.5 * s));
      return;
    }
    // Floor lamp with a conical shade.
    final px = b.center.dx;
    final shade = Rect.fromLTWH(b.left, b.top, b.width, 66 * s);
    c.drawCircle(shade.bottomCenter, 70 * s, Paint()..color = const Color(0x30FFE9A8)..maskFilter = MaskFilter.blur(BlurStyle.normal, 26 * s));
    c.drawLine(Offset(px, shade.bottom - 6 * s), Offset(px, b.bottom - 8 * s), _stroke(const Color(0xFF4A3B33), 5 * s));
    c.drawOval(Rect.fromLTWH(px - 26 * s, b.bottom - 12 * s, 52 * s, 12 * s), _fill(const Color(0xFF4A3B33)));
    c.drawPath(
        Path()
          ..moveTo(shade.left + 16 * s, shade.top)
          ..lineTo(shade.right - 16 * s, shade.top)
          ..lineTo(shade.right, shade.bottom)
          ..lineTo(shade.left, shade.bottom)
          ..close(),
        _fill(t));
    c.drawLine(shade.bottomLeft, shade.bottomRight, _stroke(_dark(t, 0.25), 4 * s));
    c.drawLine(shade.topLeft.translate(22 * s, 6 * s), shade.bottomLeft.translate(12 * s, -6 * s), _stroke(_light(t, 0.35), 4 * s));
  }

  void _plant() {
    if (v == 3) {
      // Park bush (no pot).
      const g = Color(0xFF5C9C4C);
      for (final o in [const Offset(0.28, 0.6), const Offset(0.72, 0.6), const Offset(0.5, 0.42)]) {
        c.drawOval(Rect.fromCenter(center: Offset(b.left + b.width * o.dx, b.top + b.height * o.dy), width: b.width * 0.6, height: b.height * 0.8),
            _fill(o.dy < 0.5 ? _light(g, 0.1) : g));
      }
      for (var i = 0; i < 5; i++) {
        final hh = _hash(id, i);
        c.drawCircle(Offset(b.left + b.width * (0.2 + (hh % 60) / 100), b.top + b.height * (0.3 + (hh >> 5) % 40 / 100)), 4 * s,
            _fill(tone(it['t2'])));
      }
      return;
    }
    final potH = b.height * (v == 2 ? 0.25 : 0.36);
    final pot = Rect.fromLTWH(b.left + b.width * 0.2, b.bottom - potH, b.width * 0.6, potH);
    const leaf = Color(0xFF4E9150);
    if (v == 2) {
      // Tall ficus.
      c.drawLine(pot.topCenter, Offset(pot.center.dx, b.top + b.height * 0.3), _stroke(const Color(0xFF6B4A30), 5 * s));
      for (var i = 0; i < 9; i++) {
        final hh = _hash(id, i);
        final cx = b.left + b.width * (0.15 + (hh % 70) / 100);
        final cy = b.top + b.height * (0.05 + ((hh >> 6) % 55) / 100);
        c.drawOval(Rect.fromCenter(center: Offset(cx, cy), width: 30 * s, height: 20 * s), _fill(i.isEven ? leaf : _light(leaf, 0.15)));
      }
    } else {
      for (var i = 0; i < 7; i++) {
        final a = -math.pi / 2 + (i - 3) * 0.42;
        final len = b.height * (0.5 + (i % 2) * 0.12);
        final base = pot.topCenter;
        final tip = base + Offset(math.cos(a), math.sin(a)) * len;
        final mid = Offset.lerp(base, tip, 0.5)! + Offset(-math.sin(a), math.cos(a)) * 10 * s;
        c.drawPath(
            Path()
              ..moveTo(base.dx, base.dy)
              ..quadraticBezierTo(mid.dx + 12 * s, mid.dy, tip.dx, tip.dy)
              ..quadraticBezierTo(mid.dx - 12 * s, mid.dy, base.dx, base.dy),
            _fill(i.isEven ? leaf : _dark(leaf, 0.12)));
      }
      if (v == 1) {
        for (var i = 0; i < 4; i++) {
          final a = -math.pi / 2 + (i - 1.5) * 0.6;
          final p = pot.topCenter + Offset(math.cos(a), math.sin(a)) * b.height * 0.5;
          for (var j = 0; j < 5; j++) {
            final pa = j * 2 * math.pi / 5;
            c.drawCircle(p + Offset(math.cos(pa), math.sin(pa)) * 5 * s, 4.5 * s, _fill(t2));
          }
          c.drawCircle(p, 3 * s, _fill(const Color(0xFFF4D35E)));
        }
      }
    }
    c.drawPath(
        Path()
          ..moveTo(pot.left, pot.top)
          ..lineTo(pot.right, pot.top)
          ..lineTo(pot.right - pot.width * 0.12, pot.bottom)
          ..lineTo(pot.left + pot.width * 0.12, pot.bottom)
          ..close(),
        _fill(t));
    c.drawRect(Rect.fromLTWH(pot.left - 3 * s, pot.top, pot.width + 6 * s, 9 * s), _fill(_dark(t, 0.15)));
  }

  void _counter() {
    final top = Rect.fromLTWH(b.left - 6 * s, b.top, b.width + 12 * s, 16 * s);
    final body = Rect.fromLTRB(b.left, top.bottom, b.right, b.bottom);
    c.drawRect(body, _fill(t));
    final panel = _stroke(_dark(t, 0.18), 3 * s);
    const n = 3;
    for (var i = 0; i < n; i++) {
      final pr = Rect.fromLTWH(body.left + 14 * s + i * (body.width - 28 * s) / n, body.top + 16 * s,
          (body.width - 28 * s) / n - 12 * s, body.height - 34 * s);
      c.drawRRect(RRect.fromRectAndRadius(pr, Radius.circular(4 * s)), panel);
    }
    c.drawRect(Rect.fromLTWH(body.left, body.bottom - 10 * s, body.width, 10 * s), _fill(_dark(t, 0.3)));
    c.drawRRect(RRect.fromRectAndRadius(top, Radius.circular(3 * s)), _fill(const Color(0xFFE9E2D3)));
    c.drawRect(Rect.fromLTWH(top.left, top.bottom - 4 * s, top.width, 4 * s), _fill(const Color(0xFFC9C0AE)));
  }

  void _table() {
    final sy = _d(it['sy']);
    final wood = t;
    if (v == 0) {
      // Round café table: elliptical top, pedestal, round foot.
      final top = Rect.fromLTRB(b.left, sy - 12 * s, b.right, sy + 12 * s);
      c.drawRect(Rect.fromLTWH(b.center.dx - 6 * s, sy, 12 * s, b.bottom - sy - 8 * s), _fill(_dark(wood, 0.35)));
      c.drawOval(Rect.fromCenter(center: Offset(b.center.dx, b.bottom - 5 * s), width: b.width * 0.42, height: 12 * s),
          _fill(_dark(wood, 0.4)));
      c.drawOval(top.shift(Offset(0, 6 * s)), _fill(_dark(wood, 0.28)));
      c.drawOval(top, _fill(wood));
      c.drawOval(top.deflate(6 * s).shift(Offset(-8 * s, -2 * s)), _fill(_light(wood, 0.12)));
    } else {
      // Rectangular table / desk.
      final top = Rect.fromLTRB(b.left, sy - 10 * s, b.right, sy + 6 * s);
      final legC = _dark(wood, 0.3);
      for (final lx in [b.left + 12 * s, b.right - 22 * s]) {
        c.drawRect(Rect.fromLTWH(lx, sy, 10 * s, b.bottom - sy), _fill(legC));
      }
      c.drawRect(Rect.fromLTWH(b.left + 10 * s, sy + 6 * s, b.width - 20 * s, 18 * s), _fill(_dark(wood, 0.18)));
      c.drawRRect(RRect.fromRectAndRadius(top, Radius.circular(3 * s)), _fill(wood));
      c.drawRect(Rect.fromLTWH(top.left, top.top, top.width, 4 * s), _fill(_light(wood, 0.2)));
    }
  }

  void _bench() {
    final sy = _d(it['sy']);
    final wood = t;
    final iron = v == 1 ? const Color(0xFF7D8890) : const Color(0xFF3B3735);
    // Legs and armrests.
    for (final lx in [b.left + 18 * s, b.right - 30 * s]) {
      c.drawRect(Rect.fromLTWH(lx, b.top + 20 * s, 12 * s, b.height - 20 * s), _fill(iron));
    }
    // Backrest slats.
    for (var i = 0; i < 3; i++) {
      final r = Rect.fromLTWH(b.left + 4 * s, b.top + 10 * s + i * 22 * s, b.width - 8 * s, 15 * s);
      c.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(3 * s)), _fill(i.isEven ? wood : _dark(wood, 0.08)));
    }
    // Seat.
    final seat = Rect.fromLTWH(b.left, sy - 8 * s, b.width, 18 * s);
    c.drawRRect(RRect.fromRectAndRadius(seat, Radius.circular(4 * s)), _fill(_light(wood, 0.08)));
    c.drawRect(Rect.fromLTWH(seat.left, seat.bottom - 6 * s, seat.width, 6 * s), _fill(_dark(wood, 0.25)));
  }

  void _parasol() {
    final canopyH = b.height * 0.24;
    final px = b.center.dx;
    c.drawLine(Offset(px, b.top + canopyH * 0.6), Offset(px, b.bottom), _stroke(const Color(0xFFF2EEE4), 7 * s));
    c.drawLine(Offset(px + 2 * s, b.top + canopyH), Offset(px + 2 * s, b.bottom), _stroke(const Color(0x22000000), 2 * s));
    final rim = b.top + canopyH;
    const segs = 6;
    final segW = b.width / segs;
    for (var i = 0; i < segs; i++) {
      final p = Path()
        ..moveTo(px, b.top + 6 * s)
        ..lineTo(b.left + i * segW, rim)
        ..quadraticBezierTo(b.left + (i + 0.5) * segW, rim - 14 * s, b.left + (i + 1) * segW, rim)
        ..close();
      c.drawPath(p, _fill(i.isEven ? t : t2));
    }
    c.drawCircle(Offset(px, b.top + 6 * s), 6 * s, _fill(const Color(0xFFF2EEE4)));
  }

  // ---- objects

  void _cup(Rect r, Color col) {
    final body = Rect.fromLTWH(r.left + r.width * 0.12, r.top + r.height * 0.18, r.width * 0.62, r.height * 0.72);
    c.drawOval(Rect.fromLTWH(r.left - r.width * 0.05, r.bottom - r.height * 0.16, r.width * 1.05, r.height * 0.2), _fill(const Color(0xFFF2EFE9)));
    c.drawArc(Rect.fromLTWH(body.right - r.width * 0.12, body.top + body.height * 0.18, r.width * 0.34, body.height * 0.5), -math.pi / 2,
        math.pi, false, _stroke(_dark(col, 0.1), r.width * 0.09));
    c.drawRRect(RRect.fromRectAndCorners(body, bottomLeft: Radius.circular(r.width * 0.2), bottomRight: Radius.circular(r.width * 0.2)),
        _fill(col));
    c.drawOval(Rect.fromLTWH(body.left, body.top - r.height * 0.06, body.width, r.height * 0.14), _fill(_dark(col, 0.3)));
    if (_lum(col) > 0.7) {
      c.drawRRect(RRect.fromRectAndCorners(body, bottomLeft: Radius.circular(r.width * 0.2), bottomRight: Radius.circular(r.width * 0.2)),
          _stroke(const Color(0x40000000), 1));
    }
  }

  void _book() {
    c.drawRRect(RRect.fromRectAndRadius(b, Radius.circular(2 * s)), _fill(t));
    c.drawRect(Rect.fromLTWH(b.left + 4 * s, b.top + b.height * 0.3, b.width - 6 * s, b.height * 0.45), _fill(const Color(0xFFF5EEDC)));
    c.drawRect(Rect.fromLTWH(b.left, b.top, 5 * s, b.height), _fill(_dark(t, 0.25)));
  }

  void _bag() {
    final body = Rect.fromLTWH(b.left, b.top + b.height * 0.3, b.width, b.height * 0.7);
    c.drawArc(Rect.fromLTWH(b.left + b.width * 0.22, b.top, b.width * 0.56, b.height * 0.6), math.pi, math.pi, false,
        _stroke(_dark(t, 0.25), 4 * s));
    c.drawPath(
        Path()
          ..moveTo(body.left + 4 * s, body.top)
          ..lineTo(body.right - 4 * s, body.top)
          ..lineTo(body.right, body.bottom)
          ..lineTo(body.left, body.bottom)
          ..close(),
        _fill(t));
    c.drawRect(Rect.fromLTWH(body.left + 4 * s, body.top, body.width - 8 * s, 7 * s), _fill(_dark(t, 0.15)));
  }

  void _umbrellaClosed(Rect r, Color col) {
    final cx = r.center.dx;
    c.drawLine(Offset(cx, r.top), Offset(cx, r.bottom - 4), _stroke(const Color(0xFF3C3431), r.width * 0.1));
    c.drawPath(
        Path()
          ..moveTo(cx, r.top + r.height * 0.18)
          ..quadraticBezierTo(cx + r.width * 0.55, r.top + r.height * 0.55, cx + r.width * 0.08, r.bottom - r.height * 0.1)
          ..lineTo(cx - r.width * 0.08, r.bottom - r.height * 0.1)
          ..quadraticBezierTo(cx - r.width * 0.55, r.top + r.height * 0.55, cx, r.top + r.height * 0.18),
        _fill(col));
    c.drawLine(Offset(cx, r.top + r.height * 0.25), Offset(cx + r.width * 0.05, r.bottom - r.height * 0.14), _stroke(_dark(col, 0.25), 1.5));
    c.drawArc(Rect.fromLTWH(cx - r.width * 0.42, r.top - r.height * 0.08, r.width * 0.42, r.height * 0.16), 0, math.pi, false,
        _stroke(const Color(0xFF3C3431), r.width * 0.12));
  }

  void _ball() {
    final ctr = b.center;
    final r = b.width / 2;
    c.drawCircle(ctr, r, _fill(t));
    final band = _lum(t) > 0.7 ? const Color(0xFFD6463E) : const Color(0xFFF7F3EA);
    c.save();
    c.clipPath(Path()..addOval(Rect.fromCircle(center: ctr, radius: r)));
    c.drawOval(Rect.fromCenter(center: ctr.translate(r * 0.1, 0), width: r * 0.7, height: r * 2.2), _fill(band));
    c.restore();
    c.drawCircle(ctr.translate(-r * 0.35, -r * 0.35), r * 0.22, _fill(const Color(0x55FFFFFF)));
    c.drawCircle(ctr, r, _stroke(_dark(t, 0.3), 1.4 * s));
  }

  void _fruit() {
    final bowl = Rect.fromLTWH(b.left, b.top + b.height * 0.42, b.width, b.height * 0.58);
    final r = b.height * 0.27;
    final kinds = v % 5;
    final pts = [Offset(b.left + b.width * 0.28, bowl.top), Offset(b.left + b.width * 0.72, bowl.top), Offset(b.center.dx, bowl.top - r * 0.75)];
    for (final p in pts) {
      switch (kinds) {
        case 0: // elma
          c.drawCircle(p, r, _fill(const Color(0xFFD23C34)));
          c.drawLine(p.translate(0, -r), p.translate(r * 0.2, -r * 1.4), _stroke(const Color(0xFF5B3A1E), r * 0.18));
          c.drawOval(Rect.fromLTWH(p.dx + r * 0.1, p.dy - r * 1.35, r * 0.6, r * 0.3), _fill(const Color(0xFF4E9E5C)));
          break;
        case 1: // portakal
          c.drawCircle(p, r, _fill(const Color(0xFFF08A24)));
          c.drawCircle(p.translate(-r * 0.3, -r * 0.3), r * 0.25, _fill(const Color(0x44FFFFFF)));
          break;
        case 2: // muz
          c.drawArc(Rect.fromCenter(center: p.translate(0, -r * 0.4), width: r * 2.6, height: r * 1.8), 0.2, 2.6, false,
              _stroke(const Color(0xFFF2CF3C), r * 0.55));
          break;
        case 3: // armut
          c.drawCircle(p.translate(0, r * 0.2), r * 0.9, _fill(const Color(0xFFA9C94A)));
          c.drawCircle(p.translate(0, -r * 0.55), r * 0.55, _fill(const Color(0xFFA9C94A)));
          break;
        default: // üzüm
          for (var i = 0; i < 6; i++) {
            c.drawCircle(p.translate((i % 3 - 1) * r * 0.55, (i ~/ 3) * r * 0.5 - r * 0.3), r * 0.36, _fill(const Color(0xFF6B3F8E)));
          }
      }
    }
    c.drawArc(Rect.fromLTWH(bowl.left, bowl.top - bowl.height, bowl.width, bowl.height * 2), 0, math.pi, true, _fill(t));
    c.drawOval(Rect.fromLTWH(bowl.left, bowl.top - 3 * s, bowl.width, 6 * s), _fill(_dark(t, 0.18)));
    c.drawArc(Rect.fromLTWH(bowl.left + bowl.width * 0.15, bowl.top - bowl.height * 0.6, bowl.width * 0.5, bowl.height * 1.2), 0.5, 1.2, false,
        _stroke(const Color(0x55FFFFFF), 2 * s));
  }

  void _vase() {
    final body = Rect.fromLTWH(b.left + b.width * 0.12, b.top + b.height * 0.45, b.width * 0.76, b.height * 0.55);
    final stem = _stroke(const Color(0xFF4E8A47), 2.2 * s);
    final heads = [Offset(b.left + b.width * 0.15, b.top + b.height * 0.12), Offset(b.center.dx, b.top + b.height * 0.04),
      Offset(b.right - b.width * 0.15, b.top + b.height * 0.16)];
    for (final hd in heads) {
      c.drawLine(Offset(b.center.dx, body.top + 4 * s), hd, stem);
    }
    for (final hd in heads) {
      for (var j = 0; j < 5; j++) {
        final pa = j * 2 * math.pi / 5;
        c.drawCircle(hd + Offset(math.cos(pa), math.sin(pa)) * 4.6 * s, 4.4 * s, _fill(t2));
      }
      c.drawCircle(hd, 3 * s, _fill(const Color(0xFFF4D35E)));
    }
    c.drawPath(
        Path()
          ..moveTo(body.left + body.width * 0.3, body.top)
          ..lineTo(body.right - body.width * 0.3, body.top)
          ..quadraticBezierTo(body.right + body.width * 0.15, body.center.dy, body.right - body.width * 0.1, body.bottom)
          ..lineTo(body.left + body.width * 0.1, body.bottom)
          ..quadraticBezierTo(body.left - body.width * 0.15, body.center.dy, body.left + body.width * 0.3, body.top)
          ..close(),
        _fill(t));
    c.drawLine(Offset(body.left + body.width * 0.3, body.top + body.height * 0.3), Offset(body.left + body.width * 0.25, body.bottom - 6 * s),
        _stroke(_light(t, 0.4), 2.4 * s));
  }

  void _bottle() {
    final neck = Rect.fromLTWH(b.left + b.width * 0.34, b.top, b.width * 0.32, b.height * 0.36);
    final body = Rect.fromLTWH(b.left, b.top + b.height * 0.3, b.width, b.height * 0.7);
    final col = t.withValues(alpha: 0.9);
    c.drawRRect(RRect.fromRectAndRadius(body, Radius.circular(b.width * 0.3)), _fill(col));
    c.drawRect(neck, _fill(col));
    c.drawRect(Rect.fromLTWH(neck.left - 1, b.top, neck.width + 2, 5 * s), _fill(const Color(0xFF8A5A3A)));
    c.drawRect(Rect.fromLTWH(body.left, body.top + body.height * 0.35, body.width, body.height * 0.3), _fill(const Color(0xFFF2EAD7)));
    c.drawLine(Offset(body.left + body.width * 0.25, body.top + 6 * s), Offset(body.left + body.width * 0.25, body.bottom - 6 * s),
        _stroke(const Color(0x66FFFFFF), 2 * s));
  }

  void _laptop() {
    final screen = Rect.fromLTWH(b.left + b.width * 0.08, b.top, b.width * 0.84, b.height * 0.82);
    c.drawRRect(RRect.fromRectAndRadius(screen, Radius.circular(3 * s)), _fill(t));
    c.drawRect(screen.deflate(4 * s), _fill(const Color(0xFF2E4A62)));
    c.drawRect(Rect.fromLTWH(screen.left + 8 * s, screen.top + 8 * s, screen.width * 0.4, 3 * s), _fill(const Color(0x88BFE3F2)));
    c.drawPath(
        Path()
          ..moveTo(b.left + b.width * 0.04, b.bottom - b.height * 0.18)
          ..lineTo(b.right - b.width * 0.04, b.bottom - b.height * 0.18)
          ..lineTo(b.right, b.bottom)
          ..lineTo(b.left, b.bottom)
          ..close(),
        _fill(_dark(t, 0.1)));
  }

  // ---- animals

  void _cat() {
    final fur = t;
    final dark = _dark(fur, fur == tone('siyah') ? -0.4 : 0.25);
    final eye = fur == tone('siyah') ? const Color(0xFFE8D24A) : const Color(0xFF2E2B2E);
    if (v == 1) {
      // Lying loaf.
      final body = Rect.fromLTWH(b.left, b.top + b.height * 0.25, b.width * 0.8, b.height * 0.75);
      c.drawRRect(RRect.fromRectAndRadius(body, Radius.circular(body.height / 2)), _fill(fur));
      c.drawArc(Rect.fromLTWH(b.left - b.width * 0.12, b.top + b.height * 0.5, b.width * 0.3, b.height * 0.5), math.pi * 0.5, math.pi,
          false, _stroke(fur, b.height * 0.16));
      final head = Offset(b.right - b.height * 0.42, b.top + b.height * 0.45);
      final hr = b.height * 0.36;
      _catHead(head, hr, fur, dark, eye);
      if (fur == tone('turuncu') || fur == tone('gri')) {
        final st = _stroke(dark, 2.4 * s);
        for (var i = 0; i < 3; i++) {
          c.drawLine(Offset(body.left + body.width * (0.25 + i * 0.15), body.top + 2 * s),
              Offset(body.left + body.width * (0.22 + i * 0.15), body.top + body.height * 0.45), st);
        }
      }
      return;
    }
    // Sitting.
    final body = Path()
      ..moveTo(b.left + b.width * 0.3, b.top + b.height * 0.42)
      ..quadraticBezierTo(b.left + b.width * 0.05, b.bottom, b.left + b.width * 0.18, b.bottom)
      ..lineTo(b.right - b.width * 0.18, b.bottom)
      ..quadraticBezierTo(b.right - b.width * 0.05, b.bottom, b.right - b.width * 0.3, b.top + b.height * 0.42)
      ..close();
    c.drawArc(Rect.fromLTWH(b.right - b.width * 0.35, b.bottom - b.height * 0.35, b.width * 0.45, b.height * 0.35), -math.pi * 0.2,
        math.pi * 0.9, false, _stroke(fur, b.width * 0.1));
    c.drawPath(body, _fill(fur));
    if (fur == tone('turuncu') || fur == tone('gri')) {
      final st = _stroke(dark, 2.2 * s);
      for (var i = 0; i < 3; i++) {
        final yy = b.top + b.height * (0.55 + i * 0.12);
        c.drawLine(Offset(b.left + b.width * 0.25, yy), Offset(b.left + b.width * 0.4, yy + 2 * s), st);
        c.drawLine(Offset(b.right - b.width * 0.25, yy), Offset(b.right - b.width * 0.4, yy + 2 * s), st);
      }
    }
    _catHead(Offset(b.center.dx, b.top + b.height * 0.3), b.width * 0.27, fur, dark, eye);
  }

  void _catHead(Offset o, double r, Color fur, Color dark, Color eye) {
    for (final dir in [-1.0, 1.0]) {
      c.drawPath(
          Path()
            ..moveTo(o.dx + dir * r * 0.95, o.dy - r * 0.1)
            ..lineTo(o.dx + dir * r * 0.75, o.dy - r * 1.25)
            ..lineTo(o.dx + dir * r * 0.15, o.dy - r * 0.75)
            ..close(),
          _fill(fur));
      c.drawPath(
          Path()
            ..moveTo(o.dx + dir * r * 0.78, o.dy - r * 0.35)
            ..lineTo(o.dx + dir * r * 0.7, o.dy - r * 0.98)
            ..lineTo(o.dx + dir * r * 0.35, o.dy - r * 0.68)
            ..close(),
          _fill(const Color(0xFFE9A3A8)));
    }
    c.drawOval(Rect.fromCenter(center: o, width: r * 2.1, height: r * 1.8), _fill(fur));
    c.drawCircle(o.translate(-r * 0.4, -r * 0.05), r * 0.17, _fill(eye));
    c.drawCircle(o.translate(r * 0.4, -r * 0.05), r * 0.17, _fill(eye));
    c.drawPath(Path()..moveTo(o.dx - r * 0.12, o.dy + r * 0.25)..lineTo(o.dx + r * 0.12, o.dy + r * 0.25)..lineTo(o.dx, o.dy + r * 0.4)..close(),
        _fill(const Color(0xFFD9767E)));
    final wh = _stroke(fur == tone('beyaz') ? const Color(0x88555555) : const Color(0x99FFFFFF), 1);
    for (final dir in [-1.0, 1.0]) {
      c.drawLine(o.translate(dir * r * 0.3, r * 0.38), o.translate(dir * r * 1.2, r * 0.25), wh);
      c.drawLine(o.translate(dir * r * 0.3, r * 0.45), o.translate(dir * r * 1.2, r * 0.55), wh);
    }
  }

  void _dog() {
    final fur = t;
    final dark = _dark(fur, fur == tone('siyah') ? -0.35 : 0.3);
    final body = Rect.fromLTWH(b.left + b.width * 0.08, b.top + b.height * 0.32, b.width * 0.68, b.height * 0.42);
    // Legs.
    for (final lx in [0.14, 0.28, 0.56, 0.68]) {
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(b.left + b.width * lx, body.center.dy, b.width * 0.1, b.bottom - body.center.dy), Radius.circular(4 * s)),
          _fill(lx < 0.3 && lx > 0.2 || lx > 0.6 ? fur : dark));
    }
    // Tail.
    c.drawLine(Offset(body.left + 4 * s, body.top + 8 * s), Offset(b.left, b.top + b.height * 0.12), _stroke(fur, 7 * s));
    c.drawRRect(RRect.fromRectAndRadius(body, Radius.circular(body.height / 2)), _fill(fur));
    // Head.
    final head = Offset(b.right - b.width * 0.2, b.top + b.height * 0.28);
    final hr = b.height * 0.24;
    c.drawOval(Rect.fromCenter(center: head.translate(hr * 0.75, hr * 0.35), width: hr * 1.3, height: hr * 0.9), _fill(_light(fur, 0.12)));
    c.drawCircle(head, hr, _fill(fur));
    c.drawCircle(head.translate(hr * 1.3, hr * 0.2), hr * 0.2, _fill(const Color(0xFF2B2422)));
    c.drawCircle(head.translate(hr * 0.25, -hr * 0.2), hr * 0.15, _fill(const Color(0xFF2B2422)));
    // Floppy ear.
    c.drawOval(Rect.fromCenter(center: head.translate(-hr * 0.45, hr * 0.2), width: hr * 0.6, height: hr * 1.3), _fill(dark));
    // Collar.
    c.drawLine(head.translate(-hr * 0.5, hr * 0.85), head.translate(hr * 0.4, hr * 0.95), _stroke(const Color(0xFFD6463E), 4 * s));
  }

  void _bird(Rect r, Color col) {
    final body = Rect.fromLTWH(r.left, r.top + r.height * 0.3, r.width * 0.78, r.height * 0.6);
    c.drawPath(Path()..moveTo(body.left + 2, body.center.dy)..lineTo(r.left - r.width * 0.15, body.top)..lineTo(r.left - r.width * 0.1, body.bottom)..close(),
        _fill(_dark(col, 0.25)));
    c.drawOval(body, _fill(col));
    final head = Offset(r.right - r.width * 0.3, r.top + r.height * 0.32);
    c.drawCircle(head, r.height * 0.24, _fill(col));
    c.drawPath(
        Path()
          ..moveTo(head.dx + r.height * 0.2, head.dy - r.height * 0.06)
          ..lineTo(r.right + r.width * 0.08, head.dy + r.height * 0.04)
          ..lineTo(head.dx + r.height * 0.2, head.dy + r.height * 0.12)
          ..close(),
        _fill(const Color(0xFFF0A23A)));
    c.drawCircle(head.translate(r.height * 0.06, -r.height * 0.04), r.height * 0.06, _fill(const Color(0xFF221E1E)));
    c.drawOval(Rect.fromLTWH(body.left + body.width * 0.25, body.top + body.height * 0.15, body.width * 0.45, body.height * 0.5), _fill(_dark(col, 0.2)));
    final leg = _stroke(const Color(0xFF8A6A3A), 1.4);
    c.drawLine(Offset(body.center.dx - 2, body.bottom - 1), Offset(body.center.dx - 3, r.bottom), leg);
    c.drawLine(Offset(body.center.dx + 3, body.bottom - 1), Offset(body.center.dx + 3, r.bottom), leg);
  }
}

// ------------------------------------------------------------------------------------------ people

class _PersonPainter {
  final Canvas c;
  final Map<String, dynamic> it;
  late final Map p = it['p'] as Map;
  late final Map parts = p['parts'] as Map;
  late final double s = _d(it['s']);
  late final Rect box = Rect.fromLTWH(_d(it['x']), _d(it['y']), _d(it['w']), _d(it['h']));
  late final Rect head = _rect(parts['head']);
  late final Rect hatR = _rect(parts['hat']);
  late final Rect face = _rect(parts['face']);
  late final Rect torso = _rect(parts['torso']);
  late final Rect legs = _rect(parts['legs']);
  late final Rect hand = _rect(parts['hand']);
  late final Rect bagR = _rect(parts['bag']);
  late final double r = head.width / 2;
  late final Offset hc = head.center;
  late final bool female = p['g'] == 'f';
  late final bool child = p['age'] == 'child';
  late final bool elder = p['age'] == 'elder';
  late final bool sitting = p['sit'] == true;
  late final Color skin = _skins[((p['skin'] as num?)?.toInt() ?? 0) % _skins.length];
  late final Color hair = _hairs[p['hair']] ?? _hairs['kahve']!;
  late final String style = p['hs'] as String? ?? 'short';
  late final Color top = tone(p['top']);
  late final Color bottom = tone(p['bot']);
  late final String topKind = p['tk'] as String? ?? 'tshirt';
  late final String bottomKind = p['bk'] as String? ?? 'trousers';
  late final int id = (it['id'] as num).toInt();
  late final double armW = (child ? 13 : 15) * s;
  late final double shoulder = torso.width * (female ? 0.47 : 0.52);
  // Hand positions (Rust: right hand at cx + tw/2 + 9s, y = torso.top + 0.92 tl).
  late final Offset rHand = Offset(torso.center.dx + torso.width / 2 + 9 * s, torso.top + torso.height * 0.92);
  late final Offset lHand = Offset(torso.center.dx - torso.width / 2 - 9 * s, torso.top + torso.height * 0.92);
  late final Map? hat = p['hat'] as Map?;
  late final Map? bag = p['bag'] as Map?;
  late final Map? hold = p['hold'] as Map?;

  _PersonPainter(this.c, this.it);

  void paint() {
    if (parts['seat'] != null) _chair(_rect(parts['seat']));
    if (bag != null && bag!['k'] == 'backpack') _backpack(tone(bag!['t']));
    if (hold != null && hold!['k'] == 'umbrella') _umbrellaHeld(tone(hold!['t']));
    _hairBack();
    _legs();
    _torso();
    _arms();
    _neckHead();
    _hairFront();
    _faceFeatures();
    if (p['gl'] != 'none') _glasses(p['gl'] == 'sun');
    if (hat != null) _hat();
    if (bag != null && bag!['k'] == 'backpack') _straps(tone(bag!['t']));
    if (bag != null && bag!['k'] == 'handbag') _handbag(tone(bag!['t']));
    if (hold != null && hold!['k'] != 'umbrella') _held(hold!['k'] as String, tone(hold!['t']));
    _hands();
  }

  void _chair(Rect seat) {
    const wood = Color(0xFF7B5034);
    final hip = legs.top;
    final back = Rect.fromLTWH(seat.left + seat.width * 0.08, seat.top, seat.width * 0.84, hip - seat.top + 6 * s);
    c.drawRRect(RRect.fromRectAndRadius(back, Radius.circular(8 * s)), _fill(_dark(wood, 0.15)));
    c.drawRRect(RRect.fromRectAndRadius(back.deflate(7 * s), Radius.circular(5 * s)), _fill(wood));
    for (final lx in [seat.left + 6 * s, seat.right - 14 * s]) {
      c.drawRect(Rect.fromLTWH(lx, hip, 8 * s, seat.bottom - hip), _fill(_dark(wood, 0.25)));
    }
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(seat.left, hip - 2 * s, seat.width, 12 * s), Radius.circular(4 * s)), _fill(wood));
  }

  void _hairBack() {
    if (style == 'long' || (style == 'curly' && female)) {
      final len = female ? r * 2.4 : r * 1.6;
      final rr = Rect.fromLTWH(hc.dx - r * 1.12, hc.dy - r * 0.9, r * 2.24, len);
      c.drawRRect(RRect.fromRectAndCorners(rr, topLeft: Radius.circular(r), topRight: Radius.circular(r), bottomLeft: Radius.circular(r * 0.5),
          bottomRight: Radius.circular(r * 0.5)), _fill(_dark(hair, 0.08)));
    }
    if (style == 'ponytail') {
      c.drawOval(Rect.fromLTWH(hc.dx + r * 0.6, hc.dy - r * 0.3, r * 0.7, r * 1.6), _fill(_dark(hair, 0.08)));
    }
  }

  void _legs() {
    const shoe = Color(0xFF3A2E2A);
    final legW = torso.width * 0.34;
    final lx = torso.center.dx - torso.width * 0.27;
    final rx = torso.center.dx + torso.width * 0.27;
    if (sitting) {
      // Lap (foreshortened thighs) and lower legs down to the floor or dangling.
      final lap = Rect.fromLTWH(torso.left - 2 * s, legs.top - 6 * s, torso.width + 4 * s, 26 * s);
      final lower = legs.bottom - lap.bottom;
      final legCol = bottomKind == 'trousers' ? bottom : skin;
      for (final x0 in [lx, rx]) {
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x0, lap.bottom + lower / 2 - 3 * s), width: legW * 0.85, height: lower),
            Radius.circular(legW * 0.4)), _fill(_dark(legCol, 0.06)));
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x0 + 2 * s, legs.bottom - 5 * s), width: legW * 1.15, height: 11 * s),
            Radius.circular(5 * s)), _fill(shoe));
      }
      c.drawRRect(RRect.fromRectAndRadius(lap, Radius.circular(10 * s)), _fill(bottom));
      if (bottomKind == 'skirt') {
        c.drawRRect(RRect.fromRectAndRadius(lap.inflate(4 * s).translate(0, 4 * s), Radius.circular(12 * s)), _fill(bottom));
      }
      return;
    }
    final footY = box.bottom;
    for (final x0 in [lx, rx]) {
      final leg = Rect.fromLTRB(x0 - legW / 2, legs.top - 4 * s, x0 + legW / 2, footY - 6 * s);
      c.drawRRect(RRect.fromRectAndRadius(leg, Radius.circular(legW * 0.35)), _fill(skin));
      if (bottomKind == 'trousers') {
        c.drawRRect(RRect.fromRectAndRadius(leg, Radius.circular(legW * 0.3)), _fill(x0 < torso.center.dx ? bottom : _dark(bottom, 0.06)));
      } else if (bottomKind == 'shorts') {
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(leg.left - 2 * s, leg.top, leg.width + 4 * s, leg.height * 0.42), Radius.circular(legW * 0.25)),
            _fill(x0 < torso.center.dx ? bottom : _dark(bottom, 0.06)));
      }
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(leg.left - 3 * s + (x0 > torso.center.dx ? 4 * s : -2 * s), footY - 13 * s, legW + 4 * s, 13 * s),
          Radius.circular(6 * s)), _fill(shoe));
    }
    if (bottomKind == 'skirt') {
      final hem = legs.top + (footY - legs.top) * 0.5;
      c.drawPath(
          Path()
            ..moveTo(torso.left + 4 * s, legs.top - 6 * s)
            ..lineTo(torso.right - 4 * s, legs.top - 6 * s)
            ..lineTo(torso.right + 10 * s, hem)
            ..quadraticBezierTo(torso.center.dx, hem + 6 * s, torso.left - 10 * s, hem)
            ..close(),
          _fill(bottom));
    } else if (bottomKind != 'skirt') {
      // Waistband / crotch fill.
      c.drawRect(Rect.fromLTWH(lx - legW / 2, legs.top - 6 * s, rx - lx + legW, 18 * s), _fill(bottom));
    }
  }

  Path _torsoPath() {
    final t = torso;
    final waist = t.width * (female ? 0.4 : 0.46);
    final hipW = t.width * (female ? 0.5 : 0.47);
    return Path()
      ..moveTo(t.center.dx - shoulder, t.top + 8 * s)
      ..quadraticBezierTo(t.center.dx - shoulder, t.top, t.center.dx - shoulder + 10 * s, t.top)
      ..lineTo(t.center.dx + shoulder - 10 * s, t.top)
      ..quadraticBezierTo(t.center.dx + shoulder, t.top, t.center.dx + shoulder, t.top + 8 * s)
      ..quadraticBezierTo(t.center.dx + waist, t.top + t.height * 0.55, t.center.dx + hipW, t.bottom)
      ..lineTo(t.center.dx - hipW, t.bottom)
      ..quadraticBezierTo(t.center.dx - waist, t.top + t.height * 0.55, t.center.dx - shoulder, t.top + 8 * s)
      ..close();
  }

  /// Sleeve path from the shoulder to the elbow or wrist.
  Path _sleeve(bool left, double frac) {
    final sx = torso.center.dx + (left ? -shoulder : shoulder);
    final hx = left ? lHand.dx : rHand.dx;
    final hy = (left ? lHand.dy : rHand.dy) - 6 * s;
    final ex = sx + (hx - sx) * frac;
    final ey = torso.top + 6 * s + (hy - torso.top - 6 * s) * frac;
    final dir = left ? -1.0 : 1.0;
    return Path()
      ..moveTo(sx - dir * armW * 0.2, torso.top + 2 * s)
      ..quadraticBezierTo(sx + dir * armW * 0.9, torso.top, sx + dir * armW * 0.7, torso.top + 14 * s)
      ..lineTo(ex + dir * armW * 0.5, ey)
      ..lineTo(ex - dir * armW * 0.5, ey)
      ..lineTo(sx - dir * armW * 0.6, torso.top + 22 * s)
      ..close();
  }

  void _arms() {
    // Bare arm under the sleeve (skin), then the sleeve.
    final sleeveFrac = topKind == 'tshirt' ? 0.38 : 1.0;
    for (final left in [true, false]) {
      c.drawPath(_sleeve(left, 1.0), _fill(skin));
      final sl = _sleeve(left, sleeveFrac);
      c.drawPath(sl, _fill(left ? top : _dark(top, 0.05)));
      _pattern(sl);
      if (topKind == 'sweater') {
        // Ribbed cuff.
        final hx = left ? lHand.dx : rHand.dx;
        final hy = (left ? lHand.dy : rHand.dy) - 6 * s;
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(hx, hy - 2 * s), width: armW * 1.15, height: 8 * s), Radius.circular(3 * s)),
            _fill(_dark(top, 0.18)));
      }
    }
  }

  void _torso() {
    final path = _torsoPath();
    c.drawPath(path, _fill(top));
    _pattern(path);
    // Soft side shading.
    c.save();
    c.clipPath(path);
    c.drawRect(Rect.fromLTWH(torso.right - torso.width * 0.22, torso.top, torso.width * 0.3, torso.height), _fill(const Color(0x14000000)));
    c.restore();
    final t = torso;
    switch (topKind) {
      case 'jacket':
        // Open front: shirt inside, lapels, buttons.
        final shirt = Path()
          ..moveTo(t.center.dx - t.width * 0.16, t.top)
          ..lineTo(t.center.dx + t.width * 0.16, t.top)
          ..lineTo(t.center.dx + t.width * 0.06, t.bottom)
          ..lineTo(t.center.dx - t.width * 0.06, t.bottom)
          ..close();
        c.drawPath(shirt, _fill(_lum(top) > 0.75 ? const Color(0xFF6E8BA8) : const Color(0xFFF6F2EA)));
        final lap = _fill(_dark(top, 0.16));
        for (final dir in [-1.0, 1.0]) {
          c.drawPath(
              Path()
                ..moveTo(t.center.dx + dir * t.width * 0.16, t.top)
                ..lineTo(t.center.dx + dir * t.width * 0.3, t.top + t.height * 0.12)
                ..lineTo(t.center.dx + dir * t.width * 0.07, t.top + t.height * 0.52)
                ..close(),
              lap);
        }
        c.drawCircle(Offset(t.center.dx + t.width * 0.12, t.top + t.height * 0.68), 2.6 * s, _fill(_dark(top, 0.35)));
        c.drawCircle(Offset(t.center.dx + t.width * 0.12, t.top + t.height * 0.84), 2.6 * s, _fill(_dark(top, 0.35)));
        break;
      case 'sweater':
        // Ribbed collar and hem.
        c.drawRRect(
            RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(t.center.dx, t.top + 3 * s), width: t.width * 0.38, height: 9 * s),
                Radius.circular(4 * s)),
            _fill(_dark(top, 0.2)));
        c.drawRect(Rect.fromLTWH(t.center.dx - t.width * 0.47, t.bottom - 8 * s, t.width * 0.94, 8 * s), _fill(_dark(top, 0.14)));
        final rib = _stroke(_dark(top, 0.26), 1.2 * s);
        for (double x = t.center.dx - t.width * 0.44; x < t.center.dx + t.width * 0.44; x += 5 * s) {
          c.drawLine(Offset(x, t.bottom - 7 * s), Offset(x, t.bottom - 1 * s), rib);
        }
        break;
      default:
        // T-shirt: a neckline.
        c.drawArc(Rect.fromCenter(center: Offset(t.center.dx, t.top), width: t.width * 0.34, height: 16 * s), 0, math.pi, true, _fill(skin));
    }
  }

  /// Stripes or polka dots clipped to [area] (contrasting tone so it reads at a glance).
  void _pattern(Path area) {
    final pat = p['pat'];
    if (pat == 'plain') return;
    final light = _lum(top) < 0.45;
    final ink = light ? Color.lerp(top, Colors.white, 0.75)! : Color.lerp(top, const Color(0xFF1D1A1A), 0.55)!;
    c.save();
    c.clipPath(area);
    final bounds = area.getBounds();
    if (pat == 'stripe') {
      final step = 13 * s;
      for (double yy = bounds.top + 6 * s; yy < bounds.bottom; yy += step) {
        c.drawRect(Rect.fromLTWH(bounds.left - 4, yy, bounds.width + 8, step * 0.45), _fill(ink));
      }
    } else {
      final step = 14 * s;
      var row = 0;
      for (double yy = bounds.top + 7 * s; yy < bounds.bottom; yy += step) {
        for (double xx = bounds.left + (row.isEven ? 4 : 11) * s; xx < bounds.right; xx += step) {
          c.drawCircle(Offset(xx, yy), 3.3 * s, _fill(ink));
        }
        row++;
      }
    }
    c.restore();
  }

  void _neckHead() {
    c.drawRect(Rect.fromLTWH(hc.dx - r * 0.3, head.bottom - r * 0.2, r * 0.6, torso.top - head.bottom + r * 0.3), _fill(_dark(skin, 0.08)));
    // Ears.
    c.drawOval(Rect.fromCenter(center: Offset(head.left + r * 0.04, hc.dy + r * 0.12), width: r * 0.36, height: r * 0.5), _fill(_dark(skin, 0.05)));
    c.drawOval(Rect.fromCenter(center: Offset(head.right - r * 0.04, hc.dy + r * 0.12), width: r * 0.36, height: r * 0.5), _fill(_dark(skin, 0.05)));
    c.drawOval(Rect.fromCenter(center: hc, width: r * 1.9, height: r * 2.02), _fill(skin));
  }

  void _hairFront() {
    final hp = _fill(hair);
    switch (style) {
      case 'bald':
        // A crown of hair on the sides only.
        c.drawArc(Rect.fromCenter(center: hc.translate(0, r * 0.05), width: r * 2.02, height: r * 1.7), math.pi * 0.85, math.pi * 0.35, false,
            _stroke(hair, r * 0.22));
        c.drawArc(Rect.fromCenter(center: hc.translate(0, r * 0.05), width: r * 2.02, height: r * 1.7), math.pi * 1.8, math.pi * 0.35, false,
            _stroke(hair, r * 0.22));
        c.drawCircle(hc.translate(-r * 0.35, -r * 0.55), r * 0.18, _fill(const Color(0x33FFFFFF)));
        return;
      case 'curly':
        for (var i = 0; i < 7; i++) {
          final a = math.pi + i * math.pi / 6;
          c.drawCircle(hc + Offset(math.cos(a), math.sin(a)) * r * 0.86, r * 0.34, hp);
        }
        c.drawCircle(hc.translate(0, -r * 0.62), r * 0.4, hp);
        return;
      default:
        // A cap of hair with a side parting fringe.
        final cap = Path()
          ..moveTo(hc.dx - r * 0.98, hc.dy + r * 0.12)
          ..quadraticBezierTo(hc.dx - r * 1.08, hc.dy - r * 1.12, hc.dx, hc.dy - r * 1.06)
          ..quadraticBezierTo(hc.dx + r * 1.08, hc.dy - r * 1.12, hc.dx + r * 0.98, hc.dy + r * 0.12)
          ..quadraticBezierTo(hc.dx + r * 0.85, hc.dy - r * 0.45, hc.dx + r * 0.25, hc.dy - r * 0.48)
          ..quadraticBezierTo(hc.dx - r * 0.2, hc.dy - r * 0.2, hc.dx - r * 0.7, hc.dy - r * 0.3)
          ..quadraticBezierTo(hc.dx - r * 0.9, hc.dy - r * 0.1, hc.dx - r * 0.98, hc.dy + r * 0.12)
          ..close();
        c.drawPath(cap, hp);
        if (style == 'long') {
          for (final dir in [-1.0, 1.0]) {
            c.drawRRect(
                RRect.fromRectAndRadius(Rect.fromLTWH(hc.dx + (dir < 0 ? -r * 1.08 : r * 0.72), hc.dy - r * 0.4, r * 0.36, r * 1.85), Radius.circular(r * 0.18)),
                hp);
          }
        }
        if (style == 'bun') {
          c.drawCircle(hc.translate(0, -r * 1.12), r * 0.42, hp);
        }
        if (style == 'ponytail') {
          c.drawCircle(hc.translate(r * 0.82, -r * 0.35), r * 0.16, _fill(const Color(0xFFD6463E)));
        }
        c.drawArc(Rect.fromCenter(center: hc.translate(-r * 0.2, -r * 0.62), width: r * 0.8, height: r * 0.3), math.pi, math.pi * 0.6, false,
            _stroke(_light(hair, 0.25), r * 0.08));
    }
  }

  void _faceFeatures() {
    final eyeY = face.top + face.height * 0.32;
    final ex = r * 0.36;
    const eyeC = Color(0xFF2A2222);
    c.drawCircle(Offset(hc.dx - ex, eyeY), r * 0.1, _fill(eyeC));
    c.drawCircle(Offset(hc.dx + ex, eyeY), r * 0.1, _fill(eyeC));
    c.drawCircle(Offset(hc.dx - ex + r * 0.03, eyeY - r * 0.03), r * 0.035, _fill(Colors.white));
    c.drawCircle(Offset(hc.dx + ex + r * 0.03, eyeY - r * 0.03), r * 0.035, _fill(Colors.white));
    final brow = _stroke(_dark(hair, 0.2), r * 0.07);
    c.drawLine(Offset(hc.dx - ex - r * 0.14, eyeY - r * 0.24), Offset(hc.dx - ex + r * 0.14, eyeY - r * 0.27), brow);
    c.drawLine(Offset(hc.dx + ex - r * 0.14, eyeY - r * 0.27), Offset(hc.dx + ex + r * 0.14, eyeY - r * 0.24), brow);
    // Blush, nose, mouth.
    c.drawCircle(Offset(hc.dx - r * 0.55, eyeY + r * 0.32), r * 0.15, _fill(const Color(0x30E05A5A)));
    c.drawCircle(Offset(hc.dx + r * 0.55, eyeY + r * 0.32), r * 0.15, _fill(const Color(0x30E05A5A)));
    c.drawLine(Offset(hc.dx, eyeY + r * 0.1), Offset(hc.dx - r * 0.06, eyeY + r * 0.3), _stroke(_dark(skin, 0.22), r * 0.06));
    final smile = _hash(id) % 3;
    final mouth = Rect.fromCenter(center: Offset(hc.dx, eyeY + r * 0.44), width: r * (smile == 0 ? 0.5 : 0.38), height: r * 0.26);
    c.drawArc(mouth, 0.15, math.pi - 0.3, false, _stroke(const Color(0xFF8A3B3B), r * 0.07));
    final beard = p['beard'];
    if (beard == 'mustache') {
      c.drawPath(
          Path()
            ..moveTo(hc.dx - r * 0.32, eyeY + r * 0.4)
            ..quadraticBezierTo(hc.dx, eyeY + r * 0.22, hc.dx + r * 0.32, eyeY + r * 0.4)
            ..quadraticBezierTo(hc.dx, eyeY + r * 0.34, hc.dx - r * 0.32, eyeY + r * 0.4),
          _fill(_dark(hair, 0.1)));
    } else if (beard == 'full') {
      c.drawPath(
          Path()
            ..moveTo(hc.dx - r * 0.92, hc.dy + r * 0.05)
            ..quadraticBezierTo(hc.dx - r * 0.85, hc.dy + r * 1.15, hc.dx, hc.dy + r * 1.12)
            ..quadraticBezierTo(hc.dx + r * 0.85, hc.dy + r * 1.15, hc.dx + r * 0.92, hc.dy + r * 0.05)
            ..quadraticBezierTo(hc.dx + r * 0.6, hc.dy + r * 0.62, hc.dx, hc.dy + r * 0.55)
            ..quadraticBezierTo(hc.dx - r * 0.6, hc.dy + r * 0.62, hc.dx - r * 0.92, hc.dy + r * 0.05)
            ..close(),
          _fill(_dark(hair, 0.05)));
      c.drawArc(mouth.translate(0, -r * 0.02), 0.2, math.pi - 0.4, false, _stroke(const Color(0xFF8A3B3B), r * 0.07));
    }
    if (elder) {
      final wr = _stroke(_dark(skin, 0.16), r * 0.04);
      c.drawLine(Offset(hc.dx - ex - r * 0.3, eyeY + r * 0.04), Offset(hc.dx - ex - r * 0.18, eyeY + r * 0.1), wr);
      c.drawLine(Offset(hc.dx + ex + r * 0.3, eyeY + r * 0.04), Offset(hc.dx + ex + r * 0.18, eyeY + r * 0.1), wr);
    }
  }

  void _glasses(bool sun) {
    final eyeY = face.top + face.height * 0.32;
    final ex = r * 0.36;
    final lr = r * 0.25;
    const frame = Color(0xFF231C1C);
    for (final dir in [-1.0, 1.0]) {
      final lens = Rect.fromCenter(center: Offset(hc.dx + dir * ex, eyeY + r * 0.02), width: lr * 2.2, height: lr * (sun ? 1.7 : 1.9));
      if (sun) {
        c.drawRRect(RRect.fromRectAndRadius(lens, Radius.circular(lr * 0.6)), _fill(const Color(0xFF1E2A33)));
        c.drawLine(lens.topLeft.translate(lr * 0.4, lr * 0.4), lens.topLeft.translate(lr * 0.9, lr * 0.2), _stroke(const Color(0x88FFFFFF), r * 0.05));
      } else {
        c.drawOval(lens, _fill(const Color(0x22BFE3F2)));
      }
      c.drawRRect(RRect.fromRectAndRadius(lens, Radius.circular(lr * (sun ? 0.6 : 1))), _stroke(frame, r * 0.075));
    }
    c.drawLine(Offset(hc.dx - ex + lr * 1.1, eyeY), Offset(hc.dx + ex - lr * 1.1, eyeY), _stroke(frame, r * 0.07));
    c.drawLine(Offset(hc.dx - ex - lr * 1.1, eyeY), Offset(head.left + r * 0.08, eyeY - r * 0.06), _stroke(frame, r * 0.06));
    c.drawLine(Offset(hc.dx + ex + lr * 1.1, eyeY), Offset(head.right - r * 0.08, eyeY - r * 0.06), _stroke(frame, r * 0.06));
  }

  // ---- hats: shape by kind, surface by material

  void _hat() {
    final kind = hat!['k'] as String;
    final mat = hat!['m'] as String;
    final col = kind == 'hasir' ? const Color(0xFFE7C77E) : tone(hat!['t']);
    final top = head.top;
    switch (kind) {
      case 'fotr':
        final brim = Rect.fromCenter(center: Offset(hc.dx, top + r * 0.42), width: r * 2.75, height: r * 0.62);
        final crown = Path()
          ..moveTo(hc.dx - r * 0.82, top + r * 0.45)
          ..lineTo(hc.dx - r * 0.72, top - r * 0.5)
          ..quadraticBezierTo(hc.dx, top - r * 0.72, hc.dx + r * 0.72, top - r * 0.5)
          ..lineTo(hc.dx + r * 0.82, top + r * 0.45)
          ..close();
        c.drawOval(brim, _fill(_dark(col, 0.12)));
        c.drawPath(crown, _fill(col));
        // Centre crease.
        c.drawLine(Offset(hc.dx, top - r * 0.6), Offset(hc.dx, top - r * 0.2), _stroke(_dark(col, 0.25), r * 0.08));
        final band = Rect.fromLTRB(hc.dx - r * 0.8, top + r * 0.12, hc.dx + r * 0.8, top + r * 0.38);
        c.drawRect(band, _fill(_lum(col) < 0.2 ? const Color(0xFF8C3A2E) : _dark(col, 0.45)));
        _material(mat, crown, col, brim: brim);
        break;
      case 'bere':
        final dome = Path()
          ..moveTo(hc.dx - r * 1.04, top + r * 0.62)
          ..quadraticBezierTo(hc.dx - r * 1.12, top - r * 0.62, hc.dx, top - r * 0.6)
          ..quadraticBezierTo(hc.dx + r * 1.12, top - r * 0.62, hc.dx + r * 1.04, top + r * 0.62)
          ..close();
        c.drawPath(dome, _fill(col));
        final cuff = Rect.fromLTRB(hc.dx - r * 1.08, top + r * 0.3, hc.dx + r * 1.08, top + r * 0.68);
        c.drawRRect(RRect.fromRectAndRadius(cuff, Radius.circular(r * 0.16)), _fill(_dark(col, 0.12)));
        _material(mat, dome, col, cuff: cuff);
        if (mat == 'yun') {
          // Pompom: the clearest "wool" cue.
          final pc = Offset(hc.dx, top - r * 0.66);
          c.drawCircle(pc, r * 0.36, _fill(_light(col, 0.15)));
          final fluff = _stroke(_dark(col, 0.1), r * 0.06);
          for (var i = 0; i < 8; i++) {
            final a = i * math.pi / 4;
            c.drawLine(pc + Offset(math.cos(a), math.sin(a)) * r * 0.12, pc + Offset(math.cos(a), math.sin(a)) * r * 0.34, fluff);
          }
        } else {
          c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(hc.dx, top - r * 0.62), width: r * 0.14, height: r * 0.26), Radius.circular(r * 0.07)),
              _fill(_dark(col, 0.2)));
        }
        break;
      case 'kasket':
        // Flat cap: a low, wide crown that slopes forward over a stiff visor (to the viewer's right).
        final crown = Path()
          ..moveTo(hc.dx - r * 1.04, top + r * 0.56)
          ..quadraticBezierTo(hc.dx - r * 1.12, top - r * 0.12, hc.dx - r * 0.55, top - r * 0.28)
          ..quadraticBezierTo(hc.dx + r * 0.3, top - r * 0.42, hc.dx + r * 1.0, top - r * 0.08)
          ..quadraticBezierTo(hc.dx + r * 1.42, top + r * 0.14, hc.dx + r * 1.3, top + r * 0.4)
          ..lineTo(hc.dx + r * 1.0, top + r * 0.52)
          ..close();
        final visor = Path()
          ..moveTo(hc.dx - r * 0.35, top + r * 0.5)
          ..quadraticBezierTo(hc.dx + r * 0.8, top + r * 0.36, hc.dx + r * 1.62, top + r * 0.5)
          ..quadraticBezierTo(hc.dx + r * 1.66, top + r * 0.66, hc.dx + r * 1.4, top + r * 0.74)
          ..quadraticBezierTo(hc.dx + r * 0.6, top + r * 0.8, hc.dx - r * 0.35, top + r * 0.68)
          ..close();
        // Shade under the visor on the forehead.
        c.drawOval(Rect.fromLTRB(hc.dx - r * 0.5, top + r * 0.62, hc.dx + r * 1.0, top + r * 0.86), _fill(const Color(0x30000000)));
        c.drawPath(visor, _fill(_dark(col, 0.28)));
        if (mat == 'deri') _gloss(visor);
        c.drawPath(crown, _fill(col));
        _material(mat, crown, col);
        // Front seam where the crown meets the visor, and the snap button.
        c.drawPath(
            Path()
              ..moveTo(hc.dx - r * 0.3, top + r * 0.52)
              ..quadraticBezierTo(hc.dx + r * 0.7, top + r * 0.4, hc.dx + r * 1.3, top + r * 0.42),
            _stroke(_dark(col, 0.4), r * 0.07));
        c.drawCircle(Offset(hc.dx + r * 0.78, top + r * 0.02), r * 0.1, _fill(_dark(col, 0.35)));
        break;
      default: // hasır şapka
        final brim = Rect.fromCenter(center: Offset(hc.dx, top + r * 0.45), width: r * 3.0, height: r * 0.8);
        final crown = Path()
          ..moveTo(hc.dx - r * 0.86, top + r * 0.48)
          ..quadraticBezierTo(hc.dx - r * 0.92, top - r * 0.6, hc.dx, top - r * 0.58)
          ..quadraticBezierTo(hc.dx + r * 0.92, top - r * 0.6, hc.dx + r * 0.86, top + r * 0.48)
          ..close();
        c.drawOval(brim, _fill(_dark(col, 0.06)));
        _weave(Path()..addOval(brim), col);
        c.drawPath(crown, _fill(col));
        _weave(crown, col);
        c.drawRect(Rect.fromLTRB(hc.dx - r * 0.88, top + r * 0.12, hc.dx + r * 0.88, top + r * 0.34), _fill(const Color(0xFF5A3A24)));
        c.drawOval(brim, _stroke(_dark(col, 0.3), r * 0.05));
    }
  }

  /// Material surface: yün = knitted ribs, deri = gloss + stitched edge, kumaş = soft seams.
  void _material(String mat, Path area, Color col, {Rect? brim, Rect? cuff}) {
    final bounds = area.getBounds();
    c.save();
    c.clipPath(area);
    switch (mat) {
      case 'yun':
        final rib = _stroke(_dark(col, 0.18), r * 0.07);
        for (double x = bounds.left; x < bounds.right; x += r * 0.22) {
          c.drawLine(Offset(x, bounds.top), Offset(x, bounds.bottom), rib);
        }
        // Tweed flecks.
        final fleck = _fill(_light(col, 0.3));
        for (var i = 0; i < 14; i++) {
          final hh = _hash(id, i + 50);
          c.drawCircle(Offset(bounds.left + bounds.width * (hh % 100) / 100, bounds.top + bounds.height * ((hh >> 7) % 100) / 100), r * 0.04, fleck);
        }
        break;
      case 'deri':
        c.restore();
        _gloss(area);
        c.drawPath(area, _stroke(_dark(col, 0.45), r * 0.06));
        final dash = _stroke(_light(col, 0.35), r * 0.035);
        for (double x = bounds.left + r * 0.2; x < bounds.right - r * 0.2; x += r * 0.22) {
          c.drawLine(Offset(x, bounds.bottom - r * 0.16), Offset(x + r * 0.1, bounds.bottom - r * 0.16), dash);
        }
        if (brim != null) {
          c.drawOval(brim, _stroke(_dark(col, 0.45), r * 0.05));
          c.drawArc(brim.deflate(r * 0.08), math.pi * 1.1, math.pi * 0.5, false, _stroke(const Color(0x88FFFFFF), r * 0.06));
        }
        return;
      default: // kumaş
        final seam = _stroke(_dark(col, 0.14), r * 0.035);
        c.drawLine(Offset(bounds.center.dx - r * 0.35, bounds.top), Offset(bounds.center.dx - r * 0.45, bounds.bottom), seam);
        c.drawLine(Offset(bounds.center.dx + r * 0.35, bounds.top), Offset(bounds.center.dx + r * 0.45, bounds.bottom), seam);
    }
    c.restore();
    if (cuff != null && mat == 'yun') {
      final rib = _stroke(_dark(col, 0.3), r * 0.06);
      for (double x = cuff.left + r * 0.1; x < cuff.right; x += r * 0.16) {
        c.drawLine(Offset(x, cuff.top + r * 0.04), Offset(x, cuff.bottom - r * 0.04), rib);
      }
    }
  }

  void _gloss(Path area) {
    final b = area.getBounds();
    c.save();
    c.clipPath(area);
    c.drawOval(Rect.fromLTWH(b.left + b.width * 0.15, b.top + b.height * 0.08, b.width * 0.35, b.height * 0.28), _fill(const Color(0x66FFFFFF)));
    c.drawRect(Rect.fromLTWH(b.left, b.top + b.height * 0.7, b.width, b.height * 0.3), _fill(const Color(0x22000000)));
    c.restore();
  }

  void _weave(Path area, Color col) {
    final b = area.getBounds();
    c.save();
    c.clipPath(area);
    final l1 = _stroke(_dark(col, 0.22), r * 0.045);
    for (double d = -b.height; d < b.width + b.height; d += r * 0.2) {
      c.drawLine(Offset(b.left + d, b.top), Offset(b.left + d - b.height, b.bottom), l1);
      c.drawLine(Offset(b.left + d - b.height, b.top), Offset(b.left + d, b.bottom), l1);
    }
    c.restore();
  }

  // ---- bags and held things

  void _backpack(Color col) {
    final pack = Rect.fromLTWH(bagR.left, bagR.top + bagR.height * 0.08, bagR.width + torso.width * 0.2, bagR.height * 0.88);
    c.drawRRect(RRect.fromRectAndRadius(pack, Radius.circular(8 * s)), _fill(_dark(col, 0.1)));
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(pack.left + 2 * s, pack.center.dy, pack.width * 0.5, pack.height * 0.32), Radius.circular(4 * s)),
        _fill(col));
  }

  void _straps(Color col) {
    final st = _stroke(_dark(col, 0.05), 7 * s);
    for (final dir in [-1.0, 1.0]) {
      final x0 = torso.center.dx + dir * torso.width * 0.24;
      c.drawLine(Offset(x0, torso.top + 2 * s), Offset(x0 + dir * 2 * s, torso.top + torso.height * 0.62), st);
    }
  }

  void _handbag(Color col) {
    final body = Rect.fromLTWH(bagR.left, bagR.top + bagR.height * 0.36, bagR.width, bagR.height * 0.64);
    c.drawArc(Rect.fromLTWH(body.left + body.width * 0.15, bagR.top, body.width * 0.7, bagR.height * 0.72), math.pi, math.pi, false,
        _stroke(_dark(col, 0.3), 3.5 * s));
    c.drawRRect(RRect.fromRectAndRadius(body, Radius.circular(5 * s)), _fill(col));
    c.drawRect(Rect.fromLTWH(body.left, body.top, body.width, body.height * 0.28), _fill(_dark(col, 0.15)));
    c.drawCircle(Offset(body.center.dx, body.top + body.height * 0.3), 2.6 * s, _fill(const Color(0xFFD9B45A)));
  }

  void _umbrellaHeld(Color col) {
    // Closed umbrella held at the hand, tip on the ground.
    _ItemPainter(c, it)._umbrellaClosed(Rect.fromLTWH(hand.left, rHand.dy - 22 * s, hand.width, hand.bottom - rHand.dy + 22 * s), col);
  }

  void _held(String kind, Color col) {
    final hx = rHand.dx, hy = rHand.dy;
    switch (kind) {
      case 'balloon':
        final bc = Offset(hand.center.dx + 4 * s, hand.top + 21 * s);
        c.drawLine(Offset(hx, hy), bc.translate(0, 20 * s), _stroke(const Color(0xFF6B5E57), 1.3 * s));
        c.drawOval(Rect.fromCenter(center: bc, width: 38 * s, height: 44 * s), _fill(col));
        c.drawPath(Path()..moveTo(bc.dx - 4 * s, bc.dy + 23 * s)..lineTo(bc.dx + 4 * s, bc.dy + 23 * s)..lineTo(bc.dx, bc.dy + 19 * s)..close(),
            _fill(_dark(col, 0.2)));
        c.drawOval(Rect.fromCenter(center: bc.translate(-7 * s, -9 * s), width: 9 * s, height: 13 * s), _fill(const Color(0x66FFFFFF)));
        break;
      case 'book':
        final bk = Rect.fromCenter(center: Offset(hx + 4 * s, hy - 14 * s), width: 26 * s, height: 36 * s);
        c.drawRRect(RRect.fromRectAndRadius(bk, Radius.circular(2 * s)), _fill(col));
        c.drawRect(Rect.fromLTWH(bk.left, bk.top, 5 * s, bk.height), _fill(_dark(col, 0.3)));
        c.drawRect(Rect.fromLTWH(bk.left + 9 * s, bk.top + 8 * s, bk.width - 14 * s, 4 * s), _fill(_light(col, 0.5)));
        break;
      case 'cup':
        _ItemPainter(c, it)._cup(Rect.fromCenter(center: Offset(hx + 2 * s, hy - 14 * s), width: 26 * s, height: 26 * s), col);
        break;
      case 'flower':
        c.drawLine(Offset(hx, hy + 6 * s), Offset(hx + 6 * s, hy - 40 * s), _stroke(const Color(0xFF4E8A47), 2.6 * s));
        c.drawOval(Rect.fromCenter(center: Offset(hx + 2 * s, hy - 18 * s), width: 12 * s, height: 6 * s), _fill(const Color(0xFF4E8A47)));
        final fc = Offset(hx + 6 * s, hy - 44 * s);
        for (var j = 0; j < 6; j++) {
          final a = j * math.pi / 3;
          c.drawCircle(fc + Offset(math.cos(a), math.sin(a)) * 7 * s, 6 * s, _fill(col));
        }
        c.drawCircle(fc, 4.5 * s, _fill(const Color(0xFFF4D35E)));
        break;
      case 'phone':
        final ph = Rect.fromCenter(center: Offset(hx + 2 * s, hy - 10 * s), width: 13 * s, height: 22 * s);
        c.drawRRect(RRect.fromRectAndRadius(ph, Radius.circular(3 * s)), _fill(col == tone('beyaz') ? const Color(0xFFE9E6E0) : const Color(0xFF26262B)));
        c.drawRect(ph.deflate(2 * s), _fill(const Color(0xFF5A8FC0)));
        break;
      case 'icecream':
        final tip = Offset(hx + 2 * s, hy + 4 * s);
        c.drawPath(Path()..moveTo(tip.dx, tip.dy)..lineTo(tip.dx - 10 * s, tip.dy - 26 * s)..lineTo(tip.dx + 10 * s, tip.dy - 26 * s)..close(),
            _fill(const Color(0xFFD9A15A)));
        c.drawLine(Offset(tip.dx - 5 * s, tip.dy - 18 * s), Offset(tip.dx + 4 * s, tip.dy - 24 * s), _stroke(const Color(0xFFB07B3C), 1.2 * s));
        c.drawCircle(Offset(tip.dx, tip.dy - 32 * s), 12 * s, _fill(col));
        c.drawCircle(Offset(tip.dx - 4 * s, tip.dy - 36 * s), 3.5 * s, _fill(const Color(0x66FFFFFF)));
        break;
    }
  }

  void _hands() {
    c.drawCircle(lHand.translate(0, -2 * s), armW * 0.55, _fill(skin));
    c.drawCircle(rHand.translate(0, -2 * s), armW * 0.55, _fill(skin));
  }
}
