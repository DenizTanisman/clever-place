import 'package:flutter/material.dart';

import 'catalog.dart';
import 'lux.dart';
import 'play_screen.dart';
import 'progress.dart';
import 'tutorial.dart';

/// A game's own page: rules, the two tutorial courses, endless mode and the level grid, split into
/// difficulty tiers (Kolay / Orta / Zor / Uzman) that are each playable from their first level.
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

  /// Opens a level; on return follow the tier the player ended up in (the result card can move on to
  /// the next tier).
  Future<void> _play(int level) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => PlayScreen(game: game, level: level)));
    if (mounted) setState(() => _tier = Progress.instance.currentTier(game.id));
  }

  @override
  Widget build(BuildContext context) {
    final p = Progress.instance;
    final range = p.tierRange(game.id, _tier);
    return Scaffold(
      backgroundColor: Lux.bg0,
      body: LuxBackground(
        child: SafeArea(
          child: ListenableBuilder(
            listenable: p,
            builder: (context, _) => CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 20, 0),
                    child: Row(children: [
                      IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back, color: Lux.ink)),
                    ]),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                    child: Row(
                      children: [
                        Hero(
                          tag: monogramHeroTag(widget.game.id),
                          child: Monogram(widget.game.glyph, size: 68, tint: widget.game.tint, art: widget.game.id),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              FoilText(widget.game.name, style: Lux.display(30, italic: true)),
                              const SizedBox(height: 4),
                              Text(game.tagline, style: Lux.ui(15, color: Lux.muted)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  sliver: SliverList.list(children: [
                    if (widget.game.sections.length > 1) ...[
                      const SizedBox(height: 16),
                      _sectionSelector(),
                    ],
                    const LuxHeading('Kurallar'),
                    LuxCard(child: RichBody(game.tutorials.rules, size: 15)),
                    const LuxHeading('Eğitim'),
                    Row(
                      children: [
                        Expanded(child: _courseCard(context, 'Orta seviye', 'Temel taktikler', Icons.school_outlined, game.tutorials.mid)),
                        const SizedBox(width: 12),
                        Expanded(child: _courseCard(context, 'İleri seviye', 'Usta teknikleri', Icons.auto_awesome_outlined, game.tutorials.advanced)),
                      ],
                    ),
                    if (game.hasEndless) ...[
                      const LuxHeading('Sonsuz'),
                      LuxCard(
                        highlight: true,
                        onTap: () => Navigator.push(context,
                            MaterialPageRoute(builder: (_) => PlayScreen(game: game, level: 1, mode: 'endless'))),
                        child: Row(
                          children: [
                            const Icon(Icons.all_inclusive_rounded, color: Lux.gold, size: 30),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(game.endlessLabel, style: Lux.ui(18, weight: FontWeight.w700)),
                                  Text('Rekor: ${p.best(game.id)}', style: Lux.ui(14, color: Lux.muted)),
                                ],
                              ),
                            ),
                            const Icon(Icons.play_arrow_rounded, color: Lux.gold, size: 30),
                          ],
                        ),
                      ),
                    ],
                    if (game.matchModes.isNotEmpty) ...[
                      const LuxHeading('Masa'),
                      ..._matchCards(context),
                      const SizedBox(height: 24),
                    ],
                    if (game.hasLevels) ...[
                      LuxHeading('Bölümler · ${p.completed(game.id)}/${p.levelsFor(game.id)}'),
                      if (p.tierCount(game.id) > 1) ...[
                        _tierSelector(p),
                        const SizedBox(height: 14),
                      ],
                    ],
                  ]),
                ),
                if (game.hasLevels)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                    sliver: SliverGrid.builder(
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 5, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 0.82),
                      itemCount: range.last - range.first + 1,
                      itemBuilder: (context, i) => _levelTile(context, range.first + i),
                    ),
                  ),
              ],
            ),
          ),
        ),
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
                                  child: Text(s.label,
                                      style: Lux.ui(16, weight: FontWeight.w700, color: on ? Lux.goldLight : Lux.ink)),
                                ),
                                Text('${p.completed(g.id)}/${p.levelsFor(g.id)}',
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

  /// Segmented Kolay / Orta / Zor / Uzman selector with each tier's progress.
  Widget _tierSelector(Progress p) {
    final c = p.tierCount(game.id);
    return Row(
      children: [
        for (var t = 0; t < c; t++) ...[
          if (t > 0) const SizedBox(width: 8),
          Expanded(child: _tierChip(p, t)),
        ],
      ],
    );
  }

  Widget _tierChip(Progress p, int t) {
    final on = t == _tier;
    final r = p.tierRange(game.id, t);
    final count = r.last - r.first + 1;
    final done = p.tierCompleted(game.id, t);
    final radius = BorderRadius.circular(14);
    return Semantics(
      button: true,
      selected: on,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('tier-$t'),
          borderRadius: radius,
          onTap: () => _selectTier(t),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
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
            child: Column(
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(Progress.tierNames[t],
                      style: Lux.ui(15, weight: FontWeight.w700, color: on ? Lux.goldLight : Lux.ink)),
                ),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('$done/$count', style: Lux.ui(12.5, color: done == count ? Lux.goldLight : Lux.muted)),
                ),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.star_rounded, size: 13, color: on ? Lux.gold : Lux.muted),
                      const SizedBox(width: 2),
                      Text('${p.tierStars(game.id, t)}', style: Lux.ui(12, color: on ? Lux.gold : Lux.muted)),
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
          child: Text(Lux.upper('$g ${game.name}'), style: Lux.ui(12.5, color: Lux.gold, weight: FontWeight.w600, spacing: 1.8)),
        ));
      }
      group = g;
      out.add(_matchCard(context, m, title: g == null ? m.label : m.label.substring(i + 3)));
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
                  Text(m.description, style: Lux.ui(13.5, color: Lux.muted)),
                  const SizedBox(height: 6),
                  Text('Galibiyet ${r[0]} · Berabere ${r[1]} · Yenilgi ${r[2]}',
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
          Text('$sub · ${sections.length} ders', style: Lux.ui(13, color: Lux.muted)),
        ],
      ),
    );
  }

  Widget _levelTile(BuildContext context, int level) {
    final p = Progress.instance;
    final open = p.unlocked(game.id, level);
    final s = p.stars(game.id, level);
    return LuxCard(
      radius: 14,
      padding: const EdgeInsets.all(4),
      highlight: open && s == 0,
      onTap: open ? () => _play(level) : null,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          open
              ? Text('$level', style: Lux.ui(20, weight: FontWeight.w700, color: s > 0 ? Lux.goldLight : Lux.ink))
              : const Icon(Icons.lock_outline_rounded, color: Lux.muted, size: 18),
          const SizedBox(height: 4),
          StarRow(s, size: 11),
        ],
      ),
    );
  }
}
