//! Renk Tüpleri (water sort) — pour coloured liquid layers until every tube is empty or one full
//! colour.
//!
//! Rules: a pour moves the **top contiguous same-colour run** of a tube onto a tube that is empty or
//! whose top has the same colour, as much as fits (capacity 4, or 5 in the "tall" variant).
//!
//! Generation: the colour multiset is shuffled into `colors` full tubes (no tube may start sorted,
//! no long ready-made runs), plus the empty tubes. Every candidate is checked by a weighted-A*
//! solver (state hashing, canonical = sorted tube order, admissible "block count" heuristic,
//! symmetry/pointless-move pruning, bounded node budget); its move count becomes the level's
//! **par**. Unsolvable or too-expensive candidates are retried with the next seed; a bounded number
//! of attempts, then the variant falls back to two empty tubes.
//!
//! Variants & curve (`params`): colours L1 = 6 (8 tubes), L2 = 7, then +1 every 50 levels up to 14.
//! Levels rotate through: classic (2 empty tubes), hidden layers (from L25: only the top layer of
//! each tube is visible until exposed), tall tubes (from L40: capacity 5), and tight (from L80:
//! only one empty tube, with 3 fewer colours).
//!
//! Stars: moves ≤ par → 3★, ≤ 1.3 × par → 2★, else 1★ (hidden variant: 1.25× / 1.6×, since you
//! can't plan with unseen layers). Undo is allowed but counts as a move. Using a hint or the extra
//! empty tube (once per level) caps the result at 2★.
//!
//! State: `{status, stars, title, goal, cap, tubes:[[colour bottom→top, 0 = hidden]], hidden:[n],
//!          complete:[bool], moves, par, hint:[from,to]|null, hint_text, extra_used, can_undo, stuck,
//!          last_pour:{from,to,color,amount,serial}|null, summary}`
//! Actions: `{"from":a,"to":b}` · `{"undo":true}` · `{"hint":true}` · `{"extra_tube":true}`

use crate::rng::{seed_for, Rng};
use crate::Session;
use serde_json::{json, Value};
use std::cmp::Reverse;
use std::collections::{BinaryHeap, HashSet};
use std::hash::{BuildHasherDefault, Hasher};

/// State keys are already well mixed; hash them as-is.
#[derive(Default)]
struct KeyHasher(u64);

impl Hasher for KeyHasher {
    fn finish(&self) -> u64 {
        self.0
    }
    fn write(&mut self, bytes: &[u8]) {
        for &b in bytes {
            self.0 = (self.0 << 8) ^ b as u64;
        }
    }
    fn write_u64(&mut self, v: u64) {
        self.0 = v;
    }
}

/// A tube packed into a u32: 4 bits per layer (bottom = bits 0..4), length in bits 28..32.
type Tube = u32;

fn tlen(t: Tube) -> usize {
    (t >> 28) as usize
}
fn layer(t: Tube, i: usize) -> u8 {
    ((t >> (4 * i)) & 15) as u8
}
fn top(t: Tube) -> u8 {
    let l = tlen(t);
    if l == 0 {
        0
    } else {
        layer(t, l - 1)
    }
}
fn run(t: Tube) -> usize {
    let l = tlen(t);
    if l == 0 {
        return 0;
    }
    let c = layer(t, l - 1);
    let mut k = 1;
    while k < l && layer(t, l - 1 - k) == c {
        k += 1;
    }
    k
}
fn pack(layers: &[u8]) -> Tube {
    let mut t = (layers.len() as u32) << 28;
    for (i, &c) in layers.iter().enumerate() {
        t |= (c as u32) << (4 * i);
    }
    t
}
fn unpack(t: Tube) -> Vec<u8> {
    (0..tlen(t)).map(|i| layer(t, i)).collect()
}
fn blocks(t: Tube) -> usize {
    let l = tlen(t);
    (0..l).filter(|&i| i == 0 || layer(t, i) != layer(t, i - 1)).count()
}
fn complete(t: Tube, cap: usize) -> bool {
    tlen(t) == cap && run(t) == cap
}

