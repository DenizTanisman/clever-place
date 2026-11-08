import 'package:flutter/material.dart';

import '../../clever/daily_goal_settings.dart';
import '../../clever/lux.dart';
import '../../l10n/app_localizations.dart';
import '../app/app_controllers.dart';
import '../audio/sfx_controller.dart';

AppLocalizations _l(BuildContext c) => AppLocalizations.of(c)!;

/// Locale-aware upper-casing. Dart's [String.toUpperCase] is not Turkish-aware ('i' → 'I'), so a
/// Turkish heading must be pre-cased with the dotted İ (U+0130) to read correctly.
String _localeUpper(BuildContext c, String s) {
  if (Localizations.localeOf(c).languageCode == 'tr') {
    s = s.replaceAll('ı', 'I').replaceAll('i', 'İ');
  }
  return s.toUpperCase();
}

/// Settings in the Clever Place "Zümrüt Kadife" look (emerald velvet + gold), reached from the hub's
/// tune icon. It always renders in the Lux dark style, whatever the app's light/dark theme setting.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  /// Gold-on-emerald theme for the Material controls (switches, sliders, ink) on this page.
  static final ThemeData _luxTheme = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    fontFamily: 'Jost',
    scaffoldBackgroundColor: Lux.bg0,
    colorScheme: const ColorScheme.dark(
      primary: Lux.gold,
      onPrimary: Color(0xFF2A1D05),
      secondary: Lux.goldLight,
      surface: Lux.panel,
      onSurface: Lux.ink,
    ),
    iconTheme: const IconThemeData(color: Lux.muted),
    switchTheme: SwitchThemeData(
      thumbColor:
          WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Lux.goldLight : Lux.muted),
      trackColor:
          WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Lux.goldDeep : Lux.cardDeep),
      trackOutlineColor:
          WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Lux.gold : Lux.line),
      overlayColor: WidgetStatePropertyAll(Lux.gold.withValues(alpha: 0.14)),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: Lux.gold,
      inactiveTrackColor: Lux.gold.withValues(alpha: 0.18),
      thumbColor: Lux.goldLight,
      overlayColor: Lux.gold.withValues(alpha: 0.14),
      disabledActiveTrackColor: Lux.muted.withValues(alpha: 0.5),
      disabledInactiveTrackColor: Lux.muted.withValues(alpha: 0.15),
      disabledThumbColor: Lux.muted,
      trackHeight: 3,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l = _l(context);
    final scope = AppScope.of(context);
    return Theme(
      data: _luxTheme,
      child: Scaffold(
        backgroundColor: Lux.bg0,
        body: LuxBackground(
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 36),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    IconButton(
                        onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back, color: Lux.ink)),
                  ]),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: FoilText(l.settingsTitle, style: Lux.display(34, italic: true)),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _heading(context, l.settingsLanguage),
                        AnimatedBuilder(
                          animation: scope.locale,
                          builder: (context, _) {
                            final current =
                                scope.locale.locale?.languageCode ?? Localizations.localeOf(context).languageCode;
                            Widget opt(String code, String label) =>
                                _choice(label, current == code, () => scope.locale.setLocale(Locale(code)));
                            return Column(
                              children: [
                                _pair(opt('tr', 'Türkçe'), opt('en', 'English')),
                                const SizedBox(height: 10),
                                _pair(opt('ru', 'Русский'), opt('es', 'Español')),
                              ],
                            );
                          },
                        ),
                        _heading(context, l.settingsTheme),
                        AnimatedBuilder(
                          animation: scope.theme,
                          builder: (context, _) => _pair(
                            _choice(l.themeDark, scope.theme.mode == ThemeMode.dark,
                                () => scope.theme.setMode(ThemeMode.dark),
                                icon: Icons.dark_mode_outlined),
                            _choice(l.themeLight, scope.theme.mode == ThemeMode.light,
                                () => scope.theme.setMode(ThemeMode.light),
                                icon: Icons.light_mode_outlined),
                          ),
                        ),
                        // Clever Place's daily mix; Turkish only, like the rest of the hub.
                        _heading(context, 'Günün hedefi'),
                        const DailyGoalSettings(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Gold section ornament. The label is upper-cased for the current locale first, so only Turkish
  /// gets the dotted İ ([Lux.upper] alone would turn English "Music" into "MUSİC").
  Widget _heading(BuildContext context, String s) => LuxHeading(_localeUpper(context, s));

  Widget _pair(Widget a, Widget b) => Row(
        children: [Expanded(child: a), const SizedBox(width: 10), Expanded(child: b)],
      );

  /// One option card; the selected one is gold-rimmed with a gold check.
  Widget _choice(String label, bool selected, VoidCallback onTap, {IconData? icon}) {
    return LuxCard(
      highlight: selected,
      radius: 16,
      padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 16),
      onTap: () {
        SfxController.instance.play(SoundId.menuTap); // committed language/theme selection (silent here)
        onTap();
      },
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, color: selected ? Lux.gold : Lux.muted, size: 20),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Lux.ui(16,
                    color: selected ? Lux.goldLight : Lux.ink, weight: selected ? FontWeight.w600 : FontWeight.w500)),
          ),
          if (selected) const Icon(Icons.check_rounded, color: Lux.gold, size: 20),
        ],
      ),
    );
  }
}
