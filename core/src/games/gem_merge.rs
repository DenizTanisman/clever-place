//! Mücevher Birleştir — drop-and-merge gem physics.
//!
//! A container (`w` × 140 units, y down) holds circular gems of 11 tiers with growing radii. The
//! player picks an x and drops the current gem (tiers 1–5 only; the next one is shown). Two gems of
//! the same tier that touch merge into the next tier at their contact point (score += value of the
//! new tier); two top-tier gems vanish together for a bonus. The game is lost when any settled gem
//! stays above the danger line for more than 2 s.
//!
//! Physics: semi-implicit Euler with 4 substeps per tick (tick dt capped at 1/30 s), circle–circle
//! and circle–wall contacts solved with restitution + Coulomb friction impulses (with rolling via
//! angular velocity) and Baumgarte-style positional correction, four solver iterations per
//! substep, a sweep-and-prune broad phase on x and sleeping for gems at rest (a sleeping gem acts
//! as static until hit hard; any merge wakes everything). Tuned to slide and roll freely: light
//! air / spin damping, μ = 0.22, and the resting-weight friction term only on supporting contacts.
//! Slow impacts (< 20 units/s) do not bounce, and rest is judged by actual displacement, so
//! stacks settle instead of jittering.
//!
//! ## Level curve (`params`)
//! `t = (level-1)/4` (0..=124), `d = t/124`; the container narrows from 100 to 88 units.
//! - 0 **Forge**: create a tier `7 + ⌊4.99d⌋` gem (7..11). Stars by drops vs. an estimate of the
//!   minimum `e = 2^(T-1)/6.2`: 3★ ≤ 1.6e+6, 2★ ≤ 2.4e+10.
//! - 1 **Score**: reach `S = 260 + 4t` points within `40 + t/5` drops.
//! - 2 **Forge in drops**: create tier `7 + ⌊3.99d⌋` within `e·(2.6 − 1.0d) + 4` drops.
//! - 3 **Cluttered**: start with `6 + 8d` settled gems of mixed tiers, reach `S = 220 + 4t` within
//!   `36 + t/6` drops.
//!
//! Limited-drop goals: 3★ when finished within 72 % of the drops, 2★ within 88 %.
//! Drops are seeded per level (`seed_for`), so a level's gem sequence is always the same.
//! Endless: plain score attack.
//!
//! State: `{status, stars, title, goal, score, summary?, w, h, dl, g, cur, nx, cd, warn, fx, hud}`
//! - `g`: flat ints, 5 per gem: `x·100, y·100, tier, angle·100 (0..628), scale% (grow-in)`.
//! - `cur`/`nx`: current / next tier, `cd`: ms until the next drop is allowed, `warn`: 0..1 danger.
//! - `fx`: recent merges `[[id, x·100, y·100, tier], …]` (ids increase; the view sparkles new ones).
//!
//! Actions: `{"a":"drop","x":x}` (x in container units; clamped to the walls).

use crate::rng::{seed_for, time_seed, Rng};
use crate::Session;
use serde_json::{json, Value};

pub const TIERS: usize = 11;
pub const RADII: [f64; TIERS] = [4.4, 5.8, 7.4, 8.9, 10.6, 12.8, 15.0, 17.6, 20.4, 23.8, 27.8];
pub const VALUES: [u32; TIERS] = [1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 66];
const BIG_BONUS: u32 = 200;

pub const HEIGHT: f64 = 140.0;
pub const DANGER: f64 = 26.0;
const SPAWN_Y: f64 = 14.0;
const GRAVITY: f64 = 750.0;
const SUBSTEPS: usize = 4;
const ITERS: usize = 4;
const RESTITUTION: f64 = 0.12;
/// Impacts slower than this (units/s) do not bounce: resting contacts stay put instead of hopping.
const BOUNCE_MIN: f64 = 20.0;

fn bounce(vn: f64) -> f64 {
    if -vn > BOUNCE_MIN { RESTITUTION } else { 0.0 }
}
const FRICTION: f64 = 0.22;
/// Velocity damping per second (air drag) and rolling (spin) damping per second.
const LIN_DAMP: f64 = 0.1;
const SPIN_DAMP: f64 = 0.9;
/// Speed (units/s, measured as displacement per substep) below which a gem counts towards sleep.
const SLEEP_V: f64 = 2.5;
const SLOP: f64 = 0.05;
const COOLDOWN_MS: f64 = 480.0;
const GROW_MS: f64 = 150.0;
const OVER_MS: f64 = 2000.0;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Goal {
    Tier { tier: u8, max: u32 },
    Score { target: u32, max: u32 },
}

#[derive(Clone, Debug)]
pub struct Params {
    pub goal: Goal,
    pub width: f64,
    pub clutter: usize,
    pub title: &'static str,
}

/// Rough minimum drop count to build one gem of `tier` (avg drop = 6.2 tier-1 units).
fn tier_estimate(tier: u8) -> f64 {
    (1u32 << (tier - 1)) as f64 / 6.2
}

