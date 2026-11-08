// Kociemba two-phase solver: phase 1 reaches <U, D, R2, L2, F2, B2>
// (twist, flip, UD-slice), phase 2 solves inside it. Used to turn a uniformly
// random state into a WCA-style random-state scramble.
import 'dart:typed_data';

import 'cubie.dart';

int _c(int n, int k) {
  if (k < 0 || k > n) return 0;
  var r = 1;
  for (var i = 0; i < k; i++) {
    r = r * (n - i) ~/ (i + 1);
  }
  return r;
}

int twistOf(Cubie c) {
  var t = 0;
  for (var i = 0; i < 7; i++) {
    t = t * 3 + c.co[i];
  }
  return t;
}

int flipOf(Cubie c) {
  var t = 0;
  for (var i = 0; i < 11; i++) {
    t = t * 2 + c.eo[i];
  }
  return t;
}

int sliceOf(Cubie c) {
  var idx = 0, k = 0;
  for (var j = 0; j < 12; j++) {
    if (c.ep[j] >= 8) {
      idx += _c(j, k + 1);
      k++;
    }
  }
  return idx;
}

int permIndex(List<int> p, int from, int n) {
  var idx = 0;
  for (var i = 0; i < n; i++) {
    var c = 0;
    for (var j = i + 1; j < n; j++) {
      if (p[from + j] < p[from + i]) c++;
    }
    idx = idx * (n - i) + c;
  }
  return idx;
}

List<int> permDecode(int idx, int n) {
  final d = List.filled(n, 0);
  for (var i = n - 1; i >= 0; i--) {
    d[i] = idx % (n - i);
    idx ~/= (n - i);
  }
  final left = List.generate(n, (i) => i);
  return [for (var i = 0; i < n; i++) left.removeAt(d[i])];
}

const _p2moves = [0, 1, 2, 9, 10, 11, 4, 7, 13, 16]; // U U2 U' D D2 D' R2 F2 L2 B2

class TwoPhase {
  late final Int16List twistMove, flipMove, sliceMove;
  late final Uint16List cpMove, epMove;
  late final Uint8List spMove;
  late final Int8List p1a, p1b, p2a, p2b;
  final int solvedSlice = sliceOf(Cubie.solved());

  TwoPhase() {
    twistMove = Int16List(2187 * 18);
    for (var t = 0; t < 2187; t++) {
      final c = Cubie.solved();
      var x = t, s = 0;
      for (var i = 6; i >= 0; i--) {
        c.co[i] = x % 3;
        s += c.co[i];
        x ~/= 3;
      }
      c.co[7] = (3 - s % 3) % 3;
      for (var m = 0; m < 18; m++) {
        twistMove[t * 18 + m] = twistOf(c.mul(moveCubes[m]));
      }
    }
    flipMove = Int16List(2048 * 18);
    for (var t = 0; t < 2048; t++) {
      final c = Cubie.solved();
      var x = t, s = 0;
      for (var i = 10; i >= 0; i--) {
        c.eo[i] = x % 2;
        s += c.eo[i];
        x ~/= 2;
      }
      c.eo[11] = s % 2;
      for (var m = 0; m < 18; m++) {
        flipMove[t * 18 + m] = flipOf(c.mul(moveCubes[m]));
      }
    }
    sliceMove = Int16List(495 * 18);
    for (var a = 0; a < 12; a++) {
      for (var b = a + 1; b < 12; b++) {
        for (var cc = b + 1; cc < 12; cc++) {
          for (var d = cc + 1; d < 12; d++) {
            final c = Cubie.solved();
            var u = 0, sl = 8;
            for (var j = 0; j < 12; j++) {
              c.ep[j] = (j == a || j == b || j == cc || j == d) ? sl++ : u++;
            }
            final s = sliceOf(c);
            for (var m = 0; m < 18; m++) {
              sliceMove[s * 18 + m] = sliceOf(c.mul(moveCubes[m]));
            }
          }
        }
      }
    }
    cpMove = Uint16List(40320 * 18);
    for (var i = 0; i < 40320; i++) {
      final c = Cubie.solved();
      c.cp.setAll(0, permDecode(i, 8));
      for (var m = 0; m < 18; m++) {
        cpMove[i * 18 + m] = permIndex(c.mul(moveCubes[m]).cp, 0, 8);
      }
    }
    epMove = Uint16List(40320 * 10);
    for (var i = 0; i < 40320; i++) {
      final c = Cubie.solved();
      c.ep.setAll(0, permDecode(i, 8));
      for (var k = 0; k < 10; k++) {
        epMove[i * 10 + k] = permIndex(c.mul(moveCubes[_p2moves[k]]).ep, 0, 8);
      }
    }
    spMove = Uint8List(24 * 10);
    for (var i = 0; i < 24; i++) {
      final c = Cubie.solved();
      final p = permDecode(i, 4);
      for (var j = 0; j < 4; j++) {
        c.ep[8 + j] = 8 + p[j];
      }
      for (var k = 0; k < 10; k++) {
        final n = c.mul(moveCubes[_p2moves[k]]);
        spMove[i * 10 + k] = permIndex([for (var j = 8; j < 12; j++) n.ep[j] - 8], 0, 4);
      }
    }
    p1a = _bfs(2187, 495, solvedSlice, 18, (a, m) => twistMove[a * 18 + m],
        (b, m) => sliceMove[b * 18 + m]);
    p1b = _bfs(2048, 495, solvedSlice, 18, (a, m) => flipMove[a * 18 + m],
        (b, m) => sliceMove[b * 18 + m]);
    p2a = _bfs(40320, 24, 0, 10, (a, k) => cpMove[a * 18 + _p2moves[k]],
        (b, k) => spMove[b * 10 + k]);
    p2b = _bfs(40320, 24, 0, 10, (a, k) => epMove[a * 10 + k],
        (b, k) => spMove[b * 10 + k]);
  }

