import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';
import 'block_grid_skin_picker.dart';
import 'block_grid_skins.dart';

/// Blok Merkezi: drag a piece from the tray onto the 9×9 board. While dragging, the core previews
/// the drop (skin accent = fits, red = blocked) and lights up every row / column / box that would
/// clear. The piece floats above the finger so it stays visible.
///
/// Everything is drawn in the active skin (see block_grid_skins.dart): pieces take a hue from
/// their shape, and the board, frame, preview glow and clear particles follow the skin. The palette
/// button next to the HUD opens the skin picker; unlocks are announced with a toast.
///
/// Motion model (visual only; the snap and every action use the real finger position at once):
/// - Pick-up: the piece lifts out of its tray slot, grows to board size ×1.08 with a soft shadow and
///   then trails the finger with a ~35 ms smoothing lag; over a blocked spot it tints red.
/// - Drop: each cell flies into its slot (staggered 15 ms) and pops with a strong easeOutBack.
///   A drop that does not place flies back to its tray slot (easeOutCubic, 220 ms).
/// - Clears: cleared cells flash, then shrink and fade in a wave that starts at the placed piece and
///   runs outward, bursting into skin particles. A callout ("Güzel!" … "Efsane!") sized by units ×
///   streak, the "+score" and the combo line rise and fade. Multi-unit clears shake the board and
///   flash it; a "SERİ ×n" chip tracks the streak.
/// - New tray pieces slide in from the side, staggered. HUD counters roll up.
/// - Win: a diagonal wave of light, a ring burst and confetti in the skin's colours.
/// A Ticker runs only while something animates; painters repaint from one shared notifier.
Widget blockGridView(BuildContext context, GameSession s) => _BlockGrid(key: ObjectKey(s), session: s);

// Animation timings (seconds).
const double _liftScale = 1.08;
const double _travel = 0.08;
const double _stagger = 0.015;
const double _pop = 0.16;
const double _returnDur = 0.22;
const double _waveSpread = 0.12;
const double _cellClear = 0.2;
const double _trayIn = 0.32;
const double _winDur = 0.8;
const double _shakeDur = 0.42;
const double _flashDur = 0.35;
const double _ringDur = 0.9;
const double _gravity = 520; // px / s²

/// Overshooting ease-out with a stronger back than [Curves.easeOutBack].
double _backOut(double t, [double s = 2.2]) {
  final u = t - 1;
  return 1 + (s + 1) * u * u * u + s * u * u;
}

/// Callout for a clearing placement: [units] cleared at once, the [streak] after it, and whether it
/// emptied the board. Tier 1..4 escalates "Güzel!" → "Harika!" → "Muhteşem!" → "Efsane!".
({String word, int tier}) blockCallout(int units, int streak, bool allClear) {
  if (allClear) return (word: 'Tertemiz!', tier: 4);
  final power = math.max(1, units) + (streak - 1).clamp(0, 3);
  return switch (power) {
    1 => (word: 'Güzel!', tier: 1),
    2 => (word: 'Harika!', tier: 2),
    3 => (word: 'Muhteşem!', tier: 3),
    _ => (word: 'Efsane!', tier: 4),
  };
}

/// Repaint signal for the painters: pinged by the ticker while effects run.
class _Frame extends ChangeNotifier {
  void ping() => notifyListeners();
}

/// A piece flying back to its tray slot.
class _Return {
  final List<(int, int)> cells;
  final int w, h, hue;
  final Offset from;
  final double fromCell, at;
  const _Return(this.cells, this.w, this.h, this.hue, this.from, this.fromCell, this.at);
}

/// A placed piece whose cells fly from the finger into their board slots.
class _Drop {
  final List<(int, int)> cells;
  final List<int> idx; // board index of each cell
  final List<bool> cleared; // cell is part of a clear (handed over to the clear wave at [clearAt])
  final int w, h, hue;
  final Offset from;
  final double fromCell, at, clearAt;
  const _Drop(this.cells, this.idx, this.cleared, this.w, this.h, this.hue, this.from, this.fromCell, this.at, this.clearAt);
  double get end => at + _travel + (cells.length - 1) * _stagger + _pop;
}

/// Cells cleared by one placement; [delay] staggers them outward from the placed piece.
/// [tile] is the hue seed of each cell, or -1 for a stone.
class _Clear {
  final List<int> idx, tile;
  final List<double> delay;
  final double at;
  const _Clear(this.idx, this.tile, this.delay, this.at);
  double get end => at + _waveSpread + _cellClear;
}

enum _Shape { dust, chip, sprinkle, flake, streak, shard, confetti }

/// A particle in stack coordinates; its position is analytic (no per-frame state).
class _Particle {
  final double x, y, vx, vy, born, life, size, spin, phase, grav;
  final Color color;
  final _Shape shape;
  const _Particle(this.shape, this.color, this.x, this.y, this.vx, this.vy, this.born, this.life, this.size,
      {this.spin = 0, this.phase = 0, this.grav = 1});
}

class _BlockGrid extends StatefulWidget {
  final GameSession session;
  const _BlockGrid({super.key, required this.session});

  @override
  State<_BlockGrid> createState() => _BlockGridState();
}

class _BlockGridState extends State<_BlockGrid> with SingleTickerProviderStateMixin {
  final _boardKey = GlobalKey();
  final _stackKey = GlobalKey();
  late final Ticker _ticker = createTicker((_) => _onTick());
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;
  double _lastTick = 0;
  final _frame = _Frame();
  final _rng = math.Random();

  BlockSkinStore? _store = BlockSkinStore.loaded;
  BlockSkin get _skin => _store?.skin ?? BlockSkins.zumrut;
  OverlayEntry? _toast;

  /// Hue seed of every board cell (the shape id of the piece that filled it).
  final List<int> _hue = List<int>.filled(81, 0);

  int? _drag;
  Offset _finger = Offset.zero;
  Offset _fingerLocal = Offset.zero;
  double _cell = 30;
  (int, int, int)? _sent;

  // Layout, in stack coordinates (from the last build).
  Offset _bo = Offset.zero;
  List<Rect> _slots = const [Rect.zero, Rect.zero, Rect.zero];

  // Dragged piece: visual centre / cell size chase the finger; tint = blocked amount.
  List<(int, int)> _dragCells = const [];
  int _dragW = 1, _dragH = 1, _dragHue = 0;
  Offset _visC = Offset.zero;
  double _visCell = 30;
  double _tint = 0;

  final Map<int, _Return> _rets = {};
  final List<_Drop> _drops = [];
  final List<_Clear> _clears = [];
  final List<_Particle> _parts = [];
  final List<double> _trayAt = [-10, -10, -10];
  int _pTrayCount = 0;
  String _pStatus = 'playing';
  bool _winPending = false;
  double _winAt = -1;
  bool _winBuzzed = false;
  double _shakeAt = -10, _shakeAmp = 0;
  double _flashAt = -10, _flashAmp = 0;

  // Floating callout: word + "+score" + combo line.
  int _labelSerial = 0;
  String _labelWord = '';
  int _labelTier = 1;
  String _labelScore = '';
  String _labelText = '';
  Offset _labelPos = Offset.zero; // board cell units
  double _labelDelay = 0;

  GameSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    _pTrayCount = _trayCount();
    _pStatus = s.status;
    final now = _now;
    for (var i = 0; i < 3; i++) {
      _trayAt[i] = now + 0.05 + 0.07 * i;
    }
    s.addListener(_onSession);
    _store?.addListener(_onStore);
    if (_store == null) {
      BlockSkinStore.load().then((st) {
        if (!mounted) return;
        setState(() => _store = st);
        st.addListener(_onStore);
      });
    }
    _kick();
  }

  @override
  void dispose() {
    s.removeListener(_onSession);
    _store?.removeListener(_onStore);
    _toast?.remove();
    _toast = null;
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  void _onStore() {
    if (mounted) setState(() {});
  }

  int _trayCount() => (s.state['tray'] as List? ?? const []).whereType<Map>().length;

  void _onSession() {
    final now = _now;
    final count = _trayCount();
    if (count > _pTrayCount) {
      // A new set was dealt: slide the pieces in one after another.
      final tray = s.state['tray'] as List? ?? const [];
      var k = 0;
      for (var i = 0; i < 3 && i < tray.length; i++) {
        if (tray[i] is Map) _trayAt[i] = now + 0.1 + 0.07 * k++;
      }
      _kick();
    }
    _pTrayCount = count;
    final status = s.status;
    if (status == 'won' && _pStatus != 'won') {
      _winPending = true; // resolved on the next frame, once the drop / clear are registered
      _kick();
      if (s.mode == 'level') {
        // The result card opens ~1.25 s after a win; the toast sits above it.
        _store?.reachLevel(s.level).then((g) => _announce(g, delay: const Duration(milliseconds: 1600)));
      }
    }
    _pStatus = status;
  }

  void _kick() {
    if (!_ticker.isActive) {
      _lastTick = _now;
      _ticker.start();
    }
  }

  bool _busy(double now) =>
      _drag != null ||
      _rets.isNotEmpty ||
      _drops.isNotEmpty ||
      _clears.isNotEmpty ||
      _parts.isNotEmpty ||
      _winPending ||
      _trayAt.any((t) => now - t < _trayIn) ||
      now - _shakeAt < _shakeDur ||
      now - _flashAt < _flashDur ||
      (_winAt >= 0 && now - _winAt < math.max(_winDur, _ringDur) + 0.05);

  void _onTick() {
    final now = _now;
    final dt = (now - _lastTick).clamp(0.0, 0.05);
    _lastTick = now;
    if (_drag != null) {
      final target = _fingerLocal - Offset(0, _dragH * _cell / 2 + _cell * 1.1);
      _visC = Offset.lerp(_visC, target, 1 - math.exp(-dt / 0.035))!;
      _visCell += (_cell * _liftScale - _visCell) * (1 - math.exp(-dt / 0.05));
      final pv = s.state['pv'];
      final bad = _sent != null && pv is Map && pv['ok'] == false && pv['p'] == _drag;
      _tint += ((bad ? 1.0 : 0.0) - _tint) * (1 - math.exp(-dt / 0.05));
    }
    if (_rets.isNotEmpty) {
      final done = [for (final e in _rets.entries) if (now - e.value.at >= _returnDur) e.key];
      if (done.isNotEmpty) setState(() => done.forEach(_rets.remove)); // show the tray piece again
    }
    _drops.removeWhere((d) => now > d.end);
    _clears.removeWhere((c) => now > c.end);
    _parts.removeWhere((p) => now - p.born > p.life);
    if (_winPending) {
      _winPending = false;
      var at = now + 0.05;
      for (final d in _drops) {
        at = math.max(at, d.end - _pop * 0.5);
      }
      for (final c in _clears) {
        at = math.max(at, c.end - 0.12);
      }
      _winAt = at;
      _winBuzzed = false;
      _spawnWin(at);
    }
    if (_winAt >= 0 && !_winBuzzed && now >= _winAt) {
      _winBuzzed = true;
      HapticFeedback.mediumImpact();
    }
    _frame.ping();
    if (!_busy(now)) _ticker.stop();
  }

  // ---- particles ----

  void _spawnWin(double at) {
    final skin = _skin;
    final colors = [...skin.hues, skin.accentLight];
    final size = _cell * 9;
    // Sparks on the anti-diagonal the light wave is crossing.
    for (var i = 0; i < 22; i++) {
      final u = _rng.nextDouble();
      final sum = (u * 16).round();
      final lo = math.max(0, sum - 8), hi = math.min(8, sum);
      final x = lo + _rng.nextInt(hi - lo + 1) + 0.5;
      final y = sum - (x - 0.5) + 0.5;
      final a = -math.pi / 2 + (_rng.nextDouble() - 0.5) * 1.6;
      final v = 140 + _rng.nextDouble() * 160;
      _parts.add(_Particle(_Shape.dust, skin.accentLight, _bo.dx + x * _cell, _bo.dy + y * _cell, math.cos(a) * v,
          math.sin(a) * v, at + u * 0.5, 0.5 + _rng.nextDouble() * 0.35, 1.6 + _rng.nextDouble() * 1.6));
    }
    // Confetti fountains from both lower corners and a shower from the top.
    for (var i = 0; i < 64; i++) {
      final left = i.isEven;
      final top = i % 4 == 3;
      final x = top ? _bo.dx + _rng.nextDouble() * size : _bo.dx + (left ? 0.05 : 0.95) * size;
      final y = top ? _bo.dy - _cell : _bo.dy + size * 0.95;
      final vx = top ? (_rng.nextDouble() - 0.5) * 60 : (left ? 1 : -1) * (60 + _rng.nextDouble() * 170);
      final vy = top ? 20 + _rng.nextDouble() * 60 : -(380 + _rng.nextDouble() * 260);
      _parts.add(_Particle(_Shape.confetti, colors[_rng.nextInt(colors.length)], x, y, vx, vy,
          at + 0.05 + _rng.nextDouble() * 0.35, 1.5 + _rng.nextDouble() * 0.9, 2.2 + _rng.nextDouble() * 1.6,
          spin: 4 + _rng.nextDouble() * 8, phase: _rng.nextDouble() * 6.28, grav: 0.55));
    }
  }

  /// Particles for one cleared cell at [p], thrown along [dir].
  void _spawnClear(Offset p, Offset dir, double born, int tile, double power) {
    final skin = _skin;
    final hueColor = tile < 0 ? skin.stone : skin.hue(tile);
    double r() => _rng.nextDouble();
    void add(_Shape shape, Color color, double speed, double size, {double grav = 1, double life = 0.5}) {
      final a = math.atan2(dir.dy, dir.dx) + (r() - 0.5) * 1.4;
      final v = speed * (0.6 + 0.8 * r()) * power;
      _parts.add(_Particle(shape, color, p.dx + (r() - 0.5) * _cell * 0.5, p.dy + (r() - 0.5) * _cell * 0.5,
          math.cos(a) * v, math.sin(a) * v - 80, born + r() * 0.04, life * (0.8 + 0.5 * r()), size * (0.7 + 0.6 * r()),
          spin: (r() - 0.5) * 18, phase: r() * 6.28, grav: grav));
    }

    switch (skin.particle) {
      case ParticleStyle.dust:
        add(_Shape.dust, skin.accentLight, 150, 2.4);
        add(_Shape.chip, hueColor, 120, 2.4, life: 0.55);
      case ParticleStyle.chips:
        add(_Shape.chip, hueColor, 140, 3.0, life: 0.6);
        add(_Shape.chip, Color.lerp(hueColor, Colors.black, 0.3)!, 110, 2.2, life: 0.6);
        add(_Shape.dust, const Color(0xFFF2D6A8), 70, 1.3, grav: 0.3, life: 0.7);
      case ParticleStyle.sprinkles:
        for (var k = 0; k < 2; k++) {
          add(_Shape.sprinkle, skin.hues[_rng.nextInt(skin.hues.length)], 150, 2.6, life: 0.65);
        }
        add(_Shape.dust, Colors.white, 90, 1.6, life: 0.4);
      case ParticleStyle.marble:
        add(_Shape.shard, hueColor, 130, 2.6, life: 0.6);
        add(_Shape.dust, const Color(0xFFEDEBE6), 60, 1.8, grav: 0.2, life: 0.8);
      case ParticleStyle.streaks:
        add(_Shape.streak, hueColor, 260, 2.2, grav: 0.2, life: 0.45);
        add(_Shape.dust, hueColor, 120, 1.8, grav: 0.4, life: 0.5);
      case ParticleStyle.flakes:
        add(_Shape.flake, Colors.white, 90, 3.2, grav: 0.25, life: 0.9);
        add(_Shape.shard, Color.lerp(hueColor, Colors.white, 0.4)!, 140, 2.4, life: 0.55);
      case ParticleStyle.shards:
        add(_Shape.shard, hueColor, 160, 3.0, life: 0.6);
        add(_Shape.dust, Colors.white, 120, 1.8, grav: 0.4, life: 0.45);
    }
  }

  // ---- unlocks ----

  void _announce(List<BlockSkin> gained, {Duration delay = Duration.zero}) {
    if (gained.isEmpty) return;
    Future.delayed(delay, () {
      if (!mounted) return;
      final overlay = Overlay.maybeOf(context, rootOverlay: true);
      if (overlay == null) return;
      _toast?.remove();
      late final OverlayEntry entry;
      entry = OverlayEntry(
        builder: (_) => _UnlockToast(
          skins: gained,
          onTap: () {
            if (identical(_toast, entry)) {
              _toast = null;
              entry.remove();
            }
            _openPicker();
          },
          onDone: () {
            if (identical(_toast, entry)) {
              _toast = null;
              entry.remove();
            }
          },
        ),
      );
      _toast = entry;
      overlay.insert(entry);
      HapticFeedback.lightImpact();
    });
  }

  void _openPicker() {
    final st = _store;
    if (st == null || !mounted) return;
    showBlockSkinPicker(context, st);
  }

  // ---- dragging ----

  Map<String, dynamic>? _trayItem(int i) {
    final tray = s.state['tray'] as List? ?? const [];
    return i < tray.length && tray[i] is Map ? Map<String, dynamic>.from(tray[i] as Map) : null;
  }

  int _hueOf(Map<String, dynamic> item) => (item['s'] as num?)?.toInt() ?? 0;

  /// Top-left of the floating piece in global coordinates: centred above the finger.
  Offset _pieceOrigin(Map<String, dynamic> item) {
    final w = (item['w'] as num).toDouble(), h = (item['h'] as num).toDouble();
    return _finger - Offset(w * _cell / 2, h * _cell + _cell * 1.1);
  }

  Offset _toLocal(Offset global) {
    final box = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    return box == null ? global : box.globalToLocal(global);
  }

  double _trayCell(int i) => math.min(_slots[i].width - 2, _slots[i].height - 2) / 5.6;

  (Offset, double) _returnPose(int slot, _Return r, double now) {
    final e = Curves.easeOutCubic.transform(((now - r.at) / _returnDur).clamp(0.0, 1.0));
    final cell = r.fromCell + (_trayCell(slot) - r.fromCell) * e;
    return (Offset.lerp(r.from, _slots[slot].center, e)!, cell);
  }

  void _dragStart(int i, Offset global) {
    final item = _trayItem(i);
    if (s.finished || item == null) return;
    final now = _now;
    final ret = _rets.remove(i);
    if (ret != null) {
      final (c, cell) = _returnPose(i, ret, now);
      _visC = c;
      _visCell = cell;
    } else {
      _visC = _slots[i].center;
      _visCell = _trayCell(i);
    }
    _dragCells = _cells(item);
    _dragW = (item['w'] as num).toInt();
    _dragH = (item['h'] as num).toInt();
    _dragHue = _hueOf(item);
    _tint = 0;
    _fingerLocal = _toLocal(global);
    HapticFeedback.selectionClick();
    setState(() {
      _drag = i;
      _finger = global;
      _sent = null;
    });
    _updatePreview();
    _kick();
  }

  void _dragUpdate(Offset global) {
    if (_drag == null) return;
    _finger = global;
    _fingerLocal = _toLocal(global);
    _updatePreview();
  }

  (int, int)? _snap() {
    final i = _drag;
    final item = i == null ? null : _trayItem(i);
    final box = _boardKey.currentContext?.findRenderObject() as RenderBox?;
    if (item == null || box == null) return null;
    final local = box.globalToLocal(_pieceOrigin(item));
    final w = (item['w'] as num).toInt(), h = (item['h'] as num).toInt();
    final x = (local.dx / _cell).round(), y = (local.dy / _cell).round();
    // Only snap when the piece overlaps the board by at least half its size.
    if (x + w / 2 < 0 || y + h / 2 < 0 || x + w / 2 > 9 || y + h / 2 > 9) return null;
    return (x, y);
  }

  void _updatePreview() {
    final i = _drag;
    if (i == null) return;
    final sn = _snap();
    final key = sn == null ? null : (i, sn.$1, sn.$2);
    if (key == _sent) return;
    _sent = key;
    if (sn == null) {
      s.act({'a': 'pv'});
    } else {
      s.act({'a': 'pv', 'p': i, 'x': sn.$1, 'y': sn.$2});
    }
  }

  void _dragEnd() {
    final i = _drag;
    if (i == null) return;
    final now = _now;
    final item = _trayItem(i);
    final pv = s.state['pv'];
    final sn = _snap();
    final oldBoard = (s.state['b'] as String?) ?? '';
    final oldScore = (s.state['score'] as num?)?.toInt() ?? 0;
    final oldEv = (s.state['ev'] as num?)?.toInt() ?? 0;
    _drag = null;
    _sent = null;
    var placed = false;
    if (item != null && sn != null && pv is Map && pv['ok'] == true && pv['p'] == i && pv['x'] == sn.$1 && pv['y'] == sn.$2) {
      final idx = [for (final v in pv['c'] as List) (v as num).toInt()];
      placed = s.act({'a': 'place', 'p': i, 'x': sn.$1, 'y': sn.$2});
      if (placed) {
        HapticFeedback.selectionClick();
        _registerPlacement(now, idx, oldBoard, oldScore, oldEv);
      }
    } else if (!s.finished) {
      s.act({'a': 'pv'});
    }
    if (!placed && item != null) {
      _rets[i] = _Return(_dragCells, _dragW, _dragH, _dragHue, _visC, _visCell, now);
    }
    setState(() {});
    _kick();
  }

  void _registerPlacement(double now, List<int> idx, String oldBoard, int oldScore, int oldEv) {
    final st = s.state;
    final ev = (st['ev'] as num?)?.toInt() ?? 0;
    final landAt = now + _travel + (_dragCells.length - 1) * _stagger;
    for (final i in idx) {
      if (i >= 0 && i < 81) _hue[i] = _dragHue;
    }
    final cleared = <int>{};
    if (ev != oldEv) {
      final lc = [for (final v in st['lc'] as List? ?? const []) (v as num).toInt()];
      final units = (st['lu'] as num?)?.toInt() ?? 1;
      final streak = (st['streak'] as num?)?.toInt() ?? 1;
      final allClear = st['ac'] == true;
      cleared.addAll(lc);
      // Wave origin: the placed piece's centre.
      var ox = 0.0, oy = 0.0;
      for (final i in idx) {
        ox += i % 9 + 0.5;
        oy += i ~/ 9 + 0.5;
      }
      final origin = Offset(ox / idx.length, oy / idx.length);
      final dist = [for (final i in lc) (Offset(i % 9 + 0.5, i ~/ 9 + 0.5) - origin).distance];
      final maxD = dist.fold<double>(1, math.max);
      final placedSet = idx.toSet();
      final tiles = [
        for (final i in lc)
          placedSet.contains(i) || i >= oldBoard.length || oldBoard.codeUnitAt(i) != 50 ? _hue[i.clamp(0, 80)] : -1
      ];
      final delays = [for (final d in dist) d / maxD * _waveSpread];
      _clears.add(_Clear(lc, tiles, delays, landAt));
      // Particles burst from every cleared cell, outward from the placed piece.
      final o = _bo + origin * _cell;
      final power = 1 + 0.15 * (units - 1).clamp(0, 4);
      final step = lc.length > 45 ? 2 : 1;
      for (var j = 0; j < lc.length; j += step) {
        final i = lc[j];
        final p = _bo + Offset(i % 9 + 0.5, i ~/ 9 + 0.5) * _cell;
        var dir = p - o;
        dir = dir.distance < 1 ? Offset(_rng.nextDouble() - 0.5, -1) : dir / dir.distance;
        _spawnClear(p, dir, landAt + delays[j] + 0.05, tiles[j], power);
      }
      if (units >= 2 || allClear) {
        _shakeAt = landAt + 0.04;
        _shakeAmp = _cell * (0.05 + 0.035 * math.min(units, 5)) * (allClear ? 1.4 : 1);
        _flashAt = landAt + 0.04;
        _flashAmp = math.min(0.32, 0.08 * units + (allClear ? 0.12 : 0));
        HapticFeedback.heavyImpact();
      } else {
        HapticFeedback.mediumImpact();
      }
      final gained = ((st['score'] as num?)?.toInt() ?? 0) - oldScore;
      final et = (st['et'] as String?) ?? '';
      final call = blockCallout(units, streak, allClear);
      _labelSerial++;
      _labelWord = Lux.upper(call.word);
      _labelTier = call.tier;
      _labelScore = '+$gained';
      final detail = et.replaceAll('Tertemiz!', '').split(' · ').where((p) => p.trim().isNotEmpty && !p.startsWith('+'));
      _labelText = Lux.upper(detail.join(' · '));
      _labelPos = origin;
      _labelDelay = landAt - now;
      _store?.addLines(units).then(_announce);
    }
    _drops.add(_Drop(_dragCells, idx, [for (final i in idx) cleared.contains(i)], _dragW, _dragH, _dragHue, _visC,
        _visCell, now, landAt));
  }

  // ---- build ----

  Offset _shake(double now) {
    final t = now - _shakeAt;
    if (t < 0 || t > _shakeDur) return Offset.zero;
    final d = _shakeAmp * math.exp(-t * 9);
    return Offset(math.sin(t * 58) * d, math.cos(t * 47) * d * 0.6);
  }

  Gradient _frameGradient(BlockSkin skin) => skin.style == TileStyle.candy
      ? LinearGradient(
          begin: const Alignment(-1, -1),
          end: const Alignment(-0.88, -0.82),
          colors: [skin.frame[0], skin.frame[0], skin.frame[1], skin.frame[1]],
          stops: const [0, 0.5, 0.5, 1],
          tileMode: TileMode.repeated,
        )
      : LinearGradient(begin: const Alignment(-1, -0.6), end: const Alignment(1, 0.6), colors: skin.frame);

  @override
  Widget build(BuildContext context) {
    final st = s.state;
    final board = (st['b'] as String?) ?? '';
    final hud = st['hud'] as List? ?? const [];
    final pvRaw = st['pv'];
    final pv = pvRaw is Map ? Map<String, dynamic>.from(pvRaw) : null;
    final streak = (st['streak'] as num?)?.toInt() ?? 0;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final skin = _skin;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 6, 0),
          child: Row(children: [
            for (var i = 0; i < hud.length; i++) Expanded(child: _stat(i, '${(hud[i] as List)[0]}', '${hud[i][1]}')),
            _paletteButton(skin),
          ]),
        ),
        Expanded(
          child: LayoutBuilder(builder: (context, box) {
            final trayH = (box.maxHeight * 0.24).clamp(96.0, 170.0);
            final boardSize = (box.maxWidth - 24).clamp(120.0, box.maxHeight - trayH - 20);
            _cell = boardSize / 9;
            final boardLeft = (box.maxWidth - boardSize) / 2;
            final boardTop = ((box.maxHeight - trayH - 12 - boardSize) / 2).clamp(10.0, 80.0);
            _bo = Offset(boardLeft, boardTop);
            final trayTop = box.maxHeight - 6 - trayH;
            final sw = (box.maxWidth - 16) / 3;
            _slots = [for (var i = 0; i < 3; i++) Rect.fromLTWH(8 + i * sw + 5, trayTop, sw - 10, trayH)];
            final boardWidget = Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: _frameGradient(skin),
                boxShadow: [BoxShadow(color: skin.accent.withValues(alpha: 0.22 + 0.05 * streak.clamp(0, 5)), blurRadius: 22)],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: RepaintBoundary(
                  child: CustomPaint(
                    key: _boardKey,
                    size: Size.square(boardSize),
                    painter: _BoardPainter(
                      fx: this,
                      skin: skin,
                      board: board,
                      pv: pv,
                      dragging: _drag != null,
                      dpr: dpr,
                      repaint: _frame,
                    ),
                  ),
                ),
              ),
            );
            return Stack(
              key: _stackKey,
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: boardLeft - 5,
                  top: boardTop - 5,
                  width: boardSize + 10,
                  height: boardSize + 10,
                  child: AnimatedBuilder(
                    animation: _frame,
                    builder: (context, child) => Transform.translate(offset: _shake(_now), child: child),
                    child: boardWidget,
                  ),
                ),
                Positioned(
                  right: boardLeft + 6,
                  top: boardTop - 16,
                  child: IgnorePointer(child: _streakChip(streak, skin)),
                ),
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 6,
                  height: trayH,
                  child: Row(
                    children: [
                      for (var i = 0; i < 3; i++)
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onPanStart: (d) => _dragStart(i, d.globalPosition),
                            onPanUpdate: (d) => _dragUpdate(d.globalPosition),
                            onPanEnd: (_) => _dragEnd(),
                            onPanCancel: _dragEnd,
                            child: _traySlot(i, dpr, skin),
                          ),
                        ),
                    ],
                  ),
                ),
                // Floating / flying pieces and particles, above board and tray.
                Positioned.fill(
                  child: IgnorePointer(
                    child: RepaintBoundary(
                      child: CustomPaint(painter: _FxPainter(fx: this, skin: skin, dpr: dpr, repaint: _frame)),
                    ),
                  ),
                ),
                if (_labelSerial > 0)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: boardTop + _labelPos.dy * _cell - _cell * 2.4,
                    child: IgnorePointer(child: _scoreLabel(box.maxWidth, boardSize, skin)),
                  ),
              ],
            );
          }),
        ),
      ],
    );
  }

  Widget _paletteButton(BlockSkin skin) {
    final fresh = _store?.unseen.isNotEmpty ?? false;
    return SizedBox(
      width: 44,
      height: 44,
      child: Stack(
        alignment: Alignment.center,
        children: [
          IconButton(
            tooltip: 'Görünüm',
            padding: EdgeInsets.zero,
            onPressed: _openPicker,
            icon: Icon(Icons.palette_outlined, color: skin.accent, size: 24),
          ),
          if (fresh)
            Positioned(
              right: 8,
              top: 8,
              child: Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: Lux.bordeauxLight,
                  shape: BoxShape.circle,
                  border: Border.all(color: Lux.bg0, width: 1.5),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// "SERİ ×n" badge on the board frame while a streak runs; pops on every change.
  Widget _streakChip(int streak, BlockSkin skin) {
    final on = streak >= 2;
    final hot = (streak - 1).clamp(0, 5) / 5;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      transitionBuilder: (child, a) => ScaleTransition(
        scale: CurvedAnimation(parent: a, curve: Curves.easeOutBack),
        child: FadeTransition(opacity: a, child: child),
      ),
      child: !on
          ? const SizedBox.shrink(key: ValueKey(0))
          : Container(
              key: ValueKey(streak),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: Color.lerp(const Color(0xFF1A120A), skin.accent, 0.25 + 0.5 * hot),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: skin.accentLight.withValues(alpha: 0.8)),
                boxShadow: [BoxShadow(color: skin.accent.withValues(alpha: 0.3 + 0.4 * hot), blurRadius: 8 + 10 * hot)],
              ),
              child: Text('SERİ ×$streak', style: Lux.ui(12.5, color: Colors.white, weight: FontWeight.w700, spacing: 1)),
            ),
    );
  }

  /// Callout word, "+score" and the combo / streak line popping up over the clear, rising and fading.
  Widget _scoreLabel(double width, double boardSize, BlockSkin skin) {
    final ax = ((_bo.dx + _labelPos.dx * _cell) / width * 2 - 1).clamp(-0.5, 0.5);
    final tier = _labelTier;
    final glow = [
      Shadow(color: skin.accent.withValues(alpha: 0.9), blurRadius: 10.0 + 6 * tier),
      const Shadow(color: Color(0xCC000000), blurRadius: 4, offset: Offset(0, 2)),
    ];
    final wordColor = Color.lerp(skin.accentLight, Colors.white, 0.15 * tier)!;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(_labelWord,
            style: Lux.display(boardSize * (0.07 + 0.013 * tier), color: wordColor, spacing: 1.5).copyWith(shadows: glow)),
        Text(_labelScore, style: Lux.numeral(boardSize * 0.075, color: const Color(0xFFFFF4DC)).copyWith(shadows: glow)),
        if (_labelText.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(_labelText,
                textAlign: TextAlign.center,
                style: Lux.ui(boardSize * 0.036, color: skin.accentLight, weight: FontWeight.w700, spacing: 1.2)
                    .copyWith(shadows: glow)),
          ),
      ],
    );
    const life = 1.15;
    final total = _labelDelay + life;
    return TweenAnimationBuilder<double>(
      key: ValueKey(_labelSerial),
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: (total * 1000).round()),
      builder: (context, t, child) {
        final k = (t * total - _labelDelay) / life;
        if (k <= 0 || k >= 1) return const SizedBox.shrink();
        final opacity = k < 0.1 ? k / 0.1 : (k > 0.62 ? 1 - (k - 0.62) / 0.38 : 1.0);
        final scale = 0.4 + 0.6 * _backOut((k / 0.2).clamp(0.0, 1.0), 1.6 + 0.4 * tier);
        final wiggle = tier >= 3 ? math.sin(k * 40) * 0.05 * (1 - (k / 0.35).clamp(0.0, 1.0)) : 0.0;
        return Align(
          alignment: Alignment(ax, 0),
          child: Opacity(
            opacity: opacity.clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(0, -_cell * 1.2 * Curves.easeOutCubic.transform(k)),
              child: Transform.rotate(angle: wiggle, child: Transform.scale(scale: scale, child: child)),
            ),
          ),
        );
      },
      child: content,
    );
  }

  List<(int, int)> _cells(Map<String, dynamic> item) {
    final c = [for (final v in item['c'] as List) (v as num).toInt()];
    return [for (var i = 0; i + 1 < c.length; i += 2) (c[i], c[i + 1])];
  }

  Widget _traySlot(int i, double dpr, BlockSkin skin) {
    final item = _trayItem(i);
    final hidden = item == null || _drag == i || _rets.containsKey(i);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Color.lerp(skin.bg, Colors.black, 0.25),
        border: Border.all(color: skin.accent.withValues(alpha: 0.25)),
      ),
      child: hidden
          ? const SizedBox.expand()
          : LayoutBuilder(builder: (context, box) {
              final cell = math.min(box.maxWidth, box.maxHeight) / 5.6;
              final fits = item['f'] == true;
              return AnimatedBuilder(
                animation: _frame,
                builder: (context, child) {
                  final k = ((_now - _trayAt[i]) / _trayIn).clamp(0.0, 1.0);
                  if (k >= 1) return child!;
                  final e = Curves.easeOutCubic.transform(k);
                  return Opacity(
                    opacity: (k * 2.5).clamp(0.0, 1.0),
                    child: Transform.translate(
                      offset: Offset(48 * (1 - e), 10 * (1 - e)),
                      child: Transform.scale(scale: 0.6 + 0.4 * _backOut(k, 1.8), child: child),
                    ),
                  );
                },
                child: Center(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 250),
                    opacity: fits ? 1 : 0.3,
                    child: CustomPaint(
                      size: Size((item['w'] as num) * cell, (item['h'] as num) * cell),
                      painter: _PiecePainter(_cells(item), _hueOf(item), skin, cell, dpr),
                    ),
                  ),
                ),
              );
            }),
    );
  }

  Widget _stat(int i, String label, String value) => Column(
        children: [
          _Roll(value, key: ValueKey('hud$i$label'), style: Lux.ui(21, color: Lux.goldLight, weight: FontWeight.w700)),
          Text(label, style: Lux.ui(11, color: Lux.muted, spacing: 1)),
        ],
      );
}

