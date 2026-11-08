//! Renk Kapıları — divided-attention game on vertical rods.
//!
//! Two to four vertical rods (lanes). Jewel discs slide down each rod, each at its own speed; at the
//! bottom of every rod sits a **gate** showing one colour of the level's palette. When a disc reaches
//! its gate it must match the gate's colour: a match passes (score), a mismatch is an error (a life).
//! Tapping a lane advances that gate to the next palette colour (cyclic). So you leave matching
//! lanes alone and switch the ones that would fail, watching all rods at once; a needless tap can
//! break a lane that was right (inhibition).
//!
//! Disc kinds:
//! - **normal** — must arrive at a gate of its own colour;
//! - **pair** — a normal disc that follows the previous disc in the same lane closely with a
//!   different colour (switch after the first one passed, before the second arrives);
//! - **changer** ("bukalemun") — changes colour once mid-fall; for `CHANGE_WARN_MS` before the change
//!   it shimmers and reveals its next colour (the state exposes the change only inside that window);
//! - **ghost** (outlined) — must NOT pass: the gate has to show any colour *other* than the ghost's.
//!
//! **Swaps**: from level 31 the gates occasionally trade places (two gates, or from level 120 with
//! three or more lanes sometimes a rotation of all gates). The state announces a swap
//! `SWAP_WARN_MS` ahead; the swap itself is instant in the core (the view animates it).
//!
//! ## Fairness (generator guarantees)
//! The generator tracks the gate setting a perfect player would have ("nominal" gate per lane) and
//! models each disc as a tap job: `need` taps, possible from `release` (= the moment the information
//! is final: previous disc in that lane passed, disc visible, colour change done, swap done) plus a
//! perception time `react_ms − TAP_MS`, each tap taking `TAP_MS`, finished before arrival. A disc is
//! only emitted if all open jobs stay feasible for a *single* tapping finger under earliest-deadline
//! scheduling (two hands make it easier). Consequences:
//! - two different-colour discs reach the same gate at least `react_ms` apart (≥ 350 ms at the
//!   hardest level, 700 ms at level 1), plus `TAP_MS` per extra tap needed;
//! - a changer changes colour at least `react_ms` (+ taps) before it arrives — enough to recover
//!   even if you had pre-tapped towards its first colour;
//! - no disc arrives at a swapped gate within `SWAP_GUARD_MS` of the swap; the first disc at a
//!   swapped gate is never a ghost and is given time for the worst case (`k − 1` taps), since you
//!   may have pre-set that gate for another lane before the swap;
//! - discs in one lane never overtake or overlap (minimum `SEP` of the rod between them).
//!
//! ## Level curve (`params`)
//! Lanes: 1–40 → 2, 41–160 → 3, 161–500 → 4. Within a lane band, `u` goes 0 → 1:
//! global inter-arrival gap 740 → 500 ms (2 lanes), 600 → 400 (3), 480 → 270 (4); base fall time
//! 2700 → 2100 ms, 2500 → 1900, 2300 → 1500 (each disc ±18 % → ±30 %). Colours: 3, then 4 from
//! level 21 (2 lanes), 81 (3 lanes), 201 (4 lanes) and 5 from level 331. Discs per level
//! 30 + 50·t (t = (L−1)/499) → 30 … 80. Reaction window `react_ms` = 700 − 350·t.
//! Features: pairs from L1 (8 % → 22 %), changers from L11 (8 % → 24 %), ghosts from L21
//! (7 % → 20 %), swaps from L31 (every 16 → 9 discs). From L6 an accent rotates every level:
//! Akış (faster, fewer specials), Bukalemun (changers ×2.2), Hayalet (ghosts ×2.2), Takas (swaps ×2)
//! — falling back to Çift disk (pairs ×2) while the accented feature isn't unlocked yet.
//!
//! ## Scoring
//! 3 lives. A level is won when every disc has reached its gate with at most 2 errors.
//! Stars: 0 errors → 3★, 1 → 2★, 2 → 1★; the third error loses the level.
//! Endless "Sonsuz yağmur": `time_seed()`, 3 lives, difficulty follows an equivalent level
//! `1 + 2.4 · discs generated` (lanes and colours join mid-run), `score` = discs passed
//! (ghosts kept out count as passed).
//!
//! State: `{status, stars, title, goal, score, summary?, mode, phase: "intro"|"countdown"|"run"|"done",
//!          cd, t, lanes, k, gates:[c], tp:[taps per lane], lives, max_lives, errors, passed, total,
//!          resolved, streak, notes:[..],
//!          d: [[id, lane, colour_now, flags, p×1000, spawn_ms, dur_ms, change_in_ms|-1, next_colour|-1]],
//!          ev: [[serial, lane, kind, colour, dur_ms]], sw: [ms_until, perm..] | null,
//!          swd: [serial, ms_ago, perm..] | null}`
//! - `flags`: bit 0 ghost, bit 1 shimmering (a colour change is coming within `CHANGE_WARN_MS`).
//! - `ev.kind`: 0 passed, 1 mismatch (error), 2 ghost kept out, 3 ghost slipped through (error).
//! - `perm[i]` = the lane the gate now (or after the swap) at lane `i` came from.
//!
//! Actions: `{"start":true}` (intro) · `{"tap":lane}` (while running).

use crate::rng::{seed_for, time_seed, Rng};
use crate::Session;
use serde_json::{json, Value};
use std::collections::VecDeque;

pub const MAX_COLORS: usize = 5;
pub const LIVES: u32 = 3;
pub const COUNTDOWN_MS: f64 = 3000.0;
/// Time one extra tap costs in the fairness model.
pub const TAP_MS: f64 = 120.0;
/// The reaction window at the hardest level.
pub const HARD_REACT_MS: f64 = 350.0;
/// Minimum share of the rod between two discs in the same lane.
pub const SEP: f64 = 0.16;
pub const CHANGE_WARN_MS: f64 = 600.0;
pub const SWAP_WARN_MS: f64 = 1000.0;
/// No arrival at a swapped gate closer than this to the swap (either side).
pub const SWAP_GUARD_MS: f64 = 380.0;
/// Nothing spawns before this run time.
const START_MS: f64 = 500.0;
const ENDLESS_AHEAD_MS: f64 = 7000.0;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Accent {
    Plain,
    Flow,
    Chameleon,
    Ghost,
    Swap,
    Pairs,
}

#[derive(Clone, Debug)]
pub struct Params {
    pub lanes: usize,
    pub colors: usize,
    pub discs: u32,
    pub fall_ms: f64,
    pub fall_var: f64,
    pub gap_ms: f64,
    pub react_ms: f64,
    pub switch_p: f64,
    pub pair: f64,
    pub changer: f64,
    pub ghost: f64,
    /// Discs between swaps (0 = no swaps).
    pub swap_every: u32,
    /// Share of swaps that rotate every gate (needs ≥ 3 lanes).
    pub rotate: f64,
    pub accent: Accent,
}

