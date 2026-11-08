/* Küp oynatıcı in the app: the web notebook's player (oynatici/ui.js) without the network. three.js,
   model.js and mega.js load from this folder; what to play comes from the app, which calls
   KupApp.open(entry) once the page has loaded. `entry` is a row of player_index.json
   plus the row's label and the saved speed:
     {p: 3 | 4 | 2 | 'mega', segs: [[name, moves], …], demo?, before?, label?, speed?}
   A normal row starts from the case it solves (its inverse applied to a solved puzzle) and turns to
   solved; a Gösteri row (demo) starts where the rows above it (`before`) left a solved cube.
   The app hears speed changes on the KupHost channel ("speed:<x>"). For a look in a browser:
   index.html#<the entry as URL-encoded JSON>. */
var KupApp = (function () {
  'use strict';
  var SPEEDS = [0.25, 0.5, 1, 2], QUARTER_MS = 560;
  function icon(d) {
    return '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="' + d + '" fill="currentColor"/></svg>';
  }
  var ICON = {
    play: icon('M4 2.5v11l9-5.5z'),
    pause: icon('M4 2.5h3v11H4zM9 2.5h3v11H9z'),
    next: icon('M3 3v10l7-5zM11 3h2v10h-2z'),
    prev: icon('M13 3v10L6 8zM3 3h2v10H3z'),
    first: icon('M2 3h2v10H2zM9 3v10L4 8zM15 3v10l-5-5z'),
    last: icon('M12 3h2v10h-2zM7 3v10l5-5zM1 3v10l5-5z')
  };

  function api(p) {
    return p === 'mega'
      ? { parse: function (t) { return KupMega.parse(t); }, inverse: KupMega.inverse, make: function () { return new KupMega.Mega(); } }
      : { parse: function (t) { return KupModel.parse(t, p); }, inverse: KupModel.inverse, make: function () { return new KupModel.Cube(p); } };
  }
  function tell(msg) {
    try { if (window.KupHost) window.KupHost.postMessage(msg); } catch (e) {}
  }

  var P = null; // the open player

  function open(entry) {
    close();
    var p = entry.p, a = api(p);
    var moves = [], bounds = [];
    (entry.segs || []).forEach(function (g) {
      var m = a.parse(g[1]) || [];
      bounds.push({ name: g[0], from: moves.length, to: moves.length + m.length });
      moves = moves.concat(m);
    });
    var speed = SPEEDS.indexOf(+entry.speed) >= 0 ? +entry.speed : 1;
    P = {
      puzzle: p, api: a, moves: moves, segs: bounds, before: entry.before ? (a.parse(entry.before) || []) : [],
      demo: !!entry.demo, i: 0, playing: false, anim: null, wait: null, speed: speed, cube: a.make()
    };
    build(entry.label || '');
    setupState(0);
    if (window.THREE) initScene();
    else P.msg.textContent = '3D çizim açılamadı. Hamleleri yine de adım adım izleyebilirsin.';
  }

  function build(label) {
    var root = document.getElementById('app');
    root.innerHTML =
      '<div class="kp-page">' +
        '<p class="kp-sub"></p>' +
        '<div class="kp-stage"><div class="kp-msg">3D model hazırlanıyor…</div></div>' +
        '<div class="kp-moves" role="group" aria-label="Hamleler"></div>' +
        '<div class="kp-bar"><div class="kp-ctrl">' +
          '<button type="button" class="kp-btn" data-act="first" aria-label="Başa dön">' + ICON.first + '</button>' +
          '<button type="button" class="kp-btn" data-act="prev" aria-label="Bir hamle geri">' + ICON.prev + '</button>' +
          '<button type="button" class="kp-btn main" data-act="play" aria-label="Oynat">' + ICON.play + '</button>' +
          '<button type="button" class="kp-btn" data-act="next" aria-label="Bir hamle ileri">' + ICON.next + '</button>' +
          '<button type="button" class="kp-btn" data-act="last" aria-label="Sona git">' + ICON.last + '</button>' +
        '</div><div class="kp-speed" role="group" aria-label="Hız"></div></div>' +
        '<div class="kp-foot"><span class="kp-count"></span><span>Sürükle: çevir · çift dokun: düzelt</span></div>' +
      '</div>';
    P.root = root;
    P.stage = root.querySelector('.kp-stage');
    P.msg = root.querySelector('.kp-msg');
    var kind = P.puzzle === 'mega' ? 'Megaminx' : P.puzzle + 'x' + P.puzzle;
    var sub = root.querySelector('.kp-sub');
    if (label) { var b = document.createElement('b'); b.textContent = label; sub.appendChild(b); sub.appendChild(document.createTextNode(' · ')); }
    sub.appendChild(document.createTextNode([kind,
      P.demo ? (P.before.length ? 'önceki satırların bıraktığı yerden' : 'çözülmüş küpten') : 'vakadan başlar, çözülmüş hâle gider'
    ].join(' · ')));

    var mv = root.querySelector('.kp-moves');
    var start = document.createElement('button');
    start.type = 'button'; start.className = 'kp-chip start'; start.textContent = 'baş';
    start.setAttribute('aria-label', 'Başlangıç');
    start.dataset.k = '0';
    mv.appendChild(start);
    P.segs.forEach(function (g) {
      var box = mv;
      if (g.name) {
        box = document.createElement('span');
        box.className = 'kp-seg' + (g.name === 'hizala' ? ' kp-align' : '');
        var n = document.createElement('span');
        n.className = 'kp-seg-name';
        n.textContent = g.name;
        box.appendChild(n);
        mv.appendChild(box);
      }
      for (var k = g.from; k < g.to; k++) {
        var c = document.createElement('button');
        c.type = 'button'; c.className = 'kp-chip'; c.textContent = P.moves[k].text; c.dataset.k = String(k + 1);
        c.setAttribute('aria-label', (k + 1) + '. hamle ' + P.moves[k].text + (g.name ? ' (' + g.name + ')' : ''));
        box.appendChild(c);
      }
    });
    P.chips = mv.querySelectorAll('.kp-chip');
    mv.addEventListener('click', function (e) {
      var c = e.target.closest('.kp-chip');
      if (c) { pause(); jump(+c.dataset.k); }
    });

    var sp = root.querySelector('.kp-speed');
    SPEEDS.forEach(function (v) {
      var b = document.createElement('button');
      b.type = 'button';
      b.textContent = (v === 0.25 ? '¼' : v === 0.5 ? '½' : String(v)) + '×';
      b.setAttribute('aria-label', 'Hız ' + v + ' kat');
      b.setAttribute('aria-pressed', String(v === P.speed));
      b.addEventListener('click', function () {
        P.speed = v;
        tell('speed:' + v);
        sp.querySelectorAll('button').forEach(function (x) { x.setAttribute('aria-pressed', String(x === b)); });
      });
      sp.appendChild(b);
    });

    root.querySelector('.kp-ctrl').addEventListener('click', function (e) {
      var b = e.target.closest('.kp-btn');
      if (!b || b.disabled) return;
      var a = b.dataset.act;
      if (a === 'play') togglePlay();
      else { pause(); if (a === 'first') jump(0); else if (a === 'last') jump(P.moves.length); else step(a === 'next' ? 1 : -1); }
    });
    refresh();
  }

  function close() {
    if (!P) return;
    var p = P;
    P = null;
    clearTimeout(p.wait);
    if (p.raf) cancelAnimationFrame(p.raf);
    if (p.renderer) { p.renderer.dispose(); if (p.renderer.forceContextLoss) p.renderer.forceContextLoss(); }
    if (p.onResize) window.removeEventListener('resize', p.onResize);
    p.root.innerHTML = '';
  }

  // ---- state ---------------------------------------------------------------------------------
  // Puzzle after `k` moves of the algorithm, set without animation.
  function setupState(k) {
    var c = P.cube, inv = P.api.inverse;
    c.reset();
    if (P.meshes) P.meshes.forEach(function (g, i) { g.userData.cubie = c.cubies[i]; });
    P.before.forEach(function (m) { c.apply(m); });
    if (!P.demo) for (var j = P.moves.length - 1; j >= 0; j--) c.apply(inv(P.moves[j]));
    for (var i = 0; i < k; i++) c.apply(P.moves[i]);
    P.i = k;
  }
  function finishAnim() {
    var a = P && P.anim;
    if (!a) return;
    P.anim = null;
    endTurn(a);
  }
  function jump(k) {
    finishAnim();
    setupState(Math.max(0, Math.min(P.moves.length, k)));
    syncAll();
    refresh();
  }
  function step(dir) {
    finishAnim();
    if (dir > 0 && P.i < P.moves.length) { turn(P.moves[P.i]); P.i++; }
    else if (dir < 0 && P.i > 0) { P.i--; turn(P.api.inverse(P.moves[P.i])); }
    refresh();
  }
  function togglePlay() { if (P.playing) pause(); else play(); }
  function play() {
    if (P.i >= P.moves.length) jump(0);
    P.playing = true;
    refresh();
    if (!P.anim) advance();
  }
  function pause() {
    if (!P) return;
    P.playing = false;
    clearTimeout(P.wait);
    refresh();
  }
  function advance() {
    if (!P || !P.playing) return;
    if (P.i >= P.moves.length) { P.playing = false; refresh(); return; }
    step(1);
    if (!P.scene) { P.wait = setTimeout(advance, 300 / P.speed); } // no 3D: still walk the list
  }

  function refresh() {
    if (!P) return;
    var i = P.i, n = P.moves.length, root = P.root;
    P.chips.forEach(function (c) {
      var k = +c.dataset.k;
      c.classList.toggle('now', k === i);
      c.classList.toggle('done', k < i);
    });
    var now = P.chips[i];
    if (now && now.scrollIntoView) now.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    var playBtn = root.querySelector('[data-act="play"]');
    playBtn.innerHTML = P.playing ? ICON.pause : ICON.play;
    playBtn.setAttribute('aria-label', P.playing ? 'Duraklat' : (i >= n ? 'Baştan oynat' : 'Oynat'));
    root.querySelector('[data-act="first"]').disabled = i === 0;
    root.querySelector('[data-act="prev"]').disabled = i === 0;
    root.querySelector('[data-act="next"]').disabled = i >= n;
    root.querySelector('[data-act="last"]').disabled = i >= n;
    root.querySelector('.kp-count').textContent = i + ' / ' + n + ' hamle' +
      (i >= n ? (P.demo ? '' : ' · çözüldü') : '');
  }

  // ---- 3D ------------------------------------------------------------------------------------
  function initScene() {
    var T = window.THREE, mega = P.puzzle === 'mega';
    var renderer;
    try {
      renderer = new T.WebGLRenderer({ antialias: true, alpha: true });
    } catch (e) {
      P.msg.textContent = '3D çizim açılamadı. Hamleleri yine de adım adım izleyebilirsin.';
      return;
    }
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    P.renderer = renderer;
    P.msg.remove();
    P.stage.appendChild(renderer.domElement);

    var scene = new T.Scene();
    var camera = new T.PerspectiveCamera(30, 1, 0.1, 100);
    var size = mega ? 1.75 : P.puzzle;
    camera.position.copy(new T.Vector3(1, mega ? 1.5 : 0.95, mega ? 1.7 : 1.35).normalize().multiplyScalar(size * 3.55));
    camera.lookAt(0, 0, 0);
    scene.add(new T.AmbientLight(0xffffff, 0.72));
    var light = new T.DirectionalLight(0xffffff, 0.5);
    light.position.set(3, 6, 5);
    scene.add(light);
    var root = new T.Group();
    scene.add(root);
    P.T = T; P.scene = scene; P.camera = camera; P.root3 = root;
    P.meshes = mega ? buildMega(T, root) : buildCube(T, root);

    // Drag to turn the view; a double tap puts it back.
    var view = { yaw: 0, pitch: 0 }, drag = null;
    P.view = view;
    P.stage.addEventListener('pointerdown', function (e) {
      drag = { x: e.clientX, y: e.clientY, yaw: view.yaw, pitch: view.pitch };
      P.stage.setPointerCapture(e.pointerId);
    });
    P.stage.addEventListener('pointermove', function (e) {
      if (!drag) return;
      view.yaw = drag.yaw + (e.clientX - drag.x) * 0.01;
      view.pitch = Math.max(-1.2, Math.min(1.2, drag.pitch + (e.clientY - drag.y) * 0.01));
      kick();
    });
    var endDrag = function () { drag = null; };
    P.stage.addEventListener('pointerup', endDrag);
    P.stage.addEventListener('pointercancel', endDrag);
    P.stage.addEventListener('dblclick', function () { view.yaw = 0; view.pitch = 0; kick(); });

    P.onResize = function () { resize(); kick(); };
    window.addEventListener('resize', P.onResize);
    resize();
    syncAll();
    kick();
    if (P.playing && !P.anim) advance();
  }

  function buildCube(T, root) {
    var s = 0.42, r = 0.1, shape = new T.Shape();
    shape.moveTo(-s + r, -s); shape.lineTo(s - r, -s); shape.quadraticCurveTo(s, -s, s, -s + r);
    shape.lineTo(s, s - r); shape.quadraticCurveTo(s, s, s - r, s); shape.lineTo(-s + r, s);
    shape.quadraticCurveTo(-s, s, -s, s - r); shape.lineTo(-s, -s + r); shape.quadraticCurveTo(-s, -s, -s + r, -s);
    var stickerGeo = new T.ShapeGeometry(shape);
    var bodyGeo = new T.BoxGeometry(0.97, 0.97, 0.97);
    var bodyMat = new T.MeshLambertMaterial({ color: 0x16181f });
    var mats = {};
    Object.keys(KupModel.COLORS).forEach(function (f) {
      mats[f] = new T.MeshLambertMaterial({ color: new T.Color(KupModel.COLORS[f]), side: T.DoubleSide });
    });
    return P.cube.cubies.map(function (c) {
      var g = new T.Group();
      g.add(new T.Mesh(bodyGeo, bodyMat));
      c.stickers.forEach(function (st) {
        var m = new T.Mesh(stickerGeo, mats[st.face]);
        var nv = new T.Vector3(st.normal[0], st.normal[1], st.normal[2]);
        m.position.copy(nv.clone().multiplyScalar(0.487));
        m.quaternion.setFromUnitVectors(new T.Vector3(0, 0, 1), nv);
        g.add(m);
      });
      g.userData.cubie = c;
      root.add(g);
      return g;
    });
  }

  // Each Megaminx sticker is a dark plate (the exact cell) and a smaller coloured face on it. A dark
  // core below every cut fills the gap a turning layer opens.
  function buildMega(T, root) {
    function polyGeo(pts, shrink, lift, nrm) {
      var c = [0, 0, 0];
      pts.forEach(function (p) { c[0] += p[0]; c[1] += p[1]; c[2] += p[2]; });
      c = c.map(function (x) { return x / pts.length; });
      var q = pts.map(function (p) {
        return [0, 1, 2].map(function (i) { return c[i] + (p[i] - c[i]) * shrink + nrm[i] * lift; });
      });
      var pos = [];
      for (var i = 1; i + 1 < q.length; i++) pos.push.apply(pos, q[0].concat(q[i], q[i + 1]));
      var g = new T.BufferGeometry();
      g.setAttribute('position', new T.Float32BufferAttribute(pos, 3));
      g.computeVertexNormals();
      return g;
    }
    root.add(new T.Mesh(new T.SphereGeometry(KupMega.CUT_H * 0.98, 32, 24), new T.MeshLambertMaterial({ color: 0x16181f })));
    var plateMat = new T.MeshLambertMaterial({ color: 0x16181f, side: T.DoubleSide });
    var mats = {};
    Object.keys(KupMega.COLORS).forEach(function (f) {
      mats[f] = new T.MeshLambertMaterial({ color: new T.Color(KupMega.COLORS[f]), side: T.DoubleSide });
    });
    return P.cube.cubies.map(function (s) {
      var g = new T.Group();
      g.add(new T.Mesh(polyGeo(s.poly, 1, 0, s.homeNormal), plateMat));
      g.add(new T.Mesh(polyGeo(s.poly, s.kind === 'center' ? 0.9 : 0.86, 0.006, s.homeNormal), mats[s.face]));
      g.userData.cubie = s;
      root.add(g);
      return g;
    });
  }

  function resize() {
    var w = P.stage.clientWidth, h = P.stage.clientHeight || w;
    P.renderer.setSize(w, h, false);
    P.camera.aspect = w / h;
    P.camera.updateProjectionMatrix();
  }

  function syncMesh(g) {
    var c = g.userData.cubie, T = P.T;
    if (P.puzzle === 'mega') {
      g.position.set(0, 0, 0);
      g.quaternion.set(c.q[0], c.q[1], c.q[2], c.q[3]);
      return;
    }
    var a = c.axes;
    g.position.set(c.pos[0] / 2, c.pos[1] / 2, c.pos[2] / 2);
    var m = new T.Matrix4().makeBasis(
      new T.Vector3(a[0][0], a[0][1], a[0][2]), new T.Vector3(a[1][0], a[1][1], a[1][2]), new T.Vector3(a[2][0], a[2][1], a[2][2]));
    g.quaternion.setFromRotationMatrix(m);
  }
  function syncAll() {
    if (!P || !P.meshes) return;
    P.meshes.forEach(syncMesh);
    kick();
  }

  // Animate one move; the model changes when the turn ends.
  function turn(move) {
    if (!P.scene) { P.cube.apply(move); return; }
    var T = P.T, pivot = new T.Group();
    P.root3.add(pivot);
    var picked = P.cube.select(move);
    var group = P.meshes.filter(function (g) { return picked.indexOf(g.userData.cubie) >= 0; });
    group.forEach(function (g) { pivot.add(g); });
    var quarters = Math.abs(move.angle) / (P.puzzle === 'mega' ? Math.PI * 2 / 5 : Math.PI / 2);
    var dur = QUARTER_MS * (quarters > 1.5 ? 1.5 : 1) / P.speed;
    P.anim = { move: move, pivot: pivot, group: group, start: performance.now(), dur: dur,
      axis: new T.Vector3(move.axisVec[0], move.axisVec[1], move.axisVec[2]) };
    kick();
  }
  function endTurn(a) {
    P.cube.apply(a.move);
    a.group.forEach(function (g) { P.root3.add(g); syncMesh(g); });
    P.root3.remove(a.pivot);
    kick();
  }

  function kick() {
    if (P && P.scene && !P.raf) P.raf = requestAnimationFrame(frame);
  }
  function frame(now) {
    if (!P) return;
    P.raf = 0;
    var a = P.anim;
    if (a) {
      var t = Math.min(1, (now - a.start) / a.dur);
      var e = t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
      a.pivot.quaternion.setFromAxisAngle(a.axis, e * a.move.angle);
      if (t >= 1) {
        P.anim = null;
        endTurn(a);
        if (P.playing) P.wait = setTimeout(advance, 140 / P.speed);
      }
    }
    P.root3.rotation.set(P.view.pitch, P.view.yaw, 0);
    P.renderer.render(P.scene, P.camera);
    if (P.anim) kick();
  }

  // Seen in a browser: the entry can come in the URL.
  window.addEventListener('load', function () {
    if (P || location.hash.length < 2) return;
    try { open(JSON.parse(decodeURIComponent(location.hash.slice(1)))); } catch (e) {}
  });

  return {
    open: open,
    // For checks: where the player is and whether it draws in 3D.
    state: function () { return P && { i: P.i, n: P.moves.length, playing: P.playing, gl: !!P.scene }; }
  };
})();
