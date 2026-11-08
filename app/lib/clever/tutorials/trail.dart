import '../tutorial.dart';

const trailTutorials = GameTutorials(
  rules: '''
- Dairelere doğru sırayla **tek tek dokun**.
- Sıradaki daireye dokununca çizgi bir önceki daireden ona doğru uzanır. Başka bir daireye dokunursan **hata** sayılır ve daire bordo yanar; **her yanlış dokunuş ayrı bir hatadır**.
- Zaten bağlanmış bir daireye yeniden dokunmak bir şey yapmaz.
- Türler: **A** (1, 2, 3… diye), **B** (1-A-2-B-3-C…, Türk alfabesiyle), **ters** (sondan başa), **renkli** (her sayı iki renkte; renk değiştirerek ilerle), **tuzaklı** (dizide olmayan daireler).
- Saat, geri sayım biter bitmez başlar. Hedef sürenin 3 katında süre dolar ve bölüm kaybedilir.
- Yıldızlar: hedef sürede ve hatasız 3; hedefin 1,5 katında ve en çok 2 hatayla 2; bitirirsen 1.''',
  mid: [
    TutorialSection(
      'A ile B: hız ve esneklik',
      '''Bu oyun nöropsikolojide yaygın kullanılan **İz Sürme Testi**'nin (Trail Making) dokunmatik hâli.

- **A** (1-2-3…) görsel tarama ve işlem hızını ölçer.
- **B** (1-A-2-B…) aynı taramaya iki diziyi aklında tutup aralarında **gidip gelmeyi** ekler. B ile A arasındaki fark, zihinsel esnekliğin (görev değiştirme) klasik bir göstergesidir.

Bu yüzden oyundaki hedef süre B'de daire başına neredeyse iki katı. Kendi oranına bak: aynı sayıda dairede B süren A sürenin kaç katı? Oran düştükçe esnekliğin bu görevde gelişiyor demektir.''',
    ),
    TutorialSection(
      'Önden bak: göz elden önce gider',
      '''En büyük zaman kaybı, bir daireye vardıktan **sonra** bir sonrakini aramaya başlamaktır.

Teknik: 5'e dokunurken gözün 6'yı arıyor olsun. Parmağın 5'ten kalktığı anda 6'nın yerini zaten biliyor ol.

- Gözünü parmağına değil, bir sonraki hedefe ver. Dokunma kısa bir harekettir; asıl süre aramada geçer.
- Aramayı bulunduğun yerden dışa doğru yap: sıradaki numara genelde rastgele yerdedir, ama yakın çevreyi taramak her seferinde tüm ekranı taramaktan hızlıdır.''',
    ),
    TutorialSection(
      'B dizisi: sayı ile harfi eşle',
      '''B'de her sayının eşi, alfabede **o sıradaki harf**tir: 1-A, 2-B, 3-C, 4-Ç… Bu eşlemeyi bilirsen "şimdi hangi harf?" diye saymazsın.

Türk alfabesinin tuzakları: C'den sonra **Ç**, G'den sonra **Ğ**, I'dan sonra **İ**, O'dan sonra **Ö**, S'den sonra **Ş**, U'dan sonra **Ü** gelir.

Teknik: çifti tek parça söyle: "üç-ce", "dört-çe". Sayıdan harfe geçerken aklında hep bir sonraki çift olsun.''',
      diagram: MiniGrid(['1 2 3 4 5 6 7 8', 'A B C *Ç D E F G', '9 10 11 12 13 14 15 .', '*Ğ H I *İ J K L .'],
          cell: 34, caption: 'Sayı ve eşi: altınlar Türkçeye özgü harfler'),
    ),
    TutorialSection(
      'Önce bul, sonra dokun',
      '''Dokunarak oynarken en pahalı alışkanlık **tahminle dokunmaktır**: "6 şuralardaydı" deyip emin olmadan basmak. Her yanlış dokunuş ayrı bir hatadır, üç hata da üçüncü yıldızı ve ikinci yıldızı götürür.

- Etiketi **okuduktan sonra** dokun; gözünün ucuyla gördüğün bir "6" bazen "9" ya da "G" çıkar.
- Sıkışık kümelerde dairenin ortasına dokun; oyun parmağına en yakın daireyi seçer.
- Hata yaptıysan dur ve doğru daireyi ara. Aynı daireye tekrar tekrar dokunmak her seferinde yeni bir hata yazar.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Tahtanın haritası',
      '''Arama sırasında gözüne çarpan etiketleri boşa harcama. 7'yi ararken 11'i ve 12'yi gördüysen, kabaca yerlerini akılda tut ("12 sağ altta").

- Tahtayı dörde böl: sol üst, sağ üst, sol alt, sağ alt. Gördüğün sonraki 2–3 etiketin hangi bölgede olduğunu bil.
- Bu küçük harita, bir sonraki aramayı tüm tahta yerine tek bölgeye indirir.

Bu tür "yan bilgi" zamanla otomatikleşir. Ama ilk turlarda bilinçli yapmak ciddi süre kazandırır.''',
    ),
    TutorialSection(
      'Ters diziler',
      '''Ters A (18'den 1'e) ve ters B (G-8-F-7-E-6…) çalışma belleğine daha fazla yük bindirir: geriye saymak ve alfabeyi geriye okumak otomatik değildir.

Teknik: geriyi önceden hazırla.
- Ters B'de her harften sonra **kendi eşi olan sayı** gelir, sonra bir önceki harf: G'den sonra 8 (G sekizinci harf), F'den sonra 7. Dizi G-8-F-7-E-6-D-5-Ç-4… diye iner.
- Başlangıç etiketini hedef satırından oku; ilk daireyi yanlış seçmek en sık hatadır.
- Bir sonraki çifti parmak yoldayken söyle: "fe, yedi".

Ters dizilerde hata çoğu zaman bir adım atlamaktır (F'den sonra E yerine D'ye gitmek). Her harfte bir sonrakini içinden söylemek bunu önler.''',
    ),
    TutorialSection(
      'Renkli iz: renk kural, sayı hedef',
      '''Renkli bölümde her sayı iki kez var: altın ve yakut. Sırayla gideceksin ve **her adımda renk değiştireceksin**: altın 1, yakut 2, altın 3…

Bu düzen, dilden bağımsız olsun diye harf yerine renk kullanan **Renkli İz** testinden gelir. Yanlış renkteki ikiz, en güçlü tuzaktır: sayıyı bulduğun an basmak istersin.

Teknik: "renk-sayı" diye söyle: "yakut dört". Önce rengi seç, sonra o renkteki sayıyı ara; gözünün aradığı şey tek bir renk olunca tarama da hızlanır.''',
    ),
    TutorialSection(
      'Tuzaklar, döndürülmüş etiketler ve beklenti',
      '''Tuzaklı bölümlerde dizinin **devamı** gibi görünen fazladan daireler var (14'te biten bir dizide 15 ve 16 gibi). Hedef satırından dizinin nerede bittiğini oku; ters dizilerde başlangıç en tehlikeli yerdir.

Üst bölümlerde etiketler 37°'ye kadar döner. Biçimi oku, yönü değil: bu açılarda 6 ile 9 asla yer değiştirmez.

Beklenti: İz Sürme'de pratik etkisi büyüktür; sürelerinin hızla düşmesi kısmen görevi öğrenmenden gelir. Bu kötü değil, ama "genel dikkatim iki kat arttı" demek değildir. Asıl taşınan beceri, planlı tarama ve iki diziyi aynı anda tutma alışkanlığıdır.''',
    ),
  ],
);
