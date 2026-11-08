import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// Kelime Listesi board. Rust runs the script (study → recall / recognition / distractor) and the
/// clock; this widget renders the current phase and sends taps and typed words.
///
/// Phases: intro card · 3-2-1 countdown with a banner · study (one big word at a time, fading in
/// and out on the core's slot clock) · recall (chips of typed words, Turkish keyboard, time bar) ·
/// recognition (Evet / Hayır) · distractor (sum checks) · review (serial-position chart, learning
/// curve, intrusions) → Bitir.
///
Widget wordListView(BuildContext context, GameSession s) => _WordListBoard(key: ObjectKey(s), session: s);

const _activePhases = {'countdown', 'study', 'recall', 'distract', 'feedback'};

class _WordListBoard extends StatefulWidget {
  final GameSession session;
  const _WordListBoard({super.key, required this.session});

  @override
  State<_WordListBoard> createState() => _WordListBoardState();
}

class _WordListBoardState extends State<_WordListBoard> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;

  String _input = '';
  int _entriesSeen = 0;
  double _entryAt = -10;
  String _entryResult = '';
  int _recSeen = 0;
  double _recAt = -10;
  bool _recOk = true;

  GameSession get s => widget.session;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    s.addListener(_onSession);
  }

  @override
  void dispose() {
    s.removeListener(_onSession);
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1000.0;
    _last = elapsed;
    final phase = s.state['phase'];
    if (!s.finished && _activePhases.contains(phase)) {
      s.tick(dt);
    } else if (_now - _entryAt < 0.6 || _now - _recAt < 0.6) {
      setState(() {});
    }
  }

  void _onSession() {
    final st = s.state;
    final recall = st['recall'];
    final n = recall is Map ? (recall['entries'] as List).length : 0;
    if (n > _entriesSeen) {
      final e = (recall as Map)['entries'][n - 1] as Map;
      _entryResult = e['result'] as String? ?? '';
      _entryAt = _now;
      if (_entryResult == 'ok') {
        HapticFeedback.lightImpact();
      } else if (_entryResult != 'skip') {
        HapticFeedback.mediumImpact();
      }
    }
    _entriesSeen = n;
    final rec = st['recognize'];
    final last = rec is Map ? rec['last'] : null;
    if (last is Map) {
      final serial = (last['serial'] as num).toInt();
      if (serial != _recSeen) {
        _recSeen = serial;
        _recAt = _now;
        _recOk = last['correct'] == true;
        _recOk ? HapticFeedback.lightImpact() : HapticFeedback.mediumImpact();
      }
    }
  }

  void _submit() {
    if (_input.trim().isEmpty) return;
    if (s.act({'word': _input})) setState(() => _input = '');
  }

  @override
  Widget build(BuildContext context) {
    final st = s.state;
    final phase = st['phase'] as String? ?? 'intro';
    final Widget body = switch (phase) {
      'intro' => _intro(st),
      'countdown' => PhaseCountdown(st['countdown'] as Map? ?? const {}),
      'study' => _study(st['study'] as Map? ?? const {}),
      'recall' => _recall(st['recall'] as Map? ?? const {}),
      'recognize' => _recognize(st['recognize'] as Map? ?? const {}),
      'distract' => DistractPanel(st['distract'] as Map? ?? const {}, onJudge: (v) => s.act({'judge': v})),
      _ => _review(st),
    };
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, a) => FadeTransition(
        opacity: a,
        child: ScaleTransition(scale: Tween(begin: 0.97, end: 1.0).animate(a), child: child),
      ),
      child: KeyedSubtree(key: ValueKey('$phase-${st['step']}'), child: body),
    );
  }

  // ------------------------------------------------------------------ intro

  Widget _intro(Map<String, dynamic> st) {
    const texts = {
      'free': 'Kelimeler tek tek gelecek. Liste bitince aklında kalanları istediğin sırayla yaz.',
      'serial':
          'Kelimeler tek tek gelecek. Sonra onları aynı sırayla yaz: her kelime kendi sırasında sayılır. Hatırlamadığın sırayı "Boş geç" ile atla.',
      'learning':
          'Aynı liste üç kez gelecek; her seferinde hatırladıklarını yaz. Sonunda öğrenme eğrin çizilir, yıldızlar son denemeden.',
      'recognition':
          'Liste bitince kelimeler tek tek sorulacak: listede var mıydı? Yarısı listedekilere çok yakın tuzaklar.',
      'interference':
          'Önce A listesini öğren ve yaz. Sonra yeni bir B listesi gelecek. En sonda yeniden A listesini yaz; B\'den kelime karıştırma.',
      'delayed': 'Listeyi öğren ve hemen yaz. Sonra bir süre basit işlemleri doğrula. En sonda listeyi yeniden yaz.',
    };
    final th = (st['thresholds'] as List?)?.map((e) => ((e as num) * 100).round()).toList() ?? const [];
    return MemoryIntroCard(
      title: st['title'] as String? ?? '',
      lines: [
        texts[st['variant']] ?? '',
        'Yazarken büyük-küçük harf ve Türkçe karakter (ç, ğ, ı, ö, ş, ü) önemsiz.',
        if (th.length == 3) 'Yıldızlar: ★ %${th[0]} · ★★ %${th[1]} · ★★★ %${th[2]}',
      ],
      onStart: () => s.act({'start': true}),
    );
  }

  // ------------------------------------------------------------------ study

  Widget _study(Map study) {
    final word = study['word'] as String?;
    final idx = (study['index'] as num?)?.toInt() ?? 0;
    final total = (study['total'] as num?)?.toInt() ?? 1;
    final slot = (study['slot_ms'] as num?)?.toDouble() ?? 1000;
    final t = (study['t_ms'] as num?)?.toDouble() ?? 0;
    final trials = (study['trials'] as num?)?.toInt() ?? 1;
    final list = study['list'] as String? ?? 'A';
    // Fade derived from the core clock: 120 ms in, out over the last part of the visible window.
    final visible = slot * 0.85;
    final fadeIn = (t / 120).clamp(0.0, 1.0);
    final fadeOut = ((visible - t) / 140).clamp(0.0, 1.0);
    final a = word == null ? 0.0 : math.min(fadeIn, fadeOut);
    final label = [
      if (list == 'B') 'B listesi' else 'A listesi',
      if (trials > 1) '${study['trial']}. deneme',
    ].join(' · ');
    return LayoutBuilder(builder: (context, box) {
      final big = (box.maxWidth * 0.13).clamp(34.0, 64.0);
      return Column(
        children: [
          const SizedBox(height: 14),
          Text(Lux.upper(label), style: Lux.ui(13, color: Lux.gold, spacing: 2.4, weight: FontWeight.w700)),
          const SizedBox(height: 10),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 40), child: _Dots(idx, total)),
          Expanded(
            child: Center(
              child: Opacity(
                opacity: a,
                child: Transform.scale(
                  scale: 0.94 + 0.06 * Curves.easeOutCubic.transform(fadeIn),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: FoilWord(word ?? '', style: Lux.display(big, spacing: 1.5)),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 26),
            child: Text('${idx + 1} / $total', style: Lux.ui(15, color: Lux.muted)),
          ),
        ],
      );
    });
  }

  // ------------------------------------------------------------------ recall

  Widget _recall(Map r) {
    final entries = (r['entries'] as List? ?? const []).cast<Map>();
    final serial = r['serial'] == true;
    final total = (r['total'] as num?)?.toInt() ?? 0;
    final found = (r['found'] as num?)?.toInt() ?? 0;
    final remaining = (r['remaining_ms'] as num?)?.toDouble() ?? 0;
    final limit = (r['limit_ms'] as num?)?.toDouble() ?? 1;
    final t = _now - _entryAt;
    final flash = t >= 0 && t < 0.5 ? math.pow(1 - t / 0.5, 2).toDouble() : 0.0;
    final ok = _entryResult == 'ok';
    final shake = !ok && _entryResult != 'skip' && t >= 0 && t < 0.35 ? math.sin(t * 52) * 8 * math.exp(-t * 9) : 0.0;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(r['label'] as String? ?? '',
                    style: Lux.ui(17, color: Lux.ink, weight: FontWeight.w700), overflow: TextOverflow.ellipsis),
              ),
              Text(serial ? 'Sıra ${math.min(entries.length + 1, total)} / $total' : 'Bulunan $found / $total',
                  style: Lux.ui(15, color: Lux.goldLight, weight: FontWeight.w600)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
          child: ThinBar(remaining / limit, warn: remaining < 10000),
        ),
        if (entries.isEmpty)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 30),
                child: Text(
                  serial
                      ? 'Kelimeleri gördüğün sırayla yaz. Hatırlamadığın sırayı "Boş geç" ile atla.'
                      : 'Aklına gelen her kelimeyi yaz ve Tamam\'a bas. Sıra önemli değil. Bitince "Bitti".',
                  textAlign: TextAlign.center,
                  style: Lux.ui(15, color: Lux.muted),
                ),
              ),
            ),
          )
        else
          Expanded(
            child: SingleChildScrollView(
              reverse: true,
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                alignment: WrapAlignment.center,
                children: [
                  for (var i = 0; i < entries.length; i++)
                    _chip(entries[i], serial ? i + 1 : null, i == entries.length - 1 ? flash : 0),
                ],
              ),
            ),
          ),
        Transform.translate(
          offset: Offset(shake, 0),
          child: _InputBox(
              text: _input,
              hint: serial ? '${math.min(entries.length + 1, total)}. kelime' : 'kelime yaz',
              flash: flash,
              ok: ok),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              if (serial)
                Expanded(
                  child: _SmallAction('Boş geç', onTap: () {
                    HapticFeedback.selectionClick();
                    s.act({'skip_slot': true});
                  }),
                ),
              if (serial) const SizedBox(width: 8),
              Expanded(
                child: _SmallAction('Bitti', strong: true, onTap: () {
                  HapticFeedback.selectionClick();
                  s.act({'done': true});
                  setState(() => _input = '');
                }),
              ),
            ],
          ),
        ),
        TrKeyboard(
          onChar: (c) => setState(() => _input = _input.length < 24 ? _input + c : _input),
          onBackspace: () => setState(() => _input = _input.isEmpty ? '' : _input.substring(0, _input.length - 1)),
          onEnter: _submit,
        ),
      ],
    );
  }

  Widget _chip(Map e, int? slot, double flash) {
    final result = e['result'] as String? ?? '';
    final word = e['word'] as String?;
    final text = result == 'skip' ? '—' : (e['fixed'] == true && word != null ? word : (e['text'] as String? ?? ''));
    final (Color c, IconData? icon) = switch (result) {
      'ok' => (Lux.good, e['fixed'] == true ? Icons.spellcheck_rounded : Icons.check_rounded),
      'misplaced' => (Lux.goldLight, Icons.swap_horiz_rounded),
      'other_list' => (Lux.bordeauxLight, Icons.call_split_rounded),
      'skip' => (Lux.muted, null),
      _ => (Lux.bordeauxLight, Icons.close_rounded),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Color.lerp(const Color(0xFF0B2E24), c, 0.12 + 0.25 * flash),
        border: Border.all(color: c.withValues(alpha: 0.55 + 0.45 * flash)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (slot != null) Text('$slot. ', style: Lux.ui(13, color: Lux.muted)),
          Text(text, style: Lux.ui(15, color: Lux.ink, weight: FontWeight.w600)),
          if (icon != null) ...[const SizedBox(width: 4), Icon(icon, size: 15, color: c)],
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ recognition

  Widget _recognize(Map r) {
    final word = r['word'] as String? ?? '';
    final idx = (r['index'] as num?)?.toInt() ?? 0;
    final total = (r['total'] as num?)?.toInt() ?? 1;
    final t = _now - _recAt;
    final flash = t >= 0 && t < 0.45 ? math.pow(1 - t / 0.45, 2).toDouble() : 0.0;
    final rim = Color.lerp(Lux.gold.withValues(alpha: 0.5), _recOk ? Lux.good : Lux.bordeauxLight, flash)!;
    return Column(
      children: [
        const SizedBox(height: 12),
        Text('${math.min(idx + 1, total)} / $total', style: Lux.ui(15, color: Lux.muted)),
        Padding(padding: const EdgeInsets.fromLTRB(40, 8, 40, 0), child: ThinBar(idx / total)),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                transitionBuilder: (c, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(
                      position: Tween(begin: const Offset(0, 0.2), end: Offset.zero).animate(a), child: c),
                ),
                child: Container(
                  key: ValueKey(idx),
                  padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 26),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    gradient: Lux.velvetCard,
                    border: Border.all(color: rim, width: 1.4 + flash),
                    boxShadow: [BoxShadow(color: rim.withValues(alpha: 0.25 + 0.3 * flash), blurRadius: 24)],
                  ),
                  child: FittedBox(fit: BoxFit.scaleDown, child: FoilWord(word, style: Lux.display(46, spacing: 1.2))),
                ),
              ),
            ),
          ),
        ),
        Text('Listede var mıydı?', style: Lux.ui(18, color: Lux.ink, weight: FontWeight.w600)),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 22),
          child: Row(
            children: [
              Expanded(child: _BigAnswer('Hayır', onTap: () => s.act({'answer': false}))),
              const SizedBox(width: 12),
              Expanded(child: _BigAnswer('Evet', primary: true, onTap: () => s.act({'answer': true}))),
            ],
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ review

  Widget _review(Map<String, dynamic> st) {
    final res = st['results'] is Map ? Map<String, dynamic>.from(st['results'] as Map) : <String, dynamic>{};
    final curve = (res['serial_position'] as List? ?? const []).map((e) => (e as num).toDouble()).toList();
    final learning = (res['learning'] as List?)?.map((e) => (e as num).toInt()).toList();
    final rounds = (res['rounds'] as List? ?? const []).cast<Map>();
    final intrusions = (res['intrusions'] as List? ?? const []).cast<String>();
    final falseAlarms = (res['false_alarms'] as List? ?? const []).cast<String>();
    final missed = (res['missed'] as List? ?? const []).cast<String>();
    final listA = (res['list_a'] as List? ?? const []).cast<String>();
    final clustering = (res['clustering'] as num?)?.toDouble();
    final distract = res['distract'] as Map?;
    final stars = (st['stars'] as num?)?.toInt() ?? 0;
    final pct = (res['score_pct'] as num?)?.toInt() ?? 0;
    final recognition = res['variant'] == 'recognition';
    String p(num? x) => '%${(((x ?? 0) * 100)).round()}';
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            children: [
              Center(child: FoilText('%$pct', style: Lux.numeral(54))),
              const SizedBox(height: 4),
              Center(child: StarRow(stars, size: 26)),
              const SizedBox(height: 4),
              Center(
                child: Text(stars > 0 ? 'Geçtin' : 'Eşiğin altında kaldı',
                    style: Lux.ui(14, color: stars > 0 ? Lux.good : Lux.bordeauxLight)),
              ),
              const SizedBox(height: 14),
              _Panel(
                title: recognition ? 'Liste sırasına göre tanıma' : 'Sıra etkisi (A listesi)',
                child: Column(
                  children: [
                    SizedBox(height: 120, child: CustomPaint(painter: _SerialChart(curve), size: Size.infinite)),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Baş ${p(res['primacy'] as num?)}', style: Lux.ui(13, color: Lux.goldLight)),
                        Text('Orta ${p(res['middle'] as num?)}', style: Lux.ui(13, color: Lux.muted)),
                        Text('Son ${p(res['recency'] as num?)}', style: Lux.ui(13, color: Lux.goldLight)),
                      ],
                    ),
                  ],
                ),
              ),
              if (learning != null && learning.length > 1)
                _Panel(
                  title: 'Öğrenme eğrisi',
                  child: SizedBox(
                    height: 110,
                    child: CustomPaint(painter: _LearningChart(learning, listA.length), size: Size.infinite),
                  ),
                ),
              if (rounds.isNotEmpty)
                _Panel(
                  title: 'Turlar',
                  child: Column(
                    children: [
                      for (final r in rounds)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            children: [
                              Expanded(child: Text(r['label'] as String? ?? '', style: Lux.ui(14, color: Lux.ink))),
                              Text('${r['found']} / ${r['total']}',
                                  style: Lux.ui(14, color: Lux.goldLight, weight: FontWeight.w700)),
                              if ((r['intrusions'] as num? ?? 0) > 0)
                                Text('  · ${r['intrusions']} araya giren', style: Lux.ui(12, color: Lux.bordeauxLight)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              if (intrusions.isNotEmpty || falseAlarms.isNotEmpty)
                _Panel(
                  title: recognition ? 'Yanlış alarm (tuzak kelimeler)' : 'Araya girenler',
                  child: _Chips(recognition ? falseAlarms : intrusions, Lux.bordeauxLight),
                ),
              if (missed.isNotEmpty) _Panel(title: 'Kaçırdıkların', child: _Chips(missed, Lux.muted)),
              _Panel(
                title: 'Notlar',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (clustering != null)
                      Text('Kümeleme: ardışık doğruların ${p(clustering)}\'i aynı kategoriden.',
                          style: Lux.ui(14, color: Lux.ink)),
                    if (distract != null)
                      Text('Ara görev: ${distract['right']} doğru, ${distract['wrong']} yanlış.',
                          style: Lux.ui(14, color: Lux.ink)),
                    Text('Liste: ${listA.join(', ')}', style: Lux.ui(13, color: Lux.muted)),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 18, top: 4),
          child: GoldButton('Bitir', icon: Icons.flag_rounded, onPressed: () => s.act({'finish': true})),
        ),
      ],
    );
  }
}

// ==================================================================== shared widgets

/// Gold-leaf text whose shader box also covers descenders (y, p, ğ, ç) and accents.
class FoilWord extends StatelessWidget {
  final String text;
  final TextStyle style;
  const FoilWord(this.text, {super.key, required this.style});

  @override
  Widget build(BuildContext context) {
    final size = style.fontSize ?? 20;
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (r) => Lux.foil.createShader(r),
      child: Padding(
        padding: EdgeInsets.only(top: size * 0.08, bottom: size * 0.28),
        child: Text(text, maxLines: 1, style: style.copyWith(color: Colors.white)),
      ),
    );
  }
}

