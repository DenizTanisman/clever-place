import '../tutorial.dart';

const crownsTutorials = GameTutorials(
  rules: '''
- Tahta N×N ve N renkli **bölgeye** ayrılmış. Her **satıra**, her **sütuna** ve her **bölgeye** tam **bir taç** koy. **Çift taç** bölümlerinde bu sayı **iki**.
- İki taç birbirine **değemez** — çaprazdan bile.
- Dokun: boş → X → taç. Parmağını sürükleyerek birçok hücreye X koyarsın; X'li bir hücreden başlayan sürükleme X'leri kaldırır.
- Kural ihlalleri bordo parlar: çakışan taçlar, fazla taçlı ya da artık taç sığmayan satır, sütun ve bölgeler.
- **İpucu** sıradaki mantıklı adımı adıyla anlatır ve tahtaya işler; yanlış bir taç ya da X varsa önce onu düzeltir.
- Yıldızlar: ipucusuz ve en fazla 2 düzeltme 3 · en fazla 1 ipucu ve 6 düzeltme 2 · diğer durumlarda 1. **Düzeltme**, koyduğun bir tacı kaldırmaktır (X'ler serbest).

Her bölümün tek çözümü var ve tahmin gerekmeden çözülür.''',
  mid: [
    TutorialSection(
      'Temel eleme ve son yer',
      '''Bir taç koyduğun an çevresindeki **sekiz hücre**, satırının ve sütununun geri kalanı ve bölgesinin geri kalanı boş kalır. Bunları hemen X'le; tahta sadeleştikçe sonraki adım kendini gösterir.

**Son yer:** Bir satırda, sütunda ya da bölgede taç için tek boş hücre kaldıysa taç oraya. Küçük bölgeler (1–3 hücre) en iyi başlangıç noktasıdır: önce onlara bak.''',
      diagram: MiniGrid([
        '. . ~× . .',
        '. ~× ~× ~× .',
        '~× ~× *♛ ~× ~×',
        '~× ~× ~× ~× .',
        '. . ~× . .',
      ], regions: ['AABBB', 'AABBB', 'CCCBD', 'CCDDD', 'EEDDD'], cell: 34,
          caption: 'Taçtan sonra komşular, satır, sütun ve bölge kapanır'),
    ),
    TutorialSection(
      'Hapsolan bölge',
      '''Bir bölgenin kalan bütün hücreleri **tek bir satırdaysa**, o satırın tacı o bölgeden gelecek. O satırın bölge dışındaki hücreleri boş kalır.

Tersi de doğru: bir satırın kalan hücreleri tek bir bölgenin içindeyse, bölgenin o satır dışındaki hücreleri boş kalır. Aynısı sütunlar için de geçerli.

Çizimde altın bölge yalnız 2. satırda; o satırın kalanı (bordo) elenir.''',
      diagram: MiniGrid([
        '. . . . . .',
        '!× !× *. *. *. !×',
        '. . . . . .',
        '. . . . . .',
        '. . . . . .',
        '. . . . . .',
      ], regions: ['AAAACC', 'AABBBC', 'DDDDCC', 'DEEEFF', 'DEEFFF', 'DDDFFF'], cell: 32,
          caption: 'Bölge tek satıra sıkışmış → satırın geri kalanı boş'),
    ),
    TutorialSection(
      'Ortak komşu',
      '''Bir bölgenin tacı nereye konursa konsun **aynı hücreye değiyorsa**, o hücre boş kalır — taç ona mutlaka değecek.

Çizimde altın L bölgesinin üç hücresi de bordo hücreye komşu: o hücreye taç koyamazsın.

Genişletilmiş hâli: taç bölgenin her olası yerinde bir hücreye ya değiyor ya da onun satırını/sütununu dolduruyorsa, yine o hücre boş kalır. İpucu bu adımı "Ortak komşu" diye adlandırır.''',
      diagram: MiniGrid([
        '. . . . . .',
        '. . *. *. . .',
        '. . *. !× . .',
        '. . . . . .',
        '. . . . . .',
        '. . . . . .',
      ], regions: ['AAAACC', 'AABBCC', 'DDBEEC', 'DDEEEF', 'DDEFFF', 'DDDFFF'], cell: 32,
          caption: 'L bölgesinin her hücresi bordo hücreye değiyor'),
    ),
    TutorialSection(
      'İkili hapis',
      '''Hapsolan bölgenin iki bölgelik hâli: **iki bölgenin** kalan hücreleri birlikte **iki satıra** sığıyorsa, o iki satırın iki tacı bu iki bölgeden gelir. İki satırın diğer bütün hücreleri boş kalır.

Çizimde iki altın bölge 1. ve 2. satırlara sıkışmış; bu satırlardaki bordo hücreler elenir.

Aynı sayım üç ve dört bölge için de çalışır (**çoklu hapis**): k bölge k satıra sığıyorsa satırların kalanı boştur. Tersten de bak: k satırın kalan hücreleri k bölgenin içindeyse, o bölgelerin diğer satırlardaki hücreleri boş kalır.''',
      diagram: MiniGrid([
        '*. *. *. *. *. !×',
        '*. *. *. *. *. !×',
        '. . . . . .',
        '. . . . . .',
        '. . . . . .',
        '. . . . . .',
      ], regions: ['AABBBC', 'AAABBC', 'DDDCCC', 'DEECCF', 'DEEEFF', 'DDDEFF'], cell: 32,
          caption: 'İki bölge iki satıra sığıyor → satırların kalanı boş'),
    ),
  ],
  advanced: [
    TutorialSection(
      'Çarpışma testi',
      '''Bir hücreye bakıp sor: "Buraya taç koysam ne kapanır?" Komşularını, satırını, sütununu ve bölgesini kafanda X'le. Bir bölge, satır ya da sütun **tamamen kapanıyorsa** o hücreye taç gelemez.

Çizimde bordo hücreye taç koyarsan altın bölgenin iki hücresine değer, üçüncüsü de aynı sütunda kalır: bölgede yer kalmaz. Demek ki bordo hücre boş.

En verimli adaylar küçük bölgelerin ve neredeyse dolu satırların hemen yanındaki hücrelerdir.''',
      diagram: MiniGrid([
        '. . . . . .',
        '. . *. . . .',
        '. . *. *. . .',
        '. . !♛ . . .',
        '. . . . . .',
        '. . . . . .',
      ], regions: ['AAAACC', 'AABCCC', 'DDBBCC', 'DDEEEF', 'DDEFFF', 'DDDFFF'], cell: 32,
          caption: 'Bu taç altın bölgeyi tamamen kapatıyor'),
    ),
    TutorialSection(
      'Çift taç: kalıplar',
      '''Çift taçta her birim **iki** taç ister ve taçlar yine birbirine değmez. Bu, güçlü kalıplar doğurur:

- Yan yana **üç boş hücreye** iki taç ancak **iki uca** sığar; ortası boş kalır.
- Bir **2×2 kare** en fazla bir taç alır. Yalnız 2×2'lik bir alanı kalmış bölge iki taç alamaz.
- İki tacı kalmış bir satırda dört hücre yan yana ise taçlar ya 1–3, 1–4 ya da 2–4'e gider: bu kalıpların hepsinin değdiği hücreler boş kalır.

İpucu bu adımları "Kalıp" ve "Ortak komşu" diye adlandırır.''',
      diagram: MiniGrid([
        '~× ~× *♛ !× *♛ ~× ~× ~×',
      ], cell: 30, caption: 'Üç boş hücre, iki taç → iki uç'),
    ),
    TutorialSection(
      'Çizgi çifti ve 2×2 kareler',
      '''Komşu iki satırı **birlikte** düşün. Tek taçta iki taç, çift taçta dört taç isterler.

Çift taçta iki satırı soldan sağa **2×2 karelere** böl. Her kare en fazla bir taç alır. Dört taç gerekiyorsa ve kalan hücreler tam dört kareye sığıyorsa, **her karede tam bir taç** vardır. Bu, karelerin içindeki ve çevresindeki hücreler için hemen sonuç verir.

Genel kural: iki satırın bütün olası yerleşimlerinde ortak olan hücre taçtır; hepsinin değdiği hücre boştur. İpucu bunu "Çizgi çifti" olarak gösterir.''',
      diagram: MiniGrid([
        '. . . . . . . .',
        '. . . . . . . .',
      ], regions: ['AABBCCDD', 'AABBCCDD'], cell: 30, caption: 'İki satır, dört 2×2 kare: her karede bir taç'),
    ),
    TutorialSection(
      'Deneme zinciri',
      '''En zor bölümlerde bir hücre için varsayım yaparsın: "Burada taç olsaydı…" Sonra yalnız **zorunlu** adımları izle: son yerler, komşu X'leri, dolan çizgiler. Bir satır, sütun ya da bölge tıkanıyorsa varsayım yanlıştı; o hücre boş kalır.

Tersini de dene: "Bu hücre boş olsaydı…" ve bir birim tıkanıyorsa orası **taç**tır.

**Derin deneme**'de varsayımdan sonra hapis ve ortak komşu adımlarını da kullanırsın. Disiplin önemli: varsayımı tahtaya yazma, aklında yürüt; çelişki çıkmazsa hiçbir şey öğrenmemiş sayılırsın ve başka hücreye geçersin. En iyi adaylar iki seçenekli hücrelerdir: bölgesinde ya da satırında yalnız iki yer kalmış olanlar.''',
    ),
  ],
);
