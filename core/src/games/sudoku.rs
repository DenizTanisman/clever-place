//! Classic 9×9 Sudoku with technique-graded levels.
//!
//! Generation: a random full grid (randomized bitmask backtracking) → clues are removed in
//! rotationally symmetric pairs, then single cells, while the solution stays unique (minimal
//! puzzles, ~24 clues). The puzzle is graded by a human-technique logic solver that always applies
//! the easiest technique available; its hardest required technique decides the tier:
//!
//! | rank  | technique                                                  | tier  |
//! |-------|------------------------------------------------------------|-------|
//! | 0–1   | hidden single, naked single                                | Kolay |
//! | 2–4   | locked candidates (pointing/claiming), naked/hidden pairs  | Orta  |
//! | 5–9   | naked/hidden triples, X-Wing, Skyscraper/Kite, XY-Wing     | Zor   |
//! | 10–14 | Swordfish, XYZ-Wing, quads, X-Chain, XY-Chain               | Uzman |
//! | 15    | contradiction forcing chain (Nishio)                       | Usta  |
//!
//! Level curve (`params`) — each level asks for a window of hardest-technique ranks:
//! - L1: locked candidates; L2: naked/hidden pairs.
//! - 3–60: Orta (every 3rd level must need a pair).
//! - 61–150: pairs, every 3rd level Zor.
//! - 151–250: Zor, every 4th level Uzman.
//! - 251–400: Zor/Uzman mix, every 5th level Usta.
//! - 401–500: Uzman, every 3rd level Usta.
//!
//! Each level tries up to `ATTEMPTS` deterministic seeds (≈0.5 ms each on an M-series Mac) and
//! keeps the first puzzle inside the window, else the closest easier one; if every attempt was too
//! hard, one is "softened" (stuck points get an extra clue). Every shipped puzzle is unique and
//! solvable by the logic solver, so hints can always name a technique.
//!
//! State: `{status, stars, title, goal, summary, values[81], fixed[81] (0 free · 1 given · 2 hint),
//!          notes[81] (bit d = pencil mark d), wrong[cells], conflicts[cells], remaining[9],
//!          mistakes, hints, elapsed (s), can_undo, clues, technique, hint: {cell, digit, technique,
//!          text, focus[cells]} | null}`
//! Actions: `{"set":cell,"digit":d}` · `{"erase":cell}` · `{"note":cell,"digit":d}` ·
//!          `{"fill_notes":true}` · `{"hint":true}` · `{"undo":true}`
//! Stars: 3 = no mistakes and no hints · 2 = ≤ 2 mistakes and ≤ 1 hint · otherwise 1.

use crate::rng::{seed_for, Rng};
use crate::Session;
use serde_json::{json, Value};
use std::sync::OnceLock;

// ───────────────────────────── geometry ─────────────────────────────

struct Geo {
    /// 0..9 rows, 9..18 columns, 18..27 boxes.
    units: [[usize; 9]; 27],
    peers: [[usize; 20]; 81],
}

fn geo() -> &'static Geo {
    static G: OnceLock<Geo> = OnceLock::new();
    G.get_or_init(|| {
        let mut units = [[0usize; 9]; 27];
        for i in 0..9 {
            for j in 0..9 {
                units[i][j] = i * 9 + j;
                units[9 + i][j] = j * 9 + i;
                units[18 + i][j] = (i / 3) * 27 + (i % 3) * 3 + (j / 3) * 9 + j % 3;
            }
        }
        let mut peers = [[0usize; 20]; 81];
        for (c, p) in peers.iter_mut().enumerate() {
            let mut k = 0;
            for o in 0..81 {
                if sees(c, o) {
                    p[k] = o;
                    k += 1;
                }
            }
        }
        Geo { units, peers }
    })
}

fn row(c: usize) -> usize {
    c / 9
}
fn col(c: usize) -> usize {
    c % 9
}
fn boxi(c: usize) -> usize {
    (c / 27) * 3 + (c % 9) / 3
}
fn sees(a: usize, b: usize) -> bool {
    a != b && (row(a) == row(b) || col(a) == col(b) || boxi(a) == boxi(b))
}

const ALL: u16 = 0x3FE; // bits 1..=9
const FULL: u128 = (1u128 << 81) - 1;

fn digits(m: u16) -> impl Iterator<Item = u8> {
    (1..=9u8).filter(move |d| m & (1 << d) != 0)
}

fn cell_name(c: usize) -> String {
    format!("({},{})", row(c) + 1, col(c) + 1)
}

fn unit_loc(u: usize) -> String {
    match u / 9 {
        0 => format!("{}. satırda", u % 9 + 1),
        1 => format!("{}. sütunda", u % 9 + 1),
        _ => format!("{}. kutuda", u % 9 + 1),
    }
}

fn list_cells(cells: &[usize]) -> String {
    cells.iter().map(|&c| cell_name(c)).collect::<Vec<_>>().join(" ")
}

fn list_digits(m: u16) -> String {
    digits(m).map(|d| d.to_string()).collect::<Vec<_>>().join("/")
}

/// Calls `f` with every k-combination of `0..n` (ascending). Stops early when `f` returns true.
fn combos(n: usize, k: usize, f: &mut dyn FnMut(&[usize]) -> bool) -> bool {
    if k == 0 || k > n {
        return false;
    }
    let mut idx: Vec<usize> = (0..k).collect();
    loop {
        if f(&idx) {
            return true;
        }
        let mut i = k;
        while i > 0 && idx[i - 1] == n - k + i - 1 {
            i -= 1;
        }
        if i == 0 {
            return false;
        }
        idx[i - 1] += 1;
        for j in i..k {
            idx[j] = idx[j - 1] + 1;
        }
    }
}

// ───────────────────────────── fast solver ─────────────────────────────

/// Candidate bitmasks with naked/hidden single propagation; used for generation and uniqueness.
#[derive(Clone, Copy)]
struct Bits {
    cand: [u16; 81],
    done: u128,
}

impl Bits {
    fn new() -> Self {
        Bits { cand: [ALL; 81], done: 0 }
    }

    fn from_grid(g: &[u8; 81]) -> Option<Self> {
        let mut b = Bits::new();
        for c in 0..81 {
            if g[c] != 0 && !b.assign(c, g[c]) {
                return None;
            }
        }
        Some(b)
    }

    fn assign(&mut self, cell: usize, d: u8) -> bool {
        let geo = geo();
        let mut stack = [(0usize, 0u8); 96];
        stack[0] = (cell, d);
        let mut sp = 1;
        while sp > 0 {
            sp -= 1;
            let (c, d) = stack[sp];
            let bit = 1u16 << d;
            if self.done >> c & 1 == 1 {
                if self.cand[c] != bit {
                    return false;
                }
                continue;
            }
            if self.cand[c] & bit == 0 {
                return false;
            }
            self.cand[c] = bit;
            self.done |= 1 << c;
            for &p in &geo.peers[c] {
                if self.cand[p] & bit != 0 {
                    if self.done >> p & 1 == 1 {
                        return false;
                    }
                    self.cand[p] &= !bit;
                    let m = self.cand[p];
                    if m == 0 {
                        return false;
                    }
                    if m.is_power_of_two() {
                        stack[sp] = (p, m.trailing_zeros() as u8);
                        sp += 1;
                    }
                }
            }
        }
        true
    }

