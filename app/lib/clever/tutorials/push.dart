import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../lux.dart';
import '../tutorial.dart';

const pushTutorials = GameTutorials(
  rules: '''
- 61 hücrelik altıgen tahtada 14'er bilye: sen **inci** bilyelerle, rakip **lal** bilyelerle oynar. Tek bölümlerde sen, çift bölümlerde rakip başlar; diziliş bölümden bölüme değişir (Klasik, Papatya, Ayna, Mızrak, Hilal).
- Hamle: tek sırada yan yana duran **1, 2 ya da 3** bilyeni seç ve altı yönden birine bir adım kaydır. Sıranın **kendi doğrultusunda** giderse önü boş olmalı (ya da itebileceğin bir rakip sıra olmalı); **yanlamasına** giderse gittiği her hücre boş olmalı.
- **İtiş**: kendi doğrultusunda ilerleyen sıran, hemen önündeki rakip sıradan **kalabalıksa** onu bir adım iter: 3 > 2, 3 > 1, 2 > 1. Rakip sıranın arkası boş ya da tahtanın kenarı olmalı; arkasında senin bilyen varsa itemezsin. Denk sıralar (1–1, 2–2, 3–3) birbirini itemez.
- Kenardan itilen bilye oluğa düşer ve oyundan çıkar. Rakibin **6 bilyesini** düşüren kazanır. Kendi bilyeni tahtadan atamazsın.
- Oynamak için: parmağını bilyelerinin üstünden kaydırarak 1–3 tanesini seç, kaydırmaya devam et ya da grubu gitmek istediğin yöne sürükleyip bırak. Altın oklar geçerli, bordo oklar geçersiz yönlerdir; oka ya da bilyenin gideceği hücreye dokunmak da olur.
- **Durma kuralı**: 100 hamle boyunca bilye düşmezse ya da aynı konum 3 kez tekrarlanırsa oyun durur: bilyesi çok olan kazanır, eşitse berabere.
- Yıldızlar: geri alma ve ipucu kullanmadan, en fazla **2 bilye** kaybederek kazanırsan 3; geri alma/ipucu olmadan 2; kullandıysan 1 yıldız.''',
  mid: [
    TutorialSection(
      'Merkezde ve toplu kal',
      '''Bu oyunda en değerli yer **merkez**dir. Ortadaki bilyeyi kenara itmek için rakibin onu dört adım taşıması gerekir; kenardakini tek itiş düşürür.

- Açılışta bütün grubunu merkeze doğru yürüt; rakip merkezi önce tutarsa sen kenara yaslanırsın.
- **Toplu kal**: her bilyenin mümkün olduğunca çok komşusu kendi bilyen olsun. Petek gibi sıkı bir kümede her doğrultu en az üç bilye derindir; 3'ten fazlası itemeyeceği için böyle bir küme **hiçbir yönden itilemez**.
- Delikli, ince ya da uzun bir dizilişin her deliği rakibe bir itiş hattı açar. Sıkı kal, rakibi sen dağıt.''',
      diagram: _HexDiagram([
        '. x . . x',
        '. . . . x .',
        '. . . . . . .',
        'x . . o o . . x',
        'x . . o *o o . . .',
        '. . o o o o . .',
        '. . o o o . x',
        '. . . . . .',
        '. . . . .',
      ], caption: 'İnciler merkezde ve sıkı; lal bilyeler kenara dağılmış'),
    ),
    TutorialSection(
      'Kenarda yalnız bilye bırakma',
      '''Kenardaki bir bilye, dışarı bakan her doğrultuda tehlikededir. Kenar ortasındaki hücrenin iki, köşe hücresinin **üç** dış yönü vardır.

- Her dış yön için içeri doğru say: kenardaki bilyenin arkasında kaç bilyen var? Toplam **k** ise rakip ancak **k+1** bilyelik bir sırayla iter. Arkasında iki bilyen varsa (toplam 3) o yönden asla itilemez.
- Yalnız kenar bilyesi (k = 1) iki rakip bilyeyle düşer; çifti (k = 2) üçlü bir sırayla.
- Kenara itildiysen önce onu destekle ya da içeri çek; rakibin iki yerden birden tehdit etmesine izin verme. Bir tehdidi karşılarsın, ikisini nadiren.''',
      diagram: _HexDiagram([
        '. . . . .',
        '. . . . . .',
        '. . . . . . .',
        '. . . . . . . .',
        '. . . . . . . . .',
        '. . . . . x . .',
        '. . *x . o x .',
        'o . *x . o .',
        'o o !o . o',
      ], caption: 'İki lal, kenardaki yalnız inciyi oluğa iter. Sağdaki köşe incisi arkasındaki ikiyle o yönden güvende.'),
    ),
    TutorialSection(
      'İtiş sayımı',
      '''Bir itişe girişmeden önce aynı doğrultu üzerinde say:

- **Senin sıran**: itiş yönünde arka arkaya kaç bilyen var (en çok 3 sayılır)?
- **Rakip sıra**: hemen önünden başlayarak arka arkaya kaç rakip bilye var? Seninkinden az olmalı.
- **Arkası**: rakip sıranın bittiği hücre boş ya da tahtanın dışı olmalı. Orada **senin** bilyen varsa itiş kilitlenir; rakibin bir bilyesi daha varsa sayıya eklenir.

Sonra bir kez de ters yönden bak: itişten sonra öne çıkan bilyen rakibin bir karşı itişine açık mı? İyi bir itiş, bilye düşürmese bile rakibi kenara sıkıştırır.''',
      diagram: _HexDiagram([
        '. . . . .',
        '. . . . . .',
        '. o o o !x o .',
        '. . . . . . . .',
        '. o o o *x *x + . .',
        '. . . . . . . .',
        '. . o o !x !x .',
        '. . . . . .',
        '. . . . .',
      ], caption: 'Ortada 3 > 2 itiş (+ itilenin gideceği yer). Üstte arkada kendi bilyen, altta 2–2 denk: ikisi de itilemez.'),
    ),
    TutorialSection(
      'Yanlamasına hamleyle konum değiştir',
      '''Yanlamasına hamle, sırayı şeklini bozmadan bir şerit kaydırır. İtemez ama çok işe yarar:

- **Boşluk kapatmak**: kümende bir delik açıldıysa yan kaydırma onu tek hamlede kapatır.
- **Hat kurmak**: bir itiş için doğru şeride geçmek; örneğin rakibin iki bilyesinin hizasına üçlü bir sıra getirmek.
- **Tehditten çekilmek**: kendi doğrultusunda geri gitmek kümede delik açarken, yan kaydırma tüm sırayı birlikte taşır.

Kural: gidilecek **her** hücre boş olmalı. İtme imkânın yokken, bir sonraki itişi hazırlayan sakin bir yan hamle çoğu zaman en güçlüsüdür.''',
      diagram: _HexDiagram([
        '. . . . .',
        '. . . . . .',
        '. . . . . . .',
        '. . . . . x x .',
        '. . . x + + + . .',
        '. . . *o *o *o . .',
        '. . o o . . .',
        '. . . . . .',
        '. . . . .',
      ], caption: 'Üçlü inci sırası yanlamasına (+) boşluğa geçer ve iki lalin hizasına oturur'),
    ),
  ],
  advanced: [
    TutorialSection(
      'Kama: rakip grubu böl',
      '''Toplu bir grup güçlü, iki parçaya bölünmüş grup zayıftır: her parçanın daha çok kenarı, daha çok itilebilir hattı vardır.

- Rakip kümenin **ortasına**, en ince yerine üçlü bir sırayla gir. 3 > 1 ya da 3 > 2 itişle içeri girdiğinde kama, iki parçanın arasında kalır.
- Kamanın iki yanı da rakibe dönüktür; arkasını (kendi doğrultusunu) destekli tut ki geri itilemesin.
- Bölünen parçaların küçüğünü kenara doğru sür: tek başına kalan iki-üç bilye, kenarda kolay lokmadır.''',
      diagram: _HexDiagram([
        '. . . . .',
        '. . . x . .',
        'x x . x x x .',
        'x x x !x x x . .',
        '. x x . *o . . . .',
        '. . . . *o o . .',
        '. . . o *o o .',
        '. . . o . .',
        '. . . . .',
      ], caption: 'Üçlü kama tek lali iter ve iki lal kümesinin arasına girer'),
    ),
    TutorialSection(
      'Pat: denk sıralar itemez',
      '''Aynı doğrultuda karşı karşıya duran **denk** sıralar (1–1, 2–2, 3–3) birbirini itemez. Buna **pat** denir ve iki yönlü bir silahtır.

- **Savunma**: rakip sana ikili bir sırayla bakıyorsa, karşısına ikili koymak o hattı dondurur. 3–3 pat kalıcıdır, çünkü dördüncü bilye sayılmaz.
- **Patı bozmak**: kendi sırana arkadan bir bilye ekle (2–2 yerine 3–2) ya da rakip sıranın bir bilyesini yandan kaydırmaya zorla.
- Rakibin patı bozabileceği hatları önceden gör: ikili patın arkasındaki boş hücre, rakip için de bir fırsattır.''',
      diagram: _HexDiagram([
        '. . . . .',
        '. . . . . .',
        '. . . . . . .',
        '. + *o *o !x !x . .',
        '. . . . . . . . .',
        '. o o o x x x .',
        '. . . . . . .',
        '. . . . . .',
        '. . . . .',
      ], caption: 'Altta 3–3: donmuş hat. Üstte 2–2 pat; + hücresine üçüncü inci gelince 3 > 2 itiş açılır.'),
    ),
    TutorialSection(
      'Tempo ve sıkıştırma',
      '''Bu oyunda pas yoktur: sırası gelen oynamak **zorundadır**. Sağlam bir kurulumu bozmadan yapılabilecek hamleler tükenince oyuncu kendini zayıflatır.

- **Tempo hamlesi**: cephe hattına dokunmadan, arkada zararsız bir yan kaydırma. Rakip bu sırada hamle yapmak zorunda kalır.
- **Zorlayıcı tehdit**: kenardaki bir bilyeyi tehdit etmek rakibin cevabını belirler; o savunurken sen bir sonraki itişi kurarsın.
- **Sıkıştırma**: rakibin bütün sıraları patta ve arkasında boşluk yoksa, ilk kıpırdayan delik açar. Sabırlı ol; sağlam kalan taraf çoğu zaman kazanır.
- Öndeyken durma kuralı senin lehine işler: 100 hamle bilye düşmezse bilyesi çok olan kazanır.''',
    ),
    TutorialSection(
      'Son oyunda itiş kalıpları',
      '''Bilyeler azaldıkça tahta açılır ve kenar yakınlaşır. Bilinen kalıplar:

- **Çift tehdit**: iki ayrı kenar bilyesini aynı anda tehdit et. Rakip birini kurtarır, öbürü düşer.
- **Köşe tuzağı**: köşedeki bilyenin üç dış yönü vardır; tek bilyeyle hepsini kapatamaz.
- **Kenarda 3 > 2**: kenara dayalı iki rakip bilyeye üçlüyle vurursan dıştaki düşer, içteki kenara çakılır; bir sonraki itişte o da hedeftir.
- İtişten sonra **senin** sıran öne çıkmış olur; düşürdüğün yerde rakibin bir karşı itişi var mı, mutlaka bak.
- Öndeysen bilye takasından korkma: 6'ya önce sen ulaşırsın. Gerideysen merkezi tut ve sıkı kal; acele eden rakip kenara yaklaşır.''',
      diagram: _HexDiagram([
        '. !x . . .',
        '. . *o x . .',
        '. . o *o *o *o !x',
        '. . . . . . . .',
        '. . . . . . . . .',
        '. . . . . . . .',
        '. . . . . . .',
        '. . . . . .',
        '. . . . .',
      ], caption: 'Çift tehdit: iki inci ikilisi, kenardaki iki lali aynı anda hedefliyor'),
    ),
  ],
);

