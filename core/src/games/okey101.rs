//! 101 Okey — the kahvehane variant of Okey: the owner (seat 0) against three AI rivals. Hosted by
//! the `okey` game with the modes `101_easy | 101_normal | 101_hard | 101_impossible` (the classic
//! game keeps `easy | normal | hard | impossible`, see `okey.rs`, whose tile helpers this reuses).
//!
//! ## Rules implemented ("101 sabit")
//! - **Tiles** as in classic Okey: 106 tiles, the gösterge (indicator) is turned up, the **okey** is
//!   the next number of its colour and is wild (it stands for the tile it replaces, also in point
//!   totals); the two false jokers play as the okey's face value.
//! - **Deal**: 21 tiles each, the starter gets **22** and discards first; 20 tiles stay in the pile.
//!   Seats play counter-clockwise (0 you → 1 right → 2 across → 3 left); the starter rotates.
//! - **Turn**: draw from the pile, or take your left neighbour's latest discard — a taken tile must
//!   be **used in the same turn** (in your opening, a new meld or işleme). Taking is refused when
//!   that is impossible, and `{"untake":true}` gives it back (undoing this turn's melds) as long as it
//!   is still unused. Then you may lay melds / işle, and finally discard one tile.
//! - **Opening (elini açmak)**: in one turn lay runs/sets (per) whose face values sum to **≥ 101**
//!   (fixed — the next opener does not have to beat the previous one), or **≥ 5 pairs** (çift).
//!   Runs: same colour, consecutive, ≥ 3 (`12-13-1` is a run, the 1 counts 1 point; `13-1-2` is not).
//!   Sets: same number, different colours, 3–4 tiles. Pairs: two identical tiles (an okey pairs with
//!   anything).
//! - **After opening**: lay further melds (pair openers lay only pairs, meld openers only runs/sets)
//!   and **işle** — add tiles to any run/set on the table (either end of a run, a missing colour of a
//!   set). Pairs on the table take no tiles. The okey cannot be taken back from the table.
//! - **Finishing (bitmek)**: you finish by discarding your **last** tile; laying/işleme must always
//!   leave one tile in your rack.
//! - **Scoring per hand** (lower is better): the finisher writes **−101**; every other player writes
//!   the face sum of the tiles left in their rack (okey and false joker count the okey's number), or
//!   **202** if they never opened. The hand is **doubled** (finisher and the others) when the
//!   finishing tile was an okey, and again when the finisher opened with pairs. **Penalties** (+101
//!   each, not doubled): discarding a tile that could have been işlenmiş onto a table meld, and
//!   discarding an okey (except as the finishing tile). If the pile runs out after a discard the hand
//!   ends without a finisher and everyone writes their remaining tiles (or 202).
//! - **Match**: 5 hands by default (`{"hands": 3|5|7}` during the first hand). The lowest total wins:
//!   you win with the strictly lowest total, draw when tied for the lowest, otherwise you lose.
//! - Not implemented (deliberately simple): gösterge bonus, "elden bitme" doubling, increasing
//!   opening thresholds, taking the okey back from the table.
//!
//! ## AI (tables)
//! A memoised exact search ([`MeldSolver`]) partitions a rack into runs/sets maximising either the
//! **opening value** (sum of face values) or the **coverage** (tiles laid, then value); işleme onto the
//! table is planned greedily on top (chains: a run grows as tiles are added). Every AI opens as soon
//! as it can, lays everything it can and işles every tile it can (keeping a tile to discard, and an
//! okey for an okey finish when that is its last tile).
//! - **easy (Kolay)**: misses a usable discard 35 % of the time, forgets extra melds / işleme 30 %,
//!   picks among the weakest tiles with slips, and 15 % of the time does not check whether a discard
//!   is işlenebilir (and pays the 101 penalty).
//! - **normal (Orta)**: exact partitions, a link-based potential of the leftover tiles weighted by the
//!   unseen copies, never pays a penalty, reads its right-hand neighbour (tiles they took or threw).
//! - **hard (Zor)**: + one-draw lookahead (expected opening value over every unseen tile), dead-tile
//!   awareness, stronger defence weighted by how hot the neighbour is and how late the hand is, and
//!   after opening it dumps high tiles as the pile shrinks.
//! - **impossible (İmkânsız)**: omniscient — sees every rack and the pile order. It plans the fastest
//!   opening/finish over its known future draws, never discards a tile its (non-omniscient) right-hand
//!   neighbour could take to open or finish, and chooses pile vs. discard so the neighbour's next pile
//!   tile is the less useful one.
//!
//! Easy/normal/hard (and the player's hint) decide through [`Info`] (public data + own rack only).
//! Every AI action carries a concrete Turkish `reason`.
//!
//! ## State (in addition to the classic fields)
//! `variant: "101"`, `seats[i]: {score (match total), hand: this hand's penalties, opened,
//! open_kind: "melds"|"pairs"|null, open_value, ...}`, `table: [{owner, kind: run|set|pair, tiles,
//! value}]`, `melds: [{slots, kind, value}]` (valid melds in your rack layout), `need: 101`,
//! `need_pairs: 5`, `must_use`, `can_untake`, `penalty_tiles`, `addable: [{tile, melds}]`,
//! `history: [[4 × points] per hand]`, `hand_choices`.
//!
//! Actions: `{"draw":"pile"|"discard","slot"?}` · `{"untake":true}` · `{"lay":[[ids],…]}` (opens when
//! not opened) · `{"add":{"tile":id,"meld":i,"end"?:"low"|"high"}}` · `{"discard":id,"force"?:true}`
//! (a penalised discard needs `force`; discarding the last tile finishes) · `{"arrange":[28]}` ·
//! `{"auto_arrange":"runs"|"pairs"}` · `{"suggest":true}` ("Açılabilir mi?": arranges the best
//! opening and explains it) · `{"hint":true}` · `{"ai":true}` · `{"next":true}` · `{"hands":n}`.


use crate::rng::{time_seed, Rng};
use crate::Session;
use serde_json::{json, Value};

use super::okey::{
    cap, eff, is_false, kname, layout_melds, okey_of, pack_layout, rel, sort_key, tacc, tname, FxMap, Hc, Level, COLS, GEN, N_TILES,
    NAMES, PL, ROW, SLOTS, WHERE,
};

pub const DEAL: usize = 21;
pub const OPEN_MIN: u32 = 101;
pub const OPEN_PAIRS: usize = 5;
pub const PENALTY: i32 = 101;
pub const UNOPENED: i32 = 202;
pub const FINISH_POINTS: i32 = -101;
pub const DEFAULT_HANDS: u32 = 5;
pub const HAND_CHOICES: [u32; 3] = [3, 5, 7];
const LOOKAHEAD: usize = 6;

fn left(seat: usize) -> usize {
    (seat + 3) % 4
}
fn right(seat: usize) -> usize {
    (seat + 1) % 4
}

/// Points a tile is worth when left in the rack: its printed number; the false joker shows the okey.
pub fn face(id: u8, okey: u8) -> u32 {
    let k = if is_false(id) { okey } else { id % 52 };
    (k % 13 + 1) as u32
}

fn who(seat: usize) -> String {
    if seat == 0 {
        "Sen".into()
    } else {
        NAMES[seat].into()
    }
}

// =================================================================================================
// Melds on the table

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum MKind {
    /// Same colour; `tiles[i]` sits at position `start + i` (positions 0..=12 = numbers 1..13,
    /// 13 = the 1 after 13).
    Run { col: u8, start: u8 },
    Set { num: u8 },
    Pair,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum End {
    Low,
    High,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum OpenKind {
    Melds,
    Pairs,
}

#[derive(Clone, Debug, PartialEq)]
pub struct TMeld {
    pub owner: usize,
    pub kind: MKind,
    pub tiles: Vec<u8>,
}

fn run_value(start: u8, len: usize) -> u32 {
    (0..len).map(|i| ((start as usize + i) % 13 + 1) as u32).sum()
}

fn kind_value(kind: MKind, len: usize) -> u32 {
    match kind {
        MKind::Run { start, .. } => run_value(start, len),
        MKind::Set { num } => (num as u32 + 1) * len as u32,
        MKind::Pair => 0,
    }
}

impl TMeld {
    pub fn value(&self) -> u32 {
        kind_value(self.kind, self.tiles.len())
    }

    /// Where tile `id` can be added (işleme).
    pub fn fits(&self, id: u8, okey: u8) -> Vec<End> {
        let e = eff(id, okey);
        let mut out = Vec::new();
        match self.kind {
            MKind::Run { col, start } => {
                let end = start as usize + self.tiles.len() - 1;
                let ok = |pos: usize| e.is_none_or(|k| k as usize == col as usize * 13 + pos % 13);
                if end <= 12 {
                    let pos = end + 1;
                    if (pos < 13 || start >= 1) && ok(pos) {
                        out.push(End::High);
                    }
                }
                if start >= 1 {
                    let pos = start as usize - 1;
                    if (pos > 0 || end <= 12) && ok(pos) {
                        out.push(End::Low);
                    }
                }
            }
            MKind::Set { num } => {
                if self.tiles.len() < 4 {
                    match e {
                        None => out.push(End::High),
                        Some(k) => {
                            let used = self.tiles.iter().filter_map(|&t| eff(t, okey)).any(|t| t / 13 == k / 13);
                            if k % 13 == num && !used {
                                out.push(End::High);
                            }
                        }
                    }
                }
            }
            MKind::Pair => {}
        }
        out
    }

    fn add(&mut self, id: u8, end: End) {
        match (&mut self.kind, end) {
            (MKind::Run { start, .. }, End::Low) => {
                *start -= 1;
                self.tiles.insert(0, id);
            }
            _ => self.tiles.push(id),
        }
    }

    pub fn desc(&self, okey: u8) -> String {
        match self.kind {
            MKind::Run { col, start } => {
                let nums: Vec<String> = (0..self.tiles.len()).map(|i| format!("{}", (start as usize + i) % 13 + 1)).collect();
                format!("{} {}", COLS[col as usize], nums.join("-"))
            }
            MKind::Set { num } => format!("{}'{}", num + 1, PL[num as usize]),
            MKind::Pair => {
                let t = self.tiles.iter().copied().find(|&t| eff(t, okey).is_some()).unwrap_or(self.tiles[0]);
                format!("{} çifti", tname(t, okey))
            }
        }
    }
}

/// Valid starts of a run laid in this order (ascending), best value first.
fn run_starts(e: &[Option<u8>]) -> Vec<(u8, u8)> {
    let n = e.len();
    let Some(fi) = e.iter().position(|x| x.is_some()) else { return vec![] };
    let f = e[fi].unwrap();
    let col = f / 13;
    let mut starts = vec![(f % 13) as i32 - fi as i32];
    if f % 13 == 0 {
        starts.push(13 - fi as i32);
    }
    let mut out: Vec<(u8, u8)> = Vec::new();
    for st in starts {
        if st < 0 || st + n as i32 - 1 > 13 || (st == 0 && n as i32 - 1 == 13) {
            continue;
        }
        let ok = e.iter().enumerate().all(|(i, x)| x.is_none_or(|k| k / 13 == col && ((st as usize + i) % 13) as u8 == k % 13));
        if ok {
            out.push((col, st as u8));
        }
    }
    out.sort_by_key(|&(_, st)| std::cmp::Reverse(run_value(st, n)));
    out
}

/// What a group of tiles (in this order) forms, if anything — the higher-valued reading wins.
pub fn classify(ids: &[u8], okey: u8) -> Option<MKind> {
    let e: Vec<Option<u8>> = ids.iter().map(|&i| eff(i, okey)).collect();
    let n = e.len();
    if n == 2 {
        return if e[0] == e[1] || e[0].is_none() || e[1].is_none() { Some(MKind::Pair) } else { None };
    }
    if n < 3 {
        return None;
    }
    let mut best: Option<(u32, MKind)> = None;
    if n <= 4 {
        let reals: Vec<u8> = e.iter().flatten().copied().collect();
        if let Some(&f) = reals.first() {
            let mut cols = 0u8;
            let ok = reals.iter().all(|&k| {
                let fresh = k % 13 == f % 13 && cols >> (k / 13) & 1 == 0;
                cols |= 1 << (k / 13);
                fresh
            });
            if ok {
                let num = f % 13;
                best = Some(((num as u32 + 1) * n as u32, MKind::Set { num }));
            }
        }
    }
    if let Some(&(col, start)) = run_starts(&e).first() {
        let v = run_value(start, n);
        if best.is_none_or(|b| v > b.0) {
            best = Some((v, MKind::Run { col, start }));
        }
    }
    best.map(|b| b.1)
}

/// The okey (or a tile işlenebilir onto a table run/set) — discarding it costs 101.
pub fn penalty_of(id: u8, table: &[TMeld], okey: u8) -> Option<&'static str> {
    if eff(id, okey).is_none() {
        return Some("okey");
    }
    if table.iter().any(|m| !m.fits(id, okey).is_empty()) {
        return Some("isle");
    }
    None
}

// =================================================================================================
// Meld solver (kind space)

const JB: u128 = 1 << 104;
const KMASK: u128 = JB - 1;

fn kb(k: usize) -> u128 {
    1u128 << (2 * k)
}
fn kc(key: u128, k: usize) -> u8 {
    ((key >> (2 * k)) & 3) as u8
}
fn key_of(h: &Hc) -> u128 {
    let mut k = (h.j.min(3) as u128) << 104;
    for (i, &c) in h.c.iter().enumerate() {
        k |= (c.min(3) as u128) << (2 * i);
    }
    k
}

/// A meld in kind space.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Shape {
    /// Positions `start .. start+len` of colour `col`; bit i of `wild` = position start+i is an okey.
    Run { col: u8, start: u8, len: u8, wild: u16 },
    /// Number `num`, real colours `cols`, plus `wilds` okeys.
    Set { num: u8, cols: u8, wilds: u8 },
}

