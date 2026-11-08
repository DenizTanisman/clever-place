import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core_bridge.dart';
import '../lux.dart';

/// Okey table: you (bottom) against three AI seats (right · across · left).
///
/// Every visible tile has a stable id (0..105, see `core/src/games/okey.rs`) and an eased visual
/// position, so draws, discards, takes and rack rearrangements glide on their own: the view only
/// computes where each tile *should* be from the core state. Hidden AI draws fly as tile backs.
///
/// Input (drag & drop first): drag a rack tile to any slot (gaps allowed; dropping on a tile
/// shifts the row towards the nearest gap), to your discard spot (bottom-right) to throw it, or to
/// the centre to finish. Drag the pile or the tile your left neighbour threw onto the rack to draw.
/// Taps work too: tap the pile / the offered tile; tap a rack tile, then a slot / the discard spot /
/// the centre. "Açık oyna" (eye) reveals every rack, the next pile tiles and the AI's reasons.
///
/// AI steps (`{"ai":true}` = one draw or one discard) run off the UI isolate after the previous
/// animation settled plus a human pause (draw 300–520 ms, discard 450–880 ms).
///
/// **101 Okey** (`variant: "101"` in the state) uses the same table, rack, tile art and drag
/// interactions, plus: the opened melds of every player in the middle (one row per player), a
/// drop/tap target per meld for işleme, the "Aç" pill next to the status line with the live total of
/// the melds arranged on your rack ("87 / 101"; long-press a meld on the rack to leave it out),
/// "Açılabilir mi?" (arranges and explains the best opening), "Geri ver" for a taken tile, a
/// penalty confirmation (a discard that costs 101 needs a second throw), the hand count chip and a
/// score table per hand on the result card. No finish zone: discarding the last tile finishes.
Widget okeyView(BuildContext context, GameSession s) => _OkeyTable(key: ObjectKey(s), session: s);

const int _cols = 14;
const int _slots = 28;

// =================================================================================================
// Tile art

class OkeyArt {
  OkeyArt._();

  static const colorNames = ['Kırmızı', 'Siyah', 'Mavi', 'Sarı'];
  static const ink = [Color(0xFFC4202F), Color(0xFF1E1D1B), Color(0xFF1B5CB6), Color(0xFFE08804)];
  static const ivoryHi = Color(0xFFFFFBF0);
  static const ivory = Color(0xFFF3EAD5);
  static const ivoryLo = Color(0xFFD9CBAA);
  static const edge = Color(0xFFB9A57E);

  static bool isFalse(int id) => id >= 104;
  static int kindOf(int id) => id % 52;
  static int colorOf(int id) => (id % 52) ~/ 13;
  static int numberOf(int id) => id % 13 + 1;

  static final Map<String, TextPainter> _text = {};

  static TextPainter _num(int n, int c, double size) {
    final key = '$n|$c|${size.toStringAsFixed(1)}';
    return _text.putIfAbsent(key, () {
      final tp = TextPainter(
        text: TextSpan(
          text: '$n',
          style: TextStyle(
            fontFamily: 'Jost',
            fontSize: size,
            fontWeight: FontWeight.w700,
            color: ink[c],
            height: 1.0,
            letterSpacing: -0.6,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      return tp;
    });
  }

  /// The false joker's emblem: a quatrefoil with a diamond heart (our own design).
  static Path falseJokerPath(Offset c, double r) {
    final p = Path()..fillType = PathFillType.nonZero;
    for (var i = 0; i < 4; i++) {
      final a = i * math.pi / 2 + math.pi / 4;
      p.addOval(Rect.fromCircle(center: c + Offset(math.cos(a), math.sin(a)) * r * 0.42, radius: r * 0.4));
    }
    return p;
  }

  static Path diamond(Offset c, double r) => Path()
    ..moveTo(c.dx, c.dy - r)
    ..lineTo(c.dx + r * 0.7, c.dy)
    ..lineTo(c.dx, c.dy + r)
    ..lineTo(c.dx - r * 0.7, c.dy)
    ..close();

  static Path star4(Offset c, double r) {
    final p = Path();
    for (var i = 0; i < 8; i++) {
      final a = -math.pi / 2 + i * math.pi / 4;
      final rr = i.isEven ? r : r * 0.38;
      final pt = c + Offset(math.cos(a), math.sin(a)) * rr;
      if (i == 0) {
        p.moveTo(pt.dx, pt.dy);
      } else {
        p.lineTo(pt.dx, pt.dy);
      }
    }
    return p..close();
  }

  /// Ivory tile body with depth (the darker lower edge) and a soft shadow.
  static void body(Canvas c, Rect r, {double lift = 0, Color? tint}) {
    final rad = Radius.circular(r.width * 0.16);
    final depth = r.height * 0.07;
    c.drawRRect(
      RRect.fromRectAndRadius(r.shift(Offset(0, depth + 1.5 + lift * 6)), rad),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.35 + 0.15 * lift)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2.5 + lift * 6),
    );
    c.drawRRect(RRect.fromRectAndRadius(r.shift(Offset(0, depth)), rad), Paint()..color = edge);
    final face = RRect.fromRectAndRadius(r, rad);
    c.drawRRect(
      face,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [ivoryHi, tint ?? ivory, ivoryLo],
          stops: const [0, 0.55, 1],
        ).createShader(r),
    );
    c.drawRRect(
      face.deflate(0.6),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9
        ..color = Colors.white.withValues(alpha: 0.7),
    );
  }

  /// A face-up tile. [okeyKind] marks the wild tiles with a small gold star (training aid).
  static void face(Canvas c, Rect r, int id, int okeyKind, {double lift = 0, double glow = 0, Color? glowColor}) {
    if (glow > 0) {
      c.drawRRect(
        RRect.fromRectAndRadius(r.inflate(2.5), Radius.circular(r.width * 0.2)),
        Paint()
          ..color = (glowColor ?? Lux.gold).withValues(alpha: 0.75 * glow)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
    }
    body(c, r, lift: lift);
    final w = r.width;
    if (isFalse(id)) {
      final cc = r.center.translate(0, -r.height * 0.04);
      final pth = falseJokerPath(cc, w * 0.36);
      c.drawPath(pth, Paint()..color = const Color(0xFF16523C));
      c.drawPath(
        pth,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * 0.04
          ..color = const Color(0xFFC9A04A),
      );
      c.drawPath(diamond(cc, w * 0.13), Paint()..color = const Color(0xFFF3D78F));
      return;
    }
    final col = colorOf(id);
    final n = numberOf(id);
    final tp = _num(n, col, w * (n >= 10 ? 0.56 : 0.64));
    final top = r.top + r.height * 0.13;
    tp.paint(c, Offset(r.center.dx - tp.width / 2, top));
    // The little circle under the number, as on classic tiles.
    final dot = Offset(r.center.dx, r.top + r.height * 0.74);
    c.drawCircle(dot, w * 0.11, Paint()..color = ink[col]);
    c.drawCircle(dot, w * 0.05, Paint()..color = ivory);
    if (kindOf(id) == okeyKind) {
      final sc = Offset(r.right - w * 0.2, r.top + w * 0.2);
      c.drawPath(star4(sc, w * 0.16), Paint()..color = const Color(0xFFC08A1E));
      c.drawPath(star4(sc, w * 0.1), Paint()..color = const Color(0xFFFBE7B0));
    }
  }

  /// Tile back (opponent racks, the pile): ivory with an emerald inlay and a gold hairline.
  static void back(Canvas c, Rect r, {double lift = 0}) {
    body(c, r, lift: lift, tint: const Color(0xFFEDE2C8));
    final inner = RRect.fromRectAndRadius(r.deflate(r.width * 0.17), Radius.circular(r.width * 0.1));
    c.drawRRect(
      inner,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1C6B51), Color(0xFF0A3628)],
        ).createShader(inner.outerRect),
    );
    c.drawRRect(
      inner.deflate(1.2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = Lux.gold.withValues(alpha: 0.75),
    );
    c.drawPath(diamond(r.center, r.width * 0.12), Paint()..color = Lux.gold.withValues(alpha: 0.85));
  }
}

/// A single static tile as a widget (result card, tutorials).
class OkeyTileView extends StatelessWidget {
  final int id;
  final int okeyKind;
  final double width;
  const OkeyTileView(this.id, {super.key, required this.okeyKind, this.width = 26});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: width,
        height: width * 1.42 + width * 0.12,
        child: CustomPaint(painter: _OneTile(id, okeyKind)),
      );
}

class _OneTile extends CustomPainter {
  final int id, okeyKind;
  _OneTile(this.id, this.okeyKind);
  @override
  void paint(Canvas canvas, Size size) =>
      OkeyArt.face(canvas, Rect.fromLTWH(0, 0, size.width, size.width * 1.42), id, okeyKind);
  @override
  bool shouldRepaint(_OneTile old) => old.id != id || old.okeyKind != okeyKind;
}

// =================================================================================================
// Geometry

class _Geo {
  final Size size;
  final bool v101;
  late final double slotW, tw, th, sideW, topH, k;
  late final Rect rack, table, inner, status;
  late final double x0, y0, y1;
  late final Offset pile, gost, chip, center, nextRow;
  late final List<Offset> corner;
  late final List<Offset> anchor;

  /// 101: the opened melds area and the "Aç" pill.
  late final Rect meldZone, openPill;

