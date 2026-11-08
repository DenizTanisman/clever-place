//! Towers of Hanoi on three pegs with three variants. Exact optimal move counts come from a BFS over
//! every legal configuration (≤ 3^8 states), so stars and hints are always correct — including random
//! starts and the "adjacent pegs only" rule. The solver itself is peg-count generic (≤ 4 pegs).
//!
//! State: `{status, stars, variant, title, goal, pegs: [[size bottom→top]], disks, target, moves,
//!          optimal, adjacent_only, hint: [from,to] | null, can_undo}`
//! Actions: `{"from":a,"to":b}` · `{"undo":true}` · `{"hint":true}`

use crate::rng::{seed_for, Rng};
use crate::Session;
use serde_json::{json, Value};
use std::collections::VecDeque;

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Variant {
    Classic,
    RandomStart,
    Adjacent,
}

impl Variant {
    fn title(self) -> &'static str {
        match self {
            Variant::Classic => "Klasik",
            Variant::RandomStart => "Dağınık başlangıç",
            Variant::Adjacent => "Sadece komşu direk",
        }
    }
    fn key(self) -> &'static str {
        match self {
            Variant::Classic => "classic",
            Variant::RandomStart => "random",
            Variant::Adjacent => "adjacent",
        }
    }
}

/// Every level is played on three pegs.
pub const PEGS: usize = 3;

/// Level → (variant, pegs, disks). Variants rotate every level; each variant's disk count grows in
/// even bands across 1..=500: classic 3→8 (7→255 moves), random start 4→8, adjacent-only 2→5
/// (8→242 moves).
pub fn params(level: u32) -> (Variant, usize, usize) {
    let t = (level.clamp(1, 500) - 1) as usize; // 0..=499
    match t % 3 {
        0 => (Variant::Classic, PEGS, 3 + t * 6 / 500),
        1 => (Variant::RandomStart, PEGS, 4 + t * 5 / 500),
        _ => (Variant::Adjacent, PEGS, 2 + t * 4 / 500),
    }
}

/// Configuration encoded as base-`pegs` number: digit d = peg of disk d (disk 0 = smallest).
fn encode(pos: &[u8], pegs: usize) -> usize {
    pos.iter().rev().fold(0usize, |acc, &p| acc * pegs + p as usize)
}

#[allow(dead_code)]
fn decode(mut code: usize, pegs: usize, disks: usize) -> Vec<u8> {
    let mut v = vec![0u8; disks];
    for d in v.iter_mut() {
        *d = (code % pegs) as u8;
        code /= pegs;
    }
    v
}

fn legal(from: usize, to: usize, adjacent: bool) -> bool {
    from != to && (!adjacent || from.abs_diff(to) == 1)
}

/// Distance-to-goal for every configuration (reverse BFS from "all disks on target").
fn distance_table(pegs: usize, disks: usize, target: u8, adjacent: bool) -> Vec<u32> {
    let n = pegs.pow(disks as u32);
    let mut dist = vec![u32::MAX; n];
    let goal = encode(&vec![target; disks], pegs);
    dist[goal] = 0;
    let mut q = VecDeque::from([goal]);
    let mut pos = vec![0u8; disks];
    while let Some(code) = q.pop_front() {
        let mut c = code;
        for d in pos.iter_mut() {
            *d = (c % pegs) as u8;
            c /= pegs;
        }
        // Top disk of each peg = smallest disk on it.
        let mut top = [usize::MAX; 4];
        for (disk, &p) in pos.iter().enumerate() {
            if top[p as usize] == usize::MAX {
                top[p as usize] = disk;
            }
        }
        for from in 0..pegs {
            let disk = top[from];
            if disk == usize::MAX {
                continue;
            }
            for to in 0..pegs {
                if !legal(from, to, adjacent) || (top[to] != usize::MAX && top[to] < disk) {
                    continue;
                }
                let next = code - from * pegs.pow(disk as u32) + to * pegs.pow(disk as u32);
                if dist[next] == u32::MAX {
                    dist[next] = dist[code] + 1;
                    q.push_back(next);
                }
            }
        }
    }
    dist
}

