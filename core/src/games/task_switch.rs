//! Görev Değiştirme — cued task switching (Rogers & Monsell 1995; Meiran 1996; Monsell 2003).
//!
//! Every trial shows a digit (1–9 without 5), or a digit + letter pair once a letter rule is in
//! play. A rule says how to classify it with the two big buttons (left / right):
//! - `parity`    "Tek mi, çift mi?"           left = Tek,         right = Çift
//! - `magnitude` "5'ten küçük mü, büyük mü?"  left = Küçük (<5),  right = Büyük (>5)
//! - `vowel`     "Sesli mi, sessiz mi?"       left = Sesli,       right = Sessiz
//! - `case`      "Harf küçük mü, büyük mü?"   left = küçük harf,  right = BÜYÜK HARF
//!
//! Which rule applies is told by a cue:
//! - `zone`: the stimulus appears in the zone of its rule (2 rules = top/bottom, 3 = three bands,
//!   4 = 2×2 quadrants). The zone lights up `cti_ms` before the target (cue–target interval).
//!   On "hidden label" levels the zone names are shown on the intro card only.
//! - `color`: the stimulus frame in the centre takes the rule's colour `cti_ms` before the target.
//! - `none`: alternating runs without any cue — rules come in a fixed order, two trials each
//!   (AABB, AABBCC, AABBCCDD); you have to keep track yourself. After an error the feedback names
//!   the rule that applied so you can resync. `cti_ms` is then a blank preparation interval.
//!
//! Trial timeline: cue (`cti_ms`) → target (until answer or `deadline_ms`; a timeout is an error)
//! → feedback (`fb_ms`) → next cue. A tap is timed by the core clock (sum of ticks since target
//! onset), so reaction times are frame-exact. Answers outside the target stage are rejected.
//!
//! Level = 32 trials. Cued levels have exactly 50% switch trials (runs never longer than 4).
//! Digits and letters never repeat on consecutive trials (no stimulus-repetition priming).
//!
//! Switch cost = mean RT of correct switch trials − mean RT of correct repeat trials, both
//! excluding the first trial and trials right after an error (standard practice). It needs at least
//! 3 trials of each kind, otherwise it is unknown (`null`).
//!
//! Stars: accuracy ≥ 90% and switch cost ≤ 200 ms (≤ 250 ms on cue-free levels, unknown counts as
//! fine) → 3; accuracy ≥ 82% → 2; ≥ 75% → 1; below 75% → `lost`.
//!
//! Level curve (`params(level)`):
//! - 1..=10 hand-made: P+M zone (CTI 700), P+M zone (450), P+V zone, P+M colour, M+V zone,
//!   P+M cue-free, P+M+V zone (bands), P+M+V colour, P+V cue-free, all four rules zone (quadrants).
//! - 11..=500: a 4-level cycle — zone, colour, cue-free, zone with hidden labels (labels stay on
//!   before level 60). With t = (level − 11) / 489: 2 rules for t < 0.2, 3 for t < 0.55, then 4
//!   (rule sets rotate); CTI 450 → 100 ms; cue-free preparation 500 → 200 ms; deadline 2800 →
//!   1600 ms; feedback 350 → 250 ms.
//!
//! Endless ("Sprint (60 sn)"): 60 s of play, the clock runs from the end of the countdown. Every
//! 8 correct answers move up one stage (P+M zone 450 → P+M colour 350 → P+M+V zone 350 → P+M+V
//! colour 250 → four rules zone 250 → four rules colour 150 → four rules colour 100 ms).
//! `score` = correct − errors (never below 0); time up → `lost` (the normal end of a sprint).
//!
//! State: `{status, stars, mode, phase: "intro"|"countdown"|"run"|"done", title, goal, summary?,
//!          score?, rules: [{key, question, left, right}], cue: "zone"|"color"|"none", labels,
//!          run_len, trial, trials|null, stage: "cue"|"target"|"feedback"|null, active_rule|null,
//!          target: {digit, letter|null, letter_first}|null, t_ms, cti_ms, deadline_ms, fb_ms,
//!          countdown_ms, correct, errors, timeouts, accuracy, rt_repeat_ms, rt_switch_ms,
//!          switch_cost_ms, remaining_ms|null, sprint_stage|null,
//!          last: {serial, correct, timeout, rule, expected, given|null, rt_ms|null, switch}|null}`
//! (`active_rule` = index into `rules`; it is `null` on cue-free levels while a trial runs.)
//! Actions: `{"start":true}` · `{"answer":"left"|"right"}`

use crate::rng::{seed_for, time_seed, Rng};
use crate::Session;
use serde_json::{json, Value};

pub const PARITY: usize = 0;
pub const MAGNITUDE: usize = 1;
pub const VOWEL: usize = 2;
pub const CASE: usize = 3;

pub struct RuleDef {
    pub key: &'static str,
    pub question: &'static str,
    pub left: &'static str,
    pub right: &'static str,
}

