//! `block_count`: isometric stacks of unit cubes on a floor plate.
//!
//! Model: a height map (every cube rests on the floor or on another cube; the prompt says so).
//! Medium: 3×3 base, heights ≤ 3, "how many cubes?". Hard: 4×3 / 4×4 base, heights ≤ 4, either
//! "how many cubes?" or "how many more to fill the box?".
//!
//! View: x right-down, y right-up, z up (see the painter). Each visible face covers two triangles
//! of the isometric lattice; the picture is the frontmost face per triangle. A stack is only used
//! if its picture determines the count: no other height map that differs in one column, or by ±1
//! in two columns, or in a few hundred random columns, draws the same picture with a different
//! total. Oracle: count the voxels from the figure, re-check gravity and determination.

use super::fig_common::*;
use crate::games::iq::item::{IqItem, IqOption};
use crate::rng::Rng;
use serde_json::{json, Value};
use std::collections::HashMap;

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
enum FaceT {
    Floor,
    Top,
    Front,
    Right,
}

type Pic = HashMap<(i32, i32, bool), (FaceT, i32, i32)>;
type Owner = Option<(i32, i32, i32)>;

/// Frontmost face per lattice triangle: (depth, type, projected a, projected b, owner cube).
fn render(h: &[Vec<i32>]) -> HashMap<(i32, i32, bool), (i32, FaceT, i32, i32, Owner)> {
    let mut best: HashMap<(i32, i32, bool), (i32, FaceT, i32, i32, Owner)> = HashMap::new();
    let mut put = |tri: (i32, i32, bool), depth: i32, t: FaceT, a: i32, b: i32, o: Owner| {
        let e = best.entry(tri).or_insert((i32::MIN, t, a, b, o));
        if depth > e.0 {
            *e = (depth, t, a, b, o);
        }
    };
    for (x, col) in h.iter().enumerate() {
        for (y, &hh) in col.iter().enumerate() {
            let (x, y) = (x as i32, y as i32);
            // floor tile = top face of a virtual cube at z = -1
            let (a, b) = (x + 1, y - 1);
            put((a - 1, b + 1, false), x - y - 1, FaceT::Floor, a, b, None);
            put((a - 1, b + 1, true), x - y - 1, FaceT::Floor, a, b, None);
            for z in 0..hh {
                let (a, b) = (x - z, y + z);
                let d = x - y + z;
                let o = Some((x, y, z));
                put((a - 1, b + 1, false), d, FaceT::Top, a, b, o);
                put((a - 1, b + 1, true), d, FaceT::Top, a, b, o);
                put((a, b, false), d, FaceT::Front, a, b, o);
                put((a - 1, b, true), d, FaceT::Front, a, b, o);
                put((a, b, true), d, FaceT::Right, a, b, o);
                put((a, b + 1, false), d, FaceT::Right, a, b, o);
            }
        }
    }
    best
}

/// What the eye sees: per triangle, the face type and its projected position (edges between
/// faces are visible, so the face identity matters, not which cube along the ray owns it).
fn picture(h: &[Vec<i32>]) -> Pic {
    render(h).into_iter().map(|(k, (_, t, a, b, _))| (k, (t, a, b))).collect()
}

fn total(h: &[Vec<i32>]) -> i32 {
    h.iter().flatten().sum()
}

/// Cubes with at least one visible triangle.
fn visible_cubes(h: &[Vec<i32>]) -> i32 {
    let mut owners: Vec<(i32, i32, i32)> = render(h).values().filter_map(|v| v.4).collect();
    owners.sort();
    owners.dedup();
    owners.len() as i32
}

