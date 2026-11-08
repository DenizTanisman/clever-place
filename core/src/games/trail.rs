//! İz Sürme — Trail Making style visual search + cognitive flexibility (Reitan 1958; Colour Trails,
//! D'Elia et al. 1996).
//!
//! Labelled circles are scattered over the board; tap them in order. The view does the geometry
//! (which circle was tapped) and sends `{"tap": i}` (`{"touch": i}` is accepted as an alias); the
//! core decides:
//! - the next circle of the sequence → it joins the path and the view draws the line to it;
//! - a circle already on the path (including the last one) → nothing, a harmless double tap;
//! - any other circle → an error (red flash). Every wrong tap counts.
//!
//! Variants:
//! - `a`      1 → N.
//! - `a_rev`  N → 1.
//! - `b`      1-A-2-B-3-C… (Turkish alphabet: A B C Ç D E F G Ğ H I İ J K L …).
//! - `b_rev`  the B sequence backwards, from its last label down to 1.
//! - `color`  Colour Trails: every number 1..M appears twice, in gold and in ruby. Go 1 → M and
//!   alternate colours (the start colour is given); the other-coloured twins are lures.
//!
//! Distractors (`a`/`a_rev`/`b` levels): extra circles that continue the sequence beyond its end
//! (e.g. 15, 16 after 1…14), so the start/end of the run must be read, not guessed. Labels can be
//! rotated by up to `rot_deg` (letters and digits stay upright-ish, ±10…±37°).
//!
//! Layout: best-candidate sampling in a 1 × `ASPECT` board (x right, y down, unit = board width).
//! Radius r = min(0.075, 0.27 / √n); centres keep ≥ 2.75 r apart (a gap of 0.75 r for the finger to
//! pass between circles) and ≥ 1.15 r from every edge. Bounded retries, then the radius shrinks 5%.
//!
//! Time: Başla → 3 s countdown → the clock runs. Par = (per-circle time × sequence length + 1.5 s)
//! × (1 + 2% per distractor) × (1 − 0.15 t); per-circle times: A 0.9 s, A ters 1.0 s, B 1.7 s,
//! B ters 2.0 s, colour 1.5 s. Time limit = 3 × par (→ `lost`).
//! Stars: time ≤ par and no errors → 3; time ≤ 1.5 × par and ≤ 2 errors → 2; finished → 1.
//!
//! Level curve (`params(level)`):
//! - 1..=10 hand-made: A14, B12, A18, B14, colour 8×2, B16 + 2 lures, A-rev 18, B-rev 14,
//!   B18 (rotated ±10°), colour 10×2.
//! - 11..=500: 5-level cycle with t = (level − 11) / 489 and n = 16 + round(14 t) (16 → 30):
//!   A (A-rev on odd cycles) with n circles + round(4 t) lures, B with n − 2, colour with n/2 × 2,
//!   B-rev with n − 2, B with n − 4 + (2 + round(4 t)) lures. Rotation from level 40 on every
//!   other cycle, always from t ≥ 0.6, max angle 10° → 37°. Total circles never exceed 34.
//!
//! State: `{status, stars, phase: "intro"|"countdown"|"run"|"done", title, goal, summary?, variant,
//!          aspect, radius, circles: [{x, y, label, color, rot}], seq_len, done, path: [i], next: i|null,
//!          errors, err_serial, last_wrong: i|null, ok_serial, elapsed_ms, par_ms, limit_ms,
//!          countdown_ms, start_label, start_color}`
//! Actions: `{"start":true}` · `{"tap": i}` (alias `{"touch": i}`)

use crate::rng::{seed_for, Rng};
use crate::Session;
use serde_json::{json, Value};

pub const ALPHABET: [&str; 29] = [
    "A", "B", "C", "Ç", "D", "E", "F", "G", "Ğ", "H", "I", "İ", "J", "K", "L", "M", "N", "O", "Ö", "P", "R", "S",
    "Ş", "T", "U", "Ü", "V", "Y", "Z",
];
/// Board height / width.
pub const ASPECT: f64 = 1.45;
pub const COUNTDOWN_MS: f64 = 3000.0;
/// Minimum centre distance in radii (2 r + a 0.75 r gap).
pub const MIN_DIST_R: f64 = 2.75;
/// Minimum distance from a centre to the board edge in radii.
pub const MARGIN_R: f64 = 1.15;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Variant {
    A,
    ARev,
    B,
    BRev,
    Color,
}