/// Difficulty without the per-level accent (also used by endless).
fn base_params(level: u32) -> Params {
    let level = level.clamp(1, crate::MAX_LEVEL);
    let t = (level - 1) as f64 / 499.0;
    let (lanes, u) = if level <= 40 {
        (2, (level - 1) as f64 / 39.0)
    } else if level <= 160 {
        (3, (level - 41) as f64 / 119.0)
    } else {
        (4, (level - 161) as f64 / 339.0)
    };
    let colors = match lanes {
        2 => if level <= 20 { 3 } else { 4 },
        3 => if level <= 80 { 3 } else { 4 },
        _ => if level <= 200 { 3 } else if level <= 330 { 4 } else { 5 },
    };
    let (gap0, gap1, fall0, fall1) = match lanes {
        2 => (740.0, 500.0, 2700.0, 2100.0),
        3 => (600.0, 400.0, 2500.0, 1900.0),
        _ => (480.0, 270.0, 2300.0, 1500.0),
    };
    let lerp = |a: f64, b: f64| a + (b - a) * u;
    let feature = |from: u32, base: f64, grow: f64| if level >= from { base + grow * t } else { 0.0 };
    Params {
        lanes,
        colors,
        discs: 30 + (50.0 * t).round() as u32,
        fall_ms: lerp(fall0, fall1),
        fall_var: 0.18 + 0.12 * t,
        gap_ms: lerp(gap0, gap1),
        react_ms: 700.0 - 350.0 * t,
        switch_p: 0.48 + 0.1 * t,
        pair: feature(1, 0.08, 0.14),
        changer: feature(11, 0.08, 0.16),
        ghost: feature(21, 0.07, 0.13),
        swap_every: if level >= 31 { (16.0 - 7.0 * t).round() as u32 } else { 0 },
        rotate: if lanes >= 3 && level >= 120 { 0.35 } else { 0.0 },
        accent: Accent::Plain,
    }
}

/// Level → parameters (see the module docs for the curve).
pub fn params(level: u32) -> Params {
    let level = level.clamp(1, crate::MAX_LEVEL);
    let mut p = base_params(level);
    if level >= 6 {
        match (level - 1) % 4 {
            0 => {
                p.gap_ms *= 0.9;
                p.pair *= 0.6;
                p.changer *= 0.5;
                p.ghost *= 0.5;
                p.accent = Accent::Flow;
            }
            1 if p.changer > 0.0 => {
                p.changer = (p.changer * 2.2).min(0.45);
                p.accent = Accent::Chameleon;
            }
            2 if p.ghost > 0.0 => {
                p.ghost = (p.ghost * 2.2).min(0.4);
                p.accent = Accent::Ghost;
            }
            3 if p.swap_every > 0 => {
                p.swap_every = (p.swap_every / 2).max(5);
                p.accent = Accent::Swap;
            }
            _ => {
                p.pair = (p.pair * 2.2).min(0.4);
                p.accent = Accent::Pairs;
            }
        }
    }
    p
}

fn endless_params(generated: u32) -> Params {
    base_params((1 + (generated as f64 * 2.4) as u32).min(crate::MAX_LEVEL))
}

fn title(p: &Params) -> &'static str {
    match p.accent {
        Accent::Plain => match p.lanes {
            2 => "İki kapı",
            3 => "Üç kapı",
            _ => "Dört kapı",
        },
        Accent::Flow => "Akış",
        Accent::Chameleon => "Bukalemun",
        Accent::Ghost => "Hayalet",
        Accent::Swap => "Takas",
        Accent::Pairs => "Çift disk",
    }
}

#[derive(Clone, Debug)]
pub struct Disc {
    pub id: u32,
    pub lane: usize,
    /// Final colour (the one that counts at the gate).
    pub color: u8,
    /// Colour shown before `change_at` (= `color` for non-changers).
    pub first: u8,
    pub change_at: f64,
    pub ghost: bool,
    pub spawn: f64,
    pub arrive: f64,
    /// Taps a perfect player needs for this disc.
    pub need: u8,
    pub result: Option<bool>,
}

impl Disc {
    fn changer(&self) -> bool {
        self.change_at.is_finite()
    }
    fn color_at(&self, t: f64) -> u8 {
        if t < self.change_at {
            self.first
        } else {
            self.color
        }
    }
}

#[derive(Clone, Debug)]
pub struct Swap {
    pub at: f64,
    /// `perm[i]` = lane the gate at lane `i` comes from.
    pub perm: Vec<usize>,
}

/// Lane / palette change in endless.
#[derive(Clone, Debug)]
struct Cfg {
    at: f64,
    lanes: usize,
    colors: usize,
}

#[derive(Clone, Copy, Debug)]
struct Job {
    ready: f64,
    deadline: f64,
    taps: u8,
}

/// Earliest-deadline-first schedule for one tapper (each tap `TAP_MS`, never idle while a job is
/// ready). Returns whether every job meets its deadline, and the number of leading jobs (in list
/// order) that are finished before an idle moment `≤ prune_before` with nothing else ready — those
/// can be dropped without changing the schedule of anything that comes later.
fn edf(jobs: &[Job], prune_before: f64) -> (bool, usize) {
    let mut rem: Vec<(usize, Job)> = jobs.iter().copied().enumerate().filter(|(_, j)| j.taps > 0).collect();
    let mut done = vec![false; jobs.len()];
    for (i, j) in jobs.iter().enumerate() {
        done[i] = j.taps == 0;
    }
    let mut prunable = 0;
    let mut t = f64::NEG_INFINITY;
    while !rem.is_empty() {
        let min_ready = rem.iter().map(|(_, j)| j.ready).fold(f64::INFINITY, f64::min);
        if t < min_ready {
            t = min_ready;
            if t <= prune_before {
                prunable = done.iter().take_while(|&&d| d).count();
            }
        }
        let mut best = usize::MAX;
        for (i, (_, j)) in rem.iter().enumerate() {
            if j.ready <= t + 1e-9 && (best == usize::MAX || j.deadline < rem[best].1.deadline) {
                best = i;
            }
        }
        t += TAP_MS;
        if t > rem[best].1.deadline + 1e-6 {
            return (false, 0);
        }
        rem[best].1.taps -= 1;
        if rem[best].1.taps == 0 {
            done[rem[best].0] = true;
            rem.swap_remove(best);
        }
    }
    if t <= prune_before {
        prunable = jobs.len();
    }
    (true, prunable)
}

fn edf_ok(jobs: &[Job]) -> bool {
    edf(jobs, f64::NEG_INFINITY).0
}

/// Streaming disc generator (arrivals come out in time order).
struct Gen {
    rng: Rng,
    lanes: usize,
    colors: usize,
    cursor: f64,
    last_lane: usize,
    last_arr: Vec<f64>,
    last_spawn: Vec<f64>,
    last_dur: Vec<f64>,
    /// Information about a lane is not final before this (swap / lane change).
    release_floor: Vec<f64>,
    /// No arrival in a lane before this.
    arr_floor: Vec<f64>,
    nominal: Vec<u8>,
    /// A swap moved this lane's gate since its last disc.
    fresh: Vec<bool>,
    jobs: Vec<Job>,
    since_swap: u32,
    next_swap_in: u32,
    last_swap_at: f64,
    next_id: u32,
}

/// What one generator step produced.
struct Step {
    disc: Disc,
    swap: Option<Swap>,
    cfg: Option<Cfg>,
}

impl Gen {
    fn new(mut rng: Rng, p: &Params) -> (Gen, Vec<u8>) {
        let gates: Vec<u8> = (0..p.lanes).map(|_| rng.below(p.colors) as u8).collect();
        let n = p.lanes;
        let g = Gen {
            next_swap_in: p.swap_every.max(1) + rng.below(4) as u32,
            rng,
            lanes: n,
            colors: p.colors,
            cursor: START_MS + p.fall_ms * 0.9,
            last_lane: 0,
            last_arr: vec![f64::NEG_INFINITY; n],
            last_spawn: vec![f64::NEG_INFINITY; n],
            last_dur: vec![1.0; n],
            release_floor: vec![START_MS; n],
            arr_floor: vec![START_MS; n],
            nominal: gates.clone(),
            fresh: vec![false; n],
            jobs: vec![],
            since_swap: 0,
            last_swap_at: f64::NEG_INFINITY,
            next_id: 0,
        };
        (g, gates)
    }

