//! Soroban — a 50-level Japanese abacus course for adults: reading and setting numbers, direct
//! moves, 5-complements ("small friends"), 10-complements ("big friends"), mixed complements,
//! flash chains, multiplication and division with a fixed placement rule, and anzan (mental
//! abacus).
//!
//! Board model: a row of rods, index 0 = leftmost. Each rod holds a digit 0..=9 (one heaven bead
//! worth 5 + four earth beads worth 1). The rightmost rod is the units rod; unit dots sit on every
//! third rod counted from the right.
//!
//! Course (`spec(level)`; the app shows 50 levels, levels above 50 clamp to 50):
//! -  1– 5 reading, setting and clearing numbers (1–9999)     · 7 rods, rod values shown faintly
//! -  6–10 direct addition / subtraction (no complements)     · 7 rods, rod values shown faintly
//! - 11–16 5-complements: +4 = +5 − 1 … and −4 = −5 + 1 …      · 7 rods
//! - 17–24 10-complements: +9 = +10 − 1 …, −9 = −10 + 1 …, chained carries · 9 rods
//! - 25–30 mixed complements (+6 = +10 − 5 + 1, −6 = −10 + 5 − 1) and multi-digit chains · 9 rods
//! - 31–36 flash chains on the abacus (3–10 numbers, 1–3 digits, 2.2 s » 1.2 s each) · 9 rods
//! - 37–41 multiplication 2×1, 3×1, 2×2 (multiplicand preset on the left, product right-aligned)
//! - 42–45 division by 1- and 2-digit divisors (divisor preset left, dividend right-aligned) · 11 rods
//! - 46–50 anzan: abacus hidden, typed answers; a ghost abacus with the first number fades out
//!
//! Every level is a lesson card (phase `lesson`) followed by a practice set of 8–10 problems
//! (phase `practice`). Chain problems come from a bounded random walk that only accepts terms
//! whose reference solution — the technique engine below, which works digit by digit from the
//! left exactly as a soroban user does — uses the techniques taught so far, and that contains
//! enough "focus" operations of the level's technique (e.g. level 11: at least two +4/+3 small
//! friend moves per problem).
//!
//! Checking: the view sends the per-rod digits after every bead move (`{"rods":[…]}`); the core
//! keeps the board, tracks which step of the reference solution has been reached (a chain term,
//! a partial product, a quotient digit …) and on `{"submit":true}` compares the checked area of the
//! board with the expected configuration. Multiplication and division therefore also check the
//! *placement* (the product's units digit on the rightmost rod, the quotient's units digit on the
//! marked rod). Reading and anzan problems are answered by typing (`{"answer":n}`).
//!
//! Hints: `{"hint":true}` turns on a live "next bead move" hint for the current problem (arrows
//! on the beads; caps the level at 2 stars). The first problems of a technique lesson are guided:
//! the hint is on automatically and free.
//!
//! Stars: accuracy ≥ 90 %, time ≤ par and no hint » 3; ≥ 80 % » 2; ≥ 70 % » 1; below 70 % the
//! level is lost. Par = sum of per-problem par times (derived from the bead-move count of the
//! reference solution, or from the flash duration). Time on the lesson card does not count.
//!
//! State: `{status, stars, title, goal, summary?, level, phase: "lesson"|"practice"|"done",
//!          section, lesson: {title, text}, rods_count, rods: [digit], show_values, interactive,
//!          abacus: "visible"|"hidden", ghost: {opacity, rods}|null,
//!          problem: {kind, input: "board"|"typed", text, prompt, terms|null, step, steps,
//!                    step_label, ref_len, check_from, units_rod, ref_label, area_label,
//!                    flash: {index, count, value, done, lead}|null}|null,
//!          index, total, correct, wrong, elapsed_ms, par_ms, guided, hints_used,
//!          hint: {rod, bead: "heaven"|"earth", delta, text, formula, tech, carry}|null,
//!          last: {serial, correct, given, answer, text, note}|null}`
//! Actions: `{"start":true}` · `{"rods":[d…]}` · `{"clear":true}` (zero the checked area) ·
//!          `{"reset":true}` (back to the problem's start) · `{"submit":true}` (may be combined
//!          with `rods`) · `{"answer":n}` (number or digit string) · `{"hint":true}`

use crate::rng::{seed_for, Rng};
use crate::Session;
use serde_json::{json, Value};

/// Length of the course; `params`/`spec` clamp every level above this.
pub const COURSE_LEVELS: u32 = 50;
/// "Get ready" pause before the first flashed number.
const LEAD_MS: f64 = 900.0;
/// Share of a flash slot during which the number is visible (the rest is a blank gap, so two
/// equal numbers in a row are still seen as two).
const FLASH_ON: f64 = 0.8;

// ---------------------------------------------------------------------------------------------
// Technique engine
// ---------------------------------------------------------------------------------------------

/// How one digit is added to / subtracted from a rod.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub enum Tech {
    /// The beads needed are free: move them.
    Direct,
    /// 5-complement: +4 = +5 − 1, −4 = −5 + 1 …
    Small,
    /// 10-complement: +9 = +10 − 1, −9 = −10 + 1 …
    Big,
    /// 10-complement whose rod part needs a 5-complement: +6 = +10 − 5 + 1, −6 = −10 + 5 − 1 …
    Mixed,
}

impl Tech {
    fn bit(self) -> u8 {
        1 << (self as u8)
    }
    pub fn key(self) -> &'static str {
        match self {
            Tech::Direct => "direct",
            Tech::Small => "small",
            Tech::Big => "big",
            Tech::Mixed => "mixed",
        }
    }
}

const D: u8 = 1; // Tech::Direct.bit()
const S: u8 = 2; // Tech::Small.bit()
const B: u8 = 4; // Tech::Big.bit()
const ALL: u8 = 15;

/// One bead motion: `delta` = ±5 moves the heaven bead, ±1..=4 moves that many earth beads
/// (+ = toward the beam).
#[derive(Clone, Debug)]
pub struct Move {
    pub rod: usize,
    pub delta: i8,
    pub tech: Option<Tech>,
    /// Technique formula of the digit this move belongs to, e.g. "+4 = +5 − 1".
    pub formula: String,
    /// Part of a carry / borrow on a rod further left.
    pub carry: bool,
}

/// One digit operation of a reference solution (used for technique requirements and tests).
#[derive(Clone, Copy, Debug)]
pub struct Op {
    pub digit: u8,
    pub add: bool,
    pub tech: Tech,
    /// 0 = the digit itself, 1 = its carry/borrow, 2 = a carry of the carry …
    pub depth: u32,
}

/// Can this bead motion be made on rod `rod` of board `b`?
pub fn move_ok(b: &[u8], rod: usize, delta: i8) -> bool {
    let x = b[rod] as i8;
    match delta {
        5 => x < 5,
        -5 => x >= 5,
        1..=4 => x % 5 + delta <= 4,
        -4..=-1 => x % 5 >= -delta,
        _ => false,
    }
}

fn apply(b: &mut [u8], m: &Move) {
    b[m.rod] = (b[m.rod] as i8 + m.delta) as u8;
}

/// Works digit operations on a board exactly as a soroban user does and records every bead move.
struct Engine {
    b: Vec<u8>,
    moves: Vec<Move>,
    ops: Vec<Op>,
    formula: String,
}

impl Engine {
    fn new(b: Vec<u8>) -> Self {
        Engine { b, moves: vec![], ops: vec![], formula: String::new() }
    }

    fn push(&mut self, rod: usize, delta: i8, tech: Tech, carry: bool) {
        debug_assert!(move_ok(&self.b, rod, delta), "bad move {delta} on {} (rod {rod})", self.b[rod]);
        self.b[rod] = (self.b[rod] as i8 + delta) as u8;
        self.moves.push(Move { rod, delta, tech: Some(tech), formula: self.formula.clone(), carry });
    }

    /// Direct motion of `d` (heaven first, then earth — a pinch on a real soroban).
    fn direct(&mut self, rod: usize, d: u8, sign: i8, tech: Tech, carry: bool) {
        if d >= 5 {
            self.push(rod, 5 * sign, tech, carry);
            if d > 5 {
                self.push(rod, (d as i8 - 5) * sign, tech, carry);
            }
        } else {
            self.push(rod, d as i8 * sign, tech, carry);
        }
    }

    /// Add digit `d` on `rod`. Returns false when a carry would run off the left edge.
    fn add(&mut self, rod: usize, d: u8, depth: u32) -> bool {
        if d == 0 {
            return true;
        }
        let x = self.b[rod];
        let carry = depth > 0;
        if x + d <= 9 {
            let tech = if x % 5 + d % 5 <= 4 { Tech::Direct } else { Tech::Small };
            if depth == 0 {
                self.formula =
                    if tech == Tech::Direct { format!("+{d}") } else { format!("+{d} = +5 − {}", 5 - d) };
            }
            self.ops.push(Op { digit: d, add: true, tech, depth });
            if tech == Tech::Direct {
                self.direct(rod, d, 1, tech, carry);
            } else {
                self.push(rod, 5, tech, carry);
                self.push(rod, -((5 - d) as i8), tech, carry);
            }
            true
        } else {
            if rod == 0 {
                return false;
            }
            let c = 10 - d; // x >= c because x + d >= 10
            let tech = if x % 5 >= c % 5 { Tech::Big } else { Tech::Mixed };
            if depth == 0 {
                self.formula = if tech == Tech::Big {
                    format!("+{d} = +10 − {c}")
                } else {
                    format!("+{d} = +10 − 5 + {}", 5 - c)
                };
            }
            self.ops.push(Op { digit: d, add: true, tech, depth });
            // +10 first (the carry may chain further left), then the complement on this rod.
            if !self.add(rod - 1, 1, depth + 1) {
                return false;
            }
            if tech == Tech::Big {
                self.direct(rod, c, -1, tech, carry);
            } else {
                self.push(rod, -5, tech, carry);
                self.push(rod, (5 - c) as i8, tech, carry);
            }
            true
        }
    }

    /// Subtract digit `d` on `rod`. Returns false when a borrow would run off the left edge.
    fn sub(&mut self, rod: usize, d: u8, depth: u32) -> bool {
        if d == 0 {
            return true;
        }
        let x = self.b[rod];
        let carry = depth > 0;
        if x >= d {
            let tech = if x % 5 >= d % 5 { Tech::Direct } else { Tech::Small };
            if depth == 0 {
                self.formula =
                    if tech == Tech::Direct { format!("−{d}") } else { format!("−{d} = −5 + {}", 5 - d) };
            }
            self.ops.push(Op { digit: d, add: false, tech, depth });
            if tech == Tech::Direct {
                self.direct(rod, d, -1, tech, carry);
            } else {
                self.push(rod, -5, tech, carry);
                self.push(rod, (5 - d) as i8, tech, carry);
            }
            true
        } else {
            if rod == 0 {
                return false;
            }
            let c = 10 - d; // x + c <= 9 because x < d
            let tech = if x % 5 + c % 5 <= 4 { Tech::Big } else { Tech::Mixed };
            if depth == 0 {
                self.formula = if tech == Tech::Big {
                    format!("−{d} = −10 + {c}")
                } else {
                    format!("−{d} = −10 + 5 − {}", 5 - c)
                };
            }
            self.ops.push(Op { digit: d, add: false, tech, depth });
            if !self.sub(rod - 1, 1, depth + 1) {
                return false;
            }
            if tech == Tech::Big {
                self.direct(rod, c, 1, tech, carry);
            } else {
                self.push(rod, 5, tech, carry);
                self.push(rod, -((5 - c) as i8), tech, carry);
            }
            true
        }
    }

    /// Add or subtract a whole number whose units digit sits on `units_rod`, digit by digit from
    /// the left (the soroban order).
    fn number(&mut self, units_rod: usize, n: u64, add: bool) -> bool {
        let digits: Vec<u8> = n.to_string().bytes().map(|c| c - b'0').collect();
        let k = digits.len();
        if k > units_rod + 1 {
            return false;
        }
        for (i, &d) in digits.iter().enumerate() {
            let rod = units_rod - (k - 1 - i);
            let ok = if add { self.add(rod, d, 0) } else { self.sub(rod, d, 0) };
            if !ok {
                return false;
            }
        }
        true
    }
}

