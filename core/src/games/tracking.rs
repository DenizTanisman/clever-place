//! Çoklu Takip — multiple-object tracking (MOT, after Pylyshyn & Storm 1988).
//!
//! N identical orbs sit in a 1000 × 1300 arena. For `cue_ms` the K targets glow gold ("show"), then
//! every orb looks the same and all of them move ("run") for `track_ms`: constant speed per orb,
//! smooth random steering, optional speed changes, elastic bounces off the walls and off each other.
//! When the motion stops ("recall") the player taps the K targets; the K-th pick ends the round.
//! Rounds with a digit probe then ask which digit flashed on an orb during the motion ("probe").
//! A short "feedback" phase reveals the targets, then the next round starts with a fresh layout.
//!
//! Physics runs on a fixed 5 ms step with an accumulator, so a run is identical for any frame rate
//! or tick chunking (determinism is tested). Orb positions in the state are interpolated between the
//! last two physics steps (×10 integers), so a 120 Hz view moves perfectly smoothly.
//!
//! Level curve (`params(level)`), t = (level − 1) / 499, u = progress inside the current K band:
//! - K (targets): 3 for 1–60, 4 for 61–180, 5 for 181–330, 6 for 331–500. Level 1 is 3 of 8 —
//!   already a real tracking load (adult capacity is about four objects at moderate speed).
//! - N (orbs) = 2K + 2 … 2K + 4 inside each band → 8 … 16. Radius shrinks 54 → 41 as N grows.
//! - Speed = 170 + 180·t + 70·u units/s (170 → 420): ramps inside a band, eases back when K grows.
//! - Motion time 5 s → 12 s; cue time 2.2 s → 1.6 s; steering gets livelier (0.25 → 0.85 turns/s,
//!   up to ±0.5 → ±1.7 rad); per-orb speed changes from ±0 % to ±35 %.
//! - Extras on a 4-level rotation: occluder bands (level ≥ 90, two bands from 300) the orbs pass
//!   behind; colour-swap lures (≥ 150) — random orbs briefly flash a jewel colour; a digit probe
//!   (≥ 210) — a digit flashes on one orb mid-motion and must be reported after the picks (dual task).
//!   From 400 some levels combine two extras.
//!
//! Scoring: a round is *perfect* when all K picks are targets (and the probe digit, if any, is
//! right). A level is 4 rounds. Stars: 4 perfect → 3, 3 → 2, 2 → 1; fewer → `lost`.
//!
//! State: `{status, stars, title, goal, summary?, phase: "intro"|"countdown"|"show"|"run"|"recall"|
//!          "probe"|"feedback"|"done", phase_ms, phase_len, countdown_ms, round, rounds, k, n, radius,
//!          arena: [w, h], pos: [x0·10, y0·10, …], targets: [..] (show/feedback/done only), picked,
//!          occluders: [[y0, y1]..], swaps: [[orb, colour, age_ms]..], probe: {orb, digit}|null,
//!          has_probe, lures, track_ms, results: [{hits, k, probe: bool|null, perfect}], perfect, serial,
//!          last: {hits, k, probe_ok, digit, answer}|null}`
//! Actions: `{"start":true}` (intro) · `{"pick":i}` (recall; toggles) · `{"probe":d}` (probe, 1–9)

use crate::rng::{seed_for, Rng};
use crate::Session;
use serde_json::{json, Value};
use std::f64::consts::{PI, TAU};

pub const W: f64 = 1000.0;
pub const H: f64 = 1300.0;
pub const STEP_MS: f64 = 5.0;
pub const COUNTDOWN_MS: f64 = 3000.0;
pub const FEEDBACK_MS: f64 = 1800.0;
pub const ROUNDS: usize = 4;
/// Maximum steering rate (rad/s): direction changes are curves, never kinks.
const TURN_SPEED: f64 = 2.6;
/// Colour-swap lure: lifetime and rate (events per second over the whole arena).
const SWAP_MS: f64 = 480.0;
const SWAP_RATE: f64 = 0.7;
/// Jewel colours a lure may flash (indices into the view's palette).
const SWAP_COLORS: u8 = 4;

#[derive(Clone, Debug, PartialEq)]
pub struct Params {
    pub k: usize,
    pub n: usize,
    pub radius: f64,
    /// Arena units per second.
    pub speed: f64,
    /// Per-orb speed factor varies in 1 ± speed_var.
    pub speed_var: f64,
    /// Steering events per orb per second and their maximum size (rad).
    pub turn_rate: f64,
    pub turn_max: f64,
    pub cue_ms: f64,
    pub track_ms: f64,
    pub occluders: usize,
    pub swaps: bool,
    pub probe: bool,
    pub probe_ms: f64,
}

