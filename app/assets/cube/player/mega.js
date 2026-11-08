/* Küp oynatıcı · Megaminx model. A dodecahedron with inradius 1; each face carries 11 stickers
   (centre, 5 edges, 5 corners). A face turn rotates every sticker whose centre lies beyond that
   face's cut plane (the face's own 11 plus 3 on each neighbour) by 72° steps about the face normal.
   Held as the notebook holds it: U on top, F at the front, R to its right, then BR, BL, L around U;
   DR is the lower face between F and R. */
var KupMega = (function () {
  'use strict';
  var TAU = Math.PI * 2, POLAR = Math.atan(2);

  function v(x, y, z) { return [x, y, z]; }
  function add(a, b) { return [a[0] + b[0], a[1] + b[1], a[2] + b[2]]; }
  function sub(a, b) { return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]; }
  function mul(a, k) { return [a[0] * k, a[1] * k, a[2] * k]; }
  function dot(a, b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
  function cross(a, b) { return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]; }
  function norm(a) { return mul(a, 1 / Math.sqrt(dot(a, a))); }
  // Rodrigues rotation of p about unit axis k by angle t.
  function rotate(p, k, t) {
    var c = Math.cos(t), s = Math.sin(t);
    return add(add(mul(p, c), mul(cross(k, p), s)), mul(k, dot(k, p) * (1 - c)));
  }

  // Face normals: azimuth 0 = front (+z), growing toward +x (right).
  function dir(polar, az) {
    return v(Math.sin(polar) * Math.sin(az), Math.cos(polar), Math.sin(polar) * Math.cos(az));
  }
  var D36 = TAU / 10;
  var FACES = {
    U: v(0, 1, 0), D: v(0, -1, 0),
    F: dir(POLAR, 0), R: dir(POLAR, 2 * D36), BR: dir(POLAR, 4 * D36), BL: dir(POLAR, 6 * D36), L: dir(POLAR, 8 * D36),
    DR: dir(Math.PI - POLAR, D36), DBR: dir(Math.PI - POLAR, 3 * D36), B: dir(Math.PI - POLAR, 5 * D36),
    DBL: dir(Math.PI - POLAR, 7 * D36), DL: dir(Math.PI - POLAR, 9 * D36)
  };
  var NAMES = Object.keys(FACES);
  // The notebook's colours for U and the ring around it; the rest follow the usual scheme.
  var COLORS = {
    U: '#9AA3AE', F: '#C8102E', R: '#00A05A', BR: '#7B3FA0', BL: '#F2C200', L: '#0046AD',
    D: '#F4F4F4', DR: '#FF6A13', DBR: '#F06EAA', B: '#9BE15D', DBL: '#5BC0EB', DL: '#E6D3A3'
  };

  var CUT = 0.36; // cut lines sit this fraction of the apothem in from each edge

  // Geometry of one face: vertices in order, then the 11 sticker polygons.
  function faceStickers(name) {
    var n = FACES[name];
    var nbrs = NAMES.filter(function (o) { return o !== name && Math.abs(dot(FACES[o], n) - 1 / Math.sqrt(5)) < 1e-6; });
    // Order neighbours around n.
    var e1 = norm(cross(Math.abs(n[1]) > 0.9 ? v(0, 0, 1) : v(0, 1, 0), n)), e2 = cross(n, e1);
    nbrs.sort(function (a, b) {
      var pa = FACES[a], pb = FACES[b];
      return Math.atan2(dot(pa, e2), dot(pa, e1)) - Math.atan2(dot(pb, e2), dot(pb, e1));
    });
    // Vertex between neighbours i and i+1: on all three planes (n·p = 1).
    function solve(a, b, c) {
      var det = dot(a, cross(b, c));
      return mul(add(add(cross(b, c), cross(c, a)), cross(a, b)), 1 / det);
    }
    var V = [];
    for (var i = 0; i < 5; i++) V.push(solve(n, FACES[nbrs[i]], FACES[nbrs[(i + 1) % 5]]));
    // Edge i runs V[i] → V[i+1] and borders nbrs[i+1].
    var apo = dot(sub(mul(add(V[0], V[1]), 0.5), n), sub(mul(add(V[0], V[1]), 0.5), n));
    apo = Math.sqrt(apo);
    var d = CUT * apo;
    var lines = [];
    for (var j = 0; j < 5; j++) {
      var mid = mul(add(V[j], V[(j + 1) % 5]), 0.5), inward = norm(sub(n, mid));
      lines.push({ p: add(mid, mul(inward, d)), dir: norm(sub(V[(j + 1) % 5], V[j])) });
    }
    // Intersection of two lines in the face plane.
    function meet(l1, l2) {
      var w = sub(l2.p, l1.p), c = cross(l1.dir, l2.dir), cc = dot(c, c);
      var t = dot(cross(w, l2.dir), c) / cc;
      return add(l1.p, mul(l1.dir, t));
    }
    function edgeLine(k) { return { p: V[k], dir: norm(sub(V[(k + 1) % 5], V[k])) }; }
    var Q = [], A = [], B = [];
    for (var k = 0; k < 5; k++) {
      Q.push(meet(lines[(k + 4) % 5], lines[k]));       // inner vertex near V[k]
      A.push(meet(edgeLine(k), lines[(k + 4) % 5]));    // on edge k, near V[k]
      B.push(meet(edgeLine(k), lines[(k + 1) % 5]));    // on edge k, near V[k+1]
    }
    var out = [{ face: name, poly: Q.slice(), kind: 'center' }];
    for (var m = 0; m < 5; m++) {
      out.push({ face: name, poly: [V[m], A[m], Q[m], B[(m + 4) % 5]], kind: 'corner' });
      out.push({ face: name, poly: [A[m], B[m], Q[(m + 1) % 5], Q[m]], kind: 'edge' });
    }
    out.forEach(function (s) {
      var c = [0, 0, 0];
      s.poly.forEach(function (p) { c = add(c, p); });
      s.home = mul(c, 1 / s.poly.length);
      s.normal = n;
    });
    return out;
  }

  // Height of every cut plane along its normal (the same for all faces by symmetry).
  // U's cut meets F along the line through F's two inner-pentagon vertices nearest U.
  var CUT_H = (function () {
    var u = FACES.U;
    var inner = faceStickers('F')[0].poly.map(function (p) { return dot(u, p); }).sort(function (a, b) { return b - a; });
    return inner[0] - 1e-6;
  })();

  function Mega() { this.reset(); }
  Mega.prototype.reset = function () {
    var list = [];
    NAMES.forEach(function (f) {
      faceStickers(f).forEach(function (s) {
        list.push({ face: s.face, kind: s.kind, poly: s.poly, home: s.home, homeNormal: s.normal, pos: s.home, q: [0, 0, 0, 1] });
      });
    });
    this.stickers = list;
    this.cubies = list; // the player animates whatever `select` returns
  };
  Mega.prototype.select = function (move) {
    var k = move.axisVec;
    return this.stickers.filter(function (s) { return dot(k, s.pos) > CUT_H; });
  };
  // Quaternion helpers (x, y, z, w).
  function qAxis(k, t) { var s = Math.sin(t / 2); return [k[0] * s, k[1] * s, k[2] * s, Math.cos(t / 2)]; }
  function qMul(a, b) {
    return [a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
      a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
      a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
      a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2]];
  }
  Mega.prototype.apply = function (move) {
    var sel = this.select(move), r = qAxis(move.axisVec, move.angle);
    for (var i = 0; i < sel.length; i++) {
      var s = sel[i];
      s.pos = rotate(s.pos, move.axisVec, move.angle);
      s.q = qMul(r, s.q);
    }
  };
  Mega.prototype.normalOf = function (s) {
    // Sticker normal after the turns it went through.
    var q = s.q, p = s.homeNormal;
    var u = [q[0], q[1], q[2]], w = q[3];
    var t = mul(cross(u, p), 2);
    return add(add(p, mul(t, w)), cross(u, t));
  };

  // Notation: U R F L BR BL DR DL DBR DBL B D, with 2 (144°) and '.
  function parseToken(tok) {
    var t = tok.replace(/[’′`]/g, "'");
    var m = /^(DBR|DBL|BR|BL|DR|DL|U|R|F|L|D|B)(2?)('?)(2?)$/.exec(t);
    if (!m) return null;
    var k = (m[2] || m[4]) ? 2 : 1, prime = m[3] === "'";
    return { axisVec: FACES[m[1]], angle: -k * (prime ? -1 : 1) * TAU / 5, text: t, face: m[1] };
  }
  function parse(text) {
    var clean = text.replace(/[()\[\]]/g, ' ').trim();
    if (!clean) return null;
    var toks = clean.split(/\s+/), out = [];
    for (var i = 0; i < toks.length; i++) {
      var mv = parseToken(toks[i]);
      if (!mv) return null;
      out.push(mv);
    }
    return out;
  }
  function inverse(mv) { return { axisVec: mv.axisVec, angle: -mv.angle, text: mv.text, face: mv.face }; }

  return { Mega: Mega, parse: parse, inverse: inverse, FACES: FACES, COLORS: COLORS, CUT_H: CUT_H, dot: dot };
})();
if (typeof module !== 'undefined') module.exports = KupMega;
