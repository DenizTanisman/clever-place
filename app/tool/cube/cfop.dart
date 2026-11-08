// CFOP analysis in a frame with the cross color on D: optimal cross and
// x-cross (exact pruning tables), greedy F2L pair insertions that keep the
// cross and earlier pairs, and last-layer classification by the 2-look
// algorithms of Küp Defteri (plus E, Na, Nb for full PLL names).
import 'dart:io';
import 'dart:typed_data';

import 'cubie.dart';

// --- piece motion -----------------------------------------------------------

final Int8List _eDest = Int8List(18 * 12), _eFlip = Int8List(18 * 12);
final Int8List _cDest = Int8List(18 * 8), _cTw = Int8List(18 * 8);
final Int8List _pc = Int8List(4096);
bool _motionReady = false;

void _initMotion() {
  if (_motionReady) return;
  for (var m = 0; m < 18; m++) {
    final mc = moveCubes[m];
    for (var i = 0; i < 12; i++) {
      _eDest[m * 12 + mc.ep[i]] = i;
      _eFlip[m * 12 + mc.ep[i]] = mc.eo[i];
    }
    for (var i = 0; i < 8; i++) {
      _cDest[m * 8 + mc.cp[i]] = i;
      _cTw[m * 8 + mc.cp[i]] = mc.co[i];
    }
  }
  for (var i = 1; i < 4096; i++) {
    _pc[i] = _pc[i >> 1] + (i & 1);
  }
  _motionReady = true;
}

// --- index encodings ----------------------------------------------------------
// cross: 4 D edges (DR DF DL DB) → arr4 * 16 + ori bits (190080)
// ce(s): cross + slot edge → (arr4 * 8 + r5) * 32 + ori4 * 2 + o5 (3041280)
// cc(s): cross index * 24 + corner pos * 3 + twist (4561920)

int _arr4(List<int> p, int o) {
  var used = 0, idx = 0;
  for (var i = 0; i < 4; i++) {
    final x = p[o + i];
    idx = idx * (12 - i) + x - _pc[used & ((1 << x) - 1)];
    used |= 1 << x;
  }
  return idx;
}

int _rank5(List<int> p, int o, int x) {
  var used = 0;
  for (var i = 0; i < 4; i++) {
    used |= 1 << p[o + i];
  }
  return x - _pc[used & ((1 << x) - 1)];
}

void _decodeArr(int idx, int k, List<int> out) {
  final r = List.filled(k, 0);
  for (var i = k - 1; i >= 0; i--) {
    r[i] = idx % (12 - i);
    idx ~/= (12 - i);
  }
  var used = 0;
  for (var i = 0; i < k; i++) {
    var c = r[i];
    for (var x = 0; x < 12; x++) {
      if (used & (1 << x) != 0) continue;
      if (c == 0) {
        out[i] = x;
        used |= 1 << x;
        break;
      }
      c--;
    }
  }
}

const crossSize = 190080, ceSize = 3041280, ccSize = 4561920;

Int8List _bfsTable(int size, int solved, void Function(int idx, List<int> ep, List<int> eo, List<int> c) decode,
    int Function(List<int> ep, List<int> eo, List<int> c) encode, int ne, bool corner) {
  final t = Int8List(size)..fillRange(0, size, -1);
  final q = Int32List(size);
  var head = 0, tail = 0;
  t[solved] = 0;
  q[tail++] = solved;
  final ep = List.filled(5, 0), eo = List.filled(5, 0), c = List.filled(2, 0);
  final np = List.filled(5, 0), no = List.filled(5, 0), nc = List.filled(2, 0);
  while (head < tail) {
    final idx = q[head++];
    decode(idx, ep, eo, c);
    final d = t[idx];
    for (var m = 0; m < 18; m++) {
      for (var i = 0; i < ne; i++) {
        np[i] = _eDest[m * 12 + ep[i]];
        no[i] = eo[i] ^ _eFlip[m * 12 + ep[i]];
      }
      if (corner) {
        nc[0] = _cDest[m * 8 + c[0]];
        nc[1] = (c[1] + _cTw[m * 8 + c[0]]) % 3;
      }
      final j = encode(np, no, nc);
      if (t[j] < 0) {
        t[j] = d + 1;
        q[tail++] = j;
      }
    }
  }
  return t;
}

