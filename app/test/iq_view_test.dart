// IQ Soruları view: renders question, figure-option, typed and feedback states without errors.
//
// Contact sheets for eyeballing real items: dump states from the core with
//   IQ_DUMP=/tmp/s.json cargo test --release iq_dump_states -- --ignored
// then `IQ_STATES=/tmp/s.json flutter test test/iq_view_test.dart` writes build/iq_view/NN.png.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:clever_place/clever/core_bridge.dart';
import 'package:clever_place/clever/games/iq_view.dart';
import 'package:clever_place/clever/lux.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _loadFonts() async {
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
  // Material icons for the contact sheets (the test environment draws boxes without them).
  final root = Platform.environment['FLUTTER_ROOT'];
  final icons = File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (root != null && icons.existsSync()) {
    final loader = FontLoader('MaterialIcons')..addFont(icons.readAsBytes().then((b) => ByteData.view(b.buffer)));
    await loader.load();
  }
}

Map<String, dynamic> _state(Map<String, dynamic> question, {Map<String, dynamic>? last, String mode = 'level'}) => {
      'status': 'playing',
      'stars': 0,
      'mode': mode,
      'phase': last == null ? 'question' : 'feedback',
      'q_index': 2,
      'q_count': 20,
      'answers': [true, false],
      'correct': 1,
      'streak': 2,
      'best_streak': 4,
      'lives': 2,
      'question': question,
      'last': last,
    };

final _samples = <Map<String, dynamic>>[
  _state({
    'cat': 'number_series',
    'cat_name': 'Sayı dizisi',
    'hard': false,
    'prompt': 'Dizide soru işaretinin yerine hangi sayı gelmeli?',
    'figure': {
      'layout': 'series',
      'terms': ['3', '5', '9', '17', '33', '?']
    },
    'options': [
      {'text': '49'},
      {'text': '65'},
      {'text': '66'},
      {'text': '67'}
    ],
    'typed': false,
  }),
  _state({
    'cat': 'balance',
    'cat_name': 'Terazi',
    'hard': true,
    'prompt': 'Teraziler dengede. Son teraziyi hangi grup dengeler?',
    'figure': {
      'layout': 'scales',
      'scales': [
        {
          'left': ['t', 't'],
          'right': ['s']
        },
        {
          'left': ['s', 't'],
          'right': ['c']
        }
      ],
      'ask': {
        'left': ['c', 'c'],
        'right': ['?']
      }
    },
    'options': [
      for (final g in [
        ['t', 't', 't', 't', 't', 't'],
        ['s', 's'],
        ['s', 'c'],
        ['t', 't', 't', 't', 't']
      ])
        {
          'figure': {'layout': 'symbols', 'items': g}
        }
    ],
    'typed': false,
  }),
  _state({
    'cat': 'missing_number',
    'cat_name': 'Eksik sayı',
    'hard': true,
    'prompt': 'Yıldızın uçlarındaki sayılar dilimlerden aynı kuralla çıkıyor. Soru işareti hangi sayı?',
    'figure': {
      'layout': 'star',
      'tips': ['13', '?', '12', '15', '7', '7'],
      'wedges': ['9', '1', '11', '4', '3', '4']
    },
    'options': <Object>[],
    'typed': true,
  }),
  _state({
    'cat': 'logic',
    'cat_name': 'Mantık',
    'hard': false,
    'prompt': 'Buna göre hangisi kesinlikle doğrudur?',
    'figure': {
      'layout': 'clues',
      'lines': ['Bütün zorplar bliktir.', 'Hiçbir blik flem değildir.'],
      'note': 'Kelimeler uydurma; yalnızca verilenlere dayan.'
    },
    'options': [
      {'text': 'Bazı zorplar flemdir.'},
      {'text': 'Hiçbir zorp flem değildir.'},
      {'text': 'Bütün flemler zorptur.'},
      {'text': 'Bazı blikler zorp değildir.'}
    ],
    'typed': false,
  }, last: {
    'given': 3,
    'answer': 1,
    'correct': false,
    'why': 'Öncülleri bir Venn şemasına yerleştir: “Hiçbir zorp flem değildir” her durumda doğru.',
  }),
  _state({
    'cat': 'word_problem',
    'cat_name': 'Sözel problem',
    'hard': false,
    'prompt': 'A musluğu bir depoyu 6 saatte, B musluğu 3 saatte dolduruyor. İkisi birlikte açılırsa depo kaç dakikada dolar?',
    'figure': null,
    'options': <Object>[],
    'typed': true,
  }, last: {
    'given': null,
    'typed_value': 120,
    'answer': null,
    'answer_value': 120,
    'correct': true,
    'why': 'Bir saatte birlikte 1/2 depo; depo 120 dakikada dolar.',
  }, mode: 'endless'),
];

Future<void> _show(WidgetTester tester, Map<String, dynamic> state, {GlobalKey? key}) async {
  final s = GameSession(game: 'iq', level: 1)
    ..state = state
    ..loading = false;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      backgroundColor: Lux.bg0,
      body: RepaintBoundary(
        key: key,
        child: LuxBackground(child: Builder(builder: (context) => iqView(context, s))),
      ),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('IQ view renders every kind of state', (tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 915));
    for (final st in _samples) {
      await _show(tester, st);
      expect(tester.takeException(), isNull);
      expect(find.text('${(st['question'] as Map)['cat_name']}'), findsOneWidget);
      if (st['phase'] == 'feedback') {
        expect(find.text('Neden?'), findsOneWidget);
        expect(find.text('Devam'), findsOneWidget);
      }
      if ((st['question'] as Map)['typed'] == true && st['phase'] == 'question') {
        expect(find.text('Cevabını yaz'), findsOneWidget);
      }
    }
    expect(find.text('Bitir'), findsOneWidget); // the last sample is Karışık mode
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('IQ view contact sheets (IQ_STATES)', (tester) async {
    final path = Platform.environment['IQ_STATES'];
    if (path == null) return;
    final states = [for (final s in jsonDecode(File(path).readAsStringSync()) as List) Map<String, dynamic>.from(s as Map)];
    await tester.binding.setSurfaceSize(const Size(412, 915));
    Directory('build/iq_view').createSync(recursive: true);
    for (var i = 0; i < states.length; i++) {
      final key = GlobalKey();
      await _show(tester, states[i], key: key);
      expect(tester.takeException(), isNull, reason: 'state $i');
      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('build/iq_view/${i.toString().padLeft(2, '0')}.png').writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }
    await tester.pumpWidget(const SizedBox());
  });
}