/// True when the picture pins down the total.
fn determined(h: &[Vec<i32>], hmax: i32, rng: &mut Rng) -> bool {
    let pic = picture(h);
    let t = total(h);
    let (w, d) = (h.len(), h[0].len());
    let same = |g: &[Vec<i32>]| picture(g) == pic;
    for x in 0..w {
        for y in 0..d {
            for v in 0..=hmax + 1 {
                if v == h[x][y] {
                    continue;
                }
                let mut g = h.to_vec();
                g[x][y] = v;
                if same(&g) && total(&g) != t {
                    return false;
                }
            }
        }
    }
    let cells: Vec<(usize, usize)> = (0..w).flat_map(|x| (0..d).map(move |y| (x, y))).collect();
    // Columns on one view diagonal (same x + y) can trade cubes along the line of sight (a
    // short column right behind a tall one reads as one taller column): try every height
    // combination on each diagonal.
    for s in 0..(w + d - 1) {
        let diag: Vec<(usize, usize)> = cells.iter().copied().filter(|&(x, y)| x + y == s).collect();
        if diag.len() < 2 {
            continue;
        }
        let base = (hmax + 2) as usize;
        let combos = base.pow(diag.len() as u32);
        for code in 0..combos {
            let mut g = h.to_vec();
            let mut k = code;
            for &(x, y) in &diag {
                g[x][y] = (k % base) as i32;
                k /= base;
            }
            if g != h && same(&g) && total(&g) != t {
                return false;
            }
        }
    }
    for i in 0..cells.len() {
        for j in i + 1..cells.len() {
            for (da, db) in [(1, 1), (1, -1), (-1, 1), (-1, -1)] {
                let mut g = h.to_vec();
                let (a, b) = (cells[i], cells[j]);
                g[a.0][a.1] += da;
                g[b.0][b.1] += db;
                if g[a.0][a.1] < 0 || g[b.0][b.1] < 0 {
                    continue;
                }
                if same(&g) && total(&g) != t {
                    return false;
                }
            }
        }
    }
    for _ in 0..300 {
        let mut g = h.to_vec();
        for _ in 0..3 {
            let (x, y) = cells[rng.below(cells.len())];
            g[x][y] = rng.range(0, hmax as i64 + 1) as i32;
        }
        if same(&g) && total(&g) != t {
            return false;
        }
    }
    true
}

fn stack_json(h: &[Vec<i32>], box_h: i32, ask_fill: bool) -> Value {
    let mut cubes = vec![];
    for (x, col) in h.iter().enumerate() {
        for (y, &hh) in col.iter().enumerate() {
            for z in 0..hh {
                cubes.push(json!([x, y, z]));
            }
        }
    }
    let mut v = json!({
        "k": "stack",
        "w": 2,
        "h": 2,
        "dims": [h.len(), h[0].len(), box_h],
        "cubes": cubes,
    });
    if ask_fill {
        v["ask"] = json!("fill");
    } else {
        v["ask"] = json!("count");
    }
    v
}

// ------------------------------------------------------------------------------------- oracle

pub fn oracle(item: &IqItem) -> Result<usize, String> {
    let fig = item.figure.as_ref().ok_or("no figure")?;
    let dims = fig["dims"].as_array().ok_or("dims")?;
    let (w, d, bh) = (dims[0].as_i64().ok_or("w")? as usize, dims[1].as_i64().ok_or("d")? as usize, dims[2].as_i64().ok_or("h")? as i32);
    let mut vox = vec![vec![vec![false; bh as usize + 2]; d]; w];
    let mut count = 0;
    for c in fig["cubes"].as_array().ok_or("cubes")? {
        let (x, y, z) = (c[0].as_i64().ok_or("x")? as usize, c[1].as_i64().ok_or("y")? as usize, c[2].as_i64().ok_or("z")? as usize);
        if x >= w || y >= d || z >= bh as usize || vox[x][y][z] {
            return Err("cube out of the box or repeated".into());
        }
        vox[x][y][z] = true;
        count += 1;
    }
    // gravity: no cube floats
    let mut h = vec![vec![0i32; d]; w];
    for x in 0..w {
        for y in 0..d {
            let top = (0..bh as usize).filter(|&z| vox[x][y][z]).count();
            if (0..top).any(|z| !vox[x][y][z]) {
                return Err("floating cube".into());
            }
            h[x][y] = top as i32;
        }
    }
    let mut rng = Rng::new(count as u64);
    if !determined(&h, bh, &mut rng) {
        return Err("the picture does not determine the count".into());
    }
    let want = if fig["ask"] == "fill" { (w * d) as i32 * bh - count } else { count };
    let ok: Vec<bool> = item.options.iter().map(|o| opt_text(o).trim().parse::<i32>() == Ok(want)).collect();
    if !all_distinct(&item.options) {
        return Err("duplicate options".into());
    }
    unique_index(&ok)
}

// ---------------------------------------------------------------------------------- generator

fn random_heights(rng: &mut Rng, w: usize, d: usize, hmax: i32) -> Vec<Vec<i32>> {
    // taller at the back-left so that the stack reads well; random otherwise
    (0..w)
        .map(|x| {
            (0..d)
                .map(|y| {
                    let bias = (d - 1 - y) as i32 + (w - 1 - x) as i32 / 2;
                    let top = (1 + bias).min(hmax);
                    if rng.chance(0.12) {
                        0
                    } else {
                        rng.range(1, top as i64) as i32
                    }
                })
                .collect()
        })
        .collect()
}

