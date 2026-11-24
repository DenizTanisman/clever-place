import '../tutorial.dart';

// Diagrams: ☼ = güneş, ☾ = ay, "=" / "×" tokens stand for the sign printed on the border between
// the two neighbouring cells.
const sunMoonTutorials = GameTutorials(
  rules: '''
- Her hücreye bir **güneş** ya da bir **ay** koy. Hücreye dokun: boş → güneş → ay → boş. Uzun basış hücreyi temizler.
- Her satırda ve her sütunda güneş ve ay sayısı **eşittir** (6×6'da üçer, 10×10'da beşer).
- Bir satırda ya da sütunda **üç aynı simge yan yana** gelemez.
- İki hücre arasındaki **=** işareti "ikisi aynı", **×** işareti "ikisi zıt" demektir.
- Kural ihlalleri bordo parlar. Üzerinde çalıştığın hücrenin yol açtığı ihlal, başka bir hücreye geçince ya da bir buçuk saniye dokunmayınca görünür; böylece aya giderken güneşten geçmek uyarı vermez. Hafif açık zeminli hücreler sabittir.
- Yıldızlar: ipucu ve hata yoksa 3, ipucu + hata en fazla 3 ise 2, fazlası 1 yıldız. Yanlış simgeyi bırakıp başka hücreye geçmek hata sayılır; aynı hücrede simgeler arasında dolaşmak serbest.

Bölümler 6×6 ile başlar, 120. bölümden itibaren 8×8, 300. bölümden itibaren 10×10 olur. İlerledikçe sabit hücreler azalır, işaretler artar.''',
  rulesEn: '''
- Put a **sun** or a **moon** in every cell. Tap a cell: empty → sun → moon → empty. A long press clears it.
- Every row and every column has **equal** numbers of suns and moons (three each on 6×6, five each on 10×10).
- **Three of the same symbol** can't sit side by side in a row or column.
- An **=** sign between two cells means "these are the same", an **×** sign means "these are opposite".
- Rule breaks glow burgundy. A break caused by the cell you are working on shows once you move to another cell or stop tapping for a second and a half, so passing through sun on the way to moon gives no warning. Cells with a lighter background are fixed.
- Stars: no hints and no mistakes 3, hints + mistakes at most 3 for 2, more for 1 star. Leaving a wrong symbol and moving to another cell counts as a mistake; cycling through symbols on the same cell is free.

Levels start at 6×6, become 8×8 from level 120 and 10×10 from level 300. As you go, there are fewer fixed cells and more signs.''',
  mid: [
    TutorialSection(
      'Çift kuralı',
      '''Yan yana iki aynı simge gördüğün anda **iki ucunu da** kapat: üçüncüsü gelemeyeceği için çiftin solundaki ve sağındaki hücre zıt simgedir.

Aynısı sütunlarda da geçerli. Tahtaya her baktığında ilk taraman gereken desen budur; çoğu bölümün açılışı tek bir çiftle başlar.''',
      diagram: MiniGrid(['*☾ ☼ ☼ *☾ . .'], caption: 'İki güneşin iki yanı da ay olmak zorunda'),
    ),
    TutorialSection(
      'Sandviç',
      '''İki aynı simge arasında **tek boşluk** varsa o boşluk zıt simgedir: araya aynısı gelirse üç yan yana olur.

"☼ _ ☼" gördüğün yere ay, "☾ _ ☾" gördüğün yere güneş koy. Çift kuralıyla birlikte bu iki desen, doğrudan kuralların neredeyse tamamıdır.''',
      diagram: MiniGrid(['. ☾ *☼ ☾ . .'], caption: 'İki ayın arasındaki boşluk güneş'),
    ),
    TutorialSection(
      'Sayı tamamlama',
      '''Bir satır kendi payını doldurduysa geri kalanı otomatik gelir: 6×6'da üç güneşi tamamlanan satırın **bütün boşlukları ay**dır (ya da tersi).

Taktik: Satır ve sütunları sayarak tara. "Kaç güneş, kaç ay kaldı?" sorusu, ileri tekniklerin de temelidir.''',
      diagram: MiniGrid(['☼ *☾ ☼ *☾ ☼ *☾'], caption: 'Üç güneş tamam: boşlukların hepsi ay'),
    ),
    TutorialSection(
      'İşaretleri okumak',
      '''**=** ve **×** işaretleri bilinen bir komşuya değdiği anda karşı hücreyi belirler: komşu güneşse = öbürünü güneş, × öbürünü ay yapar.

İşaretler zincir de kurar: A = B ve B × C ise A × C'dir; iki × arka arkaya gelirse uçtaki hücreler aynıdır. Bir zincirin bir ucu dolunca bütün zincir dolar — bu yüzden işaretli bölgelerde tek bir hücre bulmak bazen beş hücre kazandırır.''',
      diagram: MiniGrid(['☼ ~= *☼ ~× *☾ ~× *☼'], caption: 'Soldaki güneşten zincir boyunca: güneş, ay, güneş'),
    ),
  ],
  advanced: [
    TutorialSection(
      'Satır analizi',
      '''Doğrudan kurallar tükenince tek bir satırı ele al ve **kalan simgeleri dizmenin bütün yollarını** düşün. Bir hücre her yolda aynı çıkıyorsa yerini kesinleştirmişsindir.

Örnek: "☾ ☾ ☼ _ _ _" satırında 2 güneş ve 1 ay kaldı. Ay en sağa giderse ortadaki iki güneş, soldaki güneşle üçlü olur; demek ay 4. ya da 5. hücrede. İki durumda da **en sağ hücre güneş**.

İpucu düğmesi bu tekniğe "Satır analizi" der.''',
      diagram: MiniGrid(['☾ ☾ ☼ . . *☼'], caption: 'Ay iki yerden birinde olabilir ama sondaki hücre her durumda güneş'),
    ),
    TutorialSection(
      'Zıt çift sayımı',
      '''× ile bağlı iki boş hücre, satırın sayımına **bir güneş + bir ay** olarak girer — hangisinin hangisi olduğunu bilmesen bile.

Örnek: "☼ _ _ ☼ _×_" satırında 1 güneş ve 3 ay kaldı. Sondaki × çifti bir güneşle bir ayı yutar; geriye kalan iki boşluk ancak **ay** olabilir.

Aynı mantık = çiftinde de işler: = ile bağlı iki boşluk aynı simgeden iki tane ister; o simgeden 1 tane kaldıysa çift kesinlikle zıt simgedir.''',
      diagram: MiniGrid(['☼ *☾ *☾ ☼ . ~× .'], caption: '× çifti bir güneş + bir ay; kalan iki boşluk ay'),
    ),
    TutorialSection(
      'Eşit çift ve komşu',
      '''= ile bağlı iki boş hücre, sanki yan yana iki aynı simgeymiş gibi davranır. Hemen yanlarında bir güneş varsa çift güneş olamaz (üç güneş yan yana gelir), demek **ikisi de ay**dır.

Bu desen dikey de çalışır ve geç bölümlerde, sabit hücreler azaldığında, en sık açılış hamlesidir.''',
      diagram: MiniGrid(['☼ *☾ ~= *☾ . .'], caption: 'Güneşin yanındaki = çifti ay olmak zorunda'),
    ),
    TutorialSection(
      'Deneme ile çelişki',
      '''En zor bölümlerde bazen hiçbir satır tek başına yetmez. O zaman bir hücre seç, **zihninde** bir simge koy ve sonuçlarını zincirleme izle: çiftler, sandviçler, sayılar, işaretler.

Bir yerde üç aynı simge, taşan bir sayı ya da bozulan bir işaret çıkarsa varsayımın yanlıştır: hücre **zıt simgedir**. Çelişki çıkmazsa bir şey öğrenmedin; başka hücre dene.

Taktik: En çok kısıtlanmış hücreyi seç — dolu satırların kesişimi ya da işaret zincirinin ucu. Bu oyunda her bölüm bir adımlık denemeyle çözülebilir; daha derin tahmin gerekmez.''',
      diagram: MiniGrid(['☾ !☼ !☼ !☼ ☾ ☾'],
          caption: 'Varsayımın zinciri bir yerde böyle bir üçlüye varırsa, başlangıçtaki varsayım yanlıştır'),
    ),
  ],
);
