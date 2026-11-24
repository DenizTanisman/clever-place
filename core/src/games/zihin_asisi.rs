//! Zihin Aşısı: an original game built on inoculation theory (McGuire 1961; Roozenbeek et al. 2022).
//! The player reads invented group-chat messages, names the manipulation technique, picks the best
//! reply, and also has to recognise sound messages, so that blanket suspicion does not pay.
//!
//! The bank is `app/assets/zihin_asisi/bank.json`, built by `app/tool/zihin_asisi/build.py` from
//! `app/tool/zihin_asisi/src/*.json`. Answer positions are assigned by that script.
//!
//! **Levels.** Each technique's items, in a seeded order, are cut into levels of 10; every such level
//! opens with the technique's warning card. Items whose `set` is "karma" form the closing mixed
//! levels, which have no card. Stars: 9–10 correct → 3, 8 → 2, 7 → 1; below 7 the level is lost.
//!
//! **Karışık (mode "endless").** All items, shuffled. The third wrong answer ends the run; `score`
//! is the best streak. This is the "booster" dose: the research finds the effect fades without one.
//!
//! State:
//! ```text
//! {status, stars, title, goal, mode, level, phase: "intro"|"question"|"feedback"|"done",
//!  q_index, q_count, answers: [bool], correct, needed, streak, best_streak, lives, score,
//!  intro: {name, what, why, defense} | null,
//!  question: {id, sender, message, ask, options, difficulty},
//!  last: {given, answer, correct, why, technique_label} | null,
//!  summary?, review?: [{technique_label, message, correct, answer_text}]}
//! ```
//! Actions: `{"start": true}` (intro), `{"answer": i}` (question), `{"next": true}` (feedback).

use crate::rng::{seed_for, time_seed, Rng};
use crate::Session;
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::OnceLock;

pub const PER_LEVEL: usize = 10;
pub const NEEDED: usize = 7;
pub const ENDLESS_LIVES: u32 = 3;
/// Set name of the closing mixed levels.
pub const KARMA: &str = "karma";
/// `technique` value of a sound message.
pub const SAGLAM: &str = "saglam";

const BANK_JSON: &str = include_str!("../../../app/assets/zihin_asisi/bank.json");

#[derive(Debug, Deserialize)]
pub struct Technique {
    pub id: String,
    pub name: String,
    pub what: String,
    pub why: String,
    pub defense: String,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Item {
    pub id: String,
    pub set: String,
    pub technique: String,
    pub kind: String,
    pub difficulty: String,
    pub sender: String,
    pub message: String,
    pub ask: String,
    pub options: Vec<String>,
    pub answer: usize,
    pub why: String,
}

#[derive(Debug, Deserialize)]
pub struct Bank {
    pub techniques: Vec<Technique>,
    pub items: Vec<Item>,
}

pub fn bank() -> &'static Bank {
    static BANK: OnceLock<Bank> = OnceLock::new();
    BANK.get_or_init(|| serde_json::from_str(BANK_JSON).expect("zihin_asisi bank.json"))
}

pub fn technique_label(id: &str) -> String {
    if id == SAGLAM {
        return "Sağlam mesaj".to_string();
    }
    bank().techniques.iter().find(|t| t.id == id).map(|t| t.name.clone()).unwrap_or_default()
}

pub struct LevelDef {
    /// Index into `techniques`; `None` for a mixed level.
    pub technique: Option<usize>,
    pub items: Vec<usize>,
}

fn pool_of(set: &str) -> Vec<usize> {
    let b = bank();
    let mut p: Vec<usize> = (0..b.items.len()).filter(|&i| b.items[i].set == set).collect();
    p.sort_by(|&x, &y| b.items[x].id.cmp(&b.items[y].id));
    p
}

/// Every level in play order: the techniques in bank order, then the mixed levels.
pub fn levels() -> &'static [LevelDef] {
    static LV: OnceLock<Vec<LevelDef>> = OnceLock::new();
    LV.get_or_init(|| {
        let b = bank();
        let mut rng = Rng::new(seed_for("zihin_asisi", 0, 0));
        let mut out = vec![];
        for (t, tech) in b.techniques.iter().enumerate() {
            let mut p = pool_of(&tech.id);
            rng.shuffle(&mut p);
            out.extend(p.chunks(PER_LEVEL).map(|c| LevelDef { technique: Some(t), items: c.to_vec() }));
        }
        // Mixed levels keep the source's blocks of 10 (build.py balances answers per block, and each
        // block is authored with its own sound messages); only the order inside a block is shuffled.
        for c in pool_of(KARMA).chunks(PER_LEVEL) {
            let mut items = c.to_vec();
            rng.shuffle(&mut items);
            out.push(LevelDef { technique: None, items });
        }
        out
    })
}

pub fn level_count() -> u32 {
    levels().len() as u32
}

pub fn stars_for(correct: usize) -> u32 {
    match correct {
        9.. => 3,
        8 => 2,
        7 => 1,
        _ => 0,
    }
}

