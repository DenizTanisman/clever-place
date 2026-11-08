//! Mental Aritmetik — fast mental arithmetic, named tricks and practical everyday math.
//!
//! A level is a fixed set of 10–20 questions with a time budget. Every question has a `kind`
//! (speed arithmetic, a trick, or a practical type) and a difficulty tier 0..=9.
//!
//! Level curve (`plan(level)`):
//! - 1..=30: curriculum. Speed warm-ups interleaved with one *introduction* level per trick or
//!   practical type (state carries a `trick` card explaining it), then review mixes at 10/20/29/30.
//! - 31..=500: a 10-level cycle — speed mix, trick focus, practical mix, ×÷ speed, trick mix,
//!   practical focus, +− speed, trick focus, practical mix, grand mix. Focus levels rotate through
//!   every trick/practical type and show the card again as a refresher.
//! - Tier = `(level-1)*10/480` (0 for 1..=48 … 9 from 433), the last third of a level is one tier
//!   harder; question count grows 10 → 20; par time tightens from 100% to 80% of the summed
//!   per-question par seconds. Budget (hard limit) = 1.6 × summed par seconds.
//! - Stars: ≥95% correct and finished under par → 3; ≥80% → 2; ≥60% → 1; otherwise `lost`.
//!   Time running out ends the level; unanswered questions count as wrong.
//!
//! Endless ("Sprint"): 60 s, adaptive. A hidden skill value starts at 1.0, rises on every correct
//! answer (more on streaks) and drops on mistakes; tier = floor(skill). `score` = points, where a
//! question is worth `10 + 4·tier + kind bonus`, plus a streak bonus of 10% per streak step
//! (capped at +50%). Time up → `lost` (normal end of a sprint).
//!
//! State: `{status, stars, mode, phase: "intro"|"play"|"done", title, goal, summary?, score,
//!          trick: {kind,label,title,text}|null, question: {kind,label,prompt,text,unit}|null,
//!          index, total|null, correct, wrong, skipped, streak, best_streak, elapsed_ms, limit_ms,
//!          remaining_ms, par_ms|null, tier, last: {serial,correct,skipped,given,answer,text,points}|null}`
//! Actions: `{"start":true}` · `{"answer":"12,5"}` (string or number; comma or dot decimals) ·
//!          `{"skip":true}`

use crate::rng::{seed_for, time_seed, Rng};
use crate::Session;
use serde_json::{json, Value};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Add,
    Sub,
    Mul,
    Div,
    Chain,
    Mul11,
    Mul5,
    Mul9,
    Mul25,
    Square5,
    Near100,
    Equidistant,
    DoubleHalve,
    LeftAdd,
    ComplementSub,
    Divisibility,
    PowersSquares,
    PercentOf,
    PercentChange,
    Discount,
    VatTip,
    FracDecPct,
    Units,
    Change,
    Growth,
    Estimate,
    Average,
}

use Kind::*;

pub const SPEED: &[Kind] = &[Add, Sub, Mul, Div, Chain];
pub const TRICKS: &[Kind] = &[
    Mul11, Mul5, Mul9, Mul25, Square5, Near100, Equidistant, DoubleHalve, LeftAdd, ComplementSub, Divisibility,
    PowersSquares,
];
pub const PRACTICAL: &[Kind] =
    &[PercentOf, PercentChange, Discount, VatTip, FracDecPct, Units, Change, Growth, Estimate, Average];

impl Kind {
    pub fn key(self) -> &'static str {
        match self {
            Add => "add",
            Sub => "sub",
            Mul => "mul",
            Div => "div",
            Chain => "chain",
            Mul11 => "mul11",
            Mul5 => "mul5",
            Mul9 => "mul9",
            Mul25 => "mul25",
            Square5 => "square5",
            Near100 => "near100",
            Equidistant => "equidistant",
            DoubleHalve => "double_halve",
            LeftAdd => "left_add",
            ComplementSub => "complement_sub",
            Divisibility => "divisibility",
            PowersSquares => "powers_squares",
            PercentOf => "percent_of",
            PercentChange => "percent_change",
            Discount => "discount",
            VatTip => "vat_tip",
            FracDecPct => "frac_dec_pct",
            Units => "units",
            Change => "change",
            Growth => "growth",
            Estimate => "estimate",
            Average => "average",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Add => "Toplama",
            Sub => "Çıkarma",
            Mul => "Çarpma",
            Div => "Bölme",
            Chain => "İşlem zinciri",
            Mul11 => "×11 hilesi",
            Mul5 => "×5 hilesi",
            Mul9 => "×9 hilesi",
            Mul25 => "×25 hilesi",
            Square5 => "5 ile biten kare",
            Near100 => "100'e yakın çarpım",
            Equidistant => "Ortadan uzaklık",
            DoubleHalve => "İkile-yarıla",
            LeftAdd => "Soldan sağa toplama",
            ComplementSub => "Tamamlayanla çıkarma",
            Divisibility => "Bölünebilme",
            PowersSquares => "Kuvvetler ve kareler",
            PercentOf => "Yüzde",
            PercentChange => "Yüzde değişim",
            Discount => "İndirim",
            VatTip => "KDV ve bahşiş",
            FracDecPct => "Kesir · ondalık · yüzde",
            Units => "Birim çevirme",
            Change => "Para üstü",
            Growth => "Bileşik büyüme",
            Estimate => "Tahmin",
            Average => "Ortalama",
        }
    }

    /// Short Turkish explanation shown on the card before an introduction / focus level.
    /// Every worked example here is checked in the tests.
    pub fn trick(self) -> Option<(&'static str, &'static str)> {
        Some(match self {
            Mul11 => (
                "×11: araya toplamı yaz",
                "İki basamaklı sayıyı 11'le çarparken rakamları ayır, araya toplamlarını yaz.\n36 × 11 → 3 | 3+6 | 6 = 396.\nToplam 10 veya fazlaysa eldeyi soldakine ekle: 78 × 11 → 7 | 15 | 8 → 858.\nÜç basamakta komşuları topla: 243 × 11 → 2 | 6 | 7 | 3 = 2673.",
            ),
            Mul5 => (
                "×5: on katı, sonra yarısı",
                "5 = 10 ÷ 2. Sayıyı 10'la çarp, sonra yarıla.\n486 × 5 → 4860 ÷ 2 = 2430.\n73 × 5 → 730 ÷ 2 = 365.\n÷5 için tersi: 2 ile çarp, 10'a böl: 435 ÷ 5 → 870 ÷ 10 = 87.",
            ),
            Mul9 => (
                "×9: on katından kendisini çıkar",
                "9 = 10 − 1. Sayıyı 10'la çarp, sonra kendisini çıkar.\n67 × 9 → 670 − 67 = 603.\n99 ve 999 de aynı: 48 × 99 → 4800 − 48 = 4752.",
            ),
            Mul25 => (
                "×25: yüz katının çeyreği",
                "25 = 100 ÷ 4. Sayıyı 100'le çarp, 4'e böl.\n36 × 25 → 3600 ÷ 4 = 900.\nÖnce 4'e bölmek kolaysa böl: 84 × 25 → 21 × 100 = 2100.\n÷25 için: 4 ile çarp, 100'e böl: 1300 ÷ 25 → 5200 ÷ 100 = 52.\n×75 = ×300 ÷ 4, ×125 = ×1000 ÷ 8.",
            ),
            Square5 => (
                "Sonu 5 olan kare",
                "Onlar kısmını bir fazlasıyla çarp, sonuna 25 yaz.\n65² → 6 × 7 = 42 → 4225.\n115² → 11 × 12 = 132 → 13225.\nOndalıkta da işler: 7,5² → 7 × 8 = 56 → 56,25.",
            ),
            Near100 => (
                "100'e yakın çarpım: eksikler",
                "İki sayı da 100'e yakınsa eksiklerini bul.\n97 × 94: eksikler 3 ve 6. Çapraz çıkar: 97 − 6 = 91. Eksikleri çarp: 3 × 6 = 18 → 9118.\nÇarpım tek basamaklıysa başına 0 koy: 98 × 97 → 95 | 06 = 9506.\n100'ün üstünde fazlaları ekle: 103 × 107 → 110 | 21 = 11021.",
            ),
            Equidistant => (
                "Ortadan uzaklık: a² − b²",
                "İki sayı yuvarlak bir sayıya eşit uzaklıktaysa (a − b)(a + b) = a² − b² kullan.\n47 × 53 = 50² − 3² = 2500 − 9 = 2491.\n23 × 27 = 25² − 2² = 625 − 4 = 621.",
            ),
            DoubleHalve => (
                "İkile-yarıla",
                "Bir çarpanı yarıla, ötekini ikiyle çarp: çarpım değişmez.\n16 × 35 → 8 × 70 = 560.\n125 × 48 → 250 × 24 → 500 × 12 = 6000.\n3,5 × 16 → 7 × 8 = 56.",
            ),
            LeftAdd => (
                "Soldan sağa toplama",
                "Kâğıttaki gibi sağdan değil, büyük basamaklardan başla ve ara toplamı akılda tut.\n487 + 356 → 400 + 300 = 700 → 780 + 50 = 830 → 837 + 6 = 843.\nSöylediğin ilk sayı zaten cevabın büyük kısmıdır.",
            ),
            ComplementSub => (
                "Tamamlayanla çıkarma",
                "Yuvarlak sayıdan çıkarırken her basamağı 9'a, sonuncuyu 10'a tamamla.\n1000 − 387 → 6, 1, 3 → 613.\nÇıkan sayı yuvarlağa yakınsa yuvarla, sonra düzelt:\n523 − 198 = 523 − 200 + 2 = 325.",
            ),
            Divisibility => (
                "Bölünebilme: kalanı bölmeden bul",
                "2 ve 5 → son basamağın kalanı; 4 → son iki basamak; 8 → son üç basamak.\n3 ve 9 → rakamlar toplamının kalanı. 7452 ÷ 9 → 7+4+5+2 = 18 → kalan 0.\n11 → sağdan +, −, + … sırayla topla: 8316 → 6 − 1 + 3 − 8 = 0 → kalan 0.\n6 → 3'e göre kalan r; sayının tek/çift oluşuna uyan r ya da r+3.",
            ),
            PowersSquares => (
                "Kuvvetler ve kareler",
                "Ezber hız kazandırır: 2¹⁰ = 1024, 2¹⁶ = 65536.\nKomşu kareden git: (n+1)² = n² + 2n + 1.\n24² = 576 ise 25² = 576 + 49 = 625.\nKarekök için son rakama ve büyüklüğe bak: √729 → 27² = 729.",
            ),
            PercentOf => (
                "Yüzde: %10 ve %1 basamakları",
                "%10 = virgülü bir sola kaydır, %1 = iki sola. %5 = %10'un yarısı.\n240'ın %15'i → 24 + 12 = 36.\nYer değiştirme serbest: 25'in %8'i = 8'in %25'i = 2.",
            ),
            PercentChange => (
                "Yüzde değişim",
                "Değişim = fark ÷ eski değer.\n80 → 100: fark 20, 20 ÷ 80 = %25 artış.\nAzalış eksi yazılır: 120 → 90 = −25.\nArt arda +%20 ve −%20: 1,2 × 0,8 = 0,96 → net −4.",
            ),
            Discount => (
                "İndirim: kalan yüzdeyi öde",
                "%30 indirim = fiyatın %70'ini öde: 450 × 0,7 = 315.\nArt arda indirimler toplanmaz, çarpılır: %20 sonra %10 → 0,8 × 0,9 = 0,72 → toplam %28.\nEtiket fiyatı: 336 TL %30 indirimliyse 336 ÷ 0,7 = 480.",
            ),
            VatTip => (
                "KDV (%20) ve bahşiş",
                "KDV eklemek = 1,2 ile çarpmak: 250 → 300.\nKDV dahil fiyattan hariç fiyata 1,2'ye bölerek dön (%20 çıkarmak yanlış!): 360 → 300.\nİçindeki KDV = dahil fiyatın 1/6'sı: 360 → 60.\nBahşiş %15 = %10 + yarısı: 340 → 34 + 17 = 51.",
            ),
            FracDecPct => (
                "Kesir · ondalık · yüzde",
                "Temel taşları ezberle: 1/8 = 0,125 = %12,5 · 1/16 = 0,0625 · 1/20 = 0,05 · 1/25 = 0,04.\n3/8 = 3 × 0,125 = 0,375.\nPaydayı 100'e tamamla: 7/20 = 35/100 = %35.",
            ),
            Units => (
                "Birim çevirme",
                "Saat = 60 dk: 2,5 sa = 150 dk; 195 dk = 3,25 sa.\nHız: km/sa ÷ 3,6 = m/sn → 72 km/sa = 20 m/sn.\nSıcaklık: °F = °C × 1,8 + 32 → 25 °C = 77 °F.\nTempo: 12 km/sa → 1 km = 60 ÷ 12 = 5 dk.",
            ),
            Change => (
                "Para üstü: yukarı say",
                "Çıkarmak yerine kasiyer gibi yukarı say.\n100 − 47,35: 47,35 → 48 (0,65) → 50 (2) → 100 (50).\nToplam 0,65 + 2 + 50 = 52,65.",
            ),
            Growth => (
                "72 kuralı ve bileşik büyüme",
                "Yıllık %r büyüyen şey yaklaşık 72 ÷ r yılda iki katına çıkar: %8 → 9 yıl.\nTersi: 12 yılda iki kat → yıllık ≈ %6.\nBileşik: 1000 × 1,1 × 1,1 × 1,1 = 1331.",
            ),
            Estimate => (
                "Tahmin: yuvarla ve düzelt",
                "Yuvarla, hesapla, düzelt. 389 × 52 ≈ 400 × 50 = 20000 (gerçek 20228).\nBiri yukarı biri aşağı yuvarlanınca hatalar birbirini götürür.\nCevap belirtilen tolerans içindeyse doğru sayılır.",
            ),
            Average => (
                "Ortalama: referanstan sapma",
                "Bir referans seç, sapmaların ortalamasını ekle.\n84, 91, 77, 88 → 80'e göre +4, +11, −3, +8 = 20 → 20 ÷ 4 = 5 → 85.\nEksik değer: hedef ortalama × adet − mevcut toplam.",
            ),
            _ => return None,
        })
    }

    /// (extra points, par seconds at tier 0, extra par seconds per tier)
    fn costs(self) -> (u32, f64, f64) {
        match self {
            Add => (0, 4.0, 0.8),
            Sub => (0, 4.5, 0.9),
            Mul => (2, 5.0, 1.5),
            Div => (2, 5.0, 1.3),
            Chain => (4, 7.0, 1.5),
            Mul11 | Mul5 | Mul9 => (3, 5.0, 1.0),
            Mul25 | Square5 | LeftAdd | ComplementSub => (3, 5.0, 1.0),
            Near100 | Equidistant => (4, 7.0, 1.2),
            DoubleHalve | Divisibility => (4, 6.0, 1.0),
            PowersSquares => (2, 4.0, 0.6),
            PercentOf | FracDecPct | Change => (5, 6.0, 1.0),
            VatTip | Units => (5, 7.0, 1.0),
            PercentChange | Discount | Average => (6, 8.0, 1.2),
            Growth => (6, 9.0, 1.0),
            Estimate => (6, 7.0, 1.0),
        }
    }
}

