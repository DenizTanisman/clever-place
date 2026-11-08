//! Eksik sayı — Mensa / "math riddle" style missing numbers.
//!
//! Layouts (each shows three complete examples and one with a missing number):
//! - **grid** rows `a b c` with c = f(a, b);
//! - **equations** with a made-up operator: `8 (+) 3 = 511` (riddle style: hidden rule, often a
//!   concatenation such as "difference then sum");
//! - **triangles** (top, left, right; centre = f);
//! - **wheel**: opposite numbers combine to the centre number (the missing one is an *input*);
//! - **pairs** (number analogies x, then f(x));
//! - **pyramid**: every block = f(the two blocks under it); medium hides the top, hard can hide a
//!   bottom block (solve backwards).
//!
//! Medium rules use one operation plus at most a constant (a·b − 3, a² + b, 2a + b, x² − 1, sum
//! pyramids); hard rules combine two operations, squares or cubes, position-dependent triangle
//! rules (top × left − right), concatenations, backwards pyramids.
//!
//! Oracle: an independent expression grammar per arity (inputs, squares, cubes, doubles; every
//! binary operation over them; both bracketings over three inputs; products with a sum;
//! concatenations; each optionally plus a fitted constant). Every grammar expression that fits all
//! complete examples is applied to the incomplete one (solving for a missing input by search);
//! the item is kept only if they all predict the same single value. About a third of the items
//! are typed answers (number pad); the others have 4 (medium) or 5 (hard) options.

use super::common::*;
use super::item::IqItem;
use crate::rng::Rng;
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::sync::OnceLock;

pub const ID: &str = "missing_number";

// ------------------------------------------------------------------------------- expressions

#[derive(Clone, Debug)]
pub enum Ex {
    V(usize),
    C(i64),
    Add(Box<Ex>, Box<Ex>),
    Sub(Box<Ex>, Box<Ex>),
    Mul(Box<Ex>, Box<Ex>),
    Div(Box<Ex>, Box<Ex>),
    Pow(Box<Ex>, u32),
    Cat(Box<Ex>, Box<Ex>),
    Sqrt(Box<Ex>),
    /// Digits reversed (70 gives 7).
    Rev(Box<Ex>),
    /// Digit sum.
    DSum(Box<Ex>),
    /// Each digit squared, written side by side (42 gives 416).
    DigSq(Box<Ex>),
    /// Last digit moved to the front (1234 gives 4123).
    Rot(Box<Ex>),
}

use Ex::*;

fn v(i: usize) -> Ex {
    V(i)
}
fn k(c: i64) -> Ex {
    C(c)
}
fn add(a: Ex, b: Ex) -> Ex {
    Add(Box::new(a), Box::new(b))
}
fn sub(a: Ex, b: Ex) -> Ex {
    Sub(Box::new(a), Box::new(b))
}
fn mul(a: Ex, b: Ex) -> Ex {
    Mul(Box::new(a), Box::new(b))
}
fn div(a: Ex, b: Ex) -> Ex {
    Div(Box::new(a), Box::new(b))
}
fn pw(a: Ex, e: u32) -> Ex {
    Pow(Box::new(a), e)
}
fn cat(a: Ex, b: Ex) -> Ex {
    Cat(Box::new(a), Box::new(b))
}
fn sqrt(a: Ex) -> Ex {
    Sqrt(Box::new(a))
}
fn un(f: fn(Box<Ex>) -> Ex, a: Ex) -> Ex {
    f(Box::new(a))
}

/// Rename inputs: V(i) becomes V(map[i]).
fn remap(e: &Ex, map: &[usize]) -> Ex {
    let b = |x: &Ex| Box::new(remap(x, map));
    match e {
        V(i) => V(map[*i]),
        C(c) => C(*c),
        Add(x, y) => Add(b(x), b(y)),
        Sub(x, y) => Sub(b(x), b(y)),
        Mul(x, y) => Mul(b(x), b(y)),
        Div(x, y) => Div(b(x), b(y)),
        Pow(x, n) => Pow(b(x), *n),
        Cat(x, y) => Cat(b(x), b(y)),
        Sqrt(x) => Sqrt(b(x)),
        Rev(x) => Rev(b(x)),
        DSum(x) => DSum(b(x)),
        DigSq(x) => DigSq(b(x)),
        Rot(x) => Rot(b(x)),
    }
}

const LIMIT: i64 = 10_000_000;

impl Ex {
    pub fn eval(&self, x: &[i64]) -> Option<i64> {
        let r = match self {
            V(i) => x[*i],
            C(c) => *c,
            Add(a, b) => a.eval(x)?.checked_add(b.eval(x)?)?,
            Sub(a, b) => a.eval(x)?.checked_sub(b.eval(x)?)?,
            Mul(a, b) => a.eval(x)?.checked_mul(b.eval(x)?)?,
            Div(a, b) => {
                let (p, q) = (a.eval(x)?, b.eval(x)?);
                if q == 0 || p % q != 0 {
                    return None;
                }
                p / q
            }
            Pow(a, e) => a.eval(x)?.checked_pow(*e)?,
            Cat(a, b) => {
                let (p, q) = (a.eval(x)?, b.eval(x)?);
                if p < 0 || q < 0 {
                    return None;
                }
                format!("{p}{q}").parse().ok()?
            }
            Sqrt(a) => exact_root(a.eval(x)?, 2)?,
            Rev(a) => {
                let p = a.eval(x)?;
                if p < 0 {
                    return None;
                }
                p.to_string().chars().rev().collect::<String>().parse().ok()?
            }
            DSum(a) => {
                let p = a.eval(x)?;
                if p < 0 {
                    return None;
                }
                digit_sum(p)
            }
            DigSq(a) => {
                let p = a.eval(x)?;
                if p < 0 {
                    return None;
                }
                digits(p).iter().map(|d| (d * d).to_string()).collect::<String>().parse().ok()?
            }
            Rot(a) => {
                let p = a.eval(x)?;
                if p < 10 {
                    return None;
                }
                let t = p.to_string();
                let (head, last) = t.split_at(t.len() - 1);
                format!("{last}{head}").parse().ok()?
            }
        };
        (r.abs() <= LIMIT).then_some(r)
    }

    fn prec(&self) -> u8 {
        match self {
            Add(..) | Sub(..) => 1,
            Mul(..) | Div(..) => 2,
            Pow(..) => 3,
            _ => 4,
        }
    }

    /// Math text with the given names (or values) for the inputs: "6² − 11".
    pub fn text(&self, names: &[String]) -> String {
        let wrap = |e: &Ex, min: u8| {
            let t = e.text(names);
            if e.prec() < min {
                format!("({t})")
            } else {
                t
            }
        };
        match self {
            V(i) => names[*i].clone(),
            C(c) => num(*c),
            Add(a, b) => format!("{} + {}", wrap(a, 1), wrap(b, 1)),
            Sub(a, b) => format!("{} \u{2212} {}", wrap(a, 1), wrap(b, 2)),
            Mul(a, b) => format!("{} × {}", wrap(a, 2), wrap(b, 2)),
            Div(a, b) => format!("{} ÷ {}", wrap(a, 2), wrap(b, 3)),
            Pow(a, e) => format!("{}{}", wrap(a, 4), if *e == 2 { "²" } else { "³" }),
            Cat(a, b) => format!("{} | {}", a.text(names), b.text(names)),
            Sqrt(a) => format!("√{}", wrap(a, 4)),
            Rev(a) => format!("ters({})", a.text(names)),
            DSum(a) => format!("rakam toplamı({})", a.text(names)),
            DigSq(a) => format!("rakam kareleri({})", a.text(names)),
            Rot(a) => format!("döndür({})", a.text(names)),
        }
    }
}

/// Grammar entry: expression and whether a fitted constant may be added.
type G = Vec<(Ex, bool)>;

fn ops(a: Ex, b: Ex) -> Vec<Ex> {
    vec![add(a.clone(), b.clone()), sub(a.clone(), b.clone()), mul(a.clone(), b.clone()), div(a, b)]
}

fn grammar1() -> G {
    let x = || v(0);
    let bases = vec![
        x(),
        pw(x(), 2),
        pw(x(), 3),
        mul(x(), add(x(), k(1))),
        mul(x(), sub(x(), k(1))),
        pw(add(x(), k(1)), 2),
        pw(sub(x(), k(1)), 2),
        add(pw(x(), 2), pw(x(), 3)),
    ];
    let mut g = vec![];
    for b in bases {
        for m in [1, 2, 3, -1, 4, 5] {
            g.push((if m == 1 { b.clone() } else { mul(k(m), b.clone()) }, true));
        }
    }
    for m in 6..=12 {
        g.push((mul(k(m), x()), true));
    }
    for c in -5..=5 {
        for d in 2..=4 {
            g.push((div(add(x(), k(c)), k(d)), true));
        }
    }
    for f in [Rev as fn(Box<Ex>) -> Ex, DSum, DigSq, Rot] {
        g.push((un(f, x()), true));
        g.push((mul(k(2), un(f, x())), true));
    }
    g.push((un(Rev, un(Rot, x())), true));
    g.push((sqrt(x()), true));
    g.push((sub(x(), un(DSum, x())), true));
    g.push((add(x(), un(DSum, x())), true));
    g
}

