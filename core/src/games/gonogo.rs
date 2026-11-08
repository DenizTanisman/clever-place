//! Dur ya da Geç — response inhibition with a rule set that grows: shapes, then arrows to follow,
//! then arrows to reverse.
//!
//! Every stimulus is a jewel **shape**, either **round** or **square** (angular). A shape may also
//! carry an **arrow** (up/down/left/right) in **emerald** or **burgundy**. The rules:
//! - **Square → never respond.** No tap, no swipe, whatever arrow it carries (a correct withhold).
//! - **Round, no arrow → tap** the screen.
//! - **Round with an emerald arrow → swipe in the arrow's direction.**
//! - **Round with a burgundy arrow → swipe in the opposite direction.**
//!
//! Errors: any response to a square (*commission*), no response in time when one was needed
//! (*omission*), a swipe in the wrong direction (*wrong_dir*), a tap where a swipe was needed
//! (*need_swipe*), a swipe where a tap was needed (*need_tap*), and any tap or swipe during the gap
//! between stimuli (*early*). `judge(stim, response)` is the single rule table.
//!
//! Timeline of a trial: gap (`iti`, ±30 % jitter) → response window (`window` ms; the stimulus is
//! visible for `stim_ms` of it). A response ends the window at once, so the stream follows the
//! player's rhythm. Reaction time is the core's clock when the tap/swipe arrives. The view sends
//! `{"press":true}` when a finger lands inside a window: a finger that is still down when the window
//! closes gets `GRACE_MS` more to finish its gesture. A second response within 120 ms of the last
//! is ignored (finger bounce).
//!
//! Scoring: **balanced accuracy** = mean over the response categories present (tap, swipe, stop) of
//! the share answered correctly; early responses count as failed stop trials. Tapping everything
//! therefore scores ≈ 33–50 %, never a pass.
//! Stars: accuracy ≥ 90 % and mean RT of correct responses ≤ `rt_goal` → 3; ≥ 80 % → 2; ≥ 70 % → 1;
//! below 70 % → `lost`. `rt_goal` is the level's tap goal and swipe goal, weighted by how many tap
//! and swipe trials the show has.
//!
//! Level curve (`params(level)`), t = (level − 1) / 499:
//! - Rules arrive one by one: 1–5 round/square only · 6–8 emerald arrows (left/right) · 9–11
//!   emerald arrows in four directions · 12–14 burgundy arrows join (left/right) · 15+ everything in
//!   four directions · 25+ lures: arrows on squares (25 % → 60 % of the squares).
//! - Shows grow from 20 to 40 trials. Squares 25 % → 35 %; arrows on 40 % → 70 % of the rounds;
//!   half of the arrows burgundy once they are in.
//! - Windows shrink: tap/stop 1100 → 550 ms, arrows 1500 → 850 ms; gap 800 → 400 ms. From 120 the
//!   stimulus vanishes before the window ends (700 → 400 ms visible).
//! - RT goals: tap 650 → 450 ms, swipe 850 → 600 ms.
//!
//! Endless ("Sonsuz akış"): the full rule set, 3 lives, every error costs one. Speed is adaptive:
//! a speed value s ∈ [0, 1] rises by 0.02 per correct trial and falls by 0.1 per error, and the
//! stream uses the parameters of virtual level 15 + 485 s (windows, gaps, arrows, lures).
//! `score` = correct trials (taps, swipes and correct withholds). `lost` when the lives run out.
//!
//! State: `{status, stars, title, goal, summary?, score?, mode, phase: "intro"|"countdown"|"run"|
//!          "done", stage: "iti"|"window"|null, stage_ms, stage_len, countdown_ms, trial, trials,
//!          lives?, features: [..], rules: {arrows, burgundy, four_dirs, lures}, new_rules: [..],
//!          stim: {id, shape: "round"|"square", arrow: {dir, color: "emerald"|"burgundy"}|null}|null,
//!          pressed, fb: {serial, result, rt|null, expect: "tap"|"swipe"|"stop"|null, dir|null,
//!          input: "tap"|dir|null}, stats: {...}, accuracy, mean_rt, rt_goal, speed?}`
//! Actions: `{"start":true}` · `{"press":true}` · `{"tap":true}` · `{"swipe":"up"|"down"|"left"|"right"}`

use crate::rng::{seed_for, time_seed, Rng};
use crate::Session;
use serde_json::{json, Value};

pub const COUNTDOWN_MS: f64 = 3000.0;
pub const LIVES: u32 = 3;
pub const GRACE_MS: f64 = 300.0;
const DEBOUNCE_MS: f64 = 120.0;
/// Endless: speed gained per correct trial and lost per error.
pub const SPEED_UP: f64 = 0.02;
pub const SPEED_DOWN: f64 = 0.1;

