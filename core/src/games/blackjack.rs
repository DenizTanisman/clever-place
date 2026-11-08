//! 21 (Blackjack) against the dealer, built as a strategy trainer.
//!
//! Table rules (printed on the felt: "KRUPİYE 17'DE DURUR · BLACKJACK 3:2"):
//! - 6-deck shoe, cut card at ~75 % (234 ± 8 cards dealt); the shoe is reshuffled before the next
//!   hand once the cut card has come out (the Hi-Lo count resets with it).
//! - Dealer stands on all 17s (S17), peeks for blackjack under an ace or a ten; insurance (half the
//!   bet, pays 2:1) is offered on an ace up.
//! - Blackjack pays 3:2. Double on any first two cards, double after split (DAS) allowed.
//! - Split any two cards of equal value (K+Q too) up to 3 times (4 hands). Split aces receive one
//!   card each and can't be re-split; 21 after a split is not a blackjack.
//! - **No surrender** (keeps the decision set small; the basic-strategy tables below are the
//!   6-deck S17 DAS no-surrender tables).
//! - A hand that reaches 21 stands automatically.
//!
//! Match ("masa"): 40 hands starting with 1000 chips (points, no real money). Bets 10..=500 in
//! multiples of 5 (chips 10/25/50/100). After the 40th hand `{"next":true}` ends the match:
//! `won` if the bankroll is above 1000, `draw` at exactly 1000, `lost` below. Running out of chips
//! (< 10) ends it early as `lost`. `stars` (won only): decision accuracy ≥ 90 % → 3, ≥ 75 % → 2,
//! else 1. `score` = final chips (whole). Money is kept in half-chips internally (3:2 on 25 = 37,5).
//!
//! Modes: `classic` (just play), `coach` (the view shows `feedback` after each decision),
//! `count` (Hi-Lo trainer: every 4 hands phase `count_quiz` asks the running count; `bet_advice`
//! from the true count; Illustrious-18 deviations are accepted as correct decisions), `open`
//! (hole card + next 5 cards visible, `open_hint` = best play with that knowledge vs basic
//! strategy). The eye toggle "Açık oyna" sends `{"reveal":true}` once, which marks the session as
//! "açık" in the summary and enables `open_hint` in any mode. Decision accuracy (`counters`) is
//! measured against basic strategy in every mode (plus I18 deviations in `count`).
//!
//! Hidden information is always in the state (`hole`, `next_cards`); the view hides it unless the
//! mode / toggle allows it.
//!
//! State: `{status, stars, title, goal, summary?, score, mode, seed, phase:
//!   "bet"|"insurance"|"play"|"dealer"|"settle"|"count_quiz"|"done", turn: "you"|"dealer",
//!   ai_pending, chips, bet, min_bet, max_bet, start_chips, hand_no, hands_total,
//!   hands:[{cards:[{id,s,r}], total, soft, label, bet, doubled, from_split, split_aces, done,
//!           state: "active"|"waiting"|"stand"|"bust"|"blackjack"|"done", result?, net?}],
//!   active, dealer:{cards:[{id,s,r,down}], total, soft, label, hole_revealed, full_total},
//!   hole:{s,r}, next_cards:[{s,r}], shoe_left, shoe_total, decks_left, cut_left, shuffled,
//!   running_count, true_count, bet_advice:{units, amount, text}, actions:[..],
//!   can:{hit,stand,double,split}, insurance:{offered, taken, amount, result}, feedback?, hint?,
//!   open_hint?, quiz?, counters:{hands, decisions, correct, accuracy, hints, quiz_total,
//!   quiz_right}, message, round_net, open, peeked}`
//! Actions: `{"bet":n}` (total bet; 0 clears) · `{"deal":true}` · `{"hit":true}` ·
//!   `{"stand":true}` · `{"double":true}` · `{"split":true}` · `{"insurance":true|false}` ·
//!   `{"count_answer":n}` · `{"hint":true}` · `{"reveal":true}` · `{"next":true}` ·
//!   `{"ai":true}` (one dealer step: reveal the hole card or draw one card; settles at the end).

use crate::rng::{time_seed, Rng};
use crate::Session;
use serde_json::{json, Value};

pub const DECKS: usize = 6;
pub const START_CHIPS: i64 = 1000;
pub const HANDS_PER_MATCH: u32 = 40;
pub const MIN_BET: i64 = 10;
pub const MAX_BET: i64 = 500;
pub const MAX_HANDS: usize = 4;
pub const QUIZ_EVERY: u32 = 4;
pub const OPEN_CARDS: usize = 5;

// ---------------------------------------------------------------------------------------------
// Cards and totals

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Card {
    pub rank: u8, // 2..=14 (14 = ace)
    pub suit: u8, // 0 maça, 1 kupa, 2 karo, 3 sinek
}

impl Card {
    pub fn new(rank: u8, suit: u8) -> Self {
        Card { rank, suit }
    }
    /// Blackjack value with the ace as 1 (1..=10).
    pub fn value(self) -> u8 {
        match self.rank {
            14 => 1,
            11..=13 => 10,
            r => r,
        }
    }
    /// Hi-Lo tag: 2–6 +1, 7–9 0, tens and aces −1.
    pub fn hilo(self) -> i32 {
        match self.value() {
            2..=6 => 1,
            7..=9 => 0,
            _ => -1,
        }
    }
    fn json(self) -> Value {
        json!({"s": self.suit, "r": self.rank})
    }
}

/// Turkish rank name ("As", "Papaz", "7").
pub fn rank_name(rank: u8) -> String {
    match rank {
        14 => "As".into(),
        13 => "Papaz".into(),
        12 => "Kız".into(),
        11 => "Vale".into(),
        r => r.to_string(),
    }
}

/// Dealer up-card label: 2..=10 or "As" (value 11 = ace).
fn up_name(up: u8) -> String {
    if up == 11 {
        "As".into()
    } else {
        up.to_string()
    }
}

/// (total, soft) for a hard sum (aces as 1) and whether any ace is present.
pub fn tot(hard: u8, ace: bool) -> (u8, bool) {
    if ace && hard + 10 <= 21 {
        (hard + 10, true)
    } else {
        (hard, false)
    }
}

/// (total, soft) of a list of cards.
pub fn hand_total(cards: &[Card]) -> (u8, bool) {
    let hard: u8 = cards.iter().map(|c| c.value()).sum();
    tot(hard, cards.iter().any(|c| c.rank == 14))
}

pub fn is_blackjack(cards: &[Card]) -> bool {
    cards.len() == 2 && hand_total(cards).0 == 21
}

/// Turkish locative suffix after a number: "12'de", "16'da", "13'te".
fn loc(n: u8) -> String {
    let suf = match n % 10 {
        0 => {
            if n == 10 {
                "da"
            } else {
                "de" // 20 = yirmi
            }
        }
        1 | 2 | 7 | 8 => "de",
        3..=5 => "te",
        _ => "da", // 6 altı, 9 dokuz
    };
    format!("{n}'{suf}")
}

fn chips_text(halves: i64) -> String {
    let neg = halves < 0;
    let h = halves.abs();
    let whole = h / 2;
    let s = whole.to_string();
    let mut out = String::new();
    for (i, ch) in s.chars().enumerate() {
        if i > 0 && (s.len() - i).is_multiple_of(3) {
            out.push('.');
        }
        out.push(ch);
    }
    if h % 2 == 1 {
        out.push_str(",5");
    }
    if neg {
        format!("−{out}")
    } else {
        out
    }
}

fn signed_chips(halves: i64) -> String {
    if halves > 0 {
        format!("+{}", chips_text(halves))
    } else if halves == 0 {
        "±0".into()
    } else {
        chips_text(halves)
    }
}

fn one_decimal(x: f64) -> String {
    let s = format!("{:.1}", x).replace('.', ",");
    if x > 0.05 {
        format!("+{s}")
    } else if s == "-0,0" {
        "0,0".into()
    } else {
        s.replace('-', "−")
    }
}

// ---------------------------------------------------------------------------------------------
// Basic strategy (6 decks, S17, DAS, no surrender)

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Act {
    Hit,
    Stand,
    Double,
    Split,
}

impl Act {
    pub fn key(self) -> &'static str {
        match self {
            Act::Hit => "hit",
            Act::Stand => "stand",
            Act::Double => "double",
            Act::Split => "split",
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Act::Hit => "Kart",
            Act::Stand => "Dur",
            Act::Double => "İkiye katla",
            Act::Split => "Böl",
        }
    }
}

/// Table cell before applying "can't double": `D` double else hit, `Ds` double else stand.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Cell {
    H,
    S,
    D,
    Ds,
    P,
}

/// Should the pair of `v` (card value, 1 = aces) be split against `up` (2..=11)?
pub fn split_pair(v: u8, up: u8) -> bool {
    match v {
        1 | 8 => true,
        5 | 10 => false,
        9 => matches!(up, 2..=6 | 8 | 9),
        7 | 2 | 3 => up <= 7,
        6 => up <= 6,
        4 => up == 5 || up == 6,
        _ => false,
    }
}

/// Totals table cell (no split considered).
pub fn total_cell(total: u8, soft: bool, up: u8) -> Cell {
    use Cell::*;
    if soft {
        match total {
            0..=12 => H,
            13 | 14 => {
                if (5..=6).contains(&up) {
                    D
                } else {
                    H
                }
            }
            15 | 16 => {
                if (4..=6).contains(&up) {
                    D
                } else {
                    H
                }
            }
            17 => {
                if (3..=6).contains(&up) {
                    D
                } else {
                    H
                }
            }
            18 => match up {
                3..=6 => Ds,
                2 | 7 | 8 => S,
                _ => H,
            },
            _ => S,
        }
    } else {
        match total {
            0..=8 => H,
            9 => {
                if (3..=6).contains(&up) {
                    D
                } else {
                    H
                }
            }
            10 => {
                if up <= 9 {
                    D
                } else {
                    H
                }
            }
            11 => {
                if up <= 10 {
                    D
                } else {
                    H
                }
            }
            12 => {
                if (4..=6).contains(&up) {
                    S
                } else {
                    H
                }
            }
            13..=16 => {
                if up <= 6 {
                    S
                } else {
                    H
                }
            }
            _ => S,
        }
    }
}

/// Basic-strategy action for a hand. `pair` = value of a splittable pair (first two cards equal
/// in value), `up` = dealer up card 2..=11.
pub fn basic_action(total: u8, soft: bool, pair: Option<u8>, up: u8, can_double: bool, can_split: bool) -> Act {
    if let Some(v) = pair {
        if can_split && split_pair(v, up) {
            return Act::Split;
        }
    }
    match total_cell(total, soft, up) {
        Cell::H => Act::Hit,
        Cell::S | Cell::P => Act::Stand,
        Cell::D => {
            if can_double {
                Act::Double
            } else {
                Act::Hit
            }
        }
        Cell::Ds => {
            if can_double {
                Act::Double
            } else {
                Act::Stand
            }
        }
    }
}

