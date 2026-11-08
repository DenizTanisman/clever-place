import 'dart:ui' show Offset;

/// Which way a one-finger gesture on the Düşen Bloklar well has been read.
enum WellAxis { none, horizontal, vertical }

/// One-finger gesture recogniser for the Düşen Bloklar well, kept free of widgets so it can be
/// unit-tested. It turns pointer samples into core actions through [send]:
/// - drag left/right = `l` / `r`, one per [step] cells of travel; the first step needs a slightly
///   larger dead zone ([firstStep]) and a horizontal-dominant drag;
/// - once the motion reads as a downward swipe (a run of path segments with dy > [ratio]·|dx|
///   covering [lockDist] cells), the gesture locks to vertical: horizontal travel is ignored for the
///   rest of it and every horizontal step fired during that downward run (finger drift) is undone,
///   so the piece drops in the column it was in when the drop began;
/// - slow downward drag (vertical lock) = soft drop `d`, one row per [softStep] cells;
/// - release with a fast downward flick = hard drop `hd` (drift undone the same way),
///   fast upward flick = `hold`, short still tap = `cw`.
class WellGesture {
  WellGesture(this.send);

  /// Sends one core action. Returns true when it changed the active piece (used to know which
  /// horizontal steps really moved it and so must be undone when drift is discarded).
  final bool Function(String action) send;

  /// Cell size in logical pixels.
  double cell = 24;

  /// Horizontal travel (cells) before the first lateral step; a bit more than [step] so a drop
  /// swipe that wanders sideways does not shift the piece at the very start.
  static const double firstStep = 1.0;

  /// Horizontal travel (cells) per further lateral step.
  static const double step = 0.85;

  /// Vertical travel (cells) per soft-drop row once locked to vertical.
  static const double softStep = 0.9;

  /// Downward, vertical-dominant travel (cells) that locks the gesture to vertical.
  static const double lockDist = 0.5;

  /// dy must exceed ratio·|dx| for a path segment to count as "downward".
  static const double ratio = 1.5;

  /// Length (cells) of the path segments used to judge direction (filters jitter).
  static const double segment = 0.4;

  /// Release velocity (px/ms) that counts as a flick; slower downward drags soft-drop instead.
  static const double flick = 1.0;
  static const double slowDrag = 0.9;
  static const double flickRatio = 1.4;

  /// Velocity window (ms).
  static const int window = 100;

  final List<(int, Offset)> _path = []; // (ms, position)
  int _base = 0; // absolute index of _path[0] (the path is trimmed on long gestures)
  final List<(int, int)> _steps = []; // (absolute sample index, ±1) of lateral steps that moved the piece
  Offset _origin = Offset.zero;
  int _downAt = 0;
  WellAxis _axis = WellAxis.none;
  double _ax = 0, _ay = 0;
  int _lockAt = 0; // absolute sample index where the downward run that locked the gesture began
  bool _moved = false;
  bool _active = false;

  WellAxis get axis => _axis;

  /// True once the finger travelled or the gesture fired an action (so it is not a tap).
  bool get moved => _moved;

  void down(int t, Offset p) {
    _path
      ..clear()
      ..add((t, p));
    _base = 0;
    _steps.clear();
    _origin = p;
    _downAt = t;
    _axis = WellAxis.none;
    _ax = 0;
    _ay = 0;
    _moved = false;
    _active = true;
  }

  /// A new piece spawned (lock, hold): earlier steps belonged to another piece, never undo them.
  void newPiece() => _steps.clear();

  void cancel() {
    _active = false;
    _steps.clear();
  }