int _crossEnc(List<int> p, List<int> o) =>
    _arr4(p, 0) * 16 + (o[0] << 3 | o[1] << 2 | o[2] << 1 | o[3]);

void _crossDec(int idx, List<int> p, List<int> o) {
  final b = idx % 16;
  _decodeArr(idx ~/ 16, 4, p);
  o[0] = b >> 3 & 1;
  o[1] = b >> 2 & 1;
  o[2] = b >> 1 & 1;
  o[3] = b & 1;
}

int _ceEnc(List<int> p, List<int> o) =>
    ((_arr4(p, 0) * 8 + _rank5(p, 0, p[4])) * 32) +
    ((o[0] << 3 | o[1] << 2 | o[2] << 1 | o[3]) * 2 + o[4]);

void _ceDec(int idx, List<int> p, List<int> o) {
  final ob = idx % 32;
  _decodeArr(idx ~/ 32, 5, p);
  o[0] = ob >> 4 & 1;
  o[1] = ob >> 3 & 1;
  o[2] = ob >> 2 & 1;
  o[3] = ob >> 1 & 1;
  o[4] = ob & 1;
}

class Tables {
  final Int8List cross;
  final List<Int8List> ce, cc;
  Tables(this.cross, this.ce, this.cc);

  /// Builds the tables once and keeps them in [dir]; later calls read them.
  static Tables loadOrBuild(String dir) {
    _initMotion();
    Directory(dir).createSync(recursive: true);
    Int8List get(String name, Int8List Function() build) {
      final f = File('$dir/$name.bin');
      if (f.existsSync()) return Int8List.fromList(f.readAsBytesSync());
      final t = build();
      f.writeAsBytesSync(t, flush: true);
      return t;
    }

    final solvedP = [4, 5, 6, 7];
    final zero = [0, 0, 0, 0, 0];
    final cross = get('cross', () => _bfsTable(crossSize, _crossEnc(solvedP, zero),
        (i, p, o, c) => _crossDec(i, p, o), (p, o, c) => _crossEnc(p, o), 4, false));
    final ce = <Int8List>[], cc = <Int8List>[];
    for (var s = 0; s < 4; s++) {
      final sp = [4, 5, 6, 7, 8 + s];
      ce.add(get('ce$s', () => _bfsTable(ceSize, _ceEnc(sp, zero),
          (i, p, o, c) => _ceDec(i, p, o), (p, o, c) => _ceEnc(p, o), 5, false)));
      cc.add(get('cc$s', () => _bfsTable(ccSize, _crossEnc(solvedP, zero) * 24 + (4 + s) * 3,
          (i, p, o, c) {
            _crossDec(i ~/ 24, p, o);
            c[0] = (i % 24) ~/ 3;
            c[1] = i % 3;
          }, (p, o, c) => _crossEnc(p, o) * 24 + c[0] * 3 + c[1], 4, true)));
    }
    return Tables(cross, ce, cc);
  }
}

// --- search -----------------------------------------------------------------

const slotNames = ['FR', 'FL', 'BL', 'BR'];
final List<int> allMoves = List.generate(18, (i) => i);

/// Every face but D: the fallback set for a pair.
final List<int> noDMoves = [for (var m = 0; m < 18; m++) if (m ~/ 3 != 3) m];

/// A pair the way a hand does it: U and the two faces beside the slot
/// (FR: R F, FL: F L, BL: L B, BR: R B).
final List<List<int>> slotMoves = [
  for (final fs in const [[1, 2], [2, 4], [4, 5], [1, 5]])
    [0, 1, 2, for (final f in fs) ...[f * 3, f * 3 + 1, f * 3 + 2]],
];