/// Small hexagonal board for tutorials. [rows] = the nine rows top to bottom (5, 6, 7, 8, 9, 8, 7,
/// 6, 5 tokens): `.` empty · `o` your pearl · `x` the AI's garnet · `+` target cell (gold dot);
/// prefix `*` = gold ring (the move's actors), `!` = bordeaux ring (in danger / blocked).
class _HexDiagram extends StatelessWidget {
  final List<String> rows;
  final String? caption;
  const _HexDiagram(this.rows, {this.caption});

  @override
  Widget build(BuildContext context) {
    const s = 26.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: s * 10.4,
          height: s * 9.0,
          child: CustomPaint(painter: _HexDiagramPainter(rows)),
        ),
        if (caption != null) ...[
          const SizedBox(height: 6),
          Text(caption!, style: Lux.ui(12, color: Lux.muted), textAlign: TextAlign.center),
        ],
      ],
    );
  }
}

class _HexDiagramPainter extends CustomPainter {
  final List<String> rows;
  _HexDiagramPainter(this.rows);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 10.4;
    final c = size.center(Offset.zero);
    const k = 0.8660254;
    Path hex(double r) {
      final p = Path();
      for (var i = 0; i < 6; i++) {
        final v = c + Offset(math.cos(i * math.pi / 3), math.sin(i * math.pi / 3)) * r;
        if (i == 0) {
          p.moveTo(v.dx, v.dy);
        } else {
          p.lineTo(v.dx, v.dy);
        }
      }
      return p..close();
    }

