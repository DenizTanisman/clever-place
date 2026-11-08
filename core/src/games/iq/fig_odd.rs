//! `odd_shape`: five figures, one does not share the rule the other four share.
//!
//! Medium: a surface feature (fill, count) or a simple relation (inner shape = outer shape).
//! Hard: chirality (four rotations of one shape, one mirror image) or a relation between two
//! attributes (count = number of sides).
//!
//! Oracle: a salient-feature library (every attribute, side parity, curved/straight, relations,
//! rotation class, free class, bounding-box aspect, …) scans all 4-vs-1 splits; every split must
//! point at the same figure, and there must be at least one.

use super::fig_common::*;
use super::fig_poly::{canon, dims, mirror_h, norm, orientations, parse_cells, random_poly, rotations};
use crate::games::iq::item::{IqItem, IqOption};
use crate::rng::Rng;
use serde_json::{json, Value};

const OSHAPES: [Shape; 7] = [Shape::Circle, Shape::Triangle, Shape::Square, Shape::Diamond, Shape::Hexagon, Shape::Star, Shape::Cross];
const OFILLS: [Fill; 4] = [Fill::None, Fill::Solid, Fill::Stripes, Fill::Dots];
const POLYS: [Shape; 4] = [Shape::Triangle, Shape::Square, Shape::Pentagon, Shape::Hexagon];

/// Salient features of one option figure (name, value).
fn features(v: &Value) -> Result<Vec<(String, String)>, String> {
    let mut f: Vec<(String, String)> = vec![];
    let mut put = |k: &str, v: String| f.push((k.to_string(), v));
    match v["k"].as_str() {
        Some("poly") => {
            let c = norm(&parse_cells(&v["cells"])?);
            let (w, h) = dims(&c);
            put("size", c.len().to_string());
            put("rotclass", format!("{:?}", canon(&c, false)));
            put("freeclass", format!("{:?}", canon(&c, true)));
            put("orient", format!("{c:?}"));
            put("aspect", (w > h).to_string());
            put("bbox", format!("{w}x{h}"));
            put("selfsym", (orientations(&c, true).len()).to_string());
        }
        Some("cell") => {
            let its = items(v);
            let nested = its.len() == 2 && its[1]["c"] == "gold";
            let sh = |i: &Value| Shape::from_id(i["s"].as_str().unwrap_or("")).ok_or("shape".to_string());
            if nested {
                let (o, i) = (sh(&its[0])?, sh(&its[1])?);
                put("outer", o.id().into());
                put("inner", i.id().into());
                put("ofill", its[0]["f"].to_string());
                put("ifill", its[1]["f"].to_string());
                put("same", (o == i).to_string());
                put("osides", format!("{:?}", o.sides()));
                put("isides", format!("{:?}", i.sides()));
                put("ocurved", (o == Shape::Circle).to_string());
                put("icurved", (i == Shape::Circle).to_string());
                put("fillsame", (its[0]["f"] == its[1]["f"]).to_string());
                put("ipolyless", format!("{:?}", o.sides().zip(i.sides()).map(|(a, b)| a > b)));
            } else {
                let first = its.first().ok_or("empty")?;
                let s = sh(first)?;
                let n = its.len() as i64;
                put("count", n.to_string());
                put("countpar", (n % 2).to_string());
                put("shape", s.id().into());
                put("fill", first["f"].to_string());
                put("sides", format!("{:?}", s.sides()));
                put("sidespar", format!("{:?}", s.sides().map(|x| x % 2)));
                put("curved", (s == Shape::Circle).to_string());
                put("polygon", s.sides().is_some().to_string());
                put("count=sides", (s.sides() == Some(n)).to_string());
                put("count<sides", format!("{:?}", s.sides().map(|x| n < x)));
                put("filled", (first["f"] != "none").to_string());
                put("rot", first["rot"].to_string());
                put("size", first["r"].to_string());
                for it in &its {
                    if it["s"] != first["s"] || it["f"] != first["f"] {
                        put("mixed", "true".into());
                    }
                }
            }
        }
        _ => return Err("unknown option figure".into()),
    }
    Ok(f)
}

pub fn oracle(item: &IqItem) -> Result<usize, String> {
    let feats: Vec<Vec<(String, String)>> = item.options.iter().map(|o| features(opt_fig(o))).collect::<Result<_, _>>()?;
    let n = feats.len();
    let mut names: Vec<String> = feats.iter().flat_map(|f| f.iter().map(|(k, _)| k.clone())).collect();
    names.sort();
    names.dedup();
    let mut pointed = vec![false; n];
    for name in &names {
        let vals: Vec<Option<&String>> = feats.iter().map(|f| f.iter().find(|(k, _)| k == name).map(|(_, v)| v)).collect();
        for i in 0..n {
            let others: Vec<&Option<&String>> = vals.iter().enumerate().filter(|(j, _)| *j != i).map(|(_, v)| v).collect();
            if others.iter().all(|v| **v == *others[0]) && vals[i] != *others[0] {
                pointed[i] = true;
            }
        }
    }
    if !all_distinct(&item.options) {
        return Err("duplicate options".into());
    }
    unique_index(&pointed)
}

// ---------------------------------------------------------------------------------- generator

fn group_cell(s: Shape, n: i64, f: Fill) -> Value {
    cell(group_items(s, n as usize, f, 0, 1))
}

fn nested_cell(o: Shape, i: Shape, fo: Fill, fi: Fill) -> Value {
    let mut inner = shape_item(i, 0.5, 0.5, 0.15, 0, fi);
    inner["c"] = json!("gold");
    inner["ko"] = json!(true);
    cell(vec![shape_item(o, 0.5, 0.5, 0.4, 0, fo), inner])
}