/// Texture variant of a piece cell (stable within a piece).
int _pieceVariant(int x, int y) => x * 2 + y * 5;

/// Static tray piece.
class _PiecePainter extends CustomPainter {
  final List<(int, int)> cells;
  final int hue;
  final BlockSkin skin;
  final double cell;
  final double dpr;
  _PiecePainter(this.cells, this.hue, this.skin, this.cell, this.dpr);

  @override
  void paint(Canvas canvas, Size size) {
    for (final (x, y) in cells) {
      BlockTiles.draw(canvas, skin, hue, _pieceVariant(x, y), Rect.fromLTWH(x * cell, y * cell, cell, cell), dpr);
    }
  }

  @override
  bool shouldRepaint(_PiecePainter old) =>
      old.cell != cell || old.cells.length != cells.length || old.dpr != dpr || old.hue != hue || old.skin.id != skin.id;
}

/// Unlock announcement: slides down from the top, glows, and leaves after ~3 s. Tap opens the picker.
class _UnlockToast extends StatefulWidget {
  final List<BlockSkin> skins;
  final VoidCallback onTap;
  final VoidCallback onDone;
  const _UnlockToast({required this.skins, required this.onTap, required this.onDone});

  @override
  State<_UnlockToast> createState() => _UnlockToastState();
}