pub const RULES: [RuleDef; 4] = [
    RuleDef { key: "parity", question: "Tek mi, çift mi?", left: "Tek", right: "Çift" },
    RuleDef { key: "magnitude", question: "5'ten küçük mü, büyük mü?", left: "Küçük", right: "Büyük" },
    RuleDef { key: "vowel", question: "Sesli mi, sessiz mi?", left: "Sesli", right: "Sessiz" },
    RuleDef { key: "case", question: "Harf küçük mü, büyük mü?", left: "küçük harf", right: "BÜYÜK HARF" },
];

pub const TRIALS: usize = 32;
pub const COUNTDOWN_MS: f64 = 3000.0;
pub const SPRINT_MS: f64 = 60_000.0;
const SPRINT_STEP: u32 = 8;
const DIGITS: [u8; 8] = [1, 2, 3, 4, 6, 7, 8, 9];

/// (upper, lower) letter forms. With the case rule only letters whose two forms differ in shape
/// are used (no c/C, o/O, s/S…), and no l/I look-alikes.
const VOWELS: [(&str, &str); 8] =
    [("A", "a"), ("E", "e"), ("I", "ı"), ("İ", "i"), ("O", "o"), ("Ö", "ö"), ("U", "u"), ("Ü", "ü")];
const CONSONANTS: [(&str, &str); 20] = [
    ("B", "b"), ("C", "c"), ("Ç", "ç"), ("D", "d"), ("F", "f"), ("G", "g"), ("H", "h"), ("K", "k"),
    ("L", "l"), ("M", "m"), ("N", "n"), ("P", "p"), ("R", "r"), ("S", "s"), ("Ş", "ş"), ("T", "t"),
    ("V", "v"), ("Y", "y"), ("Z", "z"), ("J", "j"),
];
const CASE_VOWELS: [(&str, &str); 4] = [("A", "a"), ("E", "e"), ("I", "ı"), ("İ", "i")];
const CASE_CONSONANTS: [(&str, &str); 11] = [
    ("B", "b"), ("D", "d"), ("F", "f"), ("G", "g"), ("H", "h"), ("K", "k"), ("M", "m"), ("N", "n"),
    ("R", "r"), ("T", "t"), ("Y", "y"),
];

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Cue {
    Zone,
    Color,
    None,
}

