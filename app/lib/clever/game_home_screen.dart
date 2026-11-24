import 'package:flutter/material.dart';

import 'catalog.dart';
import 'lux.dart';
import 'play_screen.dart';
import 'premium_kit.dart';
import 'progress.dart';
import 'tutorial.dart';
import 'i18n/lang.dart';

/// A game's own page ("Zümrüt Rezerv" look, owner 2026-11-24): title and medallion, the game's numbers
/// (levels won, stars, the tier's best time), endless mode and tables, the difficulty tiers (Kolay /
/// Orta / Zor / Uzman, each playable from its first level) with the level grid, and a pinned "play the
/// next level" button. The rules and the two tutorial courses sit behind "Nasıl oynanır".
/// Doğru Söz lists its levels by topic instead ([SocialCategoryList]).
class GameHomeScreen extends StatefulWidget {
  final GameInfo game;
  const GameHomeScreen({super.key, required this.game});

  @override
  State<GameHomeScreen> createState() => _GameHomeScreenState();
}

class _GameHomeScreenState extends State<GameHomeScreen> {
  /// The game the page shows: the page's own game, or the chosen section's (Mental Aritmetik's
  /// Soroban). Everything below the header — rules, tutorials, levels, records — follows it.
  late GameInfo game = _initialSection();
  late int _tier = Progress.instance.currentTier(game.id);

  GameInfo _initialSection() {
    final saved = Progress.instance.section(widget.game.id);
    final s = widget.game.sections.where((s) => s.gameId == saved).firstOrNull;
    return _sectionGame(s ?? widget.game.sections.firstOrNull);
  }

  GameInfo _sectionGame(GameSection? s) =>
      s == null || s.gameId == widget.game.id ? widget.game : coreGame(s.gameId) ?? widget.game;

  void _selectSection(GameSection s) {
    final g = _sectionGame(s);
    if (g.id == game.id) return;
    setState(() {
      game = g;
      _tier = Progress.instance.currentTier(g.id);
    });
    Progress.instance.setSection(widget.game.id, s.gameId);
  }

  void _selectTier(int t) {
    if (t == _tier) return;
    setState(() => _tier = t);
    Progress.instance.setTier(game.id, t);
  }

  bool get _byCategory => game.id == 'social_seq';

  bool get _grid => game.hasLevels && !_byCategory;