// ------------------------------------------------------------------ the rule table

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Shape {
    Round,
    Square,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dir {
    Up,
    Down,
    Left,
    Right,
}

impl Dir {
    pub const ALL: [Dir; 4] = [Dir::Up, Dir::Down, Dir::Left, Dir::Right];

    pub fn opposite(self) -> Dir {
        match self {
            Dir::Up => Dir::Down,
            Dir::Down => Dir::Up,
            Dir::Left => Dir::Right,
            Dir::Right => Dir::Left,
        }
    }
    pub fn key(self) -> &'static str {
        match self {
            Dir::Up => "up",
            Dir::Down => "down",
            Dir::Left => "left",
            Dir::Right => "right",
        }
    }
    pub fn parse(s: &str) -> Option<Dir> {
        Dir::ALL.into_iter().find(|d| d.key() == s)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ink {
    Emerald,
    Burgundy,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Arrow {
    pub dir: Dir,
    pub ink: Ink,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Stim {
    pub shape: Shape,
    pub arrow: Option<Arrow>,
}

/// What a stimulus asks for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Expect {
    Stop,
    Tap,
    Swipe(Dir),
}

pub fn expected(s: Stim) -> Expect {
    match (s.shape, s.arrow) {
        (Shape::Square, _) => Expect::Stop,
        (Shape::Round, None) => Expect::Tap,
        (Shape::Round, Some(Arrow { dir, ink: Ink::Emerald })) => Expect::Swipe(dir),
        (Shape::Round, Some(Arrow { dir, ink: Ink::Burgundy })) => Expect::Swipe(dir.opposite()),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Response {
    Tap,
    Swipe(Dir),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// Tap on a plain round shape.
    Hit,
    /// Swipe in the required direction.
    SwipeOk,
    /// Correct withhold on a square.
    Reject,
    /// Any response to a square.
    Commission,
    /// No response when one was needed.
    Omission,
    /// Swipe in the wrong direction.
    WrongDir,
    /// Tap where a swipe was needed.
    NeedSwipe,
    /// Swipe where a tap was needed.
    NeedTap,
}

impl Outcome {
    pub fn ok(self) -> bool {
        matches!(self, Outcome::Hit | Outcome::SwipeOk | Outcome::Reject)
    }
    pub fn key(self) -> &'static str {
        match self {
            Outcome::Hit => "hit",
            Outcome::SwipeOk => "swipe_ok",
            Outcome::Reject => "reject",
            Outcome::Commission => "commission",
            Outcome::Omission => "omission",
            Outcome::WrongDir => "wrong_dir",
            Outcome::NeedSwipe => "need_swipe",
            Outcome::NeedTap => "need_tap",
        }
    }
}

/// The whole rule set: how a response (or none) to a stimulus is scored.
pub fn judge(s: Stim, r: Option<Response>) -> Outcome {
    use Outcome::*;
    match (expected(s), r) {
        (Expect::Stop, None) => Reject,
        (Expect::Stop, Some(_)) => Commission,
        (Expect::Tap, Some(Response::Tap)) => Hit,
        (Expect::Tap, Some(Response::Swipe(_))) => NeedTap,
        (Expect::Tap, None) => Omission,
        (Expect::Swipe(d), Some(Response::Swipe(e))) if d == e => SwipeOk,
        (Expect::Swipe(_), Some(Response::Swipe(_))) => WrongDir,
        (Expect::Swipe(_), Some(Response::Tap)) => NeedSwipe,
        (Expect::Swipe(_), None) => Omission,
    }
}

// ------------------------------------------------------------------ level curve

#[derive(Clone, Debug, PartialEq)]
pub struct Params {
    pub trials: usize,
    /// Share of squares (stop trials).
    pub p_square: f64,
    /// Share of round shapes that carry an arrow.
    pub p_arrow: f64,
    /// Share of arrows that are burgundy.
    pub p_burgundy: f64,
    /// Up/down arrows as well as left/right.
    pub four_dirs: bool,
    /// Share of squares that carry an arrow (lures).
    pub p_lure: f64,
    /// Response window for stimuli without an arrow.
    pub tap_ms: f64,
    /// Response window for stimuli with an arrow (lures included, so the pace gives nothing away).
    pub swipe_ms: f64,
    /// Visible time of the stimulus (infinite = the whole window).
    pub stim_ms: f64,
    pub iti_ms: f64,
    pub tap_goal: f64,
    pub swipe_goal: f64,
}

impl Params {
    pub fn arrows(&self) -> bool {
        self.p_arrow > 0.0
    }
    pub fn burgundy(&self) -> bool {
        self.p_burgundy > 0.0
    }
    pub fn lures(&self) -> bool {
        self.p_lure > 0.0
    }
    pub fn short(&self) -> bool {
        self.stim_ms.is_finite()
    }
    fn dirs(&self) -> &'static [Dir] {
        if self.four_dirs {
            &Dir::ALL
        } else {
            &[Dir::Left, Dir::Right]
        }
    }
}

/// Level → parameters. See the module docs for the curve.
pub fn params(level: u32) -> Params {
    let l = level.clamp(1, crate::MAX_LEVEL);
    let t = (l - 1) as f64 / 499.0;
    let (p_arrow, p_burgundy, four_dirs) = match l {
        1..=5 => (0.0, 0.0, false),
        6..=8 => (0.4, 0.0, false),
        9..=11 => (0.45, 0.0, true),
        12..=14 => (0.5, 0.4, false),
        _ => (0.5 + 0.2 * t, 0.5, true),
    };
    Params {
        trials: 20 + 2 * (10.0 * t.powf(0.8)).round() as usize,
        p_square: if l <= 3 { 0.25 } else { 0.3 + 0.05 * t },
        p_arrow,
        p_burgundy,
        four_dirs,
        p_lure: if l < 25 { 0.0 } else { 0.25 + 0.35 * t },
        tap_ms: (1100.0 - 550.0 * t).round(),
        swipe_ms: (1500.0 - 650.0 * t).round(),
        stim_ms: if l < 120 { f64::INFINITY } else { (700.0 - 300.0 * (l - 120) as f64 / 380.0).round() },
        iti_ms: (800.0 - 400.0 * t).round(),
        tap_goal: (650.0 - 200.0 * t).round(),
        swipe_goal: (850.0 - 250.0 * t).round(),
    }
}

/// Rules that are on at `level` but were off at the level before (for the "Yeni" badges).
pub fn new_rules(level: u32) -> Vec<&'static str> {
    let p = params(level);
    let q = if level > 1 { Some(params(level - 1)) } else { None };
    let was = |f: fn(&Params) -> bool| q.as_ref().is_some_and(f);
    let mut v = vec![];
    if p.arrows() && !was(Params::arrows) {
        v.push("arrows");
    }
    if p.burgundy() && !was(Params::burgundy) {
        v.push("burgundy");
    }
    if p.arrows() && p.four_dirs && !q.as_ref().is_some_and(|q| q.four_dirs) {
        v.push("four_dirs");
    }
    if p.lures() && !was(Params::lures) {
        v.push("lures");
    }
    if p.short() && !was(Params::short) {
        v.push("short");
    }
    v
}

#[derive(Clone, Debug, PartialEq)]
pub struct Trial {
    pub stim: Stim,
    pub iti: f64,
    pub window: f64,
    pub stim_ms: f64,
}

fn trial(p: &Params, r: &mut Rng, stim: Stim) -> Trial {
    let window = if stim.arrow.is_some() { p.swipe_ms } else { p.tap_ms };
    Trial { stim, iti: (p.iti_ms * (0.7 + 0.6 * r.f64())).round(), window, stim_ms: p.stim_ms.min(window) }
}

fn count(p: f64, n: usize) -> usize {
    ((p * n as f64).round() as usize).min(n)
}

/// Stop flags for `n` trials: exact count, never in the first two, at most 3 in a row.
fn stop_flags(r: &mut Rng, n: usize, count: usize) -> Vec<bool> {
    let mut f: Vec<bool> = (0..n).map(|i| i < count).collect();
    for _ in 0..300 {
        r.shuffle(&mut f);
        let early = f.iter().take(2).any(|&b| b);
        let long_run = f.windows(4).any(|w| w.iter().all(|&b| b));
        if !early && !long_run {
            break;
        }
    }
    f
}

/// A level show with exact counts of squares, arrows, burgundy arrows and lures.
pub fn gen_level(p: &Params, r: &mut Rng) -> Vec<Trial> {
    let n = p.trials;
    let n_sq = count(p.p_square, n);
    let n_round = n - n_sq;
    let n_arrow = count(p.p_arrow, n_round);
    let n_burg = count(p.p_burgundy, n_arrow);
    let n_lure = count(p.p_lure, n_sq);
    let flags = stop_flags(r, n, n_sq);
    // Ink per round shape (None = plain) and per square (None = no lure).
    let mut round_inks: Vec<Option<Ink>> = (0..n_round)
        .map(|i| match i {
            i if i < n_burg => Some(Ink::Burgundy),
            i if i < n_arrow => Some(Ink::Emerald),
            _ => None,
        })
        .collect();
    r.shuffle(&mut round_inks);
    let mut square_inks: Vec<Option<Ink>> = (0..n_sq)
        .map(|i| match i {
            i if i < n_lure && p.burgundy() && i % 2 == 1 => Some(Ink::Burgundy),
            i if i < n_lure => Some(Ink::Emerald),
            _ => None,
        })
        .collect();
    r.shuffle(&mut square_inks);
    // Balanced directions over all arrows.
    let dirs = p.dirs();
    let mut deck: Vec<Dir> = (0..n_arrow + n_lure).map(|i| dirs[i % dirs.len()]).collect();
    r.shuffle(&mut deck);
    let (mut ri, mut si, mut di) = (0, 0, 0);
    let mut out = Vec::with_capacity(n);
    for &square in &flags {
        let ink = if square {
            si += 1;
            square_inks[si - 1]
        } else {
            ri += 1;
            round_inks[ri - 1]
        };
        let arrow = ink.map(|ink| {
            di += 1;
            Arrow { dir: deck[di - 1], ink }
        });
        let stim = Stim { shape: if square { Shape::Square } else { Shape::Round }, arrow };
        out.push(trial(p, r, stim));
    }
    out
}

/// One random stimulus from the level's mix (endless).
fn random_stim(p: &Params, r: &mut Rng, square: bool) -> Stim {
    let arrow_p = if square { p.p_lure } else { p.p_arrow };
    let arrow = r.chance(arrow_p).then(|| Arrow {
        dir: *r.pick(p.dirs()),
        ink: if r.chance(p.p_burgundy) { Ink::Burgundy } else { Ink::Emerald },
    });
    Stim { shape: if square { Shape::Square } else { Shape::Round }, arrow }
}

// ------------------------------------------------------------------ scoring

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Stats {
    pub tap_ok: u32,
    pub tap_total: u32,
    pub swipe_ok: u32,
    pub swipe_total: u32,
    pub rejects: u32,
    pub stop_total: u32,
    pub commissions: u32,
    pub omissions: u32,
    /// Wrong direction, tap instead of swipe, swipe instead of tap.
    pub wrong: u32,
    pub early: u32,
    rt_sum: f64,
    rt_n: u32,
}

impl Stats {
    pub fn correct(&self) -> u32 {
        self.tap_ok + self.swipe_ok + self.rejects
    }
    /// Balanced accuracy over the categories present; early responses fail a stop trial.
    pub fn accuracy(&self) -> f64 {
        let mut cats = vec![];
        if self.tap_total > 0 {
            cats.push(self.tap_ok as f64 / self.tap_total as f64);
        }
        if self.swipe_total > 0 {
            cats.push(self.swipe_ok as f64 / self.swipe_total as f64);
        }
        if self.stop_total + self.early > 0 {
            cats.push(self.rejects as f64 / (self.stop_total + self.early) as f64);
        }
        if cats.is_empty() {
            1.0
        } else {
            cats.iter().sum::<f64>() / cats.len() as f64
        }
    }
    pub fn mean_rt(&self) -> Option<f64> {
        (self.rt_n > 0).then(|| self.rt_sum / self.rt_n as f64)
    }
    pub fn false_responses(&self) -> u32 {
        self.commissions + self.wrong + self.early
    }
    pub fn errors(&self) -> u32 {
        self.false_responses() + self.omissions
    }
    fn record(&mut self, stim: Stim, out: Outcome, rt: f64) {
        match expected(stim) {
            Expect::Stop => self.stop_total += 1,
            Expect::Tap => self.tap_total += 1,
            Expect::Swipe(_) => self.swipe_total += 1,
        }
        match out {
            Outcome::Hit => self.tap_ok += 1,
            Outcome::SwipeOk => self.swipe_ok += 1,
            Outcome::Reject => self.rejects += 1,
            Outcome::Commission => self.commissions += 1,
            Outcome::Omission => self.omissions += 1,
            Outcome::WrongDir | Outcome::NeedSwipe | Outcome::NeedTap => self.wrong += 1,
        }
        if matches!(out, Outcome::Hit | Outcome::SwipeOk) {
            self.rt_sum += rt;
            self.rt_n += 1;
        }
    }
}

pub fn stars_for(acc: f64, rt: Option<f64>, rt_goal: f64) -> u32 {
    if acc >= 0.9 - 1e-9 && rt.is_none_or(|r| r <= rt_goal) {
        3
    } else if acc >= 0.8 - 1e-9 {
        2
    } else if acc >= 0.7 - 1e-9 {
        1
    } else {
        0
    }
}

/// RT goal of a show: tap and swipe goals weighted by their trial counts.
pub fn rt_goal_for(p: &Params, trials: &[Trial]) -> f64 {
    let taps = trials.iter().filter(|t| expected(t.stim) == Expect::Tap).count() as f64;
    let swipes = trials.iter().filter(|t| matches!(expected(t.stim), Expect::Swipe(_))).count() as f64;
    if taps + swipes == 0.0 {
        return p.tap_goal;
    }
    ((taps * p.tap_goal + swipes * p.swipe_goal) / (taps + swipes)).round()
}

// ------------------------------------------------------------------ session

#[derive(Clone, Copy, Debug, PartialEq)]
enum Stage {
    Intro,
    Countdown,
    Iti,
    Window,
    Done,
}

#[derive(Clone, Debug, Default)]
struct Feedback {
    serial: u32,
    result: &'static str,
    rt: Option<f64>,
    expect: Option<Expect>,
    input: Option<Response>,
}

pub struct GoNoGo {
    endless: bool,
    level: u32,
    p: Params,
    rng: Rng,
    trials: Vec<Trial>,
    rt_goal: f64,
    stage: Stage,
    stage_ms: f64,
    /// Total run time (ms), for debouncing.
    clock: f64,
    idx: usize,
    pressed: bool,
    last_resp: f64,
    stats: Stats,
    lives: u32,
    fb: Feedback,
    stop_run: usize,
    /// Endless: adaptive speed 0..=1.
    speed: f64,
    stars: u32,
}

pub fn create(level: u32, mode: &str) -> Result<Box<dyn Session>, String> {
    Ok(Box::new(if mode == "endless" { GoNoGo::endless(time_seed()) } else { GoNoGo::level(level) }))
}

impl GoNoGo {
    fn with(level: u32, p: Params, rng: Rng, endless: bool) -> Self {
        GoNoGo {
            endless,
            level,
            rt_goal: p.tap_goal,
            p,
            rng,
            trials: vec![],
            stage: Stage::Intro,
            stage_ms: 0.0,
            clock: 0.0,
            idx: 0,
            pressed: false,
            last_resp: f64::NEG_INFINITY,
            stats: Stats::default(),
            lives: LIVES,
            fb: Feedback::default(),
            stop_run: 0,
            speed: 0.0,
            stars: 0,
        }
    }

    pub fn level(level: u32) -> Self {
        let level = level.clamp(1, crate::MAX_LEVEL);
        let p = params(level);
        let mut rng = Rng::new(seed_for("gonogo", level, 0));
        let trials = gen_level(&p, &mut rng);
        let mut g = GoNoGo::with(level, p, rng, false);
        g.rt_goal = rt_goal_for(&g.p, &trials);
        g.trials = trials;
        g
    }

    pub fn endless(seed: u64) -> Self {
        let v = Self::endless_level(0.0);
        GoNoGo::with(v, params(v), Rng::new(seed), true)
    }

    fn endless_level(speed: f64) -> u32 {
        15 + (485.0 * speed.clamp(0.0, 1.0)).round() as u32
    }

    /// Endless: make sure trial `i` exists, generated at the current speed.
    fn ensure_trial(&mut self, i: usize) {
        if !self.endless || i < self.trials.len() {
            return;
        }
        self.level = Self::endless_level(self.speed);
        self.p = params(self.level);
        let square = i >= 2 && self.stop_run < 3 && self.rng.chance(self.p.p_square);
        self.stop_run = if square { self.stop_run + 1 } else { 0 };
        let stim = random_stim(&self.p, &mut self.rng, square);
        let t = trial(&self.p, &mut self.rng, stim);
        self.trials.push(t);
    }

    fn cur(&self) -> Option<&Trial> {
        self.trials.get(self.idx)
    }

    fn total(&self) -> usize {
        if self.endless {
            usize::MAX
        } else {
            self.trials.len()
        }
    }

    fn stage_len(&self) -> f64 {
        match self.stage {
            Stage::Countdown => COUNTDOWN_MS,
            Stage::Iti => self.cur().map_or(0.0, |t| t.iti),
            Stage::Window => self.cur().map_or(0.0, |t| t.window + if self.pressed { GRACE_MS } else { 0.0 }),
            Stage::Intro | Stage::Done => f64::INFINITY,
        }
    }

    fn begin_trial(&mut self, i: usize) {
        self.idx = i;
        self.pressed = false;
        if !self.endless && i >= self.trials.len() {
            self.finish();
            return;
        }
        self.ensure_trial(i);
        self.stage = Stage::Iti;
        self.stage_ms = 0.0;
    }

    fn advance(&mut self) {
        self.stage_ms = 0.0;
        match self.stage {
            Stage::Countdown => self.begin_trial(0),
            Stage::Iti => self.stage = Stage::Window,
            Stage::Window => self.resolve(None, 0.0),
            Stage::Intro | Stage::Done => {}
        }
    }

    /// Score the current trial (`resp` = None: no response before the window closed).
    fn resolve(&mut self, resp: Option<Response>, rt: f64) {
        let Some(t) = self.cur().cloned() else { return };
        let out = judge(t.stim, resp);
        self.stats.record(t.stim, out, rt);
        self.fb = Feedback {
            serial: self.fb.serial + 1,
            result: out.key(),
            rt: resp.map(|_| rt.round()),
            expect: Some(expected(t.stim)),
            input: resp,
        };
        if self.endless {
            if out.ok() {
                self.speed = (self.speed + SPEED_UP).min(1.0);
            } else {
                self.speed = (self.speed - SPEED_DOWN).max(0.0);
                self.lose_life();
                if self.stage == Stage::Done {
                    return;
                }
            }
        }
        self.begin_trial(self.idx + 1);
    }

    fn lose_life(&mut self) {
        self.lives = self.lives.saturating_sub(1);
        if self.lives == 0 {
            self.stage = Stage::Done;
            self.stage_ms = 0.0;
        }
    }

    fn finish(&mut self) {
        self.stage = Stage::Done;
        self.stage_ms = 0.0;
        if !self.endless {
            self.stars = stars_for(self.stats.accuracy(), self.stats.mean_rt(), self.rt_goal);
        }
    }

    fn status(&self) -> &'static str {
        match self.stage {
            Stage::Done if self.endless || self.stars == 0 => "lost",
            Stage::Done => "won",
            _ => "playing",
        }
    }

    fn summary(&self) -> String {
        let s = &self.stats;
        let mut parts = vec![];
        if self.endless {
            parts.push(format!("Doğru {}", s.correct()));
        } else {
            parts.push(format!("Doğruluk %{}", (s.accuracy() * 100.0).round()));
        }
        if let Some(rt) = s.mean_rt() {
            parts.push(format!("Ort. tepki {} ms", rt.round()));
        }
        parts.push(format!("Yanlış tepki {}", s.false_responses()));
        parts.push(format!("Kaçırılan {}", s.omissions));
        parts.join(" · ")
    }

    fn title(&self) -> &'static str {
        let p = &self.p;
        if self.endless {
            "Sonsuz"
        } else if p.lures() {
            "Tuzaklı oklar"
        } else if p.burgundy() {
            "Bordo ok"
        } else if p.arrows() {
            "Zümrüt ok"
        } else {
            "Yuvarlak ya da köşeli"
        }
    }

    fn goal(&self) -> String {
        if self.endless {
            return "Hata can götürür · 3 can · doğru gittikçe hızlanır".into();
        }
        let p = &self.p;
        let mut g = vec!["Yuvarlağa dokun", "köşeliye dokunma"];
        if p.arrows() {
            g.push("zümrüt ok: yönüne kaydır");
        }
        if p.burgundy() {
            g.push("bordo ok: tersine kaydır");
        }
        format!("{} · {} uyaran", g.join(" · "), self.trials.len())
    }

    fn features(&self) -> Vec<&'static str> {
        if self.endless {
            return vec![];
        }
        let p = &self.p;
        let new = new_rules(self.level);
        let mut f = vec![];
        if p.arrows() {
            f.push(if new.contains(&"arrows") { "Yeni: zümrüt ok" } else { "Zümrüt ok" });
            f.push(match (p.four_dirs, new.contains(&"four_dirs")) {
                (true, true) => "Yeni: dört yön",
                (true, false) => "Dört yön",
                _ => "Sağ ve sol",
            });
        }
        if p.burgundy() {
            f.push(if new.contains(&"burgundy") { "Yeni: bordo ok" } else { "Bordo ok" });
        }
        if p.lures() {
            f.push(if new.contains(&"lures") { "Yeni: köşelide tuzak ok" } else { "Köşelide tuzak ok" });
        }
        if p.short() {
            f.push(if new.contains(&"short") { "Yeni: uyaran kısa görünür" } else { "Uyaran kısa görünür" });
        }
        f
    }

    fn stim_json(&self) -> Value {
        let Some(t) = self.cur() else { return Value::Null };
        if self.stage != Stage::Window || self.stage_ms >= t.stim_ms {
            return Value::Null;
        }
        json!({
            "id": self.idx,
            "shape": if t.stim.shape == Shape::Round { "round" } else { "square" },
            "arrow": t.stim.arrow.map(|a| json!({
                "dir": a.dir.key(),
                "color": if a.ink == Ink::Emerald { "emerald" } else { "burgundy" },
            })),
        })
    }

    fn early(&mut self, resp: Response) {
        self.stats.early += 1;
        self.fb = Feedback { serial: self.fb.serial + 1, result: "early", rt: None, expect: None, input: Some(resp) };
        if self.endless {
            self.speed = (self.speed - SPEED_DOWN).max(0.0);
            self.lose_life();
        }
    }
}