  _Geo(this.size, {this.v101 = false}) {
    const pad = 6.0;
    slotW = (size.width - 16 - 2 * pad) / _cols;
    tw = slotW - 2.2;
    th = tw * 1.42;
    final tierH = th + 11;
    final rackH = tierH * 2 + 12;
    rack = Rect.fromLTWH(8, size.height - rackH, size.width - 16, rackH);
    x0 = rack.left + pad;
    y0 = rack.top + 7 + th / 2;
    y1 = y0 + tierH;
    final fullStatus = Rect.fromLTWH(10, rack.top - 68, size.width - 20, 64);
    openPill = Rect.fromLTRB(fullStatus.right - 96, fullStatus.top + 4, fullStatus.right, fullStatus.bottom - 4);
    status = v101 ? Rect.fromLTRB(fullStatus.left, fullStatus.top, openPill.left - 6, fullStatus.bottom) : fullStatus;
    table = Rect.fromLTRB(0, 0, size.width, fullStatus.top - 2);
    k = 0.6;
    sideW = math.max(58, tw * k * 2 + 16);
    topH = 34 + th * k + 8;
    inner = Rect.fromLTRB(sideW, topH, size.width - sideW, table.bottom - 2);
    center = inner.center;
    final dx = math.min(tw * 2.3, inner.width * 0.3);
    final cx = tw * 0.8 + 8, cy = th * 0.62 + 8;
    if (v101) {
      // Pile row along the top edge, the melds below it.
      final py = inner.top + cy;
      pile = Offset(center.dx - dx, py);
      gost = Offset(center.dx, py);
      chip = Offset(center.dx + dx, py);
      nextRow = Offset(center.dx, py + th * 0.62 + 24);
      meldZone = Rect.fromLTRB(inner.left + 4, nextRow.dy + th * 0.3 + 4, inner.right - 4, inner.bottom - cy - th * 0.62 - 2);
    } else {
      pile = center + Offset(-dx, -th * 0.7);
      gost = center + Offset(0, -th * 0.7);
      chip = center + Offset(dx, -th * 0.7);
      nextRow = center + Offset(0, th * 0.75);
      meldZone = Rect.zero;
    }
    corner = [
      Offset(inner.right - cx, inner.bottom - cy), // you → right
      Offset(inner.right - cx, inner.top + cy), // right → across
      Offset(inner.left + cx, inner.top + cy), // across → left
      Offset(inner.left + cx, inner.bottom - cy), // left → you
    ];
    anchor = [
      Offset(size.width / 2, rack.center.dy),
      Offset(size.width - sideW / 2, inner.center.dy),
      Offset(size.width / 2, 34 + th * k / 2),
      Offset(sideW / 2, inner.center.dy),
    ];
  }

  double get sideTop => inner.top + 76;

  Offset slot(int i) => Offset(x0 + (i % _cols + 0.5) * slotW, i < _cols ? y0 : y1);
  Rect tile(Offset c, [double s = 1]) => Rect.fromCenter(center: c, width: tw * s, height: th * s);
  Rect cornerRect(int seat) => tile(corner[seat], 1.15).inflate(6);
  double get finishR => math.min(tw * 2.0, inner.height * 0.22);

  int? slotAt(Offset p) {
    if (!rack.inflate(14).contains(p)) return null;
    final col = ((p.dx - x0) / slotW).floor().clamp(0, _cols - 1);
    final row = p.dy < (y0 + y1) / 2 ? 0 : 1;
    return row * _cols + col;
  }

  /// Small face-up tiles of an opponent's rack in open play.
  Offset openPos(int seat, int i, int n) {
    final w = tw * k + 1.5, h = th * k + 3;
    if (seat == 2) {
      return Offset(size.width / 2 + (i - (n - 1) / 2) * w, 34 + th * k / 2);
    }
    final rows = (n + 1) ~/ 2;
    final cx = seat == 1 ? size.width - sideW / 2 : sideW / 2;
    final colI = i ~/ rows, rowI = i % rows;
    return Offset(cx + (colI - 0.5) * w, sideTop + rowI * h + th * k / 2);
  }
}

class _T {
  final Offset c;
  final double s;
  final bool face;
  final int layer;
  final int z;
  const _T(this.c, this.s, this.face, this.layer, this.z);
}

class _Ghost {
  final int id;
  final bool face;
  final Offset from;
  final int seat;
  final double t0, dur;
  _Ghost(this.id, this.face, this.from, this.seat, this.t0, this.dur);
}

class _Drag {
  final String kind; // rack | pile | offer
  final int id; // -1 for a pile tile (unknown)
  final int? from; // rack slot
  Offset pos;
  final Offset grab;
  _Drag(this.kind, this.id, this.from, this.pos, this.grab);
}

/// 101: where the opened melds sit (one block of rows per player).
class _TableLay {
  final Map<int, Offset> pos = {};
  final List<Rect> rects = [];
  final List<(int seat, Offset at)> labels = [];
  double scale = 0.6;
}

// =================================================================================================

class _OkeyTable extends StatefulWidget {
  final GameSession session;
  const _OkeyTable({super.key, required this.session});

  @override
  State<_OkeyTable> createState() => _OkeyTableState();
}

class _OkeyTableState extends State<_OkeyTable> with SingleTickerProviderStateMixin {
  GameSession get s => widget.session;
  Map<String, dynamic> get st => s.state;

  late final Ticker _ticker;
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;
  double _lastT = 0;
  final _rand = math.Random();

  final Map<int, Offset> _vis = {};
  final Map<int, double> _visS = {};
  Map<int, _T> _targets = {};
  final List<_Ghost> _ghosts = [];
  _Geo? _g;

  bool _open = false;
  bool _aiBusy = false;
  double _thinkFrom = -1;
  int _seenSerial = 0;
  int _seenVersion = -1;
  int _seenHand = 0;
  _Drag? _drag;
  int? _hoverSlot;
  String? _hoverZone; // discard | finish
  int? _selected; // rack slot
  int? _shakeId;
  double _shakeAt = -10;
  double _endAt = -10;

