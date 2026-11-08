// Scramble memory for Not › Küp: 3x3 random-state scrambles with a CFOP
// analysis each, 4x4 random-move scrambles.
//
//   dart compile exe tool/cube/gen.dart -o /tmp/cube_gen
//   /tmp/cube_gen --n333 1000 --n444 500      (proje kökünden)
//
// Writes assets/cube/333.json and 444.json. Every scramble and every move
// sequence in the analysis is replayed on the sticker simulator (cubie.dart
// `Facelets`) before it is written.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'cfop.dart';
import 'cubie.dart';
import 'twophase.dart';

const colors = ['W', 'Y', 'G', 'B', 'R', 'O'];
const colorTr = {
  'W': 'Beyaz', 'Y': 'Sarı', 'G': 'Yeşil', 'B': 'Mavi', 'R': 'Kırmızı', 'O': 'Turuncu',
};
const slotTr = {'FR': 'ön sağ', 'FL': 'ön sol', 'BL': 'arka sol', 'BR': 'arka sağ'};
const shapeTr = {'dot': 'nokta', 'L': 'L', 'line': 'çizgi', 'cross': 'artı'};
const ollTr = {
  'Sune': 'Sune', 'Antisune': 'Antisune', 'H': 'H', 'Pi': 'Pi',
  'Headlights': 'Farlar', 'T': 'T', 'Bowtie': 'Papyon',
};
const skipTr = {
  'll': 'son katman tamamen atlanıyor (LL skip)',
  'oll': 'OLL skip geliyor',
  'pll': 'PLL skip geliyor',
  'edges': 'sarı artı hazır geliyor',
};

Cubie randomState(Random r) {
  List<int> perm(int n) => List.generate(n, (i) => i)..shuffle(r);
  int parity(List<int> p) {
    var s = 0;
    for (var i = 0; i < p.length; i++) {
      for (var j = i + 1; j < p.length; j++) {
        if (p[j] < p[i]) s++;
      }
    }
    return s % 2;
  }

  final cp = perm(8), ep = perm(12);
  if (parity(cp) != parity(ep)) {
    final t = ep[0];
    ep[0] = ep[1];
    ep[1] = t;
  }
  final co = List.generate(8, (_) => r.nextInt(3));
  co[7] = (3 - co.sublist(0, 7).fold(0, (a, b) => a + b) % 3) % 3;
  final eo = List.generate(12, (_) => r.nextInt(2));
  eo[11] = eo.sublist(0, 11).fold(0, (a, b) => a + b) % 2;
  return Cubie(cp, co, ep, eo);
}

String _list(List<String> xs) => xs.length == 1
    ? xs.first
    : '${xs.sublist(0, xs.length - 1).join(', ')} ve ${xs.last}';

class Analyzer {
  final TwoPhase tp = TwoPhase();
  final Tables tables;
  late final F2L f2l = F2L(tables);
  final LastLayer ll = LastLayer();
  int verified = 0;
  Analyzer(String cacheDir) : tables = Tables.loadOrBuild(cacheDir);

  List<int> newScramble(Random r) {
    while (true) {
      final c = randomState(r);
      final sol = tp.solve(c, maxLen: 21) ?? tp.solve(c, maxLen: 22) ?? tp.solve(c, maxLen: 23);
      if (sol == null || sol.length < 10) continue;
      final scr = [for (final m in sol.reversed) invMove(m)];
      // Check on the sticker simulator: the scramble must give exactly c.
      final f = Facelets()..apply(movesToString(scr));
      if (!f.toCubie()!.sameAs(c)) throw StateError('scramble check');
      return scr;
    }
  }

  Cubie _check(String scr, String rot, List<String> seqs) {
    final f = Facelets()
      ..apply(scr)
      ..apply(rot);
    for (final s in seqs) {
      f.apply(s);
    }
    return f.toCubie()!;
  }