/// Big calm intro card with a Başla button.
class MemoryIntroCard extends StatelessWidget {
  final String title;
  final List<String> lines;
  final VoidCallback onStart;
  const MemoryIntroCard({super.key, required this.title, required this.lines, required this.onStart});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(22),
        child: LuxCard(
          highlight: true,
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Lux.display(22, spacing: 1)),
              const SizedBox(height: 12),
              for (final l in lines)
                if (l.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 9),
                    child: Text(l, style: Lux.ui(16, color: Lux.ink)),
                  ),
              const SizedBox(height: 10),
              Center(child: GoldButton('Başla', icon: Icons.play_arrow_rounded, onPressed: onStart)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 3-2-1 countdown: the number pops on every second; the banner says what comes next.
class PhaseCountdown extends StatelessWidget {
  final Map cd;
  const PhaseCountdown(this.cd, {super.key});

  @override
  Widget build(BuildContext context) {
    final rem = (cd['remaining_ms'] as num?)?.toDouble() ?? 0;
    final n = math.max(1, (rem / 1000).ceil());
    final into = 1 - (rem % 1000) / 1000; // 0 → 1 within the current second
    final pop = Curves.easeOutBack.transform((into * 3).clamp(0.0, 1.0));
    final fade = into > 0.75 ? 1 - (into - 0.75) / 0.25 : 1.0;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(cd['banner'] as String? ?? '',
              textAlign: TextAlign.center, style: Lux.display(24, color: Lux.goldLight, spacing: 1)),
          const SizedBox(height: 26),
          SizedBox(
            height: 130,
            child: Opacity(
              opacity: fade.clamp(0.0, 1.0),
              child: Transform.scale(scale: 0.6 + 0.4 * pop, child: FoilText('$n', style: Lux.numeral(110))),
            ),
          ),
        ],
      ),
    );
  }
}

