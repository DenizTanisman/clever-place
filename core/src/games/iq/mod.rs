//! IQ Soruları (`iq`) — 1000 medium/hard IQ-test-style questions in rotating categories. Just for
//! fun: no IQ score is computed or shown anywhere.
//!
//! **Plan** (`PLAN`, from docs/research/iq_question_types.md §4): 19 categories, 1000 questions,
//! 500 medium + 500 hard. Text/number categories live in this directory (one module each);
//! figural ones come from `figural::FIGURAL` by id. A category without a generator (figural ones
//! before they land) is skipped: the sequence then simply holds fewer questions.
//!
//! **Sequence.** Question content is deterministic per (category, occurrence j):
//! `seed_for("iq", j + 1, plan index + 1)`. Occurrences 0..medium are medium, the rest hard. The
//! global order is two halves (all medium questions, then all hard ones); each half is ordered by
//! proportional interleaving over the category counts (evenly spaced slots per category with a
//! seeded phase, then a repair pass so the same category never comes twice in a row), so every
//! window of ~10 questions mixes many categories and each level of 20 mixes a dozen or more.
//!
//! **Levels.** 50 levels × 20 questions: levels 1–25 walk the medium half, 26–50 the hard half
//! (when categories are missing the half is shorter and the levels wrap around it). Stars by
//! correct answers out of 20: 18+ → 3, 15+ → 2, 12+ → 1; fewer than 12 loses the level (retrying
//! gives the same questions). No timer. After every answer the state shows right/wrong and the
//! rule (`why`); `{"next":true}` moves on.
//!
//! **Endless "Karışık"** (`mode == "endless"`): random questions from the whole sequence (no
//! repeats within a run), a streak counter, three lives; `score` = longest streak.
//! `{"finish":true}` ends the run early.
//!
//! State: `{status, stars, title, goal, summary?, mode, phase: "question"|"feedback"|"done",
//!   q_index, q_count, answers: [bool], correct, streak, best_streak, lives,
//!   question: {cat, cat_name, hard, prompt, figure, options: [{text}|{figure}], typed: bool},
//!   last: {given, typed_value, answer, answer_value, correct, why} | null}`
//! Actions: `{"answer": i}` · `{"typed": n}` · `{"next": true}` · `{"finish": true}` (endless).

pub mod balance;
pub mod clock_calendar;
pub mod code;
pub mod common;
pub mod figural;
pub mod item;
pub mod letter_series;
pub mod logic;
pub mod missing_number;
pub mod number_series;
pub mod odd_number;
pub mod series;
pub mod word_problem;

#[cfg(test)]
mod checks;

use crate::rng::{seed_for, time_seed, Rng};
use crate::Session;
use item::{IqGen, IqItem};
use serde_json::{json, Value};
use std::sync::OnceLock;

pub const QUESTIONS_PER_LEVEL: usize = 20;
pub const LEVELS: u32 = 50;
pub const ENDLESS_LIVES: u32 = 3;

/// One category of the plan: id, Turkish UI name, total count, medium count.
#[derive(Clone, Copy, Debug)]
pub struct CatPlan {
    pub id: &'static str,
    pub name: &'static str,
    pub count: u32,
    pub medium: u32,
}

const fn c(id: &'static str, name: &'static str, count: u32, medium: u32) -> CatPlan {
    CatPlan { id, name, count, medium }
}

/// The 19 categories (research doc §4). "Farklı olanı bul" (50) is split into shapes and numbers.
pub const PLAN: &[CatPlan] = &[
    c("matrix", "Matris", 100, 50),
    c("number_series", "Sayı dizisi", 80, 40),
    c("missing_number", "Eksik sayı", 70, 35),
    c("balance", "Terazi", 70, 35),
    c("logic", "Mantık", 70, 35),
    c("shape_series", "Şekil dizisi", 60, 30),
    c("cube_rotation", "Küp döndürme", 60, 30),
    c("figure_analogy", "Şekil analojisi", 50, 25),
    c("odd_shape", "Farklı olanı bul", 25, 13),
    c("odd_number", "Farklı olanı bul", 25, 12),
    c("cube_net", "Küp açınımı", 50, 25),
    c("paper_fold", "Kâğıt katlama", 50, 25),
    c("letter_series", "Harf dizisi", 40, 20),
    c("block_count", "Blok sayma", 40, 20),
    c("mental_rotation", "Zihinsel döndürme", 40, 20),
    c("code", "Şifre çözme", 40, 20),
    c("matchstick", "Kibrit çöpü", 40, 20),
    c("assembly", "Parça birleştirme", 30, 15),
    c("clock_calendar", "Saat ve takvim", 30, 15),
    c("word_problem", "Sözel problem", 30, 15),
];

