import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:clever_place/clever/art/game_art.dart';
import 'package:clever_place/clever/catalog.dart';
import 'package:clever_place/clever/core_bridge.dart';
import 'package:clever_place/clever/games/donen_sayilar_view.dart';
import 'package:clever_place/clever/progress.dart';

/// A stand-in for the Rust session: two rings, four numbers.
class _Session extends GameSession {
  final acts = <Map<String, dynamic>>[];
  double ringAngle = 0;

  _Session() : super(game: 'donen_sayilar', level: 1) {
    loading = false;
    state = _base('intro', {});
  }

  Map<String, dynamic> _base(String phase, Set<int> found) => {
        'status': 'playing',
        'stars': 0,
        'mode': 'level',
        'level': 1,
        'phase': phase,
        'title': '4 sayı · 2 halka',
        'goal': 'Hedef',
        'board_r': 1000,
        'token_r': 135,
        'hit_r': 236,
        'rings': [
          {'r': 440, 'a': ringAngle},
          {'r': 853, 'a': -ringAngle},
        ],
        'numbers': phase == 'intro'
            ? null
            : [
                {'n': 1, 'ring': 0, 'a': 0.0, 'found': found.contains(1), 'cue': !found.contains(1)},
                {'n': 2, 'ring': 1, 'a': 0.0, 'found': found.contains(2), 'cue': false},
                {'n': 3, 'ring': 0, 'a': math.pi, 'found': false, 'cue': false},
                {'n': 4, 'ring': 1, 'a': math.pi, 'found': false, 'cue': false},
              ],
        'total': 4,
        'found': found.length,
        'errors': 0,
        'score': found.length,
        'stage': 1,
        'targets': [2, 3, 4],
        'next_goal': {'n': 9, 'stars': 1},
        'max_errors': [2, 5],
        'elapsed_ms': 0,
        'remaining_ms': 60000,
        'limit_ms': 60000,
        'countdown_ms': 0,
        'penalty_ms': 2000,
        'first_cue': true,
        'reversing': false,
        'board_serial': 0,
        'last': null,
      };

  void setRun(Set<int> found) {
    state = _base('run', found);
    notifyListeners();
  }

  @override
  bool act(Map<String, dynamic> action) {
    acts.add(action);
    if (action['start'] == true) setRun({});
    return true;
  }
}

Widget _host(GameSession s) => MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(listenable: s, builder: (context, _) => DonenSayilarBoard(session: s)),
      ),
    );

void _phone(WidgetTester t) {
  t.view.physicalSize = const Size(1080, 2340);
  t.view.devicePixelRatio = 2.5;
  addTearDown(t.view.reset);
}

/// Screen point of a board position, from the dial's actual place and size.
Offset _screen(WidgetTester t, double x, double y) {
  final box = t.renderObject<RenderBox>(find.byKey(const ValueKey('donen-dial')));
  final k = box.size.width / 2 / 1000;
  return box.localToGlobal(box.size.center(Offset.zero)) + Offset(x * k, y * k);
}

void main() {
  testWidgets('tanıtımdan oyuna geçer, sayılar başlamadan gizlidir', (t) async {
    _phone(t);
    final s = _Session();
    await t.pumpWidget(_host(s));
    expect(find.text('Başla'), findsOneWidget);
    expect(find.text('1'), findsNothing);
    await t.tap(find.text('Başla'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(s.acts.single, {'start': true});
    for (final n in ['1', '2', '3', '4']) {
      expect(find.text(n), findsOneWidget);
    }
    expect(find.textContaining('Sıradaki'), findsNothing, reason: 'the next number is never announced');
  });

  testWidgets('dokunuş, dönen halkadaki gerçek yere göre gönderilir', (t) async {
    _phone(t);
    final s = _Session();
    await t.pumpWidget(_host(s));
    s.setRun({});
    await t.pump();
    // A quarter turn on the first ring: the 1 is now straight below the centre.
    s.ringAngle = math.pi / 2;
    s.setRun({});
    await t.pump();
    await t.tapAt(_screen(t, 0, 440));
    final tap = s.acts.single['tap'] as List;
    expect(tap[0] as double, closeTo(0, 2));
    expect(tap[1] as double, closeTo(440, 2));
    final numberBox = t.getCenter(find.text('1'));
    final expected = _screen(t, 0, 440);
    expect((numberBox - expected).distance, lessThan(1.5), reason: 'the number is drawn where the core says');
  });

  testWidgets('dokunulan sayı solup kaybolur, diğerleri kalır', (t) async {
    _phone(t);
    final s = _Session();
    await t.pumpWidget(_host(s));
    s.setRun({});
    await t.pump();
    s.setRun({1});
    await t.pump();
    expect(find.text('1'), findsOneWidget, reason: 'fading out, still there on the first frame');
    await t.pump(const Duration(milliseconds: 400));
    s.setRun({1});
    await t.pump();
    expect(find.text('1'), findsNothing);
    expect(find.text('2'), findsOneWidget);
  });

  test('katalogda, Dikkat kategorisinde, 200 bölüm ve madalyon çizimiyle kayıtlı', () async {
    SharedPreferences.setMockInitialValues({});
    final p = await Progress.loadFresh();
    p.visibleLevels = 500;
    expect(p.levelsFor('donen_sayilar'), 200);
    final g = kCoreGames.firstWhere((g) => g.id == 'donen_sayilar');
    expect(g.name, 'Dönen Sayılar');
    expect(g.category, GameCategory.attention);
    expect(g.hasEndless, isTrue);
    expect(GameArtDisc.has('donen_sayilar'), isTrue);
    expect(g.tutorials.mid, hasLength(4));
    expect(g.tutorials.advanced, hasLength(4));
  });
}