fn pow2(x: i64) -> Option<i64> {
    (0..=20).contains(&x).then(|| 1i64 << x)
}

fn grammar2() -> G {
    let a = || v(0);
    let b = || v(1);
    let terms = vec![
        a(),
        b(),
        pw(a(), 2),
        pw(b(), 2),
        pw(a(), 3),
        pw(b(), 3),
        mul(k(2), a()),
        mul(k(2), b()),
        mul(k(3), a()),
        mul(k(3), b()),
        mul(k(10), a()),
        mul(k(10), b()),
        sqrt(a()),
        sqrt(b()),
    ];
    let mut g = vec![];
    for (i, t1) in terms.iter().enumerate() {
        for (j, t2) in terms.iter().enumerate() {
            if i == j {
                continue;
            }
            for e in ops(t1.clone(), t2.clone()) {
                g.push((e, true));
            }
        }
    }
    for base in ops(a(), b()) {
        g.push((pw(base.clone(), 2), true));
        g.push((mul(base.clone(), a()), true));
        g.push((mul(base.clone(), b()), true));
        g.push((mul(base.clone(), k(2)), true));
        g.push((mul(base.clone(), k(3)), true));
        g.push((div(base.clone(), k(2)), true));
        g.push((div(base.clone(), k(3)), true));
        g.push((div(base.clone(), k(4)), true));
    }
    g.push((mul(add(a(), k(1)), add(b(), k(1))), true));
    g.push((mul(sub(a(), k(1)), sub(b(), k(1))), true));
    g.push((add(mul(a(), b()), div(a(), b())), true));
    let ab = || mul(a(), b());
    for e in [add(ab(), a()), add(ab(), b()), sub(ab(), a()), sub(ab(), b()), add(add(ab(), a()), b()), sub(sub(ab(), a()), b()), mul(ab(), k(2))] {
        g.push((e, true));
    }
    let basics = || vec![add(a(), b()), sub(a(), b()), sub(b(), a()), mul(a(), b())];
    for p in basics() {
        for q in basics() {
            g.push((cat(p.clone(), q), false));
        }
    }
    g.push((cat(a(), b()), false));
    g.push((cat(b(), a()), false));
    g.push((cat(pw(a(), 2), pw(b(), 2)), false));
    g
}

fn grammar3() -> G {
    let perms = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]];
    let mut g = vec![];
    for p in perms {
        let (x, y, z) = (|| v(p[0]), || v(p[1]), || v(p[2]));
        for inner in ops(x(), y()) {
            for e in ops(inner, z()) {
                g.push((e, true));
            }
        }
        for inner in ops(y(), z()) {
            for e in ops(x(), inner) {
                g.push((e, true));
            }
        }
        for inner in ops(pw(x(), 2), y()) {
            for e in ops(inner, z()) {
                g.push((e, true));
            }
        }
        for inner in ops(y(), z()) {
            for e in ops(pw(x(), 2), inner) {
                g.push((e, true));
            }
        }
        for inner in ops(pw(x(), 2), pw(y(), 2)) {
            for e in ops(inner, z()) {
                g.push((e, true));
            }
        }
        for p2 in ops(x(), y()) {
            for q2 in ops(y(), z()) {
                g.push((cat(p2.clone(), q2), false));
            }
            for q2 in ops(x(), z()) {
                g.push((cat(p2.clone(), q2), false));
            }
        }
    }
    // Rules that ignore one of the three numbers (a decoy).
    for (i, j) in [(0, 1), (1, 0), (0, 2), (2, 0), (1, 2), (2, 1)] {
        for (e, kk) in grammar2() {
            g.push((remap(&e, &[i, j]), kk));
        }
    }
    for i in 0..3 {
        g.push((v(i), true));
        g.push((pw(v(i), 2), true));
    }
    g
}

/// Four inputs (corner squares): pairs of pairs, the plain sum, and every three-input rule on a
/// subset (one decoy corner).
fn grammar4() -> G {
    let mut g = vec![];
    let idx = [0usize, 1, 2, 3];
    let mut perms = vec![];
    for a in idx {
        for b in idx {
            for c in idx {
                for d in idx {
                    if a != b && a != c && a != d && b != c && b != d && c != d {
                        perms.push([a, b, c, d]);
                    }
                }
            }
        }
    }
    for p in perms {
        for l in ops(v(p[0]), v(p[1])) {
            for r in ops(v(p[2]), v(p[3])) {
                for e in ops(l.clone(), r) {
                    g.push((e, true));
                }
            }
        }
        for inner in ops(add(v(p[0]), v(p[1])), v(p[2])) {
            for e in ops(inner, v(p[3])) {
                g.push((e, true));
            }
        }
    }
    g.push((add(add(v(0), v(1)), add(v(2), v(3))), true));
    for skip in 0..4 {
        let keep: Vec<usize> = (0..4).filter(|&i| i != skip).collect();
        for (e, kk) in grammar3_core() {
            g.push((remap(&e, &keep), kk));
        }
    }
    g
}

/// The all-three-inputs part of the triple grammar (used inside `grammar4`).
fn grammar3_core() -> G {
    let perms = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]];
    let mut g = vec![];
    for p in perms {
        let (x, y, z) = (|| v(p[0]), || v(p[1]), || v(p[2]));
        for inner in ops(x(), y()) {
            for e in ops(inner, z()) {
                g.push((e, true));
            }
        }
    }
    g
}

fn grammar(arity: usize) -> &'static G {
    static G1: OnceLock<G> = OnceLock::new();
    static G2: OnceLock<G> = OnceLock::new();
    static G3: OnceLock<G> = OnceLock::new();
    static G4: OnceLock<G> = OnceLock::new();
    match arity {
        1 => G1.get_or_init(|| non_constant(grammar1(), 1)),
        2 => G2.get_or_init(|| non_constant(grammar2(), 2)),
        3 => G3.get_or_init(|| non_constant(grammar3(), 3)),
        _ => G4.get_or_init(|| non_constant(grammar4(), 4)),
    }
}

/// Drop expressions that do not depend on their inputs (2a ÷ a, b − b …): with a fitted constant
/// they would "explain" any example and accept every value of a missing input.
fn non_constant(g: G, arity: usize) -> G {
    let probes: [[i64; 4]; 5] = [[2, 3, 5, 7], [5, 7, 2, 3], [4, 9, 6, 8], [6, 1, 3, 2], [9, 4, 8, 5]];
    g.into_iter()
        .filter(|(e, _)| {
            let vals: Vec<Option<i64>> = probes.iter().map(|p| e.eval(&p[..arity])).collect();
            !vals.windows(2).all(|w| w[0] == w[1])
        })
        .collect()
}

/// One example: inputs → output; `None` marks the single missing number of the puzzle.
#[derive(Clone, Debug)]
pub struct Rel {
    pub ins: Vec<Option<i64>>,
    pub out: Option<i64>,
}

fn rel(ins: &[i64], out: i64) -> Rel {
    Rel { ins: ins.iter().map(|&x| Some(x)).collect(), out: Some(out) }
}

/// One grammar rule as a function (grammar entries plus the 2^x family for one input).
fn rule_fns(arity: usize) -> Vec<(Box<dyn Fn(&[i64]) -> Option<i64> + Sync + Send>, bool)> {
    let mut out: Vec<(Box<dyn Fn(&[i64]) -> Option<i64> + Sync + Send>, bool)> = vec![];
    for (i, (_, allow)) in grammar(arity).iter().enumerate() {
        out.push((Box::new(move |x: &[i64]| grammar(arity)[i].0.eval(x)), *allow));
    }
    if arity == 1 {
        for m in [1i64, 2, 3] {
            out.push((Box::new(move |x: &[i64]| pow2(x[0]).map(|p| p * m)), true));
        }
    }
    out
}

type RuleFns = Vec<(Box<dyn Fn(&[i64]) -> Option<i64> + Sync + Send>, bool)>;

fn rules_for(arity: usize) -> &'static RuleFns {
    static R: OnceLock<Vec<RuleFns>> = OnceLock::new();
    &R.get_or_init(|| (0..=4).map(|a| if a == 0 { vec![] } else { rule_fns(a) }).collect())[arity]
}

