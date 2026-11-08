//! Blok Merkezi — 9×9 block-placing puzzle.
//!
//! The board is 9×9 with nine 3×3 boxes. Each round offers three pieces drawn (weighted, seeded)
//! from a catalogue of 29 polyomino shapes. Placing a piece scores one point per cell; every full
//! row, column and 3×3 box is cleared at once. Scoring for `c` units cleared by one placement:
//! `18·c²` (simultaneous clears multiply) `+ 12·(streak−1)·c`, where the streak grows with each
//! clearing placement and resets after three placements in a row without a clear. Emptying the
//! board gives +300. A new set of three arrives when all are placed; the game ends when none of the
//! remaining pieces fits anywhere.
//!
//! Turn-based: no ticks.
//!
//! ## Level curve (`params`)
//! `t = (level-1)/4` (0..=124), `d = t/124`, `(level-1) % 4` picks the goal:
//! - 0 **Score**: reach `S = 320 + 3t` points within `N = 32` pieces.
//! - 1 **Clear**: clear `U = 6 + t/12` units (rows/columns/boxes) within `N = 30 + t/25` pieces.
//! - 2 **Cleanup**: the board starts with `10 + 20d` stone cells; clear them all within `32 + 6d` pieces.
//! - 3 **Endure**: place `30 + t/2` pieces without getting stuck; the board starts with `8 + 22d`
//!   stones; stars by points per piece (24 / 15).
//!
//! Stars for the budgeted goals: 3★ when done within 70 % of the pieces, 2★ within 85 %.
//! The piece mix gets harder with `d` (fewer monos/dominoes, more 3×3 squares, big Ls, diagonals and
//! 2×3 blocks), and the "mercy" re-deal (re-draw a set when nothing fits) drops from 3 tries to 0.
//! Endless: the same mix ramps with score (d = score/4000), mercy 3 → 0.
//!
//! State: `{status, stars, title, goal, score, summary?, b, tray, pv, ev, et, lc, streak, hud}`
//! - `b`: 81-char string row-major, `'0'` empty, `'1'` placed, `'2'` stone (pre-filled).
//! - `tray`: 3 entries, each `null` (used) or `{"s": shape, "c": [x0,y0,...], "w", "h", "f": fits}`.
//! - `pv`: last preview `{"x","y","p","ok","c":[cells],"cl":[cells that would clear]}` or null.
//! - `ev`/`et`/`lc`: event serial, text and cleared cell indices (for the clear animation).
//! - `lu`/`lp`/`ac`: units cleared, points scored and whether the board was emptied by the last
//!   clearing placement (event `ev`), so the UI can size its combo callout and count lines.
//!
//! Actions: `{"a":"pv","p":i,"x":x,"y":y}` preview (no state change but `pv`), `{"a":"pv"}` clear
//! preview, `{"a":"place","p":i,"x":x,"y":y}` place tray piece `i` with its box's top-left at (x, y).

use crate::rng::{seed_for, time_seed, Rng};
use crate::Session;
use serde_json::{json, Value};

pub const N: usize = 9;
const CELLS: usize = N * N;

/// Shape catalogue: rows separated by '/', '#' = cell. Class 0 easy, 1 medium, 2 hard.
const SHAPES: [(&str, u8); 29] = [
    ("#", 0),
    ("##", 0),
    ("#/#", 0),
    ("###", 0),
    ("#/#/#", 0),
    ("##/#.", 0),
    ("##/.#", 0),
    ("#./##", 0),
    (".#/##", 0),
    ("##/##", 1),
    ("####", 1),
    ("#/#/#/#", 1),
    ("###/#..", 1),
    ("###/..#", 1),
    ("#../###", 1),
    ("..#/###", 1),
    ("###/.#.", 1),
    (".#./###", 1),
    (".##/##.", 1),
    ("#./##/.#", 1),
    ("#./.#", 1),
    (".#/#.", 1),
    ("#####", 2),
    ("#/#/#/#/#", 2),
    ("###/###/###", 2),
    ("###/#../#..", 2),
    ("###/..#/..#", 2),
    ("#../.#./..#", 2),
    ("###/###", 2),
];

