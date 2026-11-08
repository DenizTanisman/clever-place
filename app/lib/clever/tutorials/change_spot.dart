import '../tutorial.dart';

const changeSpotTutorials = GameTutorials(
  rules: '''
- Resim **yanıp söner**: A, kısa bir boşluk, B, boşluk… İki resim arasında **bir şey** farklı (ileri bölümlerde 2–3 şey).
- Değişen yere **dokun**. Birden çok fark varsa hepsini bul; hepsi bulununca tur biter.
- Her turun süresi var. Süre biterse ya da turda **3 yanlış dokunuş** yaparsan tur kaçar ve değişiklik gösterilir.
- **2 tur kaçarsa** bölüm kaybedilir; tek kaçış affedilir.
- Her 4. bölüm **yan yana**: üstte A, altta B; farka hangi resimde dokunduğun önemli değil.
- Yıldızlar: hiç tur kaçırmadan, toplam en çok 1 yanlış dokunuşla ve ortalama tur süresinin %40'ı içinde bulursan **3**; hiç tur kaçırmazsan **2** (tek kaçış ama temiz ve hızlı oyun da 2); kalanı **1**.''',
  mid: [
    TutorialSection(
      'Değişim körlüğü: neden göremiyorsun?',
      '''Normalde bir şey değişince gözün oraya kendiliğinden kayar: değişim bir **hareket sinyali** üretir. Aradaki kısa boşluk bu sinyali siler. Geriye tek yol kalır: değişen yere **dikkatini vermiş** olman.

Rensink, O'Regan ve Clark (1997) bu "yanıp sönme" düzeneğiyle büyük değişikliklerin bile çoğu zaman 10–20 saniyede bulunduğunu gösterdi. Simons ve Levin (1998) ise sohbet ettiği kişi değiştirildiğinde insanların yarısının fark etmediğini buldu.

Dürüst beklenti: bu oyunla **bu tür görevlerde** tarama stratejin gelişir (yakın transfer). Genel dikkat ya da zekâ artışı vaat etmez.''',
    ),
    TutorialSection(
      'Önce öz, sonra ayrıntı',
      '''İlk bir–iki döngüde ayrıntıya dalma; sahnenin **özünü** çıkar: "Kafe; 4 kişi; 2 masa; pencere; saat."

Sonra bu listeyi tek tek yokla. Değişiklik çoğu zaman **adını koymadığın** bir yerde olur; isimlendirdiğin her şey bir sonraki döngüde karşılaştırılabilir hâle gelir.

- Kişiler: kim ayakta, kim oturuyor, kimde şapka var?
- Nesneler: masada ne var, yerde ne var?
- Arka plan: perde, saat, tablo, saksı.''',
    ),
    TutorialSection(
      'Izgara taraması',
      '''Gözünü rastgele gezdirmek aynı yerlere tekrar tekrar bakmana yol açar. Resmi zihninde **3×3 ızgaraya** böl ve her A–B döngüsünde **tek bir kareyi** incele.

Sıra hep aynı olsun: üst satır soldan sağa, sonra orta, sonra alt. Dokuz döngüde bütün resim taranmış olur ve hiçbir köşe atlanmaz.

Bir karede iki döngü boyunca hiçbir şey kıpırdamıyorsa güvenle bir sonrakine geç.''',
      diagram: MiniGrid(['*1 2 3', '4 5 6', '7 8 9'], caption: 'Her döngüde bir kare: 1 → 9'),
    ),
    TutorialSection(
      'Her döngüde bir–iki nesne',
      '''Görsel kısa süreli bellek bir bakışta ancak **3–4 nesne** tutar (Luck ve Vogel, 1997). Boşluğun ardından B geldiğinde, A'daki her şeyi hatırlayamazsın.

O yüzden her döngüde **1–2 nesne** seç ve sadece onlara sor: "Rengi aynı mı? Hâlâ orada mı? Yeri kaydı mı?"

Özellikle **boş alanlara** bak: masa üstü, zemin, bankın boş ucu. "Belirdi / kayboldu" türündeki değişiklikler hep böyle boşlukları doldurur ya da boşaltır.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Kenar ilgisi tuzağı',
      '''Rensink'in deneylerinde en uzun bulunan değişiklikler, sahnenin **ilgi çekmeyen** parçalarındaydı: duvar rengi, perde, masa, arka plandaki eşyalar. Gözümüz insanlara ve yüzlere koşar; arka plan "görülmüş sayılır".

İleri bölümlerde değişiklik sık sık oradadır:
- **Saatin akrebi** başka bir saati gösteriyor.
- **Perde** belirdi ya da rengi değişti.
- **Tablonun** resmi değişti, **saksı** kayboldu.

İnsanlarda bir şey bulamadığın her turda arka planı bilinçli olarak tara.''',
    ),
    TutorialSection(
      'Ton farkları',
      '''En ince değişiklikler renk değil **ton**dur: aynı mavi bir kademe açık ya da koyu.

Bunu nesne nesne aramak zordur. Bunun yerine bakışını **büyük bir renk alanına** (bir gövdeye, masa üstüne, bir perdeye) sabitle ve bir tam döngü bekle. Ton değişiyorsa o alan hafifçe "nabız atar" gibi parlayıp kararır.

Büyük alanlar bitince orta boy alanlara (çanta, kitap, fincan) geç.''',
    ),
    TutorialSection(
      'Yan yana karşılaştırma',
      '''Yan yana bölümlerde yanıp sönme yok; gözün iki resim arasında gidip gelir ve her gidişte biraz unutur.

- **Çapa yöntemi**: A'da belirgin bir nokta seç (bir kişinin şapkası), B'de aynı noktayı bul ve çevresindeki küçük alanı karşılaştır. Sonra bir sonraki çapaya geç.
- **Say, bakma**: "A'da masada 3 nesne, B'de 2" — saymak, göz atmaktan çok daha güvenilirdir.
- Satır satır git: arka sıra, orta sıra, ön sıra.''',
    ),
    TutorialSection(
      'Çoklu fark ve dokunma disiplini',
      '''2–3 farklı turlarda bir farkı bulunca baştan başlama; **taramaya kaldığın yerden** devam et. Farklar birbirinden uzak yerlerdedir.

Rastgele dokunmak pahalıdır: her yanlış dokunuş yıldızdan yer, 3'üncüsü turu kaçırır. Kural: **iki döngüde** aynı yerde değişimi görmeden dokunma.

Süre yarıyı geçtiyse panikleme; ızgaraya dön ve atladığın kareleri sırayla bitir. Sakin bir sistem, hızlı ama dağınık bakıştan daha çabuk sonuç verir.''',
    ),
  ],
);
