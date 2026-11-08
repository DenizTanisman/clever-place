//! Crowns ("Taçlar"): an N×N grid split into N coloured regions. Place crowns so that every row,
//! every column and every region holds exactly `k` crowns and no two crowns touch, not even
//! diagonally. `k = 1` normally; advanced levels use `k = 2` ("Çift taç") on 9×9 and 10×10 grids.
//!
//! Generation (all bitboards: N ≤ 11 → 121 cells fit a `u128`):
//! 1. A random valid crown placement (randomized row-by-row DFS).
//! 2. Regions grow from the crowns with a weighted, randomized flood fill (each region gets its own
//!    appetite and growth style — compact, stringy or random — for shape variety). For `k = 2`,
//!    2N blobs grow from the 2N crowns and are merged pairwise along a random perfect matching.
//! 3. Uniqueness repair: a propagation + branching solver looks for a second solution; if one
//!    exists, a cell that holds a crown only in that alternative moves to a neighbouring region,
//!    which breaks the alternative (that region now has k+1 of its crowns); buried cells get a
//!    neighbour peeled off first. Bounded rounds.
//! 4. Grading with a human-logic solver that always uses the easiest deduction (ranked):
//!    basic eliminations → last cell → one-unit confinement ("Hapsolan bölge") → shared
//!    neighbour / unit patterns → two-unit confinement → line pairs → collision test →
//!    3–4-unit confinement → forcing chain → deep forcing chain. Puzzles the logic solver cannot
//!    finish are rejected, so every level is solvable without guessing and hints can always
//!    explain the next step.
//!
//! Level curve (`params`) — size, crowns per unit, hardest-deduction window:
//! - L1 6×6 (patterns), L2 7×7 (two-unit confinement or harder).
//! - 3–30 7×7 · 31–90 8×8 · 91–170 9×9: windows alternate between "patterns" and
//!   "two-unit confinement or harder".
//! - 171–260 9×9/10×10 · 261–399 10×10/11×11 · 400+ 11×11: at least two-unit confinement.
//! - `k = 2`: every 3rd level in the 200s, two of three in the 300s (9×9), three of four from 400
//!   on (10×10; odd ones need a forcing chain).
//!
//! Measured (M-series Mac, release): the 500-level sweep takes ≈ 1.4 s (avg 2.7 ms/level);
//! 10×10 double crown is the slow case (avg ≈ 11 ms, worst ≈ 70 ms); everything else ≤ 15 ms.
//!
//! State: `{status, stars, title, goal, summary, n, k, regions[n²], region_names[n], marks[n²]
//!          (0 empty · 1 X · 2 crown), conflicts[cells], bad_units: {rows, cols, regions},
//!          crowns, crowns_total, hints, corrections, can_undo, technique,
//!          hint: {crowns[], xs[], clear[], focus[], technique, text} | null}`
//! Actions: `{"cycle":cell}` (empty → X → crown → empty) · `{"set":cell,"mark":"x|crown|empty"}` ·
//!          `{"drag":[cells],"mark":"x|empty"}` (only touches empty/X cells) · `{"clear":true}` ·
//!          `{"undo":true}` · `{"hint":true}`
//! Stars: a "correction" is removing a crown you placed (cycle, set, undo or clear).
//! 3 = no hints and ≤ 2 corrections · 2 = ≤ 1 hint and ≤ 6 corrections · otherwise 1.

use crate::rng::{seed_for, Rng};
use crate::Session;
use serde_json::{json, Value};

type BB = u128;

fn bit(c: usize) -> BB {
    1u128 << c
}

fn pc(m: BB) -> u32 {
    m.count_ones()
}

fn bits(mut m: BB) -> impl Iterator<Item = usize> {
    std::iter::from_fn(move || {
        if m == 0 {
            None
        } else {
            let i = m.trailing_zeros() as usize;
            m &= m - 1;
            Some(i)
        }
    })
}

/// Jewel names, in the same order as the app's region palette.
pub const REGION_NAMES: [&str; 11] = [
    "Zümrüt", "Safir", "Ametist", "Yakut", "Kehribar", "Akuamarin", "Turmalin", "Yeşim", "Lal", "Opal", "Lacivert",
];

// ───────────────────────────── board ─────────────────────────────

#[derive(Clone)]
struct Board {
    n: usize,
    k: u32,
    region: Vec<usize>,
    /// 0..n rows, n..2n columns, 2n..3n regions.
    units: Vec<BB>,
    /// King-move neighbours.
    nb: Vec<BB>,
    all: BB,
}

#[derive(Clone, Copy, Default, PartialEq, Debug)]
struct St {
    crowns: BB,
    xs: BB,
}

impl Board {
    fn new(n: usize, k: u32, region: Vec<usize>) -> Self {
        let mut units = vec![0u128; 3 * n];
        let mut nb = vec![0u128; n * n];
        for r in 0..n {
            for c in 0..n {
                let i = r * n + c;
                units[r] |= bit(i);
                units[n + c] |= bit(i);
                units[2 * n + region[i]] |= bit(i);
                for dr in -1i32..=1 {
                    for dc in -1i32..=1 {
                        let (rr, cc) = (r as i32 + dr, c as i32 + dc);
                        if (dr, dc) != (0, 0) && rr >= 0 && cc >= 0 && (rr as usize) < n && (cc as usize) < n {
                            nb[i] |= bit(rr as usize * n + cc as usize);
                        }
                    }
                }
            }
        }
        let all = if n * n == 128 { u128::MAX } else { (1u128 << (n * n)) - 1 };
        Board { n, k, region, units, nb, all }
    }

    fn unknown(&self, s: &St) -> BB {
        self.all & !s.crowns & !s.xs
    }

    fn need(&self, s: &St, u: usize) -> u32 {
        self.k.saturating_sub(pc(s.crowns & self.units[u]))
    }

    fn unit_name(&self, u: usize) -> String {
        let n = self.n;
        if u < n {
            format!("{}. satır", u + 1)
        } else if u < 2 * n {
            format!("{}. sütun", u - n + 1)
        } else {
            format!("{} bölge", REGION_NAMES[u - 2 * n])
        }
    }

    fn cell_name(&self, c: usize) -> String {
        format!("({},{})", c / self.n + 1, c % self.n + 1)
    }

    /// "(r,c) hücresine" / "(r,c) (r,c) hücrelerine" (`case` = "e" dative, "i" accusative).
    fn cells_np(&self, m: BB, case: &str) -> String {
        let noun = if pc(m) == 1 { "hücresi" } else { "hücreleri" };
        let suffix = if case == "e" { "ne" } else { "ni" };
        format!("{} {noun}{suffix}", self.cells_name(m))
    }

