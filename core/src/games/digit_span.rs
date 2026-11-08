//! Sayı Dizisi — forward / backward / sorted digit span and letter–number sequencing.
//!
//! A sequence is shown one symbol at a time (`on_ms` visible, then a blank until the next
//! `period_ms` slot). Afterwards the player types it back on a keypad in the order the variant asks:
//! - `forward` (İleri): as seen. `backward` (Geri): last to first. `sorted` (Sıralı): digits from
//!   smallest to largest. `letter_number` (Harf-rakam): digits ascending first, then the letters in
//!   alphabetical order (letters come from a fixed, unambiguous set [`LETTERS`]).
//! - Distractor levels put one or two quick "is this sum right?" judgements between show and recall
//!   (Brown–Peterson style: they block rehearsal). A wrong or missed judgement does not fail the
//!   trial but caps the level at 2 stars.
//!
//! Sequences: digits 0–9, never the same digit twice in a row; up to 9 symbols every digit is
//! distinct, longer sequences use each digit at most twice and never within 2 places; runs of three
//! consecutive digits (4-5-6, 8-7-6) are avoided (bounded retries).
//!
//! Level curve (`params(level)`), t = (level−1)/499:
//! - Variant cycle of 6: forward, backward, forward, sorted, backward, letter–number.
//! - Span (as a real number; a level's 5 trials get ⌊base⌋ or ⌊base⌋+1 so the curve is smooth, the
//!   longer trials come last): forward 5.5 → 13, backward 4 → 10.4, sorted 4 → 10, letter–number
//!   4 → 9. Distractor levels (level ≥ 150, every other 6-level cycle; two judgements from t > 0.6)
//!   are one shorter.
//! - Pace: `period_ms` 1000 → 550 (one symbol per second at level 1), `on_ms` = 70% of it.
//! - Stars over 5 trials: 5 correct → 3, 4 → 2, 3 → 1, fewer → `lost`. Distractor mistakes cap at 2.
//!
//! Endless (capacity test): a forward staircase, then a backward staircase, both at 1 symbol/s.
//! Forward starts at span 5, backward at 4. Two correct in a row → span + 1, one wrong → span − 1
//! (min 2). A staircase stops once the player has failed twice at the same span, or after 14
//! trials. Reliable span = the longest span recalled correctly at least twice (else at least once).
//! `score` = 10 × forward span + 15 × backward span (backward counts 1.5× because it needs
//! manipulation, not just storage). E.g. 7 forward, 5 backward → 145. Ends with `lost`.
//!
//! State: `{status, stars, mode, phase: "intro"|"countdown"|"ready"|"show"|"distract"|"recall"|
//!          "feedback"|"done", title, goal, summary?, score, variant, instruction, trial, trials|null,
//!          span, results: [bool], period_ms, on_ms, countdown_ms, show: {index, count, symbol|null,
//!          t_ms}|null, input: [str], need, keys: [str], distract: {text, index, count, remaining_ms,
//!          limit_ms}|null, distract_errors, last: {serial, correct, expected: [str], given: [str],
//!          sequence: [str], distract_ok|null}|null, track: "forward"|"backward"|null,
//!          forward_span|null, backward_span|null}`
//! Actions: `{"start":true}` · `{"key":"7"}` · `{"back":true}` · `{"submit":true}` ·
//!          `{"answer":"3 8 1"}` (whole answer at once, spaces optional) · `{"judge":true|false}` ·
//!          `{"next":true}` (skip the rest of the feedback pause)

use crate::rng::{seed_for, time_seed, Rng};
use crate::Session;
use serde_json::{json, Value};

/// Letters for letter–number sequencing: distinct shapes and names, already in Turkish alphabetical
/// order.
pub const LETTERS: [&str; 10] = ["A", "B", "D", "E", "K", "L", "M", "R", "S", "T"];
const DIGITS: [&str; 10] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"];

pub const TRIALS: usize = 5;
const COUNTDOWN_MS: f64 = 3000.0;
const READY_MS: f64 = 800.0;
const SHOW_TAIL_MS: f64 = 250.0;
const FEEDBACK_OK_MS: f64 = 1100.0;
const FEEDBACK_BAD_MS: f64 = 2300.0;
const DISTRACT_MS: f64 = 4000.0;
const ENDLESS_MAX_TRIALS: u32 = 14;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Variant {
    Forward,
    Backward,
    Sorted,
    LetterNumber,
}

