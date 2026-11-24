import '../tutorial.dart';

const hanoiTutorials = GameTutorials(
  rules: '''
- Her hamlede bir direğin **en üstteki** diskini başka bir direğe taşı.
- Diski **parmağınla sürükleyip** istediğin direğin üstüne bırak (istersen önce diske, sonra direğe dokunarak da taşıyabilirsin).
- Büyük disk asla küçük diskin üstüne konamaz.
- Bütün diskleri **HEDEF** direğine diz.
- Yıldızlar: en az hamleyle bitirirsen 3, en fazla 1,5 katıyla 2, daha fazlasıyla 1 yıldız. Geri almak da hamle sayılır.

Bütün bölümler üç direkle oynanır ve üç türde döner: klasik, dağınık başlangıç ve sadece komşu direğe taşıma. Disk sayısı bölümler ilerledikçe artar: klasikte 3'ten 8'e, komşu direkte 2'den 5'e.''',
  rulesEn: '''
- On each move, take the **top** disc of one peg and move it to another peg.
- **Drag the disc** and drop it on the peg you want (or tap the disc, then the peg).
- A larger disc can never go on top of a smaller one.
- Stack all the discs on the **GOAL** peg.
- Stars: finish in the fewest possible moves for 3, within 1.5 times that for 2, more for 1 star. Undo counts as a move too.

Every level uses three pegs and rotates through three types: classic, scattered start, and moves to a neighboring peg only. The number of discs grows as you go: from 3 to 8 in classic, from 2 to 5 in neighboring-peg levels.''',
  mid: [
    TutorialSection(
      'Büyük resim: özyineleme',
      '''n diski A'dan C'ye taşımak için önce üstteki **n-1 diski B'ye** park et, sonra **en büyük diski C'ye** taşı, sonra n-1 diski B'den C'ye taşı.

Yani 5 diskli problem, iki tane 4 diskli problem artı 1 hamledir. Bu yüzden en az hamle sayısı **2ⁿ − 1**: 3 disk 7, 4 disk 15, 5 disk 31 hamle.

Taktik: Her an kendine şunu sor: "Şu anda hangi büyük diski nereye taşımaya çalışıyorum?" Hedefin en büyük disk olunca küçükler kendiliğinden yol açar.''',
    ),
    TutorialSection(
      'İlk hamle kuralı',
      '''Klasik başlangıçta ilk hamleyi disk sayısı belirler:

- **Tek** sayıda disk varsa en küçük disk önce **hedef** direğe gider.
- **Çift** sayıda disk varsa en küçük disk önce **ara** direğe gider.

Yanlış yöne giden ilk hamle, en iyi çözümü baştan kaybettirir ve fazladan en az iki hamleye mal olur.''',
    ),
    TutorialSection(
      'En küçük disk döngüsü',
      '''En iyi çözümde **her iki hamleden biri** en küçük diskin hamlesidir ve o disk hep aynı yönde döner: tek diskte A→C→B→A, çift diskte A→B→C→A.

Arada kalan hamle her zaman tektir: en küçük diske dokunmadan yapılabilen **tek yasal hamle**. Kural basit: küçüğü döngüsünde ilerlet, sonra küçüğe dokunmayan tek hamleyi yap. Bu iki adımı tekrar et.''',
    ),
    TutorialSection(
      'Renk tekniği',
      '''Diskleri sırayla iki renge boya: 1 altın, 2 bordo, 3 altın... Bir kural: **aynı renkli iki disk asla üst üste gelmez**, ve bir disk boş direğe değil, mümkünse zıt renkli bir diskin üstüne gider.

Bu kural yanlış hamleleri baştan eler. Oyundaki disklerin rengi de altından bordoya doğru akıyor, komşu diskleri ayırt etmek kolay.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Dağınık başlangıç: en büyük diskten başla',
      '''Diskler karışık dizildiğinde ezber işe yaramaz, düşünmen gerekir:

- En büyük diske bak. Zaten hedefteyse onu **unut**: problem bir disk küçüldü.
- Değilse, onu hedefe taşıyabilmek için üstündeki ve hedefteki tüm küçük disklerin **üçüncü direkte** toplanması gerekir.
- Bu "küçükleri üçüncü direğe topla" işi, bir disk daha küçük aynı türden bir problemdir.

Bu yüzden aynı düşünce zinciri en büyük diskten aşağıya iner. İpucu düğmesi bu yolu gösterir; ama önce kendin düşün.''',
    ),
    TutorialSection(
      'Sadece komşu direk',
      '''A ile C arasında doğrudan geçiş yoksa her disk ortadan geçmek zorunda. En az hamle **3ⁿ − 1** olur: 3 diskte 26, 4 diskte 80.

Strateji: n diski A'dan C'ye taşımak için
1. n−1 diski C'ye (!) taşı,
2. en büyüğü B'ye taşı,
3. n−1 diski A'ya geri getir,
4. en büyüğü C'ye taşı,
5. n−1 diski C'ye taşı.

Garip görünür ama tek yol budur: büyük disk ortadayken küçüklerin hepsi ya solda ya sağda olmak zorunda.''',
    ),
    TutorialSection(
      'Zihin antrenmanı olarak Hanoi',
      '''Hanoi, nöropsikolojide **planlama** testi olarak kullanılır (Hanoi ve Londra Kulesi testleri). Antrenman önerisi:

- Hamle yapmadan önce ilk 3 hamleyi **kafanda** planla, sonra oyna.
- Dağınık başlangıçta ipucuna bakmadan çöz, sonra hamle sayını "En az" ile karşılaştır.
- Haftada bir 7-8 diskli klasik bölümü saatle çöz: 127 ya da 255 hamleyi hatasız yapmak bir dikkat sınavıdır.''',
    ),
  ],
);