/// Distractor: verify sums with Doğru / Yanlış until time runs out.
class DistractPanel extends StatelessWidget {
  final Map d;
  final ValueChanged<bool> onJudge;
  const DistractPanel(this.d, {super.key, required this.onJudge});

  @override
  Widget build(BuildContext context) {
    final rem = (d['remaining_ms'] as num?)?.toDouble() ?? 0;
    final total = (d['total_ms'] as num?)?.toDouble() ?? 1;
    final serial = (d['serial'] as num?)?.toInt() ?? 0;
    final lastOk = d['last_ok'] as bool?;
    return Column(
      children: [
        const SizedBox(height: 10),
        Text(Lux.upper('Ara görev'), style: Lux.ui(13, color: Lux.gold, spacing: 2.4, weight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('Listeyi düşünme, işlemlere odaklan', style: Lux.ui(14, color: Lux.muted)),
        Padding(padding: const EdgeInsets.fromLTRB(30, 12, 30, 0), child: ThinBar(rem / total)),
        const SizedBox(height: 4),
        Text('${(rem / 1000).ceil()} sn', style: Lux.ui(14, color: Lux.muted)),
        Expanded(
          child: Center(
            child: TweenAnimationBuilder<double>(
              key: ValueKey(serial),
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 380),
              builder: (context, t, child) {
                final c = lastOk == null ? Lux.gold : (lastOk ? Lux.good : Lux.bordeauxLight);
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 20),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    gradient: Lux.velvetCard,
                    border: Border.all(color: Color.lerp(c, Lux.gold.withValues(alpha: 0.5), t)!, width: 1.4),
                  ),
                  child: Opacity(
                    opacity: Curves.easeOut.transform(t),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(d['text'] as String? ?? '', style: Lux.numeral(46, color: Lux.ink)),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        Text('Doğru ${d['right'] ?? 0} · Yanlış ${d['wrong'] ?? 0}', style: Lux.ui(14, color: Lux.muted)),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 22),
          child: Row(
            children: [
              Expanded(child: _BigAnswer('Yanlış', onTap: () => onJudge(false))),
              const SizedBox(width: 12),
              Expanded(child: _BigAnswer('Doğru', primary: true, onTap: () => onJudge(true))),
            ],
          ),
        ),
      ],
    );
  }
}

/// Thin gold progress bar (fraction 0..1); bordeaux when [warn].
class ThinBar extends StatelessWidget {
  final double fraction;
  final bool warn;
  const ThinBar(this.fraction, {super.key, this.warn = false});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 5,
        child: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Color(0xFF0A2A20))),
            FractionallySizedBox(
              widthFactor: fraction.clamp(0.0, 1.0),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: warn ? null : Lux.goldGradient,
                  color: warn ? Lux.bordeauxLight : null,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Big Turkish Q keyboard (no system IME, so no suggestions or autocorrect). Sends lower-case
/// letters (I → ı, İ → i).
class TrKeyboard extends StatelessWidget {
  final ValueChanged<String> onChar;
  final VoidCallback onBackspace;
  final VoidCallback onEnter;
  final VoidCallback? onSpace;
  final String enterLabel;
  const TrKeyboard({
    super.key,
    required this.onChar,
    required this.onBackspace,
    required this.onEnter,
    this.onSpace,
    this.enterLabel = 'Tamam',
  });

  static const _rows = ['qwertyuıopğü', 'asdfghjklşi', 'zxcvbnmöç'];

  @override
  Widget build(BuildContext context) {
    void tap(String c) {
      HapticFeedback.selectionClick();
      onChar(c);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [for (final c in _rows[0].split('')) Expanded(child: _Key(Lux.upper(c), () => tap(c)))]),
          Row(children: [
            const Spacer(),
            for (final c in _rows[1].split('')) Expanded(flex: 2, child: _Key(Lux.upper(c), () => tap(c))),
            const Spacer(),
          ]),
          Row(children: [
            const Spacer(),
            for (final c in _rows[2].split('')) Expanded(flex: 2, child: _Key(Lux.upper(c), () => tap(c))),
            Expanded(
              flex: 5,
              child: _Key('⌫', () {
                HapticFeedback.selectionClick();
                onBackspace();
              }, accent: true),
            ),
          ]),
          Row(children: [
            if (onSpace != null)
              Expanded(
                flex: 5,
                child: _Key('boşluk', () {
                  HapticFeedback.selectionClick();
                  onSpace!();
                }, accent: true, small: true),
              ),
            Expanded(
              flex: 4,
              child: _Key(enterLabel, () {
                HapticFeedback.selectionClick();
                onEnter();
              }, primary: true, small: true),
            ),
          ]),
        ],
      ),
    );
  }
}