  Map<String, Object> analyze(List<int> scr) {
    final s = movesToString(scr);
    final frames = {
      for (final k in colors) k: Cubie.solved().apply(mapThroughRotation(scr, rotations[k]!)),
    };

    final cross = <String, Map<String, Object>>{};
    final xcross = <String, Map<String, Object>>{};
    for (final k in colors) {
      final rot = rotations[k]!;
      f2l.load(frames[k]!);
      final sol = f2l.shortest(0, 8)!;
      final m = movesToString(sol);
      if (!crossSolved(_check(s, rot, [m]))) throw StateError('cross check $k');
      cross[k] = {'n': sol.length, 'rot': rot, 'm': m};

      List<int>? best;
      var bestSlot = -1;
      for (var sl = 0; sl < 4; sl++) {
        f2l.load(frames[k]!);
        final x = f2l.shortest(1 << sl, best == null ? 11 : best.length - 1);
        if (x != null && (best == null || x.length < best.length)) {
          best = x;
          bestSlot = sl;
        }
      }
      if (best != null) {
        final xm = movesToString(best);
        final c = _check(s, rot, [xm]);
        if (!crossSolved(c) || !slotSolved(c, bestSlot)) throw StateError('xcross check $k');
        xcross[k] = {'n': best.length, 'slot': slotNames[bestSlot], 'rot': rot, 'm': xm};
      }
    }

    // Reference CFOP solve, white cross on D.
    final w = frames['W']!;
    final rot = rotations['W']!;
    f2l.load(w);
    final crossN = f2l.distance(0);
    final crossSols = f2l.all(0, crossN, 200);
    // Pick the optimal cross that leaves a pair solved or closest to solved.
    List<int> crossPick = crossSols.first;
    var pickScore = -1;
    var pickPair = -1;
    List<int> pickPairMoves = const [];
    for (final cs in crossSols) {
      final c1 = w.apply(cs);
      var score = 0, bestLen = 99, bestS = -1;
      List<int> bestMv = const [];
      for (var sl = 0; sl < 4; sl++) {
        f2l.load(c1);
        final p = f2l.shortest(1 << sl, 3, slotMoves[sl]);
        if (p == null) continue;
        score += p.isEmpty ? 10 : 4 - p.length;
        if (p.length < bestLen) {
          bestLen = p.length;
          bestS = sl;
          bestMv = p;
        }
      }
      if (score > pickScore) {
        pickScore = score;
        crossPick = cs;
        pickPair = bestS;
        pickPairMoves = bestMv;
      }
    }

    List<int> pairsFrom(Cubie start, int solvedMask, List<Map<String, Object>> steps,
        void Function(Cubie beforeLast, int slot, int len, bool natural) onLast) {
      var cur = start;
      var mask = solvedMask;
      final total = <int>[];
      while (mask != 15) {
        final remaining = [for (var sl = 0; sl < 4; sl++) if (mask & (1 << sl) == 0) sl];
        f2l.load(cur);
        List<int>? found;
        var slot = -1;
        var natural = true;
        for (var L = 0; L <= 12 && found == null; L++) {
          for (final t in remaining) {
            final p = f2l.atDepth(mask | (1 << t), L, slotMoves[t]);
            if (p != null) {
              found = p;
              slot = t;
              break;
            }
          }
        }
        // A piece stuck in another slot needs more faces.
        for (var L = 0; L <= 18 && found == null; L++) {
          natural = false;
          for (final t in remaining) {
            final p = f2l.atDepth(mask | (1 << t), L, noDMoves);
            if (p != null) {
              found = p;
              slot = t;
              break;
            }
          }
        }
        if (remaining.length == 1) onLast(cur, slot, found!.length, natural);
        steps.add({'k': 'pair', 'slot': slotNames[slot], 'm': movesToString(found!)});
        cur = cur.apply(found);
        total.addAll(found);
        mask |= 1 << slot;
      }
      return total;
    }

    // Plan A: chosen cross, then pairs. Plan B: x-cross, then pairs.
    final cA = w.apply(crossPick);
    f2l.load(cA);
    var firstPair = 99;
    for (var sl = 0; sl < 4; sl++) {
      f2l.load(cA);
      final p = f2l.shortest(1 << sl, 12, slotMoves[sl]) ?? f2l.shortest(1 << sl, 12, noDMoves);
      if (p != null && p.length < firstPair) firstPair = p.length;
    }
    final xw = xcross['W'];
    final useX = xw != null && (xw['n'] as int) < crossN + firstPair;

    final steps = <Map<String, Object>>[];
    Cubie start;
    int mask;
    if (useX) {
      final xm = parseFaceMoves(xw['m'] as String);
      steps.add({'k': 'xcross', 'slot': xw['slot']!, 'm': xw['m']!});
      start = w.apply(xm);
      mask = 1 << slotNames.indexOf(xw['slot'] as String);
    } else {
      steps.add({'k': 'cross', 'm': movesToString(crossPick)});
      start = cA;
      mask = 0;
    }
    late Cubie beforeLast;
    late int lastSlot, lastLen;
    late bool lastNatural;
    pairsFrom(start, mask, steps, (c, sl, len, nat) {
      beforeLast = c;
      lastSlot = sl;
      lastLen = len;
      lastNatural = nat;
    });
    final seqs = [for (final st in steps) st['m'] as String];
    final end = _check(s, rot, seqs);
    if (!f2lSolved(end)) throw StateError('ref F2L check');
    final cls = ll.classify(end);
    final f2lN = seqs.fold<int>(0, (a, m) => a + (m.isEmpty ? 0 : m.split(' ').length));

    // Other ways to put the last pair in, up to two moves longer.
    final has = {
      'll': ll.solvedUpToAuf(end),
      'oll': cls.oll == 'skip',
      'pll': cls.pll == 'skip',
      'edges': edgesOriented(end),
    };
    final found = <String, List<int>>{};
    f2l.load(beforeLast);
    for (var L = lastLen; L <= lastLen + 2; L++) {
      for (final alt in f2l.all(15, L, 3000, lastNatural ? slotMoves[lastSlot] : noDMoves)) {
        final c = beforeLast.apply(alt);
        final kinds = <String>[];
        if (ll.solvedUpToAuf(c)) kinds.add('ll');
        if (llOriented(c)) kinds.add('oll');
        if (edgesOriented(c)) kinds.add('edges');
        if (!kinds.contains('ll') && ll.classify(c).pll == 'skip') kinds.add('pll');
        for (final k in kinds) {
          if (has[k]! || found.containsKey(k)) continue;
          found[k] = alt;
        }
      }
    }
    final skips = <Map<String, Object>>[];
    final usedMoves = <String>{};
    for (final k in ['ll', 'oll', 'pll', 'edges']) {
      final alt = found[k];
      if (alt == null) continue;
      final m = movesToString(alt);
      if (k != 'edges' && usedMoves.contains(m)) continue;
      usedMoves.add(m);
      // Replay on the sticker simulator with the last pair swapped.
      final c = _check(s, rot, [...seqs.sublist(0, seqs.length - 1), m]);
      if (!f2lSolved(c)) throw StateError('skip check');
      final ok = switch (k) {
        'll' => ll.solvedUpToAuf(c),
        'oll' => llOriented(c),
        'pll' => ll.classify(c).pll == 'skip',
        _ => edgesOriented(c),
      };
      if (!ok) throw StateError('skip check $k');
      final slotName = slotNames[lastSlot];
      String note = 'Son çifti (${slotTr[slotName]}) $m ile sokarsan ${skipTr[k]}.';
      if (k == 'pll') {
        final o = ll.classify(c);
        if (o.oll != 'skip' && o.oll != 'none') note += ' OLL: ${ollTr[o.oll]}.';
      }
      skips.add({'k': k, 'slot': slotName, 'm': m, 'note': note});
    }

    // Tips.
    final tips = <String>[];
    final wn = cross['W']!['n'] as int;
    final bestN = colors.map((k) => cross[k]!['n'] as int).reduce(min);
    final bestCols = [for (final k in colors) if (cross[k]!['n'] == bestN) k];
    if (bestN < wn) {
      tips.add('Beyaz artı $wn hamle; ${_list([for (final k in bestCols) colorTr[k]!])} '
          'artı $bestN hamle (${wn - bestN} hamle kısa).');
    } else {
      final others = [for (final k in bestCols) if (k != 'W') colorTr[k]!];
      tips.add('Beyaz artı $wn hamle, bu karıştırmanın en kısa artısı'
          '${others.isEmpty ? '' : ' (${_list(others)} ile eşit)'}.');
    }
    if (xw != null) {
      tips.add('Beyaz x-cross ${xw['n']} hamle (${slotTr[xw['slot']]} çift ile): '
          'z2, sonra ${xw['m']}.');
    }
    if (!useX && pickPair >= 0) {
      final cm = movesToString(crossPick);
      final sn = slotTr[slotNames[pickPair]];
      tips.add(pickPairMoves.isEmpty
          ? 'Artıyı $cm ile yaparsan $sn çift kendiliğinden yerinde kalıyor.'
          : 'Artıyı $cm ile yaparsan $sn çift ${pickPairMoves.length} hamlede giriyor: '
              '${movesToString(pickPairMoves)}.');
    }
    final llParts = <String>[];
    if (cls.oll == 'skip') {
      llParts.add('OLL skip');
    } else {
      if (cls.edges != 'cross') llParts.add('${shapeTr[cls.edges]} (sarı artı)');
      if (cls.oll != 'none') llParts.add(ollTr[cls.oll]!);
    }
    llParts.add(cls.pll == 'skip' ? 'PLL skip' : '${cls.pll}-perm');
    tips.add('Bu referans çözümde son katman: ${llParts.join(' → ')}.');
    if (skips.isNotEmpty) tips.add(skips.first['note'] as String);

    verified++;
    return {
      's': s,
      'a': {
        'cross': cross,
        'xcross': xcross,
        'ref': {
          'rot': rot,
          'steps': steps,
          'n': f2lN,
          'nll': cls.algMoves,
          'oll': cls.oll,
          'edges': cls.edges,
          'pll': cls.pll,
        },
        'skips': skips,
        'tips': tips.take(5).toList(),
      },
    };
  }
}

