//! Harf dizisi — letter (and letter–number) series on the 29-letter Turkish alphabet.
//!
//! Medium: a constant step (forwards or backwards, wrapping past Z), steps that grow by one
//! (+1, +2, +3 …), two alternating steps, letter + its position number (A1, C3, E5 …).
//! Hard: two interleaved series (one forwards, one backwards), steps that double, growing steps
//! that wrap past Z, letter–number pairs whose number is computed from the letter's position
//! (2 × position, position², position + step index), and letter triplets.
//!
//! The classic trap is the English alphabet: one distractor always counts the last step in the
//! 26-letter alphabet (H + 5 gives M there, L in Turkish). Others are the neighbouring letters,
//! "repeat the last step", and wrong numbers.
//!
//! Oracle: tokens are parsed back into Turkish positions (no access to the generator's rule);
//! the position sequence — raw, or unwrapped past Z in either direction — must be explained by
//! the series grammar (`series::explain`). Numbers must follow their own series or a relation to
//! the letter position (m·p + c, p² + c, p + i·c); triplets must share one inner step. Exactly
//! one option may complete the sequence.

use super::common::*;
use super::item::IqItem;
use super::series;
use crate::rng::Rng;
use serde_json::json;

pub const ID: &str = "letter_series";

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Kind {
    Letters,
    Pairs,
    Triplets,
}

pub struct Spec {
    kind: Kind,
    shown: Vec<Option<String>>,
    opts: Vec<String>,
}

fn unwrap_dir(x: &[i64], up: bool) -> Vec<i64> {
    let mut out = vec![x[0]];
    for &v in &x[1..] {
        let prev = *out.last().unwrap();
        let mut u = v;
        if up {
            while u <= prev {
                u += 29;
            }
        } else {
            while u >= prev {
                u -= 29;
            }
        }
        out.push(u);
    }
    out
}

fn positions_explainable(p: &[i64]) -> bool {
    series::explainable(p) || series::explainable(&unwrap_dir(p, true)) || series::explainable(&unwrap_dir(p, false))
}

fn parse_letter(t: &str) -> Option<i64> {
    let mut c = t.chars();
    let ch = c.next()?;
    if c.next().is_some() {
        return None;
    }
    tr_pos(ch)
}

fn parse_pair(t: &str) -> Option<(i64, i64)> {
    let ch = t.chars().next()?;
    let rest: String = t.chars().skip(1).collect();
    Some((tr_pos(ch)?, rest.parse().ok()?))
}

fn parse_triplet(t: &str) -> Option<Vec<i64>> {
    let v: Option<Vec<i64>> = t.chars().map(tr_pos).collect();
    v.filter(|v| v.len() == 3)
}

fn numbers_fit(p: &[i64], n: &[i64]) -> bool {
    if series::explainable(n) {
        return true;
    }
    for m in 1..=5 {
        let c = n[0] - m * p[0];
        if p.iter().zip(n).all(|(&a, &b)| m * a + c == b) {
            return true;
        }
    }
    let c = n[0] - p[0] * p[0];
    if p.iter().zip(n).all(|(&a, &b)| a * a + c == b) {
        return true;
    }
    for step in -5..=5 {
        let c = n[0] - p[0];
        if p.iter().zip(n).enumerate().all(|(i, (&a, &b))| a + c + step * i as i64 == b) && step != 0 {
            return true;
        }
    }
    false
}

/// Does this completed token sequence follow a grammar rule?
pub fn fits(kind: Kind, toks: &[String]) -> bool {
    match kind {
        Kind::Letters => toks.iter().map(|t| parse_letter(t)).collect::<Option<Vec<i64>>>().is_some_and(|p| positions_explainable(&p)),
        Kind::Pairs => {
            let Some(v) = toks.iter().map(|t| parse_pair(t)).collect::<Option<Vec<(i64, i64)>>>() else { return false };
            let p: Vec<i64> = v.iter().map(|x| x.0).collect();
            let n: Vec<i64> = v.iter().map(|x| x.1).collect();
            positions_explainable(&p) && numbers_fit(&p, &n)
        }
        Kind::Triplets => {
            let Some(v) = toks.iter().map(|t| parse_triplet(t)).collect::<Option<Vec<Vec<i64>>>>() else { return false };
            let inner = |t: &Vec<i64>| ((t[1] - t[0]).rem_euclid(29), (t[2] - t[1]).rem_euclid(29));
            let firsts: Vec<i64> = v.iter().map(|t| t[0]).collect();
            v.iter().all(|t| inner(t) == inner(&v[0])) && positions_explainable(&firsts)
        }
    }
}

