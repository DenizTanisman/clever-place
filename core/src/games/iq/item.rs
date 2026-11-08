//! Shared contract for the IQ-style puzzle game (`iq`). Both the text/number generators
//! (`iq/*.rs`, owned by the game module) and the figural generators (`iq/figural.rs`) produce
//! `IqItem`s; the session in `iq/mod.rs` sequences them.
//!
//! Figures are opaque JSON here: their schema belongs to `figural.rs` and its painter
//! `app/lib/clever/games/iq_figure.dart` (`IqFigure(json)`), documented at the top of both.

use crate::rng::Rng;
use serde_json::{json, Value};

/// One answer option: a short text (number, word, expression) or a figure.
#[derive(Clone, Debug, PartialEq)]
pub enum IqOption {
    Text(String),
    Figure(Value),
}

impl IqOption {
    pub fn to_json(&self) -> Value {
        match self {
            IqOption::Text(t) => json!({ "text": t }),
            IqOption::Figure(f) => json!({ "figure": f }),
        }
    }
}

/// One question. `options` holds 4–6 choices (or is empty for typed answers, see `typed`);
/// `answer` is the index of the single correct option.
#[derive(Clone, Debug)]
pub struct IqItem {
    /// Category id, e.g. "matrix", "number_series" (see `CATEGORIES` in iq/mod.rs).
    pub cat: &'static str,
    pub hard: bool,
    /// Turkish question text, short ("Soru işaretinin yerine hangisi gelmeli?").
    pub prompt: String,
    /// Question figure (grid, sequence, cube, matchsticks …), if any.
    pub figure: Option<Value>,
    pub options: Vec<IqOption>,
    pub answer: usize,
    /// Typed numeric answer instead of options (e.g. some missing-number items): the correct value.
    pub typed: Option<i64>,
    /// Turkish explanation of the rule, shown after answering.
    pub why: String,
}

/// A category generator: deterministic from `rng`; `hard` picks the hard parameter set.
/// Must guarantee exactly one correct option under its declared rule set (checked by its oracle).
pub type IqGen = fn(&mut Rng, bool) -> IqItem;