/// Short Turkish reason for the basic-strategy action.
pub fn reason(total: u8, soft: bool, pair: Option<u8>, up: u8, act: Act, can_double: bool) -> String {
    let u = up_name(up);
    let weak = (2..=6).contains(&up);
    if let Some(v) = pair {
        match (v, act) {
            (1, Act::Split) => return "Asları her zaman böl: iki el de 11'den başlar, yumuşak 12 ise zayıf bir el.".into(),
            (8, Act::Split) => return "8-8 = 16, oyunun en kötü toplamı; bölersen iki tane 8'den başlarsın → böl.".into(),
            (10, _) if act == Act::Stand => return "20'yi bozma: 10'luları bölmek kazanan bir eli iki vasat ele çevirir → dur.".into(),
            (9, Act::Split) => return format!("9-9 = 18; krupiye {u} karşısında iki tane 9 tek bir 18'den daha çok kazanır → böl."),
            (9, Act::Stand) if up == 7 => return "Krupiye 7 ile çoğunlukla 17'de kalır; 18'in onu zaten yener → dur.".into(),
            (9, Act::Stand) => return format!("Krupiye {u} güçlü; 9'larla yeniden başlamak 18'den kötü → dur."),
            (7, Act::Split) => return format!("7-7 = 14 zayıf; krupiye {u} karşısında her 7'den daha iyi el çıkar → böl."),
            (6, Act::Split) => return format!("6-6 = 12 zayıf; krupiye {u} batmaya yatkın, iki 6 ile ondan yararlan → böl."),
            (4, Act::Split) => return format!("Krupiye {u} çok zayıf; bölünce 4'lerden katlanabilir eller doğar (DAS) → böl."),
            (2 | 3, Act::Split) => return format!("Krupiye {u} karşısında küçük çiftleri böl; bölme sonrası katlama serbest."),
            (5, Act::Double) => return format!("5-5'i bölme: 10 güçlü bir katlama eli; krupiye {u} → ikiye katla."),
            (5, Act::Hit) => return format!("5-5'i bölme: 10 güçlü bir başlangıç; krupiye {u} karşısında sadece kart çek."),
            _ => {}
        }
    }
    let no_dbl = !can_double && matches!(total_cell(total, soft, up), Cell::D | Cell::Ds);
    if soft {
        let s = match (total, act) {
            (12, _) => "Yumuşak 12'de batamazsın → kart çek.".to_string(),
            (13..=17, Act::Double) => {
                format!("Yumuşak {total} batmaz ve krupiye {u} zayıf → ikiye katla: tek kart, iki kat bahis.")
            }
            (13..=17, _) => format!("Yumuşak {total} henüz zayıf; As sayesinde kart çekince batmazsın → kart çek."),
            (18, Act::Double) => format!("Yumuşak 18'i krupiyenin zayıf kartına ({u}) karşı ikiye katla."),
            (18, Act::Stand) if weak => format!("Yumuşak 18 krupiye {u} karşısında iyi; iki kartı geçtiğin için katlayamazsın → dur."),
            (18, Act::Stand) => format!("Yumuşak 18 krupiye {u} karşısında yeterince iyi → dur."),
            (18, _) => format!("Krupiye {u} karşısında 18 çoğu zaman kaybeder; yumuşak el batmaz → kart çek."),
            _ => format!("Yumuşak {total} güçlü bir el → dur."),
        };
        return if no_dbl && act == Act::Hit {
            format!("{s} (Üç kartla katlanamaz.)")
        } else {
            s
        };
    }
    let s = match (total, act) {
        (0..=8, _) => format!("{total} ile hiçbir kart seni batıramaz → kart çek."),
        (9, Act::Double) => format!("Krupiye {u} zayıf; 9'dan 10'lu kartla 19 yaparsın → ikiye katla."),
        (9, _) => format!("Krupiye {u} karşısında 9'da katlamak kârlı değil → sadece kart çek."),
        (10, Act::Double) => format!("10'da en olası kart 10'luk (~%31) → 20; krupiye {u} → ikiye katla."),
        (10, _) if up >= 10 => format!("Krupiye {u} senin 10'un kadar güçlü → katlama, sadece kart çek."),
        (10, _) => "10'da batma riski yok → kart çek.".into(),
        (11, Act::Double) => format!("11'de 10'lu kart 21 yapar ve batma riski yok; krupiye {u} → ikiye katla."),
        (11, _) if up == 11 => "Krupiye As'ta (17'de duran masada) 11'de katlamak az farkla kötü → kart çek.".into(),
        (11, _) => "11'de batma riski yok → kart çek.".into(),
        (12, Act::Stand) => format!("Krupiye {u} gösteriyor, batma olasılığı yüksek (~%40) → 12'de dur."),
        (12, _) if up <= 3 => format!("Krupiye {u} yeterince sık batmaz; 12'de seni sadece 10'lu kart batırır → kart çek."),
        (12, _) => format!("Krupiye {u} ile çoğunlukla 17+ yapar; 12'de seni sadece 10'lu kart batırır → kart çek."),
        (13..=16, Act::Stand) => {
            format!("Krupiye {u} gösteriyor, batma olasılığı yüksek → {} dur, riski krupiyeye bırak.", loc(total))
        }
        (13..=16, _) => format!("Krupiye {u} ile çoğunlukla 17+ yapar; {total} durarak zaten kaybeder → kart çek."),
        _ => format!("{total} güçlü bir toplam; kart çekmek çoğu zaman batırır → dur."),
    };
    if no_dbl && act == Act::Hit {
        format!("{s} (Üç kartla katlanamaz.)")
    } else {
        s
    }
}

pub const INSURANCE_REASON: &str = "Sigorta kötü bir bahis: kapalı kartın 10'lu olma olasılığı yaklaşık %31, \
2:1 ödemenin kâr etmesi için %33'ten fazlası gerekir → alma.";

/// An index play: the deviating action and its explanation.
pub type Deviation = Option<(Act, String)>;

/// Illustrious-18 style index plays for this game (6 decks, S17). Returns the deviating action and
/// its explanation when the true count calls for it (only when it differs from basic strategy).
pub fn deviation(total: u8, soft: bool, pair: Option<u8>, up: u8, tc: f64, can_double: bool, can_split: bool) -> Option<(Act, String)> {
    let bs = basic_action(total, soft, pair, up, can_double, can_split);
    let note = |act: Act, idx: &str| {
        Some((act, format!("Sayım notu: gerçek sayım {} ({idx}) → sayan oyuncu burada {} der (Illustrious 18).", one_decimal(tc), act.label())))
    };
    if pair == Some(10) && can_split {
        if up == 5 && tc >= 5.0 {
            return note(Act::Split, "≥ +5");
        }
        if up == 6 && tc >= 4.0 {
            return note(Act::Split, "≥ +4");
        }
    }
    if soft || bs == Act::Split {
        return None;
    }
    let r = match (total, up) {
        (16, 10) if tc >= 0.0 => note(Act::Stand, "≥ 0"),
        (15, 10) if tc >= 4.0 => note(Act::Stand, "≥ +4"),
        (10, 10) if tc >= 4.0 && can_double => note(Act::Double, "≥ +4"),
        (12, 3) if tc >= 2.0 => note(Act::Stand, "≥ +2"),
        (12, 2) if tc >= 3.0 => note(Act::Stand, "≥ +3"),
        (11, 11) if tc >= 1.0 && can_double => note(Act::Double, "≥ +1"),
        (9, 2) if tc >= 1.0 && can_double => note(Act::Double, "≥ +1"),
        (10, 11) if tc >= 4.0 && can_double => note(Act::Double, "≥ +4"),
        (9, 7) if tc >= 3.0 && can_double => note(Act::Double, "≥ +3"),
        (16, 9) if tc >= 5.0 => note(Act::Stand, "≥ +5"),
        (13, 2) if tc < -1.0 => note(Act::Hit, "< −1"),
        (12, 4) if tc < 0.0 => note(Act::Hit, "< 0"),
        (12, 5) if tc < -2.0 => note(Act::Hit, "< −2"),
        (12, 6) if tc < -1.0 => note(Act::Hit, "< −1"),
        (13, 3) if tc < -2.0 => note(Act::Hit, "< −2"),
        _ => None,
    };
    r.filter(|(a, _)| *a != bs)
}

// ---------------------------------------------------------------------------------------------
// Perfect-information search (open mode): the next K cards are known, the rest is modelled as
// independent draws from the remaining shoe composition.

#[derive(Clone, Copy, Debug)]
struct SimHand {
    hard: u8,
    ace: bool,
    n: u8,
    first: u8,
    pair: bool,
    mult: f64,
    done: bool,
    split_aces: bool,
}

impl SimHand {
    fn single(v: u8, split_aces: bool) -> Self {
        SimHand { hard: v, ace: v == 1, n: 1, first: v, pair: false, mult: 1.0, done: false, split_aces }
    }
    fn total(&self) -> u8 {
        tot(self.hard, self.ace).0
    }
    fn add(&mut self, v: u8) {
        if self.n == 1 {
            self.pair = v == self.first;
        } else {
            self.pair = false;
        }
        self.hard += v;
        self.ace |= v == 1;
        self.n += 1;
        let t = self.total();
        if t >= 21 || self.split_aces {
            self.done = true;
        }
    }
}

/// Dealer outcome distribution: index 0..=4 = final 17..=21, 5 = bust.
type Dist = [f64; 6];

struct Perfect {
    known: Vec<u8>,
    p: [f64; 11],
    dh: u8,
    da: bool,
    dist: Vec<[Dist; 2]>, // by dealer hard sum, ace flag (all-unknown draws)
    du: Dist,             // dealer distribution when every dealer draw is unknown
    nodbl: Vec<[f64; 2]>, // optimal hit/stand EV vs `du` by player hard sum, ace flag
}

fn point(t: u8) -> Dist {
    let mut d = [0.0; 6];
    if t > 21 {
        d[5] = 1.0;
    } else {
        d[(t.max(17) - 17) as usize] = 1.0;
    }
    d
}

fn vs(d: &Dist, total: u8) -> f64 {
    if total > 21 {
        return -1.0;
    }
    let mut ev = d[5];
    for (i, &pr) in d.iter().take(5).enumerate() {
        let dt = 17 + i as u8;
        if total > dt {
            ev += pr;
        } else if total < dt {
            ev -= pr;
        }
    }
    ev
}

impl Perfect {
    fn new(known: Vec<u8>, rest: &[Card], dealer_hard: u8, dealer_ace: bool) -> Self {
        let mut counts = [0.0f64; 11];
        for c in rest {
            counts[c.value() as usize] += 1.0;
        }
        let n: f64 = counts.iter().sum();
        let mut p = [0.0; 11];
        for v in 1..=10 {
            p[v] = if n > 0.0 { counts[v] / n } else if v == 10 { 4.0 / 13.0 } else { 1.0 / 13.0 };
        }
        // Dealer distribution, bottom-up from high sums.
        let mut dist = vec![[[0.0; 6]; 2]; 32];
        for h in (2..32usize).rev() {
            for a in 0..2 {
                let (t, _) = tot(h as u8, a == 1);
                if t >= 17 {
                    dist[h][a] = point(t);
                } else {
                    let mut d = [0.0; 6];
                    for v in 1..=10usize {
                        let nh = h + v;
                        let na = if a == 1 || v == 1 { 1 } else { 0 };
                        for k in 0..6 {
                            d[k] += p[v] * dist[nh][na][k];
                        }
                    }
                    dist[h][a] = d;
                }
            }
        }
        let du = dist[dealer_hard as usize][dealer_ace as usize];
        let mut nodbl = vec![[0.0; 2]; 32];
        for h in (2..32usize).rev() {
            for a in 0..2 {
                let (t, _) = tot(h as u8, a == 1);
                if t > 21 {
                    nodbl[h][a] = -1.0;
                    continue;
                }
                let stand = vs(&du, t);
                if t == 21 {
                    nodbl[h][a] = stand;
                    continue;
                }
                let mut hit = 0.0;
                for v in 1..=10usize {
                    let nh = (h + v).min(31);
                    let na = if a == 1 || v == 1 { 1 } else { 0 };
                    hit += p[v] * nodbl[nh][na];
                }
                nodbl[h][a] = stand.max(hit);
            }
        }
        Perfect { known, p, dh: dealer_hard, da: dealer_ace, dist, du, nodbl }
    }

