// Renders the promo video's clips from the real screens and the real Rust core.
//
//   ./tool/promo/make.sh            (everything → build/promo/clever_place_tanitim.mp4)
//   PROMO_OUT=build/promo PROMO_ONLY=sudoku,hanoi flutter test tool/promo/promo_video_test.dart
//   PROMO_STILL=1 …                 (one PNG per scene instead of clips: quick look)
//
// Each scene pumps the widget tree in 1/30 s steps and stores every frame as raw RGBA; ffmpeg turns a
// scene into `<nn>_<id>.mp4`. Without PROMO_OUT the test is skipped, so the normal suite ignores it.

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:clever_place/clever/catalog.dart';
import 'package:clever_place/clever/core_bridge.dart';
import 'package:clever_place/clever/progress.dart';

import 'scenes.dart';
import 'stage.dart';
import 'package:clever_place/clever/i18n/lang.dart';

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      loader.addFont(File(f).readAsBytes().then((b) => ByteData.sublistView(b)));
    }
    await loader.load();
  }

  const a = 'assets/fonts';
  await family('Cormorant', [
    '$a/CormorantGaramond-Medium.ttf',
    '$a/CormorantGaramond-SemiBold.ttf',
    '$a/CormorantGaramond-Bold.ttf',
    '$a/CormorantGaramond-SemiBoldItalic.ttf',
    '$a/CormorantGaramond-BoldItalic.ttf',
  ]);
  await family('Jost', ['$a/Jost-Regular.ttf', '$a/Jost-Medium.ttf', '$a/Jost-SemiBold.ttf', '$a/Jost-Bold.ttf']);
  final sdk = File(Platform.resolvedExecutable).parent.path; // …/bin/cache/artifacts/engine/darwin-x64
  final mf = Directory('$sdk/../../material_fonts').resolveSymbolicLinksSync();
  await family('MaterialIcons', ['$mf/MaterialIcons-Regular.otf']);
  await family('Roboto', ['$mf/Roboto-Regular.ttf', '$mf/Roboto-Medium.ttf', '$mf/Roboto-Bold.ttf']);
  // The cube pages write notation in the platform's monospace face; the phone has one, the test
  // engine does not.
  final mono = Platform.environment['PROMO_MONO'];
  if (mono != null) await family('monospace', ['$mono/RobotoMono-Regular.ttf', '$mono/RobotoMono-Medium.ttf', '$mono/RobotoMono-Bold.ttf']);
  // Symbols the text faces lack (★ → ≤): the phone falls back to a system symbol font.
  final sym = Platform.environment['PROMO_SYMBOLS'];
  if (sym != null) await family('Symbols', [sym]);
}

void main() {
  final out = Platform.environment['PROMO_OUT'];
  final only = (Platform.environment['PROMO_ONLY'] ?? '').split(',').where((s) => s.isNotEmpty).toSet();
  final still = Platform.environment['PROMO_STILL'] == '1';

  testWidgets('promo video clips', (tester) async {
    debugDisableShadows = false;
    // The video's language (English unless PROMO_LANG=tr): the app and the captions follow it.
    Lang.set(Platform.environment['PROMO_LANG'] ?? 'en');
    await tester.runAsync(_loadFonts);
    // Let google_fonts fetch for real instead of failing the test.
    HttpOverrides.global = null;
    FlutterError.onError = (d) {
      // ignore: avoid_print
      print('flutter error (ignored): ${d.exceptionAsString().split('\n').first}');
    };
    Progress.clock = () => DateTime(2026, 11, 20, 10);
    SharedPreferences.setMockInitialValues(_savedProgress());
    final progress = await Progress.loadFresh();
    final info = Core.call({'op': 'info'});
    progress.visibleLevels = (info['visible_levels'] as num).toInt();

    tester.view.physicalSize = const Size(Stage.w * Stage.dpr, Stage.h * Stage.dpr);
    tester.view.devicePixelRatio = Stage.dpr;
    addTearDown(tester.view.reset);

    final dir = Directory(out!)..createSync(recursive: true);
    final stage = Stage(tester, dir, still: still);
    final scenes = buildScenes();
    for (var i = 0; i < scenes.length; i++) {
      final sc = scenes[i];
      if (only.isNotEmpty && !only.contains(sc.id)) continue;
      final sw = Stopwatch()..start();
      await stage.record(i, sc);
      // ignore: avoid_print
      print('scene ${sc.id}: ${stage.lastFrames} frames in ${sw.elapsed.inSeconds}s');
    }
    debugDisableShadows = true;
  }, skip: out == null, timeout: Timeout.none);
}

/// A played-in profile, so the hub and level pages look lived in: stars on the first stretch of
/// every game, a daily mix without the two categories the video leaves out, a few active days.
Map<String, Object> _savedProgress() {
  final rnd = math.Random(11);
  final m = <String, Object>{
    'cp.daily.cats': ['strategy', 'memory', 'attention', 'logic', 'mind'],
    'cp.days': ['2026-11-16', '2026-11-17', '2026-11-18', '2026-11-19', '2026-11-20'],
    'cp.wins.2026-11-20': 2,
  };
  for (final g in kCoreGames) {
    final done = 12 + rnd.nextInt(30);
    for (var l = 1; l <= done; l++) {
      m['cp.stars.${g.id}.$l'] = rnd.nextInt(10) < 6 ? 3 : 2;
    }
  }
  // Schulte opens the video: its page on Zor with level 300 next, and recent Zor times so the level's
  // end shows the chart and a new record.
  for (var l = 1; l < 300; l++) {
    m['cp.stars.schulte.$l'] = rnd.nextInt(10) < 7 ? 3 : 2;
  }
  m['cp.tier.schulte'] = 2;
  m['cp.times.schulte.2'] = [for (final s in schulteRecentTimes) '$s'];
  m['cp.besttime.schulte.2'] = schulteRecentTimes.reduce(math.min);
  return m;
}

// Keep the analyzer quiet about the unused import when scenes change.
// ignore: unused_element
ui.Image? _unused;
// ignore: unused_element
RenderObject? _unused2;

/// Earlier winning times on Schulte's Zor tier (ms), oldest first.
const schulteRecentTimes = [27800, 26400, 25100, 26900, 23800, 24600, 22400, 23300, 22900];
