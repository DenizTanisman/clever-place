//! Dönen Sayılar — visual search on a moving field. The numbers 1..N are scattered over concentric
//! rings that turn all the time, each ring at its own speed and against its neighbours. The player
//! taps them in ascending order inside one minute; nothing marks the next number (except, on the
//! early levels, a faint cue around the 1 until it is tapped).
//!
//! A new game rather than a Schulte mode: Schulte is a static grid scored by time over a 500-level
//! curve of orders, styling and reshuffles, while this game is a moving polar field judged by tap
//! position, scored by how far you get in 60 s, and it has an endless mode.
//!
//! **Geometry.** The board is a disc of radius [`BOARD_R`] units, centre at (0, 0), +y down (screen
//! axes). A number at ring angle `a` sits at `(r·cos a, r·sin a)`. Numbers on one ring keep their
//! relative angles, and neighbouring rings are further apart than one disc diameter, so two discs can
//! never touch at any moment, whatever the rings do. Numbers stay upright (the view moves them, it
//! does not rotate them).
//!
//! **Motion** is a closed-form function of the board clock (`Ring::angle`), never integrated, so it
//! is exact for any refresh rate. A plain ring turns at constant speed. A reversing ring runs for
//! `flip_ms`, eases to a stop and back the other way over [`RAMP_MS`] at each end.
//!
//! Level curve (`params(level)`), levels 1..=200, t = (level − 1) / 199:
//! - Rings: 2 (1–30) · 3 (31–90) · 4 (91–150) · 5 (151–200). Numbers: 12 + round(36·t) → 12..48.
//! - Speed: outer-ring speed for multiplier 1 is 60 + 170·t^1.15 units/s; each ring gets its own
//!   multiplier from 1.0, 1.2, … 1.8, and directions alternate from ring to ring.
//! - Reversing rings: none before 40, one from 40, half from 100, all from 160; a run lasts 9 s at
//!   40 falling to 3 s at 200 (±15 % per ring).
//! - First-number cue on levels 1..=60.
//!
//! Scoring: every level is a 60 s run. A wrong tap costs [`PENALTY_MS`] of the minute. Tapping every
//! number ends the run early. Targets: t3 = min(N, ⌈60 s / pace⌉) with pace 1.05 s → 1.8 s per number,
//! t2 = ⌈0.75·t3⌉, t1 = ⌈0.5·t3⌉. Stars: ≥ t3 with ≤ 2 errors → 3 · ≥ t2 with ≤ 5 errors → 2 ·
//! ≥ t1 → 1 · below t1 the level is lost.
//!
//! Endless (`mode == "endless"`): one clock starting at 60 s; clearing a board adds
//! [`ENDLESS_BONUS_MS`] and deals a harder one (stage s plays like level 1 + 9·(s − 1)). When the
//! clock runs out the run ends with `status: "lost"` and `score` = numbers tapped.
//!
//! State: `{status, stars, mode, level, phase: "intro"|"countdown"|"run"|"done", title, goal, summary?,
//!          board_r, token_r, hit_r, rings: [{r, a}], numbers: [{n, ring, a, found, cue}] | null (hidden
//!          before the run), total, found, errors, score, stage, targets: [t1, t2, t3] | null,
//!          next_goal: {n, stars} | null, max_errors: [e3, e2], elapsed_ms, remaining_ms, limit_ms,
//!          countdown_ms, penalty_ms, first_cue, reversing, board_serial,
//!          last: {serial, n, ok} | null}`.
//! A number's screen angle is its `a` plus its ring's current `a`. The next expected number is not
//! part of the state on purpose: the view cannot highlight what it does not know.
//!
//! Actions: `{"start":true}` · `{"tap":[x, y]}` (board units). The core picks the nearest number not
//! yet tapped within `hit_r` (1.75 disc radii, so a thumb need not land on the digit); a tap that
//! reaches no number is ignored without penalty.

use crate::rng::{seed_for, time_seed, Rng};
use crate::Session;
use serde_json::{json, Value};
use std::f64::consts::TAU;

pub const LEVELS: u32 = 200;
pub const RUN_MS: f64 = 60_000.0;
pub const COUNTDOWN_MS: f64 = 3000.0;
pub const PENALTY_MS: f64 = 2000.0;
pub const BOARD_R: f64 = 1000.0;
/// Time a reversing ring takes to ease to a stop (and to get going again).
pub const RAMP_MS: f64 = 500.0;
/// Smallest allowed empty space between two number discs, in board units.
pub const MIN_CLEARANCE: f64 = 8.0;
/// Most errors still worth three stars, then two stars.
pub const MAX_ERRORS_3: u32 = 2;
pub const MAX_ERRORS_2: u32 = 5;
pub const ENDLESS_BONUS_MS: f64 = 12_000.0;
/// Endless: levels of difficulty added per cleared board.
const STAGE_STEP: u32 = 9;
/// Tap reach, in disc radii.
const HIT_FACTOR: f64 = 1.75;
/// Margin between the outer discs and the rim of the board.
const RIM_MARGIN: f64 = 12.0;
/// Empty space kept between neighbours on one ring.
const RING_GAP: f64 = 20.0;
const MULTIPLIERS: [f64; 5] = [1.0, 1.2, 1.4, 1.6, 1.8];

