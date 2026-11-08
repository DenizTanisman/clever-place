//! Şifre çözme — coding–decoding on the Turkish alphabet.
//!
//! Medium: a uniform shift (KALEM gives LBMFN at +1), reverse-then-shift, letters written as their
//! alphabet positions. Hard: a position-dependent shift (+1, +2, +3 …), alternating shifts
//! (+k, −k …), the mirror alphabet (A↔Z, B↔Y …), the sum of letter positions, and sentence codes
//! (three coded sentences; find the code word of one word by elimination).
//!
//! Distractors form a 2 × 2 design of two plausible mistakes — e.g. (right shift / wrong shift) ×
//! (Turkish / English alphabet) — so every option has exactly one "near twin" and an option-only
//! solver cannot pick the centre of the set.
//!
//! Oracle: a family of letter rules — shift a + b·i, alternating shifts, reverse before or after a
//! shift, mirror + a, adjacent-pair swap + a — is fitted to every example; each rule that fits
//! all examples encodes the query, and exactly one option may be predicted. Position and sum codes
//! are checked with the same idea (positions + a, sum + a, sum + a·length). Sentence codes are
//! solved by enumerating every word ↔ code assignment.

use super::common::*;
use super::item::IqItem;
use crate::rng::Rng;
use serde_json::json;

pub const ID: &str = "code";

const WORDS: &[&str] = &[
    "KALEM", "SİLGİ", "KİTAP", "DEFTER", "ELMA", "ARMUT", "KAPI", "ÇİÇEK", "GÜNEŞ", "YILDIZ", "DENİZ", "ORMAN", "BULUT", "KÖPRÜ",
    "ŞEHİR", "SOKAK", "BAHÇE", "KUZU", "KEDİ", "KÖPEK", "TAVUK", "ÇORBA", "EKMEK", "PEYNİR", "ZEYTİN", "LİMON", "KİRAZ", "ÜZÜM",
    "SAAT", "MASA", "HALI", "ÇANTA", "GÖZLÜK", "DÜĞME", "IŞIK", "ÖRDEK", "ŞAPKA", "TOPRAK", "YAĞMUR", "RÜZGÂR", "DAĞ", "ÇAY",
    "SÜT", "BAL", "ŞEKER", "KAŞIK", "TABAK", "FİNCAN", "BARDAK", "PAZAR", "ÇARŞI", "OKUL", "SINIF", "ÖĞRENCİ", "KUŞ", "BALIK",
    "AĞAÇ", "YAPRAK", "ÇİLEK", "INCIR", "ÜTÜ", "GEMİ", "TREN", "UÇAK", "KÖY", "NEHİR", "GÖL", "ŞELALE", "KÖŞE", "DOLAP",
];

fn word_pos(w: &str) -> Option<Vec<i64>> {
    w.chars().map(tr_pos).collect()
}

fn word_of(p: &[i64]) -> String {
    p.iter().map(|&x| tr_at(x)).collect()
}

/// English-alphabet version of a shift: what a solver using the 26 letters would write.
fn en_shift(w: &str, sh: &dyn Fn(usize) -> i64) -> String {
    w.chars().enumerate().map(|(i, c)| en_at(en_pos(c) + sh(i))).collect()
}

#[derive(Clone, Copy, Debug)]
enum LetterRule {
    Shift(i64, i64),
    Alt(i64, i64),
    RevThen(i64, i64),
    ThenRev(i64, i64),
    Mirror(i64),
    Swap(i64),
}

fn apply(rule: LetterRule, w: &[i64]) -> Vec<i64> {
    let sh = |v: &[i64], a: i64, b: i64| -> Vec<i64> { v.iter().enumerate().map(|(i, &x)| (x - 1 + a + b * i as i64).rem_euclid(29) + 1).collect() };
    match rule {
        LetterRule::Shift(a, b) => sh(w, a, b),
        LetterRule::Alt(a, b) => w.iter().enumerate().map(|(i, &x)| (x - 1 + if i % 2 == 0 { a } else { b }).rem_euclid(29) + 1).collect(),
        LetterRule::RevThen(a, b) => {
            let mut r: Vec<i64> = w.to_vec();
            r.reverse();
            sh(&r, a, b)
        }
        LetterRule::ThenRev(a, b) => {
            let mut r = sh(w, a, b);
            r.reverse();
            r
        }
        LetterRule::Mirror(a) => w.iter().map(|&x| (30 - x - 1 + a).rem_euclid(29) + 1).collect(),
        LetterRule::Swap(a) => {
            let mut r = w.to_vec();
            for i in (0..r.len().saturating_sub(1)).step_by(2) {
                r.swap(i, i + 1);
            }
            sh(&r, a, 0)
        }
    }
}

