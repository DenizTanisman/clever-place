//! Independent rule grammar for integer sequences — the oracle behind `number_series` and
//! `letter_series`. It knows nothing about how the generators pick rules; it only answers
//! "which rule families explain this whole sequence?".
//!
//! A family must be *confirmed*: its free parameters are fitted from the first terms and at
//! least two more terms must agree. Families:
//! - `poly`: k-th differences constant (k = 1..3) with ≥ 3 entries at that level.
//! - `affine`: a(i+1) = p·a(i) + q (also read backwards, so halving is covered).
//! - `affine_i`: a(i+1) = p·a(i) + q + t·i.
//! - `linrec2`: a(i+1) = p·a(i) + q·a(i−1) + c (|p|, |q| ≤ 3) — Fibonacci-like.
//! - `diffs:*`: the differences follow `affine`, `known`, `poly` or a period-2/3 cycle.
//! - `ratios`: every term divides the next and the ratios are arithmetic (×2, ×3, ×4 …).
//! - `interleave`: odd and even positions each form an arithmetic or geometric series.
//! - `alt_ops`: two operations (+k / ×m / ÷m) alternate.
//! - `known`: m·K(j+i) + c for K in squares, cubes, primes, Fibonacci, triangular, 2^n, n!.
//! - `prod_rec`: a(i+1) = a(i)·a(i−1) + c · `square_rec`: a(i+1) = a(i)² + c ·
//!   `digit_rec`: a(i+1) = a(i) ± digit sum of a(i).

fn diffs(s: &[i64]) -> Vec<i64> {
    s.windows(2).map(|w| w[1] - w[0]).collect()
}

fn all_eq(s: &[i64]) -> bool {
    s.windows(2).all(|w| w[0] == w[1])
}

fn poly(s: &[i64]) -> bool {
    let mut d = s.to_vec();
    for _k in 1..=3 {
        d = diffs(&d);
        if d.len() >= 3 && all_eq(&d) {
            return true;
        }
        if d.len() < 3 {
            break;
        }
    }
    false
}

fn arithmetic(s: &[i64]) -> bool {
    s.len() >= 3 && all_eq(&diffs(s))
}

fn affine_fwd(s: &[i64]) -> bool {
    if s.len() < 4 {
        return false;
    }
    let (d0, d1) = (s[1] - s[0], s[2] - s[1]);
    if d0 == 0 || d1 % d0 != 0 {
        return false;
    }
    let p = d1 / d0;
    if p == 0 || p == 1 {
        return false;
    }
    let q = s[1] - p * s[0];
    s.windows(2).all(|w| w[0].checked_mul(p).and_then(|x| x.checked_add(q)) == Some(w[1]))
}

fn affine(s: &[i64]) -> bool {
    let mut r = s.to_vec();
    r.reverse();
    affine_fwd(s) || affine_fwd(&r)
}

fn geometric(s: &[i64]) -> bool {
    if s.len() < 3 || s.iter().any(|&x| x == 0) {
        return false;
    }
    let up = s[1] % s[0] == 0 && {
        let m = s[1] / s[0];
        m != 1 && s.windows(2).all(|w| w[0] * m == w[1])
    };
    let down = s[0] % s[1] == 0 && {
        let m = s[0] / s[1];
        m != 1 && s.windows(2).all(|w| w[1] * m == w[0])
    };
    up || down
}

fn affine_i(s: &[i64]) -> bool {
    if s.len() < 5 {
        return false;
    }
    for p in [-2i64, -1, 2, 3] {
        for t in -6i64..=6 {
            if t == 0 {
                continue;
            }
            let q = s[1] - p * s[0];
            if s.windows(2).enumerate().all(|(i, w)| p * w[0] + q + t * i as i64 == w[1]) {
                return true;
            }
        }
    }
    false
}

fn linrec2(s: &[i64]) -> bool {
    if s.len() < 6 {
        return false;
    }
    for p in -3i64..=3 {
        for q in -3i64..=3 {
            if q == 0 {
                continue;
            }
            let c = s[2] - p * s[1] - q * s[0];
            if c.abs() > 30 {
                continue;
            }
            if (2..s.len()).all(|i| p * s[i - 1] + q * s[i - 2] + c == s[i]) {
                return true;
            }
        }
    }
    false
}

