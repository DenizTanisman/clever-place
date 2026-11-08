import '../tutorial.dart';

const stroopTutorials = GameTutorials(
  rules: '''
- Ekranda bir kelime belirir; çoğu zaman bir renk adıdır ama **başka bir renkle** yazılmıştır. Kelimeyi değil, yazının **mürekkep rengini** seç: alttaki renk düğmesine dokun.
- Düğmelerde yazı yok, yalnızca renk var. İleri bölümlerde düğmelerin sırası değişir, kelime ekranda gezer; renk adı olmayan tuzak kelimeler de gelir.
- **Kural değişimi** bölümlerinde işarete bak: **RENK** → mürekkebin rengi, **KELİME** → kelimenin anlattığı renk.
- Her kelimenin bir süresi var (alttaki ince çizgi). Geç kalmak hata sayılır.
- Yıldızlar: %95 doğruluk ve hedef ortalama tepkinin altı 3, %85 ve hedefin 1,25 katı 2, bitirirsen 1 yıldız. Doğruluk %70'in altına düşerse ya da kelimelerin beşte birinden fazlasında süre dolarsa bölüm biter.
- **Sprint**: 60 saniye; doğru +1, hata −1. Puan arttıkça renkler, tuzaklar ve hız artar.
- Sonuçta **Stroop etkisi** görünür: uyumsuz kelimelerdeki ortalama tepkinden uyumlu kelimelerdekini çıkar. Ne kadar küçükse, okumayı o kadar iyi bastırıyorsun.''',
  mid: [
    TutorialSection(
      'Rengi gör, kelimeyi bulanıklaştır',
      '''Okumak senin için otomatiktir: kelimeyi görmemek elinde değil. Ama kelimenin **cevabı ele geçirmesini** zayıflatabilirsin.

- Gözünü kelimenin ortasına değil, bir harfin **içine** ya da alt kenarına koy. Harfin rengini gör, şeklini değil.
- Bakışını hafifçe gevşet; harfler biraz bulanıklaşsın. Renk bulanıklığa dayanır, okuma dayanmaz.
- Kelime belirmeden önce kendine görevi hatırlat: "renk". Fiksasyon artısı (+) bunun için bir nefeslik zaman verir.

Bu hileler okumayı kapatmaz; renk bilgisine bir adım önde başlamanı sağlar.''',
    ),
    TutorialSection(
      'İçinden adlandır, sonra bırak',
      '''Klasik Stroop testinde renk yüksek sesle söylenir. Düğmeli sürümde de **içinden söylemek** dikkati renge kilitler:

- Kısa adlar kullan: "kır", "ma", "ye", "sa", "mo", "tu". Tek hece, tam kelimeden hızlıdır.
- İlk bölümlerde her kelimede içinden adlandır; böylece kelimenin sesi değil, rengin sesi kafanda yankılanır.
- Hızlandıkça adlandırmayı bırak: renk → düğme bağı kurulunca söylemek bir yavaşlatıcıya dönüşür.

Kural: hata çoksa adlandırmaya geri dön, hatasızsan bırak ve hızlan.''',
    ),
    TutorialSection(
      'Renk → başparmak haritası',
      '''Düğmeler sabitken her rengin bir **yeri** olsun. Üç renkte sol–orta–sağ, altı renkte iki sıra üçlü:

- İlk birkaç kelimede rengi değil, **konumu** düşünmeye başla: "mavi = orta". Karar artık "hangi renk?" değil, "hangi parmak?" olur.
- Bölümde tek sefer karışan sıralarda geri sayım boyunca düğmelere bak ve haritayı yeniden kur.
- Her kelimede karışan sıralarda harita işe yaramaz: önce mürekkebi belirle, **sonra** o rengi düğmelerde ara. Asla kelimenin söylediği rengi arama; tuzak tam oradadır.''',
    ),
    TutorialSection(
      'Hız–doğruluk dengesi',
      '''Üç yıldız iki şey ister: en fazla %5 hata ve hedefin altında **ortalama** tepki (yalnızca doğru cevaplar sayılır).

- 24 kelimede %95, en fazla **bir** hata demektir. Bir hata, 50 ms'lik bir hızlanmadan çok daha pahalıdır.
- Temponu bul: iki üç bölümde hiç hata yapmıyorsan biraz hızlan; iki hatan oluyorsa 50–100 ms yavaşla.
- Hatadan sonra yavaşlamak doğaldır (hata sonrası yavaşlama). Aşırıya kaçma: bir sonraki kelimeyi normal temponla karşıla.
- Süre çizgisi kısalınca panikle basma; geç kalmak da, yanlış basmak da bir hata. Gerçekten bilmiyorsan en olası rengi seç.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Kural değişimi: işareti önceden oku',
      '''İşaret (RENK / KELİME), kelimeden önce, artı (+) göründüğü anda gelir. Bu boşluk senin **hazırlık** zamanın:

- Artıyı gördüğün an işarete bak ve kuralı içinden söyle: "renk" ya da "kelime". Kelime geldiğinde artık seçmen gerekmez, yalnızca uygularsın.
- Kural değişince ilk cevap yavaşlar: buna **geçiş bedeli** denir ve sonuçta ayrıca gösterilir. Hazırlık bu bedeli küçültür ama sıfırlamaz.
- KELİME kuralında mürekkep tuzak olur; ama okuma güçlü olduğu için bu yön genelde kolaydır.
- Şaşırtıcı bulgu: güçlü göreve (okumaya) geçmek bazen daha pahalıdır, çünkü bir önceki kelimede okumayı bastırıyordun (Allport ve arkadaşları, 1994). RENK'ten KELİME'ye geçişte acele etme.''',
    ),
    TutorialSection(
      'Çağrışım ve duygu kelimeleri',
      '''Renk adı olmayan kelimeler de tuzak kurabilir:

- **Çağrışım**: LİMON sarıyı, DENİZ maviyi uyandırır. Etkisi gerçek renk adından küçüktür ama ölçülebilir; bu kelimeler hep başka bir mürekkeple yazılır.
- **Duygu**: KORKU, PANİK gibi kelimeler dikkati bir an kendine çeker. Çoğu insanda bu etki küçüktür; kaygılı ya da yorgun günlerde büyür.
- **Nötr** kelimeler (MASA, KAPI) ölçü çizgisidir: uyumsuz bir renk adı ile nötr kelime arasındaki fark, okumanın sana ne kadar "bastırdığını" gösterir.

Strateji hepsinde aynı: her kelimeyi anlamı olmayan bir **renkli şekil** gibi gör.''',
    ),
    TutorialSection(
      'Gezgin kelime ve karışan düğmeler',
      '''Kelime yer değiştirdiğinde gözünü onun peşinden koşturma:

- Bakışını sahnenin ortasında tut. Renk, çevre görüşünde de çok hızlı fark edilir; okumak ise kelimeye bakmayı gerektirir. Yani uzaktaki kelime aslında **senin lehine**: okumadan önce rengi yakalarsın.
- Boyut değişimi bir dikkat dağıtıcıdır: iri kelime "daha önemli" değildir.
- Düğmeler her kelimede karışıyorsa iki adımı ayır: (1) mürekkebi belirle, (2) düğmelerde o rengi bul. İkinci adımda kelimeyi tekrar okumamak için bakışını düğmelere indir ve oradan kaldırma, sonraki artı belirene kadar.''',
    ),
    TutorialSection(
      'Ne ölçüyor, ne kazandırır? Dürüst bilim',
      '''Stroop etkisi (1935) psikolojinin en çok tekrarlanan bulgularından biridir: otomatik bir tepkiyi (okumayı) bastırıp asıl göreve (renge) yönelme becerisini, yani **ketleme** ve dikkat kontrolünü ölçer.

Ne beklemelisin:
- Antrenmanla bu görevdeki Stroop etkin küçülür ve hızlanırsın. Bu gerçek bir kazançtır ama büyük ölçüde **bu göreve özgüdür**.
- Günlük öz denetime, zekaya ya da başka işlere güçlü aktarım kanıtı yoktur.

Asıl değeri ölçüm aracı olmasıdır: Stroop etkin uykusuzluk ve yorgunlukla büyür. Haftalarca aynı saatte bir Sprint oynayıp puanını ve etkini not edersen, dikkat düzeyini izleyen ucuz bir göstergen olur.''',
    ),
  ],
);
