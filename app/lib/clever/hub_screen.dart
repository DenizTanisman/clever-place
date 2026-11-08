import 'package:flutter/material.dart';

import '../src/screens/settings_page.dart' show SettingsPage;
import 'catalog.dart';
import 'cube/cube_home_screen.dart';
import 'daily_mix.dart';
import 'game_home_screen.dart';
import 'lux.dart';
import 'progress.dart';

/// Küp: speedcubing timer with stored scrambles, the algorithm notebooks and their test.
final GameInfo kCubeGame = GameInfo(
  id: 'cube',
  name: 'Küp',
  tagline: 'Zamanlayıcı, algoritma defteri, test',
  glyph: '▣',
  tint: kCubeTint,
  category: GameCategory.cube,
  hasLevels: false,
  customHome: (_) => const CubeHomeScreen(),
  cardLine: 'Zamanlayıcı, defter',
);

List<GameInfo> get allGames => [...kCoreGames, kCubeGame];

/// The hub cards of [cat], in order. Games shown only inside another game's page (Soroban) are left
/// out; under Strateji the board duels come first, then the speed games.
List<GameInfo> hubGames(GameCategory cat) {
  final games = [for (final g in allGames) if (g.category == cat && g.inHub) g];
  return [...games.where((g) => !g.speed), ...games.where((g) => g.speed)];
}

/// Clever Place home — "Zümrüt Kadife".
class HubScreen extends StatefulWidget {
  const HubScreen({super.key});

  @override
  State<HubScreen> createState() => _HubScreenState();
}