impl Shape {
    pub fn value(&self) -> u32 {
        match *self {
            Shape::Run { start, len, .. } => run_value(start, len as usize),
            Shape::Set { num, cols, wilds } => (num as u32 + 1) * (cols.count_ones() + wilds as u32),
        }
    }
    pub fn count(&self) -> u32 {
        match *self {
            Shape::Run { len, .. } => len as u32,
            Shape::Set { cols, wilds, .. } => cols.count_ones() + wilds as u32,
        }
    }
    pub fn wilds(&self) -> u8 {
        match *self {
            Shape::Run { wild, .. } => wild.count_ones() as u8,
            Shape::Set { wilds, .. } => wilds,
        }
    }
    /// Real kinds, in laying order (wild positions as `None`).
    pub fn slots(&self) -> Vec<Option<u8>> {
        match *self {
            Shape::Run { col, start, len, wild } => (0..len)
                .map(|i| if wild >> i & 1 == 1 { None } else { Some(col * 13 + (start + i) % 13) })
                .collect(),
            Shape::Set { num, cols, wilds } => {
                let mut v: Vec<Option<u8>> = (0..4u8).filter(|c| cols >> c & 1 == 1).map(|c| Some(c * 13 + num)).collect();
                v.extend((0..wilds).map(|_| None));
                v
            }
        }
    }
    fn remove_from(&self, h: &mut Hc) {
        for s in self.slots() {
            match s {
                Some(k) => h.c[k as usize] -= 1,
                None => h.j -= 1,
            }
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Obj {
    /// Maximise the face-value sum (opening).
    Value,
    /// Maximise the number of tiles laid, then the value.
    Cover,
}

fn gain(obj: Obj, value: u32, count: u32) -> u32 {
    match obj {
        Obj::Value => value * 64 + count,
        Obj::Cover => count * 1024 + value,
    }
}

type Opt = (u128, u32, Option<Shape>);

/// Exact memoised search over meld partitions. Values depend only on the remaining tiles, so the
/// memo persists across calls.
pub struct MeldSolver {
    memo: [FxMap<u128, u32>; 2],
    bufs: Vec<Vec<Opt>>,
    pub calls: u64,
}

impl Default for MeldSolver {
    fn default() -> Self {
        Self::new()
    }
}

impl MeldSolver {
    pub fn new() -> Self {
        MeldSolver {
            memo: [FxMap::with_capacity_and_hasher(1 << 15, Default::default()), FxMap::with_capacity_and_hasher(1 << 15, Default::default())],
            bufs: (0..40).map(|_| Vec::with_capacity(64)).collect(),
            calls: 0,
        }
    }

    fn options(&self, key: u128, obj: Obj, out: &mut Vec<Opt>) {
        let k = ((key & KMASK).trailing_zeros() / 2) as usize;
        let col = k / 13;
        let n = k % 13;
        let j = (key >> 104) as u8 & 3;
        let rest = key - kb(k);
        out.push((rest, 0, None));
        // Sets with this tile in the lowest colour.
        let mut avail = [0usize; 3];
        let mut na = 0;
        for c2 in col + 1..4 {
            if kc(rest, c2 * 13 + n) > 0 {
                avail[na] = c2;
                na += 1;
            }
        }
        for m in 0..(1u32 << na) {
            let real = 1 + m.count_ones() as u8;
            let mut cols = 1u8 << col;
            let mut next = rest;
            for (i, &c2) in avail.iter().enumerate().take(na) {
                if m >> i & 1 == 1 {
                    cols |= 1 << c2;
                    next -= kb(c2 * 13 + n);
                }
            }
            for w in 0..=j {
                let size = real + w;
                if !(3..=4).contains(&size) {
                    continue;
                }
                let sh = Shape::Set { num: n as u8, cols, wilds: w };
                out.push((next - (w as u128) * JB, gain(obj, sh.value(), sh.count()), Some(sh)));
            }
        }
        // Runs in which this is the lowest real tile.
        if n == 0 {
            self.ext(rest, j, col, 0, 1, 1, 0, obj, 12, out);
            for s in 1..=11usize {
                self.fill(rest, j, col, s, s, 0, obj, out);
            }
        } else {
            for pre in 0..=(j as usize).min(n) {
                let start = n - pre;
                let mask = (1u16 << pre) - 1;
                self.ext(rest - (pre as u128) * JB, j - pre as u8, col, start, n + 1, pre + 1, mask, obj, if start == 0 { 12 } else { 13 }, out);
            }
        }
    }

    /// Extend a run upwards at position `pos`.
    #[allow(clippy::too_many_arguments)]
    fn ext(&self, key: u128, j: u8, col: usize, start: usize, pos: usize, len: usize, mask: u16, obj: Obj, maxpos: usize, out: &mut Vec<Opt>) {
        if len >= 3 {
            let sh = Shape::Run { col: col as u8, start: start as u8, len: len as u8, wild: mask };
            out.push((key, gain(obj, sh.value(), sh.count()), Some(sh)));
        }
        if pos > maxpos {
            return;
        }
        if pos <= 12 && kc(key, col * 13 + pos) > 0 {
            self.ext(key - kb(col * 13 + pos), j, col, start, pos + 1, len + 1, mask, obj, maxpos, out);
        }
        if j > 0 {
            self.ext(key - JB, j - 1, col, start, pos + 1, len + 1, mask | 1 << len, obj, maxpos, out);
        }
    }

    /// A run `s..=12` closed by this 1 (position 13): every position filled by a real tile or okey.
    #[allow(clippy::too_many_arguments)]
    fn fill(&self, key: u128, j: u8, col: usize, s: usize, pos: usize, mask: u16, obj: Obj, out: &mut Vec<Opt>) {
        if pos > 12 {
            let sh = Shape::Run { col: col as u8, start: s as u8, len: (14 - s) as u8, wild: mask };
            out.push((key, gain(obj, sh.value(), sh.count()), Some(sh)));
            return;
        }
        let bit = 1u16 << (pos - s);
        if kc(key, col * 13 + pos) > 0 {
            self.fill(key - kb(col * 13 + pos), j, col, s, pos + 1, mask, obj, out);
        }
        if j > 0 {
            self.fill(key - JB, j - 1, col, s, pos + 1, mask | bit, obj, out);
        }
    }

    fn f(&mut self, key: u128, obj: Obj, depth: usize) -> u32 {
        if key & KMASK == 0 {
            return 0;
        }
        let mi = obj as usize;
        if let Some(&v) = self.memo[mi].get(&key) {
            return v;
        }
        self.calls += 1;
        if depth >= self.bufs.len() {
            self.bufs.push(Vec::with_capacity(64));
        }
        let mut buf = std::mem::take(&mut self.bufs[depth]);
        buf.clear();
        self.options(key, obj, &mut buf);
        let mut best = 0u32;
        for o in buf.iter() {
            let v = o.1 + self.f(o.0, obj, depth + 1);
            if v > best {
                best = v;
            }
        }
        self.bufs[depth] = buf;
        if self.memo[mi].len() > 600_000 {
            self.memo[mi].clear();
        }
        self.memo[mi].insert(key, best);
        best
    }

    pub fn score(&mut self, h: &Hc, obj: Obj) -> u32 {
        self.f(key_of(h), obj, 0)
    }

    /// The best score and the melds of one optimal solution.
    pub fn best(&mut self, h: &Hc, obj: Obj) -> (u32, Vec<Shape>) {
        let mut key = key_of(h);
        let total = self.f(key, obj, 0);
        let mut out = Vec::new();
        let mut buf = Vec::new();
        while key & KMASK != 0 {
            let want = self.f(key, obj, 0);
            buf.clear();
            self.options(key, obj, &mut buf);
            let mut chosen = buf[0];
            for &o in buf.iter() {
                if o.1 + self.f(o.0, obj, 1) == want {
                    chosen = o;
                    break;
                }
            }
            if let Some(sh) = chosen.2 {
                out.push(sh);
            }
            key = chosen.0;
        }
        (total, out)
    }

    /// Opening value of a rack (sum of face values of the best partition).
    pub fn value(&mut self, h: &Hc) -> u32 {
        self.score(h, Obj::Value) / 64
    }

    /// Best partition that uses one tile of kind `k` (already counted in `h`): (score, its meld,
    /// the rest's melds).
    pub fn forced(&mut self, h: &Hc, k: u8, obj: Obj) -> Option<(u32, Shape, Vec<Shape>)> {
        let mut best: Option<(u32, Shape)> = None;
        for sh in shapes_with(h, k) {
            let mut r = *h;
            sh.remove_from(&mut r);
            let v = gain(obj, sh.value(), sh.count()) + self.score(&r, obj);
            if best.is_none_or(|b| v > b.0) {
                best = Some((v, sh));
            }
        }
        let (v, sh) = best?;
        let mut r = *h;
        sh.remove_from(&mut r);
        let (_, rest) = self.best(&r, obj);
        Some((v, sh, rest))
    }
}

/// Every meld (real tiles where available, okeys for the gaps) that contains a tile of kind `k`
/// and otherwise only tiles counted in `h` (which includes that tile).
pub fn shapes_with(h: &Hc, k: u8) -> Vec<Shape> {
    let mut out = Vec::new();
    let col = k / 13;
    let n = k % 13;
    // Sets.
    let others: Vec<u8> = (0..4u8).filter(|&c| c != col && h.c[(c * 13 + n) as usize] > 0).collect();
    for m in 0..(1u32 << others.len()) {
        let mut cols = 1u8 << col;
        for (i, &c) in others.iter().enumerate() {
            if m >> i & 1 == 1 {
                cols |= 1 << c;
            }
        }
        let real = cols.count_ones() as u8;
        for w in 0..=h.j {
            if (3..=4).contains(&(real + w)) {
                out.push(Shape::Set { num: n, cols, wilds: w });
            }
        }
    }
    // Runs through position p.
    let mut ps = vec![n as usize];
    if n == 0 {
        ps.push(13);
    }
    for p in ps {
        for start in 0..=p {
            for end in p.max(start + 2)..=13 {
                if start == 0 && end == 13 {
                    continue;
                }
                let mut wild = 0u16;
                let mut need = 0u8;
                for q in start..=end {
                    if q == p {
                        continue;
                    }
                    if h.c[col as usize * 13 + q % 13] == 0 {
                        wild |= 1 << (q - start);
                        need += 1;
                    }
                }
                if need <= h.j {
                    out.push(Shape::Run { col, start: start as u8, len: (end - start + 1) as u8, wild });
                }
            }
        }
    }
    out
}

/// Turn kind-space melds into tile id groups from `rack`; `prefer` is picked first for its kind.
pub fn realize(shapes: &[Shape], rack: &[u8], okey: u8, prefer: Option<u8>) -> (Vec<Vec<u8>>, Vec<u8>) {
    let mut pool: Vec<u8> = rack.to_vec();
    if let Some(p) = prefer {
        if let Some(i) = pool.iter().position(|&x| x == p) {
            pool.remove(i);
            pool.insert(0, p);
        }
    }
    let mut groups = Vec::new();
    for sh in shapes {
        let mut g = Vec::new();
        for s in sh.slots() {
            let i = pool.iter().position(|&id| eff(id, okey) == s);
            if let Some(i) = i {
                g.push(pool.remove(i));
            }
        }
        groups.push(g);
    }
    (groups, pool)
}

/// Pairs of a rack: identical tiles first, then an okey with the highest single, then okey + okey.
pub fn pairs_of(rack: &[u8], okey: u8) -> (Vec<Vec<u8>>, Vec<u8>) {
    let mut pool: Vec<u8> = rack.to_vec();
    pool.sort_by_key(|&id| sort_key(id, okey));
    let mut wild: Vec<u8> = pool.iter().copied().filter(|&id| eff(id, okey).is_none()).collect();
    pool.retain(|&id| eff(id, okey).is_some());
    let mut pairs = Vec::new();
    let mut singles = Vec::new();
    let mut i = 0;
    while i < pool.len() {
        if i + 1 < pool.len() && eff(pool[i], okey) == eff(pool[i + 1], okey) {
            pairs.push(vec![pool[i], pool[i + 1]]);
            i += 2;
        } else {
            singles.push(pool[i]);
            i += 1;
        }
    }
    singles.sort_by_key(|&id| std::cmp::Reverse(face(id, okey)));
    while let Some(w) = wild.pop() {
        if !singles.is_empty() {
            let s = singles.remove(0);
            pairs.push(vec![s, w]);
        } else if let Some(w2) = wild.pop() {
            pairs.push(vec![w, w2]);
        } else {
            singles.push(w);
        }
    }
    (pairs, singles)
}

/// Greedy işleme: tiles of `rack` that can go onto `table` (a run grows as tiles are added), okeys
/// last and only when `wilds` is set. Returns (tile, meld index, end) in order.
pub fn isle_plan(table: &[TMeld], rack: &[u8], okey: u8, wilds: bool) -> Vec<(u8, usize, End)> {
    let mut t: Vec<TMeld> = table.to_vec();
    let mut pool: Vec<u8> = rack.to_vec();
    let mut out = Vec::new();
    loop {
        let mut moved = false;
        for pass_wild in [false, true] {
            if pass_wild && !wilds {
                continue;
            }
            let mut i = 0;
            while i < pool.len() {
                let id = pool[i];
                if eff(id, okey).is_none() != pass_wild {
                    i += 1;
                    continue;
                }
                let spot = t.iter().enumerate().find_map(|(mi, m)| m.fits(id, okey).first().map(|&e| (mi, e)));
                if let Some((mi, e)) = spot {
                    t[mi].add(id, e);
                    out.push((id, mi, e));
                    pool.remove(i);
                    moved = true;
                } else {
                    i += 1;
                }
            }
            if moved {
                break;
            }
        }
        if !moved {
            break;
        }
    }
    out
}

// =================================================================================================
// Hand (full truth) and information sets

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Stage {
    Draw,
    Play,
}

#[derive(Clone, Debug)]
struct Snapshot {
    rack: Vec<u8>,
    table: Vec<TMeld>,
    opened: Option<OpenKind>,
    open_value: u32,
    layout: [i16; SLOTS],
}

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
    pub stage: Stage,
    pub starter: usize,
    pub turns: u32,
    pub table: Vec<TMeld>,
    pub opened: [Option<OpenKind>; 4],
    pub open_value: [u32; 4],
    pub penalties: [i32; 4],
    /// The tile taken from the left this turn: it must leave the rack before the discard.
    pub must_use: Option<u8>,
    snapshot: Option<Box<Snapshot>>,
    /// The AI meld step of this turn is done.
    pub melded: bool,
}

impl Hand {
    pub fn deal(rng: &mut Rng, starter: usize) -> Hand {
        let mut tiles: Vec<u8> = (0..N_TILES).collect();
        rng.shuffle(&mut tiles);
        let pos = tiles.iter().position(|&t| !is_false(t)).unwrap_or(0);
        let indicator = tiles.remove(pos);
        let mut racks: [Vec<u8>; 4] = Default::default();
        for (s, r) in racks.iter_mut().enumerate() {
            let n = if s == starter { DEAL + 1 } else { DEAL };
            *r = tiles.drain(..n).collect();
        }
        Hand {
            racks,
            discards: Default::default(),
            taken: Default::default(),
            pile: tiles,
            indicator,
            okey: okey_of(indicator),
            turn: starter,
            stage: Stage::Play,
            starter,
            turns: 0,
            table: Vec::new(),
            opened: [None; 4],
            open_value: [0; 4],
            penalties: [0; 4],
            must_use: None,
            snapshot: None,
            melded: false,
        }
    }

    pub fn offer(&self, seat: usize) -> Option<u8> {
        self.discards[left(seat)].last().copied()
    }

    pub fn info(&self, seat: usize) -> Info<'_> {
        Info {
            seat,
            rack: &self.racks[seat],
            discards: &self.discards,
            taken: &self.taken,
            table: &self.table,
            opened: self.opened,
            counts: [0, 1, 2, 3].map(|s| self.racks[s].len()),
            indicator: self.indicator,
            okey: self.okey,
            pile_count: self.pile.len(),
            must_use: if self.turn == seat { self.must_use } else { None },
        }
    }

    /// Pile tiles `seat` will draw if every other player draws from the pile.
    fn future(&self, offset: usize, n: usize) -> Vec<u8> {
        let len = self.pile.len();
        (0..n).map(|k| offset + 4 * k).take_while(|&i| i < len).map(|i| self.pile[len - 1 - i]).collect()
    }
}

/// What a seat legitimately knows: public data and its own rack. Easy/normal/hard and the hint
/// decide only through this.
pub struct Info<'a> {
    pub seat: usize,
    pub rack: &'a [u8],
    pub discards: &'a [Vec<u8>; 4],
    pub taken: &'a [Vec<u8>; 4],
    pub table: &'a [TMeld],
    pub opened: [Option<OpenKind>; 4],
    pub counts: [usize; 4],
    pub indicator: u8,
    pub okey: u8,
    pub pile_count: usize,
    pub must_use: Option<u8>,
}

impl Info<'_> {
    fn offer(&self) -> Option<u8> {
        self.discards[left(self.seat)].last().copied()
    }
}

/// Copies not visible to the deciding seat, by effective kind (+ wild okeys).
#[derive(Clone, Copy)]
struct Unseen {
    k: [u8; 52],
    j: u8,
    total: u32,
}

impl Unseen {
    fn of(info: &Info) -> Unseen {
        let mut seen = [false; N_TILES as usize];
        for &id in info.rack.iter().chain(std::iter::once(&info.indicator)).chain(info.discards.iter().flatten()).chain(info.taken.iter().flatten()) {
            seen[id as usize] = true;
        }
        for m in info.table {
            for &id in &m.tiles {
                seen[id as usize] = true;
            }
        }
        let mut phys = [2u8; 52];
        let mut fals = 2u8;
        for (id, &s) in seen.iter().enumerate() {
            if s {
                if is_false(id as u8) {
                    fals -= 1;
                } else {
                    phys[id % 52] -= 1;
                }
            }
        }
        let j = phys[info.okey as usize];
        phys[info.okey as usize] = fals;
        let total = phys.iter().map(|&x| x as u32).sum::<u32>() + j as u32;
        Unseen { k: phys, j, total }
    }

    /// No card counting: two copies of everything.
    fn flat() -> Unseen {
        Unseen { k: [2; 52], j: 2, total: 106 }
    }
}

// =================================================================================================
// Rules helpers shared by the session and the AI

/// How a taken tile can be used this turn.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Use {
    /// Opening with it (value, or pairs).
    Open { pairs: bool, value: u32 },
    /// Onto a table meld.
    Isle,
    /// In a new meld with rack tiles.
    Meld,
    /// In a new pair (pair openers).
    Pair,
}

/// Tiles of a meld opener's rack left after laying the best partition and işleme onto `table`.
fn leftovers_melds(s: &mut MeldSolver, rack: &[u8], table: &[TMeld], okey: u8, seat: usize) -> Vec<u8> {
    let (_, shapes) = s.best(&Hc::of(rack, okey), Obj::Cover);
    let (groups, rest) = realize(&shapes, rack, okey, None);
    let mut t = table.to_vec();
    for g in groups {
        if let Some(kind) = classify(&g, okey) {
            t.push(TMeld { owner: seat, kind, tiles: g });
        }
    }
    let adds = isle_plan(&t, &rest, okey, true);
    let mut rest = rest;
    for (id, _, _) in adds {
        rest.retain(|&x| x != id);
    }
    rest
}

fn leftovers_pairs(rack: &[u8], table: &[TMeld], okey: u8) -> Vec<u8> {
    let (_, singles) = pairs_of(rack, okey);
    let adds = isle_plan(table, &singles, okey, true);
    singles.into_iter().filter(|id| !adds.iter().any(|a| a.0 == *id)).collect()
}

/// Tiles left in the rack after laying everything possible (as if opened).
fn leftovers(s: &mut MeldSolver, rack: &[u8], table: &[TMeld], okey: u8, seat: usize, kind: OpenKind) -> Vec<u8> {
    match kind {
        OpenKind::Melds => leftovers_melds(s, rack, table, okey, seat),
        OpenKind::Pairs => leftovers_pairs(rack, table, okey),
    }
}

fn can_isle(table: &[TMeld], id: u8, okey: u8) -> Option<usize> {
    table.iter().position(|m| !m.fits(id, okey).is_empty())
}

/// How a seat with `rack` (without `t`) could use tile `t` taken from the left this turn.
pub fn take_use(s: &mut MeldSolver, rack: &[u8], t: u8, table: &[TMeld], opened: Option<OpenKind>, okey: u8) -> Option<Use> {
    let mut r = rack.to_vec();
    r.push(t);
    let h = Hc::of(&r, okey);
    let isle = can_isle(table, t, okey).is_some();
    let e = eff(t, okey);
    match opened {
        Some(OpenKind::Melds) => {
            let meld = match e {
                Some(k) => !shapes_with(&h, k).is_empty(),
                None => s.score(&h, Obj::Cover) / 1024 > s.score(&Hc::of(rack, okey), Obj::Cover) / 1024,
            };
            if meld {
                Some(Use::Meld)
            } else if isle {
                Some(Use::Isle)
            } else {
                None
            }
        }
        Some(OpenKind::Pairs) => {
            let pair = e.is_none() || rack.iter().any(|&x| eff(x, okey) == e || eff(x, okey).is_none());
            if pair {
                Some(Use::Pair)
            } else if isle {
                Some(Use::Isle)
            } else {
                None
            }
        }
        None => {
            let forced = match e {
                Some(k) => s.forced(&h, k, Obj::Value).map(|x| x.0 / 64).unwrap_or(0),
                None => {
                    let (sc, shapes) = s.best(&h, Obj::Value);
                    if shapes.iter().map(|x| x.wilds()).sum::<u8>() == h.j {
                        sc / 64
                    } else {
                        0
                    }
                }
            };
            if forced >= OPEN_MIN {
                return Some(Use::Open { pairs: false, value: forced });
            }
            let base = s.value(&Hc::of(rack, okey));
            if base >= OPEN_MIN && isle {
                return Some(Use::Open { pairs: false, value: base });
            }
            let before = pairs_of(rack, okey).0.len();
            let (after, singles) = pairs_of(&r, okey);
            if after.len() >= OPEN_PAIRS && after.len() > before && !singles.contains(&t) {
                return Some(Use::Open { pairs: true, value: 0 });
            }
            if before >= OPEN_PAIRS && isle {
                return Some(Use::Open { pairs: true, value: 0 });
            }
            None
        }
    }
}

/// Melds and işleme a seat performs in its play stage.
#[derive(Clone, Debug, Default)]
pub struct MeldPlan {
    pub open: Option<OpenKind>,
    /// New groups; the first `open_count` form the opening.
    pub groups: Vec<Vec<u8>>,
    pub open_count: usize,
    /// İşleme after laying the groups (meld indices refer to the table after the groups are laid).
    pub adds: Vec<(u8, usize, End)>,
    pub value: u32,
}

impl MeldPlan {
    pub fn is_empty(&self) -> bool {
        self.groups.is_empty() && self.adds.is_empty()
    }
}

fn groups_value(groups: &[Vec<u8>], okey: u8) -> u32 {
    groups.iter().map(|g| classify(g, okey).map_or(0, |k| kind_value(k, g.len()))).sum()
}

