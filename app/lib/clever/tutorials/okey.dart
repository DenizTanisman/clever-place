import 'package:flutter/material.dart';

import '../games/okey_view.dart';
import '../lux.dart';
import '../tutorial.dart';

// Tile ids as in the game: copy × 52 + colour × 13 + (number − 1); colours 0 kırmızı · 1 siyah ·
// 2 mavi · 3 sarı; 104 = sahte okey. -1 = an empty rack slot in a diagram.
const okeyTutorials = GameTutorials(
  rules: '''
**101 Okey**
- Taşlar klasikteki gibi: 106 taş, gösterge, **okey** (göstergenin bir üstü; her taşın yerine geçer) ve 2 **sahte okey** (okeyin kendi değeri olarak oynar).
- Herkes **21** taş alır, başlayan **22** alır ve ilk o atar; ortada 20 taş kalır. Sıran gelince desteden çek ya da soldakinin attığını al, sonra bir taş at.
- Yandan aldığın taşı **aynı el kullanmalısın**: açılışında, yeni bir perde ya da işleyerek. Kullanamayacağın taşı alamazsın; vazgeçersen **Geri ver** (o elki hamlelerin geri alınır).
- **Elini açmak**: tek seferde toplamı en az **101** olan perler indir (seri: aynı renk ardışık, en az 3, 12-13-1 olur, 13-1-2 olmaz; takım: aynı sayı farklı renk, 3–4 taş). Taşların üstündeki sayılar toplanır, okey yerine geçtiği taş kadar sayılır. Ya da en az **5 çift** indir. Eşik sabittir: başkası kaçla açmış olursa olsun 101 yeter.
- Açtıktan sonra yeni per indirebilir ve masadaki **her pere işleyebilirsin**: serinin ucuna, takımın eksik rengine. Çiftle açan yalnız çift indirir ama perlere işleyebilir; çiftlere işlenmez. Masadaki okey geri alınmaz.
- **Bitmek**: her şeyi indirip **son taşını atınca** bitersin; elinde hep atacak bir taş kalmalı.
- **Puan (düşük iyidir)**: biten **−101** yazar; açmış olanlar elinde kalan taşların toplamını (okey ve sahte okey okeyin sayısı kadar), **açmayan 202** yazar. Okeyle bitmek ya da çiftten açıp bitmek eli **2 katına** çıkarır (ikisi birden 4 kat). **101 ceza**: masadaki bir pere işlenebilecek taşı ya da okeyi atmak.
- Deste biterse el biter, herkes elindekini yazar. Maç 3, 5 ya da 7 el sürer (ilk elde **el** düğmesiyle seç); toplamı en düşük olan kazanır.
- **Aç** düğmesi rafında dizdiğin perlerin toplamını canlı gösterir (**87 / 101**); bir peri dışarıda bırakmak için rafın altındaki puan etiketine dokun. **Açılabilir mi?** en iyi açılışı dizer ve söyler. İşlemek için taşı masadaki pere sürükle; serinin hangi yarısına bırakırsan o uca gider. Rafta **altın nokta**: bu taş işlenebilir; **bordo nokta**: atarsan 101 ceza (cezalı bir taşı yine de atmak için ikinci kez at).

**Klasik Okey**
- 106 taş: dört renk (kırmızı, siyah, mavi, sarı) × 1–13, her taştan **iki** tane, bir de 2 **sahte okey**. Ortaya açılan **göstergenin** bir üstü (aynı renk; 13'ün üstü 1) **okey**dir ve her taşın yerine geçer; rafında küçük altın yıldızla işaretlidir. Sahte okey joker değildir: okeyin kendi değeri olarak oynar.
- Başlayan 15, diğerleri 14 taş alır. Sıran gelince **ortadan çek** ya da **soldakinin attığı** taşı al, sonra bir taş at — onu sağındaki alabilir.
- 15. taşını ortaya bırakıp kalan **14 taşın hepsi per** olunca bitirirsin: **seri** (aynı renk, ardışık, en az 3; 12-13-1 olur, 13-1-2 olmaz), **takım** (aynı sayı, farklı renk, 3–4 taş) ya da **7 çift**.
- Puan: herkes 20 ile başlar. Biri bitirince diğerleri **2** kaybeder; çiftle ya da okey atarak bitirirse **4**, ikisi birden **8**. Göstergenin eşi elinde olan onu kendiliğinden gösterir: diğerleri 1 kaybeder. Ortada taş kalmazsa el berabere.
- Maç **5 el** sürer (biri 0'a düşerse erken biter). En yüksek puan senindeyse kazanırsın, eşitlikte berabere.
- Taşları sürükleyerek rafa diz (boşluk bırakabilirsin); geçerli perlerin altında altın çizgi belirir. Atmak için sağ alttaki yere, bitirmek için ortaya sürükle. **Seri diz / Çift diz** otomatik dizer, ampul en iyi hamleyi gerekçesiyle söyler, göz (**Açık oyna**) bütün rafları, sıradaki taşları ve rakiplerin gerekçelerini açar.''',
  mid: [
    TutorialSection(
      '101: elini açmak — puanı saymak',
      '''101'de ilk hedef **açmak**: açmayan eli **202** yazar, en kötü sonuç budur.

- Puan, indirdiğin perlerdeki taşların **üstündeki sayıların toplamıdır**. Kırmızı 10-11-12-13 = 46, 13'ler takımı (üç renk) = 39, mavi 5-6-7 = 18 → **103**: açabilirsin.
- **Okey** yerine geçtiği taş kadar sayılır: 9 _ 11 serisinde okey 10 değerindedir. Bir okeyi 1-2-3'ün başına değil, yüksek bir serinin ucuna koymak puanı artırır.
- 12-13-1 serisindeki 1, **1 puan** sayar; yüksek seriler ve yüksek takımlar açmanın anahtarıdır.
- Küçük taşlar (1–4) açılışa az katkı yapar: açmadan önce ilk onlar gider.
- Rafa dizdiğin her per altın çizgiyle işaretlenir ve puanı rafın altında yazar; **Aç** düğmesi toplamı canlı tutar. Emin değilsen **Açılabilir mi?**: en iyi dizilimi bulur ve "Açabilirsin: 4 per, 112 puan" ya da "en iyi dizilim 87 puan" der.''',
      diagram: _Rack([9, 10, 11, 12, -1, 25, 38, 51, -1, 30, 31, 32], caption: '46 + 39 + 18 = 103: açabilirsin'),
    ),
    TutorialSection(
      '101: işlemek ve 101 cezası',
      '''Açtıktan sonra masadaki **her pere** taş ekleyebilirsin — kendi perlerine de, rakiplerinkine de.

- Seri iki ucundan uzar: kırmızı 4-5-6'ya kırmızı 3 ya da 7 işlenir. 13'ün üstüne 1 gelebilir, 1'in altına bir şey gelmez.
- Takım 4 renge kadar büyür: 7'ler (siyah, mavi, sarı) kırmızı 7'yi ya da okeyi alır.
- Çiftlere işlenmez. Okey her pere işlenebilir ama okeyi en son, bitirirken kullanmak çoğu zaman daha değerlidir.
- **Altın kural**: masadaki bir pere uyan taşı **atma** — işlenebilir taş atmak **101 ceza** yazdırır (henüz açmamış olsan bile). Okeyi atmak da 101 cezadır. Rafındaki bordo noktalar bu taşları gösterir.
- İşlediğin her taş elinde kalsaydı puan yazacaktı: açtıktan sonra işleyebildiğini hemen işle.''',
      diagram: _Rack([3, 4, 5, -1, 6], caption: 'Masadaki kırmızı 4-5-6\'ya kırmızı 7 işlenir; atarsan 101 ceza'),
    ),
    TutorialSection(
      '101: yandan almak',
      '''Soldakinin attığı taşı alabilirsin ama **aynı el kullanmak zorundasın**.

- Henüz açmadıysan: o taşla **bu el açabiliyor** olmalısın (taş açılış perlerinin içinde ya da açtıktan hemen sonra işlenecek).
- Açtıysan: taş yeni bir perde, bir çiftte (çiftle açtıysan) ya da masadaki bir perde yer bulmalı.
- Kullanamayacağın taşı oyun aldırmaz ve nedenini söyler. Aldıktan sonra vazgeçersen **Geri ver**: taş geri döner, o el indirdiklerin rafına geri gelir.
- Kullanabileceğin taş desteden gelecek bilinmeyen taştan iyidir: elin bir taş küçülür. Rakipler de böyle oynar — o yüzden **sağındakinin işine yarayacak taşı atma**; açmaya yakın bir oyuncu attığın taşla açabilir.''',
    ),
    TutorialSection(
      '101: puanlama ve maç',
      '''El sonunda herkes puan yazar; **düşük puan iyidir**.

- Biten: **−101**. Açmış olanlar: rafında kalan taşların toplamı. Açmayan: **202**.
- Okeyle bitmek eli **2 katına** çıkarır, çiftten açıp bitmek de; ikisi birden **4 kat** (biten −404 yazar, açmayan 808!). Ceza puanları katlanmaz.
- Her ceza **+101**: işlenebilir taşı ya da okeyi atmak.
- Deste biterse kimse bitmemiş olur: herkes elindekini yazar. Bu yüzden açtıktan sonra **büyük taşlardan kurtul**: elde kalan bir 13, el sonunda 13 yazar.
- Maç 3, 5 ya da 7 el sürer; sonuç kartındaki tablo her elin puanını ve toplamları gösterir. En düşük toplam maçı alır.''',
    ),
    TutorialSection(
      'Taşları dizmek: grupla, boşluk bırak',
      '''İyi dizilmiş raf yarı oyundur. Her perin arasında **bir boşluk** bırak, eksik taşın yerini de boş tut: neyi beklediğini bir bakışta görürsün.

- Bitmiş perleri sola, **ikilileri** ortaya, tek taşları sağa koy. Atılacak aday hep en sağdadır.
- **Açık uçlu ikili** (5-6): 4 de 7 de tamamlar — 4 taş bekler.
- **Arası boş ikili** (5-7): yalnız 6 tamamlar — 2 taş bekler.
- **Takım ikilisi** (kırmızı 9 + mavi 9): kalan iki rengin 9'ları — 4 taş bekler.

Bir şey feda edeceksen önce arası boş ikiliyi boz. Ve bir taşı iki perde sayma: tek kırmızı 7'n ya 5-6-7 serisinde ya 7'ler takımında olur.''',
      diagram: _Rack([4, 5, -1, 8, 34, -1, 16, -1, 18], caption: 'Açık uçlu (4 taş) · takım ikilisi (4 taş) · arası boş (2 taş)'),
    ),
    TutorialSection(
      'Ne atılır: sağındakini besleme',
      '''Attığın taşı **yalnız sağındaki** oyuncu alabilir. Ondan aldıklarını unutma.

- Sağındaki senden **kırmızı 7** aldıysa kırmızı 5-6-8-9 ve öbür renklerin 7'leri ona yarar: bunlar **sıcak** taşlardır.
- Attığın bir taşı **almadıysa** o taşın eşi ve yakın komşuları ona karşı daha güvenlidir; kendi attığı taşlar da öyle.
- Kural: iki aday da elinde aynı eksik sayısını bırakıyorsa sağındakine **daha az yarayanı** at. Eksiğini bir artıracaksa savunmayı bırak, kendi elini oyna.

Orta seviyedeki rakipler tam böyle düşünür; Açık oyna'da "onu atmadı" diye başlayan gerekçeler bu kuralın işidir.''',
    ),
    TutorialSection(
      'Okey\'i ne zaman kullanmalı',
      '''Okey her taştır — onu **asla atma** (bitirme hamlesi hariç).

- Okeyi **en zor gelecek** boşluğa koy: arası boş serinin ortası (5 _ 7) ya da iki kopyası da yerde olan bir taşın yeri. Kolay gelecek taşı (açık uçlu serinin ucunu) desteden beklersin.
- Okey, eksik bir takımı da tamamlar: kırmızı 9 + mavi 9 + okey = per.
- Bitirmeye bir taş kala okey artık gerekmiyorsa onu **son taş olarak at**: okey atarak bitirmek rakiplere 4 puan sildirir.
- **Sahte okey** okey değildir: okey mavi 6 ise sahte okey düz bir mavi 6'dır.''',
      diagram: _Rack([4, 45, 6, -1, 8, 34, 97], okey: 45, caption: 'Okey (sarı 7, yıldızlı) 5 _ 7 boşluğunu ve 9\'lar takımını kapatır'),
    ),
    TutorialSection(
      'Çifte gitmek ne zaman mantıklı',
      '''**7 çift** ayrı bir bitiş yoludur ve **4 puan** sildirir.

- İlk elinde **4 ya da daha fazla çift** (aynı renk, aynı sayı) varsa çifti ciddi düşün; 5 çift + okey çoğu zaman seriden hızlıdır.
- Her tek taşın tek bir eşi vardır. Eşi yere atılmışsa o tek **ölüdür**: okey olmadan çift olmaz, hemen at.
- Çifte gidince soldakinin attığı taş bir tekinin eşiyse **hemen al** — desteden gelmesini beklemek uzun sürer.
- Kararını erken ver: hem seriye hem çifte oynayan el ikisini de kaçırır. **Çift diz** düğmesi elindeki çiftleri yan yana getirir.''',
      diagram: _Rack([4, 56, -1, 21, 73, -1, 38, 90, -1, 104, 105], okey: 99, caption: 'Dört çift: iki sahte okey de kendi aralarında çifttir'),
    ),
  ],
  advanced: [
    TutorialSection(
      '101: atış taktikleri',
      '''101'de iyi atış elin evresine göre değişir.

- **Açmadan önce**: 101'e en az katkı yapan taşı at — hiçbir pere bağlanmayan küçük taşlar önce, sonra arası boş küçük ikililer. Yüksek taşları tut: 12-13'lük bir ikili tamamlanınca tek başına 36 puan getirir.
- **Açtıktan sonra**: hedef bitmek ama deste azaldıysa **en büyük gevşek taşı** at; el sonunda elinde kalanın toplamını yazarsın.
- **Hiçbir zaman**: masaya işlenebilecek taşı ya da okeyi atma (101 ceza).
- **Sağındakini izle**: senden taş alan oyuncu o taşın etrafını topluyor; açmaya yakın görünüyorsa (çok taş tutuyor, perleri dağınık) yüksek ve bağlantılı taşları ona verme.
- **Okeyle bitiş**: son iki taşından biri okeyse, öbürünü işle ya da at, okeyi en son at — el 2 katına çıkar.
- Zor masadaki rakipler bir çekiş ilerisini hesaplar ("en iyi dizilim 94 puan, açmaya 7 eksik") ve hangi taşı neden tuttuğunu söyler; Açık oyna'da okumaya değer.''',
    ),
    TutorialSection(
      '101: çifte gitmek',
      '''**5 çift** de açılıştır ve çiftten açıp biten eli 2 katına çıkarır.

- İlk elinde 4–5 çift varsa ve perlerin 101'e uzaksa çifti ciddi düşün. Çiftle açınca yalnız çift indirebilirsin; tek taşlarından ancak **masadaki perlere işleyerek** kurtulursun.
- Eşi yere düşen tek taş ölüdür: onu ilk sen at.
- Çifte gidiyorsan soldakinin attığı, tek taşlarından birinin eşi olan taşı al — 5. çifti tamamlayıp hemen açarsın.
- Bitiremezsen elinde kalan tek taşlar puan yazar: çiftçiler genellikle masaya işleyerek bitirir, perler açıldıkça şansın artar.''',
    ),
    TutorialSection(
      '101 İmkânsız masa',
      '''101'in İmkânsız masasında rakipler bütün rafları ve destenin **sırasını** görür. Bu bir eğitim aracıdır.

- Sıradaki çekişlerini bildikleri için en hızlı açılışı planlarlar: "destenin sırasını biliyor, 2 çekiş sonra elini açıyor".
- Sağındaki oyuncunun (senin) elini gördükleri için seni açtıracak ya da bitirecek taşı **atmazlar**; desteden mi yandan mı alacaklarını da sana gelecek taşa göre seçerler.
- Kendi aralarında birbirlerini engellemezler — yalnız seni.

Burada maç kazanmak çok nadirdir; elini açıp 202 yazmamak bile iyi bir sonuçtur. Gerekçeleri Açık oyna'da oku.''',
    ),
    TutorialSection(
      'Atılan taşlardan el okumak',
      '''Köşelerdeki yığınlar ve masanın ortasındaki son hamleler herkesin önünde. Oku:

- **Yerden alınan taş** bir ilandır: mavi 4 alan mavi 2-3-5-6'yı ve öbür 4'leri topluyor.
- Bir **rengi sürekli atan** o renkte seri kurmuyor; o rengin taşları ona karşı güvenli.
- Desteden çekip **aynı taşı hemen atan** oyuncunun eli değişmiyor: ya çok uzak ya da tek bir taş bekliyor. Son turlarda ikincisini varsay.
- Senin attığını **almayan** sağındaki o taşın etrafına ihtiyaç duymuyor — en azından o anda.

Açık oyna'yı açıp bir eli izle: tahminini rafla karşılaştırmak el okumayı en hızlı öğreten şeydir.''',
    ),
    TutorialSection(
      'Olasılık: kalan taş sayısı',
      '''Her taştan iki tane var. Beklediğin taşı **say**: kaçı senin elinde, kaçı yerde ya da göstergede? Hiç kalmadıysa o boşluk **ölüdür** — orayı bekleme, o ikiliyi boz.

- Eksik sayın aynıyken işine yarayacak **kalan taş sayısını** (kabul) en çok bırakan atışı seç. 5-6 ikilisi 4 taş, 5-7 ikilisi 2 taş bekler; ama 4'lerin ikisi de yerdeyse 5-6 da yalnız 2 taş bekler.
- Bir çekişte gelme ihtimali kabaca **kabul ÷ görmediğin taş sayısı**dır: 60 görünmeyen taşta 9 kabul ≈ **%15**. Zor rakip gerekçesinde bu yüzdeyi söyler.
- Elin başında **genişlik** (çok kabul), deste azalınca **hız** (az eksik) önemlidir.''',
    ),
    TutorialSection(
      'Savunma atışları',
      '''Bitmeye uzaksan (eksik 3+) ve deste azaldıysa kazanmayı değil **kaybetmemeyi** oyna.

- **En güvenli:** sağındakinin kendi attığı taşın eşi; senin attığın ve almadığı taşlar; iki kopyası da yerde olan sayıların komşuları.
- **En tehlikeli:** sağındakinin aldığı taşın komşuları ve aynı sayının öbür renkleri.
- Sağındaki **ısındıysa** (iki-üç taş almış, desteden çektiğini hemen atıyor) elini bozmak pahasına sıcak taşları tut. Zor rakip bu "ısıyı" ve destenin azaldığını tartar; tam bu durumda kendi elinden vazgeçer.
- Unutma: tuttuğun sıcak taş senin de eline girer — mümkünse onu bir pere bağla.''',
    ),
    TutorialSection(
      'İmkânsız masa: dürüst açıklama',
      '''İmkânsız masada rakipler **hile yapar**: senin rafın dahil bütün rafları ve destenin **sırasını** görürler. Bu adil bir oyun değil, bir eğitim aracıdır.

- Sıradaki çekişlerini bildikleri için **en hızlı bitişi planlarlar**: "3 çekiş sonra bitiyor, bu taş planında yok".
- Senden hemen önce oynayan rakip, desteden çekip çekmemesiyle **sana gelecek taşı seçer**: seni bitirecek taşı kendisi alır.
- Rafını gördüğü için sana yarayacak taşı **asla atmaz**.
- Kendi aralarında birbirlerini engellemezler — yalnız seni.

Burada kazanmak çok nadirdir; ortada taş bitip elin berabere kalması bile iyi sonuçtur. Açık oyna'da gerekçelerini oku: mükemmel bilginin nasıl kullanıldığını görmek, normal masada neyi tahmin etmen gerektiğini öğretir.''',
    ),
  ],
);

/// A short rack excerpt for the tutorial pages (-1 = gap).
class _Rack extends StatelessWidget {
  final List<int> ids;
  final int okey;
  final String? caption;
  const _Rack(this.ids, {this.okey = -1, this.caption});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(8, 7, 8, 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF4A2B17), Color(0xFF2E1A0D)],
            ),
            border: Border.all(color: Lux.gold.withValues(alpha: 0.7)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final id in ids)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: id < 0 ? const SizedBox(width: 14) : OkeyTileView(id, okeyKind: okey, width: 24),
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
}