class _UnlockToastState extends State<_UnlockToast> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 3400))
    ..forward().whenComplete(() {
      if (mounted) widget.onDone();
    });

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final skin = widget.skins.last;
    final names = widget.skins.map((s) => s.name).join(', ');
    final title = widget.skins.length == 1 ? 'Yeni görünüm açıldı: $names' : 'Yeni görünümler açıldı: $names';
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final top = MediaQuery.paddingOf(context).top + 12;
    return Positioned(
      left: 16,
      right: 16,
      top: top,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          final ms = _c.value * 3400;
          final inK = (ms / 420).clamp(0.0, 1.0);
          final outK = ((ms - 2950) / 450).clamp(0.0, 1.0);
          final y = -90 * (1 - _backOut(inK, 1.4)) - 90 * Curves.easeIn.transform(outK);
          final shimmer = 0.5 + 0.5 * math.sin(ms / 1000 * math.pi * 2 * 1.2);
          return Transform.translate(
            offset: Offset(0, y),
            child: Opacity(
              opacity: (1 - outK).clamp(0.0, 1.0),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [BoxShadow(color: skin.accent.withValues(alpha: 0.25 + 0.3 * shimmer), blurRadius: 18 + 10 * shimmer)],
                ),
                child: child,
              ),
            ),
          );
        },
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: widget.onTap,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
              decoration: BoxDecoration(
                gradient: Lux.velvetCard,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: skin.accent, width: 1.5),
              ),
              child: Row(
                children: [
                  SizedBox(width: 46, height: 46, child: CustomPaint(painter: SkinPreviewPainter(skin, dpr))),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(title, style: Lux.ui(15, color: Lux.ink, weight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text('Dokun ve dene', style: Lux.ui(12.5, color: skin.accentLight)),
                      ],
                    ),
                  ),
                  Icon(Icons.palette_outlined, color: skin.accent),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Everything that moves above the board and tray: the dragged piece, pieces flying back to the
/// tray, cells flying into their slots, particles and the win ring. Stack coordinates.
class _FxPainter extends CustomPainter {
  final _BlockGridState fx;
  final BlockSkin skin;
  final double dpr;
  _FxPainter({required this.fx, required this.skin, required this.dpr, required Listenable repaint}) : super(repaint: repaint);

  static final Paint _fill = Paint();
  static final Paint _line = Paint()..strokeCap = StrokeCap.round;
  static final Paint _shadow = Paint()..color = const Color(0x73000000);
  static final Paint _ring = Paint()..style = PaintingStyle.stroke;

  /// A whole piece centred at [c] with cell size [cell]; [lift] 0..1 scales its shadow.
  void _piece(Canvas canvas, List<(int, int)> cells, int w, int h, int hue, Offset c, double cell, double lift, double tint) {
    final o = c - Offset(w * cell / 2, h * cell / 2);
    if (lift > 0.01) {
      final path = Path();
      final sh = Offset(0, cell * 0.24 * lift);
      for (final (x, y) in cells) {
        path.addRRect(RRect.fromRectAndRadius(
            Rect.fromLTWH(o.dx + x * cell, o.dy + y * cell, cell, cell).deflate(cell * 0.06).shift(sh), Radius.circular(cell * 0.2)));
      }
      _shadow
        ..color = Colors.black.withValues(alpha: 0.42 * lift)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 + 6 * lift);
      canvas.drawPath(path, _shadow);
    }
    for (final (x, y) in cells) {
      final r = Rect.fromLTWH(o.dx + x * cell, o.dy + y * cell, cell, cell);
      BlockTiles.draw(canvas, skin, hue, _pieceVariant(x, y), r, dpr, px: fx._cell);
      if (tint > 0.01) {
        _fill.color = skin.bad.withValues(alpha: 0.55 * tint);
        canvas.drawRRect(RRect.fromRectAndRadius(r.deflate(cell * 0.05), Radius.circular(cell * 0.18)), _fill);
      }
    }
  }

  void _particle(Canvas canvas, _Particle p, double t) {
    final a = (1 - t / p.life).clamp(0.0, 1.0);
    var x = p.x + p.vx * t;
    final y = p.y + p.vy * t + 0.5 * _gravity * p.grav * t * t;
    if (p.shape == _Shape.confetti) x += math.sin(t * 5 + p.phase) * p.size * 4;
    final o = Offset(x, y);
    final rot = p.phase + p.spin * t;
    switch (p.shape) {
      case _Shape.dust:
        _fill.color = p.color.withValues(alpha: 0.28 * a);
        canvas.drawCircle(o, p.size * 2.4, _fill);
        _fill.color = Color.lerp(p.color, Colors.white, 0.5)!.withValues(alpha: 0.95 * a);
        canvas.drawCircle(o, p.size, _fill);
      case _Shape.streak:
        final tail = o - Offset(p.vx, p.vy + _gravity * p.grav * t) * 0.035;
        _line
          ..strokeWidth = p.size * 3
          ..color = p.color.withValues(alpha: 0.25 * a);
        canvas.drawLine(tail, o, _line);
        _line
          ..strokeWidth = p.size * 0.9
          ..color = Color.lerp(p.color, Colors.white, 0.5)!.withValues(alpha: a);
        canvas.drawLine(tail, o, _line);
      case _Shape.sprinkle:
        final d = Offset(math.cos(rot), math.sin(rot)) * p.size * 1.6;
        _line
          ..strokeWidth = p.size * 1.1
          ..color = p.color.withValues(alpha: a);
        canvas.drawLine(o - d, o + d, _line);
      case _Shape.flake:
        _line
          ..strokeWidth = math.max(1.0, p.size * 0.35)
          ..color = p.color.withValues(alpha: 0.9 * a);
        for (var k = 0; k < 3; k++) {
          final ang = rot + k * math.pi / 3;
          final d = Offset(math.cos(ang), math.sin(ang)) * p.size * 1.3;
          canvas.drawLine(o - d, o + d, _line);
        }
      case _Shape.chip:
      case _Shape.shard:
      case _Shape.confetti:
        canvas.save();
        canvas.translate(o.dx, o.dy);
        canvas.rotate(rot);
        _fill.color = p.color.withValues(alpha: a);
        if (p.shape == _Shape.chip) {
          canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: p.size * 2.2, height: p.size * 1.1), _fill);
        } else if (p.shape == _Shape.confetti) {
          final flip = math.cos(t * p.spin * 1.3).abs() * 0.85 + 0.15;
          canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: p.size * 2.4, height: p.size * 1.3 * flip), _fill);
        } else {
          final r = p.size * 1.5;
          final path = Path()
            ..moveTo(0, -r)
            ..lineTo(r * 0.55, 0)
            ..lineTo(0, r)
            ..lineTo(-r * 0.55, 0)
            ..close();
          canvas.drawPath(path, _fill);
          _fill.color = Colors.white.withValues(alpha: 0.6 * a);
          canvas.drawPath(
              Path()
                ..moveTo(0, -r)
                ..lineTo(r * 0.55, 0)
                ..lineTo(0, 0)
                ..close(),
              _fill);
        }
        canvas.restore();
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final now = fx._now;
    final cell = fx._cell;

    // Pieces flying back to their tray slots.
    for (final e in fx._rets.entries) {
      final r = e.value;
      final (c, cl) = fx._returnPose(e.key, r, now);
      final k = ((now - r.at) / _returnDur).clamp(0.0, 1.0);
      _piece(canvas, r.cells, r.w, r.h, r.hue, c, cl, 1 - k, 0);
    }

    // The dragged piece.
    if (fx._drag != null) {
      final tc = fx._trayCell(fx._drag!);
      final lift = ((fx._visCell - tc) / math.max(1.0, cell * _liftScale - tc)).clamp(0.0, 1.0);
      _piece(canvas, fx._dragCells, fx._dragW, fx._dragH, fx._dragHue, fx._visC, fx._visCell, lift, fx._tint);
    }

    // Placed cells flying into their slots, then popping.
    for (final d in fx._drops) {
      final fo = d.from - Offset(d.w * d.fromCell / 2, d.h * d.fromCell / 2);
      for (var j = 0; j < d.cells.length; j++) {
        if (d.cleared[j] && now >= d.clearAt) continue; // the clear wave owns it now
        final (cx, cy) = d.cells[j];
        final start = d.at + j * _stagger;
        final e1 = Curves.easeOutCubic.transform(((now - start) / _travel).clamp(0.0, 1.0));
        final i = d.idx[j];
        final from = Offset(fo.dx + (cx + 0.5) * d.fromCell, fo.dy + (cy + 0.5) * d.fromCell);
        final to = fx._bo + fx._shake(now) + Offset(i % 9 + 0.5, i ~/ 9 + 0.5) * cell;
        final k2 = ((now - start - _travel) / _pop).clamp(0.0, 1.0);
        final sz = k2 <= 0 ? d.fromCell + (cell * 0.78 - d.fromCell) * e1 : cell * (0.78 + 0.22 * _backOut(k2));
        final r = Rect.fromCenter(center: Offset.lerp(from, to, e1)!, width: sz, height: sz);
        BlockTiles.draw(canvas, skin, d.hue, _pieceVariant(cx, cy), r, dpr, px: cell);
        if (k2 > 0 && k2 < 1) {
          _fill.color = skin.accentLight.withValues(alpha: 0.5 * (1 - k2));
          canvas.drawRRect(RRect.fromRectAndRadius(r.deflate(sz * 0.05), Radius.circular(sz * 0.18)), _fill);
        }
      }
    }

    // Win: a ring of light bursting from the board centre.
    if (fx._winAt >= 0) {
      final k = (now - fx._winAt) / _ringDur;
      if (k > 0 && k < 1) {
        final e = Curves.easeOutCubic.transform(k);
        final c = fx._bo + Offset(cell * 4.5, cell * 4.5);
        _ring
          ..strokeWidth = cell * 0.5 * (1 - k)
          ..color = skin.accentLight.withValues(alpha: 0.65 * (1 - k));
        canvas.drawCircle(c, cell * (0.5 + 6.5 * e), _ring);
      }
    }

    // Particles.
    for (final p in fx._parts) {
      final t = now - p.born;
      if (t < 0 || t > p.life) continue;
      _particle(canvas, p, t);
    }
  }

  @override
  bool shouldRepaint(_FxPainter old) => true;
}

