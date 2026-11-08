//! Saat ve takvim — clock-hand angles, time arithmetic, mirror clocks, fast clocks, weekdays.
//!
//! Medium: the angle at a time with minutes a multiple of 10, adding a duration, a weekday
//! N days later, a mirror-image clock, a clock that gains a few minutes per hour.
//! Hard: angles at odd minutes (half degrees: the hour hand moves 0.5° per minute), weekdays
//! across months of a real year, the same date two years later (leap years), a clock that loses
//! time until it shows the right time again.
//!
//! Distractors are bug models: ignoring the hour hand's drift, the reflex angle, a missed carry,
//! counting the first day, 30-day months, forgetting 29 February, a 24-hour dial. Weekday options
//! are four consecutive days with the answer at a random place in the run.
//!
//! Oracle: every answer is recomputed by a different method — hands simulated in half degrees,
//! times as minutes of the day, weekdays with Zeller's congruence (the generator counts days from
//! a fixed epoch), fast clocks simulated hour by hour — and exactly one option must equal it.

use super::common::*;
use super::item::IqItem;
use crate::rng::Rng;
use serde_json::json;

pub const ID: &str = "clock_calendar";

const DAYS: [&str; 7] = ["Pazartesi", "Salı", "Çarşamba", "Perşembe", "Cuma", "Cumartesi", "Pazar"];
const MONTHS: [&str; 12] = ["Ocak", "Şubat", "Mart", "Nisan", "Mayıs", "Haziran", "Temmuz", "Ağustos", "Eylül", "Ekim", "Kasım", "Aralık"];

/// Days since 1970-01-01 (proleptic Gregorian), Howard Hinnant's algorithm.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

/// Weekday 0 = Monday, by day count (1970-01-01 was a Thursday).
fn weekday(y: i64, m: i64, d: i64) -> usize {
    ((days_from_civil(y, m, d) + 3).rem_euclid(7)) as usize
}

/// Weekday 0 = Monday, by Zeller's congruence (the oracle's method).
fn zeller(y: i64, m: i64, d: i64) -> usize {
    let (mm, yy) = if m < 3 { (m + 12, y - 1) } else { (m, y) };
    let k = yy % 100;
    let j = yy / 100;
    let h = (d + 13 * (mm + 1) / 5 + k + k / 4 + j / 4 + 5 * j) % 7; // 0 = Saturday
    ((h + 5) % 7) as usize
}

fn hhmm(min: i64) -> String {
    let m = min.rem_euclid(1440);
    format!("{:02}:{:02}", m / 60, m % 60)
}

fn clock12(min: i64) -> String {
    let m = min.rem_euclid(720);
    let h = m / 60;
    format!("{}:{:02}", if h == 0 { 12 } else { h }, m % 60)
}

fn angle_text(half: i64) -> String {
    if half % 2 == 0 {
        format!("{}°", half / 2)
    } else {
        format!("{},5°", half / 2)
    }
}

#[derive(Clone, Debug)]
pub enum Spec {
    Angle { h: i64, m: i64 },
    AddTime { start: i64, dur: i64 },
    DaysLater { start: usize, n: i64 },
    Date { from: (i64, i64, i64), to: (i64, i64, i64) },
    Mirror { shown: i64 },
    Fast { gain_per_hour: i64, start: i64, hours: i64 },
    Lose { per_day: i64 },
}

/// The oracle: recompute the answer text independently.
fn solve(s: &Spec) -> String {
    match *s {
        Spec::Angle { h, m } => {
            // Half degrees: the minute hand moves 12 per minute, the hour hand 1 per minute.
            let minute = 12 * m;
            let hour = 60 * (h % 12) + m;
            let d = (minute - hour).rem_euclid(720);
            angle_text(d.min(720 - d))
        }
        Spec::AddTime { start, dur } => {
            let mut t = start;
            for _ in 0..dur {
                t = (t + 1) % 1440;
            }
            hhmm(t)
        }
        Spec::DaysLater { start, n } => DAYS[(start + (n % 7) as usize) % 7].to_string(),
        Spec::Date { from, to } => {
            let w0 = zeller(from.0, from.1, from.2);
            let w1 = zeller(to.0, to.1, to.2);
            let _ = w0;
            DAYS[w1].to_string()
        }
        Spec::Mirror { shown } => clock12(720 - shown),
        Spec::Fast { gain_per_hour, start, hours } => {
            let mut shown = start;
            for _ in 0..hours {
                shown += 60 + gain_per_hour;
            }
            hhmm(shown)
        }
        Spec::Lose { per_day } => format!("{} gün", 720 / per_day),
    }
}

fn day_options(r: &mut Rng, answer: usize) -> (Vec<String>, usize) {
    let at = r.below(4);
    let first = (answer + 7 - at) % 7;
    ((0..4).map(|i| DAYS[(first + i) % 7].to_string()).collect(), at)
}