/// Tracked pieces: edges DR DF DL DB FR FL BL BR, corners DFR DLF DBL DRB.
class F2L {
  final Tables t;
  static const maxD = 24;
  final Int8List _ep = Int8List(maxD * 8), _eo = Int8List(maxD * 8);
  final Int8List _cp = Int8List(maxD * 4), _co = Int8List(maxD * 4);
  final List<int> _path = List.filled(maxD, 0);
  final List<int> _tmpP = List.filled(5, 0), _tmpO = List.filled(5, 0);
  int nodes = 0;
  F2L(this.t) {
    _initMotion();
  }

  void load(Cubie c) {
    for (var k = 0; k < 8; k++) {
      final i = c.ep.indexOf(4 + k);
      _ep[k] = i;
      _eo[k] = c.eo[i];
    }
    for (var k = 0; k < 4; k++) {
      final i = c.cp.indexOf(4 + k);
      _cp[k] = i;
      _co[k] = c.co[i];
    }
  }

  int _h(int d, int mask) {
    final eb = d * 8, cb = d * 4;
    for (var i = 0; i < 4; i++) {
      _tmpP[i] = _ep[eb + i];
      _tmpO[i] = _eo[eb + i];
    }
    final ci = _crossEnc(_tmpP, _tmpO);
    if (mask == 0) return t.cross[ci];
    var h = 0;
    for (var s = 0; s < 4; s++) {
      if (mask & (1 << s) == 0) continue;
      _tmpP[4] = _ep[eb + 4 + s];
      _tmpO[4] = _eo[eb + 4 + s];
      final a = t.ce[s][_ceEnc(_tmpP, _tmpO)];
      final b = t.cc[s][ci * 24 + _cp[cb + s] * 3 + _co[cb + s]];
      if (a > h) h = a;
      if (b > h) h = b;
    }
    return h;
  }

  void _step(int d, int m) {
    final a = d * 8, b = (d + 1) * 8;
    for (var i = 0; i < 8; i++) {
      final p = _ep[a + i];
      _ep[b + i] = _eDest[m * 12 + p];
      _eo[b + i] = _eo[a + i] ^ _eFlip[m * 12 + p];
    }
    final ca = d * 4, cb = (d + 1) * 4;
    for (var i = 0; i < 4; i++) {
      final p = _cp[ca + i];
      _cp[cb + i] = _cDest[m * 8 + p];
      _co[cb + i] = (_co[ca + i] + _cTw[m * 8 + p]) % 3;
    }
  }

  static bool _skip(int f, int lf) => f == lf || (f == (lf + 3) % 6 && f < lf);

  late List<int> _moves;
  late int _mask, _cap;
  List<List<int>>? _all;

  bool _dfs(int d, int togo) {
    final h = _h(d, _mask);
    if (h > togo) return false;
    if (togo == 0) {
      if (h != 0) return false;
      if (_all == null) return true;
      _all!.add(_path.sublist(0, d));
      return _all!.length >= _cap;
    }
    for (final m in _moves) {
      if (d > 0 && _skip(m ~/ 3, _path[d - 1] ~/ 3)) continue;
      nodes++;
      _path[d] = m;
      _step(d, m);
      if (_dfs(d + 1, togo - 1)) return true;
    }
    return false;
  }

  /// Shortest sequence (≤ [maxLen]) from [moves] solving the cross plus the
  /// slots in [mask] from the loaded state.
  List<int>? shortest(int mask, int maxLen, [List<int>? moves]) {
    _moves = moves ?? allMoves;
    _mask = mask;
    _all = null;
    for (var L = _h(0, mask); L <= maxLen; L++) {
      if (_dfs(0, L)) return _path.sublist(0, L);
    }
    return null;
  }

  /// A sequence of exactly [len] moves, or null.
  List<int>? atDepth(int mask, int len, [List<int>? moves]) {
    _moves = moves ?? allMoves;
    _mask = mask;
    _all = null;
    return _dfs(0, len) ? _path.sublist(0, len) : null;
  }

