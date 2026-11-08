//! Duvar Yarışı — the wall-race duel on a 9×9 board, against an AI opponent.
//!
//! Board: 9×9 squares, square `(r, c)` = index `r*9 + c`, row 0 at the top. The player ("you")
//! starts on (8,4) and must reach **row 0**; the AI starts on (0,4) and must reach **row 8**. Each
//! side has 10 walls.
//!
//! Walls: a wall is two squares long and lies in a groove between squares. It is anchored at one of
//! the 8×8 inner groove crossings `(r, c)`, `r, c ∈ 0..8`:
//! - `"h"` at (r,c): horizontal, below squares (r,c) and (r,c+1) — blocks (r,c)↕(r+1,c) and
//!   (r,c+1)↕(r+1,c+1);
//! - `"v"` at (r,c): vertical, right of squares (r,c) and (r+1,c) — blocks (r,c)↔(r,c+1) and
//!   (r+1,c)↔(r+1,c+1).
//!
//! A wall may not overlap another wall (same groove, sharing a half), may not cross one (an `h` and
//! a `v` on the same anchor) and may never leave either pawn without a path to its goal row.
//!
//! Turn: move your pawn one square orthogonally (not through a wall) **or** place a wall. When the
//! pawns stand face to face you may jump straight over the opponent; if a wall or the board edge is
//! behind it, you may instead jump diagonally to either side of it (unless walled off there). The
//! first pawn to reach its goal row wins. Odd levels the player starts, even levels the AI starts.
//!
//! Draw: the game has no draws in principle; as a safety cap the game is declared a **draw after
//! 200 plies** (100 moves each) without a winner (`end_reason: "ply_limit"`).
//!
//! AI: negamax + alpha-beta, iterative deepening, transposition table, killer/history ordering, all
//! bounded by a deterministic **node budget** (L500: 60k nodes ≈ 5–8 plies; ≈ 15 ms average,
//! ≈ 40 ms worst per move on an M-series Mac in release). Evaluation (side to move, 100 = one step):
//! `100·(opponent's shortest path − own shortest path) + 120·(own walls − opponent's walls) + 50`
//! (tempo), +80 per wall in hand (max 4) when the other side has none left (it can wall at leisure),
//! and ±600 once a side without walls has lost the remaining race. Candidate walls: at the root every
//! legal wall; deeper only walls that cut an edge of the opponent's current shortest path (the
//! `walls_k` best by immediate gain, and only path-lengthening ones at the horizon).
//! Weaker opponents get a smaller budget, fewer wall ideas per node (they don't foresee your walls),
//! Gaussian-ish noise on root scores, an occasional "human" slip (2nd/3rd best within a margin) and a
//! habit of **spending walls too early** (a plausible blocking wall instead of a better pawn move,
//! while they still have many walls).
//!
//! Level curve (`params`), t = (level−1)/499:
//! - budget = 1 500 · (MAX_BUDGET/1 500)^(t^0.7) nodes (L1 = 1.5k, L250 ≈ 14k, L500 = 60k)
//! - walls_k = 5 → 14 (reached at t = 0.6 ≈ L300)
//! - noise σ = 45 · (1−t)^1.5 (in 1/100 step; gone by ≈ L480)
//! - slip = 12 % · (1 − t/0.7) (none from ≈ L350), among moves within `margin` of the best
//! - margin = 30 + 70 · (1−t)²
//! - waste = 30 % · (1 − t/0.55) (none from ≈ L275): while ≥ 6 walls in hand in the first 30 plies
//! - odd levels: you start; even levels: the AI starts.
//! Measured (12 games each, random first plies): L500–L1 12:0, L250–L1 11:1, L500–L250 10:2,
//! L250–L100 8:4, L100–L1 7:5.
//!
//! Ranks: 1–40 Acemi · 41–100 Çırak · 101–180 Kalfa · 181–280 Usta · 281–400 Üstat · 401–500 Büyükusta.
//!
//! Stars on a win: 3 = no undo/hint and the AI still needed **≥ 3 steps** (its shortest path when
//! your pawn arrived), 2 = no undo/hint, 1 = undo or hint used.
//!
//! State: `{status, stars, title, goal, level, turn: "you"|"ai", ai_pending,
//!   pawns: {you: [r,c], ai: [r,c]}, walls: [{r, c, o: "h"|"v", who: "you"|"ai"}],
//!   walls_left: {you, ai}, walls_total, path: {you, ai} (shortest path lengths),
//!   my_path: [[r,c]…] (your shortest path, pawn square first), targets: [[r,c]] (legal pawn targets,
//!   your turn only), wall_slots: {h: "0101…", v: "…"} | null (64 chars, anchor r*8+c, '1' = legal,
//!   your turn with walls in hand only), last_move: {ply, who, kind: "move"|"wall", from, to, jump,
//!   wall: [r,c,o]} | null, hint: {kind: "move", to} | {kind: "wall", wall: [r,c,o]} | null, can_undo,
//!   plies, ply_limit, player_moves, complexity (0..1, for the AI pause), end_reason, summary}`.
//! Actions: `{"to":[r,c]}` · `{"wall":[r,c,"h"|"v"]}` · `{"ai":true}` · `{"undo":true}` (your last
//! move and the AI reply after it) · `{"hint":true}`.

use crate::rng::{seed_for, Rng};
use crate::Session;
use serde_json::{json, Value};
use std::sync::OnceLock;

const YOU: usize = 0;
const AI: usize = 1;
const N: usize = 9;
const SQ: usize = 81;
pub const WALLS: u8 = 10;
pub const PLY_LIMIT: u32 = 200;
const MAX_BUDGET: u64 = 60_000;
/// Most candidate walls tried at an interior search node.
const MAX_WALLS: usize = 14;

const WIN: i32 = 30_000;
const DECISIVE: i32 = 15_000;
const INF: i32 = 32_000;
const MAX_PLY: usize = 48;
const TEMPO: i32 = 50;
const RACE: i32 = 600;
/// Value of one wall in hand, and the extra weight of walls once the other side has none.
const WALL_W: i32 = 120;
const NO_WALL_W: i32 = 80;
const UNREACH: u8 = 255;

// ---------------------------------------------------------------------------------------------
// Static tables

struct Tables {
    zpawn: [[u64; SQ]; 2],
    zwall: [[u64; 64]; 2],
    zleft: [[u64; 11]; 2],
    zside: u64,
    /// h anchors that overlap an h wall on anchor a (a−1, a, a+1 in the same row).
    hconf: [u64; 64],
    /// v anchors that overlap a v wall on anchor a (a−8, a, a+8 in the same column).
    vconf: [u64; 64],
    /// Edges a wall cuts: h → down-edges (bit s = s↕s+9), v → right-edges (bit s = s↔s+1).
    hcut: [u128; 64],
    vcut: [u128; 64],
    /// h anchors cutting the down-edge at s; v anchors cutting the right-edge at s.
    hfor: [u64; SQ],
    vfor: [u64; SQ],
}

fn tables() -> &'static Tables {
    static T: OnceLock<Tables> = OnceLock::new();
    T.get_or_init(|| {
        let mut rng = Rng::new(0xC0_441D_0B_2026);
        let mut zpawn = [[0u64; SQ]; 2];
        let mut zwall = [[0u64; 64]; 2];
        let mut zleft = [[0u64; 11]; 2];
        for s in 0..2 {
            for z in zpawn[s].iter_mut() {
                *z = rng.next_u64();
            }
            for z in zwall[s].iter_mut() {
                *z = rng.next_u64();
            }
            for z in zleft[s].iter_mut() {
                *z = rng.next_u64();
            }
        }
        let zside = rng.next_u64();
        let mut hconf = [0u64; 64];
        let mut vconf = [0u64; 64];
        let mut hcut = [0u128; 64];
        let mut vcut = [0u128; 64];
        let mut hfor = [0u64; SQ];
        let mut vfor = [0u64; SQ];
        for a in 0..64 {
            let (r, c) = (a / 8, a % 8);
            hconf[a] = 1 << a;
            if c > 0 {
                hconf[a] |= 1 << (a - 1);
            }
            if c < 7 {
                hconf[a] |= 1 << (a + 1);
            }
            vconf[a] = 1 << a;
            if r > 0 {
                vconf[a] |= 1 << (a - 8);
            }
            if r < 7 {
                vconf[a] |= 1 << (a + 8);
            }
            let s = r * N + c;
            hcut[a] = b(s) | b(s + 1);
            vcut[a] = b(s) | b(s + N);
            hfor[s] |= 1 << a;
            hfor[s + 1] |= 1 << a;
            vfor[s] |= 1 << a;
            vfor[s + N] |= 1 << a;
        }
        Tables { zpawn, zwall, zleft, zside, hconf, vconf, hcut, vcut, hfor, vfor }
    })
}