pub fn generate(rng: &mut Rng, hard: bool) -> IqItem {
    loop {
        let (w, d, hmax) = if hard { *rng.pick(&[(4usize, 3usize, 4i32), (3, 4, 4), (4, 4, 3)]) } else { (3, 3, 3) };
        let h = random_heights(rng, w, d, hmax);
        let t = total(&h);
        let real_max = *h.iter().flatten().max().unwrap();
        if real_max < 2 || t < 6 {
            continue;
        }
        let hidden = t - visible_cubes(&h);
        if hidden < if hard { 2 } else { 1 } {
            continue; // the item should need the "hidden supports" reasoning
        }
        if !determined(&h, hmax, rng) {
            continue;
        }
        let ask_fill = hard && rng.chance(0.4);
        let box_h = if ask_fill { real_max } else { hmax };
        let answer = if ask_fill { (w * d) as i32 * box_h - t } else { t };
        if answer < 3 {
            continue;
        }
        // Bug models, then near counts; the answer's rank among the options is random.
        let vis = visible_cubes(&h);
        let cols = h.iter().flatten().filter(|&&v| v > 0).count() as i32;
        let bugs: Vec<i32> = if ask_fill {
            vec![(w * d) as i32 * box_h - vis, (w * d) as i32 * box_h, t, answer + box_h]
        } else {
            vec![vis, cols, t + hidden]
        };
        let rank = rng.below(5);
        let mut below: Vec<i32> = vec![];
        let mut above: Vec<i32> = vec![];
        for b in bugs.iter().copied().chain([answer - 1, answer + 1, answer - 2, answer + 2, answer - 3, answer + 3, answer - 4, answer + 4]) {
            if b <= 0 || b == answer || below.contains(&b) || above.contains(&b) {
                continue;
            }
            if b < answer && below.len() < rank {
                below.push(b);
            } else if b > answer && above.len() < 4 - rank {
                above.push(b);
            }
        }
        if below.len() != rank || above.len() != 4 - rank {
            continue;
        }
        let ds: Vec<IqOption> = below.iter().chain(&above).map(|v| IqOption::Text(v.to_string())).collect();
        let (prompt, why) = if ask_fill {
            (
                format!(
                    "Bu yapıyı {w}×{d}×{box_h} boyutunda dolu bir kutuya tamamlamak için kaç küp daha gerekir? (Her küp yere ya da başka bir küpün üstüne oturuyor; görünmeyen boşluk yok.)"
                ),
                format!(
                    "Kutu {w}×{d}×{box_h} = {} küp alır. Yapıda {t} küp var ({vis} tanesi görünüyor, {hidden} tanesi öndekilerin arkasında ya da altında). {} − {t} = {answer}.",
                    (w * d) as i32 * box_h,
                    (w * d) as i32 * box_h
                ),
            )
        } else {
            (
                "Bu yapıda kaç küp var? (Her küp yere ya da başka bir küpün üstüne oturuyor; görünmeyen boşluk yok.)".into(),
                format!(
                    "Sütun sütun say: her sütundaki küp sayısı en üstteki küpün yüksekliğine eşit. Toplam {t} küp; bunların {hidden} tanesi görünmüyor, sadece görünenleri saymak {vis} verir."
                ),
            )
        };
        let item = finish(rng, "block_count", hard, prompt, Some(stack_json(&h, box_h, ask_fill)), IqOption::Text(answer.to_string()), ds, why);
        if oracle(&item) == Ok(item.answer) {
            return item;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hidden_column_is_not_determined() {
        let mut rng = Rng::new(1);
        // h[x][y]: the 1-high column at (0, 1) sits exactly behind the 3-high column at (1, 0)
        assert!(!determined(&[vec![0, 1], vec![3, 0]], 3, &mut rng));
        assert!(determined(&[vec![1, 1], vec![1, 1]], 3, &mut rng));
        assert_eq!(visible_cubes(&[vec![0, 1], vec![3, 0]]), 3);
        // a 3-high column right behind a 2-high one: the top of the front column shows as a
        // ledge, so it does not read as one 4-high column and the count is determined
        let mut h = vec![vec![0; 3]; 3];
        h[1][0] = 2;
        h[0][1] = 3;
        h[0][2] = 1;
        h[1][2] = 1;
        h[2][2] = 1;
        let mut g = h.clone();
        g[1][0] = 4;
        g[0][1] = 0;
        assert_ne!(picture(&h), picture(&g));
        assert!(determined(&h, 3, &mut rng));
    }
}