pub fn params(level: u32) -> Params {
    let level = level.clamp(1, crate::MAX_LEVEL);
    let t = (level - 1) / 4;
    let d = t as f64 / 124.0;
    let width = 100.0 - 12.0 * d;
    match (level - 1) % 4 {
        0 => Params { goal: Goal::Tier { tier: 7 + (4.99 * d) as u8, max: 0 }, width, clutter: 0, title: "Döv" },
        1 => Params { goal: Goal::Score { target: 260 + 4 * t, max: 40 + t / 5 }, width, clutter: 0, title: "Puan" },
        2 => {
            let tier = 7 + (3.99 * d) as u8;
            let max = (tier_estimate(tier) * (2.6 - 1.0 * d)).ceil() as u32 + 4;
            Params { goal: Goal::Tier { tier, max }, width, clutter: 0, title: "Sınırlı düşüş" }
        }
        _ => Params {
            goal: Goal::Score { target: 220 + 4 * t, max: 36 + t / 6 },
            width,
            clutter: 6 + (8.0 * d) as usize,
            title: "Dolu kasa",
        },
    }
}

#[derive(Clone, Debug)]
struct Gem {
    x: f64,
    y: f64,
    vx: f64,
    vy: f64,
    ang: f64,
    w: f64,
    tier: u8, // 1..=11
    age: f64,
    still: f64,
    asleep: bool,
    px: f64, // position at the start of the substep (sleep test)
    py: f64,
    over: f64,
    dead: bool,
}

impl Gem {
    fn new(x: f64, y: f64, tier: u8) -> Gem {
        Gem { x, y, vx: 0.0, vy: 0.0, ang: 0.0, w: 0.0, tier, age: 0.0, still: 0.0, asleep: false, px: x, py: y, over: 0.0, dead: false }
    }
    fn grow(&self) -> f64 {
        (0.55 + 0.45 * self.age / GROW_MS).min(1.0)
    }
    fn r(&self) -> f64 {
        RADII[self.tier as usize - 1] * self.grow()
    }
    fn inv_m(&self) -> f64 {
        let r = RADII[self.tier as usize - 1];
        1.0 / (r * r)
    }
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Status {
    Playing,
    Won,
    Lost,
}

#[derive(Clone)]
pub struct GemMerge {
    goal: Option<Goal>,
    title: &'static str,
    width: f64,
    gems: Vec<Gem>,
    rng: Rng,
    cur: u8,
    next: u8,
    cooldown: f64,
    score: u32,
    drops: u32,
    best_tier: u8,
    merges: u32,
    time_ms: f64,
    idle_ms: f64,
    status: Status,
    fx: Vec<(u32, f64, f64, u8)>,
    fx_id: u32,
}

pub fn create(level: u32, mode: &str) -> Result<Box<dyn Session>, String> {
    Ok(Box::new(GemMerge::new(level, mode)))
}

impl GemMerge {
    pub fn new(level: u32, mode: &str) -> Self {
        let (goal, width, clutter, title, seed) = if mode == "endless" {
            (None, 100.0, 0, "Sonsuz", time_seed())
        } else {
            let p = params(level);
            (Some(p.goal), p.width, p.clutter, p.title, seed_for("gem_merge", level, 0))
        };
        let mut rng = Rng::new(seed);
        let cur = 1 + rng.below(5) as u8;
        let next = 1 + rng.below(5) as u8;
        let mut g = GemMerge {
            goal,
            title,
            width,
            gems: vec![],
            rng,
            cur,
            next,
            cooldown: 0.0,
            score: 0,
            drops: 0,
            best_tier: 0,
            merges: 0,
            time_ms: 0.0,
            idle_ms: 0.0,
            status: Status::Playing,
            fx: vec![],
            fx_id: 0,
        };
        if clutter > 0 {
            g.add_clutter(clutter);
        }
        g
    }

    /// Pre-place `n` gems of mixed tiers (no equal neighbours in a row) and let them settle.
    fn add_clutter(&mut self, n: usize) {
        let mut crng = self.rng.clone();
        let mut last = 0u8;
        let mut x = 0.0;
        let mut y = HEIGHT;
        for _ in 0..n {
            let mut tier = 1 + crng.below(6) as u8;
            if tier == last {
                tier = tier % 6 + 1;
            }
            last = tier;
            let r = RADII[tier as usize - 1];
            if x + 2.0 * r > self.width {
                x = 0.0;
                y -= 26.0;
            }
            let gem = Gem { age: GROW_MS, ..Gem::new(x + r, y - r, tier) };
            x += 2.0 * r + 0.2;
            self.gems.push(gem);
        }
        for _ in 0..150 {
            self.step(1000.0 / 60.0);
        }
        self.score = 0;
        self.merges = 0;
        self.fx.clear();
        self.best_tier = 0;
        self.rng = crng;
    }

    fn radius_of(tier: u8) -> f64 {
        RADII[tier as usize - 1]
    }