#[inline]
fn b(s: usize) -> u128 {
    1u128 << s
}

fn bits128(mut m: u128) -> impl Iterator<Item = usize> {
    std::iter::from_fn(move || {
        if m == 0 {
            None
        } else {
            let s = m.trailing_zeros() as usize;
            m &= m - 1;
            Some(s)
        }
    })
}

fn bits64(mut m: u64) -> impl Iterator<Item = usize> {
    std::iter::from_fn(move || {
        if m == 0 {
            None
        } else {
            let s = m.trailing_zeros() as usize;
            m &= m - 1;
            Some(s)
        }
    })
}

const ROW: u128 = 0x1FF;

fn goal_row(side: usize) -> usize {
    if side == YOU {
        0
    } else {
        N - 1
    }
}

fn goal_mask(side: usize) -> u128 {
    ROW << (N * goal_row(side))
}

// ---------------------------------------------------------------------------------------------
// Moves: a pawn step is the target square (0..81); a wall is 128 + anchor·2 + (0 = h, 1 = v).

type Mv = u16;
const NO_MOVE: Mv = u16::MAX;

#[inline]
fn wall_mv(a: usize, v: usize) -> Mv {
    (128 + a * 2 + v) as Mv
}
#[inline]
fn is_wall(m: Mv) -> bool {
    (128..256).contains(&m)
}
#[inline]
fn wall_of(m: Mv) -> (usize, usize) {
    let x = m as usize - 128;
    (x / 2, x % 2)
}

fn ori(v: usize) -> &'static str {
    if v == 0 {
        "h"
    } else {
        "v"
    }
}

struct MoveList {
    m: [Mv; 140],
    k: [i32; 140],
    n: usize,
}

