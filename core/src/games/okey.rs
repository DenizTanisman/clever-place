//! Okey — standard Turkish four-player tile rummy: the owner (seat 0) against three AI rivals.
//!
//! The `okey` game also hosts **101 Okey**: modes `101_easy | 101_normal | 101_hard |
//! 101_impossible` are created by [`super::okey101`] (which reuses the tile helpers below); the
//! modes `easy | normal | hard | impossible` are the classic game described here.
//!
//! ## Tiles
//! 106 tiles: ids `0..104` are the numbered tiles, two copies of 4 colours × 1–13
//! (`id % 52` = kind, `kind / 13` = colour 0 kırmızı · 1 siyah · 2 mavi · 3 sarı, `kind % 13 + 1` =
//! number, `id / 52` = copy); ids `104`, `105` are the two **false jokers** (sahte okey).
//! After the shuffle one numbered tile is turned up as the **gösterge** (indicator). The **okey**
//! (wild tile) is the next number of the same colour (13 → 1); both okey tiles are wild and may
//! stand for any tile. The false jokers are not wild: they play as the okey's face value.
//!
//! ## Deal & turn
//! The starter gets 15 tiles and opens by discarding; everyone else gets 14; 48 tiles stay in the
//! centre pile. Seats play counter-clockwise: 0 you (bottom) → 1 right → 2 across → 3 left → 0.
//! On your turn you draw — the next pile tile, or the tile the previous player (on your left) just
//! discarded — and then discard one tile to your right (onto your own discard stack, which your
//! right-hand neighbour may take). The starter rotates every hand.
//!
//! ## Winning a hand
//! You finish by discarding your 15th tile (onto the centre) when the remaining **14** tiles form:
//! - melds only: **runs** (same colour, consecutive numbers, ≥ 3; 1 may follow 13 — `12-13-1` is a
//!   run — but nothing follows that 1: `13-1-2` is not) and **sets** (same number, different
//!   colours, 3 or 4 tiles); or
//! - **7 pairs** (çift): seven pairs of identical tiles.
//!
//! An okey substitutes any tile everywhere (a run gap, a missing colour, the second tile of a pair).
//!
//! ## Scoring (documented convention)
//! Everyone starts at **20**. When a player finishes, every other player loses **2** points; ×2 if
//! the hand was finished with **pairs**, ×2 if the finishing discard was an **okey** (so 2 / 4 / 8).
//! **Gösterge**: whoever holds the indicator's twin shows it automatically at the deal — the other
//! three lose 1 point. When the centre pile is empty after a discard, the hand is a **draw** (no
//! points change). A **match** is 5 hands, or ends earlier as soon as someone's score is ≤ 0. You win
//! the match with the strictly highest score, draw when tied for the highest, otherwise you lose.
//!
//! ## AI (tables)
//! The deficiency (`eksik`) of a 14-tile hand is the minimum number of tiles that must be replaced
//! to reach a winning hand: `14 − max kept tiles`, where kept tiles sit in disjoint (possibly
//! incomplete) runs/sets whose finished sizes sum to ≤ 14, okeys count as kept, and the pair route
//! is computed separately. An exact memoised search ([`Solver`]) computes it.
//! - **easy (Kolay)**: greedy deficiency only; misses a useful discard 30 % of the time and slips
//!   (second-best discard) 18 % of the time.
//! - **normal (Orta)**: deficiency + acceptance (how many unseen tiles would improve the hand,
//!   counted from everything visible) + it reads its right-hand neighbour: tiles that neighbour
//!   took or passed shape a danger score, and it won't feed the tiles they collect.
//! - **hard (Zor)**: deficiency that knows dead tiles (all copies visible, so a gap waiting on
//!   them is worthless) + acceptance weighted by the remaining tile counts + a second-step lookahead
//!   (average acceptance after each improving draw) + defensive discards weighted by how "hot" the
//!   neighbour is (tiles taken from us) and how late the hand is; when its own estimated turns to
//!   finish exceed the remaining pile, safety weighs double.
//! - **impossible (İmkânsız)**: omniscient — sees every rack and the pile order. It plans the
//!   fastest finish over its next known draws (lookahead up to 12 own draws, assuming the others
//!   draw from the pile; binary search on "the pool can win" + a discard-order feasibility check),
//!   ranks no-finish candidates by the deficiency of hand + all known draws, never discards a tile
//!   that lets its right-hand neighbour improve or finish, and — as the player right before that
//!   neighbour — chooses pile vs. discard so the neighbour's next pile tile is the less useful one.
//!   Omniscient seats only block non-omniscient neighbours (in play: you), not each other.
//!
//! Measured (`strength_table`, single hands, 200 per pairing, seats 0+2 vs 1+3): easy–normal
//! 39:143, easy–hard 28:154, normal–hard 106:93, easy–impossible 1:139, hard–impossible 8:133.
//! A hard-level player alone against three impossible seats wins ≈ 3 % of hands.
//!
//! Information-set separation: easy/normal/hard decide through [`Info`], which is built from public
//! data plus the deciding seat's own rack only; only the impossible planner receives the [`Hand`].
//! Every AI action carries a concrete Turkish `reason`.
//!
//! ## State
//! `{status, stars: 0, title, goal, summary, mode, seed, hand_no, max_hands, phase: "play" |
//!   "hand_end", turn: "you"|"ai", seat, stage: "draw"|"discard", ai_pending, starter,
//!   seats: [{name, where, score, count, tiles, discards, reason}], layout: [28 × id | -1],
//!   melds: [{slots, kind}], indicator, okey: {kind, color, number}, pile_count, pile (next first),
//!   can_take, take_tile, last: {serial, seat, kind, tile, from, reason, text} | null, log,
//!   hint: {kind, tile, text} | null, result: {...} | null, match_over, version}`
//!
//! Actions: `{"draw":"pile"|"discard", "slot"?: k}` · `{"discard":id}` · `{"finish":id}` ·
//! `{"arrange":[28 × id|-1]}` · `{"auto_arrange":"runs"|"pairs"}` · `{"ai":true}` (one AI step:
//! a draw or a discard) · `{"hint":true}` · `{"next":true}` (after a hand: deal the next / end).

use std::collections::HashMap;
use std::hash::{BuildHasherDefault, Hasher};

use crate::rng::{time_seed, Rng};
use crate::Session;
use serde_json::{json, Value};

pub const N_TILES: u8 = 106;
pub const ROW: usize = 14;
pub const SLOTS: usize = 2 * ROW;
pub const START_SCORE: i32 = 20;
pub const MAX_HANDS: u32 = 5;
const BUDGET: u8 = 14;
const LOOKAHEAD: usize = 12;

pub const NAMES: [&str; 4] = ["Sen", "Selim", "Ayla", "Murat"];
pub(crate) const WHERE: [&str; 4] = ["you", "right", "top", "left"];
pub(crate) const COLS: [&str; 4] = ["kırmızı", "siyah", "mavi", "sarı"];
/// Turkish accusative suffix after the spoken number 1..13.
/// Plural suffix after the spoken number 1..13 ("7'ler", "9'lar").
pub(crate) const PL: [&str; 13] = ["ler", "ler", "ler", "ler", "ler", "lar", "ler", "ler", "lar", "lar", "ler", "ler", "ler"];
/// Genitive of each seat ("Ayla'nın").
pub(crate) const GEN: [&str; 4] = ["senin", "Selim'in", "Ayla'nın", "Murat'ın"];
pub(crate) const ACC: [&str; 13] = ["'i", "'yi", "'ü", "'ü", "'i", "'yı", "'yi", "'i", "'u", "'u", "'i", "'yi", "'ü"];

#[derive(Clone, Copy, PartialEq, Eq, Debug, PartialOrd, Ord)]
pub enum Level {
    Easy,
    Normal,
    Hard,
    Impossible,
}

impl Level {
    pub(crate) fn label(self) -> &'static str {
        match self {
            Level::Easy => "Kolay",
            Level::Normal => "Orta",
            Level::Hard => "Zor",
            Level::Impossible => "İmkânsız",
        }
    }
    pub(crate) fn id(self) -> &'static str {
        match self {
            Level::Easy => "easy",
            Level::Normal => "normal",
            Level::Hard => "hard",
            Level::Impossible => "impossible",
        }
    }
}

// =================================================================================================
// Tiles

pub fn is_false(id: u8) -> bool {
    id >= 104
}

/// Okey kind from the indicator tile: same colour, next number (13 → 1).
pub fn okey_of(indicator: u8) -> u8 {
    let k = indicator % 52;
    k / 13 * 13 + (k % 13 + 1) % 13
}

/// Effective kind of a tile in play: `None` = wild okey; false jokers play as the okey kind.
pub fn eff(id: u8, okey: u8) -> Option<u8> {
    if is_false(id) {
        Some(okey)
    } else if id % 52 == okey {
        None
    } else {
        Some(id % 52)
    }
}

pub(crate) fn kname(k: u8) -> String {
    format!("{} {}", COLS[(k / 13) as usize], k % 13 + 1)
}

pub(crate) fn kacc(k: u8) -> String {
    format!("{}{}", kname(k), ACC[(k % 13) as usize])
}

pub(crate) fn tname(id: u8, okey: u8) -> String {
    if is_false(id) {
        "sahte okey".into()
    } else if id % 52 == okey {
        "okey".into()
    } else {
        kname(id % 52)
    }
}

pub(crate) fn tacc(id: u8, okey: u8) -> String {
    if is_false(id) {
        "sahte okeyi".into()
    } else if id % 52 == okey {
        "okeyi".into()
    } else {
        kacc(id % 52)
    }
}

pub(crate) fn cap(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

/// Counts by effective kind plus wild okeys.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Hc {
    pub c: [u8; 52],
    pub j: u8,
}

impl Hc {
    pub fn of(ids: &[u8], okey: u8) -> Hc {
        let mut h = Hc { c: [0; 52], j: 0 };
        for &id in ids {
            h.add(eff(id, okey));
        }
        h
    }
    fn add(&mut self, e: Option<u8>) {
        match e {
            Some(k) => self.c[k as usize] += 1,
            None => self.j += 1,
        }
    }
    fn remove(&mut self, e: Option<u8>) {
        match e {
            Some(k) => self.c[k as usize] -= 1,
            None => self.j -= 1,
        }
    }
    fn with(&self, e: Option<u8>) -> Hc {
        let mut h = *self;
        h.add(e);
        h
    }
}

// =================================================================================================
// Exact winning-hand check (used to validate a finish)

/// All tiles of `c` + `j` wild okeys partition into runs and sets.
fn melds_exact(c: [u8; 52], j: u8) -> bool {
    let Some(k) = (0..52).find(|&k| c[k] > 0) else {
        return j == 0;
    };
    let col = k / 13;
    let n = k % 13;
    // Sets: this tile + real tiles of the same number in higher colours (lower colours are empty),
    // okeys fill the missing colours.
    let higher: Vec<usize> = (col + 1..4).filter(|&c2| c[c2 * 13 + n] > 0).collect();
    for m in 0..(1u32 << higher.len()) {
        let real = 1 + m.count_ones() as u8;
        let mut cc = c;
        cc[k] -= 1;
        for (i, &c2) in higher.iter().enumerate() {
            if m >> i & 1 == 1 {
                cc[c2 * 13 + n] -= 1;
            }
        }
        for size in real.max(3)..=4 {
            let jk = size - real;
            if jk <= j && melds_exact(cc, j - jk) {
                return true;
            }
        }
    }
    // Runs in which this is the lowest real tile.
    let mut cc = c;
    cc[k] -= 1;
    if n == 0 {
        // 1-2-3…
        if run_extend(cc, j, col, 1, 1, 12) {
            return true;
        }
        // …-12-13-1: this 1 closes a run starting at s.
        for s in 1..=11 {
            if run_fill(cc, j, col, s, 12) {
                return true;
            }
        }
    } else {
        for pre in 0..=(j as usize).min(n) {
            if run_extend(cc, j - pre as u8, col, n + 1, 1 + pre, 13) {
                return true;
            }
        }
    }
    false
}

/// Continue a run of colour `col` at position `pos` (13 = the 1 after 13, only as a wild here).
fn run_extend(c: [u8; 52], j: u8, col: usize, pos: usize, len: usize, maxpos: usize) -> bool {
    if len >= 3 && melds_exact(c, j) {
        return true;
    }
    if pos > maxpos {
        return false;
    }
    if pos <= 12 && c[col * 13 + pos] > 0 {
        let mut cc = c;
        cc[col * 13 + pos] -= 1;
        if run_extend(cc, j, col, pos + 1, len + 1, maxpos) {
            return true;
        }
    }
    j > 0 && run_extend(c, j - 1, col, pos + 1, len + 1, maxpos)
}

/// Fill every position `pos..=end` of colour `col` (real tile or okey), then solve the rest.
fn run_fill(c: [u8; 52], j: u8, col: usize, pos: usize, end: usize) -> bool {
    if pos > end {
        return melds_exact(c, j);
    }
    if c[col * 13 + pos] > 0 {
        let mut cc = c;
        cc[col * 13 + pos] -= 1;
        if run_fill(cc, j, col, pos + 1, end) {
            return true;
        }
    }
    j > 0 && run_fill(c, j - 1, col, pos + 1, end)
}

fn pairs_exact(h: &Hc) -> bool {
    let singles: u8 = h.c.iter().map(|&x| x % 2).sum();
    let total: u8 = h.c.iter().sum::<u8>() + h.j;
    total == 14 && singles <= h.j
}

/// `Some(pairs)` when these 14 tiles win (pairs preferred: it scores double).
pub fn winning(ids: &[u8], okey: u8) -> Option<bool> {
    if ids.len() != 14 {
        return None;
    }
    let h = Hc::of(ids, okey);
    if pairs_exact(&h) {
        return Some(true);
    }
    if melds_exact(h.c, h.j) {
        return Some(false);
    }
    None
}

// =================================================================================================
// Deficiency solver

#[derive(Default, Clone, Copy)]
pub(crate) struct Fx(u64);
impl Hasher for Fx {
    fn finish(&self) -> u64 {
        self.0
    }
    fn write(&mut self, bytes: &[u8]) {
        for &b in bytes {
            self.0 = (self.0 ^ b as u64).wrapping_mul(0x100_0000_01b3);
        }
    }
    fn write_u128(&mut self, v: u128) {
        let lo = v as u64;
        let hi = (v >> 64) as u64;
        let h = lo.wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ hi.wrapping_mul(0xC2B2_AE3D_27D4_EB4F).rotate_left(31);
        self.0 = h ^ (h >> 29);
    }
}
pub(crate) type FxMap<K, V> = HashMap<K, V, BuildHasherDefault<Fx>>;