#[derive(Clone, Debug, PartialEq)]
pub struct Params {
    pub n: usize,
    pub rings: usize,
    /// Outer-ring speed for multiplier 1, units per second.
    pub speed: f64,
    pub reversing: usize,
    pub flip_ms: f64,
    /// Numbers needed for 1, 2, 3 stars.
    pub targets: [usize; 3],
    pub first_cue: bool,
}

pub fn params(level: u32) -> Params {
    let l = level.clamp(1, LEVELS);
    let t = (l - 1) as f64 / (LEVELS - 1) as f64;
    let rings = match l {
        1..=30 => 2,
        31..=90 => 3,
        91..=150 => 4,
        _ => 5,
    };
    let n = 12 + (36.0 * t).round() as usize;
    let speed = 60.0 + 170.0 * t.powf(1.15);
    let reversing = match l {
        1..=39 => 0,
        40..=99 => 1,
        100..=159 => rings / 2,
        _ => rings,
    };
    let flip_ms = if reversing == 0 {
        0.0
    } else {
        ((9000.0 - 6000.0 * (l - 40) as f64 / 160.0) / 100.0).round() * 100.0
    };
    let pace = 1.05 + 0.75 * t;
    let t3 = n.min((RUN_MS / 1000.0 / pace).ceil() as usize);
    let t2 = (0.75 * t3 as f64).ceil() as usize;
    let t1 = (0.5 * t3 as f64).ceil() as usize;
    Params { n, rings, speed, reversing, flip_ms, targets: [t1, t2, t3], first_cue: l <= 60 }
}

/// Disc radius and innermost ring radius for a ring count. Bigger discs when there is room.
fn geometry(rings: usize) -> (f64, f64) {
    match rings {
        0..=2 => (135.0, 440.0),
        3 => (120.0, 300.0),
        4 => (102.0, 210.0),
        _ => (88.0, 150.0),
    }
}

fn ring_radii(rings: usize, token_r: f64) -> Vec<f64> {
    let inner = geometry(rings).1;
    let outer = BOARD_R - token_r - RIM_MARGIN;
    (0..rings).map(|i| inner + (outer - inner) * i as f64 / (rings - 1) as f64).collect()
}

/// Smallest angle between two neighbours on a ring of `radius`, so their discs stay `RING_GAP` apart.
fn min_angle(radius: f64, token_r: f64) -> f64 {
    let chord = 2.0 * token_r + RING_GAP;
    2.0 * (chord / (2.0 * radius)).clamp(0.0, 1.0).asin()
}

fn capacity(radius: f64, token_r: f64) -> usize {
    (TAU / min_angle(radius, token_r)).floor() as usize
}

/// How many numbers each ring holds: proportional to its radius, never above its capacity.
fn distribute(n: usize, radii: &[f64], token_r: f64) -> Vec<usize> {
    let total: f64 = radii.iter().sum();
    let share = |r: f64| n as f64 * r / total;
    let caps: Vec<usize> = radii.iter().map(|&r| capacity(r, token_r)).collect();
    let mut counts: Vec<usize> =
        radii.iter().zip(&caps).map(|(&r, &c)| (share(r).floor() as usize).min(c)).collect();
    while counts.iter().sum::<usize>() < n {
        let best = (0..radii.len())
            .filter(|&i| counts[i] < caps[i])
            .max_by(|&a, &b| {
                let (da, db) = (share(radii[a]) - counts[a] as f64, share(radii[b]) - counts[b] as f64);
                da.total_cmp(&db)
            })
            .expect("level curve exceeds ring capacity");
        counts[best] += 1;
    }
    counts
}

#[derive(Clone, Debug, PartialEq)]
struct Ring {
    radius: f64,
    /// Signed angular speed at full pace, radians per second.
    omega: f64,
    phase0: f64,
    /// Length of one run between reversals; 0 = never reverses.
    flip_ms: f64,
}

impl Ring {
    /// Ring angle `t_ms` into the board's life. Closed form: trapezoidal speed, position continuous
    /// and speed zero at each reversal.
    fn angle(&self, t_ms: f64) -> f64 {
        let w = self.omega / 1000.0;
        if self.flip_ms <= 0.0 {
            return self.phase0 + w * t_ms;
        }
        let f = self.flip_ms;
        let k = (t_ms / f).floor();
        let s = t_ms - k * f;
        let full = w * (f - RAMP_MS);
        let along = if s < RAMP_MS {
            w * s * s / (2.0 * RAMP_MS)
        } else if s <= f - RAMP_MS {
            w * (s - RAMP_MS / 2.0)
        } else {
            full - w * (f - s) * (f - s) / (2.0 * RAMP_MS)
        };
        self.phase0 + if (k as i64) % 2 == 0 { along } else { full - along }
    }
}

