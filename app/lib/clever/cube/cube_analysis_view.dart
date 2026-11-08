import 'package:flutter/material.dart';

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
  'İncelemede ilk iki merkezi (karşılıklı renkler, ör. beyaz-sarı) '
      'planla; ilk merkez için hangi 1×2 bloklar hazır, ona bak.',
  'Yau sırası: beyaz-sarı merkezler → üç artı kenarı → kalan dört merkez → '
      'kenar eşleştirme. Artıyı merkezlerden önce kurmak 3x3 aşamasını '
      'hızlandırır.',
  'Kenar eşleştirirken bir sonraki kenarın eşini şimdiden ara; eşleştirme '
      'sırasında duraksamak 4x4 süresinin en büyük kaybıdır.',
  'Parite (tek kenar ters ya da iki kenar yer değişik) algoritmaları Küp '
      'Defteri › 4x4 bölümünde; ezberli değilse önce onları çalış.',
];

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
        '${formatSolve(solve)} · ${solve.session.label}',
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
        section('İpuçları'),
        if (solve.session.size == 3)
          Text(
            'Bu karıştırma rastgele üretildi, bilgisayarda analizi yok. '
            'Hazır listedeki karıştırmalarda en kısa artı, x-cross ve '
            'skip fırsatları burada görünür.',
            style: muted,
          )
        else ...[
          Text(
            '4x4 için karıştırmaya özel analiz yok; genel taktikler:',
            style: muted,
          ),
          for (final t in _fourTips) _Bullet(t),
        ],
      ]);
    } else {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            'Hamlelerini göremiyorum; aşağıdakiler bu karıştırma için '
            'hesaplanmış en kısa başlangıçlar ve örnek bir çözüm. Kendi '
            'çözümünle karşılaştır. Parantezdeki dönüş, karıştırmadan '
            'sonra küpü nasıl çevireceğin (artı rengi alta gelir).',
            style: muted,
          ),
        ),
      );
      if (a.tips.isNotEmpty) {
        children.add(section('Taktikler'));
        children.addAll([for (final t in a.tips) _Bullet(t)]);
      }

      final crosses = a.cross.entries.toList()
        ..sort((x, y) => x.value.count.compareTo(y.value.count));
      if (crosses.isNotEmpty) {
        children.add(section('En kısa artı, renk renk'));
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
                    '${_colorNames[e.key] ?? e.key} ${e.value.count}',
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
          children.add(Text('Beyaz artı · ${white.count} hamle', style: muted));
          children.add(moves(white.rotation, white.moves));
        }
        if (best.key != 'W') {
          children.add(const SizedBox(height: 8));
          children.add(
            Text(
              'En kısası: ${_colorNames[best.key] ?? best.key} · '
              '${best.value.count} hamle',
              style: muted,
            ),
          );
          children.add(moves(best.value.rotation, best.value.moves));
        }
      }

      final xs = a.xcross.entries.toList()
        ..sort((x, y) => x.value.count.compareTo(y.value.count));
      if (xs.isNotEmpty) {
        children.add(section('X-cross (artı + bir çift birlikte)'));
        for (final e in xs.take(2)) {
          children.add(
            Text(
              '${_colorNames[e.key] ?? e.key} altta, '
              '${_slotNames[e.value.slot] ?? e.value.slot ?? ''} çift · '
              '${e.value.count} hamle',
              style: muted,
            ),
          );
          children.add(moves(e.value.rotation, e.value.moves));
          children.add(const SizedBox(height: 6));
        }
      }

      if (a.steps.isNotEmpty) {
        children.add(section('Örnek çözüm (beyaz artı)'));
        var pair = 0;
        for (final s in a.steps) {
          final label = switch (s.kind) {
            'cross' => 'Artı',
            'xcross' => 'X-cross (${_slotNames[s.slot] ?? s.slot ?? ''})',
            _ => '${++pair}. çift (${_slotNames[s.slot] ?? s.slot ?? ''})',
          };
          children.add(Text(label, style: muted));
          children.add(
            s.moves.isEmpty
                ? Text('Zaten yerinde, hamle yok.', style: muted)
                : moves(s == a.steps.first ? a.refRotation : '', s.moves),
          );
          children.add(const SizedBox(height: 4));
        }
        final ll = [
          if (a.edges != null && a.oll != 'skip')
            'kenarlar: ${_edgeName(a.edges!)}',
          if (a.oll != null) 'OLL: ${_ollName(a.oll!)}',
          if (a.pll != null) 'PLL: ${a.pll}',
        ];
        if (ll.isNotEmpty) {
          children.add(Text('Son katman · ${ll.join(' · ')}', style: muted));
        }
        if (a.refCount != null) {
          children.add(
            Text('F2L sonuna kadar ${a.refCount} hamle', style: muted),
          );
        }
      }

      if (a.skips.isNotEmpty) {
        children.add(section('Skip fırsatları'));
        for (final s in a.skips) {
          children.add(
            Text(
              '${_skipNames[s.kind] ?? s.kind}'
              '${s.note.isEmpty ? '' : ' · ${s.note}'}',
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
    'none' => 'köşeler hazır (2. adım yok)',
    'Headlights' => 'Farlar',
    'Bowtie' => 'Papyon',
    _ => o,
  };

  static String _edgeName(String e) => switch (e) {
    'dot' => 'nokta',
    'L' => 'L',
    'line' => 'çizgi',
    'cross' => 'artı hazır',
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