/// Level → parameters. See the module docs for the curve.
pub fn params(level: u32) -> Params {
    let l = level.clamp(1, crate::MAX_LEVEL);
    let t = (l - 1) as f64 / 499.0;
    let (k, lo, hi) = match l {
        1..=60 => (3, 1, 60),
        61..=180 => (4, 61, 180),
        181..=330 => (5, 181, 330),
        _ => (6, 331, 500),
    };
    let u = (l - lo) as f64 / (hi - lo) as f64;
    let n = (2 * k + 2 + (u * 2.999) as usize).min(16);
    let c = l % 4;
    let late = l >= 400;
    let occluders = if l >= 90 && (c == 0 || (late && c == 3)) { if l >= 300 { 2 } else { 1 } } else { 0 };
    let swaps = l >= 150 && (c == 1 || (late && c == 3));
    let probe = l >= 210 && (c == 2 || (l >= 450 && c == 1));
    Params {
        k,
        n,
        radius: 54.0 - (n as f64 - 8.0) * 1.6,
        speed: 170.0 + 180.0 * t + 70.0 * u,
        speed_var: 0.35 * t,
        turn_rate: 0.25 + 0.6 * t,
        turn_max: 0.5 + 1.2 * t,
        cue_ms: (2200.0 - 600.0 * t).round(),
        track_ms: ((5000.0 + 7000.0 * t) / 100.0).round() * 100.0,
        occluders,
        swaps,
        probe,
        probe_ms: (750.0 - 300.0 * t).round(),
    }
}

/// Occluder bands as (y0, y1). Tall enough (3.2 r) that an orb disappears completely for a moment.
pub fn occluder_bands(p: &Params) -> Vec<(f64, f64)> {
    let half = 1.6 * p.radius;
    let centres: &[f64] = match p.occluders {
        0 => &[],
        1 => &[0.5],
        _ => &[0.32, 0.68],
    };
    centres.iter().map(|&c| (c * H - half, c * H + half)).collect()
}

fn wrap(a: f64) -> f64 {
    let mut a = a % TAU;
    if a > PI {
        a -= TAU;
    } else if a < -PI {
        a += TAU;
    }
    a
}

#[derive(Clone, Debug, PartialEq)]
struct Orb {
    x: f64,
    y: f64,
    /// Position at the previous physics step (for interpolation).
    px: f64,
    py: f64,
    /// Heading and steering target (rad).
    h: f64,
    th: f64,
    /// Speed factor and its target.
    sp: f64,
    tsp: f64,
}

#[derive(Clone, Debug, PartialEq)]
struct ProbePlan {
    at: f64,
    orb: usize,
    digit: u8,
    start: Option<f64>,
}

#[derive(Clone, Debug, PartialEq)]
struct RoundResult {
    hits: usize,
    probe_ok: Option<bool>,
    digit: Option<u8>,
    answer: Option<u8>,
}

