//! Shikaku — divide the grid into rectangles; every rectangle holds exactly one number, equal to
//! its area.
//!
//! Generation: a seeded random partition (row-major sweep; each new rectangle's area is drawn
//! around a level-dependent mean, long 1×k slivers and 1×1 cells are discouraged, partitions with
//! too many 1×1 cells are rejected). Each rectangle gets its area number on a random cell. The
//! puzzle is accepted only if the logic solver below solves it completely with the techniques the
//! level allows — logic deductions are sound, so acceptance implies a **unique** solution (tests
//! re-check with an exact-cover counter). If logic gets stuck, the number of one unresolved
//! rectangle is moved to another cell of that rectangle (bounded repairs), then a new partition is
//! tried.
//!
//! Techniques (tiers), also used for hints:
//! 1. "Tek seçenek" — a number has exactly one candidate rectangle left.
//! 2. "Tek kapsayan" — an empty cell can only be reached by one number → that number's rectangle
//!    must contain it.
//! 3. "Ortak çekirdek" — cells shared by every candidate of a number belong to it; other numbers'
//!    candidates through them die.
//! 4. "Deneme" — a candidate that would leave another number without room, or a cell that nobody
//!    can cover, dies.
//!
//! Level curve (`params`): 7×7 (L1), 8×8 (L2–20), 9×9, 10×10, 11×11, then 12×12 / 12×10 tall,
//! 13×13 / 14×11, 15×15 / 16×12 and finally 15×15 / 18×12 from level 401. Mean rectangle area grows
//! from ~4 to ~7.5, so candidates get more ambiguous; tier 4 is allowed from level 31, and from
//! level 100 the most ambiguous of several valid puzzles is chosen.
//!
//! Overlap policy: placing a rectangle **replaces** every rectangle it overlaps (drawing over is
//! the natural way to fix a mistake). Rectangles that don't match a number are allowed and shown
//! as invalid.
//!
//! Stars: a *mistake* = placing a rectangle that is not part of the solution; every hint counts
//! once. hints + mistakes = 0 → 3★, ≤ 3 → 2★, otherwise 1★.
//!
//! State: `{status, stars, title, goal, rows, cols, clues:[[r,c,n]], rects:[{r0,c0,r1,c1,ok}],
//!          covered, total, hint:{rect:[r0,c0,r1,c1],text}|null, hints, mistakes, can_undo, summary}`
//! Actions: `{"place":[r0,c0,r1,c1]}` (any two opposite corners) · `{"remove_at":[r,c]}` ·
//!          `{"remove":k}` · `{"undo":true}` · `{"hint":true}`

use crate::rng::{seed_for, Rng};
use crate::Session;
use serde_json::{json, Value};

type Bits = [u64; 4];
const MAX_CELLS: usize = 256;

fn bset(b: &mut Bits, i: usize) {
    b[i >> 6] |= 1 << (i & 63);
}
fn bget(b: &Bits, i: usize) -> bool {
    b[i >> 6] >> (i & 63) & 1 == 1
}
fn overlaps(a: &Bits, b: &Bits) -> bool {
    (a[0] & b[0]) | (a[1] & b[1]) | (a[2] & b[2]) | (a[3] & b[3]) != 0
}
fn bor(a: &mut Bits, b: &Bits) {
    for k in 0..4 {
        a[k] |= b[k];
    }
}
fn band(a: &mut Bits, b: &Bits) {
    for k in 0..4 {
        a[k] &= b[k];
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Hash)]
pub struct Rect {
    pub r0: usize,
    pub c0: usize,
    pub r1: usize,
    pub c1: usize,
}

