//! Whole-sequence checks for the text/number categories: every item of the fixed 1000-question
//! sequence passes its category oracle, answers are spread over positions, there are no duplicate
//! questions, an option-only solver cannot beat chance, and generation is deterministic.

use super::common::option_texts;
use super::item::{IqItem, IqOption};
use serde_json::json;
use super::*;
use std::collections::HashMap;

type Checked = fn(&mut Rng, bool) -> (IqItem, Result<(), String>);

pub fn checked(id: &str) -> Option<Checked> {
    Some(match id {
        number_series::ID => number_series::gen_checked,
        missing_number::ID => missing_number::gen_checked,
        balance::ID => balance::gen_checked,
        logic::ID => logic::gen_checked,
        odd_number::ID => odd_number::gen_checked,
        letter_series::ID => letter_series::gen_checked,
        code::ID => code::gen_checked,
        clock_calendar::ID => clock_calendar::gen_checked,
        word_problem::ID => word_problem::gen_checked,
        _ => return None,
    })
}

/// All text-category items of the sequence, with the oracle verdict.
fn text_items(only: Option<&str>) -> Vec<(Slot, IqItem, Result<(), String>)> {
    sequence()
        .iter()
        .filter(|s| only.map_or(true, |o| s.plan().id == o))
        .filter_map(|s| checked(s.plan().id).map(|f| (s, f)))
        .map(|(s, f)| {
            let (it, res) = f(&mut s.rng(), s.hard);
            (*s, it, res)
        })
        .collect()
}

pub fn describe(it: &IqItem) -> String {
    let opts = option_texts(it);
    let fig = it.figure.as_ref().map(|f| f.to_string()).unwrap_or_default();
    format!(
        "[{}{}] {}\n   fig: {}\n   opts: {:?} answer: {} typed: {:?}\n   why: {}",
        it.cat,
        if it.hard { " zor" } else { "" },
        it.prompt,
        fig,
        opts,
        it.answer,
        it.typed,
        it.why
    )
}

/// Generation time per category: `cargo test --release iq_category_timing -- --ignored --nocapture`
#[test]
#[ignore]
fn iq_category_timing() {
    let mut by: HashMap<&str, (std::time::Duration, std::time::Duration, usize)> = HashMap::new();
    for s in sequence() {
        let Some(f) = checked(s.plan().id) else { continue };
        let t = std::time::Instant::now();
        let _ = f(&mut s.rng(), s.hard);
        let e = t.elapsed();
        let x = by.entry(s.plan().id).or_default();
        x.0 += e;
        x.1 = x.1.max(e);
        x.2 += 1;
    }
    let mut v: Vec<_> = by.into_iter().collect();
    v.sort_by_key(|x| std::cmp::Reverse(x.1 .1));
    for (id, (tot, max, n)) in v {
        println!("{id:16} n {n:3}  mean {:8.2?}  max {:8.2?}", tot / n as u32, max);
    }
}

/// Writes one view state per layout kind (and per typed / feedback variant) to `$IQ_DUMP`, for
/// eyeballing the Flutter view: `IQ_DUMP=/tmp/s.json cargo test --release iq_dump_states -- --ignored`.
#[test]
#[ignore]
fn iq_dump_states() {
    let Ok(path) = std::env::var("IQ_DUMP") else { return };
    let mut seen: Vec<String> = vec![];
    let mut out: Vec<serde_json::Value> = vec![];
    for (s, it, _) in text_items(None) {
        let layout = it.figure.as_ref().and_then(|f| f["layout"].as_str()).unwrap_or("none").to_string();
        let key = format!("{}|{}|{}", layout, it.typed.is_some(), it.options.iter().any(|o| matches!(o, IqOption::Figure(_))));
        if seen.contains(&key) {
            continue;
        }
        seen.push(key);
        let q = json!({
            "cat": it.cat, "cat_name": s.plan().name, "hard": it.hard, "prompt": it.prompt, "figure": it.figure,
            "options": it.options.iter().map(|o| o.to_json()).collect::<Vec<_>>(), "typed": it.typed.is_some(),
        });
        let fb = out.len() % 3 == 2;
        out.push(json!({
            "status": "playing", "stars": 0, "mode": "level", "phase": if fb { "feedback" } else { "question" },
            "q_index": 3, "q_count": 20, "answers": [true, false, true], "correct": 2, "streak": 1, "best_streak": 2, "lives": 0,
            "question": q,
            "last": if fb { json!({"given": if it.typed.is_some() { serde_json::Value::Null } else { json!((it.answer + 1) % it.options.len().max(1)) },
                                    "typed_value": it.typed.map(|v| v + 1), "answer": if it.typed.is_some() { serde_json::Value::Null } else { json!(it.answer) },
                                    "answer_value": it.typed, "correct": false, "why": it.why}) } else { serde_json::Value::Null },
        }));
    }
    std::fs::write(path, serde_json::to_string_pretty(&out).unwrap()).unwrap();
}

