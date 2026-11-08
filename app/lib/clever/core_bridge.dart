import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

typedef _CallNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

/// Thin FFI wrapper around the Rust core (`core/` → `libcp_core.so`). One function, JSON in/out.
/// See `core/src/lib.rs` for the protocol.
class Core {
  Core._();

  static final DynamicLibrary _lib = Platform.isAndroid
      ? DynamicLibrary.open('libcp_core.so')
      : Platform.isMacOS
          ? DynamicLibrary.open('libcp_core.dylib')
          : DynamicLibrary.process();
  static final _call = _lib.lookupFunction<_CallNative, _CallNative>('cp_call');
  static final _free = _lib.lookupFunction<_FreeNative, _FreeDart>('cp_free');

  static Map<String, dynamic> call(Map<String, dynamic> request) {
    final req = jsonEncode(request).toNativeUtf8();
    try {
      final res = _call(req);
      final text = res.toDartString();
      _free(res);
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      malloc.free(req);
    }
  }

  /// Heavy calls (level generation) run off the UI isolate so animations never stutter. The Rust
  /// session registry is process-global, so sessions created here are usable from the UI isolate.
  static Future<Map<String, dynamic>> callAsync(Map<String, dynamic> request) =>
      Isolate.run(() => call(request));
}

/// A live game session in the Rust core. Widgets listen to it and re-render from [state].
class GameSession extends ChangeNotifier {
  final String game;
  final int level;
  final String mode;
  GameSession({required this.game, required this.level, this.mode = 'level'});

  int? _id;
  Map<String, dynamic> state = const {};
  bool loading = true;
  String? fatal;

  /// Last rejected action's message (shown inline, cleared on the next accepted action).
  String? lastError;
  int errorSerial = 0;

  String get status => (state['status'] as String?) ?? 'playing';
  bool get finished => status == 'won' || status == 'lost' || status == 'draw';
  int get stars => (state['stars'] as num?)?.toInt() ?? 0;

  Future<void> start() async {
    final r = await Core.callAsync({'op': 'new', 'game': game, 'level': level, 'mode': mode});
    if (r['ok'] == true) {
      _id = (r['id'] as num).toInt();
      state = Map<String, dynamic>.from(r['state'] as Map);
    } else {
      fatal = r['error']?.toString() ?? 'Bilinmeyen hata';
    }
    loading = false;
    notifyListeners();
  }

  bool act(Map<String, dynamic> action) {
    final id = _id;
    if (id == null) return false;
    final r = Core.call({'op': 'act', 'id': id, 'action': action});
    if (r['state'] is Map) state = Map<String, dynamic>.from(r['state'] as Map);
    final ok = r['ok'] == true;
    if (ok) {
      lastError = null;
    } else {
      lastError = r['error']?.toString();
      errorSerial++;
    }
    notifyListeners();
    return ok;
  }

  /// Like [act] but runs off the UI isolate — for actions that make the core think (an AI
  /// opponent's move), so animations keep running while it searches. Returns false if the session
  /// was disposed meanwhile.
  Future<bool> actAsync(Map<String, dynamic> action) async {
    final id = _id;
    if (id == null || _disposed) return false;
    final r = await Core.callAsync({'op': 'act', 'id': id, 'action': action});
    if (_disposed) return false;
    if (r['state'] is Map) state = Map<String, dynamic>.from(r['state'] as Map);
    final ok = r['ok'] == true;
    if (ok) {
      lastError = null;
    } else {
      lastError = r['error']?.toString();
      errorSerial++;
    }
    notifyListeners();
    return ok;
  }

  bool _disposed = false;

  void tick(double dtMs) {
    final id = _id;
    if (id == null || finished) return;
    final r = Core.call({'op': 'tick', 'id': id, 'dt': dtMs});
    if (r['state'] is Map) {
      state = Map<String, dynamic>.from(r['state'] as Map);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final id = _id;
    if (id != null) {
      try {
        Core.call({'op': 'drop', 'id': id});
      } catch (e) {
        debugPrint('drop failed: $e');
      }
    }
    super.dispose();
  }
}
