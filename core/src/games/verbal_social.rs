//! Sözel ve Sosyal Zeka: a hand-authored bank of 450 Turkish multiple-choice items in three
//! sections of 150, Sözel (verbal reasoning), Sosyal zeka and Duygusal zeka.
//!
//! The bank is `app/assets/verbal_social/items.json`, embedded with `include_str!`. It is written
//! in `app/tool/verbal_social/src/*.json`, where the correct option is always first, and merged by
//! `assign_positions.py`. That script places each answer at a seeded position, with exact quotas
//! per (section, difficulty).
//! Item fields: `id, section, subtype, difficulty (orta|zor), prompt, options[4], answer, why`.
//!
//! **Levels (45 × 10, every item exactly once).**
//! - Slot `p` of level `L` (both counted from 0 here) holds section `(L + p) % 3`, so the sections
//!   rotate S, So, D, S, … and each level starts one section later than the one before.
//! - Each section's items are dealt to its slots in level order: all orta items first, then all zor.
//!   The counts (Sözel 74 orta, Sosyal 73, Duygusal 73) fill levels 1–22 exactly with orta items;
//!   levels 23–45 get the zor items.
//! - Inside a section and difficulty, the subtypes are interleaved in proportion to their counts by
//!   smooth weighted round robin, and the same subtype never comes twice in a row. Within a subtype
//!   the order is a seeded shuffle.
//! - Neighbouring items always come from different sections, so the same subtype is never back to
//!   back in play either.
//!
//! **Stars.** 9–10 correct → 3, 8 → 2, 7 → 1. Below 7 the level is lost and stays locked. A retry
//! replays the same items.
//!
//! **Karışık (mode "endless").** All 450 items, freshly shuffled and interleaved the same way, with
//! orta and zor mixed. A wrong answer breaks the streak, and the third wrong answer ends the run.
//! `score` is the best streak of the run.
//!
//! State:
//! ```text
//! {status, stars, title, goal, mode, level, phase: "question"|"feedback"|"done",
//!  q_index, q_count, answers: [bool], correct, needed, streak, best_streak, lives, score,
//!  question: {id, section, section_label, subtype, subtype_label, difficulty, prompt, options,
//!             consensus},
//!  last: {given, answer, correct, why} | null,
//!  summary?, review?: [{section_label, prompt, correct}]}
//! ```
//! `consensus` is true for emotion-management items: their key is the action the EI research
//! consensus rates most effective, and the view says so.
//!
//! Actions: `{"answer": i}` (in phase "question") and `{"next": true}` (in phase "feedback").

use crate::rng::{seed_for, time_seed, Rng};
use crate::Session;
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::OnceLock;

pub const LEVELS: u32 = 45;
pub const PER_LEVEL: usize = 10;
/// Levels whose items are all "orta"; the rest are "zor".
pub const ORTA_LEVELS: u32 = 22;
pub const ENDLESS_LIVES: u32 = 3;

pub const SECTIONS: [&str; 3] = ["sozel", "sosyal", "duygusal"];

const BANK_JSON: &str = include_str!("../../../app/assets/verbal_social/items.json");

#[derive(Clone, Debug, Deserialize)]
pub struct Item {
    pub id: String,
    pub section: String,
    pub subtype: String,
    pub difficulty: String,
    pub prompt: String,
    pub options: Vec<String>,
    pub answer: usize,
    pub why: String,
}

impl Item {
    pub fn section_index(&self) -> usize {
        SECTIONS.iter().position(|s| *s == self.section).unwrap_or(0)
    }
    pub fn zor(&self) -> bool {
        self.difficulty == "zor"
    }
}

pub fn section_label(s: &str) -> &'static str {
    match s {
        "sozel" => "Sözel",
        "sosyal" => "Sosyal",
        "duygusal" => "Duygusal",
        _ => "",
    }
}