impl Variant {
    pub fn key(self) -> &'static str {
        match self {
            Variant::Forward => "forward",
            Variant::Backward => "backward",
            Variant::Sorted => "sorted",
            Variant::LetterNumber => "letter_number",
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Variant::Forward => "İleri",
            Variant::Backward => "Geri",
            Variant::Sorted => "Sıralı",
            Variant::LetterNumber => "Harf-rakam",
        }
    }
    pub fn instruction(self) -> &'static str {
        match self {
            Variant::Forward => "Gördüğün sırayla yaz",
            Variant::Backward => "Sondan başa doğru yaz",
            Variant::Sorted => "Küçükten büyüğe sıralayıp yaz",
            Variant::LetterNumber => "Önce rakamlar küçükten büyüğe, sonra harfler alfabe sırasıyla",
        }
    }
    fn keys(self) -> Vec<&'static str> {
        match self {
            Variant::LetterNumber => DIGITS[1..].iter().chain(LETTERS.iter()).copied().collect(),
            _ => DIGITS.to_vec(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Params {
    pub variant: Variant,
    /// Sequence length of each trial.
    pub spans: Vec<usize>,
    pub period_ms: f64,
    pub on_ms: f64,
    /// Distractor judgements between show and recall (0 = none).
    pub distract: u32,
}

pub fn params(level: u32) -> Params {
    let level = level.clamp(1, crate::MAX_LEVEL);
    let t = (level - 1) as f64 / 499.0;
    let variant = match (level - 1) % 6 {
        0 | 2 => Variant::Forward,
        1 | 4 => Variant::Backward,
        3 => Variant::Sorted,
        _ => Variant::LetterNumber,
    };
    let distract = if level >= 150 && ((level - 1) / 6) % 2 == 1 { if t > 0.6 { 2 } else { 1 } } else { 0 };
    let (lo, hi, cap) = match variant {
        Variant::Forward => (5.5, 13.0, 13),
        Variant::Backward => (4.0, 10.4, 11),
        Variant::Sorted => (4.0, 10.0, 10),
        Variant::LetterNumber => (4.0, 9.0, 9),
    };
    let mut base: f64 = lo + (hi - lo) * t;
    if distract > 0 {
        base -= 1.0;
    }
    let whole = base.floor() as usize;
    let extra = ((base - base.floor()) * TRIALS as f64).round() as usize;
    let spans = (0..TRIALS).map(|i| (whole + usize::from(i >= TRIALS - extra)).min(cap)).collect();
    let period_ms = ((1000.0 - 450.0 * t) / 10.0).round() * 10.0;
    Params { variant, spans, period_ms, on_ms: (period_ms * 0.7).round(), distract }
}

/// Random sequence for a variant (see module docs for the constraints).
pub fn gen_sequence(rng: &mut Rng, variant: Variant, len: usize) -> Vec<String> {
    if variant == Variant::LetterNumber {
        let len = len.clamp(2, 18);
        let digits = (len / 2 + rng.below(2) * (len % 2)).clamp(1, len - 1).min(9);
        let letters = (len - digits).min(LETTERS.len());
        let mut d: Vec<usize> = (1..=9).collect();
        rng.shuffle(&mut d);
        let mut l: Vec<usize> = (0..LETTERS.len()).collect();
        rng.shuffle(&mut l);
        let mut seq: Vec<String> = d[..digits].iter().map(|x| x.to_string()).collect();
        seq.extend(l[..letters].iter().map(|&i| LETTERS[i].to_string()));
        rng.shuffle(&mut seq);
        return seq;
    }
    let mut best: Vec<u8> = Vec::new();
    for _ in 0..60 {
        let mut seq: Vec<u8> = Vec::with_capacity(len);
        let mut used = [0u8; 10];
        let max_use = if len <= 9 { 1 } else { 2 };
        while seq.len() < len {
            let opts: Vec<u8> = (0..10u8)
                .filter(|&x| used[x as usize] < max_use)
                .filter(|&x| !seq.iter().rev().take(2).any(|&p| p == x))
                .collect();
            if opts.is_empty() {
                break;
            }
            let x = *rng.pick(&opts);
            used[x as usize] += 1;
            seq.push(x);
        }
        if seq.len() < len {
            continue;
        }
        best = seq.clone();
        let run = seq.windows(3).any(|w| {
            let (a, b, c) = (w[0] as i32, w[1] as i32, w[2] as i32);
            (b - a == 1 && c - b == 1) || (a - b == 1 && b - c == 1)
        });
        if !run {
            break;
        }
    }
    best.iter().map(|d| d.to_string()).collect()
}

/// The answer the player must type for a shown sequence.
pub fn expected(variant: Variant, seq: &[String]) -> Vec<String> {
    match variant {
        Variant::Forward => seq.to_vec(),
        Variant::Backward => seq.iter().rev().cloned().collect(),
        Variant::Sorted => {
            let mut v = seq.to_vec();
            v.sort();
            v
        }
        Variant::LetterNumber => {
            let mut digits: Vec<String> = seq.iter().filter(|s| s.chars().all(|c| c.is_ascii_digit())).cloned().collect();
            digits.sort();
            let mut letters: Vec<String> = seq.iter().filter(|s| LETTERS.contains(&s.as_str())).cloned().collect();
            letters.sort_by_key(|s| LETTERS.iter().position(|l| l == s));
            digits.extend(letters);
            digits
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Phase {
    Intro,
    Countdown,
    Ready,
    Show,
    Distract,
    Recall,
    Feedback,
    Done,
}

impl Phase {
    fn key(self) -> &'static str {
        match self {
            Phase::Intro => "intro",
            Phase::Countdown => "countdown",
            Phase::Ready => "ready",
            Phase::Show => "show",
            Phase::Distract => "distract",
            Phase::Recall => "recall",
            Phase::Feedback => "feedback",
            Phase::Done => "done",
        }
    }
}

#[derive(Clone, Debug)]
struct Equation {
    text: String,
    truth: bool,
}

fn gen_equation(rng: &mut Rng) -> Equation {
    let a = rng.range(6, 39);
    let b = rng.range(3, 19);
    let sum = a + b;
    let truth = rng.chance(0.5);
    let shown = if truth {
        sum
    } else {
        let off = *rng.pick(&[1i64, 2, 10, -1, -2, -10]);
        sum + off
    };
    Equation { text: format!("{a} + {b} = {shown}"), truth }
}

#[derive(Clone, Debug)]
struct Feedback {
    serial: u32,
    correct: bool,
    expected: Vec<String>,
    given: Vec<String>,
    sequence: Vec<String>,
    distract_ok: Option<bool>,
}

/// Endless staircase bookkeeping for one track (forward or backward).
#[derive(Clone, Debug, Default)]
struct Stair {
    trials: u32,
    streak: u32,
    correct_at: [u32; 20],
    fails_at: [u32; 20],
}

impl Stair {
    fn reliable(&self) -> usize {
        (0..20).rev().find(|&s| self.correct_at[s] >= 2).or_else(|| (0..20).rev().find(|&s| self.correct_at[s] >= 1)).unwrap_or(0)
    }
}

pub struct DigitSpan {
    endless: bool,
    level: u32,
    params: Params,
    rng: Rng,
    phase: Phase,
    variant: Variant,
    trial: usize,
    span: usize,
    seq: Vec<String>,
    t_ms: f64,
    countdown_ms: f64,
    input: Vec<String>,
    results: Vec<bool>,
    equations: Vec<Equation>,
    eq_idx: usize,
    eq_t: f64,
    distract_errors: u32,
    trial_distract_ok: bool,
    last: Option<Feedback>,
    serial: u32,
    feedback_ms: f64,
    stars: u32,
    won: bool,
    // Endless
    stair: Stair,
    forward_span: Option<usize>,
    backward_span: Option<usize>,
}

pub fn create(level: u32, mode: &str) -> Result<Box<dyn Session>, String> {
    Ok(Box::new(if mode == "endless" { DigitSpan::endless(time_seed()) } else { DigitSpan::level(level) }))
}

impl DigitSpan {
    pub fn level(level: u32) -> Self {
        let params = params(level);
        let rng = Rng::new(seed_for("digit_span", level, 0));
        let mut g = DigitSpan {
            endless: false,
            level,
            variant: params.variant,
            span: params.spans[0],
            params,
            rng,
            phase: Phase::Intro,
            trial: 0,
            seq: vec![],
            t_ms: 0.0,
            countdown_ms: COUNTDOWN_MS,
            input: vec![],
            results: vec![],
            equations: vec![],
            eq_idx: 0,
            eq_t: 0.0,
            distract_errors: 0,
            trial_distract_ok: true,
            last: None,
            serial: 0,
            feedback_ms: 0.0,
            stars: 0,
            won: false,
            stair: Stair::default(),
            forward_span: None,
            backward_span: None,
        };
        g.prepare_trial();
        g
    }

    pub fn endless(seed: u64) -> Self {
        let mut g = DigitSpan::level(1);
        g.endless = true;
        g.rng = Rng::new(seed);
        g.params = Params { variant: Variant::Forward, spans: vec![], period_ms: 1000.0, on_ms: 700.0, distract: 0 };
        g.variant = Variant::Forward;
        g.span = 5;
        g.prepare_trial();
        g
    }

    fn trials(&self) -> Option<usize> {
        if self.endless {
            None
        } else {
            Some(self.params.spans.len())
        }
    }

    fn prepare_trial(&mut self) {
        if !self.endless {
            self.span = self.params.spans[self.trial];
        }
        self.seq = gen_sequence(&mut self.rng, self.variant, self.span);
        self.equations = (0..self.params.distract).map(|_| gen_equation(&mut self.rng)).collect();
        self.eq_idx = 0;
        self.eq_t = 0.0;
        self.trial_distract_ok = true;
        self.input.clear();
        self.t_ms = 0.0;
    }

    fn show_total_ms(&self) -> f64 {
        self.seq.len() as f64 * self.params.period_ms + SHOW_TAIL_MS
    }

    fn need(&self) -> usize {
        self.seq.len()
    }

    fn after_show(&mut self) {
        self.phase = if self.equations.is_empty() { Phase::Recall } else { Phase::Distract };
        self.eq_t = 0.0;
    }

    fn judge(&mut self, said: bool) {
        let ok = self.equations[self.eq_idx].truth == said;
        if !ok {
            self.distract_errors += 1;
            self.trial_distract_ok = false;
        }
        self.eq_idx += 1;
        self.eq_t = 0.0;
        if self.eq_idx >= self.equations.len() {
            self.phase = Phase::Recall;
        }
    }

    fn submit(&mut self) {
        let exp = expected(self.variant, &self.seq);
        let correct = exp == self.input;
        self.serial += 1;
        self.last = Some(Feedback {
            serial: self.serial,
            correct,
            expected: exp,
            given: self.input.clone(),
            sequence: self.seq.clone(),
            distract_ok: if self.equations.is_empty() { None } else { Some(self.trial_distract_ok) },
        });
        self.results.push(correct);
        if self.endless {
            self.stair_step(correct);
        }
        self.phase = Phase::Feedback;
        self.feedback_ms = if correct { FEEDBACK_OK_MS } else { FEEDBACK_BAD_MS };
    }

    /// Staircase update; may switch track or end the run (sets `phase` to Done via `advance`).
    fn stair_step(&mut self, ok: bool) {
        let s = self.span.min(19);
        let st = &mut self.stair;
        st.trials += 1;
        let mut stop = false;
        if ok {
            st.correct_at[s] += 1;
            st.streak += 1;
            if st.streak >= 2 {
                st.streak = 0;
                self.span = (self.span + 1).min(16);
            }
        } else {
            st.fails_at[s] += 1;
            st.streak = 0;
            if st.fails_at[s] >= 2 {
                stop = true;
            }
            self.span = self.span.saturating_sub(1).max(2);
        }
        if st.trials >= ENDLESS_MAX_TRIALS {
            stop = true;
        }
        if stop {
            let rel = self.stair.reliable();
            if self.variant == Variant::Forward {
                self.forward_span = Some(rel);
                self.variant = Variant::Backward;
                self.span = 4;
                self.stair = Stair::default();
            } else {
                self.backward_span = Some(rel);
            }
        }
    }

    fn run_over(&self) -> bool {
        if self.endless {
            self.backward_span.is_some()
        } else {
            self.results.len() >= self.params.spans.len()
        }
    }

    /// Leave the feedback pause: next trial or the end.
    fn advance(&mut self) {
        if self.run_over() {
            self.finish();
            return;
        }
        self.trial += 1;
        self.prepare_trial();
        self.phase = Phase::Ready;
        self.countdown_ms = READY_MS;
    }

    fn finish(&mut self) {
        self.phase = Phase::Done;
        if self.endless {
            return;
        }
        let ok = self.results.iter().filter(|&&r| r).count();
        let mut stars = match ok {
            5.. => 3,
            4 => 2,
            3 => 1,
            _ => 0,
        };
        if self.distract_errors > 0 {
            stars = stars.min(2);
        }
        self.stars = stars;
        self.won = stars > 0;
    }

    pub fn score(&self) -> u32 {
        if !self.endless {
            return self.results.iter().filter(|&&r| r).count() as u32 * 10;
        }
        let f = self.forward_span.unwrap_or_else(|| if self.variant == Variant::Forward { self.stair.reliable() } else { 0 });
        let b = self.backward_span.unwrap_or_else(|| if self.variant == Variant::Backward { self.stair.reliable() } else { 0 });
        (10 * f + 15 * b) as u32
    }

    fn status(&self) -> &'static str {
        match self.phase {
            Phase::Done if self.endless => "lost",
            Phase::Done if self.won => "won",
            Phase::Done => "lost",
            _ => "playing",
        }
    }

    fn summary(&self) -> String {
        if self.endless {
            return format!(
                "İleri {} · Geri {} · {} deneme",
                self.forward_span.unwrap_or(0),
                self.backward_span.unwrap_or(0),
                self.results.len()
            );
        }
        let ok = self.results.iter().filter(|&&r| r).count();
        let lo = self.params.spans.iter().min().copied().unwrap_or(0);
        let hi = self.params.spans.iter().max().copied().unwrap_or(0);
        let len = if lo == hi { format!("{lo}") } else { format!("{lo}–{hi}") };
        let mut s = format!(
            "Doğru {ok}/{} · Uzunluk {len} · {} sn/simge",
            self.results.len(),
            format!("{:.2}", self.params.period_ms / 1000.0).replace('.', ",")
        );
        if self.params.distract > 0 {
            s.push_str(&format!(" · Ara görev hatası {}", self.distract_errors));
        }
        s
    }

    fn goal(&self) -> String {
        if self.endless {
            return "Kapasiteni ölç: önce ileri, sonra geri dizi · iki doğru uzatır, bir yanlış kısaltır".into();
        }
        let lo = self.params.spans.iter().min().copied().unwrap_or(0);
        let hi = self.params.spans.iter().max().copied().unwrap_or(0);
        let len = if lo == hi { format!("{lo}") } else { format!("{lo}–{hi}") };
        let what = if self.variant == Variant::LetterNumber { "simge" } else { "rakam" };
        let extra = if self.params.distract > 0 { " · arada işlem" } else { "" };
        format!("{} deneme · {len} {what}{extra} · ★★★ için hepsi doğru", self.params.spans.len())
    }

    fn title(&self) -> String {
        if self.endless {
            return "Kapasite testi".into();
        }
        if self.params.distract > 0 {
            format!("{} + ara görev", self.variant.label())
        } else {
            self.variant.label().into()
        }
    }

    fn valid_key(&self, k: &str) -> bool {
        self.variant.keys().contains(&k)
    }
}

impl Session for DigitSpan {
    fn state(&self) -> Value {
        let show = (self.phase == Phase::Show).then(|| {
            let p = self.params.period_ms;
            let idx = (self.t_ms / p).floor() as usize;
            let visible = idx < self.seq.len() && self.t_ms - idx as f64 * p < self.params.on_ms;
            json!({
                "index": idx.min(self.seq.len()),
                "count": self.seq.len(),
                "symbol": if visible { Some(self.seq[idx].clone()) } else { None },
                "t_ms": self.t_ms.round(),
            })
        });
        let distract = (self.phase == Phase::Distract).then(|| {
            json!({
                "text": self.equations[self.eq_idx].text,
                "index": self.eq_idx,
                "count": self.equations.len(),
                "remaining_ms": (DISTRACT_MS - self.eq_t).max(0.0).round(),
                "limit_ms": DISTRACT_MS,
            })
        });
        let last = self.last.as_ref().map(|f| {
            json!({
                "serial": f.serial, "correct": f.correct, "expected": f.expected, "given": f.given,
                "sequence": f.sequence, "distract_ok": f.distract_ok,
            })
        });
        let results: Vec<bool> =
            if self.endless { self.results.iter().rev().take(14).rev().copied().collect() } else { self.results.clone() };
        json!({
            "status": self.status(),
            "stars": self.stars,
            "mode": if self.endless { "endless" } else { "level" },
            "phase": self.phase.key(),
            "title": self.title(),
            "goal": self.goal(),
            "summary": (self.phase == Phase::Done).then(|| self.summary()),
            "score": self.score(),
            "level": self.level,
            "variant": self.variant.key(),
            "variant_label": self.variant.label(),
            "instruction": self.variant.instruction(),
            "trial": self.trial,
            "trials": self.trials(),
            "span": self.span,
            "results": results,
            "period_ms": self.params.period_ms,
            "on_ms": self.params.on_ms,
            "countdown_ms": self.countdown_ms.max(0.0).round(),
            "show": show,
            "input": self.input,
            "need": self.need(),
            "keys": self.variant.keys(),
            "distract": distract,
            "distract_errors": self.distract_errors,
            "last": last,
            "track": if self.endless { Some(self.variant.key()) } else { None },
            "forward_span": self.forward_span,
            "backward_span": self.backward_span,
        })
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if self.phase == Phase::Done {
            return Err("Oyun bitti".into());
        }
        if a["start"].as_bool() == Some(true) {
            if self.phase != Phase::Intro {
                return Err("Oyun zaten başladı".into());
            }
            self.phase = Phase::Countdown;
            self.countdown_ms = COUNTDOWN_MS;
            return Ok(());
        }
        if self.phase == Phase::Intro {
            return Err("Önce Başla'ya dokun".into());
        }
        if a["next"].as_bool() == Some(true) {
            if self.phase != Phase::Feedback {
                return Err("Şimdi geçilemez".into());
            }
            self.advance();
            return Ok(());
        }
        if let Some(said) = a["judge"].as_bool() {
            if self.phase != Phase::Distract {
                return Err("Şimdi işlem sorusu yok".into());
            }
            self.judge(said);
            return Ok(());
        }
        let typing = a.get("key").is_some() || a.get("back").is_some() || a.get("submit").is_some() || a.get("answer").is_some();
        if !typing {
            return Err("Bilinmeyen hamle".into());
        }
        if self.phase != Phase::Recall {
            return Err(match self.phase {
                Phase::Show | Phase::Countdown | Phase::Ready => "Önce diziyi izle",
                Phase::Distract => "Önce işlemi cevapla",
                _ => "Şimdi yazma sırası değil",
            }
            .into());
        }
        if let Some(k) = a["key"].as_str() {
            let k = k.trim().to_uppercase();
            if !self.valid_key(&k) {
                return Err("Bu tuş bu dizide yok".into());
            }
            if self.input.len() >= self.need() {
                return Err(format!("Dizi {} simge", self.need()));
            }
            self.input.push(k);
            return Ok(());
        }
        if a["back"].as_bool() == Some(true) {
            self.input.pop().ok_or("Silinecek bir şey yok")?;
            return Ok(());
        }
        if a["submit"].as_bool() == Some(true) {
            if self.input.len() != self.need() {
                return Err(format!("{} simge yazmalısın", self.need()));
            }
            self.submit();
            return Ok(());
        }
        if let Some(s) = a["answer"].as_str() {
            let syms: Vec<String> =
                s.chars().filter(|c| !c.is_whitespace() && *c != ',' && *c != '-').map(|c| c.to_uppercase().to_string()).collect();
            if syms.len() != self.need() {
                return Err(format!("{} simge yazmalısın", self.need()));
            }
            if let Some(bad) = syms.iter().find(|k| !self.valid_key(k)) {
                return Err(format!("Geçersiz simge: {bad}"));
            }
            self.input = syms;
            self.submit();
            return Ok(());
        }
        Err("Bilinmeyen hamle".into())
    }

    fn tick(&mut self, dt_ms: f64) {
        if dt_ms.is_nan() || dt_ms <= 0.0 {
            return;
        }
        match self.phase {
            Phase::Countdown | Phase::Ready => {
                self.countdown_ms -= dt_ms;
                if self.countdown_ms <= 0.0 {
                    self.countdown_ms = 0.0;
                    self.phase = Phase::Show;
                    self.t_ms = 0.0;
                }
            }
            Phase::Show => {
                self.t_ms += dt_ms;
                if self.t_ms >= self.show_total_ms() {
                    self.after_show();
                }
            }
            Phase::Distract => {
                self.eq_t += dt_ms;
                if self.eq_t >= DISTRACT_MS {
                    // Too slow counts as a wrong judgement.
                    let truth = self.equations[self.eq_idx].truth;
                    self.judge(!truth);
                }
            }
            Phase::Feedback => {
                self.feedback_ms -= dt_ms;
                if self.feedback_ms <= 0.0 {
                    self.advance();
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

    fn run_to(g: &mut DigitSpan, phase: Phase) {
        for _ in 0..10_000 {
            if g.phase == phase || g.phase == Phase::Done {
                return;
            }
            g.tick(50.0);
        }
        panic!("phase {phase:?} not reached");
    }

    /// Plays one trial; `right` decides whether the typed answer is correct.
    fn play_trial(g: &mut DigitSpan, right: bool) {
        run_to(g, Phase::Show);
        // Shown symbols must match the hidden sequence in order.
        let mut seen: Vec<String> = vec![];
        let mut prev_visible = false;
        while g.phase == Phase::Show {
            let sym = g.state()["show"]["symbol"].as_str().map(|s| s.to_string());
            if let Some(sym) = &sym {
                if !prev_visible {
                    seen.push(sym.clone());
                }
            }
            prev_visible = sym.is_some();
            g.tick(50.0);
        }
        assert_eq!(seen, g.seq);
        while g.phase == Phase::Distract {
            let truth = g.equations[g.eq_idx].truth;
            g.act(&json!({"judge": truth})).unwrap();
        }
        assert_eq!(g.phase, Phase::Recall);
        let mut ans = expected(g.variant, &g.seq);
        if !right {
            ans.reverse();
            if ans == expected(g.variant, &g.seq) {
                ans[0] = if ans[0] == "1" { "2".into() } else { "1".into() };
            }
        }
        for k in &ans {
            g.act(&json!({"key": k})).unwrap();
        }
        g.act(&json!({"submit": true})).unwrap();
        assert_eq!(g.phase, Phase::Feedback);
        assert_eq!(g.last.as_ref().unwrap().correct, right);
        g.act(&json!({"next": true})).unwrap();
    }

    #[test]
    fn params_cover_curve() {
        for level in LEVELS {
            let p = params(level);
            assert_eq!(p.spans.len(), TRIALS);
            assert!(p.spans.iter().all(|&s| (3..=13).contains(&s)), "level {level}: {:?}", p.spans);
            assert!(p.period_ms >= 550.0 && p.period_ms <= 1000.0);
        }
        assert_eq!(params(1).variant, Variant::Forward);
        assert_eq!(params(1).period_ms, 1000.0);
        assert_eq!(params(2).variant, Variant::Backward);
        assert_eq!(params(4).variant, Variant::Sorted);
        assert_eq!(params(6).variant, Variant::LetterNumber);
        assert_eq!(*params(493).spans.last().unwrap(), 13); // forward reaches 13
        assert!(params(494).spans.iter().all(|&s| s >= 10)); // backward at the top
        assert!(params(1).spans[0] >= 5);
        assert!((150..=500).any(|l| params(l).distract > 0));
        assert!((1..150).all(|l| params(l).distract == 0));
        // Monotone in the long run.
        let avg = |l: u32| params(l).spans.iter().sum::<usize>() as f64;
        assert!(avg(493) > avg(1));
    }

    #[test]
    fn sequences_respect_constraints() {
        let mut rng = Rng::new(7);
        for len in 3..=13 {
            for _ in 0..50 {
                let s = gen_sequence(&mut rng, Variant::Forward, len);
                assert_eq!(s.len(), len);
                for w in s.windows(2) {
                    assert_ne!(w[0], w[1]);
                }
                for d in DIGITS {
                    let c = s.iter().filter(|x| x.as_str() == d).count();
                    assert!(c <= if len <= 9 { 1 } else { 2 });
                }
            }
        }
        for len in 3..=9 {
            let s = gen_sequence(&mut rng, Variant::LetterNumber, len);
            assert_eq!(s.len(), len);
            assert!(s.iter().any(|x| x.chars().all(|c| c.is_ascii_digit())));
            assert!(s.iter().any(|x| LETTERS.contains(&x.as_str())));
        }
    }

    #[test]
    fn expected_orders() {
        let seq: Vec<String> = ["3", "8", "1", "5"].iter().map(|s| s.to_string()).collect();
        assert_eq!(expected(Variant::Forward, &seq), seq);
        assert_eq!(expected(Variant::Backward, &seq), vec!["5", "1", "8", "3"]);
        assert_eq!(expected(Variant::Sorted, &seq), vec!["1", "3", "5", "8"]);
        let ln: Vec<String> = ["R", "4", "B", "1", "T", "7"].iter().map(|s| s.to_string()).collect();
        assert_eq!(expected(Variant::LetterNumber, &ln), vec!["1", "4", "7", "B", "R", "T"]);
    }

    #[test]
    fn levels_generate_and_are_deterministic() {
        for level in LEVELS {
            let a = DigitSpan::level(level);
            let b = DigitSpan::level(level);
            assert_eq!(a.seq, b.seq);
            assert_eq!(a.seq.len(), a.params.spans[0]);
            let st = a.state();
            assert_eq!(st["status"], "playing");
            assert_eq!(st["phase"], "intro");
        }
        assert_ne!(DigitSpan::level(3).seq, DigitSpan::level(4).seq);
    }

    #[test]
    fn perfect_run_gives_three_stars_every_variant() {
        for level in [1, 2, 3, 4, 6, 50, 137, 157, 250, 400, 499, 500] {
            let mut g = DigitSpan::level(level);
            g.act(&json!({"start": true})).unwrap();
            for _ in 0..TRIALS {
                play_trial(&mut g, true);
            }
            assert_eq!(g.state()["status"], "won", "level {level}");
            assert_eq!(g.stars, 3);
            assert!(g.state()["summary"].is_string());
        }
    }

    #[test]
    fn stars_follow_trials_correct() {
        for (wrong, stars, status) in [(1, 2, "won"), (2, 1, "won"), (3, 0, "lost")] {
            let mut g = DigitSpan::level(2);
            g.act(&json!({"start": true})).unwrap();
            for i in 0..TRIALS {
                play_trial(&mut g, i >= wrong);
            }
            assert_eq!(g.stars, stars);
            assert_eq!(g.state()["status"], status);
        }
    }

    #[test]
    fn distractor_mistake_caps_stars() {
        let level = (150..=500).find(|&l| params(l).distract > 0).unwrap();
        let mut g = DigitSpan::level(level);
        g.act(&json!({"start": true})).unwrap();
        run_to(&mut g, Phase::Distract);
        // Let the first judgement time out → counts as wrong.
        while g.phase == Phase::Distract && g.eq_idx == 0 {
            g.tick(100.0);
        }
        assert_eq!(g.distract_errors, 1);
        while g.phase == Phase::Distract {
            let truth = g.equations[g.eq_idx].truth;
            g.act(&json!({"judge": truth})).unwrap();
        }
        let ans: String = expected(g.variant, &g.seq).concat();
        g.act(&json!({"answer": ans})).unwrap();
        g.act(&json!({"next": true})).unwrap();
        for _ in 1..TRIALS {
            play_trial(&mut g, true);
        }
        assert_eq!(g.stars, 2);
    }

    #[test]
    fn illegal_actions_rejected_and_state_unchanged() {
        let mut g = DigitSpan::level(1);
        assert!(g.act(&json!({"key": "1"})).is_err());
        g.act(&json!({"start": true})).unwrap();
        assert!(g.act(&json!({"start": true})).is_err());
        run_to(&mut g, Phase::Show);
        let before = g.state();
        assert!(g.act(&json!({"key": "1"})).is_err());
        assert!(g.act(&json!({"judge": true})).is_err());
        assert!(g.act(&json!({"next": true})).is_err());
        assert_eq!(g.state(), before);
        run_to(&mut g, Phase::Recall);
        let before = g.state();
        assert!(g.act(&json!({"key": "A"})).is_err());
        assert!(g.act(&json!({"back": true})).is_err());
        assert!(g.act(&json!({"submit": true})).is_err());
        assert!(g.act(&json!({"answer": "12"})).is_err());
        assert!(g.act(&json!({"bogus": 1})).is_err());
        assert_eq!(g.state(), before);
        for _ in 0..g.need() {
            g.act(&json!({"key": "0"})).unwrap();
        }
        let before = g.state();
        assert!(g.act(&json!({"key": "1"})).is_err());
        assert_eq!(g.state(), before);
        g.act(&json!({"back": true})).unwrap();
        assert_eq!(g.input.len(), g.need() - 1);
    }

    #[test]
    fn wrong_answer_feedback_shows_expected() {
        let mut g = DigitSpan::level(2);
        g.act(&json!({"start": true})).unwrap();
        run_to(&mut g, Phase::Recall);
        let fwd: String = g.seq.concat(); // forward answer on a backward level = wrong
        g.act(&json!({"answer": fwd})).unwrap();
        let st = g.state();
        assert_eq!(st["last"]["correct"], false);
        let exp: Vec<String> = serde_json::from_value(st["last"]["expected"].clone()).unwrap();
        assert_eq!(exp, expected(Variant::Backward, &g.seq));
        // Feedback pause ends on its own.
        run_to(&mut g, Phase::Show);
        assert_eq!(g.trial, 1);
    }

    #[test]
    fn endless_staircase_reaches_lost_and_scores() {
        // A player with capacity 7 forward, 5 backward.
        let mut g = DigitSpan::endless(99);
        g.act(&json!({"start": true})).unwrap();
        let mut guard = 0;
        while g.phase != Phase::Done {
            run_to(&mut g, Phase::Recall);
            if g.phase == Phase::Done {
                break;
            }
            let cap = if g.variant == Variant::Forward { 7 } else { 5 };
            let mut ans = expected(g.variant, &g.seq);
            if g.span > cap {
                ans.swap(0, 1);
            }
            g.act(&json!({"answer": ans.concat()})).unwrap();
            g.act(&json!({"next": true})).unwrap();
            guard += 1;
            assert!(guard <= 28);
        }
        let st = g.state();
        assert_eq!(st["status"], "lost");
        assert_eq!(g.forward_span, Some(7));
        assert_eq!(g.backward_span, Some(5));
        assert_eq!(st["score"], 10 * 7 + 15 * 5);
        assert!(st["summary"].as_str().unwrap().contains("İleri 7"));
    }

    #[test]
    fn endless_all_wrong_ends_quickly() {
        let mut g = DigitSpan::endless(5);
        g.act(&json!({"start": true})).unwrap();
        let mut n = 0;
        while g.phase != Phase::Done {
            run_to(&mut g, Phase::Recall);
            let mut ans = expected(g.variant, &g.seq);
            ans.swap(0, 1);
            g.act(&json!({"answer": ans.concat()})).unwrap();
            g.act(&json!({"next": true})).unwrap();
            n += 1;
            assert!(n <= 28);
        }
        assert_eq!(g.state()["status"], "lost");
        assert_eq!(g.score(), 0);
    }

    #[test]
    #[ignore]
    fn timing_500_levels() {
        let t = std::time::Instant::now();
        for level in 1..=500 {
            let g = DigitSpan::level(level);
            assert!(!g.seq.is_empty());
        }
        println!("digit_span: 500 levels in {:?}", t.elapsed());
    }
}
