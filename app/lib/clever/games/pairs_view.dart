import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// Eşleştirme board: a grid of velvet-backed cards with original glyph faces (jewel cuts, moons,
/// stars, constellations) painted in Lux jewel tones. Rules, timing and scoring live in Rust.
///
/// Motion: each card turns over in 3D (Matrix4.rotateY with perspective, 260 ms) and rises a little
/// mid-turn; a found group glows gold, lifts and settles with a spring; a mismatch gives a short
/// bordeaux shake before the core turns the cards back. Shuffles glide the swapped cards to their new
/// slots (raised and gold-rimmed so you can follow them). Winning sends a lift wave over the board.
Widget pairsView(BuildContext context, GameSession s) => _PairsBoard(key: ObjectKey(s), session: s);

/// Jewel palette for card faces (index from Rust, 0..7). Our own tones, tuned to stay apart.
const _jewels = [
  Color(0xFFD9425F), // ruby
  Color(0xFF4F86EA), // sapphire
  Color(0xFF3ECF86), // emerald
  Color(0xFFA56BE0), // amethyst
  Color(0xFFEBC24D), // citrine
  Color(0xFFE5873A), // topaz
  Color(0xFF43C9D4), // aquamarine
  Color(0xFFEFE8D6), // pearl
];

const _cardAspect = 0.76; // width / height

class _Face {
  final int shape, color, detail;
  const _Face(this.shape, this.color, this.detail);
  @override
  bool operator ==(Object o) => o is _Face && o.shape == shape && o.color == color && o.detail == detail;
  @override
  int get hashCode => Object.hash(shape, color, detail);
}

class _PairsBoard extends StatefulWidget {
  final GameSession session;
  const _PairsBoard({super.key, required this.session});

  @override
  State<_PairsBoard> createState() => _PairsBoardState();
}

