// Difficulty tiers (Kolay / Orta / Zor / Uzman): ranges, the per-tier unlock rule, "continue", and
// the tier selector on the game page.

import 'package:clever_place/clever/catalog.dart';
import 'package:clever_place/clever/game_home_screen.dart';
import 'package:clever_place/clever/progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<Progress> _fresh([Map<String, Object> prefs = const {}]) async {
  SharedPreferences.setMockInitialValues(prefs);
  final p = await Progress.loadFresh();
  p.visibleLevels = 500;
  return p;
}

Future<void> _win(Progress p, String game, Iterable<int> levels) async {
  for (final l in levels) {
    await p.recordStars(game, l, 1);
  }
}

void main() {
  group('tier ranges', () {
    test('500 levels split into four quarters', () async {
      final p = await _fresh();
      expect(p.tierCount('sudoku'), 4);
      expect([for (var t = 0; t < 4; t++) p.tierRange('sudoku', t)], [
        (first: 1, last: 125),
        (first: 126, last: 250),
        (first: 251, last: 375),
        (first: 376, last: 500),
      ]);
      expect(p.tierOf('sudoku', 1), 0);
      expect(p.tierOf('sudoku', 125), 0);
      expect(p.tierOf('sudoku', 126), 1);
      expect(p.tierOf('sudoku', 375), 2);
      expect(p.tierOf('sudoku', 376), 3);
      expect(p.tierOf('sudoku', 500), 3);
    });

    test('ordinary games stay at 500 and a smaller global count caps them', () async {
      final p = await _fresh();
      expect(p.levelsFor('word_list'), 500);
      p.visibleLevels = 2;
      expect(p.levelsFor('word_list'), 2);
    });

    test('a shorter course splits proportionally and contiguously', () async {
      final p = await _fresh();
      expect(p.levelsFor('soroban'), 50);
      final ranges = [for (var t = 0; t < 4; t++) p.tierRange('soroban', t)];
      expect(ranges, [(first: 1, last: 12), (first: 13, last: 25), (first: 26, last: 37), (first: 38, last: 50)]);
    });

    test('fewer than four levels is a single tier', () async {
      final p = await _fresh();
      p.visibleLevels = 2;
      expect(p.tierCount('sudoku'), 1);
      expect(p.tierRange('sudoku', 0), (first: 1, last: 2));
    });
  });

  group('unlock rule', () {
    test('first two levels of every tier are open; the rest need the previous level won', () async {
      final p = await _fresh();
      for (final first in [1, 126, 251, 376]) {
        expect(p.unlocked('sudoku', first), isTrue, reason: '$first');
        expect(p.unlocked('sudoku', first + 1), isTrue, reason: '${first + 1}');
        expect(p.unlocked('sudoku', first + 2), isFalse, reason: '${first + 2}');
      }
      await _win(p, 'sudoku', [252]);
      expect(p.unlocked('sudoku', 253), isTrue);
      expect(p.unlocked('sudoku', 254), isFalse);
      expect(p.unlocked('sudoku', 0), isFalse);
      expect(p.unlocked('sudoku', 501), isFalse);
    });

    test('Soroban tiers open at 1, 13, 26 and 38', () async {
      final p = await _fresh();
      for (final first in [1, 13, 26, 38]) {
        expect(p.unlocked('soroban', first + 1), isTrue);
        expect(p.unlocked('soroban', first + 2), isFalse);
      }
    });

    test('everything the old rule unlocked stays unlocked', () async {
      final p = await _fresh();
      // Old progress: levels 1..130 won in order (crosses the Kolay/Orta border).
      await _win(p, 'sudoku', [for (var l = 1; l <= 130; l++) l]);
      bool oldRule(int l) => l <= 2 || p.stars('sudoku', l - 1) > 0;
      for (var l = 1; l <= 500; l++) {
        if (oldRule(l)) expect(p.unlocked('sudoku', l), isTrue, reason: '$l');
      }
      expect(p.unlocked('sudoku', 131), isTrue);
      expect(p.unlocked('sudoku', 132), isFalse);
    });
  });

  group('current tier, next level, continue', () {
    test('opens on the tier holding the lowest unwon level, then on the last chosen or played one',
        () async {
      final p = await _fresh();
      expect(p.currentTier('sudoku'), 0);
      await _win(p, 'sudoku', [for (var l = 1; l <= 125; l++) l]);
      expect(p.currentTier('sudoku'), 1);
      await p.setTier('sudoku', 3);
      expect(p.currentTier('sudoku'), 3);
      await p.recordPlay('sudoku', 260, 'level');
      expect(p.currentTier('sudoku'), 2);
      // Endless / match plays don't move the tier.
      await p.recordPlay('sudoku', 1, 'endless');
      expect(p.currentTier('sudoku'), 2);
    });

    test('nextLevel looks in the current tier first, then the later ones', () async {
      final p = await _fresh();
      expect(p.nextLevel('sudoku'), 1);
      await p.setTier('sudoku', 2);
      expect(p.nextLevel('sudoku'), 251);
      await _win(p, 'sudoku', [for (var l = 251; l <= 375; l++) l]);
      expect(p.nextLevel('sudoku'), 376);
    });

    test('continue stays in the tier and moves on at its end', () async {
      final p = await _fresh();
      expect(p.continueLevel('sudoku', 300), 300); // not won yet: replay
      await _win(p, 'sudoku', [300]);
      expect(p.continueLevel('sudoku', 300), 301);
      await p.setTier('sudoku', 0);
      await _win(p, 'sudoku', [125]);
      // End of Kolay: the next unwon level of the current tier (Kolay still has 1..124 open).
      expect(p.continueLevel('sudoku', 125), 1);
    });

    test('per-tier progress', () async {
      final p = await _fresh();
      await p.recordStars('sudoku', 126, 3);
      await p.recordStars('sudoku', 127, 2);
      expect(p.tierCompleted('sudoku', 1), 2);
      expect(p.tierStars('sudoku', 1), 5);
      expect(p.tierCompleted('sudoku', 0), 0);
    });
  });

  group('game page tier selector', () {
    Future<void> pumpPage(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 3000);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: GameHomeScreen(game: kCoreGames.first)));
      await tester.pump();
    }

    Finder scrollable() => find.byType(Scrollable).first;

    testWidgets('shows the four tiers with their progress and jumps straight to Zor', (tester) async {
      final p = await _fresh();
      await pumpPage(tester);
      await tester.scrollUntilVisible(find.text('Uzman'), 200, scrollable: scrollable());
      for (final name in Progress.tierNames) {
        expect(find.text(name), findsOneWidget);
      }
      expect(find.text('0/125'), findsNWidgets(4));

      await tester.tap(find.text('Zor'));
      await tester.pump();
      expect(p.currentTier('sudoku'), 2);
      await tester.scrollUntilVisible(find.text('251'), 200, scrollable: scrollable());
      expect(find.text('252'), findsOneWidget);
      // 253 is locked (lock icon instead of the number); nothing from other tiers is in the grid.
      expect(find.text('253'), findsNothing);
      expect(find.text('1'), findsNothing);
    });

    testWidgets('opens on the tier of the next level', (tester) async {
      await _fresh();
      final p = Progress.instance;
      await _win(p, 'sudoku', [for (var l = 1; l <= 125; l++) l]);
      await pumpPage(tester);
      await tester.scrollUntilVisible(find.text('125/125'), 200, scrollable: scrollable());
      await tester.scrollUntilVisible(find.text('126'), 200, scrollable: scrollable());
      expect(find.text('127'), findsOneWidget);
    });
  });
}