class _Key extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final bool accent, primary, small;
  const _Key(this.label, this.onTap, {this.accent = false, this.primary = false, this.small = false});

  @override
  State<_Key> createState() => _KeyState();
}

class _KeyState extends State<_Key> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final primary = widget.primary;
    final fg = primary ? const Color(0xFF1A1206) : (widget.accent ? Lux.gold : Lux.ink);
    return Padding(
      padding: const EdgeInsets.all(2.2),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _down ? 0.92 : 1,
          duration: const Duration(milliseconds: 70),
          child: Container(
            height: 50,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              gradient: primary
                  ? Lux.goldGradient
                  : LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: _down
                          ? const [Color(0xFF1E5A47), Color(0xFF0E3A2D)]
                          : const [Color(0xFF134536), Color(0xFF082A20)],
                    ),
              border: Border.all(color: primary ? Colors.transparent : Lux.line),
            ),
            child: widget.label == '⌫'
                ? Icon(Icons.backspace_outlined, color: fg, size: 21)
                : FittedBox(
                    fit: BoxFit.scaleDown,
                    child:
                        Text(widget.label, style: Lux.ui(widget.small ? 17 : 21, color: fg, weight: FontWeight.w600)),
                  ),
          ),
        ),
      ),
    );
  }
}

class _InputBox extends StatelessWidget {
  final String text;
  final String hint;
  final double flash;
  final bool ok;
  const _InputBox({required this.text, required this.hint, this.flash = 0, this.ok = true});

