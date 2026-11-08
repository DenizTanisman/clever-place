//! Sayı dizisi — continue a number sequence (or fill a gap in the middle).
//!
//! Medium (one operation, 5–6 terms, 4 options): constant step, ×2/×3 (or halving), ×p ± q,
//! growing steps (second differences constant), alternating steps, n² + c.
//! Hard (two-level or interleaved rules, 6–7 terms, 5 options): differences that are squares /
//! cubes / primes / Fibonacci numbers, differences that double or triple, two interleaved series,
//! alternating ×m and +k, Fibonacci-like sums, growing multipliers (×1, ×2, ×3 …), ×2 + i, a
//! period-3 step cycle, and gap items (the missing term sits inside the sequence).
//!
//! Distractors are bug-model values (continue the last step, forget the growth, apply the other
//! operation, continue the wrong sub-series), then near values; the oracle (`series::explain`)
//! must explain exactly one option.

use super::common::*;
use super::item::IqItem;
use super::series;
use crate::rng::Rng;
use serde_json::json;

pub const ID: &str = "number_series";

pub struct Spec {
    shown: Vec<Option<i64>>,
    opts: Vec<i64>,
}

struct Rule {
    terms: Vec<i64>,
    why: String,
    bugs: Vec<i64>,
}

fn diffs(s: &[i64]) -> Vec<i64> {
    s.windows(2).map(|w| w[1] - w[0]).collect()
}

fn list(v: &[i64]) -> String {
    v.iter().map(|&x| num(x)).collect::<Vec<_>>().join(", ")
}

fn signed(v: i64) -> String {
    if v < 0 {
        format!("\u{2212}{}", -v)
    } else {
        format!("+{v}")
    }
}

/// Generic bug values: continue the last step, repeat the last ratio, ± the second difference.
fn generic_bugs(t: &[i64], answer: i64) -> Vec<i64> {
    let n = t.len();
    let last = t[n - 1];
    let d = last - t[n - 2];
    let mut v = vec![last + d];
    if t[n - 2] != 0 && last % t[n - 2] == 0 {
        v.push(last * (last / t[n - 2]));
    }
    let dd = diffs(&diffs(t));
    if let Some(&e) = dd.last() {
        v.push(answer + e);
        v.push(answer - e);
    }
    v
}

/// "+ 5" / "− 5" with spaces, for formulas.
fn pm(v: i64) -> String {
    if v < 0 {
        format!("\u{2212} {}", -v)
    } else {
        format!("+ {v}")
    }
}