fn all_rules() -> Vec<LetterRule> {
    let mut v = vec![];
    for a in -6..=6 {
        for b in -3..=3 {
            v.push(LetterRule::Shift(a, b));
            v.push(LetterRule::RevThen(a, b));
            v.push(LetterRule::ThenRev(a, b));
        }
        for b in -6..=6 {
            if a != b {
                v.push(LetterRule::Alt(a, b));
            }
        }
        v.push(LetterRule::Mirror(a));
        v.push(LetterRule::Swap(a));
    }
    v
}

#[derive(Clone, Debug)]
pub enum Spec {
    Letters { examples: Vec<(String, String)>, query: String, opts: Vec<String> },
    Positions { examples: Vec<(String, String)>, query: String, opts: Vec<String> },
    Sum { examples: Vec<(String, i64)>, query: String, opts: Vec<String> },
    Sentences { sentences: Vec<(Vec<String>, Vec<String>)>, target: String, opts: Vec<String> },
}

fn letter_predictions(examples: &[(String, String)], query: &str) -> Vec<String> {
    let q = word_pos(query).unwrap_or_default();
    let mut out: Vec<String> = vec![];
    for rule in all_rules() {
        let ok = examples.iter().all(|(w, c)| match (word_pos(w), word_pos(c)) {
            (Some(w), Some(c)) => w.len() == c.len() && apply(rule, &w) == c,
            _ => false,
        });
        if ok {
            let p = word_of(&apply(rule, &q));
            if !out.contains(&p) {
                out.push(p);
            }
        }
    }
    out
}

fn pos_text(p: &[i64]) -> String {
    p.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(" ")
}

fn position_predictions(examples: &[(String, String)], query: &str) -> Vec<String> {
    let mut out = vec![];
    let q = word_pos(query).unwrap_or_default();
    for a in -5..=5 {
        for b in -2..=2 {
            let enc = |w: &[i64]| -> Vec<i64> { w.iter().enumerate().map(|(i, &x)| x + a + b * i as i64).collect() };
            let enc_rev = |w: &[i64]| -> Vec<i64> {
                let mut r = enc(w);
                r.reverse();
                r
            };
            for f in [&enc as &dyn Fn(&[i64]) -> Vec<i64>, &enc_rev] {
                if examples.iter().all(|(w, c)| word_pos(w).map(|w| pos_text(&f(&w))) == Some(c.clone())) {
                    let p = pos_text(&f(&q));
                    if !out.contains(&p) {
                        out.push(p);
                    }
                }
            }
        }
    }
    out
}

fn sum_predictions(examples: &[(String, i64)], query: &str) -> Vec<i64> {
    let mut out = vec![];
    let q = word_pos(query).unwrap_or_default();
    for a in -30..=30 {
        for b in -3..=3 {
            for m in 1..=2 {
                let f = |w: &[i64]| m * w.iter().sum::<i64>() + a + b * w.len() as i64;
                if examples.iter().all(|(w, c)| word_pos(w).map(|w| f(&w)) == Some(*c)) {
                    let p = f(&q);
                    if !out.contains(&p) {
                        out.push(p);
                    }
                }
            }
        }
    }
    out
}

fn permutations(n: usize) -> Vec<Vec<usize>> {
    if n == 0 {
        return vec![vec![]];
    }
    let mut out = vec![];
    for p in permutations(n - 1) {
        for i in 0..=p.len() {
            let mut q = p.clone();
            q.insert(i, n - 1);
            out.push(q);
        }
    }
    out
}

/// Every code word the target word can have under some assignment consistent with all sentences.
fn sentence_predictions(sentences: &[(Vec<String>, Vec<String>)], target: &str) -> Vec<String> {
    let mut words: Vec<String> = sentences.iter().flat_map(|s| s.0.clone()).collect();
    words.sort();
    words.dedup();
    let mut codes: Vec<String> = sentences.iter().flat_map(|s| s.1.clone()).collect();
    codes.sort();
    codes.dedup();
    let mut out = vec![];
    if words.len() != codes.len() {
        return out;
    }
    for p in permutations(words.len()) {
        let code_of = |w: &String| codes[p[words.iter().position(|x| x == w).unwrap()]].clone();
        let ok = sentences.iter().all(|(ws, cs)| {
            let mut a: Vec<String> = ws.iter().map(code_of).collect();
            a.sort();
            let mut b = cs.clone();
            b.sort();
            a == b
        });
        if ok {
            let c = code_of(&target.to_string());
            if !out.contains(&c) {
                out.push(c);
            }
        }
    }
    out
}

