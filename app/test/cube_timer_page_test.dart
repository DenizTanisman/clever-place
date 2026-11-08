import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clever_place/clever/cube/cube_log.dart';
import 'package:clever_place/clever/cube/cube_scrambles.dart';
import 'package:clever_place/clever/cube/cube_timer_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferences prefs;
  var now = 0;

  Future<void> open(WidgetTester tester, {required bool scrambled}) async {
    SharedPreferences.setMockInitialValues({
      CubeLog.storageKey: CubeLog(scrambled: scrambled).encode(),
    });
    prefs = await SharedPreferences.getInstance();
    now = 0;
    await tester.binding.setSurfaceSize(const Size(420, 900));
    await tester.pumpWidget(
      MaterialApp(home: CubeTimerPage(clock: () => now)),
    );
    // Loads the log and (missing in tests) the stored scrambles.
    await tester.pumpAndSettle();
  }

  setUp(() => ScrambleBank.debugBanks = {});
  tearDown(() => ScrambleBank.debugBanks = null);

  CubeLog saved() => CubeLog.decode(prefs.getString(CubeLog.storageKey));

  /// Press on the big number, wait past the 300 ms hold, let go.
  Future<void> holdAndRelease(WidgetTester tester) async {
    final g = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('cube-pad'))),
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Bırak!'), findsOneWidget);
    await g.up();
    await tester.pump();
  }

  Future<void> tapTimer(WidgetTester tester) async {
    final g = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('cube-pad'))),
    );
    await tester.pump();
    await g.up();
    await tester.pump();
  }

  testWidgets('just the time: hold, let go, touch', (tester) async {
    await open(tester, scrambled: false);
    expect(find.text('Basılı tut, yeşil olunca bırak'), findsOneWidget);

    // Letting go before green does not start.
    final early = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('cube-pad'))),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await early.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Bırak!'), findsNothing);

    await holdAndRelease(tester);
    now = 12345;
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('12.34'), findsOneWidget);
    await tapTimer(tester);

    final solves = saved().solves;
    expect(solves, hasLength(1));
    expect(solves.single.ms, 12345);
    expect(solves.single.scramble, isNull);
    expect(solves.single.penalty, Penalty.none);
    expect(find.text('12.34'), findsWidgets);
  });

  testWidgets('scramble: tap starts inspection, late start gets +2', (
    tester,
  ) async {
    await open(tester, scrambled: true);
    expect(find.textContaining('beyaz üst, yeşil ön'), findsOneWidget);

    await tapTimer(tester);
    expect(find.text('15'), findsOneWidget);
    now = 16000;
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('+2'), findsWidgets);

    await holdAndRelease(tester);
    final startedAt = now;
    now = startedAt + 20000;
    await tapTimer(tester);

    final s = saved().solves.single;
    expect(s.ms, 20000);
    expect(s.penalty, Penalty.plus2);
    expect(s.scramble, isNotEmpty);
    expect(find.text('22.00+'), findsWidgets);
    expect(find.text('Bu karıştırma için taktikler'), findsOneWidget);
  });

  testWidgets('inspection past 17 s is a DNF', (tester) async {
    await open(tester, scrambled: true);
    await tapTimer(tester);
    now = 18000;
    await tester.pump(const Duration(milliseconds: 20));
    await holdAndRelease(tester);
    now += 9000;
    await tapTimer(tester);
    expect(saved().solves.single.penalty, Penalty.dnf);
  });

  testWidgets('DNF chip and delete edit the last solve', (tester) async {
    await open(tester, scrambled: false);
    await holdAndRelease(tester);
    now = 9000;
    await tapTimer(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, 'DNF'));
    await tester.pump();
    expect(saved().solves.single.penalty, Penalty.dnf);
    await tester.tap(find.widgetWithText(ActionChip, 'Sil'));
    await tester.pump();
    expect(saved().solves, isEmpty);
  });

  testWidgets('a stored 3x3 scramble shows its worked-out tips', (
    tester,
  ) async {
    const json = r"""
{"puzzle":"333","version":1,"scrambles":[{"s":"R U R' F2 D L'","a":{
 "cross":{"W":{"n":6,"rot":"z2","m":"F R D' L2"},"B":{"n":4,"rot":"x","m":"R U2 F"}},
 "xcross":{"W":{"n":8,"slot":"FR","rot":"z2","m":"F R D' L2 U R U' R'"}},
 "ref":{"rot":"z2","steps":[{"k":"cross","m":"F R D' L2"},{"k":"pair","slot":"FL","m":"U L' U L"}],
        "n":40,"oll":"Sune","edges":"L","pll":"T"},
 "skips":[{"k":"pll","m":"U R U' R'","note":"son çift böyle"}],
 "tips":["Mavi artı 4 hamle, beyazdan 2 kısa."]}}]}
""";
    ScrambleBank.debugBanks = {'333': ScrambleBank.parse(json)};
    await open(tester, scrambled: true);
    expect(find.text("R U R' F2 D L'"), findsOneWidget);
    expect(find.textContaining('#1 / 1'), findsOneWidget);

    await tapTimer(tester);
    await holdAndRelease(tester);
    now += 15000;
    await tapTimer(tester);
    expect(saved().solves.single.index, 0);
    // The list has one scramble, so the next one is the same again.
    expect(saved().next['333'], 0);

    await tester.tap(find.text('Bu karıştırma için taktikler'));
    await tester.pumpAndSettle();
    expect(find.text('Mavi artı 4 hamle, beyazdan 2 kısa.'), findsOneWidget);
    expect(find.text('Mavi 4'), findsOneWidget);
    expect(find.text('Beyaz 6'), findsOneWidget);
    expect(find.text("(z2) F R D' L2"), findsWidgets);
    await tester.dragUntilVisible(
      find.textContaining('PLL: T'),
      find.byType(ListView).last,
      const Offset(0, -200),
    );
    expect(find.textContaining('OLL: Sune'), findsOneWidget);
  });
}