/// Every value the grammar predicts for the missing number (empty = nothing fits).
pub fn predictions(rels: &[Rel]) -> BTreeSet<i64> {
    let arity = rels[0].ins.len();
    let complete: Vec<(Vec<i64>, i64)> = rels
        .iter()
        .filter(|r| r.out.is_some() && r.ins.iter().all(|x| x.is_some()))
        .map(|r| (r.ins.iter().map(|x| x.unwrap()).collect(), r.out.unwrap()))
        .collect();
    let partial: Vec<&Rel> = rels.iter().filter(|r| r.out.is_none() || r.ins.iter().any(|x| x.is_none())).collect();
    let mut out = BTreeSet::new();
    if complete.len() < 2 || partial.is_empty() {
        return out;
    }
    let bound = if arity == 1 { 999 } else { 200 };
    for (f, allow_k) in rules_for(arity) {
        let Some(first) = f(&complete[0].0) else { continue };
        let kk = complete[0].1 - first;
        if (!allow_k && kk != 0) || kk.abs() > bound {
            continue;
        }
        if !complete[1..].iter().all(|(x, y)| f(x).map(|z| z + kk) == Some(*y)) {
            continue;
        }
        // Candidates from the first partial example, filtered by the rest.
        let p0 = partial[0];
        let mut cands: Vec<i64> = vec![];
        if p0.out.is_none() {
            let x: Vec<i64> = p0.ins.iter().map(|x| x.unwrap_or(0)).collect();
            if let Some(z) = f(&x) {
                cands.push(z + kk);
            }
        } else {
            let pos = p0.ins.iter().position(|x| x.is_none()).unwrap();
            let mut x: Vec<i64> = p0.ins.iter().map(|x| x.unwrap_or(0)).collect();
            for val in 0..=1500 {
                x[pos] = val;
                if f(&x).map(|z| z + kk) == p0.out {
                    cands.push(val);
                }
            }
        }
        for c in cands {
            let holds = partial[1..].iter().all(|r| {
                let x: Vec<i64> = r.ins.iter().map(|x| x.unwrap_or(c)).collect();
                f(&x).map(|z| z + kk) == Some(r.out.unwrap_or(c))
            });
            if holds {
                out.insert(c);
            }
        }
    }
    out
}

/// Near-miss values: grammar expressions without a constant that fit at least one complete
/// example exactly, applied to the incomplete one (output-missing puzzles only).
fn near_misses(rels: &[Rel]) -> Vec<i64> {
    let arity = rels[0].ins.len();
    let complete: Vec<(Vec<i64>, i64)> = rels
        .iter()
        .filter(|r| r.out.is_some() && r.ins.iter().all(|x| x.is_some()))
        .map(|r| (r.ins.iter().map(|x| x.unwrap()).collect(), r.out.unwrap()))
        .collect();
    let Some(q) = rels.iter().find(|r| r.out.is_none()) else { return vec![] };
    let qx: Vec<i64> = q.ins.iter().map(|x| x.unwrap_or(0)).collect();
    let mut v = vec![];
    for (e, _) in grammar(arity) {
        if complete.iter().any(|(x, y)| e.eval(x) == Some(*y)) {
            if let Some(z) = e.eval(&qx) {
                if z > 0 && z < 100_000 && !v.contains(&z) {
                    v.push(z);
                }
            }
        }
    }
    v
}

// ------------------------------------------------------------------------------- generator

/// What the oracle sees: plain examples, or one of the structured layouts.
#[derive(Clone, Debug)]
pub enum Structure {
    Rels(Vec<Rel>),
    Star(StarSpec),
    Pie(PieSpec),
    Diamond(DiamondSpec),
    Set(SetSpec),
}

pub fn structure_predictions(st: &Structure) -> BTreeSet<i64> {
    match st {
        Structure::Rels(r) => predictions(r),
        Structure::Star(s) => star_predictions(s),
        Structure::Pie(s) => pie_predictions(s),
        Structure::Diamond(s) => diamond_predictions(s),
        Structure::Set(s) => set_predictions(s),
    }
}

pub struct Spec {
    st: Structure,
    opts: Vec<i64>,
    answer: i64,
}

struct Rule {
    e: Ex,
    /// Inputs: inclusive ranges per input.
    ranges: Vec<(i64, i64)>,
    /// Inputs drawn as squares of the range (for √ rules).
    sq: Vec<bool>,
}

fn r2(e: Ex, a: (i64, i64), b: (i64, i64)) -> Rule {
    Rule { e, ranges: vec![a, b], sq: vec![] }
}

fn grid_rules(hard: bool) -> Vec<Rule> {
    let (a, b) = (|| v(0), || v(1));
    if !hard {
        vec![
            r2(add(mul(a(), b()), k(3)), (2, 9), (2, 9)),
            r2(sub(mul(a(), b()), k(2)), (2, 9), (2, 9)),
            r2(sub(mul(a(), b()), k(5)), (3, 9), (3, 9)),
            r2(add(pw(a(), 2), b()), (2, 9), (1, 15)),
            r2(sub(pw(a(), 2), b()), (4, 11), (1, 15)),
            r2(add(mul(k(2), a()), b()), (3, 25), (1, 20)),
            r2(sub(mul(k(3), a()), b()), (4, 20), (1, 12)),
            r2(mul(add(a(), b()), k(2)), (2, 30), (2, 30)),
            r2(sub(mul(a(), b()), a()), (2, 9), (2, 12)),
            r2(add(a(), pw(b(), 2)), (1, 20), (2, 9)),
        ]
    } else {
        vec![
            r2(add(pw(a(), 2), pw(b(), 2)), (1, 9), (1, 9)),
            r2(pw(add(a(), b()), 2), (1, 9), (1, 9)),
            r2(sub(pw(a(), 2), pw(b(), 2)), (5, 12), (1, 5)),
            r2(mul(a(), add(a(), b())), (2, 9), (1, 9)),
            r2(add(add(mul(a(), b()), a()), b()), (2, 9), (2, 9)),
            r2(sub(pw(a(), 3), b()), (2, 6), (1, 20)),
            r2(mul(sub(a(), b()), add(a(), b())), (6, 12), (1, 5)),
            r2(sub(mul(mul(k(2), a()), b()), a()), (2, 9), (2, 9)),
            r2(add(pw(a(), 2), mul(k(2), b())), (2, 9), (1, 12)),
        ]
    }
}

fn riddle_rules(hard: bool) -> Vec<Rule> {
    let (a, b) = (|| v(0), || v(1));
    if !hard {
        vec![
            r2(add(mul(a(), b()), a()), (2, 9), (2, 9)),
            r2(sub(mul(a(), b()), b()), (2, 9), (2, 9)),
            r2(add(mul(a(), b()), k(1)), (2, 9), (2, 9)),
            r2(sub(pw(a(), 2), b()), (3, 9), (1, 9)),
            r2(cat(a(), b()), (11, 19), (2, 9)),
        ]
    } else {
        vec![
            r2(cat(sub(a(), b()), add(a(), b())), (5, 9), (1, 4)),
            r2(cat(mul(a(), b()), add(a(), b())), (2, 9), (2, 9)),
            r2(cat(add(a(), b()), sub(a(), b())), (5, 9), (1, 4)),
            r2(mul(a(), add(a(), b())), (2, 9), (2, 9)),
            r2(cat(mul(a(), b()), sub(a(), b())), (5, 9), (2, 4)),
        ]
    }
}

fn tri_rules(hard: bool) -> Vec<Rule> {
    let (t, l, r) = (|| v(0), || v(1), || v(2));
    let rr = |e: Ex, a: (i64, i64), b: (i64, i64), c: (i64, i64)| Rule { e, ranges: vec![a, b, c], sq: vec![] };
    if !hard {
        vec![
            rr(add(add(t(), l()), r()), (2, 30), (2, 30), (2, 30)),
            rr(sub(mul(l(), r()), t()), (1, 15), (2, 9), (2, 9)),
            rr(mul(add(l(), r()), t()), (2, 6), (1, 9), (1, 9)),
            rr(add(mul(t(), l()), r()), (2, 9), (2, 9), (1, 15)),
            rr(sub(add(l(), r()), t()), (1, 9), (5, 30), (5, 30)),
        ]
    } else {
        vec![
            rr(sub(mul(t(), l()), r()), (3, 9), (2, 9), (1, 12)),
            rr(mul(add(t(), l()), r()), (1, 8), (1, 8), (2, 6)),
            rr(sub(pw(t(), 2), mul(l(), r())), (6, 12), (1, 6), (1, 6)),
            rr(add(mul(l(), r()), pw(t(), 2)), (2, 7), (2, 7), (2, 7)),
            rr(mul(sub(t(), l()), r()), (6, 15), (1, 5), (2, 7)),
            rr(sub(mul(mul(t(), l()), r()), t()), (2, 5), (2, 5), (2, 5)),
        ]
    }
}

