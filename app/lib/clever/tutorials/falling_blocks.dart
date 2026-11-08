import '../tutorial.dart';

const fallingBlocksTutorials = GameTutorials(
  rules: '''
- Dört hücreli taşlar (I, O, T, S, Z, J, L) kuyunun tepesinden düşer. Bir satırı tamamen doldurursan satır silinir.
- Kuyuya **dokun**: saat yönünde döndür. **İki parmakla dokun**: ters yöne döndür. **Sağa/sola sürükle**: hücre hücre kaydır. **Yavaşça aşağı sürükle**: yumuşak düşüş. **Hızlıca aşağı fırlat**: sert düşüş. **Yukarı fırlat**: sakla. Alttaki düğmeler de aynı işi yapar.
- **Sakla** kutusu her taşta bir kez kullanılabilir. Sağda sıradaki 3 taş görünür; kuyudaki çerçeve (gölge) taşın düşeceği yeri gösterir.
- Taş yere değdikten sonra yarım saniye daha kaydırılabilir; her hareket bu süreyi yeniler (en fazla 15 kez).
- Puan: tekli 100, ikili 300, üçlü 500, **dörtlü 800** — hepsi hız seviyesiyle çarpılır. T-dönüşler, art arda zor temizlemeler (×1,5) ve kombolar ek puan verir.
- Bölümler beş türde döner: satır temizle, sınırlı taşla satır, kazı, hayatta kal, puan. Yıldızlar verimliliği ölçer: hedefe ne kadar az taşla ulaşırsan (hayatta kalmada ne kadar çok satır silersen) o kadar çok yıldız.
- **Maraton**: hız her 10 satırda bir artar; yığın tepeye ulaşınca oyun biter.''',
  mid: [
    TutorialSection(
      'Düz yığ',
      '''Yüzeyin ne kadar **düz** olursa, gelen her taş için o kadar çok iyi yer olur. Komşu sütunlar arasındaki yükseklik farkı 2'yi geçince yalnızca I taşı oraya düzgün oturur.

- Taşları **yatık** koymayı tercih et; dik taşlar kule ve çukur yaratır.
- Asla taşın altında **boşluk** bırakma: kapalı bir boşluğu açmak için üstündeki her satırı silmen gerekir.
- O taşı daima düz bir 2 hücrelik zemine koy; başka yerde mutlaka boşluk bırakır.

Gölgeye bak: gölgenin altında boşluk görüyorsan taşı döndür ya da başka sütuna taşı.''',
      diagram: MiniGrid([
        '. . . . . . . . . .',
        '. . . . . . . . . .',
        'X X X . . X X X X .',
        'X X X X X X X X X .',
        'X X X X X X X X X .',
      ], cell: 26, caption: 'Düz yüzey, sağda tek bir boş sütun'),
    ),
    TutorialSection(
      'Kuyu bırak: I için yer aç',
      '''Puanın büyük kısmı **dörtlü** temizlemeden gelir: dört satırı tek seferde silmek, dört ayrı tekliden 2 kat fazla puan verir.

Yöntem: kenardaki bir sütunu (genelde en sağ ya da en sol) **boş bırak** ve diğer dokuz sütunu düz yığ. Yığın dört satır olunca dik I taşını kuyuya bırak.

- Her 7 taşlık torbada tam bir I vardır, yani iki I arasında en fazla 12 taş olur. Sabırlı ol.
- Kuyuyu başka taşla kapatma; kapatırsan altındaki satırlar kilitlenir.
- Hız yükselince kuyuyu 4 değil 2–3 satırda kullanmak daha güvenlidir.''',
      diagram: MiniGrid([
        '. . . . . . . . . *I',
        'X X X X X X X X X *I',
        'X X X X X X X X X *I',
        'X X X X X X X X X *I',
        'X X X X X X X X X *I',
      ], cell: 26, caption: 'Dik I kuyuya: dörtlü'),
    ),
    TutorialSection(
      'S ve Z için basamak okuma',
      '''S ve Z en zor taşlardır; ancak **bir basamaklık** yüzeye boşluksuz otururlar:

- **Yatay S**: sağ tarafı bir hücre yüksek olan basamağa.
- **Dikey S**: sol tarafı bir hücre yüksek olan basamağa.
- **Yatay Z**: sol tarafı bir hücre yüksek olan basamağa.
- **Dikey Z**: sağ tarafı bir hücre yüksek olan basamağa.

Yüzeyinde hem sola hem sağa doğru birer basamak bulundur; böylece S de Z de geldiğinde yer hazırdır. Hiç uygun yer yoksa Sakla'ya koy.''',
      diagram: MiniGrid([
        '. *S *S . . .',
        '*S *S X . . .',
        'X X X X . .',
      ], cell: 30, caption: 'Yatay S, sağı yüksek basamağa oturur'),
    ),
    TutorialSection(
      'Sakla ve sıradaki: önden plan',
      '''Sağdaki **üç taşlık** önizleme, sana sonraki 3 hamleyi şimdiden planlama şansı verir.

- Sakla'yı refleksle değil plan aracı olarak kullan: en iyi kullanım I'yı kuyu hazır olana kadar **saklamak**, ya da yer olmayan S/Z'yi kenara almaktır.
- Saklanan taş geri çağrılınca başlangıç yönünde ve tepede doğar.
- Bir taşı koymadan önce sıradakinin nereye gideceğini düşün: iki taş birbirini tamamlayacak şekilde yer bırak (ör. J'nin yanına L).

Kural: taşı bırakırken gözün zaten sıradaki taşta olsun.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'T-dönüş temelleri',
      '''T taşı bir yuvaya **son anda döndürülerek** girerse ve merkezinin dört köşesinden en az üçü doluysa buna **T-dönüş** denir. T-dönüş ikili 1200 × hız puan verir — dörtlüden bile fazla.

Klasik yuva: bir satırda 3 hücrelik boşluk, altında ortada 1 hücrelik çentik, üstünde ise yuvanın bir kenarını örten bir **çıkıntı**. T'yi çıkıntının yanına indir, sonra döndür: duvar itmesi (kick) onu yuvaya sokar.

- Döndürme son hareket olmalı; döndürdükten sonra kaydırırsan sayılmaz.
- Çıkıntı yoksa T düz düşer ve yalnızca normal ikili alırsın.''',
      diagram: MiniGrid([
        'X X . . . . . . . .',
        'X *T *T *T X X X X X X',
        'X X *T X X X X X X X',
      ], cell: 24, caption: 'Çıkıntının altına dönerek giren T: iki satır'),
    ),
    TutorialSection(
      'Art arda ve kombo',
      '''İki puan çarpanını birlikte kullan:

- **Art arda**: dörtlü ya da satır silen T-dönüşü, araya tekli/ikili/üçlü sokmadan arka arkaya yaparsan ikincisinden itibaren **×1,5** puan alırsın. Satır silmeyen taşlar zinciri bozmaz; yalnız "kolay" temizlemeler bozar.
- **Kombo**: arka arkaya her taşla satır silersen her biri 50 × kombo × hız ekler. Kombo, satır silmeyen ilk taşta sıfırlanır.

Pratikte: kuyunu dört satıra kadar yığ ve sadece dörtlü al (art arda zinciri), yığının tepesi tehlikeye girince zinciri bırakıp güvenli tekli/ikili temizlemelere geç.''',
    ),
    TutorialSection(
      'Kazı tekniği',
      '''Kazı bölümlerinde kuyu, her satırda bir (ileride iki) deliği olan gri çöp satırlarıyla başlar. Hedef: **bütün gri satırları** silmek.

- Yalnız **en üstteki** çöp satırının deliği açıktır. Önce onu tamamla; sonraki satırın deliği ancak üstü silinince açılır.
- Delikler aynı sütunda alt alta ise dik I ile birden çok satırı tek seferde sil.
- Deliği kapatmamak için taşları deliğin **iki yanına** koy, deliğin üstünü boş bırak.
- Çöpü silerken üstte yeni katmanlar biriktirme: her taşın bir sonraki deliği açmaya hizmet etsin.

Yıldızlar taş sayısına bakar: satır başına 2–3 taş iyi bir hedeftir.''',
      diagram: MiniGrid([
        '. . . . . . . . . .',
        'G G G *. G G G G G G',
        'G G G G G G ~. G G G',
        'G ~. G G G G G G G G',
      ], cell: 24, caption: 'Önce en üstteki açık deliği doldur'),
    ),
    TutorialSection(
      'Yüksek hız: az hareket, erken karar',
      '''Hız 10'u geçince taş bir saniyeden kısa sürede dibe iner; 20'de anında yere yapışır. Kazanmak için:

- **Az hamle**: her taş her konuma en fazla 2–3 hareketle gider (bir döndürme + duvara kadar kaydırma). Gereksiz döndürmeler zaman yer.
- **Kilit gecikmesi**: yere değen taş 0,5 saniye bekler ve her başarılı hareket bu süreyi yeniler (15 kez). Hızlı seviyede taşı yerde kaydırarak doğru yere it.
- Kararı taş doğmadan ver: sıradaki taşa bakarak yerini önceden seç.
- Yüzeyi alçak tut: yüksek hızda yığının üst yarısında oynamak hata kaldırmaz.''',
    ),
  ],
);
