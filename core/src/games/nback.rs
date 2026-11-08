//! N-Back — working-memory updating and attention-control training.
//!
//! # Level mode: single-stream N-back ("Seviye N")
//!
//! One stimulus at a time (a digit, a letter or a two-digit number) appears in the middle of the
//! screen for `stim_ms`, then the card goes blank until the next trial (`period_ms` per trial). The
//! whole card is the "match" button: tap when the current item equals the one **N trials back**.
//! The response window is the whole trial.
//!
//! - **Goal**: catch [`GOAL_HITS`] (= 17) matches. Hit #17 wins immediately.
//! - **Error budget** (`errors`): every false alarm (tap on a non-match) and every miss (a match
//!   that ends without a tap) costs one; the run is lost the moment the budget is spent. A budget
//!   of 3 means two free errors — the third one ends the run.
//! - **Fairness**: the first N trials can never match; a tap there is ignored (no error, no state
//!   change). A second tap on the same trial is a harmless no-op.
//! - **Stars**: 3 = no errors, 2 = one error, 1 = won with more errors. Turning on the "N geride"
//!   helper strip (`{"helper":true}`) during a run caps the result at 1 star.
//! - **Stream**: `N + 88` trials; the 88 scorable trials are 8 windows of 11, each with exactly 3
//!   matches (27% density, no long droughts or clumps), so a clean run lasts ≈ N + 56..66 trials
//!   (≈ 2–2.5 min) and the stream can never run out before the run is decided (24 matches, at most
//!   17 + 4 are ever needed). No item ever appears three times in a row (at N = 1 two matches are
//!   never adjacent).
//! - **Small alphabet** ([`alphabet_for`]): a level-specific subset of 9 items at N = 1–2, 8 at
//!   N = 3, 7 at N = 4, 6 from N = 5, so repeats — and with them lures — are frequent.
//! - **Lures** ([`LureKind`], classified on the finished stream by [`lure_kind`]): non-matches built
//!   to feel like matches, so neither recency nor familiarity can win the level:
//!   - `n-1` / `n+1`: the item repeats the one N−1 / N+1 back (not the one N back). 1-back uses
//!     only N+1 (an immediate repeat *is* the match there) and sequence lures.
//!   - `seq` (sequence lure, "neyden sonra ne geliyor"): the previous item X was followed by Y
//!     within the last N + 3 items, and Y follows X again — at the wrong distance. The generator
//!     sets these up by repeating a recent X just before the lure slot.
//!   Planned lures are spread over random non-match slots, kinds dealt evenly; a lure that cannot
//!   be built at its slot moves on, and accidental lures from filler slots replace planned ones, so
//!   the measured share stays on the plan. Fillers avoid the N-back item (never an accidental
//!   match), the N±1 items, the recent followers of the previous item and immediate repeats.
//! - Results: `Doğru` (hits), `Yanlış` (false alarms), `Kaçırılan` (misses),
//!   `Verimlilik` = hits / (hits + false alarms + misses), time, mean reaction time of hits, and how
//!   many false alarms were lures ("3 çeldiriciye takıldın (n−1)").
//!
//! ## Level curve ([`level_params`])
//!
//! N tiers (first level of each): N1 = 1, N2 = 2, N3 = 15, N4 = 40, N5 = 80, N6 = 135, N7 = 205,
//! N8 = 290, N9 = 390..500. With k = position inside the tier, u = k / (tier length − 1) and
//! g = (level − 1) / 499:
//! - **Tier intro** (k < 2): digits 1–9, no lures, 3-error budget — a gentle first look at a new N.
//! - **Stimulus sets** (k ≥ 2) rotate through the unlocked sets: digits always, letters from level
//!   5, two-digit numbers (10–99, two syllables to rehearse) from level 20.
//! - **Pace**: `period_ms` = 2500 − 450·g − 250·u (2500 → 1800, a sawtooth that tightens inside
//!   each tier and overall); `stim_ms` = 500 − 100·g (500 → 400).
//! - **Lures** on every level: share of the 64 non-match trials = 0.20 on tier intros, otherwise
//!   0.20 + 0.10·g (13 → 19 lures).
//! - **Error budget**: 5 below level 40 and on tier intros, otherwise 3.
//!
//! # Endless mode: dual (position + digit) adaptive N-back (Jaeggi-style)
//!
//! A 3×3 grid; each trial lights one cell with a digit inside. Two buttons: `Konum` and `Rakam`.
//! Blocks of `20 + N` trials; per modality exactly 6 of the 20 scorable trials (30%) are targets.
//! Accuracy = **balanced accuracy** = ½·(hits/targets + correct rejections/non-targets) — never
//! pressing or always pressing both score 50% — averaged over both modalities; d′ (log-linear
//! corrected) is reported too. 10 blocks starting at N = 2; after a block N goes up on ≥ 90%,
//! down on < 75% (min 1). `score` = round(100 × mean N), the run ends (`lost`) after block 10.
//!
//! # State
//!
//! Common: `{status, stars, mode: "level"|"endless", phase: "intro"|"countdown"|"run"|"break"|
//! "done", title, goal, summary?, n, trial, trials, period_ms, stim_ms, t_ms, countdown_ms}`.
//! Level: `{set: "digits"|"letters"|"numbers", set_label, lures, stim: "7"|null, can_match, pressed,
//! hits, goal_hits, misses, false_alarms, errors, error_budget, errors_left, efficiency,
//! elapsed_ms, avg_rt_ms|null, feedback: {serial, result: "hit"|"false_alarm"|"miss"|"",
//! lure_kind: "n-1"|"n+1"|"seq"|null (false alarms on a lure only)}, lure_falls: {"n-1", "n+1",
//! "seq"} (false alarms on lures so far), lure_summary: "3 çeldiriciye takıldın (n−1)"|null, helper,
//! recent: [..] (helper on only: the previous ≤ N items, oldest first)}`. The current trial's lure
//! kind is never exposed before a response.
//! Endless: `{score, modalities, stim: {pos, digit}|null, pressed: {mod: bool}, feedback: {mod:
//! {serial, result}}, stats: {mod: {hits, misses, false_alarms, correct_rejections, accuracy,
//! dprime}}, accuracy, block, blocks, n_history, last_block: {n, accuracy, change}|null}`.
//!
//! Actions: `{"start":true}` (intro / between blocks) · level: `{"match":true}`, `{"helper":bool}` ·
//! endless: `{"match":"position"|"digit"}`.

use crate::rng::{seed_for, time_seed, Rng};
use crate::Session;
use serde_json::{json, Map, Value};

pub const COUNTDOWN_MS: f64 = 3000.0;

pub fn create(level: u32, mode: &str) -> Result<Box<dyn Session>, String> {
    Ok(if mode == "endless" { Box::new(Dual::endless(time_seed())) } else { Box::new(Single::level(level)) })
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Phase {
    Intro,
    Countdown,
    Run,
    Break,
    Done,
}

impl Phase {
    fn name(self) -> &'static str {
        match self {
            Phase::Intro => "intro",
            Phase::Countdown => "countdown",
            Phase::Run => "run",
            Phase::Break => "break",
            Phase::Done => "done",
        }
    }
}

/// Fill a value sequence for fixed match slots. Match slots copy the N-back value; planned lure
/// slots take an (N−1)- or (N+1)-back value (a lure that is impossible at its slot moves to the
/// next non-match slot); every other slot avoids the N-back value and both near values.
fn fill_sequence(r: &mut Rng, n: usize, target: &[bool], want_lure: &[bool], values: usize) -> (Vec<u16>, Vec<bool>) {
    let len = target.len();
    let mut seq: Vec<u16> = Vec::with_capacity(len);
    let mut lure = vec![false; len];
    let mut debt = 0;
    for i in 0..len {
        if target[i] {
            let v = seq[i - n];
            seq.push(v);
            continue;
        }
        if want_lure[i] {
            debt += 1;
        }
        let back_n = (i >= n).then(|| seq[i - n]);
        let near: Vec<u16> = [(n >= 2 && i + 1 >= n).then(|| seq[i + 1 - n]), (i > n).then(|| seq[i - n - 1])]
            .into_iter()
            .flatten()
            .filter(|&v| Some(v) != back_n)
            .collect();
        if debt > 0 && i >= n && !near.is_empty() {
            seq.push(*r.pick(&near));
            lure[i] = true;
            debt -= 1;
            continue;
        }
        let allowed: Vec<u16> = (0..values as u16).filter(|&v| Some(v) != back_n && !near.contains(&v)).collect();
        seq.push(*r.pick(&allowed));
    }
    (seq, lure)
}

/// `0.5` → `"0,5"` (Turkish decimal comma).
fn fmt1(x: f64) -> String {
    format!("{:.1}", x).replace('.', ",")
}

fn fmt_time(ms: f64) -> String {
    let s = (ms / 1000.0).round() as u64;
    format!("{}:{:02}", s / 60, s % 60)
}

// =====================================================================================
// Level mode: single stream
// =====================================================================================

