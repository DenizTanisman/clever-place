import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:clever_place/clever/art/game_art.dart';
import 'package:clever_place/clever/catalog.dart';
import 'package:clever_place/clever/core_bridge.dart';
import 'package:clever_place/clever/games/zihin_asisi_view.dart';
import 'package:clever_place/clever/progress.dart';

class _Session extends GameSession {
  final acts = <Map<String, dynamic>>[];

  _Session() : super(game: 'zihin_asisi', level: 1) {
    loading = false;
    state = _base('intro');
  }

  Map<String, dynamic> _base(String phase) => {
        'status': 'playing',
        'stars': 0,
        'title': 'Duygu Sömürüsü',
        'mode': 'level',
        'level': 1,
        'phase': phase,
        'q_index': 0,
        'q_count': 10,
        'answers': <bool>[],
        'intro': {'name': 'Duygu Sömürüsü', 'what': 'Tanım', 'why': 'Gerekçe', 'defense': 'Savunma'},
        'question': {
          'id': 'x',
          'sender': 'Çınar Sitesi · Nihal',
          'message': 'ACİL mesaj',
          'ask': 'Bu mesajın asıl numarası ne?',
          'options': ['A şıkkı', 'B şıkkı', 'C şıkkı', 'D şıkkı'],
          'difficulty': 'orta',
        },
        'last': null,
      };

  @override
  bool act(Map<String, dynamic> action) {
    acts.add(action);
    if (action['start'] == true) {
      state = _base('question');
    } else if (action['answer'] != null) {
      state = _base('feedback')
        ..['answers'] = [true]
        ..['last'] = {'given': 1, 'answer': 1, 'correct': true, 'why': 'Açıklama', 'technique_label': 'Duygu Sömürüsü'};
    }
    notifyListeners();
    return true;
  }
}

Widget _host(GameSession s) => MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(listenable: s, builder: (context, _) => ZihinAsisiBoard(session: s)),
      ),
    );

void main() {
  testWidgets('uyarı kartından mesaja, cevaptan açıklamaya geçer', (t) async {
    t.view.physicalSize = const Size(1080, 2340);
    t.view.devicePixelRatio = 2.5;
    addTearDown(t.view.reset);
    final s = _Session();
    await t.pumpWidget(_host(s));
    expect(find.text('Duygu Sömürüsü'), findsOneWidget);
    await t.tap(find.text('Zayıf dozu al'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400)); // the double-tap guard re-arms after 300 ms
    expect(find.text('ACİL mesaj'), findsOneWidget);
    await t.tap(find.text('B şıkkı'));
    await t.pump(const Duration(milliseconds: 600));
    expect(find.text('Açıklama'), findsOneWidget);
    expect(s.acts.map((a) => a.keys.first), ['start', 'answer']);
  });

  test('katalogda, 13 bölüm ve madalyon çizimiyle kayıtlı', () async {
    SharedPreferences.setMockInitialValues({});
    final p = await Progress.loadFresh();
    p.visibleLevels = 500;
    expect(p.levelsFor('zihin_asisi'), 13);
    final g = kCoreGames.firstWhere((g) => g.id == 'zihin_asisi');
    expect(g.category, GameCategory.mind);
    expect(g.hasEndless, isTrue);
    expect(GameArtDisc.has('zihin_asisi'), isTrue);
  });
}