/// Bead moves that turn `from` into `to` rod by rod (used to set numbers and as the hint
/// fallback when the board left the reference path).
fn set_moves(from: &[u8], to: &[u8], check_from: usize) -> Vec<Move> {
    let mut out = vec![];
    for r in check_from..from.len() {
        let (x, t) = (from[r], to[r]);
        if (x >= 5) != (t >= 5) {
            out.push(Move { rod: r, delta: if t >= 5 { 5 } else { -5 }, tech: None, formula: String::new(), carry: false });
        }
        let e = (t % 5) as i8 - (x % 5) as i8;
        if e != 0 {
            out.push(Move { rod: r, delta: e, tech: None, formula: String::new(), carry: false });
        }
    }
    out
}

/// Number formed by rods `from..`.
pub fn value(b: &[u8], from: usize) -> u64 {
    b[from..].iter().fold(0u64, |acc, &d| acc * 10 + d as u64)
}

/// Board of `rods` rods with `n` right-aligned.
pub fn board_of(mut n: u64, rods: usize) -> Vec<u8> {
    let mut b = vec![0u8; rods];
    for r in (0..rods).rev() {
        b[r] = (n % 10) as u8;
        n /= 10;
    }
    b
}

fn digits_of(n: u64) -> Vec<u8> {
    n.to_string().bytes().map(|c| c - b'0').collect()
}

fn ndigits(n: u64) -> u32 {
    digits_of(n).len() as u32
}

fn pow10(k: u32) -> u64 {
    10u64.pow(k)
}

// ---------------------------------------------------------------------------------------------
// Course
// ---------------------------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Signs {
    Add,
    Sub,
    Both,
}

