// The promo video's clips, in order. Each game runs at a hard level in the real play shell and is
// played by a small driver: mostly the core's own hints, or answers worked out from the state.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:clever_place/clever/catalog.dart';
import 'package:clever_place/clever/core_bridge.dart';
import 'package:clever_place/clever/cube/cube_book_screen.dart';
import 'package:clever_place/clever/cube/cube_home_screen.dart';
import 'package:clever_place/clever/cube/cube_style.dart';
import 'package:clever_place/clever/cube/cube_timer_page.dart';
import 'package:clever_place/clever/game_home_screen.dart';
import 'package:clever_place/clever/hub_screen.dart';
import 'package:clever_place/clever/lux.dart';

import 'stage.dart';

const _logic = 'Mantık';
const _strategy = 'Strateji';
const _memory = 'Hafıza';
const _attention = 'Dikkat';
const _mind = 'Zihin antrenmanı';

int _i(Object? v) => (v as num).toInt();
List _l(Object? v) => (v as List?) ?? const [];

/// The right option of the question a quiz game shows now: replays [done] on a second session of
/// the same level, answers, and reads what the core says was right.
int _rightAnswer(String game, int level, List<Map<String, dynamic>> done) {
  final r = Core.call({'op': 'new', 'game': game, 'level': level, 'mode': 'level'});
  final id = _i(r['id']);
  Map<String, dynamic> last = r;
  for (final a in [...done, {'answer': 0}]) {
    last = Core.call({'op': 'act', 'id': id, 'action': a});
  }
  Core.call({'op': 'drop', 'id': id});
  final l = (last['state'] as Map)['last'];
  return l is Map ? _i(l['answer']) : 0;
}

Future<void> _start(Stage s, bool Function() running, {double max = 8}) async {
  s.act({'start': true});
  await s.skipUntil(running, max: max);
}

/// A board duel: the core's hint plays our side, the view makes the opponent move. [warm] of our
/// moves are played unrecorded first so the clip opens on a developed position.
Future<void> _duel(Stage s, {required int warm, required double seconds, required List<Map<String, dynamic>> Function(Map st, Map hint) moves}) async {
  var mine = 0;
  var wait = 0;
  Future<void> turn(bool rec) async {
    final st = s.st;
    if (st['status'] != 'playing') return;
    if (st['phase'] is String && st['phase'] != 'play' && st['phase'] != 'place' && st['phase'] != 'move' && st['phase'] != 'fly') {
      if (++wait > (rec ? 40 : 4)) {
        wait = 0;
        s.act({'next': true});
      }
      return;
    }
    if (st['turn'] == 'you' && st['ai_pending'] != true) {
      if (++wait < (rec ? 16 : 2)) return;
      wait = 0;
      if (!s.act({'hint': true})) return;
      final h = s.st['hint'];
      if (h is! Map) return;
      if (rec) await s.frames(7);
      for (final m in moves(s.st, h)) {
        s.act(m);
      }
      mine++;
    }
  }

  for (var i = 0; i < 4000 && mine < warm && s.st['status'] == 'playing'; i++) {
    await turn(false);
    await s.step(false);
  }
  final n = (seconds * Stage.fps).round();
  final at = s.lastFrames;
  while (s.lastFrames - at < n) {
    await turn(true);
    await s.frames(1);
  }
}

