import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../lux.dart';

/// Blok Merkezi skins: every look is drawn in code (no image assets). A skin restyles the placed
/// blocks (several hues, picked per piece shape), the stone blocks, the board (background, slots,
/// separators, frame) and the particles thrown by clears.
///
/// Skins unlock as the player progresses: by the highest level won or by the total number of
/// rows / columns / boxes ever cleared, whichever comes first. [BlockSkinStore] persists the
/// choice and both counters in SharedPreferences.

/// How a skin's tiles are painted.
enum TileStyle { gold, wood, candy, marble, neon, ice, gem }

/// What a clear throws into the air.
enum ParticleStyle { dust, chips, sprinkles, flakes, streaks, shards, marble }

class BlockSkin {
  final int index;
  final String id;
  final String name;
  final String blurb;

  /// Unlocks when the highest won level reaches [unlockLevel] or [unlockLines] units were cleared
  /// in total (0 / 0 = available from the start).
  final int unlockLevel;
  final int unlockLines;

  final TileStyle style;
  final ParticleStyle particle;

  /// Placed-block colours; a piece takes `hues[shape % hues.length]`.
  final List<Color> hues;
  final Color stone;

  /// Glow, preview and callout colours.
  final Color accent;
  final Color accentLight;
  final Color bad;

  /// Board frame gradient and board colours.
  final List<Color> frame;
  final Color bg, boxAlt, slot, thin, thick;
  final double slotRadius;

  /// Texture variants per tile (wood grain, marble veins, ice cracks).
  final int variants;

  const BlockSkin({
    required this.index,
    required this.id,
    required this.name,
    required this.blurb,
    required this.unlockLevel,
    required this.unlockLines,
    required this.style,
    required this.particle,
    required this.hues,
    required this.stone,
    required this.accent,
    required this.accentLight,
    required this.frame,
    required this.bg,
    required this.boxAlt,
    required this.slot,
    required this.thin,
    required this.thick,
    this.bad = Lux.bordeaux,
    this.slotRadius = 0.14,
    this.variants = 1,
  });

  bool get isDefault => unlockLevel == 0 && unlockLines == 0;

  bool unlockedBy({required int level, required int lines}) =>
      isDefault || level >= unlockLevel || lines >= unlockLines;

  /// "10. bölümü geç ya da 100 satır/sütun/kare temizle".
  String get unlockText => isDefault ? 'Baştan açık' : '$unlockLevel. bölümü geç ya da $unlockLines satır/sütun/kare temizle';

  Color hue(int seed) => hues[seed.abs() % hues.length];
}

class BlockSkins {
  BlockSkins._();

  static const zumrut = BlockSkin(
    index: 0,
    id: 'zumrut',
    name: 'Zümrüt',
    blurb: 'Altın varak, kadife tahta',
    unlockLevel: 0,
    unlockLines: 0,
    style: TileStyle.gold,
    particle: ParticleStyle.dust,
    hues: [Color(0xFFE2A93B), Color(0xFF2FA273), Color(0xFFC97A42)],
    stone: Color(0xFF3E2A2E),
    accent: Lux.gold,
    accentLight: Lux.goldLight,
    frame: [Color(0xFF7D5A1B), Color(0xFFF1D48B), Color(0xFFB98A35), Color(0xFFFBE7B0), Color(0xFF9C7228), Color(0xFFE3C278)],
    bg: Color(0xFF0D0907),
    boxAlt: Color(0xFF17110B),
    slot: Color(0xFF1D160F),
    thin: Color(0x14D4A94E),
    thick: Color(0xD9D4A94E),
  );

  static const ahsap = BlockSkin(
    index: 1,
    id: 'ahsap',
    name: 'Ahşap',
    blurb: 'Damarlı tahta bloklar, pirinç çıtalar',
    unlockLevel: 10,
    unlockLines: 100,
    style: TileStyle.wood,
    particle: ParticleStyle.chips,
    hues: [Color(0xFFC8914F), Color(0xFFE2B878), Color(0xFF8A5631), Color(0xFFA4502E)],
    stone: Color(0xFF3A2A20),
    accent: Color(0xFFE0A65A),
    accentLight: Color(0xFFFFDCA8),
    frame: [Color(0xFF4A2E17), Color(0xFFA8743F), Color(0xFF5E3B1F), Color(0xFFC08A50), Color(0xFF4A2E17)],
    bg: Color(0xFF24160D),
    boxAlt: Color(0xFF2C1B10),
    slot: Color(0xFF1A0F08),
    thin: Color(0x22000000),
    thick: Color(0xCCC89B4A),
    slotRadius: 0.1,
    variants: 3,
  );

