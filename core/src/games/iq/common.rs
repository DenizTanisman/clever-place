//! Shared helpers for the text/number IQ generators: the Turkish alphabet, number formatting,
//! option placement (uniform answer positions, rank-balanced numeric options) and the
//! build → verify retry loop every category uses.
//!
//! Layout figures. Text categories that need a 2-D arrangement (a number grid, triangles, a wheel,
//! balance scales, symbol equations, code examples, a clock face) put a figure whose JSON has a
//! `"layout"` key. Those are drawn by `app/lib/clever/games/iq_layout.dart`, not by the figural
//! painter; figures without `"layout"` belong to `figural.rs` / `IqFigure`. Schemas:
//! - `{"layout":"series","terms":["3","5","?"]}` — a row of chips.
//! - `{"layout":"grid","rows":[["4","7","9"],["6","11","?"]]}`.
//! - `{"layout":"triangles","items":[{"top","left","right","mid"}]}` (strings).
//! - `{"layout":"wheel","center":"36","ring":["4",…]}` — ring[i] and ring[i + n/2] are opposite.
//! - `{"layout":"pairs","items":[["3","10"],["7","?"]]}` — "a, then b" arrows.
//! - `{"layout":"pyramid","rows":[["?"],["12","15"],["5","7","8"]]}` — top row first.
//! - `{"layout":"equations","rows":[["#t","+","#t","=","10"]]}` — tokens; `#x` = shape x
//!   (t triangle, s square, c circle, d diamond, h hexagon), `(+)` = the puzzle's own operator.
//! - `{"layout":"scales","scales":[{"left":["t","t"],"right":["s"]}],"ask":{"left":[…],"right":["?"]}}`.
//! - `{"layout":"symbols","items":["s","c"]}` — a group of shapes (used as an option figure).
//! - `{"layout":"code","rows":[["KALEM","LBMFN"]],"query":["SİLGİ","?"]}`.
//! - `{"layout":"clues","lines":["…"]}` — numbered premises.
//! - `{"layout":"clock","h":3,"m":40}` — an analogue face.
//! Any layout may carry `"alphabet":true`: the view then shows the Turkish alphabet as a hint strip.

use super::item::{IqItem, IqOption};
use crate::rng::Rng;
use serde_json::Value;

/// The 29-letter Turkish alphabet (1-based positions in all helpers).
pub const TR: [char; 29] = [
    'A', 'B', 'C', 'Ç', 'D', 'E', 'F', 'G', 'Ğ', 'H', 'I', 'İ', 'J', 'K', 'L', 'M', 'N', 'O', 'Ö', 'P', 'R', 'S',
    'Ş', 'T', 'U', 'Ü', 'V', 'Y', 'Z',
];

/// Position of a Turkish capital letter, 1..=29.
pub fn tr_pos(c: char) -> Option<i64> {
    TR.iter().position(|&x| x == c).map(|i| i as i64 + 1)
}

/// Letter at a (wrapping) Turkish position: 1 = A, 29 = Z, 30 = A again, 0 = Z.
pub fn tr_at(p: i64) -> char {
    TR[((p - 1).rem_euclid(29)) as usize]
}

/// The letter an "English alphabet" solver would map a Turkish letter to.
pub fn latin_base(c: char) -> char {
    match c {
        'Ç' => 'C',
        'Ğ' => 'G',
        'İ' => 'I',
        'Ö' => 'O',
        'Ş' => 'S',
        'Ü' => 'U',
        x => x,
    }
}

/// Position in the 26-letter English alphabet (Turkish letters folded to their base first).
pub fn en_pos(c: char) -> i64 {
    (latin_base(c) as u8 - b'A') as i64 + 1
}

pub fn en_at(p: i64) -> char {
    (b'A' + ((p - 1).rem_euclid(26)) as u8) as char
}

/// Number as shown to the player (true minus sign: Jost has U+2212).
pub fn num(v: i64) -> String {
    if v < 0 {
        format!("\u{2212}{}", -v)
    } else {
        v.to_string()
    }
}

/// Parse a number written by [`num`].
pub fn parse_num(s: &str) -> Option<i64> {
    let t = s.replace('\u{2212}', "-");
    t.trim().parse().ok()
}

pub fn digits(v: i64) -> Vec<i64> {
    v.abs().to_string().bytes().map(|b| (b - b'0') as i64).collect()
}