    fn k(&self) -> usize {
        self.known.len()
    }

    /// Dealer outcome when the dealer starts drawing at known index `pos`.
    fn dealer_from(&self, pos: usize) -> Dist {
        let (mut h, mut a, mut p) = (self.dh, self.da, pos);
        loop {
            let (t, _) = tot(h, a);
            if t >= 17 {
                return point(t);
            }
            if p >= self.k() {
                return self.dist[h as usize][a as usize];
            }
            let v = self.known[p];
            h += v;
            a |= v == 1;
            p += 1;
        }
    }

    /// EV of an unfinished 2+-card hand when every future card is unknown.
    fn ev_unknown(&self, h: &SimHand) -> f64 {
        let can_double = h.n == 2 && !h.split_aces;
        let base = self.nodbl[h.hard as usize][h.ace as usize];
        if !can_double {
            return base;
        }
        let mut dbl = 0.0;
        for v in 1..=10u8 {
            let (t, _) = tot(h.hard + v, h.ace || v == 1);
            dbl += self.p[v as usize] * vs(&self.du, t);
        }
        base.max(2.0 * dbl)
    }

    /// EV of a one-card split hand when every future card is unknown.
    fn ev_fresh(&self, h: &SimHand) -> f64 {
        let mut ev = 0.0;
        for v in 1..=10u8 {
            let mut x = *h;
            x.add(v);
            let e = if x.done { vs(&self.du, x.total()) } else { self.ev_unknown(&x) };
            ev += self.p[v as usize] * e;
        }
        ev
    }

    fn rest_unknown(&self, hands: &[SimHand], active: usize) -> f64 {
        hands
            .iter()
            .enumerate()
            .map(|(i, h)| {
                if h.done || i < active {
                    h.mult * vs(&self.du, h.total())
                } else if h.n == 1 {
                    self.ev_fresh(h)
                } else {
                    h.mult * self.ev_unknown(h)
                }
            })
            .sum()
    }

    fn final_score(&self, hands: &[SimHand], pos: usize) -> f64 {
        if hands.iter().all(|h| h.total() > 21) {
            return hands.iter().map(|h| -h.mult).sum();
        }
        let d = self.dealer_from(pos);
        hands.iter().map(|h| h.mult * vs(&d, h.total())).sum()
    }

    /// Optimal EV from here (max over the player's choices).
    fn search(&self, mut hands: Vec<SimHand>, mut active: usize, mut pos: usize) -> f64 {
        loop {
            if active >= hands.len() {
                return self.final_score(&hands, pos);
            }
            if hands[active].done {
                active += 1;
                continue;
            }
            if hands[active].n == 1 {
                if pos >= self.k() {
                    return self.rest_unknown(&hands, active);
                }
                let v = self.known[pos];
                hands[active].add(v);
                pos += 1;
                continue;
            }
            break;
        }
        if pos >= self.k() {
            return self.rest_unknown(&hands, active);
        }
        let mut best = f64::NEG_INFINITY;
        for act in [Act::Stand, Act::Hit, Act::Double, Act::Split] {
            if let Some(ev) = self.apply(&hands, active, pos, act) {
                best = best.max(ev);
            }
        }
        best
    }

