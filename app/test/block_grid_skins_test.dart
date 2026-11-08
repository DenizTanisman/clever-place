// Blok Merkezi skins: unlock thresholds, persistence, callouts and drawing smoke tests.

import 'dart:ui' as ui;

import 'package:clever_place/clever/games/block_grid_skin_picker.dart';
import 'package:clever_place/clever/games/block_grid_skins.dart';
import 'package:clever_place/clever/games/block_grid_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<BlockSkinStore> _store([Map<String, Object> values = const {}]) async {
  SharedPreferences.setMockInitialValues(values);
  return BlockSkinStore(await SharedPreferences.getInstance());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('unlock thresholds', () {
    test('catalogue: unique ids, default first, thresholds strictly increasing', () {
      const all = BlockSkins.all;
      expect(all.length, greaterThanOrEqualTo(6));
      expect(all.map((s) => s.id).toSet().length, all.length);
      expect(all.first.isDefault, isTrue);
      for (var i = 0; i < all.length; i++) {
        expect(all[i].index, i, reason: 'index matches position for ${all[i].id}');
        if (i > 0) {
          expect(all[i].isDefault, isFalse);
          expect(all[i].unlockLevel, greaterThan(all[i - 1].unlockLevel));
          expect(all[i].unlockLines, greaterThan(all[i - 1].unlockLines));
          expect(all[i].hues, isNotEmpty);
        }
      }
    });

    test('a fresh player has only the default skin', () {
      expect(BlockSkins.unlocked(level: 0, lines: 0).map((s) => s.id), ['zumrut']);
    });

    test('each skin unlocks exactly at its level or its line count', () {
      for (final s in BlockSkins.all.skip(1)) {
        expect(s.unlockedBy(level: s.unlockLevel - 1, lines: s.unlockLines - 1), isFalse, reason: s.id);
        expect(s.unlockedBy(level: s.unlockLevel, lines: 0), isTrue, reason: '${s.id} by level');
        expect(s.unlockedBy(level: 0, lines: s.unlockLines), isTrue, reason: '${s.id} by lines');
      }
    });

    test('concrete rules', () {
      expect([for (final s in BlockSkins.all) (s.id, s.unlockLevel, s.unlockLines)], [
        ('zumrut', 0, 0),
        ('ahsap', 10, 100),
        ('seker', 25, 250),
        ('mermer', 50, 500),
        ('neon', 75, 800),
        ('buz', 100, 1200),
        ('mucevher', 150, 2000),
      ]);
      expect(BlockSkins.unlocked(level: 49, lines: 260).map((s) => s.id), ['zumrut', 'ahsap', 'seker']);
      expect(BlockSkins.unlocked(level: 500, lines: 0).length, BlockSkins.all.length);
      expect(BlockSkins.neon.unlockText, '75. bölümü geç ya da 800 satır/sütun/kare temizle');
    });
  });

  group('store', () {
    test('defaults', () async {
      final st = await _store();
      expect(st.skin.id, 'zumrut');
      expect(st.lines, 0);
      expect(st.level, 0);
      expect(st.unseen, isEmpty);
    });

    test('addLines reports newly unlocked skins once and persists the counter', () async {
      final st = await _store();
      expect(await st.addLines(99), isEmpty);
      expect((await st.addLines(1)).map((s) => s.id), ['ahsap']);
      expect(await st.addLines(1), isEmpty);
      expect((await st.addLines(400)).map((s) => s.id), ['seker', 'mermer']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(BlockSkinStore.kLines), 501);
      expect(BlockSkinStore(prefs).lines, 501);
    });

    test('reachLevel only moves forward and reports unlocks', () async {
      final st = await _store();
      expect((await st.reachLevel(25)).map((s) => s.id), ['ahsap', 'seker']);
      expect(await st.reachLevel(12), isEmpty);
      expect(st.level, 25);
      expect((await SharedPreferences.getInstance()).getInt(BlockSkinStore.kLevel), 25);
    });

    test('level is derived from stars already earned', () async {
      final st = await _store({'cp.stars.block_grid.3': 2, 'cp.stars.block_grid.52': 1, 'cp.stars.other.300': 3});
      expect(st.level, 52);
      expect(st.unlocked.map((s) => s.id), ['zumrut', 'ahsap', 'seker', 'mermer']);
      expect(st.unseen.map((s) => s.id), ['ahsap', 'seker', 'mermer']);
    });

    test('selection persists; locked skins cannot be selected', () async {
      final st = await _store();
      expect(await st.select(BlockSkins.neon), isFalse);
      expect(st.skin.id, 'zumrut');
      await st.addLines(800);
      expect(await st.select(BlockSkins.neon), isTrue);
      final again = BlockSkinStore(await SharedPreferences.getInstance());
      expect(again.skin.id, 'neon');
      expect(again.unseen.map((s) => s.id), isNot(contains('neon')));
    });

    test('a stored skin that is no longer unlocked falls back to the default', () async {
      final st = await _store({BlockSkinStore.kSkin: 'mucevher', BlockSkinStore.kLines: 10});
      expect(st.skin.id, 'zumrut');
      final unknown = await _store({BlockSkinStore.kSkin: 'nope'});
      expect(unknown.skin.id, 'zumrut');
    });

    test('markSeen clears the new-skin dot and persists', () async {
      final st = await _store({BlockSkinStore.kLines: 300});
      expect(st.unseen.length, 2);
      await st.markSeen();
      expect(st.unseen, isEmpty);
      expect(BlockSkinStore(await SharedPreferences.getInstance()).unseen, isEmpty);
    });
  });

  test('callouts escalate with units and streak', () {
    expect(blockCallout(1, 1, false), (word: 'Güzel!', tier: 1));
    expect(blockCallout(2, 1, false), (word: 'Harika!', tier: 2));
    expect(blockCallout(1, 2, false), (word: 'Harika!', tier: 2));
    expect(blockCallout(3, 1, false), (word: 'Muhteşem!', tier: 3));
    expect(blockCallout(2, 2, false), (word: 'Muhteşem!', tier: 3));
    expect(blockCallout(4, 1, false), (word: 'Efsane!', tier: 4));
    expect(blockCallout(1, 9, false), (word: 'Efsane!', tier: 4));
    expect(blockCallout(1, 1, true), (word: 'Tertemiz!', tier: 4));
  });

  testWidgets('every skin renders its tiles, stones and board', (tester) async {
    for (final skin in BlockSkins.all) {
      for (var t = -1; t < skin.hues.length; t++) {
        for (var v = 0; v < skin.variants; v++) {
          final img = BlockTiles.render(skin, t, v, 48);
          expect(img.width, 48);
          img.dispose();
        }
      }
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      BlockTiles.paintBoardBackground(c, const Size(270, 270), skin);
      BlockTiles.paintBoardForeground(c, const Size(270, 270), skin);
      rec.endRecording().dispose();
    }
  });

  testWidgets('picker shows locked skins with their condition and selects unlocked ones', (tester) async {
    final st = await _store({BlockSkinStore.kLines: 120});
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: BlockSkinPicker(store: st))),
    ));
    expect(find.text('Görünümler'), findsOneWidget);
    expect(find.text('Ahşap'), findsOneWidget);
    expect(find.text(BlockSkins.seker.unlockText), findsOneWidget);
    expect(find.byIcon(Icons.lock_rounded), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('skin-seker')));
    await tester.pump();
    expect(st.skin.id, 'zumrut', reason: 'locked skin is not selectable');

    await tester.tap(find.byKey(const ValueKey('skin-ahsap')));
    await tester.pumpAndSettle();
    expect(st.skin.id, 'ahsap');
    expect((await SharedPreferences.getInstance()).getString(BlockSkinStore.kSkin), 'ahsap');
  });
}