pub fn subtype_label(s: &str) -> &'static str {
    match s {
        "analoji" => "Analoji",
        "farkli_olan" => "Farklı olan",
        "baglac" => "Bağlaç ve mantık",
        "deyim_atasozu" => "Deyim ve atasözü",
        "es_zit_anlam" => "Eş ve zıt anlam",
        "paragraf_cikarim" => "Paragraf çıkarımı",
        "cumle_siralama" => "Cümle sıralama",
        "zihin_kurami" => "Zihin kuramı",
        "pot" => "Pot kırma",
        "dolayli_anlatim" => "Dolaylı anlatım",
        "durum_okuma" => "Durumu okuma",
        "sohbet" => "Sohbet becerisi",
        "ton" => "Üslup ve ton",
        "duygu_anlama" => "Duyguyu anlama",
        "duygu_yonetimi" => "Duyguyu yönetme",
        "duygu_sozcukleri" => "Duygu sözcükleri",
        "duzenleme" => "Duygu düzenleme",
        _ => "",
    }
}

/// The parsed bank (panics on a malformed bank; the tests guard it).
pub fn bank() -> &'static [Item] {
    static BANK: OnceLock<Vec<Item>> = OnceLock::new();
    BANK.get_or_init(|| serde_json::from_str(BANK_JSON).expect("verbal_social items.json"))
}

/// Orders `pool` (item indices) so that subtypes are interleaved in proportion to their counts
/// (smooth weighted round robin), and the same subtype never comes twice in a row while another one
/// is left (nor right after `prev`, the subtype played just before). Within a subtype, items keep the
/// order they have in `pool`.
pub fn interleave(items: &[Item], pool: &[usize], prev: Option<&str>) -> Vec<usize> {
    let mut kinds: Vec<&str> = vec![];
    for &i in pool {
        if !kinds.contains(&items[i].subtype.as_str()) {
            kinds.push(&items[i].subtype);
        }
    }
    let mut queues: Vec<Vec<usize>> =
        kinds.iter().map(|k| pool.iter().copied().filter(|&i| items[i].subtype == *k).rev().collect()).collect();
    let weights: Vec<i64> = queues.iter().map(|q| q.len() as i64).collect();
    let total: i64 = weights.iter().sum();
    let mut credit = vec![0i64; kinds.len()];
    let mut out = Vec::with_capacity(pool.len());
    let mut last: Option<usize> = prev.and_then(|p| kinds.iter().position(|k| *k == p));
    while out.len() < pool.len() {
        for k in 0..kinds.len() {
            if !queues[k].is_empty() {
                credit[k] += weights[k];
            }
        }
        let live: Vec<usize> = (0..kinds.len()).filter(|&k| !queues[k].is_empty()).collect();
        let allowed: Vec<usize> = if live.len() > 1 { live.iter().copied().filter(|&k| Some(k) != last).collect() } else { live };
        let k = *allowed.iter().max_by_key(|&&k| (credit[k], std::cmp::Reverse(k))).expect("non-empty pool");
        credit[k] -= total;
        out.push(queues[k].pop().expect("live queue"));
        last = Some(k);
    }
    out
}

/// One section's play order: orta items (or all items when `mix`) interleaved by subtype, then zor.
fn section_order(items: &[Item], section: usize, rng: &mut Rng, mix: bool) -> Vec<usize> {
    let mut all: Vec<usize> = (0..items.len()).filter(|&i| items[i].section_index() == section).collect();
    rng.shuffle(&mut all);
    if mix {
        return interleave(items, &all, None);
    }
    let orta: Vec<usize> = all.iter().copied().filter(|&i| !items[i].zor()).collect();
    let zor: Vec<usize> = all.iter().copied().filter(|&i| items[i].zor()).collect();
    let mut out = interleave(items, &orta, None);
    let prev = out.last().map(|&i| items[i].subtype.as_str());
    out.extend(interleave(items, &zor, prev));
    out
}