/// Which operations count toward a chain level's technique requirement.
#[derive(Clone, Copy, Debug)]
pub enum Focus {
    None,
    /// A top-level digit op with this technique, direction (None = either) and digit (empty = any).
    Tech(Tech, Option<bool>, &'static [u8]),
    /// Any complement (top-level or carry).
    NonDirect,
    /// A carry/borrow that itself needs a carry/borrow (e.g. 97 + 5, 103 − 5).
    Cascade,
}

impl Focus {
    pub fn matches(self, o: &Op) -> bool {
        match self {
            Focus::None => false,
            Focus::Tech(t, add, digits) => {
                o.depth == 0
                    && o.tech == t
                    && add.is_none_or(|a| a == o.add)
                    && (digits.is_empty() || digits.contains(&o.digit))
            }
            Focus::NonDirect => o.tech != Tech::Direct,
            Focus::Cascade => o.depth >= 1 && o.tech >= Tech::Big,
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct ChainSpec {
    /// Digit count range of the first number (preset on the board).
    pub start: (u32, u32),
    /// Digit count range of the following terms.
    pub term: (u32, u32),
    /// Total numbers including the first.
    pub terms: usize,
    pub signs: Signs,
    /// Techniques allowed in additions / subtractions (bit masks, carries included).
    pub add_ok: u8,
    pub sub_ok: u8,
    pub focus: Focus,
    /// Minimum number of focus operations per problem.
    pub need: usize,
}

#[derive(Clone, Copy, Debug)]
pub enum Gen {
    Set { digits: (u32, u32) },
    Read { digits: (u32, u32) },
    /// Alternates "set it on a messy board" with reading problems.
    Clear { digits: (u32, u32) },
    Chain(ChainSpec),
    Flash { terms: usize, digits: (u32, u32), signs: Signs, interval: u32 },
    /// (multiplicand digits, multiplier digits) shapes.
    Mul(&'static [(u32, u32)]),
    /// (quotient digits, divisor digits) shapes.
    Div(&'static [(u32, u32)]),
    /// interval 0 = all numbers shown at once; ghost opacity goes from .0 to .1 over the set.
    Anzan { terms: usize, digits: (u32, u32), signs: Signs, interval: u32, ghost: (f64, f64) },
}

#[derive(Clone, Copy, Debug)]
pub struct Spec {
    pub section: &'static str,
    pub title: &'static str,
    pub lesson: &'static str,
    pub rods: usize,
    pub count: usize,
    /// Number of guided problems at the start of the set (hint on, free).
    pub guided: usize,
    pub show_values: bool,
    pub gen: Gen,
}

/// Every level 1..=500 is accepted; only 1..=50 are distinct (the app shows 50).
pub fn params(level: u32) -> u32 {
    level.clamp(1, COURSE_LEVELS)
}

#[allow(clippy::too_many_arguments)]
const fn ch(start: (u32, u32), term: (u32, u32), terms: usize, signs: Signs, add_ok: u8, sub_ok: u8, focus: Focus, need: usize) -> Gen {
    Gen::Chain(ChainSpec { start, term, terms, signs, add_ok, sub_ok, focus, need })
}

pub fn spec(level: u32) -> Spec {
    use Signs::*;
    let level = params(level);
    let (section, title, lesson, rods, count, guided, gen): (&str, &str, &str, usize, usize, usize, Gen) = match level {
        1 => ("Okuma", "Boncukların dili",
            "Her çubukta kirişin üstünde 1 beşlik, altında 4 birlik boncuk var. Sadece kirişe değen boncuklar sayılır.\n7 = beşlik + 2 birlik. Hiçbir boncuk kirişte değilse çubuk 0'dır.\nEn sağ çubuk birler, solundaki onlar, sonra yüzler.\nBirlikleri başparmakla yukarı it, işaret parmağıyla aşağı indir; beşliği işaret parmağıyla indir ve kaldır. Boncuğu kaydırabilir ya da dokunabilirsin.\nSayıyı kur, sonra Tamam'a dokun.",
            7, 10, 2, Gen::Set { digits: (1, 2) }),
        2 => ("Okuma", "Üç basamak ve sıfır",
            "Sayıyı soldan sağa kur: önce yüzler, sonra onlar, sonra birler.\nSıfır olan basamağın çubuğuna dokunma: 405'te onlar çubuğu boş kalır.\nBoncuk şekline alış: 6 = beşlik + 1, 9 = beşlik + 4. Saymak yerine şekli tanı.",
            7, 10, 0, Gen::Set { digits: (3, 3) }),
        3 => ("Okuma", "Bir bakışta okuma",
            "Bu bölümde abaküs sana bir sayı gösteriyor, sen yazıyorsun.\nHer çubuğu tek bakışta oku: beşlik inmişse 5, üstüne kirişe değen birlikler.\nSoldan sağa oku; boş çubuk 0 demektir. Sayma, şekli tanı.",
            7, 10, 0, Gen::Read { digits: (2, 4) }),
        4 => ("Okuma", "Binler ve birim noktaları",
            "Kirişteki noktalar sağdan her üç çubukta bir: binlik ayracı gibi düşün.\nEn sağdaki noktalı çubuk birler, bir sonraki nokta binler.\nDört basamaklı sayıda önce binlerin yerini noktadan bul, sonra soldan sağa kur.",
            7, 10, 0, Gen::Set { digits: (4, 4) }),
        5 => ("Okuma", "Temizle ve kur",
            "Kurma sorularında abaküs dağınık başlıyor: önce temizle.\nParmağını kirişin üstünde soldan sağa kaydır ya da Sıfırla'ya dokun. Gerçek sorobanda alt boncuklar abaküs hafif eğilerek indirilir, sonra işaret parmağı kiriş boyunca kayıp beşlikleri kaldırır.\nAradaki okuma sorularında sayıyı yaz.",
            7, 10, 0, Gen::Clear { digits: (2, 4) }),
        6 => ("Doğrudan", "Doğrudan toplama",
            "İlk sayı tahtada hazır; aşağıdaki sayıları sırayla ekle.\nDoğrudan hamle: gereken boncuklar boşta duruyorsa onları kirişe getir. 12 + 6 » birlerde beşlik + 1 birlik.\nSon sonucu tahtada bırak ve Tamam'a dokun.",
            7, 10, 2, ch((2, 2), (1, 2), 4, Add, D, D, Focus::None, 0)),
        7 => ("Doğrudan", "Doğrudan çıkarma",
            "Çıkarmada boncukları kirişten uzaklaştır.\n8 − 3 » 3 birlik indir. 9 − 6 » beşliği kaldır, 1 birlik indir.\nAra sonuç her adımda tahtada; geri dönüp hesaplama.",
            7, 10, 2, ch((2, 3), (1, 2), 4, Sub, D, D, Focus::None, 0)),
        8 => ("Doğrudan", "Kıskaç: 6–9 tek hamlede",
            "6–9 eklerken beşlik ve birlikler birlikte hareket eder: işaret parmağı beşliği indirirken başparmak birlikleri kaldırır (kıskaç).\n6–9 çıkarırken ikisi birlikte kirişten uzaklaşır.\nİki basamaklı sayıları soldan sağa çalış: önce onlar, sonra birler.",
            7, 10, 0, ch((2, 2), (1, 2), 4, Both, D, D, Focus::Tech(Tech::Direct, None, &[5, 6, 7, 8, 9]), 2)),
        9 => ("Doğrudan", "Çok basamaklı doğrudan",
            "Her basamak kendi çubuğunda, soldan sağa: 352 + 146 » yüzlere 1, onlara 4, birlere 6.\nGözünü sayının tamamında değil sıradaki basamakta tut.",
            7, 10, 0, ch((3, 3), (2, 3), 4, Both, D, D, Focus::None, 0)),
        10 => ("Doğrudan", "Doğrudan zincir",
            "Beş sayılık zincir, toplama ve çıkarma karışık.\nAra sonucu doğru kurduğunda sıradaki sayı parlar; tahtadaki ara sonuca güven.",
            7, 10, 0, ch((2, 3), (1, 3), 5, Both, D, D, Focus::None, 0)),
        11 => ("5'in tümleyeni", "+4 = +5 − 1 · +3 = +5 − 2",
            "Eklenecek birlikler boşta yoksa beşliği kullan: 5'in tümleyeni (küçük arkadaş).\n+4: beşliği indir, 1 birlik indir. 3 + 4 » 7.\n+3: beşliği indir, 2 birlik indir. 4 + 3 » 7.\nÇiftler: 4 ile 1, 3 ile 2. İlk iki soruda oklar yol gösterir.",
            7, 10, 2, ch((1, 1), (1, 1), 5, Both, D | S, D, Focus::Tech(Tech::Small, Some(true), &[4, 3]), 2)),
        12 => ("5'in tümleyeni", "+2 = +5 − 3 · +1 = +5 − 4",
            "+2: beşliği indir, 3 birlik indir. 4 + 2 » 6.\n+1: beşliği indir, 4 birlik indir. 4 + 1 » 5.\nKural tek: 5 ekle, tümleyeni çıkar. Sayıyı hesaplama, hareketi hatırla.",
            7, 10, 2, ch((1, 1), (1, 1), 5, Both, D | S, D, Focus::Tech(Tech::Small, Some(true), &[2, 1]), 2)),
        13 => ("5'in tümleyeni", "−4 = −5 + 1 · −3 = −5 + 2",
            "Çıkarılacak birlikler kirişte yoksa beşliği kaldır, tümleyeni ekle.\n−4: beşliği kaldır, 1 birlik kaldır. 6 − 4 » 2.\n−3: beşliği kaldır, 2 birlik kaldır. 7 − 3 » 4.",
            7, 10, 2, ch((1, 1), (1, 1), 5, Both, D, D | S, Focus::Tech(Tech::Small, Some(false), &[4, 3]), 2)),
        14 => ("5'in tümleyeni", "−2 = −5 + 3 · −1 = −5 + 4",
            "−2: beşliği kaldır, 3 birlik kaldır. 5 − 2 » 3.\n−1: beşliği kaldır, 4 birlik kaldır. 5 − 1 » 4.\nToplamada beşlik iner, birlik iner; çıkarmada beşlik kalkar, birlik kalkar.",
            7, 10, 2, ch((1, 1), (1, 1), 5, Both, D, D | S, Focus::Tech(Tech::Small, Some(false), &[2, 1]), 2)),
        15 => ("5'in tümleyeni", "5'in tümleyenleri karışık",
            "Toplama ve çıkarma karışık. Her adımda önce bak: boncuk boşta mı? Boştaysa doğrudan, değilse 5'in tümleyeni.\nTümleyen çiftleri: 1–4, 2–3.",
            7, 10, 0, ch((1, 1), (1, 1), 6, Both, D | S, D | S, Focus::Tech(Tech::Small, None, &[]), 3)),
        16 => ("5'in tümleyeni", "Çok basamakta 5'in tümleyeni",
            "Her çubuk kendi kararını verir. 34 + 23 » onlarda +2 = +5 − 3, birlerde +3 = +5 − 2 » 57.\nSoldan sağa: önce onlar, sonra birler.",
            7, 10, 0, ch((2, 2), (2, 2), 4, Both, D | S, D | S, Focus::Tech(Tech::Small, None, &[]), 2)),
        17 => ("10'un tümleyeni", "+9 = +10 − 1 · +8 = +10 − 2",
            "Toplam 9'u aşıyorsa 10'un tümleyeni (büyük arkadaş): soldaki çubuğa 1 ekle, bu çubuktan tümleyeni çıkar.\n+9: soldakine +1, burada −1. 7 + 9 » 16.\n+8: soldakine +1, burada −2. 4 + 8 » 12.\nÇiftler: 9–1, 8–2, 7–3, 6–4, 5–5.",
            9, 10, 2, ch((1, 2), (1, 1), 5, Add, D | S | B, D, Focus::Tech(Tech::Big, Some(true), &[9, 8]), 2)),
        18 => ("10'un tümleyeni", "+7 = +10 − 3 · +6 = +10 − 4",
            "+7: soldakine 1, burada 3 çıkar. 8 + 7 » 15.\n+6: soldakine 1, burada 4 çıkar. 9 + 6 » 15.\nBu bölümde çıkaracağın birlikler hep kirişte hazır.",
            9, 10, 2, ch((1, 2), (1, 1), 5, Add, D | S | B, D, Focus::Tech(Tech::Big, Some(true), &[7, 6]), 2)),
        19 => ("10'un tümleyeni", "+5 … +1: on ekle, fazlasını çıkar",
            "+5 = +10 − 5: soldakine 1, beşliği kaldır. 7 + 5 » 12.\n+4 = +10 − 6, +3 = +10 − 7, +2 = +10 − 8, +1 = +10 − 9.\n9 + 1 » bu çubuğu tamamen temizle, soldakine 1 ekle.",
            9, 10, 2, ch((1, 2), (1, 1), 5, Add, D | S | B, D, Focus::Tech(Tech::Big, Some(true), &[5, 4, 3, 2, 1]), 2)),
        20 => ("10'un tümleyeni", "−9 = −10 + 1 · −8 = −10 + 2",
            "Çıkaracak kadar boncuk yoksa soldaki çubuktan 1 ödünç al (−10), burada tümleyeni ekle.\n−9: soldakinden 1 indir, burada 1 kaldır. 12 − 9 » 3.\n−8: soldakinden 1 indir, burada 2 kaldır. 13 − 8 » 5.",
            9, 10, 2, ch((2, 2), (1, 1), 5, Sub, D, D | S | B, Focus::Tech(Tech::Big, Some(false), &[9, 8]), 2)),
        21 => ("10'un tümleyeni", "−7 = −10 + 3 · −6 = −10 + 4",
            "−7: soldakinden 1 indir, burada 3 kaldır. 11 − 7 » 4.\n−6: soldakinden 1 indir, burada 4 kaldır. 30 − 6 » 24.",
            9, 10, 2, ch((2, 2), (1, 1), 5, Sub, D, D | S | B, Focus::Tech(Tech::Big, Some(false), &[7, 6]), 2)),
        22 => ("10'un tümleyeni", "−5 … −1: on al, fazlasını geri koy",
            "−5 = −10 + 5: soldakinden 1 indir, beşliği indir. 12 − 5 » 7.\n−4 = −10 + 6, −3 = −10 + 7, −2 = −10 + 8, −1 = −10 + 9.\n10 − 1 » onlardan 1 indir, birlerde 9 kur.",
            9, 10, 2, ch((2, 2), (1, 1), 5, Sub, D, D | S | B, Focus::Tech(Tech::Big, Some(false), &[5, 4, 3, 2, 1]), 2)),
        23 => ("10'un tümleyeni", "10'un tümleyenleri karışık",
            "Karar sırası: sonuç bu çubukta 9'u aşıyor ya da 0'ın altına iniyor mu? » 10'un tümleyeni.\nAşmıyorsa: boncuk yeterli mi? » doğrudan; değilse 5'in tümleyeni.",
            9, 10, 0, ch((2, 2), (1, 2), 5, Both, D | S | B, D | S | B, Focus::Tech(Tech::Big, None, &[]), 3)),
        24 => ("10'un tümleyeni", "Zincirleme elde ve ödünç",
            "Soldaki çubuk 9 ise +10 orada da taşar: 97 + 5 » yüzlere 1, onlardan 9 çıkar, birlerden 5 çıkar » 102.\nÖdünçte tersi: 103 − 5 » yüzlerden 1 indir, onlarda 9 kur, birlerde beşliği indir » 98.\nElde ya da ödünç, boş olmayan bir çubuk bulana kadar sola zincirlenir.",
            9, 10, 0, ch((2, 3), (1, 2), 4, Both, D | S | B, D | S | B, Focus::Cascade, 1)),
        25 => ("Karışık", "+6 = +10 − 5 + 1 … +9 = +10 − 5 + 4",
            "Bazen 10'un tümleyeni bu çubukta doğrudan çıkmaz: 5 + 6'da birlerde 4 birlik yok.\nO zaman çıkarmayı 5'in tümleyeniyle yap: −4 = −5 + 1.\n+6 = +10 − 5 + 1, +7 = +10 − 5 + 2, +8 = +10 − 5 + 3, +9 = +10 − 5 + 4.\n5 + 6 » soldakine 1, beşliği kaldır, 1 birlik kaldır » 11.",
            9, 10, 2, ch((1, 2), (1, 1), 5, Add, ALL, D | S | B, Focus::Tech(Tech::Mixed, Some(true), &[6, 7, 8, 9]), 2)),
        26 => ("Karışık", "−6 = −10 + 5 − 1 … −9 = −10 + 5 − 4",
            "Ödünçten sonra tümleyeni ekleyecek boncuk yoksa 5'in tümleyeniyle ekle: +4 = +5 − 1.\n−6 = −10 + 5 − 1, −7 = −10 + 5 − 2, −8 = −10 + 5 − 3, −9 = −10 + 5 − 4.\n14 − 6 » onlardan 1 indir, beşliği indir, 1 birlik indir » 8.",
            9, 10, 2, ch((2, 2), (1, 1), 5, Sub, ALL, ALL, Focus::Tech(Tech::Mixed, Some(false), &[6, 7, 8, 9]), 2)),
        27 => ("Karışık", "Bütün teknikler: toplama",
            "İki basamaklı sayılar ve dört karar: doğrudan, 5'in tümleyeni, 10'un tümleyeni, karışık.\nHer basamakta kararı bir bakışta ver; kaç ettiğini hesaplama, boncuk şekline bak.",
            9, 10, 0, ch((2, 2), (2, 2), 4, Add, ALL, ALL, Focus::NonDirect, 3)),
        28 => ("Karışık", "Bütün teknikler: çıkarma",
            "Aynı dört karar çıkarmada. Ödünç zinciri boş çubukları 9 yaparak sola ilerler.\nSoldan sağa çalışmaya devam et.",
            9, 10, 0, ch((3, 3), (2, 2), 4, Sub, ALL, ALL, Focus::NonDirect, 3)),
        29 => ("Karışık", "Üç basamaklı zincirler",
            "Üç basamaklı sayılar, karışık işaretler. Ara sonuçları listeden takip et.\nKaybolursan ipucu son doğru adımdan devam eder.",
            9, 10, 0, ch((3, 3), (2, 3), 4, Both, ALL, ALL, Focus::Tech(Tech::Mixed, None, &[]), 1)),
        30 => ("Karışık", "Büyük tekrar",
            "Beş sayılık uzun zincir, bütün teknikler. Temel kursun sınavı: hızdan önce temizlik.",
            9, 10, 0, ch((3, 4), (2, 4), 5, Both, ALL, ALL, Focus::NonDirect, 4)),
        31 => ("Flash", "Flash: ilk adım",
            "Sayılar tek tek, kısa süre görünür. Gördüğün anda abaküse ekle; sayıyı aklında biriktirme.\nSon sayıdan sonra sonucu tahtada bırak ve Tamam'a dokun.",
            9, 10, 0, Gen::Flash { terms: 3, digits: (1, 1), signs: Add, interval: 1800 }),
        32 => ("Flash", "Flash: işaretler",
            "Eksi işaretli sayılar da geliyor. İşareti sayıdan önce oku; parmağın gözünle aynı anda başlasın.",
            9, 10, 0, Gen::Flash { terms: 5, digits: (1, 1), signs: Both, interval: 1500 }),
        33 => ("Flash", "Flash: iki basamak",
            "İki basamaklı sayılar: iki hamle, önce onlar, sonra birler. Sayıyı bütün olarak fotoğrafla.",
            9, 10, 0, Gen::Flash { terms: 4, digits: (2, 2), signs: Add, interval: 2200 }),
        34 => ("Flash", "Flash: iki basamak, karışık",
            "İki basamaklı sayılar, artı ve eksi. Ritmini bul: göz, el, sonraki sayı.",
            9, 10, 0, Gen::Flash { terms: 5, digits: (2, 2), signs: Both, interval: 2000 }),
        35 => ("Flash", "Flash: yedi sayı",
            "Yedi sayı, bir ve iki basamak karışık. Bir sayıyı kaçırırsan durma; zinciri sürdür.",
            9, 8, 0, Gen::Flash { terms: 7, digits: (1, 2), signs: Both, interval: 1500 }),
        36 => ("Flash", "Flash: yarışma listesi",
            "On sayı, bir ile üç basamak arası. Yarışmalardaki gibi: el hiç durmadan çalışır.",
            9, 8, 0, Gen::Flash { terms: 10, digits: (1, 3), signs: Both, interval: 1500 }),
        37 => ("Çarpma", "Çarpma yerleşimi: 2 × 1",
            "Çarpılan solda hazır, çarpan soruda. Çarpım sağdaki alana kurulur; birler basamağı en sağ çubuktadır.\nÇarpım en fazla (çarpılan + çarpan) basamak sayısı kadar çubuk tutar: 34 × 6 » 3 çubuk.\nBasamakları soldan sağa çarp, her ara çarpımı iki basamaklı yaz (gerekirse başa 0): 3 × 6 = 18 » sağdan 3. ve 2. çubuk; 4 × 6 = 24 » sağdan 2. ve 1. çubuk. Sonuç 204.",
            11, 8, 2, Gen::Mul(&[(2, 1)])),
        38 => ("Çarpma", "Çarpma: 3 × 1",
            "Aynı kural, bir basamak daha: 236 × 4 » 4 çubuk.\n2 × 4 = 08, 3 × 4 = 12, 6 × 4 = 24; her ara çarpım bir öncekinden bir çubuk sağda başlar » 944.",
            11, 8, 1, Gen::Mul(&[(3, 1)])),
        39 => ("Çarpma", "Çarpma: hız",
            "2 × 1 ve 3 × 1 karışık. Ara çarpımı söylerken yerini de söyle: on sekiz, üçüncü ve ikinci çubuk.",
            11, 8, 0, Gen::Mul(&[(2, 1), (3, 1)])),
        40 => ("Çarpma", "Çarpma: 2 × 2",
            "47 × 36 » 4 çubuk. Sıra: 4 × 3 = 12, 4 × 6 = 24, 7 × 3 = 21, 7 × 6 = 42.\nÇarpılanda ya da çarpanda bir basamak sağa gittikçe ara çarpım da bir çubuk sağa kayar: 4 × 3 en solda (sağdan 4. ve 3.), 4 × 6 ile 7 × 3 bir sağda, 7 × 6 en sağda.\n47 × 36 = 1692.",
            11, 8, 2, Gen::Mul(&[(2, 2)])),
        41 => ("Çarpma", "Çarpma tekrarı",
            "3 × 1 ve 2 × 2 karışık. Önce çubuk sayısını belirle, sonra ara çarpımları kaydırarak ekle.",
            11, 8, 0, Gen::Mul(&[(3, 1), (2, 2)])),
        42 => ("Bölme", "Bölme yerleşimi: tek basamaklı bölen",
            "Bölen solda, bölünen sağda hazır. Bölümün birler basamağı işaretli çubuğa gelir.\nKural: bölen, bölünenin ilk basamağına sığıyorsa bölüm basamağını iki çubuk sola, sığmıyorsa bir çubuk sola yaz. Sonra bölüm × bölen'i, bölüm basamağının hemen sağındaki iki çubuktan çıkar.\n84 ÷ 4: 8'e 4 sığar » 2'yi iki sola yaz, 08 çıkar; 4'e 4 sığar » 1'i iki sola yaz, 04 çıkar. Bölüm 21, bölünen sıfırlandı.",
            11, 8, 2, Gen::Div(&[(2, 1)])),
        43 => ("Bölme", "Bölme: uzun bölünen",
            "3–4 basamaklı bölünenler. Arada 0 çıkabilir: 618 ÷ 6 » 1; sonra 1'e 6 sığmaz, o basamak 0 kalır (çubuk boş); 18 ÷ 6 = 3 » 103.",
            11, 8, 0, Gen::Div(&[(3, 1)])),
        44 => ("Bölme", "Bölme: iki basamaklı bölen",
            "Önce bölüm basamağını tahmin et: 672 ÷ 32 » 6'da 3 iki kez » 2.\nKural aynı: 32, 67'ye sığıyor » iki sola. Sonra 2 × 3 = 06 ve 2 × 2 = 04'ü birer çubuk kayarak çıkar.\nTahmin büyük geldiyse çıkarma yetmez: bölüm basamağını 1 azalt, bir bölen geri ekle.",
            11, 8, 2, Gen::Div(&[(2, 2)])),
        45 => ("Bölme", "Bölme: dört basamak",
            "Dört basamaklı bölünen, iki basamaklı bölen; bölüm iki ya da üç basamak.\nHer bölüm basamağında: tahmin et, yaz, çarpımları çıkar, kalanı kontrol et (bölenden küçük olmalı).",
            11, 8, 0, Gen::Div(&[(2, 2), (3, 2)])),
        46 => ("Anzan", "Hayali soroban",
            "Abaküs gizli. Sayıları zihnindeki sorobanda kur, boncukları zihninde oynat ve cevabı yaz.\nSoluk görüntü ilk sayıyı gösteriyor; sorular ilerledikçe kayboluyor.\nParmaklarını havada oynatmak serbest, hatta önerilir.",
            9, 10, 0, Gen::Anzan { terms: 3, digits: (1, 1), signs: Both, interval: 0, ghost: (0.55, 0.1) }),
        47 => ("Anzan", "Anzan: iki basamak",
            "Dört iki basamaklı sayı. Zihinde iki çubuk: önce onları, sonra birleri oynat.\nGörüntü her soruda biraz daha siliniyor.",
            9, 10, 0, Gen::Anzan { terms: 4, digits: (2, 2), signs: Add, interval: 0, ghost: (0.35, 0.0) }),
        48 => ("Anzan", "Flash anzan",
            "Sayılar tek tek geçer; zihindeki boncuklar her sayıda kıpırdasın. İçinden sayı okuma, hareketi gör.",
            9, 10, 0, Gen::Anzan { terms: 5, digits: (1, 1), signs: Both, interval: 1300, ghost: (0.2, 0.0) }),
        49 => ("Anzan", "Flash anzan: iki basamak",
            "Beş iki basamaklı sayı, görüntü yok. Zihindeki abaküs artık tamamen senin.",
            9, 8, 0, Gen::Anzan { terms: 5, digits: (2, 2), signs: Add, interval: 1900, ghost: (0.0, 0.0) }),
        _ => ("Anzan", "Final: flash anzan",
            "Altı iki basamaklı sayı, artı ve eksi. Kursun son sınavı. Yavaş nefes, sabit ritim.",
            9, 8, 0, Gen::Anzan { terms: 6, digits: (2, 2), signs: Both, interval: 1600, ghost: (0.0, 0.0) }),
    };
    Spec { section, title, lesson, rods, count, guided, show_values: level <= 10, gen }
}

// ---------------------------------------------------------------------------------------------
// Problems
// ---------------------------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Set,
    Read,
    Calc,
    Flash,
    Mul,
    Div,
    Anzan,
    FlashAnzan,
}

impl Kind {
    pub fn key(self) -> &'static str {
        match self {
            Kind::Set => "set",
            Kind::Read => "read",
            Kind::Calc => "calc",
            Kind::Flash => "flash",
            Kind::Mul => "mul",
            Kind::Div => "div",
            Kind::Anzan => "anzan",
            Kind::FlashAnzan => "flash_anzan",
        }
    }
    /// Answered by setting the abacus (vs. typing).
    pub fn board_input(self) -> bool {
        matches!(self, Kind::Set | Kind::Calc | Kind::Flash | Kind::Mul | Kind::Div)
    }
    pub fn flashes(self) -> bool {
        matches!(self, Kind::Flash | Kind::FlashAnzan)
    }
    fn prompt(self) -> &'static str {
        match self {
            Kind::Set => "Sayıyı abaküse kur",
            Kind::Read => "Abaküste hangi sayı var?",
            Kind::Calc => "Hesabı abaküste yap",
            Kind::Flash => "Sayıları izle, abaküste topla",
            Kind::Mul => "Çarpımı sağdaki alana kur",
            Kind::Div => "Bölümü işaretli çubuğa göre kur",
            Kind::Anzan => "Zihninde hesapla",
            Kind::FlashAnzan => "Sayıları izle, zihninde topla",
        }
    }
}

/// One step of a reference solution: from `before`, `moves` lead to `after`, whose checked area
/// reads `target`.
#[derive(Clone, Debug)]
pub struct Step {
    pub label: String,
    pub target: u64,
    pub before: Vec<u8>,
    pub moves: Vec<Move>,
    pub after: Vec<u8>,
}

#[derive(Clone, Debug)]
pub struct Problem {
    pub kind: Kind,
    pub text: String,
    /// Signed terms (chains, flash, anzan); the first is always positive.
    pub terms: Vec<i64>,
    pub initial: Vec<u8>,
    /// Rods `check_from..` are compared on submit (left of it: the preset reference factor).
    pub check_from: usize,
    pub ref_len: usize,
    /// Expected reading of the checked area (board problems).
    pub expected: u64,
    /// The number the player obtains (or types).
    pub answer: i64,
    pub units_rod: usize,
    pub steps: Vec<Step>,
    pub ops: Vec<Op>,
    pub interval_ms: f64,
    pub par_ms: f64,
    pub ghost: Option<Vec<u8>>,
}

impl Problem {
    fn moves(&self) -> usize {
        self.steps.iter().map(|s| s.moves.len()).sum()
    }
}

/// Random number with a digit count in `digits` (leading digit 1..=9).
fn num(r: &mut Rng, digits: (u32, u32)) -> u64 {
    let k = r.range(digits.0 as i64, digits.1 as i64) as u32;
    let mut n = r.range(1, 9) as u64;
    for _ in 1..k {
        n = n * 10 + r.range(0, 9) as u64;
    }
    n
}

/// Factor for multiplication drills: leading digit 2..=9, other digits mostly 1..=9.
fn factor(r: &mut Rng, k: u32) -> u64 {
    let mut n = r.range(2, 9) as u64;
    for _ in 1..k {
        let d = if r.chance(0.1) { 0 } else { r.range(1, 9) };
        n = n * 10 + d as u64;
    }
    n
}

fn signed(t: i64) -> String {
    if t < 0 {
        format!("− {}", -t)
    } else {
        format!("+ {t}")
    }
}

fn chain_text(terms: &[i64]) -> String {
    let mut s = terms[0].to_string();
    for &t in &terms[1..] {
        s.push(' ');
        s.push_str(&signed(t));
    }
    s
}

/// 1-based rod position counted from the right ("sağdan k. çubuk").
fn from_right(rods: usize, rod: usize) -> usize {
    rods - rod
}

fn blank(kind: Kind, rods: usize) -> Problem {
    Problem {
        kind,
        text: String::new(),
        terms: vec![],
        initial: vec![0; rods],
        check_from: 0,
        ref_len: 0,
        expected: 0,
        answer: 0,
        units_rod: rods - 1,
        steps: vec![],
        ops: vec![],
        interval_ms: 0.0,
        par_ms: 0.0,
        ghost: None,
    }
}

fn set_problem(target: u64, initial: Vec<u8>, rods: usize) -> Problem {
    let after = board_of(target, rods);
    let moves = set_moves(&initial, &after, 0);
    let mut p = blank(Kind::Set, rods);
    p.text = target.to_string();
    p.steps = vec![Step { label: format!("{target} kur"), target, before: initial.clone(), moves, after }];
    p.initial = initial;
    p.expected = target;
    p.answer = target as i64;
    p.par_ms = 3000.0 + 1100.0 * p.moves() as f64;
    p
}

fn read_problem(v: u64, rods: usize) -> Problem {
    let mut p = blank(Kind::Read, rods);
    p.text = "?".into();
    p.initial = board_of(v, rods);
    p.expected = v;
    p.answer = v as i64;
    p.par_ms = 3500.0 + 900.0 * ndigits(v) as f64;
    p
}

/// Reference solution of a chain on the board: one step per term after the first.
fn chain_steps(terms: &[i64], rods: usize) -> Option<(Vec<u8>, Vec<Step>, Vec<Op>)> {
    let initial = board_of(terms[0] as u64, rods);
    let mut b = initial.clone();
    let mut steps = vec![];
    let mut ops = vec![];
    for &t in &terms[1..] {
        let before = b.clone();
        let mut e = Engine::new(b);
        if !e.number(rods - 1, t.unsigned_abs(), t > 0) {
            return None;
        }
        b = e.b;
        ops.extend(e.ops);
        steps.push(Step { label: signed(t), target: value(&b, 0), before, moves: e.moves, after: b.clone() });
    }
    Some((initial, steps, ops))
}

fn gen_chain(r: &mut Rng, c: &ChainSpec, rods: usize) -> Problem {
    let limit = pow10(rods as u32);
    let mut best: Option<(Vec<i64>, usize)> = None;
    'attempt: for _ in 0..400 {
        let start = num(r, c.start);
        let mut b = board_of(start, rods);
        let mut terms = vec![start as i64];
        let mut focus = 0usize;
        for _ in 1..c.terms {
            let mut accepted = false;
            // Single-digit technique drills: when a focus move is possible here, usually take it.
            let mut focus_first: Vec<(u64, bool)> = vec![];
            if let Focus::Tech(_, dir, digits) = c.focus {
                if c.term == (1, 1) && !digits.is_empty() && r.chance(0.7) {
                    for &d in digits {
                        for add in [true, false] {
                            let sign_ok = match c.signs {
                                Signs::Add => add,
                                Signs::Sub => !add,
                                Signs::Both => true,
                            };
                            if sign_ok && dir.is_none_or(|a| a == add) {
                                focus_first.push((d as u64, add));
                            }
                        }
                    }
                    r.shuffle(&mut focus_first);
                }
            }
            for attempt in 0..60 + focus_first.len() {
                let (t, add) = if attempt < focus_first.len() {
                    focus_first[attempt]
                } else {
                    let add = match c.signs {
                        Signs::Add => true,
                        Signs::Sub => false,
                        Signs::Both => r.chance(0.5),
                    };
                    (num(r, c.term), add)
                };
                let v = value(&b, 0);
                if (!add && t > v) || (add && v + t >= limit) {
                    continue;
                }
                let mut e = Engine::new(b.clone());
                if !e.number(rods - 1, t, add) {
                    continue;
                }
                if e.ops.iter().any(|o| (if o.add { c.add_ok } else { c.sub_ok }) & o.tech.bit() == 0) {
                    continue;
                }
                let f = e.ops.iter().filter(|o| c.focus.matches(o)).count();
                if attempt < focus_first.len() && f == 0 {
                    continue;
                }
                focus += f;
                b = e.b;
                terms.push(if add { t as i64 } else { -(t as i64) });
                accepted = true;
                break;
            }
            if !accepted {
                continue 'attempt;
            }
        }
        if focus >= c.need {
            best = Some((terms, focus));
            break;
        }
        if best.as_ref().is_none_or(|(_, f)| focus > *f) {
            best = Some((terms, focus));
        }
    }
    let terms = best.map(|(t, _)| t).unwrap_or_else(|| vec![1, 1]);
    let (initial, steps, ops) = chain_steps(&terms, rods).expect("chain fits the board");
    let mut p = blank(Kind::Calc, rods);
    p.text = chain_text(&terms);
    p.answer = terms.iter().sum();
    p.expected = p.answer as u64;
    p.initial = initial;
    p.steps = steps;
    p.ops = ops;
    p.terms = terms;
    p.par_ms = 3000.0 + 1200.0 * p.moves() as f64;
    p
}

/// Terms for flash and anzan: the running total never goes below zero.
fn gen_terms(r: &mut Rng, n: usize, digits: (u32, u32), signs: Signs) -> Vec<i64> {
    let mut out: Vec<i64> = vec![];
    let mut total = 0i64;
    for i in 0..n {
        let mut t = num(r, digits) as i64;
        for _ in 0..20 {
            if out.last().is_none_or(|&p| p.abs() != t) {
                break;
            }
            t = num(r, digits) as i64;
        }
        let sub = i > 0
            && match signs {
                Signs::Add => false,
                Signs::Sub => true,
                Signs::Both => r.chance(0.45),
            }
            && t <= total;
        let v = if sub { -t } else { t };
        total += v;
        out.push(v);
    }
    out
}

fn gen_flash(r: &mut Rng, terms: usize, digits: (u32, u32), signs: Signs, interval: u32, rods: usize) -> Problem {
    let terms = gen_terms(r, terms, digits, signs);
    let mut p = blank(Kind::Flash, rods);
    // Reference solution from an empty board (the first number is set too).
    let mut b = vec![0u8; rods];
    for &t in &terms {
        let before = b.clone();
        let mut e = Engine::new(b);
        let ok = e.number(rods - 1, t.unsigned_abs(), t > 0);
        debug_assert!(ok);
        b = e.b;
        p.ops.extend(e.ops);
        p.steps.push(Step { label: signed(t), target: value(&b, 0), before, moves: e.moves, after: b.clone() });
    }
    p.answer = terms.iter().sum();
    p.expected = p.answer as u64;
    p.text = chain_text(&terms);
    p.interval_ms = interval as f64;
    p.par_ms = LEAD_MS + interval as f64 * terms.len() as f64 + 2500.0;
    p.terms = terms;
    p
}

fn gen_anzan(r: &mut Rng, terms: usize, digits: (u32, u32), signs: Signs, interval: u32, rods: usize) -> Problem {
    let terms = gen_terms(r, terms, digits, signs);
    let kind = if interval > 0 { Kind::FlashAnzan } else { Kind::Anzan };
    let mut p = blank(kind, rods);
    // The mental moves are the same as on the abacus: count them for the par time.
    let mut b = vec![0u8; rods];
    for &t in &terms {
        let mut e = Engine::new(b);
        let ok = e.number(rods - 1, t.unsigned_abs(), t > 0);
        debug_assert!(ok);
        b = e.b;
        p.ops.extend(e.ops);
    }
    p.answer = terms.iter().sum();
    p.expected = p.answer as u64;
    p.text = chain_text(&terms);
    p.interval_ms = interval as f64;
    p.par_ms = if interval > 0 {
        LEAD_MS + interval as f64 * terms.len() as f64 + 3500.0
    } else {
        3000.0 + 1300.0 * p.ops.len() as f64
    };
    p.ghost = Some(if interval > 0 { vec![0; rods] } else { board_of(terms[0] as u64, rods) });
    p.terms = terms;
    p
}

fn gen_mul(r: &mut Rng, shapes: &[(u32, u32)], rods: usize) -> Problem {
    let &(m, n) = r.pick(shapes);
    let a = factor(r, m);
    let bb = factor(r, n);
    let (ad, bd) = (digits_of(a), digits_of(bb));
    let (m, n) = (ad.len(), bd.len());
    let mut initial = vec![0u8; rods];
    initial[..m].copy_from_slice(&ad);
    let cf = m;
    let s = rods - (m + n); // first rod of the product field
    let mut b = initial.clone();
    let mut steps = vec![];
    let mut ops = vec![];
    for (i, &x) in ad.iter().enumerate() {
        for (j, &y) in bd.iter().enumerate() {
            let p = x * y;
            if p == 0 {
                continue;
            }
            let rt = s + i + j;
            let before = b.clone();
            let mut e = Engine::new(b);
            let ok = e.add(rt, p / 10, 0) && e.add(rt + 1, p % 10, 0);
            debug_assert!(ok);
            b = e.b;
            ops.extend(e.ops);
            steps.push(Step {
                label: format!(
                    "{x} × {y} = {p:02} » sağdan {}. ve {}. çubuğa ekle",
                    from_right(rods, rt),
                    from_right(rods, rt + 1)
                ),
                target: value(&b, cf),
                before,
                moves: e.moves,
                after: b.clone(),
            });
        }
    }
    let mut pr = blank(Kind::Mul, rods);
    pr.text = format!("{a} × {bb}");
    pr.terms = vec![a as i64, bb as i64];
    pr.initial = initial;
    pr.check_from = cf;
    pr.ref_len = m;
    pr.expected = a * bb;
    pr.answer = (a * bb) as i64;
    pr.steps = steps;
    pr.ops = ops;
    pr.par_ms = 5000.0 + 1300.0 * pr.moves() as f64;
    pr
}

fn gen_div(r: &mut Rng, shapes: &[(u32, u32)], rods: usize) -> Problem {
    let &(qd, n) = r.pick(shapes);
    let (mut q, mut d) = (0u64, 0u64);
    for _ in 0..200 {
        q = num(r, (qd, qd));
        d = if n == 1 {
            r.range(2, 9) as u64
        } else {
            loop {
                let c = r.range(12, 98) as u64;
                if c % 10 != 0 {
                    break c;
                }
            }
        };
        if ndigits(q * d) <= 4 && q > 1 {
            break;
        }
    }
    let dividend = q * d;
    let dd = digits_of(d);
    let n = dd.len();
    let mut initial = board_of(dividend, rods);
    initial[..n].copy_from_slice(&dd);
    let cf = n;
    let last = rods - 1;
    let units = last - (n + 1); // the quotient's units rod
    let qdig = digits_of(q);
    let mut b = initial.clone();
    let mut steps = vec![];
    let mut ops = vec![];
    for (k, &qj) in qdig.iter().enumerate() {
        let place = qdig.len() - 1 - k;
        if qj == 0 {
            continue;
        }
        let rq = units - place;
        // Write the quotient digit.
        let before = b.clone();
        let mut e = Engine::new(b);
        let ok = e.add(rq, qj, 0);
        debug_assert!(ok && before[rq] == 0);
        b = e.b;
        ops.extend(e.ops);
        steps.push(Step {
            label: format!("Bölüm basamağı {qj} » sağdan {}. çubuk", from_right(rods, rq)),
            target: value(&b, cf),
            before,
            moves: e.moves,
            after: b.clone(),
        });
        // Subtract quotient digit × each divisor digit, shifting one rod right each time.
        for (i, &dk) in dd.iter().enumerate() {
            let p = qj * dk;
            if p == 0 {
                continue;
            }
            let rt = rq + 1 + i;
            let before = b.clone();
            let mut e = Engine::new(b);
            let ok = e.sub(rt, p / 10, 0) && e.sub(rt + 1, p % 10, 0);
            debug_assert!(ok);
            b = e.b;
            ops.extend(e.ops);
            steps.push(Step {
                label: format!(
                    "{qj} × {dk} = {p:02} » sağdan {}. ve {}. çubuktan çıkar",
                    from_right(rods, rt),
                    from_right(rods, rt + 1)
                ),
                target: value(&b, cf),
                before,
                moves: e.moves,
                after: b.clone(),
            });
        }
    }
    let mut pr = blank(Kind::Div, rods);
    pr.text = format!("{dividend} ÷ {d}");
    pr.terms = vec![dividend as i64, d as i64];
    pr.initial = initial;
    pr.check_from = cf;
    pr.ref_len = n;
    pr.expected = q * pow10(n as u32 + 1);
    pr.answer = q as i64;
    pr.units_rod = units;
    pr.steps = steps;
    pr.ops = ops;
    pr.par_ms = 5000.0 + 1300.0 * pr.moves() as f64;
    pr
}

/// The deterministic practice set of a level.
pub fn level_problems(level: u32) -> Vec<Problem> {
    let level = params(level);
    let sp = spec(level);
    let mut r = Rng::new(seed_for("soroban", level, 0));
    let rods = sp.rods;
    (0..sp.count)
        .map(|i| match sp.gen {
            Gen::Set { digits } => set_problem(num(&mut r, digits), vec![0; rods], rods),
            Gen::Read { digits } => read_problem(num(&mut r, digits), rods),
            Gen::Clear { digits } => {
                let t = num(&mut r, digits);
                if i % 2 == 0 {
                    let mut junk = num(&mut r, (3, 5));
                    if junk == t {
                        junk += 1;
                    }
                    set_problem(t, board_of(junk, rods), rods)
                } else {
                    read_problem(t, rods)
                }
            }
            Gen::Chain(c) => gen_chain(&mut r, &c, rods),
            Gen::Flash { terms, digits, signs, interval } => gen_flash(&mut r, terms, digits, signs, interval, rods),
            Gen::Mul(shapes) => gen_mul(&mut r, shapes, rods),
            Gen::Div(shapes) => gen_div(&mut r, shapes, rods),
            Gen::Anzan { terms, digits, signs, interval, .. } => gen_anzan(&mut r, terms, digits, signs, interval, rods),
        })
        .collect()
}

// ---------------------------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Phase {
    Lesson,
    Practice,
    Done,
}

#[derive(Clone, Debug)]
struct Feedback {
    serial: u32,
    correct: bool,
    given: String,
    answer: String,
    text: String,
    note: Option<String>,
}

pub struct Soroban {
    level: u32,
    spec: Spec,
    problems: Vec<Problem>,
    idx: usize,
    phase: Phase,
    board: Vec<u8>,
    step: usize,
    hint_on: bool,
    hints_used: u32,
    flash_t: f64,
    elapsed_ms: f64,
    par_ms: f64,
    correct: u32,
    wrong: u32,
    serial: u32,
    last: Option<Feedback>,
    stars: u32,
    won: bool,
}

pub fn create(level: u32, _mode: &str) -> Result<Box<dyn Session>, String> {
    Ok(Box::new(Soroban::new(level)))
}

fn clock(ms: f64) -> String {
    let s = (ms / 1000.0).ceil().max(0.0) as u64;
    format!("{}:{:02}", s / 60, s % 60)
}

fn place_name(rods: usize, rod: usize) -> String {
    const NAMES: [&str; 7] = ["Birler", "Onlar", "Yüzler", "Binler", "On binler", "Yüz binler", "Milyonlar"];
    let p = rods - 1 - rod;
    NAMES.get(p).map(|s| s.to_string()).unwrap_or_else(|| format!("Sağdan {}. çubuk", p + 1))
}

fn move_action(delta: i8) -> String {
    match delta {
        5 => "beşliği indir (+5)".into(),
        -5 => "beşliği kaldır (−5)".into(),
        d if d > 0 => format!("{d} birlik kaldır (+{d})"),
        d => format!("{} birlik indir (−{})", -d, -d),
    }
}

impl Soroban {
    pub fn new(level: u32) -> Self {
        let level = params(level);
        let spec = spec(level);
        let problems = level_problems(level);
        let par_secs: f64 = problems.iter().map(|p| p.par_ms).sum::<f64>() / 1000.0;
        let par_ms = (par_secs / 5.0).ceil() * 5000.0;
        let board = problems[0].initial.clone();
        let mut g = Soroban {
            level,
            spec,
            problems,
            idx: 0,
            phase: Phase::Lesson,
            board,
            step: 0,
            hint_on: false,
            hints_used: 0,
            flash_t: -LEAD_MS,
            elapsed_ms: 0.0,
            par_ms,
            correct: 0,
            wrong: 0,
            serial: 0,
            last: None,
            stars: 0,
            won: false,
        };
        g.load(0);
        g
    }