/// A (possibly incomplete) meld picked by the solver. Positions: 0..=12 = numbers 1..13 and 13 =
/// the 1 that follows 13.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Grp {
    Drop,
    Defer,
    /// Same number (position `pos`), colour bitmask `cols`. A single colour = a lone tile.
    Set { pos: u8, cols: u8 },
    /// Same colour, starting at position `start`; `mask` bit q = position q present.
    Run { col: u8, start: u8, mask: u16 },
}

impl Grp {
    fn kinds(&self) -> Vec<u8> {
        match *self {
            Grp::Set { pos, cols } => (0..4u8).filter(|c| cols >> c & 1 == 1).map(|c| c * 13 + pos % 13).collect(),
            Grp::Run { col, mask, .. } => (0..14u8).filter(|q| mask >> q & 1 == 1).map(|q| col * 13 + q % 13).collect(),
            _ => vec![],
        }
    }
    fn size(&self) -> u8 {
        match *self {
            Grp::Set { cols, .. } => cols.count_ones() as u8,
            Grp::Run { mask, .. } => mask.count_ones() as u8,
            _ => 0,
        }
    }
    /// Finished size of this meld.
    fn target(&self) -> u8 {
        match *self {
            Grp::Set { cols, .. } => (cols.count_ones() as u8).max(3),
            Grp::Run { start, mask, .. } => (16 - mask.leading_zeros() as u8 - start).max(3),
            _ => 0,
        }
    }
}

#[derive(Clone, Copy)]
struct Opt {
    next: u128,
    nb: u8,
    gain: i8,
    g: Grp,
}

fn one(s: usize) -> u128 {
    1u128 << (2 * s)
}
fn cnt(key: u128, s: usize) -> u8 {
    ((key >> (2 * s)) & 3) as u8
}
fn pos_kind(col: usize, q: usize) -> usize {
    col * 13 + q % 13
}
fn key_of(c: &[u8; 52]) -> u128 {
    let mut k = 0u128;
    for kind in 0..52 {
        k |= (c[kind].min(3) as u128) << (2 * (kind / 13 * 14 + kind % 13));
    }
    k
}

/// Exact maximum-kept-tiles search (memoised over remaining tiles × remaining slot budget).
/// Slots: colour × 14 positions (position 13 holds a 1 that was "deferred" to follow a 13).
pub struct Solver {
    /// `memo[0]`: plain search; `memo[1]`: dead-aware search for the current `dead` table. A value
    /// depends only on (remaining tiles, budget, dead table), so memos persist across calls.
    memo: [FxMap<u128, i8>; 2],
    bufs: Vec<Vec<Opt>>,
    dead: [bool; 52],
    use_dead: bool,
    pub calls: u64,
}

impl Default for Solver {
    fn default() -> Self {
        Self::new()
    }
}

impl Solver {
    pub fn new() -> Self {
        Solver {
            memo: [FxMap::with_capacity_and_hasher(1 << 14, Default::default()), FxMap::with_capacity_and_hasher(1 << 14, Default::default())],
            bufs: (0..48).map(|_| Vec::with_capacity(48)).collect(),
            dead: [false; 52],
            use_dead: false,
            calls: 0,
        }
    }

    /// Dead kinds (no copy left anywhere obtainable): incomplete melds may not wait on them.
    fn set_dead(&mut self, dead: Option<&[bool; 52]>) {
        match dead {
            Some(d) => {
                if self.dead != *d {
                    self.dead = *d;
                    self.memo[1].clear();
                }
                self.use_dead = true;
            }
            None => self.use_dead = false,
        }
    }

    fn alive(&self, kind: usize) -> bool {
        !self.use_dead || !self.dead[kind]
    }

    fn options(&self, key: u128, b: u8, out: &mut Vec<Opt>) {
        let s = (key.trailing_zeros() / 2) as usize;
        let col = s / 14;
        let p = s % 14;
        let rest = key - one(s);
        out.push(Opt { next: rest, nb: b, gain: 0, g: Grp::Drop });
        if p == 13 {
            // A deferred 1 whose 12/13 are gone: only a lone tile.
            out.push(Opt { next: rest, nb: b - 3, gain: 1, g: Grp::Set { pos: 13, cols: 1 << col } });
            return;
        }
        if p == 0 && (cnt(key, col * 14 + 11) > 0 || cnt(key, col * 14 + 12) > 0) {
            out.push(Opt { next: rest + one(col * 14 + 13), nb: b, gain: 0, g: Grp::Defer });
        }
        // Sets (and the lone tile).
        let mut avail = [0usize; 3];
        let mut na = 0;
        for c2 in col + 1..4 {
            if cnt(key, c2 * 14 + p) > 0 {
                avail[na] = c2;
                na += 1;
            }
        }
        for m in 0..(1u32 << na) {
            let k = 1 + m.count_ones() as u8;
            let t = k.max(3);
            if t > b {
                continue;
            }
            let mut cols = 1u8 << col;
            let mut next = rest;
            for (i, &c2) in avail.iter().enumerate().take(na) {
                if m >> i & 1 == 1 {
                    cols |= 1 << c2;
                    next -= one(c2 * 14 + p);
                }
            }
            if self.use_dead && k > 1 && k < 3 {
                let alive = (0..4).filter(|&c| cols >> c & 1 == 0 && self.alive(c * 13 + p)).count() as u8;
                if alive < 3 - k {
                    continue;
                }
            }
            out.push(Opt { next, nb: b - t, gain: k as i8, g: Grp::Set { pos: p as u8, cols } });
        }
        // Runs with at least two tiles, at most two missing positions inside.
        let mut list = [0usize; 13];
        let mut nl = 0;
        for q in p + 1..14 {
            if cnt(key, col * 14 + q) > 0 {
                list[nl] = q;
                nl += 1;
            }
        }
        self.runs(col, p, &list[..nl], 0, rest, 1, p, 1u16 << p, 0, b, out);
    }

    #[allow(clippy::too_many_arguments)]
    fn runs(
        &self,
        col: usize,
        p: usize,
        list: &[usize],
        i: usize,
        next: u128,
        k: u8,
        last: usize,
        mask: u16,
        missing: usize,
        b: u8,
        out: &mut Vec<Opt>,
    ) {
        for (idx, &q) in list.iter().enumerate().skip(i) {
            let miss = missing + (q - last - 1);
            if miss > 2 || q - p + 1 > b as usize {
                break;
            }
            if (last + 1..q).any(|r| !self.alive(pos_kind(col, r))) {
                break;
            }
            let nk = k + 1;
            let nm = mask | 1 << q;
            let nn = next - one(col * 14 + q);
            let span = q - p + 1;
            let t = span.max(3) as u8;
            let ext_ok = span >= 3
                || !self.use_dead
                || (q < 13 && self.alive(pos_kind(col, q + 1)))
                || (p > 0 && self.alive(pos_kind(col, p - 1)));
            if t <= b && ext_ok {
                out.push(Opt { next: nn, nb: b - t, gain: nk as i8, g: Grp::Run { col: col as u8, start: p as u8, mask: nm } });
            }
            self.runs(col, p, list, idx + 1, nn, nk, q, nm, miss, b, out);
        }
    }

    fn f(&mut self, key: u128, b: u8, depth: usize) -> i8 {
        if key == 0 || b < 3 {
            return 0;
        }
        let mk = key | (b as u128) << 112;
        let mi = self.use_dead as usize;
        if let Some(&v) = self.memo[mi].get(&mk) {
            return v;
        }
        self.calls += 1;
        if depth >= self.bufs.len() {
            self.bufs.push(Vec::with_capacity(48));
        }
        let mut buf = std::mem::take(&mut self.bufs[depth]);
        buf.clear();
        self.options(key, b, &mut buf);
        let mut best = 0i8;
        for o in buf.iter() {
            let v = o.gain + self.f(o.next, o.nb, depth + 1);
            if v > best {
                best = v;
            }
        }
        self.bufs[depth] = buf;
        if self.memo[mi].len() > 400_000 {
            self.memo[mi].clear();
        }
        self.memo[mi].insert(mk, best);
        best
    }

    /// Max tiles of `c` that sit in disjoint melds whose finished sizes sum to ≤ 14.
    pub fn kept(&mut self, c: &[u8; 52]) -> u8 {
        self.f(key_of(c), BUDGET, 0).max(0) as u8
    }

    /// The groups of one optimal solution.
    pub fn groups(&mut self, c: &[u8; 52]) -> (u8, Vec<Grp>) {
        let mut key = key_of(c);
        let mut b = BUDGET;
        let total = self.f(key, b, 0).max(0) as u8;
        let mut out = Vec::new();
        let mut buf = Vec::new();
        while key != 0 && b >= 3 {
            let want = self.f(key, b, 0);
            buf.clear();
            self.options(key, b, &mut buf);
            let mut chosen = buf[0];
            for o in buf.clone() {
                if o.gain + self.f(o.next, o.nb, 1) == want {
                    chosen = o;
                    break;
                }
            }
            if !matches!(chosen.g, Grp::Drop | Grp::Defer) {
                out.push(chosen.g);
            }
            key = chosen.next;
            b = chosen.nb;
        }
        (total, out)
    }

    /// Deficiency through runs/sets.
    pub fn def_runs(&mut self, h: &Hc) -> u8 {
        14 - (self.kept(&h.c) + h.j).min(14)
    }
}

/// Deficiency through 7 pairs. With `dead`, a single whose twin is gone can only pair with an okey.
pub fn def_pairs(h: &Hc, dead: Option<&[bool; 52]>) -> u8 {
    let mut pairs = 0u8;
    let mut live = 0u8;
    let mut deadc = 0u8;
    for k in 0..52 {
        pairs += h.c[k] / 2;
        if h.c[k] % 2 == 1 {
            if dead.is_some_and(|d| d[k]) {
                deadc += 1;
            } else {
                live += 1;
            }
        }
    }
    let p = pairs.min(7);
    let mut q = 7 - p;
    let mut kept = 2 * p;
    let mut jl = h.j;
    // Okeys pair dead singles first, then live ones.
    let a = jl.min(deadc).min(q);
    kept += 2 * a;
    q -= a;
    jl -= a;
    let a2 = jl.min(live).min(q);
    kept += 2 * a2;
    q -= a2;
    jl -= a2;
    let live = live - a2;
    let pj = (jl / 2).min(q);
    kept += 2 * pj;
    q -= pj;
    jl -= 2 * pj;
    if jl > 0 && q > 0 {
        kept += 1;
        q -= 1;
    }
    kept += live.min(q);
    14 - kept.min(14)
}

// =================================================================================================
// Hand (full truth) and information sets

#[derive(Clone, Debug)]
pub struct Hand {
    pub racks: [Vec<u8>; 4],
    /// Each seat's discard stack, bottom → top. The right-hand neighbour may take the top.
    pub discards: [Vec<u8>; 4],
    /// Tiles each seat took from its left neighbour's discards (public knowledge).
    pub taken: [Vec<u8>; 4],
    /// Centre pile; the next tile is the **last** element.
    pub pile: Vec<u8>,
    pub indicator: u8,
    pub okey: u8,
    pub turn: usize,
    pub draw_stage: bool,
    pub starter: usize,
    pub turns: u32,
    pub shown: Option<usize>,
}

impl Hand {
    pub fn deal(rng: &mut Rng, starter: usize) -> Hand {
        let mut tiles: Vec<u8> = (0..N_TILES).collect();
        rng.shuffle(&mut tiles);
        let pos = tiles.iter().position(|&t| !is_false(t)).unwrap_or(0);
        let indicator = tiles.remove(pos);
        let mut racks: [Vec<u8>; 4] = Default::default();
        for s in 0..4 {
            let n = if s == starter { 15 } else { 14 };
            racks[s] = tiles.drain(..n).collect();
        }
        let twin = if indicator < 52 { indicator + 52 } else { indicator - 52 };
        let shown = (0..4).find(|&s| racks[s].contains(&twin));
        Hand {
            racks,
            discards: Default::default(),
            taken: Default::default(),
            pile: tiles,
            indicator,
            okey: okey_of(indicator),
            turn: starter,
            draw_stage: false,
            starter,
            turns: 0,
            shown,
        }
    }

    pub fn left(seat: usize) -> usize {
        (seat + 3) % 4
    }
    pub fn right(seat: usize) -> usize {
        (seat + 1) % 4
    }

    /// The tile `seat` may take now (its left neighbour's latest discard).
    pub fn offer(&self, seat: usize) -> Option<u8> {
        self.discards[Hand::left(seat)].last().copied()
    }

    /// The information set of `seat`: public data and its own rack only.
    pub fn info(&self, seat: usize) -> Info<'_> {
        Info {
            seat,
            rack: &self.racks[seat],
            discards: &self.discards,
            taken: &self.taken,
            indicator: self.indicator,
            okey: self.okey,
            pile_count: self.pile.len(),
            turns: self.turns,
        }
    }

    /// Pile tiles `seat` will draw if every other player draws from the pile: draw number k comes
    /// `offset + 4k` tiles from the top.
    fn future(&self, offset: usize, n: usize) -> Vec<u8> {
        let len = self.pile.len();
        (0..n).map(|k| offset + 4 * k).take_while(|&i| i < len).map(|i| self.pile[len - 1 - i]).collect()
    }
}

/// What a seat legitimately knows. Easy/normal/hard AIs and the player's hint see only this.
pub struct Info<'a> {
    pub seat: usize,
    pub rack: &'a [u8],
    pub discards: &'a [Vec<u8>; 4],
    pub taken: &'a [Vec<u8>; 4],
    pub indicator: u8,
    pub okey: u8,
    pub pile_count: usize,
    pub turns: u32,
}

impl Info<'_> {
    fn offer(&self) -> Option<u8> {
        self.discards[Hand::left(self.seat)].last().copied()
    }
}

/// Tiles not visible to the deciding seat, by effective kind (+ wild okeys).
#[derive(Clone, Copy)]
struct Unseen {
    k: [u8; 52],
    j: u8,
    total: u32,
}

impl Unseen {
    fn from_seen<'a>(okey: u8, seen: impl Iterator<Item = &'a u8>) -> Unseen {
        let mut phys = [2i8; 52];
        let mut fals = 2i8;
        for &id in seen {
            if is_false(id) {
                fals -= 1;
            } else {
                phys[(id % 52) as usize] -= 1;
            }
        }
        let mut k = [0u8; 52];
        for i in 0..52 {
            k[i] = phys[i].max(0) as u8;
        }
        let j = k[okey as usize];
        k[okey as usize] = fals.max(0) as u8;
        let total = k.iter().map(|&x| x as u32).sum::<u32>() + j as u32;
        Unseen { k, j, total }
    }

    fn of_info(info: &Info) -> Unseen {
        let ind = [info.indicator];
        let seen = info
            .rack
            .iter()
            .chain(ind.iter())
            .chain(info.discards.iter().flatten())
            .chain(info.taken.iter().flatten());
        Unseen::from_seen(info.okey, seen)
    }

    fn dead(&self) -> [bool; 52] {
        let mut d = [false; 52];
        for i in 0..52 {
            d[i] = self.k[i] == 0;
        }
        d
    }
}

