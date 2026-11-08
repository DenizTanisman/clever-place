//! Mantık — short deductions in plain Turkish.
//!
//! Medium: ordering by comparisons (4 people), seating in a row (4 people), two-premise
//! syllogisms with nonsense words, one-step conditionals (modus ponens / tollens, with the
//! "nothing follows" trap). Hard: seating with 5 people and negative / distance clues, three-premise
//! syllogisms with "some", conditional chains and "at least one" statements, key-in-a-box puzzles
//! where exactly one sign is true (or false), and "exactly one of them lies" puzzles.
//!
//! Every subtype keeps a structured spec next to the text; the oracle enumerates all models —
//! permutations for orderings and seatings, every Venn-region world (each named set non-empty)
//! for syllogisms, every truth assignment for conditionals, every key box / culprit for the
//! box and liar puzzles — and requires exactly one option to hold in every consistent model
//! (the "nothing follows" option is right exactly when no other option is forced).

use super::common::*;
use super::item::IqItem;
use crate::rng::Rng;
use serde_json::json;

pub const ID: &str = "logic";

/// (name, genitive, ablative)
const NAMES: &[(&str, &str, &str)] = &[
    ("Ali", "Ali'nin", "Ali'den"),
    ("Banu", "Banu'nun", "Banu'dan"),
    ("Cem", "Cem'in", "Cem'den"),
    ("Deniz", "Deniz'in", "Deniz'den"),
    ("Ece", "Ece'nin", "Ece'den"),
    ("Kaan", "Kaan'ın", "Kaan'dan"),
    ("Selin", "Selin'in", "Selin'den"),
    ("Oya", "Oya'nın", "Oya'dan"),
    ("Mert", "Mert'in", "Mert'ten"),
    ("Nur", "Nur'un", "Nur'dan"),
    ("Tolga", "Tolga'nın", "Tolga'dan"),
    ("İpek", "İpek'in", "İpek'ten"),
];

fn cap(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some('i') => format!("İ{}", c.as_str()),
        Some(f) => format!("{}{}", f.to_uppercase(), c.as_str()),
        None => String::new(),
    }
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

// ------------------------------------------------------------------------------- seating / order

#[derive(Clone, Copy, Debug, PartialEq)]
enum Clue {
    /// x is at seat p (0-based from the left).
    At(usize, usize),
    End(usize),
    NotEnd(usize),
    RightOf(usize, usize),
    LeftSome(usize, usize),
    Next(usize, usize),
    NotNext(usize, usize),
    Gap1(usize, usize),
    /// Ordering: x ranks above y (taller / older / faster).
    Above(usize, usize),
}

/// `pos[person] = seat` (or rank, 0 = top).
fn holds(c: Clue, pos: &[usize], n: usize) -> bool {
    let d = |a: usize, b: usize| (pos[a] as i64 - pos[b] as i64).abs();
    match c {
        Clue::At(x, p) => pos[x] == p,
        Clue::End(x) => pos[x] == 0 || pos[x] == n - 1,
        Clue::NotEnd(x) => pos[x] != 0 && pos[x] != n - 1,
        Clue::RightOf(x, y) => pos[x] == pos[y] + 1,
        Clue::LeftSome(x, y) => pos[x] < pos[y],
        Clue::Next(x, y) => d(x, y) == 1,
        Clue::NotNext(x, y) => d(x, y) != 1,
        Clue::Gap1(x, y) => d(x, y) == 2,
        Clue::Above(x, y) => pos[x] < pos[y],
    }
}

/// Every arrangement (pos per person) satisfying all clues.
fn models(clues: &[Clue], n: usize) -> Vec<Vec<usize>> {
    permutations(n).into_iter().filter(|pos| clues.iter().all(|&c| holds(c, pos, n))).collect()
}

fn ord(p: usize) -> String {
    format!("{}.", p + 1)
}

