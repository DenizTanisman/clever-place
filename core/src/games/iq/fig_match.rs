//! `matchstick`: a false equation in seven-segment matchstick digits; move one (medium) or two
//! (hard) matches to make it true. The "=" sign is fixed; "+" can become "−" and back.
//!
//! Font: 0 abcdef, 1 bc, 2 abdeg, 3 abcdg, 4 bcfg, 5 acdfg, 6 acdefg, 7 abc (3 matches),
//! 8 all, 9 abcdfg. Equations: A ± B = C with one-digit A, B and a one- or two-digit C.
//!
//! Generator: start from a true equation and move k matches at random. Oracle: brute force
//! every way to move exactly k matches (no fewer) from the drawn equation; exactly one true
//! equation may come out, and it must be the single option that matches. Every option is a
//! true equation, so "pick the true one" does not help: the distractors are the true equations
//! nearest to the puzzle that need a different number of moves (or adding/removing a match).

use super::fig_common::*;
use crate::games::iq::item::{IqItem, IqOption};
use crate::rng::Rng;
use serde_json::{json, Value};

const DIGITS: [u8; 10] = [0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F];
const PLUS: u8 = 3;
const MINUS: u8 = 1;

/// Slots: A, op, B, C… (each a bit mask); "=" is implicit between B and C.
type Eq = Vec<u8>;

fn digit(m: u8) -> Option<i64> {
    DIGITS.iter().position(|&d| d == m).map(|i| i as i64)
}

fn value(e: &Eq) -> Option<(i64, char, i64, i64)> {
    let a = digit(e[0])?;
    let op = match e[1] {
        PLUS => '+',
        MINUS => '−',
        _ => return None,
    };
    let b = digit(e[2])?;
    let mut c = 0;
    for (i, &m) in e[3..].iter().enumerate() {
        let d = digit(m)?;
        if i == 0 && d == 0 && e.len() > 4 {
            return None; // no leading zero
        }
        c = c * 10 + d;
    }
    Some((a, op, b, c))
}

fn is_true(e: &Eq) -> bool {
    matches!(value(e), Some((a, op, b, c)) if if op == '+' { a + b == c } else { a - b == c })
}

fn text(e: &Eq) -> String {
    let (a, op, b, c) = value(e).expect("valid equation");
    format!("{a} {op} {b} = {c}")
}

fn bits(e: &Eq) -> Vec<(usize, u8)> {
    let mut v = vec![];
    for (s, &m) in e.iter().enumerate() {
        let n = if s == 1 { 2 } else { 7 };
        for k in 0..n {
            v.push((s, k));
            let _ = m;
        }
    }
    v
}

fn has(e: &Eq, p: (usize, u8)) -> bool {
    e[p.0] >> p.1 & 1 == 1
}

fn toggle(e: &mut Eq, p: (usize, u8)) {
    e[p.0] ^= 1 << p.1;
}

/// Every equation reachable by moving exactly `k` matches (k ∈ {1, 2}).
fn moves(e: &Eq, k: usize) -> Vec<Eq> {
    let pos = bits(e);
    let on: Vec<(usize, u8)> = pos.iter().copied().filter(|&p| has(e, p)).collect();
    let off: Vec<(usize, u8)> = pos.iter().copied().filter(|&p| !has(e, p)).collect();
    let mut out = vec![];
    if k == 1 {
        for &p in &on {
            for &q in &off {
                let mut f = e.clone();
                toggle(&mut f, p);
                toggle(&mut f, q);
                out.push(f);
            }
        }
    } else {
        for i in 0..on.len() {
            for j in i + 1..on.len() {
                for a in 0..off.len() {
                    for b in a + 1..off.len() {
                        let mut f = e.clone();
                        toggle(&mut f, on[i]);
                        toggle(&mut f, on[j]);
                        toggle(&mut f, off[a]);
                        toggle(&mut f, off[b]);
                        out.push(f);
                    }
                }
            }
        }
    }
    out
}

fn solutions(e: &Eq, k: usize) -> Vec<Eq> {
    let mut v: Vec<Eq> = moves(e, k).into_iter().filter(is_true).collect();
    v.sort();
    v.dedup();
    v
}

// ---------------------------------------------------------------------------------- drawing

const DW: f64 = 0.5;
const GAP: f64 = 0.3;

