import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One stored scramble and, for 3x3, what was worked out for it on the
/// Mac (tool/cube/): shortest crosses per colour, x-cross, a reference
/// CFOP solve, skips within reach and tips. The app only reads it.
class StoredScramble {
  const StoredScramble(this.moves, this.analysis);

  final String moves;
  final ScrambleAnalysis? analysis;
}

/// A colour's shortest cross (or x-cross): moves after turning the cube
/// with [rotation] so that colour is down.
class CrossPlan {
  const CrossPlan(this.count, this.rotation, this.moves, {this.slot});

  final int count;
  final String rotation;
  final String moves;
  final String? slot;

  static CrossPlan? fromJson(Object? raw) {
    if (raw is! Map || raw['n'] is! int) return null;
    return CrossPlan(
      raw['n'] as int,
      raw['rot'] as String? ?? '',
      raw['m'] as String? ?? '',
      slot: raw['slot'] as String?,
    );
  }
}

class SolveStep {
  const SolveStep(this.kind, this.moves, {this.slot});

  /// `cross`, `xcross` or `pair`.
  final String kind;
  final String moves;
  final String? slot;
}

class SkipChance {
  const SkipChance(this.kind, this.moves, this.note);

  /// `oll`, `pll`, `ll` or `edges`.
  final String kind;
  final String moves;
  final String note;
}

class ScrambleAnalysis {
  const ScrambleAnalysis({
    required this.cross,
    required this.xcross,
    required this.refRotation,
    required this.steps,
    required this.refCount,
    this.oll,
    this.edges,
    this.pll,
    required this.skips,
    required this.tips,
  });

  /// Colour key (W Y G B R O) → plan.
  final Map<String, CrossPlan> cross;
  final Map<String, CrossPlan> xcross;
  final String refRotation;
  final List<SolveStep> steps;
  final int? refCount;
  final String? oll, edges, pll;
  final List<SkipChance> skips;
  final List<String> tips;

  /// Tolerant: a field the generator left out is just missing here.
  static ScrambleAnalysis? fromJson(Object? raw) {
    if (raw is! Map) return null;
    Map<String, CrossPlan> plans(Object? m) => {
      if (m is Map)
        for (final e in m.entries)
          if (CrossPlan.fromJson(e.value) case final plan?) '${e.key}': plan,
    };
    final ref = raw['ref'] is Map ? raw['ref'] as Map : const {};
    return ScrambleAnalysis(
      cross: plans(raw['cross']),
      xcross: plans(raw['xcross']),
      refRotation: ref['rot'] as String? ?? '',
      steps: [
        for (final s in (ref['steps'] as List? ?? const []))
          if (s is Map && s['m'] is String)
            SolveStep(
              s['k'] as String? ?? 'pair',
              s['m'] as String,
              slot: s['slot'] as String?,
            ),
      ],
      refCount: ref['n'] as int?,
      oll: ref['oll'] as String?,
      edges: ref['edges'] as String?,
      pll: ref['pll'] as String?,
      skips: [
        for (final s in (raw['skips'] as List? ?? const []))
          if (s is Map && s['m'] is String)
            SkipChance(
              s['k'] as String? ?? '',
              s['m'] as String,
              s['note'] as String? ?? '',
            ),
      ],
      tips: [
        for (final t in (raw['tips'] as List? ?? const []))
          if (t is String) t,
      ],
    );
  }
}

/// The scrambles kept in the app (`assets/cube/<bank>.json`). An empty list
/// when the file is missing; the timer then makes random-move ones.
class ScrambleBank {
  const ScrambleBank(this.list);

  final List<StoredScramble> list;

  static final _cache = <String, Future<ScrambleBank>>{};

  /// Tests set this to skip the asset bundle.
  @visibleForTesting
  static Map<String, ScrambleBank>? debugBanks;

  static Future<ScrambleBank> load(String bank) {
    if (debugBanks case final banks?) {
      return SynchronousFuture(banks[bank] ?? const ScrambleBank([]));
    }
    return _cache[bank] ??= _load(bank);
  }

  static Future<ScrambleBank> _load(String bank) async {
    try {
      final raw = await rootBundle.loadString('assets/cube/$bank.json');
      return await compute(parse, raw);
    } on Object catch (e) {
      debugPrint('cube: no stored $bank scrambles ($e)');
      return const ScrambleBank([]);
    }
  }

  @visibleForTesting
  static ScrambleBank parse(String raw) {
    final m = jsonDecode(raw);
    final list = m is Map ? m['scrambles'] : null;
    return ScrambleBank([
      if (list is List)
        for (final s in list)
          if (s is Map && s['s'] is String)
            StoredScramble(s['s'] as String, ScrambleAnalysis.fromJson(s['a'])),
    ]);
  }
}
