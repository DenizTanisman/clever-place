// ignore_for_file: avoid_print
// Checks the generator's building blocks against each other:
//   dart run tool/cube/selftest.dart      (proje kökünden)
import 'dart:io';
import 'dart:math';

import 'cfop.dart';
import 'cubie.dart';
import 'gen.dart' show randomState;
import 'twophase.dart';

void main() {
  final r = Random(1);
  var bad = 0;
  // Cubie tables agree with the sticker simulator.
  for (var t = 0; t < 2000; t++) {
    final ms = List.generate(1 + r.nextInt(30), (_) => r.nextInt(18));
    final c = Cubie.solved().apply(ms);
    if (!c.sameAs((Facelets()..apply(movesToString(ms))).toCubie()!)) bad++;
    if (!c.mul(c.inverse()).sameAs(Cubie.solved())) bad++;
  }
  // Holding a color on D: mapped moves equal a real rotation.
  for (final rot in rotations.values) {
    for (var t = 0; t < 300; t++) {
      final ms = List.generate(25, (_) => r.nextInt(18));
      final a = (Facelets()
            ..apply(movesToString(ms))
            ..apply(rot))
          .toCubie()!;
      if (!a.sameAs(Cubie.solved().apply(mapThroughRotation(ms, rot)))) bad++;
    }
  }
  // Two-phase solves random states in ≤ 22.
  final tp = TwoPhase();
  for (var t = 0; t < 50; t++) {
    final c = randomState(r);
    final s = tp.solve(c, maxLen: 21) ?? tp.solve(c, maxLen: 22);
    if (s == null || !c.apply(s).sameAs(Cubie.solved())) bad++;
  }
  // Last-layer algorithms are what their names say and cover all 288 cases.
  LastLayer().selfCheck();
  print(bad == 0 ? 'tamam' : 'HATA: $bad');
  if (bad != 0) exit(1);
}
