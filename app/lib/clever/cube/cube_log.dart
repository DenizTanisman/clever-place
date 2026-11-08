import 'dart:convert';

/// Küp zamanlayıcı sessions: 3x3 iki el, 3x3 tek el, 4x4.
enum CubeSession {
  three('333', '3x3', 3),
  threeOh('333oh', '3x3 tek el', 3),
  four('444', '4x4', 4);

  const CubeSession(this.id, this.label, this.size);

  final String id;
  final String label;
  final int size;

  /// The stored scramble list it draws from; tek el shares the 3x3 one.
  String get bank => size == 3 ? '333' : '444';

  static CubeSession byId(String? id) =>
      values.firstWhere((s) => s.id == id, orElse: () => three);
}

enum Penalty { none, plus2, dnf }

/// WCA inspection: up to 15 s free, up to 17 s +2, after that DNF.
Penalty inspectionPenalty(int inspectionMs) => inspectionMs <= 15000
    ? Penalty.none
    : inspectionMs <= 17000
    ? Penalty.plus2
    : Penalty.dnf;

class CubeSolve {
  const CubeSolve({
    required this.session,
    required this.ms,
    this.penalty = Penalty.none,
    this.scramble,
    this.index,
    required this.at,
  });

  final CubeSession session;

  /// Raw time on the timer, penalties not added.
  final int ms;
  final Penalty penalty;

  /// Null for a free-run solve (only the time was taken).
  final String? scramble;

  /// Position of [scramble] in its stored list, for the analysis.
  final int? index;

  /// Milliseconds since epoch when it was stopped.
  final int at;

  /// What counts: +2 added, null for DNF.
  int? get result => switch (penalty) {
    Penalty.none => ms,
    Penalty.plus2 => ms + 2000,
    Penalty.dnf => null,
  };

  CubeSolve withPenalty(Penalty p) => CubeSolve(
    session: session,
    ms: ms,
    penalty: p,
    scramble: scramble,
    index: index,
    at: at,
  );

  Map<String, Object?> toJson() => {
    's': session.id,
    'ms': ms,
    if (penalty != Penalty.none) 'p': penalty.index,
    if (scramble != null) 'sc': scramble,
    if (index != null) 'i': index,
    'at': at,
  };

  static CubeSolve? fromJson(Object? raw) {
    if (raw is! Map || raw['ms'] is! int || raw['at'] is! int) return null;
    final p = raw['p'];
    return CubeSolve(
      session: CubeSession.byId(raw['s'] as String?),
      ms: raw['ms'] as int,
      penalty: p is int && p >= 0 && p < Penalty.values.length
          ? Penalty.values[p]
          : Penalty.none,
      scramble: raw['sc'] is String ? raw['sc'] as String : null,
      index: raw['i'] is int ? raw['i'] as int : null,
      at: raw['at'] as int,
    );
  }
}

/// Every solve, where each stored scramble list has got to, and the
/// timer's choices. Kept as JSON in SharedPreferences ([storageKey]).
class CubeLog {
  const CubeLog({
    this.solves = const [],
    this.next = const {},
    this.session = CubeSession.three,
    this.scrambled = true,
  });

  static const storageKey = 'cp.cube.log';

  /// Oldest first; capped at [maxSolves].
  final List<CubeSolve> solves;
  static const maxSolves = 3000;

  /// Bank id → index of the next unused scramble.
  final Map<String, int> next;
  final CubeSession session;

  /// Scramble + 15 s inspection, or just the time.
  final bool scrambled;

  List<CubeSolve> of(CubeSession s) => [
    for (final x in solves)
      if (x.session == s) x,
  ];

  CubeLog copyWith({
    List<CubeSolve>? solves,
    Map<String, int>? next,
    CubeSession? session,
    bool? scrambled,
  }) => CubeLog(
    solves: solves ?? this.solves,
    next: next ?? this.next,
    session: session ?? this.session,
    scrambled: scrambled ?? this.scrambled,
  );

  CubeLog add(CubeSolve solve) {
    final all = [...solves, solve];
    return copyWith(
      solves: all.length > maxSolves
          ? all.sublist(all.length - maxSolves)
          : all,
    );
  }

  /// Replaces the solve stopped at [at] (they are unique), or drops it.
  CubeLog replace(int at, CubeSolve? solve) => copyWith(
    solves: [
      for (final s in solves)
        if (s.at != at) s else if (solve != null) solve,
    ],
  );

  CubeLog advance(String bank, int length) => copyWith(
    next: {...next, bank: ((next[bank] ?? 0) + 1) % (length < 1 ? 1 : length)},
  );

  String encode() => jsonEncode({
    'v': 1,
    'solves': [for (final s in solves) s.toJson()],
    'next': next,
    'session': session.id,
    'scrambled': scrambled,
  });

  static CubeLog decode(String? raw) {
    if (raw == null || raw.isEmpty) return const CubeLog();
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return const CubeLog();
      final next = m['next'];
      return CubeLog(
        solves: [
          for (final s in (m['solves'] as List? ?? const []))
            if (CubeSolve.fromJson(s) case final solve?) solve,
        ],
        next: {
          if (next is Map)
            for (final e in next.entries)
              if (e.key is String && e.value is int)
                e.key as String: e.value as int,
        },
        session: CubeSession.byId(m['session'] as String?),
        scrambled: m['scrambled'] != false,
      );
    } on FormatException {
      return const CubeLog();
    }
  }
}

/// Marks a DNF average apart from "not enough solves yet".
const dnfAverage = -1;

/// WCA average of the last [count] solves: drop the best and the worst
/// (5 % each side from 13 solves up), mean of the rest. DNFs count as the
/// worst; more DNFs than are dropped make the average a DNF. Null until
/// there are [count] solves.
int? averageOf(List<CubeSolve> solves, int count) {
  if (solves.length < count) return null;
  final last = solves.sublist(solves.length - count);
  final trim = count <= 12 ? 1 : (count * 0.05).ceil();
  final times = [for (final s in last) s.result];
  final dnfs = times.where((t) => t == null).length;
  if (dnfs > trim) return dnfAverage;
  final kept = (times.whereType<int>().toList()..sort());
  final counted = kept.sublist(trim, kept.length - (trim - dnfs));
  return (counted.reduce((a, b) => a + b) / counted.length).round();
}

int? bestOf(List<CubeSolve> solves) {
  int? best;
  for (final s in solves) {
    final r = s.result;
    if (r != null && (best == null || r < best)) best = r;
  }
  return best;
}

/// `9.87`, `1:02.35`; WCA truncates to hundredths.
String formatCubeTime(int ms) {
  final cs = ms ~/ 10;
  final minutes = cs ~/ 6000;
  final seconds = (cs % 6000) ~/ 100;
  final hundredths = (cs % 100).toString().padLeft(2, '0');
  return minutes > 0
      ? '$minutes:${seconds.toString().padLeft(2, '0')}.$hundredths'
      : '$seconds.$hundredths';
}

String formatSolve(CubeSolve s) => switch (s.penalty) {
  Penalty.none => formatCubeTime(s.ms),
  Penalty.plus2 => '${formatCubeTime(s.ms + 2000)}+',
  Penalty.dnf => 'DNF',
};

String formatAverage(int? avg) =>
    avg == null ? '–' : (avg == dnfAverage ? 'DNF' : formatCubeTime(avg));
