import '../tutorial.dart';

const blockGridTutorials = GameTutorials(
  rules: '''
- Alttaki üç taştan birini sürükleyip 9×9 tahtaya bırak. Taşlar **döndürülemez**.
- Tamamen dolan her **satır**, **sütun** ve **3×3 kare** silinir. Aynı hamlede birden fazlası silinirse kombo olur: c birim için 18·c² puan.
- Her yerleştirme hücre başına 1 puan getirir. Silen hamleler **seriyi** büyütür ve ek puan verir; art arda 3 hamle hiçbir şey silmezsen seri sıfırlanır. Tahtayı tamamen boşaltırsan +300.
- Üç taşın hepsini yerleştirince yeni üçlü gelir. Kalan taşlardan **hiçbiri** sığmıyorsa oyun biter; sığmayan taş soluk görünür.
- Sürüklerken parlayan gölge taşın sığdığını, kırmızı gölge sığmadığını gösterir; silinecek satır, sütun ve kareler parlar.
- Bölüm geçtikçe ya da satır/sütun/kare temizledikçe yeni **görünümler** açılır (Ahşap, Şeker, Mermer, Neon, Buz, Mücevher). Puanların yanındaki palet düğmesinden seçebilirsin.
- Bölümler: puan topla, belirli sayıda birim temizle, koyu taş blokları kır, sıkışmadan dayan. Yıldızlar: hedefe taş hakkının %70'iyle ulaşırsan 3, %85'iyle 2 yıldız; dayanma bölümünde taş başına puana göre.''',
  mid: [
    TutorialSection(
      'Büyük taşa yer ayır',
      '''Oyunu bitiren hemen her zaman **3×3 kare**, **1×5 çubuk** ya da büyük L taşıdır. Bunlar geldiğinde koyacak yer bulamazsan kaybedersin.

Her hamlede kendine sor: "Şimdi 3×3 gelse nereye koyardım?" Tahtada en az bir boş 3×3 alan ve bir tam boş satır ya da sütun bırakmaya çalış.

- Küçük taşları (tekli, ikili, küçük L) büyük boşlukların **ortasına** değil, kenarlarına ve dolu bölgelerin yanına koy.
- Bir boş alanı ikiye bölen hamle, çoğu zaman iki küçük işe yaramaz boşluk bırakır.''',
      diagram: MiniGrid([
        'X X X X . . . . .',
        'X X X . . . . . .',
        'X X . . . *. *. *. .',
        'X . . . . *. *. *. .',
        'X X . . . *. *. *. .',
      ], cell: 28, caption: '3×3 için yer hep hazır olsun'),
    ),
    TutorialSection(
      'Tek parça boş alan',
      '''Boş hücreleri **tek, bütün bir bölge** olarak tut. Etrafı dolu tek bir boş hücre, ancak tekli taş gelirse dolar — ve o seyrek gelir.

- Kenarları ve köşeleri önce doldur; dolu hücreler duvara yaslanırsa boşluk ortada birleşik kalır.
- Taşı koyarken **pürüzlü kenar** bırakma: dolu ile boş arasındaki sınır ne kadar kısa olursa tahta o kadar esnektir.
- Hücre tek tek kalmışsa onu dolduracak satırı ya da sütunu silerek kurtar.''',
    ),
    TutorialSection(
      'Üç taşın sırasını planla',
      '''Üç taşın hepsini yerleştirmen gerekiyor; sıra senin elinde. Bu, oyunun en güçlü aracıdır.

- Önce en **zor** taşı (en büyük, en garip şekilli) yerleştir; kolay taşlar sonra her yere sığar.
- Bir taşı koymadan önce kalan iki taşın da hâlâ sığacağından emin ol. Soluklaşan taş artık sığmıyor demektir.
- Bir taş bir satırı tamamlayacaksa, onu başka bir taşın yer açması için **önce** koy: silinen satır diğer taşlara alan açar.''',
    ),
    TutorialSection(
      'Kareleri unutma',
      '''Satır ve sütunlar kadar **3×3 kareler** de silinir — ve kare doldurmak çoğu zaman daha kolaydır, çünkü 2×2, L ve 2×3 taşlar karelere tam oturur.

Altın çizgiler kare sınırlarıdır. Bir karenin 6–7 hücresi doluysa onu bitirmeye odaklan.

Bonus: bir kareyle bir satırı aynı hamlede tamamlarsan iki birim silinir ve kombo puanı alırsın.''',
      diagram: MiniGrid([
        'X X X . . .',
        'X *. X . . .',
        'X X X . . .',
      ], cell: 30, caption: 'Tek hücre: kare tamamlanır'),
    ),
  ],
  advanced: [
    TutorialSection(
      'Kesişim kombosu',
      '''Kombo puanı birim sayısının **karesiyle** artar: 1 birim 18, 2 birim 72, 3 birim 162 puan.

Teknik: bir satır ile bir sütunu, **ortak hücreleri** hariç doldur. Tek bir taş o kesişim hücresine girdiğinde ikisi birden silinir. Kesişim hücresi aynı zamanda bir kareyi de tamamlıyorsa üç birim!

Bunu kurmak için bir satırı ve sütunu sabırla %90'a kadar doldur, kesişimi en son ve **tekli ya da küçük** bir taşla kapat.''',
      diagram: MiniGrid([
        '. . . X . .',
        '. . . X . .',
        'X X X *. X X',
        '. . . X . .',
        '. . . X . .',
      ], cell: 30, caption: 'Tek hücre: satır + sütun birlikte'),
    ),
    TutorialSection(
      'Seriyi canlı tut',
      '''Silen her hamle seriyi bir artırır ve seri, her silmede birim başına 12·(seri−1) ek puan demektir. Seri, üst üste **üç** hamle hiçbir şey silmezse biter.

- Tahtada her zaman 1–2 hamlede silinecek **yarım iş** (neredeyse dolu satır, sütun ya da kare) tut.
- Büyük bir kombo kurarken bile araya küçük temizlemeler serpiştir; üçüncü boş hamleye izin verme.
- Puan bölümlerinde seriye öncelik ver: 10'luk seri, tek bir büyük kombodan çok puan getirir.''',
    ),
    TutorialSection(
      'Taş blokları kırmak',
      '''"Taşları kır" bölümlerinde tahtada koyu, damarlı bloklar vardır. Bunlar ancak bulundukları satır, sütun ya da kare **silinince** kaybolur.

- Önce en çok koyu blok içeren satırı/sütunu/kareyi seç: en az hücreyle en çok bloğu kırarsın.
- Bir satırın 6 hücresi blok ise, sadece 3 hücre koyarak 6 bloğu kırarsın.
- Kalan blok sayısı üstte yazar; son birkaç dağınık blok için kareleri hedefle, çünkü kare 9 hücreyle bir bloğu kesin kırar.''',
    ),
    TutorialSection(
      'Dolu tahtada hayatta kalma',
      '''Tahta yarıdan fazla dolunca strateji değişir: **puan değil, yer** öncelikli.

- Hangi taş olursa olsun silebilen hamleyi seç; silmeyen hamle tahtayı daha da kapatır.
- Çapraz taşlar (iki ya da üç hücre köşeden köşeye) dağınık deliklere uyar; onları saklamak yerine deliklere ver.
- Üç taştan biri hiçbir yere sığmıyorsa, diğer ikisiyle **onun için** yer açacak satırı sil.

Dayanma bölümlerinde mantık budur: her üçlüyü eksiksiz yerleştirmek, puandan önce gelir.''',
    ),
  ],
);