pub const GOAL_HITS: u32 = 17;
/// Scorable trials per stream (after the first N): 8 windows of 11.
pub const SCORED_LEVEL: usize = 88;
const WINDOW: usize = 11;
const TARGETS_PER_WINDOW: usize = 3;
/// Matches in a stream (24): enough for 17 hits plus a full error budget of misses.
pub const TARGETS_LEVEL: usize = SCORED_LEVEL / WINDOW * TARGETS_PER_WINDOW;
/// Non-match scorable trials per stream (64): the pool lures are planted in.
pub const NONTARGETS_LEVEL: usize = SCORED_LEVEL - TARGETS_LEVEL;
const LETTERS_FROM: u32 = 5;
const NUMBERS_FROM: u32 = 20;
/// (N, first level of the tier).
const TIERS: [(usize, u32); 9] = [(1, 1), (2, 2), (3, 15), (4, 40), (5, 80), (6, 135), (7, 205), (8, 290), (9, 390)];
/// Consonants with clear, distinct shapes (no I/O/Ç/Ğ/Ş look-alikes).
const LETTERS: [char; 14] = ['B', 'C', 'D', 'F', 'G', 'H', 'K', 'L', 'M', 'P', 'R', 'S', 'T', 'Z'];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StimSet {
    Digits,
    Letters,
    Numbers,
}

impl StimSet {
    pub fn values(self) -> usize {
        match self {
            StimSet::Digits => 9,
            StimSet::Letters => LETTERS.len(),
            StimSet::Numbers => 90,
        }
    }

    fn id(self) -> &'static str {
        match self {
            StimSet::Digits => "digits",
            StimSet::Letters => "letters",
            StimSet::Numbers => "numbers",
        }
    }

    fn label(self) -> &'static str {
        match self {
            StimSet::Digits => "Rakamlar",
            StimSet::Letters => "Harfler",
            StimSet::Numbers => "İki basamaklı sayılar",
        }
    }

    pub fn show(self, v: u16) -> String {
        match self {
            StimSet::Digits => (v + 1).to_string(),
            StimSet::Letters => LETTERS[v as usize % LETTERS.len()].to_string(),
            StimSet::Numbers => (v + 10).to_string(),
        }
    }
}

/// Kind of a lure (a non-match built to feel like a match).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LureKind {
    /// Repeats the item N−1 back (one step too early).
    Minus,
    /// Repeats the item N+1 back (one step too late).
    Plus,
    /// Sequence lure: the previous item X was recently followed by Y, and Y follows X again — but
    /// at the wrong distance ("what usually comes after X").
    Seq,
}

impl LureKind {
    pub const ALL: [LureKind; 3] = [LureKind::Minus, LureKind::Plus, LureKind::Seq];

    pub fn id(self) -> &'static str {
        match self {
            LureKind::Minus => "n-1",
            LureKind::Plus => "n+1",
            LureKind::Seq => "seq",
        }
    }

    /// Short Turkish label for summaries.
    pub fn label(self) -> &'static str {
        match self {
            LureKind::Minus => "n−1",
            LureKind::Plus => "n+1",
            LureKind::Seq => "sıra",
        }
    }
}

/// How far back a sequence lure looks for an earlier "X → Y" pair.
fn seq_window(n: usize) -> usize {
    n + 3
}

/// Values that followed the previous item `s[i-1]` in a recent, complete earlier pair
/// (`s[j] == s[i-1]`, `j + 1 < i - 1`, within [`seq_window`]).
fn seq_followers(s: &[u16], n: usize, i: usize) -> Vec<u16> {
    if i < 3 {
        return vec![];
    }
    let x = s[i - 1];
    let lo = (i - 1).saturating_sub(seq_window(n));
    (lo..i - 2).filter(|&j| s[j] == x).map(|j| s[j + 1]).collect()
}

/// Classify slot `i` of a finished sequence: `None` for matches, slots before N and plain fillers.
/// Priority when several apply: N−1, N+1, sequence.
pub fn lure_kind(s: &[u16], n: usize, i: usize) -> Option<LureKind> {
    if i < n || s[i] == s[i - n] {
        return None;
    }
    if n >= 2 && s[i] == s[i + 1 - n] {
        return Some(LureKind::Minus);
    }
    if i > n && s[i] == s[i - n - 1] {
        return Some(LureKind::Plus);
    }
    if seq_followers(s, n, i).contains(&s[i]) {
        return Some(LureKind::Seq);
    }
    None
}

#[derive(Clone, Debug, PartialEq)]
pub struct LevelParams {
    pub n: usize,
    pub set: StimSet,
    pub stim_ms: f64,
    pub period_ms: f64,
    /// Distinct items used in the stream (a small alphabet makes repeats — and lures — frequent).
    pub alphabet: usize,
    /// Planned lures among the [`NONTARGETS_LEVEL`] non-match trials.
    pub lure_count: usize,
    /// Error budget: the run is lost when this many errors have been made.
    pub errors: u32,
}

/// Level → parameters. See the module docs for the curve.
pub fn level_params(level: u32) -> LevelParams {
    let level = level.clamp(1, crate::MAX_LEVEL);
    let ti = TIERS.iter().rposition(|&(_, start)| start <= level).unwrap_or(0);
    let (n, start) = TIERS[ti];
    let end = TIERS.get(ti + 1).map_or(crate::MAX_LEVEL + 1, |t| t.1);
    let k = level - start;
    let tier_len = end - start;
    let u = if tier_len > 1 { k as f64 / (tier_len - 1) as f64 } else { 0.0 };
    let g = (level - 1) as f64 / (crate::MAX_LEVEL - 1) as f64;
    let intro = k < 2;
    let mut sets = vec![StimSet::Digits];
    if level >= LETTERS_FROM {
        sets.push(StimSet::Letters);
    }
    if level >= NUMBERS_FROM {
        sets.push(StimSet::Numbers);
    }
    let set = if intro { StimSet::Digits } else { sets[(k as usize - 2) % sets.len()] };
    // Lures: 20% of the non-match trials on tier intros, otherwise 20% → 30% over the 500 levels.
    let lure_rate = if intro { 0.20 } else { 0.20 + 0.10 * g };
    LevelParams {
        n,
        set,
        stim_ms: (500.0 - 100.0 * g).round(),
        period_ms: (2500.0 - 450.0 * g - 250.0 * u).round(),
        alphabet: alphabet_for(n),
        lure_count: (lure_rate * NONTARGETS_LEVEL as f64).round() as usize,
        errors: if level < 40 || intro { 5 } else { 3 },
    }
}

/// Distinct items per stream: 9 at N = 1–2, then one fewer per N down to 6 from N = 5.
pub fn alphabet_for(n: usize) -> usize {
    match n {
        0..=2 => 9,
        3 => 8,
        4 => 7,
        _ => 6,
    }
}

/// One generated single-modality stream.
#[derive(Clone, Debug, PartialEq)]
pub struct Stream {
    pub n: usize,
    pub len: usize,
    pub seq: Vec<u16>,
    pub target: Vec<bool>,
    /// Lure kind of every slot, classified on the finished sequence ([`lure_kind`]).
    pub lure: Vec<Option<LureKind>>,
}

impl Stream {
    pub fn lure_count(&self) -> usize {
        self.lure.iter().filter(|l| l.is_some()).count()
    }
}

/// Would `v` at slot `i` (followed by the forced values of the match slots right after it) create a
/// run of three equal items?
fn makes_run(seq: &[u16], target: &[bool], n: usize, i: usize, v: u16) -> bool {
    // tail[k] = the value at slot base + k.
    let base = i.saturating_sub(2);
    let mut tail: Vec<u16> = seq[base..i].to_vec();
    tail.push(v);
    let mut t = i + 1;
    while t < target.len() && target[t] {
        let src = t - n;
        tail.push(if src < base { seq[src] } else { tail[src - base] });
        t += 1;
    }
    tail.windows(3).any(|w| w[0] == w[1] && w[1] == w[2])
}

