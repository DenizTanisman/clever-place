// Generates the launcher icon images from code (same look as the game medallions).
//
//   ICON_GEN=1 flutter test test/app_icon_gen_test.dart
//   dart run flutter_launcher_icons
//
// Writes assets/icon/icon_ios.png (full square icon, opaque), assets/icon/icon_fg.png (adaptive
// foreground, transparent, content inside the 66 % safe zone), assets/icon/icon_bg.png (adaptive
// background) and store/app_icon_store_1024.png. Without ICON_GEN it only checks that it paints.

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const double _s = 1024;

void _velvet(Canvas canvas) {
  const r = Rect.fromLTWH(0, 0, _s, _s);
  canvas.drawRect(
    r,
    Paint()
      ..shader = const RadialGradient(
        center: Alignment(0, -0.1),
        radius: 0.95,
        colors: [Color(0xFF1D5A6E), Color(0xFF0B2B3A), Color(0xFF030B12)],
        stops: [0, 0.5, 1],
      ).createShader(r),
  );
  // A few faint stars of light, deterministic.
  final rnd = math.Random(7);
  for (var i = 0; i < 40; i++) {
    final p = Offset(rnd.nextDouble() * _s, rnd.nextDouble() * _s);
    canvas.drawCircle(p, 1.5 + rnd.nextDouble() * 2.5, Paint()..color = const Color(0xFFBFF4FF).withValues(alpha: 0.08 + rnd.nextDouble() * 0.12));
  }
}

/// Brain seen from the left side (frontal lobe on the left), in a unit box ~1 × 0.8.
Path _brainUnit() => Path()
  ..moveTo(0.13, 0.60)
  ..cubicTo(0.02, 0.50, 0.03, 0.20, 0.24, 0.10)
  ..cubicTo(0.40, 0.00, 0.68, 0.00, 0.84, 0.13)
  ..cubicTo(0.98, 0.25, 1.00, 0.47, 0.92, 0.58)
  ..cubicTo(0.96, 0.68, 0.88, 0.80, 0.75, 0.77)
  ..cubicTo(0.69, 0.76, 0.65, 0.75, 0.63, 0.79)
  ..lineTo(0.64, 0.87)
  ..cubicTo(0.61, 0.91, 0.55, 0.91, 0.53, 0.87)
  ..lineTo(0.55, 0.78)
  ..cubicTo(0.50, 0.70, 0.42, 0.70, 0.36, 0.71)
  ..cubicTo(0.26, 0.73, 0.18, 0.70, 0.13, 0.60)
  ..close();

/// Folds (gyri): wavy lines across the cerebrum, the lateral fissure and cerebellum lines.
List<Path> _sulciUnit() {
  Path wave(double y0, double x0, double x1, double amp, double period, double drift) {
    final p = Path()..moveTo(x0, y0);
    for (var x = x0; x <= x1; x += 0.01) {
      final t = (x - x0) / period * 2 * math.pi;
      // Two harmonics so the folds look organic rather than a regular wave.
      p.lineTo(x, y0 + (math.sin(t) + 0.5 * math.sin(2.7 * t + y0 * 9)) * amp * 0.8 + (x - x0) * drift);
    }
    return p;
  }

  return [
    wave(0.16, 0.20, 0.82, 0.035, 0.21, 0.05),
    wave(0.31, 0.09, 0.93, 0.04, 0.24, -0.02),
    wave(0.45, 0.10, 0.50, 0.035, 0.2, 0.04),
    Path()..moveTo(0.24, 0.61)..cubicTo(0.38, 0.51, 0.56, 0.55, 0.76, 0.46), // lateral fissure
    wave(0.665, 0.70, 0.90, 0.014, 0.1, 0.0),
    wave(0.725, 0.68, 0.86, 0.014, 0.1, 0.0),
  ];
}