List<Scene> buildScenes() => [
      // ---------------------------------------------------------------- opening
      Scene('intro', '', '', full: true, (s) async {
        await s.show(const _Intro());
        await s.secs(2.8);
      }),
      Scene('hub', 'Clever Place', 'Her gün beş oyun', (s) async {
        await s.show(const HubScreen());
        await s.secs(2.2);
        final c = Offset(Stage.w / 2, 430);
        for (var k = 0; k < 5; k++) {
          await s.drag(c, c.translate(0, -330), n: 15);
          await s.secs(0.35);
        }
        await s.secs(0.5);
      }),
      Scene('levels', 'Her oyunun sayfası', '500 bölüm, dört zorluk', (s) async {
        // The game page as it opens: rules behind "Nasıl oynanır", the tier's next level pinned below.
        await s.show(GameHomeScreen(game: kCoreGames.firstWhere((g) => g.id == 'schulte')));
        await s.secs(2.4);
        final c = Offset(Stage.w / 2, 420);
        await s.drag(c, c.translate(0, -200), n: 16);
        await s.secs(1.2);
        await s.tap(find.byKey(const ValueKey('play-next')));
        await s.secs(0.6);
      }),
      Scene('schulte', _attention, 'Schulte Tablosu · Bölüm 300', (s) async {
        await s.play('schulte', 300);
        await _start(s, () => s.st['phase'] == 'run');
        await s.secs(0.7);
        Future<bool> tapNext() async {
          final cells = _l(s.st['cells']);
          final nx = s.st['next'];
          if (nx is! Map) return false;
          final i = cells.indexWhere((c) => c is Map && c['label'] == nx['label'] && c['color'] == nx['color'] && c['found'] != true);
          if (i < 0) return false;
          s.act({'tap': i});
          return true;
        }

        for (var k = 0; k < 12 && s.st['status'] == 'playing'; k++) {
          if (!await tapNext()) break;
          await s.frames(8);
        }
        // The rest of the table off camera, at a human pace, then the level's end.
        for (var k = 0; k < 200 && s.st['status'] == 'playing'; k++) {
          if (!await tapNext()) break;
          for (var f = 0; f < 20; f++) {
            await s.step(false);
          }
        }
        // ignore: avoid_print
        print('schulte time: ${s.st['elapsed_ms']} errors: ${s.st['errors']} stars: ${s.st['stars']}');
        await s.skip(1.1);
        await s.secs(4.6);
      }),

      // ---------------------------------------------------------------- Mantık
      Scene('sudoku', _logic, 'Sudoku', (s) async {
        await s.play('sudoku', 300);
        s.act({'fill_notes': true});
        await s.secs(0.8);
        for (var k = 0; k < 6; k++) {
          if (!s.act({'hint': true})) break;
          final h = s.st['hint'] as Map;
          await s.frames(10);
          if (h['cell'] != null && h['digit'] != null && _i(_l(s.st['values'])[_i(h['cell'])]) == 0) {
            s.act({'set': h['cell'], 'digit': h['digit']});
          }
          await s.frames(7);
        }
        await s.secs(0.4);
      }),
      Scene('crowns', _logic, 'Taçlar', (s) async {
        await s.play('crowns', 300);
        await s.secs(0.6);
        for (var k = 0; k < 9; k++) {
          if (!s.act({'hint': true})) break;
          final h = s.st['hint'] as Map;
          await s.frames(8);
          final xs = _l(h['xs']);
          if (xs.isNotEmpty) s.act({'drag': xs, 'mark': 'x'});
          for (final c in _l(h['crowns'])) {
            for (var t = 0; t < 3 && _i(_l(s.st['marks'])[_i(c)]) != 2; t++) {
              s.act({'cycle': c});
            }
          }
          for (final c in _l(h['clear'])) {
            for (var t = 0; t < 3 && _i(_l(s.st['marks'])[_i(c)]) != 0; t++) {
              s.act({'cycle': c});
            }
          }
          await s.frames(5);
        }
        await s.secs(0.4);
      }),
      Scene('sun_moon', _logic, 'Güneş & Ay', (s) async {
        await s.play('sun_moon', 300);
        await s.secs(0.6);
        for (var k = 0; k < 10; k++) {
          if (!s.act({'hint': true})) break;
          final h = s.st['hint'] as Map;
          await s.frames(6);
          for (var t = 0; t < 3 && _i(_l(s.st['cells'])[_i(h['cell'])]) != _i(h['value']); t++) {
            s.act({'cycle': h['cell']});
          }
          await s.frames(5);
        }
        await s.secs(0.4);
      }),
      Scene('shikaku', _logic, 'Shikaku', (s) async {
        await s.play('shikaku', 300);
        await s.secs(0.6);
        for (var k = 0; k < 12; k++) {
          if (!s.act({'hint': true})) break;
          final h = s.st['hint'] as Map;
          final q = _l(h['rect']);
          await s.frames(4);
          // The hint usually lays the rectangle itself.
          final placed = _l(s.st['rects']).any((r) => r is Map && r['r0'] == q[0] && r['c0'] == q[1] && r['r1'] == q[2] && r['c1'] == q[3]);
          if (!placed) s.act({'place': q});
          await s.frames(5);
        }
        await s.secs(0.5);
      }),
      Scene('water_sort', _logic, 'Renk Tüpleri', (s) async {
        await s.play('water_sort', 300);
        await s.secs(0.5);
        for (var k = 0; k < 7; k++) {
          if (!s.act({'hint': true})) break;
          final h = _l(s.st['hint']);
          await s.frames(5);
          s.act({'from': h[0], 'to': h[1]});
          await s.frames(13);
        }
        await s.secs(0.3);
      }),
      Scene('hanoi', _logic, 'Hanoi Kuleleri', (s) async {
        await s.play('hanoi', 420);
        await s.secs(0.5);
        for (var k = 0; k < 10; k++) {
          if (!s.act({'hint': true})) break;
          final h = _l(s.st['hint']);
          await s.frames(3);
          s.act({'from': h[0], 'to': h[1]});
          await s.frames(9);
        }
        await s.secs(0.3);
      }),
      Scene('iq', _logic, 'IQ Soruları', (s) async {
        await s.play('iq', 50);
        final done = <Map<String, dynamic>>[];
        for (var q = 0; q < 2; q++) {
          await s.secs(q == 0 ? 1.7 : 1.3);
          final a = {'answer': _rightAnswer('iq', 50, done)};
          s.act(a);
          done.add(a);
          await s.secs(1.0);
          if (q == 0) {
            s.act({'next': true});
            done.add({'next': true});
          }
        }
      }),
      Scene('verbal_social', _logic, 'Sözel ve Sosyal Zeka', (s) async {
        await s.play('verbal_social', 45);
        await s.secs(2.2);
        s.act({'answer': _rightAnswer('verbal_social', 45, const [])});
        await s.secs(1.6);
      }),

      // ---------------------------------------------------------------- Strateji
      Scene('corridor', _strategy, 'Duvar Yarışı', (s) async {
        await s.play('corridor', 301);
        await _duel(s, warm: 9, seconds: 4.6, moves: (st, h) => [
              h['kind'] == 'wall' ? {'wall': h['wall']} : {'to': h['to']}
            ]);
      }),
      Scene('push', _strategy, 'İtiş', (s) async {
        await s.play('push', 301);
        await _duel(s, warm: 10, seconds: 4.6, moves: (st, h) => [
              {'line': h['line'], 'dir': h['dir']}
            ]);
      }),
      Scene('morris', _strategy, 'Cırtcak', (s) async {
        await s.play('morris', 301);
        await _duel(s, warm: 8, seconds: 4.6, moves: (st, h) => [
              if (st['pending_remove'] == true)
                {'remove': h['remove']}
              else if (h['from'] != null)
                {'from': h['from'], 'to': h['to']}
              else
                {'place': h['to']},
              if (st['pending_remove'] != true && h['remove'] != null) {'remove': h['remove']}
            ]);
      }),
      Scene('surakarta', _strategy, 'Surakarta', (s) async {
        await s.play('surakarta', 301);
        await _duel(s, warm: 7, seconds: 4.8, moves: (st, h) => [
              {'from': h['from'], 'to': h['to']}
            ]);
      }),
      Scene('falling_blocks', _strategy, 'Düşen Bloklar', (s) async {
        await s.play('falling_blocks', 300);
        const cols = [-4, 3, -1, 5, -3, 1, 4, -5, 0, 2, -2, 5];
        // A few pieces unrecorded, so the well is not empty.
        for (var k = 0; k < cols.length; k++) {
          final rec = k >= 5;
          if (k == 5) await s.secs(0.3);
          final d = cols[k];
          for (var m = 0; m < d.abs(); m++) {
            s.act({'a': d < 0 ? 'l' : 'r'});
            await s.step(rec);
            if (rec) await s.frames(1);
          }
          if (k.isOdd) {
            s.act({'a': 'cw'});
            await s.step(rec);
            if (rec) await s.frames(2);
          }
          if (rec) await s.frames(3);
          s.act({'a': 'hd'});
          for (var m = 0; m < 6; m++) {
            await s.step(rec);
          }
        }
        await s.secs(0.4);
      }),
      Scene('block_grid', _strategy, 'Blok Merkezi', (s) async {
        await s.play('block_grid', 300);
        await s.secs(0.5);
        for (var k = 0; k < 6; k++) {
          final b = s.st['b'] as String;
          final n = math.sqrt(b.length).round();
          final tray = _l(s.st['tray']);
          Map<String, dynamic>? mv;
          var best = -1;
          for (var p = 0; p < tray.length; p++) {
            if (tray[p] is! Map) continue;
            final t = tray[p] as Map;
            if (t['f'] == false) continue;
            final c = _l(t['c']);
            for (var y = 0; y < n; y++) {
              for (var x = 0; x < n; x++) {
                var ok = true;
                var touch = 0;
                for (var q = 0; q < c.length && ok; q += 2) {
                  final cx = x + _i(c[q]), cy = y + _i(c[q + 1]);
                  if (cx >= n || cy >= n || b[cy * n + cx] != '0') {
                    ok = false;
                    break;
                  }
                  for (final d in const [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
                    final nx = cx + d[0], ny = cy + d[1];
                    if (nx < 0 || ny < 0 || nx >= n || ny >= n || b[ny * n + nx] != '0') touch++;
                  }
                }
                if (ok && touch > best) {
                  best = touch;
                  mv = {'p': p, 'x': x, 'y': y};
                }
              }
            }
          }
          if (mv == null) break;
          s.act({'a': 'pv', ...mv});
          await s.frames(7);
          s.act({'a': 'place', ...mv});
          await s.frames(11);
        }
        await s.secs(0.3);
      }),
      Scene('gem_merge', _strategy, 'Mücevher Birleştir', (s) async {
        await s.play('gem_merge', 300);
        await s.secs(0.5);
        final w = (s.st['w'] as num).toDouble();
        const xs = [0.2, 0.75, 0.45, 0.9, 0.1, 0.6, 0.3];
        for (final x in xs) {
          s.act({'a': 'drop', 'x': w * x});
          await s.frames(17);
        }
        await s.secs(0.5);
      }),

      // ---------------------------------------------------------------- Hafıza
      Scene('nback', _memory, 'N-Back', (s) async {
        await s.play('nback', 300);
        await _start(s, () => s.st['phase'] == 'run');
        // The first n numbers only fill the row: run them unrecorded, then answer for real.
        final n = _i(s.st['n']);
        final seen = <int, String>{};
        var answered = -1;
        Future<void> watch(bool rec) async {
          final t = _i(s.st['trial']);
          final stim = s.st['stim'];
          if (stim != null) {
            seen[t] = '$stim';
            if (rec && answered != t && seen[t - n] == seen[t] && s.st['can_match'] == true) {
              answered = t;
              await s.frames(9);
              s.act({'match': true});
            }
          }
          await s.step(rec);
        }

        for (var f = 0; f < 3000 && _i(s.st['trial']) < n + 1; f++) {
          await watch(false);
        }
        final at = s.lastFrames;
        while (s.lastFrames - at < 150) {
          await watch(true);
        }
      }),
      Scene('palace', _memory, 'Hafıza Sarayı', (s) async {
        await s.play('palace', 300);
        await s.secs(1.2);
        await _start(s, () => s.st['phase'] != 'countdown' && s.st['phase'] != 'intro');
        for (var k = 0; k < 3; k++) {
          await s.secs(1.2);
          s.act({'next': true});
        }
        await s.secs(0.8);
      }),
      Scene('digit_span', _memory, 'Sayı Dizisi', (s) async {
        await s.play('digit_span', 300);
        s.act({'start': true});
        // Note the symbols as they pass; the video joins at the third.
        final shown = <int, String>{};
        for (var f = 0; f < 900 && (s.st['phase'] == 'show' || s.st['phase'] == 'countdown' || s.st['phase'] == 'intro'); f++) {
          final sh = s.st['show'];
          if (sh is Map && sh['symbol'] != null) shown[_i(sh['index'])] = '${sh['symbol']}';
          await s.step(shown.length >= 3);
        }
        await s.secs(1.1);
        if (s.st['phase'] == 'distract') s.act({'judge': true});
        await s.secs(0.6);
        // Digits ascending, then letters in alphabet order: the order of the keypad.
        final keys = [for (final k in _l(s.st['keys'])) '$k'];
        final answer = shown.values.toList()..sort((a, b) => keys.indexOf(a).compareTo(keys.indexOf(b)));
        for (final k in answer) {
          if (!s.act({'key': k})) break;
          await s.frames(6);
        }
        s.act({'submit': true});
        await s.secs(0.9);
      }),
      Scene('corsi', _memory, 'Corsi Blokları', (s) async {
        await s.play('corsi', 300);
        await _start(s, () => s.st['phase'] == 'show' && s.st['lit'] != null);
        final seq = <int>[];
        var lastKey = -1;
        for (var f = 0; f < 400 && s.st['phase'] == 'show'; f++) {
          final lit = s.st['lit'];
          if (lit is Map && _i(lit['key']) != lastKey && lit['kind'] == 'target') {
            lastKey = _i(lit['key']);
            seq.add(_i(lit['block']));
          }
          // The video joins the sequence at its fourth block.
          await s.step(seq.length >= 4);
        }
        await s.framesUntil(() => s.st['phase'] == 'recall' || s.st['phase'] == 'input', max: 2);
        await s.frames(6);
        for (final b in seq) {
          s.act({'tap': b});
          await s.frames(6);
        }
        await s.secs(0.8);
      }),
      Scene('pairs', _memory, 'Eşleştirme', (s) async {
        await s.play('pairs', 300);
        await _start(s, () => s.st['phase'] == 'play');
        // Learn the faces on a second session of the same level.
        final r = Core.call({'op': 'new', 'game': 'pairs', 'level': 300, 'mode': 'level'});
        final id = _i(r['id']);
        Core.call({'op': 'act', 'id': id, 'action': {'start': true}});
        Map sh = Core.call({'op': 'tick', 'id': id, 'dt': 1.0})['state'] as Map;
        for (var t = 0; t < 400 && sh['phase'] != 'play'; t++) {
          sh = Core.call({'op': 'tick', 'id': id, 'dt': 50.0})['state'] as Map;
        }
        final n = _l(sh['cards']).length;
        final faces = <int, String>{};
        for (var p = 0; p < n; p++) {
          var a = Core.call({'op': 'act', 'id': id, 'action': {'flip': p}});
          if (a['ok'] != true) {
            Core.call({'op': 'act', 'id': id, 'action': {'close': true}});
            a = Core.call({'op': 'act', 'id': id, 'action': {'flip': p}});
          }
          final c = _l((a['state'] as Map)['cards'])[p] as Map;
          if (c['face'] != null) faces[p] = '${c['face']}';
          for (var t = 0; t < 60; t++) {
            Core.call({'op': 'tick', 'id': id, 'dt': 50.0});
          }
          Core.call({'op': 'act', 'id': id, 'action': {'close': true}});
        }
        Core.call({'op': 'drop', 'id': id});
        final groups = <String, List<int>>{};
        faces.forEach((p, f) => groups.putIfAbsent(f, () => []).add(p));
        final sets = groups.values.where((g) => g.length >= 2).toList();
        await s.secs(0.4);
        for (final g in sets.take(5)) {
          for (final p in g) {
            s.act({'flip': p});
            await s.frames(8);
          }
          await s.frames(6);
        }
        await s.secs(0.5);
      }),
      Scene('scene_quiz', _memory, 'Sahne Hafızası', (s) async {
        await s.play('scene_quiz', 300);
        await _start(s, () => s.st['phase'] == 'show');
        await s.secs(2.6);
        s.act({'ready': true});
        await s.skipUntil(() => s.st['phase'] == 'question', max: 9);
        await s.secs(1.4);
        s.act({'answer': _rightAnswerAfterShow()});
        await s.secs(1.2);
      }),
      Scene('word_list', _memory, 'Kelime Listesi', (s) async {
        await s.play('word_list', 300);
        await _start(s, () => s.st['phase'] == 'study');
        await s.secs(4.2);
      }),

      // ---------------------------------------------------------------- Dikkat
      Scene('stroop', _attention, 'Renk–Kelime', (s) async {
        await s.play('stroop', 300);
        await _start(s, () => s.st['phase'] == 'run');
        var seen = 0;
        Object? cur;
        for (var f = 0; f < 135; f++) {
          final stim = s.st['stim'];
          if (stim is Map && s.st['sub'] == 'stim') {
            if ('$stim' != cur) {
              cur = '$stim';
              seen = 0;
            }
            if (++seen == 16) {
              final colors = _l(s.st['colors']);
              final ans = stim['rule'] == 'ink' ? _i(stim['ink']) : colors.indexWhere((c) => (c as Map)['name'] == stim['word']);
              s.act({'answer': ans < 0 ? _i(stim['ink']) : ans});
            }
          }
          await s.frames(1);
        }
      }),
      Scene('tracking', _attention, 'Çoklu Takip', (s) async {
        await s.play('tracking', 300);
        await _start(s, () => s.st['phase'] == 'show');
        await s.secs(4.6);
      }),
      Scene('gonogo', _attention, 'Dur ya da Geç', (s) async {
        await s.play('gonogo', 300);
        await _start(s, () => s.st['phase'] == 'run');
        var seen = 0;
        Object? cur;
        const opp = {'up': 'down', 'down': 'up', 'left': 'right', 'right': 'left'};
        for (var f = 0; f < 140; f++) {
          final stim = s.st['stim'];
          if (stim is Map && s.st['stage'] == 'window') {
            if (stim['id'] != cur) {
              cur = stim['id'];
              seen = 0;
            }
            if (++seen == 12 && stim['shape'] == 'round') {
              final arrow = stim['arrow'];
              if (arrow is Map) {
                s.act({'swipe': arrow['color'] == 'burgundy' ? opp[arrow['dir']] : arrow['dir']});
              } else {
                s.act({'tap': true});
              }
            }
          }
          await s.frames(1);
        }
      }),
      Scene('color_gates', _attention, 'Renk Kapıları', (s) async {
        await s.play('color_gates', 300);
        await _start(s, () => s.st['phase'] == 'run' && _l(s.st['d']).length >= 3);
        for (var f = 0; f < 140; f++) {
          if (f % 3 == 0) {
            final gates = _l(s.st['gates']);
            // Per lane the disc closest to its gate; a ghost (flag bit 0) must meet another colour.
            final first = <int, List>{};
            for (final d in _l(s.st['d']).cast<List>()) {
              final lane = _i(d[1]);
              if (!first.containsKey(lane) || _i(d[4]) > _i(first[lane]![4])) first[lane] = d;
            }
            bool wrong(MapEntry<int, List> e) {
              final same = _i(gates[e.key]) == _i(e.value[2]);
              return _i(e.value[3]) & 1 == 1 ? same : !same;
            }

            final todo = first.entries.where(wrong).toList()..sort((a, b) => _i(b.value[4]).compareTo(_i(a.value[4])));
            if (todo.isNotEmpty) s.act({'tap': todo.first.key});
          }
          await s.frames(1);
        }
      }),
      Scene('task_switch', _attention, 'Görev Değiştirme', (s) async {
        await s.play('task_switch', 300);
        await _start(s, () => s.st['phase'] == 'run');
        var seen = 0;
        Object? cur;
        for (var f = 0; f < 135; f++) {
          final t = s.st['target'];
          if (t is Map && s.st['stage'] == 'target') {
            if ('$t${s.st['active_rule']}' != cur) {
              cur = '$t${s.st['active_rule']}';
              seen = 0;
            }
            if (++seen == 15) {
              final rule = (_l(s.st['rules'])[_i(s.st['active_rule'])] as Map)['key'];
              final d = _i(t['digit']);
              final ch = '${t['letter']}';
              final left = switch (rule) {
                'parity' => d.isOdd,
                'magnitude' => d < 5,
                'vowel' => 'aeıioöuüAEIİOÖUÜ'.contains(ch),
                _ => ch == ch.toLowerCase(),
              };
              s.act({'answer': left ? 'left' : 'right'});
            }
          }
          await s.frames(1);
        }
      }),
      Scene('trail', _attention, 'İz Sürme', (s) async {
        await s.play('trail', 300);
        await _start(s, () => s.st['phase'] == 'run');
        await s.secs(0.8);
        // The core tells only how far we are; find the order by trying on a second session.
        for (var k = 0; k < 13; k++) {
          final n = _l(s.st['circles']).length;
          final before = _i(s.st['next']);
          final order = _trailOrder(n, before);
          if (order == null) break;
          s.act({'tap': order});
          await s.frames(8);
        }
        await s.secs(0.4);
      }),
      Scene('rsvp', _attention, 'Hızlı Akış', (s) async {
        await s.play('rsvp', 300);
        await _start(s, () => s.st['phase'] == 'stream');
        final reds = <String>{};
        for (var f = 0; f < 200 && s.st['phase'] == 'stream'; f++) {
          final it = s.st['item'];
          if (it is Map && it['red'] == true) reds.add('${it['ch']}');
          await s.frames(1);
        }
        await s.secs(0.7);
        for (final o in _l(s.st['options'])) {
          if (reds.contains('$o')) {
            s.act({'pick': o});
            await s.frames(9);
          }
        }
        s.act({'submit': true});
        await s.secs(1.0);
      }),
      Scene('change_spot', _attention, 'Değişimi Yakala', (s) async {
        await s.play('change_spot', 300);
        await _start(s, () => s.st['phase'] == 'run');
        await s.secs(1.6);
        final a = _l((s.st['scene_a'] as Map)['items']), b = _l((s.st['scene_b'] as Map)['items']);
        for (var k = 0; k < a.length && k < b.length; k++) {
          if ('${a[k]}' == '${b[k]}') continue;
          final it = a[k] as Map;
          final x = (it['x'] as num).toDouble(), y = (it['y'] as num).toDouble();
          final w = (it['w'] as num).toDouble(), h = (it['h'] as num).toDouble();
          if (!s.act({'tap': {'x': x + w / 2, 'y': y + h / 2}})) s.act({'tap': {'x': x, 'y': y}});
          await s.secs(1.0);
        }
        await s.secs(0.4);
      }),

      // ---------------------------------------------------------------- Zihin antrenmanı
      Scene('donen_sayilar', _attention, 'Dönen Sayılar', (s) async {
        await s.play('donen_sayilar', 130);
        await _start(s, () => s.st['phase'] == 'run', max: 8);
        await s.secs(0.6);
        for (var k = 0; k < 9 && s.st['status'] == 'playing'; k++) {
          final want = _i(s.st['found']) + 1;
          final rings = _l(s.st['rings']);
          final n = _l(s.st['numbers']).cast<Map>().where((x) => _i(x['n']) == want && x['found'] != true).firstOrNull;
          if (n == null) break;
          final ring = rings[_i(n['ring'])] as Map;
          final a = (n['a'] as num).toDouble() + (ring['a'] as num).toDouble();
          final r = (ring['r'] as num).toDouble();
          s.act({'tap': [r * math.cos(a), r * math.sin(a)]});
          await s.frames(20);
        }
        await s.secs(0.3);
      }),
      Scene('math', _mind, 'Mental Aritmetik', (s) async {
        await s.play('math', 300);
        await _start(s, () => s.st['phase'] == 'play');
        for (var q = 0; q < 3; q++) {
          await s.secs(1.1);
          // What the core expects: ask a second session of the same level.
          s.act({'answer': _mathAnswer(q)});
          await s.secs(0.5);
        }
        await s.secs(0.4);
      }),
      Scene('soroban', _mind, 'Soroban', (s) async {
        await s.play('soroban', 40);
        await s.secs(1.3);
        s.act({'start': true});
        await s.secs(0.6);
        // The core's own hints, bead by bead.
        for (var k = 0; k < 7; k++) {
          if (!s.act({'hint': true})) break;
          final h = s.st['hint'];
          if (h is! Map) break;
          await s.frames(7);
          final rods = [for (final r in _l(s.st['rods'])) _i(r)];
          rods[_i(h['rod'])] += _i(h['delta']);
          if (!s.act({'rods': rods})) break;
          await s.frames(7);
        }
        await s.secs(0.4);
      }),
      Scene('zihin_asisi', _mind, 'Zihin Aşısı', (s) async {
        await s.play('zihin_asisi', 7);
        await s.secs(2.4); // the technique card: what it is, why it works, how to defend
        final done = <Map<String, dynamic>>[{'start': true}];
        s.act({'start': true});
        await s.secs(0.4);
        for (var q = 0; q < 2 && s.st['status'] == 'playing'; q++) {
          await s.secs(2.6);
          final right = _rightAnswer('zihin_asisi', 7, done);
          s.act({'answer': right});
          done
            ..add({'answer': right})
            ..add({'next': true});
          await s.secs(2.8);
          s.act({'next': true});
        }
        await s.secs(0.6);
      }),
      // ---------------------------------------------------------------- Küp
      Scene('cube', 'Zeka küpü', 'Küp', (s) async {
        await s.show(const CubeHomeScreen());
        await s.settle(() => false, maxMs: 400);
        await s.secs(2.6);
      }),
      Scene('cube_timer', 'Zeka küpü', 'Zamanlayıcı', (s) async {
        var ms = 0;
        await s.show(CubeTimerPage(clock: () => ms));
        await s.settle(() => false, maxMs: 600);
        Future<void> run(int frames) async {
          for (var f = 0; f < frames; f++) {
            ms += 1000 ~/ Stage.fps;
            await s.frames(1);
          }
        }

        await run(30);
        final pad = Offset(Stage.w / 2, 440);
        await s.tapAt(pad); // inspection starts
        await run(36);
        final g = await s.t.startGesture(pad); // hold, release: the timer runs
        await run(14);
        await g.up();
        await run(70);
        await s.tapAt(pad); // stop
        await run(30);
      }),
      Scene('cube_book', 'Zeka küpü', 'Küp Defteri', (s) async {
        await s.show(const CubeBookScreen(asset: 'assets/cube/defter.json', title: 'Küp Defteri'));
        await s.settle(() => false, maxMs: 800);
        await s.secs(1.0);
        final c = Offset(Stage.w / 2, 430);
        for (var k = 0; k < 3; k++) {
          await s.drag(c, c.translate(0, -320), n: 14);
          await s.secs(0.5);
        }
      }),

      Scene('cube_player', 'Zeka küpü', '3B oynatıcı', (s) async {
        // The player is a web page (three.js) in a WebView, which the test engine cannot draw: the
        // page frame is drawn here around an empty box, and make.sh lays the player, recorded in a
        // browser (cube3d.py), into that box.
        await s.show(const _PlayerFrame());
        await s.settle(() => false, maxMs: 300);
        final r = s.t.getRect(find.byKey(const ValueKey('promo-player-box')));
        File('${s.dir.path}/cube_player_box.json').writeAsStringSync(
            '{"x":${r.left},"y":${r.top},"w":${r.width},"h":${r.height},"scale":${Stage.appScale}}');
        await s.secs(cubePlayerSeconds);
      }),

      // ---------------------------------------------------------------- closing
      Scene('outro', '', '', full: true, (s) async {
        await s.show(const _Outro());
        await s.secs(4.5);
      }),
    ];

/// Scene quiz: the first question's right option (the show phase is cut short with `ready`).
int _rightAnswerAfterShow() {
  final r = Core.call({'op': 'new', 'game': 'scene_quiz', 'level': 300, 'mode': 'level'});
  final id = _i(r['id']);
  Core.call({'op': 'act', 'id': id, 'action': {'start': true}});
  Map st = const {};
  for (var t = 0; t < 400; t++) {
    st = Core.call({'op': 'tick', 'id': id, 'dt': 50.0})['state'] as Map;
    if (st['phase'] == 'show') break;
  }
  Core.call({'op': 'act', 'id': id, 'action': {'ready': true}});
  for (var t = 0; t < 400 && st['phase'] != 'question'; t++) {
    st = Core.call({'op': 'tick', 'id': id, 'dt': 50.0})['state'] as Map;
  }
  final a = Core.call({'op': 'act', 'id': id, 'action': {'answer': 0}});
  Core.call({'op': 'drop', 'id': id});
  final l = (a['state'] as Map)['last'];
  return l is Map ? _i(l['answer']) : 0;
}

/// Mental Aritmetik: the answer to question [q] of level 300 (answers before it given right).
String _mathAnswer(int q) {
  final known = <String>[];
  for (var round = 0; round <= q; round++) {
    final r = Core.call({'op': 'new', 'game': 'math', 'level': 300, 'mode': 'level'});
    final id = _i(r['id']);
    Core.call({'op': 'act', 'id': id, 'action': {'start': true}});
    Core.call({'op': 'tick', 'id': id, 'dt': 100.0});
    Map last = const {};
    for (final k in [...known, '1']) {
      last = Core.call({'op': 'act', 'id': id, 'action': {'answer': k}});
      Core.call({'op': 'tick', 'id': id, 'dt': 100.0});
    }
    Core.call({'op': 'drop', 'id': id});
    final l = (last['state'] as Map)['last'] as Map;
    known.add('${l['answer']}'.replaceAll(' ', ''));
  }
  return known[q];
}

/// İz Sürme: which circle is the next one, found by trying each on a second session.
int? _trailOrder(int n, int progress) {
  _trailSeq ??= () {
    final r = Core.call({'op': 'new', 'game': 'trail', 'level': 300, 'mode': 'level'});
    final id = _i(r['id']);
    Core.call({'op': 'act', 'id': id, 'action': {'start': true}});
    Map st = const {};
    for (var t = 0; t < 400 && st['phase'] != 'run'; t++) {
      st = Core.call({'op': 'tick', 'id': id, 'dt': 50.0})['state'] as Map;
    }
    final seq = <int>[];
    final count = _l(st['circles']).length;
    for (var step = 0; step < 16; step++) {
      final before = _i(st['next']);
      var found = false;
      for (var c = 0; c < count && !found; c++) {
        if (seq.contains(c)) continue;
        final a = Core.call({'op': 'act', 'id': id, 'action': {'tap': c}});
        st = a['state'] as Map;
        if (_i(st['next']) != before) {
          seq.add(c);
          found = true;
        }
      }
      if (!found) break;
    }
    Core.call({'op': 'drop', 'id': id});
    return seq;
  }();
  final done = _trailDone++;
  return done < _trailSeq!.length ? _trailSeq![done] : null;
}

List<int>? _trailSeq;
int _trailDone = 0;

// ---------------------------------------------------------------------------- full-frame cards

class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 1500),
        curve: Curves.easeOutCubic,
        builder: (c, v, _) => Material(
          type: MaterialType.transparency,
          child: Center(child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Transform.scale(
                scale: 0.86 + 0.14 * v,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(30),
                  child: Image.file(File('assets/icon/icon_ios.png'), width: 132, height: 132),
                ),
              ),
              const SizedBox(height: 26),
              Opacity(opacity: v, child: FoilText('Clever Place', style: Lux.display(46, italic: true))),
              const SizedBox(height: 6),
              Opacity(
                opacity: v,
                child: Text(promoText('ZİHİN KULÜBÜ'), style: Lux.ui(13, color: Lux.muted, weight: FontWeight.w600, spacing: 5)),
              ),
            ],
          )),
        ),
      );
}