/// Generators of the text/number categories owned by this module.
pub fn text_gen(id: &str) -> Option<IqGen> {
    Some(match id {
        number_series::ID => number_series::gen,
        missing_number::ID => missing_number::gen,
        balance::ID => balance::gen,
        logic::ID => logic::gen,
        odd_number::ID => odd_number::gen,
        letter_series::ID => letter_series::gen,
        code::ID => code::gen,
        clock_calendar::ID => clock_calendar::gen,
        word_problem::ID => word_problem::gen,
        _ => return None,
    })
}

/// (generator, UI name) for a category id, from this module or `figural::FIGURAL`.
pub fn generator(id: &str) -> Option<(IqGen, &'static str)> {
    if let Some(g) = text_gen(id) {
        let name = PLAN.iter().find(|p| p.id == id).map(|p| p.name).unwrap_or("");
        return Some((g, name));
    }
    figural::FIGURAL.iter().find(|f| f.0 == id).map(|f| (f.2, f.1))
}

/// One question of the fixed sequence.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Slot {
    /// Index into `PLAN`.
    pub cat: usize,
    /// Occurrence of this category (0-based); `j < medium` ⇒ medium.
    pub j: u32,
    pub hard: bool,
}

impl Slot {
    pub fn plan(&self) -> &'static CatPlan {
        &PLAN[self.cat]
    }

    pub fn rng(&self) -> Rng {
        Rng::new(seed_for("iq", self.j + 1, self.cat as u32 + 1))
    }

    pub fn item(&self) -> IqItem {
        let (g, _) = generator(self.plan().id).expect("slot of a category without a generator");
        g(&mut self.rng(), self.hard)
    }
}

/// Proportional interleaving: category c with n questions gets evenly spaced ideal times
/// (k + phase_c) / n over the half, with a fixed seeded phase per category so no category is
/// front- or back-loaded (that made the seam between the halves heavy). Sorting the times gives
/// the order; a repair pass then swaps any back-to-back repeat (also against `prev`, the last
/// question of the previous half) with the nearest later question of another category.
fn rotate(counts: &[(usize, u32)], prev: Option<usize>, seed: u64) -> Vec<usize> {
    let mut r = Rng::new(seed);
    let mut events: Vec<(f64, usize)> = vec![];
    for &(cat, n) in counts {
        let phase = 0.15 + 0.7 * r.f64();
        for k in 0..n {
            events.push(((k as f64 + phase) / n as f64, cat));
        }
    }
    events.sort_by(|x, y| x.0.partial_cmp(&y.0).unwrap().then(x.1.cmp(&y.1)));
    let mut out: Vec<usize> = events.into_iter().map(|e| e.1).collect();
    for _pass in 0..20 {
        let mut clean = true;
        for i in 0..out.len() {
            let before = if i == 0 { prev } else { Some(out[i - 1]) };
            if Some(out[i]) != before {
                continue;
            }
            clean = false;
            let x = out[i];
            // A later question of another category whose move leaves no new repeat.
            let pick = (i + 1..out.len()).find(|&j| {
                let y = out[j];
                y != x
                    && (j == i + 1 || out[i + 1] != y)
                    && (j == i + 1 || out[j - 1] != x)
                    && (j + 1 >= out.len() || out[j + 1] != x)
            });
            if let Some(j) = pick {
                out.swap(i, j);
            }
        }
        if clean {
            break;
        }
    }
    out
}

