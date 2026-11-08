//! Polyomino categories: `mental_rotation` (2D rotation vs mirror) and `assembly` (which three
//! pieces form the target). Cells are (x, y) with y pointing down.
//!
//! mental_rotation — medium: one option is the shape rotated, the others are rotated mirror
//! images. Hard: apply a stated composition (mirror then rotate, or rotate then mirror);
//! distractors use the wrong order, drop one step, use the other mirror axis or turn the other
//! way. Shapes have no symmetry at all, so the 8 orientations are distinct. Oracle: compare
//! canonical forms (rotation class / exact orientation after applying `ops` from the figure).
//!
//! assembly — a target region is cut into 3 connected pieces, 3 decoys are added. Medium: flips
//! allowed; hard: rotations only, decoys share sizes so several triples have the right area.
//! Oracle: an exact-cover tiler over all 20 triples; exactly one may tile.

use super::fig_common::*;
use crate::games::iq::item::{IqItem, IqOption};
use crate::rng::Rng;
use serde_json::{json, Value};

pub type Cells = Vec<(i32, i32)>;

pub fn norm(c: &[(i32, i32)]) -> Cells {
    let mx = c.iter().map(|p| p.0).min().unwrap_or(0);
    let my = c.iter().map(|p| p.1).min().unwrap_or(0);
    let mut v: Cells = c.iter().map(|&(x, y)| (x - mx, y - my)).collect();
    v.sort();
    v.dedup();
    v
}

/// 90° clockwise on screen (y down).
pub fn cw(c: &[(i32, i32)]) -> Cells {
    norm(&c.iter().map(|&(x, y)| (-y, x)).collect::<Vec<_>>())
}

pub fn mirror_h(c: &[(i32, i32)]) -> Cells {
    norm(&c.iter().map(|&(x, y)| (-x, y)).collect::<Vec<_>>())
}

pub fn mirror_v(c: &[(i32, i32)]) -> Cells {
    norm(&c.iter().map(|&(x, y)| (x, -y)).collect::<Vec<_>>())
}

pub fn rotations(c: &[(i32, i32)]) -> Vec<Cells> {
    let mut v = vec![norm(c)];
    for _ in 0..3 {
        let n = cw(v.last().unwrap());
        v.push(n);
    }
    v
}

/// Distinct orientations (rotations, plus mirrors when `flip`).
pub fn orientations(c: &[(i32, i32)], flip: bool) -> Vec<Cells> {
    let mut v = rotations(c);
    if flip {
        v.extend(rotations(&mirror_h(c)));
    }
    v.sort();
    v.dedup();
    v
}

pub fn canon(c: &[(i32, i32)], flip: bool) -> Cells {
    orientations(c, flip).into_iter().min().unwrap()
}

pub fn dims(c: &[(i32, i32)]) -> (i32, i32) {
    (c.iter().map(|p| p.0).max().unwrap_or(0) + 1, c.iter().map(|p| p.1).max().unwrap_or(0) + 1)
}

fn neighbours((x, y): (i32, i32)) -> [(i32, i32); 4] {
    [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
}

/// Random connected polyomino of `n` cells within a `max`×`max` box.
pub fn random_poly(rng: &mut Rng, n: usize, max: i32) -> Cells {
    loop {
        let mut c: Cells = vec![(0, 0)];
        while c.len() < n {
            let base = c[rng.below(c.len())];
            let nb = neighbours(base)[rng.below(4)];
            if !c.contains(&nb) {
                c.push(nb);
            }
        }
        let c = norm(&c);
        let (w, h) = dims(&c);
        if w <= max && h <= max {
            return c;
        }
    }
}

pub fn poly_fig(c: &[(i32, i32)], box_n: i32) -> Value {
    let cells: Vec<Value> = norm(c).iter().map(|&(x, y)| json!([x, y])).collect();
    json!({ "k": "poly", "w": 1, "h": 1, "n": box_n, "cells": cells })
}

pub fn parse_cells(v: &Value) -> Result<Cells, String> {
    v.as_array()
        .ok_or("cells")?
        .iter()
        .map(|p| Ok((p[0].as_i64().ok_or("x")? as i32, p[1].as_i64().ok_or("y")? as i32)))
        .collect()
}

// ------------------------------------------------------------------------- mental_rotation

#[derive(Clone, Copy, PartialEq, Debug)]
enum Op {
    MirrorH,
    MirrorV,
    Cw,
    Ccw,
    R180,
}

impl Op {
    fn id(self) -> &'static str {
        match self {
            Op::MirrorH => "mirror_h",
            Op::MirrorV => "mirror_v",
            Op::Cw => "cw90",
            Op::Ccw => "ccw90",
            Op::R180 => "r180",
        }
    }
    fn from_id(s: &str) -> Option<Op> {
        [Op::MirrorH, Op::MirrorV, Op::Cw, Op::Ccw, Op::R180].into_iter().find(|o| o.id() == s)
    }
    fn tr(self) -> &'static str {
        match self {
            Op::MirrorH => "sağ–sol aynala",
            Op::MirrorV => "alt–üst aynala",
            Op::Cw => "90° saat yönünde döndür",
            Op::Ccw => "90° saatin tersi yönünde döndür",
            Op::R180 => "180° döndür",
        }
    }
    fn apply(self, c: &[(i32, i32)]) -> Cells {
        match self {
            Op::MirrorH => mirror_h(c),
            Op::MirrorV => mirror_v(c),
            Op::Cw => cw(c),
            Op::Ccw => cw(&cw(&cw(c))),
            Op::R180 => cw(&cw(c)),
        }
    }
}

