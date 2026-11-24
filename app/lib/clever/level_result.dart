import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'daily_mix.dart';
import 'lux.dart';
import 'premium_kit.dart';
import 'progress.dart';
import 'i18n/lang.dart';

/// One action under the result's main button.
typedef ResultAction = ({String label, VoidCallback onPressed});

/// The end of a plain level ("Zümrüt Rezerv", owner 2026-11-24): stars on an arc, "Bölüm n", the time
/// with the game's mistakes and hints, the tier's last ten winning times with the record, the day's
/// goal when the level was started from it, then one gold button for the natural next step and up to
/// three quieter ones. [PlayScreen] decides the actions; this only draws.
class LevelResultView extends StatelessWidget {
  final String gameId;
  final String gameName;
  final int level;
  final bool won;
  final int stars;

  /// The game's final state (`summary`, `errors` / `mistakes`, `hints` / `hints_used`).
  final Map<String, dynamic> state;

  /// This attempt's time, the tier's best before it, and whether the time is stored yet (the chart
  /// and the record badge wait for it).
  final int timeMs;
  final int? bestBefore;
  final bool timeSaved;

  /// Started from "Günün hedefi": show the day's progress.
  final bool daily;

  final String mainLabel;
  final IconData mainIcon;
  final bool mainIconAfter;
  final Key mainKey;
  final VoidCallback onMain;
  final List<ResultAction> more;
  final VoidCallback onClose;

  const LevelResultView({
    super.key,
    required this.gameId,
    required this.gameName,
    required this.level,
    required this.won,
    required this.stars,
    required this.state,
    required this.timeMs,
    required this.bestBefore,
    required this.timeSaved,
    required this.daily,
    required this.mainLabel,
    required this.mainIcon,
    required this.mainIconAfter,
    required this.mainKey,
    required this.onMain,
    required this.more,
    required this.onClose,
  });