// =================================================================================================
// Evaluation

#[derive(Clone, Copy, Debug)]
struct Ev {
    def: u8,
    uke: u32,
    pairs: bool,
}

fn neighbours(h: &Hc) -> [bool; 52] {
    let mut m = [false; 52];
    for k in 0..52 {
        if h.c[k] == 0 {
            continue;
        }
        let col = k / 13;
        let n = k % 13;
        m[k] = true;
        for d in 1..=2usize {
            if n + d <= 12 {
                m[col * 13 + n + d] = true;
            }
            if n >= d {
                m[col * 13 + n - d] = true;
            }
        }
        // 12-13-1 wrap.
        if n == 0 {
            m[col * 13 + 12] = true;
            m[col * 13 + 11] = true;
        }
        if n >= 11 {
            m[col * 13] = true;
        }
        for c2 in 0..4 {
            m[c2 * 13 + n] = true;
        }
    }
    m
}

fn deficiency(s: &mut Solver, h: &Hc, dead: Option<&[bool; 52]>) -> (u8, u8) {
    s.set_dead(if h.j > 0 { None } else { dead });
    let dr = s.def_runs(h);
    let dp = def_pairs(h, dead);
    (dr, dp)
}

/// Deficiency and acceptance of a 14-tile hand.
fn evaluate(s: &mut Solver, h: &Hc, un: &Unseen, dead_aware: bool, with_uke: bool) -> Ev {
    let dead = un.dead();
    let dd = if dead_aware { Some(&dead) } else { None };
    let (dr, dp) = deficiency(s, h, dd);
    evaluate_with(s, h, un, dead_aware, with_uke, dr, dp)
}

/// Deficiency only (cheap first pass).
fn def_only(s: &mut Solver, h: &Hc, un: &Unseen, dead_aware: bool) -> (u8, u8) {
    let dead = un.dead();
    deficiency(s, h, if dead_aware { Some(&dead) } else { None })
}

fn evaluate_with(s: &mut Solver, h: &Hc, un: &Unseen, dead_aware: bool, with_uke: bool, dr: u8, dp: u8) -> Ev {
    let dead = un.dead();
    let dd = if dead_aware { Some(&dead) } else { None };
    let cur = dr.min(dp);
    let uke = if with_uke && cur > 0 { improvers(s, h, un, dd, dr, dp).iter().map(|x| x.1 as u32).sum() } else { 0 };
    Ev { def: cur, uke, pairs: dp < dr }
}

/// Unseen kinds (with counts) whose draw lowers the deficiency; `None` = a wild okey.
fn improvers(s: &mut Solver, h: &Hc, un: &Unseen, dd: Option<&[bool; 52]>, dr: u8, dp: u8) -> Vec<(Option<u8>, u8)> {
    let cur = dr.min(dp);
    let mut out = Vec::new();
    if cur == 0 {
        return out;
    }
    let near = neighbours(h);
    for k in 0..52u8 {
        let n = un.k[k as usize];
        if n == 0 || !near[k as usize] {
            continue;
        }
        let h2 = h.with(Some(k));
        if def_pairs(&h2, dd) < cur {
            out.push((Some(k), n));
            continue;
        }
        if dr <= cur {
            s.set_dead(if h2.j > 0 { None } else { dd });
            if s.def_runs(&h2) < cur {
                out.push((Some(k), n));
            }
        }
    }
    if un.j > 0 {
        out.push((None, un.j));
    }
    out
}

/// Second-step acceptance: the average acceptance after one improving draw (best discard then).
fn uke2(s: &mut Solver, h: &Hc, un: &Unseen, dead_aware: bool, dr: u8, dp: u8) -> f64 {
    let dead = un.dead();
    let dd = if dead_aware { Some(dead) } else { None };
    let mut imps = improvers(s, h, un, dd.as_ref(), dr, dp);
    imps.sort_by_key(|x| std::cmp::Reverse(x.1));
    let mut tot = 0.0;
    let mut w = 0.0;
    for (e, n) in imps.into_iter().take(6) {
        let Some(k) = e else { continue };
        let h15 = h.with(e);
        let mut un2 = *un;
        un2.k[k as usize] -= 1;
        un2.total -= 1;
        let mut first: Vec<(Hc, u8, u8)> = Vec::new();
        for d in 0..52u8 {
            if h15.c[d as usize] == 0 || d == k {
                continue;
            }
            let mut h14 = h15;
            h14.c[d as usize] -= 1;
            let (a, b) = def_only(s, &h14, &un2, dead_aware);
            first.push((h14, a, b));
        }
        let md = first.iter().map(|x| x.1.min(x.2)).min().unwrap_or(99);
        let mut best = 0u32;
        let mut tried = 0;
        for (h14, a, b) in first {
            if a.min(b) != md || tried >= 2 {
                continue;
            }
            tried += 1;
            let ev = evaluate_with(s, &h14, &un2, dead_aware, true, a, b);
            best = best.max(ev.uke);
        }
        tot += n as f64 * best as f64;
        w += n as f64;
    }
    if w > 0.0 {
        tot / w
    } else {
        0.0
    }
}

/// 0 none · 1 same kind · 2 same colour ±1 · 3 same colour ±2 · 4 same number, other colour.
pub(crate) fn rel(a: u8, b: u8) -> u8 {
    if a == b {
        return 1;
    }
    let (ca, na) = (a / 13, a % 13);
    let (cb, nb) = (b / 13, b % 13);
    if ca == cb {
        let d = (na as i32 - nb as i32).abs();
        // Treat 1 as following 13 too.
        let wa = if na == 0 { 13 } else { na as i32 };
        let wb = if nb == 0 { 13 } else { nb as i32 };
        let d = d.min((wa - wb).abs());
        return match d {
            1 => 2,
            2 => 3,
            _ => 0,
        };
    }
    if na == nb {
        4
    } else {
        0
    }
}

/// Danger of discarding a tile of effective kind `k` to the right-hand neighbour, from public
/// evidence: what they took from us (they collect around it), what we threw and they passed, and
/// what they threw themselves. Returns (danger, strongest evidence tile id).
fn danger(info: &Info, k: Option<u8>, live: bool, un: &Unseen) -> (f64, Option<u8>) {
    let Some(k) = k else {
        return (60.0, None);
    };
    let n = Hand::right(info.seat);
    let okey = info.okey;
    let mut d = 0.0;
    let mut best: (f64, Option<u8>) = (0.0, None);
    for &t in &info.taken[n] {
        let Some(tk) = eff(t, okey) else { continue };
        let w = match rel(k, tk) {
            1 => 1.5,
            2 => 4.0,
            3 => 2.0,
            4 => 3.0,
            _ => 0.0,
        };
        d += w;
        if w > best.0 {
            best = (w, Some(t));
        }
    }
    for &t in &info.discards[info.seat] {
        let Some(tk) = eff(t, okey) else { continue };
        d -= match rel(k, tk) {
            1 => 3.0,
            2 => 1.2,
            4 => 1.0,
            _ => 0.0,
        };
    }
    for &t in &info.discards[n] {
        let Some(tk) = eff(t, okey) else { continue };
        d -= match rel(k, tk) {
            1 => 2.5,
            2 => 1.0,
            3 => 0.4,
            4 => 1.0,
            _ => 0.0,
        };
    }
    if live {
        // A tile whose neighbours are still around can complete something for anyone.
        let col = k / 13;
        let num = k % 13;
        let mut around = 0u32;
        for c2 in 0..4u8 {
            if c2 != col {
                around += un.k[(c2 * 13 + num) as usize] as u32;
            }
        }
        if num >= 1 {
            around += un.k[(col * 13 + num - 1) as usize] as u32;
        }
        around += un.k[(col * 13 + (num + 1) % 13) as usize] as u32;
        d += 0.25 * around as f64;
    }
    (d.max(0.0), best.1)
}

// =================================================================================================
// Explanations

fn grp_desc(g: &Grp, okey: u8) -> String {
    let _ = okey;
    match *g {
        Grp::Set { pos, cols } => {
            let names: Vec<&str> = (0..4).filter(|c| cols >> c & 1 == 1).map(|c| COLS[c as usize]).collect();
            format!("{}'{} peri ({})", pos % 13 + 1, PL[(pos % 13) as usize], names.join(", "))
        }
        Grp::Run { col, start, mask } => {
            let end = 15 - mask.leading_zeros() as u16;
            let nums: Vec<String> = (start as u16..=end).filter(|q| mask >> q & 1 == 1).map(|q| format!("{}", q % 13 + 1)).collect();
            let gaps: Vec<String> = (start as u16..=end).filter(|q| mask >> q & 1 == 0).map(|q| format!("{}", q % 13 + 1)).collect();
            if gaps.is_empty() {
                format!("{} {} serisi", COLS[col as usize], nums.join("-"))
            } else {
                format!("{} {} serisi ({} bekliyor)", COLS[col as usize], nums.join("-"), gaps.join(", "))
            }
        }
        _ => String::new(),
    }
}

/// The best structure's group (≥ 2 tiles) that holds kind `k`.
fn role(s: &mut Solver, h: &Hc, k: u8) -> Option<Grp> {
    s.set_dead(None);
    let (_, gs) = s.groups(&h.c);
    gs.into_iter().find(|g| g.size() >= 2 && g.kinds().contains(&k))
}

fn who_right(seat: usize) -> String {
    let r = Hand::right(seat);
    if r == 0 {
        "sağındaki oyuncu (sen)".into()
    } else {
        format!("sağındaki {}", NAMES[r])
    }
}

/// "Soldan gelen" + who threw it.
fn from_left(seat: usize) -> String {
    let l = Hand::left(seat);
    if l == 0 {
        "Senin attığın".into()
    } else {
        format!("{} attığı", GEN[l])
    }
}

// =================================================================================================
// Decisions

#[derive(Clone, Debug)]
pub struct DrawChoice {
    pub take: bool,
    pub reason: String,
}

#[derive(Clone, Debug)]
pub struct DiscardChoice {
    pub id: u8,
    pub finish: bool,
    pub reason: String,
}

/// Unique tiles by effective kind (one physical id each), okeys last.
fn unique_tiles(rack: &[u8], okey: u8) -> Vec<u8> {
    let mut seen: Vec<Option<u8>> = Vec::new();
    let mut out = Vec::new();
    for &id in rack {
        let e = eff(id, okey);
        if !seen.contains(&e) {
            seen.push(e);
            out.push(id);
        }
    }
    out.sort_by_key(|&id| eff(id, okey).is_none());
    out
}

fn without(rack: &[u8], id: u8) -> Vec<u8> {
    let mut v = rack.to_vec();
    if let Some(i) = v.iter().position(|&x| x == id) {
        v.remove(i);
    }
    v
}

/// Best finishing discard of a 15-tile rack: (tile, pairs, okey discarded).
fn find_finish(s: &mut Solver, rack: &[u8], okey: u8) -> Option<(u8, bool, bool)> {
    if rack.len() != 15 {
        return None;
    }
    let mut best: Option<(u8, bool, bool, u8)> = None;
    for id in unique_tiles(rack, okey) {
        let rest = without(rack, id);
        let h = Hc::of(&rest, okey);
        let quick = pairs_exact(&h) || {
            s.set_dead(None);
            s.def_runs(&h) == 0
        };
        if !quick {
            continue;
        }
        if let Some(pairs) = winning(&rest, okey) {
            let ok = eff(id, okey).is_none();
            let mult = (if pairs { 2 } else { 1 }) * (if ok { 2 } else { 1 });
            if best.is_none_or(|b| mult > b.3) {
                best = Some((id, pairs, ok, mult));
            }
        }
    }
    best.map(|b| (b.0, b.1, b.2))
}

fn finish_reason(id: u8, pairs: bool, okd: bool, okey: u8, you: bool) -> String {
    let how = match (pairs, okd) {
        (true, true) => "çiftle ve okey atarak — rakipler 8'er puan kaybeder",
        (true, false) => "çiftle — rakipler 4'er puan kaybeder",
        (false, true) => "okey atarak — rakipler 4'er puan kaybeder",
        _ => "kalan 14 taş per oluyor",
    };
    if you {
        format!("Bitirebilirsin: {} ortaya sürükle ({how})", tacc(id, okey))
    } else {
        format!("{} atarak bitirdi ({how})", cap(&tacc(id, okey)))
    }
}

struct Scored {
    id: u8,
    ev: Ev,
    own: f64,
    danger: f64,
    evidence: Option<u8>,
    total: f64,
}

/// Information-set based draw decision (easy / normal / hard, and the player's hint).
pub fn info_draw(info: &Info, lvl: Level, s: &mut Solver, rng: &mut Rng, you: bool) -> DrawChoice {
    let okey = info.okey;
    let Some(top) = info.offer() else {
        return DrawChoice { take: false, reason: if you { "Ortadan çek".into() } else { "Ortadan çekti".into() } };
    };
    let un = Unseen::of_info(info);
    let mut r15 = info.rack.to_vec();
    r15.push(top);
    let left = from_left(info.seat);
    if find_finish(s, &r15, okey).is_some() {
        return DrawChoice {
            take: true,
            reason: if you {
                format!("{left} {} al: onunla bitiriyorsun", tacc(top, okey))
            } else {
                format!("{left} {} aldı: onunla bitiriyor", tacc(top, okey))
            },
        };
    }
    let dead_aware = lvl >= Level::Hard;
    let with_uke = lvl >= Level::Normal;
    let h0 = Hc::of(info.rack, okey);
    let e0 = evaluate(s, &h0, &un, dead_aware, with_uke);
    // Best hand after taking (never discard the taken tile itself).
    let h15 = h0.with(eff(top, okey));
    let mut e1: Option<Ev> = None;
    let mut first: Vec<(Hc, u8, u8)> = Vec::new();
    for id in unique_tiles(info.rack, okey) {
        let e = eff(id, okey);
        if e.is_none() {
            continue;
        }
        let mut h = h15;
        h.remove(e);
        let (dr, dp) = def_only(s, &h, &un, dead_aware);
        first.push((h, dr, dp));
    }
    let min_def = first.iter().map(|x| x.1.min(x.2)).min().unwrap_or(99);
    for (h, dr, dp) in first {
        if dr.min(dp) > min_def {
            continue;
        }
        let ev = evaluate_with(s, &h, &un, dead_aware, with_uke, dr, dp);
        if e1.is_none_or(|b| (ev.def, std::cmp::Reverse(ev.uke)) < (b.def, std::cmp::Reverse(b.uke))) {
            e1 = Some(ev);
        }
    }
    let e1 = e1.unwrap_or(e0);
    let take = e1.def < e0.def;
    if lvl == Level::Easy && take && rng.chance(0.3) {
        return DrawChoice {
            take: false,
            reason: format!("{left} {} fark etmedi, ortadan çekti", tacc(top, okey)),
        };
    }
    let tn = tname(top, okey);
    if take {
        let grp = eff(top, okey).and_then(|k| role(s, &h15, k));
        let what = match (grp, e1.pairs) {
            (_, true) => format!("{tn} ile çift oluyor"),
            (Some(g), _) => format!("{} oluyor", grp_desc(&g, okey)),
            _ => format!("{tn} elini güçlendiriyor"),
        };
        let delta = if e1.def < e0.def { format!(" — eksik {} → {}", e0.def, e1.def) } else { " — elin çok daha açık kalıyor".into() };
        DrawChoice {
            take: true,
            reason: if you {
                format!("{left} {} al: {what}{delta}", tacc(top, okey))
            } else {
                format!("{left} {} aldı: {what}{delta}", tacc(top, okey))
            },
        }
    } else {
        DrawChoice {
            take: false,
            reason: if you {
                format!("Ortadan çek: {tn} eline katkı yapmıyor (eksik {} kalırdı)", e1.def)
            } else {
                format!("{tn} işine yaramadı, ortadan çekti")
            },
        }
    }
}

