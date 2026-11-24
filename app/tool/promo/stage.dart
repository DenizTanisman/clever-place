// The promo video's stage: a 1080×1920 frame with a caption and the app in a phone-shaped window,
// plus the recorder that pumps 1/30 s steps and stores each frame.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:clever_place/clever/catalog.dart';
import 'package:clever_place/clever/core_bridge.dart';
import 'package:clever_place/clever/lux.dart';
import 'package:clever_place/clever/play_screen.dart';
import 'package:clever_place/l10n/app_localizations.dart';
import 'package:clever_place/src/app/app_controllers.dart';
import 'package:clever_place/src/theme/app_themes.dart';
import 'package:clever_place/clever/i18n/lang.dart';

/// One clip. [run] shows something on the [Stage] and records frames.
class Scene {
  final String id;
  final String kicker;
  final String title;
  final Future<void> Function(Stage s) run;

  /// Full-frame scenes (intro, outro) draw the whole 360×640 frame themselves.
  final bool full;
  const Scene(this.id, this.kicker, this.title, this.run, {this.full = false});
}

class _Touch {
  final Offset at;
  int age = 0;
  _Touch(this.at);
}

class Stage {
  static const double w = 360, h = 640, dpr = 3;
  static const Size app = Size(392, 800);
  static const double appScale = 0.7;
  static const fps = 30;
  static const _step = Duration(microseconds: 1000000 ~/ fps);

  final WidgetTester t;
  final Directory dir;
  final bool still;
  Stage(this.t, this.dir, {this.still = false});

  final _boundary = GlobalKey();
  final _fade = ValueNotifier<double>(0);
  final _touches = ValueNotifier<List<_Touch>>(const []);
  final _caption = ValueNotifier<(String, String)>(('', ''));
  final _full = ValueNotifier<bool>(false);
  final _home = ValueNotifier<Widget>(const SizedBox());
  final _locale = LocaleController(Locale(Lang.code));
  final _theme = ThemeController(ThemeMode.dark);

  RandomAccessFile? _raw;
  int lastFrames = 0;
  String _id = '';

  /// The session of the game on screen (set by [play]).
  GameSession? session;
  Map<String, dynamic> get st => session!.state;

