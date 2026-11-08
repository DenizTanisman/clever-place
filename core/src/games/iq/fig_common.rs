//! Shared vocabulary for the figural generators: shapes, fills, cell layouts, JSON builders, the
//! option shuffler and the balanced ("attribute-bisection") option builder.

use crate::games::iq::item::{IqItem, IqOption};
use crate::rng::Rng;
use serde_json::{json, Value};

/// Round to 3 decimals so equal geometry always serialises to equal JSON.
pub fn f3(x: f64) -> f64 {
    let r = (x * 1000.0).round() / 1000.0;
    if r == 0.0 {
        0.0
    } else {
        r
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Hash, PartialOrd, Ord)]
pub enum Shape {
    Circle,
    Triangle,
    Square,
    Pentagon,
    Hexagon,
    Heptagon,
    Octagon,
    Diamond,
    Star,
    Cross,
    Arrow,
}

pub const ALL_SHAPES: [Shape; 11] = [
    Shape::Circle,
    Shape::Triangle,
    Shape::Square,
    Shape::Pentagon,
    Shape::Hexagon,
    Shape::Heptagon,
    Shape::Octagon,
    Shape::Diamond,
    Shape::Star,
    Shape::Cross,
    Shape::Arrow,
];

/// Shapes that read clearly as "different" at small sizes (no heptagon/octagon look-alikes).
pub const BASIC_SHAPES: [Shape; 7] = [
    Shape::Circle,
    Shape::Triangle,
    Shape::Square,
    Shape::Diamond,
    Shape::Hexagon,
    Shape::Star,
    Shape::Cross,
];

impl Shape {
    pub fn id(self) -> &'static str {
        match self {
            Shape::Circle => "circle",
            Shape::Triangle => "triangle",
            Shape::Square => "square",
            Shape::Pentagon => "pentagon",
            Shape::Hexagon => "hexagon",
            Shape::Heptagon => "heptagon",
            Shape::Octagon => "octagon",
            Shape::Diamond => "diamond",
            Shape::Star => "star",
            Shape::Cross => "cross",
            Shape::Arrow => "arrow",
        }
    }
    pub fn from_id(s: &str) -> Option<Shape> {
        ALL_SHAPES.iter().copied().find(|x| x.id() == s)
    }
    /// Turkish name (nominative).
    pub fn tr(self) -> &'static str {
        match self {
            Shape::Circle => "daire",
            Shape::Triangle => "üçgen",
            Shape::Square => "kare",
            Shape::Pentagon => "beşgen",
            Shape::Hexagon => "altıgen",
            Shape::Heptagon => "yedigen",
            Shape::Octagon => "sekizgen",
            Shape::Diamond => "eşkenar dörtgen",
            Shape::Star => "yıldız",
            Shape::Cross => "artı",
            Shape::Arrow => "ok",
        }
    }
    /// Side count of the regular polygons (the square and diamond count as 4).
    pub fn sides(self) -> Option<i64> {
        match self {
            Shape::Triangle => Some(3),
            Shape::Square | Shape::Diamond => Some(4),
            Shape::Pentagon => Some(5),
            Shape::Hexagon => Some(6),
            Shape::Heptagon => Some(7),
            Shape::Octagon => Some(8),
            _ => None,
        }
    }
    pub fn polygon(sides: i64) -> Option<Shape> {
        match sides {
            3 => Some(Shape::Triangle),
            4 => Some(Shape::Square),
            5 => Some(Shape::Pentagon),
            6 => Some(Shape::Hexagon),
            7 => Some(Shape::Heptagon),
            8 => Some(Shape::Octagon),
            _ => None,
        }
    }
    /// Rotational symmetry period in degrees (360 = no symmetry).
    pub fn period(self) -> i64 {
        match self {
            Shape::Circle => 1,
            Shape::Triangle => 120,
            Shape::Square | Shape::Cross => 90,
            Shape::Diamond => 180, // drawn narrower than a square
            Shape::Pentagon | Shape::Star => 72,
            Shape::Hexagon => 60,
            Shape::Heptagon => 360, // 51.43° is not an integer: keep raw angles
            Shape::Octagon => 45,
            Shape::Arrow => 360,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Hash, PartialOrd, Ord)]
pub enum Fill {
    None,
    Solid,
    Stripes,
    Dots,
    Half,
}

pub const FILLS: [Fill; 5] = [Fill::None, Fill::Solid, Fill::Stripes, Fill::Dots, Fill::Half];

impl Fill {
    pub fn id(self) -> &'static str {
        match self {
            Fill::None => "none",
            Fill::Solid => "solid",
            Fill::Stripes => "stripes",
            Fill::Dots => "dots",
            Fill::Half => "half",
        }
    }
    pub fn from_id(s: &str) -> Option<Fill> {
        FILLS.iter().copied().find(|x| x.id() == s)
    }
    pub fn tr(self) -> &'static str {
        match self {
            Fill::None => "boş",
            Fill::Solid => "dolu",
            Fill::Stripes => "çizgili",
            Fill::Dots => "noktalı",
            Fill::Half => "yarım dolu",
        }
    }
}

