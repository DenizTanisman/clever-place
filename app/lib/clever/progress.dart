import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';


/// Stars per level and best endless scores, persisted locally.
class Progress extends ChangeNotifier {
  Progress._(this._prefs);
  static Progress? _instance;
  static Progress get instance => _instance!;
  final SharedPreferences _prefs;

  static Future<Progress> load() async {
    return _instance ??= Progress._(await SharedPreferences.getInstance());
  }

  /// Tests: start over on the current (mock) SharedPreferences.
  @visibleForTesting
  static Future<Progress> loadFresh() async {
    final visible = _instance?.visibleLevels ?? 2;
    return _instance = Progress._(await SharedPreferences.getInstance())..visibleLevels = visible;
  }

  /// How many levels each game shows (set from the Rust core at start-up).
  int visibleLevels = 2;

  /// Games whose course length differs from the global level count: Soroban is a 50-level course;
  /// IQ Soruları has 50 levels of 20 questions; Sözel ve Sosyal Zeka 45 fixed levels of 10 items;
  /// Doğru Söz has one level per built sequence and Yüz ve İsim 1000 levels (core `max_level`).
  static const Map<String, int> _caps = {
    'soroban': 50,
    'iq': 50,
    'verbal_social': 45,
    'zihin_asisi': 13,
    'donen_sayilar': 200,
  };

  /// Games whose cap may exceed the global count (their own course is longer than 500).
  static const Set<String> _beyondGlobal = {};

  /// The generic full level count (`MAX_LEVEL` in the Rust core).
  static const fullLevels = 500;

  /// Games with a longer course than [fullLevels] (Yüz ve İsim has 1000). The core reports the same
  /// numbers in `info.game_levels`; [main] copies them here at start-up.
  static Map<String, int> longCourses = {};

  /// Levels shown for [game]: the global count, capped by the game's own course length (which, for
  /// [_beyondGlobal] games, replaces the global count).
  int levelsFor(String game) {
    final long = longCourses[game];
    if (long != null && _beyondGlobal.contains(game)) return long;
    final cap = _caps[game];
    if (cap == null) return visibleLevels;
    return cap > visibleLevels && !_beyondGlobal.contains(game) ? visibleLevels : cap;
  }

  int stars(String game, int level) => _prefs.getInt('cp.stars.$game.$level') ?? 0;

  int totalStars(String game) {
    var t = 0;
    for (var l = 1; l <= levelsFor(game); l++) {
      t += stars(game, l);
    }
    return t;
  }

  int completed(String game) {
    var t = 0;
    for (var l = 1; l <= levelsFor(game); l++) {
      if (stars(game, l) > 0) t++;
    }
    return t;
  }

  // ---- Difficulty tiers ----

  /// Tier names, easiest first. Level generators get harder with the level number, so each tier is a
  /// contiguous quarter of the game's levels.
  static const tierNames = ['Kolay', 'Orta', 'Zor', 'Uzman'];

  /// Dative forms for the "go to the next tier" button ("Zor'a geç").
  static const tierDative = ["Kolay'a", "Orta'ya", "Zor'a", "Uzman'a"];

  /// How many tiers [game] is split into (a course shorter than four levels is a single tier).
  int tierCount(String game) => levelsFor(game) >= tierNames.length ? tierNames.length : 1;

  /// First and last level (inclusive, 1-based) of tier [t]. 500 levels: 1–125, 126–250, 251–375,
  /// 376–500; longer and shorter courses split proportionally (Yüz ve İsim 1000: 1–250, 251–500,
  /// 501–750, 751–1000; Soroban 50: 1–12, 13–25, 26–37, 38–50).
  ({int first, int last}) tierRange(String game, int t) {
    final n = levelsFor(game);
    final c = tierCount(game);
    final tt = t.clamp(0, c - 1);
    return (first: n * tt ~/ c + 1, last: n * (tt + 1) ~/ c);
  }