fn pair_rules(hard: bool) -> Vec<Rule> {
    let x = || v(0);
    let r1 = |e: Ex, a: (i64, i64)| Rule { e, ranges: vec![a], sq: vec![] };
    if !hard {
        vec![
            r1(add(mul(k(2), x()), k(3)), (2, 30)),
            r1(sub(mul(k(3), x()), k(2)), (2, 25)),
            r1(add(pw(x(), 2), k(1)), (2, 12)),
            r1(sub(pw(x(), 2), k(3)), (3, 12)),
            r1(add(mul(k(4), x()), k(1)), (2, 20)),
        ]
    } else {
        vec![
            r1(mul(x(), add(x(), k(1))), (2, 12)),
            r1(sub(pw(x(), 3), k(1)), (2, 7)),
            r1(add(mul(k(2), pw(x(), 2)), k(1)), (2, 9)),
            r1(sub(pw(add(x(), k(1)), 2), k(2)), (2, 12)),
            r1(add(pw(x(), 3), x()), (2, 6)),
        ]
    }
}

fn layout_rows(rels: &[Rel]) -> Vec<Vec<String>> {
    rels.iter()
        .map(|r| {
            let mut row: Vec<String> = r.ins.iter().map(|x| x.map(num).unwrap_or_else(|| "?".into())).collect();
            row.push(r.out.map(num).unwrap_or_else(|| "?".into()));
            row
        })
        .collect()
}

fn letters(n: usize) -> Vec<String> {
    ["a", "b", "c"][..n].iter().map(|s| s.to_string()).collect()
}

/// Examples for a rule: `n` distinct complete input tuples plus one query tuple.
fn examples(r: &mut Rng, rule: &Rule, n: usize, max_out: i64) -> Option<Vec<(Vec<i64>, i64)>> {
    let mut out: Vec<(Vec<i64>, i64)> = vec![];
    let mut tries = 0;
    while out.len() < n && tries < 200 {
        tries += 1;
        let x: Vec<i64> = rule
            .ranges
            .iter()
            .enumerate()
            .map(|(i, &(lo, hi))| {
                let v = r.range(lo, hi);
                if rule.sq.get(i) == Some(&true) {
                    v * v
                } else {
                    v
                }
            })
            .collect();
        let Some(y) = rule.e.eval(&x) else { continue };
        if y <= 0 || y > max_out || out.iter().any(|(p, _)| *p == x) {
            continue;
        }
        let mut distinct = x.clone();
        distinct.sort();
        distinct.dedup();
        let need = if x.len() == 2 { 2 } else { x.len().saturating_sub(1) };
        if rule.ranges.len() > 1 && distinct.len() < need {
            continue;
        }
        out.push((x, y));
    }
    (out.len() == n).then_some(out)
}

fn rule_line(e: &Ex, inputs: &[i64], answer: i64) -> String {
    let vals: Vec<String> = inputs.iter().map(|&x| num(x)).collect();
    format!("{} = {}", e.text(&vals), num(answer))
}

#[allow(clippy::too_many_arguments)]
fn finish(
    r: &mut Rng,
    hard: bool,
    prompt: &str,
    figure: Value,
    rels: Vec<Rel>,
    answer: i64,
    why: String,
    extra_bugs: &[i64],
) -> Option<(IqItem, Spec)> {
    let mut bugs = near_misses(&rels);
    bugs.extend_from_slice(extra_bugs);
    finish_with(r, hard, prompt, figure, Structure::Rels(rels), answer, why, &bugs)
}

#[allow(clippy::too_many_arguments)]
fn finish_with(
    r: &mut Rng,
    hard: bool,
    prompt: &str,
    figure: Value,
    st: Structure,
    answer: i64,
    why: String,
    bugs: &[i64],
) -> Option<(IqItem, Spec)> {
    let pred = structure_predictions(&st);
    if pred.len() != 1 || !pred.contains(&answer) {
        return None;
    }
    if r.chance(0.33) {
        let item = typed_item(ID, hard, prompt, Some(figure), answer, why);
        return Some((item, Spec { st, opts: vec![], answer }));
    }
    let mut bugs = bugs.to_vec();
    r.shuffle(&mut bugs);
    let n = if hard { 5 } else { 4 };
    let spread = (answer.abs() / 10).max(3);
    let (opts, at) = numeric_options(r, answer, &bugs, n, spread, 0, &|x| !pred.contains(&x))?;
    let item = text_item(ID, hard, prompt, Some(figure), strs(&opts), at, why);
    Some((item, Spec { st, opts, answer }))
}

fn build_grid(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    let rules = grid_rules(hard);
    let rule = r.pick(&rules);
    let ex = examples(r, rule, 4, 999)?;
    let answer = ex[3].1;
    let mut rels: Vec<Rel> = ex[..3].iter().map(|(x, y)| rel(x, *y)).collect();
    rels.push(Rel { ins: ex[3].0.iter().map(|&x| Some(x)).collect(), out: None });
    let fig = json!({"layout": "grid", "rows": layout_rows(&rels)});
    let names = vec!["birinci".to_string(), "ikinci".to_string()];
    let why = format!("Her satırda üçüncü sayı = {}. Son satır: {}.", rule.e.text(&names), rule_line(&rule.e, &ex[3].0, answer));
    finish(r, hard, "Her satırda aynı kural var. Soru işaretinin yerine hangi sayı gelmeli?", fig, rels, answer, why, &[])
}

fn build_riddle(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    let rules = riddle_rules(hard);
    let rule = r.pick(&rules);
    let ex = examples(r, rule, 4, 99_999)?;
    let answer = ex[3].1;
    let mut rels: Vec<Rel> = ex[..3].iter().map(|(x, y)| rel(x, *y)).collect();
    rels.push(Rel { ins: ex[3].0.iter().map(|&x| Some(x)).collect(), out: None });
    let rows: Vec<Vec<String>> = rels
        .iter()
        .map(|rl| vec![num(rl.ins[0].unwrap()), "(+)".into(), num(rl.ins[1].unwrap()), "=".into(), rl.out.map(num).unwrap_or_else(|| "?".into())])
        .collect();
    let fig = json!({"layout": "equations", "rows": rows});
    let why = if let Cat(p, q) = &rule.e {
        let vals: Vec<String> = ex[3].0.iter().map(|&x| num(x)).collect();
        let (pv, qv) = (p.eval(&ex[3].0).unwrap(), q.eval(&ex[3].0).unwrap());
        format!(
            "Sonuç iki sayının yan yana yazılması: önce {}, sonra {}. {} ve {} yan yana: {}.",
            p.text(&letters(2)),
            q.text(&letters(2)),
            format!("{} = {}", p.text(&vals), num(pv)),
            format!("{} = {}", q.text(&vals), num(qv)),
            num(answer)
        )
    } else {
        format!("Gizli kural: a ile b için sonuç {}. Son satır: {}.", rule.e.text(&letters(2)), rule_line(&rule.e, &ex[3].0, answer))
    };
    finish(r, hard, "Halkalı işlemin gizli bir kuralı var. Son işlemin sonucu ne?", fig, rels, answer, why, &[])
}

fn build_triangles(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    let rules = tri_rules(hard);
    let rule = r.pick(&rules);
    let ex = examples(r, rule, 4, 999)?;
    let answer = ex[3].1;
    let mut rels: Vec<Rel> = ex[..3].iter().map(|(x, y)| rel(x, *y)).collect();
    rels.push(Rel { ins: ex[3].0.iter().map(|&x| Some(x)).collect(), out: None });
    let items: Vec<Value> = rels
        .iter()
        .map(|rl| {
            json!({"top": num(rl.ins[0].unwrap()), "left": num(rl.ins[1].unwrap()), "right": num(rl.ins[2].unwrap()),
                   "mid": rl.out.map(num).unwrap_or_else(|| "?".into())})
        })
        .collect();
    let fig = json!({"layout": "triangles", "items": items});
    let names = vec!["üst".to_string(), "sol".to_string(), "sağ".to_string()];
    let why = format!("Ortadaki sayı = {}. Son üçgen: {}.", rule.e.text(&names), rule_line(&rule.e, &ex[3].0, answer));
    finish(r, hard, "Üçgenlerin hepsinde aynı kural var. Ortadaki soru işareti hangi sayı?", fig, rels, answer, why, &[])
}