/// One generated question.
#[derive(Clone, Debug)]
pub struct Question {
    pub kind: Kind,
    pub prompt: String,
    pub text: String,
    pub unit: String,
    pub answer: f64,
    /// Absolute tolerance (0 → exact up to float noise).
    pub tol: f64,
    /// Correct answer as shown to the player (and accepted by the checker).
    pub shown: String,
    pub points: u32,
    pub secs: f64,
    pub tier: u32,
}

impl Question {
    pub fn accepts(&self, v: f64) -> bool {
        (v - self.answer).abs() <= self.tol + 1e-6
    }
}

// ---------------------------------------------------------------- number formatting & parsing

const NNBSP: char = '\u{202F}';

fn group(int_part: &str) -> String {
    if int_part.len() < 5 {
        return int_part.to_string();
    }
    let mut out = String::new();
    let n = int_part.len();
    for (i, ch) in int_part.chars().enumerate() {
        if i > 0 && (n - i) % 3 == 0 {
            out.push(NNBSP);
        }
        out.push(ch);
    }
    out
}

/// Turkish number: decimal comma, up to 4 decimals, narrow-space thousands from 10 000, `−` sign.
pub fn fmt_num(x: f64) -> String {
    let mut s = format!("{:.4}", x.abs());
    if s.contains('.') {
        while s.ends_with('0') {
            s.pop();
        }
        if s.ends_with('.') {
            s.pop();
        }
    }
    let (ip, fp) = match s.split_once('.') {
        Some((a, b)) => (a.to_string(), Some(b.to_string())),
        None => (s.clone(), None),
    };
    let mut out = String::new();
    if x < 0.0 && s != "0" {
        out.push('−');
    }
    out.push_str(&group(&ip));
    if let Some(f) = fp {
        out.push(',');
        out.push_str(&f);
    }
    out
}

fn fi(x: i64) -> String {
    fmt_num(x as f64)
}

/// Money: whole amounts without decimals, otherwise exactly two.
fn money(x: f64) -> String {
    let c = (x * 100.0).round() as i64;
    if c % 100 == 0 {
        fi(c / 100)
    } else {
        format!("{},{:02}", group(&(c / 100).to_string()), (c % 100).abs())
    }
}

fn pct(x: f64) -> String {
    format!("%{}", fmt_num(x))
}

fn signed_pct(x: f64) -> String {
    if x < 0.0 {
        format!("−%{}", fmt_num(-x))
    } else {
        format!("+%{}", fmt_num(x))
    }
}

fn sup(n: u32) -> String {
    const D: [char; 10] = ['⁰', '¹', '²', '³', '⁴', '⁵', '⁶', '⁷', '⁸', '⁹'];
    n.to_string().chars().map(|c| D[c.to_digit(10).unwrap_or(0) as usize]).collect()
}

/// Parse a typed answer: digits, optional leading minus (`-` or `−`), decimal comma or dot.
pub fn parse_answer(s: &str) -> Option<f64> {
    let t: String = s
        .trim()
        .chars()
        .filter(|c| !c.is_whitespace() && *c != NNBSP)
        .map(|c| match c {
            ',' => '.',
            '−' => '-',
            _ => c,
        })
        .collect();
    if t.is_empty() || !t.chars().all(|c| c.is_ascii_digit() || c == '.' || c == '-') {
        return None;
    }
    t.parse::<f64>().ok().filter(|v| v.is_finite())
}

// ---------------------------------------------------------------- generators

/// Random number in lo..=hi that does not end in 0 (hi must end in 9 or not be a multiple of 10).
fn nz(r: &mut Rng, lo: i64, hi: i64) -> i64 {
    let x = r.range(lo, hi);
    if x % 10 == 0 {
        if x + 1 <= hi {
            x + 1
        } else {
            x - 1
        }
    } else {
        x
    }
}

/// Random d-digit number not ending in 0 (1-digit: 2..=9).
fn nd(r: &mut Rng, d: u32) -> i64 {
    if d == 1 {
        return r.range(2, 9);
    }
    nz(r, 10i64.pow(d - 1), 10i64.pow(d) - 1)
}

fn gcd(a: i64, b: i64) -> i64 {
    if b == 0 {
        a.abs()
    } else {
        gcd(b, a % b)
    }
}

struct Q {
    prompt: String,
    text: String,
    unit: &'static str,
    answer: f64,
    tol: f64,
    shown: Option<String>,
}

fn q(prompt: &str, text: String, answer: f64) -> Q {
    Q { prompt: prompt.to_string(), text, unit: "", answer, tol: 0.0, shown: None }
}

impl Q {
    fn unit(mut self, u: &'static str) -> Q {
        self.unit = u;
        self
    }
    fn tol(mut self, t: f64, shown: String) -> Q {
        self.tol = t;
        self.shown = Some(shown);
        self
    }
    fn shown(mut self, s: String) -> Q {
        self.shown = Some(s);
        self
    }
}

fn sum_q(r: &mut Rng, prompt: &str, spec: &[u32]) -> Q {
    let nums: Vec<i64> = spec.iter().map(|&d| nd(r, d)).collect();
    let text = nums.iter().map(|&n| fi(n)).collect::<Vec<_>>().join(" + ");
    q(prompt, text, nums.iter().sum::<i64>() as f64)
}

fn mul_text(a: i64, b: i64) -> String {
    format!("{} × {}", fi(a), fi(b))
}