  @override
  Widget build(BuildContext context) {
    final rim = Color.lerp(Lux.gold.withValues(alpha: 0.6), ok ? Lux.good : Lux.bordeauxLight, flash)!;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 22),
      height: 54,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: const Color(0xFF051F17),
        border: Border.all(color: rim, width: 1.3 + 0.7 * flash),
        boxShadow: [BoxShadow(color: rim.withValues(alpha: 0.18 + 0.3 * flash), blurRadius: 16)],
      ),
      child: text.isEmpty
          ? Text(hint, style: Lux.ui(20, color: Lux.muted.withValues(alpha: 0.55)))
          : Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(text,
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      style: Lux.ui(26, color: Lux.ink, weight: FontWeight.w600)),
                ),
                Container(width: 2, height: 26, margin: const EdgeInsets.only(left: 3), color: Lux.gold),
              ],
            ),
    );
  }
}

class _SmallAction extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool strong;
  const _SmallAction(this.label, {required this.onTap, this.strong = false});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: strong ? Lux.gold.withValues(alpha: 0.8) : Lux.line),
          ),
          child: Text(label, style: Lux.ui(16, color: strong ? Lux.goldLight : Lux.ink, weight: FontWeight.w600)),
        ),
      ),
    );
  }
}

class _BigAnswer extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final bool primary;
  const _BigAnswer(this.label, {required this.onTap, this.primary = false});

  @override
  State<_BigAnswer> createState() => _BigAnswerState();
}