fn expect_json(e: Option<Expect>) -> (Value, Value) {
    match e {
        Some(Expect::Stop) => (json!("stop"), Value::Null),
        Some(Expect::Tap) => (json!("tap"), Value::Null),
        Some(Expect::Swipe(d)) => (json!("swipe"), json!(d.key())),
        None => (Value::Null, Value::Null),
    }
}

impl Session for GoNoGo {
    fn state(&self) -> Value {
        let s = &self.stats;
        let p = &self.p;
        let done = self.stage == Stage::Done;
        let phase = match self.stage {
            Stage::Intro => "intro",
            Stage::Countdown => "countdown",
            Stage::Done => "done",
            _ => "run",
        };
        let stage = match self.stage {
            Stage::Iti => Some("iti"),
            Stage::Window => Some("window"),
            _ => None,
        };
        let len = self.stage_len();
        let (expect, dir) = expect_json(self.fb.expect);
        let input = self.fb.input.map(|r| match r {
            Response::Tap => "tap",
            Response::Swipe(d) => d.key(),
        });
        json!({
            "status": self.status(),
            "stars": self.stars,
            "title": self.title(),
            "goal": self.goal(),
            "summary": done.then(|| self.summary()),
            "score": self.endless.then(|| s.correct()),
            "mode": if self.endless { "endless" } else { "level" },
            "phase": phase,
            "stage": stage,
            "stage_ms": self.stage_ms.round(),
            "stage_len": if len.is_finite() { Some(len) } else { None },
            "countdown_ms": if self.stage == Stage::Countdown { (COUNTDOWN_MS - self.stage_ms).max(0.0).round() } else { 0.0 },
            "trial": (self.idx + 1).min(self.total()),
            "trials": (!self.endless).then_some(self.trials.len()),
            "lives": self.endless.then_some(self.lives),
            "features": self.features(),
            "rules": {
                "arrows": p.arrows(), "burgundy": p.burgundy(), "four_dirs": p.four_dirs, "lures": p.lures(),
            },
            "new_rules": if self.endless { vec![] } else { new_rules(self.level) },
            "stim": self.stim_json(),
            "pressed": self.pressed,
            "fb": {
                "serial": self.fb.serial, "result": self.fb.result, "rt": self.fb.rt,
                "expect": expect, "dir": dir, "input": input,
            },
            "stats": {
                "correct": s.correct(), "taps": s.tap_ok, "swipes": s.swipe_ok, "rejects": s.rejects,
                "commissions": s.commissions, "omissions": s.omissions, "wrong": s.wrong, "early": s.early,
                "false_responses": s.false_responses(), "errors": s.errors(),
            },
            "accuracy": (s.accuracy() * 1000.0).round() / 1000.0,
            "mean_rt": s.mean_rt().map(|v| v.round()),
            "rt_goal": (!self.endless).then_some(self.rt_goal),
            "speed": self.endless.then(|| (self.speed * 100.0).round() / 100.0),
        })
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if self.stage == Stage::Done {
            return Err("Bitti".into());
        }
        if a["start"].as_bool() == Some(true) {
            if self.stage != Stage::Intro {
                return Err("Zaten başladı".into());
            }
            self.stage = Stage::Countdown;
            self.stage_ms = 0.0;
            return Ok(());
        }
        let is_press = a["press"].as_bool() == Some(true);
        let resp = if is_press {
            None
        } else if let Some(d) = a.get("swipe") {
            Some(Response::Swipe(d.as_str().and_then(Dir::parse).ok_or("Geçersiz yön")?))
        } else if a["tap"].as_bool() == Some(true) {
            Some(Response::Tap)
        } else {
            return Err("Bilinmeyen hamle".into());
        };
        if self.stage == Stage::Intro {
            return Err("Önce Başla'ya dokun".into());
        }
        let Some(resp) = resp else {
            // A finger landed: inside a window it buys the grace time to finish the gesture.
            if self.stage == Stage::Window {
                self.pressed = true;
            }
            return Ok(());
        };
        if self.stage == Stage::Countdown {
            return Ok(()); // harmless while counting down
        }
        if self.clock - self.last_resp < DEBOUNCE_MS {
            return Ok(());
        }
        self.last_resp = self.clock;
        if self.stage == Stage::Window {
            let rt = self.stage_ms;
            self.resolve(Some(resp), rt);
        } else {
            self.early(resp);
        }
        Ok(())
    }