  /// The first of [keys] the game state holds as a number.
  static int? countOf(Map<String, dynamic> st, List<String> keys) {
    for (final k in keys) {
      final v = st[k];
      if (v is num) return v.toInt();
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final p = Progress.instance;
    final tier = p.tierOf(gameId, level);
    final tiers = p.tierCount(gameId) > 1;
    final eyebrow =
        tiers ? '${Lux.upper(gameName)} · ${Lux.upper(t(Progress.tierNames[tier]))}' : Lux.upper(gameName);
    final glow = won ? Lux.gold.withValues(alpha: 0.22) : Lux.bordeaux.withValues(alpha: 0.2);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 460),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(opacity: t, child: Transform.scale(scale: 0.96 + 0.04 * t, child: child)),
      child: Stack(
        children: [
          const Positioned.fill(child: LuxBackground(child: SizedBox.expand())),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, -0.62),
                  radius: 0.8,
                  colors: [glow, glow.withValues(alpha: 0)],
                ),
              ),
            ),
          ),
          CustomScrollView(
            slivers: [
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          RimCircleButton(Icons.close_rounded, tooltip: t('Kapat'), onPressed: onClose),
                          Expanded(
                            child: Center(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(eyebrow, maxLines: 1, style: eyebrowStyle(size: 11)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 48),
                        ],
                      ),
                      const SizedBox(height: 22),
                      _ArcStars(won ? stars : 0),
                      const SizedBox(height: 14),
                      Text(tf('Bölüm {0}', [level]),
                          textAlign: TextAlign.center, style: Lux.display(44, color: Lux.ink, italic: true, spacing: 0)),
                      const SizedBox(height: 6),
                      Text(Lux.upper(t(won ? 'Tamamlandı' : 'Olmadı')),
                          style: eyebrowStyle(color: won ? Lux.goldLight : Lux.bordeauxLight, size: 12.5)),
                      if (state['summary'] is String) ...[
                        const SizedBox(height: 12),
                        Text(ct(state['summary'] as String),
                            textAlign: TextAlign.center, style: Lux.ui(15, color: Lux.muted).copyWith(height: 1.4)),
                      ],
                      const SizedBox(height: 22),
                      _statsCard(p, tier, tiers),
                      if (daily) _dailyStrip(p),
                      const Spacer(),
                      const SizedBox(height: 22),
                      FoilWideButton(mainLabel,
                          key: mainKey, icon: mainIcon, iconAfter: mainIconAfter, onPressed: onMain),
                      if (more.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            for (final (i, a) in more.indexed) ...[
                              if (i > 0) const SizedBox(width: 10),
                              Expanded(child: OutlinePill(a.label, onPressed: a.onPressed)),
                            ],
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Time, the game's mistakes and hints (or the stars when it keeps neither), and after two wins in
  /// the tier its recent times with the record.
  Widget _statsCard(Progress p, int tier, bool tiers) {
    final errors = countOf(state, const ['errors', 'mistakes']);
    final hints = countOf(state, const ['hints', 'hints_used']);
    final cells = <(String, String)>[
      (clockTime(timeMs), t('Süre')),
      if (errors != null) ('$errors', t('Hata')),
      if (hints != null) ('$hints', t('İpucu')),
    ];
    if (cells.length == 1) cells.add(('${won ? stars : 0}/3', t('Yıldız')));
    final times = won && timeSaved ? p.recentTimes(gameId, tier) : const <int>[];
    final before = bestBefore;
    final newRecord = won && timeSaved && before != null && timeMs < before;
    final line = Lux.gold.withValues(alpha: 0.14);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0x731E6B52), Color(0xF205241C)],
        ),
        border: Border.all(color: Lux.gold.withValues(alpha: 0.28)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 40, offset: const Offset(0, 18))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              for (final (i, c) in cells.indexed)
                Expanded(
                  child: Container(
                    decoration: i > 0 ? BoxDecoration(border: Border(left: BorderSide(color: line))) : null,
                    child: Column(
                      children: [
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(c.$1,
                              style: Lux.numeral(30, color: i == 0 && won ? const Color(0xFFFBE7B0) : Lux.ink)),
                        ),
                        const SizedBox(height: 5),
                        Text(c.$2, style: Lux.ui(12, color: Lux.muted, spacing: 0.8)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          if (times.length >= 2) ...[
            const SizedBox(height: 14),
            Container(height: 1, color: line),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    tiers ? tf('Son {0} {1} bölümü', [times.length, t(Progress.tierNames[tier])]) : tf('Son {0} bölüm', [times.length]),
                    style: Lux.ui(13, color: const Color(0xFFC9D6CC)),
                  ),
                ),
                if (newRecord)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      color: Lux.gold.withValues(alpha: 0.16),
                      border: Border.all(color: Lux.goldLight.withValues(alpha: 0.4)),
                    ),
                    child: Text(tf('Yeni rekor · −{0}', [recordGain(before - timeMs)]),
                        style: Lux.ui(12, color: const Color(0xFFFBE7B0), weight: FontWeight.w600)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 82,
              width: double.infinity,
              child: CustomPaint(painter: TimesChartPainter(times, newRecord: newRecord)),
            ),
          ] else if (won && timeSaved) ...[
            const SizedBox(height: 12),
            Text(before == null ? t('Bu kademedeki ilk süren kaydedildi.') : tf('Rekor: {0}', [clockTime(before)]),
                textAlign: TextAlign.center, style: Lux.ui(13, color: Lux.muted)),
          ],
        ],
      ),
    );
  }

  /// "Günün hedefi" progress: one segment per pick, the won ones in gold.
  Widget _dailyStrip(Progress p) {
    final picks = DailyMix.today(p);
    if (picks.isEmpty) return const SizedBox.shrink();
    final done = [for (final k in picks) DailyMix.done(p, k)];
    final n = done.where((d) => d).length;
    final all = n == picks.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 0),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                for (var i = 0; i < picks.length; i++) ...[
                  if (i > 0) const SizedBox(width: 5),
                  Expanded(
                    child: Container(
                      height: 5,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(3),
                        gradient: done[i] ? reserveFoil : null,
                        color: done[i] ? null : Lux.gold.withValues(alpha: 0.16),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(all ? t('Günün hedefi tamam') : tf('Günün hedefi {0}/{1}', [n, picks.length]),
              style: Lux.ui(13, color: all ? Lux.good : const Color(0xFFC9D6CC))),
        ],
      ),
    );
  }
}

/// Three result stars on a shallow arc (the middle one larger and lit), popping in one after another.
class _ArcStars extends StatelessWidget {
  final int stars;
  const _ArcStars(this.stars);

