import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../lux.dart';
import 'cube_book.dart';
import 'cube_player.dart';
import 'cube_style.dart';

/// Reads a cube book one section at a time: section chips on top, then its headings, notes and
/// case cards. Explanations (a card's hint, a long note, a group's lead) start folded under an
/// *Açıklama* toggle, as in the web notebook, so the algorithms stand out. A ▶ beside an algorithm
/// opens it in the 3D player ([CubePlayerPage]). *Test modu* blurs the algorithms (and hides their
/// ▶) until a card is tapped. [initialAnchor] (a question's anchor) opens its section and scrolls to
/// its block.
class CubeBookScreen extends StatefulWidget {
  final String asset;
  final String title;
  final String? initialAnchor;
  const CubeBookScreen({super.key, required this.asset, required this.title, this.initialAnchor});

  @override
  State<CubeBookScreen> createState() => _CubeBookScreenState();
}

class _CubeBookScreenState extends State<CubeBookScreen> {
  late final Future<CubeBook> _book = CubeBook.load(widget.asset);
  final _scroll = ScrollController();
  final _anchorKey = GlobalKey();
  int _section = 0;
  bool _test = false;
  final _revealed = <String>{};
  String? _anchor;

  /// Unfolded explanations: [_hintKey] / [_noteKey] of a case, or a lead [TextBlock] itself.
  final _open = <Object>{};
  CubePlayerIndex? _player;

  /// Notes at least this long are explanations and fold; shorter ones are tips and stay.
  static const longNote = 80;

  static String _hintKey(CaseBlock c) => 'hint:${c.id}';
  static String _noteKey(CaseBlock c) => 'note:${c.id}';