#[derive(Clone, Debug, PartialEq)]
struct Num {
    ring: usize,
    angle0: f64,
}

#[derive(Clone, Debug, PartialEq)]
struct Board {
    rings: Vec<Ring>,
    /// Index = number − 1.
    nums: Vec<Num>,
    token_r: f64,
    hit_r: f64,
}

impl Board {
    fn generate(p: &Params, rng: &mut Rng) -> Board {
        let token_r = geometry(p.rings).0;
        let radii = ring_radii(p.rings, token_r);
        let counts = distribute(p.n, &radii, token_r);
        let mut mult = MULTIPLIERS[..p.rings].to_vec();
        rng.shuffle(&mut mult);
        let mut reversers: Vec<usize> = (0..p.rings).collect();
        rng.shuffle(&mut reversers);
        reversers.truncate(p.reversing);
        let mut sign = if rng.chance(0.5) { 1.0 } else { -1.0 };
        let outer = radii[p.rings - 1];
        let mut rings = Vec::with_capacity(p.rings);
        for (i, &radius) in radii.iter().enumerate() {
            let flip_ms = if reversers.contains(&i) {
                ((p.flip_ms * (0.85 + 0.3 * rng.f64()) / 50.0).round() * 50.0).max(2000.0)
            } else {
                0.0
            };
            rings.push(Ring { radius, omega: sign * p.speed * mult[i] / outer, phase0: rng.f64() * TAU, flip_ms });
            sign = -sign;
        }
        let mut ids: Vec<usize> = (0..p.n).collect();
        rng.shuffle(&mut ids);
        let mut nums = vec![Num { ring: 0, angle0: 0.0 }; p.n];
        let mut next_id = 0;
        for (ring, &count) in counts.iter().enumerate() {
            let slot = TAU / count as f64;
            let slack = (slot - min_angle(radii[ring], token_r)).max(0.0);
            for j in 0..count {
                let angle0 = j as f64 * slot + rng.f64() * slack * 0.7;
                nums[ids[next_id]] = Num { ring, angle0 };
                next_id += 1;
            }
        }
        Board { rings, nums, token_r, hit_r: token_r * HIT_FACTOR }
    }

    fn position(&self, id: usize, t_ms: f64) -> (f64, f64) {
        let num = &self.nums[id];
        let ring = &self.rings[num.ring];
        let a = num.angle0 + ring.angle(t_ms);
        (ring.radius * a.cos(), ring.radius * a.sin())
    }
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Phase {
    Intro,
    Countdown,
    Run,
    Done,
}

pub struct DonenSayilar {
    level: u32,
    endless: bool,
    rng: Rng,
    p: Params,
    board: Board,
    /// Index = number − 1.
    found: Vec<bool>,
    /// Numbers tapped on this board; the next expected number is `done + 1`.
    done: usize,
    phase: Phase,
    countdown_ms: f64,
    /// Time used, penalties included.
    elapsed_ms: f64,
    limit_ms: f64,
    /// Board clock: real run time since this board was dealt. Penalties do not move the rings.
    motion_ms: f64,
    errors: u32,
    score: u32,
    stage: u32,
    board_serial: u32,
    last: Option<(u32, usize, bool)>,
    serial: u32,
    won: bool,
}

pub fn create(level: u32, mode: &str) -> Result<Box<dyn Session>, String> {
    Ok(Box::new(if mode == "endless" { DonenSayilar::endless(time_seed()) } else { DonenSayilar::level(level) }))
}

fn stage_params(stage: u32) -> Params {
    params((1 + (stage - 1).saturating_mul(STAGE_STEP)).min(LEVELS))
}

impl DonenSayilar {
    pub fn level(level: u32) -> Self {
        let level = level.clamp(1, LEVELS);
        Self::with(level, false, params(level), Rng::new(seed_for("donen_sayilar", level, 0)))
    }

    pub fn endless(seed: u64) -> Self {
        Self::with(1, true, stage_params(1), Rng::new(seed))
    }

    fn with(level: u32, endless: bool, p: Params, mut rng: Rng) -> Self {
        let board = Board::generate(&p, &mut rng);
        DonenSayilar {
            level,
            endless,
            rng,
            found: vec![false; p.n],
            p,
            board,
            done: 0,
            phase: Phase::Intro,
            countdown_ms: COUNTDOWN_MS,
            elapsed_ms: 0.0,
            limit_ms: RUN_MS,
            motion_ms: 0.0,
            errors: 0,
            score: 0,
            stage: 1,
            board_serial: 0,
            last: None,
            serial: 0,
            won: false,
        }
    }

