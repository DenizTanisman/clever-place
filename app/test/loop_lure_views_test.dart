// Render tests for the N-Back level view (lure feedback, result line) and the Surakarta view (loop
// capture badges, threats, help sheet, tutorial demo). The sessions are never started, so the
// views run on hand-made states without the native core. Run with `flutter test`.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clever_place/clever/core_bridge.dart';
import 'package:clever_place/clever/games/nback_view.dart';
import 'package:clever_place/clever/games/surakarta_view.dart';
import 'package:clever_place/clever/tutorials/surakarta.dart';

Widget _host(GameSession s, Widget Function(BuildContext, GameSession) view, {double width = 392}) => MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: SizedBox(
          width: width,
          height: 820,
          child: ListenableBuilder(listenable: s, builder: (context, _) => view(context, s)),
        ),
      ),
    );

Map<String, dynamic> _nbackState({required String phase, String status = 'playing', Map? feedback, String? lureSummary}) => {
      'status': status,
      'stars': status == 'won' ? 2 : 0,
      'mode': 'level',
      'phase': phase,
      'title': '3-Back',
      'goal': '17 eşleşme yakala · 3 hata hakkı',
      'n': 3,
      'set': 'digits',
      'set_label': 'Rakamlar',
      'lures': true,
      'trial': 20,
      'trials': 91,
      'period_ms': 2300,
      'stim_ms': 480,
      't_ms': 900,
      'countdown_ms': 0,
      'stim': null,
      'can_match': true,
      'pressed': true,
      'hits': 17,
      'goal_hits': 17,
      'misses': 0,
      'false_alarms': 1,
      'errors': 1,
      'error_budget': 5,
      'errors_left': 4,
      'efficiency': 0.944,
      'elapsed_ms': 140000,
      'avg_rt_ms': 610,
      'feedback': feedback ?? {'serial': 0, 'result': '', 'lure_kind': null},
      'lure_falls': {'n-1': 1, 'n+1': 0, 'seq': 0},
      'lure_summary': lureSummary,
      'helper': false,
      'recent': [],
    };

List<List<int>> _board(List<List<int>> you, List<List<int>> ai) {
  final b = List.generate(6, (_) => List.filled(6, 0));
  for (final p in you) {
    b[p[0]][p[1]] = 1;
  }
  for (final p in ai) {
    b[p[0]][p[1]] = 2;
  }
  return b;
}

Map<String, dynamic> _surakartaState() => {
      'status': 'playing',
      'stars': 0,
      'title': 'Acemi',
      'goal': '',
      'level': 1,
      'turn': 'you',
      'ai_pending': false,
      'board': _board([
        [4, 1],
        [3, 1],
        [5, 5],
      ], [
        [4, 3],
        [0, 0],
      ]),
      'counts': {'you': 3, 'ai': 2},
      'captured': {'you': 10, 'ai': 9},
      'quiet': 3,
      'quiet_limit': 40,
      'last_move': null,
      'moves': [
        {
          'from': [4, 1],
          'to': [4, 3],
          'capture': true,
          'path': [
            {'pt': [4, 1]},
            {'pt': [5, 1]},
            {
              'arc': {'corner': 3, 'circuit': 'inner'}
            },
            {'pt': [4, 0]},
            {'pt': [4, 1]},
            {'pt': [4, 2]},
            {'pt': [4, 3]},
          ],
        },
        {'from': [4, 1], 'to': [5, 1], 'capture': false, 'path': null},
        {'from': [5, 5], 'to': [4, 5], 'capture': false, 'path': null},
      ],
      'threats': [
        [4, 1]
      ],
      'hint': null,
      'can_undo': false,
      'complexity': 0.3,
      'end_reason': '',
      'player_moves': 4,
      'summary': null,
    };

Future<void> _loadFonts() async {
  // Real faces, so layout (overflow) checks measure what the phone shows, not the square test font.
  for (final (family, files) in [
    ('Jost', ['Jost-Regular', 'Jost-Medium', 'Jost-SemiBold', 'Jost-Bold']),
    ('Cormorant', ['CormorantGaramond-Medium', 'CormorantGaramond-SemiBold', 'CormorantGaramond-Bold']),
  ]) {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(File('assets/fonts/$f.ttf').readAsBytes().then((b) => ByteData.view(b.buffer)));
    }
    await loader.load();
  }
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('N-Back names the lure after a false alarm and lists lure falls on the result card', (tester) async {
    final s = GameSession(game: 'nback', level: 50)..state = _nbackState(phase: 'run');
    await tester.pumpWidget(_host(s, nbackView, width: 360));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('Çeldirici'), findsNothing);
    s.state = _nbackState(phase: 'run', feedback: {'serial': 3, 'result': 'false_alarm', 'lure_kind': 'n-1'});
    s.notifyListeners();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Çeldirici · 2 önceki ile aynı (n−1)'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    s.state = _nbackState(
        phase: 'done', status: 'won', lureSummary: '1 çeldiriciye takıldın (n−1)', feedback: {'serial': 4, 'result': 'hit', 'lure_kind': null});
    s.notifyListeners();
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('1 çeldiriciye takıldın (n−1)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('N-Back intro fits 17 goal segments and 5 error pips', (tester) async {
    final s = GameSession(game: 'nback', level: 1)..state = _nbackState(phase: 'intro');
    await tester.pumpWidget(_host(s, nbackView, width: 360));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('17 eşleşme yakala'), findsOneWidget);
    expect(find.textContaining('çeldiriciler var'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Surakarta marks loop captures, threats, selection and opens the loop help', (tester) async {
    final s = GameSession(game: 'surakarta', level: 1)..state = _surakartaState();
    await tester.pumpWidget(_host(s, surakartaView));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Halkadan alış var'), findsOneWidget);
    // Select the capturing piece: the capture path preview and target badge are painted.
    final board = tester.getRect(find.byWidgetPredicate((w) => w is GestureDetector && w.onPanStart != null));
    final cell = board.width / (5 + 2 * 2.55);
    final origin = board.topLeft + Offset(cell * 2.55, cell * 2.55);
    await tester.tapAt(origin + Offset(1 * cell, 4 * cell));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    // The help sheet with the animated demo.
    await tester.tap(find.byIcon(Icons.all_inclusive_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SurakartaLoopDemo), findsOneWidget);
    expect(find.textContaining('geriye doğru gidip halkadan dönerek'), findsOneWidget);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 470)); // scene 1 in all its phases, into scene 2
    }
    expect(find.textContaining('İki halka'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Surakarta tutorial opens with the loop-capture demo', (tester) async {
    final first = surakartaTutorials.mid.first;
    expect(first.title, contains('Halka ile alış'));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: first.diagram!))));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 400)); // first scene: pick, ride, capture
    }
    expect(find.textContaining('Geriye yuvarlama'), findsOneWidget);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(find.textContaining('İki halka'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