    final rect = Offset.zero & size;
    canvas.drawPath(hex(s * 5.15), Paint()..shader = Lux.foil.createShader(rect));
    canvas.drawPath(hex(s * 5.0), Paint()..color = const Color(0xFF060403));
    canvas.drawPath(
        hex(s * 4.62),
        Paint()
          ..shader = const RadialGradient(
            center: Alignment(-0.3, -0.4),
            colors: [Color(0xFF3A2416), Color(0xFF160C06)],
          ).createShader(rect));
    canvas.drawPath(
        hex(s * 4.62),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Lux.gold.withValues(alpha: 0.6));

    for (var ri = 0; ri < rows.length && ri < 9; ri++) {
      final r = ri - 4;
      final toks = rows[ri].trim().split(RegExp(r'\s+'));
      final q0 = math.max(-4, -4 - r);
      for (var j = 0; j < toks.length; j++) {
        final q = q0 + j;
        final p = c + Offset((q + r / 2) * s, r * k * s);
        var t = toks[j];
        Color? ring;
        if (t.startsWith('*')) {
          ring = Lux.goldLight;
          t = t.substring(1);
        } else if (t.startsWith('!')) {
          ring = Lux.bordeauxLight;
          t = t.substring(1);
        }
        canvas.drawCircle(p, s * 0.36, Paint()..color = const Color(0xFF0A0604));
        canvas.drawCircle(
            p,
            s * 0.36,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 0.8
              ..color = const Color(0xFFFFD9A0).withValues(alpha: 0.18));
        if (t == 'o' || t == 'x') {
          final pearl = t == 'o';
          final rr = s * 0.43;
          canvas.drawCircle(
              p,
              rr,
              Paint()
                ..shader = RadialGradient(
                  center: const Alignment(-0.38, -0.45),
                  radius: 1.05,
                  colors: pearl
                      ? const [Color(0xFFFFFFFF), Color(0xFFF1E9D8), Color(0xFFC9BC9F), Color(0xFF5E5442)]
                      : const [Color(0xFFFFA3B6), Color(0xFFB8223F), Color(0xFF5E0A1F), Color(0xFF1E0309)],
                  stops: pearl ? const [0, 0.22, 0.64, 1] : const [0, 0.3, 0.74, 1],
                ).createShader(Rect.fromCircle(center: p, radius: rr)));
          canvas.drawCircle(p + Offset(-rr * 0.35, -rr * 0.45), rr * 0.14, Paint()..color = Colors.white.withValues(alpha: 0.85));
        } else if (t == '+') {
          canvas.drawCircle(
              p,
              s * 0.22,
              Paint()
                ..color = Lux.gold.withValues(alpha: 0.45)
                ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
          canvas.drawCircle(p, s * 0.12, Paint()..color = Lux.goldLight);
        }
        if (ring != null) {
          canvas.drawCircle(
              p,
              s * 0.5,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2
                ..color = ring);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_HexDiagramPainter old) => old.rows != rows;
}
