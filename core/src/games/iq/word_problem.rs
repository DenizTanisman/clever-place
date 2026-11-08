//! Sözel problemler — short arithmetic stories with whole-number answers.
//!
//! Medium: two pipes filling a tank, a discount, sharing in a ratio, heads and legs, distance and
//! speed, three consecutive numbers, an average that changes.
//! Hard: ages at two moments ("two years ago … in four years …"), a price raised and then
//! lowered by percentages, two cars meeting, finding one worker's rate from the joint rate, a
//! mixture's strength, the average speed of a round trip, a train crossing a bridge.
//!
//! Distractors are bug models: averaging the two pipe times, adding the percentages, the other
//! person's share, the arithmetic mean of two speeds, forgetting the train's own length.
//! About a third are typed (number pad).
//!
//! Oracle: each story is re-solved by brute force from its numbers — searching every whole
//! number (ages, counts, minutes, days, prices) that satisfies the story's conditions — and the
//! solution must be unique and equal to the intended answer; exactly one option may equal it.

use super::common::*;
use super::item::IqItem;
use crate::rng::Rng;

pub const ID: &str = "word_problem";

const PEOPLE: &[&str] = &["Ayla", "Deniz", "Selin", "Mert", "Ece", "Kaan"];

#[derive(Clone, Debug)]
pub enum Spec {
    /// Minutes for two pipes (hours a, b) together.
    Pipes { a: i64, b: i64 },
    Discount { price: i64, pct: i64 },
    Share { total: i64, p: i64, q: i64 },
    Legs { heads: i64, legs: i64 },
    Speed { km: i64, kmh: i64 },
    Consecutive { sum: i64 },
    Average { n: i64, avg: i64, new_avg: i64 },
    Ages { t1: i64, k1: i64, t2: i64, k2: i64 },
    TwoPct { up: i64, down: i64 },
    Meet { d: i64, v1: i64, v2: i64 },
    Worker { a: i64, together: i64 },
    Mixture { x: i64, p: i64, y: i64, q: i64 },
    RoundTrip { v1: i64, v2: i64 },
    Train { len: i64, bridge: i64, v_ms: i64 },
}

/// Brute-force solutions (whole numbers up to a bound) for each story.
fn solve(s: &Spec) -> Vec<i64> {
    match *s {
        // Minutes t with t/(60a) + t/(60b) = 1.
        Spec::Pipes { a, b } => (1..=3000).filter(|&t| t * (a + b) == 60 * a * b).collect(),
        Spec::Discount { price, pct } => (0..=price).filter(|&x| 100 * x == price * (100 - pct)).collect(),
        Spec::Share { total, p, q } => (0..=total).filter(|&bshare| (total - bshare) * q == bshare * p).collect(),
        Spec::Legs { heads, legs } => (0..=heads).filter(|&rabbits| 4 * rabbits + 2 * (heads - rabbits) == legs).collect(),
        Spec::Speed { km, kmh } => (1..=3000).filter(|&m| m * kmh == 60 * km).collect(),
        Spec::Consecutive { sum } => (2..=sum).filter(|&big| (big - 2) + (big - 1) + big == sum).collect(),
        Spec::Average { n, avg, new_avg } => (0..=2000).filter(|&x| n * avg + x == (n + 1) * new_avg).collect(),
        Spec::Ages { t1, k1, t2, k2 } => {
            let mut out = vec![];
            for a in 1..=120 {
                for b in 1..=a {
                    if a - t1 > 0 && b - t1 > 0 && a - t1 == k1 * (b - t1) && a + t2 == k2 * (b + t2) {
                        out.push(a);
                    }
                }
            }
            out
        }
        // Final price as a percentage of the first (start at 100 units).
        Spec::TwoPct { up, down } => (1..=300).filter(|&p| 100 * 100 * p == 100 * (100 + up) * (100 - down)).collect(),
        // Minutes until two cars d km apart meet.
        Spec::Meet { d, v1, v2 } => (1..=3000).filter(|&m| m * (v1 + v2) == 60 * d).collect(),
        // Days for the second worker alone: 1/a + 1/b = 1/together.
        Spec::Worker { a, together } => (1..=1000).filter(|&b| together * (a + b) == a * b).collect(),
        Spec::Mixture { x, p, y, q } => (0..=100).filter(|&r| r * (x + y) == x * p + y * q).collect(),
        // Average speed: total distance over total time for a trip of v1·v2 km each way.
        Spec::RoundTrip { v1, v2 } => (1..=500).filter(|&v| v * (v1 + v2) == 2 * v1 * v2).collect(),
        Spec::Train { len, bridge, v_ms } => (1..=1000).filter(|&t| t * v_ms == len + bridge).collect(),
    }
}