class _BigAnswerState extends State<_BigAnswer> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.primary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onTap();
      },
      child: AnimatedScale(
        scale: _down ? 0.95 : 1,
        duration: const Duration(milliseconds: 80),
        child: Container(
          height: 76,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: p ? Lux.goldGradient : Lux.velvetCard,
            border: Border.all(color: p ? Colors.transparent : Lux.gold.withValues(alpha: 0.6), width: 1.2),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 14, offset: const Offset(0, 6))
            ],
          ),
          child: Text(widget.label,
              style: Lux.ui(23, color: p ? const Color(0xFF1A1206) : Lux.goldLight, weight: FontWeight.w700)),
        ),
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  final int index, total;
  const _Dots(this.index, this.total);

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 5,
      runSpacing: 5,
      children: [
        for (var i = 0; i < total; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: i == index ? 14 : 7,
            height: 7,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              color: i < index ? Lux.gold.withValues(alpha: 0.55) : (i == index ? Lux.goldLight : Lux.line),
            ),
          ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  final String title;
  final Widget child;
  const _Panel({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: LuxCard(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(Lux.upper(title), style: Lux.ui(12, color: Lux.gold, spacing: 1.8, weight: FontWeight.w700)),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

class _Chips extends StatelessWidget {
  final List<String> words;
  final Color color;
  const _Chips(this.words, this.color);

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final w in words)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withValues(alpha: 0.6))),
            child: Text(w, style: Lux.ui(14, color: color)),
          ),
      ],
    );
  }
}

