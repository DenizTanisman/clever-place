// Cubie-level 3x3 model (Kociemba conventions) and a geometric sticker
// simulator used to check it. Faces: U0 R1 F2 D3 L4 B5. A move index is
// face * 3 + (quarter turns - 1).

/// Corners URF UFL ULB UBR DFR DLF DBL DRB, edges UR UF UL UB DR DF DL DB FR
/// FL BL BR. `cp[i]` is the cubie sitting at position i.
class Cubie {
  final List<int> cp, co, ep, eo;
  Cubie(this.cp, this.co, this.ep, this.eo);
  Cubie.solved()
    : cp = List.generate(8, (i) => i),
      co = List.filled(8, 0),
      ep = List.generate(12, (i) => i),
      eo = List.filled(12, 0);
  Cubie copy() => Cubie(List.of(cp), List.of(co), List.of(ep), List.of(eo));

  /// This state followed by [b].
  Cubie mul(Cubie b) {
    final ncp = List.filled(8, 0), nco = List.filled(8, 0);
    final nep = List.filled(12, 0), neo = List.filled(12, 0);
    for (var i = 0; i < 8; i++) {
      ncp[i] = cp[b.cp[i]];
      nco[i] = (co[b.cp[i]] + b.co[i]) % 3;
    }
    for (var i = 0; i < 12; i++) {
      nep[i] = ep[b.ep[i]];
      neo[i] = (eo[b.ep[i]] + b.eo[i]) % 2;
    }
    return Cubie(ncp, nco, nep, neo);
  }

  Cubie inverse() {
    final ncp = List.filled(8, 0), nco = List.filled(8, 0);
    final nep = List.filled(12, 0), neo = List.filled(12, 0);
    for (var i = 0; i < 8; i++) {
      ncp[cp[i]] = i;
    }
    for (var i = 0; i < 8; i++) {
      nco[i] = (3 - co[ncp[i]]) % 3;
    }
    for (var i = 0; i < 12; i++) {
      nep[ep[i]] = i;
    }
    for (var i = 0; i < 12; i++) {
      neo[i] = eo[nep[i]];
    }
    return Cubie(ncp, nco, nep, neo);
  }

  bool sameAs(Cubie o) {
    for (var i = 0; i < 8; i++) {
      if (cp[i] != o.cp[i] || co[i] != o.co[i]) return false;
    }
    for (var i = 0; i < 12; i++) {
      if (ep[i] != o.ep[i] || eo[i] != o.eo[i]) return false;
    }
    return true;
  }

  Cubie apply(List<int> moves) {
    var c = this;
    for (final m in moves) {
      c = c.mul(moveCubes[m]);
    }
    return c;
  }
}

Cubie _basic(List<int> cp, List<int> co, List<int> ep, List<int> eo) =>
    Cubie(cp, co, ep, eo);

const _z8 = [0, 0, 0, 0, 0, 0, 0, 0];
const _z12 = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
final List<Cubie> _basics = [
  _basic([3, 0, 1, 2, 4, 5, 6, 7], _z8, [3, 0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11], _z12), // U
  _basic([4, 1, 2, 0, 7, 5, 6, 3], [2, 0, 0, 1, 1, 0, 0, 2],
      [8, 1, 2, 3, 11, 5, 6, 7, 4, 9, 10, 0], _z12), // R
  _basic([1, 5, 2, 3, 0, 4, 6, 7], [1, 2, 0, 0, 2, 1, 0, 0],
      [0, 9, 2, 3, 4, 8, 6, 7, 1, 5, 10, 11], [0, 1, 0, 0, 0, 1, 0, 0, 1, 1, 0, 0]), // F
  _basic([0, 1, 2, 3, 5, 6, 7, 4], _z8, [0, 1, 2, 3, 5, 6, 7, 4, 8, 9, 10, 11], _z12), // D
  _basic([0, 2, 6, 3, 4, 1, 5, 7], [0, 1, 2, 0, 0, 2, 1, 0],
      [0, 1, 10, 3, 4, 5, 9, 7, 8, 2, 6, 11], _z12), // L
  _basic([0, 1, 3, 7, 4, 5, 2, 6], [0, 0, 1, 2, 0, 0, 2, 1],
      [0, 1, 2, 11, 4, 5, 6, 10, 8, 9, 3, 7], [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 1]), // B
];

/// The 18 face moves as cubie states.
final List<Cubie> moveCubes = () {
  final out = <Cubie>[];
  for (final b in _basics) {
    var c = Cubie.solved();
    for (var k = 0; k < 3; k++) {
      c = c.mul(b);
      out.add(c);
    }
  }
  return out;
}();

const faceLetters = 'URFDLB';

String moveName(int m) => faceLetters[m ~/ 3] + const ['', '2', "'"][m % 3];

String movesToString(List<int> ms) => ms.map(moveName).join(' ');

int invMove(int m) => (m ~/ 3) * 3 + (2 - m % 3);