impl MoveList {
    fn new() -> Self {
        MoveList { m: [0; 140], k: [0; 140], n: 0 }
    }
    fn push(&mut self, m: Mv, k: i32) {
        if self.n < self.m.len() {
            self.m[self.n] = m;
            self.k[self.n] = k;
            self.n += 1;
        }
    }
    /// Insertion sort by key, descending (stable).
    fn sort(&mut self) {
        for i in 1..self.n {
            let (m, k) = (self.m[i], self.k[i]);
            let mut j = i;
            while j > 0 && self.k[j - 1] < k {
                self.m[j] = self.m[j - 1];
                self.k[j] = self.k[j - 1];
                j -= 1;
            }
            self.m[j] = m;
            self.k[j] = k;
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Position

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
struct Pos {
    pawn: [u8; 2],
    left: [u8; 2],
    /// Wall anchors: [h, v].
    walls: [u64; 2],
    /// Open edges: bit s of `od` = s can step down to s+9; bit s of `orr` = s can step right to s+1.
    od: u128,
    orr: u128,
    stm: usize,
    hash: u64,
}

impl Pos {
    fn start(stm: usize) -> Pos {
        let t = tables();
        let mut od = 0u128;
        let mut orr = 0u128;
        for s in 0..SQ {
            if s / N < N - 1 {
                od |= b(s);
            }
            if s % N < N - 1 {
                orr |= b(s);
            }
        }
        let pawn = [(8 * N + 4) as u8, 4u8];
        let left = [WALLS, WALLS];
        let mut hash = t.zpawn[YOU][pawn[YOU] as usize] ^ t.zpawn[AI][pawn[AI] as usize];
        hash ^= t.zleft[YOU][WALLS as usize] ^ t.zleft[AI][WALLS as usize];
        if stm == AI {
            hash ^= t.zside;
        }
        Pos { pawn, left, walls: [0, 0], od, orr, stm, hash }
    }

    /// One step from `s` in direction d (0 up, 1 down, 2 left, 3 right), if no wall/edge is in the way.
    #[inline]
    fn step(&self, s: usize, d: usize) -> Option<usize> {
        match d {
            0 => (s >= N && (self.od >> (s - N)) & 1 == 1).then(|| s - N),
            1 => ((self.od >> s) & 1 == 1).then_some(s + N),
            2 => (s % N > 0 && (self.orr >> (s - 1)) & 1 == 1).then(|| s - 1),
            _ => ((self.orr >> s) & 1 == 1).then_some(s + 1),
        }
    }

    /// Legal pawn targets of `side` (jumps included).
    fn pawn_targets(&self, side: usize) -> ([u8; 8], usize) {
        let mut out = [0u8; 8];
        let mut n = 0;
        let a = self.pawn[side] as usize;
        let o = self.pawn[1 - side] as usize;
        for d in 0..4 {
            let Some(q) = self.step(a, d) else { continue };
            if q != o {
                out[n] = q as u8;
                n += 1;
            } else if let Some(j) = self.step(o, d) {
                out[n] = j as u8;
                n += 1;
            } else {
                let perp = if d < 2 { [2, 3] } else { [0, 1] };
                for p in perp {
                    if let Some(j) = self.step(o, p) {
                        out[n] = j as u8;
                        n += 1;
                    }
                }
            }
        }
        (out, n)
    }

    fn fits(&self, a: usize, v: usize) -> bool {
        let t = tables();
        if v == 0 {
            self.walls[0] & t.hconf[a] == 0 && self.walls[1] & (1 << a) == 0
        } else {
            self.walls[1] & t.vconf[a] == 0 && self.walls[0] & (1 << a) == 0
        }
    }

    /// The position with wall (a, v) added (no legality check, walls in hand unchanged).
    fn with_wall(&self, a: usize, v: usize) -> Pos {
        let t = tables();
        let mut p = *self;
        p.walls[v] |= 1 << a;
        if v == 0 {
            p.od &= !t.hcut[a];
        } else {
            p.orr &= !t.vcut[a];
        }
        p.hash ^= t.zwall[v][a];
        p
    }

    #[inline]
    fn grow(&self, f: u128) -> u128 {
        ((f & self.od) << N) | ((f >> N) & self.od) | ((f & self.orr) << 1) | ((f >> 1) & self.orr)
    }

    /// Shortest path length (pawns ignored) of `side` to its goal row; UNREACH if cut off.
    fn dist(&self, side: usize) -> u8 {
        let target = b(self.pawn[side] as usize);
        let mut seen = goal_mask(side);
        let mut front = seen;
        let mut k = 0u8;
        loop {
            if seen & target != 0 {
                return k;
            }
            let n = self.grow(front) & !seen;
            if n == 0 {
                return UNREACH;
            }
            seen |= n;
            front = n;
            k += 1;
        }
    }

    /// Distance to `side`'s goal row from every square.
    fn dist_map(&self, side: usize) -> [u8; SQ] {
        let mut d = [UNREACH; SQ];
        let mut seen = goal_mask(side);
        let mut front = seen;
        let mut k = 0u8;
        loop {
            for s in bits128(front) {
                d[s] = k;
            }
            let n = self.grow(front) & !seen;
            if n == 0 {
                break;
            }
            seen |= n;
            front = n;
            k += 1;
        }
        d
    }

    /// One shortest path of `side` (pawn square first), preferring straight lines.
    fn path(&self, side: usize, dm: &[u8; SQ]) -> Vec<usize> {
        let mut cur = self.pawn[side] as usize;
        let mut out = vec![cur];
        if dm[cur] == UNREACH {
            return out;
        }
        let fwd = if side == YOU { 0 } else { 1 };
        let mut last = fwd;
        while dm[cur] > 0 {
            let order = [last, fwd, 2, 3, 1 - fwd];
            let mut next = None;
            for d in order {
                if let Some(q) = self.step(cur, d) {
                    if dm[q] + 1 == dm[cur] {
                        next = Some((q, d));
                        break;
                    }
                }
            }
            let Some((q, d)) = next else { break };
            cur = q;
            last = d;
            out.push(q);
        }
        out
    }

    /// Edges used by a path: (down-edges, right-edges) bitmasks.
    fn path_edges(path: &[usize]) -> (u128, u128) {
        let (mut dn, mut rt) = (0u128, 0u128);
        for w in path.windows(2) {
            let (x, y) = (w[0].min(w[1]), w[0].max(w[1]));
            if y - x == N {
                dn |= b(x);
            } else {
                rt |= b(x);
            }
        }
        (dn, rt)
    }

    fn winner(&self) -> Option<usize> {
        if (self.pawn[YOU] as usize) / N == goal_row(YOU) {
            Some(YOU)
        } else if (self.pawn[AI] as usize) / N == goal_row(AI) {
            Some(AI)
        } else {
            None
        }
    }

    fn make(&self, m: Mv) -> Pos {
        let t = tables();
        let s = self.stm;
        let mut p = if is_wall(m) {
            let (a, v) = wall_of(m);
            let mut p = self.with_wall(a, v);
            p.hash ^= t.zleft[s][p.left[s] as usize] ^ t.zleft[s][p.left[s] as usize - 1];
            p.left[s] -= 1;
            p
        } else {
            let mut p = *self;
            p.hash ^= t.zpawn[s][p.pawn[s] as usize] ^ t.zpawn[s][m as usize];
            p.pawn[s] = m as u8;
            p
        };
        p.stm = 1 - s;
        p.hash ^= t.zside;
        p
    }

    /// Is wall (a, v) legal for the side to move? (fits, walls in hand, both pawns keep a path)
    fn wall_legal(&self, a: usize, v: usize) -> bool {
        if self.left[self.stm] == 0 || !self.fits(a, v) {
            return false;
        }
        let q = self.with_wall(a, v);
        q.dist(YOU) != UNREACH && q.dist(AI) != UNREACH
    }

    /// Static evaluation from the side to move's point of view (100 = one step): path race, walls
    /// in hand (worth more once the other side has none left), tempo, decided races.
    fn eval(&self) -> i32 {
        let s = self.stm;
        let o = 1 - s;
        let dm = self.dist(s) as i32;
        let d_o = self.dist(o) as i32;
        let (lm, lo) = (self.left[s] as i32, self.left[o] as i32);
        let mut sc = 100 * (d_o - dm) + WALL_W * (lm - lo) + TEMPO;
        if lm == 0 && lo > 0 {
            sc -= NO_WALL_W * lo.min(4);
        }
        if lo == 0 && lm > 0 {
            sc += NO_WALL_W * lm.min(4);
        }
        // Once a side has no walls its path can only grow: if the race is already decided, say so.
        if lo == 0 && dm <= d_o {
            sc += RACE;
        }
        if lm == 0 && d_o < dm {
            sc -= RACE;
        }
        sc
    }
}

// ---------------------------------------------------------------------------------------------
// Search

#[derive(Clone, Copy, Debug)]
pub struct Params {
    pub budget: u64,
    pub noise: f64,
    pub slip: f64,
    pub margin: i32,
    pub waste: f64,
    /// Candidate walls per interior search node (how many wall ideas it "sees" ahead).
    pub walls_k: usize,
}

pub fn params(level: u32) -> Params {
    let t = (level.clamp(1, 500) - 1) as f64 / 499.0;
    let budget = (1_500.0 * (MAX_BUDGET as f64 / 1_500.0).powf(t.powf(0.7))).round() as u64;
    Params {
        budget,
        noise: 45.0 * (1.0 - t).powf(1.5),
        slip: (0.12 * (1.0 - t / 0.7)).max(0.0),
        margin: (30.0 + 70.0 * (1.0 - t) * (1.0 - t)).round() as i32,
        waste: (0.30 * (1.0 - t / 0.55)).max(0.0),
        walls_k: (5.0 + (MAX_WALLS - 5) as f64 * (t / 0.6).min(1.0)).round() as usize,
    }
}

fn full_strength() -> Params {
    Params { budget: MAX_BUDGET, noise: 0.0, slip: 0.0, margin: 0, waste: 0.0, walls_k: MAX_WALLS }
}

pub fn rank(level: u32) -> &'static str {
    match level {
        0..=40 => "Acemi",
        41..=100 => "Çırak",
        101..=180 => "Kalfa",
        181..=280 => "Usta",
        281..=400 => "Üstat",
        _ => "Büyükusta",
    }
}

#[derive(Clone, Copy)]
struct TtEntry {
    key: u64,
    score: i32,
    depth: i8,
    flag: u8, // 0 empty, 1 exact, 2 lower, 3 upper
    best: Mv,
}

impl Default for TtEntry {
    fn default() -> Self {
        TtEntry { key: 0, score: 0, depth: 0, flag: 0, best: NO_MOVE }
    }
}

const TT_SIZE: usize = 1 << 15;

struct Search {
    nodes: u64,
    budget: u64,
    walls_k: usize,
    abort: bool,
    tt: Vec<TtEntry>,
    killers: [[Mv; 2]; MAX_PLY],
    history: Vec<i32>,
}

/// Generated moves with what the root needs to know about walls.
struct Gen {
    list: MoveList,
    /// Immediate gain (opponent path increase) per wall move, same index as `list`.
    gain: [i8; 140],
}

impl Search {
    fn new(budget: u64, walls_k: usize) -> Search {
        Search {
            nodes: 0,
            budget,
            walls_k,
            abort: false,
            tt: vec![TtEntry::default(); TT_SIZE],
            killers: [[NO_MOVE; 2]; MAX_PLY],
            history: vec![0; 2 * 256],
        }
    }

    fn hist(&self, side: usize, m: Mv) -> i32 {
        self.history[side * 256 + (m as usize & 255)]
    }

    /// Ordered moves. Root: every legal wall. Elsewhere: the best walls that cut the opponent's
    /// current shortest path (only path-lengthening ones at the horizon).
    fn gen(&self, p: &Pos, depth: i32, ply: usize, tt_move: Mv, root: bool) -> Gen {
        let t = tables();
        let s = p.stm;
        let o = 1 - s;
        let me_map = p.dist_map(s);
        let opp_map = p.dist_map(o);
        let dm = me_map[p.pawn[s] as usize] as i32;
        let d_o = opp_map[p.pawn[o] as usize] as i32;
        let mut g = Gen { list: MoveList::new(), gain: [0; 140] };
        let killer = |m: Mv| ply < MAX_PLY && (self.killers[ply][0] == m || self.killers[ply][1] == m);

        let (tg, tn) = p.pawn_targets(s);
        for &q in &tg[..tn] {
            let m = q as Mv;
            let nd = me_map[q as usize] as i32;
            let k = if m == tt_move {
                1 << 30
            } else if nd == 0 {
                1 << 29
            } else if killer(m) {
                1 << 26
            } else {
                50_000 * (dm - nd) + 25_000 + self.hist(s, m)
            };
            g.list.push(m, k);
        }
        if p.left[s] == 0 {
            g.list.sort();
            return g;
        }
        let my_path = p.path(s, &me_map);
        let opp_path = p.path(o, &opp_map);
        let (my_dn, my_rt) = Pos::path_edges(&my_path);
        let (op_dn, op_rt) = Pos::path_edges(&opp_path);
        let (hc, vc) = if root {
            (u64::MAX, u64::MAX)
        } else {
            let mut hc = 0u64;
            let mut vc = 0u64;
            for x in bits128(op_dn) {
                hc |= t.hfor[x];
            }
            for x in bits128(op_rt) {
                vc |= t.vfor[x];
            }
            (hc, vc)
        };
        let mut walls: [(Mv, i32, i8); 128] = [(0, 0, 0); 128];
        let mut nw = 0;
        for v in 0..2 {
            let cand = if v == 0 { hc } else { vc };
            for a in bits64(cand) {
                if !p.fits(a, v) {
                    continue;
                }
                let q = p.with_wall(a, v);
                let cut = if v == 0 { t.hcut[a] } else { t.vcut[a] };
                let cuts_opp = cut & (if v == 0 { op_dn } else { op_rt }) != 0;
                let cuts_me = cut & (if v == 0 { my_dn } else { my_rt }) != 0;
                let nd_o = if cuts_opp { q.dist(o) as i32 } else { d_o };
                if nd_o == UNREACH as i32 {
                    continue;
                }
                let nd_m = if cuts_me { q.dist(s) as i32 } else { dm };
                if nd_m == UNREACH as i32 {
                    continue;
                }
                let gain = nd_o - d_o;
                if !root && depth <= 1 && gain <= 0 {
                    continue;
                }
                let m = wall_mv(a, v);
                let k = if m == tt_move {
                    1 << 30
                } else if killer(m) {
                    1 << 26
                } else {
                    50_000 * (gain - (nd_m - dm)) + self.hist(s, m)
                };
                walls[nw] = (m, k, gain as i8);
                nw += 1;
            }
        }
        if !root && nw > self.walls_k {
            walls[..nw].sort_by(|x, y| y.1.cmp(&x.1));
            nw = self.walls_k;
        }
        for &(m, k, gain) in &walls[..nw] {
            g.gain[g.list.n] = gain;
            g.list.push(m, k);
        }
        // Keep gains aligned while sorting: sort an index permutation.
        let n = g.list.n;
        let mut idx: Vec<usize> = (0..n).collect();
        idx.sort_by(|&x, &y| g.list.k[y].cmp(&g.list.k[x]));
        let mut out = Gen { list: MoveList::new(), gain: [0; 140] };
        for &i in &idx {
            out.gain[out.list.n] = g.gain[i];
            out.list.push(g.list.m[i], g.list.k[i]);
        }
        out
    }

    fn negamax(&mut self, p: &Pos, depth: i32, mut alpha: i32, beta: i32, ply: usize) -> i32 {
        self.nodes += 1;
        if self.nodes > self.budget {
            self.abort = true;
            return 0;
        }
        if let Some(w) = p.winner() {
            return if w == p.stm { WIN - ply as i32 } else { -WIN + ply as i32 };
        }
        if depth <= 0 || ply >= MAX_PLY - 1 {
            return p.eval();
        }
        let key = p.hash;
        let slot = (key as usize) & (TT_SIZE - 1);
        let e = self.tt[slot];
        let mut tt_move = NO_MOVE;
        if e.flag != 0 && e.key == key {
            tt_move = e.best;
            if e.depth as i32 >= depth {
                let sc = from_tt(e.score, ply);
                match e.flag {
                    1 => return sc,
                    2 if sc >= beta => return sc,
                    3 if sc <= alpha => return sc,
                    _ => {}
                }
            }
        }
        let g = self.gen(p, depth, ply, tt_move, false);
        let a0 = alpha;
        let mut best = -INF;
        let mut best_m = NO_MOVE;
        for i in 0..g.list.n {
            let m = g.list.m[i];
            let c = p.make(m);
            let sc = -self.negamax(&c, depth - 1, -beta, -alpha, ply + 1);
            if self.abort {
                return 0;
            }
            if sc > best {
                best = sc;
                best_m = m;
            }
            if sc > alpha {
                alpha = sc;
            }
            if alpha >= beta {
                if ply < MAX_PLY && self.killers[ply][0] != m {
                    self.killers[ply][1] = self.killers[ply][0];
                    self.killers[ply][0] = m;
                }
                let h = &mut self.history[p.stm * 256 + (m as usize & 255)];
                *h = (*h + depth * depth).min(20_000);
                break;
            }
        }
        if best_m == NO_MOVE {
            return p.eval();
        }
        let flag = if best <= a0 { 3 } else if best >= beta { 2 } else { 1 };
        self.tt[slot] = TtEntry { key, score: to_tt(best, ply), depth: depth as i8, flag, best: best_m };
        best
    }
}

fn to_tt(sc: i32, ply: usize) -> i32 {
    if sc > DECISIVE {
        sc + ply as i32
    } else if sc < -DECISIVE {
        sc - ply as i32
    } else {
        sc
    }
}

fn from_tt(sc: i32, ply: usize) -> i32 {
    if sc > DECISIVE {
        sc - ply as i32
    } else if sc < -DECISIVE {
        sc + ply as i32
    } else {
        sc
    }
}

fn gauss(rng: &mut Rng) -> f64 {
    (rng.f64() + rng.f64() + rng.f64() - 1.5) * 2.0
}

/// Choose a move for the side to move. `plies` = plies played so far (for the early-wall habit).
fn choose(p: &Pos, plies: u32, prm: Params, rng: &mut Rng) -> (Mv, u64) {
    let mut s = Search::new(prm.budget, prm.walls_k);
    let g = s.gen(p, 1, 0, NO_MOVE, true);
    if g.list.n == 0 {
        // Cannot happen (walls never seal a pawn in), but never panic.
        return (p.pawn[p.stm] as Mv, 0);
    }
    // A winning step is always taken.
    for i in 0..g.list.n {
        let m = g.list.m[i];
        if !is_wall(m) && p.make(m).winner() == Some(p.stm) {
            return (m, 1);
        }
    }
    let gains: Vec<(Mv, i8)> = (0..g.list.n).map(|i| (g.list.m[i], g.gain[i])).collect();
    let human = prm.noise > 0.0 || prm.slip > 0.0;
    let mut moves: Vec<Mv> = g.list.m[..g.list.n].to_vec();
    let mut done: Vec<(Mv, i32)> = moves.iter().map(|&m| (m, 0)).collect();
    for depth in 1..30 {
        let mut alpha = -INF;
        let mut best = -INF;
        let mut cur = vec![-INF; moves.len()];
        for (i, &m) in moves.iter().enumerate() {
            let c = p.make(m);
            let a = if human && best > -INF { (best - prm.margin - 1).max(-INF) } else { alpha };
            let sc = -s.negamax(&c, depth - 1, -INF, -a, 1);
            if s.abort {
                break;
            }
            cur[i] = sc;
            best = best.max(sc);
            alpha = alpha.max(sc);
        }
        if s.abort && depth > 1 {
            break;
        }
        s.abort = false;
        let mut idx: Vec<usize> = (0..moves.len()).collect();
        idx.sort_by(|&a, &b| cur[b].cmp(&cur[a]));
        done = idx.iter().map(|&i| (moves[i], cur[i])).collect();
        moves = done.iter().map(|&(m, _)| m).collect();
        if best.abs() > DECISIVE || s.nodes > prm.budget {
            break;
        }
    }
    let best = done[0].1;
    if !human || best.abs() > DECISIVE {
        return (done[0].0, s.nodes);
    }
    // The early-wall habit: a plausible blocking wall instead of a (better) pawn move.
    if !is_wall(done[0].0) && p.left[p.stm] >= 6 && plies < 30 && rng.chance(prm.waste) {
        let w = done.iter().find(|(m, sc)| {
            is_wall(*m) && *sc >= best - 160 && gains.iter().any(|(gm, gg)| gm == m && *gg >= 1)
        });
        if let Some(&(m, _)) = w {
            return (m, s.nodes);
        }
    }
    let mut cands: Vec<(Mv, f64)> = done
        .iter()
        .filter(|(_, sc)| *sc >= best - prm.margin && sc.abs() <= DECISIVE)
        .map(|&(m, sc)| (m, sc as f64 + gauss(rng) * prm.noise))
        .collect();
    if cands.is_empty() {
        return (done[0].0, s.nodes);
    }
    cands.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    let mut pick = 0;
    if cands.len() > 1 && rng.chance(prm.slip) {
        pick = 1 + rng.below(2.min(cands.len() - 1));
    }
    (cands[pick].0, s.nodes)
}

// ---------------------------------------------------------------------------------------------
// Session

#[derive(Clone, Copy)]
struct LastMove {
    who: usize,
    m: Mv,
    from: u8,
    ply: u64,
}

#[derive(Clone)]
struct Snapshot {
    pos: Pos,
    placed: Vec<(u8, u8, u8)>,
    last: Option<LastMove>,
    plies: u32,
    player_moves: u32,
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Status {
    Playing,
    Won,
    Lost,
    Draw,
}

pub struct Corridor {
    level: u32,
    prm: Params,
    seed: u64,
    pos: Pos,
    /// Placed walls in order: (anchor, orientation, owner).
    placed: Vec<(u8, u8, u8)>,
    history: Vec<Snapshot>,
    last: Option<LastMove>,
    serial: u64,
    plies: u32,
    player_moves: u32,
    status: Status,
    reason: &'static str,
    helped: bool,
    hint: Option<Value>,
    /// The AI's shortest path when the game ended (for stars / summary).
    final_ai_path: u8,
}

fn sq_json(s: usize) -> Value {
    json!([s / N, s % N])
}

fn mv_json(m: Mv) -> Value {
    if is_wall(m) {
        let (a, v) = wall_of(m);
        json!({"kind": "wall", "wall": [a / 8, a % 8, ori(v)]})
    } else {
        json!({"kind": "move", "to": sq_json(m as usize)})
    }
}

impl Corridor {
    pub fn new(level: u32) -> Self {
        let level = level.clamp(1, 500);
        let stm = if level % 2 == 1 { YOU } else { AI };
        Corridor {
            level,
            prm: params(level),
            seed: seed_for("corridor", level, 0),
            pos: Pos::start(stm),
            placed: vec![],
            history: vec![],
            last: None,
            serial: 0,
            plies: 0,
            player_moves: 0,
            status: Status::Playing,
            reason: "",
            helped: false,
            hint: None,
            final_ai_path: 0,
        }
    }

    fn apply(&mut self, m: Mv) {
        let who = self.pos.stm;
        let from = self.pos.pawn[who];
        if is_wall(m) {
            let (a, v) = wall_of(m);
            self.placed.push((a as u8, v as u8, who as u8));
        }
        self.pos = self.pos.make(m);
        self.serial += 1;
        self.plies += 1;
        if who == YOU {
            self.player_moves += 1;
        }
        self.last = Some(LastMove { who, m, from, ply: self.serial });
        self.hint = None;
        self.check_end();
    }

    fn check_end(&mut self) {
        if let Some(w) = self.pos.winner() {
            self.status = if w == YOU { Status::Won } else { Status::Lost };
            self.reason = "goal";
            self.final_ai_path = self.pos.dist(AI);
        } else if self.plies >= PLY_LIMIT {
            self.status = Status::Draw;
            self.reason = "ply_limit";
            self.final_ai_path = self.pos.dist(AI);
        }
    }

    fn stars(&self) -> u32 {
        if self.status != Status::Won {
            0
        } else if self.helped {
            1
        } else if self.final_ai_path >= 3 {
            3
        } else {
            2
        }
    }

    fn move_rng(&self) -> Rng {
        Rng::new(self.seed ^ self.pos.hash.rotate_left(17) ^ (self.plies as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15))
    }

    fn summary(&self) -> String {
        let why = match (self.status, self.reason) {
            (Status::Won, _) => format!("Rakibin hedefe {} adım uzaktaydı", self.final_ai_path),
            (Status::Lost, _) => format!("Rakip önce vardı · Sana {} adım kalmıştı", self.pos.dist(YOU)),
            _ => format!("{PLY_LIMIT} hamle sınırı doldu"),
        };
        format!("{why} · Kalan duvarın: {} · Hamle: {}", self.pos.left[YOU], self.player_moves)
    }

    fn parse_sq(v: &Value) -> Option<usize> {
        let a = v.as_array()?;
        if a.len() != 2 {
            return None;
        }
        let r = a[0].as_u64()? as usize;
        let c = a[1].as_u64()? as usize;
        (r < N && c < N).then_some(r * N + c)
    }

    fn parse_wall(v: &Value) -> Option<(usize, usize)> {
        let a = v.as_array()?;
        if a.len() != 3 {
            return None;
        }
        let r = a[0].as_u64()? as usize;
        let c = a[1].as_u64()? as usize;
        let o = match a[2].as_str()? {
            "h" => 0,
            "v" => 1,
            _ => return None,
        };
        (r < 8 && c < 8).then_some((r * 8 + c, o))
    }

    fn check_turn(&self) -> Result<(), String> {
        if self.status != Status::Playing {
            return Err("Oyun bitti".into());
        }
        if self.pos.stm != YOU {
            return Err("Sıra rakipte".into());
        }
        Ok(())
    }

    fn snapshot(&mut self) {
        self.history.push(Snapshot {
            pos: self.pos,
            placed: self.placed.clone(),
            last: self.last,
            plies: self.plies,
            player_moves: self.player_moves,
        });
    }

    fn player_step(&mut self, a: &Value) -> Result<(), String> {
        self.check_turn()?;
        let to = Self::parse_sq(&a["to"]).ok_or("Geçersiz kare")?;
        let p = self.pos;
        if to == p.pawn[YOU] as usize {
            return Err("Piyon yerinde kaldı".into());
        }
        if to == p.pawn[AI] as usize {
            return Err("Orada rakibin piyonu var".into());
        }
        let (tg, tn) = p.pawn_targets(YOU);
        if !tg[..tn].contains(&(to as u8)) {
            let a = p.pawn[YOU] as usize;
            let adjacent = (0..4).any(|d| {
                let q = match d {
                    0 if a >= N => Some(a - N),
                    1 if a + N < SQ => Some(a + N),
                    2 if a % N > 0 => Some(a - 1),
                    3 if a % N < N - 1 => Some(a + 1),
                    _ => None,
                };
                q == Some(to)
            });
            return Err(if adjacent { "Arada duvar var".into() } else { "Piyon bir kare gider (yüz yüzeyken atlar)".into() });
        }
        self.snapshot();
        self.apply(to as Mv);
        Ok(())
    }

    fn player_wall(&mut self, a: &Value) -> Result<(), String> {
        self.check_turn()?;
        let (anchor, v) = Self::parse_wall(&a["wall"]).ok_or("Geçersiz duvar")?;
        let p = self.pos;
        if p.left[YOU] == 0 {
            return Err("Duvarın kalmadı".into());
        }
        if !p.fits(anchor, v) {
            let t = tables();
            let crosses = p.walls[1 - v] & (1 << anchor) != 0 && p.walls[v] & (if v == 0 { t.hconf[anchor] } else { t.vconf[anchor] }) == 0;
            return Err(if crosses { "Duvarlar kesişemez".into() } else { "Bu oluk dolu".into() });
        }
        if !p.wall_legal(anchor, v) {
            return Err("Bu duvar bir piyonun yolunu tamamen kapatır".into());
        }
        self.snapshot();
        self.apply(wall_mv(anchor, v));
        Ok(())
    }

    fn ai_move(&mut self) -> Result<(), String> {
        if self.status != Status::Playing {
            return Err("Oyun bitti".into());
        }
        if self.pos.stm != AI {
            return Err("Sıra sende".into());
        }
        let mut rng = self.move_rng();
        let (m, _) = choose(&self.pos, self.plies, self.prm, &mut rng);
        self.apply(m);
        Ok(())
    }

    fn wall_slots(&self) -> Value {
        let p = &self.pos;
        let mut out = [String::with_capacity(64), String::with_capacity(64)];
        let dy = p.dist_map(YOU);
        let da = p.dist_map(AI);
        let (yd, yr) = Pos::path_edges(&p.path(YOU, &dy));
        let (ad, ar) = Pos::path_edges(&p.path(AI, &da));
        let t = tables();
        for (v, s) in out.iter_mut().enumerate() {
            for a in 0..64 {
                let ok = p.fits(a, v) && {
                    let cut = if v == 0 { t.hcut[a] } else { t.vcut[a] };
                    let (my, ai) = if v == 0 { (yd, ad) } else { (yr, ar) };
                    let q = p.with_wall(a, v);
                    (cut & my == 0 || q.dist(YOU) != UNREACH) && (cut & ai == 0 || q.dist(AI) != UNREACH)
                };
                s.push(if ok { '1' } else { '0' });
            }
        }
        let [h, v] = out;
        json!({"h": h, "v": v})
    }

    fn complexity(&self) -> f64 {
        let p = &self.pos;
        let gap = (p.dist(YOU) as f64 - p.dist(AI) as f64).abs();
        let walls = (p.left[0] + p.left[1]) as f64 / 20.0;
        let close = (1.0 - gap / 5.0).clamp(0.0, 1.0);
        (0.6 * close + 0.4 * walls * close + 0.2 * (self.placed.len() as f64 / 10.0).min(1.0)).clamp(0.0, 1.0)
    }
}

impl Session for Corridor {
    fn state(&self) -> Value {
        let status = match self.status {
            Status::Playing => "playing",
            Status::Won => "won",
            Status::Lost => "lost",
            Status::Draw => "draw",
        };
        let playing = self.status == Status::Playing;
        let p = &self.pos;
        let your_turn = playing && p.stm == YOU;
        let dy = p.dist_map(YOU);
        let my_path: Vec<Value> = p.path(YOU, &dy).into_iter().map(sq_json).collect();
        let targets: Vec<Value> = if your_turn {
            let (tg, tn) = p.pawn_targets(YOU);
            tg[..tn].iter().map(|&q| sq_json(q as usize)).collect()
        } else {
            vec![]
        };
        let walls: Vec<Value> = self
            .placed
            .iter()
            .map(|&(a, v, who)| {
                json!({"r": a / 8, "c": a % 8, "o": ori(v as usize), "who": if who as usize == YOU { "you" } else { "ai" }})
            })
            .collect();
        let last = self.last.map(|l| {
            let mut o = json!({
                "ply": l.ply,
                "who": if l.who == YOU { "you" } else { "ai" },
                "kind": if is_wall(l.m) { "wall" } else { "move" },
                "from": sq_json(l.from as usize),
            });
            if is_wall(l.m) {
                let (a, v) = wall_of(l.m);
                o["wall"] = json!([a / 8, a % 8, ori(v)]);
                o["to"] = sq_json(l.from as usize);
                o["jump"] = json!(false);
            } else {
                let (f, t) = (l.from as usize, l.m as usize);
                let manhattan = (f / N).abs_diff(t / N) + (f % N).abs_diff(t % N);
                o["to"] = sq_json(t);
                o["jump"] = json!(manhattan > 1);
            }
            o
        });
        let wall_slots = if your_turn && p.left[YOU] > 0 { self.wall_slots() } else { Value::Null };
        json!({
            "status": status,
            "stars": self.stars(),
            "title": rank(self.level),
            "goal": "Piyonunu karşı kenara rakibinden önce ulaştır",
            "level": self.level,
            "turn": if p.stm == YOU { "you" } else { "ai" },
            "ai_pending": playing && p.stm == AI,
            "pawns": {"you": sq_json(p.pawn[YOU] as usize), "ai": sq_json(p.pawn[AI] as usize)},
            "walls": walls,
            "walls_left": {"you": p.left[YOU], "ai": p.left[AI]},
            "walls_total": WALLS,
            "path": {"you": dy[p.pawn[YOU] as usize], "ai": p.dist(AI)},
            "my_path": my_path,
            "targets": targets,
            "wall_slots": wall_slots,
            "last_move": last,
            "hint": self.hint,
            "can_undo": playing && !self.history.is_empty(),
            "plies": self.plies,
            "ply_limit": PLY_LIMIT,
            "player_moves": self.player_moves,
            "complexity": self.complexity(),
            "end_reason": self.reason,
            "summary": if playing { Value::Null } else { Value::String(self.summary()) },
        })
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if a["undo"].as_bool() == Some(true) {
            if self.status != Status::Playing {
                return Err("Oyun bitti".into());
            }
            let snap = self.history.pop().ok_or("Geri alınacak hamle yok")?;
            self.pos = snap.pos;
            self.placed = snap.placed;
            self.last = snap.last;
            self.plies = snap.plies;
            self.player_moves = snap.player_moves;
            self.serial += 1;
            self.helped = true;
            self.hint = None;
            return Ok(());
        }
        if a["hint"].as_bool() == Some(true) {
            self.check_turn()?;
            let mut rng = self.move_rng();
            let (m, _) = choose(&self.pos, self.plies, full_strength(), &mut rng);
            self.hint = Some(mv_json(m));
            self.helped = true;
            return Ok(());
        }
        if a["ai"].as_bool() == Some(true) {
            return self.ai_move();
        }
        if a.get("wall").is_some() {
            return self.player_wall(a);
        }
        if a.get("to").is_some() {
            return self.player_step(a);
        }
        Err("Bilinmeyen hamle".into())
    }
}

pub fn create(level: u32, _mode: &str) -> Result<Box<dyn Session>, String> {
    Ok(Box::new(Corridor::new(level)))
}

// ---------------------------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn sq(r: usize, c: usize) -> usize {
        r * N + c
    }

    fn anchor(r: usize, c: usize) -> usize {
        r * 8 + c
    }

    /// A position with pawns and walls ([(r, c, v)]), side to move `stm`.
    fn pos_of(you: (usize, usize), ai: (usize, usize), walls: &[(usize, usize, usize)], stm: usize) -> Pos {
        let mut p = Pos::start(stm);
        let t = tables();
        p.hash ^= t.zpawn[YOU][p.pawn[YOU] as usize] ^ t.zpawn[AI][p.pawn[AI] as usize];
        p.pawn = [sq(you.0, you.1) as u8, sq(ai.0, ai.1) as u8];
        p.hash ^= t.zpawn[YOU][p.pawn[YOU] as usize] ^ t.zpawn[AI][p.pawn[AI] as usize];
        for &(r, c, v) in walls {
            assert!(p.fits(anchor(r, c), v));
            p = p.with_wall(anchor(r, c), v);
        }
        p
    }

    fn targets(p: &Pos, side: usize) -> Vec<(usize, usize)> {
        let (tg, tn) = p.pawn_targets(side);
        let mut v: Vec<_> = tg[..tn].iter().map(|&q| (q as usize / N, q as usize % N)).collect();
        v.sort();
        v
    }

    fn session_with(p: Pos) -> Corridor {
        let mut g = Corridor::new(1);
        g.pos = p;
        g
    }

    #[test]
    fn corridor_levels_and_params() {
        for lv in [1, 2, 3, 50, 137, 250, 400, 499, 500] {
            let g = Corridor::new(lv);
            let s = g.state();
            assert_eq!(s["status"], "playing");
            assert_eq!(s["turn"], if lv % 2 == 1 { "you" } else { "ai" });
            assert_eq!(s["ai_pending"], lv % 2 == 0);
            assert!(s["title"].is_string());
            assert_eq!(s["path"]["you"], 8);
            assert_eq!(s["path"]["ai"], 8);
            assert_eq!(s["walls_left"]["you"], 10);
            let p = params(lv);
            assert!(p.budget >= 1_500 && p.budget <= MAX_BUDGET);
        }
        assert!(params(1).budget < params(250).budget && params(250).budget < params(500).budget);
        assert_eq!(params(500).budget, MAX_BUDGET);
        assert!(params(1).noise > params(250).noise && params(500).noise < 1e-9);
        assert_eq!(params(500).waste, 0.0);
        assert_eq!(rank(1), "Acemi");
        assert_eq!(rank(500), "Büyükusta");
        let s = Corridor::new(1).state();
        assert_eq!(s["targets"].as_array().unwrap().len(), 3);
        let slots = s["wall_slots"]["h"].as_str().unwrap();
        assert_eq!(slots.len(), 64);
        assert!(!slots.contains('0'));
    }

    #[test]
    fn corridor_basic_steps_and_walls_block() {
        let p = pos_of((4, 4), (0, 0), &[], YOU);
        assert_eq!(targets(&p, YOU), vec![(3, 4), (4, 3), (4, 5), (5, 4)]);
        // h wall above (4,4): anchor (3,4) blocks (3,4)↕(4,4).
        let p = pos_of((4, 4), (0, 0), &[(3, 4, 0)], YOU);
        assert_eq!(targets(&p, YOU), vec![(4, 3), (4, 5), (5, 4)]);
        // h wall anchored (3,3) covers columns 3 and 4 too.
        let p = pos_of((4, 4), (0, 0), &[(3, 3, 0)], YOU);
        assert_eq!(targets(&p, YOU), vec![(4, 3), (4, 5), (5, 4)]);
        // v wall anchored (4,4) is right of (4,4) and (5,4).
        let p = pos_of((4, 4), (0, 0), &[(4, 4, 1)], YOU);
        assert_eq!(targets(&p, YOU), vec![(3, 4), (4, 3), (5, 4)]);
        // ...and anchored (3,4) also covers row 4.
        let p = pos_of((4, 4), (0, 0), &[(3, 4, 1)], YOU);
        assert_eq!(targets(&p, YOU), vec![(3, 4), (4, 3), (5, 4)]);
        // Corner: only two moves.
        let p = pos_of((8, 0), (0, 0), &[], YOU);
        assert_eq!(targets(&p, YOU), vec![(7, 0), (8, 1)]);
    }

    #[test]
    fn corridor_jumps() {
        // Straight jump over the face-to-face opponent.
        let p = pos_of((4, 4), (3, 4), &[], YOU);
        assert_eq!(targets(&p, YOU), vec![(2, 4), (4, 3), (4, 5), (5, 4)]);
        // Wall behind the opponent → diagonal jumps to both sides.
        let p = pos_of((4, 4), (3, 4), &[(2, 4, 0)], YOU);
        assert_eq!(targets(&p, YOU), vec![(3, 3), (3, 5), (4, 3), (4, 5), (5, 4)]);
        // Wall behind + wall on one side → only the other diagonal.
        // (v at (3,4) is right of (3,4) and (4,4), so (4,5) is walled off too.)
        let p = pos_of((4, 4), (3, 4), &[(2, 4, 0), (3, 4, 1)], YOU);
        assert_eq!(targets(&p, YOU), vec![(3, 3), (4, 3), (5, 4)]);
        // Board edge behind the opponent → diagonals.
        let p = pos_of((1, 4), (0, 4), &[], YOU);
        assert_eq!(targets(&p, YOU), vec![(0, 3), (0, 5), (1, 3), (1, 5), (2, 4)]);
        // Sideways face-to-face with edge behind: (4,7) vs (4,8) → (3,8), (5,8).
        let p = pos_of((4, 7), (4, 8), &[], YOU);
        assert_eq!(targets(&p, YOU), vec![(3, 7), (3, 8), (4, 6), (5, 7), (5, 8)]);
        // A wall between the pawns: no jump at all.
        let p = pos_of((4, 4), (3, 4), &[(3, 4, 0)], YOU);
        assert_eq!(targets(&p, YOU), vec![(4, 3), (4, 5), (5, 4)]);
        // Through the session: jumping lands and is reported as a jump.
        let mut g = session_with(pos_of((4, 4), (3, 4), &[], YOU));
        g.act(&json!({"to": [2, 4]})).unwrap();
        let s = g.state();
        assert_eq!(s["pawns"]["you"], json!([2, 4]));
        assert_eq!(s["last_move"]["jump"], true);
        assert_eq!(s["last_move"]["kind"], "move");
    }

    #[test]
    fn corridor_wall_rules() {
        let mut g = session_with(pos_of((8, 4), (0, 4), &[(3, 3, 0)], YOU));
        let before = g.state();
        // Overlap (same groove, shifted by one) and identical.
        for w in [json!([3, 2, "h"]), json!([3, 4, "h"]), json!([3, 3, "h"])] {
            let e = g.act(&json!({"wall": w})).unwrap_err();
            assert_eq!(e, "Bu oluk dolu", "{w}");
            assert_eq!(g.state(), before);
        }
        // Crossing.
        let e = g.act(&json!({"wall": [3, 3, "v"]})).unwrap_err();
        assert_eq!(e, "Duvarlar kesişemez");
        assert_eq!(g.state(), before);
        let slots = before["wall_slots"]["h"].as_str().unwrap().as_bytes();
        assert_eq!(slots[anchor(3, 2)], b'0');
        assert_eq!(slots[anchor(3, 4)], b'0');
        assert_eq!(slots[anchor(3, 5)], b'1');
        assert_eq!(before["wall_slots"]["v"].as_str().unwrap().as_bytes()[anchor(3, 3)], b'0');
        // Touching end to end, and a T-junction, are fine.
        g.act(&json!({"wall": [3, 5, "h"]})).unwrap();
        let mut g = session_with(pos_of((8, 4), (0, 4), &[(3, 3, 0)], YOU));
        g.act(&json!({"wall": [2, 4, "v"]})).unwrap();
        // Vertical overlap.
        let mut g = session_with(pos_of((8, 4), (0, 4), &[(4, 4, 1)], YOU));
        for w in [json!([3, 4, "v"]), json!([5, 4, "v"])] {
            assert_eq!(g.act(&json!({"wall": w})).unwrap_err(), "Bu oluk dolu");
        }
        g.act(&json!({"wall": [6, 4, "v"]})).unwrap();
        // Blocking: box the player in the bottom-left corner region.
        let p = pos_of((8, 0), (0, 8), &[(7, 0, 0)], YOU);
        let mut g = session_with(p);
        let before = g.state();
        let slots = before["wall_slots"]["v"].as_str().unwrap();
        assert_eq!(&slots[anchor(7, 0)..anchor(7, 0) + 1], "0");
        let e = g.act(&json!({"wall": [7, 0, "v"]})).unwrap_err();
        // (7,0,v) crosses the h wall on the same anchor.
        assert_eq!(e, "Duvarlar kesişemez");
        // Vertical wall right of (7,1)/(8,1)… use h (7,0) + v at (7,1): (8,0),(8,1) still open to (8,2)? Build a
        // real trap: h over (8,0)-(8,1) and v right of (7,1)-(8,1) leaves (8,0),(8,1) sealed.
        let p = pos_of((8, 0), (0, 8), &[(7, 0, 0)], YOU);
        let mut g = session_with(p);
        let before = g.state();
        assert_eq!(&before["wall_slots"]["v"].as_str().unwrap()[anchor(7, 1)..anchor(7, 1) + 1], "0");
        let e = g.act(&json!({"wall": [7, 1, "v"]})).unwrap_err();
        assert_eq!(e, "Bu duvar bir piyonun yolunu tamamen kapatır");
        assert_eq!(g.state(), before);
        // The same rule protects the AI's pawn.
        let p = pos_of((8, 4), (0, 8), &[(0, 7, 0)], YOU);
        let mut g = session_with(p);
        let e = g.act(&json!({"wall": [0, 6, "v"]})).unwrap_err();
        assert_eq!(e, "Bu duvar bir piyonun yolunu tamamen kapatır");
        // Out of walls.
        let mut p = pos_of((8, 4), (0, 4), &[], YOU);
        p.left[YOU] = 0;
        let mut g = session_with(p);
        assert!(g.state()["wall_slots"].is_null());
        assert_eq!(g.act(&json!({"wall": [5, 5, "h"]})).unwrap_err(), "Duvarın kalmadı");
    }

    #[test]
    fn corridor_illegal_actions_rejected() {
        let mut g = Corridor::new(1);
        let before = g.state();
        for a in [
            json!({"to": [6, 4]}),          // two squares
            json!({"to": [7, 3]}),          // diagonal
            json!({"to": [8, 4]}),          // stay
            json!({"to": [9, 4]}),          // off board
            json!({"to": [0, 4]}),          // AI's pawn
            json!({"wall": [8, 0, "h"]}),   // anchor off range
            json!({"wall": [3, 3, "x"]}),   // bad orientation
            json!({"wall": [3, 3]}),
            json!({"ai": true}),            // not the AI's turn
            json!({"undo": true}),          // nothing to undo
            json!({"foo": 1}),
        ] {
            assert!(g.act(&a).is_err(), "{a}");
            assert_eq!(g.state(), before, "{a}");
        }
        g.act(&json!({"to": [7, 4]})).unwrap();
        let mid = g.state();
        assert!(g.act(&json!({"to": [6, 4]})).is_err()); // AI's turn now
        assert!(g.act(&json!({"wall": [2, 2, "h"]})).is_err());
        assert!(g.act(&json!({"hint": true})).is_err());
        assert_eq!(g.state(), mid);
        g.act(&json!({"ai": true})).unwrap();
        assert_eq!(g.state()["turn"], "you");
        assert!(g.act(&json!({"ai": true})).is_err());
        // Wall in the way.
        let mut g = session_with(pos_of((4, 4), (0, 0), &[(3, 4, 0)], YOU));
        let before = g.state();
        assert_eq!(g.act(&json!({"to": [3, 4]})).unwrap_err(), "Arada duvar var");
        assert_eq!(g.state(), before);
    }

    #[test]
    fn corridor_win_draw_and_stars() {
        // One step from the goal, no help, AI far away → 3 stars.
        let mut g = session_with(pos_of((1, 4), (2, 0), &[], YOU));
        g.act(&json!({"to": [0, 4]})).unwrap();
        let s = g.state();
        assert_eq!(s["status"], "won");
        assert_eq!(s["stars"], 3);
        assert!(s["summary"].as_str().unwrap().contains("6 adım"));
        // AI close → 2 stars.
        let mut g = session_with(pos_of((1, 4), (7, 0), &[], YOU));
        g.act(&json!({"to": [0, 4]})).unwrap();
        assert_eq!(g.state()["stars"], 2);
        // With a hint → 1 star.
        let mut g = session_with(pos_of((1, 4), (2, 0), &[], YOU));
        g.act(&json!({"hint": true})).unwrap();
        assert_eq!(g.state()["hint"]["kind"], "move");
        assert_eq!(g.state()["hint"]["to"], json!([0, 4]));
        g.act(&json!({"to": [0, 4]})).unwrap();
        assert_eq!(g.state()["stars"], 1);
        // The AI wins when it can.
        let mut g = session_with(pos_of((4, 4), (7, 2), &[], AI));
        g.act(&json!({"ai": true})).unwrap();
        assert_eq!(g.state()["status"], "lost");
        assert_eq!(g.state()["stars"], 0);
        // Ply cap → draw.
        let mut g = session_with(pos_of((4, 0), (4, 8), &[], YOU));
        g.plies = PLY_LIMIT - 1;
        g.act(&json!({"to": [5, 0]})).unwrap();
        assert_eq!(g.state()["status"], "draw");
        assert_eq!(g.state()["end_reason"], "ply_limit");
    }

    #[test]
    fn corridor_even_level_ai_starts_and_undo_works() {
        let mut g = Corridor::new(2);
        assert_eq!(g.state()["turn"], "ai");
        g.act(&json!({"ai": true})).unwrap();
        let s0 = g.state();
        let a = s0["wall_slots"]["h"].as_str().unwrap().rfind('1').unwrap();
        g.act(&json!({"wall": [a / 8, a % 8, "h"]})).unwrap();
        g.act(&json!({"ai": true})).unwrap();
        assert_eq!(g.state()["can_undo"], true);
        g.act(&json!({"undo": true})).unwrap();
        let s1 = g.state();
        assert_eq!(s1["pawns"], s0["pawns"]);
        assert_eq!(s1["walls"], s0["walls"]);
        assert_eq!(s1["walls_left"], s0["walls_left"]);
        assert_eq!(s1["turn"], "you");
        assert!(g.helped);
    }

    #[test]
    fn corridor_last_move_reports_walls() {
        let mut g = Corridor::new(1);
        g.act(&json!({"wall": [1, 3, "v"]})).unwrap();
        let s = g.state();
        assert_eq!(s["last_move"]["kind"], "wall");
        assert_eq!(s["last_move"]["wall"], json!([1, 3, "v"]));
        assert_eq!(s["last_move"]["who"], "you");
        assert_eq!(s["walls"][0]["who"], "you");
        let ply = s["last_move"]["ply"].as_u64().unwrap();
        g.act(&json!({"ai": true})).unwrap();
        assert!(g.state()["last_move"]["ply"].as_u64().unwrap() > ply);
        assert_eq!(g.state()["last_move"]["who"], "ai");
    }

    #[test]
    fn corridor_ai_sees_the_race() {
        // The AI (to move) is one step from its goal: it must step, not wall.
        let p = pos_of((2, 4), (7, 4), &[], AI);
        let mut rng = Rng::new(1);
        let (m, _) = choose(&p, 40, params(1), &mut rng);
        assert_eq!(m as usize, sq(8, 4));
        // The player is about to win and the AI is far behind: it has to wall the player off.
        let p = pos_of((1, 4), (1, 0), &[], AI);
        let (m, _) = choose(&p, 40, full_strength(), &mut rng);
        assert!(is_wall(m), "AI should block, played {m}");
        let c = p.make(m);
        assert!(c.dist(YOU) >= 2);
    }

    /// Play one AI-vs-AI game: +1 if side A (moving as YOU) wins, −1 if it loses, 0 draw.
    fn duel(a: Params, b: Params, seed: u64, a_first: bool) -> (i32, u32) {
        let mut p = Pos::start(if a_first { YOU } else { AI });
        let mut rng = Rng::new(seed);
        for plies in 0..PLY_LIMIT {
            if let Some(w) = p.winner() {
                return (if w == YOU { 1 } else { -1 }, plies);
            }
            let prm = if p.stm == YOU { a } else { b };
            let m = if plies < 2 {
                let (tg, tn) = p.pawn_targets(p.stm);
                tg[rng.below(tn)] as Mv
            } else {
                choose(&p, plies, prm, &mut rng).0
            };
            p = p.make(m);
        }
        (0, PLY_LIMIT)
    }

    #[test]
    fn corridor_ai_games_terminate() {
        for (i, lv) in [1u32, 137, 500].into_iter().enumerate() {
            let (r, plies) = duel(params(lv), params(1), 77 + i as u64, i % 2 == 0);
            assert!(plies < PLY_LIMIT, "level {lv}");
            assert_ne!(r, 0);
        }
    }

    #[test]
    fn corridor_strong_beats_weak() {
        let mut wins = 0;
        for g in 0..10u64 {
            let (r, _) = duel(params(500), params(1), 1000 + g, g % 2 == 0);
            if r > 0 {
                wins += 1;
            }
        }
        assert!(wins >= 8, "strong won {wins}/10");
    }

    #[test]
    fn corridor_deterministic() {
        let run = || {
            let mut g = Corridor::new(3);
            let mut seq = vec![];
            for i in 0..14 {
                if g.status != Status::Playing {
                    break;
                }
                let st = g.state();
                if st["turn"] == "you" {
                    if i % 4 == 0 {
                        let walls = ["h", "v"];
                        let slots = st["wall_slots"]["h"].as_str().unwrap();
                        let a = slots.find('1').unwrap() + i * 3 % 20;
                        let _ = g.act(&json!({"wall": [a / 8, a % 8, walls[i % 2]]}));
                    }
                    if g.state()["turn"] == "you" {
                        let t = st["targets"][0].clone();
                        g.act(&json!({"to": t})).unwrap();
                    }
                } else {
                    g.act(&json!({"ai": true})).unwrap();
                    seq.push(g.state()["last_move"].clone());
                }
            }
            seq
        };
        assert_eq!(run(), run());
    }

    #[test]
    #[ignore]
    fn corridor_strength_table() {
        for (a, b) in [(500u32, 1u32), (250, 1), (100, 1), (40, 1), (500, 250), (250, 100)] {
            let (mut w, mut d, mut l, mut plies) = (0, 0, 0, 0);
            for g in 0..12u64 {
                let (r, n) = duel(params(a), params(b), 5000 + g, g % 2 == 0);
                plies += n;
                match r {
                    1 => w += 1,
                    0 => d += 1,
                    _ => l += 1,
                }
            }
            println!("L{a} vs L{b}: +{w} ={d} -{l} · avg plies {}", plies / 12);
        }
    }

    #[test]
    #[ignore]
    fn corridor_timing() {
        for lv in [1u32, 250, 500] {
            let prm = params(lv);
            let mut total = 0.0f64;
            let mut worst = 0.0f64;
            let mut n = 0;
            let mut nodes = 0u64;
            for g in 0..4u64 {
                let mut p = Pos::start(YOU);
                let mut rng = Rng::new(g);
                for ply in 0..120u32 {
                    if p.winner().is_some() {
                        break;
                    }
                    let t0 = std::time::Instant::now();
                    let (m, nd) = if ply < 2 {
                        let (tg, tn) = p.pawn_targets(p.stm);
                        (tg[rng.below(tn)] as Mv, 0)
                    } else {
                        choose(&p, ply, prm, &mut rng)
                    };
                    let dt = t0.elapsed().as_secs_f64() * 1000.0;
                    if ply >= 2 {
                        total += dt;
                        worst = worst.max(dt);
                        n += 1;
                        nodes += nd;
                    }
                    p = p.make(m);
                }
            }
            println!(
                "level {lv}: budget {} · avg {:.2} ms · worst {:.2} ms · avg nodes {} · moves {n}",
                prm.budget,
                total / n as f64,
                worst,
                nodes / n as u64
            );
        }
    }
}
