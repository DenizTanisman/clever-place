//! `figure_analogy`: A → B, C → ?  Apply the same transformation to C.
//!
//! Two templates. *Nested*: a large outer shape with a small gold inner shape; transformations
//! swap inner/outer shapes and invert fills (solid ↔ empty). *Group*: n arrows / shapes;
//! transformations change the count, rotate, invert the fill. Medium: 1–2 transformations;
//! hard: 3.
//!
//! Oracle: per attribute, every reading of A→B in a grammar (identity, set-to-B's-value, delta,
//! side-count delta, ratio, take-from-another-attribute (swap), fill inversion, rotation
//! mirror) predicts D from C; an option fits if each attribute is predicted by some reading.
//! Exactly one option may fit.

use super::fig_common::*;
use crate::games::iq::item::{IqItem, IqOption};
use crate::rng::Rng;
use serde_json::{json, Value};
use std::collections::BTreeSet;

const NSHAPES: [Shape; 6] = [Shape::Circle, Shape::Square, Shape::Triangle, Shape::Diamond, Shape::Hexagon, Shape::Pentagon];
const GSHAPES: [Shape; 5] = [Shape::Arrow, Shape::Circle, Shape::Square, Shape::Star, Shape::Triangle];
const OFILLS: [Fill; 4] = [Fill::None, Fill::Solid, Fill::Stripes, Fill::Dots];

#[derive(Clone, Copy, PartialEq, Debug)]
struct Fig {
    nested: bool,
    // nested
    so: Shape,
    si: Shape,
    fo: Fill,
    fi: Fill,
    // group
    n: i64,
    s: Shape,
    f: Fill,
    rot: i64,
}

fn render(x: &Fig) -> Value {
    if x.nested {
        let mut inner = shape_item(x.si, 0.5, 0.5, 0.15, 0, x.fi);
        inner["c"] = json!("gold");
        inner["ko"] = json!(true);
        cell(vec![shape_item(x.so, 0.5, 0.5, 0.4, 0, x.fo), inner])
    } else {
        cell(group_items(x.s, x.n as usize, x.f, x.rot, 1))
    }
}

fn inv(f: Fill) -> Option<Fill> {
    match f {
        Fill::Solid => Some(Fill::None),
        Fill::None => Some(Fill::Solid),
        _ => None,
    }
}

// ------------------------------------------------------------------------------------- oracle

#[derive(Clone, Copy, PartialEq)]
enum T {
    Shape,
    Fill,
    Num,
    Rot,
}

/// Parsed attribute vector with the type of each slot.
fn parse(v: &Value) -> Result<Vec<(T, i64)>, String> {
    if v["k"] != "cell" {
        return Err("not a cell".into());
    }
    let its = items(v);
    let sh = |i: &Value| -> Result<i64, String> {
        Ok(ALL_SHAPES.iter().position(|&s| Some(s) == Shape::from_id(i["s"].as_str().unwrap_or(""))).ok_or("shape")? as i64)
    };
    let fl = |i: &Value| -> Result<i64, String> {
        Ok(FILLS.iter().position(|&f| Some(f) == Fill::from_id(i["f"].as_str().unwrap_or(""))).ok_or("fill")? as i64)
    };
    if its.len() == 2 && its[1]["c"] == "gold" {
        Ok(vec![(T::Shape, sh(&its[0])?), (T::Shape, sh(&its[1])?), (T::Fill, fl(&its[0])?), (T::Fill, fl(&its[1])?)])
    } else {
        let f = its.first().ok_or("empty")?;
        let rot = f["rot"].as_i64().ok_or("rot")?;
        Ok(vec![(T::Num, its.len() as i64), (T::Shape, sh(f)?), (T::Fill, fl(f)?), (T::Rot, rot.rem_euclid(360) / 45)])
    }
}

fn inv_i(f: i64) -> Option<i64> {
    let fl = inv(FILLS[f as usize])?;
    Some(FILLS.iter().position(|&x| x == fl).unwrap() as i64)
}