    fn tick(&mut self, dt_ms: f64) {
        if dt_ms.is_nan() || dt_ms <= 0.0 {
            return;
        }
        let mut rem = dt_ms;
        while rem > 0.0 && !matches!(self.stage, Stage::Intro | Stage::Done) {
            let left = self.stage_len() - self.stage_ms;
            if rem < left {
                self.stage_ms += rem;
                self.clock += rem;
                rem = 0.0;
            } else {
                let step = left.max(0.0);
                self.clock += step;
                rem -= step;
                self.advance();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LEVELS: [u32; 12] = [1, 2, 3, 6, 9, 12, 15, 25, 137, 250, 499, 500];

    fn all_stims() -> Vec<Stim> {
        let mut v = vec![];
        for shape in [Shape::Round, Shape::Square] {
            v.push(Stim { shape, arrow: None });
            for ink in [Ink::Emerald, Ink::Burgundy] {
                for dir in Dir::ALL {
                    v.push(Stim { shape, arrow: Some(Arrow { dir, ink }) });
                }
            }
        }
        v
    }

    fn all_responses() -> Vec<Option<Response>> {
        let mut v = vec![None, Some(Response::Tap)];
        v.extend(Dir::ALL.map(|d| Some(Response::Swipe(d))));
        v
    }

    /// The user's spec, written out independently of `judge`.
    fn oracle(s: Stim, r: Option<Response>) -> &'static str {
        if s.shape == Shape::Square {
            return if r.is_none() { "reject" } else { "commission" };
        }
        let Some(a) = s.arrow else {
            return match r {
                None => "omission",
                Some(Response::Tap) => "hit",
                Some(Response::Swipe(_)) => "need_tap",
            };
        };
        let want = match (a.ink, a.dir) {
            (Ink::Emerald, d) => d,
            (Ink::Burgundy, Dir::Up) => Dir::Down,
            (Ink::Burgundy, Dir::Down) => Dir::Up,
            (Ink::Burgundy, Dir::Left) => Dir::Right,
            (Ink::Burgundy, Dir::Right) => Dir::Left,
        };
        match r {
            None => "omission",
            Some(Response::Tap) => "need_swipe",
            Some(Response::Swipe(d)) if d == want => "swipe_ok",
            Some(Response::Swipe(_)) => "wrong_dir",
        }
    }

    #[test]
    fn rule_table_every_combination() {
        let mut n = 0;
        for s in all_stims() {
            for r in all_responses() {
                let out = judge(s, r);
                assert_eq!(out.key(), oracle(s, r), "{s:?} {r:?}");
                // Exactly one response is right for each stimulus.
                assert_eq!(out.ok(), matches!(oracle(s, r), "hit" | "swipe_ok" | "reject"));
                n += 1;
            }
            assert_eq!(all_responses().into_iter().filter(|&r| judge(s, r).ok()).count(), 1, "{s:?}");
        }
        assert_eq!(n, 18 * 6);
        // Spot checks in plain words.
        let round = |dir, ink| Stim { shape: Shape::Round, arrow: Some(Arrow { dir, ink }) };
        assert_eq!(judge(round(Dir::Up, Ink::Burgundy), Some(Response::Swipe(Dir::Down))), Outcome::SwipeOk);
        assert_eq!(judge(round(Dir::Left, Ink::Emerald), Some(Response::Swipe(Dir::Left))), Outcome::SwipeOk);
        assert_eq!(judge(round(Dir::Left, Ink::Emerald), Some(Response::Tap)), Outcome::NeedSwipe);
        let lure = Stim { shape: Shape::Square, arrow: Some(Arrow { dir: Dir::Up, ink: Ink::Emerald }) };
        assert_eq!(judge(lure, Some(Response::Swipe(Dir::Up))), Outcome::Commission);
        assert_eq!(judge(lure, None), Outcome::Reject);
    }

    #[test]
    fn curve_introduces_rules_in_order() {
        for l in 1..=5 {
            let p = params(l);
            assert!(!p.arrows() && !p.burgundy() && !p.lures(), "level {l}");
        }
        for l in 6..=11 {
            let p = params(l);
            assert!(p.arrows() && !p.burgundy() && !p.lures(), "level {l}");
        }
        assert!(!params(6).four_dirs && params(9).four_dirs);
        for l in 12..=24 {
            let p = params(l);
            assert!(p.arrows() && p.burgundy() && !p.lures(), "level {l}");
        }
        assert!(params(25).lures());
        assert_eq!(new_rules(1), Vec::<&str>::new());
        assert_eq!(new_rules(6), vec!["arrows"]);
        assert_eq!(new_rules(9), vec!["four_dirs"]);
        assert_eq!(new_rules(12), vec!["burgundy"]);
        assert_eq!(new_rules(25), vec!["lures"]);
        assert_eq!(new_rules(120), vec!["short"]);
        assert_eq!(params(1).trials, 20);
        assert_eq!(params(500).trials, 40);
        let z = params(500);
        assert_eq!((z.tap_ms, z.swipe_ms, z.stim_ms, z.iti_ms), (550.0, 850.0, 400.0, 400.0));
        for l in 1..500 {
            let (a, b) = (params(l), params(l + 1));
            assert!(b.trials >= a.trials && b.tap_ms <= a.tap_ms && b.swipe_ms <= a.swipe_ms);
            assert!(b.trials % 2 == 0 && b.tap_goal < b.tap_ms && b.swipe_goal < b.swipe_ms);
            assert!(b.stim_ms >= 400.0);
        }
    }

    #[test]
    fn levels_generate_with_exact_counts() {
        for level in LEVELS.iter().copied().chain(1..=40) {
            let g = GoNoGo::level(level);
            let p = &g.p;
            let n = p.trials;
            assert_eq!(g.trials.len(), n);
            let squares: Vec<&Trial> = g.trials.iter().filter(|t| t.stim.shape == Shape::Square).collect();
            let rounds: Vec<&Trial> = g.trials.iter().filter(|t| t.stim.shape == Shape::Round).collect();
            let n_sq = count(p.p_square, n);
            assert_eq!(squares.len(), n_sq, "level {level}");
            let n_arrow = count(p.p_arrow, rounds.len());
            assert_eq!(rounds.iter().filter(|t| t.stim.arrow.is_some()).count(), n_arrow);
            let burg = rounds.iter().filter(|t| matches!(t.stim.arrow, Some(Arrow { ink: Ink::Burgundy, .. }))).count();
            assert_eq!(burg, count(p.p_burgundy, n_arrow));
            assert_eq!(squares.iter().filter(|t| t.stim.arrow.is_some()).count(), count(p.p_lure, n_sq));
            assert!(g.trials[..2].iter().all(|t| t.stim.shape == Shape::Round), "level {level}: early square");
            for t in &g.trials {
                if let Some(a) = t.stim.arrow {
                    assert!(p.four_dirs || matches!(a.dir, Dir::Left | Dir::Right), "level {level}");
                    assert!(p.burgundy() || a.ink == Ink::Emerald);
                    assert_eq!(t.window, p.swipe_ms);
                } else {
                    assert_eq!(t.window, p.tap_ms);
                }
            }
        }
    }

    #[test]
    fn deterministic() {
        for level in LEVELS {
            assert_eq!(GoNoGo::level(level).trials, GoNoGo::level(level).trials);
        }
    }

    fn start(g: &mut GoNoGo) {
        g.act(&json!({"start": true})).unwrap();
        g.tick(COUNTDOWN_MS);
        assert_eq!(g.state()["phase"], "run");
    }

    fn send(g: &mut GoNoGo, r: Response) {
        let a = match r {
            Response::Tap => json!({"tap": true}),
            Response::Swipe(d) => json!({"swipe": d.key()}),
        };
        g.act(&a).unwrap();
    }

    /// Bot: answers `rt` ms after onset. `policy`: "perfect", "tap" (taps everything), "none",
    /// "wrong" (some wrong response everywhere).
    fn play(g: &mut GoNoGo, rt: f64, policy: &str, max_trials: usize) {
        let mut answered = usize::MAX;
        let mut guard = 0;
        while g.stage != Stage::Done && g.idx < max_trials {
            if g.stage == Stage::Window && g.stage_ms >= rt && answered != g.idx {
                answered = g.idx;
                let want = expected(g.cur().unwrap().stim);
                let resp = match (policy, want) {
                    ("perfect", Expect::Tap) => Some(Response::Tap),
                    ("perfect", Expect::Swipe(d)) => Some(Response::Swipe(d)),
                    ("tap", _) => Some(Response::Tap),
                    ("wrong", Expect::Stop) => Some(Response::Tap),
                    ("wrong", Expect::Tap) => Some(Response::Swipe(Dir::Up)),
                    ("wrong", Expect::Swipe(d)) => Some(Response::Swipe(d.opposite())),
                    _ => None,
                };
                if let Some(r) = resp {
                    send(g, r);
                    continue;
                }
            }
            g.tick(5.0);
            guard += 1;
            assert!(guard < 2_000_000);
        }
    }

    #[test]
    fn perfect_fast_play_wins_three_stars() {
        for level in LEVELS {
            let mut g = GoNoGo::level(level);
            start(&mut g);
            play(&mut g, 300.0, "perfect", usize::MAX);
            let st = g.state();
            assert_eq!(st["status"], "won", "level {level}");
            assert_eq!(st["stars"], 3, "level {level}");
            assert_eq!(st["accuracy"], 1.0);
            assert_eq!(g.stats.errors(), 0);
            let rt = st["mean_rt"].as_f64().unwrap();
            assert!((300.0..=305.0).contains(&rt), "level {level}: rt {rt}");
        }
    }

    #[test]
    fn slow_but_accurate_play_gets_two_stars() {
        let mut g = GoNoGo::level(1);
        start(&mut g);
        play(&mut g, 700.0, "perfect", usize::MAX);
        assert_eq!(g.state()["stars"], 2);
    }

    /// Runs level 20 until a trial expecting `want` is in its window.
    fn window_with(g: &mut GoNoGo, want: fn(Expect) -> bool) {
        let mut guard = 0;
        loop {
            if g.stage == Stage::Window && want(expected(g.cur().unwrap().stim)) {
                return;
            }
            if g.stage == Stage::Window && g.stage_ms > 50.0 {
                let r = match expected(g.cur().unwrap().stim) {
                    Expect::Tap => Some(Response::Tap),
                    Expect::Swipe(d) => Some(Response::Swipe(d)),
                    Expect::Stop => None,
                };
                if let Some(r) = r {
                    send(g, r);
                    continue;
                }
            }
            g.tick(5.0);
            guard += 1;
            assert!(guard < 100_000 && g.stage != Stage::Done);
        }
    }

    #[test]
    fn every_error_kind_is_scored_in_play() {
        let cases: [(fn(Expect) -> bool, fn(Expect) -> Option<Response>, &str); 6] = [
            (|e| e == Expect::Stop, |_| Some(Response::Tap), "commission"),
            (|e| e == Expect::Tap, |_| None, "omission"),
            (|e| e == Expect::Tap, |_| Some(Response::Swipe(Dir::Left)), "need_tap"),
            (|e| matches!(e, Expect::Swipe(_)), |_| Some(Response::Tap), "need_swipe"),
            (|e| matches!(e, Expect::Swipe(_)), |e| match e { Expect::Swipe(d) => Some(Response::Swipe(d.opposite())), _ => None }, "wrong_dir"),
            (|e| e == Expect::Stop, |_| None, "reject"),
        ];
        for (want, resp, result) in cases {
            let mut g = GoNoGo::level(20);
            start(&mut g);
            window_with(&mut g, want);
            g.tick(150.0);
            let idx = g.idx;
            let e = expected(g.cur().unwrap().stim);
            match resp(e) {
                Some(r) => send(&mut g, r),
                None => {
                    while g.idx == idx {
                        g.tick(5.0);
                    }
                }
            }
            let st = g.state();
            assert_eq!(st["fb"]["result"], result);
            if result == "reject" {
                assert_eq!(g.stats.errors(), 0);
            } else {
                assert_eq!(g.stats.errors(), 1, "{result}");
            }
            if let Expect::Swipe(d) = e {
                assert_eq!(st["fb"]["expect"], "swipe");
                assert_eq!(st["fb"]["dir"], d.key());
            }
        }
    }

    #[test]
    fn early_responses_and_bounces() {
        let mut g = GoNoGo::level(1);
        start(&mut g);
        assert_eq!(g.stage, Stage::Iti);
        g.act(&json!({"tap": true})).unwrap();
        assert_eq!(g.stats.early, 1);
        assert_eq!(g.state()["fb"]["result"], "early");
        g.tick(50.0);
        g.act(&json!({"swipe": "up"})).unwrap(); // within 120 ms: a bounce
        assert_eq!(g.stats.early, 1);
        assert!(g.stats.accuracy() < 1.0);
        // A press during the gap is harmless.
        g.act(&json!({"press": true})).unwrap();
        assert!(!g.pressed);
    }

    #[test]
    fn press_buys_grace_to_finish_the_gesture() {
        let mut g = GoNoGo::level(1);
        start(&mut g);
        while g.stage != Stage::Window {
            g.tick(5.0);
        }
        let w = g.cur().unwrap().window;
        g.tick(w - 50.0);
        g.act(&json!({"press": true})).unwrap();
        assert_eq!(g.state()["pressed"], true);
        g.tick(150.0); // past the window, inside the grace
        assert_eq!(g.stage, Stage::Window);
        send(&mut g, Response::Tap);
        assert_eq!(g.state()["fb"]["result"], "hit");
        // Without a release the grace runs out: an omission.
        while g.stage != Stage::Window {
            g.tick(5.0);
        }
        if expected(g.cur().unwrap().stim) == Expect::Tap {
            g.act(&json!({"press": true})).unwrap();
            let idx = g.idx;
            g.tick(g.cur().unwrap().window + GRACE_MS + 1.0);
            assert_ne!(g.idx, idx);
            assert_eq!(g.state()["fb"]["result"], "omission");
        }
    }

    #[test]
    fn lazy_strategies_lose() {
        for (level, policy) in [(1, "tap"), (1, "none"), (20, "tap"), (20, "none"), (300, "wrong"), (300, "tap")] {
            let mut g = GoNoGo::level(level);
            start(&mut g);
            play(&mut g, 250.0, policy, usize::MAX);
            let st = g.state();
            assert_eq!(st["status"], "lost", "level {level} {policy}");
            assert!(st["accuracy"].as_f64().unwrap() < 0.7);
            assert!(st["summary"].as_str().unwrap().contains("Yanlış tepki"));
        }
    }

    #[test]
    fn stimulus_hides_on_short_levels() {
        let mut g = GoNoGo::level(500);
        start(&mut g);
        let mut saw_hidden = false;
        let mut guard = 0;
        while g.stage != Stage::Done && guard < 400_000 {
            let st = g.state();
            if st["stage"] == "window" {
                let t = g.cur().unwrap();
                if g.stage_ms >= t.stim_ms {
                    assert!(st["stim"].is_null());
                    saw_hidden = true;
                } else {
                    assert!(st["stim"].is_object());
                }
                if g.stage_ms >= 420.0 {
                    let r = match expected(t.stim) {
                        Expect::Tap => Some(Response::Tap),
                        Expect::Swipe(d) => Some(Response::Swipe(d)),
                        Expect::Stop => None,
                    };
                    if let Some(r) = r {
                        send(&mut g, r);
                        continue;
                    }
                }
            }
            g.tick(5.0);
            guard += 1;
        }
        assert!(saw_hidden);
        assert_eq!(g.state()["status"], "won");
    }

    #[test]
    fn illegal_actions_rejected_and_state_unchanged() {
        let mut g = GoNoGo::level(1);
        let before = g.state();
        assert!(g.act(&json!({"tap": true})).is_err());
        assert!(g.act(&json!({"press": true})).is_err());
        assert!(g.act(&json!({"swipe": "sideways"})).is_err());
        assert!(g.act(&json!({"jump": true})).is_err());
        assert_eq!(g.state(), before);
        g.act(&json!({"start": true})).unwrap();
        assert!(g.act(&json!({"start": true})).is_err());
        let mut g = GoNoGo::level(1);
        start(&mut g);
        let before = g.state();
        assert!(g.act(&json!({"swipe": 3})).is_err());
        assert_eq!(g.state(), before);
        play(&mut g, 300.0, "perfect", usize::MAX);
        let before = g.state();
        assert!(g.act(&json!({"tap": true})).is_err());
        assert_eq!(g.state(), before);
    }

    #[test]
    fn endless_adapts_speed_and_reaches_lost() {
        // Never responding: three omissions end it.
        let mut g = GoNoGo::endless(7);
        start(&mut g);
        play(&mut g, 300.0, "none", usize::MAX);
        let st = g.state();
        assert_eq!(st["status"], "lost");
        assert_eq!(st["lives"], 0);
        assert!(st["summary"].as_str().unwrap().contains("Kaçırılan 3"));
        // A perfect player speeds the stream up.
        let mut g = GoNoGo::endless(11);
        start(&mut g);
        let first = g.cur().unwrap().clone();
        play(&mut g, 280.0, "perfect", 80);
        assert!(g.stage != Stage::Done);
        assert_eq!(g.lives, LIVES);
        assert!((g.speed - 1.0).abs() < 1e-9);
        assert_eq!(g.state()["score"], g.stats.correct());
        let last = g.trials.last().unwrap();
        assert!(last.iti < first.iti * 1.5 && g.p.tap_ms < 600.0);
        assert!(g.trials.iter().any(|t| matches!(t.stim.arrow, Some(Arrow { ink: Ink::Burgundy, .. }))));
        assert!(g.trials.iter().any(|t| t.stim.shape == Shape::Square && t.stim.arrow.is_some()));
        // An error slows it down again, three end it.
        let next = g.idx + 1;
        play(&mut g, 280.0, "wrong", next);
        assert!(g.speed < 1.0 && g.lives == LIVES - 1);
        play(&mut g, 280.0, "wrong", usize::MAX);
        assert_eq!(g.state()["status"], "lost");
    }

    #[test]
    #[ignore]
    fn timing_500_levels() {
        let t = std::time::Instant::now();
        for level in 1..=500 {
            let g = GoNoGo::level(level);
            assert_eq!(g.trials.len(), g.p.trials);
        }
        println!("gonogo: 500 levels in {:?}", t.elapsed());
    }
}
