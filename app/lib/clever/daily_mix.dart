import 'package:flutter/material.dart';

import 'catalog.dart';
import 'play_screen.dart';
import 'progress.dart';

/// "Günün hedefi": every day one game from each enabled category, picked at random under a rotation
/// (a game does not come back within 3 days, and every game of the category comes within n + 3 days),
/// kept for the whole day. Settings live in [Progress.dailyCategoryNames] / [Progress.dailyOnly], the
/// rotation in [Progress.mixLast] and friends; a pick is done once a level (or a match) of it is won
/// that day ([Progress.wonToday]).

/// The order the day's picks are played in: the default five first, then the rest of the hub.
const List<GameCategory> kDailyOrder = [
  GameCategory.memory,
  GameCategory.attention,
  GameCategory.logic,
  GameCategory.mind,
  GameCategory.strategy,
  GameCategory.cards,
  GameCategory.cube,
];

class DailySettings {
  final Set<GameCategory> categories;

  /// Per category, the only games its pick may come from; missing or empty = every game.
  final Map<GameCategory, Set<String>> only;

  const DailySettings({required this.categories, this.only = const {}});

  /// Hafıza, Dikkat, Mantık, Zihin antrenmanı (Mental Aritmetik only, never Soroban).
  static const defaults = DailySettings(
    categories: {
      GameCategory.memory,
      GameCategory.attention,
      GameCategory.logic,
      GameCategory.mind,
        },
    only: {
      GameCategory.mind: {'math'},
    },
  );

  /// The settings saved in [p] (defaults for whatever was never changed).
  factory DailySettings.of(Progress p) {
    final names = p.dailyCategoryNames;
    final cats = names == null
        ? defaults.categories
        : {for (final c in GameCategory.values) if (names.contains(c.name)) c};
    return DailySettings(categories: cats, only: {
      for (final c in GameCategory.values)
        if (p.dailyOnly(c.name)?.toSet() ?? defaults.only[c] case final ids?) c: ids,
    });
  }
}

/// A game the mix can hand out: a hub game run by the core with levels or match tables (not Soroban,
/// which lives inside Mental Aritmetik, nor Küp, which has its own screens).
bool dailyEligible(GameInfo g) =>
    g.inHub && g.customHome == null && g.view != null && (g.hasLevels || g.matchModes.isNotEmpty);

/// Every game of [c] the mix may pick, in catalogue order.
List<GameInfo> dailyCandidates(GameCategory c) =>
    [for (final g in kCoreGames) if (g.category == c && dailyEligible(g)) g];

/// The categories the settings can switch on (those with at least one candidate), in play order.
List<GameCategory> get dailyCategories => [for (final c in kDailyOrder) if (dailyCandidates(c).isNotEmpty) c];

/// The games [c]'s pick is drawn from under [s] (all candidates when the limit matches none of them).
List<GameInfo> dailyPool(GameCategory c, DailySettings s) {
  final all = dailyCandidates(c);
  final only = s.only[c];
  if (only == null || only.isEmpty) return all;
  final some = [for (final g in all) if (only.contains(g.id)) g];
  return some.isEmpty ? all : some;
}

class DailyPick {
  final GameCategory category;
  final GameInfo game;
  const DailyPick(this.category, this.game);
}

/// Days since 1970-01-01 for the local date of [d] (what the rotation counts in).
int dayNumber(DateTime d) => DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;

// ---- Rotation (owner's rule, 2026-11-14) ----
// In a category of n games, a game is not picked again within 3 days of its last pick, and every
// game is picked at least once in any n + 3 days. Small categories cannot keep 3 days apart: there
// the gap is n (2 games alternate, 1 game comes every day). Days the app is not opened do not count
// (see [MixHistory]), so the n + 3 holds over the days actually played.

/// The fewest days between two picks of the same game in a category of [n].
int mixMinGap(int n) => n < 3 ? n : 3;

/// The most days between two picks of the same game in a category of [n].
int mixMaxGap(int n) => n + 3;

/// Today's game out of [pool]. [last] holds the day number each game was last picked (missing = never),
/// [start] the day the rotation began. Picks at random ([seed]) among the games that are 3 days clear
/// and leave room for every other game to come before its n + 3 deadline (earliest-deadline-first
/// check, exact for one pick a day). If no such game exists (the state was broken by hand or by a
/// pool change), the most overdue clear game wins.
String mixPick({
  required List<String> pool,
  required Map<String, int> last,
  required int today,
  required int start,
  required int seed,
}) {
  final n = pool.length;
  if (n == 1) return pool.single;
  final gap = mixMinGap(n), w = mixMaxGap(n);
  // (release, deadline): the first and last day the game's next pick may fall on.
  (int, int) window(String id) => switch (last[id]) {
        final l? => (l + gap, l + w),
        null => (start, start + w - 1),
      };

  bool leavesRoom(String pick) {
    final jobs = [for (final id in pool) if (id != pick) window(id), (today + gap, today + w)];
    final done = List.filled(jobs.length, false);
    var left = jobs.length;
    for (var d = today + 1; left > 0; d++) {
      var best = -1;
      for (var i = 0; i < jobs.length; i++) {
        if (!done[i] && jobs[i].$1 <= d && (best < 0 || jobs[i].$2 < jobs[best].$2)) best = i;
      }
      if (best < 0) continue;
      if (jobs[best].$2 < d) return false;
      done[best] = true;
      left--;
    }
    return true;
  }

  final clear = [for (final id in pool) if (window(id).$1 <= today) id];
  final from = clear.isNotEmpty
      ? clear
      : [pool.reduce((a, b) => window(b).$1 < window(a).$1 ? b : a)];
  final ok = [for (final id in from) if (leavesRoom(id)) id];
  if (ok.isNotEmpty) return ok[seed % ok.length];
  return from.reduce((a, b) => window(b).$2 < window(a).$2 ? b : a);
}

