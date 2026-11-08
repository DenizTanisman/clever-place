//! Figural IQ categories: 11 generators, each with an independent uniqueness oracle.
//! Category notes live at the top of each `fig_*.rs`; the research is in
//! docs/research/iq_question_types.md. Painter: app/lib/clever/games/iq_figure.dart.
//!
//! # Figure JSON
//! Every figure is an object with a kind `k` and its extent `w`, `h` in option units (every
//! option figure is 1×1; a 3×3 matrix is 3×3), so the view can draw everything at one scale:
//! `size = w × unitPx`. Coordinates are y-down. Kinds:
//!
//! * `cell` `{items}` — one frame, items in 0..1 cell coordinates:
//!   - shape `{s, x, y, r, rot, f, c?, ko?, m?}`: `s` ∈ circle, triangle, square, pentagon,
//!     hexagon, heptagon, octagon, diamond, star, cross, arrow (arrow points up at rot 0); `r`
//!     circumradius; `rot` degrees clockwise (normalised by the shape's symmetry so equal
//!     pictures serialise equally); `f` fill ∈ none, solid, stripes, dots, half (left half in the
//!     shape's frame); `c` "gold" (default ivory); `ko` knock out what is underneath (nested
//!     inner shapes, shapes over spokes); `m` marker (the series' corner dot).
//!   - line `{s:"line", x1, y1, x2, y2}` (matrix spokes).
//! * `q` — the "?" cell; `sep` `{t}` — a separator ("→" is drawn as an arrow).
//! * `grid` `{rows, cols, cells, colw?}` — row-major sub-figures (matrix 3×3, series 1×n,
//!   analogy 2×3 with "→" columns of width 0.5, cube views 1×2).
//! * `cube` `{top, front, right}` — isometric cube; faces `{sym, rot}`; sym ∈ dot, ring, square,
//!   plus, target, diamond, dots4 (4-fold symmetric, rot 0) or arrow, triangle, half, corner
//!   (oriented: rot = quarter turns clockwise from the face's up — the back edge for the top
//!   face, the top edge for the side faces).
//! * `net` `{cols, rows, cells:[{x, y, sym, rot}]}` — a cube net (rot clockwise from net-up).
//! * `fold` `{n, panels}` — n×n sheet: fold panels `{poly, line, arrow}` (paper outline, fold
//!   line endpoints, arrow from the moving part to where it lands), then `{poly, holes, punch}`.
//! * `sheet` `{n, holes}` — an unfolded sheet with holes at cell centres.
//! * `stack` `{dims:[W, D, H], cubes:[[x, y, z]], ask}` — unit cubes on a W×D floor plate
//!   (x right-down, y right-up, z up); `ask` ∈ count, fill (fill to a W×D×H box).
//! * `sticks` `{vw, vh, sticks:[[x1, y1, x2, y2]], slots, moves}` — matchsticks (head at x2, y2)
//!   in a vw×vh box; `slots` (seven-segment masks) and `moves` are for the oracle.
//! * `poly` `{n, cells:[[x, y]], abs?, ops?}` — a polyomino in an n×n frame, centred unless
//!   `abs`; `ops` lists the transformation steps of a hard mental-rotation item.
//! * `assembly` `{target, pieces:[{t, cells}], flip, n, tn}` — target above six labelled pieces.
//!
//! Options are `IqOption::Figure` (cells, cubes, sheets, polys) or `IqOption::Text` (block
//! counts, matchstick equations, assembly triples). `odd_shape` has no question figure.
//! The generators may return the answer at any position (the session reorders options).

#[path = "fig_common.rs"]
mod fig_common;
#[path = "fig_matrix.rs"]
mod fig_matrix;
#[path = "fig_rules.rs"]
mod fig_rules;
#[path = "fig_series.rs"]
mod fig_series;
#[path = "fig_analogy.rs"]
mod fig_analogy;
#[path = "fig_poly.rs"]
mod fig_poly;
#[path = "fig_odd.rs"]
mod fig_odd;
#[path = "fig_cube.rs"]
mod fig_cube;
#[path = "fig_fold.rs"]
mod fig_fold;
#[path = "fig_blocks.rs"]
mod fig_blocks;
#[path = "fig_match.rs"]
mod fig_match;

use super::item::{IqGen, IqItem};

/// (category id, Turkish name, generator).
pub const FIGURAL: &[(&str, &str, IqGen)] = &[
    ("matrix", "Matris", fig_matrix::generate),
    ("shape_series", "Şekil dizisi", fig_series::generate),
    ("cube_rotation", "Küp döndürme", fig_cube::generate_rotation),
    ("figure_analogy", "Şekil analojisi", fig_analogy::generate),
    ("odd_shape", "Farklı şekli bul", fig_odd::generate),
    ("cube_net", "Küp açınımı", fig_cube::generate_net),
    ("paper_fold", "Kâğıt katlama", fig_fold::generate),
    ("block_count", "Blok sayma", fig_blocks::generate),
    ("matchstick", "Kibrit çöpü", fig_match::generate),
    ("mental_rotation", "Döndürme / ayna", fig_poly::generate_rotation),
    ("assembly", "Parça birleştirme", fig_poly::generate_assembly),
];

/// Independent checker: the single option that satisfies the category's rule set, computed
/// from the item's JSON alone (Err when none or several do).
pub type Oracle = fn(&IqItem) -> Result<usize, String>;

/// One oracle per category id. If the session moves the correct option, it can re-check with
/// these.
pub const ORACLES: &[(&str, Oracle)] = &[
    ("matrix", fig_matrix::oracle),
    ("shape_series", fig_series::oracle),
    ("figure_analogy", fig_analogy::oracle),
    ("odd_shape", fig_odd::oracle),
    ("cube_rotation", fig_cube::rotation_oracle),
    ("cube_net", fig_cube::net_oracle),
    ("paper_fold", fig_fold::oracle),
    ("block_count", fig_blocks::oracle),
    ("matchstick", fig_match::oracle),
    ("mental_rotation", fig_poly::rotation_oracle),
    ("assembly", fig_poly::assembly_oracle),
];

#[cfg(test)]
#[path = "fig_tests.rs"]
mod tests;
