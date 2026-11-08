import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One-shot sound effects. This build ships without audio clips, so [play] is always silent; the
/// on/off and volume preferences are still kept.
enum SoundId {
  menuForward,
  menuBack,
  menuTap,
  place,
  select,
  matchStart,
  win,
  lose,
  draw,
}

class SfxController extends ChangeNotifier {
  SfxController._();
  static final SfxController instance = SfxController._();

  static const _enabledKey = 'sfx_enabled';
  static const _volumeKey = 'sfx_volume';

  bool _enabled = true;
  double _volume = 0.8;

  bool get enabled => _enabled;
  double get volume => _volume;

  Future<void> init({required bool enabled, required double volume}) async {
    _enabled = enabled;
    _volume = volume;
  }

  /// Silent: there is nothing to play.
  void play(SoundId id) {}

  void suspend() {}

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, value);
  }

  Future<void> setVolume(double value) async {
    _volume = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_volumeKey, value);
  }
}
