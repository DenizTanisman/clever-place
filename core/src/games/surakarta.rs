//! Surakarta — the Javanese loop-capture game, against an AI opponent.
//!
//! Board: 6×6 intersections, point `(r, c)` = index `r*6 + c`. The player ("you") starts on rows
//! 4–5 (bottom), the AI on rows 0–1 (top), 12 pieces each.
//!
//! Circuits: the **inner** circuit (id 0) joins lines 1 and 4, the **outer** circuit (id 1) lines 2
//! and 3 (rows and columns). Each is a closed path of 24 occurrences, walked in this order:
//! row k eastwards → arc around the top-right corner → column 5−k southwards → arc bottom-right →
//! row 5−k westwards → arc bottom-left → column k northwards → arc top-left → back to the start
//! (k = 1 inner, 2 outer). An arc is a 270° loop of radius k around the corner point; it sits between
//! occurrence `6s+5` and `6s+6` (mod 24) and goes around corner `(s+1) % 4`
//! (corners: 0 = top-left, 1 = top-right, 2 = bottom-right, 3 = bottom-left).
//!
//! Moves: a step to any of the 8 neighbouring empty points, or a capture: travel along a circuit
//! (either direction, from any occurrence of the start point) through every empty point — the
//! mover's own start point counts as empty — passing **at least one loop arc**, and land on the first
//! piece met if it is an enemy. Captures are optional.
//!
//! End: all enemy pieces captured, or the side to move has no legal move (it loses). The game also
//! **stops** after 40 consecutive plies without a capture, or on threefold repetition of the same
//! position (same side to move): the side with more pieces wins, equal = draw. So stalling only helps
//! the side that is ahead — the player has to keep a lead, not just survive.
//!
//! AI: negamax + alpha-beta, iterative deepening, quiescence on captures, transposition table,
//! killer/history ordering, all bounded by a deterministic **node budget**. Weaker opponents get a
//! smaller budget, Gaussian-ish noise on root scores and an occasional "human" slip (2nd/3rd best
//! move within a margin); they never play an obviously random move.
//!
//! Level curve (`params`), t = (level−1)/499:
//! - budget   = 3 000 · (MAX_BUDGET/3 000)^(t^0.75) nodes (L1 = 3k, L250 ≈ 38k, L500 = 220k)
//! - noise σ  = 28 · (1−t)^1.6 (in 1/100 piece; L1 ≈ a quarter piece, gone by ≈ L470)
//! - slip     = 12 % · (1 − t/0.7) (none from ≈ L350), only among moves within `margin` of the best
//! - margin   = 25 + 50 · (1−t)² (a free piece is never "slipped" away)
//! - odd levels: you start; even levels: the AI starts.
//!
//! Ranks: 1–40 Acemi · 41–100 Çırak · 101–180 Kalfa · 181–280 Usta · 281–400 Üstat · 401–500 Büyükusta.
//!
//! State: `{status, stars, title, goal, turn: "you"|"ai", ai_pending, board: [[0|1|2]] (1 = you,
//!   2 = AI), counts: {you, ai}, captured: {you, ai} (pieces each side has taken), quiet, quiet_limit,
//!   last_move: {who, from, to, capture, path, ply} | null, moves: [{from, to, capture, path}] (only on
//!   your turn), threats: [[r,c]] (your pieces the AI could capture if it were its move; only on
//!   your turn), hint: {from, to, capture, path} | null, can_undo, complexity (0..1, for the AI
//!   pause), end_reason, summary, player_moves, level}`.
//! A path is `[{"pt":[r,c]}, {"arc":{"corner":k,"circuit":"inner"|"outer"}}, {"pt":[r,c]}, …]`, from the
//! start point to the captured point, with an `arc` entry wherever a loop is taken.
//! Actions: `{"from":[r,c],"to":[r,c]}` · `{"ai":true}` · `{"undo":true}` · `{"hint":true}`.

use crate::rng::{seed_for, Rng};
use crate::Session;
use serde_json::{json, Value};
use std::sync::OnceLock;

const YOU: usize = 0;
const AI: usize = 1;
pub const QUIET_LIMIT: u32 = 40;
const MAX_BUDGET: u64 = 220_000;

const WIN: i32 = 30_000;
const STOP_WIN: i32 = 20_000;
const DECISIVE: i32 = 15_000;
const INF: i32 = 32_000;
const MAX_PLY: usize = 64;

// ---------------------------------------------------------------------------------------------
// Static tables

struct Tables {
    circ: [[u8; 24]; 2],
    /// Occurrences of each point on the circuits: (circuit, index), `occ_n` of them.
    occ: [[(u8, u8); 2]; 36],
    occ_n: [u8; 36],
    nb: [u64; 36],
    zob: [[u64; 36]; 2],
    zside: u64,
    zquiet: [u64; QUIET_LIMIT as usize + 1],
    /// Points where a loop arc starts or ends ("loop entries").
    entries: u64,
}

fn tables() -> &'static Tables {
    static T: OnceLock<Tables> = OnceLock::new();
    T.get_or_init(|| {
        let mut circ = [[0u8; 24]; 2];
        for (ci, k) in [1usize, 2].into_iter().enumerate() {
            let mut v = Vec::with_capacity(24);
            v.extend((0..6).map(|c| k * 6 + c));
            v.extend((0..6).map(|r| r * 6 + (5 - k)));
            v.extend((0..6).rev().map(|c| (5 - k) * 6 + c));
            v.extend((0..6).rev().map(|r| r * 6 + k));
            for (j, &sq) in v.iter().enumerate() {
                circ[ci][j] = sq as u8;
            }
        }
        let mut occ = [[(0u8, 0u8); 2]; 36];
        let mut occ_n = [0u8; 36];
        let mut entries = 0u64;
        for (ci, cv) in circ.iter().enumerate() {
            for (j, &sq) in cv.iter().enumerate() {
                let s = sq as usize;
                occ[s][occ_n[s] as usize] = (ci as u8, j as u8);
                occ_n[s] += 1;
                if j % 6 == 0 || j % 6 == 5 {
                    entries |= 1 << s;
                }
            }
        }
        let mut nb = [0u64; 36];
        for (sq, m) in nb.iter_mut().enumerate() {
            let (r, c) = ((sq / 6) as i32, (sq % 6) as i32);
            for dr in -1..=1 {
                for dc in -1..=1 {
                    let (rr, cc) = (r + dr, c + dc);
                    if (dr, dc) != (0, 0) && (0..6).contains(&rr) && (0..6).contains(&cc) {
                        *m |= 1 << (rr * 6 + cc);
                    }
                }
            }
        }
        let mut rng = Rng::new(0x05A4_A17A_5A4A_17A5);
        let mut zob = [[0u64; 36]; 2];
        for side in zob.iter_mut() {
            for z in side.iter_mut() {
                *z = rng.next_u64();
            }
        }
        let zside = rng.next_u64();
        let mut zquiet = [0u64; QUIET_LIMIT as usize + 1];
        for z in zquiet.iter_mut() {
            *z = rng.next_u64();
        }
        Tables { circ, occ, occ_n, nb, zob, zside, zquiet, entries }
    })
}

#[inline]
fn bit(sq: usize) -> u64 {
    1u64 << sq
}