impl Cue {
    fn key(self) -> &'static str {
        match self {
            Cue::Zone => "zone",
            Cue::Color => "color",
            Cue::None => "none",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Params {
    /// Global rule ids, in zone order.
    pub rules: Vec<usize>,
    pub cue: Cue,
    /// Zone names visible during the run.
    pub labels: bool,
    pub cti_ms: f64,
    pub deadline_ms: f64,
    pub fb_ms: f64,
    /// Max switch cost for 3 stars.
    pub cost_ms: f64,
}

fn mk(rules: &[usize], cue: Cue, cti: f64, deadline: f64) -> Params {
    Params {
        rules: rules.to_vec(),
        cue,
        labels: true,
        cti_ms: cti,
        deadline_ms: deadline,
        fb_ms: 350.0,
        cost_ms: if cue == Cue::None { 250.0 } else { 200.0 },
    }
}

/// Level → parameters. See the module docs for the curve.
pub fn params(level: u32) -> Params {
    const P: usize = PARITY;
    const M: usize = MAGNITUDE;
    const V: usize = VOWEL;
    const C: usize = CASE;
    let level = level.clamp(1, crate::MAX_LEVEL);
    match level {
        1 => mk(&[P, M], Cue::Zone, 700.0, 3000.0),
        2 => mk(&[P, M], Cue::Zone, 450.0, 2800.0),
        3 => mk(&[P, V], Cue::Zone, 600.0, 3000.0),
        4 => mk(&[P, M], Cue::Color, 500.0, 2800.0),
        5 => mk(&[M, V], Cue::Zone, 400.0, 2800.0),
        6 => mk(&[P, M], Cue::None, 500.0, 2800.0),
        7 => mk(&[P, M, V], Cue::Zone, 600.0, 3000.0),
        8 => mk(&[P, M, V], Cue::Color, 500.0, 2800.0),
        9 => mk(&[P, V], Cue::None, 500.0, 2800.0),
        10 => mk(&[P, M, V, C], Cue::Zone, 600.0, 3000.0),
        _ => {
            let i = level - 11;
            let t = i as f64 / 489.0;
            let set = (i / 4) as usize;
            let rules: Vec<usize> = if t < 0.2 {
                let pairs = [[P, M], [P, V], [M, V], [M, C], [P, C], [V, C]];
                pairs[set % pairs.len()].to_vec()
            } else if t < 0.55 {
                let triples = [[P, M, V], [P, V, C], [M, V, C], [P, M, C]];
                triples[set % triples.len()].to_vec()
            } else {
                let quads = [[P, M, V, C], [V, P, C, M], [M, C, P, V]];
                quads[set % quads.len()].to_vec()
            };
            let (cue, labels) = match i % 4 {
                0 => (Cue::Zone, true),
                1 => (Cue::Color, true),
                2 => (Cue::None, true),
                _ => (Cue::Zone, level < 60),
            };
            let cti = if cue == Cue::None { 500.0 - 300.0 * t } else { 450.0 - 350.0 * t };
            let mut p = mk(&rules, cue, cti.round(), (2800.0 - 1200.0 * t).round());
            p.labels = labels;
            p.fb_ms = (350.0 - 100.0 * t).round();
            p
        }
    }
}

/// Sprint stage (0..=6) → parameters.
pub fn sprint_params(stage: u32) -> Params {
    const P: usize = PARITY;
    const M: usize = MAGNITUDE;
    const V: usize = VOWEL;
    const C: usize = CASE;
    let mut p = match stage {
        0 => mk(&[P, M], Cue::Zone, 450.0, 2500.0),
        1 => mk(&[P, M], Cue::Color, 350.0, 2400.0),
        2 => mk(&[P, M, V], Cue::Zone, 350.0, 2300.0),
        3 => mk(&[P, M, V], Cue::Color, 250.0, 2200.0),
        4 => mk(&[P, M, V, C], Cue::Zone, 250.0, 2100.0),
        5 => mk(&[P, M, V, C], Cue::Color, 150.0, 2000.0),
        _ => mk(&[P, M, V, C], Cue::Color, 100.0, 1800.0),
    };
    p.fb_ms = 250.0;
    p
}

#[derive(Clone, Debug, PartialEq)]
pub struct Stim {
    pub digit: u8,
    /// Letter as shown (upper or lower case form).
    pub letter: Option<String>,
    pub vowel: bool,
    pub lower: bool,
    pub letter_first: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Trial {
    /// Global rule id.
    pub rule: usize,
    pub stim: Stim,
}

/// Correct side for a rule: `false` = left, `true` = right.
pub fn expected_right(rule: usize, s: &Stim) -> bool {
    match rule {
        PARITY => s.digit % 2 == 0,
        MAGNITUDE => s.digit > 5,
        VOWEL => !s.vowel,
        _ => !s.lower,
    }
}

fn gen_stim(r: &mut Rng, rules: &[usize], prev: Option<&Stim>) -> Stim {
    let has_letter = rules.iter().any(|&x| x == VOWEL || x == CASE);
    let has_case = rules.contains(&CASE);
    let digit = loop {
        let d = *r.pick(&DIGITS);
        if prev.map(|p| p.digit) != Some(d) {
            break d;
        }
    };
    if !has_letter {
        return Stim { digit, letter: None, vowel: false, lower: false, letter_first: false };
    }
    let vowel = r.chance(0.5);
    let lower = has_case && r.chance(0.5);
    let pool: &[(&str, &str)] = match (has_case, vowel) {
        (true, true) => &CASE_VOWELS,
        (true, false) => &CASE_CONSONANTS,
        (false, true) => &VOWELS,
        (false, false) => &CONSONANTS,
    };
    let prev_upper = prev.and_then(|p| p.letter.clone()).map(|l| tr_upper(&l));
    let (up, lo) = loop {
        let c = *r.pick(pool);
        if prev_upper.as_deref() != Some(c.0) {
            break c;
        }
    };
    Stim {
        digit,
        letter: Some(if lower { lo } else { up }.to_string()),
        vowel,
        lower,
        letter_first: r.chance(0.5),
    }
}

fn tr_upper(s: &str) -> String {
    for (u, l) in VOWELS.iter().chain(CONSONANTS.iter()) {
        if *l == s || *u == s {
            return u.to_string();
        }
    }
    s.to_string()
}

/// Cued sequence: n/2 switches (16 of 31 transitions for 32 trials), runs of 1..=4. Built from
/// run lengths: n/2 + 1 runs start at length 1, the remaining trials are dealt out at random to runs
/// shorter than 4.
fn gen_cued_rules(r: &mut Rng, rules: &[usize], n: usize) -> Vec<usize> {
    let runs = n / 2 + 1;
    let mut len = vec![1usize; runs];
    for _ in 0..n.saturating_sub(runs) {
        let open: Vec<usize> = (0..runs).filter(|&i| len[i] < 4).collect();
        len[*r.pick(&open)] += 1;
    }
    let mut out = Vec::with_capacity(n);
    let mut rule = *r.pick(rules);
    for (k, &l) in len.iter().enumerate() {
        if k > 0 {
            rule = other_rule(r, rules, rule);
        }
        out.extend(std::iter::repeat(rule).take(l));
    }
    out.truncate(n);
    out
}

fn other_rule(r: &mut Rng, rules: &[usize], prev: usize) -> usize {
    let others: Vec<usize> = rules.iter().copied().filter(|&x| x != prev).collect();
    if others.is_empty() {
        prev
    } else {
        *r.pick(&others)
    }
}

pub fn gen_trials(r: &mut Rng, p: &Params, n: usize) -> Vec<Trial> {
    let rules = if p.cue == Cue::None {
        let start = r.below(p.rules.len());
        (0..n).map(|k| p.rules[(start + k / 2) % p.rules.len()]).collect()
    } else {
        gen_cued_rules(r, &p.rules, n)
    };
    let mut out: Vec<Trial> = Vec::with_capacity(n);
    for rule in rules {
        let stim = gen_stim(r, &p.rules, out.last().map(|t| &t.stim));
        out.push(Trial { rule, stim });
    }
    out
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Phase {
    Intro,
    Countdown,
    Run,
    Done,
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Stage {
    Cue,
    Target,
    Feedback,
}

#[derive(Clone, Debug)]
struct Last {
    serial: u32,
    correct: bool,
    timeout: bool,
    rule: usize,
    expected_right: bool,
    given_right: Option<bool>,
    rt_ms: Option<f64>,
    switch: bool,
}

pub struct TaskSwitch {
    endless: bool,
    p: Params,
    rng: Rng,
    trials: Vec<Trial>,
    phase: Phase,
    stage: Stage,
    countdown_ms: f64,
    idx: usize,
    t_ms: f64,
    correct: u32,
    errors: u32,
    timeouts: u32,
    rt_repeat: Vec<f64>,
    rt_switch: Vec<f64>,
    rt_all: Vec<f64>,
    prev_error: bool,
    last: Option<Last>,
    serial: u32,
    remaining_ms: f64,
    sprint_stage: u32,
    stars: u32,
    won: bool,
}

pub fn create(level: u32, mode: &str) -> Result<Box<dyn Session>, String> {
    Ok(Box::new(if mode == "endless" { TaskSwitch::sprint(time_seed()) } else { TaskSwitch::level(level) }))
}

fn mean(v: &[f64]) -> Option<f64> {
    (!v.is_empty()).then(|| v.iter().sum::<f64>() / v.len() as f64)
}

pub fn stars_for(acc: f64, cost: Option<f64>, cost_limit: f64) -> u32 {
    let cost_ok = cost.map_or(true, |c| c <= cost_limit + 1e-9);
    if acc >= 0.9 - 1e-9 && cost_ok {
        3
    } else if acc >= 0.82 - 1e-9 {
        2
    } else if acc >= 0.75 - 1e-9 {
        1
    } else {
        0
    }
}

impl TaskSwitch {
    pub fn level(level: u32) -> Self {
        let p = params(level);
        let mut rng = Rng::new(seed_for("task_switch", level, 0));
        let trials = gen_trials(&mut rng, &p, TRIALS);
        TaskSwitch::with(p, rng, trials, false)
    }

    pub fn sprint(seed: u64) -> Self {
        let p = sprint_params(0);
        let mut rng = Rng::new(seed);
        let trials = gen_trials(&mut rng, &p, 1);
        TaskSwitch::with(p, rng, trials, true)
    }

    fn with(p: Params, rng: Rng, trials: Vec<Trial>, endless: bool) -> Self {
        TaskSwitch {
            endless,
            p,
            rng,
            trials,
            phase: Phase::Intro,
            stage: Stage::Cue,
            countdown_ms: COUNTDOWN_MS,
            idx: 0,
            t_ms: 0.0,
            correct: 0,
            errors: 0,
            timeouts: 0,
            rt_repeat: vec![],
            rt_switch: vec![],
            rt_all: vec![],
            prev_error: false,
            last: None,
            serial: 0,
            remaining_ms: SPRINT_MS,
            sprint_stage: 0,
            stars: 0,
            won: false,
        }
    }

    fn total(&self) -> u32 {
        self.correct + self.errors
    }

    fn accuracy(&self) -> f64 {
        if self.total() == 0 {
            1.0
        } else {
            self.correct as f64 / self.total() as f64
        }
    }

    /// Switch cost needs ≥ 3 clean trials of each kind.
    pub fn switch_cost(&self) -> Option<f64> {
        if self.rt_switch.len() < 3 || self.rt_repeat.len() < 3 {
            return None;
        }
        Some(mean(&self.rt_switch)? - mean(&self.rt_repeat)?)
    }

    fn is_switch(&self, i: usize) -> bool {
        i > 0 && self.trials[i].rule != self.trials[i - 1].rule
    }

    fn score(&self) -> i64 {
        (self.correct as i64 - self.errors as i64).max(0)
    }

    /// Resolve the current trial (answer or timeout) and move to feedback.
    fn resolve(&mut self, given_right: Option<bool>, rt: f64) {
        let tr = &self.trials[self.idx];
        let exp = expected_right(tr.rule, &tr.stim);
        let correct = given_right == Some(exp);
        let switch = self.is_switch(self.idx);
        if correct {
            self.correct += 1;
            self.rt_all.push(rt);
            if self.idx > 0 && !self.prev_error {
                if switch {
                    self.rt_switch.push(rt);
                } else {
                    self.rt_repeat.push(rt);
                }
            }
        } else {
            self.errors += 1;
            if given_right.is_none() {
                self.timeouts += 1;
            }
        }
        self.prev_error = !correct;
        self.serial += 1;
        self.last = Some(Last {
            serial: self.serial,
            correct,
            timeout: given_right.is_none(),
            rule: tr.rule,
            expected_right: exp,
            given_right,
            rt_ms: given_right.map(|_| rt),
            switch,
        });
        self.stage = Stage::Feedback;
        if self.endless && correct {
            let st = (self.correct / SPRINT_STEP).min(6);
            if st != self.sprint_stage {
                self.sprint_stage = st;
                self.p = sprint_params(st);
            }
        }
    }

    fn next_trial(&mut self) {
        self.idx += 1;
        if self.endless {
            let prev = self.trials.last().unwrap().clone();
            let rule = if !self.p.rules.contains(&prev.rule) {
                *self.rng.pick(&self.p.rules)
            } else {
                // Run length so far (cap 4), then switch with p = 0.5.
                let run = self.trials.iter().rev().take_while(|t| t.rule == prev.rule).count();
                if run >= 4 || self.rng.chance(0.5) {
                    other_rule(&mut self.rng, &self.p.rules.clone(), prev.rule)
                } else {
                    prev.rule
                }
            };
            let stim = gen_stim(&mut self.rng, &self.p.rules.clone(), Some(&prev.stim));
            self.trials.push(Trial { rule, stim });
        } else if self.idx >= self.trials.len() {
            self.finish();
            return;
        }
        self.stage = Stage::Cue;
    }

    fn finish(&mut self) {
        self.phase = Phase::Done;
        if !self.endless {
            self.stars = stars_for(self.accuracy(), self.switch_cost(), self.p.cost_ms);
            self.won = self.stars > 0;
        }
    }

    fn status(&self) -> &'static str {
        match self.phase {
            Phase::Done if self.endless || !self.won => "lost",
            Phase::Done => "won",
            _ => "playing",
        }
    }

    fn summary(&self) -> String {
        let cost = match self.switch_cost() {
            Some(c) => format!("Geçiş maliyeti {} ms", c.round() as i64),
            None => "Geçiş maliyeti –".to_string(),
        };
        let rt = mean(&self.rt_all).map_or("–".to_string(), |m| format!("{} ms", m.round() as i64));
        if self.endless {
            format!("Doğru {} · Hata {} · Ort. tepki {rt} · {cost}", self.correct, self.errors)
        } else {
            format!(
                "Doğru {}/{} (%{}) · Ort. tepki {rt} · {cost}",
                self.correct,
                self.trials.len(),
                (self.accuracy() * 100.0).round()
            )
        }
    }

    fn title(&self) -> String {
        if self.endless {
            return "Sprint".into();
        }
        let cue = match (self.p.cue, self.p.labels) {
            (Cue::Zone, true) => "bölge",
            (Cue::Zone, false) => "gizli bölge",
            (Cue::Color, _) => "renk",
            (Cue::None, _) => "ipuçsuz",
        };
        format!("{} kural · {cue}", self.p.rules.len())
    }

    fn pattern(&self) -> String {
        ["AA", "BB", "CC", "DD"][..self.p.rules.len()].concat()
    }

    fn goal(&self) -> String {
        if self.endless {
            return "60 saniye · puan = doğru − hata · her 8 doğruda zorlaşır".into();
        }
        match self.p.cue {
            Cue::Zone => format!("Çıktığı bölge kuralı söyler · {} deneme", self.trials.len()),
            Cue::Color => format!("Çerçevenin rengi kuralı söyler · {} deneme", self.trials.len()),
            Cue::None => format!("İpucu yok: kurallar ikişer sırayla ({}) · {} deneme", self.pattern(), self.trials.len()),
        }
    }

    fn rule_index(&self, rule: usize) -> Option<usize> {
        self.p.rules.iter().position(|&r| r == rule)
    }
}

fn side(right: bool) -> &'static str {
    if right {
        "right"
    } else {
        "left"
    }
}

impl Session for TaskSwitch {
    fn state(&self) -> Value {
        let run = self.phase == Phase::Run;
        let cur = (run && self.idx < self.trials.len()).then(|| &self.trials[self.idx]);
        let active_rule = cur.and_then(|t| {
            if self.p.cue == Cue::None && self.stage != Stage::Feedback {
                None
            } else if self.stage == Stage::Feedback {
                self.last.as_ref().and_then(|l| self.rule_index(l.rule))
            } else {
                self.rule_index(t.rule)
            }
        });
        let target = cur.filter(|_| self.stage == Stage::Target).map(|t| {
            json!({"digit": t.stim.digit, "letter": t.stim.letter, "letter_first": t.stim.letter_first})
        });
        let done = self.phase == Phase::Done;
        let r1 = |x: Option<f64>| x.map(|v| v.round() as i64);
        let last = self.last.as_ref().map(|l| {
            json!({
                "serial": l.serial, "correct": l.correct, "timeout": l.timeout,
                "rule": self.rule_index(l.rule), "rule_key": RULES[l.rule].key,
                "expected": side(l.expected_right), "given": l.given_right.map(side),
                "rt_ms": r1(l.rt_ms), "switch": l.switch,
            })
        });
        let rules: Vec<Value> = self
            .p
            .rules
            .iter()
            .map(|&r| json!({"key": RULES[r].key, "question": RULES[r].question, "left": RULES[r].left, "right": RULES[r].right}))
            .collect();
        json!({
            "status": self.status(),
            "stars": self.stars,
            "mode": if self.endless { "endless" } else { "level" },
            "phase": match self.phase {
                Phase::Intro => "intro", Phase::Countdown => "countdown", Phase::Run => "run", Phase::Done => "done",
            },
            "title": self.title(),
            "goal": self.goal(),
            "summary": done.then(|| self.summary()),
            "score": if self.endless { Some(self.score()) } else { None },
            "rules": rules,
            "cue": self.p.cue.key(),
            "labels": self.p.labels,
            "run_len": 2,
            "pattern": self.pattern(),
            "trial": self.idx.min(self.trials.len().saturating_sub(1)),
            "trials": if self.endless { None } else { Some(self.trials.len()) },
            "stage": run.then(|| match self.stage { Stage::Cue => "cue", Stage::Target => "target", Stage::Feedback => "feedback" }),
            "active_rule": active_rule,
            "target": target,
            "t_ms": self.t_ms.round(),
            "cti_ms": self.p.cti_ms,
            "deadline_ms": self.p.deadline_ms,
            "fb_ms": self.p.fb_ms,
            "countdown_ms": self.countdown_ms.max(0.0).round(),
            "correct": self.correct,
            "errors": self.errors,
            "timeouts": self.timeouts,
            "accuracy": (self.accuracy() * 1000.0).round() / 1000.0,
            "rt_repeat_ms": r1(mean(&self.rt_repeat)),
            "rt_switch_ms": r1(mean(&self.rt_switch)),
            "switch_cost_ms": r1(self.switch_cost()),
            "remaining_ms": if self.endless { Some(self.remaining_ms.max(0.0).round()) } else { None },
            "sprint_stage": if self.endless { Some(self.sprint_stage + 1) } else { None },
            "last": last,
        })
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if self.phase == Phase::Done {
            return Err(if self.endless { "Süre doldu" } else { "Bölüm bitti" }.into());
        }
        if a["start"].as_bool() == Some(true) {
            if self.phase != Phase::Intro {
                return Err("Zaten başladı".into());
            }
            self.phase = Phase::Countdown;
            self.countdown_ms = COUNTDOWN_MS;
            return Ok(());
        }
        let right = match a["answer"].as_str() {
            Some("left") => false,
            Some("right") => true,
            _ => return Err("Bilinmeyen hamle".into()),
        };
        if self.phase != Phase::Run {
            return Err("Henüz başlamadı".into());
        }
        if self.stage != Stage::Target {
            return Err("Hedefi bekle".into());
        }
        let rt = self.t_ms;
        self.resolve(Some(right), rt);
        self.t_ms = 0.0;
        Ok(())
    }

    fn tick(&mut self, dt_ms: f64) {
        if !(dt_ms > 0.0) {
            return;
        }
        match self.phase {
            Phase::Countdown => {
                self.countdown_ms -= dt_ms;
                if self.countdown_ms <= 0.0 {
                    self.phase = Phase::Run;
                    self.stage = Stage::Cue;
                    self.t_ms = -self.countdown_ms;
                    self.countdown_ms = 0.0;
                }
            }
            Phase::Run => {
                if self.endless {
                    self.remaining_ms -= dt_ms;
                    if self.remaining_ms <= 0.0 {
                        self.remaining_ms = 0.0;
                        self.finish();
                        return;
                    }
                }
                self.t_ms += dt_ms;
                loop {
                    if self.phase != Phase::Run {
                        break;
                    }
                    match self.stage {
                        Stage::Cue if self.t_ms >= self.p.cti_ms => {
                            self.t_ms -= self.p.cti_ms;
                            self.stage = Stage::Target;
                        }
                        Stage::Target if self.t_ms >= self.p.deadline_ms => {
                            self.t_ms -= self.p.deadline_ms;
                            let dl = self.p.deadline_ms;
                            self.resolve(None, dl);
                        }
                        Stage::Feedback if self.t_ms >= self.p.fb_ms => {
                            self.t_ms -= self.p.fb_ms;
                            self.next_trial();
                        }
                        _ => break,
                    }
                }
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LEVELS: [u32; 9] = [1, 2, 3, 50, 137, 250, 400, 499, 500];

    #[test]
    fn params_cover_levels() {
        for level in LEVELS.iter().copied().chain(1..=20) {
            let p = params(level);
            assert!((2..=4).contains(&p.rules.len()), "level {level}");
            assert!(p.cti_ms >= 100.0 && p.cti_ms <= 700.0);
            assert!(p.deadline_ms >= 1600.0 && p.deadline_ms <= 3000.0);
            let mut r = p.rules.clone();
            r.sort();
            r.dedup();
            assert_eq!(r.len(), p.rules.len());
        }
        assert_eq!(params(1).rules, vec![PARITY, MAGNITUDE]);
        assert_eq!(params(1).cue, Cue::Zone);
        assert_eq!(params(500).rules.len(), 4);
        assert!(params(500).cti_ms <= 101.0);
        assert!(params(499).deadline_ms <= 1610.0);
        assert!((11..=500).any(|l| params(l).cue == Cue::None && params(l).rules.len() == 4));
        assert!((11..=500).any(|l| !params(l).labels));
    }

    #[test]
    fn trials_generate_with_balanced_switches() {
        for level in LEVELS.iter().copied().chain(1..=20) {
            let g = TaskSwitch::level(level);
            assert_eq!(g.trials.len(), TRIALS);
            let p = &g.p;
            let has_letter = p.rules.contains(&VOWEL) || p.rules.contains(&CASE);
            for (i, t) in g.trials.iter().enumerate() {
                assert!(p.rules.contains(&t.rule));
                assert!(DIGITS.contains(&t.stim.digit));
                assert_eq!(t.stim.letter.is_some(), has_letter);
                if i > 0 {
                    assert_ne!(t.stim.digit, g.trials[i - 1].stim.digit, "digit repeat at {i}");
                }
            }
            let switches = (1..TRIALS).filter(|&i| g.is_switch(i)).count();
            if p.cue == Cue::None {
                // AABB…: every second transition switches.
                assert_eq!(switches, (TRIALS - 1) / 2 + if TRIALS % 2 == 0 { 0 } else { 1 }, "level {level}");
                for k in 0..TRIALS {
                    assert_eq!(g.trials[k].rule, g.trials[k - k % 2].rule);
                }
            } else {
                assert_eq!(switches, 16, "level {level}");
                let mut run = 1;
                for i in 1..TRIALS {
                    run = if g.is_switch(i) { 1 } else { run + 1 };
                    assert!(run <= 4, "level {level}: run of {run}");
                }
            }
        }
    }

    #[test]
    fn many_sequences_respect_constraints() {
        let mut r = Rng::new(9);
        for _ in 0..300 {
            for rules in [vec![0, 1], vec![0, 1, 2], vec![0, 1, 2, 3]] {
                let seq = gen_cued_rules(&mut r, &rules, TRIALS);
                let sw = (1..TRIALS).filter(|&i| seq[i] != seq[i - 1]).count();
                assert_eq!(sw, 16);
                let mut run = 1;
                for i in 1..TRIALS {
                    run = if seq[i] != seq[i - 1] { 1 } else { run + 1 };
                    assert!(run <= 4);
                }
            }
        }
    }

    #[test]
    fn deterministic() {
        for level in LEVELS {
            assert_eq!(TaskSwitch::level(level).trials, TaskSwitch::level(level).trials);
        }
    }

    #[test]
    fn expected_answers() {
        let s = Stim { digit: 7, letter: Some("e".into()), vowel: true, lower: true, letter_first: false };
        assert!(!expected_right(PARITY, &s)); // odd → left
        assert!(expected_right(MAGNITUDE, &s)); // > 5 → right
        assert!(!expected_right(VOWEL, &s)); // vowel → left
        assert!(!expected_right(CASE, &s)); // lower → left
    }

    /// Plays a whole run. `choose(game, is_switch)` → Some((answer_right, rt_ms)) or None (timeout).
    fn play(g: &mut TaskSwitch, mut choose: impl FnMut(&TaskSwitch, bool) -> Option<(bool, f64)>) {
        g.act(&json!({"start": true})).unwrap();
        g.tick(COUNTDOWN_MS);
        assert_eq!(g.phase, Phase::Run);
        let mut guard = 0;
        while g.phase == Phase::Run {
            guard += 1;
            assert!(guard < 10_000);
            assert_eq!(g.stage, Stage::Cue);
            g.tick(g.p.cti_ms);
            if g.phase != Phase::Run {
                break;
            }
            assert_eq!(g.stage, Stage::Target);
            let sw = g.is_switch(g.idx);
            match choose(g, sw) {
                Some((right, rt)) => {
                    g.tick(rt);
                    if g.phase != Phase::Run {
                        break;
                    }
                    g.act(&json!({"answer": side(right)})).unwrap();
                }
                None => g.tick(g.p.deadline_ms),
            }
            if g.phase != Phase::Run {
                break;
            }
            assert_eq!(g.stage, Stage::Feedback);
            g.tick(g.p.fb_ms);
        }
    }

    fn truth(g: &TaskSwitch) -> bool {
        let t = &g.trials[g.idx];
        expected_right(t.rule, &t.stim)
    }

    #[test]
    fn perfect_play_wins_three_stars() {
        for level in LEVELS {
            let mut g = TaskSwitch::level(level);
            play(&mut g, |g, sw| Some((truth(g), if sw { 650.0 } else { 550.0 })));
            let st = g.state();
            assert_eq!(st["status"], "won", "level {level}");
            assert_eq!(st["stars"], 3);
            assert_eq!(st["correct"], TRIALS as u64);
            assert_eq!(st["switch_cost_ms"], 100);
            assert!(st["summary"].as_str().unwrap().contains("Geçiş maliyeti 100 ms"));
        }
    }

    #[test]
    fn switch_cost_is_measured_and_caps_stars() {
        // Cue-free level: switch trials 400 ms slower → accuracy perfect but cost too high → 2★.
        let mut g = TaskSwitch::level(6);
        play(&mut g, |g, sw| Some((truth(g), if sw { 900.0 } else { 500.0 })));
        assert_eq!(g.switch_cost().unwrap().round(), 400.0);
        assert_eq!(g.state()["stars"], 2);
        assert_eq!(g.state()["rt_switch_ms"], 900);
        assert_eq!(g.state()["rt_repeat_ms"], 500);
    }

    #[test]
    fn trials_after_errors_are_excluded_from_switch_cost() {
        let mut g = TaskSwitch::level(1);
        let mut k = 0;
        play(&mut g, |g, _| {
            k += 1;
            // Every 4th trial wrong; the trial after it is very slow but must not count.
            let after_err = g.prev_error;
            Some((if k % 4 == 0 { !truth(g) } else { truth(g) }, if after_err { 2000.0 } else { 500.0 }))
        });
        assert_eq!(g.errors, 8);
        assert_eq!(g.switch_cost().unwrap(), 0.0);
        assert_eq!(g.state()["status"], "won"); // 75%
        assert_eq!(g.state()["stars"], 1);
    }

    #[test]
    fn errors_and_timeouts_lose() {
        let mut g = TaskSwitch::level(3);
        let mut k = 0;
        play(&mut g, |g, _| {
            k += 1;
            match k % 3 {
                0 => None,
                1 => Some((!truth(g), 500.0)),
                _ => Some((truth(g), 500.0)),
            }
        });
        let st = g.state();
        assert_eq!(st["status"], "lost");
        assert_eq!(st["stars"], 0);
        assert!(g.timeouts > 5);
        assert_eq!(g.correct + g.errors, TRIALS as u32);
    }

    #[test]
    fn illegal_actions_rejected_and_state_unchanged() {
        let mut g = TaskSwitch::level(1);
        let before = g.state();
        assert!(g.act(&json!({"answer": "left"})).is_err()); // not started
        assert!(g.act(&json!({"answer": "up"})).is_err());
        assert!(g.act(&json!({"foo": 1})).is_err());
        assert_eq!(g.state(), before);
        g.act(&json!({"start": true})).unwrap();
        assert!(g.act(&json!({"start": true})).is_err());
        g.tick(COUNTDOWN_MS);
        let before = g.state();
        assert!(g.act(&json!({"answer": "left"})).is_err()); // cue stage: target not shown
        assert_eq!(g.state(), before);
        assert!(before["target"].is_null());
        assert!(!before["active_rule"].is_null());
        g.tick(g.p.cti_ms);
        assert!(!g.state()["target"].is_null());
    }

    #[test]
    fn cue_free_hides_rule_until_feedback() {
        let mut g = TaskSwitch::level(6);
        g.act(&json!({"start": true})).unwrap();
        g.tick(COUNTDOWN_MS);
        assert!(g.state()["active_rule"].is_null());
        g.tick(g.p.cti_ms);
        assert!(g.state()["active_rule"].is_null());
        let wrong = !truth(&g);
        g.act(&json!({"answer": side(wrong)})).unwrap();
        let st = g.state();
        assert_eq!(st["stage"], "feedback");
        assert!(!st["active_rule"].is_null());
        assert_eq!(st["last"]["correct"], false);
    }

    #[test]
    fn rt_comes_from_core_clock() {
        let mut g = TaskSwitch::level(1);
        g.act(&json!({"start": true})).unwrap();
        g.tick(COUNTDOWN_MS);
        g.tick(g.p.cti_ms);
        g.tick(300.0);
        g.tick(123.0);
        let r = truth(&g);
        g.act(&json!({"answer": side(r)})).unwrap();
        assert_eq!(g.state()["last"]["rt_ms"], 423);
    }

    #[test]
    fn sprint_reaches_lost_and_scores() {
        let mut g = TaskSwitch::sprint(7);
        let mut k = 0;
        play(&mut g, |g, _| {
            k += 1;
            Some((if k % 10 == 0 { !truth(g) } else { truth(g) }, 400.0))
        });
        let st = g.state();
        assert_eq!(st["status"], "lost");
        assert_eq!(st["remaining_ms"], 0.0);
        let score = st["score"].as_i64().unwrap();
        assert_eq!(score, g.correct as i64 - g.errors as i64);
        assert!(g.correct > 40);
        assert!(g.sprint_stage >= 4, "stage {}", g.sprint_stage);
        assert!(st["summary"].as_str().unwrap().contains("Doğru"));
        assert!(g.act(&json!({"answer": "left"})).is_err());
        // A sprint where nothing is answered still ends, with score 0.
        let mut g = TaskSwitch::sprint(3);
        play(&mut g, |_, _| None);
        assert_eq!(g.state()["status"], "lost");
        assert_eq!(g.state()["score"], 0);
    }

    #[test]
    #[ignore]
    fn timing_500_levels() {
        let t = std::time::Instant::now();
        let mut worst = 0.0f64;
        for level in 1..=500 {
            let s = std::time::Instant::now();
            let g = TaskSwitch::level(level);
            assert_eq!(g.trials.len(), TRIALS);
            worst = worst.max(s.elapsed().as_secs_f64());
        }
        println!("task_switch: 500 levels in {:?}, worst {:.3} ms", t.elapsed(), worst * 1000.0);
    }
}
