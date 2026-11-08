import '../tutorial.dart';

// Rod diagrams: each column is a rod, top to bottom = beşlik (resting / at the beam), the beam
// (—), then the four birlik beads with the travel gap. Gold beads = the ones that just moved.

const sorobanTutorials = GameTutorials(
  rules: '''
- 50 bölümlük bir kurs: her bölüm kısa bir **ders kartıyla** başlar, sonra 8–10 alıştırma gelir. Kartı oyun içinde **Ders** düğmesiyle yeniden açabilirsin.
- Her çubukta üstte 1 **beşlik** (5), altta 4 **birlik** (1) boncuk var; sadece kirişe değen boncuklar sayılır. En sağ çubuk birlerdir.
- Boncukları **kaydırarak** oynat: birlikleri yukarı it ya da aşağı indir, beşliği indir ya da kaldır. Dokunmak da çalışır. Parmağını kirişin üstünde yana kaydırmak çubukları temizler (**Sıfırla**).
- Sonucu abaküste bırakıp **Tamam**'a dokun. Okuma ve anzan sorularında cevabı tuşlarla yazarsın.
- **İpucu** sıradaki boncuk hareketini okla gösterir. Yeni bir tekniğin ilk soruları rehberlidir: oklar kendiliğinden ve bedava.
- Yıldızlar: en az **%90 doğru, hedef süre altında ve ipucusuz** 3; %80 ve üstü 2; %70 ve üstü 1 yıldız. %70'in altında bölüm tekrarlanır.''',
  mid: [
    TutorialSection(
      'Okuma ve parmak tekniği',
      '''Bir çubuğu saymadan, şeklinden oku: beşlik kirişteyse 5, üstüne kirişe değen birlikler. Yukarıdaki abaküs **2079** gösteriyor.

- **Başparmak** birlikleri yukarı iter (ekler).
- **İşaret parmağı** birlikleri aşağı indirir, beşliği hem indirir hem kaldırır.
- 6–9 eklerken **kıskaç**: işaret parmağı beşliği indirirken başparmak birlikleri aynı anda kaldırır. Çıkarırken ikisi birlikte kirişten uzaklaşır.
- Çok basamaklı sayılarda daima **soldan sağa** çalış: önce büyük basamak.
- Kirişteki noktalar sağdan her üç çubukta bir: binler ve milyonlar için yer imi.

Hız, boncuğa bir kez ve kararlı dokunmaktan gelir; aynı çubuğa iki kez dönmek yavaşlatır.''',
      diagram: MiniGrid([
        '• • . .',
        '. . • •',
        '— — — —',
        '• . • •',
        '• • • •',
        '. • . •',
        '• • • •',
        '• • • .',
      ], cell: 30, caption: '2 · 0 · 7 · 9 = 2079'),
    ),
    TutorialSection(
      "5'in tümleyenleri (küçük arkadaşlar)",
      '''Sonuç bu çubukta 9'u aşmıyor ama gereken birlikler boşta değilse **beşliği** kullan.

- Çiftler: **1–4** ve **2–3**. Toplamları 5.
- Toplama: **+4 = +5 − 1**, +3 = +5 − 2, +2 = +5 − 3, +1 = +5 − 4. Beşlik iner, birlik iner.
- Çıkarma: **−4 = −5 + 1**, −3 = −5 + 2, −2 = −5 + 3, −1 = −5 + 4. Beşlik kalkar, birlik kalkar.

Örnek: 3 + 4. Altta sadece 1 birlik boşta, 4 gerekli. Beşliği indir (+5), 1 birlik indir (−1) » 7.

Kafanda "3 artı 4 yedi" deme; elin hareketi hatırlasın: "4 ekle = beşlik iner, bir iner".''',
      diagram: MiniGrid([
        '• . .',
        '. . *•',
        '— . —',
        '• » •',
        '• . •',
        '• . .',
        '. . *•',
        '• . •',
      ], cell: 30, caption: '3 + 4 = 3 + 5 − 1 = 7'),
    ),
    TutorialSection(
      "10'un tümleyenleri (büyük arkadaşlar)",
      '''Sonuç bu çubukta 9'u aşacaksa (ya da 0'ın altına inecekse) **soldaki çubuğu** kullan.

- Çiftler: **1–9, 2–8, 3–7, 4–6, 5–5**. Toplamları 10.
- Toplama: **+9 = +10 − 1**. Soldaki çubuğa 1 ekle, bu çubuktan tümleyeni çıkar.
- Çıkarma: **−9 = −10 + 1**. Soldaki çubuktan 1 indir (ödünç), bu çubuğa tümleyeni ekle.

Örnek: 7 + 9. Onlar çubuğuna +1, birlerden −1 » 16.

Soldaki çubuk 9 ise elde oradan da taşar: 97 + 5 » yüzlere 1, onlardan 9 çıkar, birlerden 5 çıkar = **102**. Ödünçte tersi: 103 − 5 » yüzlerden 1 indir, onlarda 9 kur, birlerde beşliği indir = **98**.''',
      diagram: MiniGrid([
        '• . . • .',
        '. • . . •',
        '— — . — —',
        '. • » *• •',
        '• • . . .',
        '• . . • *•',
        '• • . • •',
        '• • . • •',
      ], cell: 30, caption: '7 + 9 = 7 + 10 − 1 = 16'),
    ),
    TutorialSection(
      'Karışık tümleyenler',
      '''Bazen 10'un tümleyeninin bu çubuktaki kısmı bile doğrudan yapılamaz. 5 + 6: soldakine 1 eklersin, sonra birlerden 4 çıkarman gerekir ama kirişte hiç birlik yok, sadece beşlik var. O kısmı 5'in tümleyeniyle yap: −4 = −5 + 1.

- **+6 = +10 − 5 + 1**, +7 = +10 − 5 + 2, +8 = +10 − 5 + 3, +9 = +10 − 5 + 4.
- **−6 = −10 + 5 − 1**, −7 = −10 + 5 − 2, −8 = −10 + 5 − 3, −9 = −10 + 5 − 4.

Her basamakta karar sırası:
- Sonuç bu çubukta 0–9 aralığından çıkıyor mu? » **10'un tümleyeni** (soldaki çubuğa elde / ödünç).
- Bu çubukta kalan hareket için boncuk yeterli mi? » **doğrudan**; değilse **5'in tümleyeni**.

Bu iki soruyu her basamakta bir bakışta cevaplayabildiğinde temel kurs bitmiş demektir.''',
      diagram: MiniGrid([
        '• . . • *•',
        '. • . . .',
        '— — . — —',
        '. . » *• *•',
        '• • . . .',
        '• • . • •',
        '• • . • •',
        '• • . • •',
      ], cell: 30, caption: '5 + 6 = 5 + 10 − 5 + 1 = 11'),
    ),
  ],
  advanced: [
    TutorialSection(
      'Çarpma yerleşimi',
      '''Uygulamadaki yöntem modern soroban yerleşimine dayanır: **çarpılan** solda hazır durur, **çarpım** sağdaki alana kurulur ve birler basamağı en sağ çubuğa gelir.

- Çarpımın en fazla (çarpılan basamak + çarpan basamak) basamağı olur: 34 × 6 » 3 çubuk, 47 × 36 » 4 çubuk. Çarpımın ilk çubuğu böylece bellidir.
- Basamakları soldan sağa çarp ve her ara çarpımı **iki basamaklı** düşün (gerekirse başına 0): 3 × 6 = 18, 4 × 6 = 24.
- Her ara çarpım iki komşu çubuğa eklenir. Çarpılanda ya da çarpanda bir basamak sağa gittikçe ara çarpım da **bir çubuk sağa** kayar.
- Eklemeler sırasında bütün tümleyen teknikleri geçerli: 18'in üstüne 24 eklerken onlarda elde oluşur.

47 × 36: 4 × 3 = 12 en solda (sağdan 4. ve 3.), 4 × 6 = 24 ve 7 × 3 = 21 bir sağda, 7 × 6 = 42 en sağda » **1692**.''',
      diagram: MiniGrid([
        '~3 ~4 . . . . .',
        '. . . . *1 *8 .',
        '. . . . . *2 *4',
        '. . . . 2 0 4',
      ], cell: 30, caption: '34 × 6: 18 sağdan 3.–2., 24 sağdan 2.–1. çubuğa » 204'),
    ),
    TutorialSection(
      'Bölme: bölüm basamağının yeri',
      '''**Bölen** solda, **bölünen** sağda hazır. Bölümün birler basamağı işaretli çubukta biter; bölünen sona doğru sıfırlanır (kalansız bölme).

- Bölen, bölünenin ilk basamak(lar)ına **sığıyorsa** bölüm basamağını **iki çubuk sola**, sığmıyorsa **bir çubuk sola** yaz.
- Sonra bölüm basamağı × bölenin her basamağını, iki basamaklı olarak, bölüm basamağının hemen sağından başlayıp birer çubuk kayarak **çıkar**.
- Kalan, sıradaki basamak için bölene hiç yetmiyorsa o bölüm basamağı **0** olur ve çubuğu boş kalır: 618 ÷ 6 = 1**0**3.

İki basamaklı bölende bölüm basamağını ilk basamaklardan **tahmin** et (672 ÷ 32 » 6'da 3 iki kez » 2). Çıkarma yetmezse tahmin büyüktür: basamağı 1 azalt ve fazladan çıkardığın bir böleni geri ekle. Çıkardıktan sonra kalan hâlâ bölenden büyükse tahmin küçüktür: basamağı 1 artır, bir bölen daha çıkar.''',
      diagram: MiniGrid([
        '~4 . . . 8 4',
        '~4 . *2 . 0 4',
        '~4 . 2 *1 0 0',
      ], cell: 30, caption: '84 ÷ 4: önce 2 (08 çıkar), sonra 1 (04 çıkar) » 21'),
    ),
    TutorialSection(
      'Flash anzan stratejisi',
      '''Anzan, sayıları kelime olarak değil **boncuk resmi** olarak tutmaktır. Ustalar abaküsün görüntüsünü zihinde hareket ettirir; bu yüzden sesli sayma onları yavaşlatır.

- Her sayıda zihindeki boncukları **gerçekten oynat**: +4 gördüğünde "beşlik iner, bir iner" hareketini hisset. Başta parmaklarını havada oynatmak çok yardımcı olur.
- Önce **tek basamak, 3 sayı** ile hatasız ol; sonra sayı adedini, en son hızı artır. Hız ancak %100 doğrulukta artırılır, her seferinde yaklaşık %10.
- İki basamaklı sayıyı tek bir resim olarak "fotoğrafla", sonra zihinde soldan sağa iki hamle yap.
- Bir sayıyı kaçırırsan durma: zinciri sürdür, sonucu yine ver. Durmak daha fazlasını kaybettirir.
- Gözünü kutunun ortasına sabitle; sayılar hep aynı yerde belirir, göz gezdirmek zaman yer.''',
    ),
    TutorialSection(
      'Günlük 10 dakika ve dürüst bilimsel not',
      '''Kısa ama her gün çalışmak, haftada bir uzun oturumdan çok daha etkilidir. Önerilen 10 dakika:

- **2 dk ısınma**: okuma ve kurma, 0'dan 9999'a sayıları hızlıca kur ve temizle.
- **4 dk teknik**: bulunduğun bölüm; hatalı çıkan tümleyeni ayrıca tekrar et.
- **3 dk flash**: abaküslü ya da anzan, rahat bir hızda.
- **1 dk gözden geçirme**: hangi tümleyende takıldın? Yarın onunla başla.

**Bilim ne diyor?** Soroban ve zihinden abaküs (anzan) eğitimi, **aritmetik hızını ve doğruluğunu** belirgin biçimde artırır; bu, iyi desteklenen bir bulgudur. Usta anzancıların hesap yaparken dil yerine görsel-uzamsal ve motor beyin sistemlerine daha çok dayandığı görüntüleme çalışmalarında gösterildi (ör. Hanakawa ve ark., 2003). Hindistan'da çocuklarla yapılan üç yıllık kontrollü bir çalışmada (Barner ve ark., 2016) matematik becerileri gelişti, ama genel zekâya ya da çalışma belleğine yayılan açık bir etki bulunmadı.

Yani dürüst beklenti: daha hızlı ve güvenilir zihinden hesap, sayıları görselleştirme becerisi ve iyi bir odak alıştırması. "Beyni baştan yaratır" gibi iddialara temkinli yaklaş; yakın aktarım gerçek, uzak aktarım kanıtlanmış değil.''',
    ),
  ],
);