fn gen_raw(kind: Kind, t: u32, r: &mut Rng) -> Q {
    let t = t.min(9);
    match kind {
        Add => {
            let spec: &[u32] = match t {
                0 => &[2, 2],
                1 => &[3, 2],
                2 => &[3, 3],
                3 => &[3, 3, 2],
                4 => &[4, 3],
                5 => &[4, 4],
                6 => &[3, 3, 3],
                7 => &[5, 4],
                8 => &[4, 4, 3],
                _ => &[5, 5],
            };
            sum_q(r, "Topla", spec)
        }
        Sub => {
            let (da, db) = [(2, 2), (3, 2), (3, 3), (4, 3), (4, 4), (5, 4), (5, 5), (6, 5), (6, 6), (7, 6)][t as usize];
            let mut a = nd(r, da);
            let mut b = nd(r, db);
            if a == b {
                b -= 1;
            }
            let allow_neg = t >= 4 && r.chance(0.25);
            if a < b && !allow_neg {
                std::mem::swap(&mut a, &mut b);
            }
            q("Çıkar", format!("{} − {}", fi(a), fi(b)), (a - b) as f64)
        }
        Mul => {
            let (alo, ahi, blo, bhi) = [
                (12, 99, 3, 9),
                (51, 99, 6, 9),
                (101, 999, 3, 9),
                (21, 99, 11, 19),
                (21, 99, 21, 99),
                (101, 999, 11, 19),
                (1001, 9999, 3, 9),
                (101, 999, 21, 99),
                (1001, 9999, 11, 19),
                (101, 999, 101, 999),
            ][t as usize];
            let a = nz(r, alo, ahi);
            let b = nz(r, blo, bhi);
            q("Çarp", mul_text(a, b), (a * b) as f64)
        }
        Div => {
            let (dlo, dhi, qlo, qhi) = [
                (3, 9, 12, 99),
                (6, 9, 50, 199),
                (3, 9, 101, 999),
                (11, 19, 12, 99),
                (12, 25, 21, 99),
                (21, 99, 12, 99),
                (3, 9, 1001, 9999),
                (11, 19, 101, 999),
                (21, 99, 101, 999),
                (101, 999, 21, 99),
            ][t as usize];
            let d = nz(r, dlo, dhi);
            let qq = nz(r, qlo, qhi);
            q("Böl (tam bölünür)", format!("{} ÷ {}", fi(d * qq), fi(d)), qq as f64)
        }
        Chain => gen_chain(t, r),
        Mul11 => {
            let (digits, mults): (u32, &[i64]) = match t {
                0 | 1 => (2, &[11]),
                2 | 3 => (3, &[11]),
                4 => (4, &[11]),
                5 => (2, &[22, 33, 44]),
                6 => (3, &[11, 22]),
                7 => (4, &[11]),
                8 => (5, &[11]),
                _ => (4, &[22, 33]),
            };
            let a = if t == 1 {
                let x = r.range(2, 9);
                let y = r.range(10 - x, 9);
                x * 10 + y
            } else {
                nd(r, digits)
            };
            let m = *r.pick(mults);
            q("Çarp", mul_text(a, m), (a * m) as f64)
        }
        Mul5 => {
            let v = match t {
                0 => (nd(r, 2), 5, false),
                1 => (nd(r, 3), 5, false),
                2 => {
                    if r.chance(0.5) {
                        (nd(r, 2), 50, false)
                    } else {
                        (nd(r, 3) | 1, 5, false)
                    }
                }
                3 => (nd(r, 4), 5, false),
                4 => (nd(r, 3), 5, true),
                5 => {
                    if r.chance(0.5) {
                        (nd(r, 3), 50, false)
                    } else {
                        (nd(r, 3), 5, true)
                    }
                }
                6 => {
                    if r.chance(0.5) {
                        (nd(r, 4), 5, false)
                    } else {
                        (nd(r, 3), 500, false)
                    }
                }
                7 => (nd(r, 4), 5, true),
                8 => {
                    let x = nz(r, 11, 99);
                    return q("Çarp", format!("{} × 5", fmt_num(x as f64 / 10.0)), x as f64 / 2.0);
                }
                _ => (nd(r, 5), 5, false),
            };
            let (a, m, divide) = v;
            if divide {
                q("Böl", format!("{} ÷ 5", fi(a * 5)), a as f64)
            } else {
                q("Çarp", mul_text(a, m), (a * m) as f64)
            }
        }
        Mul9 => {
            let (d, m) = [(2, 9), (3, 9), (2, 99), (4, 9), (3, 99), (2, 999), (4, 99), (3, 999), (5, 9), (4, 999)]
                [t as usize];
            let a = nd(r, d);
            q("Çarp", mul_text(a, m), (a * m) as f64)
        }
        Mul25 => {
            let (a, m, divide) = match t {
                0 => {
                    let a = if r.chance(0.5) { 4 * r.range(3, 24) } else { nd(r, 2) };
                    (a, 25, false)
                }
                1 => (nd(r, 2), 25, false),
                2 => (nd(r, 3), 25, false),
                3 => (nd(r, 2), 25, true),
                4 => (nd(r, 2), 75, false),
                5 => {
                    if r.chance(0.5) {
                        (nd(r, 3), 25, false)
                    } else {
                        (nd(r, 3), 25, true)
                    }
                }
                6 => (nd(r, 2), 125, false),
                7 => (nd(r, 3), 75, false),
                8 => (nd(r, 3), 125, false),
                _ => {
                    if r.chance(0.5) {
                        (nd(r, 4), 25, false)
                    } else {
                        (nd(r, 4), 25, true)
                    }
                }
            };
            if divide {
                q("Böl", format!("{} ÷ 25", fi(a * 25)), a as f64)
            } else {
                q("Çarp", mul_text(a, m), (a * m) as f64)
            }
        }
        Square5 => {
            let decimal = t == 3 || t == 6;
            let (lo, hi) = [(1, 9), (2, 12), (10, 19), (1, 12), (10, 29), (13, 39), (10, 19), (20, 49), (30, 69), (50, 99)]
                [t as usize];
            let a = r.range(lo, hi);
            if decimal {
                let x = a as f64 + 0.5;
                q("Kare al", format!("{}²", fmt_num(x)), x * x)
            } else {
                let x = a * 10 + 5;
                q("Kare al", format!("{}²", fi(x)), (x * x) as f64)
            }
        }
        Near100 => {
            let (a, b) = match t {
                0 => (r.range(91, 99), r.range(91, 99)),
                1 => (r.range(85, 99), r.range(85, 99)),
                2 => (r.range(101, 109), r.range(101, 109)),
                3 => (r.range(101, 115), r.range(101, 115)),
                4 => (r.range(101, 109), r.range(91, 99)),
                5 => (r.range(80, 99), r.range(80, 99)),
                6 => (r.range(990, 999), r.range(990, 999)),
                7 => (r.range(1001, 1012), r.range(988, 999)),
                8 => {
                    let base = *r.pick(&[200i64, 300, 500]);
                    (base - r.range(1, 9), base - r.range(1, 9))
                }
                _ => (r.range(975, 999), r.range(975, 999)),
            };
            let (a, b) = if r.chance(0.5) { (a, b) } else { (b, a) };
            q("Çarp", mul_text(a, b), (a * b) as f64)
        }
        Equidistant => {
            if t == 7 {
                let m = r.range(3, 9);
                let d = r.range(1, 9);
                let (a, b) = (m * 10 - d, m * 10 + d);
                return q(
                    "Çarp",
                    format!("{} × {}", fmt_num(a as f64 / 10.0), fmt_num(b as f64 / 10.0)),
                    (a * b) as f64 / 100.0,
                );
            }
            let (m, d) = match t {
                0 => (10 * r.range(2, 9), r.range(1, 5)),
                1 => (10 * r.range(2, 9), r.range(1, 9)),
                2 => (10 * r.range(10, 20), r.range(1, 9)),
                3 => (10 * r.range(2, 9) + 5, r.range(1, 4)),
                4 => (10 * r.range(10, 30), r.range(1, 9)),
                5 => (10 * r.range(3, 9), r.range(11, 19)),
                6 => (50 * r.range(2, 10), r.range(1, 20)),
                8 => (10 * r.range(10, 90), r.range(1, 19)),
                _ => (10 * r.range(10, 90), r.range(11, 29)),
            };
            let (a, b) = (m - d, m + d);
            let (a, b) = if r.chance(0.5) { (a, b) } else { (b, a) };
            q("Çarp", mul_text(a, b), (a * b) as f64)
        }
        DoubleHalve => {
            let ends5 = |r: &mut Rng| 10 * r.range(1, 9) + 5;
            let (a, b) = match t {
                0 => (nz(r, 6, 24) * 2, *r.pick(&[15i64, 25, 35, 45])),
                1 => (nz(r, 6, 49) * 2, ends5(r)),
                2 => (r.range(3, 24) * 4, ends5(r)),
                3 => (r.range(2, 12) * 8, *r.pick(&[125i64, 250, 375, 625])),
                4 => (nz(r, 51, 499) * 2, *r.pick(&[15i64, 25, 35, 45])),
                5 => {
                    let a = nz(r, 6, 49) * 2;
                    let x = r.range(1, 9);
                    let xv = x as f64 + 0.5;
                    let (l, rr) = if r.chance(0.5) { (fmt_num(xv), fi(a)) } else { (fi(a), fmt_num(xv)) };
                    return q("Çarp", format!("{l} × {rr}"), xv * a as f64);
                }
                6 => (nz(r, 25, 249) * 4, ends5(r)),
                7 => (r.range(2, 12) * 16, *r.pick(&[125i64, 375, 625, 875])),
                8 => (nz(r, 6, 49) * 2, 10 * r.range(10, 99) + 5),
                _ => (nz(r, 26, 249) * 4, 100 * r.range(1, 9) + *r.pick(&[25i64, 75])),
            };
            let (a, b) = if r.chance(0.5) { (a, b) } else { (b, a) };
            q("Çarp", mul_text(a, b), (a * b) as f64)
        }
        LeftAdd => {
            let spec: &[u32] = match t {
                0 => &[3, 3],
                1 => &[4, 3],
                2 => &[3, 3, 3],
                3 => &[4, 4],
                4 => &[4, 4, 3],
                5 => &[5, 4],
                6 => &[3, 3, 3, 3],
                7 => &[5, 5],
                8 => &[5, 5, 4],
                _ => &[6, 5],
            };
            sum_q(r, "Soldan sağa topla", spec)
        }
        ComplementSub => gen_complement(t, r),
        Divisibility => {
            let digits = [3, 4, 4, 5, 5, 6, 6, 7, 7, 8][t as usize];
            let divs: &[i64] = match t {
                0 => &[2, 3, 5, 9],
                1 => &[3, 4, 5, 9],
                2 => &[3, 4, 6, 8, 9, 11],
                3 | 4 => &[2, 3, 4, 5, 6, 8, 9, 11],
                _ => &[3, 4, 6, 8, 9, 11],
            };
            let d = *r.pick(divs);
            let lo = 10i64.pow(digits - 1);
            let mut n = r.range(lo + 20, 10i64.pow(digits) - 1);
            if r.chance(0.4) {
                n -= n % d;
            }
            q("Kalan kaç? (bölmeden)", format!("{} ÷ {}", fi(n), d), (n % d) as f64)
        }
        PowersSquares => {
            let variant = r.below(if t < 2 { 2 } else { 3 });
            match variant {
                0 => {
                    let (lo, hi) = match t {
                        0 => (4, 10),
                        1 => (5, 12),
                        2 => (6, 14),
                        3 => (7, 15),
                        4 | 5 => (8, 16),
                        _ => (10, 20),
                    };
                    let k = r.range(lo, hi) as u32;
                    q("Kuvvet", format!("2{}", sup(k)), (1u64 << k) as f64)
                }
                1 => {
                    let (lo, hi) = match t {
                        0 => (11, 20),
                        1 => (11, 25),
                        _ => (13, 30),
                    };
                    let n = nz(r, lo, hi);
                    q("Kare al", format!("{}²", n), (n * n) as f64)
                }
                _ => {
                    let n = nz(r, 11, 30);
                    q("Karekök", format!("√{}", fi(n * n)), n as f64)
                }
            }
        }
        PercentOf => gen_percent_of(t, r),
        PercentChange => gen_percent_change(t, r),
        Discount => gen_discount(t, r),
        VatTip => gen_vat_tip(t, r),
        FracDecPct => gen_frac(t, r),
        Units => gen_units(t, r),
        Change => gen_change(t, r),
        Growth => gen_growth(t, r),
        Estimate => gen_estimate(t, r),
        Average => gen_average(t, r),
    }
}