fn build_sequence() -> Vec<Slot> {
    let active: Vec<usize> = (0..PLAN.len()).filter(|&i| generator(PLAN[i].id).is_some()).collect();
    let med: Vec<(usize, u32)> = active.iter().map(|&i| (i, PLAN[i].medium)).collect();
    let hard: Vec<(usize, u32)> = active.iter().map(|&i| (i, PLAN[i].count - PLAN[i].medium)).collect();
    let first = rotate(&med, None, seed_for("iq/order", 1, 0));
    let second = rotate(&hard, first.last().copied(), seed_for("iq/order", 2, 0));
    let mut seen = vec![0u32; PLAN.len()];
    let mut out = vec![];
    for cat in first.into_iter().chain(second) {
        let j = seen[cat];
        seen[cat] += 1;
        out.push(Slot { cat, j, hard: j >= PLAN[cat].medium });
    }
    out
}

/// The fixed question sequence (1000 slots once every category has a generator).
pub fn sequence() -> &'static [Slot] {
    static SEQ: OnceLock<Vec<Slot>> = OnceLock::new();
    SEQ.get_or_init(build_sequence)
}

/// The 20 slots of a level (1..=50; larger levels clamp to 50).
pub fn level_slots(level: u32) -> Vec<Slot> {
    let level = level.clamp(1, LEVELS);
    let seq = sequence();
    let hard = level > LEVELS / 2;
    let half: Vec<Slot> = seq.iter().copied().filter(|s| s.hard == hard).collect();
    if half.is_empty() {
        return vec![];
    }
    let i = ((level - 1) % (LEVELS / 2)) as usize;
    (0..QUESTIONS_PER_LEVEL).map(|q| half[(i * QUESTIONS_PER_LEVEL + q) % half.len()]).collect()
}

/// Move an item's correct option to `target`, shuffling the distractors into the other slots.
pub fn place_answer(it: &mut IqItem, target: usize, r: &mut Rng) {
    if it.typed.is_some() || it.options.is_empty() {
        return;
    }
    let target = target.min(it.options.len() - 1);
    let right = it.options.remove(it.answer);
    r.shuffle(&mut it.options);
    it.options.insert(target, right);
    it.answer = target;
}

/// Spread the correct answers of a level evenly over the option positions (owner's rule): every
/// position gets the same share, ±1 when option counts differ. Items with fewer options are
/// placed first (they have fewer slots to choose from); ties are broken by a seeded shuffle, so
/// which question gets which position is random but fixed for the level.
pub fn balance_positions(items: &mut [IqItem], r: &mut Rng) {
    let mut order: Vec<usize> = (0..items.len()).filter(|&i| items[i].typed.is_none() && !items[i].options.is_empty()).collect();
    r.shuffle(&mut order);
    order.sort_by_key(|&i| items[i].options.len());
    let max_n = order.iter().map(|&i| items[i].options.len()).max().unwrap_or(0);
    let mut used = vec![0usize; max_n];
    for i in order {
        let n = items[i].options.len();
        let least = (0..n).map(|p| used[p]).min().unwrap();
        let mut cands: Vec<usize> = (0..n).filter(|&p| used[p] == least).collect();
        r.shuffle(&mut cands);
        let target = cands[0];
        used[target] += 1;
        place_answer(&mut items[i], target, r);
    }
}