/// `IQ_SAMPLE=<category> cargo test --release iq_print_samples -- --nocapture --ignored`
#[test]
#[ignore]
fn iq_print_samples() {
    let cat = std::env::var("IQ_SAMPLE").unwrap_or_else(|_| "number_series".into());
    let n: usize = std::env::var("IQ_N").ok().and_then(|x| x.parse().ok()).unwrap_or(12);
    let items = text_items(Some(&cat));
    let step = (items.len() / n).max(1);
    for (s, it, res) in items.iter().step_by(step) {
        println!("#{} {}\n   oracle: {:?}\n", s.j, describe(it), res);
    }
}

#[test]
fn iq_text_items_pass_their_oracles() {
    let items = text_items(None);
    let bad: Vec<String> =
        items.iter().filter(|(_, _, r)| r.is_err()).map(|(s, it, r)| format!("{} #{}: {:?}\n{}", s.plan().id, s.j, r, describe(it))).collect();
    assert!(bad.is_empty(), "{} failing items:\n{}", bad.len(), bad.join("\n\n"));
}

#[test]
fn iq_text_items_deterministic_and_match_session() {
    for (s, it, _) in text_items(None).iter().step_by(7) {
        let again = s.item();
        assert_eq!(describe(it), describe(&again), "{} #{}", s.plan().id, s.j);
        assert_eq!(it.hard, s.hard);
        assert_eq!(it.cat, s.plan().id);
    }
}

#[test]
fn iq_text_items_no_duplicates() {
    let mut seen: HashMap<String, String> = HashMap::new();
    for (s, it, _) in text_items(None) {
        let mut opts = option_texts(&it);
        opts.sort();
        let key = format!("{}|{}|{}|{:?}", it.cat, it.prompt, it.figure.as_ref().map(|f| f.to_string()).unwrap_or_default(), opts);
        if let Some(prev) = seen.insert(key, format!("{} #{}", s.plan().id, s.j)) {
            panic!("duplicate question: {prev} and {} #{}\n{}", s.plan().id, s.j, describe(&it));
        }
    }
}

#[test]
fn iq_text_answers_spread_over_positions() {
    let mut by_cat: HashMap<&str, Vec<(usize, usize)>> = HashMap::new();
    for (_, it, _) in text_items(None) {
        if it.typed.is_none() {
            by_cat.entry(it.cat).or_default().push((it.answer, it.options.len()));
        }
    }
    for (cat, v) in by_cat {
        let maxn = v.iter().map(|x| x.1).max().unwrap();
        let mut counts = vec![0usize; maxn];
        for &(a, _) in &v {
            counts[a] += 1;
        }
        // Binomial allowance: each of the first four positions within 3 standard deviations.
        let n = v.len() as f64;
        for (pos, &c) in counts.iter().enumerate().take(4) {
            let p = v.iter().filter(|x| x.1 > pos).map(|x| 1.0 / x.1 as f64).sum::<f64>() / n;
            let e = n * p;
            let sd = (n * p * (1.0 - p)).sqrt();
            assert!((c as f64 - e).abs() <= 3.0 * sd + 1.0, "{cat}: answer position {pos} count {c}, expected {e:.1} ({counts:?})");
        }
    }
}

/// Owner's rule: the length of a text option must not give the answer away. Per category, the
/// correct option is the strictly longest in at most 25 % of the items, and the strictly
/// shortest in at most 25 %.
#[test]
fn iq_text_answer_length_is_no_giveaway() {
    let mut by_cat: HashMap<&str, (usize, usize, usize)> = HashMap::new();
    for (_, it, _) in text_items(None) {
        if it.typed.is_some() || it.options.iter().any(|o| matches!(o, IqOption::Figure(_))) {
            continue;
        }
        let lens: Vec<usize> = option_texts(&it).iter().map(|t| t.chars().count()).collect();
        let a = lens[it.answer];
        let longest = lens.iter().enumerate().all(|(i, &l)| i == it.answer || l < a);
        let shortest = lens.iter().enumerate().all(|(i, &l)| i == it.answer || l > a);
        let e = by_cat.entry(it.cat).or_default();
        e.0 += 1;
        e.1 += longest as usize;
        e.2 += shortest as usize;
    }
    let mut bad = vec![];
    for (cat, (n, long, short)) in by_cat {
        let (fl, fs) = (long as f64 / n as f64, short as f64 / n as f64);
        if fl > 0.25 || fs > 0.25 {
            bad.push(format!("{cat}: strictly longest {fl:.2}, strictly shortest {fs:.2} (n {n})"));
        }
    }
    assert!(bad.is_empty(), "{}", bad.join("\n"));
}