    fn drop_at(&mut self, x: f64) -> Result<(), String> {
        if self.cooldown > 0.0 {
            return Err("Taş henüz hazır değil".into());
        }
        if !x.is_finite() {
            return Err("Geçersiz konum".into());
        }
        let r = Self::radius_of(self.cur);
        let x = x.clamp(r, self.width - r);
        self.gems.push(Gem { vy: 40.0, age: GROW_MS, ..Gem::new(x, SPAWN_Y, self.cur) });
        self.drops += 1;
        self.cur = self.next;
        self.next = 1 + self.rng.below(5) as u8;
        self.cooldown = COOLDOWN_MS;
        Ok(())
    }

    /// One physics frame of `dt` ms.
    fn step(&mut self, dt: f64) {
        let h = (dt / 1000.0).min(1.0 / 30.0) / SUBSTEPS as f64;
        for _ in 0..SUBSTEPS {
            self.substep(h);
        }
        self.gems.retain(|g| !g.dead);
    }

    fn substep(&mut self, h: f64) {
        let damp = 1.0 - LIN_DAMP * h;
        for g in self.gems.iter_mut() {
            g.age += h * 1000.0;
            g.px = g.x;
            g.py = g.y;
            if g.asleep {
                continue;
            }
            g.vy += GRAVITY * h;
            g.vx *= damp;
            g.vy *= damp;
            g.w *= 1.0 - SPIN_DAMP * h;
            g.x += g.vx * h;
            g.y += g.vy * h;
            g.ang += g.w * h;
        }
        // Broad phase: sort by left edge.
        let mut order: Vec<usize> = (0..self.gems.len()).collect();
        order.sort_by(|&a, &b| {
            let ka = self.gems[a].x - self.gems[a].r();
            let kb = self.gems[b].x - self.gems[b].r();
            ka.partial_cmp(&kb).unwrap_or(std::cmp::Ordering::Equal)
        });
        let mut pairs = vec![];
        for i in 0..order.len() {
            let a = &self.gems[order[i]];
            let right = a.x + a.r();
            for &oj in &order[i + 1..] {
                let b = &self.gems[oj];
                if b.x - b.r() > right {
                    break;
                }
                let (dx, dy) = (b.x - a.x, b.y - a.y);
                let rr = a.r() + b.r() + 0.3;
                if dx * dx + dy * dy < rr * rr {
                    pairs.push((order[i], oj));
                }
            }
        }
        for _ in 0..ITERS {
            for g in self.gems.iter_mut() {
                if !g.asleep {
                    Self::walls(g, self.width, h);
                }
            }
            for &(i, j) in &pairs {
                self.contact(i, j, h);
            }
        }
        self.merge(&pairs);
        // Sleep bookkeeping. Judged by how far the gem actually moved this substep, not by its
        // velocity: a gem resting in a stack keeps a small downward velocity that the two solver
        // iterations do not fully cancel (positional correction holds it in place instead), which
        // used to keep busy boards awake and jittering forever.
        for g in self.gems.iter_mut() {
            if g.asleep {
                continue;
            }
            let (mx, my) = ((g.x - g.px) / h, (g.y - g.py) / h);
            if mx.abs() < SLEEP_V && my.abs() < SLEEP_V {
                // Held in place: drop the phantom velocity so friction stops turning it into spin.
                g.vx = mx;
                g.vy = my;
            }
            if mx.abs() < SLEEP_V && my.abs() < SLEEP_V && g.w.abs() < 0.4 {
                g.still += h;
                if g.still > 0.5 {
                    g.asleep = true;
                    g.vx = 0.0;
                    g.vy = 0.0;
                    g.w = 0.0;
                }
            } else {
                g.still = 0.0;
            }
        }
    }

    fn walls(g: &mut Gem, width: f64, h: f64) {
        let r = g.r();
        // (normal x, normal y, penetration) — normals point into the container.
        let hits = [(1.0, 0.0, r - g.x), (-1.0, 0.0, g.x + r - width), (0.0, -1.0, g.y + r - HEIGHT)];
        for (nx, ny, pen) in hits {
            if pen <= 0.0 {
                continue;
            }
            g.x += nx * pen;
            g.y += ny * pen;
            let vn = g.vx * nx + g.vy * ny;
            let mut jn = 0.0;
            if vn < 0.0 {
                jn = -(1.0 + bounce(vn)) * vn;
                g.vx += jn * nx;
                g.vy += jn * ny;
            }
            // Friction against the wall (tangent t = (-ny, nx)); contact point at -r·n.
            let (tx, ty) = (-ny, nx);
            let vt = g.vx * tx + g.vy * ty - g.w * r;
            // Resting weight only presses on the floor (|ny| = 1), not on the side walls.
            let cap = FRICTION * (jn + GRAVITY * h * ny.abs() / ITERS as f64);
            let jt = (-vt / 3.0).clamp(-cap, cap);
            g.vx += jt * tx;
            g.vy += jt * ty;
            g.w -= 2.0 * jt / r;
        }
    }

