import '../tutorial.dart';

const nbackTutorials = GameTutorials(
  rules: '''
- Kartta tek tek bir öğe belirir (rakam, ileride harf ya da iki basamaklı sayı); yarım saniye görünür, sonra kart boşalır.
- Gördüğün öğe **N adım önceki** öğeyle aynıysa kartın herhangi bir yerine dokun. "3-Back" = üç önceki. İlk N uyaranda eşleşme olamaz; oradaki dokunuşlar sayılmaz.
- **17 eşleşme** yakalayınca bölümü kazanırsın (temiz bir tur 2–2,5 dakika sürer). Yanlış dokunuş ve kaçırılan eşleşme birer **hata hakkı** götürür (sol alttaki ⊘); 3 hakkın var (ilk bölümlerde ve her yeni N'in ilk iki bölümünde 5), haklar bitince bölüm biter.
- Yıldızlar: hatasız **3**, tek hatayla **2**, daha fazla hatayla kazanırsan **1**. Göz simgesindeki "N geride" yardım şeridini açarsan en fazla 1 yıldız.
- Her bölümde **çeldiriciler** var: eşleşme olmayan öğelerin beşte biri (ileride üçte birine yakını) bilerek tanıdık gelecek şekilde seçilir: bir adım erken ya da geç tekrarlar ve "bundan sonra hep bu geliyordu" dizileri. Bir çeldiriciye dokunursan kartın altında hangisi olduğu yazar; sonuç ekranı kaç çeldiriciye takıldığını gösterir.
- Bölümler ilerledikçe N 1'den 9'a çıkar; harfler ve iki basamaklı sayılar gelir, tempo 2,5 sn'den 1,8 sn'ye iner, N büyüdükçe kullanılan öğe sayısı azalır (9'dan 6'ya), yani tekrarlar ve çeldiriciler sıklaşır. Her yeni N'in ilk iki bölümü rakamla ve 5 hakla başlar.
- **İkili N-Back (uyarlanır)**: 3×3 ızgarada bir hücre yanar, içinde bir rakam görünür; konum eşleşirse **Konum**, rakam eşleşirse **Rakam** düğmesine bas. 10 blok; %90 ve üstü N'i artırır, %75 altı azaltır. Puan = ortalama N × 100.''',
  mid: [
    TutorialSection(
      'Kayan pencere: son N\'i içinden söyle',
      '''Aklında her zaman tam **N öğelik bir liste** tut ve her yeni öğede aynı üç adımı yap:

- **Karşılaştır**: yeni öğeyi listenin en eskisiyle karşılaştır. Aynıysa dokun.
- **At**: en eski öğeyi listeden çıkar.
- **Ekle ve söyle**: yeniyi sona ekle, listeyi bir kez içinden söyle.

Örnek, 2-back, rakamlar 4 7 4 2 2 7:
- 4 → [4] · 7 → [4 7]
- 4 → en eski 4: **dokun** → [7 4]
- 2 → en eski 7: yok → [4 2]
- 2 → en eski 4: yok (bir önceki 2 ile aynı ama 2-back değil) → [2 2]
- 7 → en eski 2: yok → [2 7]

İlk N uyaranda eşleşme olmaz; o anları listeyi doldurmak için kullan. Kart altında "Diziyi doldur" yazdığı sürece dokunmana gerek yok.''',
      diagram: MiniGrid(['4 7 *4 2 !2 7'], caption: '2-back: 3. öğe eşleşme · 5. öğe yalnızca bir önceki tekrarı'),
    ),
    TutorialSection(
      'Ritim: her uyarana aynı döngü',
      '''Tempo sabittir: ilk bölümlerde 2,5 saniyede bir öğe, ileride 1,8 saniye. Bu ritmi kullan:

- **Öğe görünür görünmez** (ilk yarım saniye): oku, en eskiyle karşılaştır, gerekiyorsa hemen dokun. Kararı boşluğun sonuna bırakma; bekledikçe liste bulanıklaşır.
- **Boşlukta** (kalan süre): listeyi bir kez içinden söyle: "yedi, dört… yedi, dört".
- Dokunduysan bir sonraki öğeye kadar kartı unut; aynı öğede ikinci dokunuş zaten sayılmaz.

Her öğede aynı sırayı izlemek, dikkatin kaydığı anlarda bile seni oyunda tutar. Tempo hızlandıkça "söyle" adımı kısalır; bu yüzden etiketlerin kısa olmalı (sonraki bölüm).''',
    ),
    TutorialSection(
      'Etiketleme: her öğeye kısa bir ses',
      '''Çalışma belleği sözel öğeleri bir **iç ses döngüsünde** tekrar ederek tutar; döngüye ne kadar kısa sesler girerse o kadar çok öğe sığar.

- **Rakamlar** zaten kısadır: "dört, yedi, iki".
- **Harfler**: Türkçe adıyla söyle: "be, ke, ze". Harfler kafiyeli olduğu için (be-ce-de) birbirine karışabilir; içinden söylerken ünsüzü vurgula.
- **İki basamaklı sayılar** uzun seslerdir ("yetmiş yedi" dört hece) ve N büyüdükçe döngü taşar. Her sayıyı her seferinde **aynı biçimde** ve hızlı söyle, grupları küçük tut; döngü yetmezse son bir-iki sayının **görüntüsünü** (iki rakamın şekli) de gözünün önünde tut. Görsel ve sözel bellek kısmen ayrı kaynaklardır.
- **İkili modda konum**: hücrelere telefon tuş takımı gibi 1–9 numara ver; sol alt = "yedi".''',
      diagram: MiniGrid(['1 2 3', '4 5 6', '*7 8 9'], caption: 'İkili mod: konumu sayıya çevir · sol alt = 7'),
    ),
    TutorialSection(
      'Hata haklarını yönet',
      '''Kaçırılan eşleşme de yanlış dokunuş da **aynı bedeli** öder: bir hak. Buna göre karar ver:

- **Emin değilsen** kendine sor: "Eşleşme olma ihtimali yarıdan fazla mı?" Fazlaysa dokun, değilse dokunma. Hiç dokunmamak güvenli değildir: kaçırılan her eşleşme de hak götürür.
- **Tanıdık geliyor diye dokunma**; tanıdıklık "bunu yakında gördüm" demektir, "tam N önce gördüm" demek değildir.
- **Bir hakkın gittiyse** hızlanma ve hatayı düşünme; dikkat o an geriye bakar. Bir sonraki öğeyi her zamankinden daha dikkatli karşılaştır.
- **Listeyi kaybettiysen**: emin olduğun son öğelerden listeyi yeniden kur, eksik yuvaları gelen öğelerle doldur. Pencere dolana kadar yalnızca kesin eşleşmelere dokun.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Çeldiricilere direnmek (n−1 ve n+1)',
      '''Bazı öğeler **bir adım erken ya da geç** tekrar eder. Tanıdık gelirler ama eşleşme değildirler; dokunursan hak gider.

- 3-back, rakamlar 5 8 3 8: dördüncü 8 iki önceki 8 ile aynı (n−1), üç önceki ise 5. **Dokunma.**
- 3-back, rakamlar 5 8 3 1 5: beşinci 5 dört önceki 5 ile aynı (n+1), üç önceki ise 8. **Dokunma.**

Savunma: "Bunu az önce gördüm mü?" diye sorma. Bunun yerine **belirli bir yuvayı** sor: "Üç önce ne vardı?" Kayan pencere tam bunu yapar: yeni öğeyi yalnızca listenin en eskisiyle karşılaştırırsın. Çeldirici ihtimali olan bir öğede kararını listenin en eskisini **adıyla** söyleyerek ver.''',
      diagram: MiniGrid(['5 8 3 !8', '5 8 3 1 !5'], caption: 'Bordo: tanıdık ama 3-back eşleşmesi değil'),
    ),
    TutorialSection(
      'Sıra çeldiricisi: "bundan sonra hep bu geliyordu"',
      '''Beyin yalnızca öğeleri değil, **hangi öğeden sonra ne geldiğini** de kaydeder. Oyun bunu kullanır: az önce 4'ten sonra 7 geldiyse, 4 yeniden göründüğünde ardından yine 7 gelir; ama bu kez 7 doğru uzaklıkta değildir.

- 2-back, rakamlar 4 7 1 2 4 **7**: son 7, "4'ten sonra 7" ikilisini tekrarlıyor. İki önce ise 2 var. **Dokunma.**
- Tuzak, ikiliyi tanıman: "bu sırayı biliyorum" hissi "eşleşme" gibi gelir. Oysa soru hep aynıdır: **N önce ne vardı?**
- Savunma: listeyi ikililer olarak değil, **yuvalar** olarak tut. "4'ten sonra ne gelir?" diye tahmin yürütme; her yeni öğede yalnızca en eski yuvaya bak.
- N küçükken bu tuzak daha sinsidir: 1-back'te "4 7 … 4 7" ikinci 7'de bir önceki 4'tür, eşleşme yoktur.''',
      diagram: MiniGrid(['*4 *7 1 2 *4 !7'], caption: 'Altın: ilk "4 7" ikilisi · bordo: sırayı tekrarlayan çeldirici'),
    ),
    TutorialSection(
      'Yüksek N: gruplama',
      '''N 4 ve üstüne çıkınca öğeleri tek tek tutmak zorlaşır. **Gruplama** (chunking) dene:

- 4-back'te listeyi iki ikili grup olarak söyle: "yedi beş · iki dokuz". Yeni öğe ilk grubun ilk öğesiyle karşılaştırılır, sonra liste bir öğe kayar.
- 6-back'te üçlü gruplar: "yedi beş iki · dokuz bir dört". Her grubun ilk öğesine hafif vurgu yap; ritim, grubu tek parça gibi taşır.
- 8–9-back'te pencere dört ya da üç gruba bölünür. Kayma sırasında grup sınırları her öğede bir kayar; bunu bir "yürüyen tren" gibi düşün: önden bir vagon gider, arkaya bir vagon eklenir.

Gruplama, sözel döngünün kapasitesini artırmaz; aynı kapasiteye **daha düzenli** bilgi koyar. İki basamaklı sayılarda gruplar bir öğe küçük tutulmalı.''',
    ),
    TutorialSection(
      'N\'i nasıl yükseltirsin',
      '''N'deki her artış, bir önceki N'den belirgin şekilde zordur. Basamakları sağlam çık:

- **Kural**: bir N'de iki kez arka arkaya 3 yıldız alamıyorsan bir üst N'e geçme; aynı N'in harfli, sayılı ve hızlı bölümleri tam bu pratik içindir.
- Her yeni N'in ilk iki bölümü rakamla, sakin tempoda ve 3 hakla gelir: yeni pencereyi orada kur.
- **Uyarlanır ikili mod** seviyeni ölçer: N her blokta seni zorlayan ama boğmayan yere yerleşir. Ortalama N'in haftadan haftaya yükseliyorsa ilerliyorsun.
- Günde 15–20 dakika, yorgun değilken çalış. Aynı süreyi günlere yaymak, tek seferde yığmaktan daha iyi sonuç verir; yorgunken oynanan bölümler seviyeni olduğundan düşük gösterir.
- İkili modda puan **dengeli doğruluktur**: (yakalanan eşleşme oranı + doğru pas oranı) ÷ 2; hiç basmamak da hep basmak da %50 eder.''',
    ),
    TutorialSection(
      'Bilim ne diyor: n-back neyi geliştirir?',
      '''Açık konuşalım: n-back **zekâ (IQ) artırıcı değildir**.

- 2008'de Jaeggi ve arkadaşları, ikili n-back antrenmanının akıcı zekâyı artırdığını öne sürdü. Sonraki geniş meta-analizler bunu doğrulamadı.
- **Melby-Lervåg ve Hulme** (2013; Redick ile 2016): çalışma belleği antrenmanı çalışılan göreve ve ona çok benzeyen görevlere aktarılıyor (yakın aktarım), ama zekâ, okuma ya da aritmetik gibi uzak becerilere güvenilir bir aktarım yok.
- **Sala ve Gobet** (2017–2020), **Simons ve arkadaşları** (2016): aktif kontrol gruplarıyla karşılaştırınca uzak aktarım sıfıra yakın.
- **Soveri ve arkadaşları** (2017), yalnızca n-back çalışmalarının meta-analizi: antrenmansız n-back görevlerine orta, diğer çalışma belleği görevlerine küçük, akıcı zekâya ihmal edilebilir aktarım.

Peki ne işe yarar? N-back iyi bir **çalışma belleği güncelleme ve dikkat kontrolü pratiğidir**: odağı sürdürmeyi, bilgiyi her saniye yenilemeyi ve tanıdıklık tuzaklarına direnmeyi çalıştırır; bu görevde gerçekten hızla gelişirsin. Gerçek hayatta bir beceride (zihinden hesap, yabancı dil, müzik) gelişmek istiyorsan en etkili yol o beceriyi doğrudan çalışmaktır.''',
    ),
  ],
);