pub fn digit_sum(v: i64) -> i64 {
    digits(v).iter().sum()
}

pub fn is_prime(n: i64) -> bool {
    if n < 2 {
        return false;
    }
    let mut d = 2;
    while d * d <= n {
        if n % d == 0 {
            return false;
        }
        d += 1;
    }
    true
}

/// Exact integer root: Some(r) when r^k == n.
pub fn exact_root(n: i64, k: u32) -> Option<i64> {
    if n < 0 {
        return None;
    }
    let r = (n as f64).powf(1.0 / k as f64).round() as i64;
    (r.saturating_sub(1)..=r + 1).find(|&x| x >= 0 && x.checked_pow(k) == Some(n))
}

/// A text item with options already placed.
pub fn text_item(
    cat: &'static str,
    hard: bool,
    prompt: impl Into<String>,
    figure: Option<Value>,
    options: Vec<String>,
    answer: usize,
    why: impl Into<String>,
) -> IqItem {
    IqItem {
        cat,
        hard,
        prompt: prompt.into(),
        figure,
        options: options.into_iter().map(IqOption::Text).collect(),
        answer,
        typed: None,
        why: why.into(),
    }
}

/// A typed-answer item (number pad): no options.
pub fn typed_item(cat: &'static str, hard: bool, prompt: impl Into<String>, figure: Option<Value>, value: i64, why: impl Into<String>) -> IqItem {
    IqItem { cat, hard, prompt: prompt.into(), figure, options: vec![], answer: 0, typed: Some(value), why: why.into() }
}

/// Put the answer at a uniformly random position among the distractors.
pub fn place<T: Clone>(r: &mut Rng, answer: T, distractors: &[T]) -> (Vec<T>, usize) {
    let mut v: Vec<T> = distractors.to_vec();
    r.shuffle(&mut v);
    let at = r.below(v.len() + 1);
    v.insert(at, answer);
    (v, at)
}

/// Numeric options sorted ascending with the answer at a uniformly drawn rank, so neither the
/// position nor "pick the middle value" gives the answer away. Bug-model values (`bugs`) are used
/// first; the rest are filled with values near the answer or near a bug value. `ok(v)` must hold
/// for every distractor (the category's oracle: v must not also be explainable). `min` is the
/// smallest value allowed.
pub fn numeric_options(
    r: &mut Rng,
    answer: i64,
    bugs: &[i64],
    n: usize,
    spread: i64,
    min: i64,
    ok: &dyn Fn(i64) -> bool,
) -> Option<(Vec<i64>, usize)> {
    let spread = spread.max(2);
    let mut good: Vec<i64> = vec![];
    for &b in bugs {
        if b != answer && b >= min && !good.contains(&b) && ok(b) {
            good.push(b);
        }
    }
    for _ in 0..4 {
        let rank = r.below(n);
        let need_lo = rank;
        let need_hi = n - 1 - rank;
        let mut lo: Vec<i64> = good.iter().copied().filter(|&v| v < answer).collect();
        let mut hi: Vec<i64> = good.iter().copied().filter(|&v| v > answer).collect();
        r.shuffle(&mut lo);
        r.shuffle(&mut hi);
        lo.truncate(need_lo);
        hi.truncate(need_hi);
        let mut tries = 0;
        while (lo.len() < need_lo || hi.len() < need_hi) && tries < 400 {
            tries += 1;
            let mut bases = vec![answer];
            bases.extend(lo.iter().chain(hi.iter()).copied());
            let base = *r.pick(&bases);
            let off = r.range((spread / 3).max(2), spread * 2);
            let v = if r.chance(0.5) { base + off } else { base - off };
            if v == answer || v < min || lo.contains(&v) || hi.contains(&v) || !ok(v) {
                continue;
            }
            if v < answer && lo.len() < need_lo {
                lo.push(v);
            } else if v > answer && hi.len() < need_hi {
                hi.push(v);
            }
        }
        if lo.len() >= need_lo && hi.len() >= need_hi {
            lo.truncate(need_lo);
            hi.truncate(need_hi);
            let mut all: Vec<i64> = lo.into_iter().chain(std::iter::once(answer)).chain(hi).collect();
            all.sort();
            let at = all.iter().position(|&v| v == answer)?;
            return Some((all, at));
        }
    }
    None
}