pub fn fitting(kind: Kind, shown: &[Option<String>], opts: &[String]) -> Vec<usize> {
    (0..opts.len())
        .filter(|&i| {
            let toks: Vec<String> = shown.iter().map(|t| t.clone().unwrap_or_else(|| opts[i].clone())).collect();
            fits(kind, &toks)
        })
        .collect()
}

fn l(p: i64) -> String {
    tr_at(p).to_string()
}

struct Draft {
    kind: Kind,
    /// Full sequence of tokens; the last one is the answer.
    toks: Vec<String>,
    bugs: Vec<String>,
    why: String,
}

fn steps_text(p: &[i64]) -> String {
    p.windows(2)
        .map(|w| {
            let d = w[1] - w[0];
            if d < 0 {
                format!("\u{2212}{}", -d)
            } else {
                format!("+{d}")
            }
        })
        .collect::<Vec<_>>()
        .join(", ")
}

/// English-alphabet trap: the last step counted in the 26-letter alphabet.
fn english_trap(prev: i64, step: i64) -> String {
    en_at(en_pos(tr_at(prev)) + step).to_string()
}

fn letter_draft(r: &mut Rng, p: Vec<i64>, why: String) -> Draft {
    let n = p.len();
    let ans = p[n - 1];
    let step = ans - p[n - 2];
    let prev_step = p[n - 2] - p[n - 3];
    let bugs = vec![english_trap(p[n - 2], step), l(ans + 1), l(ans - 1), l(p[n - 2] + prev_step), l(ans + 2)];
    let _ = r;
    Draft { kind: Kind::Letters, toks: p.iter().map(|&x| l(x)).collect(), bugs, why }
}

fn medium(r: &mut Rng) -> Draft {
    match r.below(5) {
        0 => {
            let k = *r.pick(&[2i64, 3, 4, 5, -2, -3, -4]);
            let a = r.range(1, 29);
            let p: Vec<i64> = (0..6).map(|i| a + k * i).collect();
            let why = format!("Her adımda {} harf {} (Türk alfabesinde, Z'den sonra A gelir). Sıradaki {}.", k.abs(), if k > 0 { "ileri" } else { "geri" }, l(p[5]));
            letter_draft(r, p, why)
        }
        1 => {
            let a = r.range(1, 20);
            let s0 = r.range(1, 3);
            let mut p = vec![a];
            for i in 0..5 {
                let last = *p.last().unwrap();
                p.push(last + s0 + i);
            }
            let why = format!("Adımlar birer büyüyor: {}. Sıradaki {}.", steps_text(&p), l(p[5]));
            letter_draft(r, p, why)
        }
        2 => {
            let (x, y) = (r.range(1, 4), r.range(2, 5));
            if x == y {
                return medium(r);
            }
            let a = r.range(1, 10);
            let mut p = vec![a];
            for i in 0..6 {
                let last = *p.last().unwrap();
                p.push(last + if i % 2 == 0 { x } else { y });
            }
            let why = format!("Adımlar dönüşümlü: +{x}, +{y}, +{x} … Sıradaki {}.", l(p[6]));
            letter_draft(r, p, why)
        }
        3 => {
            let k = r.range(2, 4);
            let a = r.range(1, 9);
            let p: Vec<i64> = (0..5).map(|i| a + k * i).collect();
            let toks: Vec<String> = p.iter().map(|&x| format!("{}{}", l(x), x)).collect();
            let ans = p[4];
            let bugs = vec![
                format!("{}{}", l(ans), en_pos(tr_at(ans))),
                format!("{}{}", english_trap(p[3], k), ans),
                format!("{}{}", l(ans + 1), ans + 1),
                format!("{}{}", l(ans), ans + k),
                format!("{}{}", l(ans - 1), ans),
            ];
            Draft { kind: Kind::Pairs, toks, bugs, why: format!("Harfler {k}'er ilerliyor, sayı harfin Türk alfabesindeki sırası: {} {}. harf.", l(ans), ans) }
        }
        _ => {
            let k = *r.pick(&[3i64, 4, 5]);
            let a = r.range(20, 29);
            let p: Vec<i64> = (0..6).map(|i| a - k * i).collect();
            let why = format!("Her adımda {k} harf geri (A'dan önce Z gelir). Sıradaki {}.", l(p[5]));
            letter_draft(r, p, why)
        }
    }
}

