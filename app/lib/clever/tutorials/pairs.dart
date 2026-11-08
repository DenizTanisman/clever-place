import '../tutorial.dart';

const pairsTutorials = GameTutorials(
  rules: '''
- Kartları ikişer çevir. Aynı iki kartı bulursan **açık kalırlar**.
- Tutmazsa kartları kısa bir an görürsün, sonra kapanırlar. Beklemek istemezsen bir sonraki karta dokun: hemen kapanır.
- Her tur, tutsa da tutmasa da **1 hamle** sayılır.
- **Üçlü** bölümlerde aynı üç kartı bul; ikinci kart ilkini tutmazsa tur hemen biter.
- Bazı bölümlerde başta kartlar kısa süre **açık** gelir; bazılarında kapalı kartlar **yer değiştirir**; bazılarında **hamle sınırı** vardır.
- Yıldızlar "kusursuz hafıza" ölçüsüne göredir: hiçbir şeyi unutmayan bir oyuncu bu dağıtımda ortalama X hamle ister. X'in 1,15 katına kadar 3, 1,5 katına kadar 2, fazlası 1 yıldız. Sınır dolarsa bölüm biter.''',
  mid: [
    TutorialSection(
      'Sistemli tarama',
      '''Yeni kartları **rastgele değil, sırayla** aç: üst satırdan başla, soldan sağa, sonra bir alt satır.

Neden? Hangi kartları gördüğünü ayrıca hatırlamak zorunda kalmazsın: "tarama şu an 2. satırın ortasında" bilgisi yeter. Rastgele açınca bir kartı iki kez açıp hamle yakmak çok kolaydır.

Kural: her turun **ilk kartı** her zaman yeni bir kart olsun (bildiğin bir çift yoksa). İlk kart yeniyse, eşi daha önce gördüğün kartlardan biri olabilir.''',
    ),
    TutorialSection(
      'Kartlara isim ver',
      '''Gördüğün her kartı içinden kısaca **adlandır**: "kırmızı ay", "mavi yıldız", "yeşil damla".

İsim, görüntünün yanına sözel bir iz ekler (çift kodlama). İki farklı iz, tek izden daha zor silinir. Sesli ya da fısıltıyla söylemek etkiyi biraz daha artırır (üretim etkisi).

İsmi kısa tut: renk + şekil. Benzer kartların olduğu bölümlerde bu iki kelime şart: "kırmızı ay" ile "kırmızı yıldız" ancak tam isimle ayrılır.''',
    ),
    TutorialSection(
      'Yer kodlaması: satır satır',
      '''Kartın adını tek başına bilmek yetmez; **yerine** bağlaman gerekir. Izgarayı satırlarla düşün:

- Kartı satırıyla birlikte söyle: "kırmızı ay, 2. sıra, sağ uç".
- Köşeler ve kenarlar en kolay hatırlanan yerlerdir; ortadaki kartları en yakın köşeye göre kodla.
- Bir satırı bir cümle gibi tut: "üst sıra: ay, yıldız, —, damla" (— = henüz açılmadı).''',
      diagram: MiniGrid([
        '*Ay Yıl . Dam',
        '. . *Ay .',
        'Pla . . .',
      ], caption: '"Ay: üst sol köşe ve 2. sıra, sağdan ikinci" · eşleşme hazır'),
    ),
    TutorialSection(
      'Önizlemeyi verimli kullan',
      '''Başta kartların açık kaldığı 1–2 saniyede hepsini ezberleyemezsin. Deneme de: hepsine bakan, hiçbirini tutamaz.

- **Dört köşeyi** ve bir satırı al.
- Ya da göze çarpan 3–4 kartı seç (en parlak renk, en ayrı şekil) ve yerlerini kodla.
- Önizlemede **eş gördüysen** (iki aynı kart), onu ilk hamlende hemen al: bilgi taze iken.

Sonra taramaya kaldığın yerden değil, önizlemede bakmadığın bölümden başla.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Bilinmeyen mi açmalı, bilinen mi?',
      '''Her turda karar şu sırayla verilir:

- **Yerini bildiğin bir çift** varsa önce onu al. Hem garanti hamle, hem bellekten bir yük kalkar.
- Yoksa **ilk kart yeni** bir kart olsun. Eşini daha önce gördüysen ikinci kart o.
- Eşini görmediysen ikinci kart da **yeni** bir kart olsun. Bildiğin bir kartı açmak sıfır bilgi verir; yeni kart ise hem bilgi verir hem şans tanır.
- Tek istisna: bir kartın yerinden **emin değilsen** ve o kartın eşi şimdi açıldıysa, aklındaki en olası yeri dene. Yanılsan bile o yerin ne olduğunu tazelemiş olursun.

Kusursuz hafıza bile çift başına ortalama yaklaşık 1,6 hamle ister; yıldız ölçüsü bu yüzden çift sayısının değil, bu ortalamanın üstüne kurulu.''',
    ),
    TutorialSection(
      'Benzer kartlar: iki özelliği birlikte kodla',
      '''İleri bölümlerde aynı şekil farklı renkte, aynı renk farklı şekilde gelir; en zorunda yalnızca köşedeki küçük **yıldız** farkı vardır.

Buradaki tuzak, beynin özellikleri tek tek tutup birbirine yanlış bağlamasıdır ("kırmızıydı, aydı" ama hangi kırmızı aydı?). Çare:

- İsmi her zaman **tam** söyle: renk + şekil (+ "yıldızlı").
- Açılan kartı adlandırmadan önce **bir an bak**: aceleyle açılan kart, yarım kodlanmış karttır.
- Eşleşme sanıp çevirdiğin ikinci karta bakarken önce ayrıntıyı doğrula.''',
    ),
    TutorialSection(
      'Karışmayı izle',
      '''Karışan bölümlerde üst bilgi "Karışmaya N hamle" der. Karışma sırasında yer değiştiren kartlar **yükselir ve altın kenarlı** kayar.

- Karışmadan hemen önce bildiğin çiftleri al: karışma onları dağıtabilir.
- Kayma sırasında yalnızca **bildiğin** kartları takip et; bilmediğin kartların yer değiştirmesi seni ilgilendirmez.
- Kayma bitince etiketi güncelle: "kırmızı ay, üst sol köşeden ortaya geçti". Eski yeri silmek, yeni yeri yazmak kadar önemlidir.''',
    ),
    TutorialSection(
      'Bilim: ne çalışıyor?',
      '''Eşleştirme, nesne ile yeri birbirine bağlama belleğini (nesne-konum bağlama) çalıştırır; bu bağ hipokampusun temel işlerinden biridir.

Dürüst olalım: bu oyunda ustalaşmak seni bu oyunda ve benzer işlerde (örneğin bir masadaki eşyaların yerini hatırlamak) iyileştirir; zekayı genel olarak artırdığına dair kanıt yok (Sala ve Gobet, 2017).

İşine yarayacak dersler ise gerçek ve taşınabilir:
- **Sistem** (tarama), **adlandırma** (çift kodlama) ve **yer kodlaması** her ezber işinde çalışır.
- Bölümler arasında kısa ara ver: bir önceki tahtanın izleri yenisine karışır (proaktif girişim).''',
    ),
  ],
);