/// Face moves only (U, R2, F' …).
List<int> parseFaceMoves(String s) {
  final out = <int>[];
  for (final t in s.trim().split(RegExp(r'\s+'))) {
    if (t.isEmpty) continue;
    final f = faceLetters.indexOf(t[0]);
    if (f < 0 || t.length > 2) throw FormatException('hamle: $t');
    final p = t.length == 1 ? 0 : (t[1] == '2' ? 1 : (t[1] == "'" ? 2 : -1));
    if (p < 0) throw FormatException('hamle: $t');
    out.add(f * 3 + p);
  }
  return out;
}

/// Whole-cube rotations that bring a color's center to D, with the face map
/// (a turn of face f made before the rotation is a turn of `map[f]` after).
const rotations = {
  'W': 'z2',
  'Y': '',
  'G': "x'",
  'B': 'x',
  'R': 'z',
  'O': "z'",
};
const _faceMaps = {
  '': [0, 1, 2, 3, 4, 5],
  'z2': [3, 4, 2, 0, 1, 5], // U→D R→L F→F D→U L→R B→B
  'x': [5, 1, 0, 2, 4, 3], // U→B F→U D→F B→D
  "x'": [2, 1, 3, 5, 4, 0], // U→F F→D D→B B→U
  'z': [1, 3, 2, 4, 0, 5], // U→R R→D D→L L→U
  "z'": [4, 0, 2, 1, 3, 5], // U→L R→U D→R L→D
};

List<int> mapThroughRotation(List<int> moves, String rot) {
  final fm = _faceMaps[rot]!;
  return [for (final m in moves) fm[m ~/ 3] * 3 + m % 3];
}

// ---------------------------------------------------------------------------
// Geometric sticker simulator: independent of the tables above.

class _St {
  int x, y, z, nx, ny, nz;
  final int color;
  _St(this.x, this.y, this.z, this.nx, this.ny, this.nz, this.color);
}

const _normals = [
  [0, 1, 0], // U
  [1, 0, 0], // R
  [0, 0, 1], // F
  [0, -1, 0], // D
  [-1, 0, 0], // L
  [0, 0, -1], // B
];

int _faceOfNormal(int nx, int ny, int nz) {
  for (var f = 0; f < 6; f++) {
    final n = _normals[f];
    if (n[0] == nx && n[1] == ny && n[2] == nz) return f;
  }
  throw StateError('normal');
}

/// Stickers carry the color of the face they started on (0..5 = U..B; with
/// WCA holding that is white, red, green, yellow, orange, blue).
class Facelets {
  final List<_St> _st = [];
  Facelets() {
    for (var f = 0; f < 6; f++) {
      final n = _normals[f];
      for (var a = -1; a <= 1; a++) {
        for (var b = -1; b <= 1; b++) {
          int x, y, z;
          if (n[0] != 0) {
            x = n[0];
            y = a;
            z = b;
          } else if (n[1] != 0) {
            y = n[1];
            x = a;
            z = b;
          } else {
            z = n[2];
            x = a;
            y = b;
          }
          _st.add(_St(x, y, z, n[0], n[1], n[2], f));
        }
      }
    }
  }

  void _turn(int axis, List<int> layers, int q) {
    for (final s in _st) {
      final c = axis == 0 ? s.x : (axis == 1 ? s.y : s.z);
      if (!layers.contains(c)) continue;
      for (var k = 0; k < q; k++) {
        final x = s.x, y = s.y, z = s.z, nx = s.nx, ny = s.ny, nz = s.nz;
        if (axis == 0) {
          s.y = z;
          s.z = -y;
          s.ny = nz;
          s.nz = -ny;
        } else if (axis == 1) {
          s.x = -z;
          s.z = x;
          s.nx = -nz;
          s.nz = nx;
        } else {
          s.x = y;
          s.y = -x;
          s.nx = ny;
          s.ny = -nx;
        }
      }
    }
  }

  static final _tok = RegExp(r"^([URFDLBMESxyzurfdlb])(w?)(2'|2|')?$");

  /// Any 3x3 notation: face turns, wide (r, Rw), slices, rotations.
  void apply(String alg) {
    for (final t in alg.trim().split(RegExp(r'\s+'))) {
      if (t.isEmpty) continue;
      final m = _tok.firstMatch(t);
      if (m == null) throw FormatException('hamle: $t');
      var c = m.group(1)!;
      final wide = m.group(2) == 'w';
      final suf = m.group(3) ?? '';
      final amt = suf.startsWith('2') ? 2 : (suf == "'" ? 3 : 1);
      if (wide) c = c.toLowerCase();
      late int axis, sign;
      late List<int> layers;
      switch (c) {
        case 'R': axis = 0; sign = 1; layers = [1];
        case 'L': axis = 0; sign = -1; layers = [-1];
        case 'M': axis = 0; sign = -1; layers = [0];
        case 'r': axis = 0; sign = 1; layers = [0, 1];
        case 'l': axis = 0; sign = -1; layers = [-1, 0];
        case 'x': axis = 0; sign = 1; layers = [-1, 0, 1];
        case 'U': axis = 1; sign = 1; layers = [1];
        case 'D': axis = 1; sign = -1; layers = [-1];
        case 'E': axis = 1; sign = -1; layers = [0];
        case 'u': axis = 1; sign = 1; layers = [0, 1];
        case 'd': axis = 1; sign = -1; layers = [-1, 0];
        case 'y': axis = 1; sign = 1; layers = [-1, 0, 1];
        case 'F': axis = 2; sign = 1; layers = [1];
        case 'B': axis = 2; sign = -1; layers = [-1];
        case 'S': axis = 2; sign = 1; layers = [0];
        case 'f': axis = 2; sign = 1; layers = [0, 1];
        case 'b': axis = 2; sign = -1; layers = [-1, 0];
        case 'z': axis = 2; sign = 1; layers = [-1, 0, 1];
      }
      _turn(axis, layers, sign > 0 ? amt : (4 - amt) % 4);
    }
  }