fn clue_text(c: Clue, names: &[usize], adj: &str) -> String {
    let nm = |i: usize| NAMES[names[i]].0;
    let gen = |i: usize| NAMES[names[i]].1;
    let abl = |i: usize| NAMES[names[i]].2;
    match c {
        Clue::At(x, p) => format!("{} soldan {} sandalyede.", nm(x), ord(p)),
        Clue::End(x) => format!("{} uçlardaki sandalyelerden birinde.", nm(x)),
        Clue::NotEnd(x) => format!("{} uçlarda oturmuyor.", nm(x)),
        Clue::RightOf(x, y) => format!("{}, {} hemen sağında.", nm(x), gen(y)),
        Clue::LeftSome(x, y) => format!("{}, {} solunda bir yerde (yanında olmak zorunda değil).", nm(x), gen(y)),
        Clue::Next(x, y) => format!("{} ile {} yan yana.", nm(x), nm(y)),
        Clue::NotNext(x, y) => format!("{} ile {} yan yana değil.", nm(x), nm(y)),
        Clue::Gap1(x, y) => format!("{} ile {} arasında tam bir kişi var.", nm(x), nm(y)),
        Clue::Above(x, y) => format!("{}, {} daha {adj}.", nm(x), abl(y)),
    }
}

#[derive(Clone, Debug)]
pub struct SeatSpec {
    n: usize,
    clues: Vec<Clue>,
    /// Seat (or rank) asked about.
    ask: usize,
    /// Options as person indices.
    opts: Vec<usize>,
}

fn seat_answer_set(s: &SeatSpec) -> Vec<usize> {
    let mut v: Vec<usize> = models(&s.clues, s.n).iter().map(|pos| pos.iter().position(|&p| p == s.ask).unwrap()).collect();
    v.sort();
    v.dedup();
    v
}

fn random_clue(r: &mut Rng, n: usize, hard: bool, ordering: bool) -> Clue {
    let x = r.below(n);
    let mut y = r.below(n);
    while y == x {
        y = r.below(n);
    }
    if ordering {
        return Clue::Above(x, y);
    }
    let kinds = if hard { 8 } else { 5 };
    match r.below(kinds) {
        0 => Clue::RightOf(x, y),
        1 => Clue::Next(x, y),
        2 => Clue::End(x),
        3 => Clue::LeftSome(x, y),
        4 => Clue::At(x, r.below(n)),
        5 => Clue::NotNext(x, y),
        6 => Clue::Gap1(x, y),
        _ => Clue::NotEnd(x),
    }
}

