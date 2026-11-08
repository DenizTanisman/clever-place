//! Rule-family oracles shared by the matrix, series and analogy categories. They see only the
//! attribute values parsed back from the figure JSON and enumerate a broad grammar of rule
//! families; the union of what every consistent family predicts is the set of acceptable values.
//! `None` means no family explains the attribute (a free / noise attribute).

use std::collections::BTreeSet;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum AKind {
    /// Unordered categories.
    Cat,
    /// Ordered integers in lo..=hi.
    Num(i64, i64),
    /// Integers modulo m (rotation steps, corner positions).
    Cyc(i64),
    /// Bit sets (line overlays).
    Set,
}

fn in_dom(k: AKind, v: i64) -> Option<i64> {
    match k {
        AKind::Num(lo, hi) => (lo..=hi).contains(&v).then_some(v),
        AKind::Cyc(m) => Some(v.rem_euclid(m)),
        _ => Some(v),
    }
}

fn arith_ok(k: AKind, l: &[i64]) -> bool {
    match k {
        AKind::Num(..) => l.windows(3).all(|w| w[1] - w[0] == w[2] - w[1]),
        AKind::Cyc(m) => l.windows(3).all(|w| (w[1] - w[0]).rem_euclid(m) == (w[2] - w[1]).rem_euclid(m)),
        _ => false,
    }
}

/// Predictions for the bottom-right cell of a 3×3 matrix. `g[r][c]` with g[2][2] ignored.
pub fn matrix_predict(g: &[[i64; 3]; 3], k: AKind) -> Option<BTreeSet<i64>> {
    let mut out = BTreeSet::new();
    let mut any = false;
    for dir in 0..2 {
        // lines[l][p]: rows (dir 0) or columns (dir 1); the unknown is lines[2][2] either way.
        let line = |l: usize, p: usize| if dir == 0 { g[l][p] } else { g[p][l] };
        let l0 = [line(0, 0), line(0, 1), line(0, 2)];
        let l1 = [line(1, 0), line(1, 1), line(1, 2)];
        let (a, b) = (line(2, 0), line(2, 1));
        // constant within each line
        if l0.iter().all(|&x| x == l0[0]) && l1.iter().all(|&x| x == l1[0]) && a == b {
            any = true;
            out.insert(a);
        }
        // arithmetic progression along each line (own step per line)
        if arith_ok(k, &l0) && arith_ok(k, &l1) {
            if let Some(v) = in_dom(k, 2 * b - a) {
                any = true;
                out.insert(v);
            }
        }
        // distribution of three: every line is a permutation of the same three values
        {
            let s0: BTreeSet<i64> = l0.iter().copied().collect();
            let s1: BTreeSet<i64> = l1.iter().copied().collect();
            if s0.len() == 3 && s0 == s1 && a != b && s0.contains(&a) && s0.contains(&b) {
                let rest: Vec<i64> = s0.iter().copied().filter(|&x| x != a && x != b).collect();
                any = true;
                out.insert(rest[0]);
            }
        }
        match k {
            AKind::Num(..) => {
                let fams: [fn(i64, i64) -> i64; 3] = [|x, y| x + y, |x, y| x - y, |x, y| y - x];
                for f in fams {
                    if f(l0[0], l0[1]) == l0[2] && f(l1[0], l1[1]) == l1[2] {
                        if let Some(v) = in_dom(k, f(a, b)) {
                            any = true;
                            out.insert(v);
                        }
                    }
                }
            }
            AKind::Set => {
                let fams: [fn(i64, i64) -> i64; 5] =
                    [|x, y| x ^ y, |x, y| x | y, |x, y| x & y, |x, y| x & !y, |x, y| y & !x];
                for f in fams {
                    if f(l0[0], l0[1]) == l0[2] && f(l1[0], l1[1]) == l1[2] {
                        any = true;
                        out.insert(f(a, b));
                    }
                }
            }
            _ => {}
        }
    }
    // constant along wrapped diagonals
    for sgn in [1i64, -1] {
        let cls = |r: usize, c: usize| (r as i64 + sgn * c as i64).rem_euclid(3);
        let mut vals: [Option<i64>; 3] = [None; 3];
        let mut ok = true;
        for r in 0..3 {
            for c in 0..3 {
                if r == 2 && c == 2 {
                    continue;
                }
                let k2 = cls(r, c) as usize;
                match vals[k2] {
                    None => vals[k2] = Some(g[r][c]),
                    Some(v) if v == g[r][c] => {}
                    _ => ok = false,
                }
            }
        }
        if ok {
            if let Some(v) = vals[cls(2, 2) as usize] {
                any = true;
                out.insert(v);
            }
        }
    }
    any.then_some(out)
}