void _ringHalf(Canvas canvas, Offset c, double rx, double ry, double tilt, bool front, double w) {
  canvas.save();
  canvas.translate(c.dx, c.dy);
  canvas.rotate(tilt);
  final rect = Rect.fromCenter(center: Offset.zero, width: rx * 2, height: ry * 2);
  final start = front ? 0.0 : math.pi;
  // Soft glow, then a bright core that runs cyan → gold.
  canvas.drawArc(
    rect,
    start,
    math.pi,
    false,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 3.2
      ..color = const Color(0xFF7FE8FF).withValues(alpha: front ? 0.28 : 0.16)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 2.2),
  );
  canvas.drawArc(
    rect,
    start,
    math.pi,
    false,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..shader = LinearGradient(
        colors: front
            ? const [Color(0xFF9EF3FF), Color(0xFFFFFFFF), Color(0xFFF1D48B)]
            : const [Color(0x88F1D48B), Color(0x997FE8FF), Color(0x889EF3FF)],
      ).createShader(rect),
  );
  if (front) {
    // Field particles riding the ring.
    for (final a in [0.55, 1.9, 2.6]) {
      final p = Offset(rx * math.cos(a), ry * math.sin(a));
      canvas.drawCircle(p, w * 2.4, Paint()..color = const Color(0xFF9EF3FF).withValues(alpha: 0.35)..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 1.6));
      canvas.drawCircle(p, w * 0.95, Paint()..color = Colors.white);
    }
  }
  canvas.restore();
}

/// The emblem: a faceted crystal brain wrapped in glowing magnetic-field rings.
/// [scale] = width of the brain in pixels.
void _emblem(Canvas canvas, double scale) {
  const c = Offset(_s / 2, _s / 2);
  final w = scale;
  final h = scale * 0.96;
  final origin = c - Offset(w / 2, h * 0.47);
  final m = Matrix4.identity()
    ..translateByDouble(origin.dx, origin.dy, 0, 1)
    ..scaleByDouble(w, h, 1, 1);
  final brain = _brainUnit().transform(m.storage);
  final bounds = brain.getBounds();
  final rings = [
    (rx: scale * 0.78, ry: scale * 0.20, tilt: -0.42),
    (rx: scale * 0.74, ry: scale * 0.17, tilt: 0.38),
    (rx: scale * 0.64, ry: scale * 0.14, tilt: 1.35),
  ];
  final lw = scale * 0.022;
  for (final r in rings) {
    _ringHalf(canvas, c, r.rx, r.ry, r.tilt, false, lw);
  }
  // Outer aura.
  canvas.drawPath(
    brain,
    Paint()
      ..color = const Color(0xFF6FE6FF).withValues(alpha: 0.45)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, scale * 0.07),
  );
  // Crystal facets: a jittered grid triangulated and clipped to the silhouette.
  canvas.save();
  canvas.clipPath(brain);
  final rnd = math.Random(42);
  const cols = 9, rows = 8;
  final pts = List.generate(rows + 1, (j) {
    return List.generate(cols + 1, (i) {
      final jitter = (i == 0 || j == 0 || i == cols || j == rows) ? 0.0 : 0.32;
      return Offset(
        bounds.left + (i + (rnd.nextDouble() - 0.5) * jitter) * bounds.width / cols,
        bounds.top + (j + (rnd.nextDouble() - 0.5) * jitter) * bounds.height / rows,
      );
    });
  });
  const deep = Color(0xFF1C6E91), bright = Color(0xFFDDF9FF), aqua = Color(0xFF5FD3F0);
  final edge = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = scale * 0.006
    ..color = Colors.white.withValues(alpha: 0.42);
  for (var j = 0; j < rows; j++) {
    for (var i = 0; i < cols; i++) {
      final a = pts[j][i], b = pts[j][i + 1], d = pts[j + 1][i], e = pts[j + 1][i + 1];
      final tris = (i + j).isEven ? [[a, b, e], [a, e, d]] : [[a, b, d], [b, e, d]];
      for (final t in tris) {
        final cen = (t[0] + t[1] + t[2]) / 3;
        final lx = (cen.dx - bounds.left) / bounds.width, ly = (cen.dy - bounds.top) / bounds.height;
        // Light from the top left, plus facet-to-facet sparkle.
        var light = (1.15 - (lx * 0.55 + ly * 0.75)) + (rnd.nextDouble() - 0.5) * 0.55;
        light = light.clamp(0.0, 1.0);
        var col = light > 0.5 ? Color.lerp(aqua, bright, (light - 0.5) * 2)! : Color.lerp(deep, aqua, light * 2)!;
        final prism = rnd.nextDouble();
        if (prism < 0.07) col = Color.lerp(col, const Color(0xFFB9A4FF), 0.55)!; // amethyst glint
        if (prism > 0.95) col = Color.lerp(col, const Color(0xFF7CF2C2), 0.5)!; // emerald glint
        final path = Path()..addPolygon(t, true);
        canvas.drawPath(path, Paint()..color = col.withValues(alpha: 0.92));
        canvas.drawPath(path, edge);
      }
    }
  }
  // Folds glowing inside the crystal.
  for (final sp in _sulciUnit()) {
    final p = sp.transform(m.storage);
    canvas.drawPath(
      p,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = scale * 0.024
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFF0B3C55).withValues(alpha: 0.5),
    );
    canvas.drawPath(
      p,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = scale * 0.009
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withValues(alpha: 0.9),
    );
  }
  // Glossy highlight across the top.
  canvas.drawOval(
    Rect.fromLTWH(bounds.left + bounds.width * 0.12, bounds.top + bounds.height * 0.04, bounds.width * 0.55, bounds.height * 0.32),
    Paint()
      ..shader = RadialGradient(colors: [Colors.white.withValues(alpha: 0.45), Colors.white.withValues(alpha: 0)])
          .createShader(Rect.fromLTWH(bounds.left + bounds.width * 0.12, bounds.top, bounds.width * 0.55, bounds.height * 0.36)),
  );
  canvas.restore();
  // Bright rim.
  canvas.drawPath(
    brain,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = scale * 0.014
      ..color = const Color(0xFFE6FBFF),
  );
  for (final r in rings) {
    _ringHalf(canvas, c, r.rx, r.ry, r.tilt, true, lw);
  }
}

