// English for Clever Place: Game names, categories, taglines, section and mode labels (catalog.dart, names_tr.dart).
// Key: the Turkish text exactly as in the code; value: its English. See lang.dart.
//
// names_tr.dart holds Turkish first names (for picking a TTS voice): content, not interface, so it
// has no entries here.

const Map<String, String> enCatalog = {
  // ---- categories (GameCategory, hub section order)
  'Strateji': 'Strategy',
  'Hafıza': 'Memory',
  'Dikkat': 'Attention',
  'Mantık bulmacaları': 'Logic puzzles',
  'Zihin antrenmanı': 'Mind training',
  'Kıraathane oyunları': 'Coffeehouse games',
  'Dinleme': 'Listening',
  'Zeka küpü': 'Puzzle cube',

  // ---- GameInfo defaults
  'Sonsuz mod': 'Endless mode',
  'Bilgilendirme': 'Info',

  // ---- logic puzzles
  'Sudoku': 'Sudoku',
  'Tek çözümlü, teknikle derecelenmiş': 'Unique solutions, graded by technique',
  'Taçlar': 'Crowns',
  'Her satır, sütun ve bölgede bir taç': 'One crown in every row, column and region',
  'Güneş & Ay': 'Sun & Moon',
  'Denge, eşitlik ve zıtlık': 'Balance, equals and opposites',
  'Shikaku': 'Shikaku',
  'Izgarayı dikdörtgenlere böl': 'Split the grid into rectangles',
  'Renk Tüpleri': 'Color Tubes',
  'Sıvıları renklerine ayır': 'Sort the liquids by color',
  'Hanoi Kuleleri': 'Tower of Hanoi',
  'Özyinelemenin en saf hâli': 'Recursion in its purest form',
  'IQ Soruları': 'IQ Puzzles',
  'Matris, dizi, küp, mantık: 1000 soru, puan yok, sadece keyif':
      'Matrices, sequences, cubes, logic: 1000 questions, no score, just fun',
  'Karışık': 'Mixed',
  'Sözel ve Sosyal Zeka': 'Verbal & Social Intelligence',
  'Kelimeler, insanlar ve duygular: 450 soru': 'Words, people and emotions: 450 questions',

  // ---- strategy: quick solo games
  'Düşen Bloklar': 'Falling Blocks',
  'Satırları tamamla, kuyuyu boşalt': 'Complete lines, clear the well',
  'Maraton': 'Marathon',
  'Blok Merkezi': 'Block Grid',
  '9×9: satır, sütun ve kare temizle': '9×9: clear rows, columns and squares',
  'Mücevher Birleştir': 'Gem Merge',
  'Aynı taşlar birleşip büyür': 'Matching gems merge and grow',

  // ---- mind training
  'Mental Aritmetik': 'Mental Arithmetic',
  'Hızlı işlem ve pratik hileler': 'Fast calculation and handy tricks',
  'Sprint (60 sn)': 'Sprint (60 s)',
  'Sprint': 'Sprint',
  'Soroban': 'Soroban',
  'Japon abaküsü: boncukla hesap, zihinde anzan': 'Japanese abacus: count with beads, then anzan in your head',
  'Zihin Aşısı': 'Mind Vaccine',
  'Manipülasyona karşı bağışıklık: 11 teknik': 'Immunity to manipulation: 11 techniques',
  'Hatırlatma dozu': 'Booster shot',

  // ---- memory
  'N-Back': 'N-Back',
  'Çalışma belleği antrenmanı': 'Working memory training',
  'İkili N-Back (uyarlanır)': 'Dual N-Back (adaptive)',
  'Hafıza Sarayı': 'Memory Palace',
  'Duraklara yerleştir, sırayla hatırla': 'Place items along the route, recall them in order',
  'Sayı Dizisi': 'Digit Span',
  'İleri ve geri rakam belleği': 'Forward and backward digit memory',
  'Uyarlanır (kapasite testi)': 'Adaptive (capacity test)',
  'Corsi Blokları': 'Corsi Blocks',
  'Yanan sırayı tekrarla': 'Repeat the order they light up',
  'Eşleştirme': 'Pairs',
  'Kartların yerini aklında tut': 'Remember where the cards are',
  'Sahne Hafızası': 'Scene Memory',
  'Bak, aklında tut, soruları cevapla': 'Look, remember, answer the questions',
  'Yüz ve İsim': 'Faces & Names',
  'Yüzü gör, ismi bağla': 'See the face, link the name',
  'Kelime Listesi': 'Word List',
  'Gör, bekle, hatırla': 'See, wait, recall',

  // ---- attention
  'Schulte Tablosu': 'Schulte Table',
  'Sırayla bul: görsel tarama ve odak': 'Find them in order: visual scanning and focus',
  'Dönen Sayılar': 'Spinning Numbers',
  'Dönen halkalarda sırayla bul': 'Find them in order on spinning rings',
  'Sonsuz tur': 'Endless rounds',
  'Renk–Kelime': 'Color–Word',
  'Okuma, rengini seç': "Don't read it, pick its color",
  'Çoklu Takip': 'Multiple Object Tracking',
  'Gözünü ayırmadan izle': 'Keep your eyes on them',
  'Dur ya da Geç': 'Go / No-Go',
  'Hızlı karar, sağlam fren': 'Quick decisions, firm brakes',
  'Sonsuz akış': 'Endless stream',
  'Renk Kapıları': 'Color Gates',
  'Düşen diskleri doğru kapıya al': 'Guide the falling discs to the right gate',
  'Sonsuz yağmur': 'Endless rain',
  'Görev Değiştirme': 'Task Switching',
  'Kural değişir, sen de değiş': 'The rule changes, so do you',
  'İz Sürme': 'Trail Making',
  '1-A-2-B-3-C: iki diziyi ör': '1-A-2-B-3-C: weave two sequences',
  'Hızlı Akış': 'Rapid Stream',
  'Akan harflerde hedefleri yakala': 'Catch the targets in a stream of letters',
  'Değişimi Yakala': 'Spot the Change',
  'Neyin değiştiğini bul': 'Find what changed',

  // ---- strategy: board duels
  'Koridor': 'Corridor',
  'Duvar Yarışı': 'Wall Race',
  'Yolunu aç, rakibininkini uzat': "Open your path, lengthen your rival's",
  'Abalone': 'Abalone',
  'İtiş': 'Push',
  'Bilyeleri it, rakibi tahtadan düşür': 'Push the marbles, knock your rival off the board',
  'Cırtcak': "Nine Men's Morris",
  '9 taş: değirmen kur, rakibin taşını al': "9 pieces: form mills, take your rival's pieces",
  'Surakarta': 'Surakarta',
  'Halkalardan dolaş, uzaktan vur': 'Loop around the circuits, strike from afar',
  'XOX': 'XOX',
  'Altı oyunluk maç, dört oyun türü': 'Six-game matches, four variants',

  // ---- listening
  'Kim Ne Dedi?': 'Who Said What?',
  'Konuşmayı takip et: kim önerdi, kim vazgeçti?': 'Follow the conversation: who suggested what, who backed out?',
  'Nerede Kalmıştım?': 'Where Was I?',
  'Sözün kesilse de ipi elinden bırakma': "Don't lose the thread, even when you're cut off",
  'Doğru Söz': 'Right Words',
  'Zor anlarda doğru cümleyi bul: 1000 sahne': 'Find the right words in hard moments: 1000 scenes',
  'Benim ilkelerim ve her alanın araştırmaya dayalı ilkeleri':
      'My principles, and the research-based principles of each area',

  // ---- coffeehouse games
  'Batak': 'Batak',
  'İhale, koz ve el sayma': 'Bidding, trumps and counting tricks',
  'Okey': 'Okey',
  '101 ve klasik: per diz, işle, ilk sen bitir': '101 and classic: build melds, lay off, go out first',
  'Blöf': 'Bluff',
  'Yalanı yakala, kendininkini sakla': 'Catch the lie, hide your own',
  '21': 'Blackjack',
  'Krupiyeye karşı: temel strateji ve kart sayma': 'Against the dealer: basic strategy and card counting',

  // ---- the cube (hub_screen.dart)
  'Küp': 'Cube',
  'Zamanlayıcı, algoritma defteri, test': 'Timer, algorithm notebook, tests',
  'Zamanlayıcı, defter': 'Timer, notebook',

  // ---- tiers and table modes (Batak, Okey, Blöf; XOX opponents)
  'Kolay': 'Easy',
  'Orta': 'Medium',
  'Zor': 'Hard',
  'Uzman': 'Expert',
  'Usta': 'Master',
  'İmkânsız': 'Impossible',
  'Rakipler temel kurallarla, bazen dikkatsiz oynar.': 'Opponents play by the basic rules, sometimes carelessly.',
  'Rakipler kart sayar, mantıklı oynar.': 'Opponents count cards and play sensibly.',
  'Güçlü rakipler: olasılık hesabı ve derin arama.': 'Strong opponents: probability math and deep search.',
  'Rakipler bütün kartları görür ve kusursuz oynar.': 'Opponents see every card and play flawlessly.',

  // Okey: "Group · Table" labels; the game page translates the group and the table part separately.
  '101': '101',
  'Klasik': 'Classic',
  '101 · Kolay': '101 · Easy',
  '101 · Orta': '101 · Medium',
  '101 · Zor': '101 · Hard',
  '101 · İmkânsız': '101 · Impossible',
  'Klasik · Kolay': 'Classic · Easy',
  'Klasik · Orta': 'Classic · Medium',
  'Klasik · Zor': 'Classic · Hard',
  'Klasik · İmkânsız': 'Classic · Impossible',
  'Rakipler açmayı bilir ama işlemeyi unutur, bazen ceza yer.':
      'Opponents know how to open but forget to lay off, and sometimes take penalties.',
  'Rakipler en iyi açılışı bulur, taş sayar, ceza yemez.':
      'Opponents find the best opening, count tiles and never take penalties.',
  'Güçlü rakipler: bir çekiş ileriyi hesaplar, sağındakini besleme.':
      'Strong opponents: they think one draw ahead and avoid feeding the next player.',
  'Rakipler bütün rafları ve destenin sırasını görür.': 'Opponents see every rack and the order of the pile.',

  // Blackjack tables
  'Klasik masa': 'Classic table',
  '6 deste, krupiye 17\'de durur. Kendi stratejinle oyna.': '6 decks, dealer stands on 17. Play your own strategy.',
  'Koç': 'Coach',
  'Her karardan sonra temel stratejiye göre doğru hamle ve nedeni.':
      'After every decision: the basic-strategy play and why.',
  'Kart sayma': 'Card counting',
  'Hi-Lo sayımı: masada say, ara ara sayını sorar.':
      'Hi-Lo count: keep the count as you play; now and then you are asked for it.',
  'Açık deste': 'Open deck',
  'Sıradaki kartları ve krupiyenin kapalı kartını görürsün.': "You see the next cards and the dealer's hole card.",

  // ---- XOX free matches (matchTitle: "Serbest maç · <opponent>", or "Arkadaşla maç")
  'Arkadaşla maç': 'Match with a friend',
  'Serbest maç': 'Free match',
  'Serbest maç · {0}': 'Free match · {0}',
  'Arkadaşla': 'With a friend',
  'Klasik 3×3': 'Classic 3×3',
  'Klasik 4×4': 'Classic 4×4',
  'Klasik 4×4 · 3\'lü': 'Classic 4×4 · 3 in a row',
  'Klasik 4×4 · 4\'lü': 'Classic 4×4 · 4 in a row',
  '3\'lü': '3 in a row',
  '4\'lü': '4 in a row',

  // ---- tutorial.dart: rules placeholder and course screen chrome
  'Kurallar yakında.': 'Rules coming soon.',
  'Bu eğitim yakında.': 'This course is coming soon.',
  'Bitir': 'Finish',
  'Kurallar': 'How to play',
  'Orta seviye': 'Intermediate',
  'İleri seviye': 'Advanced',
  'Temel taktikler': 'Core tactics',
  'Usta teknikleri': 'Expert techniques',
};