  /// The tier holding [level].
  int tierOf(String game, int level) {
    final c = tierCount(game);
    for (var t = 0; t < c; t++) {
      if (level <= tierRange(game, t).last) return t;
    }
    return c - 1;
  }

  int tierCompleted(String game, int t) {
    final r = tierRange(game, t);
    var n = 0;
    for (var l = r.first; l <= r.last; l++) {
      if (stars(game, l) > 0) n++;
    }
    return n;
  }

  int tierStars(String game, int t) {
    final r = tierRange(game, t);
    var n = 0;
    for (var l = r.first; l <= r.last; l++) {
      n += stars(game, l);
    }
    return n;
  }

  /// The tier the game page opens on: the last one chosen or played, else the tier holding the
  /// lowest level not yet won.
  int currentTier(String game) {
    final saved = _prefs.getInt('cp.tier.$game');
    if (saved != null && saved >= 0 && saved < tierCount(game)) return saved;
    for (var l = 1; l <= levelsFor(game); l++) {
      if (stars(game, l) == 0) return tierOf(game, l);
    }
    return 0;
  }

  Future<void> setTier(String game, int t) => _prefs.setInt('cp.tier.$game', t);

  /// Lowest level not yet won in [t], or null when the whole tier has stars. Always unlocked: either
  /// it is one of the tier's first two levels or the level before it (same tier) is won.
  int? firstUnwonIn(String game, int t) {
    final r = tierRange(game, t);
    for (var l = r.first; l <= r.last; l++) {
      if (stars(game, l) == 0) return l;
    }
    return null;
  }

  /// The level to play next: the first unwon level of the current tier, then of the later tiers, then
  /// of any tier. Null when every level has stars.
  int? nextLevel(String game) {
    final c = tierCount(game);
    final cur = currentTier(game);
    for (var i = 0; i < c; i++) {
      final l = firstUnwonIn(game, (cur + i) % c);
      if (l != null) return l;
    }
    return null;
  }

  /// "Continue" after [level]: the same level until it is won, then the next level of the same
  /// tier, and at a tier's end wherever [nextLevel] points (or the same level if all are done).
  int continueLevel(String game, int level) {
    if (stars(game, level) == 0) return level;
    if (level < tierRange(game, tierOf(game, level)).last) return level + 1;
    return nextLevel(game) ?? level;
  }

  /// Every tier's first two levels are always open, so any tier is playable straight away. Inside a
  /// tier a level opens when the previous one is won. (The old global rule — level ≤ 2 or the
  /// previous level won — is a subset of this, so nothing that was open before gets locked.)
  bool unlocked(String game, int level) {
    if (level < 1 || level > levelsFor(game)) return false;
    final first = tierRange(game, tierOf(game, level)).first;
    return level - first < 2 || stars(game, level - 1) > 0;
  }

  Future<void> recordStars(String game, int level, int s) async {
    if (s > stars(game, level)) {
      await _prefs.setInt('cp.stars.$game.$level', s);
      notifyListeners();
    }
  }

  // ---- Winning times per game and difficulty tier (game page record, result screen chart) ----

  /// How many recent winning times each tier keeps.
  static const recentTimesKept = 10;

  /// The last [recentTimesKept] winning times in tier [t] of [game], oldest first, in ms.
  List<int> recentTimes(String game, int t) => [
        for (final s in _prefs.getStringList('cp.times.$game.$t') ?? const <String>[])
          if (int.tryParse(s) case final v?) v,
      ];

  /// The fastest winning time ever in tier [t] of [game] (ms), or null before the first win.
  int? bestTime(String game, int t) => _prefs.getInt('cp.besttime.$game.$t');

  /// Stores a winning time of [level] and returns the tier's best before it (null: first time).
  Future<int?> recordTime(String game, int level, int ms) async {
    final t = tierOf(game, level);
    final before = bestTime(game, t);
    final list = recentTimes(game, t)..add(ms);
    if (list.length > recentTimesKept) list.removeRange(0, list.length - recentTimesKept);
    await _prefs.setStringList('cp.times.$game.$t', [for (final v in list) '$v']);
    if (before == null || ms < before) await _prefs.setInt('cp.besttime.$game.$t', ms);
    notifyListeners();
    return before;
  }