class _PairsBoardState extends State<_PairsBoard> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  double _playAcc = 0;
  final Map<int, _Face> _faces = {};
  int _matchSerial = 0, _missSerial = 0, _shuffleSerial = 0;
  bool _wonSeen = false;

  GameSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    final st = s.state;
    _matchSerial = (st['match_serial'] as num?)?.toInt() ?? 0;
    _missSerial = (st['miss_serial'] as num?)?.toInt() ?? 0;
    _shuffleSerial = (st['shuffle_serial'] as num?)?.toInt() ?? 0;
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1000.0;
    _lastTick = elapsed;
    if (s.finished) return;
    final phase = s.state['phase'];
    if (phase == 'preview' || phase == 'look' || phase == 'shuffle') {
      if (_playAcc > 0) {
        s.tick(_playAcc);
        _playAcc = 0;
      }
      s.tick(dt);
    } else if (phase == 'play') {
      // Only the clock runs while it's your move: batch it so the board isn't rebuilt every frame.
      _playAcc += dt;
      if (_playAcc >= 500) {
        s.tick(_playAcc);
        _playAcc = 0;
      }
    }
  }

  void _sync(Map<String, dynamic> st) {
    final ms = (st['match_serial'] as num?)?.toInt() ?? 0;
    if (ms != _matchSerial) {
      _matchSerial = ms;
      HapticFeedback.lightImpact();
    }
    final mi = (st['miss_serial'] as num?)?.toInt() ?? 0;
    if (mi != _missSerial) {
      _missSerial = mi;
      HapticFeedback.mediumImpact();
    }
    final sh = (st['shuffle_serial'] as num?)?.toInt() ?? 0;
    if (sh != _shuffleSerial) {
      _shuffleSerial = sh;
      HapticFeedback.selectionClick();
    }
    if (st['status'] == 'won' && !_wonSeen) {
      _wonSeen = true;
      HapticFeedback.heavyImpact();
    }
  }

  void _tap(int pos, Map<String, dynamic> card) {
    if (s.finished) return;
    if (card['matched'] == true || card['up'] == true) return;
    final phase = s.state['phase'];
    if (phase == 'look') {
      // Tapping on while a mismatch is showing turns it back at once, then flips the new card.
      s.act({'close': true});
    } else if (phase != 'play') {
      return;
    }
    if (s.state['phase'] != 'play') return; // e.g. the close triggered a shuffle
    if (_playAcc > 0) {
      s.tick(_playAcc);
      _playAcc = 0;
    }
    HapticFeedback.selectionClick();
    s.act({'flip': pos});
  }

  @override
  Widget build(BuildContext context) {
    final st = s.state;
    _sync(st);
    final cards = [for (final c in (st['cards'] as List? ?? const [])) Map<String, dynamic>.from(c as Map)];
    for (final c in cards) {
      final f = c['face'];
      if (f is Map) {
        _faces[(c['id'] as num).toInt()] =
            _Face((f['shape'] as num).toInt(), (f['color'] as num).toInt(), (f['detail'] as num).toInt());
      }
    }
    final phase = st['phase'] as String? ?? 'intro';
    return Stack(
      children: [
        Column(
          children: [
            _header(st, phase),
            Expanded(child: _grid(st, cards, phase)),
            const SizedBox(height: 18),
          ],
        ),
        if (phase == 'intro') Positioned.fill(child: _card(st)),
      ],
    );
  }

  // ------------------------------------------------------------------ header

  Widget _header(Map<String, dynamic> st, String phase) {
    final moves = (st['moves'] as num?)?.toInt() ?? 0;
    final three = (st['three_star'] as num?)?.toInt() ?? 0;
    final two = (st['two_star'] as num?)?.toInt() ?? 0;
    final limit = (st['limit'] as num?)?.toInt();
    final found = (st['found'] as num?)?.toInt() ?? 0;
    final groups = (st['groups'] as num?)?.toInt() ?? 0;
    final toShuffle = (st['moves_to_shuffle'] as num?)?.toInt();
    final group = (st['group'] as num?)?.toInt() ?? 2;
    final starsNow = moves <= three ? 3 : (moves <= two ? 2 : 1);
    final previewTotal = (st['preview_total'] as num?)?.toDouble() ?? 0;
    final previewLeft = (st['preview_ms'] as num?)?.toDouble() ?? 0;
    final nearLimit = limit != null && limit - moves <= 3;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 6),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(end: moves.toDouble()),
                duration: const Duration(milliseconds: 260),
                builder: (context, v, _) => FoilText('${v.round()}', style: Lux.numeral(44)),
              ),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(Lux.upper('hamle'), style: Lux.ui(13, color: Lux.gold, weight: FontWeight.w600, spacing: 2)),
              ),
              const SizedBox(width: 12),
              Padding(padding: const EdgeInsets.only(bottom: 8), child: StarRow(s.finished ? s.stars : starsNow, size: 16)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _line('$found / $groups ${group == 3 ? 'üçlü' : 'çift'}', Lux.ui(16, weight: FontWeight.w700)),
                    _line('3★ ≤ $three · 2★ ≤ $two', Lux.ui(12, color: Lux.muted)),
                    if (limit != null)
                      _line('Sınır: ${limit - moves} hamle kaldı',
                          Lux.ui(12, color: nearLimit ? Lux.bordeauxLight : Lux.muted, weight: nearLimit ? FontWeight.w700 : FontWeight.w500)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 22,
            child: phase == 'preview' && previewTotal > 0
                ? Row(
                    children: [
                      Text('Ezberle', style: Lux.ui(13, color: Lux.goldLight, weight: FontWeight.w600)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: SizedBox(
                            height: 5,
                            child: Stack(children: [
                              const Positioned.fill(child: ColoredBox(color: Color(0xFF2A2015))),
                              FractionallySizedBox(
                                widthFactor: (previewLeft / previewTotal).clamp(0.0, 1.0),
                                child: const DecoratedBox(decoration: BoxDecoration(gradient: Lux.goldGradient)),
                              ),
                            ]),
                          ),
                        ),
                      ),
                    ],
                  )
                : toShuffle != null
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: Row(
                          children: [
                            Icon(Icons.swap_horiz_rounded, size: 17, color: phase == 'shuffle' ? Lux.goldLight : Lux.muted),
                            const SizedBox(width: 6),
                            Text(
                              phase == 'shuffle' ? 'Kartlar yer değiştiriyor · takip et' : 'Karışmaya $toShuffle hamle',
                              style: Lux.ui(13, color: phase == 'shuffle' ? Lux.goldLight : (toShuffle <= 1 ? Lux.bordeauxLight : Lux.muted)),
                            ),
                          ],
                        ),
                      )
                    : const SizedBox(),
          ),
        ],
      ),
    );
  }

  Widget _line(String text, TextStyle style) =>
      Text(text, style: style, maxLines: 1, softWrap: false, overflow: TextOverflow.fade, textAlign: TextAlign.right);

  // ------------------------------------------------------------------ grid

  Widget _grid(Map<String, dynamic> st, List<Map<String, dynamic>> cards, String phase) {
    final cols = (st['cols'] as num?)?.toInt() ?? 3;
    final rows = (st['rows'] as num?)?.toInt() ?? 4;
    final lastMatch = [for (final p in (st['last_match'] as List? ?? const [])) (p as num).toInt()];
    final lastMiss = [for (final p in (st['last_miss'] as List? ?? const [])) (p as num).toInt()];
    final swapping = <int>{
      if (phase == 'shuffle')
        for (final sw in (st['swaps'] as List? ?? const [])) ...[((sw as List)[0] as num).toInt(), (sw[1] as num).toInt()]
    };
    final matchSerial = (st['match_serial'] as num?)?.toInt() ?? 0;
    final missSerial = (st['miss_serial'] as num?)?.toInt() ?? 0;
    final won = st['status'] == 'won';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: LayoutBuilder(builder: (context, box) {
        const gapFrac = 0.1;
        // Card width from both constraints (gap = 10% of a card's width).
        final byW = box.maxWidth / (cols + (cols + 1) * gapFrac);
        final byH = box.maxHeight / (rows / _cardAspect + (rows + 1) * gapFrac);
        final cw = math.min(byW, byH);
        final ch = cw / _cardAspect;
        final gap = cw * gapFrac;
        final gw = cols * cw + (cols + 1) * gap, gh = rows * ch + (rows + 1) * gap;
        final ox = (box.maxWidth - gw) / 2, oy = (box.maxHeight - gh) / 2;
        Offset at(int pos) => Offset(ox + gap + (pos % cols) * (cw + gap), oy + gap + (pos ~/ cols) * (ch + gap));

        final entries = <(int, Map<String, dynamic>)>[for (var p = 0; p < cards.length; p++) (p, cards[p])];
        // Swapping cards are painted last so they glide over the others.
        entries.sort((a, b) => (swapping.contains(a.$1) ? 1 : 0) - (swapping.contains(b.$1) ? 1 : 0));
        return Stack(
          clipBehavior: Clip.none,
          children: [
            for (final (pos, c) in entries)
              AnimatedPositioned(
                key: ValueKey('card${c['id']}'),
                duration: const Duration(milliseconds: 640),
                curve: Curves.easeInOutCubic,
                left: at(pos).dx,
                top: at(pos).dy,
                width: cw,
                height: ch,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (_) => _tap(pos, c),
                  child: _Card(
                    face: _faces[(c['id'] as num).toInt()],
                    // A lost board turns every card over so you can see what you missed.
                    up: c['up'] == true || st['status'] == 'lost',
                    matched: c['matched'] == true,
                    matchKey: lastMatch.contains(pos) ? matchSerial : -1,
                    missKey: lastMiss.contains(pos) && phase == 'look' ? missSerial : -1,
                    swapping: swapping.contains(pos),
                    winDelay: won ? (pos ~/ cols + pos % cols) * 45 : -1,
                  ),
                ),
              ),
          ],
        );
      }),
    );
  }

  // ------------------------------------------------------------------ intro

  Widget _card(Map<String, dynamic> st) {
    final cols = (st['cols'] as num?)?.toInt() ?? 3;
    final rows = (st['rows'] as num?)?.toInt() ?? 4;
    final group = (st['group'] as num?)?.toInt() ?? 2;
    final groups = (st['groups'] as num?)?.toInt() ?? 0;
    final preview = ((st['preview_total'] as num?)?.toDouble() ?? 0) / 1000;
    final conf = (st['confusable'] as num?)?.toInt() ?? 0;
    final every = (st['shuffle_every'] as num?)?.toInt() ?? 0;
    final limit = (st['limit'] as num?)?.toInt();
    final three = (st['three_star'] as num?)?.toInt() ?? 0;
    final two = (st['two_star'] as num?)?.toInt() ?? 0;
    final lines = <String>[
      group == 3
          ? 'Kartları tek tek çevir; aynı üç kartı bul. İkinci kart ilkini tutmazsa tur biter.'
          : 'Kartları ikişer ikişer çevir; aynı iki kartı bul. Tutmayan kartlar kısa bir bakıştan sonra kapanır.',
      if (preview > 0)
        'Başta bütün kartlar ${preview.toStringAsFixed(1).replaceAll('.', ',').replaceAll(',0', '')} sn açık kalacak: ezberle.',
      if (conf >= 2) 'Dikkat: bazı kartlar birbirine çok benziyor. Şekle de renge de bak.',
      if (conf >= 3) 'Köşedeki küçük yıldızın olup olmadığına da bak.',
      if (every > 0) 'Her $every hamlede bazı kapalı kartlar yer değiştirir. Kayan kartları gözünle takip et.',
      if (limit != null) 'Hamle sınırı: $limit. Sınır dolarsa bölüm biter.',
      '3 yıldız: en fazla $three hamle · 2 yıldız: en fazla $two hamle.',
    ];
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => ColoredBox(
        color: Colors.black.withValues(alpha: 0.55 * t),
        child: Opacity(opacity: t, child: Transform.scale(scale: 0.95 + 0.05 * t, child: child)),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: LuxCard(
            highlight: true,
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(Lux.upper('$cols×$rows · $groups ${group == 3 ? 'üçlü' : 'çift'}'),
                    textAlign: TextAlign.center, style: Lux.display(22, spacing: 1.5)),
                const SizedBox(height: 14),
                for (final l in lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(l, textAlign: TextAlign.center, style: Lux.ui(16, weight: FontWeight.w500)),
                  ),
                const SizedBox(height: 10),
                GoldButton('Başla', icon: Icons.play_arrow_rounded, onPressed: () {
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
}

/// One card: 3D flip, match lift, mismatch shake, shuffle lift and the win wave.
class _Card extends StatefulWidget {
  final _Face? face;
  final bool up, matched, swapping;
  final int matchKey, missKey, winDelay;
  const _Card({
    required this.face,
    required this.up,
    required this.matched,
    required this.matchKey,
    required this.missKey,
    required this.swapping,
    required this.winDelay,
  });

  @override
  State<_Card> createState() => _CardState();
}

class _CardState extends State<_Card> with TickerProviderStateMixin {
  late final AnimationController _flip =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 260), value: widget.up ? 1 : 0);
  late final AnimationController _lift = AnimationController(vsync: this, duration: const Duration(milliseconds: 720));
  late final AnimationController _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 380));
  late final AnimationController _raise = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));

  @override
  void didUpdateWidget(_Card old) {
    super.didUpdateWidget(old);
    if (widget.up != old.up) {
      _flip.animateTo(widget.up ? 1 : 0, curve: Curves.easeInOutCubic);
    }
    if (widget.matchKey >= 0 && widget.matchKey != old.matchKey && widget.matched) {
      // Let the last card finish turning before the pair lifts.
      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted) _lift.forward(from: 0);
      });
    }
    if (widget.missKey >= 0 && widget.missKey != old.missKey) {
      Future.delayed(const Duration(milliseconds: 240), () {
        if (mounted) _shake.forward(from: 0);
      });
    }
    if (widget.swapping != old.swapping) {
      widget.swapping ? _raise.forward() : _raise.reverse();
    }
    if (widget.winDelay >= 0 && old.winDelay < 0) {
      Future.delayed(Duration(milliseconds: 260 + widget.winDelay), () {
        if (mounted) _lift.forward(from: 0);
      });
    }
  }

  @override
  void dispose() {
    _flip.dispose();
    _lift.dispose();
    _shake.dispose();
    _raise.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_flip, _lift, _shake, _raise]),
      builder: (context, _) {
        final v = _flip.value;
        final angle = math.pi * v;
        final showFace = v > 0.5;
        final mid = math.sin(math.pi * v); // 0 at rest, 1 edge-on
        // Match lift: rise fast, settle with a spring.
        final l = _lift.value;
        final liftUp = l == 0 || l == 1 ? 0.0 : (l < 0.3 ? Curves.easeOut.transform(l / 0.3) : 1 - Curves.elasticOut.transform((l - 0.3) / 0.7));
        final raise = Curves.easeOut.transform(_raise.value);
        final scale = 1 + 0.05 * mid + 0.1 * liftUp.clamp(-0.3, 1.0) + 0.07 * raise;
        final dy = -8 * liftUp - 5 * raise - 3 * mid;
        final k = _shake.value;
        final dx = k == 0 || k == 1 ? 0.0 : math.sin(k * math.pi * 6) * 6 * (1 - k);
        final glow = widget.matched ? 0.35 + 0.65 * liftUp.clamp(0.0, 1.0) : 0.0;
        final miss = k > 0 && k < 1 ? 1 - k : 0.0;
        final m = Matrix4.identity()
          ..setEntry(3, 2, 0.0014)
          ..translateByDouble(dx, dy, 0, 1)
          ..scaleByDouble(scale, scale, 1, 1)
          ..rotateY(angle);
        return Transform(
          alignment: Alignment.center,
          transform: m,
          child: showFace
              ? Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.rotationY(math.pi),
                  child: CustomPaint(
                    painter: _FacePainter(widget.face, glow: glow, miss: miss, lifted: mid + liftUp.clamp(0.0, 1.0)),
                  ),
                )
              : CustomPaint(painter: _BackPainter(lifted: mid + raise, highlight: raise)),
        );
      },
    );
  }
}

