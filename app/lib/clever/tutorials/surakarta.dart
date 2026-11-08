import '../games/surakarta_view.dart' show SurakartaLoopDemo;
import '../tutorial.dart';

const surakartaTutorials = GameTutorials(
  rules: '''
- 6×6 tahtada 12'şer taş: sen alttaki **inci** taşlarla, rakip üstteki **lal** taşlarla oynar. Tek bölümlerde sen, çift bölümlerde rakip başlar.
- Normal hamle: taşını komşu 8 noktadan **boş** birine bir adım götür (çapraz da olur). Taşı **sürükleyip bırak** ya da önce taşa, sonra hedefe dokun.
- **Alış**: taşın bir devre çizgisi boyunca (iç devre zümrüt, dış devre altın) istediği kadar ilerler ve köşe halkalarından **en az birini** dolaşır. Yol boş olmalı (başladığı nokta boş sayılır); karşısına çıkan ilk taş rakibinse onu alır ve yerine oturur. Alış zorunlu değildir.
- Alış **iki yönde de** olur: rakibe doğru değil, ondan uzaklaşıp **geriye doğru** gidip halkadan dönerek de vurabilirsin. Yol birden çok halkadan ve taşın kendi noktasının üstünden geçebilir.
- Oyunda: alışı olan taşının köşesinde **altın halka işareti** yanar; taşa dokununca alabileceği rakipler altın halkayla çevrilir, yolları kesik çizgiyle görünür ("×2" = iki halkadan geçer). Çevresinde **bordo kesik halka** olan taşın tehlikededir. Alttaki sonsuzluk işaretli düğme kısa bir canlandırma gösterir.
- Kazanmak için rakibin bütün taşlarını al ya da onu **hamlesiz** bırak.
- **Durma kuralı**: 40 hamle boyunca hiç taş alınmazsa ya da aynı konum 3 kez tekrarlanırsa oyun durur: taşı çok olan kazanır, eşitse berabere. Yani gerideyken beklemek seni kurtarmaz; önde kalmak zorundasın.
- Yıldızlar: geri alma ve ipucu kullanmadan, en az **6 taşla** kazanırsan 3; geri alma/ipucu olmadan 2; kullandıysan 1 yıldız.''',
  mid: [
    TutorialSection(
      'Halka ile alış: geriye doğru da',
      '''Surakarta'da taşlar uzaktan vurur, ama yalnızca **halkadan dolaşarak**. Bunu görmenin yolu, taşı değil **çizgiyi** takip etmektir:

- Taşın durduğu devre çizgisini iki yöne de izle. Çizgi kenara varınca köşedeki halkaya girer, çeyrek eksik bir tur (270°) atar ve dik çizgiden tahtaya geri döner.
- **Geriye yuvarlama**: hedef önünde olsa bile önce **ters yöne**, kendi tarafına doğru git. Canlandırmada (4,1)'deki taş aşağı (5,1)'e iner, sol alt halkadan dönüp (4,0)'a çıkar, kendi eski noktasının üstünden geçer ve (4,3)'teki taşı **arkadan** alır.
- **Birden çok halka**: yol boş kaldıkça halkadan halkaya geçebilir. İkinci örnekte taş sol alt halkadan girip bütün sütunu çıkar, sol üst halkadan dönüp alır.
- Yolun üstündeki **her taş** (seninki de) yolu keser. Yalnızca taşın kendi başladığı nokta boş sayılır.

Oyunda bunları aramak zorunda değilsin: alışı olan taşın altın halka işaretiyle parlar, dokununca yolu kesik çizgiyle çizilir.''',
      diagram: SurakartaLoopDemo(),
    ),
    TutorialSection(
      'Devreleri okumak',
      '''Tahtada iki kapalı devre var. **İç devre** (zümrüt) 1. ve 4. satır ile 1. ve 4. sütundan, **dış devre** (altın) 2. ve 3. satır ile sütundan oluşur. Köşelerdeki halkalar çizgileri birbirine bağlar.

- Kenar çizgileri (0. ve 5.) hiçbir devrede değildir. **Dört köşe noktası** hiçbir devreye değmez: oradaki taş kimseyi alamaz ama alınamaz da.
- **İD** ile işaretli sekiz nokta iki devrenin de üstündedir: hem iki yönden vurur hem iki yönden vurulur.
- Bir taşı oynatmadan önce "bu nokta hangi devrede?" diye sor; tehlike ve fırsat sadece o devreden gelir.''',
      diagram: MiniGrid([
        '~· İ D D İ ~·',
        'İ İ *İD *İD İ İ',
        'D *İD D D *İD D',
        'D *İD D D *İD D',
        'İ İ *İD *İD İ İ',
        '~· İ D D İ ~·',
      ], caption: 'İ = iç devre · D = dış devre · İD = ikisi birden'),
    ),
    TutorialSection(
      'Halka girişlerini kontrol et',
      '''Her halkanın iki ucu kenarda bir noktaya iner: bunlar **halka girişleri**. Halkadan gelen bir taşın ilk çarptığı yer çoğu zaman burasıdır.

- Girişte duran taşın **açık**tır: halkanın öbür ucundaki çizgi boşaldığı an alınabilir.
- Buna karşılık halkanın **arkasında**, aynı çizgide yolu açık bir taşın varsa o halkayı sen kontrol edersin: rakip o devreye adım atınca alırsın.
- İyi bir alışkanlık: her hamleden sonra sekiz halkayı tek tek tara; hangisi senin, hangisi rakibin, hangisi kapalı?''',
      diagram: MiniGrid([
        '. *İ *D *D *İ .',
        '*İ . . . . *İ',
        '*D . . . . *D',
        '*D . . . . *D',
        '*İ . . . . *İ',
        '. *İ *D *D *İ .',
      ], caption: 'Halka girişleri: İ iç halkalar, D dış halkalar'),
    ),
    TutorialSection(
      'Saldırı–savunma sayımı',
      '''Bir taşı almadan önce say: o noktaya **kaç taşın** halkadan ulaşıyor (saldıranlar), rakibin kaç taşı aynı noktaya halkadan ulaşıp **geri alabilir** (savunanlar)?

- Saldıran sayısı savunandan fazlaysa alış zincirinin sonunda taş kazanırsın.
- Eşitse takas olur: önce aşağıdaki "takas" bölümüne bak.
- Kendi taşını da aynı mantıkla koru: önemli bir taşı **iki taşla korumak**, rakibin tek saldırısını boşa çıkarır.

Dikkat: alan taş yer değiştirdiği için başladığı nokta boşalır; bu, arkadaki başka bir taşın yolunu açabilir. Saymayı bitirince bir kez de "alıştan sonra hangi yol açılıyor?" diye bak.''',
    ),
    TutorialSection(
      'Yolu kapat, yolu aç',
      '''Her taş, bulunduğu çizgide bir **duvar**dır. Bu iki şey demek:

- **Kapatma**: rakibin halkadan gelen saldırısını, yoluna bir taş koyarak kesebilirsin. Çoğu zaman tehdit edilen taşı kaçırmaktan daha iyidir, çünkü kapatan taş aynı zamanda o devreyi senin yapar.
- **Açarak saldırı**: bir taşını çizgiden çekince arkasındaki taşının yolu açılır. Çekilen taş başka bir şeyi tehdit ederse rakip ikisini birden karşılayamaz.

Taş seçerken hep iki soruyu sor: "Bu taş kalkınca hangi yol açılıyor? Vardığı yerde hangi yolu kapatıyor?"''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Takas ne zaman iyi?',
      '''Bire bir takas sayıları değil **oranı** değiştirir.

- **Öndeysen takas et**: 7'ye 5 iken iki takas 5'e 3, dört takas 3'e 1 eder. Az taşla rakibin saldıracak yolu da kalmaz.
- **Gerideysen takastan kaç**: taşları tahtada tut, devreleri kalabalık bırak, rakibi hesaplamaya zorla.
- Durma kuralı da önde olanı ödüllendirir: 40 hamle boyunca taş alınmazsa fazla taşlı kazanır. Öndeyken güvenli takaslar ve sakin hamleler yeter; gerideyken temas yaratmak zorundasın.
- Halka kontrol eden taşını, kontrol etmeyen bir taşla takas etme; değerli olan taş değil, gördüğü yoldur.''',
    ),
    TutorialSection(
      'Bekleme hamlesi',
      '''Bazen iki taraf da birbirini nişanlamıştır ve **ilk hareket eden kaybeder**: korumadaki bir taş kıpırdarsa yol açılır.

- Böyle anlarda hiçbir şeyi bozmayan bir **bekleme hamlesi** yap: köşedeki bir taşı yanına kaydır, devre dışı bir noktada dolaştır.
- Köşe noktaları bu iş için idealdir: oradaki taş alınamaz ve her zaman bir hamlesi vardır.
- Tersini de kullan: rakibin bütün taşları kilitli ya da korumaya bağlıysa ona sakin bir hamle bırak; bozmak zorunda kalır. Hiç hamlesi kalmazsa doğrudan kaybeder.''',
    ),
    TutorialSection(
      'Kesişim noktaları ve çatal',
      '''İki devrenin kesiştiği sekiz nokta, (1,2) (1,3) (2,1) (2,4) (3,1) (3,4) (4,2) (4,3), tahtanın **kavşaklarıdır**.

- Buradaki taşın iki devrede birden yolu vardır. Tek hamlede **iki ayrı taşı** tehdit edebilir; buna **çatal** denir. Rakip birini kurtarırken öbürünü alırsın.
- Aynı nedenle kavşakta duran taşın iki devreden de vurulabilir. Korumasız kavşak taşı en kolay kayıptır.
- Plan: kavşağa ancak iki devreyi de taradıktan ve taşın en az bir kez korunuyorken gir.''',
      diagram: MiniGrid([
        '. . . . . .',
        '. . *✦ *✦ . .',
        '. *✦ . . *✦ .',
        '. *✦ . . *✦ .',
        '. . *✦ *✦ . .',
        '. . . . . .',
      ], caption: 'İç ve dış devrenin kesiştiği sekiz kavşak'),
    ),
    TutorialSection(
      'Son oyunda devre hâkimiyeti',
      '''Taşlar azalınca tahta açılır: tek bir taş, halkaları boş bir devrenin **tamamını** görür.

- Bir devreyi tamamen sahiplen: o devrede rakibin taşı kalmasın, senin taşın yolunu görsün. Rakip o devreye her adım attığında alırsın.
- Kendi taşlarını rakibin hâkim olduğu devreden çıkar: sadece senin devrende olan noktalara ya da köşelere çek.
- Az taşla rakibi **hamle zorunluluğuna** sok: köşedeki tek taş bile her sırada bir adım atmak zorunda; komşu üç noktası da iç devrededir. O devre seninse, kaçacak yeri kalmaz.
- Öndeysen acele etme: durma kuralı 40 hamlede oyunu senin lehine bitirir.''',
    ),
  ],
);
