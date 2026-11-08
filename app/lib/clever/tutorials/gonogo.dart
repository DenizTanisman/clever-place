import '../tutorial.dart';

const gonogoTutorials = GameTutorials(
  rules: '''
- Ekranın ortasında bir **şekil** belirir: ya **yuvarlak** ya **köşeli** (kare).
- **Köşeli** gelirse **hiçbir şey yapma**: dokunma, kaydırma. Üstünde ok olsa bile. Elini çekmek burada doğru cevaptır.
- **Yuvarlak**, üstünde ok yoksa: ekranın herhangi bir yerine **dokun**.
- **Yuvarlak**, üstünde **zümrüt (yeşil) ok** varsa: parmağını **okun yönüne kaydır**.
- **Yuvarlak**, üstünde **bordo ok** varsa: parmağını **okun tersine kaydır** (ok yukarıysa aşağı, sola ise sağa).
- Oklu yuvarlakta düz dokunmak, oksuz yuvarlakta kaydırmak ve yanlış yöne kaydırmak **hatadır**. Süre dolarsa **kaçırdın** sayılır; ekranda şekil yokken dokunmak **erken** sayılır.
- Kurallar sırayla gelir: ilk bölümlerde yalnızca yuvarlak ve köşeli, sonra zümrüt oklar (önce sağ-sol, sonra dört yön), sonra bordo oklar. İleri bölümlerde köşelilerin üstüne de **tuzak ok** konur ve tempo hızlanır.
- Bir bölüm 20 uyaranla başlar, ileri bölümlerde 40'a çıkar. Puan **dengeli doğruluktur**: dokunma, kaydırma ve durma ayrı ayrı puanlanır, sonra ortalaması alınır.
- Yıldızlar: doğruluk %90 ve üstü, ortalama tepki de hedef sürenin altındaysa 3; %80 ve üstü 2; %70 ve üstü 1. %70 altında bölümü tekrar oynarsın.
- **Sonsuz akış**: bütün kurallar açık, 3 can, her hata bir can götürür. Doğru gittikçe akış hızlanır, hata yapınca biraz yavaşlar. Puan = doğru tepki sayısı.''',
  mid: [
    TutorialSection(
      'Adım adım: önce şekil, sonra ok',
      '''Her uyaranda kararı iki adımda ver. Sıra önemli:

- **1. Şekil**: köşeli mi? Köşeliyse iş bitti, elini çek. Ok rengine, yönüne bakmana bile gerek yok.
- **2. Ok**: yuvarlaksa üstünde ok var mı? Yoksa dokun. Varsa rengine bak.
- **3. Renk**: zümrüt "git" demektir: okla aynı yöne. Bordo "dön" demektir: tam tersine.

Bu sırayı içinden bir kez kur: "Köşeliyse dur. Yuvarlaksa: ok yoksa dokun, zümrütse aynı yön, bordoysa ters." Başlamadan önce kuralları böyle **eğer–ise** cümleleriyle söylemek kararı otomatiğe bağlamayı kolaylaştırır (Gollwitzer ve Sheeran, 2006).''',
    ),
    TutorialSection(
      'Dokunmak mı, kaydırmak mı?',
      '''Oyun parmağının hareketine bakar:

- **Dokunma**: parmağını koy ve kaldır, kaydırmadan.
- **Kaydırma**: parmağını koy ve bir yöne kısa, net bir çizgi çek. Kısa bir hareket yeter; oyun yönü parmağın en çok gittiği eksenden okur (yukarı, aşağı, sol, sağ).

Kaydırmaya şeklin üstünden başlaman gerekmez; ekranın her yeri çalışır. Parmağın ekrandayken süre biterse oyun hareketini bitirmen için kısa bir ek süre tanır.

Çapraz çizme: yarı yukarı yarı sağa giden bir çizgi yanlış yöne okunabilir. Düz ve kararlı çiz.''',
    ),
    TutorialSection(
      'Ritme kapılma',
      '''Uyaranların çoğu "tepki ver" dediği için el kendiliğinden basmaya başlar; nadir gelen köşeliye de basarsın. Aralar bilerek ±%30 oynatılır; ritmi tahmin edip önceden dokunmak "erken" sayılır.

Doğru yöntem **gör, tanı, yap** döngüsüdür: şekil belirince önce kimliğini tanı ("yuvarlak, bordo, yukarı"), sonra hareket et. Tanıma bir göz kırpmasından kısadır. Başlangıçta yavaş ve hatasız ol, hızı sonra artır.

Kararsız kaldığında elini çekmek en ucuz hatadır: köşeliye yapılan tek bir yanlış tepki, durma puanından büyük bir pay götürür.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Bordo ok: ters çevirmenin bedeli',
      '''Bordo ok, gözünün gördüğü yönün tersini istemek demektir. Beyin önce okun yönüne gitmeye hazırlanır; o hazırlığı durdurup ters yöne çevirmek zaman alır. Bu, psikolojide uyumsuzluk (Simon ve Stroop türü) etkisi olarak bilinir.

- Bordoyu görünce yönü değil **hedefi** düşün: "yukarı ok, bordo: aşağı."
- İlk bölümlerde bordo oklar sadece sağa ve sola bakar; dört yön sonra gelir. Önce sağ-sol ters çevirmeyi oturt.
- Zümrüt ve bordo karıştığında tepki süren biraz uzar; bu doğaldır. Hedef sürede kaydırma için zaten daha fazla pay vardır.''',
    ),
    TutorialSection(
      'Tuzak oklar ve kısa görünüm',
      '''İleri bölümlerde köşelilerin üstüne de ok konur. Ok, "kaydır" çağrısı yapan güçlü bir uyarandır; bu yüzden en sinsi tuzaktır.

- Kural sırası seni korur: **önce şekil**. Köşeliyi gördüğün an ok yokmuş gibi davran.
- 120. bölümden sonra şekil, tepki süresi bitmeden kaybolur. Şekli gördüğün anda kararını ver; kaybolduktan sonra hatırlamaya çalışmak yavaştır.
- Tempo arttıkça "önce şekil" adımını atlamak cazip gelir. Yanlış tepkilerin çoğu bu atlamadan doğar.''',
    ),
    TutorialSection(
      'Bilim ne diyor: ketleme antrenmanı neyi geliştirir?',
      '''Dur–geç (Go/No-Go) görevleri, otomatik bir tepkiyi durdurma becerisinin klasik ölçümüdür. Bu oyun buna kural seçimi ekler: hangi hareketi yapacağını uyaranın rengine göre değiştirirsin.

- Hızlı tempolu, nadir "dur" uyaranlı akışlar Robertson ve arkadaşlarının (1997) sürekli dikkat testine (SART) benzer. Yanlış tepkiler çoğu zaman dikkatin kaydığı anın işaretidir: fark et ve sonraki uyarana dön.
- **Pratikle bu görevde hızla ilerlersin** (yakın aktarım).
- **Uzak aktarım kanıtı zayıf.** Enge ve arkadaşları (2014), ketleme antrenmanının antrenmansız görevlere ve günlük öz denetime gerçek bir aktarım yaratmadığını buldu.

Yani bu oyun dikkat kontrolü için iyi bir pratik alanıdır; "irade kası" büyüten bir ilaç değildir. Uyku, bildirimleri kısmak ve eğer–ise planları hâlâ en güçlü kaldıraçlardır.''',
    ),
  ],
);