/// Normalised rotation for drawing: symmetric shapes collapse equivalent angles so that two
/// visually identical figures always serialise identically. A half fill breaks the symmetry.
pub fn norm_rot(s: Shape, fill: Fill, rot: i64) -> i64 {
    let r = rot.rem_euclid(360);
    if fill == Fill::Half {
        return r;
    }
    let p = s.period();
    if p == 1 {
        0
    } else {
        r % p
    }
}

/// One shape primitive. `x`, `y` in cell units (0..1, y down), `r` circumradius in cell units,
/// `rot` degrees clockwise.
pub fn shape_item(s: Shape, x: f64, y: f64, r: f64, rot: i64, fill: Fill) -> Value {
    json!({
        "s": s.id(),
        "x": f3(x),
        "y": f3(y),
        "r": f3(r),
        "rot": norm_rot(s, fill, rot),
        "f": fill.id(),
    })
}

pub fn line_item(x1: f64, y1: f64, x2: f64, y2: f64) -> Value {
    json!({ "s": "line", "x1": f3(x1), "y1": f3(y1), "x2": f3(x2), "y2": f3(y2) })
}

pub fn cell(items: Vec<Value>) -> Value {
    json!({ "k": "cell", "w": 1, "h": 1, "items": items })
}

pub fn q_cell() -> Value {
    json!({ "k": "q", "w": 1, "h": 1 })
}

pub fn sep(t: &str) -> Value {
    json!({ "k": "sep", "t": t })
}

/// A rows×cols grid of sub-figures (row-major). `colw` gives per-column widths in units.
pub fn grid(rows: usize, cols: usize, cells: Vec<Value>, colw: Option<Vec<f64>>) -> Value {
    assert_eq!(cells.len(), rows * cols);
    let w: f64 = match &colw {
        Some(c) => c.iter().sum(),
        None => cols as f64,
    };
    let mut g = json!({ "k": "grid", "rows": rows, "cols": cols, "w": f3(w), "h": rows, "cells": cells });
    if let Some(c) = colw {
        g["colw"] = json!(c);
    }
    g
}

/// Positions for `n` equal items in a unit cell.
pub fn layout(n: usize) -> Vec<(f64, f64)> {
    match n {
        1 => vec![(0.5, 0.5)],
        2 => vec![(0.3, 0.5), (0.7, 0.5)],
        3 => vec![(0.5, 0.28), (0.27, 0.7), (0.73, 0.7)],
        4 => vec![(0.3, 0.3), (0.7, 0.3), (0.3, 0.7), (0.7, 0.7)],
        5 => vec![(0.25, 0.25), (0.75, 0.25), (0.5, 0.5), (0.25, 0.75), (0.75, 0.75)],
        6 => vec![(0.22, 0.3), (0.5, 0.3), (0.78, 0.3), (0.22, 0.7), (0.5, 0.7), (0.78, 0.7)],
        7 => vec![
            (0.22, 0.2),
            (0.5, 0.2),
            (0.78, 0.2),
            (0.5, 0.5),
            (0.22, 0.8),
            (0.5, 0.8),
            (0.78, 0.8),
        ],
        8 => vec![
            (0.2, 0.25),
            (0.4, 0.25),
            (0.6, 0.25),
            (0.8, 0.25),
            (0.2, 0.75),
            (0.4, 0.75),
            (0.6, 0.75),
            (0.8, 0.75),
        ],
        _ => panic!("layout for {n}"),
    }
}

/// Circumradius for `n` items of the given size step (0 small, 1 medium, 2 large).
pub fn count_radius(n: usize, size: i64) -> f64 {
    let base = match n {
        1 => 0.34,
        2 => 0.18,
        3 => 0.17,
        4 => 0.16,
        5 => 0.14,
        6 => 0.12,
        _ => 0.1,
    };
    base * [0.55, 0.78, 1.0][size.clamp(0, 2) as usize]
}

/// `n` identical shapes laid out in a cell.
pub fn group_items(s: Shape, n: usize, fill: Fill, rot: i64, size: i64) -> Vec<Value> {
    let r = count_radius(n, size);
    layout(n).into_iter().map(|(x, y)| shape_item(s, x, y, r, rot, fill)).collect()
}