    fn contact(&mut self, i: usize, j: usize, h: f64) {
        let (a, b) = if i < j {
            let (l, r) = self.gems.split_at_mut(j);
            (&mut l[i], &mut r[0])
        } else {
            let (l, r) = self.gems.split_at_mut(i);
            (&mut r[0], &mut l[j])
        };
        if a.dead || b.dead || (a.asleep && b.asleep) {
            return;
        }
        let (dx, dy) = (b.x - a.x, b.y - a.y);
        let dist = (dx * dx + dy * dy).sqrt().max(1e-6);
        let (ra, rb) = (a.r(), b.r());
        let pen = ra + rb - dist;
        if pen <= 0.0 {
            return;
        }
        let (nx, ny) = (dx / dist, dy / dist);
        let (tx, ty) = (-ny, nx);
        let mut ia = if a.asleep { 0.0 } else { a.inv_m() };
        let mut ib = if b.asleep { 0.0 } else { b.inv_m() };
        let vn = (b.vx - a.vx) * nx + (b.vy - a.vy) * ny;
        // Wake a sleeper on a real hit.
        if (a.asleep || b.asleep) && (vn < -12.0 || pen > 1.2) {
            a.asleep = false;
            b.asleep = false;
            a.still = 0.0;
            b.still = 0.0;
            ia = a.inv_m();
            ib = b.inv_m();
        }
        let sum = ia + ib;
        if sum == 0.0 {
            return;
        }
        let mut jn = 0.0;
        if vn < 0.0 {
            jn = -(1.0 + bounce(vn)) * vn / sum;
            a.vx -= jn * nx * ia;
            a.vy -= jn * ny * ia;
            b.vx += jn * nx * ib;
            b.vy += jn * ny * ib;
        }
        let vt = (b.vx - a.vx) * tx + (b.vy - a.vy) * ty - b.w * rb - a.w * ra;
        // The resting-weight term scales with how much the contact supports (|ny|: 1 when stacked,
        // 0 side by side) and is split over the solver iterations, so friction stays Coulomb-like.
        let cap = FRICTION * (jn + GRAVITY * h * ny.abs() / (sum * ITERS as f64));
        let jt = (-vt / (3.0 * sum)).clamp(-cap, cap);
        a.vx -= jt * tx * ia;
        a.vy -= jt * ty * ia;
        b.vx += jt * tx * ib;
        b.vy += jt * ty * ib;
        a.w -= 2.0 * jt * ia / ra.max(1e-3);
        b.w -= 2.0 * jt * ib / rb.max(1e-3);
        // Positional correction (capped to keep merges and drops calm).
        let corr = ((pen - SLOP).max(0.0) * 0.6).min(1.5) / sum;
        a.x -= nx * corr * ia;
        a.y -= ny * corr * ia;
        b.x += nx * corr * ib;
        b.y += ny * corr * ib;
    }

    fn merge(&mut self, pairs: &[(usize, usize)]) {
        let mut born = vec![];
        let mut any = false;
        for &(i, j) in pairs {
            let (a, b) = (&self.gems[i], &self.gems[j]);
            if a.dead || b.dead || a.tier != b.tier {
                continue;
            }
            let (dx, dy) = (b.x - a.x, b.y - a.y);
            let reach = a.r() + b.r() + 0.25;
            if dx * dx + dy * dy > reach * reach {
                continue;
            }
            let tier = a.tier;
            let (ra, rb) = (a.r(), b.r());
            let k = ra / (ra + rb);
            let (cx, cy) = (a.x + dx * k, a.y + dy * k);
            let (vx, vy) = ((a.vx + b.vx) / 2.0, (a.vy + b.vy) / 2.0);
            self.gems[i].dead = true;
            self.gems[j].dead = true;
            any = true;
            self.merges += 1;
            self.fx_id += 1;
            if tier as usize == TIERS {
                self.score += BIG_BONUS + VALUES[TIERS - 1];
                self.fx.push((self.fx_id, cx, cy, tier));
            } else {
                let nt = tier + 1;
                self.score += VALUES[nt as usize - 1];
                self.best_tier = self.best_tier.max(nt);
                self.fx.push((self.fx_id, cx, cy, nt));
                let r = RADII[nt as usize - 1];
                let x = cx.clamp(r * 0.55, self.width - r * 0.55);
                born.push(Gem { vx, vy: vy.min(0.0) - 20.0, ..Gem::new(x, cy, nt) });
            }
        }
        if any {
            for g in self.gems.iter_mut() {
                g.asleep = false;
                g.still = 0.0;
            }
            self.gems.extend(born);
            if self.fx.len() > 8 {
                let cut = self.fx.len() - 8;
                self.fx.drain(..cut);
            }
        }
    }

    fn check(&mut self, dt: f64) {
        let mut worst: f64 = 0.0;
        for g in self.gems.iter_mut() {
            let speed = (g.vx * g.vx + g.vy * g.vy).sqrt();
            if g.age > 1200.0 && g.y - g.r() < DANGER && speed < 30.0 {
                g.over += dt;
            } else {
                g.over = 0.0;
            }
            worst = worst.max(g.over);
        }
        if worst > OVER_MS {
            self.status = Status::Lost;
            return;
        }
        let done = match self.goal {
            Some(Goal::Tier { tier, .. }) => self.best_tier >= tier,
            Some(Goal::Score { target, .. }) => self.score >= target,
            None => false,
        };
        if done {
            self.status = Status::Won;
            return;
        }
        // Out of drops: wait until the last gem has settled (merges may still win), then lose.
        let max = match self.goal {
            Some(Goal::Tier { max, .. }) | Some(Goal::Score { max, .. }) => max,
            None => 0,
        };
        if max > 0 && self.drops >= max {
            self.idle_ms += dt;
            if self.idle_ms > 4000.0 || (self.cooldown <= 0.0 && self.gems.iter().all(|g| g.asleep)) {
                self.status = Status::Lost;
            }
        }
    }