  // 101 only.
  int? _hoverMeld;
  bool _hoverLow = false;
  final Set<int> _excluded = {}; // rack tiles of melds left out of the "Aç" selection
  int? _confirmPenalty; // a penalised discard was refused once: the next throw of it is forced
  _TableLay _tbl = _TableLay();

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => _onTick());
    _seenVersion = _int(st['version'], -1);
    final last = st['last'];
    _seenSerial = last is Map ? _int(last['serial']) : 0;
    _seenHand = _int(st['hand_no']);
    s.addListener(_onSession);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAi());
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadHands());
  }

  static const _handsKey = 'cp.okey101.hands';

  /// 101: apply the remembered hand count to a fresh match.
  Future<void> _loadHands() async {
    if (!_is101) return;
    try {
      final p = await SharedPreferences.getInstance();
      final n = p.getInt(_handsKey);
      if (!mounted || n == null) return;
      if (_int(st['hand_no']) == 1 && st['phase'] == 'play' && _int(st['max_hands']) != n) s.act({'hands': n});
    } catch (_) {}
  }

  void _cycleHands() {
    final choices = [for (final x in (st['hand_choices'] as List? ?? const [3, 5, 7])) _int(x)];
    if (choices.isEmpty) return;
    final i = choices.indexOf(_int(st['max_hands'], 5));
    final next = choices[(i + 1) % choices.length];
    if (s.act({'hands': next})) {
      HapticFeedback.selectionClick();
      SharedPreferences.getInstance().then((p) => p.setInt(_handsKey, next)).catchError((_) => false);
    }
  }

  @override
  void dispose() {
    s.removeListener(_onSession);
    _ticker.dispose();
    super.dispose();
  }

  static int _int(Object? v, [int d = 0]) => (v as num?)?.toInt() ?? d;

  List<int> get _layout => [for (final v in (st['layout'] as List? ?? const [])) _int(v, -1)];
  int get _okey => _int((st['okey'] as Map?)?['kind'], -1);
  List<Map<String, dynamic>> get _seats =>
      [for (final x in (st['seats'] as List? ?? const [])) Map<String, dynamic>.from(x as Map)];
  bool get _playing => st['phase'] == 'play' && !s.finished;
  bool get _yourTurn => _playing && st['turn'] == 'you';
  bool get _drawStage => st['stage'] == 'draw';
  bool get _showAll => _open || st['phase'] == 'hand_end';

  bool get _is101 => st['variant'] == '101';
  List<Map<String, dynamic>> get _table =>
      [for (final x in (st['table'] as List? ?? const [])) Map<String, dynamic>.from(x as Map)];
  Set<int> get _penaltyTiles => {for (final x in (st['penalty_tiles'] as List? ?? const [])) _int(x)};
  Map<int, List<int>> get _addable => {
        for (final x in (st['addable'] as List? ?? const []))
          _int((x as Map)['tile']): [for (final m in (x['melds'] as List? ?? const [])) _int(m)]
      };
  int? get _mustUse => st['must_use'] == null ? null : _int(st['must_use']);

  /// The melds arranged on the rack that the "Aç" pill would lay (runs/sets and pairs apart).
  ({int value, List<List<int>> runs, List<List<int>> prs}) _selection() {
    final lay = _layout;
    var value = 0;
    final runs = <List<int>>[], prs = <List<int>>[];
    for (final m in (st['melds'] as List? ?? const [])) {
      final mm = m as Map;
      final ids = [for (final x in (mm['slots'] as List? ?? const [])) _int(x) < lay.length ? lay[_int(x)] : -1];
      if (ids.isEmpty || ids.any((i) => i < 0) || ids.any(_excluded.contains)) continue;
      if (mm['kind'] == 'pair') {
        prs.add(ids);
      } else {
        runs.add(ids);
        value += _int(mm['value']);
      }
    }
    return (value: value, runs: runs, prs: prs);
  }

  // ---------------------------------------------------------------------------------------------
  // Session events

  void _onSession() {
    final ver = _int(st['version'], -1);
    if (ver == _seenVersion) return;
    _seenVersion = ver;
    final hand = _int(st['hand_no']);
    if (hand != _seenHand) {
      _seenHand = hand;
      _vis.clear();
      _visS.clear();
      _ghosts.clear();
      _selected = null;
      _excluded.clear();
      _confirmPenalty = null;
      _dealAt = _now;
    }
    final last = st['last'];
    final serial = last is Map ? _int(last['serial']) : 0;
    if (serial != _seenSerial && last is Map) {
      final fresh = serial == _seenSerial + 1;
      _seenSerial = serial;
      if (fresh) _event(Map<String, dynamic>.from(last));
    }
    if (st['phase'] == 'hand_end' && _endAt < 0) {
      _endAt = _now;
      final res = st['result'];
      final w = res is Map ? res['winner'] : null;
      if (w == 0) {
        HapticFeedback.heavyImpact();
      } else {
        HapticFeedback.mediumImpact();
      }
    } else if (st['phase'] == 'play') {
      _endAt = -10;
    }
    if (mounted) setState(() {});
    _kick();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAi());
  }

  double _dealAt = -10;

  void _event(Map<String, dynamic> e) {
    final seat = _int(e['seat']);
    final kind = e['kind'] as String? ?? '';
    final tile = e['tile'] == null ? null : _int(e['tile']);
    final g = _g;
    if (g == null || tile == null) return;
    if (seat != 0 && !_showAll) {
      if (kind == 'pile') {
        _ghosts.add(_Ghost(tile, false, g.pile, seat, _now, 0.42));
      } else if (kind == 'take') {
        _ghosts.add(_Ghost(tile, true, _vis[tile] ?? g.corner[_Seats.left(seat)], seat, _now, 0.46));
      }
    }
    if (kind == 'discard' && seat != 0) HapticFeedback.selectionClick();
  }

  // ---------------------------------------------------------------------------------------------
  // AI pacing

  void _maybeAi() {
    if (!mounted || _aiBusy || st['ai_pending'] != true || st['phase'] != 'play' || s.finished) return;
    _aiBusy = true;
    final settle = _settleTime();
    final pause = _drawStage ? 0.30 + _rand.nextDouble() * 0.22 : 0.45 + _rand.nextDouble() * 0.43;
    _thinkFrom = _now + settle;
    final session = s;
    _kick();
    Future.delayed(Duration(milliseconds: ((settle + pause) * 1000).round()), () async {
      if (!mounted || !identical(session, s)) return;
      if (st['ai_pending'] != true || st['phase'] != 'play') {
        setState(() => _aiBusy = false);
        return;
      }
      final ok = await s.actAsync({'ai': true});
      if (!mounted) return;
      _reapplyArrange();
      setState(() => _aiBusy = false);
      if (ok) WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAi());
    });
  }

  double _settleTime() {
    var far = 0.0;
    _targets.forEach((id, t) {
      final v = _vis[id];
      if (v != null) far = math.max(far, (v - t.c).distance);
    });
    var t = far > 3 ? 0.32 : 0.0;
    for (final gh in _ghosts) {
      t = math.max(t, gh.t0 + gh.dur - _now);
    }
    return t + 0.05;
  }

  // ---------------------------------------------------------------------------------------------
  // Motion

  void _kick() {
    if (!_ticker.isActive) {
      _lastT = _now;
      _ticker.start();
    }
  }

  void _onTick() {
    final now = _now;
    final dt = (now - _lastT).clamp(0.0, 0.05);
    _lastT = now;
    final k = 1 - math.exp(-dt * 12.5);
    var moving = false;
    _targets.forEach((id, t) {
      final v = _vis[id] ?? t.c;
      var nv = Offset.lerp(v, t.c, k)!;
      if ((nv - t.c).distance < 0.35) {
        nv = t.c;
      } else {
        moving = true;
      }
      _vis[id] = nv;
      final sv = _visS[id] ?? t.s;
      final ns = sv + (t.s - sv) * k;
      _visS[id] = (ns - t.s).abs() < 0.004 ? t.s : ns;
      if (_visS[id] != t.s) moving = true;
    });
    _ghosts.removeWhere((gh) => now > gh.t0 + gh.dur);
    final busy = moving ||
        _ghosts.isNotEmpty ||
        _drag != null ||
        _aiBusy ||
        now - _shakeAt < 0.45 ||
        now - _endAt < 1.2 ||
        now - _dealAt < 1.0 ||
        (st['hint'] is Map && (st['hint'] as Map)['tile'] != null);
    if (!busy) _ticker.stop();
    if (mounted) setState(() {});
  }

  /// Where every visible tile should be, from the state.
  Map<int, _T> _computeTargets(_Geo g) {
    final t = <int, _T>{};
    var z = 0;
    void put(int id, Offset c, double sc, int layer) => t[id] = _T(c, sc, true, layer, layer * 1000 + z++);
    final lay = _layout;
    for (var i = 0; i < lay.length && i < _slots; i++) {
      if (lay[i] >= 0) put(lay[i], g.slot(i), 1, 5);
    }
    final seats = _seats;
    for (var seat = 0; seat < seats.length; seat++) {
      final d = [for (final x in (seats[seat]['discards'] as List? ?? const [])) _int(x)];
      for (var j = math.max(0, d.length - 3); j < d.length; j++) {
        final depth = d.length - 1 - j;
        put(d[j], g.corner[seat] + Offset(-2.5 * depth, -2.5 * depth), 1.08, 1);
      }
      if (seat > 0 && _showAll) {
        final tiles = [for (final x in (seats[seat]['tiles'] as List? ?? const [])) _int(x)];
        for (var j = 0; j < tiles.length; j++) {
          put(tiles[j], g.openPos(seat, j, tiles.length), g.k, 3);
        }
      }
    }
    final ind = _int(st['indicator'], -1);
    if (ind >= 0) put(ind, g.gost, 1.12, 2);
    for (final e in _tbl.pos.entries) {
      put(e.key, e.value, _tbl.scale, 2);
    }
    final res = st['result'];
    if (res is Map && res['finish_tile'] != null) {
      put(_int(res['finish_tile']), g.nextRow, 1.12, 4);
    }
    if (_showAll && st['phase'] == 'play') {
      final pile = [for (final x in (st['pile'] as List? ?? const [])) _int(x)];
      for (var j = 0; j < math.min(5, pile.length); j++) {
        put(pile[j], g.nextRow + Offset((j - 2) * (g.tw * 0.72 + 3), 0), 0.7, 2);
      }
    }
    // New tiles start where they came from.
    final last = st['last'];
    var moving = false;
    for (final e in t.entries) {
      final cur = _vis[e.key];
      if (cur != null) {
        if ((cur - e.value.c).distance > 0.5 || (_visS[e.key] ?? 1) != e.value.s) moving = true;
        continue;
      }
      Offset start = e.value.c;
      if (last is Map && _int(last['tile'], -1) == e.key) {
        final kind = last['kind'];
        final seat = _int(last['seat']);
        if (kind == 'pile') start = g.pile;
        if (kind == 'discard' || kind == 'finish' || kind == 'open' || kind == 'lay' || kind == 'add') start = g.anchor[seat];
      } else if (last is Map && _tbl.pos.containsKey(e.key) && const ['open', 'lay', 'add'].contains(last['kind'])) {
        // Melds an opponent laid fly in from its seat.
        start = g.anchor[_int(last['seat'])];
      } else if (now0(e.key)) {
        start = g.pile;
      }
      if (!_built) start = e.value.c;
      if (start != e.value.c) moving = true;
      _vis[e.key] = start;
      _visS[e.key] = e.value.s;
    }
    _built = true;
    _vis.removeWhere((id, _) => !t.containsKey(id));
    if (moving && !_ticker.isActive) WidgetsBinding.instance.addPostFrameCallback((_) => _kick());
    return t;
  }

  bool _built = false;

  /// Dealing: rack tiles fly in from the pile right after a new hand.
  bool now0(int id) => _now - _dealAt < 0.2;

  // ---------------------------------------------------------------------------------------------
  // Input

  bool _hitTile(Offset p, Offset c, _Geo g, [double s = 1]) => g.tile(c, s).inflate(4).contains(p);

  int? _offerId() => st['take_tile'] == null ? null : _int(st['take_tile']);

  void _panStart(Offset p) {
    final g = _g;
    if (g == null || st['phase'] != 'play' || s.finished) return;
    final slot = g.slotAt(p);
    if (slot != null) {
      final lay = _layout;
      if (slot < lay.length && lay[slot] >= 0 && g.tile(g.slot(slot)).inflate(3).contains(p)) {
        final id = lay[slot];
        HapticFeedback.selectionClick();
        setState(() {
          _drag = _Drag('rack', id, slot, _vis[id] ?? g.slot(slot), p - (_vis[id] ?? g.slot(slot)));
          _selected = null;
        });
        _kick();
        return;
      }
    }
    if (_yourTurn && _drawStage) {
      if (_hitTile(p, g.pile, g, 1.1) && _int(st['pile_count']) > 0) {
        HapticFeedback.selectionClick();
        setState(() => _drag = _Drag('pile', -1, null, g.pile, p - g.pile));
        _kick();
        return;
      }
      final offer = _offerId();
      if (offer != null && g.cornerRect(3).contains(p)) {
        HapticFeedback.selectionClick();
        final c = _vis[offer] ?? g.corner[3];
        setState(() => _drag = _Drag('offer', offer, null, c, p - c));
        _kick();
      }
    }
  }

  void _panUpdate(Offset p) {
    final d = _drag, g = _g;
    if (d == null || g == null) return;
    d.pos = p - d.grab;
    final c = d.pos;
    int? hs = g.slotAt(c);
    String? zone;
    int? hm;
    if (d.kind == 'rack') {
      if (g.cornerRect(0).inflate(8).contains(c)) {
        zone = 'discard';
        hs = null;
      } else if (_is101) {
        hm = _meldAt(c);
        if (hm != null) {
          zone = 'meld';
          hs = null;
          _hoverLow = c.dx < _tbl.rects[hm].center.dx;
        }
      } else if ((c - g.center).distance < g.finishR) {
        zone = 'finish';
        hs = null;
      }
    }
    if (hs != _hoverSlot || zone != _hoverZone || hm != _hoverMeld) HapticFeedback.selectionClick();
    setState(() {
      _hoverSlot = hs;
      _hoverZone = zone;
      _hoverMeld = hm;
    });
  }

  /// 101: the table meld under `p`.
  int? _meldAt(Offset p) {
    final r = _tbl.rects;
    for (var i = 0; i < r.length; i++) {
      if (r[i] != Rect.zero && r[i].inflate(5).contains(p)) return i;
    }
    return null;
  }

  void _add(int id, int meld, bool low) {
    if (s.act({
      'add': {'tile': id, 'meld': meld, 'end': low ? 'low' : 'high'}
    })) {
      HapticFeedback.lightImpact();
    } else {
      _reject(id);
    }
  }

  /// 101: lay the melds arranged on the rack (the opening when not opened yet).
  void _openMelds() {
    final sel = _selection();
    final me = _seats.isNotEmpty ? _seats[0] : const <String, dynamic>{};
    final opened = me['opened'] == true;
    final need = _int(st['need'], 101), needP = _int(st['need_pairs'], 5);
    final List<List<int>> groups;
    if (!opened) {
      groups = (sel.value < need && sel.prs.length >= needP) ? sel.prs : sel.runs;
    } else {
      groups = me['open_kind'] == 'pairs' ? sel.prs : sel.runs;
    }
    if (s.act({'lay': groups})) {
      HapticFeedback.heavyImpact();
      setState(_excluded.clear);
    } else {
      HapticFeedback.mediumImpact();
    }
  }

  /// 101: a tap on a meld's point label under the rack toggles it out of / into the selection.
  bool _toggleMeldAt(Offset p, _Geo g) {
    final lay = _layout;
    for (final m in (st['melds'] as List? ?? const [])) {
      final slots = [for (final x in ((m as Map)['slots'] as List? ?? const [])) _int(x)];
      if (slots.isEmpty) continue;
      final a = g.slot(slots.first), b = g.slot(slots.last);
      final label = Rect.fromLTRB(a.dx - g.tw / 2, a.dy + g.th / 2, b.dx + g.tw / 2, a.dy + g.th / 2 + 10);
      if (!label.contains(p)) continue;
      final ids = [for (final sl in slots) if (sl < lay.length && lay[sl] >= 0) lay[sl]];
      setState(() {
        if (ids.any(_excluded.contains)) {
          _excluded.removeAll(ids);
        } else {
          _excluded.addAll(ids);
        }
      });
      HapticFeedback.selectionClick();
      return true;
    }
    return false;
  }

  void _panEnd() {
    final d = _drag;
    if (d == null) return;
    final slot = _hoverSlot, zone = _hoverZone, meld = _hoverMeld;
    setState(() {
      _drag = null;
      _hoverSlot = null;
      _hoverZone = null;
      _hoverMeld = null;
    });
    if (d.kind == 'rack') {
      _vis[d.id] = d.pos;
      if (zone == 'discard') {
        _throw(d.id);
      } else if (zone == 'meld' && meld != null) {
        _add(d.id, meld, _hoverLow);
      } else if (zone == 'finish') {
        _finish(d.id);
      } else if (slot != null && slot != d.from) {
        _moveSlot(d.from!, slot);
      }
    } else {
      if (d.kind == 'offer') _vis[d.id] = d.pos;
      if ((d.pos - (d.kind == 'pile' ? _g!.pile : _g!.corner[3])).distance < 18) {
        _kick();
        return; // put back
      }
      _draw(d.kind == 'offer', slot, from: d.pos);
    }
    _kick();
  }

  void _tap(Offset p) {
    final g = _g;
    if (g == null || st['phase'] != 'play' || s.finished) return;
    final slot = g.slotAt(p);
    final lay = _layout;
    if (_yourTurn && _drawStage) {
      if (_hitTile(p, g.pile, g, 1.1)) {
        _draw(false, null);
        return;
      }
      if (_offerId() != null && g.cornerRect(3).contains(p)) {
        _draw(true, null);
        return;
      }
    }
    final sel = _selected;
    if (_is101 && sel == null && _toggleMeldAt(p, g)) return;
    if (sel != null && sel < lay.length && lay[sel] >= 0) {
      final id = lay[sel];
      if (g.cornerRect(0).contains(p)) {
        setState(() => _selected = null);
        _throw(id);
        return;
      }
      final mi = _is101 ? _meldAt(p) : null;
      if (mi != null) {
        setState(() => _selected = null);
        _add(id, mi, p.dx < _tbl.rects[mi].center.dx);
        return;
      }
      if (!_is101 && (p - g.center).distance < g.finishR) {
        setState(() => _selected = null);
        _finish(id);
        return;
      }
      if (slot != null) {
        setState(() => _selected = null);
        if (slot != sel) _moveSlot(sel, slot);
        return;
      }
    }
    if (slot != null && slot < lay.length && lay[slot] >= 0) {
      HapticFeedback.selectionClick();
      setState(() => _selected = _selected == slot ? null : slot);
      _kick();
    } else {
      setState(() => _selected = null);
    }
  }

  void _reject(int id) {
    HapticFeedback.mediumImpact();
    _shakeId = id;
    _shakeAt = _now;
    _kick();
  }

  void _throw(int id) {
    if (!_yourTurn || _drawStage) {
      _reject(id);
      s.act({'discard': id}); // the core explains why (toast)
      return;
    }
    // 101: a discard that costs 101 is refused once (the core says why); throwing it again forces it.
    final pen = _is101 && _penaltyTiles.contains(id);
    final force = pen && _confirmPenalty == id;
    if (s.act({'discard': id, if (force) 'force': true})) {
      _confirmPenalty = null;
      HapticFeedback.lightImpact();
    } else {
      if (pen) _confirmPenalty = id;
      _reject(id);
    }
  }

  void _finish(int id) {
    if (s.act({'finish': id})) {
      HapticFeedback.heavyImpact();
    } else {
      _reject(id);
    }
  }

  void _draw(bool take, int? slot, {Offset? from}) {
    final lay = _layout;
    final free = slot != null && slot < lay.length && lay[slot] < 0;
    final ok = s.act({'draw': take ? 'discard' : 'pile', if (free) 'slot': slot});
    if (!ok) {
      HapticFeedback.mediumImpact();
      return;
    }
    HapticFeedback.selectionClick();
    // The new tile starts where the finger let go.
    final last = st['last'];
    final id = last is Map ? _int(last['tile'], -1) : -1;
    if (id >= 0 && from != null) _vis[id] = from;
    if (slot != null && !free && id >= 0) {
      final now = _layout;
      final at = now.indexOf(id);
      if (at >= 0 && at != slot) s.act({'arrange': _moved(now, at, slot)});
    }
  }

  void _moveSlot(int from, int to) {
    final lay = _layout;
    if (from >= lay.length || lay[from] < 0) return;
    HapticFeedback.selectionClick();
    final next = _moved(lay, from, to);
    if (s.act({'arrange': next})) {
      _arranged = next;
      _arrangedVersion = _int(st['version']);
    }
  }

  List<int>? _arranged;
  int _arrangedVersion = -1;

  /// An AI step computed off-isolate may return a state older than a rearrangement made meanwhile.
  void _reapplyArrange() {
    final a = _arranged;
    if (a == null) return;
    if (_int(st['version']) < _arrangedVersion) {
      final cur = _layout.where((x) => x >= 0).toSet();
      if (cur.length == a.where((x) => x >= 0).length && a.where((x) => x >= 0).every(cur.contains)) {
        s.act({'arrange': a});
      }
    }
    _arranged = null;
  }

  /// Move a rack tile; dropping onto a tile shifts that row towards the nearest gap.
  static List<int> _moved(List<int> lay, int from, int to) {
    final l = [...lay];
    while (l.length < _slots) {
      l.add(-1);
    }
    final id = l[from];
    l[from] = -1;
    if (l[to] < 0) {
      l[to] = id;
      return l;
    }
    final start = (to ~/ _cols) * _cols, end = start + _cols;
    int? gap;
    for (var d = 1; d < _cols; d++) {
      if (to + d < end && l[to + d] < 0) {
        gap = to + d;
        break;
      }
      if (to - d >= start && l[to - d] < 0) {
        gap = to - d;
        break;
      }
    }
    if (gap == null) {
      l[from] = l[to];
      l[to] = id;
      return l;
    }
    if (gap > to) {
      for (var i = gap; i > to; i--) {
        l[i] = l[i - 1];
      }
    } else {
      for (var i = gap; i < to; i++) {
        l[i] = l[i + 1];
      }
    }
    l[to] = id;
    return l;
  }

  // ---------------------------------------------------------------------------------------------
  // Build

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(builder: (context, box) {
            final size = Size(box.maxWidth, box.maxHeight);
            final v101 = _is101;
            final g = (_g != null && _g!.size == size && _g!.v101 == v101) ? _g! : (_g = _Geo(size, v101: v101));
            _tbl = v101 ? _layoutTable(g) : _TableLay();
            _targets = _computeTargets(g);
            final now = _now;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (d) => _panStart(d.localPosition),
                    onPanUpdate: (d) => _panUpdate(d.localPosition),
                    onPanEnd: (_) => _panEnd(),
                    onPanCancel: _panEnd,
                    onTapUp: (d) => _tap(d.localPosition),
                    child: CustomPaint(painter: _TablePainter(this, g, now)),
                  ),
                ),
                ..._plates(g, now),
                Positioned(
                  right: 4,
                  top: 0,
                  child: _EyeToggle(open: _open, onTap: () => setState(() => _open = !_open)),
                ),
                Positioned.fromRect(rect: g.status, child: IgnorePointer(child: _statusBox())),
                if (_is101) Positioned.fromRect(rect: g.openPill, child: _openPill()),
                if (st['phase'] == 'hand_end' && _now - _endAt > 0.9)
                  Positioned.fromRect(
                      rect: g.table.deflate(10), child: Center(child: _is101 ? _resultCard101(g) : _resultCard(g))),
              ],
            );
          }),
        ),
        _is101 ? _buttons101() : _buttons(),
      ],
    );
  }

  List<Widget> _plates(_Geo g, double now) {
    final seats = _seats;
    if (seats.length < 4) return const [];
    final active = _playing ? _int(st['seat']) : -1;
    Widget plate(int seat, {bool vertical = false}) {
      final x = seats[seat];
      final on = active == seat;
      final thinking = on && _aiBusy && now >= _thinkFrom;
      final breath = thinking ? 0.5 + 0.5 * math.sin(now * 4.2) : (on ? 0.35 : 0.0);
      final name = x['name'] as String? ?? '';
      final score = _int(x['score']);
      final count = _int(x['count']);
      // 101: lower totals are better; show the opening and this hand's penalties.
      final v101 = _is101;
      final pen = _int(x['hand']);
      final openTag = x['opened'] == true ? (x['open_kind'] == 'pairs' ? 'çift açtı' : '${_int(x['open_value'])} açtı') : '';
      final children = <Widget>[
        Text(name, style: Lux.ui(13, color: on ? Lux.goldLight : Lux.ink, weight: FontWeight.w600)),
        Text('$score', style: Lux.numeral(17, color: !v101 && score <= 6 ? Lux.bordeauxLight : Lux.gold)),
        if (!vertical) const SizedBox(width: 6),
        Text(thinking ? 'düşünüyor' : '$count taş', style: Lux.ui(10.5, color: thinking ? Lux.goldLight : Lux.muted)),
        if (v101 && openTag.isNotEmpty) ...[
          if (!vertical) const SizedBox(width: 6),
          Text(openTag, style: Lux.ui(10, color: Lux.goldLight, weight: FontWeight.w600)),
        ],
        if (v101 && pen > 0) ...[
          if (!vertical) const SizedBox(width: 6),
          Text('+$pen ceza', style: Lux.ui(10, color: Lux.bordeauxLight, weight: FontWeight.w600)),
        ],
      ];
      return Container(
        padding: EdgeInsets.symmetric(horizontal: vertical ? 4 : 10, vertical: 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: const Color(0xCC05241C),
          border: Border.all(color: Color.lerp(Lux.line, Lux.gold, breath)!),
          boxShadow: [BoxShadow(color: Lux.gold.withValues(alpha: 0.25 * breath), blurRadius: 4 + 10 * breath)],
        ),
        child: vertical
            ? Column(mainAxisSize: MainAxisSize.min, children: children)
            : Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
                children[0],
                const SizedBox(width: 6),
                ...children.skip(1),
              ]),
      );
    }

    return [
      Positioned(left: 0, right: 0, top: 0, child: Center(child: IgnorePointer(child: plate(2)))),
      Positioned(left: 2, top: g.inner.top - 4, width: g.sideW - 4, child: IgnorePointer(child: plate(3, vertical: true))),
      Positioned(right: 2, top: g.inner.top - 4, width: g.sideW - 4, child: IgnorePointer(child: plate(1, vertical: true))),
    ];
  }

  Widget _statusBox() {
    final last = st['last'];
    String line1 = '';
    String? why;
    var c1 = Lux.ink;
    if (last is Map) {
      line1 = last['text'] as String? ?? '';
      final seat = _int(last['seat']);
      final r = last['reason'] as String? ?? '';
      if (_open && seat != 0 && r.isNotEmpty) why = r;
    }
    final hint = st['hint'];
    String line2;
    var c2 = Lux.muted;
    final showHint = hint is Map && (_yourTurn || hint['kind'] == 'suggest');
    if (hint is Map && showHint) {
      line2 = hint['text'] as String? ?? '';
      c2 = Lux.goldLight;
    } else if (why != null) {
      line2 = 'Neden? $why';
      c2 = const Color(0xFFD9C48E);
    } else if (_yourTurn && _is101) {
      final me = _seats.isNotEmpty ? _seats[0] : const <String, dynamic>{};
      final must = _mustUse;
      if (_drawStage) {
        line2 = 'Sıra sende: desteden çek ya da soldakini al (alırsan bu el kullanmalısın)';
      } else if (must != null) {
        line2 = 'Yandan aldığın taşı bu el kullan: aç, pere koy ya da işle · olmazsa Geri ver';
      } else if (me['opened'] != true) {
        line2 = 'Perleri diz, 101 olunca Aç · sonra bir taş at';
      } else if (_int(me['count']) <= 1) {
        line2 = 'Son taşını at: bitiriyorsun!';
      } else {
        line2 = 'İşlemek için taşı masadaki pere sürükle · sonra bir taş at';
      }
      c2 = Lux.gold;
    } else if (_yourTurn) {
      line2 = _drawStage
          ? 'Sıra sende: ortadaki desteden çek ya da soldan gelen taşı al'
          : 'Bir taş at (sağ alttaki yere sürükle) · bitirmek için ortaya bırak';
      c2 = Lux.gold;
      c1 = Lux.ink;
    } else if (_playing) {
      final seat = _int(st['seat']);
      final names = _seats.map((e) => e['name'] as String? ?? '').toList();
      line2 = seat < names.length ? '${names[seat]} oynuyor…' : '';
    } else {
      line2 = '';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: const Color(0x8805241C),
        border: Border.all(color: showHint ? Lux.gold.withValues(alpha: 0.7) : Lux.lineFaint),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(line1, maxLines: 1, overflow: TextOverflow.ellipsis, style: Lux.ui(13.5, color: c1, weight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(line2, maxLines: 2, overflow: TextOverflow.ellipsis, style: Lux.ui(12, color: c2)),
        ],
      ),
    );
  }

  Widget _buttons() {
    final seats = _seats;
    final me = seats.isNotEmpty ? _int(seats[0]['score']) : 0;
    final canPlay = st['phase'] == 'play' && !s.finished;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Lux.line),
              color: const Color(0x6605241C),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('Puanın', style: Lux.ui(10.5, color: Lux.muted)),
              Text('$me', style: Lux.numeral(19, color: me <= 6 ? Lux.bordeauxLight : Lux.goldLight)),
            ]),
          ),
          const Spacer(),
          _SmallButton('Seri diz', onTap: canPlay ? () => s.act({'auto_arrange': 'runs'}) : null),
          const SizedBox(width: 8),
          _SmallButton('Çift diz', onTap: canPlay ? () => s.act({'auto_arrange': 'pairs'}) : null),
          const SizedBox(width: 10),
          RimIconButton(
            Icons.lightbulb_outline_rounded,
            tooltip: 'İpucu: en iyi hamle ve nedeni',
            onPressed: _yourTurn && st['hint'] is! Map
                ? () {
                    s.actAsync({'hint': true}).then((_) => _kick());
                    _kick();
                  }
                : null,
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------------------------
  // 101 pieces

  /// Opened melds: one block of rows per player (across, left, right, you), mini tiles that shrink
  /// until everything fits the zone.
  _TableLay _layoutTable(_Geo g) {
    final table = _table;
    final zone = g.meldZone;
    final byOwner = <int, List<int>>{};
    for (var i = 0; i < table.length; i++) {
      byOwner.putIfAbsent(_int(table[i]['owner']), () => []).add(i);
    }
    const order = [2, 3, 1, 0];
    const labelW = 42.0;
    for (var sc = 0.62;; sc -= 0.04) {
      final lay = _TableLay()..scale = sc;
      final w = g.tw * sc, h = g.th * sc, step = w + 1.2, gap = w * 0.6, rowH = h + 5;
      final rects = List<Rect>.filled(table.length, Rect.zero);
      var y = zone.top + h / 2 + 2;
      for (final o in order) {
        final ms = byOwner[o];
        if (ms == null) continue;
        lay.labels.add((o, Offset(zone.left, y)));
        var x = zone.left + labelW;
        for (final i in ms) {
          final tiles = [for (final t in (table[i]['tiles'] as List? ?? const [])) _int(t)];
          final mw = tiles.length * step;
          if (x + mw > zone.right && x > zone.left + labelW) {
            x = zone.left + labelW;
            y += rowH;
          }
          for (var j = 0; j < tiles.length; j++) {
            lay.pos[tiles[j]] = Offset(x + j * step + w / 2, y);
          }
          rects[i] = Rect.fromLTWH(x - 2, y - h / 2 - 2.5, mw + 2.8, h + 5);
          x += mw + gap;
        }
        y += rowH + 4;
      }
      lay.rects.addAll(rects);
      if (y - rowH <= zone.bottom || sc <= 0.36) return lay;
    }
  }

  Widget _openPill() {
    final seats = _seats;
    final me = seats.isNotEmpty ? seats[0] : const <String, dynamic>{};
    final opened = me['opened'] == true;
    final pairsOpener = me['open_kind'] == 'pairs';
    final sel = _selection();
    final need = _int(st['need'], 101), needP = _int(st['need_pairs'], 5);
    final active = _yourTurn && !_drawStage;
    String title, sub;
    bool ready;
    if (!opened) {
      if (sel.value < need && sel.prs.length >= needP) {
        title = 'ÇİFTLE AÇ';
        sub = '${sel.prs.length} / $needP çift';
        ready = true;
      } else {
        title = 'AÇ';
        sub = '${sel.value} / $need';
        ready = sel.value >= need;
      }
    } else {
      final n = pairsOpener ? sel.prs.length : sel.runs.length;
      title = 'İNDİR';
      sub = n == 0 ? 'per yok' : '$n ${pairsOpener ? 'çift' : 'per'}';
      ready = n > 0;
    }
    final hot = ready && active;
    return Semantics(
      button: true,
      label: '$title $sub',
      child: GestureDetector(
        onTap: _playing ? _openMelds : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: hot
                ? const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF8C6A22), Color(0xFF4A3410)])
                : null,
            color: hot ? null : const Color(0x8805241C),
            border: Border.all(color: hot ? Lux.goldLight : (ready ? Lux.gold : Lux.line), width: hot ? 1.4 : 1),
            boxShadow: hot ? [BoxShadow(color: Lux.gold.withValues(alpha: 0.35), blurRadius: 10)] : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(title,
                    style: Lux.ui(14, color: hot ? Lux.goldLight : (active ? Lux.ink : Lux.muted), weight: FontWeight.w700, spacing: 1.4)),
              ),
              const SizedBox(height: 1),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(sub, style: Lux.ui(12.5, color: ready ? Lux.gold : Lux.muted, weight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buttons101() {
    final seats = _seats;
    final me = seats.isNotEmpty ? _int(seats[0]['score']) : 0;
    final canPlay = st['phase'] == 'play' && !s.finished;
    final firstHand = canPlay && _int(st['hand_no']) == 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Lux.line),
              color: const Color(0x6605241C),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('Toplamın', style: Lux.ui(10.5, color: Lux.muted)),
              Text('$me', style: Lux.numeral(19, color: Lux.goldLight)),
            ]),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (firstHand) ...[
                  _SmallButton('${_int(st['max_hands'], 5)} el', onTap: _cycleHands),
                  const SizedBox(width: 6),
                ],
                if (st['can_untake'] == true)
                  _SmallButton('Geri ver', onTap: () => s.act({'untake': true}))
                else
                  _SmallButton('Çift diz', onTap: canPlay ? () => s.act({'auto_arrange': 'pairs'}) : null),
                const SizedBox(width: 6),
                _SmallButton('Açılabilir mi?',
                    onTap: canPlay
                        ? () {
                            setState(_excluded.clear);
                            s.actAsync({'suggest': true}).then((_) => _kick());
                          }
                        : null),
                const SizedBox(width: 8),
                RimIconButton(
                  Icons.lightbulb_outline_rounded,
                  tooltip: 'İpucu: en iyi hamle ve nedeni',
                  onPressed: _yourTurn && (st['hint'] is! Map || (st['hint'] as Map)['kind'] == 'suggest')
                      ? () {
                          s.actAsync({'hint': true}).then((_) => _kick());
                          _kick();
                        }
                      : null,
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultCard101(_Geo g) {
    final res = st['result'];
    if (res is! Map) return const SizedBox();
    final seats = _seats;
    final winner = res['winner'];
    final matchOver = st['match_over'] == true;
    final hist = [
      for (final h in (st['history'] as List? ?? const [])) [for (final p in h as List) _int(p)]
    ];
    final pens = [for (final p in (res['penalties'] as List? ?? const [0, 0, 0, 0])) _int(p)];
    final totals = [for (final x in seats) _int(x['score'])];
    final best = totals.isEmpty ? 0 : totals.reduce(math.min);
    final cell = Lux.ui(13, color: Lux.ink);
    Widget c(String t, {TextStyle? style, TextAlign align = TextAlign.right}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2.5, horizontal: 2),
          child: Text(t, textAlign: align, maxLines: 1, overflow: TextOverflow.fade, softWrap: false, style: style ?? cell),
        );
    final penNote = [
      for (var i = 0; i < pens.length && i < seats.length; i++)
        if (pens[i] > 0) '${seats[i]['name']} +${pens[i]}'
    ];
    return LuxCard(
      highlight: winner == 0,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(res['text'] as String? ?? '',
              textAlign: TextAlign.center,
              style: Lux.display(19, color: winner == 0 ? Lux.gold : (winner == null ? Lux.goldLight : Lux.ink))),
          const SizedBox(height: 10),
          Table(
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            columnWidths: {0: const FlexColumnWidth(2.2), for (var i = 1; i <= hist.length + 1; i++) i: const FlexColumnWidth(1)},
            children: [
              TableRow(children: [
                c('', align: TextAlign.left),
                for (var i = 0; i < hist.length; i++) c('${i + 1}. el', style: Lux.ui(11, color: Lux.muted)),
                c('Toplam', style: Lux.ui(11, color: Lux.muted)),
              ]),
              for (var p = 0; p < seats.length; p++)
                TableRow(children: [
                  c(seats[p]['name'] as String? ?? '',
                      align: TextAlign.left, style: Lux.ui(13.5, color: p == 0 ? Lux.goldLight : Lux.ink, weight: FontWeight.w600)),
                  for (var i = 0; i < hist.length; i++)
                    c(p < hist[i].length ? '${hist[i][p]}' : '',
                        style: Lux.ui(13,
                            color: i == hist.length - 1
                                ? (p < hist[i].length && hist[i][p] < 0 ? Lux.good : Lux.ink)
                                : Lux.muted,
                            weight: i == hist.length - 1 ? FontWeight.w600 : FontWeight.w500)),
                  c('${totals[p]}', style: Lux.numeral(17, color: totals[p] == best ? Lux.gold : Lux.ink)),
                ]),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            [
              if (penNote.isNotEmpty) 'Ceza: ${penNote.join(' · ')}',
              'Düşük puan kazanır · açmayan 202 yazar',
            ].join('  ·  '),
            textAlign: TextAlign.center,
            style: Lux.ui(11.5, color: Lux.muted),
          ),
          const SizedBox(height: 12),
          GoldButton(matchOver ? 'Maç sonucu' : 'Sonraki el', icon: Icons.arrow_forward_rounded, onPressed: () {
            HapticFeedback.selectionClick();
            s.act({'next': true});
          }),
        ],
      ),
    );
  }

  Widget _resultCard(_Geo g) {
    final res = st['result'];
    if (res is! Map) return const SizedBox();
    final seats = _seats;
    final deltas = [for (final d in (res['deltas'] as List? ?? const [0, 0, 0, 0])) _int(d)];
    final groups = [
      for (final gr in (res['groups'] as List? ?? const [])) [for (final t in gr as List) _int(t)]
    ];
    final winner = res['winner'];
    final matchOver = st['match_over'] == true;
    final tw = math.min(22.0, (g.size.width - 90) / 16);
    return LuxCard(
      highlight: winner == 0,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(res['text'] as String? ?? '',
              textAlign: TextAlign.center,
              style: Lux.display(19, color: winner == 0 ? Lux.gold : (winner == null ? Lux.goldLight : Lux.ink))),
          if (groups.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final gr in groups)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    for (final id in gr) Padding(padding: const EdgeInsets.all(0.6), child: OkeyTileView(id, okeyKind: _okey, width: tw)),
                  ]),
              ],
            ),
          ],
          const SizedBox(height: 12),
          for (var i = 0; i < seats.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1.5),
              child: Row(children: [
                SizedBox(width: 70, child: Text(seats[i]['name'] as String? ?? '', style: Lux.ui(14, color: i == 0 ? Lux.goldLight : Lux.ink))),
                const Spacer(),
                SizedBox(
                  width: 44,
                  child: Text(deltas[i] == 0 ? '' : '${deltas[i]}',
                      textAlign: TextAlign.right, style: Lux.ui(14, color: Lux.bordeauxLight, weight: FontWeight.w600)),
                ),
                SizedBox(
                  width: 44,
                  child: Text('${_int(seats[i]['score'])}', textAlign: TextAlign.right, style: Lux.numeral(18)),
                ),
              ]),
            ),
          const SizedBox(height: 12),
          GoldButton(matchOver ? 'Maç sonucu' : 'Sonraki el', icon: Icons.arrow_forward_rounded, onPressed: () {
            HapticFeedback.selectionClick();
            s.act({'next': true});
          }),
        ],
      ),
    );
  }
}

