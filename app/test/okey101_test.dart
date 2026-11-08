// Okey: the 101 tables come first on the game page (grouped under "101 Okey" / "Klasik Okey"), and
// the 101 table view shows the live opening total and lays the melds arranged on the rack. The
// session is a small scripted stand-in for the Rust core. Run with `flutter test`.

import 'package:clever_place/clever/catalog.dart';
import 'package:clever_place/clever/core_bridge.dart';
import 'package:clever_place/clever/game_home_screen.dart';
import 'package:clever_place/clever/games/okey_view.dart';
import 'package:clever_place/clever/progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ScriptSession extends GameSession {
  final acts = <Map<String, dynamic>>[];
  final bool Function(Map<String, dynamic> action, ScriptSession s) onAct;
  ScriptSession(Map<String, dynamic> initial, this.onAct) : super(game: 'okey', level: 1, mode: '101_normal') {
    state = initial;
    loading = false;
  }

  @override
  bool act(Map<String, dynamic> action) {
    acts.add(action);
    final ok = onAct(action, this);
    if (ok) {
      state = {...state, 'version': (state['version'] as int) + 1};
      notifyListeners();
    }
    return ok;
  }

  @override
  Future<bool> actAsync(Map<String, dynamic> action) async => act(action);

  @override
  void tick(double dtMs) {}
}

Map<String, dynamic> _seat(int i, {bool opened = false, int value = 0}) => {
      'name': ['Sen', 'Selim', 'Ayla', 'Murat'][i],
      'where': ['you', 'right', 'top', 'left'][i],
      'score': [0, 202, -101, 30][i],
      'hand': i == 1 ? 101 : 0,
      'count': i == 0 ? 8 : 21,
      'tiles': const <int>[],
      'discards': const <int>[],
      'taken': const <int>[],
      'reason': '',
      'wins': 0,
      'opened': opened,
      'open_kind': opened ? 'melds' : null,
      'open_value': value,
    };

Map<String, dynamic> _state() {
  final layout = List<int>.filled(28, -1);
  // Red 10-11-12-13 (46) · 13s black, blue, yellow (39) · loose tiles.
  for (final (i, id) in [(0, 9), (1, 10), (2, 11), (3, 12), (5, 25), (6, 38), (7, 51), (14, 6)]) {
    layout[i] = id;
  }
  return {
    'status': 'playing',
    'stars': 0,
    'variant': '101',
    'title': 'El 1/5',
    'goal': '101 puanla elini aç, işle, ilk sen bitir',
    'mode': '101_normal',
    'hand_no': 1,
    'max_hands': 5,
    'hand_choices': [3, 5, 7],
    'phase': 'play',
    'turn': 'you',
    'seat': 0,
    'stage': 'discard',
    'ai_pending': false,
    'starter': 0,
    'seats': [_seat(0), _seat(1), _seat(2, opened: true, value: 108), _seat(3)],
    'layout': layout,
    'melds': [
      {'slots': [0, 1, 2, 3], 'kind': 'run', 'value': 46},
      {'slots': [5, 6, 7], 'kind': 'set', 'value': 39},
    ],
    'table': [
      {'owner': 2, 'kind': 'run', 'tiles': [3, 4, 5], 'value': 15},
    ],
    'need': 101,
    'need_pairs': 5,
    'indicator': 20,
    'okey': {'kind': 21, 'color': 1, 'number': 9},
    'pile_count': 14,
    'pile': const <int>[],
    'can_take': false,
    'take_tile': null,
    'must_use': null,
    'can_untake': false,
    'penalty_tiles': [6],
    'addable': const [],
    'history': const [],
    'last': null,
    'log': const [],
    'hint': null,
    'result': null,
    'match_over': false,
    'version': 1,
  };
}

