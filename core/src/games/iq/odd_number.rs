//! Farklı olanı bul (sayılar) — five numbers (or number pairs); four share a property, one
//! does not.
//!
//! Medium: primes with one odd composite, multiples of k with a near miss, squares, three-digit
//! palindromes. Hard: strictly decreasing or increasing digits, a shared digit sum, n(n+1)
//! numbers, triangular numbers, powers of two, primes whose reversal is prime, and number pairs
//! where four follow one relation (b = a², b = 2a + 1, b = a(a+1), b = a³ …).
//!
//! Sets are found by local search: start from a random set and, while a feature singles out a
//! member, replace that member.
//!
//! Oracle (`splits`): a library of salient features — parity, prime, square, cube, triangular,
//! Fibonacci, power of two, n(n+1), palindrome, increasing / decreasing digits, repeated digit,
//! all-even / all-odd digits, digit 0, divisibility by 3..12, and categorical values (digit
//! count, first and last digit, digit sum, digital root, remainders mod 3/4/5/7/9). For pairs
//! also b − a, b + a, b ÷ a, b mod a, b − a², b − a³, b − 2a, b − 3a, b − a(a+1), b − 2^a and the
//! salient single-number features of a and of b (parity, prime, square, cube, digit count, last
//! digit). Every feature that splits the five 4 : 1 must single out
//! the intended answer (the research doc's caveat: 25 was the only odd number, 64 the only cube).

use super::common::*;
use super::item::IqItem;
use crate::rng::Rng;

pub const ID: &str = "odd_number";

pub struct Spec {
    /// Single numbers, or pairs (b = Some).
    vals: Vec<(i64, Option<i64>)>,
    odd: usize,
}

fn is_square(n: i64) -> bool {
    exact_root(n, 2).is_some()
}
fn is_cube(n: i64) -> bool {
    exact_root(n, 3).is_some()
}
fn is_tri(n: i64) -> bool {
    n >= 0 && is_square(8 * n + 1)
}
fn is_fib(n: i64) -> bool {
    n >= 0 && (is_square(5 * n * n + 4) || is_square(5 * n * n - 4))
}
fn is_pronic(n: i64) -> bool {
    (0..=1000).take_while(|i| i * (i + 1) <= n).any(|i| i * (i + 1) == n)
}
fn is_pow2(n: i64) -> bool {
    n > 0 && n & (n - 1) == 0
}
fn palindrome(n: i64) -> bool {
    let d = digits(n);
    d.len() > 1 && d.iter().eq(d.iter().rev())
}
fn increasing(n: i64) -> bool {
    let d = digits(n);
    d.len() > 1 && d.windows(2).all(|w| w[0] < w[1])
}
fn decreasing(n: i64) -> bool {
    let d = digits(n);
    d.len() > 1 && d.windows(2).all(|w| w[0] > w[1])
}

const SINGLE: [&str; 36] = [
    "even", "prime", "square", "cube", "tri", "fib", "pow2", "pronic", "palindrome", "increasing", "decreasing", "repeat", "alleven",
    "allodd", "zero", "len", "first", "last", "dsum", "droot", "dsum_even", "mod3", "mod4", "mod5", "mod7", "mod9", "div3", "div4",
    "div5", "div6", "div7", "div8", "div9", "div10", "div11", "div12",
];
const PAIR: [&str; 10] = ["b-a", "b+a", "b/a", "bmoda", "b-a2", "b-a3", "b-2a", "b-3a", "b-a(a+1)", "b-2^a"];