fn hard(r: &mut Rng) -> Draft {
    match r.below(5) {
        0 => {
            let (a, b) = (r.range(1, 9), r.range(21, 29));
            let (x, y) = (r.range(1, 3), r.range(1, 3));
            let p: Vec<i64> = (0..8).map(|i| if i % 2 == 0 { a + x * (i / 2) as i64 } else { b - y * (i / 2) as i64 }).collect();
            let n = p.len();
            let bugs = vec![l(p[n - 2] + x), l(p[n - 1] - 1), english_trap(p[n - 3], -y), l(p[n - 1] + y), l(p[n - 1] + 1)];
            let why = format!(
                "İki dizi iç içe: biri baştan {}'er ileri ({}, {}, {}, {}), öteki sondan {}'er geri ({}, {}, {}, {}).",
                x,
                l(p[0]),
                l(p[2]),
                l(p[4]),
                l(p[6]),
                y,
                l(p[1]),
                l(p[3]),
                l(p[5]),
                l(p[7])
            );
            Draft { kind: Kind::Letters, toks: p.iter().map(|&q| l(q)).collect(), bugs, why }
        }
        1 => {
            let a = r.range(1, 29);
            let mut p = vec![a];
            let mut d = r.range(1, 3);
            let steps = r.range(4, 5);
            for _ in 0..steps {
                let last = *p.last().unwrap();
                p.push(last + d);
                d *= 2;
            }
            let why = format!("Adımlar ikiye katlanıyor: {}. Sıradaki {}.", steps_text(&p), l(*p.last().unwrap()));
            let mut dr = letter_draft(r, p.clone(), why);
            dr.bugs.push(l(p[p.len() - 2] + 12));
            dr
        }
        2 => {
            let a = r.range(10, 24);
            let s0 = r.range(2, 4);
            let mut p = vec![a];
            for i in 0..5 {
                let last = *p.last().unwrap();
                p.push(last + s0 + i);
            }
            let why = format!("Adımlar birer büyüyor ({}), Z'den sonra A'dan devam. Sıradaki {}.", steps_text(&p), l(p[5]));
            letter_draft(r, p, why)
        }
        3 => {
            // Letter steps grow; the number is computed from the letter position.
            let a = r.range(1, 4);
            let mut p = vec![a];
            let s0 = r.range(2, 3);
            for i in 0..4 {
                let last = *p.last().unwrap();
                p.push(last + s0 + i);
            }
            let f = r.below(2);
            let num_of = |q: i64| if f == 0 { 2 * q } else { q * q };
            let toks: Vec<String> = p.iter().map(|&q| format!("{}{}", l(q), num_of(q))).collect();
            let ans = p[4];
            let bugs = vec![
                format!("{}{}", english_trap(p[3], ans - p[3]), num_of(ans)),
                format!("{}{}", l(ans), num_of(en_pos(tr_at(ans)))),
                format!("{}{}", l(ans + 1), num_of(ans + 1)),
                format!("{}{}", l(ans), num_of(ans) + 2),
                format!("{}{}", l(p[3] + (p[3] - p[2])), num_of(p[3] + (p[3] - p[2]))),
            ];
            let rel = if f == 0 { "harfin sırasının 2 katı" } else { "harfin sırasının karesi" };
            Draft {
                kind: Kind::Pairs,
                toks,
                bugs,
                why: format!("Harf adımları {} ; sayı {}: {} {}. harf, sayı {}.", steps_text(&p), rel, l(ans), ans, num_of(ans)).replace(" ;", ";"),
            }
        }
        _ => {
            // Triplets: each group is three letters with one inner step; groups move on.
            let inner = r.range(1, 2);
            let jump = r.range(0, 3);
            let a = r.range(1, 12);
            let firsts: Vec<i64> = (0..4).map(|i| a + (2 * inner + jump) * i).collect();
            let trip = |f: i64| format!("{}{}{}", l(f), l(f + inner), l(f + 2 * inner));
            let toks: Vec<String> = firsts.iter().map(|&f| trip(f)).collect();
            let ans = firsts[3];
            let en = |f: i64| -> String {
                let e = en_pos(tr_at(f));
                format!("{}{}{}", en_at(e), en_at(e + inner), en_at(e + 2 * inner))
            };
            let bugs = vec![trip(ans + 1), trip(ans - 1), en(ans), trip(firsts[2] + 2 * inner + 1), format!("{}{}{}", l(ans), l(ans + inner + 1), l(ans + 2 * inner + 1))];
            Draft {
                kind: Kind::Triplets,
                toks,
                bugs,
                why: format!(
                    "Her grupta harfler {inner}'er ilerliyor; gruplar arasında {jump} harf atlanıyor. Sıradaki grup {}.",
                    trip(ans)
                ),
            }
        }
    }
}

