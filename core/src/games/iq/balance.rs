//! Terazi — balance scales and symbol equations.
//!
//! - **Scales** (WAIS Figure Weights style): balanced scales relate shapes; pick the group that
//!   balances the last scale. Medium: 2–3 shapes, 2 scales; hard: 3–4 shapes, 3 scales that need
//!   substitution. Options are drawn shape groups (`{"layout":"symbols"}` figures).
//! - **Symbol equations** (viral picture puzzles): shapes stand for numbers. Medium: solvable one
//!   shape at a time; hard: simultaneous sums and a query that tests operator precedence.
//! - **Letter algebra**: A + B = 13, A − B = 3, A × B = ?; hard: a combination that is fixed even
//!   though the single letters are not (A − 4B + 2C = 16, 2A + 7B − 5C = 83, A + B − C = ?).
//! - **Precedence traps**: 6 + 6 ÷ 6 × 6 − 6 = ?
//!
//! Oracle: brute force over every assignment of positive integer weights (scales: 1..12 per
//! shape; equations: 0..30) consistent with the given scales or equations. The option that
//! balances / the value of the query must be the same in every solution, and every other option
//! must fail in every solution. Expressions are evaluated by an independent precedence parser
//! (× and ÷ before + and −). Distractors come from typical mistakes: left-to-right evaluation,
//! one substitution step missed, a shape counted once too often.

use super::common::*;
use super::item::{IqItem, IqOption};
use crate::rng::Rng;
use serde_json::{json, Value};

pub const ID: &str = "balance";

const SHAPES: [&str; 5] = ["t", "s", "c", "d", "h"];
const SHAPE_NAME: [&str; 5] = ["üçgen", "kare", "daire", "elmas", "altıgen"];

#[derive(Clone, Debug)]
pub struct Scale {
    left: Vec<usize>,
    right: Vec<usize>,
}

#[derive(Clone, Debug)]
pub enum Spec {
    Scales { k: usize, scales: Vec<Scale>, ask: Vec<usize>, opts: Vec<Vec<usize>> },
    Eq { rows: Vec<Vec<String>>, query: Vec<String>, opts: Vec<i64>, lo: i64 },
    Plain { expr: Vec<String>, opts: Vec<i64> },
}

fn weight(g: &[usize], w: &[i64]) -> i64 {
    g.iter().map(|&s| w[s]).sum()
}

/// All weight vectors (1..=12) for k shapes satisfying every scale.
fn scale_solutions(k: usize, scales: &[Scale]) -> Vec<Vec<i64>> {
    let mut out = vec![];
    let mut w = vec![1i64; k];
    loop {
        if scales.iter().all(|s| weight(&s.left, &w) == weight(&s.right, &w)) {
            out.push(w.clone());
        }
        let mut i = 0;
        loop {
            if i == k {
                return out;
            }
            w[i] += 1;
            if w[i] <= 12 {
                break;
            }
            w[i] = 1;
            i += 1;
        }
    }
}

fn group_fig(g: &[usize]) -> Value {
    json!({"layout": "symbols", "items": g.iter().map(|&s| SHAPES[s]).collect::<Vec<_>>()})
}

fn scale_json(s: &Scale) -> Value {
    json!({"left": s.left.iter().map(|&x| SHAPES[x]).collect::<Vec<_>>(), "right": s.right.iter().map(|&x| SHAPES[x]).collect::<Vec<_>>()})
}

fn random_group(r: &mut Rng, k: usize, max: usize) -> Vec<usize> {
    let n = r.range(1, max as i64) as usize;
    let mut g: Vec<usize> = (0..n).map(|_| r.below(k)).collect();
    g.sort();
    g
}

/// Smallest group of shapes (by count) with the given weight, using the allowed shapes.
fn groups_of_weight(target: i64, w: &[i64], max_len: usize) -> Vec<Vec<usize>> {
    let k = w.len();
    let mut out = vec![];
    fn rec(start: usize, left: i64, cur: &mut Vec<usize>, w: &[i64], k: usize, max_len: usize, out: &mut Vec<Vec<usize>>) {
        if left == 0 && !cur.is_empty() {
            out.push(cur.clone());
            return;
        }
        if left < 0 || cur.len() == max_len {
            return;
        }
        for s in start..k {
            cur.push(s);
            rec(s, left - w[s], cur, w, k, max_len, out);
            cur.pop();
        }
    }
    rec(0, target, &mut vec![], w, k, max_len, &mut out);
    out
}