fn gen_chain(t: u32, r: &mut Rng) -> Q {
    let p = "İşlem önceliğiyle hesapla";
    match t {
        0 => {
            let (a, b, c) = (nd(r, 2), nd(r, 2), nd(r, 2));
            q(p, format!("{a} + {b} − {c}"), (a + b - c) as f64)
        }
        1 => {
            let (a, b, c) = (nd(r, 2), nd(r, 1), nd(r, 2));
            q(p, format!("{a} × {b} + {c}"), (a * b + c) as f64)
        }
        2 => {
            let (a, b, c, d) = (nd(r, 3), nd(r, 3), nd(r, 2), nd(r, 2));
            q(p, format!("{a} + {b} − {c} + {d}"), (a + b - c + d) as f64)
        }
        3 => {
            let (a, b, c, d) = (nd(r, 2), nd(r, 1), nd(r, 2), nd(r, 1));
            q(p, format!("{a} × {b} − {c} × {d}"), (a * b - c * d) as f64)
        }
        4 => {
            let (a, b, c) = (nd(r, 2), nd(r, 2), nd(r, 1));
            q(p, format!("({a} + {b}) × {c}"), ((a + b) * c) as f64)
        }
        5 => {
            let (a, b, c, d, e) = (nd(r, 2), nd(r, 1), nd(r, 2), nd(r, 1), nd(r, 2));
            q(p, format!("{a} × {b} + {c} × {d} − {e}"), (a * b + c * d - e) as f64)
        }
        6 => {
            let (a, b, c) = (nd(r, 2), nz(r, 11, 19), nd(r, 3));
            q(p, format!("{a} × {b} − {c}"), (a * b - c) as f64)
        }
        7 => {
            let (a, b, c, d) = (nd(r, 3), nd(r, 2), nd(r, 1), nd(r, 1));
            q(p, format!("({a} − {b}) × ({c} + {d})"), ((a - b) * (c + d)) as f64)
        }
        8 => {
            let (c, qq, b) = (r.range(3, 9), nz(r, 12, 99), r.range(3, 9));
            q(p, format!("{} ÷ {c} × {b}", c * qq), (qq * b) as f64)
        }
        _ => {
            let (a, b, c, d) = (nd(r, 2), nz(r, 11, 19), nd(r, 2), nz(r, 11, 19));
            q(p, format!("{a} × {b} + {c} × {d}"), (a * b + c * d) as f64)
        }
    }
}

fn gen_complement(t: u32, r: &mut Rng) -> Q {
    let p = "Çıkar";
    let near_round = |r: &mut Rng, a: i64, unit: i64| -> i64 {
        // A number just below a multiple of `unit`, smaller than `a`.
        let k = r.range(1, (a / unit).max(1));
        (k * unit - r.range(1, 4)).max(1)
    };
    let (a, b) = match t {
        0 => {
            if r.chance(0.5) {
                (1000, nd(r, 3))
            } else {
                let a = r.range(310, 999);
                (a, near_round(r, a, 100))
            }
        }
        1 => {
            if r.chance(0.5) {
                (10_000, nd(r, 4))
            } else {
                let a = r.range(1100, 9999);
                (a, near_round(r, a, 100))
            }
        }
        2 => {
            let a = 1000 * r.range(2, 9);
            (a, nz(r, 1001, a - 1))
        }
        3 => {
            let a = r.range(3100, 9999);
            (a, near_round(r, a, 1000))
        }
        4 => (100_000, nd(r, 5)),
        5 => {
            let c = r.range(101, 9899); // cents
            let c = if c % 100 == 0 { c + 7 } else { c };
            return q(
                "Para üstü gibi tamamla",
                format!("100 − {}", money(c as f64 / 100.0)),
                (10_000 - c) as f64 / 100.0,
            )
            .shown(money((10_000 - c) as f64 / 100.0));
        }
        6 => {
            let a = r.range(31_000, 99_999);
            (a, near_round(r, a, 1000))
        }
        7 => {
            let a = 10_000 * r.range(2, 9);
            (a, nz(r, 10_001, a - 1))
        }
        8 => {
            let a = r.range(310_000, 999_999);
            (a, near_round(r, a, 10_000))
        }
        _ => (1_000_000, nd(r, 6)),
    };
    let (a, b) = if b >= a { (a, a / 3 + 1) } else { (a, b) };
    q(p, format!("{} − {}", fi(a), fi(b)), (a - b) as f64)
}

fn gen_percent_of(t: u32, r: &mut Rng) -> Q {
    let variant = match t {
        0 => 0,
        1 => 1,
        2 => 2,
        3 => 3,
        4 => 4,
        _ => [2, 3, 4, 5][r.below(4)],
    };
    match variant {
        0 => {
            let p = *r.pick(&[5i64, 10, 15, 20, 25, 30, 50, 75]);
            let y = 20 * r.range(2, 40);
            q("Yüzde hesabı", format!("{} × {}", pct(p as f64), fi(y)), (p * y) as f64 / 100.0)
        }
        1 => {
            let p = 5 * r.range(1, 19);
            let y = 20 * r.range(3, 50);
            q("Yüzde hesabı", format!("{} × {}", pct(p as f64), fi(y)), (p * y) as f64 / 100.0)
        }
        2 => {
            let p = nz(r, 2, 99);
            let y = 100 * r.range(2, 40);
            q("Yüzde hesabı", format!("{} × {}", pct(p as f64), fi(y)), (p * y) as f64 / 100.0)
        }
        3 => {
            let p = nz(r, 2, 99);
            let y = nz(r, 12, 999);
            q("Yüzde hesabı", format!("{} × {}", pct(p as f64), fi(y)), (p * y) as f64 / 100.0)
        }
        4 => {
            let p = 5 * r.range(1, 19);
            let x = 20 * r.range(2, 60);
            let y = p * x / 100;
            q("Sayıyı bul", format!("{} × ? = {}", pct(p as f64), fi(y)), x as f64)
        }
        _ => {
            let p = *r.pick(&[2.5f64, 7.5, 12.5, 17.5, 37.5, 62.5, 87.5]);
            let y = 40 * r.range(5, 250);
            q("Yüzde hesabı", format!("{} × {}", pct(p), fi(y)), p * y as f64 / 100.0)
        }
    }
}

fn gen_percent_change(t: u32, r: &mut Rng) -> Q {
    let p_change = "Yüzde kaç değişti? (azalışta −)";
    let variant = match t {
        0 => 0,
        1 => 1,
        2 => 2,
        3 => 3,
        _ => [1, 2, 3, 4][r.below(4)],
    };
    match variant {
        0 => {
            let p = *r.pick(&[10i64, 20, 25, 50, -10, -20, -25, -50]);
            let old = 20 * r.range(1, 25);
            let new = old * (100 + p) / 100;
            q(p_change, format!("{} → {}", fi(old), fi(new)), p as f64).unit("%")
        }
        1 => {
            let mut p = 5 * r.range(-15, 30);
            if p == 0 {
                p = 35;
            }
            let old = 20 * r.range(2, 40);
            let new = old * (100 + p) / 100;
            q(p_change, format!("{} → {}", fi(old), fi(new)), p as f64).unit("%")
        }
        2 => {
            let step = if t >= 5 { 5 } else { 10 };
            let mut p1 = step * r.range(-50 / step, 50 / step);
            let mut p2 = step * r.range(-50 / step, 50 / step);
            if p1 == 0 {
                p1 = 20;
            }
            if p2 == 0 {
                p2 = -20;
            }
            let net = p1 as f64 + p2 as f64 + (p1 * p2) as f64 / 100.0;
            q("Art arda iki değişim · net yüzde?", format!("{}, sonra {}", signed_pct(p1 as f64), signed_pct(p2 as f64)), net)
                .unit("%")
        }
        3 => {
            let p = *r.pick(&[10i64, 20, 25, 50, 60, 75, -10, -20, -25, -40, -50]);
            let old = 20 * r.range(2, 50);
            let new = old * (100 + p) / 100;
            q("Eski değer kaçtı?", format!("? {} = {}", signed_pct(p as f64), fi(new)), old as f64)
        }
        _ => {
            let mut p = nz(r, -60, 99);
            if p == 0 {
                p = 13;
            }
            let old = 100 * r.range(2, 90);
            let new = old * (100 + p) / 100;
            q(p_change, format!("{} → {}", fi(old), fi(new)), p as f64).unit("%")
        }
    }
}

fn gen_discount(t: u32, r: &mut Rng) -> Q {
    let variant = match t {
        0 => 0,
        1 => 1,
        2 => 2,
        3 => 3,
        4 => 4,
        _ => 1 + r.below(4),
    };
    let big = if t >= 5 { 10 } else { 1 };
    match variant {
        0 => {
            let price = 10 * r.range(10, 90);
            let d = *r.pick(&[10i64, 20, 25, 30, 40, 50]);
            let ans = (price * (100 - d)) as f64 / 100.0;
            q("İndirimli fiyat", format!("{} TL · −%{}", fi(price), d), ans).unit("TL").shown(money(ans))
        }
        1 => {
            let price = 5 * r.range(11, 199) * big;
            let d = 5 * r.range(1, 12);
            let ans = (price * (100 - d)) as f64 / 100.0;
            q("İndirimli fiyat", format!("{} TL · −%{}", fi(price), d), ans).unit("TL").shown(money(ans))
        }
        2 => {
            let d1 = 10 * r.range(1, 5);
            let d2 = 5 * r.range(1, 10);
            let total = (d1 + d2) as f64 - (d1 * d2) as f64 / 100.0;
            q("Art arda indirim · toplam yüzde?", format!("−%{}, sonra −%{}", d1, d2), total).unit("%")
        }
        3 => {
            let d = *r.pick(&[10i64, 20, 25, 30, 40, 50, 60, 75]);
            let orig = 20 * r.range(3, 50) * big;
            let now = orig * (100 - d) / 100;
            q("Etiket fiyatı (indirimden önce)", format!("{} TL = −%{} sonrası", fi(now), d), orig as f64).unit("TL")
        }
        _ => {
            let price = 50 * r.range(2, 30) * big;
            let d = 5 * r.range(1, 8);
            let ans = (price * (100 - d)) as f64 / 100.0 * 1.2;
            q("İndirim, sonra %20 KDV", format!("{} TL · −%{} · +KDV", fi(price), d), ans).unit("TL").shown(money(ans))
        }
    }
}