/// Probabilistic turns-to-finish estimate from deficiency and acceptance.
fn turns_est(e: &Ev, un: &Unseen) -> f64 {
    if e.def == 0 {
        return 0.0;
    }
    let per = (un.total.max(1) as f64 / (e.uke as f64 + 0.5)).min(25.0);
    per * (1.0 + 1.5 * (e.def as f64 - 1.0))
}

/// Information-set based discard decision.
pub fn info_discard(info: &Info, lvl: Level, s: &mut Solver, rng: &mut Rng, you: bool) -> DiscardChoice {
    let okey = info.okey;
    let rack = info.rack;
    if let Some((id, pairs, okd)) = find_finish(s, rack, okey) {
        return DiscardChoice { id, finish: true, reason: finish_reason(id, pairs, okd, okey, you) };
    }
    let un = Unseen::of_info(info);
    let dead_aware = lvl >= Level::Hard;
    let with_uke = lvl >= Level::Normal;
    let h15 = Hc::of(rack, okey);
    let n = Hand::right(info.seat);
    let heat = 1.0 + 0.5 * info.taken[n].len() as f64;
    let late = if info.pile_count < 12 { 1.5 } else { 1.0 };
    let mut cands: Vec<Scored> = Vec::new();
    let uniq = unique_tiles(rack, okey);
    let has_plain = uniq.iter().any(|&id| eff(id, okey).is_some());
    let mut first: Vec<(u8, Hc, u8, u8)> = Vec::new();
    for id in uniq {
        let e = eff(id, okey);
        if e.is_none() && has_plain {
            continue;
        }
        let mut h = h15;
        h.remove(e);
        let (dr, dp) = def_only(s, &h, &un, dead_aware);
        first.push((id, h, dr, dp));
    }
    let min_def = first.iter().map(|x| x.2.min(x.3)).min().unwrap_or(99);
    let slack = if lvl >= Level::Hard { 1 } else { 0 };
    let mut hands: Vec<(Hc, u8, u8, f64)> = Vec::new();
    for (id, h, dr, dp) in first {
        let e = eff(id, okey);
        let ev = if dr.min(dp) <= min_def + slack {
            evaluate_with(s, &h, &un, dead_aware, with_uke, dr, dp)
        } else {
            Ev { def: dr.min(dp), uke: 0, pairs: dp < dr }
        };
        let (dg, evidence) = danger(info, e, false, &un);
        let own = match lvl {
            Level::Easy => -1000.0 * ev.def as f64 + 0.01 * (e.map_or(0, |k| k % 13) as f64),
            Level::Normal => -1000.0 * ev.def as f64 + 8.0 * ev.uke as f64,
            _ => -1000.0 * ev.def as f64 + 9.0 * ev.uke as f64,
        };
        let w = match lvl {
            Level::Easy => 0.0,
            Level::Normal => 30.0,
            _ => {
                let mut w = 30.0 * heat * late;
                if turns_est(&ev, &un) > info.pile_count as f64 / 4.0 + 1.0 {
                    w *= 2.0; // can't realistically finish: play safe
                }
                w
            }
        };
        cands.push(Scored { id, ev, own, danger: dg, evidence, total: own - w * dg });
        hands.push((h, dr, dp, w));
    }
    if lvl >= Level::Hard {
        // Second-step lookahead for the most promising candidates.
        let mut order: Vec<usize> = (0..cands.len()).filter(|&i| cands[i].ev.def == min_def).collect();
        order.sort_by(|&a, &b| cands[b].own.partial_cmp(&cands[a].own).unwrap_or(std::cmp::Ordering::Equal));
        for &i in order.iter().take(2) {
            let (h, dr, dp, w) = hands[i];
            let u2 = uke2(s, &h, &un, dead_aware, dr, dp);
            cands[i].own += 4.0 * u2;
            cands[i].total = cands[i].own - w * cands[i].danger;
        }
    }
    cands.sort_by(|a, b| b.total.partial_cmp(&a.total).unwrap_or(std::cmp::Ordering::Equal));
    let mut pick = 0usize;
    let mut slip = false;
    if lvl == Level::Easy {
        // Ties at the top: random among them.
        let ties = cands.iter().take_while(|c| c.ev.def == cands[0].ev.def).count();
        pick = rng.below(ties.max(1));
        if cands.len() > ties && rng.chance(0.18) && cands[ties].ev.def <= cands[0].ev.def + 1 {
            pick = ties;
            slip = true;
        }
    }
    let chosen = &cands[pick];
    let id = chosen.id;
    let k = eff(id, okey);
    let tn = tacc(id, okey);
    // Role of the tile in the 15-tile structure.
    let dup = k.is_some_and(|k| h15.c[k as usize] >= 2);
    let grp = k.and_then(|k| role(s, &h15, k));
    let base = if slip {
        match grp {
            Some(g) => format!("Dikkatsiz atış: {tn} attı, oysa {} için lazımdı", grp_desc(&g, okey)),
            None => format!("Dikkatsiz atış: {tn} attı, daha iyisi vardı"),
        }
    } else if dup && !chosen.ev.pairs {
        if you {
            format!("İki tane {} var; birini at", tname(id, okey))
        } else {
            format!("İki tane {} vardı; birini attı", tname(id, okey))
        }
    } else if chosen.ev.pairs {
        if you {
            format!("Çifte git: {tn} at, eşi gelme ihtimali en düşük tek taş")
        } else {
            format!("Çifte gidiyor: {tn} attı, eşi en zor gelecek tek taştı")
        }
    } else {
        match grp {
            None => {
                if you {
                    format!("{} at: hiçbir perle bağı yok", cap(&tn))
                } else {
                    format!("{} attı: hiçbir perle bağı yoktu", cap(&tn))
                }
            }
            Some(g) => {
                if you {
                    format!("{} at: {} en zayıf bağlantın", cap(&tn), grp_desc(&g, okey))
                } else {
                    format!("{} attı: {} en zayıf bağlantısıydı", cap(&tn), grp_desc(&g, okey))
                }
            }
        }
    };
    let mut reason = base;
    if lvl >= Level::Normal && !slip {
        reason += &format!(" · eksik {}", chosen.ev.def);
        if lvl >= Level::Hard && un.total > 0 {
            let p = 100.0 * chosen.ev.uke as f64 / un.total as f64;
            reason += &format!(", {} taş işine yarar (her çekişte %{:.0})", chosen.ev.uke, p);
        } else {
            reason += &format!(", {} taş işine yarar", chosen.ev.uke);
        }
    }
    // Defensive note: a better own-hand discard was skipped because of the neighbour.
    if lvl >= Level::Normal && !slip {
        if let Some(best_own) = cands.iter().max_by(|a, b| a.own.partial_cmp(&b.own).unwrap_or(std::cmp::Ordering::Equal)) {
            if best_own.id != id && best_own.danger > chosen.danger + 0.5 {
                let avoided = cap(&tacc(best_own.id, okey));
                let who = if you { "sağındaki oyuncu".to_string() } else { who_right(info.seat) };
                let note = match best_own.evidence {
                    Some(t) if you => format!("{avoided} atma: {who} {} aldı, ona yarar", tacc(t, okey)),
                    Some(t) => format!("{avoided} atmadı: {who} {} aldı, ona yarardı", tacc(t, okey)),
                    None if you => format!("{avoided} atma: {who} için tehlikeli"),
                    None => format!("{avoided} atmadı: {who} için tehlikeliydi"),
                };
                reason = format!("{reason}. {note}");
            }
        }
    }
    DiscardChoice { id, finish: false, reason }
}

// ---- Omniscient planning (impossible) -----------------------------------------------------------

/// A winning 14-subset of `pool` (prefers later tiles as targets so early tiles can be thrown);
/// returns the target flags.
fn pool_target(s: &mut Solver, pool: &[u8], okey: u8) -> Option<Vec<bool>> {
    let h = Hc::of(pool, okey);
    // Pairs route.
    let pairs_ok = {
        let pairs: u8 = h.c.iter().map(|&x| x / 2).sum();
        let singles: u8 = h.c.iter().map(|&x| x % 2).sum();
        pairs + h.j.min(singles) + h.j.saturating_sub(singles) / 2 >= 7
    };
    let pick = |kinds: &mut Vec<Option<u8>>| -> Vec<bool> {
        let mut flags = vec![false; pool.len()];
        for i in (0..pool.len()).rev() {
            let e = eff(pool[i], okey);
            if let Some(p) = kinds.iter().position(|&x| x == e) {
                kinds.remove(p);
                flags[i] = true;
            }
        }
        flags
    };
    s.set_dead(None);
    let (kept, gs) = s.groups(&h.c);
    if kept + h.j >= 14 {
        let mut kinds: Vec<Option<u8>> = gs.iter().flat_map(|g| g.kinds()).map(Some).collect();
        while kinds.len() < 14 {
            kinds.push(None);
        }
        let flags = pick(&mut kinds);
        let tgt: Vec<u8> = pool.iter().zip(&flags).filter(|(_, &f)| f).map(|(&t, _)| t).collect();
        if winning(&tgt, okey).is_some() {
            return Some(flags);
        }
    }
    if pairs_ok {
        let mut kinds: Vec<Option<u8>> = Vec::new();
        for k in 0..52u8 {
            if h.c[k as usize] >= 2 && kinds.len() < 14 {
                kinds.push(Some(k));
                kinds.push(Some(k));
            }
        }
        let mut j = h.j;
        for k in 0..52u8 {
            if h.c[k as usize] % 2 == 1 && j > 0 && kinds.len() < 14 {
                kinds.push(Some(k));
                kinds.push(None);
                j -= 1;
            }
        }
        while kinds.len() < 14 && j > 0 {
            kinds.push(None);
            j -= 1;
        }
        if kinds.len() == 14 {
            let flags = pick(&mut kinds);
            let tgt: Vec<u8> = pool.iter().zip(&flags).filter(|(_, &f)| f).map(|(&t, _)| t).collect();
            if winning(&tgt, okey).is_some() {
                return Some(flags);
            }
        }
    }
    None
}

fn pool_winnable(s: &mut Solver, hand14: &[u8], fut: &[u8], okey: u8) -> bool {
    let mut pool: Vec<u8> = hand14.to_vec();
    pool.extend_from_slice(fut);
    let h = Hc::of(&pool, okey);
    s.set_dead(None);
    def_pairs(&h, None) == 0 || s.def_runs(&h) == 0
}

/// Deficiency of the whole known pool (hand + every known future draw): how many needed tiles
/// will not come by themselves.
fn pool_def(s: &mut Solver, hand14: &[u8], fut: &[u8], okey: u8) -> u8 {
    let mut pool: Vec<u8> = hand14.to_vec();
    pool.extend_from_slice(fut);
    let h = Hc::of(&pool, okey);
    s.set_dead(None);
    def_pairs(&h, None).min(s.def_runs(&h))
}