/// Deals the three section orders into slots that rotate sections (slot p of block b holds section
/// (b + p) % 3), `per_block` slots per block.
fn deal(orders: [Vec<usize>; 3], per_block: usize) -> Vec<usize> {
    let total: usize = orders.iter().map(|o| o.len()).sum();
    let mut next = [0usize; 3];
    let mut out = Vec::with_capacity(total);
    let mut slot = 0usize;
    while out.len() < total {
        let (b, p) = (slot / per_block, slot % per_block);
        let s = (b + p) % 3;
        slot += 1;
        if next[s] < orders[s].len() {
            out.push(orders[s][next[s]]);
            next[s] += 1;
        }
    }
    out
}

/// The 45 fixed levels, 10 item indices each.
pub fn levels() -> &'static [Vec<usize>] {
    static LV: OnceLock<Vec<Vec<usize>>> = OnceLock::new();
    LV.get_or_init(|| {
        let items = bank();
        let mut rng = Rng::new(seed_for("verbal_social", 0, 0));
        let orders = [0, 1, 2].map(|s| section_order(items, s, &mut rng, false));
        deal(orders, PER_LEVEL).chunks(PER_LEVEL).map(|c| c.to_vec()).collect()
    })
}

/// An endless-mode order of all items (orta and zor mixed), from `seed`.
pub fn endless_order(seed: u64) -> Vec<usize> {
    let items = bank();
    let mut rng = Rng::new(seed);
    let orders = [0, 1, 2].map(|s| section_order(items, s, &mut rng, true));
    // A random first section; the rotation then continues S, So, D without restarting.
    let shift = rng.below(3);
    let rotated = [0, 1, 2].map(|k| orders[(k + shift) % 3].clone());
    deal(rotated, usize::MAX)
}

pub fn stars_for(correct: usize) -> u32 {
    match correct {
        9.. => 3,
        8 => 2,
        7 => 1,
        _ => 0,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase {
    Question,
    Feedback,
    Done,
}

pub struct VerbalSocial {
    level: u32,
    endless: bool,
    /// Item indices in play order (endless: refilled when used up).
    order: Vec<usize>,
    seed: u64,
    idx: usize,
    phase: Phase,
    /// (given option, correct) per answered item.
    answers: Vec<(usize, bool)>,
    streak: u32,
    best_streak: u32,
    status: &'static str,
    stars: u32,
}

pub fn create(level: u32, mode: &str) -> Result<Box<dyn Session>, String> {
    Ok(Box::new(if mode == "endless" { VerbalSocial::endless(time_seed()) } else { VerbalSocial::level(level) }))
}

impl VerbalSocial {
    pub fn level(level: u32) -> Self {
        let level = level.clamp(1, LEVELS);
        let order = levels()[(level - 1) as usize].clone();
        Self::with(level, false, order, 0)
    }

    pub fn endless(seed: u64) -> Self {
        Self::with(1, true, endless_order(seed), seed)
    }

    fn with(level: u32, endless: bool, order: Vec<usize>, seed: u64) -> Self {
        VerbalSocial {
            level,
            endless,
            order,
            seed,
            idx: 0,
            phase: Phase::Question,
            answers: vec![],
            streak: 0,
            best_streak: 0,
            status: "playing",
            stars: 0,
        }
    }

    fn item(&self) -> &'static Item {
        &bank()[self.order[self.idx.min(self.order.len() - 1)]]
    }

    fn correct(&self) -> usize {
        self.answers.iter().filter(|a| a.1).count()
    }

    fn wrong(&self) -> usize {
        self.answers.len() - self.correct()
    }

    /// Item ids in play order (tests, tools).
    pub fn ids(&self) -> Vec<&'static str> {
        self.order.iter().map(|&i| bank()[i].id.as_str()).collect()
    }

    fn advance(&mut self) {
        if self.endless {
            if self.wrong() as u32 >= ENDLESS_LIVES {
                self.phase = Phase::Done;
                self.status = "lost";
                return;
            }
            self.idx += 1;
            if self.idx >= self.order.len() {
                // Used up every item: a fresh shuffle that starts in another section than the last
                // item (so the rotation, and the no-repeat rule, carry over the seam).
                let last = &bank()[self.order[self.order.len() - 1]];
                let next = loop {
                    self.seed = self.seed.wrapping_add(0x9E37_79B9);
                    let next = endless_order(self.seed);
                    if bank()[next[0]].section != last.section {
                        break next;
                    }
                };
                self.order.extend(next);
            }
            self.phase = Phase::Question;
            return;
        }
        self.idx += 1;
        if self.idx >= self.order.len() {
            self.idx = self.order.len() - 1;
            self.phase = Phase::Done;
            self.stars = stars_for(self.correct());
            self.status = if self.stars > 0 { "won" } else { "lost" };
        } else {
            self.phase = Phase::Question;
        }
    }

    fn summary(&self) -> String {
        let c = self.correct();
        if self.endless {
            return format!("{} soruda {} doğru · En uzun seri {}", self.answers.len(), c, self.best_streak);
        }
        let mut per = [(0, 0); 3];
        for (k, a) in self.answers.iter().enumerate() {
            let s = bank()[self.order[k]].section_index();
            per[s].1 += 1;
            per[s].0 += a.1 as usize;
        }
        let parts: Vec<String> = (0..3).map(|s| format!("{} {}/{}", section_label(SECTIONS[s]), per[s].0, per[s].1)).collect();
        let head = format!("Doğru {c}/{}", self.order.len());
        if self.status == "lost" {
            format!("{head} · Geçmek için en az 7 doğru gerekir\n{}", parts.join(" · "))
        } else {
            format!("{head}\n{}", parts.join(" · "))
        }
    }
}

