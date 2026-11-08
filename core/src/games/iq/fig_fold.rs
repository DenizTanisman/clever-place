//! `paper_fold`: a square sheet is folded 1–3 times, punched, and unfolded.
//!
//! All geometry is exact on a doubled integer lattice (cell centres are odd numbers). Folds are
//! symmetry axes of the current paper (vertical, horizontal, diagonal, anti-diagonal), so the
//! moving part lands exactly on the staying part. Medium: 4×4 sheet, 1–2 straight folds.
//! Hard: 6×6 sheet, 2–3 folds with at least one diagonal.
//!
//! Generator: unfold backwards (reflect every hole across each fold line, last fold first).
//! Oracle: forward simulation — every cell centre of the flat sheet is carried through the folds
//! described by the panels (line + arrow give the moving side); a cell is holed iff it lands on a
//! punch. It also re-clips the paper outline after every fold and checks the drawn panels.
//! Distractors keep the hole count: one wrong reflection axis, a punch one cell off, a mirrored
//! pattern; medium may add "forgot one unfold".

use super::fig_common::*;
use crate::games::iq::item::{IqItem, IqOption};
use crate::rng::Rng;
use serde_json::{json, Value};

type P = (i64, i64);

/// Line a·X + b·Y = c on the doubled lattice.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Line {
    a: i64,
    b: i64,
    c: i64,
}