    /// EV of taking `act` on hands[active] (which has ≥ 2 cards); None when not allowed.
    fn apply(&self, hands: &[SimHand], active: usize, pos: usize, act: Act) -> Option<f64> {
        let h = hands[active];
        let mut hs = hands.to_vec();
        match act {
            Act::Stand => {
                hs[active].done = true;
                Some(self.search(hs, active, pos))
            }
            Act::Hit | Act::Double => {
                if act == Act::Double && (h.n != 2 || h.split_aces) {
                    return None;
                }
                if pos >= self.k() {
                    // Only reachable at the root with an empty window: use the unknown model.
                    let mut ev = 0.0;
                    for v in 1..=10u8 {
                        let mut x = hs.clone();
                        x[active].add(v);
                        if act == Act::Double {
                            x[active].mult *= 2.0;
                            x[active].done = true;
                        }
                        ev += self.p[v as usize] * self.rest_unknown(&x, active);
                    }
                    return Some(ev);
                }
                hs[active].add(self.known[pos]);
                if act == Act::Double {
                    hs[active].mult *= 2.0;
                    hs[active].done = true;
                }
                Some(self.search(hs, active, pos + 1))
            }
            Act::Split => {
                if !(h.n == 2 && h.pair && hands.len() < MAX_HANDS && !h.split_aces) {
                    return None;
                }
                let aces = h.first == 1;
                hs[active] = SimHand::single(h.first, aces);
                hs.insert(active + 1, SimHand::single(h.first, aces));
                Some(self.search(hs, active, pos))
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Session

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mode {
    Classic,
    Coach,
    Count,
    Open,
}

impl Mode {
    fn key(self) -> &'static str {
        match self {
            Mode::Classic => "classic",
            Mode::Coach => "coach",
            Mode::Count => "count",
            Mode::Open => "open",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Phase {
    Bet,
    Insurance,
    Play,
    Dealer,
    Settle,
    CountQuiz,
    Done,
}

impl Phase {
    fn key(self) -> &'static str {
        match self {
            Phase::Bet => "bet",
            Phase::Insurance => "insurance",
            Phase::Play => "play",
            Phase::Dealer => "dealer",
            Phase::Settle => "settle",
            Phase::CountQuiz => "count_quiz",
            Phase::Done => "done",
        }
    }
}

#[derive(Clone, Debug)]
struct Hand {
    cards: Vec<(u32, Card)>,
    bet_h: i64, // half-chips, includes the double
    doubled: bool,
    from_split: bool,
    split_aces: bool,
    done: bool,
    result: Option<&'static str>,
    net_h: i64,
}

impl Hand {
    fn new(bet_h: i64) -> Self {
        Hand { cards: vec![], bet_h, doubled: false, from_split: false, split_aces: false, done: false, result: None, net_h: 0 }
    }
    fn plain(&self) -> Vec<Card> {
        self.cards.iter().map(|c| c.1).collect()
    }
    fn total(&self) -> (u8, bool) {
        hand_total(&self.plain())
    }
    fn natural(&self) -> bool {
        !self.from_split && is_blackjack(&self.plain())
    }
    fn pair_value(&self) -> Option<u8> {
        if self.cards.len() == 2 && self.cards[0].1.value() == self.cards[1].1.value() {
            Some(self.cards[0].1.value())
        } else {
            None
        }
    }
}

pub struct Blackjack {
    mode: Mode,
    seed: u64,
    rng: Rng,
    shoe: Vec<Card>,
    pos: usize,
    cut: usize,
    next_id: u32,
    shuffled: bool,
    phase: Phase,
    bank_h: i64,
    bet: i64,
    hands: Vec<Hand>,
    active: usize,
    dealer: Vec<(u32, Card)>,
    hole_revealed: bool,
    insurance_offered: bool,
    insurance_h: i64,
    insurance_net_h: Option<i64>,
    running: i32,
    hands_played: u32,
    decisions: u32,
    correct: u32,
    feedback: Option<Value>,
    serial: u32,
    hint: Option<Value>,
    hints: u32,
    quiz_total: u32,
    quiz_right: u32,
    quiz: Option<Value>,
    peeked: bool,
    status: &'static str,
    message: String,
    round_net_h: i64,
    fixed_shoe: bool,
}

pub fn create(_level: u32, mode: &str) -> Result<Box<dyn Session>, String> {
    let m = match mode {
        "classic" | "level" => Mode::Classic,
        "coach" => Mode::Coach,
        "count" => Mode::Count,
        "open" => Mode::Open,
        _ => return Err(format!("Bilinmeyen masa: {mode}")),
    };
    Ok(Box::new(Blackjack::new(m, time_seed())))
}

fn fresh_shoe(rng: &mut Rng) -> Vec<Card> {
    let mut v = Vec::with_capacity(52 * DECKS);
    for _ in 0..DECKS {
        for s in 0..4 {
            for r in 2..=14 {
                v.push(Card::new(r, s));
            }
        }
    }
    rng.shuffle(&mut v);
    v
}

impl Blackjack {
    pub fn new(mode: Mode, seed: u64) -> Self {
        let mut g = Blackjack {
            mode,
            seed,
            rng: Rng::new(seed),
            shoe: vec![],
            pos: 0,
            cut: 0,
            next_id: 1,
            shuffled: false,
            phase: Phase::Bet,
            bank_h: START_CHIPS * 2,
            bet: 25,
            hands: vec![],
            active: 0,
            dealer: vec![],
            hole_revealed: false,
            insurance_offered: false,
            insurance_h: 0,
            insurance_net_h: None,
            running: 0,
            hands_played: 0,
            decisions: 0,
            correct: 0,
            feedback: None,
            serial: 0,
            hint: None,
            hints: 0,
            quiz_total: 0,
            quiz_right: 0,
            quiz: None,
            peeked: false,
            status: "playing",
            message: String::new(),
            round_net_h: 0,
            fixed_shoe: false,
        };
        g.reshuffle();
        g.shuffled = false;
        g
    }

    /// Test helper: the shoe starts with exactly `cards` (in deal order), followed by a shuffled
    /// shoe; no reshuffle happens.
    #[cfg(test)]
    fn with_cards(mode: Mode, cards: &[Card]) -> Self {
        let mut g = Blackjack::new(mode, 1);
        let mut shoe = cards.to_vec();
        shoe.extend(fresh_shoe(&mut Rng::new(99)));
        g.shoe = shoe;
        g.pos = 0;
        g.cut = usize::MAX;
        g.fixed_shoe = true;
        g
    }

    fn reshuffle(&mut self) {
        self.shoe = fresh_shoe(&mut self.rng);
        self.pos = 0;
        let jitter = self.rng.range(-8, 8);
        self.cut = (self.shoe.len() as i64 * 3 / 4 + jitter) as usize;
        self.running = 0;
        self.shuffled = true;
    }

    fn draw(&mut self, visible: bool) -> (u32, Card) {
        if self.pos >= self.shoe.len() {
            // Cannot happen with a 75 % cut card, but never panic: continue with a fresh shoe.
            self.reshuffle();
        }
        let c = self.shoe[self.pos];
        self.pos += 1;
        if visible {
            self.running += c.hilo();
        }
        let id = self.next_id;
        self.next_id += 1;
        (id, c)
    }

    fn up(&self) -> Card {
        self.dealer[0].1
    }

    /// Up card as 2..=11.
    fn up_val(&self) -> u8 {
        match self.up().value() {
            1 => 11,
            v => v,
        }
    }

    fn dealer_plain(&self) -> Vec<Card> {
        self.dealer.iter().map(|c| c.1).collect()
    }

    fn decks_left(&self) -> f64 {
        let hidden = if !self.dealer.is_empty() && !self.hole_revealed { 1 } else { 0 };
        ((self.shoe.len() - self.pos + hidden) as f64 / 52.0).max(0.25)
    }

    fn true_count(&self) -> f64 {
        self.running as f64 / self.decks_left()
    }

    fn total_h(&self) -> i64 {
        self.bank_h
    }

    // --- legality -------------------------------------------------------------------------

    fn can_double(&self) -> bool {
        self.phase == Phase::Play
            && self.hands.get(self.active).is_some_and(|h| h.cards.len() == 2 && !h.split_aces && !h.done && self.bank_h >= h.bet_h)
    }

    fn can_split(&self) -> bool {
        self.phase == Phase::Play
            && self.hands.len() < MAX_HANDS
            && self.hands.get(self.active).is_some_and(|h| {
                h.pair_value().is_some() && !h.split_aces && !h.done && self.bank_h >= h.bet_h
            })
    }

    fn actions(&self) -> Vec<&'static str> {
        match self.phase {
            Phase::Bet => vec!["bet", "deal"],
            Phase::Insurance => vec!["insurance"],
            Phase::Play => {
                let mut v = vec!["hit", "stand"];
                if self.can_double() {
                    v.push("double");
                }
                if self.can_split() {
                    v.push("split");
                }
                v
            }
            Phase::Dealer => vec!["ai"],
            Phase::Settle => vec!["next"],
            Phase::CountQuiz => vec!["count_answer"],
            Phase::Done => vec![],
        }
    }

    /// Basic-strategy action (and reason) for the active hand given what is legal.
    fn bs_now(&self) -> Option<(Act, String, Deviation)> {
        if self.phase != Phase::Play {
            return None;
        }
        let h = self.hands.get(self.active)?;
        let (t, soft) = h.total();
        let pair = h.pair_value();
        let up = self.up_val();
        let (cd, cs) = (self.can_double(), self.can_split());
        let act = basic_action(t, soft, pair, up, cd, cs);
        let why = reason(t, soft, if cs { pair } else { None }, up, act, cd);
        let dev = deviation(t, soft, if cs { pair } else { None }, up, self.true_count(), cd, cs);
        Some((act, why, dev))
    }

    #[allow(clippy::too_many_arguments)]
    fn record_decision(&mut self, key: &str, label: &str, best: Act, best_label: &str, why: String, dev: Deviation, chosen: Option<Act>) {
        let mut ok = chosen == Some(best);
        let dev_text = dev.as_ref().map(|d| d.1.clone());
        if self.mode == Mode::Count {
            if let (Some((da, _)), Some(c)) = (&dev, chosen) {
                if *da == c {
                    ok = true;
                }
            }
        }
        self.decisions += 1;
        if ok {
            self.correct += 1;
        }
        self.serial += 1;
        self.feedback = Some(json!({
            "serial": self.serial,
            "action": key,
            "action_label": label,
            "correct": ok,
            "best": best.key(),
            "best_label": best_label,
            "reason": why,
            "deviation": dev_text,
        }));
    }

    // --- flow -----------------------------------------------------------------------------

    fn enter_bet(&mut self) {
        self.hands.clear();
        self.dealer.clear();
        self.active = 0;
        self.hole_revealed = false;
        self.insurance_offered = false;
        self.insurance_h = 0;
        self.insurance_net_h = None;
        self.hint = None;
        self.shuffled = false;
        if !self.fixed_shoe && self.pos >= self.cut {
            self.reshuffle();
        }
        if self.bank_h < MIN_BET * 2 {
            self.finish("Fişin bitti");
            return;
        }
        let max = (self.bank_h / 2).min(MAX_BET);
        self.bet = (self.bet.min(max) / 5 * 5).max(MIN_BET);
        self.phase = Phase::Bet;
    }

    fn finish(&mut self, why: &str) {
        self.phase = Phase::Done;
        let start = START_CHIPS * 2;
        self.status = if self.bank_h > start {
            "won"
        } else if self.bank_h == start {
            "draw"
        } else {
            "lost"
        };
        self.message = why.to_string();
    }

    fn deal(&mut self) {
        self.round_net_h = 0;
        self.message.clear();
        self.feedback = None;
        self.bank_h -= self.bet * 2;
        let mut h = Hand::new(self.bet * 2);
        let c1 = self.draw(true);
        h.cards.push(c1);
        let up = self.draw(true);
        self.dealer.push(up);
        let c2 = self.draw(true);
        h.cards.push(c2);
        let hole = self.draw(false);
        self.dealer.push(hole);
        self.hands = vec![h];
        self.active = 0;
        self.hole_revealed = false;
        if self.up().rank == 14 {
            self.insurance_offered = true;
            self.phase = Phase::Insurance;
        } else {
            self.after_peek();
        }
    }

    fn reveal_hole(&mut self) {
        if !self.hole_revealed && self.dealer.len() >= 2 {
            self.hole_revealed = true;
            self.running += self.dealer[1].1.hilo();
        }
    }

    /// Dealer peek (ace or ten up), then blackjack checks, then play.
    fn after_peek(&mut self) {
        let dealer_bj = is_blackjack(&self.dealer_plain());
        if self.insurance_h > 0 {
            if dealer_bj {
                self.bank_h += self.insurance_h * 3;
                self.insurance_net_h = Some(self.insurance_h * 2);
            } else {
                self.insurance_net_h = Some(-self.insurance_h);
            }
            self.round_net_h += self.insurance_net_h.unwrap_or(0);
        }
        if dealer_bj || self.hands[0].natural() {
            for h in self.hands.iter_mut() {
                h.done = true;
            }
            self.settle();
            return;
        }
        self.phase = Phase::Play;
        self.advance();
    }

    /// Move to the next unfinished hand (dealing the second card to split hands); when all hands
    /// are finished, hand over to the dealer.
    fn advance(&mut self) {
        while self.active < self.hands.len() {
            if self.hands[self.active].cards.len() == 1 {
                let c = self.draw(true);
                let h = &mut self.hands[self.active];
                h.cards.push(c);
                if h.split_aces {
                    h.done = true;
                }
            }
            let h = &mut self.hands[self.active];
            if h.total().0 >= 21 {
                h.done = true;
            }
            if !h.done {
                return;
            }
            self.active += 1;
        }
        self.phase = Phase::Dealer;
    }

    fn dealer_needs_card(&self) -> bool {
        let live = self.hands.iter().any(|h| h.total().0 <= 21);
        live && hand_total(&self.dealer_plain()).0 < 17
    }

    fn dealer_step(&mut self) {
        if !self.hole_revealed {
            self.reveal_hole();
        } else if self.dealer_needs_card() {
            let c = self.draw(true);
            self.dealer.push(c);
        }
        if !self.dealer_needs_card() {
            self.settle();
        }
    }

    fn settle(&mut self) {
        self.reveal_hole();
        let dealer = self.dealer_plain();
        let dealer_bj = is_blackjack(&dealer);
        let (dt, _) = hand_total(&dealer);
        let mut net_sum = 0;
        for h in self.hands.iter_mut() {
            let (t, _) = h.total();
            let natural = h.natural();
            let (res, net): (&'static str, i64) = if t > 21 {
                ("bust", -h.bet_h)
            } else if dealer_bj {
                if natural {
                    ("push", 0)
                } else {
                    ("lose", -h.bet_h)
                }
            } else if natural {
                ("blackjack", h.bet_h * 3 / 2)
            } else if dt > 21 || t > dt {
                ("win", h.bet_h)
            } else if t == dt {
                ("push", 0)
            } else {
                ("lose", -h.bet_h)
            };
            h.result = Some(res);
            h.net_h = net;
            h.done = true;
            if net >= 0 {
                self.bank_h += h.bet_h + net;
            }
            net_sum += net;
        }
        self.round_net_h += net_sum;
        self.hands_played += 1;
        self.active = self.hands.len();
        self.phase = Phase::Settle;
        self.message = self.settle_message(dealer_bj, dt);
    }

    fn settle_message(&self, dealer_bj: bool, dt: u8) -> String {
        let net = signed_chips(self.round_net_h);
        let head = if dealer_bj {
            "Krupiye blackjack yaptı".to_string()
        } else if self.hands.len() == 1 && self.hands[0].result == Some("blackjack") {
            "Blackjack! 3:2 ödendi".to_string()
        } else if self.hands.iter().all(|h| h.result == Some("bust")) {
            "Battın".to_string()
        } else if dt > 21 {
            "Krupiye battı".to_string()
        } else {
            format!("Krupiye {dt}")
        };
        format!("{head} · {net}")
    }

    fn after_settle(&mut self) {
        if self.hands_played >= HANDS_PER_MATCH {
            self.finish("Masa bitti");
        } else if self.bank_h < MIN_BET * 2 {
            self.finish("Fişin bitti");
        } else if self.mode == Mode::Count && self.hands_played.is_multiple_of(QUIZ_EVERY) {
            self.phase = Phase::CountQuiz;
        } else {
            self.enter_bet();
        }
    }

    // --- open play ------------------------------------------------------------------------

    fn open_visible(&self) -> bool {
        self.mode == Mode::Open || self.peeked
    }

    fn next_cards(&self, n: usize) -> Vec<Card> {
        self.shoe[self.pos..(self.pos + n).min(self.shoe.len())].to_vec()
    }

    fn perfect(&self) -> Perfect {
        let known: Vec<Card> = self.next_cards(OPEN_CARDS);
        let rest = &self.shoe[(self.pos + known.len()).min(self.shoe.len())..];
        let d = self.dealer_plain();
        let hard: u8 = d.iter().map(|c| c.value()).sum();
        let ace = d.iter().any(|c| c.rank == 14);
        Perfect::new(known.iter().map(|c| c.value()).collect(), rest, hard, ace)
    }

    fn sim_hands(&self) -> Vec<SimHand> {
        self.hands
            .iter()
            .map(|h| {
                let mut s = SimHand::single(h.cards[0].1.value(), h.split_aces);
                s.done = false;
                for c in &h.cards[1..] {
                    s.add(c.1.value());
                }
                s.mult = if h.doubled { 2.0 } else { 1.0 };
                s.done = h.done;
                s
            })
            .collect()
    }

    /// Best action with the hole card and the next cards known, vs basic strategy.
    fn open_hint(&self) -> Option<Value> {
        if self.phase == Phase::Insurance {
            let ten = self.dealer[1].1.value() == 10;
            let best = if ten { "Sigorta al" } else { "Sigorta yok" };
            let why = if ten {
                format!("Kapalı kart {}: krupiyede blackjack var, sigorta 2:1 kazanır. Temel strateji yine de 'alma' der, çünkü normalde bunu bilemezsin.", rank_name(self.dealer[1].1.rank))
            } else {
                format!("Kapalı kart {}: krupiyede blackjack yok, sigorta kaybeder. Temel strateji de 'alma' der.", rank_name(self.dealer[1].1.rank))
            };
            return Some(json!({"best": if ten {"insurance"} else {"no_insurance"}, "best_label": best,
                "bs": "no_insurance", "bs_label": "Sigorta yok", "same": !ten, "reason": why, "evs": {}}));
        }
        if self.phase != Phase::Play {
            return None;
        }
        let (bs, _, _) = self.bs_now()?;
        let pf = self.perfect();
        let hands = self.sim_hands();
        let mut evs = serde_json::Map::new();
        let mut best: Option<(Act, f64)> = None;
        for act in [Act::Stand, Act::Hit, Act::Double, Act::Split] {
            let legal = match act {
                Act::Double => self.can_double(),
                Act::Split => self.can_split(),
                _ => true,
            };
            if !legal {
                continue;
            }
            if let Some(ev) = pf.apply(&hands, self.active, 0, act) {
                evs.insert(act.key().into(), json!((ev * 100.0).round() / 100.0));
                if best.is_none_or(|(_, b)| ev > b + 1e-9) {
                    best = Some((act, ev));
                }
            }
        }
        let (ba, bev) = best?;
        let bs_ev = evs.get(bs.key()).and_then(|v| v.as_f64()).unwrap_or(bev);
        // Treat near-ties as agreement (the basic play is just as good here).
        let same = ba == bs || (bev - bs_ev).abs() < 1e-6;
        let shown_best = if same { bs } else { ba };
        let hole = self.dealer[1].1;
        let (dt, ds) = hand_total(&self.dealer_plain());
        let mut why = format!(
            "Kapalı kart {} → krupiye {}{}. ",
            rank_name(hole.rank),
            if ds { "yumuşak " } else { "" },
            dt
        );
        if same {
            why.push_str(&format!("Temel strateji de bunu der: {}.", self.consequence(shown_best)));
        } else {
            why.push_str(&format!(
                "{}: {}. {}: {}.",
                bs.label(),
                self.consequence(bs),
                ba.label(),
                self.consequence(ba)
            ));
        }
        Some(json!({
            "best": shown_best.key(), "best_label": shown_best.label(),
            "bs": bs.key(), "bs_label": bs.label(),
            "same": same, "reason": why, "evs": Value::Object(evs),
        }))
    }

    /// What happens right after `act`, told from the known cards.
    fn consequence(&self, act: Act) -> String {
        let next = self.next_cards(OPEN_CARDS);
        let h = &self.hands[self.active];
        let Some(&c) = next.first() else {
            return "sıradaki kart bilinmiyor".into();
        };
        let mut cards = h.plain();
        match act {
            Act::Hit | Act::Double => {
                cards.push(c);
                let (t, _) = hand_total(&cards);
                let base = if act == Act::Double { "tek kart" } else { "sıradaki" };
                if t > 21 {
                    format!("{base} {} → {t}, batarsın", rank_name(c.rank))
                } else {
                    format!("{base} {} → {t}", rank_name(c.rank))
                }
            }
            Act::Split => format!("ilk ele {} gelir", rank_name(c.rank)),
            Act::Stand => {
                if self.active + 1 < self.hands.len() {
                    return "sıradaki kartlar diğer eline gider".into();
                }
                let mut d = self.dealer_plain();
                let mut drawn = vec![];
                let mut i = 0;
                while hand_total(&d).0 < 17 && i < next.len() {
                    d.push(next[i]);
                    drawn.push(rank_name(next[i].rank));
                    i += 1;
                }
                let (dt, _) = hand_total(&d);
                if dt < 17 {
                    "krupiyenin kartları açık destenin ötesine geçiyor".into()
                } else if drawn.is_empty() {
                    format!("krupiye {dt} ile kalır")
                } else if dt > 21 {
                    format!("krupiye {} çekip batar", drawn.join(", "))
                } else {
                    format!("krupiye {} çekip {dt} yapar", drawn.join(", "))
                }
            }
        }
    }

    // --- JSON -----------------------------------------------------------------------------

    fn hand_label(cards: &[Card], natural: bool) -> String {
        let (t, soft) = hand_total(cards);
        if natural {
            "Blackjack".into()
        } else if t > 21 {
            format!("Battı · {t}")
        } else if soft {
            format!("Yumuşak {t}")
        } else {
            format!("{t}")
        }
    }

    fn bet_advice(&self) -> Value {
        let tc = self.true_count();
        let units: i64 = if tc < 2.0 {
            1
        } else if tc < 3.0 {
            2
        } else if tc < 4.0 {
            4
        } else if tc < 5.0 {
            6
        } else {
            8
        };
        let amount = units * 25;
        let text = if units == 1 {
            format!("Gerçek sayım {} → avantaj krupiyede, en düşük bahis (1 birim = 25)", one_decimal(tc))
        } else {
            format!("Gerçek sayım {} → {units} birim ({amount})", one_decimal(tc))
        };
        json!({"units": units, "amount": amount, "text": text})
    }

    fn accuracy(&self) -> Option<u32> {
        if self.decisions == 0 {
            None
        } else {
            Some(((self.correct as f64 / self.decisions as f64) * 100.0).round() as u32)
        }
    }

    fn summary(&self) -> String {
        let mut s = format!("Fiş: {} · {} el", chips_text(self.bank_h), self.hands_played);
        match self.accuracy() {
            Some(a) => s.push_str(&format!(" · Doğru karar: %{a} ({}/{})", self.correct, self.decisions)),
            None => s.push_str(" · Karar yok"),
        }
        if self.mode == Mode::Count && self.quiz_total > 0 {
            s.push_str(&format!(" · Sayım: {}/{}", self.quiz_right, self.quiz_total));
        }
        if self.hints > 0 {
            s.push_str(&format!(" · İpucu: {}", self.hints));
        }
        if self.open_visible() {
            s.push_str(" · açık");
        }
        s
    }

    fn stars(&self) -> u32 {
        if self.status != "won" {
            return 0;
        }
        match self.accuracy().unwrap_or(100) {
            90.. => 3,
            75.. => 2,
            _ => 1,
        }
    }
}

impl Session for Blackjack {
    fn state(&self) -> Value {
        let hands: Vec<Value> = self
            .hands
            .iter()
            .enumerate()
            .map(|(i, h)| {
                let plain = h.plain();
                let (t, soft) = hand_total(&plain);
                let st = if t > 21 {
                    "bust"
                } else if h.natural() {
                    "blackjack"
                } else if self.phase == Phase::Play && i == self.active {
                    "active"
                } else if !h.done {
                    "waiting"
                } else if h.result.is_some() {
                    "done"
                } else {
                    "stand"
                };
                json!({
                    "cards": h.cards.iter().map(|(id, c)| json!({"id": id, "s": c.suit, "r": c.rank})).collect::<Vec<_>>(),
                    "total": t, "soft": soft, "label": Self::hand_label(&plain, h.natural()),
                    "bet": h.bet_h as f64 / 2.0, "doubled": h.doubled, "from_split": h.from_split,
                    "split_aces": h.split_aces, "done": h.done, "state": st,
                    "result": h.result, "net": h.net_h as f64 / 2.0,
                })
            })
            .collect();
        let dplain = self.dealer_plain();
        let (vis_t, vis_soft) = if self.hole_revealed || dplain.is_empty() {
            hand_total(&dplain)
        } else {
            hand_total(&dplain[..1])
        };
        let (full_t, _) = hand_total(&dplain);
        let dealer_label = if dplain.is_empty() {
            String::new()
        } else if self.hole_revealed && is_blackjack(&dplain) {
            "Blackjack".into()
        } else if self.hole_revealed {
            Self::hand_label(&dplain, false)
        } else {
            Self::hand_label(&dplain[..1], false)
        };
        let dealer = json!({
            "cards": self.dealer.iter().enumerate().map(|(i, (id, c))| json!({
                "id": id, "s": c.suit, "r": c.rank, "down": i == 1 && !self.hole_revealed
            })).collect::<Vec<_>>(),
            "total": vis_t, "soft": vis_soft, "label": dealer_label,
            "hole_revealed": self.hole_revealed, "full_total": full_t,
        });
        let acts = self.actions();
        let tc = self.true_count();
        let hand_no = (self.hands_played + if matches!(self.phase, Phase::Settle | Phase::Done | Phase::CountQuiz) { 0 } else { 1 })
            .clamp(1, HANDS_PER_MATCH);
        let ai = self.phase == Phase::Dealer && self.status == "playing";
        let mut v = json!({
            "status": self.status,
            "stars": self.stars(),
            "title": format!("El {hand_no}/{HANDS_PER_MATCH}"),
            "goal": "40 elde 1.000 fişi büyüt · krupiye 17'de durur · blackjack 3:2",
            "score": (self.bank_h / 2).max(0),
            "mode": self.mode.key(),
            "seed": self.seed,
            "phase": self.phase.key(),
            "turn": if ai { "dealer" } else { "you" },
            "ai_pending": ai,
            "chips": self.total_h() as f64 / 2.0,
            "chips_text": chips_text(self.bank_h),
            "bet": self.bet,
            "min_bet": MIN_BET,
            "max_bet": MAX_BET.min(self.bank_h / 2),
            "start_chips": START_CHIPS,
            "hand_no": hand_no,
            "hands_total": HANDS_PER_MATCH,
            "hands": hands,
            "active": self.active,
            "dealer": dealer,
            "hole": self.dealer.get(1).map(|c| c.1.json()),
            "next_cards": self.next_cards(OPEN_CARDS).iter().map(|c| c.json()).collect::<Vec<_>>(),
            "shoe_left": self.shoe.len() - self.pos,
            "shoe_total": self.shoe.len(),
            "cut_left": self.cut.saturating_sub(self.pos).min(self.shoe.len()),
            "decks_left": (self.decks_left() * 10.0).round() / 10.0,
            "shuffled": self.shuffled,
            "running_count": self.running,
            "true_count": (tc * 10.0).round() / 10.0,
            "true_count_text": one_decimal(tc),
            "bet_advice": self.bet_advice(),
        });
        let extra = json!({
            "actions": acts,
            "can": {
                "hit": self.phase == Phase::Play,
                "stand": self.phase == Phase::Play,
                "double": self.can_double(),
                "split": self.can_split(),
            },
            "insurance": {
                "offered": self.insurance_offered,
                "taken": self.insurance_h > 0,
                "amount": self.insurance_h as f64 / 2.0,
                "result": self.insurance_net_h.map(|n| n as f64 / 2.0),
                "cost": self.bet as f64 / 2.0,
            },
            "feedback": self.feedback,
            "hint": self.hint,
            "quiz": self.quiz,
            "counters": {
                "hands": self.hands_played,
                "decisions": self.decisions,
                "correct": self.correct,
                "accuracy": self.accuracy(),
                "hints": self.hints,
                "quiz_total": self.quiz_total,
                "quiz_right": self.quiz_right,
            },
            "message": self.message,
            "round_net": self.round_net_h as f64 / 2.0,
            "open": self.mode == Mode::Open,
            "peeked": self.peeked,
        });
        if let (Some(m), Value::Object(e)) = (v.as_object_mut(), extra) {
            m.extend(e);
        }
        if self.open_visible() {
            v["open_hint"] = self.open_hint().unwrap_or(Value::Null);
        }
        if self.status != "playing" || self.hands_played > 0 {
            v["summary"] = json!(self.summary());
        }
        v
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if self.status != "playing" {
            return Err("Masa bitti".into());
        }
        if a.get("reveal").and_then(Value::as_bool) == Some(true) {
            self.peeked = true;
            return Ok(());
        }
        if a.get("hint").and_then(Value::as_bool) == Some(true) {
            let h = match self.phase {
                Phase::Insurance => json!({"best": "no_insurance", "best_label": "Sigorta yok", "reason": INSURANCE_REASON,
                    "deviation": if self.true_count() >= 3.0 && self.mode == Mode::Count {
                        Some(format!("Sayım notu: gerçek sayım {} (≥ +3) → sayan oyuncu sigorta alır (Illustrious 18).", one_decimal(self.true_count())))
                    } else { None }}),
                Phase::Play => {
                    let (act, why, dev) = self.bs_now().ok_or("Şu an ipucu yok")?;
                    json!({"best": act.key(), "best_label": act.label(), "reason": why,
                        "deviation": if self.mode == Mode::Count { dev.map(|d| d.1) } else { None }})
                }
                _ => return Err("Şu an ipucu yok".into()),
            };
            self.hint = Some(h);
            self.hints += 1;
            return Ok(());
        }
        if let Some(n) = a.get("bet") {
            if self.phase != Phase::Bet {
                return Err("Bahis el başında konur".into());
            }
            let n = n.as_i64().ok_or("Geçersiz bahis")?;
            if n < 0 || n % 5 != 0 {
                return Err("Geçersiz bahis".into());
            }
            if n > MAX_BET {
                return Err("En fazla 500 fiş".into());
            }
            if n * 2 > self.bank_h {
                return Err("Yeterli fiş yok".into());
            }
            self.bet = n;
            return Ok(());
        }
        if a.get("deal").and_then(Value::as_bool) == Some(true) {
            if self.phase != Phase::Bet {
                return Err("El zaten dağıtıldı".into());
            }
            if self.bet < MIN_BET {
                return Err("En az 10 fiş koy".into());
            }
            if self.bet * 2 > self.bank_h {
                return Err("Yeterli fiş yok".into());
            }
            self.hint = None;
            self.deal();
            return Ok(());
        }
        if let Some(take) = a.get("insurance").and_then(Value::as_bool) {
            if self.phase != Phase::Insurance {
                return Err("Sigorta sadece krupiye As gösterince".into());
            }
            let cost = self.bet; // half the bet, in half-chips
            if take && self.bank_h < cost {
                return Err("Sigorta için yeterli fiş yok".into());
            }
            let dev = if self.mode == Mode::Count && self.true_count() >= 3.0 {
                Some((Act::Hit, format!("Sayım notu: gerçek sayım {} (≥ +3) → sayan oyuncu sigorta alır (Illustrious 18).", one_decimal(self.true_count()))))
            } else {
                None
            };
            // Map insurance onto the decision record: Hit = take, Stand = decline.
            let chosen = if take { Act::Hit } else { Act::Stand };
            self.record_decision(
                if take { "insurance" } else { "no_insurance" },
                if take { "Sigorta al" } else { "Sigorta yok" },
                Act::Stand,
                "Sigorta yok",
                INSURANCE_REASON.into(),
                dev,
                Some(chosen),
            );
            if let Some(fb) = self.feedback.as_mut() {
                fb["best"] = json!("no_insurance");
            }
            if take {
                self.bank_h -= cost;
                self.insurance_h = cost;
            }
            self.hint = None;
            self.after_peek();
            return Ok(());
        }
        if a.get("count_answer").is_some() {
            if self.phase != Phase::CountQuiz {
                return Err("Şu an sayım sorulmuyor".into());
            }
            let n = a["count_answer"].as_i64().ok_or("Bir sayı gir")?;
            let ok = n == self.running as i64;
            self.quiz_total += 1;
            if ok {
                self.quiz_right += 1;
            }
            self.serial += 1;
            self.quiz = Some(json!({
                "serial": self.serial, "answer": n, "actual": self.running, "correct": ok,
                "true_count": (self.true_count() * 10.0).round() / 10.0,
                "true_count_text": one_decimal(self.true_count()),
                "decks_left": (self.decks_left() * 10.0).round() / 10.0,
            }));
            self.enter_bet();
            return Ok(());
        }
        if a.get("next").and_then(Value::as_bool) == Some(true) {
            if self.phase != Phase::Settle {
                return Err("El henüz bitmedi".into());
            }
            self.after_settle();
            return Ok(());
        }
        if a.get("ai").and_then(Value::as_bool) == Some(true) {
            if self.phase != Phase::Dealer {
                return Err("Sıra krupiyede değil".into());
            }
            self.dealer_step();
            return Ok(());
        }
        let act = if a.get("hit").and_then(Value::as_bool) == Some(true) {
            Act::Hit
        } else if a.get("stand").and_then(Value::as_bool) == Some(true) {
            Act::Stand
        } else if a.get("double").and_then(Value::as_bool) == Some(true) {
            Act::Double
        } else if a.get("split").and_then(Value::as_bool) == Some(true) {
            Act::Split
        } else {
            return Err("Bilinmeyen hamle".into());
        };
        if self.phase != Phase::Play {
            return Err(match self.phase {
                Phase::Bet => "Önce bahis koyup dağıt",
                Phase::Insurance => "Önce sigorta kararını ver",
                _ => "Şu an hamle sırası sende değil",
            }
            .into());
        }
        match act {
            Act::Double if !self.can_double() => {
                let h = &self.hands[self.active];
                return Err(if h.cards.len() != 2 || h.split_aces {
                    "Sadece ilk iki kartta ikiye katlanır"
                } else {
                    "Yeterli fiş yok"
                }
                .into());
            }
            Act::Split if !self.can_split() => {
                let h = &self.hands[self.active];
                return Err(if h.pair_value().is_none() {
                    "Sadece eş değerli iki kart bölünür"
                } else if self.hands.len() >= MAX_HANDS {
                    "En fazla 4 ele bölünebilir"
                } else if h.split_aces {
                    "Bölünmüş aslar yeniden bölünmez"
                } else {
                    "Yeterli fiş yok"
                }
                .into());
            }
            _ => {}
        }
        let (best, why, dev) = self.bs_now().ok_or("Şu an hamle sırası sende değil")?;
        self.record_decision(act.key(), act.label(), best, best.label(), why, dev, Some(act));
        self.hint = None;
        let i = self.active;
        match act {
            Act::Hit => {
                let c = self.draw(true);
                self.hands[i].cards.push(c);
                if self.hands[i].total().0 >= 21 {
                    self.hands[i].done = true;
                }
            }
            Act::Stand => self.hands[i].done = true,
            Act::Double => {
                let b = self.hands[i].bet_h;
                self.bank_h -= b;
                self.hands[i].bet_h += b;
                self.hands[i].doubled = true;
                let c = self.draw(true);
                self.hands[i].cards.push(c);
                self.hands[i].done = true;
            }
            Act::Split => {
                let b = self.hands[i].bet_h;
                self.bank_h -= b;
                let second = self.hands[i].cards.pop().expect("pair has two cards");
                let aces = second.1.rank == 14;
                let mut other = Hand::new(b);
                other.cards.push(second);
                other.from_split = true;
                other.split_aces = aces;
                self.hands[i].from_split = true;
                self.hands[i].split_aces = aces;
                self.hands.insert(i + 1, other);
                if aces {
                    // One card each, dealt right away.
                    for k in [i, i + 1] {
                        let c = self.draw(true);
                        self.hands[k].cards.push(c);
                        self.hands[k].done = true;
                    }
                }
            }
        }
        self.advance();
        Ok(())
    }
}

// ---------------------------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn c(rank: u8) -> Card {
        Card::new(rank, 0)
    }

    fn cards(ranks: &[u8]) -> Vec<Card> {
        ranks.iter().map(|&r| c(r)).collect()
    }

    fn act(g: &mut Blackjack, v: Value) {
        g.act(&v).unwrap_or_else(|e| panic!("{v} rejected: {e}"));
    }

    fn run_dealer(g: &mut Blackjack) {
        let mut guard = 0;
        while g.phase == Phase::Dealer {
            act(g, json!({"ai": true}));
            guard += 1;
            assert!(guard < 20);
        }
    }

    /// Deal order: player, dealer up, player, dealer hole, then further cards.
    fn table(ranks: &[u8], bet: i64) -> Blackjack {
        let mut g = Blackjack::with_cards(Mode::Coach, &cards(ranks));
        act(&mut g, json!({"bet": bet}));
        act(&mut g, json!({"deal": true}));
        g
    }

    fn chips(g: &Blackjack) -> f64 {
        g.state()["chips"].as_f64().unwrap()
    }

    #[test]
    fn blackjack_hand_totals_with_soft_aces() {
        assert_eq!(hand_total(&cards(&[14, 6])), (17, true));
        assert_eq!(hand_total(&cards(&[14, 6, 10])), (17, false));
        assert_eq!(hand_total(&cards(&[14, 14])), (12, true));
        assert_eq!(hand_total(&cards(&[14, 14, 9])), (21, true));
        assert_eq!(hand_total(&cards(&[13, 12, 14])), (21, false));
        assert_eq!(hand_total(&cards(&[14, 13])), (21, true));
        assert!(is_blackjack(&cards(&[14, 11])));
        assert!(!is_blackjack(&cards(&[7, 7, 7])));
        assert_eq!(hand_total(&cards(&[14, 14, 14, 14, 7])), (21, true));
        assert_eq!(hand_total(&cards(&[10, 6, 9])), (25, false));
        assert_eq!(Blackjack::hand_label(&cards(&[14, 6]), false), "Yumuşak 17");
        assert_eq!(Blackjack::hand_label(&cards(&[10, 6, 9]), false), "Battı · 25");
    }

    #[test]
    fn blackjack_dealer_stands_on_soft_17() {
        // Player 10+9 stands; dealer A+6 (soft 17) must stand → player 19 wins.
        let mut g = table(&[10, 14, 9, 6, 5], 10);
        assert_eq!(g.phase, Phase::Insurance);
        act(&mut g, json!({"insurance": false}));
        act(&mut g, json!({"stand": true}));
        run_dealer(&mut g);
        assert_eq!(g.dealer.len(), 2, "dealer must stand on soft 17");
        assert_eq!(g.hands[0].result, Some("win"));
        // Dealer 10+6 = hard 16 must hit; next card 5 → 21.
        let mut g = table(&[10, 10, 9, 6, 5], 10);
        act(&mut g, json!({"stand": true}));
        run_dealer(&mut g);
        assert_eq!(g.dealer.len(), 3);
        assert_eq!(hand_total(&g.dealer_plain()).0, 21);
        assert_eq!(g.hands[0].result, Some("lose"));
        // Dealer A+2+4 = soft 17 after hitting → stands.
        let mut g = table(&[10, 14, 8, 2, 4, 10], 10);
        act(&mut g, json!({"insurance": false}));
        act(&mut g, json!({"stand": true}));
        run_dealer(&mut g);
        assert_eq!(g.dealer.len(), 3);
        assert_eq!(hand_total(&g.dealer_plain()), (17, true));
        assert_eq!(g.hands[0].result, Some("win"));
    }

    #[test]
    fn blackjack_payouts() {
        // Natural pays 3:2 (25 → +37,5).
        let g = table(&[14, 9, 13, 7], 25);
        assert_eq!(g.phase, Phase::Settle);
        assert_eq!(g.hands[0].result, Some("blackjack"));
        assert_eq!(chips(&g), 1037.5);
        // Push: 10+8 vs 10+8.
        let mut g = table(&[10, 10, 8, 8], 50);
        act(&mut g, json!({"stand": true}));
        run_dealer(&mut g);
        assert_eq!(g.hands[0].result, Some("push"));
        assert_eq!(chips(&g), 1000.0);
        // Double 11 vs 6: gets a 10 → 21; dealer 6+10+9 busts → +2 × 20.
        let mut g = table(&[6, 6, 5, 10, 10, 9], 20);
        act(&mut g, json!({"double": true}));
        assert_eq!(g.phase, Phase::Dealer);
        run_dealer(&mut g);
        assert_eq!(g.hands[0].result, Some("win"));
        assert_eq!(chips(&g), 1040.0);
        // Split 8s vs 7: hands 8+10 (18), 8+3+10? → second hand 8+3 = 11 doubles to 21; dealer 7+10 = 17.
        let mut g = table(&[8, 7, 8, 10, 10, 3, 10], 10);
        act(&mut g, json!({"split": true}));
        assert_eq!(g.hands.len(), 2);
        assert_eq!(g.hands[0].total().0, 18);
        act(&mut g, json!({"stand": true}));
        assert_eq!(g.active, 1);
        assert_eq!(g.hands[1].total().0, 11);
        act(&mut g, json!({"double": true}));
        run_dealer(&mut g);
        assert_eq!(g.hands[0].result, Some("win"));
        assert_eq!(g.hands[1].result, Some("win"));
        assert_eq!(g.hands[1].total().0, 21);
        assert_eq!(chips(&g), 1000.0 + 10.0 + 20.0);
        // Split aces: one card each, 21 after a split is not a blackjack (pays 1:1).
        let mut g = table(&[14, 9, 14, 8, 13, 5], 10);
        assert_eq!(g.phase, Phase::Play, "dealer shows 9: no insurance");
        act(&mut g, json!({"split": true}));
        assert_eq!(g.phase, Phase::Dealer);
        assert!(g.hands.iter().all(|h| h.cards.len() == 2 && h.done));
        run_dealer(&mut g);
        assert_eq!(g.hands[0].result, Some("win")); // A+K = 21 vs 17
        assert_eq!(g.hands[0].net_h, 20);
        assert_eq!(g.hands[1].result, Some("lose")); // A+5 = 16 vs 17
        // Insurance pays 2:1 when the dealer has blackjack; the main bet loses.
        let mut g = table(&[10, 14, 9, 13], 20);
        act(&mut g, json!({"insurance": true}));
        assert_eq!(g.phase, Phase::Settle);
        assert_eq!(g.insurance_net_h, Some(40)); // +20 chips
        assert_eq!(chips(&g), 1000.0);
        assert_eq!(g.feedback.as_ref().unwrap()["correct"], false);
        // Insurance lost when no dealer blackjack.
        let mut g = table(&[10, 14, 9, 7], 20);
        act(&mut g, json!({"insurance": true}));
        assert_eq!(g.phase, Phase::Play);
        act(&mut g, json!({"stand": true}));
        run_dealer(&mut g);
        // Dealer soft 18 beats 19? no: 19 > 18 → win 20, insurance −10.
        assert_eq!(g.hands[0].result, Some("win"));
        assert_eq!(chips(&g), 1010.0);
        // Player natural vs dealer natural pushes.
        let g = table(&[14, 14, 13, 12], 10);
        // ace up → insurance first
        assert_eq!(g.phase, Phase::Insurance);
        let mut g = g;
        act(&mut g, json!({"insurance": false}));
        assert_eq!(g.hands[0].result, Some("push"));
        assert_eq!(chips(&g), 1000.0);
        // Bust loses even if the dealer busts later.
        let mut g = table(&[10, 6, 6, 10, 10], 10);
        act(&mut g, json!({"hit": true}));
        assert_eq!(g.hands[0].result, None);
        assert_eq!(g.phase, Phase::Dealer);
        run_dealer(&mut g);
        assert_eq!(g.dealer.len(), 2, "dealer does not draw when every hand busted");
        assert_eq!(g.hands[0].result, Some("bust"));
        assert_eq!(chips(&g), 990.0);
    }

    #[test]
    fn blackjack_basic_strategy_spot_checks() {
        use Act::*;
        let h = |t, up| basic_action(t, false, None, up, true, true);
        let s = |t, up| basic_action(t, true, None, up, true, true);
        let p = |v, up| basic_action(if v == 1 { 12 } else { v * 2 }, v == 1, Some(v), up, true, true);
        // Hard totals.
        assert_eq!(h(8, 6), Hit);
        assert_eq!(h(9, 2), Hit);
        assert_eq!(h(9, 3), Double);
        assert_eq!(h(9, 7), Hit);
        assert_eq!(h(10, 9), Double);
        assert_eq!(h(10, 10), Hit);
        assert_eq!(h(10, 11), Hit);
        assert_eq!(h(11, 10), Double);
        assert_eq!(h(11, 11), Hit); // S17
        assert_eq!(h(12, 2), Hit);
        assert_eq!(h(12, 3), Hit);
        assert_eq!(h(12, 4), Stand);
        assert_eq!(h(12, 6), Stand);
        assert_eq!(h(12, 7), Hit);
        assert_eq!(h(13, 2), Stand);
        assert_eq!(h(14, 7), Hit);
        assert_eq!(h(15, 10), Hit);
        assert_eq!(h(16, 6), Stand);
        assert_eq!(h(16, 10), Hit);
        assert_eq!(h(17, 11), Stand);
        // Soft totals.
        assert_eq!(s(13, 4), Hit);
        assert_eq!(s(13, 5), Double);
        assert_eq!(s(15, 4), Double);
        assert_eq!(s(16, 3), Hit);
        assert_eq!(s(17, 2), Hit);
        assert_eq!(s(17, 3), Double);
        assert_eq!(s(18, 2), Stand); // S17
        assert_eq!(s(18, 3), Double);
        assert_eq!(s(18, 7), Stand);
        assert_eq!(s(18, 9), Hit);
        assert_eq!(s(18, 11), Hit);
        assert_eq!(s(19, 6), Stand); // S17
        assert_eq!(s(20, 6), Stand);
        // Soft 18 with three cards vs 4: Ds → stand; soft 17 three cards vs 4: D → hit.
        assert_eq!(basic_action(18, true, None, 4, false, false), Stand);
        assert_eq!(basic_action(17, true, None, 4, false, false), Hit);
        assert_eq!(basic_action(11, false, None, 6, false, false), Hit);
        // Pairs (DAS).
        assert_eq!(p(1, 11), Split);
        assert_eq!(p(8, 10), Split);
        assert_eq!(p(8, 11), Split);
        assert_eq!(p(10, 6), Stand);
        assert_eq!(p(5, 9), Double);
        assert_eq!(p(5, 10), Hit);
        assert_eq!(p(9, 7), Stand);
        assert_eq!(p(9, 8), Split);
        assert_eq!(p(9, 10), Stand);
        assert_eq!(p(9, 2), Split);
        assert_eq!(p(7, 7), Split);
        assert_eq!(p(7, 8), Hit);
        assert_eq!(p(6, 2), Split);
        assert_eq!(p(6, 7), Hit);
        assert_eq!(p(4, 4), Hit);
        assert_eq!(p(4, 5), Split);
        assert_eq!(p(4, 7), Hit);
        assert_eq!(p(3, 7), Split);
        assert_eq!(p(3, 8), Hit);
        assert_eq!(p(2, 2), Split);
        // Pairs that can't be split fall back to totals.
        assert_eq!(basic_action(16, false, Some(8), 10, true, false), Hit);
        assert_eq!(basic_action(12, true, Some(1), 6, true, false), Hit);
    }

    #[test]
    fn blackjack_basic_strategy_full_reference_table() {
        // Reference chart (6 decks, S17, DAS, no surrender); columns: dealer 2 3 4 5 6 7 8 9 T A.
        let hard = [
            (8, "HHHHHHHHHH"),
            (9, "HDDDDHHHHH"),
            (10, "DDDDDDDDHH"),
            (11, "DDDDDDDDDH"),
            (12, "HHSSSHHHHH"),
            (13, "SSSSSHHHHH"),
            (14, "SSSSSHHHHH"),
            (15, "SSSSSHHHHH"),
            (16, "SSSSSHHHHH"),
            (17, "SSSSSSSSSS"),
        ];
        let soft = [
            (13, "HHHDDHHHHH"),
            (14, "HHHDDHHHHH"),
            (15, "HHDDDHHHHH"),
            (16, "HHDDDHHHHH"),
            (17, "HDDDDHHHHH"),
            (18, "SDDDDSSHHH"),
            (19, "SSSSSSSSSS"),
            (20, "SSSSSSSSSS"),
        ];
        let pairs = [
            (2, "PPPPPPHHHH"),
            (3, "PPPPPPHHHH"),
            (4, "HHHPPHHHHH"),
            (6, "PPPPPHHHHH"),
            (7, "PPPPPPHHHH"),
            (8, "PPPPPPPPPP"),
            (9, "PPPPPSPPSS"),
            (10, "SSSSSSSSSS"),
            (1, "PPPPPPPPPP"),
        ];
        let code = |a: Act| match a {
            Act::Hit => 'H',
            Act::Stand => 'S',
            Act::Double => 'D',
            Act::Split => 'P',
        };
        let mut cells = 0;
        for (t, row) in hard {
            for (i, ch) in row.chars().enumerate() {
                assert_eq!(code(basic_action(t, false, None, i as u8 + 2, true, true)), ch, "hard {t} vs {}", i + 2);
                cells += 1;
            }
        }
        for (t, row) in soft {
            for (i, ch) in row.chars().enumerate() {
                assert_eq!(code(basic_action(t, true, None, i as u8 + 2, true, true)), ch, "soft {t} vs {}", i + 2);
                cells += 1;
            }
        }
        for (v, row) in pairs {
            let (t, sft) = if v == 1 { (12, true) } else { (v * 2, false) };
            for (i, ch) in row.chars().enumerate() {
                assert_eq!(code(basic_action(t, sft, Some(v), i as u8 + 2, true, true)), ch, "pair {v} vs {}", i + 2);
                cells += 1;
            }
        }
        assert!(cells >= 270);
        // Every cell has a non-empty reason.
        for t in 4..=21 {
            for up in 2..=11 {
                let a = basic_action(t, false, None, up, true, true);
                assert!(!reason(t, false, None, up, a, true).is_empty());
            }
        }
        assert_eq!(
            reason(12, false, None, 6, Act::Stand, true),
            "Krupiye 6 gösteriyor, batma olasılığı yüksek (~%40) → 12'de dur."
        );
        assert!(reason(16, false, None, 5, Act::Stand, true).contains("16'da dur"));
        assert!(reason(13, false, None, 5, Act::Stand, true).contains("13'te dur"));
    }

    #[test]
    fn blackjack_hilo_running_and_true_count() {
        // Player 2, dealer up 3, player K, hole 9 (hidden): +1 +1 −1 = +1 visible.
        let mut g = table(&[2, 3, 13, 9, 14], 10);
        assert_eq!(g.running, 1);
        act(&mut g, json!({"hit": true})); // ace: −1 → 0 (2+K+A = 13)
        assert_eq!(g.running, 0);
        act(&mut g, json!({"stand": true}));
        run_dealer(&mut g); // reveals 9 (0) then draws
        let all: i32 = g.hands[0].plain().iter().chain(g.dealer_plain().iter()).map(|c| c.hilo()).sum();
        assert_eq!(g.running, all);
        // True count = running / decks left.
        let st = g.state();
        let decks = (g.shoe.len() - g.pos) as f64 / 52.0;
        assert!((g.true_count() - g.running as f64 / decks).abs() < 1e-9);
        assert!(st["decks_left"].as_f64().unwrap() > 5.0);
        // A full fresh shoe sums to zero.
        let mut rng = Rng::new(5);
        assert_eq!(fresh_shoe(&mut rng).iter().map(|c| c.hilo()).sum::<i32>(), 0);
        assert_eq!(fresh_shoe(&mut rng).len(), 312);
    }

    #[test]
    fn blackjack_count_quiz_flow() {
        let mut g = Blackjack::new(Mode::Count, 77);
        for _ in 0..QUIZ_EVERY {
            play_hand_basic(&mut g);
            if g.phase == Phase::Settle {
                act(&mut g, json!({"next": true}));
            }
        }
        assert_eq!(g.phase, Phase::CountQuiz);
        let before = g.state();
        assert!(g.act(&json!({"hit": true})).is_err());
        assert_eq!(g.state(), before);
        let rc = g.running;
        act(&mut g, json!({"count_answer": rc}));
        assert_eq!(g.quiz_right, 1);
        assert_eq!(g.phase, Phase::Bet);
        assert_eq!(g.state()["quiz"]["correct"], true);
    }

    #[test]
    fn blackjack_illegal_actions_rejected_unchanged() {
        let mut g = Blackjack::new(Mode::Classic, 3);
        let check = |g: &mut Blackjack, a: Value| {
            let before = g.state();
            assert!(g.act(&a).is_err(), "{a} should be rejected");
            assert_eq!(g.state(), before, "{a} changed state");
        };
        check(&mut g, json!({"hit": true}));
        check(&mut g, json!({"bet": 7}));
        check(&mut g, json!({"bet": 505}));
        check(&mut g, json!({"bet": -10}));
        check(&mut g, json!({"insurance": true}));
        check(&mut g, json!({"ai": true}));
        check(&mut g, json!({"next": true}));
        check(&mut g, json!({"count_answer": 3}));
        check(&mut g, json!({"hint": true}));
        check(&mut g, json!({"foo": 1}));
        act(&mut g, json!({"bet": 0}));
        check(&mut g, json!({"deal": true}));
        // Mid-hand: double after three cards, split a non-pair.
        let mut g = table(&[5, 9, 6, 7, 2, 10], 10);
        check(&mut g, json!({"split": true}));
        check(&mut g, json!({"bet": 20}));
        check(&mut g, json!({"deal": true}));
        act(&mut g, json!({"hit": true})); // 13
        check(&mut g, json!({"double": true}));
        // Not enough chips to double.
        let mut g = Blackjack::with_cards(Mode::Classic, &cards(&[6, 9, 5, 7, 10]));
        g.bank_h = 2 * 300;
        act(&mut g, json!({"bet": 200}));
        act(&mut g, json!({"deal": true}));
        check(&mut g, json!({"double": true}));
        // Basic strategy now says hit (11 vs 9 without a double).
        act(&mut g, json!({"hit": true}));
        assert_eq!(g.feedback.as_ref().unwrap()["correct"], true);
        // Split aces can't be re-split or hit.
        let mut g = table(&[14, 9, 14, 8, 14, 5], 10);
        act(&mut g, json!({"split": true}));
        check(&mut g, json!({"hit": true}));
        check(&mut g, json!({"split": true}));
    }

    /// Plays one hand with basic strategy (bets the advised amount in count mode).
    fn play_hand_basic(g: &mut Blackjack) {
        if g.phase == Phase::CountQuiz {
            let rc = g.running as i64;
            act(g, json!({"count_answer": rc}));
        }
        if g.phase == Phase::Done {
            return;
        }
        assert_eq!(g.phase, Phase::Bet);
        let bet = 25.min(g.bank_h / 2) / 5 * 5;
        act(g, json!({"bet": bet.max(10)}));
        act(g, json!({"deal": true}));
        if g.phase == Phase::Insurance {
            act(g, json!({"insurance": false}));
        }
        let mut guard = 0;
        while g.phase == Phase::Play {
            let (a, _, _) = g.bs_now().unwrap();
            let mut m = serde_json::Map::new();
            m.insert(a.key().into(), json!(true));
            act(g, Value::Object(m));
            guard += 1;
            assert!(guard < 30);
        }
        run_dealer(g);
        assert_eq!(g.phase, Phase::Settle);
        assert_eq!(g.correct, g.decisions);
    }

    #[test]
    fn blackjack_sessions_terminate_with_correct_result() {
        let mut outcomes = [0; 3];
        for seed in 0..60u64 {
            let mode = [Mode::Classic, Mode::Coach, Mode::Count, Mode::Open][seed as usize % 4];
            let mut g = Blackjack::new(mode, seed * 7919 + 1);
            let mut guard = 0;
            while g.status == "playing" {
                if g.phase == Phase::Settle {
                    act(&mut g, json!({"next": true}));
                    continue;
                }
                play_hand_basic(&mut g);
                guard += 1;
                assert!(guard <= HANDS_PER_MATCH + 1);
            }
            let st = g.state();
            assert_eq!(g.phase, Phase::Done);
            let chips = st["chips"].as_f64().unwrap();
            let expect = if chips > 1000.0 {
                "won"
            } else if chips == 1000.0 {
                "draw"
            } else {
                "lost"
            };
            assert_eq!(st["status"], expect);
            assert!(st["summary"].as_str().unwrap().contains("Doğru karar: %100"));
            assert!(g.hands_played == HANDS_PER_MATCH || g.bank_h < MIN_BET * 2);
            if expect == "won" {
                assert_eq!(st["stars"], 3);
            }
            outcomes[match expect {
                "won" => 0,
                "draw" => 1,
                _ => 2,
            }] += 1;
            assert!(g.act(&json!({"next": true})).is_err());
        }
        assert!(outcomes[0] > 0 && outcomes[2] > 0, "{outcomes:?}");
    }

    #[test]
    fn blackjack_draw_and_bust_out() {
        // Draw: exactly 1000 at the end. Force by finishing a session with an untouched bankroll.
        let mut g = Blackjack::new(Mode::Classic, 9);
        g.hands_played = HANDS_PER_MATCH - 1;
        // One push hand: rig the shoe.
        let mut shoe = cards(&[10, 10, 8, 8]);
        shoe.extend(fresh_shoe(&mut Rng::new(1)));
        g.shoe = shoe;
        g.pos = 0;
        g.cut = usize::MAX;
        act(&mut g, json!({"deal": true}));
        act(&mut g, json!({"stand": true}));
        run_dealer(&mut g);
        assert_eq!(g.status, "playing");
        act(&mut g, json!({"next": true}));
        assert_eq!(g.status, "draw");
        // Bust out: less than the minimum bet left ends the match as lost.
        let mut g = Blackjack::with_cards(Mode::Classic, &cards(&[10, 10, 6, 10, 10]));
        g.bank_h = 2 * 15;
        act(&mut g, json!({"bet": 10}));
        act(&mut g, json!({"deal": true}));
        act(&mut g, json!({"hit": true}));
        run_dealer(&mut g);
        act(&mut g, json!({"next": true}));
        assert_eq!(g.status, "lost");
    }

    #[test]
    fn blackjack_determinism_with_fixed_seed() {
        let run = |seed| {
            let mut g = Blackjack::new(Mode::Open, seed);
            let mut log = vec![];
            for _ in 0..12 {
                if g.phase == Phase::Settle {
                    act(&mut g, json!({"next": true}));
                }
                play_hand_basic(&mut g);
                log.push(g.state());
            }
            log
        };
        assert_eq!(run(42), run(42));
        assert_ne!(run(42), run(43));
    }

    #[test]
    fn blackjack_reshuffles_at_cut_card() {
        let mut g = Blackjack::new(Mode::Count, 11);
        let mut shuffles = 0;
        for _ in 0..80 {
            g.hands_played = 1; // keep the match open; we only care about the shoe here
            if g.phase == Phase::Settle {
                act(&mut g, json!({"next": true}));
            }
            if g.status != "playing" {
                break;
            }
            if g.phase == Phase::CountQuiz {
                act(&mut g, json!({"count_answer": 0}));
            }
            if g.shuffled {
                shuffles += 1;
                assert_eq!(g.running, 0);
                assert_eq!(g.pos, 0);
            }
            assert!(g.pos < g.cut + 40);
            play_hand_basic(&mut g);
        }
        assert!(shuffles >= 1, "80 hands must pass a 75% cut card");
    }

    #[test]
    fn blackjack_open_hint_uses_known_cards() {
        // Hard 16 vs 10 with a 5 on top: basic strategy hits, and here hitting makes 21.
        let mut g = Blackjack::with_cards(Mode::Open, &cards(&[10, 10, 6, 7, 5, 10, 10, 10, 10]));
        act(&mut g, json!({"deal": true}));
        let h = g.state()["open_hint"].clone();
        // …and since the 5 is known, doubling (one card, 21) beats a plain hit.
        assert_eq!(h["bs"], "hit");
        assert_eq!(h["best"], "double");
        assert_eq!(h["same"], false);
        // Hard 16 vs 10: next card is a 10 (bust) and the dealer has 17 → still lose either way…
        // Hard 15 vs 7 (dealer 7+9 = 16), next card 10: hitting busts, standing wins when the
        // dealer then draws the 10 and busts. Basic strategy says hit; perfect info says stand.
        let mut g = Blackjack::with_cards(Mode::Open, &cards(&[10, 7, 5, 9, 10, 10, 10, 10, 10]));
        act(&mut g, json!({"deal": true}));
        let h = g.state()["open_hint"].clone();
        assert_eq!(h["bs"], "hit");
        assert_eq!(h["best"], "stand");
        assert_eq!(h["same"], false);
        assert!(h["reason"].as_str().unwrap().contains("batar"), "{h}");
        // Classic mode does not expose open_hint until the eye toggle reveals.
        let mut g = Blackjack::with_cards(Mode::Classic, &cards(&[10, 7, 5, 9, 10, 10]));
        act(&mut g, json!({"deal": true}));
        assert!(g.state().get("open_hint").is_none());
        act(&mut g, json!({"reveal": true}));
        assert_eq!(g.state()["open_hint"]["best"], "stand");
        act(&mut g, json!({"stand": true}));
        run_dealer(&mut g);
        assert!(g.summary().ends_with("açık"));
    }

    #[test]
    fn blackjack_perfect_search_matches_unknown_model_without_window() {
        // With no known cards, the search reduces to the infinite-deck model: standing on 20 vs a
        // dealer 6+10 is clearly better than hitting.
        let rest = fresh_shoe(&mut Rng::new(3));
        let pf = Perfect::new(vec![], &rest, 16, false);
        let mut h = SimHand::single(10, false);
        h.add(10);
        let st = pf.apply(&[h], 0, 0, Act::Stand).unwrap();
        let hit = pf.apply(&[h], 0, 0, Act::Hit).unwrap();
        assert!(st > 0.4 && hit < st, "stand {st} hit {hit}");
    }

    #[test]
    fn blackjack_count_mode_deviations() {
        // 16 vs 10 at a positive count: standing counts as correct in count mode.
        assert_eq!(deviation(16, false, None, 10, 1.0, true, true).map(|d| d.0), Some(Act::Stand));
        assert_eq!(deviation(16, false, None, 10, -1.0, true, true), None);
        assert_eq!(deviation(12, false, None, 4, -0.5, true, true).map(|d| d.0), Some(Act::Hit));
        assert_eq!(deviation(10, false, Some(10), 6, 4.5, true, true).map(|d| d.0), Some(Act::Split));
        assert_eq!(deviation(11, false, None, 11, 1.5, true, true).map(|d| d.0), Some(Act::Double));
        assert_eq!(deviation(16, false, Some(8), 10, 3.0, true, true), None, "8-8 is still split");
    }

    #[test]
    fn blackjack_create_modes() {
        for m in ["classic", "coach", "count", "open"] {
            let s = create(1, m).unwrap();
            let st = s.state();
            assert_eq!(st["status"], "playing");
            assert_eq!(st["phase"], "bet");
            assert_eq!(st["chips"], 1000.0);
        }
        assert!(create(1, "nope").is_err());
        assert_eq!(chips_text(2075), "1.037,5");
        assert_eq!(chips_text(-40), "−20");
        assert_eq!(loc(16), "16'da");
        assert_eq!(loc(20), "20'de");
    }
}