struct Draft {
    spec: Spec,
    prompt: String,
    answer: i64,
    bugs: Vec<i64>,
    why: String,
}

fn medium(r: &mut Rng) -> Option<Draft> {
    Some(match r.below(7) {
        0 => {
            let (a, b) = *r.pick(&[(2i64, 3i64), (3, 6), (4, 12), (6, 12), (2, 6), (4, 6), (3, 5), (6, 10), (5, 20), (10, 15)]);
            let ans = 60 * a * b / (a + b);
            if 60 * a * b % (a + b) != 0 {
                return None;
            }
            Draft {
                spec: Spec::Pipes { a, b },
                prompt: format!("A musluğu bir depoyu {a} saatte, B musluğu {b} saatte dolduruyor. İkisi birlikte açılırsa depo kaç dakikada dolar?"),
                answer: ans,
                bugs: vec![30 * (a + b), 60 * a.min(b) / 2, 60 * (b - a).abs(), ans + 10],
                why: format!("Bir saatte A deponun 1/{a}'ini, B 1/{b}'ini doldurur; birlikte saatte {}/{}. Depo {}·60/{} = {ans} dakikada dolar.", a + b, a * b, a * b, a + b),
            }
        }
        1 => {
            let price = 20 * r.range(5, 40);
            let pct = *r.pick(&[10i64, 15, 20, 25, 30, 35, 40]);
            let ans = price * (100 - pct) / 100;
            if price * (100 - pct) % 100 != 0 {
                return None;
            }
            Draft {
                spec: Spec::Discount { price, pct },
                prompt: format!("{price} liralık bir ceket %{pct} indirimle satılıyor. İndirimli fiyatı kaç lira?"),
                answer: ans,
                bugs: vec![price * pct / 100, price - pct, ans + price / 20, price * (100 + pct) / 100],
                why: format!("İndirim {price} × {pct} ÷ 100 = {} lira; {price} \u{2212} {} = {ans}.", price * pct / 100, price * pct / 100),
            }
        }
        2 => {
            let (p, q) = *r.pick(&[(2i64, 3i64), (3, 5), (1, 3), (2, 5), (3, 4), (4, 5)]);
            let unit = r.range(10, 60) * 5;
            let total = unit * (p + q);
            let (a, b) = (r.pick(PEOPLE).to_string(), "kardeşi".to_string());
            Draft {
                spec: Spec::Share { total, p, q },
                prompt: format!("{total} lira, {a} ile {b} arasında {p} : {q} oranında paylaşılıyor. Kardeşi kaç lira alır?"),
                answer: q * unit,
                bugs: vec![p * unit, total / 2, total / q, (q - p) * unit],
                why: format!("Toplam {} pay var; bir pay {total} ÷ {} = {unit} lira. Kardeşi {q} pay alır: {}.", p + q, p + q, q * unit),
            }
        }
        3 => {
            let rabbits = r.range(3, 20);
            let chickens = r.range(3, 25);
            let heads = rabbits + chickens;
            let legs = 4 * rabbits + 2 * chickens;
            Draft {
                spec: Spec::Legs { heads, legs },
                prompt: format!("Bir çiftlikte tavuk ve tavşanların toplam {heads} başı ve {legs} ayağı var. Kaç tavşan var?"),
                answer: rabbits,
                bugs: vec![chickens, legs / 4, heads / 2, legs / 2 - heads + 1],
                why: format!("Hepsi tavuk olsaydı {} ayak olurdu; fazladan {} ayak var, her tavşan 2 fazla getirir: {} ÷ 2 = {rabbits}.", 2 * heads, legs - 2 * heads, legs - 2 * heads),
            }
        }
        4 => {
            let kmh = *r.pick(&[40i64, 45, 50, 60, 72, 75, 80, 90, 120]);
            let m = r.range(4, 30) * 10;
            if kmh * m % 60 != 0 {
                return None;
            }
            let km = kmh * m / 60;
            Draft {
                spec: Spec::Speed { km, kmh },
                prompt: format!("Saatte {kmh} km hızla giden bir araç {km} km'yi kaç dakikada alır?"),
                answer: m,
                bugs: vec![km * 60 / kmh + 60, km, m / 2, m + kmh / 2],
                why: format!("{km} ÷ {kmh} saat = {m} dakika (saat × 60)."),
            }
        }
        5 => {
            let big = r.range(12, 120);
            let sum = 3 * big - 3;
            Draft {
                spec: Spec::Consecutive { sum },
                prompt: format!("Ardışık üç doğal sayının toplamı {sum}. En büyüğü kaç?"),
                answer: big,
                bugs: vec![big - 1, big - 2, sum / 3 + 2, big + 1],
                why: format!("Ortanca sayı {sum} ÷ 3 = {}; en büyüğü {big}.", big - 1),
            }
        }
        _ => {
            let n = r.range(3, 6);
            let avg = r.range(50, 80);
            let new_avg = avg + *r.pick(&[-3i64, -2, 2, 3, 4, 5]);
            let x = (n + 1) * new_avg - n * avg;
            if x <= 0 || x > 100 {
                return None;
            }
            Draft {
                spec: Spec::Average { n, avg, new_avg },
                prompt: format!("{n} sınavın ortalaması {avg}. Bir sınav daha girilince ortalama {new_avg} oluyor. Son sınavın notu kaç?"),
                answer: x,
                bugs: vec![new_avg, new_avg + (new_avg - avg), 2 * new_avg - avg, x + n],
                why: format!("Önce toplam {n} × {avg} = {}, sonra {} × {new_avg} = {}; fark {x}.", n * avg, n + 1, (n + 1) * new_avg),
            }
        }
    })
}

