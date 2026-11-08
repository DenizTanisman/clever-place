import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Küp Defteri and Tek El Planı, sections of
/// blocks (headings, text, case cards with their diagrams and algorithms …) and the questions.
class CubeBook {
  static const defter = 'assets/cube/defter.json';
  static const tekEl = 'assets/cube/tek_el.json';
  static const all = [defter, tekEl];

  final String asset;
  final String title;
  final List<BookBlock> intro;
  final List<BookSection> sections;
  final List<BookBlock> foot;
  final List<CubeQuestion> questions;

  const CubeBook({
    required this.asset,
    required this.title,
    required this.intro,
    required this.sections,
    required this.foot,
    required this.questions,
  });

  /// The section that holds [anchor] (a section id or an element id inside a block), or -1.
  int sectionOf(String anchor) {
    for (var i = 0; i < sections.length; i++) {
      final s = sections[i];
      if (s.id == anchor || s.blocks.any((b) => b.ids.contains(anchor))) return i;
    }
    return -1;
  }

  String sectionTitle(String? id) => sections.where((s) => s.id == id).map((s) => s.title).firstOrNull ?? title;

  static final Map<String, CubeBook> _cache = {};

  /// Cached; a book already loaded comes back synchronously.
  static Future<CubeBook> load(String asset) {
    final hit = _cache[asset];
    if (hit != null) return SynchronousFuture(hit);
    return rootBundle.loadString(asset).then((s) => _cache[asset] = parse(s, asset: asset));
  }

  /// Both books. One by one: `Future.wait` drops the synchronous futures of cached books.
  static Future<List<CubeBook>> loadAll() async => [for (final a in all) await load(a)];

  @visibleForTesting
  static CubeBook parse(String json, {String asset = ''}) {
    final m = jsonDecode(json) as Map<String, dynamic>;
    List<BookBlock> blocks(Object? l) =>
        [for (final b in l as List? ?? const []) BookBlock.fromJson(b as Map<String, dynamic>)];
    return CubeBook(
      asset: asset,
      title: m['title'] as String,
      intro: blocks(m['intro']),
      sections: [
        for (final s in m['sections'] as List)
          BookSection(s['id'] as String, s['title'] as String, blocks(s['blocks'])),
      ],
      foot: blocks(m['foot']),
      questions: [
        for (final q in m['questions'] as List? ?? const []) CubeQuestion.fromJson(q as Map<String, dynamic>, asset),
      ],
    );
  }
}

class BookSection {
  final String id;
  final String title;
  final List<BookBlock> blocks;
  const BookSection(this.id, this.title, this.blocks);
}

/// One piece of a lesson. Text keeps `**bold**` and `` `code` `` (see [CubeRichText]).
sealed class BookBlock {
  /// Element ids inside the block (question anchors point at these).
  final List<String> ids;
  const BookBlock(this.ids);

  factory BookBlock.fromJson(Map<String, dynamic> j) {
    final ids = [for (final i in j['ids'] as List? ?? const []) i as String];
    List<Map<String, dynamic>> items() => [for (final i in j['items'] as List) i as Map<String, dynamic>];
    return switch (j['t'] as String) {
      'h' =>
        HeadingBlock(ids, j['level'] as int, j['text'] as String, tag: j['tag'] as String?, count: j['count'] as int?),
      'p' => TextBlock(ids, j['text'] as String, style: j['style'] as String?),
      'ol' || 'ul' => ListBlock(ids, j['t'] == 'ol', [for (final i in j['items'] as List) i as String]),
      'table' => TableBlock(ids, [
          for (final r in j['rows'] as List) [for (final c in r as List) c as String],
        ]),
      'case' => CaseBlock.fromJson(ids, j),
      'moves' => MovesBlock(ids, [
          for (final i in items())
            MoveCard(
                id: i['id'] as String?, svg: i['svg'] as String, name: i['name'] as String, text: i['text'] as String),
        ]),
      'gloss' => GlossBlock(ids, [for (final i in items()) (term: i['term'] as String, text: i['text'] as String)]),
      'card' => CardBlock(ids, [for (final c in j['children'] as List) BookBlock.fromJson(c as Map<String, dynamic>)],
          tone: j['tone'] as String?),
      'legend' =>
        LegendBlock(ids, [for (final i in items()) (color: i['color'] as String?, text: i['text'] as String)]),
      'links' => LinksBlock(ids, [for (final i in items()) (text: i['text'] as String, url: i['url'] as String)]),
      final t => throw FormatException('unknown block $t'),
    };
  }
}

/// Level 1: a puzzle/part title (with its [tag]), 2: a part, 3: a group of cards ([count] of
/// them), 4: a split inside a group (Basic · Advance).
class HeadingBlock extends BookBlock {
  final int level;
  final String text;
  final String? tag;
  final int? count;
  const HeadingBlock(super.ids, this.level, this.text, {this.tag, this.count});
}

