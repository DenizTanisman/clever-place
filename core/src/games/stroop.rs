//! Renk–Kelime (Stroop) — inhibition and task switching. A word appears in an ink colour; answer
//! the **ink** by tapping a colour swatch (the buttons carry no words). On rule-switching levels a
//! cue tells you whether to answer the ink (`RENK`) or the word's meaning (`KELİME`).
//!
//! Colours (global indices, introduced in this order): 0 KIRMIZI · 1 MAVİ · 2 YEŞİL · 3 SARI ·
//! 4 MOR · 5 TURUNCU. Trial kinds: congruent (word = ink), incongruent (colour word ≠ ink), neutral
//! word (MASA…), colour-associated word (LİMON, DENİZ… always drawn in a different ink) and
//! emotional word (KORKU, PANİK…). Word-rule trials are always incongruent colour words.
//!
//! Level curve (`params(level)`), t = (level−1)/499:
//! - Colours: 1..=15 → 3 · 16..=80 → 4 · 81..=180 → 5 · 181.. → 6.
//! - Variant = (level−1) % 6: Klasik, Çağrışım (30 % associated/neutral words), Gezgin (word at a
//!   random position and size), Duygu (30 % emotional/neutral words), Kural değişimi (rule cue,
//!   ~30→40 % word-rule trials), Karışık (25 % mixed distractors; roaming from 30, switching from 60).
//!   From 300 every level roams, from 420 every level switches.
//! - Incongruent share of the colour-word ink trials: 50 % → 85 % (at least 3 congruent trials stay
//!   so the interference effect can be measured).
//! - Buttons: fixed order below 30; one shuffled order per level from 30; reshuffled on every word
//!   on even levels from 150 and on all levels from 350.
//! - Trials: 24 → 30. Fixation cross 450 → 300 ms before each word.
//! - Par mean RT (3 stars) = 820 − 220·t + 50·(colours−3) + 130 (switching) + 160 (per-word button
//!   shuffle) + 40 (roaming) ms; deadline per word = par × (2.1 − 0.6·t) (level 1: 820 / 1700 ms;
//!   level 500: 1080 / 1600 ms).
//!
//! Scoring (level): accuracy = correct / trials (wrong taps and timeouts are not correct).
//! Stars: ≥ 95 % and mean RT of correct answers ≤ par → 3 · ≥ 85 % and ≤ 1.25 × par → 2 · else 1.
//! Lost when accuracy can no longer reach 70 % or after more than trials/5 timeouts (the level
//! ends right there).
//!
//! Endless ("Sprint (60 sn)"): 60 s of words. `score` = max(0, correct − errors), errors = wrong
//! taps + timeouts. Difficulty stage = score / 6 (max 10): colours 3 → 6 over stages 0–3,
//! incongruent 50 % → 85 %, distractor words from stage 2, rule switching from 4, roaming from 5,
//! per-word button shuffle from 6; deadline 1900 − 90·stage ms (min 1000). Time up → `lost`.
//!
//! The summary reports the **Stroop effect**: mean RT of correct incongruent ink trials − mean RT of
//! correct congruent ink trials (needs ≥ 2 of each), and on switching levels the **switch cost**
//! (rule changed vs. repeated).
//!
//! State: `{status, stars, mode, phase: "intro"|"countdown"|"run"|"done", title, goal, summary?,
//!          score, notes: [..], colors: [{key, name}], buttons: [colour idx], switching, trial,
//!          trials|null, sub: "fix"|"stim"|null, t_ms, fix_ms, deadline_ms, countdown_ms,
//!          stim: {word, ink, rule, kind, x, y, size}|null, cue: "ink"|"word"|null, correct, wrong,
//!          timeouts, mean_rt|null, par_rt|null, interference_ms|null, switch_cost_ms|null,
//!          elapsed_ms, limit_ms|null, remaining_ms|null, stage|null,
//!          last: {serial, ok, timeout, rt, answer|null, expected, rule}|null}`
//! Actions: `{"start":true}` · `{"answer": colourIndex}`

use crate::rng::{seed_for, time_seed, Rng};
use crate::Session;
use serde_json::{json, Value};

pub const COLORS: [(&str, &str); 6] = [
    ("red", "KIRMIZI"),
    ("blue", "MAVİ"),
    ("green", "YEŞİL"),
    ("yellow", "SARI"),
    ("purple", "MOR"),
    ("orange", "TURUNCU"),
];
const ASSOC: [[&str; 3]; 6] = [
    ["DOMATES", "ÇİLEK", "KİRAZ"],
    ["DENİZ", "GÖK", "OKYANUS"],
    ["ÇİMEN", "YAPRAK", "ORMAN"],
    ["LİMON", "MUZ", "GÜNEŞ"],
    ["PATLICAN", "MENEKŞE", "LAVANTA"],
    ["PORTAKAL", "HAVUÇ", "MANDALİNA"],
];
const NEUTRAL: [&str; 8] = ["MASA", "KAPI", "KALEM", "DEFTER", "BARDAK", "PENCERE", "KİTAP", "SANDALYE"];
const EMOTIONAL: [&str; 8] = ["KORKU", "ÖFKE", "PANİK", "TEHLİKE", "KAYGI", "KAVGA", "YALAN", "ACİL"];

