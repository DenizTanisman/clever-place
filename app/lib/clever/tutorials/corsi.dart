import '../tutorial.dart';

const corsiTutorials = GameTutorials(
  rules: '''
- Bloklar tek tek **altın** rengi yanar. Sonra onlara **aynı sırayla** dokun. Süre sınırı yok.
- **Tersten** bölümlerinde (bordo rozet, sola bakan ok) sondan başa doğru dokun.
- **Karışık yön** bölümlerinde (30. bölümden sonra çoğu bölüm) yön önceden söylenmez. Gösterim bitince üstte **AYNI SIRADA** ya da **TERS SIRADA** yazısı belirir; o denemede ona göre dokun. Yön her denemede değişebilir.
- **Bordo** yanan bloklar tuzak: sıraya dahil değiller, yok say.
- Bazı bölümlerde bloklar gösterimden sonra yavaşça **kayar**: yanan bloğu takip et, eski yerini değil.
- Yanlış bir dokunuş denemeyi bitirir; doğru sıra numaralarla yeniden gösterilir.
- Yıldızlar: 6 denemede 6 doğru 3, 5 doğru 2, 3–4 doğru 1 yıldız. 3'ten az doğru bölümü kaybettirir.
- **Uyarlanır** mod klinik Corsi merdivenidir: dizi 3'ten başlar, iki şanstan biri doğruysa bir uzar. Önce ileri, sonra tersten; puan = ileri açıklık + geri açıklık.''',
  mid: [
    TutorialSection(
      'Yolu bir şekil olarak gör',
      '''Blokları tek tek ezberlemeye çalışma. Yanan blokları kafanda **bir çizgiyle birleştir**: ortaya bir zikzak, bir üçgen, bir "Z" ya da bir kanca çıkar.

Bir şekli hatırlamak, beş ayrı noktayı hatırlamaktan çok daha kolaydır. Mekânsal bellek hareketi ve yönleri iyi tutar.

Dokunurken de aynı çizgiyi çiz: parmağın şeklin üstünden geçsin.''',
      diagram: MiniGrid([
        '. *1 . . .',
        '. . . *2 .',
        '*3 . . . .',
        '. . *4 . .',
        '. . . . *5',
      ], caption: 'Örnek: 1→2→3 bir "Z"nin üstü, 3→4→5 aşağı inen bir merdiven'),
    ),
    TutorialSection(
      'Parçalara böl: 2–3 hamlelik gruplar',
      '''Çalışma belleği aynı anda yaklaşık **4 parça** taşır (Cowan, 2001). Hile, her parçayı büyütmektir.

- 6 blokluk diziyi **iki üçlü** gör: "sağa kayan üçlü" + "aşağı inen üçlü".
- 7–8 blokta 3 + 3 + 2 dene.
- Parçalar arasında gösterimde doğal bir dönüş varsa sınırı oraya koy.

Dokunurken de parçalar halinde dokun: üç dokunuş, kısa bir nefes, sonraki üç dokunuş.''',
    ),
    TutorialSection(
      'Son bloktan sonra bir kez prova et',
      '''Son blok söndüğünde hemen dokunmaya başlama. Süre sınırı yok: şekli **gözünle bir kez yeniden yürü**, sonra dokun.

Mekânsal prova, dikkatin sırayla o yerlere kaymasıyla yapılır (Awh ve Jonides, 2001). Gözünü ya da dikkatini bloklar üzerinde gezdirmek izi tazeler.

Gösterim sırasında da yeni yanan bloğu bir öncekine bağla: "buradan şuraya". Gözünü yanan bloğa sabitle, etrafa dağılma.''',
    ),
    TutorialSection(
      'Çapa bloklar ve kısa etiketler',
      '''Bloklar düzensiz dizildiği için bazıları "yerli yerinde" durur: en köşedeki, en kenardaki, iki bloğun arasında sıkışmış olan. Bunlar **çapan** olsun.

Zor bir bloğu çapaya göre etiketle: "sol üst köşenin altındaki". Bir iki kısa sözel etiket mekânsal izi destekler (görsel + sözel = çift kodlama).

Ama her bloğa etiket koyma: sözel sesli tekrar yavaş, şekil hızlıdır. Etiketi sadece şekli bozan tek bir sıçrama için kullan.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Tersten: şekli geri yürü',
      '''Tersten dizide blokları tek tek ters çevirmeye çalışırsan bellek dolar. Bunun yerine **şekli olduğu gibi sakla** ve onun üstünde sondan başa yürü.

- Gösterimde şekli normal kur.
- Dokunmadan önce şeklin **son ucunu** bul; parmağını oraya koy ve çizgiyi geri izle.
- Parçalarla çalışıyorsan: parçaların sırasını ve her parçanın içini birlikte ters çevir (3-3 → son üçlü tersten, sonra ilk üçlü tersten).

Araştırmalarda Corsi'de ters sıra çoğu zaman rakam dizisindeki kadar zorlamaz (bulgular karışık): şekil iki yönde de okunabilir. Bu yüzden bu oyunda ters dizi yalnızca bir blok kısadır.''',
      diagram: MiniGrid([
        '~1 . . *5',
        '. ~2 . .',
        '. . ~3 .',
        '*4 . . .',
      ], caption: 'Gösterim 1→2→3→4→5 · Tersten 5→4→3→2→1: aynı çizgi, öbür uçtan'),
    ),
    TutorialSection(
      'Karışık yön: iki uca da hazır ol',
      '''Karışık bölümlerde yönü gösterim bitene kadar bilemezsin. Bu yüzden diziyi tek yöne göre ezberlemek tehlikelidir: ileri bir sıra kurarsan ters çıktığında baştan çevirmen gerekir.

- Diziyi bir **şekil** olarak sakla, liste olarak değil. Şekil iki yönde de okunur: başından da sonundan da yürünür.
- Gösterim biterken **iki ucu** işaretle: ilk yanan blok ve son yanan blok. Yazı belirince parmağını doğru uca koy.
- Yazıyı oku, sonra dokun. Yazı belirdiği anda acele etme; süre sınırı yok. En sık hata, alışkanlıkla ileri başlamaktır.
- Uzunluk yönü ele vermez: dizinin kaç blok olacağı yöne değil, denemenin sırasına bağlıdır.

Bu, çalışma belleğindeki bilgiyi sonradan gelen bir kurala göre kullanmayı çalıştırır: bilgiyi tutmakla onu hangi yönde kullanacağını seçmek ayrı işlerdir.''',
    ),
    TutorialSection(
      'Tuzak flaşlarını filtrele',
      '''Bordo flaş, şekline girmeye çalışan bir yabancıdır. Her yanışta önce **rengi** kontrol et, sonra yeri.

- Bordo görünce içinden kısa bir "hayır" de ve şekli bir önceki altın bloktan devam ettir.
- En sinsi tuzak, dizide **zaten olan** ya da birazdan yanacak bir bloğa düşendir. Sıra numarası değil, renk karar verir.
- Tuzakla dolu bölümde şekli biraz daha **yavaş** kur; hızlı ama yanlış bir şekil, yavaş ve doğru bir şekilden kötüdür.

Bu, dikkatin "ilgisiz olanı dışarıda tutma" yanını çalıştırır (dikkat kontrolü).''',
    ),
    TutorialSection(
      'Kayan bloklar: nesneyi izle, yeri değil',
      '''Kayma bölümlerinde ezberlediğin **yer** bozulur; ama yanan **bloklar** aynı bloklardır. Kayma sırasında hedef blokları gözünle takip etmen gerekir.

- Gözünü tek bir bloğa kilitleme; hedeflerin **ortasına** bak ve hepsini çevresel görüşle izle.
- İnsan aynı anda yaklaşık 4 hareketli nesneyi güvenle izleyebilir (çoklu nesne takibi). Uzun dizide hedefleri 2–3'lük gruplara ayır, her grubu tek bir "küme" olarak izle.
- Şekli kaymadan sonra yeniden kur: bloklar az kaydığı için şekil genelde **gerilmiş** ama tanınır kalır.''',
    ),
    TutorialSection(
      'Ne çalışıyor, ne vaat etmiyor',
      '''Corsi blok testi (Corsi, 1972) görsel-mekânsal kısa süreli belleği ölçer ve nöropsikolojide yaygındır. Sağlıklı yetişkinlerde ileri açıklık çoğunlukla **5–7** arasındadır (Kessels ve ark., 2000).

Antrenmanla bu oyunda ve ona benzeyen işlerde gelişirsin (yakın aktarım). Çalışma belleği antrenmanının zekayı kalıcı artırdığına dair güçlü kanıt **yok** (Melby-Lervåg ve Hulme, 2013; Simons ve ark., 2016).

Öneri:
- Haftada bir kez **Uyarlanır** modu oyna ve puanını not et: bu senin ölçümün.
- Kısa, odaklı oturumlar (10 dakika) uzun ve yorgun oturumlardan iyidir.
- Uykusuzken puanının düştüğünü görürsen şaşırma: dikkat ve bellek önce orada bozulur.''',
    ),
  ],
);
