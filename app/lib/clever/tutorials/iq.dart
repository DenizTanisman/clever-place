import '../tutorial.dart';

const iqTutorials = GameTutorials(
  rules: '''
- 1000 soru, 50 bölüm: her bölümde **20 soru**. Bölüm 1–25 orta, 26–50 zor sorular. Sorular kategoriler arasında döner; aynı tür arka arkaya gelmez.
- Kategoriler: matris, şekil ve sayı dizisi, eksik sayı, terazi, mantık, küp döndürme ve açınım, kâğıt katlama, blok sayma, zihinsel döndürme, şekil analojisi, farklı olanı bul, harf dizisi, şifre, kibrit çöpü, parça birleştirme, saat ve takvim, sözel problem.
- Süre yok. Kartın köşesindeki saat yalnızca bilgi içindir; acele ettirmez.
- Her cevaptan sonra doğru mu yanlış mı hemen görürsün; **Neden?** kutusu kuralı anlatır. **Devam** ile sıradaki soruya geç.
- Yıldızlar: 20'de **18** doğru 3 yıldız, **15** doğru 2, **12** doğru 1. 12'nin altı bölümü geçmez; aynı sorularla yeniden deneyebilirsin.
- **Karışık** modda 1000 soru arasından rastgele sorular gelir; doğru cevaplar seriyi uzatır, 3 hakkın var. Rekor: en uzun seri.
- Bu bir eğlence oyunudur: **IQ puanı ölçmez ve göstermez.**''',
  mid: [
    TutorialSection(
      'Önce kuralı söyle, sonra seçeneklere bak',
      '''Seçenekler bilerek "yakın" seçilir: her biri tipik bir hatadan gelir (son adımı tekrarlamak, işlem önceliğini unutmak, İngiliz alfabesiyle saymak). Onlara bakarak kural aramak seni yanlış yola sokar.

- Soruyu oku, kuralı **kendi cümlenle** kur: "her adımda iki katı, bir eksik".
- Cevabı kafanda hesapla, **sonra** seçeneklerde ara.
- Bulamazsan kural yanlıştır; seçeneklere değil, soruya dön.''',
    ),
    TutorialSection(
      'Diziler: farkların farkı',
      '''Sayı dizisinde ilk iş ardışık **farkları** yazmak. Farklar sabitse iş biter; değilse farkların farkına bak.

- 7, 12, 19, 28, 39 farkları 5, 7, 9, 11: her seferinde +2, sıradaki 39 + 13 = **52**.
- Farklar 1, 2, 4, 8 gibi büyüyorsa katlanıyordur; 1, 4, 9, 16 ise kareler.
- Hiçbiri tutmuyorsa **oranlara** (×2, ×3) ve **iç içe iki diziye** bak: tek sıradakiler bir kural, çift sıradakiler başka bir kural.''',
      diagram: MiniGrid(['7 12 19 28 39 *52', '. 5 7 9 11 *13'], cell: 30, caption: 'Üst sıra dizi, alt sıra farklar'),
    ),
    TutorialSection(
      'Eksik sayı: satırda kural ara',
      '''Izgara, üçgen, yıldız ya da çark: hepsinde aynı kural her örnekte tekrar eder. Tam olan örneklerden birinde kuralı tahmin et, **ikinci örnekte doğrula**, sonra eksik olana uygula.

- Önce basit işlemler: toplam, fark, çarpım.
- Sonuç büyükse kare ya da çarpım vardır (a² + b, a × b + a).
- Sonuç tuhaf uzunsa iki sayı **yan yana** yazılmış olabilir: 8 ve 3 için 5 | 11 = 511.
- Bazı sorularda bir sayı **tuzaktır**: kurala hiç girmez.''',
      diagram: MiniGrid(['4 7 9', '5 3 22', '6 11 *25'], cell: 34, caption: 'Birincinin karesi eksi ikinci'),
    ),
    TutorialSection(
      'Terazi ve semboller',
      '''Terazide en hafif şekli **1 birim** say, diğerlerini ona çevir. "İki üçgen bir kare" ise kare 2 birim; "kare ve üçgen bir daire" ise daire 3 birim.

Sembol denklemlerinde şekilleri tek tek çöz. Son satırda **işlem önceliğine** dikkat: önce çarpma ve bölme, sonra toplama ve çıkarma. 2 + 3 × 4 = 14, 20 değil.

Üç denklem birbirine bağlıysa (üçgen + kare, kare + daire, üçgen + daire) hepsini topla ve ikiye böl: üç şeklin toplamını bulursun.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Matris: satır ve sütunu ayrı oku',
      '''3 × 3 matriste her özellik (şekil, renk, sayı, yön) **kendi kuralını** izler. Hepsini birden değil, birer birer çöz:

- **Sabit**: satır boyunca aynı kalan.
- **İlerleme**: her adımda bir artan ya da dönen.
- **Üçlü dağılım**: her satırda üç değerin her biri bir kez.
- **Toplama / çıkarma**: üçüncü hücre ilk ikisinin birleşimi ya da farkı.

Her özelliğin cevabını bul, sonra hepsini taşıyan tek seçeneği seç.''',
      diagram: MiniGrid(['A B C', 'B C A', 'C A *B'], cell: 34, caption: 'Üçlü dağılım: her satırda her harf bir kez'),
    ),
    TutorialSection(
      'Küp, açınım ve döndürme',
      '''Küp sorularında iki temel bilgi yeter:

- **Karşılıklı yüzler** aynı anda görünmez. Bir seçenekte karşılıklı iki yüz yan yanaysa o seçenek elenir.
- Açınımda bir kare atlayarak aynı sıradaki iki kare **karşılıklıdır**.

Zor sorularda bütün seçenekler mümkün görünür; fark **yönde**dir: bir köşede üç yüzün saat yönündeki sırası sabittir. Ayna görüntüsü bu sırayı tersine çevirir.

Zihinsel döndürmede de aynı tuzak var: şekli döndürmek serbest, **ters çevirmek** yasak.''',
    ),
    TutorialSection(
      'Mantık: her durumu dene',
      '''"Kesinlikle doğru" demek, verilenlere uyan **her** durumda doğru demek. Bir seçeneğin olabilir olması yetmez.

- Sıralama ve oturma sorularında boş kutular çiz, kesin bilgiden başla (en solda, hemen sağında).
- "Bütün A'lar B'dir" kümeleri iç içe koyar; "Hiçbir B C değildir" ayırır. Küçük bir Venn şeması çiz.
- "Eğer … ise" cümlesinde sonuç doğru diye neden doğru olmaz. Bu tuzağa düşmemek için **"Kesin bir şey söylenemez"** seçeneği de bazen doğrudur.
- "Yalnızca biri doğru söylüyor" sorularında her ihtimali tek tek varsay ve doğru cümleleri say.''',
    ),
    TutorialSection(
      'Harfler, şifreler, saat',
      '''Harf sorularında daima **Türk alfabesi** (29 harf) geçerli: Ç, Ğ, I, İ, Ö, Ş, Ü da sayılır, Q, W, X yoktur. İngiliz alfabesiyle sayan seçenek en sık tuzaktır. Ekrandaki alfabe şeridi her harfin sırasını gösterir.

- Şifrede bir örnek kelimede her harfin kaç adım kaydığını yaz: hepsi aynıysa sabit kaydırma, 1, 2, 3 diye büyüyorsa sıraya bağlı kaydırma.
- Saat açısında akrep de hareket eder: her dakika **0,5°**. 3:40'ta akrep 110°, yelkovan 240°, aradaki açı 130°.
- Haftanın günlerinde 7'nin katlarını at: 100 gün sonra = 14 hafta + 2 gün.''',
    ),
  ],
);