Future<void> _pumpTable(WidgetTester tester, GameSession s) async {
  tester.view.physicalSize = const Size(1236, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (c) => okeyView(c, s)))));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the 101 tables come first, then the classic ones', () {
    final okey = kCoreGames.firstWhere((g) => g.id == 'okey');
    expect([for (final m in okey.matchModes) m.id],
        ['101_easy', '101_normal', '101_hard', '101_impossible', 'easy', 'normal', 'hard', 'impossible']);
    expect(okey.matchModes.first.label, '101 · Kolay');
    expect(okey.matchModes[4].label, 'Klasik · Kolay');
  });

  testWidgets('game page groups the tables under 101 Okey and Klasik Okey', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await Progress.loadFresh();
    tester.view.physicalSize = const Size(1440, 6000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final okey = kCoreGames.firstWhere((g) => g.id == 'okey');
    await tester.pumpWidget(MaterialApp(home: GameHomeScreen(game: okey)));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('KLASİK OKEY'), 300, scrollable: find.byType(Scrollable).first);
    final h101 = find.text('101 OKEY');
    final hClassic = find.text('KLASİK OKEY');
    expect(h101, findsOneWidget);
    expect(hClassic, findsOneWidget);
    expect(tester.getTopLeft(h101).dy, lessThan(tester.getTopLeft(hClassic).dy));
    // Cards show the table part only, twice (once per variant).
    expect(find.text('Kolay'), findsNWidgets(2));
    expect(find.text('İmkânsız'), findsWidgets);
    expect(find.text('101 · Kolay'), findsNothing);
  });

  testWidgets('the Aç pill shows the live total and lays the arranged melds', (tester) async {
    final s = ScriptSession(_state(), (a, s) => a.containsKey('hands'));
    await _pumpTable(tester, s);
    expect(find.text('AÇ'), findsOneWidget);
    expect(find.text('85 / 101'), findsOneWidget);
    expect(find.text('Açılabilir mi?'), findsOneWidget);
    await tester.tap(find.text('AÇ'));
    await tester.pump();
    expect(s.acts.last, {
      'lay': [
        [9, 10, 11, 12],
        [25, 38, 51],
      ]
    });
    // The hand count chip cycles 5 → 7 in the first hand.
    await tester.tap(find.text('5 el'));
    await tester.pump();
    expect(s.acts.last, {'hands': 7});
    // "Açılabilir mi?" asks the core to arrange and explain.
    await tester.tap(find.text('Açılabilir mi?'));
    await tester.pump();
    expect(s.acts.last, {'suggest': true});
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('opened: the pill lays further melds; a taken tile can be given back', (tester) async {
    final st = _state();
    st['seats'] = [_seat(0, opened: true, value: 112), _seat(1), _seat(2, opened: true, value: 108), _seat(3)];
    st['can_untake'] = true;
    st['must_use'] = 6;
    final s = ScriptSession(st, (a, s) => true);
    await _pumpTable(tester, s);
    expect(find.text('İNDİR'), findsOneWidget);
    expect(find.text('2 per'), findsOneWidget);
    await tester.tap(find.text('Geri ver'));
    await tester.pump();
    expect(s.acts.last, {'untake': true});
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('result card lists every hand and the totals', (tester) async {
    final st = _state();
    st['phase'] = 'hand_end';
    st['history'] = [
      [-101, 202, 34, 12],
      [40, -202, 404, 202],
    ];
    st['result'] = {
      'winner': 1,
      'text': 'Selim okeyle bitirdi! — el 2 katı',
      'points': [40, -202, 404, 202],
      'penalties': [0, 0, 101, 0],
      'finish_tile': null,
      'scores': [-61, 0, 438, 214],
    };
    st['seats'] = [
      {..._seat(0), 'score': -61},
      {..._seat(1), 'score': 0},
      {..._seat(2), 'score': 438},
      {..._seat(3), 'score': 214},
    ];
    final s = ScriptSession(st, (a, s) => true);
    await _pumpTable(tester, s);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.text('Selim okeyle bitirdi! — el 2 katı'), findsOneWidget);
    expect(find.text('1. el'), findsOneWidget);
    expect(find.text('2. el'), findsOneWidget);
    expect(find.text('-61'), findsNWidgets(2)); // the table and "Toplamın"
    expect(find.textContaining('Ayla +101'), findsOneWidget);
    await tester.tap(find.text('Sonraki el'));
    await tester.pump();
    expect(s.acts.last, {'next': true});
    await tester.pump(const Duration(seconds: 2));
  });
}