class _BoardPainter extends CustomPainter {
  final _BlockGridState fx;
  final BlockSkin skin;
  final String board;
  final Map<String, dynamic>? pv;
  final bool dragging;
  final double dpr;
  _BoardPainter({
    required this.fx,
    required this.skin,
    required this.board,
    required this.pv,
    required this.dragging,
    required this.dpr,
    required Listenable repaint,
  }) : super(repaint: repaint);

  static final Map<int, (ui.Picture, ui.Picture)> _cache = {};
  static final Uint8List _mask = Uint8List(81);
  static final Paint _fill = Paint();
  static final Paint _stroke = Paint()..style = PaintingStyle.stroke;
  static final Paint _glow = Paint()..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

  /// Background (field, box shading, empty slots) and foreground (separators), per skin and size.
  static (ui.Picture, ui.Picture) _layers(Size size, BlockSkin skin) {
    final key = skin.index * 1000000 + (size.width * 4).round();
    return _cache[key] ??= () {
      final rec = ui.PictureRecorder();
      BlockTiles.paintBoardBackground(Canvas(rec), size, skin);
      final rec2 = ui.PictureRecorder();
      BlockTiles.paintBoardForeground(Canvas(rec2), size, skin);
      return (rec.endRecording(), rec2.endRecording());
    }();
  }