fn scales_item(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    let k = if hard { r.range(3, 4) as usize } else { r.range(2, 3) as usize };
    let mut w: Vec<i64> = (0..k).map(|_| r.range(1, 6)).collect();
    w[0] = 1.max(w[0].min(3));
    let mut sorted = w.clone();
    sorted.sort();
    sorted.dedup();
    if sorted.len() != k {
        return None;
    }
    let nscales = if hard { 3 } else { k };
    let mut scales: Vec<Scale> = vec![];
    for _ in 0..40 {
        if scales.len() == nscales {
            break;
        }
        let left = random_group(r, k, if hard { 3 } else { 2 });
        let cands: Vec<Vec<usize>> = groups_of_weight(weight(&left, &w), &w, 4).into_iter().filter(|g| g.iter().all(|s| !left.contains(s))).collect();
        if cands.is_empty() {
            continue;
        }
        let right = r.pick(&cands).clone();
        let same = |s: &Scale| (s.left == left && s.right == right) || (s.left == right && s.right == left);
        if scales.iter().any(same) {
            continue;
        }
        scales.push(Scale { left, right });
    }
    if scales.len() < nscales {
        return None;
    }
    let sols = scale_solutions(k, &scales);
    // The scales must fix every ratio (all solutions are multiples of one vector).
    if sols.is_empty() || !sols.iter().all(|s| (0..k).all(|i| s[i] * w[0] == w[i] * s[0])) {
        return None;
    }
    let ask = random_group(r, k, if hard { 3 } else { 2 });
    let target = weight(&ask, &w);
    // Answer: a group of a different make-up with the same weight.
    let answers: Vec<Vec<usize>> = groups_of_weight(target, &w, 5).into_iter().filter(|g| g.iter().all(|s| !ask.contains(s))).collect();
    if answers.is_empty() {
        return None;
    }
    let answer = r.pick(&answers).clone();
    // Distractors: one unit too heavy / too light, or the same count of the wrong shape.
    let mut ds: Vec<Vec<usize>> = vec![];
    let mut tries = 0;
    while ds.len() < 3 && tries < 200 {
        tries += 1;
        let dw = target + *r.pick(&[-2i64, -1, 1, 1, 2, w[0], -w[0]]);
        if dw <= 0 {
            continue;
        }
        let gs: Vec<Vec<usize>> = groups_of_weight(dw, &w, 5).into_iter().filter(|g| !ds.contains(g) && *g != answer).collect();
        if gs.is_empty() {
            continue;
        }
        // Prefer groups as long as the answer so size gives nothing away.
        let same_len: Vec<Vec<usize>> = gs.iter().filter(|g| (g.len() as i64 - answer.len() as i64).abs() <= 1).cloned().collect();
        let g = if !same_len.is_empty() { r.pick(&same_len).clone() } else { r.pick(&gs).clone() };
        ds.push(g);
    }
    if ds.len() < 3 {
        return None;
    }
    let (opts, at) = place(r, answer.clone(), &ds);
    let fig = json!({"layout": "scales", "scales": scales.iter().map(scale_json).collect::<Vec<_>>(),
                     "ask": {"left": ask.iter().map(|&x| SHAPES[x]).collect::<Vec<_>>(), "right": ["?"]}});
    let ws: Vec<String> = (0..k).map(|i| format!("{} = {}", SHAPE_NAME[i], w[i])).collect();
    let why = format!(
        "Teraziler ağırlıkları belirliyor (en hafif şekil 1 birim sayılırsa): {}. Soldaki grup {} birim; doğru seçenek de {} birim.",
        ws.join(", "),
        target,
        weight(&answer, &w)
    );
    let item = IqItem {
        cat: ID,
        hard,
        prompt: "Teraziler dengede. Son teraziyi hangi grup dengeler?".into(),
        figure: Some(fig),
        options: opts.iter().map(|g| IqOption::Figure(group_fig(g))).collect(),
        answer: at,
        typed: None,
        why,
    };
    Some((item, Spec::Scales { k, scales, ask, opts }))
}

// ------------------------------------------------------------------------------- expressions

