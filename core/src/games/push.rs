//! İtiş — the hexagonal marble-pushing duel, against an AI opponent.
//!
//! Board: a hexagon of side 5 = 61 cells in axial coordinates `(q, r)` with
//! `max(|q|, |r|, |q+r|) ≤ 4`. Rows of equal `r` are horizontal (pointy-top layout: pixel
//! `x = q + r/2`, `y = r·√3/2`); `r = -4` is the top row (5 cells), `r = 4` the bottom row. Cell
//! index = reading order (row by row from the top, `q` ascending). The player ("you") sits at the
//! bottom, the AI at the top.
//!
//! Directions `k` (axial deltas, counter-clockwise from east on screen):
//! 0 = (+1, 0) E · 1 = (+1, −1) NE · 2 = (0, −1) NW · 3 = (−1, 0) W · 4 = (−1, +1) SW · 5 = (0, +1) SE.
//!
//! Rules: each side has 14 marbles. A move takes 1, 2 or 3 of your marbles that stand in a straight
//! line, side by side, and moves them one step in one of the six directions:
//! - **in-line** (along their own axis; a single marble always moves "in-line"): the front cell must
//!   be empty — or hold enemy marbles that can be pushed (sumito);
//! - **broadside** (2–3 marbles, sideways): every destination cell must be empty; never pushes.
//! Sumito: the enemy line directly in front must be **outnumbered** (3→2, 3→1, 2→1) and be followed
//! by an empty cell or the edge; an enemy marble shoved over the edge is captured. You can never push
//! your own marbles, never move your own marble off the board, and a push is blocked when one of
//! your own marbles stands right behind the enemy line ("pac" = equal lines can't push at all).
//!
//! End: pushing 6 enemy marbles off wins. Draw safety: after 100 consecutive plies without a capture,
//! or on threefold repetition of a position (same side to move), the game stops: the side with more
//! marbles left wins, equal = draw. A side to move without any legal move loses (practically never
//! happens). So stalling only helps the side that is ahead.
//!
//! Starting layouts rotate with the level, `(level − 1) % 5`; the AI's marbles are the point
//! reflection `(q, r) → (−q, −r)` of yours (Papatya: the left–right mirror `(q, r) → (−q−r, r)`),
//! so every layout is fair:
//! - 0 **Klasik**: your two back rows (5 + 6) + the middle three of the third row.
//! - 1 **Papatya**: two seven-marble flowers per side (centre + its six neighbours): yours top-left
//!   and bottom-right, the AI's top-right and bottom-left — split groups that clash at once.
//! - 2 **Ayna**: your two flowers sit side by side on your half and face the enemy's two flowers
//!   head-on across the middle row (mirror image).
//! - 3 **Mızrak**: a 5-4-3-2 wedge whose tip points at the enemy's tip across one empty row.
//! - 4 **Hilal**: a crescent — your back two rows without their centre cell, plus a horn climbing
//!   each flank.
//!
//! AI: negamax + alpha-beta, iterative deepening, quiescence on push-offs, transposition table,
//! killer/history move ordering (TT move, push-offs, pushes, killers, history), all bounded by a
//! deterministic **node budget**. Evaluation (1000 = one marble, from the side to move): material
//! (dominant), centre distance (a steep penalty per ring outward, so marbles flock to the centre),
//! cohesion (friendly neighbour pairs), edge danger (marbles the enemy can shove off right now,
//! counting the exact sumito lines; one is defensible, two usually lose a marble) and a small bonus
//! for own sumito threats. Weaker opponents: smaller budget, Gaussian-ish root noise and an
//! occasional "human" slip (2nd/3rd best move within a margin well under a marble).
//!
//! Level curve (`params`), t = (level−1)/499:
//! - budget  = 2 500 · (MAX_BUDGET/2 500)^(t^0.75) nodes (L1 = 2.5k, L250 ≈ 22k, L500 = MAX_BUDGET)
//! - noise σ = 140 · (1−t)^1.6 (in 1/1000 marble; gone by ≈ L470)
//! - slip    = 12 % · (1 − t/0.7) (none from ≈ L350), only among moves within `margin` of the best
//! - margin  = 70 + 160 · (1−t)² (far below a marble: a slip never knowingly gives one away)
//! - odd levels: you start; even levels: the AI starts.
//!
//! Ranks: 1–40 Acemi · 41–100 Çırak · 101–180 Kalfa · 181–280 Usta · 281–400 Üstat · 401–500 Büyükusta.
//!
//! Stars on a win: 3 = no undo/hint and at most 2 of your marbles lost, 2 = no undo/hint,
//! 1 = undo or hint used.
//!
//! State: `{status, stars, title, goal, level, layout, layout_name, turn: "you"|"ai", ai_pending,
//!   board: [[q, r, v]] (61 cells in index order; v 0 empty · 1 you · 2 AI), counts: {you, ai},
//!   captured: {you, ai} (marbles each side has pushed off), target (6), quiet, quiet_limit,
//!   last_move: Move + {ply, who} | null, moves: [Move] (only on your turn), hint: Move | null,
//!   can_undo, complexity (0..1, for the AI pause), end_reason, summary, player_moves}`.
//! A Move is `{line: [[q,r]…] (tail → head; for in-line moves the head is in front), dir: k,
//!   kind: "inline"|"broadside", to: [[q,r]…] (line cells after the move, same order),
//!   pushed: [[q,r]…] (enemy marbles shoved, nearest first), pushed_to: [[q,r] | null…],
//!   captured: bool}`.
//! Actions: `{"line": [[q,r], …], "dir": k}` (1–3 of your marbles in any order + a direction) ·
//!   `{"ai": true}` · `{"undo": true}` (your last move and the AI's reply) · `{"hint": true}`.

use crate::rng::{seed_for, Rng};
use crate::Session;
use serde_json::{json, Value};
use std::sync::OnceLock;

const YOU: usize = 0;
const AI: usize = 1;
pub const N: usize = 61;
pub const MARBLES: i32 = 14;
pub const TARGET: i32 = 6;
pub const QUIET_LIMIT: u32 = 100;
const MAX_BUDGET: u64 = 160_000;
const OFF: u8 = 255;

const MARBLE: i32 = 1000;
const WIN: i32 = 300_000;
const STOP_WIN: i32 = 200_000;
const DECISIVE: i32 = 150_000;
const INF: i32 = 320_000;
const MAX_PLY: usize = 64;

/// Axial deltas of the six directions.
pub const DIRS: [(i32, i32); 6] = [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)];

pub const LAYOUT_NAMES: [&str; 5] = ["Klasik", "Papatya", "Ayna", "Mızrak", "Hilal"];

// ---------------------------------------------------------------------------------------------
// Static tables

struct Tables {
    coord: [(i8, i8); N],
    /// `idx[q+4][r+4]` = cell index or OFF.
    idx: [[u8; 9]; 9],
    nb: [[u8; 6]; N],
    nbmask: [u64; N],
    ring: [u8; N],
    /// Directions that lead off the board from this cell (rim cells only).
    out_dirs: [[u8; 3]; N],
    out_n: [u8; N],
    rim: u64,
    zob: [[u64; N]; 2],
    zside: u64,
    zquiet: [u64; 13],
}