/// Every feature of one number (order of `SINGLE`); booleans are 0/1.
fn features(n: i64) -> Vec<i64> {
    let d = digits(n);
    let mut s = d.clone();
    s.sort();
    s.dedup();
    let mut f: Vec<i64> = vec![
        (n % 2 == 0) as i64,
        is_prime(n) as i64,
        is_square(n) as i64,
        is_cube(n) as i64,
        is_tri(n) as i64,
        is_fib(n) as i64,
        is_pow2(n) as i64,
        is_pronic(n) as i64,
        palindrome(n) as i64,
        increasing(n) as i64,
        decreasing(n) as i64,
        (s.len() < d.len()) as i64,
        d.iter().all(|x| x % 2 == 0) as i64,
        d.iter().all(|x| x % 2 == 1) as i64,
        d.contains(&0) as i64,
        d.len() as i64,
        d[0],
        *d.last().unwrap(),
        digit_sum(n),
        if n == 0 { 0 } else { 1 + (n - 1) % 9 },
        digit_sum(n) % 2,
    ];
    for m in [3, 4, 5, 7, 9] {
        f.push(n.rem_euclid(m));
    }
    for m in 3..=12 {
        f.push((n % m == 0) as i64);
    }
    f
}

/// Relation features of a pair (order of `PAIR`), then every feature of a and of b.
fn pair_features(a: i64, b: i64) -> Vec<i64> {
    const NONE: i64 = i64::MIN;
    let mut f: Vec<i64> = vec![
        b - a,
        b + a,
        if a != 0 && b % a == 0 { b / a } else { NONE },
        if a != 0 { b.rem_euclid(a) } else { NONE },
        b - a * a,
        b - a * a * a,
        b - 2 * a,
        b - 3 * a,
        b - a * (a + 1),
        if (0..30).contains(&a) { b - (1 << a) } else { NONE },
    ];
    // In a pair item the relation is the question; of the single-number features only the
    // salient ones could compete with it (a solver would not weigh "a is a multiple of 7").
    let fa = features(a);
    let fb = features(b);
    f.extend(PAIR_SINGLE.iter().map(|&i| fa[i]));
    f.extend(PAIR_SINGLE.iter().map(|&i| fb[i]));
    f
}

/// Indices into `SINGLE` kept for each number of a pair: even, prime, square, cube, len, last.
const PAIR_SINGLE: [usize; 6] = [0, 1, 2, 3, 15, 17];

fn feature_name(i: usize, len: usize) -> String {
    if len == SINGLE.len() {
        return SINGLE[i].to_string();
    }
    if i < PAIR.len() {
        PAIR[i].to_string()
    } else if i < PAIR.len() + PAIR_SINGLE.len() {
        format!("a.{}", SINGLE[PAIR_SINGLE[i - PAIR.len()]])
    } else {
        format!("b.{}", SINGLE[PAIR_SINGLE[i - PAIR.len() - PAIR_SINGLE.len()]])
    }
}

/// Indices singled out by some feature that splits the set 4 : 1 (or n−1 : 1), with the feature.
pub fn splits(feats: &[Vec<i64>]) -> Vec<(usize, String)> {
    let n = feats.len();
    let len = feats[0].len();
    let mut out = vec![];
    for fi in 0..len {
        for i in 0..n {
            let mut others = (0..n).filter(|&j| j != i).map(|j| feats[j][fi]);
            let first = others.next().unwrap();
            if first != feats[i][fi] && others.all(|x| x == first) {
                out.push((i, feature_name(fi, len)));
            }
        }
    }
    out
}

fn spec_feats(s: &Spec) -> Vec<Vec<i64>> {
    s.vals.iter().map(|&(a, b)| b.map_or_else(|| features(a), |b| pair_features(a, b))).collect()
}

type Val = (i64, Option<i64>);

/// One kind of odd-one-out: how to draw a member, how to draw the odd one, and the explanation.
struct KindGen {
    member: Box<dyn Fn(&mut Rng) -> Option<Val>>,
    odd: Box<dyn Fn(&mut Rng) -> Option<Val>>,
    why: Box<dyn Fn(Val) -> String>,
}

fn single(member: impl Fn(&mut Rng) -> Option<i64> + 'static, odd: impl Fn(&mut Rng) -> Option<i64> + 'static, why: impl Fn(i64) -> String + 'static) -> KindGen {
    KindGen {
        member: Box::new(move |r| member(r).map(|x| (x, None))),
        odd: Box::new(move |r| odd(r).map(|x| (x, None))),
        why: Box::new(move |v| why(v.0)),
    }
}

