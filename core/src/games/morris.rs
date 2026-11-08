//! Cırtcak (Nine Men's Morris, "9 Taş") against an AI opponent.
//!
//! Board: 24 points on three concentric squares; the side midpoints are joined between squares
//! (no diagonals). Point numbering (7×7 grid coordinates in `COORDS`):
//!
//! ```text
//!  0-----------1-----------2
//!  |   3-------4-------5   |
//!  |   |   6---7---8   |   |
//!  9--10--11      12--13--14
//!  |   |  15--16--17   |   |
//!  |  18------19------20   |
//! 21----------22----------23
//! ```
//!
//! Rules: each side has 9 pieces. Phase 1: sides alternate placing a piece on an empty point.
//! Phase 2 (once all 18 are placed): move a piece along a line to an adjacent empty point. A side
//! reduced to exactly 3 pieces **flies** (may move to any empty point). Forming three in a row on a
//! line (a mill, by placing or moving) removes one opponent piece that is not in a mill — unless all
//! of them are in mills. Re-opening and closing the same mill counts again. A side with fewer than 3
//! pieces, or a side to move with no legal move (blocked), loses.
//!
//! Draws (`status: "draw"`): (1) the same position (same pieces, same side to move) occurs for the
//! third time; (2) 50 moves by each side (100 plies) in phase 2 without any removal.
//!
//! Turn protocol: the player is side 0 (light), the AI side 1 (dark). Odd levels the player starts,
//! even levels the AI starts. A player mill leaves a pending removal step (`pending_remove`, list
//! `removable`); the AI does its removal inside its own `{"ai":true}` move.
//!
//! AI: negamax alpha-beta with iterative deepening under a **node budget** (deterministic),
//! transposition table (cleared per move), move ordering (TT move, mills/removals, blocking the
//! opponent's mill point, killers, history), repetition/50-move draws inside the search, and a
//! phase-aware evaluation (material, mills, open twos, closable threats, running "cırtcak" mills,
//! blocked pieces, mobility, point control, flying threats).
//!
//! Strength curve (`params`): with u = ½·ln L/ln 500 + ½·(L−1)/499 (0 → 1):
//!   budget = 12 000 · 33.3^u nodes (L1 = 12k ≈ 5 plies deep, L250 ≈ 140k ≈ 8 plies,
//!   L500 = 400k ≈ 9–10 plies), eval noise σ = 35·(1−u)^1.4 centipieces, "human" slip (2nd/3rd
//!   best) with p = 0.10·(1−u)², only among moves within margin = 80·(1−u) centipieces of the best
//!   (less than a piece, so a slip never knowingly hangs a piece). L ≥ ~400 is near full strength.
//!   Ranks: 1–40 Acemi, 41–100 Çırak, 101–180 Kalfa, 181–280 Usta, 281–390 Üstat, 391+ Büyükusta.
//!
//! Stars on a win: 3 = no undo/hint and ≥ 5 own pieces left (board + hand), 2 = no undo/hint,
//! 1 = undo or hint used.
//!
//! State: `{status, stars, title, goal, summary, level, rank, rank_index, turn: "you"|"ai",
//!          ai_pending, you_first, board: [24 × 0 empty | 1 you | 2 ai], phase: "place"|"move",
//!          hand: [you, ai], on_board: [you, ai], captured: [by you, by ai], flying: [you, ai],
//!          pending_remove, removable: [p], can_place, targets: [24 × [to]] (your movable pieces),
//!          mills: [{owner: 1|2, points: [a,b,c]}], last_move: {ply, who, kind, from, to, removed,
//!          mills} | null, plies, your_moves, quiet, draw_in, repeats, can_undo, hint: {from, to,
//!          remove} | null, used_help, end_reason, ai_moves, version}`
//! `last_move.ply` is an event serial: +1 for each placement/move/removal event (restored on undo).
//! Actions: `{"place":p}` · `{"from":a,"to":b}` · `{"remove":p}` · `{"ai":true}` · `{"undo":true}`
//! (back to the start of your previous turn, AI reply included) · `{"hint":true}`.

use crate::rng::{seed_for, Rng};
use crate::Session;
use serde_json::{json, Value};

const FULL: u32 = (1 << 24) - 1;
const NONE: u8 = 24;
const WIN: i32 = 100_000;
const MATE_ZONE: i32 = WIN - 1_000;
const INF: i32 = 1_000_000;
const MAX_PLY: usize = 64;
const DRAW_QUIET: u16 = 100;

const MILLS: [[usize; 3]; 16] = [
    [0, 1, 2],
    [3, 4, 5],
    [6, 7, 8],
    [9, 10, 11],
    [12, 13, 14],
    [15, 16, 17],
    [18, 19, 20],
    [21, 22, 23],
    [0, 9, 21],
    [3, 10, 18],
    [6, 11, 15],
    [1, 4, 7],
    [16, 19, 22],
    [8, 12, 17],
    [5, 13, 20],
    [2, 14, 23],
];

/// (x, y) on a 7×7 grid, for the view and for documentation.
pub const COORDS: [(u8, u8); 24] = [
    (0, 0), (3, 0), (6, 0), (1, 1), (3, 1), (5, 1), (2, 2), (3, 2), (4, 2), (0, 3), (1, 3), (2, 3),
    (4, 3), (5, 3), (6, 3), (2, 4), (3, 4), (4, 4), (1, 5), (3, 5), (5, 5), (0, 6), (3, 6), (6, 6),
];

const fn build_masks() -> [u32; 16] {
    let mut m = [0u32; 16];
    let mut i = 0;
    while i < 16 {
        m[i] = (1 << MILLS[i][0]) | (1 << MILLS[i][1]) | (1 << MILLS[i][2]);
        i += 1;
    }
    m
}
const MASK: [u32; 16] = build_masks();

/// Lines between points are exactly the consecutive pairs of every mill line.
const fn build_adj() -> [u32; 24] {
    let mut a = [0u32; 24];
    let mut i = 0;
    while i < 16 {
        let m = MILLS[i];
        a[m[0]] |= 1 << m[1];
        a[m[1]] |= (1 << m[0]) | (1 << m[2]);
        a[m[2]] |= 1 << m[1];
        i += 1;
    }
    a
}
const ADJ: [u32; 24] = build_adj();

/// The two mill lines through every point.
const fn build_point_mills() -> [[u32; 2]; 24] {
    let mut pm = [[0u32; 2]; 24];
    let mut n = [0usize; 24];
    let mut i = 0;
    while i < 16 {
        let mut k = 0;
        while k < 3 {
            let p = MILLS[i][k];
            pm[p][n[p]] = MASK[i];
            n[p] += 1;
            k += 1;
        }
        i += 1;
    }
    pm
}
const PM: [[u32; 2]; 24] = build_point_mills();

const fn splitmix(x: u64) -> u64 {
    let mut z = x.wrapping_add(0x9E37_79B9_7F4A_7C15);
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}
/// Zobrist keys: [side*24 + point] pieces, [48] side to move, [49 + side*10 + n] pieces in hand.
const fn build_zobrist() -> [u64; 69] {
    let mut z = [0u64; 69];
    let mut i = 0;
    while i < 69 {
        z[i] = splitmix(0x5EED_0000 + i as u64 * 0x1_0001);
        i += 1;
    }
    z
}
const Z: [u64; 69] = build_zobrist();
const Z_STM: u64 = Z[48];
const fn zhand(side: usize, n: u8) -> u64 {
    Z[49 + side * 10 + n as usize]
}