impl RoundResult {
    fn perfect(&self, k: usize) -> bool {
        self.hits == k && self.probe_ok != Some(false)
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Phase {
    Intro,
    Countdown,
    Show,
    Run,
    Recall,
    Probe,
    Feedback,
    Done,
}

pub struct Tracking {
    p: Params,
    bands: Vec<(f64, f64)>,
    rng: Rng,
    phase: Phase,
    /// Milliseconds spent in the current phase (fixed-step clock).
    clock: f64,
    /// Unspent tick time (< STEP_MS).
    acc: f64,
    round: usize,
    orbs: Vec<Orb>,
    targets: Vec<usize>,
    picked: Vec<usize>,
    swaps: Vec<(usize, u8, f64)>,
    probe: Option<ProbePlan>,
    results: Vec<RoundResult>,
    serial: u32,
}

pub fn create(level: u32, _mode: &str) -> Result<Box<dyn Session>, String> {
    // The catalog offers levels only; any mode plays the level.
    Ok(Box::new(Tracking::level(level)))
}

pub fn stars_for(perfect: usize) -> u32 {
    match perfect {
        4.. => 3,
        3 => 2,
        2 => 1,
        _ => 0,
    }
}

impl Tracking {
    pub fn level(level: u32) -> Self {
        let p = params(level);
        Tracking {
            bands: occluder_bands(&p),
            p,
            rng: Rng::new(seed_for("tracking", level, 0)),
            phase: Phase::Intro,
            clock: 0.0,
            acc: 0.0,
            round: 0,
            orbs: vec![],
            targets: vec![],
            picked: vec![],
            swaps: vec![],
            probe: None,
            results: vec![],
            serial: 0,
        }
    }

    fn occluded(&self, y: f64) -> bool {
        let r = self.p.radius;
        self.bands.iter().any(|&(a, b)| y + r * 0.3 > a && y - r * 0.3 < b)
    }

    /// Fresh layout: well spaced, nobody starts behind an occluder, random headings, K targets.
    fn new_round(&mut self) {
        let (n, r) = (self.p.n, self.p.radius);
        let min_d = 2.4 * r;
        let margin = r + 10.0;
        let mut orbs: Vec<Orb> = Vec::with_capacity(n);
        for _ in 0..n {
            let mut best = (0.0, 0.0, -1.0f64);
            for _ in 0..400 {
                let x = margin + self.rng.f64() * (W - 2.0 * margin);
                let y = margin + self.rng.f64() * (H - 2.0 * margin);
                let free = self.bands.iter().all(|&(a, b)| y + r + 6.0 < a || y - r - 6.0 > b);
                if !free {
                    continue;
                }
                let gap = orbs.iter().map(|o| ((o.x - x).powi(2) + (o.y - y).powi(2)).sqrt()).fold(f64::MAX, f64::min);
                if gap > best.2 {
                    best = (x, y, gap);
                }
                if gap >= min_d {
                    break;
                }
            }
            let h = wrap(self.rng.f64() * TAU);
            orbs.push(Orb { x: best.0, y: best.1, px: best.0, py: best.1, h, th: h, sp: 1.0, tsp: 1.0 });
        }
        self.orbs = orbs;
        let mut idx: Vec<usize> = (0..n).collect();
        self.rng.shuffle(&mut idx);
        let mut t: Vec<usize> = idx.into_iter().take(self.p.k).collect();
        t.sort_unstable();
        self.targets = t;
        self.picked.clear();
        self.swaps.clear();
        self.probe = self.p.probe.then(|| ProbePlan {
            at: (self.p.track_ms * (0.3 + 0.4 * self.rng.f64())).round(),
            orb: self.rng.below(n),
            digit: 1 + self.rng.below(9) as u8,
            start: None,
        });
        self.phase = Phase::Show;
        self.clock = 0.0;
    }

    fn physics(&mut self, dt: f64) {
        let Tracking { p, rng, orbs, .. } = self;
        let r = p.radius;
        for o in orbs.iter_mut() {
            o.px = o.x;
            o.py = o.y;
            if rng.chance(p.turn_rate * dt) {
                o.th = wrap(o.h + (rng.f64() * 2.0 - 1.0) * p.turn_max);
            }
            if p.speed_var > 0.0 && rng.chance(0.6 * dt) {
                o.tsp = 1.0 + (rng.f64() * 2.0 - 1.0) * p.speed_var;
            }
            let m = TURN_SPEED * dt;
            o.h = wrap(o.h + wrap(o.th - o.h).clamp(-m, m));
            o.sp += (o.tsp - o.sp) * (1.5 * dt).min(1.0);
            let v = p.speed * o.sp;
            o.x += o.h.cos() * v * dt;
            o.y += o.h.sin() * v * dt;
            if o.x < r || o.x > W - r {
                o.x = if o.x < r { 2.0 * r - o.x } else { 2.0 * (W - r) - o.x };
                o.h = wrap(PI - o.h);
                o.th = wrap(PI - o.th);
            }
            if o.y < r || o.y > H - r {
                o.y = if o.y < r { 2.0 * r - o.y } else { 2.0 * (H - r) - o.y };
                o.h = wrap(-o.h);
                o.th = wrap(-o.th);
            }
        }
        let n = orbs.len();
        let d2min = 4.0 * r * r;
        for i in 0..n {
            for j in i + 1..n {
                let dx = orbs[j].x - orbs[i].x;
                let dy = orbs[j].y - orbs[i].y;
                let d2 = dx * dx + dy * dy;
                if d2 >= d2min {
                    continue;
                }
                let d = d2.sqrt();
                let (nx, ny) = if d > 1e-9 { (dx / d, dy / d) } else { (1.0, 0.0) };
                // Separate the pair, then exchange the normal velocity components (equal masses).
                let push = (2.0 * r - d) / 2.0;
                orbs[i].x = (orbs[i].x - nx * push).clamp(r, W - r);
                orbs[i].y = (orbs[i].y - ny * push).clamp(r, H - r);
                orbs[j].x = (orbs[j].x + nx * push).clamp(r, W - r);
                orbs[j].y = (orbs[j].y + ny * push).clamp(r, H - r);
                let (si, sj) = (orbs[i].sp, orbs[j].sp);
                let (mut vix, mut viy) = (orbs[i].h.cos() * si, orbs[i].h.sin() * si);
                let (mut vjx, mut vjy) = (orbs[j].h.cos() * sj, orbs[j].h.sin() * sj);
                let rel = (vix - vjx) * nx + (viy - vjy) * ny;
                if rel > 0.0 {
                    vix -= rel * nx;
                    viy -= rel * ny;
                    vjx += rel * nx;
                    vjy += rel * ny;
                    // Each orb keeps its own speed; only the directions change.
                    orbs[i].h = viy.atan2(vix);
                    orbs[i].th = orbs[i].h;
                    orbs[j].h = vjy.atan2(vjx);
                    orbs[j].th = orbs[j].h;
                }
            }
        }
    }

    fn events(&mut self) {
        let dt = STEP_MS / 1000.0;
        for s in self.swaps.iter_mut() {
            s.2 += STEP_MS;
        }
        self.swaps.retain(|s| s.2 < SWAP_MS);
        if self.p.swaps && self.rng.chance(SWAP_RATE * dt) {
            let o = self.rng.below(self.p.n);
            let c = self.rng.below(SWAP_COLORS as usize) as u8;
            if !self.swaps.iter().any(|s| s.0 == o) {
                self.swaps.push((o, c, 0.0));
            }
        }
        if let Some(pr) = &self.probe {
            if pr.start.is_none() && self.clock >= pr.at && !self.occluded(self.orbs[pr.orb].y) {
                let now = self.clock;
                if let Some(pr) = self.probe.as_mut() {
                    pr.start = Some(now);
                }
            }
        }
    }

    fn probe_visible(&self) -> Option<&ProbePlan> {
        if self.phase != Phase::Run {
            return None;
        }
        self.probe.as_ref().filter(|pr| pr.start.is_some_and(|s| self.clock - s < self.p.probe_ms))
    }

    /// One fixed physics/timer step.
    fn step(&mut self) {
        self.clock += STEP_MS;
        match self.phase {
            Phase::Countdown if self.clock >= COUNTDOWN_MS => self.new_round(),
            Phase::Show if self.clock >= self.p.cue_ms => {
                self.phase = Phase::Run;
                self.clock = 0.0;
            }
            Phase::Run => {
                self.physics(STEP_MS / 1000.0);
                self.events();
                if self.clock >= self.p.track_ms {
                    self.phase = Phase::Recall;
                    self.clock = 0.0;
                    self.swaps.clear();
                    for o in self.orbs.iter_mut() {
                        o.px = o.x;
                        o.py = o.y;
                    }
                    // A probe that never got a clear moment is dropped, not asked unfairly.
                    if self.probe.as_ref().is_some_and(|p| p.start.is_none()) {
                        self.probe = None;
                    }
                }
            }
            Phase::Feedback if self.clock >= FEEDBACK_MS => {
                if self.round + 1 >= ROUNDS {
                    self.phase = Phase::Done;
                } else {
                    self.round += 1;
                    self.new_round();
                }
            }
            _ => {}
        }
    }

    fn finish_round(&mut self, answer: Option<u8>) {
        let hits = self.picked.iter().filter(|i| self.targets.contains(i)).count();
        let digit = self.probe.as_ref().map(|p| p.digit);
        self.results.push(RoundResult { hits, probe_ok: digit.map(|d| answer == Some(d)), digit, answer });
        self.phase = Phase::Feedback;
        self.clock = 0.0;
        self.serial += 1;
    }

    fn perfect(&self) -> usize {
        self.results.iter().filter(|r| r.perfect(self.p.k)).count()
    }

    fn stars(&self) -> u32 {
        if self.phase == Phase::Done {
            stars_for(self.perfect())
        } else {
            0
        }
    }

    fn status(&self) -> &'static str {
        match self.phase {
            Phase::Done if self.stars() > 0 => "won",
            Phase::Done => "lost",
            _ => "playing",
        }
    }

    fn summary(&self) -> String {
        let hits: usize = self.results.iter().map(|r| r.hits).sum();
        let mut s = format!(
            "Kusursuz tur {}/{} · İsabet {}/{}",
            self.perfect(),
            ROUNDS,
            hits,
            self.p.k * self.results.len().max(1)
        );
        let probes: Vec<bool> = self.results.iter().filter_map(|r| r.probe_ok).collect();
        if !probes.is_empty() {
            s += &format!(" · Rakam {}/{}", probes.iter().filter(|&&b| b).count(), probes.len());
        }
        s
    }

    fn phase_len(&self) -> Option<f64> {
        match self.phase {
            Phase::Countdown => Some(COUNTDOWN_MS),
            Phase::Show => Some(self.p.cue_ms),
            Phase::Run => Some(self.p.track_ms),
            Phase::Feedback => Some(FEEDBACK_MS),
            _ => None,
        }
    }
}

impl Session for Tracking {
    fn state(&self) -> Value {
        let p = &self.p;
        let alpha = if self.phase == Phase::Run { (self.acc / STEP_MS).clamp(0.0, 1.0) } else { 1.0 };
        let mut pos = Vec::with_capacity(self.orbs.len() * 2);
        for o in &self.orbs {
            pos.push(((o.px + (o.x - o.px) * alpha) * 10.0).round() as i64);
            pos.push(((o.py + (o.y - o.py) * alpha) * 10.0).round() as i64);
        }
        let reveal = matches!(self.phase, Phase::Show | Phase::Feedback | Phase::Done);
        let mut extras = vec![];
        if p.occluders > 0 {
            extras.push("perde");
        }
        if p.swaps {
            extras.push("renk tuzağı");
        }
        if p.probe {
            extras.push("rakam");
        }
        let goal = format!(
            "{} hedefi {} sn izle, sonra seç · {} tur{}",
            p.k,
            fmt_secs(p.track_ms),
            ROUNDS,
            if extras.is_empty() { String::new() } else { format!(" · {}", extras.join(" + ")) }
        );
        let results: Vec<Value> = self
            .results
            .iter()
            .map(|r| json!({"hits": r.hits, "k": p.k, "probe": r.probe_ok, "perfect": r.perfect(p.k)}))
            .collect();
        let last = matches!(self.phase, Phase::Feedback | Phase::Done)
            .then(|| self.results.last())
            .flatten()
            .map(|r| json!({"hits": r.hits, "k": p.k, "probe_ok": r.probe_ok, "digit": r.digit, "answer": r.answer}));
        json!({
            "status": self.status(),
            "stars": self.stars(),
            "title": format!("{} hedef · {} küre", p.k, p.n),
            "goal": goal,
            "summary": (self.phase == Phase::Done).then(|| self.summary()),
            "phase": match self.phase {
                Phase::Intro => "intro", Phase::Countdown => "countdown", Phase::Show => "show",
                Phase::Run => "run", Phase::Recall => "recall", Phase::Probe => "probe",
                Phase::Feedback => "feedback", Phase::Done => "done",
            },
            "phase_ms": (self.clock + if self.phase == Phase::Run { self.acc } else { 0.0 }).round(),
            "phase_len": self.phase_len(),
            "countdown_ms": if self.phase == Phase::Countdown { (COUNTDOWN_MS - self.clock).max(0.0).round() } else { 0.0 },
            "round": (self.round + 1).min(ROUNDS),
            "rounds": ROUNDS,
            "k": p.k,
            "n": p.n,
            "radius": p.radius,
            "arena": [W, H],
            "pos": pos,
            "targets": if reveal { self.targets.clone() } else { vec![] },
            "picked": self.picked,
            "occluders": self.bands.iter().map(|&(a, b)| json!([a.round(), b.round()])).collect::<Vec<_>>(),
            "swaps": self.swaps.iter().map(|s| json!([s.0, s.1, s.2.round()])).collect::<Vec<_>>(),
            "probe": self.probe_visible().map(|pr| json!({"orb": pr.orb, "digit": pr.digit})),
            "has_probe": p.probe,
            "lures": p.swaps,
            "track_ms": p.track_ms,
            "results": results,
            "perfect": self.perfect(),
            "serial": self.serial,
            "last": last,
        })
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if self.phase == Phase::Done {
            return Err("Bölüm bitti".into());
        }
        if a["start"].as_bool() == Some(true) {
            if self.phase != Phase::Intro {
                return Err("Zaten başladı".into());
            }
            self.phase = Phase::Countdown;
            self.clock = 0.0;
            self.acc = 0.0;
            return Ok(());
        }
        if let Some(i) = a.get("pick") {
            let i = i.as_u64().ok_or("Geçersiz küre")? as usize;
            if self.phase != Phase::Recall {
                return Err(if self.phase == Phase::Probe { "Önce rakamı seç" } else { "Küreler durunca seç" }.into());
            }
            if i >= self.p.n {
                return Err("Geçersiz küre".into());
            }
            if let Some(at) = self.picked.iter().position(|&x| x == i) {
                self.picked.remove(at);
                return Ok(());
            }
            self.picked.push(i);
            if self.picked.len() == self.p.k {
                if self.probe.is_some() {
                    self.phase = Phase::Probe;
                    self.clock = 0.0;
                } else {
                    self.finish_round(None);
                }
            }
            return Ok(());
        }
        if let Some(d) = a.get("probe") {
            if self.phase != Phase::Probe {
                return Err("Şu an rakam sorulmuyor".into());
            }
            let d = d.as_u64().filter(|d| (1..=9).contains(d)).ok_or("1 ile 9 arasında bir rakam seç")?;
            self.finish_round(Some(d as u8));
            return Ok(());
        }
        Err("Bilinmeyen hamle".into())
    }