Future<Uint8List> _png(void Function(Canvas) draw) async {
  final rec = ui.PictureRecorder();
  draw(Canvas(rec));
  final img = await rec.endRecording().toImage(_s.toInt(), _s.toInt());
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<void> _loadFonts() async {
  for (final (family, files) in [
    ('Cormorant', ['CormorantGaramond-Bold', 'CormorantGaramond-BoldItalic', 'CormorantGaramond-SemiBoldItalic']),
  ]) {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(File('assets/fonts/$f.ttf').readAsBytes().then((b) => ByteData.view(b.buffer)));
    }
    await loader.load();
  }
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('launcher icon paints (ICON_GEN=1 writes the files)', (tester) async {
    await tester.runAsync(() async {
      final full = await _png((c) {
        _velvet(c);
        _emblem(c, _s * 0.50);
      });
      // Adaptive foreground: the launcher masks to a circle/squircle of ~66 % of the canvas.
      final fg = await _png((c) => _emblem(c, _s * 0.36));
      final bg = await _png(_velvet);
      expect(full.length, greaterThan(1000));
      if (Platform.environment['ICON_GEN'] == '1') {
        File('assets/icon/icon_ios.png').writeAsBytesSync(full);
        File('assets/icon/icon_fg.png').writeAsBytesSync(fg);
        File('assets/icon/icon_bg.png').writeAsBytesSync(bg);
        File('store/app_icon_store_1024.png').writeAsBytesSync(full);
      }
    });
    expect(math.pi, greaterThan(3));
  });
}
