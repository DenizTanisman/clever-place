// Game medallion illustrations: every game has one, and they all paint.
//
// Contact sheet for eyeballing: `ART_SHEET=1 flutter test test/game_art_test.dart` writes
// build/game_art_sheet.png (each medallion at hub size 50 and at 120, on the hub background).

import 'dart:io';
import 'dart:ui' as ui;

import 'package:clever_place/clever/art/game_art.dart';
import 'package:clever_place/clever/catalog.dart';
import 'package:clever_place/clever/hub_screen.dart';
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

void main() {
  setUpAll(_loadFonts);

  test('every game on the hub has an illustration', () {
    final missing = [for (final g in allGames) if (!kGameArt.containsKey(g.id)) g.id];
    expect(missing, isEmpty, reason: 'no medallion art for: $missing');
  });

  testWidgets('every illustration paints at hub and page size', (tester) async {
    final key = GlobalKey();
    final games = allGames;
    await tester.binding.setSurfaceSize(const Size(1200, 1800));
    await tester.pumpWidget(MaterialApp(
      home: RepaintBoundary(
        key: key,
        child: Container(
          color: Lux.bg0,
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 14,
            runSpacing: 10,
            children: [
              for (final GameInfo g in games)
                SizedBox(
                  width: 180,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Monogram(g.glyph, size: 50, tint: g.tint, art: g.id),
                          const SizedBox(width: 8),
                          Monogram(g.glyph, size: 120, tint: g.tint, art: g.id),
                        ],
                      ),
                      Text(g.name, style: const TextStyle(fontFamily: 'Jost', fontSize: 13, color: Colors.white70)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    if (Platform.environment['ART_SHEET'] == '1') {
      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('build/game_art_sheet.png')
          ..createSync(recursive: true)
          ..writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }
  });
}