    /// `None` = contradiction, `Some(progress)`.
    fn hidden_singles(&mut self) -> Option<bool> {
        let geo = geo();
        let mut progress = false;
        for u in &geo.units {
            let (mut once, mut twice, mut placed) = (0u16, 0u16, 0u16);
            for &c in u {
                let m = self.cand[c];
                if self.done >> c & 1 == 1 {
                    placed |= m;
                } else {
                    twice |= once & m;
                    once |= m;
                }
            }
            if (once | placed) != ALL {
                return None;
            }
            let singles = once & !twice & !placed;
            if singles != 0 {
                for d in digits(singles) {
                    let bit = 1u16 << d;
                    let c = *u.iter().find(|&&c| self.cand[c] & bit != 0 && self.done >> c & 1 == 0)?;
                    if !self.assign(c, d) {
                        return None;
                    }
                    progress = true;
                }
            }
        }
        Some(progress)
    }
}

fn search(mut b: Bits, limit: usize, count: &mut usize, sol: &mut Option<[u8; 81]>, rng: &mut Option<&mut Rng>) {
    loop {
        match b.hidden_singles() {
            None => return,
            Some(true) => continue,
            Some(false) => break,
        }
    }
    if b.done == FULL {
        *count += 1;
        if sol.is_none() {
            let mut g = [0u8; 81];
            for c in 0..81 {
                g[c] = b.cand[c].trailing_zeros() as u8;
            }
            *sol = Some(g);
        }
        return;
    }
    let mut best = 0;
    let mut best_n = 10;
    for c in 0..81 {
        if b.done >> c & 1 == 0 {
            let n = b.cand[c].count_ones();
            if n < best_n {
                best_n = n;
                best = c;
                if n == 2 {
                    break;
                }
            }
        }
    }
    let mut ds: Vec<u8> = digits(b.cand[best]).collect();
    if let Some(r) = rng.as_deref_mut() {
        r.shuffle(&mut ds);
    }
    for d in ds {
        let mut nb = b;
        if nb.assign(best, d) {
            search(nb, limit, count, sol, rng);
            if *count >= limit {
                return;
            }
        }
    }
}

/// Number of solutions, capped at `limit`, plus the first one found (used to verify uniqueness).
#[cfg(test)]
fn count_solutions(g: &[u8; 81], limit: usize) -> (usize, Option<[u8; 81]>) {
    let Some(b) = Bits::from_grid(g) else { return (0, None) };
    let mut count = 0;
    let mut sol = None;
    search(b, limit, &mut count, &mut sol, &mut None);
    (count, sol)
}

fn random_full(rng: &mut Rng) -> [u8; 81] {
    let mut count = 0;
    let mut sol = None;
    search(Bits::new(), 1, &mut count, &mut sol, &mut Some(rng));
    sol.expect("empty grid is solvable")
}

/// True if the puzzle has a solution where none of `cells` holds its value from `full`
/// (i.e. emptying those cells would break uniqueness).
fn has_other(g: &[u8; 81], cells: &[usize], full: &[u8; 81]) -> bool {
    let Some(b) = Bits::from_grid(g) else { return false };
    // Any alternative solution differs from `full` in at least one of the emptied cells.
    for &c in cells {
        let others = b.cand[c] & !(1 << full[c]);
        for d in digits(others) {
            let mut nb = b;
            if nb.assign(c, d) {
                let mut count = 0;
                let mut sol = None;
                search(nb, 1, &mut count, &mut sol, &mut None);
                if count > 0 {
                    return true;
                }
            }
        }
    }
    false
}

/// Remove clues (symmetric pairs first, then single cells) while the puzzle stays unique — or,
/// with `cap`, while the logic solver can still finish it using techniques up to `cap` (a
/// logic-solvable puzzle is unique by construction).
fn minimize(full: &[u8; 81], rng: &mut Rng, cap: Option<Tech>) -> [u8; 81] {
    let keeps = |g: &[u8; 81], cells: &[usize]| match cap {
        None => !has_other(g, cells, full),
        Some(m) => solves_with(g, m),
    };
    let mut g = *full;
    let mut order: Vec<usize> = (0..41).collect();
    rng.shuffle(&mut order);
    for c in order {
        let pair: Vec<usize> = if c == 40 { vec![40] } else { vec![c, 80 - c] };
        for &p in &pair {
            g[p] = 0;
        }
        if !keeps(&g, &pair) {
            for &p in &pair {
                g[p] = full[p];
            }
        }
    }
    // Final single-cell pass makes the puzzle minimal (symmetry mostly survives).
    let mut rest: Vec<usize> = (0..81).filter(|&c| g[c] != 0).collect();
    rng.shuffle(&mut rest);
    for c in rest {
        g[c] = 0;
        if !keeps(&g, &[c]) {
            g[c] = full[c];
        }
    }
    g
}

fn solves_with(g: &[u8; 81], max: Tech) -> bool {
    let mut l = Logic::new(g);
    while !l.solved() {
        match l.next(max) {
            Some(s) => l.apply(&s),
            None => return false,
        }
    }
    true
}

// ───────────────────────────── logic solver ─────────────────────────────

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub enum Tech {
    HiddenSingle,
    NakedSingle,
    Locked,
    NakedPair,
    HiddenPair,
    NakedTriple,
    HiddenTriple,
    XWing,
    Turbot,
    XYWing,
    Swordfish,
    XYZWing,
    Quad,
    XChain,
    XYChain,
    Forcing,
}

const TECHS: [Tech; 16] = [
    Tech::HiddenSingle,
    Tech::NakedSingle,
    Tech::Locked,
    Tech::NakedPair,
    Tech::HiddenPair,
    Tech::NakedTriple,
    Tech::HiddenTriple,
    Tech::XWing,
    Tech::Turbot,
    Tech::XYWing,
    Tech::Swordfish,
    Tech::XYZWing,
    Tech::Quad,
    Tech::XChain,
    Tech::XYChain,
    Tech::Forcing,
];

impl Tech {
    pub fn name(self) -> &'static str {
        match self {
            Tech::HiddenSingle => "Gizli tekli",
            Tech::NakedSingle => "Tek aday",
            Tech::Locked => "Kilitli aday",
            Tech::NakedPair => "Açık çift",
            Tech::HiddenPair => "Gizli çift",
            Tech::NakedTriple => "Açık üçlü",
            Tech::HiddenTriple => "Gizli üçlü",
            Tech::XWing => "X-Wing",
            Tech::Turbot => "Gökdelen / Uçurtma",
            Tech::XYWing => "XY-Wing",
            Tech::Swordfish => "Swordfish",
            Tech::XYZWing => "XYZ-Wing",
            Tech::Quad => "Dörtlü",
            Tech::XChain => "X-Zinciri",
            Tech::XYChain => "XY-Zinciri",
            Tech::Forcing => "Zorlama zinciri",
        }
    }

    pub fn tier(self) -> &'static str {
        match self as u8 {
            0..=1 => "Kolay",
            2..=4 => "Orta",
            5..=9 => "Zor",
            10..=14 => "Uzman",
            _ => "Usta",
        }
    }
}