fn apply_ops(ops: &[Op], c: &[(i32, i32)]) -> Cells {
    let mut v = norm(c);
    for o in ops {
        v = o.apply(&v);
    }
    v
}

pub fn rotation_oracle(item: &IqItem) -> Result<usize, String> {
    let fig = item.figure.as_ref().ok_or("no figure")?;
    let src = parse_cells(&fig["cells"])?;
    let opts: Vec<Cells> = item.options.iter().map(|o| parse_cells(&opt_fig(o)["cells"]).map(|c| norm(&c))).collect::<Result<_, _>>()?;
    let ops: Vec<Op> = match fig["ops"].as_array() {
        Some(a) => a.iter().map(|o| Op::from_id(o.as_str().unwrap_or("")).ok_or("bad op")).collect::<Result<_, _>>()?,
        None => vec![],
    };
    let ok: Vec<bool> = if ops.is_empty() {
        // any proper rotation (0/90/180/270) of the source, never a mirror image
        let rots = rotations(&src);
        opts.iter().map(|o| rots.contains(o)).collect()
    } else {
        let want = apply_ops(&ops, &src);
        opts.iter().map(|o| *o == want).collect()
    };
    if !all_distinct(&item.options) {
        return Err("duplicate options".into());
    }
    unique_index(&ok)
}

fn asymmetric_poly(rng: &mut Rng, n: usize, max: i32) -> Cells {
    loop {
        let c = random_poly(rng, n, max);
        if orientations(&c, true).len() == 8 {
            return c;
        }
    }
}

/// The shape with one cell moved to another free spot (still connected).
fn near_miss(rng: &mut Rng, c: &[(i32, i32)]) -> Cells {
    loop {
        let mut v: Cells = c.to_vec();
        v.remove(rng.below(v.len()));
        let base = v[rng.below(v.len())];
        let nb = neighbours(base)[rng.below(4)];
        if v.contains(&nb) || c.contains(&nb) {
            continue;
        }
        v.push(nb);
        if connected(&v) {
            return norm(&v);
        }
    }
}

fn connected(c: &[(i32, i32)]) -> bool {
    let mut seen = vec![c[0]];
    let mut i = 0;
    while i < seen.len() {
        for nb in neighbours(seen[i]) {
            if c.contains(&nb) && !seen.contains(&nb) {
                seen.push(nb);
            }
        }
        i += 1;
    }
    seen.len() == c.len()
}

