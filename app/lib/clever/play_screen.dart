import 'package:flutter/material.dart';

import 'catalog.dart';
import 'core_bridge.dart';
import 'daily_mix.dart';
import 'level_result.dart';
import 'lux.dart';
import 'progress.dart';
import 'i18n/lang.dart';

/// The levels before and after [level] in [list]; null past either end.
({int? prev, int? next}) levelNeighbours(List<int> list, int level) {
  final i = list.indexOf(level);
  return (prev: i > 0 ? list[i - 1] : null, next: i >= 0 && i + 1 < list.length ? list[i + 1] : null);
}

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

  /// The levels "Önceki" / "Sonraki" walk through, in order (Doğru Söz: the chosen sub-category).
  /// Null: the level's difficulty tier.
  final List<int>? levels;
  const PlayScreen(
      {super.key, required this.game, required this.level, this.mode = 'level', this.daily = false, this.levels});

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

  /// Wall clock of the current attempt: the level's time when the game reports none of its own.
  final Stopwatch _watch = Stopwatch();

  /// The finished attempt's time (ms), the tier's best before it, and whether the time is stored.
  int? _timeMs;
  int? _prevBest;
  bool _timeSaved = false;

  /// A free match of a level game (XOX), as opposed to a card game's table.
  bool get _freeMatch => widget.game.matchTitle != null && widget.mode != 'level';
  bool get _match => widget.game.matchModes.isNotEmpty || _freeMatch;
  bool get _endless => widget.mode != 'level' && !_match;

  /// A plain level (not a match, not endless) of a game without its own result card: these end on the
  /// full-screen result ([_levelResult]); the rest keep the compact card.
  bool get _levelScreen => !_endless && !_match && widget.game.resultCard == null;

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
    _timeMs = null;
    _prevBest = null;
    _timeSaved = false;
    _watch
      ..reset()
      ..start();
    _s.start();
    Progress.instance.recordPlay(widget.game.id, widget.level, widget.mode);
  }

  /// The attempt's time: the game's own clock when it keeps one (`elapsed_ms`, or Sudoku's `elapsed`
  /// in seconds; Schulte's includes its penalties), else the wall clock.
  int _measuredTime(Map<String, dynamic> st) {
    final ms = st['elapsed_ms'];
    if (ms is num && ms > 0) return ms.round();
    final s = st['elapsed'];
    if (s is num && s > 0) return (s * 1000).round();
    return _watch.elapsedMilliseconds;
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
      _watch.stop();
      _timeMs = _measuredTime(_s.state);
      if (!_endless && !_match && _s.status == 'won') {
        final session = _s;
        Progress.instance.recordTime(widget.game.id, widget.level, _timeMs!).then((before) {
          if (mounted && identical(session, _s)) {
            setState(() {
              _prevBest = before;
              _timeSaved = true;
            });
          }
        });
      }
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
    final title = _freeMatch
        ? ct(widget.game.matchTitle!(widget.mode))
        : _match
        ? t(widget.game.matchModes.firstWhere((m) => m.id == widget.mode, orElse: () => widget.game.matchModes.first).label)
        : _endless
            ? t(widget.game.endlessLabel)
            : tf('Bölüm {0}', [widget.level]);
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
                              Text(t(widget.game.name), style: Lux.ui(13, color: Lux.muted, spacing: 1.2)),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(title, maxLines: 1, style: Lux.display(24, color: Lux.ink, italic: true)),
                              ),
                            ],
                          ),
                        ),
                        if (st['title'] is String)
                          Container(
                            constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.3),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: Lux.line),
                            ),
                            child: Text(ct(st['title'] as String),
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: Lux.ui(12, color: Lux.goldLight)),
                          ),
                        if (widget.game.infoPage case final page?)
                          IconButton(
                            tooltip: t(widget.game.infoLabel),
                            onPressed: () => Navigator.push(
                                context, MaterialPageRoute(builder: (c) => page(c, _s.state))),
                            icon: const Icon(Icons.info_outline_rounded, color: Lux.gold),
                          ),
                        IconButton(onPressed: _restart, icon: const Icon(Icons.refresh_rounded, color: Lux.gold)),
                      ],
                    ),
                  ),
                  if (st['goal'] is String)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                      child: Text(ct(st['goal'] as String),
                          textAlign: TextAlign.center, style: Lux.ui(14, color: Lux.muted, weight: FontWeight.w500)),
                    ),
                  Expanded(
                    child: _s.loading
                        ? const Center(child: CircularProgressIndicator(color: Lux.gold))
                        : _s.fatal != null
                            ? Center(child: Text(ct(_s.fatal!), style: Lux.ui(16, color: Lux.bad)))
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
                        child: Text(ct(_toast ?? ''), style: Lux.ui(15, color: const Color(0xFFFFD6DF))),
                      ),
                    ),
                  ),
                ),
              ),
              if (_s.finished && _showResult) _levelScreen ? _levelResult(context) : _resultCard(context),
            ],
          ),
        ),
      ),
    );
  }

  void _goTo(int level) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
          builder: (_) => PlayScreen(game: widget.game, level: level, daily: widget.daily, levels: widget.levels)),
    );
  }

  /// Where the result can lead. Levels move within the given list, or else within the current
  /// difficulty tier; at a tier's end a win offers the next tier. "Günün hedefi": after a win, the
  /// day's next pick (null when the goal is reached).
  ({int? prev, int? next, int? nextTier, bool daily, DailyPick? dailyNext}) _nav() {
    final won = _s.status == 'won';
    final p = Progress.instance;
    final id = widget.game.id;
    final levels = !_endless && !_match;
    final tier = p.tierOf(id, widget.level);
    final range = p.tierRange(id, tier);
    final inList = widget.levels?.contains(widget.level) ?? false;
    final around = inList ? levelNeighbours(widget.levels!, widget.level) : null;
    final prevLevel = inList ? around!.prev : (widget.level > range.first ? widget.level - 1 : null);
    final nextLevel = inList ? around!.next : (widget.level < range.last ? widget.level + 1 : null);
    final nextTier =
        levels && won && !inList && widget.level == range.last && tier + 1 < p.tierCount(id) ? tier + 1 : null;
    final daily = widget.daily && won;
    return (
      prev: levels ? prevLevel : null,
      next: levels && won ? nextLevel : null,
      nextTier: nextTier,
      daily: daily,
      dailyNext: daily ? DailyMix.next(p) : null,
    );
  }

  /// Opens the first unwon level of [tier] (its first two are always open).
  void _goToTier(int tier) {
    final p = Progress.instance;
    final id = widget.game.id;
    p.setTier(id, tier);
    _goTo(p.firstUnwonIn(id, tier) ?? p.tierRange(id, tier).first);
  }

  /// End of a plain level: decides the actions, [LevelResultView] draws them.
  Widget _levelResult(BuildContext context) {
    final won = _s.status == 'won';
    final nav = _nav();
    final p = Progress.instance;

    // The main action: the day's next pick, the next level, the next tier, or another try.
    final String mainLabel;
    final VoidCallback mainAction;
    var retryIsMain = false;
    if (nav.dailyNext case final pick?) {
      mainLabel = tf('Sıradaki: {0}', [t(pick.game.name)]);
      mainAction = () => Navigator.pushReplacement(context, DailyMix.route(p, pick.game));
    } else if (nav.next case final n?) {
      mainLabel = tf('Sonraki bölüm · {0}', [n]);
      mainAction = () => _goTo(n);
    } else if (nav.nextTier case final nt?) {
      mainLabel = tf('{0} geç', [Lang.en ? t(Progress.tierNames[nt]) : Progress.tierDative[nt]]);
      mainAction = () => _goToTier(nt);
    } else {
      mainLabel = won ? t('Tekrar oyna') : t('Tekrar dene');
      mainAction = _restart;
      retryIsMain = true;
    }
    final more = <ResultAction>[
      if (!retryIsMain) (label: t('Tekrar oyna'), onPressed: _restart),
      if (nav.dailyNext != null && nav.next != null) (label: t('Sonraki'), onPressed: () => _goTo(nav.next!)),
      (label: widget.daily ? t('Çık') : t('Bölümler'), onPressed: () => Navigator.pop(context)),
      if (nav.prev case final prev?) (label: t('Önceki'), onPressed: () => _goTo(prev)),
    ].take(3).toList();

    return Positioned.fill(
      child: LevelResultView(
        gameId: widget.game.id,
        gameName: t(widget.game.name),
        level: widget.level,
        won: won,
        stars: _s.stars,
        state: _s.state,
        timeMs: _timeMs ?? 0,
        bestBefore: _prevBest,
        timeSaved: _timeSaved,
        daily: widget.daily,
        mainLabel: mainLabel,
        mainIcon: retryIsMain ? Icons.refresh_rounded : Icons.arrow_forward_rounded,
        mainIconAfter: !retryIsMain,
        mainKey: nav.dailyNext != null ? const ValueKey('daily-next') : const ValueKey('result-main'),
        onMain: mainAction,
        more: more,
        onClose: () => Navigator.pop(context),
      ),
    );
  }

  Widget _resultCard(BuildContext context) {
    final won = _s.status == 'won';
    final draw = _s.status == 'draw';
    final st = _s.state;
    final p = Progress.instance;
    final nav = _nav();
    final prevLevel = nav.prev;
    final nextLevel = nav.next;
    final hasPrev = prevLevel != null;
    final hasNext = nextLevel != null;
    final nextTier = nav.nextTier;
    final daily = nav.daily;
    final dailyNext = nav.dailyNext;
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
                if (widget.game.resultCard case final card?)
                  card(context, st)
                else
                  Text(Lux.upper(_match
                          ? t(won ? 'Kazandın' : draw ? 'Berabere' : 'Kaybettin')
                          : t(won ? 'Tebrikler' : draw ? 'Berabere' : (_endless ? 'Oyun bitti' : 'Olmadı'))),
                      style: Lux.display(26, color: won ? Lux.gold : draw ? Lux.goldLight : Lux.bordeauxLight)),
                const SizedBox(height: 14),
                if (!_endless && !_match && won) _PoppingStars(_s.stars, size: 40),
                if (_endless) ...[
                  Text('${(st['score'] as num?)?.toInt() ?? 0}', style: Lux.display(40, color: Lux.goldLight)),
                  Text(_newBest ? t('Yeni rekor!') : tf('Rekor: {0}', [Progress.instance.best(widget.game.id)]),
                      style: Lux.ui(15, color: _newBest ? Lux.good : Lux.muted)),
                ],
                if (st['summary'] is String) ...[
                  const SizedBox(height: 12),
                  Text(ct(st['summary'] as String), textAlign: TextAlign.center, style: Lux.ui(15, color: Lux.ink)),
                ],
                if (daily && dailyNext == null) ...[
                  const SizedBox(height: 12),
                  Text(t('Günün hedefi tamam!'), textAlign: TextAlign.center, style: Lux.ui(15, color: Lux.good)),
                ],
                const SizedBox(height: 22),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    GoldButton(t(_freeMatch ? 'Oyun sayfası' : _match ? 'Masalar' : 'Bölümler'), outlined: true, onPressed: () => Navigator.pop(context)),
                    if (hasPrev)
                      GoldButton(t('Önceki'), icon: Icons.arrow_back_rounded, outlined: true, onPressed: () => _goTo(prevLevel)),
                    GoldButton(t(_freeMatch ? 'Yeni maç' : _match ? 'Yeni el' : 'Tekrar'),
                        icon: Icons.refresh_rounded,
                        outlined: hasNext || nextTier != null || dailyNext != null,
                        onPressed: _restart),
                    if (hasNext)
                      GoldButton(t('Sonraki'),
                          icon: Icons.arrow_forward_rounded,
                          outlined: dailyNext != null,
                          onPressed: () => _goTo(nextLevel)),
                    if (dailyNext != null)
                      GoldButton(tf('Sıradaki: {0}', [t(dailyNext.game.name)]),
                          key: const ValueKey('daily-next'),
                          icon: Icons.arrow_forward_rounded,
                          onPressed: () => Navigator.pushReplacement(context, DailyMix.route(p, dailyNext.game))),
                    if (nextTier != null)
                      GoldButton(tf('{0} geç', [Lang.en ? t(Progress.tierNames[nextTier]) : Progress.tierDative[nextTier]]),
                          icon: Icons.arrow_forward_rounded,
                          outlined: dailyNext != null,
                          onPressed: () => _goToTier(nextTier)),
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
