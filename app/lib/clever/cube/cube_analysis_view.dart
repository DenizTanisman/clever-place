import 'package:flutter/material.dart';

import '../i18n/lang.dart';
import '../lux.dart';
import 'cube_log.dart';
import 'cube_net.dart';
import 'cube_net_view.dart';
import 'cube_scrambles.dart';
import 'cube_style.dart';

const _colorNames = {
  'W': 'Beyaz',
  'Y': 'Sarı',
  'G': 'Yeşil',
  'B': 'Mavi',
  'R': 'Kırmızı',
  'O': 'Turuncu',
};

const _colorFaces = {
  'W': CubeFace.u,
  'Y': CubeFace.d,
  'G': CubeFace.f,
  'B': CubeFace.b,
  'R': CubeFace.r,
  'O': CubeFace.l,
};

const _slotNames = {
  'FR': 'ön sağ',
  'FL': 'ön sol',
  'BR': 'arka sağ',
  'BL': 'arka sol',
};

const _skipNames = {
  'oll': 'OLL skip',
  'pll': 'PLL skip',
  'll': 'Son katman skip',
  'edges': 'Sarı artı hazır',
};

/// The app never sees the moves; these hold for any 4x4 solve.
const _fourTips = [
  'İncelemede ilk iki merkezi (karşılıklı renkler, ör. beyaz-sarı) planla; ilk merkez için hangi 1×2 bloklar hazır, ona bak.',
  'Yau sırası: beyaz-sarı merkezler → üç artı kenarı → kalan dört merkez → kenar eşleştirme. Artıyı merkezlerden önce kurmak 3x3 aşamasını hızlandırır.',
  'Kenar eşleştirirken bir sonraki kenarın eşini şimdiden ara; eşleştirme sırasında duraksamak 4x4 süresinin en büyük kaybıdır.',
  'Parite (tek kenar ters ya da iki kenar yer değişik) algoritmaları Küp Defteri › 4x4 bölümünde; ezberli değilse önce onları çalış.',
];

String _color(String key) => _colorNames[key] == null ? key : t(_colorNames[key]!);

String _slot(String? key) => _slotNames[key] == null ? (key ?? '') : t(_slotNames[key]!);

/// "5 hamle" / "5 moves", "1 move".
String _hamle(int n) => Lang.en ? (n == 1 ? '1 move' : '$n moves') : '$n hamle';

/// English for a tip or skip note the Mac tool wrote into assets/cube/333.json (Turkish there);
/// the few sentence shapes it uses, with colours, slots and case names translated. Anything else,
/// and everything in Turkish, comes back as it is.
String cubeTip(String tr) {
  if (!Lang.en) return tr;
  const colors = {'Beyaz': 'White', 'Sarı': 'Yellow', 'Yeşil': 'Green', 'Mavi': 'Blue', 'Kırmızı': 'Red', 'Turuncu': 'Orange'};
  const slots = {'ön sağ': 'front right', 'ön sol': 'front left', 'arka sağ': 'back right', 'arka sol': 'back left'};
  String cl(String s) => s.replaceAll(' ve ', ' and ').split(', ').map((p) => p.split(' and ').map((c) => colors[c] ?? c).join(' and ')).join(', ');
  String sl(String s) => slots[s] ?? s;
  String n(String s, String one, String many) => s == '1' ? '1 $one' : '$s $many';
  String ll(String s) => s
      .replaceAll('(sarı artı)', '(yellow cross)')
      .replaceAll('nokta', 'dot')
      .replaceAll('çizgi', 'line')
      .replaceAll('Papyon', 'Bowtie')
      .replaceAll('Farlar', 'Headlights');
  RegExpMatch? m(String re) => RegExp(re).firstMatch(tr);
  RegExpMatch? x;
  if ((x = m(r'^(.+?) artı (\d+) hamle; (.+?) artı (\d+) hamle \((\d+) hamle kısa\)\.$')) != null) {
    return '${cl(x![1]!)} cross ${n(x[2]!, 'move', 'moves')}; ${cl(x[3]!)} cross ${n(x[4]!, 'move', 'moves')} '
        '(${n(x[5]!, 'move', 'moves')} shorter).';
  }
  if ((x = m(r'^(.+?) artı (\d+) hamle, bu karıştırmanın en kısa artısı(?: \((.+?) ile eşit\))?\.$')) != null) {
    final tie = x![3] == null ? '' : ' (tied with ${cl(x[3]!)})';
    return '${cl(x[1]!)} cross ${n(x[2]!, 'move', 'moves')}, the shortest cross for this scramble$tie.';
  }
  if ((x = m(r'^(.+?) x-cross (\d+) hamle \((.+?) çift ile\): (.+?), sonra (.+)\.$')) != null) {
    return '${cl(x![1]!)} x-cross ${n(x[2]!, 'move', 'moves')} (with the ${sl(x[3]!)} pair): ${x[4]}, then ${x[5]}.';
  }
  if ((x = m(r'^Son çifti \((.+?)\) (.+?) ile sokarsan son katman tamamen atlanıyor \(LL skip\)\.$')) != null) {
    return 'Insert the last pair (${sl(x![1]!)}) with ${x[2]} and the whole last layer is skipped (LL skip).';
  }
  if ((x = m(r'^Son çifti \((.+?)\) (.+?) ile sokarsan (sarı artı hazır|OLL skip|PLL skip) geliyor\.(?: OLL: (.+?)\.)?$')) != null) {
    final what = switch (x![3]) {
      'sarı artı hazır' => 'the yellow cross comes ready',
      'OLL skip' => 'you get an OLL skip',
      _ => 'you get a PLL skip',
    };
    final oll = x[4] == null ? '' : ' OLL: ${ll(x[4]!)}.';
    return 'Insert the last pair (${sl(x[1]!)}) with ${x[2]} and $what.$oll';
  }
  if ((x = m(r'^Artıyı (.+?) ile yaparsan (.+?) çift kendiliğinden yerinde kalıyor\.$')) != null) {
    return 'Build the cross with ${x![1]} and the ${sl(x[2]!)} pair stays solved by itself.';
  }
  if ((x = m(r'^Artıyı (.+?) ile yaparsan (.+?) çift (\d+) hamlede giriyor: (.+)\.$')) != null) {
    return 'Build the cross with ${x![1]} and the ${sl(x[2]!)} pair goes in with ${n(x[3]!, 'move', 'moves')}: ${x[4]}.';
  }
  if ((x = m(r'^Bu referans çözümde son katman: (.+)$')) != null) {
    return 'Last layer in this reference solve: ${ll(x![1]!)}';
  }
  return tr;
}