pub struct Hanoi {
    variant: Variant,
    pegs: usize,
    disks: usize,
    target: u8,
    adjacent: bool,
    pos: Vec<u8>,
    history: Vec<Vec<u8>>,
    moves: u32,
    optimal: u32,
    dist: Vec<u32>,
    hint: Option<(usize, usize)>,
}

impl Hanoi {
    pub fn new(level: u32) -> Self {
        let (variant, pegs, disks) = params(level);
        let mut rng = Rng::new(seed_for("hanoi", level, 0));
        let adjacent = variant == Variant::Adjacent;
        let target = (pegs - 1) as u8;
        let dist = distance_table(pegs, disks, target, adjacent);
        let random = variant == Variant::RandomStart;
        let pos = if random {
            // Random legal start that is far enough from the goal to be interesting.
            let min_d = (pegs.pow(disks as u32 / 2) as u32).max(6);
            let mut best = vec![0u8; disks];
            for _ in 0..200 {
                let cand: Vec<u8> = (0..disks).map(|_| rng.below(pegs) as u8).collect();
                let d = dist[encode(&cand, pegs)];
                if d >= min_d {
                    best = cand;
                    break;
                }
                if d > dist[encode(&best, pegs)] {
                    best = cand;
                }
            }
            best
        } else {
            vec![0u8; disks]
        };
        let optimal = dist[encode(&pos, pegs)];
        Hanoi { variant, pegs, disks, target, adjacent, pos, history: vec![], moves: 0, optimal, dist, hint: None }
    }

    fn peg_lists(&self) -> Vec<Vec<usize>> {
        let mut pegs = vec![vec![]; self.pegs];
        // Bottom → top = largest → smallest. Sizes are 1-based for display.
        for disk in (0..self.disks).rev() {
            pegs[self.pos[disk] as usize].push(disk + 1);
        }
        pegs
    }

    fn top(&self, peg: usize) -> Option<usize> {
        (0..self.disks).find(|&d| self.pos[d] as usize == peg)
    }

    fn solved(&self) -> bool {
        self.pos.iter().all(|&p| p == self.target)
    }

    fn stars(&self) -> u32 {
        if !self.solved() {
            0
        } else if self.moves <= self.optimal {
            3
        } else if (self.moves as f64) <= self.optimal as f64 * 1.5 {
            2
        } else {
            1
        }
    }

    fn best_move(&self) -> Option<(usize, usize)> {
        let here = self.dist[encode(&self.pos, self.pegs)];
        if here == 0 || here == u32::MAX {
            return None;
        }
        for from in 0..self.pegs {
            let Some(disk) = self.top(from) else { continue };
            for to in 0..self.pegs {
                if !legal(from, to, self.adjacent) {
                    continue;
                }
                if let Some(t) = self.top(to) {
                    if t < disk {
                        continue;
                    }
                }
                let mut next = self.pos.clone();
                next[disk] = to as u8;
                if self.dist[encode(&next, self.pegs)] + 1 == here {
                    return Some((from, to));
                }
            }
        }
        None
    }
}