class _Outro extends StatelessWidget {
  const _Outro();

  @override
  Widget build(BuildContext context) {
    final games = [
      for (final g in kCoreGames)
        if (g.category != GameCategory.cards) g,
    ];
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 2600),
      builder: (c, v, _) => Material(
        type: MaterialType.transparency,
        child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FoilText('Clever Place', style: Lux.display(40, italic: true)),
            const SizedBox(height: 4),
            Text(promoText('ZİHİN KULÜBÜ'), style: Lux.ui(12, color: Lux.muted, weight: FontWeight.w600, spacing: 5)),
            const SizedBox(height: 24),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 9,
              runSpacing: 9,
              children: [
                for (var i = 0; i < games.length; i++)
                  Opacity(
                    opacity: ((v * (games.length + 8) - i) / 8).clamp(0.0, 1.0),
                    child: Monogram(games[i].glyph, size: 44, tint: games[i].tint, art: games[i].id),
                  ),
              ],
            ),
            const SizedBox(height: 26),
            Text(promoText('Mantık · Strateji · Hafıza · Dikkat · Zihin · Küp'),
                textAlign: TextAlign.center, style: Lux.ui(13, color: Lux.goldLight, weight: FontWeight.w500, spacing: 0.6)),
            const SizedBox(height: 8),
            Text(promoTextF('{0} oyun · her birinde zorlaşan bölümler', games.length),
                textAlign: TextAlign.center, style: Lux.display(21, color: Lux.ink, italic: true)),
          ],
        ),
      )),
    );
  }
}

/// How long the 3D player clip runs (cube3d.py records the same length).
const double cubePlayerSeconds = 14;

/// The 3D player page (CubePlayerPage) with an empty box where its WebView goes.
class _PlayerFrame extends StatelessWidget {
  const _PlayerFrame();

  @override
  Widget build(BuildContext context) => CubeTheme(
        child: Scaffold(
          backgroundColor: Lux.bg0,
          body: LuxBackground(
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  CubeHeader('Y-perm'),
                  const Expanded(child: SizedBox.expand(key: ValueKey('promo-player-box'))),
                ],
              ),
            ),
          ),
        ),
      );
}
