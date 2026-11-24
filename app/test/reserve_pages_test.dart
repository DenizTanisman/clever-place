// "Zümrüt Rezerv" game page and level result (owner, 2026-11-24): winning times per tier, the page's
// numbers row and pinned play button, and the rules + tutorials behind "Nasıl oynanır".

import 'package:clever_place/clever/catalog.dart';
import 'package:clever_place/clever/game_home_screen.dart';
import 'package:clever_place/clever/level_result.dart';
import 'package:clever_place/clever/premium_kit.dart';
import 'package:clever_place/clever/progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<Progress> _fresh() async {
  SharedPreferences.setMockInitialValues({});
  final p = await Progress.loadFresh();
  p.visibleLevels = 500;
  return p;
}

void main() {
  group('winning times', () {
    test('keep the last ten per tier and return the best before each win', () async {
      final p = await _fresh();
      // Levels 376–500 are Uzman (tier 3).
      expect(await p.recordTime('sudoku', 400, 300000), isNull, reason: 'first time in Uzman');
      expect(p.bestTime('sudoku', 3), 300000);
      expect(await p.recordTime('sudoku', 401, 320000), 300000);
      expect(p.bestTime('sudoku', 3), 300000, reason: 'a slower win keeps the record');
      expect(await p.recordTime('sudoku', 402, 208000), 300000);
      expect(p.bestTime('sudoku', 3), 208000);
      // Another tier has its own list and record.
      expect(await p.recordTime('sudoku', 5, 90000), isNull);
      expect(p.recentTimes('sudoku', 0), [90000]);
      for (var i = 0; i < 12; i++) {
        await p.recordTime('sudoku', 403 + i, 250000 + i);
      }
      final recent = p.recentTimes('sudoku', 3);
      expect(recent.length, Progress.recentTimesKept);
      expect(recent.first, 250002, reason: 'oldest dropped first');
      expect(recent.last, 250011);
    });

    test('clock and record texts', () {
      expect(clockTime(208000), '3:28');
      expect(clockTime(59600), '1:00');
      expect(clockTime(3723000), '1:02:03');
      expect(recordGain(400), '0,4 sn');
      expect(recordGain(14000), '14 sn');
      expect(recordGain(65000), '1:05');
    });
  });

  group('game page', () {
    Future<void> pumpPage(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: GameHomeScreen(game: kCoreGames.first)));
      await tester.pump();
    }

    testWidgets('numbers row, tier record and the pinned play button', (tester) async {
      final p = await _fresh();
      await p.recordStars('sudoku', 1, 3);
      await p.recordTime('sudoku', 1, 95000);
      await pumpPage(tester);
      expect(find.text('MANTIK BULMACALARI'), findsOneWidget);
      expect(find.text('1/500'), findsOneWidget);
      expect(find.text('Kolay rekoru'), findsOneWidget);
      expect(find.text('1:35'), findsOneWidget);
      expect(find.text('Oyna · Bölüm 2'), findsOneWidget);
      expect(find.text('Kolay · 1/125'), findsOneWidget);
      // The rules are no longer on the page itself.
      expect(find.textContaining('KURALLAR'), findsNothing);
    });

    testWidgets('"Nasıl oynanır" opens the rules and both courses', (tester) async {
      await _fresh();
      await pumpPage(tester);
      await tester.tap(find.byKey(const ValueKey('how-to-play')));
      await tester.pumpAndSettle();
      expect(find.text('Nasıl oynanır'), findsWidgets);
      expect(find.textContaining('KURALLAR'), findsOneWidget);
      await tester.dragUntilVisible(find.text('Orta seviye'), find.byType(ListView).last, const Offset(0, -300));
      expect(find.text('Orta seviye'), findsOneWidget);
      expect(find.text('İleri seviye'), findsOneWidget);
    });

    testWidgets('a finished tier hides the play button', (tester) async {
      final p = await _fresh();
      for (var l = 1; l <= 125; l++) {
        await p.recordStars('sudoku', l, 1);
      }
      await p.setTier('sudoku', 0);
      await pumpPage(tester);
      expect(find.byKey(const ValueKey('play-next')), findsNothing);
      expect(find.text('Kolay'), findsOneWidget);
    });
  });

  group('level result', () {
    Future<void> pumpResult(WidgetTester tester, {required bool won, int? before, Map<String, dynamic>? state}) async {
      tester.view.physicalSize = const Size(1170, 2532); // 390 x 844
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: LevelResultView(
            gameId: 'sudoku',
            gameName: 'Sudoku',
            level: 402,
            won: won,
            stars: won ? 3 : 0,
            state: state ?? const {'mistakes': 0, 'hints': 1},
            timeMs: 208000,
            bestBefore: before,
            timeSaved: won,
            daily: false,
            mainLabel: won ? 'Sonraki bölüm · 403' : 'Tekrar dene',
            mainIcon: won ? Icons.arrow_forward_rounded : Icons.refresh_rounded,
            mainIconAfter: won,
            mainKey: const ValueKey('result-main'),
            onMain: () {},
            more: [(label: 'Tekrar oyna', onPressed: () {}), (label: 'Bölümler', onPressed: () {})],
            onClose: () {},
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('a record win: stats, recent times and the record badge fit a phone', (tester) async {
      final p = await _fresh();
      for (final t in [292000, 271000, 222000, 229000]) {
        await p.recordTime('sudoku', 400, t);
      }
      await p.recordTime('sudoku', 402, 208000);
      await pumpResult(tester, won: true, before: 222000);
      expect(find.text('SUDOKU · UZMAN'), findsOneWidget);
      expect(find.text('Bölüm 402'), findsOneWidget);
      expect(find.text('TAMAMLANDI'), findsOneWidget);
      expect(find.text('3:28'), findsOneWidget);
      expect(find.text('Hata'), findsOneWidget);
      expect(find.text('İpucu'), findsOneWidget);
      expect(find.text('Son 5 Uzman bölümü'), findsOneWidget);
      expect(find.text('Yeni rekor · −14 sn'), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
      expect(find.text('Sonraki bölüm · 403'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a loss: no stars, no chart, retry first; a game without counts shows the stars', (tester) async {
      await _fresh();
      await pumpResult(tester, won: false, state: const {});
      expect(find.text('OLMADI'), findsOneWidget);
      expect(find.text('Yıldız'), findsOneWidget);
      expect(find.text('0/3'), findsOneWidget);
      expect(find.textContaining('Yeni rekor'), findsNothing);
      expect(find.text('Tekrar dene'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
