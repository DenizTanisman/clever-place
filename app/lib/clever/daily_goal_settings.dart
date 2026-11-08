import 'package:flutter/material.dart';

import 'catalog.dart';
import 'daily_mix.dart';
import 'lux.dart';
import 'progress.dart';

/// Settings › "Günün hedefi": a collapsible card that picks which categories feed the daily mix and,
/// per category, optionally which of its games. Every change re-draws today's picks (they are derived
/// from the date and these settings).
class DailyGoalSettings extends StatefulWidget {
  const DailyGoalSettings({super.key});

  @override
  State<DailyGoalSettings> createState() => _DailyGoalSettingsState();
}

class _DailyGoalSettingsState extends State<DailyGoalSettings> {
  final Future<Progress> _progress = Progress.load();
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Progress>(
      future: _progress,
      builder: (context, snap) {
        final p = snap.data;
        if (p == null) return const SizedBox.shrink();
        return ListenableBuilder(listenable: p, builder: (context, _) => _card(p));
      },
    );
  }

  Widget _card(Progress p) {
    final s = DailySettings.of(p);
    final picks = dailyPicks(Progress.clock(), s);
    final summary = picks.isEmpty
        ? 'Kapalı: hiç kategori seçili değil'
        : '${picks.length} oyun · ${[for (final k in picks) k.category.label].join(', ')}';
    return LuxCard(
      highlight: _open,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: const ValueKey('daily-settings-header'),
            borderRadius: BorderRadius.circular(18),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              child: Row(
                children: [
                  const Icon(Icons.flag_outlined, color: Lux.gold, size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Günlük karışık', style: Lux.ui(16.5, weight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(summary, style: Lux.ui(13, color: Lux.muted)),
                      ],
                    ),
                  ),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(Icons.expand_more_rounded, color: Lux.gold),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _open ? _body(p, s) : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  Widget _body(Progress p, DailySettings s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 10, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Her gün açık kategorilerin her birinden rastgele bir oyun gelir; liste gün boyu aynı kalır, '
              'ertesi gün yenilenir. Bir değişiklik bugünün seçimini de yeniler.',
              style: Lux.ui(13, color: Lux.muted)),
          for (final c in dailyCategories) _category(p, s, c),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: GoldButton('Varsayılana dön',
                key: const ValueKey('daily-settings-reset'),
                icon: Icons.restart_alt_rounded,
                outlined: true,
                onPressed: p.resetDaily),
          ),
        ],
      ),
    );
  }

  Widget _category(Progress p, DailySettings s, GameCategory c) {
    final on = s.categories.contains(c);
    final games = dailyCandidates(c);
    // The limit as shown: only games that still exist; none of them = "Hepsi".
    final only = {for (final g in games) if (s.only[c]?.contains(g.id) ?? false) g.id};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Container(height: 1, color: Lux.lineFaint),
        Row(
          children: [
            Expanded(child: Text(c.label, style: Lux.ui(15.5, weight: FontWeight.w600, color: on ? Lux.ink : Lux.muted))),
            Switch(
              key: ValueKey('daily-cat-${c.name}'),
              value: on,
              onChanged: (v) {
                final cats = {...s.categories};
                v ? cats.add(c) : cats.remove(c);
                p.setDailyCategoryNames([for (final x in GameCategory.values) if (cats.contains(x)) x.name]);
              },
            ),
          ],
        ),
        if (on && games.length > 1) ...[
          Text('Sadece şu oyunlar:', style: Lux.ui(12.5, color: Lux.muted)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _pill('Hepsi', only.isEmpty, ValueKey('daily-all-${c.name}'), () => p.setDailyOnly(c.name, const [])),
              for (final g in games)
                _pill(g.name, only.contains(g.id), ValueKey('daily-only-${c.name}-${g.id}'), () {
                  final next = {...only};
                  if (!next.remove(g.id)) next.add(g.id);
                  // Every game ticked is the same as no limit.
                  p.setDailyOnly(c.name, next.length == games.length ? const [] : [for (final x in games) if (next.contains(x.id)) x.id]);
                }),
            ],
          ),
        ],
      ],
    );
  }

  Widget _pill(String label, bool on, Key key, VoidCallback onTap) {
    final radius = BorderRadius.circular(20);
    return Semantics(
      button: true,
      selected: on,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: key,
          borderRadius: radius,
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: radius,
              color: on ? Lux.gold.withValues(alpha: 0.16) : Colors.transparent,
              border: Border.all(color: on ? Lux.gold : Lux.line),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (on) ...[const Icon(Icons.check_rounded, size: 14, color: Lux.goldLight), const SizedBox(width: 4)],
                Text(label, style: Lux.ui(13, color: on ? Lux.goldLight : Lux.ink)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