pub fn strs(v: &[i64]) -> Vec<String> {
    v.iter().map(|&x| num(x)).collect()
}

/// Build candidates until one passes the oracle. Returns the item and the oracle's verdict on it
/// (`Err` only when every attempt failed: the tests assert this never happens on the sequence).
pub fn retry<S>(
    r: &mut Rng,
    hard: bool,
    build: fn(&mut Rng, bool) -> Option<(IqItem, S)>,
    verify: fn(&IqItem, &S) -> Result<(), String>,
) -> (IqItem, Result<(), String>) {
    let mut last: Option<(IqItem, Result<(), String>)> = None;
    for _ in 0..400 {
        if let Some((item, spec)) = build(r, hard) {
            match verify(&item, &spec) {
                Ok(()) => return (item, Ok(())),
                Err(e) => last = Some((item, Err(e))),
            }
        }
    }
    last.unwrap_or_else(|| {
        (text_item("none", hard, "?", None, vec!["?".into(), "-".into()], 0, ""), Err("no candidate built".into()))
    })
}

/// Like [`retry`], but the subtype (`kind`) is drawn once and kept while retrying, so subtypes
/// the oracle rejects more often are not crowded out by easy ones. Falls back to fresh kinds.
pub fn retry_kind<S>(
    r: &mut Rng,
    hard: bool,
    pick: fn(&mut Rng, bool) -> usize,
    build: fn(&mut Rng, bool, usize) -> Option<(IqItem, S)>,
    verify: fn(&IqItem, &S) -> Result<(), String>,
) -> (IqItem, Result<(), String>) {
    let mut last: Option<(IqItem, Result<(), String>)> = None;
    let mut kind = pick(r, hard);
    for attempt in 0..3000 {
        if attempt % 1000 == 999 {
            kind = pick(r, hard);
        }
        if let Some((item, spec)) = build(r, hard, kind) {
            match verify(&item, &spec) {
                Ok(()) => return (item, Ok(())),
                Err(e) => last = Some((item, Err(e))),
            }
        }
    }
    last.unwrap_or_else(|| {
        (text_item("none", hard, "?", None, vec!["?".into(), "-".into()], 0, ""), Err("no candidate built".into()))
    })
}

/// Shared sanity checks on any finished item: option count, distinct options, answer in range.
pub fn basic_checks(item: &IqItem) -> Result<(), String> {
    if let Some(_) = item.typed {
        if !item.options.is_empty() {
            return Err("typed item with options".into());
        }
        return Ok(());
    }
    if !(4..=6).contains(&item.options.len()) {
        return Err(format!("{} options", item.options.len()));
    }
    if item.answer >= item.options.len() {
        return Err("answer out of range".into());
    }
    for i in 0..item.options.len() {
        for j in 0..i {
            if item.options[i] == item.options[j] {
                return Err(format!("duplicate option {:?}", item.options[i]));
            }
        }
    }
    if item.prompt.contains('→') || item.why.contains('→') || item.prompt.contains('●') || item.prompt.contains('★') {
        return Err("glyph missing from the UI font".into());
    }
    Ok(())
}

/// Option texts (Text options only).
pub fn option_texts(item: &IqItem) -> Vec<String> {
    item.options
        .iter()
        .map(|o| match o {
            IqOption::Text(t) => t.clone(),
            IqOption::Figure(f) => f.to_string(),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iq_common_alphabet() {
        assert_eq!(tr_pos('A'), Some(1));
        assert_eq!(tr_pos('Ç'), Some(4));
        assert_eq!(tr_pos('K'), Some(14));
        assert_eq!(tr_pos('Z'), Some(29));
        assert_eq!(tr_at(30), 'A');
        assert_eq!(tr_at(0), 'Z');
        assert_eq!(en_pos('Ş'), 19);
        assert_eq!(en_at(27), 'A');
    }

    #[test]
    fn iq_common_numeric_options_rank_uniform() {
        let mut r = Rng::new(7);
        let mut ranks = [0; 4];
        for _ in 0..400 {
            let (opts, at) = numeric_options(&mut r, 50, &[48, 55, 60], 4, 6, 0, &|_| true).unwrap();
            assert_eq!(opts[at], 50);
            assert!(opts.windows(2).all(|w| w[0] < w[1]));
            ranks[at] += 1;
        }
        assert!(ranks.iter().all(|&c| c > 70), "{ranks:?}");
    }
}