fn build(r: &mut Rng, hard: bool) -> Option<(IqItem, Spec)> {
    let n_opts = if hard { 5 } else { 4 };
    let kind = r.below(5);
    let (prompt, fig, spec, opts, at, why): (String, Option<serde_json::Value>, Spec, Vec<String>, usize, String) = match (hard, kind) {
        (_, 0) | (_, 1) if kind == 0 || hard => {
            // Angle between the hands.
            let h = r.range(1, 11);
            let m = if hard { r.range(1, 59) } else { 10 * r.range(1, 5) };
            if hard && m % 5 == 0 {
                return None;
            }
            let a2 = (60 * h - 11 * m).abs(); // twice |30h − 5.5m|
            let half = a2.min(720 - a2);
            let no_drift = (2 * (30 * h - 6 * m)).abs() % 720;
            let no_drift = no_drift.min(720 - no_drift);
            let bugs = vec![no_drift, 720 - half, half + m, (half - m).abs()];
            // Every option has the answer's parity in half degrees: whole degrees for whole-degree answers, ",5" for
            // half-degree ones, so the form of a number never gives the answer away.
            let (v, at) = numeric_options(r, half, &bugs, n_opts, 20, 1, &|x| x != half && x < 720 && (x - half) % 2 == 0)?;
            let why = format!(
                "Yelkovan {}°, akrep {}° (her dakika 0,5° ilerler: {} × 30 + {} × 0,5). Aradaki küçük açı {}.",
                6 * m,
                angle_text(60 * h + m).trim_end_matches('°'),
                h,
                m,
                angle_text(half)
            );
            (
                format!("Saat {}:{:02} iken akrep ile yelkovan arasındaki küçük açı kaç derece?", h, m),
                Some(json!({"layout": "clock", "h": h, "m": m})),
                Spec::Angle { h, m },
                v.iter().map(|&x| angle_text(x)).collect(),
                at,
                why,
            )
        }
        (false, 1) => {
            let start = r.range(6 * 60, 20 * 60 + 59);
            let dur = r.range(70, 230);
            let end = start + dur;
            let no_carry = start / 60 * 60 + (start % 60 + dur % 60) % 60 + dur / 60 * 60;
            let bugs = vec![no_carry, end + 60, end - 60, end + 10, end - 10];
            let (v, at) = numeric_options(r, end, &bugs, n_opts, 25, 0, &|x| x != end && x % 1440 != end % 1440)?;
            let why = format!("{} + {} saat {} dakika = {}.", hhmm(start), dur / 60, dur % 60, hhmm(end));
            (
                format!("Bir film {} saat {} dakika sürüyor. Başlama saati {}. Film kaçta biter?", dur / 60, dur % 60, hhmm(start)),
                None,
                Spec::AddTime { start, dur },
                v.iter().map(|&x| hhmm(x)).collect(),
                at,
                why,
            )
        }
        (false, 2) => {
            let start = r.below(7);
            let n = r.range(30, 400);
            if n % 7 == 0 {
                return None;
            }
            let ans = (start + (n % 7) as usize) % 7;
            let (o, at) = day_options(r, ans);
            let why = format!("{} = 7 × {} + {}: {} haftadan sonra {} gün daha. {} + {} gün = {}.", n, n / 7, n % 7, n / 7, n % 7, DAYS[start], n % 7, DAYS[ans]);
            (format!("Bugün {}. {} gün sonra hangi gün olur?", DAYS[start], n), None, Spec::DaysLater { start, n }, o, at, why)
        }
        (false, 3) => {
            let shown = r.range(1, 11) * 60 + 5 * r.range(1, 11);
            let real = 720 - shown;
            let bugs = vec![real + 60, real - 60, 780 - shown + 30, shown];
            let (v, at) = numeric_options(r, real, &bugs, n_opts, 40, 0, &|x| x % 720 != real % 720 && x > 0)?;
            let why = format!("Ayna görüntüsünde gerçek saat = 12:00 \u{2212} görünen saat: 12:00 \u{2212} {} = {}.", clock12(shown), clock12(real));
            (
                format!("Bir saatin aynadaki görüntüsü {} gösteriyor. Gerçek saat kaç?", clock12(shown)),
                None,
                Spec::Mirror { shown },
                v.iter().map(|&x| clock12(x)).collect(),
                at,
                why,
            )
        }
        (false, _) => {
            let g = r.range(2, 5);
            let start = r.range(6, 10) * 60;
            let hours = r.range(3, 8);
            let ans = start + hours * (60 + g);
            let bugs = vec![start + hours * 60 + g * (hours - 1), start + hours * (60 - g), start + hours * 60 + g * (hours + 1), start + hours * 60];
            let (v, at) = numeric_options(r, ans, &bugs, n_opts, 6, 0, &|x| x != ans)?;
            let why = format!("{} saatte {} × {} = {} dakika ileri gider: {} + {} saat + {} dk = {}.", hours, hours, g, hours * g, hhmm(start), hours, hours * g, hhmm(ans));
            (
                format!("Bir saat her saatte {g} dakika ileri gidiyor. Saat {} iken doğru ayarlandı. Doğru saat {} olduğunda bu saat neyi gösterir?", hhmm(start), hhmm(start + hours * 60)),
                None,
                Spec::Fast { gain_per_hour: g, start, hours },
                v.iter().map(|&x| hhmm(x)).collect(),
                at,
                why,
            )
        }
        (true, 2) => {
            let y = r.range(2025, 2035);
            let m0 = r.range(1, 8);
            let m1 = m0 + r.range(2, 4);
            let d = r.range(1, 28);
            let w0 = weekday(y, m0, d);
            let w1 = weekday(y, m1, d);
            let gap = days_from_civil(y, m1, d) - days_from_civil(y, m0, d);
            let (o, at) = day_options(r, w1);
            let why = format!(
                "Aradaki gün sayısı {gap}; {gap} = 7 × {} + {}. {} + {} gün = {}.",
                gap / 7,
                gap % 7,
                DAYS[w0],
                gap % 7,
                DAYS[w1]
            );
            (
                format!("{d} {} {y} günü {}. Aynı yıl {d} {} hangi gün?", MONTHS[(m0 - 1) as usize], DAYS[w0], MONTHS[(m1 - 1) as usize]),
                None,
                Spec::Date { from: (y, m0, d), to: (y, m1, d) },
                o,
                at,
                why,
            )
        }
        (true, 3) => {
            let y = r.range(2025, 2033);
            let m = r.range(1, 12);
            let d = r.range(1, 28);
            let w0 = weekday(y, m, d);
            let w1 = weekday(y + 2, m, d);
            let gap = days_from_civil(y + 2, m, d) - days_from_civil(y, m, d);
            let (o, at) = day_options(r, w1);
            let why = format!(
                "İki yıl {gap} gün ediyor ({}). {gap} = 7 × {} + {}: {} + {} gün = {}.",
                if gap == 731 { "araya bir 29 Şubat giriyor" } else { "araya 29 Şubat girmiyor" },
                gap / 7,
                gap % 7,
                DAYS[w0],
                gap % 7,
                DAYS[w1]
            );
            (
                format!("{d} {} {y} günü {}. {d} {} {} hangi gün?", MONTHS[(m - 1) as usize], DAYS[w0], MONTHS[(m - 1) as usize], y + 2),
                None,
                Spec::Date { from: (y, m, d), to: (y + 2, m, d) },
                o,
                at,
                why,
            )
        }
        (true, _) => {
            let per_day = *r.pick(&[2i64, 3, 4, 5, 6, 8, 9, 10, 12, 15]);
            let ans = 720 / per_day;
            let bugs = vec![1440 / per_day, 360 / per_day, 60 / per_day * 24, ans + 30];
            let (v, at) = numeric_options(r, ans, &bugs, n_opts, 20, 1, &|x| x != ans)?;
            let why = format!(
                "12 saatlik kadranda saat, toplam 12 saat = 720 dakika geri kalınca yine doğruyu gösterir: 720 ÷ {per_day} = {ans} gün."
            );
            (
                format!("Bir saat her gün {per_day} dakika geri kalıyor. Bugün doğru ayarlandı. En az kaç gün sonra yine doğru saati gösterir? (12 saatlik kadran)"),
                None,
                Spec::Lose { per_day },
                v.iter().map(|&x| format!("{x} gün")).collect(),
                at,
                why,
            )
        }
    };
    let item = text_item(ID, hard, prompt, fig, opts, at, why);
    Some((item, spec))
}

fn verify(item: &IqItem, s: &Spec) -> Result<(), String> {
    basic_checks(item)?;
    let want = solve(s);
    let texts = option_texts(item);
    let hits: Vec<usize> = (0..texts.len()).filter(|&i| texts[i] == want).collect();
    if hits != vec![item.answer] {
        return Err(format!("oracle says {want}, options {texts:?}, answer {}", item.answer));
    }
    Ok(())
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
    fn iq_clock_calendar_methods_agree() {
        // 3:40 → 130°.
        assert_eq!(solve(&Spec::Angle { h: 3, m: 40 }), "130°");
        // 2026-11-06 is a Friday.
        assert_eq!(weekday(2026, 11, 6), 4);
        for y in 2020..2040 {
            for m in 1..=12 {
                for d in [1, 13, 28] {
                    assert_eq!(weekday(y, m, d), zeller(y, m, d), "{y}-{m}-{d}");
                }
            }
        }
        // Mirror 4:20 → 7:40.
        assert_eq!(solve(&Spec::Mirror { shown: 4 * 60 + 20 }), "7:40");
    }
}
