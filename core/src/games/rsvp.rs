//! Hızlı Akış — rapid serial visual presentation and the attentional blink (Raymond, Shapiro &
//! Arnell 1992; Chun & Potter 1995; Dux & Marois 2009).
//!
//! A stream of letters flashes at one fixed point, back to back (no blank), `item_ms` each
//! (120 → 80 ms, i.e. 8.3 → 12.5 items/s). Embedded are 2 or 3 targets; after the stream you pick
//! the targets you saw from a set of options (at most as many picks as there are targets; order does
//! not matter; "nothing" is a valid answer).
//!
//! Target kinds:
//! - `digit`: digits among letters. Options = a digit keypad (2–9).
//! - `color`: letters drawn in ruby among ivory letters. Options = the targets + foils, several of
//!   which were in the stream (so you must have identified the red ones, not just seen letters).
//! - `set`: letters from a target set shown beforehand (5 letters, 6 with 3 targets) among other
//!   letters. Options = the target set.
//!
//! Look-alikes (documented choice): normal levels avoid every letter that resembles a digit —
//! O/0, I/1, İ/1, Z/2, S/5, G/6, B/8 never appear and the digit pool is 2–9, so the stream never
//! offers a shape the eye can mistake. "Benzer" levels (every other digit cycle from level 40)
//! use them deliberately: the letters O I S Z B G join the stream and the keypad becomes 0–9.
//!
//! Lag = T2 position − T1 position (1..=8). The blink is deepest at lag 2–3 (T2 inside ~200–500 ms
//! after T1); lag 1 is often spared. Each level plans its 16 lags: a share `short` of them are lag
//! 2/3 (alternating), the rest cycle through 1, 4, 5, 6, 7, 8; the plan is shuffled. T1 sits at
//! position 4..=8, a 3rd target 1..=5 items after T2, and 3..=5 masking items follow the last
//! target. No symbol repeats within 3 items; distractors never repeat a target's symbol.
//!
//! Timing: Rust advances the stream on tick with accumulated dt — the current item is
//! ⌊t / item_ms⌋, so items never drift; the view renders exactly the item in `state`.
//! Stream cycle: fixation 700 ms → stream → answer (untimed) → feedback 1400 ms → next stream.
//!
//! Scoring: T1 accuracy = streams with T1 reported / streams. T2|T1 = later targets reported in
//! streams where T1 was reported / later targets in those streams (the standard attentional-blink
//! measure; with 3 targets T2 and T3 both count). Per-lag T2|T1 is reported in the summary.
//! Stars: T2|T1 ≥ 85% and T1 ≥ 85% → 3; T2|T1 ≥ 72% → 2; otherwise 1; T1 < 60% or T2|T1 < 60% →
//! `lost`.
//!
//! Level curve (`params(level)`):
//! - 1..=10 hand-made: digit 120 ms, digit 112, colour 115, set 112, digit 105, colour 105,
//!   digit 100, set 100, digit 100 ×3 targets, digit 100 look-alike. Short-lag share 15% → 30%.
//! - 11..=500: with t = (level − 11) / 489, item_ms = 105 − 25 t (→ 80), short-lag share
//!   25% → 55%, kinds cycle digit / colour / digit / set, look-alike on every other digit cycle
//!   from level 40; 3 targets on every 3rd level from 100 and on 2 of 3 levels from t ≥ 0.6.
//!
//! State: `{status, stars, phase: "intro"|"countdown"|"fixation"|"stream"|"answer"|"feedback"|"done",
//!          title, goal, summary?, kind, lookalike, target_set|null, item_ms, rate, targets, stream,
//!          streams, item: {ch, red}|null, item_index, items_len, t_ms, countdown_ms, options, picked,
//!          last: {serial, symbols, hits, picked, lag, false_picks}|null, t1_acc, t2_given_t1,
//!          lags: [{lag, n, ok}]}`
//! Actions: `{"start":true}` · `{"pick":"7"}` (toggles) · `{"submit":true}`

use crate::rng::{seed_for, Rng};
use crate::Session;
use serde_json::{json, Value};

