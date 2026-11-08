import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'games/batak_view.dart';
import 'games/blackjack_view.dart';
import 'games/block_grid_view.dart';
import 'games/blof_view.dart';
import 'games/change_spot_view.dart';
import 'games/color_gates_view.dart';
import 'games/corridor_view.dart';
import 'games/corsi_view.dart';
import 'games/crowns_view.dart';
import 'games/digit_span_view.dart';
import 'games/falling_blocks_view.dart';
import 'games/gem_merge_view.dart';
import 'games/gonogo_view.dart';
import 'games/hanoi_view.dart';
import 'games/iq_view.dart';
import 'games/math_view.dart';
import 'games/morris_view.dart';
import 'games/nback_view.dart';
import 'games/okey_view.dart';
import 'games/pairs_view.dart';
import 'games/palace_view.dart';
import 'games/push_view.dart';
import 'games/rsvp_view.dart';
import 'games/scene_quiz_view.dart';
import 'games/schulte_view.dart';
import 'games/shikaku_view.dart';
import 'games/soroban_view.dart';
import 'games/stroop_view.dart';
import 'games/sudoku_view.dart';
import 'games/sun_moon_view.dart';
import 'games/surakarta_view.dart';
import 'games/task_switch_view.dart';
import 'games/tracking_view.dart';
import 'games/trail_view.dart';
import 'games/verbal_social_view.dart';
import 'games/water_sort_view.dart';
import 'games/word_list_view.dart';
import 'tutorial.dart';
import 'tutorials/batak.dart';
import 'tutorials/blackjack.dart';
import 'tutorials/block_grid.dart';
import 'tutorials/blof.dart';
import 'tutorials/change_spot.dart';
import 'tutorials/color_gates.dart';
import 'tutorials/corridor.dart';
import 'tutorials/corsi.dart';
import 'tutorials/crowns.dart';
import 'tutorials/digit_span.dart';
import 'tutorials/falling_blocks.dart';
import 'tutorials/gem_merge.dart';
import 'tutorials/gonogo.dart';
import 'tutorials/hanoi.dart';
import 'tutorials/iq.dart';
import 'tutorials/math.dart';
import 'tutorials/morris.dart';
import 'tutorials/nback.dart';
import 'tutorials/okey.dart';
import 'tutorials/pairs.dart';
import 'tutorials/palace.dart';
import 'tutorials/push.dart';
import 'tutorials/rsvp.dart';
import 'tutorials/scene_quiz.dart';
import 'tutorials/schulte.dart';
import 'tutorials/shikaku.dart';
import 'tutorials/soroban.dart';
import 'tutorials/stroop.dart';
import 'tutorials/sudoku.dart';
import 'tutorials/sun_moon.dart';
import 'tutorials/surakarta.dart';
import 'tutorials/task_switch.dart';
import 'tutorials/tracking.dart';
import 'tutorials/trail.dart';
import 'tutorials/verbal_social.dart';
import 'tutorials/water_sort.dart';
import 'tutorials/word_list.dart';

typedef GameViewBuilder = Widget Function(
    BuildContext context, GameSession session);

/// Declaration order is the hub's section order.
enum GameCategory {
  strategy('Strateji'),
  memory('Hafıza'),
  attention('Dikkat'),
  logic('Mantık bulmacaları'),
  mind('Zihin antrenmanı'),
  cards('Kıraathane oyunları'),
  cube('Zeka küpü');

  final String label;
  const GameCategory(this.label);
}

/// A table/opponent setting for match-style games (card games): the home screen lists these instead of
/// levels; the id is passed to the core as `mode`.
class MatchMode {
  final String id;
  final String label;
  final String description;
  const MatchMode(this.id, this.label, this.description);
}

/// One section of a game page that hosts several games (Mental Aritmetik: Sprint and Soroban). Each
/// section is a full game of its own ([gameId], with its own levels, stars and tutorials).
class GameSection {
  final String label;
  final String gameId;
  const GameSection(this.label, this.gameId);
}

class GameInfo {
  final String id;
  final String name;
  final String tagline;
  final String glyph;
  final Color? tint;
  final GameCategory category;
  final bool hasLevels;
  final bool hasEndless;
  final String endlessLabel;
  final GameViewBuilder? view;
  final GameTutorials tutorials;