    fn there(m: BB) -> &'static str {
        if pc(m) == 1 {
            "orası"
        } else {
            "oralar"
        }
    }

    fn cells_name(&self, m: BB) -> String {
        bits(m).map(|c| self.cell_name(c)).collect::<Vec<_>>().join(" ")
    }

    /// True if `need` pairwise non-touching cells can be picked from `m` (need ≤ 2 checked exactly).
    fn fits(&self, m: BB, need: u32) -> bool {
        match need {
            0 => true,
            1 => m != 0,
            2 => bits(m).any(|c| m & !self.nb[c] & !bit(c) != 0),
            _ => pc(m) >= need,
        }
    }

    /// Place a crown and cross out its neighbours. False if it touches another crown.
    fn put(&self, s: &mut St, c: usize) -> bool {
        if s.crowns & self.nb[c] != 0 {
            return false;
        }
        s.crowns |= bit(c);
        s.xs = (s.xs | self.nb[c]) & !s.crowns;
        true
    }

    /// Solver propagation: full units are crossed out, units with exactly enough room are filled.
    fn propagate(&self, s: &mut St) -> bool {
        loop {
            let mut changed = false;
            for &u in &self.units {
                let cr = pc(s.crowns & u);
                if cr > self.k {
                    return false;
                }
                let unk = self.unknown(s) & u;
                if cr == self.k {
                    if unk != 0 {
                        s.xs |= unk;
                        changed = true;
                    }
                    continue;
                }
                let need = self.k - cr;
                let nu = pc(unk);
                if nu < need || !self.fits(unk, need) {
                    return false;
                }
                if nu == need {
                    for c in bits(unk) {
                        if !self.put(s, c) {
                            return false;
                        }
                    }
                    changed = true;
                }
            }
            if !changed {
                return true;
            }
        }
    }

    fn solve(&self, mut s: St, limit: usize, out: &mut Vec<BB>) {
        if out.len() >= limit || !self.propagate(&mut s) {
            return;
        }
        if pc(s.crowns) as usize == self.n * self.k as usize {
            out.push(s.crowns);
            return;
        }
        let unk = self.unknown(&s);
        let mut best = (u32::MAX, 0usize);
        for (i, &u) in self.units.iter().enumerate() {
            if pc(s.crowns & u) < self.k {
                let nu = pc(unk & u);
                if nu < best.0 {
                    best = (nu, i);
                }
            }
        }
        let m = unk & self.units[best.1];
        if m == 0 {
            return;
        }
        // Branch on the cell whose crown would cross out the most open cells.
        let c = m.trailing_zeros() as usize;
        let mut a = s;
        if self.put(&mut a, c) {
            self.solve(a, limit, out);
        }
        let mut b = s;
        b.xs |= bit(c);
        self.solve(b, limit, out);
    }

    fn solutions(&self, limit: usize) -> Vec<BB> {
        let mut out = vec![];
        self.solve(St::default(), limit, &mut out);
        out
    }

    /// Orthogonal neighbours of a mask.
    fn spread(&self, m: BB) -> BB {
        let n = self.n;
        let mut left_edge = 0u128;
        let mut right_edge = 0u128;
        for r in 0..n {
            left_edge |= bit(r * n);
            right_edge |= bit(r * n + n - 1);
        }
        (((m & !right_edge) << 1) | ((m & !left_edge) >> 1) | (m << n) | (m >> n)) & self.all
    }

    fn connected(&self, m: BB) -> bool {
        if m == 0 {
            return true;
        }
        let mut seen = m & m.wrapping_neg();
        loop {
            let next = (seen | self.spread(seen)) & m;
            if next == seen {
                return seen == m;
            }
            seen = next;
        }
    }
}

// ───────────────────────────── logic solver ─────────────────────────────

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub enum CTech {
    Basic,
    LastCell,
    Confine1,
    Pattern,
    Confine2,
    LinePair,
    Lookahead,
    Confine3,
    Forcing,
    DeepForcing,
}

const CTECHS: [CTech; 10] = [
    CTech::Basic,
    CTech::LastCell,
    CTech::Confine1,
    CTech::Pattern,
    CTech::Confine2,
    CTech::LinePair,
    CTech::Lookahead,
    CTech::Confine3,
    CTech::Forcing,
    CTech::DeepForcing,
];

impl CTech {
    pub fn name(self) -> &'static str {
        match self {
            CTech::Basic => "Temel eleme",
            CTech::LastCell => "Son yer",
            CTech::Confine1 => "Hapsolan bölge",
            CTech::Pattern => "Ortak komşu",
            CTech::Confine2 => "İkili hapis",
            CTech::LinePair => "Çizgi çifti",
            CTech::Lookahead => "Çarpışma testi",
            CTech::Confine3 => "Çoklu hapis",
            CTech::Forcing => "Deneme zinciri",
            CTech::DeepForcing => "Derin deneme",
        }
    }
}

struct Ded {
    tech: CTech,
    crowns: BB,
    xs: BB,
    focus: BB,
    text: String,
}

impl Board {
    fn next(&self, s: &St, max: CTech) -> Option<Ded> {
        CTECHS.iter().filter(|&&t| t <= max).find_map(|&t| self.find(s, t))
    }

    fn find(&self, s: &St, t: CTech) -> Option<Ded> {
        match t {
            CTech::Basic => self.basic(s),
            CTech::LastCell => self.last_cell(s),
            CTech::Confine1 => self.confine(s, 1, 1),
            CTech::Pattern => self.pattern(s).ok().flatten(),
            CTech::Confine2 => self.confine(s, 2, 2),
            CTech::LinePair => self.line_pair(s),
            CTech::Lookahead => self.lookahead(s),
            CTech::Confine3 => self.confine(s, 3, 4),
            CTech::Forcing => self.forcing(s),
            CTech::DeepForcing => self.deep_forcing(s),
        }
    }

    fn apply(&self, s: &mut St, d: &Ded) {
        s.crowns |= d.crowns;
        s.xs = (s.xs | d.xs) & !s.crowns;
    }

    /// Unit order for scanning: regions first (that is how people look), then rows, columns.
    fn unit_order(&self) -> impl Iterator<Item = usize> {
        let n = self.n;
        (2 * n..3 * n).chain(0..2 * n)
    }

    fn basic(&self, s: &St) -> Option<Ded> {
        let unk = self.unknown(s);
        let mut x = 0u128;
        for c in bits(s.crowns) {
            x |= self.nb[c];
        }
        for &u in &self.units {
            if pc(s.crowns & u) >= self.k {
                x |= u;
            }
        }
        let x = x & unk;
        (x != 0).then(|| Ded {
            tech: CTech::Basic,
            crowns: 0,
            xs: x,
            focus: s.crowns,
            text: "Temel eleme: tacın çevresindeki sekiz hücreye ve taçları tamamlanmış satır, sütun ve bölgelerin kalan hücrelerine taç gelemez".into(),
        })
    }

    fn last_cell(&self, s: &St) -> Option<Ded> {
        let unk = self.unknown(s);
        for u in self.unit_order() {
            let need = self.need(s, u);
            let m = unk & self.units[u];
            if need > 0 && pc(m) == need {
                let text = if need == 1 {
                    format!("Son yer: {} için tek aday hücre kaldı: {}", self.unit_name(u), self.cells_name(m))
                } else {
                    format!("Son yer: {} {need} taç istiyor ve tam {need} boş hücresi kaldı: {}", self.unit_name(u), self.cells_name(m))
                };
                return Some(Ded { tech: CTech::LastCell, crowns: m, xs: 0, focus: self.units[u], text });
            }
        }
        None
    }

