import 'package:flutter/services.dart';

/// FLAG_KEEP_SCREEN_ON while the cube timer is open: a 4x4 solve outlasts
/// the screen timeout.
class ScreenAwake {
  static const _channel = MethodChannel('clever_place/screen');

  static Future<void> on() => _invoke('keepScreenOn');

  static Future<void> off() => _invoke('allowScreenOff');

  static Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // Tests / non-Android hosts: no-op.
    }
  }
}
