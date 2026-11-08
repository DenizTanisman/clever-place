import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:clever_place/clever/cube/cube_log.dart';
import 'package:clever_place/clever/cube/cube_net.dart';

String invert(String alg) => alg
    .split(' ')
    .reversed
    .map(
      (t) => t.endsWith("'")
          ? t.substring(0, t.length - 1)
          : t.endsWith('2')
          ? t
          : "$t'",
    )
    .join(' ');

void main() {
  group('CubeNet', () {
    test('a face turn four times is no turn', () {
      for (final f in 'URFDLB'.split('')) {
        expect(CubeNet.scrambled(3, '$f $f $f $f').isSolved, isTrue, reason: f);
        expect(CubeNet.scrambled(3, f).isSolved, isFalse, reason: f);
        expect(CubeNet.scrambled(4, '${f}w2 ${f}w2').isSolved, isTrue);
      }
    });

    test('sexy move six times is no turn', () {
      final alg = List.filled(6, "R U R' U'").join(' ');
      expect(CubeNet.scrambled(3, alg).isSolved, isTrue);
    });

    test('a scramble and its inverse cancel, 3x3 and 4x4', () {
      final rnd = Random(7);
      for (final n in [3, 4]) {
        for (var i = 0; i < 20; i++) {
          final s = randomMoveScramble(n, random: rnd);
          expect(CubeNet.scrambled(n, s).isSolved, isFalse);
          expect(CubeNet.scrambled(n, '$s ${invert(s)}').isSolved, isTrue);
        }
      }
    });

    test('R moves the front column to the top, clockwise', () {
      final cube = CubeNet.scrambled(3, 'R');
      // U's right column is now green (from F), F's right column yellow.
      expect([
        for (final r in cube.grid(CubeFace.u)) r[2],
      ], everyElement(CubeFace.f));
      expect([
        for (final r in cube.grid(CubeFace.f)) r[2],
      ], everyElement(CubeFace.d));
      expect(cube.grid(CubeFace.u)[0][0], CubeFace.u);
    });

    test('U turns the front row to the left', () {
      final cube = CubeNet.scrambled(3, 'U');
      expect(cube.grid(CubeFace.l)[0], everyElement(CubeFace.f));
      expect(cube.grid(CubeFace.f)[0], everyElement(CubeFace.r));
    });

    test('F turns the top row onto the right face', () {
      final cube = CubeNet.scrambled(3, 'F');
      expect([
        for (final r in cube.grid(CubeFace.r)) r[0],
      ], everyElement(CubeFace.u));
    });

    test('wide and lowercase turns are the same', () {
      final a = CubeNet.scrambled(4, "Rw U Fw' r2");
      final b = CubeNet.scrambled(4, "r U f' Rw2");
      for (final f in CubeFace.values) {
        expect(a.grid(f), b.grid(f));
      }
    });
  });

  group('CubeLog', () {
    CubeSolve s(int ms, [Penalty p = Penalty.none]) =>
        CubeSolve(session: CubeSession.three, ms: ms, penalty: p, at: ms);

    test('ao5 drops best and worst', () {
      final xs = [s(10000), s(12000), s(11000), s(30000), s(9000)];
      expect(averageOf(xs, 5), 11000);
      expect(averageOf(xs.sublist(1), 5), isNull);
    });

    test('one DNF is the dropped worst, two make a DNF', () {
      expect(
        averageOf([
          s(10000),
          s(12000),
          s(11000),
          s(1, Penalty.dnf),
          s(9000),
        ], 5),
        11000,
      );
      expect(
        averageOf([
          s(10000),
          s(2, Penalty.dnf),
          s(11000),
          s(1, Penalty.dnf),
          s(9000),
        ], 5),
        dnfAverage,
      );
    });

    test('+2 counts in the result', () {
      expect(s(10000, Penalty.plus2).result, 12000);
      expect(formatSolve(s(10000, Penalty.plus2)), '12.00+');
    });

    test('inspection penalties', () {
      expect(inspectionPenalty(15000), Penalty.none);
      expect(inspectionPenalty(15001), Penalty.plus2);
      expect(inspectionPenalty(17000), Penalty.plus2);
      expect(inspectionPenalty(17001), Penalty.dnf);
    });

    test('times are truncated to hundredths', () {
      expect(formatCubeTime(9879), '9.87');
      expect(formatCubeTime(62359), '1:02.35');
    });

    test('round trip keeps solves, pointers and choices', () {
      final log = const CubeLog()
          .add(s(12345, Penalty.plus2))
          .add(
            const CubeSolve(
              session: CubeSession.four,
              ms: 90000,
              scramble: 'Rw U',
              index: 3,
              at: 99,
            ),
          )
          .advance('333', 1000)
          .copyWith(session: CubeSession.threeOh, scrambled: false);
      final back = CubeLog.decode(log.encode());
      expect(back.solves.length, 2);
      expect(back.solves.first.penalty, Penalty.plus2);
      expect(back.solves.last.scramble, 'Rw U');
      expect(back.solves.last.index, 3);
      expect(back.next['333'], 1);
      expect(back.session, CubeSession.threeOh);
      expect(back.scrambled, isFalse);
      expect(CubeLog.decode('bozuk').solves, isEmpty);
    });

    test('pointer wraps at the end of the list', () {
      final log = const CubeLog(next: {'444': 499}).advance('444', 500);
      expect(log.next['444'], 0);
    });
  });
}
