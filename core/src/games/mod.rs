//! Game registry. Each game lives in its own module and exposes
//! `pub fn create(level: u32, mode: &str) -> Result<Box<dyn Session>, String>`.

use crate::Session;

pub mod batak;
pub mod blackjack;
pub mod block_grid;
pub mod blof;
pub mod change_spot;
pub mod color_gates;
pub mod corridor;
pub mod corsi;
pub mod crowns;
pub mod digit_span;
pub mod falling_blocks;
pub mod gem_merge;
pub mod gonogo;
pub mod hanoi;
pub mod iq;
pub mod math;
pub mod morris;
pub mod nback;
pub mod okey;
pub mod okey101;
pub mod pairs;
pub mod palace;
pub mod push;
pub mod rsvp;
pub mod scene;
pub mod scene_quiz;
pub mod schulte;
pub mod shikaku;
pub mod soroban;
pub mod stroop;
pub mod sudoku;
pub mod sun_moon;
pub mod surakarta;
pub mod task_switch;
pub mod tracking;
pub mod trail;
pub mod verbal_social;
pub mod water_sort;
pub mod word_list;

/// Every game id the core knows.
pub const GAME_IDS: &[&str] = &[
    "hanoi", "sudoku", "water_sort", "crowns", "sun_moon", "shikaku", "gem_merge",
    "falling_blocks", "block_grid", "math", "nback", "morris", "surakarta",
    "schulte", "stroop", "tracking", "gonogo", "color_gates", "palace", "digit_span", "corsi", "pairs",
    "corridor", "push", "soroban", "task_switch", "trail", "rsvp", "change_spot", "scene_quiz", "word_list",
    "batak", "okey", "blof", "blackjack", "iq",
    "verbal_social",
];

pub fn create(game: &str, level: u32, mode: &str) -> Result<Box<dyn Session>, String> {
    match game {
        "hanoi" => Ok(Box::new(hanoi::Hanoi::new(level))),
        "sudoku" => sudoku::create(level, mode),
        "water_sort" => water_sort::create(level, mode),
        "crowns" => crowns::create(level, mode),
        "sun_moon" => sun_moon::create(level, mode),
        "shikaku" => shikaku::create(level, mode),
        "gem_merge" => gem_merge::create(level, mode),
        "falling_blocks" => falling_blocks::create(level, mode),
        "block_grid" => block_grid::create(level, mode),
        "math" => math::create(level, mode),
        "nback" => nback::create(level, mode),
        "morris" => morris::create(level, mode),
        "surakarta" => surakarta::create(level, mode),
        "schulte" => schulte::create(level, mode),
        "stroop" => stroop::create(level, mode),
        "tracking" => tracking::create(level, mode),
        "gonogo" => gonogo::create(level, mode),
        "color_gates" => color_gates::create(level, mode),
        "palace" => palace::create(level, mode),
        "digit_span" => digit_span::create(level, mode),
        "corsi" => corsi::create(level, mode),
        "pairs" => pairs::create(level, mode),
        "corridor" => corridor::create(level, mode),
        "push" => push::create(level, mode),
        "soroban" => soroban::create(level, mode),
        "task_switch" => task_switch::create(level, mode),
        "trail" => trail::create(level, mode),
        "rsvp" => rsvp::create(level, mode),
        "change_spot" => change_spot::create(level, mode),
        "scene_quiz" => scene_quiz::create(level, mode),
        "word_list" => word_list::create(level, mode),
        "batak" => batak::create(level, mode),
        "okey" => okey::create(level, mode),
        "blof" => blof::create(level, mode),
        "blackjack" => blackjack::create(level, mode),
        "iq" => iq::create(level, mode),
        "verbal_social" => verbal_social::create(level, mode),
        _ => Err(format!("unknown game: {game}")),
    }
}