impl Variant {
    fn key(self) -> &'static str {
        match self {
            Variant::A => "a",
            Variant::ARev => "a_rev",
            Variant::B => "b",
            Variant::BRev => "b_rev",
            Variant::Color => "color",
        }
    }
    fn per_circle_ms(self) -> f64 {
        match self {
            Variant::A => 900.0,
            Variant::ARev => 1000.0,
            Variant::B => 1700.0,
            Variant::BRev => 2000.0,
            Variant::Color => 1500.0,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Params {
    pub variant: Variant,
    /// Sequence length (colour: how many numbers; each appears twice).
    pub seq: usize,
    pub distractors: usize,
    pub rot_deg: f64,
    pub par_ms: f64,
}

impl Params {
    pub fn total(&self) -> usize {
        if self.variant == Variant::Color {
            self.seq * 2
        } else {
            self.seq + self.distractors
        }
    }
}

fn mk(variant: Variant, seq: usize, distractors: usize, rot_deg: f64, t: f64) -> Params {
    let base = variant.per_circle_ms() * seq as f64 + 1500.0;
    let par = base * (1.0 + 0.02 * distractors as f64) * (1.0 - 0.15 * t);
    Params { variant, seq, distractors, rot_deg, par_ms: (par / 100.0).round() * 100.0 }
}

/// Level → parameters. See the module docs for the curve.
pub fn params(level: u32) -> Params {
    use Variant::*;
    let level = level.clamp(1, crate::MAX_LEVEL);
    match level {
        1 => mk(A, 14, 0, 0.0, 0.0),
        2 => mk(B, 12, 0, 0.0, 0.0),
        3 => mk(A, 18, 0, 0.0, 0.0),
        4 => mk(B, 14, 0, 0.0, 0.0),
        5 => mk(Color, 8, 0, 0.0, 0.0),
        6 => mk(B, 16, 2, 0.0, 0.0),
        7 => mk(ARev, 18, 0, 0.0, 0.0),
        8 => mk(BRev, 14, 0, 0.0, 0.0),
        9 => mk(B, 18, 0, 10.0, 0.0),
        10 => mk(Color, 10, 0, 0.0, 0.0),
        _ => {
            let i = level - 11;
            let t = i as f64 / 489.0;
            let cycle = i / 5;
            let n = 16 + (14.0 * t).round() as usize;
            let rot = if (level >= 40 && cycle % 2 == 1) || t >= 0.6 { (10.0 + 27.0 * t).round() } else { 0.0 };
            match i % 5 {
                0 => mk(if cycle % 2 == 1 { ARev } else { A }, n, (4.0 * t).round() as usize, rot, t),
                1 => mk(B, n - 2, 0, rot, t),
                2 => mk(Color, n / 2, 0, rot, t),
                3 => mk(BRev, n - 2, 0, rot, t),
                _ => mk(B, n - 4, 2 + (4.0 * t).round() as usize, rot, t),
            }
        }
    }
}

fn label_b(k: usize) -> String {
    if k % 2 == 0 {
        (k / 2 + 1).to_string()
    } else {
        ALPHABET[(k / 2).min(ALPHABET.len() - 1)].to_string()
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Circle {
    pub x: f64,
    pub y: f64,
    pub label: String,
    /// 0 = gold, 1 = ruby (colour variant only; otherwise 0).
    pub color: u8,
    pub rot: f64,
}

pub fn radius_for(n: usize) -> f64 {
    (0.27 / (n as f64).sqrt()).min(0.075)
}

/// Well-spread centres for `n` circles: best-candidate sampling with bounded retries.
pub fn layout(r: &mut Rng, n: usize) -> (Vec<(f64, f64)>, f64) {
    let mut rad = radius_for(n);
    loop {
        for _attempt in 0..25 {
            if let Some(pts) = try_layout(r, n, rad) {
                return (pts, rad);
            }
        }
        rad *= 0.95;
    }
}

fn try_layout(r: &mut Rng, n: usize, rad: f64) -> Option<Vec<(f64, f64)>> {
    let m = MARGIN_R * rad;
    let min_d2 = (MIN_DIST_R * rad).powi(2);
    let mut pts: Vec<(f64, f64)> = Vec::with_capacity(n);
    let sample = |r: &mut Rng| (m + r.f64() * (1.0 - 2.0 * m), m + r.f64() * (ASPECT - 2.0 * m));
    let nearest = |pts: &[(f64, f64)], p: (f64, f64)| {
        pts.iter().map(|q| (q.0 - p.0).powi(2) + (q.1 - p.1).powi(2)).fold(f64::INFINITY, f64::min)
    };
    for _ in 0..n {
        let mut best: Option<((f64, f64), f64)> = None;
        let mut valid = 0;
        for _ in 0..400 {
            let c = sample(r);
            let d = nearest(&pts, c);
            if d < min_d2 {
                continue;
            }
            valid += 1;
            if best.map_or(true, |b| d > b.1) {
                best = Some((c, d));
            }
            if valid >= 12 {
                break;
            }
        }
        pts.push(best?.0);
    }
    Some(pts)
}

/// Builds circles and the target sequence (circle indices in order).
pub fn generate(level: u32, p: &Params) -> (Vec<Circle>, Vec<usize>, f64, u8) {
    let mut r = Rng::new(seed_for("trail", level, 0));
    let total = p.total();
    let (pts, rad) = layout(&mut r, total);
    // Labels in sequence order, then distractors; positions are shuffled over them.
    let mut items: Vec<(String, u8)> = Vec::with_capacity(total);
    let start_color = if p.variant == Variant::Color { r.below(2) as u8 } else { 0 };
    match p.variant {
        Variant::A => {
            items.extend((1..=p.seq + p.distractors).map(|k| (k.to_string(), 0)));
        }
        Variant::ARev => {
            items.extend((1..=p.seq).rev().map(|k| (k.to_string(), 0)));
            items.extend((p.seq + 1..=p.seq + p.distractors).map(|k| (k.to_string(), 0)));
        }
        Variant::B => {
            items.extend((0..p.seq + p.distractors).map(|k| (label_b(k), 0)));
        }
        Variant::BRev => {
            items.extend((0..p.seq).rev().map(|k| (label_b(k), 0)));
            items.extend((p.seq..p.seq + p.distractors).map(|k| (label_b(k), 0)));
        }
        Variant::Color => {
            items.extend((0..p.seq).map(|k| ((k + 1).to_string(), (start_color + k as u8) % 2)));
            items.extend((0..p.seq).map(|k| ((k + 1).to_string(), (start_color + k as u8 + 1) % 2)));
        }
    }
    let mut slots: Vec<usize> = (0..total).collect();
    r.shuffle(&mut slots);
    // circle index for item k = slots[k]
    let mut circles: Vec<Circle> = vec![Circle { x: 0.0, y: 0.0, label: String::new(), color: 0, rot: 0.0 }; total];
    for (k, (label, color)) in items.into_iter().enumerate() {
        let (x, y) = pts[slots[k]];
        let rot = if p.rot_deg > 0.0 { (r.f64() * 2.0 - 1.0) * p.rot_deg } else { 0.0 };
        circles[slots[k]] = Circle { x, y, label, color, rot: (rot * 10.0).round() / 10.0 };
    }
    let seq = slots[..p.seq].to_vec();
    (circles, seq, rad, start_color)
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Phase {
    Intro,
    Countdown,
    Run,
    Done,
}

pub struct Trail {
    p: Params,
    circles: Vec<Circle>,
    seq: Vec<usize>,
    radius: f64,
    start_color: u8,
    phase: Phase,
    countdown_ms: f64,
    elapsed_ms: f64,
    limit_ms: f64,
    done: usize,
    errors: u32,
    last_wrong: Option<usize>,
    err_serial: u32,
    ok_serial: u32,
    stars: u32,
    won: bool,
}

pub fn create(level: u32, _mode: &str) -> Result<Box<dyn Session>, String> {
    Ok(Box::new(Trail::level(level)))
}

pub fn stars_for(elapsed: f64, par: f64, errors: u32) -> u32 {
    if elapsed <= par && errors == 0 {
        3
    } else if elapsed <= par * 1.5 && errors <= 2 {
        2
    } else {
        1
    }
}

fn secs(ms: f64) -> String {
    format!("{:.1}", ms / 1000.0).replace('.', ",")
}

/// How a label is read aloud (last word only), for Turkish suffix harmony.
fn spoken(label: &str) -> &'static str {
    if let Ok(n) = label.parse::<u32>() {
        const ONES: [&str; 10] = ["sıfır", "bir", "iki", "üç", "dört", "beş", "altı", "yedi", "sekiz", "dokuz"];
        const TENS: [&str; 10] = ["", "on", "yirmi", "otuz", "kırk", "elli", "altmış", "yetmiş", "seksen", "doksan"];
        return if n % 10 != 0 || n == 0 { ONES[(n % 10) as usize] } else { TENS[((n / 10) % 10) as usize] };
    }
    match label {
        "A" => "a",
        "I" => "ı",
        "O" => "o",
        "U" => "u",
        "Ö" => "ö",
        "Ü" => "ü",
        "E" => "e",
        "İ" => "i",
        _ => "be", // consonant letters are read with a final "e" (be, ce, çe…)
    }
}

fn back_vowel(word: &str) -> bool {
    word.chars().rev().find(|c| "aeıioöuü".contains(*c)).map_or(false, |c| "aıou".contains(c))
}

/// Dative suffix: 1'e, 2'ye, 6'ya, 10'a, A'ya, B'ye.
pub fn dat(label: &str) -> String {
    let w = spoken(label);
    let a = if back_vowel(w) { "a" } else { "e" };
    let y = if w.chars().last().map_or(false, |c| "aeıioöuü".contains(c)) { "y" } else { "" };
    format!("'{y}{a}")
}

/// Ablative suffix: 1'den, 3'ten, 6'dan, 4'ten, A'dan, B'den.
pub fn abl(label: &str) -> String {
    let w = spoken(label);
    let a = if back_vowel(w) { "a" } else { "e" };
    let d = if w.chars().last().map_or(false, |c| "çfhkpsşt".contains(c)) { "t" } else { "d" };
    format!("'{d}{a}n")
}

impl Trail {
    pub fn level(level: u32) -> Self {
        let p = params(level);
        let (circles, seq, radius, start_color) = generate(level, &p);
        let limit_ms = p.par_ms * 3.0;
        Trail {
            p,
            circles,
            seq,
            radius,
            start_color,
            phase: Phase::Intro,
            countdown_ms: COUNTDOWN_MS,
            elapsed_ms: 0.0,
            limit_ms,
            done: 0,
            errors: 0,
            last_wrong: None,
            err_serial: 0,
            ok_serial: 0,
            stars: 0,
            won: false,
        }
    }

    fn next(&self) -> Option<usize> {
        self.seq.get(self.done).copied()
    }

    fn label_of(&self, k: usize) -> &str {
        &self.circles[self.seq[k]].label
    }

    fn title(&self) -> String {
        let base = match self.p.variant {
            Variant::A => "İz A",
            Variant::ARev => "İz A · ters",
            Variant::B => "İz B",
            Variant::BRev => "İz B · ters",
            Variant::Color => "Renkli iz",
        };
        if self.p.distractors > 0 {
            format!("{base} · tuzaklı")
        } else {
            base.to_string()
        }
    }

    fn goal(&self) -> String {
        let first = self.label_of(0);
        let last = self.label_of(self.seq.len() - 1);
        let g = match self.p.variant {
            Variant::A => format!("{first}{} {last}{} sırayla bağla", abl(first), dat(last)),
            Variant::ARev => format!("Geriye say: {first}{} {last}{} bağla", abl(first), dat(last)),
            Variant::B => format!("Sayı-harf sırayla: 1-A-2-B… {last}{} kadar", dat(last)),
            Variant::BRev => format!("Geriye: {first}-{}-{}… 1'e kadar", self.label_of(1), self.label_of(2)),
            Variant::Color => format!(
                "1'den {last}{}, renk değiştirerek · {} 1 ile başla",
                dat(last),
                if self.start_color == 0 { "altın" } else { "yakut" }
            ),
        };
        let lures = if self.p.distractors > 0 { " · tuzak daireler var" } else { "" };
        format!("{g}{lures} · hedef {} sn", secs(self.p.par_ms))
    }

    fn status(&self) -> &'static str {
        match self.phase {
            Phase::Done if self.won => "won",
            Phase::Done => "lost",
            _ => "playing",
        }
    }

    fn summary(&self) -> String {
        if self.won {
            format!("Süre {} sn (hedef {}) · Hata {}", secs(self.elapsed_ms), secs(self.p.par_ms), self.errors)
        } else {
            format!("Süre doldu · {}/{} daire · Hata {}", self.done, self.seq.len(), self.errors)
        }
    }
}

impl Session for Trail {
    fn state(&self) -> Value {
        let circles: Vec<Value> = self
            .circles
            .iter()
            .map(|c| {
                json!({
                    "x": (c.x * 10000.0).round() / 10000.0, "y": (c.y * 10000.0).round() / 10000.0,
                    "label": c.label, "color": c.color, "rot": c.rot,
                })
            })
            .collect();
        let done = self.phase == Phase::Done;
        json!({
            "status": self.status(),
            "stars": self.stars,
            "phase": match self.phase {
                Phase::Intro => "intro", Phase::Countdown => "countdown", Phase::Run => "run", Phase::Done => "done",
            },
            "title": self.title(),
            "goal": self.goal(),
            "summary": done.then(|| self.summary()),
            "variant": self.p.variant.key(),
            "aspect": ASPECT,
            "radius": (self.radius * 10000.0).round() / 10000.0,
            "circles": circles,
            "seq_len": self.seq.len(),
            "done": self.done,
            "path": &self.seq[..self.done],
            "next": if done { None } else { self.next() },
            "errors": self.errors,
            "err_serial": self.err_serial,
            "last_wrong": self.last_wrong,
            "ok_serial": self.ok_serial,
            "elapsed_ms": self.elapsed_ms.round(),
            "par_ms": self.p.par_ms,
            "limit_ms": self.limit_ms,
            "countdown_ms": self.countdown_ms.max(0.0).round(),
            "start_label": self.label_of(0),
            "start_color": self.start_color,
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
            return Ok(());
        }
        let Some(i) = a["tap"].as_u64().or_else(|| a["touch"].as_u64()) else {
            return Err("Bilinmeyen hamle".into());
        };
        let i = i as usize;
        if i >= self.circles.len() {
            return Err("Böyle bir daire yok".into());
        }
        if self.phase != Phase::Run {
            return Err("Henüz başlamadı".into());
        }
        if self.seq[..self.done].contains(&i) {
            return Ok(()); // on the path already: a harmless double tap
        }
        if Some(i) == self.next() {
            self.done += 1;
            self.ok_serial += 1;
            self.last_wrong = None;
            if self.done == self.seq.len() {
                self.phase = Phase::Done;
                self.won = true;
                self.stars = stars_for(self.elapsed_ms, self.p.par_ms, self.errors);
            }
            return Ok(());
        }
        self.errors += 1;
        self.err_serial += 1;
        self.last_wrong = Some(i);
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
                    self.elapsed_ms = -self.countdown_ms;
                    self.countdown_ms = 0.0;
                }
            }
            Phase::Run => {
                self.elapsed_ms += dt_ms;
                if self.elapsed_ms >= self.limit_ms {
                    self.elapsed_ms = self.limit_ms;
                    self.phase = Phase::Done;
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

    fn check_layout(g: &Trail) {
        let r = g.radius;
        assert!(r > 0.03, "radius {r}");
        let m = MARGIN_R * r - 1e-6;
        for c in &g.circles {
            assert!(c.x >= m && c.x <= 1.0 - m, "x {}", c.x);
            assert!(c.y >= m && c.y <= ASPECT - m, "y {}", c.y);
            assert!(c.rot.abs() <= g.p.rot_deg + 1e-9);
        }
        for i in 0..g.circles.len() {
            for j in i + 1..g.circles.len() {
                let (a, b) = (&g.circles[i], &g.circles[j]);
                let d = ((a.x - b.x).powi(2) + (a.y - b.y).powi(2)).sqrt();
                assert!(d >= MIN_DIST_R * r - 1e-9, "circles {i},{j} too close: {d} < {}", MIN_DIST_R * r);
            }
        }
        // Labels unique (colour: unique by label + colour).
        let mut keys: Vec<(String, u8)> = g.circles.iter().map(|c| (c.label.clone(), c.color)).collect();
        keys.sort();
        keys.dedup();
        assert_eq!(keys.len(), g.circles.len());
    }

    #[test]
    fn params_cover_levels() {
        for level in LEVELS.iter().copied().chain(1..=20) {
            let p = params(level);
            assert!(p.total() >= 12 && p.total() <= 34, "level {level}: {}", p.total());
            assert!(p.par_ms > 5000.0);
        }
        let totals: Vec<usize> = (1..=500).map(|l| params(l).total()).collect();
        assert_eq!(*totals.iter().min().unwrap(), 12);
        assert!(*totals.iter().max().unwrap() >= 30);
        assert!((1..=500).all(|l| params(l).total() <= 34));
        assert!((11..=500).any(|l| params(l).variant == Variant::BRev && params(l).rot_deg > 30.0));
    }

    #[test]
    fn layouts_inside_and_non_overlapping() {
        for level in LEVELS.iter().copied().chain(1..=30) {
            check_layout(&Trail::level(level));
        }
    }

    #[test]
    fn sequences_follow_variant_rules() {
        for level in 1..=15 {
            let g = Trail::level(level);
            let labels: Vec<&str> = g.seq.iter().map(|&i| g.circles[i].label.as_str()).collect();
            match g.p.variant {
                Variant::A => assert_eq!(labels[..3], ["1", "2", "3"]),
                Variant::ARev => {
                    assert_eq!(labels[0], g.p.seq.to_string());
                    assert_eq!(*labels.last().unwrap(), "1");
                }
                Variant::B => assert_eq!(labels[..6], ["1", "A", "2", "B", "3", "C"]),
                Variant::BRev => assert_eq!(labels[labels.len() - 4..], ["B", "2", "A", "1"]),
                Variant::Color => {
                    for (k, &i) in g.seq.iter().enumerate() {
                        assert_eq!(g.circles[i].label, (k + 1).to_string());
                        assert_eq!(g.circles[i].color, (g.start_color + k as u8) % 2);
                    }
                }
            }
            assert_eq!(g.seq.len(), g.p.seq);
            let mut s = g.seq.clone();
            s.sort();
            s.dedup();
            assert_eq!(s.len(), g.seq.len());
        }
        // B labels use the Turkish alphabet.
        assert_eq!(label_b(7), "Ç");
        assert_eq!(label_b(6), "4");
    }

    #[test]
    fn turkish_suffixes() {
        let d: Vec<String> = ["1", "2", "3", "6", "9", "10", "14", "16", "20", "30", "A", "B", "O", "Ö"].iter().map(|l| dat(l)).collect();
        assert_eq!(d, ["'e", "'ye", "'e", "'ya", "'a", "'a", "'e", "'ya", "'ye", "'a", "'ya", "'ye", "'ya", "'ye"]);
        let a: Vec<String> = ["1", "3", "4", "6", "10", "18", "A", "K"].iter().map(|l| abl(l)).collect();
        assert_eq!(a, ["'den", "'ten", "'ten", "'dan", "'dan", "'den", "'dan", "'den"]);
    }

    #[test]
    fn deterministic() {
        for level in LEVELS {
            let (a, b) = (Trail::level(level), Trail::level(level));
            assert_eq!(a.circles, b.circles);
            assert_eq!(a.seq, b.seq);
        }
    }

    fn run(g: &mut Trail) {
        g.act(&json!({"start": true})).unwrap();
        g.tick(COUNTDOWN_MS);
        assert_eq!(g.phase, Phase::Run);
    }

    #[test]
    fn solving_in_order_wins_three_stars() {
        for level in LEVELS {
            let mut g = Trail::level(level);
            run(&mut g);
            for &i in &g.seq.clone() {
                g.tick(200.0);
                g.act(&json!({"touch": i})).unwrap();
            }
            let st = g.state();
            assert_eq!(st["status"], "won", "level {level}");
            assert_eq!(st["stars"], 3);
            assert!(st["summary"].as_str().unwrap().contains("Hata 0"));
        }
    }

    #[test]
    fn errors_and_time_reduce_stars() {
        let mut g = Trail::level(2);
        run(&mut g);
        let seq = g.seq.clone();
        let wrong = (0..g.circles.len()).find(|i| !seq.contains(i) || *i == seq[2]).unwrap();
        g.act(&json!({"tap": seq[0]})).unwrap();
        let serial = g.err_serial;
        g.act(&json!({"tap": wrong})).unwrap();
        g.act(&json!({"tap": wrong})).unwrap(); // every wrong tap counts
        assert_eq!(g.errors, 2);
        assert_eq!(g.err_serial, serial + 2);
        let st = g.state();
        assert_eq!(st["done"], 1);
        assert_eq!(st["last_wrong"], wrong);
        g.act(&json!({"tap": seq[0]})).unwrap(); // already on the path: harmless double tap
        assert_eq!(g.errors, 2);
        g.act(&json!({"touch": seq[1]})).unwrap(); // the old action name still works
        assert_eq!(g.state()["done"], 2);
        assert!(g.state()["last_wrong"].is_null());
        for &i in &seq[2..] {
            g.act(&json!({"tap": i})).unwrap();
        }
        assert_eq!(g.state()["stars"], 2);
        // A third error drops a fast, finished run to 1 star.
        let mut g = Trail::level(2);
        run(&mut g);
        for _ in 0..3 {
            g.act(&json!({"tap": wrong})).unwrap();
        }
        for &i in &seq {
            g.act(&json!({"tap": i})).unwrap();
        }
        assert_eq!(g.state()["stars"], 1);
        // Slow but clean: over 1.5 × par → 1 star.
        let mut g = Trail::level(1);
        run(&mut g);
        g.tick(g.p.par_ms * 1.6);
        for &i in &g.seq.clone() {
            g.act(&json!({"touch": i})).unwrap();
        }
        assert_eq!(g.state()["status"], "won");
        assert_eq!(g.state()["stars"], 1);
    }

    #[test]
    fn timeout_loses() {
        let mut g = Trail::level(4);
        run(&mut g);
        g.act(&json!({"touch": g.seq[0]})).unwrap();
        for _ in 0..((g.limit_ms / 200.0) as usize + 2) {
            g.tick(200.0);
        }
        let st = g.state();
        assert_eq!(st["status"], "lost");
        assert!(st["summary"].as_str().unwrap().contains("Süre doldu"));
        assert!(g.act(&json!({"touch": g.seq[1]})).is_err());
    }

    #[test]
    fn illegal_actions_rejected_and_state_unchanged() {
        let mut g = Trail::level(1);
        let before = g.state();
        assert!(g.act(&json!({"touch": g.seq[0]})).is_err()); // not started
        assert!(g.act(&json!({"touch": 999})).is_err());
        assert!(g.act(&json!({"foo": 1})).is_err());
        assert_eq!(g.state(), before);
        g.act(&json!({"start": true})).unwrap();
        assert!(g.act(&json!({"start": true})).is_err());
        assert!(g.act(&json!({"touch": g.seq[0]})).is_err()); // countdown
        g.tick(COUNTDOWN_MS);
        let before = g.state();
        assert!(g.act(&json!({"touch": 999})).is_err());
        assert_eq!(g.state(), before);
    }

    #[test]
    #[ignore]
    fn timing_500_levels() {
        let t = std::time::Instant::now();
        let mut worst = 0.0f64;
        for level in 1..=500 {
            let s = std::time::Instant::now();
            let g = Trail::level(level);
            check_layout(&g);
            worst = worst.max(s.elapsed().as_secs_f64());
        }
        println!("trail: 500 levels in {:?}, worst {:.3} ms", t.elapsed(), worst * 1000.0);
    }
}