List<Map<String, Object>> _work(int count, String cacheDir, int id) {
  final a = Analyzer(cacheDir);
  final r = Random.secure();
  final out = <Map<String, Object>>[];
  final sw = Stopwatch()..start();
  for (var i = 0; i < count; i++) {
    out.add(a.analyze(a.newScramble(r)));
    if ((i + 1) % 10 == 0) {
      stdout.writeln('[$id] ${i + 1}/$count  ${(sw.elapsedMilliseconds / (i + 1)).round()} ms/karıştırma');
    }
  }
  return out;
}

/// 4x4 random-move: axes U/Uw/D, R/Rw/L, F/Fw/B; a run on one axis turns
/// each layer set at most once, in this order.
String scramble444(Random r, int len) {
  const axes = [
    ['U', 'Uw', 'D'],
    ['R', 'Rw', 'L'],
    ['F', 'Fw', 'B'],
  ];
  final out = <String>[];
  var lastAxis = -1, lastType = -1;
  while (out.length < len) {
    final a = r.nextInt(3), t = r.nextInt(3);
    if (a == lastAxis && t <= lastType) continue;
    out.add(axes[a][t] + const ['', '2', "'"][r.nextInt(3)]);
    lastAxis = a;
    lastType = t;
  }
  return out.join(' ');
}

