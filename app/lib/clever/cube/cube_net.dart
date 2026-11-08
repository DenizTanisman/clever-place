import 'dart:math';

/// Faces in the order the net and the colours use them. WCA hold: white
/// up, green front, so U white · R red · F green · D yellow · L orange ·
/// B blue.
enum CubeFace { u, r, f, d, l, b }

/// One parsed turn in WCA notation: `R`, `R'`, `R2`, `Rw`, `3Rw2`, `r`.
class CubeMove {
  const CubeMove(this.face, this.width, this.turns);

  final CubeFace face;

  /// Layers turned from the face inwards (1 = the outer layer).
  final int width;

  /// Quarter turns clockwise seen from the face: 1, 2 or 3 (= ').
  final int turns;

  static final _token = RegExp(r"^(\d*)([URFDLBurfdlb])(w?)(['2]?)$");

  /// Null for anything that is not a face turn (rotations included).
  static CubeMove? parse(String token) {
    final m = _token.firstMatch(token.trim());
    if (m == null) return null;
    final letter = m.group(2)!;
    final wide = m.group(3)!.isNotEmpty || letter.toLowerCase() == letter;
    final depth = int.tryParse(m.group(1)!);
    final face = CubeFace.values['urfdlb'.indexOf(letter.toLowerCase())];
    final width = wide ? (depth ?? 2) : 1;
    final turns = switch (m.group(4)) {
      "'" => 3,
      '2' => 2,
      _ => 1,
    };
    return CubeMove(face, width, turns);
  }

  static List<CubeMove> parseAll(String alg) => [
    for (final t in alg.split(RegExp(r'\s+')))
      if (parse(t) case final m?) m,
  ];
}

/// A sticker-level N×N×N cube, enough to draw what a scramble does.
///
/// Every sticker keeps its 3D position on a grid where cubie centres sit
/// at the odd coordinates −(n−1)…(n−1) and the faces at ±n (x → R,
/// y → U, z → F). A turn rotates the stickers of its layers a quarter
/// about the face's axis, so any size and wide turn come for free.
class CubeNet {
  CubeNet(this.n) : _x = [], _y = [], _z = [], _c = [] {
    for (final face in CubeFace.values) {
      for (var a = -(n - 1); a <= n - 1; a += 2) {
        for (var b = -(n - 1); b <= n - 1; b += 2) {
          final (x, y, z) = switch (face) {
            CubeFace.u => (a, n, b),
            CubeFace.d => (a, -n, b),
            CubeFace.r => (n, a, b),
            CubeFace.l => (-n, a, b),
            CubeFace.f => (a, b, n),
            CubeFace.b => (a, b, -n),
          };
          _x.add(x);
          _y.add(y);
          _z.add(z);
          _c.add(face);
        }
      }
    }
  }

  /// [n]×[n]×[n] with [alg] applied to a solved cube.
  factory CubeNet.scrambled(int n, String alg) {
    final cube = CubeNet(n);
    for (final move in CubeMove.parseAll(alg)) {
      cube.apply(move);
    }
    return cube;
  }

  final int n;
  final List<int> _x, _y, _z;

  /// The colour of each sticker, named by the face it started on.
  final List<CubeFace> _c;

  void apply(CubeMove move) {
    // Outward axis of the face: which coordinate and which sign.
    final (axis, sign) = switch (move.face) {
      CubeFace.r => (0, 1),
      CubeFace.l => (0, -1),
      CubeFace.u => (1, 1),
      CubeFace.d => (1, -1),
      CubeFace.f => (2, 1),
      CubeFace.b => (2, -1),
    };
    final limit = n - 2 * move.width;
    // Clockwise seen from outside is −90° about the outward normal, so
    // +90° about the positive axis for the L, D and B side.
    final quarters = sign > 0 ? 4 - move.turns : move.turns;
    for (var i = 0; i < _c.length; i++) {
      final along = switch (axis) {
        0 => _x[i],
        1 => _y[i],
        _ => _z[i],
      };
      if (sign * along <= limit) continue;
      for (var q = 0; q < quarters; q++) {
        // One +90° right-hand turn about the axis.
        switch (axis) {
          case 0:
            final y = _y[i];
            _y[i] = -_z[i];
            _z[i] = y;
          case 1:
            final z = _z[i];
            _z[i] = -_x[i];
            _x[i] = z;
          default:
            final x = _x[i];
            _x[i] = -_y[i];
            _y[i] = x;
        }
      }
    }
  }

  /// The colours on [face], row by row as in the usual net: U with F at
  /// its bottom, the four sides upright, D with F at its top.
  List<List<CubeFace>> grid(CubeFace face) {
    final rows = List.generate(n, (_) => List.filled(n, CubeFace.u));
    int idx(int v) => (v + n - 1) ~/ 2;
    int rev(int v) => (n - 1 - v) ~/ 2;
    for (var i = 0; i < _c.length; i++) {
      final x = _x[i], y = _y[i], z = _z[i];
      final (bool on, int row, int col) = switch (face) {
        CubeFace.u => (y == n, idx(z), idx(x)),
        CubeFace.d => (y == -n, rev(z), idx(x)),
        CubeFace.f => (z == n, rev(y), idx(x)),
        CubeFace.b => (z == -n, rev(y), rev(x)),
        CubeFace.r => (x == n, rev(y), rev(z)),
        CubeFace.l => (x == -n, rev(y), idx(z)),
      };
      if (on) rows[row][col] = _c[i];
    }
    return rows;
  }

  bool get isSolved => CubeFace.values.every(
    (f) => grid(f).every((row) => row.every((c) => c == f)),
  );
}

/// A random-move scramble, used only when the stored list is missing.
/// No face twice in a row, and no `R L R`-style returns on one axis.
String randomMoveScramble(int n, {Random? random}) {
  final rnd = random ?? Random();
  final length = n <= 3 ? 25 : 40;
  const letters = 'URFDLB';
  final out = <String>[];
  int? last, beforeLast;
  while (out.length < length) {
    final f = rnd.nextInt(6);
    if (f == last) continue;
    if (last != null && f % 3 == last % 3 && f == beforeLast) continue;
    beforeLast = last;
    last = f;
    // WCA 4x4 scrambles widen only U, R and F.
    final wide = n > 3 && f < 3 && rnd.nextBool() ? 'w' : '';
    out.add('${letters[f]}$wide${const ['', "'", '2'][rnd.nextInt(3)]}');
  }
  return out.join(' ');
}