  /// Every sequence of exactly [len] moves that does it (up to [cap]).
  List<List<int>> all(int mask, int len, int cap, [List<int>? moves]) {
    _moves = moves ?? allMoves;
    _mask = mask;
    _all = [];
    _cap = cap;
    _dfs(0, len);
    final r = _all!;
    _all = null;
    return r;
  }

  int distance(int mask) => _h(0, mask);
}

// --- last layer ------------------------------------------------------------------

const edgeAlgs = {
  'dot': "F R U R' U' F' f R U R' U' f'",
  'L': "F U R U' R' F'",
  'line': "F R U R' U' F'",
};
const ocllAlgs = {
  'Sune': "R U R' U R U2 R'",
  'Antisune': "R U2 R' U' R U' R'",
  'H': "R U R' U R U' R' U R U2 R'",
  'Pi': "R U2 R2 U' R2 U' R2 U2 R",
  'Headlights': "R2 D' R U2 R' D R U2 R",
  'T': "r U R' U' r' F R F'",
  'Bowtie': "F' r U R' U' r' F R",
};
const pllAlgs = {
  'T': "R U R' U' R' F R2 U' R' U' R U R' F'",
  'Y': "F R U' R' U' R U R' F' R U R' U' R' F R F'",
  'Ua': "R U' R U R U R U' R' U' R2",
  'Ub': "R2 U R U R' U' R' U' R' U R'",
  'H': "M2 U M2 U2 M2 U M2",
  'Z': "M' U M2 U M2 U M' U2 M2",
  'Aa': "x R' U R' D2 R U' R' D2 R2 x'",
  'Ab': "x R2' D2 R U R' D2 R U' R x'",
  'F': "R' U' F' R U R' U' R' F R2 U' R' U' R U R' U R",
  'Ja': "U' R' U L' U2 R U' R' U2 R L",
  'Jb': "R U R' F' R U R' U' R' F R2 U' R'",
  'Ra': "R U' R' U' R U R D R' U' R D' R' U2 R'",
  'Rb': "R2 F R U R U' R' F' R U2 R' U2 R",
  'V': "R' U R' U' y R' F' R2 U' R' U R' F R F",
  'Ga': "R2 U R' U R' U' R U' R2 U' D R' U R D'",
  'Gb': "R' U' R U D' R2 U R' U R U' R U' R2 D",
  'Gc': "R2 U' R U' R U R' U R2 U D' R U' R' D",
  'Gd': "R U R' U' D R2 U' R U' R' U R' U R2 D'",
  // Not in Küp Defteri (rare cases); verified below like the others.
  'E': "x' L' U L D' L' U' L D L' U' L D' L' U L D x",
  'Na': "R U R' U R U R' F' R U R' U' R' F R2 U' R' U2 R U' R'",
  'Nb': "R' U R U' R' F' U' F R U R' F R' F' R U' R",
};

int algLength(String alg) =>
    alg.trim().split(RegExp(r'\s+')).where((t) => !RegExp(r'^[xyz]').hasMatch(t)).length;

bool f2lSolved(Cubie c) {
  for (var i = 4; i < 8; i++) {
    if (c.cp[i] != i || c.co[i] != 0) return false;
  }
  for (var i = 4; i < 12; i++) {
    if (c.ep[i] != i || c.eo[i] != 0) return false;
  }
  return true;
}

bool crossSolved(Cubie c) {
  for (var i = 4; i < 8; i++) {
    if (c.ep[i] != i || c.eo[i] != 0) return false;
  }
  return true;
}

bool slotSolved(Cubie c, int s) =>
    c.cp[4 + s] == 4 + s && c.co[4 + s] == 0 && c.ep[8 + s] == 8 + s && c.eo[8 + s] == 0;

bool llOriented(Cubie c) {
  for (var i = 0; i < 4; i++) {
    if (c.co[i] != 0 || c.eo[i] != 0) return false;
  }
  return true;
}

bool edgesOriented(Cubie c) => c.eo[0] == 0 && c.eo[1] == 0 && c.eo[2] == 0 && c.eo[3] == 0;