pub const COUNTDOWN_MS: f64 = 3000.0;
pub const SPRINT_MS: f64 = 60_000.0;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Congruent,
    Incongruent,
    Neutral,
    Assoc,
    Emotional,
}

impl Kind {
    fn key(self) -> &'static str {
        match self {
            Kind::Congruent => "congruent",
            Kind::Incongruent => "incongruent",
            Kind::Neutral => "neutral",
            Kind::Assoc => "assoc",
            Kind::Emotional => "emotional",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Rule {
    Ink,
    Word,
}

impl Rule {
    fn key(self) -> &'static str {
        match self {
            Rule::Ink => "ink",
            Rule::Word => "word",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Variant {
    Classic,
    Assoc,
    Roaming,
    Emotion,
    Switch,
    Mixed,
    Sprint,
}

impl Variant {
    fn label(self) -> &'static str {
        match self {
            Variant::Classic => "Klasik",
            Variant::Assoc => "Çağrışım",
            Variant::Roaming => "Gezgin",
            Variant::Emotion => "Duygu",
            Variant::Switch => "Kural değişimi",
            Variant::Mixed => "Karışık",
            Variant::Sprint => "Sprint",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Params {
    pub variant: Variant,
    pub colors: usize,
    pub trials: usize,
    pub p_incong: f64,
    /// Share of trials that show a non-colour word.
    pub distract: f64,
    pub assoc: bool,
    pub emo: bool,
    pub switching: bool,
    /// Share of word-rule trials when switching.
    pub p_word: f64,
    pub roaming: bool,
    /// 0 = fixed order, 1 = one shuffled order per level, 2 = reshuffled for every word.
    pub shuffle: u8,
    pub fix_ms: f64,
    pub deadline_ms: f64,
    pub par_rt: f64,
}

pub fn params(level: u32) -> Params {
    let level = level.clamp(1, 500);
    let t = (level - 1) as f64 / 499.0;
    let colors = match level {
        1..=15 => 3,
        16..=80 => 4,
        81..=180 => 5,
        _ => 6,
    };
    let variant = [Variant::Classic, Variant::Assoc, Variant::Roaming, Variant::Emotion, Variant::Switch, Variant::Mixed]
        [((level - 1) % 6) as usize];
    let (distract, assoc, emo) = match variant {
        Variant::Assoc => (0.3, true, false),
        Variant::Emotion => (0.3, false, true),
        Variant::Mixed => (0.25, true, true),
        _ => (0.0, false, false),
    };
    let switching = variant == Variant::Switch || (variant == Variant::Mixed && level >= 60) || level >= 420;
    let roaming = variant == Variant::Roaming || (variant == Variant::Mixed && level >= 30) || level >= 300;
    let shuffle = if level < 30 {
        0
    } else if level >= 350 || (level >= 150 && level.is_multiple_of(2)) {
        2
    } else {
        1
    };
    let mut par = 820.0 - 220.0 * t + 50.0 * (colors - 3) as f64;
    if switching {
        par += 130.0;
    }
    if shuffle == 2 {
        par += 160.0;
    }
    if roaming {
        par += 40.0;
    }
    let par_rt = (par / 10.0).round() * 10.0;
    let deadline_ms = (par_rt * (2.1 - 0.6 * t) / 50.0).round() * 50.0;
    Params {
        variant,
        colors,
        trials: 24 + (6.0 * t).round() as usize,
        p_incong: 0.5 + 0.35 * t,
        distract,
        assoc,
        emo,
        switching,
        p_word: 0.3 + 0.1 * t,
        roaming,
        shuffle,
        fix_ms: (450.0 - 150.0 * t).round(),
        deadline_ms,
        par_rt,
    }
}

/// Difficulty of the sprint at a given stage (stage = score / 6, capped at 10).
pub fn sprint_params(stage: u32) -> Params {
    let s = stage.min(10);
    let sf = s as f64;
    Params {
        variant: Variant::Sprint,
        colors: 3 + s.min(3) as usize,
        trials: 0,
        p_incong: (0.5 + 0.05 * sf).min(0.85),
        distract: if s >= 2 { 0.2 } else { 0.0 },
        assoc: s >= 2,
        emo: s >= 2,
        switching: s >= 4,
        p_word: (0.3 + 0.02 * (sf - 4.0).max(0.0)).min(0.4),
        roaming: s >= 5,
        shuffle: if s >= 6 { 2 } else { 0 },
        fix_ms: 300.0,
        deadline_ms: (1900.0 - 90.0 * sf).max(1000.0),
        par_rt: 0.0,
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Trial {
    pub kind: Kind,
    pub rule: Rule,
    pub word: &'static str,
    /// Colour the word names (colour words) or evokes (associated words).
    pub word_color: Option<usize>,
    pub ink: usize,
    pub x: f64,
    pub y: f64,
    pub size: f64,
    pub buttons: Vec<usize>,
}

impl Trial {
    pub fn expected(&self) -> usize {
        match self.rule {
            Rule::Ink => self.ink,
            Rule::Word => self.word_color.expect("word rule needs a colour word"),
        }
    }
}

fn other(rng: &mut Rng, k: usize, not: usize) -> usize {
    let c = rng.below(k - 1);
    if c >= not {
        c + 1
    } else {
        c
    }
}

fn permutation(rng: &mut Rng, k: usize, avoid: Option<&[usize]>) -> Vec<usize> {
    let mut v: Vec<usize> = (0..k).collect();
    for _ in 0..8 {
        rng.shuffle(&mut v);
        if avoid != Some(v.as_slice()) {
            break;
        }
    }
    v
}

/// Fill in a trial of the given kind/rule, avoiding an immediate repeat of the previous word or ink.
fn make_trial(rng: &mut Rng, p: &Params, kind: Kind, rule: Rule, prev: Option<&Trial>, base_buttons: &[usize]) -> Trial {
    let k = p.colors;
    let mut best = None;
    for _ in 0..10 {
        let (word, word_color, ink) = match kind {
            Kind::Congruent => {
                let c = rng.below(k);
                (COLORS[c].1, Some(c), c)
            }
            Kind::Incongruent => {
                let c = rng.below(k);
                (COLORS[c].1, Some(c), other(rng, k, c))
            }
            Kind::Assoc => {
                let c = rng.below(k);
                (*rng.pick(&ASSOC[c]), Some(c), other(rng, k, c))
            }
            Kind::Neutral => (*rng.pick(&NEUTRAL), None, rng.below(k)),
            Kind::Emotional => (*rng.pick(&EMOTIONAL), None, rng.below(k)),
        };
        let repeat = prev.is_some_and(|q| q.word == word || q.ink == ink);
        best = Some((word, word_color, ink));
        if !repeat {
            break;
        }
    }
    let (word, word_color, ink) = best.expect("at least one attempt");
    let (x, y, size) = if p.roaming {
        let x = ((rng.f64() * 2.0 - 1.0) * 0.7 * 100.0).round() / 100.0;
        let y = ((rng.f64() * 2.0 - 1.0) * 0.6 * 100.0).round() / 100.0;
        let size = ((0.8 + 0.4 * rng.f64()) * 100.0).round() / 100.0;
        (x, y, size)
    } else {
        (0.0, 0.0, 1.0)
    };
    let buttons = if p.shuffle == 2 {
        permutation(rng, k, prev.map(|q| q.buttons.as_slice()))
    } else {
        base_buttons.to_vec()
    };
    Trial { kind, rule, word, word_color, ink, x, y, size, buttons }
}

/// The full, deterministic trial list for a level (exact kind composition, shuffled order).
fn level_trials(level: u32, p: &Params) -> Vec<Trial> {
    let mut rng = Rng::new(seed_for("stroop", level, 0));
    let n = p.trials;
    let d = (n as f64 * p.distract).round() as usize;
    let w = if p.switching { (n as f64 * p.p_word).round() as usize } else { 0 };
    let c = n - d - w;
    let mut incong = (c as f64 * p.p_incong).round() as usize;
    if c >= 8 {
        incong = incong.min(c - 3);
    }
    let mut plan: Vec<(Kind, Rule)> = Vec::with_capacity(n);
    plan.extend(std::iter::repeat_n((Kind::Incongruent, Rule::Word), w));
    plan.extend(std::iter::repeat_n((Kind::Incongruent, Rule::Ink), incong));
    plan.extend(std::iter::repeat_n((Kind::Congruent, Rule::Ink), c - incong));
    let mut pool = vec![Kind::Neutral];
    if p.assoc {
        pool.push(Kind::Assoc);
    }
    if p.emo {
        pool.push(Kind::Emotional);
    }
    // Distractors: non-neutral kinds get the larger share (neutral words are the baseline).
    for i in 0..d {
        let kind = if pool.len() == 1 || i % 3 == 2 {
            Kind::Neutral
        } else {
            pool[1 + (i / 3 + i % 3) % (pool.len() - 1)]
        };
        plan.push((kind, Rule::Ink));
    }
    rng.shuffle(&mut plan);
    let base: Vec<usize> = if p.shuffle == 1 { permutation(&mut rng, p.colors, None) } else { (0..p.colors).collect() };
    let mut trials: Vec<Trial> = Vec::with_capacity(n);
    for (kind, rule) in plan {
        let t = make_trial(&mut rng, p, kind, rule, trials.last(), &base);
        trials.push(t);
    }
    trials
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Phase {
    Intro,
    Countdown,
    Run,
    Done,
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Sub {
    Fix,
    Stim,
}

#[derive(Clone, Debug)]
struct Res {
    kind: Kind,
    rule: Rule,
    switched: bool,
    ok: bool,
    timeout: bool,
    rt: f64,
}

#[derive(Clone, Debug)]
struct Feedback {
    serial: u32,
    ok: bool,
    timeout: bool,
    rt: f64,
    answer: Option<usize>,
    expected: usize,
    rule: Rule,
}

pub struct Stroop {
    endless: bool,
    p: Params,
    trials: Vec<Trial>,
    idx: usize,
    phase: Phase,
    sub: Sub,
    t_ms: f64,
    countdown_ms: f64,
    elapsed_ms: f64,
    results: Vec<Res>,
    last: Option<Feedback>,
    serial: u32,
    rng: Rng,
    won: bool,
    lost_reason: Option<&'static str>,
}

pub fn create(level: u32, mode: &str) -> Result<Box<dyn Session>, String> {
    Ok(Box::new(if mode == "endless" { Stroop::sprint(time_seed()) } else { Stroop::level(level) }))
}

fn mean(v: impl Iterator<Item = f64>) -> Option<(f64, usize)> {
    let (s, n) = v.fold((0.0, 0usize), |(s, n), x| (s + x, n + 1));
    if n == 0 {
        None
    } else {
        Some((s / n as f64, n))
    }
}

fn signed(ms: f64) -> String {
    let r = ms.round() as i64;
    if r >= 0 {
        format!("+{r}")
    } else {
        format!("−{}", -r)
    }
}

impl Stroop {
    pub fn level(level: u32) -> Self {
        let p = params(level);
        let trials = level_trials(level, &p);
        Stroop {
            endless: false,
            p,
            trials,
            idx: 0,
            phase: Phase::Intro,
            sub: Sub::Fix,
            t_ms: 0.0,
            countdown_ms: COUNTDOWN_MS,
            elapsed_ms: 0.0,
            results: vec![],
            last: None,
            serial: 0,
            rng: Rng::new(seed_for("stroop", level, 1)),
            won: false,
            lost_reason: None,
        }
    }

    pub fn sprint(seed: u64) -> Self {
        let mut g = Stroop::level(1);
        g.endless = true;
        g.p = sprint_params(0);
        g.rng = Rng::new(seed);
        g.trials.clear();
        g.push_sprint_trial();
        g
    }

    fn score(&self) -> u32 {
        let c = self.correct() as i64;
        let e = (self.results.len() - self.correct()) as i64;
        (c - e).max(0) as u32
    }

    fn stage(&self) -> u32 {
        (self.score() / 6).min(10)
    }

    fn push_sprint_trial(&mut self) {
        self.p = sprint_params(self.stage());
        let p = &self.p;
        let rng = &mut self.rng;
        let r = rng.f64();
        let (kind, rule) = if p.switching && r < p.p_word {
            (Kind::Incongruent, Rule::Word)
        } else if p.distract > 0.0 && rng.chance(p.distract) {
            (*rng.pick(&[Kind::Neutral, Kind::Assoc, Kind::Emotional]), Rule::Ink)
        } else if rng.chance(p.p_incong) {
            (Kind::Incongruent, Rule::Ink)
        } else {
            (Kind::Congruent, Rule::Ink)
        };
        let base: Vec<usize> = (0..p.colors).collect();
        let prev = self.trials.last().filter(|q| q.buttons.len() == p.colors);
        let t = make_trial(rng, p, kind, rule, prev, &base);
        self.trials.push(t);
    }

    fn current(&self) -> Option<&Trial> {
        if self.phase == Phase::Run {
            self.trials.get(self.idx)
        } else {
            None
        }
    }

    fn correct(&self) -> usize {
        self.results.iter().filter(|r| r.ok).count()
    }

    fn timeouts(&self) -> usize {
        self.results.iter().filter(|r| r.timeout).count()
    }

    fn mean_rt(&self) -> Option<f64> {
        mean(self.results.iter().filter(|r| r.ok).map(|r| r.rt)).map(|(m, _)| m)
    }

    fn interference(&self) -> Option<f64> {
        let of = |k: Kind| {
            mean(self.results.iter().filter(|r| r.ok && r.rule == Rule::Ink && r.kind == k).map(|r| r.rt))
        };
        match (of(Kind::Incongruent), of(Kind::Congruent)) {
            (Some((i, ni)), Some((c, nc))) if ni >= 2 && nc >= 2 => Some(i - c),
            _ => None,
        }
    }

    fn switch_cost(&self) -> Option<f64> {
        if !self.results.iter().any(|r| r.rule == Rule::Word) {
            return None;
        }
        let of = |sw: bool| mean(self.results.iter().skip(1).filter(|r| r.ok && r.switched == sw).map(|r| r.rt));
        match (of(true), of(false)) {
            (Some((s, ns)), Some((r, nr))) if ns >= 2 && nr >= 2 => Some(s - r),
            _ => None,
        }
    }

    fn record(&mut self, answer: Option<usize>) {
        let trial = &self.trials[self.idx];
        let expected = trial.expected();
        let ok = answer == Some(expected);
        let switched = self.idx > 0 && self.trials[self.idx - 1].rule != trial.rule;
        let rt = if answer.is_some() { self.t_ms } else { self.p.deadline_ms };
        self.results.push(Res { kind: trial.kind, rule: trial.rule, switched, ok, timeout: answer.is_none(), rt });
        self.serial += 1;
        self.last =
            Some(Feedback { serial: self.serial, ok, timeout: answer.is_none(), rt, answer, expected, rule: trial.rule });
        self.idx += 1;
        self.sub = Sub::Fix;
        self.t_ms = 0.0;
        if self.endless {
            self.push_sprint_trial();
            return;
        }
        let n = self.trials.len();
        let errors = self.results.len() - self.correct();
        let need = (7 * n).div_ceil(10);
        if errors > n - need {
            self.lost_reason = Some("Doğruluk %70'in altında kaldı");
            self.phase = Phase::Done;
        } else if self.timeouts() > n / 5 {
            self.lost_reason = Some("Çok fazla süre aşımı");
            self.phase = Phase::Done;
        } else if self.idx >= n {
            self.phase = Phase::Done;
            self.won = true;
        }
    }

    fn stars(&self) -> u32 {
        if !self.won {
            return 0;
        }
        let n = self.trials.len();
        let c = self.correct();
        let m = self.mean_rt().unwrap_or(f64::MAX);
        if c * 100 >= 95 * n && m <= self.p.par_rt {
            3
        } else if c * 100 >= 85 * n && m <= self.p.par_rt * 1.25 {
            2
        } else {
            1
        }
    }

    fn status(&self) -> &'static str {
        match self.phase {
            Phase::Done if self.won => "won",
            Phase::Done => "lost",
            _ => "playing",
        }
    }

    fn summary(&self) -> String {
        let mut parts: Vec<String> = vec![];
        if let Some(r) = self.lost_reason {
            parts.push(r.to_string());
        }
        if self.endless {
            parts.push(format!("Doğru {} · Hata {}", self.correct(), self.results.len() - self.correct()));
        } else {
            parts.push(format!("Doğru {}/{}", self.correct(), self.trials.len()));
        }
        if let Some(m) = self.mean_rt() {
            parts.push(format!("Ort. {} ms", m.round()));
        }
        if let Some(i) = self.interference() {
            parts.push(format!("Stroop etkisi {} ms", signed(i)));
        }
        if let Some(s) = self.switch_cost() {
            parts.push(format!("Geçiş bedeli {} ms", signed(s)));
        }
        parts.join(" · ")
    }

    fn notes(&self) -> Vec<String> {
        let p = &self.p;
        let mut v = vec![];
        if self.endless {
            v.push("60 saniye. Doğru +1, yanlış ya da geç kalma −1.".to_string());
            v.push("Puan arttıkça renk sayısı, tuzak kelimeler ve hız artar; sonra kural değişimi gelir.".to_string());
            v.push("Kural işareti çıkınca: RENK → mürekkep, KELİME → kelimenin anlamı.".to_string());
            return v;
        }
        if p.switching {
            v.push("Kelimenin üstündeki işaret kuralı söyler: RENK → mürekkebin rengi, KELİME → kelimenin anlattığı renk.".into());
        } else {
            v.push("Kelimeyi okuma: yazının mürekkep rengine dokun.".into());
        }
        if p.assoc {
            v.push("Bazı kelimeler bir rengi çağrıştırır (LİMON, DENİZ…). Yine de mürekkebe bak.".into());
        }
        if p.emo {
            v.push("Duygu yüklü kelimeler de var (KORKU, PANİK…); anlamına takılma.".into());
        }
        if p.roaming {
            v.push("Kelime ekranın farklı yerlerinde, farklı boyda belirir.".into());
        }
        match p.shuffle {
            1 => v.push("Düğmelerin sırası bu bölümde farklı.".into()),
            2 => v.push("Düğmelerin sırası her kelimede değişir.".into()),
            _ => {}
        }
        v.push(format!(
            "{} kelime · kelime başına {} sn · 3 yıldız: %95 doğru ve ort. {} ms altı.",
            self.trials.len(),
            format!("{:.1}", p.deadline_ms / 1000.0).replace('.', ","),
            p.par_rt
        ));
        v
    }

    fn goal(&self) -> String {
        if self.endless {
            return "60 sn · doğru +1, hata −1 · puan arttıkça zorlaşır".into();
        }
        let what = if self.p.switching { "İşarete göre renk ya da kelime" } else { "Mürekkebin rengine dokun" };
        format!("{what} · {} kelime · ★★★ %95 ve {} ms", self.trials.len(), self.p.par_rt)
    }
}

impl Session for Stroop {
    fn state(&self) -> Value {
        let cur = self.current();
        let stim = cur.filter(|_| self.sub == Sub::Stim).map(|t| {
            json!({"word": t.word, "ink": t.ink, "rule": t.rule.key(), "kind": t.kind.key(), "x": t.x, "y": t.y,
                   "size": t.size})
        });
        let buttons: Vec<usize> = cur
            .map(|t| t.buttons.clone())
            .or_else(|| self.trials.get(self.idx).map(|t| t.buttons.clone()))
            .or_else(|| self.trials.last().map(|t| t.buttons.clone()))
            .unwrap_or_else(|| (0..self.p.colors).collect());
        let colors: Vec<Value> =
            (0..buttons.len()).map(|i| json!({"key": COLORS[i].0, "name": COLORS[i].1})).collect();
        let cue = if self.p.switching { cur.map(|t| t.rule.key()) } else { None };
        let title = format!("{} · {} renk", self.p.variant.label(), self.p.colors);
        let last = self.last.as_ref().map(|f| {
            json!({"serial": f.serial, "ok": f.ok, "timeout": f.timeout, "rt": f.rt.round(), "answer": f.answer,
                   "expected": f.expected, "rule": f.rule.key()})
        });
        json!({
            "status": self.status(),
            "stars": self.stars(),
            "mode": if self.endless { "endless" } else { "level" },
            "phase": match self.phase {
                Phase::Intro => "intro", Phase::Countdown => "countdown", Phase::Run => "run", Phase::Done => "done",
            },
            "title": if self.endless { "Sprint".to_string() } else { title },
            "goal": self.goal(),
            "summary": if self.phase == Phase::Done { Some(self.summary()) } else { None },
            "score": if self.endless { self.score() } else { self.correct() as u32 },
            "notes": self.notes(),
            "colors": colors,
            "buttons": buttons,
            "switching": self.p.switching,
            "trial": self.idx,
            "trials": if self.endless { None } else { Some(self.trials.len()) },
            "sub": cur.map(|_| if self.sub == Sub::Fix { "fix" } else { "stim" }),
            "t_ms": self.t_ms.round(),
            "fix_ms": self.p.fix_ms,
            "deadline_ms": self.p.deadline_ms,
            "countdown_ms": self.countdown_ms.max(0.0).round(),
            "stim": stim,
            "cue": cue,
            "correct": self.correct(),
            "wrong": self.results.len() - self.correct() - self.timeouts(),
            "timeouts": self.timeouts(),
            "mean_rt": self.mean_rt().map(|m| m.round()),
            "par_rt": if self.endless { None } else { Some(self.p.par_rt) },
            "interference_ms": self.interference().map(|m| m.round()),
            "switch_cost_ms": self.switch_cost().map(|m| m.round()),
            "elapsed_ms": self.elapsed_ms.round(),
            "limit_ms": if self.endless { Some(SPRINT_MS) } else { None },
            "remaining_ms": if self.endless { Some((SPRINT_MS - self.elapsed_ms).max(0.0).round()) } else { None },
            "stage": if self.endless { Some(self.stage() + 1) } else { None },
            "last": last,
        })
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if self.phase == Phase::Done {
            return Err(if self.endless { "Süre doldu" } else { "Bölüm bitti" }.into());
        }
        if a["start"].as_bool() == Some(true) {
            if self.phase != Phase::Intro {
                return Err("Oyun zaten başladı".into());
            }
            self.phase = Phase::Countdown;
            self.countdown_ms = COUNTDOWN_MS;
            return Ok(());
        }
        let Some(answer) = a["answer"].as_u64() else {
            return Err("Bilinmeyen hamle".into());
        };
        match self.phase {
            Phase::Intro => return Err("Önce Başla'ya dokun".into()),
            Phase::Countdown => return Err("Geri sayımı bekle".into()),
            _ => {}
        }
        let answer = answer as usize;
        if answer >= self.p.colors {
            return Err("Bu renk bu bölümde yok".into());
        }
        if self.sub != Sub::Stim {
            return Err("Kelimeyi bekle".into());
        }
        self.record(Some(answer));
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
                    self.countdown_ms = 0.0;
                    self.phase = Phase::Run;
                    self.sub = Sub::Fix;
                    self.t_ms = 0.0;
                }
            }
            Phase::Run => {
                if self.endless {
                    self.elapsed_ms += dt_ms;
                    if self.elapsed_ms >= SPRINT_MS {
                        self.elapsed_ms = SPRINT_MS;
                        self.phase = Phase::Done;
                        return;
                    }
                } else {
                    self.elapsed_ms += dt_ms;
                }
                self.t_ms += dt_ms;
                if self.sub == Sub::Fix && self.t_ms >= self.p.fix_ms {
                    self.t_ms -= self.p.fix_ms;
                    self.sub = Sub::Stim;
                }
                if self.sub == Sub::Stim && self.t_ms >= self.p.deadline_ms {
                    self.record(None);
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

    fn started(mut g: Stroop) -> Stroop {
        g.act(&json!({"start": true})).unwrap();
        g.tick(COUNTDOWN_MS + 1.0);
        assert_eq!(g.phase, Phase::Run);
        g
    }

    /// Advance to the next word onset.
    fn to_stim(g: &mut Stroop) {
        let mut guard = 0;
        while g.phase == Phase::Run && g.sub != Sub::Stim {
            g.tick(50.0);
            guard += 1;
            assert!(guard < 100);
        }
    }

    fn answer_after(g: &mut Stroop, rt: f64, correct: bool) {
        to_stim(g);
        if g.phase != Phase::Run {
            return;
        }
        let t = g.t_ms;
        if rt > t {
            g.tick(rt - t);
        }
        let e = g.trials[g.idx].expected();
        let a = if correct { e } else { (e + 1) % g.p.colors };
        g.act(&json!({"answer": a})).unwrap();
    }

    #[test]
    fn params_cover_every_level_sanely() {
        for level in 1..=500 {
            let p = params(level);
            assert!((3..=6).contains(&p.colors));
            assert!((24..=30).contains(&p.trials));
            assert!(p.par_rt >= 600.0 && p.par_rt <= 1250.0, "L{level} par {}", p.par_rt);
            assert!(p.deadline_ms >= p.par_rt * 1.4, "L{level}");
            assert!(p.fix_ms >= 300.0);
        }
        assert_eq!(params(1).colors, 3);
        assert_eq!(params(1).variant, Variant::Classic);
        assert_eq!(params(1).deadline_ms, 1700.0);
        assert_eq!(params(1).par_rt, 820.0);
        assert_eq!(params(500).colors, 6);
        assert!(params(500).switching && params(500).roaming && params(500).shuffle == 2);
        assert!(params(5).switching);
        assert!(!params(1).switching && !params(2).switching);
        // Deadlines tighten relative to the par time.
        let ratio = |l: u32| params(l).deadline_ms / params(l).par_rt;
        assert!(ratio(1) > 2.0 && ratio(500) < 1.55);
        for s in 0..=12 {
            let p = sprint_params(s);
            assert!(p.deadline_ms >= 1000.0 && (3..=6).contains(&p.colors) && p.p_word <= 0.4 + 1e-9);
        }
    }

    #[test]
    fn levels_generate_and_are_deterministic() {
        for level in LEVELS {
            let a = Stroop::level(level);
            let b = Stroop::level(level);
            assert_eq!(a.trials, b.trials);
            let p = &a.p;
            assert_eq!(a.trials.len(), p.trials);
            for (i, t) in a.trials.iter().enumerate() {
                assert!(t.ink < p.colors && t.expected() < p.colors);
                assert_eq!(t.buttons.len(), p.colors);
                let mut b = t.buttons.clone();
                b.sort();
                assert_eq!(b, (0..p.colors).collect::<Vec<_>>());
                match t.kind {
                    Kind::Congruent => assert_eq!(t.word_color, Some(t.ink)),
                    Kind::Incongruent | Kind::Assoc => assert_ne!(t.word_color, Some(t.ink)),
                    _ => assert!(t.word_color.is_none()),
                }
                if t.rule == Rule::Word {
                    assert!(p.switching && t.kind == Kind::Incongruent);
                }
                if i > 0 && p.shuffle == 2 {
                    assert_ne!(t.buttons, a.trials[i - 1].buttons);
                }
            }
            let cong = a.trials.iter().filter(|t| t.kind == Kind::Congruent).count();
            assert!(cong >= 3, "L{level}: {cong} congruent");
            let st = a.state();
            assert_eq!(st["status"], "playing");
            assert!(st["stim"].is_null());
            assert!(!st["notes"].as_array().unwrap().is_empty());
        }
    }

    #[test]
    fn variants_contain_their_kinds() {
        let has = |level: u32, k: Kind| Stroop::level(level).trials.iter().any(|t| t.kind == k);
        assert!(has(2, Kind::Assoc) && has(2, Kind::Neutral));
        assert!(has(4, Kind::Emotional));
        assert!(Stroop::level(5).trials.iter().any(|t| t.rule == Rule::Word));
        assert!(Stroop::level(3).trials.iter().any(|t| t.x != 0.0 || t.y != 0.0));
        assert!(Stroop::level(1).trials.iter().all(|t| t.rule == Rule::Ink && t.x == 0.0));
    }

    #[test]
    fn fast_perfect_run_wins_three_stars_and_reports_effect() {
        for level in LEVELS {
            let mut g = started(Stroop::level(level));
            while g.phase == Phase::Run {
                // Incongruent answers 80 ms slower than congruent ones.
                to_stim(&mut g);
                let slow = g.trials[g.idx].kind != Kind::Congruent;
                answer_after(&mut g, if slow { 520.0 } else { 440.0 }, true);
            }
            let st = g.state();
            assert_eq!(st["status"], "won", "L{level}");
            assert_eq!(st["stars"], 3);
            let i = st["interference_ms"].as_f64().unwrap();
            assert!((i - 80.0).abs() <= 51.0, "L{level}: {i}");
            assert!(st["summary"].as_str().unwrap().contains("Stroop etkisi"));
            assert!(g.act(&json!({"answer": 0})).is_err());
        }
    }

    #[test]
    fn stars_follow_accuracy_and_speed() {
        // Correct but slow (between par and 1.25 × par) → 2 stars.
        let mut g = started(Stroop::level(1));
        let slow = g.p.par_rt * 1.1;
        while g.phase == Phase::Run {
            answer_after(&mut g, slow, true);
        }
        assert_eq!(g.stars(), 2);
        // Three mistakes in 24 (87.5 %) and fast → 2 stars; six mistakes (75 %) → 1 star.
        for (mistakes, stars) in [(3, 2), (6, 1)] {
            let mut g = started(Stroop::level(1));
            let mut i = 0;
            while g.phase == Phase::Run {
                answer_after(&mut g, 400.0, i >= mistakes);
                i += 1;
            }
            assert_eq!(g.state()["status"], "won");
            assert_eq!(g.stars(), stars, "{mistakes} mistakes");
        }
    }

    #[test]
    fn low_accuracy_loses_early() {
        let mut g = started(Stroop::level(1));
        let mut answered = 0;
        while g.phase == Phase::Run {
            answer_after(&mut g, 400.0, false);
            answered += 1;
        }
        let st = g.state();
        assert_eq!(st["status"], "lost");
        assert_eq!(answered, 8, "24 words: the 8th mistake makes 70 % unreachable");
        assert!(st["summary"].as_str().unwrap().starts_with("Doğruluk"));
    }

    #[test]
    fn timeouts_lose() {
        let mut g = started(Stroop::level(1));
        let mut guard = 0;
        while g.phase == Phase::Run {
            g.tick(100.0);
            guard += 1;
            assert!(guard < 10_000);
        }
        let st = g.state();
        assert_eq!(st["status"], "lost");
        assert_eq!(st["timeouts"], 5);
        assert_eq!(st["last"]["timeout"], true);
        assert!(st["summary"].as_str().unwrap().starts_with("Çok fazla süre aşımı"));
    }

    #[test]
    fn rule_switching_expects_word_meaning() {
        let mut g = started(Stroop::level(5));
        let i = g.trials.iter().position(|t| t.rule == Rule::Word).unwrap();
        for _ in 0..i {
            answer_after(&mut g, 400.0, true);
        }
        to_stim(&mut g);
        let st = g.state();
        assert_eq!(st["cue"], "word");
        let t = g.trials[g.idx].clone();
        g.act(&json!({"answer": t.ink})).unwrap(); // answering the ink is wrong here
        assert_eq!(g.state()["last"]["ok"], false);
        assert_eq!(g.state()["last"]["expected"], t.word_color.unwrap());
    }

    #[test]
    fn illegal_actions_rejected_and_state_unchanged() {
        let mut g = Stroop::level(1);
        let before = g.state();
        assert!(g.act(&json!({"answer": 0})).is_err());
        assert!(g.act(&json!({"foo": 1})).is_err());
        assert_eq!(g.state(), before);
        g.act(&json!({"start": true})).unwrap();
        assert!(g.act(&json!({"answer": 0})).is_err()); // countdown
        g.tick(COUNTDOWN_MS + 1.0);
        let before = g.state();
        assert_eq!(before["sub"], "fix");
        assert!(g.act(&json!({"answer": 0})).is_err()); // fixation: no word yet
        assert_eq!(g.state(), before);
        to_stim(&mut g);
        let before = g.state();
        assert!(g.act(&json!({"answer": 3})).is_err()); // only 3 colours on level 1
        assert!(g.act(&json!({"answer": "x"})).is_err());
        assert!(g.act(&json!({"start": true})).is_err());
        assert_eq!(g.state(), before);
    }

    #[test]
    fn sprint_ramps_scores_and_ends() {
        let mut g = started(Stroop::sprint(7));
        for _ in 0..50 {
            answer_after(&mut g, 300.0, true);
        }
        assert!(g.p.colors == 6 && g.p.switching && g.p.shuffle == 2, "stage {}", g.stage());
        answer_after(&mut g, 300.0, false);
        let st = g.state();
        assert_eq!(st["score"], 49);
        assert_eq!(st["status"], "playing");
        let mut guard = 0;
        while g.phase == Phase::Run {
            g.tick(200.0);
            guard += 1;
            assert!(guard < 1000);
        }
        let st = g.state();
        assert_eq!(st["status"], "lost");
        assert!(st["score"].as_u64().unwrap() <= 49);
        assert!(st["summary"].as_str().unwrap().contains("Doğru 50"));
        assert!(g.act(&json!({"answer": 0})).is_err());
        // Score never goes below zero.
        let mut g = started(Stroop::sprint(8));
        for _ in 0..5 {
            answer_after(&mut g, 300.0, false);
        }
        assert_eq!(g.state()["score"], 0);
    }

    #[test]
    fn signed_format() {
        assert_eq!(signed(86.4), "+86");
        assert_eq!(signed(-12.0), "−12");
    }

    #[test]
    #[ignore]
    fn timing_500_levels() {
        let t = std::time::Instant::now();
        let mut worst = 0.0f64;
        for level in 1..=500 {
            let s = std::time::Instant::now();
            let g = Stroop::level(level);
            assert!(!g.trials.is_empty());
            worst = worst.max(s.elapsed().as_secs_f64());
        }
        println!("stroop: 500 levels in {:?}, worst {:.3} ms", t.elapsed(), worst * 1000.0);
        for level in [1, 2, 5, 16, 30, 60, 81, 150, 181, 300, 350, 420, 500] {
            let p = params(level);
            println!("L{level}: {:?} k{} n{} inc {:.2} sw {} roam {} shuf {} fix {} dl {} par {}", p.variant, p.colors,
                p.trials, p.p_incong, p.switching, p.roaming, p.shuffle, p.fix_ms, p.deadline_ms, p.par_rt);
        }
    }
}
