//! `shape_series`: a row of figures changing step by step; pick the next one.
//!
//! Each frame is an attribute vector: a single main shape (sides, rotation, fill) with an optional
//! corner dot, or a group of small shapes (count, shape, fill). Medium: 1–2 attributes change with
//! simple steps over 4 frames. Hard: 2–3 attributes with different periods (rotation period 8,
//! corner period 4, fill period 2/3, some backwards) over 5 frames.
//!
//! Oracle: parse the frames back to attributes and run the sequence grammar of
//! `fig_rules::series_predict` (constant, arithmetic, modular, periodic 2–3, second order,
//! geometric, interleaved) per attribute; exactly one option may fit every attribute.

use super::fig_common::*;
use super::fig_rules::*;
use crate::games::iq::item::{IqItem, IqOption};
use crate::rng::Rng;
use serde_json::{json, Value};

pub const CORNERS: [(f64, f64); 4] = [(0.15, 0.15), (0.85, 0.15), (0.85, 0.85), (0.15, 0.85)];
const SFILLS: [Fill; 4] = [Fill::None, Fill::Solid, Fill::Stripes, Fill::Dots];
const GSHAPES: [Shape; 6] = [Shape::Circle, Shape::Square, Shape::Triangle, Shape::Star, Shape::Diamond, Shape::Cross];

#[derive(Clone, Copy, PartialEq, Debug)]
pub struct Frame {
    pub group: bool,
    pub shape: Shape,
    pub fill: Fill,
    pub rot: i64, // degrees
    pub count: i64,
    pub corner: i64, // -1 = none
}

pub fn render(f: &Frame) -> Value {
    let mut its = if f.group {
        group_items(f.shape, f.count as usize, f.fill, f.rot, 1)
    } else {
        vec![shape_item(f.shape, 0.5, 0.5, 0.3, f.rot, f.fill)]
    };
    if f.corner >= 0 {
        let (x, y) = CORNERS[f.corner as usize];
        let mut m = shape_item(Shape::Circle, x, y, 0.07, 0, Fill::Solid);
        m["m"] = json!(true);
        m["c"] = json!("gold");
        its.push(m);
    }
    cell(its)
}

// ------------------------------------------------------------------------------------- oracle

/// Parsed attributes: [shape, sides, rot step, fill, count, corner].
fn parse(v: &Value) -> Result<[i64; 6], String> {
    if v["k"] != "cell" {
        return Err("not a cell".into());
    }
    let its = items(v);
    let mains: Vec<&Value> = its.iter().filter(|i| i["m"] != true).collect();
    let marks: Vec<&Value> = its.iter().filter(|i| i["m"] == true).collect();
    let f = mains.first().ok_or("empty frame")?;
    let shape = Shape::from_id(f["s"].as_str().unwrap_or("")).ok_or("bad shape")?;
    let fill = Fill::from_id(f["f"].as_str().unwrap_or("")).ok_or("bad fill")?;
    for m in &mains {
        if m["s"] != f["s"] || m["f"] != f["f"] || m["rot"] != f["rot"] {
            return Err("mixed frame".into());
        }
    }
    let rot = f["rot"].as_i64().ok_or("rot")?;
    if rot % 45 != 0 {
        return Err("rotation off the 45° grid".into());
    }
    let corner = match marks.first() {
        None => 4,
        Some(m) => {
            let (x, y) = (num(m, "x"), num(m, "y"));
            CORNERS.iter().position(|&(a, b)| (a - x).abs() < 1e-6 && (b - y).abs() < 1e-6).ok_or("marker off a corner")? as i64
        }
    };
    Ok([
        ALL_SHAPES.iter().position(|&s| s == shape).unwrap() as i64,
        shape.sides().unwrap_or(0),
        rot / 45,
        FILLS.iter().position(|&x| x == fill).unwrap() as i64,
        mains.len() as i64,
        corner,
    ])
}