impl Rect {
    fn area(&self) -> usize {
        (self.r1 - self.r0 + 1) * (self.c1 - self.c0 + 1)
    }
    fn contains(&self, r: usize, c: usize) -> bool {
        r >= self.r0 && r <= self.r1 && c >= self.c0 && c <= self.c1
    }
    fn bits(&self, cols: usize) -> Bits {
        let mut b = [0u64; 4];
        for r in self.r0..=self.r1 {
            for c in self.c0..=self.c1 {
                bset(&mut b, r * cols + c);
            }
        }
        b
    }
    fn overlaps(&self, o: &Rect) -> bool {
        self.r0 <= o.r1 && o.r0 <= self.r1 && self.c0 <= o.c1 && o.c0 <= self.c1
    }
    fn json(&self) -> Value {
        json!([self.r0, self.c0, self.r1, self.c1])
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Params {
    pub rows: usize,
    pub cols: usize,
    pub mean_area: f64,
    pub max_area: usize,
    pub max_tier: u8,
    /// Valid puzzles generated per level; the most ambiguous one wins.
    pub picks: u32,
}

/// Level → generator parameters (see module docs).
pub fn params(level: u32) -> Params {
    let l = level.clamp(1, 500);
    let alt = l % 2 == 0;
    let (rows, cols) = match l {
        1 => (7, 7),
        2..=20 => (8, 8),
        21..=60 => (9, 9),
        61..=110 => (10, 10),
        111..=170 => (11, 11),
        171..=240 => {
            if alt {
                (12, 10)
            } else {
                (12, 12)
            }
        }
        241..=320 => {
            if alt {
                (14, 11)
            } else {
                (13, 13)
            }
        }
        321..=400 => {
            if alt {
                (16, 12)
            } else {
                (15, 15)
            }
        }
        _ => {
            if alt {
                (18, 12)
            } else {
                (15, 15)
            }
        }
    };
    let t = (l - 1) as f64 / 499.0;
    let mean_area = 4.6 + 4.6 * t.powf(0.8);
    let max_area = ((mean_area * 2.3).round() as usize).clamp(10, 26);
    let max_tier = match l {
        1 => 2,
        2..=30 => 3,
        _ => 4,
    };
    let picks = 4 + (l / 30).min(14);
    Params { rows, cols, mean_area, max_area, max_tier, picks }
}

#[derive(Clone, Debug)]
pub struct Puzzle {
    pub rows: usize,
    pub cols: usize,
    /// (cell, number)
    pub clues: Vec<(usize, usize)>,
    /// solution[k] = rectangle of clue k
    pub solution: Vec<Rect>,
}

/// Random partition of the grid into rectangles.
fn partition(p: &Params, rng: &mut Rng) -> Option<Vec<Rect>> {
    let (rows, cols) = (p.rows, p.cols);
    let mut owner = vec![false; rows * cols];
    let mut rects = Vec::new();
    let sd = p.mean_area * 0.6;
    for r in 0..rows {
        for c in 0..cols {
            if owner[r * cols + c] {
                continue;
            }
            let mut max_w = 0;
            while c + max_w < cols && !owner[r * cols + c + max_w] {
                max_w += 1;
            }
            let mut opts: Vec<(f64, usize, usize)> = Vec::new();
            for w in 1..=max_w.min(p.max_area) {
                let mut h = 1;
                loop {
                    let a = w * h;
                    if a > p.max_area {
                        break;
                    }
                    let mut weight = (-((a as f64 - p.mean_area).powi(2)) / (2.0 * sd * sd)).exp();
                    if a == 1 {
                        weight *= 0.12;
                    }
                    if w.min(h) == 1 && w.max(h) >= 5 {
                        weight *= 0.3;
                    }
                    opts.push((weight, w, h));
                    if r + h >= rows || (0..w).any(|k| owner[(r + h) * cols + c + k]) {
                        break;
                    }
                    h += 1;
                }
            }
            let total: f64 = opts.iter().map(|o| o.0).sum();
            let mut x = rng.f64() * total;
            let mut pick = opts[0];
            for o in &opts {
                if x < o.0 {
                    pick = *o;
                    break;
                }
                x -= o.0;
            }
            let (_, w, h) = pick;
            for rr in r..r + h {
                for cc in c..c + w {
                    owner[rr * cols + cc] = true;
                }
            }
            rects.push(Rect { r0: r, c0: c, r1: r + h - 1, c1: c + w - 1 });
        }
    }
    let ones = rects.iter().filter(|r| r.area() == 1).count();
    if ones > (rows * cols / 35).max(1) {
        return None;
    }
    Some(rects)
}

#[derive(Clone, Copy, Debug)]
struct Cand {
    rect: Rect,
    bits: Bits,
    clue: usize,
}

/// Candidate rectangles for every clue.
struct Space {
    rows: usize,
    cols: usize,
    clue_cells: Vec<usize>,
    clue_nums: Vec<usize>,
    cands: Vec<Cand>,
    by_clue: Vec<Vec<usize>>,
    by_cell: Vec<Vec<usize>>,
    all: Bits,
}

impl Space {
    fn new(rows: usize, cols: usize, clues: &[(usize, usize)]) -> Self {
        // Prefix sums of clue counts for O(1) "exactly one clue inside".
        let mut pre = vec![0i32; (rows + 1) * (cols + 1)];
        let mut is_clue = vec![false; rows * cols];
        for &(cell, _) in clues {
            is_clue[cell] = true;
        }
        for r in 0..rows {
            for c in 0..cols {
                pre[(r + 1) * (cols + 1) + c + 1] = pre[r * (cols + 1) + c + 1] + pre[(r + 1) * (cols + 1) + c]
                    - pre[r * (cols + 1) + c]
                    + is_clue[r * cols + c] as i32;
            }
        }
        let count = |rc: &Rect| {
            pre[(rc.r1 + 1) * (cols + 1) + rc.c1 + 1] - pre[rc.r0 * (cols + 1) + rc.c1 + 1] - pre[(rc.r1 + 1) * (cols + 1) + rc.c0]
                + pre[rc.r0 * (cols + 1) + rc.c0]
        };
        let mut cands = Vec::new();
        let mut by_clue = vec![vec![]; clues.len()];
        let mut by_cell = vec![vec![]; rows * cols];
        for (k, &(cell, n)) in clues.iter().enumerate() {
            let (r, c) = (cell / cols, cell % cols);
            for h in 1..=n.min(rows) {
                if n % h != 0 || n / h > cols {
                    continue;
                }
                let w = n / h;
                for r0 in r.saturating_sub(h - 1)..=r {
                    if r0 + h > rows {
                        continue;
                    }
                    for c0 in c.saturating_sub(w - 1)..=c {
                        if c0 + w > cols {
                            continue;
                        }
                        let rect = Rect { r0, c0, r1: r0 + h - 1, c1: c0 + w - 1 };
                        if count(&rect) != 1 {
                            continue;
                        }
                        let id = cands.len();
                        cands.push(Cand { rect, bits: rect.bits(cols), clue: k });
                        by_clue[k].push(id);
                        for rr in rect.r0..=rect.r1 {
                            for cc in rect.c0..=rect.c1 {
                                by_cell[rr * cols + cc].push(id);
                            }
                        }
                    }
                }
            }
        }
        let mut all = [0u64; 4];
        for i in 0..rows * cols {
            bset(&mut all, i);
        }
        Space {
            rows,
            cols,
            clue_cells: clues.iter().map(|c| c.0).collect(),
            clue_nums: clues.iter().map(|c| c.1).collect(),
            cands,
            by_clue,
            by_cell,
            all,
        }
    }
}

#[derive(Clone)]
struct LState {
    alive: Vec<bool>,
    placed: Vec<Option<usize>>,
    covered: Bits,
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Tech {
    OnlyCover { cell: usize, clue: usize },
    Core { clue: usize },
    Lookahead { clue: usize },
}

impl Tech {
    fn tier(&self) -> u8 {
        match self {
            Tech::OnlyCover { .. } => 2,
            Tech::Core { .. } => 3,
            Tech::Lookahead { .. } => 4,
        }
    }
}

enum Event {
    Place { clue: usize },
    Eliminate(Tech),
}

impl LState {
    fn new(sp: &Space) -> Self {
        LState { alive: vec![true; sp.cands.len()], placed: vec![None; sp.clue_cells.len()], covered: [0; 4] }
    }

    fn place(&mut self, sp: &Space, cand: usize) {
        let c = sp.cands[cand];
        self.placed[c.clue] = Some(cand);
        bor(&mut self.covered, &c.bits);
        for &o in &sp.by_clue[c.clue] {
            self.alive[o] = o == cand;
        }
        for (i, oc) in sp.cands.iter().enumerate() {
            if self.alive[i] && oc.clue != c.clue && overlaps(&oc.bits, &c.bits) {
                self.alive[i] = false;
            }
        }
    }

    /// One deduction step (lowest tier first). Err(()) = contradiction.
    fn step(&mut self, sp: &Space, max_tier: u8) -> Result<Option<Event>, ()> {
        // Tier 1: single option.
        for k in 0..sp.clue_cells.len() {
            if self.placed[k].is_some() {
                continue;
            }
            let mut it = sp.by_clue[k].iter().filter(|&&i| self.alive[i]);
            match (it.next(), it.next()) {
                (None, _) => return Err(()),
                (Some(&i), None) => {
                    self.place(sp, i);
                    return Ok(Some(Event::Place { clue: k }));
                }
                _ => {}
            }
        }
        if max_tier < 2 {
            return Ok(None);
        }
        // Tier 2: only one number reaches an empty cell.
        for cell in 0..sp.rows * sp.cols {
            if bget(&self.covered, cell) {
                continue;
            }
            let mut owner = None;
            let mut multi = false;
            for &i in &sp.by_cell[cell] {
                if !self.alive[i] {
                    continue;
                }
                let k = sp.cands[i].clue;
                match owner {
                    None => owner = Some(k),
                    Some(o) if o != k => {
                        multi = true;
                        break;
                    }
                    _ => {}
                }
            }
            let Some(k) = owner else { return Err(()) };
            if multi {
                continue;
            }
            let mut killed = false;
            for &i in &sp.by_clue[k] {
                if self.alive[i] && !bget(&sp.cands[i].bits, cell) {
                    self.alive[i] = false;
                    killed = true;
                }
            }
            if killed {
                return Ok(Some(Event::Eliminate(Tech::OnlyCover { cell, clue: k })));
            }
        }
        if max_tier < 3 {
            return Ok(None);
        }
        // Tier 3: common core.
        for k in 0..sp.clue_cells.len() {
            if self.placed[k].is_some() {
                continue;
            }
            let mut inter = sp.all;
            for &i in &sp.by_clue[k] {
                if self.alive[i] {
                    band(&mut inter, &sp.cands[i].bits);
                }
            }
            let mut killed = false;
            for (i, c) in sp.cands.iter().enumerate() {
                if self.alive[i] && c.clue != k && overlaps(&c.bits, &inter) {
                    self.alive[i] = false;
                    killed = true;
                }
            }
            if killed {
                return Ok(Some(Event::Eliminate(Tech::Core { clue: k })));
            }
        }
        if max_tier < 4 {
            return Ok(None);
        }
        // Tier 4: one-step lookahead per candidate.
        let unplaced: Vec<usize> = (0..sp.clue_cells.len()).filter(|&k| self.placed[k].is_none()).collect();
        for &k in &unplaced {
            for &x in &sp.by_clue[k] {
                if !self.alive[x] {
                    continue;
                }
                let xb = sp.cands[x].bits;
                let mut reach = self.covered;
                bor(&mut reach, &xb);
                let mut ok = true;
                for &k2 in &unplaced {
                    if k2 == k {
                        continue;
                    }
                    let mut any = false;
                    for &i in &sp.by_clue[k2] {
                        if self.alive[i] && !overlaps(&sp.cands[i].bits, &xb) {
                            bor(&mut reach, &sp.cands[i].bits);
                            any = true;
                        }
                    }
                    if !any {
                        ok = false;
                        break;
                    }
                }
                if ok && reach != sp.all {
                    ok = false;
                }
                if !ok {
                    self.alive[x] = false;
                    return Ok(Some(Event::Eliminate(Tech::Lookahead { clue: k })));
                }
            }
        }
        Ok(None)
    }

    fn done(&self) -> bool {
        self.placed.iter().all(|p| p.is_some())
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Grade {
    pub max_tier: u8,
    pub steps: [u32; 5],
    /// Initial candidates per number.
    pub ambiguity: f64,
}

/// Logic solve. Ok(grade) when solved; Err(unresolved clue indices) when stuck.
fn logic_solve(sp: &Space, max_tier: u8) -> Result<Grade, Vec<usize>> {
    let mut st = LState::new(sp);
    let mut grade = Grade { max_tier: 1, ambiguity: sp.cands.len() as f64 / sp.clue_cells.len() as f64, ..Default::default() };
    loop {
        if st.done() {
            return if st.covered == sp.all { Ok(grade) } else { Err((0..sp.clue_cells.len()).collect()) };
        }
        match st.step(sp, max_tier) {
            Err(()) => return Err((0..sp.clue_cells.len()).collect()),
            Ok(None) => return Err((0..sp.clue_cells.len()).filter(|&k| st.placed[k].is_none()).collect()),
            Ok(Some(Event::Place { .. })) => grade.steps[1] += 1,
            Ok(Some(Event::Eliminate(t))) => {
                grade.steps[t.tier() as usize] += 1;
                grade.max_tier = grade.max_tier.max(t.tier());
            }
        }
    }
}

/// One logic-solvable puzzle from a given attempt seed, if found within the repair budget.
fn try_build(p: &Params, rng: &mut Rng) -> Option<(Puzzle, Grade)> {
    let rects = partition(p, rng)?;
    let cols = p.cols;
    let mut clues: Vec<(usize, usize)> = rects
        .iter()
        .map(|r| {
            let rr = r.r0 + rng.below(r.r1 - r.r0 + 1);
            let cc = r.c0 + rng.below(r.c1 - r.c0 + 1);
            (rr * cols + cc, r.area())
        })
        .collect();
    for _ in 0..14 {
        let sp = Space::new(p.rows, p.cols, &clues);
        match logic_solve(&sp, p.max_tier) {
            Ok(grade) => return Some((Puzzle { rows: p.rows, cols, clues, solution: rects }, grade)),
            Err(stuck) => {
                if stuck.is_empty() {
                    return None;
                }
                // Move the number of one unresolved rectangle (prefer large ones: most ambiguous).
                let k = stuck[rng.below(stuck.len())];
                let r = rects[k];
                if r.area() == 1 {
                    continue;
                }
                let rr = r.r0 + rng.below(r.r1 - r.r0 + 1);
                let cc = r.c0 + rng.below(r.c1 - r.c0 + 1);
                clues[k].0 = rr * cols + cc;
            }
        }
    }
    None
}

/// Deterministic puzzle for a level.
pub fn generate(level: u32) -> (Puzzle, Grade) {
    let p = params(level);
    assert!(p.rows * p.cols <= MAX_CELLS);
    let mut best: Option<(Puzzle, Grade)> = None;
    let mut found = 0;
    let score = |g: &Grade| {
        g.max_tier as f64 * 15.0 + g.steps[4] as f64 * 6.0 + g.steps[3] as f64 * 3.0 + g.steps[2] as f64 * 0.5 + g.ambiguity * 10.0
    };
    for attempt in 0..400 {
        let mut rng = Rng::new(seed_for("shikaku", level, attempt));
        if let Some((puz, grade)) = try_build(&p, &mut rng) {
            if best.as_ref().map_or(true, |(_, b)| score(&grade) > score(b)) {
                best = Some((puz, grade));
            }
            found += 1;
            if found >= p.picks {
                break;
            }
        }
    }
    best.expect("shikaku generation failed")
}

fn cell_name(cols: usize, cell: usize) -> String {
    format!("{}. satır, {}. sütun", cell / cols + 1, cell % cols + 1)
}

fn tech_text(sp: &Space, t: &Tech) -> String {
    match *t {
        Tech::OnlyCover { cell, clue } => format!(
            "Tek kapsayan — ({}) hücresine yalnızca {} ulaşabiliyor, o yüzden onun dikdörtgeni bu hücreyi içermeli.",
            cell_name(sp.cols, cell),
            sp.clue_nums[clue]
        ),
        Tech::Core { clue } => format!(
            "Ortak çekirdek — ({}) konumundaki {} sayısının bütün seçenekleri aynı hücreleri kapsıyor; o hücrelere başka sayı giremez.",
            cell_name(sp.cols, sp.clue_cells[clue]),
            sp.clue_nums[clue]
        ),
        Tech::Lookahead { clue } => format!(
            "Deneme — ({}) konumundaki {} için bazı yerleşimler başka bir sayıyı yersiz ya da bir hücreyi sahipsiz bırakıyor; onlar elendi.",
            cell_name(sp.cols, sp.clue_cells[clue]),
            sp.clue_nums[clue]
        ),
    }
}

pub struct Shikaku {
    puz: Puzzle,
    grade: Grade,
    space: Space,
    rects: Vec<Rect>,
    history: Vec<Vec<Rect>>,
    hints: u32,
    mistakes: u32,
    hint: Option<(Rect, String)>,
}

impl Shikaku {
    pub fn new(level: u32) -> Self {
        let (puz, grade) = generate(level);
        let space = Space::new(puz.rows, puz.cols, &puz.clues);
        Shikaku { puz, grade, space, rects: vec![], history: vec![], hints: 0, mistakes: 0, hint: None }
    }

    /// A rectangle is valid when it holds exactly one number equal to its area.
    fn rect_ok(&self, r: &Rect) -> bool {
        let cols = self.puz.cols;
        let mut inside = self.puz.clues.iter().filter(|&&(cell, _)| r.contains(cell / cols, cell % cols));
        match (inside.next(), inside.next()) {
            (Some(&(_, n)), None) => n == r.area(),
            _ => false,
        }
    }

    fn covered(&self) -> usize {
        self.rects.iter().map(|r| r.area()).sum()
    }

    fn solved(&self) -> bool {
        self.covered() == self.puz.rows * self.puz.cols && self.rects.iter().all(|r| self.rect_ok(r))
    }

    fn stars(&self) -> u32 {
        let pen = self.hints + self.mistakes;
        if !self.solved() {
            0
        } else if pen == 0 {
            3
        } else if pen <= 3 {
            2
        } else {
            1
        }
    }

    fn snapshot(&mut self) {
        self.history.push(self.rects.clone());
        self.hint = None;
    }

    fn place(&mut self, r: Rect) -> Result<(), String> {
        if r.r1 >= self.puz.rows || r.c1 >= self.puz.cols {
            return Err("Dikdörtgen ızgaranın dışına taşıyor".into());
        }
        if self.rects.contains(&r) {
            return Err("Bu dikdörtgen zaten yerleşik".into());
        }
        self.snapshot();
        self.rects.retain(|o| !o.overlaps(&r));
        self.rects.push(r);
        if !self.puz.solution.contains(&r) {
            self.mistakes += 1;
        }
        Ok(())
    }

    fn do_hint(&mut self) -> Result<(), String> {
        self.hints += 1;
        if let Some(k) = self.rects.iter().position(|r| !self.puz.solution.contains(r)) {
            let r = self.rects[k];
            self.snapshot();
            self.rects.remove(k);
            self.hint = Some((r, "Bu dikdörtgen çözümde yok — kaldırdım. Oradaki sayılara yeniden bak.".into()));
            return Ok(());
        }
        let sp = &self.space;
        let mut st = LState::new(sp);
        for r in &self.rects {
            let k = self.puz.solution.iter().position(|s| s == r).expect("correct rect");
            let cand = sp.by_clue[k].iter().copied().find(|&i| sp.cands[i].rect == *r).expect("candidate");
            st.place(sp, cand);
        }
        let mut last_reason: Option<Tech> = None;
        let mut found: Option<(usize, String)> = None;
        for _ in 0..10_000 {
            match st.step(sp, 4) {
                Ok(Some(Event::Place { clue, .. })) => {
                    let n = sp.clue_nums[clue];
                    let at = cell_name(sp.cols, sp.clue_cells[clue]);
                    let text = match last_reason {
                        None => format!(
                            "Tek seçenek — ({at}) konumundaki {n} için ızgaraya sığan ve başka sayı içermeyen tek dikdörtgen bu."
                        ),
                        Some(t) => format!("{} Böylece ({at}) konumundaki {n} için tek seçenek kaldı.", tech_text(sp, &t)),
                    };
                    found = Some((clue, text));
                    break;
                }
                Ok(Some(Event::Eliminate(t))) => last_reason = Some(t),
                _ => break,
            }
        }
        let (clue, text) = match found {
            Some(f) => f,
            None => {
                let k = (0..self.puz.solution.len())
                    .find(|&k| !self.rects.contains(&self.puz.solution[k]))
                    .ok_or("Eksik dikdörtgen yok")?;
                (k, format!("{} sayısının dikdörtgeni bu.", self.puz.clues[k].1))
            }
        };
        let r = self.puz.solution[clue];
        self.snapshot();
        self.rects.retain(|o| !o.overlaps(&r));
        self.rects.push(r);
        self.hint = Some((r, text));
        Ok(())
    }
}

impl Session for Shikaku {
    fn state(&self) -> Value {
        let (rows, cols) = (self.puz.rows, self.puz.cols);
        let status = if self.solved() { "won" } else { "playing" };
        let label = match self.grade.max_tier {
            1 | 2 => "Akıcı",
            3 => "Çekirdek",
            _ => "Derin",
        };
        json!({
            "status": status,
            "stars": self.stars(),
            "title": format!("{rows}×{cols} · {label}"),
            "goal": format!("Izgarayı {} dikdörtgene böl · her biri tek sayı, alanı o sayı", self.puz.clues.len()),
            "rows": rows,
            "cols": cols,
            "clues": self.puz.clues.iter().map(|&(cell, n)| json!([cell / cols, cell % cols, n])).collect::<Vec<_>>(),
            "rects": self.rects.iter().map(|r| json!({"r0": r.r0, "c0": r.c0, "r1": r.r1, "c1": r.c1, "ok": self.rect_ok(r)})).collect::<Vec<_>>(),
            "covered": self.covered(),
            "total": rows * cols,
            "hint": self.hint.as_ref().map(|(r, t)| json!({"rect": r.json(), "text": t})),
            "hints": self.hints,
            "mistakes": self.mistakes,
            "can_undo": !self.history.is_empty() && !self.solved(),
            "summary": format!("İpucu: {} · Hatalı dikdörtgen: {}", self.hints, self.mistakes),
        })
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if self.solved() {
            return Err("Bölüm bitti".into());
        }
        if a["undo"].as_bool() == Some(true) {
            let prev = self.history.pop().ok_or("Geri alınacak hamle yok")?;
            self.rects = prev;
            self.hint = None;
            return Ok(());
        }
        if a["hint"].as_bool() == Some(true) {
            return self.do_hint();
        }
        let nums = |v: &Value, n: usize| -> Option<Vec<usize>> {
            let arr = v.as_array()?;
            if arr.len() != n {
                return None;
            }
            arr.iter().map(|x| x.as_u64().map(|x| x as usize)).collect()
        };
        if !a["place"].is_null() {
            let v = nums(&a["place"], 4).ok_or("Geçersiz dikdörtgen")?;
            let r = Rect { r0: v[0].min(v[2]), c0: v[1].min(v[3]), r1: v[0].max(v[2]), c1: v[1].max(v[3]) };
            return self.place(r);
        }
        if !a["remove_at"].is_null() {
            let v = nums(&a["remove_at"], 2).ok_or("Geçersiz hücre")?;
            let k = self.rects.iter().position(|r| r.contains(v[0], v[1])).ok_or("Burada dikdörtgen yok")?;
            self.snapshot();
            self.rects.remove(k);
            return Ok(());
        }
        if let Some(k) = a["remove"].as_u64() {
            let k = k as usize;
            if k >= self.rects.len() {
                return Err("Böyle bir dikdörtgen yok".into());
            }
            self.snapshot();
            self.rects.remove(k);
            return Ok(());
        }
        Err("Bilinmeyen hamle".into())
    }
}

pub fn create(level: u32, mode: &str) -> Result<Box<dyn Session>, String> {
    if mode == "endless" {
        return Err("Shikaku'da sonsuz mod yok".into());
    }
    Ok(Box::new(Shikaku::new(level)))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Exact-cover solution counter (stops at `limit`), independent of the logic techniques.
    fn count_solutions(p: &Puzzle, limit: usize) -> usize {
        let sp = Space::new(p.rows, p.cols, &p.clues);
        fn rec(sp: &Space, covered: Bits, used: &mut Vec<bool>, limit: usize) -> usize {
            if covered == sp.all {
                return 1;
            }
            // Branch on the uncovered cell with the fewest compatible candidates.
            let mut best: Option<(usize, Vec<usize>)> = None;
            for cell in 0..sp.rows * sp.cols {
                if bget(&covered, cell) {
                    continue;
                }
                let opts: Vec<usize> = sp.by_cell[cell]
                    .iter()
                    .copied()
                    .filter(|&i| !used[sp.cands[i].clue] && !overlaps(&sp.cands[i].bits, &covered))
                    .collect();
                if best.as_ref().map_or(true, |b| opts.len() < b.1.len()) {
                    let empty = opts.is_empty();
                    best = Some((cell, opts));
                    if empty {
                        return 0;
                    }
                }
            }
            let (_, opts) = best.unwrap();
            let mut total = 0;
            for i in opts {
                let c = sp.cands[i];
                used[c.clue] = true;
                let mut cov = covered;
                bor(&mut cov, &c.bits);
                total += rec(sp, cov, used, limit - total);
                used[c.clue] = false;
                if total >= limit {
                    break;
                }
            }
            total
        }
        rec(&sp, [0; 4], &mut vec![false; p.clues.len()], limit)
    }

    const LEVELS: [u32; 9] = [1, 2, 3, 50, 137, 250, 400, 499, 500];

    #[test]
    fn shikaku_levels_generate_unique() {
        for level in LEVELS {
            let (p, _) = generate(level);
            let pr = params(level);
            assert_eq!((p.rows, p.cols), (pr.rows, pr.cols));
            let area: usize = p.solution.iter().map(|r| r.area()).sum();
            assert_eq!(area, p.rows * p.cols);
            assert_eq!(count_solutions(&p, 2), 1, "level {level} not unique");
        }
    }

    #[test]
    fn shikaku_deterministic() {
        for level in [1, 250] {
            assert_eq!(generate(level).0.clues, generate(level).0.clues);
        }
    }

    #[test]
    fn shikaku_illegal_actions_rejected() {
        let mut g = Shikaku::new(1);
        let before = g.state();
        assert!(g.act(&json!({"place": [0, 0, 7, 2]})).is_err());
        assert!(g.act(&json!({"place": [0, 0]})).is_err());
        assert!(g.act(&json!({"remove_at": [0, 0]})).is_err());
        assert!(g.act(&json!({"remove": 3})).is_err());
        assert!(g.act(&json!({"undo": true})).is_err());
        assert_eq!(before, g.state());
    }

    #[test]
    fn shikaku_overlap_replaces() {
        let mut g = Shikaku::new(2);
        g.act(&json!({"place": [0, 0, 1, 1]})).unwrap();
        g.act(&json!({"place": [1, 1, 2, 2]})).unwrap();
        assert_eq!(g.rects.len(), 1);
        g.act(&json!({"undo": true})).unwrap();
        assert_eq!(g.rects, vec![Rect { r0: 0, c0: 0, r1: 1, c1: 1 }]);
        g.act(&json!({"remove_at": [1, 0]})).unwrap();
        assert!(g.rects.is_empty());
    }

    #[test]
    fn shikaku_solution_wins_three_stars() {
        for level in [1, 137] {
            let mut g = Shikaku::new(level);
            for r in g.puz.solution.clone() {
                g.act(&json!({"place": [r.r1, r.c1, r.r0, r.c0]})).unwrap();
            }
            let st = g.state();
            assert_eq!(st["status"], "won");
            assert_eq!(st["stars"], 3);
        }
    }

    #[test]
    fn shikaku_hints_solve() {
        for level in [1, 300] {
            let mut g = Shikaku::new(level);
            // Start with a wrong rectangle somewhere.
            g.act(&json!({"place": [0, 0, 0, 0]})).unwrap();
            let mut guard = 0;
            while g.state()["status"] == "playing" {
                g.act(&json!({"hint": true})).unwrap();
                assert!(!g.hint.as_ref().unwrap().1.is_empty());
                guard += 1;
                assert!(guard < 300);
            }
        }
    }

    #[test]
    #[ignore]
    fn shikaku_timing_all_levels() {
        let t0 = std::time::Instant::now();
        let mut worst = (0u128, 0u32);
        let mut tiers = [0u32; 5];
        for level in 1..=500 {
            let t = std::time::Instant::now();
            let (_, g) = generate(level);
            tiers[g.max_tier as usize] += 1;
            let ms = t.elapsed().as_millis();
            if ms > worst.0 {
                worst = (ms, level);
            }
        }
        println!("shikaku: 500 levels in {:?}, worst {} ms (level {}), tiers {:?}", t0.elapsed(), worst.0, worst.1, tiers);
    }
}