  static Int8List _bfs(int na, int nb, int b0, int nm, int Function(int, int) ma,
      int Function(int, int) mb) {
    final t = Int8List(na * nb)..fillRange(0, na * nb, -1);
    t[b0] = 0;
    var depth = 0, done = 1;
    while (done < na * nb) {
      var added = 0;
      for (var i = 0; i < na * nb; i++) {
        if (t[i] != depth) continue;
        final a = i ~/ nb, b = i % nb;
        for (var m = 0; m < nm; m++) {
          final j = ma(a, m) * nb + mb(b, m);
          if (t[j] < 0) {
            t[j] = depth + 1;
            added++;
          }
        }
      }
      if (added == 0) break;
      done += added;
      depth++;
    }
    return t;
  }

  final _sol = List.filled(40, 0);
  late Cubie _start;
  int _max = 21, _nodes = 0, _limit = 0, _len = -1;

  static bool _skip(int f, int lf) => f == lf || (f == (lf + 3) % 6 && f < lf);

  /// Moves solving [c] in at most [maxLen] turns, or null (also on node limit).
  List<int>? solve(Cubie c, {int maxLen = 21, int nodeLimit = 30000000}) {
    _start = c;
    _max = maxLen;
    _nodes = 0;
    _limit = nodeLimit;
    _len = -1;
    final tw = twistOf(c), fl = flipOf(c), sl = sliceOf(c);
    for (var d = 0; d <= maxLen; d++) {
      if (_p1(tw, fl, sl, 0, d)) return _sol.sublist(0, _len);
      if (_nodes > _limit) return null;
    }
    return null;
  }

  bool _p1(int tw, int fl, int sl, int depth, int togo) {
    if (togo == 0) {
      if (tw != 0 || fl != 0 || sl != solvedSlice) return false;
      if (depth > 0) {
        final lm = _sol[depth - 1];
        final f = lm ~/ 3;
        // A phase-2 move last means a shorter phase 1 was already tried.
        if (f == 0 || f == 3 || lm % 3 == 1) return false;
      }
      return _p2start(depth);
    }
    for (var m = 0; m < 18; m++) {
      final f = m ~/ 3;
      if (depth > 0 && _skip(f, _sol[depth - 1] ~/ 3)) continue;
      final ntw = twistMove[tw * 18 + m], nfl = flipMove[fl * 18 + m];
      final nsl = sliceMove[sl * 18 + m];
      final h1 = p1a[ntw * 495 + nsl], h2 = p1b[nfl * 495 + nsl];
      if ((h1 > h2 ? h1 : h2) > togo - 1) continue;
      if (++_nodes > _limit) return false;
      _sol[depth] = m;
      if (_p1(ntw, nfl, nsl, depth + 1, togo - 1)) return true;
    }
    return false;
  }

  bool _p2start(int d1) {
    final c = _start.apply(_sol.sublist(0, d1));
    final cp = permIndex(c.cp, 0, 8), ep = permIndex(c.ep, 0, 8);
    final sp = permIndex([for (var j = 8; j < 12; j++) c.ep[j] - 8], 0, 4);
    final h1 = p2a[cp * 24 + sp], h2 = p2b[ep * 24 + sp];
    final h = h1 > h2 ? h1 : h2;
    for (var d2 = h; d1 + d2 <= _max; d2++) {
      if (_p2(cp, ep, sp, d1, d1, d2)) return true;
    }
    return false;
  }

  bool _p2(int cp, int ep, int sp, int d1, int depth, int togo) {
    if (togo == 0) {
      if (cp == 0 && ep == 0 && sp == 0) {
        _len = depth;
        return true;
      }
      return false;
    }
    for (var k = 0; k < 10; k++) {
      final m = _p2moves[k];
      if (depth > 0 && _skip(m ~/ 3, _sol[depth - 1] ~/ 3)) continue;
      final ncp = cpMove[cp * 18 + m], nep = epMove[ep * 10 + k];
      final nsp = spMove[sp * 10 + k];
      final h1 = p2a[ncp * 24 + nsp], h2 = p2b[nep * 24 + nsp];
      if ((h1 > h2 ? h1 : h2) > togo - 1) continue;
      if (++_nodes > _limit) return false;
      _sol[depth] = m;
      if (_p2(ncp, nep, nsp, d1, depth + 1, togo - 1)) return true;
    }
    return false;
  }
}
