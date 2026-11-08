//! Tests for every figural category: oracle agreement on many fixed seeds, determinism, answer
//! position spread, an option-only ("blind") bias check, and the fixture dump for the painter.

use super::*;
use crate::games::iq::item::IqOption;
use crate::rng::Rng;
use serde_json::{json, Value};
use std::collections::HashMap;

const N: u64 = 220;

fn seed(cat: &str, hard: bool, i: u64) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in cat.bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x100_0000_01b3);
    }
    h ^ (i << 8) ^ (hard as u64)
}

fn gen_of(cat: &str) -> IqGen {
    FIGURAL.iter().find(|(id, _, _)| *id == cat).unwrap().2
}

fn oracle_of(cat: &str) -> Oracle {
    ORACLES.iter().find(|(id, _)| *id == cat).unwrap_or_else(|| panic!("no oracle for {cat}")).1
}

pub fn item_json(it: &IqItem) -> Value {
    json!({
        "cat": it.cat,
        "hard": it.hard,
        "prompt": it.prompt,
        "figure": it.figure,
        "options": it.options.iter().map(|o| o.to_json()).collect::<Vec<_>>(),
        "answer": it.answer,
        "why": it.why,
    })
}

fn items_for(cat: &str, hard: bool, n: u64) -> Vec<IqItem> {
    let g = gen_of(cat);
    (0..n).map(|i| g(&mut Rng::new(seed(cat, hard, i)), hard)).collect()
}

#[test]
fn ids_names_and_oracles() {
    let want = [
        "matrix",
        "shape_series",
        "cube_rotation",
        "figure_analogy",
        "odd_shape",
        "cube_net",
        "paper_fold",
        "block_count",
        "mental_rotation",
        "matchstick",
        "assembly",
    ];
    let have: Vec<&str> = FIGURAL.iter().map(|(id, _, _)| *id).collect();
    for w in want {
        assert!(have.contains(&w), "missing category {w}");
        let _ = oracle_of(w);
    }
    assert_eq!(have.len(), want.len());
}

#[test]
fn every_item_passes_its_oracle() {
    for (cat, _, _) in FIGURAL {
        let oracle = oracle_of(cat);
        for hard in [false, true] {
            for (i, it) in items_for(cat, hard, N).iter().enumerate() {
                let ctx = format!("{cat} hard={hard} #{i}");
                assert_eq!(it.cat, *cat, "{ctx}");
                assert_eq!(it.hard, hard, "{ctx}");
                assert!((4..=6).contains(&it.options.len()), "{ctx}: {} options", it.options.len());
                assert!(it.answer < it.options.len(), "{ctx}");
                assert!(!it.prompt.is_empty() && !it.why.is_empty(), "{ctx}");
                assert!(it.typed.is_none(), "{ctx}");
                let keys: Vec<String> = it.options.iter().map(|o| o.to_json().to_string()).collect();
                for a in 0..keys.len() {
                    for b in a + 1..keys.len() {
                        assert_ne!(keys[a], keys[b], "{ctx}: options {a} and {b} identical");
                    }
                }
                assert_eq!(oracle(it), Ok(it.answer), "{ctx}\n{}", item_json(it));
                assert!(fig_common::item_readable(&it.figure, &it.options), "{ctx}: pattern inside a star/cross");
            }
        }
    }
}

#[test]
fn deterministic() {
    for (cat, _, g) in FIGURAL {
        for hard in [false, true] {
            for i in 0..5 {
                let a = g(&mut Rng::new(seed(cat, hard, i)), hard);
                let b = g(&mut Rng::new(seed(cat, hard, i)), hard);
                assert_eq!(item_json(&a), item_json(&b), "{cat}");
            }
        }
    }
}

#[test]
fn answer_positions_spread() {
    for (cat, _, _) in FIGURAL {
        for hard in [false, true] {
            let its = items_for(cat, hard, N);
            let mut by_len: HashMap<usize, Vec<usize>> = HashMap::new();
            for it in &its {
                let v = by_len.entry(it.options.len()).or_insert_with(|| vec![0; it.options.len()]);
                v[it.answer] += 1;
            }
            for (n, counts) in by_len {
                let total: usize = counts.iter().sum();
                if total < 40 {
                    continue;
                }
                let exp = total as f64 / n as f64;
                for (p, &c) in counts.iter().enumerate() {
                    assert!(
                        (c as f64) > exp * 0.45 && (c as f64) < exp * 1.6,
                        "{cat} hard={hard}: position {p} got {c} of {total} ({counts:?})"
                    );
                }
            }
        }
    }
}

