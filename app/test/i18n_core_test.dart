// English for the Rust core's text (lib/clever/i18n/en_core.dart, built by tool/i18n/core_strings.py).
// The inputs are lines the core really writes, filled in by hand from its format strings.

import 'package:clever_place/clever/i18n/en_core.dart';
import 'package:clever_place/clever/i18n/lang.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ct() in English', () {
    setUp(() => Lang.en = true);
    tearDown(() => Lang.en = false);

    const cases = <String, String>{
      // exact lines
      'Bilinmeyen hamle': 'Unknown move',
      'Bölüm bitti': 'Level over',
      'Üstat': 'Maestro',
      'T-dönüş mini ikili': 'T-spin mini double',
      'Önce eşyaları yerleştir': 'Place the items first',
      // sudoku: refusal, goal, summary, hint (hole words translated too)
      'Bu satırda zaten 5 var': 'This row already has a 5',
      'Her satır, sütun ve kutuda 1–9 birer kez · 28 ipucu': '1–9 once in every row, column and box · 28 clues',
      'Hata: 2 · İpucu: 1 · Süre: 4:05 · En zor teknik: Gizli tekli':
          'Mistakes: 2 · Hints: 1 · Time: 4:05 · Hardest technique: Hidden single',
      'Gizli tekli: 7 rakamı 3. satırda yalnız (3,5) hücresine gelebilir':
          'Hidden single: in row 3, 7 can only go in cell (3,5)',
      // crowns
      '8×8 · Çift taç': '8×8 · Two crowns',
      'Her satır, sütun ve bölgeye 2 taç · taçlar birbirine değmez':
          '2 crowns in every row, column and region · crowns never touch',
      'Son yer: Safir bölge için tek aday hücre kaldı: (4,2)':
          'Last spot: Sapphire region has only one candidate cell left: (4,2)',
      // sun & moon: the sun/moon words come through holes
      'Çift kuralı — 3. satır: yan yana iki güneş var; üçüncüsü gelemez, bu hücre ay.':
          "Pair rule — row 3: two suns side by side; a third can't follow, this cell is moon.",
      // other games
      'Hamle: 12 · Hedef: 10 · ek tüp': 'Moves: 12 · Target: 10 · extra tube',
      'Bütün diskleri 3. direğe taşı. En az hamle: 7': 'Move all disks to peg 3. Fewest moves: 7',
      "3 oyunluk maç · 4'lü çizgi kur": '3-game match · make a line of 4',
      'Skor 2–1 · 0 berabere': 'Score 2–1 · 0 draws',
      'Rakibin 2 taşa indi · Kalan taşın: 5 · Hamle: 23':
          'Your opponent is down to 2 pieces · Your pieces left: 5 · Moves: 23',
      'Kozla kesti (Kupa)': 'Trumped (Hearts)',
      'Stroop etkisi 85 ms': 'Stroop effect 85 ms',
      'Doğru 9/10 · %90 · Ort. yerleştirme 4.2 sn': 'Correct 9/10 · 90% · Avg. placing 4.2 s',
      '12 mesaj · en az 9 doğru': '12 messages · at least 9 correct',
      // language-bound content stays Turkish
      'Kerem': 'Kerem',
      'Soldan 2. sandalyede kim oturuyor?': 'Soldan 2. sandalyede kim oturuyor?',
    };
    for (final c in cases.entries) {
      test(c.key, () => expect(ct(c.key), c.value));
    }

    // A " · "-joined line whose first part fits a short template ("Ort. {} ms") is caught whole by
    // that template, because a hole also matches " · ". Needs CoreTemplate holes not to cross " · "
    // when the Turkish template has none (lang.dart).
    test('joined parts each translated', () {
      expect(ct('Doğru 8/10 · Ort. 412 ms · Stroop etkisi 85 ms'), 'Correct 8/10 · Avg. 412 ms · Stroop effect 85 ms');
    });

    test('null and empty', () {
      expect(ct(null), '');
      expect(ct(''), '');
    });
  });

  test('ct() returns the input unchanged in Turkish', () {
    Lang.en = false;
    for (final s in ['Bilinmeyen hamle', 'Bu satırda zaten 5 var', 'Hamle: 12 · Hedef: 10 · ek tüp']) {
      expect(ct(s), s);
    }
  });

  test('no template is only holes, no exact key is empty', () {
    final hole = RegExp(r'\{\d*\}');
    for (final (tr, en) in enCoreTemplates) {
      expect(tr.replaceAll(hole, '').trim(), isNotEmpty, reason: tr);
      expect(hole.hasMatch(tr), isTrue, reason: 'template without a hole: $tr');
      expect(en, isNotEmpty, reason: tr);
    }
    for (final e in enCoreExact.entries) {
      expect(e.key, isNotEmpty);
      expect(e.value, isNotEmpty, reason: e.key);
    }
  });
}
