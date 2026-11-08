import '../tutorial.dart';

const sceneQuizTutorials = GameTutorials(
  rules: '''
- Bir sahne birkaç saniye görünür (ilk bölümlerde 15 sn, ileride 3–4 sn). Hazırsan **Hazırım** ile erken kapatabilirsin.
- Sahne kapanınca sorular gelir: sayı soruları **dört sayılık seçiciyle**, diğerleri seçeneklerle cevaplanır.
- İlk soru **kilit sorudur**: yanlışsa bölüm hemen biter ve sonraki bölüm açılmaz.
- İleri bölümlerde ilk 2–3 soru bir **zincirdir**: "Kaç şapka vardı?" → "Bunlardan kaçı kırmızıydı?" → "Kırmızı olanlardan kaçı yündü?"
- "Şapka" sorularında **bere, kasket ve hasır şapka** da şapka sayılır.
- Yıldızlar: kilit sorudan sonra hepsi doğruysa **3**, bir yanlışla **2**, daha fazlasıyla **1**.''',
  mid: [
    TutorialSection(
      'Bakarken say',
      '''Soruların büyük kısmı **sayı** ister ve kilit soru çoğu zaman bir sayıdır. İlk iş, bakarken saymak:

- Kaç kişi? Kaçı oturuyor?
- Kaç şapka? Kaç gözlük, kaç çanta?
- Kaç hayvan, hangisi?

Sayıları içinden kısa bir cümleyle söyle: "**5 kişi, 3 şapka, 1 kedi.**" Sahne kapanınca ilk bu cümleyi hatırlarsın.''',
    ),
    TutorialSection(
      'Sözel etiketleme',
      '''Görüntü tek başına çabuk solar; ona bir **kelime etiketi** eklersen iki kanaldan kaydedilir (Paivio'nun ikili kodlama fikri). Görsel bellek bir bakışta 3–4 nesne tutar, sözel tekrar bunu uzatır.

Etiketleri kısa tut, sıfat önde:
- "**3 şapka: kırmızı yün bere, mavi kasket, hasır.**"
- "Masada iki fincan: beyaz, kırmızı."

Malzemeyi de etikete kat: yün (örgü çizgileri, ponpon), deri (parlak, dikişli), hasır (örgülü, geniş kenarlı), kumaş (düz).''',
    ),
    TutorialSection(
      'Kim, ne, nerede',
      '''Kişileri hep **aynı sırayla** tara: soldan sağa, arkadan öne. Her kişi için üç şey: **kim** (kadın, adam, çocuk, yaşlı), **ne** (şapka, üst, elindeki), **nerede** (masanın yanında, pencerenin önünde, bankta).

"Masanın yanında oturan kadın — kırmızı bere, gözlük."

Sorular kişiyi hep böyle tarif eder ("pencerenin önünde duran adamın kasketi…"); aynı kalıpla kaydedersen cevap hazır bekler.''',
    ),
    TutorialSection(
      'Zincire hazırlık',
      '''Zincir sorular bir kümeyi adım adım daraltır: önce hepsi, sonra bir renk, sonra bir malzeme. Saydığın her kümeyi küçük bir **ağaç** olarak kaydet:

"3 şapka → 2 kırmızı (1 yün, 1 kumaş) + 1 hasır."

Böylece ikinci ve üçüncü soru yeniden hatırlama değil, ağaçtan **okuma** olur. Kilit soru zincirin başıdır; o yüzden ilk sayını sağlamlaştır.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Hikâye yöntemi',
      '''Ayrı ayrı nesneler çabuk karışır; bir **hikâyeye** bağlananlar bir arada kalır. Sahneyi tek cümlelik bir olaya çevir:

"Kırmızı bereli kadın masada kitap okurken kasketli adam pencereden turuncu kediye bakıyor."

Hikâye hem sırayı hem **kimde ne olduğunu** (bağlamayı) korur. Biraz abartılı ve canlı imgeler daha iyi kalır: bereyi kocaman, kediyi şaşkın hayal et.''',
    ),
    TutorialSection(
      'Sahne için loci',
      '''Hafıza sarayının küçük bir sürümü: her sahneyi hep aynı **6 yere** yerleştir — arka sol, arka orta, arka sağ, ön sol, ön orta, ön sağ.

Bakarken her yere gördüğünü "bırak"; soruda o yerlere sırayla yürü. Loci'nin gücü sabit, sıralı ipuçlarından gelir (Caplan ve ark., 2019); yerler aynı kaldıkça her sahnede daha hızlı çalışır.''',
      diagram: MiniGrid(['1 2 3', '*4 *5 *6'], caption: 'Üst satır: arka sıra · alt satır: ön sıra'),
    ),
    TutorialSection(
      '3–4 saniyede ne yapmalı?',
      '''Bir sahnenin **özünü** 100 milisaniyede kavrarız, ama ayrıntı için göz saniyede ancak 3–4 kez durur. 3,5 saniye yaklaşık 12 bakış demektir; plansız harcarsan boşa gider.

Önceliğin:
1. **Say**: kişiler ve şapkalar (kilit soru büyük ihtimalle burada).
2. **Tuhaf olanı yakala**: balon, kedi, güneş gözlüğü.
3. Kalan bakışlarla bir–iki kişinin şapka rengi ve yeri.

Her şeyi yakalamaya çalışma; doğru şeyleri yakala.''',
    ),
    TutorialSection(
      'Tuzak seçenekler ve bağlama',
      '''Yanlış seçenekler rastgele değildir: çoğu **aynı sahneden** gelir. "Kırmızı" seçeneği orada, çünkü sahnede kırmızı bir şey vardı — ama belki başka birinin kazağıydı.

Bu, dikkat araştırmalarında bilinen bir hatadır: özellikleri doğru görüp **yanlış kişiye bağlamak** (Treisman'ın "hayalî birleşimleri"). Çözüm, kodlarken bağı açıkça kurmak: "kırmızı → **bere** → **kadın** → masa."

Cevap verirken kendine sor: "Bu rengi gördüm mü, yoksa **bu kişide** mi gördüm?"''',
    ),
  ],
);
