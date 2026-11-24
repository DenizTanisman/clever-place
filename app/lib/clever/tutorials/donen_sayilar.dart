import '../tutorial.dart';

const donenSayilarTutorials = GameTutorials(
  rules: '''
- Sayılar iç içe **dönen halkalara** dağılmıştır. **1'den başlayarak** sayılara sırayla dokun.
- Her halkanın hızı farklıdır ve komşu halkalar **ters yöne** döner. İleri bölümlerde bazı halkalar yavaşlayıp yön değiştirir.
- **Sıradaki sayı işaretlenmez.** Yalnız ilk bölümlerde 1'in çevresinde ince bir işaret vardır.
- Dokunduğun sayı kaybolur. Yanlış sayıya dokunmak dakikandan **2 saniye** götürür; boşluğa dokunmanın cezası yoktur.
- Her bölüm **60 saniyedir**. Hepsine ulaşırsan bölüm erken biter.
- Yıldızlar: bölümün 3. hedefi ve en çok 2 hata **3**, 2. hedef ve en çok 5 hata **2**, 1. hedef **1** yıldız. 1. hedefin altında bölüm geçilmez.
- **Sonsuz tur**: 60 saniyeyle başlarsın, her tam tur **12 saniye** ekler ve sonraki turu zorlaştırır. Puanın dokunduğun sayıların toplamıdır.''',
  rulesEn: '''
- The numbers are spread over nested **spinning rings**. Tap them in order, **starting from 1**.
- Each ring has its own speed, and neighboring rings spin **in opposite directions**. In later levels some rings slow down and reverse.
- **The next number isn't marked.** Only in the first levels is there a thin marker around the 1.
- A number you tap disappears. Tapping the wrong number costs **2 seconds** of your minute; tapping empty space has no penalty.
- Each level is **60 seconds**. If you reach every number, the level ends early.
- Stars: the level's 3rd target with at most 2 mistakes is **3**, the 2nd target with at most 5 mistakes **2**, the 1st target **1** star. Below the 1st target you don't pass.
- **Endless rounds**: you start with 60 seconds; every full round adds **12 seconds** and makes the next round harder. Your score is how many numbers you tap in total.''',
  mid: [
    TutorialSection(
      'Önce sayıyı söyle, sonra ara',
      '''Sıradaki sayı ekranda işaretlenmez, sırayı sen tutarsın. Sayıyı içinden söyle: "on yedi". Sonra onu ara.

- Söylenmiş bir hedef, göz gezdirirken daha kolay akılda kalır.
- Üstteki sayaç kaç sayı bulduğunu gösterir; aklın karışırsa ona bak, ama her dokunuşta bakma.''',
    ),
    TutorialSection(
      'Tek halka tara',
      '''Bütün tabloyu aynı anda tarama. Bir halkayı seç, onu baştan sona izle, yoksa sonrakine geç:

- Sıra her seferinde aynı olsun, örneğin **dıştan içe**. Böylece aynı yere iki kez bakmazsın.
- Dış halkalarda daha çok sayı vardır; aradığın sayının orada olma ihtimali daha yüksektir.''',
    ),
    TutorialSection(
      'Sayıya değil, gideceği yere dokun',
      '''Dönen bir sayıya baktığın yere dokunursan parmağın geç kalabilir. Parmak yola çıkarken sayı da ilerler:

- Hızlı halkalarda sayının **biraz önüne** dokun.
- Dokunma alanı sayının kendisinden geniştir, tam üstüne denk gelmen gerekmez.
- Yanına dokunduğun başka bir sayı varsa en yakın olan sayılır. Sıkışık yerde acele etme.''',
    ),
    TutorialSection(
      'Bir sonrakini şimdiden yakala',
      '''Dokunmak üzereyken gözünü sıradaki sayıya kaydır: parmak yolunu kendisi tamamlar.

Ararken gördüğün sayıları da unutma. 5'i ararken 6'yı fark ettiysen, onun hangi halkada ve hangi yöne gittiğini aklında tut. Bu küçük harita, halkalar dönse de işe yarar: **halka değişmez**, sadece konum kayar.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Halka haritası',
      '''Numaraların yeri sabit değildir ama **halkası sabittir**. Bir halkanın hangi sayıları taşıdığını öğrenirsen, aramayı o halkayla sınırlarsın.

Bölümün başındaki ilk birkaç saniyeyi yalnız 1'i bulmaya değil, gördüğün sayıların halkalarını kaydetmeye de harca. Bu, ilerleyen saniyelerde kendini geri öder.''',
    ),
    TutorialSection(
      'Yön değiştiren halkalar',
      '''Yön değiştirecek halka önce **yavaşlar**. Bu an aslında bir fırsattır:

- Yavaşlayan halkadaki sayıya o anda dokunmak en kolayıdır.
- Hızlı dönerken ileriye dokunma alışkanlığı burada zarar verir: halka durduysa önüne değil **üstüne** dokun.''',
    ),
    TutorialSection(
      'Hız mı, doğruluk mu?',
      '''Hata iki bedel öder: 2 saniye gider ve yıldız üst sınırın düşer.

- 2 saniye, geç bölümlerde yaklaşık **bir sayı** demektir.
- 3 yıldız için en çok 2 hatan olabilir. Üçüncü hatadan sonra hedef 2 yıldıza iner.
- Emin değilsen yarım saniye daha bak. Sıkışık halkada acele, en yaygın hata sebebidir.''',
    ),
    TutorialSection(
      'Ne çalıştırıyor? Dürüst bilim',
      '''Bu oyun, Schulte tablosu gibi **görsel arama** ve sırayı akılda tutma işidir; hareket eklenince gözünü hedefe göre ayarlaman da gerekir.

Düzenli oynayınca bu görevde ve ona benzeyen işlerde hızlanırsın. Genel zekâ ya da günlük dikkat üzerinde büyük bir etki beklemek için iyi bir kanıt yok. En dürüst kullanımı: kısa, odaklı bir antrenman ve o günkü dikkatini gösteren küçük bir ölçüm.''',
    ),
  ],
);