fn bits(mut m: u64) -> impl Iterator<Item = usize> {
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

/// Walk circuit `c` from occurrence `j` in direction `dir` (±1). Returns the first occupied point
/// (other than `from`, which counts as empty) and whether a loop arc was passed before reaching it.
/// Empty points reached after a loop are added to `ctrl`.
#[inline]
fn walk(t: &Tables, occ: u64, from: usize, c: usize, j: usize, fwd: bool, ctrl: &mut u64) -> Option<(usize, bool)> {
    let cv = &t.circ[c];
    let mut j = j;
    let mut looped = false;
    for _ in 0..24 {
        if fwd {
            if j % 6 == 5 {
                looped = true;
            }
            j = if j == 23 { 0 } else { j + 1 };
        } else {
            if j % 6 == 0 {
                looped = true;
            }
            j = if j == 0 { 23 } else { j - 1 };
        }
        let q = cv[j] as usize;
        if q == from {
            continue;
        }
        if occ & bit(q) == 0 {
            if looped {
                *ctrl |= bit(q);
            }
            continue;
        }
        return Some((q, looped));
    }
    None
}

// ---------------------------------------------------------------------------------------------
// Position and moves

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
struct Mv {
    from: u8,
    to: u8,
    cap: bool,
}

const NO_MOVE: Mv = Mv { from: 255, to: 255, cap: false };

struct MoveList {
    m: [Mv; 160],
    n: usize,
}

impl MoveList {
    fn new() -> Self {
        MoveList { m: [Mv::default(); 160], n: 0 }
    }
    fn push(&mut self, m: Mv) {
        if self.n < self.m.len() {
            self.m[self.n] = m;
            self.n += 1;
        }
    }
    fn as_slice(&self) -> &[Mv] {
        &self.m[..self.n]
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
struct Pos {
    bb: [u64; 2],
    stm: usize,
    quiet: u32,
    hash: u64,
}

impl Pos {
    fn start(stm: usize) -> Pos {
        let t = tables();
        let mut bb = [0u64; 2];
        for sq in 0..12 {
            bb[AI] |= bit(sq);
            bb[YOU] |= bit(sq + 24);
        }
        Pos::from_bb(bb, stm, 0, t)
    }

    fn from_bb(bb: [u64; 2], stm: usize, quiet: u32, t: &Tables) -> Pos {
        let mut hash = if stm == AI { t.zside } else { 0 };
        for (s, &b) in bb.iter().enumerate() {
            for sq in bits(b) {
                hash ^= t.zob[s][sq];
            }
        }
        Pos { bb, stm, quiet, hash }
    }

    fn count(&self, side: usize) -> i32 {
        self.bb[side].count_ones() as i32
    }

    fn gen(&self, caps_only: bool, out: &mut MoveList) {
        let t = tables();
        let s = self.stm;
        let me = self.bb[s];
        let opp = self.bb[1 - s];
        let occ = me | opp;
        let mut dummy = 0u64;
        for from in bits(me) {
            let start = out.n;
            for k in 0..t.occ_n[from] as usize {
                let (c, j) = t.occ[from][k];
                for fwd in [true, false] {
                    if let Some((q, looped)) = walk(t, occ, from, c as usize, j as usize, fwd, &mut dummy) {
                        if looped && opp & bit(q) != 0 && !out.m[start..out.n].iter().any(|m| m.to as usize == q) {
                            out.push(Mv { from: from as u8, to: q as u8, cap: true });
                        }
                    }
                }
            }
            if !caps_only {
                for q in bits(t.nb[from] & !occ) {
                    out.push(Mv { from: from as u8, to: q as u8, cap: false });
                }
            }
        }
    }

    fn make(&self, m: Mv) -> Pos {
        let t = tables();
        let mut p = *self;
        let s = p.stm;
        let o = 1 - s;
        let (f, to) = (m.from as usize, m.to as usize);
        p.bb[s] ^= bit(f) | bit(to);
        p.hash ^= t.zob[s][f] ^ t.zob[s][to];
        if m.cap {
            p.bb[o] ^= bit(to);
            p.hash ^= t.zob[o][to];
            p.quiet = 0;
        } else {
            p.quiet += 1;
        }
        p.stm = o;
        p.hash ^= t.zside;
        p
    }

    /// Hash including the no-capture counter once it gets close to the limit (it changes the result).
    fn tt_key(&self) -> u64 {
        if self.quiet >= QUIET_LIMIT - 12 {
            self.hash ^ tables().zquiet[self.quiet.min(QUIET_LIMIT) as usize]
        } else {
            self.hash
        }
    }

    /// Score for the side to move when the game stops on the quiet/repetition rule.
    fn stop_score(&self, ply: usize) -> i32 {
        let d = self.count(self.stm) - self.count(1 - self.stm);
        match d.signum() {
            1 => STOP_WIN + 10 * d - ply as i32,
            -1 => -STOP_WIN + 10 * d + ply as i32,
            _ => 0,
        }
    }

    /// Static evaluation from the side to move's point of view (100 = one piece).
    fn eval(&self) -> i32 {
        let t = tables();
        let occ = self.bb[0] | self.bb[1];
        let mut att = [0u64; 2];
        let mut def = [0u64; 2];
        let mut ctrl = [0u64; 2];
        let mut mob = [0i32; 2];
        for s in 0..2 {
            let mine = self.bb[s];
            for from in bits(mine) {
                mob[s] += (t.nb[from] & !occ).count_ones() as i32;
                for k in 0..t.occ_n[from] as usize {
                    let (c, j) = t.occ[from][k];
                    for fwd in [true, false] {
                        if let Some((q, looped)) = walk(t, occ, from, c as usize, j as usize, fwd, &mut ctrl[s]) {
                            if looped {
                                if mine & bit(q) != 0 {
                                    def[s] |= bit(q);
                                } else {
                                    att[s] |= bit(q);
                                    mob[s] += 2;
                                }
                            }
                        }
                    }
                }
            }
        }
        let s = self.stm;
        let o = 1 - s;
        let mut sc = 100 * (self.count(s) - self.count(o));
        sc += 3 * (ctrl[s].count_ones() as i32 - ctrl[o].count_ones() as i32);
        sc += mob[s] - mob[o];
        sc += 3 * ((def[s] & self.bb[s]).count_ones() as i32 - (def[o] & self.bb[o]).count_ones() as i32);
        // Pressure on enemy pieces (the side to move's captures are resolved by quiescence).
        sc += 6 * (att[s].count_ones() as i32) - 6 * (att[o].count_ones() as i32);
        // My pieces under fire: I can rescue one per move; a second loose piece is usually lost.
        let loose = (att[o] & !def[s]).count_ones() as i32;
        let traded = (att[o] & def[s]).count_ones() as i32;
        sc -= 12 * loose.min(1) + 55 * (loose - 1).max(0) + 4 * traded;
        // The opponent's loose pieces after its move matter less (it is my move: qsearch sees them).
        sc += 4 * (att[s] & !def[o]).count_ones() as i32;
        // Exposed loop entries: pieces sitting on an arc end that the enemy already sees.
        sc -= 6 * (att[o] & t.entries).count_ones() as i32;
        sc
    }
}

// ---------------------------------------------------------------------------------------------
// Capture paths (for the UI)

#[derive(Clone, Debug, PartialEq)]
enum Seg {
    Pt(usize),
    Arc { corner: usize, circuit: usize },
}

fn seg_json(path: &[Seg]) -> Value {
    Value::Array(
        path.iter()
            .map(|s| match *s {
                Seg::Pt(q) => json!({"pt": [q / 6, q % 6]}),
                Seg::Arc { corner, circuit } => {
                    json!({"arc": {"corner": corner, "circuit": if circuit == 0 { "inner" } else { "outer" }}})
                }
            })
            .collect(),
    )
}

/// Every capture path of the piece on `from` (side `side`): (target, path). Several paths may reach
/// the same target; callers pick the shortest.
fn capture_paths(p: &Pos, side: usize, from: usize) -> Vec<(usize, Vec<Seg>)> {
    let t = tables();
    let occ = p.bb[0] | p.bb[1];
    let opp = p.bb[1 - side];
    let mut out = vec![];
    for k in 0..t.occ_n[from] as usize {
        let (c, j0) = t.occ[from][k];
        let (c, j0) = (c as usize, j0 as usize);
        for fwd in [true, false] {
            let mut path = vec![Seg::Pt(from)];
            let mut j = j0;
            let mut looped = false;
            for _ in 0..24 {
                let arc = if fwd { j % 6 == 5 } else { j % 6 == 0 };
                if arc {
                    looped = true;
                    let s = j / 6;
                    let corner = if fwd { (s + 1) % 4 } else { s % 4 };
                    path.push(Seg::Arc { corner, circuit: c });
                }
                j = if fwd { (j + 1) % 24 } else { (j + 23) % 24 };
                let q = t.circ[c][j] as usize;
                path.push(Seg::Pt(q));
                if q == from || occ & bit(q) == 0 {
                    continue;
                }
                if looped && opp & bit(q) != 0 {
                    out.push((q, path.clone()));
                }
                break;
            }
        }
    }
    out
}

fn shortest_path(p: &Pos, side: usize, from: usize, to: usize) -> Option<Vec<Seg>> {
    capture_paths(p, side, from).into_iter().filter(|(q, _)| *q == to).map(|(_, v)| v).min_by_key(|v| v.len())
}

fn move_json(p: &Pos, m: Mv) -> Value {
    let (f, t) = (m.from as usize, m.to as usize);
    let path = if m.cap { shortest_path(p, p.stm, f, t).map(|v| seg_json(&v)).unwrap_or(Value::Null) } else { Value::Null };
    json!({"from": [f / 6, f % 6], "to": [t / 6, t % 6], "capture": m.cap, "path": path})
}

// ---------------------------------------------------------------------------------------------
// Search

#[derive(Clone, Copy)]
pub struct Params {
    pub budget: u64,
    pub noise: f64,
    pub slip: f64,
    pub margin: i32,
}

pub fn params(level: u32) -> Params {
    let t = (level.clamp(1, 500) - 1) as f64 / 499.0;
    let budget = (3_000.0 * (MAX_BUDGET as f64 / 3_000.0).powf(t.powf(0.75))).round() as u64;
    Params {
        budget,
        noise: 28.0 * (1.0 - t).powf(1.6),
        slip: (0.12 * (1.0 - t / 0.7)).max(0.0),
        margin: (25.0 + 50.0 * (1.0 - t) * (1.0 - t)).round() as i32,
    }
}

fn full_strength() -> Params {
    Params { budget: MAX_BUDGET, noise: 0.0, slip: 0.0, margin: 0 }
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

#[derive(Clone, Copy, Default)]
struct TtEntry {
    key: u64,
    score: i32,
    depth: i8,
    flag: u8, // 0 empty, 1 exact, 2 lower, 3 upper
    best: Mv,
}

const TT_SIZE: usize = 1 << 16;

struct Search {
    nodes: u64,
    budget: u64,
    abort: bool,
    tt: Vec<TtEntry>,
    killers: [[Mv; 2]; MAX_PLY],
    history: Vec<i32>,
    /// Hashes of earlier positions (game history since the last capture, then the search path).
    stack: Vec<u64>,
}

impl Search {
    fn new(budget: u64, game_hashes: &[u64]) -> Search {
        Search {
            nodes: 0,
            budget,
            abort: false,
            tt: vec![TtEntry::default(); TT_SIZE],
            killers: [[NO_MOVE; 2]; MAX_PLY],
            history: vec![0; 2 * 36 * 36],
            stack: game_hashes.to_vec(),
        }
    }

    /// Threefold: the current position already occurred twice (same side to move).
    fn repeated(&self, p: &Pos) -> bool {
        let n = self.stack.len();
        let back = (p.quiet as usize).min(n);
        let mut seen = 0;
        let mut i = 2;
        while i <= back {
            if self.stack[n - i] == p.hash {
                seen += 1;
                if seen >= 2 {
                    return true;
                }
            }
            i += 2;
        }
        false
    }

    fn order(&self, p: &Pos, list: &mut MoveList, tt_move: Mv, ply: usize) {
        let mut keys = [0i32; 160];
        for i in 0..list.n {
            let m = list.m[i];
            keys[i] = if m == tt_move {
                1 << 30
            } else if m.cap {
                1 << 28
            } else if ply < MAX_PLY && (m == self.killers[ply][0] || m == self.killers[ply][1]) {
                1 << 26
            } else {
                self.history[(p.stm * 36 + m.from as usize) * 36 + m.to as usize]
            };
        }
        // Insertion sort, descending (lists are short).
        for i in 1..list.n {
            let (m, k) = (list.m[i], keys[i]);
            let mut j = i;
            while j > 0 && keys[j - 1] < k {
                list.m[j] = list.m[j - 1];
                keys[j] = keys[j - 1];
                j -= 1;
            }
            list.m[j] = m;
            keys[j] = k;
        }
    }

    fn qsearch(&mut self, p: &Pos, mut alpha: i32, beta: i32, ply: usize, qd: u32) -> i32 {
        self.nodes += 1;
        if p.count(p.stm) == 0 {
            return -WIN + ply as i32;
        }
        if p.count(1 - p.stm) == 0 {
            return WIN - ply as i32;
        }
        let stand = p.eval();
        if stand >= beta || qd >= 10 || ply >= MAX_PLY - 1 {
            return stand;
        }
        if stand > alpha {
            alpha = stand;
        }
        let mut list = MoveList::new();
        p.gen(true, &mut list);
        for &m in list.as_slice() {
            let c = p.make(m);
            let sc = -self.qsearch(&c, -beta, -alpha, ply + 1, qd + 1);
            if sc >= beta {
                return sc;
            }
            if sc > alpha {
                alpha = sc;
            }
        }
        alpha
    }

    fn negamax(&mut self, p: &Pos, depth: i32, mut alpha: i32, beta: i32, ply: usize) -> i32 {
        self.nodes += 1;
        if self.nodes > self.budget {
            self.abort = true;
            return 0;
        }
        if p.count(p.stm) == 0 {
            return -WIN + ply as i32;
        }
        if p.quiet >= QUIET_LIMIT || self.repeated(p) {
            return p.stop_score(ply);
        }
        if depth <= 0 || ply >= MAX_PLY - 2 {
            return self.qsearch(p, alpha, beta, ply, 0);
        }
        let key = p.tt_key();
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
        let mut list = MoveList::new();
        p.gen(false, &mut list);
        if list.n == 0 {
            return -WIN + ply as i32;
        }
        self.order(p, &mut list, tt_move, ply);
        let a0 = alpha;
        let mut best = -INF;
        let mut best_m = list.m[0];
        self.stack.push(p.hash);
        for &m in list.as_slice() {
            let c = p.make(m);
            let sc = -self.negamax(&c, depth - 1, -beta, -alpha, ply + 1);
            if self.abort {
                self.stack.pop();
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
                if !m.cap {
                    if ply < MAX_PLY && self.killers[ply][0] != m {
                        self.killers[ply][1] = self.killers[ply][0];
                        self.killers[ply][0] = m;
                    }
                    let h = &mut self.history[(p.stm * 36 + m.from as usize) * 36 + m.to as usize];
                    *h = (*h + depth * depth).min(1 << 24);
                }
                break;
            }
        }
        self.stack.pop();
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

/// Choose a move for the side to move. `game_hashes` = hashes of earlier positions since the last
/// capture (for repetition). Returns None only when there is no legal move.
fn choose(p: &Pos, game_hashes: &[u64], prm: Params, rng: &mut Rng) -> Option<(Mv, u64)> {
    let mut list = MoveList::new();
    p.gen(false, &mut list);
    if list.n == 0 {
        return None;
    }
    if list.n == 1 {
        return Some((list.m[0], 1));
    }
    let mut s = Search::new(prm.budget, game_hashes);
    let human = prm.noise > 0.0 || prm.slip > 0.0;
    let mut moves: Vec<Mv> = list.as_slice().to_vec();
    // Captures first for the first iteration.
    moves.sort_by_key(|m| !m.cap);
    let mut done_scores: Vec<(Mv, i32)> = vec![];
    for depth in 1..40 {
        let mut alpha = -INF;
        let mut best = -INF;
        let mut cur = vec![-INF; moves.len()];
        s.stack.push(p.hash);
        for (i, &m) in moves.iter().enumerate() {
            let c = p.make(m);
            // Human mode: keep every move within the margin exact, so noise can choose among them.
            let a = if human && best > -INF { (best - prm.margin - 1).max(-INF) } else { alpha };
            let sc = -s.negamax(&c, depth - 1, -INF, -a, 1);
            if s.abort {
                break;
            }
            cur[i] = sc;
            if sc > best {
                best = sc;
            }
            if sc > alpha {
                alpha = sc;
            }
        }
        s.stack.pop();
        if s.abort && depth > 1 {
            break;
        }
        s.abort = false;
        // Re-order for the next iteration: best first (stable sort keeps earlier order on ties).
        let mut idx: Vec<usize> = (0..moves.len()).collect();
        idx.sort_by(|&a, &b| cur[b].cmp(&cur[a]));
        done_scores = idx.iter().map(|&i| (moves[i], cur[i])).collect();
        moves = done_scores.iter().map(|&(m, _)| m).collect();
        if best.abs() > DECISIVE || s.nodes > prm.budget {
            break;
        }
    }
    let best = done_scores[0].1;
    if !human || best.abs() > DECISIVE {
        return Some((done_scores[0].0, s.nodes));
    }
    // Human choice among the moves within the margin of the best.
    let mut cands: Vec<(Mv, f64)> = done_scores
        .iter()
        .filter(|(_, sc)| *sc >= best - prm.margin && sc.abs() <= DECISIVE)
        .map(|&(m, sc)| {
            let g = (rng.f64() + rng.f64() + rng.f64() - 1.5) * 2.0; // ≈ N(0, 1)
            (m, sc as f64 + g * prm.noise)
        })
        .collect();
    if cands.is_empty() {
        return Some((done_scores[0].0, s.nodes));
    }
    cands.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    let mut pick = 0;
    if cands.len() > 1 && rng.chance(prm.slip) {
        pick = 1 + rng.below(2.min(cands.len() - 1));
    }
    Some((cands[pick].0, s.nodes))
}

// ---------------------------------------------------------------------------------------------
// Session

#[derive(Clone)]
struct LastMove {
    who: usize,
    m: Mv,
    path: Value,
    ply: u64,
}

#[derive(Clone)]
struct Snapshot {
    pos: Pos,
    hashes: Vec<u64>,
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

pub struct Surakarta {
    level: u32,
    prm: Params,
    seed: u64,
    pos: Pos,
    /// Hashes of every earlier position since the last capture (repetition window).
    hashes: Vec<u64>,
    history: Vec<Snapshot>,
    last: Option<LastMove>,
    serial: u64,
    plies: u32,
    player_moves: u32,
    status: Status,
    reason: &'static str,
    helped: bool,
    hint: Option<Value>,
}

impl Surakarta {
    pub fn new(level: u32) -> Self {
        let level = level.clamp(1, 500);
        let stm = if level % 2 == 1 { YOU } else { AI };
        Surakarta {
            level,
            prm: params(level),
            seed: seed_for("surakarta", level, 0),
            pos: Pos::start(stm),
            hashes: vec![],
            history: vec![],
            last: None,
            serial: 0,
            plies: 0,
            player_moves: 0,
            status: Status::Playing,
            reason: "",
            helped: false,
            hint: None,
        }
    }

    fn legal(&self) -> Vec<Mv> {
        let mut l = MoveList::new();
        self.pos.gen(false, &mut l);
        l.as_slice().to_vec()
    }

    fn apply(&mut self, m: Mv) {
        let who = self.pos.stm;
        let path = if m.cap {
            shortest_path(&self.pos, who, m.from as usize, m.to as usize).map(|v| seg_json(&v)).unwrap_or(Value::Null)
        } else {
            Value::Null
        };
        if m.cap {
            self.hashes.clear();
        } else {
            self.hashes.push(self.pos.hash);
        }
        self.pos = self.pos.make(m);
        self.serial += 1;
        self.plies += 1;
        if who == YOU {
            self.player_moves += 1;
        }
        self.last = Some(LastMove { who, m, path, ply: self.serial });
        self.hint = None;
        self.check_end();
    }

    fn check_end(&mut self) {
        let p = &self.pos;
        let side_status = |winner: usize| if winner == YOU { Status::Won } else { Status::Lost };
        if p.count(p.stm) == 0 {
            self.status = side_status(1 - p.stm);
            self.reason = "all_captured";
            return;
        }
        if self.legal().is_empty() {
            self.status = side_status(1 - p.stm);
            self.reason = "no_moves";
            return;
        }
        let rep = self.hashes.iter().filter(|&&h| h == p.hash).count() >= 2;
        if p.quiet >= QUIET_LIMIT || rep {
            let (y, a) = (p.count(YOU), p.count(AI));
            self.status = if y > a { Status::Won } else if a > y { Status::Lost } else { Status::Draw };
            self.reason = if rep { "repetition" } else { "quiet" };
        }
    }

    fn stars(&self) -> u32 {
        if self.status != Status::Won {
            0
        } else if self.helped {
            1
        } else if self.pos.count(YOU) >= 6 {
            3
        } else {
            2
        }
    }

    fn move_rng(&self) -> Rng {
        Rng::new(self.seed ^ self.pos.hash.rotate_left(17) ^ (self.plies as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15))
    }

    fn summary(&self) -> String {
        let why = match self.reason {
            "all_captured" => {
                if self.status == Status::Won {
                    "Rakibin bütün taşları alındı"
                } else {
                    "Bütün taşların alındı"
                }
            }
            "no_moves" => {
                if self.status == Status::Won {
                    "Rakip kilitlendi"
                } else {
                    "Hamle kalmadı"
                }
            }
            "quiet" => "40 hamle alış olmadı",
            "repetition" => "Aynı konum 3 kez",
            _ => "",
        };
        format!(
            "{why} · Kalan taşın: {} · Rakibin: {} · Hamle: {}",
            self.pos.count(YOU),
            self.pos.count(AI),
            self.player_moves
        )
    }

    fn parse_pt(v: &Value) -> Option<usize> {
        let a = v.as_array()?;
        if a.len() != 2 {
            return None;
        }
        let r = a[0].as_u64()? as usize;
        let c = a[1].as_u64()? as usize;
        (r < 6 && c < 6).then_some(r * 6 + c)
    }

    fn player_move(&mut self, a: &Value) -> Result<(), String> {
        if self.status != Status::Playing {
            return Err("Oyun bitti".into());
        }
        if self.pos.stm != YOU {
            return Err("Sıra rakipte".into());
        }
        let from = Self::parse_pt(&a["from"]).ok_or("Geçersiz nokta")?;
        let to = Self::parse_pt(&a["to"]).ok_or("Geçersiz nokta")?;
        let p = self.pos;
        if p.bb[YOU] & bit(from) == 0 {
            return Err("Orada senin taşın yok".into());
        }
        if from == to {
            return Err("Taş yerinde kaldı".into());
        }
        if p.bb[YOU] & bit(to) != 0 {
            return Err("Orada kendi taşın var".into());
        }
        let m = self.legal().into_iter().find(|m| m.from as usize == from && m.to as usize == to);
        let Some(m) = m else {
            return Err(if p.bb[AI] & bit(to) != 0 {
                "Almak için boş bir halka yolu gerek (en az bir halka)".into()
            } else {
                "Taş yalnızca bir adım gider".into()
            });
        };
        self.history.push(Snapshot {
            pos: self.pos,
            hashes: self.hashes.clone(),
            last: self.last.clone(),
            plies: self.plies,
            player_moves: self.player_moves,
        });
        self.apply(m);
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
        let (m, _) = choose(&self.pos, &self.hashes, self.prm, &mut rng).ok_or("Rakibin hamlesi yok")?;
        self.apply(m);
        Ok(())
    }

    fn complexity(&self) -> f64 {
        let mut l = MoveList::new();
        self.pos.gen(true, &mut l);
        let mut o = self.pos;
        o.stm = 1 - o.stm;
        let mut l2 = MoveList::new();
        o.gen(true, &mut l2);
        ((l.n + l2.n) as f64 / 6.0).min(1.0)
    }
}

impl Session for Surakarta {
    fn state(&self) -> Value {
        let status = match self.status {
            Status::Playing => "playing",
            Status::Won => "won",
            Status::Lost => "lost",
            Status::Draw => "draw",
        };
        let playing = self.status == Status::Playing;
        let p = &self.pos;
        let board: Vec<Vec<u8>> = (0..6)
            .map(|r| {
                (0..6)
                    .map(|c| {
                        let s = r * 6 + c;
                        if p.bb[YOU] & bit(s) != 0 {
                            1
                        } else if p.bb[AI] & bit(s) != 0 {
                            2
                        } else {
                            0
                        }
                    })
                    .collect()
            })
            .collect();
        let moves: Vec<Value> = if playing && p.stm == YOU {
            self.legal().into_iter().map(|m| move_json(p, m)).collect()
        } else {
            vec![]
        };
        let threats: Vec<Value> = if playing && p.stm == YOU {
            let mut o = *p;
            o.stm = AI;
            let mut l = MoveList::new();
            o.gen(true, &mut l);
            let mut pts: Vec<usize> = l.as_slice().iter().map(|m| m.to as usize).collect();
            pts.sort();
            pts.dedup();
            pts.into_iter().map(|q| json!([q / 6, q % 6])).collect()
        } else {
            vec![]
        };
        let last = self.last.as_ref().map(|l| {
            let (f, t) = (l.m.from as usize, l.m.to as usize);
            json!({
                "who": if l.who == YOU { "you" } else { "ai" },
                "from": [f / 6, f % 6], "to": [t / 6, t % 6],
                "capture": l.m.cap, "path": l.path, "ply": l.ply,
            })
        });
        json!({
            "status": status,
            "stars": self.stars(),
            "title": rank(self.level),
            "goal": "Rakibin bütün taşlarını al · 40 hamle taş alınmazsa çok taşlı kazanır",
            "level": self.level,
            "turn": if p.stm == YOU { "you" } else { "ai" },
            "ai_pending": playing && p.stm == AI,
            "board": board,
            "counts": {"you": p.count(YOU), "ai": p.count(AI)},
            "captured": {"you": 12 - p.count(AI), "ai": 12 - p.count(YOU)},
            "quiet": p.quiet,
            "quiet_limit": QUIET_LIMIT,
            "last_move": last,
            "moves": moves,
            "threats": threats,
            "hint": self.hint,
            "can_undo": playing && !self.history.is_empty(),
            "complexity": self.complexity(),
            "end_reason": self.reason,
            "player_moves": self.player_moves,
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
            self.hashes = snap.hashes;
            self.last = snap.last;
            self.plies = snap.plies;
            self.player_moves = snap.player_moves;
            self.serial += 1;
            self.helped = true;
            self.hint = None;
            return Ok(());
        }
        if a["hint"].as_bool() == Some(true) {
            if self.status != Status::Playing {
                return Err("Oyun bitti".into());
            }
            if self.pos.stm != YOU {
                return Err("Sıra rakipte".into());
            }
            let mut rng = self.move_rng();
            let (m, _) = choose(&self.pos, &self.hashes, full_strength(), &mut rng).ok_or("Hamle yok")?;
            self.hint = Some(move_json(&self.pos, m));
            self.helped = true;
            return Ok(());
        }
        if a["ai"].as_bool() == Some(true) {
            return self.ai_move();
        }
        if a.get("from").is_some() {
            return self.player_move(a);
        }
        Err("Bilinmeyen hamle".into())
    }
}

pub fn create(level: u32, _mode: &str) -> Result<Box<dyn Session>, String> {
    Ok(Box::new(Surakarta::new(level)))
}

// ---------------------------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn sq(r: usize, c: usize) -> usize {
        r * 6 + c
    }

    fn pos_of(you: &[(usize, usize)], ai: &[(usize, usize)], stm: usize) -> Pos {
        let mut bb = [0u64; 2];
        for &(r, c) in you {
            bb[YOU] |= bit(sq(r, c));
        }
        for &(r, c) in ai {
            bb[AI] |= bit(sq(r, c));
        }
        Pos::from_bb(bb, stm, 0, tables())
    }

    fn captures(p: &Pos) -> Vec<(usize, usize)> {
        let mut l = MoveList::new();
        p.gen(true, &mut l);
        let mut v: Vec<_> = l.as_slice().iter().map(|m| (m.from as usize, m.to as usize)).collect();
        v.sort();
        v
    }

    fn session_with(p: Pos) -> Surakarta {
        let mut g = Surakarta::new(1);
        g.pos = p;
        g
    }

    #[test]
    fn surakarta_circuits_are_correct() {
        let t = tables();
        for (ci, k) in [(0usize, 1i32), (1, 2)] {
            let cv = t.circ[ci];
            assert_eq!(cv.len(), 24);
            for j in 0..24 {
                let a = cv[j] as i32;
                let b = cv[(j + 1) % 24] as i32;
                let (ar, ac, br, bc) = (a / 6, a % 6, b / 6, b % 6);
                if j % 6 == 5 {
                    // Arc: both ends on the board edge, at distance k from the same corner.
                    let corner = ((j / 6) + 1) % 4;
                    let (cr, cc) = [(0, 0), (0, 5), (5, 5), (5, 0)][corner];
                    assert_eq!((ar - cr).abs() + (ac - cc).abs(), k, "circuit {ci} j {j}");
                    assert_eq!((br - cr).abs() + (bc - cc).abs(), k, "circuit {ci} j {j}");
                    assert!(ar == cr || ac == cc);
                    assert!(br == cr || bc == cc);
                } else {
                    assert_eq!((ar - br).abs() + (ac - bc).abs(), 1, "circuit {ci} j {j}");
                }
            }
            // Lines k and 5-k only; the four crossing points occur twice.
            let lines = [k, 5 - k];
            for s in 0..36i32 {
                let (r, c) = (s / 6, s % 6);
                let n = cv.iter().filter(|&&q| q as i32 == s).count();
                let expect = lines.contains(&r) as usize + lines.contains(&c) as usize;
                assert_eq!(n, expect, "circuit {ci} point ({r},{c})");
            }
        }
        // Corner points are on no circuit.
        assert_eq!(t.occ_n[sq(0, 0)], 0);
        assert_eq!(t.occ_n[sq(5, 5)], 0);
        assert_eq!(t.occ_n[sq(1, 1)], 2);
    }

    #[test]
    fn surakarta_start_has_no_captures() {
        let p = Pos::start(YOU);
        assert!(captures(&p).is_empty());
        let mut l = MoveList::new();
        p.gen(false, &mut l);
        assert!(l.n > 0);
    }

    #[test]
    fn surakarta_capture_requires_a_loop() {
        // Same row, adjacent, no loop → no capture (own (0,2) blocks the long way round).
        let p = pos_of(&[(2, 0), (0, 2)], &[(2, 1)], YOU);
        assert!(!captures(&p).contains(&(sq(2, 0), sq(2, 1))));
        // Without the blocker the long way (through four loops) is a legal capture.
        let p = pos_of(&[(2, 0)], &[(2, 1)], YOU);
        assert!(captures(&p).contains(&(sq(2, 0), sq(2, 1))));
        // Around the top-left outer arc: (2,0) → arc → (0,2).
        let p = pos_of(&[(2, 0)], &[(0, 2)], YOU);
        assert_eq!(captures(&p), vec![(sq(2, 0), sq(0, 2))]);
        let path = shortest_path(&p, YOU, sq(2, 0), sq(0, 2)).unwrap();
        assert_eq!(path, vec![Seg::Pt(sq(2, 0)), Seg::Arc { corner: 0, circuit: 1 }, Seg::Pt(sq(0, 2))]);
        // Inner arc top-right: (1,5) → arc → (0,4).
        let p = pos_of(&[(1, 5)], &[(0, 4)], YOU);
        assert_eq!(captures(&p), vec![(sq(1, 5), sq(0, 4))]);
    }

    #[test]
    fn surakarta_path_blocked_by_pieces() {
        // Own piece on (1,2) blocks the outer circuit column-2 path from (2,2)? Use the outer TL arc:
        // (2,1) → (2,0) → arc → (0,2): an own piece on (2,0) blocks.
        let p = pos_of(&[(2, 1), (2, 0), (1, 2)], &[(0, 2)], YOU);
        let caps = captures(&p);
        assert!(!caps.contains(&(sq(2, 1), sq(0, 2))));
        assert!(caps.contains(&(sq(2, 0), sq(0, 2))));
        // An enemy piece before the loop stops the path without a capture (no loop yet). Own pieces
        // on (2,3) and (3,2) block the long ways round.
        let p = pos_of(&[(2, 2), (2, 3), (3, 2)], &[(2, 1), (0, 2)], YOU);
        let caps = captures(&p);
        assert!(!caps.contains(&(sq(2, 2), sq(0, 2))));
        assert!(!caps.contains(&(sq(2, 2), sq(2, 1))));
    }

    #[test]
    fn surakarta_start_point_counts_as_empty() {
        // (1,1) north up column 1 → (0,1) → TL arc → (1,0) → (1,1) (itself) → hits (1,2).
        let p = pos_of(&[(1, 1)], &[(1, 2)], YOU);
        let caps = captures(&p);
        assert!(caps.contains(&(sq(1, 1), sq(1, 2))));
        let path = shortest_path(&p, YOU, sq(1, 1), sq(1, 2)).unwrap();
        assert!(path.contains(&Seg::Pt(sq(1, 1))) && path.iter().filter(|s| **s == Seg::Pt(sq(1, 1))).count() == 2);
        assert!(path.contains(&Seg::Arc { corner: 0, circuit: 0 }));
    }

    #[test]
    fn surakarta_known_positions() {
        // Long capture through two loops: (4,4) on inner col 4 going north reaches (0,4), TR arc
        // to (1,5), west along row 1 … would hit (1,3).
        let p = pos_of(&[(4, 4)], &[(1, 3)], YOU);
        let caps = captures(&p);
        assert!(caps.contains(&(sq(4, 4), sq(1, 3))));
        // AI side captures too.
        let p = pos_of(&[(5, 3)], &[(3, 5)], AI);
        // (3,5) on outer row 3, walking east→ BR arc → (5,3).
        assert!(captures(&p).contains(&(sq(3, 5), sq(5, 3))));
        // Corner pieces can never capture or be captured.
        let p = pos_of(&[(0, 0)], &[(2, 0), (0, 2)], YOU);
        assert!(captures(&p).is_empty());
    }

    #[test]
    fn surakarta_illegal_actions_rejected() {
        let mut g = Surakarta::new(1);
        let before = g.state();
        for a in [
            json!({"from": [0, 0], "to": [1, 1]}), // not mine
            json!({"from": [4, 0], "to": [3, 2]}), // too far
            json!({"from": [5, 0], "to": [4, 0]}), // own piece
            json!({"from": [4, 0], "to": [4, 0]}),
            json!({"from": [9, 0], "to": [3, 0]}),
            json!({"ai": true}),                    // not the AI's turn
            json!({"undo": true}),                  // nothing to undo
            json!({"foo": 1}),
        ] {
            assert!(g.act(&a).is_err(), "{a}");
            assert_eq!(g.state(), before, "{a}");
        }
        g.act(&json!({"from": [4, 0], "to": [3, 0]})).unwrap();
        assert!(g.act(&json!({"from": [4, 1], "to": [3, 1]})).is_err()); // AI's turn now
        assert!(g.act(&json!({"hint": true})).is_err());
        g.act(&json!({"ai": true})).unwrap();
        assert_eq!(g.state()["turn"], "you");
    }

    #[test]
    fn surakarta_even_level_ai_starts_and_undo_works() {
        let mut g = Surakarta::new(2);
        assert_eq!(g.state()["turn"], "ai");
        assert_eq!(g.state()["ai_pending"], true);
        g.act(&json!({"ai": true})).unwrap();
        let s0 = g.state();
        let mv = s0["moves"][0].clone();
        g.act(&json!({"from": mv["from"], "to": mv["to"]})).unwrap();
        g.act(&json!({"ai": true})).unwrap();
        assert_eq!(g.state()["can_undo"], true);
        g.act(&json!({"undo": true})).unwrap();
        let s1 = g.state();
        assert_eq!(s1["board"], s0["board"]);
        assert_eq!(s1["turn"], "you");
        assert!(g.helped);
    }

    #[test]
    fn surakarta_capture_action_and_last_move_path() {
        let p = pos_of(&[(2, 0), (5, 5)], &[(0, 2), (0, 0)], YOU);
        let mut g = session_with(p);
        g.act(&json!({"from": [2, 0], "to": [0, 2]})).unwrap();
        let s = g.state();
        assert_eq!(s["last_move"]["capture"], true);
        assert_eq!(s["last_move"]["path"][1]["arc"]["circuit"], "outer");
        assert_eq!(s["counts"]["ai"], 1);
        assert_eq!(s["captured"]["you"], 11);
        assert_eq!(s["quiet"], 0);
    }

    #[test]
    fn surakarta_win_by_capturing_all() {
        let p = pos_of(&[(2, 0), (5, 5), (5, 4), (4, 5), (4, 4), (5, 3)], &[(0, 2)], YOU);
        let mut g = session_with(p);
        g.act(&json!({"from": [2, 0], "to": [0, 2]})).unwrap();
        let s = g.state();
        assert_eq!(s["status"], "won");
        assert_eq!(s["stars"], 3);
        assert!(s["summary"].as_str().unwrap().contains("Kalan taşın: 6"));
    }

    #[test]
    fn surakarta_stop_rule_and_draw() {
        // Equal material when the no-capture counter runs out → draw.
        let mut p = pos_of(&[(5, 5)], &[(0, 0)], YOU);
        p.quiet = QUIET_LIMIT - 2;
        let mut g = session_with(p);
        g.act(&json!({"from": [5, 5], "to": [4, 5]})).unwrap();
        assert_eq!(g.status, Status::Playing);
        g.apply(Mv { from: 0, to: 6, cap: false });
        assert_eq!(g.status, Status::Draw);
        assert_eq!(g.reason, "quiet");
        assert_eq!(g.state()["status"], "draw");
        assert_eq!(g.state()["stars"], 0);
        // More pieces wins when it stops.
        let mut p = pos_of(&[(5, 5), (5, 4)], &[(0, 0)], YOU);
        p.quiet = QUIET_LIMIT - 1;
        let mut g = session_with(p);
        g.act(&json!({"from": [5, 5], "to": [4, 5]})).unwrap();
        assert_eq!(g.status, Status::Won);
        assert_eq!(g.reason, "quiet");
        // …and fewer loses.
        let mut p = pos_of(&[(5, 5)], &[(0, 0), (0, 5)], YOU);
        p.quiet = QUIET_LIMIT - 1;
        let mut g = session_with(p);
        g.act(&json!({"from": [5, 5], "to": [4, 5]})).unwrap();
        assert_eq!(g.status, Status::Lost);
    }

    #[test]
    fn surakarta_repetition_stops_the_game() {
        let p = pos_of(&[(5, 5)], &[(0, 0)], YOU);
        let mut g = session_with(p);
        // you: (5,5)->(5,4)->(5,5)…, AI is forced-ish to shuffle; feed AI moves manually via apply.
        let ai_moves = [Mv { from: 0, to: 1, cap: false }, Mv { from: 1, to: 0, cap: false }];
        for i in 0..8 {
            if g.status != Status::Playing {
                break;
            }
            let (f, t) = if i % 2 == 0 { ([5, 5], [5, 4]) } else { ([5, 4], [5, 5]) };
            g.act(&json!({"from": f, "to": t})).unwrap();
            if g.status != Status::Playing {
                break;
            }
            g.apply(ai_moves[i % 2]);
        }
        assert_eq!(g.status, Status::Draw);
        assert_eq!(g.reason, "repetition");
    }

    #[test]
    fn surakarta_no_moves_loses() {
        // AI piece at (0,0) boxed in by your pieces that it cannot capture (no circuit there).
        let p = pos_of(&[(0, 1), (1, 0), (1, 1), (5, 5)], &[(0, 0)], AI);
        let mut g = session_with(p);
        g.check_end();
        assert_eq!(g.status, Status::Won);
        assert_eq!(g.reason, "no_moves");
    }

    // ------------------------------------------------------------------ loop captures, in depth

    /// Independent reference for captures: walk the board geometrically, point by point, in each
    /// of the four directions; leaving the board on a circuit line takes the 270° loop around the
    /// nearer corner and re-enters on the perpendicular line. No circuit tables involved.
    fn ref_captures(p: &Pos) -> Vec<(usize, usize)> {
        let me = p.bb[p.stm];
        let opp = p.bb[1 - p.stm];
        let occ = me | opp;
        let mut out = vec![];
        for from in bits(me) {
            let (r0, c0) = ((from / 6) as i32, (from % 6) as i32);
            for (dr0, dc0) in [(0, 1), (0, -1), (1, 0), (-1, 0)] {
                let line = if dr0 == 0 { r0 } else { c0 };
                if !(1..=4).contains(&line) {
                    continue;
                }
                let (mut r, mut c, mut dr, mut dc) = (r0, c0, dr0, dc0);
                let mut looped = false;
                for _ in 0..24 {
                    let (nr, nc) = (r + dr, c + dc);
                    if (0..6).contains(&nr) && (0..6).contains(&nc) {
                        (r, c) = (nr, nc);
                    } else {
                        looped = true;
                        if dr == 0 {
                            // Off the east/west edge on row r: around the corner of the nearer half.
                            let cr = if r < 3 { 0 } else { 5 };
                            let d = (r - cr).abs();
                            (r, c) = (cr, if dc > 0 { 5 - d } else { d });
                            (dr, dc) = (if cr == 0 { 1 } else { -1 }, 0);
                        } else {
                            let cc = if c < 3 { 0 } else { 5 };
                            let d = (c - cc).abs();
                            (r, c) = (if dr > 0 { 5 - d } else { d }, cc);
                            (dr, dc) = (0, if cc == 0 { 1 } else { -1 });
                        }
                    }
                    let q = (r * 6 + c) as usize;
                    if q == from || occ & bit(q) == 0 {
                        continue;
                    }
                    if looped && opp & bit(q) != 0 {
                        out.push((from, q));
                    }
                    break;
                }
            }
        }
        out.sort();
        out.dedup();
        out
    }

    fn arcs(path: &[Seg]) -> usize {
        path.iter().filter(|s| matches!(s, Seg::Arc { .. })).count()
    }

    /// Directions (forward / backward along the circuit's walking order) that reach `to` from `from`.
    fn directions(p: &Pos, from: usize, to: usize) -> (bool, bool) {
        let t = tables();
        let occ = p.bb[0] | p.bb[1];
        let mut dummy = 0;
        let (mut f, mut b) = (false, false);
        for k in 0..t.occ_n[from] as usize {
            let (c, j) = t.occ[from][k];
            for fwd in [true, false] {
                if let Some((q, true)) = walk(t, occ, from, c as usize, j as usize, fwd, &mut dummy) {
                    if q == to && p.bb[1 - p.stm] & bit(q) != 0 {
                        if fwd {
                            f = true;
                        } else {
                            b = true;
                        }
                    }
                }
            }
        }
        (f, b)
    }

    #[test]
    fn surakarta_captures_match_geometric_reference() {
        let mut rng = Rng::new(2024);
        let mut multi_loop = 0;
        let mut through_start = 0;
        let mut total = 0;
        for case in 0..4000 {
            let mut bb = [0u64; 2];
            let density = 0.08 + 0.4 * rng.f64();
            for sq in 0..36 {
                if rng.chance(density) {
                    bb[rng.below(2)] |= bit(sq);
                }
            }
            let p = Pos::from_bb(bb, case % 2, 0, tables());
            let got = captures(&p);
            assert_eq!(got, ref_captures(&p), "case {case}: {bb:?}");
            // Every capture has a well-formed UI path: start → … → target, ≥ 1 loop, adjacent points
            // between loops, empty points (or the mover's own start) in between.
            for &(from, to) in &got {
                total += 1;
                let path = shortest_path(&p, p.stm, from, to).unwrap();
                assert_eq!(path.first(), Some(&Seg::Pt(from)));
                assert_eq!(path.last(), Some(&Seg::Pt(to)));
                assert!(arcs(&path) >= 1);
                multi_loop += (arcs(&path) >= 2) as usize;
                let pts: Vec<usize> = path.iter().filter_map(|s| if let Seg::Pt(q) = s { Some(*q) } else { None }).collect();
                through_start += (pts.iter().filter(|&&q| q == from).count() >= 2) as usize;
                for &q in &pts[1..pts.len() - 1] {
                    assert!(q == from || (bb[0] | bb[1]) & bit(q) == 0, "case {case}: blocked path point {q}");
                }
                for w in path.windows(2) {
                    if let (Seg::Pt(a), Seg::Pt(b)) = (&w[0], &w[1]) {
                        let (a, b) = (*a as i32, *b as i32);
                        assert_eq!((a / 6 - b / 6).abs() + (a % 6 - b % 6).abs(), 1, "case {case}: jump {a}→{b}");
                    }
                }
            }
        }
        println!("reference check: {total} captures, {multi_loop} through 2+ loops, {through_start} crossing their start");
        assert!(total > 2000 && multi_loop > 300 && through_start > 50, "{total} / {multi_loop} / {through_start}");
    }

    #[test]
    fn surakarta_capture_backwards_along_the_circuit() {
        // (2,0) is the first point of the outer circuit (row 2 eastwards); going *backwards* it
        // takes the top-left loop at once and lands on (0,2). The forward way (east along row 2)
        // is blocked by the own piece on (2,3).
        let p = pos_of(&[(2, 0), (2, 3)], &[(0, 2)], YOU);
        assert!(captures(&p).contains(&(sq(2, 0), sq(0, 2))));
        assert_eq!(directions(&p, sq(2, 0), sq(0, 2)), (false, true));
        // The mirror image: (0,2) is the last point of column 2 northwards; *forward* it loops to (2,0).
        let p = pos_of(&[(0, 2), (2, 3)], &[(2, 0)], YOU);
        assert_eq!(directions(&p, sq(0, 2), sq(2, 0)), (true, false));
        // "Rolling round from behind": a bottom piece runs down its column, away from the target,
        // loops around the bottom-left corner and hits a piece on its own row from behind.
        // (4,1) south → (5,1) → BL inner loop → (4,0) → (4,1) itself → (4,2) → enemy on (4,3).
        let p = pos_of(&[(4, 1), (3, 1)], &[(4, 3), (0, 0)], YOU);
        let path = shortest_path(&p, YOU, sq(4, 1), sq(4, 3)).unwrap();
        assert_eq!(
            path,
            vec![
                Seg::Pt(sq(4, 1)),
                Seg::Pt(sq(5, 1)),
                Seg::Arc { corner: 3, circuit: 0 },
                Seg::Pt(sq(4, 0)),
                Seg::Pt(sq(4, 1)),
                Seg::Pt(sq(4, 2)),
                Seg::Pt(sq(4, 3)),
            ]
        );
        // The AI does it too, against you.
        let p = pos_of(&[(1, 3), (5, 5)], &[(1, 1), (2, 1)], AI);
        let (f, b) = directions(&p, sq(1, 1), sq(1, 3));
        assert!(f || b);
        assert!(captures(&p).contains(&(sq(1, 1), sq(1, 3))));
    }

    #[test]
    fn surakarta_capture_through_several_loops() {
        // Two loops: (1,0) east along row 1 → TR loop → down column 4 → BR loop → west along row 4
        // → (4,3). The backward way round (TL, column 1, BL) is blocked by the own piece on (2,1).
        let p = pos_of(&[(1, 0), (2, 1)], &[(4, 3)], YOU);
        assert!(captures(&p).contains(&(sq(1, 0), sq(4, 3))));
        let path = shortest_path(&p, YOU, sq(1, 0), sq(4, 3)).unwrap();
        assert_eq!(arcs(&path), 2);
        assert!(path.contains(&Seg::Arc { corner: 1, circuit: 0 }) && path.contains(&Seg::Arc { corner: 2, circuit: 0 }));
        // Three loops: the same start, target on (3,1) (column 1, reached after TR, BR and BL);
        // the short backward way (TL, then down column 1) is blocked on (0,1).
        let p = pos_of(&[(1, 0), (0, 1)], &[(3, 1)], YOU);
        let path = shortest_path(&p, YOU, sq(1, 0), sq(3, 1)).unwrap();
        assert_eq!(arcs(&path), 3, "{path:?}");
        // Four loops, all the way round to the neighbour.
        let p = pos_of(&[(2, 0)], &[(2, 1)], YOU);
        let path = shortest_path(&p, YOU, sq(2, 0), sq(2, 1)).unwrap();
        assert_eq!(arcs(&path), 4);
        // An own piece anywhere on that long way blocks it.
        let p = pos_of(&[(2, 0), (5, 3)], &[(2, 1)], YOU);
        assert!(!captures(&p).contains(&(sq(2, 0), sq(2, 1))));
    }

    #[test]
    fn surakarta_capture_path_crosses_its_own_start() {
        // (2,2) sits on both outer lines. Westwards: (2,1) (2,0) → TL loop → (0,2) (1,2) → its own
        // point (2,2), which counts as empty → (3,2) → enemy on (4,2). Straight down the column the
        // enemy is reached without a loop, which is not a capture.
        let p = pos_of(&[(2, 2), (2, 3), (3, 3)], &[(4, 2)], YOU);
        assert!(captures(&p).contains(&(sq(2, 2), sq(4, 2))));
        let path = shortest_path(&p, YOU, sq(2, 2), sq(4, 2)).unwrap();
        assert_eq!(path.iter().filter(|s| **s == Seg::Pt(sq(2, 2))).count(), 2, "{path:?}");
        assert_eq!(arcs(&path), 1);
        // Another own piece on that path blocks it; the mover's own point never does.
        let p = pos_of(&[(2, 2), (1, 2), (2, 3), (3, 3)], &[(4, 2)], YOU);
        assert!(!captures(&p).contains(&(sq(2, 2), sq(4, 2))));
        // The session accepts it and reports the full path for the animation.
        let mut g = session_with(pos_of(&[(2, 2), (2, 3), (3, 3)], &[(4, 2), (0, 0)], YOU));
        let st = g.state();
        let mv = st["moves"].as_array().unwrap().iter().find(|m| m["from"] == json!([2, 2]) && m["to"] == json!([4, 2])).unwrap().clone();
        assert_eq!(mv["capture"], true);
        assert_eq!(mv["path"].as_array().unwrap().iter().filter(|s| s["pt"] == json!([2, 2])).count(), 2);
        g.act(&json!({"from": [2, 2], "to": [4, 2]})).unwrap();
        assert_eq!(g.state()["last_move"]["path"], mv["path"]);
        assert_eq!(g.state()["counts"]["ai"], 1);
    }

    #[test]
    fn surakarta_state_lists_threats_on_your_turn() {
        // The AI's (0,2) can capture your (2,0) round the top-left loop.
        let g = session_with(pos_of(&[(2, 0), (5, 5)], &[(0, 2), (0, 0)], YOU));
        let st = g.state();
        assert!(st["threats"].as_array().unwrap().contains(&json!([2, 0])));
        assert!(!st["threats"].as_array().unwrap().contains(&json!([5, 5])));
        assert!(Surakarta::new(1).state()["threats"].as_array().unwrap().is_empty());
    }

    #[test]
    fn surakarta_ai_takes_loop_captures() {
        // A free piece reachable only through loops (two of them from (1,0), one from (2,1)):
        // every level takes it.
        for lv in [1, 137, 500] {
            let p = pos_of(&[(4, 3), (5, 5), (5, 0)], &[(1, 0), (2, 1), (0, 0)], AI);
            assert!(captures(&p).contains(&(sq(1, 0), sq(4, 3))));
            let mut r = Rng::new(lv as u64);
            let (m, _) = choose(&p, &[], params(lv), &mut r).unwrap();
            assert!(m.cap && m.to as usize == sq(4, 3), "level {lv}: {m:?}");
        }
        // In real games the AI's captures include multi-loop and own-start-crossing ones.
        let mut multi = 0;
        let mut caps = 0;
        for g in 0..6u64 {
            let mut p = Pos::start(if g % 2 == 0 { YOU } else { AI });
            let mut rng = Rng::new(300 + g);
            for ply in 0..160 {
                let mut l = MoveList::new();
                p.gen(false, &mut l);
                if l.n == 0 || p.count(0) == 0 || p.count(1) == 0 || p.quiet >= QUIET_LIMIT {
                    break;
                }
                let prm = if p.stm == AI { params(250) } else { params(1) };
                let m = if ply < 2 { l.m[rng.below(l.n)] } else { choose(&p, &[], prm, &mut rng).unwrap().0 };
                if m.cap && p.stm == AI {
                    caps += 1;
                    let path = shortest_path(&p, AI, m.from as usize, m.to as usize).unwrap();
                    multi += (arcs(&path) >= 2) as usize;
                }
                p = p.make(m);
            }
        }
        println!("AI (level 250) captures: {caps}, through 2+ loops: {multi}");
        assert!(caps >= 10 && multi >= 1, "AI captures {caps}, multi-loop {multi}");
    }

    /// Play one full AI-vs-AI game; returns +1 if side A (starts as YOU) wins, -1 loss, 0 draw.
    fn duel(a: Params, b: Params, seed: u64, a_first: bool) -> (i32, u32) {
        let mut p = Pos::start(if a_first { YOU } else { AI });
        let mut hashes: Vec<u64> = vec![];
        let mut rng = Rng::new(seed);
        // Two random opening plies per side for variety.
        for plies in 0..400u32 {
            let prm = if p.stm == YOU { a } else { b };
            let mut l = MoveList::new();
            p.gen(false, &mut l);
            if p.count(p.stm) == 0 || l.n == 0 {
                return (if p.stm == YOU { -1 } else { 1 }, plies);
            }
            let rep = hashes.iter().filter(|&&h| h == p.hash).count() >= 2;
            if p.quiet >= QUIET_LIMIT || rep {
                let d = p.count(YOU) - p.count(AI);
                return (d.signum(), plies);
            }
            let m = if plies < 2 { l.m[rng.below(l.n)] } else { choose(&p, &hashes, prm, &mut rng).unwrap().0 };
            if m.cap {
                hashes.clear();
            } else {
                hashes.push(p.hash);
            }
            p = p.make(m);
        }
        (0, 400)
    }

    #[test]
    fn surakarta_ai_games_terminate() {
        for (i, lv) in [1u32, 137, 500].into_iter().enumerate() {
            let (_, plies) = duel(params(lv), params(1), 77 + i as u64, i % 2 == 0);
            assert!(plies < 400, "level {lv}");
        }
    }

    #[test]
    fn surakarta_strong_beats_weak() {
        let mut score = 0;
        let mut wins = 0;
        for g in 0..10u64 {
            let (r, _) = duel(params(500), params(1), 1000 + g, g % 2 == 0);
            score += r;
            if r > 0 {
                wins += 1;
            }
        }
        assert!(wins >= 6, "strong won {wins}/10 (score {score})");
    }

    #[test]
    fn surakarta_deterministic() {
        let run = || {
            let mut g = Surakarta::new(3);
            let mut seq = vec![];
            for _ in 0..12 {
                if g.status != Status::Playing {
                    break;
                }
                let st = g.state();
                if st["turn"] == "you" {
                    let n = st["moves"].as_array().unwrap().len();
                    let m = st["moves"][n / 2].clone();
                    g.act(&json!({"from": m["from"], "to": m["to"]})).unwrap();
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
    fn surakarta_levels_and_params() {
        for lv in [1, 2, 3, 50, 137, 250, 400, 499, 500] {
            let g = Surakarta::new(lv);
            let s = g.state();
            assert_eq!(s["status"], "playing");
            assert_eq!(s["turn"], if lv % 2 == 1 { "you" } else { "ai" });
            assert!(s["title"].is_string());
        }
        assert!(params(1).budget < params(250).budget && params(250).budget < params(500).budget);
        assert_eq!(params(500).budget, MAX_BUDGET);
        assert_eq!(rank(1), "Acemi");
        assert_eq!(rank(500), "Büyükusta");
    }

    #[test]
    fn surakarta_level_one_sees_captures() {
        // Positions from semi-random games where full strength captures: level 1 should mostly agree.
        let mut agree = 0;
        let mut total = 0;
        let mut rng = Rng::new(9);
        for g in 0..40u64 {
            let mut p = Pos::start(if g % 2 == 0 { YOU } else { AI });
            for _ in 0..(8 + rng.below(30)) {
                let mut l = MoveList::new();
                p.gen(false, &mut l);
                if l.n == 0 || p.count(p.stm) < 3 {
                    break;
                }
                // Mostly quiet random moves so material stays on the board.
                let quiet: Vec<Mv> = l.as_slice().iter().copied().filter(|m| !m.cap).collect();
                let m = if !quiet.is_empty() && rng.chance(0.8) { quiet[rng.below(quiet.len())] } else { l.m[rng.below(l.n)] };
                p = p.make(m);
            }
            if p.count(0) < 3 || p.count(1) < 3 {
                continue;
            }
            let mut r = Rng::new(g);
            let Some((best, _)) = choose(&p, &[], full_strength(), &mut r) else { continue };
            if !best.cap {
                continue;
            }
            total += 1;
            let (weak, _) = choose(&p, &[], params(1), &mut r).unwrap();
            agree += (weak == best) as u32;
        }
        assert!(total >= 8, "only {total} capture positions");
        assert!(agree * 4 >= total * 3, "level 1 agreed {agree}/{total}");
    }

    #[test]
    #[ignore]
    fn surakarta_strength_table() {
        for (a, b) in [(500u32, 1u32), (250, 1), (100, 1), (500, 250), (250, 100), (40, 1)] {
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
    fn surakarta_timing() {
        for lv in [1u32, 250, 500] {
            let prm = params(lv);
            let mut total = 0.0f64;
            let mut worst = 0.0f64;
            let mut n = 0;
            let mut nodes = 0u64;
            for g in 0..4u64 {
                let mut p = Pos::start(YOU);
                let mut rng = Rng::new(g);
                let mut hashes = vec![];
                for ply in 0..60 {
                    let mut l = MoveList::new();
                    p.gen(false, &mut l);
                    if l.n == 0 || p.count(p.stm) == 0 || p.quiet >= QUIET_LIMIT {
                        break;
                    }
                    let t0 = std::time::Instant::now();
                    let (m, nd) = if ply < 2 { (l.m[rng.below(l.n)], 0) } else { choose(&p, &hashes, prm, &mut rng).unwrap() };
                    let dt = t0.elapsed().as_secs_f64() * 1000.0;
                    if ply >= 2 {
                        total += dt;
                        worst = worst.max(dt);
                        n += 1;
                        nodes += nd;
                    }
                    if m.cap {
                        hashes.clear();
                    } else {
                        hashes.push(p.hash);
                    }
                    p = p.make(m);
                }
            }
            println!(
                "level {lv}: budget {} · avg {:.2} ms · worst {:.2} ms · avg nodes {}",
                prm.budget,
                total / n as f64,
                worst,
                nodes / n as u64
            );
        }
    }
}