fn reverse_num(x: i64) -> i64 {
    digits(x).iter().rev().fold(0, |a, d| a * 10 + d)
}

fn kind_gen(r: &mut Rng, hard: bool, kind: usize) -> KindGen {
    match (hard, kind) {
        (false, 0) => single(
            |r| Some(r.range(11, 97)).filter(|&x| is_prime(x)),
            |r| Some(r.range(21, 99)).filter(|&x| x % 2 == 1 && !is_prime(x) && x % 5 != 0),
            |o| {
                let f = (3..o).find(|d| o % d == 0).unwrap_or(1);
                format!("{} = {} × {}, asal değil; diğerleri asal sayı.", num(o), f, o / f)
            },
        ),
        (false, 1) => {
            let k = *r.pick(&[3i64, 4, 6, 7, 8, 9, 11, 12, 13]);
            single(
                move |r| Some(k * r.range(3, 12)),
                move |r| Some(k * r.range(3, 12) + *r.pick(&[-2i64, -1, 1, 2])),
                move |o| format!("Diğerlerinin hepsi {k}'in katı; {} değil.", num(o)),
            )
        }
        (false, 2) => single(
            |r| Some(r.range(4, 20)).map(|x| x * x),
            |r| {
                let b = r.range(5, 19);
                Some(b * b + *r.pick(&[-2i64, -1, 1, 2, 3]))
            },
            |o| format!("Diğerleri tam kare; {} değil.", num(o)),
        ),
        (false, _) => single(
            |r| {
                let (a, b) = (r.range(1, 9), r.range(0, 9));
                Some(a * 101 + b * 10)
            },
            |r| Some(r.range(1, 9) * 100 + r.range(0, 9) * 10 + r.range(1, 9)).filter(|&x| !palindrome(x)),
            |o| format!("Diğerleri tersten de aynı okunuyor (palindrom); {} öyle değil.", num(o)),
        ),
        // (Cubes do not work as a single kind: every 3-digit cube set holds 512 = 2⁹ or 729 = 27²;
        // cubes appear in the pair rules instead.)
        (true, 0) => single(
            |r| {
                let mut d: Vec<i64> = (0..=9).collect();
                r.shuffle(&mut d);
                let mut ds: Vec<i64> = d[..4].to_vec();
                ds.sort_by(|a, b| b.cmp(a));
                Some(ds.iter().fold(0, |acc, x| acc * 10 + x))
            },
            |r| Some(r.range(1023, 9876)).filter(|&x| !increasing(x) && !decreasing(x)),
            |o| format!("Diğerlerinin rakamları soldan sağa azalıyor; {} sayısınınki azalmıyor.", num(o)),
        ),
        (true, 1) => {
            let s = r.range(10, 20);
            single(
                move |r| Some(r.range(100, 999)).filter(|&x| digit_sum(x) == s),
                move |r| Some(r.range(100, 999)).filter(|&x| (digit_sum(x) - s).abs() == 1),
                move |o| format!("Diğerlerinin rakamları toplamı {s}; {} sayısınınki {}.", num(o), digit_sum(o)),
            )
        }
        (true, 2) => single(
            |r| Some(r.range(3, 15)).map(|x| x * (x + 1)),
            |r| {
                let b = r.range(4, 14);
                Some(b * (b + 1) + *r.pick(&[-2i64, 2, 4, -4]))
            },
            |o| format!("Diğerleri ardışık iki sayının çarpımı (12 = 3 × 4, 20 = 4 × 5 gibi); {} değil.", num(o)),
        ),
        (true, 3) => single(
            |r| Some(r.range(4, 20)).map(|x| x * (x + 1) / 2),
            |r| {
                let b = r.range(5, 19);
                Some(b * (b + 1) / 2 + *r.pick(&[-1i64, 1, 2]))
            },
            |o| format!("Diğerleri üçgensel sayı (1, 3, 6, 10, 15 …); {} değil.", num(o)),
        ),
        (true, 4) => single(
            |r| Some(1i64 << r.range(4, 11)),
            |r| Some((1i64 << r.range(4, 11)) + *r.pick(&[-2i64, 2, 4, -4, 6])),
            |o| format!("Diğerleri 2'nin kuvveti; {} değil.", num(o)),
        ),
        (true, 5) => single(
            |r| {
                let mut d: Vec<i64> = (1..=9).collect();
                r.shuffle(&mut d);
                let mut ds: Vec<i64> = d[..4].to_vec();
                ds.sort();
                Some(ds.iter().fold(0, |acc, x| acc * 10 + x))
            },
            |r| Some(r.range(1234, 9876)).filter(|&x| !increasing(x) && !decreasing(x) && !digits(x).contains(&0)),
            |o| format!("Diğerlerinin rakamları soldan sağa artıyor; {} sayısınınki artmıyor.", num(o)),
        ),
        (true, 6) => single(
            |r| Some(r.range(12, 99)).filter(|&x| is_prime(x) && is_prime(reverse_num(x))),
            |r| Some(r.range(12, 99)).filter(|&x| is_prime(x) && !is_prime(reverse_num(x))),
            |o| format!("Hepsi asal, ama yalnızca {} ters çevrilince asal kalmıyor ({} asal değil).", num(o), num(reverse_num(o))),
        ),
        (true, _) => {
            let rules: [(&str, fn(i64) -> i64, (i64, i64)); 6] = [
                ("ikinci sayı birincinin karesi", |a| a * a, (11, 30)),
                ("ikinci sayı birincinin 2 katının 1 fazlası", |a| 2 * a + 1, (10, 40)),
                ("ikinci sayı birinci ile bir fazlasının çarpımı", |a| a * (a + 1), (10, 30)),
                ("ikinci sayı birincinin küpü", |a| a * a * a, (10, 21)),
                ("ikinci sayı birincinin 3 katının 2 eksiği", |a| 3 * a - 2, (10, 30)),
                ("ikinci sayı birincinin karesinin 1 eksiği", |a| a * a - 1, (11, 30)),
            ];
            let (desc, f, (lo, hi)) = rules[r.below(rules.len())];
            KindGen {
                member: Box::new(move |r| {
                    let a = r.range(lo, hi);
                    Some((a, Some(f(a))))
                }),
                odd: Box::new(move |r| {
                    let a = r.range(lo, hi);
                    Some((a, Some(f(a) + *r.pick(&[-2i64, -1, 1, 2]))))
                }),
                why: Box::new(move |(a, b)| {
                    let b = b.unwrap_or(0);
                    format!("Diğer çiftlerde {desc}; {} : {} çiftinde değil ({} olmalıydı).", num(a), num(b), num(f(a)))
                }),
            }
        }
    }
}