fn periodic(d: &[i64], p: usize) -> bool {
    d.len() >= p + 2 && (p..d.len()).all(|i| d[i] == d[i - p]) && !all_eq(d)
}

fn ratios(s: &[i64]) -> bool {
    if s.len() < 4 || s.iter().any(|&x| x == 0) {
        return false;
    }
    let mut r = vec![];
    for w in s.windows(2) {
        if w[1] % w[0] != 0 {
            return false;
        }
        r.push(w[1] / w[0]);
    }
    arithmetic(&r) && !all_eq(&r)
}

fn interleave(s: &[i64]) -> bool {
    if s.len() < 6 {
        return false;
    }
    let ev: Vec<i64> = s.iter().step_by(2).copied().collect();
    let od: Vec<i64> = s.iter().skip(1).step_by(2).copied().collect();
    let simple = |x: &[i64]| x.len() >= 3 && (arithmetic(x) || geometric(x));
    simple(&ev) && simple(&od)
}

#[derive(Clone, Copy, PartialEq)]
enum Op {
    Add(i64),
    Mul(i64),
    Div(i64),
}

fn op_of(a: i64, b: i64) -> Vec<Op> {
    let mut v = vec![Op::Add(b - a)];
    if a != 0 && b % a == 0 {
        let m = b / a;
        if m.abs() >= 2 && m.abs() <= 9 {
            v.push(Op::Mul(m));
        }
    }
    if b != 0 && a % b == 0 {
        let m = a / b;
        if m.abs() >= 2 && m.abs() <= 9 {
            v.push(Op::Div(m));
        }
    }
    v
}

fn alt_ops(s: &[i64]) -> bool {
    if s.len() < 5 {
        return false;
    }
    let mut classes: [Vec<(i64, i64)>; 2] = [vec![], vec![]];
    for (i, w) in s.windows(2).enumerate() {
        classes[i % 2].push((w[0], w[1]));
    }
    let consistent = |c: &Vec<(i64, i64)>| -> Vec<Op> {
        let mut ops = op_of(c[0].0, c[0].1);
        for &(a, b) in &c[1..] {
            let o = op_of(a, b);
            ops.retain(|x| o.contains(x));
        }
        ops
    };
    let a = consistent(&classes[0]);
    let b = consistent(&classes[1]);
    !a.is_empty() && !b.is_empty()
}

fn known_seqs() -> Vec<Vec<i64>> {
    let n = 40;
    let squares: Vec<i64> = (0..n).map(|i| i * i).collect();
    let cubes: Vec<i64> = (0..20).map(|i| i * i * i).collect();
    let mut primes = vec![];
    let mut x = 2;
    while primes.len() < 40 {
        if super::common::is_prime(x) {
            primes.push(x);
        }
        x += 1;
    }
    let mut fib = vec![1i64, 2];
    while fib.len() < 30 {
        let l = fib.len();
        fib.push(fib[l - 1] + fib[l - 2]);
    }
    let tri: Vec<i64> = (0..n).map(|i| i * (i + 1) / 2).collect();
    let pow2: Vec<i64> = (0..30).map(|i| 1i64 << i).collect();
    let mut fact = vec![1i64];
    for i in 1..13 {
        let l = *fact.last().unwrap();
        fact.push(l * i);
    }
    vec![squares, cubes, primes, fib, tri, pow2, fact]
}

fn known(s: &[i64]) -> bool {
    if s.len() < 4 {
        return false;
    }
    for k in known_seqs() {
        for m in [1i64, 2, 3, -1, -2] {
            for j in 0..k.len() {
                if j + s.len() > k.len() {
                    break;
                }
                let c = s[0] - m * k[j];
                // A plain run needs 4 terms; a scaled or shifted one fits two more parameters.
                if (m != 1 || c != 0) && s.len() < 5 {
                    continue;
                }
                if (0..s.len()).all(|i| m * k[j + i] + c == s[i]) {
                    return true;
                }
            }
        }
    }
    false
}