fn sides_i(s: i64) -> Option<i64> {
    ALL_SHAPES[s as usize].sides()
}

fn predict(a: &[(T, i64)], b: &[(T, i64)], c: &[(T, i64)], k: usize) -> BTreeSet<i64> {
    let (t, ax, bx, cx) = (a[k].0, a[k].1, b[k].1, c[k].1);
    let mut p = BTreeSet::new();
    if ax == bx {
        p.insert(cx);
    }
    p.insert(bx);
    for (j, &(tj, aj)) in a.iter().enumerate() {
        if j != k && tj == t && aj == bx {
            p.insert(c[j].1);
        }
    }
    match t {
        T::Num => {
            p.insert(cx + bx - ax);
            if ax != 0 && bx % ax == 0 {
                p.insert(cx * (bx / ax));
            }
            if bx != 0 && ax % bx == 0 && cx % (ax / bx) == 0 {
                p.insert(cx / (ax / bx));
            }
        }
        T::Rot => {
            p.insert((cx + bx - ax).rem_euclid(8));
            if bx == (-ax).rem_euclid(8) {
                p.insert((-cx).rem_euclid(8));
            }
            if bx == (4 - ax).rem_euclid(8) {
                p.insert((4 - cx).rem_euclid(8));
            }
        }
        T::Fill => {
            if inv_i(ax) == Some(bx) {
                if let Some(x) = inv_i(cx) {
                    p.insert(x);
                }
            }
        }
        T::Shape => {
            if let (Some(sa), Some(sb), Some(sc)) = (sides_i(ax), sides_i(bx), sides_i(cx)) {
                if let Some(s) = Shape::polygon(sc + sb - sa) {
                    p.insert(ALL_SHAPES.iter().position(|&x| x == s).unwrap() as i64);
                }
            }
        }
    }
    p
}