/// Evaluate tokens with precedence; variables come from `val` (shape token or letter).
pub fn eval_tokens(toks: &[String], val: &dyn Fn(&str) -> Option<i64>) -> Option<i64> {
    // Parse into terms of a sum: each term is a product/quotient chain.
    let mut sum = 0i64;
    let mut sign = 1i64;
    let mut term: Option<i64> = None;
    let mut pending: Option<char> = None;
    let atom = |t: &str| -> Option<i64> {
        if let Some(v) = parse_num(t) {
            return Some(v);
        }
        // Coefficient + letter ("2X").
        let digits_part: String = t.chars().take_while(|c| c.is_ascii_digit()).collect();
        if !digits_part.is_empty() && digits_part.len() < t.len() {
            let coef: i64 = digits_part.parse().ok()?;
            return val(&t[digits_part.len()..]).map(|v| coef * v);
        }
        val(t)
    };
    for t in toks {
        match t.as_str() {
            "+" | "\u{2212}" => {
                sum += sign * term?;
                sign = if t == "+" { 1 } else { -1 };
                term = None;
            }
            "×" => pending = Some('*'),
            "÷" => pending = Some('/'),
            _ => {
                let v = atom(t)?;
                term = Some(match (term, pending.take()) {
                    (None, _) => v,
                    (Some(a), Some('*')) => a.checked_mul(v)?,
                    (Some(a), Some('/')) => {
                        if v == 0 || a % v != 0 {
                            return None;
                        }
                        a / v
                    }
                    _ => return None,
                });
            }
        }
    }
    Some(sum + sign * term?)
}

/// Left-to-right evaluation (the classic mistake).
fn eval_ltr(toks: &[String], val: &dyn Fn(&str) -> Option<i64>) -> Option<i64> {
    let mut acc: Option<i64> = None;
    let mut op = '+';
    for t in toks {
        match t.as_str() {
            "+" => op = '+',
            "\u{2212}" => op = '-',
            "×" => op = '*',
            "÷" => op = '/',
            _ => {
                let v = parse_num(t).or_else(|| val(t))?;
                acc = Some(match (acc, op) {
                    (None, _) => v,
                    (Some(a), '+') => a + v,
                    (Some(a), '-') => a - v,
                    (Some(a), '*') => a * v,
                    (Some(a), _) => {
                        if v == 0 || a % v != 0 {
                            return None;
                        }
                        a / v
                    }
                });
            }
        }
    }
    acc
}

fn vars_of(rows: &[Vec<String>], query: &[String]) -> Vec<String> {
    let mut v: Vec<String> = vec![];
    for t in rows.iter().flatten().chain(query.iter()) {
        let name: String = t.chars().skip_while(|c| c.is_ascii_digit()).collect();
        let is_var = t.starts_with('#') || (name.len() == 1 && name.chars().all(|c| c.is_ascii_uppercase()));
        if is_var && !name.is_empty() && !v.contains(&name) {
            v.push(name);
        }
    }
    v
}

/// Every value the query takes over all assignments (lo..=30) satisfying the rows.
fn eq_predictions(rows: &[Vec<String>], query: &[String], lo: i64) -> Vec<i64> {
    let vars = vars_of(rows, query);
    let n = vars.len();
    let mut vals = vec![lo; n];
    let mut out = vec![];
    loop {
        let get = |t: &str| vars.iter().position(|x| x == t).map(|i| vals[i]);
        let ok = rows.iter().all(|row| {
            let eq = row.iter().position(|t| t == "=").unwrap();
            let lhs = eval_tokens(&row[..eq], &get);
            let rhs = eval_tokens(&row[eq + 1..], &get);
            lhs.is_some() && lhs == rhs
        });
        if ok {
            if let Some(q) = eval_tokens(query, &get) {
                if !out.contains(&q) {
                    out.push(q);
                }
            }
        }
        let mut i = 0;
        loop {
            if i == n {
                return out;
            }
            vals[i] += 1;
            if vals[i] <= 30 {
                break;
            }
            vals[i] = lo;
            i += 1;
        }
    }
}

fn t(s: &str) -> String {
    s.to_string()
}

fn sh(i: usize) -> String {
    format!("#{}", SHAPES[i])
}