fn pick_words(r: &mut Rng, n: usize, need_special: bool) -> Vec<String> {
    let mut out: Vec<String> = vec![];
    while out.len() < n {
        let w = r.pick(WORDS).to_string();
        if word_pos(&w).is_none() || out.contains(&w) {
            continue;
        }
        if need_special && out.len() == n - 1 && !w.chars().any(|c| "ÇĞIİÖŞÜ".contains(c) || "CGHOPSTUV".contains(c)) {
            continue;
        }
        out.push(w);
    }
    out
}

/// Answer and three distractors from a 2 × 2 design: `opts[0]` is the answer.
fn grid4(a: String, b: String, c: String, d: String) -> Vec<String> {
    vec![a, b, c, d]
}

fn letters_item(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    let kind = if hard { r.below(4) } else { r.below(2) };
    let n_ex = if hard { 2 } else { 1 };
    let ws = pick_words(r, n_ex + 1, true);
    let (ex_words, query) = (&ws[..n_ex], ws[n_ex].clone());
    let q = word_pos(&query)?;
    let (rule, alt_rule, why): (LetterRule, LetterRule, String) = match (hard, kind) {
        (false, 0) => {
            let k = *r.pick(&[1i64, 2, 3, -1, -2]);
            let dir = if k > 0 { "ileri" } else { "geri" };
            (LetterRule::Shift(k, 0), LetterRule::Shift(-k, 0), format!("Her harf alfabede {} harf {} kayıyor.", k.abs(), dir))
        }
        (false, _) => {
            let k = *r.pick(&[1i64, 2, -1]);
            (LetterRule::RevThen(k, 0), LetterRule::Shift(k, 0), format!("Kelime ters çevriliyor, sonra her harf {} harf {} kayıyor.", k.abs(), if k > 0 { "ileri" } else { "geri" }))
        }
        (true, 0) => {
            let a = r.range(1, 2);
            (LetterRule::Shift(a, 1), LetterRule::Shift(a - 1, 1), format!("Harfler sırasıyla +{}, +{}, +{} … kayıyor: n. harf {} kadar ileri.", a, a + 1, a + 2, if a == 1 { "n".to_string() } else { format!("n + {}", a - 1) }))
        }
        (true, 1) => {
            let k = r.range(1, 3);
            (LetterRule::Alt(k, -k), LetterRule::Alt(-k, k), format!("Harfler sırayla {k} ileri, {k} geri kayıyor."))
        }
        (true, 2) => (LetterRule::Mirror(0), LetterRule::Mirror(1), "Ayna alfabe: A↔Z, B↔Y, C↔V … her harf, alfabenin öbür ucundan aynı sıradaki harfle yer değiştiriyor.".replace('↔', " ile ")),
        _ => {
            let k = *r.pick(&[1i64, 2]);
            (LetterRule::RevThen(k, 1), LetterRule::Shift(k, 1), format!("Kelime ters çevriliyor, sonra harfler sırasıyla +{}, +{}, +{} … kayıyor.", k, k + 1, k + 2))
        }
    };
    let examples: Vec<(String, String)> = ex_words.iter().map(|w| (w.clone(), word_of(&apply(rule, &word_pos(w).unwrap())))).collect();
    let answer = word_of(&apply(rule, &q));
    let wrong = word_of(&apply(alt_rule, &q));
    // English-alphabet twins of the right and the wrong rule.
    let en_of = |rl: LetterRule| -> String {
        match rl {
            LetterRule::Shift(a, b) => en_shift(&query, &|i| a + b * i as i64),
            LetterRule::Alt(a, b) => en_shift(&query, &|i| if i % 2 == 0 { a } else { b }),
            LetterRule::RevThen(a, b) => {
                let rev: String = query.chars().rev().collect();
                en_shift(&rev, &|i| a + b * i as i64)
            }
            LetterRule::Mirror(a) => query.chars().map(|c| en_at(27 - en_pos(c) + a)).collect(),
            other => word_of(&apply(other, &q)),
        }
    };
    let (en_right, en_wrong) = (en_of(rule), en_of(alt_rule));
    let set = grid4(answer.clone(), wrong, en_right, en_wrong);
    let mut ds: Vec<String> = set[1..].to_vec();
    ds.sort();
    ds.dedup();
    if ds.len() < 3 || ds.contains(&answer) {
        return None;
    }
    let (opts, at) = place(r, answer.clone(), &ds);
    let fig = json!({"layout": "code", "rows": examples.iter().map(|(a, b)| vec![a.clone(), b.clone()]).collect::<Vec<_>>(), "query": [query.clone(), "?"], "alphabet": true});
    let why = format!("{why} {query} için {answer}.");
    let item = text_item(ID, hard, "Aynı şifreyle bu kelime nasıl yazılır?", Some(fig), opts.clone(), at, why);
    Some((item, Spec::Letters { examples, query, opts }))
}

