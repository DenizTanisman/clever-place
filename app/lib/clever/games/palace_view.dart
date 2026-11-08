import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// Hafıza Sarayı board: a lit, winding path of stations across the top (the camera glides so the
/// current station sits in the middle and glows), a big item card in the middle, and the controls
/// at thumb height (place button / candidate grid / Turkish keyboard). Rules, timing, candidates and
/// checking live in Rust.
///
/// Motion: each new item card rises in from the right; placing it (tap, swipe left or the button)
/// sends a small gold chip along an arc onto the station, which answers with a soft ring. In recall
/// the path glides to the probed station; a pick flashes its node green or bordeaux and a banner
/// shows the right item when the answer was wrong.
Widget palaceView(BuildContext context, GameSession s) => _PalaceBoard(key: ObjectKey(s), session: s);

const _headerH = 50.0;

class _PalaceBoard extends StatefulWidget {
  final GameSession session;
  const _PalaceBoard({super.key, required this.session});

  @override
  State<_PalaceBoard> createState() => _PalaceBoardState();
}

class _PalaceBoardState extends State<_PalaceBoard> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;

  double _focus = 0;

  // Show-phase tracking for the placing animation.
  int _seenRound = -1;
  int _seenIndex = -1;
  String _seenItem = '';
  double _flyAt = -10;
  int _flyIdx = 0;
  String _flyWord = '';

  // Recall feedback.
  int _seenSerial = 0;
  double _fbAt = -10;
  bool _fbOk = false;
  int _fbIdx = -1;

  String _typed = '';

  GameSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    final last = s.state['last'];
    if (last is Map) _seenSerial = (last['serial'] as num).toInt();
    _focus = _target(s.state).toDouble();
    s.addListener(_onSession);
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    s.removeListener(_onSession);
    _ticker.dispose();
    super.dispose();
  }

  int _target(Map<String, dynamic> st) {
    final show = st['show'];
    if (show is Map) return (show['index'] as num).toInt();
    final probe = st['probe'];
    if (probe is Map) return (probe['station_index'] as num).toInt();
    final last = st['last'];
    if (st['phase'] == 'done' && last is Map) return (last['station_index'] as num).toInt();
    return 0;
  }

  bool _animating(double now) =>
      (now - _flyAt) < 0.9 || (now - _fbAt) < 1.0 || (_focus - _target(s.state)).abs() > 0.002;

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1000.0;
    _lastTick = elapsed;
    final target = _target(s.state).toDouble();
    _focus += (target - _focus) * (1 - math.exp(-dt / 150));
    if ((_focus - target).abs() < 0.002) _focus = target;
    final phase = s.state['phase'];
    if (!s.finished && (phase == 'countdown' || phase == 'show')) {
      s.tick(dt);
    } else if (_animating(_now)) {
      setState(() {});
    }
  }

  void _onSession() {
    final st = s.state;
    final round = (st['round'] as num?)?.toInt() ?? 0;
    final show = st['show'];
    if (show is Map) {
      final idx = (show['index'] as num).toInt();
      if (round == _seenRound && idx != _seenIndex && _seenIndex >= 0) _fly(_seenIndex, _seenItem);
      _seenRound = round;
      _seenIndex = idx;
      _seenItem = show['item'] as String? ?? '';
    } else if (_seenIndex >= 0 && round == _seenRound) {
      // Last item of the walk was placed (or timed out): show → recall.
      _fly(_seenIndex, _seenItem);
      _seenIndex = -1;
    }
    final last = st['last'];
    if (last is Map) {
      final serial = (last['serial'] as num).toInt();
      if (serial != _seenSerial) {
        _seenSerial = serial;
        _fbAt = _now;
        _fbOk = last['correct'] == true;
        _fbIdx = (last['station_index'] as num).toInt();
        if (_fbOk) {
          HapticFeedback.lightImpact();
        } else {
          HapticFeedback.mediumImpact();
        }
      }
    }
  }

  void _fly(int idx, String word) {
    _flyAt = _now;
    _flyIdx = idx;
    _flyWord = word;
  }

  void _next() {
    if (s.state['phase'] != 'show' || s.finished) return;
    HapticFeedback.selectionClick();
    s.act({'next': true});
  }

  void _pick(int i) {
    if (s.state['phase'] != 'recall' || s.finished) return;
    HapticFeedback.selectionClick();
    s.act({'pick': i});
  }

  void _submitTyped() {
    if (s.state['phase'] != 'recall' || _typed.trim().isEmpty) return;
    if (s.act({'type': _typed})) setState(() => _typed = '');
  }

  void _skip() {
    if (s.state['phase'] != 'recall') return;
    HapticFeedback.selectionClick();
    if (s.act({'skip': true})) setState(() => _typed = '');
  }

  void _typeKey(String k) {
    HapticFeedback.selectionClick();
    setState(() {
      if (k == '⌫') {
        if (_typed.isNotEmpty) _typed = _typed.substring(0, _typed.length - 1);
      } else if (_typed.length < 24) {
        _typed += k;
      }
    });
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final st = s.state;
    final phase = st['phase'] as String? ?? 'intro';
    final now = _now;
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      final h = box.maxHeight;
      final pathH = (h * 0.25).clamp(150.0, 220.0);
      final bandRect = Rect.fromLTWH(0, _headerH, w, pathH);
      final stations = (st['stations'] as List?)?.cast<String>() ?? const <String>[];
      final marks = (st['marks'] as List?)?.cast<String>() ?? const <String>[];
      final current = phase == 'show' || phase == 'recall' ? _target(st) : -1;
      final cardCenter = Offset(w / 2, _headerH + pathH + (h - _headerH - pathH) * 0.3);
      return Stack(
        children: [
          Column(
            children: [
              SizedBox(height: _headerH, child: _header(st, phase)),
              SizedBox(
                height: pathH,
                child: CustomPaint(
                  size: Size(w, pathH),
                  painter: _PathPainter(
                    stations: stations,
                    marks: marks,
                    focus: _focus,
                    current: current,
                    now: now,
                    flashAt: _fbAt,
                    flashOk: _fbOk,
                    flashIdx: _fbIdx,
                    ringAt: _flyAt + 0.42,
                    ringIdx: _flyIdx,
                    dim: phase == 'clear' || phase == 'intro',
                  ),
                ),
              ),
              Expanded(child: _body(st, phase)),
            ],
          ),
          if (now - _flyAt < 0.45) Positioned.fill(child: IgnorePointer(child: _flyChip(now, cardCenter, bandRect))),
          if (phase == 'intro' || phase == 'clear') Positioned.fill(child: _card(st, phase)),
          if (phase == 'countdown') Positioned.fill(child: IgnorePointer(child: _countdown(st))),
        ],
      );
    });
  }

  Widget _header(Map<String, dynamic> st, String phase) {
    final rounds = (st['rounds'] as num?)?.toInt() ?? 1;
    final round = (st['round'] as num?)?.toInt() ?? 0;
    final len = (st['list_len'] as num?)?.toInt() ?? 0;
    final show = st['show'] is Map ? Map<String, dynamic>.from(st['show'] as Map) : null;
    final probe = st['probe'] is Map ? Map<String, dynamic>.from(st['probe'] as Map) : null;
    String left;
    if (show != null) {
      left = 'Yerleştir ${show['number']} / ${show['total']}';
    } else if (probe != null) {
      left = 'Hatırla ${(probe['pos'] as num).toInt() + 1} / ${probe['total']}';
    } else {
      left = '${st['palace']} · $len durak';
    }
    final listTag = rounds > 1 ? ' · ${round + 1}. liste' : '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(left, maxLines: 1, overflow: TextOverflow.ellipsis, style: Lux.ui(17, weight: FontWeight.w700)),
                Text('${st['palace']}$listTag', maxLines: 1, overflow: TextOverflow.ellipsis, style: Lux.ui(12.5, color: Lux.muted)),
              ],
            ),
          ),
          if ((st['answered'] as num? ?? 0) > 0)
            Text('Doğru ${st['correct']} / ${st['answered']}', style: Lux.ui(14, color: Lux.goldLight, weight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _body(Map<String, dynamic> st, String phase) {
    switch (phase) {
      case 'show':
        return _showBody(st);
      case 'recall':
        return st['typed'] == true ? _typedBody(st) : _gridBody(st);
      default:
        return _restBody(st);
    }
  }

  Widget _restBody(Map<String, dynamic> st) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Spacer(),
          _feedbackBanner(st),
          const Spacer(flex: 2),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ show

  Widget _showBody(Map<String, dynamic> st) {
    final show = Map<String, dynamic>.from(st['show'] as Map);
    final limit = (show['limit_ms'] as num).toDouble();
    final rem = (show['remaining_ms'] as num).toDouble();
    final f = (rem / limit).clamp(0.0, 1.0);
    final idx = (show['index'] as num).toInt();
    final key = ValueKey('card${st['round']}-$idx');
    return Column(
      children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _next,
            onHorizontalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) < -150) _next();
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 6, 22, 8),
              child: Center(
                child: TweenAnimationBuilder<double>(
                  key: key,
                  tween: Tween(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 360),
                  curve: Curves.easeOutCubic,
                  builder: (context, t, child) => Opacity(
                    opacity: t,
                    child: Transform.translate(
                      offset: Offset(46 * (1 - t), 10 * (1 - t)),
                      child: Transform.scale(scale: 0.92 + 0.08 * t, child: child),
                    ),
                  ),
                  child: _itemCard(show, f, idx < 2),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
          child: SizedBox(
            width: double.infinity,
            child: Center(child: GoldButton('Yerleştir', icon: Icons.arrow_forward_rounded, onPressed: _next)),
          ),
        ),
      ],
    );
  }

  Widget _itemCard(Map<String, dynamic> show, double f, bool tip) {
    final item = show['item'] as String? ?? '';
    final low = f < 0.25;
    return LuxCard(
      highlight: true,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(Lux.upper('Durak ${show['number']} · ${show['station']}'),
              textAlign: TextAlign.center, style: Lux.ui(13, color: Lux.gold, spacing: 2, weight: FontWeight.w700)),
          const SizedBox(height: 16),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: FoilText(Lux.upper(item), style: Lux.display(54, spacing: 2)),
          ),
          const SizedBox(height: 14),
          Text(
            tip ? 'Eşyayı durakla etkileştir: canlı, tuhaf, hareketli bir sahne kur.' : 'Sahneyi gör, sesini duy, sonra yerleştir.',
            textAlign: TextAlign.center,
            style: Lux.ui(13.5, color: Lux.muted),
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 5,
              child: Stack(children: [
                const Positioned.fill(child: ColoredBox(color: Color(0xFF0A2219))),
                FractionallySizedBox(
                  widthFactor: f,
                  child: DecoratedBox(
                    decoration: BoxDecoration(gradient: low ? null : Lux.goldGradient, color: low ? Lux.bordeauxLight : null),
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: Text('${((show['remaining_ms'] as num) / 1000).ceil()} sn',
                style: Lux.ui(12, color: low ? Lux.bordeauxLight : Lux.muted)),
          ),
        ],
      ),
    );
  }

  /// Gold chip flying from the card onto its station (first 0.42 s of the placing animation).
  Widget _flyChip(double now, Offset from, Rect band) {
    final t = Curves.easeInOutCubic.transform(((now - _flyAt) / 0.42).clamp(0.0, 1.0));
    final to = band.topLeft + _PathPainter.nodePos(band.size, _flyIdx, _focus);
    final p = Offset.lerp(from, to, t)! + Offset(0, -60 * math.sin(math.pi * t));
    final scale = 1.0 - 0.7 * t;
    return CustomPaint(
      painter: _ChipPainter(center: p, scale: scale, label: Lux.upper(_flyWord), opacity: 1 - 0.3 * t),
    );
  }

  // ------------------------------------------------------------------ recall

  Widget _probeHeader(Map<String, dynamic> probe) {
    return TweenAnimationBuilder<double>(
      key: ValueKey('probe${probe['pos']}-${probe['station_index']}'),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(opacity: t, child: Transform.translate(offset: Offset(0, 8 * (1 - t)), child: child)),
      child: Column(
        children: [
          Text(Lux.upper('Durak ${probe['number']}'), style: Lux.ui(12.5, color: Lux.gold, spacing: 2.4, weight: FontWeight.w700)),
          const SizedBox(height: 4),
          FittedBox(fit: BoxFit.scaleDown, child: Text(probe['station'] as String, style: Lux.display(30, color: Lux.ink))),
          const SizedBox(height: 4),
          Text('Burada ne vardı?', style: Lux.ui(14.5, color: Lux.muted)),
        ],
      ),
    );
  }

  Widget _feedbackBanner(Map<String, dynamic> st) {
    final last = st['last'] is Map ? Map<String, dynamic>.from(st['last'] as Map) : null;
    if (last == null) return const SizedBox(height: 40);
    final ok = last['correct'] == true;
    final skipped = last['skipped'] == true;
    final answer = Lux.upper(last['answer'] as String? ?? '');
    final text = ok
        ? '${last['number']}. durak · $answer ✓'
        : skipped
            ? '${last['number']}. durakta $answer vardı'
            : '${Lux.upper(last['given'] as String? ?? '')} değil · ${last['number']}. durakta $answer vardı';
    return SizedBox(
      height: 40,
      child: TweenAnimationBuilder<double>(
        key: ValueKey('fb${last['serial']}'),
        tween: Tween(begin: 0, end: 1),
        duration: Duration(milliseconds: ok ? 1300 : 2600),
        builder: (context, t, _) {
          final c = ok ? Lux.gold : Lux.bordeaux;
          final fin = Curves.easeOutBack.transform((t * 5).clamp(0.0, 1.0));
          final out = t < 0.8 ? 1.0 : 1 - (t - 0.8) / 0.2;
          return Opacity(
            opacity: (out * (ok ? 1 : 0.55 + 0.45 * out)).clamp(0.0, 1.0),
            child: Transform.scale(
              scale: 0.9 + 0.1 * fin,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    color: c.withValues(alpha: 0.16),
                    border: Border.all(color: c.withValues(alpha: 0.8)),
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(text,
                        maxLines: 1, style: Lux.ui(15, color: ok ? Lux.goldLight : const Color(0xFFFFD6DF), weight: FontWeight.w700)),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _gridBody(Map<String, dynamic> st) {
    final probe = Map<String, dynamic>.from(st['probe'] as Map);
    final cands = (probe['candidates'] as List?)?.cast<String>() ?? const <String>[];
    final cols = cands.length >= 9 ? 3 : 2;
    final rows = (cands.length / cols).ceil();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      child: Column(
        children: [
          _probeHeader(probe),
          const SizedBox(height: 6),
          _feedbackBanner(st),
          const SizedBox(height: 6),
          Expanded(
            child: LayoutBuilder(builder: (context, box) {
              final cellH = ((box.maxHeight - 52 - rows * 8) / rows).clamp(36.0, 66.0);
              return Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  for (var r = 0; r < rows; r++)
                    Row(
                      children: [
                        for (var c = 0; c < cols; c++)
                          Expanded(
                            child: r * cols + c < cands.length
                                ? _Choice(
                                    key: ValueKey('c${probe['pos']}-${r * cols + c}'),
                                    label: Lux.upper(cands[r * cols + c]),
                                    height: cellH,
                                    small: cols == 3,
                                    onTap: () => _pick(r * cols + c),
                                  )
                                : const SizedBox(),
                          ),
                      ],
                    ),
                  const SizedBox(height: 4),
                  TextButton(
                    onPressed: _skip,
                    child: Text('Hatırlamıyorum', style: Lux.ui(14, color: Lux.muted)),
                  ),
                ],
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _typedBody(Map<String, dynamic> st) {
    final probe = Map<String, dynamic>.from(st['probe'] as Map);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
      child: Column(
        children: [
          _probeHeader(probe),
          const SizedBox(height: 6),
          _feedbackBanner(st),
          const Spacer(),
          Container(
            constraints: const BoxConstraints(minWidth: 220, minHeight: 54),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: const Color(0xFF07261C),
              border: Border.all(color: Lux.gold.withValues(alpha: 0.6), width: 1.3),
              boxShadow: [BoxShadow(color: Lux.gold.withValues(alpha: 0.12), blurRadius: 16)],
            ),
            child: Center(
              widthFactor: 1,
              child: Text(_typed.isEmpty ? '…' : Lux.upper(_typed),
                  style: Lux.ui(28, color: _typed.isEmpty ? Lux.muted : Lux.ink, weight: FontWeight.w700, spacing: 1.5)),
            ),
          ),
          const Spacer(),
          _TrKeyboard(onKey: _typeKey, onSkip: _skip, onSubmit: _submitTyped, canSubmit: _typed.trim().isNotEmpty),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ overlays

  Widget _card(Map<String, dynamic> st, String phase) {
    final clear = phase == 'clear';
    final rc = (st['round_correct'] as List?)?.cast<num>() ?? const <num>[];
    final len = (st['list_len'] as num?)?.toInt() ?? 0;
    final heading = clear ? 'Sarayı temizle' : '${st['palace']} sarayı';
    final body = clear
        ? '1. liste: ${rc.isEmpty ? 0 : rc[0]}/$len doğru.\n\n'
            'Şimdi eski eşyaları sil: her durağı boş, temiz ve aydınlık gör; eski sahneyi bir rüzgâr süpürsün. '
            'Yeni liste aynı duraklara gelecek, eskisi tuzak olarak karşına çıkacak.'
        : st['brief'] as String? ?? '';
    return TweenAnimationBuilder<double>(
      key: ValueKey('card$phase'),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => ColoredBox(
        color: Colors.black.withValues(alpha: 0.5 * t),
        child: Opacity(opacity: t, child: Transform.scale(scale: 0.95 + 0.05 * t, child: child)),
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: LuxCard(
            highlight: true,
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(Lux.upper(heading), textAlign: TextAlign.center, style: Lux.display(22, spacing: 1.5)),
                const SizedBox(height: 14),
                Text(body, textAlign: TextAlign.center, style: Lux.ui(16, weight: FontWeight.w500)),
                if (!clear) ...[
                  const SizedBox(height: 10),
                  Text(st['goal'] as String? ?? '', textAlign: TextAlign.center, style: Lux.ui(14, color: Lux.muted)),
                ],
                const SizedBox(height: 18),
                GoldButton(clear ? 'Temizledim' : 'Başla',
                    icon: clear ? Icons.auto_awesome_rounded : Icons.play_arrow_rounded, onPressed: () {
                  HapticFeedback.selectionClick();
                  s.act({'start': true});
                }),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _countdown(Map<String, dynamic> st) {
    final ms = (st['countdown_ms'] as num?)?.toDouble() ?? 0;
    final k = (ms / 1000).ceil().clamp(1, 3);
    final p = ((k * 1000 - ms) / 1000).clamp(0.0, 1.0);
    final inT = Curves.easeOutBack.transform((p / 0.22).clamp(0.0, 1.0));
    final outT = Curves.easeInCubic.transform(((p - 0.62) / 0.38).clamp(0.0, 1.0));
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.35 * (k == 1 ? 1 - outT : 1.0)),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Yürüyüş başlıyor', style: Lux.ui(15, color: Lux.muted, spacing: 1.2)),
            const SizedBox(height: 8),
            Transform.scale(
              scale: (0.55 + 0.45 * inT) * (1 + 0.5 * outT),
              child: Opacity(
                opacity: ((p / 0.12).clamp(0.0, 1.0) * (1 - outT)).toDouble(),
                child: Text('$k', style: Lux.display(100, color: Lux.goldLight)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The lit path of stations. Nodes sit on a gentle wave; the camera ([focus]) keeps the current
/// station centred. Walked stations glow gold, answered ones green / bordeaux; the path fades out at
/// both edges.
class _PathPainter extends CustomPainter {
  final List<String> stations;
  final List<String> marks;
  final double focus;
  final int current;
  final double now;
  final double flashAt;
  final bool flashOk;
  final int flashIdx;
  final double ringAt;
  final int ringIdx;
  final bool dim;
  _PathPainter({
    required this.stations,
    required this.marks,
    required this.focus,
    required this.current,
    required this.now,
    required this.flashAt,
    required this.flashOk,
    required this.flashIdx,
    required this.ringAt,
    required this.ringIdx,
    required this.dim,
  });

  static double gap(Size size) => size.width / 4.2;

  static Offset nodePos(Size size, int i, double focus) =>
      Offset(size.width / 2 + (i - focus) * gap(size), size.height * 0.5 + size.height * 0.14 * math.sin(i * 1.15));

  @override
  void paint(Canvas canvas, Size size) {
    final n = stations.length;
    if (n == 0) return;
    final rect = Offset.zero & size;
    canvas.saveLayer(rect, Paint());
    final lo = math.max(0, (focus - 3.2).floor());
    final hi = math.min(n - 1, (focus + 3.2).ceil());

    // Path: smooth curve through node centres (midpoint quadratic spline).
    final pts = [for (var i = math.max(0, lo - 1); i <= math.min(n - 1, hi + 1); i++) nodePos(size, i, focus)];
    final first = math.max(0, lo - 1);
    if (pts.length >= 2) {
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (var k = 1; k < pts.length - 1; k++) {
        final mid = Offset.lerp(pts[k], pts[k + 1], 0.5)!;
        path.quadraticBezierTo(pts[k].dx, pts[k].dy, mid.dx, mid.dy);
      }
      path.lineTo(pts.last.dx, pts.last.dy);
      final a = dim ? 0.35 : 1.0;
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 16
            ..strokeCap = StrokeCap.round
            ..color = Lux.gold.withValues(alpha: 0.07 * a)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = Lux.gold.withValues(alpha: 0.42 * a));
      // Walked part brighter: from the first node to the focus.
      if (current >= 0) {
        final walked = Path()..moveTo(pts.first.dx, pts.first.dy);
        final upto = (current - first).clamp(0, pts.length - 1);
        for (var k = 1; k <= upto; k++) {
          walked.lineTo(pts[k].dx, pts[k].dy);
        }
        if (upto > 0) {
          canvas.drawPath(
              walked,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 3
                ..strokeCap = StrokeCap.round
                ..color = Lux.goldLight.withValues(alpha: 0.35 * a)
                ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2));
        }
      }
    }

    for (var i = lo; i <= hi; i++) {
      final c = nodePos(size, i, focus);
      final mark = i < marks.length ? marks[i] : '';
      final isCur = i == current;
      final dist = (i - focus).abs();
      final near = (1 - dist / 3.4).clamp(0.0, 1.0);
      final r = isCur ? 13.0 : 8.0;
      Color fill;
      switch (mark) {
        case 'ok':
          fill = Lux.good;
        case 'bad':
          fill = Lux.bordeauxLight;
        case 'placed':
          fill = Lux.gold;
        default:
          fill = const Color(0xFF0B3A2E);
      }
      if (isCur) {
        final breathe = 0.75 + 0.25 * math.sin(now * 3.2);
        canvas.drawCircle(c, r * 2.6,
            Paint()
              ..shader = RadialGradient(colors: [
                Lux.gold.withValues(alpha: 0.42 * breathe),
                Lux.gold.withValues(alpha: 0),
              ]).createShader(Rect.fromCircle(center: c, radius: r * 2.6)));
        fill = mark == '' ? Lux.gold : fill;
      }
      // Recall flash on the answered node.
      if (i == flashIdx && now - flashAt < 0.9) {
        final ft = (now - flashAt) / 0.9;
        final fc = flashOk ? Lux.good : Lux.bordeauxLight;
        canvas.drawCircle(c, r + 4 + 18 * ft,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.5 * (1 - ft)
              ..color = fc.withValues(alpha: 0.8 * (1 - ft)));
      }
      // Placing ring when the flying chip lands.
      if (i == ringIdx && now >= ringAt && now - ringAt < 0.5) {
        final rt = (now - ringAt) / 0.5;
        canvas.drawCircle(c, r + 2 + 22 * Curves.easeOutCubic.transform(rt),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.2 * (1 - rt)
              ..color = Lux.goldLight.withValues(alpha: 0.9 * (1 - rt)));
      }
      canvas.drawCircle(c.translate(0, 2), r, Paint()..color = Colors.black.withValues(alpha: 0.4));
      canvas.drawCircle(
          c,
          r,
          Paint()
            ..shader = RadialGradient(
              center: const Alignment(-0.35, -0.4),
              colors: [Color.lerp(fill, Colors.white, 0.45)!, fill, Color.lerp(fill, Colors.black, 0.55)!],
              stops: const [0, 0.5, 1],
            ).createShader(Rect.fromCircle(center: c, radius: r)));
      canvas.drawCircle(
          c,
          r - 0.5,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = Lux.goldLight.withValues(alpha: isCur ? 0.9 : 0.45));
      // Number inside / label beside.
      final numTp = TextPainter(
        text: TextSpan(
            text: '${i + 1}',
            style: Lux.ui(isCur ? 11.5 : 8.5, color: mark == '' && !isCur ? Lux.muted : const Color(0xFF1A1206), weight: FontWeight.w700)),
        textDirection: TextDirection.ltr,
      )..layout();
      numTp.paint(canvas, c - Offset(numTp.width / 2, numTp.height / 2));
      final below = math.sin(i * 1.15) >= 0;
      final maxW = gap(size) * 0.92;
      final tp = TextPainter(
        text: TextSpan(
          text: stations[i],
          style: Lux.ui(isCur ? 14 : 11.5,
              color: isCur ? Lux.goldLight : Lux.ink.withValues(alpha: 0.35 + 0.45 * near), weight: isCur ? FontWeight.w700 : FontWeight.w500),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
        maxLines: 2,
        ellipsis: '…',
      )..layout(maxWidth: isCur ? maxW * 1.35 : maxW);
      final ly = below ? c.dy + r + 6 : c.dy - r - 6 - tp.height;
      tp.paint(canvas, Offset(c.dx - tp.width / 2, ly));
    }

    // Edge fade.
    canvas.drawRect(
        rect,
        Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = const LinearGradient(
            colors: [Color(0x00000000), Color(0xFF000000), Color(0xFF000000), Color(0x00000000)],
            stops: [0, 0.16, 0.84, 1],
          ).createShader(rect));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PathPainter old) => true;
}

/// The small gold chip that carries a placed item onto its station.
class _ChipPainter extends CustomPainter {
  final Offset center;
  final double scale;
  final String label;
  final double opacity;
  _ChipPainter({required this.center, required this.scale, required this.label, required this.opacity});

  @override
  void paint(Canvas canvas, Size size) {
    final tp = TextPainter(
      text: TextSpan(text: label, style: Lux.ui(18 * scale + 4, color: const Color(0xFF1A1206), weight: FontWeight.w700)),
      textDirection: TextDirection.ltr,
    )..layout();
    final w = tp.width + 26 * scale + 8;
    final h = tp.height + 12 * scale + 4;
    final r = RRect.fromRectAndRadius(Rect.fromCenter(center: center, width: w, height: h), Radius.circular(h / 2));
    canvas.drawRRect(r.shift(const Offset(0, 3)),
        Paint()..color = Colors.black.withValues(alpha: 0.35 * opacity)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    canvas.drawRRect(
        r,
        Paint()
          ..shader = LinearGradient(colors: Lux.foil.colors.map((c) => c.withValues(alpha: opacity)).toList(), stops: Lux.foil.stops)
              .createShader(r.outerRect));
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_ChipPainter old) => true;
}

/// Candidate button: velvet tile with a gold rim; sinks on touch.
class _Choice extends StatefulWidget {
  final String label;
  final double height;
  final bool small;
  final VoidCallback onTap;
  const _Choice({super.key, required this.label, required this.height, required this.onTap, this.small = false});

  @override
  State<_Choice> createState() => _ChoiceState();
}

class _ChoiceState extends State<_Choice> with SingleTickerProviderStateMixin {
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 80),
    reverseDuration: const Duration(milliseconds: 170),
  );

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(4),
      child: AnimatedBuilder(
        animation: _press,
        builder: (context, child) => Transform.scale(scale: 1 - 0.05 * _press.value, child: child),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            splashColor: Lux.gold.withValues(alpha: 0.2),
            onTapDown: (_) => _press.forward(),
            onTapUp: (_) => _press.forward().whenComplete(() {
              if (mounted) _press.reverse();
            }),
            onTapCancel: () => _press.reverse(),
            onTap: widget.onTap,
            child: Ink(
              height: widget.height,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF13402F), Color(0xFF07261C)],
                ),
                border: Border.all(color: Lux.gold.withValues(alpha: 0.45)),
              ),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(widget.label,
                        maxLines: 1, style: Lux.ui(widget.small ? 15 : 17, color: Lux.ink, weight: FontWeight.w700, spacing: 0.8)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Big Turkish keyboard (Q layout without Q/W/X, which Turkish words never need).
class _TrKeyboard extends StatelessWidget {
  final void Function(String) onKey;
  final VoidCallback onSkip;
  final VoidCallback onSubmit;
  final bool canSubmit;
  const _TrKeyboard({required this.onKey, required this.onSkip, required this.onSubmit, required this.canSubmit});

  static const _rows = [
    ['E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', 'Ğ', 'Ü'],
    ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', 'Ş', 'İ'],
    ['Z', 'C', 'V', 'B', 'N', 'M', 'Ö', 'Ç', '⌫'],
  ];

  /// Turkish lowercase of one key.
  static String _lower(String k) => switch (k) { 'I' => 'ı', 'İ' => 'i', _ => k.toLowerCase() };

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final r in _rows)
          Row(
            children: [
              for (final k in r)
                Expanded(
                  flex: k == '⌫' ? 2 : 1,
                  child: _TKey(label: k, onTap: () => onKey(k == '⌫' ? k : _lower(k))),
                ),
            ],
          ),
        Row(
          children: [
            Expanded(flex: 3, child: _TKey(label: 'Bilmiyorum', small: true, onTap: onSkip)),
            Expanded(flex: 4, child: _TKey(label: 'boşluk', small: true, onTap: () => onKey(' '))),
            Expanded(flex: 3, child: _TKey(label: 'Tamam', small: true, primary: canSubmit, onTap: onSubmit)),
          ],
        ),
      ],
    );
  }
}

class _TKey extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool small;
  final bool primary;
  const _TKey({required this.label, required this.onTap, this.small = false, this.primary = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(2.5),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          splashColor: Lux.gold.withValues(alpha: 0.25),
          onTap: onTap,
          child: Ink(
            height: 50,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              gradient: primary
                  ? Lux.goldGradient
                  : const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFF13402F), Color(0xFF07261C)],
                    ),
              border: Border.all(color: primary ? Colors.transparent : Lux.line),
            ),
            child: Center(
              child: label == '⌫'
                  ? const Icon(Icons.backspace_outlined, color: Lux.gold, size: 20)
                  : FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(label,
                          style: Lux.ui(small ? 14 : 19, color: primary ? const Color(0xFF1A1206) : Lux.ink, weight: FontWeight.w700)),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
