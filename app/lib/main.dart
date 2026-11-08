import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n/app_localizations.dart';
import 'src/app/app_controllers.dart';
import 'src/audio/music_controller.dart';
import 'src/audio/sfx_controller.dart';
import 'clever/core_bridge.dart';
import 'clever/hub_screen.dart';
import 'clever/progress.dart';
import 'src/theme/app_themes.dart';

const List<Locale> kSupportedLocales = [Locale('tr'), Locale('en'), Locale('ru'), Locale('es')];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await AppPrefs.load(kSupportedLocales);
  final progress = await Progress.load();
  try {
    final info = Core.call({'op': 'info'});
    progress.visibleLevels = (info['visible_levels'] as num?)?.toInt() ?? 2;
  } catch (e) {
    debugPrint('Rust core unavailable: $e');
  }
  // The audio layers ship without any clips in this build, so these calls are silent.
  SfxController.instance.init(enabled: prefs.sfxEnabled, volume: prefs.sfxVolume);
  MusicController.instance
      .init(enabled: prefs.musicEnabled, volume: prefs.musicVolume)
      .then((_) => MusicController.instance.enterLobby());
  runApp(CleverPlaceApp(
    locale: LocaleController(prefs.locale),
    theme: ThemeController(prefs.themeMode),
  ));
}

class CleverPlaceApp extends StatefulWidget {
  final LocaleController locale;
  final ThemeController theme;

  /// First screen; the Clever Place hub unless a test starts somewhere else.
  final Widget? home;
  const CleverPlaceApp({
    super.key,
    required this.locale,
    required this.theme,
    this.home,
  });

  @override
  State<CleverPlaceApp> createState() => _CleverPlaceAppState();
}

class _CleverPlaceAppState extends State<CleverPlaceApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Don't keep audio running in the background / with the screen off (spec: pause when away, resume
    // on return). `inactive` is transient (app switcher, notification shade) — ignore it to avoid
    // stutter; act on paused/hidden/detached and resume on resumed.
    switch (state) {
      case AppLifecycleState.resumed:
        MusicController.instance.resumeFromBackground();
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        MusicController.instance.suspend();
        SfxController.instance.suspend();
      case AppLifecycleState.inactive:
        break;
    }
  }

  LocaleController get locale => widget.locale;
  ThemeController get theme => widget.theme;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      locale: locale,
      theme: theme,
      // Rebuild MaterialApp whenever locale or theme changes.
      child: AnimatedBuilder(
        animation: Listenable.merge([locale, theme]),
        builder: (context, _) {
          return MaterialApp(
            title: 'Clever Place',
            debugShowCheckedModeBanner: false,
            theme: AppThemes.light,
            darkTheme: AppThemes.dark,
            themeMode: theme.mode,
            locale: locale.locale,
            supportedLocales: kSupportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: widget.home ?? const HubScreen(),
          );
        },
      ),
    );
  }
}