struct Step {
    tech: Tech,
    place: Option<(usize, u8)>,
    elim: Vec<(usize, u8)>,
    text: String,
    focus: Vec<usize>,
}

#[derive(Clone)]
struct Logic {
    val: [u8; 81],
    cand: [u16; 81],
}

impl Logic {
    fn new(g: &[u8; 81]) -> Self {
        let mut l = Logic { val: [0; 81], cand: [ALL; 81] };
        for c in 0..81 {
            if g[c] != 0 {
                l.place(c, g[c]);
            }
        }
        l
    }

    fn place(&mut self, c: usize, d: u8) {
        self.val[c] = d;
        self.cand[c] = 0;
        for &p in &geo().peers[c] {
            self.cand[p] &= !(1 << d);
        }
    }

    fn solved(&self) -> bool {
        self.val.iter().all(|&v| v != 0)
    }

    fn apply(&mut self, s: &Step) {
        if let Some((c, d)) = s.place {
            self.place(c, d);
        }
        for &(c, d) in &s.elim {
            self.cand[c] &= !(1 << d);
        }
    }

    fn next(&self, max: Tech) -> Option<Step> {
        TECHS.iter().filter(|&&t| t <= max).find_map(|&t| self.find(t))
    }

    fn find(&self, t: Tech) -> Option<Step> {
        match t {
            Tech::HiddenSingle => self.hidden_single(),
            Tech::NakedSingle => self.naked_single(),
            Tech::Locked => self.locked(),
            Tech::NakedPair => self.naked_subset(2),
            Tech::HiddenPair => self.hidden_subset(2),
            Tech::NakedTriple => self.naked_subset(3),
            Tech::HiddenTriple => self.hidden_subset(3),
            Tech::XWing => self.fish(2),
            Tech::Turbot => self.x_chain(2),
            Tech::XYWing => self.xy_wing(),
            Tech::Swordfish => self.fish(3),
            Tech::XYZWing => self.xyz_wing(),
            Tech::Quad => self.naked_subset(4).or_else(|| self.hidden_subset(4)),
            Tech::XChain => self.x_chain(6),
            Tech::XYChain => self.xy_chain(),
            Tech::Forcing => self.forcing(),
        }
    }

    fn hidden_single(&self) -> Option<Step> {
        let g = geo();
        for u in (18..27).chain(0..18) {
            for d in 1..=9u8 {
                let bit = 1u16 << d;
                let mut n = 0;
                let mut at = 0;
                for &c in &g.units[u] {
                    if self.cand[c] & bit != 0 {
                        n += 1;
                        at = c;
                    }
                }
                if n == 1 {
                    return Some(Step {
                        tech: Tech::HiddenSingle,
                        place: Some((at, d)),
                        elim: vec![],
                        text: format!("Gizli tekli: {d} rakamı {} yalnız {} hücresine gelebilir", unit_loc(u), cell_name(at)),
                        focus: g.units[u].to_vec(),
                    });
                }
            }
        }
        None
    }

    fn naked_single(&self) -> Option<Step> {
        (0..81).find(|&c| self.val[c] == 0 && self.cand[c].count_ones() == 1).map(|c| {
            let d = self.cand[c].trailing_zeros() as u8;
            Step {
                tech: Tech::NakedSingle,
                place: Some((c, d)),
                elim: vec![],
                text: format!(
                    "Tek aday: {} hücresinin satırı, sütunu ve kutusu diğer sekiz rakamı dışlıyor; buraya yalnız {d} gelir",
                    cell_name(c)
                ),
                focus: geo().peers[c].to_vec(),
            }
        })
    }

    fn locked(&self) -> Option<Step> {
        let g = geo();
        // Pointing: a box's candidates for d lie on one line.
        for b in 0..9 {
            let bu = 18 + b;
            for d in 1..=9u8 {
                let bit = 1u16 << d;
                let cells: Vec<usize> = g.units[bu].iter().copied().filter(|&c| self.cand[c] & bit != 0).collect();
                if cells.len() < 2 {
                    continue;
                }
                for (line, same) in [
                    (row(cells[0]), cells.iter().all(|&c| row(c) == row(cells[0]))),
                    (9 + col(cells[0]), cells.iter().all(|&c| col(c) == col(cells[0]))),
                ] {
                    if !same {
                        continue;
                    }
                    let elim: Vec<(usize, u8)> = g.units[line]
                        .iter()
                        .copied()
                        .filter(|&c| boxi(c) != b && self.cand[c] & bit != 0)
                        .map(|c| (c, d))
                        .collect();
                    if !elim.is_empty() {
                        let line_name = if line < 9 { format!("{}. satırda", line + 1) } else { format!("{}. sütunda", line - 8) };
                        return Some(Step {
                            tech: Tech::Locked,
                            place: None,
                            elim,
                            text: format!(
                                "Kilitli aday (işaret eden): {}. kutudaki {d} adayları yalnız {line_name}; bu çizginin kutu dışındaki {d} adayları silinir",
                                b + 1
                            ),
                            focus: cells,
                        });
                    }
                }
            }
        }
        // Claiming: a line's candidates for d lie in one box.
        for line in 0..18 {
            for d in 1..=9u8 {
                let bit = 1u16 << d;
                let cells: Vec<usize> = g.units[line].iter().copied().filter(|&c| self.cand[c] & bit != 0).collect();
                if cells.len() < 2 || !cells.iter().all(|&c| boxi(c) == boxi(cells[0])) {
                    continue;
                }
                let b = boxi(cells[0]);
                let elim: Vec<(usize, u8)> = g.units[18 + b]
                    .iter()
                    .copied()
                    .filter(|&c| !g.units[line].contains(&c) && self.cand[c] & bit != 0)
                    .map(|c| (c, d))
                    .collect();
                if !elim.is_empty() {
                    return Some(Step {
                        tech: Tech::Locked,
                        place: None,
                        elim,
                        text: format!(
                            "Kilitli aday (hapsolan): {} {d} adayları yalnız {}. kutuda; kutunun geri kalanından {d} silinir",
                            unit_loc(line),
                            b + 1
                        ),
                        focus: cells,
                    });
                }
            }
        }
        None
    }

    fn naked_subset(&self, k: usize) -> Option<Step> {
        let g = geo();
        let tech = match k {
            2 => Tech::NakedPair,
            3 => Tech::NakedTriple,
            _ => Tech::Quad,
        };
        for u in 0..27 {
            let open: Vec<usize> = g.units[u].iter().copied().filter(|&c| self.val[c] == 0).collect();
            if open.len() <= k {
                continue;
            }
            let small: Vec<usize> = open.iter().copied().filter(|&c| (2..=k as u32).contains(&self.cand[c].count_ones())).collect();
            let mut found = None;
            combos(small.len(), k, &mut |idx| {
                let union = idx.iter().fold(0u16, |m, &i| m | self.cand[small[i]]);
                if union.count_ones() as usize != k {
                    return false;
                }
                let members: Vec<usize> = idx.iter().map(|&i| small[i]).collect();
                let mut elim = vec![];
                for &c in &open {
                    if !members.contains(&c) {
                        for d in digits(self.cand[c] & union) {
                            elim.push((c, d));
                        }
                    }
                }
                if elim.is_empty() {
                    return false;
                }
                let count = ["", "", "iki", "üç", "dört"][k];
                found = Some(Step {
                    tech,
                    place: None,
                    elim,
                    text: format!(
                        "{}: {} {} hücreleri yalnız {} rakamlarını alabilir; bu {count} rakam aynı birimdeki diğer hücrelerden silinir",
                        if k == 4 { "Açık dörtlü" } else { tech.name() },
                        unit_loc(u),
                        list_cells(&members),
                        list_digits(union)
                    ),
                    focus: members,
                });
                true
            });
            if found.is_some() {
                return found;
            }
        }
        None
    }