/// `k` random values with no value appearing 4 or more times.
fn spread<T: Copy + PartialEq>(rng: &mut Rng, pal: &[T], k: usize) -> Vec<T> {
    loop {
        let v: Vec<T> = (0..k).map(|_| *rng.pick(pal)).collect();
        if v.iter().all(|x| v.iter().filter(|y| *y == x).count() < 4) {
            return v;
        }
    }
}

fn try_gen(rng: &mut Rng, hard: bool, t: usize) -> Option<IqItem> {
    let mut figs: Vec<Value> = vec![];
    let why: String;
    match t {
        0 => {
            let mut fl = OFILLS.to_vec();
            rng.shuffle(&mut fl);
            let (common, odd) = (fl[0], fl[1]);
            let shapes = spread(rng, &OSHAPES, 5);
            let counts = spread(rng, &[1i64, 2, 3, 4], 5);
            for k in 0..5 {
                figs.push(group_cell(shapes[k], counts[k], if k == 0 { odd } else { common }));
            }
            why = format!("Dördünün dolgusu {}, yalnızca bunun dolgusu {}. Şekil ve sayı farkları belirleyici değil.", common.tr(), odd.tr());
        }
        1 => {
            let k = rng.range(1, 4);
            let odd = if k == 1 { 2 } else if k == 4 { 3 } else { k + if rng.chance(0.5) { 1 } else { -1 } };
            let shapes = spread(rng, &OSHAPES, 5);
            let fills = spread(rng, &OFILLS, 5);
            for i in 0..5 {
                figs.push(group_cell(shapes[i], if i == 0 { odd } else { k }, fills[i]));
            }
            why = format!("Dördünde {k} şekil var, yalnızca bunda {odd}.");
        }
        2 => {
            let mut outs = NSH.to_vec();
            rng.shuffle(&mut outs);
            let fo = spread(rng, &[Fill::None, Fill::Solid, Fill::Stripes], 5);
            let fi = spread(rng, &[Fill::None, Fill::Solid], 5);
            for i in 0..5 {
                let o = outs[i];
                let inner = if i == 0 { outs[5] } else { o };
                figs.push(nested_cell(o, inner, fo[i], fi[i]));
            }
            why = "Dördünde içteki şekil dıştakinin küçük bir kopyası; yalnızca bunda içteki şekil farklı.".into();
        }
        3 => {
            let src = loop {
                let n = rng.range(5, 6) as usize;
                let c = random_poly(rng, n, 4);
                if orientations(&c, true).len() == 8 {
                    break c;
                }
            };
            // Each figure sits at its own place in a 5×5 frame (the frames are not centred).
            let mirs = rotations(&mirror_h(&src));
            let place = |c: &[(i32, i32)], rng: &mut Rng| {
                let (w, h) = dims(c);
                let (ox, oy) = (rng.range(0, (5 - w) as i64) as i32, rng.range(0, (5 - h) as i64) as i32);
                let cells: Vec<Value> = c.iter().map(|&(x, y)| json!([x + ox, y + oy])).collect();
                json!({ "k": "poly", "w": 1, "h": 1, "n": 5, "abs": true, "cells": cells })
            };
            let m = mirs[rng.below(4)].clone();
            figs.push(place(&m, rng));
            for r in rotations(&src) {
                figs.push(place(&r, rng));
            }
            why = "Dördü aynı şeklin döndürülmüş hâli; bu ise ayna görüntüsü, döndürerek diğerlerinin üstüne getirilemez.".into();
        }
        _ => {
            let shapes = spread(rng, &POLYS, 5);
            let fills = spread(rng, &OFILLS, 5);
            let s0 = shapes[0].sides().unwrap();
            // The odd count is the side number of a polygon none of the others shows, so its
            // layout is not shared with another figure (no "most typical" leak).
            let missing: Vec<i64> = (3..=6).filter(|&k| k != s0 && !shapes[1..].iter().any(|s| s.sides() == Some(k))).collect();
            if missing.is_empty() {
                return None;
            }
            let odd = *rng.pick(&missing);
            for i in 0..5 {
                let s = shapes[i];
                let n = if i == 0 { odd } else { s.sides().unwrap() };
                figs.push(group_cell(s, n, fills[i]));
            }
            why = format!(
                "Dördünde şekil sayısı şeklin kenar sayısına eşit (3 üçgen, 4 kare, 5 beşgen, 6 altıgen); bunda ise {odd} {} var.",
                shapes[0].tr()
            );
        }
    }
    let correct = IqOption::Figure(figs.remove(0));
    let opts: Vec<IqOption> = figs.into_iter().map(IqOption::Figure).collect();
    let mut all = opts.clone();
    all.push(correct.clone());
    if !all_distinct(&all) || !item_readable(&None, &all) {
        return None;
    }
    Some(finish(rng, "odd_shape", hard, "Hangisi diğerlerinden farklı?".into(), None, correct, opts, why))
}

const NSH: [Shape; 6] = [Shape::Circle, Shape::Square, Shape::Triangle, Shape::Diamond, Shape::Hexagon, Shape::Pentagon];

pub fn generate(rng: &mut Rng, hard: bool) -> IqItem {
    let t = if hard { rng.below(2) + 3 } else { rng.below(3) };
    loop {
        if let Some(it) = try_gen(rng, hard, t) {
            if oracle(&it) == Ok(it.answer) {
                return it;
            }
        }
    }
}