  static const seker = BlockSkin(
    index: 2,
    id: 'seker',
    name: 'Şeker',
    blurb: 'Parlak jöle şekerler, çikolata taşlar',
    unlockLevel: 25,
    unlockLines: 250,
    style: TileStyle.candy,
    particle: ParticleStyle.sprinkles,
    hues: [Color(0xFFFF5A7A), Color(0xFFFFCF3F), Color(0xFF45DDA8), Color(0xFF5B8CFF), Color(0xFFB06BFF), Color(0xFFFF9A3C)],
    stone: Color(0xFF4A2A1A),
    accent: Color(0xFFFF7AB6),
    accentLight: Color(0xFFFFD6EA),
    frame: [Color(0xFFFF6FAE), Color(0xFFFFF0F7), Color(0xFFFF6FAE), Color(0xFFFFF0F7), Color(0xFFFF6FAE)],
    bg: Color(0xFF250C20),
    boxAlt: Color(0xFF2F1129),
    slot: Color(0xFF3A1634),
    thin: Color(0x0FFFFFFF),
    thick: Color(0xB3FF8FC8),
    slotRadius: 0.3,
  );

  static const mermer = BlockSkin(
    index: 3,
    id: 'mermer',
    name: 'Mermer',
    blurb: 'Damarlı mermer, altın kakma',
    unlockLevel: 50,
    unlockLines: 500,
    style: TileStyle.marble,
    particle: ParticleStyle.marble,
    hues: [Color(0xFFEDEAE3), Color(0xFF2E2E33), Color(0xFF2F6B55), Color(0xFFD9A8A0)],
    stone: Color(0xFF45444A),
    accent: Color(0xFFE8DCC0),
    accentLight: Color(0xFFFFFFFF),
    frame: [Color(0xFFB8A47A), Color(0xFFF5EFE3), Color(0xFFC9B68C), Color(0xFFFFFBF2), Color(0xFFB8A47A)],
    bg: Color(0xFF131615),
    boxAlt: Color(0xFF191D1C),
    slot: Color(0xFF1F2423),
    thin: Color(0x10FFFFFF),
    thick: Color(0xCCD4A94E),
    slotRadius: 0.08,
    variants: 3,
  );

  static const neon = BlockSkin(
    index: 4,
    id: 'neon',
    name: 'Neon',
    blurb: 'Karanlıkta parlayan çizgiler',
    unlockLevel: 75,
    unlockLines: 800,
    style: TileStyle.neon,
    particle: ParticleStyle.streaks,
    hues: [Color(0xFF00E5FF), Color(0xFFFF2BD6), Color(0xFFB6FF3B), Color(0xFFFF8A00), Color(0xFF8C6CFF)],
    stone: Color(0xFF1A1C26),
    accent: Color(0xFF00E5FF),
    accentLight: Color(0xFFBDF8FF),
    bad: Color(0xFFFF2B5A),
    frame: [Color(0xFFFF2BD6), Color(0xFF8C6CFF), Color(0xFF00E5FF), Color(0xFF8C6CFF), Color(0xFFFF2BD6)],
    bg: Color(0xFF04050D),
    boxAlt: Color(0xFF070915),
    slot: Color(0xFF0A0D1C),
    thin: Color(0x1200E5FF),
    thick: Color(0x9900E5FF),
    slotRadius: 0.16,
  );

  static const buz = BlockSkin(
    index: 5,
    id: 'buz',
    name: 'Buz',
    blurb: 'Kırağılı buz kalıpları',
    unlockLevel: 100,
    unlockLines: 1200,
    style: TileStyle.ice,
    particle: ParticleStyle.flakes,
    hues: [Color(0xFF8FD3FF), Color(0xFF6FE3DC), Color(0xFFB7B3FF)],
    stone: Color(0xFF2C3644),
    accent: Color(0xFF9FDCFF),
    accentLight: Color(0xFFF0FAFF),
    frame: [Color(0xFF5AA8D8), Color(0xFFE8F8FF), Color(0xFF7FC8F0), Color(0xFFFFFFFF), Color(0xFF5AA8D8)],
    bg: Color(0xFF06121F),
    boxAlt: Color(0xFF0A1828),
    slot: Color(0xFF0F2134),
    thin: Color(0x10BFE9FF),
    thick: Color(0x99BFE9FF),
    slotRadius: 0.12,
    variants: 3,
  );

  static const mucevher = BlockSkin(
    index: 6,
    id: 'mucevher',
    name: 'Mücevher',
    blurb: 'Kesme taşlar, kadife kutu',
    unlockLevel: 150,
    unlockLines: 2000,
    style: TileStyle.gem,
    particle: ParticleStyle.shards,
    hues: [Color(0xFFE0115F), Color(0xFF2763FF), Color(0xFF0FA36B), Color(0xFF9B4DFF), Color(0xFFFFB000), Color(0xFFBFEFFF)],
    stone: Color(0xFF38323F),
    accent: Color(0xFFF0D69A),
    accentLight: Color(0xFFFFFFFF),
    frame: [Color(0xFF7D5A1B), Color(0xFFF1D48B), Color(0xFFB98A35), Color(0xFFFBE7B0), Color(0xFF9C7228), Color(0xFFE3C278)],
    bg: Color(0xFF110A1C),
    boxAlt: Color(0xFF170E26),
    slot: Color(0xFF1E1430),
    thin: Color(0x14D4A94E),
    thick: Color(0xD9D4A94E),
    slotRadius: 0.1,
  );