/// One attempt at filling a stream; `None` when the forced matches produced a run of three.
fn try_stream(r: &mut Rng, p: &LevelParams) -> Option<Stream> {
    let n = p.n;
    let len = n + SCORED_LEVEL;
    let mut target = vec![false; len];
    for w in 0..SCORED_LEVEL / WINDOW {
        let mut slots: Vec<usize> = (n + w * WINDOW..n + (w + 1) * WINDOW).collect();
        r.shuffle(&mut slots);
        let mut placed = 0;
        for &i in &slots {
            if placed == TARGETS_PER_WINDOW {
                break;
            }
            // 1-back: two matches in a row would be three equal items in a row.
            if n == 1 && (target[i - 1] || target.get(i + 1) == Some(&true)) {
                continue;
            }
            target[i] = true;
            placed += 1;
        }
        if placed < TARGETS_PER_WINDOW {
            return None;
        }
    }
    // Alphabet: a level-specific subset of the stimulus set.
    let mut pool: Vec<u16> = (0..p.set.values() as u16).collect();
    r.shuffle(&mut pool);
    pool.truncate(p.alphabet.min(pool.len()));
    // Plan the lures: random non-match slots, kinds dealt evenly (no N−1 lure at N = 1).
    let kinds: Vec<LureKind> = if n == 1 { vec![LureKind::Plus, LureKind::Seq] } else { LureKind::ALL.to_vec() };
    let mut free: Vec<usize> = (n..len).filter(|&i| !target[i]).collect();
    r.shuffle(&mut free);
    let mut want: Vec<Option<LureKind>> = vec![None; len];
    let offset = r.below(kinds.len());
    for (k, &i) in free.iter().take(p.lure_count).enumerate() {
        want[i] = Some(kinds[(k + offset) % kinds.len()]);
    }

    let mut seq: Vec<u16> = Vec::with_capacity(len);
    // Planned lures not placed yet, with how many slots each has waited (a lure that cannot be
    // built at its slot moves on; after `PATIENCE` slots another kind is used instead), and
    // accidental lures that cancel later planned ones, so the total stays at the plan.
    const PATIENCE: u32 = 3;
    let mut queue: Vec<(LureKind, u32)> = vec![];
    let mut credit = 0usize;
    for i in 0..len {
        if target[i] {
            let v = seq[i - n];
            seq.push(v);
            continue;
        }
        let back_n = (i >= n).then(|| seq[i - n]);
        let ok = |v: u16, seq: &[u16]| Some(v) != back_n && !makes_run(seq, &target, n, i, v);
        if let Some(k) = want[i] {
            if credit > 0 {
                credit -= 1;
            } else {
                queue.push((k, 0));
            }
        }
        let near_minus = (n >= 2 && i + 1 >= n).then(|| seq[i + 1 - n]);
        let near_plus = (i > n).then(|| seq[i - n - 1]);
        let followers = seq_followers(&seq, n, i);
        // Plant the oldest pending lure: its own kind, or — once it has waited long enough — any
        // other kind (sequence lures first, they are the hardest to build).
        if i >= n && !queue.is_empty() {
            let (want_k, age) = queue[0];
            let mut order = vec![want_k];
            if age >= PATIENCE {
                order.extend([LureKind::Seq, LureKind::Plus, LureKind::Minus].into_iter().filter(|&k| k != want_k && kinds.contains(&k)));
            }
            let mut planted = None;
            for k in order {
                let mut cands: Vec<u16> = match k {
                    LureKind::Minus => near_minus.into_iter().collect(),
                    LureKind::Plus => near_plus.into_iter().filter(|&v| Some(v) != near_minus).collect(),
                    LureKind::Seq => {
                        followers.iter().copied().filter(|&v| Some(v) != near_minus && Some(v) != near_plus).collect()
                    }
                };
                cands.retain(|&v| ok(v, &seq));
                cands.dedup();
                if !cands.is_empty() {
                    planted = Some(*r.pick(&cands));
                    break;
                }
            }
            if let Some(v) = planted {
                seq.push(v);
                queue.remove(0);
                continue;
            }
            queue[0].1 += 1;
        }
        // Filler: never a match; avoid lure values and immediate repeats when the alphabet allows.
        let prev = i.checked_sub(1).map(|j| seq[j]);
        let allowed: Vec<u16> = pool.iter().copied().filter(|&v| ok(v, &seq)).collect();
        let is_near = |v: u16| Some(v) == near_minus || Some(v) == near_plus;
        let tiers: [Vec<u16>; 4] = [
            allowed.iter().copied().filter(|&v| !is_near(v) && !followers.contains(&v) && Some(v) != prev).collect(),
            allowed.iter().copied().filter(|&v| !is_near(v) && !followers.contains(&v)).collect(),
            allowed.iter().copied().filter(|&v| !is_near(v)).collect(),
            allowed.clone(),
        ];
        let Some(mut choice) = tiers.iter().find(|t| !t.is_empty()).cloned() else {
            return None;
        };
        // Set up a sequence lure due on the next slot: repeat a recent "X" whose follower "Y" can
        // come next as a pure sequence lure (not a match, not N±1). X itself stays a plain filler.
        let next_seq = i >= n
            && i + 1 < len
            && !target[i + 1]
            && (want[i + 1] == Some(LureKind::Seq) || queue.first().map(|q| q.0) == Some(LureKind::Seq));
        if next_seq {
            let k = i + 1;
            let can_setup = |x: u16| {
                let mut s2 = seq.clone();
                s2.push(x);
                seq_followers(&s2, n, k).into_iter().any(|y| {
                    let mut s3 = s2.clone();
                    s3.push(y);
                    !makes_run(&s2, &target, n, k, y) && lure_kind(&s3, n, k) == Some(LureKind::Seq)
                })
            };
            if let Some(setups) =
                tiers[..2].iter().map(|t| t.iter().copied().filter(|&x| can_setup(x)).collect::<Vec<u16>>()).find(|t| !t.is_empty())
            {
                choice = setups;
            }
        }
        let v = *r.pick(&choice);
        seq.push(v);
        if lure_kind(&seq, n, i).is_some() {
            if queue.is_empty() {
                credit += 1;
            } else {
                queue.remove(0);
            }
        }
    }
    // Validate: matches exactly where planned, no run of three anywhere.
    for i in 0..len {
        if (i >= n && seq[i] == seq[i - n]) != target[i] {
            return None;
        }
    }
    if seq.windows(3).any(|w| w[0] == w[1] && w[1] == w[2]) {
        return None;
    }
    let lure = (0..len).map(|i| lure_kind(&seq, n, i)).collect();
    Some(Stream { n, len, seq, target, lure })
}

/// Level stream: [`TARGETS_LEVEL`] matches (3 in every window of 11 scorable trials), planned
/// lures of all kinds, fillers that avoid accidental lures, no run of three equal items.
pub fn gen_stream(r: &mut Rng, p: &LevelParams) -> Stream {
    for _ in 0..500 {
        if let Some(s) = try_stream(r, p) {
            return s;
        }
    }
    unreachable!("nback: no valid stream for {p:?}")
}

pub struct Single {
    p: LevelParams,
    s: Stream,
    phase: Phase,
    countdown_ms: f64,
    trial: usize,
    t_ms: f64,
    elapsed_ms: f64,
    pressed: bool,
    hits: u32,
    misses: u32,
    false_alarms: u32,
    rt_sum_ms: f64,
    feedback: (u32, &'static str, Option<LureKind>),
    serial: u32,
    /// False alarms on lures, per kind (N−1, N+1, sequence).
    lure_falls: [u32; 3],
    helper: bool,
    helper_used: bool,
    won: bool,
    stars: u32,
}

impl Single {
    pub fn level(level: u32) -> Self {
        let p = level_params(level);
        let mut rng = Rng::new(seed_for("nback", level, 0));
        let s = gen_stream(&mut rng, &p);
        Single {
            p,
            s,
            phase: Phase::Intro,
            countdown_ms: COUNTDOWN_MS,
            trial: 0,
            t_ms: 0.0,
            elapsed_ms: 0.0,
            pressed: false,
            hits: 0,
            misses: 0,
            false_alarms: 0,
            rt_sum_ms: 0.0,
            feedback: (0, "", None),
            serial: 0,
            lure_falls: [0; 3],
            helper: false,
            helper_used: false,
            won: false,
            stars: 0,
        }
    }

    fn errors(&self) -> u32 {
        self.misses + self.false_alarms
    }

    fn efficiency(&self) -> f64 {
        let all = self.hits + self.errors();
        if all == 0 {
            0.0
        } else {
            self.hits as f64 / all as f64
        }
    }

    fn finish(&mut self, won: bool) {
        self.phase = Phase::Done;
        self.won = won;
        self.stars = match (won, self.helper_used, self.errors()) {
            (false, _, _) => 0,
            (true, true, _) => 1,
            (true, false, 0) => 3,
            (true, false, 1) => 2,
            _ => 1,
        };
    }

    fn end_trial(&mut self) {
        let i = self.trial;
        if i >= self.s.n && self.s.target[i] && !self.pressed {
            self.misses += 1;
            self.serial += 1;
            self.feedback = (self.serial, "miss", None);
            if self.errors() >= self.p.errors {
                self.finish(false);
                return;
            }
        }
        self.pressed = false;
        self.trial += 1;
        if self.trial >= self.s.len {
            // Unreachable in practice: the stream holds more matches than a run can consume.
            self.finish(false);
        }
    }

    /// "3 çeldiriciye takıldın (n−1)" / "3 çeldiriciye takıldın (2 n−1, 1 sıra)"; None without lure falls.
    fn lure_line(&self) -> Option<String> {
        let total: u32 = self.lure_falls.iter().sum();
        if total == 0 {
            return None;
        }
        let parts: Vec<(u32, &str)> =
            LureKind::ALL.iter().zip(self.lure_falls).filter(|(_, c)| *c > 0).map(|(k, c)| (c, k.label())).collect();
        let detail = if parts.len() == 1 {
            parts[0].1.to_string()
        } else {
            parts.iter().map(|(c, l)| format!("{c} {l}")).collect::<Vec<_>>().join(", ")
        };
        Some(format!("{total} çeldiriciye takıldın ({detail})"))
    }