fn positions_item(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    let ws = pick_words(r, 2, true);
    let (w, query) = (ws[0].clone(), ws[1].clone());
    let a = if hard { r.range(1, 3) } else { 0 };
    let enc = |w: &str, off: i64| pos_text(&word_pos(w).unwrap().iter().map(|x| x + off).collect::<Vec<_>>());
    let enc_en = |w: &str, off: i64| pos_text(&w.chars().map(|c| en_pos(c) + off).collect::<Vec<_>>());
    let examples = vec![(w.clone(), enc(&w, a))];
    let answer = enc(&query, a);
    let set = vec![answer.clone(), enc(&query, a + 1), enc_en(&query, a), enc_en(&query, a + 1)];
    let mut ds: Vec<String> = set[1..].to_vec();
    ds.dedup();
    if ds.iter().any(|d| *d == answer) || ds.len() < 3 || ds[0] == ds[1] || ds[1] == ds[2] || ds[0] == ds[2] {
        return None;
    }
    let (opts, at) = place(r, answer.clone(), &ds);
    let fig = json!({"layout": "code", "rows": [[w.clone(), examples[0].1.clone()]], "query": [query.clone(), "?"], "alphabet": true});
    let why = if a == 0 {
        format!("Her harf, Türk alfabesindeki sırasıyla yazılıyor (A 1, B 2, C 3, Ç 4 …). {query}: {answer}.")
    } else {
        format!("Her harf, Türk alfabesindeki sırasının {a} fazlasıyla yazılıyor. {query}: {answer}.")
    };
    let item = text_item(ID, hard, "Aynı şifreyle bu kelime nasıl yazılır?", Some(fig), opts.clone(), at, why);
    Some((item, Spec::Positions { examples, query, opts }))
}

fn sum_item(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    let ws = pick_words(r, 3, true);
    let s = |w: &str| word_pos(w).unwrap().iter().sum::<i64>();
    let s_en = |w: &str| w.chars().map(en_pos).sum::<i64>();
    let (w1, w2, q) = (ws[0].clone(), ws[1].clone(), ws[2].clone());
    let len = q.chars().count() as i64;
    let examples = vec![(w1.clone(), s(&w1)), (w2.clone(), s(&w2))];
    let answer = s(&q);
    let set = [answer, answer + len, s_en(&q), s_en(&q) + len];
    let mut ds: Vec<i64> = set[1..].to_vec();
    ds.sort();
    ds.dedup();
    if ds.len() < 3 || ds.contains(&answer) {
        return None;
    }
    let (opts, at) = place(r, num(answer), &ds.iter().map(|&x| num(x)).collect::<Vec<_>>());
    let fig = json!({"layout": "code", "rows": [[w1.clone(), num(examples[0].1)], [w2.clone(), num(examples[1].1)]], "query": [q.clone(), "?"], "alphabet": true});
    let why = format!(
        "Şifre, harflerin Türk alfabesindeki sıralarının toplamı. {q}: {} = {}.",
        word_pos(&q).unwrap().iter().map(|x| x.to_string()).collect::<Vec<_>>().join(" + "),
        answer
    );
    let item = text_item(ID, hard, "Aynı şifreyle bu kelimenin sayısı kaç?", Some(fig), opts.clone(), at, why);
    Some((item, Spec::Sum { examples, query: q, opts }))
}

const PHRASE_WORDS: &[&str] = &["mavi", "kuş", "uçar", "kırmızı", "gül", "açar", "küçük", "kedi", "uyur", "büyük", "deniz", "parlar", "sarı", "güneş", "doğar", "yeşil", "ağaç", "büyür"];
const CODE_WORDS: &[&str] = &["lo", "pa", "ti", "ra", "ne", "ku", "mi", "so", "fe", "zu", "ba", "di"];

