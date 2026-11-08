// Sözel ve Sosyal Zeka board: answer an item and see the "Neden?" panel (plus the research-consensus
// note on emotion-management items), then move on. The session is a small scripted stand-in for the
// Rust core. Run with `flutter test`.

import 'package:clever_place/clever/catalog.dart';
import 'package:clever_place/clever/core_bridge.dart';
import 'package:clever_place/clever/games/verbal_social_view.dart';
import 'package:clever_place/clever/progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ScriptSession extends GameSession {
  final List<Map<String, dynamic>> items;
  final acts = <Map<String, dynamic>>[];
  int idx = 0;
  final answers = <bool>[];

  _ScriptSession(this.items) : super(game: 'verbal_social', level: 1) {
    loading = false;
    state = _state('question', null);
  }

  Map<String, dynamic> _state(String phase, Map<String, dynamic>? last) {
    final it = items[idx];
    return {
      'status': 'playing',
      'stars': 0,
      'title': 'Orta',
      'goal': '${items.length} soru · en az 7 doğru',
      'mode': 'level',
      'level': 1,
      'phase': phase,
      'q_index': idx,
      'q_count': items.length,
      'answers': answers,
      'correct': answers.where((a) => a).length,
      'question': {
        'id': it['id'],
        'section': it['section'],
        'section_label': it['section_label'],
        'subtype': it['subtype'],
        'subtype_label': it['subtype_label'],
        'difficulty': 'orta',
        'prompt': it['prompt'],
        'options': it['options'],
        'consensus': it['subtype'] == 'duygu_yonetimi',
      },
      'last': last,
    };
  }

  @override
  bool act(Map<String, dynamic> action) {
    acts.add(action);
    final it = items[idx];
    if (action['answer'] is int && state['phase'] == 'question') {
      final correct = action['answer'] == it['answer'];
      answers.add(correct);
      state = _state('feedback', {'given': action['answer'], 'answer': it['answer'], 'correct': correct, 'why': it['why']});
    } else if (action['next'] == true && state['phase'] == 'feedback') {
      idx++;
      state = _state('question', null);
    } else {
      return false;
    }
    notifyListeners();
    return true;
  }

  @override
  void tick(double dtMs) {}
}

const _items = [
  {
    'id': 'soz-x',
    'section': 'sozel',
    'section_label': 'Sözel',
    'subtype': 'analoji',
    'subtype_label': 'Analoji',
    'prompt': '“TERMOMETRE : SICAKLIK” ikilisindeki ilişkiye en çok benzeyen ikili hangisi?',
    'options': ['Barometre : basınç', 'Pusula : harita', 'Saat : zaman dilimi', 'Cetvel : kalem'],
    'answer': 0,
    'why': 'Termometre sıcaklığı ölçer; barometre de basıncı ölçer.',
  },
  {
    'id': 'duy-x',
    'section': 'duygusal',
    'section_label': 'Duygusal',
    'subtype': 'duygu_yonetimi',
    'subtype_label': 'Duyguyu yönetme',
    'prompt': 'Batu raporda bir hata buldu. En etkili davranış hangisi?',
    'options': ['Yöneticisine söyleyip düzeltme önermek', 'Hiç açmamak', 'Fazla mesai yapmak', 'Unutmak'],
    'answer': 0,
    'why': 'Sorun düzeltilebilir; bildirip çözüm önermek hem sorunu hem kaygıyı giderir.',
  },
];

Widget _host(GameSession s) => MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: SizedBox(
          width: 392,
          height: 820,
          child: ListenableBuilder(listenable: s, builder: (context, _) => verbalSocialView(context, s)),
        ),
      ),
    );

void main() {
  testWidgets('answering shows the result and the Neden? panel, Devam moves on', (tester) async {
    await tester.binding.setSurfaceSize(const Size(392, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final s = _ScriptSession([for (final i in _items) Map<String, dynamic>.from(i)]);
    await tester.pumpWidget(_host(s));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Sözel'), findsOneWidget);
    expect(find.text('Analoji'), findsOneWidget);
    expect(find.text('Neden?'), findsNothing);

    // A wrong answer: red feedback, the explanation, no consensus note on a verbal item.
    await tester.tap(find.text('Pusula : harita'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(s.acts.last, {'answer': 1});
    expect(find.text('Neden?'), findsOneWidget);
    expect(find.text('Olmadı'), findsOneWidget);
    expect(find.text('Termometre sıcaklığı ölçer; barometre de basıncı ölçer.'), findsOneWidget);
    expect(find.text(kConsensusNote), findsNothing);

    // Options are locked during feedback.
    await tester.tap(find.text('Barometre : basınç'));
    await tester.pump();
    expect(s.acts.length, 1);

    await tester.ensureVisible(find.text('Devam'));
    await tester.pump();
    await tester.tap(find.text('Devam'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 400)); // the old item finishes fading out
    expect(find.text('Duygusal'), findsOneWidget);
    expect(find.text('Neden?'), findsNothing);

    // An emotion-management item: right answer, with the research-consensus note.
    await tester.tap(find.text('Yöneticisine söyleyip düzeltme önermek'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Doğru'), findsOneWidget);
    expect(find.text('Neden?'), findsOneWidget);
    expect(find.text(kConsensusNote), findsOneWidget);
    expect(find.text('Sonucu gör'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('catalog entry: logic, after IQ or at the end of logic, with endless Karışık', () {
    final i = kCoreGames.indexWhere((g) => g.id == 'verbal_social');
    expect(i, isNonNegative);
    final g = kCoreGames[i];
    expect(g.name, 'Sözel ve Sosyal Zeka');
    expect(g.tagline, 'Kelimeler, insanlar ve duygular: 450 soru');
    expect(g.category, GameCategory.logic);
    expect(g.hasEndless, isTrue);
    expect(g.endlessLabel, 'Karışık');
    final iq = kCoreGames.indexWhere((g) => g.id == 'iq');
    if (iq >= 0) {
      expect(i, iq + 1);
    } else {
      expect(kCoreGames[i - 1].category, GameCategory.logic);
      expect(kCoreGames.skip(i + 1).any((g) => g.category == GameCategory.logic), isFalse);
    }
    expect(g.tutorials.mid, isNotEmpty);
    expect(g.tutorials.advanced, isNotEmpty);
  });

  test('progress caps the course at 45 levels', () async {
    SharedPreferences.setMockInitialValues({});
    final p = await Progress.loadFresh();
    p.visibleLevels = 500;
    expect(p.levelsFor('verbal_social'), 45);
    expect(p.tierRange('verbal_social', 1).last, 22);
  });
}