/// Drop shadow shared by both sides; grows while the card is in the air.
void _shadow(Canvas canvas, RRect rr, double lifted) {
  canvas.drawRRect(
    rr.shift(Offset(0, 3 + 6 * lifted)),
    Paint()
      ..color = Colors.black.withValues(alpha: 0.5 - 0.15 * lifted.clamp(0.0, 1.0))
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4 + 6 * lifted),
  );
}

/// Card back: emerald velvet, gold double rim, a faint lozenge lattice and a gold rhomb medallion.
class _BackPainter extends CustomPainter {
  final double lifted, highlight;
  _BackPainter({required this.lifted, required this.highlight});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final r = size.width * 0.12;
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(r));
    _shadow(canvas, rr, lifted);
    canvas.drawRRect(
      rr,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1C6E54), Color(0xFF0B3D2E), Color(0xFF062519)],
          stops: [0, 0.55, 1],
        ).createShader(rect),
    );
    // Lattice.
    canvas.save();
    canvas.clipRRect(rr.deflate(size.width * 0.09));
    final lat = Paint()
      ..color = Lux.gold.withValues(alpha: 0.11)
      ..strokeWidth = 1;
    final step = size.width * 0.2;
    for (double x = -size.height; x < size.width + size.height; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x + size.height, size.height), lat);
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), lat);
    }
    canvas.restore();
    // Medallion.
    final c = rect.center;
    final m = size.width * 0.17;
    final rh = Path()
      ..moveTo(c.dx, c.dy - m * 1.3)
      ..lineTo(c.dx + m, c.dy)
      ..lineTo(c.dx, c.dy + m * 1.3)
      ..lineTo(c.dx - m, c.dy)
      ..close();
    canvas.drawPath(rh, Paint()..shader = Lux.foil.createShader(rh.getBounds()));
    canvas.drawPath(
      rh,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0xFF5A4413),
    );
    canvas.drawCircle(c, m * 0.28, Paint()..color = const Color(0xFF0B3D2E));
    // Rims.
    final rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3 + 1.2 * highlight
      ..color = Color.lerp(Lux.gold.withValues(alpha: 0.75), Lux.goldLight, highlight)!;
    canvas.drawRRect(rr.deflate(0.7), rim);
    canvas.drawRRect(
      rr.deflate(size.width * 0.055),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = Lux.gold.withValues(alpha: 0.3),
    );
    if (highlight > 0) {
      canvas.drawRRect(
        rr.inflate(2),
        Paint()
          ..color = Lux.gold.withValues(alpha: 0.35 * highlight)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
    }
  }

  @override
  bool shouldRepaint(_BackPainter old) => old.lifted != lifted || old.highlight != highlight;
}