/// Pour amount from `a` into `b` (0 = illegal).
fn pour_amount(a: Tube, b: Tube, cap: usize) -> usize {
    let la = tlen(a);
    if la == 0 {
        return 0;
    }
    let lb = tlen(b);
    if lb == cap || (lb > 0 && top(b) != top(a)) {
        return 0;
    }
    run(a).min(cap - lb)
}

fn apply_pour(a: Tube, b: Tube, k: usize) -> (Tube, Tube) {
    let c = top(a) as u32;
    let la = tlen(a);
    let lb = tlen(b);
    let keep = la - k;
    let mask = if keep == 0 { 0 } else { (1u32 << (4 * keep)) - 1 };
    let na = (a & mask) | ((keep as u32) << 28);
    let mut nb = b & 0x0FFF_FFFF;
    for i in lb..lb + k {
        nb |= c << (4 * i);
    }
    nb |= ((lb + k) as u32) << 28;
    (na, nb)
}

fn solved(tubes: &[Tube], cap: usize) -> bool {
    tubes.iter().all(|&t| tlen(t) == 0 || complete(t, cap))
}

fn key(tubes: &[Tube]) -> u64 {
    let mut v = [0 as Tube; MAX_TUBES];
    let v = &mut v[..tubes.len()];
    v.copy_from_slice(tubes);
    v.sort_unstable();
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for &t in v.iter() {
        h = (h ^ t as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15);
        h ^= h >> 31;
    }
    h ^= h >> 33;
    h = h.wrapping_mul(0xff51_afd7_ed55_8ccd);
    h ^ (h >> 33)
}

/// Useful moves from a position (pruned: no pouring out of finished tubes, no moving a
/// single-colour tube into an empty one, only the first empty tube as a destination).
fn moves(tubes: &[Tube], cap: usize) -> Vec<(usize, usize, usize)> {
    let mut out = Vec::new();
    let first_empty = tubes.iter().position(|&t| tlen(t) == 0);
    for (i, &a) in tubes.iter().enumerate() {
        if tlen(a) == 0 || complete(a, cap) {
            continue;
        }
        let single = run(a) == tlen(a);
        for (j, &b) in tubes.iter().enumerate() {
            if i == j {
                continue;
            }
            if tlen(b) == 0 && (Some(j) != first_empty || single) {
                continue;
            }
            let k = pour_amount(a, b, cap);
            if k > 0 {
                out.push((i, j, k));
            }
        }
    }
    out
}

/// Most tubes a position can have (14 colours + 2 empty + the extra tube power).
const MAX_TUBES: usize = 18;

struct Node {
    tubes: [Tube; MAX_TUBES],
    parent: u32,
    mv: (u8, u8),
    g: u32,
    blocks: u32,
}

/// Weighted A*. Returns the move list (indices into the given tube order) or None if the budget
/// runs out / no solution.
pub fn solve(start: &[Tube], cap: usize, colors: usize, wg: usize, wh: usize, budget: usize) -> Option<Vec<(usize, usize)>> {
    let n = start.len();
    assert!(n <= MAX_TUBES);
    if solved(start, cap) {
        return Some(vec![]);
    }
    let mut first = [0 as Tube; MAX_TUBES];
    first[..n].copy_from_slice(start);
    let b0: usize = start.iter().map(|&t| blocks(t)).sum();
    let mut nodes: Vec<Node> = Vec::with_capacity(budget + 64);
    nodes.push(Node { tubes: first, parent: u32::MAX, mv: (0, 0), g: 0, blocks: b0 as u32 });
    let mut seen: HashSet<u64, BuildHasherDefault<KeyHasher>> = HashSet::with_capacity_and_hasher(budget * 2, Default::default());
    seen.insert(key(start));
    let mut heap = BinaryHeap::new();
    heap.push((Reverse(wh * b0.saturating_sub(colors)), Reverse(0u32), 0u32));
    while let Some((_, _, id)) = heap.pop() {
        if nodes.len() > budget {
            return None;
        }
        let (tubes, g, bl) = {
            let nd = &nodes[id as usize];
            (nd.tubes, nd.g, nd.blocks as usize)
        };
        for (i, j, k) in moves(&tubes[..n], cap) {
            let mut next = tubes;
            let (a, b) = apply_pour(tubes[i], tubes[j], k);
            next[i] = a;
            next[j] = b;
            if !seen.insert(key(&next[..n])) {
                continue;
            }
            let nb = bl + blocks(a) + blocks(b) - blocks(tubes[i]) - blocks(tubes[j]);
            let nid = nodes.len() as u32;
            nodes.push(Node { tubes: next, parent: id, mv: (i as u8, j as u8), g: g + 1, blocks: nb as u32 });
            if solved(&next[..n], cap) {
                let mut path = vec![];
                let mut cur = nid;
                while nodes[cur as usize].parent != u32::MAX {
                    let nd = &nodes[cur as usize];
                    path.push((nd.mv.0 as usize, nd.mv.1 as usize));
                    cur = nd.parent;
                }
                path.reverse();
                return Some(path);
            }
            heap.push((Reverse(wg * (g + 1) as usize + wh * nb.saturating_sub(colors)), Reverse(g + 1), nid));
        }
    }
    None
}


