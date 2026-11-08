//! Schulte Tablosu — visual search and peripheral attention. A grid of shuffled symbols; tap them
//! in order as fast as you can while keeping your gaze on the central fixation point.
//!
//! Orders (`Order`):
//! - `Asc`: numbers 1 → N.
//! - `Desc`: numbers N → 1.
//! - `Alpha`: Turkish letters A → Z without the easily confused Ğ and dotless I (27 letters, so
//!   only on 4×4 and 5×5 grids; bigger grids use `Desc` in that slot).
//! - `Gorbov` (Gorbov–Schulte, two colours): ⌈N/2⌉ light ("beyaz") numbers and ⌊N/2⌋ red numbers.
//!   Alternate: light ascending, red descending — light 1, red r, light 2, red r−1, … (r = red count).
//!
//! Level curve (`params(level)`), t = (level−1)/499:
//! - Grid: 1..=12 → 4×4 · 13..=130 → 5×5 · 131..=300 → 6×6 · 301..=500 → 7×7.
//! - Order slot = (level−1) % 5: Asc, Desc, Alpha (Desc on 6×6/7×7), Asc, Gorbov.
//! - Distractor styling (mixed font sizes ±12–32 %, rotations up to 6–24°; intensity 0.4 + 0.6·t):
//!   slot 3 from level 20, also slot 0 from level 100, every level from 220.
//! - Reshuffle after every correct tap: slot 3 from 160, every non-Gorbov level from 330, all from 450.
//! - Found symbols are dimmed only on levels 1..=60 (afterwards you track progress yourself).
//!
//! Time: the clock starts after a 3 s countdown (the grid is hidden until then). A wrong tap adds
//! a 2 s penalty to the clock and shakes the grid. Par time (3 stars):
//!   par = cells × (400 + 17·cells) ms × (1 − 0.22·t) × order factor × styling × reshuffle,
//!   order factor Asc 1.0 · Desc 1.1 · Alpha 1.2 · Gorbov 1.7; styling 1 + 0.12·intensity;
//!   reshuffle 1.45; rounded to 0.5 s (level 1, 4×4 numbers: 11 s; 5×5 numbers: ~20 s;
//!   7×7 numbers at 301: 57 s; 7×7 two-colour with reshuffle at 500: 130 s).
//! Stars: time (with penalties) ≤ par → 3 · ≤ 1.5 × par → 2 · finished → 1.
//! Limit (generous): max(3 × par, par + 30 s), rounded up to 5 s; running out → `lost`.
//!
//! State: `{status, stars, mode, phase: "intro"|"countdown"|"run"|"done", title, goal, summary?,
//!          size, total, order, cells: [{label, color, scale, rot, found}] | null (hidden before the
//!          run), next: {index, label, color} | null, found, errors, elapsed_ms, par_ms, limit_ms,
//!          remaining_ms, countdown_ms, penalty_ms, dim_found, shuffle, styled, layout_serial,
//!          last: {serial, cell, ok} | null}`
//! Actions: `{"start":true}` · `{"tap": cellIndex}` (row-major).

use crate::rng::{seed_for, Rng};
use crate::Session;
use serde_json::{json, Value};

pub const COUNTDOWN_MS: f64 = 3000.0;
pub const PENALTY_MS: f64 = 2000.0;
/// Turkish alphabet without Ğ and dotless I (easily confused at a glance).
pub const LETTERS: [&str; 27] = [
    "A", "B", "C", "Ç", "D", "E", "F", "G", "H", "İ", "J", "K", "L", "M", "N", "O", "Ö", "P", "R", "S", "Ş", "T",
    "U", "Ü", "V", "Y", "Z",
];

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Order {
    Asc,
    Desc,
    Alpha,
    Gorbov,
}