fn feats_of(v: &[Val]) -> Vec<Vec<i64>> {
    v.iter().map(|&(a, b)| b.map_or_else(|| features(a), |b| pair_features(a, b))).collect()
}

fn draw(r: &mut Rng, f: &dyn Fn(&mut Rng) -> Option<Val>, avoid: &[Val]) -> Option<Val> {
    for _ in 0..200 {
        if let Some(v) = f(r) {
            if v.0 > 0 && !avoid.iter().any(|w| w.0 == v.0 || (v.1.is_none() && w.0 == v.0)) {
                return Some(v);
            }
        }
    }
    None
}

/// Local search: start from a random set and, while some feature singles out a member instead
/// of the odd one, replace that member. Index 0 of the result is the odd one.
fn search(r: &mut Rng, g: &KindGen) -> Option<(Vec<Val>, String)> {
    let odd = draw(r, &*g.odd, &[])?;
    let mut v = vec![odd];
    for _ in 0..4 {
        let m = draw(r, &*g.member, &v)?;
        v.push(m);
    }
    for _ in 0..400 {
        let sp = splits(&feats_of(&v));
        let bad: Vec<usize> = sp.iter().map(|x| x.0).filter(|&i| i != 0).collect();
        if !sp.is_empty() && bad.is_empty() {
            return Some((v.clone(), (g.why)(v[0])));
        }
        let i = if bad.is_empty() { 1 + r.below(4) } else { *r.pick(&bad) };
        let rest: Vec<Val> = v.iter().enumerate().filter(|&(j, _)| j != i).map(|(_, &x)| x).collect();
        v[i] = draw(r, &*g.member, &rest)?;
    }
    None
}