fn medium_rule(r: &mut Rng) -> Rule {
    // A plain constant step is the easiest medium rule: half the weight of the others.
    let pick = r.below(13);
    match if pick == 0 { 0 } else { 1 + (pick - 1) / 2 } {
        0 => {
            let a = r.range(2, 60);
            let d = *r.pick(&[7i64, 9, 11, 12, 13, 14, 15, 17, 19, 23, -7, -9, -11, -13]);
            let a = if d < 0 { a + 120 } else { a };
            let t: Vec<i64> = (0..6).map(|i| a + d * i).collect();
            Rule { why: format!("Her adımda {} (sabit adım).", signed(d)), bugs: vec![t[5] + d + 1, t[5] - d, t[5] + 2 * d], terms: t }
        }
        1 => {
            if r.chance(0.35) {
                // Halving (or thirds) downwards.
                let m = *r.pick(&[2i64, 3]);
                let base = r.range(1, 7);
                let t: Vec<i64> = (0..6).rev().map(|i| base * m.pow(i as u32)).collect();
                let last = t[4];
                Rule { why: format!("Her terim bir öncekinin {}: {} ÷ {m} = {}.", if m == 2 { "yarısı" } else { "üçte biri" }, num(last), num(t[5])), bugs: vec![t[4] - (t[3] - t[4]), t[5] * 2, t[4] - t[5] * 2], terms: t }
            } else {
                let m = *r.pick(&[2i64, 3]);
                let a = r.range(2, if m == 2 { 9 } else { 5 });
                let t: Vec<i64> = (0..6).map(|i| a * m.pow(i as u32)).collect();
                Rule { why: format!("Her terim bir öncekinin {m} katı: {} × {m} = {}.", num(t[4]), num(t[5])), bugs: vec![], terms: t }
            }
        }
        2 => {
            let (p, q) = if r.chance(0.65) { (2, *r.pick(&[-3i64, -2, -1, 1, 2, 3, 4])) } else { (3, *r.pick(&[-2i64, -1, 1, 2])) };
            let mut a = r.range(2, if p == 2 { 9 } else { 4 });
            let mut t = vec![a];
            for _ in 0..5 {
                a = a * p + q;
                t.push(a);
            }
            let qs = if q > 0 { format!("{q} fazlası") } else { format!("{} eksiği", -q) };
            Rule { why: format!("Her terim bir öncekinin {p} katının {qs}: {} × {p} {} {} = {}.", num(t[4]), if q > 0 { "+" } else { "\u{2212}" }, q.abs(), num(t[5])), bugs: vec![t[4] * p, t[4] * p - q], terms: t }
        }
        3 => {
            let a = r.range(1, 30);
            let d0 = r.range(1, 9);
            let e = r.range(1, 4) * if r.chance(0.2) { -1 } else { 1 };
            let d0 = if e < 0 { d0 + 12 } else { d0 };
            let mut t = vec![a];
            for i in 0..5 {
                let l = *t.last().unwrap();
                t.push(l + d0 + e * i);
            }
            let ds = diffs(&t);
            Rule {
                why: format!("Farklar {}: her seferinde {} değişiyor, sıradaki fark {}.", list(&ds[..4]), signed(e), num(ds[4])),
                bugs: vec![t[4] + ds[3], t[5] + e],
                terms: t,
            }
        }
        4 => {
            let a = r.range(5, 40);
            let (x, y) = if r.chance(0.5) { (r.range(4, 12), -r.range(1, 3)) } else { (r.range(2, 9), r.range(10, 19)) };
            let mut t = vec![a];
            for i in 0..6 {
                let l = *t.last().unwrap();
                t.push(l + if i % 2 == 0 { x } else { y });
            }
            Rule {
                why: format!("Adımlar sırayla {} ve {}, dönüşümlü.", signed(x), signed(y)),
                bugs: vec![t[5] + y, t[5] + x + y],
                terms: t,
            }
        }
        5 => {
            let n0 = r.range(2, 8);
            let c = *r.pick(&[-2i64, -1, 0, 1, 2, 3]);
            let t: Vec<i64> = (0..5).map(|i| (n0 + i) * (n0 + i) + c).collect();
            let cs = match c {
                0 => String::new(),
                c if c > 0 => format!(" + {c}"),
                c => format!(" \u{2212} {}", -c),
            };
            Rule {
                why: format!("Ardışık kareler{}: {}²{} = {}.", if c == 0 { "" } else { " (sabit eklemeyle)" }, n0 + 4, cs, num(t[4])),
                bugs: vec![t[3] + (t[3] - t[2]), (n0 + 4) * (n0 + 4) + c + 1],
                terms: t,
            }
        }
        _ => {
            // Growing additions: +1·k, +2·k, +3·k …
            let a = r.range(1, 20);
            let k = *r.pick(&[2i64, 3, 4, 5]);
            let mut t = vec![a];
            for i in 1..=5 {
                let l = *t.last().unwrap();
                t.push(l + k * i);
            }
            Rule {
                why: format!("Eklenen sayı her adımda {k} büyüyor: +{k}, +{}, +{} …", 2 * k, 3 * k),
                bugs: vec![t[4] + 4 * k, t[5] + k],
                terms: t,
            }
        }
    }
}

