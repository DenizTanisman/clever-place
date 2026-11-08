import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../lux.dart';
import 'cube_style.dart';

/// Which Küp Defteri rows the 3D player plays, and what: `assets/cube/player/player_index.json`,
/// keyed by the case
/// id; one entry per row of the case's algorithms, null for rows it can't play (prose rows).
class CubePlayerIndex {
  static const asset = 'assets/cube/player/player_index.json';

  /// The offline player page; three.js, the cube models and its script sit next to it.
  static const page = 'assets/cube/player/index.html';

  final Map<String, List<Map<String, dynamic>?>> cases;
  const CubePlayerIndex(this.cases);

  /// What row [row] of case [caseId] plays, or null.
  Map<String, dynamic>? entry(String caseId, int row) {
    final rows = cases[caseId];
    return rows != null && row < rows.length ? rows[row] : null;
  }

  /// 3x3 · 4x4 · 2x2 · Megaminx.
  static String kind(Map<String, dynamic> entry) {
    final p = entry['p'];
    return p == 'mega' ? 'Megaminx' : '${p}x$p';
  }

  static CubePlayerIndex? _cache;

  /// Cached; once loaded it comes back synchronously.
  static Future<CubePlayerIndex> load() {
    final hit = _cache;
    if (hit != null) return SynchronousFuture(hit);
    return rootBundle.loadString(asset).then((s) => _cache = parse(s));
  }

  @visibleForTesting
  static CubePlayerIndex parse(String json) {
    final m = jsonDecode(json) as Map<String, dynamic>;
    return CubePlayerIndex({
      for (final e in (m['cases'] as Map<String, dynamic>).entries)
        e.key: [for (final r in e.value as List) r as Map<String, dynamic>?],
    });
  }
}

/// The 3D player for one algorithm row, full screen: the web notebook's player (three.js) in a
/// WebView, loaded from the app's assets so it works offline. It starts from the case the row
/// solves (a Gösteri row: from where the rows above it left the cube) and plays it slowly or move
/// by move.
class CubePlayerPage extends StatefulWidget {
  final String title;
  final String label;
  final Map<String, dynamic> entry;
  const CubePlayerPage({super.key, required this.title, required this.label, required this.entry});

  static const speedKey = 'cube-player-speed';

  @override
  State<CubePlayerPage> createState() => _CubePlayerPageState();
}

class _CubePlayerPageState extends State<CubePlayerPage> {
  late final WebViewController _web;
  bool _started = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel('KupHost', onMessageReceived: _onMessage)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) => _open(),
        // The page never leaves its folder.
        onNavigationRequest: (r) => r.url.startsWith('file:') || r.url.startsWith('about:')
            ? NavigationDecision.navigate
            : NavigationDecision.prevent,
      ))
      ..loadFlutterAsset(CubePlayerIndex.page);
  }

  Future<void> _open() async {
    if (_started) return;
    _started = true;
    final prefs = await SharedPreferences.getInstance();
    final entry = {
      ...widget.entry,
      'label': widget.label,
      'speed': prefs.getDouble(CubePlayerPage.speedKey) ?? 1,
    };
    await _web.runJavaScript('KupApp.open(${jsonEncode(entry)});');
    if (mounted) setState(() => _ready = true);
  }

  Future<void> _onMessage(JavaScriptMessage m) async {
    if (!m.message.startsWith('speed:')) return;
    final v = double.tryParse(m.message.substring(6));
    if (v != null) (await SharedPreferences.getInstance()).setDouble(CubePlayerPage.speedKey, v);
  }

  @override
  Widget build(BuildContext context) {
    return CubeTheme(
      child: Scaffold(
        backgroundColor: Lux.bg0,
        body: LuxBackground(
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CubeHeader(widget.title),
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(child: WebViewWidget(controller: _web)),
                      if (!_ready) const Center(child: CircularProgressIndicator(color: Lux.gold)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