    fn pick_d(&mut self) -> u8 {
        const W: [f64; 4] = [6.0, 3.5, 2.0, 1.2];
        let n = self.colors - 1;
        let total: f64 = W[..n].iter().sum();
        let mut r = self.rng.f64() * total;
        for (i, w) in W[..n].iter().enumerate() {
            if r < *w {
                return i as u8 + 1;
            }
            r -= w;
        }
        n as u8
    }

    fn add(&self, c: u8, d: u8) -> u8 {
        ((c as usize + d as usize) % self.colors) as u8
    }

    fn dist(&self, from: u8, to: u8) -> u8 {
        ((to as usize + self.colors - from as usize) % self.colors) as u8
    }

    fn maybe_cfg(&mut self, p: &Params) -> Option<Cfg> {
        if p.lanes <= self.lanes && p.colors <= self.colors {
            return None;
        }
        let at = self.cursor + 300.0;
        while self.lanes < p.lanes {
            self.lanes += 1;
            self.last_arr.push(at);
            self.last_spawn.push(at);
            self.last_dur.push(1.0);
            self.release_floor.push(at);
            self.arr_floor.push(at);
            self.nominal.push(0);
            self.fresh.push(false);
        }
        self.colors = self.colors.max(p.colors);
        for f in self.release_floor.iter_mut() {
            *f = f.max(at);
        }
        Some(Cfg { at, lanes: self.lanes, colors: self.colors })
    }

    fn maybe_swap(&mut self, p: &Params) -> Option<Swap> {
        if p.swap_every == 0 || self.lanes < 2 {
            return None;
        }
        self.since_swap += 1;
        if self.since_swap < self.next_swap_in {
            return None;
        }
        self.since_swap = 0;
        self.next_swap_in = (p.swap_every as i64 + self.rng.range(-2, 2)).max(3) as u32;
        let n = self.lanes;
        let perm: Vec<usize> = if n >= 3 && self.rng.chance(p.rotate) {
            let right = self.rng.chance(0.5);
            (0..n).map(|i| if right { (i + n - 1) % n } else { (i + 1) % n }).collect()
        } else {
            let a = self.rng.below(n);
            let b = (a + 1 + self.rng.below(n - 1)) % n;
            let mut v: Vec<usize> = (0..n).collect();
            v.swap(a, b);
            v
        };
        let moved: Vec<usize> = (0..n).filter(|&i| perm[i] != i).collect();
        let last = moved.iter().map(|&i| self.last_arr[i]).fold(f64::NEG_INFINITY, f64::max);
        let at = (last + SWAP_GUARD_MS)
            .max(START_MS + SWAP_WARN_MS + 800.0)
            .max(self.cursor - 150.0)
            .max(self.last_swap_at + SWAP_WARN_MS + 500.0);
        self.last_swap_at = at;
        let old = self.nominal.clone();
        for &i in &moved {
            self.nominal[i] = old[perm[i]];
            self.release_floor[i] = self.release_floor[i].max(at);
            self.arr_floor[i] = self.arr_floor[i].max(at + SWAP_GUARD_MS);
            self.fresh[i] = true;
        }
        Some(Swap { at, perm })
    }