  int _tileAt(int i, int k) => k == 2 ? -1 : fx._hue[i];

  @override
  void paint(Canvas canvas, Size size) {
    final now = fx._now;
    final cell = size.width / 9;
    Rect at(int i) => Rect.fromLTWH((i % 9) * cell, (i ~/ 9) * cell, cell, cell);
    final layers = _layers(size, skin);
    canvas.drawPicture(layers.$1);

    // Cells still flying in are drawn by the overlay.
    _mask.fillRange(0, 81, 0);
    for (final d in fx._drops) {
      for (final i in d.idx) {
        if (i >= 0 && i < 81) _mask[i] = 1;
      }
    }

    // Win: a diagonal wave of light from the top-left corner.
    final winT = fx._winAt >= 0 ? now - fx._winAt : -1.0;
    final waving = winT >= 0 && winT < _winDur;
    double wave(int i) {
      if (!waving) return 0;
      final k = (winT - ((i % 9) + (i ~/ 9)) / 16 * 0.5) / 0.3;
      return k <= 0 || k >= 1 ? 0 : math.sin(math.pi * k);
    }

    for (var i = 0; i < board.length && i < 81; i++) {
      final k = board.codeUnitAt(i) - 48;
      final w = wave(i);
      if (k > 0 && _mask[i] == 0) {
        var r = at(i);
        if (w > 0) r = Rect.fromCenter(center: r.center, width: cell * (1 + 0.08 * w), height: cell * (1 + 0.08 * w));
        BlockTiles.draw(canvas, skin, _tileAt(i, k), i, r, dpr, px: cell);
        if (w > 0) {
          _fill.color = skin.accentLight.withValues(alpha: 0.5 * w);
          canvas.drawRRect(RRect.fromRectAndRadius(r.deflate(cell * 0.06), Radius.circular(cell * 0.18)), _fill);
        }
      } else if (w > 0 && k <= 0) {
        _fill.color = skin.accentLight.withValues(alpha: 0.2 * w);
        canvas.drawRRect(RRect.fromRectAndRadius(at(i).deflate(cell * 0.08), Radius.circular(cell * 0.14)), _fill);
      }
    }

    // Drop preview: the piece's ghost glows (pulsing) where it fits, red where it does not.
    final p = pv;
    if (dragging && p != null) {
      final ok = p['ok'] == true;
      final pulse = 0.5 + 0.5 * math.sin(now * math.pi * 2 * 1.1);
      final cl = p['cl'] as List? ?? const [];
      if (cl.isNotEmpty) {
        _fill.color = skin.accentLight.withValues(alpha: 0.16 + 0.14 * pulse);
        for (final v in cl) {
          canvas.drawRRect(RRect.fromRectAndRadius(at((v as num).toInt()).deflate(cell * 0.04), Radius.circular(cell * 0.16)), _fill);
        }
      }
      final cells = p['c'] as List? ?? const [];
      if (ok) {
        final glow = Path();
        for (final v in cells) {
          glow.addRRect(RRect.fromRectAndRadius(at((v as num).toInt()).deflate(cell * 0.02), Radius.circular(cell * 0.2)));
        }
        _glow.color = skin.accent.withValues(alpha: 0.35 + 0.3 * pulse);
        canvas.drawPath(glow, _glow);
        _stroke
          ..strokeWidth = 1.6
          ..color = skin.accentLight.withValues(alpha: 0.55 + 0.35 * pulse);
        for (final v in cells) {
          final i = (v as num).toInt();
          final r = at(i);
          BlockTiles.draw(canvas, skin, fx._dragHue, i, r, dpr, opacity: 0.55, px: cell);
          canvas.drawRRect(RRect.fromRectAndRadius(r.deflate(cell * 0.06), Radius.circular(cell * 0.18)), _stroke);
        }
      } else {
        _fill.color = skin.bad.withValues(alpha: 0.5);
        _stroke
          ..strokeWidth = 1.4
          ..color = Color.lerp(skin.bad, Colors.white, 0.4)!.withValues(alpha: 0.6);
        for (final v in cells) {
          final rr = RRect.fromRectAndRadius(at((v as num).toInt()).deflate(cell * 0.08), Radius.circular(cell * 0.16));
          canvas.drawRRect(rr, _fill);
          canvas.drawRRect(rr, _stroke);
        }
      }
    }

    // Clears: each cell flashes, then shrinks and fades; the wave runs outward from the placed piece.
    for (final c in fx._clears) {
      for (var j = 0; j < c.idx.length; j++) {
        final i = c.idx[j];
        if (i < 0 || i >= 81) continue;
        if (_mask[i] == 1 && now < c.at) continue; // still flying in
        final k = (now - c.at - c.delay[j]) / _cellClear;
        if (k >= 1) continue;
        final base = at(i);
        if (k <= 0) {
          BlockTiles.draw(canvas, skin, c.tile[j], i, base, dpr, px: cell);
          continue;
        }
        double sc, alpha, flash;
        if (k < 0.35) {
          final f = k / 0.35;
          sc = 1 + 0.1 * Curves.easeOut.transform(f);
          alpha = 1;
          flash = f;
        } else {
          final g = (k - 0.35) / 0.65;
          sc = 1.1 * (1 - 0.85 * Curves.easeIn.transform(g));
          alpha = 1 - g;
          flash = 1 - g;
        }
        final r = Rect.fromCenter(center: base.center, width: cell * sc, height: cell * sc);
        BlockTiles.draw(canvas, skin, c.tile[j], i, r, dpr, opacity: alpha, px: cell);
        _fill.color = Color.lerp(skin.accentLight, Colors.white, 0.6)!.withValues(alpha: 0.85 * flash * alpha);
        canvas.drawRRect(RRect.fromRectAndRadius(r.deflate(cell * 0.04 * sc), Radius.circular(cell * 0.18 * sc)), _fill);
      }
    }

    canvas.drawPicture(layers.$2);

    // Big clears light up the whole board for a moment.
    final ft = now - fx._flashAt;
    if (ft >= 0 && ft < _flashDur) {
      _fill.color = skin.accentLight.withValues(alpha: fx._flashAmp * (1 - ft / _flashDur));
      canvas.drawRect(Offset.zero & size, _fill);
    }
  }