  /// Non-empty for match-style games: shown instead of the level grid (implies no levels).
  final List<MatchMode> matchModes;

  /// Games that run outside the Rust core (Küp) open their own screen.
  final WidgetBuilder? customHome;

  /// The hub card's second line for a [customHome] game.
  final String? cardLine;

  /// False for a game that is reached only as a [sections] entry of another game's page (Soroban
  /// inside Mental Aritmetik): no hub card, never in the daily mix.
  final bool inHub;

  /// Non-empty when the game page switches between several games (the first is usually this one).
  final List<GameSection> sections;

  /// A quick solo game listed under Strateji after the board duels (the former "Hız ve uzay"
  /// section: Düşen Bloklar, Blok Merkezi, Mücevher Birleştir).
  final bool speed;

  const GameInfo({
    required this.id,
    required this.name,
    required this.tagline,
    required this.glyph,
    required this.category,
    this.tint,
    this.hasLevels = true,
    this.hasEndless = false,
    this.endlessLabel = 'Sonsuz mod',
    this.view,
    this.tutorials = GameTutorials.empty,
    this.matchModes = const [],
    this.customHome,
    this.cardLine,
    this.inHub = true,
    this.sections = const [],
    this.speed = false,
  });
}

/// Every game the Rust core runs. The hub adds Küp, which has its own screens.
const List<GameInfo> kCoreGames = [
  GameInfo(
      id: 'sudoku',
      name: 'Sudoku',
      tagline: 'Tek çözümlü, teknikle derecelenmiş',
      glyph: '9',
      tint: Color(0xFFB08A2E),
      category: GameCategory.logic,
      view: sudokuView,
      tutorials: sudokuTutorials),
  GameInfo(
      id: 'crowns',
      name: 'Taçlar',
      tagline: 'Her satır, sütun ve bölgede bir taç',
      glyph: '♛',
      tint: Color(0xFF8E3FB8),
      category: GameCategory.logic,
      view: crownsView,
      tutorials: crownsTutorials),
  GameInfo(
      id: 'sun_moon',
      name: 'Güneş & Ay',
      tagline: 'Denge, eşitlik ve zıtlık',
      glyph: '☾',
      tint: Color(0xFF2F6FCB),
      category: GameCategory.logic,
      view: sunMoonView,
      tutorials: sunMoonTutorials),
  GameInfo(
      id: 'shikaku',
      name: 'Shikaku',
      tagline: 'Izgarayı dikdörtgenlere böl',
      glyph: '▦',
      tint: Color(0xFFC0453A),
      category: GameCategory.logic,
      view: shikakuView,
      tutorials: shikakuTutorials),
  GameInfo(
      id: 'water_sort',
      name: 'Renk Tüpleri',
      tagline: 'Sıvıları renklerine ayır',
      glyph: '◈',
      tint: Color(0xFF1E9FB0),
      category: GameCategory.logic,
      view: waterSortView,
      tutorials: waterSortTutorials),
  GameInfo(
      id: 'hanoi',
      name: 'Hanoi Kuleleri',
      tagline: 'Özyinelemenin en saf hâli',
      glyph: 'H',
      tint: Color(0xFFB8682E),
      category: GameCategory.logic,
      view: hanoiView,
      tutorials: hanoiTutorials),
  GameInfo(
      id: 'iq',
      name: 'IQ Soruları',
      tagline: 'Matris, dizi, küp, mantık: 1000 soru, puan yok, sadece keyif',
      glyph: 'IQ',
      tint: Color(0xFF3B4FA0),
      category: GameCategory.logic,
      hasEndless: true,
      endlessLabel: 'Karışık',
      view: iqView,
      tutorials: iqTutorials),
  GameInfo(
      id: 'verbal_social',
      name: 'Sözel ve Sosyal Zeka',
      tagline: 'Kelimeler, insanlar ve duygular: 450 soru',
      glyph: 'Söz',
      tint: Color(0xFF4B3F8F),
      category: GameCategory.logic,
      hasEndless: true,
      endlessLabel: 'Karışık',
      view: verbalSocialView,
      tutorials: verbalSocialTutorials),
  GameInfo(
      id: 'falling_blocks',
      name: 'Düşen Bloklar',
      tagline: 'Satırları tamamla, kuyuyu boşalt',
      glyph: '▙',
      tint: Color(0xFFD98B2B),
      category: GameCategory.strategy,
      speed: true,
      hasEndless: true,
      endlessLabel: 'Maraton',
      view: fallingBlocksView,
      tutorials: fallingBlocksTutorials),
  GameInfo(
      id: 'block_grid',
      name: 'Blok Merkezi',
      tagline: '9×9: satır, sütun ve kare temizle',
      glyph: '▣',
      tint: Color(0xFF3A3A4A),
      category: GameCategory.strategy,
      speed: true,
      hasEndless: true,
      view: blockGridView,
      tutorials: blockGridTutorials),
  GameInfo(
      id: 'gem_merge',
      name: 'Mücevher Birleştir',
      tagline: 'Aynı taşlar birleşip büyür',
      glyph: '◆',
      tint: Color(0xFFC2457A),
      category: GameCategory.strategy,
      speed: true,
      hasEndless: true,
      view: gemMergeView,
      tutorials: gemMergeTutorials),
  GameInfo(
      id: 'math',
      name: 'Mental Aritmetik',
      tagline: 'Hızlı işlem ve pratik hileler',
      glyph: '∑',
      tint: Color(0xFF2E8F66),
      category: GameCategory.mind,
      hasEndless: true,
      endlessLabel: 'Sprint (60 sn)',
      sections: [GameSection('Sprint', 'math'), GameSection('Soroban', 'soroban')],
      view: mathView,
      tutorials: mathTutorials),
  GameInfo(
      id: 'nback',
      name: 'N-Back',
      tagline: 'Çalışma belleği antrenmanı',
      glyph: 'N',
      tint: Color(0xFF3E4FB5),
      category: GameCategory.memory,
      hasEndless: true,
      endlessLabel: 'İkili N-Back (uyarlanır)',
      view: nbackView,
      tutorials: nbackTutorials),
  GameInfo(
      id: 'schulte',
      name: 'Schulte Tablosu',
      tagline: 'Sırayla bul: görsel tarama ve odak',
      glyph: '25',
      tint: Color(0xFF4F8A3C),
      category: GameCategory.attention,
      view: schulteView,
      tutorials: schulteTutorials),
  GameInfo(
      id: 'stroop',
      name: 'Renk–Kelime',
      tagline: 'Okuma, rengini seç',
      glyph: 'Aa',
      tint: Color(0xFFB83A5A),
      category: GameCategory.attention,
      hasEndless: true,
      endlessLabel: 'Sprint (60 sn)',
      view: stroopView,
      tutorials: stroopTutorials),
  GameInfo(
      id: 'tracking',
      name: 'Çoklu Takip',
      tagline: 'Gözünü ayırmadan izle',
      glyph: '◎',
      tint: Color(0xFF3A8FB8),
      category: GameCategory.attention,
      view: trackingView,
      tutorials: trackingTutorials),
  GameInfo(
      id: 'gonogo',
      name: 'Dur ya da Geç',
      tagline: 'Hızlı karar, sağlam fren',
      glyph: '→',
      tint: Color(0xFFC27A2E),
      category: GameCategory.attention,
      hasEndless: true,
      endlessLabel: 'Sonsuz akış',
      view: gonogoView,
      tutorials: gonogoTutorials),
  GameInfo(
      id: 'color_gates',
      name: 'Renk Kapıları',
      tagline: 'Düşen diskleri doğru kapıya al',
      glyph: '≡',
      tint: Color(0xFF6A3FB8),
      category: GameCategory.attention,
      hasEndless: true,
      endlessLabel: 'Sonsuz yağmur',
      view: colorGatesView,
      tutorials: colorGatesTutorials),
  GameInfo(
      id: 'palace',
      name: 'Hafıza Sarayı',
      tagline: 'Duraklara yerleştir, sırayla hatırla',
      glyph: '⌂',
      tint: Color(0xFF9A7A2E),
      category: GameCategory.memory,
      view: palaceView,
      tutorials: palaceTutorials),
  GameInfo(
      id: 'digit_span',
      name: 'Sayı Dizisi',
      tagline: 'İleri ve geri rakam belleği',
      glyph: '7',
      tint: Color(0xFF2E6F8F),
      category: GameCategory.memory,
      hasEndless: true,
      endlessLabel: 'Uyarlanır (kapasite testi)',
      view: digitSpanView,
      tutorials: digitSpanTutorials),
  GameInfo(
      id: 'corsi',
      name: 'Corsi Blokları',
      tagline: 'Yanan sırayı tekrarla',
      glyph: '◧',
      tint: Color(0xFF8F3E2E),
      category: GameCategory.memory,
      hasEndless: true,
      endlessLabel: 'Uyarlanır (kapasite testi)',
      view: corsiView,
      tutorials: corsiTutorials),
  GameInfo(
      id: 'pairs',
      name: 'Eşleştirme',
      tagline: 'Kartların yerini aklında tut',
      glyph: '❖',
      tint: Color(0xFF2E8F7A),
      category: GameCategory.memory,
      view: pairsView,
      tutorials: pairsTutorials),
  GameInfo(
      id: 'corridor',
      name: 'Duvar Yarışı',
      tagline: 'Yolunu aç, rakibininkini uzat',
      glyph: '▥',
      tint: Color(0xFF5E6B2E),
      category: GameCategory.strategy,
      view: corridorView,
      tutorials: corridorTutorials),
  GameInfo(
      id: 'push',
      name: 'İtiş',
      tagline: 'Bilyeleri it, rakibi tahtadan düşür',
      glyph: '⬢',
      tint: Color(0xFF4A4F9A),
      category: GameCategory.strategy,
      view: pushView,
      tutorials: pushTutorials),
  GameInfo(
      id: 'soroban',
      name: 'Soroban',
      tagline: 'Japon abaküsü: boncukla hesap, zihinde anzan',
      glyph: '珠',
      tint: Color(0xFF8A4A2B),
      category: GameCategory.mind,
      inHub: false,
      view: sorobanView,
      tutorials: sorobanTutorials),
  GameInfo(
      id: 'task_switch',
      name: 'Görev Değiştirme',
      tagline: 'Kural değişir, sen de değiş',
      glyph: '⇄',
      tint: Color(0xFF2E7A6F),
      category: GameCategory.attention,
      hasEndless: true,
      endlessLabel: 'Sprint (60 sn)',
      view: taskSwitchView,
      tutorials: taskSwitchTutorials),
  GameInfo(
      id: 'trail',
      name: 'İz Sürme',
      tagline: '1-A-2-B-3-C: iki diziyi ör',
      glyph: '↯',
      tint: Color(0xFF7A6A2E),
      category: GameCategory.attention,
      view: trailView,
      tutorials: trailTutorials),
  GameInfo(
      id: 'rsvp',
      name: 'Hızlı Akış',
      tagline: 'Akan harflerde hedefleri yakala',
      glyph: '»',
      tint: Color(0xFF9A3E6A),
      category: GameCategory.attention,
      view: rsvpView,
      tutorials: rsvpTutorials),
  GameInfo(
      id: 'change_spot',
      name: 'Değişimi Yakala',
      tagline: 'Neyin değiştiğini bul',
      glyph: '◐',
      tint: Color(0xFF3E7A9A),
      category: GameCategory.attention,
      view: changeSpotView,
      tutorials: changeSpotTutorials),
  GameInfo(
      id: 'scene_quiz',
      name: 'Sahne Hafızası',
      tagline: 'Bak, aklında tut, soruları cevapla',
      glyph: '◫',
      tint: Color(0xFFA0662E),
      category: GameCategory.memory,
      view: sceneQuizView,
      tutorials: sceneQuizTutorials),
  GameInfo(
      id: 'word_list',
      name: 'Kelime Listesi',
      tagline: 'Gör, bekle, hatırla',
      glyph: '¶',
      tint: Color(0xFF4E6E3A),
      category: GameCategory.memory,
      view: wordListView,
      tutorials: wordListTutorials),
  GameInfo(
      id: 'batak',
      name: 'Batak',
      tagline: 'İhale, koz ve el sayma',
      glyph: 'B',
      tint: Color(0xFF2E4A8F),
      category: GameCategory.cards,
      hasLevels: false,
      matchModes: [
        MatchMode('easy', 'Kolay',
            'Rakipler temel kurallarla, bazen dikkatsiz oynar.'),
        MatchMode('normal', 'Orta', 'Rakipler kart sayar, mantıklı oynar.'),
        MatchMode(
            'hard', 'Zor', 'Güçlü rakipler: olasılık hesabı ve derin arama.'),
        MatchMode('impossible', 'İmkânsız',
            'Rakipler bütün kartları görür ve kusursuz oynar.'),
      ],
      view: batakView,
      tutorials: batakTutorials),
  GameInfo(
      id: 'okey',
      name: 'Okey',
      tagline: '101 ve klasik: per diz, işle, ilk sen bitir',
      glyph: 'Ok',
      tint: Color(0xFFB0802E),
      category: GameCategory.cards,
      hasLevels: false,
      // "Group · Table" labels: the game page shows a small header per group.
      matchModes: [
        MatchMode('101_easy', '101 · Kolay',
            'Rakipler açmayı bilir ama işlemeyi unutur, bazen ceza yer.'),
        MatchMode('101_normal', '101 · Orta',
            'Rakipler en iyi açılışı bulur, taş sayar, ceza yemez.'),
        MatchMode('101_hard', '101 · Zor',
            'Güçlü rakipler: bir çekiş ileriyi hesaplar, sağındakini besleme.'),
        MatchMode('101_impossible', '101 · İmkânsız',
            'Rakipler bütün rafları ve destenin sırasını görür.'),
        MatchMode('easy', 'Klasik · Kolay',
            'Rakipler temel kurallarla, bazen dikkatsiz oynar.'),
        MatchMode('normal', 'Klasik · Orta',
            'Rakipler kart sayar, mantıklı oynar.'),
        MatchMode('hard', 'Klasik · Zor',
            'Güçlü rakipler: olasılık hesabı ve derin arama.'),
        MatchMode('impossible', 'Klasik · İmkânsız',
            'Rakipler bütün kartları görür ve kusursuz oynar.'),
      ],
      view: okeyView,
      tutorials: okeyTutorials),
  GameInfo(
      id: 'blof',
      name: 'Blöf',
      tagline: 'Yalanı yakala, kendininkini sakla',
      glyph: '?',
      tint: Color(0xFF8F2E5A),
      category: GameCategory.cards,
      hasLevels: false,
      matchModes: [
        MatchMode('easy', 'Kolay',
            'Rakipler temel kurallarla, bazen dikkatsiz oynar.'),
        MatchMode('normal', 'Orta', 'Rakipler kart sayar, mantıklı oynar.'),
        MatchMode(
            'hard', 'Zor', 'Güçlü rakipler: olasılık hesabı ve derin arama.'),
        MatchMode('impossible', 'İmkânsız',
            'Rakipler bütün kartları görür ve kusursuz oynar.'),
      ],
      view: blofView,
      tutorials: blofTutorials),
  GameInfo(
      id: 'blackjack',
      name: '21',
      tagline: 'Krupiyeye karşı: temel strateji ve kart sayma',
      glyph: '21',
      tint: Color(0xFF1F6B45),
      category: GameCategory.cards,
      hasLevels: false,
      matchModes: [
        MatchMode('classic', 'Klasik masa',
            '6 deste, krupiye 17\'de durur. Kendi stratejinle oyna.'),
        MatchMode('coach', 'Koç',
            'Her karardan sonra temel stratejiye göre doğru hamle ve nedeni.'),
        MatchMode('count', 'Kart sayma',
            'Hi-Lo sayımı: masada say, ara ara sayını sorar.'),
        MatchMode('open', 'Açık deste',
            'Sıradaki kartları ve krupiyenin kapalı kartını görürsün.'),
      ],
      view: blackjackView,
      tutorials: blackjackTutorials),
  GameInfo(
      id: 'morris',
      name: 'Cırtcak',
      tagline: '9 taş: değirmen kur, rakibin taşını al',
      glyph: '⊡',
      tint: Color(0xFF8A5A2B),
      category: GameCategory.strategy,
      view: morrisView,
      tutorials: morrisTutorials),
  GameInfo(
      id: 'surakarta',
      name: 'Surakarta',
      tagline: 'Halkalardan dolaş, uzaktan vur',
      glyph: '∞',
      tint: Color(0xFF2E7F8F),
      category: GameCategory.strategy,
      view: surakartaView,
      tutorials: surakartaTutorials),
];

/// The core game with [id], or null.
GameInfo? coreGame(String id) {
  for (final g in kCoreGames) {
    if (g.id == id) return g;
  }
  return null;
}