  /// Opens a level; on return follow the tier the player ended up in (the result screen can move on
  /// to the next tier).
  Future<void> _play(int level) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => PlayScreen(game: game, level: level)));
    if (mounted) setState(() => _tier = Progress.instance.currentTier(game.id));
  }

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
              final range = p.tierRange(game.id, _tier);
              final next = _grid ? p.firstUnwonIn(game.id, _tier) : null;
              return Stack(
                children: [
                  CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(child: _topBar(context)),
                      SliverToBoxAdapter(child: _header()),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                        sliver: SliverList.list(children: [
                          if (widget.game.sections.length > 1) ...[
                            const SizedBox(height: 18),
                            _sectionSelector(),
                          ],
                          if (_grid) ...[
                            const SizedBox(height: 20),
                            _statsRow(p),
                          ],
                          if (game.infoPage case final page?) ...[
                            const SizedBox(height: 16),
                            _infoCard(context, page),
                          ],
                          if (game.hasEndless) ...[
                            LuxHeading(t('Sonsuz')),
                            _endlessCard(context, p),
                          ],
                          if (game.matchModes.isNotEmpty) ...[
                            LuxHeading(t('Masa')),
                            ..._matchCards(context),
                            const SizedBox(height: 24),
                          ],
                          if (game.homeExtra case final extra?) extra(context, game),
                          if (_byCategory) ...[
                            LuxHeading(tf('Konular · {0}/{1}', [p.completed(game.id), p.levelsFor(game.id)])),
                            const SizedBox.shrink(),
                            const SizedBox(height: 22),
                          ] else if (_grid) ...[
                            const SizedBox(height: 22),
                            if (p.tierCount(game.id) > 1) ...[
                              _tierSelector(p),
                              const SizedBox(height: 16),
                            ],
                          ],
                        ]),
                      ),
                      if (_grid)
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(16, 0, 16, next != null ? 132 : 32),
                          sliver: SliverGrid.builder(
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 5, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 0.94),
                            itemCount: range.last - range.first + 1,
                            itemBuilder: (context, i) => _levelTile(context, range.first + i, next),
                          ),
                        ),
                    ],
                  ),
                  if (next != null) Positioned(left: 0, right: 0, bottom: 0, child: _playBar(p, next)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context) {
    final tut = game.tutorials;
    final hasHowTo = tut.rules.trim().isNotEmpty || tut.mid.isNotEmpty || tut.advanced.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 16, 0),
      child: Row(
        children: [
          RimCircleButton(Icons.arrow_back_rounded, tooltip: Lang.en ? 'Back' : 'Geri', onPressed: () => Navigator.pop(context)),
          const Spacer(),
          if (hasHowTo)
            Material(
              type: MaterialType.transparency,
              shape: StadiumBorder(side: BorderSide(color: Lux.gold.withValues(alpha: 0.24))),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: const ValueKey('how-to-play'),
                onTap: () => _showHowTo(context),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Text(t('Nasıl oynanır'), style: Lux.ui(14, color: Lux.goldLight)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Category eyebrow, title and tagline on the left, the medallion on the right.
  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(Lux.upper(t(widget.game.category.label)), style: eyebrowStyle()),
                const SizedBox(height: 6),
                Text(t(widget.game.name),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Lux.display(38, color: Lux.ink, italic: true, spacing: 0).copyWith(height: 0.98)),
                const SizedBox(height: 8),
                Text(t(game.tagline), style: Lux.ui(14.5, color: Lux.muted).copyWith(height: 1.4)),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(shape: BoxShape.circle, color: Lux.gold.withValues(alpha: 0.07)),
            child: Hero(
              tag: monogramHeroTag(widget.game.id),
              child: Monogram(widget.game.glyph, size: 86, tint: widget.game.tint, art: widget.game.id),
            ),
          ),
        ],
      ),
    );
  }

  /// Levels won, stars, and the best winning time in the chosen tier, between two gold hairlines.
  Widget _statsRow(Progress p) {
    final best = p.bestTime(game.id, _tier);
    final tiers = p.tierCount(game.id) > 1;
    Widget cell(Widget value, String label, {bool divided = false}) => Expanded(
          child: Container(
            decoration: divided
                ? BoxDecoration(
                    border: Border.symmetric(vertical: BorderSide(color: Lux.gold.withValues(alpha: 0.14))))
                : null,
            child: Column(
              children: [
                FittedBox(fit: BoxFit.scaleDown, child: value),
                const SizedBox(height: 4),
                Text(label, style: Lux.ui(12, color: Lux.muted, spacing: 0.8)),
              ],
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: Border.symmetric(horizontal: BorderSide(color: Lux.gold.withValues(alpha: 0.2))),
      ),
      child: Row(
        children: [
          cell(
            Text.rich(
              TextSpan(
                text: '${p.completed(game.id)}',
                style: Lux.numeral(28, color: Lux.ink),
                children: [TextSpan(text: '/${p.levelsFor(game.id)}', style: Lux.numeral(17, color: Lux.muted))],
              ),
            ),
            t('Bölüm'),
          ),
          cell(Text('${p.totalStars(game.id)}', style: Lux.numeral(28)), t('Yıldız'), divided: true),
          cell(
            Text(best == null ? '—' : clockTime(best), style: Lux.numeral(28, color: Lux.ink)),
            tiers ? tf('{0} rekoru', [t(Progress.tierNames[_tier])]) : t('Rekor'),
          ),
        ],
      ),
    );
  }

  /// The rules, the two tutorial courses: what the page used to show above the levels.
  void _showHowTo(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (sheetContext) => DraggableScrollableSheet(
        initialChildSize: 0.86,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, controller) => Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF0E4636), Color(0xFF05241C)],
            ),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(top: BorderSide(color: Lux.gold.withValues(alpha: 0.45))),
          ),
          child: ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 32),
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 5,
                  decoration: BoxDecoration(color: Lux.muted.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(3)),
                ),
              ),
              const SizedBox(height: 18),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(Lux.upper(t(game.name)), style: eyebrowStyle()),
                    const SizedBox(height: 4),
                    Text(t('Nasıl oynanır'), style: Lux.display(32, color: Lux.ink, italic: true, spacing: 0)),
                  ],
                ),
              ),
              LuxHeading(t('Kurallar')),
              LuxCard(child: RichBody(game.tutorials.rulesText, size: 15)),
              if (game.tutorials.mid.isNotEmpty || game.tutorials.advanced.isNotEmpty) ...[
                LuxHeading(t('Eğitim')),
                // The courses themselves are Turkish in both languages (owner, 2026-11-24).
                if (Lang.en)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10, left: 4),
                    child: Text(t('Dersler Türkçedir.'), style: Lux.ui(13, color: Lux.muted)),
                  ),
                Row(
                  children: [
                    Expanded(
                        child: _courseCard(
                            context, t('Orta seviye'), t('Temel taktikler'), Icons.school_outlined, game.tutorials.mid)),
                    const SizedBox(width: 12),
                    Expanded(
                        child: _courseCard(context, t('İleri seviye'), t('Usta teknikleri'), Icons.auto_awesome_outlined,
                            game.tutorials.advanced)),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _endlessCard(BuildContext context, Progress p) {
    return LuxCard(
      highlight: true,
      onTap: () =>
          Navigator.push(context, MaterialPageRoute(builder: (_) => PlayScreen(game: game, level: 1, mode: 'endless'))),
      child: Row(
        children: [
          const Icon(Icons.all_inclusive_rounded, color: Lux.gold, size: 30),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t(game.endlessLabel), style: Lux.ui(18, weight: FontWeight.w700)),
                Text(tf('Rekor: {0}', [p.best(game.id)]), style: Lux.ui(14, color: Lux.muted)),
              ],
            ),
          ),
          const Icon(Icons.play_arrow_rounded, color: Lux.gold, size: 30),
        ],
      ),
    );
  }

  /// Segmented switch between the page's games (Mental Aritmetik: Sprint / Soroban), each with its
  /// own medallion and level count.
  Widget _sectionSelector() {
    final p = Progress.instance;
    final radius = BorderRadius.circular(16);
    return Row(
      children: [
        for (final (i, s) in widget.game.sections.indexed) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(
            child: Builder(builder: (context) {
              final g = _sectionGame(s);
              final on = g.id == game.id;
              return Semantics(
                button: true,
                selected: on,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    key: ValueKey('section-${s.gameId}'),
                    borderRadius: radius,
                    onTap: () => _selectSection(s),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                      decoration: BoxDecoration(
                        borderRadius: radius,
                        gradient: on
                            ? const LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [Color(0xFF155A45), Color(0xFF07301F)],
                              )
                            : Lux.velvetCard,
                        border: Border.all(color: on ? Lux.gold.withValues(alpha: 0.85) : Lux.line, width: on ? 1.2 : 1),
                      ),
                      child: Row(
                        children: [
                          Monogram(g.glyph, size: 34, tint: g.tint, art: g.id),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(t(s.label),
                                      style: Lux.ui(16, weight: FontWeight.w700, color: on ? Lux.goldLight : Lux.ink)),
                                ),
                                Text(tf('{0}/{1} bölüm', [p.completed(g.id), p.levelsFor(g.id)]),
                                    style: Lux.ui(12.5, color: on ? Lux.gold : Lux.muted)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ],
    );
  }

  /// Kolay / Orta / Zor / Uzman as one pill; the chosen tier is gold leaf. Each tab shows the tier's
  /// progress under its name.
  Widget _tierSelector(Progress p) {
    final c = p.tierCount(game.id);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(40),
        color: Lux.bg0.withValues(alpha: 0.65),
        border: Border.all(color: Lux.gold.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          for (var k = 0; k < c; k++) ...[
            if (k > 0) const SizedBox(width: 4),
            Expanded(child: _tierTab(p, k)),
          ],
        ],
      ),
    );
  }

  Widget _tierTab(Progress p, int k) {
    final on = k == _tier;
    final r = p.tierRange(game.id, k);
    final count = r.last - r.first + 1;
    final done = p.tierCompleted(game.id, k);
    final fg = on ? reserveInk : (done == count ? Lux.goldLight : const Color(0xFFC9D6CC));
    return Semantics(
      button: true,
      selected: on,
      child: Material(
        type: MaterialType.transparency,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('tier-$k'),
          onTap: () => _selectTier(k),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 50,
            decoration: BoxDecoration(gradient: on ? reserveFoil : null),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(t(Progress.tierNames[k]),
                      style: Lux.ui(14.5, color: fg, weight: on ? FontWeight.w700 : FontWeight.w500)),
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('$done/$count',
                      style: Lux.ui(11.5, color: on ? reserveInk.withValues(alpha: 0.75) : Lux.muted)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Table cards. Labels of the form "Group · Table" (Okey: "101 · Kolay", "Klasik · Kolay") get a
  /// small header per group ("101 Okey") and show only the table part on the card.
  List<Widget> _matchCards(BuildContext context) {
    final out = <Widget>[];
    String? group;
    for (final m in game.matchModes) {
      final i = m.label.indexOf(' · ');
      final g = i > 0 ? m.label.substring(0, i) : null;
      if (g != null && g != group) {
        out.add(Padding(
          padding: EdgeInsets.fromLTRB(4, out.isEmpty ? 0 : 10, 4, 8),
          child: Text(Lux.upper('${t(g)} ${t(game.name)}'), style: Lux.ui(12.5, color: Lux.gold, weight: FontWeight.w600, spacing: 1.8)),
        ));
      }
      group = g;
      out.add(_matchCard(context, m, title: t(g == null ? m.label : m.label.substring(i + 3))));
    }
    return out;
  }

  Widget _matchCard(BuildContext context, MatchMode m, {required String title}) {
    final r = Progress.instance.record(game.id, m.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: LuxCard(
        highlight: m.id == 'impossible' || m.id.endsWith('_impossible'),
        onTap: () => Navigator.push(
            context, MaterialPageRoute(builder: (_) => PlayScreen(game: game, level: 1, mode: m.id))),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Lux.ui(18, weight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(t(m.description), style: Lux.ui(13.5, color: Lux.muted)),
                  const SizedBox(height: 6),
                  Text(tf('Galibiyet {0} · Berabere {1} · Yenilgi {2}', [r[0], r[1], r[2]]),
                      style: Lux.ui(12.5, color: Lux.goldLight)),
                ],
              ),
            ),
            const Icon(Icons.play_arrow_rounded, color: Lux.gold, size: 30),
          ],
        ),
      ),
    );
  }

  /// The game's info page (Doğru Söz: "Bilgilendirme"), reachable before playing.
  Widget _infoCard(BuildContext context, GameInfoPage page) {
    return LuxCard(
      key: const ValueKey('game-info-card'),
      padding: const EdgeInsets.all(14),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (c) => page(c, const {}))),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded, color: Lux.gold),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t(game.infoLabel), style: Lux.ui(17, weight: FontWeight.w700)),
                if (game.infoLine.isNotEmpty) Text(t(game.infoLine), style: Lux.ui(13, color: Lux.muted)),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, color: Lux.gold),
        ],
      ),
    );
  }

  Widget _courseCard(BuildContext context, String title, String sub, IconData icon, List<TutorialSection> sections) {
    return LuxCard(
      padding: const EdgeInsets.all(14),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => TutorialScreen(title: game.name, level: title, sections: sections)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Lux.gold),
          const SizedBox(height: 8),
          Text(title, style: Lux.ui(17, weight: FontWeight.w700)),
          Text(tf('{0} · {1} ders', [sub, sections.length]), style: Lux.ui(13, color: Lux.muted)),
        ],
      ),
    );
  }

  /// Won (number + stars), next (gold leaf rim, "SIRADA"), open but not won, or locked (dim number +
  /// lock).
  Widget _levelTile(BuildContext context, int level, int? next) {
    final p = Progress.instance;
    final open = p.unlocked(game.id, level);
    final s = p.stars(game.id, level);
    final radius = BorderRadius.circular(16);
    if (level == next) {
      return Semantics(
        button: true,
        label: tf('Bölüm {0}, sırada', [level]),
        child: Container(
          padding: const EdgeInsets.all(1.5),
          decoration: BoxDecoration(
            borderRadius: radius,
            gradient: Lux.foil,
            boxShadow: [BoxShadow(color: Lux.goldLight.withValues(alpha: 0.28), blurRadius: 20)],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14.5),
              onTap: () => _play(level),
              child: Ink(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14.5),
                  gradient: const RadialGradient(
                    center: Alignment(0, -0.4),
                    radius: 1.1,
                    colors: [Color(0xFF1E6B52), Color(0xFF062A21)],
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('$level', style: Lux.numeral(21, color: const Color(0xFFFBE7B0))),
                    const SizedBox(height: 4),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(t('SIRADA'), style: Lux.ui(9, color: Lux.goldLight, weight: FontWeight.w600, spacing: 1.8)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (!open) {
      return Container(
        decoration: BoxDecoration(
          borderRadius: radius,
          color: Lux.bg0.withValues(alpha: 0.5),
          border: Border.all(color: Lux.gold.withValues(alpha: 0.12)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('$level', style: Lux.numeral(17, color: Lux.muted.withValues(alpha: 0.5))),
            const SizedBox(height: 4),
            Icon(Icons.lock_outline_rounded, size: 12, color: Lux.muted.withValues(alpha: 0.55)),
          ],
        ),
      );
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: radius,
        onTap: () => _play(level),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: radius,
            gradient: Lux.velvetCard,
            border: Border.all(color: Lux.gold.withValues(alpha: s > 0 ? 0.24 : 0.5)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('$level', style: Lux.numeral(19, color: s > 0 ? Lux.ink : Lux.goldLight)),
              const SizedBox(height: 5),
              StarRow(s, size: 10),
            ],
          ),
        ),
      ),
    );
  }

  /// Pinned at the bottom: play the tier's next level.
  Widget _playBar(Progress p, int level) {
    final count = p.tierRange(game.id, _tier).last - p.tierRange(game.id, _tier).first + 1;
    final done = p.tierCompleted(game.id, _tier);
    final tierLine = p.tierCount(game.id) > 1 ? '${t(Progress.tierNames[_tier])} · $done/$count' : '$done/$count';
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 30, 20, 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Lux.bg0.withValues(alpha: 0), Lux.bg0.withValues(alpha: 0.92), Lux.bg0],
          stops: const [0, 0.45, 1],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FoilWideButton(tf('Oyna · Bölüm {0}', [level]),
              key: const ValueKey('play-next'), icon: Icons.play_arrow_rounded, onPressed: () => _play(level)),
          const SizedBox(height: 8),
          Text(tierLine, style: Lux.ui(12.5, color: Lux.muted)),
        ],
      ),
    );
  }
}