pub const STREAMS: usize = 16;
pub const COUNTDOWN_MS: f64 = 3000.0;
pub const FIX_MS: f64 = 700.0;
pub const FB_MS: f64 = 1400.0;
pub const MAX_LAG: usize = 8;

/// Letters that never resemble a digit.
const LETTERS: [&str; 22] =
    ["A", "C", "Ç", "D", "E", "F", "H", "J", "K", "L", "M", "N", "P", "R", "T", "U", "V", "Y", "Ş", "Ü", "Ö", "Ğ"];
/// Digit look-alikes, used deliberately on "benzer" levels (O/0, I/1, Z/2, S/5, G/6, B/8).
const LOOKALIKES: [&str; 6] = ["O", "I", "Z", "S", "G", "B"];
const DIGITS: [&str; 8] = ["2", "3", "4", "5", "6", "7", "8", "9"];
const DIGITS_ALL: [&str; 10] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"];
/// Turkish alphabetical order for sorting options.
const ORDER: &str = "0123456789ABCÇDEFGĞHIİJKLMNOÖPRSŞTUÜVYZ";

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Digit,
    Color,
    Set,
}

impl Kind {
    fn key(self) -> &'static str {
        match self {
            Kind::Digit => "digit",
            Kind::Color => "color",
            Kind::Set => "set",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Params {
    pub kind: Kind,
    pub lookalike: bool,
    pub item_ms: f64,
    pub targets: usize,
    /// Share of streams with lag 2 or 3.
    pub short: f64,
}

fn mk(kind: Kind, item_ms: f64, targets: usize, short: f64, lookalike: bool) -> Params {
    Params { kind, lookalike, item_ms, targets, short }
}

/// Level → parameters. See the module docs for the curve.
pub fn params(level: u32) -> Params {
    use Kind::*;
    let level = level.clamp(1, crate::MAX_LEVEL);
    match level {
        1 => mk(Digit, 120.0, 2, 0.15, false),
        2 => mk(Digit, 112.0, 2, 0.2, false),
        3 => mk(Color, 115.0, 2, 0.2, false),
        4 => mk(Set, 112.0, 2, 0.2, false),
        5 => mk(Digit, 105.0, 2, 0.25, false),
        6 => mk(Color, 105.0, 2, 0.25, false),
        7 => mk(Digit, 100.0, 2, 0.3, false),
        8 => mk(Set, 100.0, 2, 0.3, false),
        9 => mk(Digit, 100.0, 3, 0.25, false),
        10 => mk(Digit, 100.0, 2, 0.3, true),
        _ => {
            let i = level - 11;
            let t = i as f64 / 489.0;
            let kind = [Digit, Color, Digit, Set][(i % 4) as usize];
            let lookalike = kind == Digit && level >= 40 && (i / 4) % 2 == 1;
            let three = (level >= 100 && i % 3 == 2) || (t >= 0.6 && i % 3 != 0);
            mk(kind, (105.0 - 25.0 * t).round(), if three { 3 } else { 2 }, 0.25 + 0.3 * t, lookalike)
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Item {
    pub ch: String,
    pub red: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Stream {
    pub items: Vec<Item>,
    /// Target positions in the stream, in order.
    pub pos: Vec<usize>,
    pub lag: usize,
    pub options: Vec<String>,
}

impl Stream {
    pub fn symbols(&self) -> Vec<String> {
        self.pos.iter().map(|&p| self.items[p].ch.clone()).collect()
    }
}

fn sort_tr(v: &mut [String]) {
    v.sort_by_key(|s| ORDER.chars().position(|c| s.starts_with(c)).unwrap_or(99));
}

pub fn lag_plan(r: &mut Rng, short: f64) -> Vec<usize> {
    let n_short = ((STREAMS as f64 * short).round() as usize).clamp(1, STREAMS);
    let mut lags: Vec<usize> = (0..n_short).map(|k| if k % 2 == 0 { 2 } else { 3 }).collect();
    let mut others = [1usize, 4, 5, 6, 7, 8];
    r.shuffle(&mut others);
    lags.extend((0..STREAMS - n_short).map(|k| others[k % others.len()]));
    r.shuffle(&mut lags);
    lags
}

/// Target pool, distractor pool and option list base for a level.
fn pools(p: &Params, set: &[String]) -> (Vec<String>, Vec<String>) {
    let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
    match p.kind {
        Kind::Digit => {
            let mut letters = s(&LETTERS);
            if p.lookalike {
                letters.extend(s(&LOOKALIKES));
                (s(&DIGITS_ALL), letters)
            } else {
                (s(&DIGITS), letters)
            }
        }
        Kind::Color => (s(&LETTERS), s(&LETTERS)),
        Kind::Set => (set.to_vec(), s(&LETTERS).into_iter().filter(|l| !set.contains(l)).collect()),
    }
}

pub fn gen_stream(r: &mut Rng, p: &Params, lag: usize, set: &[String]) -> Stream {
    let (tpool, dpool) = pools(p, set);
    let t1 = r.range(4, 8) as usize;
    let mut pos = vec![t1, t1 + lag];
    if p.targets >= 3 {
        pos.push(t1 + lag + r.range(1, 5) as usize);
    }
    let len = pos.last().unwrap() + 1 + r.range(3, 5) as usize;
    // Distinct target symbols.
    let mut syms: Vec<String> = Vec::new();
    while syms.len() < pos.len() {
        let c = r.pick(&tpool).clone();
        if !syms.contains(&c) {
            syms.push(c);
        }
    }
    let red = p.kind == Kind::Color;
    let mut items: Vec<Item> = Vec::with_capacity(len);
    for i in 0..len {
        if let Some(k) = pos.iter().position(|&q| q == i) {
            items.push(Item { ch: syms[k].clone(), red });
            continue;
        }
        let recent: Vec<&str> = items.iter().rev().take(3).map(|it| it.ch.as_str()).collect();
        // Avoid the next target's symbol right before it, too.
        let upcoming: Vec<&str> = pos.iter().filter(|&&q| q > i && q <= i + 3).map(|&q| {
            let k = pos.iter().position(|&x| x == q).unwrap();
            syms[k].as_str()
        }).collect();
        let cands: Vec<&String> = dpool
            .iter()
            .filter(|c| !syms.contains(c) && !recent.contains(&c.as_str()) && !upcoming.contains(&c.as_str()))
            .collect();
        items.push(Item { ch: (*r.pick(&cands)).clone(), red: false });
    }
    let mut options: Vec<String> = match p.kind {
        Kind::Digit | Kind::Set => tpool.clone(),
        Kind::Color => {
            let want = if p.targets >= 3 { 9 } else { 8 };
            let mut o = syms.clone();
            // Up to three foils that were in the stream (white), then other letters.
            let mut seen: Vec<String> = items.iter().filter(|it| !it.red).map(|it| it.ch.clone()).collect();
            seen.sort();
            seen.dedup();
            r.shuffle(&mut seen);
            for c in seen.into_iter().take(3) {
                o.push(c);
            }
            while o.len() < want {
                let c = r.pick(&tpool).clone();
                if !o.contains(&c) {
                    o.push(c);
                }
            }
            o
        }
    };
    sort_tr(&mut options);
    Stream { items, pos, lag, options }
}

pub fn gen_level(level: u32) -> (Params, Vec<String>, Vec<Stream>) {
    let p = params(level);
    let mut r = Rng::new(seed_for("rsvp", level, 0));
    let set: Vec<String> = if p.kind == Kind::Set {
        let mut l: Vec<String> = LETTERS.iter().map(|x| x.to_string()).collect();
        r.shuffle(&mut l);
        let mut s: Vec<String> = l.into_iter().take(if p.targets >= 3 { 6 } else { 5 }).collect();
        sort_tr(&mut s);
        s
    } else {
        vec![]
    };
    let lags = lag_plan(&mut r, p.short);
    let streams = lags.iter().map(|&lag| gen_stream(&mut r, &p, lag, &set)).collect();
    (p, set, streams)
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Phase {
    Intro,
    Countdown,
    Fixation,
    Stream,
    Answer,
    Feedback,
    Done,
}

#[derive(Clone, Debug)]
struct Result_ {
    hits: Vec<bool>,
    picked: Vec<String>,
    false_picks: usize,
}

pub struct Rsvp {
    p: Params,
    set: Vec<String>,
    streams: Vec<Stream>,
    phase: Phase,
    countdown_ms: f64,
    t_ms: f64,
    idx: usize,
    picked: Vec<String>,
    results: Vec<Result_>,
    serial: u32,
    stars: u32,
    won: bool,
}

pub fn create(level: u32, _mode: &str) -> Result<Box<dyn Session>, String> {
    Ok(Box::new(Rsvp::level(level)))
}

pub fn stars_for(t1: f64, t2t1: f64) -> u32 {
    if t1 < 0.6 - 1e-9 || t2t1 < 0.6 - 1e-9 {
        0
    } else if t2t1 >= 0.85 - 1e-9 && t1 >= 0.85 - 1e-9 {
        3
    } else if t2t1 >= 0.72 - 1e-9 {
        2
    } else {
        1
    }
}

fn pct(x: f64) -> String {
    format!("%{}", (x * 100.0).round())
}

impl Rsvp {
    pub fn level(level: u32) -> Self {
        let (p, set, streams) = gen_level(level);
        Rsvp {
            p,
            set,
            streams,
            phase: Phase::Intro,
            countdown_ms: COUNTDOWN_MS,
            t_ms: 0.0,
            idx: 0,
            picked: vec![],
            results: vec![],
            serial: 0,
            stars: 0,
            won: false,
        }
    }

    fn t1_acc(&self) -> f64 {
        if self.results.is_empty() {
            return 0.0;
        }
        self.results.iter().filter(|r| r.hits[0]).count() as f64 / self.results.len() as f64
    }

    /// Later targets reported given T1 reported.
    fn t2_given_t1(&self) -> f64 {
        let (mut num, mut den) = (0usize, 0usize);
        for r in self.results.iter().filter(|r| r.hits[0]) {
            num += r.hits[1..].iter().filter(|&&h| h).count();
            den += r.hits.len() - 1;
        }
        if den == 0 {
            0.0
        } else {
            num as f64 / den as f64
        }
    }

    /// Per lag: (streams with T1 reported, of which T2 reported).
    fn lag_table(&self) -> Vec<(usize, usize, usize)> {
        let mut out = vec![];
        for lag in 1..=MAX_LAG {
            if !self.streams.iter().any(|s| s.lag == lag) {
                continue;
            }
            let mut n = 0;
            let mut ok = 0;
            for (s, r) in self.streams.iter().zip(&self.results) {
                if s.lag == lag && r.hits[0] {
                    n += 1;
                    if r.hits[1] {
                        ok += 1;
                    }
                }
            }
            out.push((lag, n, ok));
        }
        out
    }

    fn submit(&mut self) {
        let s = &self.streams[self.idx];
        let syms = s.symbols();
        let hits: Vec<bool> = syms.iter().map(|x| self.picked.contains(x)).collect();
        let false_picks = self.picked.iter().filter(|x| !syms.contains(x)).count();
        self.results.push(Result_ { hits, picked: std::mem::take(&mut self.picked), false_picks });
        self.serial += 1;
        self.phase = Phase::Feedback;
        self.t_ms = 0.0;
    }

    fn after_feedback(&mut self) {
        self.idx += 1;
        if self.idx >= self.streams.len() {
            self.phase = Phase::Done;
            self.stars = stars_for(self.t1_acc(), self.t2_given_t1());
            self.won = self.stars > 0;
        } else {
            self.phase = Phase::Fixation;
        }
    }

    fn title(&self) -> String {
        let mut t = match self.p.kind {
            Kind::Digit => "Rakam",
            Kind::Color => "Renk",
            Kind::Set => "Hedef küme",
        }
        .to_string();
        if self.p.lookalike {
            t.push_str(" · benzer");
        }
        if self.p.targets >= 3 {
            t.push_str(" · 3 hedef");
        }
        t
    }

    fn rate(&self) -> String {
        format!("{:.1}", 1000.0 / self.p.item_ms).replace('.', ",")
    }

    fn goal(&self) -> String {
        let n = self.p.targets;
        let what = match self.p.kind {
            Kind::Digit => format!("Harflerin arasındaki {n} rakamı yakala"),
            Kind::Color => format!("Yakut renkli {n} harfi yakala"),
            Kind::Set => format!("Hedef harflerden {n} tanesini yakala: {}", self.set.join(" ")),
        };
        let la = if self.p.lookalike { " · dikkat: O/0, I/1, S/5 benzerleri" } else { "" };
        format!("{what}{la} · {} akış · saniyede {} harf", self.streams.len(), self.rate())
    }

    fn summary(&self) -> String {
        let lags: Vec<String> = self
            .lag_table()
            .into_iter()
            .map(|(lag, n, ok)| if n == 0 { format!("{lag}→–") } else { format!("{lag}→{}", pct(ok as f64 / n as f64)) })
            .collect();
        let fp: usize = self.results.iter().map(|r| r.false_picks).sum();
        format!(
            "T2|T1 {} · T1 {} · Yanlış seçim {fp} · Gecikmeye göre T2: {}",
            pct(self.t2_given_t1()),
            pct(self.t1_acc()),
            lags.join(", ")
        )
    }

    fn status(&self) -> &'static str {
        match self.phase {
            Phase::Done if self.won => "won",
            Phase::Done => "lost",
            _ => "playing",
        }
    }

    fn current_item(&self) -> Option<usize> {
        if self.phase != Phase::Stream {
            return None;
        }
        let k = (self.t_ms / self.p.item_ms).floor() as usize;
        (k < self.streams[self.idx].items.len()).then_some(k)
    }
}

impl Session for Rsvp {
    fn state(&self) -> Value {
        let s = self.streams.get(self.idx.min(self.streams.len() - 1)).unwrap();
        let item_index = self.current_item();
        let item = item_index.map(|k| json!({"ch": s.items[k].ch, "red": s.items[k].red}));
        let show_options = matches!(self.phase, Phase::Answer | Phase::Feedback);
        let last = self.results.last().map(|r| {
            let st = &self.streams[self.results.len() - 1];
            json!({
                "serial": self.serial, "symbols": st.symbols(), "hits": r.hits, "picked": r.picked,
                "lag": st.lag, "false_picks": r.false_picks,
            })
        });
        let lags: Vec<Value> =
            self.lag_table().into_iter().map(|(lag, n, ok)| json!({"lag": lag, "n": n, "ok": ok})).collect();
        let done = self.phase == Phase::Done;
        let options: Vec<String> = if show_options { s.options.clone() } else { vec![] };
        json!({
            "status": self.status(),
            "stars": self.stars,
            "phase": match self.phase {
                Phase::Intro => "intro", Phase::Countdown => "countdown", Phase::Fixation => "fixation",
                Phase::Stream => "stream", Phase::Answer => "answer", Phase::Feedback => "feedback", Phase::Done => "done",
            },
            "title": self.title(),
            "goal": self.goal(),
            "summary": done.then(|| self.summary()),
            "kind": self.p.kind.key(),
            "lookalike": self.p.lookalike,
            "target_set": (self.p.kind == Kind::Set).then(|| self.set.clone()),
            "item_ms": self.p.item_ms,
            "rate": self.rate(),
            "targets": self.p.targets,
            "stream": self.idx.min(self.streams.len() - 1),
            "streams": self.streams.len(),
            "item": item,
            "item_index": item_index,
            "items_len": s.items.len(),
            "t_ms": self.t_ms.round(),
            "countdown_ms": self.countdown_ms.max(0.0).round(),
            "options": options,
            "picked": self.picked,
            "last": last,
            "t1_acc": (self.t1_acc() * 1000.0).round() / 1000.0,
            "t2_given_t1": (self.t2_given_t1() * 1000.0).round() / 1000.0,
            "lags": lags,
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
        if let Some(sym) = a["pick"].as_str() {
            if self.phase != Phase::Answer {
                return Err("Akış bitince seç".into());
            }
            if !self.streams[self.idx].options.iter().any(|o| o == sym) {
                return Err("Bu seçenek yok".into());
            }
            if let Some(k) = self.picked.iter().position(|x| x == sym) {
                self.picked.remove(k);
            } else {
                if self.picked.len() >= self.p.targets {
                    return Err(format!("En fazla {} hedef seçebilirsin", self.p.targets));
                }
                self.picked.push(sym.to_string());
            }
            return Ok(());
        }
        if a["submit"].as_bool() == Some(true) {
            if self.phase != Phase::Answer {
                return Err("Akış bitince onayla".into());
            }
            self.submit();
            return Ok(());
        }
        Err("Bilinmeyen hamle".into())
    }

    fn tick(&mut self, dt_ms: f64) {
        if !(dt_ms > 0.0) {
            return;
        }
        let mut dt = dt_ms;
        // Carry leftover time across phase changes so the stream onset stays exact.
        loop {
            match self.phase {
                Phase::Countdown => {
                    self.countdown_ms -= dt;
                    if self.countdown_ms > 0.0 {
                        return;
                    }
                    dt = -self.countdown_ms;
                    self.countdown_ms = 0.0;
                    self.phase = Phase::Fixation;
                    self.t_ms = 0.0;
                }
                Phase::Fixation => {
                    self.t_ms += dt;
                    if self.t_ms < FIX_MS {
                        return;
                    }
                    dt = self.t_ms - FIX_MS;
                    self.t_ms = 0.0;
                    self.phase = Phase::Stream;
                }
                Phase::Stream => {
                    self.t_ms += dt;
                    let total = self.streams[self.idx].items.len() as f64 * self.p.item_ms;
                    if self.t_ms < total {
                        return;
                    }
                    self.t_ms = 0.0;
                    self.phase = Phase::Answer;
                    return;
                }
                Phase::Feedback => {
                    self.t_ms += dt;
                    if self.t_ms < FB_MS {
                        return;
                    }
                    dt = self.t_ms - FB_MS;
                    self.t_ms = 0.0;
                    self.after_feedback();
                    if self.phase == Phase::Done {
                        return;
                    }
                }
                _ => return,
            }
            if !(dt > 0.0) {
                return;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LEVELS: [u32; 9] = [1, 2, 3, 50, 137, 250, 400, 499, 500];

    fn check_stream(s: &Stream, p: &Params, set: &[String]) {
        assert_eq!(s.pos.len(), p.targets);
        assert_eq!(s.pos[1] - s.pos[0], s.lag);
        assert!((1..=MAX_LAG).contains(&s.lag));
        assert!(s.pos[0] >= 4 && s.pos[0] <= 8);
        let last = *s.pos.last().unwrap();
        assert!(s.items.len() - last - 1 >= 3, "masking items after last target");
        let syms = s.symbols();
        let mut u = syms.clone();
        u.sort();
        u.dedup();
        assert_eq!(u.len(), syms.len(), "distinct targets");
        for (i, it) in s.items.iter().enumerate() {
            let is_t = s.pos.contains(&i);
            assert_eq!(it.red, is_t && p.kind == Kind::Color);
            if !is_t {
                assert!(!syms.contains(&it.ch), "distractor repeats a target");
                assert!(it.ch.parse::<u32>().is_err(), "digit distractor");
                if !p.lookalike {
                    assert!(!LOOKALIKES.contains(&it.ch.as_str()), "look-alike on a normal level");
                }
                if p.kind == Kind::Set {
                    assert!(!set.contains(&it.ch));
                }
            } else {
                match p.kind {
                    Kind::Digit => assert!(it.ch.parse::<u32>().is_ok()),
                    Kind::Set => assert!(set.contains(&it.ch)),
                    Kind::Color => assert!(LETTERS.contains(&it.ch.as_str())),
                }
            }
            for j in i.saturating_sub(3)..i {
                assert_ne!(s.items[j].ch, it.ch, "repeat within 3 at {i}");
            }
        }
        for sym in &syms {
            assert!(s.options.contains(sym), "target missing from options");
        }
        if p.kind == Kind::Digit && !p.lookalike {
            assert_eq!(s.options.len(), 8);
            assert!(!s.options.contains(&"0".to_string()));
        }
    }

    #[test]
    fn params_cover_levels() {
        for level in LEVELS.iter().copied().chain(1..=20) {
            let p = params(level);
            assert!(p.item_ms >= 80.0 && p.item_ms <= 120.0, "level {level}");
            assert!(p.targets == 2 || p.targets == 3);
            assert!(p.short > 0.0 && p.short < 0.6);
        }
        assert_eq!(params(1).item_ms, 120.0);
        assert_eq!(params(500).item_ms, 80.0);
        assert!((11..=500).any(|l| params(l).lookalike));
        assert!((400..=500).filter(|&l| params(l).targets == 3).count() > 50);
    }

    #[test]
    fn levels_generate_valid_streams() {
        for level in LEVELS.iter().copied().chain(1..=24) {
            let (p, set, streams) = gen_level(level);
            assert_eq!(streams.len(), STREAMS);
            for s in &streams {
                check_stream(s, &p, &set);
            }
            let short = streams.iter().filter(|s| s.lag == 2 || s.lag == 3).count();
            assert_eq!(short, ((STREAMS as f64 * p.short).round() as usize).max(1), "level {level}");
        }
    }

    #[test]
    fn deterministic() {
        for level in LEVELS {
            assert_eq!(gen_level(level).2, gen_level(level).2);
        }
    }

    /// Runs the whole level; `answer(game, symbols)` returns what to pick.
    fn play(g: &mut Rsvp, mut answer: impl FnMut(&Rsvp, Vec<String>) -> Vec<String>) {
        g.act(&json!({"start": true})).unwrap();
        g.tick(COUNTDOWN_MS);
        assert_eq!(g.phase, Phase::Fixation);
        while g.phase != Phase::Done {
            assert_eq!(g.phase, Phase::Fixation);
            g.tick(FIX_MS);
            assert_eq!(g.phase, Phase::Stream);
            let n = g.streams[g.idx].items.len();
            for k in 0..n {
                assert_eq!(g.current_item(), Some(k));
                g.tick(g.p.item_ms);
            }
            assert_eq!(g.phase, Phase::Answer);
            for sym in answer(g, g.streams[g.idx].symbols()) {
                g.act(&json!({"pick": sym})).unwrap();
            }
            g.act(&json!({"submit": true})).unwrap();
            assert_eq!(g.phase, Phase::Feedback);
            g.tick(FB_MS);
        }
    }

    #[test]
    fn perfect_play_wins_three_stars() {
        for level in LEVELS {
            let mut g = Rsvp::level(level);
            play(&mut g, |_, syms| syms);
            let st = g.state();
            assert_eq!(st["status"], "won", "level {level}");
            assert_eq!(st["stars"], 3);
            assert_eq!(st["t2_given_t1"], 1.0);
            assert!(st["summary"].as_str().unwrap().contains("Gecikmeye göre"));
        }
    }

    #[test]
    fn blink_pattern_scores_by_lag() {
        // Simulated blink: T2 missed at lag 2–3, everything else seen.
        let mut g = Rsvp::level(50);
        play(&mut g, |g, syms| {
            let lag = g.streams[g.idx].lag;
            if lag == 2 || lag == 3 {
                vec![syms[0].clone()]
            } else {
                syms
            }
        });
        let short = g.streams.iter().filter(|s| s.lag == 2 || s.lag == 3).count();
        let later = (g.p.targets - 1) * STREAMS;
        let expect = 1.0 - short as f64 / later as f64;
        assert!((g.t2_given_t1() - expect).abs() < 1e-9);
        for (lag, n, ok) in g.lag_table() {
            if lag == 2 || lag == 3 {
                assert_eq!(ok, 0);
            } else {
                assert_eq!(ok, n);
            }
        }
        assert_eq!(g.t1_acc(), 1.0);
        assert!(g.state()["summary"].as_str().unwrap().contains("2→%0"));
    }

    #[test]
    fn missing_everything_loses_and_false_picks_count() {
        let mut g = Rsvp::level(1);
        play(&mut g, |g, syms| {
            // Pick two wrong digits.
            g.streams[g.idx].options.iter().filter(|o| !syms.contains(o)).take(2).cloned().collect()
        });
        let st = g.state();
        assert_eq!(st["status"], "lost");
        assert_eq!(st["t1_acc"], 0.0);
        assert!(st["summary"].as_str().unwrap().contains("Yanlış seçim 32"));
        // T1 only: T2|T1 = 0 → lost.
        let mut g = Rsvp::level(2);
        play(&mut g, |_, syms| vec![syms[0].clone()]);
        assert_eq!(g.state()["status"], "lost");
        assert_eq!(g.t1_acc(), 1.0);
    }

    #[test]
    fn stars_thresholds() {
        assert_eq!(stars_for(1.0, 0.85), 3);
        assert_eq!(stars_for(0.8, 0.9), 2);
        assert_eq!(stars_for(1.0, 0.72), 2);
        assert_eq!(stars_for(1.0, 0.65), 1);
        assert_eq!(stars_for(0.55, 1.0), 0);
        assert_eq!(stars_for(1.0, 0.59), 0);
    }

    #[test]
    fn illegal_actions_rejected_and_state_unchanged() {
        let mut g = Rsvp::level(1);
        let before = g.state();
        assert!(g.act(&json!({"pick": "3"})).is_err());
        assert!(g.act(&json!({"submit": true})).is_err());
        assert!(g.act(&json!({"foo": 1})).is_err());
        assert_eq!(g.state(), before);
        g.act(&json!({"start": true})).unwrap();
        assert!(g.act(&json!({"start": true})).is_err());
        g.tick(COUNTDOWN_MS + FIX_MS + 10.0);
        assert_eq!(g.phase, Phase::Stream);
        let before = g.state();
        assert!(g.act(&json!({"pick": "3"})).is_err()); // during the stream
        assert_eq!(g.state(), before);
        g.tick(5000.0);
        assert_eq!(g.phase, Phase::Answer);
        let syms = g.streams[0].symbols();
        assert!(g.act(&json!({"pick": "X"})).is_err()); // not an option
        let others: Vec<String> = g.streams[0].options.iter().filter(|o| !syms.contains(o)).cloned().collect();
        g.act(&json!({"pick": others[0]})).unwrap();
        g.act(&json!({"pick": others[1]})).unwrap();
        let before = g.state();
        assert!(g.act(&json!({"pick": others[2]})).is_err()); // max 2 picks
        assert_eq!(g.state(), before);
        g.act(&json!({"pick": others[1]})).unwrap(); // toggle off
        assert_eq!(g.state()["picked"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn stream_timing_is_exact_with_uneven_ticks() {
        let mut g = Rsvp::level(500); // 80 ms items
        g.act(&json!({"start": true})).unwrap();
        g.tick(COUNTDOWN_MS);
        g.tick(FIX_MS - 5.0);
        assert_eq!(g.phase, Phase::Fixation);
        g.tick(5.0 + 79.0);
        assert_eq!(g.current_item(), Some(0));
        g.tick(1.0);
        assert_eq!(g.current_item(), Some(1));
        // 16.7 ms frames: item k is shown exactly in [80k, 80(k+1)).
        let mut t = 80.0;
        while g.phase == Phase::Stream {
            assert_eq!(g.current_item(), Some((t / 80.0f64).floor() as usize));
            g.tick(16.7);
            t += 16.7;
        }
        assert_eq!(g.phase, Phase::Answer);
        assert!(g.state()["item"].is_null());
        assert!(!g.state()["options"].as_array().unwrap().is_empty());
    }

    #[test]
    #[ignore]
    fn timing_500_levels() {
        let t = std::time::Instant::now();
        let mut worst = 0.0f64;
        for level in 1..=500 {
            let s = std::time::Instant::now();
            let (p, set, streams) = gen_level(level);
            for st in &streams {
                check_stream(st, &p, &set);
            }
            worst = worst.max(s.elapsed().as_secs_f64());
        }
        println!("rsvp: 500 levels in {:?}, worst {:.3} ms", t.elapsed(), worst * 1000.0);
    }
}