/// Everything a seat can lay now: the opening (melds ≥ 101, else ≥ 5 pairs) as soon as possible,
/// then every further meld and every işleme — always keeping one tile to discard (an okey when it
/// would be the last tile: finishing with it doubles the hand). `extras = false` skips the
/// non-mandatory part (easy's slips), but never the use of `must_use`.
#[allow(clippy::too_many_arguments)]
pub fn plan_melds(
    s: &mut MeldSolver,
    rack: &[u8],
    table: &[TMeld],
    opened: Option<OpenKind>,
    must_use: Option<u8>,
    okey: u8,
    seat: usize,
    extras: bool,
) -> MeldPlan {
    let mut plan = MeldPlan::default();
    let mut pool: Vec<u8> = rack.to_vec();
    let mut kind = opened;
    let must = must_use.filter(|t| pool.contains(t));
    if kind.is_none() {
        let h = Hc::of(&pool, okey);
        let forced = match must.and_then(|t| eff(t, okey)) {
            Some(k) => s.forced(&h, k, Obj::Value).map(|(sc, sh, rest)| {
                let mut v = vec![sh];
                v.extend(rest);
                (sc, v)
            }),
            None => None,
        };
        // Without a forced opening the taken tile is işlendi right after opening.
        let (vscore, vshapes) = match forced {
            Some(f) if f.0 / 64 >= OPEN_MIN => f,
            _ => s.best(&h, Obj::Value),
        };
        let value = vscore / 64;
        let mut chosen: Option<Vec<Shape>> = None;
        if value >= OPEN_MIN {
            let (cscore, cshapes) = s.best(&h, Obj::Cover);
            let cv = cscore % 1024;
            chosen = Some(if cv >= OPEN_MIN && must.is_none() { cshapes } else { vshapes });
        }
        if let Some(shapes) = chosen {
            let (groups, rest) = realize(&shapes, &pool, okey, must);
            plan.value = groups_value(&groups, okey);
            plan.open_count = groups.len();
            plan.groups = groups;
            plan.open = Some(OpenKind::Melds);
            pool = rest;
            kind = Some(OpenKind::Melds);
        } else {
            let (pairs, rest) = pairs_of(&pool, okey);
            if pairs.len() >= OPEN_PAIRS && must.is_none_or(|t| !rest.contains(&t) || can_isle(table, t, okey).is_some()) {
                plan.open_count = pairs.len();
                plan.groups = pairs;
                plan.open = Some(OpenKind::Pairs);
                pool = rest;
                kind = Some(OpenKind::Pairs);
            }
        }
        if kind.is_none() {
            return plan;
        }
    }
    let kind = kind.unwrap();
    let must_left = must.is_some_and(|t| pool.contains(&t));
    if extras || must_left {
        // Further melds.
        let (groups, rest) = match kind {
            OpenKind::Melds => {
                let (_, shapes) = s.best(&Hc::of(&pool, okey), Obj::Cover);
                realize(&shapes, &pool, okey, must)
            }
            OpenKind::Pairs => pairs_of(&pool, okey),
        };
        if extras {
            plan.groups.extend(groups);
            pool = rest;
        } else if let Some(g) = groups.into_iter().find(|g| must.is_some_and(|t| g.contains(&t))) {
            pool.retain(|x| !g.contains(x));
            plan.groups.push(g);
        }
    }
    // Keep one tile to discard.
    if pool.is_empty() {
        let first_extra = plan.open_count;
        let opening_melds = plan.open == Some(OpenKind::Melds);
        // A tile off the end of a long run / set, okeys first (an okey finish doubles).
        let mut cut: Option<(usize, usize)> = None;
        for (gi, g) in plan.groups.iter().enumerate() {
            if g.len() < 4 {
                continue;
            }
            for pos in [g.len() - 1, 0] {
                let mut g2 = g.clone();
                let id = g2.remove(pos);
                if must == Some(id) || classify(&g2, okey).is_none_or(|k| k == MKind::Pair) {
                    continue;
                }
                if opening_melds && gi < first_extra {
                    let mut gs = plan.groups[..first_extra].to_vec();
                    gs[gi] = g2.clone();
                    if groups_value(&gs, okey) < OPEN_MIN {
                        continue;
                    }
                }
                let better = cut.is_none_or(|(cg, cp)| eff(id, okey).is_none() && eff(plan.groups[cg][cp], okey).is_some());
                if better {
                    cut = Some((gi, pos));
                }
            }
        }
        if let Some((gi, pos)) = cut {
            let id = plan.groups[gi].remove(pos);
            pool.push(id);
        } else if plan.groups.len() > first_extra && !plan.groups.last().is_some_and(|g| must.is_some_and(|t| g.contains(&t))) {
            let g = plan.groups.pop().unwrap();
            pool.extend(g);
        } else {
            // No tile can be kept back without breaking the opening: lay nothing this turn.
            return MeldPlan::default();
        }
    }
    // İşleme onto the table (and the melds just laid).
    let must_left = must.is_some_and(|t| pool.contains(&t));
    if extras || must_left {
        let mut tbl: Vec<TMeld> = table.to_vec();
        for g in &plan.groups {
            if let Some(k) = classify(g, okey) {
                tbl.push(TMeld { owner: seat, kind: k, tiles: g.clone() });
            }
        }
        let mut adds = isle_plan(&tbl, &pool, okey, true);
        if !extras {
            // Only what the taken tile needs (it may need a chain before it).
            match adds.iter().position(|a| Some(a.0) == must) {
                Some(p) => adds.truncate(p + 1),
                None => adds.clear(),
            }
        }
        if adds.len() >= pool.len() {
            // Keep a tile: a lone okey when everything else goes (okey finish), else cut the chain.
            let wild_n = pool.iter().filter(|&&x| eff(x, okey).is_none()).count();
            let alt = isle_plan(&tbl, &pool, okey, false);
            if extras && wild_n == 1 && alt.len() + 1 == pool.len() && must.is_none_or(|t| eff(t, okey).is_some()) {
                adds = alt;
            } else {
                adds.truncate(pool.len() - 1);
            }
        }
        for a in &adds {
            pool.retain(|&x| x != a.0);
        }
        plan.adds = adds;
    }
    plan
}

// =================================================================================================
// Explanations

fn meld_ref(m: &TMeld, okey: u8) -> String {
    let whose = if m.owner == 0 { "senin".to_string() } else { GEN[m.owner].to_string() };
    format!("{whose} {} perine", m.desc(okey))
}

fn plan_text(plan: &MeldPlan, table: &[TMeld], okey: u8, seat: usize, you: bool) -> String {
    let mut parts = Vec::new();
    let mut tbl = table.to_vec();
    for g in &plan.groups {
        if let Some(k) = classify(g, okey) {
            tbl.push(TMeld { owner: seat, kind: k, tiles: g.clone() });
        }
    }
    let v = |a: &str, b: &str| if you { a.to_string() } else { b.to_string() };
    match plan.open {
        Some(OpenKind::Melds) => parts.push(format!("{} perle {} puan {}", plan.open_count, plan.value, v("aç", "açtı"))),
        Some(OpenKind::Pairs) => parts.push(format!("{} çiftle {}", plan.open_count, v("aç", "açtı"))),
        None => {}
    }
    let extra = plan.groups.len() - plan.open_count;
    if extra > 0 {
        let what = if plan.groups.last().is_some_and(|g| g.len() == 2) { "çift" } else { "per" };
        parts.push(format!("{extra} {what} daha {}", v("indir", "indirdi")));
    }
    if !plan.adds.is_empty() {
        let (id, mi, _) = plan.adds[0];
        if plan.adds.len() == 1 {
            parts.push(format!("{} {} {}", tacc(id, okey), meld_ref(&tbl[mi], okey), v("işle", "işledi")));
        } else {
            parts.push(format!("{} taş {}", plan.adds.len(), v("işle", "işledi")));
        }
    }
    cap(&parts.join(", "))
}