/// Seating (or ordering) puzzle: add true clues until the asked seat is forced, then drop
/// redundant ones.
fn seat_puzzle(r: &mut Rng, hard: bool, ordering: bool) -> Option<(IqItem, Spec)> {
    let n = if hard { 5 } else { 4 };
    let mut pool: Vec<usize> = (0..NAMES.len()).collect();
    r.shuffle(&mut pool);
    let names: Vec<usize> = pool[..n].to_vec();
    let mut truth: Vec<usize> = (0..n).collect();
    r.shuffle(&mut truth); // truth[person] = seat
    let ask = r.below(n);
    let mut clues: Vec<Clue> = vec![];
    for _ in 0..60 {
        let c = random_clue(r, n, hard, ordering);
        if !holds(c, &truth, n) || clues.contains(&c) {
            continue;
        }
        if let Clue::At(_, p) = c {
            if p == ask {
                continue;
            }
        }
        clues.push(c);
        let ms = models(&clues, n);
        let answers: Vec<usize> = ms.iter().map(|pos| pos.iter().position(|&p| p == ask).unwrap()).collect();
        if answers.windows(2).all(|w| w[0] == w[1]) {
            break;
        }
    }
    let spec0 = SeatSpec { n, clues: clues.clone(), ask, opts: vec![] };
    if seat_answer_set(&spec0).len() != 1 {
        return None;
    }
    // Drop redundant clues (keep the asked seat forced).
    let mut i = 0;
    while i < clues.len() {
        let mut fewer = clues.clone();
        fewer.remove(i);
        if seat_answer_set(&SeatSpec { n, clues: fewer.clone(), ask, opts: vec![] }).len() == 1 {
            clues = fewer;
        } else {
            i += 1;
        }
    }
    if clues.len() < if hard { 4 } else { 3 } {
        return None;
    }
    let answer_person = (0..n).find(|&p| truth[p] == ask)?;
    let others: Vec<usize> = (0..n).filter(|&p| p != answer_person).take(if hard { 4 } else { 3 }).collect();
    let (opts, at) = place(r, answer_person, &others);
    let (adj, ask_text) = if ordering {
        let (adj, sup) = *r.pick(&[("uzun", "uzun"), ("yaşlı", "yaşlı"), ("hızlı", "hızlı")]);
        let q = if ask == 0 {
            format!("En {sup} kim?")
        } else if ask == n - 1 {
            let low = match sup {
                "uzun" => "kısa",
                "yaşlı" => "genç",
                _ => "yavaş",
            };
            format!("En {low} kim?")
        } else {
            format!("En {sup} olandan başlayınca {} sırada kim var?", ord(ask))
        };
        (adj, q)
    } else {
        ("", format!("Soldan {} sandalyede kim oturuyor?", ord(ask)))
    };
    let mut lines: Vec<String> = clues.iter().map(|&c| clue_text(c, &names, adj)).collect();
    r.shuffle(&mut lines);
    let intro = if ordering { format!("{} kişi var.", n) } else { format!("{} kişi yan yana {} sandalyeye oturuyor.", n, n) };
    let fig = json!({"layout": "clues", "lines": lines});
    let order: Vec<&str> = {
        let mut v: Vec<(usize, &str)> = (0..n).map(|p| (truth[p], NAMES[names[p]].0)).collect();
        v.sort();
        v.into_iter().map(|x| x.1).collect()
    };
    let why = if ordering {
        format!("Karşılaştırmaları zincir hâline getir: {}. Sıra kesin olarak {}.", order.join(" > "), order.join(", "))
    } else {
        format!("İpuçlarının hepsine uyan dizilişte soldan sağa: {}.", order.join(", "))
    };
    let why = if ordering && models(&clues, n).len() > 1 {
        format!("Karşılaştırmalar sıranın hepsini belirlemiyor, ama sorulan yeri kesinleştiriyor: {} her durumda {} sırada.", NAMES[names[answer_person]].0, ord(ask))
    } else {
        why
    };
    let texts: Vec<String> = opts.iter().map(|&p| NAMES[names[p]].0.to_string()).collect();
    let item = text_item(ID, hard, format!("{intro} {ask_text}"), Some(fig), texts, at, why);
    Some((item, Spec::Seat(SeatSpec { n, clues, ask, opts })))
}

// ------------------------------------------------------------------------------- syllogisms

/// (singular, plural, with copula)
const TERMS: &[(&str, &str, &str)] = &[
    ("zorp", "zorplar", "zorptur"),
    ("blik", "blikler", "bliktir"),
    ("flem", "flemler", "flemdir"),
    ("tarp", "tarplar", "tarptır"),
    ("muv", "muvlar", "muvdur"),
    ("gesk", "geskler", "gesktir"),
    ("nüm", "nümler", "nümdür"),
    ("pirt", "pirtler", "pirttir"),
    ("dolk", "dolklar", "dolktur"),
];

#[derive(Clone, Copy, Debug, PartialEq)]
enum Q {
    All,
    No,
    Some,
    SomeNot,
}

type Stmt = (Q, usize, usize);

fn stmt_holds(s: Stmt, world: u32, n: usize) -> bool {
    let (q, x, y) = s;
    let regions = (1u32..(1 << n)).filter(|reg| world & (1 << reg) != 0);
    let has = |reg: u32, i: usize| reg & (1 << i) != 0;
    let mut regs = regions;
    match q {
        Q::All => regs.all(|g| !has(g, x) || has(g, y)),
        Q::No => regs.all(|g| !(has(g, x) && has(g, y))),
        Q::Some => regs.any(|g| has(g, x) && has(g, y)),
        Q::SomeNot => regs.any(|g| has(g, x) && !has(g, y)),
    }
}

/// Worlds = sets of non-empty Venn regions with every term non-empty, consistent with premises.
fn worlds(premises: &[Stmt], n: usize) -> Vec<u32> {
    let total = 1u32 << (1 << n);
    (0..total)
        .step_by(2) // region 0 (outside every set) is irrelevant
        .filter(|&w| (0..n).all(|t| (1u32..(1 << n)).any(|g| w & (1 << g) != 0 && g & (1 << t) != 0)))
        .filter(|&w| premises.iter().all(|&p| stmt_holds(p, w, n)))
        .collect()
}

