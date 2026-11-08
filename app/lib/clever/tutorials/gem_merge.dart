import '../tutorial.dart';

const gemMergeTutorials = GameTutorials(
  rules: '''
- Kavanozun üstünde parmağını kaydırarak nişan al (kesikli kılavuz çizgi), bırakınca mücevher düşer. Yalnız 1–5. seviye taşlar düşer; sıradaki taş sağ üstte görünür.
- Aynı seviyedeki iki mücevher **değince birleşir** ve değdikleri yerde bir üst seviyeye dönüşür. Puan = yeni taşın seviye değeri (1. seviyeden 11.'ye: 1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 66).
- 11 seviye: Kuvars, Ametist, Sitrin, Akuamarin, Granat, Peridot, Topaz, Safir, Zümrüt, Yakut, **Elmas**. İki Elmas birleşince ikisi de kaybolur ve +266 puan getirir.
- Yerine oturmuş bir mücevher kırmızı kesikli çizginin üstünde **2 saniyeden** fazla kalırsa oyun biter (çizgi yanıp söner).
- Bölümler: belirli seviyede bir mücevher yap, sınırlı düşüşle puan topla, sınırlı düşüşle seviye yap, dolu kasayla başla. Her bölümün taş sırası sabittir.
- Yıldızlar: hedefe ne kadar az düşüşle ulaşırsan o kadar çok yıldız.''',
  mid: [
    TutorialSection(
      'Köşe stratejisi',
      '''En büyük mücevherini bir **alt köşeye** yerleştir ve oradan hiç çıkarma. Duvar ve zemin onu iki yandan tutar, küçük taşlar altına kaçamaz.

- Büyük taşı ortada bırakırsan küçükler iki yanına dağılır ve birbirinden kopar.
- Köşeyi seçince sadık kal: sol köşe seçtiysen büyükleri hep sola, küçükleri sağa düşür.
- Köşedeki taş birleşip büyüdüğünde yine köşede kalır, çünkü yeni taş temas noktasında doğar.''',
      diagram: MiniGrid([
        '. . . . . .',
        '. . . . 2 1',
        '*8 7 6 4 3 2',
      ], cell: 34, caption: 'En büyük köşede, seviyeler sağa doğru küçülür'),
    ),
    TutorialSection(
      'Seviye merdiveni',
      '''Köşedeki büyük taştan uzaklaştıkça seviyeleri **birer birer azalt**: 8, 7, 6, 5, 4... Bu dizilişe merdiven denir.

Merdivenin en küçük ucunda bir birleşme olduğunda yeni taş bir üst basamağa değer ve **zincirleme** birleşir: 4+4 → 5, o 5 yanındaki 5 ile → 6... Tek düşüşle beş birleşme mümkündür.

Merdiveni bozacak taşı (ör. 7'nin yanına 2) merdivenden uzak, açık tarafa at.''',
    ),
    TutorialSection(
      'Küçükleri gömme',
      '''Büyük bir taşın altında ya da iki büyük taş arasında sıkışan küçük taş **kayıptır**: ona ulaşacak eşi düşüremezsin ve yer kaplamaya devam eder.

- Küçük taşları (1–3) yığının **üstüne** ya da açık tarafa düşür, büyük taşların altına değil.
- Bir küçük taş sıkıştıysa aynı seviyeden bir taşı tam üstüne bırak; düşerken temas edip birleşebilir.
- Büyük bir taşı küçüklerin üstüne bırakma: küçükler altında ezilir ve merdivenden kopar.''',
    ),
    TutorialSection(
      'Sıradakine bak',
      '''Sağ üstteki **sıradaki** taş, iki hamlelik plan yapmanı sağlar.

- Şimdiki taş eşsizse ama sıradaki onunla aynıysa, ikisini **yan yana** düşür: ikinci düşüş birleşmeyi garantiler.
- Şimdiki taş bir eşin üstüne düşecekse, sıradaki taşın da gideceği yeri kapatmadığından emin ol.
- Birleşme bekleyen bir çift oluşmuşsa, aradaki engeli kaldıracak taşı önce düşür.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Zincirleme birleşme',
      '''Birleşen iki taş, **değdikleri noktada** bir üst seviyede yeniden doğar. Bu noktayı önceden düşünürsen zincir kurarsın.

Örnek: 5'in hemen yanında iki tane 4 olsun. 4'leri birbirine değdirdiğinde doğan 5, temas noktası 5'e yakınsa ona da değer ve 6 olur. Merdivende her basamak bir sonrakine **yaslanmış** olmalı; arada boşluk ya da başka taş varsa zincir kopar.

Puan da zincirle katlanır: 4+4 → 5 (15), 5+5 → 6 (21), 6+6 → 7 (28): tek düşüşle 64 puan.''',
    ),
    TutorialSection(
      'Yuvarlanma ve sekme',
      '''Mücevherler yuvarlaktır: eğimli bir yüzeye düşen taş **yuvarlanır**, duvara çarpan taş hafifçe seker.

- İki taşın arasındaki çukura tam ortadan bırakırsan taş oraya oturur.
- Bir taşın tepesine kenardan bırakırsan yana kayar; bunu bir eşin yanına **kaydırmak** için kullan.
- Duvarın dibine nişan alırken taşın yarıçapını hesaba kat: büyük taş duvardan uzakta merkezlenir.

Kılavuz çizgi taşın merkezinin düşeceği hattı gösterir, yuvarlanmayı değil.''',
    ),
    TutorialSection(
      'Tehlike çizgisini yönetmek',
      '''Oyun bitişi yalnız **durgun** taşlar için sayılır: zıplayan ya da yeni düşen taş çizgiyi geçse de sayaç çalışmaz. Çizginin yanıp sönmesi sayacın işlediğini gösterir.

- Yığın yükselince büyük taş düşürme; küçük taşları boşluklara doldur ve birleşme ara.
- Kavanozun bir tarafı yüksekse alçak tarafa oyna; yüksek taraftaki taşlar birleşince yığın çöker.
- Dolu kasa bölümlerinde ilk birkaç düşüşü kasanın üstündeki eşleri birleştirmeye harca; yükseklik kazanmak, puandan önemlidir.''',
    ),
    TutorialSection(
      'Sınırlı düşüş hesabı',
      '''Her seviye iki alt seviyenin birleşimidir, yani T. seviye bir mücevher **2^(T−1)** tane 1. seviye taşa eşittir. Düşen taşların ortalaması yaklaşık 6,2 birimdir.

- 7. seviye: en az ~11 düşüş · 8. seviye: ~21 · 9. seviye: ~42 · 10. seviye: ~83.
- Kasada kalan her eşsiz taş **boşa giden** düşüş demektir. Hedef seviyeye ulaşmak için kasadaki taşları tek bir merdivende topla.
- Puan bölümlerinde büyük birleşmeler pahalıdır ama çok puan getirir: 9. seviye tek başına 45 puan, ama yolundaki bütün birleşmelerle birlikte 400 puanı aşar.''',
    ),
  ],
);