fn eq_finish(
    r: &mut Rng,
    hard: bool,
    prompt: &str,
    rows: Vec<Vec<String>>,
    query: Vec<String>,
    lo: i64,
    answer: i64,
    bugs: Vec<i64>,
    why: String,
) -> Option<(IqItem, Spec)> {
    let preds = eq_predictions(&rows, &query, lo);
    if preds != vec![answer] {
        return None;
    }
    let n = if hard { 5 } else { 4 };
    let (opts, at) = numeric_options(r, answer, &bugs, n, (answer.abs() / 8).max(3), -99, &|v| v != answer)?;
    let mut shown = rows.clone();
    let mut q = query.clone();
    q.push(t("="));
    q.push(t("?"));
    shown.push(q);
    let fig = json!({"layout": "equations", "rows": shown});
    let item = text_item(ID, hard, prompt, Some(fig), strs(&opts), at, why);
    Some((item, Spec::Eq { rows, query, opts, lo }))
}

fn symbols_item(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    let mut idx: Vec<usize> = (0..5).collect();
    r.shuffle(&mut idx);
    let (a, b, c) = (idx[0], idx[1], idx[2]);
    let (va, vb, vc) = (r.range(2, 9), r.range(2, 9), r.range(2, 9));
    if va == vb || vb == vc || va == vc {
        return None;
    }
    let val = |i: usize| if i == a { va } else if i == b { vb } else { vc };
    let get = |s: &str| -> Option<i64> { (0..5).find(|&i| SHAPES[i] == &s[1..]).map(val) };
    let (rows, query): (Vec<Vec<String>>, Vec<String>) = if !hard {
        (
            vec![
                vec![sh(a), t("+"), sh(a), t("+"), sh(a), t("="), num(3 * va)],
                vec![sh(a), t("+"), sh(b), t("+"), sh(b), t("="), num(va + 2 * vb)],
                vec![sh(b), t("×"), sh(c), t("="), num(vb * vc)],
            ],
            vec![sh(c), t("+"), sh(a), t("×"), sh(b)],
        )
    } else {
        (
            vec![
                vec![sh(a), t("+"), sh(b), t("="), num(va + vb)],
                vec![sh(b), t("+"), sh(c), t("="), num(vb + vc)],
                vec![sh(a), t("+"), sh(c), t("="), num(va + vc)],
            ],
            if r.chance(0.5) { vec![sh(a), t("+"), sh(b), t("×"), sh(c), t("\u{2212}"), sh(a)] } else { vec![sh(c), t("×"), sh(c), t("\u{2212}"), sh(a), t("×"), sh(b)] },
        )
    };
    let answer = eval_tokens(&query, &get)?;
    let ltr = eval_ltr(&query, &get).unwrap_or(answer + 7);
    let bugs = vec![ltr, answer + va, answer - vc, answer + 1];
    let ws = format!(
        "{} = {}, {} = {}, {} = {}",
        SHAPE_NAME[a], va, SHAPE_NAME[b], vb, SHAPE_NAME[c], vc
    );
    let why = if hard {
        format!("Üç denklemi topla ve ikiye böl: üç şeklin toplamı {}. Her denklemi bundan çıkar: {ws}. Çarpma önce yapılır: sonuç {}.", va + vb + vc, num(answer))
    } else {
        format!("Sırayla çöz: {ws}. Çarpma toplamadan önce yapılır: sonuç {}.", num(answer))
    };
    eq_finish(r, hard, "Her şekil bir sayı. Son satırın sonucu ne?", rows, query, 1, answer, bugs, why)
}