fn build_pairs(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    let rules = pair_rules(hard);
    let rule = r.pick(&rules);
    let ex = examples(r, rule, 4, 999)?;
    let answer = ex[3].1;
    let mut rels: Vec<Rel> = ex[..3].iter().map(|(x, y)| rel(x, *y)).collect();
    rels.push(Rel { ins: vec![Some(ex[3].0[0])], out: None });
    let items: Vec<Vec<String>> = layout_rows(&rels);
    let fig = json!({"layout": "pairs", "items": items});
    let why = format!("Her sayı aynı işlemle dönüşüyor: x için {}. {}.", rule.e.text(&["x".to_string()]), rule_line(&rule.e, &ex[3].0, answer));
    finish(r, hard, "Her sayı aynı kuralla dönüşüyor. Son sayı neye dönüşür?", fig, rels, answer, why, &[])
}

fn build_wheel(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    // (rule for x, y; centre; how to solve y)
    let (x, y) = (|| v(0), || v(1));
    let kind = if hard { r.below(4) } else { r.below(2) };
    let (e, center, xs_range): (Ex, i64, (i64, i64)) = match (hard, kind) {
        (false, 0) => (add(x(), y()), r.range(25, 90), (3, 20)),
        (false, _) => (mul(x(), y()), *r.pick(&[24i64, 36, 48, 60, 72, 84, 90, 96]), (2, 12)),
        (true, 0) => (add(pw(x(), 2), y()), r.range(70, 120), (2, 8)),
        (true, 1) => (add(mul(k(2), x()), y()), r.range(40, 90), (4, 20)),
        (true, 2) => (sub(pw(x(), 2), y()), r.range(5, 30), (6, 12)),
        _ => (add(mul(x(), y()), x()), *r.pick(&[36i64, 48, 60, 72, 84, 96, 120]), (2, 12)),
    };
    let mut pairs: Vec<(i64, i64)> = vec![];
    let mut tries = 0;
    while pairs.len() < 4 && tries < 300 {
        tries += 1;
        let xv = r.range(xs_range.0, xs_range.1);
        if pairs.iter().any(|p| p.0 == xv) {
            continue;
        }
        let found = (1..=999).find(|&yv| e.eval(&[xv, yv]) == Some(center));
        if let Some(yv) = found {
            if yv != xv && !pairs.iter().any(|p| p.1 == yv) {
                pairs.push((xv, yv));
            }
        }
    }
    if pairs.len() < 4 {
        return None;
    }
    let answer = pairs[3].1;
    let mut rels: Vec<Rel> = pairs[..3].iter().map(|&(a, b)| rel(&[a, b], center)).collect();
    rels.push(Rel { ins: vec![Some(pairs[3].0), None], out: Some(center) });
    let n = pairs.len();
    let mut ring = vec![String::new(); 2 * n];
    for (i, &(a, b)) in pairs.iter().enumerate() {
        ring[i] = num(a);
        ring[i + n] = if i == 3 { "?".into() } else { num(b) };
    }
    let fig = json!({"layout": "wheel", "center": num(center), "ring": ring});
    let names = vec!["bir sayı".to_string(), "karşısındaki".to_string()];
    let why = format!(
        "Karşılıklı sayılar ortadaki sayıyı veriyor: {} = {}. {}.",
        e.text(&names),
        num(center),
        rule_line(&e, &[pairs[3].0, answer], center)
    );
    let bugs: Vec<i64> = vec![center - pairs[3].0, pairs[2].1, answer + 1, answer - 1, answer + pairs[3].0];
    finish(r, hard, "Karşılıklı sayılar ortadaki sayıyla aynı kuralla ilişkili. Soru işareti hangi sayı?", fig, rels, answer, why, &bugs)
}

fn build_pyramid(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    let (a, b) = (|| v(0), || v(1));
    let kind = if hard { r.below(3) } else { 0 };
    let (e, lo, hi, desc): (Ex, i64, i64, &str) = match kind {
        0 => (add(a(), b()), 1, 20, "altındaki iki taşın toplamı"),
        1 => (add(add(a(), b()), k(1)), 1, 15, "altındaki iki taşın toplamının 1 fazlası"),
        _ => (mul(a(), b()), 1, 4, "altındaki iki taşın çarpımı"),
    };
    let bottom: Vec<i64> = (0..4).map(|_| r.range(lo, hi)).collect();
    let mut rows = vec![bottom];
    for _ in 0..3 {
        let l = rows.last().unwrap();
        let nr: Vec<i64> = l.windows(2).map(|w| e.eval(&[w[0], w[1]]).unwrap()).collect();
        rows.push(nr);
    }
    if rows.iter().flatten().any(|&x| x > 999) {
        return None;
    }
    if kind == 2 && rows[0].iter().filter(|&&x| x == 1).count() > 1 {
        return None;
    }
    // Hide the top (medium) or, for hard sums, a bottom block.
    let hide_bottom = hard && kind == 0;
    let (hr, hc) = if hide_bottom { (0usize, r.below(4)) } else { (3usize, 0usize) };
    let answer = rows[hr][hc];
    let cell = |ri: usize, ci: usize| if (ri, ci) == (hr, hc) { None } else { Some(rows[ri][ci]) };
    let mut rels = vec![];
    for ri in 1..4 {
        for ci in 0..rows[ri].len() {
            rels.push(Rel { ins: vec![cell(ri - 1, ci), cell(ri - 1, ci + 1)], out: cell(ri, ci) });
        }
    }
    // Complete examples first.
    rels.sort_by_key(|rl| rl.out.is_none() || rl.ins.iter().any(|x| x.is_none()));
    let top_first: Vec<Vec<String>> = (0..4)
        .rev()
        .map(|ri| (0..rows[ri].len()).map(|ci| cell(ri, ci).map(num).unwrap_or_else(|| "?".into())).collect())
        .collect();
    let fig = json!({"layout": "pyramid", "rows": top_first});
    let why = if hide_bottom {
        let above = rows[1][hc.min(2)];
        let other = if hc <= 2 { rows[0][hc + 1] } else { rows[0][hc - 1] };
        format!("Her taş {desc}. Geriye doğru çöz: üstündeki {} \u{2212} yanındaki {} = {}.", num(above), num(other), num(answer))
    } else {
        format!("Her taş {desc}: {} ve {} ile tepe {}.", num(rows[2][0]), num(rows[2][1]), num(answer))
    };
    let bugs: Vec<i64> = vec![answer + 1, answer - 1, answer + 2, answer * 2];
    let prompt = if hide_bottom { "Her taş, altındaki iki taştan aynı kuralla çıkıyor. Soru işareti hangi sayı?" } else { "Her taş, altındaki iki taştan aynı kuralla çıkıyor. Tepede hangi sayı olmalı?" };
    finish(r, hard, prompt, fig, rels, answer, why, &bugs)
}

fn opt_str(x: Option<i64>) -> String {
    x.map(num).unwrap_or_else(|| "?".into())
}

/// Inverted triangles: two top corners give the bottom one.
fn build_itriangles(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    let (a, b) = (|| v(0), || v(1));
    let sq = |e: Ex, x: (i64, i64), y: (i64, i64), s: [bool; 2]| Rule { e, ranges: vec![x, y], sq: s.to_vec() };
    let rules = if !hard {
        vec![
            r2(div(add(a(), b()), k(2)), (1, 30), (1, 30)),
            r2(div(b(), a()), (2, 9), (4, 90)),
            r2(div(add(a(), b()), k(3)), (1, 30), (1, 30)),
            r2(sub(mul(k(2), a()), b()), (8, 25), (1, 15)),
        ]
    } else {
        vec![
            sq(mul(sqrt(a()), b()), (2, 12), (2, 9), [true, false]),
            r2(add(pw(a(), 2), pw(b(), 2)), (1, 9), (1, 9)),
            sq(add(sqrt(a()), sqrt(b())), (2, 12), (2, 12), [true, true]),
            r2(pw(sub(b(), a()), 2), (1, 9), (10, 20)),
            r2(mul(add(a(), k(1)), add(b(), k(1))), (2, 9), (2, 9)),
        ]
    };
    let rule = r.pick(&rules);
    let ex = examples(r, rule, 4, 999)?;
    let answer = ex[3].1;
    let mut rels: Vec<Rel> = ex[..3].iter().map(|(x, y)| rel(x, *y)).collect();
    rels.push(Rel { ins: ex[3].0.iter().map(|&x| Some(x)).collect(), out: None });
    let items: Vec<Value> = rels
        .iter()
        .map(|rl| json!({"left": opt_str(rl.ins[0]), "right": opt_str(rl.ins[1]), "bottom": opt_str(rl.out)}))
        .collect();
    let fig = json!({"layout": "itriangles", "items": items});
    let names = vec!["sol".to_string(), "sağ".to_string()];
    let why = format!("Alttaki sayı = {}. Son üçgen: {}.", rule.e.text(&names), rule_line(&rule.e, &ex[3].0, answer));
    finish(r, hard, "Her ters üçgende üstteki iki sayı alttakini aynı kuralla veriyor. Soru işareti hangi sayı?", fig, rels, answer, why, &[])
}

