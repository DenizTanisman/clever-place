// Düşen Bloklar well gesture tests: direction lock, drift undo, soft/hard drop, tap.
// Run with `flutter test test/falling_blocks_gesture_test.dart`.

import 'package:clever_place/clever/games/falling_blocks_gesture.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake well: tracks the piece column (0..9) and records every action sent.
class FakeWell {
  int col;
  final List<String> log = [];
  FakeWell([this.col = 4]);

  bool send(String a) {
    log.add(a);
    if (a == 'l' && col > 0) {
      col--;
      return true;
    }
    if (a == 'r' && col < 9) {
      col++;
      return true;
    }
    return a != 'l' && a != 'r';
  }
}

const cell = 27.0;

/// Drives a gesture along straight segments, one sample every [dtMs] ms with [px] pixels per sample.
class Finger {
  final WellGesture g;
  int t = 0;
  Offset p;
  Finger(this.g, [this.p = const Offset(130, 100)]) {
    g.down(t, p);
  }

  void to(Offset target, {double px = 4, int dtMs = 8}) {
    final d = target - p;
    final n = (d.distance / px).ceil().clamp(1, 10000);
    final start = p;
    for (var i = 1; i <= n; i++) {
      t += dtMs;
      p = start + d * (i / n);
      g.move(t, p);
    }
  }

  void by(double dx, double dy, {double px = 4, int dtMs = 8}) => to(p + Offset(dx, dy), px: px, dtMs: dtMs);

  void wait(int ms) {
    t += ms;
    g.move(t, p);
  }

  void up() => g.up(t);
}

void main() {
  late FakeWell well;
  late WellGesture g;
  setUp(() {
    well = FakeWell();
    g = WellGesture(well.send)..cell = cell;
  });

  test('fast drop swipe with sideways drift hard-drops in the starting column', () {
    final f = Finger(g);
    // 220 px down in ~70 ms with 1.2 cells of drift to the right spread over the swipe.
    f.by(cell * 1.2, 220, px: 25, dtMs: 8);
    f.up();
    expect(g.axis, WellAxis.vertical);
    expect(well.col, 4);
    expect(well.log.where((a) => a == 'r' || a == 'l'), isEmpty);
    expect(well.log.last, 'hd');
  });

  test('drift at the ambiguous start does not shift the drop column', () {
    final f = Finger(g);
    f.by(cell * 0.9, 6, px: 3); // finger rolls sideways first (below the dead zone)
    f.by(4, 240, px: 24); // then the real downward flick
    f.up();
    expect(well.col, 4);
    expect(well.log, ['hd']);
  });

  test('a lateral step fired by drift during the drop is undone', () {
    final f = Finger(g);
    f.by(cell * 2.6, 0, px: 3); // deliberate: two columns right, residual 0.75 cell
    expect(well.col, 6);
    f.wait(60);
    // Downward swipe whose start wanders right (still dy > 1.5·dx): the residual crosses a step
    // before the swipe has gone far enough down to lock.
    f.by(cell * 0.3, cell * 0.48, px: 3);
    expect(well.col, 7, reason: 'drift fired a step before the lock');
    f.by(cell * 0.3, cell * 5, px: 20);
    f.up();
    expect(g.axis, WellAxis.vertical);
    expect(well.col, 6, reason: 'deliberate moves stay, drift is undone');
    expect(well.log.last, 'hd');
  });

  test('after the vertical lock horizontal movement is ignored', () {
    final f = Finger(g);
    f.by(0, cell * 1.0, px: 2, dtMs: 16); // slow drag down: locks vertical
    expect(g.axis, WellAxis.vertical);
    f.by(cell * 3, 0, px: 2, dtMs: 16);
    expect(well.col, 4);
    f.up();
  });

  test('horizontal drag moves cell by cell after a slightly larger dead zone', () {
    final f = Finger(g);
    f.by(cell * 0.95, 0, px: 2);
    expect(well.col, 4, reason: 'dead zone before the first step');
    f.by(cell * 0.1, 0, px: 2);
    expect(well.col, 5);
    f.by(cell * 0.85, 0, px: 2);
    expect(well.col, 6);
    f.by(-cell * (0.85 * 3 + 0.1), 0, px: 2); // +0.05 cell residual from the right drag
    expect(well.col, 3);
    f.up();
    expect(well.log.where((a) => a != 'r' && a != 'l'), isEmpty, reason: 'no rotate or drop');
  });

  test('horizontal drag with a little vertical wobble still moves precisely', () {
    final f = Finger(g);
    for (var i = 0; i < 4; i++) {
      f.by(cell * 0.5, 5, px: 2);
      f.by(cell * 0.5, -5, px: 2);
    }
    expect(g.axis, WellAxis.horizontal);
    expect(well.col, 8); // 4 cells of travel: first at 1.0, then 1.85, 2.7, 3.55
    expect(well.log.contains('d'), isFalse);
  });

  test('drag sideways then flick down keeps the new column', () {
    final f = Finger(g);
    f.by(-cell * 1.9, 0, px: 3);
    expect(well.col, 2);
    f.by(0, 200, px: 25);
    f.up();
    expect(well.col, 2);
    expect(well.log.last, 'hd');
  });

  test('slow downward drag soft-drops about one row per cell', () {
    final f = Finger(g);
    f.by(0, cell * 4.6, px: 2, dtMs: 16); // 0.125 px/ms
    f.up();
    expect(well.log.where((a) => a == 'd').length, 5);
    expect(well.log.contains('hd'), isFalse);
  });

  test('tap rotates, upward flick holds', () {
    var f = Finger(g);
    f.wait(80);
    f.up();
    expect(well.log, ['cw']);
    well.log.clear();
    f = Finger(g);
    f.by(0, -150, px: 25);
    f.up();
    expect(well.log, ['hold']);
  });

  test('steps of an earlier piece are never undone', () {
    final f = Finger(g);
    f.by(cell * 1.1, 0, px: 3);
    expect(well.col, 5);
    g.newPiece(); // the piece locked under gravity mid-gesture, a new one spawned
    well.col = 4;
    f.by(0, 200, px: 25);
    f.up();
    expect(well.col, 4);
  });
}