    fn cur(&self) -> Option<&Problem> {
        if self.phase == Phase::Practice {
            self.problems.get(self.idx)
        } else {
            None
        }
    }

    fn load(&mut self, i: usize) {
        self.idx = i;
        if let Some(p) = self.problems.get(i) {
            self.board = p.initial.clone();
        }
        self.step = 0;
        self.hint_on = false;
        self.flash_t = -LEAD_MS;
        self.advance();
    }

    /// Move the step pointer past every reference checkpoint the board now matches.
    fn advance(&mut self) {
        let Some(p) = self.problems.get(self.idx) else { return };
        if p.kind == Kind::Flash {
            return;
        }
        let v = value(&self.board, p.check_from);
        while self.step < p.steps.len() && v == p.steps[self.step].target {
            self.step += 1;
        }
    }

    fn guided(&self) -> bool {
        self.idx < self.spec.guided
    }

    fn flash_done(&self) -> bool {
        match self.cur() {
            Some(p) if p.kind.flashes() => self.flash_t >= p.interval_ms * p.terms.len() as f64,
            _ => true,
        }
    }

    fn hint_visible(&self) -> bool {
        matches!(self.cur(), Some(p) if p.kind.board_input() && p.kind != Kind::Flash) && (self.guided() || self.hint_on)
    }

