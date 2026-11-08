import '../tutorial.dart';

const mathTutorials = GameTutorials(
  rules: '''
- Soruyu oku, cevabı alttaki tuş takımıyla yaz ve **Tamam**'a bas. Ondalık için virgül, eksi için − tuşu.
- Yanlış cevapta doğrusu gösterilir ve sıradaki soruya geçilir. **Geç** soruyu yanlış sayar.
- Her bölüm 10–20 soru ve bir süre sınırıdır. Halka kalan süreyi, üstündeki çizgi 3 yıldız hedef süresini gösterir.
- Yıldızlar: en az **%95 doğru ve hedef süre altında** 3, %80 ve üstü 2, %60 ve üstü 1 yıldız. Altında kalırsan bölümü tekrar oynarsın.
- "Yeni:" bölümleri bir **hile kartıyla** başlar; kartı oyun içinde "Hile" düğmesiyle yeniden açabilirsin.
- Tahmin ve 72 kuralı sorularında yazılan tolerans içindeki her cevap doğrudur.
- **Sprint**: 60 saniye. Doğru cevaplar seriyi büyütür; seri büyüdükçe sorular zorlaşır ve her soru daha çok puan getirir.''',
  mid: [
    TutorialSection(
      'Yuvarla ve düzelt: ×5, ×9, ×25 ve ikile-yarıla',
      '''Zor çarpanı kolay bir yuvarlak sayıya çevir, sonra düzelt:

- **×5 = ×10 ÷ 2**: 68 × 5 → 680 ÷ 2 = **340**.
- **×9 = ×10 − 1 kez**: 46 × 9 → 460 − 46 = **414**. Aynısı ×99 için: 37 × 99 → 3700 − 37 = **3663**.
- **×25 = ×100 ÷ 4**: 64 × 25 → 6400 ÷ 4 = **1600**. ×75 = ×300 ÷ 4: 36 × 75 → 10800 ÷ 4 = **2700**. ×125 = ×1000 ÷ 8: 48 × 125 → 48000 ÷ 8 = **6000**.
- **İkile-yarıla**: bir çarpanı yarıla, ötekini iki katına çıkar; çarpım değişmez. 18 × 45 → 9 × 90 = **810**. Hedef: çarpanlardan biri 10, 100 gibi yuvarlak olsun.

Bölmede tersini yap: ÷5 = ×2 ÷ 10 (435 ÷ 5 → 870 ÷ 10 = 87), ÷25 = ×4 ÷ 100 (1300 ÷ 25 → 5200 ÷ 100 = 52).''',
    ),
    TutorialSection(
      '×11: araya toplamı yaz',
      '''İki basamaklı sayıyı 11'le çarparken iki rakamı aç, araya toplamlarını koy:

- 54 × 11 → 5 | 5+4 | 4 = **594**.
- Toplam 10 veya fazlaysa eldeyi soldakine ekle: 87 × 11 → 8 | 15 | 7 → **957**.
- Üç ve daha çok basamakta komşu rakamları topla: 352 × 11 → 3 | 3+5 | 5+2 | 2 = **3872**. 2718 × 11 → 2 | 9 | 8 | 9 | 8 = **29898**.
- ×22, ×33: önce ×11, sonra ×2 ya da ×3. 47 × 22 → 517 × 2 = **1034**.

Neden çalışır? 11 = 10 + 1, yani sayıyı bir basamak kaydırıp kendisiyle topluyorsun; araya düşen toplam o toplamanın ta kendisi.''',
      diagram: MiniGrid(['~3 ~+ ~6', '3 *9 6'], caption: '36 × 11: uçlar aynen kalır, ortaya 3 + 6'),
    ),
    TutorialSection(
      'Soldan sağa toplama ve tamamlayanla çıkarma',
      '''**Soldan sağa toplama**: Büyük basamaktan başla, ara toplamı söyleyerek ilerle. 568 + 275 → 700 → 830 → **843**. İlk söylediğin sayı cevabın büyük kısmıdır; tahmin hatası bile küçük kalır.

**Tamamlayanla çıkarma**: 1000, 10000 gibi bir sayıdan çıkarırken her basamağı 9'a, son basamağı 10'a tamamla:
- 1000 − 467 → 5, 3, 3 → **533**.
- 10000 − 3728 → 6, 2, 7, 2 → **6272**.
- Sondaki sıfırlar olduğu gibi kalır; 10'a tamamlanan, sıfır olmayan son basamaktır: 1000 − 380 → 6, 2, 0 → **620**.

**Yuvarla-düzelt**: 742 − 397 = 742 − 400 + 3 = **345**.

**Para üstü**: kasiyer gibi yukarı say. 50 − 18,65: 18,65 → 19 (0,35) → 20 (1) → 50 (30) → **31,35**.''',
      diagram: MiniGrid(['~1 ~0 ~0 ~0', '. 3 8 7', '. *6 *1 *3'], caption: '1000 − 387: 9−3, 9−8, 10−7'),
    ),
    TutorialSection(
      'Yüzde, indirim, KDV ve kesirler',
      '''**%10 ve %1 tuğlaları**: %10 virgülü bir sola, %1 iki sola kaydırır. 360'ın %35'i → 3 × 36 + 18 = **126** (%30 + %5).

**Yer değiştir**: 50'nin %18'i = 18'in %50'si = **9**.

**İndirim**: %25 indirim = %75'ini öde. 640 × 0,75 = **480**. Art arda %20 ve %10 indirim %30 değil, 0,8 × 0,9 = 0,72 → **%28** eder.

**KDV %20**: eklemek ×1,2 → 450 TL + KDV = **540**. Dahil fiyattan hariç fiyata ÷1,2 ile dön: 540 → **450**. Sık hata: 540'tan %20 düşmek 432 verir, yanlış.

**Bahşiş %15** = %10 + yarısı: 280 → 28 + 14 = **42**.

**Kesir tablosu**: 1/8 = 0,125 (3/8 = 0,375, 5/8 = 0,625, 7/8 = 0,875) · 1/16 = 0,0625 · 1/20 = %5 · 1/25 = %4. Paydayı 100'e tamamla: 7/20 = 35/100 = **%35**.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Kareler: sonu 5, komşu kare ve a² − b²',
      '''**Sonu 5 olan kare**: onlar kısmını bir fazlasıyla çarp, sonuna 25 ekle. 85² → 8 × 9 = 72 → **7225**. 135² → 13 × 14 = 182 → **18225**.

**Genelleme**: onlar aynı, birlerin toplamı 10 ise aynı hile çalışır, sona birlerin çarpımını yaz: 43 × 47 → 4 × 5 = 20 | 3 × 7 = 21 → **2021**.

**Komşu kare**: (n+1)² = n² + 2n + 1. 31² = 900 + 60 + 1 = **961**. 30'a kadar kareleri ezberlemek (21² = 441, 24² = 576, 27² = 729, 29² = 841) karekök sorularını da hızlandırır.

**Ortadan uzaklık**: iki sayı bir yuvarlak sayıya eşit uzaklıktaysa (a − b)(a + b) = a² − b². 68 × 72 = 70² − 2² = 4900 − 4 = **4896**. 23 × 27 = 25² − 2² = **621**.''',
    ),
    TutorialSection(
      '100\'e yakın çarpım: eksikler yöntemi',
      '''İki sayı da 100'e yakınsa eksiklerini (100'e uzaklıklarını) yaz:

- 96 × 89: eksikler 4 ve 11. **Çapraz çıkar**: 96 − 11 = 85. **Eksikleri çarp**: 4 × 11 = 44. Sonuç **8544**.
- Eksiklerin çarpımı 100'ü geçerse eldeyi ekle: 88 × 86 → 88 − 14 = 74 | 12 × 14 = 168 → 7400 + 168 = **7568**.
- 100'ün üstünde fazlaları ekle: 106 × 104 → 106 + 4 = 110 | 6 × 4 = 24 → **11024**.
- Biri üstte biri altta: 104 × 97 = 100 × (104 − 3) − 4 × 3 = 10100 − 12 = **10088**.
- 1000'e yakınsa son kısım üç basamaklıdır: 997 × 993 → 990 | 021 → **990021**.

Neden? (100 − a)(100 − b) = 100 × (100 − a − b) + a × b.''',
      diagram: MiniGrid(['97 ~→ *3', '94 ~→ *6', '*91 ~| *18'], caption: '97 × 94: 97 − 6 = 91, 3 × 6 = 18 → 9118'),
    ),
    TutorialSection(
      'Bölünebilme: kalanı bölmeden bul',
      '''- **2, 5**: son basamağın kalanı yeter. **4**: son iki basamak: 7316 → 16 → kalan **0**. **8**: son üç basamak: 53128 → 128 → kalan **0**.
- **3 ve 9**: rakamlar toplamının kalanı. 4638 → 4+6+3+8 = 21 → 9'a kalan **3**, 3'e kalan **0**.
- **11**: sağdan başla, rakamları sırayla +, −, +, − topla. 9273 → 3 − 7 + 2 − 9 = −11 → kalan **0**. Sonuç eksiyse 11 ekle: 5284 → 4 − 8 + 2 − 5 = −7 → −7 + 11 = **4**.
- **6**: önce 3'e göre kalanı (r) bul; 6'ya kalan r ya da r + 3'tür ve sayıyla aynı tek/çift olandır. 7451 → rakam toplamı 17 → r = 2; sayı tek, adaylar 2 ve 5 → **5**.

**2'nin kuvvetleri**: 2¹⁰ = 1024, 2¹² = 4096, 2¹⁶ = 65536, 2²⁰ = 1048576. 2¹⁰ ≈ 1000 bilgisi tahminde de iş görür.''',
    ),
    TutorialSection(
      'Tahmin, 72 kuralı ve ortalama',
      '''**Tahmin**: yuvarla, hesapla, düzelt. 612 × 49 ≈ 600 × 50 = 30000 (gerçek 29988). Bir sayıyı yukarı, ötekini aşağı yuvarlarsan hatalar birbirini götürür. 8734 ÷ 29 ≈ 8700 ÷ 30 = 290 (gerçek ≈ 301, fark %4).

**72 kuralı**: yıllık %r büyüyen şey ≈ 72 ÷ r yılda iki katına çıkar. %9 faiz → 8 yıl. Yıllık %24 enflasyonda fiyatlar ≈ 3 yılda ikiye katlanır; paranın alım gücü de aynı sürede yarıya iner. 16 yılda %9 ile iki kez ikiye katlanır: ≈ **4 kat**.

**Ortalama**: bir referans seç, sapmaları topla. 72, 85, 91, 68 → 80'e göre −8, +5, +11, −12 = −4 → −4 ÷ 4 = −1 → **79**. Eksik not: dört sınavda 85 ortalama için 80, 90, 78'den sonra 4 × 85 − 248 = **92** gerekir.

**Birimler**: km/sa ÷ 3,6 = m/sn (90 km/sa = 25 m/sn). °F = °C × 1,8 + 32 (30 °C = 86 °F).''',
    ),
  ],
);