    /// Sets of `lo..=hi` regions whose remaining cells lie in lines with the same remaining need
    /// (and the reverse: lines confined to regions).
    fn confine(&self, s: &St, lo: usize, hi: usize) -> Option<Ded> {
        let n = self.n;
        let unk = self.unknown(s);
        let open = |range: std::ops::Range<usize>| -> Vec<usize> { range.filter(|&u| self.need(s, u) > 0).collect() };
        let regions = open(2 * n..3 * n);
        let rows = open(0..n);
        let cols = open(n..2 * n);
        let tech = match lo {
            1 => CTech::Confine1,
            2 => CTech::Confine2,
            _ => CTech::Confine3,
        };
        for j in lo..=hi {
            // (group units, target line family)
            for (group, family, inside_is_region) in [
                (&regions, 0..n, true),
                (&regions, n..2 * n, true),
                (&rows, 2 * n..3 * n, false),
                (&cols, 2 * n..3 * n, false),
            ] {
                if group.len() <= j {
                    // A complete family adds no information (all needs sum to the same total).
                    continue;
                }
                let mut found = None;
                combo(group.len(), j, &mut |idx| {
                    let cells = idx.iter().fold(0u128, |m, &i| m | self.units[group[i]]) & unk;
                    let need: u32 = idx.iter().map(|&i| self.need(s, group[i])).sum();
                    let span: Vec<usize> = family.clone().filter(|&f| self.units[f] & cells != 0).collect();
                    if span.len() != j {
                        return false;
                    }
                    let span_need: u32 = span.iter().map(|&f| self.need(s, f)).sum();
                    if span_need != need {
                        return false;
                    }
                    let span_cells = span.iter().fold(0u128, |m, &f| m | self.units[f]);
                    let x = span_cells & unk & !cells;
                    if x == 0 {
                        return false;
                    }
                    let gnames: Vec<String> = idx.iter().map(|&i| self.unit_name(group[i])).collect();
                    let snames: Vec<String> = span.iter().map(|&f| self.unit_name(f)).collect();
                    let text = if j == 1 {
                        if inside_is_region {
                            format!(
                                "{}: {} için kalan bütün hücreler {} içinde; o çizginin {} bu bölgeden gelecek, çizginin geri kalanı boş kalır",
                                tech.name(), gnames[0], snames[0], if need == 1 { "tacı" } else { "kalan taçları" }
                            )
                        } else {
                            format!(
                                "{}: {} için kalan bütün hücreler {} içinde; bölgenin {} bu çizgiden gelecek, bölgenin geri kalanı boş kalır",
                                tech.name(), gnames[0], snames[0], if need == 1 { "tacı" } else { "kalan taçları" }
                            )
                        }
                    } else {
                        format!(
                            "{}: {} birlikte yalnız {} içine sığıyor ({} taç = {} taç); bu {} içindeki diğer hücreler boş kalır",
                            tech.name(),
                            gnames.join(", "),
                            snames.join(", "),
                            need,
                            span_need,
                            if inside_is_region { "çizgilerin" } else { "bölgelerin" }
                        )
                    };
                    found = Some(Ded { tech, crowns: 0, xs: x, focus: cells, text });
                    true
                });
                if found.is_some() {
                    return found;
                }
            }
        }
        None
    }

    /// Enumerate every way a unit can still take its crowns: cells used by all of them are crowns,
    /// cells hit by all of them (touch / filled line) stay empty.
    /// `Err` = some unit has no valid placement left (only happens under a false assumption).
    fn pattern(&self, s: &St) -> Result<Option<Ded>, ()> {
        let unk = self.unknown(s);
        for u in self.unit_order() {
            let need = self.need(s, u);
            let m = unk & self.units[u];
            if need == 0 || need > 2 || pc(m) > 24 {
                continue;
            }
            let cells: Vec<usize> = bits(m).collect();
            let mut all_in = u128::MAX;
            let mut all_hit = u128::MAX;
            let mut any = false;
            let mut consider = |p: BB| {
                // Respect the other units' capacity.
                for &w in &self.units {
                    if pc((s.crowns | p) & w) > self.k {
                        return;
                    }
                }
                let mut hit = 0u128;
                for c in bits(p) {
                    hit |= self.nb[c];
                }
                for &w in &self.units {
                    if pc((s.crowns | p) & w) == self.k {
                        hit |= w;
                    }
                }
                all_in &= p;
                all_hit &= hit & !p;
                any = true;
            };
            if need == 1 {
                for &c in &cells {
                    consider(bit(c));
                }
            } else {
                for (i, &a) in cells.iter().enumerate() {
                    for &b in &cells[i + 1..] {
                        if self.nb[a] & bit(b) == 0 {
                            consider(bit(a) | bit(b));
                        }
                    }
                }
            }
            if !any {
                return Err(());
            }
            let crowns = all_in & unk;
            let xs = all_hit & unk & !crowns;
            if crowns != 0 {
                return Ok(Some(Ded {
                    tech: CTech::Pattern,
                    crowns,
                    xs: 0,
                    focus: m,
                    text: format!(
                        "Kalıp: {} için kalan {need} tacı yerleştirmenin her yolu {} kullanıyor; {} taç",
                        self.unit_name(u),
                        self.cells_np(crowns, "i"),
                        Self::there(crowns)
                    ),
                }));
            }
            if xs != 0 {
                let text = if need == 1 {
                    format!(
                        "Ortak komşu: {} tacını hangi hücreye koyarsan koy {} değiyor ya da çizgisini dolduruyor; {} boş kalır",
                        self.unit_name(u),
                        self.cells_np(xs, "e"),
                        Self::there(xs)
                    )
                } else {
                    format!(
                        "Ortak komşu: {} için iki tacın bütün olası yerleşimleri {} dışlıyor; {} boş kalır",
                        self.unit_name(u),
                        self.cells_np(xs, "i"),
                        Self::there(xs)
                    )
                };
                return Ok(Some(Ded { tech: CTech::Pattern, crowns: 0, xs, focus: m, text }));
            }
        }
        Ok(None)
    }

    /// Two neighbouring rows (or columns) together: enumerate every way to give both their
    /// remaining crowns. Cells used by all ways are crowns; cells hit by all ways stay empty.
    fn line_pair(&self, s: &St) -> Option<Ded> {
        let n = self.n;
        let unk = self.unknown(s);
        for base in [0, n] {
            for i in 0..n - 1 {
                let (u1, u2) = (base + i, base + i + 1);
                let (n1, n2) = (self.need(s, u1), self.need(s, u2));
                if n1 + n2 < 2 {
                    continue;
                }
                let cells: Vec<usize> = bits(unk & (self.units[u1] | self.units[u2])).collect();
                let mut all_in = u128::MAX;
                let mut all_hit = u128::MAX;
                let mut count = 0u32;
                let mut aborted = false;
                let mut pick = 0u128;
                self.enum_pair(s, &cells, 0, [u1, u2], [n1, n2], &mut pick, &mut |p| {
                    let mut hit = 0u128;
                    for c in bits(p) {
                        hit |= self.nb[c];
                    }
                    for &w in &self.units {
                        if pc((s.crowns | p) & w) == self.k {
                            hit |= w;
                        }
                    }
                    all_in &= p;
                    all_hit &= hit & !p;
                    count += 1;
                    if count > 4000 {
                        aborted = true;
                    }
                    !aborted
                });
                if aborted || count == 0 {
                    continue;
                }
                let crowns = all_in & unk;
                let xs = all_hit & unk & !crowns;
                if crowns == 0 && xs == 0 {
                    continue;
                }
                let names = format!("{} ve {}", self.unit_name(u1), self.unit_name(u2));
                let text = if crowns != 0 {
                    format!(
                        "Çizgi çifti: {names} birlikte {} taç istiyor; bunu sağlamanın her yolu {} kullanıyor, {} taç",
                        n1 + n2,
                        self.cells_np(crowns, "i"),
                        Self::there(crowns)
                    )
                } else {
                    format!(
                        "Çizgi çifti: {names} birlikte {} taç istiyor; bütün olası yerleşimler {} değiyor ya da çizgisini dolduruyor, {} boş kalır",
                        n1 + n2,
                        self.cells_np(xs, "e"),
                        Self::there(xs)
                    )
                };
                return Some(Ded {
                    tech: CTech::LinePair,
                    crowns,
                    xs: if crowns != 0 { 0 } else { xs },
                    focus: unk & (self.units[u1] | self.units[u2]),
                    text,
                });
            }
        }
        None
    }

