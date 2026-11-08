//! Corsi Blocks — visuospatial working-memory span (after Corsi, 1972; Kessels et al., 2000).
//!
//! Irregularly placed blocks light up one by one; the player then taps them in the same order
//! (forward) or in the reverse order (backward). Blocks are positioned per level on a portrait board
//! `1.0 × BOARD_H` (normalised units) with best-candidate sampling: no two blocks overlap (centre
//! distance ≥ 1.5 × block size, so even rotated squares keep a gap) and no block lines up with two
//! others on the same column or row, so the layout never reads as a grid.
//!
//! A level is `TRIALS` (6) trials. Each trial: a short "ready" pause, the show (targets light for
//! 60% of the onset interval; bordeaux distractor flashes are interleaved on some levels and must be
//! ignored), an optional drift (every block glides to a new nearby spot — at recall you must track
//! *which* block lit, not *where* it was), then recall without a time limit. A wrong tap ends the
//! trial at once and the correct answer is replayed slowly. Repeated taps on a block already tapped
//! in this trial are rejected (sequences never repeat a block), so a double tap can't cost a trial.
//!
//! Stars (level mode): 6/6 correct → 3, 5/6 → 2, 3–4/6 → 1, fewer than half → `lost` (the level ends
//! early as soon as 3 correct is out of reach).
//!
//! Level curve (`params(level)`, t = (level−1)/499):
//! - span s(L) = 4 + 7·((L−1)/499)^0.75 → 4.0 at L1, ≈5 at L40, ≈6 at L100, ≈8 at L250, 11 at L500.
//!   The fractional part is spread over the trials: ⌈frac·6 − 0.25⌉ of the 6 trials (the last ones)
//!   use ⌊s⌋+1, so difficulty rises smoothly (level 2 already has one 5-long trial).
//! - L1–11 forward only; L12–29 backward recall on every 3rd level (span − 1, since reversing costs
//!   about one item), announced up front;
//! - from L30 (`MIXED_FROM`) three of every four levels are **mixed**: each trial is forward or
//!   backward at random (`trial_dirs`, deterministic per level, at least 2 of each in the 6), and
//!   the order is hidden (`reverse: null`) during ready/show/drift and revealed only when recall
//!   starts. All trials use span − 0.5 so their length gives nothing away; every 4th level stays
//!   plainly forward. Scoring checks the revealed order;
//! - onset interval 900 → 450 ms; blocks 9 → 16;
//! - distractor flashes from L40 on 3 of every 4 levels: 1 → 3 per trial;
//! - drift from L150 on 2 of every 5 levels: up to 0.5 → 1.5 block sizes.
//!
//! Endless ("Uyarlanır", clinical staircase): 12 fixed blocks, 900 ms. Forward staircase from span
//! 3: two trials per span, continue to span+1 if at least one is correct (a correct first trial skips
//! the second); the stage ends when both fail. Then the same staircase backward. Span of a stage =
//! longest span with a correct trial (2 if even span 3 fails). `score` = forward span + backward span
//! (the backward span is the bonus on top of the classic forward Corsi span).
//!
//! State: `{status, stars, mode, phase: "intro"|"countdown"|"ready"|"show"|"drift"|"recall"|
//!          "feedback"|"replay"|"done", title, goal, summary, score?, board_h, block_size,
//!          blocks: [[x,y]], rot: [rad], lit: {block, kind: "target"|"distractor"|"replay", index, t,
//!          key}|null, trial, trials, span, reverse: bool|null (null = not revealed yet), mixed,
//!          interval_ms, distractors, drifting, taps: [b],
//!          answer: [b] (feedback/replay/done only), last_tap: {block, ok, serial}|null, wrong_block,
//!          results: [bool], correct, wrong, countdown_ms, stage: "forward"|"backward",
//!          forward_span, backward_span, history: [{span, reverse, ok}]}`
//! Actions: `{"start":true}` · `{"tap": block}`

use crate::rng::{seed_for, time_seed, Rng};
use crate::Session;
use serde_json::{json, Value};

pub const BOARD_H: f64 = 1.25;
pub const TRIALS: usize = 6;
pub const COUNTDOWN_MS: f64 = 3000.0;
pub const READY_MS: f64 = 800.0;
pub const LEAD_MS: f64 = 450.0;
pub const TAIL_MS: f64 = 300.0;
pub const DRIFT_MS: f64 = 1700.0;
pub const FEEDBACK_MS: f64 = 900.0;
pub const REPLAY_LEAD_MS: f64 = 600.0;
pub const REPLAY_STEP_MS: f64 = 520.0;
pub const REPLAY_TAIL_MS: f64 = 800.0;
/// Share of the onset interval a block stays lit.
pub const LIT_SHARE: f64 = 0.6;
pub const ENDLESS_BLOCKS: usize = 12;
pub const ENDLESS_START: usize = 3;
pub const ENDLESS_INTERVAL: f64 = 900.0;
/// Minimum centre distance in block sizes.
pub const SEP: f64 = 1.5;
/// Two blocks whose x (or y) differ by less than this are "aligned".
const ALIGN: f64 = 0.02;
/// First level whose trials may be forward or backward at random.
pub const MIXED_FROM: u32 = 30;

#[derive(Clone, Debug, PartialEq)]
pub struct Params {
    pub blocks: usize,
    /// Span per trial (ascending).
    pub spans: Vec<usize>,
    /// Every trial backward (fixed, announced up front).
    pub reverse: bool,
    /// Each trial's order is drawn at random and revealed only when recall starts.
    pub mixed: bool,
    pub interval_ms: f64,
    pub distractors: usize,
    /// Maximum drift distance in block sizes (0 = blocks stay put).
    pub drift: f64,
}

