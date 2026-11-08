import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Background music. This build ships without audio clips, so every transition is a silent no-op;
/// the on/off and volume preferences are still kept.
class MusicController extends ChangeNotifier {
  MusicController._();
  static final MusicController instance = MusicController._();

  static const _enabledKey = 'music_enabled';
  static const _volumeKey = 'music_volume';

  bool _enabled = true;
  double _volume = 0.6;

  bool get enabled => _enabled;
  double get volume => _volume;

  Future<void> init({required bool enabled, required double volume}) async {
    _enabled = enabled;
    _volume = volume;
  }

  void enterLobby() {}
  void startMatch() {}
  void endMatch() {}
  void suspend() {}
  void resumeFromBackground() {}

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