/// "Bu karıştırma için taktikler": the shortest crosses, x-cross, a
/// reference CFOP solve and skips within reach, worked out on the Mac for
/// this stored scramble.
class CubeAnalysisView extends StatelessWidget {
  const CubeAnalysisView({
    super.key,
    required this.solve,
    required this.stored,
    this.controller,
  });

  final CubeSolve solve;
  final StoredScramble? stored;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final a = stored?.analysis;
    final mono = cubeMoves(16);
    final muted = Lux.ui(13.5, color: Lux.muted);

    Widget section(String title) => Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 6),
      child: Text(
        Lux.upper(title),
        style: Lux.ui(11.5, color: Lux.gold, weight: FontWeight.w600, spacing: 1.8),
      ),
    );

    Widget moves(String rotation, String m) => Padding(
      padding: const EdgeInsets.only(top: 2),
      child: SelectableText(
        [if (rotation.isNotEmpty) '($rotation)', m].join(' '),
        style: mono,
      ),
    );

    final children = <Widget>[
      Text(
        '${formatSolve(solve)} · ${t(solve.session.label)}',
        style: Lux.display(24, italic: true),
      ),
      if (solve.scramble != null) ...[
        const SizedBox(height: 6),
        SelectableText(solve.scramble!, style: mono),
        const SizedBox(height: 8),
        Center(
          child: SizedBox(
            width: 200,
            child: CubeNetView(
              size: solve.session.size,
              scramble: solve.scramble!,
            ),
          ),
        ),
      ],
    ];

    if (a == null) {
      children.addAll([
        section(t('İpuçları')),
        if (solve.session.size == 3)
          Text(
            t('Bu karıştırma rastgele üretildi, bilgisayarda analizi yok. Hazır listedeki karıştırmalarda en kısa artı, x-cross ve skip fırsatları burada görünür.'),
            style: muted,
          )
        else ...[
          Text(
            t('4x4 için karıştırmaya özel analiz yok; genel taktikler:'),
            style: muted,
          ),
          for (final tip in _fourTips) _Bullet(t(tip)),
        ],
      ]);
    } else {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            t('Hamlelerini göremiyorum; aşağıdakiler bu karıştırma için hesaplanmış en kısa başlangıçlar ve örnek bir çözüm. Kendi çözümünle karşılaştır. Parantezdeki dönüş, karıştırmadan sonra küpü nasıl çevireceğin (artı rengi alta gelir).'),
            style: muted,
          ),
        ),
      );
      if (a.tips.isNotEmpty) {
        children.add(section(t('Taktikler')));
        children.addAll([for (final tip in a.tips) _Bullet(cubeTip(tip))]);
      }

      final crosses = a.cross.entries.toList()
        ..sort((x, y) => x.value.count.compareTo(y.value.count));
      if (crosses.isNotEmpty) {
        children.add(section(t('En kısa artı, renk renk')));
        children.add(
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final e in crosses)
                Chip(
                  avatar: CircleAvatar(
                    backgroundColor: cubeColor(
                      _colorFaces[e.key] ?? CubeFace.u,
                    ),
                    radius: 7,
                  ),
                  label: Text(
                    '${_color(e.key)} ${e.value.count}',
                    style: TextStyle(
                      fontWeight: e.key == 'W' ? FontWeight.w800 : null,
                    ),
                  ),
                ),
            ],
          ),
        );
        final white = a.cross['W'];
        final best = crosses.first;
        if (white != null) {
          children.add(const SizedBox(height: 10));
          children.add(Text(tf('Beyaz artı · {0}', [_hamle(white.count)]), style: muted));
          children.add(moves(white.rotation, white.moves));
        }
        if (best.key != 'W') {
          children.add(const SizedBox(height: 8));
          children.add(
            Text(
              tf('En kısası: {0} · {1}', [_color(best.key), _hamle(best.value.count)]),
              style: muted,
            ),
          );
          children.add(moves(best.value.rotation, best.value.moves));
        }
      }

      final xs = a.xcross.entries.toList()
        ..sort((x, y) => x.value.count.compareTo(y.value.count));
      if (xs.isNotEmpty) {
        children.add(section(t('X-cross (artı + bir çift birlikte)')));
        for (final e in xs.take(2)) {
          children.add(
            Text(
              tf('{0} altta, {1} çift · {2}', [_color(e.key), _slot(e.value.slot), _hamle(e.value.count)]),
              style: muted,
            ),
          );
          children.add(moves(e.value.rotation, e.value.moves));
          children.add(const SizedBox(height: 6));
        }
      }

      if (a.steps.isNotEmpty) {
        children.add(section(t('Örnek çözüm (beyaz artı)')));
        var pair = 0;
        for (final s in a.steps) {
          final label = switch (s.kind) {
            'cross' => t('Artı'),
            'xcross' => 'X-cross (${_slot(s.slot)})',
            _ => tf('{0}. çift ({1})', [++pair, _slot(s.slot)]),
          };
          children.add(Text(label, style: muted));
          children.add(
            s.moves.isEmpty
                ? Text(t('Zaten yerinde, hamle yok.'), style: muted)
                : moves(s == a.steps.first ? a.refRotation : '', s.moves),
          );
          children.add(const SizedBox(height: 4));
        }
        final ll = [
          if (a.edges != null && a.oll != 'skip')
            tf('kenarlar: {0}', [_edgeName(a.edges!)]),
          if (a.oll != null) 'OLL: ${_ollName(a.oll!)}',
          if (a.pll != null) 'PLL: ${a.pll}',
        ];
        if (ll.isNotEmpty) {
          children.add(Text(tf('Son katman · {0}', [ll.join(' · ')]), style: muted));
        }
        if (a.refCount != null) {
          children.add(
            Text(tf('F2L sonuna kadar {0}', [_hamle(a.refCount!)]), style: muted),
          );
        }
      }

      if (a.skips.isNotEmpty) {
        children.add(section(t('Skip fırsatları')));
        for (final s in a.skips) {
          children.add(
            Text(
              '${_skipNames[s.kind] == null ? s.kind : t(_skipNames[s.kind]!)}'
              '${s.note.isEmpty ? '' : ' · ${cubeTip(s.note)}'}',
              style: muted,
            ),
          );
          children.add(moves('', s.moves));
          children.add(const SizedBox(height: 6));
        }
      }
    }

    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      children: children,
    );
  }

  /// Küp Defteri's names for the 2-look corner cases.
  static String _ollName(String o) => switch (o) {
    'skip' => 'skip',
    'none' => t('köşeler hazır (2. adım yok)'),
    'Headlights' => t('Farlar'),
    'Bowtie' => t('Papyon'),
    _ => o,
  };

  static String _edgeName(String e) => switch (e) {
    'dot' => t('nokta'),
    'L' => 'L',
    'line' => t('çizgi'),
    'cross' => t('artı hazır'),
    _ => e,
  };
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 2, right: 8),
          child: Icon(Icons.bolt, size: 16, color: Lux.gold),
        ),
        Expanded(child: Text(text, style: Lux.ui(14.5))),
      ],
    ),
  );
}
