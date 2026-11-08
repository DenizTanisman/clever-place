import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../lux.dart';
import 'cube_book.dart';
import 'cube_book_screen.dart';
import 'cube_style.dart';

/// Leitner boxes per question id: a wrong answer goes back to box 1, a right one moves up a box
/// (to 5 at most). A question is due when it was never asked, or its box's wait has passed.
class CubeDrill {
  static const storageKey = 'cp.cube.drill';

  /// Box 3 and up counts as learned.
  static const learnedBox = 3;

  /// Wait after an answer, by box (box 1: right away).
  static const _wait = [Duration.zero, Duration.zero, Duration(days: 1), Duration(days: 3), Duration(days: 7), Duration(days: 14)];

  final Map<String, ({int box, int seen})> _cards;
  CubeDrill._(this._cards);

  factory CubeDrill.decode(String? raw) {
    final cards = <String, ({int box, int seen})>{};
    try {
      final m = jsonDecode(raw ?? '{}') as Map<String, dynamic>;
      m.forEach((id, v) {
        final l = v as List;
        cards[id] = (box: l[0] as int, seen: l[1] as int);
      });
    } catch (_) {}
    return CubeDrill._(cards);
  }

  String encode() => jsonEncode({for (final e in _cards.entries) e.key: [e.value.box, e.value.seen]});

  int box(String id) => _cards[id]?.box ?? 0;

  bool due(String id, int nowMs) {
    final c = _cards[id];
    if (c == null) return true;
    return nowMs - c.seen >= _wait[c.box.clamp(0, _wait.length - 1)].inMilliseconds;
  }

  void record(String id, {required bool right, required int nowMs}) {
    final b = box(id);
    _cards[id] = (box: right ? (max(b, 1) + 1).clamp(1, 5) : 1, seen: nowMs);
  }

  /// Due first; then lower boxes, easier stages, the longest unseen; book order breaks ties.
  List<CubeQuestion> order(List<CubeQuestion> qs, int nowMs) {
    final idx = {for (var i = 0; i < qs.length; i++) qs[i].id: i};
    int seen(String id) => _cards[id]?.seen ?? 0;
    return [...qs]..sort((a, b) {
        for (final c in [
          (due(a.id, nowMs) ? 0 : 1) - (due(b.id, nowMs) ? 0 : 1),
          box(a.id) - box(b.id),
          a.stage - b.stage,
          seen(a.id).compareTo(seen(b.id)),
          idx[a.id]! - idx[b.id]!,
        ]) {
          if (c != 0) return c;
        }
        return 0;
      });
  }
}

/// Multiple-choice drill over both cube books, filtered by book and section. Wrong answers come
/// back first ([CubeDrill]); after each answer the reason and a way into the notebook.
class CubeQuizScreen extends StatefulWidget {
  /// For tests: the time, in ms since epoch.
  @visibleForTesting
  final int Function()? clock;
  const CubeQuizScreen({super.key, this.clock});

  /// For the cube home: all questions, learned ones (box 3+), due now.
  static Future<({int total, int learned, int due})> summary() async {
    final books = await CubeBook.loadAll();
    final prefs = await SharedPreferences.getInstance();
    final drill = CubeDrill.decode(prefs.getString(CubeDrill.storageKey));
    final now = DateTime.now().millisecondsSinceEpoch;
    final qs = [for (final b in books) ...b.questions];
    return (
      total: qs.length,
      learned: qs.where((q) => drill.box(q.id) >= CubeDrill.learnedBox).length,
      due: qs.where((q) => drill.due(q.id, now)).length,
    );
  }

  @override
  State<CubeQuizScreen> createState() => _CubeQuizScreenState();
}

class _CubeQuizScreenState extends State<CubeQuizScreen> {
  static final _movesOnly = RegExp(r"^[()\sRULDFBMESxyzrufldbw0-9'’]+$");
  final _random = Random();
  List<CubeBook>? _books;
  SharedPreferences? _prefs;
  CubeDrill _drill = CubeDrill.decode(null);
  String? _book; // null: both
  String? _section; // null: every section of the book
  CubeQuestion? _q;
  List<int> _order = const []; // shown position -> option index
  int? _picked;
  String? _lastId;
  int _right = 0, _asked = 0;