    fn stars(&self) -> u32 {
        if !self.won {
            return 0;
        }
        let [t1, t2, t3] = self.p.targets;
        if self.done >= t3 && self.errors <= MAX_ERRORS_3 {
            3
        } else if self.done >= t2 && self.errors <= MAX_ERRORS_2 {
            2
        } else if self.done >= t1 {
            1
        } else {
            0
        }
    }

    fn status(&self) -> &'static str {
        match self.phase {
            Phase::Done if self.won => "won",
            Phase::Done => "lost",
            _ => "playing",
        }
    }

    /// The number not yet tapped nearest to (x, y), if it is within reach.
    fn number_at(&self, x: f64, y: f64) -> Option<usize> {
        let reach = self.board.hit_r * self.board.hit_r;
        (0..self.p.n)
            .filter(|&id| !self.found[id])
            .map(|id| {
                let (px, py) = self.board.position(id, self.motion_ms);
                (id, (px - x).powi(2) + (py - y).powi(2))
            })
            .filter(|&(_, d)| d <= reach)
            .min_by(|a, b| a.1.total_cmp(&b.1))
            .map(|(id, _)| id)
    }

    fn finish(&mut self) {
        self.phase = Phase::Done;
        self.won = !self.endless && self.done >= self.p.targets[0];
    }

    fn time_up(&mut self) {
        self.elapsed_ms = self.limit_ms;
        self.finish();
    }

    fn next_board(&mut self) {
        self.stage += 1;
        self.p = stage_params(self.stage);
        self.board = Board::generate(&self.p, &mut self.rng);
        self.found = vec![false; self.p.n];
        self.done = 0;
        self.motion_ms = 0.0;
        self.limit_ms += ENDLESS_BONUS_MS;
        self.board_serial += 1;
    }

    fn tap(&mut self, id: usize) {
        let ok = id == self.done;
        self.serial += 1;
        self.last = Some((self.serial, id + 1, ok));
        if ok {
            self.found[id] = true;
            self.done += 1;
            self.score += 1;
            if self.done == self.p.n {
                if self.endless {
                    self.next_board();
                } else {
                    self.finish();
                }
            }
        } else {
            self.errors += 1;
            self.elapsed_ms += PENALTY_MS;
            if self.elapsed_ms >= self.limit_ms {
                self.time_up();
            }
        }
    }

    fn title(&self) -> String {
        if self.endless {
            return format!("Sonsuz · Tur {}", self.stage);
        }
        let mut title = format!("{} sayı · {} halka", self.p.n, self.p.rings);
        if self.p.reversing > 0 {
            title.push_str(" · dönüşlü");
        }
        title
    }

    fn goal(&self) -> String {
        if self.endless {
            return format!("Süre bitmeden topla · her tam tur +{} sn", (ENDLESS_BONUS_MS / 1000.0) as u32);
        }
        format!("60 saniyede 1'den ileri · ★★★ {} sayı, en çok {MAX_ERRORS_3} hata", self.p.targets[2])
    }

    fn summary(&self) -> String {
        if self.endless {
            return format!("Toplam {} sayı · Tur {} · Hata {}", self.score, self.stage, self.errors);
        }
        let left = clock((self.limit_ms - self.elapsed_ms).max(0.0));
        if self.won {
            format!("Ulaşılan {}/{} · Hata {} · Kalan {}", self.done, self.p.n, self.errors, left)
        } else {
            format!("Süre doldu · {}/{} · 1 yıldız için {} · Hata {}", self.done, self.p.n, self.p.targets[0], self.errors)
        }
    }

    fn next_goal(&self) -> Option<Value> {
        if self.endless {
            return None;
        }
        self.p.targets.iter().position(|&t| t > self.done).map(|i| json!({"n": self.p.targets[i], "stars": i + 1}))
    }
}

/// `m:ss,t` (tenths), e.g. `0:23,4`.
fn clock(ms: f64) -> String {
    let tenths = (ms / 100.0).round().max(0.0) as u64;
    format!("{}:{:02},{}", tenths / 600, (tenths / 10) % 60, tenths % 10)
}

fn round4(x: f64) -> f64 {
    (x * 1e4).round() / 1e4
}

