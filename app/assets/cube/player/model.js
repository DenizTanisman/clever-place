/* Küp oynatıcı · model. NxN cube as cubies with integer positions and orientation matrices.
   Coordinates are doubled so every layer sits on an integer: -(n-1) … n-1 in steps of 2.
   x → right (R), y → up (U), z → toward the viewer (F). A quarter turn qt=+1 is +90° about the
   axis (right-hand rule), so R, U, F are qt=-1 on their axis. */
var KupModel = (function () {
  'use strict';

  // +90° about each axis.
  function rot1(axis, v) {
    var x = v[0], y = v[1], z = v[2];
    if (axis === 0) return [x, -z, y];
    if (axis === 1) return [z, y, -x];
    return [-y, x, z];
  }
  function rot(axis, qt, v) {
    var k = ((qt % 4) + 4) % 4;
    for (var i = 0; i < k; i++) v = rot1(axis, v);
    return v;
  }

  // Face colours as the notebook holds the cube: yellow up, red front.
  var COLORS = {
    U: '#FFD500', D: '#F4F4F4', F: '#C8102E', B: '#FF6A13', R: '#00A05A', L: '#0046AD'
  };
  var FACE_OF = { '0,1': 'R', '0,-1': 'L', '1,1': 'U', '1,-1': 'D', '2,1': 'F', '2,-1': 'B' };

  function Cube(n) {
    this.n = n;
    this.reset();
  }
  Cube.prototype.reset = function () {
    var n = this.n, m = n - 1, list = [];
    for (var x = -m; x <= m; x += 2)
      for (var y = -m; y <= m; y += 2)
        for (var z = -m; z <= m; z += 2) {
          if (Math.abs(x) !== m && Math.abs(y) !== m && Math.abs(z) !== m) continue;
          var home = [x, y, z], stickers = [];
          for (var a = 0; a < 3; a++) {
            if (home[a] === m || home[a] === -m) {
              var s = home[a] === m ? 1 : -1, nrm = [0, 0, 0];
              nrm[a] = s;
              stickers.push({ normal: nrm, face: FACE_OF[a + ',' + s] });
            }
          }
          // Orientation as the images of the three unit axes (columns).
          list.push({ home: home, pos: home.slice(), axes: [[1, 0, 0], [0, 1, 0], [0, 0, 1]], stickers: stickers });
        }
    this.cubies = list;
  };
  // Layer index 0 … n-1 along an axis.
  Cube.prototype.layerOf = function (c, axis) { return (c.pos[axis] + this.n - 1) / 2; };
  Cube.prototype.select = function (move) {
    var self = this;
    return this.cubies.filter(function (c) { return move.layers.indexOf(self.layerOf(c, move.axis)) >= 0; });
  };
  Cube.prototype.apply = function (move) {
    var sel = this.select(move);
    for (var i = 0; i < sel.length; i++) {
      var c = sel[i];
      c.pos = rot(move.axis, move.qt, c.pos);
      c.axes = c.axes.map(function (v) { return rot(move.axis, move.qt, v); });
    }
  };
  // Current outward normal of a sticker (home normal pushed through the orientation).
  Cube.prototype.normalOf = function (c, s) {
    var a = s.normal, r = [0, 0, 0];
    for (var i = 0; i < 3; i++) for (var k = 0; k < 3; k++) r[k] += a[i] * c.axes[i][k];
    return r;
  };
  // Colour letter seen at a position from a direction; used by the tests.
  Cube.prototype.facelets = function () {
    var out = [];
    for (var i = 0; i < this.cubies.length; i++) {
      var c = this.cubies[i];
      for (var j = 0; j < c.stickers.length; j++)
        out.push({ pos: c.pos, normal: this.normalOf(c, c.stickers[j]), face: c.stickers[j].face });
    }
    return out;
  };

  /* Notation. Face turns with optional width (Rw, 3Rw, r), single inner slices (2R), slices
     (M E S), rotations (x y z); suffixes 2, ', 2'. On a 2x2 a lowercase turn moves the same corners
     as the face turn, so r is R there. On a 3x3 it is the outer two layers. On a 4x4 it is the inner
     slice (r2 U2 r2 Uw2 r2 Uw2, the PLL parity alg; read as two layers it would break the middle). */
  var FACES = { R: [0, 1, -1], L: [0, -1, 1], U: [1, 1, -1], D: [1, -1, 1], F: [2, 1, -1], B: [2, -1, 1] };
  var SLICES = { M: 'L', E: 'D', S: 'F' }, ROTS = { x: 'R', y: 'U', z: 'F' };

  function range(a, b) { var r = []; for (var i = a; i <= b; i++) r.push(i); return r; }
  // Layer indices for `count` layers starting `skip` in from the face side.
  function faceLayers(n, side, skip, count) {
    return range(skip, skip + count - 1).map(function (k) { return side > 0 ? n - 1 - k : k; });
  }

  function parseToken(tok, n) {
    var t = tok.replace(/[’′`]/g, "'");
    var m = /^(\d*)([URFDLBurfdlbMESxyz])(w?)(\d*)('?)(\d*)$/.exec(t);
    if (!m) return null;
    var pre = m[1] ? +m[1] : 0, letter = m[2], wide = m[3] === 'w';
    var amount = +(m[4] || m[6] || 1), prime = m[5] === "'";
    if (amount !== 1 && amount !== 2) return null;
    var mv;
    if (ROTS[letter]) {
      var f = FACES[ROTS[letter]];
      mv = { axis: f[0], layers: range(0, n - 1), qt: f[2] };
    } else if (SLICES[letter]) {
      if (n % 2 === 0) return null;
      var g = FACES[SLICES[letter]];
      mv = { axis: g[0], layers: [(n - 1) / 2], qt: g[2] };
    } else {
      var upper = letter.toUpperCase(), lower = letter !== upper, h = FACES[upper];
      if (!h) return null;
      var layers;
      if (lower) {
        if (wide || pre) return null;
        if (n === 2) layers = faceLayers(n, h[1], 0, 1);
        else if (n === 3) layers = faceLayers(n, h[1], 0, 2);
        else layers = faceLayers(n, h[1], 1, 1);
      } else if (wide) {
        var w = pre || 2;
        if (w > n) return null;
        layers = faceLayers(n, h[1], 0, w);
      } else if (pre) {
        if (pre > n) return null;
        layers = faceLayers(n, h[1], pre - 1, 1);
      } else layers = faceLayers(n, h[1], 0, 1);
      mv = { axis: h[0], layers: layers, qt: h[2] };
    }
    mv.qt *= amount * (prime ? -1 : 1);
    mv.text = t;
    // What the player animates: turn `angle` radians about `axisVec` (shared with the Megaminx).
    mv.axisVec = [mv.axis === 0 ? 1 : 0, mv.axis === 1 ? 1 : 0, mv.axis === 2 ? 1 : 0];
    mv.angle = mv.qt * Math.PI / 2;
    return mv;
  }

  // Whole algorithm, or null if any token is not a cube move (prose rows, Megaminx).
  function parse(text, n) {
    var clean = text.replace(/[()\[\]]/g, ' ').trim();
    if (!clean) return null;
    var toks = clean.split(/\s+/), out = [];
    for (var i = 0; i < toks.length; i++) {
      var mv = parseToken(toks[i], n);
      if (!mv) return null;
      out.push(mv);
    }
    return out;
  }

  function inverse(mv) {
    return { axis: mv.axis, layers: mv.layers, qt: -mv.qt, text: mv.text, axisVec: mv.axisVec, angle: -mv.angle };
  }

  return { Cube: Cube, parse: parse, inverse: inverse, COLORS: COLORS, rot: rot };
})();
if (typeof module !== 'undefined') module.exports = KupModel;