pub fn oracle(item: &IqItem) -> Result<usize, String> {
    let fig = item.figure.as_ref().ok_or("no figure")?;
    let cells = fig["cells"].as_array().ok_or("no cells")?;
    let (last, given) = cells.split_last().ok_or("empty")?;
    if last["k"] != "q" || given.len() < 3 {
        return Err("expected frames then ?".into());
    }
    let seq: Vec<[i64; 6]> = given.iter().map(parse).collect::<Result<_, _>>()?;
    let opts: Vec<[i64; 6]> = item.options.iter().map(|o| parse(opt_fig(o))).collect::<Result<_, _>>()?;
    let any_unmarked = seq.iter().chain(&opts).any(|a| a[5] == 4);
    let kinds = [
        AKind::Cat,
        AKind::Num(0, 8),
        AKind::Cyc(8),
        AKind::Cat,
        AKind::Num(1, 8),
        if any_unmarked { AKind::Cat } else { AKind::Cyc(4) },
    ];
    let mut ok = vec![true; opts.len()];
    for (a, &k) in kinds.iter().enumerate() {
        let v: Vec<i64> = seq.iter().map(|s| s[a]).collect();
        let p = series_predict(&v, k);
        for (i, o) in opts.iter().enumerate() {
            if !fits(&p, o[a]) {
                ok[i] = false;
            }
        }
    }
    if !all_distinct(&item.options) {
        return Err("duplicate options".into());
    }
    unique_index(&ok)
}

// ---------------------------------------------------------------------------------- generator

#[derive(Clone, Copy, PartialEq, Debug)]
enum Rule {
    /// rotation step in 45° units
    Rot(i64),
    /// side count step
    Sides(i64),
    /// group count step
    Count(i64),
    /// corner step
    Corner(i64),
    /// fill cycle of length p (2 or 3)
    FillCycle(usize),
    /// group shape cycle of length p
    ShapeCycle(usize),
}

fn frames(rule_set: &[Rule], start: Frame, n: usize, fills: &[Fill], shapes: &[Shape]) -> Vec<Frame> {
    (0..n as i64)
        .map(|i| {
            let mut f = start;
            for r in rule_set {
                match *r {
                    Rule::Rot(k) => f.rot = (start.rot + 45 * k * i).rem_euclid(360),
                    Rule::Sides(d) => f.shape = Shape::polygon(start.shape.sides().unwrap() + d * i).unwrap_or(Shape::Circle),
                    Rule::Count(d) => f.count = start.count + d * i,
                    Rule::Corner(d) => f.corner = (start.corner + d * i).rem_euclid(4),
                    Rule::FillCycle(p) => f.fill = fills[i as usize % p],
                    Rule::ShapeCycle(p) => f.shape = shapes[i as usize % p],
                }
            }
            f
        })
        .collect()
}

fn valid(f: &Frame) -> bool {
    if f.group {
        (1..=8).contains(&f.count)
    } else {
        f.shape != Shape::Circle
    }
}