String edgeShape(Cubie c) {
  final ok = [for (var i = 0; i < 4; i++) c.eo[i] == 0];
  final n = ok.where((x) => x).length;
  if (n == 4) return 'cross';
  if (n == 0) return 'dot';
  final i = ok.indexOf(true), j = ok.lastIndexOf(true);
  return (j - i) == 2 ? 'line' : 'L';
}

class LastLayer {
  final List<Cubie> auf = [Cubie.solved(), moveCubes[0], moveCubes[1], moveCubes[2]];
  final Map<String, Cubie> edge = {}, ocll = {}, pll = {};
  LastLayer() {
    for (final e in edgeAlgs.entries) {
      final c = algCubie(e.value);
      if (!f2lSolved(c)) throw StateError('edge alg breaks F2L: ${e.key}');
      edge[e.key] = c;
    }
    for (final e in ocllAlgs.entries) {
      final c = algCubie(e.value);
      if (!f2lSolved(c) || !edgesOriented(c)) throw StateError('OCLL alg: ${e.key}');
      ocll[e.key] = c;
    }
    for (final e in pllAlgs.entries) {
      final c = algCubie(e.value);
      if (!f2lSolved(c) || !llOriented(c)) throw StateError('PLL alg not pure: ${e.key}');
      pll[e.key] = c;
    }
  }

  bool solvedUpToAuf(Cubie c) => auf.any(c.sameAs);

  /// The user's 2-look OLL then PLL from an F2L-solved state.
  ({String edges, String oll, String pll, Cubie afterOll, int algMoves}) classify(Cubie c) {
    var algMoves = 0;
    final shape = edgeShape(c);
    if (llOriented(c)) {
      final p = pllName(c);
      return (edges: shape, oll: 'skip', pll: p, afterOll: c, algMoves: algMoves + _pllLen(p));
    }
    var s = c;
    if (shape != 'cross') {
      Cubie? next;
      for (final a in auf) {
        final t = s.mul(a).mul(edge[shape]!);
        if (edgesOriented(t)) {
          next = t;
          break;
        }
      }
      s = next!;
      algMoves += algLength(edgeAlgs[shape]!);
    }
    var oll = 'none';
    if (!llOriented(s)) {
      Cubie? next;
      for (final e in ocll.entries) {
        for (final a in auf) {
          final t = s.mul(a).mul(e.value);
          if (llOriented(t)) {
            next = t;
            oll = e.key;
            break;
          }
        }
        if (next != null) break;
      }
      s = next!;
      algMoves += algLength(ocllAlgs[oll]!);
    }
    final p = pllName(s);
    return (edges: shape, oll: oll, pll: p, afterOll: s, algMoves: algMoves + _pllLen(p));
  }

  int _pllLen(String p) => p == 'skip' ? 0 : algLength(pllAlgs[p]!);

  String pllName(Cubie c) {
    if (solvedUpToAuf(c)) return 'skip';
    for (final e in pll.entries) {
      for (final a in auf) {
        if (solvedUpToAuf(c.mul(a).mul(e.value))) return e.key;
      }
    }
    throw StateError('PLL not recognised');
  }

  /// All 288 oriented last-layer permutations get exactly one name.
  void selfCheck() {
    final seen = <String, String>{};
    String key(Cubie c) => '${c.cp.sublist(0, 4)}${c.ep.sublist(0, 4)}';
    for (final e in pll.entries) {
      final inv = e.value.inverse();
      for (final a in auf) {
        for (final b in auf) {
          final x = b.mul(inv).mul(a.inverse());
          final k = key(x);
          if (seen.containsKey(k) && seen[k] != e.key) {
            throw StateError('PLL ${e.key} overlaps ${seen[k]}');
          }
          seen[k] = e.key;
        }
      }
    }
    for (final a in auf) {
      seen[key(a)] = 'skip';
    }
    if (seen.length != 288) throw StateError('PLL coverage ${seen.length}/288');
  }
}