fn build(r: &mut Rng, hard_: bool) -> Option<(IqItem, Spec)> {
    let d = if hard_ { hard(r) } else { medium(r) };
    let n = d.toks.len();
    let answer = d.toks[n - 1].clone();
    let mut shown: Vec<Option<String>> = d.toks.iter().cloned().map(Some).collect();
    shown[n - 1] = None;
    let want = if hard_ { 5 } else { 4 };
    let mut ds: Vec<String> = vec![];
    for b in &d.bugs {
        if *b != answer && !ds.contains(b) && fitting(d.kind, &shown, &[b.clone()]).is_empty() {
            ds.push(b.clone());
        }
        if ds.len() == want - 1 {
            break;
        }
    }
    if ds.len() < want - 1 {
        return None;
    }
    let (opts, at) = place(r, answer, &ds);
    let terms: Vec<String> = shown.iter().map(|t| t.clone().unwrap_or_else(|| "?".into())).collect();
    let fig = json!({"layout": "series", "terms": terms, "alphabet": true});
    let item = text_item(ID, hard_, "Türk alfabesine göre (29 harf) soru işaretinin yerine ne gelmeli?", Some(fig), opts.clone(), at, d.why);
    Some((item, Spec { kind: d.kind, shown, opts }))
}

fn verify(item: &IqItem, s: &Spec) -> Result<(), String> {
    basic_checks(item)?;
    let f = fitting(s.kind, &s.shown, &s.opts);
    if f != vec![item.answer] {
        return Err(format!("{:?} {:?} options {:?}: fitting {:?}", s.kind, s.shown, s.opts, f));
    }
    Ok(())
}

pub fn gen_checked(r: &mut Rng, hard: bool) -> (IqItem, Result<(), String>) {
    retry(r, hard, build, verify)
}

pub fn gen(r: &mut Rng, hard: bool) -> IqItem {
    gen_checked(r, hard).0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iq_letter_series_doc_examples() {
        let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
        // A, C, E, H, ? gives L (positions 1, 3, 6, 10, 15); the English reading would give M.
        let shown: Vec<Option<String>> = vec![Some("A".into()), Some("C".into()), Some("E".into()), Some("H".into()), None];
        assert_eq!(fitting(Kind::Letters, &shown, &s(&["L", "M", "K"])), vec![0]);
        // A2, Ç8, G16, ? gives J26.
        assert!(fits(Kind::Pairs, &s(&["A2", "Ç8", "G16", "J26", "Ö38"])));
        assert!(!fits(Kind::Pairs, &s(&["A2", "Ç8", "G16", "J26", "Ö36"])));
    }
}