    fn tick(&mut self, dt_ms: f64) {
        if dt_ms.is_nan() || dt_ms <= 0.0 || matches!(self.phase, Phase::Intro | Phase::Recall | Phase::Probe | Phase::Done) {
            return;
        }
        self.acc += dt_ms;
        while self.acc >= STEP_MS {
            self.acc -= STEP_MS;
            self.step();
            if matches!(self.phase, Phase::Recall | Phase::Probe | Phase::Done) {
                self.acc = 0.0;
                break;
            }
        }
    }
}

fn fmt_secs(ms: f64) -> String {
    let s = ms / 1000.0;
    if (s - s.round()).abs() < 1e-9 {
        format!("{}", s.round())
    } else {
        format!("{:.1}", s).replace('.', ",")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LEVELS: [u32; 9] = [1, 2, 3, 50, 137, 250, 400, 499, 500];

    fn start(g: &mut Tracking) {
        g.act(&json!({"start": true})).unwrap();
        g.tick(COUNTDOWN_MS);
        assert_eq!(g.phase, Phase::Show);
    }

    /// Tick in `chunk` ms steps until the motion stops; checks the arena bounds after every tick.
    fn run_to_recall(g: &mut Tracking, chunk: f64) {
        let r = g.p.radius;
        let mut guard = 0;
        while matches!(g.phase, Phase::Show | Phase::Run) {
            g.tick(chunk);
            for o in &g.orbs {
                assert!(o.x >= r - 1e-6 && o.x <= W - r + 1e-6, "x out of arena: {}", o.x);
                assert!(o.y >= r - 1e-6 && o.y <= H - r + 1e-6, "y out of arena: {}", o.y);
            }
            guard += 1;
            assert!(guard < 100_000);
        }
    }

    fn finish_feedback(g: &mut Tracking) {
        assert_eq!(g.phase, Phase::Feedback);
        g.tick(FEEDBACK_MS);
    }

    /// Plays one round: `wrong` = how many of the K picks are non-targets; `probe_ok` answers right.
    fn play_round(g: &mut Tracking, wrong: usize, probe_ok: bool) {
        run_to_recall(g, 16.0);
        assert_eq!(g.phase, Phase::Recall);
        let targets = g.targets.clone();
        let others: Vec<usize> = (0..g.p.n).filter(|i| !targets.contains(i)).collect();
        let picks: Vec<usize> =
            others.iter().take(wrong).chain(targets.iter().take(g.p.k - wrong)).copied().collect();
        for i in picks {
            g.act(&json!({"pick": i})).unwrap();
        }
        if g.phase == Phase::Probe {
            let d = g.probe.as_ref().unwrap().digit;
            let ans = if probe_ok { d } else { d % 9 + 1 };
            g.act(&json!({"probe": ans})).unwrap();
        }
        finish_feedback(g);
    }

    #[test]
    fn curve_shape() {
        let a = params(1);
        assert_eq!((a.k, a.n), (3, 8));
        assert_eq!(a.track_ms, 5000.0);
        assert_eq!(a.occluders + a.swaps as usize + a.probe as usize, 0);
        let z = params(500);
        assert_eq!((z.k, z.n), (6, 16));
        assert_eq!(z.track_ms, 12000.0);
        assert!(z.speed > 400.0 && a.speed < 200.0);
        assert!(params(2).speed > a.speed);
        for level in LEVELS.iter().copied().chain(1..=500) {
            let p = params(level);
            assert!((3..=6).contains(&p.k) && (8..=16).contains(&p.n) && p.n >= 2 * p.k + 2);
            assert!(p.radius >= 41.0 && p.cue_ms >= 1600.0);
        }
        assert!((90..=500).any(|l| params(l).occluders == 1));
        assert!((300..=500).any(|l| params(l).occluders == 2));
        assert!((150..=500).any(|l| params(l).swaps));
        assert!((210..=500).any(|l| params(l).probe));
        assert!((400..=500).any(|l| { let p = params(l); p.swaps && p.occluders > 0 }));
    }

    #[test]
    fn levels_generate_with_spaced_layout() {
        for level in LEVELS {
            let mut g = Tracking::level(level);
            assert_eq!(g.state()["phase"], "intro");
            start(&mut g);
            let r = g.p.radius;
            assert_eq!(g.orbs.len(), g.p.n);
            assert_eq!(g.targets.len(), g.p.k);
            for i in 0..g.orbs.len() {
                for j in i + 1..g.orbs.len() {
                    let d = ((g.orbs[i].x - g.orbs[j].x).powi(2) + (g.orbs[i].y - g.orbs[j].y).powi(2)).sqrt();
                    assert!(d >= 2.4 * r - 1e-6, "level {level}: orbs too close at start");
                }
                assert!(!g.occluded(g.orbs[i].y) || g.bands.is_empty(), "level {level}: starts hidden");
            }
            let st = g.state();
            assert_eq!(st["pos"].as_array().unwrap().len(), 2 * g.p.n);
            assert_eq!(st["targets"].as_array().unwrap().len(), g.p.k);
        }
    }

    #[test]
    fn deterministic_and_frame_rate_independent() {
        for level in LEVELS {
            let mut a = Tracking::level(level);
            let mut b = Tracking::level(level);
            let mut c = Tracking::level(level);
            start(&mut a);
            start(&mut b);
            start(&mut c);
            assert_eq!(a.orbs, b.orbs);
            assert_eq!(a.targets, b.targets);
            // 7 ms vs 5 ms vs 3.5 ms chunks over the same total time → identical motion.
            for _ in 0..1000 {
                a.tick(7.0);
            }
            for _ in 0..1400 {
                b.tick(5.0);
            }
            for _ in 0..2000 {
                c.tick(3.5);
            }
            assert_eq!(a.orbs, b.orbs, "level {level}");
            assert_eq!(a.orbs, c.orbs, "level {level}");
            assert_eq!(a.state(), b.state());
        }
    }

    #[test]
    fn physics_stays_inside_and_orbs_do_not_pass_through() {
        for level in LEVELS {
            let mut g = Tracking::level(level);
            start(&mut g);
            let r = g.p.radius;
            let mut moved = 0.0;
            let start_pos: Vec<(f64, f64)> = g.orbs.iter().map(|o| (o.x, o.y)).collect();
            let mut guard = 0;
            while matches!(g.phase, Phase::Show | Phase::Run) {
                g.tick(16.0);
                for (i, o) in g.orbs.iter().enumerate() {
                    assert!(o.x >= r - 1e-6 && o.x <= W - r + 1e-6 && o.y >= r - 1e-6 && o.y <= H - r + 1e-6);
                    for q in &g.orbs[i + 1..] {
                        let d = ((o.x - q.x).powi(2) + (o.y - q.y).powi(2)).sqrt();
                        assert!(d > 1.2 * r, "level {level}: deep overlap {d}");
                    }
                }
                guard += 1;
                assert!(guard < 10_000);
            }
            for (o, s) in g.orbs.iter().zip(&start_pos) {
                moved += ((o.x - s.0).powi(2) + (o.y - s.1).powi(2)).sqrt();
            }
            assert!(moved / g.p.n as f64 > 50.0, "level {level}: orbs barely moved");
            assert_eq!(g.phase, Phase::Recall);
            // Motion is over: positions are frozen.
            let before = g.state()["pos"].clone();
            g.tick(500.0);
            assert_eq!(g.state()["pos"], before);
        }
    }

    #[test]
    fn targets_hidden_while_moving() {
        let mut g = Tracking::level(1);
        start(&mut g);
        assert_eq!(g.state()["targets"].as_array().unwrap().len(), 3);
        g.tick(g.p.cue_ms + 10.0);
        assert_eq!(g.state()["phase"], "run");
        assert!(g.state()["targets"].as_array().unwrap().is_empty());
        run_to_recall(&mut g, 16.0);
        assert!(g.state()["targets"].as_array().unwrap().is_empty());
    }

    #[test]
    fn perfect_play_three_stars_on_every_level() {
        for level in LEVELS.iter().copied().chain([210, 214, 450]) {
            let mut g = Tracking::level(level);
            start(&mut g);
            for _ in 0..ROUNDS {
                play_round(&mut g, 0, true);
            }
            let st = g.state();
            assert_eq!(st["status"], "won", "level {level}");
            assert_eq!(st["stars"], 3);
            assert_eq!(st["perfect"], 4);
            assert!(st["summary"].as_str().unwrap().starts_with("Kusursuz tur 4/4"));
        }
    }

    #[test]
    fn selection_scoring_and_stars() {
        // 3 perfect + 1 round with one wrong pick → 2 stars.
        let mut g = Tracking::level(5);
        start(&mut g);
        play_round(&mut g, 0, true);
        play_round(&mut g, 1, true);
        assert_eq!(g.results[1].hits, g.p.k - 1);
        play_round(&mut g, 0, true);
        play_round(&mut g, 0, true);
        assert_eq!(g.state()["stars"], 2);
        assert_eq!(g.state()["status"], "won");
        // Two perfect rounds → 1 star; one → lost.
        for (good, stars, status) in [(2, 1, "won"), (1, 0, "lost")] {
            let mut g = Tracking::level(7);
            start(&mut g);
            for r in 0..ROUNDS {
                play_round(&mut g, if r < good { 0 } else { 2 }, true);
            }
            assert_eq!(g.state()["stars"], stars);
            assert_eq!(g.state()["status"], status);
        }
    }

    #[test]
    fn probe_must_be_answered_correctly() {
        let level = (210..=260).find(|&l| params(l).probe).unwrap();
        let mut g = Tracking::level(level);
        start(&mut g);
        // Something was shown during the motion.
        let mut seen = None;
        while matches!(g.phase, Phase::Show | Phase::Run) {
            g.tick(16.0);
            if let Some(pr) = g.state()["probe"].as_object() {
                seen = pr.get("digit").and_then(|d| d.as_u64());
            }
        }
        assert_eq!(seen, Some(g.probe.as_ref().unwrap().digit as u64));
        for &t in &g.targets.clone() {
            g.act(&json!({"pick": t})).unwrap();
        }
        assert_eq!(g.state()["phase"], "probe");
        assert!(g.act(&json!({"pick": 0})).is_err());
        assert!(g.act(&json!({"probe": 0})).is_err());
        let wrong = seen.unwrap() as u8 % 9 + 1;
        g.act(&json!({"probe": wrong})).unwrap();
        assert_eq!(g.results[0].hits, g.p.k);
        assert!(!g.results[0].perfect(g.p.k));
        assert_eq!(g.state()["last"]["probe_ok"], false);
    }

    #[test]
    fn picks_toggle_and_illegal_actions_rejected() {
        let mut g = Tracking::level(1);
        let before = g.state();
        assert!(g.act(&json!({"pick": 0})).is_err());
        assert!(g.act(&json!({"probe": 3})).is_err());
        assert!(g.act(&json!({"jump": 1})).is_err());
        assert_eq!(g.state(), before);
        start(&mut g);
        assert!(g.act(&json!({"start": true})).is_err());
        let before = g.state();
        assert!(g.act(&json!({"pick": 0})).is_err()); // still showing the cue
        assert_eq!(g.state(), before);
        g.tick(g.p.cue_ms + 50.0);
        let before = g.state();
        assert!(g.act(&json!({"pick": 0})).is_err()); // moving
        assert_eq!(g.state(), before);
        run_to_recall(&mut g, 20.0);
        let before = g.state();
        assert!(g.act(&json!({"pick": 99})).is_err());
        assert!(g.act(&json!({"pick": "a"})).is_err());
        assert_eq!(g.state(), before);
        g.act(&json!({"pick": 2})).unwrap();
        assert_eq!(g.picked, vec![2]);
        g.act(&json!({"pick": 2})).unwrap();
        assert!(g.picked.is_empty());
        assert_eq!(g.phase, Phase::Recall);
    }

    #[test]
    #[ignore]
    fn timing_500_levels() {
        let t = std::time::Instant::now();
        let mut worst = 0.0f64;
        for level in 1..=500 {
            let s = std::time::Instant::now();
            let mut g = Tracking::level(level);
            g.act(&json!({"start": true})).unwrap();
            g.tick(COUNTDOWN_MS);
            worst = worst.max(s.elapsed().as_secs_f64());
        }
        // One full motion phase of the hardest level, simulated at 120 Hz ticks.
        let mut g = Tracking::level(500);
        g.act(&json!({"start": true})).unwrap();
        g.tick(COUNTDOWN_MS);
        let s = std::time::Instant::now();
        let mut ticks = 0;
        while matches!(g.phase, Phase::Show | Phase::Run) {
            g.tick(8.333);
            let _ = g.state();
            ticks += 1;
        }
        let per = s.elapsed().as_secs_f64() / ticks as f64 * 1e6;
        println!("tracking: 500 layouts in {:?}, worst {:.3} ms; tick+state {per:.1} µs", t.elapsed(), worst * 1000.0);
    }
}
