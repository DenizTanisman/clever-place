import '../tutorial.dart';

// Diagrams: every column is a tube, the top row is the tube's mouth. Letters are colours:
// K kırmızı, M mavi, Y yeşil, S sarı; "." = empty space.
const waterSortTutorials = GameTutorials(
  rules: '''
- Bir tüpe dokun (tüp kalkar), sonra hedef tüpe dokun: üstteki **aynı renkli katmanların hepsi**, sığdığı kadar dökülür.
- Hedef tüp **boş** olmalı ya da en üstünde **aynı renk** bulunmalı.
- Her tüp ya boş ya da tek renkle **tam dolu** olunca kazanırsın; tamamlanan tüp altın kapak takar.
- Yıldızlar: hamlen **Hedef** sayısına eşit ya da azsa 3, en fazla 1,3 katıysa 2, fazlası 1 yıldız (gizli katmanlı bölümlerde 1,25 ve 1,6 kat). Geri almak bir hamle sayılır. İpucu ya da ek boş tüp kullanırsan en fazla 2 yıldız.

Bölümler dört türde döner: klasik, gizli katmanlar (alttaki katmanlar açılınca görünür), uzun tüpler (5 katman) ve tek boş tüp.''',
  mid: [
    TutorialSection(
      'Boş tüp altın değerinde',
      '''Boş tüp, elindeki tek **park yeri**dir. Onu karışık renklerle doldurursan hareket alanın kapanır.

Kural: Boş tüpe yalnızca, ardından en az bir tüpü tamamen boşaltacak ya da bir rengi bitirecek bir döküm yap. "Şimdilik buraya koyayım" diye yapılan dökümler, sonunda geri alma maliyetine döner.''',
    ),
    TutorialSection(
      'Önce üstleri eşle',
      '''Boş tüpe dokunmadan önce **aynı renkli tepeleri** birleştir. İki tüpün üstünde kırmızı varsa birini öbürüne dök: hem bir tüpün altı açılır hem de kırmızı bloku büyür.

Örnekte 1. tüpteki kırmızıyı 3. tüpe dökmek, 1. tüpün altındaki maviyi açığa çıkarır ve boş tüp yine boş kalır.''',
      diagram: MiniGrid(['. . . .', '*K . . .', 'M Y *K .', 'Y M K .'],
          caption: 'Kırmızıyı kırmızının üstüne dök, boş tüp boş kalsın'),
    ),
    TutorialSection(
      'Kısmi döküm',
      '''Döküm **sığdığı kadar** olur: üç katlı bir mavi bloku tek boşluğu kalan bir tüpe dökersen yalnızca bir katman geçer, iki katman kaynakta kalır.

Bu bazen işine yarar (bir tüpü tam dolu bitirmek için tam gereken kadar dökersin), bazen de bloku böler. Dökmeden önce hedefte kaç boşluk olduğunu say.''',
      diagram: MiniGrid(['M *.', 'M M', 'M Y', 'K Y'], caption: 'Soldaki üç maviden yalnızca biri sağdaki tek boşluğa sığar'),
    ),
    TutorialSection(
      'Bitirebileceğin rengi bitir',
      '''Bir rengin dört katmanı da tepelere yakınsa önce onu bitir. Tamamlanan tüp altın kapakla kilitlenir, tahtadaki karmaşa bir renk azalır ve dikkatin geri kalanlara kalır.

Taktik: Her renk için "kaç katmanı açıkta, kaçı gömülü?" diye sor. Gömülü katmanı en az olan renk, en ucuz bitecek renktir.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Taban tüpü seç',
      '''Her rengin bitişte bir **evi** olacak. En iyi ev, **dibinde zaten o renk** olan tüptür: üstünü boşalttığında o rengi doğrudan üstüne yığarsın.

Dibi iki farklı tüpte aynı renk olan durumlarda ikisinden birini tamamen boşaltman gerekir; hangisinin üstü daha hafifse onu seç. Bu kararı oyunun başında vermek, hamle sayını ciddi azaltır.''',
    ),
    TutorialSection(
      'Hedef sayısını anla',
      '''Her tüpü renk değişim noktalarına göre **bloklara** ayır. Bir döküm en fazla iki bloku birleştirir, yani blok sayısını en fazla bir azaltır. Bitişte her renk tek blok olacağına göre:

**en az hamle ≥ toplam blok − renk sayısı**

"Hedef", bilgisayarın bu sınırı kullanarak bulduğu çözümün hamle sayısıdır. Senin işin, blok sayısını her hamlede gerçekten bir azaltan dökümler bulmak; boşa giden her döküm hedeften uzaklaştırır.''',
    ),
    TutorialSection(
      'Gizli katmanlar',
      '''Gizli bölümlerde yalnızca en üstteki katman görünür; altındakiler açığa çıktıkça belirir ve bir kez görülen katman açık kalır.

- Bilgi en değerli kaynaktır: önce **en çok gizli katmanı açacak** dökümleri yap.
- Boş tüpleri bilinmeyen durumlara karşı yedekte tut; erken doldurursan açılan sürpriz bir renk seni kilitler.
- Yıldız sınırı burada daha esnektir (1,25 ve 1,6 kat), çünkü kimse görmediği katmanı planlayamaz.''',
    ),
    TutorialSection(
      'Tek boş tüp',
      '''Tek boş tüplü bölümlerde her döküm zinciri önceden planlanmalı. Boş tüpü kullanmadan önce şunu bil: **hangi tüp bu sayede tamamen boşalacak?** Boşalan o tüp yeni park yerin olur.

Altın kural: Boş tüpü, ancak geri vermeyi garanti edebildiğinde doldur. Takıldığını hissedersen birkaç hamle geri al; erken bir geri alma, kilitlenmiş bir tahtadan her zaman ucuzdur. Ek tüp düğmesi bölümü kurtarır ama yıldızı 2 ile sınırlar.''',
    ),
  ],
);