// ------------------------------------------------------------------- option-only bias check

fn opt_key(o: &IqOption) -> String {
    match o {
        IqOption::Text(t) => t.clone(),
        IqOption::Figure(f) => f.to_string(),
    }
}

fn as_num(o: &IqOption) -> Option<f64> {
    match o {
        IqOption::Text(t) => {
            let t = t.replace('\u{2212}', "-").replace(',', ".").replace('°', "").replace(':', "");
            t.trim().parse().ok()
        }
        _ => None,
    }
}

fn letters_of(o: &IqOption) -> Vec<char> {
    opt_key(o).chars().filter(|c| c.is_alphanumeric()).collect()
}

/// Option-only heuristics: each looks at the option set alone and names one option.
fn heuristics() -> Vec<(&'static str, fn(&[IqOption]) -> usize)> {
    fn argmax(v: Vec<f64>) -> usize {
        let mut best = 0;
        for i in 1..v.len() {
            if v[i] > v[best] {
                best = i;
            }
        }
        best
    }
    vec![
        ("first", |_| 0),
        ("last", |o| o.len() - 1),
        ("largest", |o| argmax(o.iter().map(|x| as_num(x).unwrap_or(0.0)).collect())),
        ("smallest", |o| argmax(o.iter().map(|x| -as_num(x).unwrap_or(0.0)).collect())),
        ("closest to mean", |o| {
            let v: Vec<f64> = o.iter().map(|x| as_num(x).unwrap_or(0.0)).collect();
            let m = v.iter().sum::<f64>() / v.len() as f64;
            argmax(v.iter().map(|x| -(x - m).abs()).collect())
        }),
        ("median rank", |o| o.len() / 2),
        ("longest", |o| argmax(o.iter().map(|x| opt_key(x).chars().count() as f64).collect())),
        ("shortest", |o| argmax(o.iter().map(|x| -(opt_key(x).chars().count() as f64)).collect())),
        ("most similar to others", |o| {
            argmax(
                o.iter()
                    .map(|a| {
                        let la = letters_of(a);
                        o.iter()
                            .map(|b| {
                                let lb = letters_of(b);
                                la.iter().zip(lb.iter()).filter(|(x, y)| x == y).count() as f64
                            })
                            .sum::<f64>()
                    })
                    .collect(),
            )
        }),
        ("unique parity", |o| {
            let par: Vec<i64> = o.iter().map(|x| as_num(x).map(|v| (v as i64).rem_euclid(2)).unwrap_or(2)).collect();
            (0..o.len()).find(|&i| par.iter().filter(|&&p| p == par[i]).count() == 1).unwrap_or(0)
        }),
        ("unique last char", |o| {
            let last: Vec<char> = o.iter().map(|x| opt_key(x).chars().last().unwrap_or(' ')).collect();
            (0..o.len()).find(|&i| last.iter().filter(|&&p| p == last[i]).count() == 1).unwrap_or(0)
        }),
        ("closest to its nearest neighbour", |o| {
            let v: Vec<f64> = o.iter().map(|x| as_num(x).unwrap_or(0.0)).collect();
            argmax(
                (0..v.len())
                    .map(|i| -(0..v.len()).filter(|&j| j != i).map(|j| (v[i] - v[j]).abs()).fold(f64::MAX, f64::min))
                    .collect(),
            )
        }),
    ]
}

#[test]
fn iq_text_option_only_solver_is_near_chance() {
    let mut by_cat: HashMap<&str, Vec<IqItem>> = HashMap::new();
    for (_, it, _) in text_items(None) {
        if it.typed.is_none() {
            by_cat.entry(it.cat).or_default().push(it);
        }
    }
    let mut report = vec![];
    for (cat, items) in &by_cat {
        let chance = items.iter().map(|i| 1.0 / i.options.len() as f64).sum::<f64>() / items.len() as f64;
        // Binomial noise allowance: small categories get a slightly wider margin.
        let margin = 0.12 + 1.0 / (items.len() as f64).sqrt() * 0.5;
        for (name, h) in heuristics() {
            let hits = items.iter().filter(|it| h(&it.options) == it.answer).count();
            let acc = hits as f64 / items.len() as f64;
            if acc > chance + margin {
                report.push(format!("{cat}: '{name}' gets {acc:.2} (chance {chance:.2}, n {})", items.len()));
            }
        }
    }
    assert!(report.is_empty(), "option-only bias:\n{}", report.join("\n"));
}
