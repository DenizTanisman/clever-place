import 'package:flutter/material.dart';

import '../lux.dart';
import '../tutorial.dart';

/// Point numbering used in the diagrams (same as the game):
///
///  0-----1-----2
///  | 3---4---5 |
///  | | 6-7-8 | |
///  9-10-11 12-13-14
///  | | 15-16-17| |
///  | 18--19--20|
/// 21----22----23
const morrisTutorials = GameTutorials(
  rules: '''
- Tahtada 24 nokta var; ikiniz de **9'ar taşla** başlarsınız. Tek bölümlerde sen, çift bölümlerde rakip başlar.
- **Yerleştirme:** sırayla boş bir noktaya taş koyarsınız — taşı tepsinden sürükle ya da noktaya dokun.
- **Kaydırma:** 18 taş yerleşince bir taşını çizgi boyunca komşu boş noktaya sürükle. **3 taşa düşen** taraf **uçar**: taşını istediği boş noktaya götürür.
- Bir çizgide 3 taşını yan yana getirmek **değirmen**dir: rakibin değirmende olmayan bir taşını alırsın (hepsi değirmendeyse herhangi birini). Değirmeni açıp yeniden kapatmak yine sayılır.
- Rakibini **2 taşa indirirsen** ya da **hamle yapamaz** hâle getirirsen kazanırsın.
- **Berabere:** aynı konum üçüncü kez gelirse ya da kaydırma evresinde 50'şer hamle boyunca hiç taş alınmazsa.
- Yıldızlar: geri al ve ipucu kullanmadan, en az **5 taşın** kalarak kazanırsan 3; yardımsız ama daha az taşla 2; geri al ya da ipucu kullandıysan 1.''',
  mid: [
    TutorialSection(
      'Açılış: köşe değil kavşak',
      '''Ortadaki karenin dört kenar ortası (**4, 10, 13, 19**) dört yöne bağlanan **kavşaklardır**. Köşelerin ise yalnızca iki komşusu vardır.

- Yerleştirmede değirmen kovalamak yerine önce kavşakları tut: kaydırma evresinde en çok hareket bu noktalardan çıkar.
- Köşeye konan taş kolayca kilitlenir; rakip iki taşla onu felç eder.
- Rakibin bir kavşağı aldıysa yanındaki kenar ortalarına yerleşip o taşın yollarını daralt.

Kural: yerleştirmenin sonunda **kaç hamlen olacağını** düşünerek koy, kaç taşın olacağını değil.''',
      diagram: _MorrisDiagram(hi: [4, 10, 13, 19], caption: 'Altın halkalar: dört kavşak'),
    ),
    TutorialSection(
      'Çatal: iki tehdidi birden aç',
      '''Bir taşla **iki açık ikili** kurarsan rakip ancak birini kapatabilir; öbürü değirmen olur.

Örnek: 2 ve 21'de taşın var. **0'a** koyduğun an iki tehdit doğar: 1'e koyarsan üst sıra, 9'a koyarsan sol sütun değirmen olur. Rakip birini kapatır, sen öbürünü tamamlarsın.

Çatal noktasını önceden hazırla: aynı noktadan geçen iki çizginin her birine **birer taş** koy, ikisi de rakipten boş kalsın. Rakip de aynı şeyi yapar — onun ortak noktalarını erken doldur.''',
      diagram: _MorrisDiagram(you: [2, 21], hi: [0], dots: [1, 9], caption: '0 → iki tehdit: 1 ve 9'),
    ),
    TutorialSection(
      'Sıra kimde: kapat mı, engelle mi?',
      '''İkinin de açık bir ikilin varsa ve sıra sendeyse **önce kendi değirmenini kapat**: taş alma hakkını kullanıp rakibin **tehdit eden ikilisinden** bir taş al. Böylece hem bir taş kazanırsın hem de onun tehdidini söndürürsün.

Kendi tehdidin yoksa rakibin açık ikilisini **hemen** kapat; bir tur gecikmek bir taşa mal olur.

Dikkat: engellemek için koyduğun taş kendi işine de yarasın — mümkünse aynı anda yeni bir ikili kuran ya da bir kavşağı tutan noktayı seç.''',
    ),
    TutorialSection(
      'Hangi taşı almalı?',
      '''Değirmen kurunca alacağın taşı rastgele seçme. Sırayla bak:

- **Tehdit taşı:** rakibin bir sonraki hamlede değirmene çevirebileceği ikilinin taşı.
- **Kilit taşı:** senin değirmen noktanı kapatan ya da senin taşlarını hapseden taş.
- **En hareketli taş:** kaydırma evresinde rakibin oyununu taşıyan, çok komşusu boş olan taş.

Zaten kilitli, hiçbir yere gidemeyen bir taşı alma: zararsızdır, üstelik onu alınca rakibe yer açarsın. İpucu düğmesi alınacak taşı da gösterir.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Cırtcak: koşan değirmen',
      '''Oyunun adını veren silah: **tek bir taşın iki değirmen arasında gidip gelmesi**. Her hamlen bir değirmen kapatır, yani her hamlede bir taş alırsın.

Kuruluş: 3-4-5 değirmenin ve üst sırada 0 ile 2'de taşların var, 1 boş. 4'teki taşı **1'e** kaydır: üst sıra kapanır, taş al. Sonra **4'e** geri dön: orta sıra kapanır, yine taş al.

Rakibin bunu durdurmasının tek yolu boşalan noktaya (1 ya da 4) bir taş sokmaktır. Bu yüzden önce **komşu noktaları kendin tut** (burada 7): rakibin yaklaşamadığı bir cırtcak oyunu bitirir.''',
      diagram: _MorrisDiagram(you: [0, 2, 3, 4, 5], hi: [7], dots: [1], arrows: [[4, 1]], caption: '4 ↔ 1: her hamle bir değirmen · 7\'yi sen tut'),
    ),
    TutorialSection(
      'Kilitleme: hareketlilik taştan değerlidir',
      '''Kaydırma evresinde **hamle yapamayan taraf kaybeder** — taşı daha çok olsa bile. Bu yüzden bir taş eksik ama özgür bir dizilim, bir taş fazla ama sıkışmış bir dizilimden çoğu zaman iyidir.

- Her hamleden önce rakibin **kaç hamlesi** kaldığını say. Üçün altına inince kilit kokusu var.
- Taşlarını rakibin boşluklarının **yanına** koy: her komşu nokta onun bir yolunu kapatır.
- Kendi taşlarını çizgilerin uçlarına, köşelere yığma; kenar ortaları ve kavşaklar seni nefessiz bırakmaz.

Taş almak yerine kilitlemeyi seçtiğin anlar olur: son yolu kapatan hamle, bir değirmenden daha güçlüdür.''',
      diagram: _MorrisDiagram(you: [1, 9, 22], ai: [0, 21], caption: 'Üç taş, köşedeki iki rakip taşı kilitliyor'),
    ),
    TutorialSection(
      'Uçma oyunu: 3 taşla savaş',
      '''3 taşa düşen taraf her boş noktaya uçabilir. Bu, oyunun karakterini değiştirir:

- **Uçanın** her açık ikilisi (iki taş + boş üçüncü nokta) anında bir tehdittir; komşuluk gerekmez.
- **Sen uçuyorsan:** aynı anda iki açık ikili kur. Rakip birini kapatır, öbüründen değirmen gelir ve rakip de 3'e iner ya da kaybeder.
- **Rakip uçuyorsa:** onun iki taşının aynı çizgide kalmasına izin verme; boş üçüncü noktayı hemen doldur. Kendi değirmenini kapatırken **onun ikilisinden** taş al.

3'e 3'te ilk çatalı kuran kazanır; sıranın kimde olduğunu iki hamle ileriden hesapla.''',
    ),
    TutorialSection(
      'Beraberlik çizgisi: tekrar ve 50 hamle',
      '''Aynı konum (aynı taşlar, aynı sıra) **üçüncü kez** gelirse ya da kaydırma evresinde **50'şer hamle** taş alınmazsa oyun berabere biter. Tahtanın altında kalan tur sayısı ve tekrar uyarısı görünür.

- **Öndeysen:** aynı iki noktada gidip gelme; her birkaç hamlede bir yeni bir ikili kur, rakibi kilide zorla ve sayaç dolmadan taş al.
- **Gerideysen:** sağlam bir **kale** kur (değirmende duran, açılmayan taşlar) ve tekrara oyna — beraberlik, kayıptan iyidir.
- Üst seviye rakipler kazanırken tekrardan kaçar, kaybederken tekrarı arar; ona fırsat verme.''',
    ),
  ],
);

const List<(int, int)> _xy = [
  (0, 0), (3, 0), (6, 0), (1, 1), (3, 1), (5, 1), (2, 2), (3, 2), (4, 2), (0, 3), (1, 3), (2, 3),
  (4, 3), (5, 3), (6, 3), (2, 4), (3, 4), (4, 4), (1, 5), (3, 5), (5, 5), (0, 6), (3, 6), (6, 6),
];

/// Small morris board for tutorials: your stones (ivory), the opponent's (garnet), gold rings on
/// highlighted points, gold dots on threat points, arrows for moves.
class _MorrisDiagram extends StatelessWidget {
  final List<int> you, ai, hi, dots;
  final List<List<int>> arrows;
  final String? caption;
  const _MorrisDiagram(
      {this.you = const [], this.ai = const [], this.hi = const [], this.dots = const [], this.arrows = const [], this.caption});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(width: 190, height: 190, child: CustomPaint(painter: _DiagramPainter(this))),
        if (caption != null) ...[
          const SizedBox(height: 6),
          Text(caption!, style: Lux.ui(12, color: Lux.muted), textAlign: TextAlign.center),
        ],
      ],
    );
  }
}

class _DiagramPainter extends CustomPainter {
  final _MorrisDiagram d;
  _DiagramPainter(this.d);

  @override
  void paint(Canvas canvas, Size size) {
    final b = Offset.zero & size;
    final rr = RRect.fromRectAndRadius(b, const Radius.circular(12));
    canvas.drawRRect(
        rr,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF4B2415), Color(0xFF2A120A), Color(0xFF1C0C06)],
          ).createShader(b));
    canvas.drawRRect(rr.deflate(1), Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..shader = Lux.foil.createShader(b));
    final m = size.width * 0.1, cell = (size.width - 2 * m) / 6;
    Offset pt(int p) => Offset(m + _xy[p].$1 * cell, m + _xy[p].$2 * cell);
    final line = Paint()
      ..strokeWidth = 1.6
      ..shader = Lux.foil.createShader(b);
    for (final sq in const [(0, 6), (1, 5), (2, 4)]) {
      final a = m + sq.$1 * cell, z = m + sq.$2 * cell;
      canvas.drawRect(Rect.fromLTRB(a, a, z, z), line..style = PaintingStyle.stroke);
    }
    for (final c in const [(1, 7), (9, 11), (12, 14), (16, 22)]) {
      canvas.drawLine(pt(c.$1), pt(c.$2), line);
    }
    for (var p = 0; p < 24; p++) {
      canvas.drawCircle(pt(p), 2.6, Paint()..color = Lux.gold);
    }
    final r = cell * 0.4;
    final gold = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Lux.goldLight;
    // Moves: a curved double arrow bowing out to the side, so short hops stay readable.
    for (final a in d.arrows) {
      final s = pt(a[0]), e = pt(a[1]);
      final u = (e - s) / (e - s).distance;
      final n = Offset(-u.dy, u.dx);
      final bow = cell * 0.75;
      final p0 = s + n * r * 0.9, p1 = e + n * r * 0.9;
      final ctrl = (s + e) / 2 + n * bow;
      canvas.drawPath(
          Path()
            ..moveTo(p0.dx, p0.dy)
            ..quadraticBezierTo(ctrl.dx, ctrl.dy, p1.dx, p1.dy),
          gold);
      for (final (tip, from) in [(p1, ctrl), (p0, ctrl)]) {
        final dir = (tip - from) / (tip - from).distance;
        final side = Offset(-dir.dy, dir.dx);
        canvas.drawLine(tip, tip - dir * 6 + side * 4, gold);
        canvas.drawLine(tip, tip - dir * 6 - side * 4, gold);
      }
    }
    for (final p in d.hi) {
      canvas.drawCircle(pt(p), r * 1.2, Paint()
        ..color = Lux.gold.withValues(alpha: 0.3)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
      canvas.drawCircle(pt(p), r * 1.05, gold);
    }
    for (final p in d.dots) {
      canvas.drawCircle(pt(p), r * 0.42, Paint()..color = Lux.goldLight);
    }
    void stone(int p, bool mine) {
      final c = pt(p);
      canvas.drawCircle(c + const Offset(0.8, 1.6), r, Paint()..color = Colors.black.withValues(alpha: 0.5));
      canvas.drawCircle(
          c,
          r,
          Paint()
            ..shader = RadialGradient(
              center: const Alignment(-0.35, -0.45),
              colors: mine
                  ? const [Color(0xFFFFFFFF), Color(0xFFF4ECDD), Color(0xFF9C8B70)]
                  : const [Color(0xFFD0607E), Color(0xFF6A1830), Color(0xFF150409)],
              stops: const [0, 0.45, 1],
            ).createShader(Rect.fromCircle(center: c, radius: r)));
      canvas.drawCircle(c + Offset(-r * 0.32, -r * 0.38), r * 0.22, Paint()..color = Colors.white.withValues(alpha: mine ? 0.7 : 0.45));
    }

    for (final p in d.you) {
      stone(p, true);
    }
    for (final p in d.ai) {
      stone(p, false);
    }
  }

  @override
  bool shouldRepaint(_DiagramPainter old) => old.d != d;
}