pub fn oracle(item: &IqItem) -> Result<usize, String> {
    let fig = item.figure.as_ref().ok_or("no figure")?;
    let cells = fig["cells"].as_array().ok_or("no cells")?;
    // grid 2×3: A → B / C → ?
    if cells.len() != 6 || cells[5]["k"] != "q" {
        return Err("expected A → B / C → ?".into());
    }
    let (a, b, c) = (parse(&cells[0])?, parse(&cells[2])?, parse(&cells[3])?);
    if a.len() != b.len() || a.len() != c.len() {
        return Err("mixed templates".into());
    }
    let opts: Vec<Vec<(T, i64)>> = item.options.iter().map(|o| parse(opt_fig(o))).collect::<Result<_, _>>()?;
    let mut ok = vec![true; opts.len()];
    for k in 0..a.len() {
        let p = predict(&a, &b, &c, k);
        for (i, o) in opts.iter().enumerate() {
            if o.len() != a.len() || !p.contains(&o[k].1) {
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
enum Tr {
    Swap,
    InvOuter,
    InvInner,
    Count(i64),
    Rot(i64),
    InvFill,
}

fn apply(t: Tr, x: &Fig) -> Option<Fig> {
    let mut y = *x;
    match t {
        Tr::Swap => {
            y.so = x.si;
            y.si = x.so;
        }
        Tr::InvOuter => y.fo = inv(x.fo)?,
        Tr::InvInner => y.fi = inv(x.fi)?,
        Tr::Count(d) => {
            y.n = x.n + d;
            if !(1..=6).contains(&y.n) {
                return None;
            }
        }
        Tr::Rot(k) => y.rot = (x.rot + 45 * k).rem_euclid(360),
        Tr::InvFill => y.f = inv(x.f)?,
    }
    Some(y)
}

fn apply_all(ts: &[Tr], x: &Fig) -> Option<Fig> {
    let mut y = *x;
    for t in ts {
        y = apply(*t, &y)?;
    }
    Some(y)
}

/// Wrong versions of `d` for transformation `t` (whole figures, only `t`'s attribute differs).
fn wrongs(t: Tr, c: &Fig, d: &Fig) -> Vec<Fig> {
    let mut v = vec![];
    match t {
        Tr::Swap => {
            let mut y = *d;
            y.so = c.so;
            y.si = c.si;
            v.push(y);
        }
        Tr::InvOuter => {
            let mut y = *d;
            y.fo = c.fo;
            v.push(y);
            for f in OFILLS {
                let mut y = *d;
                y.fo = f;
                v.push(y);
            }
        }
        Tr::InvInner => {
            let mut y = *d;
            y.fi = c.fi;
            v.push(y);
        }
        Tr::Count(k) => {
            for n in [c.n, d.n + k.signum(), d.n - k.signum(), c.n - k] {
                let mut y = *d;
                y.n = n;
                v.push(y);
            }
        }
        Tr::Rot(k) => {
            for r in [c.rot, c.rot - 45 * k, d.rot + 180, d.rot + 90] {
                let mut y = *d;
                y.rot = r.rem_euclid(360);
                v.push(y);
            }
        }
        Tr::InvFill => {
            let mut y = *d;
            y.f = c.f;
            v.push(y);
        }
    }
    let mut out: Vec<Fig> = vec![];
    for y in v {
        if y != *d && (y.nested || (1..=6).contains(&y.n)) && !out.contains(&y) {
            out.push(y);
        }
    }
    out
}

fn describe(t: Tr) -> String {
    match t {
        Tr::Swap => "Dıştaki ve içteki şekil yer değiştiriyor.".into(),
        Tr::InvOuter => "Dış şeklin dolgusu tersine dönüyor (dolu olan boş, boş olan dolu olur).".into(),
        Tr::InvInner => "İç şeklin dolgusu tersine dönüyor (dolu olan boş, boş olan dolu olur).".into(),
        Tr::Count(d) => format!("Şekil sayısı {} {}.", d.abs(), if d > 0 { "artıyor" } else { "azalıyor" }),
        Tr::Rot(k) => format!(
            "Şekiller {}° {} dönüyor.",
            45 * k.abs(),
            if k > 0 { "saat yönünde" } else { "saatin tersi yönünde" }
        ),
        Tr::InvFill => "Dolgu tersine dönüyor (dolu olan boş, boş olan dolu olur).".into(),
    }
}

fn try_gen(rng: &mut Rng, hard: bool) -> Option<IqItem> {
    let nested = rng.chance(0.45);
    let pick2 = |rng: &mut Rng, pal: &[Shape]| {
        let mut p = pal.to_vec();
        rng.shuffle(&mut p);
        (p[0], p[1])
    };
    let sf = |rng: &mut Rng| if rng.chance(0.5) { Fill::Solid } else { Fill::None };
    let mut ts: Vec<Tr>;
    let (a, c);
    if nested {
        let (s1, s2) = pick2(rng, &NSHAPES);
        let (s3, s4) = pick2(rng, &NSHAPES);
        if (s1, s2) == (s3, s4) {
            return None;
        }
        let base = Fig { nested: true, so: s1, si: s2, fo: sf(rng), fi: sf(rng), n: 0, s: Shape::Circle, f: Fill::None, rot: 0 };
        a = base;
        c = Fig { so: s3, si: s4, fo: sf(rng), fi: sf(rng), ..base };
        ts = if hard {
            vec![Tr::Swap, Tr::InvOuter, Tr::InvInner]
        } else {
            rng.pick(&[vec![Tr::Swap], vec![Tr::Swap, Tr::InvOuter], vec![Tr::Swap, Tr::InvInner], vec![Tr::InvOuter, Tr::InvInner]]).clone()
        };
    } else {
        let arrows = rng.chance(0.6);
        let s_a = if arrows { Shape::Arrow } else { *rng.pick(&GSHAPES[1..]) };
        let s_c = if arrows { Shape::Arrow } else { *rng.pick(&GSHAPES[1..]) };
        let mut pool = vec![Tr::Count(*rng.pick(&[1, 1, 2, -1, -2])), Tr::InvFill];
        if arrows {
            pool.push(Tr::Rot(*rng.pick(&[2, -2, 1, -1, 4])));
        }
        rng.shuffle(&mut pool);
        let k = if hard { 3 } else { rng.range(1, 2) as usize };
        if pool.len() < k {
            return None;
        }
        ts = pool.into_iter().take(k).collect();
        let rot0 = |rng: &mut Rng| if arrows { 90 * rng.range(0, 3) } else { 0 };
        a = Fig { nested: false, so: Shape::Circle, si: Shape::Circle, fo: Fill::None, fi: Fill::None, n: rng.range(1, 4), s: s_a, f: sf(rng), rot: rot0(rng) };
        c = Fig { n: rng.range(1, 4), s: s_c, f: sf(rng), rot: rot0(rng), ..a };
        if !hard && (a.n == c.n && a.s == c.s && a.f == c.f && a.rot == c.rot) {
            return None;
        }
    }
    ts.sort_by_key(|t| format!("{t:?}"));
    let b = apply_all(&ts, &a)?;
    let d = apply_all(&ts, &c)?;
    if b == a || d == c {
        return None;
    }
    let sizes: Vec<usize> = match ts.len() {
        1 => vec![4],
        2 => vec![3, 2],
        3 => vec![2, 2, 2],
        _ => return None,
    };
    let mut values: Vec<Vec<Fig>> = vec![];
    for (t, &s) in ts.iter().zip(&sizes) {
        let mut w = wrongs(*t, &c, &d);
        if s == 4 && w.len() < 3 {
            // a single swap has only one bug model: add fill variants as extra dimensions
            let mut extra = vec![];
            for y in &w {
                let mut z = *y;
                z.fo = inv(z.fo).unwrap_or(z.fo);
                extra.push(z);
            }
            let mut z = d;
            z.fo = inv(z.fo).unwrap_or(z.fo);
            extra.push(z);
            for e in extra {
                if e != d && !w.contains(&e) {
                    w.push(e);
                }
            }
        }
        if w.len() < s - 1 {
            return None;
        }
        let mut v = vec![d];
        v.extend(w.into_iter().take(s - 1));
        values.push(v);
    }
    let combos = balanced_combos(rng, &sizes);
    let mut opts = vec![];
    for cmb in &combos {
        let mut y = d;
        for (k, t) in ts.iter().enumerate() {
            let src = values[k][cmb[k]];
            match t {
                Tr::Swap => {
                    y.so = src.so;
                    y.si = src.si;
                }
                Tr::InvOuter => y.fo = src.fo,
                Tr::InvInner => y.fi = src.fi,
                Tr::Count(_) => y.n = src.n,
                Tr::Rot(_) => y.rot = src.rot,
                Tr::InvFill => y.f = src.f,
            }
            if sizes == [4] {
                y = src;
            }
        }
        opts.push(IqOption::Figure(render(&y)));
    }
    if !all_distinct(&opts) {
        return None;
    }
    let arrow = sep("→");
    let fig = grid(2, 3, vec![render(&a), arrow.clone(), render(&b), render(&c), arrow, q_cell()], Some(vec![1.0, 0.5, 1.0]));
    let why = ts.iter().map(|t| describe(*t)).collect::<Vec<_>>().join(" ");
    if !item_readable(&Some(fig.clone()), &opts) {
        return None;
    }
    let correct = opts.remove(0);
    Some(finish(
        rng,
        "figure_analogy",
        hard,
        "İlk şekil ikinciye nasıl dönüşüyorsa, üçüncü şekil de öyle dönüşür. Soru işaretinin yerine hangisi gelmeli?".into(),
        Some(fig),
        correct,
        opts,
        format!("{why} Aynı değişiklik üçüncü şekle uygulanır."),
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