fn sentences_item(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    let mut words: Vec<String> = PHRASE_WORDS.iter().map(|s| s.to_string()).collect();
    r.shuffle(&mut words);
    words.truncate(5);
    let mut codes: Vec<String> = CODE_WORDS.iter().map(|s| s.to_string()).collect();
    r.shuffle(&mut codes);
    codes.truncate(5);
    let code_of = |w: &String| codes[words.iter().position(|x| x == w).unwrap()].clone();
    // Three sentences of 2–3 words.
    let mut sentences: Vec<(Vec<String>, Vec<String>)> = vec![];
    for _ in 0..3 {
        let n = r.range(2, 3) as usize;
        let mut ws = words.clone();
        r.shuffle(&mut ws);
        ws.truncate(n);
        let mut cs: Vec<String> = ws.iter().map(code_of).collect();
        r.shuffle(&mut cs);
        sentences.push((ws, cs));
    }
    let used: Vec<String> = words.iter().filter(|w| sentences.iter().any(|s| s.0.contains(w))).cloned().collect();
    if used.len() != words.len() {
        return None;
    }
    let target = r.pick(&words).clone();
    let preds = sentence_predictions(&sentences, &target);
    if preds.len() != 1 {
        return None;
    }
    let answer = code_of(&target);
    let mut others: Vec<String> = codes.iter().filter(|c| **c != answer).cloned().collect();
    r.shuffle(&mut others);
    others.truncate(3);
    let (opts, at) = place(r, answer.clone(), &others);
    let lines: Vec<String> = sentences.iter().map(|(ws, cs)| format!("“{}” = {}", ws.join(" "), cs.join(" "))).collect();
    let fig = json!({"layout": "clues", "lines": lines, "note": "Şifre kelimelerinin sırası karışık olabilir."});
    let why = format!("Cümleleri karşılaştır: ortak kelimeler ortak şifreleri verir. Eleme sonunda “{target}” = {answer}.");
    let _ = hard;
    let item = text_item(ID, true, format!("Şifreli dilde “{target}” nasıl yazılır?"), Some(fig), opts.clone(), at, why);
    Some((item, Spec::Sentences { sentences, target, opts }))
}

fn build(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    if hard {
        match r.below(8) {
            0..=4 => letters_item(r, true),
            5 => sum_item(r, true),
            6 => positions_item(r, true),
            _ => sentences_item(r, true),
        }
    } else {
        match r.below(5) {
            0..=2 => letters_item(r, false),
            3 => positions_item(r, false),
            _ => sum_item(r, false),
        }
    }
}

fn verify(item: &IqItem, s: &Spec) -> Result<(), String> {
    basic_checks(item)?;
    let (preds, opts): (Vec<String>, &Vec<String>) = match s {
        Spec::Letters { examples, query, opts } => (letter_predictions(examples, query), opts),
        Spec::Positions { examples, query, opts } => (position_predictions(examples, query), opts),
        Spec::Sum { examples, query, opts } => (sum_predictions(examples, query).into_iter().map(num).collect(), opts),
        Spec::Sentences { sentences, target, opts } => (sentence_predictions(sentences, target), opts),
    };
    let hits: Vec<usize> = (0..opts.len()).filter(|&i| preds.contains(&opts[i])).collect();
    if hits != vec![item.answer] {
        return Err(format!("predictions {preds:?}, options {opts:?}, answer {}", item.answer));
    }
    Ok(())
}

pub fn gen_checked(r: &mut Rng, hard: bool) -> (IqItem, Result<(), String>) {
    let (mut it, res) = retry(r, hard, build, verify);
    it.hard = hard;
    (it, res)
}

pub fn gen(r: &mut Rng, hard: bool) -> IqItem {
    gen_checked(r, hard).0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iq_code_doc_examples() {
        // KALEM gives LBMFN; SİLGİ gives ŞJMĞJ (+1 in the Turkish alphabet).
        let ex = vec![("KALEM".to_string(), "LBMFN".to_string())];
        assert_eq!(letter_predictions(&ex, "SİLGİ"), vec!["ŞJMĞJ".to_string()]);
        // ELMA gives FNÖD, ARI gives BŞK: the n-th letter moves +n. KUŞ gives LVÜ.
        let ex = vec![("ELMA".to_string(), "FNÖD".to_string()), ("ARI".to_string(), "BŞK".to_string())];
        assert_eq!(letter_predictions(&ex, "KUŞ"), vec!["LVÜ".to_string()]);
    }
}
