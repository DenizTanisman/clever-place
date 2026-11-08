import '../tutorial.dart';

const _band = ['AAABBBCCC', 'AAABBBCCC', 'AAABBBCCC'];

const sudokuTutorials = GameTutorials(
  rules: '''
- 1–9 rakamlarını her **satıra**, her **sütuna** ve kalın altın çizgili her **3×3 kutuya** birer kez yerleştir.
- Bir hücreye dokun, sonra alttan rakamı seç. **Not** açıkken rakamlar küçük kalem notu olur; bir rakam koyduğunda aynı satır, sütun ve kutudaki o rakamın notları kendiliğinden silinir. **Tüm notlar** bütün adayları bir kerede yazar.
- Yanlış rakam kabul edilir ama bordo görünür ve **hata** sayılır. Kaybetmek yok.
- **İpucu** bir hücreyi açar ve onu bulduran tekniği adıyla söyler.
- Yıldızlar: hatasız ve ipuçsuz 3 · en fazla 2 hata ve 1 ipucu 2 · diğer durumlarda 1.

Her bölümün tek çözümü var ve tahmin gerekmeden çözülür. Sağ üstteki etiket (Kolay, Orta, Zor, Uzman, Usta) o bulmacada gereken en zor tekniği gösterir.''',
  mid: [
    TutorialSection(
      'Gizli tekli',
      '''Bir rakamın bir kutuda, satırda ya da sütunda **gidebileceği tek hücre** kalmışsa oraya yazılır — o hücrenin başka adayları olsa bile.

Çizimde ortadaki kutuya bir 7 lazım. Üst satırda soldaki kutunun 7'si, orta satırda sağdaki kutunun 7'si var: ortadaki kutunun ilk iki satırı 7'ye kapalı. Alt satırda da 4 ve 2 dolu. Geriye tek hücre kalıyor.

Taktik: rakam rakam dolaş. "Bu kutuda 7 nerede olabilir?" diye sor, çizgileri parmağınla uzat. Bulmacaların büyük kısmı bu tarama ile açılır.''',
      diagram: MiniGrid([
        '7 . . . . . . . .',
        '. . . . . . 7 . .',
        '. . . 4 *7 2 . . .',
      ], regions: _band, cell: 28, caption: 'Ortadaki kutuda 7 yalnız işaretli hücreye gidebilir'),
    ),
    TutorialSection(
      'Tek aday',
      '''Bir hücrenin satırı, sütunu ve kutusu birlikte sekiz farklı rakamı içeriyorsa, o hücreye **yalnız kalan dokuzuncu** rakam gelir.

Çizimde işaretli hücrenin satırında 1, 2, 4, 6, 7; sütununda 3 ve 5; kutusunda 8 var. Geriye yalnız 9 kalıyor.

Gizli tekliden farkı: orada rakamdan hücreye, burada hücreden rakama bakarsın. Notlarda bir hücrede tek aday kaldığında bu teknik kendiliğinden görünür.''',
      diagram: MiniGrid([
        '. . . . 3 . . . .',
        '1 2 . 4 *9 6 7 . .',
        '. . . 8 5 . . . .',
      ], regions: _band, cell: 28, caption: 'Satır + sütun + kutu sekiz rakamı dışlıyor'),
    ),
    TutorialSection(
      'Kilitli aday',
      '''**İşaret eden:** Bir kutuda bir rakamın adayları tek bir satırda (ya da sütunda) toplanmışsa, o rakam kutunun içinde o satıra mutlaka gelecek. Demek ki aynı satırın **kutu dışındaki** hücrelerinden o aday silinir.

**Hapsolan:** Tersi de geçerli. Bir satırdaki bir rakamın adayları tek kutuya sıkışmışsa, o kutunun geri kalanından o aday silinir.

Çizimde soldaki kutuda 5 yalnız 2. satıra gidebilir; bu yüzden aynı satırdaki bordo 5 adayları elenir. Orta seviye bulmacaların anahtarı çoğu zaman budur.''',
      diagram: MiniGrid([
        '~3 ~8 ~1 . . . . . .',
        '*5 *5 ~6 . !5 . !5 . .',
        '~2 ~9 ~4 . . . . . .',
      ], regions: _band, cell: 28, caption: 'Kutudaki 5 bu satıra kilitli → bordo adaylar silinir'),
    ),
    TutorialSection(
      'Açık çift, gizli çift',
      '''**Açık çift:** Aynı birimde iki hücrenin adayları tam olarak aynı iki rakamsa (ör. 2 ve 7), bu iki rakam o iki hücreye paylaşılır. Birimin diğer hücrelerinden 2 ve 7 silinir.

**Gizli çift:** Bir birimde iki rakam yalnız aynı iki hücreye gidebiliyorsa, o iki hücre başka rakam alamaz; diğer adayları silinir.

Aynı mantık üç hücre / üç rakam için de çalışır: **açık üçlü** ve **gizli üçlü**. Üçlüde her hücrenin üç adayın hepsini taşıması gerekmez; 12, 23, 13 de bir üçlüdür.''',
      diagram: MiniGrid([
        '*27 *27 ~5 !29 ~1 !78 39 ~4 ~6',
      ], cell: 34, caption: 'İki hücre 2 ile 7\'yi paylaşıyor → bordo hücrelerden 2 ve 7 silinir'),
    ),
  ],
  advanced: [
    TutorialSection(
      'X-Wing ve Swordfish',
      '''Bir rakamın adayları **iki satırda** yalnız **aynı iki sütunda** duruyorsa, o rakam bu dört köşenin çaprazından ikisine gelir. Hangi çapraz olursa olsun iki sütunun ikisi de dolar: bu sütunların diğer hücrelerinden o rakam silinir.

Çizimde 4, 1. ve 4. satırda yalnız 2. ve 5. sütunda. Bordo 4 adayları elenir. Satır ve sütun rollerini değiştirerek de çalışır.

**Swordfish** aynı fikrin üç satır / üç sütunlu hâlidir: üç satırdaki adaylar toplam üç sütuna sığıyorsa, o sütunların geri kalanı temizlenir.''',
      diagram: MiniGrid([
        '. *4 . . *4 .',
        '. !4 . . . .',
        '. . . . !4 .',
        '. *4 . . *4 .',
        '. !4 . . !4 .',
      ], cell: 32, caption: 'Dört köşe bir dikdörtgen: sütunların kalanı 4 alamaz'),
    ),
    TutorialSection(
      'Gökdelen ve uçurtma',
      '''İki **güçlü bağ** düşün: bir rakamın bir sütunda yalnız iki adayı varsa, ikisinden biri mutlaka o rakamdır.

**Gökdelen:** İki sütunda bu tür çiftler var ve alt uçları aynı satırda. Alt uçlardan en fazla biri doğru olabilir; o yüzden **üst uçlardan biri** kesin o rakam. İki üst ucu birden gören hücreler o rakamı alamaz.

Çizimde 6, 2. ve 5. sütunda ikişer kez geçiyor; alt uçlar 5. satırda buluşuyor. Bordo hücreler iki üst ucu da görüyor. **İki ipli uçurtma** aynı fikrin bir satır + bir sütun ile kurulan hâlidir; uçlar bir kutuda buluşur.''',
      diagram: MiniGrid([
        '. *6 . !6 . !6',
        '!6 . !6 . *6 .',
        '. . . . . .',
        '. . . . . .',
        '. ~6 . . ~6 .',
        '. . . . . .',
      ], regions: ['AAABBB', 'AAABBB', 'AAABBB', 'CCCDDD', 'CCCDDD', 'CCCDDD'], cell: 30,
          caption: 'Alt uçlar aynı satırda → üst uçlardan biri 6'),
    ),
    TutorialSection(
      'XY-Wing ve XYZ-Wing',
      '''İki adaylı üç hücre: **merkez** 1/2, bir **kanat** 1/3, öteki kanat 2/3. Merkez her iki kanadı da görüyor.

Merkez 1 olursa 1/3'lük kanat 3 olur; merkez 2 olursa 2/3'lük kanat 3 olur. Her durumda kanatlardan biri **3**. Demek ki iki kanadı birden gören her hücreden 3 silinir.

**XYZ-Wing**'de merkezin üç adayı vardır (1/2/3). Bu kez merkezin kendisi de 3 olabilir, bu yüzden yalnız **üçünü birden** gören hücrelerden 3 silinir — genelde merkezle aynı kutudaki hücreler.''',
      diagram: MiniGrid([
        '*12 . . *23 .',
        '. . . . .',
        '*13 . . !3 .',
      ], cell: 36, caption: 'Kanatlardan biri mutlaka 3 → ikisini gören hücre 3 olamaz'),
    ),
    TutorialSection(
      'Zincirler ve zorlama',
      '''**X-Zinciri:** Tek bir rakam için güçlü bağ (birimde yalnız iki aday) ve zayıf bağ (birbirini gören iki aday) sırayla dizilir. Zincir güçlü bağla başlayıp güçlü bağla bitiyorsa iki uçtan biri kesin o rakamdır; iki ucu birden gören hücreler temizlenir. Gökdelen, en kısa X-Zinciridir.

**XY-Zinciri:** İki adaylı hücreler ortak rakamlarla birbirine bağlanır. "Baş hücre 4 değilse sıradaki şu olur, sonraki şu olur… son hücre 4 olur." Uçlardan biri mutlaka 4; ikisini gören hücrelerden 4 silinir. XY-Wing üç halkalı XY-Zinciridir.

**Zorlama zinciri (Usta):** İki adaylı bir hücre seç, adaylardan birini koyduğunu varsay ve yalnız teklilerle ilerle. Bir hücre adaysız kalıyor ya da bir rakama yer kalmıyorsa varsayım yanlıştır; o aday silinir. Notlarını kalemle değil, aklında yürüt.''',
    ),
  ],
);
