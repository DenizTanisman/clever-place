import 'package:flutter/material.dart';

import 'catalog.dart';
import 'core_bridge.dart';
import 'daily_mix.dart';
import 'lux.dart';
import 'progress.dart';

/// Shared in-game shell: top bar, goal line, the game's own board widget, inline error toast and the
/// end-of-level result card. Game views only draw the board and send actions.
///
/// Conventions every game state may use: `status`, `stars`, `title` (variant name), `goal`,
/// `score` (endless best), `summary` (one line on the result card).
class PlayScreen extends StatefulWidget {
  final GameInfo game;
  final int level;
  final String mode;

  /// Started from "Günün hedefi": a win offers the day's next pick.
  final bool daily;
  const PlayScreen({super.key, required this.game, required this.level, this.mode = 'level', this.daily = false});

  @override
  State<PlayScreen> createState() => _PlayScreenState();
}

class _PlayScreenState extends State<PlayScreen> {
  late GameSession _s;
  bool _recorded = false;
  bool _newBest = false;
  bool _showResult = false;
  int _shownError = 0;
  String? _toast;

  bool get _match => widget.game.matchModes.isNotEmpty;
  bool get _endless => widget.mode != 'level' && !_match;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  void _boot() {
    _s = GameSession(game: widget.game.id, level: widget.level, mode: widget.mode)..addListener(_onChange);
    _recorded = false;
    _newBest = false;
    _showResult = false;
    _s.start();
    Progress.instance.recordPlay(widget.game.id, widget.level, widget.mode);
  }

  void _restart() {
    _s.removeListener(_onChange);
    _s.dispose();
    setState(_boot);
  }

  void _onChange() {
    if (_s.errorSerial != _shownError) {
      _shownError = _s.errorSerial;
      _toast = _s.lastError;
      Future.delayed(const Duration(milliseconds: 1600), () {
        if (mounted && _shownError == _s.errorSerial) setState(() => _toast = null);
      });
    }
    if (_s.finished && !_recorded) {
      _recorded = true;
      if (_match) {
        Progress.instance.recordMatch(widget.game.id, widget.mode, _s.status);
      } else if (_endless) {
        final score = (_s.state['score'] as num?)?.toInt() ?? 0;
        Progress.instance.recordBest(widget.game.id, score).then((b) {
          if (mounted) setState(() => _newBest = b);
        });
      } else if (_s.status == 'won') {
        Progress.instance.recordStars(widget.game.id, widget.level, _s.stars);
      }
      if (_s.status == 'won' || _endless) {
        Progress.instance.recordWin(widget.game.id, level: _s.status == 'won' && !_endless);
      }
      // Let the winning move finish its animation (and the board its celebration) first.
      final session = _s;
      // Duel games end on a move that may travel a long path (Surakarta loops), so give them longer.
      final duel = (widget.game.category == GameCategory.strategy && !widget.game.speed) || _match;
      final delay = _s.status == 'won' ? (duel ? 2300 : 1250) : (duel ? 1800 : 600);
      Future.delayed(Duration(milliseconds: delay), () {
        if (mounted && identical(session, _s) && _s.finished) setState(() => _showResult = true);
      });
    }
    // Only rebuild the shell when something the shell shows changed; the board has its own
    // ListenableBuilder, so per-frame ticks don't rebuild the top bar and overlays.
    final sig = '${_s.loading}|${_s.fatal}|${_s.status}|${_s.state['title']}|${_s.state['goal']}|$_toast';
    if (sig != _shellSig && mounted) {
      _shellSig = sig;
      setState(() {});
    }
  }

  String _shellSig = '';

