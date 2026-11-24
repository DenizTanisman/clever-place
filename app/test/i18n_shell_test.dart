// Turkish / English (owner, 2026-11-24): the hub, game page and level result in English, and the
// translation helpers.

import 'package:clever_place/clever/catalog.dart';
import 'package:clever_place/clever/game_home_screen.dart';
import 'package:clever_place/clever/hub_screen.dart';
import 'package:clever_place/clever/i18n/lang.dart';
import 'package:clever_place/clever/level_result.dart';
import 'package:clever_place/clever/lux.dart';
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

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

void main() {
  tearDown(() => Lang.set('tr'));

  group('helpers', () {
    test('Turkish passes through, English looks up, placeholders fill in', () {
      Lang.set('tr');
      expect(t('Ayarlar'), 'Ayarlar');
      expect(tf('Bölüm {0}', [7]), 'Bölüm 7');
      expect(ct('Bölüm 7'), 'Bölüm 7');
      Lang.set('en');
      expect(t('Ayarlar'), 'Settings');
      expect(tf('Bölüm {0}', [7]), 'Level 7');
      expect(t('bu metin sözlükte yok'), 'bu metin sözlükte yok');
      expect(Lux.upper('Music'), 'MUSIC');
      Lang.set('tr');
      expect(Lux.upper('Müzik'), 'MÜZİK');
    });

    test('every game name, tagline and category has English', () {
      Lang.set('en');
      final missing = <String>[
        for (final g in [...kCoreGames, kCubeGame]) ...[
          if (Lang.english(g.name) == null) g.name,
          if (g.tagline.isNotEmpty && Lang.english(g.tagline) == null) g.tagline,
        ],
        for (final c in GameCategory.values)
          if (Lang.english(c.label) == null) c.label,
      ];
      expect(missing, isEmpty);
    });

    test('every game has English rules', () {
      final missing = [
        for (final g in kCoreGames)
          if (g.tutorials.rules.trim().isNotEmpty && g.tutorials.rulesEn == null) g.id,
      ];
      expect(missing, isEmpty);
    });
  });

  group('screens in English', () {
    testWidgets('hub', (tester) async {
      await _fresh();
      Lang.set('en');
      _phone(tester);
      await tester.pumpWidget(const MaterialApp(home: HubScreen()));
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Clever Place'), findsOneWidget);
      expect(find.text('MIND CLUB'), findsOneWidget);
      expect(find.text('TODAY\'S GOAL'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('game page and its rules', (tester) async {
      await _fresh();
      Lang.set('en');
      _phone(tester);
      await tester.pumpWidget(MaterialApp(home: GameHomeScreen(game: kCoreGames.first)));
      await tester.pump();
      expect(find.text('How to play'), findsOneWidget);
      expect(find.text('Play · Level 1'), findsOneWidget);
      expect(find.text('Easy'), findsOneWidget);
      expect(find.text('Easy best'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('how-to-play')));
      await tester.pumpAndSettle();
      expect(find.textContaining('RULES'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('level result', (tester) async {
      await _fresh();
      Lang.set('en');
      _phone(tester);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: LevelResultView(
            gameId: 'sudoku',
            gameName: 'Sudoku',
            level: 402,
            won: true,
            stars: 2,
            state: const {'mistakes': 1, 'hints': 0},
            timeMs: 208000,
            bestBefore: null,
            timeSaved: true,
            daily: false,
            mainLabel: tf('Sonraki bölüm · {0}', [403]),
            mainIcon: Icons.arrow_forward_rounded,
            mainIconAfter: true,
            mainKey: const ValueKey('result-main'),
            onMain: () {},
            more: [(label: t('Tekrar oyna'), onPressed: () {}), (label: t('Bölümler'), onPressed: () {})],
            onClose: () {},
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('SUDOKU · EXPERT'), findsOneWidget);
      expect(find.text('Level 402'), findsOneWidget);
      expect(find.text('COMPLETE'), findsOneWidget);
      expect(find.text('Time'), findsOneWidget);
      expect(find.text('Mistakes'), findsOneWidget);
      expect(find.text('Next level · 403'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
