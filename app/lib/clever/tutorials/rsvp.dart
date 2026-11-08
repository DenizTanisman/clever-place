import '../tutorial.dart';

const rsvpTutorials = GameTutorials(
  rules: '''
- Harfler ekranın ortasında, hep aynı noktada, saniyede 8–12 harf hızla akar.
- Akışın içinde 2 (ileride 3) **hedef** var: harflerin arasındaki rakamlar, yakut renkli harfler ya da baştan gösterilen hedef harfler.
- Akış bitince gördüğün hedefleri seç (en çok hedef sayısı kadar, sıra önemli değil) ve onayla. Hiçbirini görmediysen "Göremedim".
- Her bölüm 16 akış. İki hedef arasındaki mesafeye **gecikme** denir (1–8 harf).
- **T1** = ilk hedefi yakalama oranın. **T2|T1** = ilk hedefi yakaladığın akışlarda sonrakileri de yakalama oranın.
- Yıldızlar: T1 ve T2|T1 en az %85 → 3; T2|T1 en az %72 → 2; aksi halde 1. T1 ya da T2|T1 %60'ın altındaysa bölüm kaybedilir.
- Sonuçta gecikmeye göre T2 başarın görünür: kendi dikkat kırpması eğrin.''',
  mid: [
    TutorialSection(
      'Dikkat kırpması',
      '''İlk hedefi gördükten sonraki yaklaşık **200–500 ms** içinde gelen ikinci hedef sık sık hiç görülmez. Buna **dikkat kırpması** denir (Raymond, Shapiro ve Arnell, 1992). Saniyede 10 harfte bu, gecikme 2–5 demek; en derin nokta gecikme 2–3.

Göz harfi görür; sorun, beynin ilk hedefi kalıcı hâle getirirken (kodlarken) ikinciye yer açamaması (Chun ve Potter, 1995).

İlginç istisna: **gecikme 1**. Hedef ilkinin hemen ardından gelirse çoğu zaman birlikte "içeri girerler" ve yakalanır. Sonuç grafiğinde 1'in yüksek, 2–3'ün çukur, 6–8'in yine yüksek olması beklenen eğridir.''',
      diagram: MiniGrid(['K R *7 M *3 P T', '~ ~ T1 ~ T2 ~ ~'], cell: 38, caption: 'Gecikme 2: T2, T1\'den iki harf sonra — kırpmanın dibi'),
    ),
    TutorialSection(
      'Yumuşak dikkat',
      '''Sezgiye ters ama sağlam bir bulgu: fazla **kasılmak** kırpmayı büyütür. Katılımcılara "rahat ol, çok odaklanma" denildiğinde ya da arka planda müzik dinlerken kırpma küçüldü (Olivers ve Nieuwenhuis, 2005, 2006).

Teknik:
- Gözün artıda, yüzün ve omzun gevşek. Akışı "yakalamaya" değil, **akmasına izin vermeye** çalış.
- Harfleri tek tek okumaya çalışma; hedef kendiliğinden "parlar".
- Bir akışta kaçırdıysan bir sonrakinde daha çok sıkma; tam tersine biraz bırak.''',
    ),
    TutorialSection(
      'T1\'i çabuk bırak',
      '''Kırpmanın büyük kısmı, ilk hedefe fazla yatırım yapmaktan gelir: onu aklında tekrar edip "kaybetmeyeyim" diye tutarken ikinciyi kaçırırsın.

Teknik:
- T1'i tek, kısa bir etiketle işaretle ("yedi") ve **hemen** akışa dön.
- Akış sırasında T1'i tekrar etme. İki-üç sembolü birkaç saniye tutmak kısa süreli belleğin için kolaydır; akış bitince orada olacak.
- Cevap ekranında önce en emin olduğunu seç, sonra diğerini.''',
    ),
    TutorialSection(
      'Akış öncesi hazırlık',
      '''Her akıştan önce artı işareti 0,7 saniye görünür. Bu senin hazırlık anın.

- Gözünü kırpmak istiyorsan şimdi kırp: 100 ms'lik bir harf göz kırpışında tamamen kaybolur.
- Telefonu hep aynı uzaklıkta ve aynı açıda tut, ekran parlaklığı yüksek olsun.
- Bir nefes ver ve bakışını artının tam ortasına sabitle. Harfler aynı noktada çıkacak; gözünü hareket ettirmen gerekmiyor.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Benzer şekiller: O/0, I/1, S/5',
      '''Normal bölümlerde rakama benzeyen harfler (O, I, İ, Z, S, G, B) **hiç** kullanılmaz ve rakamlar 2–9 arasındadır; yani gördüğün şekli karıştırma ihtimalin yoktur.

"Benzer" bölümlerde bunlar bilerek akışa girer ve tuş takımı 0–9 olur. Bu yazı tipinde ayırt edici işaretler:
- **0** dar bir oval, **O** neredeyse tam daire.
- **1**'in tepesinde bayrak var, **I** düz bir çubuk.
- **5**'in üstü düz ve köşeli, **S** baştan sona kıvrım.
- **2**'nin tabanı düz, **Z**'nin hem üstü hem altı düz.
- **8** iki kapalı halka, **B**'nin sol kenarı dümdüz.
- **6**'nın altında kapalı bir halka var, **G** ise sağdan açık bir yay.

İlk izlenimine güven: bu hızda "bir daha bakma" şansın yok.''',
    ),
    TutorialSection(
      'Üç hedef',
      '''Üç hedefli akışlarda T3, T2'nin kırpmasına da düşebilir. T2 ile T3 arası 1–5 harf.

- T1 ile T2 ardışık geldiyse (gecikme 1) onları tek bir parça gibi tut: "yedi-üç".
- Her hedefi yakaladığında yine kısa etiket ve akışa dönüş; zinciri kafanda kurmaya akış bittikten sonra başla.
- Seçim hakkın hedef sayısı kadar. Bu bir **zorunlu seçim** düzeni: emin olmadığın bir hedef için en güçlü izlenimini seçmek puanını düşürmez, yanlış seçim sadece özette sayılır. Hiç iz yoksa boş bırak.''',
    ),
    TutorialSection(
      'Hız arttıkça',
      '''Üst bölümlerde harf başına süre 80 ms'ye iner (saniyede 12,5 harf). Kırpmanın süresi milisaniye olarak aşağı yukarı aynı kalır; bu yüzden **daha çok harfe** yayılır: gecikme 3–6 da zorlaşır.

Ayrıca her hedefin hemen ardından gelen harf onu **maskeler**: bir şey gördüğünü bilirsin ama ne olduğundan emin olmazsın. Bu durumda ilk izlenim çoğu zaman doğrudur; uzun düşünmek hafızadaki izi daha da bulanıklaştırır.

Teknik: hız arttıkça bakışı daha da gevşet ve cevap ekranında ilk iki saniye içinde seç.''',
    ),
    TutorialSection(
      'Bilim ve beklenti',
      '''Dikkat kırpması insan beyninin en sağlam bulgularından biri; tamamen yok olmaz. Yine de değişebilir:

- Özel bir eğitimle kırpmanın uzun süre neredeyse kaybolduğunu gösteren bir çalışma var (Choi ve ark., 2012). Etki o göreve özgüydü.
- Üç aylık yoğun bir farkındalık meditasyonu inzivası sonrası kırpma küçüldü (Slagter ve ark., 2007).

Dürüst beklenti: bu oyunda T2|T1 eğrin düzelecek; bu, zamansal dikkatini **bu tür görevde** daha iyi dağıttığını gösterir. Genel zekayı ya da her işteki dikkati büyüttüğü iddiası kanıtlanmış değil. Buradaki asıl taşınabilir ders: kasılmadan, akışa izin vererek dikkat etmek.''',
    ),
  ],
);
