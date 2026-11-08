import 'package:flutter/material.dart';

import 'cube_net.dart';

Color cubeColor(CubeFace f) => switch (f) {
  CubeFace.u => const Color(0xFFF5F7FA),
  CubeFace.d => const Color(0xFFFFD43B),
  CubeFace.f => const Color(0xFF2FBF5B),
  CubeFace.b => const Color(0xFF2E6FF2),
  CubeFace.r => const Color(0xFFE5383B),
  CubeFace.l => const Color(0xFFFF8C1A),
};

/// The scrambled cube as a cross-shaped net (U on top, L F R B across,
/// D below), held white up, green front as the scramble is applied.
class CubeNetView extends StatelessWidget {
  const CubeNetView({super.key, required this.size, required this.scramble});

  final int size;
  final String scramble;

  @override
  Widget build(BuildContext context) {
    final cube = CubeNet.scrambled(size, scramble);
    return AspectRatio(
      aspectRatio: 4 / 3,
      child: CustomPaint(painter: _NetPainter(cube)),
    );
  }
}

class _NetPainter extends CustomPainter {
  _NetPainter(this.cube);

  final CubeNet cube;

  static const _layout = {
    CubeFace.u: (1, 0),
    CubeFace.l: (0, 1),
    CubeFace.f: (1, 1),
    CubeFace.r: (2, 1),
    CubeFace.b: (3, 1),
    CubeFace.d: (1, 2),
  };

  @override
  void paint(Canvas canvas, Size size) {
    final face = size.width / 4;
    final cell = face / cube.n;
    final gap = cell * 0.08;
    final paint = Paint();
    for (final MapEntry(key: f, value: (col, row)) in _layout.entries) {
      final grid = cube.grid(f);
      final origin = Offset(col * face, row * face);
      paint.color = const Color(0xFF0A0F1C); // between stickers
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          (origin & Size(face, face)).deflate(gap),
          Radius.circular(cell * 0.2),
        ),
        paint,
      );
      for (var r = 0; r < cube.n; r++) {
        for (var c = 0; c < cube.n; c++) {
          paint.color = cubeColor(grid[r][c]);
          final rect = Rect.fromLTWH(
            origin.dx + c * cell,
            origin.dy + r * cell,
            cell,
            cell,
          ).deflate(gap * 1.6);
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, Radius.circular(cell * 0.15)),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_NetPainter old) => old.cube != cube;
}
