//! Cube categories: `cube_rotation` (ICAR-style 3D rotation) and `cube_net` (fold a net).
//!
//! Frame: x right, y back, z up. A view shows the top (+z), front (−y) and right (+x) faces; each
//! face glyph has an "up" direction. Canonical in-face frames (seen from outside):
//! top: up = +y, right = +x; front: up = +z, right = +x; right face: up = +z, right = +y.
//! A glyph `rot` k means its up is the face's up turned k × 90° clockwise.
//!
//! cube_rotation — two reference views share exactly one face, so five faces are known. Medium:
//! symmetric symbols; distractors show two opposite faces together or a mirrored corner.
//! Hard: oriented symbols too; distractors are mirrored corners, wrongly turned glyphs and
//! swapped faces. Oracle: enumerate every labelling consistent with both views (24 rotations
//! for the second view), then for each option search the 24 rotations: the answer must be a
//! certain view in every labelling; each distractor impossible in every labelling (an unknown
//! face may hold any unused symbol).
//!
//! cube_net — the 11 nets (1-4-1 for medium, the other five for hard). The generator folds by
//! propagating face frames across the net; the oracle folds independently by rolling a cube
//! across the net cells (rotation matrices), then matches options against the 24 rotations.

use super::fig_common::*;
use crate::games::iq::item::{IqItem, IqOption};
use crate::rng::Rng;
use serde_json::{json, Value};

type V3 = [i32; 3];
type M3 = [[i32; 3]; 3];

fn neg(a: V3) -> V3 {
    [-a[0], -a[1], -a[2]]
}

fn mul(m: &M3, v: V3) -> V3 {
    [0, 1, 2].map(|i| m[i][0] * v[0] + m[i][1] * v[1] + m[i][2] * v[2])
}

fn mm(a: &M3, b: &M3) -> M3 {
    let mut c = [[0; 3]; 3];
    for i in 0..3 {
        for j in 0..3 {
            c[i][j] = (0..3).map(|k| a[i][k] * b[k][j]).sum();
        }
    }
    c
}

fn transpose(a: &M3) -> M3 {
    let mut c = [[0; 3]; 3];
    for i in 0..3 {
        for j in 0..3 {
            c[i][j] = a[j][i];
        }
    }
    c
}

fn det(m: &M3) -> i32 {
    m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
        + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
}

/// The 24 proper rotations (signed permutation matrices with det +1).
pub fn rotations24() -> Vec<M3> {
    let perms = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]];
    let mut out = vec![];
    for p in perms {
        for s in 0..8 {
            let mut m = [[0; 3]; 3];
            for i in 0..3 {
                m[i][p[i]] = if s >> i & 1 == 1 { -1 } else { 1 };
            }
            if det(&m) == 1 {
                out.push(m);
            }
        }
    }
    out
}

const TOP: V3 = [0, 0, 1];
const FRONT: V3 = [0, -1, 0];
const RIGHT: V3 = [1, 0, 0];
/// (normal, canonical up, canonical right) for the three visible faces.
const VIS: [(V3, V3, V3); 3] = [(TOP, [0, 1, 0], [1, 0, 0]), (FRONT, [0, 0, 1], [1, 0, 0]), (RIGHT, [0, 0, 1], [0, 1, 0])];

/// Symmetric glyphs (4-fold, so their turn never matters). No "x": on the top face of an
/// isometric cube an x and a plus are easy to confuse.
pub const PLAIN: [&str; 7] = ["dot", "ring", "square", "plus", "target", "diamond", "dots4"];
pub const ORIENTED: [&str; 4] = ["arrow", "triangle", "half", "corner"];

fn oriented(sym: &str) -> bool {
    ORIENTED.contains(&sym)
}