    /// DFS over `cells` choosing crowns so units `us` get exactly `need` more, with no touching
    /// and no unit over capacity. `f` returns false to stop.
    #[allow(clippy::too_many_arguments)]
    fn enum_pair(&self, s: &St, cells: &[usize], i: usize, us: [usize; 2], need: [u32; 2], pick: &mut BB, f: &mut dyn FnMut(BB) -> bool) -> bool {
        let have = [pc(*pick & self.units[us[0]]), pc(*pick & self.units[us[1]])];
        if have[0] == need[0] && have[1] == need[1] {
            return f(*pick);
        }
        if i == cells.len() {
            return true;
        }
        // Prune: not enough cells left for a unit.
        for j in 0..2 {
            let rest = cells[i..].iter().filter(|&&c| self.units[us[j]] & bit(c) != 0).count() as u32;
            if have[j] + rest < need[j] {
                return true;
            }
        }
        let c = cells[i];
        let j = if self.units[us[0]] & bit(c) != 0 { 0 } else { 1 };
        if have[j] < need[j] && (s.crowns | *pick) & self.nb[c] == 0 {
            let p2 = *pick | bit(c);
            if self.units.iter().all(|&w| pc((s.crowns | p2) & w) <= self.k) {
                *pick = p2;
                let go = self.enum_pair(s, cells, i + 1, us, need, pick, f);
                *pick &= !bit(c);
                if !go {
                    return false;
                }
            }
        }
        self.enum_pair(s, cells, i + 1, us, need, pick, f)
    }

    /// A crown here would leave some unit without room → this cell stays empty.
    fn lookahead(&self, s: &St) -> Option<Ded> {
        let unk = self.unknown(s);
        for c in bits(unk) {
            let mut t = *s;
            t.crowns |= bit(c);
            t.xs |= self.nb[c];
            for &w in &self.units {
                if pc(t.crowns & w) >= self.k {
                    t.xs |= w;
                }
            }
            t.xs &= !t.crowns;
            let tu = self.unknown(&t);
            for u in self.unit_order() {
                let need = self.need(&t, u);
                if need > 0 && !self.fits(tu & self.units[u], need) {
                    return Some(Ded {
                        tech: CTech::Lookahead,
                        crowns: 0,
                        xs: bit(c),
                        focus: self.units[u] & unk,
                        text: format!(
                            "Çarpışma testi: {} hücresine taç koyarsan {} için yer kalmıyor; orası boş kalır",
                            self.cell_name(c),
                            self.unit_name(u)
                        ),
                    });
                }
            }
        }
        None
    }

    /// Assume a crown (or an empty cell) and follow the forced moves; a dead end proves the
    /// opposite.
    fn forcing(&self, s: &St) -> Option<Ded> {
        let unk = self.unknown(s);
        for c in bits(unk) {
            let mut t = *s;
            if !self.put(&mut t, c) || !self.propagate(&mut t) {
                return Some(Ded {
                    tech: CTech::Forcing,
                    crowns: 0,
                    xs: bit(c),
                    focus: bit(c),
                    text: format!(
                        "Deneme zinciri: {} hücresine taç koyup zorunlu hamleleri izlersen bir satır, sütun ya da bölge tıkanıyor; orası boş kalır",
                        self.cell_name(c)
                    ),
                });
            }
        }
        for c in bits(unk) {
            let mut t = *s;
            t.xs |= bit(c);
            if !self.propagate(&mut t) {
                return Some(Ded {
                    tech: CTech::Forcing,
                    crowns: bit(c),
                    xs: 0,
                    focus: bit(c),
                    text: format!(
                        "Deneme zinciri: {} hücresini boş bırakırsan zorunlu hamleler bir satırı, sütunu ya da bölgeyi tıkıyor; orası taç",
                        self.cell_name(c)
                    ),
                });
            }
        }
        None
    }

    /// Propagation with the everyday techniques (used under an assumption). False = dead end.
    fn deep_propagate(&self, t: &mut St) -> bool {
        for _ in 0..200 {
            if !self.propagate(t) {
                return false;
            }
            if pc(t.crowns) as usize == self.n * self.k as usize {
                return true;
            }
            let d = match self.confine(t, 1, 1) {
                Some(d) => d,
                None => match self.pattern(t) {
                    Err(()) => return false,
                    Ok(Some(d)) => d,
                    Ok(None) => return true,
                },
            };
            if d.crowns & self.unknown(t) != d.crowns {
                return false;
            }
            for c in bits(d.crowns) {
                if !self.put(t, c) {
                    return false;
                }
            }
            t.xs |= d.xs & !t.crowns;
        }
        true
    }

    /// Like the forcing chain, but the assumption is followed with confinement and patterns too,
    /// and both "crown here" and "empty here" are tried.
    fn deep_forcing(&self, s: &St) -> Option<Ded> {
        let unk = self.unknown(s);
        for c in bits(unk) {
            let mut t = *s;
            if !self.put(&mut t, c) || !self.deep_propagate(&mut t) {
                return Some(Ded {
                    tech: CTech::DeepForcing,
                    crowns: 0,
                    xs: bit(c),
                    focus: bit(c),
                    text: format!(
                        "Derin deneme: {} hücresine taç koyarsan hapis ve ortak komşu adımları bir bölgeyi ya da çizgiyi tıkıyor; orası boş kalır",
                        self.cell_name(c)
                    ),
                });
            }
            let mut t = *s;
            t.xs |= bit(c);
            if !self.deep_propagate(&mut t) {
                return Some(Ded {
                    tech: CTech::DeepForcing,
                    crowns: bit(c),
                    xs: 0,
                    focus: bit(c),
                    text: format!(
                        "Derin deneme: {} hücresini boş bırakırsan zorunlu adımlar bir bölgeyi ya da çizgiyi tıkıyor; orası taç",
                        self.cell_name(c)
                    ),
                });
            }
        }
        None
    }

    /// Hardest deduction the easiest-first logic solver needs (`None` = stuck).
    /// Uses deductions up to `max`.
    fn grade(&self, max: CTech) -> Option<CTech> {
        let mut s = St::default();
        let mut hardest = CTech::Basic;
        let total = self.n * self.k as usize;
        while (pc(s.crowns) as usize) < total {
            let d = self.next(&s, max)?;
            hardest = hardest.max(d.tech);
            self.apply(&mut s, &d);
        }
        Some(hardest)
    }
}

