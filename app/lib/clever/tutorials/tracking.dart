import '../tutorial.dart';

const trackingTutorials = GameTutorials(
  rules: '''
- Turun başında bazı küreler **altın** parlar: hedeflerin onlar. Sonra hepsi aynı renge döner ve birkaç saniye hareket eder; duvarlardan ve birbirlerinden sekerler.
- Küreler durunca hedef bildiğin kürelere dokun. Yanlış seçimi ikinci dokunuşla geri alabilirsin; son hedefi seçtiğinde tur biter.
- Bir bölüm 4 turdur. Bütün hedefleri doğru bulduğun tur **kusursuz** sayılır.
- Yıldızlar: 4 kusursuz tur 3, 3 tur 2, 2 tur 1 yıldız; daha azında bölümü tekrar oynarsın.
- Hedef sayısı 3'ten 6'ya, küre sayısı 8'den 16'ya çıkar; hız ve hareket süresi (5 → 12 sn) artar.
- İleri bölümlerde **perde** (kürelerin arkasından geçtiği bantlar), **renk tuzağı** (bir an renk değiştiren küreler) ve **rakam** (hareket sırasında bir kürede beliren rakam) gelir. Rakam seçimden sonra sorulur; yanlış cevaplanırsa tur kusursuz sayılmaz.''',
  mid: [
    TutorialSection(
      'Merkeze bak, kürelere değil',
      '''Gözünü tek tek hedeflere çevirmek en doğal ama en zayıf yöntemdir. Göz bir hedefe sıçrarken diğerleri o anda görüş alanının kenarında kalır ve tam o an yer değiştirirler.

Bunun yerine bakışını **hedef grubunun ortasına** (ağırlık merkezine) koy ve orada tut. Hedefleri gözünle değil **dikkatinle** izlersin; çevresel görüş hareketi yakalamakta çok iyidir.

- Fehd ve Seiffert (2008) göz izleme çalışmasında, iyi takip edenlerin bakışının hedeflerin üstünde değil, hedef grubunun merkezinde durduğunu buldu.
- Grup arenanın bir köşesine kayarsa bakışını yavaşça onunla kaydır; sıçrama yapma, süzül.
- Arenanın ortasındaki soluk halkalar bakışına bir dayanak olsun.''',
    ),
    TutorialSection(
      'Hedefleri bir şekle bağla',
      '''Üç hedef bir **üçgen**, dört hedef bir **dörtgen** oluşturur. Altın parlama sırasında üç ayrı küre ezberleme; tek bir şekli ezberle.

Hareket başlayınca o şeklin **esnemesini** izle: üçgen uzar, daralır, döner. Bir köşe şekilden kopup başka bir kürenin yanından geçerse, şeklin bozulup bozulmadığına bak.

- Yantis (1992), insanların hedefleri zihinde "sanal bir çokgen" olarak gruplayıp izlediğini gösterdi; hedefler gruplanabilir biçimde hareket ettiğinde takip belirgin şekilde iyileşti.
- 5–6 hedefte tek şekil fazla karmaşık olur: hedefleri **iki küçük gruba** ayır (ör. bir üçgen + bir çizgi) ve iki grubu ayrı ayrı izle.''',
      diagram: MiniGrid([
        '. *1 . . .',
        '. . . ~o .',
        '~o . . . *2',
        '. . *3 . .',
      ], caption: 'Üç hedef = bir üçgen. Şekli izle, tek küreyi değil.'),
    ),
    TutorialSection(
      'Tek küreyi kovalama',
      '''Bir hedefi kaybetmek üzere olduğunu hissettiğinde gözünü ona dikmek isteyeceksin. Yapma: o küreyi kurtarırken çoğu zaman diğer ikisini kaybedersin.

- **Kayıp kabulü**: bir hedef karışırsa onu bırak, kalanları sağlam tut. Tur sonunda kaybettiğin hedef için, onu en son gördüğün yerin çevresindeki en olası küreyi seç.
- 3 hedefte 2'si kesin, 1'i tahmin; 3'ü de belirsiz olmaktan çok daha iyidir.
- Seçim yaparken önce en emin olduğun hedeflere dokun; belirsiz olanı en sona bırak.''',
    ),
    TutorialSection(
      'Tehlikeli anlar: yakın geçişler',
      '''Hız tek başına takibi bozmaz; asıl sorun bir hedefin bir başka küreye **çok yaklaştığı** anlardır. Franconeri ve arkadaşları (2010), takip hatalarının büyük kısmının bu yakın geçişlerden kaynaklandığını gösterdi.

- Dikkatini eşit dağıtma: bir hedef başka bir küreye yaklaşırken o bölgeye **dikkat ağırlığı** ver (gözünü değil).
- **Çarpışmalar** en riskli anlardır: iki küre çarpıştığında yön değiştirir. Hedefin çarpıştıktan sonra **hangi yöne** döndüğüne dikkat et; çoğu kayıp, çarpışmadan sonra yanlış küreyi izlemeye devam etmekten gelir.
- Duvardan sekme öngörülebilirdir: geliş açısı = gidiş açısı. Duvar sekmelerine daha az dikkat ayırabilirsin.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Perdenin arkası: yörüngeyi tahmin et',
      '''Perde bölümlerinde küreler altın kenarlı bantların arkasından geçer ve bir an görünmez olur. İyi haber: beyin kısa süreli kaybolmalara alışkındır. Scholl ve Pylyshyn (1999), nesneler doğal biçimde bir engelin arkasına girip çıktığında takibin neredeyse hiç bozulmadığını gösterdi.

- Hedef perdeye girerken **giriş noktasını ve yönünü** işaretle. Hız sabite yakındır; çıkışı bandın öbür kenarında, aynı doğrultuda bekle.
- Perdenin arkasında da çarpışma ve dönüş olabilir. Çıkışta iki aday varsa, beklediğin zamana ve doğrultuya en yakın olanı seç.
- Hareket bitince bantlar şeffaflaşır; arkada kalan küreleri de seçebilirsin.''',
    ),
    TutorialSection(
      'Renk tuzağı: konumu izle, rengi değil',
      '''Renk tuzağında rastgele bir küre yarım saniyeliğine yakut, zümrüt, ametist ya da kehribar renge bürünür. Bu, dikkatini istemeden çeken (dışsal yakalama) bir uyarandır; hedefle hiçbir ilgisi yoktur.

- Çoklu takip, nesnelerin **konumunu** izler, görünüşünü değil. Pylyshyn (2004) katılımcıların izledikleri nesnelerin nerede olduğunu bilip hangisinin hangisi olduğunu çoğu zaman karıştırdığını; Bahrami (2003) izlenen nesnelerdeki renk ve şekil değişikliklerinin sıkça fark edilmediğini gösterdi.
- Parlama olunca gözünü oraya **çevirme**. Kısa bir "gördüm" de ve bakışını grubun merkezinde tut.
- Bir hedef renk değiştirirse onu kaybetmiş sayma; renk geçer, konum kalır.''',
    ),
    TutorialSection(
      'İkili görev: rakamı yakala',
      '''Rakam bölümlerinde, hareketin ortasında bir kürenin üstünde kısa süreliğine (0,75 → 0,45 sn) bir rakam belirir. Seçimden sonra sorulur. Bu bir **ikili görevdir**: dikkat kaynağı sınırlıdır ve iki işe bölünür.

- Bakışını merkezde tut; rakamın belirdiğini çevresel görüşün fark eder. Okuyamazsan kısa bir bakış at ve **hemen** merkeze dön.
- Rakamı görür görmez **içinden söyle** ("yedi") ve bir kez tekrar et. Sözel bellek, görsel-uzamsal takipten kısmen ayrı çalışır; rakamı kelimeye çevirmek, takip için kullandığın kaynağı daha az yer.
- Önce hedefleri seç (sıra oyunda da böyle), sonra rakamı söyle. Rakamı unutmamak için seçim sırasında da aklında tut.''',
    ),
    TutorialSection(
      'Bilim ne diyor: çoklu takip neyi çalıştırır?',
      '''Çoklu nesne takibi, 1988'de Pylyshyn ve Storm'un deneyiyle başlayan, dikkat araştırmalarının standart bir görevidir.

- **Kapasite sabit değildir.** Alvarez ve Franconeri (2007): yavaş hareket eden 8 nesne izlenebilirken, çok hızlıda bu sayı 1–2'ye iner. Ortalama hızda çoğu yetişkinin sınırı 4 civarındadır. Bu yüzden hedef sayısı ve hız birlikte artar.
- **Pratikle bu görevde belirgin şekilde ilerlersin** (yakın aktarım): grubu izleme, yakın geçişleri yönetme ve dikkatini dağıtmama becerin gelişir.
- **Uzak aktarım zayıf.** Spor ve sürüş için satılan takip antrenmanları üzerine sistematik derleme (Harris, Wilson ve Vine, 2018) sahadaki performansa aktarım için güçlü kanıt bulamadı. Aksiyon oyunlarının dikkati geliştirip geliştirmediği de tartışmalı (Bediou ve ark., 2018 ↔ Sala ve ark., 2018).

Kısacası: bu oyun dikkatini sürdürme ve bölme pratiği için iyidir ve gerçekten gelişirsin; ama "zekâ artırır" ya da "sahada seni hızlandırır" demek için kanıt yok.''',
    ),
  ],
);