/// Bars per list position (share recalled) with a smoothed trend line: the U of primacy/recency.
class _SerialChart extends CustomPainter {
  final List<double> v;
  _SerialChart(this.v);

  @override
  void paint(Canvas canvas, Size size) {
    if (v.isEmpty) return;
    final n = v.length;
    final w = size.width / n;
    final h = size.height - 16;
    final grid = Paint()
      ..color = Lux.lineFaint
      ..strokeWidth = 1;
    for (final g in [0.0, 0.5, 1.0]) {
      canvas.drawLine(Offset(0, h * (1 - g)), Offset(size.width, h * (1 - g)), grid);
    }
    final third = math.max(1, n ~/ 3);
    for (var i = 0; i < n; i++) {
      final edge = i < third || i >= n - third;
      final bh = math.max(2.0, h * v[i]);
      final r = Rect.fromLTWH(i * w + w * 0.18, h - bh, w * 0.64, bh);
      final paint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: v[i] == 0
              ? [Lux.bordeaux.withValues(alpha: 0.7), Lux.bordeaux.withValues(alpha: 0.4)]
              : edge
                  ? const [Color(0xFFF1D48B), Color(0xFF9C7228)]
                  : const [Color(0xFFB98A35), Color(0xFF6E5020)],
        ).createShader(r);
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(3)), paint);
      if (n <= 16 || i % 2 == 0 || i == n - 1) {
        final tp = TextPainter(
          text: TextSpan(text: '${i + 1}', style: Lux.ui(9.5, color: Lux.muted)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(i * w + (w - tp.width) / 2, h + 3));
      }
    }
    // Trend: moving average over 3 positions.
    final path = Path();
    for (var i = 0; i < n; i++) {
      final a = v[math.max(0, i - 1)], b = v[i], c = v[math.min(n - 1, i + 1)];
      final y = h * (1 - (a + 2 * b + c) / 4);
      final x = i * w + w / 2;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..color = Lux.good.withValues(alpha: 0.8),
    );
  }

  @override
  bool shouldRepaint(_SerialChart old) => old.v != v;
}

