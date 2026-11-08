import '../tutorial.dart';

const shikakuTutorials = GameTutorials(
  rules: '''
- Izgarayı **dikdörtgenlere** (kareler de olur) böl.
- Her dikdörtgende **tam bir sayı** olmalı ve o sayı dikdörtgenin **alanına** (hücre sayısına) eşit olmalı.
- Bir köşeden karşı köşeye sürükleyerek çiz. Önizleme **altın** ise boyut ve sayı tutuyor, **bordo** ise tutmuyor.
- Yeni dikdörtgen üst üste geldiği eskileri siler. Bir dikdörtgene dokunursan kalkar; "1" yazan hücreye dokunmak onu tek başına kutular.
- Bütün ızgara geçerli dikdörtgenlerle kaplanınca bölüm biter. Her bölümün tek çözümü vardır ve tahmin gerektirmez.
- Yıldızlar: ipucu ve hatalı dikdörtgen yoksa 3, toplamı en fazla 3 ise 2, fazlası 1 yıldız. Çözümde olmayan her dikdörtgen bir hata sayılır.

Izgara 7×7 ile başlar, sonlara doğru 15×15 ve 18×12'ye kadar büyür; sayılar da büyüdükçe seçenekler çoğalır.''',
  mid: [
    TutorialSection(
      'Tek seçenek',
      '''Her sayı için sor: "Hangi dikdörtgenler ızgaraya sığar ve **başka sayı içermez**?" Tek bir aday kalan sayıyı hemen çiz.

Örnekte sol üstteki 4'ün 1×4 şeridi sağdaki 2'yi içine alır, 4×1 şerit ise ızgaraya sığmaz. Geriye yalnızca 2×2 kare kalır. Sonra sağ alttaki 4 de tek seçeneğe düşer ve bulmaca kendiliğinden çözülür.''',
      diagram: MiniGrid(['*4 *. . 2', '*. *. . .', '2 . . 4'], caption: 'Sol üstteki 4 için tek aday: 2×2 kare'),
    ),
    TutorialSection(
      'Asal sayılar ve şeritler',
      '''2, 3, 5, 7, 11, 13 gibi **asal** sayıların dikdörtgeni yalnızca **tek sıra şerit** olabilir (1×n ya da n×1). 4, 6, 8, 12 gibi sayıların ise çok daha fazla biçimi vardır.

Bu yüzden önce büyük asal sayılara bak: 7'lik bir şerit çoğu yönde bir sayıya ya da kenara çarpar ve seçenekleri hızla tükenir.''',
      diagram: MiniGrid(['. . . . .', '*5 *. *. *. *.', '. 3 . . .'],
          caption: '5 dikey sığmaz; yatayda da tek yol var'),
    ),
    TutorialSection(
      'Kenarlar ve köşeler',
      '''Kenara ve köşeye yakın sayıların seçenekleri azdır, çünkü dikdörtgen ızgaradan taşamaz. Büyük bir sayı köşeye sıkışmışsa çoğu zaman tek bir biçim kalır.

Taktik: İlk taramada köşelerden başla, sonra kenarlar boyunca ilerle. Yerleşen her dikdörtgen yeni bir "kenar" oluşturur — iç bölgeler de böyle köşeye dönüşür.''',
    ),
    TutorialSection(
      'Tek kapsayan',
      '''Sayılara değil, **boş hücrelere** bak: "Bu hücreye hangi sayılar ulaşabilir?" Yalnızca bir sayı ulaşabiliyorsa, o sayının dikdörtgeni bu hücreyi içermek zorundadır.

Örnekte sağ üst köşedeki iki hücreye yalnızca sağdaki 4 dikey bir şeritle ulaşabilir. Demek 4 dikey şerittir; 2 de altta kalan iki hücreyi alır.''',
      diagram: MiniGrid(['~4 ~. ~2 *.', '~. ~. ~. *.', '~4 ~. . *4', '~. ~. 2 *.'],
          regions: ['AABZ', 'AABZ', 'CCZZ', 'CCZZ'],
          caption: 'Köşeye yalnızca 4 ulaşabiliyor: 4 dikey şerit'),
    ),
  ],
  advanced: [
    TutorialSection(
      'Ortak çekirdek',
      '''Bir sayının bütün adayları **aynı hücreleri** kapsıyorsa, hangi aday seçilirse seçilsin o hücreler bu sayıya aittir. Başka hiçbir sayının dikdörtgeni oradan geçemez.

Örnekte dar bir koridordaki 4'ün üç olası şeridi de 4'ün kendisini ve sağ komşusunu içerir. O komşu hücre artık başka sayılar için **duvar**dır; bu da onların seçeneklerini budar.''',
      diagram: MiniGrid(['~. ~. 4 *. ~. ~.'], caption: 'Koridordaki 4: üç adayın ortak hücresi'),
    ),
    TutorialSection(
      'Sayılar duvardır',
      '''Bir dikdörtgen **iki sayı içeremez**. Bu yüzden her sayı komşularının önüne doğal bir duvar örer: büyük bir dikdörtgen çizmeye çalışırken araya giren her sayı o biçimi öldürür.

Taktik: Büyük bir sayının adaylarını sayarken, çevresindeki sayıların arasına "görünmez çizgiler" çek. Birbirine yakın iki sayının arasındaki hücreler genellikle ikisinden birine aittir — hangisinin daha az seçeneği varsa ondan başla.''',
    ),
    TutorialSection(
      'Alan muhasebesi',
      '''Yerleşmiş dikdörtgenler ve kenarlar bir bölgeyi **kapattığında**, içindeki sayıların toplamı bölgenin alanına eşit olmak zorundadır.

Kapalı bir cepte 6 hücre ve içinde yalnızca 2 ile 4 varsa, cebi ikiye bölmenin yolları çok azdır; çoğu zaman tek bölme kalır. Toplam tutmuyorsa bir yerde hata yapmışsındır — geri al ve kontrol et.''',
    ),
    TutorialSection(
      'Deneme: bir adım ileri',
      '''En zor bölümlerde bir sayının birkaç adayı kalır ve hiçbiri doğrudan elenmez. Her adayı **zihninde** çiz ve tek soruyu sor: "Bu dikdörtgen yerleşirse başka bir sayı sığacak yer bulabilir mi, her boş hücreye hâlâ biri ulaşabilir mi?"

Bir sayıyı yersiz ya da bir hücreyi sahipsiz bırakan aday yanlıştır; onu ele. Bu oyunda her bölüm bu tek adımlık denemeyle çözülebilir — daha derin tahmin gerekmez. İpucu düğmesi bu tekniğe "Deneme" der.''',
    ),
  ],
);