/// Tiny helper so views don't depend on the core's numbering.
class _Seats {
  static int left(int seat) => (seat + 3) % 4;
}

class _SmallButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  const _SmallButton(this.label, {this.onTap});

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onTap == null ? 0.4 : 1,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(30),
            onTap: onTap == null
                ? null
                : () {
                    HapticFeedback.selectionClick();
                    onTap!();
                  },
            child: Ink(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(30),
                color: const Color(0x33000000),
                border: Border.all(color: Lux.gold.withValues(alpha: 0.7)),
              ),
              child: Text(label, style: Lux.ui(14, color: Lux.goldLight, weight: FontWeight.w600)),
            ),
          ),
        ),
      );
}

class _EyeToggle extends StatelessWidget {
  final bool open;
  final VoidCallback onTap;
  const _EyeToggle({required this.open, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: open ? Lux.gold.withValues(alpha: 0.18) : const Color(0x6605241C),
            border: Border.all(color: open ? Lux.gold : Lux.line),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(open ? Icons.visibility_rounded : Icons.visibility_off_rounded, size: 17, color: open ? Lux.goldLight : Lux.muted),
            const SizedBox(width: 4),
            Text('Açık oyna', style: Lux.ui(11.5, color: open ? Lux.goldLight : Lux.muted, weight: FontWeight.w600)),
          ]),
        ),
      );
}