/// Card face: dark onyx panel with a gold rim and one original glyph in a jewel tone.
class _FacePainter extends CustomPainter {
  final _Face? face;
  final double glow, miss, lifted;
  _FacePainter(this.face, {required this.glow, required this.miss, required this.lifted});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(size.width * 0.12));
    if (glow > 0) {
      canvas.drawRRect(
        rr.inflate(3),
        Paint()
          ..color = Lux.gold.withValues(alpha: 0.55 * glow)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6 + 8 * glow),
      );
    }
    _shadow(canvas, rr, lifted);
    canvas.drawRRect(
      rr,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.3, -0.45),
          radius: 1.2,
          colors: [Color(0xFF1E2A26), Color(0xFF0D1412), Color(0xFF070B0A)],
          stops: [0, 0.6, 1],
        ).createShader(rect),
    );
    final f = face;
    if (f != null) {
      final color = _jewels[f.color % _jewels.length];
      final c = Offset(size.width / 2, size.height / 2);
      final r = size.width * 0.33;
      _Glyphs.draw(canvas, f.shape, c, r, color);
      if (f.detail > 0) {
        final sr = size.width * 0.075;
        _Glyphs.sparkle(canvas, Offset(size.width * 0.8, size.height * 0.15), sr, Lux.goldLight);
        if (f.detail > 1) _Glyphs.sparkle(canvas, Offset(size.width * 0.2, size.height * 0.85), sr, Lux.goldLight);
      }
    }
    final rimColor = miss > 0
        ? Color.lerp(Lux.gold, Lux.bordeauxLight, miss)!
        : Color.lerp(Lux.gold.withValues(alpha: 0.7), Lux.goldLight, glow)!;
    canvas.drawRRect(rr.deflate(0.7), Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4 + 1.2 * math.max(glow, miss)
      ..color = rimColor);
    canvas.drawRRect(
      rr.deflate(size.width * 0.055),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = Lux.gold.withValues(alpha: 0.22),
    );
  }

  @override
  bool shouldRepaint(_FacePainter old) =>
      old.face != face || old.glow != glow || old.miss != miss || old.lifted != lifted;
}