fn hard(r: &mut Rng) -> Option<Draft> {
    Some(match r.below(7) {
        0 => {
            let (t1, t2) = (r.range(2, 6), r.range(2, 8));
            let (k1, k2) = *r.pick(&[(3i64, 2i64), (4, 2), (5, 3), (4, 3), (3, 2)]);
            // a − t1 = k1 (b − t1), a + t2 = k2 (b + t2) ⇒ b = (k1 t1 − t1 + k2 t2 + t2) / (k1 − k2) …
            let num_b = k1 * t1 - t1 + k2 * t2 - t2;
            let den = k1 - k2;
            if num_b % den != 0 {
                return None;
            }
            let b = num_b / den;
            let a = k1 * (b - t1) + t1;
            if b - t1 <= 0 || a + t2 != k2 * (b + t2) || a > 90 {
                return None;
            }
            let who = r.pick(PEOPLE).to_string();
            Draft {
                spec: Spec::Ages { t1, k1, t2, k2 },
                prompt: format!(
                    "{t1} yıl önce {who}, kardeşinin {k1} katı yaşındaydı. {t2} yıl sonra kardeşinin {k2} katı yaşında olacak. {who} şimdi kaç yaşında?"
                ),
                answer: a,
                bugs: vec![b, a - t1, a + t2, k1 * b],
                why: format!("Kardeşin yaşı x olsun: {who} = {k1}(x \u{2212} {t1}) + {t1} ve {who} + {t2} = {k2}(x + {t2}). Buradan x = {b}, {who} = {a}."),
            }
        }
        1 => {
            let (up, down) = *r.pick(&[(20i64, 20i64), (25, 20), (10, 10), (50, 20), (20, 25), (30, 10), (40, 25), (25, 40), (50, 50)]);
            let ans = (100 + up) * (100 - down) / 100;
            if (100 + up) * (100 - down) % 100 != 0 {
                return None;
            }
            Draft {
                spec: Spec::TwoPct { up, down },
                prompt: format!("Bir ürünün fiyatı önce %{up} artırıldı, sonra yeni fiyat %{down} indirildi. Son fiyat, ilk fiyatın yüzde kaçı?"),
                answer: ans,
                bugs: vec![100 + up - down, 100, 100 - (up - down).abs(), ans + 2],
                why: format!("100 liralık ürün {} lira olur, sonra {} × {} ÷ 100 = {ans} lira: ilk fiyatın %{ans}'i. Yüzdeler doğrudan toplanmaz.", 100 + up, 100 + up, 100 - down),
            }
        }
        2 => {
            let (v1, v2) = (r.range(4, 12) * 10, r.range(4, 12) * 10);
            let m = r.range(6, 30) * 10;
            if (v1 + v2) * m % 60 != 0 {
                return None;
            }
            let d = (v1 + v2) * m / 60;
            Draft {
                spec: Spec::Meet { d, v1, v2 },
                prompt: format!("Aralarında {d} km olan iki araç aynı anda birbirine doğru yola çıkıyor; hızları saatte {v1} ve {v2} km. Kaç dakika sonra karşılaşırlar?"),
                answer: m,
                bugs: vec![60 * d / v1.max(v2), m * 2, 60 * d / (v1 + v2) + 60, (m / 2).max(1)],
                why: format!("Her saat aradaki mesafe {} km kapanır: {d} ÷ {} saat = {m} dakika.", v1 + v2, v1 + v2),
            }
        }
        3 => {
            let (a, t) = *r.pick(&[(6i64, 4i64), (12, 4), (10, 6), (12, 8), (15, 10), (20, 12), (30, 12), (6, 3), (20, 15), (24, 8)]);
            if (a - t) == 0 || a * t % (a - t) != 0 {
                return None;
            }
            let b = a * t / (a - t);
            let who = r.pick(PEOPLE).to_string();
            Draft {
                spec: Spec::Worker { a, together: t },
                prompt: format!("{who} bir işi tek başına {a} günde bitiriyor. Arkadaşıyla birlikte aynı işi {t} günde bitiriyorlar. Arkadaşı bu işi tek başına kaç günde bitirir?"),
                answer: b,
                bugs: vec![a - t, 2 * t, a + t, (a + t) / 2],
                why: format!("Günde birlikte 1/{t}, {who} 1/{a} yapıyor; arkadaşı 1/{t} \u{2212} 1/{a} = 1/{b}. Yani {b} gün."),
            }
        }
        4 => {
            let (x, y) = (r.range(1, 6) * 10, r.range(1, 6) * 10);
            let (p, q) = (r.range(1, 8) * 5, r.range(1, 8) * 5);
            if p == q || (x * p + y * q) % (x + y) != 0 {
                return None;
            }
            let ans = (x * p + y * q) / (x + y);
            Draft {
                spec: Spec::Mixture { x, p, y, q },
                prompt: format!("%{p}'lik {x} litre şekerli su ile %{q}'lik {y} litre şekerli su karıştırılıyor. Karışım yüzde kaç şekerli olur?"),
                answer: ans,
                bugs: vec![(p + q) / 2, p + q, ans + 5, (p * y + q * x) / (x + y)],
                why: format!("Şeker: {x} × {p}/100 + {y} × {q}/100 = {} litre; {} litrede bu, %{ans} eder.", (x * p + y * q) as f64 / 100.0, x + y).replace('.', ","),
            }
        }
        5 => {
            let (v1, v2) = *r.pick(&[(40i64, 60i64), (30, 60), (60, 90), (20, 30), (45, 90), (36, 45), (60, 120), (48, 80), (72, 120)]);
            let ans = 2 * v1 * v2 / (v1 + v2);
            Draft {
                spec: Spec::RoundTrip { v1, v2 },
                prompt: format!("Bir araç bir şehre saatte {v1} km hızla gidip aynı yoldan saatte {v2} km hızla dönüyor. Bütün yolculuğun ortalama hızı saatte kaç km?"),
                answer: ans,
                bugs: vec![(v1 + v2) / 2, v1.max(v2) - v1.min(v2), ans + 4, (v1 + v2) / 2 + 2],
                why: format!("Yol {} km olsun: gidiş {} saat, dönüş {} saat; {} km ÷ {} saat = {ans}. Hızların ortalaması ({}) yanlıştır.", v1 * v2, v2, v1, 2 * v1 * v2, v1 + v2, (v1 + v2) / 2),
            }
        }
        _ => {
            let v = r.range(10, 30);
            let t = r.range(10, 40);
            let len = r.range(5, 30) * 10;
            let bridge = v * t - len;
            if bridge < 50 {
                return None;
            }
            Draft {
                spec: Spec::Train { len, bridge, v_ms: v },
                prompt: format!("{len} metre uzunluğundaki bir tren saniyede {v} metre hızla {bridge} metrelik bir köprüden geçiyor. Trenin köprüye girmesinden tamamen çıkmasına kadar kaç saniye geçer?"),
                answer: t,
                bugs: vec![bridge / v, len / v + 1, t + len / v, t - 2],
                why: format!("Tren kendi boyu kadar fazla yol alır: {len} + {bridge} = {} metre; {} ÷ {v} = {t} saniye.", len + bridge, len + bridge),
            }
        }
    })
}

