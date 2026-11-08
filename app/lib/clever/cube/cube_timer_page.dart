import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../lux.dart';
import 'cube_analysis_view.dart';
import 'cube_log.dart';
import 'cube_net.dart';
import 'cube_net_view.dart';
import 'cube_scrambles.dart';
import 'cube_style.dart';
import 'screen_awake.dart';

enum _Phase { idle, inspecting, holding, ready, running, done }

/// Küp zamanlayıcı. With a scramble: tap to start the 15 s inspection,
/// hold until green, let go to start, touch to stop. Without: hold, let
/// go, touch. After a stored 3x3 scramble the tips worked out for it are
/// one tap away.
class CubeTimerPage extends StatefulWidget {
  const CubeTimerPage({super.key, @visibleForTesting this.clock});

  /// Monotonic milliseconds; tests drive it by hand.
  final int Function()? clock;

  @override
  State<CubeTimerPage> createState() => _CubeTimerPageState();
}

class _CubeTimerPageState extends State<CubeTimerPage>
    with SingleTickerProviderStateMixin {
  static const _holdTime = Duration(milliseconds: 300);

  final _clock = Stopwatch()..start();
  late final Ticker _ticker;

  CubeLog _log = const CubeLog();
  bool _loaded = false;
  ScrambleBank _bank = const ScrambleBank([]);

  /// The scramble on screen and its place in [_bank] (null: random-move).
  String? _scramble;
  int? _index;

  _Phase _phase = _Phase.idle;

  /// Where a let-go-too-early hold returns to.
  _Phase _beforeHold = _Phase.idle;
  Timer? _holdTimer;
  bool _startInspectionOnUp = false;
  bool _ignoreUp = false;
  int _inspectAt = 0, _startAt = 0;
  bool _cue8 = false, _cue12 = false;
  CubeSolve? _last;
  bool _showNet = true;

  int get _now => widget.clock?.call() ?? _clock.elapsedMilliseconds;
  CubeSession get _session => _log.session;
  bool get _busy =>
      _phase == _Phase.running ||
      _phase == _Phase.inspecting ||
      ((_phase == _Phase.holding || _phase == _Phase.ready) &&
          _beforeHold == _Phase.inspecting);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => setState(() {}));
    ScreenAwake.on();
    _load();
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _ticker.dispose();
    ScreenAwake.off();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _log = CubeLog.decode(prefs.getString(CubeLog.storageKey));
    await _loadBank();
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _loadBank() async {
    _bank = await ScrambleBank.load(_session.bank);
    _pickScramble();
  }

  void _pickScramble() {
    if (_bank.list.isEmpty) {
      _index = null;
      _scramble = randomMoveScramble(_session.size);
      return;
    }
    final i = (_log.next[_session.bank] ?? 0) % _bank.list.length;
    _index = i;
    _scramble = _bank.list[i].moves;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(CubeLog.storageKey, _log.encode());
  }

  void _nextScramble() {
    if (_index != null) {
      _log = _log.advance(_session.bank, _bank.list.length);
      _save();
    }
    setState(_pickScramble);
  }

  Future<void> _setSession(CubeSession s) async {
    _log = _log.copyWith(session: s);
    _last = null;
    _phase = _Phase.idle;
    await _save();
    await _loadBank();
    if (mounted) setState(() {});
  }

  void _setScrambled(bool on) {
    setState(() {
      _log = _log.copyWith(scrambled: on);
      _last = null;
      _phase = _Phase.idle;
    });
    _save();
  }

  // ---- the timer --------------------------------------------------------

  void _onDown(PointerDownEvent _) {
    switch (_phase) {
      case _Phase.running:
        _stop();
      case _Phase.idle || _Phase.done:
        if (_log.scrambled) {
          _startInspectionOnUp = true;
        } else {
          _hold();
        }
      case _Phase.inspecting:
        _hold();
      case _Phase.holding || _Phase.ready:
        break; // a second finger
    }
  }

  void _onUp(PointerUpEvent _) {
    if (_ignoreUp) {
      _ignoreUp = false;
      return;
    }
    switch (_phase) {
      case _Phase.holding:
        _holdTimer?.cancel();
        setState(() => _phase = _beforeHold);
      case _Phase.ready:
        _start();
      case _Phase.idle || _Phase.done when _startInspectionOnUp:
        _startInspectionOnUp = false;
        _inspectAt = _now;
        _cue8 = _cue12 = false;
        _ticker.start();
        setState(() => _phase = _Phase.inspecting);
      default:
        break;
    }
  }

  void _hold() {
    _beforeHold = _phase;
    setState(() => _phase = _Phase.holding);
    _holdTimer?.cancel();
    _holdTimer = Timer(_holdTime, () {
      if (!mounted || _phase != _Phase.holding) return;
      HapticFeedback.selectionClick();
      setState(() => _phase = _Phase.ready);
    });
  }

  void _start() {
    _startAt = _now;
    if (!_ticker.isActive) _ticker.start();
    setState(() => _phase = _Phase.running);
  }

  void _stop() {
    final ms = _now - _startAt;
    _ticker.stop();
    _ignoreUp = true;
    HapticFeedback.mediumImpact();
    final inspected = _beforeHold == _Phase.inspecting;
    final solve = CubeSolve(
      session: _session,
      ms: ms,
      penalty: inspected
          ? inspectionPenalty(_startAt - _inspectAt)
          : Penalty.none,
      scramble: _log.scrambled ? _scramble : null,
      index: _log.scrambled ? _index : null,
      at: DateTime.now().millisecondsSinceEpoch,
    );
    _log = _log.add(solve);
    if (_log.scrambled) {
      if (_index != null) {
        _log = _log.advance(_session.bank, _bank.list.length);
      }
      _pickScramble();
    }
    _save();
    setState(() {
      _last = solve;
      _phase = _Phase.done;
    });
  }

  void _cancel() {
    _holdTimer?.cancel();
    _ticker.stop();
    setState(() => _phase = _last == null ? _Phase.idle : _Phase.done);
  }

  void _setPenalty(CubeSolve solve, Penalty? p) {
    final changed = p == null ? null : solve.withPenalty(p);
    setState(() {
      _log = _log.replace(solve.at, changed);
      if (_last?.at == solve.at) _last = changed;
      if (changed == null && _last == null) _phase = _Phase.idle;
    });
    _save();
  }

  // ---- what the big number shows ---------------------------------------

  ({String text, Color color, String hint}) _display() {
    final last = _last;
    switch (_phase) {
      case _Phase.running:
        return (
          text: formatCubeTime(_now - _startAt),
          color: Lux.ink,
          hint: 'Durdurmak için ekrana dokun',
        );
      case _Phase.inspecting:
        final t = _now - _inspectAt;
        if (t >= 8000 && !_cue8) {
          _cue8 = true;
          HapticFeedback.heavyImpact();
        }
        if (t >= 12000 && !_cue12) {
          _cue12 = true;
          HapticFeedback.heavyImpact();
        }
        final left = 15 - t ~/ 1000;
        return (
          text: t > 17000 ? 'DNF' : (t > 15000 ? '+2' : '$left'),
          color: t >= 12000 ? Lux.bad : Lux.gold,
          hint: t >= 12000
              ? '12 saniye! Basılı tut, yeşilde bırak'
              : t >= 8000
              ? '8 saniye. Basılı tut, yeşilde bırak'
              : 'İnceleme · hazır olunca basılı tut, yeşilde bırak',
        );
      case _Phase.holding:
        return (
          text: _beforeHold == _Phase.inspecting
              ? '${15 - (_now - _inspectAt) ~/ 1000}'
              : formatCubeTime(0),
          color: Lux.bordeauxLight,
          hint: 'Bekle…',
        );
      case _Phase.ready:
        return (
          text: formatCubeTime(0),
          color: Lux.good,
          hint: 'Bırak!',
        );
      case _Phase.done when last != null:
        return (
          text: formatSolve(last),
          color: Lux.ink,
          hint: _log.scrambled
              ? 'Yeni karıştırma hazır · dokun, inceleme başlasın'
              : 'Basılı tut, yeşilde bırak',
        );
      default:
        return (
          text: formatCubeTime(0),
          color: Lux.muted,
          hint: _log.scrambled
              ? 'Karıştır, sonra dokun: 15 sn inceleme başlar'
              : 'Basılı tut, yeşil olunca bırak',
        );
    }
  }

  StoredScramble? _storedFor(CubeSolve s) {
    final i = s.index;
    if (i == null || s.session.size != 3) return null;
    // Only if the list is still the one the solve was made from.
    if (i >= _bank.list.length || _bank.list[i].moves != s.scramble) {
      return null;
    }
    return _bank.list[i];
  }

  void _openAnalysis(CubeSolve s) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scroll) =>
          CubeAnalysisView(solve: s, stored: _storedFor(s), controller: scroll),
    ),
  );

  void _openHistory() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => StatefulBuilder(
      builder: (context, setSheet) {
        final list = _log.of(_session).reversed.toList();
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 0.95,
          builder: (context, scroll) => list.isEmpty
              ? const Center(child: Text('Bu oturumda henüz çözüm yok.'))
              : ListView.builder(
                  controller: scroll,
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final s = list[i];
                    final at = DateTime.fromMillisecondsSinceEpoch(s.at);
                    return ListTile(
                      leading: Text(
                        '${list.length - i}',
                        style: const TextStyle(color: Lux.muted),
                      ),
                      title: Text(
                        formatSolve(s),
                        style: const TextStyle(
                          fontFeatures: [FontFeature.tabularFigures()],
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      subtitle: Text(
                        '${_two(at.day)}.${_two(at.month)} '
                        '${_two(at.hour)}:${_two(at.minute)}'
                        '${s.scramble == null ? ' · sadece süre' : ''}',
                      ),
                      trailing: PopupMenuButton<Penalty?>(
                        onSelected: (p) {
                          _setPenalty(s, p);
                          setSheet(() {});
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: Penalty.none,
                            child: Text('Ceza yok'),
                          ),
                          PopupMenuItem(
                            value: Penalty.plus2,
                            child: Text('+2'),
                          ),
                          PopupMenuItem(value: Penalty.dnf, child: Text('DNF')),
                          PopupMenuItem(value: null, child: Text('Sil')),
                        ],
                      ),
                      onTap: s.scramble == null ? null : () => _openAnalysis(s),
                    );
                  },
                ),
        );
      },
    ),
  );

  static String _two(int v) => v.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final shown = _display();
    final solves = _log.of(_session);
    final calm = !_busy;
    return CubeTheme(
      child: Scaffold(
      backgroundColor: Lux.bg0,
      body: LuxBackground(
        child: !_loaded
            ? const SizedBox.shrink()
            : SafeArea(
                child: Column(
                  children: [
                    CubeHeader(
                      'Zamanlayıcı',
                      action: _busy
                          ? TextButton(onPressed: _cancel, child: const Text('İptal'))
                          : IconButton(
                              tooltip: 'Geçmiş',
                              onPressed: _openHistory,
                              icon: const Icon(Icons.history, color: Lux.gold),
                            ),
                    ),
                    if (calm) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                        child: SegmentedButton<CubeSession>(
                          segments: [
                            for (final s in CubeSession.values)
                              ButtonSegment(value: s, label: Text(s.label)),
                          ],
                          selected: {_session},
                          showSelectedIcon: false,
                          onSelectionChanged: (v) => _setSession(v.first),
                        ),
                      ),
                      SwitchListTile(
                        dense: true,
                        title: const Text('Karıştırma + 15 sn inceleme'),
                        subtitle: Text(
                          _log.scrambled
                              ? 'Yarışmadaki gibi'
                              : 'Sadece süre: basılı tut, bırak, dokun',
                        ),
                        value: _log.scrambled,
                        onChanged: _setScrambled,
                      ),
                      if (_log.scrambled && _scramble != null)
                        _ScrambleCard(
                          scramble: _scramble!,
                          size: _session.size,
                          number: _index == null
                              ? 'rastgele'
                              : '#${_index! + 1} / ${_bank.list.length}',
                          showNet: _showNet,
                          onToggleNet: () =>
                              setState(() => _showNet = !_showNet),
                          onNext: _nextScramble,
                        ),
                    ],
                    Expanded(
                      child: Listener(
                        key: const Key('cube-pad'),
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: _onDown,
                        onPointerUp: _onUp,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              FittedBox(
                                child: Text(
                                  shown.text,
                                  style: Lux.numeral(92, color: shown.color).copyWith(
                                    fontFeatures: const [FontFeature.tabularFigures()],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                shown.hint,
                                textAlign: TextAlign.center,
                                style: Lux.ui(15, color: Lux.muted),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (calm && _phase == _Phase.done && _last != null)
                      _AfterSolve(
                        solve: _last!,
                        hasTips: _last!.scramble != null,
                        onPenalty: (p) => _setPenalty(_last!, p),
                        onTips: () => _openAnalysis(_last!),
                      ),
                    if (calm) _Stats(solves: solves),
                  ],
                ),
              ),
      ),
      ),
    );
  }
}

class _ScrambleCard extends StatelessWidget {
  const _ScrambleCard({
    required this.scramble,
    required this.size,
    required this.number,
    required this.showNet,
    required this.onToggleNet,
    required this.onNext,
  });

  final String scramble;
  final int size;
  final String number;
  final bool showNet;
  final VoidCallback onToggleNet, onNext;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: LuxCard(
        radius: 14,
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Karıştırma $number · beyaz üst, yeşil ön',
                    maxLines: 2,
                    style: Lux.ui(12.5, color: Lux.muted),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: showNet ? 'Şemayı gizle' : 'Şemayı göster',
                  onPressed: onToggleNet,
                  icon: Icon(
                    showNet ? Icons.grid_off_outlined : Icons.grid_on_outlined,
                    color: Lux.gold,
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Sıradaki karıştırma',
                  onPressed: onNext,
                  icon: const Icon(Icons.skip_next, color: Lux.gold),
                ),
              ],
            ),
            SelectableText(
              scramble,
              style: cubeMoves(17),
            ),
            if (showNet) ...[
              const SizedBox(height: 8),
              Center(
                child: SizedBox(
                  width: 220,
                  child: CubeNetView(size: size, scramble: scramble),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AfterSolve extends StatelessWidget {
  const _AfterSolve({
    required this.solve,
    required this.hasTips,
    required this.onPenalty,
    required this.onTips,
  });

  final CubeSolve solve;
  final bool hasTips;
  final ValueChanged<Penalty?> onPenalty;
  final VoidCallback onTips;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 6,
        children: [
          ChoiceChip(
            label: const Text('+2'),
            selected: solve.penalty == Penalty.plus2,
            onSelected: (on) => onPenalty(on ? Penalty.plus2 : Penalty.none),
          ),
          ChoiceChip(
            label: const Text('DNF'),
            selected: solve.penalty == Penalty.dnf,
            onSelected: (on) => onPenalty(on ? Penalty.dnf : Penalty.none),
          ),
          ActionChip(
            avatar: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Sil'),
            onPressed: () => onPenalty(null),
          ),
          if (hasTips)
            ActionChip(
              avatar: const Icon(Icons.lightbulb_outline, size: 18),
              label: const Text('Bu karıştırma için taktikler'),
              onPressed: onTips,
            ),
        ],
      ),
    );
  }
}

class _Stats extends StatelessWidget {
  const _Stats({required this.solves});

  final List<CubeSolve> solves;

  @override
  Widget build(BuildContext context) {
    Widget cell(String label, String value) => Expanded(
      child: Column(
        children: [
          Text(Lux.upper(label), style: Lux.ui(10, color: Lux.muted, spacing: 1.6)),
          const SizedBox(height: 3),
          Text(value, style: Lux.numeral(20)),
        ],
      ),
    );
    final best = bestOf(solves);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 12),
      child: Row(
        children: [
          cell('çözüm', '${solves.length}'),
          cell('en iyi', best == null ? '–' : formatCubeTime(best)),
          cell('ao5', formatAverage(averageOf(solves, 5))),
          cell('ao12', formatAverage(averageOf(solves, 12))),
          cell('ao100', formatAverage(averageOf(solves, 100))),
        ],
      ),
    );
  }
}