    fn next(&mut self, p: &Params) -> Step {
        let cfg = self.maybe_cfg(p);
        let swap = self.maybe_swap(p);
        // Any job added from now on is ready after `cursor − 4500` (it spawns at most one fall
        // time before its arrival), so the schedule before an idle moment there is final.
        let (_, cut) = edf(&self.jobs, self.cursor - 4500.0);
        self.jobs.drain(..cut);
        let k = self.colors;
        let pair = self.next_id > 0 && self.rng.chance(p.pair);
        let lane = if pair {
            self.last_lane
        } else {
            // Prefer lanes that have been idle for a while.
            let w: Vec<f64> = (0..self.lanes)
                .map(|l| {
                    let idle = (self.cursor - self.last_arr[l]).clamp(60.0, 4000.0) + 100.0;
                    let mut x = idle * idle;
                    if self.cursor < self.arr_floor[l] {
                        x *= 0.15;
                    }
                    x
                })
                .collect();
            let total: f64 = w.iter().sum();
            let mut r = self.rng.f64() * total;
            let mut pick = self.lanes - 1;
            for (i, x) in w.iter().enumerate() {
                if r < *x {
                    pick = i;
                    break;
                }
                r -= x;
            }
            pick
        };
        let n0 = self.nominal[lane];
        // Kind and colours.
        let roll = self.rng.f64();
        // The first disc after a swap is never a ghost: a ghost leaves the gate on "anything but
        // its colour", so the player's setting would stay unknown.
        let ghost = !pair && !self.fresh[lane] && roll < p.ghost;
        let changer = !ghost && !pair && roll < p.ghost + p.changer;
        let mut color;
        let mut first;
        let mut need;
        let mut new_nom;
        let mut worst;
        if ghost {
            let off = if self.rng.chance(0.6) { 0 } else { 1 + self.rng.below(k - 1) as u8 };
            let g = self.add(n0, off);
            color = g;
            first = g;
            need = (g == n0) as u8;
            new_nom = if g == n0 { self.add(n0, 1) } else { n0 };
            worst = need;
        } else if changer {
            let d = self.pick_d();
            if self.rng.chance(0.55) {
                first = n0;
                color = self.add(n0, d);
                need = d;
            } else {
                first = self.add(n0, d);
                color = n0;
                need = 0;
            }
            new_nom = color;
            // Worst case: the player already cycled part-way towards the first colour.
            let steps = self.dist(n0, first);
            worst = (0..=steps).map(|s| self.dist(self.add(n0, s), color)).max().unwrap_or(0);
        } else {
            let d = if pair {
                1 + self.rng.below((k - 1).min(2)) as u8
            } else if self.rng.chance(p.switch_p) {
                self.pick_d()
            } else {
                0
            };
            color = self.add(n0, d);
            first = color;
            need = d;
            new_nom = color;
            worst = d;
        }
        let gap_min = (p.gap_ms * 0.4).max(130.0);
        let mut arr = (self.cursor + gap_min).max(self.arr_floor[lane]);
        if pair {
            let w = p.react_ms + (need.max(1) - 1) as f64 * TAP_MS + self.rng.f64() * 90.0;
            arr = arr.max(self.last_arr[lane] + w);
        } else {
            arr = arr.max(self.cursor + p.gap_ms * (0.55 + 0.9 * self.rng.f64()));
        }
        // Right after a swap the player may have pre-set this gate for another disc: assume the
        // worst (any colour) for the first disc that arrives there.
        let fresh = self.fresh[lane];
        let fresh_taps = if fresh { (k - 1) as u8 } else { 0 };
        let var = p.fall_var;
        let mut target_dur = if pair {
            self.last_dur[lane]
        } else {
            p.fall_ms * (1.0 + var * (2.0 * self.rng.f64() - 1.0))
        };
        let mut min_dur = p.fall_ms * (1.0 - var) * 0.8;
        if fresh {
            // Long enough on screen to fix a gate in any state once the disc is visible.
            let need_ms = p.react_ms + (fresh_taps as f64 - 1.0) * TAP_MS + 150.0;
            target_dur = target_dur.max(need_ms);
            min_dur = min_dur.max(need_ms);
        }
        let change_frac = 0.3 + 0.32 * self.rng.f64();
        let mut change_at = f64::INFINITY;
        let mut dur = target_dur;
        let mut special_tries = 0;
        let mut ok = false;
        for _ in 0..400 {
            let mut hi = target_dur;
            if self.last_spawn[lane].is_finite() {
                hi = hi.min(arr - self.last_spawn[lane] - SEP * self.last_dur[lane]);
            }
            if self.last_arr[lane].is_finite() {
                hi = hi.min((arr - self.last_arr[lane]) / SEP);
            }
            hi = hi.min(arr - START_MS);
            if hi < min_dur {
                arr += 50.0;
                continue;
            }
            dur = hi;
            let spawn = arr - dur;
            change_at = f64::INFINITY;
            let mut retry = false;
            if first != color {
                let latest = arr - (p.react_ms + (worst.max(fresh_taps).max(1) - 1) as f64 * TAP_MS + 60.0);
                let c = (spawn + dur * change_frac).min(latest);
                if c < spawn + dur * 0.2 {
                    retry = true;
                } else {
                    change_at = c;
                }
            }
            let job_taps = need.max(fresh_taps);
            if !retry && job_taps > 0 {
                let mut release = spawn.max(self.release_floor[lane]);
                if self.last_arr[lane].is_finite() {
                    release = release.max(self.last_arr[lane]);
                }
                if change_at.is_finite() {
                    release = release.max(change_at);
                }
                self.jobs.push(Job { ready: release + p.react_ms - TAP_MS, deadline: arr, taps: job_taps });
                if edf_ok(&self.jobs) {
                    ok = true;
                    break;
                }
                self.jobs.pop();
                retry = true;
            }
            if !retry {
                ok = true;
                break;
            }
            special_tries += 1;
            if special_tries >= 4 && need > 0 {
                // Too tight here: make it a disc that needs no tap (keeps the pace instead of
                // opening a hole in the rain).
                if ghost && n0 == color {
                    color = self.add(n0, 1);
                    first = color;
                } else if !ghost {
                    color = n0;
                    first = n0;
                }
                need = 0;
                new_nom = n0;
                worst = 0;
                change_at = f64::INFINITY;
            } else {
                arr += 50.0;
            }
        }
        debug_assert!(ok, "color_gates generator gave up (lane {lane}, arrival {arr})");
        let spawn = arr - dur;
        let disc = Disc {
            id: self.next_id,
            lane,
            color,
            first,
            change_at,
            ghost,
            spawn,
            arrive: arr,
            need,
            result: None,
        };
        self.next_id += 1;
        self.last_arr[lane] = arr;
        self.last_spawn[lane] = spawn;
        self.last_dur[lane] = dur;
        self.nominal[lane] = new_nom;
        self.fresh[lane] = false;
        self.last_lane = lane;
        self.cursor = arr;
        Step { disc, swap, cfg }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Phase {
    Intro,
    Countdown,
    Run,
    Done,
}

pub struct ColorGates {
    endless: bool,
    p: Params,
    gen: Gen,
    phase: Phase,
    countdown: f64,
    t: f64,
    pub discs: Vec<Disc>,
    /// Index of the next unresolved disc (discs resolve in arrival order).
    next: usize,
    pub swaps: Vec<Swap>,
    swap_idx: usize,
    cfgs: Vec<Cfg>,
    cfg_idx: usize,
    lanes: usize,
    colors: usize,
    pub gates: Vec<u8>,
    taps: Vec<u32>,
    total_taps: u32,
    min_taps: u32,
    errors: u32,
    passed: u32,
    resolved: u32,
    total: u32,
    streak: u32,
    best_streak: u32,
    ev_serial: u64,
    events: VecDeque<[i64; 5]>,
    swap_serial: u64,
    won: bool,
}

pub fn create(level: u32, mode: &str) -> Result<Box<dyn Session>, String> {
    Ok(Box::new(ColorGates::new(level, mode)))
}

impl ColorGates {
    pub fn new(level: u32, mode: &str) -> Self {
        let endless = mode == "endless";
        let (p, seed) = if endless {
            (endless_params(0), time_seed())
        } else {
            (params(level), seed_for("color_gates", level, 0))
        };
        Self::with_seed(p, seed, endless)
    }

    fn with_seed(p: Params, seed: u64, endless: bool) -> Self {
        let (gen, gates) = Gen::new(Rng::new(seed), &p);
        let mut g = ColorGates {
            endless,
            lanes: p.lanes,
            colors: p.colors,
            total: if endless { 0 } else { p.discs },
            p: p.clone(),
            gen,
            phase: Phase::Intro,
            countdown: 0.0,
            t: 0.0,
            discs: vec![],
            next: 0,
            swaps: vec![],
            swap_idx: 0,
            cfgs: vec![],
            cfg_idx: 0,
            taps: vec![0; gates.len()],
            gates,
            total_taps: 0,
            min_taps: 0,
            errors: 0,
            passed: 0,
            resolved: 0,
            streak: 0,
            best_streak: 0,
            ev_serial: 0,
            events: VecDeque::new(),
            swap_serial: 0,
            won: false,
        };
        if endless {
            g.fill(ENDLESS_AHEAD_MS);
        } else {
            for _ in 0..p.discs {
                let s = g.gen.next(&p);
                g.push_step(s);
            }
        }
        g
    }

    fn push_step(&mut self, s: Step) {
        if let Some(c) = s.cfg {
            self.cfgs.push(c);
        }
        if let Some(w) = s.swap {
            self.swaps.push(w);
        }
        self.discs.push(s.disc);
    }

    /// Endless: keep generating until the schedule reaches `until` (run time).
    fn fill(&mut self, until: f64) {
        let mut guard = 0;
        while self.gen.cursor < until && guard < 64 {
            let p = endless_params(self.gen.next_id);
            let s = self.gen.next(&p);
            self.p = p;
            self.push_step(s);
            guard += 1;
        }
        // Drop long-resolved discs so the list stays short.
        if self.next > 48 {
            let cut = self.next - 16;
            self.discs.drain(0..cut);
            self.next -= cut;
        }
        if self.swap_idx > 16 {
            self.swaps.drain(0..self.swap_idx);
            self.swap_idx = 0;
        }
    }

    fn status(&self) -> &'static str {
        if self.phase != Phase::Done {
            "playing"
        } else if self.won {
            "won"
        } else {
            "lost"
        }
    }

    fn stars(&self) -> u32 {
        if self.won {
            3u32.saturating_sub(self.errors).max(1)
        } else {
            0
        }
    }

    fn apply_cfg(&mut self, c: &Cfg) {
        while self.gates.len() < c.lanes {
            self.gates.push(0);
            self.taps.push(0);
        }
        self.lanes = c.lanes;
        self.colors = c.colors;
    }

    fn apply_swap(&mut self, perm: &[usize]) {
        let old = self.gates.clone();
        for (i, &from) in perm.iter().enumerate() {
            if i < self.gates.len() && from < old.len() {
                self.gates[i] = old[from];
            }
        }
        self.swap_serial += 1;
    }

    fn resolve(&mut self, i: usize) {
        let d = &self.discs[i];
        let gate = self.gates[d.lane];
        let ok = if d.ghost { gate != d.color } else { gate == d.color };
        let kind = match (d.ghost, ok) {
            (false, true) => 0,
            (false, false) => 1,
            (true, true) => 2,
            (true, false) => 3,
        };
        self.ev_serial += 1;
        self.events.push_back([self.ev_serial as i64, d.lane as i64, kind, d.color as i64, (d.arrive - d.spawn).round() as i64]);
        while self.events.len() > 10 {
            self.events.pop_front();
        }
        self.min_taps += d.need as u32;
        self.discs[i].result = Some(ok);
        self.resolved += 1;
        if ok {
            self.passed += 1;
            self.streak += 1;
            self.best_streak = self.best_streak.max(self.streak);
        } else {
            self.errors += 1;
            self.streak = 0;
        }
        if self.errors >= LIVES {
            self.phase = Phase::Done;
            self.won = false;
        } else if !self.endless && self.resolved >= self.total {
            self.phase = Phase::Done;
            self.won = true;
        }
    }

    fn advance(&mut self, dt: f64) {
        let target = self.t + dt;
        loop {
            if self.endless {
                self.fill(target + ENDLESS_AHEAD_MS);
            }
            let tc = self.cfgs.get(self.cfg_idx).map_or(f64::INFINITY, |c| c.at);
            let ts = self.swaps.get(self.swap_idx).map_or(f64::INFINITY, |s| s.at);
            let td = self.discs.get(self.next).map_or(f64::INFINITY, |d| d.arrive);
            let te = tc.min(ts).min(td);
            if te > target {
                break;
            }
            self.t = self.t.max(te);
            if tc <= te {
                let c = self.cfgs[self.cfg_idx].clone();
                self.apply_cfg(&c);
                self.cfg_idx += 1;
            } else if ts <= te {
                let perm = self.swaps[self.swap_idx].perm.clone();
                self.apply_swap(&perm);
                self.swap_idx += 1;
            } else {
                let i = self.next;
                self.next += 1;
                self.resolve(i);
                if self.phase == Phase::Done {
                    return;
                }
            }
        }
        self.t = target;
    }

    fn goal(&self) -> String {
        if self.endless {
            "3 can · yağmur giderek hızlanır".into()
        } else {
            format!("{} diski kapıdan geçir · en fazla {} hata", self.total, LIVES - 1)
        }
    }

    fn notes(&self) -> Vec<&'static str> {
        let p = &self.p;
        let mut v = vec!["Disk kapıya vardığında kapı onun renginde olmalı. Dokunduğun direğin kapısı sıradaki renge geçer."];
        if self.endless {
            v.push("Yağmur hızlandıkça yeni direkler, renkler, hayaletler ve takaslar katılır.");
            return v;
        }
        if p.pair > 0.0 {
            v.push("Çift disk: aynı direkte peş peşe iki farklı renk gelir. İlki geçince çevir.");
        }
        if p.changer > 0.0 {
            v.push("Bukalemun disk ışıldayınca renk değiştirir. Son rengine göre ayarla.");
        }
        if p.ghost > 0.0 {
            v.push("Hayalet disk (içi boş) geçmemeli: kapı onun renginde olmasın.");
        }
        if p.swap_every > 0 {
            v.push("Takas: kapılar yer değiştirir, altın yaylar önceden haber verir.");
        }
        v
    }