  @override
  void initState() {
    super.initState();
    _anchor = widget.initialAnchor;
    if (widget.asset == CubeBook.defter) {
      CubePlayerIndex.load().then((p) {
        if (mounted) setState(() => _player = p);
      }, onError: (_) {});
    }
    _book.then((b) {
      final a = _anchor;
      if (!mounted || a == null) return;
      final i = b.sectionOf(a);
      if (i < 0) return;
      setState(() => _section = i);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _anchorKey.currentContext;
        if (ctx != null) Scrollable.ensureVisible(ctx, alignment: 0.08, duration: const Duration(milliseconds: 350));
      });
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _go(int i) {
    setState(() {
      _section = i;
      _anchor = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    return CubeTheme(
      child: Scaffold(
        backgroundColor: Lux.bg0,
        body: LuxBackground(
          child: SafeArea(
            child: FutureBuilder<CubeBook>(
              future: _book,
              builder: (context, snap) {
                final book = snap.data;
                return Column(
                  children: [
                    CubeHeader(
                      widget.title,
                      action: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (book != null && _foldable(book).isNotEmpty)
                            IconButton(
                              key: const Key('cube-book-explain-all'),
                              tooltip: _open.isEmpty ? 'Açıklamaları aç' : 'Açıklamaları kapat',
                              icon: Icon(_open.isEmpty ? Icons.unfold_more : Icons.unfold_less, color: Lux.goldLight),
                              onPressed: () => setState(() {
                                if (_open.isEmpty) {
                                  _open.addAll(_foldable(book));
                                } else {
                                  _open.clear();
                                }
                              }),
                            ),
                          FilterChip(
                            key: const Key('cube-book-test'),
                            label: const Text('Test modu'),
                            avatar: Icon(_test ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                            showCheckmark: false,
                            selected: _test,
                            onSelected: (v) => setState(() {
                              _test = v;
                              _revealed.clear();
                            }),
                          ),
                        ],
                      ),
                    ),
                    if (book == null)
                      Expanded(
                        child: Center(
                          child: snap.hasError
                              ? Text('Defter açılamadı.', style: Lux.ui(15, color: Lux.muted))
                              : const CircularProgressIndicator(color: Lux.gold),
                        ),
                      )
                    else ...[
                      _chips(book),
                      if (_test)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 2, 20, 4),
                          child: Text('Algoritmalar gizli: karta dokun, görünsün.',
                              style: Lux.ui(13, color: Lux.goldLight)),
                        ),
                      Expanded(child: _body(book)),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// Every explanation of the book that folds (their keys in [_open]).
  List<Object> _foldable(CubeBook book) {
    Iterable<Object> walk(List<BookBlock> bs) sync* {
      for (final b in bs) {
        if (b is TextBlock && b.style == 'lead') yield b;
        if (b is CaseBlock) {
          if (b.hint != null) yield _hintKey(b);
          if ((b.note?.length ?? 0) >= longNote) yield _noteKey(b);
        }
        if (b is CardBlock) yield* walk(b.children);
      }
    }

    return [
      ...walk(book.intro),
      for (final s in book.sections) ...walk(s.blocks),
      ...walk(book.foot),
    ];
  }

  void _toggle(Object key) => setState(() => _open.contains(key) ? _open.remove(key) : _open.add(key));

  Widget _chips(CubeBook book) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        itemCount: book.sections.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) => ChoiceChip(
          label: Text(book.sections[i].title),
          selected: i == _section,
          showCheckmark: false,
          onSelected: (_) => _go(i),
        ),
      ),
    );
  }

  Widget _body(CubeBook book) {
    final s = book.sections[_section];
    final last = _section == book.sections.length - 1;
    return SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_section == 0)
            for (final b in book.intro) _block(b),
          for (final b in s.blocks) _block(b),
          if (last) ...[
            const SizedBox(height: 16),
            for (final b in book.foot) _block(b),
          ],
          const SizedBox(height: 20),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 10,
            runSpacing: 10,
            children: [
              if (_section > 0)
                GoldButton('Önceki', icon: Icons.arrow_back, outlined: true, onPressed: () => _go(_section - 1))
              else
                const SizedBox.shrink(),
              if (!last) GoldButton('Sonraki bölüm', icon: Icons.arrow_forward, onPressed: () => _go(_section + 1)),
            ],
          ),
        ],
      ),
    );
  }

  /// The block a question pointed at gets a key (to scroll to it) and a gold frame.
  Widget _block(BookBlock b) {
    final a = _anchor;
    final target = a != null && b.ids.contains(a);
    final w = Padding(
      padding: EdgeInsets.only(bottom: b is HeadingBlock ? 4 : 10),
      child: _content(b, highlight: target),
    );
    if (!target) return w;
    return KeyedSubtree(key: _anchorKey, child: w);
  }

  Widget _content(BookBlock b, {bool highlight = false}) {
    return switch (b) {
      HeadingBlock() => _heading(b),
      TextBlock() => _text(b),
      ListBlock() => _list(b),
      TableBlock() => _table(b),
      CaseBlock() => _case(b, highlight),
      MovesBlock() => _moves(b),
      GlossBlock() => _gloss(b),
      CardBlock() => _card(b, highlight),
      LegendBlock() => _legend(b),
      LinksBlock() => _links(b),
    };
  }

  Widget _heading(HeadingBlock h) {
    switch (h.level) {
      case 1:
        return Padding(
          padding: const EdgeInsets.only(top: 14, bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (h.tag != null)
                Text(Lux.upper(h.tag!), style: Lux.ui(12, color: Lux.gold, weight: FontWeight.w700, spacing: 2.2)),
              FoilText(h.text, style: Lux.display(24, italic: true)),
              const SizedBox(height: 6),
              Container(height: 1, color: Lux.line),
            ],
          ),
        );
      case 4:
        return Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 2),
          child:
              Text(Lux.upper(h.text), style: Lux.ui(11.5, color: Lux.goldLight, weight: FontWeight.w600, spacing: 1.6)),
        );
      default:
        return Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Text.rich(TextSpan(children: [
            TextSpan(text: h.text, style: Lux.ui(h.level == 2 ? 19 : 17, weight: FontWeight.w700)),
            if (h.count != null) TextSpan(text: '  ${h.count}', style: Lux.ui(13, color: Lux.muted)),
          ])),
        );
    }
  }

  Widget _text(TextBlock t) {
    final style = switch (t.style) {
      'big' => Lux.display(30),
      'lead' || 'muted' || 'note' || 'foot' => Lux.ui(14, color: Lux.muted),
      _ => Lux.ui(15.5),
    };
    final text = CubeRichText(t.text, style: style);
    if (t.style != 'lead') return text;
    return CubeExplanation(open: _open.contains(t), onToggle: () => _toggle(t), child: text);
  }

  Widget _list(ListBlock l) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < l.items.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 26,
                  child: l.ordered
                      ? Text('${i + 1}.', style: Lux.ui(15, color: Lux.gold, weight: FontWeight.w700))
                      : Padding(
                          padding: const EdgeInsets.only(top: 7, left: 4),
                          child: Container(
                              width: 5,
                              height: 5,
                              decoration: const BoxDecoration(color: Lux.gold, shape: BoxShape.circle)),
                        ),
                ),
                Expanded(child: CubeRichText(l.items[i], style: Lux.ui(15))),
              ],
            ),
          ),
      ],
    );
  }

  Widget _table(TableBlock t) {
    return Container(
      decoration: BoxDecoration(border: Border.all(color: Lux.line), borderRadius: BorderRadius.circular(10)),
      clipBehavior: Clip.antiAlias,
      child: Table(
        defaultVerticalAlignment: TableCellVerticalAlignment.top,
        columnWidths: {
          for (var c = 0; c < t.rows.first.length; c++)
            c: t.rows.every((r) => c < r.length && r[c].length <= 6)
                ? const IntrinsicColumnWidth()
                : const FlexColumnWidth(),
        },
        border: const TableBorder(horizontalInside: BorderSide(color: Lux.lineFaint)),
        children: [
          for (var r = 0; r < t.rows.length; r++)
            TableRow(
              decoration: BoxDecoration(color: r == 0 ? Lux.cardDeep : null),
              children: [
                for (final c in t.rows[r])
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                    child: CubeRichText(c,
                        style: r == 0 ? Lux.ui(13, color: Lux.gold, weight: FontWeight.w700) : Lux.ui(14)),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _case(CaseBlock c, bool highlight) {
    final hidden = _test && !_revealed.contains(c.id);
    final flows = [
      for (final f in c.figs)
        if (f.isFlow) f
    ];
    final small = [
      for (final f in c.figs)
        if (!f.isFlow) f
    ];
    final figW = switch (small.length) { 1 => 96.0, 2 => 84.0, _ => 70.0 };
    final figs = Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        for (final f in small)
          SizedBox(
            width: figW,
            child: Column(
              children: [
                SvgPicture.string(f.svg, width: figW),
                if (f.caption != null)
                  Text(f.caption!, textAlign: TextAlign.center, style: Lux.ui(11, color: Lux.muted)),
              ],
            ),
          ),
      ],
    );
    final meta = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(TextSpan(children: [
          TextSpan(text: c.title, style: Lux.ui(16.5, weight: FontWeight.w700)),
          if (c.sub != null) TextSpan(text: '  ${c.sub}', style: Lux.ui(13, color: Lux.muted)),
        ])),
        if (c.hint != null)
          CubeExplanation(
            key: ValueKey('cube-explain-${c.id}'),
            open: _open.contains(_hintKey(c)),
            onToggle: () => _toggle(_hintKey(c)),
            child: CubeRichText(c.hint!, style: Lux.ui(13.5, color: Lux.muted)),
          ),
        const SizedBox(height: 8),
        for (var i = 0; i < c.algs.length; i++) _alg(c, i, hidden),
        if (c.note != null) ...[
          const SizedBox(height: 4),
          Container(height: 1, color: Lux.lineFaint),
          const SizedBox(height: 6),
          if (c.note!.length >= longNote)
            CubeExplanation(
              key: ValueKey('cube-note-${c.id}'),
              label: 'Not',
              open: _open.contains(_noteKey(c)),
              onToggle: () => _toggle(_noteKey(c)),
              child: CubeRichText(c.note!, style: Lux.ui(13, color: Lux.muted)),
            )
          else
            CubeRichText(c.note!, style: Lux.ui(13, color: Lux.muted)),
        ],
      ],
    );
    return LuxCard(
      key: ValueKey('case-${c.id}'),
      highlight: highlight,
      padding: const EdgeInsets.all(14),
      onTap:
          _test ? () => setState(() => _revealed.contains(c.id) ? _revealed.remove(c.id) : _revealed.add(c.id)) : null,
      child: c.figs.length == 1 && flows.isEmpty
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [figs, const SizedBox(width: 14), Expanded(child: meta)],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Flow charts keep a readable text size (about 0.8 of the source) and scroll sideways.
                for (final f in flows) ...[
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SvgPicture.string(f.svg, width: 700, height: 700 / f.aspect),
                  ),
                  const SizedBox(height: 10),
                ],
                if (small.isNotEmpty) ...[figs, const SizedBox(height: 10)],
                meta,
              ],
            ),
    );
  }

  Widget _alg(CaseBlock c, int i, bool hidden) {
    final a = c.algs[i];
    final play = hidden ? null : _player?.entry(c.id, i);
    Widget moves = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(a.moves, style: cubeMoves(15)),
        for (final t in a.trigs) Text('${t.moves} = ${t.name}', style: Lux.ui(12, color: Lux.muted)),
      ],
    );
    if (hidden) {
      moves = ExcludeSemantics(
        child: IgnorePointer(
          child: ImageFiltered(
            key: const Key('cube-alg-hidden'),
            imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
            child: moves,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(Lux.upper(a.label), style: Lux.ui(10.5, color: Lux.gold, weight: FontWeight.w600, spacing: 1.2)),
          if (play == null)
            moves
          else
            Row(
              children: [
                Expanded(child: moves),
                IconButton(
                  key: ValueKey('cube-play-${c.id}-$i'),
                  tooltip: '3D oynat',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.play_circle_outline, color: Lux.gold, size: 30),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => CubePlayerPage(
                        title: [c.title, if (c.sub != null) c.sub!].join(' · '),
                        label: a.label,
                        entry: play,
                      ),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _moves(MovesBlock m) {
    return LayoutBuilder(builder: (context, box) {
      final w = (box.maxWidth - 10) / 2;
      return Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final it in m.items)
            SizedBox(
              width: w,
              child: LuxCard(
                highlight: _anchor != null && _anchor == it.id,
                padding: const EdgeInsets.all(10),
                child: Column(
                  children: [
                    SvgPicture.string(it.svg, width: 92),
                    const SizedBox(height: 4),
                    Text(it.name, style: cubeMoves(16)),
                    Text(it.text, textAlign: TextAlign.center, style: Lux.ui(12.5, color: Lux.muted)),
                  ],
                ),
              ),
            ),
        ],
      );
    });
  }

  Widget _gloss(GlossBlock g) {
    return LuxCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final it in g.items)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(it.term, style: Lux.ui(15, color: Lux.goldLight, weight: FontWeight.w700)),
                  CubeRichText(it.text, style: Lux.ui(14)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _card(CardBlock c, bool highlight) {
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final b in c.children)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: b is HeadingBlock
                ? Text(b.text, style: Lux.ui(17, weight: FontWeight.w700, color: Lux.goldLight))
                : _content(b),
          ),
      ],
    );
    return LuxCard(
      highlight: highlight || c.tone == 'key',
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: c.tone == 'warn'
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2, right: 10),
                  child: Icon(Icons.warning_amber_rounded, color: Lux.bordeauxLight, size: 22),
                ),
                Expanded(child: body),
              ],
            )
          : body,
    );
  }

  Widget _legend(LegendBlock l) {
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        for (final it in l.items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (it.color != null) ...[
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: Color(int.parse('FF${it.color!.substring(1)}', radix: 16)),
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(color: Lux.bg0),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Flexible(child: Text(it.text, style: Lux.ui(12.5, color: Lux.muted))),
            ],
          ),
      ],
    );
  }

  Widget _links(LinksBlock l) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final it in l.items)
          ActionChip(
            avatar: const Icon(Icons.open_in_new),
            label: Text(it.text),
            onPressed: () => launchUrl(Uri.parse(it.url), mode: LaunchMode.externalApplication),
          ),
      ],
    );
  }
}