fn combo(n: usize, k: usize, f: &mut dyn FnMut(&[usize]) -> bool) -> bool {
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

// ───────────────────────────── generator ─────────────────────────────

/// Random valid crown placement (k per row/column, no touching).
fn random_crowns(n: usize, k: u32, rng: &mut Rng) -> Option<BB> {
    let mut options: Vec<Vec<usize>> = vec![];
    if k == 1 {
        for a in 0..n {
            options.push(vec![a]);
        }
    } else {
        for a in 0..n {
            for b in a + 2..n {
                options.push(vec![a, b]);
            }
        }
    }
    let mut count = vec![0u32; n];
    let mut rows: Vec<Vec<usize>> = vec![];
    let mut budget = 20_000u32;
    fn dfs(
        r: usize,
        n: usize,
        k: u32,
        options: &[Vec<usize>],
        count: &mut [u32],
        rows: &mut Vec<Vec<usize>>,
        rng: &mut Rng,
        budget: &mut u32,
    ) -> bool {
        if r == n {
            return true;
        }
        if *budget == 0 {
            return false;
        }
        *budget -= 1;
        let mut order: Vec<usize> = (0..options.len()).collect();
        rng.shuffle(&mut order);
        let left = n - r - 1;
        'opt: for oi in order {
            let o = &options[oi];
            for &c in o {
                if count[c] >= k {
                    continue 'opt;
                }
                if let Some(prev) = rows.last() {
                    if prev.iter().any(|&p| p.abs_diff(c) <= 1) {
                        continue 'opt;
                    }
                }
            }
            // Every column must still be able to reach k crowns in the remaining rows.
            for c in 0..n {
                let here = o.contains(&c);
                let have = count[c] + here as u32;
                let deficit = k - have.min(k);
                let room = if here { left / 2 } else { left.div_ceil(2) };
                if deficit as usize > room {
                    continue 'opt;
                }
            }
            for &c in o {
                count[c] += 1;
            }
            rows.push(o.clone());
            if dfs(r + 1, n, k, options, count, rows, rng, budget) {
                return true;
            }
            rows.pop();
            for &c in o {
                count[c] -= 1;
            }
        }
        false
    }
    if !dfs(0, n, k, &options, &mut count, &mut rows, rng, &mut budget) {
        return None;
    }
    let mut m = 0u128;
    for (r, cs) in rows.iter().enumerate() {
        for &c in cs {
            m |= bit(r * n + c);
        }
    }
    Some(m)
}

/// Grow one region per seed with per-region appetite and style.
fn grow(n: usize, seeds: &[usize], rng: &mut Rng) -> Vec<usize> {
    const NONE: usize = usize::MAX;
    let mut region = vec![NONE; n * n];
    let m = seeds.len();
    let mut appetite: Vec<f64> = (0..m).map(|_| 0.25 + rng.f64() * rng.f64() * 3.0).collect();
    // 0 = random, 1 = compact, 2 = stringy
    let style: Vec<u8> = (0..m).map(|_| rng.below(3) as u8).collect();
    let mut last: Vec<usize> = seeds.to_vec();
    for (i, &s) in seeds.iter().enumerate() {
        region[s] = i;
    }
    let orth = |c: usize| -> Vec<usize> {
        let (r, cc) = (c / n, c % n);
        let mut v = Vec::with_capacity(4);
        if r > 0 {
            v.push(c - n);
        }
        if r + 1 < n {
            v.push(c + n);
        }
        if cc > 0 {
            v.push(c - 1);
        }
        if cc + 1 < n {
            v.push(c + 1);
        }
        v
    };
    let mut left = n * n - m;
    while left > 0 {
        // Frontier per region.
        let mut frontier: Vec<Vec<usize>> = vec![vec![]; m];
        for c in 0..n * n {
            if region[c] != NONE {
                continue;
            }
            for o in orth(c) {
                let r = region[o];
                if r != NONE && !frontier[r].contains(&c) {
                    frontier[r].push(c);
                }
            }
        }
        let total: f64 = (0..m).filter(|&i| !frontier[i].is_empty()).map(|i| appetite[i]).sum();
        let mut pick = rng.f64() * total;
        let mut ri = 0;
        for i in 0..m {
            if frontier[i].is_empty() {
                continue;
            }
            ri = i;
            if pick < appetite[i] {
                break;
            }
            pick -= appetite[i];
        }
        let f = &frontier[ri];
        let cell = match style[ri] {
            1 => {
                // Compact: most same-region neighbours.
                let best = f.iter().map(|&c| orth(c).iter().filter(|&&o| region[o] == ri).count()).max().unwrap_or(0);
                let cands: Vec<usize> = f.iter().copied().filter(|&c| orth(c).iter().filter(|&&o| region[o] == ri).count() == best).collect();
                *rng.pick(&cands)
            }
            2 => {
                let ext: Vec<usize> = f.iter().copied().filter(|&c| orth(c).contains(&last[ri])).collect();
                if ext.is_empty() || rng.chance(0.2) {
                    *rng.pick(f)
                } else {
                    *rng.pick(&ext)
                }
            }
            _ => *rng.pick(f),
        };
        region[cell] = ri;
        last[ri] = cell;
        // Regions slow down as they get large, so sizes stay varied but not absurd.
        appetite[ri] *= 0.97;
        left -= 1;
    }
    region
}

/// Merge 2n blobs into n regions along a random perfect matching of the adjacency graph.
fn pair_blobs(n: usize, blob: &[usize], blobs: usize, rng: &mut Rng) -> Option<Vec<usize>> {
    let mut adj = vec![vec![false; blobs]; blobs];
    for c in 0..n * n {
        let (r, cc) = (c / n, c % n);
        if cc + 1 < n && blob[c] != blob[c + 1] {
            adj[blob[c]][blob[c + 1]] = true;
            adj[blob[c + 1]][blob[c]] = true;
        }
        if r + 1 < n && blob[c] != blob[c + n] {
            adj[blob[c]][blob[c + n]] = true;
            adj[blob[c + n]][blob[c]] = true;
        }
    }
    let mut mate = vec![usize::MAX; blobs];
    fn rec(adj: &[Vec<bool>], mate: &mut [usize], rng: &mut Rng, budget: &mut u32) -> bool {
        if *budget == 0 {
            return false;
        }
        *budget -= 1;
        let b = adj.len();
        // Unmatched blob with the fewest free partners.
        let mut best: Option<(usize, usize)> = None;
        for i in 0..b {
            if mate[i] != usize::MAX {
                continue;
            }
            let free = (0..b).filter(|&j| adj[i][j] && mate[j] == usize::MAX).count();
            if best.is_none_or(|(_, f)| free < f) {
                best = Some((i, free));
            }
        }
        let Some((i, _)) = best else { return true };
        let mut partners: Vec<usize> = (0..b).filter(|&j| adj[i][j] && mate[j] == usize::MAX).collect();
        rng.shuffle(&mut partners);
        for j in partners {
            mate[i] = j;
            mate[j] = i;
            if rec(adj, mate, rng, budget) {
                return true;
            }
            mate[i] = usize::MAX;
            mate[j] = usize::MAX;
        }
        false
    }
    let mut budget = 2000;
    if !rec(&adj, &mut mate, rng, &mut budget) {
        return None;
    }
    let mut id = vec![usize::MAX; blobs];
    let mut next = 0;
    for i in 0..blobs {
        if id[i] == usize::MAX {
            id[i] = next;
            id[mate[i]] = next;
            next += 1;
        }
    }
    Some(blob.iter().map(|&b| id[b]).collect())
}

/// Shuffle region ids so colours are not tied to position.
fn relabel(region: &mut [usize], n: usize, rng: &mut Rng) {
    let mut perm: Vec<usize> = (0..n).collect();
    rng.shuffle(&mut perm);
    for r in region.iter_mut() {
        *r = perm[*r];
    }
}

/// Move `c` from its region to a neighbouring one if its region stays connected.
fn try_move(board: &mut Board, c: usize, rng: &mut Rng) -> bool {
    let n = board.n;
    let r = board.region[c];
    let home = board.units[2 * n + r];
    if pc(home) <= 1 || !board.connected(home & !bit(c)) {
        return false;
    }
    let mut targets: Vec<usize> = bits(board.spread(bit(c))).map(|o| board.region[o]).filter(|&o| o != r).collect();
    targets.sort_unstable();
    targets.dedup();
    if targets.is_empty() {
        return false;
    }
    // Prefer the smallest neighbouring region (keeps sizes balanced).
    targets.sort_by_key(|&t| pc(board.units[2 * n + t]));
    let t = if rng.chance(0.7) { targets[0] } else { *rng.pick(&targets) };
    board.region[c] = t;
    board.units[2 * n + r] &= !bit(c);
    board.units[2 * n + t] |= bit(c);
    true
}