fn digit_sticks(m: u8, ox: f64) -> Vec<[f64; 4]> {
    let segs = [
        [ox, 0.0, ox + DW, 0.0],
        [ox + DW, 0.0, ox + DW, 0.5],
        [ox + DW, 0.5, ox + DW, 1.0],
        [ox, 1.0, ox + DW, 1.0],
        [ox, 0.5, ox, 1.0],
        [ox, 0.0, ox, 0.5],
        [ox, 0.5, ox + DW, 0.5],
    ];
    (0..7).filter(|&k| m >> k & 1 == 1).map(|k| segs[k]).collect()
}

fn layout(e: &Eq) -> (Vec<[f64; 4]>, f64) {
    let mut sticks = vec![];
    let mut x = 0.0;
    for (s, &m) in e.iter().enumerate() {
        if s == 1 {
            if m & 1 == 1 {
                sticks.push([x, 0.5, x + DW, 0.5]);
            }
            if m & 2 == 2 {
                sticks.push([x + DW / 2.0, 0.25, x + DW / 2.0, 0.75]);
            }
        } else {
            sticks.extend(digit_sticks(m, x));
        }
        x += DW + GAP;
        if s == 2 {
            // the fixed "=" sign
            sticks.push([x, 0.38, x + DW, 0.38]);
            sticks.push([x, 0.62, x + DW, 0.62]);
            x += DW + GAP;
        }
    }
    (sticks, x - GAP)
}

fn figure(e: &Eq) -> Value {
    let (sticks, w) = layout(e);
    json!({
        "k": "sticks",
        "w": f3(w * 0.9),
        "h": 1,
        "vw": f3(w),
        "vh": 1,
        "slots": e,
        "sticks": sticks.iter().map(|s| json!([f3(s[0]), f3(s[1]), f3(s[2]), f3(s[3])])).collect::<Vec<_>>(),
    })
}

// ------------------------------------------------------------------------------------- oracle

pub fn oracle(item: &IqItem) -> Result<usize, String> {
    let fig = item.figure.as_ref().ok_or("no figure")?;
    let e: Eq = fig["slots"].as_array().ok_or("slots")?.iter().map(|v| v.as_u64().unwrap_or(255) as u8).collect();
    if e.len() < 4 || figure(&e)["sticks"] != fig["sticks"] {
        return Err("drawn sticks do not match the slots".into());
    }
    let k = fig["moves"].as_u64().ok_or("moves")? as usize;
    if is_true(&e) {
        return Err("the puzzle is already true".into());
    }
    for fewer in 1..k {
        if !solutions(&e, fewer).is_empty() {
            return Err("solvable with fewer moves".into());
        }
    }
    let sols = solutions(&e, k);
    if sols.len() != 1 {
        return Err(format!("{} solutions", sols.len()));
    }
    let want = text(&sols[0]);
    let ok: Vec<bool> = item.options.iter().map(|o| opt_text(o) == want).collect();
    if !all_distinct(&item.options) {
        return Err("duplicate options".into());
    }
    unique_index(&ok)
}

// ---------------------------------------------------------------------------------- generator

fn all_true(len: usize) -> Vec<Eq> {
    let mut v = vec![];
    for a in 0..10i64 {
        for b in 0..10i64 {
            for (op, m) in [('+', PLUS), ('−', MINUS)] {
                let c = if op == '+' { a + b } else { a - b };
                if c < 0 {
                    continue;
                }
                let cs: Vec<u8> = if len == 4 {
                    if c > 9 {
                        continue;
                    }
                    vec![DIGITS[c as usize]]
                } else {
                    if c < 10 {
                        continue;
                    }
                    vec![DIGITS[(c / 10) as usize], DIGITS[(c % 10) as usize]]
                };
                let mut e = vec![DIGITS[a as usize], m, DIGITS[b as usize]];
                e.extend(cs);
                v.push(e);
            }
        }
    }
    v
}

fn dist(a: &Eq, b: &Eq) -> u32 {
    a.iter().zip(b).map(|(x, y)| (x ^ y).count_ones()).sum()
}

fn sticks_count(e: &Eq) -> u32 {
    e.iter().map(|m| m.count_ones()).sum()
}