/// Danger of discarding kind `k` to the right-hand neighbour, from public evidence only.
fn danger(info: &Info, k: Option<u8>) -> (f64, Option<u8>) {
    let Some(k) = k else { return (60.0, None) };
    let n = right(info.seat);
    let okey = info.okey;
    let mut d = 0.0;
    let mut best: (f64, Option<u8>) = (0.0, None);
    for &t in &info.taken[n] {
        let Some(tk) = eff(t, okey) else { continue };
        let w = match rel(k, tk) {
            1 => 1.0,
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
    for &t in info.discards[info.seat].iter().chain(info.discards[n].iter()) {
        let Some(tk) = eff(t, okey) else { continue };
        d -= match rel(k, tk) {
            1 => 2.5,
            2 => 1.0,
            4 => 1.0,
            _ => 0.0,
        };
    }
    // An opened neighbour takes anything that fits their hand.
    if info.opened[n].is_some() {
        d *= 1.3;
    }
    (d.max(0.0), best.1)
}

/// Link potential of loose tiles: how likely pairs of them grow into melds (weighted by the unseen
/// completing copies and the points they would bring).
fn potential(loose: &[u8], okey: u8, un: &Unseen) -> f64 {
    let ks: Vec<Option<u8>> = loose.iter().map(|&id| eff(id, okey)).collect();
    let mut p = 0.0;
    for (i, a) in ks.iter().enumerate() {
        let Some(a) = *a else {
            p += 18.0;
            continue;
        };
        for b in ks.iter().skip(i + 1) {
            let Some(b) = *b else { continue };
            let (ca, na) = (a / 13, a % 13);
            let (cb, nb) = (b / 13, b % 13);
            let mut outs = 0u32;
            let mut pts = (na + nb + 2) as f64;
            if ca == cb && a != b {
                let (lo, hi) = (na.min(nb), na.max(nb));
                match hi - lo {
                    1 => {
                        if lo >= 1 {
                            outs += un.k[(ca * 13 + lo - 1) as usize] as u32;
                        }
                        outs += un.k[(ca * 13 + (hi + 1) % 13) as usize] as u32;
                        pts += (lo + 1) as f64;
                    }
                    2 => {
                        outs += un.k[(ca * 13 + lo + 1) as usize] as u32;
                        pts += (lo + 2) as f64;
                    }
                    _ => {}
                }
            } else if na == nb && ca != cb {
                for c in 0..4u8 {
                    if c != ca && c != cb {
                        outs += un.k[(c * 13 + na) as usize] as u32;
                    }
                }
                pts += (na + 1) as f64;
            }
            if outs > 0 {
                p += (outs as f64 + un.j as f64) * pts / 12.0;
            }
        }
    }
    p
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
    out
}

fn without(rack: &[u8], id: u8) -> Vec<u8> {
    let mut v = rack.to_vec();
    if let Some(i) = v.iter().position(|&x| x == id) {
        v.remove(i);
    }
    v
}

fn from_left(seat: usize) -> String {
    let l = left(seat);
    if l == 0 {
        "Senin attığın".into()
    } else {
        format!("{} attığı", GEN[l])
    }
}

fn use_text(u: Use, t: u8, table: &[TMeld], okey: u8) -> String {
    match u {
        Use::Open { pairs: false, value } => format!("onunla {value} puanla elini açıyor"),
        Use::Open { pairs: true, .. } => "onunla çiftten açıyor".into(),
        Use::Isle => match can_isle(table, t, okey) {
            Some(mi) => format!("{} işleyecek", meld_ref(&table[mi], okey)),
            None => "masaya işleyecek".into(),
        },
        Use::Meld => "elindeki taşlarla yeni per oluyor".into(),
        Use::Pair => "elindeki taşla çift oluyor".into(),
    }
}

/// Information-set draw decision: take the left neighbour's tile only when it can be used now.
pub fn info_draw(info: &Info, lvl: Level, s: &mut MeldSolver, rng: &mut Rng, you: bool) -> DrawChoice {
    let okey = info.okey;
    let pile = |why: String| DrawChoice { take: false, reason: why };
    let Some(t) = info.offer() else {
        return pile(if you { "Ortadan çek: alınacak taş yok".into() } else { "Ortadan çekti".into() });
    };
    let lf = from_left(info.seat);
    let tn = tacc(t, okey);
    match take_use(s, info.rack, t, info.table, info.opened[info.seat], okey) {
        None => {
            let why = if info.opened[info.seat].is_none() {
                format!("{lf} {tn} alsa bu el açması gerekirdi, açamıyor")
            } else {
                format!("{lf} {} hiçbir pere girmiyor", tname(t, okey))
            };
            if you {
                pile(format!("Ortadan çek: {why} (yandan alınan taş hemen kullanılmalı)"))
            } else {
                pile(format!("Ortadan çekti: {why}"))
            }
        }
        Some(u) => {
            if lvl == Level::Easy && rng.chance(0.35) {
                return pile(format!("{lf} {tn} fark etmedi, ortadan çekti"));
            }
            let what = use_text(u, t, info.table, okey);
            DrawChoice { take: true, reason: if you { format!("{lf} {tn} al: {what}") } else { format!("{lf} {tn} aldı: {what}") } }
        }
    }
}

struct Cand {
    id: u8,
    own: f64,
    danger: f64,
    evidence: Option<u8>,
    total: f64,
    pen: Option<&'static str>,
}

/// Score of the tiles kept after discarding (higher is better).
fn eval_rest(s: &mut MeldSolver, rest: &[u8], info: &Info, un: &Unseen, lvl: Level) -> f64 {
    let okey = info.okey;
    let late = if info.pile_count < 8 { 1.0 } else { 0.0 };
    match info.opened[info.seat] {
        None => {
            let h = Hc::of(rest, okey);
            let (sc, shapes) = s.best(&h, Obj::Value);
            let v = sc / 64;
            let (_, loose) = realize(&shapes, rest, okey, None);
            let np = pairs_of(rest, okey).0.len();
            let pb = if np >= 4 && lvl >= Level::Normal { 9.0 * np as f64 } else { 0.0 };
            let pot = if lvl == Level::Easy { 0.0 } else { potential(&loose, okey, un) };
            v as f64 + 0.45 * pot + pb
        }
        Some(kind) => {
            let loose = leftovers(s, rest, info.table, okey, info.seat, kind);
            let f: u32 = loose.iter().map(|&id| face(id, okey)).sum();
            let pot = if lvl == Level::Easy { 0.0 } else { potential(&loose, okey, un) };
            let fw = if lvl >= Level::Hard { 0.5 + 1.5 * late } else { 0.6 };
            -30.0 * loose.len() as f64 - fw * f as f64 + 0.3 * pot
        }
    }
}

/// Expected opening value after one more draw (hard's lookahead, unopened only).
fn expected_value(s: &mut MeldSolver, rest: &[u8], okey: u8, un: &Unseen) -> f64 {
    let h = Hc::of(rest, okey);
    let base = s.value(&h) as f64;
    if un.total == 0 {
        return base;
    }
    let mut near = [false; 52];
    for &id in rest {
        let Some(k) = eff(id, okey) else { continue };
        let (c, n) = (k / 13, k % 13);
        for d in 1..=2u8 {
            if n + d <= 12 {
                near[(c * 13 + n + d) as usize] = true;
            }
            if n >= d {
                near[(c * 13 + n - d) as usize] = true;
            }
        }
        if n >= 11 {
            near[(c * 13) as usize] = true;
        }
        for c2 in 0..4 {
            near[(c2 * 13 + n) as usize] = true;
        }
    }
    let mut tot = 0.0;
    let mut mass = 0u32;
    for (k, &is_near) in near.iter().enumerate() {
        let n = un.k[k];
        if n == 0 || !is_near {
            continue;
        }
        let mut h2 = h;
        h2.c[k] += 1;
        tot += n as f64 * s.value(&h2) as f64;
        mass += n as u32;
    }
    if un.j > 0 {
        let mut h2 = h;
        h2.j += 1;
        tot += un.j as f64 * s.value(&h2) as f64;
        mass += un.j as u32;
    }
    (tot + (un.total - mass.min(un.total)) as f64 * base) / un.total as f64
}

fn finish_text(id: u8, okey: u8, you: bool, pairs: bool) -> String {
    let okd = eff(id, okey).is_none();
    let how = match (okd, pairs) {
        (true, true) => " — okeyle ve çiftten bitiş: el 4 katı",
        (true, false) => " — okeyle bitiş: el 2 katı",
        (false, true) => " — çiftten bitiş: el 2 katı",
        _ => "",
    };
    if you {
        format!("Bitir: son taşın {} at{how}", tacc(id, okey))
    } else {
        format!("Son taşı {} atarak bitirdi{how}", tacc(id, okey))
    }
}

/// Information-set discard decision.
pub fn info_discard(info: &Info, lvl: Level, s: &mut MeldSolver, rng: &mut Rng, you: bool) -> DiscardChoice {
    let okey = info.okey;
    let rack = info.rack;
    if rack.len() == 1 {
        let pairs = info.opened[info.seat] == Some(OpenKind::Pairs);
        return DiscardChoice { id: rack[0], finish: true, reason: finish_text(rack[0], okey, you, pairs) };
    }
    let un = if lvl == Level::Easy { Unseen::flat() } else { Unseen::of(info) };
    let uniq = unique_tiles(rack, okey);
    let has_plain = uniq.iter().any(|&id| eff(id, okey).is_some());
    let careless = lvl == Level::Easy && rng.chance(0.15);
    let n = right(info.seat);
    let w = match lvl {
        Level::Easy => 0.0,
        Level::Normal => 2.0,
        _ => 2.5 * (1.0 + 0.4 * info.taken[n].len() as f64) * if info.pile_count < 8 { 1.5 } else { 1.0 },
    };
    let mut cands: Vec<Cand> = Vec::new();
    for id in uniq {
        if (eff(id, okey).is_none() && has_plain) || info.must_use == Some(id) {
            continue;
        }
        let pen = penalty_of(id, info.table, okey);
        let rest = without(rack, id);
        let mut own = eval_rest(s, &rest, info, &un, lvl);
        if info.opened[info.seat].is_none() {
            own -= 0.08 * face(id, okey) as f64;
        }
        let (dg, evidence) = if lvl >= Level::Normal { danger(info, eff(id, okey)) } else { (0.0, None) };
        let penalty_cost = if pen.is_some() && !careless { 400.0 } else { 0.0 };
        cands.push(Cand { id, own, danger: dg, evidence, total: own - w * dg - penalty_cost, pen });
    }
    if cands.is_empty() {
        // Only the must-use tile is left (cannot happen after a legal take).
        let id = rack[0];
        return DiscardChoice { id, finish: false, reason: format!("{} attı", cap(&tacc(id, okey))) };
    }
    if lvl >= Level::Hard && info.opened[info.seat].is_none() {
        let mut order: Vec<usize> = (0..cands.len()).collect();
        order.sort_by(|&a, &b| cands[b].total.partial_cmp(&cands[a].total).unwrap_or(std::cmp::Ordering::Equal));
        for &i in order.iter().take(4) {
            let rest = without(rack, cands[i].id);
            let ev = expected_value(s, &rest, okey, &un);
            let base = s.value(&Hc::of(&rest, okey)) as f64;
            cands[i].own += 2.0 * (ev - base);
            cands[i].total += 2.0 * (ev - base);
        }
    }
    cands.sort_by(|a, b| b.total.partial_cmp(&a.total).unwrap_or(std::cmp::Ordering::Equal));
    let mut pick = 0usize;
    let mut slip = false;
    if lvl == Level::Easy && cands.len() > 1 {
        let top = cands[0].total;
        let ties = cands.iter().take_while(|c| (c.total - top).abs() < 1.5).count();
        pick = rng.below(ties.max(1));
        if rng.chance(0.18) && cands.len() > ties {
            pick = ties;
            slip = true;
        }
    }
    let chosen = &cands[pick];
    let id = chosen.id;
    let tn = tacc(id, okey);
    let rest = without(rack, id);
    let mut reason = match info.opened[info.seat] {
        None => {
            let h = Hc::of(&rest, okey);
            let (sc, shapes) = s.best(&h, Obj::Value);
            let v = sc / 64;
            let (_, loose) = realize(&shapes, &rest, okey, None);
            let flat = Unseen::flat();
            let linked = potential(&[loose.as_slice(), &[id]].concat(), okey, &flat) - potential(&loose, okey, &flat) > 0.01;
            let base = if slip {
                format!("Dikkatsiz atış: {tn} attı, daha iyisi vardı")
            } else if linked {
                if you {
                    format!("{} at: bağlantıları en zayıf taş", cap(&tn))
                } else {
                    format!("{} attı: bağlantıları en zayıf taştı", cap(&tn))
                }
            } else if you {
                format!("{} at: hiçbir pere bağlanmıyor", cap(&tn))
            } else {
                format!("{} attı: hiçbir pere bağlanmıyordu", cap(&tn))
            };
            if lvl >= Level::Normal && !slip {
                if v >= OPEN_MIN {
                    format!("{base} · elde {v} puanlık dizilim var")
                } else {
                    format!("{base} · en iyi dizilim {v} puan, açmaya {} eksik", OPEN_MIN - v)
                }
            } else {
                base
            }
        }
        Some(kind) => {
            let loose = leftovers(s, &rest, info.table, okey, info.seat, kind);
            let f: u32 = loose.iter().map(|&x| face(x, okey)).sum();
            let base = if slip {
                format!("Dikkatsiz atış: {tn} attı, daha iyisi vardı")
            } else if you {
                format!("{} at: perlere bağlanmıyor, elde kalırsa {} puan yazar", cap(&tn), face(id, okey))
            } else {
                format!("{} attı: perlere bağlanmıyordu, elde kalsa {} puan yazardı", cap(&tn), face(id, okey))
            };
            if lvl >= Level::Normal && !slip {
                format!("{base} · elde {} taş, {} puan kalıyor", loose.len(), f)
            } else {
                base
            }
        }
    };
    if let Some(p) = chosen.pen {
        reason = if p == "okey" {
            "Dikkatsiz atış: okeyi attı — 101 ceza".to_string()
        } else {
            let mi = can_isle(info.table, id, okey).unwrap_or(0);
            format!("Dikkatsiz atış: {tn} attı, oysa {} işlenebilirdi — 101 ceza", meld_ref(&info.table[mi], okey))
        };
    } else if lvl >= Level::Normal && !slip {
        // Notes on a better-looking tile held back: a penalty, or the neighbour.
        let best_own = cands.iter().filter(|c| c.id != id).max_by(|a, b| a.own.partial_cmp(&b.own).unwrap_or(std::cmp::Ordering::Equal));
        if let Some(b) = best_own {
            if b.own > chosen.own + 0.5 {
                let avoided = cap(&tacc(b.id, okey));
                let note = if b.pen == Some("isle") {
                    let mi = can_isle(info.table, b.id, okey).unwrap_or(0);
                    Some(format!("{avoided} {}: {} işlenebilir (101 ceza)", if you { "atma" } else { "atmadı" }, meld_ref(&info.table[mi], okey)))
                } else if b.danger > chosen.danger + 0.5 {
                    let r = right(info.seat);
                    let whom = if r == 0 { "sağındaki oyuncu (sen)".to_string() } else { format!("sağındaki {}", NAMES[r]) };
                    Some(match b.evidence {
                        Some(t) if you => format!("{avoided} atma: sağındaki oyuncu {} aldı, ona yarar", tacc(t, okey)),
                        Some(t) => format!("{avoided} atmadı: {whom} {} aldı, ona yarardı", tacc(t, okey)),
                        None if you => format!("{avoided} atma: sağındaki oyuncuya yarayabilir"),
                        None => format!("{avoided} atmadı: {whom} için tehlikeliydi"),
                    })
                } else {
                    None
                };
                if let Some(n) = note {
                    reason = format!("{reason}. {n}");
                }
            }
        }
    }
    DiscardChoice { id, finish: false, reason }
}

// ---- Omniscient planning (impossible) -----------------------------------------------------------

fn can_open_pool(s: &mut MeldSolver, pool: &[u8], okey: u8) -> bool {
    s.value(&Hc::of(pool, okey)) >= OPEN_MIN || pairs_of(pool, okey).0.len() >= OPEN_PAIRS
}

/// Plan quality of keeping `rest` with known future draws `fut` (higher is better), and the
/// number of draws until the next milestone (opening, or finishing once opened).
fn omni_eval(s: &mut MeldSolver, hand: &Hand, seat: usize, rest: &[u8], fut: &[u8]) -> (f64, Option<usize>) {
    let okey = hand.okey;
    let pool = |t: usize| -> Vec<u8> { rest.iter().chain(fut[..t].iter()).copied().collect() };
    let nf = fut.len();
    match hand.opened[seat] {
        None => {
            let vf = s.value(&Hc::of(&pool(nf), okey));
            if nf == 0 || !can_open_pool(s, &pool(nf), okey) {
                let v0 = s.value(&Hc::of(rest, okey));
                return (-3000.0 + vf as f64 + 0.5 * v0 as f64, None);
            }
            let (mut lo, mut hi) = (1usize, nf);
            while lo < hi {
                let mid = (lo + hi) / 2;
                if can_open_pool(s, &pool(mid), okey) {
                    hi = mid;
                } else {
                    lo = mid + 1;
                }
            }
            (-100.0 * lo as f64 + 0.2 * vf as f64, Some(lo))
        }
        Some(kind) => {
            let f0: u32 = leftovers(s, rest, &hand.table, okey, seat, kind).iter().map(|&id| face(id, okey)).sum();
            let mut u = |t: usize| leftovers(s, &pool(t), &hand.table, okey, seat, kind).len();
            let un = if nf == 0 { usize::MAX } else { u(nf) };
            if nf == 0 || un > nf {
                let un = if nf == 0 { 30 } else { un };
                return (-3000.0 - 30.0 * un as f64 - 0.6 * f0 as f64, None);
            }
            let (mut lo, mut hi) = (1usize, nf);
            while lo < hi {
                let mid = (lo + hi) / 2;
                if u(mid) <= mid {
                    hi = mid;
                } else {
                    lo = mid + 1;
                }
            }
            (-100.0 * lo as f64 - 0.05 * f0 as f64, Some(lo))
        }
    }
}

/// What the right-hand neighbour `n` gains from tile `t` (taken from my discard when `take`, else
/// drawn from the pile): (danger, what it would do).
fn neighbour_gain(s: &mut MeldSolver, hand: &Hand, n: usize, t: u8, take: bool) -> (f64, &'static str) {
    let okey = hand.okey;
    let rack = &hand.racks[n];
    if take && take_use(s, rack, t, &hand.table, hand.opened[n], okey).is_none() {
        return (0.0, "");
    }
    let mut r = rack.clone();
    r.push(t);
    match hand.opened[n] {
        None => {
            if can_open_pool(s, &r, okey) && !can_open_pool(s, rack, okey) {
                (1500.0, "elini açardı")
            } else {
                (0.0, "")
            }
        }
        Some(kind) => {
            let u1 = leftovers(s, &r, &hand.table, okey, n, kind).len();
            if u1 <= 1 {
                return (5000.0, "elini bitirirdi");
            }
            let u0 = leftovers(s, rack, &hand.table, okey, n, kind).len();
            if u1 <= u0 {
                (150.0, "işine yarardı")
            } else {
                (0.0, "")
            }
        }
    }
}

/// Best discard for a rack and known draws: (id, score, milestone, danger, danger text).
fn omni_best(s: &mut MeldSolver, hand: &Hand, seat: usize, rack: &[u8], fut: &[u8], block: bool) -> (u8, f64, Option<usize>, f64, &'static str) {
    let okey = hand.okey;
    let uniq = unique_tiles(rack, okey);
    let has_plain = uniq.iter().any(|&id| eff(id, okey).is_some());
    let mut cands: Vec<u8> = uniq.iter().copied().filter(|&id| (eff(id, okey).is_some() || !has_plain) && hand.must_use != Some(id)).collect();
    let safe: Vec<u8> = cands.iter().copied().filter(|&id| penalty_of(id, &hand.table, okey).is_none()).collect();
    if !safe.is_empty() {
        cands = safe;
    }
    if cands.len() > 9 {
        // Prefer tiles the whole known pool does not need.
        let mut pool: Vec<u8> = rack.to_vec();
        pool.extend_from_slice(fut);
        let obj = if hand.opened[seat].is_some() { Obj::Cover } else { Obj::Value };
        let (_, shapes) = s.best(&Hc::of(&pool, okey), obj);
        let (_, loose) = realize(&shapes, &pool, okey, None);
        let loose_k: Vec<Option<u8>> = loose.iter().map(|&x| eff(x, okey)).collect();
        let opened = hand.opened[seat].is_some();
        cands.sort_by_key(|&id| (!loose_k.contains(&eff(id, okey)), if opened { 20 - face(id, okey) } else { face(id, okey) }));
        cands.truncate(9);
    }
    if cands.is_empty() {
        cands.push(rack[0]);
    }
    let n = right(seat);
    let mut best: Option<(u8, f64, Option<usize>, f64, &'static str)> = None;
    for id in cands {
        let rest = without(rack, id);
        let (sc, t) = omni_eval(s, hand, seat, &rest, fut);
        let (dg, what) = if block { neighbour_gain(s, hand, n, id, true) } else { (0.0, "") };
        let pen = if penalty_of(id, &hand.table, okey).is_some() { 400.0 } else { 0.0 };
        let total = sc - dg - pen;
        if best.as_ref().is_none_or(|b| total > b.1) {
            best = Some((id, total, t, dg, what));
        }
    }
    best.expect("rack has tiles")
}

pub fn omni_discard(hand: &Hand, seat: usize, s: &mut MeldSolver, block: bool) -> DiscardChoice {
    let okey = hand.okey;
    let rack = &hand.racks[seat];
    if rack.len() == 1 {
        let pairs = hand.opened[seat] == Some(OpenKind::Pairs);
        return DiscardChoice { id: rack[0], finish: true, reason: finish_text(rack[0], okey, false, pairs) };
    }
    let fut = hand.future(3, LOOKAHEAD);
    let (id, _, t, dg, what) = omni_best(s, hand, seat, rack, &fut, block);
    let tn = cap(&tacc(id, okey));
    let goal = if hand.opened[seat].is_some() { "bitiriyor" } else { "elini açıyor" };
    let mut reason = match t {
        Some(t) => format!("{tn} attı: destenin sırasını biliyor, {t} çekiş sonra {goal}; bu taş planında yok"),
        None if fut.is_empty() => format!("{tn} attı: deste bitiyor, bu taş elde kalsa {} puan yazardı", face(id, okey)),
        None => format!("{tn} attı: sıradaki {} çekişini biliyor, bu taş hiçbirine bağlanmıyor", fut.len()),
    };
    let r = right(seat);
    let whose = if r == 0 { "senin".to_string() } else { GEN[r].to_string() };
    if dg > 0.0 {
        reason += &format!(" ({whose} {what} ama başka yolu yok)");
    } else if block {
        for alt in unique_tiles(rack, okey) {
            if alt == id || eff(alt, okey).is_none() || penalty_of(alt, &hand.table, okey).is_some() {
                continue;
            }
            let (adg, w) = neighbour_gain(s, hand, r, alt, true);
            if adg > 0.0 {
                reason = format!("Sağındakinin elini görüyor: {} {whose} {w}, onu tutuyor — {reason}", tname(alt, okey));
                break;
            }
        }
    }
    DiscardChoice { id, finish: false, reason }
}

pub fn omni_draw(hand: &Hand, seat: usize, s: &mut MeldSolver, block: bool) -> DrawChoice {
    let okey = hand.okey;
    let rack = &hand.racks[seat];
    let len = hand.pile.len();
    let Some(&p0) = hand.pile.last() else {
        return DrawChoice { take: hand.offer(seat).is_some(), reason: "Ortada taş kalmadı".into() };
    };
    let p1 = if len >= 2 { Some(hand.pile[len - 2]) } else { None };
    let pile_next = tname(p0, okey);
    let r = right(seat);
    let whose = if r == 0 { "senin".to_string() } else { GEN[r].to_string() };
    let usable = hand.offer(seat).filter(|&t| take_use(s, rack, t, &hand.table, hand.opened[seat], okey).is_some());
    let mut ra = rack.clone();
    ra.push(p0);
    let fa = hand.future(4, LOOKAHEAD);
    let (_, sa, ta, _, _) = omni_best(s, hand, seat, &ra, &fa, block);
    let goal = if hand.opened[seat].is_some() { "bitiriyor" } else { "açıyor" };
    let Some(top) = usable else {
        let why = match ta {
            Some(t) => format!("{t} çekiş sonra {goal}"),
            None => "eline en çok bu yarıyor".into(),
        };
        let lead = if hand.offer(seat).is_some() { "Ortadan çekti (yandaki taşı bu el kullanamazdı)" } else { "Ortadan çekti" };
        return DrawChoice { take: false, reason: format!("{lead}: sıradaki taşın {pile_next} olduğunu biliyor; {why}") };
    };
    let (ga, fin_a) = match (block, p1) {
        (true, Some(p)) => neighbour_gain(s, hand, r, p, false),
        _ => (0.0, ""),
    };
    let mut rb = rack.clone();
    rb.push(top);
    let fb = hand.future(3, LOOKAHEAD);
    let (_, sb, tb, _, _) = omni_best(s, hand, seat, &rb, &fb, block);
    let (gb, fin_b) = if block { neighbour_gain(s, hand, r, p0, false) } else { (0.0, "") };
    let score_a = sa - ga;
    let score_b = sb - gb + 1.0; // a usable tile now beats an equal plan later
    let lf = from_left(seat);
    let take = score_b > score_a;
    let blocked = (take && sa > sb) || (!take && sb > sa);
    if take {
        let reason = if blocked && !fin_a.is_empty() {
            let p1n = p1.map(|t| tname(t, okey)).unwrap_or_default();
            format!("{lf} {} aldı: ortadan çekseydi sıradaki {p1n} {whose} {fin_a}", tacc(top, okey))
        } else {
            let when = match tb {
                Some(t) => format!("{t} çekiş sonra {goal}"),
                None => format!("sıradaki taş {pile_next} ondan daha az işine yarıyor"),
            };
            format!("{lf} {} aldı: destenin sırasına göre böylece {when}", tacc(top, okey))
        };
        return DrawChoice { take: true, reason };
    }
    let why = if blocked && !fin_b.is_empty() {
        format!("{pile_next} {whose} {fin_b}, onu kendisi aldı")
    } else {
        match ta {
            Some(t) => format!("böylece {t} çekiş sonra {goal}"),
            None => "eline en çok bu yarıyor".into(),
        }
    };
    DrawChoice { take: false, reason: format!("Ortadan çekti: sıradaki taşın {pile_next} olduğunu biliyor; {why}") }
}

// =================================================================================================
// Rack layout

/// Valid melds (and 2-tile pairs) among the gap-separated segments of the layout, with values.
fn layout_melds101(layout: &[i16; SLOTS], okey: u8) -> Vec<(Vec<usize>, MKind, u32)> {
    let mut out = Vec::new();
    for (slots, _) in layout_melds(layout, okey) {
        let ids: Vec<u8> = slots.iter().map(|&i| layout[i] as u8).collect();
        if let Some(k) = classify(&ids, okey) {
            out.push((slots, k, kind_value(k, ids.len())));
        }
    }
    out
}

/// Groups (kept whole, a gap after each) then loose tiles (contiguous, may wrap rows).
fn place(groups: &[Vec<u8>], loose: &[u8], gaps: bool) -> Option<[i16; SLOTS]> {
    let mut lay = [-1i16; SLOTS];
    let (mut row, mut col) = (0usize, 0usize);
    for g in groups {
        if g.len() > ROW {
            return None;
        }
        if col + g.len() > ROW {
            if row == 1 {
                return None;
            }
            row = 1;
            col = 0;
        }
        for &t in g {
            lay[row * ROW + col] = t as i16;
            col += 1;
        }
        if gaps && col < ROW {
            col += 1;
        }
    }
    for &t in loose {
        if col >= ROW {
            if row == 1 {
                return None;
            }
            row = 1;
            col = 0;
        }
        lay[row * ROW + col] = t as i16;
        col += 1;
    }
    Some(lay)
}

fn pack101(groups: &[Vec<u8>], rest: &[u8], okey: u8) -> [i16; SLOTS] {
    let mut loose: Vec<u8> = rest.to_vec();
    loose.sort_by_key(|&id| sort_key(id, okey));
    place(groups, &loose, true).or_else(|| place(groups, &loose, false)).unwrap_or_else(|| {
        let mut all: Vec<Vec<Option<u8>>> = groups.iter().map(|g| g.iter().map(|&x| Some(x)).collect()).collect();
        all.push(loose.iter().map(|&x| Some(x)).collect());
        pack_layout(&all)
    })
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
    okey_finish: bool,
    pairs: bool,
    mult: i32,
    points: [i32; 4],
    penalties: [i32; 4],
    text: String,
    finish_tile: Option<u8>,
    rests: [Vec<u8>; 4],
}

pub struct Okey101 {
    level: Level,
    seed: u64,
    rng: Rng,
    solver: MeldSolver,
    totals: [i32; 4],
    history: Vec<[i32; 4]>,
    hand_no: u32,
    max_hands: u32,
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
    /// An AI could not use a tile it took (should never happen; tests check it stays 0).
    pub fallbacks: u32,
    no_take: bool,
}

pub fn create(mode: &str) -> Result<Box<dyn Session>, String> {
    let level = match mode {
        "easy" => Level::Easy,
        "normal" => Level::Normal,
        "hard" => Level::Hard,
        "impossible" => Level::Impossible,
        _ => Level::Normal,
    };
    Ok(Box::new(Okey101::new(level, time_seed())))
}

fn kind_str(k: MKind) -> &'static str {
    match k {
        MKind::Run { .. } => "run",
        MKind::Set { .. } => "set",
        MKind::Pair => "pair",
    }
}

impl Okey101 {
    pub fn new(level: Level, seed: u64) -> Okey101 {
        Okey101::with_levels(level, [Level::Hard, level, level, level], seed)
    }

    pub fn with_levels(level: Level, seat_levels: [Level; 4], seed: u64) -> Okey101 {
        let mut rng = Rng::new(seed);
        let starter = rng.below(4);
        let hand = Hand::deal(&mut rng, starter);
        let mut g = Okey101 {
            level,
            seed,
            rng,
            solver: MeldSolver::new(),
            totals: [0; 4],
            history: Vec::new(),
            hand_no: 1,
            max_hands: DEFAULT_HANDS,
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
            fallbacks: 0,
            no_take: false,
        };
        g.after_deal();
        g
    }

    fn after_deal(&mut self) {
        self.layout = super::okey::sorted_layout(&self.hand.racks[0], self.hand.okey);
        self.reasons = Default::default();
        self.hint = None;
        self.no_take = false;
        let ind = tname(self.hand.indicator, self.hand.okey);
        let ok = kname(self.hand.okey);
        let st = self.hand.starter;
        self.push_log(st, "deal", None, None, format!("Gösterge {ind}: okey {ok}"), format!("{} başlıyor (22 taş, ilk o atar)", who(st)));
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

    fn check_play(&self, seat: usize) -> Result<(), String> {
        self.check_turn(seat)?;
        if self.hand.stage == Stage::Draw {
            return Err("Önce bir taş çek".into());
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
        let last = (ROW..SLOTS).rev().find(|&i| self.layout[i] >= 0).unwrap_or(ROW - 1);
        let free = (last + 1..SLOTS).find(|&i| self.layout[i] < 0).or_else(|| (0..SLOTS).find(|&i| self.layout[i] < 0));
        if let Some(f) = free {
            self.layout[f] = id as i16;
        }
    }

    fn remove_tile(&mut self, seat: usize, id: u8) {
        let r = &mut self.hand.racks[seat];
        if let Some(i) = r.iter().position(|&x| x == id) {
            r.remove(i);
        }
        if seat == 0 {
            for s in self.layout.iter_mut() {
                if *s == id as i16 {
                    *s = -1;
                }
            }
        }
    }

    fn draw(&mut self, seat: usize, take: bool, slot: Option<usize>, reason: String) -> Result<(), String> {
        self.check_turn(seat)?;
        if self.hand.stage != Stage::Draw {
            return Err("Şimdi taş çekme sırası değil: bir taş at".into());
        }
        let okey = self.hand.okey;
        let (tile, from) = if take {
            let t = self.hand.offer(seat).ok_or("Alınacak taş yok")?;
            if take_use(&mut self.solver, &self.hand.racks[seat], t, &self.hand.table, self.hand.opened[seat], okey).is_none() {
                return Err(if self.hand.opened[seat].is_none() {
                    format!("{} alamazsın: yandan alınan taşla bu el açmalısın, açamıyorsun", cap(&tacc(t, okey)))
                } else {
                    format!("{} alamazsın: hiçbir pere girmiyor (yandan alınan taş hemen kullanılmalı)", cap(&tacc(t, okey)))
                });
            }
            self.hand.snapshot = Some(Box::new(Snapshot {
                rack: self.hand.racks[seat].clone(),
                table: self.hand.table.clone(),
                opened: self.hand.opened[seat],
                open_value: self.hand.open_value[seat],
                layout: self.layout,
            }));
            let l = left(seat);
            self.hand.discards[l].pop();
            self.hand.taken[seat].push(t);
            self.hand.must_use = Some(t);
            (t, Some(l))
        } else {
            (self.hand.pile.pop().ok_or("Ortada taş kalmadı")?, None)
        };
        self.hand.racks[seat].push(tile);
        self.hand.stage = Stage::Play;
        if seat == 0 {
            self.place_in_layout(tile, slot);
        }
        let w = who(seat);
        let text = if take {
            format!("{w} {} {}", tacc(tile, okey), if seat == 0 { "aldın — bu el kullanmalısın" } else { "aldı" })
        } else if seat == 0 {
            format!("Ortadan {} çektin", tname(tile, okey))
        } else {
            format!("{w} ortadan çekti")
        };
        self.push_log(seat, if take { "take" } else { "pile" }, Some(tile), from, text, reason);
        Ok(())
    }

    fn untake(&mut self, seat: usize) -> Result<(), String> {
        self.check_play(seat)?;
        let Some(t) = self.hand.must_use else { return Err("Geri verilecek taş yok".into()) };
        if !self.hand.racks[seat].contains(&t) {
            return Err("Aldığın taşı kullandın, artık geri veremezsin".into());
        }
        let snap = self.hand.snapshot.take().ok_or("Geri verilecek taş yok")?;
        self.hand.racks[seat] = snap.rack;
        self.hand.table = snap.table;
        self.hand.opened[seat] = snap.opened;
        self.hand.open_value[seat] = snap.open_value;
        if seat == 0 {
            self.layout = snap.layout;
        }
        self.hand.taken[seat].pop();
        self.hand.discards[left(seat)].push(t);
        self.hand.must_use = None;
        self.hand.stage = Stage::Draw;
        self.hand.melded = false;
        let okey = self.hand.okey;
        self.push_log(seat, "untake", Some(t), Some(left(seat)), format!("{} {} geri {}", who(seat), tacc(t, okey), if seat == 0 { "verdin" } else { "verdi" }), String::new());
        Ok(())
    }

    /// Validate laying `groups` now: the melds and the opening kind it sets (if it opens).
    fn check_lay(&self, seat: usize, groups: &[Vec<u8>]) -> Result<(Vec<TMeld>, Option<OpenKind>, u32), String> {
        self.check_play(seat)?;
        let okey = self.hand.okey;
        if groups.is_empty() || groups.iter().any(|g| g.is_empty()) {
            return Err("Önce indirilecek perleri diz".into());
        }
        let rack = &self.hand.racks[seat];
        let mut seen: Vec<u8> = Vec::new();
        for &id in groups.iter().flatten() {
            if !rack.contains(&id) || seen.contains(&id) {
                return Err("Bu taş elinde değil".into());
            }
            seen.push(id);
        }
        if seen.len() >= rack.len() {
            return Err("Son taşı atarak bitirmelisin: elinde bir taş kalmalı".into());
        }
        let mut melds = Vec::new();
        for g in groups {
            let Some(kind) = classify(g, okey) else {
                let names: Vec<String> = g.iter().map(|&t| tname(t, okey)).collect();
                return Err(format!("{} geçerli bir per değil", names.join(", ")));
            };
            melds.push(TMeld { owner: seat, kind, tiles: g.clone() });
        }
        let pairs = melds.iter().filter(|m| m.kind == MKind::Pair).count();
        let value: u32 = melds.iter().map(|m| m.value()).sum();
        match self.hand.opened[seat] {
            None => {
                if pairs == melds.len() {
                    if pairs < OPEN_PAIRS {
                        return Err(format!("Çiftle açmak için en az {OPEN_PAIRS} çift gerekir: seçili {pairs}"));
                    }
                    Ok((melds, Some(OpenKind::Pairs), 0))
                } else if pairs == 0 {
                    if value < OPEN_MIN {
                        return Err(format!("Açmak için {OPEN_MIN} puan gerekir: seçili {value}"));
                    }
                    Ok((melds, Some(OpenKind::Melds), value))
                } else {
                    Err("Açarken ya perler ya çiftler kullanılır, ikisi birden olmaz".into())
                }
            }
            Some(OpenKind::Melds) => {
                if pairs > 0 {
                    return Err("Perle açtın: çift indiremezsin (perlere işleyebilirsin)".into());
                }
                Ok((melds, None, value))
            }
            Some(OpenKind::Pairs) => {
                if pairs != melds.len() {
                    return Err("Çiftle açtın: yalnız çift indirebilirsin (perlere işleyebilirsin)".into());
                }
                Ok((melds, None, 0))
            }
        }
    }

    fn apply_lay(&mut self, seat: usize, melds: Vec<TMeld>, open: Option<OpenKind>, value: u32) {
        for m in &melds {
            for &id in &m.tiles {
                self.remove_tile(seat, id);
            }
        }
        if let Some(k) = open {
            self.hand.opened[seat] = Some(k);
            self.hand.open_value[seat] = value;
        }
        self.hand.table.extend(melds);
    }

    fn lay(&mut self, seat: usize, groups: &[Vec<u8>]) -> Result<(), String> {
        let (melds, open, value) = self.check_lay(seat, groups)?;
        let n = melds.len();
        let pairs = open == Some(OpenKind::Pairs) || melds.iter().all(|m| m.kind == MKind::Pair);
        self.apply_lay(seat, melds, open, value);
        let text = match open {
            Some(OpenKind::Melds) => format!("Elini açtın: {n} per, {value} puan"),
            Some(OpenKind::Pairs) => format!("Elini çiftle açtın: {n} çift"),
            None => format!("{n} {} daha indirdin", if pairs { "çift" } else { "per" }),
        };
        self.push_log(seat, if open.is_some() { "open" } else { "lay" }, None, None, text, String::new());
        Ok(())
    }

    fn check_add(&self, seat: usize, id: u8, mi: usize, end: Option<End>) -> Result<End, String> {
        self.check_play(seat)?;
        let okey = self.hand.okey;
        if self.hand.opened[seat].is_none() {
            return Err("İşlemek için önce elini açmalısın".into());
        }
        let rack = &self.hand.racks[seat];
        if !rack.contains(&id) {
            return Err("Bu taş elinde değil".into());
        }
        if rack.len() < 2 {
            return Err("Son taşı atarak bitirmelisin".into());
        }
        let m = self.hand.table.get(mi).ok_or("Masada böyle bir per yok")?;
        let fits = m.fits(id, okey);
        if fits.is_empty() {
            return Err(format!("{} bu pere uymuyor", cap(&tname(id, okey))));
        }
        Ok(match end {
            Some(e) if fits.contains(&e) => e,
            _ => fits[0],
        })
    }

    fn add(&mut self, seat: usize, id: u8, mi: usize, end: Option<End>, log: bool) -> Result<(), String> {
        let e = self.check_add(seat, id, mi, end)?;
        self.remove_tile(seat, id);
        let okey = self.hand.okey;
        let desc = meld_ref(&self.hand.table[mi], okey);
        self.hand.table[mi].add(id, e);
        if log {
            self.push_log(seat, "add", Some(id), None, format!("{} {} {}", who(seat), tacc(id, okey), format_args!("{desc} {}", if seat == 0 { "işledin" } else { "işledi" })), String::new());
        }
        Ok(())
    }

    fn discard(&mut self, seat: usize, id: u8, force: bool, reason: String) -> Result<(), String> {
        self.check_play(seat)?;
        let okey = self.hand.okey;
        let rack = &self.hand.racks[seat];
        if !rack.contains(&id) {
            return Err("Bu taş elinde değil".into());
        }
        if let Some(t) = self.hand.must_use.filter(|t| rack.contains(t)) {
            return Err(format!("Yandan aldığın {} bu el kullanmalısın: pere koy, işle ya da geri ver", tacc(t, okey)));
        }
        let w = who(seat);
        if rack.len() == 1 {
            self.remove_tile(seat, id);
            let text = format!("{w} {} atarak {}", tacc(id, okey), if seat == 0 { "bitirdin!" } else { "bitirdi!" });
            self.push_log(seat, "finish", Some(id), None, text, reason);
            self.end_hand(Some(seat), eff(id, okey).is_none(), Some(id));
            return Ok(());
        }
        let pen = penalty_of(id, &self.hand.table, okey);
        if let (Some(p), false) = (pen, force) {
            return Err(if p == "okey" {
                "Okeyi atarsan 101 ceza yazarsın — yine de atmak için tekrar at".into()
            } else {
                let mi = can_isle(&self.hand.table, id, okey).unwrap_or(0);
                format!("{} {} işlenebilir: atarsan 101 ceza. Yine de atmak için tekrar at", cap(&tname(id, okey)), meld_ref(&self.hand.table[mi], okey))
            });
        }
        self.remove_tile(seat, id);
        self.hand.discards[seat].push(id);
        self.hand.turns += 1;
        let mut text = format!("{w} {} {}", tacc(id, okey), if seat == 0 { "attın" } else { "attı" });
        if pen.is_some() {
            self.hand.penalties[seat] += PENALTY;
            text += " — 101 ceza";
        }
        self.push_log(seat, "discard", Some(id), None, text, reason);
        if self.hand.pile.is_empty() {
            self.end_hand(None, false, None);
            return Ok(());
        }
        self.hand.turn = right(seat);
        self.hand.stage = Stage::Draw;
        self.hand.must_use = None;
        self.hand.snapshot = None;
        self.hand.melded = false;
        self.no_take = false;
        Ok(())
    }

    fn end_hand(&mut self, winner: Option<usize>, okd: bool, tile: Option<u8>) {
        let okey = self.hand.okey;
        let pairs = winner.is_some_and(|w| self.hand.opened[w] == Some(OpenKind::Pairs));
        let mult = (if okd { 2 } else { 1 }) * (if pairs { 2 } else { 1 });
        let mut points = [0i32; 4];
        for (s, p) in points.iter_mut().enumerate() {
            *p = if winner == Some(s) {
                FINISH_POINTS * mult
            } else if self.hand.opened[s].is_some() {
                self.hand.racks[s].iter().map(|&id| face(id, okey) as i32).sum::<i32>() * mult
            } else {
                UNOPENED * mult
            };
            *p += self.hand.penalties[s];
            self.totals[s] += *p;
        }
        self.history.push(points);
        let text = match winner {
            Some(w) => {
                self.wins[w] += 1;
                let how = match (okd, pairs) {
                    (true, true) => " okeyle ve çiftten",
                    (true, false) => " okeyle",
                    (false, true) => " çiftten",
                    _ => "",
                };
                let dbl = if mult > 1 { format!(" — el {mult} katı") } else { String::new() };
                format!("{}{how} {}{dbl}", who(w), if w == 0 { "bitirdin!" } else { "bitirdi!" })
            }
            None => "Ortada taş kalmadı: herkes elindekini yazar".into(),
        };
        self.hand_end = true;
        self.hint = None;
        self.result = Some(HandResult {
            winner,
            okey_finish: okd,
            pairs,
            mult,
            points,
            penalties: self.hand.penalties,
            text,
            finish_tile: tile,
            rests: self.hand.racks.clone(),
        });
        self.match_over = self.hand_no >= self.max_hands;
    }

    fn next_hand(&mut self) -> Result<(), String> {
        if !self.hand_end || self.final_status.is_some() {
            return Err("El sürüyor".into());
        }
        if self.match_over {
            let mine = self.totals[0];
            let best_other = self.totals[1..].iter().copied().min().unwrap_or(0);
            self.final_status = Some(if mine < best_other {
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

    /// Lay a plan (opening, further melds, işleme) as one logged step.
    fn apply_plan(&mut self, seat: usize, plan: &MeldPlan, reason: String) -> Result<(), String> {
        let okey = self.hand.okey;
        let before = self.hand.table.clone();
        let text = format!("{}: {}", who(seat), plan_text(plan, &before, okey, seat, false));
        let base = self.hand.table.len();
        let oc = plan.open_count.min(plan.groups.len());
        if oc > 0 {
            let (m, o, v) = self.check_lay(seat, &plan.groups[..oc])?;
            self.apply_lay(seat, m, o, v);
        }
        if plan.groups.len() > oc {
            let (m, o, v) = self.check_lay(seat, &plan.groups[oc..])?;
            self.apply_lay(seat, m, o, v);
        }
        debug_assert_eq!(self.hand.table.len(), base + plan.groups.len());
        for &(id, mi, e) in &plan.adds {
            self.add(seat, id, mi, Some(e), false)?;
        }
        let kind = if plan.open.is_some() { "open" } else if plan.groups.is_empty() { "add" } else { "lay" };
        let tile = plan.adds.first().map(|a| a.0);
        self.push_log(seat, kind, tile, None, text, reason);
        Ok(())
    }

    fn plan_reason(&self, seat: usize, plan: &MeldPlan) -> String {
        let okey = self.hand.okey;
        let mut parts = Vec::new();
        match plan.open {
            Some(OpenKind::Melds) => parts.push(format!(
                "{} puanlık dizilim hazırdı: hemen açmak 202 cezasından kurtarır ve işleme yolunu açar",
                plan.value
            )),
            Some(OpenKind::Pairs) => parts.push(format!("{} çifti vardı, perle 101'e ulaşamıyordu: çiftten açtı (bitirirse el 2 katı)", plan.open_count)),
            None => {}
        }
        if plan.groups.len() > plan.open_count {
            parts.push("elde kalan her taş el sonunda puan yazar, indirebildiğini indirdi".to_string());
        }
        if let Some(&(id, _, _)) = plan.adds.first() {
            let t = cap(&tname(id, okey));
            parts.push(format!("{t} masaya uyuyordu: atsaydı 101 ceza yazardı, elde kalsa puan"));
        }
        if let Some(t) = self.hand.must_use {
            if plan.groups.iter().flatten().chain(plan.adds.iter().map(|a| &a.0)).any(|&x| x == t) {
                parts.push(format!("yandan aldığı {} kullandı", tacc(t, okey)));
            }
        }
        let _ = seat;
        cap(&parts.join("; "))
    }

    /// One AI step for `seat`: a draw, a meld step (opening / laying / işleme), or a discard.
    pub fn ai_step(&mut self, seat: usize) -> Result<(), String> {
        self.check_turn(seat)?;
        let lvl = self.seat_levels[seat];
        let r = right(seat);
        let block = r == 0 || self.seat_levels[r] != Level::Impossible;
        if self.hand.stage == Stage::Draw {
            let ch = if lvl == Level::Impossible {
                omni_draw(&self.hand, seat, &mut self.solver, block)
            } else {
                let info = self.hand.info(seat);
                info_draw(&info, lvl, &mut self.solver, &mut self.rng, false)
            };
            if ch.take && !self.no_take && self.hand.offer(seat).is_some() && self.draw(seat, true, None, ch.reason.clone()).is_ok() {
                return Ok(());
            }
            let reason = if ch.take { "Ortadan çekti".to_string() } else { ch.reason };
            return self.draw(seat, false, None, reason);
        }
        if !self.hand.melded {
            self.hand.melded = true;
            let extras = !(lvl == Level::Easy && self.rng.chance(0.3));
            let plan = plan_melds(&mut self.solver, &self.hand.racks[seat], &self.hand.table, self.hand.opened[seat], self.hand.must_use, self.hand.okey, seat, extras);
            if !plan.is_empty() {
                let reason = self.plan_reason(seat, &plan);
                let snapshot = (self.hand.racks[seat].clone(), self.hand.table.clone(), self.hand.opened[seat], self.hand.open_value[seat]);
                match self.apply_plan(seat, &plan, reason) {
                    Ok(()) => return Ok(()),
                    Err(_) => {
                        self.fallbacks += 1;
                        self.hand.racks[seat] = snapshot.0;
                        self.hand.table = snapshot.1;
                        self.hand.opened[seat] = snapshot.2;
                        self.hand.open_value[seat] = snapshot.3;
                    }
                }
            }
        }
        if self.hand.must_use.is_some_and(|t| self.hand.racks[seat].contains(&t)) {
            // Could not use the taken tile: give it back and draw from the pile instead.
            self.fallbacks += 1;
            self.untake(seat)?;
            self.no_take = true;
            return Ok(());
        }
        let ch = if lvl == Level::Impossible {
            omni_discard(&self.hand, seat, &mut self.solver, block)
        } else {
            let info = self.hand.info(seat);
            info_discard(&info, lvl, &mut self.solver, &mut self.rng, false)
        };
        self.discard(seat, ch.id, true, ch.reason)
    }

    fn compute_hint(&mut self) -> Result<(), String> {
        self.check_turn(0)?;
        let mut rng = Rng::new(self.seed ^ self.serial as u64);
        let okey = self.hand.okey;
        if self.hand.stage == Stage::Draw {
            let info = self.hand.info(0);
            let ch = info_draw(&info, Level::Hard, &mut self.solver, &mut rng, true);
            let tile = if ch.take { self.hand.offer(0) } else { None };
            self.hint = Some((if ch.take { "take".into() } else { "pile".into() }, tile, ch.reason));
            return Ok(());
        }
        let plan = plan_melds(&mut self.solver, &self.hand.racks[0], &self.hand.table, self.hand.opened[0], self.hand.must_use, okey, 0, true);
        if !plan.is_empty() {
            let text = plan_text(&plan, &self.hand.table, okey, 0, true);
            let (kind, tile, tail) = if plan.open.is_some() {
                ("open", None, " — \"Açılabilir mi?\" ile diz, sonra Aç")
            } else if !plan.groups.is_empty() {
                ("lay", None, " — \"Açılabilir mi?\" ile diz, sonra İndir")
            } else {
                ("add", Some(plan.adds[0].0), " — taşı masadaki perin üstüne sürükle")
            };
            self.hint = Some((kind.into(), tile, format!("{text}{tail}")));
            return Ok(());
        }
        let info = self.hand.info(0);
        let ch = info_discard(&info, Level::Hard, &mut self.solver, &mut rng, true);
        self.hint = Some((if ch.finish { "finish".into() } else { "discard".into() }, Some(ch.id), ch.reason));
        Ok(())
    }

    /// "Açılabilir mi?": arrange the best opening (or further melds) and explain it.
    fn suggest(&mut self) -> Result<(), String> {
        if !self.playing() {
            return Err("El bitti".into());
        }
        let okey = self.hand.okey;
        let rack = self.hand.racks[0].clone();
        let must = if self.hand.turn == 0 { self.hand.must_use } else { None };
        let plan = plan_melds(&mut self.solver, &rack, &self.hand.table, self.hand.opened[0], must, okey, 0, true);
        let text;
        if !plan.groups.is_empty() {
            let used: Vec<u8> = plan.groups.iter().flatten().copied().collect();
            let mut rest: Vec<u8> = rack.iter().copied().filter(|x| !used.contains(x)).collect();
            // İşlenecek tiles go first among the loose ones.
            rest.sort_by_key(|x| !plan.adds.iter().any(|a| a.0 == *x));
            self.layout = pack101(&plan.groups, &rest, okey);
            let tail = if self.hand.turn == 0 && self.hand.stage == Stage::Play { "" } else { " (sıran gelince)" };
            text = match plan.open {
                Some(OpenKind::Melds) => format!("Açabilirsin{tail}: {} per, {} puan — Aç'a bas", plan.open_count, plan.value),
                Some(OpenKind::Pairs) => format!("Çiftle açabilirsin{tail}: {} çift — Aç'a bas", plan.open_count),
                None => format!("{} {} daha indirebilirsin{tail} — İndir'e bas", plan.groups.len(), if plan.groups[0].len() == 2 { "çift" } else { "per" }),
            };
        } else {
            let h = Hc::of(&rack, okey);
            let obj = if self.hand.opened[0].is_some() { Obj::Cover } else { Obj::Value };
            let (_, shapes) = self.solver.best(&h, obj);
            let (groups, rest) = realize(&shapes, &rack, okey, None);
            let v = groups_value(&groups, okey);
            let np = pairs_of(&rack, okey).0.len();
            if self.hand.opened[0].is_none() {
                if np >= 4 && v < 80 {
                    let (pairs, singles) = pairs_of(&rack, okey);
                    self.layout = pack101(&pairs, &singles, okey);
                } else {
                    self.layout = pack101(&groups, &rest, okey);
                }
                text = format!("Henüz açamazsın: en iyi dizilim {v} puan ({OPEN_MIN} gerekir) · {np} çift ({OPEN_PAIRS} gerekir)");
            } else if let Some(&(id, mi, _)) = plan.adds.first() {
                text = format!("İndirecek per yok; {} {} işleyebilirsin (sürükle)", tacc(id, okey), meld_ref(&self.hand.table[mi], okey));
            } else {
                self.layout = pack101(&groups, &rest, okey);
                text = "İndirecek per ya da işlenecek taş yok".into();
            }
        }
        self.hint = Some(("suggest".into(), None, text));
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

    fn parse_groups(v: &Value) -> Result<Vec<Vec<u8>>, String> {
        let arr = v.as_array().ok_or("Geçersiz per")?;
        let mut out = Vec::new();
        for g in arr {
            let ga = g.as_array().ok_or("Geçersiz per")?;
            let mut ids = Vec::new();
            for x in ga {
                let id = x.as_u64().ok_or("Geçersiz per")?;
                if id >= N_TILES as u64 {
                    return Err("Bu taş elinde değil".into());
                }
                ids.push(id as u8);
            }
            out.push(ids);
        }
        Ok(out)
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
        if a["suggest"].as_bool() == Some(true) {
            return self.suggest();
        }
        if a["next"].as_bool() == Some(true) {
            return self.next_hand();
        }
        if a["untake"].as_bool() == Some(true) {
            self.untake(0)?;
            self.hint = None;
            return Ok(());
        }
        if let Some(n) = a["hands"].as_u64() {
            if self.hand_no != 1 || self.hand_end || self.final_status.is_some() {
                return Err("El sayısı yalnız ilk elde seçilir".into());
            }
            if !HAND_CHOICES.contains(&(n as u32)) {
                return Err("Geçersiz el sayısı".into());
            }
            self.max_hands = n as u32;
            return Ok(());
        }
        if let Some(arr) = a.get("arrange") {
            return self.arrange(arr);
        }
        if let Some(m) = a["auto_arrange"].as_str() {
            if !self.playing() {
                return Err("El bitti".into());
            }
            let okey = self.hand.okey;
            let rack = self.hand.racks[0].clone();
            self.layout = if m == "pairs" {
                let (p, rest) = pairs_of(&rack, okey);
                pack101(&p, &rest, okey)
            } else {
                let obj = if self.hand.opened[0].is_some() { Obj::Cover } else { Obj::Value };
                let (_, shapes) = self.solver.best(&Hc::of(&rack, okey), obj);
                let (g, rest) = realize(&shapes, &rack, okey, None);
                pack101(&g, &rest, okey)
            };
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
        if let Some(g) = a.get("lay") {
            let groups = Self::parse_groups(g)?;
            self.lay(0, &groups)?;
            self.hint = None;
            return Ok(());
        }
        if let Some(o) = a.get("add") {
            let id = o["tile"].as_u64().filter(|&x| x < N_TILES as u64).ok_or("Bu taş elinde değil")? as u8;
            let mi = o["meld"].as_u64().ok_or("Masada böyle bir per yok")? as usize;
            let end = match o["end"].as_str() {
                Some("low") => Some(End::Low),
                Some("high") => Some(End::High),
                _ => None,
            };
            self.add(0, id, mi, end, true)?;
            self.hint = None;
            return Ok(());
        }
        if let Some(id) = a["discard"].as_u64() {
            if id >= N_TILES as u64 {
                return Err("Bu taş elinde değil".into());
            }
            let force = a["force"].as_bool() == Some(true);
            self.discard(0, id as u8, force, String::new())?;
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

impl Session for Okey101 {
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
                    "score": self.totals[s],
                    "hand": h.penalties[s],
                    "count": h.racks[s].len(),
                    "tiles": tiles,
                    "discards": h.discards[s],
                    "taken": h.taken[s],
                    "reason": self.reasons[s],
                    "wins": self.wins[s],
                    "opened": h.opened[s].is_some(),
                    "open_kind": h.opened[s].map(|k| if k == OpenKind::Melds { "melds" } else { "pairs" }),
                    "open_value": h.open_value[s],
                })
            })
            .collect();
        let melds: Vec<Value> = layout_melds101(&self.layout, okey)
            .into_iter()
            .map(|(slots, k, v)| json!({"slots": slots, "kind": kind_str(k), "value": v}))
            .collect();
        let table: Vec<Value> =
            h.table.iter().map(|m| json!({"owner": m.owner, "kind": kind_str(m.kind), "tiles": m.tiles, "value": m.value()})).collect();
        let pile: Vec<u8> = h.pile.iter().rev().copied().collect();
        let your_turn = playing && h.turn == 0;
        let your_play = your_turn && h.stage == Stage::Play;
        let penalty_tiles: Vec<u8> = if your_play { h.racks[0].iter().copied().filter(|&id| penalty_of(id, &h.table, okey).is_some()).collect() } else { vec![] };
        let addable: Vec<Value> = if your_play && h.opened[0].is_some() && h.racks[0].len() >= 2 {
            h.racks[0]
                .iter()
                .filter_map(|&id| {
                    let ms: Vec<usize> = (0..h.table.len()).filter(|&i| !h.table[i].fits(id, okey).is_empty()).collect();
                    if ms.is_empty() {
                        None
                    } else {
                        Some(json!({"tile": id, "melds": ms}))
                    }
                })
                .collect()
        } else {
            vec![]
        };
        let result = self.result.as_ref().map(|r| {
            json!({
                "winner": r.winner,
                "okey_finish": r.okey_finish,
                "pairs": r.pairs,
                "mult": r.mult,
                "points": r.points,
                "deltas": r.points,
                "penalties": r.penalties,
                "text": r.text,
                "finish_tile": r.finish_tile,
                "rests": r.rests,
                "groups": Vec::<Vec<u8>>::new(),
                "scores": self.totals,
            })
        });
        let summary = if self.match_over || self.final_status.is_some() {
            Some(format!(
                "Toplamın {} · {} {} · {} {} · {} {} (düşük kazanır)",
                self.totals[0], NAMES[1], self.totals[1], NAMES[2], self.totals[2], NAMES[3], self.totals[3]
            ))
        } else {
            None
        };
        let mut v = json!({
            "status": status,
            "stars": 0,
            "variant": "101",
            "title": format!("El {}/{}", self.hand_no, self.max_hands),
            "goal": "101 puanla elini aç, işle, ilk sen bitir",
            "summary": summary,
            "mode": format!("101_{}", self.level.id()),
            "mode_label": format!("101 · {}", self.level.label()),
            "seed": self.seed.to_string(),
            "hand_no": self.hand_no,
            "max_hands": self.max_hands,
            "hand_choices": HAND_CHOICES,
            "phase": if self.hand_end || self.final_status.is_some() { "hand_end" } else { "play" },
            "turn": if h.turn == 0 { "you" } else { "ai" },
            "seat": h.turn,
            "stage": if h.stage == Stage::Draw { "draw" } else { "discard" },
            "ai_pending": playing && h.turn != 0,
            "starter": h.starter,
            "seats": seats,
            "layout": self.layout.to_vec(),
            "melds": melds,
            "table": table,
            "need": OPEN_MIN,
            "need_pairs": OPEN_PAIRS,
            "indicator": h.indicator,
            "okey": {"kind": okey, "color": okey / 13, "number": okey % 13 + 1},
            "pile_count": h.pile.len(),
            "pile": pile,
        });
        let more = json!({
            "can_take": your_turn && h.stage == Stage::Draw && h.offer(0).is_some(),
            "take_tile": h.offer(0),
            "must_use": if your_turn { h.must_use.filter(|t| h.racks[0].contains(t)) } else { None },
            "can_untake": your_play && h.must_use.is_some_and(|t| h.racks[0].contains(&t)),
            "penalty_tiles": penalty_tiles,
            "addable": addable,
            "history": self.history,
            "last": self.last.as_ref().map(last_json),
            "log": self.log.iter().rev().take(12).map(last_json).collect::<Vec<_>>(),
            "hint": self.hint.as_ref().map(|(k, t, txt)| json!({"kind": k, "tile": t, "text": txt})),
            "result": result,
            "match_over": self.match_over,
            "version": self.version,
        });
        if let (Some(m), Value::Object(extra)) = (v.as_object_mut(), more) {
            m.extend(extra);
        }
        v
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
    use std::collections::HashMap;

    /// Tile id from colour (0..4), number (1..13), copy (0/1).
    fn t(c: u8, n: u8, copy: u8) -> u8 {
        copy * 52 + c * 13 + (n - 1)
    }
    const R: u8 = 0;
    const K: u8 = 1;
    const B: u8 = 2;
    const Y: u8 = 3;
    /// Okey = yellow 13 (indicator yellow 12): ids 51 and 103 are wild, 104/105 play as yellow 13.
    const OKEY: u8 = 3 * 13 + 12;
    const OK1: u8 = 51;
    const OK2: u8 = 103;

    fn kinds(ids: &[u8]) -> Option<MKind> {
        classify(ids, OKEY)
    }

    #[test]
    fn deal_sizes_and_tile_set() {
        let mut rng = Rng::new(5);
        let h = Hand::deal(&mut rng, 1);
        let mut all: Vec<u8> = h.racks.iter().flatten().copied().collect();
        all.extend(&h.pile);
        all.push(h.indicator);
        all.sort();
        assert_eq!(all, (0..106).collect::<Vec<u8>>());
        assert_eq!(h.racks[1].len(), 22);
        assert_eq!(h.racks[0].len(), 21);
        assert_eq!(h.pile.len(), 20);
        assert_eq!(h.stage, Stage::Play, "the starter discards first");
        assert_eq!(h.okey, okey_of(h.indicator));
    }

    #[test]
    fn deterministic_deals_and_play() {
        let a = Okey101::new(Level::Normal, 42);
        let b = Okey101::new(Level::Normal, 42);
        assert_eq!(a.state(), b.state());
        let c = Okey101::new(Level::Normal, 43);
        assert_ne!(a.state()["seats"], c.state()["seats"]);
        // The same seed plays the same AI moves.
        let mut a = Okey101::with_levels(Level::Hard, [Level::Hard; 4], 7);
        let mut b = Okey101::with_levels(Level::Hard, [Level::Hard; 4], 7);
        for _ in 0..40 {
            if !a.playing() {
                break;
            }
            let s = a.hand.turn;
            a.ai_step(s).unwrap();
            b.ai_step(s).unwrap();
        }
        assert_eq!(a.state(), b.state());
    }

    #[test]
    fn meld_validation_and_values() {
        let run = [t(R, 1, 0), t(R, 2, 0), t(R, 3, 0)];
        assert_eq!(kinds(&run), Some(MKind::Run { col: R, start: 0 }));
        let wrap = [t(B, 11, 0), t(B, 12, 0), t(B, 13, 0), t(B, 1, 0)];
        assert_eq!(kinds(&wrap), Some(MKind::Run { col: B, start: 10 }));
        assert_eq!(kind_value(kinds(&wrap).unwrap(), 4), 11 + 12 + 13 + 1);
        assert_eq!(kinds(&[t(B, 13, 0), t(B, 1, 0), t(B, 2, 0)]), None, "13-1-2 is not a run");
        assert_eq!(kinds(&[t(K, 7, 0), t(B, 7, 0), t(Y, 7, 0)]), Some(MKind::Set { num: 6 }));
        assert_eq!(kinds(&[t(K, 7, 0), t(K, 7, 1), t(Y, 7, 0)]), None, "a set repeats no colour");
        assert_eq!(kinds(&[t(K, 7, 0), t(B, 7, 0), t(Y, 7, 0), t(R, 7, 0), t(R, 7, 1)]), None);
        // The okey stands for the tile it replaces, also in points.
        let gap = [t(R, 5, 0), OK1, t(R, 7, 0)];
        assert_eq!(kind_value(kinds(&gap).unwrap(), 3), 18);
        let low = [OK1, t(R, 5, 0), t(R, 6, 0)];
        assert_eq!(kinds(&low), Some(MKind::Run { col: R, start: 3 }));
        assert_eq!(kind_value(kinds(&low).unwrap(), 3), 15);
        let set_ok = [t(K, 9, 0), OK2, t(B, 9, 0)];
        assert_eq!(kind_value(kinds(&set_ok).unwrap(), 3), 27);
        // False jokers play as yellow 13 and are not wild.
        assert_eq!(kinds(&[t(Y, 11, 0), t(Y, 12, 0), 104]), Some(MKind::Run { col: Y, start: 10 }));
        assert_eq!(kinds(&[t(R, 1, 0), 104, t(R, 3, 0)]), None);
        // Pairs.
        assert_eq!(kinds(&[t(R, 5, 0), t(R, 5, 1)]), Some(MKind::Pair));
        assert_eq!(kinds(&[t(R, 5, 0), OK1]), Some(MKind::Pair));
        assert_eq!(kinds(&[104, 105]), Some(MKind::Pair));
        assert_eq!(kinds(&[t(R, 5, 0), t(R, 6, 0)]), None);
        // A 1 may not appear twice in a run.
        let mut long: Vec<u8> = (1..=13).map(|n| t(R, n, 0)).collect();
        assert!(kinds(&long).is_some());
        long.push(t(R, 1, 1));
        assert_eq!(kinds(&long), None);
    }

    /// Independent oracle: every subset that forms a meld (in some order), then an exact packing.
    fn subset_meld(ids: &[u8], okey: u8) -> Option<u32> {
        let e: Vec<Option<u8>> = ids.iter().map(|&i| eff(i, okey)).collect();
        let reals: Vec<u8> = e.iter().flatten().copied().collect();
        let n = ids.len();
        if n < 3 || reals.is_empty() {
            return None;
        }
        let mut best: Option<u32> = None;
        let num = reals[0] % 13;
        let mut cols: Vec<u8> = reals.iter().map(|k| k / 13).collect();
        cols.sort();
        cols.dedup();
        if n <= 4 && reals.iter().all(|k| k % 13 == num) && cols.len() == reals.len() {
            best = Some((num as u32 + 1) * n as u32);
        }
        let col = reals[0] / 13;
        if reals.iter().all(|k| k / 13 == col) {
            for st in 0..=13usize {
                let end = st + n - 1;
                if end > 13 || (st == 0 && end == 13) {
                    continue;
                }
                let mut used = [false; 14];
                let ok = reals.iter().all(|&k| {
                    let num = (k % 13) as usize;
                    let p = if num >= st && num <= end { num } else if num == 0 && end == 13 { 13 } else { return false };
                    !std::mem::replace(&mut used[p], true)
                });
                if ok {
                    let v = run_value(st as u8, n);
                    best = Some(best.map_or(v, |b| b.max(v)));
                }
            }
        }
        best
    }

    fn oracle(rack: &[u8], okey: u8) -> (u32, u32) {
        let n = rack.len();
        let mut melds: Vec<(u32, u32, u32)> = Vec::new(); // mask, value, count
        for m in 1u32..(1 << n) {
            if m.count_ones() < 3 {
                continue;
            }
            let ids: Vec<u8> = (0..n).filter(|i| m >> i & 1 == 1).map(|i| rack[i]).collect();
            if let Some(v) = subset_meld(&ids, okey) {
                melds.push((m, v, m.count_ones()));
            }
        }
        // Max value, and max (count, value), over disjoint melds: branch on the lowest free tile.
        let mut by_low: Vec<Vec<(u32, u32, u32)>> = vec![Vec::new(); n];
        for &(m, v, c) in &melds {
            by_low[m.trailing_zeros() as usize].push((m, v, c));
        }
        fn go(used: u32, n: usize, by_low: &[Vec<(u32, u32, u32)>], memo: &mut HashMap<u32, (u32, u32)>) -> (u32, u32) {
            let free = !used & ((1u32 << n) - 1);
            if free == 0 {
                return (0, 0);
            }
            if let Some(&v) = memo.get(&used) {
                return v;
            }
            let i = free.trailing_zeros() as usize;
            let mut best = go(used | 1 << i, n, by_low, memo);
            for &(m, v, c) in &by_low[i] {
                if m & used == 0 {
                    let r = go(used | m, n, by_low, memo);
                    best.0 = best.0.max(r.0 + v);
                    best.1 = best.1.max(r.1 + c * 1024 + v);
                }
            }
            memo.insert(used, best);
            best
        }
        let mut memo = HashMap::new();
        go(0, n, &by_low, &mut memo)
    }

    #[test]
    fn solver_matches_brute_force_oracle() {
        let mut rng = Rng::new(17);
        let mut s = MeldSolver::new();
        let mut nonzero = 0;
        for trial in 0..400 {
            // Dense racks: two colours, a narrow number band, sometimes okeys.
            let okey = OKEY;
            let mut pool: Vec<u8> = Vec::new();
            let c1 = rng.below(4) as u8;
            let c2 = (c1 + 1 + rng.below(3) as u8) % 4;
            let lo = 1 + rng.below(9) as u8;
            for c in [c1, c2, (c2 + 1) % 4] {
                for n in lo..=(lo + 4).min(13) {
                    pool.push(t(c, n, 0));
                    pool.push(t(c, n, 1));
                }
            }
            for c in 0..3u8 {
                pool.push(t(c, 12, 0));
                pool.push(t(c, 13, 0));
                pool.push(t(c, 1, 0));
            }
            pool.retain(|&id| eff(id, okey).is_some());
            pool.sort();
            pool.dedup();
            rng.shuffle(&mut pool);
            let n = 9 + trial % 4;
            let mut rack: Vec<u8> = pool[..n].to_vec();
            match trial % 5 {
                0 => rack[0] = OK1,
                1 => {
                    rack[0] = OK1;
                    rack[1] = OK2;
                }
                2 => rack[0] = 104,
                _ => {}
            }
            let (ov, oc) = oracle(&rack, okey);
            let h = Hc::of(&rack, okey);
            assert_eq!(s.value(&h), ov, "value of {rack:?}");
            assert_eq!(s.score(&h, Obj::Cover), oc, "cover of {rack:?}");
            let (sc, shapes) = s.best(&h, Obj::Value);
            assert_eq!(sc / 64, shapes.iter().map(|x| x.value()).sum::<u32>());
            let (groups, _) = realize(&shapes, &rack, okey, None);
            for g in &groups {
                assert!(classify(g, okey).is_some(), "realized group {g:?} is a meld");
            }
            if ov > 0 {
                nonzero += 1;
            }
        }
        assert!(nonzero > 250, "too few racks with melds: {nonzero}");
    }

    #[test]
    fn opening_value_and_forced_partition() {
        let mut s = MeldSolver::new();
        let base = vec![
            t(R, 1, 0), t(R, 2, 0), t(R, 3, 0), // 6
            t(K, 7, 0), t(B, 7, 0), t(Y, 7, 0), t(R, 7, 0), // 28
            t(B, 10, 0), t(B, 11, 0), t(B, 12, 0), t(B, 13, 0), // 46
            t(K, 4, 0), t(B, 4, 1), t(Y, 4, 1), // 12
            t(R, 9, 0), t(K, 11, 0),
        ];
        assert_eq!(s.value(&Hc::of(&base, OKEY)), 92);
        let mut with = base.clone();
        with.push(OK1);
        // Okey as red 8: red 7-8-9 (24) instead of the red 7 in the 7s set (-7) = 109.
        assert_eq!(s.value(&Hc::of(&with, OKEY)), 109);
        // Forced: a black 11 only forms nothing — no meld contains it.
        assert!(s.forced(&Hc::of(&with, OKEY), K * 13 + 10, Obj::Value).is_none_or(|x| x.1.slots().contains(&Some(K * 13 + 10))));
        // A red 8 taken: red 7-8-9 instead of the 7's set? 7s set (28) vs run 7-8-9 (24) + 7s set
        // without red (21): forced value with the red 8 = 6 + 21 + 24 + 46 + 12 = 109 (+okey 9).
        let mut w2 = with.clone();
        w2.push(t(R, 8, 0));
        let h2 = Hc::of(&w2, OKEY);
        let (sc, sh, rest) = s.forced(&h2, R * 13 + 7, Obj::Value).unwrap();
        assert!(sh.slots().contains(&Some(R * 13 + 7)));
        assert_eq!(sc / 64, sh.value() + rest.iter().map(|x| x.value()).sum::<u32>());
        assert!(sc / 64 >= 110, "forced value {}", sc / 64);
        // Pairs.
        let mut pr = Vec::new();
        for (c, n) in [(R, 1), (K, 5), (B, 9), (Y, 2)] {
            pr.push(t(c, n, 0));
            pr.push(t(c, n, 1));
        }
        pr.push(t(B, 3, 0));
        pr.push(OK1);
        pr.push(t(R, 11, 0));
        let (pairs, singles) = pairs_of(&pr, OKEY);
        assert_eq!(pairs.len(), 5);
        assert_eq!(singles.len(), 1);
        assert!(pairs.iter().any(|p| p.contains(&OK1) && p.contains(&t(R, 11, 0))), "okey pairs the highest single");
    }

    // ---- session helpers --------------------------------------------------------------------

    /// Give `seat` exactly `rack` at its play stage with okey = yellow 13 (tiles taken from wherever
    /// they were).
    fn rig(g: &mut Okey101, seat: usize, rack: &[u8]) {
        let ind = t(Y, 12, 1);
        for s in 0..4 {
            g.hand.racks[s].retain(|x| !rack.contains(x) && *x != ind);
            g.hand.discards[s].retain(|x| !rack.contains(x));
        }
        g.hand.pile.retain(|x| !rack.contains(x) && *x != ind);
        g.hand.indicator = ind;
        g.hand.okey = OKEY;
        g.hand.racks[seat] = rack.to_vec();
        g.hand.turn = seat;
        g.hand.stage = Stage::Play;
        g.hand.must_use = None;
        if seat == 0 {
            g.layout = super::super::okey::sorted_layout(rack, OKEY);
        }
    }

    fn sess(seed: u64) -> Okey101 {
        Okey101::new(Level::Normal, seed)
    }

    fn opening_rack() -> Vec<u8> {
        vec![
            t(R, 1, 0), t(R, 2, 0), t(R, 3, 0),
            t(K, 7, 0), t(B, 7, 0), t(Y, 7, 0), t(R, 7, 0),
            t(B, 10, 0), t(B, 11, 0), t(B, 12, 0), t(B, 13, 0),
            t(K, 4, 0), t(B, 4, 1), t(Y, 4, 1),
            t(R, 9, 0), t(K, 11, 0), OK1, t(Y, 2, 0), t(K, 2, 1), t(R, 12, 1), t(B, 6, 1), t(K, 13, 1),
        ]
    }

    fn g(ids: &[u8]) -> Value {
        json!(ids)
    }

    #[test]
    fn opening_lay_rules() {
        let mut gm = sess(1);
        let rack = opening_rack();
        rig(&mut gm, 0, &rack);
        let low = json!({"lay": [g(&[t(R, 1, 0), t(R, 2, 0), t(R, 3, 0)]), g(&[t(K, 7, 0), t(B, 7, 0), t(Y, 7, 0), t(R, 7, 0)])]});
        let before = gm.state();
        let e = gm.act(&low).unwrap_err();
        assert!(e.contains("101"), "{e}");
        assert_eq!(gm.state(), before, "rejected lay leaves the state unchanged");
        // Mixing pairs and melds is refused.
        assert!(gm.act(&json!({"lay": [g(&[t(R, 1, 0), t(R, 2, 0), t(R, 3, 0)]), g(&[t(K, 2, 1), OK1])]})).is_err());
        // Not a meld.
        assert!(gm.act(&json!({"lay": [g(&[t(R, 1, 0), t(K, 2, 1), t(R, 3, 0)])]})).is_err());
        let open = json!({"lay": [
            g(&[t(R, 1, 0), t(R, 2, 0), t(R, 3, 0)]),
            g(&[t(K, 7, 0), t(B, 7, 0), t(Y, 7, 0), t(R, 7, 0)]),
            g(&[OK1, t(B, 10, 0), t(B, 11, 0), t(B, 12, 0), t(B, 13, 0)]),
            g(&[t(K, 4, 0), t(B, 4, 1), t(Y, 4, 1)]),
        ]});
        gm.act(&open).unwrap();
        assert_eq!(gm.hand.opened[0], Some(OpenKind::Melds));
        assert_eq!(gm.hand.open_value[0], 6 + 28 + 55 + 12);
        assert_eq!(gm.hand.table.len(), 4);
        assert_eq!(gm.hand.racks[0].len(), rack.len() - 15);
        let st = gm.state();
        assert_eq!(st["seats"][0]["open_value"], 101);
        // After opening a meld opener may lay more runs/sets (no threshold) but no pairs.
        assert!(gm.act(&json!({"lay": [g(&[t(Y, 2, 0), t(K, 2, 1)])]})).is_err());
        // Everything but one tile may go; the last tile must stay for the discard.
        let mut gm = sess(2);
        let all: Vec<u8> = vec![
            t(R, 10, 0), t(R, 11, 0), t(R, 12, 0), t(R, 13, 0), t(K, 13, 0), t(B, 13, 0), t(Y, 13, 1),
        ];
        rig(&mut gm, 0, &all);
        gm.hand.racks[0].retain(|&x| x != t(Y, 13, 1));
        gm.hand.racks[0].push(t(B, 12, 0));
        gm.hand.racks[0].push(t(B, 11, 0));
        // 10-11-12-13 red (46) + 13s set k,b + ... value check only: 46 + 39 = 85 < 101 → refused.
        assert!(gm.act(&json!({"lay": [g(&[t(R, 10, 0), t(R, 11, 0), t(R, 12, 0)])]})).is_err());
    }

    #[test]
    fn keep_one_tile_and_pairs_opening() {
        let mut gm = sess(3);
        let mut pr = Vec::new();
        for (c, n) in [(R, 1), (K, 5), (B, 9), (Y, 2), (R, 12)] {
            pr.push(t(c, n, 0));
            pr.push(t(c, n, 1));
        }
        let mut rack = pr.clone();
        rack.extend([t(B, 3, 0), t(K, 8, 0)]);
        rig(&mut gm, 0, &rack);
        let four = json!({"lay": pr[..8].chunks(2).map(|c| g(c)).collect::<Vec<_>>()});
        let e = gm.act(&four).unwrap_err();
        assert!(e.contains("5 çift"), "{e}");
        let five = json!({"lay": pr.chunks(2).map(|c| g(c)).collect::<Vec<_>>()});
        gm.act(&five).unwrap();
        assert_eq!(gm.hand.opened[0], Some(OpenKind::Pairs));
        // A pair opener lays no runs/sets.
        gm.hand.racks[0].extend([t(R, 6, 0), t(R, 7, 0), t(R, 8, 0)]);
        assert!(gm.act(&json!({"lay": [g(&[t(R, 6, 0), t(R, 7, 0), t(R, 8, 0)])]})).is_err());
        // Laying every tile is refused: one must remain for the finishing discard.
        let mut gm = sess(4);
        let rack = vec![t(R, 10, 0), t(R, 11, 0), t(R, 12, 0), t(R, 13, 0), t(K, 13, 0), t(B, 13, 0), OK2];
        rig(&mut gm, 0, &rack);
        gm.hand.opened[0] = Some(OpenKind::Melds);
        let both = json!({"lay": [g(&[t(R, 10, 0), t(R, 11, 0), t(R, 12, 0), t(R, 13, 0)]), g(&[t(K, 13, 0), t(B, 13, 0), OK2])]});
        let e = gm.act(&both).unwrap_err();
        assert!(e.contains("bir taş kalmalı"), "{e}");
        gm.act(&json!({"lay": [g(&[t(R, 10, 0), t(R, 11, 0), t(R, 12, 0), t(R, 13, 0)])]})).unwrap();
        assert_eq!(gm.hand.racks[0].len(), 3);
    }

    fn table_meld(owner: usize, ids: &[u8]) -> TMeld {
        TMeld { owner, kind: classify(ids, OKEY).unwrap(), tiles: ids.to_vec() }
    }

    #[test]
    fn isleme_legality() {
        let run = table_meld(1, &[t(R, 4, 0), t(R, 5, 0), t(R, 6, 0)]);
        assert_eq!(run.fits(t(R, 7, 1), OKEY), vec![End::High]);
        assert_eq!(run.fits(t(R, 3, 1), OKEY), vec![End::Low]);
        assert!(run.fits(t(K, 7, 1), OKEY).is_empty());
        assert_eq!(run.fits(OK1, OKEY), vec![End::High, End::Low]);
        assert!(run.fits(104, OKEY).is_empty(), "false joker = yellow 13");
        let ones = table_meld(1, &[t(R, 1, 0), t(R, 2, 0), t(R, 3, 0)]);
        assert_eq!(ones.fits(t(R, 4, 0), OKEY), vec![End::High]);
        assert!(ones.fits(t(R, 13, 0), OKEY).is_empty(), "nothing goes below 1");
        let top = table_meld(1, &[t(R, 11, 0), t(R, 12, 0), t(R, 13, 0)]);
        assert_eq!(top.fits(t(R, 1, 0), OKEY), vec![End::High], "12-13-1");
        let mut wrap = table_meld(1, &[t(R, 12, 0), t(R, 13, 0), t(R, 1, 0)]);
        assert!(wrap.fits(t(R, 2, 0), OKEY).is_empty(), "13-1-2 never");
        assert_eq!(wrap.fits(t(R, 11, 1), OKEY), vec![End::Low]);
        wrap.add(t(R, 11, 1), End::Low);
        assert_eq!(wrap.value(), 11 + 12 + 13 + 1);
        let set = table_meld(2, &[t(K, 7, 0), t(B, 7, 0), t(Y, 7, 0)]);
        assert_eq!(set.fits(t(R, 7, 0), OKEY), vec![End::High]);
        assert!(set.fits(t(K, 7, 1), OKEY).is_empty(), "colour already used");
        assert_eq!(set.fits(OK2, OKEY), vec![End::High]);
        let full = table_meld(2, &[t(K, 7, 0), t(B, 7, 0), t(Y, 7, 0), t(R, 7, 0)]);
        assert!(full.fits(OK2, OKEY).is_empty());
        let pair = table_meld(3, &[t(R, 5, 0), t(R, 5, 1)]);
        assert!(pair.fits(OK1, OKEY).is_empty(), "pairs take no tiles");

        // Session: only opened players may işle; the tile goes to the right end; the chain grows.
        let mut gm = sess(5);
        let rack = vec![t(R, 7, 1), t(R, 8, 1), t(K, 9, 0), t(B, 2, 0), t(Y, 5, 0)];
        rig(&mut gm, 0, &rack);
        gm.hand.table = vec![run.clone()];
        let e = gm.act(&json!({"add": {"tile": t(R, 7, 1), "meld": 0}})).unwrap_err();
        assert!(e.contains("açmalısın"), "{e}");
        gm.hand.opened[0] = Some(OpenKind::Melds);
        let st = gm.state();
        assert_eq!(st["addable"][0]["tile"], t(R, 7, 1));
        assert!(gm.act(&json!({"add": {"tile": t(R, 8, 1), "meld": 0}})).is_err());
        gm.act(&json!({"add": {"tile": t(R, 7, 1), "meld": 0}})).unwrap();
        gm.act(&json!({"add": {"tile": t(R, 8, 1), "meld": 0}})).unwrap();
        assert_eq!(gm.hand.table[0].tiles.len(), 5);
        assert!(gm.act(&json!({"add": {"tile": t(K, 9, 0), "meld": 0}})).is_err());
        assert!(gm.act(&json!({"add": {"tile": t(K, 9, 0), "meld": 3}})).is_err());
        // An okey dropped on the low side goes low.
        gm.hand.racks[0].push(OK1);
        gm.act(&json!({"add": {"tile": OK1, "meld": 0, "end": "low"}})).unwrap();
        assert_eq!(gm.hand.table[0].tiles[0], OK1);
        assert_eq!(gm.hand.table[0].kind, MKind::Run { col: R, start: 2 });
    }

    #[test]
    fn discard_penalties() {
        let mut gm = sess(6);
        let rack = vec![t(R, 7, 1), t(K, 9, 0), t(B, 2, 0), OK1, t(Y, 5, 0)];
        rig(&mut gm, 0, &rack);
        gm.hand.table = vec![table_meld(1, &[t(R, 4, 0), t(R, 5, 0), t(R, 6, 0)])];
        let st = gm.state();
        let pens: Vec<u64> = st["penalty_tiles"].as_array().unwrap().iter().map(|x| x.as_u64().unwrap()).collect();
        assert!(pens.contains(&(t(R, 7, 1) as u64)) && pens.contains(&(OK1 as u64)) && pens.len() == 2);
        let before = gm.state();
        let e = gm.act(&json!({"discard": t(R, 7, 1)})).unwrap_err();
        assert!(e.contains("101 ceza"), "{e}");
        assert_eq!(gm.state(), before);
        gm.act(&json!({"discard": t(R, 7, 1), "force": true})).unwrap();
        assert_eq!(gm.hand.penalties[0], 101);
        // Okey discard.
        let mut gm = sess(6);
        rig(&mut gm, 0, &rack);
        assert!(gm.act(&json!({"discard": OK1})).is_err());
        gm.act(&json!({"discard": OK1, "force": true})).unwrap();
        assert_eq!(gm.hand.penalties[0], 101);
        // A safe tile costs nothing.
        let mut gm = sess(6);
        rig(&mut gm, 0, &rack);
        gm.hand.table = vec![table_meld(1, &[t(R, 4, 0), t(R, 5, 0), t(R, 6, 0)])];
        gm.act(&json!({"discard": t(K, 9, 0)})).unwrap();
        assert_eq!(gm.hand.penalties[0], 0);
    }

    #[test]
    fn taken_tile_must_be_used_or_given_back() {
        let mut gm = sess(7);
        let rack = vec![t(K, 9, 0), t(B, 2, 0), t(Y, 5, 0), t(K, 3, 1), t(B, 11, 1)];
        rig(&mut gm, 0, &rack);
        gm.hand.stage = Stage::Draw;
        gm.hand.table = vec![table_meld(1, &[t(R, 4, 0), t(R, 5, 0), t(R, 6, 0)])];
        gm.hand.discards[3] = vec![t(R, 7, 1)];
        // Not opened: cannot open with it → refused.
        let before = gm.state();
        let e = gm.act(&json!({"draw": "discard"})).unwrap_err();
        assert!(e.contains("açmalısın"), "{e}");
        assert_eq!(gm.state(), before);
        // Opened: it fits the table run → allowed, but must be used before the discard.
        gm.hand.opened[0] = Some(OpenKind::Melds);
        let before = gm.state();
        gm.act(&json!({"draw": "discard"})).unwrap();
        assert_eq!(gm.state()["must_use"], t(R, 7, 1));
        assert_eq!(gm.state()["can_untake"], true);
        let e = gm.act(&json!({"discard": t(K, 9, 0)})).unwrap_err();
        assert!(e.contains("kullanmalısın"), "{e}");
        // Give it back: everything as before (but the version and the log).
        gm.act(&json!({"untake": true})).unwrap();
        let after = gm.state();
        for key in ["seats", "table", "layout", "stage", "take_tile", "pile_count"] {
            assert_eq!(after[key], before[key], "{key} restored");
        }
        // Take again, işle it, then discard.
        gm.act(&json!({"draw": "discard"})).unwrap();
        gm.act(&json!({"add": {"tile": t(R, 7, 1), "meld": 0}})).unwrap();
        assert!(gm.act(&json!({"untake": true})).is_err());
        gm.act(&json!({"discard": t(K, 9, 0)})).unwrap();
        assert_eq!(gm.hand.turn, 1);
    }

    #[test]
    fn scoring_cases() {
        // Plain finish.
        let mut gm = sess(8);
        rig(&mut gm, 0, &[t(K, 9, 0)]);
        gm.hand.opened = [Some(OpenKind::Melds), None, Some(OpenKind::Melds), Some(OpenKind::Pairs)];
        gm.hand.racks[1] = vec![t(R, 1, 1), t(R, 2, 1)];
        gm.hand.racks[2] = vec![t(B, 10, 1), t(Y, 3, 1), 104]; // 10 + 3 + 13 (false joker = okey's number)
        gm.hand.racks[3] = vec![OK2, t(K, 1, 1)]; // okey counts 13
        gm.hand.penalties[2] = 101;
        gm.act(&json!({"discard": t(K, 9, 0)})).unwrap();
        let r = gm.result.clone().unwrap();
        assert_eq!(r.winner, Some(0));
        assert_eq!(r.points, [-101, 202, 26 + 101, 14]);
        assert_eq!(gm.totals, r.points);
        assert_eq!(gm.history.len(), 1);
        // Okey finish doubles (penalties are not doubled).
        let mut gm = sess(9);
        rig(&mut gm, 0, &[OK1]);
        gm.hand.opened = [Some(OpenKind::Melds), None, Some(OpenKind::Melds), None];
        gm.hand.racks[2] = vec![t(B, 10, 1)];
        gm.hand.penalties[1] = 101;
        gm.act(&json!({"discard": OK1})).unwrap();
        let r = gm.result.clone().unwrap();
        assert!(r.okey_finish);
        assert_eq!(r.points, [-202, 404 + 101, 20, 404]);
        // Pairs finisher doubles; with an okey, 4×.
        let mut gm = sess(10);
        rig(&mut gm, 2, &[OK1]);
        gm.hand.opened = [None, Some(OpenKind::Melds), Some(OpenKind::Pairs), None];
        gm.hand.racks[1] = vec![t(B, 10, 1)];
        gm.discard(2, OK1, true, String::new()).unwrap();
        let r = gm.result.clone().unwrap();
        assert_eq!(r.mult, 4);
        assert_eq!(r.points, [808, 40, -404, 808]);
        // Pile out: no finisher, everyone writes what is left.
        let mut gm = sess(11);
        rig(&mut gm, 0, &[t(K, 9, 0), t(K, 10, 0)]);
        gm.hand.opened = [Some(OpenKind::Melds), None, None, None];
        gm.hand.pile.clear();
        gm.act(&json!({"discard": t(K, 9, 0)})).unwrap();
        let r = gm.result.clone().unwrap();
        assert_eq!(r.winner, None);
        assert_eq!(r.points[0], 10);
        assert_eq!(r.points[1], 202);
        // Match: lowest total wins.
        let mut gm = sess(12);
        gm.act(&json!({"hands": 3})).unwrap();
        assert!(gm.act(&json!({"hands": 4})).is_err());
        assert_eq!(gm.max_hands, 3);
        gm.totals = [50, 100, 120, 300];
        gm.hand_no = 3;
        rig(&mut gm, 0, &[t(K, 9, 0)]);
        gm.hand.opened[0] = Some(OpenKind::Melds);
        gm.act(&json!({"discard": t(K, 9, 0)})).unwrap();
        assert!(gm.match_over);
        gm.act(&json!({"next": true})).unwrap();
        assert_eq!(gm.final_status, Some("won"));
        assert!(gm.state()["summary"].as_str().unwrap().contains("düşük kazanır"));
    }

    #[test]
    fn illegal_actions_are_rejected_unchanged() {
        let mut gm = sess(13);
        while gm.playing() && gm.hand.turn != 0 {
            gm.act(&json!({"ai": true})).unwrap();
        }
        assert!(gm.playing());
        let before = gm.state();
        let foreign = (0..106u8).find(|id| !gm.hand.racks[0].contains(id)).unwrap();
        let mine = gm.hand.racks[0][0];
        let mut bad = vec![
            json!({"ai": true}),
            json!({"next": true}),
            json!({"discard": foreign}),
            json!({"lay": [[foreign, mine, mine]]}),
            json!({"lay": []}),
            json!({"lay": "x"}),
            json!({"add": {"tile": mine, "meld": 0}}),
            json!({"untake": true}),
            json!({"arrange": [1, 2, 3]}),
            json!({"hands": 9}),
            json!({"draw": "nowhere"}),
            json!({"bogus": 1}),
        ];
        if gm.hand.stage == Stage::Draw {
            bad.push(json!({"discard": mine}));
        } else {
            bad.push(json!({"draw": "pile"}));
        }
        for a in bad {
            assert!(gm.act(&a).is_err(), "{a} should fail");
            assert_eq!(gm.state(), before, "{a} changed state");
        }
        gm.act(&json!({"suggest": true})).unwrap();
        assert!(gm.state()["hint"]["text"].as_str().is_some_and(|s| !s.is_empty()));
        gm.act(&json!({"auto_arrange": "runs"})).unwrap();
        gm.act(&json!({"auto_arrange": "pairs"})).unwrap();
        let mut ids: Vec<u8> = gm.layout.iter().filter(|&&x| x >= 0).map(|&x| x as u8).collect();
        ids.sort();
        let mut r = gm.hand.racks[0].clone();
        r.sort();
        assert_eq!(ids, r);
        gm.act(&json!({"hint": true})).unwrap();
        assert!(gm.state()["hint"]["text"].as_str().is_some_and(|s| !s.is_empty()));
    }

    #[test]
    fn suggest_arranges_the_best_opening() {
        let mut gm = sess(14);
        rig(&mut gm, 0, &opening_rack());
        gm.act(&json!({"suggest": true})).unwrap();
        let st = gm.state();
        let text = st["hint"]["text"].as_str().unwrap();
        assert!(text.starts_with("Açabilirsin"), "{text}");
        let total: u64 = st["melds"].as_array().unwrap().iter().filter(|m| m["kind"] != "pair").map(|m| m["value"].as_u64().unwrap()).sum();
        assert!(total >= 101, "layout melds sum to {total}");
        // Laying exactly the layout melds opens.
        let lay: Vec<Vec<u8>> = st["melds"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|m| m["kind"] != "pair")
            .map(|m| m["slots"].as_array().unwrap().iter().map(|s| gm.layout[s.as_u64().unwrap() as usize] as u8).collect())
            .collect();
        gm.act(&json!({"lay": lay})).unwrap();
        assert_eq!(gm.hand.opened[0], Some(OpenKind::Melds));
    }

    fn self_play(levels: [Level; 4], seed: u64, hands: u32) -> Okey101 {
        let mut gm = Okey101::with_levels(levels[1], levels, seed);
        gm.max_hands = hands;
        let mut steps = 0;
        while gm.final_status.is_none() {
            if gm.hand_end {
                gm.act(&json!({"next": true})).unwrap();
                continue;
            }
            let seat = gm.hand.turn;
            gm.ai_step(seat).unwrap();
            steps += 1;
            assert!(steps < 4000, "match did not terminate");
        }
        gm
    }

    #[test]
    fn ai_only_matches_terminate_at_all_levels() {
        for (i, lvl) in [Level::Easy, Level::Normal, Level::Hard, Level::Impossible].into_iter().enumerate() {
            let gm = self_play([lvl; 4], 100 + i as u64, 3);
            assert!(gm.final_status.is_some());
            assert_eq!(gm.fallbacks, 0, "{lvl:?} could not use a taken tile");
            assert_eq!(gm.history.len(), 3);
            let st = gm.state();
            assert!(st["summary"].is_string());
            // Tile conservation at the end of the last hand.
            let h = &gm.hand;
            let mut all: Vec<u8> = h.racks.iter().flatten().chain(h.discards.iter().flatten()).chain(h.pile.iter()).copied().collect();
            all.extend(h.table.iter().flat_map(|m| m.tiles.iter().copied()));
            all.push(h.indicator);
            if let Some(f) = gm.result.as_ref().and_then(|r| r.finish_tile) {
                all.push(f);
            }
            all.sort();
            assert_eq!(all, (0..106).collect::<Vec<u8>>(), "{lvl:?}");
            for m in &h.table {
                assert!(classify(&m.tiles, h.okey).is_some(), "table meld {m:?} stays valid");
            }
        }
    }

    #[test]
    fn reasons_are_present() {
        let mut gm = sess(21);
        let mut n = 0;
        while gm.playing() && n < 80 {
            if gm.hand.turn == 0 {
                gm.ai_step(0).unwrap();
            } else {
                gm.act(&json!({"ai": true})).unwrap();
                let l = gm.last.as_ref().unwrap();
                assert!(!l.reason.is_empty(), "{l:?}");
            }
            n += 1;
        }
    }

    /// Easy/normal/hard decisions depend only on public data + own rack.
    #[test]
    fn info_decisions_ignore_hidden_tiles() {
        let mut checked = 0;
        for seed in 0..10u64 {
            let mut gm = Okey101::with_levels(Level::Hard, [Level::Hard; 4], 300 + seed);
            for _ in 0..(10 + seed as usize * 2) {
                if !gm.playing() {
                    break;
                }
                let seat = gm.hand.turn;
                gm.ai_step(seat).unwrap();
            }
            if !gm.playing() {
                continue;
            }
            let seat = gm.hand.turn;
            let mut h2 = gm.hand.clone();
            let others: Vec<usize> = (0..4).filter(|&s| s != seat).collect();
            let mut pool: Vec<u8> = others.iter().flat_map(|&s| h2.racks[s].clone()).chain(h2.pile.clone()).collect();
            // Tiles others took are public: keep them in place.
            let public: Vec<u8> = h2.taken.iter().flatten().copied().collect();
            pool.retain(|x| !public.contains(x));
            Rng::new(seed).shuffle(&mut pool);
            for &s in &others {
                let keep: Vec<u8> = h2.racks[s].iter().copied().filter(|x| public.contains(x)).collect();
                let n = h2.racks[s].len() - keep.len();
                let mut r: Vec<u8> = pool.drain(..n).collect();
                r.extend(keep);
                h2.racks[s] = r;
            }
            h2.pile = pool;
            let mut solver = MeldSolver::new();
            for lvl in [Level::Easy, Level::Normal, Level::Hard] {
                if gm.hand.stage == Stage::Draw {
                    let a = info_draw(&gm.hand.info(seat), lvl, &mut solver, &mut Rng::new(1), false);
                    let b = info_draw(&h2.info(seat), lvl, &mut solver, &mut Rng::new(1), false);
                    assert_eq!((a.take, a.reason), (b.take, b.reason));
                } else {
                    let a = info_discard(&gm.hand.info(seat), lvl, &mut solver, &mut Rng::new(1), false);
                    let b = info_discard(&h2.info(seat), lvl, &mut solver, &mut Rng::new(1), false);
                    assert_eq!((a.id, a.reason), (b.id, b.reason));
                }
                checked += 1;
            }
        }
        assert!(checked >= 15);
    }

    /// Match totals of seats 0+2 vs 1+3 over `n` matches (lower is better).
    fn duel(a: Level, b: Level, n: u64, hands: u32, seed: u64) -> (i64, i64, u32, u32) {
        let (mut ta, mut tb, mut wa, mut wb) = (0i64, 0i64, 0u32, 0u32);
        for i in 0..n {
            let gm = self_play([a, b, a, b], seed + i, hands);
            ta += (gm.totals[0] + gm.totals[2]) as i64;
            tb += (gm.totals[1] + gm.totals[3]) as i64;
            wa += gm.wins[0] + gm.wins[2];
            wb += gm.wins[1] + gm.wins[3];
        }
        (ta, tb, wa, wb)
    }

    #[test]
    fn impossible_beats_hard_by_a_wide_margin() {
        let (hard, imp, wh, wi) = duel(Level::Hard, Level::Impossible, 16, DEFAULT_HANDS, 500);
        println!("hard vs impossible over 16 matches: totals {hard} vs {imp}, hand wins {wh} vs {wi}");
        assert!(imp * 10 < hard * 7, "impossible total {imp} vs hard {hard}");
        assert!(wi * 2 > wh * 3, "hand wins impossible {wi} vs hard {wh}");
    }

    #[test]
    fn hard_beats_easy() {
        let (easy, hard, we, wh) = duel(Level::Easy, Level::Hard, 16, DEFAULT_HANDS, 900);
        assert!(hard * 10 < easy * 8, "hard total {hard} vs easy {easy}");
        assert!(wh > we, "hand wins hard {wh} vs easy {we}");
    }

    /// Prints one hand's log (with reasons). Run with `--ignored --nocapture`.
    #[test]
    #[ignore]
    fn trace_hand() {
        let lvl = match std::env::var("OKEY_LVL").as_deref() {
            Ok("easy") => Level::Easy,
            Ok("normal") => Level::Normal,
            Ok("impossible") => Level::Impossible,
            _ => Level::Hard,
        };
        let seed = std::env::var("OKEY_SEED").ok().and_then(|v| v.parse().ok()).unwrap_or(1);
        let mut gm = Okey101::with_levels(lvl, [lvl; 4], seed);
        let mut seen = 0;
        while gm.playing() {
            let seat = gm.hand.turn;
            gm.ai_step(seat).unwrap();
            let l = gm.last.clone().unwrap();
            if l.serial != seen {
                seen = l.serial;
                println!("[{}] {} -- {}", l.seat, l.text, l.reason);
            }
        }
        let r = gm.result.unwrap();
        println!("{} / {:?} / pile {}", r.text, r.points, gm.hand.pile.len());
        for m in &gm.hand.table {
            println!("  {} {}", GEN[m.owner], m.desc(gm.hand.okey));
        }
    }

    #[test]
    #[ignore]
    fn timing_ai_decisions() {
        for lvl in [Level::Easy, Level::Normal, Level::Hard, Level::Impossible] {
            let mut worst = 0u128;
            let mut total = 0u128;
            let mut n = 0u128;
            for seed in 0..4u64 {
                let mut gm = Okey101::with_levels(lvl, [lvl; 4], 7000 + seed);
                let mut steps = 0;
                while gm.final_status.is_none() && steps < 800 {
                    if gm.hand_end {
                        gm.act(&json!({"next": true})).unwrap();
                        continue;
                    }
                    let seat = gm.hand.turn;
                    let t0 = std::time::Instant::now();
                    gm.ai_step(seat).unwrap();
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

    /// Match totals and hand wins for level pairs (seats 0,2 vs 1,3); with `OKEY_SOLO` one seat-0
    /// player against three seats of the second level. Run with `--ignored --nocapture`.
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
            Ok(v) => v.split(',').filter_map(|p| p.split_once('-')).map(|(a, b)| (parse(a), parse(b))).collect(),
            Err(_) => vec![(Easy, Normal), (Easy, Hard), (Normal, Hard), (Hard, Impossible), (Easy, Impossible)],
        };
        let n: u64 = std::env::var("OKEY_N").ok().and_then(|v| v.parse().ok()).unwrap_or(40);
        let solo = std::env::var("OKEY_SOLO").is_ok();
        for (a, b) in pairs {
            let levels = if solo { [a, b, b, b] } else { [a, b, a, b] };
            let (mut ta, mut tb, mut wa, mut wb, mut mw, mut md, mut ml) = (0i64, 0i64, 0u32, 0u32, 0u32, 0u32, 0u32);
            let mut opened = [0u32; 2];
            let mut hands = 0u32;
            for i in 0..n {
                let gm = self_play(levels, 10_000 + i, DEFAULT_HANDS);
                let sa: &[usize] = if solo { &[0] } else { &[0, 2] };
                let sb: &[usize] = if solo { &[1, 2, 3] } else { &[1, 3] };
                ta += sa.iter().map(|&s| gm.totals[s] as i64).sum::<i64>();
                tb += sb.iter().map(|&s| gm.totals[s] as i64).sum::<i64>();
                wa += sa.iter().map(|&s| gm.wins[s]).sum::<u32>();
                wb += sb.iter().map(|&s| gm.wins[s]).sum::<u32>();
                hands += gm.history.len() as u32;
                for p in &gm.history {
                    opened[0] += sa.iter().filter(|&&s| p[s] < 202).count() as u32;
                    opened[1] += sb.iter().filter(|&&s| p[s] < 202).count() as u32;
                }
                match gm.final_status {
                    Some("won") => mw += 1,
                    Some("draw") => md += 1,
                    _ => ml += 1,
                }
            }
            let per = |x: i64, seats: usize| x as f64 / (n as f64 * seats as f64);
            let (na, nb) = if solo { (1, 3) } else { (2, 2) };
            println!(
                "{a:?} vs {b:?}: avg match total per seat {:.0} vs {:.0} · hand wins {wa} vs {wb} of {hands} hands · seat-0 matches W/D/L {mw}/{md}/{ml} · opened-or-finished hands {} vs {}",
                per(ta, na),
                per(tb, nb),
                opened[0],
                opened[1]
            );
        }
    }
}