/// Six-ray star: every tip comes from two wedges (beside it, or beside the opposite tip).
fn build_star(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    let kind = if hard { r.below(3) } else { 0 };
    let (e, offset, lo, hi): (Ex, usize, i64, i64) = match kind {
        0 => (add(v(0), v(1)), 5, 0, 15),
        1 => (mul(v(0), v(1)), 5, 1, 9),
        _ => (add(v(0), v(1)), 2, 0, 15),
    };
    let wedges: Vec<i64> = (0..6).map(|_| r.range(lo, hi)).collect();
    let tip = |i: usize| e.eval(&[wedges[(i + offset) % 6], wedges[(i + offset + 1) % 6]]).unwrap();
    let tips: Vec<i64> = (0..6).map(tip).collect();
    let mut seen = tips.clone();
    seen.sort();
    seen.dedup();
    if seen.len() < 5 {
        return None;
    }
    let miss = r.below(6);
    let answer = tips[miss];
    let tips_s: Vec<String> = (0..6).map(|i| if i == miss { "?".into() } else { num(tips[i]) }).collect();
    let fig = json!({"layout": "star", "tips": tips_s, "wedges": strs(&wedges)});
    let (w1, w2) = (wedges[(miss + offset) % 6], wedges[(miss + offset + 1) % 6]);
    let op = if kind == 1 { "çarpımı" } else { "toplamı" };
    let sym = if kind == 1 { "×" } else { "+" };
    let why = if offset == 2 {
        format!("Her uçtaki sayı, karşısındaki ucun iki yanındaki dilimlerin {op}: {} {sym} {} = {}.", num(w1), num(w2), num(answer))
    } else {
        format!("Her uçtaki sayı, iki yanındaki dilimin {op}: {} {sym} {} = {}.", num(w1), num(w2), num(answer))
    };
    let spec = StarSpec { tips: tips.iter().enumerate().map(|(i, &t)| (i != miss).then_some(t)).collect(), wedges };
    let near = vec![w1 + w2, w1 * w2, answer + 1, answer - 1];
    finish_with(r, hard, "Yıldızın uçlarındaki sayılar dilimlerden aynı kuralla çıkıyor. Soru işareti hangi sayı?", fig, Structure::Star(spec), answer, why, &near)
}

#[derive(Clone, Debug)]
pub struct StarSpec {
    tips: Vec<Option<i64>>,
    wedges: Vec<i64>,
}

/// Union over every pairing of a tip with two neighbouring wedges (any rotation offset).
fn star_predictions(s: &StarSpec) -> BTreeSet<i64> {
    let mut out = BTreeSet::new();
    for o in 0..6 {
        let mut rels: Vec<Rel> = (0..6)
            .map(|i| Rel { ins: vec![Some(s.wedges[(i + o) % 6]), Some(s.wedges[(i + o + 1) % 6])], out: s.tips[i] })
            .collect();
        rels.sort_by_key(|rl| rl.out.is_none());
        out.extend(predictions(&rels));
    }
    out
}

/// Pie of six slices: each slice and the one opposite it are linked by the same rule.
fn build_pie(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    let x = || v(0);
    let rules: Vec<(Ex, (i64, i64))> = if !hard {
        vec![(add(mul(k(2), x()), k(1)), (2, 20)), (mul(k(3), x()), (2, 20)), (add(mul(k(2), x()), k(5)), (2, 20))]
    } else {
        vec![
            (add(pw(x(), 2), k(1)), (2, 10)),
            (sub(pw(x(), 2), k(1)), (2, 10)),
            (mul(k(3), add(x(), k(1))), (2, 20)),
            (mul(x(), add(x(), k(1))), (2, 10)),
        ]
    };
    let (e, (lo, hi)) = r.pick(&rules).clone();
    let mut smalls: Vec<i64> = vec![];
    while smalls.len() < 3 {
        let s0 = r.range(lo, hi);
        if !smalls.contains(&s0) {
            smalls.push(s0);
        }
    }
    let bigs: Vec<i64> = smalls.iter().map(|&s0| e.eval(&[s0]).unwrap()).collect();
    let mut ring = vec![0i64; 6];
    let mut small_at = [0usize; 3];
    for i in 0..3 {
        small_at[i] = if r.chance(0.5) { i + 3 } else { i };
        ring[small_at[i]] = smalls[i];
        ring[(small_at[i] + 3) % 6] = bigs[i];
    }
    let pair = r.below(3);
    let hide_big = r.chance(0.6);
    let hide_at = if hide_big { (small_at[pair] + 3) % 6 } else { small_at[pair] };
    let answer = ring[hide_at];
    let ring_s: Vec<String> = (0..6).map(|i| if i == hide_at { "?".into() } else { num(ring[i]) }).collect();
    let fig = json!({"layout": "wheel", "center": Value::Null, "ring": ring_s});
    let spec = PieSpec { ring: (0..6).map(|i| (i != hide_at).then_some(ring[i])).collect() };
    let names = vec!["küçük".to_string()];
    let why = format!("Karşılıklı dilimler aynı kuralla bağlı: büyük = {}. {} ile {} karşılıklı.", e.text(&names), num(smalls[pair]), num(bigs[pair]));
    let near = vec![answer + 1, answer - 1, smalls[pair] * 2, bigs[pair] / 2, answer + 2];
    finish_with(r, hard, "Karşılıklı dilimlerdeki sayılar aynı kuralla ilişkili. Soru işareti hangi sayı?", fig, Structure::Pie(spec), answer, why, &near)
}

#[derive(Clone, Debug)]
pub struct PieSpec {
    ring: Vec<Option<i64>>,
}

/// Opposite slices: the smaller one is the input; the incomplete pair is tried both ways.
fn pie_predictions(s: &PieSpec) -> BTreeSet<i64> {
    let mut complete = vec![];
    let mut partial = None;
    for i in 0..3 {
        match (s.ring[i], s.ring[i + 3]) {
            (Some(a), Some(b)) => complete.push(rel(&[a.min(b)], a.max(b))),
            (Some(a), None) | (None, Some(a)) => partial = Some(a),
            _ => {}
        }
    }
    let mut out = BTreeSet::new();
    let Some(known) = partial else { return out };
    let mut fwd = complete.clone();
    fwd.push(Rel { ins: vec![Some(known)], out: None });
    out.extend(predictions(&fwd));
    let mut back = complete;
    back.push(Rel { ins: vec![None], out: Some(known) });
    out.extend(predictions(&back));
    out
}

/// Split diamonds (top, left, right, bottom).
fn build_diamonds(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    let kind = if hard { 1 + r.below(2) } else { 0 };
    let mut ds: Vec<[i64; 4]> = vec![];
    let mut tries = 0;
    while ds.len() < 4 && tries < 300 {
        tries += 1;
        let d = match kind {
            0 => {
                let (t, l, rr) = (r.range(2, 20), r.range(2, 20), r.range(2, 20));
                [t, l, rr, l + rr - t]
            }
            1 => {
                let (t, b) = (r.range(2, 12), r.range(2, 12));
                let p = t * b;
                let divs: Vec<i64> = (2..p).filter(|d| p % d == 0 && *d != t && *d != b).collect();
                if divs.is_empty() {
                    continue;
                }
                let l = *r.pick(&divs);
                [t, l, p / l, b]
            }
            _ => {
                let (t, b) = (r.range(2, 9), r.range(2, 9));
                let p = t * b;
                if !(10..=99).contains(&p) {
                    continue;
                }
                [t, p / 10, p % 10, b]
            }
        };
        if d.iter().any(|&x| !(0..=99).contains(&x)) || ds.contains(&d) {
            continue;
        }
        if kind != 2 && d.iter().any(|&x| x < 1) {
            continue;
        }
        ds.push(d);
    }
    if ds.len() < 4 {
        return None;
    }
    let cell = r.below(4);
    let answer = ds[3][cell];
    let cells: Vec<Vec<Option<i64>>> =
        ds.iter().enumerate().map(|(i, d)| d.iter().enumerate().map(|(c, &x)| (i != 3 || c != cell).then_some(x)).collect()).collect();
    let items: Vec<Value> = cells
        .iter()
        .map(|d| json!({"top": opt_str(d[0]), "left": opt_str(d[1]), "right": opt_str(d[2]), "bottom": opt_str(d[3])}))
        .collect();
    let fig = json!({"layout": "diamonds", "items": items});
    let rule = match kind {
        0 => "Her karede üst + alt = sol + sağ.".to_string(),
        1 => "Her karede üst × alt = sol × sağ.".to_string(),
        _ => "Her karede üst × alt, sol ve sağ rakam yan yana yazılınca çıkan sayı (7 × 8 = 56 ise sol 5, sağ 6).".to_string(),
    };
    let d = ds[3];
    let why = format!("{rule} Son kare: üst {}, sol {}, sağ {}, alt {}.", num(d[0]), num(d[1]), num(d[2]), num(d[3]));
    let near = vec![answer + 1, answer - 1, answer + 2, answer * 2];
    finish_with(r, hard, "Bölünmüş karelerin hepsinde aynı ilişki var. Soru işareti hangi sayı?", fig, Structure::Diamond(DiamondSpec { cells }), answer, why, &near)
}