fn hard_rule(r: &mut Rng) -> Rule {
    match r.below(9) {
        0 => {
            // Differences from a known sequence.
            let (name, seq): (&str, Vec<i64>) = match r.below(4) {
                0 => ("ardışık kareler", (1..20).map(|i| i * i).collect()),
                1 => ("ardışık küpler", (1..10).map(|i| i * i * i).collect()),
                2 => ("ardışık asal sayılar", vec![2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41]),
                _ => ("Fibonacci sayıları", vec![1, 2, 3, 5, 8, 13, 21, 34, 55, 89]),
            };
            let j = r.below(seq.len().min(5) - 1);
            let a = r.range(1, 25);
            let mut t = vec![a];
            for i in 0..6 {
                let l = *t.last().unwrap();
                t.push(l + seq[j + i]);
            }
            let ds = diffs(&t);
            Rule {
                why: format!("Farklar {}: {name}. Sıradaki fark {}.", list(&ds[..5]), num(ds[5])),
                bugs: vec![t[5] + ds[4], t[5] + ds[4] + (ds[4] - ds[3]), t[6] + 1],
                terms: t,
            }
        }
        1 => {
            let m = *r.pick(&[2i64, 2, 3]);
            let a = r.range(1, 20);
            let d0 = r.range(1, 5);
            let mut t = vec![a];
            let mut d = d0;
            for _ in 0..6 {
                let l = *t.last().unwrap();
                t.push(l + d);
                d *= m;
            }
            let ds = diffs(&t);
            Rule {
                why: format!("Farklar {}: her fark bir öncekinin {m} katı.", list(&ds)),
                bugs: vec![t[5] + ds[4] + (ds[4] - ds[3]), t[5] * m, t[5] + ds[4]],
                terms: t,
            }
        }
        2 => {
            // Two interleaved series; 7 shown, the 8th asked (it belongs to the second series).
            let a = r.range(1, 20);
            let d = r.range(2, 9) * if r.chance(0.3) { -1 } else { 1 };
            let a = if d < 0 { a + 40 } else { a };
            let b = r.range(1, 5);
            let geo = r.chance(0.5);
            let m = *r.pick(&[2i64, 3]);
            let e = r.range(3, 12);
            let mut t = vec![];
            for i in 0..8 {
                if i % 2 == 0 {
                    t.push(a + d * (i / 2) as i64);
                } else if geo {
                    t.push(b * m.pow((i / 2) as u32));
                } else {
                    t.push(b + e * (i / 2) as i64);
                }
            }
            let second = if geo { format!("{m} katına çıkıyor") } else { format!("{} artıyor", e) };
            Rule {
                why: format!(
                    "İki dizi iç içe: tek sıradakiler {} ({}), çift sıradakiler {} ({}).",
                    list(&[t[0], t[2], t[4], t[6]]),
                    signed(d),
                    list(&[t[1], t[3], t[5], t[7]]),
                    second
                ),
                bugs: vec![t[6] + d, t[6] + (t[6] - t[5])],
                terms: t,
            }
        }
        3 => {
            let m = *r.pick(&[2i64, 3]);
            let k = *r.pick(&[-4i64, -3, -2, -1, 1, 2, 3, 4, 5, 6]);
            let mut a = r.range(1, 6);
            let mul_first = r.chance(0.5);
            let mut t = vec![a];
            for i in 0..6 {
                a = if (i % 2 == 0) == mul_first { a * m } else { a + k };
                t.push(a);
            }
            let next_mul = (6 % 2 == 0) == mul_first;
            Rule {
                why: format!("İşlemler dönüşümlü: × {m} ve {}. Sıradaki işlem {}.", signed(k), if next_mul { format!("× {m}") } else { signed(k) }),
                bugs: vec![if next_mul { t[5] + k } else { t[5] * m }, t[5] * m + k, t[6] + 1],
                terms: t,
            }
        }
        4 => {
            let c = *r.pick(&[0i64, 0, 1, -1, 2]);
            let mut t = vec![r.range(1, 6), r.range(2, 9)];
            for _ in 0..5 {
                let l = t.len();
                t.push(t[l - 1] + t[l - 2] + c);
            }
            let cs = match c {
                0 => String::new(),
                c if c > 0 => format!(", sonra +{c}"),
                c => format!(", sonra \u{2212}{}", -c),
            };
            Rule {
                why: format!("Her terim önceki iki terimin toplamı{cs}: {} + {}{} = {}.", num(t[4]), num(t[5]), if c == 0 { String::new() } else { format!(" {}", pm(c)) }, num(t[6])),
                bugs: vec![t[5] + (t[5] - t[4]), t[5] + t[4] + c + 1, t[5] + t[3] + c],
                terms: t,
            }
        }
        5 => {
            let r0 = r.range(1, 2);
            let mut a = r.range(1, 5);
            let mut t = vec![a];
            for i in 0..5 {
                a *= r0 + i;
                t.push(a);
            }
            Rule {
                why: format!("Çarpanlar birer büyüyor: × {}, × {}, × {} … Sıradaki × {}.", r0, r0 + 1, r0 + 2, r0 + 4),
                bugs: vec![t[4] * (r0 + 3), t[4] * (r0 + 5), t[4] + (t[4] - t[3])],
                terms: t,
            }
        }
        6 => {
            let tq = r.range(1, 3);
            let q = *r.pick(&[0i64, 1, -1]);
            let mut a = r.range(1, 6);
            let mut t = vec![a];
            for i in 0..5 {
                a = 2 * a + q + tq * i;
                t.push(a);
            }
            Rule {
                why: format!(
                    "Her terim bir öncekinin 2 katı, eklenen sayı her adımda {tq} büyüyor: {} × 2 {} = {}.",
                    num(t[4]),
                    pm(q + tq * 4),
                    num(t[5])
                ),
                bugs: vec![2 * t[4] + q + tq * 3, 2 * t[4], 2 * t[4] + q + tq * 5],
                terms: t,
            }
        }
        7 => {
            let (x, y, z) = (r.range(3, 9), r.range(10, 20), -r.range(2, 8));
            let mut a = r.range(5, 30);
            let mut t = vec![a];
            for i in 0..7 {
                a += [x, y, z][i % 3];
                t.push(a);
            }
            Rule {
                why: format!("Adımlar üçlü bir döngüde tekrar ediyor: {}, {}, {}.", signed(x), signed(y), signed(z)),
                bugs: vec![t[6] + x, t[6] + y],
                terms: t,
            }
        }
        _ => {
            let n0 = r.range(1, 6);
            let c = *r.pick(&[-1i64, 1, 2, -2, 3]);
            let t: Vec<i64> = (0..6).map(|i| (n0 + i).pow(3) + c).collect();
            Rule {
                why: format!("Ardışık küpler, {} ile: {}³ {} = {}.", signed(c), n0 + 5, pm(c), num(t[5])),
                bugs: vec![t[4] + (t[4] - t[3]), (n0 + 5).pow(2) + c],
                terms: t,
            }
        }
    }
}