impl Order {
    fn key(self) -> &'static str {
        match self {
            Order::Asc => "asc",
            Order::Desc => "desc",
            Order::Alpha => "alpha",
            Order::Gorbov => "gorbov",
        }
    }
    fn label(self) -> &'static str {
        match self {
            Order::Asc => "Sayılar",
            Order::Desc => "Geriye",
            Order::Alpha => "Harfler",
            Order::Gorbov => "İki renk",
        }
    }
    fn factor(self) -> f64 {
        match self {
            Order::Asc => 1.0,
            Order::Desc => 1.1,
            Order::Alpha => 1.2,
            Order::Gorbov => 1.7,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Params {
    pub size: usize,
    pub order: Order,
    /// Distractor styling intensity: 0 = plain, otherwise 0.4..=1.
    pub styled: f64,
    pub shuffle: bool,
    pub dim_found: bool,
    pub par_ms: f64,
    pub limit_ms: f64,
}

pub fn params(level: u32) -> Params {
    let level = level.clamp(1, 500);
    let t = (level - 1) as f64 / 499.0;
    let size = match level {
        1..=12 => 4,
        13..=130 => 5,
        131..=300 => 6,
        _ => 7,
    };
    let cells = size * size;
    let slot = (level - 1) % 5;
    let order = match slot {
        0 | 3 => Order::Asc,
        1 => Order::Desc,
        2 => {
            if cells <= LETTERS.len() {
                Order::Alpha
            } else {
                Order::Desc
            }
        }
        _ => Order::Gorbov,
    };
    let styled_on = (level >= 20 && slot == 3) || (level >= 100 && slot == 0) || level >= 220;
    let styled = if styled_on { (0.4 + 0.6 * t).min(1.0) } else { 0.0 };
    let shuffle = (level >= 160 && slot == 3) || (level >= 330 && slot != 4) || level >= 450;
    let dim_found = level <= 60;
    let per_cell = 400.0 + 17.0 * cells as f64;
    let mut par = cells as f64 * per_cell * (1.0 - 0.22 * t) * order.factor();
    par *= 1.0 + 0.12 * styled;
    if shuffle {
        par *= 1.45;
    }
    let par_ms = (par / 500.0).round() * 500.0;
    let limit_ms = ((par_ms * 3.0).max(par_ms + 30_000.0) / 5000.0).ceil() * 5000.0;
    Params { size, order, styled, shuffle, dim_found, par_ms, limit_ms }
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Phase {
    Intro,
    Countdown,
    Run,
    Done,
}

#[derive(Clone, Debug, PartialEq)]
struct Symbol {
    label: String,
    color: u8, // 0 = light, 1 = red (Gorbov only)
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct Style {
    scale: f64,
    rot: f64,
}

pub struct Schulte {
    level: u32,
    p: Params,
    symbols: Vec<Symbol>,
    /// Symbol ids in the order they must be tapped.
    seq: Vec<usize>,
    /// Grid position → symbol id.
    layout: Vec<usize>,
    /// Symbol id → styling (re-rolled with every reshuffle).
    style: Vec<Style>,
    found: Vec<bool>,
    next: usize,
    phase: Phase,
    countdown_ms: f64,
    elapsed_ms: f64,
    errors: u32,
    last: Option<(u32, usize, bool)>,
    serial: u32,
    layout_serial: u32,
    rng: Rng,
    won: bool,
}

pub fn create(level: u32, _mode: &str) -> Result<Box<dyn Session>, String> {
    // Levels only: any other mode plays the level as well.
    Ok(Box::new(Schulte::new(level)))
}

fn build_symbols(order: Order, n: usize) -> (Vec<Symbol>, Vec<usize>) {
    match order {
        Order::Asc | Order::Desc => {
            let syms = (0..n).map(|i| Symbol { label: (i + 1).to_string(), color: 0 }).collect();
            let seq = if order == Order::Asc { (0..n).collect() } else { (0..n).rev().collect() };
            (syms, seq)
        }
        Order::Alpha => {
            let syms = (0..n).map(|i| Symbol { label: LETTERS[i].to_string(), color: 0 }).collect();
            (syms, (0..n).collect())
        }
        Order::Gorbov => {
            let light = n.div_ceil(2);
            let red = n / 2;
            let mut syms: Vec<Symbol> = (0..light).map(|i| Symbol { label: (i + 1).to_string(), color: 0 }).collect();
            syms.extend((0..red).map(|i| Symbol { label: (i + 1).to_string(), color: 1 }));
            let mut seq = Vec::with_capacity(n);
            for i in 0..light {
                seq.push(i);
                if i < red {
                    seq.push(light + red - 1 - i); // red r, r−1, …, 1
                }
            }
            (syms, seq)
        }
    }
}

impl Schulte {
    pub fn new(level: u32) -> Self {
        let p = params(level);
        let n = p.size * p.size;
        let (symbols, seq) = build_symbols(p.order, n);
        let mut gen = Rng::new(seed_for("schulte", level, 0));
        let mut layout: Vec<usize> = (0..n).collect();
        gen.shuffle(&mut layout);
        let style = Self::roll_style(&mut gen, n, p.styled);
        Schulte {
            level,
            p,
            symbols,
            seq,
            layout,
            style,
            found: vec![false; n],
            next: 0,
            phase: Phase::Intro,
            countdown_ms: COUNTDOWN_MS,
            elapsed_ms: 0.0,
            errors: 0,
            last: None,
            serial: 0,
            layout_serial: 0,
            rng: Rng::new(seed_for("schulte", level, 1)),
            won: false,
        }
    }

    fn roll_style(rng: &mut Rng, n: usize, intensity: f64) -> Vec<Style> {
        (0..n)
            .map(|_| {
                if intensity <= 0.0 {
                    Style { scale: 1.0, rot: 0.0 }
                } else {
                    let spread = 0.12 + 0.2 * intensity;
                    let max_rot = 6.0 + 18.0 * intensity;
                    let scale = 1.0 + (rng.f64() * 2.0 - 1.0) * spread;
                    let rot = (rng.f64() * 2.0 - 1.0) * max_rot;
                    Style { scale: (scale * 100.0).round() / 100.0, rot: rot.round() }
                }
            })
            .collect()
    }

    fn cells(&self) -> usize {
        self.layout.len()
    }

    fn stars(&self) -> u32 {
        if !self.won {
            0
        } else if self.elapsed_ms <= self.p.par_ms {
            3
        } else if self.elapsed_ms <= self.p.par_ms * 1.5 {
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

    fn reshuffle(&mut self) {
        self.rng.shuffle(&mut self.layout);
        self.style = Self::roll_style(&mut self.rng, self.layout.len(), self.p.styled);
        self.layout_serial += 1;
    }

    fn time_up(&mut self) {
        self.elapsed_ms = self.p.limit_ms;
        self.phase = Phase::Done;
        self.won = false;
    }

    fn summary(&self) -> String {
        let per = if self.next > 0 { self.elapsed_ms / self.next as f64 / 1000.0 } else { 0.0 };
        if self.won {
            format!(
                "Süre {} · Hata {} · Hedef {} · {} sn/sembol",
                clock(self.elapsed_ms),
                self.errors,
                clock(self.p.par_ms),
                dec(per, 2)
            )
        } else {
            format!("Süre doldu · Bulunan {}/{} · Hata {}", self.next, self.cells(), self.errors)
        }
    }

    fn order_text(&self) -> &'static str {
        match self.p.order {
            Order::Asc => "1'den büyüğe",
            Order::Desc => "büyükten 1'e",
            Order::Alpha => "A'dan Z'ye",
            Order::Gorbov => "beyaz artan, kırmızı azalan, sırayla",
        }
    }
}

/// `m:ss,t` (tenths), e.g. `0:23,4`.
fn clock(ms: f64) -> String {
    let tenths = (ms / 100.0).round().max(0.0) as u64;
    format!("{}:{:02},{}", tenths / 600, (tenths / 10) % 60, tenths % 10)
}

fn dec(x: f64, places: usize) -> String {
    format!("{x:.places$}").replace('.', ",")
}

impl Session for Schulte {
    fn state(&self) -> Value {
        let visible = matches!(self.phase, Phase::Run | Phase::Done);
        let cells = if visible {
            Some(
                self.layout
                    .iter()
                    .map(|&id| {
                        let s = &self.symbols[id];
                        let st = self.style[id];
                        json!({
                            "label": s.label, "color": s.color, "scale": st.scale, "rot": st.rot,
                            "found": self.found[id],
                        })
                    })
                    .collect::<Vec<_>>(),
            )
        } else {
            None
        };
        let next = self.seq.get(self.next).filter(|_| self.phase != Phase::Done).map(|&id| {
            json!({"index": self.next, "label": self.symbols[id].label, "color": self.symbols[id].color})
        });
        let size = self.p.size;
        let mut title = format!("{size}×{size} · {}", self.p.order.label());
        if self.p.shuffle {
            title.push_str(" · karışan");
        }
        json!({
            "status": self.status(),
            "stars": self.stars(),
            "mode": "level",
            "level": self.level,
            "phase": match self.phase {
                Phase::Intro => "intro", Phase::Countdown => "countdown", Phase::Run => "run", Phase::Done => "done",
            },
            "title": title,
            "goal": format!("{} sembolü {} bul · ★★★ {} altı", self.cells(), self.order_text(), clock(self.p.par_ms)),
            "summary": if self.phase == Phase::Done { Some(self.summary()) } else { None },
            "size": size,
            "total": self.cells(),
            "order": self.p.order.key(),
            "cells": cells,
            "next": next,
            "found": self.next,
            "errors": self.errors,
            "elapsed_ms": self.elapsed_ms.round(),
            "par_ms": self.p.par_ms,
            "limit_ms": self.p.limit_ms,
            "remaining_ms": (self.p.limit_ms - self.elapsed_ms).max(0.0).round(),
            "countdown_ms": self.countdown_ms.max(0.0).round(),
            "penalty_ms": PENALTY_MS,
            "dim_found": self.p.dim_found,
            "shuffle": self.p.shuffle,
            "styled": self.p.styled > 0.0,
            "layout_serial": self.layout_serial,
            "last": self.last.map(|(serial, cell, ok)| json!({"serial": serial, "cell": cell, "ok": ok})),
        })
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if self.phase == Phase::Done {
            return Err("Bölüm bitti".into());
        }
        if a["start"].as_bool() == Some(true) {
            if self.phase != Phase::Intro {
                return Err("Oyun zaten başladı".into());
            }
            self.phase = Phase::Countdown;
            self.countdown_ms = COUNTDOWN_MS;
            return Ok(());
        }
        let Some(cell) = a["tap"].as_u64() else {
            return Err("Bilinmeyen hamle".into());
        };
        match self.phase {
            Phase::Intro => return Err("Önce Başla'ya dokun".into()),
            Phase::Countdown => return Err("Geri sayımı bekle".into()),
            _ => {}
        }
        let cell = cell as usize;
        if cell >= self.cells() {
            return Err("Geçersiz hücre".into());
        }
        let id = self.layout[cell];
        let ok = id == self.seq[self.next];
        self.serial += 1;
        self.last = Some((self.serial, cell, ok));
        if ok {
            self.found[id] = true;
            self.next += 1;
            if self.next == self.cells() {
                self.phase = Phase::Done;
                self.won = true;
            } else if self.p.shuffle {
                self.reshuffle();
            }
        } else {
            self.errors += 1;
            self.elapsed_ms += PENALTY_MS;
            if self.elapsed_ms >= self.p.limit_ms {
                self.time_up();
            }
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
                if self.elapsed_ms >= self.p.limit_ms {
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

    const LEVELS: [u32; 9] = [1, 2, 3, 50, 137, 250, 400, 499, 500];

    fn started(level: u32) -> Schulte {
        let mut g = Schulte::new(level);
        g.act(&json!({"start": true})).unwrap();
        g.tick(COUNTDOWN_MS + 1.0);
        assert_eq!(g.phase, Phase::Run);
        g
    }

    /// Grid position of the symbol that must be tapped next.
    fn target(g: &Schulte) -> usize {
        let id = g.seq[g.next];
        g.layout.iter().position(|&x| x == id).unwrap()
    }

    fn wrong_cell(g: &Schulte) -> usize {
        (target(g) + 1) % g.cells()
    }

    #[test]
    fn params_cover_every_level_sanely() {
        let mut prev_size = 4;
        for level in 1..=500 {
            let p = params(level);
            assert!((4..=7).contains(&p.size));
            assert!(p.size >= prev_size, "grid never shrinks");
            prev_size = p.size;
            if p.order == Order::Alpha {
                assert!(p.size * p.size <= LETTERS.len());
            }
            assert!(p.par_ms >= 5000.0 && p.par_ms < p.limit_ms);
            assert!(p.limit_ms >= p.par_ms * 3.0 - 1e-9);
            assert_eq!(p.limit_ms % 5000.0, 0.0);
            assert!((0.0..=1.0).contains(&p.styled));
        }
        assert_eq!(params(1).size, 4);
        assert_eq!(params(1).order, Order::Asc);
        assert_eq!(params(1).par_ms, 11_000.0);
        assert_eq!(params(2).order, Order::Desc);
        assert_eq!(params(3).order, Order::Alpha);
        assert_eq!(params(5).order, Order::Gorbov);
        assert_eq!(params(500).size, 7);
        assert!(params(500).shuffle && params(500).styled > 0.99);
        assert!(!params(1).shuffle && params(1).styled == 0.0 && params(1).dim_found);
        assert!(!params(61).dim_found);
        // Every variant shows up on every grid size it can.
        for size in [5, 6, 7] {
            let lv: Vec<_> = (1..=500).map(params).filter(|p| p.size == size).collect();
            assert!(lv.iter().any(|p| p.order == Order::Gorbov));
            assert!(lv.iter().any(|p| p.order == Order::Desc));
            assert!(lv.iter().any(|p| p.styled > 0.0));
        }
        assert!((1..=500).map(params).any(|p| p.shuffle && p.size == 6));
    }

    #[test]
    fn levels_generate_and_are_deterministic() {
        for level in LEVELS {
            let a = Schulte::new(level);
            let b = Schulte::new(level);
            assert_eq!(a.layout, b.layout);
            assert_eq!(a.style, b.style);
            assert_eq!(a.seq, b.seq);
            let n = a.cells();
            // The order is a permutation of all symbols; labels are unique per colour.
            let mut s = a.seq.clone();
            s.sort();
            assert_eq!(s, (0..n).collect::<Vec<_>>());
            let mut labels: Vec<_> = a.symbols.iter().map(|x| (x.label.clone(), x.color)).collect();
            labels.sort();
            labels.dedup();
            assert_eq!(labels.len(), n);
            let st = a.state();
            assert_eq!(st["status"], "playing");
            assert!(st["cells"].is_null(), "grid hidden before the run");
        }
        assert_ne!(Schulte::new(1).layout, Schulte::new(4).layout);
    }

    #[test]
    fn gorbov_order_alternates() {
        let (syms, seq) = build_symbols(Order::Gorbov, 25);
        let labels: Vec<_> = seq.iter().take(6).map(|&i| (syms[i].label.as_str(), syms[i].color)).collect();
        assert_eq!(labels, vec![("1", 0), ("12", 1), ("2", 0), ("11", 1), ("3", 0), ("10", 1)]);
        let last = &syms[*seq.last().unwrap()];
        assert_eq!((last.label.as_str(), last.color), ("13", 0));
        let (syms, seq) = build_symbols(Order::Gorbov, 16);
        let last = &syms[*seq.last().unwrap()];
        assert_eq!((last.label.as_str(), last.color), ("1", 1));
        let (syms, seq) = build_symbols(Order::Alpha, 25);
        assert_eq!(syms[seq[0]].label, "A");
        assert_eq!(syms[seq[24]].label, "V");
    }

    #[test]
    fn perfect_fast_run_wins_three_stars() {
        for level in LEVELS {
            let mut g = started(level);
            let n = g.cells();
            for _ in 0..n {
                g.tick(100.0);
                let c = target(&g);
                g.act(&json!({"tap": c})).unwrap();
            }
            let st = g.state();
            assert_eq!(st["status"], "won", "level {level}");
            assert_eq!(st["stars"], 3);
            assert_eq!(st["found"], n);
            assert!(st["summary"].as_str().unwrap().starts_with("Süre"));
            assert!(g.act(&json!({"tap": 0})).is_err());
        }
    }

    #[test]
    fn reshuffle_changes_layout_after_correct_tap() {
        let mut g = started(500);
        assert!(g.p.shuffle);
        let before = g.layout.clone();
        let c = target(&g);
        g.act(&json!({"tap": c})).unwrap();
        assert_ne!(g.layout, before);
        assert_eq!(g.layout_serial, 1);
        // A wrong tap never reshuffles.
        let before = g.layout.clone();
        let w = wrong_cell(&g);
        g.act(&json!({"tap": w})).unwrap();
        assert_eq!(g.layout, before);
        // Same taps → same layouts (deterministic).
        let mut a = started(500);
        let mut b = started(500);
        for _ in 0..5 {
            let c = target(&a);
            a.act(&json!({"tap": c})).unwrap();
            b.act(&json!({"tap": c})).unwrap();
            assert_eq!(a.layout, b.layout);
        }
    }

    #[test]
    fn wrong_tap_costs_penalty_and_stars() {
        let mut g = started(1);
        let w = wrong_cell(&g);
        g.act(&json!({"tap": w})).unwrap();
        let st = g.state();
        assert_eq!(st["errors"], 1);
        assert_eq!(st["elapsed_ms"], PENALTY_MS);
        assert_eq!(st["last"]["ok"], false);
        assert_eq!(st["found"], 0);
        // Tapping an already found symbol is also an error.
        let c = target(&g);
        g.act(&json!({"tap": c})).unwrap();
        g.act(&json!({"tap": c})).unwrap();
        assert_eq!(g.errors, 2);
        // Finish slowly: 2 stars between par and 1.5 × par, 1 star above.
        let mut g = started(1);
        g.tick(g.p.par_ms + 500.0);
        while g.phase == Phase::Run {
            let c = target(&g);
            g.act(&json!({"tap": c})).unwrap();
        }
        assert_eq!(g.stars(), 2);
        let mut g = started(1);
        g.tick(g.p.par_ms * 1.5 + 500.0);
        while g.phase == Phase::Run {
            let c = target(&g);
            g.act(&json!({"tap": c})).unwrap();
        }
        assert_eq!(g.stars(), 1);
        assert_eq!(g.state()["status"], "won");
    }

    #[test]
    fn running_out_of_time_loses() {
        let mut g = started(2);
        let limit = g.p.limit_ms;
        let mut guard = 0;
        while g.phase == Phase::Run {
            g.tick(250.0);
            guard += 1;
            assert!(guard < 10_000);
        }
        let st = g.state();
        assert_eq!(st["status"], "lost");
        assert_eq!(st["elapsed_ms"], limit);
        assert!(st["summary"].as_str().unwrap().starts_with("Süre doldu"));
        // Penalties alone can also run the clock out.
        let mut g = started(1);
        while g.phase == Phase::Run {
            let w = wrong_cell(&g);
            g.act(&json!({"tap": w})).unwrap();
        }
        assert_eq!(g.state()["status"], "lost");
    }

    #[test]
    fn illegal_actions_rejected_and_state_unchanged() {
        let mut g = Schulte::new(1);
        let before = g.state();
        assert!(g.act(&json!({"tap": 0})).is_err()); // not started
        assert!(g.act(&json!({"foo": 1})).is_err());
        assert_eq!(g.state(), before);
        g.act(&json!({"start": true})).unwrap();
        let before = g.state();
        assert!(g.act(&json!({"tap": 0})).is_err()); // countdown
        assert!(g.act(&json!({"start": true})).is_err());
        assert_eq!(g.state(), before);
        g.tick(COUNTDOWN_MS);
        let before = g.state();
        assert!(g.act(&json!({"tap": 16})).is_err());
        assert!(g.act(&json!({"tap": "x"})).is_err());
        assert_eq!(g.state(), before);
        // The clock only runs during the run.
        let mut g = Schulte::new(1);
        g.tick(5000.0);
        assert_eq!(g.elapsed_ms, 0.0);
    }

    #[test]
    fn clock_format() {
        assert_eq!(clock(23_449.0), "0:23,4");
        assert_eq!(clock(83_000.0), "1:23,0");
        assert_eq!(dec(0.9449, 2), "0,94");
    }

    #[test]
    #[ignore]
    fn timing_500_levels() {
        let t = std::time::Instant::now();
        let mut worst = 0.0f64;
        for level in 1..=500 {
            let s = std::time::Instant::now();
            let g = Schulte::new(level);
            assert!(g.cells() >= 16);
            worst = worst.max(s.elapsed().as_secs_f64());
        }
        println!("schulte: 500 levels in {:?}, worst {:.3} ms", t.elapsed(), worst * 1000.0);
        for level in [1, 2, 13, 14, 15, 17, 131, 135, 160, 301, 305, 330, 450, 500] {
            let p = params(level);
            println!("L{level}: {}×{} {:?} styled {:.2} shuffle {} par {} limit {}", p.size, p.size, p.order, p.styled,
                p.shuffle, p.par_ms / 1000.0, p.limit_ms / 1000.0);
        }
    }
}
