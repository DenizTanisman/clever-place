import '../tutorial.dart';

// Strategy charts: K = Kart (hit), D = Dur (stand), *2× = İkiye katla (double), !B = Böl (split).
// Columns: the dealer's up card 2..10 and A. Rules: 6 decks, dealer stands on soft 17, double after
// split allowed, no surrender.

const blackjackTutorials = GameTutorials(
  rules: '''
- Amaç: 21'i geçmeden krupiyeden yüksek toplam yapmak. Resimli kartlar 10, As 1 ya da 11 sayılır.
- Fişi **sürükleyip bahis çemberine bırak** (ya da fişe dokun), sonra **Dağıt**. Bahis 10–500.
- **Kart** çek, **Dur**, **İkiye katla** (ilk iki kartta; bahis ikiye, tek kart) ya da **Böl** (eş değerli iki kart, en fazla 4 el; bölünen aslara tek kart).
- Krupiye **17'de durur** (yumuşak 17 dahil), blackjack **3:2** öder. Krupiye As gösterirse sigorta sorulur. Teslim (surrender) yok.
- Masa **40 el**, **1.000 fişle** başlar: 1.000'in üstünde bitirirsen kazandın, tam 1.000 berabere, altında kaybettin. Fişin 10'un altına düşerse masa biter.
- Her karar **temel stratejiye** göre puanlanır ("Doğru %"). Koç masası her karardan sonra doğrusunu ve nedenini söyler; Kart sayma masası 4 elde bir "Sayım kaç?" diye sorar.
- Göz düğmesi (**Açık oyna**) krupiyenin kapalı kartını ve sıradaki 5 kartı gösterir; o masanın sonucuna "açık" yazılır.''',
  mid: [
    TutorialSection(
      'Sert toplamlar: krupiyenin kartına bak',
      '''As içermeyen (ya da Ası 1 sayılan) ellere **sert** denir. Kararın yarısı senin toplamın, yarısı krupiyenin açık kartı.

- Krupiye **2–6** gösteriyorsa **zayıftır**: çok sık batar (6'da ~%42). 13–16 ile **dur**, riski ona bırak.
- Krupiye **7–As** gösteriyorsa **güçlüdür**: genelde 17+ yapar. 12–16 ile durmak zaten kaybeder → **kart çek**.
- **12** istisnadır: sadece 10'luk kart seni batırır, bu yüzden krupiye 2–3'e karşı bile kart çek; sadece 4–6'ya karşı dur.
- **17 ve üstü**: her zaman dur. **8 ve altı**: her zaman kart.

Akılda tutma kuralı: krupiyenin kapalı kartını **10** say. 7 gösteren krupiye "17" demektir; 16'n onu yenemez.''',
      diagram: MiniGrid([
        '. 2 3 4 5 6 7 8 9 10 A',
        '9 ~K *2× *2× *2× *2× ~K ~K ~K ~K ~K',
        '10 *2× *2× *2× *2× *2× *2× *2× *2× ~K ~K',
        '11 *2× *2× *2× *2× *2× *2× *2× *2× *2× ~K',
        '12 ~K ~K D D D ~K ~K ~K ~K ~K',
        '13 D D D D D ~K ~K ~K ~K ~K',
        '16 D D D D D ~K ~K ~K ~K ~K',
        '17 D D D D D D D D D D',
      ], cell: 25, caption: 'Sert toplamlar (13–16 aynı satır) · K kart, D dur, 2× katla'),
    ),
    TutorialSection(
      'Yumuşak toplamlar: As bir can simididir',
      '''Ası 11 sayılan ele **yumuşak** denir (ekranda "Yumuşak 17"). Tek kartla batamazsın: büyük kart gelirse As 1'e döner. Bu yüzden yumuşak ellerde daha cesur oyna.

- **Yumuşak 13–17** (A2–A6): krupiye zayıfsa (A2–A3 için 5–6, A4–A5 için 4–6, A6 için 3–6) **ikiye katla**, yoksa kart çek. **Yumuşak 17'de asla durma.**
- **Yumuşak 18** (A7) en çok yanlış oynanan eldir: 3–6'ya **katla**, 2–7–8'e **dur**, 9–10–As'a **kart çek**. 18 bu kartlara karşı çoğu zaman kaybeder ve yumuşak el batmaz.
- **Yumuşak 19–21**: dur.

Üç kartlı yumuşak elde katlayamazsın: tabloda "katla" yazan yerde **kart çek** (yumuşak 18'de ise dur).''',
      diagram: MiniGrid([
        '. 2 3 4 5 6 7 8 9 10 A',
        'A2 ~K ~K ~K *2× *2× ~K ~K ~K ~K ~K',
        'A4 ~K ~K *2× *2× *2× ~K ~K ~K ~K ~K',
        'A6 ~K *2× *2× *2× *2× ~K ~K ~K ~K ~K',
        'A7 D *2× *2× *2× *2× D D ~K ~K ~K',
        'A8 D D D D D D D D D D',
      ], cell: 25, caption: 'A3 = A2 satırı, A5 = A4 satırı · A7 = yumuşak 18'),
    ),
    TutorialSection(
      'Çiftleri bölme',
      '''Bölmek, iyi bir başlangıç kartını iki ele çoğaltmak ya da kötü bir toplamdan kaçmaktır. Bu masada bölünen elde ikiye katlamak serbest (DAS), bu yüzden küçük çiftleri de bölebilirsin.

- **As-As ve 8-8: her zaman böl.** İki As 11'den başlayan iki eldir; 8-8 ise 16, oyunun en kötü toplamı.
- **5-5 ve 10-10: asla bölme.** 5-5 aslında güçlü bir 10'dur (katla); 20'yi bozmak para yakmaktır.
- **9-9**: 2–6 ve 8–9'a böl; 7'ye karşı dur (krupiye büyük ihtimalle 17, 18'in onu yener), 10 ve As'a karşı dur.
- **7-7**: 2–7'ye böl. **6-6**: 2–6'ya böl. **4-4**: sadece 5–6'ya böl. **2-2, 3-3**: 2–7'ye böl.
- 4 ele ulaşınca artık bölemezsin: o zaman eli normal toplam gibi oyna.''',
      diagram: MiniGrid([
        '. 2 3 4 5 6 7 8 9 10 A',
        'AA !B !B !B !B !B !B !B !B !B !B',
        '99 !B !B !B !B !B D !B !B D D',
        '88 !B !B !B !B !B !B !B !B !B !B',
        '77 !B !B !B !B !B !B ~K ~K ~K ~K',
        '66 !B !B !B !B !B ~K ~K ~K ~K ~K',
        '44 ~K ~K ~K !B !B ~K ~K ~K ~K ~K',
        '22 !B !B !B !B !B !B ~K ~K ~K ~K',
      ], cell: 25, caption: 'B böl · 3-3 = 2-2 satırı · 5-5 ve 10-10 bölünmez'),
    ),
    TutorialSection(
      'İkiye katlama: avantajı büyütmek',
      '''İkiye katladığında bahsin iki katına çıkar ama **sadece bir kart** alırsın. Bunu, o tek kartın seni güçlü bir ele götürmesinin muhtemel olduğu ve krupiyenin zor durumda olduğu anlarda yap.

- **11**: As hariç her karta katla. (Krupiyenin 17'de durduğu masada 11'e karşı As'ı katlamak az farkla kötü; kart çek.)
- **10**: 2–9'a katla; 10 ve As'a karşı sadece kart çek.
- **9**: sadece 3–6'ya katla.
- **Yumuşak eller**: krupiye 4–6 gösterirken A2–A7'nin çoğu katlanır (yumuşak toplamlar bölümü).
- Bölünen elde de katlayabilirsin: 8-8'i böldün, ilk ele 3 geldi → 11, katla.

Yaygın hata: katlamaktan çekinmek. Temel stratejinin kârının önemli kısmı, krupiye zayıfken bahsi büyütmekten gelir. Fişin yetmezse katlama düğmesi kapanır; o zaman katla yerine kart çek.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Hi-Lo sayımı ve gerçek sayım',
      '''Kartlar desteden çıktıkça kalan destenin bileşimi değişir. **Büyük kartlar** (10'lar, Aslar) oyuncuya yarar: blackjack 3:2 öder, krupiye 12–16'da daha sık batar. Hi-Lo bunu tek bir sayıyla izler:

- **2–6: +1** · **7–9: 0** · **10, resim, As: −1**
- Gördüğün her kartı topla: bu **koşu sayımı**dır (running count). Taze deste 0'dan başlar, tam deste yine 0'a döner.
- **Gerçek sayım = koşu sayımı ÷ kalan deste.** +6 iki deste kala +3 demektir, beş deste kala sadece +1,2.

Pratik: kartları **ikişer** say. Papaz + 5 = 0, iki küçük = +2. Krupiyenin kapalı kartını açılınca say. Bu masada her 4 elde bir "Sayım kaç?" sorusu gelir; sabot karıştırılınca (kesme kartı ~%75'te) sayım 0'a döner. Sayım düğmesiyle cevabını kontrol edebilirsin, ama önce kafandan say.''',
      diagram: MiniGrid([
        '2 3 4 5 6 7 8 9 10 A',
        '*+1 *+1 *+1 *+1 *+1 0 0 0 !−1 !−1',
      ], cell: 30, caption: 'Hi-Lo değerleri'),
    ),
    TutorialSection(
      'Bahis aralığı ve sapmalar (Illustrious 18)',
      '''Sayım iki şekilde kullanılır: **bahsi** ve **kararı** değiştirmek.

Bahis: gerçek sayım +1'in altındayken avantaj kumarhanededir → en küçük bahis. Kabaca her +1 gerçek sayım oyuncuya ~%0,5 kazandırır. Bu masada öneri: +2'de 2 birim, +3'te 4, +4'te 6, +5 ve üstünde 8 birim (1 birim = 25).

Sapmalar: temel strateji ortalama deste içindir; sayım yüksekken (çok 10'luk kalmışken) bazı kararlar döner. En değerlileri:
- **Sigorta**: gerçek sayım **+3** ve üstünde al.
- **16'ya karşı 10**: sayım **0 veya üstündeyse dur**.
- **15'e karşı 10**: +4'te dur. **10'a karşı 10**: +4'te katla. **11'e karşı As**: +1'de katla.
- **12'ye karşı 3**: +2'de dur; **12'ye karşı 2**: +3'te dur.
- **10-10'a karşı 5**: +5'te böl; **6**: +4'te böl.
- Ters yönde: sayım 0'ın altındaysa **12'ye karşı 4**'te kart çek; −1'in altında **13'e karşı 2**'de kart çek.

Kart sayma masasında bu sapmalar da **doğru** sayılır ve koç notu olarak gösterilir.''',
    ),
    TutorialSection(
      'Sigorta neden kötü bir bahis',
      '''Krupiye As gösterince sigorta, bahsinin yarısıyla "kapalı kart 10'luk" diye ayrı bir bahistir ve **2:1** öder.

Hesap: 6 destede 312 kartın 96'sı 10 değerindedir. Senin iki kartın ve krupiyenin Ası görüldükten sonra kalan ~309 kartın yaklaşık **96'sı** 10'luk → olasılık ~**%31**. 2:1 ödemenin başa baş olması için **%33,3** gerekir.

10 fişlik sigortanın beklentisi: 0,31 × 20 − 0,69 × 10 ≈ **−0,7 fiş**, yani sigortaya yatırdığının ~%7'sini kaybedersin.

"Elimde blackjack var, eşit para (even money) alayım" da aynı bahistir; uzun vadede yine kaybettirir. Tek istisna: **kart sayarken gerçek sayım +3 ve üstü** — o zaman kalan destede 10'lukların oranı %33'ü geçer.''',
    ),
    TutorialSection(
      'Kumarhane avantajı: dürüst not',
      '''Bu masanın kuralları (6 deste, krupiye yumuşak 17'de durur, bölmeden sonra katlama serbest, 3:2) oyuncu için iyi kurallardır. Kusursuz temel stratejiyle bile kumarhane avantajı yaklaşık **%0,4**'tür: oynadığın her 100 fişin ~0,4'ünü uzun vadede kaybedersin. Ortalama bir oyuncunun hataları bunu **%2–4**'e çıkarır.

Neden uzun vadede kazanılmaz?
- Temel strateji kaybı **küçültür**, sıfırlamaz.
- Kart sayma ~%0,5–1 avantaj verebilir ama büyük bahis aralığı, binlerce el ve büyük sermaye ister; dalgalanma çok büyüktür (bir elin standart sapması ~1,15 bahis). Gerçek kumarhaneler sayanı masadan uzaklaştırır, sık karıştırır ya da 6:5 öder (avantajı ~%1,4 artırır).
- 40 elde standart sapma ~7 bahistir: kısa vadede sonucu şans belirler.

Bu yüzden burada fişler sadece puandır. Kendini **"Doğru %"** ve **sayım doğruluğu** ile ölç: iyi karar, kötü bir elde de iyi karardır.''',
    ),
  ],
);