impl Session for DonenSayilar {
    fn state(&self) -> Value {
        let visible = matches!(self.phase, Phase::Run | Phase::Done);
        let numbers = visible.then(|| {
            self.board
                .nums
                .iter()
                .enumerate()
                .map(|(id, num)| {
                    let cue = id == 0 && self.p.first_cue && !self.found[0];
                    json!({"n": id + 1, "ring": num.ring, "a": round4(num.angle0), "found": self.found[id], "cue": cue})
                })
                .collect::<Vec<_>>()
        });
        let rings: Vec<Value> =
            self.board.rings.iter().map(|r| json!({"r": r.radius, "a": round4(r.angle(self.motion_ms))})).collect();
        json!({
            "status": self.status(),
            "stars": self.stars(),
            "mode": if self.endless { "endless" } else { "level" },
            "level": self.level,
            "phase": match self.phase {
                Phase::Intro => "intro", Phase::Countdown => "countdown", Phase::Run => "run", Phase::Done => "done",
            },
            "title": self.title(),
            "goal": self.goal(),
            "summary": if self.phase == Phase::Done { Some(self.summary()) } else { None },
            "board_r": BOARD_R,
            "token_r": self.board.token_r,
            "hit_r": self.board.hit_r,
            "rings": rings,
            "numbers": numbers,
            "total": self.p.n,
            "found": self.done,
            "errors": self.errors,
            "score": self.score,
            "stage": self.stage,
            "targets": if self.endless { None } else { Some(self.p.targets) },
            "next_goal": self.next_goal(),
            "max_errors": [MAX_ERRORS_3, MAX_ERRORS_2],
            "elapsed_ms": self.elapsed_ms.round(),
            "remaining_ms": (self.limit_ms - self.elapsed_ms).max(0.0).round(),
            "limit_ms": self.limit_ms,
            "countdown_ms": self.countdown_ms.max(0.0).round(),
            "penalty_ms": PENALTY_MS,
            "first_cue": self.p.first_cue,
            "reversing": self.p.reversing > 0,
            "board_serial": self.board_serial,
            "last": self.last.map(|(serial, n, ok)| json!({"serial": serial, "n": n, "ok": ok})),
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
        let point = a["tap"].as_array().filter(|p| p.len() == 2).and_then(|p| Some((p[0].as_f64()?, p[1].as_f64()?)));
        let Some((x, y)) = point else {
            return Err("Bilinmeyen hamle".into());
        };
        match self.phase {
            Phase::Intro => return Err("Önce Başla'ya dokun".into()),
            Phase::Countdown => return Err("Geri sayımı bekle".into()),
            _ => {}
        }
        if let Some(id) = self.number_at(x, y) {
            self.tap(id);
        }
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
                }
            }
            Phase::Run => {
                self.elapsed_ms += dt_ms;
                self.motion_ms += dt_ms;
                if self.elapsed_ms >= self.limit_ms {
                    self.time_up();
                }
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: [u32; 9] = [1, 2, 3, 50, 90, 137, 160, 199, 200];

    fn started(level: u32) -> DonenSayilar {
        let mut g = DonenSayilar::level(level);
        g.act(&json!({"start": true})).unwrap();
        g.tick(COUNTDOWN_MS + 1.0);
        assert_eq!(g.phase, Phase::Run);
        g
    }

    fn tap_number(g: &mut DonenSayilar, n: usize) {
        let (x, y) = g.board.position(n - 1, g.motion_ms);
        g.act(&json!({"tap": [x, y]})).unwrap();
    }

    fn tap_next(g: &mut DonenSayilar, count: usize) {
        for _ in 0..count {
            let n = g.done + 1;
            tap_number(g, n);
        }
    }

    /// All discs pairwise apart by at least 2·token_r + MIN_CLEARANCE at `t`, and inside the board.
    fn assert_no_overlap(board: &Board, t: f64, what: &str) {
        let min = 2.0 * board.token_r + MIN_CLEARANCE;
        let pts: Vec<_> = (0..board.nums.len()).map(|i| board.position(i, t)).collect();
        for i in 0..pts.len() {
            let (x, y) = pts[i];
            assert!((x * x + y * y).sqrt() + board.token_r <= BOARD_R, "{what}: number {} leaves the board", i + 1);
            for j in 0..i {
                let d = ((x - pts[j].0).powi(2) + (y - pts[j].1).powi(2)).sqrt();
                assert!(d >= min, "{what}: {} and {} are {d:.1} apart at t={t}", i + 1, j + 1);
            }
        }
    }

    #[test]
    fn params_cover_every_level_sanely() {
        let mut prev = params(1);
        for level in 1..=LEVELS {
            let p = params(level);
            assert!((12..=48).contains(&p.n), "level {level}");
            assert!((2..=5).contains(&p.rings));
            assert!(p.n >= prev.n && p.rings >= prev.rings && p.speed >= prev.speed, "level {level} got easier");
            assert!(p.reversing <= p.rings);
            let [t1, t2, t3] = p.targets;
            assert!(0 < t1 && t1 < t2 && t2 < t3 && t3 <= p.n, "level {level}: {:?}", p.targets);
            let token_r = geometry(p.rings).0;
            let radii = ring_radii(p.rings, token_r);
            let counts = distribute(p.n, &radii, token_r);
            assert_eq!(counts.iter().sum::<usize>(), p.n);
            for (&c, &r) in counts.iter().zip(&radii) {
                assert!(c >= 2 && c <= capacity(r, token_r), "level {level}: ring of radius {r} holds {c}");
            }
            prev = p;
        }
        let first = params(1);
        assert_eq!((first.n, first.rings, first.reversing), (12, 2, 0));
        assert!(first.first_cue && first.speed < 70.0);
        assert_eq!(first.targets, [6, 9, 12]);
        let last = params(LEVELS);
        assert_eq!((last.n, last.rings, last.reversing), (48, 5, 5));
        assert!(!last.first_cue && last.flip_ms <= 3000.0);
        assert!(last.targets[2] < last.n, "late levels cannot be cleared by just matching the pace");
        // Out-of-range levels are clamped, not rejected.
        assert_eq!(params(0), params(1));
        assert_eq!(params(500), params(LEVELS));
    }

    #[test]
    fn levels_are_deterministic_and_differ() {
        for level in SAMPLE {
            let (a, b) = (DonenSayilar::level(level), DonenSayilar::level(level));
            assert_eq!(a.board, b.board);
            assert_eq!(a.board.nums.len(), a.p.n);
        }
        assert_ne!(DonenSayilar::level(1).board, DonenSayilar::level(2).board);
        let (a, b) = (DonenSayilar::endless(7), DonenSayilar::endless(8));
        assert_ne!(a.board, b.board);
    }

    #[test]
    fn numbers_never_overlap_at_any_time() {
        for level in 1..=LEVELS {
            let g = DonenSayilar::level(level);
            let board = &g.board;
            // The structural guarantee: rings further apart than one disc, neighbours on a ring too.
            let min = 2.0 * board.token_r + MIN_CLEARANCE;
            for w in board.rings.windows(2) {
                assert!(w[1].radius - w[0].radius >= min, "level {level}: rings too close");
            }
            // And the outcome: sampled over a whole minute, reversals included.
            for step in 0..=240 {
                assert_no_overlap(board, step as f64 * 250.0 + 13.0, &format!("level {level}"));
            }
        }
        // Every endless stage shape, including the deepest.
        let mut rng = Rng::new(99);
        for stage in 1..=30 {
            let board = Board::generate(&stage_params(stage), &mut rng);
            for step in 0..=60 {
                assert_no_overlap(&board, step as f64 * 777.0, &format!("stage {stage}"));
            }
        }
    }

    #[test]
    fn rings_alternate_direction_and_differ_in_speed() {
        for level in 1..=LEVELS {
            let g = DonenSayilar::level(level);
            let omegas: Vec<f64> = g.board.rings.iter().map(|r| r.omega).collect();
            for w in omegas.windows(2) {
                assert!(w[0] * w[1] < 0.0, "level {level}: neighbours turn the same way");
            }
            for i in 0..omegas.len() {
                for j in 0..i {
                    let (a, b) = (omegas[i].abs().max(omegas[j].abs()), omegas[i].abs().min(omegas[j].abs()));
                    assert!(a / b >= 1.1, "level {level}: rings {i} and {j} share a speed");
                }
            }
            let reversing = g.board.rings.iter().filter(|r| r.flip_ms > 0.0).count();
            assert_eq!(reversing, g.p.reversing);
        }
    }

    #[test]
    fn motion_is_independent_of_the_frame_rate() {
        let run = |dt: f64| {
            let mut g = started(180);
            let mut t = 0.0;
            while t < 20_000.0 {
                let step = dt.min(20_000.0 - t);
                g.tick(step);
                t += step;
            }
            g.board.rings.iter().map(|r| r.angle(g.motion_ms)).collect::<Vec<_>>()
        };
        let (a, b) = (run(8.33), run(16.67));
        for (x, y) in a.iter().zip(&b) {
            assert!((x - y).abs() < 1e-6);
        }
    }

    #[test]
    fn reversals_are_continuous_and_stop_the_ring() {
        let ring = Ring { radius: 500.0, omega: 0.5, phase0: 1.0, flip_ms: 4000.0 };
        assert_eq!(ring.angle(0.0), 1.0);
        for k in 1..6 {
            let t = k as f64 * ring.flip_ms;
            let (before, at, after) = (ring.angle(t - 1.0), ring.angle(t), ring.angle(t + 1.0));
            assert!((before - at).abs() < 1e-5 && (after - at).abs() < 1e-5, "jump at t={t}");
        }
        // The first run goes one way, the second comes back, and the ring is home after two.
        assert!(ring.angle(4000.0) > 2.0);
        assert!((ring.angle(8000.0) - 1.0).abs() < 1e-9);
        let plain = Ring { radius: 500.0, omega: -0.5, phase0: 0.0, flip_ms: 0.0 };
        assert!((plain.angle(2000.0) + 1.0).abs() < 1e-9);
    }

    #[test]
    fn a_tap_is_judged_by_where_it_lands() {
        let mut g = started(1);
        g.tick(1234.0);
        // A thumb well off the digit, away from the centre, still gets the number.
        let (x, y) = g.board.position(0, g.motion_ms);
        let len = (x * x + y * y).sqrt();
        let off = 1.2 * g.board.token_r;
        g.act(&json!({"tap": [x + x / len * off, y + y / len * off]})).unwrap();
        assert_eq!((g.done, g.errors), (1, 0));
        assert_eq!(g.state()["last"]["n"], 1);
        // A number moves with the clock: its old position is empty, the new one counts.
        g.tick(4000.0);
        tap_number(&mut g, 2);
        assert_eq!((g.done, g.errors), (2, 0));
    }

    #[test]
    fn empty_taps_and_tapped_numbers_cost_nothing() {
        let mut g = started(1);
        let before = g.state();
        g.act(&json!({"tap": [0.0, 0.0]})).unwrap(); // the empty middle
        g.act(&json!({"tap": [990.0, 990.0]})).unwrap();
        assert_eq!(g.state(), before);
        let (x, y) = g.board.position(0, g.motion_ms);
        tap_number(&mut g, 1);
        let serial = g.serial;
        g.act(&json!({"tap": [x, y]})).unwrap(); // a gone number no longer exists
        assert_eq!((g.errors, g.serial), (0, serial));
    }

    #[test]
    fn wrong_number_costs_the_penalty_only() {
        let mut g = started(1);
        let motion = g.motion_ms;
        tap_number(&mut g, 2);
        let st = g.state();
        assert_eq!(st["errors"], 1);
        assert_eq!(st["found"], 0);
        assert_eq!(st["elapsed_ms"], PENALTY_MS);
        assert_eq!(st["last"]["ok"], false);
        assert_eq!(g.motion_ms, motion, "the rings do not jump on a penalty");
        // Penalties alone can run the minute out.
        let mut g = started(1);
        while g.phase == Phase::Run {
            tap_number(&mut g, 2);
        }
        assert_eq!(g.state()["status"], "lost");
    }

    #[test]
    fn clean_fast_run_wins_three_stars() {
        for level in SAMPLE {
            let mut g = started(level);
            for _ in 0..g.p.n {
                g.tick(100.0);
                tap_next(&mut g, 1);
            }
            let st = g.state();
            assert_eq!(st["status"], "won", "level {level}");
            assert_eq!(st["stars"], 3);
            assert_eq!(st["found"], g.p.n);
            assert!(st["summary"].as_str().unwrap().starts_with("Ulaşılan"));
            assert!(g.act(&json!({"tap": [0.0, 0.0]})).is_err());
        }
    }

    #[test]
    fn stars_follow_targets_and_errors() {
        // Level 1: targets 6 / 9 / 12.
        let play = |count: usize, errors: u32| {
            let mut g = started(1);
            tap_next(&mut g, count);
            g.errors = errors;
            let left = g.limit_ms - g.elapsed_ms;
            g.tick(left + 1.0);
            g.state()
        };
        assert_eq!(play(12, 2)["stars"], 3);
        assert_eq!(play(12, 3)["stars"], 2);
        assert_eq!(play(9, 0)["stars"], 2);
        assert_eq!(play(9, 5)["stars"], 2);
        assert_eq!(play(9, 6)["stars"], 1);
        assert_eq!(play(6, 40)["stars"], 1);
        let lost = play(5, 0);
        assert_eq!(lost["status"], "lost");
        assert_eq!(lost["stars"], 0);
        assert!(lost["summary"].as_str().unwrap().starts_with("Süre doldu"));
        assert_eq!(lost["remaining_ms"], 0.0);
        // Time running out with enough numbers is a win, not a loss.
        let g = play(6, 0);
        assert_eq!(g["status"], "won");
    }

    #[test]
    fn next_number_stays_hidden_and_only_the_one_is_cued() {
        let st = DonenSayilar::level(1).state();
        assert!(st["numbers"].is_null(), "hidden before the run");
        let mut g = started(1);
        let st = g.state();
        assert!(st.get("next").is_none());
        let numbers = st["numbers"].as_array().unwrap();
        assert!(numbers.iter().all(|n| n["cue"] == (n["n"] == 1)));
        tap_number(&mut g, 1);
        let st = g.state();
        assert!(st["numbers"].as_array().unwrap().iter().all(|n| n["cue"] == false));
        assert_eq!(st["numbers"][0]["found"], true);
        let late = started(100).state();
        assert!(late["numbers"].as_array().unwrap().iter().all(|n| n["cue"] == false));
    }

    #[test]
    fn next_goal_climbs_through_the_targets() {
        let mut g = started(1);
        assert_eq!(g.state()["next_goal"], json!({"n": 6, "stars": 1}));
        tap_next(&mut g, 6);
        assert_eq!(g.state()["next_goal"], json!({"n": 9, "stars": 2}));
        tap_next(&mut g, 3);
        assert_eq!(g.state()["next_goal"], json!({"n": 12, "stars": 3}));
        tap_next(&mut g, 3);
        assert!(g.state()["next_goal"].is_null());
    }

    #[test]
    fn endless_deals_harder_boards_until_time_runs_out() {
        let mut g = DonenSayilar::endless(11);
        g.act(&json!({"start": true})).unwrap();
        g.tick(COUNTDOWN_MS + 1.0);
        let first = g.p.n;
        tap_next(&mut g, first);
        let st = g.state();
        assert_eq!(st["status"], "playing");
        assert_eq!(st["stage"], 2);
        assert_eq!(st["board_serial"], 1);
        assert_eq!(st["score"], first);
        assert_eq!(st["found"], 0);
        assert_eq!(g.motion_ms, 0.0, "a new board starts its own clock");
        assert_eq!(g.limit_ms, RUN_MS + ENDLESS_BONUS_MS);
        assert!(g.p.n >= first);
        assert_eq!(st["mode"], "endless");
        assert!(st["next_goal"].is_null() && st["targets"].is_null());
        g.tick(RUN_MS * 2.0);
        let st = g.state();
        assert_eq!(st["status"], "lost");
        assert_eq!(st["score"], first);
        assert_eq!(st["stars"], 0);
        assert!(st["summary"].as_str().unwrap().starts_with("Toplam"));
        // Deep stages stop at the hardest level instead of running past it.
        assert_eq!(stage_params(1000), params(LEVELS));
    }

    #[test]
    fn illegal_actions_rejected_and_state_unchanged() {
        let mut g = DonenSayilar::level(1);
        let before = g.state();
        assert!(g.act(&json!({"tap": [0.0, 0.0]})).is_err()); // not started
        assert!(g.act(&json!({"foo": 1})).is_err());
        assert_eq!(g.state(), before);
        g.act(&json!({"start": true})).unwrap();
        let before = g.state();
        assert!(g.act(&json!({"tap": [0.0, 0.0]})).is_err()); // countdown
        assert!(g.act(&json!({"start": true})).is_err());
        assert_eq!(g.state(), before);
        g.tick(COUNTDOWN_MS);
        let before = g.state();
        assert!(g.act(&json!({"tap": [1.0]})).is_err());
        assert!(g.act(&json!({"tap": "x"})).is_err());
        assert!(g.act(&json!({"tap": ["a", "b"]})).is_err());
        assert_eq!(g.state(), before);
        // The clock only runs during the run.
        let mut g = DonenSayilar::level(1);
        g.tick(5000.0);
        assert_eq!((g.elapsed_ms, g.motion_ms), (0.0, 0.0));
    }

    /// The Flutter tests use a stand-in session, so the keys the view reads are pinned here.
    #[test]
    fn state_has_what_the_view_reads() {
        let mut g = started(1);
        tap_number(&mut g, 2);
        let st = g.state();
        for key in [
            "status", "stars", "mode", "phase", "title", "goal", "board_r", "token_r", "rings", "numbers", "total",
            "found", "errors", "score", "stage", "targets", "next_goal", "max_errors", "remaining_ms", "countdown_ms",
            "penalty_ms", "first_cue", "reversing", "board_serial", "last",
        ] {
            assert!(st.get(key).is_some(), "missing {key}");
        }
        assert!(st["rings"][0]["r"].is_number() && st["rings"][0]["a"].is_number());
        let n = &st["numbers"][0];
        assert!(n["n"].is_number() && n["ring"].is_number() && n["a"].is_number());
        assert!(n["found"].is_boolean() && n["cue"].is_boolean());
        assert!(st["last"]["serial"].is_number() && st["last"]["n"].is_number() && st["last"]["ok"].is_boolean());
    }

    #[test]
    fn registered_in_the_game_list() {
        assert!(crate::games::GAME_IDS.contains(&"donen_sayilar"));
        assert!(crate::games::create("donen_sayilar", 1, "level").is_ok());
        assert_eq!(crate::games::create("donen_sayilar", 1, "endless").unwrap().state()["mode"], "endless");
    }

    #[test]
    #[ignore]
    fn timing_all_levels() {
        let t = std::time::Instant::now();
        let mut worst = 0.0f64;
        for level in 1..=LEVELS {
            let s = std::time::Instant::now();
            let g = DonenSayilar::level(level);
            assert!(g.p.n >= 12);
            worst = worst.max(s.elapsed().as_secs_f64());
        }
        println!("donen_sayilar: {LEVELS} levels in {:?}, worst {:.3} ms", t.elapsed(), worst * 1000.0);
    }
}