#[inline]
fn bits(mut b: u32) -> impl Iterator<Item = usize> {
    std::iter::from_fn(move || {
        if b == 0 {
            None
        } else {
            let i = b.trailing_zeros() as usize;
            b &= b - 1;
            Some(i)
        }
    })
}

#[inline]
fn forms_mill(own: u32, to: usize) -> bool {
    let [a, b] = PM[to];
    own & a == a || own & b == b
}

/// Opponent pieces that may be taken: those outside mills, or any if all are in mills.
fn removable(opp: u32) -> u32 {
    let mut inmill = 0;
    for &m in &MASK {
        if opp & m == m {
            inmill |= m;
        }
    }
    let r = opp & !inmill;
    if r == 0 {
        opp
    } else {
        r
    }
}

fn mills_of(own: u32) -> impl Iterator<Item = usize> {
    (0..16).filter(move |&i| own & MASK[i] == MASK[i])
}

/// One ply: `from == NONE` places from the hand; `rem != NONE` removes that opponent piece.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Mv {
    pub from: u8,
    pub to: u8,
    pub rem: u8,
}

impl Mv {
    fn pack(self) -> u32 {
        self.from as u32 | (self.to as u32) << 5 | (self.rem as u32) << 10
    }
    fn hist_idx(self) -> usize {
        self.from as usize * 24 + self.to as usize
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Pos {
    pub bb: [u32; 2],
    pub hand: [u8; 2],
    pub stm: usize,
    /// Plies in phase 2 since the last removal.
    pub quiet: u16,
    pub hash: u64,
}

impl Pos {
    pub fn start(stm: usize) -> Pos {
        let mut hash = zhand(0, 9) ^ zhand(1, 9);
        if stm == 1 {
            hash ^= Z_STM;
        }
        Pos { bb: [0, 0], hand: [9, 9], stm, quiet: 0, hash }
    }

    #[cfg(test)]
    fn rehash(&mut self) {
        let mut h = zhand(0, self.hand[0]) ^ zhand(1, self.hand[1]);
        if self.stm == 1 {
            h ^= Z_STM;
        }
        for s in 0..2 {
            for p in bits(self.bb[s]) {
                h ^= Z[s * 24 + p];
            }
        }
        self.hash = h;
    }

    pub fn total(&self, s: usize) -> u32 {
        self.bb[s].count_ones() + self.hand[s] as u32
    }
    fn empty(&self) -> u32 {
        !(self.bb[0] | self.bb[1]) & FULL
    }
    fn placing(&self) -> bool {
        self.hand[0] + self.hand[1] > 0
    }
    pub fn flying(&self, s: usize) -> bool {
        self.hand[s] == 0 && self.bb[s].count_ones() == 3
    }

    pub fn apply(&self, m: Mv) -> Pos {
        let s = self.stm;
        let o = 1 - s;
        let mut p = *self;
        if m.from == NONE {
            p.hash ^= zhand(s, p.hand[s]) ^ zhand(s, p.hand[s] - 1);
            p.hand[s] -= 1;
        } else {
            p.bb[s] &= !(1 << m.from);
            p.hash ^= Z[s * 24 + m.from as usize];
        }
        p.bb[s] |= 1 << m.to;
        p.hash ^= Z[s * 24 + m.to as usize];
        if m.rem != NONE {
            p.bb[o] &= !(1 << m.rem);
            p.hash ^= Z[o * 24 + m.rem as usize];
            p.quiet = 0;
        } else if m.from != NONE {
            p.quiet = self.quiet + 1;
        } else {
            p.quiet = 0;
        }
        p.stm = o;
        p.hash ^= Z_STM;
        p
    }

    /// Destinations of the piece on `from` for the side to move (empty if it can't move).
    fn dests(&self, from: usize) -> u32 {
        let empty = self.empty();
        if self.flying(self.stm) {
            empty
        } else {
            ADJ[from] & empty
        }
    }

    fn gen(&self, out: &mut Vec<Mv>) {
        out.clear();
        let s = self.stm;
        let own = self.bb[s];
        let opp = self.bb[1 - s];
        let empty = self.empty();
        let rem = removable(opp);
        let mut push = |from: u8, to: usize, own_after: u32| {
            if opp != 0 && forms_mill(own_after, to) {
                for r in bits(rem) {
                    out.push(Mv { from, to: to as u8, rem: r as u8 });
                }
            } else {
                out.push(Mv { from, to: to as u8, rem: NONE });
            }
        };
        if self.hand[s] > 0 {
            for to in bits(empty) {
                push(NONE, to, own | 1 << to);
            }
        } else {
            let fly = own.count_ones() == 3;
            for from in bits(own) {
                let d = if fly { empty } else { ADJ[from] & empty };
                for to in bits(d) {
                    push(from as u8, to, (own & !(1 << from)) | 1 << to);
                }
            }
        }
    }

    fn has_move(&self) -> bool {
        let s = self.stm;
        if self.hand[s] > 0 || self.flying(s) {
            return self.empty() != 0;
        }
        let empty = self.empty();
        bits(self.bb[s]).any(|p| ADJ[p] & empty != 0)
    }

    /// Mills that this move closes (for the view).
    fn closed_mills(&self, m: Mv) -> Vec<usize> {
        let s = self.stm;
        let mut own = self.bb[s];
        if m.from != NONE {
            own &= !(1 << m.from);
        }
        own |= 1 << m.to;
        (0..16).filter(|&i| MASK[i] & (1 << m.to) != 0 && own & MASK[i] == MASK[i]).collect()
    }
}

// ---------------------------------------------------------------------------------------------
// Evaluation (centipieces, from the side to move's point of view)

const POINT_VALUE: [i32; 24] = {
    let mut v = [0i32; 24];
    let mut p = 0;
    while p < 24 {
        v[p] = match ADJ[p].count_ones() {
            4 => 7,
            3 => 3,
            _ => 0,
        };
        p += 1;
    }
    v
};

/// Empty points that would complete a line holding two pieces of `own` and none of `opp`.
fn two_points(own: u32, opp: u32) -> (u32, i32) {
    let mut pts = 0;
    let mut n = 0;
    for &m in &MASK {
        if (own & m).count_ones() == 2 && opp & m == 0 {
            pts |= m & !own;
            n += 1;
        }
    }
    (pts, n)
}

fn side_eval(pos: &Pos, s: usize) -> i32 {
    let own = pos.bb[s];
    let opp = pos.bb[1 - s];
    let empty = pos.empty();
    let mut sc = pos.total(s) as i32 * 100;
    let mills = mills_of(own).count() as i32;
    let (_, twos) = two_points(own, opp);
    if pos.placing() {
        sc += mills * 22 + twos * 20;
        // A fork point: placing there would create two open twos at once.
        let mut forks = 0;
        for p in bits(empty) {
            let [a, b] = PM[p];
            if (own & a).count_ones() == 1 && opp & a == 0 && (own & b).count_ones() == 1 && opp & b == 0 {
                forks += 1;
            }
        }
        sc += forks * 9;
        for p in bits(own) {
            sc += POINT_VALUE[p];
            let lib = (ADJ[p] & empty).count_ones() as i32;
            sc += lib * 2;
            if lib == 0 {
                sc -= 8;
            }
        }
        return sc;
    }
    if pos.flying(s) {
        // A flying side threatens to close every open two anywhere.
        sc += twos * 45 + mills * 8;
        return sc;
    }
    let opp_fly = pos.flying(1 - s);
    let mut mobility = 0;
    let mut blocked = 0;
    for p in bits(own) {
        let lib = (ADJ[p] & empty).count_ones() as i32;
        mobility += lib;
        if lib == 0 {
            blocked += 1;
        }
    }
    sc += mobility.min(14) * 6 - blocked * 9;
    sc += mills * 14;
    // Closable threats: an own piece off the line can step into the open point.
    let opp_reach = if opp_fly { empty } else { bits(opp).fold(0, |acc, p| acc | ADJ[p]) };
    for m in MASK {
        if (own & m).count_ones() == 2 && opp & m == 0 {
            let e = (m & !own).trailing_zeros() as usize;
            if ADJ[e] & own & !m != 0 {
                sc += 30;
                if opp_reach & (1 << e) == 0 {
                    sc += 20;
                }
            } else {
                sc += 6;
            }
        }
    }
    // Mills that can open and re-close; a running mill ("cırtcak") closes a mill on every move.
    for i in mills_of(own) {
        for p in bits(MASK[i]) {
            for q in bits(ADJ[p] & empty) {
                if forms_mill((own & !(1 << p)) | 1 << q, q) {
                    sc += 70;
                    if opp_reach & (1 << p) == 0 {
                        sc += 45;
                    }
                } else if opp_reach & (1 << p) == 0 {
                    sc += 12;
                }
            }
        }
    }
    sc
}

pub fn eval(pos: &Pos) -> i32 {
    let s = pos.stm;
    let mut sc = side_eval(pos, s) - side_eval(pos, 1 - s);
    // Tempo: the side to move closes an open mill point right away.
    let own = pos.bb[s];
    let opp = pos.bb[1 - s];
    let free = pos.hand[s] > 0 || pos.flying(s);
    let closable = MASK.iter().any(|&m| {
        (own & m).count_ones() == 2 && opp & m == 0 && (free || ADJ[(m & !own).trailing_zeros() as usize] & own & !m != 0)
    });
    if closable {
        sc += 55;
    }
    sc
}

// ---------------------------------------------------------------------------------------------
// Search

#[derive(Clone, Copy, Default)]
struct TtEntry {
    key: u64,
    mv: u32,
    score: i32,
    depth: i8,
    flag: u8, // 0 empty, 1 exact, 2 lower, 3 upper
}

const TT_BITS: u32 = 16;

pub struct Searcher {
    budget: u64,
    pub nodes: u64,
    /// Deepest fully completed iteration.
    pub depth: i32,
    aborted: bool,
    iter: i32,
    tt: Vec<TtEntry>,
    killers: [[u32; 2]; MAX_PLY],
    history: Vec<i32>,
    path: Vec<u64>,
    bufs: Vec<Vec<Mv>>,
}

#[derive(Clone, Copy, Debug)]
pub struct RootLine {
    pub mv: Mv,
    pub score: i32,
    pub exact: bool,
}

impl Searcher {
    pub fn new(budget: u64) -> Self {
        Searcher {
            budget,
            nodes: 0,
            depth: 0,
            aborted: false,
            iter: 0,
            tt: vec![TtEntry::default(); 1 << TT_BITS],
            killers: [[u32::MAX; 2]; MAX_PLY],
            history: vec![0; 2 * 25 * 24],
            path: Vec::with_capacity(256),
            bufs: (0..MAX_PLY + 1).map(|_| Vec::with_capacity(64)).collect(),
        }
    }

    fn order(&self, pos: &Pos, moves: &[Mv], tt_mv: u32, ply: usize) -> Vec<(Mv, i32)> {
        let s = pos.stm;
        let own = pos.bb[s];
        let opp = pos.bb[1 - s];
        let (opp_pts, _) = two_points(opp, own);
        let empty = pos.empty();
        moves
            .iter()
            .map(|&m| {
                let pk = m.pack();
                let mut sc = self.history[s * 600 + m.hist_idx()];
                if pk == tt_mv {
                    sc = 1 << 30;
                } else {
                    if m.rem != NONE {
                        let r = m.rem as usize;
                        let mut rv = (ADJ[r] & empty).count_ones() as i32;
                        for line in PM[r] {
                            if (opp & line).count_ones() == 2 && own & line == 0 {
                                rv += 8;
                            }
                        }
                        sc += (1 << 24) + rv * 1000;
                    }
                    if opp_pts & (1 << m.to) != 0 {
                        sc += 1 << 22;
                    }
                    if ply < MAX_PLY && (self.killers[ply][0] == pk || self.killers[ply][1] == pk) {
                        sc += 1 << 20;
                    }
                }
                (m, sc)
            })
            .collect()
    }

    fn repeated(&self, quiet: u16) -> bool {
        let n = self.path.len();
        let cur = self.path[n - 1];
        let mut k = 2;
        while k as u16 <= quiet && k < n {
            if self.path[n - 1 - k] == cur {
                return true;
            }
            k += 2;
        }
        false
    }

    fn negamax(&mut self, pos: &Pos, depth: i32, mut alpha: i32, beta: i32, ply: usize) -> i32 {
        self.nodes += 1;
        if self.nodes > self.budget && self.iter > 1 {
            self.aborted = true;
            return 0;
        }
        let s = pos.stm;
        if pos.total(s) < 3 {
            return -(WIN - ply as i32);
        }
        if self.repeated(pos.quiet) || pos.quiet >= DRAW_QUIET {
            return 0;
        }
        if depth <= 0 || ply >= MAX_PLY {
            if !pos.has_move() {
                return -(WIN - ply as i32);
            }
            return eval(pos);
        }
        let idx = (pos.hash as usize) & ((1 << TT_BITS) - 1);
        let e = self.tt[idx];
        let mut tt_mv = u32::MAX;
        if e.flag != 0 && e.key == pos.hash {
            tt_mv = e.mv;
            if e.depth as i32 >= depth {
                let mut sc = e.score;
                if sc > MATE_ZONE {
                    sc -= ply as i32;
                } else if sc < -MATE_ZONE {
                    sc += ply as i32;
                }
                match e.flag {
                    1 => return sc,
                    2 if sc >= beta => return sc,
                    3 if sc <= alpha => return sc,
                    _ => {}
                }
            }
        }
        let mut buf = std::mem::take(&mut self.bufs[ply]);
        pos.gen(&mut buf);
        if buf.is_empty() {
            self.bufs[ply] = buf;
            return -(WIN - ply as i32);
        }
        let mut ordered = self.order(pos, &buf, tt_mv, ply);
        self.bufs[ply] = buf;
        ordered.sort_by_key(|x| std::cmp::Reverse(x.1));
        let alpha0 = alpha;
        let mut best = -INF;
        let mut best_mv = ordered[0].0;
        for &(m, _) in &ordered {
            let child = pos.apply(m);
            self.path.push(child.hash);
            let sc = -self.negamax(&child, depth - 1, -beta, -alpha, ply + 1);
            self.path.pop();
            if self.aborted {
                return 0;
            }
            if sc > best {
                best = sc;
                best_mv = m;
            }
            if sc > alpha {
                alpha = sc;
            }
            if alpha >= beta {
                let pk = m.pack();
                if m.rem == NONE && ply < MAX_PLY && self.killers[ply][0] != pk {
                    self.killers[ply][1] = self.killers[ply][0];
                    self.killers[ply][0] = pk;
                }
                let h = &mut self.history[s * 600 + m.hist_idx()];
                *h = (*h + depth * depth).min(1 << 19);
                break;
            }
        }
        let flag = if best >= beta {
            2
        } else if best > alpha0 {
            1
        } else {
            3
        };
        let mut stored = best;
        if stored > MATE_ZONE {
            stored += ply as i32;
        } else if stored < -MATE_ZONE {
            stored -= ply as i32;
        }
        let slot = &mut self.tt[idx];
        if slot.flag == 0 || slot.key == pos.hash || depth as i8 >= slot.depth {
            *slot = TtEntry { key: pos.hash, mv: best_mv.pack(), score: stored, depth: depth as i8, flag };
        }
        best
    }

    /// Iterative deepening over the given root moves. `hist` = hashes of earlier positions (oldest
    /// first) for repetition detection. Root moves scoring within `margin` of the best get exact
    /// scores (so weaker levels can pick a near-best move). Returns lines sorted best-first, from
    /// the last fully completed depth.
    pub fn think(&mut self, pos: &Pos, hist: &[u64], mut moves: Vec<Mv>, margin: i32) -> Vec<RootLine> {
        self.path.clear();
        let keep = (pos.quiet as usize).min(hist.len());
        self.path.extend_from_slice(&hist[hist.len() - keep..]);
        self.path.push(pos.hash);
        let mut lines: Vec<RootLine> = moves.iter().map(|&mv| RootLine { mv, score: 0, exact: false }).collect();
        if moves.len() <= 1 {
            for l in lines.iter_mut() {
                l.exact = true;
            }
            return lines;
        }
        // Initial order: the static move ordering.
        let ord = self.order(pos, &moves, u32::MAX, 0);
        let mut ord = ord;
        ord.sort_by_key(|x| std::cmp::Reverse(x.1));
        moves = ord.into_iter().map(|x| x.0).collect();
        for depth in 1..MAX_PLY as i32 - 2 {
            self.iter = depth;
            let mut cur: Vec<RootLine> = Vec::with_capacity(moves.len());
            let mut best = -INF;
            for (i, &m) in moves.iter().enumerate() {
                let alpha = if i == 0 { -INF } else { best - margin };
                let child = pos.apply(m);
                self.path.push(child.hash);
                let sc = -self.negamax(&child, depth - 1, -INF, -alpha, 1);
                self.path.pop();
                if self.aborted {
                    break;
                }
                cur.push(RootLine { mv: m, score: sc, exact: i == 0 || sc > alpha });
                if sc > best {
                    best = sc;
                }
            }
            if self.aborted {
                break;
            }
            cur.sort_by(|a, b| b.score.cmp(&a.score).then(b.exact.cmp(&a.exact)));
            moves = cur.iter().map(|l| l.mv).collect();
            lines = cur;
            self.depth = depth;
            // A forced result found within this depth won't change with more depth.
            if best.abs() > MATE_ZONE && WIN - best.abs() <= depth {
                break;
            }
            if self.nodes > self.budget {
                break;
            }
        }
        lines
    }
}

// ---------------------------------------------------------------------------------------------
// Levels

#[derive(Clone, Copy, Debug)]
pub struct Params {
    pub budget: u64,
    pub noise: f64,
    pub blunder: f64,
    pub margin: i32,
    pub ai_first: bool,
    pub rank: &'static str,
    pub rank_index: u32,
}

pub const FULL_BUDGET: u64 = 400_000;

pub fn params(level: u32) -> Params {
    let l = level.clamp(1, 500) as f64;
    let u = (0.5 * l.ln() / 500f64.ln() + 0.5 * (l - 1.0) / 499.0).clamp(0.0, 1.0);
    let budget = (12_000.0 * (FULL_BUDGET as f64 / 12_000.0).powf(u)).round() as u64;
    let (rank, rank_index) = match level {
        0..=40 => ("Acemi", 0),
        41..=100 => ("Çırak", 1),
        101..=180 => ("Kalfa", 2),
        181..=280 => ("Usta", 3),
        281..=390 => ("Üstat", 4),
        _ => ("Büyükusta", 5),
    };
    Params {
        budget,
        noise: 35.0 * (1.0 - u).powf(1.4),
        blunder: 0.10 * (1.0 - u) * (1.0 - u),
        margin: (80.0 * (1.0 - u)).round() as i32,
        ai_first: level.is_multiple_of(2),
        rank,
        rank_index,
    }
}

fn gauss(rng: &mut Rng) -> f64 {
    (rng.f64() + rng.f64() + rng.f64() + rng.f64() - 2.0) * 3f64.sqrt()
}

/// Pick a move from searched root lines the way a player of this strength would.
fn choose(lines: &[RootLine], p: &Params, rng: &mut Rng) -> Mv {
    let best = lines[0].score;
    if lines.len() == 1 || (p.noise <= 0.0 && p.blunder <= 0.0) {
        return lines[0].mv;
    }
    let mut cands: Vec<(f64, usize)> = lines
        .iter()
        .enumerate()
        .filter(|(i, l)| *i == 0 || (l.exact && l.score >= best - p.margin && l.score > -MATE_ZONE))
        .map(|(i, l)| {
            let noisy = if l.score.abs() > MATE_ZONE { l.score as f64 } else { l.score as f64 + gauss(rng) * p.noise };
            (noisy, i)
        })
        .collect();
    cands.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap().then(a.1.cmp(&b.1)));
    let mut pick = 0;
    if cands.len() > 1 && rng.chance(p.blunder) {
        pick = if cands.len() > 2 && rng.chance(0.3) { 2 } else { 1 };
    }
    lines[cands[pick].1].mv
}

/// The engine's move for `pos` (`hist` = earlier position hashes, oldest first).
pub fn engine_move(pos: &Pos, hist: &[u64], p: &Params, rng: &mut Rng) -> (Mv, u64, i32) {
    let mut moves = Vec::new();
    pos.gen(&mut moves);
    let margin = if p.noise > 0.0 || p.blunder > 0.0 { p.margin.max(1) } else { 0 };
    let mut s = Searcher::new(p.budget);
    let lines = s.think(pos, hist, moves, margin);
    (choose(&lines, p, rng), s.nodes, s.depth)
}

// ---------------------------------------------------------------------------------------------
// Session

#[derive(Clone, Copy, PartialEq, Debug)]
enum End {
    YouWin(&'static str),
    AiWin(&'static str),
    Draw(&'static str),
}

#[derive(Clone, Debug)]
struct LastMove {
    ply: u32,
    who: usize,
    kind: &'static str,
    from: Option<u8>,
    to: Option<u8>,
    removed: Option<u8>,
    mills: Vec<usize>,
}

#[derive(Clone)]
struct Game {
    pos: Pos,
    /// Player's mill-closing move waiting for its removal: (position before it, move).
    pending: Option<(Pos, Mv)>,
    /// Hash after every completed ply (index 0 = start position).
    hist: Vec<u64>,
    plies: u32,
    your_moves: u32,
    serial: u32,
    last: Option<LastMove>,
    end: Option<End>,
    rng: Rng,
}

pub struct Morris {
    level: u32,
    p: Params,
    g: Game,
    undo: Vec<Game>,
    used_help: bool,
    hint: Option<Mv>,
    version: u64,
}

pub fn create(level: u32, _mode: &str) -> Result<Box<dyn Session>, String> {
    Ok(Box::new(Morris::new(level)))
}

impl Morris {
    pub fn new(level: u32) -> Self {
        let level = level.clamp(1, 500);
        let p = params(level);
        let pos = Pos::start(if p.ai_first { 1 } else { 0 });
        let g = Game {
            pos,
            pending: None,
            hist: vec![pos.hash],
            plies: 0,
            your_moves: 0,
            serial: 0,
            last: None,
            end: None,
            rng: Rng::new(seed_for("morris", level, 0)),
        };
        Morris { level, p, g, undo: vec![], used_help: false, hint: None, version: 0 }
    }

    fn repeats(&self) -> usize {
        let g = &self.g;
        let n = g.hist.len();
        let window = (g.pos.quiet as usize + 1).min(n);
        g.hist[n - window..].iter().filter(|&&h| h == g.pos.hash).count()
    }

    fn check_end(&self) -> Option<End> {
        let pos = &self.g.pos;
        let s = pos.stm;
        if pos.total(s) < 3 {
            return Some(if s == 1 { End::YouWin("Rakibin 2 taşa indi") } else { End::AiWin("2 taşa indin") });
        }
        if !pos.has_move() {
            return Some(if s == 1 {
                End::YouWin("Rakibin kilitlendi, hamle yapamıyor")
            } else {
                End::AiWin("Kilitlendin, hamle kalmadı")
            });
        }
        if self.repeats() >= 3 {
            return Some(End::Draw("Aynı konum üç kez tekrarlandı"));
        }
        if pos.quiet >= DRAW_QUIET {
            return Some(End::Draw("50 hamledir taş alınmadı"));
        }
        None
    }

    /// Complete a ply: apply `m` to `base`, record history, set last move, detect the end.
    fn finish(&mut self, base: Pos, m: Mv, who: usize, kind: &'static str) {
        let mills = if kind == "remove" { vec![] } else { base.closed_mills(m) };
        let g = &mut self.g;
        g.pos = base.apply(m);
        g.pending = None;
        g.hist.push(g.pos.hash);
        g.plies += 1;
        if who == 0 {
            g.your_moves += 1;
        }
        g.serial += 1;
        g.last = Some(LastMove {
            ply: g.serial,
            who,
            kind,
            from: if kind == "remove" || m.from == NONE { None } else { Some(m.from) },
            to: if kind == "remove" { None } else { Some(m.to) },
            removed: if m.rem == NONE { None } else { Some(m.rem) },
            mills,
        });
        self.hint = None;
        self.g.end = self.check_end();
    }

    fn your_turn(&self) -> Result<(), String> {
        if self.g.end.is_some() {
            return Err("Oyun bitti".into());
        }
        if self.g.pos.stm != 0 {
            return Err("Sıra rakipte".into());
        }
        Ok(())
    }

    /// Player's placement or move (without removal).
    fn player_move(&mut self, from: u8, to: u8) -> Result<(), String> {
        self.your_turn()?;
        if self.g.pending.is_some() {
            return Err("Önce rakibin bir taşını al".into());
        }
        let pos = self.g.pos;
        if to as usize >= 24 || (from != NONE && from as usize >= 24) {
            return Err("Geçersiz nokta".into());
        }
        if from == NONE {
            if pos.hand[0] == 0 {
                return Err("Elinde taş kalmadı — taşlarını kaydır".into());
            }
        } else {
            if pos.hand[0] > 0 {
                return Err("Önce bütün taşlarını yerleştir".into());
            }
            if pos.bb[0] & (1 << from) == 0 {
                return Err("Bu senin taşın değil".into());
            }
        }
        if pos.empty() & (1 << to) == 0 {
            return Err("Bu nokta dolu".into());
        }
        if from != NONE && pos.dests(from as usize) & (1 << to) == 0 {
            return Err("Taş sadece çizgi boyunca komşu noktaya gider".into());
        }
        let m = Mv { from, to, rem: NONE };
        self.undo.push(self.g.clone());
        let mut own = pos.bb[0];
        if from != NONE {
            own &= !(1 << from);
        }
        own |= 1 << to;
        if pos.bb[1] != 0 && forms_mill(own, to as usize) {
            // Show the piece on its new point; the ply completes with the removal.
            let mut shown = pos.apply(m);
            shown.stm = 0;
            shown.quiet = pos.quiet;
            let g = &mut self.g;
            g.pending = Some((pos, m));
            g.pos = shown;
            g.serial += 1;
            g.last = Some(LastMove {
                ply: g.serial,
                who: 0,
                kind: if from == NONE { "place" } else { "move" },
                from: if from == NONE { None } else { Some(from) },
                to: Some(to),
                removed: None,
                mills: pos.closed_mills(m),
            });
            self.hint = None;
        } else {
            self.finish(pos, m, 0, if from == NONE { "place" } else { "move" });
        }
        Ok(())
    }

    fn player_remove(&mut self, r: u8) -> Result<(), String> {
        if self.g.end.is_some() {
            return Err("Oyun bitti".into());
        }
        let Some((base, m)) = self.g.pending else { return Err("Şu an taş alınmaz".into()) };
        if r as usize >= 24 || base.bb[1] & (1 << r) == 0 {
            return Err("Orada rakip taşı yok".into());
        }
        if removable(base.bb[1]) & (1 << r) == 0 {
            return Err("Değirmendeki taş alınamaz — önce açıktaki taşları al".into());
        }
        self.finish(base, Mv { rem: r, ..m }, 0, "remove");
        Ok(())
    }

    fn ai_move(&mut self) -> Result<(), String> {
        if self.g.end.is_some() {
            return Err("Oyun bitti".into());
        }
        if self.g.pos.stm != 1 {
            return Err("Sıra sende".into());
        }
        let pos = self.g.pos;
        let n = self.g.hist.len();
        let hist = self.g.hist[..n - 1].to_vec();
        let (m, _, _) = engine_move(&pos, &hist, &self.p, &mut self.g.rng);
        self.finish(pos, m, 1, if m.from == NONE { "place" } else { "move" });
        Ok(())
    }

    fn compute_hint(&self) -> Option<Mv> {
        let (base, moves) = match self.g.pending {
            Some((base, pm)) => {
                let mut all = Vec::new();
                base.gen(&mut all);
                (base, all.into_iter().filter(|m| m.from == pm.from && m.to == pm.to).collect::<Vec<_>>())
            }
            None => {
                let mut all = Vec::new();
                self.g.pos.gen(&mut all);
                (self.g.pos, all)
            }
        };
        if moves.is_empty() {
            return None;
        }
        // The last history entry is the root itself (the pending base, or the current position).
        let hist = &self.g.hist[..self.g.hist.len() - 1];
        let mut s = Searcher::new(FULL_BUDGET);
        let lines = s.think(&base, hist, moves, 0);
        lines.first().map(|l| l.mv)
    }

    fn stars(&self) -> u32 {
        match self.g.end {
            Some(End::YouWin(_)) => {
                if self.used_help {
                    1
                } else if self.g.pos.total(0) >= 5 {
                    3
                } else {
                    2
                }
            }
            _ => 0,
        }
    }
}

fn pt(p: Option<u8>) -> Value {
    p.map_or(Value::Null, |v| json!(v))
}

impl Session for Morris {
    fn state(&self) -> Value {
        let g = &self.g;
        let pos = &g.pos;
        let (status, reason) = match g.end {
            None => ("playing", None),
            Some(End::YouWin(r)) => ("won", Some(r)),
            Some(End::AiWin(r)) => ("lost", Some(r)),
            Some(End::Draw(r)) => ("draw", Some(r)),
        };
        let playing = g.end.is_none();
        let your_turn = playing && pos.stm == 0;
        let board: Vec<u8> = (0..24)
            .map(|p| if pos.bb[0] & (1 << p) != 0 { 1 } else if pos.bb[1] & (1 << p) != 0 { 2 } else { 0 })
            .collect();
        let pending = g.pending.is_some();
        let removable_pts: Vec<usize> = match g.pending {
            Some((base, _)) => bits(removable(base.bb[1])).collect(),
            None => vec![],
        };
        let can_place = your_turn && !pending && pos.hand[0] > 0;
        let targets: Vec<Vec<usize>> = (0..24)
            .map(|p| {
                if your_turn && !pending && pos.hand[0] == 0 && pos.bb[0] & (1 << p) != 0 {
                    bits(pos.dests(p)).collect()
                } else {
                    vec![]
                }
            })
            .collect();
        let mills: Vec<Value> = (0..2)
            .flat_map(|s| mills_of(pos.bb[s]).map(move |i| json!({"owner": s + 1, "points": MILLS[i]})))
            .collect();
        let last = g.last.as_ref().map(|l| {
            json!({
                "ply": l.ply,
                "who": if l.who == 0 { "you" } else { "ai" },
                "kind": l.kind,
                "from": pt(l.from),
                "to": pt(l.to),
                "removed": pt(l.removed),
                "mills": l.mills.iter().map(|&i| MILLS[i]).collect::<Vec<_>>(),
            })
        });
        let hint = self.hint.map(|m| {
            json!({
                "from": if m.from == NONE { Value::Null } else { json!(m.from) },
                "to": json!(m.to),
                "remove": if m.rem == NONE { Value::Null } else { json!(m.rem) },
            })
        });
        let ai_moves = if playing && pos.stm == 1 {
            let mut v = Vec::new();
            pos.gen(&mut v);
            v.len()
        } else {
            0
        };
        let summary = reason.map(|r| format!("{r} · Kalan taşın: {} · Hamle: {}", pos.total(0), g.your_moves));
        let phase2 = !pos.placing();
        json!({
            "status": status,
            "stars": self.stars(),
            "title": self.p.rank,
            "goal": "Rakibini 2 taşa indir ya da kilitle",
            "summary": summary,
            "end_reason": reason,
            "level": self.level,
            "rank": self.p.rank,
            "rank_index": self.p.rank_index,
            "turn": if pos.stm == 0 { "you" } else { "ai" },
            "ai_pending": playing && pos.stm == 1,
            "you_first": !self.p.ai_first,
            "board": board,
            "phase": if pos.placing() { "place" } else { "move" },
            "hand": pos.hand,
            "on_board": [pos.bb[0].count_ones(), pos.bb[1].count_ones()],
            "captured": [9 - pos.total(1), 9 - pos.total(0)],
            "flying": [pos.flying(0), pos.flying(1)],
            "pending_remove": pending,
            "removable": removable_pts,
            "can_place": can_place,
            "targets": targets,
            "mills": mills,
            "last_move": last,
            "plies": g.plies,
            "your_moves": g.your_moves,
            "quiet": pos.quiet,
            "draw_in": if phase2 { (DRAW_QUIET - pos.quiet.min(DRAW_QUIET)) as i64 } else { -1 },
            "repeats": self.repeats(),
            "can_undo": your_turn && !self.undo.is_empty(),
            "hint": hint,
            "used_help": self.used_help,
            "ai_moves": ai_moves,
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

impl Morris {
    fn act_inner(&mut self, a: &Value) -> Result<(), String> {
        let pnum = |k: &str| a[k].as_u64().map(|v| v.min(255) as u8);
        if a["ai"].as_bool() == Some(true) {
            return self.ai_move();
        }
        if a["undo"].as_bool() == Some(true) {
            if self.g.end.is_some() || self.g.pos.stm != 0 {
                return Err("Şu an geri alınamaz".into());
            }
            let prev = self.undo.pop().ok_or("Geri alınacak hamle yok")?;
            self.g = prev;
            self.used_help = true;
            self.hint = None;
            return Ok(());
        }
        if a["hint"].as_bool() == Some(true) {
            self.your_turn()?;
            self.hint = self.compute_hint();
            self.used_help = true;
            return Ok(());
        }
        if let Some(p) = pnum("remove") {
            return self.player_remove(p);
        }
        if let Some(p) = pnum("place") {
            return self.player_move(NONE, p);
        }
        if let (Some(f), Some(t)) = (pnum("from"), pnum("to")) {
            return self.player_move(f, t);
        }
        Err("Bilinmeyen hamle".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bb(points: &[usize]) -> u32 {
        points.iter().fold(0, |a, &p| a | 1 << p)
    }

    fn pos_with(you: &[usize], ai: &[usize], hand: [u8; 2], stm: usize) -> Pos {
        let mut p = Pos { bb: [bb(you), bb(ai)], hand, stm, quiet: 0, hash: 0 };
        p.rehash();
        p
    }

    /// Session with a custom position on the player's turn.
    fn session_at(pos: Pos) -> Morris {
        let mut m = Morris::new(1);
        m.g.pos = pos;
        m.g.hist = vec![pos.hash];
        m.g.end = m.check_end();
        m
    }

    #[test]
    fn board_geometry() {
        let total: u32 = ADJ.iter().map(|a| a.count_ones()).sum();
        assert_eq!(total, 64); // 32 lines
        for p in 0..24 {
            for q in bits(ADJ[p]) {
                assert!(ADJ[q] & (1 << p) != 0);
            }
            assert!(PM[p][0] != PM[p][1]);
        }
        assert_eq!(ADJ[4].count_ones(), 4);
        assert_eq!(ADJ[0], bb(&[1, 9]));
    }

    #[test]
    fn params_for_levels() {
        let mut prev = 0;
        for level in [1, 2, 3, 50, 137, 250, 400, 499, 500] {
            let p = params(level);
            assert!(p.budget >= prev, "budget grows");
            prev = p.budget;
            assert_eq!(p.ai_first, level % 2 == 0);
            assert!(p.noise >= 0.0 && p.blunder < 0.2);
            let m = Morris::new(level);
            let st = m.state();
            assert_eq!(st["status"], "playing");
            assert_eq!(st["title"], p.rank);
            assert_eq!(st["turn"], if p.ai_first { "ai" } else { "you" });
            assert_eq!(st["ai_pending"], p.ai_first);
        }
        assert_eq!(params(1).rank, "Acemi");
        assert_eq!(params(500).rank, "Büyükusta");
        assert_eq!(params(500).budget, FULL_BUDGET);
        assert_eq!(params(500).blunder, 0.0);
    }

    #[test]
    fn mill_by_placing_requires_removal() {
        let mut m = session_at(pos_with(&[0, 1], &[9, 10], [7, 7], 0));
        m.act(&json!({"place": 2})).unwrap();
        let st = m.state();
        assert_eq!(st["pending_remove"], true);
        assert_eq!(st["turn"], "you");
        assert_eq!(st["last_move"]["mills"][0], json!([0, 1, 2]));
        assert!(m.act(&json!({"place": 5})).is_err());
        assert!(m.act(&json!({"ai": true})).is_err());
        m.act(&json!({"remove": 9})).unwrap();
        let st = m.state();
        assert_eq!(st["board"][9], 0);
        assert_eq!(st["turn"], "ai");
        assert_eq!(st["captured"][0], 1);
    }

    #[test]
    fn removal_rules() {
        // AI has a mill on 3-4-5 plus a loose piece on 21: the mill is protected.
        let mut m = session_at(pos_with(&[0, 1], &[3, 4, 5, 21], [6, 5], 0));
        m.act(&json!({"place": 2})).unwrap();
        let st = m.state();
        assert_eq!(st["removable"], json!([21]));
        let before = m.state();
        assert!(m.act(&json!({"remove": 4})).is_err());
        assert_eq!(m.state(), before);
        assert!(m.act(&json!({"remove": 6})).is_err()); // empty point
        m.act(&json!({"remove": 21})).unwrap();
        // All opponent pieces in mills → any may be taken.
        let mut m = session_at(pos_with(&[0, 1], &[3, 4, 5], [6, 6], 0));
        m.act(&json!({"place": 2})).unwrap();
        assert_eq!(m.state()["removable"], json!([3, 4, 5]));
        m.act(&json!({"remove": 4})).unwrap();
    }

    #[test]
    fn moving_and_reclosing_mill_counts_again() {
        // Phase 2: you have mill 0-1-2 and a loose piece; open by 2→14 and close back.
        let mut m = session_at(pos_with(&[0, 1, 2, 10], &[4, 6, 18, 20, 22], [0, 0], 0));
        assert!(m.act(&json!({"from": 2, "to": 23})).is_err()); // not adjacent
        m.act(&json!({"from": 2, "to": 14})).unwrap();
        assert_eq!(m.state()["pending_remove"], false);
        let pos = m.g.pos;
        m.finish(pos, Mv { from: 6, to: 7, rem: NONE }, 1, "move");
        m.act(&json!({"from": 14, "to": 2})).unwrap();
        assert_eq!(m.state()["pending_remove"], true);
        assert_eq!(m.state()["last_move"]["mills"], json!([[0, 1, 2]]));
    }

    #[test]
    fn flying_with_three() {
        let p = pos_with(&[0, 1, 9], &[4, 6, 7, 18, 20], [0, 0], 0);
        assert!(p.flying(0));
        let mut m = session_at(p);
        assert_eq!(m.state()["flying"], json!([true, false]));
        m.act(&json!({"from": 9, "to": 23})).unwrap(); // far jump is legal
        let p = pos_with(&[0, 1, 9, 10], &[4, 6, 7, 18, 20], [0, 0], 0);
        let mut m = session_at(p);
        assert!(m.act(&json!({"from": 9, "to": 23})).is_err());
    }

    #[test]
    fn blocked_side_loses() {
        // AI on 0, 1, 2, 21: every neighbour (9, 4, 14, 22) is yours → AI to move is blocked.
        let p = pos_with(&[9, 4, 14, 22], &[0, 1, 2, 21], [0, 0], 1);
        assert!(!p.has_move());
        let mut m = session_at(p);
        assert_eq!(m.state()["status"], "won");
        assert_eq!(m.state()["end_reason"], "Rakibin kilitlendi, hamle yapamıyor");
        assert!(m.act(&json!({"ai": true})).is_err());
        let q = pos_with(&[0, 1, 2, 21], &[9, 4, 14, 22], [0, 0], 0);
        assert_eq!(session_at(q).state()["status"], "lost");
        // With three pieces the same side would fly instead.
        let f = pos_with(&[9, 4, 14, 22], &[0, 1, 2], [0, 0], 1);
        assert!(f.has_move());
    }

    #[test]
    fn fewer_than_three_loses() {
        let mut m = session_at(pos_with(&[1, 4, 6, 12], &[9, 21, 23], [0, 0], 0));
        m.act(&json!({"from": 6, "to": 7})).unwrap();
        assert_eq!(m.state()["pending_remove"], true);
        m.act(&json!({"remove": 9})).unwrap();
        let st = m.state();
        assert_eq!(st["status"], "won");
        assert_eq!(st["stars"], 2); // only 4 pieces left
    }

    #[test]
    fn draw_by_repetition_and_quiet_moves() {
        // Both sides shuffle a free piece back and forth.
        let p = pos_with(&[0, 3, 6, 15], &[2, 5, 8, 17], [0, 0], 0);
        let mut m = session_at(p);
        let mut guard = 0;
        while m.state()["status"] == "playing" && guard < 20 {
            if m.g.pos.stm == 0 {
                let st = m.state();
                let mv = if st["board"][9] == 1 { (9, 0) } else { (0, 9) };
                if m.act(&json!({"from": mv.0, "to": mv.1})).is_err() {
                    break;
                }
            } else {
                // Force a mirrored AI shuffle.
                let pos = m.g.pos;
                let mv = if pos.bb[1] & (1 << 14) != 0 { Mv { from: 14, to: 2, rem: NONE } } else { Mv { from: 2, to: 14, rem: NONE } };
                m.finish(pos, mv, 1, "move");
            }
            guard += 1;
        }
        assert_eq!(m.state()["status"], "draw");
        assert_eq!(m.state()["end_reason"], "Aynı konum üç kez tekrarlandı");

        let mut p = pos_with(&[0, 3, 6, 15], &[2, 5, 8, 17], [0, 0], 0);
        p.quiet = 99;
        let mut m = session_at(p);
        m.act(&json!({"from": 0, "to": 9})).unwrap();
        assert_eq!(m.state()["status"], "draw");
        assert_eq!(m.state()["end_reason"], "50 hamledir taş alınmadı");
    }

    #[test]
    fn illegal_actions_leave_state_unchanged() {
        let mut m = Morris::new(1);
        m.act(&json!({"place": 4})).unwrap();
        let before = m.state();
        for a in [
            json!({"place": 10}),          // AI's turn
            json!({"undo": true}),         // AI's turn
            json!({"hint": true}),         // AI's turn
            json!({"from": 4, "to": 3}),
        ] {
            assert!(m.act(&a).is_err(), "{a}");
            assert_eq!(m.state(), before);
        }
        m.act(&json!({"ai": true})).unwrap();
        let before = m.state();
        let taken = (0..24).find(|&p| before["board"][p] == 2).unwrap();
        for a in [
            json!({"ai": true}),
            json!({"place": 4}),
            json!({"place": taken}),
            json!({"place": 30}),
            json!({"from": 4, "to": 1}),
            json!({"remove": taken}),
            json!({"foo": 1}),
        ] {
            assert!(m.act(&a).is_err(), "{a}");
            assert_eq!(m.state(), before);
        }
    }

    #[test]
    fn undo_restores_previous_turn_and_caps_stars() {
        let mut m = Morris::new(1);
        m.act(&json!({"place": 4})).unwrap();
        m.act(&json!({"ai": true})).unwrap();
        let after_first = m.state();
        m.act(&json!({"place": 10})).unwrap();
        m.act(&json!({"ai": true})).unwrap();
        assert_eq!(m.state()["can_undo"], true);
        m.act(&json!({"undo": true})).unwrap();
        let st = m.state();
        assert_eq!(st["board"], after_first["board"]);
        assert_eq!(st["used_help"], true);
        // Replaying the same move gives the same AI reply (determinism incl. RNG).
        m.act(&json!({"place": 10})).unwrap();
        m.act(&json!({"ai": true})).unwrap();
        let a = m.state()["board"].clone();
        m.act(&json!({"undo": true})).unwrap();
        m.act(&json!({"place": 10})).unwrap();
        m.act(&json!({"ai": true})).unwrap();
        assert_eq!(m.state()["board"], a);
    }

    #[test]
    fn hint_gives_legal_move() {
        let mut m = Morris::new(3);
        m.act(&json!({"hint": true})).unwrap();
        let h = m.state()["hint"].clone();
        assert!(h["to"].is_u64());
        m.act(&json!({"place": h["to"]})).unwrap();
        // Hint during a pending removal names a removable piece.
        let mut m = session_at(pos_with(&[0, 1], &[9, 10, 3, 4], [7, 5], 0));
        m.act(&json!({"place": 2})).unwrap();
        m.act(&json!({"hint": true})).unwrap();
        let r = m.state()["hint"]["remove"].as_u64().unwrap();
        m.act(&json!({"remove": r})).unwrap();
    }

    /// Engine vs engine from the start; returns +1 if side 0 wins, -1 if side 1 wins, 0 draw.
    fn engine_game(p0: &Params, p1: &Params, seed: u64, first: usize) -> (i32, u32) {
        let mut pos = Pos::start(first);
        let mut hist = vec![pos.hash];
        let mut rngs = [Rng::new(seed), Rng::new(seed ^ 0xABCDEF)];
        let mut plies = 0;
        loop {
            let s = pos.stm;
            if pos.total(s) < 3 || !pos.has_move() {
                return (if s == 0 { -1 } else { 1 }, plies);
            }
            let n = hist.len();
            let window = (pos.quiet as usize + 1).min(n);
            if hist[n - window..].iter().filter(|&&h| h == pos.hash).count() >= 3 || pos.quiet >= DRAW_QUIET {
                return (0, plies);
            }
            let p = if s == 0 { p0 } else { p1 };
            let (m, _, _) = engine_move(&pos, &hist[..n - 1], p, &mut rngs[s]);
            pos = pos.apply(m);
            hist.push(pos.hash);
            plies += 1;
            assert!(plies < 3000, "game must terminate");
        }
    }

    #[test]
    fn ai_vs_ai_terminates() {
        let a = params(1);
        let b = params(60);
        for seed in 0..2 {
            let (_, plies) = engine_game(&a, &b, seed, seed as usize % 2);
            assert!(plies >= 18);
        }
    }

    #[test]
    fn strong_beats_weak() {
        let strong = params(500);
        let weak = params(1);
        let (mut w, mut d, mut l) = (0, 0, 0);
        for seed in 0..10u64 {
            let (r, _) = engine_game(&strong, &weak, 1000 + seed, (seed % 2) as usize);
            match r {
                1 => w += 1,
                0 => d += 1,
                _ => l += 1,
            }
        }
        eprintln!("strong vs weak: {w} wins, {d} draws, {l} losses");
        assert!(w >= 6 && l <= 1, "strong {w}/{d}/{l}");
    }

    #[test]
    fn deterministic_replies() {
        let play = || {
            let mut m = Morris::new(2);
            let mut boards = vec![];
            for _ in 0..6 {
                m.act(&json!({"ai": true})).unwrap();
                boards.push(m.state()["board"].clone());
                let st = m.state();
                let p = (0..24).find(|&p| st["board"][p] == 0).unwrap();
                m.act(&json!({"place": p})).unwrap();
                if m.state()["pending_remove"] == true {
                    let r = m.state()["removable"][0].as_u64().unwrap();
                    m.act(&json!({"remove": r})).unwrap();
                }
            }
            boards
        };
        assert_eq!(play(), play());
    }

    #[test]
    #[ignore]
    fn strength_curve() {
        for (hi, lo) in [(50, 1), (250, 50), (500, 250)] {
            let (mut w, mut d, mut l) = (0, 0, 0);
            for seed in 0..8u64 {
                match engine_game(&params(hi), &params(lo), 77 + seed, (seed % 2) as usize).0 {
                    1 => w += 1,
                    0 => d += 1,
                    _ => l += 1,
                }
            }
            eprintln!("L{hi} vs L{lo}: {w} wins, {d} draws, {l} losses");
        }
    }

    #[test]
    #[ignore]
    fn timing_per_move() {
        for level in [1, 250, 500] {
            let p = params(level);
            let mut pos = Pos::start(0);
            let mut hist = vec![pos.hash];
            let mut rng = Rng::new(7);
            let (mut total, mut worst, mut n, mut nodes, mut depths) = (0.0f64, 0.0f64, 0, 0u64, 0i32);
            for _ in 0..200 {
                if pos.total(pos.stm) < 3 || !pos.has_move() || pos.quiet >= DRAW_QUIET {
                    break;
                }
                let t = std::time::Instant::now();
                let (m, nd, d) = engine_move(&pos, &hist[..hist.len() - 1], &p, &mut rng);
                depths += d;
                let ms = t.elapsed().as_secs_f64() * 1000.0;
                total += ms;
                worst = worst.max(ms);
                nodes += nd;
                n += 1;
                pos = pos.apply(m);
                hist.push(pos.hash);
            }
            eprintln!(
                "level {level}: budget {} · {n} moves · avg depth {:.1} · avg {:.1} ms · worst {:.1} ms · {:.0} knodes/s",
                p.budget,
                depths as f64 / n as f64,
                total / n as f64,
                worst,
                nodes as f64 / total
            );
        }
    }
}