fn wrong_frames(rng: &mut Rng, r: Rule, seq: &[Frame], next: &Frame, fills: &[Fill], shapes: &[Shape]) -> Vec<Frame> {
    let last = seq[seq.len() - 1];
    let mut v: Vec<Frame> = vec![];
    let mut w = |g: &dyn Fn(&mut Frame)| {
        let mut f = *next;
        g(&mut f);
        v.push(f);
    };
    match r {
        Rule::Rot(k) => {
            w(&|f| f.rot = last.rot);
            w(&|f| f.rot = (next.rot + 45 * k).rem_euclid(360));
            w(&|f| f.rot = (last.rot - 45 * k).rem_euclid(360));
            w(&|f| f.rot = (next.rot + 180).rem_euclid(360));
            w(&|f| f.rot = (next.rot + 90).rem_euclid(360));
        }
        Rule::Sides(d) => {
            w(&|f| f.shape = last.shape);
            for dd in [d, -2 * d, 2 * d] {
                if let Some(s) = next.shape.sides().and_then(|s| Shape::polygon(s + dd)) {
                    w(&|f| f.shape = s);
                }
            }
        }
        Rule::Count(d) => {
            w(&|f| f.count = last.count);
            w(&|f| f.count = next.count + d);
            w(&|f| f.count = next.count + d.signum());
            w(&|f| f.count = next.count - 2 * d);
        }
        Rule::Corner(d) => {
            w(&|f| f.corner = last.corner);
            w(&|f| f.corner = (next.corner + 2).rem_euclid(4));
            w(&|f| f.corner = (last.corner - d).rem_euclid(4));
            w(&|f| f.corner = (next.corner + d).rem_euclid(4));
        }
        Rule::FillCycle(p) => {
            w(&|f| f.fill = last.fill);
            for &x in fills.iter().take(p) {
                w(&|f| f.fill = x);
            }
            for &x in SFILLS.iter() {
                w(&|f| f.fill = x);
            }
        }
        Rule::ShapeCycle(p) => {
            w(&|f| f.shape = last.shape);
            for &x in shapes.iter().take(p) {
                w(&|f| f.shape = x);
            }
            for &x in GSHAPES.iter() {
                w(&|f| f.shape = x);
            }
        }
    }
    let _ = rng;
    let mut out: Vec<Frame> = vec![];
    for f in v {
        if f != *next && valid(&f) && !out.contains(&f) {
            out.push(f);
        }
    }
    out
}

fn dir_word(d: i64) -> &'static str {
    if d > 0 {
        "saat yönünde"
    } else {
        "saatin tersi yönünde"
    }
}

fn describe(r: Rule, fills: &[Fill], shapes: &[Shape]) -> String {
    match r {
        Rule::Rot(k) => format!("Ok her adımda {}° {} dönüyor.", 45 * k.abs(), dir_word(k)),
        Rule::Sides(d) => format!("Kenar sayısı her adımda 1 {}.", if d > 0 { "artıyor" } else { "azalıyor" }),
        Rule::Count(d) => format!("Şekil sayısı her adımda {} {}.", d.abs(), if d > 0 { "artıyor" } else { "azalıyor" }),
        Rule::Corner(d) => format!(
            "Altın nokta her adımda {} köşe {} ilerliyor.",
            ["", "bir", "iki", "üç"][d.unsigned_abs() as usize],
            dir_word(d)
        ),
        Rule::FillCycle(p) => {
            let names: Vec<String> = fills.iter().take(p).map(|f| f.tr().to_string()).collect();
            format!("Dolgu {} sırasıyla tekrarlanıyor.", names.join(", "))
        }
        Rule::ShapeCycle(p) => {
            let names: Vec<String> = shapes.iter().take(p).map(|s| s.tr().to_string()).collect();
            format!("Şekiller {} sırasıyla tekrarlanıyor.", names.join(", "))
        }
    }
}