/// Fewest future draws after which a 14-tile hand can finish with the known draws `fut`
/// (binary search on the monotone "pool can win", then a discard-order feasibility check).
fn finish_in(s: &mut Solver, hand14: &[u8], fut: &[u8], okey: u8, max_t: usize) -> Option<usize> {
    let max_t = max_t.min(fut.len());
    if max_t == 0 || !pool_winnable(s, hand14, &fut[..max_t], okey) {
        return None;
    }
    let (mut lo, mut hi) = (1, max_t);
    while lo < hi {
        let mid = (lo + hi) / 2;
        if pool_winnable(s, hand14, &fut[..mid], okey) {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }
    for t in lo..=max_t {
        let mut pool: Vec<u8> = hand14.to_vec();
        pool.extend_from_slice(&fut[..t]);
        let Some(flags) = pool_target(s, &pool, okey) else { continue };
        // Feasibility: by turn i there must be i non-target tiles to throw.
        let base = hand14.len();
        let ok = (1..t).all(|i| flags[..base + i].iter().filter(|&&f| !f).count() >= i);
        if ok {
            return Some(t);
        }
    }
    None
}

/// Exact danger of feeding `k_id` to the right-hand neighbour (the planner sees their rack).
fn exact_danger(s: &mut Solver, hand: &Hand, seat: usize, id: u8, base_def: u8) -> (f64, bool) {
    let n = Hand::right(seat);
    let okey = hand.okey;
    let mut r = hand.racks[n].clone();
    r.push(id);
    if find_finish(s, &r, okey).is_some() {
        return (5000.0, true);
    }
    let h = Hc::of(&r, okey);
    let (dr, dp) = deficiency(s, &h, None);
    if dr.min(dp) < base_def {
        (120.0 + 60.0 * (4u8.saturating_sub(base_def)) as f64, false)
    } else {
        (0.0, false)
    }
}

fn base_def(s: &mut Solver, hand: &Hand, seat: usize) -> u8 {
    let h = Hc::of(&hand.racks[Hand::right(seat)], hand.okey);
    let (dr, dp) = deficiency(s, &h, None);
    dr.min(dp)
}

/// Best plan for a 15-tile rack and known future draws: (turns, discard, danger, feeds-a-finish).
/// Without a finish in sight, candidates are ranked by the deficiency of hand + all known draws.
fn omni_plan(s: &mut Solver, hand: &Hand, seat: usize, rack: &[u8], fut: &[u8], block: bool) -> (Option<usize>, u8, f64, bool, f64) {
    let okey = hand.okey;
    if let Some((id, _, _)) = find_finish(s, rack, okey) {
        return (Some(0), id, 0.0, false, 0.0);
    }
    let bd = base_def(s, hand, seat);
    let uniq = unique_tiles(rack, okey);
    let has_plain = uniq.iter().any(|&id| eff(id, okey).is_some());
    let mut best: Option<(Option<usize>, u8, f64, bool, f64)> = None;
    let mut best_t = fut.len();
    for id in uniq {
        if eff(id, okey).is_none() && has_plain {
            continue;
        }
        let rest = without(rack, id);
        let t = finish_in(s, &rest, fut, okey, (best_t + 1).min(fut.len()));
        let (dg, fin) = if block { exact_danger(s, hand, seat, id, bd) } else { (0.0, false) };
        let score = match t {
            Some(t) => -(t as f64) * 100.0 - dg,
            None => {
                let h = Hc::of(&rest, okey);
                let (dr, dp) = deficiency(s, &h, None);
                -2000.0 - 100.0 * pool_def(s, &rest, fut, okey) as f64 - 30.0 * dr.min(dp) as f64 - dg
            }
        };
        if let Some(tt) = t {
            best_t = best_t.min(tt);
        }
        if best.as_ref().is_none_or(|b| score > b.4) {
            best = Some((t, id, dg, fin, score));
        }
    }
    best.expect("rack has tiles")
}

pub fn omni_discard(hand: &Hand, seat: usize, s: &mut Solver, block: bool) -> DiscardChoice {
    let okey = hand.okey;
    let rack = &hand.racks[seat];
    if let Some((id, pairs, okd)) = find_finish(s, rack, okey) {
        return DiscardChoice { id, finish: true, reason: finish_reason(id, pairs, okd, okey, false) };
    }
    let fut = hand.future(3, LOOKAHEAD);
    let (t, id, dg, _, _) = omni_plan(s, hand, seat, rack, &fut, block);
    let tn = tacc(id, okey);
    let mut reason = match t {
        Some(t) => format!("{} attı: destenin sırasını biliyor, {t} çekiş sonra bitiyor; bu taş planında yok", cap(&tn)),
        None => format!(
            "{} attı: sıradaki {} çekişini biliyor, bu taş hiçbirine bağlanmıyor",
            cap(&tn),
            fut.len()
        ),
    };
    if dg > 0.0 {
        reason += " (sağındakine yarıyor ama başka yolu yok)";
    } else if block {
        // Did it hold back a tile that would have fed the neighbour?
        let bd = base_def(s, hand, seat);
        for alt in unique_tiles(rack, okey) {
            if alt == id || eff(alt, okey).is_none() {
                continue;
            }
            let (adg, fin) = exact_danger(s, hand, seat, alt, bd);
            if adg > 0.0 {
                let r = Hand::right(seat);
                let what = if fin { "elini bitirirdi" } else { "işine yarardı" };
                reason = format!("Sağındakinin elini görüyor: {} {} {what}, onu tutuyor — {reason}", tname(alt, okey), GEN[r]);
                break;
            }
        }
    }
    DiscardChoice { id, finish: false, reason }
}

/// How much the right-hand neighbour gains from drawing `tile` from the pile next.
fn pile_gift(s: &mut Solver, hand: &Hand, seat: usize, tile: Option<u8>) -> (f64, bool) {
    let Some(tile) = tile else { return (0.0, false) };
    let bd = base_def(s, hand, seat);
    exact_danger(s, hand, seat, tile, bd)
}

pub fn omni_draw(hand: &Hand, seat: usize, s: &mut Solver, block: bool) -> DrawChoice {
    let okey = hand.okey;
    let rack = &hand.racks[seat];
    let len = hand.pile.len();
    let Some(&p0) = hand.pile.last() else {
        return DrawChoice { take: hand.offer(seat).is_some(), reason: "Ortada taş kalmadı".into() };
    };
    let p1 = if len >= 2 { Some(hand.pile[len - 2]) } else { None };
    let pile_next = tname(p0, okey);
    let right = GEN[Hand::right(seat)];
    let Some(top) = hand.offer(seat) else {
        return DrawChoice { take: false, reason: format!("Ortadan çekti: sıradaki taşın {pile_next} olduğunu biliyor") };
    };
    let mut ra = rack.clone();
    ra.push(p0);
    let mut rb = rack.clone();
    rb.push(top);
    let fa = hand.future(4, LOOKAHEAD);
    let fb = hand.future(3, LOOKAHEAD);
    let (ta, _, _, _, sa) = omni_plan(s, hand, seat, &ra, &fa, block);
    let (tb, _, _, _, sb) = omni_plan(s, hand, seat, &rb, &fb, block);
    // Which pile tile the right-hand neighbour gets next depends on this choice.
    let (ga, fin_a) = if block { pile_gift(s, hand, seat, p1) } else { (0.0, false) };
    let (gb, fin_b) = if block { pile_gift(s, hand, seat, Some(p0)) } else { (0.0, false) };
    let score_a = sa - ga;
    let score_b = sb - gb;
    let left = from_left(seat);
    let take = score_b > score_a;
    let blocked = (take && sa > sb) || (!take && sb > sa);
    if take {
        let reason = if blocked {
            let p1n = p1.map(|t| tname(t, okey)).unwrap_or_default();
            format!(
                "{left} {} aldı: ortadan çekseydi sıradaki {p1n} {right} {}",
                tacc(top, okey),
                if fin_a { "elini bitirecekti" } else { "işine yarayacaktı" }
            )
        } else {
            let when = match tb {
                Some(0) => "hemen bitiriyor".to_string(),
                Some(t) => format!("{t} çekiş sonra bitiyor"),
                None => format!("sıradaki taş {pile_next} ondan daha az işine yarıyor"),
            };
            format!("{left} {} aldı: destenin sırasına göre böylece {when}", tacc(top, okey))
        };
        return DrawChoice { take: true, reason };
    }
    let why = if blocked {
        format!("{pile_next} {right} {}, onu kendisi aldı", if fin_b { "elini bitirecekti" } else { "işine yarayacaktı" })
    } else {
        match ta {
            Some(0) => "onunla bitiriyor".to_string(),
            Some(t) => format!("böylece {t} çekiş sonra bitiyor"),
            None => "eline en çok bu yarıyor".to_string(),
        }
    };
    DrawChoice { take: false, reason: format!("Ortadan çekti: sıradaki taşın {pile_next} olduğunu biliyor; {why}") }
}

// =================================================================================================
// Rack layout helpers (the player's two-tier rack)

/// Check one contiguous chunk of the rack, in display order. Returns "run" / "set".
pub(crate) fn chunk_kind(seq: &[Option<u8>]) -> Option<&'static str> {
    let n = seq.len();
    if n < 3 {
        return None;
    }
    // Set.
    if n <= 4 {
        let reals: Vec<u8> = seq.iter().flatten().copied().collect();
        if let Some(&f) = reals.first() {
            let num = f % 13;
            let mut cols = 0u8;
            let mut ok = true;
            for &k in &reals {
                if k % 13 != num || cols >> (k / 13) & 1 == 1 {
                    ok = false;
                    break;
                }
                cols |= 1 << (k / 13);
            }
            if ok {
                return Some("set");
            }
        } else {
            return Some("set");
        }
    }
    // Run (ascending; 1 may follow 13 at the very end).
    let Some(fi) = seq.iter().position(|e| e.is_some()) else { return Some("run") };
    let f = seq[fi].unwrap();
    let col = f / 13;
    let mut starts = vec![(f % 13) as i32 - fi as i32];
    if f % 13 == 0 {
        starts.push(13 - fi as i32);
    }
    'outer: for st in starts {
        if st < 0 || st + n as i32 - 1 > 13 {
            continue;
        }
        for (i, e) in seq.iter().enumerate() {
            if let Some(k) = *e {
                let v = st + i as i32;
                if k / 13 != col || (v % 13) as u8 != k % 13 {
                    continue 'outer;
                }
            }
        }
        return Some("run");
    }
    None
}

/// Valid melds (and pairs in 2-tile segments) among the gap-separated segments of the layout.
pub(crate) fn layout_melds(layout: &[i16; SLOTS], okey: u8) -> Vec<(Vec<usize>, &'static str)> {
    let mut out = Vec::new();
    for row in 0..2 {
        let mut i = 0;
        while i < ROW {
            if layout[row * ROW + i] < 0 {
                i += 1;
                continue;
            }
            let start = i;
            while i < ROW && layout[row * ROW + i] >= 0 {
                i += 1;
            }
            let slots: Vec<usize> = (start..i).map(|x| row * ROW + x).collect();
            let seq: Vec<Option<u8>> = slots.iter().map(|&x| eff(layout[x] as u8, okey)).collect();
            if seq.len() == 2 {
                if seq[0] == seq[1] || seq[0].is_none() || seq[1].is_none() {
                    out.push((slots, "pair"));
                }
                continue;
            }
            // Best partition into consecutive melds (max covered tiles).
            let n = seq.len();
            let mut best = vec![(0usize, usize::MAX); n + 1];
            for e in 1..=n {
                best[e] = (best[e - 1].0, e - 1); // tile e-1 uncovered
                for st in 0..e.saturating_sub(2) {
                    if chunk_kind(&seq[st..e]).is_some() {
                        let v = best[st].0 + (e - st);
                        if v > best[e].0 {
                            best[e] = (v, st);
                        }
                    }
                }
            }
            let mut e = n;
            let mut chunks = Vec::new();
            while e > 0 {
                let st = best[e].1;
                if st == e - 1 && (best[e].0 == best[e - 1].0) && chunk_kind(&seq[st..e]).is_none() {
                    e -= 1;
                    continue;
                }
                if let Some(kind) = chunk_kind(&seq[st..e]) {
                    chunks.push((slots[st..e].to_vec(), kind));
                }
                e = st;
            }
            chunks.reverse();
            out.extend(chunks);
        }
    }
    out
}

pub(crate) fn sort_key(id: u8, okey: u8) -> u16 {
    match eff(id, okey) {
        None => 1000 + id as u16,
        Some(k) => k as u16 * 2 + (id >= 52) as u16,
    }
}

/// Place groups of tiles left-to-right, a gap after each group, wrapping to the second row.
pub(crate) fn pack_layout(groups: &[Vec<Option<u8>>]) -> [i16; SLOTS] {
    let mut layout = [-1i16; SLOTS];
    let total: usize = groups.iter().map(|g| g.len()).sum();
    let gaps = groups.len();
    let gap = total + gaps <= SLOTS;
    let mut row = 0;
    let mut col = 0;
    for g in groups {
        if col + g.len() > ROW && row == 0 {
            row = 1;
            col = 0;
        }
        for &t in g {
            if col >= ROW {
                if row == 0 {
                    row = 1;
                    col = 0;
                } else {
                    break;
                }
            }
            layout[row * ROW + col] = t.map_or(-1, |x| x as i16);
            col += 1;
        }
        if gap && col < ROW {
            col += 1;
        }
    }
    // Anything that didn't fit (shouldn't happen): fill free slots.
    let placed: Vec<i16> = layout.iter().copied().filter(|&x| x >= 0).collect();
    for g in groups {
        for t in g.iter().flatten() {
            if !placed.contains(&(*t as i16)) {
                if let Some(free) = layout.iter().position(|&x| x < 0) {
                    layout[free] = *t as i16;
                }
            }
        }
    }
    layout
}

fn auto_layout(s: &mut Solver, rack: &[u8], okey: u8, pairs: bool) -> [i16; SLOTS] {
    let mut pool: Vec<u8> = rack.to_vec();
    pool.sort_by_key(|&id| sort_key(id, okey));
    let mut jokers: Vec<u8> = pool.iter().copied().filter(|&id| eff(id, okey).is_none()).collect();
    pool.retain(|&id| eff(id, okey).is_some());
    let take = |pool: &mut Vec<u8>, k: u8| -> Option<u8> {
        let i = pool.iter().position(|&id| eff(id, okey) == Some(k))?;
        Some(pool.remove(i))
    };
    let mut groups: Vec<Vec<Option<u8>>> = Vec::new();
    if pairs {
        let h = Hc::of(&pool, okey);
        for k in 0..52u8 {
            if h.c[k as usize] >= 2 {
                let a = take(&mut pool, k);
                let b = take(&mut pool, k);
                groups.push(vec![a, b]);
            }
        }
        while let Some(j) = jokers.pop() {
            if pool.is_empty() {
                groups.push(vec![Some(j)]);
            } else {
                let t = pool.remove(0);
                groups.push(vec![Some(t), Some(j)]);
            }
        }
    } else {
        let h = Hc::of(&pool, okey);
        s.set_dead(None);
        let (_, gs) = s.groups(&h.c);
        let mut real: Vec<(Grp, Vec<Option<u8>>)> = Vec::new();
        for g in gs.iter().filter(|g| g.size() >= 2) {
            let seq: Vec<Option<u8>> = match *g {
                Grp::Set { .. } => g.kinds().into_iter().map(|k| take(&mut pool, k)).collect(),
                Grp::Run { col, start, mask } => {
                    let end = 15 - mask.leading_zeros() as u8;
                    (start..=end)
                        .map(|q| if mask >> q & 1 == 1 { take(&mut pool, col * 13 + q % 13) } else { None })
                        .collect()
                }
                _ => vec![],
            };
            real.push((*g, seq));
        }
        // Okeys fill the gaps of the most complete groups first.
        real.sort_by_key(|(g, _)| g.target() - g.size());
        for (g, seq) in real.iter_mut() {
            let need = g.target() as usize;
            for slot in seq.iter_mut() {
                if slot.is_none() {
                    if let Some(j) = jokers.pop() {
                        *slot = Some(j);
                    }
                }
            }
            while seq.len() < need {
                match jokers.pop() {
                    Some(j) => seq.push(Some(j)),
                    None => break,
                }
            }
        }
        // Gaps inside a run stay empty only if they fit; drop leading/trailing Nones.
        for (_, seq) in real {
            groups.push(seq);
        }
        if !jokers.is_empty() {
            groups.push(jokers.iter().map(|&j| Some(j)).collect());
        }
    }
    // Leftovers by colour.
    let mut by_col: Vec<Vec<Option<u8>>> = vec![Vec::new(); 4];
    for id in pool {
        let k = eff(id, okey).unwrap_or(0);
        by_col[(k / 13) as usize].push(Some(id));
    }
    for c in by_col.into_iter().filter(|c| !c.is_empty()) {
        groups.push(c);
    }
    // If gaps make it overflow, drop the inner None gaps.
    let total: usize = groups.iter().map(|g| g.len() + 1).sum();
    if total > SLOTS + 1 {
        for g in groups.iter_mut() {
            g.retain(|x| x.is_some());
        }
    }
    pack_layout(&groups)
}

