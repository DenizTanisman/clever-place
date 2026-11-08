import '../tutorial.dart';

const verbalSocialTutorials = GameTutorials(
  rules: '''
- **450 özgün soru**, üç bölümde: **Sözel** (kelimeler ve akıl yürütme), **Sosyal** (insanları okumak) ve **Duygusal** (duyguları anlamak ve yönetmek).
- Her bölümde **10 soru** var. Bölümler sırayla gelir (Sözel, Sosyal, Duygusal…) ve aynı tür soru art arda gelmez.
- İlk 22 bölüm **orta**, 23–45 arası **zor** sorulardan oluşur.
- Her cevaptan sonra **Neden?** kutusu doğru cevabın gerekçesini ve en çekici yanlışın neden yanlış olduğunu anlatır. Süre yok: oku, düşün, sonra **Devam** de.
- Yıldızlar: 9–10 doğru **3**, 8 doğru **2**, 7 doğru **1** yıldız. 7'nin altında bölüm geçilmez; tekrar oynarsan **aynı sorular** gelir.
- **Karışık** modu bütün sorulardan rastgele seçer: doğru cevaplar seriyi uzatır, üçüncü yanlışta oyun biter.
- Bu oyun bir IQ ya da EQ testi değildir ve puan vermez. Amaç, düşünme ve insan okuma alışkanlığı kazanmak.''',
  mid: [
    TutorialSection(
      'Sözel: önce ilişkiyi adlandır',
      '''Analojide seçeneklere bakmadan önce ilk ikilinin ilişkisini **tek cümleyle** söyle: "Termometre sıcaklığı **ölçer**." Sonra aynı cümleyi seçeneklere uygula: "Barometre … ölçer."

Yanlış seçenekler çoğu zaman **aynı konudan** gelir ama ilişkiyi taşımaz. "Taslak : metin" ikilisinde "kopya : orijinal" de bir sürüm ilişkisidir, ama yön terstir.

Ölçüt sorularında (farklı olan) bir ayrım bulunca durma: harf sayısı, kök, olumlu/olumsuz anlam gibi **başka bir 3'e 1 bölünme** var mı, diye kontrol et. Sorular tek bir anlam ölçütüyle kurulmuştur.''',
    ),
    TutorialSection(
      'Sözel: bağlaç, deyim, paragraf',
      '''- **Bağlaç**: boşluktan önceki ve sonraki cümlenin ilişkisini bul: karşıtlık mı (ama, oysa), neden mi (çünkü), ekleme mi (üstelik), koşul mu (yeter ki)?
- **Deyim ve atasözü**: sözü bağlamın içinde oku. Kelimesi kelimesine okuma çoğu zaman tuzaktır.
- **Paragraf**: "kesin olarak çıkarılabilir" sorusunda yalnızca parçanın söylediğine güven. "Her zaman", "hiçbir" gibi genellemeler ve neden–sonuç ters çevirmeleri tipik çeldiricilerdir.
- **Cümle sıralama**: "Bu", "Bu yüzden", "Ancak" ile başlayan cümle ilk olamaz. Önce açılış cümlesini, sonra zamir ve bağlaç zincirini bul.''',
    ),
    TutorialSection(
      'Sosyal: herkesin bildiğini ayrı tut',
      '''Sosyal soruların çoğu bir **bilgi farkı** üzerine kuruludur: kim neyi gördü, kim neyi kaçırdı?

Hikâyeyi okurken her kişi için küçük bir not tut: "Efe mesajı yazdı. Aslı **açmadı**. Efe bunu **bilmiyor**." Soru "Efe ne düşünüyor?" diyorsa senin bildiğini değil, **Efe'nin bildiğini** kullan.

Bu format, Francesca Happé'nin 1994'te geliştirdiği **Garip Hikâyeler (Strange Stories)** testinden gelir: insanların neden kelimenin tam anlamıyla doğru olmayan şeyler söylediğini (beyaz yalan, şaka, ikna, yanlış anlama) anlamayı ölçer. Buradaki hikâyelerin hepsi yeni yazıldı; testten yalnızca biçim alındı.''',
    ),
    TutorialSection(
      'Sosyal: pot ve dolaylı söz',
      '''**Pot kırma** soruları Baron-Cohen ve arkadaşlarının (1999) **Faux Pas** testinden esinlenir. Birinin, bilmeden, karşısındakini kıracak bir şey söylediği anı yakalamak gerekir. Dört soru sor:

- Kim söyledi?
- Neyi bilmiyordu?
- Söz neden incitti?
- Karşıdaki ne hissetti?

Pot kasıtlı değildir. Bilerek söylenen kırıcı söz pot değil, kabalıktır.

**Dolaylı anlatım**: "Burası biraz soğuk değil mi?" çoğu zaman bir ricadır. "Bakarız" çoğu zaman kibar bir hayırdır. "Sen bilirsin" çoğu zaman onaylamamaktır. Sözün yanında **bağlamı, tonu ve tekrarı** oku.''',
    ),
    TutorialSection(
      'Duygusal: duyguyu durumdan oku',
      '''Duyguyu anlama soruları MacCann ve Roberts'ın (2008) **STEU** testinin biçimini kullanır. Bu biçim, duyguları **değerlendirme kuramına** göre çözer. Duygu, olayın kendisinden çok onu nasıl yorumladığımızdan doğar:

- Haksızlığı biri yaptıysa **öfke**.
- Önemli bir şey geri gelmeyecek biçimde kaybolduysa **üzüntü**.
- Belirsiz bir tehdit yaklaşıyorsa **kaygı**.
- Belirli bir davranışından rahatsızsan **suçluluk**.
- Bütün benliğin küçülmüş gibiyse **utanç**.
- İki seçenek arasında yanlış olanı seçtiysen **pişmanlık** ("keşke").

Önce "**Kim yaptı? Kontrol kimde? Düzelir mi?**" diye sor, sonra seçeneklere bak.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Duygu yönetimi: "en etkili" ne demek?',
      '''Duygu yönetimi soruları **STEM** testinin (MacCann ve Roberts, 2008) biçimini izler. Doğru seçenek, duygusal zekâ araştırmalarındaki **uzman görüşüne** göre en etkili davranıştır. Bu sorularda uygulama bunu ayrıca hatırlatır.

Araştırmaların genel çizgisi:
- Sorun kontrol edilebiliyorsa **sakin ve soruna yönelik adım** at.
- Durumu **yeniden değerlendir**.
- **Destek iste**.
- Karşındakinin duygusunu **önce kabul et**, çözümü sonra öner.

Daha az etkili olanlar: **bastırmak**, önemli bir sorundan **kaçmak**, aynı düşünceyi **evirip çevirmek** (ruminasyon), öfkeyle boşalmak, "abartma, geçer" diye geçiştirmek.

Bunlar mutlak doğrular değil, **ortalama** durum için geçerli eğilimlerdir. Gerçek hayatta bağlam her zaman önemlidir.''',
    ),
    TutorialSection(
      'Duygu sözcükleri: ince farklar',
      '''Türkçe duygu sözcükleri yakın anlamlıdır ama aynı değildir:

- **Hayal kırıklığı** beklentinin boşa çıkmasıdır. **Kırgınlık**, yakın birinin davranışının içte bıraktığı yaradır. **Küskünlük** bu yaranın konuşmamaya dönüşmesidir.
- **Mahcubiyet** daha hafiftir; birinin önünde mahcup olunur. **Utanç**, benliğin bütününe yönelir.
- **Gıpta** kötü niyetsiz imrenmedir. **Haset** ise başkasının elindekini kaybetmesini istemektir.

İnce farkı yakalamak için kendine sor: duygu **kime** yöneliyor? **Davranışa mı**, **kişiye mi**? İçte mi kalıyor, **dışa mı** vuruyor?''',
    ),
    TutorialSection(
      'Duygu düzenleme stratejileri',
      '''James Gross'un **süreç modeli**, duyguyu farklı anlarda düzenleyebileceğimizi söyler:

- **Durum seçimi**: o ortama hiç girmemek.
- **Durumu değiştirmek**: ortamı düzenlemek.
- **Dikkati yönlendirmek**: başka şeye odaklanmak.
- **Yeniden değerlendirme**: olaya başka bir anlam vermek.
- **Tepkiyi bastırmak**: duyguyu yüzüne yansıtmamak.

Araştırmaların bulguları şöyle:
- Alışkanlık hâline gelmiş bastırma, yeniden değerlendirmeden daha maliyetlidir.
- **Ruminasyon** olumsuz duyguyu uzatır.
- Duyguya **ad koymak** onun şiddetini azaltır.
- Çok yoğun bir anda dikkati dağıtmak kısa vadede işe yarar.

Soruda önce davranışın **hangi anda** yapıldığını bul: olaydan önce mi, sırasında mı, sonra mı?''',
    ),
    TutorialSection(
      'Sosyal: ton ve sohbet',
      '''**Ton** sorularında hitap tek başına belirleyici değildir. Hoca "bana Onur Hoca de" dediyse, sorun hitapta değil, başka bir sınırın aşılmasındadır: argo, "sen" dili, ciddi bir işi geçiştirmek. Bağlamın **ne kadar samimiyete izin verdiğini** tart.

**Sohbet** sorularında iyi bir takip sorusu üç şey yapar:
- karşındakinin **söylediğine dayanır**;
- **açık uçludur**;
- konuyu **sana çevirmez**.

Karşındaki gitmek istiyorsa genelde işaret verir: kısa cevaplar, saate bakmak, "Neyse…". Bu işaretleri görünce sözü sıcak bir kapanışa bağla.''',
    ),
    TutorialSection(
      'Bu cevaplar neye dayanıyor?',
      '''Sözel soruların cevabı **mantıkla** kanıtlanabilir. Sosyal ve duygusal soruların cevabı ise **araştırma uzlaşısına** ve dikkatli yetişkinlerin büyük çoğunluğunun vereceği yanıta dayanır; mutlak doğru değildir.

Her soru elle yazıldı. Ardından iki denetimden geçti:
- Her yanlış seçenek için "en iyi savunma" yazıldı. Savunması doğru cevap kadar güçlü olan sorular yeniden yazıldı.
- Sorular, cevap anahtarı gizlenerek baştan çözüldü.

Yine de bir cevaba katılmıyorsan, gerekçeni **Neden?** kutusundaki açıklamayla karşılaştır. Çoğu zaman fark, hikâyedeki küçük bir ipucundadır.''',
    ),
  ],
);