fn letters_item(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    if !hard {
        let (a, b) = (r.range(4, 20), r.range(1, 12));
        if a <= b {
            return None;
        }
        let rows = vec![vec![t("A"), t("+"), t("B"), t("="), num(a + b)], vec![t("A"), t("\u{2212}"), t("B"), t("="), num(a - b)]];
        let query = if r.chance(0.5) { vec![t("A"), t("×"), t("B")] } else { vec![t("A"), t("×"), t("A"), t("\u{2212}"), t("B")] };
        let get = |s: &str| match s {
            "A" => Some(a),
            "B" => Some(b),
            _ => None,
        };
        let answer = eval_tokens(&query, &get)?;
        let bugs = vec![(a + b) * (a - b), a * a, answer + b, eval_ltr(&query, &get).unwrap_or(answer + 3)];
        let why = format!("İki denklemi topla: 2A = {}, yani A = {a}, B = {b}. Sonuç {}.", 2 * a, num(answer));
        eq_finish(r, false, "Harfler birer sayı. Sonuç ne?", rows, query, 0, answer, bugs, why)
    } else if r.chance(0.5) {
        // A combination fixed by the equations even though A, B, C are not.
        let (p, q) = (r.range(1, 3), r.range(1, 3));
        // eq1 = u, eq2 = v, with p·eq1 + q·eq2 = m·(A + B − C) for a small m: choose coefficients.
        let (a1, b1, c1) = (1i64, -r.range(2, 5), r.range(1, 3));
        let m = p + q;
        // Need p·(a1, b1, −c1… ) + q·(a2, b2, c2) = m·(1, 1, −1).
        let a2 = (m - p * a1) / q;
        let b2 = (m - p * b1) / q;
        let c2 = (-m - p * c1) / q;
        if (m - p * a1) % q != 0 || (m - p * b1) % q != 0 || (-m - p * c1) % q != 0 {
            return None;
        }
        let (va, vb, vc) = (r.range(3, 12), r.range(1, 6), r.range(1, 6));
        let e1 = a1 * va + b1 * vb + c1 * vc;
        let e2 = a2 * va + b2 * vb + c2 * vc;
        let term = |coef: i64, name: &str, first: bool| -> Vec<String> {
            let mut v = vec![];
            if !first {
                v.push(if coef < 0 { t("\u{2212}") } else { t("+") });
            } else if coef < 0 {
                return vec![];
            }
            let c = coef.abs();
            v.push(if c == 1 { name.to_string() } else { format!("{c}{name}") });
            v
        };
        if a1 <= 0 || a2 <= 0 || b2 == 0 || c2 == 0 {
            return None;
        }
        let row = |a: i64, b: i64, c: i64, rhs: i64| -> Vec<String> {
            let mut v = term(a, "A", true);
            v.extend(term(b, "B", false));
            v.extend(term(c, "C", false));
            v.push(t("="));
            v.push(num(rhs));
            v
        };
        let rows = vec![row(a1, b1, c1, e1), row(a2, b2, c2, e2)];
        let query = vec![t("A"), t("+"), t("B"), t("\u{2212}"), t("C")];
        let answer = va + vb - vc;
        if (p * e1 + q * e2) != m * answer {
            return None;
        }
        let bugs = vec![e1 + e2, (e1 + e2) / 2, answer + 1, e1 - e2];
        let why = format!(
            "A, B, C tek tek bulunamaz ama gerekmez: {}. denklemin {p} katı ile {}. denklemin {q} katını topla, {m}·(A + B \u{2212} C) = {} çıkar. Sonuç {answer}.",
            1,
            2,
            p * e1 + q * e2
        );
        eq_finish(r, true, "Harfler birer tam sayı. A + B \u{2212} C kaç?", rows, query, -20, answer, bugs, why)
    } else {
        let (x, y) = (r.range(2, 9), r.range(1, 9));
        let rows = vec![vec![t("2X"), t("+"), t("Y"), t("="), num(2 * x + y)], vec![t("X"), t("+"), t("2Y"), t("="), num(x + 2 * y)]];
        let query = vec![t("X"), t("+"), t("Y")];
        let answer = x + y;
        let bugs = vec![2 * x + y, x + 2 * y, (3 * x + 3 * y) / 2 + 1, answer * 2];
        let why = format!("İki denklemi topla: 3X + 3Y = {}, yani X + Y = {answer}.", 3 * answer);
        eq_finish(r, true, "Harfler birer sayı. X + Y kaç?", rows, query, 0, answer, bugs, why)
    }
}