    fn hidden_subset(&self, k: usize) -> Option<Step> {
        let g = geo();
        let tech = match k {
            2 => Tech::HiddenPair,
            3 => Tech::HiddenTriple,
            _ => Tech::Quad,
        };
        for u in 0..27 {
            let cells = &g.units[u];
            let open = cells.iter().filter(|&&c| self.val[c] == 0).count();
            if open <= k {
                continue;
            }
            // (digit, position mask within the unit)
            let mut ds: Vec<(u8, u16)> = vec![];
            for d in 1..=9u8 {
                let bit = 1u16 << d;
                let mut pos = 0u16;
                for (i, &c) in cells.iter().enumerate() {
                    if self.cand[c] & bit != 0 {
                        pos |= 1 << i;
                    }
                }
                if (2..=k as u32).contains(&pos.count_ones()) {
                    ds.push((d, pos));
                }
            }
            let mut found = None;
            combos(ds.len(), k, &mut |idx| {
                let pos = idx.iter().fold(0u16, |m, &i| m | ds[i].1);
                if pos.count_ones() as usize != k {
                    return false;
                }
                let dmask = idx.iter().fold(0u16, |m, &i| m | (1 << ds[i].0));
                let members: Vec<usize> = (0..9).filter(|i| pos & (1 << i) != 0).map(|i| cells[i]).collect();
                let mut elim = vec![];
                for &c in &members {
                    for d in digits(self.cand[c] & !dmask) {
                        elim.push((c, d));
                    }
                }
                if elim.is_empty() {
                    return false;
                }
                found = Some(Step {
                    tech,
                    place: None,
                    elim,
                    text: format!(
                        "{}: {} {} rakamları yalnız {} hücrelerine gelebilir; bu hücrelerin diğer adayları silinir",
                        if k == 4 { "Gizli dörtlü" } else { tech.name() },
                        unit_loc(u),
                        list_digits(dmask),
                        list_cells(&members)
                    ),
                    focus: members,
                });
                true
            });
            if found.is_some() {
                return found;
            }
        }
        None
    }

    fn fish(&self, size: usize) -> Option<Step> {
        let tech = if size == 2 { Tech::XWing } else { Tech::Swordfish };
        for d in 1..=9u8 {
            let bit = 1u16 << d;
            for by_rows in [true, false] {
                let at = |line: usize, pos: usize| if by_rows { line * 9 + pos } else { pos * 9 + line };
                let mut lines: Vec<(usize, u16)> = vec![];
                for l in 0..9 {
                    let mut m = 0u16;
                    for p in 0..9 {
                        if self.cand[at(l, p)] & bit != 0 {
                            m |= 1 << p;
                        }
                    }
                    if (2..=size as u32).contains(&m.count_ones()) {
                        lines.push((l, m));
                    }
                }
                let mut found = None;
                combos(lines.len(), size, &mut |idx| {
                    let cover = idx.iter().fold(0u16, |m, &i| m | lines[i].1);
                    if cover.count_ones() as usize != size {
                        return false;
                    }
                    let base: Vec<usize> = idx.iter().map(|&i| lines[i].0).collect();
                    let mut elim = vec![];
                    for p in (0..9).filter(|p| cover & (1 << p) != 0) {
                        for l in (0..9).filter(|l| !base.contains(l)) {
                            let c = at(l, p);
                            if self.cand[c] & bit != 0 {
                                elim.push((c, d));
                            }
                        }
                    }
                    if elim.is_empty() {
                        return false;
                    }
                    let names = |v: Vec<usize>| v.iter().map(|x| (x + 1).to_string()).collect::<Vec<_>>().join(", ");
                    let covers: Vec<usize> = (0..9).filter(|p| cover & (1 << p) != 0).collect();
                    let (bl, cl) = if by_rows { ("satırda", "sütunlarda") } else { ("sütunda", "satırlarda") };
                    let focus = base
                        .iter()
                        .flat_map(|&l| (0..9).filter(move |p| cover & (1 << p) != 0).map(move |p| at(l, p)))
                        .filter(|&c| self.cand[c] & bit != 0)
                        .collect();
                    found = Some(Step {
                        tech,
                        place: None,
                        elim,
                        text: format!(
                            "{}: {d} adayı {}. {bl} yalnız {}. {cl}; bu {cl} başka hiçbir hücre {d} olamaz",
                            tech.name(),
                            names(base.clone()),
                            names(covers)
                        ),
                        focus,
                    });
                    true
                });
                if found.is_some() {
                    return found;
                }
            }
        }
        None
    }

    fn xy_wing(&self) -> Option<Step> {
        let g = geo();
        for p in 0..81 {
            let pm = self.cand[p];
            if self.val[p] != 0 || pm.count_ones() != 2 {
                continue;
            }
            let wings: Vec<usize> = g.peers[p]
                .iter()
                .copied()
                .filter(|&c| self.cand[c].count_ones() == 2 && (self.cand[c] & pm).count_ones() == 1)
                .collect();
            for (i, &a) in wings.iter().enumerate() {
                for &b in &wings[i + 1..] {
                    let (am, bm) = (self.cand[a], self.cand[b]);
                    let z = am & bm & !pm;
                    if z.count_ones() != 1 || (am & pm) == (bm & pm) {
                        continue;
                    }
                    let zd = z.trailing_zeros() as u8;
                    let elim: Vec<(usize, u8)> = (0..81)
                        .filter(|&c| c != p && self.cand[c] & z != 0 && sees(c, a) && sees(c, b))
                        .map(|c| (c, zd))
                        .collect();
                    if !elim.is_empty() {
                        return Some(Step {
                            tech: Tech::XYWing,
                            place: None,
                            elim,
                            text: format!(
                                "XY-Wing: merkez {} ({}), kanatlar {} ({}) ve {} ({}); merkez hangi rakamı alırsa alsın kanatlardan biri {zd} olur, ikisini birden gören hücrelerden {zd} silinir",
                                cell_name(p),
                                list_digits(pm),
                                cell_name(a),
                                list_digits(am),
                                cell_name(b),
                                list_digits(bm)
                            ),
                            focus: vec![p, a, b],
                        });
                    }
                }
            }
        }
        None
    }

