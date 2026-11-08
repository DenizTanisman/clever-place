import '../tutorial.dart';

// Diagram letters: Y = yakut (kırmızı), S = safir (mavi), T = topaz (sarı), A = ametist (mor).
// The bottom row of each diagram is the gate row.

const colorGatesTutorials = GameTutorials(
  rules: '''
- Her direğin altında renkli bir **kapı** var. Diskler direklerden aşağı kayar, her biri kendi hızında.
- Disk kapıya vardığında kapı **onun renginde** olmalı: disk geçer. Renk tutmazsa kapı çatlar ve **bir can** gider.
- Bir direğin üstünde herhangi bir yere **dokununca** o kapı sıradaki renge döner. Kapının altındaki küçük taş sıradaki rengi gösterir; renkler hep aynı sırayla döner.
- Rengi zaten doğru olan kapıya dokunma: gereksiz bir dokunuş doğru kapıyı bozar.
- İleriki bölümlerde: **hayalet** disk (içi boş) geçmemeli, kapı onun renginde olmasın. **Bukalemun** disk ışıldayınca renk değiştirir. **Takasta** kapılar yer değiştirir.
- Yıldızlar: bölüm, bütün diskler kapıya varınca biter. 0 hata 3 yıldız, 1 hata 2, 2 hata 1 yıldız. Üçüncü hatada bölüm kaybedilir.
- **Sonsuz yağmur**: 3 canın var. Yağmur hızlanır, yeni direkler ve renkler katılır. Puanın, geçirdiğin disk sayısıdır.''',
  mid: [
    TutorialSection(
      'Aşağıdan yukarı tara',
      '''Göz ekranı alışkanlıkla yukarıdan okur. Burada kararı **kapı satırı** verir, o yüzden taramaya aşağıdan başla:

- Önce kapı satırına bak, renkleri bir kez içinden söyle: "yakut, topaz, topaz".
- Sonra her direkte **kapıya en yakın diske** bak. Rengi kapıyla aynı mı?
- Aynıysa o direği bırak. Değilse o direk "iş listende".
- Üstteki disklere ancak bu tur bitince bak. Onlar daha yolda, şimdilik karar vermeleri gerekmiyor.

Bir tur yarım saniye sürmeli. Bir direğe takılıp kalırsan diğerleri seni kapıda yakalar.''',
      diagram: MiniGrid(
        ['~S . ~T', '. ~Y .', 'Y . .', '. S T', '*Y !T *T'],
        caption: 'Alttan tara: 1. ve 3. direk tamam. 2. direk safir istiyor, kapı topaz.',
      ),
    ),
    TutorialSection(
      'İlk varan önce',
      '''İki direk aynı anda değişiklik istiyorsa, **kapıya önce varacak** diskten başla. Bunu iki şey belirler:

- **Mesafe**: kapıya en yakın disk genelde ilk varır.
- **Hız**: diskler farklı hızlarda kayar. Arkasında uzun ışık izi olan disk hızlıdır, daha yukarıdan bile önce varabilir.

Önce acil direği çevir, sonra ikinciye geç. İkinci disk uzaktaysa ona zaman var: telaşla iki direğe birden dokunup birini yanlış renge götürme.''',
      diagram: MiniGrid(
        ['. ~S', '. ~.', '. S', 'T .', '!Y !T'],
        caption: '1. direkteki topaz daha yakın: önce onun kapısını çevir.',
      ),
    ),
    TutorialSection(
      'Doğru kapıya dokunma',
      '''Bu oyunun yarısı **dokunmamaktır**. Hızlanan yağmurda el, bir şey yapmak ister. Doğru kapıya bir kez dokunursan onu bozarsın. Geri getirmek de (4 renkte) üç dokunuş daha ister.

- Kendine bir kural koy: "Tutuyorsa ellerim duruyor."
- Bir direkte sıradaki iki disk farklı renkteyse, kapıyı **ilki geçmeden** değiştirme. Önce ilki geçer, sonra çevirirsin.
- Bölüm sonunda **Fazla dokunuş** sayısına bak. Bu sayı, gereğinden fazla yaptığın dokunuşlardır. Sıfıra yaklaştıkça hem hata azalır hem de zamanın artar.

Psikolojide bu beceriye **tepki ketleme** denir: hazır olan bir hareketi son anda durdurmak.''',
    ),
    TutorialSection(
      'Renk sırasını ezberle',
      '''Kapılar hep aynı sırayla döner: **yakut → safir → topaz → ametist → inci → başa**. Bölümde kaç renk varsa, sıra o kadarıyla döner.

- Gereken dokunuş sayısı, sıradaki **mesafedir**. 4 renkte topazdan safire gitmek için 3 dokunuş gerekir (topaz → ametist → yakut → safir).
- Dokunmadan önce sayıyı söyle: "üç". Sonra üç dokunuşu ritimle yap. Tek tek bakarak dokunursan zaman kaybedersin.
- Kapının altındaki küçük taş sıradaki rengi gösterir; son dokunuştan önce kontrol için ona bak.
- Her rengin bir işareti var: yakut ●, safir ◆, topaz ▲, ametist ■, inci ✦. Göz ucuyla bakarken şekil, renkten hızlı okunabilir.''',
      diagram: MiniGrid(['*Y S T A'], caption: '4 renk: Yakut → Safir → Topaz → Ametist → başa döner'),
    ),
  ],
  advanced: [
    TutorialSection(
      'İki elle ritim',
      '''Üç ve dört direkte tek parmak yetişmez. Ekranı ikiye böl:

- **Sol başparmak** soldaki direkleri, **sağ başparmak** sağdakileri alır. Dört direkte her ele iki direk düşer. Elini ortaya geçirme.
- Bütün sütun dokunma alanıdır. Ekranın üstüne uzanma, kapıların hemen üstüne, başparmağının rahat ulaştığı yere dokun.
- Bir direk iki ya da üç dokunuş istiyorsa dokunuşları **tek bir ritimle** yap: "ta-ta-ta". Her dokunuşu ayrı ayrı kontrol etme; sonucu kapının rengine bakarak doğrula.
- İki el aynı anda çalışabilir. İki direğin işi varsa, ikisini birlikte çevir.''',
    ),
    TutorialSection(
      'Çift disk: anı yakala',
      '''Aynı direkte peş peşe gelen iki farklı renkli disk, **zamanlama** sınavıdır:

- Kapıyı önce ilk diske göre ayarla.
- İlk disk geçtiği anda kapıda **altın kıvılcım** çıkar. Bu, çevirme işaretindir.
- Kıvılcımla birlikte ikinci diskin rengine çevir. Erken çevirirsen ilk disk çarpar, geç kalırsan ikincisi.
- Arada birkaç dokunuş gerekiyorsa sayıyı ilk disk gelmeden söyle ("iki"), işaret gelince ritimle bas.

Oyun, aynı kapıya varan farklı renkli iki disk arasında her zaman tepki için yeterli zaman bırakır. Bu süre en zor bölümde bile 350 ms'den kısa değildir. Yani yetişmek mümkün, ama beklemen gerek.''',
      diagram: MiniGrid(
        ['. ~.', '. S', '. Y', '. *Y'],
        caption: 'Yakut geçince kıvılcım: hemen safire çevir',
      ),
    ),
    TutorialSection(
      'Hayalet, bukalemun, takas',
      '''Üç özel durum, üç ayrı kural:

- **Hayalet** (içi boş, kesik halka): kural tersine döner. Kapı hayaletin renginde **olmasın**. Kapı zaten başka renkteyse dokunma. Aynı renkteyse **tek dokunuş** yeter, herhangi bir başka renk işini görür.
- **Bukalemun**: ışıldamaya başlayınca içinde **gelecek rengi** büyüyen bir çekirdek görürsün. İlk rengine göre kapı ayarlama; değişimi bekle, son renge göre çevir. Oyun, değişimden sonra tepki için yeterli zaman bırakır.
- **Takas**: yer değiştirecek kapıların arasında yaklaşık bir saniye önce **altın yaylar** belirir. O kapıları önceden ayarlama. Kapılar yerine oturunca taramaya önce o direklerden başla.''',
    ),
    TutorialSection(
      'Bölünmüş dikkat: dürüst bir not',
      '''Bu oyun birkaç akışı aynı anda izlemeyi, aralarında hızla geçiş yapmayı ve gereksiz hareketi durdurmayı çalıştırır.

- İnsan dikkati gerçekte **aynı anda** iki şeye bakmaz. Odağını direkler arasında çok hızlı kaydırır ve her geçişin küçük bir bedeli vardır. "Multitasking'de iyiyim" duygusu araştırmalarda pek doğrulanmaz. Bu oyunda kazanılan beceri, geçişleri ucuzlatan bir **tarama düzenidir**.
- Antrenmanla bu oyunda ve ona çok benzeyen işlerde belirgin şekilde ilerlersin. Bu kazancın genel zekâya ya da günlük hayatın bambaşka işlerine taşındığını gösteren sağlam bir kanıt yok (Sala ve Gobet, 2017; Simons ve ark., 2016).
- Sürekli dikkati ve tepki hızını en çok **uykusuzluk** bozar (Lim ve Dinges, 2010). Kötü bir gecenin ardından skorun düşerse bunun sebebi becerin değil, yorgunluğundur.
- Öneri: 10–15 dakikalık oturumlar oyna, bildirimleri kapat. Hatalar art arda gelmeye başlayınca bırak.''',
    ),
  ],
);
