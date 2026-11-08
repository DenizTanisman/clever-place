// Audio controller unit tests. Run with `flutter test`.

import 'package:flutter_test/flutter_test.dart';
import 'package:clever_place/src/audio/music_controller.dart';
import 'package:clever_place/src/audio/sfx_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('SFX play is a safe no-op before init (no audio backend in tests)', () {
    // Never throws even though no clips are loaded — SFX must never disrupt the app.
    expect(() => SfxController.instance.play(SoundId.place), returnsNormally);
    expect(() => SfxController.instance.play(SoundId.matchStart), returnsNormally);
    expect(() => SfxController.instance.play(SoundId.menuForward), returnsNormally);
  });

  test('Music transitions are safe no-ops before init', () {
    expect(() => MusicController.instance.enterLobby(), returnsNormally);
    expect(() => MusicController.instance.startMatch(), returnsNormally);
    expect(() => MusicController.instance.endMatch(), returnsNormally);
  });

  test('SFX setEnabled / setVolume update getters and persist', () async {
    SharedPreferences.setMockInitialValues({});
    final sfx = SfxController.instance;
    await sfx.setEnabled(false);
    expect(sfx.enabled, isFalse);
    await sfx.setVolume(0.3);
    expect(sfx.volume, 0.3);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('sfx_enabled'), isFalse);
    expect(prefs.getDouble('sfx_volume'), 0.3);
    await sfx.setEnabled(true);
  });

  test('Music setEnabled / setVolume update getters and persist', () async {
    SharedPreferences.setMockInitialValues({});
    final music = MusicController.instance;
    await music.setEnabled(false);
    expect(music.enabled, isFalse);
    await music.setVolume(0.25);
    expect(music.volume, 0.25);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('music_enabled'), isFalse);
    expect(prefs.getDouble('music_volume'), 0.25);
    await music.setEnabled(true);
  });
}