fn try_gen(rng: &mut Rng, hard: bool) -> Option<IqItem> {
    let n = if hard { 5 } else { 4 };
    let mut fills = SFILLS.to_vec();
    rng.shuffle(&mut fills);
    let mut shapes = GSHAPES.to_vec();
    rng.shuffle(&mut shapes);
    let step = |rng: &mut Rng, opts: &[i64]| *rng.pick(opts) * if rng.chance(0.5) { 1 } else { -1 };
    // Template: arrow (rotation), polygon (sides) or group (count).
    let t = rng.below(3);
    let mut start = Frame { group: false, shape: Shape::Arrow, fill: fills[0], rot: 0, count: 1, corner: -1 };
    let mut rules: Vec<Rule> = vec![];
    match t {
        0 => {
            start.rot = 45 * rng.range(0, 7);
            rules.push(Rule::Rot(step(rng, if hard { &[1, 2, 3] } else { &[1, 2] })));
        }
        1 => {
            let d = if hard && rng.chance(0.4) { -1 } else { 1 };
            let max_s = if hard { 8 } else { 7 };
            let s0 = if d > 0 { rng.range(3, max_s - n as i64) } else { rng.range(3 + n as i64, max_s) };
            start.shape = Shape::polygon(s0).unwrap();
            start.rot = 0;
            rules.push(Rule::Sides(d));
        }
        _ => {
            start.group = true;
            start.shape = shapes[0];
            let d = *rng.pick(&[1, 1, -1]);
            let len = n as i64; // values start..start+d*n (the answer included)
            start.count = if d > 0 { rng.range(1, 8 - len) } else { rng.range(1 + len, 8) };
            rules.push(Rule::Count(d));
        }
    }
    // Extra rules: medium sometimes one simple extra, hard 1–2 extra with other periods.
    let extra = if hard { rng.range(1, 2) } else { rng.below(2) as i64 };
    let mut pool: Vec<Rule> = vec![];
    if !start.group {
        pool.push(Rule::Corner(if hard { step(rng, &[1, 1, 2]) } else { 1 }));
    }
    pool.push(Rule::FillCycle(if hard && rng.chance(0.5) { 3 } else { 2 }));
    if start.group {
        pool.push(Rule::ShapeCycle(if hard { *rng.pick(&[2, 3]) } else { 2 }));
    }
    rng.shuffle(&mut pool);
    for r in pool.into_iter().take(extra as usize) {
        if let Rule::Corner(_) = r {
            start.corner = rng.range(0, 3);
        }
        rules.push(r);
    }
    if hard && rules.len() < 2 {
        return None;
    }
    let all = frames(&rules, start, n + 1, &fills, &shapes);
    if !all.iter().all(valid) {
        return None;
    }
    let (seq, next) = (&all[..n], all[n]);
    let sizes: Vec<usize> = match rules.len() {
        1 => vec![if hard { 5 } else { 4 }],
        2 => vec![3, 2],
        3 => vec![2, 2, 2],
        _ => return None,
    };
    // Per rule: the attribute values (as whole frames differing in that attribute only).
    let mut values: Vec<Vec<Frame>> = vec![];
    for (r, &s) in rules.iter().zip(&sizes) {
        let w = wrong_frames(rng, *r, seq, &next, &fills, &shapes);
        if w.len() < s - 1 {
            return None;
        }
        let mut v = vec![next];
        v.extend(w.into_iter().take(s - 1));
        values.push(v);
    }
    let combos = balanced_combos(rng, &sizes);
    let mut opts = vec![];
    for c in &combos {
        let mut f = next;
        for (k, r) in rules.iter().enumerate() {
            let src = values[k][c[k]];
            match r {
                Rule::Rot(_) => f.rot = src.rot,
                Rule::Sides(_) | Rule::ShapeCycle(_) => f.shape = src.shape,
                Rule::Count(_) => f.count = src.count,
                Rule::Corner(_) => f.corner = src.corner,
                Rule::FillCycle(_) => f.fill = src.fill,
            }
        }
        if !valid(&f) {
            return None;
        }
        opts.push(IqOption::Figure(render(&f)));
    }
    if !all_distinct(&opts) {
        return None;
    }
    let mut cells: Vec<Value> = seq.iter().map(render).collect();
    cells.push(q_cell());
    let why = rules.iter().map(|r| describe(*r, &fills, &shapes)).collect::<Vec<_>>().join(" ");
    let figure = Some(grid(1, n + 1, cells, None));
    if !item_readable(&figure, &opts) {
        return None;
    }
    let correct = opts.remove(0);
    Some(finish(
        rng,
        "shape_series",
        hard,
        "Dizide sıradaki şekil hangisi?".into(),
        figure,
        correct,
        opts,
        why,
    ))
}

pub fn generate(rng: &mut Rng, hard: bool) -> IqItem {
    loop {
        if let Some(it) = try_gen(rng, hard) {
            if oracle(&it) == Ok(it.answer) {
                return it;
            }
        }
    }
}
