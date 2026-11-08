import '../tutorial.dart';

const digitSpanTutorials = GameTutorials(
  rules: '''
- Rakamlar ekranda tek tek belirir: ilk bölümlerde saniyede bir, ileride daha hızlı. Dizi bitince klavyeden yaz ve **Tamam**'a bas.
- **İleri:** gördüğün sırayla. **Geri:** sondan başa. **Sıralı:** küçükten büyüğe. **Harf-rakam:** önce rakamlar küçükten büyüğe, sonra harfler alfabe sırasıyla.
- İleri bölümlerde dizi ile cevap arasına bir **işlem sorusu** girer (doğru mu, yanlış mı?). Cevapla ama diziyi bırakma.
- Bir bölüm 5 denemedir. Yıldızlar: 5/5 → 3, 4/5 → 2, 3/5 → 1; daha azı başarısız. Ara görevde hata yaparsan en fazla 2 yıldız.
- Uyarlanır mod kapasiteni ölçer: üst üste iki doğru diziyi bir uzatır, bir yanlış bir kısaltır; aynı uzunlukta iki kez yanılınca o bölüm biter. Önce ileri, sonra geri dizi. Puan = 10 × ileri + 15 × geri.''',
  mid: [
    TutorialSection(
      'Gruplama: 3-3-4',
      '''Kısa süreli bellek tek tek rakamları değil **grupları** sayar; rahatça tutabildiğin grup sayısı 4 civarındadır (Cowan, 2001). On rakamı on parça olarak tutmak zordur, üç-dört grup olarak kolaydır.

- 6 rakam: **3-3** · 7 rakam: **3-4** · 9 rakam: **3-3-3** · 10 rakam: **3-3-4** (telefon numarası gibi).
- Grubu içinden tek bir "sayı" gibi oku: 5-8-2 değil, "beş yüz seksen iki".
- Dizi gelirken grubu kapat ve bir sonrakine geç; geri dönüp eski grubu tekrarlamaya çalışma.''',
      diagram: MiniGrid([
        '*5 *8 *2 . 9 1 4 . *7 *3 *6 *0',
      ], cell: 22, caption: '10 rakam = 3 grup'),
    ),
    TutorialSection(
      'Ritim ve iç ses',
      '''Rakamları akılda tutan sistem büyük ölçüde **iç sesindir** (Baddeley'in "fonolojik döngüsü"). Kendi kendine tekrar etmezsen iz birkaç saniyede söner.

- Her rakamı geldiği anda **içinden söyle**, grubu bir ritimle bitir: "beş-se-kiz-İKİ".
- Dizi bitince tamamını bir kez daha hızla "dinle", sonra yazmaya başla.
- Hızlı bölümlerde her rakamı ayrı söyleyemezsin; grubu tek bir melodi gibi söyle.

Ara görev bu döngüyü bilerek keser (Brown–Peterson yöntemi): işlemi okurken bile döngüyü fısıltı gibi sürdürmeye çalış.''',
    ),
    TutorialSection(
      'Geri dizi: çizgiyi gör',
      '''Geri dizide iç ses yetmez, çünkü ses ileri akar. Bunun yerine **görsel bir çizgi** kur:

- Rakamlar geldikçe onları zihninde bir tahtaya **soldan sağa** yaz.
- Yazarken tahtayı **sağdan sola** oku.
- Uzun dizide grup grup çalış: grupların sırasını ters çevir, sonra her grubun içini ters oku. 582 914 → önce 914'ü ters (4-1-9), sonra 582'yi ters (2-8-5).

Gruplar küçük oldukça ters çevirmek kolaylaşır; 6'dan uzun geri dizilerde 2-3'lük gruplar kullan.''',
      diagram: MiniGrid([
        '5 8 2 . 9 1 4',
        '*4 *1 *9 . *2 *8 *5',
      ], cell: 30, caption: 'Grupların sırası da, içi de ters'),
    ),
    TutorialSection(
      'Sıralı ve harf-rakam: lambaları yak',
      '''Bu iki türde sırayı unutabilirsin; önemli olan **hangi** rakamın geldiği.

- Zihninde 0'dan 9'a bir **lamba sırası** hayal et. Gelen her rakam kendi lambasını yakar.
- Dizi bitince lambaları soldan sağa oku: yanan her lamba bir cevap.
- Harf-rakamda iki ayrı sıra kur: üstte rakam lambaları, altta harf lambaları (A B D E K L M R S T). Önce üst sırayı, sonra alt sırayı oku.

İleri sırayla tutup sonra sıralamaya çalışmak iki kat iş demektir; lambalar sıralamayı **gelirken** yapar.''',
      diagram: MiniGrid([
        '0 *1 2 *3 4 *5 6 7 *8 9',
      ], cell: 26, caption: 'Gelen: 8 3 5 1 → yazılan: 1 3 5 8'),
    ),
  ],
  advanced: [
    TutorialSection(
      'Anlam yükle',
      '''Uzun süreli bellekte zaten olan bir şeye bağlanan grup bedavaya gelir: **1453**, **1923**, **365**, **112**, bir arkadaşının doğum yılı, otobüs hattın.

Ünlü örnek: SF adlı bir koşucu, rakam gruplarını koşu derecelerine çevirerek (3-4-9-2 → "3 dakika 49,2 saniye, iyi bir mil derecesi") yaklaşık 230 saatlik çalışmayla rakam kapasitesini **7'den 79'a** çıkardı (Ericsson, Chase ve Faloon, 1980). Ama harflerdeki kapasitesi 6 civarında kaldı: kazanç beceriye özgüydü.

Kendi kodunu kur: tarihler, puanlar, hatlar, saatler. Hafıza Sarayı'ndaki Major sistemi de bu işi görür.''',
    ),
    TutorialSection(
      'Ara görevde diziyi korumak',
      '''İşlem sorusu dikkatini diziden çalmak için oradadır. Az dikkatle çözmek için:

- **Sadece son haneye bak:** 27 + 8 = 35 mi? 7 + 8 = 15 → son hane 5, uyuyor. Yanlış işlemlerin çoğu son hanede ya da onlar basamağında bozulur.
- Son hane uyuyorsa onlara bak: 27 + 8 ≈ 30'lar. 45 yazıyorsa yanlış.
- Cevabı verir vermez dizinin **ilk grubunu** içinden söyle, döngüyü yeniden başlat.

4 saniyelik süre dolarsa cevap yanlış sayılır; ama işlemi kusursuz çözmek için diziyi kaybetmek daha pahalıdır.''',
    ),
    TutorialSection(
      'Hız artınca: gruplayarak dinle',
      '''Son bölümlerde rakamlar yarım saniyede bir gelir. Bu hızda:

- Grupları **önceden planla**: dizinin uzunluğunu biliyorsun (üstte yazıyor), 12 ise 3-3-3-3 diye hazır ol.
- Her rakamı tekrar etmeye çalışma; grubun "melodisini" dinle, grup bitince tek seferde söyle.
- Dizi biter bitmez **yazmaya başla**: iz saniyeler içinde söner. İlk grubu yazarken sıradakini içinden söyle.
- Yanlış yazdığını fark edersen silip düzeltebilirsin; ama tereddüt etmek de iz kaybettirir.''',
    ),
    TutorialSection(
      'Bilim: ne ölçer, ne kazandırır?',
      '''Rakam dizisi testi zeka testlerinin (WAIS) bir parçasıdır. Yetişkinlerde ileri dizi ortalaması yaklaşık **6–7**, geri dizi **4–5** rakamdır.

- **İleri dizi** kısa süreli depolamayı (iç ses döngüsü) ölçer.
- **Geri, sıralı ve harf-rakam** bilgiyi tutarken **işlemeyi**, yani çalışma belleğini ölçer. Puan formülünde geri dizinin 1,5 kat sayılmasının nedeni bu.

Dürüst not: bu antrenmanla bu testte belirgin gelişirsin (yakın aktarım), çoğu da gruplama ve kodlama stratejilerinden gelir. Genel zekaya ya da başka işlere taşındığına dair kanıt zayıf (Melby-Lervåg ve Hulme, 2016; Simons ve ark., 2016). Uyarlanır modu haftada bir yap ve gelişimini ölç; uyku ve dinlenmişlik sonuçları belirgin etkiler.''',
    ),
  ],
);