fn tables() -> &'static Tables {
    static T: OnceLock<Tables> = OnceLock::new();
    T.get_or_init(|| {
        let mut coord = [(0i8, 0i8); N];
        let mut idx = [[OFF; 9]; 9];
        let mut i = 0;
        for r in -4i32..=4 {
            for q in (-4i32).max(-4 - r)..=4i32.min(4 - r) {
                coord[i] = (q as i8, r as i8);
                idx[(q + 4) as usize][(r + 4) as usize] = i as u8;
                i += 1;
            }
        }
        assert_eq!(i, N);
        let at = |q: i32, r: i32| -> u8 {
            if (-4..=4).contains(&q) && (-4..=4).contains(&r) {
                idx[(q + 4) as usize][(r + 4) as usize]
            } else {
                OFF
            }
        };
        let mut nb = [[OFF; 6]; N];
        let mut nbmask = [0u64; N];
        let mut ring = [0u8; N];
        let mut out_dirs = [[0u8; 3]; N];
        let mut out_n = [0u8; N];
        let mut rim = 0u64;
        for c in 0..N {
            let (q, r) = (coord[c].0 as i32, coord[c].1 as i32);
            ring[c] = q.abs().max(r.abs()).max((q + r).abs()) as u8;
            for (d, &(dq, dr)) in DIRS.iter().enumerate() {
                let n = at(q + dq, r + dr);
                nb[c][d] = n;
                if n == OFF {
                    out_dirs[c][out_n[c] as usize] = d as u8;
                    out_n[c] += 1;
                } else {
                    nbmask[c] |= 1 << n;
                }
            }
            if ring[c] == 4 {
                rim |= 1 << c;
            }
        }
        let mut rng = Rng::new(0x1715_0000_C0FF_EE42);
        let mut zob = [[0u64; N]; 2];
        for side in zob.iter_mut() {
            for z in side.iter_mut() {
                *z = rng.next_u64();
            }
        }
        let zside = rng.next_u64();
        let mut zquiet = [0u64; 13];
        for z in zquiet.iter_mut() {
            *z = rng.next_u64();
        }
        Tables { coord, idx, nb, nbmask, ring, out_dirs, out_n, rim, zob, zside, zquiet }
    })
}