/// Move cells between regions until the intended crowns are the only solution. Each round
/// enumerates a batch of alternative solutions; moving a cell that is crowned in an alternative
/// (but not in the intended solution) to another region kills every alternative using that cell
/// and leaves the others untouched, so one solver call pays for several repairs.
fn make_unique(board: &mut Board, sol: BB, rng: &mut Rng, max_rounds: usize) -> bool {
    for _ in 0..max_rounds {
        let mut alts: Vec<BB> = board.solutions(2).into_iter().filter(|&s| s != sol).collect();
        if alts.is_empty() {
            return true;
        }
        let mut progress = false;
        while !alts.is_empty() {
            // Cells ranked by how many alternatives they kill.
            let mut cand: Vec<(usize, usize)> = bits(alts.iter().fold(0u128, |m, &a| m | a) & !sol)
                .map(|c| (alts.iter().filter(|&&a| a & bit(c) != 0).count(), c))
                .collect();
            rng.shuffle(&mut cand);
            cand.sort_by_key(|&(k, _)| std::cmp::Reverse(k));
            let Some(&(_, c)) = cand.iter().find(|&&(_, c)| try_move(board, c, rng)) else { break };
            alts.retain(|&a| a & bit(c) == 0);
            progress = true;
        }
        if alts.is_empty() {
            continue;
        }
        if progress {
            continue;
        }
        // The remaining cells are buried inside their regions: peel a neighbour off first.
        let used = alts.iter().fold(0u128, |m, &a| m | a);
        let mut peel: Vec<usize> = bits(board.spread(used & !sol)).filter(|&e| used & bit(e) == 0 && sol & bit(e) == 0).collect();
        rng.shuffle(&mut peel);
        if !peel.iter().any(|&e| try_move(board, e, rng)) {
            return false;
        }
    }
    false
}

/// Level → (size, crowns per unit, hardest-deduction window). See the module docs.
pub fn params(level: u32) -> (usize, u32, CTech, CTech) {
    use CTech::*;
    let l = level;
    let double = match l {
        200..=299 => l % 3 == 0,
        300..=399 => l % 3 != 1,
        400.. => l % 4 != 0,
        _ => false,
    };
    if double {
        return match l {
            ..=399 => (9, 2, if l % 2 == 0 { LinePair } else { Pattern }, Forcing),
            _ if l % 2 == 0 => (10, 2, Pattern, Forcing),
            _ => (10, 2, Forcing, DeepForcing),
        };
    }
    let alt = l % 2 == 0;
    match l {
        0..=1 => (6, 1, Pattern, Confine2),
        2 => (7, 1, Confine2, Forcing),
        3..=30 => (7, 1, if alt { Confine2 } else { Pattern }, Forcing),
        31..=90 => (8, 1, if l % 3 == 0 { Confine2 } else { Pattern }, Forcing),
        91..=170 => (9, 1, if alt { Confine2 } else { Pattern }, Forcing),
        171..=260 => (if alt { 10 } else { 9 }, 1, Confine2, DeepForcing),
        261..=399 => (if alt { 11 } else { 10 }, 1, Confine2, DeepForcing),
        _ => (11, 1, Confine2, DeepForcing),
    }
}

pub struct Puzzle {
    pub n: usize,
    pub k: u32,
    pub region: Vec<usize>,
    pub solution: BB,
    pub hardest: CTech,
}

const ATTEMPTS: u32 = 60;

fn build(n: usize, k: u32, rng: &mut Rng) -> Option<(Board, BB)> {
    let sol = random_crowns(n, k, rng)?;
    let seeds: Vec<usize> = bits(sol).collect();
    let mut region = if k == 1 {
        grow(n, &seeds, rng)
    } else {
        let blob = grow(n, &seeds, rng);
        pair_blobs(n, &blob, seeds.len(), rng)?
    };
    relabel(&mut region, n, rng);
    let mut board = Board::new(n, k, region);
    if !make_unique(&mut board, sol, rng, 5 * n) {
        return None;
    }
    Some((board, sol))
}

pub fn generate(level: u32) -> Puzzle {
    let (n, k, lo, hi) = params(level);
    let mut best: Option<(u8, Puzzle)> = None;
    for attempt in 0..ATTEMPTS {
        let mut rng = Rng::new(seed_for("crowns", level, attempt));
        let Some((board, sol)) = build(n, k, &mut rng) else { continue };
        let Some(h) = board.grade(hi) else { continue };
        let dist = if h < lo { lo as u8 - h as u8 } else { (h as u8).saturating_sub(hi as u8) };
        let p = Puzzle { n, k, region: board.region.clone(), solution: sol, hardest: h };
        if dist == 0 {
            return p;
        }
        // Prefer misses on the hard side only a little less than easy ones.
        if best.as_ref().is_none_or(|(bd, _)| dist < *bd) {
            best = Some((dist, p));
        }
    }
    if let Some((_, p)) = best {
        return p;
    }
    // Extremely unlikely: keep trying with fresh seeds (bounded) and accept any logic-solvable grid.
    for attempt in ATTEMPTS..ATTEMPTS + 400 {
        let mut rng = Rng::new(seed_for("crowns", level, attempt));
        if let Some((board, sol)) = build(n, k, &mut rng) {
            if let Some(h) = board.grade(CTech::DeepForcing) {
                return Puzzle { n, k, region: board.region.clone(), solution: sol, hardest: h };
            }
        }
    }
    panic!("crowns: no puzzle for level {level}");
}

// ───────────────────────────── session ─────────────────────────────

struct HintInfo {
    crowns: BB,
    xs: BB,
    clear: BB,
    focus: BB,
    tech: Option<CTech>,
    text: String,
}

pub struct Crowns {
    board: Board,
    solution: BB,
    hardest: CTech,
    marks: Vec<u8>,
    history: Vec<Vec<u8>>,
    hints: u32,
    corrections: u32,
    hint: Option<HintInfo>,
}

pub fn create(level: u32, mode: &str) -> Result<Box<dyn Session>, String> {
    if mode == "endless" {
        return Err("Taçlar'da sonsuz mod yok".into());
    }
    Ok(Box::new(Crowns::new(level.clamp(1, crate::MAX_LEVEL))))
}

const EMPTY: u8 = 0;
const X: u8 = 1;
const CROWN: u8 = 2;

impl Crowns {
    pub fn new(level: u32) -> Self {
        let p = generate(level);
        let board = Board::new(p.n, p.k, p.region);
        let cells = p.n * p.n;
        Crowns {
            board,
            solution: p.solution,
            hardest: p.hardest,
            marks: vec![EMPTY; cells],
            history: vec![],
            hints: 0,
            corrections: 0,
            hint: None,
        }
    }

    fn mask(&self, v: u8) -> BB {
        self.marks.iter().enumerate().filter(|(_, &m)| m == v).fold(0u128, |a, (i, _)| a | bit(i))
    }

    fn solved(&self) -> bool {
        let crowns = self.mask(CROWN);
        let b = &self.board;
        b.units.iter().all(|&u| pc(crowns & u) == b.k) && bits(crowns).all(|c| crowns & b.nb[c] == 0)
    }