fn valid(s: Stmt, ws: &[u32], n: usize) -> bool {
    !ws.is_empty() && ws.iter().all(|&w| stmt_holds(s, w, n))
}

fn stmt_text(s: Stmt, t: &[usize]) -> String {
    let (q, x, y) = s;
    let (a, b) = (TERMS[t[x]], TERMS[t[y]]);
    match q {
        Q::All => format!("Bütün {} {}.", a.1, b.2),
        Q::No => format!("Hiçbir {} {} değildir.", a.0, b.0),
        Q::Some => format!("Bazı {} {}.", a.1, b.2),
        Q::SomeNot => format!("Bazı {} {} değildir.", a.1, b.0),
    }
}

#[derive(Clone, Debug)]
pub struct SylSpec {
    n: usize,
    premises: Vec<Stmt>,
    opts: Vec<Stmt>,
}

fn syllogism(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    let n = if hard { 4 } else { 3 };
    let qs = [Q::All, Q::No, Q::Some, Q::SomeNot];
    let np = if hard { 3 } else { 2 };
    // Premises chain the terms: (0,1), (1,2), (2,3) in a random direction.
    let mut premises: Vec<Stmt> = vec![];
    for i in 0..np {
        let q = if hard { *r.pick(&qs) } else { *r.pick(&[Q::All, Q::All, Q::No, Q::Some]) };
        let (x, y) = if r.chance(0.7) || q == Q::SomeNot { (i, i + 1) } else { (i + 1, i) };
        premises.push((q, x, y));
    }
    let ws = worlds(&premises, n);
    if ws.is_empty() {
        return None;
    }
    // Candidate conclusions about the two ends of the chain (they need every premise).
    let (e0, e1) = (0, n - 1);
    let cands: Vec<Stmt> = qs.iter().flat_map(|&q| [(q, e0, e1), (q, e1, e0)]).collect();
    let valids: Vec<Stmt> = cands.iter().copied().filter(|&c| valid(c, &ws, n)).collect();
    if valids.is_empty() {
        return None;
    }
    let answer = *r.pick(&valids);
    // Distractors: not forced; prefer ones that are possible (true in some world).
    let mut poss: Vec<Stmt> = cands.iter().copied().filter(|&c| !valid(c, &ws, n) && ws.iter().any(|&w| stmt_holds(c, w, n))).collect();
    let mut imposs: Vec<Stmt> = cands.iter().copied().filter(|&c| !ws.iter().any(|&w| stmt_holds(c, w, n))).collect();
    r.shuffle(&mut poss);
    r.shuffle(&mut imposs);
    let mut ds: Vec<Stmt> = poss.into_iter().take(2).collect();
    ds.extend(imposs);
    // Fill from statements about other term pairs if needed.
    let mut extra: Vec<Stmt> = vec![];
    for &q in &qs {
        for x in 0..n {
            for y in 0..n {
                if x != y && !premises.contains(&(q, x, y)) && !valid((q, x, y), &ws, n) {
                    extra.push((q, x, y));
                }
            }
        }
    }
    r.shuffle(&mut extra);
    ds.extend(extra);
    let mut picked: Vec<Stmt> = vec![];
    for d in ds {
        if !picked.contains(&d) && d != answer {
            picked.push(d);
        }
        if picked.len() == 3 {
            break;
        }
    }
    let (opts, at) = place(r, answer, &picked);
    let mut pool: Vec<usize> = (0..TERMS.len()).collect();
    r.shuffle(&mut pool);
    let t = pool[..n].to_vec();
    let lines: Vec<String> = premises.iter().map(|&p| stmt_text(p, &t)).collect();
    let fig = json!({"layout": "clues", "lines": lines, "note": "Kelimeler uydurma; yalnızca verilenlere dayan."});
    let texts: Vec<String> = opts.iter().map(|&o| stmt_text(o, &t)).collect();
    let why = format!(
        "Öncülleri bir Venn şemasına yerleştir: “{}” her durumda doğru. Diğerleri bazı durumlarda doğru olabilir ama kesin değil.",
        stmt_text(answer, &t).trim_end_matches('.')
    );
    let item = text_item(ID, hard, "Buna göre hangisi kesinlikle doğrudur?", Some(fig), texts, at, why);
    Some((item, Spec::Syl(SylSpec { n, premises, opts })))
}

