import '../tutorial.dart';

// Diagrams use a doubled grid: even rows/columns are squares, odd ones are the grooves between them
// (`~·`). An empty gold cell in a groove is a wall.

const corridorTutorials = GameTutorials(
  rules: '''
- 9×9 tahta. Sen alttaki **inci** piyonla oynarsın; amacın en üst sıraya (altın çizgi) rakibinden **önce** varmak. Rakibin **lal** piyonu üstten başlar, alt sıraya koşar. Tek bölümlerde sen, çift bölümlerde rakip başlar.
- Her sırada **ya** piyonunu bir kare götür (ileri, geri, sağa, sola; duvarın içinden geçemez) **ya da** bir duvar koy. Piyonu sürükle ya da parlayan bir kareye dokun.
- 10 duvarın var; her biri iki kare boyundadır ve karelerin arasındaki oluğa oturur. Tepsiden sürükleyip bırak: yeşil-altın gölge geçerli, bordo geçersiz. Yönünü yuvarlak düğmeyle, tepsiye dokunarak ya da sürüklerken **ikinci parmakla** dokunarak çevir.
- Duvarlar üst üste binemez, birbirini kesemez ve **hiçbir piyonun** hedefe giden son yolunu kapatamaz.
- Yüz yüze gelince rakibin üstünden **atlarsın**; arkasında duvar ya da tahta kenarı varsa onun sağ ya da sol çaprazına geçersin.
- Toplam 200 hamlede kimse varamazsa oyun berabere biter.
- Yıldızlar: geri alma ve ipucu kullanmadan, sen vardığında rakibin hedefe en az **3 adım** uzaktaysa 3; yardımsız ama daha yakın bir yarışta 2; geri alma ya da ipucu kullandıysan 1 yıldız.''',
  mid: [
    TutorialSection(
      'Yol sayımı',
      '''Bu oyun bir **yarış**tır; her hamleden önce iki sayıyı bil: senin en kısa yolun ve rakibinin en kısa yolu. Üst şeritte rakibin yolu, alt şeritte seninki yazar; "yolum" düğmesi kendi yolunu tahtada gösterir.

- **Fark** = rakibin yolu − senin yolun. Pozitifse öndesin.
- **Sıra** yarım adım değerindedir: yollar eşitse ve sıra sendeyse sen öndesin.
- Bir duvar ancak rakibin yolunu senin piyon adımından **fazla** uzatıyorsa (en az 2 adım) piyon hamlesinden iyidir. Tek adımlık duvar, piyonunu bir kare yürütmekle aynı farkı yaratır ama elinden bir duvar gider.

Sayıları ezberleme, her turda yeniden say: tek bir duvar her şeyi değiştirebilir.''',
      diagram: MiniGrid([
        '0 ~· 0 ~· 0 ~· 0 ~· 0',
        '~· ~· * * * ~· ~· ~· ~·',
        '1 ~· 2 ~· *2 ~· *1 ~· 1',
        '~· ~· ~· ~· ~· ~· ~· ~· ~·',
        '2 ~· 3 ~· *3 ~· 2 ~· 2',
        '~· ~· ~· ~· ~· ~· ~· ~· ~·',
        '3 ~· 4 ~· *4 ~· 3 ~· 3',
      ], cell: 27, caption: 'Sayı: o kareden hedefe kaç adım · boş altın hücreler duvar · altın sayılar en kısa yol'),
    ),
    TutorialSection(
      'Duvarı erken harcama',
      '''Açılışta rakibin önüne koyduğun tek duvar onu genelde **bir** adım uzatır: yana kayar, yoluna devam eder. Sen bir hamle harcadın, o bir adım kaybetti; fark değişmedi ama elinde bir duvar eksik.

- Elindeki duvar bir **tehdit**tir: rakip her hamlede "buraya duvar gelirse?" diye düşünmek zorunda. Koyduğun duvar artık tehdit değildir.
- Duvarları rakip bir **koridora** girdiğinde, bir kenara yaslandığında ya da hedefe yaklaştığında kullan; o anlarda tek duvar 3–6 adım uzatabilir.
- Rakibin duvarları bittiyse, sende kalanlar neredeyse kesin kazanç demektir. Duvar sayısını da yarış farkına kat: kabaca her duvar bir–iki adım değerindedir.
- İlk hamlelerde piyonunu ilerlet, rakibin piyonunun nereye gideceğini gör; sonra vur.''',
    ),
    TutorialSection(
      'Atlama hileleri',
      '''İki piyon yüz yüze gelince sıradaki oyuncu rakibin **üstünden atlar** ve bir adımı bedavaya kazanır. Rakibin arkasında duvar ya da kenar varsa düz atlayamazsın; onun çaprazındaki iki kareden birine geçersin.

- **Rakibin tam önüne adım atma.** Aynı sütunda aranızda bir kare kaldıysa o kareye ilk giren, karşısındakine atlama hediye eder. Bir yana kay ya da bir duvar koy; rakip sana yaklaşmak zorunda kalsın.
- Çapraz atlama yön değiştirmenin bedava yoludur: arkasında duvar olan rakip, seni tek hamlede yan sütuna taşır.
- Rakibi kendi önüne çekmek için onun yolunu senin sütununa yönlendiren bir duvar da kurabilirsin; sonra atlarsın.''',
      diagram: MiniGrid([
        '. ~· . ~· . ~· . ~· .',
        '~· ~· ~· ~· * * * ~· ~·',
        '. ~· *+ ~· !R ~· *+ ~· .',
        '~· ~· ~· ~· ~· ~· ~· ~· ~·',
        '. ~· . ~· S ~· . ~· .',
      ], cell: 27, caption: 'S = sen, R = rakip · R\'nin arkası duvar: çapraz + karelerine atlarsın'),
    ),
    TutorialSection(
      'Arkanı duvarla koru',
      '''Rakibin duvarları senin yolunu en çok **dar bir yerde** uzatır: bir kenar boyunca ya da iki duvarın arasından geçerken. Bunu önceden kapatabilirsin.

- **Oluğu sen doldur**: rakibin en zararlı duvarı nereye koyacağını bul. Aynı oluğa ya da onu kesen yöne senin duvarın oturursa, kesişme ve üst üste binme yasağı o duvarı imkânsız kılar.
- **Yolunu kalınlaştır**: yolunun yanına, ona paralel bir duvar koymak, rakibin seni o koridordan atmasını zorlaştırır; yolu kapatmak yasak olduğu için tek çıkışlı koridorun kapatılamaz.
- Arkandaki (geçtiğin bölgedeki) duvarlar rakibi de etkiler: geride kalan bir set, onun inişini uzatıyorsa bir taşla iki kuş vurursun.
- İpucu: koymadan önce "bu duvar benim en kısa yolumu uzatıyor mu?" diye bak; savunma duvarı kendini tıkamamalı.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Çit ve iki kapı',
      '''Tek duvar kolayca dolaşılır; **yan yana duvarlar** bir çit kurar ve rakibi kapıya kadar yürütür. Yol kapatmak yasak olduğu için her çitin bir kapısı kalmalıdır; püf noktası kapıyı nereye bırakacağındır.

- Çiti rakibin önüne, **kapı uzak kenarda** kalacak şekilde kur: rakip çitin boyu kadar yana, sonra geri yürür.
- **İki kapı** bırak: rakip birine yöneldiği anda o kapıyı tek duvarla kapat. Öteki kapıya dönmek zorunda kalır; bu tek duvar 5–8 adım kazandırabilir.
- Zamanlama: kapıyı rakip ona **en yakınken** kapat; erken kapatırsan o daha kısa yoldan döner.
- Kendine dikkat: kurduğun çit senin dönüş yolunu da uzatmasın; çiti rakibin yarı alanına kur.''',
      diagram: MiniGrid([
        '. ~· . ~· !R ~· . ~· . ~· .',
        '~· ~· ~· ~· ~· ~· ~· ~· ~· ~· ~·',
        '. ~· . ~· . ~· . ~· . ~· .',
        '~· ~· * * * * * * * ~· ~·',
        '. ~· . ~· . ~· . ~· . ~· .',
      ], cell: 25, caption: 'Rakip aşağı inmek istiyor: iki duvarlık çitin kapıları iki uçta'),
    ),
    TutorialSection(
      'Merdiven',
      '''Yatay ve dikey duvarları **basamak basamak** dizersen tahtayı çapraz kesen bir set olur. Merdivenin önüne gelen piyon her ileri adım için bir de yan adım atmak zorunda kalır ya da setin ucuna kadar dolaşır.

- Dört duvarlık bir merdiven, düz bir çitin kapatamayacağı kadar geniş bir alanı keser; üstelik basamaklar birbirine değer ama kesişmez, yani kuralca geçerlidir.
- Merdiveni rakibin **çaprazına** kur: rakip sütun değiştirerek kaçmaya çalıştıkça basamağa çarpar.
- Tersinden de düşün: rakibin merdiveni karşısında basamakları tek tek inme; setin ucunu erken hedefle ya da bir basamağın önüne kendi duvarını koyup yolu sabitle.
- Merdiven aynı zamanda **senin koridorundur**: setin öbür yanından yürürken rakibin duvarları seni zor keser.''',
      diagram: MiniGrid([
        '. ~· . ~· . ~· . ~· . ~· .',
        '* * * ~· ~· ~· ~· ~· ~· ~· ~·',
        '. ~· . * . ~· . ~· . ~· .',
        '~· ~· ~· * ~· ~· ~· ~· ~· ~· ~·',
        '. ~· . * . ~· . ~· . ~· .',
        '~· ~· ~· * * * * ~· ~· ~· ~·',
        '. ~· . ~· . ~· . * . ~· .',
        '~· ~· ~· ~· ~· ~· ~· * ~· ~· ~·',
        '. ~· . ~· . ~· . * . ~· .',
      ], cell: 25, caption: 'Yatay–dikey–yatay–dikey: çapraz bir merdiven'),
    ),
    TutorialSection(
      'Tempo ve duvar paritesi',
      '''Her duvar bir hamledir. Yarışta önemli olan sadece adımlar değil, **kimin daha çok "bedava" hamlesi kaldığı**dır.

- Yollar eşit, duvarlar eşitse sıradaki taraf yarım adım öndedir. Rakip duvar koyup seni 1 adım uzatırsa bu sadece bir **takastır**: o da bir hamle harcadı, sırayı sana verdi.
- Duvar sayısı eşitken duvarı ilk koyan genelde zarar eder; karşılık verecek duvar rakipte kalır. **Son duvar** kimdeyse son sözü o söyler.
- Elinde rakipten fazla duvar varsa yarışı biraz geriden götürebilirsin; sonunda fazladan duvarlarla farkı kapatırsın.
- Pratik kural: duvar koymadan önce iki şeyi say: (1) bu duvar kaç adım kazandırıyor, (2) bundan sonra kimin kaç duvarı kalıyor. Kazanç 2 adımdan azsa ve duvar paritesini bozuyorsa koyma.''',
    ),
    TutorialSection(
      'Son oyunda yarış hesabı',
      '''Duvarlar azalınca oyun saf bir hesaba döner.

- **Rakibin duvarı yoksa**: senin yolun onunkinden kısa ya da eşitse ve sıra sendeyse kazanmışsın; kalan duvarlarını yalnızca bu hesap bozulursa kullan. Gerideysen önce duvarla farkı kapat, sonra koş.
- **Senin duvarın yoksa**: rakibin her duvarının seni ne kadar uzatabileceğini düşün. Yolun açık bir alandan geçiyorsa bir duvar 1–2 adım, bir kenar ya da koridor boyuncaysa çok daha fazla uzatabilir. Böyle anda kısa ama dar yol yerine bir adım uzun ama **geniş** yolu seç.
- **Karşılaşma noktası**: iki piyon aynı sütunda birbirine yürüyorsa kimin önce yanaşacağını say; yanaşan, karşısındakine atlama hediye eder (bir adım). Gerekirse bir yan adımla sırayı çevir.
- Son kontrol: her hamleden önce "rakibim şimdi duvar koyarsa yarış kimde?" diye sor. Cevap "onda" ise, önce o duvarı imkânsız kıl.''',
    ),
  ],
);