pub fn generate_rotation(rng: &mut Rng, hard: bool) -> IqItem {
    loop {
        let n = if hard { rng.range(6, 7) as usize } else { rng.range(5, 6) as usize };
        let box_n = 4;
        let src = asymmetric_poly(rng, n, box_n);
        let rots = rotations(&src);
        let mirs = rotations(&mirror_h(&src));
        if !hard {
            let k = rng.range(1, 3) as usize;
            let correct = rots[k].clone();
            // Distractors: one mirror image of the shape (the classic mistake) and two near-miss
            // shapes (one cell moved), each also with its mirror image. Every option then has
            // exactly one mirror partner, so the option set alone does not single out the answer.
            let mut d: Vec<Cells> = vec![mirs[rng.below(4)].clone()];
            let all_or = orientations(&src, true);
            let mut guard = 0;
            while d.len() < 5 && guard < 200 {
                guard += 1;
                let v = near_miss(rng, &src);
                if orientations(&v, true).len() == 8
                    && !all_or.contains(&v)
                    && !d.iter().any(|x| canon(x, true) == canon(&v, true))
                {
                    let o = rotations(&v);
                    let om = rotations(&mirror_h(&v));
                    d.push(o[rng.below(4)].clone());
                    d.push(om[rng.below(4)].clone());
                }
            }
            if d.len() < 5 {
                continue;
            }
            rng.shuffle(&mut d);
            let opts: Vec<IqOption> = d.iter().map(|c| IqOption::Figure(poly_fig(c, box_n))).collect();
            let angle = [0, 90, 180, 270][k];
            let item = finish(
                rng,
                "mental_rotation",
                false,
                "Hangisi üstteki şeklin yalnızca döndürülmüş hâlidir (aynalanmamış)?".into(),
                Some(poly_fig(&src, box_n)),
                IqOption::Figure(poly_fig(&correct, box_n)),
                opts,
                format!(
                    "Doğru seçenek şeklin {angle}° saat yönünde döndürülmüş hâli. Ayna görüntüsü hangi açıyla döndürülürse döndürülsün üst üste gelmez; diğer seçeneklerde bir kare yer değiştirmiş."
                ),
            );
            if rotation_oracle(&item) == Ok(item.answer) {
                return item;
            }
            continue;
        }
        let mirror = if rng.chance(0.6) { Op::MirrorH } else { Op::MirrorV };
        let rot = *rng.pick(&[Op::Cw, Op::Ccw, Op::Cw, Op::Ccw, Op::R180]);
        let ops = if rng.chance(0.5) { vec![mirror, rot] } else { vec![rot, mirror] };
        let correct = apply_ops(&ops, &src);
        let other_mirror = if mirror == Op::MirrorH { Op::MirrorV } else { Op::MirrorH };
        let other_rot = match rot {
            Op::Cw => Op::Ccw,
            Op::Ccw => Op::Cw,
            _ => Op::Cw,
        };
        let cands: Vec<Vec<Op>> = vec![
            vec![ops[1], ops[0]],
            vec![rot],
            vec![mirror],
            if ops[0] == mirror { vec![mirror, other_rot] } else { vec![other_rot, mirror] },
            vec![other_mirror, rot],
            vec![],
        ];
        let mut d: Vec<Cells> = vec![];
        for c in cands {
            let x = apply_ops(&c, &src);
            if x != correct && !d.contains(&x) {
                d.push(x);
            }
        }
        // top up with other orientations
        let mut rest: Vec<Cells> = rots.iter().chain(&mirs).cloned().collect();
        rng.shuffle(&mut rest);
        for x in rest {
            if d.len() >= 5 {
                break;
            }
            if x != correct && !d.contains(&x) {
                d.push(x);
            }
        }
        d.truncate(5);
        let steps: Vec<&str> = ops.iter().map(|o| o.tr()).collect();
        let prompt = format!("Şekli önce {}, sonra {}. Sonuç hangisi?", steps[0], steps[1]);
        let mut fig = poly_fig(&src, box_n);
        fig["ops"] = json!(ops.iter().map(|o| o.id()).collect::<Vec<_>>());
        let item = finish(
            rng,
            "mental_rotation",
            true,
            prompt,
            Some(fig),
            IqOption::Figure(poly_fig(&correct, box_n)),
            d.iter().map(|c| IqOption::Figure(poly_fig(c, box_n))).collect(),
            format!(
                "Adımları sırayla uygula: önce {}, sonra {}. Sıra önemlidir: ters sırada yapmak ya da bir adımı atlamak başka bir şekil verir.",
                steps[0], steps[1]
            ),
        );
        if rotation_oracle(&item) == Ok(item.answer) {
            return item;
        }
    }
}

// --------------------------------------------------------------------------------- assembly