impl Line {
    fn side(&self, p: P) -> i64 {
        (self.a * p.0 + self.b * p.1 - self.c).signum()
    }
    fn reflect(&self, p: P) -> P {
        let n2 = self.a * self.a + self.b * self.b;
        let d = self.a * p.0 + self.b * p.1 - self.c;
        // n2 ∈ {1, 2}: 2d/n2 is an integer
        let k = 2 * d / n2;
        (p.0 - k * self.a, p.1 - k * self.b)
    }
    fn diagonal(&self) -> bool {
        self.a != 0 && self.b != 0
    }
    /// The other axis through the same centre point (vertical ↔ horizontal, diagonal ↔ anti).
    fn other(&self, centre: P) -> Line {
        if self.diagonal() {
            let (a, b) = (self.a, -self.b);
            Line { a, b, c: a * centre.0 + b * centre.1 }
        } else {
            let (a, b) = (self.b, self.a);
            Line { a, b, c: a * centre.0 + b * centre.1 }
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct Fold {
    line: Line,
    /// side (+1 / −1) that moves
    moving: i64,
}

fn clip(poly: &[P], l: &Line, keep: i64) -> Vec<P> {
    // keep points with side == keep or on the line
    let mut out: Vec<P> = vec![];
    let n = poly.len();
    for i in 0..n {
        let (p, q) = (poly[i], poly[(i + 1) % n]);
        let (sp, sq) = (l.side(p), l.side(q));
        if sp == keep || sp == 0 {
            out.push(p);
        }
        if sp != 0 && sq != 0 && sp != sq {
            let fp = (l.a * p.0 + l.b * p.1 - l.c) as f64;
            let fq = (l.a * q.0 + l.b * q.1 - l.c) as f64;
            let t = fp / (fp - fq);
            let x = p.0 as f64 + t * (q.0 - p.0) as f64;
            let y = p.1 as f64 + t * (q.1 - p.1) as f64;
            out.push((x.round() as i64, y.round() as i64));
        }
    }
    out.dedup();
    if out.len() > 1 && out[0] == out[out.len() - 1] {
        out.pop();
    }
    out
}

fn same_poly(a: &[P], b: &[P]) -> bool {
    let mut x = a.to_vec();
    let mut y = b.to_vec();
    x.sort();
    y.sort();
    x == y
}

fn symmetric(poly: &[P], l: &Line) -> bool {
    let r: Vec<P> = poly.iter().map(|&p| l.reflect(p)).collect();
    same_poly(poly, &r)
}

/// Strictly inside a convex polygon.
fn inside(poly: &[P], p: P) -> bool {
    let n = poly.len();
    let mut sign = 0;
    for i in 0..n {
        let (a, b) = (poly[i], poly[(i + 1) % n]);
        let cr = (b.0 - a.0) * (p.1 - a.1) - (b.1 - a.1) * (p.0 - a.0);
        if cr == 0 {
            return false;
        }
        let s = cr.signum();
        if sign == 0 {
            sign = s;
        } else if s != sign {
            return false;
        }
    }
    true
}

fn centroid(poly: &[P]) -> (f64, f64) {
    let n = poly.len() as f64;
    (poly.iter().map(|p| p.0 as f64).sum::<f64>() / n, poly.iter().map(|p| p.1 as f64).sum::<f64>() / n)
}

fn bbox_centre(poly: &[P]) -> P {
    let (x0, x1) = (poly.iter().map(|p| p.0).min().unwrap(), poly.iter().map(|p| p.0).max().unwrap());
    let (y0, y1) = (poly.iter().map(|p| p.1).min().unwrap(), poly.iter().map(|p| p.1).max().unwrap());
    ((x0 + x1) / 2, (y0 + y1) / 2)
}

fn candidate_lines(poly: &[P]) -> Vec<Line> {
    let (cx, cy) = bbox_centre(poly);
    [Line { a: 1, b: 0, c: cx }, Line { a: 0, b: 1, c: cy }, Line { a: 1, b: -1, c: cx - cy }, Line { a: 1, b: 1, c: cx + cy }]
        .into_iter()
        .filter(|l| symmetric(poly, l))
        .collect()
}

fn unfold(holes: &[P], folds: &[Fold], skip: Option<usize>, swap_axis: Option<(usize, P)>) -> Vec<P> {
    let mut h: Vec<P> = holes.to_vec();
    for (k, f) in folds.iter().enumerate().rev() {
        if skip == Some(k) {
            continue;
        }
        let line = match swap_axis {
            Some((j, c)) if j == k => f.line.other(c),
            _ => f.line,
        };
        let mut add: Vec<P> = h.iter().map(|&p| line.reflect(p)).collect();
        h.append(&mut add);
        h.sort();
        h.dedup();
    }
    h
}

fn pt(p: P) -> Value {
    json!([f3(p.0 as f64 / 2.0), f3(p.1 as f64 / 2.0)])
}

fn sheet(n: i64, holes: &[P]) -> Value {
    let mut h = holes.to_vec();
    h.sort();
    json!({ "k": "sheet", "w": 1, "h": 1, "n": n, "holes": h.iter().map(|&p| pt(p)).collect::<Vec<_>>() })
}

/// Endpoints of the fold line inside the polygon.
fn chord(poly: &[P], l: &Line) -> (P, P) {
    let mut pts: Vec<(f64, f64)> = vec![];
    let n = poly.len();
    for i in 0..n {
        let (p, q) = (poly[i], poly[(i + 1) % n]);
        let fp = (l.a * p.0 + l.b * p.1 - l.c) as f64;
        let fq = (l.a * q.0 + l.b * q.1 - l.c) as f64;
        if fp == 0.0 {
            pts.push((p.0 as f64, p.1 as f64));
        } else if fp * fq < 0.0 {
            let t = fp / (fp - fq);
            pts.push((p.0 as f64 + t * (q.0 - p.0) as f64, p.1 as f64 + t * (q.1 - p.1) as f64));
        }
    }
    pts.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let a = pts[0];
    let b = pts[pts.len() - 1];
    ((a.0.round() as i64, a.1.round() as i64), (b.0.round() as i64, b.1.round() as i64))
}

// ------------------------------------------------------------------------------------- oracle

fn parse_pts(v: &Value) -> Result<Vec<P>, String> {
    v.as_array()
        .ok_or("points")?
        .iter()
        .map(|p| {
            let x = p[0].as_f64().ok_or("x")? * 2.0;
            let y = p[1].as_f64().ok_or("y")? * 2.0;
            Ok((x.round() as i64, y.round() as i64))
        })
        .collect()
}

pub fn oracle(item: &IqItem) -> Result<usize, String> {
    let fig = item.figure.as_ref().ok_or("no figure")?;
    let n = fig["n"].as_i64().ok_or("n")?;
    let panels = fig["panels"].as_array().ok_or("panels")?;
    let (last, folds_v) = panels.split_last().ok_or("no panels")?;
    let mut poly: Vec<P> = vec![(0, 0), (2 * n, 0), (2 * n, 2 * n), (0, 2 * n)];
    let mut folds: Vec<Fold> = vec![];
    for pv in folds_v {
        if !same_poly(&parse_pts(&pv["poly"])?, &poly) {
            return Err("panel outline does not match the folded paper".into());
        }
        let l = parse_pts(&pv["line"])?;
        let (p, q) = (l[0], l[1]);
        // line through p and q: a = dy, b = −dx (normalised to unit steps)
        let (dx, dy) = (q.0 - p.0, q.1 - p.1);
        let g = gcd(dx.abs(), dy.abs()).max(1);
        let (a, b) = (dy / g, -dx / g);
        let line = Line { a, b, c: a * p.0 + b * p.1 };
        let ar = parse_pts(&pv["arrow"])?;
        let moving = line.side(ar[0]);
        if moving == 0 || line.side(ar[1]) != -moving {
            return Err("arrow does not cross the fold".into());
        }
        if !symmetric(&poly, &line) {
            return Err("fold is not a symmetry axis of the paper".into());
        }
        poly = clip(&poly, &line, -moving);
        folds.push(Fold { line, moving });
    }
    if !same_poly(&parse_pts(&last["poly"])?, &poly) {
        return Err("final outline mismatch".into());
    }
    let punches = parse_pts(&last["holes"])?;
    let mut holes: Vec<P> = vec![];
    for i in 0..n {
        for j in 0..n {
            let mut p = (2 * i + 1, 2 * j + 1);
            for f in &folds {
                if f.line.side(p) == f.moving {
                    p = f.line.reflect(p);
                }
            }
            if punches.contains(&p) {
                holes.push((2 * i + 1, 2 * j + 1));
            }
        }
    }
    holes.sort();
    let ok: Vec<bool> = item
        .options
        .iter()
        .map(|o| {
            let mut h = parse_pts(&opt_fig(o)["holes"]).unwrap_or_default();
            h.sort();
            h == holes
        })
        .collect();
    if !all_distinct(&item.options) {
        return Err("duplicate options".into());
    }
    unique_index(&ok)
}

fn gcd(a: i64, b: i64) -> i64 {
    if b == 0 {
        a
    } else {
        gcd(b, a % b)
    }
}

// ---------------------------------------------------------------------------------- generator

fn fold_tr(l: &Line, moving: i64) -> &'static str {
    match (l.a, l.b, moving) {
        (1, 0, -1) => "soldan sağa",
        (1, 0, _) => "sağdan sola",
        (0, 1, -1) => "yukarıdan aşağıya",
        (0, 1, _) => "aşağıdan yukarıya",
        _ => "çapraz",
    }
}

fn try_gen(rng: &mut Rng, hard: bool) -> Option<IqItem> {
    let n: i64 = if hard { 6 } else { 4 };
    let n_folds = if hard { rng.range(2, 3) as usize } else { rng.range(1, 2) as usize };
    let mut poly: Vec<P> = vec![(0, 0), (2 * n, 0), (2 * n, 2 * n), (0, 2 * n)];
    let mut folds: Vec<Fold> = vec![];
    let mut panels: Vec<Value> = vec![];
    for _ in 0..n_folds {
        let mut cands = candidate_lines(&poly);
        if !hard {
            cands.retain(|l| !l.diagonal());
        }
        if cands.is_empty() {
            return None;
        }
        let line = cands[rng.below(cands.len())];
        let moving = if rng.chance(0.5) { 1 } else { -1 };
        let (c0, c1) = chord(&poly, &line);
        let mpart = clip(&poly, &line, moving);
        let (mx, my) = centroid(&mpart);
        // arrow: from the moving part's centroid to its mirror image
        let mp = (mx.round() as i64, my.round() as i64);
        let to = line.reflect(mp);
        if line.side(mp) != moving {
            return None;
        }
        panels.push(json!({
            "poly": poly.iter().map(|&p| pt(p)).collect::<Vec<_>>(),
            "line": [pt(c0), pt(c1)],
            "arrow": [pt(mp), pt(to)],
        }));
        poly = clip(&poly, &line, -moving);
        folds.push(Fold { line, moving });
    }
    if hard && !folds.iter().any(|f| f.line.diagonal()) {
        return None;
    }
    // Punch 1–2 cell centres strictly inside the folded paper.
    let mut spots: Vec<P> = vec![];
    for i in 0..n {
        for j in 0..n {
            let p = (2 * i + 1, 2 * j + 1);
            if inside(&poly, p) {
                spots.push(p);
            }
        }
    }
    if spots.is_empty() {
        return None;
    }
    rng.shuffle(&mut spots);
    let n_punch = if n_folds == 1 || (hard && n_folds == 2) { 2.min(spots.len()) } else { 1 };
    let punches: Vec<P> = spots[..n_punch].to_vec();
    let answer = unfold(&punches, &folds, None, None);

    // Distractors. Most are the correct unfolding of a punch in another place (one cell off, or
    // another spot), so every option is equally symmetric; one more is a typical mistake
    // (a wrong reflection axis, or a forgotten unfold) applied to a random one of those patterns,
    // so the answer is not the "centre" of the option set.
    let inb = |c: &[P]| c.iter().all(|&(x, y)| x > 0 && y > 0 && x < 2 * n && y < 2 * n);
    // Alternative punch sets: random cells of the flat sheet (the same number of punches).
    // Shifts of the true punch would make the answer the centre of a star of overlapping
    // patterns, so they are not used.
    let mut alts: Vec<Vec<P>> = vec![];
    for _ in 0..12 {
        let q: Vec<P> = (0..punches.len()).map(|_| (2 * rng.range(0, n - 1) + 1, 2 * rng.range(0, n - 1) + 1)).collect();
        alts.push(q);
    }
    let mut fulls: Vec<Vec<P>> = vec![];
    for q in &alts {
        let f = unfold(q, &folds, None, None);
        if f != answer && f.len() == answer.len() && inb(&f) && !fulls.contains(&f) {
            fulls.push(f);
        }
    }
    if fulls.len() < 3 {
        return None;
    }
    let fulls_extra: Vec<Vec<P>> = fulls.split_off(3.min(fulls.len()));
    let mut ds: Vec<Vec<P>> = fulls.clone();
    let base_k = rng.below(4);
    let base: Vec<P> = if base_k == 0 { punches.clone() } else { alts[0].clone() };
    let base = if base_k == 0 {
        base
    } else {
        // the punch set behind fulls[base_k - 1]
        alts.iter().find(|q| unfold(q, &folds, None, None) == fulls[base_k - 1]).cloned().unwrap_or(base)
    };
    let centre = (n, n);
    // Wrong axis first; when the folds generate the full symmetry group a wrong axis gives the
    // same pattern, so "forgot one unfold" is the fallback (valid for any base, no selection bias).
    let mut bugs: Vec<Vec<P>> = (0..folds.len()).map(|k| unfold(&base, &folds, None, Some((k, centre_of(&folds, k, centre))))).collect();
    rng.shuffle(&mut bugs);
    if hard {
        // hard: every option has the same hole count (no size outlier to eliminate)
        bugs.extend(fulls_extra.iter().cloned());
    } else {
        let mut forgot: Vec<Vec<P>> = (0..folds.len()).map(|k| unfold(&base, &folds, Some(k), None)).collect();
        rng.shuffle(&mut forgot);
        bugs.extend(forgot);
    }
    for mut c in bugs {
        c.sort();
        c.dedup();
        let forgot = !hard && c.len() * 2 == answer.len();
        if inb(&c) && c != answer && (c.len() == answer.len() || forgot) && !ds.contains(&c) {
            ds.push(c);
            break;
        }
    }
    if ds.len() < 4 {
        return None;
    }
    ds.truncate(4);
    let mut final_panel = json!({
        "poly": poly.iter().map(|&p| pt(p)).collect::<Vec<_>>(),
        "holes": punches.iter().map(|&p| pt(p)).collect::<Vec<_>>(),
    });
    final_panel["punch"] = json!(true);
    panels.push(final_panel);
    let fig = json!({ "k": "fold", "w": panels.len(), "h": 1, "n": n, "panels": panels });
    let steps: Vec<String> = folds.iter().map(|f| fold_tr(&f.line, f.moving).to_string()).collect();
    let why = format!(
        "Katlamalar: {}. Kâğıt açılırken her katlama çizgisi bir ayna gibidir: delikler çizgiye göre yansır ve her açılışta sayıları ikiye katlanır. Kâğıtta {} delik açıldı, açılınca {} delik olur.{}",
        steps.join(", "),
        punches.len(),
        answer.len(),
        if folds.iter().any(|f| f.line.diagonal()) { " Çapraz katlamada delik köşegene göre yansır." } else { "" }
    );
    Some(finish(
        rng,
        "paper_fold",
        hard,
        "Kâğıt gösterildiği gibi katlanıp delindi. Açılınca nasıl görünür?".into(),
        Some(fig),
        IqOption::Figure(sheet(n, &answer)),
        ds.iter().map(|d| IqOption::Figure(sheet(n, d))).collect(),
        why,
    ))
}

/// Centre point of fold k's line (on the doubled lattice), for the wrong-axis bug.
fn centre_of(folds: &[Fold], k: usize, sheet_centre: P) -> P {
    // replay the paper up to fold k
    let n2 = sheet_centre.0 * 2;
    let mut poly: Vec<P> = vec![(0, 0), (n2, 0), (n2, n2), (0, n2)];
    for f in &folds[..k] {
        poly = clip(&poly, &f.line, -f.moving);
    }
    bbox_centre(&poly)
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
