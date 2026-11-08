//! Düşen Bloklar — the falling four-cell-block well game.
//!
//! A 10×20 well (plus 4 hidden spawn rows), the seven one-sided pieces I O T S Z J L, a seeded
//! 7-bag, box rotation with SRS-style wall kicks, hold (once per piece), a next queue of 3, ghost,
//! gravity by speed level, soft/hard drop, a 500 ms lock delay with 15 move resets (refilled when
//! the piece reaches a new lowest row), line clears with single/double/triple/quad scoring,
//! T-spins (3-corner rule), combos, back-to-back and all-clear bonuses. Game over on block-out
//! (spawn blocked), lock-out (piece locked fully above the visible well) or garbage push-out.
//!
//! Time only advances through `tick(dt_ms)`.
//!
//! ## Level curve (`params`)
//! `t = (level-1)/5` (0..=99) is the tier, `(level-1) % 5` picks the goal kind; base speed
//! `sb = 3 + 9t/99` (3..=12, guideline gravity: speed 3 ≈ 0.62 s/row, 12 ≈ 0.035 s/row).
//! - 0 **Lines**: clear `20 + t/6` lines (20..36); from tier 25 the well starts with 1..3 garbage rows.
//! - 1 **Lines within pieces**: `15 + t/10` lines in `ceil(2.5n) + slack` pieces, slack 22 → 8, speed sb+1.
//! - 2 **Dig**: clear `7 + 5t/99` pre-filled garbage rows (7..12); holes wander more and rows get
//!   two holes as t rises.
//! - 3 **Survive**: `60 + 60t/99` s (rounded to 5 s) at speed sb+2 while garbage rises every
//!   `14 − 9t/99` s.
//! - 4 **Score**: reach `speed × (3200 + 28t)` points (rounded to 100) within 60 pieces.
//!
//! Stars measure efficiency (pieces used, or lines cleared while surviving).
//! Endless (Maraton): speed 1, +1 every 10 lines (cap 20 = instant gravity), `score` = points.
//!
//! State: `{status, stars, title, goal, score, summary?, b, cur, gd, hold, ch, nx, clr, lk, ev, et,
//!          sp, hud: [[label, value]]}`
//! - `b`: 200-char string, visible rows top→bottom, `'0'` empty, `'1'..'7'` = I O T S Z J L, `'8'` garbage.
//! - `cur`: `[kind, x0,y0, x1,y1, x2,y2, x3,y3]` (y relative to the visible top, may be negative) or `[]`.
//! - `gd`: ghost drop distance in rows. `hold`: kind or 0, `ch`: hold available. `nx`: next 3 kinds.
//! - `clr`: visible row indices flashing (line-clear animation, 280 ms). `lk`: lock-delay progress 0..1.
//! - `ev`/`et`: event serial + text ("Dörtlü!", "T-dönüş ikili", "Kombo 3"...).
//!
//! Actions: `{"a":"l"|"r"|"d"|"hd"|"cw"|"ccw"|"hold"}` — left, right, soft drop one row, hard drop,
//! rotate clockwise / counter-clockwise, hold. A blocked move is accepted as a no-op (no toast while
//! playing fast); hold twice, unknown actions or acting after the end are rejected.

use crate::rng::{seed_for, time_seed, Rng};
use crate::Session;
use serde_json::{json, Value};
use std::collections::VecDeque;

pub const W: usize = 10;
pub const VIS: usize = 20;
pub const HID: usize = 4;
pub const H: usize = VIS + HID;

const LOCK_MS: f64 = 500.0;
const MAX_RESETS: u32 = 15;
const CLEAR_MS: f64 = 280.0;
const GARBAGE: u8 = 8;

const KI: u8 = 1;
const KO: u8 = 2;
const KT: u8 = 3;

/// Spawn-orientation cells of each kind inside its rotation box (y down).
fn spawn_cells(k: u8) -> [(i32, i32); 4] {
    match k {
        1 => [(0, 1), (1, 1), (2, 1), (3, 1)], // I
        2 => [(0, 0), (1, 0), (0, 1), (1, 1)], // O
        3 => [(1, 0), (0, 1), (1, 1), (2, 1)], // T
        4 => [(1, 0), (2, 0), (0, 1), (1, 1)], // S
        5 => [(0, 0), (1, 0), (1, 1), (2, 1)], // Z
        6 => [(0, 0), (0, 1), (1, 1), (2, 1)], // J
        _ => [(2, 0), (0, 1), (1, 1), (2, 1)], // L
    }
}

fn box_size(k: u8) -> i32 {
    match k {
        KI => 4,
        KO => 2,
        _ => 3,
    }
}

/// Cells for kind `k` in rotation `rot` (0 spawn, 1 R, 2 180, 3 L): clockwise box rotation.
fn shape(k: u8, rot: u8) -> [(i32, i32); 4] {
    let n = box_size(k);
    let mut c = spawn_cells(k);
    for _ in 0..rot % 4 {
        for p in c.iter_mut() {
            *p = (n - 1 - p.1, p.0);
        }
    }
    c
}