/// Continuous forward-span curve.
pub fn span_curve(level: u32) -> f64 {
    let l = (level.clamp(1, crate::MAX_LEVEL) - 1) as f64;
    4.0 + 7.0 * l.powf(0.75) / 499f64.powf(0.75)
}

/// Level → parameters (see the module docs for the curve).
pub fn params(level: u32) -> Params {
    let level = level.clamp(1, crate::MAX_LEVEL);
    let t = (level - 1) as f64 / 499.0;
    let blocks = 9 + (7.0 * t + 1e-9).floor() as usize;
    let mixed = level >= MIXED_FROM && level % 4 != 0;
    let reverse = (12..MIXED_FROM).contains(&level) && level % 3 == 0;
    // Mixed trials share one length whatever their order, so the length gives nothing away.
    let span = span_curve(level) - if reverse { 1.0 } else if mixed { 0.5 } else { 0.0 };
    let base = (span + 1e-9).floor() as usize;
    let frac = span - base as f64;
    let ups = ((frac * TRIALS as f64 - 0.25).ceil().max(0.0) as usize).min(TRIALS);
    let spans = (0..TRIALS).map(|i| if i + ups >= TRIALS { base + 1 } else { base }).collect();
    let distractors = if level >= 40 && level % 4 != 0 { 1 + (2.999 * t) as usize } else { 0 };
    let drift = if level >= 150 && (level % 5 == 2 || level % 5 == 4) { 0.5 + 1.0 * t } else { 0.0 };
    Params { blocks, spans, reverse, mixed, interval_ms: 900.0 - 450.0 * t, distractors, drift }
}

/// Per-trial order of a mixed level (`true` = backward): deterministic from the level seed, with
/// at least two trials of each order so neither can be counted on.
pub fn trial_dirs(level: u32) -> Vec<bool> {
    let mut r = Rng::new(seed_for("corsi", level, 1));
    loop {
        let d: Vec<bool> = (0..TRIALS).map(|_| r.chance(0.5)).collect();
        let back = d.iter().filter(|&&b| b).count();
        if (2..=TRIALS - 2).contains(&back) {
            return d;
        }
    }
}

/// Block side length (normalised to the board width) for `n` blocks.
pub fn block_size(n: usize) -> f64 {
    0.165 - 0.0055 * (n.saturating_sub(9)) as f64
}

fn dist(a: (f64, f64), b: (f64, f64)) -> f64 {
    ((a.0 - b.0).powi(2) + (a.1 - b.1).powi(2)).sqrt()
}

fn lerp(a: (f64, f64), b: (f64, f64), u: f64) -> (f64, f64) {
    (a.0 + (b.0 - a.0) * u, a.1 + (b.1 - a.1) * u)
}

fn in_bounds(p: (f64, f64), size: f64) -> bool {
    let m = size * 0.8;
    p.0 >= m && p.0 <= 1.0 - m && p.1 >= m && p.1 <= BOARD_H - m
}

fn aligned_with(p: (f64, f64), others: &[(f64, f64)]) -> (usize, usize) {
    let ax = others.iter().filter(|o| (o.0 - p.0).abs() < ALIGN).count();
    let ay = others.iter().filter(|o| (o.1 - p.1).abs() < ALIGN).count();
    (ax, ay)
}

/// Irregular, non-overlapping layout (best-candidate sampling with an anti-grid rule).
pub fn layout(rng: &mut Rng, n: usize, size: f64) -> Vec<(f64, f64)> {
    let m = size * 0.8;
    let mut best: Vec<(f64, f64)> = vec![];
    let mut best_sep = -1.0;
    for _ in 0..40 {
        let mut pts: Vec<(f64, f64)> = Vec::with_capacity(n);
        for _ in 0..n {
            let mut pick = None;
            let mut pick_d = -1.0;
            for _ in 0..48 {
                let c = (m + rng.f64() * (1.0 - 2.0 * m), m + rng.f64() * (BOARD_H - 2.0 * m));
                let (ax, ay) = aligned_with(c, &pts);
                if ax >= 2 || ay >= 2 {
                    continue;
                }
                let d = pts.iter().map(|&p| dist(p, c)).fold(f64::MAX, f64::min);
                if d > pick_d {
                    pick_d = d;
                    pick = Some(c);
                }
            }
            match pick {
                Some(c) => pts.push(c),
                None => break,
            }
        }
        if pts.len() < n {
            continue;
        }
        let sep = min_sep(&pts);
        if sep > best_sep {
            best_sep = sep;
            best = pts;
        }
        if best_sep >= SEP * size {
            break;
        }
    }
    best
}

pub fn min_sep(pts: &[(f64, f64)]) -> f64 {
    let mut d = f64::MAX;
    for i in 0..pts.len() {
        for j in i + 1..pts.len() {
            d = d.min(dist(pts[i], pts[j]));
        }
    }
    d
}

const PATH_SAMPLES: [f64; 9] = [0.0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1.0];

