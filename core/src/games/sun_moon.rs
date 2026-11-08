//! Sun & Moon ("Güneş & Ay") — a binary balance puzzle.
//!
//! Rules: fill every cell with a sun or a moon. Every row and column holds equally many suns and
//! moons; no three equal symbols may touch in a line (row or column); an `=` sign between two cells
//! means they are equal, `×` means they differ. (The optional "no two identical rows" rule is not
//! used: the clue set alone always forces a unique grid.)
//!
//! Generation: a random valid full grid is built row by row from the list of valid line patterns.
//! Clues = every cell as a given plus a random subset of `=`/`×` edge signs. Clues are then removed
//! greedily (seeded order) as long as the logic solver below still solves the grid using only the
//! techniques allowed for that level. A logic solve uses only sound deductions, so a solved puzzle is
//! guaranteed to have exactly one solution (the tests double-check with a brute-force counter).
//!
//! Techniques (tiers), also used for hints:
//! 1. Direct rules — "Çift kuralı" (XX → neighbours opposite), "Sandviç" (X_X → middle opposite),
//!    "Sayı tamamlama" (n/2 of one symbol → rest opposite), "İşaret" (=/× with a known neighbour).
//! 2. "Satır analizi" — every completion of one line consistent with counts, no-three and the
//!    in-line signs agrees on a cell.
//! 3. "Deneme ile çelişki" — assuming a value and propagating tiers 1–2 breaks a rule, so the cell
//!    takes the opposite value (one level deep only; capped per puzzle).
//!
//! Level curve (`params`): 6×6 for levels 1–119, 8×8 for 120–299, 10×10 for 300–500. Level 1 is
//! direct rules only (minimal givens for that tier); from level 2 line analysis is allowed; trial
//! reasoning is allowed from level 40 (6×6), 150 (8×8) and 320 (10×10). Within a size band the
//! number of edge signs grows and givens are removed first, so late puzzles lean on `=`/`×` signs.
//!
//! Stars: a *mistake* is counted when you leave a cell holding the wrong symbol (moving on to
//! another cell, asking a hint or undoing); cycling one cell through its values is free. Every
//! hint counts once. 0 hints and 0 mistakes → 3★, hints + mistakes ≤ 3 → 2★, otherwise 1★.
//!
//! Deferred feedback: `bad_*` are the live rule breaks of the whole grid. `deferred` repeats them
//! with the cell currently being edited (the last one set, until another cell, a hint or an undo)
//! treated as empty, so the UI can hold back errors that cell causes while the player is still
//! cycling it (passing through sun on the way to moon) and reveal them a moment later.
//!
//! State: `{status, stars, title, goal, size, cells:[0 empty|1 sun|2 moon], fixed:[bool],
//!          edges:[[a,b,"="|"x"]], bad_cells:[i], bad_rows:[r], bad_cols:[c], bad_edges:[k],
//!          deferred:{cell, bad_cells, bad_rows, bad_cols, bad_edges}|null,
//!          hint:{cell,value,text}|null, hints, mistakes, filled, can_undo, summary}`
//! Actions: `{"cycle":i}` (empty → sun → moon → empty) · `{"set":i,"value":0|1|2}` ·
//!          `{"undo":true}` · `{"hint":true}`

use crate::rng::{seed_for, Rng};
use crate::Session;
use serde_json::{json, Value};

pub const SUN: u8 = 1;
pub const MOON: u8 = 2;

fn opp(v: u8) -> u8 {
    3 - v
}