/// SRS kick offsets (x right, y DOWN) for a rotation `from → to`.
fn kicks(k: u8, from: u8, to: u8) -> [(i32, i32); 5] {
    if k == KO {
        return [(0, 0); 5];
    }
    if k == KI {
        // Wiki table is y-up; negate y.
        let t: [(i32, i32); 5] = match (from, to) {
            (0, 1) => [(0, 0), (-2, 0), (1, 0), (-2, -1), (1, 2)],
            (1, 0) => [(0, 0), (2, 0), (-1, 0), (2, 1), (-1, -2)],
            (1, 2) => [(0, 0), (-1, 0), (2, 0), (-1, 2), (2, -1)],
            (2, 1) => [(0, 0), (1, 0), (-2, 0), (1, -2), (-2, 1)],
            (2, 3) => [(0, 0), (2, 0), (-1, 0), (2, 1), (-1, -2)],
            (3, 2) => [(0, 0), (-2, 0), (1, 0), (-2, -1), (1, 2)],
            (3, 0) => [(0, 0), (1, 0), (-2, 0), (1, -2), (-2, 1)],
            _ => [(0, 0), (-1, 0), (2, 0), (-1, 2), (2, -1)], // (0, 3)
        };
        return t.map(|(x, y)| (x, -y));
    }
    // JLSTZ: kick = offset[from] − offset[to] (y-up offsets).
    const OFF: [[(i32, i32); 5]; 4] = [
        [(0, 0); 5],
        [(0, 0), (1, 0), (1, -1), (0, 2), (1, 2)],
        [(0, 0); 5],
        [(0, 0), (-1, 0), (-1, -1), (0, 2), (-1, 2)],
    ];
    let mut out = [(0, 0); 5];
    for (i, o) in out.iter_mut().enumerate() {
        let a = OFF[from as usize][i];
        let b = OFF[to as usize][i];
        *o = (a.0 - b.0, -(a.1 - b.1));
    }
    out
}