    fn xyz_wing(&self) -> Option<Step> {
        let g = geo();
        for p in 0..81 {
            let pm = self.cand[p];
            if self.val[p] != 0 || pm.count_ones() != 3 {
                continue;
            }
            let wings: Vec<usize> = g.peers[p]
                .iter()
                .copied()
                .filter(|&c| self.cand[c].count_ones() == 2 && self.cand[c] & !pm == 0)
                .collect();
            for (i, &a) in wings.iter().enumerate() {
                for &b in &wings[i + 1..] {
                    let (am, bm) = (self.cand[a], self.cand[b]);
                    let z = am & bm;
                    if am | bm != pm || z.count_ones() != 1 {
                        continue;
                    }
                    let zd = z.trailing_zeros() as u8;
                    let elim: Vec<(usize, u8)> = (0..81)
                        .filter(|&c| c != p && self.cand[c] & z != 0 && sees(c, p) && sees(c, a) && sees(c, b))
                        .map(|c| (c, zd))
                        .collect();
                    if !elim.is_empty() {
                        return Some(Step {
                            tech: Tech::XYZWing,
                            place: None,
                            elim,
                            text: format!(
                                "XYZ-Wing: merkez {} ({}), kanatlar {} ({}) ve {} ({}); üçünden biri mutlaka {zd}, üçünü birden gören hücrelerden {zd} silinir",
                                cell_name(p),
                                list_digits(pm),
                                cell_name(a),
                                list_digits(am),
                                cell_name(b),
                                list_digits(bm)
                            ),
                            focus: vec![p, a, b],
                        });
                    }
                }
            }
        }
        None
    }

    /// Single-digit alternating chain with up to `max_links` strong links. Two strong links =
    /// Turbot Fish (Skyscraper, 2-String Kite); longer = X-Chain.
    fn x_chain(&self, max_links: u8) -> Option<Step> {
        let g = geo();
        for d in 1..=9u8 {
            let bit = 1u16 << d;
            let mut strong: Vec<Vec<usize>> = vec![vec![]; 81];
            for u in &g.units {
                let cs: Vec<usize> = u.iter().copied().filter(|&c| self.cand[c] & bit != 0).collect();
                if cs.len() == 2 {
                    strong[cs[0]].push(cs[1]);
                    strong[cs[1]].push(cs[0]);
                }
            }
            for s in 0..81 {
                if strong[s].is_empty() {
                    continue;
                }
                // state = cell*2 + parity (1 = reached by a strong link → "true if s is false").
                let mut parent = [usize::MAX; 162];
                let mut depth = [0u8; 162];
                let mut seen = [false; 162];
                let mut q = std::collections::VecDeque::new();
                seen[s * 2] = true;
                for &t in &strong[s] {
                    let st = t * 2 + 1;
                    if !seen[st] {
                        seen[st] = true;
                        parent[st] = s * 2;
                        depth[st] = 1;
                        q.push_back(st);
                    }
                }
                while let Some(st) = q.pop_front() {
                    let c = st / 2;
                    if st % 2 == 1 {
                        if depth[st] >= 2 && depth[st] <= max_links && c != s {
                            let elim: Vec<(usize, u8)> = (0..81)
                                .filter(|&x| x != s && x != c && self.cand[x] & bit != 0 && sees(x, s) && sees(x, c))
                                .map(|x| (x, d))
                                .collect();
                            if !elim.is_empty() {
                                let mut chain = vec![c];
                                let mut cur = st;
                                while parent[cur] != usize::MAX {
                                    cur = parent[cur];
                                    chain.push(cur / 2);
                                }
                                chain.reverse();
                                let (tech, text) = if depth[st] == 2 && chain.len() == 4 {
                                    let (a, b, e, f) = (chain[0], chain[1], chain[2], chain[3]);
                                    let name = if (col(a) == col(b) && col(e) == col(f)) || (row(a) == row(b) && row(e) == row(f)) {
                                        "Gökdelen"
                                    } else if boxi(b) == boxi(e) {
                                        "İki ipli uçurtma"
                                    } else {
                                        "Turbot balığı"
                                    };
                                    (Tech::Turbot, format!(
                                        "{name}: {d} için iki güçlü bağ ({} = {} ve {} = {}) birbirini görüyor; {} ya da {} mutlaka {d}, ikisini birden gören hücrelerden {d} silinir",
                                        cell_name(a), cell_name(b), cell_name(e), cell_name(f), cell_name(a), cell_name(f)
                                    ))
                                } else {
                                    (Tech::XChain, format!(
                                        "X-Zinciri: {d} için güçlü ve zayıf bağlar sırayla {} hücrelerini bağlıyor; iki uçtan biri mutlaka {d}, ikisini birden gören hücrelerden {d} silinir",
                                        list_cells(&chain)
                                    ))
                                };
                                return Some(Step { tech, place: None, elim, text, focus: chain });
                            }
                        }
                        if depth[st] >= max_links {
                            continue;
                        }
                        for &w in &g.peers[c] {
                            let ns = w * 2;
                            if self.cand[w] & bit != 0 && !seen[ns] {
                                seen[ns] = true;
                                parent[ns] = st;
                                depth[ns] = depth[st];
                                q.push_back(ns);
                            }
                        }
                    } else {
                        for &t in &strong[c] {
                            let ns = t * 2 + 1;
                            if !seen[ns] {
                                seen[ns] = true;
                                parent[ns] = st;
                                depth[ns] = depth[st] + 1;
                                q.push_back(ns);
                            }
                        }
                    }
                }
            }
        }
        None
    }

    /// Chain of bivalue cells: if the start is not x, the end is x.
    fn xy_chain(&self) -> Option<Step> {
        let g = geo();
        let bival: Vec<bool> = (0..81).map(|c| self.val[c] == 0 && self.cand[c].count_ones() == 2).collect();
        for s in 0..81 {
            if !bival[s] {
                continue;
            }
            for x in digits(self.cand[s]) {
                let a = (self.cand[s] & !(1 << x)).trailing_zeros() as u8;
                // state = cell*10 + digit forced true in that cell
                let mut parent = vec![usize::MAX; 810];
                let mut seen = vec![false; 810];
                let start = s * 10 + a as usize;
                seen[start] = true;
                let mut q = std::collections::VecDeque::from([start]);
                let mut len = vec![0u8; 810];
                len[start] = 1;
                while let Some(st) = q.pop_front() {
                    let (c, v) = (st / 10, (st % 10) as u8);
                    if len[st] >= 12 {
                        continue;
                    }
                    for &n in &g.peers[c] {
                        if !bival[n] || n == s || self.cand[n] & (1 << v) == 0 {
                            continue;
                        }
                        let nv = (self.cand[n] & !(1 << v)).trailing_zeros() as u8;
                        let ns = n * 10 + nv as usize;
                        if seen[ns] {
                            continue;
                        }
                        seen[ns] = true;
                        parent[ns] = st;
                        len[ns] = len[st] + 1;
                        if nv == x {
                            let elim: Vec<(usize, u8)> = (0..81)
                                .filter(|&t| t != s && t != n && self.cand[t] & (1 << x) != 0 && sees(t, s) && sees(t, n))
                                .map(|t| (t, x))
                                .collect();
                            if !elim.is_empty() {
                                let mut chain = vec![n];
                                let mut cur = ns;
                                while parent[cur] != usize::MAX {
                                    cur = parent[cur];
                                    chain.push(cur / 10);
                                }
                                chain.reverse();
                                return Some(Step {
                                    tech: Tech::XYChain,
                                    place: None,
                                    elim,
                                    text: format!(
                                        "XY-Zinciri: iki adaylı hücreler {} birbirini zorluyor; baş hücre {x} değilse son hücre {x} olur, ikisini birden gören hücrelerden {x} silinir",
                                        list_cells(&chain)
                                    ),
                                    focus: chain,
                                });
                            }
                        }
                        q.push_back(ns);
                    }
                }
            }
        }
        None
    }