class _HubScreenState extends State<HubScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _in =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..forward();

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  Animation<double> _stagger(int i) {
    final start = (i * 0.045).clamp(0.0, 0.6);
    return CurvedAnimation(parent: _in, curve: Interval(start, (start + 0.4).clamp(0.0, 1.0), curve: Curves.easeOutCubic));
  }

  Widget _rise(int i, Widget child) {
    final a = _stagger(i);
    return AnimatedBuilder(
      animation: a,
      builder: (context, c) => Opacity(opacity: a.value, child: Transform.translate(offset: Offset(0, 22 * (1 - a.value)), child: c)),
      child: child,
    );
  }

  /// "Başla / Devam": the day's first pick not yet done; a win there offers the next one.
  void _playDaily() {
    final p = Progress.instance;
    final next = DailyMix.next(p);
    if (next != null) Navigator.push(context, DailyMix.route(p, next.game));
  }

  void _openSettings() => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage()));

  @override
  Widget build(BuildContext context) {
    final p = Progress.instance;
    return Scaffold(
      backgroundColor: Lux.bg0,
      body: LuxBackground(
        child: SafeArea(
          child: ListenableBuilder(
            listenable: p,
            builder: (context, _) {
              final stars = p.starsFor(kCoreGames.map((g) => g.id));
              final level = Progress.roman(stars ~/ 6 + 1);
              var idx = 0;
              return CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                      child: Row(
                        children: [
                          const SizedBox(width: 48),
                          Expanded(
                            child: _rise(
                              idx++,
                              Column(
                                children: [
                                  const SizedBox(height: 10),
                                  FoilText('Clever Place', style: Lux.display(38, italic: true), align: TextAlign.center),
                                  const SizedBox(height: 4),
                                  Text(Lux.upper('Zihin Kulübü'),
                                      style: Lux.ui(11.5, color: Lux.muted, spacing: 4.2, weight: FontWeight.w500)),
                                ],
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: _openSettings,
                            icon: const Icon(Icons.tune_rounded, color: Lux.gold),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                    sliver: SliverToBoxAdapter(child: _rise(idx++, _dailyCard(p))),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    sliver: SliverToBoxAdapter(
                      child: _rise(
                        idx++,
                        Row(
                          children: [
                            Expanded(child: _stat('$stars', 'Yıldız')),
                            const SizedBox(width: 10),
                            Expanded(child: _stat('${p.daysThisWeek}/7', 'Bu hafta')),
                            const SizedBox(width: 10),
                            Expanded(child: _stat(level, 'Seviye')),
                          ],
                        ),
                      ),
                    ),
                  ),
                  for (final cat in GameCategory.values) ...[
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      sliver: SliverToBoxAdapter(child: _rise(idx++, LuxHeading(cat.label))),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      sliver: SliverGrid.count(
                        crossAxisCount: 2,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 0.98,
                        children: [for (final g in hubGames(cat)) _rise(idx++, _gameCard(g))],
                      ),
                    ),
                  ],
                  const SliverToBoxAdapter(child: SizedBox(height: 36)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// "Günün hedefi": the ring, today's picks (one per enabled category) and Başla / Devam.
  Widget _dailyCard(Progress p) {
    final picks = DailyMix.today(p);
    final won = p.wonToday;
    final done = picks.where((k) => won.contains(k.game.id)).length;
    final all = picks.isNotEmpty && done == picks.length;
    return LuxCard(
      key: const ValueKey('daily-card'),
      highlight: true,
      padding: const EdgeInsets.fromLTRB(18, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _goalRing(done, picks.length),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(Lux.upper('Günün hedefi'), style: Lux.ui(11, color: Lux.muted, spacing: 2.4)),
                    const SizedBox(height: 2),
                    Text(picks.isEmpty ? 'Kategori seç' : '$done / ${picks.length} oyun',
                        style: Lux.display(23, color: Lux.ink, italic: true)),
                    const SizedBox(height: 2),
                    Text(
                      all ? 'Bugünlük tamam · ${p.daysThisWeek} / 7 gün' : 'Haftalık ritim: ${p.daysThisWeek} / 7 gün',
                      style: Lux.ui(12.5, color: Lux.muted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (picks.isEmpty)
                GoldButton('Ayarlar', outlined: true, onPressed: _openSettings)
              else if (!all)
                GoldButton(done == 0 ? 'Başla' : 'Devam', key: const ValueKey('daily-play'), onPressed: _playDaily),
            ],
          ),
          if (picks.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(height: 1, color: Lux.lineFaint),
            const SizedBox(height: 4),
            for (final pick in picks) _pickRow(p, pick, won.contains(pick.game.id)),
          ],
        ],
      ),
    );
  }

  Widget _pickRow(Progress p, DailyPick pick, bool done) {
    final g = pick.game;
    return InkWell(
      key: ValueKey('daily-pick-${g.id}'),
      borderRadius: BorderRadius.circular(10),
      onTap: () => Navigator.push(context, DailyMix.route(p, g)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            // Not a Hero: the game's hub card below already carries this medallion's hero tag.
            Monogram(g.glyph, size: 34, tint: g.tint, art: g.id),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(g.name,
                      style: Lux.ui(15, weight: FontWeight.w600, color: done ? Lux.muted : Lux.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  Text(pick.category.label, style: Lux.ui(11.5, color: Lux.muted), maxLines: 1),
                ],
              ),
            ),
            Icon(done ? Icons.check_circle_rounded : Icons.play_circle_outline_rounded,
                color: done ? Lux.good : Lux.gold, size: 22),
          ],
        ),
      ),
    );
  }

  Widget _goalRing(int done, int goal) {
    final v = goal == 0 ? 0.0 : (done / goal).clamp(0.0, 1.0);
    return SizedBox(
      width: 54,
      height: 54,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: v,
              strokeWidth: 4,
              backgroundColor: Lux.lineFaint,
              valueColor: const AlwaysStoppedAnimation(Lux.gold),
              strokeCap: StrokeCap.round,
            ),
          ),
          Icon(v >= 1 ? Icons.emoji_events_rounded : Icons.auto_awesome_rounded, color: Lux.goldLight, size: 24),
        ],
      ),
    );
  }

  Widget _stat(String value, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: Lux.velvetCard,
        border: Border.all(color: Lux.line),
      ),
      child: Column(
        children: [
          Text(value, style: Lux.numeral(22)),
          const SizedBox(height: 3),
          Text(Lux.upper(label), style: Lux.ui(10, color: Lux.muted, spacing: 1.8)),
        ],
      ),
    );
  }

  Widget _gameCard(GameInfo g) {
    final p = Progress.instance;
    String sub;
    double prog;
    if (g.customHome != null) {
      sub = g.cardLine ?? '';
      prog = 0;
    } else if (g.matchModes.isNotEmpty) {
      var w = 0, l = 0;
      for (final m in g.matchModes) {
        final r = p.record(g.id, m.id);
        w += r[0];
        l += r[2];
      }
      sub = w + l == 0 ? 'Masaya otur' : '$w galibiyet · $l yenilgi';
      prog = 0;
    } else if (g.hasLevels) {
      final done = p.completed(g.id);
      final next = p.nextLevel(g.id);
      sub = next == null
          ? 'Hepsi tamam'
          : p.tierCount(g.id) > 1
              ? '${Progress.tierNames[p.tierOf(g.id, next)]} · Bölüm $next'
              : 'Bölüm $next';
      prog = done / p.levelsFor(g.id);
    } else {
      sub = 'Rekor ${p.best(g.id)}';
      prog = 0;
    }
    return LuxCard(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: g.customHome ?? (_) => GameHomeScreen(game: g))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The hub outlives every game page, so its medallion must never depend on hero
              // bookkeeping: Flutter hides a push flight's source hero and only reveals it again when
              // it sees the matching pop transition. A pop it skips (it ignores route changes while a
              // predictive-back swipe is still animating out, e.g. two quick backs Play » game page »
              // hub) left the card blank for good. Painting the child as its own placeholder keeps it.
              Hero(
                tag: monogramHeroTag(g.id),
                placeholderBuilder: (context, size, child) => child,
                child: Monogram(g.glyph, size: 50, tint: g.tint, art: g.id),
              ),
              const Spacer(),
              if (g.hasLevels) StarRow((p.totalStars(g.id) / p.levelsFor(g.id)).round().clamp(0, 3), size: 12),
            ],
          ),
          const Spacer(),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(g.name, style: Lux.display(19, color: Lux.ink), maxLines: 1),
          ),
          const SizedBox(height: 2),
          Text(sub, style: Lux.ui(12.5, color: Lux.muted), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 9),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: Stack(
                    children: [
                      Container(height: 3, color: Lux.lineFaint),
                      FractionallySizedBox(
                        widthFactor: prog.clamp(0.0, 1.0),
                        child: Container(height: 3, decoration: const BoxDecoration(gradient: Lux.foil)),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(g.hasLevels ? '${(prog * 100).round()}%' : '', style: Lux.ui(10.5, color: Lux.muted)),
            ],
          ),
        ],
      ),
    );
  }
}
