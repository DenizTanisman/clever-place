import 'package:flutter/material.dart';

import '../card_kit.dart';
import '../lux.dart';
import '../tutorial.dart';

/// Suits in the diagrams: 0 maça, 1 kupa, 2 karo, 3 sinek; ranks 2..14 (14 = As).
const batakTutorials = GameTutorials(
  rules: '''
- 52 kart, 4 oyuncu, herkes **kendi için** oynar. Sen Güney'sin; oyun saat yönünde döner. Herkese 13 kart.
- **İhale:** dağıtanın solundan başlayarak herkes alacağı el sayısını söyler (en az **4**, en çok 13) ya da **pas** der; pas diyen bir daha konuşmaz. İlk üç kişi pas derse dağıtan 4 almak zorundadır.
- İhaleyi alan **kozu seçer** ve ilk eli açar. Koz, biri koz atana kadar (**koz kırılana** kadar) açılamaz — elinde yalnız koz kalmadıysa.
- **Renge uy.** Masadaki en büyük kartı geçebiliyorsan **geçmek zorundasın** (yükseltme). Rengin yoksa **kozla kesmek** zorundasın; masada koz varsa onu geçebiliyorsan geçmelisin. Ne renk ne koz varsa istediğini at.
- **Puan:** ihaleci tutturursa **aldığı el kadar** alır, tutturamazsa ihalesi kadar **eksi** yazar (batar). Diğerleri aldıkları el kadar alır.
- **Maç:** biri **51 puana** ulaşınca ya da **10 el** bitince en yüksek puan kazanır. Kazanırsan 2 yıldız; ipucusuz ve 10+ farkla 3; ipucu aldıysan 1.
- Kartı masaya **sürükle** ya da iki kez dokun. Göz düğmesi (**Açık oyna**) bütün elleri ve rakiplerin **Neden?** satırlarını gösterir; puan hapına dokununca cetvel açılır.''',
  mid: [
    TutorialSection(
      'El değerlendirme ve ihale sayısı',
      '''Elini **el sayısına** çevir, sonra **aşağı yuvarla**:

- **As** ≈ 1 el. **Papaz**, yanında en az bir küçük kartla ≈ 0,6 (As'la birlikteyse ≈ 0,9). **Kız** üçlüde ≈ 0,3.
- **Koz uzunluğu:** 3'ten sonraki her küçük koz ≈ 0,85 el — rakiplerin kozu bitince onlar da el alır.
- **Kısa yan renk** (en az 3 kozun varken): o renk sende hiç yoksa ≈ 1, tek kartsa ≈ 0,6, iki kartsa ≈ 0,25 — gelince kozla keseceksin.
- İlk eli sen açtığın için ≈ +0,2.

Örnek: Maça A K 9 6 4, Kupa A 7, Karo K 8 3, Sinek 5 2 → maça koz: 1 + 0,9 + 1,7 (iki fazla koz) + kupa As 1 + karo Papaz 0,6 + kupa ve sinek ikilileri 0,5 + 0,2 ≈ **5,9** → **5 de**; 6 sınırda.

Tutturunca aldığın **el kadar** yazdığın için büyük ihale fazladan puan getirmez: rakibi geçecek **en küçük sayıyı** söyle, tahmininin üstüne çıkma.''',
      diagram: _CardRow([(0, 14), (0, 13), (0, 9), (0, 6), (0, 4), (1, 14), (1, 7), (2, 13), (2, 8), (2, 3), (3, 5), (3, 2)],
          caption: '≈ 5,9 el: maça koz, 5 de'),
    ),
    TutorialSection(
      'Koz sayma',
      '''Toplam **13 koz** var. Her an şunu bil: **kalan koz = 13 − seninkiler − düşenler.**

- Her koz düştüğünde say. Bir oyuncu renge uymayıp **koz da atmadıysa** onda koz **kalmamıştır** — not et.
- İhaleciysen ve **en büyük kozlar sende** ise kozları çek: As'ını, sonra Papaz'ını aç. Rakiplerde koz bitince yan renklerdeki büyüklerin kesilmeden el alır.
- Rakiplerde tek koz kaldıysa ve o koz seninkinden büyükse onu çekmek için koz harcama; yan renklerini oyna, o kozu kendi elinde kullanmak zorunda kalsın.
- Koz kırılmadan koz açılamaz: ilk elde koz çekmek istiyorsan önce birinin kesmesi gerekir. Kısa rengini oynayıp rakibi kesmeye zorlamak kozu kırar.''',
    ),
    TutorialSection(
      'Yükseltme kuralını kullanmak',
      '''Batak'ta masadaki en büyük kartı **geçebiliyorsan geçmek zorundasın**. Bunu lehine çevir:

- **Son sırada ucuza al:** herkes oynadıktan sonra masayı geçen **en küçük** kartı at — kural seni büyüğünü atmaya zorlamaz, sadece geçmeye.
- **Küçükten aç:** bir renkte Papaz'ın varsa ve As dışarıdaysa o rengi **küçük** kartla aç. Arkadakiler geçmek zorunda: As'ın yanında açtığın karttan büyük başka kartı olmayan oyuncu **As'ı atmak zorunda** kalır, Papaz'ın en büyük olur.
- **Geçemiyorsan özgürsün:** masayı geçecek kartın yoksa en değersizini ver; büyüklerini boşuna yakma.
- **Bilgi:** bir oyuncu masanın altında kalan bir kart verdiyse o renkte **daha büyüğü yoktur** — kural onu geçmeye zorlardı. Bu, rakibin elini daraltır.''',
      diagram: _CardRow([(1, 9), (1, 12), (1, 14), (1, 3)],
          caption: 'Papaz sende, Kupa 9 açtın: Kız ve As geçmek zorunda kaldı, son oyuncu geçemedi — Papaz artık en büyük'),
    ),
    TutorialSection(
      'Rakibin bittiği rengi izlemek',
      '''Bir oyuncu açılan renge **uymadığı** an o renkte **bitmiştir** — bunu el sonuna kadar unutma.

- **Uymadı ama koz attı:** o renk her açıldığında kesecek. Defansta bu rengi **açma**; ihaleciye bedava el olur.
- **Uymadı, koz da atmadı:** onda **koz da yok**. Artık senin yan renk büyüklerin ona karşı güvende.
- **Kozun altına koz attı:** masadaki kozu geçemedi demek; ondaki kozların hepsi o kozdan küçük.
- İhaleciysen rakiplerin bittiği rengi **sen** açma — sen de kesebiliyorsan bile kozun azalır. Onların bitmediği, senin bittiğin rengi açtırmaya çalış.

Açık oyna modunda Neden? satırlarında rakiplerin bu bilgiyi nasıl kullandığını görebilirsin.''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Pozisyon (empas) ve emniyet oyunu',
      '''**Pozisyon:** elinde Kupa As–Kız var, Papaz **senden önce oynayan** rakipte. Kupayı **sen açma**: başkası açtığında Papaz'cı senden önce oynamak zorunda kalır; Papaz'ı atarsa As'ınla alırsın, küçük atarsa Kız'ın el alır. Rengi sen açarsan Papaz'cı arkadan gelir ve Kız'ını yer.

Papaz **senden sonra** oynayan rakipteyse Kız'ın ancak Papaz düştükten sonra el alır; ona güvenip ihale sayma.

**Emniyet:** ihale için gereken eller elindeyse **önce onları topla**. Batmak ihalen kadar eksi, fazladan el sadece +1: 6 ihaleye 6 garanti elin varsa 8 için risk alma.''',
      diagram: _CardRow([(1, 14), (1, 12)], caption: 'As–Kız: Papaz önünde ise iki el'),
    ),
    TutorialSection(
      'Kozla kesip kontrol',
      '''Kozun iki işi var: **el almak** ve **kontrol** (eli geri kazanmak).

- **Kısa rengini kes, büyük kozu sakla:** tek kartlık rengini erken oynayıp bitir; o renk gelince **küçük kozla** kes. As ve Papaz'ı, rakip koz çekmeye kalktığında eli geri almak için tut.
- **Kesmeye ihtiyacın varsa koz çekme:** kozları erken toplarsan kesecek kozun kalmaz. Önce kes, sonra çek.
- **Uzun yan rengin varsa önce koz çek:** yan rengin büyükleri ancak rakiplerde koz kalmadıysa güvende.
- **Üstten kesme:** masada küçük bir koz varsa ve sen geçebiliyorsan geçmek zorundasın — geç ama **gereğinden büyük** kozla değil.''',
    ),
    TutorialSection(
      'Son eller için kart sayma',
      '''Son 4–5 elde rakiplerin ellerini neredeyse kesin bilebilirsin:

- Her renkten 13 kart var: **düşenleri** say, kalanları rakiplere dağıt.
- **Bitmiş renkleri** ve **koz bitenleri** hatırla (uymadı / kesmedi).
- **Tavanlar:** masanın altında kalan kart veren oyuncunun o renkte daha büyüğü yoktur (yükseltme zorunluluğu).
- Kalan kartları bu kısıtlarla yerleştir; çoğu zaman tek bir dağılım kalır.

Örnek: son üç el, koz Kupa. Kupa 10 ve 4 dışarıda; Kerem kupada bitti. O hâlde iki koz da Selin ya da Murat'ta. Murat az önce Kupa 7'nin altına Kupa 5 verdiyse 10 onda değil: **Kupa 10 Selin'de.**''',
    ),
    TutorialSection(
      'İmkânsız modunda neden kaybedersin — dürüstçe',
      '''İmkânsız masadaki rakipler **bütün kartları görür** ve her elde **çift kör (double-dummy) arama** ile kusursuz oynar:

- Hangi kartın nerede olduğunu bilir; tahmin yapmaz, **hesap** yapar.
- İhaleyi ancak **garanti** edebildiği kadar söyler: üç rakip birlikte en iyi savunmayı yapsa bile tutacağı sayıyı. Bu yüzden neredeyse hiç batmaz.
- Sen ihaleci olunca üçü **birlikte** seni batırmaya oynar; ellerin dağılımını bildikleri için empasların tutmaz, kart saymanın avantajı yoktur.

Kazanmanın tek yolu: rakiplerin kartları gerçekten kötü gelmiş olsun ve sen hatasız oyna. Beraberlik mümkün. Bu masayı **antrenman** için kullan: Açık oyna'yı aç, Neden? satırlarında mükemmel oyunun gerekçesini oku; ipucu ise yalnızca **senin bildiklerinle** önerir — ikisini karşılaştır.''',
    ),
  ],
);

/// A row of small cards for the tutorial diagrams.
class _CardRow extends StatelessWidget {
  final List<(int, int)> cards;
  final String? caption;
  const _CardRow(this.cards, {this.caption});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, cons) {
      final n = cards.length;
      final w = (cons.maxWidth / (n <= 4 ? 4.5 : 5.2)).clamp(30.0, 64.0);
      final step = n <= 1 ? 0.0 : ((cons.maxWidth - w) / (n - 1)).clamp(0.0, w * 0.9);
      final total = w + step * (n - 1);
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: total,
            height: w / CardKit.aspect,
            child: Stack(children: [
              for (var i = 0; i < n; i++)
                Positioned(
                  left: i * step,
                  top: 0,
                  width: w,
                  height: w / CardKit.aspect,
                  child: PlayingCard(suit: cards[i].$1, rank: cards[i].$2),
                ),
            ]),
          ),
          if (caption != null) ...[
            const SizedBox(height: 8),
            Text(caption!, textAlign: TextAlign.center, style: Lux.ui(12, color: Lux.muted)),
          ],
        ],
      );
    });
  }
}
