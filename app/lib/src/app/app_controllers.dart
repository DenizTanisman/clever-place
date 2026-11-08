import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Holds the chosen [Locale] (null = follow the device) and persists it (spec §1, §5).
class LocaleController extends ChangeNotifier {
  static const _key = 'locale';
  Locale? _locale;
  Locale? get locale => _locale;

  LocaleController(this._locale);

  Future<void> setLocale(Locale? value) async {
    if (_locale == value) return;
    _locale = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (value == null) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(_key, value.languageCode);
    }
  }
}

/// Holds the [ThemeMode] (dark/light) and persists it (spec §2, §5).
class ThemeController extends ChangeNotifier {
  static const _key = 'theme';
  ThemeMode _mode;
  ThemeMode get mode => _mode;

  ThemeController(this._mode);

  Future<void> setMode(ThemeMode value) async {
    if (_mode == value) return;
    _mode = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, value == ThemeMode.light ? 'light' : 'dark');
  }
}

/// The persisted app preferences, loaded once at startup.
class AppPrefs {
  final Locale? locale;
  final ThemeMode themeMode;
  final bool sfxEnabled;
  final double sfxVolume;
  final bool musicEnabled;
  final double musicVolume;
  const AppPrefs(this.locale, this.themeMode, this.sfxEnabled, this.sfxVolume,
      this.musicEnabled, this.musicVolume);

  static Future<AppPrefs> load(Iterable<Locale> supported) async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString('locale');
    final locale = (code != null && supported.any((l) => l.languageCode == code))
        ? Locale(code)
        : null; // null → MaterialApp resolves the device locale (with fallback)
    final theme = prefs.getString('theme') == 'light' ? ThemeMode.light : ThemeMode.dark;
    final sfxEnabled = prefs.getBool('sfx_enabled') ?? true;
    final sfxVolume = prefs.getDouble('sfx_volume') ?? 0.8;
    final musicEnabled = prefs.getBool('music_enabled') ?? true;
    final musicVolume = prefs.getDouble('music_volume') ?? 0.6;
    return AppPrefs(locale, theme, sfxEnabled, sfxVolume, musicEnabled, musicVolume);
  }
}

/// Exposes the two controllers to the widget tree.
class AppScope extends InheritedWidget {
  final LocaleController locale;
  final ThemeController theme;
  const AppScope({
    super.key,
    required this.locale,
    required this.theme,
    required super.child,
  });

  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope old) => false; // controllers notify directly
}