pub(crate) fn sorted_layout(rack: &[u8], okey: u8) -> [i16; SLOTS] {
    let mut by_col: Vec<Vec<Option<u8>>> = vec![Vec::new(); 5];
    let mut ids = rack.to_vec();
    ids.sort_by_key(|&id| sort_key(id, okey));
    for id in ids {
        match eff(id, okey) {
            Some(k) => by_col[(k / 13) as usize].push(Some(id)),
            None => by_col[4].push(Some(id)),
        }
    }
    let groups: Vec<Vec<Option<u8>>> = by_col.into_iter().filter(|c| !c.is_empty()).collect();
    pack_layout(&groups)
}

// =================================================================================================
// Session

#[derive(Clone, Debug)]
struct Last {
    serial: u32,
    seat: usize,
    kind: &'static str,
    tile: Option<u8>,
    from: Option<usize>,
    reason: String,
    text: String,
}

#[derive(Clone, Debug)]
struct HandResult {
    winner: Option<usize>,
    pairs: bool,
    okey_finish: bool,
    deltas: [i32; 4],
    text: String,
    finish_tile: Option<u8>,
    groups: Vec<Vec<u8>>,
}

pub struct Okey {
    level: Level,
    seed: u64,
    rng: Rng,
    solver: Solver,
    scores: [i32; 4],
    hand_no: u32,
    hand: Hand,
    hand_end: bool,
    result: Option<HandResult>,
    match_over: bool,
    final_status: Option<&'static str>,
    layout: [i16; SLOTS],
    last: Option<Last>,
    log: Vec<Last>,
    serial: u32,
    reasons: [String; 4],
    hint: Option<(String, Option<u8>, String)>,
    version: u64,
    /// Strategy per seat (seat 0 is only used by tests / self-play).
    seat_levels: [Level; 4],
    wins: [u32; 4],
}

pub fn create(_level: u32, mode: &str) -> Result<Box<dyn Session>, String> {
    if let Some(m) = mode.strip_prefix("101_") {
        return super::okey101::create(m);
    }
    let level = match mode {
        "easy" => Level::Easy,
        "normal" => Level::Normal,
        "hard" => Level::Hard,
        "impossible" => Level::Impossible,
        _ => Level::Normal,
    };
    Ok(Box::new(Okey::new(level, time_seed())))
}

impl Okey {
    pub fn new(level: Level, seed: u64) -> Okey {
        Okey::with_levels(level, [Level::Hard, level, level, level], seed)
    }

    pub fn with_levels(level: Level, seat_levels: [Level; 4], seed: u64) -> Okey {
        let mut rng = Rng::new(seed);
        let starter = rng.below(4);
        let hand = Hand::deal(&mut rng, starter);
        let mut g = Okey {
            level,
            seed,
            rng,
            solver: Solver::new(),
            scores: [START_SCORE; 4],
            hand_no: 1,
            hand,
            hand_end: false,
            result: None,
            match_over: false,
            final_status: None,
            layout: [-1; SLOTS],
            last: None,
            log: Vec::new(),
            serial: 0,
            reasons: Default::default(),
            hint: None,
            version: 0,
            seat_levels,
            wins: [0; 4],
        };
        g.after_deal();
        g
    }

    fn after_deal(&mut self) {
        self.layout = sorted_layout(&self.hand.racks[0], self.hand.okey);
        self.reasons = Default::default();
        self.hint = None;
        let ind = tname(self.hand.indicator, self.hand.okey);
        let ok = kname(self.hand.okey);
        self.push_log(self.hand.starter, "deal", None, None, format!("Gösterge {ind}: okey {ok}"), format!(
            "{} başlıyor (15 taş)",
            if self.hand.starter == 0 { "Sen".to_string() } else { NAMES[self.hand.starter].to_string() }
        ));
        if let Some(s) = self.hand.shown {
            for o in 0..4 {
                if o != s {
                    self.scores[o] -= 1;
                }
            }
            let who = if s == 0 { "Göstergeyi sen gösterdin".to_string() } else { format!("{} göstergeyi gösterdi", NAMES[s]) };
            self.push_log(s, "show", Some(if self.hand.indicator < 52 { self.hand.indicator + 52 } else { self.hand.indicator - 52 }), None,
                format!("{who}: diğerleri 1 puan kaybetti"), "Göstergenin eşi elindeydi".into());
        }
    }

    fn push_log(&mut self, seat: usize, kind: &'static str, tile: Option<u8>, from: Option<usize>, text: String, reason: String) {
        self.serial += 1;
        let l = Last { serial: self.serial, seat, kind, tile, from, reason: reason.clone(), text };
        if !reason.is_empty() && seat != 0 {
            self.reasons[seat] = reason;
        }
        self.log.push(l.clone());
        if self.log.len() > 40 {
            self.log.remove(0);
        }
        self.last = Some(l);
    }

    fn playing(&self) -> bool {
        self.final_status.is_none() && !self.hand_end
    }

    fn check_turn(&self, seat: usize) -> Result<(), String> {
        if self.final_status.is_some() {
            return Err("Maç bitti".into());
        }
        if self.hand_end {
            return Err("El bitti — sonraki ele geç".into());
        }
        if self.hand.turn != seat {
            return Err("Sıra sende değil".into());
        }
        Ok(())
    }

    fn place_in_layout(&mut self, id: u8, slot: Option<usize>) {
        if let Some(s) = slot {
            if s < SLOTS && self.layout[s] < 0 {
                self.layout[s] = id as i16;
                return;
            }
        }
        // First free slot after the last tile of the bottom row, else anywhere.
        let last = (ROW..SLOTS).rev().find(|&i| self.layout[i] >= 0).unwrap_or(ROW - 1);
        let free = (last + 1..SLOTS).find(|&i| self.layout[i] < 0).or_else(|| (0..SLOTS).find(|&i| self.layout[i] < 0));
        if let Some(f) = free {
            self.layout[f] = id as i16;
        }
    }

    fn draw(&mut self, seat: usize, take: bool, slot: Option<usize>, reason: String) -> Result<(), String> {
        self.check_turn(seat)?;
        if !self.hand.draw_stage {
            return Err("Önce bir taş at".into());
        }
        let okey = self.hand.okey;
        let (tile, from) = if take {
            let l = Hand::left(seat);
            let t = self.hand.discards[l].pop().ok_or("Alınacak taş yok")?;
            self.hand.taken[seat].push(t);
            (t, Some(l))
        } else {
            (self.hand.pile.pop().ok_or("Ortada taş kalmadı")?, None)
        };
        self.hand.racks[seat].push(tile);
        self.hand.draw_stage = false;
        if seat == 0 {
            self.place_in_layout(tile, slot);
        }
        let who = if seat == 0 { "Sen".to_string() } else { NAMES[seat].to_string() };
        let text = if take {
            format!("{who} {} {}", tacc(tile, okey), if seat == 0 { "aldın" } else { "aldı" })
        } else if seat == 0 {
            format!("Ortadan {} çektin", tname(tile, okey))
        } else {
            format!("{who} ortadan çekti")
        };
        self.push_log(seat, if take { "take" } else { "pile" }, Some(tile), from, text, reason);
        Ok(())
    }

    fn remove_tile(&mut self, seat: usize, id: u8) -> Result<(), String> {
        let r = &mut self.hand.racks[seat];
        let i = r.iter().position(|&x| x == id).ok_or("Bu taş elinde değil")?;
        r.remove(i);
        if seat == 0 {
            for s in self.layout.iter_mut() {
                if *s == id as i16 {
                    *s = -1;
                }
            }
        }
        Ok(())
    }

    fn discard(&mut self, seat: usize, id: u8, reason: String) -> Result<(), String> {
        self.check_turn(seat)?;
        if self.hand.draw_stage {
            return Err("Önce bir taş çek".into());
        }
        if !self.hand.racks[seat].contains(&id) {
            return Err("Bu taş elinde değil".into());
        }
        self.remove_tile(seat, id)?;
        let okey = self.hand.okey;
        self.hand.discards[seat].push(id);
        self.hand.turns += 1;
        let who = if seat == 0 { "Sen".to_string() } else { NAMES[seat].to_string() };
        let text = format!("{who} {} {}", tacc(id, okey), if seat == 0 { "attın" } else { "attı" });
        self.push_log(seat, "discard", Some(id), None, text, reason);
        if self.hand.pile.is_empty() {
            self.end_hand(None, false, false, None);
            return Ok(());
        }
        self.hand.turn = Hand::right(seat);
        self.hand.draw_stage = true;
        Ok(())
    }

    fn finish(&mut self, seat: usize, id: u8, reason: String) -> Result<(), String> {
        self.check_turn(seat)?;
        if self.hand.draw_stage {
            return Err("Önce bir taş çek".into());
        }
        let rack = &self.hand.racks[seat];
        if !rack.contains(&id) {
            return Err("Bu taş elinde değil".into());
        }
        let rest = without(rack, id);
        let okey = self.hand.okey;
        let Some(pairs) = winning(&rest, okey) else {
            return Err("Kalan 14 taş per oluşturmuyor".into());
        };
        let okd = eff(id, okey).is_none();
        self.remove_tile(seat, id)?;
        let who = if seat == 0 { "Sen".to_string() } else { NAMES[seat].to_string() };
        let text = format!("{who} {} atarak {}", tacc(id, okey), if seat == 0 { "bitirdin!" } else { "bitirdi!" });
        self.push_log(seat, "finish", Some(id), None, text, reason);
        self.end_hand(Some(seat), pairs, okd, Some(id));
        Ok(())
    }

    fn end_hand(&mut self, winner: Option<usize>, pairs: bool, okd: bool, tile: Option<u8>) {
        let mut deltas = [0i32; 4];
        let okey = self.hand.okey;
        let mut groups = Vec::new();
        let text;
        if let Some(w) = winner {
            let mult = (if pairs { 2 } else { 1 }) * (if okd { 2 } else { 1 });
            for o in 0..4 {
                if o != w {
                    deltas[o] = -2 * mult;
                    self.scores[o] -= 2 * mult;
                }
            }
            self.wins[w] += 1;
            let how = match (pairs, okd) {
                (true, true) => " çiftle ve okey atarak",
                (true, false) => " çiftle",
                (false, true) => " okey atarak",
                _ => "",
            };
            let who = if w == 0 { "Sen".to_string() } else { NAMES[w].to_string() };
            let verb = if w == 0 { "bitirdin" } else { "bitirdi" };
            let others = if w == 0 { "Rakipler" } else { "Diğerleri" };
            text = format!("{who}{how} {verb}! {others} {}'er puan kaybetti", 2 * mult);
            // The winner's 14 tiles as melds for display.
            let rack = self.hand.racks[w].clone();
            let lay = auto_layout(&mut self.solver, &rack, okey, pairs);
            for row in 0..2 {
                let mut cur = Vec::new();
                for i in 0..ROW {
                    let v = lay[row * ROW + i];
                    if v >= 0 {
                        cur.push(v as u8);
                    } else if !cur.is_empty() {
                        groups.push(std::mem::take(&mut cur));
                    }
                }
                if !cur.is_empty() {
                    groups.push(cur);
                }
            }
        } else {
            text = "Ortada taş kalmadı: el berabere".into();
        }
        self.hand_end = true;
        self.hint = None;
        self.result = Some(HandResult { winner, pairs, okey_finish: okd, deltas, text, finish_tile: tile, groups });
        self.match_over = self.scores.iter().any(|&s| s <= 0) || self.hand_no >= MAX_HANDS;
    }

    fn next_hand(&mut self) -> Result<(), String> {
        if !self.hand_end || self.final_status.is_some() {
            return Err("El sürüyor".into());
        }
        if self.match_over {
            let mine = self.scores[0];
            let best_other = self.scores[1..].iter().copied().max().unwrap_or(0);
            self.final_status = Some(if mine > best_other {
                "won"
            } else if mine == best_other {
                "draw"
            } else {
                "lost"
            });
            return Ok(());
        }
        self.hand_no += 1;
        let starter = (self.hand.starter + 1) % 4;
        self.hand = Hand::deal(&mut self.rng, starter);
        self.hand_end = false;
        self.result = None;
        self.after_deal();
        Ok(())
    }

    /// One AI step for `seat` with its strategy: a draw or a discard.
    pub fn ai_step(&mut self, seat: usize) -> Result<(), String> {
        self.check_turn(seat)?;
        let lvl = self.seat_levels[seat];
        // Omniscient seats block every neighbour that is not omniscient itself (in play: you).
        let r = Hand::right(seat);
        let block = r == 0 || self.seat_levels[r] != Level::Impossible;
        if self.hand.draw_stage {
            let ch = if lvl == Level::Impossible {
                omni_draw(&self.hand, seat, &mut self.solver, block)
            } else {
                let info = self.hand.info(seat);
                info_draw(&info, lvl, &mut self.solver, &mut self.rng, false)
            };
            let take = ch.take && self.hand.offer(seat).is_some();
            if !take && self.hand.pile.is_empty() {
                return Err("Ortada taş kalmadı".into());
            }
            self.draw(seat, take, None, ch.reason)
        } else {
            let ch = if lvl == Level::Impossible {
                omni_discard(&self.hand, seat, &mut self.solver, block)
            } else {
                let info = self.hand.info(seat);
                info_discard(&info, lvl, &mut self.solver, &mut self.rng, false)
            };
            if ch.finish {
                self.finish(seat, ch.id, ch.reason)
            } else {
                self.discard(seat, ch.id, ch.reason)
            }
        }
    }

    fn compute_hint(&mut self) -> Result<(), String> {
        self.check_turn(0)?;
        let info = self.hand.info(0);
        let mut rng = Rng::new(self.seed ^ self.serial as u64);
        if self.hand.draw_stage {
            let ch = info_draw(&info, Level::Hard, &mut self.solver, &mut rng, true);
            let tile = if ch.take { self.hand.offer(0) } else { None };
            self.hint = Some((if ch.take { "take".into() } else { "pile".into() }, tile, ch.reason));
        } else {
            let ch = info_discard(&info, Level::Hard, &mut self.solver, &mut rng, true);
            self.hint = Some((if ch.finish { "finish".into() } else { "discard".into() }, Some(ch.id), ch.reason));
        }
        Ok(())
    }