    fn summary(&self) -> Option<String> {
        if self.phase != Phase::Done {
            return None;
        }
        let extra = self.total_taps.saturating_sub(self.min_taps);
        Some(if self.endless {
            format!("Geçen {} · En uzun seri {} · Fazla dokunuş {}", self.passed, self.best_streak, extra)
        } else if self.won {
            format!("Geçen {}/{} · Hata {} · Fazla dokunuş {}", self.passed, self.total, self.errors, extra)
        } else {
            format!("Geçen {}/{} · Canlar bitti", self.passed, self.total)
        })
    }

    fn discs_json(&self) -> Vec<Value> {
        let t = self.t;
        let mut out = vec![];
        if !matches!(self.phase, Phase::Run | Phase::Done) {
            return out;
        }
        for d in self.discs[self.next..].iter() {
            if d.spawn > t {
                // Arrivals are ordered, spawns are not: keep scanning a little past the first unspawned.
                if d.arrive - 4000.0 > t {
                    break;
                }
                continue;
            }
            let dur = d.arrive - d.spawn;
            let p = ((t - d.spawn) / dur).clamp(0.0, 1.0);
            let mut flags = d.ghost as i64;
            let (mut ch, mut nc) = (-1i64, -1i64);
            if d.changer() && t < d.change_at && d.change_at - t <= CHANGE_WARN_MS {
                flags |= 2;
                ch = (d.change_at - t).round() as i64;
                nc = d.color as i64;
            }
            out.push(json!([
                d.id,
                d.lane,
                d.color_at(t),
                flags,
                (p * 1000.0).round() as i64,
                d.spawn.round() as i64,
                dur.round() as i64,
                ch,
                nc
            ]));
        }
        out
    }
}

impl Session for ColorGates {
    fn state(&self) -> Value {
        let phase = match self.phase {
            Phase::Intro => "intro",
            Phase::Countdown => "countdown",
            Phase::Run => "run",
            Phase::Done => "done",
        };
        let sw = self.swaps.get(self.swap_idx).and_then(|s| {
            let until = s.at - self.t;
            (self.phase == Phase::Run && until <= SWAP_WARN_MS).then(|| {
                let mut v = vec![until.max(0.0).round() as i64];
                v.extend(s.perm.iter().map(|&x| x as i64));
                v
            })
        });
        let swd = (self.swap_idx > 0).then(|| &self.swaps[self.swap_idx - 1]).and_then(|s| {
            let ago = self.t - s.at;
            (ago < 1500.0).then(|| {
                let mut v = vec![self.swap_serial as i64, ago.round() as i64];
                v.extend(s.perm.iter().map(|&x| x as i64));
                v
            })
        });
        let score = self.passed;
        json!({
            "status": self.status(),
            "stars": self.stars(),
            "title": if self.endless { "Sonsuz yağmur" } else { title(&self.p) },
            "goal": self.goal(),
            "score": score,
            "summary": self.summary(),
            "mode": if self.endless { "endless" } else { "level" },
            "phase": phase,
            "cd": self.countdown.max(0.0).round() as i64,
            "t": (self.t * 10.0).round() / 10.0,
            "lanes": self.lanes,
            "k": self.colors,
            "gates": self.gates[..self.lanes],
            "tp": self.taps[..self.lanes],
            "lives": LIVES.saturating_sub(self.errors),
            "max_lives": LIVES,
            "errors": self.errors,
            "passed": self.passed,
            "total": self.total,
            "resolved": self.resolved,
            "streak": self.streak,
            "notes": self.notes(),
            "d": self.discs_json(),
            "ev": self.events.iter().map(|e| json!(e)).collect::<Vec<_>>(),
            "sw": sw,
            "swd": swd,
        })
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if a["start"].as_bool() == Some(true) {
            if self.phase != Phase::Intro {
                return Err("Oyun zaten başladı".into());
            }
            self.phase = Phase::Countdown;
            self.countdown = COUNTDOWN_MS;
            return Ok(());
        }
        if let Some(l) = a["tap"].as_u64() {
            match self.phase {
                Phase::Intro | Phase::Countdown => return Err("Henüz başlamadı".into()),
                Phase::Done => return Err("Oyun bitti".into()),
                Phase::Run => {}
            }
            let l = l as usize;
            if l >= self.lanes {
                return Err("Geçersiz kapı".into());
            }
            self.gates[l] = ((self.gates[l] as usize + 1) % self.colors) as u8;
            self.taps[l] += 1;
            self.total_taps += 1;
            return Ok(());
        }
        Err("Bilinmeyen hamle".into())
    }