/// New positions for a drift of up to `amount` block sizes. Every block moves along a straight
/// line with a shared (eased) parameter, and no two blocks ever come closer than `SEP` sizes on the
/// way. A block that finds no safe move stays where it is.
pub fn drift_targets(rng: &mut Rng, from: &[(f64, f64)], size: f64, amount: f64) -> Vec<(f64, f64)> {
    let n = from.len();
    let sep = SEP * size;
    let mut best = from.to_vec();
    let mut best_moved = 0;
    // A few independent tries; keep the one that moves the most blocks.
    for _ in 0..4 {
        let mut to = from.to_vec();
        let mut order: Vec<usize> = (0..n).collect();
        rng.shuffle(&mut order);
        let mut moved = 0;
        for &i in &order {
            for _ in 0..40 {
                let ang = rng.f64() * std::f64::consts::TAU;
                let len = (0.35 + 0.65 * rng.f64()) * amount * size;
                let cand = (from[i].0 + ang.cos() * len, from[i].1 + ang.sin() * len);
                if !in_bounds(cand, size) {
                    continue;
                }
                let ok = (0..n).filter(|&j| j != i).all(|j| {
                    PATH_SAMPLES.iter().all(|&u| dist(lerp(from[i], cand, u), lerp(from[j], to[j], u)) >= sep)
                });
                if ok {
                    to[i] = cand;
                    moved += 1;
                    break;
                }
            }
        }
        if moved > best_moved {
            best_moved = moved;
            best = to;
        }
        if 4 * moved >= 3 * n {
            break;
        }
    }
    best
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Phase {
    Intro,
    Countdown,
    Ready,
    Show,
    Drift,
    Recall,
    Feedback,
    Replay,
    Done,
}

impl Phase {
    fn key(self) -> &'static str {
        match self {
            Phase::Intro => "intro",
            Phase::Countdown => "countdown",
            Phase::Ready => "ready",
            Phase::Show => "show",
            Phase::Drift => "drift",
            Phase::Recall => "recall",
            Phase::Feedback => "feedback",
            Phase::Replay => "replay",
            Phase::Done => "done",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Debug)]
struct Event {
    block: usize,
    distractor: bool,
}

#[derive(Clone, Copy, Debug)]
struct Trial {
    span: usize,
    reverse: bool,
    ok: bool,
}

pub struct Corsi {
    endless: bool,
    p: Params,
    rng: Rng,
    size: f64,
    pos: Vec<(f64, f64)>,
    rot: Vec<f64>,
    drift_to: Vec<(f64, f64)>,
    phase: Phase,
    phase_ms: f64,
    trial: usize,
    span: usize,
    reverse: bool,
    /// Mixed levels: the order of each trial (`true` = backward).
    dirs: Vec<bool>,
    events: Vec<Event>,
    answer: Vec<usize>,
    taps: Vec<usize>,
    wrong_block: Option<usize>,
    tap_serial: u32,
    last_tap: Option<(usize, bool)>,
    show_serial: u32,
    history: Vec<Trial>,
    // Endless staircase.
    stage: usize,
    stage_tries: usize,
    forward_span: usize,
    backward_span: usize,
    won: bool,
}

pub fn create(level: u32, mode: &str) -> Result<Box<dyn Session>, String> {
    Ok(Box::new(if mode == "endless" { Corsi::endless(time_seed()) } else { Corsi::level(level) }))
}

impl Corsi {
    fn with(p: Params, mut rng: Rng, endless: bool, dirs: Vec<bool>) -> Self {
        let size = block_size(p.blocks);
        let pos = layout(&mut rng, p.blocks, size);
        let rot = (0..p.blocks).map(|_| (rng.f64() - 0.5) * 0.42).collect();
        let mut g = Corsi {
            endless,
            p,
            rng,
            size,
            drift_to: pos.clone(),
            pos,
            rot,
            phase: Phase::Intro,
            phase_ms: 0.0,
            trial: 0,
            span: 0,
            reverse: false,
            dirs,
            events: vec![],
            answer: vec![],
            taps: vec![],
            wrong_block: None,
            tap_serial: 0,
            last_tap: None,
            show_serial: 0,
            history: vec![],
            stage: 0,
            stage_tries: 0,
            forward_span: 0,
            backward_span: 0,
            won: false,
        };
        g.setup_trial();
        g
    }

    pub fn level(level: u32) -> Self {
        let level = level.clamp(1, crate::MAX_LEVEL);
        let p = params(level);
        let dirs = if p.mixed { trial_dirs(level) } else { vec![] };
        Corsi::with(p, Rng::new(seed_for("corsi", level, 0)), false, dirs)
    }

    pub fn endless(seed: u64) -> Self {
        let p = Params {
            blocks: ENDLESS_BLOCKS,
            spans: vec![],
            reverse: false,
            mixed: false,
            interval_ms: ENDLESS_INTERVAL,
            distractors: 0,
            drift: 0.0,
        };
        let mut g = Corsi::with(p, Rng::new(seed), true, vec![]);
        g.span = ENDLESS_START;
        g.setup_trial();
        g
    }

    fn lit_ms(&self) -> f64 {
        self.p.interval_ms * LIT_SHARE
    }

    fn show_ms(&self) -> f64 {
        LEAD_MS + (self.events.len().max(1) - 1) as f64 * self.p.interval_ms + self.lit_ms() + TAIL_MS
    }

    fn replay_ms(&self) -> f64 {
        REPLAY_LEAD_MS + self.answer.len() as f64 * REPLAY_STEP_MS + REPLAY_TAIL_MS
    }

    /// Generate the sequence (and drift) for the current trial; keeps the phase.
    fn setup_trial(&mut self) {
        if self.endless {
            self.reverse = self.stage == 1;
        } else {
            let k = self.trial.min(TRIALS - 1);
            self.span = self.p.spans[k];
            self.reverse = if self.p.mixed { self.dirs[k] } else { self.p.reverse };
        }
        let n = self.p.blocks;
        let span = self.span.min(n);
        let mut all: Vec<usize> = (0..n).collect();
        self.rng.shuffle(&mut all);
        let seq: Vec<usize> = all[..span].to_vec();
        // Distractors go into distinct gaps between targets, never on a neighbouring target.
        let mut gaps: Vec<usize> = (1..span).collect();
        self.rng.shuffle(&mut gaps);
        let mut gap_set = gaps[..self.p.distractors.min(gaps.len())].to_vec();
        gap_set.sort_unstable();
        let mut events = Vec::with_capacity(span + gap_set.len());
        for (k, &b) in seq.iter().enumerate() {
            if gap_set.contains(&k) {
                let prev = seq[k - 1];
                let choices: Vec<usize> = (0..n).filter(|&x| x != prev && x != b).collect();
                events.push(Event { block: *self.rng.pick(&choices), distractor: true });
            }
            events.push(Event { block: b, distractor: false });
        }
        self.events = events;
        self.answer = if self.reverse { seq.iter().rev().copied().collect() } else { seq };
        self.taps.clear();
        self.wrong_block = None;
        self.last_tap = None;
        self.drift_to =
            if self.p.drift > 0.0 { drift_targets(&mut self.rng, &self.pos, self.size, self.p.drift) } else { self.pos.clone() };
    }

    fn enter(&mut self, ph: Phase) {
        self.phase = ph;
        self.phase_ms = 0.0;
        if matches!(ph, Phase::Show | Phase::Replay) {
            self.show_serial += 1;
        }
    }

    fn correct(&self) -> usize {
        self.history.iter().filter(|t| t.ok).count()
    }

    fn wrong(&self) -> usize {
        self.history.len() - self.correct()
    }

    fn stars(&self) -> u32 {
        if self.endless || !self.won {
            return 0;
        }
        match self.correct() {
            6.. => 3,
            5 => 2,
            _ => 1,
        }
    }

    fn finish_trial(&mut self, ok: bool) {
        self.history.push(Trial { span: self.span, reverse: self.reverse, ok });
        self.enter(if ok { Phase::Feedback } else { Phase::Replay });
    }

    /// After the feedback / replay of a trial: next trial, next stage or the end.
    fn advance(&mut self) {
        if self.endless {
            let ok = self.history.last().map(|t| t.ok).unwrap_or(false);
            self.stage_tries += 1;
            let stage_over = if ok {
                if self.stage == 0 {
                    self.forward_span = self.span;
                } else {
                    self.backward_span = self.span;
                }
                self.span += 1;
                self.stage_tries = 0;
                self.span > ENDLESS_BLOCKS
            } else {
                self.stage_tries >= 2
            };
            if stage_over {
                let best = |s: usize| if s == 0 { ENDLESS_START - 1 } else { s };
                if self.stage == 0 {
                    self.forward_span = best(self.forward_span);
                    self.stage = 1;
                    self.stage_tries = 0;
                    self.span = ENDLESS_START;
                    self.setup_trial();
                    self.enter(Phase::Intro);
                } else {
                    self.backward_span = best(self.backward_span);
                    self.enter(Phase::Done);
                }
                return;
            }
            self.setup_trial();
            self.enter(Phase::Ready);
            return;
        }
        let correct = self.correct();
        let wrong = self.wrong();
        if 2 * (TRIALS - wrong) < TRIALS {
            self.won = false;
            self.enter(Phase::Done);
        } else if self.history.len() >= TRIALS {
            self.won = 2 * correct >= TRIALS;
            self.enter(Phase::Done);
        } else {
            self.trial += 1;
            self.setup_trial();
            self.enter(Phase::Ready);
        }
    }

    fn after_show(&mut self) {
        if self.drift_to != self.pos {
            self.enter(Phase::Drift);
        } else {
            self.enter(Phase::Recall);
        }
    }

    fn score(&self) -> usize {
        self.forward_span + self.backward_span
    }

    fn current_blocks(&self) -> Vec<(f64, f64)> {
        if self.phase == Phase::Drift {
            let u = (self.phase_ms / DRIFT_MS).clamp(0.0, 1.0);
            let e = u * u * (3.0 - 2.0 * u);
            self.pos.iter().zip(&self.drift_to).map(|(&a, &b)| lerp(a, b, e)).collect()
        } else {
            self.pos.clone()
        }
    }

    fn lit(&self) -> Value {
        match self.phase {
            Phase::Show => {
                let rel = self.phase_ms - LEAD_MS;
                if rel < 0.0 {
                    return Value::Null;
                }
                let k = (rel / self.p.interval_ms) as usize;
                let within = rel - k as f64 * self.p.interval_ms;
                match self.events.get(k) {
                    Some(e) if within < self.lit_ms() => json!({
                        "block": e.block,
                        "kind": if e.distractor { "distractor" } else { "target" },
                        "index": k,
                        "t": within / self.lit_ms(),
                        "key": self.show_serial * 100 + k as u32,
                    }),
                    _ => Value::Null,
                }
            }
            Phase::Replay => {
                let rel = self.phase_ms - REPLAY_LEAD_MS;
                if rel < 0.0 {
                    return Value::Null;
                }
                let k = (rel / REPLAY_STEP_MS) as usize;
                let within = rel - k as f64 * REPLAY_STEP_MS;
                let lit = REPLAY_STEP_MS * 0.72;
                match self.answer.get(k) {
                    Some(&b) if within < lit => json!({
                        "block": b, "kind": "replay", "index": k, "t": within / lit,
                        "key": self.show_serial * 100 + k as u32,
                    }),
                    _ => Value::Null,
                }
            }
            _ => Value::Null,
        }
    }

    /// Whether the current trial's order may be shown: always on fixed levels, and on mixed levels
    /// only from the moment recall starts.
    fn dir_revealed(&self) -> bool {
        !self.p.mixed || matches!(self.phase, Phase::Recall | Phase::Feedback | Phase::Replay | Phase::Done)
    }

    fn status(&self) -> &'static str {
        match self.phase {
            Phase::Done if self.endless || !self.won => "lost",
            Phase::Done => "won",
            _ => "playing",
        }
    }

    fn dir(reverse: bool) -> &'static str {
        if reverse {
            "Geri"
        } else {
            "İleri"
        }
    }

    fn summary(&self) -> String {
        if self.endless {
            return format!(
                "İleri açıklık {} · Geri açıklık {} · Toplam {}",
                self.forward_span,
                self.backward_span,
                self.score()
            );
        }
        let max_span = self.p.spans.iter().max().copied().unwrap_or(0);
        let order = if self.p.mixed { "Karışık".to_string() } else { Self::dir(self.p.reverse).to_string() };
        let base = format!("Doğru {}/{} · Uzunluk {} · {order} sıra", self.correct(), self.history.len(), max_span);
        if self.phase == Phase::Done && !self.won {
            format!("{base} · En az {} doğru gerekiyordu", TRIALS / 2)
        } else {
            base
        }
    }

    fn goal(&self) -> String {
        if self.endless {
            return if self.stage == 0 {
                "Kapasite testi · İleri sıra: her başarıda dizi bir uzar".into()
            } else {
                "Kapasite testi · Geri sıra: yanan sırayı tersten dokun".into()
            };
        }
        let lo = self.p.spans.iter().min().copied().unwrap_or(0);
        let hi = self.p.spans.iter().max().copied().unwrap_or(0);
        let len = if lo == hi { format!("{lo}") } else { format!("{lo}–{hi}") };
        let how = if self.p.mixed {
            "aynı ya da ters sırayla dokun; yön gösterimden sonra açıklanır"
        } else if self.p.reverse {
            "tersten (sondan başa) dokun"
        } else {
            "yanış sırasıyla dokun"
        };
        let mut g = format!("{TRIALS} deneme · bloklara {how} · dizi {len}");
        if self.p.distractors > 0 {
            g.push_str(" · bordo flaşları yok say");
        }
        if self.p.drift > 0.0 {
            g.push_str(" · bloklar kayar");
        }
        g
    }

    fn title(&self) -> String {
        if self.endless {
            return if self.stage == 0 { "İleri".into() } else { "Geri".into() };
        }
        let order = if self.p.mixed { "Karışık yön" } else { Self::dir(self.p.reverse) };
        let mut t = format!("{order} · {} blok", self.p.blocks);
        if self.p.drift > 0.0 {
            t.push_str(" · kayan");
        } else if self.p.distractors > 0 {
            t.push_str(" · tuzaklı");
        }
        t
    }
}