fn describe(from: &Eq, to: &Eq) -> String {
    let names = |e: &Eq| -> Vec<String> {
        let (a, op, b, c) = value(e).unwrap();
        let mut v = vec![a.to_string(), op.to_string(), b.to_string()];
        if e.len() == 5 {
            v.push((c / 10).to_string());
            v.push((c % 10).to_string());
        } else {
            v.push(c.to_string());
        }
        v
    };
    let (f, t) = (names(from), names(to));
    let ch: Vec<String> = f.iter().zip(&t).filter(|(x, y)| x != y).map(|(x, y)| format!("{x} yerine {y}")).collect();
    tr_list(&ch)
}

pub fn generate(rng: &mut Rng, hard: bool) -> IqItem {
    let k = if hard { 2 } else { 1 };
    loop {
        let len = if hard && rng.chance(0.35) { 5 } else { 4 };
        let pool = all_true(len);
        let truth = pool[rng.below(pool.len())].clone();
        let cands = moves(&truth, k);
        if cands.is_empty() {
            continue;
        }
        let puzzle = cands[rng.below(cands.len())].clone();
        if value(&puzzle).is_none() || is_true(&puzzle) {
            continue;
        }
        if (1..k).any(|f| !solutions(&puzzle, f).is_empty()) {
            continue;
        }
        let sols = solutions(&puzzle, k);
        if sols.len() != 1 || sols[0] != truth {
            continue;
        }
        // Distractors: the nearest other true equations (they need adding/removing matches or a
        // different number of moves), sorted by stick distance with random tie-breaks.
        let mut others: Vec<(u32, u64, Eq)> = pool
            .iter()
            .filter(|e| **e != truth && **e != puzzle)
            .map(|e| (dist(e, &puzzle), rng.next_u64(), e.clone()))
            .collect();
        others.sort();
        let ds: Vec<Eq> = others.into_iter().take(4).map(|x| x.2).collect();
        let changed = describe(&puzzle, &truth);
        let prompt = if hard {
            "İki kibrit çöpünün yerini değiştirerek eşitliği doğru yap (= işareti sabit). Hangisi elde edilir?"
        } else {
            "Tek bir kibrit çöpünün yerini değiştirerek eşitliği doğru yap (= işareti sabit). Hangisi elde edilir?"
        };
        let extra: Vec<String> = ds
            .iter()
            .filter(|d| sticks_count(d) != sticks_count(&puzzle))
            .take(1)
            .map(|d| format!("{} eşitliği de doğru ama çöp sayısı farklı: çöp eklemek ya da atmak gerekir.", text(d)))
            .collect();
        let why = format!(
            "{} eşitliği {} olur: {}. {} {}",
            text_any(&puzzle),
            text(&truth),
            changed,
            if hard { "Bunu iki çöple yapmanın tek yolu bu." } else { "Tek çöple doğru olan başka eşitlik yok." },
            extra.join(" ")
        );
        let item = finish(
            rng,
            "matchstick",
            hard,
            prompt.into(),
            Some({
                let mut f = figure(&puzzle);
                f["moves"] = json!(k);
                f
            }),
            IqOption::Text(text(&truth)),
            ds.iter().map(|d| IqOption::Text(text(d))).collect(),
            why.trim().to_string(),
        );
        if oracle(&item) == Ok(item.answer) {
            return item;
        }
    }
}

fn text_any(e: &Eq) -> String {
    value(e).map(|(a, op, b, c)| format!("{a} {op} {b} = {c}")).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn eq(a: usize, op: u8, b: usize, c: &[usize]) -> Eq {
        let mut e = vec![DIGITS[a], op, DIGITS[b]];
        e.extend(c.iter().map(|&d| DIGITS[d]));
        e
    }

    #[test]
    fn research_doc_examples() {
        // 8 − 3 = 6 → 8 − 2 = 6 is the only 1-move solution
        let s = solutions(&eq(8, MINUS, 3, &[6]), 1);
        assert_eq!(s.iter().map(text).collect::<Vec<_>>(), vec!["8 − 2 = 6"]);
        // 6 + 4 = 4 has two (0 + 4 = 4 and 8 − 4 = 4)
        assert_eq!(solutions(&eq(6, PLUS, 4, &[4]), 1).len(), 2);
        // 7 + 1 = 0 → 7 − 7 = 0
        let s = solutions(&eq(7, PLUS, 1, &[0]), 1);
        assert_eq!(s.iter().map(text).collect::<Vec<_>>(), vec!["7 − 7 = 0"]);
    }
}