    /// Contradiction forcing chain: assuming `d` in a cell and following singles breaks the
    /// grid, so `d` is not there. Bivalue cells are tried first (the classic Nishio approach).
    fn forcing(&self) -> Option<Step> {
        let mut b = Bits { cand: [0; 81], done: 0 };
        for c in 0..81 {
            if self.val[c] != 0 {
                b.cand[c] = 1 << self.val[c];
                b.done |= 1 << c;
            } else {
                b.cand[c] = self.cand[c];
            }
        }
        for k in 2..=9 {
            for c in (0..81).filter(|&c| self.val[c] == 0 && self.cand[c].count_ones() == k) {
                for d in digits(self.cand[c]) {
                    let mut t = b;
                    let ok = t.assign(c, d)
                        && loop {
                            match t.hidden_singles() {
                                None => break false,
                                Some(true) => continue,
                                Some(false) => break true,
                            }
                        };
                    if !ok {
                        return Some(Step {
                            tech: Tech::Forcing,
                            place: None,
                            elim: vec![(c, d)],
                            text: format!(
                                "Zorlama zinciri: {} hücresine {d} koyarsan tekli adımlar zinciri bir çelişkiye varıyor (bir hücreye ya da bir rakama yer kalmıyor); demek ki orada {d} olamaz",
                                cell_name(c)
                            ),
                            focus: vec![c],
                        });
                    }
                }
            }
        }
        None
    }
}

/// Hardest technique the easiest-first logic solver needs, using techniques up to `max`
/// (`None` = it gets stuck).
fn grade(g: &[u8; 81], max: Tech) -> Option<Tech> {
    let mut l = Logic::new(g);
    let mut hardest = Tech::HiddenSingle;
    while !l.solved() {
        let s = l.next(max)?;
        hardest = hardest.max(s.tech);
        l.apply(&s);
    }
    Some(hardest)
}

/// Last resort: make the puzzle solvable with techniques up to `max` by turning one solution
/// digit into a clue whenever the solver is stuck.
fn soften(puzzle: &[u8; 81], full: &[u8; 81], max: Tech, rng: &mut Rng) -> [u8; 81] {
    let mut p = *puzzle;
    let mut l = Logic::new(&p);
    while !l.solved() {
        match l.next(max) {
            Some(s) => l.apply(&s),
            None => {
                let open: Vec<usize> = (0..81).filter(|&c| l.val[c] == 0).collect();
                let c = *rng.pick(&open);
                p[c] = full[c];
                l.place(c, full[c]);
            }
        }
    }
    p
}

// ───────────────────────────── levels ─────────────────────────────

const ATTEMPTS: u32 = 90;

/// Level → window of hardest-technique ranks `(lo, hi)` (see module docs).
pub fn params(level: u32) -> (Tech, Tech) {
    use Tech::*;
    const ORTA: (Tech, Tech) = (Locked, HiddenPair);
    const PAIRS: (Tech, Tech) = (NakedPair, HiddenPair);
    const ZOR: (Tech, Tech) = (NakedTriple, XYWing);
    const UZMAN: (Tech, Tech) = (Swordfish, XYChain);
    const USTA: (Tech, Tech) = (Forcing, Forcing);
    match level {
        0..=1 => (Locked, Locked),
        2 => PAIRS,
        3..=60 => {
            if level % 3 == 2 {
                PAIRS
            } else {
                ORTA
            }
        }
        61..=150 => {
            if level % 3 == 0 {
                ZOR
            } else {
                PAIRS
            }
        }
        151..=250 => {
            if level % 4 == 0 {
                UZMAN
            } else {
                ZOR
            }
        }
        251..=400 => match level % 5 {
            0 => USTA,
            1 | 3 => UZMAN,
            _ => ZOR,
        },
        _ => match level % 3 {
            0 => USTA,
            _ => UZMAN,
        },
    }
}

pub struct Puzzle {
    pub givens: [u8; 81],
    pub solution: [u8; 81],
    pub hardest: Tech,
}

pub fn generate(level: u32) -> Puzzle {
    let (lo, hi) = params(level);
    // Closest miss: (distance, puzzle). Too-hard puzzles are kept aside for softening.
    let mut best: Option<(u8, Puzzle)> = None;
    let mut too_hard: Option<([u8; 81], [u8; 81], u32)> = None;
    for attempt in 0..ATTEMPTS {
        let mut rng = Rng::new(seed_for("sudoku", level, attempt));
        let full = random_full(&mut rng);
        let p = minimize(&full, &mut rng, None);
        let Some(h) = grade(&p, hi) else {
            too_hard.get_or_insert((p, full, attempt));
            continue;
        };
        let cand = Puzzle { givens: p, solution: full, hardest: h };
        if h >= lo {
            return cand;
        }
        let dist = lo as u8 - h as u8;
        if best.as_ref().is_none_or(|(bd, _)| dist < *bd) {
            best = Some((dist, cand));
        }
    }
    if let Some((_, p)) = best {
        return p;
    }
    // Every attempt was too hard for the window: soften one.
    let (p, full, attempt) = too_hard.expect("attempts > 0");
    let mut rng = Rng::new(seed_for("sudoku", level, attempt + 1000));
    let p = soften(&p, &full, hi, &mut rng);
    let hardest = grade(&p, Tech::Forcing).expect("softened puzzle is logic-solvable");
    Puzzle { givens: p, solution: full, hardest }
}

// ───────────────────────────── session ─────────────────────────────

#[derive(Clone)]
struct Snap {
    values: [u8; 81],
    notes: [u16; 81],
}

struct HintInfo {
    cell: usize,
    digit: u8,
    tech: Tech,
    text: String,
    focus: Vec<usize>,
}

pub struct Sudoku {
    givens: [u8; 81],
    solution: [u8; 81],
    values: [u8; 81],
    notes: [u16; 81],
    hinted: u128,
    hardest: Tech,
    history: Vec<Snap>,
    mistakes: u32,
    hints: u32,
    elapsed_ms: f64,
    hint: Option<HintInfo>,
}

pub fn create(level: u32, mode: &str) -> Result<Box<dyn Session>, String> {
    if mode == "endless" {
        return Err("Sudoku'da sonsuz mod yok".into());
    }
    Ok(Box::new(Sudoku::new(level.clamp(1, crate::MAX_LEVEL))))
}

impl Sudoku {
    pub fn new(level: u32) -> Self {
        let p = generate(level);
        Sudoku {
            givens: p.givens,
            solution: p.solution,
            values: p.givens,
            notes: [0; 81],
            hinted: 0,
            hardest: p.hardest,
            history: vec![],
            mistakes: 0,
            hints: 0,
            elapsed_ms: 0.0,
            hint: None,
        }
    }

    fn fixed(&self, c: usize) -> bool {
        self.givens[c] != 0 || self.hinted >> c & 1 == 1
    }

    fn solved(&self) -> bool {
        self.values == self.solution
    }

