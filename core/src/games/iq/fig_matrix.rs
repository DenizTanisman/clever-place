//! `matrix`: 3×3 Raven-style matrices.
//!
//! Two templates. *Element* matrices: every cell holds `count` copies of one shape with a fill and
//! a size; 2 (medium) or 3 (hard) attributes follow a rule (constant per line, progression,
//! distribution of three, sum), hard rules may run along columns and may come with an irrelevant
//! colour attribute. *Overlay* matrices: cells hold spokes; the third cell of a line is the XOR /
//! union / intersection of the first two (hard adds a shape rule on top).
//!
//! Options are balanced attribute combinations (I-RAVEN), so no attribute value gives the
//! answer away by frequency. Oracle: parse every cell back to attributes and run the rule-family
//! grammar of `fig_rules::matrix_predict` per attribute, rows and columns; exactly one option
//! may fit every attribute.

use super::fig_common::*;
use super::fig_rules::*;
use crate::games::iq::item::{IqItem, IqOption};
use crate::rng::Rng;
use serde_json::{json, Value};

const SHAPES: [Shape; 7] = BASIC_SHAPES;
const MFILLS: [Fill; 5] = [Fill::None, Fill::Solid, Fill::Stripes, Fill::Dots, Fill::Half];
const SPOKE_LEN: f64 = 0.42;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Attr {
    Shape,
    Count,
    Fill,
    Size,
    Lines,
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Rule {
    ConstLine,
    Latin,
    Prog(i64),
    Sum,
    Xor,
    Or,
    And,
}

#[derive(Clone, Copy, PartialEq, Debug)]
struct MCell {
    shape: i64, // index into SHAPES
    count: i64,
    fill: i64, // index into MFILLS
    size: i64,
    lines: i64,
    gold: bool,
    ko: bool,
}

fn render(c: &MCell) -> Value {
    let mut its = vec![];
    for i in 0..8 {
        if c.lines >> i & 1 == 1 {
            let a = (i as f64) * std::f64::consts::FRAC_PI_4;
            its.push(line_item(0.5, 0.5, 0.5 + SPOKE_LEN * a.sin(), 0.5 - SPOKE_LEN * a.cos()));
        }
    }
    if c.count > 0 {
        for mut it in group_items(SHAPES[c.shape as usize], c.count as usize, MFILLS[c.fill as usize], 0, c.size) {
            if c.gold {
                it["c"] = json!("gold");
            }
            if c.ko {
                it["ko"] = json!(true);
            }
            its.push(it);
        }
    }
    cell(its)
}

// ------------------------------------------------------------------------------------- oracle

#[derive(Debug, Clone, Copy)]
struct PCell {
    shape: i64,
    count: i64,
    fill: i64,
    size: i64,
    lines: i64,
    gold: i64,
}

fn parse(v: &Value) -> Result<PCell, String> {
    if v["k"] != "cell" {
        return Err("not a cell".into());
    }
    let mut lines = 0i64;
    let mut shapes = vec![];
    for it in items(v) {
        if it["s"] == "line" {
            let (dx, dy) = (num(&it, "x2") - 0.5, num(&it, "y2") - 0.5);
            let k = (dx.atan2(-dy).to_degrees() / 45.0).round().rem_euclid(8.0) as i64;
            lines |= 1 << k;
        } else {
            shapes.push(it);
        }
    }
    let count = shapes.len() as i64;
    let (mut shape, mut fill, mut size, mut gold) = (-1, -1, -1, 0);
    if let Some(f) = shapes.first() {
        let s = Shape::from_id(f["s"].as_str().unwrap_or("")).ok_or("bad shape")?;
        shape = SHAPES.iter().position(|&x| x == s).ok_or("shape outside palette")? as i64;
        let fl = Fill::from_id(f["f"].as_str().unwrap_or("")).ok_or("bad fill")?;
        fill = MFILLS.iter().position(|&x| x == fl).unwrap() as i64;
        let r = num(f, "r");
        size = (0..3)
            .min_by(|&a, &b| {
                let da = (count_radius(count as usize, a) - r).abs();
                let db = (count_radius(count as usize, b) - r).abs();
                da.partial_cmp(&db).unwrap()
            })
            .unwrap();
        gold = (f["c"] == "gold") as i64;
        for o in &shapes {
            if o["s"] != f["s"] || o["f"] != f["f"] || o["r"] != f["r"] || o["c"] != f["c"] {
                return Err("mixed shapes in one cell".into());
            }
        }
    }
    Ok(PCell { shape, count, fill, size, lines, gold })
}

type Getter = fn(&PCell) -> i64;
const ATTRS: [(Getter, AKind); 6] = [
    (|c| c.shape, AKind::Cat),
    (|c| c.count, AKind::Num(0, 6)),
    (|c| c.fill, AKind::Cat),
    (|c| c.size, AKind::Num(0, 2)),
    (|c| c.lines, AKind::Set),
    (|c| c.gold, AKind::Cat),
];

pub fn oracle(item: &IqItem) -> Result<usize, String> {
    let fig = item.figure.as_ref().ok_or("no figure")?;
    let cells = fig["cells"].as_array().ok_or("no cells")?;
    if fig["k"] != "grid" || cells.len() != 9 || cells[8]["k"] != "q" {
        return Err("expected a 3×3 grid ending in ?".into());
    }
    let mut g = [[None; 3]; 3];
    for (i, c) in cells.iter().enumerate().take(8) {
        g[i / 3][i % 3] = Some(parse(c)?);
    }
    let opts: Vec<PCell> = item.options.iter().map(|o| parse(opt_fig(o))).collect::<Result<_, _>>()?;
    let mut ok = vec![true; opts.len()];
    for (get, kind) in ATTRS {
        let mut vals = [[0i64; 3]; 3];
        for r in 0..3 {
            for c in 0..3 {
                if let Some(p) = &g[r][c] {
                    vals[r][c] = get(p);
                }
            }
        }
        // The shape is only meaningful where there are shapes.
        let pred = matrix_predict(&vals, kind);
        for (i, o) in opts.iter().enumerate() {
            if !fits(&pred, get(o)) {
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

fn domain(a: Attr) -> Vec<i64> {
    match a {
        Attr::Shape => (0..SHAPES.len() as i64).collect(),
        Attr::Count => (1..=6).collect(),
        Attr::Fill => (0..MFILLS.len() as i64).collect(),
        Attr::Size => (0..3).collect(),
        Attr::Lines => vec![],
    }
}

fn distinct(rng: &mut Rng, dom: &[i64], k: usize) -> Vec<i64> {
    let mut d = dom.to_vec();
    rng.shuffle(&mut d);
    d.truncate(k);
    d
}

/// A random 3×3 Latin square over indices 0..3.
fn latin(rng: &mut Rng) -> [[usize; 3]; 3] {
    let mut perm = [0usize, 1, 2];
    rng.shuffle(&mut perm);
    let mut shifts = [0usize, 1, 2];
    rng.shuffle(&mut shifts);
    let rev = rng.chance(0.5);
    let mut l = [[0; 3]; 3];
    for (r, row) in l.iter_mut().enumerate() {
        for (p, x) in row.iter_mut().enumerate() {
            let k = if rev { (shifts[r] + 3 - p) % 3 } else { (p + shifts[r]) % 3 };
            *x = perm[k];
        }
    }
    l
}

/// Values laid out per line: `lines[l][p]`.
fn line_values(rng: &mut Rng, a: Attr, rule: Rule) -> Option<[[i64; 3]; 3]> {
    let dom = domain(a);
    let mut out = [[0i64; 3]; 3];
    match rule {
        Rule::ConstLine => {
            let v = distinct(rng, &dom, 3);
            for l in 0..3 {
                out[l] = [v[l]; 3];
            }
        }
        Rule::Latin => {
            let v = distinct(rng, &dom, 3);
            let sq = latin(rng);
            for l in 0..3 {
                for p in 0..3 {
                    out[l][p] = v[sq[l][p]];
                }
            }
        }
        Rule::Prog(d) => {
            let (lo, hi) = (dom[0], dom[dom.len() - 1]);
            let starts: Vec<i64> = (lo..=hi).filter(|&s| (lo..=hi).contains(&(s + 2 * d))).collect();
            if a == Attr::Size {
                let s = starts[0];
                for row in out.iter_mut() {
                    *row = [s, s + d, s + 2 * d];
                }
            } else {
                let st = distinct(rng, &starts, 3.min(starts.len()));
                if st.len() < 2 {
                    return None;
                }
                for l in 0..3 {
                    let s = st[l % st.len()];
                    out[l] = [s, s + d, s + 2 * d];
                }
            }
        }
        Rule::Sum => {
            for row in out.iter_mut() {
                let x = rng.range(1, 4);
                let y = rng.range(1, 5 - x + 1);
                if x + y > 6 {
                    return None;
                }
                *row = [x, y, x + y];
            }
            if out[0] == out[1] {
                return None;
            }
        }
        _ => unreachable!(),
    }
    Some(out)
}

fn to_grid(lines: [[i64; 3]; 3], dir: usize) -> [[i64; 3]; 3] {
    let mut g = [[0; 3]; 3];
    for l in 0..3 {
        for p in 0..3 {
            if dir == 0 {
                g[l][p] = lines[l][p];
            } else {
                g[p][l] = lines[l][p];
            }
        }
    }
    g
}

/// Plausible wrong values ("bug models") for the missing cell, most plausible first.
fn wrongs(rng: &mut Rng, a: Attr, rule: Rule, lines: &[[i64; 3]; 3]) -> Vec<i64> {
    let correct = lines[2][2];
    let (x, y) = (lines[2][0], lines[2][1]);
    let mut c: Vec<i64> = match rule {
        Rule::Latin => {
            let mut v = vec![x, y];
            rng.shuffle(&mut v);
            v
        }
        Rule::ConstLine => {
            let mut v = vec![lines[0][2], lines[1][2]];
            rng.shuffle(&mut v);
            v
        }
        Rule::Prog(d) => {
            let mut v = vec![correct + d, y, correct - 2 * d];
            if a == Attr::Count {
                v.push(correct + 2 * d);
            }
            v
        }
        Rule::Sum => vec![correct + 1, correct - 1, (x - y).abs(), x * y],
        _ => vec![],
    };
    let mut rest = domain(a);
    rng.shuffle(&mut rest);
    c.extend(rest);
    let dom = domain(a);
    let mut out = vec![];
    for v in c {
        if v != correct && dom.contains(&v) && !out.contains(&v) {
            out.push(v);
        }
    }
    out
}

fn line_word(dir: usize) -> (&'static str, &'static str) {
    if dir == 0 {
        ("satırda", "soldan sağa")
    } else {
        ("sütunda", "yukarıdan aşağıya")
    }
}

fn describe(a: Attr, rule: Rule, dir: usize, lines: &[[i64; 3]; 3]) -> String {
    let (lw, flow) = line_word(dir);
    let name = |v: i64| -> String {
        match a {
            Attr::Shape => SHAPES[v as usize].tr().to_string(),
            Attr::Fill => MFILLS[v as usize].tr().to_string(),
            Attr::Count => format!("{v} şekilli hücre"),
            Attr::Size => ["küçük", "orta", "büyük"][v as usize].to_string(),
            Attr::Lines => String::new(),
        }
    };
    let what = match a {
        Attr::Shape => "Şekil",
        Attr::Count => "Şekil sayısı",
        Attr::Fill => "Dolgu",
        Attr::Size => "Boyut",
        Attr::Lines => "Çizgiler",
    };
    match rule {
        Rule::ConstLine => format!("Her {lw} {} aynı kalıyor.", what.to_lowercase()),
        Rule::Latin => {
            let mut v: Vec<i64> = lines[0].to_vec();
            v.sort();
            let names: Vec<String> = v.into_iter().map(name).collect();
            format!("Her {lw} {} birer kez var.", tr_list(&names))
        }
        Rule::Prog(d) => {
            if a == Attr::Size {
                format!("Boyut her {lw} {flow} {}.", if d > 0 { "büyüyor" } else { "küçülüyor" })
            } else {
                format!("Şekil sayısı her {lw} {flow} {} {}.", d.abs(), if d > 0 { "artıyor" } else { "azalıyor" })
            }
        }
        Rule::Sum => format!("Her {lw} üçüncü hücredeki şekil sayısı ilk ikisinin toplamı."),
        Rule::Xor => format!(
            "Her {lw} üçüncü hücre, ilk iki hücreden yalnızca birinde olan çizgileri gösterir; ortak çizgiler silinir."
        ),
        Rule::Or => format!("Her {lw} üçüncü hücre, ilk iki hücrenin bütün çizgilerini birleştirir."),
        Rule::And => format!("Her {lw} üçüncü hücrede yalnızca ilk iki hücrenin ortak çizgileri kalır."),
    }
}

struct Plan {
    attr: Attr,
    rule: Rule,
    dir: usize,
    lines: [[i64; 3]; 3],
}

fn spokes(rng: &mut Rng, lo: u32, hi: u32) -> i64 {
    loop {
        let m = rng.below(256) as i64;
        let n = (m as u64).count_ones();
        if (lo..=hi).contains(&n) {
            return m;
        }
    }
}

fn logic_lines(rng: &mut Rng, rule: Rule) -> Option<[[i64; 3]; 3]> {
    let op = |a: i64, b: i64| match rule {
        Rule::Xor => a ^ b,
        Rule::Or => a | b,
        _ => a & b,
    };
    let mut out = [[0i64; 3]; 3];
    for row in out.iter_mut() {
        let (lo, hi) = if rule == Rule::And { (3, 5) } else { (2, 4) };
        let a = spokes(rng, lo, hi);
        let b = spokes(rng, lo, hi);
        let c = op(a, b);
        if a == b || c == 0 || c == a || c == b {
            return None;
        }
        *row = [a, b, c];
    }
    // Overlap in the complete lines, so OR / XOR / AND are told apart.
    if (out[0][0] & out[0][1]) == 0 && (out[1][0] & out[1][1]) == 0 {
        return None;
    }
    if (out[2][0] & out[2][1]) == 0 {
        return None;
    }
    Some(out)
}

fn logic_wrongs(rng: &mut Rng, rule: Rule, l: &[[i64; 3]; 3]) -> Vec<i64> {
    let (a, b, c) = (l[2][0], l[2][1], l[2][2]);
    let mut v = vec![a | b, a ^ b, a & b, a, b];
    rng.shuffle(&mut v);
    // a near miss: the correct set with one spoke toggled
    let k = rng.below(8);
    v.push(c ^ (1 << k));
    v.push(c ^ (1 << ((k + 3) % 8)));
    let _ = rule;
    let mut out = vec![];
    for x in v {
        if x != c && x != 0 && !out.contains(&x) {
            out.push(x);
        }
    }
    out
}

fn try_gen(rng: &mut Rng, hard: bool) -> Option<IqItem> {
    let logic = rng.chance(0.3);
    let mut plans: Vec<Plan> = vec![];
    let mut gold_noise = false;
    let base = MCell { shape: 0, count: 1, fill: 1, size: 2, lines: 0, gold: false, ko: false };
    if logic {
        let rule = *rng.pick(&if hard { vec![Rule::Xor, Rule::Xor, Rule::Or, Rule::And] } else { vec![Rule::Xor, Rule::Or] });
        let dir = if hard { rng.below(2) } else { 0 };
        plans.push(Plan { attr: Attr::Lines, rule, dir, lines: logic_lines(rng, rule)? });
        if hard {
            let a = if rng.chance(0.6) { Attr::Shape } else { Attr::Fill };
            let rule2 = if rng.chance(0.7) { Rule::Latin } else { Rule::ConstLine };
            let mut lv = line_values(rng, a, rule2)?;
            if a == Attr::Fill {
                // keep the centre shape readable over the spokes: no empty fill
                for row in lv.iter_mut() {
                    for x in row.iter_mut() {
                        if *x == 0 {
                            return None;
                        }
                    }
                }
            }
            plans.push(Plan { attr: a, rule: rule2, dir: 1 - dir, lines: lv });
        }
    } else {
        let sets: &[&[Attr]] = if hard {
            &[&[Attr::Shape, Attr::Count, Attr::Fill], &[Attr::Shape, Attr::Fill, Attr::Size], &[Attr::Shape, Attr::Count, Attr::Fill]]
        } else {
            &[
                &[Attr::Shape, Attr::Count],
                &[Attr::Shape, Attr::Fill],
                &[Attr::Count, Attr::Fill],
                &[Attr::Shape, Attr::Size],
                &[Attr::Fill, Attr::Size],
                &[Attr::Count, Attr::Shape],
            ]
        };
        let mut set: Vec<Attr> = rng.pick(sets).to_vec();
        rng.shuffle(&mut set);
        for &a in &set {
            let rule = match a {
                Attr::Shape | Attr::Fill => {
                    if rng.chance(0.7) {
                        Rule::Latin
                    } else {
                        Rule::ConstLine
                    }
                }
                Attr::Count => *rng.pick(&[Rule::Prog(1), Rule::Prog(1), Rule::Prog(-1), Rule::Latin, Rule::Sum, Rule::ConstLine]),
                Attr::Size => *rng.pick(&[Rule::Prog(1), Rule::Prog(-1), Rule::Latin]),
                Attr::Lines => unreachable!(),
            };
            let dir = if hard { rng.below(2) } else { 0 };
            plans.push(Plan { attr: a, rule, dir, lines: line_values(rng, a, rule)? });
        }
        gold_noise = hard && rng.chance(0.5);
    }
    let active: Vec<Attr> = plans.iter().map(|p| p.attr).collect();
    // Inactive attributes are constant over the whole matrix.
    let mut cells = [[base; 3]; 3];
    let size_active = active.contains(&Attr::Size);
    let count_active = active.contains(&Attr::Count);
    let c_shape = rng.below(SHAPES.len()) as i64;
    let c_fill = if logic { *rng.pick(&[1i64, 2, 3]) } else { rng.below(MFILLS.len()) as i64 };
    let c_count = if logic { 1 } else if size_active { rng.range(1, 2) } else { rng.range(1, 4) };
    let c_size = if logic { 0 } else if count_active { 2 } else { 1 };
    for row in cells.iter_mut() {
        for c in row.iter_mut() {
            c.shape = c_shape;
            c.fill = c_fill;
            c.count = if logic && !active.contains(&Attr::Shape) && !active.contains(&Attr::Fill) { 0 } else { c_count };
            c.size = c_size;
            c.ko = logic;
            if gold_noise {
                c.gold = rng.chance(0.5);
            }
        }
    }
    for p in &plans {
        let g = to_grid(p.lines, p.dir);
        for r in 0..3 {
            for c in 0..3 {
                let v = g[r][c];
                let cl = &mut cells[r][c];
                match p.attr {
                    Attr::Shape => cl.shape = v,
                    Attr::Count => cl.count = v,
                    Attr::Fill => cl.fill = v,
                    Attr::Size => cl.size = v,
                    Attr::Lines => cl.lines = v,
                }
            }
        }
    }
    // Every cell must differ from its row neighbours (no dead rows).
    for r in 0..3 {
        if cells[r][0] == cells[r][1] && cells[r][1] == cells[r][2] {
            return None;
        }
    }
    let answer = cells[2][2];

    // Options: balanced combos over the active attributes.
    let sizes: Vec<usize> = match (plans.len(), logic) {
        (1, true) => vec![5],
        (2, _) => vec![3, 2],
        (3, _) => vec![2, 2, 2],
        _ => return None,
    };
    let mut values: Vec<Vec<i64>> = vec![];
    for (p, &s) in plans.iter().zip(&sizes) {
        let w = if p.attr == Attr::Lines { logic_wrongs(rng, p.rule, &p.lines) } else { wrongs(rng, p.attr, p.rule, &p.lines) };
        if w.len() < s - 1 {
            return None;
        }
        let mut v = vec![p.lines[2][2]];
        v.extend(w.into_iter().take(s - 1));
        values.push(v);
    }
    let combos = balanced_combos(rng, &sizes);
    let mut opts = vec![];
    for combo in &combos {
        let mut c = answer;
        for (k, p) in plans.iter().enumerate() {
            let v = values[k][combo[k]];
            match p.attr {
                Attr::Shape => c.shape = v,
                Attr::Count => c.count = v,
                Attr::Fill => c.fill = v,
                Attr::Size => c.size = v,
                Attr::Lines => c.lines = v,
            }
        }
        opts.push(IqOption::Figure(render(&c)));
    }
    if !all_distinct(&opts) {
        return None;
    }
    let mut grid_cells: Vec<Value> = vec![];
    for r in 0..3 {
        for c in 0..3 {
            grid_cells.push(if r == 2 && c == 2 { q_cell() } else { render(&cells[r][c]) });
        }
    }
    let mut why: Vec<String> = plans.iter().map(|p| describe(p.attr, p.rule, p.dir, &p.lines)).collect();
    if gold_noise {
        why.push("Renk (altın / fildişi) hiçbir kurala bağlı değil, yalnızca dikkat dağıtıyor.".into());
    }
    if !logic || answer.count > 0 {
        why.push(format!(
            "Cevap: {} {} {}.",
            answer.count,
            MFILLS[answer.fill as usize].tr(),
            SHAPES[answer.shape as usize].tr()
        ));
    }
    let figure = Some(grid(3, 3, grid_cells, None));
    if !item_readable(&figure, &opts) {
        return None;
    }
    let correct = opts.remove(0);
    Some(finish(
        rng,
        "matrix",
        hard,
        "Soru işaretinin yerine hangisi gelmeli?".into(),
        figure,
        correct,
        opts,
        why.join(" "),
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