/// Can the pieces exactly tile the target (each used once)?
pub fn tiles(target: &[(i32, i32)], pieces: &[Cells], flip: bool) -> bool {
    let area: usize = pieces.iter().map(|p| p.len()).sum();
    if area != target.len() {
        return false;
    }
    let ors: Vec<Vec<Cells>> = pieces.iter().map(|p| orientations(p, flip)).collect();
    let mut free: Vec<(i32, i32)> = norm(target);
    let mut used = vec![false; pieces.len()];
    fn rec(free: &mut Vec<(i32, i32)>, ors: &[Vec<Cells>], used: &mut [bool]) -> bool {
        let Some(&first) = free.iter().min_by_key(|&&(x, y)| (y, x)) else {
            return true;
        };
        for i in 0..ors.len() {
            if used[i] {
                continue;
            }
            for o in &ors[i] {
                // anchor: the piece's first cell in (y, x) order lands on `first`
                let a = *o.iter().min_by_key(|&&(x, y)| (y, x)).unwrap();
                let placed: Vec<(i32, i32)> = o.iter().map(|&(x, y)| (x - a.0 + first.0, y - a.1 + first.1)).collect();
                if placed.iter().all(|p| free.contains(p)) {
                    free.retain(|p| !placed.contains(p));
                    used[i] = true;
                    if rec(free, ors, used) {
                        return true;
                    }
                    used[i] = false;
                    free.extend(placed);
                }
            }
        }
        false
    }
    rec(&mut free, &ors, &mut used)
}

const LABELS: [&str; 6] = ["A", "B", "C", "D", "E", "F"];

fn triples() -> Vec<[usize; 3]> {
    let mut v = vec![];
    for a in 0..6 {
        for b in a + 1..6 {
            for c in b + 1..6 {
                v.push([a, b, c]);
            }
        }
    }
    v
}

fn triple_text(t: &[usize; 3]) -> String {
    format!("{} + {} + {}", LABELS[t[0]], LABELS[t[1]], LABELS[t[2]])
}

pub fn assembly_oracle(item: &IqItem) -> Result<usize, String> {
    let fig = item.figure.as_ref().ok_or("no figure")?;
    let target = parse_cells(&fig["target"])?;
    let flip = fig["flip"].as_bool().ok_or("flip")?;
    let pieces: Vec<Cells> =
        fig["pieces"].as_array().ok_or("pieces")?.iter().map(|p| parse_cells(&p["cells"])).collect::<Result<_, _>>()?;
    if pieces.len() != 6 {
        return Err("expected 6 pieces".into());
    }
    let tiling: Vec<[usize; 3]> =
        triples().into_iter().filter(|t| tiles(&target, &t.iter().map(|&i| pieces[i].clone()).collect::<Vec<_>>(), flip)).collect();
    if tiling.len() != 1 {
        return Err(format!("{} triples tile the target", tiling.len()));
    }
    let want = triple_text(&tiling[0]);
    let ok: Vec<bool> = item.options.iter().map(|o| opt_text(o) == want).collect();
    unique_index(&ok)
}

/// Cut `target` into 3 connected pieces of 2..=5 cells by random region growing.
fn partition(rng: &mut Rng, target: &[(i32, i32)]) -> Option<Vec<Cells>> {
    let mut owner: Vec<Option<usize>> = vec![None; target.len()];
    let mut seeds: Vec<usize> = (0..target.len()).collect();
    rng.shuffle(&mut seeds);
    for (k, &s) in seeds.iter().take(3).enumerate() {
        owner[s] = Some(k);
    }
    for _ in 0..500 {
        if owner.iter().all(|o| o.is_some()) {
            break;
        }
        let i = rng.below(target.len());
        if owner[i].is_some() {
            continue;
        }
        let nb: Vec<usize> = neighbours(target[i])
            .iter()
            .filter_map(|p| target.iter().position(|q| q == p))
            .filter(|&j| owner[j].is_some())
            .collect();
        if nb.is_empty() {
            continue;
        }
        let j = nb[rng.below(nb.len())];
        let k = owner[j].unwrap();
        let size = owner.iter().filter(|o| **o == Some(k)).count();
        if size < 5 {
            owner[i] = Some(k);
        }
    }
    if owner.iter().any(|o| o.is_none()) {
        return None;
    }
    let pieces: Vec<Cells> =
        (0..3).map(|k| norm(&target.iter().zip(&owner).filter(|(_, o)| **o == Some(k)).map(|(p, _)| *p).collect::<Vec<_>>())).collect();
    if pieces.iter().any(|p| p.len() < 2 || p.len() > 5) {
        return None;
    }
    Some(pieces)
}