    fn stars(&self) -> u32 {
        if !self.solved() {
            0
        } else if self.mistakes == 0 && self.hints == 0 {
            3
        } else if self.mistakes <= 2 && self.hints <= 1 {
            2
        } else {
            1
        }
    }

    fn snapshot(&mut self) {
        self.history.push(Snap { values: self.values, notes: self.notes });
    }

    fn put(&mut self, c: usize, d: u8) {
        self.values[c] = d;
        self.notes[c] = 0;
        for &p in &geo().peers[c] {
            self.notes[p] &= !(1 << d);
        }
    }

    fn conflicts(&self) -> Vec<usize> {
        (0..81)
            .filter(|&c| self.values[c] != 0 && geo().peers[c].iter().any(|&p| self.values[p] == self.values[c]))
            .collect()
    }

    fn cell_arg(a: &Value, key: &str) -> Result<usize, String> {
        let c = a[key].as_u64().ok_or("Hücre eksik")? as usize;
        if c >= 81 {
            return Err("Geçersiz hücre".into());
        }
        Ok(c)
    }

    fn digit_arg(a: &Value) -> Result<u8, String> {
        match a["digit"].as_u64() {
            Some(d @ 1..=9) => Ok(d as u8),
            _ => Err("Rakam 1–9 olmalı".into()),
        }
    }

    /// Next logical placement from the correct digits on the board.
    fn find_hint(&self) -> HintInfo {
        let mut g = [0u8; 81];
        for c in 0..81 {
            if self.values[c] == self.solution[c] {
                g[c] = self.values[c];
            }
        }
        let mut l = Logic::new(&g);
        let mut hardest_elim: Option<Step> = None;
        for _ in 0..200 {
            let Some(s) = l.next(Tech::Forcing) else { break };
            if let Some((c, d)) = s.place {
                let (tech, text, mut focus) = match &hardest_elim {
                    Some(e) if e.tech > s.tech => (e.tech, format!("{}. Ardından {}", e.text, lower_first(&s.text)), e.focus.clone()),
                    _ => (s.tech, s.text.clone(), s.focus.clone()),
                };
                focus.retain(|&f| f != c);
                return HintInfo { cell: c, digit: d, tech, text, focus };
            }
            if hardest_elim.as_ref().is_none_or(|e| s.tech > e.tech) {
                l.apply(&s);
                hardest_elim = Some(s);
            } else {
                l.apply(&s);
            }
        }
        // Fallback (should not happen for a logic-graded puzzle): reveal the most constrained cell.
        let c = (0..81)
            .filter(|&c| self.values[c] != self.solution[c])
            .min_by_key(|&c| l.cand[c].count_ones())
            .unwrap_or(0);
        HintInfo {
            cell: c,
            digit: self.solution[c],
            tech: Tech::NakedSingle,
            text: format!("{} hücresinin değeri {}", cell_name(c), self.solution[c]),
            focus: vec![],
        }
    }
}

fn lower_first(s: &str) -> String {
    let mut ch = s.chars();
    match ch.next() {
        Some(f) => f.to_lowercase().collect::<String>() + ch.as_str(),
        None => String::new(),
    }
}

fn fmt_time(ms: f64) -> String {
    let s = (ms / 1000.0) as u64;
    format!("{}:{:02}", s / 60, s % 60)
}

impl Session for Sudoku {
    fn state(&self) -> Value {
        let won = self.solved();
        let fixed: Vec<u8> = (0..81)
            .map(|c| if self.givens[c] != 0 { 1 } else if self.hinted >> c & 1 == 1 { 2 } else { 0 })
            .collect();
        let wrong: Vec<usize> = (0..81).filter(|&c| self.values[c] != 0 && self.values[c] != self.solution[c]).collect();
        let remaining: Vec<u32> = (1..=9u8).map(|d| 9u32.saturating_sub(self.values.iter().filter(|&&v| v == d).count() as u32)).collect();
        let clues = self.givens.iter().filter(|&&v| v != 0).count();
        json!({
            "status": if won { "won" } else { "playing" },
            "stars": self.stars(),
            "title": self.hardest.tier(),
            "goal": format!("Her satır, sütun ve kutuda 1–9 birer kez · {clues} ipucu"),
            "summary": format!(
                "Hata: {} · İpucu: {} · Süre: {} · En zor teknik: {}",
                self.mistakes, self.hints, fmt_time(self.elapsed_ms), self.hardest.name()
            ),
            "values": self.values.to_vec(),
            "fixed": fixed,
            "notes": self.notes.to_vec(),
            "wrong": wrong,
            "conflicts": self.conflicts(),
            "remaining": remaining,
            "mistakes": self.mistakes,
            "hints": self.hints,
            "elapsed": (self.elapsed_ms / 1000.0) as u64,
            "can_undo": !self.history.is_empty() && !won,
            "clues": clues,
            "technique": self.hardest.name(),
            "hint": self.hint.as_ref().map(|h| json!({
                "cell": h.cell,
                "digit": h.digit,
                "technique": h.tech.name(),
                "text": h.text,
                "focus": h.focus,
            })),
        })
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if self.solved() {
            return Err("Bölüm bitti".into());
        }
        if a["undo"].as_bool() == Some(true) {
            let s = self.history.pop().ok_or("Geri alınacak hamle yok")?;
            self.values = s.values;
            self.notes = s.notes;
            // Hinted cells stay revealed.
            for c in 0..81 {
                if self.hinted >> c & 1 == 1 {
                    self.put(c, self.solution[c]);
                }
            }
            self.hint = None;
            return Ok(());
        }
        if a["hint"].as_bool() == Some(true) {
            let h = self.find_hint();
            self.put(h.cell, h.digit);
            self.hinted |= 1 << h.cell;
            self.hints += 1;
            self.hint = Some(h);
            return Ok(());
        }
        if a["fill_notes"].as_bool() == Some(true) {
            let mut notes = self.notes;
            for c in 0..81 {
                if self.values[c] == 0 {
                    let mut m = ALL;
                    for &p in &geo().peers[c] {
                        m &= !(1 << self.values[p]);
                    }
                    notes[c] = m;
                }
            }
            if notes == self.notes {
                return Err("Notlar zaten dolu".into());
            }
            self.snapshot();
            self.notes = notes;
            self.hint = None;
            return Ok(());
        }
        if a.get("set").is_some() {
            let c = Self::cell_arg(a, "set")?;
            let d = Self::digit_arg(a)?;
            if self.fixed(c) {
                return Err("Bu hücre sabit".into());
            }
            if self.values[c] == d {
                return Ok(());
            }
            self.snapshot();
            self.put(c, d);
            if d != self.solution[c] {
                self.mistakes += 1;
            }
            self.hint = None;
            return Ok(());
        }
        if a.get("erase").is_some() {
            let c = Self::cell_arg(a, "erase")?;
            if self.fixed(c) {
                return Err("Bu hücre sabit".into());
            }
            if self.values[c] == 0 && self.notes[c] == 0 {
                return Err("Hücre zaten boş".into());
            }
            self.snapshot();
            self.values[c] = 0;
            self.notes[c] = 0;
            self.hint = None;
            return Ok(());
        }
        if a.get("note").is_some() {
            let c = Self::cell_arg(a, "note")?;
            let d = Self::digit_arg(a)?;
            if self.fixed(c) {
                return Err("Bu hücre sabit".into());
            }
            if self.values[c] != 0 {
                return Err("Not almak için önce rakamı sil".into());
            }
            self.snapshot();
            self.notes[c] ^= 1 << d;
            self.hint = None;
            return Ok(());
        }
        Err("Bilinmeyen hamle".into())
    }