fn tr_sym(s: &str) -> &'static str {
    match s {
        "dot" => "dolu daire",
        "ring" => "halka",
        "square" => "kare",
        "plus" => "artı",
        "target" => "hedef",
        "diamond" => "karo",
        "dots4" => "dört nokta",
        "arrow" => "ok",
        "triangle" => "üçgen",
        "half" => "yarım dolu kare",
        "corner" => "köşebent",
        _ => "?",
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Face {
    n: V3,
    sym: String,
    up: V3,
}

/// One visible face as drawn: (sym, rot).
type Glyph = (String, i64);
type View = [Glyph; 3];

fn rot_index(up: V3, cu: V3, cr: V3) -> i64 {
    [cu, cr, neg(cu), neg(cr)].iter().position(|&x| x == up).expect("glyph up lies in the face") as i64
}

fn up_of(rot: i64, cu: V3, cr: V3) -> V3 {
    [cu, cr, neg(cu), neg(cr)][rot.rem_euclid(4) as usize]
}

/// The view of a full labelling under rotation `q`.
fn view_of(faces: &[Face], q: &M3) -> View {
    VIS.map(|(t, cu, cr)| {
        let f = faces.iter().find(|f| mul(q, f.n) == t).expect("face");
        let rot = if oriented(&f.sym) { rot_index(mul(q, f.up), cu, cr) } else { 0 };
        (f.sym.clone(), rot)
    })
}

fn glyph_json(g: &Glyph) -> Value {
    json!({ "sym": g.0, "rot": g.1 })
}

fn cube_json(v: &View) -> Value {
    json!({ "k": "cube", "w": 1, "h": 1, "top": glyph_json(&v[0]), "front": glyph_json(&v[1]), "right": glyph_json(&v[2]) })
}

fn parse_view(v: &Value) -> Result<View, String> {
    if v["k"] != "cube" {
        return Err("not a cube".into());
    }
    let g = |k: &str| -> Result<Glyph, String> {
        Ok((v[k]["sym"].as_str().ok_or("sym")?.to_string(), v[k]["rot"].as_i64().ok_or("rot")?))
    };
    Ok([g("top")?, g("front")?, g("right")?])
}

// --------------------------------------------------------------------------- partial labellings

/// Faces of a partial labelling (6 slots by normal; `None` = never seen).
type Partial = Vec<(V3, Option<(String, V3)>)>;

const NORMALS: [V3; 6] = [[0, 0, 1], [0, 0, -1], [0, -1, 0], [0, 1, 0], [1, 0, 0], [-1, 0, 0]];

fn place(p: &mut Partial, view: &View, q: &M3) -> bool {
    let qi = transpose(q);
    for (k, (t, cu, cr)) in VIS.iter().enumerate() {
        let n = mul(&qi, *t);
        let up = mul(&qi, up_of(view[k].1, *cu, *cr));
        let slot = p.iter().position(|(m, _)| *m == n).unwrap();
        match &p[slot].1 {
            Some((s, u)) => {
                if *s != view[k].0 || (oriented(s) && *u != up) {
                    return false;
                }
            }
            None => {
                if p.iter().any(|(_, f)| matches!(f, Some((s, _)) if *s == view[k].0)) {
                    return false;
                }
                let up = if oriented(&view[k].0) { up } else { [0, 0, 0] };
                p[slot].1 = Some((view[k].0.clone(), up));
            }
        }
    }
    true
}

/// Labellings consistent with every reference view (the first view fixes the frame).
fn consistent(views: &[View]) -> Vec<Partial> {
    let mut base: Partial = NORMALS.iter().map(|&n| (n, None)).collect();
    let id = [[1, 0, 0], [0, 1, 0], [0, 0, 1]];
    if !place(&mut base, &views[0], &id) {
        return vec![];
    }
    let mut out = vec![base];
    for v in &views[1..] {
        let mut next = vec![];
        for p in &out {
            for q in rotations24() {
                let mut c = p.clone();
                if place(&mut c, v, &q) && !next.contains(&c) {
                    next.push(c);
                }
            }
        }
        out = next;
    }
    out
}

/// (certain, possible) for `view` in labelling `p`.
fn check_view(p: &Partial, view: &View) -> (bool, bool) {
    let mut certain = false;
    let mut possible = false;
    if view[0].0 == view[1].0 || view[0].0 == view[2].0 || view[1].0 == view[2].0 {
        return (false, false);
    }
    for q in rotations24() {
        let qi = transpose(&q);
        let mut all_known = true;
        let mut ok = true;
        for (k, (t, cu, cr)) in VIS.iter().enumerate() {
            let n = mul(&qi, *t);
            let up = mul(&qi, up_of(view[k].1, *cu, *cr));
            match &p.iter().find(|(m, _)| *m == n).unwrap().1 {
                Some((s, u)) => {
                    if *s != view[k].0 || (oriented(s) && *u != up) {
                        ok = false;
                    }
                }
                None => {
                    all_known = false;
                    if p.iter().any(|(_, f)| matches!(f, Some((s, _)) if *s == view[k].0)) {
                        ok = false;
                    }
                }
            }
        }
        if ok {
            possible = true;
            if all_known {
                certain = true;
            }
        }
    }
    (certain, possible)
}

fn judge(labellings: &[Partial], opts: &[View]) -> Result<usize, String> {
    if labellings.is_empty() {
        return Err("reference views are inconsistent".into());
    }
    let mut ok = vec![];
    for (i, o) in opts.iter().enumerate() {
        let r: Vec<(bool, bool)> = labellings.iter().map(|p| check_view(p, o)).collect();
        let certain = r.iter().all(|x| x.0);
        let impossible = r.iter().all(|x| !x.1);
        if !certain && !impossible {
            return Err(format!("option {i} is undecidable"));
        }
        ok.push(certain);
    }
    unique_index(&ok)
}

pub fn rotation_oracle(item: &IqItem) -> Result<usize, String> {
    let fig = item.figure.as_ref().ok_or("no figure")?;
    let refs: Vec<View> = fig["cells"].as_array().ok_or("cells")?.iter().map(parse_view).collect::<Result<_, _>>()?;
    let opts: Vec<View> = item.options.iter().map(|o| parse_view(opt_fig(o))).collect::<Result<_, _>>()?;
    if !all_distinct(&item.options) {
        return Err("duplicate options".into());
    }
    judge(&consistent(&refs), &opts)
}

// ------------------------------------------------------------------------------ generation

fn random_cube(rng: &mut Rng, hard: bool) -> Vec<Face> {
    let mut plain = PLAIN.to_vec();
    rng.shuffle(&mut plain);
    let mut ori = ORIENTED.to_vec();
    rng.shuffle(&mut ori);
    let n_or = if hard { rng.range(3, 4) as usize } else { 0 };
    let mut syms: Vec<&str> = ori.into_iter().take(n_or).collect();
    syms.extend(plain.into_iter().take(6 - n_or));
    rng.shuffle(&mut syms);
    NORMALS
        .iter()
        .zip(syms)
        .map(|(&n, s)| {
            // any of the 4 in-face directions
            let ups: Vec<V3> = NORMALS.iter().copied().filter(|u| *u != n && *u != neg(n)).collect();
            Face { n, sym: s.to_string(), up: ups[rng.below(4)] }
        })
        .collect()
}

fn visible_normals(q: &M3) -> Vec<V3> {
    let qi = transpose(q);
    VIS.iter().map(|(t, _, _)| mul(&qi, *t)).collect()
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Bug {
    Opposite,
    Mirror,
    Turned,
    Swap,
}

/// A distractor built from an independent random view by one typical mistake.
fn bug_view(rng: &mut Rng, faces: &[Face], known: &[V3], bug: Bug) -> Option<View> {
    let rots = rotations24();
    let q = rots[rng.below(24)];
    if !visible_normals(&q).iter().all(|n| known.contains(n)) {
        return None;
    }
    let mut v = view_of(faces, &q);
    match bug {
        Bug::Opposite => {
            // replace one visible face by the face opposite another visible face
            let vis = visible_normals(&q);
            let (a, b) = (rng.below(3), rng.below(3));
            if a == b {
                return None;
            }
            let opp = neg(vis[b]);
            if !known.contains(&opp) {
                return None;
            }
            let f = faces.iter().find(|f| f.n == opp).unwrap();
            v[a] = (f.sym.clone(), if oriented(&f.sym) { rng.range(0, 3) } else { 0 });
        }
        Bug::Mirror => {
            // swap front and right: the corner read in the opposite turning sense
            v.swap(1, 2);
        }
        Bug::Turned => {
            let ks: Vec<usize> = (0..3).filter(|&k| oriented(&v[k].0)).collect();
            if ks.is_empty() {
                return None;
            }
            let k = ks[rng.below(ks.len())];
            v[k].1 = (v[k].1 + rng.range(1, 3)).rem_euclid(4);
        }
        Bug::Swap => {
            let (a, b) = if rng.chance(0.5) { (0, 1) } else { (0, 2) };
            v.swap(a, b);
        }
    }
    Some(v)
}

fn bugs_for(hard: bool) -> Vec<Bug> {
    if hard {
        vec![Bug::Mirror, Bug::Turned, Bug::Swap, Bug::Turned, Bug::Opposite]
    } else {
        vec![Bug::Opposite, Bug::Mirror, Bug::Opposite, Bug::Mirror, Bug::Swap]
    }
}

fn bug_tr(b: Bug) -> &'static str {
    match b {
        Bug::Opposite => "karşılıklı iki yüz yan yana gösterilmiş (aynı anda görünemezler)",
        Bug::Mirror => "yüzlerin dönüş sırası ayna görüntüsü gibi ters",
        Bug::Turned => "bir sembolün yönü yanlış",
        Bug::Swap => "iki yüzün yeri değişmiş",
    }
}

/// Pick 4 distractors whose verdict is "impossible" under `labellings`.
fn distractors(rng: &mut Rng, faces: &[Face], known: &[V3], hard: bool, labellings: &[Partial], answer: &View) -> Option<(Vec<View>, Vec<Bug>)> {
    let mut out: Vec<View> = vec![];
    let mut kinds: Vec<Bug> = vec![];
    let plan = bugs_for(hard);
    let mut tries = 0;
    while out.len() < 4 {
        tries += 1;
        if tries > 400 {
            return None;
        }
        let bug = plan[out.len()];
        let Some(v) = bug_view(rng, faces, known, bug) else { continue };
        if v == *answer || out.contains(&v) {
            continue;
        }
        if labellings.iter().all(|p| !check_view(p, &v).1) {
            out.push(v);
            kinds.push(bug);
        }
    }
    Some((out, kinds))
}

fn opposite_pairs(faces: &[Face], known: &[V3]) -> Vec<String> {
    let mut v = vec![];
    for n in [TOP, FRONT, RIGHT] {
        if known.contains(&n) && known.contains(&neg(n)) {
            let a = faces.iter().find(|f| f.n == n).unwrap();
            let b = faces.iter().find(|f| f.n == neg(n)).unwrap();
            v.push(format!("{}–{}", tr_sym(&a.sym), tr_sym(&b.sym)));
        }
    }
    v
}

fn kinds_text(kinds: &[Bug]) -> String {
    let mut k: Vec<Bug> = vec![];
    for &b in kinds {
        if !k.contains(&b) {
            k.push(b);
        }
    }
    let parts: Vec<String> = k.iter().map(|&b| bug_tr(b).to_string()).collect();
    format!("Yanlış seçeneklerde {}.", tr_list(&parts))
}

pub fn generate_rotation(rng: &mut Rng, hard: bool) -> IqItem {
    let rots = rotations24();
    loop {
        let faces = random_cube(rng, hard);
        let q1 = rots[rng.below(24)];
        let q2 = rots[rng.below(24)];
        let (v1, v2) = (visible_normals(&q1), visible_normals(&q2));
        if v1.iter().filter(|n| v2.contains(n)).count() != 1 {
            continue;
        }
        let known: Vec<V3> = v1.iter().chain(&v2).copied().collect();
        let (r1, r2) = (view_of(&faces, &q1), view_of(&faces, &q2));
        let labellings = consistent(&[r1.clone(), r2.clone()]);
        if labellings.len() != 1 {
            continue;
        }
        let q3 = rots[rng.below(24)];
        if !visible_normals(&q3).iter().all(|n| known.contains(n)) {
            continue;
        }
        let ans = view_of(&faces, &q3);
        if ans == r1 || ans == r2 {
            continue;
        }
        let Some((ds, kinds)) = distractors(rng, &faces, &known, hard, &labellings, &ans) else { continue };
        let pairs = opposite_pairs(&faces, &known);
        let why = format!(
            "İki görünümden beş yüz ve yerleri belli olur{}. Doğru seçenek küpün başka bir yönden görünüşü. {}",
            if pairs.is_empty() { String::new() } else { format!("; karşılıklı yüzler: {}", pairs.join(", ")) },
            kinds_text(&kinds)
        );
        let fig = grid(1, 2, vec![cube_json(&r1), cube_json(&r2)], None);
        let item = finish(
            rng,
            "cube_rotation",
            hard,
            "Üstteki iki görünüm aynı küpe ait; her yüzde farklı bir sembol var. Seçeneklerden hangisi de bu küpün bir görünümüdür?".into(),
            Some(fig),
            IqOption::Figure(cube_json(&ans)),
            ds.iter().map(|v| IqOption::Figure(cube_json(v))).collect(),
            why,
        );
        if rotation_oracle(&item) == Ok(item.answer) {
            return item;
        }
    }
}

// ----------------------------------------------------------------------------------- nets

/// The 11 cube nets (x right, y down). The first six are the 1-4-1 family.
pub const NETS: [[(i32, i32); 6]; 11] = [
    [(0, 0), (0, 1), (1, 1), (2, 1), (3, 1), (0, 2)],
    [(0, 0), (0, 1), (1, 1), (2, 1), (3, 1), (1, 2)],
    [(0, 0), (0, 1), (1, 1), (2, 1), (3, 1), (2, 2)],
    [(0, 0), (0, 1), (1, 1), (2, 1), (3, 1), (3, 2)],
    [(1, 0), (0, 1), (1, 1), (2, 1), (3, 1), (1, 2)],
    [(1, 0), (0, 1), (1, 1), (2, 1), (3, 1), (2, 2)],
    [(0, 0), (1, 0), (1, 1), (2, 1), (3, 1), (1, 2)],
    [(0, 0), (1, 0), (1, 1), (2, 1), (3, 1), (2, 2)],
    [(0, 0), (1, 0), (1, 1), (2, 1), (3, 1), (3, 2)],
    [(0, 0), (1, 0), (1, 1), (2, 1), (2, 2), (3, 2)],
    [(0, 0), (1, 0), (2, 0), (2, 1), (3, 1), (4, 1)],
];

/// Generator's fold: propagate (right, up, normal) frames from the first cell.
fn fold_frames(cells: &[(i32, i32)], glyphs: &[Glyph]) -> Option<Vec<Face>> {
    let mut frames: Vec<Option<(V3, V3, V3)>> = vec![None; cells.len()];
    frames[0] = Some(([1, 0, 0], [0, 1, 0], [0, 0, 1]));
    let mut queue = vec![0usize];
    while let Some(i) = queue.pop() {
        let (r, u, n) = frames[i].unwrap();
        let (x, y) = cells[i];
        for (dx, dy, f) in [
            (1, 0, (neg(n), u, r)),
            (-1, 0, (n, u, neg(r))),
            (0, -1, (r, neg(n), u)),
            (0, 1, (r, n, neg(u))),
        ] {
            if let Some(j) = cells.iter().position(|&c| c == (x + dx, y + dy)) {
                if frames[j].is_none() {
                    frames[j] = Some(f);
                    queue.push(j);
                }
            }
        }
    }
    let mut faces = vec![];
    for (k, fr) in frames.iter().enumerate() {
        let (r, u, n) = (*fr)?;
        let up = [u, r, neg(u), neg(r)][glyphs[k].1.rem_euclid(4) as usize];
        faces.push(Face { n, sym: glyphs[k].0.clone(), up });
    }
    let mut ns: Vec<V3> = faces.iter().map(|f| f.n).collect();
    ns.sort();
    ns.dedup();
    (ns.len() == 6).then_some(faces)
}

/// Oracle's fold: roll a cube across the net; the cell under the cube labels its top face.
fn fold_rolling(cells: &[(i32, i32)], glyphs: &[Glyph]) -> Option<Vec<Face>> {
    let id: M3 = [[1, 0, 0], [0, 1, 0], [0, 0, 1]];
    // world rotations that bring the face on the given side to the top
    let to_top = |dx: i32, dy: i32| -> M3 {
        match (dx, dy) {
            (1, 0) => [[0, 0, -1], [0, 1, 0], [1, 0, 0]],
            (-1, 0) => [[0, 0, 1], [0, 1, 0], [-1, 0, 0]],
            (0, -1) => [[1, 0, 0], [0, 0, -1], [0, 1, 0]],
            _ => [[1, 0, 0], [0, 0, 1], [0, -1, 0]],
        }
    };
    let mut state: Vec<Option<M3>> = vec![None; cells.len()];
    state[0] = Some(id);
    let mut queue = vec![0usize];
    while let Some(i) = queue.pop() {
        let m = state[i].unwrap();
        let (x, y) = cells[i];
        for (dx, dy) in [(1, 0), (-1, 0), (0, -1), (0, 1)] {
            if let Some(j) = cells.iter().position(|&c| c == (x + dx, y + dy)) {
                if state[j].is_none() {
                    state[j] = Some(mm(&to_top(dx, dy), &m));
                    queue.push(j);
                }
            }
        }
    }
    let mut faces = vec![];
    for (k, s) in state.iter().enumerate() {
        let mi = transpose(&(*s)?);
        // net up = world +y, net right = world +x (seen from above)
        let g = [[0, 1, 0], [1, 0, 0], [0, -1, 0], [-1, 0, 0]][glyphs[k].1.rem_euclid(4) as usize];
        faces.push(Face { n: mul(&mi, [0, 0, 1]), sym: glyphs[k].0.clone(), up: mul(&mi, g) });
    }
    let mut ns: Vec<V3> = faces.iter().map(|f| f.n).collect();
    ns.sort();
    ns.dedup();
    (ns.len() == 6).then_some(faces)
}

fn net_json(cells: &[(i32, i32)], glyphs: &[Glyph]) -> Value {
    let cols = cells.iter().map(|c| c.0).max().unwrap() + 1;
    let rows = cells.iter().map(|c| c.1).max().unwrap() + 1;
    json!({
        "k": "net",
        "w": f3(cols as f64 * 0.5),
        "h": f3(rows as f64 * 0.5),
        "cols": cols,
        "rows": rows,
        "cells": cells.iter().zip(glyphs).map(|(&(x, y), g)| json!({ "x": x, "y": y, "sym": g.0, "rot": g.1 })).collect::<Vec<_>>(),
    })
}

pub fn net_oracle(item: &IqItem) -> Result<usize, String> {
    let fig = item.figure.as_ref().ok_or("no figure")?;
    let mut cells = vec![];
    let mut glyphs = vec![];
    for c in fig["cells"].as_array().ok_or("cells")? {
        cells.push((c["x"].as_i64().ok_or("x")? as i32, c["y"].as_i64().ok_or("y")? as i32));
        glyphs.push((c["sym"].as_str().ok_or("sym")?.to_string(), c["rot"].as_i64().ok_or("rot")?));
    }
    let faces = fold_rolling(&cells, &glyphs).ok_or("not a cube net")?;
    let full: Partial = faces.iter().map(|f| (f.n, Some((f.sym.clone(), f.up)))).collect();
    let opts: Vec<View> = item.options.iter().map(|o| parse_view(opt_fig(o))).collect::<Result<_, _>>()?;
    if !all_distinct(&item.options) {
        return Err("duplicate options".into());
    }
    judge(&[full], &opts)
}

fn transform_net(rng: &mut Rng, net: &[(i32, i32)]) -> Vec<(i32, i32)> {
    let k = rng.below(4);
    let flip = rng.chance(0.5);
    let mut c: Vec<(i32, i32)> = net.iter().map(|&(x, y)| if flip { (-x, y) } else { (x, y) }).collect();
    for _ in 0..k {
        c = c.iter().map(|&(x, y)| (-y, x)).collect();
    }
    let mx = c.iter().map(|p| p.0).min().unwrap();
    let my = c.iter().map(|p| p.1).min().unwrap();
    c.iter().map(|&(x, y)| (x - mx, y - my)).collect()
}

pub fn generate_net(rng: &mut Rng, hard: bool) -> IqItem {
    let rots = rotations24();
    loop {
        let base = if hard { NETS[rng.range(6, 10) as usize] } else { NETS[rng.below(6)] };
        let cells = transform_net(rng, &base);
        let mut plain = PLAIN.to_vec();
        rng.shuffle(&mut plain);
        let mut ori = ORIENTED.to_vec();
        rng.shuffle(&mut ori);
        let n_or = if hard { rng.range(3, 4) as usize } else { 0 };
        let mut syms: Vec<&str> = ori.into_iter().take(n_or).collect();
        syms.extend(plain.into_iter().take(6 - n_or));
        rng.shuffle(&mut syms);
        let glyphs: Vec<Glyph> =
            syms.iter().map(|s| (s.to_string(), if oriented(s) { rng.range(0, 3) } else { 0 })).collect();
        let Some(faces) = fold_frames(&cells, &glyphs) else { continue };
        let ans = view_of(&faces, &rots[rng.below(24)]);
        let known: Vec<V3> = NORMALS.to_vec();
        let full: Partial = faces.iter().map(|f| (f.n, Some((f.sym.clone(), f.up)))).collect();
        let Some((ds, kinds)) = distractors(rng, &faces, &known, hard, &[full], &ans) else { continue };
        let pairs = opposite_pairs(&faces, &known);
        let why = format!(
            "Katlayınca karşılıklı gelen yüzler: {}. Karşılıklı yüzler aynı anda görünemez. {}{}",
            pairs.join(", "),
            if hard { "Yönü olan sembollerde, katlanınca okun ya da üçgenin hangi kenara baktığına da dikkat et. " } else { "" },
            kinds_text(&kinds)
        );
        let item = finish(
            rng,
            "cube_net",
            hard,
            "Bu açınım katlanınca hangi küp elde edilir?".into(),
            Some(net_json(&cells, &glyphs)),
            IqOption::Figure(cube_json(&ans)),
            ds.iter().map(|v| IqOption::Figure(cube_json(v))).collect(),
            why,
        );
        if net_oracle(&item) == Ok(item.answer) {
            return item;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rotation_group_and_nets() {
        let r = rotations24();
        assert_eq!(r.len(), 24);
        let plain: Vec<Glyph> = PLAIN[..6].iter().map(|s| (s.to_string(), 0)).collect();
        for net in NETS {
            let a = fold_frames(&net, &plain).expect("frames fold");
            let b = fold_rolling(&net, &plain).expect("rolling folds");
            for f in &a {
                assert!(b.iter().any(|g| g.n == f.n && g.sym == f.sym), "{net:?}");
            }
        }
        // both folds agree on glyph directions too
        let mut rng = Rng::new(5);
        for net in NETS {
            let g: Vec<Glyph> = (0..6).map(|i| (ORIENTED[i % 4].to_string() + &"x".repeat(i / 4), rng.range(0, 3))).collect();
            let a = fold_frames(&net, &g).unwrap();
            let b = fold_rolling(&net, &g).unwrap();
            assert_eq!(a.len(), b.len());
            for f in &a {
                assert!(b.contains(f), "{net:?}: {f:?}");
            }
        }
        // cross net: the cells two apart in the long row are opposite
        let f = fold_frames(&NETS[4], &plain).unwrap();
        assert_eq!(f[1].n, neg(f[3].n));
    }
}