fn vname(v: u8) -> &'static str {
    if v == SUN {
        "güneş"
    } else {
        "ay"
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Params {
    pub size: usize,
    pub max_tier: u8,
    /// Edge signs in the initial clue pool.
    pub edges: usize,
    /// 0 → givens and signs are removed in mixed order; 1 → all givens are tried first.
    pub given_bias: f64,
    /// Maximum number of trial (tier 3) deductions a puzzle may need.
    pub max_trials: u32,
}

/// Level → generator parameters (see module docs for the curve).
pub fn params(level: u32) -> Params {
    let l = level.clamp(1, 500);
    let (size, lo, hi, tier3_from, max_trials) = if l < 120 {
        (6, 1, 119, 40, 3)
    } else if l < 300 {
        (8, 120, 299, 150, 6)
    } else {
        (10, 300, 500, 320, 9)
    };
    let t = (l - lo) as f64 / (hi - lo) as f64;
    let max_tier = if l == 1 {
        1
    } else if l >= tier3_from {
        3
    } else {
        2
    };
    let total_edges = 2 * size * (size - 1);
    let edges = (total_edges as f64 * (0.08 + 0.14 * t)).round() as usize;
    Params { size, max_tier, edges, given_bias: 0.25 + 0.75 * t, max_trials }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Edge {
    pub a: usize,
    pub b: usize,
    pub eq: bool,
}

#[derive(Clone, Debug)]
pub struct Puzzle {
    pub n: usize,
    pub givens: Vec<u8>,
    pub edges: Vec<Edge>,
    pub solution: Vec<u8>,
}

/// All valid lines of length `n` as bitmasks (bit k set = sun at position k).
fn line_patterns(n: usize) -> Vec<u16> {
    (0u32..(1 << n))
        .filter(|&p| {
            if p.count_ones() as usize != n / 2 {
                return false;
            }
            for i in 0..n - 2 {
                let b = (p >> i) & 7;
                if b == 7 || b == 0 {
                    return false;
                }
            }
            true
        })
        .map(|p| p as u16)
        .collect()
}

/// Valid line patterns per size, computed once.
fn cached_patterns(n: usize) -> &'static [u16] {
    use std::sync::OnceLock;
    static CACHE: [OnceLock<Vec<u16>>; 3] = [OnceLock::new(), OnceLock::new(), OnceLock::new()];
    let slot = match n {
        6 => 0,
        8 => 1,
        _ => 2,
    };
    CACHE[slot].get_or_init(|| line_patterns(n))
}

/// Per-puzzle constraint context: lines (rows then columns) with their in-line sign masks.
struct Ctx {
    n: usize,
    pats: &'static [u16],
    lines: Vec<LineInfo>,
    edges: Vec<Edge>,
    cell_edges: Vec<Vec<usize>>,
}

struct LineInfo {
    cells: Vec<usize>,
    /// bit k = "=" between positions k and k+1
    eq: u16,
    /// bit k = "×" between positions k and k+1
    ne: u16,
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Contra {
    Line(usize),
    Edge(usize),
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Tech {
    Pair,
    Sandwich,
    Count,
    Sign(usize),
    LineAnalysis { suns_left: u32, moons_left: u32 },
    Trial { tried: u8, contra: Contra },
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct Step {
    cell: usize,
    val: u8,
    line: usize,
    tech: Tech,
}

impl Ctx {
    fn new(n: usize, edges: &[Edge]) -> Self {
        let mut lines = Vec::with_capacity(2 * n);
        for r in 0..n {
            lines.push(LineInfo { cells: (0..n).map(|c| r * n + c).collect(), eq: 0, ne: 0 });
        }
        for c in 0..n {
            lines.push(LineInfo { cells: (0..n).map(|r| r * n + c).collect(), eq: 0, ne: 0 });
        }
        for e in edges {
            let (ra, ca, rb) = (e.a / n, e.a % n, e.b / n);
            let (li, k) = if ra == rb { (ra, ca) } else { (n + ca, ra) };
            if e.eq {
                lines[li].eq |= 1 << k;
            } else {
                lines[li].ne |= 1 << k;
            }
        }
        let mut cell_edges = vec![vec![]; n * n];
        for (k, e) in edges.iter().enumerate() {
            cell_edges[e.a].push(k);
            cell_edges[e.b].push(k);
        }
        Ctx { n, pats: cached_patterns(n), lines, edges: edges.to_vec(), cell_edges }
    }

    fn masks(&self, g: &[u8], li: usize) -> (u16, u16) {
        let (mut s, mut m) = (0u16, 0u16);
        for (k, &c) in self.lines[li].cells.iter().enumerate() {
            match g[c] {
                SUN => s |= 1 << k,
                MOON => m |= 1 << k,
                _ => {}
            }
        }
        (s, m)
    }

    /// Hard rule check of one line (three in a row / count overflow / broken in-line sign).
    fn line_ok(&self, g: &[u8], li: usize) -> bool {
        let n = self.n;
        let cells = &self.lines[li].cells;
        let (s, m) = self.masks(g, li);
        if s.count_ones() as usize > n / 2 || m.count_ones() as usize > n / 2 {
            return false;
        }
        for i in 0..n - 2 {
            let v = g[cells[i]];
            if v != 0 && v == g[cells[i + 1]] && v == g[cells[i + 2]] {
                return false;
            }
        }
        true
    }

    /// Tier 1. In `apply` mode every deduction is written immediately and the pass continues;
    /// otherwise the first deduction is returned. Err = contradiction found.
    fn t1(&self, g: &mut [u8], apply: bool) -> Result<(bool, Option<Step>), Contra> {
        let n = self.n;
        let mut changed = false;
        macro_rules! emit {
            ($cell:expr, $val:expr, $line:expr, $tech:expr) => {{
                let st = Step { cell: $cell, val: $val, line: $line, tech: $tech };
                if !apply {
                    return Ok((true, Some(st)));
                }
                g[$cell] = $val;
                changed = true;
            }};
        }
        for li in 0..2 * n {
            if !self.line_ok(g, li) {
                return Err(Contra::Line(li));
            }
            let cells = &self.lines[li].cells;
            // Pair: XX → both ends opposite.
            for i in 0..n - 1 {
                let v = g[cells[i]];
                if v != 0 && v == g[cells[i + 1]] {
                    if i > 0 && g[cells[i - 1]] == 0 {
                        emit!(cells[i - 1], opp(v), li, Tech::Pair);
                    }
                    if i + 2 < n && g[cells[i + 2]] == 0 {
                        emit!(cells[i + 2], opp(v), li, Tech::Pair);
                    }
                }
            }
            // Sandwich: X_X → middle opposite.
            for i in 0..n - 2 {
                let v = g[cells[i]];
                if v != 0 && v == g[cells[i + 2]] && g[cells[i + 1]] == 0 {
                    emit!(cells[i + 1], opp(v), li, Tech::Sandwich);
                }
            }
            // Count completion.
            let (s, m) = self.masks(g, li);
            for (full, other) in [(s, MOON), (m, SUN)] {
                if full.count_ones() as usize == n / 2 {
                    for &c in cells {
                        if g[c] == 0 {
                            emit!(c, other, li, Tech::Count);
                        }
                    }
                }
            }
            if !self.line_ok(g, li) {
                return Err(Contra::Line(li));
            }
        }
        for (k, e) in self.edges.iter().enumerate() {
            let (va, vb) = (g[e.a], g[e.b]);
            let want = |v: u8| if e.eq { v } else { opp(v) };
            if va != 0 && vb != 0 {
                if want(va) != vb {
                    return Err(Contra::Edge(k));
                }
            } else if va != 0 {
                let li = self.line_of(e.a, e.b);
                emit!(e.b, want(va), li, Tech::Sign(k));
            } else if vb != 0 {
                let li = self.line_of(e.a, e.b);
                emit!(e.a, want(vb), li, Tech::Sign(k));
            }
        }
        Ok((changed, None))
    }

    fn line_of(&self, a: usize, b: usize) -> usize {
        if a / self.n == b / self.n {
            a / self.n
        } else {
            self.n + a % self.n
        }
    }

    /// Line analysis of one line: (forced suns, forced moons) as position masks.
    fn analyze_line(&self, g: &[u8], li: usize) -> Result<(u16, u16), Contra> {
        let n = self.n;
        let full: u16 = ((1u32 << n) - 1) as u16;
        let inner: u16 = ((1u32 << (n - 1)) - 1) as u16;
        let (s, m) = self.masks(g, li);
        let LineInfo { eq, ne, .. } = self.lines[li];
        let (mut and, mut or, mut cnt) = (full, 0u16, 0u32);
        for &p in self.pats {
            if p & m != 0 || p & s != s {
                continue;
            }
            let d = (p ^ (p >> 1)) & inner;
            if d & eq != 0 || d & ne != ne {
                continue;
            }
            and &= p;
            or |= p;
            cnt += 1;
        }
        if cnt == 0 {
            return Err(Contra::Line(li));
        }
        Ok((and & !s, !or & full & !m))
    }

    /// Tier 2: line analysis over all lines.
    fn t2(&self, g: &mut [u8], apply: bool) -> Result<(bool, Option<Step>), Contra> {
        let n = self.n;
        let mut changed = false;
        for li in 0..2 * n {
            let (suns, moons) = self.analyze_line(g, li)?;
            if suns | moons == 0 {
                continue;
            }
            let (s, m) = self.masks(g, li);
            let half = (n / 2) as u32;
            let tech = Tech::LineAnalysis { suns_left: half - s.count_ones(), moons_left: half - m.count_ones() };
            for k in 0..n {
                let val = if suns >> k & 1 == 1 {
                    SUN
                } else if moons >> k & 1 == 1 {
                    MOON
                } else {
                    continue;
                };
                let c = self.lines[li].cells[k];
                if !apply {
                    return Ok((true, Some(Step { cell: c, val, line: li, tech })));
                }
                g[c] = val;
                changed = true;
            }
        }
        Ok((changed, None))
    }

    /// Tiers 1+2 to a fixpoint after `start` was just set, assuming the rest of `g` already was at
    /// a tier-1/2 fixpoint. Worklist over dirty lines; line analysis subsumes the tier-1 line rules.
    fn propagate_from(&self, g: &mut [u8], start: usize) -> Result<(), Contra> {
        let n = self.n;
        let mut dirty = vec![false; 2 * n];
        let mut stack: Vec<usize> = Vec::with_capacity(2 * n);
        let mut cells: Vec<usize> = vec![start];
        while let Some(c) = cells.pop() {
            for li in [c / n, n + c % n] {
                if !dirty[li] {
                    dirty[li] = true;
                    stack.push(li);
                }
            }
            for &k in &self.cell_edges[c] {
                let e = self.edges[k];
                let other = if e.a == c { e.b } else { e.a };
                let want = if e.eq { g[c] } else { opp(g[c]) };
                if g[other] == 0 {
                    g[other] = want;
                    cells.push(other);
                } else if g[other] != want {
                    return Err(Contra::Edge(k));
                }
            }
            if cells.is_empty() {
                while let Some(li) = stack.pop() {
                    dirty[li] = false;
                    let (suns, moons) = self.analyze_line(g, li)?;
                    if suns | moons == 0 {
                        continue;
                    }
                    for k in 0..n {
                        let c2 = self.lines[li].cells[k];
                        if suns >> k & 1 == 1 {
                            g[c2] = SUN;
                        } else if moons >> k & 1 == 1 {
                            g[c2] = MOON;
                        } else {
                            continue;
                        }
                        cells.push(c2);
                    }
                    if !cells.is_empty() {
                        break;
                    }
                }
            }
        }
        Ok(())
    }

    /// Tier 3: first empty cell (from `start`) where one value leads to a contradiction.
    fn t3(&self, g: &[u8], start: usize) -> Option<Step> {
        let nn = self.n * self.n;
        let mut buf = g.to_vec();
        for k in 0..nn {
            let c = (start + k) % nn;
            if g[c] != 0 {
                continue;
            }
            for v in [SUN, MOON] {
                buf.copy_from_slice(g);
                buf[c] = v;
                if let Err(contra) = self.propagate_from(&mut buf, c) {
                    return Some(Step { cell: c, val: opp(v), line: c / self.n, tech: Tech::Trial { tried: v, contra } });
                }
            }
        }
        None
    }

    /// Next single deduction (hint order: tier 1, tier 2, tier 3).
    fn next_step(&self, g: &[u8]) -> Option<Step> {
        let mut w = g.to_vec();
        if let Ok((_, Some(s))) = self.t1(&mut w, false) {
            return Some(s);
        }
        if let Ok((_, Some(s))) = self.t2(&mut w, false) {
            return Some(s);
        }
        self.t3(g, 0)
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Grade {
    pub max_tier: u8,
    pub t2_uses: u32,
    pub trials: u32,
}

/// Logic solve from the givens. `Some` only if fully solved with the allowed techniques.
fn logic_solve(ctx: &Ctx, givens: &[u8], max_tier: u8, max_trials: u32) -> Option<(Vec<u8>, Grade)> {
    let mut g = givens.to_vec();
    let mut grade = Grade { max_tier: 1, ..Default::default() };
    let mut cursor = 0;
    loop {
        loop {
            match ctx.t1(&mut g, true) {
                Err(_) => return None,
                Ok((false, _)) => break,
                Ok(_) => {}
            }
        }
        if g.iter().all(|&v| v != 0) {
            return Some((g, grade));
        }
        if max_tier >= 2 {
            match ctx.t2(&mut g, true) {
                Err(_) => return None,
                Ok((true, _)) => {
                    grade.t2_uses += 1;
                    grade.max_tier = grade.max_tier.max(2);
                    continue;
                }
                _ => {}
            }
        }
        if max_tier >= 3 && grade.trials < max_trials {
            if let Some(st) = ctx.t3(&g, cursor) {
                g[st.cell] = st.val;
                cursor = st.cell;
                grade.trials += 1;
                grade.max_tier = 3;
                continue;
            }
        }
        return None;
    }
}

/// Random valid full grid, row by row from shuffled valid line patterns with column checks.
fn random_full_grid(n: usize, rng: &mut Rng) -> Vec<u8> {
    let pats = line_patterns(n);
    let half = n / 2;
    let mut rows: Vec<u16> = Vec::with_capacity(n);
    let mut orders: Vec<Vec<u16>> = Vec::new();
    let mut idx: Vec<usize> = Vec::new();
    let col_ok = |rows: &[u16]| -> bool {
        let r = rows.len();
        for c in 0..n {
            let bit = |i: usize| (rows[i] >> c) & 1;
            let suns = (0..r).filter(|&i| bit(i) == 1).count();
            if suns > half || r - suns > half {
                return false;
            }
            if r >= 3 && bit(r - 1) == bit(r - 2) && bit(r - 2) == bit(r - 3) {
                return false;
            }
        }
        true
    };
    let mut guard = 0u32;
    loop {
        if rows.len() == n {
            break;
        }
        if idx.len() == rows.len() {
            let mut o = pats.clone();
            rng.shuffle(&mut o);
            orders.push(o);
            idx.push(0);
        }
        let d = rows.len();
        let mut placed = false;
        while idx[d] < orders[d].len() {
            let p = orders[d][idx[d]];
            idx[d] += 1;
            rows.push(p);
            if col_ok(&rows) {
                placed = true;
                break;
            }
            rows.pop();
        }
        if !placed {
            orders.pop();
            idx.pop();
            rows.pop();
        }
        guard += 1;
        assert!(guard < 1_000_000, "grid generation runaway");
    }
    let mut g = vec![0u8; n * n];
    for (r, &p) in rows.iter().enumerate() {
        for c in 0..n {
            g[r * n + c] = if (p >> c) & 1 == 1 { SUN } else { MOON };
        }
    }
    g
}

fn all_edges(n: usize) -> Vec<(usize, usize)> {
    let mut v = Vec::new();
    for r in 0..n {
        for c in 0..n {
            if c + 1 < n {
                v.push((r * n + c, r * n + c + 1));
            }
            if r + 1 < n {
                v.push((r * n + c, (r + 1) * n + c));
            }
        }
    }
    v
}

#[derive(Clone, Copy)]
enum Clue {
    Given(usize),
    Edge(usize),
}

/// Greedy clue removal from (all givens + `p.edges` random signs).
fn reduce(sol: &[u8], p: &Params, rng: &mut Rng) -> (Puzzle, Grade) {
    let n = p.size;
    let mut pool = all_edges(n);
    rng.shuffle(&mut pool);
    pool.truncate(p.edges);
    let edges: Vec<Edge> = pool.iter().map(|&(a, b)| Edge { a, b, eq: sol[a] == sol[b] }).collect();
    let mut edge_on = vec![true; edges.len()];
    let mut givens = sol.to_vec();

    let mut order: Vec<(f64, Clue)> = (0..n * n).map(|i| (rng.f64() + p.given_bias, Clue::Given(i))).collect();
    for k in 0..edges.len() {
        order.push((rng.f64(), Clue::Edge(k)));
    }
    order.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap());

    let active = |edge_on: &[bool]| -> Vec<Edge> {
        edges.iter().zip(edge_on).filter(|(_, &on)| on).map(|(e, _)| *e).collect()
    };
    // Phase 1 with at most tier 2 (cheap), phase 2 with the full allowance.
    let phases: Vec<u8> = if p.max_tier >= 3 { vec![2, 3] } else { vec![p.max_tier] };
    for &tier in &phases {
        for &(_, clue) in &order {
            match clue {
                Clue::Given(i) => {
                    if givens[i] == 0 {
                        continue;
                    }
                    givens[i] = 0;
                }
                Clue::Edge(k) => {
                    if !edge_on[k] {
                        continue;
                    }
                    edge_on[k] = false;
                }
            }
            let ctx = Ctx::new(n, &active(&edge_on));
            if logic_solve(&ctx, &givens, tier, p.max_trials).is_none() {
                match clue {
                    Clue::Given(i) => givens[i] = sol[i],
                    Clue::Edge(k) => edge_on[k] = true,
                }
            }
        }
    }
    let edges = active(&edge_on);
    let ctx = Ctx::new(n, &edges);
    let (solved, grade) = logic_solve(&ctx, &givens, p.max_tier, p.max_trials).expect("reduced puzzle solvable");
    debug_assert_eq!(solved, sol);
    (Puzzle { n, givens, edges, solution: sol.to_vec() }, grade)
}

/// Deterministic puzzle for a level. A few seeded attempts; prefer one that actually needs the
/// level's top technique.
pub fn generate(level: u32) -> (Puzzle, Grade) {
    let p = params(level);
    let mut best: Option<(Puzzle, Grade)> = None;
    for attempt in 0..4 {
        let mut rng = Rng::new(seed_for("sun_moon", level, attempt));
        let sol = random_full_grid(p.size, &mut rng);
        let (puz, grade) = reduce(&sol, &p, &mut rng);
        let score = |g: &Grade| g.max_tier as u32 * 1000 + g.trials * 10 + g.t2_uses;
        if grade.max_tier >= p.max_tier {
            return (puz, grade);
        }
        if best.as_ref().map_or(true, |(_, b)| score(&grade) > score(b)) {
            best = Some((puz, grade));
        }
    }
    best.unwrap()
}

fn line_name(n: usize, li: usize) -> String {
    if li < n {
        format!("{}. satır", li + 1)
    } else {
        format!("{}. sütun", li - n + 1)
    }
}

fn cap(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

fn step_text(n: usize, st: &Step) -> String {
    let l = line_name(n, st.line);
    let y = vname(st.val);
    let x = vname(opp(st.val));
    match st.tech {
        Tech::Pair => format!("Çift kuralı — {l}: yan yana iki {x} var; üçüncüsü gelemez, bu hücre {y}."),
        Tech::Sandwich => {
            format!("Sandviç — {l}: iki {x} arasında tek boşluk var; araya {x} gelirse üçlü olur, bu hücre {y}.")
        }
        Tech::Count => format!(
            "Sayı tamamlama — {l}: {} {x} tamamlandı, kalan hücrelerin hepsi {y}.",
            n / 2
        ),
        Tech::Sign(_) => format!("İşaret — komşusuyla arasındaki =/× işareti bu hücreyi belirliyor: {y}."),
        Tech::LineAnalysis { suns_left, moons_left } => format!(
            "Satır analizi — {}: daha {suns_left} güneş ve {moons_left} ay yerleşecek. Bunları üçlü oluşturmadan \
             ve işaretleri bozmadan dizmenin her yolunda bu hücre {y} oluyor.",
            cap(&l)
        ),
        Tech::Trial { tried, contra } => {
            let at = match contra {
                Contra::Line(li) => format!("{} kuralları bozuluyor", line_name(n, li)),
                Contra::Edge(_) => "bir =/× işareti bozuluyor".to_string(),
            };
            format!(
                "Deneme ile çelişki — buraya {} koyarsan zincirleme çıkarımlar sonunda {at}. O halde bu hücre {y}.",
                vname(tried)
            )
        }
    }
}

fn sign_text(e: &Edge, known: u8, val: u8) -> String {
    if e.eq {
        format!("İşaret — = işareti iki hücrenin aynı olduğunu söyler; komşu {}, bu hücre de {}.", vname(known), vname(val))
    } else {
        format!("İşaret — × işareti zıtlık demek; komşu {}, bu hücre {}.", vname(known), vname(val))
    }
}

pub struct SunMoon {
    puz: Puzzle,
    grade: Grade,
    ctx: Ctx,
    grid: Vec<u8>,
    history: Vec<(usize, u8)>,
    hints: u32,
    mistakes: u32,
    last_cell: Option<usize>,
    hint: Option<(usize, u8, String)>,
}

impl SunMoon {
    pub fn new(level: u32) -> Self {
        let (puz, grade) = generate(level);
        let ctx = Ctx::new(puz.n, &puz.edges);
        let grid = puz.givens.clone();
        SunMoon { puz, grade, ctx, grid, history: vec![], hints: 0, mistakes: 0, last_cell: None, hint: None }
    }

    fn n(&self) -> usize {
        self.puz.n
    }

    fn solved(&self) -> bool {
        self.grid == self.puz.solution
    }

    fn stars(&self) -> u32 {
        if !self.solved() {
            0
        } else if self.hints + self.mistakes == 0 {
            3
        } else if self.hints + self.mistakes <= 3 {
            2
        } else {
            1
        }
    }

    /// Count a mistake if the cell we are leaving holds a wrong symbol.
    fn settle(&mut self, next: Option<usize>) {
        if let Some(c) = self.last_cell {
            if Some(c) != next && self.grid[c] != 0 && self.grid[c] != self.puz.solution[c] {
                self.mistakes += 1;
            }
        }
        self.last_cell = next;
    }

    fn set_cell(&mut self, i: usize, v: u8) -> Result<(), String> {
        if self.solved() {
            return Err("Bölüm bitti".into());
        }
        if i >= self.grid.len() {
            return Err("Geçersiz hücre".into());
        }
        if v > MOON {
            return Err("Geçersiz değer".into());
        }
        if self.puz.givens[i] != 0 {
            return Err("Bu hücre sabit".into());
        }
        if self.grid[i] == v {
            return Ok(());
        }
        self.settle(Some(i));
        self.history.push((i, self.grid[i]));
        self.grid[i] = v;
        self.hint = None;
        if self.solved() {
            self.last_cell = None;
        }
        Ok(())
    }

    /// Rule breaks of grid `g`: (cells, rows, cols, edges).
    fn violations(&self, g: &[u8]) -> (Vec<usize>, Vec<usize>, Vec<usize>, Vec<usize>) {
        let n = self.n();
        let mut bad = vec![false; n * n];
        let (mut rows, mut cols) = (vec![], vec![]);
        for li in 0..2 * n {
            let cells = &self.ctx.lines[li].cells;
            for i in 0..n - 2 {
                let v = g[cells[i]];
                if v != 0 && v == g[cells[i + 1]] && v == g[cells[i + 2]] {
                    for k in 0..3 {
                        bad[cells[i + k]] = true;
                    }
                }
            }
            let (s, m) = self.ctx.masks(g, li);
            if s.count_ones() as usize > n / 2 || m.count_ones() as usize > n / 2 {
                if li < n {
                    rows.push(li);
                } else {
                    cols.push(li - n);
                }
            }
        }
        let mut bad_edges = vec![];
        for (k, e) in self.puz.edges.iter().enumerate() {
            let (a, b) = (g[e.a], g[e.b]);
            if a != 0 && b != 0 && (a == b) != e.eq {
                bad_edges.push(k);
                bad[e.a] = true;
                bad[e.b] = true;
            }
        }
        let cells = (0..n * n).filter(|&i| bad[i]).collect();
        (cells, rows, cols, bad_edges)
    }

    fn do_hint(&mut self) -> Result<(), String> {
        if self.solved() {
            return Err("Bölüm bitti".into());
        }
        self.settle(None);
        self.hints += 1;
        // A wrong symbol on the board first: point at it and clear it.
        if let Some(i) = (0..self.grid.len()).find(|&i| self.grid[i] != 0 && self.grid[i] != self.puz.solution[i]) {
            let wrong = self.grid[i];
            self.history.push((i, wrong));
            self.grid[i] = 0;
            let text = format!("Bu hücredeki {} yanlış — çözümle çelişiyor, kaldırdım. Buradan devam et.", vname(wrong));
            self.hint = Some((i, 0, text));
            return Ok(());
        }
        let (cell, val, text) = match self.ctx.next_step(&self.grid) {
            Some(st) => {
                let text = match st.tech {
                    Tech::Sign(k) => {
                        let e = self.puz.edges[k];
                        let other = if e.a == st.cell { e.b } else { e.a };
                        sign_text(&e, self.grid[other], st.val)
                    }
                    _ => step_text(self.n(), &st),
                };
                (st.cell, st.val, text)
            }
            None => {
                let i = (0..self.grid.len()).find(|&i| self.grid[i] == 0).ok_or("Boş hücre yok")?;
                let v = self.puz.solution[i];
                (i, v, format!("Bu hücre çözümde {}.", vname(v)))
            }
        };
        debug_assert_eq!(val, self.puz.solution[cell]);
        self.history.push((cell, self.grid[cell]));
        self.grid[cell] = val;
        self.hint = Some((cell, val, text));
        Ok(())
    }

    fn label(&self) -> &'static str {
        match self.grade.max_tier {
            1 => "Doğrudan",
            2 => "Analiz",
            _ => "Deneme",
        }
    }
}

impl Session for SunMoon {
    fn state(&self) -> Value {
        let n = self.n();
        let (bad_cells, bad_rows, bad_cols, bad_edges) = self.violations(&self.grid);
        // Same check with the cell being edited blanked out (see module docs).
        let deferred = self.last_cell.filter(|_| !self.solved()).map(|c| {
            let mut g = self.grid.clone();
            g[c] = 0;
            let (cells, rows, cols, edges) = self.violations(&g);
            json!({"cell": c, "bad_cells": cells, "bad_rows": rows, "bad_cols": cols, "bad_edges": edges})
        });
        let status = if self.solved() { "won" } else { "playing" };
        let filled = self.grid.iter().filter(|&&v| v != 0).count();
        json!({
            "status": status,
            "stars": self.stars(),
            "title": format!("{n}×{n} · {}", self.label()),
            "goal": "Her satır ve sütunda eşit güneş ve ay · üç aynı yan yana gelmez",
            "size": n,
            "cells": self.grid,
            "fixed": self.puz.givens.iter().map(|&v| v != 0).collect::<Vec<_>>(),
            "edges": self.puz.edges.iter().map(|e| json!([e.a, e.b, if e.eq { "=" } else { "x" }])).collect::<Vec<_>>(),
            "bad_cells": bad_cells,
            "bad_rows": bad_rows,
            "bad_cols": bad_cols,
            "bad_edges": bad_edges,
            "deferred": deferred,
            "hint": self.hint.as_ref().map(|(c, v, t)| json!({"cell": c, "value": v, "text": t})),
            "hints": self.hints,
            "mistakes": self.mistakes,
            "filled": filled,
            "total": n * n,
            "can_undo": !self.history.is_empty() && !self.solved(),
            "summary": format!("İpucu: {} · Hata: {}", self.hints, self.mistakes),
        })
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if a["undo"].as_bool() == Some(true) {
            if self.solved() {
                return Err("Bölüm bitti".into());
            }
            let (i, prev) = self.history.pop().ok_or("Geri alınacak hamle yok")?;
            self.settle(None);
            self.grid[i] = prev;
            self.hint = None;
            return Ok(());
        }
        if a["hint"].as_bool() == Some(true) {
            return self.do_hint();
        }
        if let Some(i) = a["cycle"].as_u64() {
            let i = i as usize;
            let cur = *self.grid.get(i).ok_or("Geçersiz hücre")?;
            return self.set_cell(i, (cur + 1) % 3);
        }
        if let Some(i) = a["set"].as_u64() {
            let v = a["value"].as_u64().ok_or("value eksik")?;
            return self.set_cell(i as usize, v.min(255) as u8);
        }
        Err("Bilinmeyen hamle".into())
    }
}

pub fn create(level: u32, mode: &str) -> Result<Box<dyn Session>, String> {
    if mode == "endless" {
        return Err("Güneş & Ay'da sonsuz mod yok".into());
    }
    Ok(Box::new(SunMoon::new(level)))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Brute-force solution counter (stops at `limit`), independent of the logic solver.
    fn count_solutions(p: &Puzzle, limit: usize) -> usize {
        let n = p.n;
        let full: u16 = ((1u32 << n) - 1) as u16;
        // Per row: valid line patterns that respect the givens and the horizontal signs.
        let mut row_pats: Vec<Vec<u16>> = Vec::new();
        // Per row r ≥ 1: vertical "=" / "×" masks between row r-1 and row r.
        let (mut eqv, mut nev) = (vec![0u16; n], vec![0u16; n]);
        for e in &p.edges {
            if e.b / n != e.a / n {
                let (r, c) = (e.b / n, e.b % n);
                if e.eq {
                    eqv[r] |= 1 << c;
                } else {
                    nev[r] |= 1 << c;
                }
            }
        }
        for r in 0..n {
            let ok: Vec<u16> = line_patterns(n)
                .into_iter()
                .filter(|&pat| {
                    let val = |c: usize| if (pat >> c) & 1 == 1 { SUN } else { MOON };
                    (0..n).all(|c| p.givens[r * n + c] == 0 || p.givens[r * n + c] == val(c))
                        && p.edges.iter().filter(|e| e.a / n == r && e.b / n == r).all(|e| {
                            (val(e.a % n) == val(e.b % n)) == e.eq
                        })
                })
                .collect();
            row_pats.push(ok);
        }
        struct S<'a> {
            n: usize,
            full: u16,
            row_pats: &'a [Vec<u16>],
            eqv: &'a [u16],
            nev: &'a [u16],
            rows: Vec<u16>,
            suns: Vec<usize>,
        }
        fn rec(s: &mut S, limit: usize) -> usize {
            let (n, r) = (s.n, s.rows.len());
            if r == n {
                return 1;
            }
            let mut total = 0;
            for k in 0..s.row_pats[r].len() {
                let pat = s.row_pats[r][k];
                if r >= 1 {
                    let d = s.rows[r - 1] ^ pat;
                    if d & s.eqv[r] != 0 || d & s.nev[r] != s.nev[r] {
                        continue;
                    }
                }
                if r >= 2 {
                    let (a, b) = (s.rows[r - 2], s.rows[r - 1]);
                    if a & b & pat != 0 || !a & !b & !pat & s.full != 0 {
                        continue;
                    }
                }
                if (0..n).any(|c| {
                    let sun = s.suns[c] + ((pat >> c) & 1) as usize;
                    sun > n / 2 || r + 1 - sun > n / 2
                }) {
                    continue;
                }
                for c in 0..n {
                    s.suns[c] += ((pat >> c) & 1) as usize;
                }
                s.rows.push(pat);
                total += rec(s, limit - total);
                s.rows.pop();
                for c in 0..n {
                    s.suns[c] -= ((pat >> c) & 1) as usize;
                }
                if total >= limit {
                    break;
                }
            }
            total
        }
        let mut s = S { n, full, row_pats: &row_pats, eqv: &eqv, nev: &nev, rows: vec![], suns: vec![0; n] };
        rec(&mut s, limit)
    }


    const LEVELS: [u32; 9] = [1, 2, 3, 50, 137, 250, 400, 499, 500];

    #[test]
    fn sun_moon_line_pattern_counts() {
        assert_eq!(line_patterns(6).len(), 14);
        assert_eq!(line_patterns(8).len(), 34);
        // The brute-force counter sees many grids when there are no clues, one with the full grid.
        let (p, _) = generate(1);
        let empty = Puzzle { givens: vec![0; 36], edges: vec![], ..p.clone() };
        assert_eq!(count_solutions(&empty, 5), 5);
        let full = Puzzle { givens: p.solution.clone(), ..p };
        assert_eq!(count_solutions(&full, 5), 1);
    }

    #[test]
    fn sun_moon_levels_generate_unique() {
        for level in LEVELS {
            let (p, g) = generate(level);
            let pr = params(level);
            assert_eq!(p.n, pr.size);
            assert!(g.max_tier <= pr.max_tier);
            assert_eq!(count_solutions(&p, 2), 1, "level {level} not unique");
            let ctx = Ctx::new(p.n, &p.edges);
            let (s, _) = logic_solve(&ctx, &p.givens, pr.max_tier, pr.max_trials).expect("logic solvable");
            assert_eq!(s, p.solution);
        }
    }

    #[test]
    fn sun_moon_deterministic() {
        for level in [1, 137, 400] {
            let (a, _) = generate(level);
            let (b, _) = generate(level);
            assert_eq!(a.givens, b.givens);
            assert_eq!(a.edges, b.edges);
        }
    }

    #[test]
    fn sun_moon_illegal_actions_rejected() {
        let mut g = SunMoon::new(1);
        let fixed = (0..36).find(|&i| g.puz.givens[i] != 0).unwrap();
        let before = g.state();
        assert!(g.act(&json!({"cycle": fixed})).is_err());
        assert!(g.act(&json!({"cycle": 99})).is_err());
        assert!(g.act(&json!({"set": 0, "value": 7})).is_err());
        assert!(g.act(&json!({"undo": true})).is_err());
        assert!(g.act(&json!({"bogus": 1})).is_err());
        assert_eq!(before, g.state());
    }

    #[test]
    fn sun_moon_solution_wins_three_stars() {
        for level in [1, 137] {
            let mut g = SunMoon::new(level);
            let sol = g.puz.solution.clone();
            for (i, &v) in sol.iter().enumerate() {
                if g.puz.givens[i] == 0 {
                    g.act(&json!({"set": i, "value": v})).unwrap();
                }
            }
            let st = g.state();
            assert_eq!(st["status"], "won");
            assert_eq!(st["stars"], 3);
        }
    }

    #[test]
    fn sun_moon_cycle_is_free_but_leaving_wrong_counts() {
        let mut g = SunMoon::new(2);
        let i = (0..36).find(|&i| g.puz.givens[i] == 0).unwrap();
        let j = (0..36).rev().find(|&i| g.puz.givens[i] == 0).unwrap();
        // Cycle to the correct value (may pass through the wrong one).
        while g.grid[i] != g.puz.solution[i] {
            g.act(&json!({"cycle": i})).unwrap();
        }
        g.act(&json!({"set": j, "value": opp(g.puz.solution[j])})).unwrap();
        assert_eq!(g.mistakes, 0);
        g.act(&json!({"cycle": i})).unwrap(); // leave j wrong
        assert_eq!(g.mistakes, 1);
    }

    #[test]
    fn sun_moon_hints_solve() {
        for level in [1, 60, 400] {
            let mut g = SunMoon::new(level);
            let mut guard = 0;
            while g.state()["status"] == "playing" {
                g.act(&json!({"hint": true})).unwrap();
                let h = g.hint.clone().unwrap();
                assert!(!h.2.is_empty());
                guard += 1;
                assert!(guard < 200);
            }
            assert_eq!(g.state()["stars"], 1);
        }
    }

    #[test]
    fn sun_moon_violations_reported() {
        let mut g = SunMoon::new(1);
        // Put sun in every empty cell of row 0 → count overflow / triples likely.
        for c in 0..6 {
            if g.puz.givens[c] == 0 {
                g.act(&json!({"set": c, "value": SUN})).unwrap();
            }
        }
        let st = g.state();
        let suns = (0..6).filter(|&c| g.grid[c] == SUN).count();
        if suns > 3 {
            assert!(st["bad_rows"].as_array().unwrap().contains(&json!(0)));
        }
    }

    #[test]
    fn sun_moon_deferred_hides_only_the_edited_cell() {
        let mut g = SunMoon::new(1);
        let n = 6;
        let breaks = |g: &SunMoon, t: &[u8]| {
            let (c, r, k, e) = g.violations(t);
            c.len() + r.len() + k.len() + e.len()
        };
        // Find an empty cell where one symbol breaks a rule.
        let mut found = None;
        'search: for i in 0..36 {
            if g.puz.givens[i] != 0 {
                continue;
            }
            for v in [SUN, MOON] {
                let mut t = g.grid.clone();
                t[i] = v;
                if breaks(&g, &t) > 0 {
                    found = Some((i, v));
                    break 'search;
                }
            }
        }
        let (i, v) = found.expect("some cell can break a rule");
        g.act(&json!({"set": i, "value": v})).unwrap();
        let st = g.state();
        let count = |d: &Value| ["bad_cells", "bad_rows", "bad_cols", "bad_edges"].iter().map(|k| d[*k].as_array().unwrap().len()).sum::<usize>();
        assert!(count(&st) > 0);
        assert_eq!(st["deferred"]["cell"], i);
        assert_eq!(count(&st["deferred"]), 0, "breaks of the edited cell are held back");
        assert_eq!(g.mistakes, 0, "the intermediate state is not a mistake yet");
        // Moving on to another cell (outside i's lines) reveals the break in the deferred view too.
        let j = (0..36).find(|&j| g.puz.givens[j] == 0 && j / n != i / n && j % n != i % n).unwrap();
        g.act(&json!({"cycle": j})).unwrap();
        let st = g.state();
        assert_eq!(st["deferred"]["cell"], j);
        assert!(count(&st["deferred"]) > 0);
        // A hint ends the edit: nothing is deferred any more.
        g.act(&json!({"hint": true})).unwrap();
        assert!(g.state()["deferred"].is_null());
    }

    #[test]
    #[ignore]
    fn sun_moon_timing_all_levels() {
        let t0 = std::time::Instant::now();
        let mut worst = (0u128, 0u32);
        let mut tiers = [0u32; 4];
        for level in 1..=500 {
            let t = std::time::Instant::now();
            let (_, g) = generate(level);
            tiers[g.max_tier as usize] += 1;
            let ms = t.elapsed().as_millis();
            if ms > worst.0 {
                worst = (ms, level);
            }
        }
        println!("sun_moon: 500 levels in {:?}, worst {} ms (level {}), tiers {:?}", t0.elapsed(), worst.0, worst.1, tiers);
    }
}