fn build(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    let rule = if hard { hard_rule(r) } else { medium_rule(r) };
    let t = rule.terms;
    if t.iter().any(|&x| x.abs() > 9999) {
        return None;
    }
    let n = if hard { 5 } else { 4 };
    // Hard gap items: take a medium-or-hard rule and hide a middle term instead of the next one.
    let gap = hard && r.chance(0.25);
    let (shown, answer, bugs): (Vec<Option<i64>>, i64, Vec<i64>) = if gap {
        let g = r.range(2, t.len() as i64 - 3) as usize;
        let mut sh: Vec<Option<i64>> = t.iter().map(|&x| Some(x)).collect();
        sh[g] = None;
        let a = t[g];
        let mut bugs = vec![t[g - 1] + (t[g - 1] - t[g - 2]), (t[g - 1] + t[g + 1]) / 2];
        bugs.push(t[g + 1] - (t[g + 2] - t[g + 1]));
        (sh, a, bugs)
    } else {
        let a = *t.last().unwrap();
        let mut sh: Vec<Option<i64>> = t.iter().map(|&x| Some(x)).collect();
        *sh.last_mut().unwrap() = None;
        let mut bugs = rule.bugs.clone();
        bugs.extend(generic_bugs(&t[..t.len() - 1], a));
        (sh, a, bugs)
    };
    let spread = (answer.abs() / 12).max(3);
    let min = if t.iter().all(|&x| x >= 0) { 0 } else { -9999 };
    let sh2 = shown.clone();
    let ok = move |v: i64| series::fitting_options(&sh2, &[v]).is_empty();
    let (opts, at) = numeric_options(r, answer, &bugs, n, spread, min, &ok)?;
    let terms: Vec<String> = shown.iter().map(|x| x.map(num).unwrap_or_else(|| "?".into())).collect();
    let prompt = if gap { "Dizide eksik olan terim hangisi?" } else { "Dizide soru işaretinin yerine hangi sayı gelmeli?" };
    let why = if gap { format!("{} Eksik terim {}.", rule.why, num(answer)) } else { rule.why };
    let item = text_item(ID, hard, prompt, Some(json!({"layout": "series", "terms": terms})), strs(&opts), at, why);
    Some((item, Spec { shown, opts }))
}

fn verify(item: &IqItem, s: &Spec) -> Result<(), String> {
    basic_checks(item)?;
    let fit = series::fitting_options(&s.shown, &s.opts);
    if fit != vec![item.answer] {
        return Err(format!("series {:?} options {:?}: fitting {:?}, answer {}", s.shown, s.opts, fit, item.answer));
    }
    Ok(())
}

pub fn gen_checked(r: &mut Rng, hard: bool) -> (IqItem, Result<(), String>) {
    retry(r, hard, build, verify)
}

pub fn gen(r: &mut Rng, hard: bool) -> IqItem {
    gen_checked(r, hard).0
}