  /// In unlock order.
  static const all = [zumrut, ahsap, seker, mermer, neon, buz, mucevher];

  static BlockSkin byId(String? id) => all.firstWhere((s) => s.id == id, orElse: () => zumrut);

  static List<BlockSkin> unlocked({required int level, required int lines}) =>
      [for (final s in all) if (s.unlockedBy(level: level, lines: lines)) s];
}

/// Persistent skin state: chosen skin, total units cleared, highest won level, skins already seen
/// in the picker (the palette button shows a dot while a new one is unseen).
class BlockSkinStore extends ChangeNotifier {
  static const kSkin = 'cp.skin.block_grid';
  static const kLines = 'cp.lines.block_grid';
  static const kLevel = 'cp.reach.block_grid';
  static const kSeen = 'cp.skinseen.block_grid';
  static const _starsPrefix = 'cp.stars.block_grid.';

  final SharedPreferences _prefs;
  int _lines;
  int _level;
  String _skin;
  final Set<String> _seen;

  BlockSkinStore(this._prefs)
      : _lines = _prefs.getInt(kLines) ?? 0,
        _level = _prefs.getInt(kLevel) ?? 0,
        _skin = _prefs.getString(kSkin) ?? BlockSkins.zumrut.id,
        _seen = (_prefs.getStringList(kSeen) ?? const []).toSet() {
    // Levels already won before skins existed count too.
    for (final k in _prefs.getKeys()) {
      if (!k.startsWith(_starsPrefix)) continue;
      final l = int.tryParse(k.substring(_starsPrefix.length));
      final v = _prefs.get(k);
      if (l != null && v is int && v > 0 && l > _level) _level = l;
    }
    if (!skin.unlockedBy(level: _level, lines: _lines)) _skin = BlockSkins.zumrut.id;
  }

  static BlockSkinStore? _instance;
  static BlockSkinStore? get loaded => _instance;
  static Future<BlockSkinStore> load() async => _instance ??= BlockSkinStore(await SharedPreferences.getInstance());

  @visibleForTesting
  static void resetForTest() => _instance = null;

  int get lines => _lines;
  int get level => _level;
  BlockSkin get skin => BlockSkins.byId(_skin);
  bool isUnlocked(BlockSkin s) => s.unlockedBy(level: _level, lines: _lines);
  List<BlockSkin> get unlocked => BlockSkins.unlocked(level: _level, lines: _lines);

  /// Unlocked skins the player has not looked at in the picker yet.
  List<BlockSkin> get unseen => [for (final s in unlocked) if (!s.isDefault && !_seen.contains(s.id)) s];

  List<BlockSkin> _gained(int level0, int lines0) => [
        for (final s in BlockSkins.all)
          if (!s.unlockedBy(level: level0, lines: lines0) && isUnlocked(s)) s
      ];

  /// Adds cleared units; returns the skins this unlocked.
  Future<List<BlockSkin>> addLines(int n) async {
    if (n <= 0) return const [];
    final l0 = _lines;
    _lines += n;
    await _prefs.setInt(kLines, _lines);
    final g = _gained(_level, l0);
    notifyListeners();
    return g;
  }

  /// Records a won level; returns the skins this unlocked.
  Future<List<BlockSkin>> reachLevel(int level) async {
    if (level <= _level) return const [];
    final l0 = _level;
    _level = level;
    await _prefs.setInt(kLevel, _level);
    final g = _gained(l0, _lines);
    notifyListeners();
    return g;
  }

  /// Selects [s] if it is unlocked. Returns false for a locked skin.
  Future<bool> select(BlockSkin s) async {
    if (!isUnlocked(s)) return false;
    _skin = s.id;
    _seen.add(s.id);
    await _prefs.setString(kSkin, s.id);
    await _prefs.setStringList(kSeen, _seen.toList());
    notifyListeners();
    return true;
  }

  /// Marks every unlocked skin as seen (the picker was opened).
  Future<void> markSeen() async {
    final before = _seen.length;
    for (final s in unlocked) {
      _seen.add(s.id);
    }
    if (_seen.length == before) return;
    await _prefs.setStringList(kSeen, _seen.toList());
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------------------------

Color _mix(Color a, Color b, double t) => Color.lerp(a, b, t)!;
Color _light(Color c, double t) => _mix(c, Colors.white, t);
Color _dark(Color c, double t) => _mix(c, Colors.black, t);

/// Pre-rendered tiles per (skin, tile, variant, pixel size). `tile` < 0 is the stone block.
class BlockTiles {
  BlockTiles._();
  static final Map<int, ui.Image> _cache = {};
  static final Paint _paint = Paint()..filterQuality = FilterQuality.medium;

  static ui.Image get(BlockSkin skin, int tile, int variant, double px) {
    final size = px.round().clamp(4, 400);
    final v = skin.variants > 1 ? variant.abs() % skin.variants : 0;
    final t = tile < 0 ? 15 : tile.abs() % skin.hues.length;
    final key = ((skin.index * 16 + t) * 4 + v) * 1000 + size;
    final hit = _cache[key];
    if (hit != null) return hit;
    if (_cache.length > 600) _cache.clear();
    return _cache[key] = render(skin, t == 15 ? -1 : t, v, size.toDouble());
  }

  static ui.Image render(BlockSkin skin, int tile, int variant, double s) {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    paintTile(c, skin, tile, variant, s);
    return rec.endRecording().toImageSync(s.toInt(), s.toInt());
  }

  /// Draws a tile into [r]. [px] is the nominal (unscaled) cell size, so scaled / animated tiles
  /// reuse one rendered image.
  static void draw(Canvas canvas, BlockSkin skin, int tile, int variant, Rect r, double dpr,
      {double opacity = 1, double? px}) {
    if (opacity <= 0.004 || r.width <= 0.5) return;
    final img = get(skin, tile, variant, (px ?? r.width) * dpr);
    _paint.color = Color.fromRGBO(255, 255, 255, opacity.clamp(0.0, 1.0));
    canvas.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), r, _paint);
  }

