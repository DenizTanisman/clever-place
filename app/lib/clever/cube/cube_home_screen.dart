import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../lux.dart';
import 'cube_book_screen.dart';
import 'cube_log.dart';
import 'cube_quiz_screen.dart';
import 'cube_timer_page.dart';

/// Küp: the timer, the two notebooks (Küp Defteri, Tek El Planı) and the algorithm test. Not a
/// Rust-core game, so the hub opens this page instead of a level grid.
class CubeHomeScreen extends StatefulWidget {
  const CubeHomeScreen({super.key});

  @override
  State<CubeHomeScreen> createState() => _CubeHomeScreenState();
}

class _CubeHomeScreenState extends State<CubeHomeScreen> {
  CubeLog _log = const CubeLog();
  ({int total, int learned, int due})? _quiz;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final prefs = await SharedPreferences.getInstance();
    final quiz = await CubeQuizScreen.summary();
    if (!mounted) return;
    setState(() {
      _log = CubeLog.decode(prefs.getString(CubeLog.storageKey));
      _quiz = quiz;
    });
  }

  Future<void> _open(Widget page) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final quiz = _quiz;
    return Scaffold(
      backgroundColor: Lux.bg0,
      body: LuxBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Row(children: [
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back, color: Lux.ink)),
              ]),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  children: [
                    Hero(tag: monogramHeroTag('cube'), child: const Monogram('▣', size: 68, tint: kCubeTint, art: 'cube')),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FoilText('Küp', style: Lux.display(30, italic: true)),
                          const SizedBox(height: 4),
                          Text('Zamanlayıcı, algoritma defteri, test', style: Lux.ui(15, color: Lux.muted)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const LuxHeading('Zamanlayıcı'),
              LuxCard(
                highlight: true,
                onTap: () => _open(const CubeTimerPage()),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.timer_outlined, color: Lux.gold, size: 30),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Çözüm süresi', style: Lux.ui(18, weight: FontWeight.w700)),
                              Text('Karıştırma, 15 sn inceleme, taktikler', style: Lux.ui(13.5, color: Lux.muted)),
                            ],
                          ),
                        ),
                        const Icon(Icons.play_arrow_rounded, color: Lux.gold, size: 30),
                      ],
                    ),
                    const SizedBox(height: 14),
                    for (final s in CubeSession.values) _sessionLine(s),
                  ],
                ),
              ),
              const LuxHeading('Eğitim'),
              Row(
                children: [
                  Expanded(
                    child: _bookCard(
                      'Küp Defteri',
                      'F2L, OLL, PLL, 4x4, 2x2, Megaminx',
                      Icons.menu_book_outlined,
                      const CubeBookScreen(asset: 'assets/cube/defter.json', title: 'Küp Defteri'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _bookCard(
                      'Tek El Planı',
                      'Hedef, aşamalar, günlük çalışma',
                      Icons.back_hand_outlined,
                      const CubeBookScreen(asset: 'assets/cube/tek_el.json', title: 'Tek El Planı'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              LuxCard(
                onTap: () => _open(const CubeQuizScreen()),
                child: Row(
                  children: [
                    const Icon(Icons.quiz_outlined, color: Lux.gold, size: 30),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Algoritma testi', style: Lux.ui(18, weight: FontWeight.w700)),
                          Text(
                            quiz == null
                                ? 'Bildiklerin seyrek, yanlışların sık gelir'
                                : '${quiz.learned} / ${quiz.total} öğrenildi · sırada ${quiz.due}',
                            style: Lux.ui(13.5, color: Lux.muted),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.play_arrow_rounded, color: Lux.gold, size: 30),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sessionLine(CubeSession s) {
    final solves = _log.of(s);
    final best = bestOf(solves);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          SizedBox(width: 86, child: Text(s.label, style: Lux.ui(14, color: Lux.goldLight, weight: FontWeight.w600))),
          Expanded(
            child: Text(
              solves.isEmpty
                  ? 'henüz çözüm yok'
                  : 'en iyi ${best == null ? '–' : formatCubeTime(best)} · '
                      'ao5 ${formatAverage(averageOf(solves, 5))} · '
                      'ao12 ${formatAverage(averageOf(solves, 12))} · ${solves.length} çözüm',
              style: Lux.ui(13, color: Lux.muted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _bookCard(String title, String sub, IconData icon, Widget page) {
    return LuxCard(
      padding: const EdgeInsets.all(14),
      onTap: () => _open(page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Lux.gold),
          const SizedBox(height: 8),
          Text(title, style: Lux.ui(17, weight: FontWeight.w700)),
          Text(sub, style: Lux.ui(13, color: Lux.muted), maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

/// The cube's enamel colour on the hub and its own page.
const kCubeTint = Color(0xFF2F8F4E);