    /// The next bead move: follows the reference solution while the board is on it, otherwise
    /// steers rod by rod toward the current step's result.
    fn next_move(&self) -> Option<Move> {
        let p = self.cur()?;
        let st = p.steps.get(self.step)?;
        let cf = p.check_from;
        let mut b = st.before.clone();
        let mut states = vec![b.clone()];
        for m in &st.moves {
            apply(&mut b, m);
            states.push(b.clone());
        }
        let on_path = (0..st.moves.len()).rev().find(|&k| states[k][cf..] == self.board[cf..]);
        match on_path {
            Some(k) => Some(st.moves[k].clone()),
            None => set_moves(&self.board, &st.after, cf).into_iter().next(),
        }
    }

    fn hint_json(&self) -> Value {
        if !self.hint_visible() {
            return Value::Null;
        }
        let Some(p) = self.cur() else { return Value::Null };
        let Some(m) = self.next_move() else { return Value::Null };
        let rods = self.board.len();
        let place = if matches!(p.kind, Kind::Mul | Kind::Div) {
            format!("Sağdan {}. çubuk", from_right(rods, m.rod))
        } else {
            place_name(rods, m.rod)
        };
        let mut text = format!("{place}: {}", move_action(m.delta));
        if m.carry {
            text.push_str(" · elde/ödünç");
        }
        let formula = if m.tech.is_none() && p.kind != Kind::Set {
            "Tahta yoldan çıktı: bu çubuğu düzelt".to_string()
        } else if matches!(p.kind, Kind::Mul | Kind::Div) && m.tech == Some(Tech::Direct) {
            // The step label already names the partial product; only complements need a formula.
            String::new()
        } else {
            m.formula.clone()
        };
        json!({
            "rod": m.rod,
            "bead": if m.delta.abs() == 5 { "heaven" } else { "earth" },
            "delta": m.delta,
            "text": text,
            "formula": formula,
            "tech": m.tech.map(|t| t.key()),
            "carry": m.carry,
        })
    }