impl Session for VerbalSocial {
    fn state(&self) -> Value {
        let it = self.item();
        let last = matches!(self.phase, Phase::Feedback | Phase::Done)
            .then(|| self.answers.last())
            .flatten()
            .map(|&(given, correct)| json!({"given": given, "answer": it.answer, "correct": correct, "why": it.why}));
        let lives = ENDLESS_LIVES.saturating_sub(self.wrong() as u32);
        let mut v = json!({
            "status": self.status,
            "stars": self.stars,
            "title": if self.endless { "Karışık".to_string() } else if self.level > ORTA_LEVELS { "Zor".to_string() } else { "Orta".to_string() },
            "goal": if self.endless {
                format!("Seri {} · {} hata hakkı kaldı", self.streak, lives)
            } else {
                format!("{} soru · en az 7 doğru", self.order.len())
            },
            "mode": if self.endless { "endless" } else { "level" },
            "level": self.level,
            "phase": match self.phase { Phase::Question => "question", Phase::Feedback => "feedback", Phase::Done => "done" },
            "q_index": self.idx,
            "q_count": if self.endless { 0 } else { self.order.len() },
            "answers": self.answers.iter().map(|a| a.1).collect::<Vec<_>>(),
            "correct": self.correct(),
            "needed": 7,
            "streak": self.streak,
            "best_streak": self.best_streak,
            "lives": lives,
            "score": self.best_streak,
            "question": {
                "id": it.id,
                "section": it.section,
                "section_label": section_label(&it.section),
                "subtype": it.subtype,
                "subtype_label": subtype_label(&it.subtype),
                "difficulty": it.difficulty,
                "prompt": it.prompt,
                "options": it.options,
                "consensus": it.subtype == "duygu_yonetimi",
            },
            "last": last,
        });
        if self.phase == Phase::Done {
            v["summary"] = json!(self.summary());
            v["review"] = json!(self
                .answers
                .iter()
                .enumerate()
                .map(|(k, a)| {
                    let it = &bank()[self.order[k]];
                    json!({"section_label": section_label(&it.section), "prompt": it.prompt, "correct": a.1,
                           "answer_text": it.options[it.answer]})
                })
                .collect::<Vec<_>>());
        }
        v
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if self.status != "playing" {
            return Err("Bölüm bitti".into());
        }
        if a["next"].as_bool() == Some(true) {
            if self.phase != Phase::Feedback {
                return Err("Şimdi değil".into());
            }
            self.advance();
            return Ok(());
        }
        if let Some(i) = a["answer"].as_u64() {
            if self.phase != Phase::Question {
                return Err("Önce devam et".into());
            }
            let it = self.item();
            let i = i as usize;
            if i >= it.options.len() {
                return Err("Geçersiz seçenek".into());
            }
            let correct = i == it.answer;
            self.answers.push((i, correct));
            if correct {
                self.streak += 1;
                self.best_streak = self.best_streak.max(self.streak);
            } else {
                self.streak = 0;
            }
            self.phase = Phase::Feedback;
            return Ok(());
        }
        Err("Bilinmeyen hamle".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::{HashMap, HashSet};

    fn len(s: &str) -> f64 {
        s.chars().count() as f64
    }

    fn norm(s: &str) -> String {
        s.to_lowercase().chars().filter(|c| c.is_alphanumeric() || *c == ' ').collect::<String>().split_whitespace().collect::<Vec<_>>().join(" ")
    }

    fn by_section(s: usize) -> Vec<&'static Item> {
        bank().iter().filter(|i| i.section_index() == s).collect()
    }

    // ------------------------------------------------------------------ bank validity

    #[test]
    fn bank_shape() {
        let b = bank();
        assert_eq!(b.len(), 450);
        let subtypes: [&[&str]; 3] = [
            &["analoji", "farkli_olan", "baglac", "deyim_atasozu", "es_zit_anlam", "paragraf_cikarim", "cumle_siralama"],
            &["zihin_kurami", "pot", "dolayli_anlatim", "durum_okuma", "sohbet", "ton"],
            &["duygu_anlama", "duygu_yonetimi", "duygu_sozcukleri", "duzenleme"],
        ];
        let mut ids = HashSet::new();
        for it in b {
            assert!(SECTIONS.contains(&it.section.as_str()), "{}: section", it.id);
            assert!(subtypes[it.section_index()].contains(&it.subtype.as_str()), "{}: subtype {}", it.id, it.subtype);
            assert!(!subtype_label(&it.subtype).is_empty());
            assert!(it.difficulty == "orta" || it.difficulty == "zor", "{}: difficulty", it.id);
            assert!(ids.insert(it.id.clone()), "duplicate id {}", it.id);
            assert!(!it.why.trim().is_empty(), "{}: why", it.id);
            assert!(it.prompt.split_whitespace().count() <= 70, "{}: prompt over 70 words", it.id);
            for o in &it.options {
                assert!(o.split_whitespace().count() <= 22, "{}: option over 22 words", it.id);
            }
            let text = format!("{}{}{}", it.prompt, it.options.concat(), it.why);
            assert!(!text.chars().any(|c| "→←↑↓●★☆♥✓✗✔✘•".contains(c)), "{}: glyph missing from Jost", it.id);
        }
        for (s, orta) in [(0, 74), (1, 73), (2, 73)] {
            let items = by_section(s);
            assert_eq!(items.len(), 150, "{}", SECTIONS[s]);
            assert_eq!(items.iter().filter(|i| !i.zor()).count(), orta, "{} orta count", SECTIONS[s]);
        }
    }

    #[test]
    fn no_duplicate_prompts() {
        let mut seen: HashMap<String, &str> = HashMap::new();
        for it in bank() {
            if let Some(other) = seen.insert(norm(&it.prompt), &it.id) {
                panic!("{} repeats the prompt of {}", it.id, other);
            }
        }
    }

    #[test]
    fn four_distinct_options_and_answer_in_range() {
        for it in bank() {
            assert_eq!(it.options.len(), 4, "{}", it.id);
            let set: HashSet<String> = it.options.iter().map(|o| norm(o)).collect();
            assert_eq!(set.len(), 4, "{}: options not distinct", it.id);
            assert!(it.answer < 4, "{}: answer out of range", it.id);
            for o in &it.options {
                let n = norm(o);
                assert!(!["hepsi", "hiçbiri", "ikisi de"].iter().any(|b| n == *b || n.starts_with(&format!("{b} "))), "{}: {o}", it.id);
            }
        }
    }

    /// Exact quotas: in every (section, difficulty) group of N items each position is the answer
    /// N/4 times (±1 for the remainder), and per section within ±5% of an even split.
    #[test]
    fn answer_positions_balanced() {
        for s in 0..3 {
            for zor in [false, true] {
                let g: Vec<_> = by_section(s).into_iter().filter(|i| i.zor() == zor).collect();
                let n = g.len();
                for p in 0..4 {
                    let c = g.iter().filter(|i| i.answer == p).count();
                    assert!(c == n / 4 || c == n.div_ceil(4), "{} zor={zor}: position {p} is the answer {c} times of {n}", SECTIONS[s]);
                }
            }
            let items = by_section(s);
            for p in 0..4 {
                let c = items.iter().filter(|i| i.answer == p).count() as f64 / items.len() as f64;
                assert!((c - 0.25).abs() <= 0.05, "{} position {p}: {:.1}%", SECTIONS[s], c * 100.0);
            }
        }
    }

    /// No length giveaway: the correct option stays within 0.75–1.33× the mean distractor length
    /// (single words may instead be within 3 characters of it), and per section it is the strictly
    /// longest, or the strictly shortest, option in at most 25% of the items.
    #[test]
    fn option_length_bias() {
        for s in 0..3 {
            let items = by_section(s);
            let (mut longest, mut shortest) = (0, 0);
            for it in &items {
                let c = len(&it.options[it.answer]);
                let others: Vec<f64> = (0..4).filter(|&k| k != it.answer).map(|k| len(&it.options[k])).collect();
                let mean = others.iter().sum::<f64>() / 3.0;
                assert!(
                    (0.75 * mean..=1.33 * mean).contains(&c) || (c - mean).abs() <= 3.0,
                    "{}: correct option length {c} vs distractor mean {mean:.1}",
                    it.id
                );
                if others.iter().all(|&o| c > o) {
                    longest += 1;
                }
                if others.iter().all(|&o| c < o) {
                    shortest += 1;
                }
            }
            let n = items.len();
            assert!(longest * 4 <= n, "{}: correct is the longest in {longest}/{n}", SECTIONS[s]);
            assert!(shortest * 4 <= n, "{}: correct is the shortest in {shortest}/{n}", SECTIONS[s]);
        }
    }

    // ------------------------------------------------------------------ levels

    #[test]
    fn all_levels_generate_and_use_every_item_once() {
        let lv = levels();
        assert_eq!(lv.len(), LEVELS as usize);
        let mut used = HashSet::new();
        for (l, items) in lv.iter().enumerate() {
            assert_eq!(items.len(), PER_LEVEL, "level {}", l + 1);
            for &i in items {
                assert!(used.insert(i), "item {} used twice", bank()[i].id);
            }
            let g = VerbalSocial::level(l as u32 + 1);
            assert_eq!(g.state()["question"]["options"].as_array().unwrap().len(), 4);
        }
        assert_eq!(used.len(), 450);
    }

    #[test]
    fn orta_first_then_zor() {
        for (l, items) in levels().iter().enumerate() {
            let want_zor = l as u32 + 1 > ORTA_LEVELS;
            for &i in items {
                assert_eq!(bank()[i].zor(), want_zor, "level {} item {}", l + 1, bank()[i].id);
            }
        }
    }

    #[test]
    fn sections_rotate_and_subtypes_never_repeat_back_to_back() {
        let lv = levels();
        let flat: Vec<usize> = lv.concat();
        for (l, items) in lv.iter().enumerate() {
            for (p, &i) in items.iter().enumerate() {
                assert_eq!(bank()[i].section_index(), (l + p) % 3, "level {} slot {}", l + 1, p);
            }
        }
        for w in flat.windows(2) {
            assert_ne!(bank()[w[0]].subtype, bank()[w[1]].subtype);
        }
        // Within each section's own sequence too.
        for s in 0..3 {
            let seq: Vec<usize> = flat.iter().copied().filter(|&i| bank()[i].section_index() == s).collect();
            for w in seq.windows(2) {
                assert_ne!(bank()[w[0]].subtype, bank()[w[1]].subtype, "{} {} {} {}", bank()[w[0]].id, bank()[w[1]].id, bank()[w[0]].difficulty, bank()[w[1]].difficulty);
            }
        }
    }

    /// Proportional mixing: along each section's sequence (per difficulty), every subtype's running
    /// count stays within 2 of its proportional share.
    #[test]
    fn subtypes_interleave_in_proportion() {
        let flat: Vec<usize> = levels().concat();
        for s in 0..3 {
            for zor in [false, true] {
                let seq: Vec<&Item> = flat.iter().map(|&i| &bank()[i]).filter(|i| i.section_index() == s && i.zor() == zor).collect();
                let n = seq.len() as f64;
                let mut total: HashMap<&str, f64> = HashMap::new();
                for it in &seq {
                    *total.entry(&it.subtype).or_default() += 1.0;
                }
                let mut run: HashMap<&str, f64> = HashMap::new();
                for (k, it) in seq.iter().enumerate() {
                    *run.entry(&it.subtype).or_default() += 1.0;
                    for (st, t) in &total {
                        let share = t * (k + 1) as f64 / n;
                        let have = run.get(st).copied().unwrap_or(0.0);
                        assert!((have - share).abs() <= 2.0, "{} zor={zor} {st} at {k}: {have} vs {share:.1}", SECTIONS[s]);
                    }
                }
            }
        }
    }

    #[test]
    fn interleave_example_three_big_one_small() {
        // Three types of 6 and one of 2: one of each big type, the small one about every 3rd round.
        let mk = |st: &'static str, n: usize| (0..n).map(move |k| Item {
            id: format!("{st}{k}"),
            section: "sozel".into(),
            subtype: st.into(),
            difficulty: "orta".into(),
            prompt: String::new(),
            options: vec![],
            answer: 0,
            why: String::new(),
        });
        let items: Vec<Item> = mk("a", 6).chain(mk("b", 6)).chain(mk("c", 6)).chain(mk("d", 2)).collect();
        let pool: Vec<usize> = (0..items.len()).collect();
        let order: String = interleave(&items, &pool, None).iter().map(|&i| items[i].subtype.clone()).collect();
        assert_eq!(order.len(), 20);
        assert!(!order.as_bytes().windows(2).any(|w| w[0] == w[1]), "{order}");
        assert_eq!(&order[..3], "abc", "{order}");
        let d: Vec<usize> = order.match_indices('d').map(|(k, _)| k).collect();
        assert!(d[0] >= 3 && d[0] <= 9 && d[1] >= 10, "{order}");
    }

    #[test]
    fn levels_are_deterministic() {
        for l in [1, 2, 22, 23, 45] {
            assert_eq!(VerbalSocial::level(l).ids(), VerbalSocial::level(l).ids());
        }
        assert_ne!(VerbalSocial::level(1).ids(), VerbalSocial::level(2).ids());
    }

    // ------------------------------------------------------------------ play

    fn play(g: &mut VerbalSocial, right: usize) {
        for k in 0..PER_LEVEL {
            let ans = g.item().answer;
            let pick = if k < right { ans } else { (ans + 1) % 4 };
            g.act(&json!({"answer": pick})).unwrap();
            let st = g.state();
            assert_eq!(st["phase"], "feedback");
            assert_eq!(st["last"]["correct"], k < right);
            assert!(st["last"]["why"].as_str().unwrap().len() > 10);
            g.act(&json!({"next": true})).unwrap();
        }
    }

    #[test]
    fn stars_from_correct_count() {
        for (right, status, stars) in [(10, "won", 3), (9, "won", 3), (8, "won", 2), (7, "won", 1), (6, "lost", 0), (0, "lost", 0)] {
            let mut g = VerbalSocial::level(5);
            play(&mut g, right);
            let st = g.state();
            assert_eq!((st["status"].as_str().unwrap(), st["stars"].as_u64().unwrap() as u32), (status, stars), "{right} right");
            assert_eq!(st["phase"], "done");
            assert_eq!(st["review"].as_array().unwrap().len(), 10);
            assert!(st["summary"].as_str().unwrap().starts_with(&format!("Doğru {right}/10")));
            assert!(g.act(&json!({"answer": 0})).is_err());
        }
    }

    #[test]
    fn illegal_actions_leave_state_unchanged() {
        let mut g = VerbalSocial::level(1);
        let before = g.state();
        assert!(g.act(&json!({"next": true})).is_err());
        assert!(g.act(&json!({"answer": 4})).is_err());
        assert!(g.act(&json!({"jump": 1})).is_err());
        assert_eq!(g.state(), before);
        g.act(&json!({"answer": 0})).unwrap();
        assert!(g.act(&json!({"answer": 1})).is_err(), "one answer per item");
    }

    #[test]
    fn consensus_flag_marks_emotion_management() {
        let lv = levels();
        let (l, k) = (0..lv.len())
            .flat_map(|l| (0..PER_LEVEL).map(move |k| (l, k)))
            .find(|&(l, k)| bank()[lv[l][k]].subtype == "duygu_yonetimi")
            .unwrap();
        let mut g = VerbalSocial::level(l as u32 + 1);
        for _ in 0..k {
            g.act(&json!({"answer": 0})).unwrap();
            g.act(&json!({"next": true})).unwrap();
        }
        assert_eq!(g.state()["question"]["consensus"], true);
        assert_eq!(g.state()["question"]["section_label"], "Duygusal");
    }

    #[test]
    fn endless_streak_and_three_lives() {
        let mut g = VerbalSocial::endless(42);
        assert_eq!(g.state()["title"], "Karışık");
        let order = endless_order(42);
        assert_eq!(order.len(), 450);
        assert_eq!(order.iter().collect::<HashSet<_>>().len(), 450);
        for w in order.windows(2) {
            assert_ne!(bank()[w[0]].section, bank()[w[1]].section);
        }
        for _ in 0..5 {
            let a = g.item().answer;
            g.act(&json!({"answer": a})).unwrap();
            g.act(&json!({"next": true})).unwrap();
        }
        assert_eq!(g.state()["streak"], 5);
        for n in 1..=3 {
            let a = g.item().answer;
            g.act(&json!({"answer": (a + 1) % 4})).unwrap();
            assert_eq!(g.state()["streak"], 0);
            g.act(&json!({"next": true})).unwrap();
            if n < 3 {
                assert_eq!(g.state()["status"], "playing");
                let a = g.item().answer;
                g.act(&json!({"answer": a})).unwrap();
                g.act(&json!({"next": true})).unwrap();
            }
        }
        let st = g.state();
        assert_eq!(st["status"], "lost");
        assert_eq!(st["score"], 5);
        assert_eq!(st["lives"], 0);
    }

    #[test]
    fn endless_refills_after_the_whole_bank() {
        let mut g = VerbalSocial::endless(7);
        for _ in 0..460 {
            let a = g.item().answer;
            g.act(&json!({"answer": a})).unwrap();
            g.act(&json!({"next": true})).unwrap();
        }
        assert_eq!(g.state()["status"], "playing");
        assert_eq!(g.state()["best_streak"], 460);
    }

    #[test]
    fn registered_in_core() {
        assert!(crate::games::GAME_IDS.contains(&"verbal_social"));
        let r = crate::handle(r#"{"op":"new","game":"verbal_social","level":3,"mode":"level"}"#);
        assert_eq!(r["ok"], true, "{r}");
        assert_eq!(r["state"]["q_count"], 10);
    }
}
