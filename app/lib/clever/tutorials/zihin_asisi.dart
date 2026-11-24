import '../tutorial.dart';

const zihinAsisiTutorials = GameTutorials(
  rules: '''
- Her teknik bir **doz**: önce uyarı kartını okursun, sonra **10 kurgusal mesajla** zayıf dozu alırsın.
- Mesajdaki numarayı bulur, en iyi karşılığı seçer ve **sağlam mesajları** ayırırsın.
- Yıldızlar: 9–10 doğru **3**, 8 doğru **2**, 7 doğru **1** yıldız. 7'nin altında bölüm geçilmez.
- Son bölümler **karma sınavdır**: uyarı yoktur, hangi tekniğin geldiğini sen bulursun.
- **Hatırlatma dozu** bütün mesajları karıştırır; üçüncü yanlışta biter.
- Mesajlardaki kişi ve olaylar uydurmadır.''',
  rulesEn: '''
- Each technique is a **dose**: first you read the warning card, then you take a weak dose with **10 fictional messages**.
- You spot the trick in each message, pick the best response and tell the **genuine messages** apart.
- Stars: 9–10 right **3**, 8 right **2**, 7 right **1** star. Below 7 you don't pass the level.
- The final levels are a **mixed exam**: no warning, you work out which technique you are facing.
- **Booster shot** mixes all the messages; it ends on the third wrong answer.
- The people and events in the messages are made up.''',
  mid: [
    TutorialSection(
      'Neden "aşı"?',
      '''Tıpta aşı, vücudu mikrobun **zayıflatılmış** hâliyle tanıştırır. William McGuire 1961'de aynı fikri ikna için önerdi: Bir saldırıyı önceden, zayıf hâliyle görüp cevaplamayı öğrenen kişi gerçeğine karşı daha dirençli olur.

Her bölüm bu iki adımı izler: **uyarı** ve **zayıf doz**.''',
    ),
    TutorialSection(
      'Duygu kötü bir şey değil',
      '''Bir mesajın üzgün, öfkeli ya da endişeli olması onu manipülasyon yapmaz. Bakılacak şey duygunun **bilginin yerini alıp almadığıdır**:

- Ne olmuş, nerede, ne zaman?
- Kim görmüş, nereden biliniyor?
- Benden ne yapmamı istiyor, acele ettiriyor mu?''',
    ),
  ],
  advanced: [
    TutorialSection(
      'Her şeye şüpheyle bakmak aşı değildir',
      '''Bazı araştırmalar bu tür oyunların insanları yalnızca daha **şüpheci** yapabildiğini, doğruyu yanlıştan ayırmayı her zaman iyileştirmediğini gösterdi (Modirrousta-Galian ve Higham, 2023).

Bu yüzden her bölümde sağlam mesajlar da var ve sonuç ekranı bunları ne kadar ayırabildiğini ayrıca gösterir.''',
    ),
    TutorialSection(
      'Etki zamanla azalır',
      '''Araştırmalar aşı etkisinin haftalar içinde zayıfladığını, hatırlatmayla korunabildiğini buluyor (Maertens ve ark., 2021). **Hatırlatma dozu** modu bunun için var.

Yöntem ve teknik listesi Cambridge Üniversitesi araştırmacılarının inoculation.science sitesinden ve Roozenbeek ve ark. (2022) çalışmasından esinlenmiştir. Oyunun mesajları ve kurgusu özgündür.''',
    ),
  ],
);
