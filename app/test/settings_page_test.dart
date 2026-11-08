// Settings page: Clever Place "Zümrüt Kadife" look, and its choices still drive the controllers.
// Run with `flutter test`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clever_place/clever/lux.dart';
import 'package:clever_place/main.dart';
import 'package:clever_place/src/app/app_controllers.dart';
import 'package:clever_place/src/screens/settings_page.dart' show SettingsPage;

void main() {
  late LocaleController locale;
  late ThemeController theme;

  Widget app(ThemeMode mode) {
    locale = LocaleController(const Locale('tr'));
    theme = ThemeController(mode);
    return CleverPlaceApp(
      locale: locale,
      theme: theme,
      home: const SettingsPage(),
    );
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('renders in the Lux style even with the light theme selected', (tester) async {
    await tester.pumpWidget(app(ThemeMode.light));
    await tester.pump();

    expect(find.byType(LuxBackground), findsOneWidget);
    expect(find.widgetWithText(FoilText, 'Ayarlar'), findsOneWidget);
    for (final h in ['DİL', 'TEMA']) {
      expect(find.text('✦  $h  ✦'), findsOneWidget, reason: h);
    }
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, Lux.bg0);
    final ctx = tester.element(find.byType(LuxCard).first);
    expect(Theme.of(ctx).brightness, Brightness.dark);

    // The current choices are the highlighted (gold-rimmed) cards with a check.
    LuxCard card(String label) =>
        tester.widget<LuxCard>(find.ancestor(of: find.text(label), matching: find.byType(LuxCard)));
    expect(card('Türkçe').highlight, isTrue);
    expect(card('English').highlight, isFalse);
    expect(card('Açık').highlight, isTrue);
    expect(card('Koyu').highlight, isFalse);
    expect(find.byIcon(Icons.check_rounded), findsNWidgets(2));
  });

  testWidgets('choosing a theme takes effect', (tester) async {
    await tester.pumpWidget(app(ThemeMode.light));
    await tester.pump();

    await tester.tap(find.text('Koyu'));
    await tester.pump();
    expect(theme.mode, ThemeMode.dark);
    LuxCard card(String label) =>
        tester.widget<LuxCard>(find.ancestor(of: find.text(label), matching: find.byType(LuxCard)));
    expect(card('Koyu').highlight, isTrue);
    expect(card('Açık').highlight, isFalse);
  });

  testWidgets('switching language relabels the page', (tester) async {
    await tester.pumpWidget(app(ThemeMode.dark));
    await tester.pump();
    await tester.tap(find.text('English'));
    await tester.pump();
    expect(locale.locale, const Locale('en'));
    expect(find.widgetWithText(FoilText, 'Settings'), findsOneWidget);
    expect(find.text('✦  THEME  ✦'), findsOneWidget);
  });
}