// ------------------------------------------------------------------------------- conditionals

/// (positive, negative, positive-if, negative-if)
const PROPS: &[(&str, &str, &str, &str)] = &[
    ("lamba yanıyor", "lamba yanmıyor", "lamba yanıyorsa", "lamba yanmıyorsa"),
    ("kapı açık", "kapı kapalı", "kapı açıksa", "kapı kapalıysa"),
    ("zil çalıyor", "zil çalmıyor", "zil çalıyorsa", "zil çalmıyorsa"),
    ("pencere açık", "pencere kapalı", "pencere açıksa", "pencere kapalıysa"),
    ("köpek havlıyor", "köpek havlamıyor", "köpek havlıyorsa", "köpek havlamıyorsa"),
    ("yağmur yağıyor", "yağmur yağmıyor", "yağmur yağıyorsa", "yağmur yağmıyorsa"),
    ("Ada evde", "Ada evde değil", "Ada evdeyse", "Ada evde değilse"),
    ("radyo açık", "radyo kapalı", "radyo açıksa", "radyo kapalıysa"),
    ("çay demlenmiş", "çay demlenmemiş", "çay demlenmişse", "çay demlenmemişse"),
    ("araba garajda", "araba garajda değil", "araba garajdaysa", "araba garajda değilse"),
];

/// A literal: (proposition index, positive?).
type Lit = (usize, bool);

#[derive(Clone, Copy, Debug, PartialEq)]
enum Fact {
    If(Lit, Lit),
    Or(Lit, Lit),
    Is(Lit),
}

fn lit_true(l: Lit, a: u32) -> bool {
    ((a >> l.0) & 1 == 1) == l.1
}

fn fact_true(f: Fact, a: u32) -> bool {
    match f {
        Fact::If(p, q) => !lit_true(p, a) || lit_true(q, a),
        Fact::Or(p, q) => lit_true(p, a) || lit_true(q, a),
        Fact::Is(p) => lit_true(p, a),
    }
}

#[derive(Clone, Debug)]
pub struct CondSpec {
    nprops: usize,
    facts: Vec<Fact>,
    /// None = "kesin bir şey söylenemez".
    opts: Vec<Option<Lit>>,
}

fn lit_text(l: Lit, names: &[usize]) -> String {
    let p = PROPS[names[l.0]];
    if l.1 { p.0.to_string() } else { p.1.to_string() }
}

fn lit_cond(l: Lit, names: &[usize]) -> String {
    let p = PROPS[names[l.0]];
    if l.1 { p.2.to_string() } else { p.3.to_string() }
}

fn fact_text(f: Fact, names: &[usize]) -> String {
    match f {
        Fact::If(p, q) => format!("{} {}.", cap(&lit_cond(p, names)), lit_text(q, names)),
        Fact::Or(p, q) => format!("Ya {} ya da {} (en az biri doğru).", lit_text(p, names), lit_text(q, names)),
        Fact::Is(p) => format!("{}.", cap(&lit_text(p, names))),
    }
}

fn forced(spec: &CondSpec, l: Lit) -> bool {
    let models: Vec<u32> = (0..(1u32 << spec.nprops)).filter(|&a| spec.facts.iter().all(|&f| fact_true(f, a))).collect();
    !models.is_empty() && models.iter().all(|&a| lit_true(l, a))
}

fn cond_correct(spec: &CondSpec) -> Vec<usize> {
    let lits: Vec<usize> = (0..spec.opts.len()).filter(|&i| spec.opts[i].is_some_and(|l| forced(spec, l))).collect();
    if lits.is_empty() {
        (0..spec.opts.len()).filter(|&i| spec.opts[i].is_none()).collect()
    } else {
        lits
    }
}

fn neg(l: Lit) -> Lit {
    (l.0, !l.1)
}