  void move(int t, Offset p) {
    if (!_active || _path.isEmpty) return;
    final d = p - _path.last.$2;
    _path.add((t, p));
    _trim();
    if ((p - _origin).distance > 14) _moved = true;

    if (_axis == WellAxis.vertical) {
      _ay += d.dy;
      _softDrop();
      return;
    }

    // Has the recent motion become a downward swipe? Then lock to vertical and drop any drift.
    final tail = _tailStart();
    final td = p - _path[tail].$2;
    if (td.dy >= lockDist * cell) {
      _undoSince(_base + tail);
      _axis = WellAxis.vertical;
      _lockAt = _base + tail;
      _ay = td.dy;
      _moved = true;
      _softDrop();
      return;
    }

    if (_axis == WellAxis.none) {
      final total = p - _origin;
      if (total.dx.abs() < firstStep * cell || total.dx.abs() < total.dy.abs()) return;
      _axis = WellAxis.horizontal;
      // Start the accumulator so the first step fires exactly at [firstStep] cells.
      _ax = total.dx - total.dx.sign * (firstStep - step) * cell;
    } else {
      _ax += d.dx;
    }
    final s = step * cell;
    while (_ax >= s) {
      _lateral(1);
      _ax -= s;
    }
    while (_ax <= -s) {
      _lateral(-1);
      _ax += s;
    }
  }

  void up(int t) {
    if (!_active) return;
    _active = false;
    final v = velocity;
    final held = t - _downAt;
    if (v.dy > flick && v.dy > v.dx.abs() * flickRatio) {
      if (_axis != WellAxis.vertical) _undoSince(_base + _tailStart());
      send('hd');
    } else if (v.dy < -flick && -v.dy > v.dx.abs() * flickRatio) {
      send('hold');
    } else if (!_moved && held < 300) {
      send('cw');
    }
    _steps.clear();
  }

  /// Finger velocity (px/ms) over the last [window] ms.
  Offset get velocity => _velocitySince(0);

  /// Like [velocity] but ignoring samples before absolute index [from].
  Offset _velocitySince(int from) {
    if (_path.length < 2) return Offset.zero;
    final b = _path.last;
    final first = (from - _base).clamp(0, _path.length - 2);
    var i = _path.length - 2;
    while (i > first && b.$1 - _path[i - 1].$1 <= window) {
      i--;
    }
    final a = _path[i];
    final dt = (b.$1 - a.$1).clamp(1, 1000);
    return (b.$2 - a.$2) / dt.toDouble();
  }

  void _softDrop() {
    // Slow downward drag = one row per [softStep] cells. Fast flicks are left for the release.
    // Only the downward run counts, so a slow wobble before a flick does not soft-drop.
    if (_velocitySince(_lockAt).dy < slowDrag) {
      final s = softStep * cell;
      while (_ay >= s) {
        send('d');
        _ay -= s;
      }
    } else {
      _ay = 0;
    }
    if (_ay < 0) _ay = _ay.clamp(-softStep * cell * 3, 0);
  }

  void _lateral(int dir) {
    _moved = true;
    if (send(dir > 0 ? 'r' : 'l')) _steps.add((_base + _path.length - 1, dir));
  }

  /// Index into [_path] where the current downward run starts: walking back from the newest
  /// sample in segments of [segment] cells, the run continues while every segment points down
  /// with dy > [ratio]·|dx|. Reaching the first sample means the whole gesture is that run
  /// (including an ambiguous start shorter than one segment).
  int _tailStart() {
    final seg = segment * cell;
    var anchor = _path.length - 1;
    for (var j = _path.length - 2; j >= 0; j--) {
      final d = _path[anchor].$2 - _path[j].$2;
      if (d.distance < seg) continue;
      if (d.dy <= 0 || d.dy <= ratio * d.dx.abs()) return anchor;
      anchor = j;
    }
    return 0;
  }

  /// Undoes the lateral steps fired after absolute sample [index] (newest first).
  void _undoSince(int index) {
    while (_steps.isNotEmpty && _steps.last.$1 > index) {
      final s = _steps.removeLast();
      send(s.$2 > 0 ? 'l' : 'r');
    }
  }

  void _trim() {
    if (_path.length <= 600) return;
    _path.removeRange(0, 100);
    _base += 100;
  }
}
