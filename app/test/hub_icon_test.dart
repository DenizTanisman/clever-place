// Regression: a hub card's medallion (Monogram) must survive entering and leaving a game.
//
// Flutter's HeroController hides the hub hero when the game page is pushed and only shows it again
// when it sees the matching pop. It ignores route changes while a predictive-back swipe is still
// animating out, so two quick backs (play » game page » hub) used to leave the card blank for good.

import 'package:clever_place/clever/game_home_screen.dart';
import 'package:clever_place/clever/hub_screen.dart';
import 'package:clever_place/clever/lux.dart';
import 'package:clever_place/clever/progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _backEvent(WidgetTester tester, String method, [Map<String, dynamic>? args]) async {
  final msg = const StandardMethodCodec().encodeMethodCall(MethodCall(method, args));
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage('flutter/backgesture', msg, (_) {});
}

/// An Android predictive-back swipe released part-way (the page then animates out on its own).
Future<void> _swipeBack(WidgetTester tester, {bool button = false}) async {
  await _backEvent(tester, 'startBackGesture', {
    'touchOffset': button ? null : [5.0, 300.0],
    'progress': 0.0,
    'swipeEdge': 0,
  });
  await tester.pump(const Duration(milliseconds: 16));
  for (final p in [0.1, 0.2, 0.3, 0.4]) {
    await _backEvent(tester, 'updateBackGestureProgress', {'x': 100.0, 'y': 300.0, 'progress': p, 'swipeEdge': 0});
    await tester.pump(const Duration(milliseconds: 16));
  }
  await _backEvent(tester, 'commitBackGesture');
}

Finder _heroOf(String id) => find.byWidgetPredicate((w) => w is Hero && w.tag == monogramHeroTag(id));

/// The hub card's Monogram, painted (offstage placeholders are skipped by the finder).
Finder _hubMonogram(String id) => find.descendant(of: _heroOf(id), matching: find.byType(Monogram));

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final p = await Progress.load();
    p.visibleLevels = 500;
  });

  final android = TargetPlatformVariant.only(TargetPlatform.android);

  /// Pumps the hub; returns a callback that restores the error handler (call it at the end).
  Future<VoidCallback> pumpHub(WidgetTester tester) async {
    final prev = FlutterError.onError;
    // The test font is wider than Jost; ignore overflow stripes, they are not what we test.
    FlutterError.onError = (d) {
      if (d.exceptionAsString().contains('overflowed')) return;
      prev?.call(d);
    };
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: HubScreen()));
    await tester.pump(const Duration(seconds: 2));
    return () => FlutterError.onError = prev;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  testWidgets('medallion is back after entering and leaving a game', (tester) async {
    final done = await pumpHub(tester);
    expect(_hubMonogram('corridor'), findsOneWidget);
    await tester.tapAt(tester.getCenter(_heroOf('corridor')));
    await tester.pump();
    await settle(tester);
    expect(find.byType(GameHomeScreen), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    await settle(tester);
    expect(find.byType(GameHomeScreen), findsNothing);
    expect(_hubMonogram('corridor'), findsOneWidget);
    done();
  }, variant: android);

  for (final second in ['swipe', 'button', 'system back']) {
    testWidgets('medallion survives a quick double back (swipe, then $second)', (tester) async {
      final done = await pumpHub(tester);
      await tester.tapAt(tester.getCenter(_heroOf('corridor')));
      await tester.pump();
      await settle(tester);
      // A page above the game page (stands in for the play screen, which needs the Rust core).
      tester.state<NavigatorState>(find.byType(Navigator).first)
          .push(MaterialPageRoute(builder: (_) => const Scaffold(body: Text('play'))));
      await tester.pump();
      await settle(tester);

      await _swipeBack(tester);
      await tester.pump(const Duration(milliseconds: 100)); // the play page is still animating out
      switch (second) {
        case 'swipe':
          await _swipeBack(tester);
        case 'button':
          await _swipeBack(tester, button: true);
        default:
          await tester.binding.handlePopRoute();
      }
      await settle(tester);

      expect(find.byType(GameHomeScreen), findsNothing);
      expect(_hubMonogram('corridor'), findsOneWidget);
      done();
    }, variant: android);
  }
}