fn build(r: &mut Rng, hard_: bool) -> Option<(IqItem, Spec)> {
    let d = if hard_ { hard(r)? } else { medium(r)? };
    if solve(&d.spec) != vec![d.answer] {
        return None;
    }
    if r.chance(0.33) {
        let item = typed_item(ID, hard_, d.prompt, None, d.answer, d.why);
        return Some((item, d.spec));
    }
    let n = if hard_ { 5 } else { 4 };
    let (opts, at) = numeric_options(r, d.answer, &d.bugs, n, (d.answer / 8).max(3), 1, &|v| v != d.answer)?;
    let item = text_item(ID, hard_, d.prompt, None, strs(&opts), at, d.why);
    Some((item, d.spec))
}

fn verify(item: &IqItem, s: &Spec) -> Result<(), String> {
    basic_checks(item)?;
    let sol = solve(s);
    if sol.len() != 1 {
        return Err(format!("{} solutions: {sol:?}", sol.len()));
    }
    match item.typed {
        Some(v) if v == sol[0] => Ok(()),
        Some(v) => Err(format!("typed {v}, oracle {}", sol[0])),
        None => {
            let texts = option_texts(item);
            let hits: Vec<usize> = (0..texts.len()).filter(|&i| parse_num(&texts[i]) == Some(sol[0])).collect();
            if hits == vec![item.answer] {
                Ok(())
            } else {
                Err(format!("oracle {}, options {texts:?}", sol[0]))
            }
        }
    }
}

pub fn gen_checked(r: &mut Rng, hard: bool) -> (IqItem, Result<(), String>) {
    retry(r, hard, build, verify)
}

pub fn gen(r: &mut Rng, hard: bool) -> IqItem {
    gen_checked(r, hard).0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iq_word_problem_doc_examples() {
        // Pipes 6 h and 3 h: 2 hours together.
        assert_eq!(solve(&Spec::Pipes { a: 6, b: 3 }), vec![120]);
        // Two years ago 3×, in four years 2×: Ayla is 20.
        assert_eq!(solve(&Spec::Ages { t1: 2, k1: 3, t2: 4, k2: 2 }), vec![20]);
        assert_eq!(solve(&Spec::RoundTrip { v1: 40, v2: 60 }), vec![48]);
    }
}