  Widget _root() => RepaintBoundary(
        key: _boundary,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: w,
            height: h,
            child: Stack(
              children: [
                const Positioned.fill(child: LuxBackground(child: SizedBox.expand())),
                ValueListenableBuilder(
                  valueListenable: _full,
                  builder: (c, full, _) => full ? const SizedBox() : _captionBar(),
                ),
                ValueListenableBuilder(
                  valueListenable: _full,
                  builder: (c, full, child) => full
                      ? Positioned.fill(child: _fadeBox(child!))
                      : Positioned(
                          left: (w - app.width * appScale) / 2,
                          top: 70,
                          width: app.width * appScale,
                          height: app.height * appScale,
                          child: _fadeBox(_phone(child!)),
                        ),
                  child: _appTree(),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: ValueListenableBuilder(
                      valueListenable: _touches,
                      builder: (c, list, _) => CustomPaint(painter: _TouchPainter(list)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _fadeBox(Widget child) => ValueListenableBuilder(
        valueListenable: _fade,
        builder: (c, v, ch) => Opacity(opacity: v, child: ch),
        child: child,
      );

  Widget _captionBar() => Positioned(
        left: 0,
        right: 0,
        top: 10,
        height: 56,
        child: ValueListenableBuilder(
          valueListenable: _caption,
          builder: (c, cap, _) => ValueListenableBuilder(
            valueListenable: _fade,
            builder: (c, v, _) => Opacity(
              opacity: v,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(cap.$1.toUpperCase(), style: Lux.ui(11, color: Lux.gold, weight: FontWeight.w600, spacing: 3.2)),
                  const SizedBox(height: 1),
                  Text(cap.$2, maxLines: 1, style: Lux.display(27, color: Lux.ink, italic: true)),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _phone(Widget child) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          boxShadow: const [BoxShadow(color: Color(0xB0000000), blurRadius: 26, offset: Offset(0, 10))],
        ),
        child: Container(
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Lux.gold.withValues(alpha: 0.55), width: 1.2),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: FittedBox(
              fit: BoxFit.fill,
              child: SizedBox(width: app.width, height: app.height, child: child),
            ),
          ),
        ),
      );

  Widget _appTree() => AppScope(
        locale: _locale,
        theme: _theme,
        child: ValueListenableBuilder(
          valueListenable: _home,
          builder: (c, home, _) => MaterialApp(
            key: ObjectKey(home),
            debugShowCheckedModeBanner: false,
            theme: AppThemes.light,
            // Symbols the text faces lack (★ ≤ →) come from a fallback face, as on the phone.
            darkTheme: AppThemes.dark.copyWith(
              textTheme: AppThemes.dark.textTheme.apply(fontFamilyFallback: const ['Symbols']),
            ),
            themeMode: ThemeMode.dark,
            locale: Locale(Lang.code),
            supportedLocales: const [Locale('tr'), Locale('en'), Locale('ru'), Locale('es')],
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            builder: (c, child) => ValueListenableBuilder(
              valueListenable: _full,
              builder: (c, full, _) => MediaQuery(
                data: MediaQuery.of(c).copyWith(
                  size: full ? const Size(w, h) : app,
                  padding: full ? EdgeInsets.zero : const EdgeInsets.only(top: 14, bottom: 8),
                  viewPadding: full ? EdgeInsets.zero : const EdgeInsets.only(top: 14, bottom: 8),
                  devicePixelRatio: dpr,
                ),
                child: child!,
              ),
            ),
            home: home,
          ),
        ),
      );

  // ---- recording ----

  Future<void> record(int index, Scene sc) async {
    _id = '${index.toString().padLeft(2, '0')}_${sc.id}';
    lastFrames = 0;
    session = null;
    _fade.value = 0;
    _touches.value = const [];
    _caption.value = (promoText(sc.kicker), promoText(sc.title));
    _full.value = sc.full;
    final rawFile = File('${dir.path}/$_id.rgba');
    if (!still) _raw = rawFile.openSync(mode: FileMode.write);
    await t.pumpWidget(_root());
    await sc.run(this);
    // Fade out.
    for (var i = 4; i >= 0; i--) {
      _fade.value = i / 5;
      await _frame(fade: false);
    }
    _raw?.closeSync();
    _raw = null;
    // Leave the scene: drop its tree and let its timers run out.
    _home.value = SizedBox(key: UniqueKey());
    await t.pump();
    await t.pump(const Duration(seconds: 8));
    if (!still) {
      final r = Process.runSync('ffmpeg', [
        '-y', '-loglevel', 'error', '-f', 'rawvideo', '-pix_fmt', 'rgba',
        '-s', '${(w * dpr).round()}x${(h * dpr).round()}', '-r', '$fps', '-i', rawFile.path,
        '-c:v', 'libx264', '-preset', 'medium', '-crf', '15', '-pix_fmt', 'yuv420p', '${dir.path}/$_id.mp4',
      ]);
      if (r.exitCode != 0) throw StateError('ffmpeg: ${r.stderr}');
      rawFile.deleteSync();
    }
  }

  Future<void> _frame({bool fade = true}) async {
    if (fade && _fade.value < 1) _fade.value = (_fade.value + 0.2).clamp(0, 1);
    if (_touches.value.isNotEmpty) {
      for (final x in _touches.value) {
        x.age++;
      }
      _touches.value = [for (final x in _touches.value) if (x.age < 12) x];
    }
    await t.pump(_step);
    final n = lastFrames++;
    if (still && n % 40 != 20) {
      // Still let real-time work (isolates) come through.
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
      return;
    }
    await t.runAsync(() async {
      final b = _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: dpr);
      if (still) {
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File('${dir.path}/still_${_id}_${n.toString().padLeft(4, '0')}.png').writeAsBytesSync(Uint8List.sublistView(png!));
      } else {
        final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
        _raw!.writeFromSync(Uint8List.sublistView(bd!));
      }
      img.dispose();
    });
  }

  /// Record [n] frames.
  Future<void> frames(int n) async {
    for (var i = 0; i < n; i++) {
      await _frame();
    }
  }

  Future<void> secs(double s) => frames((s * fps).round());

  /// Advance without recording (loading, skipping a countdown).
  Future<void> skip(double s) async {
    final n = (s * fps).round();
    for (var i = 0; i < n; i++) {
      await t.pump(_step);
      if (i % 5 == 0) await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
    }
  }

  /// One step: recorded or not.
  Future<void> step(bool rec) async {
    if (rec) {
      await frames(1);
    } else {
      await t.pump(_step);
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
    }
  }

  /// Advance unrecorded until [done] (at most [max] seconds of game time).
  Future<void> skipUntil(bool Function() done, {double max = 12}) async {
    for (var i = 0; i < max * fps && !done(); i++) {
      await step(false);
    }
  }

  /// Record until [done] (at most [max] seconds).
  Future<void> framesUntil(bool Function() done, {double max = 6}) async {
    for (var i = 0; i < max * fps && !done(); i++) {
      await frames(1);
    }
  }

  /// Let real asynchronous work (isolates) finish, pumping meanwhile, until [done].
  Future<void> settle(bool Function() done, {int maxMs = 20000}) async {
    for (var i = 0; i < maxMs ~/ 10 && !done(); i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await t.pump(const Duration(milliseconds: 1));
    }
  }

  // ---- showing things ----

  Future<void> show(Widget home) async {
    _home.value = home;
    await t.pump();
  }

  /// Open [id] at [level] in the real play shell and wait until the level is generated.
  Future<void> play(String id, int level, {String mode = 'level'}) async {
    final g = kCoreGames.firstWhere((g) => g.id == id);
    session = null;
    await show(PlayScreen(game: _spy(g), level: level, mode: mode));
    await settle(() => session != null && !session!.loading);
    await t.pump(const Duration(milliseconds: 16));
  }

  GameInfo _spy(GameInfo g) => GameInfo(
        id: g.id,
        name: g.name,
        tagline: g.tagline,
        glyph: g.glyph,
        category: g.category,
        tint: g.tint,
        hasLevels: g.hasLevels,
        hasEndless: g.hasEndless,
        endlessLabel: g.endlessLabel,
        view: (c, s) {
          session = s;
          return g.view!(c, s);
        },
        tutorials: g.tutorials,
        matchModes: g.matchModes,
        customHome: g.customHome,
        cardLine: g.cardLine,
        inHub: g.inHub,
        sections: g.sections,
        speed: g.speed,
      );

  // ---- acting ----

  /// Send [action] straight to the core (the view animates the new state).
  bool act(Map<String, dynamic> action) => session!.act(action);

  void _mark(Offset p) => _touches.value = [..._touches.value, _Touch(p)];

  /// Tap at a point of the 360×640 frame, showing a touch mark.
  Future<void> tapAt(Offset p) async {
    _mark(p);
    await t.tapAt(p);
  }

  Future<void> tap(Finder f) async {
    final p = t.getCenter(f.first);
    await tapAt(p);
  }

  /// Tap a point given in the coordinates of the widget found by [f] (fractions of its size).
  Future<void> tapIn(Finder f, double fx, double fy) async {
    final r = t.getRect(f.first);
    await tapAt(Offset(r.left + r.width * fx, r.top + r.height * fy));
  }

  /// Drag from [a] to [b] over [n] recorded frames.
  Future<void> drag(Offset a, Offset b, {int n = 10, int hold = 0}) async {
    final g = await t.startGesture(a);
    _mark(a);
    await frames(1 + hold);
    for (var i = 1; i <= n; i++) {
      final k = Curves.easeInOut.transform(i / n);
      final p = Offset.lerp(a, b, k)!;
      await g.moveTo(p);
      if (i % 2 == 0) _mark(p);
      await frames(1);
    }
    _mark(b);
    await g.up();
    await frames(1);
  }

  Rect rect(Finder f) => t.getRect(f.first);
}

class _TouchPainter extends CustomPainter {
  final List<_Touch> list;
  _TouchPainter(this.list);

  @override
  void paint(Canvas canvas, Size size) {
    for (final x in list) {
      final k = x.age / 12;
      canvas.drawCircle(x.at, 7 + 9 * k, Paint()..color = const Color(0xFFFFF3D0).withValues(alpha: 0.42 * (1 - k)));
      canvas.drawCircle(
          x.at,
          7 + 9 * k,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.75 * (1 - k)));
    }
  }

  @override
  bool shouldRepaint(_TouchPainter old) => true;
}

/// A caption or title card text in the video's language: the app's dictionary, or the video's own
/// lines below.
String promoText(String tr) => Lang.en ? (_promoEn[tr] ?? Lang.english(tr) ?? tr) : tr;

const Map<String, String> _promoEn = {
  'Mantık': 'Logic',
  'Zihin': 'Mind',
  'Zihin antrenmanı': 'Mind training',
  'Zeka küpü': 'Puzzle cube',
  'Her gün beş oyun': 'Five games a day',
  'Her oyunun sayfası': 'Every game\'s page',
  '500 bölüm, dört zorluk': '500 levels, four tiers',
  'Schulte Tablosu · Bölüm 300': 'Schulte Table · Level 300',
  'Zamanlayıcı': 'Timer',
  'Küp Defteri': 'Cube Notebook',
  '3B oynatıcı': '3D player',
  'ZİHİN KULÜBÜ': 'MIND CLUB',
  'Mantık · Strateji · Hafıza · Dikkat · Zihin · Küp': 'Logic · Strategy · Memory · Attention · Mind · Cube',
  '{0} oyun · her birinde zorlaşan bölümler': '{0} games · levels that get harder',
};

/// [promoText] with `{0}` filled.
String promoTextF(String tr, Object a) => promoText(tr).replaceAll('{0}', '$a');