fn gen_vat_tip(t: u32, r: &mut Rng) -> Q {
    let variant = match t {
        0 => 0,
        1 => 1,
        2 => 2,
        3 => 3,
        4 => 4,
        _ => r.below(5),
    };
    let big = if t >= 5 { 10 } else { 1 };
    match variant {
        0 => {
            let net = 5 * r.range(10, 199) * big;
            q("KDV dahil fiyat (%20)", format!("{} TL + KDV", fi(net)), net as f64 * 1.2).unit("TL")
        }
        1 => {
            let bill = 10 * r.range(8, 99) * big;
            let p = *r.pick(&[10i64, 15, 20]);
            let ans = (bill * p) as f64 / 100.0;
            q("Bahşiş kaç TL?", format!("{} TL · %{} bahşiş", fi(bill), p), ans).unit("TL").shown(money(ans))
        }
        2 => {
            let net = 5 * r.range(10, 199) * big;
            let gross = net * 6 / 5;
            q("KDV hariç fiyat (%20)", format!("KDV dahil {} TL", fi(gross)), net as f64).unit("TL")
        }
        3 => {
            let net = 5 * r.range(10, 199) * big;
            let gross = net * 6 / 5;
            q("İçindeki KDV tutarı (%20)", format!("KDV dahil {} TL", fi(gross)), (gross / 6) as f64).unit("TL")
        }
        _ => {
            let bill = 20 * r.range(10, 99) * big;
            let p = *r.pick(&[10i64, 15, 20]);
            let k = *r.pick(&[2i64, 4, 5]);
            let ans = (bill * (100 + p)) as f64 / 100.0 / k as f64;
            q("Bahşiş dahil kişi başı", format!("{} TL + %{} · {} kişi", fi(bill), p, k), ans)
                .unit("TL")
                .shown(money(ans))
        }
    }
}

fn reduced(r: &mut Rng, dens: &[i64], improper: bool) -> (i64, i64) {
    let d = *r.pick(dens);
    loop {
        let n = if improper { r.range(d + 1, 3 * d - 1) } else { r.range(1, d - 1) };
        if gcd(n, d) == 1 {
            return (n, d);
        }
    }
}

fn gen_frac(t: u32, r: &mut Rng) -> Q {
    let variant = if t >= 5 { [1, 2, 3, 4, 5][r.below(5)] } else { t as usize };
    match variant {
        0 => {
            if r.chance(0.6) {
                let (n, d) = reduced(r, &[2, 4, 5, 8, 10, 20], false);
                q("Ondalık olarak", format!("{n}/{d}"), n as f64 / d as f64)
            } else {
                let (n, d) = reduced(r, &[4, 8, 20, 25, 40], false);
                let x = n as f64 / d as f64;
                q("Yüzde olarak", format!("{} = %?", fmt_num(x)), x * 100.0)
            }
        }
        1 => {
            if r.chance(0.5) {
                let (n, d) = reduced(r, &[4, 5, 8, 20, 25, 50], false);
                q("Yüzde olarak", format!("{n}/{d} = %?"), n as f64 * 100.0 / d as f64)
            } else {
                let (n, _) = reduced(r, &[8], false);
                q("Payı bul", format!("{} = ?/8", fmt_num(n as f64 / 8.0)), n as f64)
            }
        }
        2 => {
            let (n, d) = reduced(r, &[16, 25, 40, 50], false);
            q("Ondalık olarak", format!("{n}/{d}"), n as f64 / d as f64)
        }
        3 => {
            if r.chance(0.5) {
                let (n, _) = reduced(r, &[8], false);
                q("Payı bul", format!("{} = ?/8", pct(n as f64 * 12.5)), n as f64)
            } else {
                let d = *r.pick(&[4i64, 5, 8, 16, 20, 25, 40, 50]);
                q("Paydayı bul", format!("{} = 1/?", pct(100.0 / d as f64)), d as f64)
            }
        }
        4 => {
            let (n, d) = reduced(r, &[4, 8, 16, 20, 25], true);
            q("Ondalık olarak", format!("{n}/{d}"), n as f64 / d as f64)
        }
        _ => {
            let (n, d) = reduced(r, &[3, 6, 7, 9, 11, 12], false);
            let x = n as f64 / d as f64;
            if r.chance(0.5) {
                let v = x * 100.0;
                q("Yaklaşık yüzde (±0,1)", format!("{n}/{d} ≈ %?"), v).tol(0.1, fmt_num((v * 100.0).round() / 100.0))
            } else {
                q("Yaklaşık ondalık (2 basamak)", format!("{n}/{d} ≈ ?"), x).tol(0.005, fmt_num((x * 100.0).round() / 100.0))
            }
        }
    }
}