/// Lesson text: `**bold**` turns gold, `` `code` `` turns monospace.
class CubeRichText extends StatelessWidget {
  final String text;
  final TextStyle style;
  const CubeRichText(this.text, {super.key, required this.style});

  static final _marks = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`');

  @override
  Widget build(BuildContext context) {
    final spans = <InlineSpan>[];
    var at = 0;
    for (final m in _marks.allMatches(text)) {
      if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
      if (m.group(1) != null) {
        spans.add(TextSpan(text: m.group(1), style: style.copyWith(color: Lux.goldLight, fontWeight: FontWeight.w700)));
      } else {
        spans.add(TextSpan(text: m.group(2), style: cubeMoves((style.fontSize ?? 15) + 0.5)));
      }
      at = m.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return Text.rich(TextSpan(style: style, children: spans));
  }
}

/// An explanation folded under a small *Açıklama* toggle (its chevron turns); it opens and closes
/// with a size animation.
class CubeExplanation extends StatelessWidget {
  final bool open;
  final VoidCallback onToggle;
  final Widget child;
  final String label;
  const CubeExplanation(
      {super.key, required this.open, required this.onToggle, required this.child, this.label = 'Açıklama'});

  static const duration = Duration(milliseconds: 220);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          button: true,
          expanded: open,
          child: InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 4, 6, 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: Lux.ui(12.5, color: Lux.goldLight, weight: FontWeight.w600, spacing: 0.4)),
                  AnimatedRotation(
                    turns: open ? 0.5 : 0,
                    duration: duration,
                    child: const Icon(Icons.expand_more, size: 18, color: Lux.gold),
                  ),
                ],
              ),
            ),
          ),
        ),
        ClipRect(
          child: AnimatedSize(
            duration: duration,
            curve: Curves.easeInOut,
            alignment: Alignment.topLeft,
            child: open
                ? Padding(padding: const EdgeInsets.only(top: 2, bottom: 2), child: child)
                : const SizedBox(width: double.infinity),
          ),
        ),
      ],
    );
  }
}