/// Twelve original glyphs: jewel cuts, celestial shapes and two constellations.
class _Glyphs {
  static void draw(Canvas canvas, int shape, Offset c, double r, Color color) {
    switch (shape % 12) {
      case 0:
        _brilliant(canvas, c, r, color);
      case 1:
        _poly(canvas, c, color, const [Offset(0, -1.15), Offset(0.78, -0.25), Offset(0, 1.15), Offset(-0.78, -0.25)], r,
            facets: true);
      case 2:
        _poly(canvas, c, color, [for (var i = 0; i < 6; i++) _polar(i * math.pi / 3 - math.pi / 2, 1.0)], r, table: 0.55);
      case 3:
        _poly(canvas, c, color, const [
          Offset(-0.45, -0.95), Offset(0.45, -0.95), Offset(0.75, -0.65), Offset(0.75, 0.65),
          Offset(0.45, 0.95), Offset(-0.45, 0.95), Offset(-0.75, 0.65), Offset(-0.75, -0.65),
        ], r, table: 0.6);
      case 4:
        _drop(canvas, c, r, color);
      case 5:
        _poly(canvas, c, color,
            [for (var i = 0; i < 10; i++) _polar(i * math.pi / 5 - math.pi / 2, i.isEven ? 1.08 : 0.46)], r);
      case 6:
        _crescent(canvas, c, r, color);
      case 7:
        _poly(canvas, c, color, [_polar(-math.pi / 2, 1.1), _polar(math.pi / 6, 1.1), _polar(5 * math.pi / 6, 1.1)],
            r.toDouble(), table: 0.45, offset: Offset(0, r * 0.12));
      case 8:
        _constellation(canvas, c, r, color, const [
          Offset(-0.95, -0.35), Offset(-0.45, 0.45), Offset(0.0, -0.15), Offset(0.45, 0.5), Offset(0.95, -0.4),
        ], const [(0, 1), (1, 2), (2, 3), (3, 4)]);
      case 9:
        _constellation(canvas, c, r, color, const [
          Offset(0, -1.0), Offset(0.8, -0.05), Offset(0.25, 0.95), Offset(-0.7, 0.55), Offset(-0.15, -0.05),
        ], const [(0, 1), (1, 2), (2, 3), (3, 0), (0, 4), (4, 2)]);
      case 10:
        _planet(canvas, c, r, color);
      default:
        _compass(canvas, c, r, color);
    }
  }