#[derive(Clone, Debug)]
struct Shape {
    cells: Vec<(usize, usize)>,
    w: usize,
    h: usize,
    class: u8,
}

fn catalogue() -> Vec<Shape> {
    SHAPES
        .iter()
        .map(|&(pat, class)| {
            let mut cells = vec![];
            let mut w = 0;
            let rows: Vec<&str> = pat.split('/').collect();
            for (y, r) in rows.iter().enumerate() {
                w = w.max(r.len());
                for (x, ch) in r.chars().enumerate() {
                    if ch == '#' {
                        cells.push((x, y));
                    }
                }
            }
            Shape { cells, w, h: rows.len(), class }
        })
        .collect()
}

fn weight(class: u8, d: f64) -> f64 {
    match class {
        0 => 1.0 - 0.6 * d,
        1 => 1.0,
        _ => 0.3 + 1.1 * d,
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Goal {
    Score { target: u32, max: u32 },
    Clear { units: u32, max: u32 },
    Cleanup { max: u32 },
    Endure { pieces: u32 },
}

#[derive(Clone, Debug)]
pub struct Params {
    pub goal: Goal,
    pub difficulty: f64,
    pub stones: usize,
    pub mercy: u32,
    pub title: &'static str,
}

pub fn params(level: u32) -> Params {
    let level = level.clamp(1, crate::MAX_LEVEL);
    let t = (level - 1) / 4;
    let d = t as f64 / 124.0;
    let mercy = (3.0 - 3.2 * d).round().max(0.0) as u32;
    match (level - 1) % 4 {
        0 => Params { goal: Goal::Score { target: 320 + 3 * t, max: 32 }, difficulty: d, stones: 0, mercy, title: "Puan" },
        1 => Params {
            goal: Goal::Clear { units: 6 + t / 12, max: 30 + t / 25 },
            difficulty: d,
            stones: 0,
            mercy,
            title: "Temizle",
        },
        2 => Params {
            goal: Goal::Cleanup { max: 32 + (6.0 * d) as u32 },
            difficulty: d,
            stones: 10 + (20.0 * d) as usize,
            mercy,
            title: "Taşları kır",
        },
        _ => Params {
            goal: Goal::Endure { pieces: 30 + t / 2 },
            difficulty: d,
            stones: 8 + (22.0 * d) as usize,
            mercy,
            title: "Dayan",
        },
    }
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Status {
    Playing,
    Won,
    Lost,
}

#[derive(Clone)]
pub struct BlockGrid {
    shapes: Vec<Shape>,
    goal: Option<Goal>,
    title: &'static str,
    difficulty: f64,
    mercy: u32,
    board: [u8; CELLS],
    tray: [Option<usize>; 3],
    rng: Rng,
    score: u32,
    placed: u32,
    units: u32,
    streak: u32,
    dry: u32,
    best_combo: u32,
    status: Status,
    preview: Option<(usize, i32, i32)>,
    ev: u32,
    et: String,
    lc: Vec<usize>,
    lu: u32,
    lp: u32,
    ac: bool,
}

pub fn create(level: u32, mode: &str) -> Result<Box<dyn Session>, String> {
    Ok(Box::new(BlockGrid::new(level, mode)))
}

/// Cell indices of every full row, column and box (deduplicated), plus the unit count.
fn full_units(b: &[u8; CELLS]) -> (Vec<usize>, u32) {
    let mut mark = [false; CELLS];
    let mut units = 0;
    for i in 0..N {
        if (0..N).all(|x| b[i * N + x] != 0) {
            units += 1;
            (0..N).for_each(|x| mark[i * N + x] = true);
        }
        if (0..N).all(|y| b[y * N + i] != 0) {
            units += 1;
            (0..N).for_each(|y| mark[y * N + i] = true);
        }
        let (bx, by) = (i % 3 * 3, i / 3 * 3);
        if (0..9).all(|k| b[(by + k / 3) * N + bx + k % 3] != 0) {
            units += 1;
            (0..9).for_each(|k| mark[(by + k / 3) * N + bx + k % 3] = true);
        }
    }
    ((0..CELLS).filter(|&i| mark[i]).collect(), units)
}

impl BlockGrid {
    pub fn new(level: u32, mode: &str) -> Self {
        let (goal, difficulty, stones, mercy, title, seed) = if mode == "endless" {
            (None, 0.0, 0, 3, "Sonsuz", time_seed())
        } else {
            let p = params(level);
            (Some(p.goal), p.difficulty, p.stones, p.mercy, p.title, seed_for("block_grid", level, 0))
        };
        let mut g = BlockGrid {
            shapes: catalogue(),
            goal,
            title,
            difficulty,
            mercy,
            board: [0; CELLS],
            tray: [None; 3],
            rng: Rng::new(seed),
            score: 0,
            placed: 0,
            units: 0,
            streak: 0,
            dry: 0,
            best_combo: 0,
            status: Status::Playing,
            preview: None,
            ev: 0,
            et: String::new(),
            lc: vec![],
            lu: 0,
            lp: 0,
            ac: false,
        };
        g.add_stones(stones);
        g.deal();
        g
    }

    /// Scatter stones as small random shapes, never completing a unit.
    fn add_stones(&mut self, target: usize) {
        let mut count = 0;
        let mut tries = 0;
        while count < target && tries < 400 {
            tries += 1;
            let s = self.rng.below(9); // easy shapes only: natural-looking clutter
            let x = self.rng.below(N) as i32;
            let y = self.rng.below(N) as i32;
            if !self.can_place(s, x, y) {
                continue;
            }
            let mut b = self.board;
            for &(cx, cy) in &self.shapes[s].cells {
                b[(y as usize + cy) * N + x as usize + cx] = 2;
            }
            if full_units(&b).1 > 0 {
                continue;
            }
            count += self.shapes[s].cells.len();
            self.board = b;
        }
    }

    fn draw_shape(&mut self) -> usize {
        let d = self.difficulty;
        let total: f64 = self.shapes.iter().map(|s| weight(s.class, d)).sum();
        let mut r = self.rng.f64() * total;
        for (i, s) in self.shapes.iter().enumerate() {
            r -= weight(s.class, d);
            if r < 0.0 {
                return i;
            }
        }
        0
    }

    fn deal(&mut self) {
        if self.goal.is_none() {
            self.difficulty = (self.score as f64 / 4000.0).min(1.0);
            self.mercy = (3.0 - 3.0 * self.difficulty).round() as u32;
        }
        for attempt in 0..=self.mercy {
            self.tray = [Some(self.draw_shape()), Some(self.draw_shape()), Some(self.draw_shape())];
            if attempt == self.mercy || self.any_fits() {
                break;
            }
        }
    }

    fn can_place(&self, s: usize, x: i32, y: i32) -> bool {
        let sh = &self.shapes[s];
        if x < 0 || y < 0 || x as usize + sh.w > N || y as usize + sh.h > N {
            return false;
        }
        sh.cells.iter().all(|&(cx, cy)| self.board[(y as usize + cy) * N + x as usize + cx] == 0)
    }

    fn fits_anywhere(&self, s: usize) -> bool {
        (0..N as i32).any(|y| (0..N as i32).any(|x| self.can_place(s, x, y)))
    }

    fn any_fits(&self) -> bool {
        self.tray.iter().flatten().any(|&s| self.fits_anywhere(s))
    }

    fn stones_left(&self) -> u32 {
        self.board.iter().filter(|&&c| c == 2).count() as u32
    }

    /// Board after placing (without clearing) — `None` if illegal.
    fn placed_board(&self, s: usize, x: i32, y: i32) -> Option<[u8; CELLS]> {
        if !self.can_place(s, x, y) {
            return None;
        }
        let mut b = self.board;
        for &(cx, cy) in &self.shapes[s].cells {
            b[(y as usize + cy) * N + x as usize + cx] = 1;
        }
        Some(b)
    }

    fn place(&mut self, p: usize, x: i32, y: i32) -> Result<(), String> {
        let s = self.tray.get(p).copied().flatten().ok_or("Bu taş zaten kullanıldı")?;
        let sh = &self.shapes[s];
        if x < 0 || y < 0 || x as usize + sh.w > N || y as usize + sh.h > N {
            return Err("Taş tahtanın dışına taşıyor".into());
        }
        let mut b = self.placed_board(s, x, y).ok_or("Taş buraya sığmıyor")?;
        let cells = sh.cells.len() as u32;
        self.tray[p] = None;
        self.placed += 1;
        self.preview = None;
        let (clear, c) = full_units(&b);
        let mut pts = cells;
        if c > 0 {
            self.streak += 1;
            self.dry = 0;
            pts += 18 * c * c + 12 * (self.streak - 1) * c;
            for &i in &clear {
                b[i] = 0;
            }
            self.units += c;
            self.best_combo = self.best_combo.max(c);
            let mut parts = vec![];
            self.ac = false;
            if c > 1 {
                parts.push(format!("Kombo ×{c}"));
            }
            if self.streak > 1 {
                parts.push(format!("Seri {}", self.streak));
            }
            if b.iter().all(|&v| v == 0) {
                pts += 300;
                self.ac = true;
                parts.push("Tertemiz!".into());
            }
            if parts.is_empty() {
                parts.push(format!("+{}", pts - cells));
            }
            self.ev += 1;
            self.et = parts.join(" · ");
            self.lc = clear;
            self.lu = c;
            self.lp = pts;
        } else {
            self.dry += 1;
            if self.dry >= 3 {
                self.streak = 0;
            }
        }
        self.board = b;
        self.score += pts;
        if self.tray.iter().all(|t| t.is_none()) {
            self.deal();
        }
        self.update_status();
        Ok(())
    }

    fn update_status(&mut self) {
        let (done, max) = match self.goal {
            None => (false, 0),
            Some(Goal::Score { target, max }) => (self.score >= target, max),
            Some(Goal::Clear { units, max }) => (self.units >= units, max),
            Some(Goal::Cleanup { max }) => (self.stones_left() == 0, max),
            Some(Goal::Endure { pieces }) => (self.placed >= pieces, 0),
        };
        if done {
            self.status = Status::Won;
        } else if (max > 0 && self.placed >= max) || !self.any_fits() {
            self.status = Status::Lost;
        }
    }

    fn stars(&self) -> u32 {
        if self.status != Status::Won {
            return 0;
        }
        let used = self.placed as f64;
        let (three, two) = match self.goal {
            Some(Goal::Score { max, .. }) | Some(Goal::Clear { max, .. }) | Some(Goal::Cleanup { max }) => {
                let m = max as f64;
                (used <= m * 0.7, used <= m * 0.85)
            }
            Some(Goal::Endure { pieces }) => {
                let s = self.score as f64 / pieces as f64;
                (s >= 24.0, s >= 15.0)
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
            None => "Yerleştirebildiğin sürece devam · en yüksek puan".into(),
            Some(Goal::Score { target, max }) => format!("{target} puan yap · {max} taş içinde"),
            Some(Goal::Clear { units, max }) => format!("{units} satır/sütun/kare temizle · {max} taş içinde"),
            Some(Goal::Cleanup { max }) => format!("Bütün taş blokları kır · {max} taş içinde"),
            Some(Goal::Endure { pieces }) => format!("{pieces} taşı sıkışmadan yerleştir"),
        }
    }

    fn hud(&self) -> Value {
        match self.goal {
            None => json!([["Puan", self.score], ["Taş", self.placed], ["Seri", self.streak]]),
            Some(Goal::Score { target, max }) => {
                json!([["Puan", format!("{}/{}", self.score, target)], ["Taş", format!("{}/{}", self.placed, max)], ["Seri", self.streak]])
            }
            Some(Goal::Clear { units, max }) => json!([
                ["Temizlenen", format!("{}/{}", self.units.min(units), units)],
                ["Taş", format!("{}/{}", self.placed, max)],
                ["Puan", self.score]
            ]),
            Some(Goal::Cleanup { max }) => {
                json!([["Kalan blok", self.stones_left()], ["Taş", format!("{}/{}", self.placed, max)], ["Puan", self.score]])
            }
            Some(Goal::Endure { pieces }) => {
                json!([["Taş", format!("{}/{}", self.placed, pieces)], ["Puan", self.score], ["Seri", self.streak]])
            }
        }
    }

    fn preview_json(&self) -> Value {
        let Some((p, x, y)) = self.preview else { return Value::Null };
        let Some(s) = self.tray[p] else { return Value::Null };
        let sh = &self.shapes[s];
        let cells: Vec<i32> = sh
            .cells
            .iter()
            .map(|&(cx, cy)| (y + cy as i32) * N as i32 + x + cx as i32)
            .filter(|&i| i >= 0 && (i as usize) < CELLS)
            .collect();
        match self.placed_board(s, x, y) {
            Some(b) => {
                let (cl, _) = full_units(&b);
                json!({"p": p, "x": x, "y": y, "ok": true, "c": cells, "cl": cl})
            }
            None => json!({"p": p, "x": x, "y": y, "ok": false, "c": cells, "cl": []}),
        }
    }
}

impl Session for BlockGrid {
    fn state(&self) -> Value {
        let status = match self.status {
            Status::Playing => "playing",
            Status::Won => "won",
            Status::Lost => "lost",
        };
        let b: String = self.board.iter().map(|&c| (b'0' + c) as char).collect();
        let tray: Vec<Value> = self
            .tray
            .iter()
            .map(|t| match t {
                None => Value::Null,
                Some(s) => {
                    let sh = &self.shapes[*s];
                    let c: Vec<usize> = sh.cells.iter().flat_map(|&(x, y)| [x, y]).collect();
                    json!({"s": s, "c": c, "w": sh.w, "h": sh.h, "f": self.fits_anywhere(*s)})
                }
            })
            .collect();
        let mut v = json!({
            "status": status,
            "stars": self.stars(),
            "title": self.title,
            "goal": self.goal_text(),
            "score": self.score,
            "b": b,
            "tray": tray,
            "pv": self.preview_json(),
            "ev": self.ev,
            "et": self.et,
            "lc": self.lc,
            "lu": self.lu,
            "lp": self.lp,
            "ac": self.ac,
            "streak": self.streak,
            "hud": self.hud(),
        });
        if self.status != Status::Playing {
            v["summary"] = json!(format!(
                "Taş: {} · Temizlenen: {} · En büyük kombo: ×{}",
                self.placed, self.units, self.best_combo
            ));
        }
        v
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if self.status != Status::Playing {
            return Err("Oyun bitti".into());
        }
        let cmd = a["a"].as_str().ok_or("Hamle eksik")?;
        let p = a["p"].as_u64().map(|v| v as usize);
        let x = a["x"].as_i64().map(|v| v as i32);
        let y = a["y"].as_i64().map(|v| v as i32);
        match (cmd, p, x, y) {
            ("pv", Some(p), Some(x), Some(y)) => {
                if p >= 3 || self.tray[p].is_none() {
                    return Err("Bu taş zaten kullanıldı".into());
                }
                self.preview = Some((p, x, y));
                Ok(())
            }
            ("pv", ..) => {
                self.preview = None;
                Ok(())
            }
            ("place", Some(p), Some(x), Some(y)) => {
                if p >= 3 {
                    return Err("Geçersiz taş".into());
                }
                self.place(p, x, y)
            }
            _ => Err("Bilinmeyen hamle".into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LEVELS: [u32; 9] = [1, 2, 3, 50, 137, 250, 400, 499, 500];

    /// Board quality: penalise isolated holes and ragged edges, reward open 3×3 space.
    fn quality(b: &[u8; CELLS]) -> f64 {
        let mut edges = 0;
        let mut lonely = 0;
        for y in 0..N {
            for x in 0..N {
                let empty = b[y * N + x] == 0;
                let mut empty_nb = 0;
                for (dx, dy) in [(1i32, 0i32), (-1, 0), (0, 1), (0, -1)] {
                    let (nx, ny) = (x as i32 + dx, y as i32 + dy);
                    let other = if nx < 0 || ny < 0 || nx >= N as i32 || ny >= N as i32 {
                        false
                    } else {
                        b[ny as usize * N + nx as usize] == 0
                    };
                    if empty != other {
                        edges += 1;
                    }
                    if other {
                        empty_nb += 1;
                    }
                }
                if empty && empty_nb == 0 {
                    lonely += 1;
                }
            }
        }
        let mut open3 = 0;
        for y in 0..=N - 3 {
            for x in 0..=N - 3 {
                if (0..9).all(|k| b[(y + k / 3) * N + x + k % 3] == 0) {
                    open3 += 1;
                }
            }
        }
        -0.35 * edges as f64 - 4.0 * lonely as f64 + 0.6 * open3 as f64
    }

    fn moves(g: &BlockGrid) -> Vec<(usize, i32, i32)> {
        let mut v = vec![];
        for p in 0..3 {
            let Some(s) = g.tray[p] else { continue };
            for y in 0..N as i32 {
                for x in 0..N as i32 {
                    if g.can_place(s, x, y) {
                        v.push((p, x, y));
                    }
                }
            }
        }
        v
    }

    fn value(g: &BlockGrid, base_score: u32) -> f64 {
        let stones = g.stones_left() as f64;
        let lost = if g.status == Status::Lost { -1000.0 } else { 0.0 };
        (g.score - base_score) as f64 + quality(&g.board) - 6.0 * stones + lost
    }

    /// Two-ply greedy: best placement assuming the best follow-up with another tray piece.
    fn best_move(g: &BlockGrid) -> Option<(usize, i32, i32)> {
        let mut best: Option<(f64, (usize, i32, i32))> = None;
        for m in moves(g) {
            let mut a = g.clone();
            a.goal = None;
            a.place(m.0, m.1, m.2).unwrap();
            let mut v = value(&a, g.score);
            if a.tray.iter().flatten().count() > 0 && a.tray.iter().flatten().count() < 3 {
                let mut bv = f64::MIN;
                for m2 in moves(&a) {
                    let mut b = a.clone();
                    b.place(m2.0, m2.1, m2.2).unwrap();
                    bv = bv.max(value(&b, g.score));
                }
                v = if bv == f64::MIN { v - 1000.0 } else { bv };
            }
            if best.as_ref().is_none_or(|(bv, _)| v > *bv) {
                best = Some((v, m));
            }
        }
        best.map(|b| b.1)
    }

    fn bot_play(g: &mut BlockGrid, max: u32) {
        while g.status == Status::Playing && g.placed < max {
            let (p, x, y) = best_move(g).expect("a legal move exists while playing");
            g.act(&json!({"a": "place", "p": p, "x": x, "y": y})).unwrap();
        }
    }

    #[test]
    fn block_grid_levels_generate_and_are_deterministic() {
        for level in LEVELS {
            let a = BlockGrid::new(level, "level");
            let b = BlockGrid::new(level, "level");
            assert_eq!(a.board, b.board);
            assert_eq!(a.tray, b.tray);
            assert_eq!(a.status, Status::Playing);
            assert_eq!(full_units(&a.board).1, 0);
            let p = params(level);
            if let Goal::Cleanup { .. } = p.goal {
                assert!(a.stones_left() as usize >= p.stones.min(10), "level {level}");
            }
            assert_eq!(a.state()["b"].as_str().unwrap().len(), CELLS);
        }
        assert_eq!(catalogue().len(), 29);
    }

    #[test]
    fn block_grid_clears_rows_columns_and_boxes() {
        let mut g = BlockGrid::new(1, "endless");
        g.board = [0; CELLS];
        // Row 0 except x=8, column 8 except y=0 → placing a mono at (8,0) clears both.
        for i in 0..8 {
            g.board[i] = 1;
            g.board[(i + 1) * N + 8] = 1;
        }
        g.tray = [Some(0), Some(0), Some(0)];
        let before = g.score;
        g.act(&json!({"a": "pv", "p": 0, "x": 8, "y": 0})).unwrap();
        let pv = g.state()["pv"].clone();
        assert_eq!(pv["ok"], true);
        assert_eq!(pv["cl"].as_array().unwrap().len(), 17);
        g.act(&json!({"a": "place", "p": 0, "x": 8, "y": 0})).unwrap();
        assert!(g.board.iter().all(|&c| c == 0));
        assert_eq!(g.units, 2);
        // 1 cell + 18·4 combo + 300 all-clear
        assert_eq!(g.score - before, 1 + 72 + 300);
        // A 3×3 box.
        for k in 0..8 {
            g.board[(3 + k / 3) * N + 3 + k % 3] = 1;
        }
        g.act(&json!({"a": "place", "p": 1, "x": 5, "y": 5})).unwrap();
        assert_eq!(g.units, 3);
        assert_eq!(g.streak, 2);
    }

    #[test]
    fn block_grid_reports_last_clear_for_the_ui() {
        let mut g = BlockGrid::new(1, "endless");
        g.board = [0; CELLS];
        g.tray = [Some(0), Some(0), Some(0)];
        // Row 0 except x=8 and column 8 except y=0, plus a stray cell so the board is not emptied.
        for i in 0..8 {
            g.board[i] = 1;
            g.board[(i + 1) * N + 8] = 1;
        }
        g.board[4 * N + 2] = 1;
        let st = g.state();
        assert_eq!((st["ev"].as_u64(), st["lu"].as_u64(), st["lp"].as_u64()), (Some(0), Some(0), Some(0)));
        let before = g.score;
        g.act(&json!({"a": "place", "p": 0, "x": 8, "y": 0})).unwrap();
        let st = g.state();
        assert_eq!(st["ev"], 1);
        assert_eq!(st["lu"], 2);
        assert_eq!(st["ac"], false);
        assert_eq!(st["lp"].as_u64().unwrap() as u32, g.score - before);
        assert_eq!(st["lc"].as_array().unwrap().len(), 17);
        // A non-clearing placement keeps the last clear's numbers (same event serial).
        g.act(&json!({"a": "place", "p": 1, "x": 0, "y": 8})).unwrap();
        let st2 = g.state();
        assert_eq!(st2["ev"], 1);
        assert_eq!(st2["lu"], 2);
        // Emptying the board is flagged.
        g.board = [0; CELLS];
        for x in 0..8 {
            g.board[8 * N + x] = 1;
        }
        g.board[8 * N] = 1;
        g.act(&json!({"a": "place", "p": 2, "x": 8, "y": 8})).unwrap();
        let st3 = g.state();
        assert_eq!(st3["ev"], 2);
        assert_eq!(st3["lu"], 1);
        assert_eq!(st3["ac"], true);
    }

    #[test]
    fn block_grid_illegal_actions_rejected() {
        let mut g = BlockGrid::new(3, "level");
        let s = g.tray[0].unwrap();
        // Find an occupied spot for an overlap test.
        let before = g.state();
        assert!(g.act(&json!({"a": "place", "p": 0, "x": 9, "y": 0})).is_err());
        assert!(g.act(&json!({"a": "place", "p": 5, "x": 0, "y": 0})).is_err());
        assert!(g.act(&json!({"a": "fly"})).is_err());
        if let Some(i) = g.board.iter().position(|&c| c != 0) {
            let (x, y) = ((i % N) as i32, (i / N) as i32);
            let (cx, cy) = g.shapes[s].cells[0];
            let r = g.act(&json!({"a": "place", "p": 0, "x": x - cx as i32, "y": y - cy as i32}));
            assert!(r.is_err());
        }
        assert_eq!(g.state(), before);
        let (p, x, y) = best_move(&g).unwrap();
        g.act(&json!({"a": "place", "p": p, "x": x, "y": y})).unwrap();
        assert!(g.act(&json!({"a": "place", "p": p, "x": x, "y": y})).is_err());
    }

    #[test]
    fn block_grid_bot_wins_early_levels() {
        let mut stars = vec![];
        for level in 1..=8 {
            let mut g = BlockGrid::new(level, "level");
            bot_play(&mut g, 500);
            assert_eq!(g.status, Status::Won, "level {level}: {}", g.state()["summary"]);
            stars.push(g.stars());
        }
        assert!(stars.iter().filter(|&&s| s == 3).count() >= 3, "{stars:?}");
    }

    #[test]
    fn block_grid_endless_reaches_lost() {
        let mut g = BlockGrid::new(1, "endless");
        // Dumb play: always the first legal spot scanning from the top-left.
        let mut guard = 0;
        while g.status == Status::Playing {
            let mut done = false;
            'outer: for p in 0..3 {
                let Some(s) = g.tray[p] else { continue };
                for y in 0..N as i32 {
                    for x in 0..N as i32 {
                        if g.can_place(s, x, y) {
                            g.act(&json!({"a": "place", "p": p, "x": x, "y": y})).unwrap();
                            done = true;
                            break 'outer;
                        }
                    }
                }
            }
            assert!(done);
            guard += 1;
            assert!(guard < 2000);
        }
        assert_eq!(g.status, Status::Lost);
        assert!(g.state()["summary"].is_string());
    }

    #[test]
    #[ignore]
    fn block_grid_calibrate() {
        for kind in 0..4u32 {
            for band in [0u32, 30, 60, 90, 120] {
                let mut wins = 0;
                let mut st = [0; 4];
                let mut used = 0;
                let n = 8;
                for k in 0..n {
                    let level = 1 + kind + 4 * (band + k).min(124);
                    let mut g = BlockGrid::new(level, "level");
                    bot_play(&mut g, 500);
                    if g.status == Status::Won {
                        wins += 1;
                    }
                    used += g.placed;
                    st[g.stars() as usize] += 1;
                }
                println!("kind {kind} tier {band:>3}: {:?} wins {wins}/{n} stars0..3 {st:?} avg pieces {}", params(1 + kind + 4 * band).goal, used / n);
            }
        }
    }

    #[test]
    #[ignore]
    fn block_grid_timing() {
        let t = std::time::Instant::now();
        for level in 1..=500 {
            let g = BlockGrid::new(level, "level");
            assert_eq!(g.status, Status::Playing);
        }
        println!("block_grid: 500 levels generated in {:?}", t.elapsed());
        let mut g = BlockGrid::new(250, "level");
        let t = std::time::Instant::now();
        for i in 0..1000 {
            g.act(&json!({"a": "pv", "p": 0, "x": i % 7, "y": i % 5})).ok();
            let _ = g.state().to_string();
        }
        println!("block_grid: 1000 preview+state in {:?}", t.elapsed());
    }
}
