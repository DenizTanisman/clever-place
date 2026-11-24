// "Günün hedefi" daily mix, Soroban inside Mental Aritmetik, and Strateji absorbing the speed games.
// Run with `flutter test`.

import 'package:clever_place/clever/catalog.dart';
import 'package:clever_place/clever/daily_goal_settings.dart';
import 'package:clever_place/clever/daily_mix.dart';
import 'package:clever_place/clever/game_home_screen.dart';
import 'package:clever_place/clever/hub_screen.dart';
import 'package:clever_place/clever/lux.dart';
import 'package:clever_place/clever/progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _day = DateTime(2026, 11, 7, 9, 30);

Future<Progress> _fresh([Map<String, Object> prefs = const {}]) async {
  SharedPreferences.setMockInitialValues(prefs);
  final p = await Progress.loadFresh();
  p.visibleLevels = 500;
  return p;
}

List<String> _ids(List<DailyPick> picks) => [for (final k in picks) k.game.id];

void main() {
  setUp(() => Progress.clock = () => _day);
  tearDown(() => Progress.clock = DateTime.now);

  group('daily picks', () {
    test('default: one game each from Hafıza, Dikkat, Mantık, Zihin (Mental Aritmetik)', () {
      final picks = dailyPicks(_day, DailySettings.defaults);
      expect([for (final k in picks) k.category], [
        GameCategory.memory,
        GameCategory.attention,
        GameCategory.logic,
        GameCategory.mind,
      ]);
      for (final k in picks) {
        expect(k.game.category, k.category);
      }
      expect(picks[3].game.id, 'math');
    });

    test('stable all day, re-drawn on other days', () {
      final a = _ids(dailyPicks(DateTime(2026, 11, 7, 0, 1), DailySettings.defaults));
      final b = _ids(dailyPicks(DateTime(2026, 11, 7, 23, 59), DailySettings.defaults));
      expect(a, b);
      final memory = {
        for (var d = 0; d < 60; d++) dailyPicks(DateTime(2026, 1, 1).add(Duration(days: d)), DailySettings.defaults)[0].game.id,
      };
      expect(memory.length, greaterThan(3), reason: 'the memory pick should vary from day to day');
    });

    test('Soroban is never drawn, whatever the settings', () {
      final pools = [
        DailySettings.defaults,
        const DailySettings(categories: {GameCategory.mind}, only: {}),
        const DailySettings(categories: {GameCategory.mind}, only: {GameCategory.mind: {'soroban'}}),
      ];
      for (final s in pools) {
        for (var d = 0; d < 120; d++) {
          expect(_ids(dailyPicks(DateTime(2026, 1, 1).add(Duration(days: d)), s)), isNot(contains('soroban')));
        }
      }
      expect(dailyCandidates(GameCategory.mind).map((g) => g.id), ['math', 'zihin_asisi']);
    });

    test('a limit keeps the draw inside the chosen games', () {
      const s = DailySettings(categories: {GameCategory.logic}, only: {GameCategory.logic: {'sudoku', 'hanoi'}});
      for (var d = 0; d < 40; d++) {
        final ids = _ids(dailyPicks(DateTime(2026, 3, 1).add(Duration(days: d)), s));
        expect(ids.length, 1);
        expect(['sudoku', 'hanoi'], contains(ids.single));
      }
    });

    test('every hub category with a playable game can join; Küp cannot', () {
      expect(dailyCategories, [
        GameCategory.memory,
        GameCategory.attention,
        GameCategory.logic,
        GameCategory.mind,
        GameCategory.strategy,
        GameCategory.cards,
      ]);
      final all = DailySettings(categories: GameCategory.values.toSet());
      final ids = _ids(dailyPicks(_day, all));
      expect(ids.length, 6);
      expect(ids, isNot(contains('cube')));
    });
  });

  group('settings and progress', () {
    test('saved settings drive the picks and survive a reload; reset restores the defaults', () async {
      var p = await _fresh();
      expect(DailyMix.today(p).length, 4);
      await p.setDailyCategoryNames([GameCategory.memory.name, GameCategory.strategy.name]);
      await p.setDailyOnly(GameCategory.strategy.name, ['corridor']);
      p = await Progress.loadFresh();
      final s = DailySettings.of(p);
      expect(s.categories, {GameCategory.memory, GameCategory.strategy});
      expect(s.only[GameCategory.strategy], {'corridor'});
      expect(s.only[GameCategory.mind], {'math'}, reason: 'untouched categories keep their default');
      expect(_ids(DailyMix.today(p))[1], 'corridor');

      await p.resetDaily();
      expect(DailySettings.of(p).categories, DailySettings.defaults.categories);
      expect(DailyMix.today(p).length, 4);
    });

    test('a level win ticks its pick off; an endless run does not', () async {
      final p = await _fresh();
      final picks = DailyMix.today(p);
      expect(DailyMix.next(p)!.game.id, picks[0].game.id);
      await p.recordWin(picks[0].game.id);
      expect(DailyMix.done(p, picks[0]), isTrue);
      expect(DailyMix.next(p)!.game.id, picks[1].game.id);
      await p.recordWin(picks[1].game.id, level: false);
      expect(DailyMix.done(p, picks[1]), isFalse);
      for (final k in picks) {
        await p.recordWin(k.game.id);
      }
      expect(DailyMix.next(p), isNull);
      // Tomorrow starts afresh.
      Progress.clock = () => _day.add(const Duration(days: 1));
      expect(p.wonToday, isEmpty);
    });

    test('a pick opens at the next level of its game', () async {
      final p = await _fresh();
      final g = coreGame('sudoku')!;
      await p.recordStars('sudoku', 1, 3);
      final s = DailyMix.screen(p, g);
      expect(s.level, 2);
      expect(s.daily, isTrue);
      final batak = DailyMix.screen(p, coreGame('batak')!);
      expect(batak.mode, 'easy');
    });
  });

  group('catalogue', () {
    test('hub order: no Hız ve uzay, its games under Strateji after the board games', () {
      expect([for (final c in GameCategory.values) c.label], [
        'Strateji',
        'Hafıza',
        'Dikkat',
        'Mantık bulmacaları',
        'Zihin antrenmanı',
        'Kıraathane oyunları',
        'Zeka küpü',
      ]);
      final strategy = [for (final g in hubGames(GameCategory.strategy)) g.id];
      expect(strategy, ['corridor', 'push', 'morris', 'surakarta', 'falling_blocks', 'block_grid', 'gem_merge']);
    });

    test('Soroban is a section of Mental Aritmetik, not a hub card; its ids are unchanged', () {
      expect(hubGames(GameCategory.mind).map((g) => g.id), ['math', 'zihin_asisi']);
      final math = coreGame('math')!;
      expect([for (final s in math.sections) (s.label, s.gameId)], [('Sprint', 'math'), ('Soroban', 'soroban')]);
      final soroban = coreGame('soroban')!;
      expect(soroban.inHub, isFalse);
      expect(soroban.tutorials.mid, isNotEmpty);
    });
  });

  group('widgets', () {
    Future<VoidCallback> big(WidgetTester tester) async {
      final prev = FlutterError.onError;
      // The test font is wider than Jost; overflow stripes are not what we test.
      FlutterError.onError = (d) {
        if (d.exceptionAsString().contains('overflowed')) return;
        prev?.call(d);
      };
      tester.view.physicalSize = const Size(1290, 4000);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      return () => FlutterError.onError = prev;
    }

    testWidgets('the hub card lists today\'s picks and marks the won ones', (tester) async {
      final restore = await big(tester);
      final p = await _fresh();
      final picks = DailyMix.today(p);
      await p.recordWin(picks[2].game.id);
      await tester.pumpWidget(const MaterialApp(home: HubScreen()));
      await tester.pump(const Duration(seconds: 2));

      final card = find.byKey(const ValueKey('daily-card'));
      expect(find.descendant(of: card, matching: find.text('1 / 4 oyun')), findsOneWidget);
      for (final k in picks) {
        expect(find.byKey(ValueKey('daily-pick-${k.game.id}')), findsOneWidget);
      }
      expect(find.descendant(of: card, matching: find.byIcon(Icons.check_circle_rounded)), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Devam')), findsOneWidget);
      // No hub card for Soroban; Mental Aritmetik has one.
      Finder hero(String id) => find.byWidgetPredicate((w) => w is Hero && w.tag == monogramHeroTag(id));
      await tester.scrollUntilVisible(hero('math'), 300, scrollable: find.byType(Scrollable).first);
      expect(hero('math'), findsOneWidget);
      expect(hero('soroban'), findsNothing);
      restore();
    });

    testWidgets('Mental Aritmetik switches between Sprint and Soroban', (tester) async {
      final restore = await big(tester);
      final p = await _fresh();
      await tester.pumpWidget(MaterialApp(home: GameHomeScreen(game: coreGame('math')!)));
      await tester.pump();
      // A tall view: the whole page down to the level grid is built without scrolling.
      tester.view.physicalSize = const Size(1290, 9000);
      await tester.pump();
      // The page's level count ("0/500" in the numbers row under the title).
      Finder levels(int n) => find.text('0/$n');
      expect(find.text('Sprint'), findsOneWidget);
      expect(find.text('Soroban'), findsOneWidget);
      // Sprint = the mental arithmetic game itself: its endless sprint and 500 levels.
      expect(find.text('Sprint (60 sn)'), findsOneWidget);
      expect(levels(500), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('section-soroban')));
      await tester.pump();
      expect(p.section('math'), 'soroban');
      expect(levels(50), findsOneWidget);
      expect(find.text('Sprint (60 sn)'), findsNothing, reason: 'Soroban has no endless mode');

      // The page reopens on the last section.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(MaterialApp(home: GameHomeScreen(game: coreGame('math')!)));
      await tester.pump();
      expect(levels(50), findsOneWidget);
      restore();
    });

    testWidgets('settings: the collapsible card toggles categories, limits games and resets', (tester) async {
      final restore = await big(tester);
      final p = await _fresh();
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(backgroundColor: Lux.bg0, body: SingleChildScrollView(child: DailyGoalSettings())),
      ));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('daily-cat-attention')), findsNothing, reason: 'closed by default');

      await tester.tap(find.byKey(const ValueKey('daily-settings-header')));
      await tester.pumpAndSettle();
      expect(find.byType(Switch), findsNWidgets(dailyCategories.length));

      await tester.tap(find.byKey(const ValueKey('daily-cat-attention')));
      await tester.pump();
      expect(p.dailyCategoryNames, isNot(contains('attention')));
      expect(DailyMix.today(p).length, 3);

      await tester.tap(find.byKey(const ValueKey('daily-only-logic-sudoku')));
      await tester.pump();
      expect(p.dailyOnly('logic'), ['sudoku']);
      expect(DailyMix.today(p).firstWhere((k) => k.category == GameCategory.logic).game.id, 'sudoku');

      await tester.tap(find.byKey(const ValueKey('daily-all-logic')));
      await tester.pump();
      expect(p.dailyOnly('logic'), isEmpty);

      await tester.ensureVisible(find.byKey(const ValueKey('daily-settings-reset')));
      await tester.tap(find.byKey(const ValueKey('daily-settings-reset')));
      await tester.pump();
      expect(p.dailyCategoryNames, isNull);
      expect(DailyMix.today(p).length, 4);
      restore();
    });
  });

  group('rotation (no repeat within 3 days, every game within n + 3)', () {
    // Checks a run of picks of one category: gaps between picks of a game, and that every game
    // appears in every window of n + 3 consecutive days (counting from the first day).
    void checkRun(List<String> run, List<String> pool, {String? reason}) {
      final n = pool.length;
      final seen = <String, int>{};
      for (var d = 0; d < run.length; d++) {
        final id = run[d];
        expect(pool, contains(id), reason: reason);
        if (seen[id] case final prev?) {
          expect(d - prev, greaterThanOrEqualTo(mixMinGap(n)), reason: '$reason: $id on days $prev and $d');
          expect(d - prev, lessThanOrEqualTo(mixMaxGap(n)), reason: '$reason: $id on days $prev and $d');
        } else {
          expect(d, lessThan(mixMaxGap(n)), reason: '$reason: $id first came on day $d');
        }
        seen[id] = d;
      }
      for (final id in pool) {
        expect(run.length - 1 - seen[id]!, lessThan(mixMaxGap(n)), reason: '$reason: $id missing at the end');
      }
    }

    List<String> simulate(List<String> pool, int days, int salt) {
      final last = <String, int>{};
      final run = <String>[];
      for (var t = 0; t < days; t++) {
        final id = mixPick(pool: pool, last: last, today: t, start: 0, seed: (t * 2654435761 + salt) & 0x7fffffff);
        last[id] = t;
        run.add(id);
      }
      return run;
    }

    test('holds for every category size from 1 to 16 over 400 days', () {
      for (var n = 1; n <= 16; n++) {
        final pool = [for (var i = 0; i < n; i++) 'g$i'];
        for (var salt = 0; salt < 8; salt++) {
          checkRun(simulate(pool, 400, salt), pool, reason: 'n=$n salt=$salt');
        }
      }
    });

    test('random, not a fixed rotation', () {
      final pool = [for (var i = 0; i < 8; i++) 'g$i'];
      final run = simulate(pool, 400, 1);
      final orders = {for (var c = 0; c + 8 <= run.length; c += 8) run.sublist(c, c + 8).join(',')};
      expect(orders.length, greaterThan(10), reason: 'the order of the games should keep changing');
    });

    test('the real hub: all categories on, 500 days through dailyPicks', () {
      final s = DailySettings(categories: GameCategory.values.toSet());
      final h = MemoryMixHistory();
      final runs = <GameCategory, List<String>>{};
      for (var d = 0; d < 500; d++) {
        final day = DateTime(2026, 11, 14, 9).add(Duration(days: d));
        final picks = dailyPicks(day, s, history: h);
        expect(_ids(dailyPicks(day, s, history: h)), _ids(picks), reason: 'kept for the whole day');
        for (final k in picks) {
          (runs[k.category] ??= []).add(k.game.id);
        }
      }
      for (final e in runs.entries) {
        checkRun(e.value, [for (final g in dailyPool(e.key, s)) g.id], reason: e.key.name);
      }
    });

    test('defaults: Zihin is always Mental Aritmetik, never Soroban or Zihin Aşısı', () {
      final h = MemoryMixHistory();
      for (var d = 0; d < 60; d++) {
        final picks = dailyPicks(DateTime(2026, 11, 14).add(Duration(days: d)), DailySettings.defaults, history: h);
        expect(picks.firstWhere((k) => k.category == GameCategory.mind).game.id, 'math');
      }
    });

    test('days the app is not opened do not count', () {
      const s = DailySettings(categories: {GameCategory.memory});
      final pool = [for (final g in dailyPool(GameCategory.memory, s)) g.id];
      final h = MemoryMixHistory();
      final run = <String>[];
      var day = DateTime(2026, 11, 14, 9);
      for (var i = 0; i < 300; i++) {
        run.add(dailyPicks(day, s, history: h).single.game.id);
        day = day.add(Duration(days: i % 7 == 3 ? 5 : 1)); // a 4-day break every week
      }
      checkRun(run, pool, reason: 'counted over opened days');
    });

    test('kept on the device: same pick after a reload, history survives a settings reset', () async {
      final p = await _fresh();
      final first = _ids(DailyMix.today(p));
      final again = await Progress.loadFresh();
      expect(_ids(DailyMix.today(again)), first);
      await again.resetDaily();
      expect(_ids(DailyMix.today(again)), first);
      expect(again.mixLast(GameCategory.memory.name)[first[0]], dayNumber(_day));
    });
  });
}