    fn record(&mut self, ok: bool, given: String, note: Option<String>) {
        let p = &self.problems[self.idx];
        let answer = p.answer.to_string();
        let text = match p.kind {
            Kind::Set => "Kur".to_string(),
            Kind::Read => "Okuma".to_string(),
            _ => p.text.clone(),
        };
        if ok {
            self.correct += 1;
        } else {
            self.wrong += 1;
        }
        self.serial += 1;
        self.last = Some(Feedback { serial: self.serial, correct: ok, given, answer, text, note });
        if self.idx + 1 >= self.problems.len() {
            self.finish();
        } else {
            self.load(self.idx + 1);
        }
    }

    fn submit_board(&mut self) {
        let p = &self.problems[self.idx];
        let raw = value(&self.board, p.check_from);
        let ok = raw == p.expected;
        let mut note = None;
        if !ok && raw != 0 {
            let shifted = (1..8).any(|k| raw == p.expected.saturating_mul(pow10(k)) || p.expected == raw.saturating_mul(pow10(k)));
            if shifted {
                note = Some(match p.kind {
                    Kind::Div => "Rakamlar doğru, yeri kaymış: bölümün birleri işaretli çubukta".to_string(),
                    _ => "Rakamlar doğru, yeri kaymış: birler en sağ çubukta".to_string(),
                });
            }
        }
        let given = if p.kind == Kind::Div {
            let unit = pow10(p.ref_len as u32 + 1);
            if raw % unit == 0 {
                (raw / unit).to_string()
            } else {
                format!("{} (artık var)", raw / unit)
            }
        } else {
            raw.to_string()
        };
        self.record(ok, given, note);
    }

    fn finish(&mut self) {
        self.phase = Phase::Done;
        let n = self.problems.len() as f64;
        let acc = self.correct as f64 / n;
        self.stars = if acc < 0.7 - 1e-9 {
            0
        } else if acc >= 0.9 - 1e-9 && self.elapsed_ms <= self.par_ms && self.hints_used == 0 {
            3
        } else if acc >= 0.8 - 1e-9 {
            2
        } else {
            1
        };
        self.won = self.stars > 0;
    }

    fn status(&self) -> &'static str {
        match self.phase {
            Phase::Done if self.won => "won",
            Phase::Done => "lost",
            _ => "playing",
        }
    }

    fn summary(&self) -> String {
        let mut s = format!(
            "Doğru {}/{} · Süre {} · Hedef {}",
            self.correct,
            self.problems.len(),
            clock(self.elapsed_ms),
            clock(self.par_ms)
        );
        if self.hints_used > 0 {
            s.push_str(&format!(" · İpucu {}", self.hints_used));
        }
        s
    }

    fn flash_json(&self, p: &Problem) -> Value {
        if !p.kind.flashes() {
            return Value::Null;
        }
        let count = p.terms.len();
        let slot = p.interval_ms;
        let (index, val) = if self.flash_t < 0.0 {
            (-1i64, Value::Null)
        } else {
            let i = (self.flash_t / slot).floor() as usize;
            if i >= count {
                (count as i64, Value::Null)
            } else if self.flash_t - i as f64 * slot < slot * FLASH_ON {
                (i as i64, json!(p.terms[i]))
            } else {
                (i as i64, Value::Null)
            }
        };
        json!({
            "index": index,
            "count": count,
            "value": val,
            "done": self.flash_done(),
            "lead": self.flash_t < 0.0,
            "interval_ms": slot,
        })
    }

    fn problem_json(&self) -> Value {
        let Some(p) = self.cur() else { return Value::Null };
        let rods = self.board.len();
        let (ref_label, area_label) = match p.kind {
            Kind::Mul => (Some("Çarpılan"), Some("Çarpım")),
            Kind::Div => (Some("Bölen"), Some("Bölüm · bölünen")),
            _ => (None, None),
        };
        let step_label = if self.hint_visible() { p.steps.get(self.step).map(|s| s.label.clone()) } else { None };
        json!({
            "kind": p.kind.key(),
            "input": if p.kind.board_input() { "board" } else { "typed" },
            "text": if p.kind.flashes() { String::new() } else { p.text.clone() },
            "prompt": p.kind.prompt(),
            "terms": if p.terms.is_empty() || p.kind.flashes() || matches!(p.kind, Kind::Mul | Kind::Div) { Value::Null } else { json!(p.terms) },
            "step": self.step,
            "steps": p.steps.len(),
            "step_label": step_label,
            "ref_len": p.ref_len,
            "check_from": p.check_from,
            "units_rod": if matches!(p.kind, Kind::Mul | Kind::Div) { json!(p.units_rod) } else { Value::Null },
            "ref_label": ref_label,
            "area_label": area_label,
            "flash": self.flash_json(p),
            "rods": rods,
        })
    }
}

impl Session for Soroban {
    fn state(&self) -> Value {
        let p = self.cur();
        let kind = p.map(|p| p.kind);
        let hidden = matches!(kind, Some(Kind::Anzan | Kind::FlashAnzan));
        let ghost = match p {
            Some(p) if hidden => {
                let Gen::Anzan { ghost: (g0, g1), .. } = self.spec.gen else { unreachable!() };
                let t = if self.problems.len() > 1 { self.idx as f64 / (self.problems.len() - 1) as f64 } else { 0.0 };
                let op = g0 + (g1 - g0) * t;
                if op > 0.005 {
                    json!({"opacity": op, "rods": p.ghost.clone().unwrap_or_default()})
                } else {
                    Value::Null
                }
            }
            _ => Value::Null,
        };
        let interactive = self.phase == Phase::Practice && kind.is_some_and(|k| k.board_input());
        let last = self.last.as_ref().map(|f| {
            json!({"serial": f.serial, "correct": f.correct, "given": f.given, "answer": f.answer,
                   "text": f.text, "note": f.note})
        });
        json!({
            "status": self.status(),
            "stars": self.stars,
            "level": self.level,
            "title": self.spec.section,
            "goal": format!(
                "{} soru · ★★★: %90 doğru, {} altı, ipucusuz",
                self.problems.len(),
                clock(self.par_ms)
            ),
            "summary": if self.phase == Phase::Done { Some(self.summary()) } else { None },
            "phase": match self.phase { Phase::Lesson => "lesson", Phase::Practice => "practice", Phase::Done => "done" },
            "section": self.spec.section,
            "lesson": {"title": self.spec.title, "text": self.spec.lesson},
            "rods_count": self.board.len(),
            "rods": if hidden { vec![0u8; self.board.len()] } else { self.board.clone() },
            "show_values": self.spec.show_values && kind != Some(Kind::Read),
            "interactive": interactive,
            "abacus": if hidden { "hidden" } else { "visible" },
            "ghost": ghost,
            "problem": self.problem_json(),
            "index": self.idx,
            "total": self.problems.len(),
            "correct": self.correct,
            "wrong": self.wrong,
            "elapsed_ms": self.elapsed_ms.round(),
            "par_ms": self.par_ms,
            "guided": self.phase == Phase::Practice && self.guided() && self.hint_visible(),
            "hint_on": self.hint_on,
            "hints_used": self.hints_used,
            "hint": self.hint_json(),
            "last": last,
        })
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if self.phase == Phase::Done {
            return Err("Bölüm bitti".into());
        }
        if a["start"].as_bool() == Some(true) {
            if self.phase != Phase::Lesson {
                return Err("Ders zaten başladı".into());
            }
            self.phase = Phase::Practice;
            self.load(0);
            return Ok(());
        }
        if self.phase == Phase::Lesson {
            return Err("Önce Başla'ya dokun".into());
        }
        let p = self.problems[self.idx].clone();
        let board_input = p.kind.board_input();

        if a["hint"].as_bool() == Some(true) {
            if !board_input || p.kind == Kind::Flash {
                return Err("Bu soruda ipucu yok".into());
            }
            if !self.guided() && !self.hint_on {
                self.hint_on = true;
                self.hints_used += 1;
            }
            return Ok(());
        }

        // Validate everything before touching the state.
        let new_rods: Option<Vec<u8>> = if a["rods"].is_null() {
            None
        } else {
            if !board_input {
                return Err("Bu soruda boncuklar kilitli".into());
            }
            let arr = a["rods"].as_array().ok_or("rods bir liste olmalı")?;
            if arr.len() != self.board.len() {
                return Err("Çubuk sayısı uymuyor".into());
            }
            let mut v = Vec::with_capacity(arr.len());
            for x in arr {
                match x.as_u64() {
                    Some(d) if d <= 9 => v.push(d as u8),
                    _ => return Err("Her çubuk 0–9 arası olmalı".into()),
                }
            }
            Some(v)
        };
        let clear = a["clear"].as_bool() == Some(true);
        let reset = a["reset"].as_bool() == Some(true);
        if (clear || reset) && !board_input {
            return Err("Bu soruda boncuklar kilitli".into());
        }
        let submit = a["submit"].as_bool() == Some(true);
        let answer = &a["answer"];
        if submit {
            if !board_input {
                return Err("Cevabı yazarak ver".into());
            }
            if !self.flash_done() {
                return Err("Önce bütün sayıları izle".into());
            }
        }
        let typed: Option<i64> = if answer.is_null() {
            None
        } else {
            if board_input {
                return Err("Cevabı abaküste göster ve Tamam'a dokun".into());
            }
            if !self.flash_done() {
                return Err("Önce bütün sayıları izle".into());
            }
            let v = if let Some(x) = answer.as_i64() {
                Some(x)
            } else {
                let s: String = answer.as_str().unwrap_or("").chars().filter(|c| !c.is_whitespace() && *c != '.').collect();
                if s.is_empty() {
                    return Err("Önce cevabını yaz".into());
                }
                s.replace('−', "-").parse::<i64>().ok()
            };
            Some(v.ok_or("Geçerli bir sayı yaz")?)
        };
        if new_rods.is_none() && !clear && !reset && !submit && typed.is_none() {
            return Err("Bilinmeyen hamle".into());
        }

        if reset {
            self.board = p.initial.clone();
            self.step = 0;
        }
        if clear {
            for d in &mut self.board[p.check_from..] {
                *d = 0;
            }
            self.step = 0;
        }
        if let Some(v) = new_rods {
            self.board = v;
        }
        self.advance();
        if submit {
            self.submit_board();
        } else if let Some(x) = typed {
            self.record(x == p.answer, x.to_string(), None);
        }
        Ok(())
    }