  @override
  void dispose() {
    _s.removeListener(_onChange);
    _s.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = _s.state;
    final title = _match
        ? widget.game.matchModes.firstWhere((m) => m.id == widget.mode, orElse: () => widget.game.matchModes.first).label
        : _endless
            ? widget.game.endlessLabel
            : 'Bölüm ${widget.level}';
    return Scaffold(
      backgroundColor: Lux.bg0,
      body: LuxBackground(
        child: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 6, 8, 0),
                    child: Row(
                      children: [
                        IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back, color: Lux.ink)),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(widget.game.name, style: Lux.ui(13, color: Lux.muted, spacing: 1.2)),
                              Text(title, style: Lux.display(24, color: Lux.ink, italic: true)),
                            ],
                          ),
                        ),
                        if (st['title'] is String)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: Lux.line),
                            ),
                            child: Text(st['title'] as String, style: Lux.ui(12, color: Lux.goldLight)),
                          ),
                        IconButton(onPressed: _restart, icon: const Icon(Icons.refresh_rounded, color: Lux.gold)),
                      ],
                    ),
                  ),
                  if (st['goal'] is String)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                      child: Text(st['goal'] as String,
                          textAlign: TextAlign.center, style: Lux.ui(14, color: Lux.muted, weight: FontWeight.w500)),
                    ),
                  Expanded(
                    child: _s.loading
                        ? const Center(child: CircularProgressIndicator(color: Lux.gold))
                        : _s.fatal != null
                            ? Center(child: Text(_s.fatal!, style: Lux.ui(16, color: Lux.bad)))
                            : ListenableBuilder(
                                listenable: _s,
                                builder: (context, _) => widget.game.view?.call(context, _s) ?? const SizedBox(),
                              ),
                  ),
                ],
              ),
              // Inline error toast (illegal move).
              Positioned(
                left: 24,
                right: 24,
                bottom: 24,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: _toast == null ? 0 : 1,
                    duration: const Duration(milliseconds: 200),
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xEE2A0F17),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Lux.bordeaux),
                        ),
                        child: Text(_toast ?? '', style: Lux.ui(15, color: const Color(0xFFFFD6DF))),
                      ),
                    ),
                  ),
                ),
              ),
              if (_s.finished && _showResult) _resultCard(context),
            ],
          ),
        ),
      ),
    );
  }

  void _goTo(int level) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => PlayScreen(game: widget.game, level: level, daily: widget.daily)),
    );
  }

  Widget _resultCard(BuildContext context) {
    final won = _s.status == 'won';
    final draw = _s.status == 'draw';
    final st = _s.state;
    // Levels move within the current difficulty tier; at a tier's end the card offers the next tier.
    final p = Progress.instance;
    final id = widget.game.id;
    final levels = !_endless && !_match;
    final tier = p.tierOf(id, widget.level);
    final range = p.tierRange(id, tier);
    final hasPrev = levels && widget.level > range.first;
    final hasNext = levels && won && widget.level < range.last;
    final nextTier = levels && won && widget.level == range.last && tier + 1 < p.tierCount(id) ? tier + 1 : null;
    // "Günün hedefi": after a win, the day's next pick (or the goal reached).
    final daily = widget.daily && won;
    final dailyNext = daily ? DailyMix.next(p) : null;
    return Positioned.fill(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutBack,
        builder: (context, t, child) => ColoredBox(
          color: Colors.black.withValues(alpha: 0.6 * t.clamp(0, 1)),
          child: Center(child: Transform.scale(scale: 0.85 + 0.15 * t, child: Opacity(opacity: t.clamp(0, 1), child: child))),
        ),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: LuxCard(
            highlight: true,
            padding: const EdgeInsets.fromLTRB(24, 26, 24, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(Lux.upper(_match
                        ? (won ? 'Kazandın' : draw ? 'Berabere' : 'Kaybettin')
                        : won ? 'Tebrikler' : draw ? 'Berabere' : (_endless ? 'Oyun bitti' : 'Olmadı')),
                    style: Lux.display(26, color: won ? Lux.gold : draw ? Lux.goldLight : Lux.bordeauxLight)),
                const SizedBox(height: 14),
                if (!_endless && !_match && won) _PoppingStars(_s.stars, size: 40),
                if (_endless) ...[
                  Text('${(st['score'] as num?)?.toInt() ?? 0}', style: Lux.display(40, color: Lux.goldLight)),
                  Text(_newBest ? 'Yeni rekor!' : 'Rekor: ${Progress.instance.best(widget.game.id)}',
                      style: Lux.ui(15, color: _newBest ? Lux.good : Lux.muted)),
                ],
                if (st['summary'] is String) ...[
                  const SizedBox(height: 12),
                  Text(st['summary'] as String, textAlign: TextAlign.center, style: Lux.ui(15, color: Lux.ink)),
                ],
                if (daily && dailyNext == null) ...[
                  const SizedBox(height: 12),
                  Text('Günün hedefi tamam!', textAlign: TextAlign.center, style: Lux.ui(15, color: Lux.good)),
                ],
                const SizedBox(height: 22),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    GoldButton(_match ? 'Masalar' : 'Bölümler', outlined: true, onPressed: () => Navigator.pop(context)),
                    if (hasPrev)
                      GoldButton('Önceki', icon: Icons.arrow_back_rounded, outlined: true, onPressed: () => _goTo(widget.level - 1)),
                    GoldButton(_match ? 'Yeni el' : 'Tekrar',
                        icon: Icons.refresh_rounded,
                        outlined: hasNext || nextTier != null || dailyNext != null,
                        onPressed: _restart),
                    if (hasNext)
                      GoldButton('Sonraki',
                          icon: Icons.arrow_forward_rounded,
                          outlined: dailyNext != null,
                          onPressed: () => _goTo(widget.level + 1)),
                    if (dailyNext != null)
                      GoldButton('Sıradaki: ${dailyNext.game.name}',
                          key: const ValueKey('daily-next'),
                          icon: Icons.arrow_forward_rounded,
                          onPressed: () => Navigator.pushReplacement(context, DailyMix.route(p, dailyNext.game))),
                    if (nextTier != null)
                      GoldButton('${Progress.tierDative[nextTier]} geç',
                          icon: Icons.arrow_forward_rounded, outlined: dailyNext != null, onPressed: () {
                        // The next tier's first unwon level (its first two are always open).
                        p.setTier(id, nextTier);
                        _goTo(p.firstUnwonIn(id, nextTier) ?? p.tierRange(id, nextTier).first);
                      }),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


/// Result stars that pop in one after another with a springy overshoot.
class _PoppingStars extends StatelessWidget {
  final int stars;
  final double size;
  const _PoppingStars(this.stars, {required this.size});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        final on = i < stars;
        final icon = Icon(Icons.star_rounded, size: size, color: on ? Colors.white : Lux.muted.withValues(alpha: 0.28));
        final star = on
            ? ShaderMask(blendMode: BlendMode.srcIn, shaderCallback: (r) => Lux.foil.createShader(r), child: icon)
            : icon;
        if (!on) return star;
        return TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: Duration(milliseconds: 380 + 260 * i),
          builder: (context, t, child) {
            final local = ((t * (380 + 260 * i) - 260 * i - 150) / 380).clamp(0.0, 1.0);
            final e = Curves.elasticOut.transform(local);
            return Transform.rotate(angle: (1 - local) * -0.6, child: Transform.scale(scale: e, child: child));
          },
          child: star,
        );
      }),
    );
  }
}