fn conditional(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    let mut pool: Vec<usize> = (0..PROPS.len()).collect();
    r.shuffle(&mut pool);
    let sgn = |r: &mut Rng| r.chance(0.7);
    let (nprops, facts, opts): (usize, Vec<Fact>, Vec<Option<Lit>>) = if !hard {
        let (p, q) = ((0, sgn(r)), (1, sgn(r)));
        match r.below(4) {
            // Modus ponens: P, so Q.
            0 => (2, vec![Fact::If(p, q), Fact::Is(p)], vec![Some(q), Some(neg(q)), Some(neg(p)), None]),
            // Modus tollens: not Q, so not P.
            1 => (2, vec![Fact::If(p, q), Fact::Is(neg(q))], vec![Some(neg(p)), Some(p), Some(q), None]),
            // Affirming the consequent: nothing follows.
            2 => (2, vec![Fact::If(p, q), Fact::Is(q)], vec![None, Some(p), Some(neg(p)), Some(neg(q))]),
            // Denying the antecedent: nothing follows.
            _ => (2, vec![Fact::If(p, q), Fact::Is(neg(p))], vec![None, Some(neg(q)), Some(q), Some(p)]),
        }
    } else {
        let (p, q, s) = ((0, sgn(r)), (1, sgn(r)), (2, sgn(r)));
        match r.below(4) {
            // Chain with contraposition: P→Q, Q→S, not S, so not P.
            0 => (3, vec![Fact::If(p, q), Fact::If(q, s), Fact::Is(neg(s))], vec![Some(neg(p)), Some(p), Some(q), Some(s), None]),
            // Disjunctive syllogism through a conditional: P or Q, P→S, not S, so Q.
            1 => (3, vec![Fact::Or(p, q), Fact::If(p, s), Fact::Is(neg(s))], vec![Some(q), Some(p), Some(s), Some(neg(q)), None]),
            // Chain forwards: P, P→Q, Q→S, so S.
            2 => (3, vec![Fact::Is(p), Fact::If(p, q), Fact::If(q, s)], vec![Some(s), Some(neg(s)), Some(neg(q)), Some(neg(p)), None]),
            // Trap: P→Q, S→Q, Q: nothing follows about P or S.
            _ => (3, vec![Fact::If(p, q), Fact::If(s, q), Fact::Is(q)], vec![None, Some(p), Some(s), Some(neg(p)), Some(neg(s))]),
        }
    };
    let names: Vec<usize> = pool[..nprops].to_vec();
    let spec = CondSpec { nprops, facts: facts.clone(), opts: opts.clone() };
    let correct = cond_correct(&spec);
    if correct.len() != 1 {
        return None;
    }
    let ans = opts[correct[0]];
    let others: Vec<Option<Lit>> = opts.iter().copied().filter(|o| *o != ans).collect();
    let (opts, at) = place(r, ans, &others);
    let nothing = "Kesin bir şey söylenemez.".to_string();
    let texts: Vec<String> = opts.iter().map(|o| o.map(|l| format!("{}.", cap(&lit_text(l, &names)))).unwrap_or_else(|| nothing.clone())).collect();
    let lines: Vec<String> = facts.iter().map(|&f| fact_text(f, &names)).collect();
    let fig = json!({"layout": "clues", "lines": lines});
    let why = match ans {
        Some(l) => format!("Verilenlerin hepsi doğruysa “{}” olmak zorunda: diğer durum bir öncülle çelişir.", lit_text(l, &names)),
        None => {
            // Which fallacy is the trap: a known antecedent that is false, or a true consequent?
            let denied = facts.iter().any(|&f| matches!(f, Fact::Is(l) if facts.iter().any(|&g| matches!(g, Fact::If(p, _) if p == neg(l)))));
            if denied {
                "“Eğer … ise” cümlesi yalnızca koşul gerçekleşince bir şey söyler. Koşul gerçekleşmedi diye sonucun tersi olmaz; eldeki bilgi hiçbir seçeneği kesinleştirmiyor.".to_string()
            } else {
                "Sonuç doğru diye neden de doğru olmaz: aynı sonucu başka bir şey de doğurabilir. Eldeki bilgi hiçbir seçeneği kesinleştirmiyor.".to_string()
            }
        }
    };
    let spec = CondSpec { nprops, facts, opts };
    let item = text_item(ID, hard, "Buna göre hangisi kesinlikle doğrudur?", Some(fig), texts, at, why);
    Some((item, Spec::Cond(spec)))
}