pub fn stars_for(correct: usize) -> u32 {
    match correct {
        18.. => 3,
        15.. => 2,
        12.. => 1,
        _ => 0,
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Phase {
    Question,
    Feedback,
    Done,
}

struct Answered {
    given: Option<usize>,
    typed: Option<i64>,
    correct: bool,
}

pub struct Iq {
    level: u32,
    endless: bool,
    slots: Vec<Slot>,
    items: Vec<IqItem>,
    idx: usize,
    phase: Phase,
    answers: Vec<Answered>,
    status: &'static str,
    stars: u32,
    streak: u32,
    best_streak: u32,
    lives: u32,
    rng: Rng,
    used: Vec<bool>,
    /// Endless: how often each answer position was used (keeps positions even over a run).
    pos_used: Vec<usize>,
}

pub fn create(level: u32, mode: &str) -> Result<Box<dyn Session>, String> {
    let g = if mode == "endless" { Iq::endless(time_seed()) } else { Iq::new(level) };
    if g.items.is_empty() {
        return Err("Soru yok".into());
    }
    Ok(Box::new(g))
}

impl Iq {
    pub fn new(level: u32) -> Self {
        let level = level.clamp(1, LEVELS);
        let slots = level_slots(level);
        let mut items: Vec<IqItem> = slots.iter().map(|s| s.item()).collect();
        balance_positions(&mut items, &mut Rng::new(seed_for("iq/positions", level, 0)));
        Iq {
            level,
            endless: false,
            slots,
            items,
            idx: 0,
            phase: Phase::Question,
            answers: vec![],
            status: "playing",
            stars: 0,
            streak: 0,
            best_streak: 0,
            lives: 0,
            rng: Rng::new(0),
            used: vec![],
            pos_used: vec![0; 8],
        }
    }

    pub fn endless(seed: u64) -> Self {
        let mut g = Iq::new(1);
        g.endless = true;
        g.slots.clear();
        g.items.clear();
        g.lives = ENDLESS_LIVES;
        g.rng = Rng::new(seed);
        g.used = vec![false; sequence().len()];
        g.draw();
        g
    }

    /// Endless: append one random unused question, avoiding the previous question's category.
    fn draw(&mut self) {
        let seq = sequence();
        if seq.is_empty() {
            return;
        }
        if self.used.iter().all(|&u| u) {
            self.used.iter_mut().for_each(|u| *u = false);
        }
        let prev = self.slots.last().map(|s| s.cat);
        for attempt in 0..200 {
            let k = self.rng.below(seq.len());
            if self.used[k] || (attempt < 150 && Some(seq[k].cat) == prev) {
                continue;
            }
            self.used[k] = true;
            self.push_item(seq[k]);
            return;
        }
        let k = (0..seq.len()).find(|&k| !self.used[k]).unwrap_or(0);
        self.used[k] = true;
        self.push_item(seq[k]);
    }

    /// Endless: add a question, putting its answer on the least used position so far.
    fn push_item(&mut self, slot: Slot) {
        let mut it = slot.item();
        if it.typed.is_none() && !it.options.is_empty() {
            let n = it.options.len();
            let least = (0..n).map(|p| self.pos_used[p]).min().unwrap();
            let cands: Vec<usize> = (0..n).filter(|&p| self.pos_used[p] == least).collect();
            let target = cands[self.rng.below(cands.len())];
            self.pos_used[target] += 1;
            place_answer(&mut it, target, &mut self.rng);
        }
        self.slots.push(slot);
        self.items.push(it);
    }

    fn correct(&self) -> usize {
        self.answers.iter().filter(|a| a.correct).count()
    }

    fn finish(&mut self) {
        self.phase = Phase::Done;
        if self.endless {
            self.status = "lost";
            return;
        }
        let c = self.correct();
        self.stars = stars_for(c);
        self.status = if self.stars > 0 { "won" } else { "lost" };
    }

    fn advance(&mut self) {
        if self.endless {
            if self.lives == 0 {
                self.finish();
                return;
            }
            self.draw();
            self.idx += 1;
            self.phase = Phase::Question;
            return;
        }
        if self.idx + 1 >= self.items.len() {
            self.finish();
        } else {
            self.idx += 1;
            self.phase = Phase::Question;
        }
    }

    fn record(&mut self, given: Option<usize>, typed: Option<i64>) {
        let it = &self.items[self.idx];
        let correct = match it.typed {
            Some(v) => typed == Some(v),
            None => given == Some(it.answer),
        };
        self.answers.push(Answered { given, typed, correct });
        if correct {
            self.streak += 1;
            self.best_streak = self.best_streak.max(self.streak);
        } else {
            self.streak = 0;
            if self.endless {
                self.lives = self.lives.saturating_sub(1);
            }
        }
        self.phase = Phase::Feedback;
    }

    fn summary(&self) -> String {
        let c = self.correct();
        let n = self.answers.len();
        if self.endless {
            format!("En uzun seri {} · Doğru {c}/{n}", self.best_streak)
        } else if self.status == "won" {
            format!("Doğru {c}/{n} · En uzun seri {}", self.best_streak)
        } else {
            format!("Doğru {c}/{n} · Geçmek için 12 doğru gerekli, aynı sorularla tekrar dene")
        }
    }

    fn cat_name(&self, i: usize) -> &'static str {
        let p = self.slots[i].plan();
        generator(p.id).map(|g| g.1).unwrap_or(p.name)
    }
}

impl Session for Iq {
    fn state(&self) -> Value {
        let i = self.idx.min(self.items.len().saturating_sub(1));
        let it = &self.items[i];
        let question = json!({
            "cat": it.cat,
            "cat_name": self.cat_name(i),
            "hard": it.hard,
            "prompt": it.prompt,
            "figure": it.figure,
            "options": it.options.iter().map(|o| o.to_json()).collect::<Vec<_>>(),
            "typed": it.typed.is_some(),
        });
        let last = (matches!(self.phase, Phase::Feedback | Phase::Done) && self.answers.len() > i).then(|| {
            let a = &self.answers[i];
            json!({
                "given": a.given,
                "typed_value": a.typed,
                "answer": if it.typed.is_some() { Value::Null } else { json!(it.answer) },
                "answer_value": it.typed,
                "correct": a.correct,
                "why": it.why,
            })
        });
        let hard = self.level > LEVELS / 2;
        let mut v = json!({
            "status": self.status,
            "stars": self.stars,
            "mode": if self.endless { "endless" } else { "level" },
            "title": if self.endless { format!("Seri {}", self.streak) } else if hard { "Zor".to_string() } else { "Orta".to_string() },
            "goal": if self.endless {
                format!("Karışık sorular · {} hak kaldı · En uzun seri {}", self.lives, self.best_streak)
            } else {
                format!("{} soru · 12 doğru geçer · 18 doğru 3 yıldız", self.items.len())
            },
            "level": self.level,
            "phase": match self.phase { Phase::Question => "question", Phase::Feedback => "feedback", Phase::Done => "done" },
            "q_index": i,
            "q_count": if self.endless { 0 } else { self.items.len() },
            "answers": self.answers.iter().map(|a| a.correct).collect::<Vec<_>>(),
            "correct": self.correct(),
            "streak": self.streak,
            "best_streak": self.best_streak,
            "score": self.best_streak,
            "lives": self.lives,
            "question": question,
            "last": last,
        });
        if self.phase == Phase::Done {
            v["summary"] = json!(self.summary());
        }
        v
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if self.status != "playing" {
            return Err("Bölüm bitti".into());
        }
        if a["next"].as_bool() == Some(true) {
            if self.phase != Phase::Feedback {
                return Err("Önce cevapla".into());
            }
            self.advance();
            return Ok(());
        }
        if a["finish"].as_bool() == Some(true) {
            if !self.endless {
                return Err("Bölüm modunda bitirilemez".into());
            }
            self.finish();
            return Ok(());
        }
        if self.phase != Phase::Question {
            return Err("Devam'a dokun".into());
        }
        let it = &self.items[self.idx];
        if let Some(i) = a["answer"].as_u64() {
            if it.typed.is_some() {
                return Err("Bu soruda sayıyı yaz".into());
            }
            if i as usize >= it.options.len() {
                return Err("Geçersiz seçenek".into());
            }
            self.record(Some(i as usize), None);
            return Ok(());
        }
        if let Some(v) = a["typed"].as_i64() {
            if it.typed.is_none() {
                return Err("Bu soruda bir seçenek seç".into());
            }
            self.record(None, Some(v));
            return Ok(());
        }
        Err("Bilinmeyen hamle".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn all_present() -> bool {
        PLAN.iter().all(|p| generator(p.id).is_some())
    }

    #[test]
    fn iq_plan_totals() {
        assert_eq!(PLAN.iter().map(|p| p.count).sum::<u32>(), 1000);
        assert_eq!(PLAN.iter().map(|p| p.medium).sum::<u32>(), 500);
        let mut ids: Vec<&str> = PLAN.iter().map(|p| p.id).collect();
        ids.sort();
        ids.dedup();
        assert_eq!(ids.len(), PLAN.len());
        // Every text category has a generator; figural ids are looked up in FIGURAL.
        for id in ["number_series", "missing_number", "balance", "logic", "odd_number", "letter_series", "code", "clock_calendar", "word_problem"] {
            assert!(text_gen(id).is_some(), "{id}");
        }
        for f in figural::FIGURAL {
            assert!(PLAN.iter().any(|p| p.id == f.0), "figural id {} is not in the plan", f.0);
        }
    }

    #[test]
    fn iq_sequence_counts_and_halves() {
        let seq = sequence();
        let expected: u32 = PLAN.iter().filter(|p| generator(p.id).is_some()).map(|p| p.count).sum();
        assert_eq!(seq.len() as u32, expected);
        if all_present() {
            assert_eq!(seq.len(), 1000);
            assert_eq!(seq.iter().filter(|s| !s.hard).count(), 500);
        }
        // Medium half first, then hard; per category occurrences 0..medium are medium.
        let first_hard = seq.iter().position(|s| s.hard).unwrap();
        assert!(seq[first_hard..].iter().all(|s| s.hard));
        for (i, p) in PLAN.iter().enumerate() {
            let occ: Vec<&Slot> = seq.iter().filter(|s| s.cat == i).collect();
            if generator(p.id).is_none() {
                assert!(occ.is_empty());
                continue;
            }
            assert_eq!(occ.len() as u32, p.count, "{}", p.id);
            for (j, s) in occ.iter().enumerate() {
                assert_eq!(s.j, j as u32);
                assert_eq!(s.hard, j as u32 >= p.medium);
            }
        }
    }

    #[test]
    fn iq_rotation_never_repeats_and_windows_are_varied() {
        let seq = sequence();
        for w in seq.windows(2) {
            assert_ne!(w[0].cat, w[1].cat, "two {} in a row", w[0].plan().id);
        }
        let active = PLAN.iter().filter(|p| generator(p.id).is_some()).count();
        let need = if active >= 15 { 7 } else { 6 };
        let mut min_distinct = usize::MAX;
        for w in seq.windows(10) {
            let mut c: Vec<usize> = w.iter().map(|s| s.cat).collect();
            c.sort();
            c.dedup();
            min_distinct = min_distinct.min(c.len());
            // No category more than three times in ten.
            for &k in &c {
                assert!(w.iter().filter(|s| s.cat == k).count() <= 3, "{} crowds a window", PLAN[k].id);
            }
        }
        assert!(min_distinct >= need, "a window of 10 has only {min_distinct} categories");
    }

    /// The rotation on the full plan (all 20 entries), independent of which generators exist yet.
    #[test]
    fn iq_rotation_on_the_full_plan() {
        let med: Vec<(usize, u32)> = (0..PLAN.len()).map(|i| (i, PLAN[i].medium)).collect();
        let hard: Vec<(usize, u32)> = (0..PLAN.len()).map(|i| (i, PLAN[i].count - PLAN[i].medium)).collect();
        let first = rotate(&med, None, seed_for("iq/order", 1, 0));
        let second = rotate(&hard, first.last().copied(), seed_for("iq/order", 2, 0));
        let all: Vec<usize> = first.iter().chain(second.iter()).copied().collect();
        assert_eq!(all.len(), 1000);
        for (i, p) in PLAN.iter().enumerate() {
            assert_eq!(all.iter().filter(|&&c| c == i).count() as u32, p.count);
        }
        for w in all.windows(2) {
            assert_ne!(w[0], w[1]);
        }
        let mut min_distinct = usize::MAX;
        for w in all.windows(10) {
            let mut c = w.to_vec();
            c.sort();
            c.dedup();
            min_distinct = min_distinct.min(c.len());
            for &k in &c {
                assert!(w.iter().filter(|&&x| x == k).count() <= 2, "{} three times in ten", PLAN[k].id);
            }
        }
        let worst = all
            .windows(10)
            .position(|w| {
                let mut c = w.to_vec();
                c.sort();
                c.dedup();
                c.len() == min_distinct
            })
            .unwrap();
        assert!(
            min_distinct >= 7,
            "a window of 10 has only {min_distinct} categories at {worst}: {:?}",
            all[worst..worst + 10].iter().map(|&k| PLAN[k].id).collect::<Vec<_>>()
        );
        // Every 20-question level mixes many categories.
        for lv in all.chunks(20) {
            let mut c = lv.to_vec();
            c.sort();
            c.dedup();
            assert!(c.len() >= 12, "a level has only {} categories", c.len());
        }
    }

    #[test]
    fn iq_levels_partition_the_halves() {
        let seq = sequence();
        let mut seen = std::collections::HashSet::new();
        for level in 1..=LEVELS {
            let slots = level_slots(level);
            assert_eq!(slots.len(), QUESTIONS_PER_LEVEL);
            assert!(slots.iter().all(|s| s.hard == (level > 25)), "level {level}");
            // (With categories missing, levels wrap around a shorter half; only the full plan
            // guarantees the seam between levels never repeats a category.)
            if seq.len() == 1000 {
                for w in slots.windows(2) {
                    assert_ne!(w[0].cat, w[1].cat);
                }
            }
            let mut cats: Vec<usize> = slots.iter().map(|s| s.cat).collect();
            cats.sort();
            cats.dedup();
            assert!(cats.len() >= 6, "level {level} mixes only {} categories", cats.len());
            for s in slots {
                seen.insert((s.cat, s.j));
            }
        }
        // With the full plan the 50 levels hold every question exactly once.
        if seq.len() == 1000 {
            assert_eq!(seen.len(), 1000);
        } else {
            assert_eq!(seen.len(), seq.len().min(1000));
        }
    }

    #[test]
    fn iq_levels_have_exact_position_quotas() {
        for level in 1..=LEVELS {
            let g = Iq::new(level);
            let mc: Vec<&IqItem> = g.items.iter().filter(|it| it.typed.is_none()).collect();
            let min_n = mc.iter().map(|it| it.options.len()).min().unwrap_or(4);
            let mut counts = vec![0usize; 8];
            for it in &mc {
                counts[it.answer] += 1;
            }
            let shared = &counts[..min_n];
            let (lo, hi) = (*shared.iter().min().unwrap(), *shared.iter().max().unwrap());
            assert!(hi - lo <= 1, "level {level}: answer positions {counts:?}");
            if mc.iter().all(|it| it.options.len() == min_n) {
                // Same option count everywhere: exact quotas (e.g. 20 four-option items = 5 each).
                assert!(shared.iter().all(|&c| c == mc.len() / min_n || c == mc.len().div_ceil(min_n)), "level {level}: {counts:?}");
            }
            // Re-placing keeps every option and the right answer.
            for (it, s) in g.items.iter().zip(&g.slots) {
                let orig = s.item();
                let mut a = it.options.clone();
                let mut b = orig.options.clone();
                a.sort_by_key(|o| format!("{o:?}"));
                b.sort_by_key(|o| format!("{o:?}"));
                assert_eq!(a, b);
                if it.typed.is_none() {
                    assert_eq!(it.options[it.answer], orig.options[orig.answer]);
                }
            }
        }
    }

    fn answer_all(g: &mut Iq, right: usize) {
        for i in 0..QUESTIONS_PER_LEVEL {
            let it = g.items[g.idx].clone();
            let ok = i < right;
            let act = match it.typed {
                Some(v) => json!({"typed": if ok { v } else { v + 1 }}),
                None => json!({"answer": if ok { it.answer } else { (it.answer + 1) % it.options.len() }}),
            };
            g.act(&act).unwrap();
            assert_eq!(g.state()["phase"], "feedback");
            assert_eq!(g.state()["last"]["correct"], ok);
            assert!(g.state()["last"]["why"].as_str().is_some_and(|w| !w.is_empty()));
            g.act(&json!({"next": true})).unwrap();
        }
    }

    #[test]
    fn iq_stars_and_retry() {
        for (right, stars, status) in [(20, 3, "won"), (18, 3, "won"), (17, 2, "won"), (15, 2, "won"), (14, 1, "won"), (12, 1, "won"), (11, 0, "lost")] {
            let mut g = Iq::new(3);
            answer_all(&mut g, right);
            let st = g.state();
            assert_eq!(st["status"], status, "{right} right");
            assert_eq!(st["stars"], stars, "{right} right");
            assert!(st["summary"].as_str().is_some());
        }
        // A retry has the same questions.
        let a = Iq::new(27);
        let b = Iq::new(27);
        for (x, y) in a.items.iter().zip(&b.items) {
            assert_eq!(x.prompt, y.prompt);
            assert_eq!(x.options, y.options);
            assert!(x.hard);
        }
    }

    #[test]
    fn iq_illegal_actions_leave_state() {
        let mut g = Iq::new(1);
        let before = g.state().to_string();
        assert!(g.act(&json!({"next": true})).is_err());
        assert!(g.act(&json!({"answer": 99})).is_err());
        assert!(g.act(&json!({"finish": true})).is_err());
        assert!(g.act(&json!({"jump": 1})).is_err());
        assert_eq!(before, g.state().to_string());
        let it = g.items[0].clone();
        if it.typed.is_some() {
            assert!(g.act(&json!({"answer": 0})).is_err());
            g.act(&json!({"typed": it.typed.unwrap()})).unwrap();
        } else {
            assert!(g.act(&json!({"typed": 3})).is_err());
            g.act(&json!({"answer": it.answer})).unwrap();
        }
        assert!(g.act(&json!({"answer": 0})).is_err(), "answering twice");
    }

    #[test]
    fn iq_endless_streak_lives_and_finish() {
        let mut g = Iq::endless(42);
        let mut answered = 0;
        while g.status == "playing" && answered < 60 {
            let it = g.items[g.idx].clone();
            // Three right, one wrong, repeating.
            let ok = answered % 4 != 3;
            let act = match it.typed {
                Some(v) => json!({"typed": if ok { v } else { v + 1 }}),
                None => json!({"answer": if ok { it.answer } else { (it.answer + 1) % it.options.len() }}),
            };
            g.act(&act).unwrap();
            g.act(&json!({"next": true})).unwrap();
            answered += 1;
        }
        assert_eq!(g.status, "lost");
        assert_eq!(answered, 12, "three lives, one lost every fourth answer");
        assert_eq!(g.state()["score"], 3);
        // No repeats within a run, and no category twice in a row.
        let mut keys: Vec<(usize, u32)> = g.slots.iter().map(|s| (s.cat, s.j)).collect();
        for w in g.slots.windows(2) {
            assert_ne!(w[0].cat, w[1].cat);
        }
        keys.sort();
        keys.dedup();
        assert_eq!(keys.len(), g.slots.len());
        let mut h = Iq::endless(7);
        h.act(&json!({"finish": true})).unwrap();
        assert_eq!(h.status, "lost");
    }

    #[test]
    fn iq_protocol_roundtrip() {
        let r = crate::handle(r#"{"op":"new","game":"iq","level":50,"mode":"level"}"#);
        assert_eq!(r["ok"], true, "{r}");
        assert_eq!(r["state"]["q_count"], 20);
        assert_eq!(r["state"]["question"]["hard"], true);
        let r = crate::handle(r#"{"op":"new","game":"iq","level":1,"mode":"endless"}"#);
        assert_eq!(r["ok"], true);
        assert_eq!(r["state"]["mode"], "endless");
    }

    /// `cargo test --release iq_level_timing -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn iq_level_timing() {
        let t = std::time::Instant::now();
        let mut worst = std::time::Duration::ZERO;
        for level in 1..=LEVELS {
            let t0 = std::time::Instant::now();
            let _ = Iq::new(level);
            worst = worst.max(t0.elapsed());
        }
        println!("50 levels in {:?}, worst level {:?}", t.elapsed(), worst);
    }
}
