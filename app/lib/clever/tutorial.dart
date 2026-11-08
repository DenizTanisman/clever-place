import 'package:flutter/material.dart';

import 'lux.dart';

/// One tutorial page: a heading, a short text (paragraphs separated by a blank line; lines starting
/// with "- " render as bullets; text between **double stars** renders bold gold), and an optional
/// diagram (usually a [MiniGrid]).
class TutorialSection {
  final String title;
  final String body;
  final Widget? diagram;
  const TutorialSection(this.title, this.body, {this.diagram});
}

/// Per-game teaching content: the rules (shown on the game page) plus a mid-level and an
/// advanced-level strategy course.
class GameTutorials {
  final String rules;
  final List<TutorialSection> mid;
  final List<TutorialSection> advanced;
  const GameTutorials({required this.rules, required this.mid, required this.advanced});

  static const empty = GameTutorials(rules: 'Kurallar yakında.', mid: [], advanced: []);
}

/// Small illustrative grid for tutorials. Each row is a string of space-separated tokens:
/// `.` empty · any text = shown in the cell · prefix `*` = gold highlight · prefix `!` = bordeaux
/// (wrong / forbidden) · prefix `~` = dimmed. Optional [regions]: same-sized rows of single letters;
/// equal letters share a background tint (for region puzzles).
class MiniGrid extends StatelessWidget {
  final List<String> rows;
  final List<String>? regions;
  final double cell;
  final String? caption;
  const MiniGrid(this.rows, {super.key, this.regions, this.cell = 34, this.caption});

  static const _regionTints = [
    Color(0xFF3B2E1A), Color(0xFF3A1F27), Color(0xFF1F3330), Color(0xFF2B2440), Color(0xFF3A3420),
    Color(0xFF1E2A3D), Color(0xFF3D2A1E), Color(0xFF263A22), Color(0xFF3A2236), Color(0xFF22323A),
  ];

  @override
  Widget build(BuildContext context) {
    final grid = rows.map((r) => r.trim().split(RegExp(r'\s+'))).toList();
    final regionKeys = <String, int>{};
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Lux.gold.withValues(alpha: 0.5)),
            color: const Color(0xFF100B07),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var r = 0; r < grid.length; r++)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var c = 0; c < grid[r].length; c++) _cell(grid[r][c], _region(r, c, regionKeys)),
                  ],
                ),
            ],
          ),
        ),
        if (caption != null) ...[
          const SizedBox(height: 6),
          Text(caption!, style: Lux.ui(12, color: Lux.muted), textAlign: TextAlign.center),
        ],
      ],
    );
  }

  Color? _region(int r, int c, Map<String, int> keys) {
    final reg = regions;
    if (reg == null || r >= reg.length) return null;
    final row = reg[r].replaceAll(' ', '');
    if (c >= row.length) return null;
    final k = row[c];
    final i = keys.putIfAbsent(k, () => keys.length);
    return _regionTints[i % _regionTints.length];
  }

  Widget _cell(String token, Color? regionTint) {
    var t = token;
    Color bg = regionTint ?? const Color(0xFF1C150E);
    Color fg = Lux.ink;
    Border? border;
    if (t.startsWith('*')) {
      t = t.substring(1);
      bg = Color.lerp(bg, Lux.gold, 0.35)!;
      fg = Lux.goldLight;
      border = Border.all(color: Lux.gold, width: 1.4);
    } else if (t.startsWith('!')) {
      t = t.substring(1);
      bg = Color.lerp(bg, Lux.bordeaux, 0.45)!;
      fg = const Color(0xFFFFD6DF);
    } else if (t.startsWith('~')) {
      t = t.substring(1);
      fg = Lux.muted.withValues(alpha: 0.6);
    }
    if (t == '.') t = '';
    return Container(
      width: cell,
      height: cell,
      margin: const EdgeInsets.all(1.5),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6), border: border),
      child: Text(t, style: Lux.ui(cell * 0.46, color: fg, weight: FontWeight.w700)),
    );
  }
}

/// Renders a tutorial body string (see [TutorialSection]).
class RichBody extends StatelessWidget {
  final String text;
  final double size;
  const RichBody(this.text, {super.key, this.size = 16});

  @override
  Widget build(BuildContext context) {
    final blocks = text.trim().split(RegExp(r'\n\s*\n'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final b in blocks)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in b.split('\n'))
                  if (line.trimLeft().startsWith('- '))
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: EdgeInsets.only(top: size * 0.45, right: 8),
                            child: Container(width: 5, height: 5, decoration: const BoxDecoration(color: Lux.gold, shape: BoxShape.circle)),
                          ),
                          Expanded(child: _rich(line.trimLeft().substring(2))),
                        ],
                      ),
                    )
                  else
                    _rich(line),
              ],
            ),
          ),
      ],
    );
  }

  Widget _rich(String s) {
    final parts = s.split('**');
    return Text.rich(
      TextSpan(children: [
        for (var i = 0; i < parts.length; i++)
          TextSpan(
            text: parts[i],
            style: i.isOdd ? Lux.ui(size, color: Lux.goldLight, weight: FontWeight.w700) : Lux.ui(size, color: Lux.ink, weight: FontWeight.w500),
          ),
      ]),
    );
  }
}

/// Swipeable tutorial course (one section per page) with a progress rail.
class TutorialScreen extends StatefulWidget {
  final String title;
  final String level;
  final List<TutorialSection> sections;
  const TutorialScreen({super.key, required this.title, required this.level, required this.sections});

  @override
  State<TutorialScreen> createState() => _TutorialScreenState();
}

class _TutorialScreenState extends State<TutorialScreen> {
  final _pc = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.sections.length;
    return Scaffold(
      backgroundColor: Lux.bg0,
      body: LuxBackground(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
                child: Row(
                  children: [
                    IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back, color: Lux.ink)),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.title, style: Lux.ui(20, weight: FontWeight.w700)),
                          Text(widget.level, style: Lux.ui(13, color: Lux.gold, spacing: 1.5)),
                        ],
                      ),
                    ),
                    Text(n == 0 ? '' : '${_page + 1} / $n', style: Lux.ui(14, color: Lux.muted)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
                child: Row(
                  children: [
                    for (var i = 0; i < n; i++)
                      Expanded(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          height: 3,
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(2),
                            color: i <= _page ? Lux.gold : Lux.line,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: n == 0
                    ? Center(child: Text('Bu eğitim yakında.', style: Lux.ui(16, color: Lux.muted)))
                    : PageView.builder(
                        controller: _pc,
                        itemCount: n,
                        onPageChanged: (p) => setState(() => _page = p),
                        itemBuilder: (_, i) {
                          final s = widget.sections[i];
                          return SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                            child: LuxCard(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(s.title, style: Lux.display(19, spacing: 1)),
                                  const SizedBox(height: 14),
                                  if (s.diagram != null) ...[
                                    Center(child: s.diagram!),
                                    const SizedBox(height: 16),
                                  ],
                                  RichBody(s.body),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: Row(
                  children: [
                    GoldButton('Geri', outlined: true, onPressed: _page > 0 ? () => _go(-1) : null),
                    const Spacer(),
                    GoldButton(_page < n - 1 ? 'İleri' : 'Bitir',
                        onPressed: () => _page < n - 1 ? _go(1) : Navigator.pop(context)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _go(int d) => _pc.animateToPage(_page + d, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
}
