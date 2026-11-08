import 'dart:convert';

import 'package:clever_place/clever/cube/cube_book.dart';
import 'package:clever_place/clever/cube/cube_book_screen.dart';
import 'package:clever_place/clever/cube/cube_player.dart';
import 'package:clever_place/clever/cube/cube_quiz_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every block, cards inside Tek El Planı's boxes included.
Iterable<BookBlock> blocks(CubeBook b) sync* {
  Iterable<BookBlock> walk(List<BookBlock> bs) sync* {
    for (final x in bs) {
      yield x;
      if (x is CardBlock) yield* walk(x.children);
    }
  }

  yield* walk(b.intro);
  for (final s in b.sections) {
    yield* walk(s.blocks);
  }
  yield* walk(b.foot);
}

Iterable<String> svgs(CubeBook b) sync* {
  for (final x in blocks(b)) {
    if (x is CaseBlock) yield* x.figs.map((f) => f.svg);
    if (x is MovesBlock) yield* x.items.map((m) => m.svg);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CubeBook defter, tekEl;

  setUpAll(() async {
    defter = CubeBook.parse(await rootBundle.loadString(CubeBook.defter), asset: CubeBook.defter);
    tekEl = CubeBook.parse(await rootBundle.loadString(CubeBook.tekEl), asset: CubeBook.tekEl);
  });

  group('assets', () {
    // Counts of the sources: the notebook has 155 cards and 184 <svg>
    // (one is the arrow-marker <defs>); 84 of the old recall pack's 87 questions still hold,
    // 99 more are made from the cards and the glossary. Tek El Planı: 5 sections, 28 questions.
    test('Küp Defteri', () {
      expect(defter.title, 'Küp Defteri');
      expect(defter.sections.map((s) => s.id),
          ['x3', 'gosteri', 'x4', 'mega', 'x2', 'ek', 'sozluk', 'notasyon']);
      expect(blocks(defter).whereType<CaseBlock>(), hasLength(155));
      expect(svgs(defter), hasLength(183));
      expect(defter.questions.where((q) => !q.id.startsWith('gen-')), hasLength(84));
      expect(defter.questions.where((q) => q.id.startsWith('gen-')), hasLength(104));
      expect(blocks(defter).whereType<GlossBlock>().expand((g) => g.items), hasLength(40));
      expect(blocks(defter).whereType<MovesBlock>().single.items, hasLength(12));
      final sexy = blocks(defter).whereType<CaseBlock>().firstWhere((c) => c.title == 'Köşe yerinde ve doğru');
      expect(sexy.algs.single.trigs.single, (moves: "(U R U' R')", name: 'Ters sexy'));
    });

    test('Tek El Planı', () {
      expect(tekEl.sections.map((s) => s.id), ['hedef', 'yol', 'kurallar', 'calisma', 'malzeme']);
      expect(tekEl.questions, hasLength(28));
      expect(blocks(tekEl).whereType<TableBlock>(), hasLength(2));
      expect(blocks(tekEl).whereType<CardBlock>(), hasLength(19));
    });

    test('every question is well formed and its anchor is in its book', () {
      for (final b in [defter, tekEl]) {
        final ids = {for (final s in b.sections) s.id};
        for (final q in b.questions) {
          expect(q.options, hasLength(4), reason: q.id);
          expect(q.options.toSet(), hasLength(4), reason: q.id);
          expect(q.answer, inInclusiveRange(0, 3), reason: q.id);
          expect(ids, contains(q.section), reason: q.id);
          if (q.anchor != null) expect(b.sectionOf(q.anchor!), isNot(-1), reason: '${q.id} → ${q.anchor}');
        }
        expect(b.questions.map((q) => q.id).toSet(), hasLength(b.questions.length));
      }
    });

    // The index comes from the web player's own logic on the notebook; in a browser
    // the notebook shows 220 ▶ (125 Megaminx, 78 3x3, 15 2x2, 2 4x4).
    test('3D player: index fits the notebook, the offline page is bundled', () async {
      final index = CubePlayerIndex.parse(await rootBundle.loadString(CubePlayerIndex.asset));
      final cases = {for (final c in blocks(defter).whereType<CaseBlock>()) c.id: c};
      final kinds = <String, int>{};
      for (final MapEntry(key: id, value: rows) in index.cases.entries) {
        expect(cases, contains(id));
        expect(rows, hasLength(cases[id]!.algs.length), reason: id);
        for (final e in rows.nonNulls) {
          kinds.update(CubePlayerIndex.kind(e), (n) => n + 1, ifAbsent: () => 1);
          final segs = e['segs'] as List;
          expect(segs, isNotEmpty, reason: id);
          for (final g in segs) {
            expect((g as List)[1] as String, isNotEmpty, reason: id);
          }
        }
      }
      expect(kinds, {'Megaminx': 125, '3x3': 78, '2x2': 15, '4x4': 2});
      // Prose rows get no ▶.
      final co = blocks(defter).whereType<CaseBlock>().firstWhere((c) => c.title.startsWith("CO · R' D' R D"));
      final tekrar = co.algs.indexWhere((a) => a.label == 'Tekrar');
      expect(index.entry(co.id, tekrar), isNull);
      expect(index.entry(co.id, 0), isNotNull);

      final html = await rootBundle.loadString(CubePlayerIndex.page);
      for (final f in ['three.min.js', 'model.js', 'mega.js', 'player.js', 'player.css']) {
        expect(html, contains('"$f"'));
        final data = await rootBundle.load('assets/cube/player/$f');
        expect(data.lengthInBytes, greaterThan(1000), reason: f);
      }
      expect(html.contains('http'), isFalse, reason: 'the page must not need the network');
    });

    test('every diagram is self-contained SVG flutter_svg can load', () async {
      final all = svgs(defter).toList();
      for (final s in all) {
        expect(s, startsWith('<svg xmlns="http://www.w3.org/2000/svg"'));
        expect(s.contains('var('), isFalse);
        expect(s.contains('marker'), isFalse);
      }
      for (final s in all) {
        final info = await vg.loadPicture(SvgStringLoader(s), null);
        expect(info.size.width, greaterThan(0));
        info.picture.dispose();
      }
    });
  });

  group('CubeDrill', () {
    CubeQuestion q(String id, {int stage = 1}) => CubeQuestion(
        book: '', id: id, section: 's', stage: stage, anchor: null, q: id, options: const ['a', 'b', 'c', 'd'], answer: 0, why: '');

    test('wrong goes back to box 1 and comes first; right waits', () {
      final d = CubeDrill.decode(null);
      const day = 24 * 3600 * 1000;
      final qs = [q('a'), q('b'), q('c', stage: 2)];
      expect(d.order(qs, 0).map((x) => x.id), ['a', 'b', 'c']);
      d.record('a', right: true, nowMs: 0); // box 2: due in a day
      d.record('b', right: false, nowMs: 0); // box 1: due now
      expect(d.box('a'), 2);
      expect(d.box('b'), 1);
      expect(d.due('a', day - 1), isFalse);
      expect(d.due('a', day), isTrue);
      expect(d.order(qs, 10).map((x) => x.id), ['c', 'b', 'a']);
      final back = CubeDrill.decode(d.encode());
      expect(back.box('a'), 2);
      expect(CubeDrill.decode('bozuk').box('a'), 0);
    });
  });

  group('screens', () {
    Future<void> pumpScreen(WidgetTester tester, Widget w) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(CubeBook.loadAll);
      await tester.runAsync(CubePlayerIndex.load);
      await tester.pumpWidget(MaterialApp(home: w));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('reader: test mode hides the algorithms until a card is tapped', (tester) async {
      await pumpScreen(tester, const CubeBookScreen(asset: CubeBook.defter, title: 'Küp Defteri'));
      expect(find.text('3x3'), findsOneWidget);
      expect(find.textContaining('Köşe yerinde ve doğru'), findsWidgets);
      expect(find.byKey(const Key('cube-alg-hidden')), findsNothing);

      await tester.tap(find.byKey(const Key('cube-book-test')));
      await tester.pump();
      final hidden = tester.widgetList(find.byKey(const Key('cube-alg-hidden'), skipOffstage: false)).length;
      expect(hidden, greaterThan(20));

      await tester.tap(find.textContaining('Köşe yerinde ve doğru').first);
      await tester.pump();
      expect(tester.widgetList(find.byKey(const Key('cube-alg-hidden'), skipOffstage: false)).length, lessThan(hidden));

      await tester.dragUntilVisible(find.text('Sözlük'), find.byType(ListView).first, const Offset(-200, 0));
      await tester.tap(find.text('Sözlük'));
      await tester.pump();
      expect(find.textContaining('Sexy move'), findsWidgets);
    });

    testWidgets('reader: explanations start folded, open one by one or all at once', (tester) async {
      await pumpScreen(tester, const CubeBookScreen(asset: CubeBook.defter, title: 'Küp Defteri'));
      const hint = 'Kenar ön üstte, ön rengi öne bakıyor.';
      const lead = 'Köşe kendi slotunda. Kenar üst katmanda dolaşıyor.';
      expect(find.text(hint, findRichText: true), findsNothing);
      expect(find.text(lead, findRichText: true), findsNothing);
      expect(find.text("(U R U' R') U' F' U F"), findsOneWidget); // the algorithm stays

      final toggle = find.descendant(
          of: find.byKey(const ValueKey('cube-explain-mdec6e6d6a0')), matching: find.text('Açıklama'));
      await tester.tap(toggle);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(hint, findRichText: true), findsOneWidget);
      expect(find.text(lead, findRichText: true), findsNothing);
      await tester.tap(toggle);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(hint, findRichText: true), findsNothing);

      await tester.tap(find.byKey(const Key('cube-book-explain-all')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(hint, findRichText: true), findsOneWidget);
      expect(find.text(lead, findRichText: true), findsOneWidget);
      await tester.tap(find.byKey(const Key('cube-book-explain-all')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(hint, findRichText: true), findsNothing);
      expect(find.text(lead, findRichText: true), findsNothing);

      // In test mode the toggle opens the explanation without revealing the card.
      await tester.tap(find.byKey(const Key('cube-book-test')));
      await tester.pump();
      final hidden = tester.widgetList(find.byKey(const Key('cube-alg-hidden'), skipOffstage: false)).length;
      await tester.tap(toggle);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(hint, findRichText: true), findsOneWidget);
      expect(tester.widgetList(find.byKey(const Key('cube-alg-hidden'), skipOffstage: false)), hasLength(hidden));
    });

    testWidgets('reader: every row the web player plays has a ▶, the rest none', (tester) async {
      await pumpScreen(tester, const CubeBookScreen(asset: CubeBook.defter, title: 'Küp Defteri'));
      final index = await tester.runAsync(CubePlayerIndex.load);

      // Test mode: no ▶ until the card is revealed (the player would show the moves).
      await tester.tap(find.byKey(const Key('cube-book-test')));
      await tester.pump();
      expect(find.byIcon(Icons.play_circle_outline, skipOffstage: false), findsNothing);
      await tester.tap(find.textContaining('Köşe yerinde ve doğru').first);
      await tester.pump();
      expect(find.byKey(const ValueKey('cube-play-mdec6e6d6a0-0')), findsOneWidget);
      await tester.tap(find.byKey(const Key('cube-book-test')));
      await tester.pump();

      var buttons = 0;
      for (final s in defter.sections) {
        final chip = find.widgetWithText(ChoiceChip, s.title);
        await tester.ensureVisible(chip);
        await tester.tap(chip);
        await tester.pump();
        for (final c in s.blocks.whereType<CaseBlock>()) {
          for (var i = 0; i < c.algs.length; i++) {
            final play = find.byKey(ValueKey('cube-play-${c.id}-$i'), skipOffstage: false);
            final playable = index!.entry(c.id, i) != null;
            expect(play, playable ? findsOneWidget : findsNothing, reason: '${c.title} · ${c.algs[i].label}');
            if (playable) buttons++;
          }
        }
        expect(find.byIcon(Icons.play_circle_outline, skipOffstage: false),
            findsNWidgets(s.blocks.whereType<CaseBlock>().expand((c) => [
                  for (var i = 0; i < c.algs.length; i++)
                    if (index!.entry(c.id, i) != null) 1
                ]).length));
      }
      expect(buttons, 220);
    });

    testWidgets('reader: an anchor opens its section', (tester) async {
      await pumpScreen(tester,
          const CubeBookScreen(asset: CubeBook.defter, title: 'Küp Defteri', initialAnchor: 'x4-oll-parity'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('OLL parity'), findsWidgets);
      final chip = tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '4x4'));
      expect(chip.selected, isTrue);
    });

    testWidgets('quiz: answer, the box moves, the next one comes, the notebook opens', (tester) async {
      SharedPreferences.setMockInitialValues({});
      const now = 1000000;
      await pumpScreen(tester, CubeQuizScreen(clock: () => now));

      final all = [...defter.questions, ...tekEl.questions];
      final first = CubeDrill.decode(null).order(all, now).first;
      expect(find.text(first.q), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('cube-option-${first.answer}')));
      await tester.pump();
      expect(find.text('Doğru'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(CubeDrill.decode(prefs.getString(CubeDrill.storageKey)).box(first.id), 2);

      await tester.tap(find.text('Sonraki'));
      await tester.pump();
      expect(find.text(first.q), findsNothing);
      final second = all.firstWhere((q) => find.text(q.q).evaluate().isNotEmpty);
      final wrong = (second.answer + 1) % 4;
      await tester.tap(find.byKey(ValueKey('cube-option-$wrong')));
      await tester.pump();
      expect(find.text('Yanlış'), findsOneWidget);
      expect(CubeDrill.decode(prefs.getString(CubeDrill.storageKey)).box(second.id), 1);

      if (second.anchor != null) {
        await tester.tap(find.text('Defterde gör'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byType(CubeBookScreen), findsOneWidget);
      }
    });

    testWidgets('quiz: filter to one section', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpScreen(tester, const CubeQuizScreen());
      await tester.tap(find.widgetWithText(ChoiceChip, 'Tek El Planı'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ChoiceChip, tekEl.sections.first.title));
      await tester.pump();
      final shown = tekEl.questions.where((q) => find.text(q.q).evaluate().isNotEmpty);
      expect(shown.single.section, tekEl.sections.first.id);
      expect(find.text('Öğrenildi 0 / ${tekEl.questions.where((q) => q.section == 'hedef').length}'), findsOneWidget);
    });

    test('summary counts every question', () async {
      SharedPreferences.setMockInitialValues({
        CubeDrill.storageKey: jsonEncode({
          defter.questions.first.id: [3, DateTime.now().millisecondsSinceEpoch],
        }),
      });
      final s = await CubeQuizScreen.summary();
      expect(s.total, defter.questions.length + tekEl.questions.length);
      expect(s.learned, 1);
      expect(s.due, s.total - 1);
    });
  });
}