    fn tick(&mut self, dt_ms: f64) {
        if !self.solved() {
            self.elapsed_ms += dt_ms;
        }
    }
}

// ───────────────────────────── tests ─────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    const LEVELS: [u32; 9] = [1, 2, 3, 50, 137, 250, 400, 499, 500];

    #[test]
    fn sudoku_levels_generate_unique_and_logic_solvable() {
        for level in LEVELS {
            let p = generate(level);
            let (n, sol) = count_solutions(&p.givens, 2);
            assert_eq!(n, 1, "level {level} not unique");
            assert_eq!(sol.unwrap(), p.solution);
            assert_eq!(grade(&p.givens, Tech::Forcing), Some(p.hardest), "level {level}");
            for c in 0..81 {
                assert!(p.givens[c] == 0 || p.givens[c] == p.solution[c]);
            }
        }
    }

    #[test]
    fn sudoku_deterministic() {
        for level in [1, 137, 500] {
            assert_eq!(generate(level).givens, generate(level).givens);
        }
    }

    #[test]
    fn sudoku_early_levels_hit_their_window() {
        for level in 1..=6 {
            let p = generate(level);
            let (lo, hi) = params(level);
            assert!(p.hardest >= lo && p.hardest <= hi, "level {level}: {:?}", p.hardest);
        }
    }

    #[test]
    fn sudoku_solving_reaches_won_with_three_stars() {
        let mut g = Sudoku::new(1);
        for c in 0..81 {
            if g.givens[c] == 0 {
                g.act(&json!({"set": c, "digit": g.solution[c]})).unwrap();
            }
        }
        let st = g.state();
        assert_eq!(st["status"], "won");
        assert_eq!(st["stars"], 3);
        assert!(g.act(&json!({"hint": true})).is_err());
    }

    #[test]
    fn sudoku_illegal_actions_leave_state_unchanged() {
        let mut g = Sudoku::new(2);
        let given = (0..81).find(|&c| g.givens[c] != 0).unwrap();
        let empty = (0..81).find(|&c| g.givens[c] == 0).unwrap();
        let before = g.state();
        for a in [
            json!({"set": given, "digit": 1}),
            json!({"set": empty, "digit": 0}),
            json!({"set": 81, "digit": 3}),
            json!({"erase": given}),
            json!({"erase": empty}),
            json!({"note": given, "digit": 4}),
            json!({"undo": true}),
            json!({"bogus": 1}),
        ] {
            assert!(g.act(&a).is_err(), "{a}");
            assert_eq!(g.state(), before, "{a}");
        }
    }

    #[test]
    fn sudoku_mistakes_notes_undo_and_hints() {
        let mut g = Sudoku::new(3);
        let empties: Vec<usize> = (0..81).filter(|&c| g.givens[c] == 0).collect();
        let (a, b) = (empties[0], *empties.iter().find(|&&c| sees(c, empties[0])).unwrap());
        // Note in a peer is removed when a digit lands.
        let d = g.solution[a];
        g.act(&json!({"note": b, "digit": d})).unwrap();
        assert_eq!(g.notes[b], 1 << d);
        g.act(&json!({"set": a, "digit": d})).unwrap();
        assert_eq!(g.notes[b], 0);
        assert_eq!(g.mistakes, 0);
        // Wrong digit is accepted but counted.
        let wrong = (1..=9u8).find(|&x| x != g.solution[b] && x != d).unwrap();
        g.act(&json!({"set": b, "digit": wrong})).unwrap();
        assert_eq!(g.mistakes, 1);
        assert_eq!(g.state()["wrong"], json!([b]));
        g.act(&json!({"undo": true})).unwrap();
        assert_eq!(g.values[b], 0);
        assert_eq!(g.mistakes, 1);
        // Hints reveal a correct cell and stay through undo.
        g.act(&json!({"hint": true})).unwrap();
        let h = g.state()["hint"].clone();
        let hc = h["cell"].as_u64().unwrap() as usize;
        assert_eq!(g.values[hc], g.solution[hc]);
        assert!(!h["text"].as_str().unwrap().is_empty());
        g.act(&json!({"undo": true})).unwrap();
        assert_eq!(g.values[hc], g.solution[hc]);
        assert!(g.act(&json!({"set": hc, "digit": 1})).is_err());
        // Finish: stars drop to 1 (1 mistake, 1 hint → 2 stars).
        for c in 0..81 {
            if g.values[c] != g.solution[c] {
                g.act(&json!({"set": c, "digit": g.solution[c]})).unwrap();
            }
        }
        assert_eq!(g.state()["status"], "won");
        assert_eq!(g.stars(), 2);
    }

    #[test]
    fn sudoku_hints_alone_solve_the_puzzle() {
        let mut g = Sudoku::new(250);
        let mut guard = 0;
        while !g.solved() {
            g.act(&json!({"hint": true})).unwrap();
            guard += 1;
            assert!(guard <= 81);
        }
        assert_eq!(g.stars(), 1);
    }

    #[test]
    fn sudoku_endless_not_supported() {
        assert!(create(1, "endless").is_err());
    }

    /// `cargo test --release sudoku_timing -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn sudoku_timing_all_levels() {
        let t0 = std::time::Instant::now();
        let mut worst = (0.0f64, 0u32);
        let mut tiers = std::collections::BTreeMap::new();
        let mut misses = 0;
        for level in 1..=500 {
            let t = std::time::Instant::now();
            let p = generate(level);
            let ms = t.elapsed().as_secs_f64() * 1000.0;
            if ms > worst.0 {
                worst = (ms, level);
            }
            let (lo, hi) = params(level);
            if p.hardest < lo || p.hardest > hi {
                misses += 1;
            }
            *tiers.entry(format!("{:02} {:?}", p.hardest as u8, p.hardest)).or_insert(0) += 1;
        }
        let total = t0.elapsed().as_secs_f64();
        println!("500 levels: {:.2}s total, {:.1} ms avg, worst {:.1} ms (L{})", total, total * 2.0, worst.0, worst.1);
        println!("window misses: {misses}");
        for (k, v) in tiers {
            println!("  {k}: {v}");
        }
    }

    #[test]
    #[ignore]
    fn sudoku_grade_distribution() {
        let t = std::time::Instant::now();
        let mut hist = std::collections::BTreeMap::new();
        for attempt in 0..2000 {
            let mut rng = Rng::new(seed_for("sudoku", 9, attempt));
            let full = random_full(&mut rng);
            let q = minimize(&full, &mut rng, None);
            *hist.entry(grade(&q, Tech::Forcing).map(|h| format!("{:02}{h:?}", h as u8)).unwrap_or("99".into())).or_insert(0) += 1;
        }
        println!("{:.2} ms/attempt; {hist:?}", t.elapsed().as_secs_f64() * 1000.0 / 2000.0);
    }
}