impl Session for Corsi {
    fn state(&self) -> Value {
        let reveal = matches!(self.phase, Phase::Feedback | Phase::Replay | Phase::Done);
        let mut v = json!({
            "status": self.status(),
            "stars": self.stars(),
            "mode": if self.endless { "endless" } else { "level" },
            "phase": self.phase.key(),
            "title": self.title(),
            "goal": self.goal(),
            "summary": self.summary(),
            "board_h": BOARD_H,
            "block_size": self.size,
            "blocks": self.current_blocks().iter().map(|p| json!([p.0, p.1])).collect::<Vec<_>>(),
            "rot": self.rot,
            "lit": self.lit(),
            "trial": self.trial,
            "trials": if self.endless { 0 } else { TRIALS },
            "span": self.span,
            "reverse": if self.dir_revealed() { json!(self.reverse) } else { Value::Null },
            "mixed": self.p.mixed,
            "interval_ms": self.p.interval_ms,
            "distractors": self.p.distractors,
            "drifting": self.drift_to != self.pos,
            "taps": self.taps,
            "answer": if reveal { json!(self.answer) } else { Value::Null },
            "last_tap": self.last_tap.map(|(b, ok)| json!({"block": b, "ok": ok, "serial": self.tap_serial})),
            "wrong_block": self.wrong_block,
            "results": self.history.iter().map(|t| t.ok).collect::<Vec<_>>(),
            "correct": self.correct(),
            "wrong": self.wrong(),
            "countdown_ms": if self.phase == Phase::Countdown { (COUNTDOWN_MS - self.phase_ms).max(0.0) } else { 0.0 },
            "stage": if self.stage == 0 { "forward" } else { "backward" },
            "forward_span": self.forward_span,
            "backward_span": self.backward_span,
            "history": self.history.iter().map(|t| json!({"span": t.span, "reverse": t.reverse, "ok": t.ok})).collect::<Vec<_>>(),
        });
        if self.endless {
            v["score"] = json!(self.score());
        }
        v
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if a["start"].as_bool() == Some(true) {
            if self.phase != Phase::Intro {
                return Err("Zaten başladı".into());
            }
            self.enter(Phase::Countdown);
            return Ok(());
        }
        let Some(b) = a["tap"].as_u64() else {
            return Err("Bilinmeyen hamle".into());
        };
        let b = b as usize;
        match self.phase {
            Phase::Recall => {}
            Phase::Intro => return Err("Önce Başla'ya dokun".into()),
            Phase::Done => return Err("Bölüm bitti".into()),
            Phase::Countdown | Phase::Ready | Phase::Show | Phase::Drift => return Err("Önce sırayı izle".into()),
            Phase::Feedback | Phase::Replay => return Err("Sonraki deneme hazırlanıyor".into()),
        }
        if b >= self.p.blocks {
            return Err("Geçersiz blok".into());
        }
        if self.taps.contains(&b) {
            return Err("Bu bloğa zaten dokundun".into());
        }
        let ok = self.answer[self.taps.len()] == b;
        self.taps.push(b);
        self.tap_serial += 1;
        self.last_tap = Some((b, ok));
        if !ok {
            self.wrong_block = Some(b);
            self.finish_trial(false);
        } else if self.taps.len() == self.answer.len() {
            self.finish_trial(true);
        }
        Ok(())
    }