    fn tick(&mut self, dt_ms: f64) {
        if self.phase != Phase::Practice || dt_ms.is_nan() || dt_ms <= 0.0 {
            return;
        }
        self.elapsed_ms += dt_ms;
        if self.problems[self.idx].kind.flashes() {
            self.flash_t += dt_ms;
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn started(level: u32) -> Soroban {
        let mut g = Soroban::new(level);
        g.act(&json!({"start": true})).unwrap();
        g
    }

    /// Replays a problem's reference solution, checking every bead move and checkpoint.
    fn replay(p: &Problem) -> Vec<u8> {
        let mut b = p.initial.clone();
        for st in &p.steps {
            assert_eq!(b[p.check_from..], st.before[p.check_from..], "step start mismatch in {}", p.text);
            for m in &st.moves {
                assert!(m.rod >= p.check_from, "move touches the reference area in {}", p.text);
                assert!(move_ok(&b, m.rod, m.delta), "illegal move {:?} on {:?} in {}", m, b, p.text);
                apply(&mut b, m);
            }
            assert_eq!(value(&b, p.check_from), st.target, "{}: {}", p.text, st.label);
            assert_eq!(b, st.after);
        }
        b
    }

    #[test]
    fn engine_examples_from_the_lessons() {
        let run = |start: u64, t: u64, add: bool| {
            let mut e = Engine::new(board_of(start, 5));
            assert!(e.number(4, t, add));
            (value(&e.b, 0), e.ops.clone(), e.moves.clone())
        };
        let (v, ops, moves) = run(3, 4, true);
        assert_eq!(v, 7);
        assert_eq!(ops[0].tech, Tech::Small);
        assert_eq!(moves.iter().map(|m| m.delta).collect::<Vec<_>>(), vec![5, -1]);
        assert_eq!(moves[0].formula, "+4 = +5 − 1");
        let (v, ops, _) = run(6, 4, false);
        assert_eq!((v, ops[0].tech), (2, Tech::Small));
        let (v, ops, moves) = run(7, 9, true);
        assert_eq!((v, ops[0].tech), (16, Tech::Big));
        assert_eq!(moves[0].formula, "+9 = +10 − 1");
        let (v, ops, moves) = run(5, 6, true);
        assert_eq!((v, ops[0].tech), (11, Tech::Mixed));
        assert_eq!(moves.iter().map(|m| m.delta).collect::<Vec<_>>(), vec![1, -5, 1]);
        assert_eq!(moves[0].formula, "+6 = +10 − 5 + 1");
        let (v, ops, moves) = run(14, 6, false);
        assert_eq!((v, ops[0].tech), (8, Tech::Mixed));
        assert_eq!(moves[0].formula, "−6 = −10 + 5 − 1");
        let (v, ops, _) = run(97, 5, true);
        assert_eq!(v, 102);
        assert!(ops.iter().any(|o| Focus::Cascade.matches(o)));
        let (v, ops, _) = run(103, 5, false);
        assert_eq!(v, 98);
        assert!(ops.iter().any(|o| Focus::Cascade.matches(o)));
        let (v, _, _) = run(34, 23, true);
        assert_eq!(v, 57);
    }

    #[test]
    fn engine_exhaustive_single_digits() {
        // Every rod value × every digit, both directions: the reference moves are legal and right.
        for start in 0..100u64 {
            for d in 1..=9u64 {
                for add in [true, false] {
                    if !add && d > start {
                        continue;
                    }
                    let mut b = board_of(start, 4);
                    let mut e = Engine::new(b.clone());
                    assert!(e.number(3, d, add));
                    for m in &e.moves {
                        assert!(move_ok(&b, m.rod, m.delta));
                        apply(&mut b, m);
                    }
                    let want = if add { start + d } else { start - d };
                    assert_eq!(value(&b, 0), want);
                }
            }
        }
    }

    #[test]
    fn every_level_generates_and_reference_solutions_replay() {
        for level in 1..=50 {
            let sp = spec(level);
            let ps = level_problems(level);
            assert_eq!(ps.len(), sp.count);
            for p in &ps {
                assert_eq!(p.initial.len(), sp.rods);
                if p.kind.board_input() {
                    let b = replay(p);
                    assert_eq!(value(&b, p.check_from), p.expected, "level {level}: {}", p.text);
                }
                if !p.terms.is_empty() && !matches!(p.kind, Kind::Mul | Kind::Div) {
                    assert_eq!(p.terms.iter().sum::<i64>(), p.answer);
                    let mut run = 0;
                    for &t in &p.terms {
                        run += t;
                        assert!(run >= 0, "negative running total in {}", p.text);
                    }
                }
                assert!(p.par_ms > 0.0);
            }
        }
    }

    #[test]
    fn levels_clamp_to_fifty() {
        assert_eq!(params(51), 50);
        assert_eq!(params(500), 50);
        assert_eq!(params(0), 1);
        for level in [51, 137, 500] {
            let a = level_problems(level);
            let b = level_problems(50);
            assert_eq!(a.len(), b.len());
            for (x, y) in a.iter().zip(&b) {
                assert_eq!(x.text, y.text);
            }
            let g = Soroban::new(level);
            assert_eq!(g.state()["level"], 50);
        }
    }

    #[test]
    fn deterministic() {
        for level in [1, 5, 11, 24, 30, 36, 40, 45, 50] {
            let a = level_problems(level);
            let b = level_problems(level);
            for (x, y) in a.iter().zip(&b) {
                assert_eq!(x.text, y.text);
                assert_eq!(x.initial, y.initial);
                assert_eq!(x.expected, y.expected);
            }
        }
        // Different levels give different sets.
        let texts = |l: u32| level_problems(l).iter().map(|p| p.text.clone()).collect::<Vec<_>>();
        assert_ne!(texts(11), texts(12));
    }

    #[test]
    fn chain_levels_respect_technique_rules() {
        for level in 6..=30 {
            let Gen::Chain(c) = spec(level).gen else { panic!("level {level} is not a chain") };
            for p in level_problems(level) {
                for o in &p.ops {
                    let ok = if o.add { c.add_ok } else { c.sub_ok };
                    assert!(ok & o.tech.bit() != 0, "level {level}: {:?} not allowed in {}", o, p.text);
                }
                let f = p.ops.iter().filter(|o| c.focus.matches(o)).count();
                assert!(f >= c.need, "level {level}: only {f} focus ops in {}", p.text);
            }
        }
    }

    #[test]
    fn complement_levels_need_their_technique() {
        let has = |level: u32, pred: &dyn Fn(&Op) -> bool| {
            for p in level_problems(level) {
                assert!(p.ops.iter().any(pred), "level {level}: {} lacks the technique", p.text);
            }
        };
        // Small friends: +4/+3, +2/+1, −4/−3, −2/−1.
        has(11, &|o| o.tech == Tech::Small && o.add && [4, 3].contains(&o.digit));
        has(12, &|o| o.tech == Tech::Small && o.add && [2, 1].contains(&o.digit));
        has(13, &|o| o.tech == Tech::Small && !o.add && [4, 3].contains(&o.digit));
        has(14, &|o| o.tech == Tech::Small && !o.add && [2, 1].contains(&o.digit));
        // Big friends.
        has(17, &|o| o.tech == Tech::Big && o.add && o.depth == 0 && [9, 8].contains(&o.digit));
        has(20, &|o| o.tech == Tech::Big && !o.add && o.depth == 0 && [9, 8].contains(&o.digit));
        has(24, &|o| o.depth >= 1 && o.tech == Tech::Big);
        // Mixed.
        has(25, &|o| o.tech == Tech::Mixed && o.add);
        has(26, &|o| o.tech == Tech::Mixed && !o.add);
        // Small-friend levels never need a 10-complement; big-friend levels never a mixed one.
        for level in 11..=16 {
            for p in level_problems(level) {
                assert!(p.ops.iter().all(|o| o.tech <= Tech::Small), "level {level}: {}", p.text);
            }
        }
        for level in 17..=24 {
            for p in level_problems(level) {
                assert!(p.ops.iter().all(|o| o.tech != Tech::Mixed), "level {level}: {}", p.text);
            }
        }
        // Direct levels are direct only.
        for level in 6..=10 {
            for p in level_problems(level) {
                assert!(p.ops.iter().all(|o| o.tech == Tech::Direct), "level {level}: {}", p.text);
            }
        }
    }

    #[test]
    fn multiplication_problems_are_valid() {
        for level in 37..=41 {
            let Gen::Mul(shapes) = spec(level).gen else { panic!() };
            for p in level_problems(level) {
                let (a, b) = (p.terms[0] as u64, p.terms[1] as u64);
                assert!(shapes.contains(&(ndigits(a), ndigits(b))), "{}", p.text);
                assert_eq!(p.expected, a * b);
                assert_eq!(p.answer as u64, a * b);
                // Multiplicand preset on the left, product field right-aligned.
                assert_eq!(value(&p.initial[..p.ref_len], 0), a);
                assert_eq!(value(&p.initial, p.check_from), 0);
                let fin = replay(&p);
                assert_eq!(fin[..p.ref_len], p.initial[..p.ref_len]);
                assert_eq!(value(&fin, p.check_from), a * b);
            }
        }
    }

    #[test]
    fn division_problems_are_valid() {
        for level in 42..=45 {
            for p in level_problems(level) {
                let (dividend, d) = (p.terms[0] as u64, p.terms[1] as u64);
                assert_eq!(dividend % d, 0, "{}", p.text);
                let q = dividend / d;
                assert_eq!(p.answer as u64, q);
                assert!(ndigits(dividend) <= 4);
                assert_eq!(value(&p.initial[..p.ref_len], 0), d);
                assert_eq!(value(&p.initial, p.check_from), dividend);
                // Quotient units on the marked rod, dividend fully cleared.
                let fin = replay(&p);
                assert_eq!(value(&fin, p.check_from), q * pow10(p.ref_len as u32 + 1));
                assert_eq!(value(&fin[..=p.units_rod], p.check_from), q);
                assert!(fin[p.units_rod + 1..].iter().all(|&x| x == 0));
            }
        }
        // The lesson's examples.
        let lesson = |dividend: u64, d: u64| {
            let rods = 11;
            let n = ndigits(d) as usize;
            let units = rods - 1 - (n + 1);
            let mut b = board_of(dividend, rods);
            b[..n].copy_from_slice(&digits_of(d));
            (units, b)
        };
        let (units, _) = lesson(84, 4);
        assert_eq!(units, 8);
        let (units, _) = lesson(672, 32);
        assert_eq!(units, 7);
    }

    /// Solve every problem through the public protocol, following the live hint for board
    /// problems (exercises step tracking and hints) and typing answers otherwise.
    fn solve(level: u32, use_hints: bool) -> Soroban {
        let mut g = started(level);
        while g.phase == Phase::Practice {
            let p = g.problems[g.idx].clone();
            if p.kind.flashes() {
                assert!(g.act(&json!({"submit": true, "answer": 0})).is_err());
                while !g.flash_done() {
                    g.tick(100.0);
                }
            }
            if p.kind.board_input() {
                if use_hints && p.kind != Kind::Flash {
                    g.act(&json!({"hint": true})).unwrap();
                    let mut guard = 0;
                    while g.step < p.steps.len() {
                        let h = g.state()["hint"].clone();
                        assert!(!h.is_null(), "level {level}: no hint for {}", p.text);
                        let rod = h["rod"].as_u64().unwrap() as usize;
                        let delta = h["delta"].as_i64().unwrap() as i8;
                        assert!(move_ok(&g.board, rod, delta));
                        let mut b = g.board.clone();
                        b[rod] = (b[rod] as i8 + delta) as u8;
                        g.act(&json!({"rods": b})).unwrap();
                        guard += 1;
                        assert!(guard < 300);
                    }
                    g.act(&json!({"submit": true})).unwrap();
                } else {
                    let mut b = g.board.clone();
                    let want = board_of(p.expected, b.len() - p.check_from);
                    b[p.check_from..].copy_from_slice(&want);
                    g.act(&json!({"rods": b, "submit": true})).unwrap();
                }
            } else {
                g.act(&json!({"answer": p.answer})).unwrap();
            }
            assert_eq!(g.last.as_ref().unwrap().correct, true, "level {level}: {}", p.text);
        }
        g
    }

    #[test]
    fn following_hints_solves_every_level() {
        for level in 1..=50 {
            let g = solve(level, true);
            assert_eq!(g.status(), "won");
            assert_eq!(g.correct as usize, g.problems.len());
        }
    }

    #[test]
    fn perfect_fast_play_gives_three_stars() {
        for level in [1, 3, 5, 11, 24, 31, 37, 44, 46, 50] {
            let g = solve(level, false);
            assert_eq!(g.state()["status"], "won");
            assert_eq!(g.stars, 3, "level {level}");
        }
        // Using a hint outside guided problems caps the stars at 2.
        let g = solve(9, true);
        assert_eq!(g.stars, 2);
        assert!(g.hints_used > 0);
        // Guided problems are free.
        let mut g = started(11);
        g.act(&json!({"hint": true})).unwrap();
        assert_eq!(g.hints_used, 0);
        assert!(!g.state()["hint"].is_null());
    }

    #[test]
    fn slow_or_inaccurate_play_loses_stars() {
        // Too slow: 2 stars.
        let mut g = started(2);
        g.tick(g.par_ms + 1000.0);
        while g.phase == Phase::Practice {
            let p = g.problems[g.idx].clone();
            g.act(&json!({"rods": board_of(p.expected, 7), "submit": true})).unwrap();
        }
        assert_eq!((g.status(), g.stars), ("won", 2));
        // 7/10 right: 1 star; 6/10: lost.
        for (right, status, stars) in [(7, "won", 1), (8, "won", 2), (6, "lost", 0)] {
            let mut g = started(3);
            let mut i = 0;
            while g.phase == Phase::Practice {
                let ans = g.problems[g.idx].answer;
                g.act(&json!({"answer": if i < right { ans } else { ans + 1 }})).unwrap();
                i += 1;
            }
            assert_eq!((g.status(), g.stars), (status, stars), "right {right}");
            assert!(g.state()["summary"].as_str().unwrap().contains(&format!("{right}/10")));
        }
    }

    #[test]
    fn checking_set_rods_and_anzan() {
        // Set: the rods must show the number.
        let mut g = started(4);
        let p = g.problems[0].clone();
        g.act(&json!({"rods": board_of(p.expected + 1, 7)})).unwrap();
        g.act(&json!({"submit": true})).unwrap();
        assert!(!g.last.as_ref().unwrap().correct);
        assert_eq!(g.wrong, 1);
        // Calc: final board must equal the result; step tracking follows the terms.
        let mut g = started(17);
        let p = g.problems[0].clone();
        assert_eq!(g.step, 0);
        g.act(&json!({"rods": board_of(p.steps[0].target, 9)})).unwrap();
        assert_eq!(g.step, 1);
        g.act(&json!({"reset": true})).unwrap();
        assert_eq!(g.step, 0);
        assert_eq!(g.board, p.initial);
        g.act(&json!({"clear": true})).unwrap();
        assert!(g.board.iter().all(|&d| d == 0));
        g.act(&json!({"rods": board_of(p.expected, 9), "submit": true})).unwrap();
        assert!(g.last.as_ref().unwrap().correct);
        // Multiplication: right digits on the wrong rods are wrong (placement is checked).
        let mut g = started(37);
        let p = g.problems[0].clone();
        let mut b = p.initial.clone();
        let rods = p.initial.len();
        let shifted = board_of(p.expected * 10, rods - p.check_from);
        b[p.check_from..].copy_from_slice(&shifted);
        g.act(&json!({"rods": b, "submit": true})).unwrap();
        let fb = g.last.clone().unwrap();
        assert!(!fb.correct);
        assert!(fb.note.is_some());
        // Ignoring the reference area: clearing the multiplicand doesn't matter.
        let p = g.problems[1].clone();
        let mut b = vec![0u8; rods];
        b[p.check_from..].copy_from_slice(&board_of(p.expected, rods - p.check_from));
        g.act(&json!({"rods": b, "submit": true})).unwrap();
        assert!(g.last.as_ref().unwrap().correct);
        // Division: quotient on the units-marked rod.
        let mut g = started(42);
        let p = g.problems[0].clone();
        let mut b = p.initial.clone();
        let rods = p.initial.len();
        b[p.check_from..].copy_from_slice(&board_of(p.answer as u64 * 100, rods - p.check_from));
        g.act(&json!({"rods": b, "submit": true})).unwrap();
        assert!(g.last.as_ref().unwrap().correct);
        assert_eq!(g.last.as_ref().unwrap().given, p.answer.to_string());
        // Anzan: typed, string answers accepted, abacus hidden.
        let mut g = started(46);
        let st = g.state();
        assert_eq!(st["abacus"], "hidden");
        assert!(!st["ghost"].is_null());
        assert!(st["rods"].as_array().unwrap().iter().all(|x| x == 0));
        let ans = g.problems[0].answer;
        g.act(&json!({"answer": ans.to_string()})).unwrap();
        assert!(g.last.as_ref().unwrap().correct);
        g.act(&json!({"answer": 9999})).unwrap();
        assert!(!g.last.as_ref().unwrap().correct);
        // Ghost fades out over the set.
        let mut g = started(47);
        let first = g.state()["ghost"]["opacity"].as_f64().unwrap();
        for _ in 0..5 {
            let a = g.problems[g.idx].answer;
            g.act(&json!({"answer": a})).unwrap();
        }
        let later = g.state()["ghost"]["opacity"].as_f64().unwrap_or(0.0);
        assert!(later < first);
    }

    #[test]
    fn flash_reveals_numbers_one_by_one() {
        let mut g = started(31);
        let p = g.problems[0].clone();
        let st = g.state();
        assert_eq!(st["problem"]["flash"]["lead"], true);
        assert!(st["problem"]["terms"].is_null());
        assert_eq!(st["problem"]["text"], "");
        g.tick(LEAD_MS + 10.0);
        assert_eq!(g.state()["problem"]["flash"]["value"], p.terms[0]);
        g.tick(p.interval_ms * 0.85);
        assert!(g.state()["problem"]["flash"]["value"].is_null()); // blank gap
        g.tick(p.interval_ms * 0.2);
        assert_eq!(g.state()["problem"]["flash"]["value"], p.terms[1]);
        assert!(g.act(&json!({"submit": true})).is_err());
        assert!(g.act(&json!({"hint": true})).is_err());
        // Beads may move while numbers flash.
        g.act(&json!({"rods": board_of(p.terms[0] as u64, 9)})).unwrap();
        g.tick(p.interval_ms * p.terms.len() as f64);
        assert_eq!(g.state()["problem"]["flash"]["done"], true);
        g.act(&json!({"rods": board_of(p.expected, 9), "submit": true})).unwrap();
        assert!(g.last.as_ref().unwrap().correct);
        // Flash anzan: typed, also blocked until the flash ends.
        let mut g = started(48);
        let ans = g.problems[0].answer;
        assert!(g.act(&json!({"answer": ans})).is_err());
        g.tick(30_000.0);
        g.act(&json!({"answer": ans})).unwrap();
        assert!(g.last.as_ref().unwrap().correct);
    }

    #[test]
    fn illegal_actions_rejected_and_state_unchanged() {
        let mut g = Soroban::new(6);
        assert!(g.act(&json!({"rods": [0, 0, 0, 0, 0, 0, 1]})).is_err()); // still in the lesson
        g.act(&json!({"start": true})).unwrap();
        assert!(g.act(&json!({"start": true})).is_err());
        let before = g.state();
        assert!(g.act(&json!({"rods": [1, 2, 3]})).is_err());
        assert!(g.act(&json!({"rods": [0, 0, 0, 0, 0, 0, 12]})).is_err());
        assert!(g.act(&json!({"rods": "x"})).is_err());
        assert!(g.act(&json!({"answer": 5})).is_err());
        assert!(g.act(&json!({"rods": [0, 0, 0, 0, 0, 0, 1], "answer": 5})).is_err());
        assert!(g.act(&json!({"bogus": true})).is_err());
        assert_eq!(g.state(), before);
        // Reading problems: beads are locked, an empty answer is rejected.
        let mut g = started(3);
        let before = g.state();
        assert!(g.act(&json!({"rods": [0, 0, 0, 0, 0, 0, 1]})).is_err());
        assert!(g.act(&json!({"clear": true})).is_err());
        assert!(g.act(&json!({"submit": true})).is_err());
        assert!(g.act(&json!({"answer": ""})).is_err());
        assert!(g.act(&json!({"answer": "abc"})).is_err());
        assert!(g.act(&json!({"hint": true})).is_err());
        assert_eq!(g.state(), before);
        assert_eq!(before["show_values"], false); // never give the reading away
        // Finished levels reject everything.
        let mut g = solve(1, false);
        assert!(g.act(&json!({"submit": true})).is_err());
    }

    #[test]
    fn hint_recovers_when_the_board_leaves_the_path() {
        let mut g = started(25);
        g.act(&json!({"hint": true})).unwrap();
        let p = g.problems[0].clone();
        // Scramble the board, then follow hints back to the first checkpoint and beyond.
        let mut junk = g.board.clone();
        junk[0] = 3;
        g.act(&json!({"rods": junk})).unwrap();
        let mut guard = 0;
        while g.step < p.steps.len() {
            let h = g.state()["hint"].clone();
            let rod = h["rod"].as_u64().unwrap() as usize;
            let delta = h["delta"].as_i64().unwrap() as i8;
            let mut b = g.board.clone();
            assert!(move_ok(&b, rod, delta));
            b[rod] = (b[rod] as i8 + delta) as u8;
            g.act(&json!({"rods": b})).unwrap();
            guard += 1;
            assert!(guard < 200);
        }
        g.act(&json!({"submit": true})).unwrap();
        assert!(g.last.as_ref().unwrap().correct);
    }

    #[test]
    fn lesson_card_and_state_shape() {
        for level in 1..=50 {
            let g = Soroban::new(level);
            let st = g.state();
            assert_eq!(st["phase"], "lesson");
            assert_eq!(st["status"], "playing");
            assert!(st["lesson"]["title"].as_str().unwrap().len() > 3);
            assert!(st["lesson"]["text"].as_str().unwrap().len() > 30);
            assert!(st["goal"].as_str().unwrap().contains("soru"));
            let rods = st["rods_count"].as_u64().unwrap();
            assert!((7..=13).contains(&rods));
            let g = started(level);
            assert!(!g.state()["problem"].is_null());
        }
    }

    #[test]
    #[ignore]
    fn dump_course() {
        for level in 1..=50 {
            let sp = spec(level);
            let g = Soroban::new(level);
            let ps = level_problems(level);
            let sample: Vec<String> = ps.iter().take(3).map(|p| format!("{} = {}", p.text, p.answer)).collect();
            println!("{level:>2} {:<16} {:<44} par {} | {}", sp.section, sp.title, clock(g.par_ms), sample.join(" | "));
        }
    }

    #[test]
    #[ignore]
    fn timing_all_levels() {
        let t = std::time::Instant::now();
        let mut worst = 0f64;
        for level in 1..=50 {
            let s = std::time::Instant::now();
            let _ = Soroban::new(level);
            worst = worst.max(s.elapsed().as_secs_f64());
        }
        println!("soroban: 50 levels in {:?}, worst {:.3} ms", t.elapsed(), worst * 1000.0);
    }
}