  static Offset _polar(double a, double d) => Offset(math.cos(a) * d, math.sin(a) * d);

  static Paint _body(Color color, Rect bounds) => Paint()
    ..shader = RadialGradient(
      center: const Alignment(-0.35, -0.45),
      radius: 1.05,
      colors: [Color.lerp(color, Colors.white, 0.55)!, color, Color.lerp(color, Colors.black, 0.55)!],
      stops: const [0, 0.5, 1],
    ).createShader(bounds);

  static void _halo(Canvas canvas, Path p, Color color) {
    canvas.drawPath(p, Paint()..color = color.withValues(alpha: 0.28)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7));
  }

  static void _finish(Canvas canvas, Path p, Color color) {
    canvas.drawPath(
      p,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeJoin = StrokeJoin.round
        ..color = Color.lerp(color, Colors.white, 0.6)!.withValues(alpha: 0.75),
    );
    final b = p.getBounds();
    canvas.save();
    canvas.clipPath(p);
    canvas.drawOval(
      Rect.fromCenter(center: b.topLeft + Offset(b.width * 0.33, b.height * 0.27), width: b.width * 0.42, height: b.height * 0.2),
      Paint()..color = Colors.white.withValues(alpha: 0.38)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
    );
    canvas.restore();
  }

  static void _poly(Canvas canvas, Offset c, Color color, List<Offset> pts, double r,
      {double table = 0, bool facets = false, Offset offset = Offset.zero}) {
    final o = c + offset;
    final path = Path()..addPolygon([for (final p in pts) o + p * r], true);
    _halo(canvas, path, color);
    canvas.drawPath(path, _body(color, path.getBounds()));
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9
      ..color = Colors.black.withValues(alpha: 0.28);
    if (table > 0) {
      final inner = [for (final p in pts) o + p * r * table];
      canvas.drawPath(Path()..addPolygon(inner, true), line);
      for (var i = 0; i < pts.length; i++) {
        canvas.drawLine(o + pts[i] * r, inner[i], line);
      }
    }
    if (facets) {
      for (final p in pts) {
        canvas.drawLine(o, o + p * r, line);
      }
      canvas.drawLine(o + pts[1] * r, o + pts[3] * r, line);
    }
    _finish(canvas, path, color);
  }

  static void _brilliant(Canvas canvas, Offset c, double r, Color color) {
    final path = Path()..addOval(Rect.fromCircle(center: c, radius: r));
    _halo(canvas, path, color);
    canvas.drawPath(path, _body(color, path.getBounds()));
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9
      ..color = Colors.black.withValues(alpha: 0.26);
    final table = [for (var i = 0; i < 8; i++) c + _polar(i * math.pi / 4 + math.pi / 8, r * 0.48)];
    canvas.drawPath(Path()..addPolygon(table, true), line);
    for (var i = 0; i < 8; i++) {
      canvas.drawLine(table[i], c + _polar(i * math.pi / 4 + math.pi / 8 + math.pi / 8, r), line);
      canvas.drawLine(table[i], c + _polar(i * math.pi / 4, r), line);
    }
    _finish(canvas, path, color);
  }

  static void _drop(Canvas canvas, Offset c, double r, Color color) {
    final top = c + Offset(0, -r * 1.15);
    final path = Path()
      ..moveTo(top.dx, top.dy)
      ..cubicTo(c.dx + r * 0.35, c.dy - r * 0.55, c.dx + r * 0.9, c.dy + r * 0.05, c.dx + r * 0.85, c.dy + r * 0.38)
      ..arcToPoint(Offset(c.dx - r * 0.85, c.dy + r * 0.38), radius: Radius.circular(r * 0.86), clockwise: true)
      ..cubicTo(c.dx - r * 0.9, c.dy + r * 0.05, c.dx - r * 0.35, c.dy - r * 0.55, top.dx, top.dy)
      ..close();
    _halo(canvas, path, color);
    canvas.drawPath(path, _body(color, path.getBounds()));
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9
      ..color = Colors.black.withValues(alpha: 0.26);
    final inner = Rect.fromCenter(center: c + Offset(0, r * 0.3), width: r * 0.9, height: r * 0.7);
    canvas.drawOval(inner, line);
    canvas.drawLine(top, inner.topCenter, line);
    _finish(canvas, path, color);
  }

  static void _crescent(Canvas canvas, Offset c, double r, Color color) {
    final outer = Path()..addOval(Rect.fromCircle(center: c, radius: r));
    final bite = Path()..addOval(Rect.fromCircle(center: c + Offset(r * 0.48, -r * 0.22), radius: r * 0.82));
    final path = Path.combine(PathOperation.difference, outer, bite);
    _halo(canvas, path, color);
    canvas.drawPath(path, _body(color, path.getBounds()));
    _finish(canvas, path, color);
  }

  static void _planet(Canvas canvas, Offset c, double r, Color color) {
    final ring = Rect.fromCenter(center: c, width: r * 2.3, height: r * 0.7);
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.12
      ..color = Color.lerp(color, Colors.white, 0.35)!.withValues(alpha: 0.85);
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(-0.35);
    canvas.translate(-c.dx, -c.dy);
    // Back half of the ring, the sphere, then the front half.
    canvas.drawArc(ring, math.pi, math.pi, false, ringPaint);
    final body = Path()..addOval(Rect.fromCircle(center: c, radius: r * 0.62));
    _halo(canvas, body, color);
    canvas.drawPath(body, _body(color, body.getBounds()));
    _finish(canvas, body, color);
    canvas.drawArc(ring, 0, math.pi, false, ringPaint);
    canvas.restore();
  }

  static void _compass(Canvas canvas, Offset c, double r, Color color) {
    final pts = <Offset>[];
    for (var i = 0; i < 8; i++) {
      pts.add(c + _polar(i * math.pi / 4 - math.pi / 2, i.isEven ? r * 1.12 : r * 0.3));
    }
    final path = Path()..addPolygon(pts, true);
    _halo(canvas, path, color);
    canvas.drawPath(path, _body(color, path.getBounds()));
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9
      ..color = Colors.black.withValues(alpha: 0.3);
    for (var i = 0; i < 8; i += 2) {
      canvas.drawLine(c, pts[i], line);
    }
    _finish(canvas, path, color);
    canvas.drawCircle(c, r * 0.12, Paint()..color = Color.lerp(color, Colors.white, 0.7)!);
  }

  static void _constellation(Canvas canvas, Offset c, double r, Color color, List<Offset> stars, List<(int, int)> links) {
    final pts = [for (final s in stars) c + s * r];
    final line = Paint()
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.65);
    for (final (a, b) in links) {
      canvas.drawLine(pts[a], pts[b], line);
    }
    for (var i = 0; i < pts.length; i++) {
      final sr = r * (i.isEven ? 0.2 : 0.15);
      canvas.drawCircle(pts[i], sr * 2.2, Paint()..color = color.withValues(alpha: 0.25)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
      final dot = Path()..addOval(Rect.fromCircle(center: pts[i], radius: sr));
      canvas.drawPath(dot, _body(color, dot.getBounds()));
      canvas.drawCircle(pts[i] + Offset(-sr * 0.3, -sr * 0.35), sr * 0.3, Paint()..color = Colors.white.withValues(alpha: 0.6));
    }
  }

  /// Small four-point sparkle (detail marks, the crescent's star).
  static void sparkle(Canvas canvas, Offset c, double r, Color color) {
    final path = Path();
    for (var i = 0; i < 8; i++) {
      final p = c + _polar(i * math.pi / 4 - math.pi / 2, i.isEven ? r : r * 0.28);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.35)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    canvas.drawPath(path, Paint()..color = Color.lerp(color, Colors.white, 0.45)!);
  }
}