// ------------------------------------------------------------------------- blind bias check

/// Tokens of an option: every JSON leaf as "path=value" (array indices dropped), and every
/// small numeric array (a point / a cube) as one token. Text options: characters by position,
/// plus the whole number for numeric options.
fn tokens(o: &IqOption) -> Vec<String> {
    fn walk(v: &Value, path: &str, out: &mut Vec<String>) {
        match v {
            Value::Object(m) => {
                for (k, x) in m {
                    walk(x, &format!("{path}.{k}"), out);
                }
            }
            Value::Array(a) => {
                if !a.is_empty() && a.iter().all(|x| x.is_number()) {
                    out.push(format!("{path}={v}"));
                } else {
                    for x in a {
                        walk(x, &format!("{path}[]"), out);
                    }
                }
            }
            _ => out.push(format!("{path}={v}")),
        }
    }
    let mut out = vec![];
    match o {
        IqOption::Figure(v) => walk(v, "", &mut out),
        IqOption::Text(t) => {
            for (i, ch) in t.chars().enumerate() {
                out.push(format!("{i}:{ch}"));
            }
            for w in t.split(|c: char| !c.is_alphanumeric()) {
                if !w.is_empty() {
                    out.push(format!("w:{w}"));
                }
            }
        }
    }
    out
}

/// Accuracy of several option-only heuristics (credit split on ties).
fn blind_scores(its: &[IqItem]) -> Vec<(&'static str, f64)> {
    let mut acc = vec![0.0f64; 9];
    for it in its {
        let toks: Vec<Vec<String>> = it.options.iter().map(tokens).collect();
        let n = toks.len();
        let mut freq: HashMap<&String, usize> = HashMap::new();
        for t in &toks {
            let mut seen = std::collections::HashSet::new();
            for x in t {
                if seen.insert(x) {
                    *freq.entry(x).or_default() += 1;
                }
            }
        }
        let sum: Vec<f64> = toks.iter().map(|t| t.iter().map(|x| freq[x] as f64).sum()).collect();
        let mean: Vec<f64> = toks.iter().zip(&sum).map(|(t, s)| s / t.len().max(1) as f64).collect();
        let len: Vec<f64> = toks.iter().map(|t| t.len() as f64).collect();
        let numeric: Option<Vec<f64>> = it
            .options
            .iter()
            .map(|o| match o {
                IqOption::Text(t) => t.trim().parse::<f64>().ok(),
                _ => None,
            })
            .collect();
        let median: Vec<f64> = match &numeric {
            Some(v) => {
                let mut s = v.clone();
                s.sort_by(|a, b| a.partial_cmp(b).unwrap());
                let m = s[n / 2];
                v.iter().map(|x| -(x - m).abs()).collect()
            }
            None => vec![0.0; n],
        };
        let neg = |v: &[f64]| v.iter().map(|x| -x).collect::<Vec<f64>>();
        for (k, score) in [sum.clone(), neg(&sum), mean.clone(), neg(&mean), len.clone(), median].iter().enumerate() {
            let best = score.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
            let ties: Vec<usize> = (0..n).filter(|&i| (score[i] - best).abs() < 1e-9).collect();
            if ties.contains(&it.answer) {
                acc[k] += 1.0 / ties.len() as f64;
            }
        }
        // Visual-outlier shortcuts: the only option with a different element count / structure
        // (complexity), or the only one whose value differs on some attribute that all the
        // others share (size, stroke, fill …). Credit 1/n when no single outlier exists.
        let outlier = |flags: Vec<usize>| -> f64 {
            if flags.len() == 1 {
                (flags[0] == it.answer) as u8 as f64
            } else {
                1.0 / n as f64
            }
        };
        let paths: Vec<Vec<String>> = toks
            .iter()
            .map(|t| {
                let mut p: Vec<String> = t.iter().map(|x| x.split('=').next().unwrap_or("").to_string()).collect();
                p.sort();
                p
            })
            .collect();
        let structure: Vec<usize> = (0..n).filter(|&i| (0..n).filter(|&j| j != i).all(|j| paths[j] == paths[(i + 1) % n] && paths[j] != paths[i])).collect();
        acc[6] += outlier(structure);
        let mut by_path: HashMap<String, Vec<Vec<String>>> = HashMap::new();
        for (i, t) in toks.iter().enumerate() {
            for x in t {
                let (p, v) = x.split_once('=').unwrap_or((x, ""));
                let e = by_path.entry(p.to_string()).or_insert_with(|| vec![vec![]; n]);
                e[i].push(v.to_string());
            }
        }
        let mut flagged = std::collections::BTreeSet::new();
        for vals in by_path.values_mut() {
            for v in vals.iter_mut() {
                v.sort();
            }
            for i in 0..n {
                let others: Vec<&Vec<String>> = (0..n).filter(|&j| j != i).map(|j| &vals[j]).collect();
                if others.iter().all(|o| *o == others[0]) && vals[i] != *others[0] {
                    flagged.insert(i);
                }
            }
        }
        acc[7] += outlier(flagged.into_iter().collect());
        let lens: Vec<usize> = toks.iter().map(|t| t.len()).collect();
        let short_min = *lens.iter().min().unwrap();
        let shortest: Vec<usize> = (0..n).filter(|&i| lens[i] == short_min).collect();
        acc[8] += if shortest.contains(&it.answer) { 1.0 / shortest.len() as f64 } else { 0.0 };
    }
    let names = [
        "mode-sum",
        "anti-mode-sum",
        "mode-mean",
        "anti-mode-mean",
        "longest",
        "median",
        "odd-structure",
        "odd-attribute",
        "shortest",
    ];
    names.iter().zip(acc).map(|(nm, a)| (*nm, a / its.len() as f64)).collect()
}