/// Guideline gravity: milliseconds per row at a speed level.
pub fn ms_per_row(speed: u32) -> f64 {
    let s = speed.clamp(1, 20) as f64;
    1000.0 * (0.8 - (s - 1.0) * 0.007).powf(s - 1.0)
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Goal {
    /// Clear `n` lines; `max_pieces` 0 = unlimited.
    Lines { n: u32, max_pieces: u32 },
    /// Clear every pre-filled garbage row.
    Dig { rows: u32 },
    /// Stay alive for `secs` seconds.
    Survive { secs: u32 },
    /// Reach `target` points within `max_pieces`.
    Score { target: u64, max_pieces: u32 },
}

#[derive(Clone, Debug)]
pub struct Params {
    pub goal: Option<Goal>,
    pub speed: u32,
    pub prefill: u32,
    pub hole_change: f64,
    pub double_hole: f64,
    pub rise_ms: f64,
    pub title: &'static str,
}

pub fn params(level: u32) -> Params {
    let level = level.clamp(1, crate::MAX_LEVEL);
    let t = (level - 1) / 5;
    let sb = 3 + t * 9 / 99;
    let tf = t as f64 / 99.0;
    let base = Params {
        goal: None,
        speed: sb,
        prefill: 0,
        hole_change: 0.35 + 0.6 * tf,
        double_hole: if t > 50 { (tf - 0.5) * 0.8 } else { 0.0 },
        rise_ms: 0.0,
        title: "",
    };
    match (level - 1) % 5 {
        0 => Params { goal: Some(Goal::Lines { n: 20 + t / 6, max_pieces: 0 }), prefill: t / 25, title: "Satır", ..base },
        1 => {
            let n = 15 + t / 10;
            let slack = 22 - t * 14 / 99;
            let max = (n * 5).div_ceil(2) + slack;
            Params { goal: Some(Goal::Lines { n, max_pieces: max }), speed: sb + 1, title: "Sınırlı taş", ..base }
        }
        2 => Params { goal: Some(Goal::Dig { rows: 7 + t * 5 / 99 }), prefill: 7 + t * 5 / 99, title: "Kazı", ..base },
        3 => {
            let secs = (60 + t * 60 / 99) / 5 * 5;
            Params {
                goal: Some(Goal::Survive { secs }),
                speed: sb + 2,
                rise_ms: (14.0 - 9.0 * tf) * 1000.0,
                title: "Hayatta kal",
                ..base
            }
        }
        _ => {
            let target = (sb as u64 * (3200 + 28 * t as u64)).div_ceil(100) * 100;
            Params { goal: Some(Goal::Score { target, max_pieces: 60 }), title: "Puan", ..base }
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct Piece {
    k: u8,
    rot: u8,
    x: i32,
    y: i32,
}

impl Piece {
    fn spawn(k: u8) -> Piece {
        let x = if k == KO { 4 } else { 3 };
        // 3-wide pieces occupy the last hidden row and the top visible row; I sits in the top visible row.
        Piece { k, rot: 0, x, y: HID as i32 - 1 }
    }
    fn cells(&self) -> [(i32, i32); 4] {
        shape(self.k, self.rot).map(|(cx, cy)| (self.x + cx, self.y + cy))
    }
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Status {
    Playing,
    Won,
    Lost,
}

#[derive(Clone)]
pub struct Blocks {
    endless: bool,
    goal: Option<Goal>,
    title: &'static str,
    board: [u8; W * H],
    cur: Option<Piece>,
    hold: u8,
    can_hold: bool,
    queue: VecDeque<u8>,
    bag_rng: Rng,
    garb_rng: Rng,
    hole: usize,
    hole_change: f64,
    double_hole: f64,
    speed: u32,
    start_speed: u32,
    fall_acc: f64,
    lock_ms: f64,
    resets: u32,
    lowest: i32,
    last_rot: bool,
    last_kick: usize,
    clearing: Vec<usize>,
    clear_ms: f64,
    rise_ms: f64,
    rise_acc: f64,
    prefill_cells: u32,
    score: u64,
    lines: u32,
    pieces: u32,
    time_ms: f64,
    combo: i32,
    b2b: bool,
    quads: u32,
    tspins: u32,
    status: Status,
    ev: u32,
    et: String,
}

pub fn create(level: u32, mode: &str) -> Result<Box<dyn Session>, String> {
    Ok(Box::new(Blocks::new(level, mode)))
}

impl Blocks {
    pub fn new(level: u32, mode: &str) -> Self {
        if mode == "endless" {
            let seed = time_seed();
            return Self::build(None, 1, 0, 0.5, 0.0, 0.0, "Maraton", seed, true);
        }
        let p = params(level);
        let seed = seed_for("falling_blocks", level, 0);
        Self::build(p.goal, p.speed, p.prefill, p.hole_change, p.double_hole, p.rise_ms, p.title, seed, false)
    }

    #[allow(clippy::too_many_arguments)]
    fn build(
        goal: Option<Goal>,
        speed: u32,
        prefill: u32,
        hole_change: f64,
        double_hole: f64,
        rise_ms: f64,
        title: &'static str,
        seed: u64,
        endless: bool,
    ) -> Self {
        let mut garb_rng = Rng::new(seed ^ 0xA5A5_5A5A_1234_5678);
        let hole = garb_rng.below(W);
        let mut g = Blocks {
            endless,
            goal,
            title,
            board: [0; W * H],
            cur: None,
            hold: 0,
            can_hold: true,
            queue: VecDeque::new(),
            bag_rng: Rng::new(seed),
            garb_rng,
            hole,
            hole_change,
            double_hole,
            speed,
            start_speed: speed,
            fall_acc: 0.0,
            lock_ms: 0.0,
            resets: 0,
            lowest: 0,
            last_rot: false,
            last_kick: 0,
            clearing: vec![],
            clear_ms: 0.0,
            rise_ms,
            rise_acc: 0.0,
            prefill_cells: 0,
            score: 0,
            lines: 0,
            pieces: 0,
            time_ms: 0.0,
            combo: -1,
            b2b: false,
            quads: 0,
            tspins: 0,
            status: Status::Playing,
            ev: 0,
            et: String::new(),
        };
        for _ in 0..prefill {
            g.push_garbage();
        }
        g.prefill_cells = g.board.iter().filter(|&&c| c != 0).count() as u32;
        g.refill();
        g.spawn_next();
        g
    }

    fn refill(&mut self) {
        while self.queue.len() < 7 {
            let mut bag = [1u8, 2, 3, 4, 5, 6, 7];
            self.bag_rng.shuffle(&mut bag);
            self.queue.extend(bag);
        }
    }

    fn cell(&self, x: i32, y: i32) -> u8 {
        if x < 0 || x >= W as i32 || y >= H as i32 {
            return 9; // wall / floor
        }
        if y < 0 {
            return 0; // open sky above the buffer
        }
        self.board[y as usize * W + x as usize]
    }

    fn fits(&self, p: &Piece) -> bool {
        p.cells().iter().all(|&(x, y)| self.cell(x, y) == 0)
    }

    fn grounded(&self, p: &Piece) -> bool {
        !self.fits(&Piece { y: p.y + 1, ..*p })
    }

    fn drop_dist(&self, p: &Piece) -> i32 {
        let mut d = 0;
        while self.fits(&Piece { y: p.y + d + 1, ..*p }) {
            d += 1;
        }
        d
    }

    fn spawn_piece(&mut self, k: u8) {
        let p = Piece::spawn(k);
        self.fall_acc = 0.0;
        self.lock_ms = 0.0;
        self.resets = 0;
        self.lowest = p.y;
        self.last_rot = false;
        if !self.fits(&p) {
            self.cur = None;
            self.status = Status::Lost;
            return;
        }
        self.cur = Some(p);
    }

    fn spawn_next(&mut self) {
        let k = self.queue.pop_front().unwrap_or(KT);
        self.refill();
        self.spawn_piece(k);
    }

    /// Push one garbage row in from the bottom. Returns false on push-out (top-out).
    fn push_garbage(&mut self) -> bool {
        let overflow = self.board[..W].iter().any(|&c| c != 0);
        self.board.copy_within(W.., 0);
        if self.garb_rng.chance(self.hole_change) {
            let mut h = self.garb_rng.below(W - 1);
            if h >= self.hole {
                h += 1;
            }
            self.hole = h;
        }
        let row = (H - 1) * W;
        for x in 0..W {
            self.board[row + x] = GARBAGE;
        }
        self.board[row + self.hole] = 0;
        if self.garb_rng.chance(self.double_hole) {
            let mut h2 = self.garb_rng.below(W - 1);
            if h2 >= self.hole {
                h2 += 1;
            }
            self.board[row + h2] = 0;
        }
        !overflow
    }

    fn garbage_rows_left(&self) -> u32 {
        (0..H)
            .filter(|y| !self.clearing.contains(y) && self.board[y * W..(y + 1) * W].contains(&GARBAGE))
            .count() as u32
    }

    fn try_move(&mut self, dx: i32, dy: i32) -> bool {
        let Some(p) = self.cur else { return false };
        let np = Piece { x: p.x + dx, y: p.y + dy, ..p };
        if self.fits(&np) {
            self.cur = Some(np);
            self.after_move(np);
            self.last_rot = false;
            true
        } else {
            false
        }
    }

    fn try_rotate(&mut self, cw: bool) -> bool {
        let Some(p) = self.cur else { return false };
        if p.k == KO {
            return false;
        }
        let to = if cw { (p.rot + 1) % 4 } else { (p.rot + 3) % 4 };
        for (i, (kx, ky)) in kicks(p.k, p.rot, to).into_iter().enumerate() {
            let np = Piece { rot: to, x: p.x + kx, y: p.y + ky, ..p };
            if self.fits(&np) {
                self.cur = Some(np);
                self.after_move(np);
                self.last_rot = true;
                self.last_kick = i;
                return true;
            }
        }
        false
    }

    /// Lock-delay bookkeeping after a successful move or rotation.
    fn after_move(&mut self, np: Piece) {
        if np.y > self.lowest {
            self.lowest = np.y;
            self.resets = 0;
            self.lock_ms = 0.0;
        } else if self.lock_ms > 0.0 && self.resets < MAX_RESETS {
            self.lock_ms = 0.0;
            self.resets += 1;
        }
    }

    fn tspin_kind(&self, p: &Piece) -> u8 {
        // 0 none, 1 mini, 2 full
        if p.k != KT || !self.last_rot {
            return 0;
        }
        let occ = |dx: i32, dy: i32| self.cell(p.x + dx, p.y + dy) != 0;
        let corners = [occ(0, 0), occ(2, 0), occ(0, 2), occ(2, 2)];
        if corners.iter().filter(|&&c| c).count() < 3 {
            return 0;
        }
        let front = match p.rot {
            0 => corners[0] && corners[1],
            1 => corners[1] && corners[3],
            2 => corners[2] && corners[3],
            _ => corners[0] && corners[2],
        };
        if front || self.last_kick == 4 {
            2
        } else {
            1
        }
    }

    fn lock(&mut self) {
        let Some(p) = self.cur.take() else { return };
        let ts = self.tspin_kind(&p);
        let mut all_hidden = true;
        for (x, y) in p.cells() {
            if y >= 0 {
                self.board[y as usize * W + x as usize] = p.k;
            }
            if y >= HID as i32 {
                all_hidden = false;
            }
        }
        self.pieces += 1;
        self.can_hold = true;
        if all_hidden {
            self.status = Status::Lost;
            return;
        }
        let full: Vec<usize> = (0..H).filter(|&y| self.board[y * W..(y + 1) * W].iter().all(|&c| c != 0)).collect();
        let n = full.len();
        let lvl = self.speed as u64;
        let mut pts: u64 = match (ts, n) {
            (2, _) => [400, 800, 1200, 1600][n.min(3)],
            (1, _) => [100, 200, 400, 400][n.min(3)],
            _ => [0, 100, 300, 500, 800][n.min(4)],
        } * lvl;
        let mut parts: Vec<String> = vec![];
        if n > 0 {
            let difficult = n == 4 || ts > 0;
            if difficult && self.b2b {
                pts = pts * 3 / 2;
                parts.push("Art arda".into());
            }
            self.b2b = difficult;
            self.combo += 1;
            if self.combo > 0 {
                pts += 50 * self.combo as u64 * lvl;
            }
        } else {
            self.combo = -1;
        }
        let name = ["", "tekli", "ikili", "üçlü", "dörtlü"][n.min(4)];
        if ts > 0 {
            self.tspins += 1;
            let mini = if ts == 1 { " mini" } else { "" };
            parts.push(format!("T-dönüş{mini}{}{name}", if n > 0 { " " } else { "" }));
        } else if n == 4 {
            self.quads += 1;
            parts.push("Dörtlü!".into());
        } else if n > 1 {
            parts.push(["", "", "İkili", "Üçlü"][n.min(3)].to_string());
        }
        if self.combo > 0 {
            parts.push(format!("Kombo {}", self.combo));
        }
        // All clear: nothing left outside the cleared rows.
        if n > 0 && (0..H).all(|y| full.contains(&y) || self.board[y * W..(y + 1) * W].iter().all(|&c| c == 0)) {
            pts += [0, 800, 1200, 1800, 2000][n.min(4)] * lvl;
            parts.push("Tam temizlik!".into());
        }
        self.score += pts;
        self.lines += n as u32;
        if !parts.is_empty() {
            self.ev += 1;
            self.et = parts.join(" · ");
        }
        if self.endless {
            self.speed = (self.start_speed + self.lines / 10).min(20);
        }
        self.clearing = full;
        self.clear_ms = 0.0;
        if self.check_goal() {
            self.remove_cleared();
            return;
        }
        if self.status != Status::Playing {
            return;
        }
        if self.clearing.is_empty() {
            self.spawn_next();
        }
    }

    /// Goal check after a lock; sets won / lost. Returns true when the level was won.
    fn check_goal(&mut self) -> bool {
        let Some(goal) = self.goal else { return false };
        let (done, max) = match goal {
            Goal::Lines { n, max_pieces } => (self.lines >= n, max_pieces),
            Goal::Dig { .. } => (self.garbage_rows_left() == 0, 0),
            Goal::Survive { .. } => (false, 0),
            Goal::Score { target, max_pieces } => (self.score >= target, max_pieces),
        };
        if done {
            self.status = Status::Won;
            return true;
        }
        if max > 0 && self.pieces >= max {
            self.status = Status::Lost;
        }
        false
    }

    fn remove_cleared(&mut self) {
        let rows = std::mem::take(&mut self.clearing);
        if rows.is_empty() {
            return;
        }
        let mut nb = [0u8; W * H];
        let mut dst = H;
        for y in (0..H).rev() {
            if rows.contains(&y) {
                continue;
            }
            dst -= 1;
            nb[dst * W..(dst + 1) * W].copy_from_slice(&self.board[y * W..(y + 1) * W]);
        }
        self.board = nb;
    }

    fn hard_drop(&mut self) {
        let Some(p) = self.cur else { return };
        let d = self.drop_dist(&p);
        if d > 0 {
            self.cur = Some(Piece { y: p.y + d, ..p });
            self.last_rot = false;
        }
        self.score += 2 * d as u64;
        self.lock();
    }

    fn do_hold(&mut self) -> Result<(), String> {
        let Some(p) = self.cur else { return Ok(()) };
        if !self.can_hold {
            return Err("Bu taşı zaten sakladın".into());
        }
        self.can_hold = false;
        if self.hold == 0 {
            self.hold = p.k;
            self.spawn_next();
        } else {
            let k = self.hold;
            self.hold = p.k;
            self.spawn_piece(k);
        }
        Ok(())
    }

    fn stars(&self) -> u32 {
        if self.status != Status::Won {
            return 0;
        }
        let pieces = self.pieces as f64;
        let ideal_lines = |n: u32| ((n * 10).saturating_sub(self.prefill_cells.min(n * 10))) as f64 / 4.0;
        let (three, two) = match self.goal {
            Some(Goal::Lines { n, max_pieces: 0 }) => {
                let i = ideal_lines(n);
                (pieces <= i + 10.0, pieces <= i + 22.0)
            }
            Some(Goal::Lines { n, max_pieces }) => {
                let i = ideal_lines(n);
                let slack = max_pieces as f64 - i;
                (pieces <= i + slack * 0.4, pieces <= i + slack * 0.75)
            }
            Some(Goal::Dig { rows }) => {
                let r = rows as f64;
                (pieces <= r * 2.5 + 3.0, pieces <= r * 4.0 + 6.0)
            }
            Some(Goal::Survive { secs }) => {
                let l = self.lines as f64;
                (l >= secs as f64 / 4.0, l >= secs as f64 / 8.0)
            }
            Some(Goal::Score { max_pieces, .. }) => {
                let m = max_pieces as f64;
                (pieces <= m * 0.8, pieces <= m * 0.92)
            }
            None => (false, false),
        };
        if three {
            3
        } else if two {
            2
        } else {
            1
        }
    }

    fn goal_text(&self) -> String {
        match self.goal {
            None => "Hız her 10 satırda artar · üste ulaşma".into(),
            Some(Goal::Lines { n, max_pieces: 0 }) => format!("{n} satır temizle"),
            Some(Goal::Lines { n, max_pieces }) => format!("{n} satır temizle · {max_pieces} taş içinde"),
            Some(Goal::Dig { rows }) => format!("{rows} gri çöp satırının hepsini temizle"),
            Some(Goal::Survive { secs }) => format!("{secs} saniye dayan · zemin yükseliyor"),
            Some(Goal::Score { target, max_pieces }) => format!("{target} puan yap · {max_pieces} taş içinde"),
        }
    }

    fn hud(&self) -> Value {
        let secs = (self.time_ms / 1000.0) as u64;
        let clock = format!("{}:{:02}", secs / 60, secs % 60);
        match self.goal {
            None => json!([["Puan", self.score], ["Satır", self.lines], ["Hız", self.speed]]),
            Some(Goal::Lines { n, max_pieces }) => {
                let taş = if max_pieces > 0 { format!("{}/{}", self.pieces, max_pieces) } else { self.pieces.to_string() };
                json!([["Satır", format!("{}/{}", self.lines.min(n), n)], ["Taş", taş], ["Puan", self.score]])
            }
            Some(Goal::Dig { .. }) => {
                json!([["Kalan çöp", self.garbage_rows_left()], ["Taş", self.pieces], ["Puan", self.score]])
            }
            Some(Goal::Survive { secs: total }) => {
                let left = (total as f64 - self.time_ms / 1000.0).max(0.0).ceil() as u64;
                json!([["Kalan", format!("{}:{:02}", left / 60, left % 60)], ["Satır", self.lines], ["Hız", self.speed]])
            }
            Some(Goal::Score { target, max_pieces }) => json!([
                ["Puan", format!("{}/{}", self.score, target)],
                ["Taş", format!("{}/{}", self.pieces, max_pieces)],
                ["Süre", clock]
            ]),
        }
    }

    fn summary(&self) -> String {
        let secs = (self.time_ms / 1000.0) as u64;
        format!(
            "Satır: {} · Taş: {} · Dörtlü: {} · T-dönüş: {} · Süre: {}:{:02}",
            self.lines,
            self.pieces,
            self.quads,
            self.tspins,
            secs / 60,
            secs % 60
        )
    }
}

impl Session for Blocks {
    fn state(&self) -> Value {
        let status = match self.status {
            Status::Playing => "playing",
            Status::Won => "won",
            Status::Lost => "lost",
        };
        let b: String = self.board[HID * W..].iter().map(|&c| (b'0' + c) as char).collect();
        let (cur, gd) = match self.cur {
            Some(p) => {
                let mut v = vec![p.k as i32];
                for (x, y) in p.cells() {
                    v.push(x);
                    v.push(y - HID as i32);
                }
                (v, self.drop_dist(&p))
            }
            None => (vec![], 0),
        };
        let clr: Vec<i32> = self.clearing.iter().map(|&y| y as i32 - HID as i32).filter(|&y| y >= 0).collect();
        let nx: Vec<u8> = self.queue.iter().take(3).copied().collect();
        let mut v = json!({
            "status": status,
            "stars": self.stars(),
            "title": self.title,
            "goal": self.goal_text(),
            "score": self.score,
            "b": b,
            "cur": cur,
            "gd": gd,
            "hold": self.hold,
            "ch": self.can_hold,
            "nx": nx,
            "clr": clr,
            "lk": (self.lock_ms / LOCK_MS).min(1.0),
            "ev": self.ev,
            "et": self.et,
            "sp": self.speed,
            "hud": self.hud(),
        });
        if self.status != Status::Playing {
            v["summary"] = json!(self.summary());
        }
        v
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if self.status != Status::Playing {
            return Err("Oyun bitti".into());
        }
        let cmd = a["a"].as_str().ok_or("Hamle eksik")?;
        if !matches!(cmd, "l" | "r" | "d" | "hd" | "cw" | "ccw" | "hold") {
            return Err("Bilinmeyen hamle".into());
        }
        if self.cur.is_none() {
            return Ok(()); // line-clear pause: input ignored
        }
        match cmd {
            "l" => {
                self.try_move(-1, 0);
            }
            "r" => {
                self.try_move(1, 0);
            }
            "d" => {
                if self.try_move(0, 1) {
                    self.score += 1;
                    self.fall_acc = 0.0;
                }
            }
            "hd" => self.hard_drop(),
            "cw" => {
                self.try_rotate(true);
            }
            "ccw" => {
                self.try_rotate(false);
            }
            _ => self.do_hold()?,
        }
        Ok(())
    }

    fn tick(&mut self, dt: f64) {
        if self.status != Status::Playing {
            return;
        }
        let dt = dt.clamp(0.0, 250.0);
        self.time_ms += dt;
        if let Some(Goal::Survive { secs }) = self.goal {
            if self.time_ms >= secs as f64 * 1000.0 {
                self.status = Status::Won;
                return;
            }
        }
        if !self.clearing.is_empty() {
            self.clear_ms += dt;
            if self.clear_ms >= CLEAR_MS {
                self.remove_cleared();
                self.spawn_next();
            }
            return;
        }
        if self.rise_ms > 0.0 {
            self.rise_acc += dt;
            if self.rise_acc >= self.rise_ms {
                self.rise_acc -= self.rise_ms;
                if !self.push_garbage() {
                    self.status = Status::Lost;
                    return;
                }
                if let Some(p) = self.cur {
                    let up = Piece { y: p.y - 1, ..p };
                    if !self.fits(&p) {
                        self.cur = Some(up);
                        self.lowest = self.lowest.min(up.y);
                    }
                }
            }
        }
        let Some(p) = self.cur else {
            self.spawn_next();
            return;
        };
        self.fall_acc += dt / ms_per_row(self.speed);
        let mut p = p;
        while self.fall_acc >= 1.0 {
            let np = Piece { y: p.y + 1, ..p };
            if self.fits(&np) {
                p = np;
                self.fall_acc -= 1.0;
                self.last_rot = false;
                if p.y > self.lowest {
                    self.lowest = p.y;
                    self.resets = 0;
                    self.lock_ms = 0.0;
                }
            } else {
                self.fall_acc = 0.0;
            }
        }
        self.cur = Some(p);
        if self.grounded(&p) {
            self.lock_ms += dt;
            if self.lock_ms >= LOCK_MS {
                self.lock();
            }
        } else {
            self.lock_ms = 0.0;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LEVELS: [u32; 9] = [1, 2, 3, 50, 137, 250, 400, 499, 500];

    /// Board heuristic (aggregate height, lines, holes, bumpiness) on a W×H array.
    fn evaluate(board: &[u8; W * H]) -> f64 {
        let mut heights = [0i32; W];
        let mut holes = 0;
        for x in 0..W {
            let mut seen = false;
            for y in 0..H {
                let c = board[y * W + x] != 0;
                if c && !seen {
                    seen = true;
                    heights[x] = (H - y) as i32;
                } else if !c && seen {
                    holes += 1;
                }
            }
        }
        let agg: i32 = heights.iter().sum();
        let bump: i32 = heights.windows(2).map(|w| (w[0] - w[1]).abs()).sum();
        -0.51 * agg as f64 - 0.36 * holes as f64 - 0.18 * bump as f64
    }

    fn cleared(board: &[u8; W * H]) -> ([u8; W * H], u32) {
        let mut nb = [0u8; W * H];
        let mut dst = H;
        let mut n = 0;
        for y in (0..H).rev() {
            if board[y * W..(y + 1) * W].iter().all(|&c| c != 0) {
                n += 1;
                continue;
            }
            dst -= 1;
            nb[dst * W..(dst + 1) * W].copy_from_slice(&board[y * W..(y + 1) * W]);
        }
        (nb, n)
    }

    /// Greedy one-piece bot: tries every rotation × column (and hold), returns the action list.
    fn plan(g: &Blocks) -> Vec<&'static str> {
        let mut best = (f64::MIN, vec![]);
        for use_hold in [false, true] {
            if use_hold && !g.can_hold {
                continue;
            }
            let mut base = g.clone();
            let mut pre: Vec<&'static str> = vec![];
            if use_hold {
                base.act(&json!({"a": "hold"})).unwrap();
                pre.push("hold");
                if base.cur.is_none() {
                    continue;
                }
            }
            for r in 0..4 {
                for dx in -5i32..=5 {
                    let mut t = base.clone();
                    let mut acts = pre.clone();
                    for _ in 0..r {
                        t.try_rotate(true);
                    }
                    acts.extend(std::iter::repeat_n("cw", r));
                    let step = if dx < 0 { -1 } else { 1 };
                    let mut ok = true;
                    for _ in 0..dx.abs() {
                        if !t.try_move(step, 0) {
                            ok = false;
                            break;
                        }
                        acts.push(if step < 0 { "l" } else { "r" });
                    }
                    if !ok {
                        continue;
                    }
                    let p = t.cur.unwrap();
                    let d = t.drop_dist(&p);
                    let mut b = t.board;
                    for (x, y) in (Piece { y: p.y + d, ..p }).cells() {
                        if y < 0 {
                            continue;
                        }
                        b[y as usize * W + x as usize] = p.k;
                    }
                    let (nb, n) = cleared(&b);
                    let s = evaluate(&nb) + 0.76 * n as f64;
                    if s > best.0 {
                        acts.push("hd");
                        best = (s, acts);
                    }
                }
            }
        }
        best.1
    }

    /// Plays until finished; `gap` ms of "thinking" between pieces. Returns the final status.
    fn bot_play(g: &mut Blocks, gap: f64, max_pieces: u32) -> Status {
        let mut guard = 0;
        while g.status == Status::Playing && g.pieces < max_pieces {
            if g.cur.is_some() {
                for a in plan(g) {
                    g.act(&json!({ "a": a })).unwrap();
                }
            }
            let mut t = 0.0;
            while t < gap && g.status == Status::Playing {
                g.tick(16.0);
                t += 16.0;
            }
            guard += 1;
            assert!(guard < 5000);
        }
        g.status
    }

    #[test]
    fn falling_blocks_rotation_and_kicks() {
        // Every shape keeps 4 distinct cells inside its box and 4 rotations return to start.
        for k in 1..=7u8 {
            let s0 = shape(k, 0);
            assert_eq!(shape(k, 4), s0);
            for r in 0..4 {
                let s = shape(k, r);
                for &(x, y) in &s {
                    assert!(x >= 0 && y >= 0 && x < box_size(k) && y < box_size(k));
                }
            }
        }
        // JLSTZ 0→R kicks match the published table (y down).
        assert_eq!(kicks(KT, 0, 1), [(0, 0), (-1, 0), (-1, -1), (0, 2), (-1, 2)]);
        // A T rotated against the left wall kicks back in.
        let mut g = Blocks::new(1, "level");
        g.cur = Some(Piece { k: KT, rot: 1, x: -1, y: 10 });
        assert!(g.fits(&g.cur.unwrap()));
        assert!(g.try_rotate(true));
        assert!(g.cur.unwrap().cells().iter().all(|&(x, _)| x >= 0));
    }

    #[test]
    fn falling_blocks_levels_generate_and_are_deterministic() {
        for level in LEVELS {
            let a = Blocks::new(level, "level");
            let b = Blocks::new(level, "level");
            assert_eq!(a.board, b.board);
            assert_eq!(a.queue, b.queue);
            assert!(a.cur.is_some());
            assert_eq!(a.status, Status::Playing);
            let st = a.state();
            assert_eq!(st["b"].as_str().unwrap().len(), W * VIS);
            assert!(st["goal"].as_str().is_some());
        }
        // Bag property: every 7 consecutive pieces from the start contain each kind once.
        let mut g = Blocks::new(1, "level");
        let mut seq = vec![g.cur.unwrap().k];
        for _ in 0..13 {
            seq.push(g.queue.pop_front().unwrap());
            g.refill();
        }
        for bag in seq.chunks(7) {
            let mut s = bag.to_vec();
            s.sort();
            assert_eq!(s, vec![1, 2, 3, 4, 5, 6, 7]);
        }
    }

    #[test]
    fn falling_blocks_illegal_actions_rejected() {
        let mut g = Blocks::new(1, "level");
        let before = g.state();
        assert!(g.act(&json!({"a": "jump"})).is_err());
        assert!(g.act(&json!({})).is_err());
        assert_eq!(g.state(), before);
        g.act(&json!({"a": "hold"})).unwrap();
        let held = g.state();
        assert!(g.act(&json!({"a": "hold"})).is_err());
        assert_eq!(g.state(), held);
        // Walls: moving left 20 times stops at the wall without errors.
        for _ in 0..20 {
            g.act(&json!({"a": "l"})).unwrap();
        }
        assert!(g.cur.unwrap().cells().iter().all(|&(x, _)| x >= 0));
    }

    #[test]
    fn falling_blocks_line_clear_and_scoring() {
        let mut g = Blocks::new(1, "level");
        // Fill the bottom row except columns 3..=6, then drop a flat I there.
        for x in 0..W {
            if !(3..=6).contains(&x) {
                g.board[(H - 1) * W + x] = 8;
            }
        }
        g.cur = Some(Piece::spawn(KI));
        g.act(&json!({"a": "hd"})).unwrap();
        assert_eq!(g.lines, 1);
        assert_eq!(g.clearing.len(), 1);
        for _ in 0..30 {
            g.tick(16.0);
        }
        assert!(g.clearing.is_empty());
        assert!(g.board.iter().all(|&c| c == 0));
        // Single (100×3) + all clear (800×3) + hard drop points.
        assert!(g.score >= 2700);
    }

    #[test]
    fn falling_blocks_gravity_and_lock_delay() {
        let mut g = Blocks::new(1, "endless");
        let y0 = g.cur.unwrap().y;
        g.tick(250.0);
        let mut t = 0.0;
        while t < 1100.0 {
            g.tick(16.0);
            t += 16.0;
        }
        assert!(g.cur.unwrap().y > y0, "speed 1 drops a row per second");
        // Hard drop then nothing locks until the next piece.
        let pieces = g.pieces;
        g.act(&json!({"a": "d"})).unwrap();
        g.act(&json!({"a": "hd"})).unwrap();
        assert_eq!(g.pieces, pieces + 1);
        // Lock delay: a grounded piece waits ~500 ms.
        let p = g.cur.unwrap();
        let d = g.drop_dist(&p);
        g.cur = Some(Piece { y: p.y + d, ..p });
        g.tick(150.0);
        g.tick(150.0);
        assert_eq!(g.pieces, pieces + 1);
        g.tick(250.0);
        assert_eq!(g.pieces, pieces + 2);
    }

    #[test]
    fn falling_blocks_bot_wins_levels() {
        let mut stars = vec![];
        for level in [1, 2, 3, 4, 5, 6, 8, 9, 10] {
            let mut g = Blocks::new(level, "level");
            let st = bot_play(&mut g, 400.0, 400);
            assert_eq!(st, Status::Won, "level {level}: {}", g.summary());
            stars.push((level, g.stars()));
            assert!(g.stars() >= 1);
        }
        // A greedy bot without T-spins should still earn 3 stars on the opening levels.
        assert!(stars.iter().filter(|s| s.1 == 3).count() >= 5, "{stars:?}");
    }

    #[test]
    fn falling_blocks_endless_reaches_lost() {
        let mut g = Blocks::new(1, "endless");
        let mut guard = 0;
        while g.status == Status::Playing {
            g.act(&json!({"a": "hd"})).unwrap();
            for _ in 0..20 {
                g.tick(16.0);
            }
            guard += 1;
            assert!(guard < 200);
        }
        assert_eq!(g.status, Status::Lost);
        assert!(g.state()["summary"].is_string());
        assert!(g.act(&json!({"a": "l"})).is_err());
    }

    #[test]
    fn falling_blocks_tspin_double_detected() {
        let mut g = Blocks::new(1, "level");
        // Classic T-spin double slot at the bottom-left.
        //  row H-3: X X . . . . . . . .    (overhang at x=0..1)
        //  row H-2: X . . . X X X X X X    (wait: need slot) — build explicitly:
        let rows = ["##........", "#...######", "##.#######"];
        for (i, r) in rows.iter().enumerate() {
            let y = H - 3 + i;
            for (x, ch) in r.chars().enumerate() {
                if ch == '#' {
                    g.board[y * W + x] = 8;
                }
            }
        }
        // T pointing down (rot 2) at box x=1, y=H-3: cells (1..3, H-2) and (2, H-1).
        // Approach: T in rot 1 just above, rotate cw into the slot.
        g.cur = Some(Piece { k: KT, rot: 1, x: 1, y: H as i32 - 3 });
        assert!(g.fits(&g.cur.unwrap()));
        assert!(g.try_rotate(true));
        let p = g.cur.unwrap();
        assert_eq!(g.drop_dist(&p), 0, "{:?}", p);
        let lines = g.lines;
        g.lock();
        assert_eq!(g.lines - lines, 2);
        assert_eq!(g.tspins, 1);
        assert!(g.et.contains("T-dönüş ikili"), "{}", g.et);
    }

    #[test]
    #[ignore]
    fn falling_blocks_calibrate() {
        for level in [1, 2, 3, 4, 5, 51, 52, 53, 54, 55, 251, 252, 253, 254, 255, 496, 497, 498, 499, 500] {
            let mut g = Blocks::new(level, "level");
            let st = bot_play(&mut g, 350.0, 400);
            println!("L{level:>3} {:?} {:?} stars={} {} score={}", g.goal, st, g.stars(), g.summary(), g.score);
        }
    }

    #[test]
    #[ignore]
    fn falling_blocks_timing() {
        let t = std::time::Instant::now();
        for level in 1..=500 {
            let g = Blocks::new(level, "level");
            assert!(g.cur.is_some());
        }
        println!("falling_blocks: 500 levels generated in {:?}", t.elapsed());
        let mut g = Blocks::new(250, "level");
        let t = std::time::Instant::now();
        let mut bytes = 0;
        for _ in 0..1000 {
            g.tick(16.0);
            bytes += g.state().to_string().len();
        }
        println!("falling_blocks: 1000 tick+state in {:?}, avg state {} bytes", t.elapsed(), bytes / 1000);
    }
}