impl Session for Hanoi {
    fn state(&self) -> Value {
        let status = if self.solved() { "won" } else { "playing" };
        json!({
            "status": status,
            "stars": self.stars(),
            "variant": self.variant.key(),
            "title": self.variant.title(),
            "goal": format!("Bütün diskleri {}. direğe taşı. En az hamle: {}", self.target + 1, self.optimal),
            "pegs": self.peg_lists(),
            "disks": self.disks,
            "target": self.target,
            "moves": self.moves,
            "optimal": self.optimal,
            "remaining_optimal": self.dist[encode(&self.pos, self.pegs)],
            "adjacent_only": self.adjacent,
            "hint": self.hint.map(|(a, b)| json!([a, b])),
            "can_undo": !self.history.is_empty(),
        })
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if a["undo"].as_bool() == Some(true) {
            let prev = self.history.pop().ok_or("Geri alınacak hamle yok")?;
            self.pos = prev;
            self.moves += 1; // undo still costs a move: stars reward clean play
            self.hint = None;
            return Ok(());
        }
        if a["hint"].as_bool() == Some(true) {
            self.hint = self.best_move();
            return Ok(());
        }
        if self.solved() {
            return Err("Bölüm bitti".into());
        }
        let from = a["from"].as_u64().ok_or("from eksik")? as usize;
        let to = a["to"].as_u64().ok_or("to eksik")? as usize;
        if from >= self.pegs || to >= self.pegs {
            return Err("Geçersiz direk".into());
        }
        if !legal(from, to, self.adjacent) {
            return Err(if self.adjacent { "Sadece komşu direğe taşıyabilirsin" } else { "Aynı direk" }.into());
        }
        let disk = self.top(from).ok_or("Bu direk boş")?;
        if let Some(t) = self.top(to) {
            if t < disk {
                return Err("Büyük disk küçüğün üstüne konamaz".into());
            }
        }
        self.history.push(self.pos.clone());
        self.pos[disk] = to as u8;
        self.moves += 1;
        self.hint = None;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classic_optimal_is_2n_minus_1() {
        for n in 3..=8 {
            let d = distance_table(3, n, 2, false);
            assert_eq!(d[0], (1u32 << n) - 1);
        }
    }

    #[test]
    fn adjacent_optimal_is_3n_minus_1() {
        for n in 2..=5 {
            let d = distance_table(3, n, 2, true);
            assert_eq!(d[0], 3u32.pow(n as u32) - 1);
        }
    }

    #[test]
    fn every_level_uses_three_pegs_and_stays_phone_sized() {
        let mut prev = [0usize; 3];
        for level in 1..=500 {
            let (variant, pegs, disks) = params(level);
            assert_eq!(pegs, 3, "level {level}");
            let g = Hanoi::new(level);
            assert_eq!(g.state()["pegs"].as_array().unwrap().len(), 3, "level {level}");
            let (slot, lo, hi) = match variant {
                Variant::Classic => (0, 3, 8),
                Variant::RandomStart => (1, 4, 8),
                Variant::Adjacent => (2, 2, 5),
            };
            assert!((lo..=hi).contains(&disks), "level {level}: {disks} disks");
            assert!(disks >= prev[slot], "difficulty must not drop at level {level}");
            prev[slot] = disks;
        }
        assert_eq!(params(1), (Variant::Classic, 3, 3));
        assert_eq!(params(498), (Variant::Adjacent, 3, 5));
        assert_eq!(params(499), (Variant::Classic, 3, 8));
        assert_eq!(params(500), (Variant::RandomStart, 3, 8));
    }

    #[test]
    fn reve_puzzle_known_values() {
        // Solver stays peg-generic. Frame–Stewart numbers for 4 pegs: 1,3,5,9,13,17,25,33
        let expect = [1, 3, 5, 9, 13, 17, 25, 33];
        for (i, &e) in expect.iter().enumerate() {
            let d = distance_table(4, i + 1, 3, false);
            assert_eq!(d[0], e, "n={}", i + 1);
        }
    }

    #[test]
    fn every_level_generates_and_hint_solves() {
        for level in [1, 2, 3, 4, 5, 6, 77, 250, 497, 498, 499, 500] {
            let mut g = Hanoi::new(level);
            assert!(g.optimal > 0);
            let mut guard = 0;
            while !g.solved() {
                let (a, b) = g.best_move().expect("hint");
                g.act(&json!({"from": a, "to": b})).unwrap();
                guard += 1;
                assert!(guard < 5000);
            }
            assert_eq!(g.moves, g.optimal);
            assert_eq!(g.stars(), 3);
        }
    }

    #[test]
    fn illegal_moves_rejected() {
        let mut g = Hanoi::new(1);
        assert!(g.act(&json!({"from": 1, "to": 2})).is_err()); // empty peg
        g.act(&json!({"from": 0, "to": 1})).unwrap();
        assert!(g.act(&json!({"from": 0, "to": 1})).is_err()); // big on small
    }
}