fn pick_kind(r: &mut Rng, hard: bool) -> usize {
    if hard {
        r.below(10)
    } else {
        r.below(4)
    }
}

fn build(r: &mut Rng, hard: bool, kind: usize) -> Option<(IqItem, Spec)> {
    let g = kind_gen(r, hard, kind);
    let (found, why) = search(r, &g)?;
    let (vals, odd) = place(r, found[0], &found[1..]);
    let texts: Vec<String> = vals.iter().map(|&(a, b)| b.map_or_else(|| num(a), |b| format!("{} : {}", num(a), num(b)))).collect();
    let prompt = if vals[0].1.is_some() { "Hangi çift diğerlerinden farklı bir kurala uyuyor?" } else { "Hangi sayı diğerlerinden farklı?" };
    let item = text_item(ID, hard, prompt, None, texts, odd, why);
    Some((item, Spec { vals, odd }))
}

fn verify(item: &IqItem, s: &Spec) -> Result<(), String> {
    basic_checks(item)?;
    if item.answer != s.odd {
        return Err("answer index".into());
    }
    let sp = splits(&spec_feats(s));
    if sp.is_empty() {
        return Err("no feature singles out the answer".into());
    }
    if let Some((i, f)) = sp.iter().find(|(i, _)| *i != s.odd) {
        return Err(format!("feature '{f}' singles out option {i} instead of {}: {:?}", s.odd, s.vals));
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

    fn scan(v: &[i64]) -> Vec<(usize, String)> {
        splits(&v.iter().map(|&x| features(x)).collect::<Vec<_>>())
    }

    #[test]
    fn iq_odd_number_doc_caveats() {
        // {16, 25, 36, 48, 64}: 25 is the only odd number, so "48 is not a square" is ambiguous.
        let s = scan(&[16, 25, 36, 48, 64]);
        assert!(s.iter().any(|(i, _)| *i == 1) && s.iter().any(|(i, _)| *i == 3));
        // {16, 36, 45, 64, 81}: 64 is the only cube.
        assert!(scan(&[16, 36, 45, 64, 81]).iter().any(|(i, f)| *i == 3 && f == "cube"));
        // The doc's own "passed" example 13, 23, 41, 51, 67 is ambiguous for this broader scan:
        // 51 is the only non-prime, but 13 is the only Fibonacci number.
        let s = scan(&[13, 23, 41, 51, 67]);
        assert!(s.contains(&(3, "prime".to_string())) && s.contains(&(0, "fib".to_string())), "{s:?}");
        // 169, 289, 343, 841, 961: every singling-out feature points at 343.
        assert!(scan(&[169, 289, 343, 841, 961]).iter().all(|(i, _)| *i == 2));
    }

    /// How often the local search finds a set for each kind, and how fast:
    /// `cargo test --release iq_odd_number_kind_rates -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn iq_odd_number_kind_rates() {
        let mut r = Rng::new(5);
        for (hard, kinds) in [(false, 4usize), (true, 10)] {
            for k in 0..kinds {
                let t = std::time::Instant::now();
                let ok = (0..200).filter(|_| build(&mut r, hard, k).is_some()).count();
                println!("hard {hard} kind {k}: {ok}/200 in {:?}", t.elapsed());
            }
        }
    }
}