// =================================================================================================
// Painter

class _TablePainter extends CustomPainter {
  final _OkeyTableState v;
  final _Geo g;
  final double now;
  _TablePainter(this.v, this.g, this.now);

  Map<String, dynamic> get st => v.st;

  @override
  void paint(Canvas canvas, Size size) {
    final okey = v._okey;
    _felt(canvas);
    _spots(canvas);
    _pile(canvas, okey);
    if (v._is101) _tableMelds(canvas);
    _hiddenRacks(canvas);
    // Tiles by layer (rack tiles after the wood).
    final entries = v._targets.entries.toList()..sort((a, b) => a.value.z.compareTo(b.value.z));
    final drag = v._drag;
    for (final e in entries.where((e) => e.value.layer < 5)) {
      _tileAt(canvas, e.key, e.value, okey, drag);
    }
    _rackWood(canvas);
    _melds(canvas);
    for (final e in entries.where((e) => e.value.layer >= 5)) {
      _tileAt(canvas, e.key, e.value, okey, drag);
    }
    _ghosts(canvas, okey);
    if (drag != null) {
      final r = g.tile(drag.pos, 1.12);
      if (drag.id < 0) {
        OkeyArt.back(canvas, r, lift: 1);
      } else {
        OkeyArt.face(canvas, r, drag.id, okey, lift: 1);
      }
    }
  }