// ------------------------------------------------------------------------------- boxes and liars

#[derive(Clone, Copy, Debug, PartialEq)]
enum Sign {
    /// "The key is in box b" / "not in box b".
    In(usize, bool),
}

#[derive(Clone, Debug)]
pub struct BoxSpec {
    signs: Vec<Sign>,
    /// Exactly this many signs are true.
    true_count: usize,
}

fn box_models(s: &BoxSpec) -> Vec<usize> {
    (0..s.signs.len())
        .filter(|&key| s.signs.iter().filter(|&&Sign::In(b, yes)| (key == b) == yes).count() == s.true_count)
        .collect()
}

const BOX: [&str; 4] = ["A", "B", "C", "D"];
const BOX_LOC: [&str; 4] = ["A'da", "B'de", "C'de", "D'de"];

fn boxes(r: &mut Rng) -> Option<(IqItem, Spec)> {
    let n = 4;
    let one_true = r.chance(0.5);
    let true_count = if one_true { 1 } else { n - 1 };
    let signs: Vec<Sign> = (0..n).map(|_| Sign::In(r.below(n), r.chance(0.5))).collect();
    let spec = BoxSpec { signs: signs.clone(), true_count };
    let m = box_models(&spec);
    if m.len() != 1 {
        return None;
    }
    let key = m[0];
    let lines: Vec<String> = signs
        .iter()
        .enumerate()
        .map(|(i, &Sign::In(b, yes))| {
            let place_ = if b == i { "bu kutuda".to_string() } else { BOX_LOC[b].to_string() };
            format!("{} kutusu: “Anahtar {}{}.”", BOX[i], place_, if yes { "" } else { " değil" })
        })
        .collect();
    let fig = json!({"layout": "clues", "lines": lines});
    let rule = if one_true { "Yazılardan yalnızca biri doğru." } else { "Yazılardan yalnızca biri yanlış." };
    let why = format!(
        "Anahtarı sırayla her kutuya koyup doğru yazıları say: yalnızca {} kutusunda {} tutuyor.",
        BOX[key],
        if one_true { "tam bir doğru yazı" } else { "tam bir yanlış yazı" }
    );
    let texts: Vec<String> = BOX.iter().map(|b| format!("{b} kutusu")).collect();
    let item = text_item(ID, true, format!("Bir anahtar dört kutudan birinde. {rule} Anahtar hangi kutuda?"), Some(fig), texts, key, why);
    Some((item, Spec::Boxes(spec)))
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Claim {
    /// Speaker says "I did not do it".
    NotMe,
    /// "x did it" / "x did not do it".
    Did(usize, bool),
}

#[derive(Clone, Debug)]
pub struct LiarSpec {
    claims: Vec<Claim>,
    liars: usize,
}

fn claim_true(speaker: usize, c: Claim, culprit: usize) -> bool {
    match c {
        Claim::NotMe => culprit != speaker,
        Claim::Did(x, yes) => (culprit == x) == yes,
    }
}

fn liar_models(s: &LiarSpec) -> Vec<usize> {
    let n = s.claims.len();
    (0..n).filter(|&c| (0..n).filter(|&sp| !claim_true(sp, s.claims[sp], c)).count() == s.liars).collect()
}

fn liars(r: &mut Rng) -> Option<(IqItem, Spec)> {
    let n = 4;
    let mut pool: Vec<usize> = (0..NAMES.len()).collect();
    r.shuffle(&mut pool);
    let names: Vec<usize> = pool[..n].to_vec();
    let liars = if r.chance(0.6) { 1 } else { 3 };
    let claims: Vec<Claim> = (0..n)
        .map(|sp| {
            if r.chance(0.3) {
                Claim::NotMe
            } else {
                let mut x = r.below(n);
                while x == sp {
                    x = r.below(n);
                }
                Claim::Did(x, r.chance(0.5))
            }
        })
        .collect();
    let spec = LiarSpec { claims: claims.clone(), liars };
    let m = liar_models(&spec);
    if m.len() != 1 {
        return None;
    }
    let culprit = m[0];
    let nm = |i: usize| NAMES[names[i]].0;
    let lines: Vec<String> = claims
        .iter()
        .enumerate()
        .map(|(sp, &c)| match c {
            Claim::NotMe => format!("{}: “Ben kırmadım.”", nm(sp)),
            Claim::Did(x, true) => format!("{}: “{} kırdı.”", nm(sp), nm(x)),
            Claim::Did(x, false) => format!("{}: “{} kırmadı.”", nm(sp), nm(x)),
        })
        .collect();
    let fig = json!({"layout": "clues", "lines": lines});
    let rule = if liars == 1 { "Yalnızca biri yalan söylüyor." } else { "Yalnızca biri doğruyu söylüyor." };
    let why = format!("Her kişiyi sırayla suçlu kabul edip yalanları say: kurala yalnızca {} suçluyken uyuluyor.", nm(culprit));
    let texts: Vec<String> = (0..n).map(|i| nm(i).to_string()).collect();
    let item = text_item(ID, true, format!("Vazoyu dört kişiden biri kırdı. {rule} Vazoyu kim kırdı?"), Some(fig), texts, culprit, why);
    Some((item, Spec::Liar(spec)))
}

// ------------------------------------------------------------------------------- dispatch

#[derive(Clone, Debug)]
pub enum Spec {
    Seat(SeatSpec),
    Syl(SylSpec),
    Cond(CondSpec),
    Boxes(BoxSpec),
    Liar(LiarSpec),
}

fn pick_kind(r: &mut Rng, hard: bool) -> usize {
    if hard {
        r.below(7)
    } else {
        r.below(4)
    }
}

fn build(r: &mut Rng, hard: bool, kind: usize) -> Option<(IqItem, Spec)> {
    let mut out = if hard {
        match kind {
            0 | 1 => seat_puzzle(r, true, false),
            2 => syllogism(r, true),
            3 => conditional(r, true),
            4 => boxes(r),
            5 => liars(r),
            _ => seat_puzzle(r, true, true),
        }
    } else {
        match kind {
            0 => seat_puzzle(r, false, true),
            1 => seat_puzzle(r, false, false),
            2 => syllogism(r, false),
            _ => conditional(r, false),
        }
    }?;
    out.0.hard = hard;
    Some(out)
}

fn verify(item: &IqItem, s: &Spec) -> Result<(), String> {
    basic_checks(item)?;
    let correct: Vec<usize> = match s {
        Spec::Seat(sp) => {
            let ans = seat_answer_set(sp);
            (0..sp.opts.len()).filter(|&i| ans.contains(&sp.opts[i])).collect()
        }
        Spec::Syl(sp) => {
            let ws = worlds(&sp.premises, sp.n);
            (0..sp.opts.len()).filter(|&i| valid(sp.opts[i], &ws, sp.n)).collect()
        }
        Spec::Cond(sp) => cond_correct(sp),
        Spec::Boxes(sp) => box_models(sp),
        Spec::Liar(sp) => liar_models(sp),
    };
    if correct != vec![item.answer] {
        return Err(format!("correct options {correct:?}, answer {}", item.answer));
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
    fn iq_logic_doc_examples() {
        // All A are B, no B is C: "no A is C" is forced, "some B are not A" is only possible.
        let prem = vec![(Q::All, 0, 1), (Q::No, 1, 2)];
        let ws = worlds(&prem, 3);
        assert!(valid((Q::No, 0, 2), &ws, 3));
        assert!(!valid((Q::SomeNot, 1, 0), &ws, 3));
        // Boxes A..E: C at 5, B right of D, A next to C, E left of A, D and E not neighbours: D B E A C.
        let (a, b, c, d, e) = (0, 1, 2, 3, 4);
        let clues = vec![Clue::At(c, 4), Clue::RightOf(b, d), Clue::Next(a, c), Clue::LeftSome(e, a), Clue::NotNext(d, e)];
        let ms = models(&clues, 5);
        assert_eq!(ms.len(), 1);
        assert_eq!(ms[0][d], 0);
        // Key puzzle from the doc: exactly one of "in A", "not in B", "not in A" is true: B.
        let s = BoxSpec { signs: vec![Sign::In(0, true), Sign::In(1, false), Sign::In(0, false)], true_count: 1 };
        assert_eq!(box_models(&s), vec![1]);
    }
}