/// Words recalled per trial, as a rising gold line with labelled points.
class _LearningChart extends CustomPainter {
  final List<int> v;
  final int total;
  _LearningChart(this.v, this.total);

  @override
  void paint(Canvas canvas, Size size) {
    if (v.isEmpty || total == 0) return;
    final h = size.height - 18;
    const pad = 26.0;
    final w = size.width - 2 * pad;
    Offset pt(int i) =>
        Offset(pad + (v.length == 1 ? w / 2 : w * i / (v.length - 1)), 10 + (h - 10) * (1 - v[i] / total));
    final grid = Paint()
      ..color = Lux.lineFaint
      ..strokeWidth = 1;
    canvas.drawLine(const Offset(0, 10), Offset(size.width, 10), grid);
    canvas.drawLine(Offset(0, h), Offset(size.width, h), grid);
    final path = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < v.length; i++) {
      path.lineTo(pt(i).dx, pt(i).dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = Lux.gold,
    );
    for (var i = 0; i < v.length; i++) {
      final p = pt(i);
      canvas.drawCircle(p, 6, Paint()..color = Lux.goldLight);
      canvas.drawCircle(p, 3, Paint()..color = Lux.bg0);
      final tp = TextPainter(
        text: TextSpan(text: '${v[i]}', style: Lux.ui(13, color: Lux.ink, weight: FontWeight.w700)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(p.dx - tp.width / 2, p.dy - 22 < 0 ? p.dy + 8 : p.dy - 22));
      final lab = TextPainter(
        text: TextSpan(text: '${i + 1}. deneme', style: Lux.ui(10, color: Lux.muted)),
        textDirection: TextDirection.ltr,
      )..layout();
      lab.paint(canvas, Offset(p.dx - lab.width / 2, h + 4));
    }
  }

  @override
  bool shouldRepaint(_LearningChart old) => old.v != v || old.total != total;
}