  void _felt(Canvas c) {
    final r = RRect.fromRectAndRadius(g.inner.deflate(2), const Radius.circular(22));
    c.drawRRect(
      r,
      Paint()
        ..shader = const RadialGradient(
          radius: 0.9,
          colors: [Color(0x3320805F), Color(0x1003190F)],
        ).createShader(r.outerRect),
    );
    c.drawRRect(
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Lux.lineFaint,
    );
  }

  void _spots(Canvas c) {
    final yourDiscard = v._yourTurn && !v._drawStage;
    final canTake = st['can_take'] == true;
    for (var seat = 0; seat < 4; seat++) {
      final r = RRect.fromRectAndRadius(g.tile(g.corner[seat], 1.08).inflate(5), const Radius.circular(8));
      var glow = 0.0;
      Color col = Lux.gold;
      if (seat == 0 && (yourDiscard || v._hoverZone == 'discard')) {
        glow = 0.45 + 0.35 * math.sin(now * 3.4);
        if (v._hoverZone == 'discard') {
          glow = 1;
          if (!yourDiscard) col = Lux.bordeaux;
        }
      }
      if (seat == 3 && canTake) glow = 0.35 + 0.3 * math.sin(now * 3.4);
      if (glow > 0) {
        c.drawRRect(r.inflate(2), Paint()..color = col.withValues(alpha: 0.35 * glow)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7));
      }
      c.drawRRect(r, Paint()..color = const Color(0x2A000000));
      c.drawRRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = glow > 0 ? 1.4 : 0.8
          ..color = (glow > 0 ? col : Lux.gold).withValues(alpha: glow > 0 ? 0.6 + 0.4 * glow : 0.28),
      );
      if (seat == 0) {
        final d = (v._seats.isNotEmpty ? (v._seats[0]['discards'] as List? ?? const []) : const []);
        if (d.isEmpty) _label(c, 'AT', g.corner[0], 11, Lux.gold.withValues(alpha: 0.6));
      }
    }
    // Finish zone while dragging a rack tile (classic; in 101 the last discard finishes).
    if (!v._is101 && (v._drag?.kind == 'rack' || (v._selected != null && v._yourTurn && !v._drawStage))) {
      final hot = v._hoverZone == 'finish';
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = hot ? 2 : 1.2
        ..color = Lux.gold.withValues(alpha: hot ? 0.95 : 0.45);
      c.drawCircle(g.center, g.finishR, Paint()..color = Lux.gold.withValues(alpha: hot ? 0.16 : 0.05));
      const n = 40;
      for (var i = 0; i < n; i += 2) {
        final a0 = i / n * 2 * math.pi + now * 0.4, a1 = (i + 1) / n * 2 * math.pi + now * 0.4;
        c.drawArc(Rect.fromCircle(center: g.center, radius: g.finishR), a0, a1 - a0, false, paint);
      }
      _label(c, 'BİTİR', g.center + Offset(0, -g.finishR + 12), 11, Lux.goldLight.withValues(alpha: hot ? 1 : 0.7));
    }
  }

  void _pile(Canvas c, int okey) {
    final n = (st['pile_count'] as num?)?.toInt() ?? 0;
    final canDraw = v._yourTurn && v._drawStage;
    if (n > 0) {
      final layers = math.min(4, (n + 11) ~/ 12);
      for (var i = 0; i < layers; i++) {
        final pulse = canDraw && i == layers - 1 ? 0.5 + 0.5 * math.sin(now * 3.4) : 0.0;
        if (pulse > 0) {
          c.drawRRect(
            RRect.fromRectAndRadius(g.tile(g.pile, 1.12).inflate(4), const Radius.circular(7)),
            Paint()
              ..color = Lux.gold.withValues(alpha: 0.35 * pulse)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
          );
        }
        if (v._drag?.kind == 'pile' && i == layers - 1) continue;
        OkeyArt.back(c, g.tile(g.pile + Offset(0, -2.2 * i), 1.12));
      }
    }
    final ly = g.pile.dy + g.th * 0.56 + 10;
    _label(c, 'DESTE $n', Offset(g.pile.dx, ly), 9.5, Lux.muted);
    _label(c, 'GÖSTERGE', Offset(g.gost.dx, ly), 9.5, Lux.muted);
    // Okey chip: which tile is wild this hand.
    if (okey >= 0) {
      OkeyArt.face(c, g.tile(g.chip, 0.9), okey, okey);
      _label(c, 'OKEY', Offset(g.chip.dx, ly), 9.5, Lux.gold);
    }
    if (v._showAll && st['phase'] == 'play') {
      _label(c, 'SIRADAKİ TAŞLAR', g.nextRow + Offset(0, g.th * 0.35 + 10), 9.5, Lux.muted);
    }
    if (!v._is101) _log(c);
  }

  void _hiddenRacks(Canvas c) {
    if (v._showAll) return;
    final seats = v._seats;
    if (seats.length < 4) return;
    for (var seat = 1; seat < 4; seat++) {
      final n = (seats[seat]['count'] as num?)?.toInt() ?? 0;
      final s = seat == 2 ? g.k * 0.92 : g.k * 1.05;
      final w = g.tw * s, h = g.th * s;
      if (seat == 2) {
        final step = w * 0.62;
        final x0 = g.size.width / 2 - (n - 1) * step / 2;
        for (var i = 0; i < n; i++) {
          OkeyArt.back(c, Rect.fromCenter(center: Offset(x0 + i * step, g.anchor[2].dy), width: w, height: h));
        }
      } else {
        final step = h * 0.42;
        final top = g.sideTop;
        final cx = g.anchor[seat].dx;
        for (var i = 0; i < n; i++) {
          OkeyArt.back(c, Rect.fromCenter(center: Offset(cx, top + i * step + h / 2), width: w, height: h));
        }
      }
    }
  }

  void _tileAt(Canvas c, int id, _T t, int okey, _Drag? drag) {
    if (drag != null && drag.id == id && drag.kind != 'pile') return;
    var p = v._vis[id] ?? t.c;
    final sc = v._visS[id] ?? t.s;
    final slotSel = v._selected;
    final lay = v._layout;
    var lift = 0.0;
    var glow = 0.0;
    Color? glowColor;
    if (t.layer >= 5 && slotSel != null && slotSel < lay.length && lay[slotSel] == id) {
      p = p.translate(0, -g.th * 0.18);
      lift = 0.6;
      glow = 0.8;
    }
    final hint = st['hint'];
    if (hint is Map && v._yourTurn && (hint['tile'] as num?)?.toInt() == id) {
      glow = 0.55 + 0.45 * math.sin(now * 4);
      glowColor = Lux.goldLight;
    }
    if (v._shakeId == id && now - v._shakeAt < 0.45) {
      p = p.translate(math.sin((now - v._shakeAt) * 50) * 4 * (1 - (now - v._shakeAt) / 0.45), 0);
      glow = 0.8;
      glowColor = Lux.bordeaux;
    }
    if (v._is101 && t.layer >= 5 && v._mustUse == id && glow == 0) {
      glow = 0.6 + 0.4 * math.sin(now * 4);
      glowColor = Lux.goldLight;
    }
    final far = (p - t.c).distance;
    if (far > 6) lift = math.max(lift, math.min(1, far / 120));
    final r = g.tile(p, sc * (1 + 0.08 * lift));
    OkeyArt.face(c, r, id, okey, lift: lift, glow: glow, glowColor: glowColor);
    // 101 rack marks: gold = can be işlendi now, bordeaux = discarding it costs 101 (okeys have a star).
    final wild = !OkeyArt.isFalse(id) && OkeyArt.kindOf(id) == okey;
    if (v._is101 && t.layer >= 5 && v._yourTurn && !v._drawStage && !wild) {
      final add = v._addable.containsKey(id);
      final pen = v._penaltyTiles.contains(id);
      if (add || pen) {
        final dot = Offset(r.left + r.width * 0.2, r.top + r.width * 0.2);
        c.drawCircle(dot, r.width * 0.11, Paint()..color = add ? const Color(0xFFC08A1E) : Lux.bordeaux);
        c.drawCircle(dot, r.width * 0.05, Paint()..color = OkeyArt.ivory);
      }
    }
  }

  void _rackWood(Canvas c) {
    final r = RRect.fromRectAndRadius(g.rack, const Radius.circular(10));
    c.drawRRect(r.shift(const Offset(0, 4)), Paint()..color = Colors.black.withValues(alpha: 0.5)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
    c.drawRRect(
      r,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF4A2B17), Color(0xFF2E1A0D), Color(0xFF3B2312)],
        ).createShader(g.rack),
    );
    // Wood grain.
    c.save();
    c.clipRRect(r);
    final grain = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var i = 0; i < 16; i++) {
      final y = g.rack.top + 4 + i * g.rack.height / 16;
      final path = Path()..moveTo(g.rack.left, y);
      for (var x = g.rack.left; x <= g.rack.right; x += 12) {
        path.lineTo(x, y + math.sin(x / 37 + i * 1.7) * 2.2 + math.sin(x / 11 + i) * 0.6);
      }
      grain.color = (i.isEven ? const Color(0xFF6B4324) : const Color(0xFF1E1008)).withValues(alpha: 0.28);
      c.drawPath(path, grain);
    }
    // Two ledges the tiles stand on.
    for (final y in [g.y0, g.y1]) {
      final ledge = Rect.fromLTWH(g.rack.left + 3, y + g.th / 2 + 1, g.rack.width - 6, 7);
      c.drawRRect(
        RRect.fromRectAndRadius(ledge, const Radius.circular(3)),
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF7A4E2A), Color(0xFF3A2010)],
          ).createShader(ledge),
      );
      c.drawLine(ledge.topLeft, ledge.topRight, Paint()..color = Lux.gold.withValues(alpha: 0.55)..strokeWidth = 0.8);
    }
    c.restore();
    c.drawRRect(
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..shader = Lux.foil.createShader(g.rack),
    );
    // Hover slot.
    final hs = v._hoverSlot;
    if (hs != null && v._drag != null) {
      final lay = v._layout;
      final occupied = hs < lay.length && lay[hs] >= 0 && lay[hs] != v._drag!.id;
      c.drawRRect(
        RRect.fromRectAndRadius(g.tile(g.slot(hs)).inflate(2), const Radius.circular(6)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = (occupied ? Lux.goldLight : Lux.gold).withValues(alpha: 0.9),
      );
    }
  }

  void _melds(Canvas c) {
    final melds = st['melds'] as List? ?? const [];
    final lay = v._layout;
    for (final m in melds) {
      final slots = [for (final x in (m as Map)['slots'] as List) (x as num).toInt()];
      if (slots.isEmpty) continue;
      final pair = m['kind'] == 'pair';
      final a = g.slot(slots.first), b = g.slot(slots.last);
      final y = a.dy + g.th / 2 + 4.5;
      final out = v._is101 && slots.any((sl) => sl < lay.length && v._excluded.contains(lay[sl]));
      if (out) {
        c.drawLine(Offset(a.dx - g.tw * 0.42, y), Offset(b.dx + g.tw * 0.42, y),
            Paint()..color = Lux.muted.withValues(alpha: 0.45)..strokeWidth = 1.2);
      } else {
        final p = Paint()
          ..strokeWidth = pair ? 1.6 : 2.4
          ..strokeCap = StrokeCap.round
          ..shader = Lux.foil.createShader(Rect.fromLTRB(a.dx - g.tw / 2, y - 2, b.dx + g.tw / 2, y + 2));
        c.drawLine(Offset(a.dx - g.tw * 0.42, y), Offset(b.dx + g.tw * 0.42, y), p);
        c.drawLine(Offset(a.dx - g.tw * 0.42, y), Offset(b.dx + g.tw * 0.42, y),
            Paint()..color = Lux.goldLight.withValues(alpha: 0.25)..strokeWidth = 5..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
      }
      // 101: each meld's points on the ledge (tap it to leave the meld out of "Aç").
      if (v._is101 && !pair) {
        final value = (m['value'] as num?)?.toInt() ?? 0;
        final mid = Offset((a.dx + b.dx) / 2, y);
        final tp = TextPainter(
          text: TextSpan(
              text: out ? 'dışarıda' : '$value',
              style: Lux.ui(9, color: out ? Lux.muted : const Color(0xFF2A1A08), weight: FontWeight.w700)),
          textDirection: TextDirection.ltr,
        )..layout();
        final r = RRect.fromRectAndRadius(
            Rect.fromCenter(center: mid, width: tp.width + 8, height: tp.height + 1), const Radius.circular(6));
        c.drawRRect(r, Paint()..color = out ? const Color(0xCC1E1008) : Lux.goldLight);
        tp.paint(c, mid - Offset(tp.width / 2, tp.height / 2));
      }
    }
  }

  /// 101: the opened melds (their tiles are drawn with the other tiles), owner labels and the
  /// işleme targets of the tile being dragged or selected.
  void _tableMelds(Canvas c) {
    final tbl = v._tbl;
    final seats = v._seats;
    final zone = g.meldZone;
    if (tbl.rects.isEmpty) {
      _label(c, 'Masa boş: ilk açan 101 puanla açar', zone.center, 10.5, Lux.muted.withValues(alpha: 0.7));
      return;
    }
    for (final (seat, at) in tbl.labels) {
      if (seat >= seats.length) continue;
      final x = seats[seat];
      final name = x['name'] as String? ?? '';
      final sub = x['open_kind'] == 'pairs' ? 'çift' : '${(x['open_value'] as num?)?.toInt() ?? 0}';
      final tp = TextPainter(
        text: TextSpan(children: [
          TextSpan(text: '$name\n', style: Lux.ui(10, color: seat == 0 ? Lux.goldLight : Lux.ink, weight: FontWeight.w600)),
          TextSpan(text: sub, style: Lux.ui(9, color: Lux.muted)),
        ]),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 40);
      tp.paint(c, Offset(at.dx, at.dy - tp.height / 2));
    }
    int? tile;
    final d = v._drag;
    if (d != null && d.kind == 'rack') {
      tile = d.id;
    } else if (v._selected != null && v._selected! < v._layout.length) {
      final id = v._layout[v._selected!];
      if (id >= 0) tile = id;
    }
    final targets = tile == null ? const <int>[] : (v._addable[tile] ?? const <int>[]);
    for (var i = 0; i < tbl.rects.length; i++) {
      final r = tbl.rects[i];
      if (r == Rect.zero) continue;
      final rr = RRect.fromRectAndRadius(r, const Radius.circular(5));
      final hot = v._hoverMeld == i;
      final target = targets.contains(i);
      c.drawRRect(rr, Paint()..color = const Color(0x26000000));
      if (target || hot) {
        final a = hot ? 1.0 : 0.55 + 0.25 * math.sin(now * 3.4);
        c.drawRRect(rr.inflate(1.5),
            Paint()..color = Lux.gold.withValues(alpha: 0.35 * a)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
        c.drawRRect(
            rr,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = hot ? 1.6 : 1.1
              ..color = Lux.goldLight.withValues(alpha: 0.6 + 0.4 * a));
        if (hot) {
          // The end the tile goes to.
          final x = v._hoverLow ? r.left - 3 : r.right + 3;
          c.drawLine(Offset(x, r.top + 2), Offset(x, r.bottom - 2),
              Paint()..color = Lux.goldLight..strokeWidth = 2..strokeCap = StrokeCap.round);
        }
      } else {
        c.drawRRect(rr, Paint()..style = PaintingStyle.stroke..strokeWidth = 0.7..color = Lux.lineFaint);
      }
    }
  }

  void _ghosts(Canvas c, int okey) {
    for (final gh in v._ghosts) {
      final t = ((now - gh.t0) / gh.dur).clamp(0.0, 1.0);
      final e = Curves.easeInOutCubic.transform(t);
      final to = g.anchor[gh.seat];
      final mid = Offset.lerp(gh.from, to, 0.5)! + const Offset(0, -26);
      final u = 1 - e;
      final p = gh.from * (u * u) + mid * (2 * u * e) + to * (e * e);
      final sc = 1.0 - 0.4 * e;
      final r = g.tile(p, sc);
      final a = t > 0.85 ? (1 - (t - 0.85) / 0.15) : 1.0;
      c.saveLayer(r.inflate(12), Paint()..color = Colors.white.withValues(alpha: a));
      if (gh.face) {
        OkeyArt.face(c, r, gh.id, okey, lift: 0.6);
      } else {
        OkeyArt.back(c, r, lift: 0.6);
      }
      c.restore();
    }
  }

  /// The last few actions, faint, under the centre (reading the table).
  void _log(Canvas c) {
    final log = st['log'] as List? ?? const [];
    var y = g.nextRow.dy + g.th * 0.35 + 30;
    final maxY = g.inner.bottom - g.th * 1.4;
    for (var i = 0; i < log.length && i < 5 && y < maxY; i++) {
      final e = log[i] as Map;
      final text = e['text'] as String? ?? '';
      if (text.isEmpty) continue;
      _label(c, text, Offset(g.center.dx, y), 11, Lux.muted.withValues(alpha: 0.85 - i * 0.15));
      y += 17;
    }
  }

  void _label(Canvas c, String text, Offset at, double size, Color color) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: Lux.ui(size, color: color, weight: FontWeight.w600, spacing: 1.0)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, at - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