/// Predictions for the next term of a sequence.
pub fn series_predict(v: &[i64], k: AKind) -> Option<BTreeSet<i64>> {
    let n = v.len();
    let mut out = BTreeSet::new();
    let mut any = false;
    let mut add = |x: Option<i64>, out: &mut BTreeSet<i64>| {
        if let Some(x) = x {
            any = true;
            out.insert(x);
        }
    };
    if v.iter().all(|&x| x == v[0]) {
        add(Some(v[0]), &mut out);
    }
    // periodic with period p (at least two confirmations)
    for p in 2..n.saturating_sub(1) {
        if (p..n).all(|i| v[i] == v[i - p]) {
            add(Some(v[n - p]), &mut out);
        }
    }
    match k {
        AKind::Num(..) | AKind::Cyc(_) => {
            if arith_ok(k, v) {
                add(in_dom(k, 2 * v[n - 1] - v[n - 2]), &mut out);
            }
        }
        _ => {}
    }
    if let AKind::Num(..) = k {
        // second-order differences constant
        if n >= 4 {
            let d: Vec<i64> = v.windows(2).map(|w| w[1] - w[0]).collect();
            if d.windows(3).all(|w| w[1] - w[0] == w[2] - w[1]) && d.windows(2).all(|w| w[1] - w[0] == d[1] - d[0]) {
                let dd = d[1] - d[0];
                add(in_dom(k, v[n - 1] + d[d.len() - 1] + dd), &mut out);
            }
            // geometric ×q
            if v.iter().all(|&x| x != 0) {
                let q = v[1] / v[0];
                if q > 1 && v.windows(2).all(|w| w[1] == w[0] * q) {
                    add(in_dom(k, v[n - 1] * q), &mut out);
                }
            }
        }
        // two interleaved progressions with a common step
        if n >= 5 {
            let d = v[2] - v[0];
            if (2..n).all(|i| v[i] - v[i - 2] == d) {
                add(in_dom(k, v[n - 2] + d), &mut out);
            }
        }
    }
    any.then_some(out)
}

/// Does value `x` satisfy a prediction (`None` = free)?
pub fn fits(p: &Option<BTreeSet<i64>>, x: i64) -> bool {
    match p {
        None => true,
        Some(s) => s.contains(&x),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matrix_families() {
        // latin
        let g = [[1, 2, 3], [2, 3, 1], [3, 1, 0]];
        assert_eq!(matrix_predict(&g, AKind::Cat), Some([2].into()));
        // count progression per row
        let g = [[1, 2, 3], [2, 3, 4], [3, 4, 0]];
        let p = matrix_predict(&g, AKind::Num(1, 6)).unwrap();
        assert!(p.contains(&5));
        // xor
        let g = [[0b011, 0b110, 0b101], [0b1000, 0b1001, 0b0001], [0b1100, 0b0110, 0]];
        assert_eq!(matrix_predict(&g, AKind::Set), Some([0b1010].into()));
    }

    #[test]
    fn series_families() {
        assert_eq!(series_predict(&[0, 1, 2, 3], AKind::Cyc(8)), Some([4].into()));
        assert_eq!(series_predict(&[1, 2, 1, 2, 1], AKind::Cat), Some([2].into()));
        assert!(series_predict(&[1, 3, 2, 4], AKind::Cat).is_none());
    }
}