#[inline]
fn bit(c: usize) -> u64 {
    1u64 << c
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

fn cell_at(q: i32, r: i32) -> Option<usize> {
    if !(-4..=4).contains(&q) || !(-4..=4).contains(&r) {
        return None;
    }
    let v = tables().idx[(q + 4) as usize][(r + 4) as usize];
    (v != OFF).then_some(v as usize)
}

/// `steps` cells from `c` along `d` (OFF if it leaves the board).
#[inline]
fn walk(t: &Tables, c: usize, d: usize, steps: usize) -> u8 {
    let mut x = c as u8;
    for _ in 0..steps {
        if x == OFF {
            return OFF;
        }
        x = t.nb[x as usize][d];
    }
    x
}

fn qr(c: usize) -> Value {
    let (q, r) = tables().coord[c];
    json!([q, r])
}

// ---------------------------------------------------------------------------------------------
// Layouts

/// Your 14 starting cells for a layout (the AI gets their point reflection).
pub fn layout_cells(layout: usize) -> Vec<usize> {
    let mut v: Vec<(i32, i32)> = vec![];
    let flower = |v: &mut Vec<(i32, i32)>, q: i32, r: i32| {
        v.push((q, r));
        for (dq, dr) in DIRS {
            v.push((q + dq, r + dr));
        }
    };
    match layout % 5 {
        0 => {
            v.extend((-4..=0).map(|q| (q, 4)));
            v.extend((-4..=1).map(|q| (q, 3)));
            v.extend((-2..=0).map(|q| (q, 2)));
        }
        1 => {
            flower(&mut v, 0, 3);
            flower(&mut v, 0, -3);
        }
        2 => {
            flower(&mut v, -3, 2);
            flower(&mut v, 1, 2);
        }
        3 => {
            v.extend((-4..=0).map(|q| (q, 4)));
            v.extend((-3..=0).map(|q| (q, 3)));
            v.extend((-2..=0).map(|q| (q, 2)));
            v.extend((-1..=0).map(|q| (q, 1)));
        }
        _ => {
            v.extend([(-4, 4), (-3, 4), (-1, 4), (0, 4)]);
            v.extend((-4..=1).map(|q| (q, 3)));
            v.extend([(-4, 2), (2, 2), (-4, 1), (3, 1)]);
        }
    }
    v.into_iter().map(|(q, r)| cell_at(q, r).expect("layout cell on board")).collect()
}

/// The AI's counterpart of your starting cell `c` in `layout`.
fn ai_cell(layout: usize, c: usize) -> usize {
    let (q, r) = tables().coord[c];
    let (q, r) = (q as i32, r as i32);
    if layout % 5 == 1 {
        cell_at(-q - r, r).unwrap()
    } else {
        cell_at(-q, -r).unwrap()
    }
}

// ---------------------------------------------------------------------------------------------
// Position and moves

/// A move: `n` marbles starting at `tail` along `line`, each moving one step along `dir`.
/// In-line: `line == dir` and `tail` is the rear marble. Broadside: `line` in 0..3.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
struct Mv {
    tail: u8,
    n: u8,
    line: u8,
    dir: u8,
    push: u8,
    cap: bool,
}

const NO_MOVE: Mv = Mv { tail: OFF, n: 0, line: 0, dir: 0, push: 0, cap: false };

impl Mv {
    fn inline(&self) -> bool {
        self.line == self.dir
    }
    fn cells(&self) -> Vec<usize> {
        let t = tables();
        (0..self.n as usize).map(|i| walk(t, self.tail as usize, self.line as usize, i) as usize).collect()
    }
    fn hist_idx(&self, stm: usize) -> usize {
        (((stm * N + self.tail as usize) * 6 + self.line as usize) * 6 + self.dir as usize) * 3 + self.n as usize - 1
    }
}

const HIST_SIZE: usize = 2 * N * 6 * 6 * 3;

struct MoveList {
    m: [Mv; 256],
    n: usize,
}

impl MoveList {
    fn new() -> Self {
        MoveList { m: [Mv::default(); 256], n: 0 }
    }
    #[inline]
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

const RING_W: [i32; 5] = [0, 14, 34, 62, 110];
const W_COHESION: i32 = 7;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
struct Pos {
    bb: [u64; 2],
    stm: usize,
    quiet: u32,
    hash: u64,
}

impl Pos {
    fn start(layout: usize, stm: usize) -> Pos {
        let mut bb = [0u64; 2];
        for c in layout_cells(layout) {
            bb[YOU] |= bit(c);
            bb[AI] |= bit(ai_cell(layout, c));
        }
        Pos::from_bb(bb, stm, 0)
    }

    fn from_bb(bb: [u64; 2], stm: usize, quiet: u32) -> Pos {
        let t = tables();
        let mut hash = if stm == AI { t.zside } else { 0 };
        for (s, &b) in bb.iter().enumerate() {
            for c in bits(b) {
                hash ^= t.zob[s][c];
            }
        }
        Pos { bb, stm, quiet, hash }
    }

    #[inline]
    fn count(&self, side: usize) -> i32 {
        self.bb[side].count_ones() as i32
    }

    fn gen(&self, caps_only: bool, out: &mut MoveList) {
        let t = tables();
        let s = self.stm;
        let me = self.bb[s];
        let opp = self.bb[1 - s];
        let occ = me | opp;
        for c in bits(me) {
            for d in 0..6usize {
                // In-line: the run of own marbles from tail c along d (at most 3) moves along d.
                let mut head = c;
                let mut n = 1u8;
                loop {
                    let f = t.nb[head][d];
                    if f == OFF {
                        break;
                    }
                    let f = f as usize;
                    if me & bit(f) != 0 {
                        if n == 3 {
                            break;
                        }
                        head = f;
                        n += 1;
                        continue;
                    }
                    if opp & bit(f) == 0 {
                        if !caps_only {
                            out.push(Mv { tail: c as u8, n, line: d as u8, dir: d as u8, push: 0, cap: false });
                        }
                        break;
                    }
                    // Sumito: count the enemy line in front.
                    let mut j = 0u8;
                    let mut x = f as u8;
                    while x != OFF && opp & bit(x as usize) != 0 && j < n {
                        j += 1;
                        x = t.nb[x as usize][d];
                    }
                    if j < n && (x == OFF || occ & bit(x as usize) == 0) {
                        let cap = x == OFF;
                        if cap || !caps_only {
                            out.push(Mv { tail: c as u8, n, line: d as u8, dir: d as u8, push: j, cap });
                        }
                    }
                    break;
                }
            }
            if caps_only {
                continue;
            }
            // Broadside: 2–3 marbles along axis a (0..3), sideways in the 4 other directions.
            for a in 0..3usize {
                let c1 = t.nb[c][a];
                if c1 == OFF || me & bit(c1 as usize) == 0 {
                    continue;
                }
                let c2 = t.nb[c1 as usize][a];
                let three = c2 != OFF && me & bit(c2 as usize) != 0;
                for md in 0..6usize {
                    if md == a || md == a + 3 {
                        continue;
                    }
                    let d0 = t.nb[c][md];
                    let d1 = t.nb[c1 as usize][md];
                    if d0 == OFF || d1 == OFF || occ & (bit(d0 as usize) | bit(d1 as usize)) != 0 {
                        continue;
                    }
                    out.push(Mv { tail: c as u8, n: 2, line: a as u8, dir: md as u8, push: 0, cap: false });
                    if three {
                        let d2 = t.nb[c2 as usize][md];
                        if d2 != OFF && occ & bit(d2 as usize) == 0 {
                            out.push(Mv { tail: c as u8, n: 3, line: a as u8, dir: md as u8, push: 0, cap: false });
                        }
                    }
                }
            }
        }
    }

    fn make(&self, m: Mv) -> Pos {
        let t = tables();
        let mut p = *self;
        let s = p.stm;
        let o = 1 - s;
        let old = p.bb;
        let d = m.dir as usize;
        if m.inline() {
            let head = walk(t, m.tail as usize, d, m.n as usize - 1) as usize;
            let front = t.nb[head][d] as usize;
            p.bb[s] ^= bit(m.tail as usize) | bit(front);
            if m.push > 0 {
                p.bb[o] ^= bit(front);
                let end = walk(t, front, d, m.push as usize);
                if end != OFF {
                    p.bb[o] |= bit(end as usize);
                }
            }
        } else {
            let mut c = m.tail as usize;
            let mut x = 0u64;
            for i in 0..m.n {
                if i > 0 {
                    c = t.nb[c][m.line as usize] as usize;
                }
                x |= bit(c) | bit(t.nb[c][d] as usize);
            }
            p.bb[s] ^= x;
        }
        for side in 0..2 {
            for c in bits(old[side] ^ p.bb[side]) {
                p.hash ^= t.zob[side][c];
            }
        }
        if m.cap {
            p.quiet = 0;
        } else {
            p.quiet += 1;
        }
        p.stm = o;
        p.hash ^= t.zside;
        p
    }

    fn tt_key(&self) -> u64 {
        if self.quiet >= QUIET_LIMIT - 12 {
            self.hash ^ tables().zquiet[(QUIET_LIMIT - self.quiet).min(12) as usize]
        } else {
            self.hash
        }
    }

    fn stop_score(&self, ply: usize) -> i32 {
        let d = self.count(self.stm) - self.count(1 - self.stm);
        match d.signum() {
            1 => STOP_WIN + 100 * d - ply as i32,
            -1 => -STOP_WIN + 100 * d + ply as i32,
            _ => 0,
        }
    }

    /// How many of `victim`'s marbles the other side could shove off the board right now.
    fn threats(&self, victim: usize) -> i32 {
        let t = tables();
        let mine = self.bb[victim];
        let att = self.bb[1 - victim];
        let mut n = 0;
        for c in bits(mine & t.rim) {
            'dirs: for k in 0..t.out_n[c] as usize {
                let e = (t.out_dirs[c][k] as usize + 3) % 6; // inward: the attacker pushes the other way
                let mut x = c as u8;
                let mut own = 0;
                while x != OFF && mine & bit(x as usize) != 0 {
                    own += 1;
                    if own == 3 {
                        continue 'dirs;
                    }
                    x = t.nb[x as usize][e];
                }
                let mut j = 0;
                while x != OFF && att & bit(x as usize) != 0 && j < 3 {
                    j += 1;
                    x = t.nb[x as usize][e];
                }
                if j > own {
                    n += 1;
                    break;
                }
            }
        }
        n
    }

    /// Static evaluation from the side to move's point of view (1000 = one marble).
    fn eval(&self) -> i32 {
        let t = tables();
        let s = self.stm;
        let o = 1 - s;
        let mut sc = MARBLE * (self.count(s) - self.count(o));
        for (side, sign) in [(s, 1), (o, -1)] {
            let b = self.bb[side];
            let mut pos = 0;
            for c in bits(b) {
                pos -= RING_W[t.ring[c] as usize];
                pos += W_COHESION * (t.nbmask[c] & b).count_ones() as i32;
            }
            sc += sign * pos;
        }
        // Edge danger. The side to move can rescue one threatened marble; a second usually falls.
        let mine = self.threats(s);
        let theirs = self.threats(o);
        sc -= 260 * mine.min(1) + 640 * (mine - 1).max(0);
        sc += 90 * theirs;
        sc
    }
}

// ---------------------------------------------------------------------------------------------
// Validating a player's move (with a precise Turkish reason when it is illegal)

fn classify(p: &Pos, cells: &[usize], dir: usize) -> Result<Mv, &'static str> {
    let t = tables();
    let s = p.stm;
    let me = p.bb[s];
    let opp = p.bb[1 - s];
    let occ = me | opp;
    let n = cells.len();
    if n == 0 || n > 3 {
        return Err("1, 2 ya da 3 bilye seç");
    }
    if dir >= 6 {
        return Err("Geçersiz yön");
    }
    for (i, &c) in cells.iter().enumerate() {
        if me & bit(c) == 0 {
            return Err("Orada senin bilyen yok");
        }
        if cells[..i].contains(&c) {
            return Err("Aynı bilye iki kez seçildi");
        }
    }
    // Find the axis: tail + i·a must cover the selection.
    let mut found: Option<(usize, usize)> = None;
    if n == 1 {
        found = Some((cells[0], dir));
    } else {
        'search: for &tail in cells {
            for a in 0..6 {
                let ok = (0..n).all(|i| {
                    let x = walk(t, tail, a, i);
                    x != OFF && cells.contains(&(x as usize))
                });
                if ok {
                    found = Some((tail, a));
                    break 'search;
                }
            }
        }
    }
    let Some((mut tail, mut a)) = found else {
        return Err("Bilyeler tek sırada ve yan yana olmalı");
    };
    if n == 1 || a == dir || (a + 3) % 6 == dir {
        // In-line: tail = rear marble relative to dir.
        if a != dir {
            tail = walk(t, tail, a, n - 1) as usize;
            a = dir;
        }
        let head = walk(t, tail, a, n - 1) as usize;
        let f = t.nb[head][dir];
        if f == OFF {
            return Err("Kendi bilyeni tahtadan atamazsın");
        }
        let f = f as usize;
        if me & bit(f) != 0 {
            return Err(if n == 3 { "En fazla 3 bilye birlikte gider" } else { "Önünde kendi bilyen var" });
        }
        if opp & bit(f) == 0 {
            return Ok(Mv { tail: tail as u8, n: n as u8, line: dir as u8, dir: dir as u8, push: 0, cap: false });
        }
        if n == 1 {
            return Err("Tek bilye itemez: itmek için sayıca üstün ol");
        }
        let mut j = 0;
        let mut x = f as u8;
        while x != OFF && opp & bit(x as usize) != 0 && j < 3 {
            j += 1;
            x = t.nb[x as usize][dir];
        }
        if j >= n {
            return Err(if j == n { "Denk sıralar birbirini itemez" } else { "Rakip sıra daha kalabalık: itemezsin" });
        }
        if x != OFF && me & bit(x as usize) != 0 {
            return Err("Rakibin arkasında kendi bilyen var: itemezsin");
        }
        if x != OFF && opp & bit(x as usize) != 0 {
            return Err("Rakip sıra daha kalabalık: itemezsin");
        }
        return Ok(Mv { tail: tail as u8, n: n as u8, line: dir as u8, dir: dir as u8, push: j as u8, cap: x == OFF });
    }
    // Broadside: canonical axis 0..3.
    if a >= 3 {
        tail = walk(t, tail, a, n - 1) as usize;
        a -= 3;
    }
    for i in 0..n {
        let c = walk(t, tail, a, i) as usize;
        let d = t.nb[c][dir];
        if d == OFF {
            return Err("Kendi bilyeni tahtadan atamazsın");
        }
        if occ & bit(d as usize) != 0 {
            return Err("Yan hamlede gidilen hücreler boş olmalı");
        }
    }
    Ok(Mv { tail: tail as u8, n: n as u8, line: a as u8, dir: dir as u8, push: 0, cap: false })
}