  int get _now => widget.clock?.call() ?? DateTime.now().millisecondsSinceEpoch;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final books = await CubeBook.loadAll();
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _books = books;
      _prefs = prefs;
      _drill = CubeDrill.decode(prefs.getString(CubeDrill.storageKey));
    });
    _next();
  }

  List<CubeQuestion> get _pool => [
        for (final b in _books ?? const <CubeBook>[])
          if (_book == null || b.asset == _book)
            for (final q in b.questions)
              if (_section == null || q.section == _section) q,
      ];

  void _next() {
    var pool = _pool;
    if (pool.length > 1) pool = pool.where((q) => q.id != _lastId).toList();
    final q = pool.isEmpty ? null : _drill.order(pool, _now).first;
    setState(() {
      _q = q;
      _picked = null;
      _order = q == null ? const [] : (List.generate(q.options.length, (i) => i)..shuffle(_random));
    });
  }

  Future<void> _answer(int option) async {
    final q = _q;
    if (q == null || _picked != null) return;
    final right = option == q.answer;
    setState(() {
      _picked = option;
      _asked++;
      if (right) _right++;
      _lastId = q.id;
      _drill.record(q.id, right: right, nowMs: _now);
    });
    await _prefs?.setString(CubeDrill.storageKey, _drill.encode());
  }

  void _filter({String? book, String? section}) {
    setState(() {
      _book = book;
      _section = section;
      _lastId = null;
    });
    _next();
  }

  CubeBook _bookOf(CubeQuestion q) => _books!.firstWhere((b) => b.asset == q.book);

  @override
  Widget build(BuildContext context) {
    final books = _books;
    return CubeTheme(
      child: Scaffold(
        backgroundColor: Lux.bg0,
        body: LuxBackground(
          child: SafeArea(
            child: Column(
              children: [
                CubeHeader('Küp testi',
                    action: _asked == 0
                        ? null
                        : Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Text('$_right / $_asked', style: Lux.numeral(22)),
                          )),
                if (books == null)
                  const Expanded(child: Center(child: CircularProgressIndicator(color: Lux.gold)))
                else ...[
                  _filters(books),
                  Expanded(child: _question()),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _filters(List<CubeBook> books) {
    final book = books.where((b) => b.asset == _book).firstOrNull;
    final pool = _pool;
    final learned = pool.where((q) => _drill.box(q.id) >= CubeDrill.learnedBox).length;
    final due = pool.where((q) => _drill.due(q.id, _now)).length;
    Widget row(List<Widget> chips) => SizedBox(
          height: 46,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            children: [
              for (final c in chips) Padding(padding: const EdgeInsets.only(right: 8), child: c),
            ],
          ),
        );
    ChoiceChip chip(String label, bool selected, VoidCallback onTap) =>
        ChoiceChip(label: Text(label), selected: selected, showCheckmark: false, onSelected: (_) => onTap());
    return Column(
      children: [
        row([
          chip('Hepsi', _book == null, () => _filter()),
          for (final b in books) chip(b.title, _book == b.asset, () => _filter(book: b.asset)),
        ]),
        if (book != null)
          row([
            chip('Tüm bölümler', _section == null, () => _filter(book: book.asset)),
            for (final s in book.sections)
              if (book.questions.any((q) => q.section == s.id))
                chip(s.title, _section == s.id, () => _filter(book: book.asset, section: s.id)),
          ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 2, 20, 0),
          child: Row(
            children: [
              Text('Öğrenildi $learned / ${pool.length}', style: Lux.ui(13, color: Lux.muted)),
              const Spacer(),
              Text('Sırada $due', style: Lux.ui(13, color: Lux.goldLight)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _question() {
    final q = _q;
    if (q == null) {
      return Center(child: Text('Bu seçimde soru yok.', style: Lux.ui(15, color: Lux.muted)));
    }
    final book = _bookOf(q);
    final picked = _picked;
    final box = _drill.box(q.id);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 32),
      children: [
        LuxCard(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${book.title} · ${book.sectionTitle(q.section)}${box > 0 ? ' · kutu $box' : ' · yeni'}',
                style: Lux.ui(12, color: Lux.gold, spacing: 0.6),
              ),
              const SizedBox(height: 8),
              CubeRichText(q.q, style: Lux.ui(18, weight: FontWeight.w600)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < _order.length; i++) _option(q, i, _order[i]),
        if (picked != null) ...[
          const SizedBox(height: 6),
          LuxCard(
            highlight: picked == q.answer,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(picked == q.answer ? 'Doğru' : 'Yanlış',
                    style: Lux.ui(17, weight: FontWeight.w700, color: picked == q.answer ? Lux.good : Lux.bad)),
                if (q.why.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  CubeRichText(q.why, style: Lux.ui(14.5)),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 10,
            runSpacing: 10,
            children: [
              if (q.anchor != null)
                GoldButton(
                  'Defterde gör',
                  icon: Icons.menu_book_outlined,
                  outlined: true,
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => CubeBookScreen(asset: q.book, title: book.title, initialAnchor: q.anchor),
                    ),
                  ),
                )
              else
                const SizedBox.shrink(),
              GoldButton('Sonraki', icon: Icons.arrow_forward, onPressed: _next),
            ],
          ),
        ],
      ],
    );
  }

  Widget _option(CubeQuestion q, int shown, int option) {
    final picked = _picked;
    final text = q.options[option];
    final isAnswer = option == q.answer;
    Color? edge;
    if (picked != null && isAnswer) edge = Lux.good;
    if (picked == option && !isAnswer) edge = Lux.bad;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Opacity(
        opacity: picked != null && edge == null ? 0.55 : 1,
        child: Container(
          decoration: edge == null
              ? null
              : BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: edge, width: 2)),
          child: LuxCard(
            key: ValueKey('cube-option-$option'),
            radius: 16,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            onTap: picked == null ? () => _answer(option) : null,
            child: Row(
              children: [
                Text(String.fromCharCode(65 + shown), style: Lux.ui(16, color: Lux.gold, weight: FontWeight.w700)),
                const SizedBox(width: 12),
                Expanded(
                  child: _movesOnly.hasMatch(text)
                      ? Text(text, style: cubeMoves(15.5, color: Lux.ink))
                      : CubeRichText(text, style: Lux.ui(15.5)),
                ),
                if (edge != null) Icon(isAnswer ? Icons.check_circle : Icons.cancel, color: edge, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
