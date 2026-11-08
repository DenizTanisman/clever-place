import '../tutorial.dart';

/// Blöf tutorials. Diagrams are [MiniGrid] "card ledgers": one row per rank, one cell per copy
/// (`*` gold = where you know the card is, `!` bordeaux = impossible / a lie, `~` dim = unknown).
const blofTutorials = GameTutorials(
  rules: '''
- 4 kişi, 52 kart, herkese 13. Sıra saat yönünde döner; turu açan bir **sayı** söyler ("Üç tane 7") ve 1–4 kartı kapalı yığına koyar.
- Sıradaki ya **aynı sayıyı** söyleyerek 1–4 kart koyar (doğru ya da yalan), ya **"Blöf!"** der, ya da **pas** geçer. Son koyulan kartlar, üstüne yeni kart gelene kadar sırası gelen herkesin itirazına açıktır.
- "Blöf!" denince son koyulan kartlar açılır: içinde başka sayı varsa **yalancı** bütün yığını alır, hepsi doğruysa yığını **itiraz eden** alır. Yığını almayan yeni turu açar.
- Üç kişi üst üste pas geçerse yığın **yanar** (oyundan çıkar), son kart koyan yeni turu açar.
- Bir elde bir sayının **dördü** toplanınca açılıp atılır; o sayı artık söylenemez — bu yüzden "dört tane" demek her zaman yalandır.
- Son kartlarını koyan hemen kazanmaz: herkes sırayla itiraz edebilir. Kimse itiraz etmezse ya da kartlar doğru çıkarsa **elini ilk bitiren kazanır**.
- Göz düğmesi (**Açık oyna**) bütün elleri, yığının gerçeğini ve rakiplerin neden öyle oynadığını gösterir. Lamba bir öneri verir ve olasılık yardımcısını açar; ipucu kullanılan galibiyet 1 yıldız, yardımsız galibiyet 3 yıldız sayılır.''',
  mid: [
    TutorialSection(
      'Kart takibi: defter tut',
      '''Her sayıdan yalnızca **4 kart** var. Kafanda her sayı için küçük bir defter tut ve kartları yerine yaz:

- **Elindekiler:** kesin bilgi.
- **Senin yığına koyduğun gerçek kartlar:** başkasında olamaz.
- **Açılan kartlar:** "Blöf!" sonrası açılan kartlar herkesin önünde yığını alana gider — o kişi oynayana kadar orada olduklarını bilirsin.
- **Atılan dörtlüler:** oyundan çıkmıştır.

Defterde yeri belli olmayan kart sayısı, rakiplerin o sayıdan **en fazla** kaç tane tutabileceğidir. Örnekte 9'lardan ikisi sende, biri açıldı ve Defne'ye gitti: Kerem en fazla **1 tane 9** tutabilir.''',
      diagram: MiniGrid([
        '9 *sen *sen *Def ~?',
        '7 *sen ~? ~? ~?',
        'K !at !at !at !at',
      ], cell: 40, caption: 'Altın: yeri belli · soluk: bilinmiyor · bordo: oyun dışı'),
    ),
    TutorialSection(
      'Ne zaman blöf yapılır?',
      '''Blöfün bedeli, yakalanırsan alacağın **yığın**dır. O yüzden blöf, yığın küçükken ucuzdur:

- **Turu açarken** yığın sadece senin kartlarından oluşur; yakalansan bile yalnızca kendi kartlarını geri alırsın. Elindeki **tekli kartları** (aynı sayıdan sadece bir tane olanları) gerçek kartların arasına katıp elden çıkarmanın en ucuz anı budur.
- **Tek kartla** blöf yap: "Bir tane 7" herkesin tutabileceği bir iddiadır, "Üç tane 7" ise şüphe çeker.
- Bu turda o sayıdan zaten çok şey söylendiyse (toplam 4'ü aşıyorsa) blöf yapma: sıradaki kişi hesap yapar.
- Elinde o sayı yoksa ve yığın büyükse **pas** geçmek çoğu zaman en iyisidir.''',
    ),
    TutorialSection(
      'Ne zaman "Blöf!" denir?',
      '''İtirazın üç güçlü gerekçesi var:

- **İmkânsız iddia:** elindekiler + bildiklerin, iddia edilen sayıyı aşıyorsa kesin yalandır. Elinde iki 9 varken biri "Üç tane 9" diyemez → **Blöf!**
- **Tur toplamı:** bu turda o sayıdan söylenenler ile senin bildiğin kartların toplamı 4'ü geçiyorsa birisi yalan söylüyor; çoğu zaman en son ve en büyük iddia.
- **Bitmek üzere olan rakip:** 1–2 kartı kalan oyuncu yalan söylemeye mecburdur; son kartlarına itiraz etmezsen oyun biter.

Gerekçe yoksa itiraz etme: doğru bir iddiaya "Blöf!" demek yığını sana yükler ve turu rakibe açtırır.''',
    ),
    TutorialSection(
      'Büyük yığın riski',
      '''Yığın büyüdükçe her hamlenin ağırlığı artar:

- **Doğru oynamak** her zaman güvenlidir: itiraz edilirse yığını itiraz eden alır.
- **Blöfün** riski yığınla birlikte büyür. 2 kartlık yığında blöf neredeyse bedavadır; 12 kartlık yığında yakalanmak oyunu kaybettirebilir.
- **İtirazın** riski de büyür: yanılırsan bütün yığını alırsın. Büyük yığında yalnızca güçlü gerekçeyle "Blöf!" de.

Kural: elinde o sayı yoksa ve yığın 6 kartı geçtiyse pas geç, yığının başkasında patlamasını bekle. Unutma, üç pas üst üste gelirse yığın yanar ve kimse almaz.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Olasılık hesabı',
      '''İddia "imkânsız" değilse soru şudur: **rakip bu kartları tutuyor olabilir mi?**

Yerini bilmediğin kartlar rakiplerin elleri arasında rastgele dağılmıştır. Göremediğin 39 kartın içinde 4 tane 9 varsa, 13 kartlık bir elde:
- en az **bir** 9 olma olasılığı ≈ %82,
- en az **iki** 9 ≈ %41,
- en az **üç** 9 ≈ %10.

Yani "Bir tane 9" büyük ihtimalle doğrudur, "Üç tane 9" ise çoğu zaman yalandır. Elinde 9 varsa bu oranlar hızla düşer: iki 9 sendeyse belli bir rakibin kalan iki 9'u birden tutma olasılığı yaklaşık %10'a iner.

Bir şey daha: o sayıyı tutmayan oyuncular çoğu zaman **pas geçer**, tutanlar oynar. Oynamayı seçmiş olmak, kartı tutmak lehine küçük bir kanıttır. Lamba düğmesi bu hesabı her iddia için yapar.''',
      diagram: MiniGrid([
        '1+ *%82',
        '2+ %41',
        '3+ !%10',
      ], cell: 44, caption: '13 kartlık elde belli bir sayıdan en az kaç tane?'),
    ),
    TutorialSection(
      'Rakip profili çıkarma',
      '''Her açılan el, oyuncunun karakteri hakkında bilgi verir. Geçmiş düğmesinden şunları izle:

- **Blöf oranı:** açılan iddialarından kaçı yalan çıktı? Sık yalan söyleyene karşı itiraz eşiğini düşür.
- **İtiraz sıklığı:** sık "Blöf!" diyen birinin önünde blöf pahalıdır; hiç itiraz etmeyenin önünde ucuz.
- **İtiraz isabeti:** itirazları hep haklı çıkan biri (İmkânsız masadaki gibi) yalanını mutlaka yakalar — ona karşı doğruyu oyna.
- **Kart sayısı:** az kartı kalan oyuncu daha çok blöf yapar, daha çok itiraz eder.

Zor masadaki rakipler seni de böyle izler: hep aynı şekilde oynarsan okunursun. Bazen doğru kartla tek kart koy, bazen tekli kartını blöfle at.''',
    ),
    TutorialSection(
      'Son kartlarda strateji',
      '''Son kartlarını koyduğunda herkes itiraz hakkı kazanır ve itiraz etmemek onlar için oyunu kaybetmek demektir. Bu yüzden **son hamle yalan olmamalı**.

- Elinde 3–4 kart kaldığında, hepsini **tek bir sayıya** indirmeye çalış: önce tekli kartlarını küçük yığınlarda blöfle at, sonra kalan çifti ya da üçlüyü kendi açtığın turda **doğru** söyle. İtiraz edilse bile kartlar doğru çıkar ve kazanırsın.
- Tur başkasındaysa ve kalan kartların o sayıdansa, hepsini doğru koy: bitişin garanti.
- Rakibin 1–2 kartı kaldıysa onun iddialarına daha kolay "Blöf!" de; o da senin gibi son kartlarını temizlemeye çalışıyor ve çoğu zaman yalan söylemek zorunda.''',
    ),
    TutorialSection(
      'İmkânsız masa: dürüst açıklama',
      '''İmkânsız masadaki rakipler **bütün elleri ve yığının gerçeğini görür**. Bu bir hile değil, açıkça söylenen bir antrenman ayarıdır:

- Yalanlarına **her zaman** itiraz ederler ve **hiçbir zaman** doğru bir iddiaya itiraz etmezler.
- Kendileri yalanı ancak kimsenin kârlı bir itiraz yapamayacağı durumda söylerler; masada başka bir İmkânsız oyuncu yalanı her zaman göreceği için pratikte **hiç yalan söylemezler**.
- Turu açarken en çok tuttukları sayıyı, mümkünse sıradakinin hiç tutmadığı sayıyı seçerler.

Bu masada kazanmanın tek yolu **hiç yalan söylememek** ve rakiplerin iddialarına güvenmektir (hepsi doğrudur!). Elin kötüyse kazanamazsın; iyiyse, sabırla doğru oynayarak bitirebilirsin. Buradan öğreneceğin ders: blöfsüz oyunun temposu ve doğru sayı seçmenin değeri.''',
    ),
  ],
);