    fn stars(&self) -> u32 {
        if !self.solved() {
            0
        } else if self.hints == 0 && self.corrections <= 2 {
            3
        } else if self.hints <= 1 && self.corrections <= 6 {
            2
        } else {
            1
        }
    }

    fn cell(&self, v: &Value) -> Result<usize, String> {
        let c = v.as_u64().ok_or("Hücre eksik")? as usize;
        if c >= self.marks.len() {
            return Err("Geçersiz hücre".into());
        }
        Ok(c)
    }

    fn mark_arg(a: &Value) -> Result<u8, String> {
        match a["mark"].as_str() {
            Some("x") => Ok(X),
            Some("crown") => Ok(CROWN),
            Some("empty") => Ok(EMPTY),
            _ => Err("Geçersiz işaret".into()),
        }
    }

    /// Commit a new marks vector as one undoable step.
    fn commit(&mut self, next: Vec<u8>) {
        if next == self.marks {
            return;
        }
        self.corrections += self.removed_crowns(&self.marks, &next);
        self.history.push(std::mem::replace(&mut self.marks, next));
        self.hint = None;
    }

    fn removed_crowns(&self, from: &[u8], to: &[u8]) -> u32 {
        from.iter().zip(to).filter(|(&a, &b)| a == CROWN && b != CROWN).count() as u32
    }

    fn find_hint(&self) -> HintInfo {
        let b = &self.board;
        let crowns = self.mask(CROWN);
        let xs = self.mask(X);
        let wrong_crowns = crowns & !self.solution;
        if wrong_crowns != 0 {
            let c = wrong_crowns.trailing_zeros() as usize;
            return HintInfo {
                crowns: 0,
                xs: 0,
                clear: bit(c),
                focus: bit(c),
                tech: None,
                text: format!("{} hücresindeki taç çözüme uymuyor; onu kaldırdım", b.cell_name(c)),
            };
        }
        let wrong_xs = xs & self.solution;
        if wrong_xs != 0 {
            let c = wrong_xs.trailing_zeros() as usize;
            return HintInfo {
                crowns: 0,
                xs: 0,
                clear: bit(c),
                focus: bit(c),
                tech: None,
                text: format!("{} hücresini yanlışlıkla elemişsin; orada taç olabilir, X'i kaldırdım", b.cell_name(c)),
            };
        }
        let s = St { crowns, xs };
        if let Some(d) = b.next(&s, CTech::DeepForcing) {
            return HintInfo { crowns: d.crowns, xs: d.xs, clear: 0, focus: d.focus, tech: Some(d.tech), text: d.text };
        }
        let c = (self.solution & !crowns).trailing_zeros() as usize;
        HintInfo {
            crowns: bit(c),
            xs: 0,
            clear: 0,
            focus: bit(c),
            tech: None,
            text: format!("{} hücresinde taç var", b.cell_name(c)),
        }
    }

    fn conflicts(&self) -> (BB, Vec<usize>, Vec<usize>, Vec<usize>) {
        let b = &self.board;
        let n = b.n;
        let crowns = self.mask(CROWN);
        let unk = b.all & !crowns & !self.mask(X);
        let mut cells = 0u128;
        let (mut rows, mut cols, mut regs) = (vec![], vec![], vec![]);
        for (u, &m) in b.units.iter().enumerate() {
            let cr = pc(crowns & m);
            let over = cr > b.k;
            let starved = cr < b.k && pc(unk & m) < b.k - cr;
            if over {
                cells |= crowns & m;
            }
            if over || starved {
                match u / n {
                    0 => rows.push(u),
                    1 => cols.push(u - n),
                    _ => regs.push(u - 2 * n),
                }
            }
        }
        for c in bits(crowns) {
            if crowns & b.nb[c] != 0 {
                cells |= bit(c);
            }
        }
        (cells, rows, cols, regs)
    }
}

fn list(m: BB) -> Vec<usize> {
    bits(m).collect()
}

impl Session for Crowns {
    fn state(&self) -> Value {
        let b = &self.board;
        let won = self.solved();
        let (cells, rows, cols, regs) = self.conflicts();
        let title = if b.k == 2 { format!("{0}×{0} · Çift taç", b.n) } else { format!("{0}×{0}", b.n) };
        json!({
            "status": if won { "won" } else { "playing" },
            "stars": self.stars(),
            "title": title,
            "goal": format!("Her satır, sütun ve bölgeye {} taç · taçlar birbirine değmez", b.k),
            "summary": format!(
                "İpucu: {} · Düzeltme: {} · En zor adım: {}",
                self.hints, self.corrections, self.hardest.name()
            ),
            "n": b.n,
            "k": b.k,
            "regions": b.region,
            "region_names": REGION_NAMES[..b.n].to_vec(),
            "marks": self.marks,
            "conflicts": list(cells),
            "bad_units": {"rows": rows, "cols": cols, "regions": regs},
            "crowns": pc(self.mask(CROWN)),
            "crowns_total": b.n * b.k as usize,
            "hints": self.hints,
            "corrections": self.corrections,
            "can_undo": !self.history.is_empty() && !won,
            "technique": self.hardest.name(),
            "hint": self.hint.as_ref().map(|h| json!({
                "crowns": list(h.crowns),
                "xs": list(h.xs),
                "clear": list(h.clear),
                "focus": list(h.focus),
                "technique": h.tech.map(|t| t.name()),
                "text": h.text,
            })),
        })
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if self.solved() {
            return Err("Bölüm bitti".into());
        }
        if a["undo"].as_bool() == Some(true) {
            let prev = self.history.pop().ok_or("Geri alınacak hamle yok")?;
            self.corrections += self.removed_crowns(&self.marks, &prev);
            self.marks = prev;
            self.hint = None;
            return Ok(());
        }
        if a["hint"].as_bool() == Some(true) {
            let h = self.find_hint();
            let mut next = self.marks.clone();
            for c in bits(h.clear) {
                next[c] = EMPTY;
            }
            for c in bits(h.xs) {
                next[c] = X;
            }
            for c in bits(h.crowns) {
                next[c] = CROWN;
            }
            // Hint edits are not corrections and cannot be undone into a hint-free state.
            self.history.clear();
            self.marks = next;
            self.hints += 1;
            self.hint = Some(h);
            return Ok(());
        }
        if a["clear"].as_bool() == Some(true) {
            if self.marks.iter().all(|&m| m == EMPTY) {
                return Err("Tahta zaten boş".into());
            }
            let next = vec![EMPTY; self.marks.len()];
            self.commit(next);
            return Ok(());
        }
        if let Some(v) = a.get("cycle") {
            let c = self.cell(v)?;
            let mut next = self.marks.clone();
            next[c] = (next[c] + 1) % 3;
            self.commit(next);
            return Ok(());
        }
        if let Some(v) = a.get("set") {
            let c = self.cell(v)?;
            let m = Self::mark_arg(a)?;
            let mut next = self.marks.clone();
            next[c] = m;
            self.commit(next);
            return Ok(());
        }
        if let Some(v) = a.get("drag") {
            let cells = v.as_array().ok_or("Hücre listesi eksik")?;
            let m = Self::mark_arg(a)?;
            if m == CROWN {
                return Err("Sürükleyerek taç konmaz".into());
            }
            let mut next = self.marks.clone();
            for cv in cells {
                let c = self.cell(cv)?;
                if next[c] != CROWN {
                    next[c] = m;
                }
            }
            self.commit(next);
            return Ok(());
        }
        Err("Bilinmeyen hamle".into())
    }
}

