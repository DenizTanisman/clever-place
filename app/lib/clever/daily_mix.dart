import 'package:flutter/material.dart';

import 'catalog.dart';
import 'play_screen.dart';
import 'progress.dart';

/// "Günün hedefi": every day one game from each enabled category, picked at random but seeded by the
/// date, so the set holds for the whole day and changes the next. Only the settings are stored
/// (SharedPreferences, see [Progress.dailyCategoryNames] / [Progress.dailyOnly]); the picks are a pure
/// function of the date and those settings, and a pick is done once a level (or a match) of it is won
/// that day ([Progress.wonToday]).

/// The order the day's picks are played in: the default four first, then the rest of the hub.
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

  /// Hafıza, Dikkat, Mantık, and Zihin antrenmanı (Mental Aritmetik only, never Soroban).
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

/// The picks for [day]: one per enabled category, in [kDailyOrder]. The draw is a hash of the date,
/// the category and its pool, so it is the same all day and only a category whose pool changed is
/// drawn again.
List<DailyPick> dailyPicks(DateTime day, DailySettings s) {
  final key = Progress.dayKey(day);
  return [
    for (final c in kDailyOrder)
      if (s.categories.contains(c))
        if (dailyPool(c, s) case final pool when pool.isNotEmpty)
          DailyPick(c, pool[_hash('$key|${c.name}|${pool.map((g) => g.id).join(',')}') % pool.length]),
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
  static List<DailyPick> today(Progress p) => dailyPicks(Progress.clock(), DailySettings.of(p));

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