pub fn generate_assembly(rng: &mut Rng, hard: bool) -> IqItem {
    loop {
        let flip = !hard;
        let target: Cells = if hard {
            let n = rng.range(10, 12) as usize;
            let t = random_poly(rng, n, 4);
            let (w, h) = dims(&t);
            if w * h == n as i32 {
                continue; // a plain rectangle is the medium shape
            }
            t
        } else {
            let (w, h) = *rng.pick(&[(2, 3), (3, 2), (2, 4), (4, 2), (3, 3)]);
            (0..w).flat_map(|x| (0..h).map(move |y| (x, y))).collect()
        };
        let Some(parts) = partition(rng, &target) else { continue };
        let mut pieces: Vec<Cells> = parts.clone();
        // Decoys: hard ones share the sizes of the real parts so the area check is not enough.
        for k in 0..3 {
            let n = if hard { parts[k].len() } else { rng.range(2, 5) as usize };
            pieces.push(random_poly(rng, n, 3));
        }
        // Show each piece in a random allowed orientation.
        let mut shown: Vec<Cells> = pieces
            .iter()
            .map(|p| {
                let o = orientations(p, flip);
                o[rng.below(o.len())].clone()
            })
            .collect();
        let mut order: Vec<usize> = (0..6).collect();
        rng.shuffle(&mut order);
        shown = order.iter().map(|&i| shown[i].clone()).collect();
        let pos_of = |orig: usize| order.iter().position(|&i| i == orig).unwrap();
        let mut ans = [pos_of(0), pos_of(1), pos_of(2)];
        ans.sort();
        // Pieces must look different from each other.
        let canons: Vec<Cells> = shown.iter().map(|p| canon(p, flip)).collect();
        if (0..6).any(|i| (i + 1..6).any(|j| canons[i] == canons[j])) {
            continue;
        }
        let all = triples();
        let tiling: Vec<&[usize; 3]> =
            all.iter().filter(|t| tiles(&target, &t.iter().map(|&i| shown[i].clone()).collect::<Vec<_>>(), flip)).collect();
        if tiling.len() != 1 || *tiling[0] != ans {
            continue;
        }
        let area = target.len();
        let mut same_area: Vec<[usize; 3]> =
            all.iter().copied().filter(|t| *t != ans && t.iter().map(|&i| shown[i].len()).sum::<usize>() == area).collect();
        let mut others: Vec<[usize; 3]> = all.iter().copied().filter(|t| *t != ans && !same_area.contains(t)).collect();
        rng.shuffle(&mut same_area);
        rng.shuffle(&mut others);
        if hard && same_area.len() < 2 {
            continue;
        }
        let take_same = if hard { same_area.len().min(3) } else { same_area.len().min(1) };
        let mut d: Vec<[usize; 3]> = same_area.into_iter().take(take_same).collect();
        d.extend(others.into_iter().take(4 - d.len()));
        let max_dim = shown.iter().map(|p| dims(p).0.max(dims(p).1)).max().unwrap().max(3);
        let tdims = dims(&target);
        let fig = json!({
            "k": "assembly",
            "w": 3,
            "h": 3,
            "flip": flip,
            "n": max_dim,
            "tn": tdims.0.max(tdims.1),
            "target": norm(&target).iter().map(|&(x, y)| json!([x, y])).collect::<Vec<_>>(),
            "pieces": shown.iter().enumerate().map(|(i, p)| json!({
                "t": LABELS[i],
                "cells": p.iter().map(|&(x, y)| json!([x, y])).collect::<Vec<_>>(),
            })).collect::<Vec<_>>(),
        });
        let sizes: Vec<String> = ans.iter().map(|&i| format!("{} ({} kare)", LABELS[i], shown[i].len())).collect();
        let why = format!(
            "{} birlikte hedef şekli tam olarak kaplar: toplam {} kare. {}",
            tr_list(&sizes),
            area,
            if hard {
                "Alanı tutan başka üçlüler de var ama onlar şekle yerleşmiyor; parçalar döndürülebilir, ters çevrilemez."
            } else {
                "Parçalar döndürülebilir ve ters çevrilebilir."
            }
        );
        let prompt = if hard {
            "Hangi üç parça birleşince üstteki şekli oluşturur? (Parçalar döndürülebilir ama ters çevrilemez.)"
        } else {
            "Hangi üç parça birleşince üstteki şekli oluşturur? (Parçalar döndürülebilir ve ters çevrilebilir.)"
        };
        let item = finish(
            rng,
            "assembly",
            hard,
            prompt.into(),
            Some(fig),
            IqOption::Text(triple_text(&ans)),
            d.iter().map(|t| IqOption::Text(triple_text(t))).collect(),
            why,
        );
        if assembly_oracle(&item) == Ok(item.answer) {
            return item;
        }
    }
}