/// Phone readability: a pattern fill (stripes, dots, half) inside a star or a cross is too thin
/// to read at option size. True when no such item occurs anywhere in `v`.
pub fn readable(v: &Value) -> bool {
    match v {
        Value::Object(m) => {
            let thin = matches!(m.get("s").and_then(|x| x.as_str()), Some("star") | Some("cross"));
            let pattern = matches!(m.get("f").and_then(|x| x.as_str()), Some("stripes") | Some("dots") | Some("half"));
            !(thin && pattern) && m.values().all(readable)
        }
        Value::Array(a) => a.iter().all(readable),
        _ => true,
    }
}

/// `readable` over a question figure and all its options.
pub fn item_readable(figure: &Option<Value>, opts: &[IqOption]) -> bool {
    figure.as_ref().is_none_or(readable) && opts.iter().all(|o| readable(&o.to_json()))
}

/// Canonical string of an option (pairwise identity check).
pub fn opt_key(o: &IqOption) -> String {
    o.to_json().to_string()
}

/// Shuffle the correct option in among the distractors and build the item. Panics if two options
/// are identical (generators must filter before calling).
#[allow(clippy::too_many_arguments)]
pub fn finish(
    rng: &mut Rng,
    cat: &'static str,
    hard: bool,
    prompt: String,
    figure: Option<Value>,
    correct: IqOption,
    distractors: Vec<IqOption>,
    why: String,
) -> IqItem {
    let mut opts: Vec<(bool, IqOption)> = vec![(true, correct)];
    opts.extend(distractors.into_iter().map(|d| (false, d)));
    rng.shuffle(&mut opts);
    let answer = opts.iter().position(|(c, _)| *c).unwrap();
    let options: Vec<IqOption> = opts.into_iter().map(|(_, o)| o).collect();
    IqItem { cat, hard, prompt, figure, options, answer, typed: None, why }
}

/// True when all options are pairwise different.
pub fn all_distinct(opts: &[IqOption]) -> bool {
    let keys: Vec<String> = opts.iter().map(opt_key).collect();
    for i in 0..keys.len() {
        for j in i + 1..keys.len() {
            if keys[i] == keys[j] {
                return false;
            }
        }
    }
    true
}

/// Balanced option combinations (I-RAVEN style). `sizes[i]` is the number of values offered for
/// attribute i (value 0 = the correct one). Returns index tuples, the first being all zeros.
/// Supported shapes keep every attribute value equally frequent: products of up to 6, or
/// 2×2×2 minus one complementary pair (6).
pub fn balanced_combos(rng: &mut Rng, sizes: &[usize]) -> Vec<Vec<usize>> {
    let mut all: Vec<Vec<usize>> = vec![vec![]];
    for &s in sizes {
        let mut next = vec![];
        for a in &all {
            for v in 0..s {
                let mut b = a.clone();
                b.push(v);
                next.push(b);
            }
        }
        all = next;
    }
    if all.len() > 6 {
        assert!(sizes.iter().all(|&s| s == 2) && sizes.len() == 3, "unsupported {sizes:?}");
        // Drop a complementary pair that does not contain the answer (0,0,0) or its complement.
        let pairs: Vec<(Vec<usize>, Vec<usize>)> = all
            .iter()
            .filter(|c| c[0] == 0 && c.iter().any(|&v| v == 1))
            .map(|c| (c.clone(), c.iter().map(|v| 1 - v).collect()))
            .collect();
        let (x, y) = pairs[rng.below(pairs.len())].clone();
        all.retain(|c| *c != x && *c != y);
    }
    all
}

/// Comma list in Turkish: "a, b ve c".
pub fn tr_list(xs: &[String]) -> String {
    match xs.len() {
        0 => String::new(),
        1 => xs[0].clone(),
        n => format!("{} ve {}", xs[..n - 1].join(", "), xs[n - 1]),
    }
}

// ---------------------------------------------------------------- parsing helpers for oracles

pub fn num(v: &Value, k: &str) -> f64 {
    v[k].as_f64().unwrap_or(f64::NAN)
}

pub fn items(cell: &Value) -> Vec<Value> {
    cell["items"].as_array().cloned().unwrap_or_default()
}

/// Option's figure JSON (panics on text options; oracles only call it on figure categories).
pub fn opt_fig(o: &IqOption) -> &Value {
    match o {
        IqOption::Figure(v) => v,
        IqOption::Text(_) => panic!("text option in a figure category"),
    }
}

pub fn opt_text(o: &IqOption) -> &str {
    match o {
        IqOption::Text(t) => t,
        IqOption::Figure(_) => panic!("figure option in a text category"),
    }
}

/// Exactly-one helper for oracles: returns the single index where `ok` holds.
pub fn unique_index(ok: &[bool]) -> Result<usize, String> {
    let hits: Vec<usize> = ok.iter().enumerate().filter(|(_, &b)| b).map(|(i, _)| i).collect();
    match hits.len() {
        1 => Ok(hits[0]),
        0 => Err("no option satisfies the rules".into()),
        _ => Err(format!("several options satisfy the rules: {hits:?}")),
    }
}