#[derive(Clone, Debug)]
pub struct DiamondSpec {
    cells: Vec<Vec<Option<i64>>>,
}

fn pair_ops(x: i64, y: i64) -> [Option<i64>; 8] {
    let cat2 = |p: i64, q: i64| if p >= 0 && q >= 0 { format!("{p}{q}").parse().ok() } else { None };
    [
        Some(x + y),
        Some(x - y),
        Some(y - x),
        Some(x * y),
        (y != 0 && x % y == 0).then(|| x / y),
        (x != 0 && y % x == 0).then(|| y / x),
        cat2(x, y),
        cat2(y, x),
    ]
}

/// Diamond oracle: every pairing of the four cells into two pairs with any pair operation on
/// each side (equal results), plus "one cell = triple-grammar rule of the other three".
fn diamond_predictions(s: &DiamondSpec) -> BTreeSet<i64> {
    let mut out = BTreeSet::new();
    let inc = s.cells.iter().position(|d| d.iter().any(|x| x.is_none())).unwrap();
    let complete: Vec<[i64; 4]> =
        s.cells.iter().enumerate().filter(|(i, _)| *i != inc).map(|(_, d)| [d[0].unwrap(), d[1].unwrap(), d[2].unwrap(), d[3].unwrap()]).collect();
    let pairings = [[(0, 3), (1, 2)], [(0, 1), (2, 3)], [(0, 2), (1, 3)]];
    for pr in pairings {
        for o1 in 0..8 {
            for o2 in 0..8 {
                let holds = |d: &[i64; 4]| {
                    let a = pair_ops(d[pr[0].0], d[pr[0].1])[o1];
                    let b = pair_ops(d[pr[1].0], d[pr[1].1])[o2];
                    a.is_some() && a == b
                };
                if !complete.iter().all(holds) {
                    continue;
                }
                for val in 0..=1500 {
                    let mut d = [0i64; 4];
                    for c in 0..4 {
                        d[c] = s.cells[inc][c].unwrap_or(val);
                    }
                    if holds(&d) {
                        out.insert(val);
                    }
                }
            }
        }
    }
    for outc in 0..4 {
        let others: Vec<usize> = (0..4).filter(|&c| c != outc).collect();
        let mut rels: Vec<Rel> = s.cells.iter().map(|d| Rel { ins: others.iter().map(|&c| d[c]).collect(), out: d[outc] }).collect();
        rels.sort_by_key(|rl| rl.out.is_none() || rl.ins.iter().any(|x| x.is_none()));
        out.extend(predictions(&rels));
    }
    out
}

/// Squares with a number on each corner and the result in the middle.
fn build_corners(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    let (tl, tr, br, bl) = (|| v(0), || v(1), || v(2), || v(3));
    let rules: Vec<(Ex, &str)> = if !hard {
        vec![
            (add(add(tl(), tr()), add(br(), bl())), "dört köşenin toplamı"),
            (add(mul(tl(), tr()), add(bl(), br())), "üst iki köşenin çarpımı + alt iki köşenin toplamı"),
        ]
    } else {
        vec![
            (add(mul(tl(), br()), mul(tr(), bl())), "çapraz köşelerin çarpımlarının toplamı"),
            (sub(mul(tl(), tr()), mul(bl(), br())), "üst köşelerin çarpımı \u{2212} alt köşelerin çarpımı"),
            (mul(sub(tl(), br()), add(tr(), bl())), "(sol üst \u{2212} sağ alt) × (sağ üst + sol alt)"),
        ]
    };
    let (e, desc) = r.pick(&rules).clone();
    let rule = Rule { e: e.clone(), ranges: vec![(1, 9); 4], sq: vec![] };
    let ex = examples(r, &rule, 4, 999)?;
    let answer = ex[3].1;
    let mut rels: Vec<Rel> = ex[..3].iter().map(|(x, y)| rel(x, *y)).collect();
    rels.push(Rel { ins: ex[3].0.iter().map(|&x| Some(x)).collect(), out: None });
    let items: Vec<Value> = rels
        .iter()
        .map(|rl| json!({"tl": opt_str(rl.ins[0]), "tr": opt_str(rl.ins[1]), "br": opt_str(rl.ins[2]), "bl": opt_str(rl.ins[3]), "mid": opt_str(rl.out)}))
        .collect();
    let fig = json!({"layout": "corners", "items": items});
    let why = format!("Ortadaki sayı = {desc}. Son kare: {} = {}.", e.text(&strs(&ex[3].0)), num(answer));
    finish(r, hard, "Her karenin ortasındaki sayı köşelerden aynı kuralla çıkıyor. Soru işareti hangi sayı?", fig, rels, answer, why, &[])
}

/// A 3×3 grid holding a shuffled set (multiples, squares, cubes, primes) with one member missing.
fn build_set_grid(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    let (set, desc): (Vec<i64>, String) = if !hard {
        let m = r.range(3, 12);
        ((1..=9).map(|i| i * m).collect(), format!("{m}'in ilk dokuz katı"))
    } else {
        match r.below(4) {
            0 => {
                let s0 = r.range(1, 4);
                ((s0..s0 + 9).map(|i| i * i).collect(), format!("{}² ile {}² arasındaki kareler", s0, s0 + 8))
            }
            1 => ((1..=9).map(|i| i * i * i).collect(), "1³ ile 9³ arasındaki küpler".into()),
            2 => (vec![2, 3, 5, 7, 11, 13, 17, 19, 23], "ilk dokuz asal sayı".into()),
            _ => {
                let s0 = r.range(1, 4);
                ((s0..s0 + 9).map(|i| i * (i + 1) / 2).collect(), "ardışık üçgensel sayılar (1, 3, 6, 10 …)".into())
            }
        }
    };
    let mut cells = set.clone();
    r.shuffle(&mut cells);
    let miss = r.below(9);
    let answer = cells[miss];
    let rows: Vec<Vec<String>> = (0..3).map(|i| (0..3).map(|j| if i * 3 + j == miss { "?".into() } else { num(cells[i * 3 + j]) }).collect()).collect();
    let fig = json!({"layout": "grid", "rows": rows});
    let shown: Vec<i64> = cells.iter().enumerate().filter(|(i, _)| *i != miss).map(|(_, &x)| x).collect();
    let why = format!("Izgarada {desc} karışık sırayla duruyor; eksik olan {}.", num(answer));
    let near = vec![answer + 1, answer - 1, answer * 2, answer + set[1] - set[0]];
    finish_with(r, hard, "Izgaradaki sayılar bir küme oluşturuyor. Eksik olan hangisi?", fig, Structure::Set(SetSpec { shown }), answer, why, &near)
}

#[derive(Clone, Debug)]
pub struct SetSpec {
    shown: Vec<i64>,
}

/// Set oracle: values v for which the nine numbers, sorted, form a sequence the series grammar
/// explains.
fn set_predictions(s: &SetSpec) -> BTreeSet<i64> {
    let mut out = BTreeSet::new();
    for val in 0..=1500 {
        if s.shown.contains(&val) {
            continue;
        }
        let mut all = s.shown.clone();
        all.push(val);
        all.sort();
        if super::series::explainable(&all) {
            out.insert(val);
        }
    }
    out
}