fn gen_units(t: u32, r: &mut Rng) -> Q {
    let pool: &[u32] = match t {
        0 | 1 => &[0, 1, 2, 3],
        2..=4 => &[0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
        _ => &[4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
    };
    let p = "Birim çevir";
    match *r.pick(pool) {
        0 => {
            let k = loop {
                let k = r.range(5, 19);
                if k % 4 != 0 {
                    break k;
                }
            };
            let h = k as f64 / 4.0;
            q(p, format!("{} sa = ? dk", fmt_num(h)), h * 60.0).unit("dk")
        }
        1 => {
            let k = 5 * r.range(21, 199);
            q(p, format!("{} km = ? m", fmt_num(k as f64 / 100.0)), (k * 10) as f64).unit("m")
        }
        2 => {
            let g = nz(r, 101, 999) * if t >= 1 { 10 } else { 1 };
            q(p, format!("{} g = ? kg", fi(g)), g as f64 / 1000.0).unit("kg")
        }
        3 => {
            let k = nz(r, 11, 99);
            q(p, format!("{} L = ? mL", fmt_num(k as f64 / 10.0)), (k * 100) as f64).unit("mL")
        }
        4 => {
            let m = loop {
                let m = 15 * r.range(5, 23);
                if m % 60 != 0 {
                    break m;
                }
            };
            q(p, format!("{} dk = ? sa", m), m as f64 / 60.0).unit("sa")
        }
        5 => {
            let (h, m) = (r.range(1, 9), 5 * r.range(1, 11));
            q(p, format!("{h} sa {m} dk = ? dk"), (h * 60 + m) as f64).unit("dk")
        }
        6 => {
            let k = r.range(1, 10);
            q(p, format!("{} km/sa = ? m/sn", 18 * k), (5 * k) as f64).unit("m/sn")
        }
        7 => {
            let v = r.range(5, 40);
            q(p, format!("{v} m/sn = ? km/sa"), v as f64 * 3.6).unit("km/sa")
        }
        8 => {
            let k = r.range(-4, 8);
            q(p, format!("{} °C = ? °F", fi(5 * k)), (9 * k + 32) as f64).unit("°F")
        }
        9 => {
            if r.chance(0.5) {
                let (w, d) = (r.range(2, 9), r.range(1, 6));
                q(p, format!("{w} hafta {d} gün = ? gün"), (7 * w + d) as f64).unit("gün")
            } else {
                let (d, h) = (r.range(2, 9), r.range(1, 23));
                q(p, format!("{d} gün {h} sa = ? sa"), (24 * d + h) as f64).unit("sa")
            }
        }
        10 => {
            let k = r.range(-4, 12);
            q(p, format!("{} °F = ? °C", fi(32 + 9 * k)), (5 * k) as f64).unit("°C")
        }
        11 => {
            let k = loop {
                let k = r.range(3, 19);
                if k % 4 != 0 {
                    break k;
                }
            };
            q(p, format!("{} sn = ? sa", fi(900 * k)), k as f64 / 4.0).unit("sa")
        }
        12 => {
            let v = 12 * r.range(3, 10);
            let h = r.range(1, 4);
            let m = *r.pick(&[15i64, 20, 30, 40, 45]);
            let ans = v * (60 * h + m) / 60;
            q("Yol = hız × süre", format!("{v} km/sa · {h} sa {m} dk"), ans as f64).unit("km")
        }
        13 => {
            let v = *r.pick(&[4i64, 5, 6, 8, 10, 12, 15, 20]);
            q("Tempo: 1 km kaç dakika?", format!("{v} km/sa → ? dk/km"), 60.0 / v as f64).unit("dk")
        }
        14 => {
            if r.chance(0.5) {
                let k = nz(r, 11, 99);
                q(p, format!("{} m² = ? cm²", fmt_num(k as f64 / 10.0)), (k * 1000) as f64).unit("cm²")
            } else {
                let k = nz(r, 11, 99);
                q(p, format!("{} cm² = ? m²", fi(k * 100)), k as f64 / 100.0).unit("m²")
            }
        }
        _ => {
            let k = loop {
                let k = r.range(3, 19);
                if k % 4 != 0 {
                    break k;
                }
            };
            q(p, format!("{} gün = ? sa", fmt_num(k as f64 / 4.0)), (6 * k) as f64).unit("sa")
        }
    }
}

fn gen_change(t: u32, r: &mut Rng) -> Q {
    let cents = |r: &mut Rng, lo: i64, hi: i64| -> i64 {
        let c = r.range(lo, hi);
        if c % 5 == 0 && r.chance(0.5) {
            c + 2
        } else {
            c
        }
    };
    let (pay, items): (i64, Vec<i64>) = match t {
        0 => {
            let pay = *r.pick(&[20i64, 50, 100]);
            (pay, vec![cents(r, pay * 25, pay * 100 - 10)])
        }
        1 => {
            let pay = *r.pick(&[200i64, 500]);
            (pay, vec![cents(r, pay * 30, pay * 100 - 10)])
        }
        2 => {
            let pay = *r.pick(&[100i64, 200]);
            (pay, vec![cents(r, 500, pay * 40), cents(r, 500, pay * 40)])
        }
        3 | 4 => {
            let pay = *r.pick(&[100i64, 200]);
            (pay, (0..3).map(|_| cents(r, 300, pay * 30)).collect())
        }
        _ => {
            let pay = *r.pick(&[200i64, 500, 1000]);
            let k = if t >= 7 { 4 } else { 3 };
            (pay, (0..k).map(|_| cents(r, 500, pay * 100 / (k + 1))).collect())
        }
    };
    let total: i64 = items.iter().sum();
    let ans = (pay * 100 - total) as f64 / 100.0;
    let text = if items.len() == 1 {
        format!("{} − {}", pay, money(items[0] as f64 / 100.0))
    } else {
        items.iter().map(|&c| money(c as f64 / 100.0)).collect::<Vec<_>>().join(" + ")
    };
    let prompt = if items.len() == 1 { "Para üstü".to_string() } else { format!("{pay} TL verdin · para üstü") };
    q(&prompt, text, ans).unit("TL").shown(money(ans))
}

fn gen_growth(t: u32, r: &mut Rng) -> Q {
    let variant = if t >= 5 { r.below(5) } else { t as usize };
    match variant {
        0 => {
            let rate = *r.pick(&[2i64, 3, 4, 6, 8, 9, 12, 18, 24]);
            let ans = 72.0 / rate as f64;
            q("72 kuralı · kaç yılda 2 kat? (±1)", format!("Yıllık %{rate}"), ans).unit("yıl").tol(1.0, fmt_num(ans))
        }
        1 => {
            let years = *r.pick(&[3i64, 4, 6, 8, 9, 12, 18, 24]);
            let ans = 72.0 / years as f64;
            q("72 kuralı · yıllık yüzde kaç? (±1)", format!("{years} yılda 2 kat"), ans).unit("%").tol(1.0, fmt_num(ans))
        }
        2 => {
            let p = 1000 * r.range(1, 9);
            let rate = *r.pick(&[10i64, 20, 50]);
            let ans = p as f64 * (1.0 + rate as f64 / 100.0).powi(2);
            q("Bileşik getiri · 2 yıl sonra", format!("{} TL · yıllık %{}", fi(p), rate), ans).unit("TL").tol(0.5, money(ans))
        }
        3 => {
            let rate = *r.pick(&[6i64, 8, 9, 12]);
            let k = r.range(2, 3);
            let years = k * 72 / rate;
            let ans = (1i64 << k) as f64;
            q("72 kuralı · kaç katına çıkar? (±%12)", format!("Yıllık %{rate} · {years} yıl"), ans)
                .unit("kat")
                .tol(ans * 0.12, fmt_num(ans))
        }
        _ => {
            if r.chance(0.5) {
                let rate = *r.pick(&[3i64, 4, 6, 8, 9, 12, 18, 24]);
                let ans = 72.0 / rate as f64;
                q("Enflasyon · alım gücü kaç yılda yarıya iner? (±1)", format!("Yıllık %{rate} enflasyon"), ans)
                    .unit("yıl")
                    .tol(1.0, fmt_num(ans))
            } else {
                let p = 1000 * r.range(1, 5);
                let rate = *r.pick(&[5i64, 10, 20]);
                let n = 3;
                let ans = p as f64 * (1.0 + rate as f64 / 100.0).powi(n);
                q("Bileşik getiri · 3 yıl sonra (±%1)", format!("{} TL · yıllık %{}", fi(p), rate), ans)
                    .unit("TL")
                    .tol(ans * 0.01, money(ans))
            }
        }
    }
}

fn gen_estimate(t: u32, r: &mut Rng) -> Q {
    let rel: f64 = if t <= 3 {
        0.10
    } else if t <= 6 {
        0.07
    } else {
        0.05
    };
    let prompt = format!("Tahmin · ±%{} içinde", (rel * 100.0).round() as i64);
    let big = t >= 4;
    let (text, ans) = match r.below(5) {
        0 => {
            let a = nd(r, if big { 4 } else { 3 });
            let b = nd(r, 2);
            (format!("≈ {}", mul_text(a, b)), (a * b) as f64)
        }
        1 => {
            let a = nd(r, if big { 5 } else { 4 });
            let b = nz(r, 13, 99);
            (format!("≈ {} ÷ {}", fi(a), b), a as f64 / b as f64)
        }
        2 => {
            let n = loop {
                let n = r.range(150, if big { 99_999 } else { 9_999 });
                let s = (n as f64).sqrt().round() as i64;
                if s * s != n {
                    break n;
                }
            };
            (format!("≈ √{}", fi(n)), (n as f64).sqrt())
        }
        3 => {
            let k = if big { 4 } else { 3 };
            let nums: Vec<i64> = (0..k).map(|_| nd(r, 4)).collect();
            (format!("≈ {}", nums.iter().map(|&x| fi(x)).collect::<Vec<_>>().join(" + ")), nums.iter().sum::<i64>() as f64)
        }
        _ => {
            let p = nz(r, 11, 89);
            let y = nd(r, if big { 5 } else { 4 });
            (format!("≈ %{} × {}", p, fi(y)), (p * y) as f64 / 100.0)
        }
    };
    let shown = fmt_num((ans * 10.0).round() / 10.0);
    q(&prompt, text, ans).tol(ans.abs() * rel, shown)
}

fn gen_average(t: u32, r: &mut Rng) -> Q {
    let variant = match t {
        0..=2 => 0,
        3 => 1,
        4 => 2,
        _ => r.below(3),
    };
    match variant {
        0 | 3 => {
            let k = [3usize, 4, 5, 4, 5, 6, 6, 6, 6, 6][t as usize];
            let (lo, hi) = if t >= 5 { (100, 999) } else if t >= 2 { (40, 199) } else { (40, 99) };
            let mut nums: Vec<i64> = (0..k).map(|_| r.range(lo, hi)).collect();
            let rem = nums.iter().sum::<i64>() % k as i64;
            nums[k - 1] -= rem;
            if nums[k - 1] < lo {
                nums[k - 1] += k as i64;
            }
            let avg = nums.iter().sum::<i64>() as f64 / k as f64;
            q("Ortalama", nums.iter().map(|&x| fi(x)).collect::<Vec<_>>().join(" · "), avg)
        }
        1 => {
            let k = r.range(3, 5) as usize;
            let target = r.range(65, 92);
            let mut nums: Vec<i64> = (0..k - 1).map(|_| (target + r.range(-12, 12)).min(100)).collect();
            let mut missing = target * k as i64 - nums.iter().sum::<i64>();
            while missing > 100 {
                let i = r.below(k - 1);
                if nums[i] < 100 {
                    nums[i] += 1;
                    missing -= 1;
                }
            }
            let mut shown = nums.iter().map(|&x| fi(x)).collect::<Vec<_>>();
            shown.push("?".into());
            q(&format!("Ortalama {target} olsun · eksik not?"), shown.join(" · "), missing as f64)
        }
        _ => {
            let (q1, q2) = (r.range(1, 5), r.range(1, 5));
            let (p1, p2) = (5 * r.range(4, 16), 5 * r.range(4, 16));
            let ans = (q1 * p1 + q2 * p2) as f64 / (q1 + q2) as f64;
            q("Ağırlıklı ortalama · kg fiyatı", format!("{q1} kg × {p1} TL + {q2} kg × {p2} TL"), ans)
                .unit("TL")
                .tol(0.01, money(ans))
        }
    }
}

/// Generate one question of `kind` at tier `t` (0..=9).
pub fn generate(kind: Kind, t: u32, r: &mut Rng) -> Question {
    let t = t.min(9);
    // Plain + and − are a tier easier than everything else; shift them so level 1 is not trivial.
    let gt = if matches!(kind, Add | Sub) { (t + 1).min(9) } else { t };
    let g = gen_raw(kind, gt, r);
    let (extra, s0, st) = kind.costs();
    Question {
        kind,
        shown: g.shown.unwrap_or_else(|| fmt_num(g.answer)),
        prompt: g.prompt,
        text: g.text,
        unit: g.unit.to_string(),
        answer: g.answer,
        tol: g.tol,
        points: 10 + 4 * t + extra,
        secs: s0 + st * t as f64,
        tier: t,
    }
}

// ---------------------------------------------------------------- level plan

#[derive(Clone, Debug)]
pub struct Plan {
    pub title: String,
    /// Kinds to draw from (repeats = weight).
    pub kinds: Vec<Kind>,
    /// Kind shown on the trick card (intro or focus level).
    pub card: Option<Kind>,
    /// Share of questions forced to `card`'s kind on focus levels.
    pub focus: bool,
    pub tier: u32,
    pub n: usize,
    pub par_scale: f64,
}

fn curriculum(level: u32) -> (String, Vec<Kind>, Option<Kind>) {
    let intro = |k: Kind| (format!("Yeni: {}", k.label()), vec![k], Some(k));
    let all_tricks_until = |n: usize| TRICKS[..n].to_vec();
    match level {
        1 => ("Hız: dört işlem".into(), vec![Mul, Mul, Mul, Add, Sub, Div], None),
        2 => intro(Mul11),
        3 => intro(Mul5),
        4 => ("Hız: çarpma ve bölme".into(), vec![Mul, Div], None),
        5 => intro(Mul9),
        6 => intro(PercentOf),
        7 => intro(LeftAdd),
        8 => intro(Mul25),
        9 => intro(Discount),
        10 => ("Tekrar".into(), vec![Mul11, Mul5, Mul9, Mul25, LeftAdd, PercentOf, Discount], None),
        11 => intro(Square5),
        12 => intro(ComplementSub),
        13 => intro(Change),
        14 => intro(Near100),
        15 => ("Hız: karışık".into(), SPEED.to_vec(), None),
        16 => intro(Equidistant),
        17 => intro(VatTip),
        18 => intro(DoubleHalve),
        19 => intro(FracDecPct),
        20 => {
            let mut k = all_tricks_until(10);
            k.extend([PercentOf, Discount, Change, VatTip, FracDecPct]);
            ("Tekrar".into(), k, None)
        }
        21 => intro(Divisibility),
        22 => intro(PercentChange),
        23 => intro(PowersSquares),
        24 => intro(Units),
        25 => ("Hız: karışık".into(), SPEED.to_vec(), None),
        26 => intro(Average),
        27 => intro(Growth),
        28 => intro(Estimate),
        29 => ("Tekrar: hileler".into(), TRICKS.to_vec(), None),
        _ => ("Tekrar: pratik".into(), PRACTICAL.to_vec(), None),
    }
}

/// Level → plan. See the module docs for the curve.
pub fn plan(level: u32) -> Plan {
    let level = level.clamp(1, crate::MAX_LEVEL);
    let tier = ((level - 1) * 10 / 480).min(9);
    let n = 10 + ((level - 1) * 10 / 499) as usize;
    let par_scale = 1.0 - 0.2 * (level - 1) as f64 / 499.0;
    let (title, kinds, card, focus) = if level <= 30 {
        let (t, k, c) = curriculum(level);
        (t, k, c, false)
    } else {
        let i = level - 31;
        let k = (i / 10) as usize;
        match i % 10 {
            0 => ("Hız".to_string(), SPEED.to_vec(), None, false),
            1 => {
                let kind = TRICKS[k % TRICKS.len()];
                (kind.label().to_string(), vec![kind], Some(kind), true)
            }
            2 | 8 => ("Pratik matematik".to_string(), PRACTICAL.to_vec(), None, false),
            3 => ("Hız: çarpma ve bölme".to_string(), vec![Mul, Div, Mul, Chain], None, false),
            4 => ("Hile karması".to_string(), TRICKS.to_vec(), None, false),
            5 => {
                let kind = PRACTICAL[k % PRACTICAL.len()];
                (kind.label().to_string(), vec![kind], Some(kind), true)
            }
            6 => ("Hız: toplama ve çıkarma".to_string(), vec![Add, Sub, Chain, LeftAdd, ComplementSub], None, false),
            7 => {
                let kind = TRICKS[(k + 6) % TRICKS.len()];
                (kind.label().to_string(), vec![kind], Some(kind), true)
            }
            _ => {
                let mut all = SPEED.to_vec();
                all.extend_from_slice(TRICKS);
                all.extend_from_slice(PRACTICAL);
                ("Büyük karma".to_string(), all, None, false)
            }
        }
    };
    Plan { title, kinds, card, focus, tier, n, par_scale }
}

fn level_questions(level: u32, p: &Plan) -> Vec<Question> {
    let mut r = Rng::new(seed_for("math", level, 0));
    let mut out: Vec<Question> = Vec::with_capacity(p.n);
    let mut mix: Vec<Kind> = SPEED.to_vec();
    mix.extend_from_slice(TRICKS);
    for i in 0..p.n {
        let t = (p.tier + u32::from(i >= p.n * 2 / 3)).min(9);
        // Focus levels: 70% the focus kind, 30% everything else.
        let kind = if p.focus && i % 10 >= 7 { *r.pick(&mix) } else { *r.pick(&p.kinds) };
        let mut qn = generate(kind, t, &mut r);
        for _ in 0..12 {
            if !out.iter().any(|o| o.text == qn.text) {
                break;
            }
            qn = generate(kind, t, &mut r);
        }
        out.push(qn);
    }
    out
}

// ---------------------------------------------------------------- session

pub const SPRINT_MS: f64 = 60_000.0;

#[derive(Clone, Copy, PartialEq, Debug)]
enum Phase {
    Intro,
    Play,
    Done,
}

#[derive(Clone, Debug)]
struct Feedback {
    serial: u32,
    correct: bool,
    skipped: bool,
    given: String,
    answer: String,
    text: String,
    points: u32,
}

pub struct MathGame {
    endless: bool,
    title: String,
    card: Option<Kind>,
    questions: Vec<Question>,
    idx: usize,
    phase: Phase,
    elapsed_ms: f64,
    limit_ms: f64,
    par_ms: f64,
    correct: u32,
    wrong: u32,
    skipped: u32,
    streak: u32,
    best_streak: u32,
    points: u32,
    timed_out: bool,
    last: Option<Feedback>,
    serial: u32,
    rng: Rng,
    skill: f64,
    stars: u32,
    won: bool,
}

pub fn create(level: u32, mode: &str) -> Result<Box<dyn Session>, String> {
    Ok(Box::new(if mode == "endless" { MathGame::sprint(time_seed()) } else { MathGame::level(level) }))
}

impl MathGame {
    pub fn level(level: u32) -> Self {
        let p = plan(level);
        let questions = level_questions(level, &p);
        let par_secs: f64 = questions.iter().map(|q| q.secs).sum();
        let par_ms = (par_secs * p.par_scale).round() * 1000.0;
        let limit_ms = ((par_secs * 1.6 / 5.0).ceil() * 5.0) * 1000.0;
        MathGame {
            endless: false,
            title: p.title,
            card: p.card,
            questions,
            idx: 0,
            phase: Phase::Intro,
            elapsed_ms: 0.0,
            limit_ms,
            par_ms,
            correct: 0,
            wrong: 0,
            skipped: 0,
            streak: 0,
            best_streak: 0,
            points: 0,
            timed_out: false,
            last: None,
            serial: 0,
            rng: Rng::new(0),
            skill: 0.0,
            stars: 0,
            won: false,
        }
    }

    pub fn sprint(seed: u64) -> Self {
        let mut g = MathGame::level(1);
        g.endless = true;
        g.title = "Sprint".into();
        g.card = None;
        g.limit_ms = SPRINT_MS;
        g.par_ms = 0.0;
        g.rng = Rng::new(seed);
        g.skill = 1.0;
        g.questions.clear();
        g.next_sprint_question();
        g
    }

    fn tier(&self) -> u32 {
        if self.endless {
            (self.skill.floor() as u32).min(9)
        } else {
            self.questions.get(self.idx.min(self.questions.len().saturating_sub(1))).map(|q| q.tier).unwrap_or(0)
        }
    }

    fn next_sprint_question(&mut self) {
        // Weighted: speed arithmetic ×3, every trick and practical type ×1.
        let mut pool: Vec<Kind> = Vec::new();
        for &k in SPEED {
            pool.extend([k, k, k]);
        }
        pool.extend_from_slice(TRICKS);
        pool.extend_from_slice(PRACTICAL);
        let t = (self.skill.floor() as u32).min(9);
        let mut kind = *self.rng.pick(&pool);
        if let Some(prev) = self.questions.last() {
            if prev.kind == kind {
                kind = *self.rng.pick(&pool);
            }
        }
        let qn = generate(kind, t, &mut self.rng);
        self.questions.push(qn);
    }

    fn current(&self) -> Option<&Question> {
        if self.phase == Phase::Play {
            self.questions.get(self.idx)
        } else {
            None
        }
    }

    fn finish_level(&mut self) {
        self.phase = Phase::Done;
        if self.endless {
            return;
        }
        let n = self.questions.len() as f64;
        let acc = self.correct as f64 / n;
        self.stars = if acc >= 0.95 - 1e-9 && self.elapsed_ms <= self.par_ms && !self.timed_out {
            3
        } else if acc >= 0.8 - 1e-9 {
            2
        } else if acc >= 0.6 - 1e-9 {
            1
        } else {
            0
        };
        self.won = self.stars > 0;
    }

    fn record(&mut self, given: Option<f64>) {
        let qn = self.questions[self.idx].clone();
        let ok = given.map(|v| qn.accepts(v)).unwrap_or(false);
        let mut pts = 0;
        if ok {
            self.correct += 1;
            self.streak += 1;
            self.best_streak = self.best_streak.max(self.streak);
            let bonus = 1.0 + 0.1 * (self.streak.saturating_sub(1)).min(5) as f64;
            pts = (qn.points as f64 * bonus).round() as u32;
            self.points += pts;
        } else {
            if given.is_some() {
                self.wrong += 1;
            } else {
                self.skipped += 1;
            }
            self.streak = 0;
        }
        if self.endless {
            self.skill = match (ok, given.is_some()) {
                (true, _) => self.skill + 0.25 + 0.05 * self.streak.min(6) as f64,
                (false, true) => self.skill - 0.6,
                (false, false) => self.skill - 0.3,
            }
            .clamp(0.0, 9.99);
        }
        self.serial += 1;
        self.last = Some(Feedback {
            serial: self.serial,
            correct: ok,
            skipped: given.is_none(),
            given: given.map(fmt_num).unwrap_or_default(),
            answer: qn.shown.clone(),
            text: qn.text.clone(),
            points: pts,
        });
        self.idx += 1;
        if self.endless {
            self.next_sprint_question();
        } else if self.idx >= self.questions.len() {
            self.finish_level();
        }
    }

    fn status(&self) -> &'static str {
        match (self.phase, self.endless) {
            (Phase::Done, true) => "lost",
            (Phase::Done, false) => {
                if self.won {
                    "won"
                } else {
                    "lost"
                }
            }
            _ => "playing",
        }
    }

    fn summary(&self) -> String {
        if self.endless {
            format!(
                "Doğru {} · Yanlış {} · En uzun seri {} · Zorluk {}",
                self.correct,
                self.wrong + self.skipped,
                self.best_streak,
                (self.skill.floor() as u32).min(9) + 1
            )
        } else {
            let head = if self.timed_out { "Süre doldu · " } else { "" };
            format!(
                "{head}Doğru {}/{} · Süre {} · Hedef {}",
                self.correct,
                self.questions.len(),
                clock(self.elapsed_ms),
                clock(self.par_ms)
            )
        }
    }
}

fn clock(ms: f64) -> String {
    let s = (ms / 1000.0).ceil().max(0.0) as u64;
    format!("{}:{:02}", s / 60, s % 60)
}

impl Session for MathGame {
    fn state(&self) -> Value {
        let card = self.card.and_then(|k| {
            k.trick().map(|(title, text)| json!({"kind": k.key(), "label": k.label(), "title": title, "text": text}))
        });
        let question = self.current().map(|qn| {
            json!({
                "kind": qn.kind.key(),
                "label": qn.kind.label(),
                "prompt": qn.prompt,
                "text": qn.text,
                "unit": qn.unit,
            })
        });
        let goal = if self.endless {
            "60 saniyede en çok puanı topla · seri zorluğu artırır".to_string()
        } else {
            format!(
                "{} soru · süre {} · ★★★ için %95 ve {} altı",
                self.questions.len(),
                clock(self.limit_ms),
                clock(self.par_ms)
            )
        };
        let last = self.last.as_ref().map(|f| {
            json!({
                "serial": f.serial, "correct": f.correct, "skipped": f.skipped, "given": f.given,
                "answer": f.answer, "text": f.text, "points": f.points,
            })
        });
        json!({
            "status": self.status(),
            "stars": self.stars,
            "mode": if self.endless { "endless" } else { "level" },
            "phase": match self.phase { Phase::Intro => "intro", Phase::Play => "play", Phase::Done => "done" },
            "title": self.title,
            "goal": goal,
            "summary": if self.phase == Phase::Done { Some(self.summary()) } else { None },
            "score": self.points,
            "trick": card,
            "question": question,
            "index": self.idx,
            "total": if self.endless { None } else { Some(self.questions.len()) },
            "correct": self.correct,
            "wrong": self.wrong,
            "skipped": self.skipped,
            "streak": self.streak,
            "best_streak": self.best_streak,
            "elapsed_ms": self.elapsed_ms.round(),
            "limit_ms": self.limit_ms,
            "remaining_ms": (self.limit_ms - self.elapsed_ms).max(0.0).round(),
            "par_ms": if self.endless { None } else { Some(self.par_ms) },
            "tier": self.tier() + 1,
            "last": last,
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
            self.phase = Phase::Play;
            return Ok(());
        }
        if self.phase == Phase::Intro {
            return Err("Önce Başla'ya dokun".into());
        }
        if a["skip"].as_bool() == Some(true) {
            self.record(None);
            return Ok(());
        }
        let v = &a["answer"];
        if v.is_null() {
            return Err("Bilinmeyen hamle".into());
        }
        let parsed = if let Some(x) = v.as_f64() {
            Some(x)
        } else {
            let s = v.as_str().unwrap_or("");
            if s.trim().is_empty() {
                return Err("Önce cevabını yaz".into());
            }
            parse_answer(s)
        };
        let x = parsed.ok_or("Geçerli bir sayı yaz")?;
        self.record(Some(x));
        Ok(())
    }

    fn tick(&mut self, dt_ms: f64) {
        if self.phase != Phase::Play || !(dt_ms > 0.0) {
            return;
        }
        self.elapsed_ms += dt_ms;
        if self.elapsed_ms >= self.limit_ms {
            self.elapsed_ms = self.limit_ms;
            if !self.endless {
                self.timed_out = true;
                // Unanswered questions count as wrong (not skipped: they were never seen).
                self.wrong += (self.questions.len() - self.idx) as u32;
                self.idx = self.questions.len();
            }
            self.finish_level();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LEVELS: [u32; 9] = [1, 2, 3, 50, 137, 250, 400, 499, 500];

    /// Tiny evaluator for the pure-arithmetic question texts (+ − × ÷ parentheses, ², decimal comma).
    fn eval(s: &str) -> f64 {
        let s: String = s.chars().filter(|c| !c.is_whitespace() && *c != NNBSP).collect();
        let toks: Vec<char> = s.chars().collect();
        let mut i = 0;
        fn expr(t: &[char], i: &mut usize) -> f64 {
            let mut v = term(t, i);
            while *i < t.len() && (t[*i] == '+' || t[*i] == '−') {
                let op = t[*i];
                *i += 1;
                let r = term(t, i);
                v = if op == '+' { v + r } else { v - r };
            }
            v
        }
        fn term(t: &[char], i: &mut usize) -> f64 {
            let mut v = factor(t, i);
            while *i < t.len() && (t[*i] == '×' || t[*i] == '÷') {
                let op = t[*i];
                *i += 1;
                let r = factor(t, i);
                v = if op == '×' { v * r } else { v / r };
            }
            v
        }
        fn factor(t: &[char], i: &mut usize) -> f64 {
            let mut v = if t[*i] == '(' {
                *i += 1;
                let v = expr(t, i);
                *i += 1; // ')'
                v
            } else {
                let mut s = String::new();
                while *i < t.len() && (t[*i].is_ascii_digit() || t[*i] == ',') {
                    s.push(if t[*i] == ',' { '.' } else { t[*i] });
                    *i += 1;
                }
                s.parse::<f64>().unwrap()
            };
            if *i < t.len() && t[*i] == '²' {
                *i += 1;
                v *= v;
            }
            v
        }
        let v = expr(&toks, &mut i);
        assert_eq!(i, toks.len(), "unparsed tail in {s}");
        v
    }

    const PURE: &[Kind] = &[
        Add, Sub, Mul, Div, Chain, Mul11, Mul5, Mul9, Mul25, Square5, Near100, Equidistant, DoubleHalve, LeftAdd,
        ComplementSub,
    ];

    #[test]
    fn pure_arithmetic_answers_match_text() {
        let mut r = Rng::new(7);
        for &k in PURE {
            for t in 0..10 {
                for _ in 0..60 {
                    let qn = generate(k, t, &mut r);
                    let v = eval(&qn.text);
                    assert!((v - qn.answer).abs() < 1e-6, "{k:?} t{t}: {} = {} != {}", qn.text, v, qn.answer);
                }
            }
        }
    }

    #[test]
    fn every_kind_and_tier_is_sane() {
        let mut r = Rng::new(11);
        let mut all = SPEED.to_vec();
        all.extend_from_slice(TRICKS);
        all.extend_from_slice(PRACTICAL);
        for &k in &all {
            for t in 0..10 {
                for _ in 0..80 {
                    let qn = generate(k, t, &mut r);
                    assert!(qn.answer.is_finite(), "{k:?} {}", qn.text);
                    // The shown answer is accepted by the checker (round-trip through the parser).
                    let v = parse_answer(&qn.shown).unwrap_or_else(|| panic!("unparsable {}", qn.shown));
                    assert!(qn.accepts(v), "{k:?} t{t}: {} shown {} answer {}", qn.text, qn.shown, qn.answer);
                    // Exact answers have at most 4 decimals so they can be typed.
                    if qn.tol == 0.0 {
                        assert!(((qn.answer * 10_000.0).round() - qn.answer * 10_000.0).abs() < 1e-4, "{}", qn.text);
                    }
                    assert!(!qn.text.is_empty() && !qn.prompt.is_empty());
                }
            }
        }
    }

    #[test]
    fn practical_spot_checks() {
        let mut r = Rng::new(3);
        for t in 0..10 {
            for _ in 0..100 {
                let qn = generate(Divisibility, t, &mut r);
                let (n, d) = qn.text.split_once(" ÷ ").unwrap();
                let n: i64 = n.chars().filter(|c| c.is_ascii_digit()).collect::<String>().parse().unwrap();
                let d: i64 = d.parse().unwrap();
                assert_eq!(qn.answer as i64, n % d);
                let qn = generate(PowersSquares, t, &mut r);
                assert!(qn.answer >= 16.0 || qn.text.starts_with('√'));
                let qn = generate(Average, t, &mut r);
                assert!(qn.answer > 0.0 && qn.answer <= 1000.0, "{}", qn.text);
            }
        }
    }

    #[test]
    fn trick_card_examples_are_correct() {
        assert_eq!(36 * 11, 396);
        assert_eq!(78 * 11, 858);
        assert_eq!(243 * 11, 2673);
        assert_eq!(486 * 5, 2430);
        assert_eq!(73 * 5, 365);
        assert_eq!(435 / 5, 87);
        assert_eq!(67 * 9, 603);
        assert_eq!(48 * 99, 4752);
        assert_eq!(36 * 25, 900);
        assert_eq!(84 * 25, 2100);
        assert_eq!(1300 / 25, 52);
        assert_eq!(65 * 65, 4225);
        assert_eq!(115 * 115, 13225);
        assert_eq!(7.5f64 * 7.5, 56.25);
        assert_eq!(97 * 94, 9118);
        assert_eq!(98 * 97, 9506);
        assert_eq!(103 * 107, 11021);
        assert_eq!(47 * 53, 2491);
        assert_eq!(23 * 27, 621);
        assert_eq!(16 * 35, 560);
        assert_eq!(125 * 48, 6000);
        assert_eq!(3.5f64 * 16.0, 56.0);
        assert_eq!(487 + 356, 843);
        assert_eq!(1000 - 387, 613);
        assert_eq!(523 - 198, 325);
        assert_eq!(7452 % 9, 0);
        assert_eq!(8316 % 11, 0);
        assert_eq!(7451 % 6, 5);
        assert_eq!(1u32 << 16, 65536);
        assert_eq!(24 * 24 + 49, 625);
        assert_eq!(27 * 27, 729);
        assert_eq!(240 * 15 / 100, 36);
        assert!((1.2f64 * 0.8 - 0.96).abs() < 1e-12);
        assert_eq!(450 * 70 / 100, 315);
        assert_eq!(336 * 10 / 7, 480);
        assert_eq!(250 * 6 / 5, 300);
        assert_eq!(360 * 5 / 6, 300);
        assert_eq!(360 / 6, 60);
        assert_eq!(340 * 15 / 100, 51);
        assert_eq!(25 * 18 / 10 + 32, 77);
        assert_eq!(72 * 10 / 36, 20);
        assert_eq!(10000 - 4735, 5265);
        assert_eq!(1000 * 11 * 11 * 11 / 1000, 1331);
        assert_eq!(389 * 52, 20228);
        assert_eq!((84 + 91 + 77 + 88) / 4, 85);
        for k in TRICKS.iter().chain(PRACTICAL) {
            assert!(k.trick().is_some(), "{k:?} has no card");
        }
    }

    #[test]
    fn levels_generate_and_are_deterministic() {
        for level in LEVELS {
            let a = MathGame::level(level);
            let b = MathGame::level(level);
            assert!((10..=20).contains(&a.questions.len()));
            assert_eq!(
                a.questions.iter().map(|q| q.text.clone()).collect::<Vec<_>>(),
                b.questions.iter().map(|q| q.text.clone()).collect::<Vec<_>>()
            );
            assert!(a.par_ms < a.limit_ms);
            assert_eq!(a.state()["status"], "playing");
        }
        // Intro levels carry a trick card.
        assert!(MathGame::level(2).state()["trick"]["text"].as_str().unwrap().contains("11"));
        assert!(MathGame::level(1).state()["trick"].is_null());
    }

    #[test]
    fn curriculum_introduces_every_type() {
        let mut seen = vec![];
        for level in 1..=30 {
            if let Some(k) = plan(level).card {
                seen.push(k);
            }
        }
        for k in TRICKS.iter().chain(PRACTICAL) {
            assert!(seen.contains(k), "{k:?} never introduced");
        }
    }

    fn solve(level: u32) -> MathGame {
        let mut g = MathGame::level(level);
        g.act(&json!({"start": true})).unwrap();
        while g.phase == Phase::Play {
            g.tick(500.0);
            let shown = g.current().unwrap().shown.clone();
            g.act(&json!({"answer": shown})).unwrap();
        }
        g
    }

    #[test]
    fn solving_gives_three_stars() {
        for level in LEVELS {
            let g = solve(level);
            assert_eq!(g.state()["status"], "won", "level {level}");
            assert_eq!(g.stars, 3);
        }
    }

    #[test]
    fn stars_follow_accuracy_and_time() {
        // All correct but slow → 2 stars.
        let mut g = MathGame::level(5);
        g.act(&json!({"start": true})).unwrap();
        g.tick(g.par_ms + 1000.0);
        while g.phase == Phase::Play {
            let shown = g.current().unwrap().shown.clone();
            g.act(&json!({"answer": shown})).unwrap();
        }
        assert_eq!(g.stars, 2);
        // Everything skipped → lost.
        let mut g = MathGame::level(5);
        g.act(&json!({"start": true})).unwrap();
        while g.phase == Phase::Play {
            g.act(&json!({"skip": true})).unwrap();
        }
        assert_eq!(g.state()["status"], "lost");
        // Timeout → lost, unanswered count as wrong.
        let mut g = MathGame::level(5);
        g.act(&json!({"start": true})).unwrap();
        for _ in 0..2000 {
            g.tick(250.0);
        }
        assert_eq!(g.state()["status"], "lost");
        assert_eq!(g.wrong as usize, g.questions.len());
    }

    #[test]
    fn illegal_actions_rejected_and_state_unchanged() {
        let mut g = MathGame::level(1);
        let before = g.state();
        assert!(g.act(&json!({"answer": "12"})).is_err()); // not started
        assert_eq!(g.state(), before);
        g.act(&json!({"start": true})).unwrap();
        let before = g.state();
        assert!(g.act(&json!({"answer": "1a2"})).is_err());
        assert!(g.act(&json!({"answer": ""})).is_err());
        assert!(g.act(&json!({"start": true})).is_err());
        assert!(g.act(&json!({"foo": 1})).is_err());
        assert_eq!(g.state(), before);
        // Numbers and comma decimals both work.
        assert_eq!(parse_answer("−12,5"), Some(-12.5));
        assert_eq!(parse_answer("3.25"), Some(3.25));
        assert_eq!(parse_answer("1 000"), Some(1000.0));
    }

    #[test]
    fn wrong_answer_feedback_shows_correct_value() {
        let mut g = MathGame::level(1);
        g.act(&json!({"start": true})).unwrap();
        let shown = g.current().unwrap().shown.clone();
        g.act(&json!({"answer": -999999})).unwrap();
        let st = g.state();
        assert_eq!(st["last"]["correct"], false);
        assert_eq!(st["last"]["answer"], shown);
        assert_eq!(st["streak"], 0);
    }

    #[test]
    fn endless_adapts_and_ends() {
        let mut g = MathGame::sprint(99);
        g.act(&json!({"start": true})).unwrap();
        for _ in 0..30 {
            let shown = g.current().unwrap().shown.clone();
            g.act(&json!({"answer": shown})).unwrap();
            g.tick(100.0);
        }
        assert!(g.tier() >= 5, "tier {}", g.tier());
        let pts = g.points;
        assert!(pts > 300);
        for _ in 0..300 {
            g.tick(250.0);
        }
        let st = g.state();
        assert_eq!(st["status"], "lost");
        assert_eq!(st["score"], pts);
        assert!(g.act(&json!({"skip": true})).is_err());
    }

    #[test]
    fn fmt_and_money() {
        assert_eq!(fmt_num(0.375), "0,375");
        assert_eq!(fmt_num(-36.0), "−36");
        assert_eq!(fmt_num(12345.5), "12\u{202F}345,5");
        assert_eq!(money(52.65), "52,65");
        assert_eq!(money(52.6), "52,60");
        assert_eq!(money(300.0), "300");
    }

    #[test]
    #[ignore]
    fn timing_500_levels() {
        let t = std::time::Instant::now();
        let mut worst = 0.0f64;
        for level in 1..=500 {
            let s = std::time::Instant::now();
            let g = MathGame::level(level);
            assert!(!g.questions.is_empty());
            worst = worst.max(s.elapsed().as_secs_f64());
        }
        println!("math: 500 levels in {:?}, worst {:.3} ms", t.elapsed(), worst * 1000.0);
    }
}