fn move_json(m: Mv) -> Value {
    let t = tables();
    let d = m.dir as usize;
    let cells = m.cells();
    let to: Vec<Value> = cells.iter().map(|&c| qr(t.nb[c][d] as usize)).collect();
    let mut pushed = vec![];
    let mut pushed_to = vec![];
    if m.inline() && m.push > 0 {
        let head = *cells.last().unwrap();
        for i in 0..m.push as usize {
            let c = walk(t, head, d, i + 1) as usize;
            pushed.push(qr(c));
            let dst = t.nb[c][d];
            pushed_to.push(if dst == OFF { Value::Null } else { qr(dst as usize) });
        }
    }
    json!({
        "line": cells.iter().map(|&c| qr(c)).collect::<Vec<_>>(),
        "dir": m.dir,
        "kind": if m.inline() { "inline" } else { "broadside" },
        "to": to,
        "pushed": pushed,
        "pushed_to": pushed_to,
        "captured": m.cap,
    })
}

// ---------------------------------------------------------------------------------------------
// Search

#[derive(Clone, Copy, Debug)]
pub struct Params {
    pub budget: u64,
    pub noise: f64,
    pub slip: f64,
    pub margin: i32,
}

pub fn params(level: u32) -> Params {
    let t = (level.clamp(1, 500) - 1) as f64 / 499.0;
    let budget = (2_500.0 * (MAX_BUDGET as f64 / 2_500.0).powf(t.powf(0.75))).round() as u64;
    Params {
        budget,
        noise: 140.0 * (1.0 - t).powf(1.6),
        slip: (0.12 * (1.0 - t / 0.7)).max(0.0),
        margin: (70.0 + 160.0 * (1.0 - t) * (1.0 - t)).round() as i32,
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
            history: vec![0; HIST_SIZE],
            stack: game_hashes.to_vec(),
        }
    }

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
        let t = tables();
        let mut keys = [0i32; 256];
        for i in 0..list.n {
            let m = list.m[i];
            keys[i] = if m == tt_move {
                1 << 30
            } else if m.cap {
                (1 << 29) + m.n as i32
            } else if m.push > 0 {
                (1 << 28) + m.n as i32
            } else if ply < MAX_PLY && (m == self.killers[ply][0] || m == self.killers[ply][1]) {
                1 << 27
            } else {
                // History, then a light static hint: bigger groups moving inwards first.
                let tail = m.tail as usize;
                let to = t.nb[tail][m.dir as usize];
                let inward = if to != OFF { t.ring[tail] as i32 - t.ring[to as usize] as i32 } else { 0 };
                self.history[m.hist_idx(p.stm)] * 8 + inward * 4 + m.n as i32
            };
        }
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
        if p.count(p.stm) <= MARBLES - TARGET {
            return -WIN + ply as i32;
        }
        let stand = p.eval();
        if stand >= beta || qd >= 6 || ply >= MAX_PLY - 1 {
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
        if p.count(p.stm) <= MARBLES - TARGET {
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
                if !m.cap && m.push == 0 {
                    if ply < MAX_PLY && self.killers[ply][0] != m {
                        self.killers[ply][1] = self.killers[ply][0];
                        self.killers[ply][0] = m;
                    }
                    let h = &mut self.history[m.hist_idx(p.stm)];
                    *h = (*h + depth * depth).min(1 << 20);
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
    s.order(p, &mut list, NO_MOVE, 0);
    let mut moves: Vec<Mv> = list.as_slice().to_vec();
    let mut done_scores: Vec<(Mv, i32)> = vec![];
    for depth in 1..40 {
        let mut alpha = -INF;
        let mut best = -INF;
        let mut cur = vec![-INF; moves.len()];
        s.stack.push(p.hash);
        for (i, &m) in moves.iter().enumerate() {
            let c = p.make(m);
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
            // A partial iteration still counts when the previous best was re-searched and another
            // move has already proved better at the new depth.
            if !human && cur[0] > -INF {
                if let Some(bi) = (1..moves.len()).filter(|&i| cur[i] > cur[0]).max_by_key(|&i| cur[i]) {
                    let m = moves[bi];
                    done_scores.retain(|&(x, _)| x != m);
                    done_scores.insert(0, (m, cur[bi]));
                }
            }
            break;
        }
        s.abort = false;
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

pub struct Push {
    level: u32,
    layout: usize,
    prm: Params,
    seed: u64,
    pos: Pos,
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

impl Push {
    pub fn new(level: u32) -> Self {
        let level = level.clamp(1, 500);
        let stm = if level % 2 == 1 { YOU } else { AI };
        let layout = ((level - 1) % 5) as usize;
        Push {
            level,
            layout,
            prm: params(level),
            seed: seed_for("push", level, 0),
            pos: Pos::start(layout, stm),
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
        self.last = Some(LastMove { who, m, ply: self.serial });
        self.hint = None;
        self.check_end();
    }

    fn check_end(&mut self) {
        let p = &self.pos;
        let side_status = |winner: usize| if winner == YOU { Status::Won } else { Status::Lost };
        for side in [YOU, AI] {
            if p.count(side) <= MARBLES - TARGET {
                self.status = side_status(1 - side);
                self.reason = "pushed_off";
                return;
            }
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

    fn lost_marbles(&self) -> i32 {
        MARBLES - self.pos.count(YOU)
    }

    fn stars(&self) -> u32 {
        if self.status != Status::Won {
            0
        } else if self.helped {
            1
        } else if self.lost_marbles() <= 2 {
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
            "pushed_off" => {
                if self.status == Status::Won {
                    "Rakibin 6 bilyesini düşürdün"
                } else {
                    "6 bilyen düşürüldü"
                }
            }
            "no_moves" => {
                if self.status == Status::Won {
                    "Rakibin hamlesi kalmadı"
                } else {
                    "Hamlen kalmadı"
                }
            }
            "quiet" => "100 hamle bilye düşmedi",
            "repetition" => "Aynı konum 3 kez",
            _ => "",
        };
        format!(
            "{why} · Düşürdüğün: {} · Kaybettiğin: {} · Hamle: {}",
            MARBLES - self.pos.count(AI),
            self.lost_marbles(),
            self.player_moves
        )
    }

    fn parse_cell(v: &Value) -> Option<usize> {
        let a = v.as_array()?;
        if a.len() != 2 {
            return None;
        }
        cell_at(a[0].as_i64()? as i32, a[1].as_i64()? as i32)
    }

    fn player_move(&mut self, a: &Value) -> Result<(), String> {
        if self.status != Status::Playing {
            return Err("Oyun bitti".into());
        }
        if self.pos.stm != YOU {
            return Err("Sıra rakipte".into());
        }
        let line = a["line"].as_array().ok_or("Bilye seç")?;
        let mut cells = vec![];
        for v in line {
            cells.push(Self::parse_cell(v).ok_or("Geçersiz hücre")?);
        }
        let dir = a["dir"].as_u64().ok_or("Bir yön seç")? as usize;
        let m = classify(&self.pos, &cells, dir)?;
        debug_assert!(self.legal().contains(&m), "classify/gen mismatch: {m:?}");
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

    /// 0..1: how tactical the position looks (pushes available to either side), for the AI pause.
    fn complexity(&self) -> f64 {
        let count = |p: &Pos| {
            let mut l = MoveList::new();
            p.gen(false, &mut l);
            l.as_slice().iter().filter(|m| m.push > 0).count()
        };
        let mut o = self.pos;
        o.stm = 1 - o.stm;
        ((count(&self.pos) + count(&o)) as f64 / 10.0).min(1.0)
    }
}

impl Session for Push {
    fn state(&self) -> Value {
        let t = tables();
        let status = match self.status {
            Status::Playing => "playing",
            Status::Won => "won",
            Status::Lost => "lost",
            Status::Draw => "draw",
        };
        let playing = self.status == Status::Playing;
        let p = &self.pos;
        let board: Vec<Value> = (0..N)
            .map(|c| {
                let v = if p.bb[YOU] & bit(c) != 0 {
                    1
                } else if p.bb[AI] & bit(c) != 0 {
                    2
                } else {
                    0
                };
                json!([t.coord[c].0, t.coord[c].1, v])
            })
            .collect();
        let moves: Vec<Value> =
            if playing && p.stm == YOU { self.legal().into_iter().map(move_json).collect() } else { vec![] };
        let last = self.last.as_ref().map(|l| {
            let mut v = move_json(l.m);
            v["who"] = json!(if l.who == YOU { "you" } else { "ai" });
            v["ply"] = json!(l.ply);
            v
        });
        json!({
            "status": status,
            "stars": self.stars(),
            "title": rank(self.level),
            "goal": format!("Rakibin 6 bilyesini tahtadan it · Diziliş: {}", LAYOUT_NAMES[self.layout]),
            "level": self.level,
            "layout": self.layout,
            "layout_name": LAYOUT_NAMES[self.layout],
            "turn": if p.stm == YOU { "you" } else { "ai" },
            "ai_pending": playing && p.stm == AI,
            "board": board,
            "counts": {"you": p.count(YOU), "ai": p.count(AI)},
            "captured": {"you": MARBLES - p.count(AI), "ai": MARBLES - p.count(YOU)},
            "target": TARGET,
            "quiet": p.quiet,
            "quiet_limit": QUIET_LIMIT,
            "last_move": last,
            "moves": moves,
            "hint": self.hint,
            "can_undo": playing && !self.history.is_empty(),
            "complexity": if playing { self.complexity() } else { 0.0 },
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
            self.hint = Some(move_json(m));
            self.helped = true;
            return Ok(());
        }
        if a["ai"].as_bool() == Some(true) {
            return self.ai_move();
        }
        if a.get("line").is_some() {
            return self.player_move(a);
        }
        Err("Bilinmeyen hamle".into())
    }
}

pub fn create(level: u32, _mode: &str) -> Result<Box<dyn Session>, String> {
    Ok(Box::new(Push::new(level)))
}

// ---------------------------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn c(q: i32, r: i32) -> usize {
        cell_at(q, r).unwrap()
    }

    fn pos_of(you: &[(i32, i32)], ai: &[(i32, i32)], stm: usize) -> Pos {
        let mut bb = [0u64; 2];
        for &(q, r) in you {
            bb[YOU] |= bit(c(q, r));
        }
        for &(q, r) in ai {
            bb[AI] |= bit(c(q, r));
        }
        Pos::from_bb(bb, stm, 0)
    }

    fn session_with(p: Pos) -> Push {
        let mut g = Push::new(1);
        g.pos = p;
        g
    }

    fn legal_set(p: &Pos) -> Vec<Mv> {
        let mut l = MoveList::new();
        p.gen(false, &mut l);
        l.as_slice().to_vec()
    }

    fn act_line(g: &mut Push, cells: &[(i32, i32)], dir: usize) -> Result<(), String> {
        let line: Vec<Value> = cells.iter().map(|&(q, r)| json!([q, r])).collect();
        g.act(&json!({"line": line, "dir": dir}))
    }

    #[test]
    fn push_board_geometry() {
        let t = tables();
        assert_eq!(t.rim.count_ones(), 24);
        assert_eq!(t.ring.iter().filter(|&&r| r == 0).count(), 1);
        for cell in 0..N {
            for d in 0..6 {
                let n = t.nb[cell][d];
                if n != OFF {
                    assert_eq!(t.nb[n as usize][(d + 3) % 6] as usize, cell);
                }
            }
        }
        assert_eq!(t.coord[0], (0, -4));
        assert_eq!(t.coord[N - 1], (0, 4));
    }

    #[test]
    fn push_layouts_valid() {
        for l in 0..5 {
            let p = Pos::start(l, YOU);
            assert_eq!(p.count(YOU), 14, "layout {l}");
            assert_eq!(p.count(AI), 14, "layout {l}");
            assert_eq!(p.bb[0] & p.bb[1], 0, "layout {l}");
            // Mirror fairness: reflecting your marbles gives the AI's.
            let refl: u64 = bits(p.bb[YOU]).map(|c| bit(ai_cell(l, c))).fold(0, |a, b| a | b);
            assert_eq!(refl, p.bb[AI]);
            // You sit (mostly) on the bottom half.
            let t = tables();
            let below: i32 = bits(p.bb[YOU]).map(|c| t.coord[c].1 as i32).sum();
            assert!(below >= 0, "layout {l}");
            assert!(!legal_set(&p).is_empty());
            // No captures or pushes at the start.
            assert!(legal_set(&p).iter().all(|m| m.push == 0), "layout {l}");
        }
        // Left-right symmetry of each layout: (q, r) → (−q−r, r).
        for l in 0..5 {
            let cells = layout_cells(l);
            let t = tables();
            for &x in &cells {
                let (q, r) = (t.coord[x].0 as i32, t.coord[x].1 as i32);
                if l != 1 {
                    assert!(cells.contains(&c(-q - r, r)), "layout {l} not mirror-symmetric");
                }
            }
        }
    }

    #[test]
    fn push_inline_and_broadside_legality() {
        let p = pos_of(&[(0, 0), (1, 0), (2, 0)], &[(-4, 4)], YOU);
        // Line of three moving east: legal; west: legal (in-line).
        assert!(classify(&p, &[c(0, 0), c(1, 0), c(2, 0)], 0).is_ok());
        assert!(classify(&p, &[c(2, 0), c(0, 0), c(1, 0)], 3).is_ok());
        // Broadside NE / SE.
        let m = classify(&p, &[c(0, 0), c(1, 0), c(2, 0)], 1).unwrap();
        assert!(!m.inline());
        assert_eq!(m.n, 3);
        // Gap in the selection.
        assert!(classify(&p, &[c(0, 0), c(2, 0)], 0).is_err());
        // Not mine.
        assert!(classify(&p, &[c(-4, 4)], 0).is_err());
        // Broadside blocked by an enemy.
        let p = pos_of(&[(0, 0), (1, 0)], &[(1, -1)], YOU);
        assert_eq!(classify(&p, &[c(0, 0), c(1, 0)], 1).unwrap_err(), "Yan hamlede gidilen hücreler boş olmalı");
        // Broadside off the board.
        let p = pos_of(&[(0, 4), (-1, 4)], &[(0, 0)], YOU);
        assert!(classify(&p, &[c(0, 4), c(-1, 4)], 5).is_err());
        // Can't step off the board.
        let p = pos_of(&[(4, 0)], &[(0, 0)], YOU);
        assert_eq!(classify(&p, &[c(4, 0)], 0).unwrap_err(), "Kendi bilyeni tahtadan atamazsın");
        // Can't move into own marble with a single.
        let p = pos_of(&[(0, 0), (1, 0)], &[(-4, 4)], YOU);
        assert!(classify(&p, &[c(0, 0)], 0).is_err());
        // Four in a row: three in front can't move.
        let p = pos_of(&[(-2, 0), (-1, 0), (0, 0), (1, 0)], &[(-4, 4)], YOU);
        assert!(classify(&p, &[c(-2, 0), c(-1, 0), c(0, 0)], 0).is_err());
        assert!(classify(&p, &[c(-1, 0), c(0, 0), c(1, 0)], 0).is_ok());
    }

    #[test]
    fn push_sumito_rules() {
        // 2 vs 1 pushes, into an empty cell.
        let p = pos_of(&[(0, 0), (1, 0)], &[(2, 0)], YOU);
        let m = classify(&p, &[c(0, 0), c(1, 0)], 0).unwrap();
        assert_eq!((m.push, m.cap), (1, false));
        let q = p.make(m);
        assert!(q.bb[AI] & bit(c(3, 0)) != 0 && q.bb[YOU] & bit(c(2, 0)) != 0 && q.bb[YOU] & bit(c(0, 0)) == 0);
        // 1 vs 1: no.
        assert!(classify(&p, &[c(1, 0)], 0).is_err());
        // 3 vs 2 and 3 vs 1.
        let p = pos_of(&[(-2, 0), (-1, 0), (0, 0)], &[(1, 0), (2, 0)], YOU);
        let m = classify(&p, &[c(-2, 0), c(-1, 0), c(0, 0)], 0).unwrap();
        assert_eq!(m.push, 2);
        let q = p.make(m);
        assert_eq!(q.count(AI), 2);
        assert!(q.bb[AI] & bit(c(3, 0)) != 0);
        // 2 vs 2 (pac): no.
        let p = pos_of(&[(-1, 0), (0, 0)], &[(1, 0), (2, 0)], YOU);
        assert_eq!(classify(&p, &[c(-1, 0), c(0, 0)], 0).unwrap_err(), "Denk sıralar birbirini itemez");
        // 3 vs 3: no.
        let p = pos_of(&[(-3, 0), (-2, 0), (-1, 0)], &[(0, 0), (1, 0), (2, 0)], YOU);
        assert!(classify(&p, &[c(-3, 0), c(-2, 0), c(-1, 0)], 0).is_err());
        // 2 vs 1 blocked by own marble behind the enemy.
        let p = pos_of(&[(-1, 0), (0, 0), (2, 0)], &[(1, 0)], YOU);
        assert_eq!(classify(&p, &[c(-1, 0), c(0, 0)], 0).unwrap_err(), "Rakibin arkasında kendi bilyen var: itemezsin");
        // 3 vs 2 where a third enemy marble sits behind: 3 vs 3, no.
        let p = pos_of(&[(-3, 0), (-2, 0), (-1, 0)], &[(0, 0), (1, 0), (2, 0)], YOU);
        assert!(legal_set(&p).iter().all(|m| m.push == 0));
        // Generator agrees on these.
        let p = pos_of(&[(-1, 0), (0, 0), (2, 0)], &[(1, 0)], YOU);
        assert!(legal_set(&p).iter().all(|m| m.push == 0));
    }

    #[test]
    fn push_off_the_board_captures() {
        // 2 vs 1 at the east edge: the enemy at (4,0) falls off.
        let p = pos_of(&[(2, 0), (3, 0)], &[(4, 0)], YOU);
        let m = classify(&p, &[c(2, 0), c(3, 0)], 0).unwrap();
        assert!(m.cap);
        let q = p.make(m);
        assert_eq!(q.count(AI), 0);
        assert_eq!(q.quiet, 0);
        // 3 vs 2 at the edge: one falls, one is shoved to the rim.
        let p = pos_of(&[(0, 0), (1, 0), (2, 0)], &[(3, 0), (4, 0)], YOU);
        let m = classify(&p, &[c(0, 0), c(1, 0), c(2, 0)], 0).unwrap();
        assert!(m.cap && m.push == 2);
        let q = p.make(m);
        assert_eq!(q.count(AI), 1);
        assert!(q.bb[AI] & bit(c(4, 0)) != 0);
        // Session: last_move describes the push.
        let mut g = session_with(pos_of(&[(2, 0), (3, 0), (-4, 4)], &[(4, 0), (-4, 0), (0, -4)], YOU));
        act_line(&mut g, &[(2, 0), (3, 0)], 0).unwrap();
        let s = g.state();
        assert_eq!(s["last_move"]["captured"], true);
        assert_eq!(s["last_move"]["pushed"], json!([[4, 0]]));
        assert_eq!(s["last_move"]["pushed_to"], json!([null]));
        assert_eq!(s["captured"]["you"], 12);
        // Threat detection sees it.
        let p = pos_of(&[(2, 0), (3, 0)], &[(4, 0)], AI);
        assert_eq!(p.threats(AI), 1);
        assert_eq!(p.threats(YOU), 0);
    }

    #[test]
    fn push_classify_matches_generator() {
        let mut rng = Rng::new(42);
        for g in 0..60u64 {
            let mut p = Pos::start((g % 5) as usize, if g % 2 == 0 { YOU } else { AI });
            for _ in 0..(10 + rng.below(50)) {
                let l = legal_set(&p);
                if l.is_empty() || p.count(0) <= 8 || p.count(1) <= 8 {
                    break;
                }
                p = p.make(l[rng.below(l.len())]);
            }
            let legal = legal_set(&p);
            // Every generated move is accepted by classify (with any cell order) and equal.
            for &m in &legal {
                let mut cells = m.cells();
                cells.reverse();
                assert_eq!(classify(&p, &cells, m.dir as usize), Ok(m));
            }
            // Every accepted (cells, dir) appears in the generator.
            let t = tables();
            for c0 in bits(p.bb[p.stm]) {
                for a in 0..6 {
                    for n in 1..=3 {
                        let cells: Vec<usize> = (0..n).map(|i| walk(t, c0, a, i)).filter(|&x| x != OFF).map(|x| x as usize).collect();
                        if cells.len() != n {
                            continue;
                        }
                        for d in 0..6 {
                            if let Ok(m) = classify(&p, &cells, d) {
                                assert!(legal.contains(&m), "{m:?} missing from gen");
                            }
                        }
                    }
                }
            }
            // Generated moves are distinct.
            for (i, a) in legal.iter().enumerate() {
                assert!(!legal[i + 1..].contains(a));
            }
            // Hash stays consistent.
            for &m in &legal {
                let q = p.make(m);
                assert_eq!(q.hash, Pos::from_bb(q.bb, q.stm, 0).hash);
                assert_eq!(q.count(0) + q.count(1) + m.cap as i32, p.count(0) + p.count(1));
            }
        }
    }

    #[test]
    fn push_illegal_actions_rejected() {
        let mut g = Push::new(1);
        let before = g.state();
        for a in [
            json!({"line": [[0, -4]], "dir": 5}),           // AI's marble
            json!({"line": [[0, 0]], "dir": 0}),             // empty cell
            json!({"line": [[-4, 4]], "dir": 4}),            // off the board
            json!({"line": [[-4, 4]], "dir": 0}),            // into own marble
            json!({"line": [[-4, 4], [-2, 4]], "dir": 1}),   // not adjacent
            json!({"line": [[-4, 4], [-3, 4], [-2, 4], [-1, 4]], "dir": 1}), // four
            json!({"line": [[-2, 2]], "dir": 9}),            // bad direction
            json!({"line": [[9, 9]], "dir": 1}),             // bad cell
            json!({"line": [[-2, 2], [-2, 2]], "dir": 1}),   // duplicate
            json!({"ai": true}),                             // not the AI's turn
            json!({"undo": true}),                           // nothing to undo
            json!({"foo": 1}),
        ] {
            assert!(g.act(&a).is_err(), "{a}");
            assert_eq!(g.state(), before, "{a}");
        }
        act_line(&mut g, &[(-2, 2), (-2, 3)], 2).unwrap(); // in-line NW from the third row
        assert_eq!(g.state()["turn"], "ai");
        assert!(act_line(&mut g, &[(-1, 2)], 2).is_err());
        assert!(g.act(&json!({"hint": true})).is_err());
        g.act(&json!({"ai": true})).unwrap();
        assert_eq!(g.state()["turn"], "you");
        assert!(g.state()["moves"].as_array().unwrap().len() > 20);
    }

    #[test]
    fn push_even_level_ai_starts_and_undo_works() {
        let mut g = Push::new(2);
        assert_eq!(g.state()["turn"], "ai");
        assert_eq!(g.state()["ai_pending"], true);
        g.act(&json!({"ai": true})).unwrap();
        let s0 = g.state();
        let mv = s0["moves"][0].clone();
        g.act(&json!({"line": mv["line"], "dir": mv["dir"]})).unwrap();
        g.act(&json!({"ai": true})).unwrap();
        assert_eq!(g.state()["can_undo"], true);
        g.act(&json!({"undo": true})).unwrap();
        let s1 = g.state();
        assert_eq!(s1["board"], s0["board"]);
        assert_eq!(s1["turn"], "you");
        assert!(g.helped);
    }

    #[test]
    fn push_win_and_stars() {
        // AI already lost 5; pushing a sixth wins with 3 stars (you lost 0).
        let ai: Vec<(i32, i32)> = vec![(4, 0), (0, -4), (1, -4), (2, -4), (3, -4), (4, -4), (-4, 0), (-3, 0), (0, -2)];
        let mut you: Vec<(i32, i32)> = vec![(2, 0), (3, 0)];
        you.extend((-4..=0).map(|q| (q, 4)));
        you.extend((-4..=1).map(|q| (q, 3)));
        you.push((0, 2));
        let mut g = session_with(pos_of(&you, &ai, YOU));
        act_line(&mut g, &[(2, 0), (3, 0)], 0).unwrap();
        let s = g.state();
        assert_eq!(s["status"], "won");
        assert_eq!(s["stars"], 3);
        assert!(s["summary"].as_str().unwrap().contains("Düşürdüğün: 6"));
        // Same win after losing 3 marbles: 2 stars.
        let you3: Vec<(i32, i32)> = you[..11].to_vec();
        let mut g = session_with(pos_of(&you3, &ai, YOU));
        act_line(&mut g, &[(2, 0), (3, 0)], 0).unwrap();
        assert_eq!(g.state()["stars"], 2);
        // With help: 1 star.
        let mut g = session_with(pos_of(&you, &ai, YOU));
        g.helped = true;
        act_line(&mut g, &[(2, 0), (3, 0)], 0).unwrap();
        assert_eq!(g.state()["stars"], 1);
    }

    #[test]
    fn push_stop_rule_and_draw() {
        // Ten marbles a side, far apart: your (0,0) and the AI's (0,-4) are the movers.
        let mut you: Vec<(i32, i32)> = vec![(0, 0)];
        you.extend((-4..=0).map(|q| (q, 4)));
        you.extend((-4..=-1).map(|q| (q, 3)));
        let mut ai: Vec<(i32, i32)> = (0..=4).map(|q| (q, -4)).collect();
        ai.extend((1..=4).map(|q| (q, -3)));
        ai.push((4, -2));
        let mut p = pos_of(&you, &ai, YOU);
        p.quiet = QUIET_LIMIT - 2;
        let mut g = session_with(p);
        act_line(&mut g, &[(0, 0)], 0).unwrap();
        assert_eq!(g.status, Status::Playing);
        g.apply(classify(&g.pos, &[c(0, -4)], 5).unwrap());
        assert_eq!(g.status, Status::Draw);
        assert_eq!(g.reason, "quiet");
        assert_eq!(g.state()["status"], "draw");
        assert_eq!(g.state()["stars"], 0);
        // More marbles wins when it stops.
        let mut you2 = you.clone();
        you2.push((-4, 2));
        let mut p = pos_of(&you2, &ai, YOU);
        p.quiet = QUIET_LIMIT - 1;
        let mut g = session_with(p);
        act_line(&mut g, &[(0, 0)], 0).unwrap();
        assert_eq!(g.status, Status::Won);
        assert_eq!(g.reason, "quiet");
        // …and fewer loses.
        let mut p = pos_of(&you[..9], &ai, YOU);
        p.quiet = QUIET_LIMIT - 1;
        let mut g = session_with(p);
        act_line(&mut g, &[(0, 0)], 0).unwrap();
        assert_eq!(g.status, Status::Lost);
        // Threefold repetition.
        let mut g = session_with(pos_of(&you, &ai, YOU));
        for i in 0..8 {
            if g.status != Status::Playing {
                break;
            }
            let (from, d) = if i % 2 == 0 { ((0, 0), 0) } else { ((1, 0), 3) };
            act_line(&mut g, &[from], d).unwrap();
            if g.status != Status::Playing {
                break;
            }
            let (from, d) = if i % 2 == 0 { (c(0, -4), 5) } else { (c(0, -3), 2) };
            g.apply(classify(&g.pos, &[from], d).unwrap());
        }
        assert_eq!(g.status, Status::Draw);
        assert_eq!(g.reason, "repetition");
    }

    #[test]
    fn push_ai_takes_free_marble_and_defends() {
        // AI to move can push a player marble off: it must.
        let mut you = vec![(0, 0), (1, 0), (4, -4)];
        you.extend((-4..=0).map(|q| (q, 4)));
        you.extend((-4..=-1).map(|q| (q, 3)));
        let ai = [(2, -4), (3, -4), (-2, -2), (-1, -2), (0, -2), (1, -2), (-3, -1), (-2, -1), (-1, -1), (-4, 0)];
        let p = pos_of(&you, &ai, AI);
        let mut rng = Rng::new(1);
        // (4,-4) is a rim corner; AI line (2,-4),(3,-4) pushes it east off the board.
        let (m, _) = choose(&p, &[], params(1), &mut rng).unwrap();
        assert!(m.cap, "{m:?}");
    }

    /// One AI-vs-AI game; +1 if A (moves as YOU) wins, −1 loss, 0 draw.
    fn duel(a: Params, b: Params, seed: u64, a_first: bool, layout: usize) -> (i32, u32) {
        let mut p = Pos::start(layout, if a_first { YOU } else { AI });
        let mut hashes: Vec<u64> = vec![];
        let mut rng = Rng::new(seed);
        for plies in 0..1500u32 {
            for side in [YOU, AI] {
                if p.count(side) <= MARBLES - TARGET {
                    return (if side == YOU { -1 } else { 1 }, plies);
                }
            }
            let rep = hashes.iter().filter(|&&h| h == p.hash).count() >= 2;
            if p.quiet >= QUIET_LIMIT || rep {
                return ((p.count(YOU) - p.count(AI)).signum(), plies);
            }
            let prm = if p.stm == YOU { a } else { b };
            let l = legal_set(&p);
            if l.is_empty() {
                return (if p.stm == YOU { -1 } else { 1 }, plies);
            }
            let m = if plies < 2 { l[rng.below(l.len())] } else { choose(&p, &hashes, prm, &mut rng).unwrap().0 };
            if m.cap {
                hashes.clear();
            } else {
                hashes.push(p.hash);
            }
            p = p.make(m);
        }
        ((p.count(YOU) - p.count(AI)).signum(), 1500)
    }

    /// The strong side in debug-mode tests: full strength in release, a lighter budget in debug
    /// builds so `cargo test` stays quick (still far above level 1).
    fn strong() -> Params {
        if cfg!(debug_assertions) {
            Params { budget: 30_000, ..params(500) }
        } else {
            params(500)
        }
    }

    #[test]
    fn push_ai_games_terminate() {
        for (i, lv) in [1u32, 137].into_iter().enumerate() {
            let (_, plies) = duel(params(lv), params(1), 77 + i as u64, i % 2 == 0, i);
            assert!(plies < 1500, "level {lv}");
        }
    }

    #[test]
    fn push_strong_beats_weak() {
        let mut wins = 0;
        let mut log = vec![];
        for g in 0..10u64 {
            let (r, n) = duel(strong(), params(1), 1000 + g, g % 2 == 0, (g % 5) as usize);
            log.push((r, n));
            if r > 0 {
                wins += 1;
            }
        }
        assert!(wins >= 8, "strong won {wins}/10: {log:?}");
    }

    #[test]
    fn push_deterministic() {
        let run = || {
            let mut g = Push::new(3);
            let mut seq = vec![];
            for _ in 0..10 {
                if g.status != Status::Playing {
                    break;
                }
                let st = g.state();
                if st["turn"] == "you" {
                    let n = st["moves"].as_array().unwrap().len();
                    let m = st["moves"][n / 2].clone();
                    g.act(&json!({"line": m["line"], "dir": m["dir"]})).unwrap();
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
    fn push_levels_and_params() {
        for lv in [1, 2, 3, 50, 137, 250, 400, 499, 500] {
            let g = Push::new(lv);
            let s = g.state();
            assert_eq!(s["status"], "playing");
            assert_eq!(s["turn"], if lv % 2 == 1 { "you" } else { "ai" });
            assert!(s["title"].is_string());
            assert_eq!(s["board"].as_array().unwrap().len(), 61);
            assert_eq!(s["counts"]["you"], 14);
            assert_eq!(s["layout"], ((lv - 1) % 5) as u64);
        }
        assert!(params(1).budget < params(250).budget && params(250).budget < params(500).budget);
        assert_eq!(params(500).budget, MAX_BUDGET);
        assert_eq!(params(500).noise, 0.0);
        assert_eq!(rank(1), "Acemi");
        assert_eq!(rank(500), "Büyükusta");
    }

    #[test]
    #[ignore]
    fn push_strength_table() {
        for (a, b) in [(500u32, 1u32), (250, 1), (100, 1), (500, 250), (250, 100), (40, 1)] {
            let (mut w, mut d, mut l, mut plies) = (0, 0, 0, 0);
            for g in 0..10u64 {
                let (r, n) = duel(params(a), params(b), 5000 + g, g % 2 == 0, (g % 5) as usize);
                plies += n;
                match r {
                    1 => w += 1,
                    0 => d += 1,
                    _ => l += 1,
                }
            }
            println!("L{a} vs L{b}: +{w} ={d} -{l} · avg plies {}", plies / 10);
        }
    }

    #[test]
    #[ignore]
    fn push_timing() {
        for lv in [1u32, 250, 500] {
            let prm = params(lv);
            let mut total = 0.0f64;
            let mut worst = 0.0f64;
            let mut n = 0;
            let mut nodes = 0u64;
            for g in 0..5u64 {
                let mut p = Pos::start(g as usize, YOU);
                let mut rng = Rng::new(g);
                let mut hashes = vec![];
                for ply in 0..80 {
                    let l = legal_set(&p);
                    if l.is_empty() || p.count(0) <= 8 || p.count(1) <= 8 || p.quiet >= QUIET_LIMIT {
                        break;
                    }
                    let t0 = std::time::Instant::now();
                    let (m, nd) = if ply < 2 { (l[rng.below(l.len())], 0) } else { choose(&p, &hashes, prm, &mut rng).unwrap() };
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