fn endless_order(seed: u64) -> Vec<usize> {
    let mut all: Vec<usize> = (0..bank().items.len()).collect();
    Rng::new(seed).shuffle(&mut all);
    all
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase {
    Intro,
    Question,
    Feedback,
    Done,
}

pub struct ZihinAsisi {
    level: u32,
    endless: bool,
    technique: Option<usize>,
    order: Vec<usize>,
    seed: u64,
    idx: usize,
    phase: Phase,
    answers: Vec<(usize, bool)>,
    streak: u32,
    best_streak: u32,
    status: &'static str,
    stars: u32,
}

pub fn create(level: u32, mode: &str) -> Result<Box<dyn Session>, String> {
    Ok(Box::new(if mode == "endless" { ZihinAsisi::endless(time_seed()) } else { ZihinAsisi::level(level) }))
}

impl ZihinAsisi {
    pub fn level(level: u32) -> Self {
        let level = level.clamp(1, level_count());
        let def = &levels()[(level - 1) as usize];
        Self::with(level, false, def.technique, def.items.clone(), 0)
    }

    pub fn endless(seed: u64) -> Self {
        Self::with(1, true, None, endless_order(seed), seed)
    }

    fn with(level: u32, endless: bool, technique: Option<usize>, order: Vec<usize>, seed: u64) -> Self {
        ZihinAsisi {
            level,
            endless,
            technique,
            order,
            seed,
            idx: 0,
            phase: if technique.is_some() { Phase::Intro } else { Phase::Question },
            answers: vec![],
            streak: 0,
            best_streak: 0,
            status: "playing",
            stars: 0,
        }
    }

    fn item(&self) -> &'static Item {
        &bank().items[self.order[self.idx.min(self.order.len() - 1)]]
    }

    fn correct(&self) -> usize {
        self.answers.iter().filter(|a| a.1).count()
    }

    fn wrong(&self) -> usize {
        self.answers.len() - self.correct()
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
                self.seed = self.seed.wrapping_add(0x9E37_79B9);
                self.order.extend(endless_order(self.seed));
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

    /// (right, total) on sound messages: shows whether the player has become merely suspicious.
    fn saglam_skoru(&self) -> (usize, usize) {
        let mut s = (0, 0);
        for (k, a) in self.answers.iter().enumerate() {
            if bank().items[self.order[k]].technique == SAGLAM {
                s.1 += 1;
                s.0 += a.1 as usize;
            }
        }
        s
    }

    fn summary(&self) -> String {
        let c = self.correct();
        let (sr, st) = self.saglam_skoru();
        let saglam = if st > 0 { format!("\nSağlam mesajları ayırma {sr}/{st}") } else { String::new() };
        if self.endless {
            return format!("{} mesajda {} doğru · En uzun seri {}{}", self.answers.len(), c, self.best_streak, saglam);
        }
        let head = format!("Doğru {c}/{}", self.order.len());
        if self.status == "lost" {
            format!("{head} · Geçmek için en az {NEEDED} doğru gerekir{saglam}")
        } else {
            format!("{head}{saglam}")
        }
    }

    fn title(&self) -> String {
        if self.endless {
            "Hatırlatma dozu".to_string()
        } else if let Some(t) = self.technique {
            bank().techniques[t].name.clone()
        } else {
            "Karma sınav".to_string()
        }
    }
}

impl Session for ZihinAsisi {
    fn state(&self) -> Value {
        let it = self.item();
        let last = matches!(self.phase, Phase::Feedback | Phase::Done).then(|| self.answers.last()).flatten().map(|&(given, correct)| {
            json!({"given": given, "answer": it.answer, "correct": correct, "why": it.why,
                   "technique_label": technique_label(&it.technique)})
        });
        let lives = ENDLESS_LIVES.saturating_sub(self.wrong() as u32);
        let intro = (self.phase == Phase::Intro).then(|| self.technique).flatten().map(|t| {
            let x = &bank().techniques[t];
            json!({"name": x.name, "what": x.what, "why": x.why, "defense": x.defense})
        });
        let mut v = json!({
            "status": self.status,
            "stars": self.stars,
            "title": self.title(),
            "goal": if self.endless {
                format!("Seri {} · {} hata hakkı kaldı", self.streak, lives)
            } else {
                format!("{} mesaj · en az {NEEDED} doğru", self.order.len())
            },
            "mode": if self.endless { "endless" } else { "level" },
            "level": self.level,
            "phase": match self.phase {
                Phase::Intro => "intro",
                Phase::Question => "question",
                Phase::Feedback => "feedback",
                Phase::Done => "done",
            },
            "q_index": self.idx,
            "q_count": if self.endless { 0 } else { self.order.len() },
            "answers": self.answers.iter().map(|a| a.1).collect::<Vec<_>>(),
            "correct": self.correct(),
            "needed": NEEDED,
            "streak": self.streak,
            "best_streak": self.best_streak,
            "lives": lives,
            "score": self.best_streak,
            "intro": intro,
            "question": {
                "id": it.id,
                "sender": it.sender,
                "message": it.message,
                "ask": it.ask,
                "options": it.options,
                "difficulty": it.difficulty,
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
                    let it = &bank().items[self.order[k]];
                    json!({"technique_label": technique_label(&it.technique), "message": it.message,
                           "correct": a.1, "answer_text": it.options[it.answer]})
                })
                .collect::<Vec<_>>());
        }
        v
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if self.status != "playing" {
            return Err("Bölüm bitti".into());
        }
        if a["start"].as_bool() == Some(true) {
            if self.phase != Phase::Intro {
                return Err("Şimdi değil".into());
            }
            self.phase = Phase::Question;
            return Ok(());
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
    use std::collections::HashSet;

    #[test]
    fn bank_is_well_formed() {
        let b = bank();
        assert_eq!(b.techniques.len(), 11);
        let techs: HashSet<&str> = b.techniques.iter().map(|t| t.id.as_str()).collect();
        let mut ids = HashSet::new();
        for it in &b.items {
            assert!(ids.insert(it.id.as_str()), "duplicate {}", it.id);
            assert_eq!(it.options.len(), 4, "{}", it.id);
            assert!(it.answer < 4, "{}", it.id);
            assert_eq!(it.options.iter().collect::<HashSet<_>>().len(), 4, "{}", it.id);
            assert!(it.set == KARMA || techs.contains(it.set.as_str()), "{}", it.id);
            assert!(it.technique == SAGLAM || techs.contains(it.technique.as_str()), "{}", it.id);
            assert!(["teshis", "karsilik", "saglam"].contains(&it.kind.as_str()), "{}", it.id);
            assert!(!it.why.is_empty() && !it.message.is_empty() && !it.ask.is_empty(), "{}", it.id);
        }
    }

    #[test]
    fn the_course_has_thirteen_levels() {
        assert_eq!(level_count(), 13);
        assert_eq!(bank().items.len(), 130);
    }

    #[test]
    fn every_level_has_ten_items_and_sound_messages() {
        for (n, l) in levels().iter().enumerate() {
            assert_eq!(l.items.len(), PER_LEVEL, "level {}", n + 1);
            let sound = l.items.iter().filter(|&&i| bank().items[i].technique == SAGLAM).count();
            assert!(sound >= 2, "level {} has {sound} sound messages", n + 1);
        }
    }

    #[test]
    fn answer_positions_are_balanced_per_level() {
        for (n, l) in levels().iter().enumerate() {
            let mut c = [0; 4];
            for &i in &l.items {
                c[bank().items[i].answer] += 1;
            }
            assert!(c.iter().all(|&x| (2..=3).contains(&x)), "level {}: {c:?}", n + 1);
        }
    }

    #[test]
    fn correct_option_is_not_given_away_by_length() {
        for it in &bank().items {
            let right = it.options[it.answer].chars().count() as f64;
            let others: f64 = (0..4).filter(|&k| k != it.answer).map(|k| it.options[k].chars().count() as f64).sum::<f64>() / 3.0;
            let r = right / others;
            assert!((0.6..=1.45).contains(&r), "{}: ratio {r:.2}", it.id);
        }
    }

    fn play(g: &mut ZihinAsisi, right: usize) {
        if g.phase == Phase::Intro {
            g.act(&json!({"start": true})).unwrap();
        }
        let n = g.order.len();
        for k in 0..n {
            let a = g.item().answer;
            let pick = if k < right { a } else { (a + 1) % 4 };
            g.act(&json!({"answer": pick})).unwrap();
            if g.status != "playing" {
                break;
            }
            g.act(&json!({"next": true})).unwrap();
        }
    }

    #[test]
    fn a_level_scores_by_correct_answers() {
        let mut g = ZihinAsisi::level(1);
        assert_eq!(g.state()["phase"], "intro");
        assert!(g.state()["intro"]["name"].is_string());
        play(&mut g, 10);
        assert_eq!(g.state()["status"], "won");
        assert_eq!(g.state()["stars"], 3);
        let mut g = ZihinAsisi::level(1);
        play(&mut g, 6);
        assert_eq!(g.state()["status"], "lost");
        assert_eq!(g.state()["stars"], 0);
    }

    #[test]
    fn answers_are_refused_during_the_intro() {
        let mut g = ZihinAsisi::level(1);
        assert!(g.act(&json!({"answer": 0})).is_err());
    }

    #[test]
    fn endless_ends_on_the_third_mistake() {
        let mut g = ZihinAsisi::endless(7);
        assert_eq!(g.state()["phase"], "question");
        for _ in 0..3 {
            let a = g.item().answer;
            g.act(&json!({"answer": (a + 1) % 4})).unwrap();
            let _ = g.act(&json!({"next": true}));
        }
        assert_eq!(g.state()["status"], "lost");
    }

    #[test]
    fn the_game_is_registered() {
        assert!(crate::games::GAME_IDS.contains(&"zihin_asisi"));
    }
}
