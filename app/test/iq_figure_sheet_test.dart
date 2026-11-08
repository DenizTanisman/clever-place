// IQ figure painter: every fixture figure (core/src/games/iq/figural.rs, dumped with
// `cd core && cargo test --release -- --ignored dump`) paints without errors.
//
// Contact sheets for eyeballing: `IQ_SHEET=1 flutter test test/iq_figure_sheet_test.dart` writes
// build/iq_sheet_<category>.png — 2 medium + 2 hard items per category: prompt, question figure,
// options (the answer framed in green) and the explanation.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:clever_place/clever/games/iq_figure.dart';
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
}

List<Map<String, dynamic>> _fixtures() {
  final dir = Directory('test/fixtures/iq');
  final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return [for (final f in files) (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>()];
}

const double unitPx = 100;

Widget _option(Map<String, dynamic> o, bool correct, String label) {
  final fig = o['figure'];
  return Container(
    width: 118,
    padding: const EdgeInsets.all(6),
    decoration: BoxDecoration(
      color: Lux.card,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: correct ? Lux.good : Lux.line, width: correct ? 3 : 1),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: Lux.ui(13, color: Lux.muted)),
        if (fig != null)
          IqFigure((fig as Map).cast<String, dynamic>(), size: unitPx)
        else
          SizedBox(
            height: 40,
            child: Center(child: Text(o['text'] as String, style: Lux.ui(19, color: Lux.ink))),
          ),
      ],
    ),
  );
}

Widget _item(Map<String, dynamic> it) {
  final fig = it['figure'] as Map?;
  final options = (it['options'] as List).cast<Map>();
  double figSize = 0;
  if (fig != null) {
    final f = fig.cast<String, dynamic>();
    figSize = ((f['w'] as num?)?.toDouble() ?? 1) * unitPx;
    final h = ((f['h'] as num?)?.toDouble() ?? 1) * unitPx;
    // keep tall figures (assembly) within a phone-ish height
    if (h > 300) figSize *= 300 / h;
    if (figSize > 760) figSize = 760;
  }
  return Container(
    width: 800,
    margin: const EdgeInsets.only(bottom: 18),
    padding: const EdgeInsets.all(14),
    decoration:
        BoxDecoration(color: Lux.panel, borderRadius: BorderRadius.circular(16), border: Border.all(color: Lux.line)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('${it['hard'] == true ? 'ZOR' : 'ORTA'} · ${it['prompt']}', style: Lux.ui(15, color: Lux.goldLight)),
        const SizedBox(height: 10),
        if (fig != null) Center(child: IqFigure(fig.cast<String, dynamic>(), size: figSize)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < options.length; i++)
              _option(options[i].cast<String, dynamic>(), i == it['answer'], String.fromCharCode(65 + i)),
          ],
        ),
        const SizedBox(height: 8),
        Text(it['why'] as String, style: Lux.ui(12, color: Lux.muted)),
      ],
    ),
  );
}

void main() {
  setUpAll(_loadFonts);

  test('fixtures exist for every figural category', () {
    final cats = _fixtures().map((f) => f['cat']).toSet();
    expect(cats.length, 11);
  });

  for (final fx in _fixtures()) {
    testWidgets('figures paint: ${fx['cat']}', (tester) async {
      final key = GlobalKey();
      await tester.binding.setSurfaceSize(const Size(840, 4200));
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Material(
          type: MaterialType.transparency,
          child: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: key,
              child: Container(
                color: Lux.bg0,
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${fx['name']} (${fx['cat']})', style: Lux.display(24)),
                    const SizedBox(height: 12),
                    for (final it in (fx['items'] as List).cast<Map>()) _item(it.cast<String, dynamic>()),
                  ],
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull);
      if (Platform.environment['IQ_SHEET'] == '1') {
        await tester.runAsync(() async {
          final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          File('build/iq_sheet_${fx['cat']}.png')
            ..createSync(recursive: true)
            ..writeAsBytesSync(bytes!.buffer.asUint8List());
        });
      }
    });
  }
}