    fn warn(&self) -> f64 {
        self.gems.iter().map(|g| g.over).fold(0.0, f64::max) / OVER_MS
    }

    fn stars(&self) -> u32 {
        if self.status != Status::Won {
            return 0;
        }
        let used = self.drops as f64;
        let (three, two) = match self.goal {
            Some(Goal::Tier { tier, max: 0 }) => {
                let e = tier_estimate(tier);
                (used <= 1.6 * e + 6.0, used <= 2.4 * e + 10.0)
            }
            Some(Goal::Tier { max, .. }) | Some(Goal::Score { max, .. }) => {
                let m = max as f64;
                (used <= 0.72 * m, used <= 0.88 * m)
            }
            None => (false, false),
        };
        if three {
            3
        } else if two {
            2
        } else {
            1
        }
    }

    fn goal_text(&self) -> String {
        match self.goal {
            None => "Aynı taşları birleştir · çizginin üstünde kalma".into(),
            Some(Goal::Tier { tier, max: 0 }) => format!("{tier}. seviye bir mücevher yap"),
            Some(Goal::Tier { tier, max }) => format!("{tier}. seviye mücevher · {max} düşüş içinde"),
            Some(Goal::Score { target, max }) => format!("{target} puan · {max} düşüş içinde"),
        }
    }

    fn hud(&self) -> Value {
        let top = self.best_tier.max(self.gems.iter().map(|g| g.tier).max().unwrap_or(0));
        match self.goal {
            None => json!([["Puan", self.score], ["Düşüş", self.drops], ["En büyük", top]]),
            Some(Goal::Tier { tier, max }) => {
                let d = if max > 0 { format!("{}/{}", self.drops, max) } else { self.drops.to_string() };
                json!([["En büyük", format!("{}/{}", top, tier)], ["Düşüş", d], ["Puan", self.score]])
            }
            Some(Goal::Score { target, max }) => json!([
                ["Puan", format!("{}/{}", self.score, target)],
                ["Düşüş", format!("{}/{}", self.drops, max)],
                ["En büyük", top]
            ]),
        }
    }
}

impl Session for GemMerge {
    fn state(&self) -> Value {
        let status = match self.status {
            Status::Playing => "playing",
            Status::Won => "won",
            Status::Lost => "lost",
        };
        let mut g = Vec::with_capacity(self.gems.len() * 5);
        for gem in &self.gems {
            let ang = gem.ang.rem_euclid(std::f64::consts::TAU);
            g.push((gem.x * 100.0).round() as i32);
            g.push((gem.y * 100.0).round() as i32);
            g.push(gem.tier as i32);
            g.push((ang * 100.0) as i32);
            g.push((gem.grow() * 100.0).round() as i32);
        }
        let fx: Vec<Value> = self
            .fx
            .iter()
            .map(|&(id, x, y, t)| json!([id, (x * 100.0).round() as i32, (y * 100.0).round() as i32, t]))
            .collect();
        let mut v = json!({
            "status": status,
            "stars": self.stars(),
            "title": self.title,
            "goal": self.goal_text(),
            "score": self.score,
            "w": self.width,
            "h": HEIGHT,
            "dl": DANGER,
            "g": g,
            "cur": self.cur,
            "nx": self.next,
            "cd": self.cooldown.max(0.0).round(),
            "warn": (self.warn() * 100.0).round() / 100.0,
            "fx": fx,
            "hud": self.hud(),
        });
        if self.status != Status::Playing {
            let secs = (self.time_ms / 1000.0) as u64;
            v["summary"] = json!(format!(
                "Düşüş: {} · Birleşme: {} · En büyük: {}. seviye · Süre: {}:{:02}",
                self.drops,
                self.merges,
                self.best_tier,
                secs / 60,
                secs % 60
            ));
        }
        v
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if self.status != Status::Playing {
            return Err("Oyun bitti".into());
        }
        match a["a"].as_str() {
            Some("drop") => {
                let x = a["x"].as_f64().ok_or("Konum eksik")?;
                let max = match self.goal {
                    Some(Goal::Tier { max, .. }) | Some(Goal::Score { max, .. }) => max,
                    None => 0,
                };
                if max > 0 && self.drops >= max {
                    return Err("Düşüş hakkın bitti".into());
                }
                self.drop_at(x)
            }
            _ => Err("Bilinmeyen hamle".into()),
        }
    }