fn plain_item(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    let n = r.range(2, 9);
    let m = r.range(2, 6);
    let expr: Vec<String> = if !hard {
        match r.below(3) {
            0 => vec![num(n), t("+"), num(n), t("÷"), num(n), t("×"), num(n), t("\u{2212}"), num(n)],
            1 => vec![num(n), t("+"), num(m), t("×"), num(n), t("\u{2212}"), num(m)],
            _ => vec![num(n * m), t("÷"), num(m), t("+"), num(m), t("×"), num(n)],
        }
    } else {
        match r.below(2) {
            0 => vec![num(n), t("\u{2212}"), num(n * m), t("÷"), num(m), t("×"), num(n), t("+"), num(m)],
            _ => vec![num(n * m), t("÷"), num(n), t("×"), num(m), t("\u{2212}"), num(n), t("×"), num(m), t("+"), num(n)],
        }
    };
    let answer = eval_tokens(&expr, &|_| None)?;
    let ltr = eval_ltr(&expr, &|_| None);
    let mut bugs = vec![answer + n, answer - m, answer + 2 * n];
    if let Some(l) = ltr {
        bugs.insert(0, l);
    }
    let num_opts = if hard { 5 } else { 4 };
    let (opts, at) = numeric_options(r, answer, &bugs, num_opts, (answer.abs() / 6).max(3), -99, &|v| v != answer)?;
    let mut shown = expr.clone();
    shown.push(t("="));
    shown.push(t("?"));
    let fig = json!({"layout": "equations", "rows": [shown]});
    let why = format!(
        "İşlem önceliği: önce çarpma ve bölme (soldan sağa), sonra toplama ve çıkarma. Sonuç {}{}.",
        num(answer),
        ltr.filter(|&l| l != answer).map(|l| format!("; soldan sağa gidersen yanlışlıkla {} bulursun", num(l))).unwrap_or_default()
    );
    let item = text_item(ID, hard, "İşlemin sonucu kaç?", Some(fig), strs(&opts), at, why);
    Some((item, Spec::Plain { expr, opts }))
}

fn pick_kind(r: &mut Rng, _hard: bool) -> usize {
    r.below(10)
}

fn build(r: &mut Rng, hard: bool, kind: usize) -> Option<(IqItem, Spec)> {
    match kind {
        0..=3 => scales_item(r, hard),
        4..=6 => symbols_item(r, hard),
        7 | 8 => letters_item(r, hard),
        _ => plain_item(r, hard),
    }
}

fn verify(item: &IqItem, s: &Spec) -> Result<(), String> {
    basic_checks(item)?;
    match s {
        Spec::Scales { k, scales, ask, opts } => {
            let sols = scale_solutions(*k, scales);
            if sols.is_empty() {
                return Err("no weights".into());
            }
            let always: Vec<usize> = (0..opts.len()).filter(|&i| sols.iter().all(|w| weight(&opts[i], w) == weight(ask, w))).collect();
            let sometimes: Vec<usize> = (0..opts.len()).filter(|&i| sols.iter().any(|w| weight(&opts[i], w) == weight(ask, w))).collect();
            if always != vec![item.answer] || sometimes != always {
                return Err(format!("balancing options {always:?} / {sometimes:?}"));
            }
        }
        Spec::Eq { rows, query, opts, lo } => {
            let p = eq_predictions(rows, query, *lo);
            if p.len() != 1 || opts[item.answer] != p[0] || opts.iter().filter(|o| p.contains(o)).count() != 1 {
                return Err(format!("query values {p:?}, options {opts:?}"));
            }
        }
        Spec::Plain { expr, opts } => {
            let v = eval_tokens(expr, &|_| None);
            if v != Some(opts[item.answer]) || opts.iter().filter(|&&o| Some(o) == v).count() != 1 {
                return Err(format!("value {v:?}, options {opts:?}"));
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
    fn iq_balance_parser_and_doc_examples() {
        let toks = |s: &str| s.split(' ').map(|x| x.replace('-', "\u{2212}")).collect::<Vec<_>>();
        assert_eq!(eval_tokens(&toks("5 + 5 × 5 - 5"), &|_| None), Some(25));
        assert_eq!(eval_tokens(&toks("8 - 8 ÷ 4 × 3"), &|_| None), Some(2));
        assert_eq!(eval_tokens(&toks("1 + 1 + 1 × 0 + 1"), &|_| None), Some(3));
        assert_eq!(eval_ltr(&toks("5 + 5 × 5 - 5"), &|_| None), Some(45));
        // A − 4B + 2C = 16, 2A + 7B − 5C = 83: A + B − C = 33 in every integer solution.
        let rows = vec![toks("A - 4B + 2C = 16"), toks("2A + 7B - 5C = 83")];
        assert_eq!(eq_predictions(&rows, &toks("A + B - C"), -20), vec![33]);
        // Doc scale example: ▲▲ = ■, ■▲ = ●; ●● weighs 6 ▲.
        let scales = vec![Scale { left: vec![0, 0], right: vec![1] }, Scale { left: vec![1, 0], right: vec![2] }];
        let sols = scale_solutions(3, &scales);
        assert!(sols.iter().all(|w| 2 * w[2] == 6 * w[0]));
    }
}