    fn tick(&mut self, dt: f64) {
        match self.phase {
            Phase::Intro | Phase::Done => {}
            Phase::Countdown => {
                self.countdown -= dt;
                if self.countdown <= 0.0 {
                    let carry = -self.countdown;
                    self.countdown = 0.0;
                    self.phase = Phase::Run;
                    self.advance(carry);
                }
            }
            Phase::Run => self.advance(dt),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LEVELS: [u32; 9] = [1, 2, 3, 50, 137, 250, 400, 499, 500];

    fn run(g: &mut ColorGates) {
        g.act(&json!({"start": true})).unwrap();
        g.tick(COUNTDOWN_MS);
        assert_eq!(g.phase, Phase::Run);
    }

    /// Human-limited autoplayer: sees a disc's final requirement only `perceive` ms after the
    /// information is final (disc visible, previous disc in that lane gone, colour change done,
    /// swap done), taps at most once per `tap_gap` ms with one finger, earliest arrival first.
    fn bot(g: &mut ColorGates, perceive: f64, tap_gap: f64, dt: f64, until: f64) {
        run(g);
        let mut last_tap = f64::NEG_INFINITY;
        let mut guard = 0u32;
        while g.phase == Phase::Run && g.t < until {
            if g.t - last_tap >= tap_gap {
                let mut best: Option<(f64, usize)> = None;
                for lane in 0..g.lanes {
                    let Some(i) = (g.next..g.discs.len()).find(|&i| g.discs[i].lane == lane) else { continue };
                    let d = &g.discs[i];
                    let prev = (0..g.next).rev().find(|&j| g.discs[j].lane == lane).map(|j| g.discs[j].arrive);
                    let swap = g.swaps[..g.swap_idx]
                        .iter()
                        .filter(|s| s.perm.get(lane).is_some_and(|&f| f != lane))
                        .map(|s| s.at)
                        .fold(f64::NEG_INFINITY, f64::max);
                    let cfg = g.cfgs[..g.cfg_idx].last().map_or(f64::NEG_INFINITY, |c| c.at);
                    let mut known = d.spawn.max(swap).max(cfg).max(prev.unwrap_or(f64::NEG_INFINITY));
                    if d.changer() {
                        known = known.max(d.change_at);
                    }
                    if g.t < known + perceive {
                        continue;
                    }
                    let gate = g.gates[lane];
                    let ok = if d.ghost { gate != d.color } else { gate == d.color };
                    if !ok && best.is_none_or(|(a, _)| d.arrive < a) {
                        best = Some((d.arrive, lane));
                    }
                }
                if let Some((_, lane)) = best {
                    g.act(&json!({"tap": lane})).unwrap();
                    last_tap = g.t;
                }
            }
            g.tick(dt);
            guard += 1;
            assert!(guard < 2_000_000);
        }
    }

    #[test]
    fn color_gates_params_curve() {
        for level in LEVELS {
            let p = params(level);
            assert!((2..=4).contains(&p.lanes));
            assert!((3..=MAX_COLORS).contains(&p.colors));
            assert!((30..=80).contains(&p.discs));
            assert!(p.react_ms >= HARD_REACT_MS - 1e-9);
        }
        assert_eq!(params(1).lanes, 2);
        assert_eq!(params(1).discs, 30);
        assert_eq!(params(500).lanes, 4);
        assert_eq!(params(500).discs, 80);
        assert_eq!(params(500).colors, 5);
        assert!((params(500).react_ms - HARD_REACT_MS).abs() < 1e-9);
        assert!(params(2).gap_ms < params(1).gap_ms);
    }

    #[test]
    fn color_gates_levels_generate_and_are_deterministic() {
        for level in LEVELS {
            let a = ColorGates::new(level, "level");
            let b = ColorGates::new(level, "level");
            assert_eq!(a.discs.len(), params(level).discs as usize);
            assert_eq!(a.gates, b.gates);
            for (x, y) in a.discs.iter().zip(&b.discs) {
                assert_eq!((x.lane, x.color, x.first, x.ghost), (y.lane, y.color, y.first, y.ghost));
                assert_eq!(x.arrive, y.arrive);
                assert_eq!(x.spawn, y.spawn);
            }
            let st = a.state();
            assert_eq!(st["status"], "playing");
            assert_eq!(st["phase"], "intro");
            assert!(st["title"].is_string() && st["goal"].is_string());
        }
        assert_ne!(
            ColorGates::new(3, "level").discs.iter().map(|d| d.color).collect::<Vec<_>>(),
            ColorGates::new(4, "level").discs.iter().map(|d| d.color).collect::<Vec<_>>()
        );
    }

    fn check_fair(g: &ColorGates, react: f64) {
        let ds = &g.discs;
        for w in ds.windows(2) {
            assert!(w[1].arrive >= w[0].arrive, "arrivals out of order");
        }
        for (i, d) in ds.iter().enumerate() {
            assert!(d.spawn >= START_MS - 1e-6 && d.arrive > d.spawn);
            if d.changer() {
                assert!(d.change_at > d.spawn && d.arrive - d.change_at >= react - 1e-6, "changer too late");
                assert_ne!(d.first, d.color);
            }
            // Next disc in the same lane.
            if let Some(e) = ds[i + 1..].iter().find(|e| e.lane == d.lane) {
                let gap = e.arrive - d.arrive;
                // No overtaking / overlap on the rod.
                assert!(e.spawn >= d.spawn, "overtake");
                assert!(gap >= SEP * (e.arrive - e.spawn) - 1e-6, "overlap at the gate");
                if !d.ghost && !e.ghost && d.color != e.color {
                    assert!(gap >= react - 1e-6 && gap >= HARD_REACT_MS - 1e-6, "lane gap {gap} < {react}");
                }
            }
        }
        for s in &g.swaps {
            for (lane, &from) in s.perm.iter().enumerate() {
                if from == lane {
                    continue;
                }
                for d in ds.iter().filter(|d| d.lane == lane) {
                    assert!((d.arrive - s.at).abs() >= SWAP_GUARD_MS - 1e-6, "arrival too close to a swap");
                }
            }
        }
    }

    #[test]
    fn color_gates_generator_is_fair() {
        let mut levels: Vec<u32> = LEVELS.to_vec();
        levels.extend((1..=500).step_by(13));
        for level in levels {
            let g = ColorGates::new(level, "level");
            check_fair(&g, params(level).react_ms);
        }
    }

    #[test]
    fn color_gates_features_appear() {
        let mut ghosts = 0;
        let mut changers = 0;
        let mut swaps = 0;
        let mut pairs = 0;
        for level in [200, 301, 302, 303, 304, 450] {
            let g = ColorGates::new(level, "level");
            ghosts += g.discs.iter().filter(|d| d.ghost).count();
            changers += g.discs.iter().filter(|d| d.changer()).count();
            swaps += g.swaps.len();
            pairs += g
                .discs
                .windows(2)
                .filter(|w| w[0].lane == w[1].lane && w[0].color != w[1].color && w[1].arrive - w[0].arrive < 700.0)
                .count();
        }
        assert!(ghosts > 5 && changers > 5 && swaps > 3 && pairs > 3, "{ghosts} {changers} {swaps} {pairs}");
        let g = ColorGates::new(1, "level");
        assert!(g.discs.iter().all(|d| !d.ghost && !d.changer()) && g.swaps.is_empty());
    }

    #[test]
    fn color_gates_human_limited_bot_wins_with_three_stars() {
        let mut levels: Vec<u32> = LEVELS.to_vec();
        levels.extend((7..=500).step_by(37));
        for level in levels {
            let mut g = ColorGates::new(level, "level");
            bot(&mut g, 200.0, 100.0, 4.0, f64::INFINITY);
            if g.errors > 0 {
                let bad: Vec<_> = g.discs.iter().filter(|d| d.result == Some(false)).collect();
                let lane_hist: Vec<_> = g.discs.iter().filter(|d| d.lane == bad[0].lane).collect();
                panic!("level {level}: {bad:#?}\n{lane_hist:#?}\nswaps {:?}", g.swaps);
            }
            assert_eq!(g.stars(), 3, "level {level}");
            assert_eq!(g.passed, g.total);
            assert!(g.state()["summary"].as_str().unwrap().contains("Hata 0"));
        }
    }

    #[test]
    fn color_gates_pass_and_mismatch_scoring() {
        let mut g = ColorGates::new(1, "level");
        run(&mut g);
        // Set the first disc's gate correctly and let it arrive.
        let d = g.discs[0].clone();
        while g.gates[d.lane] != d.color {
            g.act(&json!({"tap": d.lane})).unwrap();
        }
        // Make sure nothing else arrives first.
        let dt = d.arrive - g.t + 1.0;
        g.tick(dt);
        assert_eq!(g.discs[0].result, Some(true));
        assert_eq!(g.passed, 1);
        assert_eq!(g.errors, 0);
        let ev = g.state()["ev"][0].clone();
        assert_eq!(ev[2], 0);
        // Now break the next disc's gate on purpose.
        let e = g.discs[1].clone();
        while g.gates[e.lane] == e.color {
            g.act(&json!({"tap": e.lane})).unwrap();
        }
        // The first-arriving disc of the rest might be in another lane: fix those up to e.
        g.tick(e.arrive - g.t + 1.0);
        assert_eq!(g.discs[1].result, Some(false));
        assert_eq!(g.errors, 1);
        assert_eq!(g.state()["lives"], 2);
        assert_eq!(g.streak, 0);
    }

    #[test]
    fn color_gates_gate_cycling_and_bad_actions() {
        let mut g = ColorGates::new(250, "level");
        let k = g.colors as u8;
        assert!(g.act(&json!({"tap": 0})).is_err()); // not started
        let before = g.gates.clone();
        run(&mut g);
        assert_eq!(g.gates, before);
        let c0 = g.gates[0];
        for i in 1..=k {
            g.act(&json!({"tap": 0})).unwrap();
            assert_eq!(g.gates[0], (c0 + i) % k);
        }
        assert_eq!(g.gates[0], c0, "full cycle returns to the start colour");
        assert_eq!(g.state()["tp"][0], k as u64);
        let snap = g.gates.clone();
        assert!(g.act(&json!({"tap": 9})).is_err());
        assert!(g.act(&json!({"start": true})).is_err());
        assert!(g.act(&json!({"bogus": 1})).is_err());
        assert_eq!(g.gates, snap);
    }

    #[test]
    fn color_gates_ghost_rule() {
        // A ghost passes only when the gate does NOT show its colour.
        let level = (200..500).find(|&l| ColorGates::new(l, "level").discs.iter().take(12).any(|d| d.ghost)).unwrap();
        for keep_out in [true, false] {
            let mut g = ColorGates::new(level, "level");
            let gi = g.discs.iter().position(|d| d.ghost).unwrap();
            bot_until(&mut g, gi);
            let d = g.discs[gi].clone();
            let lane = d.lane;
            if keep_out {
                if g.gates[lane] == d.color {
                    g.act(&json!({"tap": lane})).unwrap();
                }
            } else {
                while g.gates[lane] != d.color {
                    g.act(&json!({"tap": lane})).unwrap();
                }
            }
            let errs = g.errors;
            // Resolve exactly this disc (others before it were already handled by the bot).
            while g.next <= gi && g.phase == Phase::Run {
                g.tick(1.0);
            }
            assert_eq!(g.discs[gi].result, Some(keep_out));
            assert_eq!(g.errors, errs + (!keep_out) as u32);
            let last = g.events.back().unwrap();
            assert_eq!(last[2], if keep_out { 2 } else { 3 });
        }
    }

    /// Plays perfectly (oracle) until disc `upto` is the next to resolve and its predecessors in
    /// the same lane are gone.
    fn bot_until(g: &mut ColorGates, upto: usize) {
        run(g);
        while g.next < upto {
            let i = g.next;
            let d = g.discs[i].clone();
            // Fix the gate for the next arriving disc right before it arrives.
            g.tick((d.arrive - g.t - 0.5).max(0.0));
            let ok = |gate: u8| if d.ghost { gate != d.color } else { gate == d.color };
            while !ok(g.gates[d.lane]) {
                g.act(&json!({"tap": d.lane})).unwrap();
            }
            while g.next <= i {
                g.tick(1.0);
            }
        }
        assert_eq!(g.errors, 0);
    }

    /// Oracle play up to run time `t`: every disc that arrives meanwhile gets its gate set right
    /// before arrival — to its final colour, or (for disc `wrong`) to its first colour.
    fn oracle_to(g: &mut ColorGates, t: f64, wrong: Option<usize>) {
        while g.phase == Phase::Run && g.t < t {
            let Some(d) = g.discs.get(g.next).cloned() else { break };
            if d.arrive - 0.5 > t {
                g.tick(t - g.t);
                break;
            }
            g.tick((d.arrive - g.t - 0.5).max(0.0));
            let is_wrong = Some(g.next) == wrong;
            let want = |gate: u8| {
                if is_wrong {
                    gate == d.first
                } else if d.ghost {
                    gate != d.color
                } else {
                    gate == d.color
                }
            };
            let mut n = 0;
            while !want(g.gates[d.lane]) && n < MAX_COLORS {
                g.act(&json!({"tap": d.lane})).unwrap();
                n += 1;
            }
            let i = g.next;
            while g.next <= i && g.phase == Phase::Run {
                g.tick(1.0);
            }
        }
    }

    #[test]
    fn color_gates_changer_discs_change_colour() {
        let level = (11..500).find(|&l| ColorGates::new(l, "level").discs.iter().take(15).any(|d| d.changer())).unwrap();
        for wrong in [false, true] {
            let mut g = ColorGates::new(level, "level");
            let ci = g.discs.iter().position(|d| d.changer()).unwrap();
            let d = g.discs[ci].clone();
            run(&mut g);
            let row = |g: &ColorGates| g.state()["d"].as_array().unwrap().iter().find(|r| r[0] == d.id).cloned();
            // Before the warning window: first colour, no shimmer, next colour hidden.
            oracle_to(&mut g, d.change_at - CHANGE_WARN_MS - 50.0, None);
            if let Some(r) = row(&g) {
                assert_eq!(r[2], d.first);
                assert_eq!(r[3].as_i64().unwrap() & 2, 0);
                assert_eq!(r[8], -1);
            }
            oracle_to(&mut g, d.change_at - 200.0, None);
            let r = row(&g).expect("visible");
            assert_eq!(r[2], d.first);
            assert_eq!(r[3].as_i64().unwrap() & 2, 2, "shimmer warning");
            assert_eq!(r[8], d.color);
            oracle_to(&mut g, d.change_at + 1.0, None);
            let r = row(&g).expect("visible");
            assert_eq!(r[2], d.color);
            assert_eq!(r[3].as_i64().unwrap() & 2, 0);
            // The gate is judged against the final colour.
            oracle_to(&mut g, d.arrive + 2.0, wrong.then_some(ci));
            assert_eq!(g.discs[ci].result, Some(!wrong));
            assert_eq!(g.errors, wrong as u32);
        }
    }

    #[test]
    fn color_gates_swap_moves_gates() {
        let level = (31..500).find(|&l| !ColorGates::new(l, "level").swaps.is_empty()).unwrap();
        let mut g = ColorGates::new(level, "level");
        run(&mut g);
        let s = g.swaps[0].clone();
        oracle_to(&mut g, s.at - SWAP_WARN_MS + 10.0, None);
        let st = g.state();
        assert!(st["sw"].is_array(), "warning before the swap");
        oracle_to(&mut g, s.at - 1.0, None);
        let before = g.gates.clone();
        g.tick(2.0);
        for (i, &from) in s.perm.iter().enumerate() {
            assert_eq!(g.gates[i], before[from]);
        }
        assert!(g.state()["swd"].is_array());
    }

    #[test]
    fn color_gates_level_win_and_loss() {
        // Idle player loses after three errors.
        let mut g = ColorGates::new(1, "level");
        run(&mut g);
        let mut guard = 0;
        while g.phase == Phase::Run {
            g.tick(16.0);
            guard += 1;
            assert!(guard < 100_000);
        }
        let st = g.state();
        assert_eq!(st["status"], "lost");
        assert_eq!(st["stars"], 0);
        assert_eq!(g.errors, LIVES);
        assert!(st["summary"].as_str().unwrap().contains("Canlar bitti"));
        // Oracle with exactly two deliberate errors: won with 1 star.
        let mut g = ColorGates::new(2, "level");
        run(&mut g);
        let mut sabotaged = 0;
        while g.phase == Phase::Run {
            let i = g.next;
            let d = g.discs[i].clone();
            g.tick((d.arrive - g.t - 0.5).max(0.0));
            let ok = |gate: u8| if d.ghost { gate != d.color } else { gate == d.color };
            if sabotaged < 2 && i % 7 == 3 {
                while ok(g.gates[d.lane]) {
                    g.act(&json!({"tap": d.lane})).unwrap();
                }
                sabotaged += 1;
            } else {
                while !ok(g.gates[d.lane]) {
                    g.act(&json!({"tap": d.lane})).unwrap();
                }
            }
            while g.next <= i && g.phase == Phase::Run {
                g.tick(1.0);
            }
        }
        assert_eq!(g.status(), "won");
        assert_eq!(g.errors, 2);
        assert_eq!(g.stars(), 1);
        assert!(g.act(&json!({"tap": 0})).is_err());
    }

    #[test]
    fn color_gates_endless_ramps_and_reaches_lost() {
        let mut g = ColorGates::new(1, "endless");
        assert_eq!(g.state()["title"], "Sonsuz yağmur");
        // A good player for a long while: lanes and colours join mid-run, no errors.
        bot(&mut g, 200.0, 100.0, 4.0, 70_000.0);
        assert_eq!(g.errors, 0);
        assert_eq!(g.lanes, 4, "lanes joined");
        assert!(g.colors >= 4);
        assert!(g.passed > 100, "passed {}", g.passed);
        // Then the player stops: the rain wins.
        while g.phase == Phase::Run {
            g.tick(16.0);
        }
        let st = g.state();
        assert_eq!(st["status"], "lost");
        assert_eq!(st["score"].as_u64().unwrap(), g.passed as u64);
        // Idle player loses fast.
        let mut g = ColorGates::with_seed(endless_params(0), 7, true);
        run(&mut g);
        let mut guard = 0;
        while g.phase == Phase::Run {
            g.tick(16.0);
            guard += 1;
            assert!(guard < 200_000);
        }
        assert_eq!(g.state()["status"], "lost");
    }

    #[test]
    fn color_gates_endless_schedule_is_fair() {
        for seed in 1..4u64 {
            let mut g = ColorGates::with_seed(endless_params(0), seed, true);
            // Generate a long schedule without pruning by never resolving.
            for _ in 0..260 {
                let p = endless_params(g.gen.next_id);
                let s = g.gen.next(&p);
                g.push_step(s);
            }
            assert!(g.cfgs.len() >= 2, "lanes join in endless");
            // Lane-change events delay information: check the lane-gap rule with the hardest window.
            check_fair(&g, HARD_REACT_MS);
        }
    }

    #[test]
    fn color_gates_state_shape() {
        let mut g = ColorGates::new(137, "level");
        run(&mut g);
        g.tick(4000.0_f64.min(200.0));
        for _ in 0..30 {
            g.tick(100.0);
        }
        let st = g.state();
        assert_eq!(st["lanes"], 3);
        let d = st["d"].as_array().unwrap();
        assert!(!d.is_empty());
        for r in d {
            let r = r.as_array().unwrap();
            assert_eq!(r.len(), 9);
            let p = r[4].as_i64().unwrap();
            assert!((0..=1000).contains(&p));
        }
    }

    /// Prints the realised pace per level (duration, discs/s, taps/s, specials).
    #[test]
    #[ignore]
    fn color_gates_calibrate() {
        for level in [1, 2, 5, 10, 20, 40, 41, 80, 120, 160, 161, 250, 330, 400, 500] {
            let g = ColorGates::new(level, "level");
            let p = params(level);
            let secs = g.discs.last().unwrap().arrive / 1000.0;
            let taps: u32 = g.discs.iter().map(|d| d.need as u32).sum();
            let mut lane_gap = f64::INFINITY;
            for (i, d) in g.discs.iter().enumerate() {
                if let Some(e) = g.discs[i + 1..].iter().find(|e| e.lane == d.lane) {
                    if e.color != d.color && !e.ghost && !d.ghost {
                        lane_gap = lane_gap.min(e.arrive - d.arrive);
                    }
                }
            }
            println!(
                "L{level:3} {} lanes k{} {:>2} discs {:5.1}s  {:.2} discs/s  {:.2} taps/s  ghosts {:2} changers {:2} swaps {:2}  min lane gap {:4.0} ms  [{}]",
                p.lanes,
                p.colors,
                g.discs.len(),
                secs,
                g.discs.len() as f64 / secs,
                taps as f64 / secs,
                g.discs.iter().filter(|d| d.ghost).count(),
                g.discs.iter().filter(|d| d.changer()).count(),
                g.swaps.len(),
                lane_gap,
                title(&p)
            );
        }
    }

    #[test]
    #[ignore]
    fn color_gates_timing() {
        let t0 = std::time::Instant::now();
        let mut worst = 0.0f64;
        for level in 1..=500 {
            let t = std::time::Instant::now();
            let g = ColorGates::new(level, "level");
            assert!(!g.discs.is_empty());
            worst = worst.max(t.elapsed().as_secs_f64());
        }
        println!("500 levels: {:?}, worst {:.2} ms", t0.elapsed(), worst * 1000.0);
    }

    #[test]
    #[ignore]
    fn color_gates_bot_all_levels() {
        for level in 1..=500 {
            let mut g = ColorGates::new(level, "level");
            check_fair(&g, params(level).react_ms);
            bot(&mut g, 200.0, 100.0, 4.0, f64::INFINITY);
            assert_eq!(g.stars(), 3, "level {level}");
        }
    }
}