    fn summary(&self) -> String {
        let hits = if self.won { self.hits.to_string() } else { format!("{}/{}", self.hits, GOAL_HITS) };
        let mut out = format!(
            "Doğru {hits} · Yanlış {} · Kaçırılan {} · Verimlilik %{} · Süre {}",
            self.false_alarms,
            self.misses,
            (self.efficiency() * 100.0).round(),
            fmt_time(self.elapsed_ms)
        );
        if let Some(l) = self.lure_line() {
            out.push_str(" · ");
            out.push_str(&l);
        }
        out
    }
}

impl Session for Single {
    fn state(&self) -> Value {
        let n = self.p.n;
        let running = self.phase == Phase::Run;
        let visible = running && self.t_ms < self.p.stim_ms && self.trial < self.s.len;
        let stim = visible.then(|| self.p.set.show(self.s.seq[self.trial]));
        let recent: Vec<String> = if self.helper && running {
            (self.trial.saturating_sub(n)..self.trial).map(|i| self.p.set.show(self.s.seq[i])).collect()
        } else {
            vec![]
        };
        let done = self.phase == Phase::Done;
        json!({
            "status": match (done, self.won) { (false, _) => "playing", (true, true) => "won", _ => "lost" },
            "stars": self.stars,
            "mode": "level",
            "phase": self.phase.name(),
            "title": format!("{n}-Back"),
            "goal": format!("{GOAL_HITS} eşleşme yakala · {} hata hakkı", self.p.errors),
            "summary": done.then(|| self.summary()),
            "n": n,
            "set": self.p.set.id(),
            "set_label": self.p.set.label(),
            "lures": self.p.lure_count > 0,
            "trial": self.trial.min(self.s.len),
            "trials": self.s.len,
            "period_ms": self.p.period_ms,
            "stim_ms": self.p.stim_ms,
            "t_ms": self.t_ms.round(),
            "countdown_ms": self.countdown_ms.max(0.0).round(),
            "stim": stim,
            "can_match": running && self.trial >= n,
            "pressed": self.pressed,
            "hits": self.hits,
            "goal_hits": GOAL_HITS,
            "misses": self.misses,
            "false_alarms": self.false_alarms,
            "errors": self.errors(),
            "error_budget": self.p.errors,
            "errors_left": self.p.errors.saturating_sub(self.errors()),
            "efficiency": (self.efficiency() * 1000.0).round() / 1000.0,
            "elapsed_ms": self.elapsed_ms.round(),
            "avg_rt_ms": (self.hits > 0).then(|| (self.rt_sum_ms / self.hits as f64).round()),
            "feedback": {
                "serial": self.feedback.0, "result": self.feedback.1,
                "lure_kind": self.feedback.2.map(LureKind::id),
            },
            "lure_falls": {
                "n-1": self.lure_falls[0], "n+1": self.lure_falls[1], "seq": self.lure_falls[2],
            },
            "lure_summary": self.lure_line(),
            "helper": self.helper,
            "helper_used": self.helper_used,
            "recent": recent,
        })
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if self.phase == Phase::Done {
            return Err("Bitti".into());
        }
        if let Some(on) = a["helper"].as_bool() {
            self.helper = on;
            if on && matches!(self.phase, Phase::Countdown | Phase::Run) {
                self.helper_used = true;
            }
            return Ok(());
        }
        if a["start"].as_bool() == Some(true) {
            if self.phase != Phase::Intro {
                return Err("Oyun zaten sürüyor".into());
            }
            self.phase = Phase::Countdown;
            self.countdown_ms = COUNTDOWN_MS;
            if self.helper {
                self.helper_used = true;
            }
            return Ok(());
        }
        if !matches!(a.get("match"), Some(Value::Bool(true)) | Some(Value::String(_))) {
            return Err("Bilinmeyen hamle".into());
        }
        if self.phase != Phase::Run {
            return Err("Henüz başlamadı".into());
        }
        if self.trial < self.s.n || self.pressed {
            // First N trials cannot match; a repeated tap on the same trial counts once.
            return Ok(());
        }
        self.pressed = true;
        self.serial += 1;
        if self.s.target[self.trial] {
            self.hits += 1;
            self.rt_sum_ms += self.t_ms;
            self.feedback = (self.serial, "hit", None);
            if self.hits >= GOAL_HITS {
                self.finish(true);
            }
        } else {
            self.false_alarms += 1;
            let kind = self.s.lure[self.trial];
            if let Some(k) = kind {
                self.lure_falls[LureKind::ALL.iter().position(|&x| x == k).unwrap()] += 1;
            }
            self.feedback = (self.serial, "false_alarm", kind);
            if self.errors() >= self.p.errors {
                self.finish(false);
            }
        }
        Ok(())
    }