/// [style]: lead · muted · note · foot (quieter), big (a large figure), intro, or null.
class TextBlock extends BookBlock {
  final String text;
  final String? style;
  const TextBlock(super.ids, this.text, {this.style});
}

class ListBlock extends BookBlock {
  final bool ordered;
  final List<String> items;
  const ListBlock(super.ids, this.ordered, this.items);
}

/// The first row is the header.
class TableBlock extends BookBlock {
  final List<List<String>> rows;
  const TableBlock(super.ids, this.rows);
}

/// A case card: diagrams, name, how to recognise it, its algorithms (OH · 2 el).
class CaseBlock extends BookBlock {
  final String id;
  final String title;
  final String? sub;
  final String? hint;
  final List<CaseAlg> algs;
  final List<CaseFigure> figs;
  final String? note;
  const CaseBlock(super.ids,
      {required this.id, required this.title, this.sub, this.hint, required this.algs, required this.figs, this.note});

  factory CaseBlock.fromJson(List<String> ids, Map<String, dynamic> j) => CaseBlock(
        ids,
        id: j['id'] as String,
        title: j['title'] as String,
        sub: j['sub'] as String?,
        hint: j['hint'] as String?,
        algs: [
          for (final a in j['algs'] as List)
            CaseAlg(a['label'] as String, a['moves'] as String, [
              for (final t in a['trigs'] as List? ?? const []) (moves: t['moves'] as String, name: t['name'] as String),
            ]),
        ],
        figs: [for (final f in j['figs'] as List) CaseFigure(f['svg'] as String, f['caption'] as String?)],
        note: j['note'] as String?,
      );
}

/// [trigs]: the nicknamed triggers inside the moves, e.g. (R U R' U') = Sexy move.
class CaseAlg {
  final String label;
  final String moves;
  final List<({String moves, String name})> trigs;
  const CaseAlg(this.label, this.moves, this.trigs);
}

class CaseFigure {
  final String svg;
  final String? caption;
  const CaseFigure(this.svg, this.caption);

  /// Width ÷ height of the viewBox (1 when it can't be read).
  double get aspect {
    final m = RegExp(r'viewBox="[-\d.]+ [-\d.]+ ([\d.]+) ([\d.]+)"').firstMatch(svg);
    if (m == null) return 1;
    return double.parse(m.group(1)!) / double.parse(m.group(2)!);
  }

  /// A step-by-step flow chart (Megaminx wide cards): drawn large and scrolled sideways.
  bool get isFlow => aspect > 2.5;
}

/// Notation cards: a move drawn and explained.
class MovesBlock extends BookBlock {
  final List<MoveCard> items;
  const MovesBlock(super.ids, this.items);
}

class MoveCard {
  final String? id;
  final String svg;
  final String name;
  final String text;
  const MoveCard({this.id, required this.svg, required this.name, required this.text});
}

class GlossBlock extends BookBlock {
  final List<({String term, String text})> items;
  const GlossBlock(super.ids, this.items);
}

/// A boxed note of Tek El Planı; [tone] key (the main points) or warn.
class CardBlock extends BookBlock {
  final List<BookBlock> children;
  final String? tone;
  const CardBlock(super.ids, this.children, {this.tone});
}

/// Colour key of the diagrams; [color] is `#RRGGBB`.
class LegendBlock extends BookBlock {
  final List<({String? color, String text})> items;
  const LegendBlock(super.ids, this.items);
}

class LinksBlock extends BookBlock {
  final List<({String text, String url})> items;
  const LinksBlock(super.ids, this.items);
}

/// A multiple-choice question; [anchor] is where its answer is in the book (null when the
/// notebook has no single place for it). Ids starting with `gen-` were made from the cards.
class CubeQuestion {
  final String book;
  final String id;
  final String? section;
  final int stage;
  final String? anchor;
  final String q;
  final List<String> options;
  final int answer;
  final String why;

  const CubeQuestion({
    required this.book,
    required this.id,
    required this.section,
    required this.stage,
    required this.anchor,
    required this.q,
    required this.options,
    required this.answer,
    required this.why,
  });

  factory CubeQuestion.fromJson(Map<String, dynamic> j, String book) => CubeQuestion(
        book: book,
        id: j['id'] as String,
        section: j['section'] as String?,
        stage: j['stage'] as int? ?? 1,
        anchor: j['anchor'] as String?,
        q: j['q'] as String,
        options: [for (final o in j['options'] as List) o as String],
        answer: j['answer'] as int,
        why: j['why'] as String? ?? '',
      );
}