#[test]
fn options_alone_do_not_give_the_answer_away() {
    let mut report = vec![];
    for (cat, _, _) in FIGURAL {
        for hard in [false, true] {
            let its = items_for(cat, hard, 300);
            let chance: f64 = its.iter().map(|it| 1.0 / it.options.len() as f64).sum::<f64>() / its.len() as f64;
            for (name, acc) in blind_scores(&its) {
                // Odd-one-out is the one category where the options are the stem itself: the
                // "least typical / outlier / longest / shortest option" heuristics detect oddness,
                // which is the task, not a leak. The "most typical option" heuristics still apply.
                if *cat == "odd_shape"
                    && (name.starts_with("anti") || name.starts_with("odd-") || name == "longest" || name == "shortest")
                {
                    continue;
                }
                report.push(format!("{cat:>16} hard={hard:<5} {name:<15} {acc:.2} (chance {chance:.2})"));
                assert!(acc <= chance + 0.12, "{cat} hard={hard}: blind '{name}' gets {acc:.2} vs chance {chance:.2}");
            }
        }
    }
    println!("{}", report.join("\n"));
}

/// Writes the painter fixtures: `cargo test --release -- --ignored dump`.
#[test]
#[ignore]
fn dump() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../app/test/fixtures/iq");
    std::fs::create_dir_all(&dir).unwrap();
    for (cat, name, _) in FIGURAL {
        let mut its = vec![];
        for hard in [false, true] {
            for i in 0..2 {
                its.push(item_json(&items_for(cat, hard, 40)[(i * 17 + 3) as usize]));
            }
        }
        let doc = json!({ "cat": cat, "name": name, "items": its });
        std::fs::write(dir.join(format!("{cat}.json")), serde_json::to_string_pretty(&doc).unwrap()).unwrap();
    }
}

/// Blind scores split by a substring of `why` (diagnostics while tuning distractors).
#[test]
#[ignore]
fn blind_by_template() {
    let cat = std::env::var("IQ_CAT").unwrap_or("odd_shape".into());
    let key = std::env::var("IQ_KEY").unwrap_or("ayna".into());
    for hard in [false, true] {
        let its = items_for(&cat, hard, 300);
        let (a, b): (Vec<IqItem>, Vec<IqItem>) = its.into_iter().partition(|it| it.why.contains(&key));
        println!("hard={hard} with-key n={} {:?}", a.len(), blind_scores(&a));
        println!("hard={hard} without n={} {:?}", b.len(), blind_scores(&b));
    }
}