fn prod_rec(s: &[i64]) -> bool {
    if s.len() < 5 {
        return false;
    }
    let c = s[2] - s[1] * s[0];
    c.abs() <= 10 && (2..s.len()).all(|i| s[i - 1].checked_mul(s[i - 2]).map(|x| x + c) == Some(s[i]))
}

fn square_rec(s: &[i64]) -> bool {
    if s.len() < 4 {
        return false;
    }
    let c = s[1] - s[0] * s[0];
    s.windows(2).all(|w| w[0].checked_mul(w[0]).map(|x| x + c) == Some(w[1]))
}

fn digit_rec(s: &[i64]) -> bool {
    if s.len() < 4 {
        return false;
    }
    let ds = super::common::digit_sum;
    s.windows(2).all(|w| w[0] + ds(w[0]) == w[1]) || s.windows(2).all(|w| w[0] - ds(w[0]) == w[1])
}

/// Every rule family that explains the whole sequence (empty = unexplainable).
pub fn explain(s: &[i64]) -> Vec<&'static str> {
    let mut out = vec![];
    if s.len() < 4 {
        return out;
    }
    if poly(s) {
        out.push("poly");
    }
    if affine(s) {
        out.push("affine");
    }
    if affine_i(s) {
        out.push("affine_i");
    }
    if linrec2(s) {
        out.push("linrec2");
    }
    if ratios(s) {
        out.push("ratios");
    }
    if interleave(s) {
        out.push("interleave");
    }
    if alt_ops(s) {
        out.push("alt_ops");
    }
    if known(s) {
        out.push("known");
    }
    if prod_rec(s) {
        out.push("prod_rec");
    }
    if square_rec(s) {
        out.push("square_rec");
    }
    if digit_rec(s) {
        out.push("digit_rec");
    }
    let d = diffs(s);
    if d.len() >= 4 {
        if affine(&d) {
            out.push("diffs:affine");
        }
        if known(&d) {
            out.push("diffs:known");
        }
        if poly(&d) {
            out.push("diffs:poly");
        }
        if periodic(&d, 2) {
            out.push("diffs:period2");
        }
        if periodic(&d, 3) {
            out.push("diffs:period3");
        }
        if alt_ops(&d) {
            out.push("diffs:alt_ops");
        }
    }
    out
}

pub fn explainable(s: &[i64]) -> bool {
    !explain(s).is_empty()
}

/// Which of `options` completes `shown` (with `None` = the gap) into an explainable sequence.
pub fn fitting_options(shown: &[Option<i64>], options: &[i64]) -> Vec<usize> {
    let mut out = vec![];
    for (i, &o) in options.iter().enumerate() {
        let full: Vec<i64> = shown.iter().map(|x| x.unwrap_or(o)).collect();
        if explainable(&full) {
            out.push(i);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iq_series_grammar_examples() {
        // Research doc examples.
        assert!(explain(&[3, 5, 9, 17, 33, 65]).contains(&"affine"));
        assert!(explainable(&[1, 2, 6, 15, 31, 56]));
        assert!(!explainable(&[1, 2, 6, 15, 31, 57]));
        assert!(explain(&[2, 5, 10, 17, 26]).contains(&"poly"));
        assert!(explain(&[1, 1, 2, 3, 5, 8]).contains(&"linrec2"));
        assert!(explain(&[2, 2, 4, 12, 48]).contains(&"ratios"));
        assert!(explain(&[1, 10, 3, 20, 5, 40]).contains(&"interleave"));
        assert!(explain(&[3, 6, 9, 18, 21, 42]).contains(&"alt_ops"));
        assert!(explain(&[64, 32, 16, 8]).contains(&"affine"));
        assert!(explain(&[3, 5, 8, 13, 20, 31]).contains(&"diffs:known"));
        assert!(!explainable(&[3, 5, 9, 17, 33, 64]));
    }
}