  static void paintTile(Canvas c, BlockSkin skin, int tile, int variant, double s) {
    final stone = tile < 0;
    final base = stone ? skin.stone : skin.hues[tile % skin.hues.length];
    switch (skin.style) {
      case TileStyle.gold:
        _gold(c, s, base, stone);
      case TileStyle.wood:
        _wood(c, s, base, stone, variant);
      case TileStyle.candy:
        _candy(c, s, base, stone);
      case TileStyle.marble:
        _marble(c, s, base, stone, variant);
      case TileStyle.neon:
        _neon(c, s, base, stone);
      case TileStyle.ice:
        _ice(c, s, base, stone, variant);
      case TileStyle.gem:
        _gem(c, s, base, stone, tile);
    }
  }

  // Zümrüt: glossy enamel tile with a gold rim; stone = garnet obsidian with bronze veins.
  static void _gold(Canvas c, double s, Color base, bool stone) {
    final outer = RRect.fromRectAndRadius(Rect.fromLTWH(s * 0.05, s * 0.05, s * 0.9, s * 0.9), Radius.circular(s * 0.18));
    c.drawRRect(
      outer,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_light(base, stone ? 0.18 : 0.5), base, _dark(base, 0.55)],
        ).createShader(outer.outerRect),
    );
    final inner = outer.outerRect.deflate(s * 0.15);
    c.drawRRect(
      RRect.fromRectAndRadius(inner, Radius.circular(s * 0.08)),
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.45),
          radius: 1.1,
          colors: [_light(base, stone ? 0.12 : 0.32), base, _dark(base, 0.25)],
        ).createShader(inner),
    );
    if (stone) {
      c.drawPath(
        Path()
          ..moveTo(inner.left, inner.top + inner.height * 0.3)
          ..lineTo(inner.left + inner.width * 0.45, inner.top + inner.height * 0.55)
          ..lineTo(inner.right, inner.top + inner.height * 0.4),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.035
          ..color = Lux.goldDeep.withValues(alpha: 0.75),
      );
    }
    c.drawOval(
      Rect.fromLTWH(inner.left + s * 0.03, inner.top + s * 0.02, inner.width * 0.55, inner.height * 0.3),
      Paint()
        ..color = Colors.white.withValues(alpha: stone ? 0.12 : 0.42)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.03),
    );
    c.drawRRect(
      outer,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.03
        ..color = (stone ? Lux.goldDeep : Lux.goldLight).withValues(alpha: 0.6),
    );
  }

  // Ahşap: bevelled block with wavy grain and the odd knot; stone = charred plank with rivets.
  static void _wood(Canvas c, double s, Color base, bool stone, int variant) {
    final rect = Rect.fromLTWH(s * 0.05, s * 0.05, s * 0.9, s * 0.9);
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(s * 0.1));
    c.drawRRect(
      rr,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_light(base, 0.18), base, _dark(base, 0.3)],
        ).createShader(rect),
    );
    c.save();
    c.clipRRect(rr);
    final rnd = math.Random(variant * 31 + (stone ? 7 : 1));
    final grain = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.022
      ..color = _dark(base, 0.45).withValues(alpha: stone ? 0.6 : 0.4);
    final lines = 5 + rnd.nextInt(2);
    for (var k = 0; k < lines; k++) {
      final y0 = rect.top + rect.height * (k + 0.5 + (rnd.nextDouble() - 0.5) * 0.5) / lines;
      final amp = s * (0.015 + rnd.nextDouble() * 0.03);
      final ph = rnd.nextDouble() * math.pi * 2;
      final p = Path()..moveTo(rect.left - 2, y0);
      for (var i = 1; i <= 12; i++) {
        final x = rect.left - 2 + (rect.width + 4) * i / 12;
        p.lineTo(x, y0 + math.sin(ph + i * 0.7) * amp);
      }
      c.drawPath(p, grain);
    }
    if (!stone && variant == 1) {
      final kc = Offset(rect.left + rect.width * (0.3 + rnd.nextDouble() * 0.4), rect.top + rect.height * 0.55);
      c.drawOval(Rect.fromCenter(center: kc, width: s * 0.16, height: s * 0.07), Paint()..color = _dark(base, 0.4).withValues(alpha: 0.75));
      c.drawOval(
          Rect.fromCenter(center: kc, width: s * 0.3, height: s * 0.14),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = s * 0.018
            ..color = _dark(base, 0.4).withValues(alpha: 0.6));
    }
    c.restore();
    // Bevel.
    final hi = Paint()
      ..strokeWidth = s * 0.05
      ..color = Colors.white.withValues(alpha: stone ? 0.08 : 0.26);
    final lo = Paint()
      ..strokeWidth = s * 0.05
      ..color = Colors.black.withValues(alpha: 0.32);
    final d = s * 0.075;
    c.drawLine(Offset(rect.left + d, rect.top + d), Offset(rect.right - d, rect.top + d), hi);
    c.drawLine(Offset(rect.left + d, rect.top + d), Offset(rect.left + d, rect.bottom - d), hi);
    c.drawLine(Offset(rect.left + d, rect.bottom - d), Offset(rect.right - d, rect.bottom - d), lo);
    c.drawLine(Offset(rect.right - d, rect.top + d), Offset(rect.right - d, rect.bottom - d), lo);
    if (stone) {
      final rivet = Paint()..color = const Color(0xFF8D8D92);
      for (final o in [Offset(rect.left + s * 0.17, rect.top + s * 0.17), Offset(rect.right - s * 0.17, rect.bottom - s * 0.17)]) {
        c.drawCircle(o, s * 0.06, rivet);
        c.drawCircle(o - Offset(s * 0.015, s * 0.015), s * 0.022, Paint()..color = Colors.white.withValues(alpha: 0.5));
      }
    }
    c.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.02
          ..color = _dark(base, 0.6));
  }

  // Şeker: round jelly candy with a big gloss; stone = a chocolate square in four segments.
  static void _candy(Canvas c, double s, Color base, bool stone) {
    final rect = Rect.fromLTWH(s * 0.06, s * 0.06, s * 0.88, s * 0.88);
    if (stone) {
      final rr = RRect.fromRectAndRadius(rect, Radius.circular(s * 0.12));
      c.drawRRect(
          rr,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [_light(base, 0.2), base, _dark(base, 0.35)],
            ).createShader(rect));
      final groove = Paint()
        ..strokeWidth = s * 0.035
        ..color = _dark(base, 0.4);
      c.drawLine(Offset(rect.center.dx, rect.top + s * 0.08), Offset(rect.center.dx, rect.bottom - s * 0.08), groove);
      c.drawLine(Offset(rect.left + s * 0.08, rect.center.dy), Offset(rect.right - s * 0.08, rect.center.dy), groove);
      final shine = Paint()
        ..strokeWidth = s * 0.02
        ..color = _light(base, 0.3).withValues(alpha: 0.6);
      c.drawLine(Offset(rect.center.dx + s * 0.03, rect.top + s * 0.08), Offset(rect.center.dx + s * 0.03, rect.bottom - s * 0.08), shine);
      c.drawLine(Offset(rect.left + s * 0.08, rect.center.dy + s * 0.03), Offset(rect.right - s * 0.08, rect.center.dy + s * 0.03), shine);
      return;
    }
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(s * 0.3));
    c.drawRRect(
        rr,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.3, -0.4),
            radius: 1.0,
            colors: [_light(base, 0.45), base, _dark(base, 0.35)],
            stops: const [0, 0.55, 1],
          ).createShader(rect));
    final gloss = Rect.fromLTWH(rect.left + s * 0.14, rect.top + s * 0.08, rect.width - s * 0.28, rect.height * 0.4);
    c.drawRRect(
        RRect.fromRectAndRadius(gloss, Radius.circular(s * 0.2)),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.white.withValues(alpha: 0.7), Colors.white.withValues(alpha: 0.0)],
          ).createShader(gloss));
    c.drawCircle(Offset(rect.left + s * 0.24, rect.top + s * 0.22), s * 0.05, Paint()..color = Colors.white.withValues(alpha: 0.9));
    c.drawArc(
        rect.deflate(s * 0.12),
        math.pi * 0.2,
        math.pi * 0.6,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = s * 0.04
          ..color = Colors.white.withValues(alpha: 0.22));
    c.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.03
          ..color = _dark(base, 0.4));
  }

  // Mermer: polished slab with veins and a gold inlay edge; stone = speckled granite.
  static void _marble(Canvas c, double s, Color base, bool stone, int variant) {
    final rect = Rect.fromLTWH(s * 0.05, s * 0.05, s * 0.9, s * 0.9);
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(s * 0.08));
    c.drawRRect(
        rr,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [_light(base, 0.15), base, _dark(base, 0.15)],
          ).createShader(rect));
    c.save();
    c.clipRRect(rr);
    final rnd = math.Random(variant * 17 + (stone ? 5 : 3));
    if (stone) {
      final dot = Paint();
      for (var i = 0; i < 46; i++) {
        dot.color = (rnd.nextBool() ? Colors.black : Colors.white).withValues(alpha: 0.15 + rnd.nextDouble() * 0.3);
        c.drawCircle(Offset(rect.left + rnd.nextDouble() * rect.width, rect.top + rnd.nextDouble() * rect.height),
            s * (0.01 + rnd.nextDouble() * 0.025), dot);
      }
    } else {
      final darkBase = base.computeLuminance() < 0.3;
      final vein = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.006)
        ..color = (darkBase ? Colors.white : const Color(0xFF555560)).withValues(alpha: darkBase ? 0.5 : 0.45);
      for (var k = 0; k < 3; k++) {
        Offset pt() => Offset(rect.left + rnd.nextDouble() * rect.width, rect.top + rnd.nextDouble() * rect.height);
        final a = Offset(rect.left - 2, rect.top + rnd.nextDouble() * rect.height);
        final b = Offset(rect.right + 2, rect.top + rnd.nextDouble() * rect.height);
        final p = Path()
          ..moveTo(a.dx, a.dy)
          ..cubicTo(pt().dx, pt().dy, pt().dx, pt().dy, b.dx, b.dy);
        vein.strokeWidth = s * (k == 0 ? 0.025 : 0.012);
        c.drawPath(p, vein);
      }
      c.drawPath(
          Path()
            ..moveTo(rect.left, rect.top + rect.height * 0.55)
            ..lineTo(rect.left + rect.width * 0.55, rect.top)
            ..lineTo(rect.left + rect.width * 0.8, rect.top)
            ..lineTo(rect.left, rect.top + rect.height * 0.8)
            ..close(),
          Paint()..color = Colors.white.withValues(alpha: 0.12));
    }
    c.restore();
    c.drawRRect(
        rr.deflate(s * 0.012),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.025
          ..color = (stone ? const Color(0xFF6A6870) : Lux.gold).withValues(alpha: 0.8));
  }

  // Neon: dark glass with a glowing outline; stone = a dead, hatched panel.
  static void _neon(Canvas c, double s, Color base, bool stone) {
    final rect = Rect.fromLTWH(s * 0.12, s * 0.12, s * 0.76, s * 0.76);
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(s * 0.16));
    if (stone) {
      c.drawRRect(rr, Paint()..color = base);
      c.save();
      c.clipRRect(rr);
      final hatch = Paint()
        ..strokeWidth = s * 0.02
        ..color = const Color(0xFF5A6070).withValues(alpha: 0.35);
      for (var k = -4; k < 6; k++) {
        final x = rect.left + k * s * 0.16;
        c.drawLine(Offset(x, rect.bottom), Offset(x + rect.height, rect.top), hatch);
      }
      c.restore();
      c.drawRRect(
          rr,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = s * 0.03
            ..color = const Color(0xFF5A6070));
      return;
    }
    c.drawRRect(rr, Paint()..color = _dark(base, 0.82));
    c.drawRRect(
        rr,
        Paint()
          ..shader = RadialGradient(colors: [base.withValues(alpha: 0.28), base.withValues(alpha: 0.0)]).createShader(rect));
    c.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.09
          ..color = base.withValues(alpha: 0.85)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.05));
    c.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.04
          ..color = _light(base, 0.55));
    c.drawRRect(
        rr.deflate(s * 0.13),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.018
          ..color = base.withValues(alpha: 0.5));
  }

  // Buz: translucent ice with frost, a crack and trapped bubbles; stone = frozen rock.
  static void _ice(Canvas c, double s, Color base, bool stone, int variant) {
    final rect = Rect.fromLTWH(s * 0.05, s * 0.05, s * 0.9, s * 0.9);
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(s * 0.12));
    c.drawRRect(
        rr,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: stone
                ? [_light(base, 0.15), base, _dark(base, 0.3)]
                : [_light(base, 0.65), _light(base, 0.1), _dark(base, 0.3)],
          ).createShader(rect));
    final rnd = math.Random(variant * 13 + (stone ? 9 : 2));
    c.save();
    c.clipRRect(rr);
    if (stone) {
      final frost = Paint()..color = Colors.white.withValues(alpha: 0.35);
      for (var i = 0; i < 18; i++) {
        c.drawCircle(Offset(rect.left + rnd.nextDouble() * rect.width, rect.top + rnd.nextDouble() * rect.height * 0.5),
            s * (0.008 + rnd.nextDouble() * 0.018), frost);
      }
      c.drawRect(Rect.fromLTWH(rect.left, rect.top, rect.width, s * 0.12), Paint()..color = Colors.white.withValues(alpha: 0.4));
    } else {
      c.drawPath(
          Path()
            ..moveTo(rect.left, rect.top)
            ..lineTo(rect.left + rect.width * 0.62, rect.top)
            ..lineTo(rect.left, rect.top + rect.height * 0.62)
            ..close(),
          Paint()..color = Colors.white.withValues(alpha: 0.28));
      final crack = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.014
        ..color = Colors.white.withValues(alpha: 0.6);
      var p = Offset(rect.left + rect.width * (0.45 + rnd.nextDouble() * 0.3), rect.top + rect.height * 0.35);
      final path = Path()..moveTo(p.dx, p.dy);
      for (var i = 0; i < 4; i++) {
        p += Offset((rnd.nextDouble() - 0.5) * s * 0.25, s * 0.13);
        path.lineTo(p.dx, p.dy);
      }
      c.drawPath(path, crack);
      final bubble = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.012
        ..color = Colors.white.withValues(alpha: 0.55);
      for (var i = 0; i < 2; i++) {
        c.drawCircle(Offset(rect.left + rect.width * (0.2 + rnd.nextDouble() * 0.6), rect.top + rect.height * (0.55 + rnd.nextDouble() * 0.3)),
            s * (0.025 + rnd.nextDouble() * 0.02), bubble);
      }
    }
    c.restore();
    c.drawRRect(
        rr.deflate(s * 0.08),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.03
          ..color = Colors.white.withValues(alpha: 0.22)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.02));
    c.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.025
          ..color = _light(base, 0.7).withValues(alpha: 0.85));
  }

  // Mücevher: square-cut gem with four facets, a table and a glint in a gold setting;
  // stone = rough ore with coloured flecks.
  static void _gem(Canvas c, double s, Color base, bool stone, int tile) {
    final o = Rect.fromLTWH(s * 0.06, s * 0.06, s * 0.88, s * 0.88);
    if (stone) {
      final rnd = math.Random(5);
      final pts = <Offset>[];
      for (var i = 0; i < 7; i++) {
        final a = i / 7 * math.pi * 2 + rnd.nextDouble() * 0.4;
        final r = s * (0.36 + rnd.nextDouble() * 0.08);
        pts.add(o.center + Offset(math.cos(a) * r, math.sin(a) * r));
      }
      final path = Path()..addPolygon(pts, true);
      c.drawPath(
          path,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [_light(base, 0.25), base, _dark(base, 0.4)],
            ).createShader(o));
      final fleck = Paint();
      const fl = [Color(0xFFE0115F), Color(0xFF2763FF), Color(0xFF0FA36B), Color(0xFFFFB000)];
      for (var i = 0; i < 7; i++) {
        fleck.color = fl[i % fl.length].withValues(alpha: 0.75);
        c.drawCircle(o.center + Offset((rnd.nextDouble() - 0.5) * s * 0.5, (rnd.nextDouble() - 0.5) * s * 0.5), s * 0.022, fleck);
      }
      c.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = s * 0.02
            ..color = Colors.black.withValues(alpha: 0.5));
      return;
    }
    final t = o.deflate(o.width * 0.24);
    Path quad(Offset a, Offset b, Offset c2, Offset d) => Path()..addPolygon([a, b, c2, d], true);
    final fill = Paint();
    fill.color = _light(base, 0.38);
    c.drawPath(quad(o.topLeft, o.topRight, t.topRight, t.topLeft), fill);
    fill.color = _light(base, 0.08);
    c.drawPath(quad(o.topLeft, t.topLeft, t.bottomLeft, o.bottomLeft), fill);
    fill.color = _dark(base, 0.25);
    c.drawPath(quad(o.topRight, o.bottomRight, t.bottomRight, t.topRight), fill);
    fill.color = _dark(base, 0.48);
    c.drawPath(quad(o.bottomLeft, t.bottomLeft, t.bottomRight, o.bottomRight), fill);
    c.drawRect(
        t,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [_light(base, 0.3), base, _light(base, 0.12)],
          ).createShader(t));
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.012
      ..color = Colors.white.withValues(alpha: 0.3);
    c.drawRect(t, edge);
    c.drawLine(o.topLeft, t.topLeft, edge);
    c.drawLine(o.topRight, t.topRight, edge);
    c.drawLine(o.bottomLeft, t.bottomLeft, edge);
    c.drawLine(o.bottomRight, t.bottomRight, edge);
    c.drawPath(
        Path()
          ..moveTo(t.left, t.top + t.height * 0.45)
          ..lineTo(t.left + t.width * 0.45, t.top)
          ..lineTo(t.left + t.width * 0.7, t.top)
          ..lineTo(t.left, t.top + t.height * 0.7)
          ..close(),
        Paint()..color = Colors.white.withValues(alpha: 0.3));
    // Four-point glint.
    final g = Offset(t.left + t.width * 0.22, t.top + t.height * 0.22);
    final r = s * 0.11, w = s * 0.022;
    c.drawPath(
        Path()
          ..moveTo(g.dx, g.dy - r)
          ..lineTo(g.dx + w, g.dy - w)
          ..lineTo(g.dx + r, g.dy)
          ..lineTo(g.dx + w, g.dy + w)
          ..lineTo(g.dx, g.dy + r)
          ..lineTo(g.dx - w, g.dy + w)
          ..lineTo(g.dx - r, g.dy)
          ..lineTo(g.dx - w, g.dy - w)
          ..close(),
        Paint()..color = Colors.white.withValues(alpha: 0.92));
    c.drawRect(
        o,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.03
          ..color = Lux.gold);
  }

  /// Board background (field, box shading, empty slots, skin texture) in [size].
  static void paintBoardBackground(Canvas c, Size size, BlockSkin skin) {
    final cell = size.width / 9;
    c.drawRect(Offset.zero & size, Paint()..color = skin.bg);
    for (var b = 0; b < 9; b++) {
      if (b.isOdd) {
        c.drawRect(Rect.fromLTWH((b % 3) * 3 * cell, (b ~/ 3) * 3 * cell, 3 * cell, 3 * cell), Paint()..color = skin.boxAlt);
      }
    }
    final rnd = math.Random(skin.index * 101 + 3);
    switch (skin.style) {
      case TileStyle.wood:
        final grain = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.black.withValues(alpha: 0.18);
        for (var k = 0; k < 40; k++) {
          final y0 = rnd.nextDouble() * size.height;
          final p = Path()..moveTo(0, y0);
          for (var i = 1; i <= 18; i++) {
            p.lineTo(size.width * i / 18, y0 + math.sin(i * 0.6 + k) * 2.2);
          }
          c.drawPath(p, grain);
        }
      case TileStyle.marble:
        final vein = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = Colors.white.withValues(alpha: 0.05);
        for (var k = 0; k < 7; k++) {
          Offset pt() => Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height);
          final a = Offset(0, rnd.nextDouble() * size.height), b = Offset(size.width, rnd.nextDouble() * size.height);
          c.drawPath(
              Path()
                ..moveTo(a.dx, a.dy)
                ..cubicTo(pt().dx, pt().dy, pt().dx, pt().dy, b.dx, b.dy),
              vein);
        }
      case TileStyle.ice:
      case TileStyle.gem:
        final dot = Paint()..color = Colors.white.withValues(alpha: skin.style == TileStyle.ice ? 0.06 : 0.035);
        for (var k = 0; k < 140; k++) {
          c.drawCircle(Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height), 0.6 + rnd.nextDouble(), dot);
        }
      case TileStyle.candy:
        final stripe = Paint()
          ..strokeWidth = cell * 0.35
          ..color = Colors.white.withValues(alpha: 0.018);
        for (var x = -size.height; x < size.width; x += cell * 0.9) {
          c.drawLine(Offset(x, size.height), Offset(x + size.height, 0), stripe);
        }
      case TileStyle.gold:
      case TileStyle.neon:
        break;
    }
    final slot = Paint()..color = skin.slot;
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = skin.accent.withValues(alpha: 0.1);
    for (var i = 0; i < 81; i++) {
      final r = RRect.fromRectAndRadius(
          Rect.fromLTWH((i % 9) * cell, (i ~/ 9) * cell, cell, cell).deflate(cell * 0.08), Radius.circular(cell * skin.slotRadius));
      c.drawRRect(r, slot);
      if (skin.style == TileStyle.neon) c.drawRRect(r, outline);
    }
  }

  /// Separators drawn above the tiles.
  static void paintBoardForeground(Canvas c, Size size, BlockSkin skin) {
    final cell = size.width / 9;
    final thin = Paint()
      ..color = skin.thin
      ..strokeWidth = 1;
    final thick = Paint()
      ..color = skin.thick
      ..strokeWidth = 2.2;
    if (skin.style == TileStyle.neon) {
      final glow = Paint()
        ..color = skin.thick.withValues(alpha: 0.35)
        ..strokeWidth = 6
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
      for (var k = 3; k < 9; k += 3) {
        c.drawLine(Offset(k * cell, 0), Offset(k * cell, size.height), glow);
        c.drawLine(Offset(0, k * cell), Offset(size.width, k * cell), glow);
      }
    }
    for (var k = 1; k < 9; k++) {
      final paint = k % 3 == 0 ? thick : thin;
      c.drawLine(Offset(k * cell, 0), Offset(k * cell, size.height), paint);
      c.drawLine(Offset(0, k * cell), Offset(size.width, k * cell), paint);
    }
  }
}

/// A small 4×4 board sample of [skin] (picker cards, unlock toast).
class SkinPreviewPainter extends CustomPainter {
  final BlockSkin skin;
  final double dpr;
  SkinPreviewPainter(this.skin, this.dpr);

  // -2 empty, -1 stone, else hue seed.
  static const _layout = [0, 0, -2, 1, -2, 0, 2, 1, 3, -1, 2, -2, 3, 3, -2, 4];

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / 4;
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(cell * 0.3)));
    canvas.drawRect(Offset.zero & size, Paint()..color = skin.bg);
    final slot = Paint()..color = skin.slot;
    for (var i = 0; i < 16; i++) {
      final r = Rect.fromLTWH((i % 4) * cell, (i ~/ 4) * cell, cell, cell);
      final t = _layout[i];
      if (t == -2) {
        canvas.drawRRect(RRect.fromRectAndRadius(r.deflate(cell * 0.08), Radius.circular(cell * skin.slotRadius)), slot);
      } else {
        BlockTiles.draw(canvas, skin, t, i, r, dpr);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(SkinPreviewPainter old) => old.skin.id != skin.id || old.dpr != dpr;
}