  /// Sticker colors keyed by (position, face of normal).
  Map<int, int> _map() {
    final m = <int, int>{};
    for (final s in _st) {
      m[(((s.x + 1) * 9 + (s.y + 1) * 3 + (s.z + 1)) * 6) +
          _faceOfNormal(s.nx, s.ny, s.nz)] = s.color;
    }
    return m;
  }

  static int _key(List<int> p, int face) =>
      (((p[0] + 1) * 9 + (p[1] + 1) * 3 + (p[2] + 1)) * 6) + face;

  static const _cornerPos = [
    [1, 1, 1], [-1, 1, 1], [-1, 1, -1], [1, 1, -1],
    [1, -1, 1], [-1, -1, 1], [-1, -1, -1], [1, -1, -1],
  ];
  static const _cornerFaces = [
    [0, 1, 2], [0, 2, 4], [0, 4, 5], [0, 5, 1],
    [3, 2, 1], [3, 4, 2], [3, 5, 4], [3, 1, 5],
  ];
  static const _edgePos = [
    [1, 1, 0], [0, 1, 1], [-1, 1, 0], [0, 1, -1],
    [1, -1, 0], [0, -1, 1], [-1, -1, 0], [0, -1, -1],
    [1, 0, 1], [-1, 0, 1], [-1, 0, -1], [1, 0, -1],
  ];
  static const _edgeFaces = [
    [0, 1], [0, 2], [0, 4], [0, 5], [3, 1], [3, 2], [3, 4], [3, 5],
    [2, 1], [2, 4], [5, 4], [5, 1],
  ];

  /// The state relative to the centers, read in the current holding. Null if
  /// the stickers do not form a cube (cannot happen for real turns).
  Cubie? toCubie() {
    final m = _map();
    // color → face by the center currently on that face.
    final faceOf = List.filled(6, -1);
    for (var f = 0; f < 6; f++) {
      faceOf[m[_key(_normals[f], f)]!] = f;
    }
    final cp = List.filled(8, 0), co = List.filled(8, 0);
    for (var i = 0; i < 8; i++) {
      final f = [for (final x in _cornerFaces[i]) faceOf[m[_key(_cornerPos[i], x)]!]];
      final j = f.indexWhere((x) => x == 0 || x == 3);
      if (j < 0) return null;
      final c1 = f[(j + 1) % 3], c2 = f[(j + 2) % 3];
      final k = _cornerFaces.indexWhere((cf) => cf[1] == c1 && cf[2] == c2);
      if (k < 0) return null;
      cp[i] = k;
      co[i] = j;
    }
    final ep = List.filled(12, 0), eo = List.filled(12, 0);
    for (var i = 0; i < 12; i++) {
      final a = faceOf[m[_key(_edgePos[i], _edgeFaces[i][0])]!];
      final b = faceOf[m[_key(_edgePos[i], _edgeFaces[i][1])]!];
      var k = _edgeFaces.indexWhere((e) => e[0] == a && e[1] == b);
      if (k >= 0) {
        ep[i] = k;
      } else {
        k = _edgeFaces.indexWhere((e) => e[0] == b && e[1] == a);
        if (k < 0) return null;
        ep[i] = k;
        eo[i] = 1;
      }
    }
    return Cubie(cp, co, ep, eo);
  }

  /// Turns the whole cube so the starting centers are home again.
  void normalize() {
    const rots = ['', 'x', 'x2', "x'", 'z', "z'"];
    const ys = ['', 'y', 'y2', "y'"];
    for (final a in rots) {
      for (final b in ys) {
        final t = Facelets().._st.clear();
        for (final s in _st) {
          t._st.add(_St(s.x, s.y, s.z, s.nx, s.ny, s.nz, s.color));
        }
        t.apply('$a $b');
        final m = t._map();
        var home = true;
        for (var f = 0; f < 6 && home; f++) {
          if (m[_key(_normals[f], f)] != f) home = false;
        }
        if (home) {
          _st
            ..clear()
            ..addAll(t._st);
          return;
        }
      }
    }
    throw StateError('normalize');
  }
}

/// The effect of any algorithm relative to the centers, as a cubie state.
Cubie algCubie(String alg) {
  final f = Facelets()..apply(alg);
  f.normalize();
  return f.toCubie()!;
}