// ───────────────────────────── tests ─────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    const LEVELS: [u32; 9] = [1, 2, 3, 50, 137, 250, 400, 499, 500];

    fn check_puzzle(level: u32, p: &Puzzle) {
        let b = Board::new(p.n, p.k, p.region.clone());
        let sols = b.solutions(2);
        assert_eq!(sols, vec![p.solution], "level {level}: not unique");
        // Every region connected and holding exactly k solution crowns.
        for r in 0..p.n {
            let m = b.units[2 * p.n + r];
            assert!(b.connected(m), "level {level}: region {r} split");
            assert_eq!(pc(m & p.solution), p.k);
        }
        assert_eq!(b.grade(CTech::DeepForcing), Some(p.hardest));
    }

    #[test]
    fn crowns_levels_generate_unique_and_logic_solvable() {
        for level in LEVELS {
            let p = generate(level);
            let (n, k, _, _) = params(level);
            assert_eq!((p.n, p.k), (n, k));
            check_puzzle(level, &p);
        }
    }

    #[test]
    fn crowns_double_crown_levels() {
        for level in [201, 402, 403] {
            let p = generate(level);
            assert_eq!(p.k, 2);
            check_puzzle(level, &p);
        }
    }

    #[test]
    fn crowns_deterministic() {
        for level in [1, 250, 401] {
            let (a, b) = (generate(level), generate(level));
            assert_eq!(a.region, b.region);
            assert_eq!(a.solution, b.solution);
        }
    }

    fn solve_by_cycles(g: &mut Crowns) {
        let sol: Vec<usize> = bits(g.solution).collect();
        for c in sol {
            g.act(&json!({"cycle": c})).unwrap();
            g.act(&json!({"cycle": c})).unwrap();
        }
    }

    #[test]
    fn crowns_solving_reaches_won_with_three_stars() {
        for level in [1, 403] {
            let mut g = Crowns::new(level);
            solve_by_cycles(&mut g);
            let st = g.state();
            assert_eq!(st["status"], "won");
            assert_eq!(st["stars"], 3);
            assert!(g.act(&json!({"cycle": 0})).is_err());
        }
    }

    #[test]
    fn crowns_illegal_actions_leave_state_unchanged() {
        let mut g = Crowns::new(2);
        let before = g.state();
        let cells = g.marks.len();
        for a in [
            json!({"cycle": cells}),
            json!({"set": 0, "mark": "queen"}),
            json!({"drag": [0, 1], "mark": "crown"}),
            json!({"drag": [0, cells], "mark": "x"}),
            json!({"undo": true}),
            json!({"clear": true}),
            json!({"nope": true}),
        ] {
            assert!(g.act(&a).is_err(), "{a}");
            assert_eq!(g.state(), before, "{a}");
        }
    }

    #[test]
    fn crowns_conflicts_corrections_drag_and_undo() {
        let mut g = Crowns::new(3);
        let n = g.board.n;
        // Two touching crowns → both flagged.
        g.act(&json!({"set": 0, "mark": "crown"})).unwrap();
        g.act(&json!({"set": n + 1, "mark": "crown"})).unwrap();
        let st = g.state();
        assert_eq!(st["conflicts"], json!([0, n + 1]));
        g.act(&json!({"undo": true})).unwrap();
        assert_eq!(g.corrections, 1);
        assert_eq!(g.state()["conflicts"], json!([]));
        // Drag marks X but never overwrites the crown.
        g.act(&json!({"drag": [0, 1, 2], "mark": "x"})).unwrap();
        assert_eq!(&g.marks[..3], &[CROWN, X, X]);
        g.act(&json!({"drag": [1, 2], "mark": "empty"})).unwrap();
        assert_eq!(&g.marks[..3], &[CROWN, EMPTY, EMPTY]);
        // A row full of X's is starved.
        let row: Vec<usize> = (n..2 * n).collect();
        g.act(&json!({"drag": row, "mark": "x"})).unwrap();
        assert!(g.state()["bad_units"]["rows"].as_array().unwrap().contains(&json!(1)));
    }

    #[test]
    fn crowns_hints_alone_solve_the_puzzle() {
        for level in [5, 404] {
            let mut g = Crowns::new(level);
            // Start with a wrong crown: the first hint removes it.
            let wrong = (0..g.marks.len()).find(|&c| g.solution & bit(c) == 0).unwrap();
            g.act(&json!({"set": wrong, "mark": "crown"})).unwrap();
            g.act(&json!({"hint": true})).unwrap();
            assert_eq!(g.marks[wrong], EMPTY);
            let mut guard = 0;
            while !g.solved() {
                g.act(&json!({"hint": true})).unwrap();
                assert!(!g.state()["hint"]["text"].as_str().unwrap().is_empty());
                guard += 1;
                assert!(guard < 300, "level {level}: hints loop");
            }
            assert_eq!(g.stars(), 1);
        }
    }

    #[test]
    fn crowns_endless_not_supported() {
        assert!(create(1, "endless").is_err());
    }

    /// `cargo test --release crowns_timing -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn crowns_timing_all_levels() {
        let t0 = std::time::Instant::now();
        let mut worst = (0.0f64, 0u32);
        let mut hist = std::collections::BTreeMap::new();
        let mut by_size = std::collections::BTreeMap::new();
        let mut misses = 0;
        for level in 1..=500 {
            let t = std::time::Instant::now();
            let p = generate(level);
            let ms = t.elapsed().as_secs_f64() * 1000.0;
            if ms > worst.0 {
                worst = (ms, level);
            }
            let (_, _, lo, hi) = params(level);
            if p.hardest < lo || p.hardest > hi {
                misses += 1;
            }
            *hist.entry(format!("{:?}", p.hardest)).or_insert(0) += 1;
            let e = by_size.entry((p.n, p.k)).or_insert((0, 0.0f64, 0.0f64));
            e.0 += 1;
            e.1 += ms;
            e.2 = e.2.max(ms);
        }
        let total = t0.elapsed().as_secs_f64();
        println!("500 levels: {:.2}s, avg {:.1} ms, worst {:.1} ms (L{}), window misses {misses}", total, total * 2.0, worst.0, worst.1);
        for ((n, k), (cnt, sum, max)) in by_size {
            println!("  {n}x{n} k={k}: {cnt} levels, avg {:.1} ms, max {:.1} ms", sum / cnt as f64, max);
        }
        println!("  hardest: {hist:?}");
    }

    #[test]
    #[ignore]
    fn crowns_grade_distribution() {
        for (n, k, cap) in [(6, 1, CTech::DeepForcing), (7, 1, CTech::DeepForcing), (8, 1, CTech::DeepForcing), (9, 1, CTech::DeepForcing), (10, 1, CTech::DeepForcing), (11, 1, CTech::DeepForcing), (10, 2, CTech::DeepForcing), (10, 2, CTech::Forcing), (9, 2, CTech::DeepForcing)] {
            let t = std::time::Instant::now();
            let mut hist = std::collections::BTreeMap::new();
            let mut built = 0;
            let tries = 200;
            for a in 0..tries {
                let mut rng = Rng::new(seed_for("crowns-dist", n as u32 * 10 + k, a));
                if let Some((b, _)) = build(n, k, &mut rng) {
                    built += 1;
                    let g = b.grade(cap).map(|g| format!("{g:?}")).unwrap_or("STUCK".into());
                    *hist.entry(g).or_insert(0) += 1;
                }
            }
            println!(
                "{n}x{n} k={k} cap {cap:?}: built {built}/{tries}, {:.2} ms/try; {hist:?}",
                t.elapsed().as_secs_f64() * 1000.0 / tries as f64
            );
        }
    }
}