    fn tick(&mut self, dt_ms: f64) {
        self.phase_ms += dt_ms;
        match self.phase {
            Phase::Countdown if self.phase_ms >= COUNTDOWN_MS => self.enter(Phase::Show),
            Phase::Ready if self.phase_ms >= READY_MS => self.enter(Phase::Show),
            Phase::Show if self.phase_ms >= self.show_ms() => self.after_show(),
            Phase::Drift if self.phase_ms >= DRIFT_MS => {
                self.pos = self.drift_to.clone();
                self.enter(Phase::Recall);
            }
            Phase::Feedback if self.phase_ms >= FEEDBACK_MS => self.advance(),
            Phase::Replay if self.phase_ms >= self.replay_ms() => self.advance(),
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LEVELS: [u32; 9] = [1, 2, 3, 50, 137, 250, 400, 499, 500];

    fn to_recall(g: &mut Corsi) {
        let mut guard = 0;
        while g.phase != Phase::Recall {
            assert!(g.phase != Phase::Done && g.phase != Phase::Intro, "stuck in {:?}", g.phase);
            g.tick(16.0);
            guard += 1;
            assert!(guard < 5000);
        }
    }

    fn to_next(g: &mut Corsi) {
        let mut guard = 0;
        while matches!(g.phase, Phase::Feedback | Phase::Replay) {
            g.tick(16.0);
            guard += 1;
            assert!(guard < 5000);
        }
    }

    /// Play one trial: right answer when `ok`, else a wrong first tap.
    fn play(g: &mut Corsi, ok: bool) {
        to_recall(g);
        if ok {
            for b in g.answer.clone() {
                g.act(&json!({ "tap": b })).unwrap();
            }
        } else {
            let wrong = (0..g.p.blocks).find(|&b| b != g.answer[0]).unwrap();
            g.act(&json!({ "tap": wrong })).unwrap();
        }
        to_next(g);
    }

    #[test]
    fn params_curve() {
        for l in LEVELS {
            let p = params(l);
            assert!((9..=16).contains(&p.blocks), "{l}");
            assert_eq!(p.spans.len(), TRIALS);
            assert!(p.spans.windows(2).all(|w| w[0] <= w[1]));
            assert!(*p.spans.iter().min().unwrap() >= 3 && *p.spans.iter().max().unwrap() <= 11);
            assert!(p.spans.iter().all(|&s| s + 3 <= p.blocks));
            assert!((450.0..=900.0).contains(&p.interval_ms));
            assert!(p.distractors <= 3);
        }
        assert_eq!(params(1).spans, vec![4; 6]);
        assert!(params(2).spans.iter().sum::<usize>() > params(1).spans.iter().sum::<usize>());
        let p = params(500);
        assert_eq!((p.blocks, p.spans[0], p.reverse), (16, 11, false));
        assert!((p.interval_ms - 450.0).abs() < 1e-9);
        assert!(params(12).reverse && !params(13).reverse);
        assert!(params(41).distractors >= 1 && params(401).distractors == 3 && params(44).distractors == 0);
        assert!(params(152).drift > 0.0 && params(151).drift == 0.0);
        for l in 1..499 {
            assert!(span_curve(l + 1) >= span_curve(l));
        }
    }

    #[test]
    fn layouts_never_overlap_and_are_irregular() {
        for l in 1..=500 {
            let g = Corsi::level(l);
            assert_eq!(g.pos.len(), g.p.blocks, "level {l}");
            assert!(min_sep(&g.pos) >= SEP * g.size - 1e-9, "level {l}: overlap {}", min_sep(&g.pos));
            for (i, &p) in g.pos.iter().enumerate() {
                assert!(in_bounds(p, g.size));
                let others: Vec<_> = g.pos.iter().enumerate().filter(|&(j, _)| j != i).map(|(_, &q)| q).collect();
                let (ax, ay) = aligned_with(p, &others);
                assert!(ax <= 2 && ay <= 2, "level {l}: grid-like alignment");
            }
        }
    }

    #[test]
    fn drift_paths_keep_blocks_apart() {
        for l in (150..=500).filter(|l| params(*l).drift > 0.0) {
            let mut g = Corsi::level(l);
            g.act(&json!({"start": true})).unwrap();
            assert_ne!(g.drift_to, g.pos, "level {l} should drift");
            let moved = g.pos.iter().zip(&g.drift_to).filter(|(a, b)| a != b).count();
            assert!(2 * moved >= g.p.blocks, "level {l}: only {moved} blocks drift");
            for _ in 0..3 {
                for k in 0..=20 {
                    let u = k as f64 / 20.0;
                    let pts: Vec<_> = g.pos.iter().zip(&g.drift_to).map(|(&a, &b)| lerp(a, b, u)).collect();
                    assert!(min_sep(&pts) >= SEP * g.size * 0.98, "level {l} u={u}");
                    assert!(pts.iter().all(|&p| in_bounds(p, g.size)));
                }
                play(&mut g, true);
            }
        }
    }

    #[test]
    fn deterministic() {
        for l in LEVELS {
            let (mut a, mut b) = (Corsi::level(l), Corsi::level(l));
            assert_eq!(a.pos, b.pos);
            assert_eq!(a.rot, b.rot);
            for _ in 0..3 {
                assert_eq!(a.answer, b.answer);
                assert_eq!(a.events, b.events);
                a.act(&json!({"start": true})).ok();
                b.act(&json!({"start": true})).ok();
                play(&mut a, true);
                play(&mut b, true);
            }
        }
    }

    #[test]
    fn sequences_and_answers() {
        for l in LEVELS {
            let mut g = Corsi::level(l);
            g.act(&json!({"start": true})).unwrap();
            for _ in 0..TRIALS {
                let targets: Vec<usize> = g.events.iter().filter(|e| !e.distractor).map(|e| e.block).collect();
                assert_eq!(targets.len(), g.span);
                let mut uniq = targets.clone();
                uniq.sort_unstable();
                uniq.dedup();
                assert_eq!(uniq.len(), targets.len(), "no repeats");
                let expect: Vec<usize> = if g.reverse { targets.iter().rev().copied().collect() } else { targets };
                assert_eq!(g.answer, expect);
                assert_eq!(g.events.iter().filter(|e| e.distractor).count(), g.p.distractors.min(g.span - 1));
                // A distractor never sits on a neighbouring target.
                for w in g.events.windows(2) {
                    assert_ne!(w[0].block, w[1].block);
                }
                play(&mut g, true);
            }
            assert_eq!(g.status(), "won");
            assert_eq!(g.stars(), 3);
        }
    }

    #[test]
    fn show_lights_every_event_in_order() {
        let mut g = Corsi::level(50);
        g.act(&json!({"start": true})).unwrap();
        let mut seen: Vec<(usize, String)> = vec![];
        let mut guard = 0;
        while g.phase != Phase::Recall {
            g.tick(10.0);
            let lit = g.lit();
            if lit.is_object() {
                let item = (lit["block"].as_u64().unwrap() as usize, lit["kind"].as_str().unwrap().to_string());
                if seen.last() != Some(&item) {
                    seen.push(item);
                }
            }
            guard += 1;
            assert!(guard < 10000);
        }
        let expect: Vec<(usize, String)> = g
            .events
            .iter()
            .map(|e| (e.block, if e.distractor { "distractor" } else { "target" }.to_string()))
            .collect();
        assert_eq!(seen, expect);
    }

    #[test]
    fn reverse_level_requires_reverse_order() {
        let mut g = Corsi::level(12);
        assert!(g.p.reverse);
        g.act(&json!({"start": true})).unwrap();
        to_recall(&mut g);
        let forward: Vec<usize> = g.events.iter().filter(|e| !e.distractor).map(|e| e.block).collect();
        // Tapping the first lit block first is wrong in backward mode.
        g.act(&json!({ "tap": forward[0] })).unwrap();
        assert_eq!(g.phase, Phase::Replay);
        assert_eq!(g.history.last().map(|t| t.ok), Some(false));
        assert_eq!(g.wrong_block, Some(forward[0]));
    }

    #[test]
    fn mixed_order_starts_after_the_fixed_tiers() {
        for l in 1..MIXED_FROM {
            assert!(!params(l).mixed, "level {l} should keep a fixed order");
        }
        for l in 1..12 {
            assert!(!params(l).reverse, "level {l} should be forward");
        }
        let mixed: Vec<u32> = (MIXED_FROM..=500).filter(|&l| params(l).mixed).collect();
        assert!(mixed.len() > 300);
        for l in MIXED_FROM..=500 {
            let p = params(l);
            assert!(!p.reverse, "level {l}: no announced backward levels once mixing starts");
            assert_eq!(p.mixed, l % 4 != 0);
        }
        for &l in &mixed {
            let d = trial_dirs(l);
            assert_eq!(d, trial_dirs(l), "level {l}: deterministic");
            let back = d.iter().filter(|&&b| b).count();
            assert!((2..=TRIALS - 2).contains(&back), "level {l}: {back} backward");
        }
        // Not the same pattern on every level.
        assert!(mixed.windows(2).any(|w| trial_dirs(w[0]) != trial_dirs(w[1])));
    }

    #[test]
    fn mixed_direction_hidden_until_recall_then_scored() {
        let level = (MIXED_FROM..=60).find(|&l| params(l).mixed && params(l).drift == 0.0).unwrap();
        let mut g = Corsi::level(level);
        assert_eq!(g.state()["mixed"], true);
        assert!(g.state()["reverse"].is_null());
        g.act(&json!({"start": true})).unwrap();
        let (mut saw_fwd, mut saw_back) = (false, false);
        for k in 0..TRIALS {
            // Hidden for the whole presentation.
            let mut guard = 0;
            while g.phase != Phase::Recall {
                assert!(g.state()["reverse"].is_null(), "trial {k}: order leaked in {:?}", g.phase);
                assert!(g.state()["answer"].is_null());
                g.tick(16.0);
                guard += 1;
                assert!(guard < 5000);
            }
            // Revealed at recall, and it is this trial's drawn order.
            let st = g.state();
            assert_eq!(st["reverse"], g.dirs[k], "trial {k}");
            assert_eq!(g.reverse, g.dirs[k]);
            let shown: Vec<usize> = g.events.iter().filter(|e| !e.distractor).map(|e| e.block).collect();
            if g.reverse {
                saw_back = true;
                // The order as shown is wrong on a backward trial (span ≥ 2, so the first tap differs).
                let mut probe = Corsi::level(level);
                probe.act(&json!({"start": true})).unwrap();
                for _ in 0..k {
                    play(&mut probe, true);
                }
                to_recall(&mut probe);
                probe.act(&json!({"tap": shown[0]})).unwrap();
                assert_eq!(probe.history.last().map(|t| t.ok), Some(false));
                assert_eq!(g.answer, shown.iter().rev().copied().collect::<Vec<_>>());
            } else {
                saw_fwd = true;
                assert_eq!(g.answer, shown);
            }
            for b in g.answer.clone() {
                g.act(&json!({ "tap": b })).unwrap();
            }
            assert_eq!(g.history.last().map(|t| (t.ok, t.reverse)), Some((true, g.dirs[k])));
            to_next(&mut g);
        }
        assert!(saw_fwd && saw_back);
        assert_eq!(g.status(), "won");
        assert_eq!(g.stars(), 3);
    }

    #[test]
    fn fixed_levels_show_their_order_up_front() {
        for l in [1, 12, 13, 32] {
            let g = Corsi::level(l);
            assert!(!g.p.mixed);
            assert_eq!(g.state()["reverse"], g.p.reverse, "level {l}");
        }
    }

    #[test]
    fn illegal_taps_rejected_without_change() {
        let mut g = Corsi::level(1);
        assert!(g.act(&json!({"tap": 0})).is_err()); // intro
        g.act(&json!({"start": true})).unwrap();
        assert!(g.act(&json!({"start": true})).is_err());
        g.tick(COUNTDOWN_MS + 1.0);
        assert_eq!(g.phase, Phase::Show);
        let before = g.state();
        assert!(g.act(&json!({"tap": 0})).is_err()); // during show
        assert_eq!(g.state(), before);
        to_recall(&mut g);
        let first = g.answer[0];
        g.act(&json!({ "tap": first })).unwrap();
        let before = g.state();
        assert!(g.act(&json!({ "tap": first })).is_err()); // repeat
        assert!(g.act(&json!({"tap": 99})).is_err()); // out of range
        assert!(g.act(&json!({"bogus": 1})).is_err());
        assert_eq!(g.state(), before);
    }

    #[test]
    fn wrong_tap_replays_answer() {
        let mut g = Corsi::level(1);
        g.act(&json!({"start": true})).unwrap();
        to_recall(&mut g);
        let wrong = (0..9).find(|&b| b != g.answer[0]).unwrap();
        let answer = g.answer.clone();
        g.act(&json!({ "tap": wrong })).unwrap();
        assert_eq!(g.state()["phase"], "replay");
        assert!(g.state()["answer"].is_array());
        let mut replayed = vec![];
        while g.phase == Phase::Replay {
            g.tick(10.0);
            let lit = g.lit();
            if lit.is_object() {
                let b = lit["block"].as_u64().unwrap() as usize;
                if replayed.last() != Some(&b) {
                    replayed.push(b);
                }
            }
        }
        assert_eq!(replayed, answer);
        assert_eq!(g.phase, Phase::Ready);
        assert_eq!(g.trial, 1);
    }

    #[test]
    fn scoring() {
        let run = |pattern: &[bool]| {
            let mut g = Corsi::level(5);
            g.act(&json!({"start": true})).unwrap();
            for &ok in pattern {
                if g.phase == Phase::Done {
                    break;
                }
                play(&mut g, ok);
            }
            (g.status(), g.stars(), g.history.len())
        };
        assert_eq!(run(&[true; 6]), ("won", 3, 6));
        assert_eq!(run(&[false, true, true, true, true, true]), ("won", 2, 6));
        assert_eq!(run(&[false, false, true, true, true, true]), ("won", 1, 6));
        assert_eq!(run(&[false, false, false, true, true, true]), ("won", 1, 6));
        // 4 wrong: 3 correct is out of reach → lost right away.
        assert_eq!(run(&[false, true, false, false, false, true]), ("lost", 0, 5));
        assert_eq!(run(&[false; 6]), ("lost", 0, 4));
    }

    #[test]
    fn endless_staircase_reaches_lost() {
        // Always wrong: span 2 forward, span 2 backward.
        let mut g = Corsi::endless(7);
        g.act(&json!({"start": true})).unwrap();
        let mut guard = 0;
        while g.phase != Phase::Done {
            if g.phase == Phase::Intro {
                assert_eq!(g.stage, 1);
                g.act(&json!({"start": true})).unwrap();
            }
            play(&mut g, false);
            guard += 1;
            assert!(guard < 20);
        }
        assert_eq!(g.status(), "lost");
        assert_eq!(g.state()["score"], 4);

        // Perfect up to span 6 forward and 5 backward, with a miss-then-hit on the way.
        let mut g = Corsi::endless(9);
        g.act(&json!({"start": true})).unwrap();
        let mut guard = 0;
        let mut missed_once = false;
        while g.phase != Phase::Done {
            if g.phase == Phase::Intro {
                g.act(&json!({"start": true})).unwrap();
            }
            to_recall(&mut g);
            let limit = if g.stage == 0 { 6 } else { 5 };
            let ok = if g.span == 4 && !missed_once {
                missed_once = true;
                false
            } else {
                g.span <= limit
            };
            if ok {
                for b in g.answer.clone() {
                    g.act(&json!({ "tap": b })).unwrap();
                }
            } else {
                let wrong = (0..g.p.blocks).find(|&b| b != g.answer[0]).unwrap();
                g.act(&json!({ "tap": wrong })).unwrap();
            }
            to_next(&mut g);
            guard += 1;
            assert!(guard < 40);
        }
        assert_eq!((g.forward_span, g.backward_span), (6, 5));
        assert_eq!(g.state()["score"], 11);
        assert_eq!(g.status(), "lost");
        assert_eq!(g.state()["stars"], 0);
    }

    #[test]
    #[ignore]
    fn timing_500_levels() {
        let t = std::time::Instant::now();
        for l in 1..=500 {
            let _ = Corsi::level(l);
        }
        println!("corsi: 500 levels in {:?}", t.elapsed());
        for l in LEVELS {
            let p = params(l);
            println!("L{l}: {:?}", p);
        }
    }
}