/// Where the rotation keeps what it picked. [Progress] stores it on the device; tests use [MemoryMixHistory].
abstract class MixHistory {
  Map<String, int> last(GameCategory c);
  void setLast(GameCategory c, Map<String, int> last);
  int? start(GameCategory c);
  void setStart(GameCategory c, int day);
  String? pickedOn(GameCategory c, int day);
  void setPickedOn(GameCategory c, int day, String id);
}

class MemoryMixHistory implements MixHistory {
  final _last = <GameCategory, Map<String, int>>{};
  final _start = <GameCategory, int>{};
  final _on = <GameCategory, (int, String)>{};

  @override
  Map<String, int> last(GameCategory c) => {...?_last[c]};
  @override
  void setLast(GameCategory c, Map<String, int> last) => _last[c] = {...last};
  @override
  int? start(GameCategory c) => _start[c];
  @override
  void setStart(GameCategory c, int day) => _start[c] = day;
  @override
  String? pickedOn(GameCategory c, int day) => switch (_on[c]) { (final d, final id) when d == day => id, _ => null };
  @override
  void setPickedOn(GameCategory c, int day, String id) => _on[c] = (day, id);
}

class ProgressMixHistory implements MixHistory {
  final Progress p;
  const ProgressMixHistory(this.p);

  @override
  Map<String, int> last(GameCategory c) => p.mixLast(c.name);
  @override
  void setLast(GameCategory c, Map<String, int> last) => p.setMixLast(c.name, last);
  @override
  int? start(GameCategory c) => p.mixStart(c.name);
  @override
  void setStart(GameCategory c, int day) => p.setMixStart(c.name, day);
  @override
  String? pickedOn(GameCategory c, int day) => p.mixPickedOn(c.name, day);
  @override
  void setPickedOn(GameCategory c, int day, String id) => p.setMixPickedOn(c.name, day, id);
}

/// The pick of [c] on [today] from [pool], drawn once and then kept for the day in [h].
GameInfo _rotate(GameCategory c, List<GameInfo> pool, int today, String key, MixHistory h) {
  final kept = h.pickedOn(c, today);
  for (final g in pool) {
    if (g.id == kept) return g;
  }
  var last = h.last(c);
  var start = h.start(c);
  if (start == null || last.isEmpty) {
    start = today;
    h.setStart(c, start);
  } else {
    // Days the app was not opened are skipped: the whole history moves forward by them.
    final newest = last.values.reduce((a, b) => a > b ? a : b);
    final skipped = today - 1 - newest;
    if (skipped > 0) {
      last = {for (final e in last.entries) e.key: e.value + skipped};
      start += skipped;
      h.setStart(c, start);
    }
  }
  final ids = [for (final g in pool) g.id];
  final id = mixPick(pool: ids, last: last, today: today, start: start, seed: _hash('$key|${c.name}'));
  h.setLast(c, {...last, id: today});
  h.setPickedOn(c, today, id);
  return pool.firstWhere((g) => g.id == id);
}

/// The picks for [day]: one per enabled category, in [kDailyOrder]. With [history] the pick follows the
/// rotation (no repeat within 3 days, every game within n + 3) and is kept for the day; without it
/// (settings preview, tests) it is a stable hash draw of the date.
List<DailyPick> dailyPicks(DateTime day, DailySettings s, {MixHistory? history}) {
  final key = Progress.dayKey(day);
  final today = dayNumber(day);
  return [
    for (final c in kDailyOrder)
      if (s.categories.contains(c))
        if (dailyPool(c, s) case final pool when pool.isNotEmpty)
          DailyPick(
            c,
            history == null
                ? pool[_hash('$key|${c.name}|${pool.map((g) => g.id).join(',')}') % pool.length]
                : _rotate(c, pool, today, key, history),
          ),
  ];
}

/// FNV-1a with a murmur finaliser: stable across runs and platforms (unlike a seeded [Random]).
int _hash(String s) {
  var h = 0x811c9dc5;
  for (final b in s.codeUnits) {
    h = ((h ^ b) * 0x01000193) & 0xffffffff;
  }
  h ^= h >> 16;
  h = (h * 0x85ebca6b) & 0xffffffff;
  h ^= h >> 13;
  h = (h * 0xc2b2ae35) & 0xffffffff;
  h ^= h >> 16;
  return h;
}

/// Today's mix as the hub and the result card see it.
class DailyMix {
  static List<DailyPick> today(Progress p) =>
      dailyPicks(Progress.clock(), DailySettings.of(p), history: ProgressMixHistory(p));

  static bool done(Progress p, DailyPick pick) => p.wonToday.contains(pick.game.id);

  /// The first pick of the day not yet done, or null when the goal is reached.
  static DailyPick? next(Progress p) {
    final won = p.wonToday;
    for (final pick in today(p)) {
      if (!won.contains(pick.game.id)) return pick;
    }
    return null;
  }

  /// A pick plays at the player's next level in that game (a match game at its first table).
  static PlayScreen screen(Progress p, GameInfo g) {
    if (g.matchModes.isNotEmpty) return PlayScreen(game: g, level: 1, mode: g.matchModes.first.id, daily: true);
    return PlayScreen(game: g, level: p.nextLevel(g.id) ?? 1, daily: true);
  }

  static Route<void> route(Progress p, GameInfo g) => MaterialPageRoute(builder: (_) => screen(p, g));
}