/// Digit manipulation maps ("x, then y").
fn build_digits(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    let x = || v(0);
    // (rule, input range, description, per-digit constraint id)
    let rules: Vec<(Ex, (i64, i64), &str, u8)> = if !hard {
        vec![
            (un(DSum, x()), (100, 999), "rakamlarının toplamı", 0),
            (sub(x(), k(111)), (222, 999), "her rakamından 1 çıkarılmış hâli", 1),
            (sub(k(100), x()), (11, 89), "100'e tamamlayan sayı", 0),
            (un(Rev, x()), (12, 98), "rakamları ters çevrilmiş hâli", 3),
        ]
    } else {
        vec![
            (un(DigSq, x()), (12, 99), "her rakamının karesi yan yana yazılmış hâli", 0),
            (un(Rot, x()), (1000, 9999), "son rakamı başa alınmış hâli", 3),
            (sub(x(), k(123)), (234, 999), "rakamlarından sırayla 1, 2, 3 çıkarılmış hâli", 2),
            (add(x(), un(DSum, x())), (20, 199), "kendisi ile rakamları toplamının toplamı", 0),
            (mul(k(2), un(DSum, x())), (100, 999), "rakamları toplamının 2 katı", 0),
        ]
    };
    let (e, range, desc, cons) = r.pick(&rules).clone();
    let digit_ok = |n: i64| -> bool {
        let d = digits(n);
        match cons {
            1 => d.iter().all(|&x| x >= 1),
            2 => d.len() == 3 && d[0] >= 1 && d[1] >= 2 && d[2] >= 3,
            3 => *d.last().unwrap() != 0 && d.windows(2).any(|w| w[0] != w[1]),
            _ => true,
        }
    };
    let mut ex: Vec<(i64, i64)> = vec![];
    let mut tries = 0;
    while ex.len() < 4 && tries < 300 {
        tries += 1;
        let n = r.range(range.0, range.1);
        if !digit_ok(n) || ex.iter().any(|p| p.0 == n) {
            continue;
        }
        if let Some(y) = e.eval(&[n]) {
            if y > 0 {
                ex.push((n, y));
            }
        }
    }
    if ex.len() < 4 {
        return None;
    }
    let answer = ex[3].1;
    let mut rels: Vec<Rel> = ex[..3].iter().map(|&(a, b)| rel(&[a], b)).collect();
    rels.push(Rel { ins: vec![Some(ex[3].0)], out: None });
    let fig = json!({"layout": "pairs", "items": layout_rows(&rels)});
    let why = format!("Her sayının karşılığı, sayının {desc}: {} için {}.", num(ex[3].0), num(answer));
    finish(r, hard, "Sayılar rakamlarıyla oynanarak dönüşüyor. Son sayının karşılığı ne?", fig, rels, answer, why, &[])
}

/// "a, b, c = d" lines; some hard rules ignore one of the three numbers (a decoy).
fn build_triples(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    let (a, b, c) = (|| v(0), || v(1), || v(2));
    let rr = |e: Ex, x: (i64, i64), y: (i64, i64), z: (i64, i64)| Rule { e, ranges: vec![x, y, z], sq: vec![] };
    let decoy = "üçüncü sayı bir tuzak, kurala girmiyor";
    let rules: Vec<(Rule, Option<&str>)> = if !hard {
        vec![
            (rr(add(sub(a(), b()), c()), (10, 30), (1, 9), (1, 20)), None),
            (rr(div(mul(a(), b()), c()), (2, 12), (2, 12), (2, 9)), None),
            (rr(sub(add(a(), b()), c()), (5, 20), (5, 20), (1, 9)), None),
        ]
    } else {
        vec![
            (rr(sub(mul(a(), c()), b()), (2, 15), (1, 12), (2, 9)), None),
            (rr(mul(add(a(), b()), c()), (1, 9), (1, 9), (2, 6)), None),
            (rr(sub(pw(a(), 2), b()), (3, 9), (1, 20), (1, 9)), Some(decoy)),
            (rr(add(mul(a(), b()), a()), (2, 9), (2, 9), (1, 9)), Some(decoy)),
            (rr(cat(mul(b(), c()), mul(a(), b())), (2, 9), (2, 9), (2, 9)), None),
        ]
    };
    let (rule, dec) = r.pick(&rules);
    let ex = examples(r, rule, 4, 99_999)?;
    let answer = ex[3].1;
    let mut rels: Vec<Rel> = ex[..3].iter().map(|(x, y)| rel(x, *y)).collect();
    rels.push(Rel { ins: ex[3].0.iter().map(|&x| Some(x)).collect(), out: None });
    let rows: Vec<Vec<String>> = rels
        .iter()
        .map(|rl| vec![opt_str(rl.ins[0]), ",".into(), opt_str(rl.ins[1]), ",".into(), opt_str(rl.ins[2]), "=".into(), opt_str(rl.out)])
        .collect();
    let fig = json!({"layout": "equations", "rows": rows});
    let names = vec!["a".to_string(), "b".to_string(), "c".to_string()];
    let vals = strs(&ex[3].0);
    let (rule_txt, line) = if let Cat(p, q) = &rule.e {
        (format!("{} ve {} yan yana", p.text(&names), q.text(&names)), format!("{} | {} = {}", p.text(&vals), q.text(&vals), num(answer)))
    } else {
        (rule.e.text(&names), rule_line(&rule.e, &ex[3].0, answer))
    };
    let why = format!("a, b, c için sonuç = {rule_txt}{}. Son satır: {line}.", dec.map(|d| format!(" ({d})")).unwrap_or_default());
    finish(r, hard, "Her satır a, b, c = sonuç biçiminde aynı kuralı izliyor. Son sonuç ne?", fig, rels, answer, why, &[])
}

fn pick_kind(r: &mut Rng, _hard: bool) -> usize {
    r.below(19)
}

fn build(r: &mut Rng, hard: bool, kind: usize) -> Option<(IqItem, Spec)> {
    match kind {
        0 | 1 => build_grid(r, hard),
        2 | 3 => build_riddle(r, hard),
        4 => build_triangles(r, hard),
        5 | 6 => build_itriangles(r, hard),
        7 => build_pairs(r, hard),
        8 | 9 => build_digits(r, hard),
        10 | 11 => build_triples(r, hard),
        12 => build_wheel(r, hard),
        13 => build_pie(r, hard),
        14 => build_star(r, hard),
        15 => build_diamonds(r, hard),
        16 => build_corners(r, hard),
        17 => build_set_grid(r, hard),
        _ => build_pyramid(r, hard),
    }
}

fn verify(item: &IqItem, s: &Spec) -> Result<(), String> {
    basic_checks(item)?;
    let pred = structure_predictions(&s.st);
    if pred.len() != 1 || !pred.contains(&s.answer) {
        return Err(format!("grammar predicts {pred:?}, intended {}", s.answer));
    }
    match item.typed {
        Some(v) if v != s.answer => return Err("typed value differs".into()),
        Some(_) => {}
        None => {
            if s.opts[item.answer] != s.answer || s.opts.iter().filter(|o| pred.contains(o)).count() != 1 {
                return Err(format!("options {:?}", s.opts));
            }
        }
    }
    Ok(())
}

pub fn gen_checked(r: &mut Rng, hard: bool) -> (IqItem, Result<(), String>) {
    retry_kind(r, hard, pick_kind, build, verify)
}

pub fn gen(r: &mut Rng, hard: bool) -> IqItem {
    gen_checked(r, hard).0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iq_missing_number_doc_examples() {
        // Grid rows [4,7,9], [5,3,22], [6,11,?] → 25 (a² − b): the doc's medium example.
        let rels = vec![rel(&[4, 7], 9), rel(&[5, 3], 22), rel(&[7, 2], 47), Rel { ins: vec![Some(6), Some(11)], out: None }];
        assert_eq!(predictions(&rels).into_iter().collect::<Vec<_>>(), vec![25]);
        // Triangles (6,2,5 → 7), (4,3,2 → 10), (7,5,9 → ?) → 26 (top × left − right).
        let rels = vec![rel(&[6, 2, 5], 7), rel(&[4, 3, 2], 10), Rel { ins: vec![Some(7), Some(5), Some(9)], out: None }];
        assert!(predictions(&rels).contains(&26));
        // Concatenation riddle: 8 (+) 3 = 511, 7 (+) 2 = 59, 9 (+) 4 = 513, 6 (+) 5 = ? → 111.
        let rels = vec![rel(&[8, 3], 511), rel(&[7, 2], 59), rel(&[9, 4], 513), Rel { ins: vec![Some(6), Some(5)], out: None }];
        assert_eq!(predictions(&rels).into_iter().collect::<Vec<_>>(), vec![111]);
    }

    /// `cargo test --release iq_missing_number_kind_timing -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn iq_missing_number_kind_timing() {
        let mut r = Rng::new(3);
        for hard in [false, true] {
            for kind in 0..19 {
                let t = std::time::Instant::now();
                let mut ok = 0;
                for _ in 0..20 {
                    if let Some((it, sp)) = build(&mut r, hard, kind) {
                        if verify(&it, &sp).is_ok() {
                            ok += 1;
                        }
                    }
                }
                println!("hard {hard} kind {kind:2}: {ok:2}/20 ok, {:?} per build", t.elapsed() / 20);
            }
        }
    }
}