    fn tick(&mut self, dt: f64) {
        if self.status != Status::Playing {
            return;
        }
        let dt = dt.clamp(0.0, 100.0);
        self.time_ms += dt;
        self.cooldown -= dt;
        self.step(dt);
        self.check(dt);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LEVELS: [u32; 9] = [1, 2, 3, 50, 137, 250, 400, 499, 500];

    /// Simple player: drop onto the highest gem of the same tier, otherwise keep big gems left and
    /// small ones right.
    fn aim(g: &GemMerge) -> f64 {
        let same = g
            .gems
            .iter()
            .filter(|m| m.tier == g.cur)
            .min_by(|a, b| (a.y - a.r()).partial_cmp(&(b.y - b.r())).unwrap());
        if let Some(m) = same {
            return m.x;
        }
        let r = GemMerge::radius_of(g.cur);
        r + (g.width - 2.0 * r) * (0.35 + 0.13 * (5 - g.cur.min(5)) as f64)
    }

    fn bot_play(g: &mut GemMerge, max_drops: u32) {
        let mut guard = 0;
        while g.status == Status::Playing && g.drops < max_drops {
            if g.cooldown <= 0.0 && g.act(&json!({"a": "drop", "x": aim(g)})).is_err() {
                // out of drops: let the board settle
            }
            for _ in 0..30 {
                g.tick(16.0);
            }
            guard += 1;
            assert!(guard < 10_000);
        }
        let mut settle = 0;
        while g.status == Status::Playing && settle < 600 {
            g.tick(16.0);
            settle += 1;
        }
    }

    #[test]
    fn gem_merge_levels_generate_and_are_deterministic() {
        for level in LEVELS {
            let a = GemMerge::new(level, "level");
            let b = GemMerge::new(level, "level");
            assert_eq!(a.status, Status::Playing);
            assert_eq!((a.cur, a.next), (b.cur, b.next));
            assert_eq!(a.gems.len(), b.gems.len());
            for (x, y) in a.gems.iter().zip(&b.gems) {
                assert_eq!((x.x, x.y, x.tier), (y.x, y.y, y.tier));
            }
            // Clutter settled inside the container and below the danger line.
            for gem in &a.gems {
                assert!(gem.x >= gem.r() - 0.5 && gem.x <= a.width - gem.r() + 0.5);
                assert!(gem.y + gem.r() <= HEIGHT + 0.5);
                assert!(gem.y - gem.r() > DANGER, "level {level}");
            }
            let st = a.state();
            assert_eq!(st["g"].as_array().unwrap().len(), a.gems.len() * 5);
        }
    }

    #[test]
    fn gem_merge_equal_gems_merge_and_score() {
        let mut g = GemMerge::new(1, "endless");
        g.gems.push(Gem::new(40.0, 120.0, 3));
        g.gems.push(Gem::new(48.0, 120.0, 3));
        for _ in 0..30 {
            g.tick(16.0);
        }
        assert_eq!(g.gems.len(), 1);
        assert_eq!(g.gems[0].tier, 4);
        assert_eq!(g.score, VALUES[3]);
        assert_eq!(g.fx.len(), 1);
        // Two top-tier gems vanish with the bonus.
        let mut g = GemMerge::new(1, "endless");
        g.gems.push(Gem::new(28.0, 110.0, 11));
        g.gems.push(Gem::new(72.0, 110.0, 11));
        for _ in 0..90 {
            g.tick(16.0);
        }
        assert!(g.gems.is_empty());
        assert_eq!(g.score, BIG_BONUS + VALUES[10]);
    }

    #[test]
    fn gem_merge_gems_settle_and_sleep() {
        let mut g = GemMerge::new(1, "endless");
        for (i, t) in [1u8, 2, 3, 4, 5, 1, 2, 3].iter().enumerate() {
            g.gems.push(Gem::new(8.0 + i as f64 * 11.0, 60.0 - (i % 3) as f64 * 15.0, *t));
        }
        for _ in 0..300 {
            g.tick(16.0);
        }
        for gem in &g.gems {
            assert!(gem.asleep, "{gem:?}");
            assert!(gem.y + gem.r() <= HEIGHT + 0.3);
        }
    }

    /// Busy boards (36 drops, 40 seeds) must fall fully asleep soon after the drops stop: no
    /// endless jitter or spinning in place. Before the displacement-based sleep test, 4 solver
    /// iterations and the no-bounce threshold, 22 of 60 such boards never slept.
    #[test]
    fn gem_merge_busy_board_falls_asleep() {
        for seed in 0..40u64 {
            let mut g = busy_board(seed, 36);
            let mut n = 0;
            while g.status == Status::Playing && !g.gems.iter().all(|m| m.asleep) {
                g.tick(16.0);
                n += 1;
                assert!(n < 600, "seed {seed}: board still awake after {n} ticks");
            }
        }
    }

    /// An endless-style board after `drops` bot drops, seeded (endless mode itself is time-seeded).
    fn busy_board(seed: u64, drops: u32) -> GemMerge {
        let mut g = GemMerge::new(1, "level");
        g.goal = None;
        g.rng = Rng::new(seed);
        g.cur = 1 + g.rng.below(5) as u8;
        g.next = 1 + g.rng.below(5) as u8;
        for _ in 0..drops {
            g.cooldown = 0.0;
            let _ = g.act(&json!({"a": "drop", "x": aim(&g)}));
            for _ in 0..40 {
                g.tick(16.0);
            }
            if g.status != Status::Playing {
                break;
            }
        }
        g
    }

    #[test]
    fn gem_merge_illegal_actions_rejected() {
        let mut g = GemMerge::new(1, "level");
        let before = g.state();
        assert!(g.act(&json!({"a": "shake"})).is_err());
        assert!(g.act(&json!({"a": "drop"})).is_err());
        assert_eq!(g.state(), before);
        g.act(&json!({"a": "drop", "x": 50.0})).unwrap();
        let after = g.state();
        assert!(g.act(&json!({"a": "drop", "x": 50.0})).is_err(), "cooldown");
        assert_eq!(g.state(), after);
    }

    #[test]
    fn gem_merge_bot_wins_early_levels() {
        let mut stars = vec![];
        for level in [1, 2, 3, 4] {
            let mut g = GemMerge::new(level, "level");
            bot_play(&mut g, 400);
            assert_eq!(g.status, Status::Won, "level {level}: {}", g.state()["summary"]);
            stars.push(g.stars());
        }
        assert!(stars.contains(&3), "{stars:?}");
    }

    #[test]
    fn gem_merge_endless_reaches_lost() {
        let mut g = GemMerge::new(1, "endless");
        let mut guard = 0;
        // Drop everything in the same corner as fast as allowed: the pile must overflow.
        while g.status == Status::Playing {
            if g.cooldown <= 0.0 {
                g.act(&json!({"a": "drop", "x": (guard % 3) as f64 * 40.0 })).unwrap();
            }
            g.tick(16.0);
            guard += 1;
            assert!(guard < 60_000);
        }
        assert_eq!(g.status, Status::Lost);
        assert!(g.state()["summary"].is_string());
    }

    #[test]
    #[ignore]
    fn gem_merge_calibrate() {
        for kind in 0..4u32 {
            for band in [0u32, 30, 60, 90, 124] {
                let mut wins = 0;
                let mut st = [0; 4];
                let n = 4;
                let mut drops = 0;
                for k in 0..n {
                    let level = 1 + kind + 4 * (band + k).min(124);
                    let mut g = GemMerge::new(level, "level");
                    bot_play(&mut g, 600);
                    wins += (g.status == Status::Won) as u32;
                    st[g.stars() as usize] += 1;
                    drops += g.drops;
                }
                println!("kind {kind} tier {band:>3}: {:?} wins {wins}/{n} stars {st:?} avg drops {}", params(1 + kind + 4 * band).goal, drops / n);
            }
        }
    }

    /// Feel metrics (run with `--ignored --nocapture`): how far gems roll / slide and how long
    /// a board takes to fall asleep. Used to tune damping and friction.
    #[test]
    #[ignore]
    fn gem_merge_feel() {
        let ticks_to_sleep = |g: &mut GemMerge, max: u32| -> u32 {
            for i in 0..max {
                if g.gems.iter().all(|m| m.asleep) {
                    return i;
                }
                g.tick(16.0);
            }
            max
        };
        // A: tier-2 gem lands off-centre on a resting tier-4 gem and rolls off.
        let mut g = GemMerge::new(1, "endless");
        g.gems.push(Gem { asleep: true, age: GROW_MS, ..Gem::new(50.0, HEIGHT - RADII[3], 4) });
        g.gems.push(Gem { age: GROW_MS, ..Gem::new(50.0 + 0.3 * RADII[3], 40.0, 2) });
        let n = ticks_to_sleep(&mut g, 2000);
        println!("A roll-off: small gem ends {:.1} units from the big one, asleep after {n} ticks", (g.gems[1].x - 50.0).abs());
        // B: gem sliding along the floor at 30 u/s.
        let mut g = GemMerge::new(1, "endless");
        g.gems.push(Gem { vx: 30.0, age: GROW_MS, ..Gem::new(10.0, HEIGHT - RADII[2], 3) });
        let n = ticks_to_sleep(&mut g, 2000);
        println!("B push 30 u/s: travelled {:.1} units, asleep after {n} ticks", g.gems[0].x - 10.0);
        // F: distinct tiers (no merges) poured at the centre: how far does the pile spread?
        let mut g = GemMerge::new(1, "endless");
        for (i, t) in [5u8, 2, 7, 1, 4, 8, 3, 6].iter().enumerate() {
            g.cur = *t;
            g.cooldown = 0.0;
            g.act(&json!({"a": "drop", "x": 50.0 + (i % 2) as f64 * 0.5})).unwrap();
            for _ in 0..45 {
                g.tick(16.0);
            }
        }
        let n = ticks_to_sleep(&mut g, 3000);
        let top = g.gems.iter().map(|m| m.y - m.r()).fold(HEIGHT, f64::min);
        let spread = g.gems.iter().map(|m| (m.x - 50.0).abs()).sum::<f64>() / g.gems.len() as f64;
        println!("F pour: {} gems, top {top:.1}, mean |x-50| {spread:.1}, asleep after {n} more ticks", g.gems.len());
        // C: gem touching the side wall falls 80 units.
        let mut g = GemMerge::new(1, "endless");
        g.gems.push(Gem { vx: -5.0, age: GROW_MS, ..Gem::new(RADII[4], 40.0, 5) });
        let mut n = 0;
        while g.gems[0].y + g.gems[0].r() < HEIGHT - 0.5 && n < 500 {
            g.tick(16.0);
            n += 1;
        }
        println!("C wall slide: reached the floor after {n} ticks (free fall: ~{:.0})", (2.0 * (HEIGHT - 40.0 - RADII[4]) / GRAVITY).sqrt() * 1000.0 / 16.0);
        // D: two gems wedged between a wall and each other.
        let mut g = GemMerge::new(1, "endless");
        g.gems.push(Gem { age: GROW_MS, ..Gem::new(RADII[6], 60.0, 7) });
        g.gems.push(Gem { age: GROW_MS, ..Gem::new(2.0 * RADII[6] + RADII[5] - 0.2, 62.0, 6) });
        let n = ticks_to_sleep(&mut g, 2000);
        println!("D wedge: settled at y {:.1}/{:.1} (floor rest {:.1}/{:.1}) after {n} ticks", g.gems[0].y, g.gems[1].y, HEIGHT - RADII[6], HEIGHT - RADII[5]);
        // E: settle time of a messy board, plus stability over bot play.
        let mut g = GemMerge::new(1, "endless");
        for (i, t) in [1u8, 2, 3, 4, 5, 1, 2, 3].iter().enumerate() {
            g.gems.push(Gem::new(8.0 + i as f64 * 11.0, 60.0 - (i % 3) as f64 * 15.0, *t));
        }
        let n = ticks_to_sleep(&mut g, 2000);
        println!("E settle: 8 gems asleep after {n} ticks");
        let (mut pen, mut speed, mut awake, mut frames) = (0.0f64, 0.0f64, 0usize, 0usize);
        for level in [1u32, 2, 3, 4, 13, 50, 137] {
            let mut g = GemMerge::new(level, "level");
            let mut guard = 0;
            while g.status == Status::Playing && guard < 6000 {
                if g.cooldown <= 0.0 && guard % 40 == 0 {
                    let _ = g.act(&json!({"a": "drop", "x": aim(&g)}));
                }
                g.tick(16.0);
                guard += 1;
                frames += 1;
                awake += g.gems.iter().filter(|m| !m.asleep).count();
                for (i, a) in g.gems.iter().enumerate() {
                    speed = speed.max((a.vx * a.vx + a.vy * a.vy).sqrt());
                    // Overlap between grown gems only (a merge child grows into its neighbours).
                    for b in g.gems[i + 1..].iter().filter(|b| a.age > 400.0 && b.age > 400.0) {
                        let d = ((a.x - b.x).powi(2) + (a.y - b.y).powi(2)).sqrt();
                        pen = pen.max(a.r() + b.r() - d);
                    }
                }
            }
            println!("  level {level}: {:?} drops {} score {}", g.status, g.drops, g.score);
        }
        println!("E play: max overlap {pen:.2}, max speed {speed:.0}, awake gems per frame {:.2}", awake as f64 / frames as f64);
        // G: busy boards must fall fully asleep once the drops stop (no endless jitter).
        let mut worst = 0;
        for seed in 0..60u64 {
            let mut g = busy_board(seed, 36);
            let mut n = 0;
            while g.status == Status::Playing && !g.gems.iter().all(|m| m.asleep) && n < 1500 {
                g.tick(16.0);
                n += 1;
            }
            worst = worst.max(n);
        }
        println!("G settle: 60 boards after 36 drops, slowest all-asleep after {worst} ticks (1500 = never)");
    }

    #[test]
    #[ignore]
    fn gem_merge_timing() {
        let t = std::time::Instant::now();
        for level in 1..=500 {
            let g = GemMerge::new(level, "level");
            assert_eq!(g.status, Status::Playing);
        }
        println!("gem_merge: 500 levels generated in {:?}", t.elapsed());
        // Busy board: tick + state cost.
        let mut g = GemMerge::new(1, "endless");
        let mut tiers = 0u8;
        for i in 0..45 {
            tiers = tiers % 6 + 1;
            g.gems.push(Gem::new(6.0 + (i % 9) as f64 * 11.0, 130.0 - (i / 9) as f64 * 16.0, tiers));
        }
        let t = std::time::Instant::now();
        let mut bytes = 0;
        let mut worst = std::time::Duration::ZERO;
        for _ in 0..1000 {
            let s = std::time::Instant::now();
            g.tick(16.6);
            bytes += g.state().to_string().len();
            worst = worst.max(s.elapsed());
        }
        println!(
            "gem_merge: 1000 tick+state with {} gems in {:?} (worst {:?}), avg state {} bytes",
            g.gems.len(),
            t.elapsed(),
            worst,
            bytes / 1000
        );
    }
}