  int best(String game) => _prefs.getInt('cp.best.$game') ?? 0;

  Future<bool> recordBest(String game, int score) async {
    if (score > best(game)) {
      await _prefs.setInt('cp.best.$game', score);
      notifyListeners();
      return true;
    }
    return false;
  }

  // ---- Match games (cards): win / draw / loss per game and table mode ----

  List<int> record(String game, String mode) => [
        _prefs.getInt('cp.wdl.$game.$mode.w') ?? 0,
        _prefs.getInt('cp.wdl.$game.$mode.d') ?? 0,
        _prefs.getInt('cp.wdl.$game.$mode.l') ?? 0,
      ];

  Future<void> recordMatch(String game, String mode, String status) async {
    final k = switch (status) { 'won' => 'w', 'draw' => 'd', _ => 'l' };
    final key = 'cp.wdl.$game.$mode.$k';
    await _prefs.setInt(key, (_prefs.getInt(key) ?? 0) + 1);
    notifyListeners();
  }

  // ---- Daily goal, weekly rhythm, continue ----

  /// The clock behind every "today" (tests pin it).
  static DateTime Function() clock = DateTime.now;

  static String _day(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// The day key used for every per-day record ("2026-11-07").
  static String dayKey(DateTime d) => _day(d);

  int get todayWins => _prefs.getInt('cp.wins.${_day(clock())}') ?? 0;

  /// Games with a level (or a match) won today: what ticks off the daily mix's picks.
  Set<String> get wonToday => (_prefs.getStringList('cp.won.${_day(clock())}') ?? const []).toSet();

  Set<String> get _activeDays => (_prefs.getStringList('cp.days') ?? const []).toSet();

  /// Total distinct days played (never decreases).
  int get daysPlayed => _activeDays.length;

  /// Days played in the current Monday-started week (0–7). A rhythm, not a streak: it never "breaks".
  int get daysThisWeek {
    final now = clock();
    final monday = DateTime(now.year, now.month, now.day).subtract(Duration(days: now.weekday - 1));
    final days = _activeDays;
    var n = 0;
    for (var i = 0; i < 7; i++) {
      if (days.contains(_day(monday.add(Duration(days: i))))) n++;
    }
    return n;
  }

  /// A finished win in [game]. [level] is false for an endless run: it counts as the day's activity
  /// but does not tick off a daily pick.
  Future<void> recordWin(String game, {bool level = true}) async {
    final today = _day(clock());
    await _prefs.setInt('cp.wins.$today', todayWins + 1);
    if (level) {
      final won = wonToday;
      if (won.add(game)) await _prefs.setStringList('cp.won.$today', won.toList());
    }
    final days = _activeDays..add(today);
    await _prefs.setStringList('cp.days', days.toList());
    notifyListeners();
  }

  /// Sum of stars over every game id given.
  int starsFor(Iterable<String> games) => games.fold(0, (a, g) => a + totalStars(g));

  /// Levels won (at least one star) over every game id given.
  int completedFor(Iterable<String> games) => games.fold(0, (a, g) => a + completed(g));

  /// The player's level from [done] won levels (owner, 2026-11-22): every won level counts one, and
  /// leaving level n takes 2^n of them (1 → 2 needs 2, 2 → 3 needs 4, 3 → 4 needs 8 …), so level L
  /// starts at 2^L − 2 won levels. [into] is how far into the current level, [need] its length.
  static ({int level, int into, int need}) playerLevel(int done) {
    var level = 1, need = 2, left = done < 0 ? 0 : done;
    while (left >= need) {
      left -= need;
      level++;
      need *= 2;
    }
    return (level: level, into: left, need: need);
  }

  /// Roman numerals (kept for other uses; the player level is shown in plain numbers).
  static String roman(int n) {
    if (n <= 0) return '—';
    const vals = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
    const syms = ['M', 'CM', 'D', 'CD', 'C', 'XC', 'L', 'XL', 'X', 'IX', 'V', 'IV', 'I'];
    var out = '';
    for (var i = 0; i < vals.length; i++) {
      while (n >= vals[i]) {
        out += syms[i];
        n -= vals[i];
      }
    }
    return out;
  }

  // ---- Daily mix settings: which categories (and optionally which of their games) feed the day ----

  /// Enabled category names, or null for the default set.
  List<String>? get dailyCategoryNames => _prefs.getStringList('cp.daily.cats');

  Future<void> setDailyCategoryNames(List<String> names) async {
    await _prefs.setStringList('cp.daily.cats', names);
    notifyListeners();
  }

  /// The game ids a category's daily pick is limited to: null = that category's default, empty = every
  /// game of the category.
  List<String>? dailyOnly(String category) => _prefs.getStringList('cp.daily.only.$category');

  Future<void> setDailyOnly(String category, List<String> ids) async {
    await _prefs.setStringList('cp.daily.only.$category', ids);
    notifyListeners();
  }

  // ---- Daily mix rotation (see daily_mix.dart). Kept apart from the settings: resetDaily keeps it. ----
  // Written without notifyListeners: the hub stores the day's picks while it builds.

  /// Per game of [category]: the day number it was last the day's pick.
  Map<String, int> mixLast(String category) => {
        for (final e in _prefs.getStringList('cp.mix.last.$category') ?? const <String>[])
          if (e.split('=') case [final id, final d] when int.tryParse(d) != null) id: int.parse(d),
      };

  void setMixLast(String category, Map<String, int> last) => unawaited(
      _prefs.setStringList('cp.mix.last.$category', [for (final e in last.entries) '${e.key}=${e.value}']));

  /// The day number the rotation of [category] started on.
  int? mixStart(String category) => _prefs.getInt('cp.mix.start.$category');

  void setMixStart(String category, int day) => unawaited(_prefs.setInt('cp.mix.start.$category', day));

  /// The game picked for [category] on [day], if that day was drawn already.
  String? mixPickedOn(String category, int day) {
    final v = _prefs.getString('cp.mix.on.$category');
    if (v == null) return null;
    final i = v.indexOf('=');
    return i > 0 && v.substring(0, i) == '$day' ? v.substring(i + 1) : null;
  }

  void setMixPickedOn(String category, int day, String id) =>
      unawaited(_prefs.setString('cp.mix.on.$category', '$day=$id'));

  /// Back to the default daily mix: drops every daily setting.
  Future<void> resetDaily() async {
    for (final k in _prefs.getKeys().where((k) => k.startsWith('cp.daily.')).toList()) {
      await _prefs.remove(k);
    }
    notifyListeners();
  }

  /// The section a multi-game page (Mental Aritmetik: Sprint / Soroban) opens on: the last one chosen.
  String? section(String game) => _prefs.getString('cp.section.$game');

  Future<void> setSection(String game, String section) => _prefs.setString('cp.section.$game', section);

  /// The sub-category last opened on a game's category page (Doğru Söz: a raw domain).
  String? lastSubcategory(String game) => _prefs.getString('cp.subcategory.$game');

  Future<void> setLastSubcategory(String game, String id) async {
    await _prefs.setString('cp.subcategory.$game', id);
    notifyListeners();
  }

  String? get lastGame => _prefs.getString('cp.last.game');
  int get lastLevel => _prefs.getInt('cp.last.level') ?? 1;
  String get lastMode => _prefs.getString('cp.last.mode') ?? 'level';

  Future<void> recordPlay(String game, int level, String mode) async {
    await _prefs.setString('cp.last.game', game);
    await _prefs.setInt('cp.last.level', level);
    await _prefs.setString('cp.last.mode', mode);
    // A played level makes its tier the one the game page opens on.
    if (mode == 'level') await setTier(game, tierOf(game, level));
  }
}