Future<void> main(List<String> args) async {
  int arg(String name, int def) {
    final i = args.indexOf(name);
    return i >= 0 ? int.parse(args[i + 1]) : def;
  }

  final n333 = arg('--n333', 1000), n444 = arg('--n444', 500);
  final jobs = arg('--jobs', Platform.numberOfProcessors);
  final root = args.contains('--root') ? args[args.indexOf('--root') + 1] : Directory.current.path;
  if (!File('$root/pubspec.yaml').existsSync()) {
    stderr.writeln('Proje kökünden çalıştır (ya da --root ver).');
    exit(2);
  }
  final outDir = args.contains('--out') ? args[args.indexOf('--out') + 1] : '$root/assets/cube';
  final cacheDir = '$root/tool/cube/.cache';
  final date = DateTime.now().toIso8601String().substring(0, 10);
  Directory(outDir).createSync(recursive: true);

  final sw = Stopwatch()..start();
  Tables.loadOrBuild(cacheDir);
  LastLayer().selfCheck();
  stdout.writeln('tablolar hazır (${sw.elapsedMilliseconds} ms), $jobs iş parçacığı');

  final per = List.generate(jobs, (i) => n333 ~/ jobs + (i < n333 % jobs ? 1 : 0));
  final parts = await Future.wait([
    for (var i = 0; i < jobs; i++)
      if (per[i] > 0) Isolate.run(() => _work(per[i], cacheDir, i)),
  ]);
  final s333 = [for (final p in parts) ...p];
  File('$outDir/333.json').writeAsStringSync(jsonEncode(
      {'puzzle': '333', 'version': 1, 'generated': date, 'scrambles': s333}));

  final r = Random.secure();
  final s444 = [for (var i = 0; i < n444; i++) {'s': scramble444(r, 40)}];
  File('$outDir/444.json').writeAsStringSync(jsonEncode(
      {'puzzle': '444', 'version': 1, 'generated': date, 'scrambles': s444}));
  stdout.writeln('bitti: ${s333.length} 3x3 (hepsi simülatörde doğrulandı), '
      '${s444.length} 4x4, ${(sw.elapsedMilliseconds / 1000).round()} s');
}
