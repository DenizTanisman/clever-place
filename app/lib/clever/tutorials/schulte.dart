import '../tutorial.dart';

const schulteTutorials = GameTutorials(
  rules: '''
- Karışık dizilmiş sembollere **sırayla** ve olabildiğince hızlı dokun. Üstteki **Sıradaki** hapı aradığın sembolü gösterir.
- Bakışını ortadaki **altın noktada** tut; sembolleri çevre görüşünle yakala.
- Türler: sayılar (1 → N), geriye (N → 1), harfler (A → Z; Ğ ve I yok) ve **iki renk**: beyazlar artan, kırmızılar azalan sırayla, dönüşümlü.
- Tablo 4×4'ten 7×7'ye büyür. İleri bölümlerde boyutlar ve açılar karışır, sonra tablo her doğru dokunuşta **yeniden karışır**.
- Yanlış dokunuş saatine **2 saniye** ekler. Süre sınırı geniştir; dolarsa bölüm biter.
- Yıldızlar (cezalar dahil süreyle): hedef sürenin altında 3, hedefin 1,5 katına kadar 2, bitirirsen 1 yıldız.''',
  mid: [
    TutorialSection(
      'Yumuşak odak: gözünü gezdirme',
      '''Yeni başlayan, her sayıyı bulmak için gözünü hücreden hücreye atlatır. Her göz sıçraması yaklaşık 200 ms'lik bir duraklama demektir; 25 sembolde bu saniyeler eder.

Bunun yerine:
- Bakışını ortadaki noktaya **sabitle** ve tabloyu bir bütün olarak gör. Telefon ekranında 5×5 tablo, merkezin birkaç derece çevresine sığar; büyük, net rakamları orada tanıyabilirsin.
- Gözünü "kısma", gevşet: dar bir spot ışığı yerine geniş bir lamba gibi düşün. Aradığın sayı kendiliğinden "öne çıkar".
- Bulamadığında önce **yerinde kalarak** bir saniye bekle; ancak sonra gözünü kaydır ve hemen merkeze dön.

Dürüst not: çevre görüşü merkezden daha bulanıktır. Amaç her şeyi kenardan okumak değil, göz sıçramalarını azaltmaktır.''',
      diagram: MiniGrid(
          ['~9 ~14 ~3 ~22 ~17', '~11 ~6 ~19 ~1 ~24', '~2 ~15 *• ~8 ~20', '~18 ~4 ~12 ~25 ~7', '~23 ~10 ~16 ~5 ~13'],
          caption: 'Bakış merkezde; tablo bir bütün olarak görülür'),
    ),
    TutorialSection(
      'Bir sonrakini şimdiden ara',
      '''Parmağın gözünden yavaştır. Bunu kullan: **7'ye dokunurken 8'i aramaya başla.**

- Dokunma kararını verdiğin an dikkatini bir sonraki sembole bırak; parmak yolunu kendisi tamamlar.
- "Sıradaki" hapına her seferinde bakma: sırayı kafanda say. Hap yalnızca kaybolduğunda yardım içindir.
- Ritim tut: dokun–ara–dokun. Duraksamalar genellikle bir önceki dokunuşu "kontrol etmekten" gelir; doğru dokunuş zaten altın parlar.

Bu "boru hattı" alışkanlığı tek başına süreni belirgin biçimde kısaltır.''',
    ),
    TutorialSection(
      'Satır ve bölge parçalama',
      '''Tabloyu dört çeyreğe ya da 2–3 satırlık **şeritlere** böl. Bir sayıyı ararken yolda gördüklerini kaba bir haritaya yaz:

- 1'i ararken 2'nin sol altta, 3'ün üst ortada olduğunu "yan gözle" fark edersin. Bu bilgiyi at değil, **tut**.
- Hücre hücre değil, şerit şerit tara: bir bakışta bir satırın tamamını al.
- Haritan yanlış çıkarsa sorun değil; aramayı o çeyrekten başlatmak yine de zamandır.

Sabit tablolarda bölümün ikinci yarısı ilkinden hızlı geçmeli: haritan doldukça arama kısalır. Soluklaşan semboller ilk bölümlerde bu haritayı kurmayı öğretir.''',
      diagram: MiniGrid(['9 14 *3 22 17', '11 6 19 *1 24', '*2 15 13 8 20', '18 4 12 25 7', '23 10 16 5 21'],
          caption: '1 bulunurken 2 ve 3 de haritaya girer'),
    ),
    TutorialSection(
      'Hız mı, doğruluk mu?',
      '''Yanlış dokunuş 2 saniye ceza getirir. 5×5 tabloda iyi bir tempoda bu **iki–üç sembol** süresidir.

- Emin olmadan dokunma: yarım saniyelik tereddüt, bir hatadan dört kat ucuzdur.
- Özellikle 6 ile 9, 16 ile 19 ve harflerde Ç–C, Ö–O, Ş–S, Ü–U çiftlerine dikkat.
- Hata yaptıysan durma ve kendini suçlama: hemen sıradakine dön. Sinirli bir sonraki dokunuş, ikinci hatanın en yaygın sebebidir.

Amaç önce **hatasız bir tur**, sonra hız. Hatasız tempo oturunca hız kendiliğinden gelir.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'İki renk: toplam kuralı',
      '''İki renkli tabloda iki sayaç tutman gerekir: beyazlar 1'den yukarı, kırmızılar en büyüğünden aşağı. Her adımda iki sayıyı ayrı ayrı hatırlamak yorucu; kısayol şu:

**Beyaz + sıradaki kırmızı = kırmızı sayısı + 1.**

- 5×5: 13 beyaz, 12 kırmızı → toplam **13**. Beyaz 4'ten sonra kırmızı 13 − 4 = 9.
- 6×6: 18 + 18 → toplam **19**. 7×7: 25 beyaz, 24 kırmızı → toplam **25**.

Böylece tek bir sayıyı (beyazı) sayarsın, kırmızıyı her seferinde hesaplarsın. Renkleri de ayrı ara: kırmızı ararken beyazları "görmezden gel", gözün yalnızca sıcak tonu taransın.''',
      diagram: MiniGrid(['*1 !8 7 !3', '!5 3 !1 6', '2 !6 4 !2', '!7 8 !4 5'],
          caption: '4×4 · bordo = kırmızı · beyaz 1, kırmızı 8, beyaz 2, kırmızı 7… (toplam 9)'),
    ),
    TutorialSection(
      'Geriye ve harf dizileri',
      '''Ezberlenmiş sıra bozulunca beynin "sıradaki ne?" sorusuna her adımda emek harcar. Bu emeği azalt:

- **Geriye**: sayıyı içinden söyle, sonra ara: "yirmi üç… yirmi iki…". Söylenmiş bir hedef, bakarken akılda daha kolay kalır.
- **Harfler**: Türk alfabesini dörtlü gruplar halinde ezberle (Ğ ve I bu tabloda yok):
- A B C Ç · D E F G · H İ J K · L M N O · Ö P R S · Ş T U Ü · V Y Z
- Grup sınırlarında (Ç → D, K → L, S → Ş) kısa bir an "sıradaki grup" diye düşün; takılmalar en çok orada olur.''',
    ),
    TutorialSection(
      'Karışan tablo ve dikkat dağıtıcılar',
      '''İleri bölümlerde iki şey stratejini değiştirir:

- **Karışık boyut ve açı**: büyük yazılmış sayı daha önemli değildir. Gözün iriye kayar; bunu bil ve **şekle** bak, boyuta değil. Hafif eğik semboller de aynı sembol: 6 ile 9'u alt–üst kalınlığından ayırt et.
- **Her dokunuşta karışan tablo**: yer haritası işe yaramaz. Haritayı bırak, saf taramaya geç: merkezden çeyrek çeyrek, her seferinde aynı sırayla (örneğin saat yönünde). Sabit bir tarama sırası, rastgele göz gezdirmekten hızlıdır ve aynı yere iki kez bakmanı önler.

Karışan tabloda "bir sonrakini şimdiden ara" tekniği de çalışmaz; dokun, yeni tabloyu **bir bütün olarak** gör, sonra ara.''',
    ),
    TutorialSection(
      'Ne çalıştırıyor? Dürüst bilim',
      '''Schulte tabloları, Alman psikiyatr Walter Schulte'nin adını taşır ve uzun süredir dikkat ve görsel tarama hızını ölçmek için kullanılır. Kırmızı-siyah sürüm, Sovyet havacılık psikoloğu F. D. Gorbov'un **dikkat değiştirme** testidir.

Ne beklemelisin:
- Düzenli oynayınca **bu görevde** ve ona çok benzeyen görsel arama işlerinde hızlanırsın. Bu gerçek ve ölçülebilir bir kazançtır.
- "Hızlı okuma", "görüş alanını genişletme" ya da IQ artışı iddiaları iyi desteklenmez; beyin oyunlarının uzak işlere aktarımı zayıftır.

Önerim: günde birkaç tur, süreni not et. Süren uykusuz ya da bölünmüş günlerde belirgin uzuyorsa, tablo sana o günkü dikkat düzeyini gösteren hızlı bir ölçüm aracıdır.''',
    ),
  ],
);