    fn arrange(&mut self, a: &Value) -> Result<(), String> {
        if self.final_status.is_some() {
            return Err("Maç bitti".into());
        }
        let arr = a.as_array().ok_or("Geçersiz dizilim")?;
        if arr.len() > SLOTS {
            return Err("Geçersiz dizilim".into());
        }
        let mut lay = [-1i16; SLOTS];
        let mut seen = Vec::new();
        for (i, v) in arr.iter().enumerate() {
            let id = v.as_i64().unwrap_or(-1);
            if id < 0 {
                continue;
            }
            if id >= N_TILES as i64 {
                return Err("Geçersiz dizilim".into());
            }
            let id = id as u8;
            if seen.contains(&id) || !self.hand.racks[0].contains(&id) {
                return Err("Geçersiz dizilim".into());
            }
            seen.push(id);
            lay[i] = id as i16;
        }
        if seen.len() != self.hand.racks[0].len() {
            return Err("Geçersiz dizilim".into());
        }
        self.layout = lay;
        Ok(())
    }

    fn act_inner(&mut self, a: &Value) -> Result<(), String> {
        if a["ai"].as_bool() == Some(true) {
            if !self.playing() || self.hand.turn == 0 {
                return Err("Sıra rakipte değil".into());
            }
            let seat = self.hand.turn;
            return self.ai_step(seat);
        }
        if a["hint"].as_bool() == Some(true) {
            return self.compute_hint();
        }
        if a["next"].as_bool() == Some(true) {
            return self.next_hand();
        }
        if let Some(arr) = a.get("arrange") {
            return self.arrange(arr);
        }
        if let Some(m) = a["auto_arrange"].as_str() {
            if self.final_status.is_some() || self.hand_end {
                return Err("El bitti".into());
            }
            let rack = self.hand.racks[0].clone();
            self.layout = auto_layout(&mut self.solver, &rack, self.hand.okey, m == "pairs");
            return Ok(());
        }
        if let Some(src) = a["draw"].as_str() {
            let slot = a["slot"].as_u64().map(|x| x as usize);
            let take = match src {
                "pile" => false,
                "discard" => true,
                _ => return Err("Bilinmeyen hamle".into()),
            };
            self.draw(0, take, slot, String::new())?;
            self.hint = None;
            return Ok(());
        }
        if let Some(id) = a["discard"].as_u64() {
            if id >= N_TILES as u64 {
                return Err("Bu taş elinde değil".into());
            }
            self.discard(0, id as u8, String::new())?;
            self.hint = None;
            return Ok(());
        }
        if let Some(id) = a["finish"].as_u64() {
            if id >= N_TILES as u64 {
                return Err("Bu taş elinde değil".into());
            }
            self.finish(0, id as u8, String::new())?;
            self.hint = None;
            return Ok(());
        }
        Err("Bilinmeyen hamle".into())
    }
}

fn last_json(l: &Last) -> Value {
    json!({
        "serial": l.serial,
        "seat": l.seat,
        "kind": l.kind,
        "tile": l.tile,
        "from": l.from,
        "reason": l.reason,
        "text": l.text,
    })
}

impl Session for Okey {
    fn state(&self) -> Value {
        let h = &self.hand;
        let okey = h.okey;
        let playing = self.playing();
        let status = self.final_status.unwrap_or("playing");
        let seats: Vec<Value> = (0..4)
            .map(|s| {
                let mut tiles = h.racks[s].clone();
                tiles.sort_by_key(|&id| sort_key(id, okey));
                json!({
                    "name": NAMES[s],
                    "where": WHERE[s],
                    "score": self.scores[s],
                    "count": h.racks[s].len(),
                    "tiles": tiles,
                    "discards": h.discards[s],
                    "taken": h.taken[s],
                    "reason": self.reasons[s],
                    "wins": self.wins[s],
                })
            })
            .collect();
        let melds: Vec<Value> =
            layout_melds(&self.layout, okey).into_iter().map(|(slots, kind)| json!({"slots": slots, "kind": kind})).collect();
        let pile: Vec<u8> = h.pile.iter().rev().copied().collect();
        let your_turn = playing && h.turn == 0;
        let result = self.result.as_ref().map(|r| {
            json!({
                "winner": r.winner,
                "pairs": r.pairs,
                "okey_finish": r.okey_finish,
                "deltas": r.deltas,
                "text": r.text,
                "finish_tile": r.finish_tile,
                "groups": r.groups,
                "scores": self.scores,
            })
        });
        let summary = if self.match_over || self.final_status.is_some() {
            Some(format!(
                "Puanın {} · {} {} · {} {} · {} {}",
                self.scores[0], NAMES[1], self.scores[1], NAMES[2], self.scores[2], NAMES[3], self.scores[3]
            ))
        } else {
            None
        };
        json!({
            "status": status,
            "stars": 0,
            "title": format!("El {}/{}", self.hand_no, MAX_HANDS),
            "goal": "Taşlarını per diz, ilk sen bitir",
            "summary": summary,
            "mode": self.level.id(),
            "mode_label": self.level.label(),
            "seed": self.seed.to_string(),
            "hand_no": self.hand_no,
            "max_hands": MAX_HANDS,
            "phase": if self.hand_end || self.final_status.is_some() { "hand_end" } else { "play" },
            "turn": if h.turn == 0 { "you" } else { "ai" },
            "seat": h.turn,
            "stage": if h.draw_stage { "draw" } else { "discard" },
            "ai_pending": playing && h.turn != 0,
            "starter": h.starter,
            "seats": seats,
            "layout": self.layout.to_vec(),
            "melds": melds,
            "indicator": h.indicator,
            "okey": {"kind": okey, "color": okey / 13, "number": okey % 13 + 1},
            "pile_count": h.pile.len(),
            "pile": pile,
            "can_take": your_turn && h.draw_stage && h.offer(0).is_some(),
            "take_tile": h.offer(0),
            "last": self.last.as_ref().map(last_json),
            "log": self.log.iter().rev().take(12).map(last_json).collect::<Vec<_>>(),
            "hint": self.hint.as_ref().map(|(k, t, txt)| json!({"kind": k, "tile": t, "text": txt})),
            "result": result,
            "match_over": self.match_over,
            "version": self.version,
        })
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        let r = self.act_inner(a);
        if r.is_ok() {
            self.version += 1;
        }
        r
    }
}

// =================================================================================================

#[cfg(test)]
mod tests {
    use super::*;

    /// Tile id from colour (0..4), number (1..13), copy (0/1).
    fn t(c: u8, n: u8, copy: u8) -> u8 {
        copy * 52 + c * 13 + (n - 1)
    }
    const R: u8 = 0;
    const K: u8 = 1;
    const B: u8 = 2;
    const Y: u8 = 3;

    /// Okey = yellow 13 in these tests (indicator yellow 12); no tile below uses it unless stated.
    const OKEY: u8 = 3 * 13 + 12;

    #[test]
    fn okey_tile_set_and_okey_determination() {
        let mut rng = Rng::new(5);
        let h = Hand::deal(&mut rng, 2);
        let mut all: Vec<u8> = h.racks.iter().flatten().copied().collect();
        all.extend(&h.pile);
        all.push(h.indicator);
        all.sort();
        assert_eq!(all, (0..106).collect::<Vec<u8>>());
        assert_eq!(h.racks[2].len(), 15);
        assert_eq!(h.racks[0].len(), 14);
        assert_eq!(h.pile.len(), 48);
        assert!(!is_false(h.indicator));
        // Next number, same colour; 13 → 1.
        assert_eq!(okey_of(t(R, 5, 0)), R * 13 + 5); // red 6
        assert_eq!(okey_of(t(B, 13, 1)), B * 13); // blue 13 → blue 1
        assert_eq!(okey_of(t(Y, 12, 0)), OKEY);
        // Real okey tiles are wild; false jokers play as the okey kind.
        assert_eq!(eff(t(Y, 13, 0), OKEY), None);
        assert_eq!(eff(t(Y, 13, 1), OKEY), None);
        assert_eq!(eff(104, OKEY), Some(OKEY));
        assert_eq!(eff(105, OKEY), Some(OKEY));
        assert_eq!(eff(t(K, 7, 1), OKEY), Some(K * 13 + 6));
    }

    #[test]
    fn meld_validation() {
        // Runs + sets.
        let hand = vec![
            t(R, 1, 0), t(R, 2, 0), t(R, 3, 0), // run
            t(K, 7, 0), t(B, 7, 0), t(Y, 7, 0), t(R, 7, 0), // 4-set
            t(B, 10, 0), t(B, 11, 0), t(B, 12, 0), t(B, 13, 0), // run of 4
            t(K, 4, 0), t(B, 4, 1), t(Y, 4, 1), // set
        ];
        assert_eq!(winning(&hand, OKEY), Some(false));
        // 12-13-1 is a run; 13-1-2 is not.
        let mut h2 = hand.clone();
        h2.splice(7..11, [t(B, 12, 0), t(B, 13, 0), t(B, 1, 0), t(K, 1, 1)]);
        assert_eq!(winning(&h2, OKEY), None); // 12-13-1 + stray black 1 → not complete
        let mut h3 = hand.clone();
        h3.splice(7..11, [t(B, 11, 0), t(B, 12, 0), t(B, 13, 0), t(B, 1, 0)]);
        assert_eq!(winning(&h3, OKEY), Some(false));
        let mut h4 = hand.clone();
        h4.splice(7..11, [t(B, 13, 0), t(B, 1, 0), t(B, 2, 0), t(B, 3, 0)]);
        assert_eq!(winning(&h4, OKEY), None);
        // A set may not repeat a colour.
        let mut h5 = hand.clone();
        h5.splice(11..14, [t(K, 4, 0), t(K, 4, 1), t(Y, 4, 1)]);
        assert_eq!(winning(&h5, OKEY), None);
        // Wrong length.
        assert_eq!(winning(&hand[..13], OKEY), None);
        // Okey substitution: replace red 2 by an okey (yellow 13), and blue 12 by the other okey.
        let mut h6 = hand.clone();
        h6[1] = t(Y, 13, 0);
        h6[9] = t(Y, 13, 1);
        assert_eq!(winning(&h6, OKEY), Some(false));
        // False joker plays as yellow 13: completes blue/black/red 13 set? Use it in a run 11-12-13 yellow.
        let h7 = vec![
            t(Y, 11, 0), t(Y, 12, 0), 104, // yellow 11-12-(13)
            t(K, 7, 0), t(B, 7, 0), t(Y, 7, 0),
            t(B, 9, 0), t(B, 10, 0), t(B, 11, 0), t(B, 12, 0),
            t(K, 4, 0), t(B, 4, 1), t(Y, 4, 1), t(R, 4, 1),
        ];
        assert_eq!(winning(&h7, OKEY), Some(false));
        // The false joker is not wild: as a red 2 substitute it fails.
        let mut h8 = hand.clone();
        h8[1] = 104;
        assert_eq!(winning(&h8, OKEY), None);
    }

    #[test]
    fn pairs_validation() {
        let mut hand = Vec::new();
        for (c, n) in [(R, 1), (K, 5), (B, 9), (Y, 2), (R, 12), (K, 13)] {
            hand.push(t(c, n, 0));
            hand.push(t(c, n, 1));
        }
        hand.push(t(B, 3, 0));
        hand.push(t(Y, 13, 0)); // okey pairs with blue 3
        assert_eq!(winning(&hand, OKEY), Some(true));
        // Two false jokers are a pair too.
        let mut h2 = hand.clone();
        h2[12] = 104;
        h2[13] = 105;
        assert_eq!(winning(&h2, OKEY), Some(true));
        let mut h3 = hand.clone();
        h3[13] = t(R, 3, 0);
        assert_eq!(winning(&h3, OKEY), None);
    }

    #[test]
    fn solver_matches_exact_check_on_random_hands() {
        let mut rng = Rng::new(99);
        let mut s = Solver::new();
        let mut wins = 0;
        for trial in 0..3000 {
            // Bias towards winning-ish hands: build some melds then fill.
            let mut ids: Vec<u8> = (0..106).collect();
            rng.shuffle(&mut ids);
            let okey = rng.below(52) as u8;
            let hand: Vec<u8> = if trial % 2 == 0 {
                ids[..14].to_vec()
            } else {
                // Construct from melds.
                let mut v = Vec::new();
                while v.len() < 14 {
                    let c = rng.below(4) as u8;
                    let n = 1 + rng.below(11) as u8;
                    let len = (3 + rng.below(3)).min(14 - v.len());
                    if len < 3 {
                        v.push(ids[v.len() + 20]);
                        continue;
                    }
                    if rng.chance(0.5) {
                        for i in 0..len as u8 {
                            if n + i <= 13 {
                                v.push(t(c, n + i, rng.below(2) as u8));
                            }
                        }
                    } else {
                        for cc in 0..len.min(4) as u8 {
                            v.push(t((c + cc) % 4, n, rng.below(2) as u8));
                        }
                    }
                    v.sort();
                    v.dedup();
                }
                v.truncate(14);
                v
            };
            let h = Hc::of(&hand, okey);
            let dp_win = s.def_runs(&h) == 0;
            let ex = melds_exact(h.c, h.j);
            assert_eq!(dp_win, ex, "hand {hand:?} okey {okey}");
            if ex {
                wins += 1;
            }
        }
        assert!(wins > 100, "too few winning test hands: {wins}");
    }

    #[test]
    fn deficiency_values() {
        let mut s = Solver::new();
        // One tile away: 4 complete melds = 11 tiles + 3 tiles needing one.
        let hand = vec![
            t(R, 1, 0), t(R, 2, 0), t(R, 3, 0),
            t(K, 7, 0), t(B, 7, 0), t(Y, 7, 0), t(R, 7, 0),
            t(B, 10, 0), t(B, 11, 0), t(B, 12, 0),
            t(K, 4, 0), t(B, 4, 1), t(Y, 1, 1), t(K, 9, 0),
        ];
        let h = Hc::of(&hand, OKEY);
        assert_eq!(s.def_runs(&h), 2);
        // With an okey the deficiency drops by one.
        let mut h2 = hand.clone();
        h2[13] = t(Y, 13, 0);
        assert_eq!(s.def_runs(&Hc::of(&h2, OKEY)), 1);
        // Pairs: six pairs + two singles → 1.
        let mut ph = Vec::new();
        for (c, n) in [(R, 1), (K, 5), (B, 9), (Y, 2), (R, 12), (K, 13)] {
            ph.push(t(c, n, 0));
            ph.push(t(c, n, 1));
        }
        ph.push(t(B, 3, 0));
        ph.push(t(R, 3, 0));
        assert_eq!(def_pairs(&Hc::of(&ph, OKEY), None), 1);
    }

    fn sess(level: Level, seed: u64) -> Okey {
        Okey::new(level, seed)
    }

    /// Drive the session until it is the player's turn (or the hand ends).
    fn run_ai(g: &mut Okey) {
        while g.playing() && g.hand.turn != 0 {
            g.act(&json!({"ai": true})).unwrap();
        }
    }