    fn tick(&mut self, dt_ms: f64) {
        if !(dt_ms > 0.0) {
            return;
        }
        match self.phase {
            Phase::Countdown => {
                self.countdown_ms -= dt_ms;
                if self.countdown_ms <= 0.0 {
                    self.phase = Phase::Run;
                    self.t_ms = -self.countdown_ms;
                    self.elapsed_ms = self.t_ms;
                    self.countdown_ms = 0.0;
                }
            }
            Phase::Run => {
                self.t_ms += dt_ms;
                self.elapsed_ms += dt_ms;
                while self.phase == Phase::Run && self.t_ms >= self.p.period_ms {
                    self.t_ms -= self.p.period_ms;
                    self.end_trial();
                }
            }
            _ => {}
        }
    }
}

// =====================================================================================
// Endless mode: dual (position + digit) adaptive
// =====================================================================================

pub const MODS: [&str; 2] = ["position", "digit"];
/// Number of distinct values per modality (9 cells, digits 1–9).
const VALUES: [usize; 2] = [9, 9];
pub const P: usize = 0;
pub const D: usize = 1;

pub const SCORED: usize = 20;
pub const TARGETS: usize = 6; // 30% of 20
pub const ENDLESS_BLOCKS: usize = 10;
const DUAL_STIM_MS: f64 = 500.0;
const DUAL_PERIOD_MS: f64 = 3000.0;

/// One generated dual block: per modality a value sequence and its target / lure flags.
#[derive(Clone, Debug, PartialEq)]
pub struct Block {
    pub n: usize,
    pub len: usize,
    pub seq: [Vec<u16>; 2],
    pub target: [Vec<bool>; 2],
    pub lure: [Vec<bool>; 2],
}

/// `lure_rate`: share of the 20 scorable trials that are deliberate (N±1)-back lures (the
/// adaptive mode uses 0; kept for tests and future variants).
pub fn gen_block(r: &mut Rng, n: usize, lure_rate: f64) -> Block {
    let len = SCORED + n;
    let mut seq: [Vec<u16>; 2] = Default::default();
    let mut target: [Vec<bool>; 2] = Default::default();
    let mut lure: [Vec<bool>; 2] = Default::default();
    for m in [P, D] {
        let mut eligible: Vec<usize> = (n..len).collect();
        r.shuffle(&mut eligible);
        let mut t = vec![false; len];
        for &i in eligible.iter().take(TARGETS) {
            t[i] = true;
        }
        let lure_count = (lure_rate * SCORED as f64).round() as usize;
        let mut want = vec![false; len];
        for &i in eligible.iter().skip(TARGETS).take(lure_count) {
            want[i] = true;
        }
        let (s, l) = fill_sequence(r, n, &t, &want, VALUES[m]);
        seq[m] = s;
        target[m] = t;
        lure[m] = l;
    }
    Block { n, len, seq, target, lure }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Stats {
    pub hits: u32,
    pub misses: u32,
    pub false_alarms: u32,
    pub correct_rejections: u32,
}

impl Stats {
    /// Balanced accuracy; a half with no trials yet counts as perfect.
    pub fn accuracy(&self) -> f64 {
        let t = self.hits + self.misses;
        let nt = self.false_alarms + self.correct_rejections;
        let hr = if t == 0 { 1.0 } else { self.hits as f64 / t as f64 };
        let cr = if nt == 0 { 1.0 } else { self.correct_rejections as f64 / nt as f64 };
        (hr + cr) / 2.0
    }

    /// d′ with the log-linear correction (Hautus 1995).
    pub fn dprime(&self) -> f64 {
        let t = (self.hits + self.misses) as f64;
        let nt = (self.false_alarms + self.correct_rejections) as f64;
        let h = (self.hits as f64 + 0.5) / (t + 1.0);
        let f = (self.false_alarms as f64 + 0.5) / (nt + 1.0);
        inv_norm(h) - inv_norm(f)
    }
}

/// Inverse standard normal CDF (Acklam's rational approximation, |error| < 1.2e-9).
fn inv_norm(p: f64) -> f64 {
    const A: [f64; 6] = [-3.969683028665376e1, 2.209460984245205e2, -2.759285104469687e2, 1.383577518672690e2,
        -3.066479806614716e1, 2.506628277459239];
    const B: [f64; 5] = [-5.447609879822406e1, 1.615858368580409e2, -1.556989798598866e2, 6.680131188771972e1,
        -1.328068155288572e1];
    const C_: [f64; 6] = [-7.784894002430293e-3, -3.223964580411365e-1, -2.400758277161838, -2.549732539343734,
        4.374664141464968, 2.938163982698783];
    const D_: [f64; 4] = [7.784695709041462e-3, 3.224671290700398e-1, 2.445134137142996, 3.754408661907416];
    let p = p.clamp(1e-12, 1.0 - 1e-12);
    let pl = 0.02425;
    if p < pl {
        let q = (-2.0 * p.ln()).sqrt();
        (((((C_[0] * q + C_[1]) * q + C_[2]) * q + C_[3]) * q + C_[4]) * q + C_[5])
            / ((((D_[0] * q + D_[1]) * q + D_[2]) * q + D_[3]) * q + 1.0)
    } else if p <= 1.0 - pl {
        let q = p - 0.5;
        let r = q * q;
        (((((A[0] * r + A[1]) * r + A[2]) * r + A[3]) * r + A[4]) * r + A[5]) * q
            / (((((B[0] * r + B[1]) * r + B[2]) * r + B[3]) * r + B[4]) * r + 1.0)
    } else {
        -inv_norm(1.0 - p)
    }
}

#[derive(Clone, Debug)]
struct LastBlock {
    n: usize,
    accuracy: f64,
    change: i32,
}

pub struct Dual {
    n: usize,
    rng: Rng,
    block: Block,
    phase: Phase,
    countdown_ms: f64,
    trial: usize,
    t_ms: f64,
    pressed: [bool; 2],
    stats: [Stats; 2],
    feedback: [(u32, &'static str); 2],
    serial: u32,
    block_idx: usize,
    n_history: Vec<usize>,
    acc_history: Vec<f64>,
    last_block: Option<LastBlock>,
}

impl Dual {
    pub fn endless(seed: u64) -> Self {
        let mut rng = Rng::new(seed);
        let n = 2;
        let block = gen_block(&mut rng, n, 0.0);
        Dual {
            n,
            rng,
            block,
            phase: Phase::Intro,
            countdown_ms: COUNTDOWN_MS,
            trial: 0,
            t_ms: 0.0,
            pressed: [false; 2],
            stats: [Stats::default(); 2],
            feedback: [(0, ""); 2],
            serial: 0,
            block_idx: 0,
            n_history: vec![],
            acc_history: vec![],
            last_block: None,
        }
    }

    fn accuracy(&self) -> f64 {
        (self.stats[P].accuracy() + self.stats[D].accuracy()) / 2.0
    }

    fn end_trial(&mut self) {
        let i = self.trial;
        if i >= self.block.n {
            for m in [P, D] {
                let target = self.block.target[m][i];
                let s = &mut self.stats[m];
                match (target, self.pressed[m]) {
                    (true, true) => s.hits += 1,
                    (true, false) => {
                        s.misses += 1;
                        self.serial += 1;
                        self.feedback[m] = (self.serial, "miss");
                    }
                    (false, true) => s.false_alarms += 1,
                    (false, false) => s.correct_rejections += 1,
                }
            }
        }
        self.pressed = [false; 2];
        self.trial += 1;
        if self.trial >= self.block.len {
            self.end_block();
        }
    }

    fn end_block(&mut self) {
        let acc = self.accuracy();
        let n = self.n;
        self.n_history.push(n);
        self.acc_history.push(acc);
        let change = if acc >= 0.9 - 1e-9 {
            1
        } else if acc < 0.75 && n > 1 {
            -1
        } else {
            0
        };
        self.last_block = Some(LastBlock { n, accuracy: acc, change });
        self.block_idx += 1;
        if self.block_idx >= ENDLESS_BLOCKS {
            self.phase = Phase::Done;
            return;
        }
        self.n = (n as i32 + change).max(1) as usize;
        self.block = gen_block(&mut self.rng, self.n, 0.0);
        self.phase = Phase::Break;
    }

    fn start_block(&mut self) {
        self.phase = Phase::Countdown;
        self.countdown_ms = COUNTDOWN_MS;
        self.trial = 0;
        self.t_ms = 0.0;
        self.pressed = [false; 2];
        self.stats = [Stats::default(); 2];
    }

    fn score(&self) -> u32 {
        if self.n_history.is_empty() {
            return 0;
        }
        let mean = self.n_history.iter().sum::<usize>() as f64 / self.n_history.len() as f64;
        (mean * 100.0).round() as u32
    }

    fn summary(&self) -> String {
        let hist = self.n_history.iter().map(|n| n.to_string()).collect::<Vec<_>>().join(" → ");
        let mean = self.score() as f64 / 100.0;
        let acc = self.acc_history.iter().sum::<f64>() / self.acc_history.len().max(1) as f64;
        format!("N: {hist} · ortalama N {} · doğruluk %{}", fmt1(mean), (acc * 100.0).round())
    }
}

impl Session for Dual {
    fn state(&self) -> Value {
        let n = self.n;
        let running = self.phase == Phase::Run;
        let visible = running && self.t_ms < DUAL_STIM_MS && self.trial < self.block.len;
        let stim = visible.then(|| {
            let i = self.trial;
            json!({"pos": self.block.seq[P][i] as usize, "digit": self.block.seq[D][i] + 1})
        });
        let mut pressed = Map::new();
        let mut feedback = Map::new();
        let mut stats = Map::new();
        for m in [P, D] {
            pressed.insert(MODS[m].into(), json!(self.pressed[m]));
            feedback.insert(MODS[m].into(), json!({"serial": self.feedback[m].0, "result": self.feedback[m].1}));
            let s = self.stats[m];
            stats.insert(
                MODS[m].into(),
                json!({
                    "hits": s.hits, "misses": s.misses, "false_alarms": s.false_alarms,
                    "correct_rejections": s.correct_rejections,
                    "accuracy": (s.accuracy() * 1000.0).round() / 1000.0,
                    "dprime": (s.dprime() * 100.0).round() / 100.0,
                }),
            );
        }
        let done = self.phase == Phase::Done;
        json!({
            "status": if done { "lost" } else { "playing" },
            "stars": 0,
            "mode": "endless",
            "phase": self.phase.name(),
            "title": format!("İkili · {n}-back"),
            "goal": "10 blok · %90 ve üstü N'i artırır, %75 altı azaltır",
            "summary": done.then(|| self.summary()),
            "score": self.score(),
            "n": n,
            "modalities": MODS,
            "trial": self.trial.min(self.block.len),
            "trials": self.block.len,
            "period_ms": DUAL_PERIOD_MS,
            "stim_ms": DUAL_STIM_MS,
            "t_ms": self.t_ms.round(),
            "countdown_ms": self.countdown_ms.max(0.0).round(),
            "stim": stim,
            "pressed": pressed,
            "feedback": feedback,
            "stats": stats,
            "accuracy": (self.accuracy() * 1000.0).round() / 1000.0,
            "lures": false,
            "block": (self.block_idx + 1).min(ENDLESS_BLOCKS),
            "blocks": ENDLESS_BLOCKS,
            "n_history": self.n_history,
            "last_block": self.last_block.as_ref().map(|b| json!({
                "n": b.n, "accuracy": (b.accuracy * 1000.0).round() / 1000.0, "change": b.change,
            })),
        })
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if self.phase == Phase::Done {
            return Err("Bitti".into());
        }
        if a["start"].as_bool() == Some(true) {
            return match self.phase {
                Phase::Intro | Phase::Break => {
                    self.start_block();
                    Ok(())
                }
                _ => Err("Blok zaten sürüyor".into()),
            };
        }
        let Some(name) = a["match"].as_str() else {
            return Err("Bilinmeyen hamle".into());
        };
        let m = MODS.iter().position(|&x| x == name).ok_or("Bilinmeyen kanal")?;
        if self.phase != Phase::Run {
            return Err("Blok henüz başlamadı".into());
        }
        if self.trial < self.block.n || self.pressed[m] {
            // First N trials cannot match (tap ignored); a second tap on a trial is a no-op.
            return Ok(());
        }
        self.pressed[m] = true;
        self.serial += 1;
        let hit = self.block.target[m][self.trial];
        self.feedback[m] = (self.serial, if hit { "hit" } else { "false_alarm" });
        Ok(())
    }

    fn tick(&mut self, dt_ms: f64) {
        if !(dt_ms > 0.0) {
            return;
        }
        match self.phase {
            Phase::Countdown => {
                self.countdown_ms -= dt_ms;
                if self.countdown_ms <= 0.0 {
                    self.phase = Phase::Run;
                    self.t_ms = -self.countdown_ms;
                    self.countdown_ms = 0.0;
                }
            }
            Phase::Run => {
                self.t_ms += dt_ms;
                while self.phase == Phase::Run && self.t_ms >= DUAL_PERIOD_MS {
                    self.t_ms -= DUAL_PERIOD_MS;
                    self.end_trial();
                }
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LEVELS: [u32; 9] = [1, 2, 3, 50, 137, 250, 400, 499, 500];

    /// Is slot `i` an (N±1)-back repeat that is not an N-back match?
    fn is_near(s: &[u16], n: usize, i: usize) -> bool {
        (n >= 2 && i + 1 >= n && s[i] == s[i + 1 - n]) || (i > n && s[i] == s[i - n - 1])
    }

    fn check_stream(st: &Stream, p: &LevelParams) {
        assert_eq!(st.n, p.n);
        assert_eq!(st.len, p.n + SCORED_LEVEL);
        let s = &st.seq;
        let n = st.n;
        assert!(s.iter().all(|&v| (v as usize) < p.set.values()));
        // Small alphabet: at most the level's number of distinct items.
        let mut distinct: Vec<u16> = s.clone();
        distinct.sort();
        distinct.dedup();
        assert!(distinct.len() <= p.alphabet, "alphabet {} > {}", distinct.len(), p.alphabet);
        for i in 0..st.len {
            // No accidental matches anywhere: a slot repeats the N-back item iff it is a planned match.
            let is_match = i >= n && s[i] == s[i - n];
            assert_eq!(is_match, st.target[i], "target flag mismatch at {i}");
            assert_eq!(st.lure[i], lure_kind(s, n, i), "lure flag mismatch at {i}");
            if let Some(k) = st.lure[i] {
                // A lure is never a match at distance N, and really is what its kind says.
                assert!(!st.target[i] && s[i] != s[i - n], "lure at {i} is a match");
                match k {
                    LureKind::Minus => assert!(n >= 2 && s[i] == s[i + 1 - n]),
                    LureKind::Plus => assert!(s[i] == s[i - n - 1]),
                    LureKind::Seq => {
                        let j = (0..i - 2).rev().find(|&j| s[j] == s[i - 1] && s[j + 1] == s[i]).unwrap();
                        assert!(i - 1 - j <= seq_window(n), "seq lure at {i} too far back");
                    }
                }
            }
        }
        // No long runs of the same item.
        assert!(s.windows(3).all(|w| !(w[0] == w[1] && w[1] == w[2])), "run of three: {s:?}");
        // 3 matches in every window of 11 scorable trials (27%), none in the first N.
        assert!(st.target[..n].iter().all(|&t| !t));
        for w in 0..SCORED_LEVEL / WINDOW {
            let a = n + w * WINDOW;
            assert_eq!(st.target[a..a + WINDOW].iter().filter(|&&t| t).count(), TARGETS_PER_WINDOW);
        }
        assert_eq!(st.target.iter().filter(|&&t| t).count(), TARGETS_LEVEL);
        // Lure share of the non-match trials stays near the plan (20–30%).
        let share = st.lure_count() as f64 / NONTARGETS_LEVEL as f64;
        let planned = p.lure_count as f64 / NONTARGETS_LEVEL as f64;
        assert!(share >= planned - 0.08 && share <= planned + 0.10, "lure share {share:.2} vs plan {planned:.2} (n {n})");
    }

    #[test]
    fn level_params_curve() {
        for level in LEVELS {
            let p = level_params(level);
            assert!((1..=9).contains(&p.n), "level {level}");
            assert!(p.period_ms >= 1800.0 && p.period_ms <= 2500.0);
            assert!(p.stim_ms >= 400.0 && p.stim_ms <= 500.0);
            assert!(p.errors == 3 || p.errors == 5);
        }
        let p1 = level_params(1);
        assert_eq!((p1.n, p1.set, p1.errors, p1.alphabet), (1, StimSet::Digits, 5, 9));
        assert_eq!((p1.period_ms, p1.stim_ms), (2500.0, 500.0));
        assert_eq!(level_params(2).n, 2);
        assert_eq!(level_params(3).n, 2);
        assert_eq!(level_params(50).n, 4);
        assert_eq!(level_params(50).errors, 3);
        assert_eq!(level_params(137).n, 6);
        assert_eq!(level_params(250).n, 7);
        assert_eq!(level_params(400).n, 9);
        let p500 = level_params(500);
        assert_eq!((p500.n, p500.errors, p500.period_ms, p500.stim_ms, p500.alphabet), (9, 3, 1800.0, 400.0, 6));
        // N never decreases; tier intros give back the extra errors and use digits.
        let mut prev = 1;
        for level in 1..=500 {
            let p = level_params(level);
            assert!(p.n >= prev && p.n <= prev + 1, "level {level}");
            if p.n > prev {
                assert_eq!((p.set, p.errors), (StimSet::Digits, 5), "tier intro {level}");
            }
            prev = p.n;
        }
        // All three stimulus sets appear; letters before two-digit numbers.
        let first = |set| (1..=500).find(|&l| level_params(l).set == set).unwrap();
        assert!(first(StimSet::Letters) < first(StimSet::Numbers));
        assert!(first(StimSet::Numbers) <= 25);
        // The alphabet shrinks as N grows.
        assert!((1..500).all(|l| level_params(l).alphabet >= level_params(l + 1).alphabet));
    }

    #[test]
    fn lure_ratio_rises_with_level() {
        // Planned share: 20% of the non-match trials at the start, 30% at level 500.
        let share = |l: u32| level_params(l).lure_count as f64 / NONTARGETS_LEVEL as f64;
        assert!((share(1) - 0.20).abs() < 0.02);
        assert!((share(500) - 0.30).abs() < 0.02);
        for l in 1..=500 {
            assert!((0.18..=0.32).contains(&share(l)), "level {l}");
        }
        // Measured over the generated streams: every level has lures, and the mean share rises.
        let mean = |levels: std::ops::RangeInclusive<u32>| {
            let v: Vec<f64> = levels.map(|l| Single::level(l).s.lure_count() as f64 / NONTARGETS_LEVEL as f64).collect();
            v.iter().sum::<f64>() / v.len() as f64
        };
        let (lo, hi) = (mean(1..=50), mean(451..=500));
        assert!((0.17..=0.30).contains(&lo), "low levels {lo:.3}");
        assert!((0.25..=0.38).contains(&hi), "high levels {hi:.3}");
        assert!(hi > lo + 0.04, "{lo:.3} → {hi:.3}");
        for l in [1, 2, 15, 137, 500] {
            assert!(Single::level(l).s.lure_count() >= 8, "level {l}");
        }
    }

    #[test]
    fn every_lure_kind_is_used() {
        for level in [2, 15, 40, 137, 290, 500] {
            let g = Single::level(level);
            for k in LureKind::ALL {
                let c = g.s.lure.iter().filter(|&&l| l == Some(k)).count();
                assert!(c >= 2, "level {level}: only {c} {k:?} lures");
            }
        }
        // 1-back has no N−1 lures, but N+1 and sequence lures.
        let g = Single::level(1);
        assert!(g.s.lure.iter().all(|&l| l != Some(LureKind::Minus)));
        for k in [LureKind::Plus, LureKind::Seq] {
            assert!(g.s.lure.iter().filter(|&&l| l == Some(k)).count() >= 3, "{k:?}");
        }
    }

    #[test]
    fn lure_classification_examples() {
        // 3-back: 5 8 3 8 → the 4th item repeats 2 back (N−1); 5 8 3 1 5 → N+1.
        assert_eq!(lure_kind(&[5, 8, 3, 8], 3, 3), Some(LureKind::Minus));
        assert_eq!(lure_kind(&[5, 8, 3, 1, 5], 3, 4), Some(LureKind::Plus));
        // 2-back: 4 7 1 2 4 7 → 7 followed 4 before (sequence lure), but 2 back is 2.
        assert_eq!(lure_kind(&[4, 7, 1, 2, 4, 7], 2, 5), Some(LureKind::Seq));
        // A real match is never a lure.
        assert_eq!(lure_kind(&[4, 7, 4], 2, 2), None);
        assert_eq!(lure_kind(&[4, 7, 1], 2, 2), None);
    }

    #[test]
    fn levels_generate_valid_streams() {
        for level in 1..=500 {
            let g = Single::level(level);
            check_stream(&g.s, &g.p);
            if LEVELS.contains(&level) || level <= 30 {
                let st = g.state();
                assert_eq!(st["status"], "playing");
                assert_eq!(st["phase"], "intro");
                assert_eq!(st["title"], format!("{}-Back", g.p.n));
                assert_eq!(st["goal"], format!("17 eşleşme yakala · {} hata hakkı", g.p.errors));
            }
        }
        let mut r = Rng::new(9);
        for n in 1..=9 {
            for set in [StimSet::Digits, StimSet::Letters, StimSet::Numbers] {
                for lure_count in [13, 16, 19] {
                    let p = LevelParams {
                        n, set, stim_ms: 500.0, period_ms: 2500.0, alphabet: alphabet_for(n), lure_count, errors: 3,
                    };
                    for _ in 0..10 {
                        check_stream(&gen_stream(&mut r, &p), &p);
                    }
                }
            }
        }
    }

    #[test]
    fn deterministic() {
        for level in LEVELS {
            assert_eq!(Single::level(level).s, Single::level(level).s);
            assert_eq!(level_params(level), level_params(level));
        }
        assert_ne!(Single::level(2).s, Single::level(3).s);
        let p = level_params(200);
        assert_eq!(gen_stream(&mut Rng::new(77), &p), gen_stream(&mut Rng::new(77), &p));
    }

    #[test]
    #[ignore]
    fn lure_stats() {
        for n in 1..=9 {
            let levels: Vec<u32> = (1..=500).filter(|&l| level_params(l).n == n).collect();
            let shares: Vec<f64> =
                levels.iter().map(|&l| Single::level(l).s.lure_count() as f64 / NONTARGETS_LEVEL as f64).collect();
            let plan: f64 =
                levels.iter().map(|&l| level_params(l).lure_count as f64 / NONTARGETS_LEVEL as f64).sum::<f64>() / levels.len() as f64;
            let mut kinds = [0usize; 3];
            for &l in &levels {
                for k in Single::level(l).s.lure.iter().flatten() {
                    kinds[LureKind::ALL.iter().position(|x| x == k).unwrap()] += 1;
                }
            }
            println!(
                "N{n}: plan {:.3} · measured mean {:.3} min {:.3} max {:.3} · kinds {:?}",
                plan,
                shares.iter().sum::<f64>() / shares.len() as f64,
                shares.iter().cloned().fold(1.0, f64::min),
                shares.iter().cloned().fold(0.0, f64::max),
                kinds
            );
        }
    }

    #[test]
    fn stimulus_strings() {
        assert_eq!(StimSet::Digits.show(0), "1");
        assert_eq!(StimSet::Digits.show(8), "9");
        assert_eq!(StimSet::Numbers.show(0), "10");
        assert_eq!(StimSet::Numbers.show(89), "99");
        assert_eq!(StimSet::Letters.show(0), "B");
    }

    fn start(g: &mut Single) {
        g.act(&json!({"start": true})).unwrap();
        g.tick(COUNTDOWN_MS);
        assert_eq!(g.phase, Phase::Run);
    }

    /// Play the current trial: tap when `tap(trial, is_target)` says so, then let the trial end.
    fn play(g: &mut Single, mut tap: impl FnMut(usize, bool) -> bool) {
        while g.phase == Phase::Run {
            let i = g.trial;
            if tap(i, g.s.target[i]) {
                g.act(&json!({"match": true})).unwrap();
            }
            if g.phase != Phase::Run {
                break;
            }
            g.tick(g.p.stim_ms + 1.0);
            assert!(g.state()["stim"].is_null());
            g.tick(g.p.period_ms - g.p.stim_ms - 1.0);
        }
    }

    #[test]
    fn perfect_play_wins_three_stars_after_seventeen_hits() {
        for level in LEVELS {
            let mut g = Single::level(level);
            start(&mut g);
            play(&mut g, |_, t| t);
            let st = g.state();
            assert_eq!(st["status"], "won", "level {level}");
            assert_eq!(st["stars"], 3);
            assert_eq!(st["hits"], 17);
            assert_eq!(st["errors"], 0);
            assert_eq!(st["efficiency"], 1.0);
            assert!(st["lure_summary"].is_null());
            // The 17th match sits in the 6th window of 11: a clean run lasts N + 56..66 trials.
            let trials = g.trial + 1;
            assert!(trials > g.p.n + 55 && trials <= g.p.n + 66, "level {level}: {trials}");
            assert!(st["summary"].as_str().unwrap().starts_with("Doğru 17 · Yanlış 0 · Kaçırılan 0 · Verimlilik %100"));
            assert!(!st["summary"].as_str().unwrap().contains("çeldirici"));
            assert!(g.act(&json!({"match": true})).is_err());
        }
    }

    #[test]
    fn stars_follow_errors() {
        // Level 50: budget 3. One false alarm → 2 stars, two → 1 star.
        for (fas, stars) in [(1, 2), (2, 1)] {
            let mut g = Single::level(50);
            assert_eq!(g.p.errors, 3);
            start(&mut g);
            let mut left = fas;
            play(&mut g, |i, t| {
                if !t && i >= g_n(50) && left > 0 {
                    left -= 1;
                    return true;
                }
                t
            });
            assert_eq!(g.state()["status"], "won");
            assert_eq!(g.state()["stars"], stars);
            assert_eq!(g.state()["errors_left"], 3 - fas);
        }
        // Level 1: budget 5. One miss and one false alarm → still won, 1 star.
        let mut g = Single::level(1);
        assert_eq!(g.p.errors, 5);
        start(&mut g);
        let (mut missed, mut fa) = (false, false);
        play(&mut g, |i, t| {
            if t && !missed {
                missed = true;
                return false;
            }
            if !t && i >= 1 && !fa {
                fa = true;
                return true;
            }
            t
        });
        let st = g.state();
        assert_eq!((st["status"].as_str(), st["stars"].as_u64(), st["misses"].as_u64()), (Some("won"), Some(1), Some(1)));
    }

    fn g_n(level: u32) -> usize {
        level_params(level).n
    }

    #[test]
    fn loses_when_error_budget_is_spent() {
        // Never tapping: each match becomes a miss; the 3rd miss ends a budget-3 level.
        let mut g = Single::level(50);
        start(&mut g);
        play(&mut g, |_, _| false);
        let st = g.state();
        assert_eq!(st["status"], "lost");
        assert_eq!(st["misses"], 3);
        assert_eq!(st["errors_left"], 0);
        assert_eq!(st["stars"], 0);
        assert_eq!(st["feedback"]["result"], "miss");
        assert!(st["feedback"]["lure_kind"].is_null());
        assert!(st["summary"].as_str().unwrap().starts_with("Doğru 0/17 · Yanlış 0 · Kaçırılan 3"));
        // Tapping everything: false alarms end it quickly (budget 5 at level 1).
        let mut g = Single::level(1);
        start(&mut g);
        play(&mut g, |_, _| true);
        let st = g.state();
        assert_eq!(st["status"], "lost");
        assert_eq!(st["false_alarms"], 5);
        assert!(g.trial < 30);
        assert!(g.act(&json!({"start": true})).is_err());
    }

    #[test]
    fn false_alarms_on_lures_are_reported() {
        // Level 137 (6-back): tap the first three lures, play the rest perfectly.
        let level = 137;
        let mut g = Single::level(level);
        start(&mut g);
        let lure = g.s.lure.clone();
        let mut taken: Vec<LureKind> = vec![];
        let mut seen_feedback = vec![];
        while g.phase == Phase::Run {
            let i = g.trial;
            let tap = g.s.target[i] || (lure[i].is_some() && taken.len() < 2);
            if tap {
                if let Some(k) = lure[i] {
                    taken.push(k);
                }
                g.act(&json!({"match": true})).unwrap();
                if let Some(k) = lure[i] {
                    let st = g.state();
                    assert_eq!(st["feedback"]["result"], "false_alarm");
                    assert_eq!(st["feedback"]["lure_kind"], k.id());
                    seen_feedback.push(k);
                }
            }
            if g.phase != Phase::Run {
                break;
            }
            g.tick(g.p.period_ms);
        }
        assert_eq!(seen_feedback, taken);
        let st = g.state();
        assert_eq!(st["status"], "won");
        assert_eq!(st["false_alarms"], 2);
        let total: u64 = ["n-1", "n+1", "seq"].iter().map(|k| st["lure_falls"][*k].as_u64().unwrap()).sum();
        assert_eq!(total, 2);
        let line = st["lure_summary"].as_str().unwrap().to_string();
        assert!(line.starts_with("2 çeldiriciye takıldın ("), "{line}");
        assert!(st["summary"].as_str().unwrap().ends_with(&line));
        // A plain (non-lure) false alarm carries no lure kind.
        let mut g = Single::level(level);
        start(&mut g);
        while g.phase == Phase::Run {
            let i = g.trial;
            if i >= g.p.n && !g.s.target[i] && g.s.lure[i].is_none() {
                g.act(&json!({"match": true})).unwrap();
                assert_eq!(g.state()["feedback"]["result"], "false_alarm");
                assert!(g.state()["feedback"]["lure_kind"].is_null());
                assert!(g.state()["lure_summary"].is_null());
                break;
            }
            g.tick(g.p.period_ms);
        }
    }

    #[test]
    fn lure_line_formats() {
        let mut g = Single::level(10);
        assert_eq!(g.lure_line(), None);
        g.lure_falls = [3, 0, 0];
        assert_eq!(g.lure_line().unwrap(), "3 çeldiriciye takıldın (n−1)");
        g.lure_falls = [2, 0, 1];
        assert_eq!(g.lure_line().unwrap(), "3 çeldiriciye takıldın (2 n−1, 1 sıra)");
    }

    #[test]
    fn early_taps_ignored_and_illegal_actions_rejected() {
        let mut g = Single::level(400); // N = 9
        let before = g.state();
        assert!(g.act(&json!({"match": true})).is_err()); // not started
        assert!(g.act(&json!({"match": false})).is_err());
        assert!(g.act(&json!({"foo": 1})).is_err());
        assert_eq!(g.state(), before);
        g.act(&json!({"start": true})).unwrap();
        assert!(g.act(&json!({"start": true})).is_err());
        assert!(g.act(&json!({"match": true})).is_err()); // countdown
        g.tick(COUNTDOWN_MS);
        for _ in 0..g.p.n {
            assert_eq!(g.state()["can_match"], false);
            let before = g.state();
            for _ in 0..3 {
                g.act(&json!({"match": true})).unwrap();
            }
            assert_eq!(g.state(), before, "early tap must not change state");
            g.tick(g.p.period_ms);
        }
        assert_eq!(g.trial, g.p.n);
        assert_eq!(g.state()["can_match"], true);
        assert_eq!(g.errors(), 0);
        // A double tap on one trial counts once.
        g.act(&json!({"match": true})).unwrap();
        let after_one = g.state();
        g.act(&json!({"match": true})).unwrap();
        assert_eq!(g.state(), after_one);
        assert_eq!(g.hits + g.false_alarms, 1);
    }

    #[test]
    fn timing_and_visibility() {
        let mut g = Single::level(1);
        g.act(&json!({"start": true})).unwrap();
        assert!(g.state()["stim"].is_null());
        g.tick(COUNTDOWN_MS - 1.0);
        assert_eq!(g.state()["phase"], "countdown");
        g.tick(1.0);
        let st = g.state();
        assert_eq!(st["stim"], g.p.set.show(g.s.seq[0]));
        g.tick(g.p.stim_ms);
        assert!(g.state()["stim"].is_null());
        assert_eq!(g.state()["trial"], 0);
        g.tick(g.p.period_ms - g.p.stim_ms);
        assert_eq!(g.state()["trial"], 1);
        assert!(g.state()["elapsed_ms"].as_f64().unwrap() >= g.p.period_ms - 1.0);
        // A huge dt never skips past the decision: trials still end one by one.
        let mut g = Single::level(50);
        start(&mut g);
        g.tick(1e7);
        assert_eq!(g.state()["status"], "lost");
    }

    #[test]
    fn helper_strip_shows_recent_and_caps_stars() {
        let mut g = Single::level(3); // N = 2
        assert!(g.state()["recent"].as_array().unwrap().is_empty());
        start(&mut g);
        g.tick(g.p.period_ms * 3.0); // now at trial 3
        assert!(g.state()["recent"].as_array().unwrap().is_empty()); // off by default
        g.act(&json!({"helper": true})).unwrap();
        let st = g.state();
        let recent: Vec<String> = st["recent"].as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_string()).collect();
        assert_eq!(recent, vec![g.p.set.show(g.s.seq[1]), g.p.set.show(g.s.seq[2])]);
        g.act(&json!({"helper": false})).unwrap();
        play(&mut g, |_, t| t);
        let st = g.state();
        assert_eq!(st["status"], "won");
        assert_eq!(st["stars"], 1);
    }

    // ------------------------------------------------------------------ endless dual

    fn check_block(b: &Block, lure_rate: f64) {
        assert_eq!(b.len, SCORED + b.n);
        for m in [P, D] {
            let s = &b.seq[m];
            assert_eq!(s.len(), b.len);
            assert!(s.iter().all(|&v| (v as usize) < VALUES[m]));
            let mut targets = 0;
            let mut lures = 0;
            for i in 0..b.len {
                let is_match = i >= b.n && s[i] == s[i - b.n];
                assert_eq!(is_match, b.target[m][i], "target flag mismatch at {i}");
                if is_match {
                    targets += 1;
                    continue;
                }
                let near = is_near(s, b.n, i);
                assert_eq!(near, b.lure[m][i], "unplanned lure at {i}");
                lures += near as usize;
            }
            assert_eq!(targets, TARGETS);
            if lure_rate == 0.0 {
                assert_eq!(lures, 0);
            } else {
                assert!(lures > 0);
            }
        }
    }

    #[test]
    fn dual_blocks_respect_target_and_lure_rules() {
        let mut r = Rng::new(5);
        for n in 1..=8 {
            for lure in [0.0, 0.15] {
                for _ in 0..50 {
                    check_block(&gen_block(&mut r, n, lure), lure);
                }
            }
        }
        let g = Dual::endless(3);
        check_block(&g.block, 0.0);
        assert_eq!(g.state()["mode"], "endless");
        assert_eq!(g.state()["n"], 2);
    }

    /// Play one dual block: press exactly the targets (or nothing / everything).
    fn play_block(g: &mut Dual, strategy: &str) {
        g.act(&json!({"start": true})).unwrap();
        g.tick(COUNTDOWN_MS);
        assert_eq!(g.phase, Phase::Run);
        while g.phase == Phase::Run {
            for m in [P, D] {
                let press = match strategy {
                    "perfect" => g.block.target[m][g.trial],
                    "all" => true,
                    _ => false,
                };
                if press {
                    g.act(&json!({"match": MODS[m]})).unwrap();
                }
            }
            g.tick(DUAL_PERIOD_MS / 2.0);
            g.tick(DUAL_PERIOD_MS / 2.0);
        }
    }

    #[test]
    fn dual_balanced_accuracy() {
        let mut g = Dual::endless(7);
        play_block(&mut g, "perfect");
        assert_eq!(g.last_block.as_ref().unwrap().accuracy, 1.0);
        for strategy in ["none", "all"] {
            let mut g = Dual::endless(8);
            play_block(&mut g, strategy);
            assert!((g.last_block.as_ref().unwrap().accuracy - 0.5).abs() < 1e-9, "{strategy}");
        }
    }

    #[test]
    fn dual_illegal_actions_rejected_and_state_unchanged() {
        let mut g = Dual::endless(11);
        let before = g.state();
        assert!(g.act(&json!({"match": "position"})).is_err()); // not started
        assert!(g.act(&json!({"match": "color"})).is_err());
        assert!(g.act(&json!({"match": "smell"})).is_err());
        assert!(g.act(&json!({"foo": 1})).is_err());
        assert_eq!(g.state(), before);
        g.act(&json!({"start": true})).unwrap();
        assert!(g.act(&json!({"start": true})).is_err());
        g.tick(COUNTDOWN_MS);
        let before = g.state();
        g.act(&json!({"match": "position"})).unwrap(); // trial 0 < N: ignored
        assert_eq!(g.state(), before);
    }

    #[test]
    fn dual_stimulus_visibility_and_timing() {
        let mut g = Dual::endless(1);
        g.act(&json!({"start": true})).unwrap();
        assert!(g.state()["stim"].is_null());
        g.tick(COUNTDOWN_MS);
        let st = g.state();
        assert!(st["stim"]["pos"].as_u64().unwrap() < 9);
        assert!((1..=9).contains(&st["stim"]["digit"].as_u64().unwrap()));
        g.tick(DUAL_STIM_MS + 1.0);
        assert!(g.state()["stim"].is_null());
        assert_eq!(g.state()["trial"], 0);
        g.tick(DUAL_PERIOD_MS);
        assert_eq!(g.state()["trial"], 1);
    }

    #[test]
    fn endless_adapts_and_ends() {
        let mut g = Dual::endless(42);
        for b in 0..ENDLESS_BLOCKS {
            assert_eq!(g.n, 2 + b);
            play_block(&mut g, "perfect");
        }
        let st = g.state();
        assert_eq!(st["status"], "lost");
        assert_eq!(g.n_history, (2..12).collect::<Vec<_>>());
        assert_eq!(st["score"], 650);
        assert!(st["summary"].as_str().unwrap().contains("2 → 3"));
        // Poor play lowers N.
        let mut g = Dual::endless(1);
        play_block(&mut g, "none");
        assert_eq!(g.n, 1);
        assert_eq!(g.phase, Phase::Break);
        assert_eq!(g.state()["last_block"]["change"], -1);
    }

    #[test]
    fn create_dispatches_by_mode() {
        assert_eq!(create(2, "level").unwrap().state()["mode"], "level");
        assert_eq!(create(2, "endless").unwrap().state()["mode"], "endless");
    }

    #[test]
    fn dprime_sanity() {
        let perfect = Stats { hits: 6, misses: 0, false_alarms: 0, correct_rejections: 14 };
        let chance = Stats { hits: 3, misses: 3, false_alarms: 7, correct_rejections: 7 };
        assert!(perfect.dprime() > 2.5);
        assert!(chance.dprime().abs() < 0.01);
        assert!((inv_norm(0.975) - 1.959964).abs() < 1e-5);
    }

    #[test]
    #[ignore]
    fn timing_500_levels() {
        let t = std::time::Instant::now();
        let mut worst = 0.0f64;
        for level in 1..=500 {
            let s = std::time::Instant::now();
            let g = Single::level(level);
            assert!(g.s.len > SCORED_LEVEL);
            worst = worst.max(s.elapsed().as_secs_f64());
        }
        println!("nback: 500 levels in {:?}, worst {:.3} ms", t.elapsed(), worst * 1000.0);
    }
}
