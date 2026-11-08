import '../tutorial.dart';

const palaceTutorials = GameTutorials(
  rules: '''
- Her bölümde bir sarayda yürürsün (Ev, Yurt, Okul, Mahalle yolu, Ofis). Her durağa bir eşya gelir: **Durak 5 · Boy aynası → FİL**.
- Eşyayı durakla birlikte canlı bir sahneye çevir, sonra karta dokun ya da sola kaydır: eşya durağa yerleşir. Her eşyanın bir süresi var; süre bitince kendiliğinden yerleşir.
- Sonra yolu yeniden yürürsün: her durakta orada ne olduğunu **seçeneklerden seç**, ileri bölümlerde **yaz**. Aklında yoksa "Hatırlamıyorum" de.
- Bölüm türleri: ileri yürüyüş, geri yürüyüş, rastgele durak, yazarak ve **çift liste** (aynı saraya iki liste; arada sarayı temizlersin).
- Liste 5 eşyadan 40 eşyaya uzar; eşya başına süre 12 saniyeden 3 saniyeye iner, seçenekler birbirine benzer.
- Yıldızlar: %95 doğru → 3 (ya da %90 doğru ve eşyaları ortalama sürenin yarısında yerleştirdiysen 3). %80 → 2, %60 → 1. Daha azı başarısız.''',
  mid: [
    TutorialSection(
      'Canlı, tuhaf, çok duyulu imge',
      '''Beyin sıradan olanı siler, garip olanı saklar. Bir kelimeyi "düşünmek" yetmez; onu **gör, duy, kokla, dokun**.

- **Büyüt ya da küçült:** dev bir kiraz, avuç kadar bir fil.
- **Hareket ettir:** imge bir şey yapsın. Canlı varlıklar (insan, hayvan) daha iyi tutar; cansız eşyaya bile can ver (Blunt ve VanArsdall, 2021).
- **Duyu ekle:** ses, koku, sıcaklık, acı. "Tencere" değil, "fokurdayan, buharı yüzünü yakan tencere".
- **Abart ya da saçmala:** gülünç ya da biraz rahatsız edici sahneler daha kalıcıdır.

Örnek: **Boy aynası → FİL**. Fil hortumunu aynaya dayamış, buğulanan camda kendi dev kulaklarını görüp öyle bir hapşırıyor ki ayna çatlıyor. Çatlama sesini duy.''',
    ),
    TutorialSection(
      'İmgeyi durakla etkileştir',
      '''Hatırlarken elinde sadece durak var. Durak ile eşya arasındaki **bağ** zayıfsa eşya gelmez. Araştırmaya göre etkinin asıl kaynağı yürümek değil, **sıralı ipucu + canlı imge + ikisini birbirine bağlamak** (Caplan ve ark., 2019).

- Zayıf: "Ananas paspasın üstünde duruyor."
- Güçlü: "Ananas paspasa ayaklarını sile sile giriyor, dikenleri paspası delik deşik ediyor, liflerin yırtılma sesi geliyor."

Kural: eşya durağa **bir şey yapsın** ya da durak eşyaya bir şey yapsın: ezsin, yaksın, ıslatsın, yutsun, fırlatsın. Durağın kendine özgü özelliğini kullan: ayna yansıtır, ocak yakar, buzdolabı dondurur, turnike sıkıştırır.''',
    ),
    TutorialSection(
      'Sırayı tut: geri yürüyüş ve 5\'lik işaretler',
      '''İleri yürüyüşte yol seni taşır. **Geri yürüyüşte** son duraktan başla ve zihninde gerçekten geri geri yürü: arkanı dönüp kapıya doğru bak. Sahneyi yeniden canlandırmak, eşyayı "listeden çekmekten" daha güvenilirdir.

**Rastgele durakta** ("12. durakta ne vardı?") yürümeye vakit yok, o durağa **ışınlan**. Bunun için numaraları duraklara bağla:
- Her **5. durağa** bir el (beş parmak), her **10. durağa** bir kral tacı hayal et (bir kez, kalıcı olarak).
- 12 = taçlı durak + 2 adım. 17 = 15. durağın elinden 2 adım ileri.

Oyundaki yol da her durağın numarasını gösterir; onları sarayın kalıcı parçası yap.''',
      diagram: MiniGrid([
        '1 2 3 4 *5',
        '6 7 8 9 *10',
        '11 !12 13 14 *15',
      ], cell: 38, caption: '12. durak: 10\'un tacından 2 adım'),
    ),
    TutorialSection(
      'Önce hatırla, sonra bak',
      '''Seçenekler sana yardım etmez, **tuzak kurar**. Yanlış seçenekler üç türdendir:
- **Aynı listeden** başka bir eşya, çoğu zaman komşu duraktaki (sıra hatası).
- **Aynı türden** bir eşya: kiraz yerine vişne, keman yerine çello (benzerlik hatası).
- **Çift listede** aynı durağın eski eşyası (karışma hatası).

Taktik: Durağın adını okuyunca **seçeneklere bakmadan** önce sahneyi gör ve cevabı içinden söyle. Sonra seçeneklerde onu ara. Önce bakarsan tanıdık gelen ilk kelimeye kayarsın; tanıdık gelmek, doğru olmak değildir.

Emin değilsen tahmin etmek yerine "Hatırlamıyorum" de ve o durağın sahnesini sonraki turda daha güçlü kur.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Kendi sarayını kur',
      '''Oyundaki saraylar antrenman içindir; gerçek hayatta **kendi** sarayın çok daha güçlüdür, çünkü onu zaten biliyorsun.

- **Tanıdık bir yer seç:** evin, yurdun, her gün yürüdüğün yol.
- **Sabit bir yön belirle:** kapıdan gir, hep saat yönünde dön.
- **Oda başına 5–10 durak** seç; birbirine benzemesin (üç aynı sandalye kötü durak olur).
- Durakları bir kez gerçekten yürü, **numaralandır**, yaz.
- İlk hafta sadece yolu ezberle: gözünü kapat, 1'den 40'a ve 40'tan 1'e yürü.

Kanıt: Hiç deneyimi olmayan kişiler 6 hafta, günde 30 dakika çalışınca 72 kelimelik listede hatırladıkları kelime yaklaşık **26'dan 62'ye** çıktı, etki 4 ay sonra da sürdü (Dresler ve ark., 2017).''',
    ),
    TutorialSection(
      'Sarayı temizlemek ve yeniden kullanmak',
      '''Aynı sarayı ikinci kez kullanınca eski imgeler yeni listeye karışır (**önleyici ket vurma**). Çift liste bölümleri tam bunu çalıştırır.

- **Temizleme ritüeli:** İkinci listeden önce her durağı bir kez boş, temiz ve aydınlık gör. Bir rüzgârın eski sahneyi süpürdüğünü hayal et.
- **Yeni imgeyi daha güçlü kur:** daha büyük, daha gürültülü, daha tuhaf. Eskisiyle aynı duyuyu kullanma: eski sahne sesliyse yenisi kokulu olsun.
- **Dönüşümlü saraylar:** Uygulayıcılar eski imgeler solana kadar (birkaç gün) aynı sarayı yeniden kullanmamayı önerir. Bu, bilimsel olarak test edilmemiş bir pratik ipucu.
- Uzun süre saklamak istediğin bir liste için sarayı ayır, temizleme; onun yerine aralıklı tekrar yap.''',
    ),
    TutorialSection(
      'Sayılar: Major sistemi ve PAO',
      '''Sayılar resim değildir; önce onları resme çevir. **Major sistemi** her rakama bir ünsüz verir, ünlüler serbesttir:

0 = S, Z · 1 = T, D · 2 = N · 3 = M · 4 = R · 5 = L · 6 = C, Ç, Ş, J · 7 = K, G · 8 = F, V · 9 = P, B

- 14 = T-R → **TıR** · 90 = B-Z → **BoZa** · 21 = N-T → **NoTa** · 75 = K-L → **KaLe**
- 1490 → "dev bir **tır**, kasasından **boza** fışkırarak" tek bir sahne olur ve bir durağa gider.

**PAO** (Kişi-Eylem-Nesne) bir adım ileridir: 00–99 arası her sayıya bir kişi, bir eylem ve bir nesne atanır. 6 haneli bir sayı tek sahne olur: ilk iki hane kişi, ortadaki eylem, son iki hane nesne. Hafıza sporcularının çoğu böyle çalışır; kurması haftalar sürer.

Bu oyunda sayı listeleri yok; Sayı Dizisi'ndeki dizilerle Major sistemini deneyebilirsin.''',
      diagram: MiniGrid([
        '0 1 2 3 4',
        'S T N M R',
        '5 6 7 8 9',
        'L Ç K F P',
      ], cell: 36, caption: 'Major sistemi (kısa tablo)'),
    ),
    TutorialSection(
      '3 saniyede sahne ve dürüst bilim',
      '''Son bölümlerde eşya başına 3 saniye kalır. Hız için:
- **İlk akla gelen imgeyi** kullan, daha iyisini arama.
- Tek bir **güçlü fiil** yeter: ezer, yakar, yutar, fırlatır.
- Durakların "eylemlerini" önceden hazırla: ocak hep yakar, ayna hep yansıtır, duş hep ıslatır.

Ne kazandırır? Zihin sarayı sıralı listeler, sayılar, isimler ve konuşma iskeletlerinde güçlüdür: meta-analizlerde orta-büyük etki (g = 0,65; d = 0,88, ama ikincisinin kanıt kalitesi düşük). Bir konuyu **anlamanı** sağlamaz ve zekanı genel olarak artırmaz; bu oyunda yükselen şey **loci becerisidir**. Kalıcı öğrenme için sarayı aralıklı tekrar ve kendini test etmekle birleştir.''',
    ),
  ],
);
