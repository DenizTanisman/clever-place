import '../tutorial.dart';

const wordListTutorials = GameTutorials(
  rules: '''
- Somut kelimeler tek tek ekrana gelir. Liste bitince hatırladıklarını **klavyeyle yaz**: her kelimeden sonra **Tamam**, bitirince **Bitti**. Sıra önemli değil.
- Büyük-küçük harf ve Türkçe karakterler önemsiz (kopek = köpek). Başka yazım hatası kabul edilmez; listede olmayan kelime **araya giren** sayılır.
- Bölüm türleri döner: **serbest hatırlama**, **öğrenme eğrisi** (aynı liste 3 kez), **tanıma** (listede var mıydı?), **karışma** (araya B listesi girer), **gecikmeli** (60–90 sn işlem doğrulamadan sonra).
- 100. bölümden sonra bazı bölümler **sıralı**: kelimeleri gördüğün sırayla yazarsın, her kelime kendi sırasında sayılır.
- Liste 8 kelimeden 30 kelimeye uzar, hız kelime başı 2,5 saniyeden 0,8 saniyeye çıkar.
- Yıldızlar hatırlanan yüzdeye göre; tam eşikler başlangıç kartında yazar (ilk bölümde %60 / %75 / %90). 1 yıldız eşiğinin altı kaybettirir.
- Sonunda **sıra etkisi** grafiği, öğrenme eğrin, araya girenler ve kaçırdıkların gösterilir.''',
  mid: [
    TutorialSection(
      'Kategoriye göre kümele',
      '''Listeler kategorilerden kurulur (meyve, alet, kuş, mutfak…) ama kelimeler **bilerek karıştırılmış** gelir: yan yana iki kelime asla aynı kategoriden değildir.

- Kelimeyi görünce içinden kategorisini ekle: "elma → **meyve**", "keser → **alet**".
- Hatırlarken kategori kategori git: "Meyveler: elma, kiraz. Aletler: keser, mengene. Kuşlar…"
- Kaç kategori olduğunu bil: bir kategoride 2 kelime bulduysan, eksik olanı orada ara.

Düzenlemek serbest hatırlamayı belirgin biçimde artırır; sonuç ekranındaki **kümeleme** oranı bunu ne kadar yaptığını gösterir.''',
    ),
    TutorialSection(
      'Hikâye yöntemi',
      '''Kelimeleri sırayla **tek bir hikâyede** birbirine bağla:

"Bir **köpek** **gitar**ı ısırıyor, gitarın içinden **kiraz**lar dökülüyor, kirazlar **tava**da cızırdıyor…"

- Her yeni kelime bir öncekiyle **etkileşsin**: yan yana durmak yetmez, biri diğerine bir şey yapsın.
- Canlı, hareketli, tuhaf sahneler daha iyi tutar.
- Hatırlarken hikâyeyi baştan oynat; zincir seni bir sonraki kelimeye götürür.

Klasik bir deneyde (Bower ve Clark, 1969) kelimeleri hikâyeye bağlayanlar, on iki listeyi sonradan düz ezberleyenlerden kat kat iyi hatırladı. **Sıralı** bölümlerde bu yöntem çok güçlüdür.''',
    ),
    TutorialSection(
      'Sıra etkisi: baş ve son',
      '''Sonuç grafiğinde genellikle bir **U** görürsün:
- **Baş etkisi:** ilk kelimeler daha çok tekrar edildiği için uzun süreli belleğe geçer.
- **Son etkisi:** son kelimeler hâlâ çalışma belleğindedir ama birkaç saniyede silinir.
- **Orta** en zayıf bölgedir.

Taktik:
- Yazmaya **son kelimelerle** başla; onlar en çabuk kaybolur.
- Sonra baştan devam et, en son ortayı ara.
- Çalışırken orta bölümdeki kelimelere bilerek **daha canlı** imge ver.

Gecikmeli hatırlamada son etkisi kaybolur: o kelimeler hiç kalıcı kaydedilmediyse geri gelmez.''',
    ),
    TutorialSection(
      'Tekrar mı, anlamlandırma mı?',
      '''"Elma, elma, elma…" diye **ezber tekrarı** kelimeyi birkaç saniye akılda tutar ama kalıcı belleğe zayıf taşır. Kalıcılığı sağlayan **anlamlandırmadır**: kelimeye anlam, imge ve bağlantı vermek (işleme düzeyleri, Craik ve Lockhart, 1972).

- Her kelime için **bir imge** kur: "elma" → kırmızı, parlak, ısırılmış bir elma.
- İmgeyi bir öncekine ya da kategorisine **bağla**.
- Hızlı bölümlerde (1 saniyenin altı) her kelimeye tam sahne kuramazsın: tek bir anlık görüntü yeter, sonra zincirle.

Hızlı ve düz tekrar, hemen yazınca iyi görünür; gecikmeli testte gerçek fark ortaya çıkar.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Zihin sarayı (loci)',
      '''İyi bildiğin bir yolu (evin, yurt odan, kampüs rotası) **numaralı duraklara** böl: kapı, paspas, ayakkabılık, mutfak masası… Her kelimenin imgesini sırayla bir durağa bırak ve **durakla etkileştir**: "Kapıyı bir **köpek** açıyor, paspasın üstünde **gitar** çalıyor."

- Durakları önceden hazırla; 0,8 saniyede yeni durak düşünmeye vakit yok.
- 30 kelime için 30 durak, ya da 10 durağa üçer kelime.
- Sıralı bölümlerde saray neredeyse kusursuz sıra verir.

Kanıt güçlü: 6 hafta, günde 30 dakika çalışan kişiler 72 kelimelik listede yaklaşık **26'dan 62'ye** çıktı ve etki 4 ay sonra da sürdü (Dresler ve ark., 2017). Meta-analizlerde etki orta-büyük (g = 0,65; d = 0,88).''',
    ),
    TutorialSection(
      'Öğrenme eğrisi ve test etkisi',
      '''Öğrenme eğrisi bölümlerinde aynı liste üç kez gelir. Her hatırlama denemesi **kendisi bir öğrenmedir**: geri getirmek, tekrar okumaktan çok daha güçlüdür (test etkisi; Roediger ve Karpicke, 2006).

- 1. denemeden sonra **neyi kaçırdığını** fark et: hangi kategoriler eksikti?
- 2. denemede liste akarken kaçırdığın kelimelere **ekstra canlı** bir imge ver.
- 3. denemede önce kesin bildiklerini, sonra yeni eklediklerini yaz.

Sağlıklı bir eğri yükselir (örneğin 12 kelimede 6 → 9 → 11). Düz kalıyorsa her denemede aynı kelimeleri tekrar ediyorsun demektir; stratejiyi değiştir.''',
    ),
    TutorialSection(
      'Karışma ve tuzaklar',
      '''İki liste aynı kategorileri paylaşınca birbirine karışır: B listesini öğrenmek A'yı bozar (**geriye ket vurma**), A da B'yi bozar (**ileriye ket vurma**). İleri bölümlerde B listesi A'nın kategorilerini giderek daha çok paylaşır.

- A ve B'yi **farklı mekânlara** koy: A mutfakta, B bahçede geçsin.
- A'yı yeniden yazarken her kelimenin **hangi sahnede** olduğunu sor; bahçede gördüğün kelime B'dendir.

Tanıma bölümlerinde tuzaklar listedekilerle aynı kategoriden gelir. **"Tanıdık geliyor" ile "gördüm" aynı şey değildir**: bir kelimeye Evet demeden önce o kelime için kurduğun imgeyi hatırlamaya çalış. İmge yoksa dikkatli ol; benzer kelimelerin sahte anı üretmesi iyi bilinen bir etkidir.''',
    ),
    TutorialSection(
      'Gecikmeli hatırlama ve dürüst bilim',
      '''Gecikmeli bölümlerde araya 60–90 saniyelik işlem görevi girer; bu sürede kafanda tekrar edemezsin. Geriye ancak **gerçekten kodladığın** kelimeler kalır: imge ve bağlantıyla öğrendiklerin kalır, düz tekrar edilenler gider.

Bu oyun liste öğrenme becerisini ve strateji kullanımını geliştirir. Faydası en çok **benzer işlere** taşınır: alışveriş listesi, konuşma maddeleri, bir algoritmanın adımları. Genel zekayı artırdığına dair kanıt yok (Sala ve Gobet, 2017; Simons ve ark., 2016).

İlerlemeyi ölç: haftada bir aynı türden bir bölümü oyna ve yüzdeni not et. **Uyku** öğrendiklerini pekiştirir; uykusuz bir geceden sonra yeni bilgiyi kodlama belirgin biçimde düşer.''',
    ),
  ],
);