    #[test]
    fn illegal_actions_are_rejected_unchanged() {
        let mut g = sess(Level::Normal, 7);
        run_ai(&mut g);
        assert!(g.playing());
        let before = g.state();
        let foreign = (0..106u8).find(|id| !g.hand.racks[0].contains(id) && *id != g.hand.indicator).unwrap();
        let mut bad = vec![
            json!({"ai": true}),
            json!({"next": true}),
            json!({"discard": foreign}),
            json!({"finish": foreign}),
            json!({"arrange": [1, 2, 3]}),
            json!({"auto_arrange": 5}),
            json!({"draw": "nowhere"}),
            json!({"bogus": 1}),
        ];
        if g.hand.draw_stage {
            bad.push(json!({"discard": g.hand.racks[0][0]}));
        } else {
            bad.push(json!({"draw": "pile"}));
        }
        for a in bad {
            assert!(g.act(&a).is_err(), "{a} should fail");
            assert_eq!(g.state(), before, "{a} changed state");
        }
        // Draw, then a non-winning finish is rejected unchanged.
        if g.hand.draw_stage {
            g.act(&json!({"draw": "pile"})).unwrap();
        }
        let rack = g.hand.racks[0].clone();
        let st = g.state();
        let mut s = Solver::new();
        if find_finish(&mut s, &rack, g.hand.okey).is_none() {
            assert!(g.act(&json!({"finish": rack[0]})).is_err());
            assert_eq!(g.state(), st);
        }
        // Arrange with a permutation is accepted; with a duplicate is rejected.
        let mut lay: Vec<i64> = vec![-1; SLOTS];
        for (i, &id) in rack.iter().enumerate() {
            lay[SLOTS - 1 - i] = id as i64;
        }
        assert!(g.act(&json!({"arrange": lay})).is_ok());
        let st = g.state();
        let mut dup = lay.clone();
        dup[0] = rack[0] as i64;
        assert!(g.act(&json!({"arrange": dup})).is_err());
        assert_eq!(g.state(), st);
        assert!(g.act(&json!({"auto_arrange": "runs"})).is_ok());
        let lay2: Vec<i16> = g.layout.to_vec();
        let mut ids: Vec<u8> = lay2.iter().filter(|&&x| x >= 0).map(|&x| x as u8).collect();
        ids.sort();
        let mut r2 = rack.clone();
        r2.sort();
        assert_eq!(ids, r2);
        assert!(g.act(&json!({"auto_arrange": "pairs"})).is_ok());
    }

    #[test]
    fn finishing_and_scoring() {
        let mut g = sess(Level::Normal, 11);
        // Force a known winning rack on seat 0 at its discard stage.
        let okey = g.hand.okey;
        let oc = okey / 13;
        // Pick tiles avoiding the okey kind's colour/number collisions: build pairs of non-okey kinds.
        let mut rack = Vec::new();
        let mut k = 0u8;
        while rack.len() < 14 {
            if k != okey {
                rack.push(k);
                rack.push(k + 52);
            }
            k += 1;
        }
        let extra = (0..52u8).find(|&x| x != okey && !rack.contains(&x)).unwrap();
        rack.push(extra);
        let _ = oc;
        // Reassign tiles: remove these ids from wherever they are.
        for s in 0..4 {
            g.hand.racks[s].retain(|x| !rack.contains(x));
        }
        g.hand.pile.retain(|x| !rack.contains(x));
        g.hand.racks[0] = rack.clone();
        g.hand.turn = 0;
        g.hand.draw_stage = false;
        let before = g.scores;
        g.act(&json!({"finish": extra})).unwrap();
        assert!(g.hand_end);
        let r = g.result.clone().unwrap();
        assert_eq!(r.winner, Some(0));
        assert!(r.pairs);
        for o in 1..4 {
            assert_eq!(g.scores[o], before[o] - 4, "pairs finish costs 4");
        }
        assert_eq!(g.scores[0], before[0]);
        // Next hand deals again.
        g.act(&json!({"next": true})).unwrap();
        assert!(g.playing());
        assert_eq!(g.hand_no, 2);
    }

    #[test]
    fn okey_finish_doubles() {
        let mut g = sess(Level::Normal, 12);
        let okey = g.hand.okey;
        let jok = okey; // physical copy 0 of the okey kind is wild
        // Melds of non-okey colour: pick a colour different from okey's.
        let c = (okey / 13 + 1) % 4;
        let c2 = (okey / 13 + 2) % 4;
        let mut rack: Vec<u8> = (1..=7).map(|n| t(c, n, 0)).collect();
        rack.extend((1..=7).map(|n| t(c2, n, 0)));
        rack.push(jok);
        for s in 0..4 {
            g.hand.racks[s].retain(|x| !rack.contains(x));
        }
        g.hand.pile.retain(|x| !rack.contains(x));
        g.hand.racks[0] = rack;
        g.hand.turn = 0;
        g.hand.draw_stage = false;
        let before = g.scores;
        g.act(&json!({"finish": jok})).unwrap();
        let r = g.result.clone().unwrap();
        assert!(r.okey_finish && !r.pairs);
        assert_eq!(g.scores[1], before[1] - 4);
    }

    #[test]
    fn gosterge_and_pile_out_draw() {
        // Find a seed where someone holds the indicator twin; scores reflect −1 for the others.
        for seed in 0..200u64 {
            let g = sess(Level::Easy, seed);
            if let Some(s) = g.hand.shown {
                for o in 0..4 {
                    assert_eq!(g.scores[o], if o == s { 20 } else { 19 });
                }
                break;
            }
        }
        // Empty pile after a discard → draw.
        let mut g = sess(Level::Easy, 3);
        let seat = g.hand.turn;
        g.hand.pile.clear();
        let id = g.hand.racks[seat][0];
        g.discard(seat, id, String::new()).unwrap();
        assert!(g.hand_end);
        assert_eq!(g.result.as_ref().unwrap().winner, None);
    }

    fn self_play(levels: [Level; 4], seed: u64) -> Okey {
        let mut g = Okey::with_levels(levels[1], levels, seed);
        let mut steps = 0;
        while g.final_status.is_none() {
            if g.hand_end {
                g.act(&json!({"next": true})).unwrap();
                continue;
            }
            let seat = g.hand.turn;
            g.ai_step(seat).unwrap();
            steps += 1;
            assert!(steps < 5000, "match did not terminate");
        }
        g
    }

    #[test]
    fn ai_only_matches_terminate_at_all_levels() {
        for (i, lvl) in [Level::Easy, Level::Normal, Level::Hard, Level::Impossible].into_iter().enumerate() {
            let g = self_play([lvl; 4], 100 + i as u64);
            assert!(g.final_status.is_some());
            let st = g.state();
            assert!(st["summary"].is_string());
        }
    }

    #[test]
    fn info_sets_hide_other_racks() {
        let g = sess(Level::Hard, 4);
        let info = g.hand.info(2);
        assert_eq!(info.rack, &g.hand.racks[2][..]);
        let un = Unseen::of_info(&info);
        // Unseen counts include tiles in other racks (they are hidden from seat 2).
        let other = g.hand.racks[1][0];
        if let Some(k) = eff(other, g.hand.okey) {
            assert!(un.k[k as usize] > 0 || g.hand.racks[2].iter().any(|&x| eff(x, g.hand.okey) == Some(k)));
        }
    }

    /// Easy/normal/hard decisions depend only on public data + own rack: reshuffling every hidden
    /// tile (other racks and the pile) never changes them.
    #[test]
    fn info_decisions_ignore_hidden_tiles() {
        let mut checked = 0;
        for seed in 0..12u64 {
            let mut g = sess(Level::Hard, 300 + seed);
            for _ in 0..(9 + seed as usize) {
                if !g.playing() {
                    break;
                }
                let seat = g.hand.turn;
                g.ai_step(seat).unwrap();
            }
            if !g.playing() {
                continue;
            }
            let seat = g.hand.turn;
            let mut h2 = g.hand.clone();
            let others: Vec<usize> = (0..4).filter(|&s| s != seat).collect();
            let mut pool: Vec<u8> = others.iter().flat_map(|&s| h2.racks[s].clone()).chain(h2.pile.clone()).collect();
            Rng::new(seed).shuffle(&mut pool);
            for &s in &others {
                let n = h2.racks[s].len();
                h2.racks[s] = pool.drain(..n).collect();
            }
            h2.pile = pool;
            let mut solver = Solver::new();
            for lvl in [Level::Easy, Level::Normal, Level::Hard] {
                if g.hand.draw_stage {
                    let a = info_draw(&g.hand.info(seat), lvl, &mut solver, &mut Rng::new(1), false);
                    let b = info_draw(&h2.info(seat), lvl, &mut solver, &mut Rng::new(1), false);
                    assert_eq!((a.take, a.reason), (b.take, b.reason));
                } else {
                    let a = info_discard(&g.hand.info(seat), lvl, &mut solver, &mut Rng::new(1), false);
                    let b = info_discard(&h2.info(seat), lvl, &mut solver, &mut Rng::new(1), false);
                    assert_eq!((a.id, a.reason), (b.id, b.reason));
                }
                checked += 1;
            }
        }
        assert!(checked >= 15);
    }

    #[test]
    fn impossible_beats_easy() {
        // Seats 1 and 3 impossible, 0 and 2 easy; count hand wins.
        let mut imp = 0;
        let mut easy = 0;
        for seed in 0..6u64 {
            let g = self_play([Level::Easy, Level::Impossible, Level::Easy, Level::Impossible], 500 + seed);
            imp += g.wins[1] + g.wins[3];
            easy += g.wins[0] + g.wins[2];
        }
        assert!(imp > 2 * easy, "impossible {imp} vs easy {easy}");
    }

    #[test]
    fn hard_beats_easy() {
        let mut hard = 0;
        let mut easy = 0;
        for seed in 0..6u64 {
            let g = self_play([Level::Easy, Level::Hard, Level::Easy, Level::Hard], 900 + seed);
            hard += g.wins[1] + g.wins[3];
            easy += g.wins[0] + g.wins[2];
        }
        assert!(hard >= easy, "hard {hard} vs easy {easy}");
    }

    #[test]
    fn reasons_are_present() {
        let mut g = sess(Level::Normal, 21);
        let mut n = 0;
        while g.playing() && n < 40 {
            if g.hand.turn == 0 {
                g.ai_step(0).unwrap();
            } else {
                g.act(&json!({"ai": true})).unwrap();
                let l = g.last.as_ref().unwrap();
                assert!(!l.reason.is_empty(), "{:?}", l);
            }
            n += 1;
        }
    }

    #[test]
    fn hint_and_layout_melds() {
        let mut g = sess(Level::Normal, 31);
        run_ai(&mut g);
        g.act(&json!({"hint": true})).unwrap();
        let st = g.state();
        assert!(st["hint"]["text"].as_str().is_some_and(|s| !s.is_empty()));
        // A hand-made layout: red 3-4-5 then a gap, then a 7 set.
        let okey = g.hand.okey;
        let mut lay = [-1i16; SLOTS];
        let ids = [t(R, 3, 0), t(R, 4, 0), t(R, 5, 0)];
        if ids.iter().all(|&i| eff(i, okey).is_some()) {
            for (i, &id) in ids.iter().enumerate() {
                lay[i] = id as i16;
            }
            let m = layout_melds(&lay, okey);
            assert_eq!(m.len(), 1);
            assert_eq!(m[0].1, "run");
        }
        assert_eq!(chunk_kind(&[Some(R * 13 + 11), Some(R * 13 + 12), Some(R * 13)]), Some("run"));
        assert_eq!(chunk_kind(&[Some(R * 13 + 12), Some(R * 13), Some(R * 13 + 1)]), None);
        assert_eq!(chunk_kind(&[Some(K * 13 + 6), None, Some(Y * 13 + 6)]), Some("set"));
    }

    #[test]
    #[ignore]
    fn timing_ai_decisions() {
        for lvl in [Level::Easy, Level::Normal, Level::Hard, Level::Impossible] {
            let mut worst = 0u128;
            let mut total = 0u128;
            let mut n = 0u128;
            for seed in 0..3u64 {
                let mut g = Okey::with_levels(lvl, [lvl; 4], 7000 + seed);
                let mut steps = 0;
                while g.final_status.is_none() && steps < 600 {
                    if g.hand_end {
                        g.act(&json!({"next": true})).unwrap();
                        continue;
                    }
                    let seat = g.hand.turn;
                    let t0 = std::time::Instant::now();
                    g.ai_step(seat).unwrap();
                    let us = t0.elapsed().as_micros();
                    worst = worst.max(us);
                    total += us;
                    n += 1;
                    steps += 1;
                }
            }
            println!("{lvl:?}: steps {n}, avg {} µs, worst {} µs", total / n.max(1), worst);
            assert!(worst < 100_000, "{lvl:?} worst {worst} µs");
        }
    }

    /// Single-hand win counts for level pairs (seats 0,2 vs 1,3). Run with `--ignored --nocapture`.
    #[test]
    #[ignore]
    fn strength_table() {
        use Level::*;
        let parse = |s: &str| match s {
            "easy" => Easy,
            "normal" => Normal,
            "hard" => Hard,
            _ => Impossible,
        };
        let pairs: Vec<(Level, Level)> = match std::env::var("OKEY_PAIRS") {
            Ok(v) => v
                .split(',')
                .filter_map(|p| p.split_once('-'))
                .map(|(a, b)| (parse(a), parse(b)))
                .collect(),
            Err(_) => vec![(Easy, Easy), (Easy, Normal), (Easy, Hard), (Normal, Hard), (Hard, Impossible), (Easy, Impossible)],
        };
        let n: u32 = std::env::var("OKEY_N").ok().and_then(|v| v.parse().ok()).unwrap_or(150);
        for pair in pairs {
            let mut wins = [0u32; 4];
            let mut draws = 0;
            let mut rng = Rng::new(42);
            let solo = std::env::var("OKEY_SOLO").is_ok();
            let levels = if solo { [pair.0, pair.1, pair.1, pair.1] } else { [pair.0, pair.1, pair.0, pair.1] };
            let mut turns = 0;
            for _ in 0..n {
                let mut g = Okey::with_levels(pair.1, levels, rng.next_u64());
                while g.playing() {
                    let seat = g.hand.turn;
                    g.ai_step(seat).unwrap();
                }
                turns += g.hand.turns;
                match g.result.as_ref().unwrap().winner {
                    Some(w) => wins[w] += 1,
                    None => draws += 1,
                }
            }
            println!(
                "{:?} vs {:?}: {} vs {} · draws {} · avg discards/hand {} · per seat {:?}",
                pair.0,
                pair.1,
                wins[0] + wins[2],
                wins[1] + wins[3],
                draws,
                turns / n,
                wins
            );
        }
    }
}