  @override
  bool shouldRepaint(_BoardPainter old) => true;
}


/// HUD value whose numbers roll to the new value (easeOutCubic) and glint when a count goes up.
/// Clock-like values (with ':') and values whose shape changes simply switch.
class _Roll extends StatefulWidget {
  final String value;
  final TextStyle style;
  const _Roll(this.value, {super.key, required this.style});

  @override
  State<_Roll> createState() => _RollState();
}

class _RollState extends State<_Roll> with SingleTickerProviderStateMixin {
  static final _num = RegExp(r'\d+');
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 420), value: 1);
  List<int> _from = const [], _to = const [];
  bool _up = false;

  static List<int> _nums(String s) => [for (final m in _num.allMatches(s)) int.tryParse(m[0]!) ?? 0];

  @override
  void initState() {
    super.initState();
    _from = _to = _nums(widget.value);
  }

  @override
  void didUpdateWidget(_Roll old) {
    super.didUpdateWidget(old);
    if (old.value == widget.value) return;
    final next = _nums(widget.value);
    final sameShape = !widget.value.contains(':') &&
        next.length == _to.length &&
        widget.value.replaceAll(_num, '#') == old.value.replaceAll(_num, '#');
    if (!sameShape) {
      _from = _to = next;
      _up = false;
      _c.value = 1;
      return;
    }
    final now = _current();
    _up = false;
    for (var i = 0; i < next.length; i++) {
      if (next[i] > now[i]) _up = true;
    }
    _from = now;
    _to = next;
    _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  List<int> _current() {
    final e = Curves.easeOutCubic.transform(_c.value);
    return [for (var i = 0; i < _to.length; i++) (_from[i] + (_to[i] - _from[i]) * e).round()];
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        var text = widget.value;
        if (_c.isAnimating) {
          final cur = _current();
          var i = 0;
          text = widget.value.replaceAllMapped(_num, (m) => i < cur.length ? '${cur[i++]}' : m[0]!);
        }
        final g = _up && _c.isAnimating ? math.sin(math.pi * _c.value) : 0.0;
        return Transform.scale(
          scale: 1 + 0.08 * g,
          child: Text(
            text,
            style: widget.style.copyWith(
              color: Color.lerp(widget.style.color, Colors.white, 0.55 * g),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        );
      },
    );
  }
}
