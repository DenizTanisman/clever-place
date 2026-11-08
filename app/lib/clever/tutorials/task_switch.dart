import '../tutorial.dart';

const taskSwitchTutorials = GameTutorials(
  rules: '''
- Ekranda bir rakam (ileride rakam + harf) çıkar. O anki **kural** sola mı sağa mı basacağını söyler.
- Kurallar: **Tek mi, çift mi?** · **5'ten küçük mü, büyük mü?** · **Sesli mi, sessiz mi?** · **Harf küçük mü, büyük mü?** Düğmelerde her kuralın sol ve sağ anlamı yazar.
- Kuralı **ipucu** söyler: hedefin çıktığı bölge ya da hedeften hemen önce çerçevenin aldığı renk. İpuçsuz bölümlerde kurallar ikişer ikişer sırayla gelir (AABB): sırayı sen takip edersin.
- Her bölüm 32 deneme. Süre içinde basmazsan o deneme de hata sayılır.
- **Geçiş maliyeti** = kural değiştiğinde ortalama tepki süren eksi kural aynı kaldığında ortalama tepki süren. Sonuçta görürsün.
- Yıldızlar: %90 doğruluk ve geçiş maliyeti en çok 200 ms (ipuçsuzda 250 ms) → 3; %82 → 2; %75 → 1; %75'in altı kaybettirir.
- Sprint: 60 saniye, puan = doğru − hata. Her 8 doğruda yeni kural ya da daha kısa hazırlık süresi gelir.''',
  mid: [
    TutorialSection(
      'Geçiş maliyeti: beynin vites değiştirmesi',
      '''Kural değişen denemelerde herkes yavaşlar ve daha çok hata yapar. Buna **geçiş maliyeti** denir (Rogers ve Monsell, 1995). Tipik değer 100–300 ms.

Sebebi, beynin her kural için ayrı bir "görev ayarı" tutması: hangi özelliğe bakacağın (rakamın tekliği mi, büyüklüğü mü) ve hangi cevabın hangi düğme olduğu. Kural değişince bu ayar yeniden kurulur, eskisinin izi de bir süre karışmaya devam eder.

Hedef sıfır değil, **küçük ve istikrarlı** bir maliyet. Sonuç kartındaki "Tekrar" ve "Geçiş" sürelerini karşılaştır: hangisi seni yavaşlatıyor, onu gör.''',
      diagram: MiniGrid(['1 2 3 4 5 6', '~TÇ ~TÇ *KB ~KB ~KB *TÇ'],
          cell: 42, caption: 'Altın: kural değişti (geçiş) · soluk: aynı kural (tekrar)'),
    ),
    TutorialSection(
      'İpucunda hazırlan, hedefi bekleme',
      '''Bölge ışıdığı ya da çerçeve renk aldığı an hedef henüz yoktur. Bu kısa aralık senin hazırlık zamanın.

- İpucu gelir gelmez kuralı içinden söyle: "tek-çift".
- İki başparmağını düğmelerin üstünde hazır tut.
- Rakam çıktığında artık "hangi kural?" diye düşünmemelisin, sadece özelliğe bakmalısın.

Araştırmalar hazırlık süresi uzadıkça geçiş maliyetinin belirgin biçimde düştüğünü gösteriyor (Meiran, 1996). Bu süreyi pasif beklersen kaybedersin; aktif kullanırsan maliyetin ciddi kısmı hedef gelmeden ödenir. Üst bölümlerde bu süre 100 ms'ye iner: o zaman hazırlığın refleks olmuş olmalı.''',
    ),
    TutorialSection(
      'Kısa sözlü etiketler',
      '''Kuralı içinden tek kelimeyle söylemek işe yarar. İç sesini meşgul eden deneylerde (aynı anda anlamsız bir kelimeyi tekrarlatarak) geçiş maliyeti büyüdü: iç konuşma, görev ayarını tutmanın bir parçası (Emerson ve Miyake, 2003).

Her kural için bir etiket seç ve hep onu kullan:
- **"tek"** → Tek mi, çift mi?
- **"beş"** → 5'ten küçük mü, büyük mü?
- **"ses"** → Sesli mi, sessiz mi?
- **"boy"** → Harf küçük mü, büyük mü?

Kısa olsun: uzun cümle kurarsan hazırlık süresini yer.''',
    ),
    TutorialSection(
      'Tek eşleme kuralı: sol = ilk kelime',
      '''Dört kuralı ayrı ayrı ezberleme. Hepsinde **sol düğme sorunun ilk kelimesi**:

- Tek mi, çift mi? → sol **Tek**
- 5'ten küçük mü, büyük mü? → sol **Küçük**
- Sesli mi, sessiz mi? → sol **Sesli**
- Harf küçük mü, büyük mü? → sol **küçük harf**

Yani soruyu içinden sorduğunda cevabın "ilk kelime" ise sol, değilse sağ. Bu, dört eşlemeyi tek bir kurala indirir ve hafızanı kuralın kendisine ayırır.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Uyumsuz uyaranlar: önce kural, sonra özellik',
      '''7'ye bak: tek kuralında **sol** (Tek), büyüklük kuralında **sağ** (Büyük). Bu tür uyaranlara **uyumsuz** denir; diğer kuralın cevabı da kafanda hazırdır ve seninkiyle yarışır. Hataların çoğu burada çıkar.

3 ise iki kuralda da **sol**: tek ve 5'ten küçük. Bu **uyumlu** bir uyaran; hangi kuralı uygularsan uygula cevap aynı, bu yüzden kolay gelir. Tehlike de burada: birkaç uyumlu denemeden sonra kuralı kontrol etmeyi bırakırsın ve ilk uyumsuz rakamda yanılırsın.

Teknik: rakam çıkınca önce kuralı hatırla, **sonra** sadece o kuralın özelliğine bak. Rakam sana bir cevap fısıldıyorsa onu dinleme. Uyumsuz denemede 50 ms yavaşlamak, yanlış basmaktan iyidir.''',
    ),
    TutorialSection(
      'İpuçsuz sıra: AABB ritmi',
      '''İpuçsuz bölümlerde kurallar ikişer ikişer döner: A A B B (üç kuralda A A B B C C). Ekranda hiçbir yardım yok; sırayı **çalışma belleğin** tutar.

- Ritim tut: "bir, iki, değiş". Her çiftin **ilk** denemesi geçiş, **ikinci** denemesi tekrardır.
- Geçiş denemesinde kuralı önceden söyle, tekrar denemesinde aynı ayarda kal.
- Hata yaptığında geri bildirim o denemenin kuralını yazar: hemen yeniden hizalan. Sırayı kaybettiysen "bu kural ikinci miydi?" diye düşün.

Bu düzen, kuralların tahmin edilebildiği hâlde bile geçiş maliyeti ölçen klasik "dönüşümlü diziler" yönteminden gelir (Rogers ve Monsell, 1995): hazırlık maliyeti azaltır ama tamamen yok etmez.''',
    ),
    TutorialSection(
      'Kalıntı maliyet ve geri dönüş yavaşlığı',
      '''Hazırlık süresi ne kadar uzun olursa olsun bir miktar **kalıntı maliyet** hep kalır: görev ayarının bir kısmı ancak hedef gelince kurulabiliyor. Üst bölümlerde bu payı kabul et; amacın doğruluğu korumak.

Üç-dört kurallı bölümlerde bir tuhaflık daha var: A → B → A dizisinde A'ya dönüş, C → B → A'dakinden yavaştır. Az önce bıraktığın kural "bastırılmış" olarak kalır (geri dönüş baskılaması; Mayr ve Keele, 2000).

Pratik sonuç: yeni bıraktığın kurala dönerken ekstra yavaşladığını hissedersen bu normal. Panik yapma, kuralı içinden net söyle ve devam et.''',
    ),
    TutorialSection(
      'Ne gelişir, ne gelişmez',
      '''Dürüst tablo: görev değiştirme antrenmanı **çalıştığın görevde** geçiş maliyetini düşürür, benzer geçiş görevlerine kısmen taşınır (Karbach ve Kray, 2009). Genel zekayı ya da her işteki dikkati büyüttüğüne dair kanıt zayıf (Sala ve Gobet, 2017).

Bu oyunun gerçek hayattaki dersi şu: geçişin her zaman bir bedeli var. Bir işten ötekine atlamak dakikalar boyunca "dikkat kalıntısı" bırakır (Leroy, 2009).

- İşleri grupla: benzer işleri art arda yap.
- Bir işi bırakmak zorundaysan bir cümleyle "nerede kaldım, sonra ne yapacağım" yaz.
- Kesinti geldiğinde, buradaki gibi: önce kuralı (yeni işin amacını) söyle, sonra başla.''',
    ),
  ],
);