  @override
  Widget build(BuildContext context) {
    const sizes = [60.0, 84.0, 60.0];
    const angles = [-0.21, 0.0, 0.21];
    const drops = [8.0, 0.0, 8.0];
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(3, (i) {
        final on = i < stars;
        final icon = Icon(
          on ? Icons.star_rounded : Icons.star_outline_rounded,
          size: sizes[i],
          color: on ? Colors.white : Lux.muted.withValues(alpha: 0.32),
          shadows: on && i == 1 ? [Shadow(color: Lux.goldLight.withValues(alpha: 0.55), blurRadius: 22)] : null,
        );
        final star = on
            ? ShaderMask(blendMode: BlendMode.srcIn, shaderCallback: (r) => Lux.foil.createShader(r), child: icon)
            : icon;
        final placed = Transform.translate(
          offset: Offset(0, drops[i]),
          child: Transform.rotate(angle: angles[i], child: star),
        );
        if (!on) return placed;
        final total = 420 + 240 * i;
        return TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: Duration(milliseconds: total),
          builder: (context, t, child) {
            final local = ((t * total - 240 * i - 120) / 420).clamp(0.0, 1.0);
            return Transform.scale(scale: Curves.elasticOut.transform(local), child: child);
          },
          child: placed,
        );
      }),
    );
  }
}

/// The tier's recent winning times, oldest left; faster is higher. Marks the record (the old one when
/// this attempt broke it) and the newest time.
class TimesChartPainter extends CustomPainter {
  final List<int> times;
  final bool newRecord;
  TimesChartPainter(this.times, {required this.newRecord});

  @override
  void paint(Canvas canvas, Size size) {
    final n = times.length;
    if (n < 2) return;
    const top = 18.0, bottom = 16.0, left = 5.0, right = 7.0;
    final h = size.height - top - bottom;
    final w = size.width - left - right;
    final lo = times.reduce(math.min), hi = times.reduce(math.max);
    final span = hi - lo;
    double x(int i) => left + w * i / (n - 1);
    double y(int v) => span == 0 ? top + h / 2 : top + h * (v - lo) / span;

    final grid = Paint()
      ..color = Lux.gold.withValues(alpha: 0.12)
      ..strokeWidth = 1;
    for (final f in const [1 / 3, 2 / 3]) {
      canvas.drawLine(Offset(left, top + h * f), Offset(size.width - right, top + h * f), grid);
    }

    final path = Path()..moveTo(x(0), y(times[0]));
    for (var i = 1; i < n; i++) {
      path.lineTo(x(i), y(times[i]));
    }
    final floor = top + h + 6;
    final area = Path.from(path)
      ..lineTo(x(n - 1), floor)
      ..lineTo(x(0), floor)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Lux.gold.withValues(alpha: 0.32), Lux.gold.withValues(alpha: 0)],
        ).createShader(Rect.fromLTWH(0, top, size.width, floor - top)),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFFE3C278)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );

    // The record: the fastest before this attempt when it broke it, else the fastest overall.
    final pool = newRecord ? times.sublist(0, n - 1) : times;
    var bestIdx = 0;
    for (var i = 1; i < pool.length; i++) {
      if (pool[i] < pool[bestIdx]) bestIdx = i;
    }
    final last = Offset(x(n - 1), y(times[n - 1]));
    if (bestIdx != n - 1) {
      final b = Offset(x(bestIdx), y(times[bestIdx]));
      canvas.drawCircle(b, 3, Paint()..color = Lux.bg0);
      canvas.drawCircle(
          b,
          3,
          Paint()
            ..color = Lux.muted
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2);
      _label(canvas, size, '${t(newRecord ? 'eski rekor' : 'rekor')} ${clockTime(times[bestIdx])}', b.dx, b.dy - 16,
          centered: true);
    }
    canvas.drawCircle(last, 5.5, Paint()..color = Lux.bg0);
    canvas.drawCircle(last, 4.2, Paint()..color = const Color(0xFFFBE7B0));
    _label(canvas, size, clockTime(times[0]), left, size.height - 13);
  }

  void _label(Canvas canvas, Size size, String text, double x, double y, {bool centered = false}) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: Lux.ui(11, color: Lux.muted)),
      textDirection: TextDirection.ltr,
    )..layout();
    var dx = centered ? x - tp.width / 2 : x;
    dx = dx.clamp(0.0, math.max(0.0, size.width - tp.width));
    tp.paint(canvas, Offset(dx, y.clamp(0.0, math.max(0.0, size.height - tp.height))));
  }

  @override
  bool shouldRepaint(covariant TimesChartPainter old) => old.newRecord != newRecord || !listEquals(old.times, times);
}