/// Best-effort solve for play-time hints (bounded).
fn quick_solve(tubes: &[Tube], cap: usize, colors: usize) -> Option<Vec<(usize, usize)>> {
    solve(tubes, cap, colors, 1, 2, 12_000).or_else(|| solve(tubes, cap, colors, 1, 5, 30_000))
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Variant {
    Classic,
    Hidden,
    Tall,
    Tight,
}

impl Variant {
    fn title(self) -> &'static str {
        match self {
            Variant::Classic => "Klasik",
            Variant::Hidden => "Gizli katmanlar",
            Variant::Tall => "Uzun tüpler",
            Variant::Tight => "Tek boş tüp",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Params {
    pub variant: Variant,
    pub colors: usize,
    pub empty: usize,
    pub cap: usize,
}

/// Level → (variant, colours, empty tubes, capacity). See module docs.
pub fn params(level: u32) -> Params {
    let l = level.clamp(1, 500);
    let base = if l == 1 { 6 } else { (7 + (l as usize - 2) / 50).min(14) };
    let variant = match (l - 1) % 6 {
        2 if l >= 25 => Variant::Hidden,
        4 if l >= 40 => Variant::Tall,
        5 if l >= 80 => Variant::Tight,
        _ => Variant::Classic,
    };
    match variant {
        Variant::Classic | Variant::Hidden => Params { variant, colors: base, empty: 2, cap: 4 },
        Variant::Tall => Params { variant, colors: (base - 1).max(6), empty: 2, cap: 5 },
        Variant::Tight => Params { variant, colors: (base - 4).clamp(5, 8), empty: 1, cap: 4 },
    }
}

fn deal(p: &Params, rng: &mut Rng) -> Option<Vec<Tube>> {
    let mut pool: Vec<u8> = (1..=p.colors as u8).flat_map(|c| std::iter::repeat(c).take(p.cap)).collect();
    rng.shuffle(&mut pool);
    let mut tubes: Vec<Tube> = pool.chunks(p.cap).map(pack).collect();
    // Reject ready-made structure: a sorted tube, or long runs that make it trivial.
    let long_runs = tubes.iter().filter(|&&t| (0..p.cap - 1).any(|i| (0..3.min(p.cap - i)).all(|k| layer(t, i + k) == layer(t, i)) && p.cap - i >= 3)).count();
    if tubes.iter().any(|&t| complete(t, p.cap)) || long_runs > p.colors / 4 {
        return None;
    }
    tubes.extend(std::iter::repeat(pack(&[])).take(p.empty));
    Some(tubes)
}

/// Solvability check + par: a fast weighted search (w = 2) proves solvability, then less greedy
/// searches (w = 1.5, 1.25, and plain A* = optimal for ≤ 9 colours) with small budgets try to
/// shorten the solution.
pub fn par_solution(tubes: &[Tube], p: &Params) -> Option<Vec<(usize, usize)>> {
    let budget = 6_000 + 2_000 * p.colors;
    let mut best = solve(tubes, p.cap, p.colors, 1, 2, budget)?;
    let exact = if p.colors <= 9 { 25_000 } else { 0 };
    for (wg, wh, b) in [(2, 3, 12_000), (4, 5, 12_000), (1, 1, exact)] {
        if let Some(s) = solve(tubes, p.cap, p.colors, wg, wh, b) {
            if s.len() < best.len() {
                best = s;
            }
        }
    }
    Some(best)
}

/// Deterministic level: (params actually used, start tubes, par).
pub fn generate(level: u32) -> (Params, Vec<Tube>, usize) {
    let mut p = params(level);
    for attempt in 0..80u32 {
        if attempt == 50 && p.empty == 1 {
            p = Params { variant: Variant::Classic, empty: 2, ..p }; // tight variant too hard for these seeds
        }
        let mut rng = Rng::new(seed_for("water_sort", level, attempt));
        let Some(tubes) = deal(&p, &mut rng) else { continue };
        if let Some(path) = par_solution(&tubes, &p) {
            return (p, tubes, path.len());
        }
    }
    // Last resort (never observed): greedy solve with a large budget.
    let mut rng = Rng::new(seed_for("water_sort", level, 999));
    p = Params { variant: Variant::Classic, empty: 2, ..p };
    loop {
        if let Some(tubes) = deal(&p, &mut rng) {
            if let Some(path) = solve(&tubes, p.cap, p.colors, 1, 5, 400_000) {
                return (p, tubes, path.len());
            }
        }
    }
}

pub struct WaterSort {
    p: Params,
    tubes: Vec<Tube>,
    hidden: Vec<usize>,
    par: usize,
    moves: u32,
    history: Vec<Vec<Tube>>,
    hints: u32,
    extra_used: bool,
    hint: Option<(usize, usize)>,
    hint_text: Option<String>,
    last_pour: Option<(usize, usize, u8, usize)>,
    serial: u32,
}

impl WaterSort {
    pub fn new(level: u32) -> Self {
        let (p, tubes, par) = generate(level);
        let hidden = tubes
            .iter()
            .map(|&t| if p.variant == Variant::Hidden { tlen(t).saturating_sub(1) } else { 0 })
            .collect();
        WaterSort {
            p,
            tubes,
            hidden,
            par,
            moves: 0,
            history: vec![],
            hints: 0,
            extra_used: false,
            hint: None,
            hint_text: None,
            last_pour: None,
            serial: 0,
        }
    }

    fn won(&self) -> bool {
        solved(&self.tubes, self.p.cap)
    }

    fn stars(&self) -> u32 {
        if !self.won() {
            return 0;
        }
        let (a, b) = if self.p.variant == Variant::Hidden { (1.25, 1.6) } else { (1.0, 1.3) };
        let m = self.moves as f64;
        let par = self.par as f64;
        let s = if m <= par * a {
            3
        } else if m <= par * b {
            2
        } else {
            1
        };
        if self.hints > 0 || self.extra_used {
            s.min(2)
        } else {
            s
        }
    }

    fn stuck(&self) -> bool {
        !self.won()
            && !(0..self.tubes.len()).any(|i| (0..self.tubes.len()).any(|j| i != j && pour_amount(self.tubes[i], self.tubes[j], self.p.cap) > 0))
    }

    fn reveal(&mut self, i: usize) {
        self.hidden[i] = self.hidden[i].min(tlen(self.tubes[i]).saturating_sub(1));
    }

    fn pour(&mut self, from: usize, to: usize) -> Result<(), String> {
        let n = self.tubes.len();
        if from >= n || to >= n {
            return Err("Geçersiz tüp".into());
        }
        if from == to {
            return Err("Aynı tüp".into());
        }
        let (a, b) = (self.tubes[from], self.tubes[to]);
        if tlen(a) == 0 {
            return Err("Bu tüp boş".into());
        }
        if tlen(b) == self.p.cap {
            return Err("Hedef tüp dolu".into());
        }
        let k = pour_amount(a, b, self.p.cap);
        if k == 0 {
            return Err("Renkler uyuşmuyor".into());
        }
        self.history.push(self.tubes.clone());
        let color = top(a);
        let (na, nb) = apply_pour(a, b, k);
        self.tubes[from] = na;
        self.tubes[to] = nb;
        self.reveal(from);
        self.moves += 1;
        self.hint = None;
        self.hint_text = None;
        self.serial += 1;
        self.last_pour = Some((from, to, color, k));
        Ok(())
    }

    fn colors_present(&self) -> usize {
        self.p.colors
    }
}

impl Session for WaterSort {
    fn state(&self) -> Value {
        let won = self.won();
        let tubes: Vec<Vec<u8>> = self
            .tubes
            .iter()
            .zip(&self.hidden)
            .map(|(&t, &h)| unpack(t).into_iter().enumerate().map(|(i, c)| if i < h { 0 } else { c }).collect())
            .collect();
        json!({
            "status": if won { "won" } else { "playing" },
            "stars": self.stars(),
            "title": format!("{} · {} renk", self.p.variant.title(), self.p.colors),
            "goal": format!("Her tüpü tek renkle doldur · hedef {} hamle", self.par),
            "variant": format!("{:?}", self.p.variant).to_lowercase(),
            "cap": self.p.cap,
            "tubes": tubes,
            "hidden": self.hidden,
            "complete": self.tubes.iter().map(|&t| complete(t, self.p.cap)).collect::<Vec<_>>(),
            "moves": self.moves,
            "par": self.par,
            "hint": self.hint.map(|(a, b)| json!([a, b])),
            "hint_text": self.hint_text,
            "hints": self.hints,
            "extra_used": self.extra_used,
            "can_undo": !self.history.is_empty() && !won,
            "stuck": self.stuck(),
            "last_pour": self.last_pour.map(|(f, t, c, k)| json!({"from": f, "to": t, "color": c, "amount": k, "serial": self.serial})),
            "summary": format!("Hamle: {} · Hedef: {}{}", self.moves, self.par, if self.extra_used { " · ek tüp" } else { "" }),
        })
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if self.won() {
            return Err("Bölüm bitti".into());
        }
        if a["undo"].as_bool() == Some(true) {
            let prev = self.history.pop().ok_or("Geri alınacak hamle yok")?;
            // An extra tube added after this snapshot stays (it is never taken back).
            let mut prev = prev;
            while prev.len() < self.tubes.len() {
                prev.push(pack(&[]));
            }
            self.tubes = prev;
            for i in 0..self.tubes.len() {
                self.reveal(i);
            }
            self.moves += 1; // undo still costs a move
            self.hint = None;
            self.hint_text = None;
            self.last_pour = None;
            self.serial += 1;
            return Ok(());
        }
        if a["hint"].as_bool() == Some(true) {
            self.hints += 1;
            match quick_solve(&self.tubes, self.p.cap, self.colors_present()) {
                Some(path) if !path.is_empty() => {
                    self.hint = Some(path[0]);
                    self.hint_text = Some(format!("Buradan {} hamlede çözülebilir. Sıradaki dökme parlıyor.", path.len()));
                }
                _ => {
                    self.hint = None;
                    self.hint_text = Some("Bu durumdan çıkış bulamadım — birkaç hamle geri al.".into());
                }
            }
            return Ok(());
        }
        if a["extra_tube"].as_bool() == Some(true) {
            if self.extra_used {
                return Err("Ek tüp zaten kullanıldı".into());
            }
            self.extra_used = true;
            self.tubes.push(pack(&[]));
            self.hidden.push(0);
            self.hint = None;
            self.hint_text = None;
            return Ok(());
        }
        let from = a["from"].as_u64().ok_or("from eksik")? as usize;
        let to = a["to"].as_u64().ok_or("to eksik")? as usize;
        self.pour(from, to)
    }
}

pub fn create(level: u32, mode: &str) -> Result<Box<dyn Session>, String> {
    if mode == "endless" {
        return Err("Renk Tüpleri'nde sonsuz mod yok".into());
    }
    Ok(Box::new(WaterSort::new(level)))
}

#[cfg(test)]
mod tests {
    use super::*;

    const LEVELS: [u32; 9] = [1, 2, 3, 50, 137, 250, 400, 499, 500];

    #[test]
    fn water_sort_packing() {
        let t = pack(&[1, 2, 2]);
        assert_eq!(tlen(t), 3);
        assert_eq!(top(t), 2);
        assert_eq!(run(t), 2);
        assert_eq!(blocks(t), 2);
        let (a, b) = apply_pour(t, pack(&[2]), 2);
        assert_eq!(unpack(a), vec![1]);
        assert_eq!(unpack(b), vec![2, 2, 2]);
        assert_eq!(pour_amount(pack(&[3, 3, 3]), pack(&[3, 3]), 4), 2);
        assert_eq!(pour_amount(pack(&[3]), pack(&[1]), 4), 0);
    }

    #[test]
    fn water_sort_levels_generate_and_par_replays() {
        for level in LEVELS {
            let (p, tubes, par) = generate(level);
            assert!(par > 0);
            let mut count = vec![0; 16];
            for &t in &tubes {
                for c in unpack(t) {
                    count[c as usize] += 1;
                }
            }
            assert!((1..=p.colors).all(|c| count[c] == p.cap));
            // Re-solve and replay through the session to confirm the par is reachable.
            let mut g = WaterSort::new(level);
            let path = par_solution(&tubes, &p).unwrap();
            assert_eq!(path.len(), par);
            for (a, b) in path {
                g.act(&json!({"from": a, "to": b})).unwrap();
            }
            let st = g.state();
            assert_eq!(st["status"], "won", "level {level}");
            assert_eq!(st["stars"], 3);
        }
    }

    #[test]
    fn water_sort_deterministic() {
        for level in [1, 250, 500] {
            assert_eq!(generate(level).1, generate(level).1);
        }
    }

    #[test]
    fn water_sort_illegal_rejected() {
        let mut g = WaterSort::new(1);
        let before = g.state();
        let n = g.tubes.len();
        assert!(g.act(&json!({"from": n - 1, "to": 0})).is_err()); // empty source
        assert!(g.act(&json!({"from": 0, "to": 0})).is_err());
        assert!(g.act(&json!({"from": 0, "to": 99})).is_err());
        assert!(g.act(&json!({"from": 0, "to": 1})).is_err()); // full target
        assert!(g.act(&json!({"undo": true})).is_err());
        assert_eq!(before, g.state());
    }

    #[test]
    fn water_sort_undo_counts_and_hidden_reveal() {
        let level = (25..60).find(|&l| params(l).variant == Variant::Hidden).unwrap();
        let mut g = WaterSort::new(level);
        let st = g.state();
        assert_eq!(st["hidden"][0], g.p.cap - 1);
        assert_eq!(st["tubes"][0][0], 0);
        let n = g.tubes.len();
        g.act(&json!({"from": 0, "to": n - 1})).unwrap();
        assert!(g.hidden[0] < g.p.cap - 1);
        let h0 = g.hidden[0];
        g.act(&json!({"undo": true})).unwrap();
        assert_eq!(g.moves, 2);
        assert_eq!(g.hidden[0], h0); // revealed layers stay revealed
    }

    #[test]
    fn water_sort_hint_and_extra_cap_stars() {
        let mut g = WaterSort::new(2);
        g.act(&json!({"extra_tube": true})).unwrap();
        assert!(g.act(&json!({"extra_tube": true})).is_err());
        let mut guard = 0;
        while !g.won() {
            g.act(&json!({"hint": true})).unwrap();
            let (a, b) = g.hint.expect("hint move");
            g.act(&json!({"from": a, "to": b})).unwrap();
            guard += 1;
            assert!(guard < 300);
        }
        assert!(g.stars() <= 2);
    }

    #[test]
    #[ignore]
    fn water_sort_timing_all_levels() {
        let t0 = std::time::Instant::now();
        let mut worst = (0u128, 0u32);
        let mut fallbacks = 0;
        for level in 1..=500 {
            let t = std::time::Instant::now();
            let (p, _, _) = generate(level);
            if p != params(level) {
                fallbacks += 1;
            }
            let ms = t.elapsed().as_millis();
            if ms > worst.0 {
                worst = (ms, level);
            }
        }
        println!(
            "water_sort: 500 levels in {:?}, worst {} ms (level {}), tight→classic fallbacks {fallbacks}",
            t0.elapsed(),
            worst.0,
            worst.1
        );
    }
}
