//! Eşleştirme — concentration / matching cards (pairs, and triplets on some levels).
//!
//! Face-down cards on a `cols × rows` grid. Flip cards one at a time: in pair levels a turn is two
//! cards, in triplet levels up to three (the turn ends as soon as a card doesn't match the first).
//! A completed group stays open; a mismatch stays visible for a short look and then flips back (the
//! view may end the look early with `close`). A third card can never be flipped while a mismatch is
//! showing, matched cards can't be flipped. Every finished turn — match or not — is one **move**.
//!
//! Faces are drawn by the app from `{shape (0..12), color (0..8), detail (0..3)}`. The level's
//! `confusable` setting picks the face set: 0 = as different as possible, 1 = shape twins (same
//! shape, different colour), 2 = a shape × colour product (every face shares its shape with some
//! faces and its colour with others), 3 = product with tiny detail variants (corner sparkles).
//!
//! **Par** (documented): the mean number of moves a *perfect-memory* player needs on this exact deal,
//! from 200 simulated games with random exploration order (strategy: play a fully known group if one
//! exists; otherwise flip an unknown card, then its known partners, then unknown cards). Preview and
//! shuffles are ignored (the perfect player tracks swaps), so on early levels the preview is a help.
//! Stars: moves ≤ ⌈par·1.15⌉ → 3, ≤ ⌈par·1.5⌉ → 2, otherwise 1. Levels with a move limit
//! (`limit = ⌈par·mult⌉`) are `lost` when the limit is used up before the board is cleared.
//!
//! Level curve (`params(level)`, t = (level−1)/499):
//! - board tier: L1–40 3×4, L41–120 4×4, L121–220 4×5, L221–350 5×6, L351–500 6×6 (cols×rows);
//!   every 3rd level uses the next tier with one step less confusable faces;
//! - triplets on every 7th level from L100 (3×4 / 3×5 / 3×6 / 4×6 / 5×6 by tier);
//! - preview 2000 ms at L1, −10 ms per level, none from L201;
//! - confusable faces: 0 below L40, 1 below L130, 2 below L300, 3 after;
//! - shuffles from L70 (every 4th level, from L300 every other level): every 6 → 3 moves,
//!   1 → 3 swaps of face-down cards, animated (`shuffle` phase, 900 ms);
//! - move limit from L90 on every 6th level, from L420 on every even level: mult 2.0 → 1.6;
//! - mismatch look 900 → 600 ms.
//!
//! Endless is not offered for this game; any mode plays the level.
//!
//! State: `{status, stars, phase: "intro"|"preview"|"play"|"look"|"shuffle"|"done", title, goal,
//!          summary, cols, rows, group, confusable, cards: [{id, face: {shape,color,detail}|null, up, matched}]
//!          (by position), moves, par, three_star, two_star, limit|null, found, groups, preview_ms,
//!          preview_total, look_ms, shuffle_every, moves_to_shuffle|null, swaps: [[a,b]],
//!          shuffle_serial, match_serial, last_match: [pos], miss_serial, last_miss: [pos],
//!          elapsed_ms}`
//! Actions: `{"start":true}` · `{"flip": pos}` · `{"close":true}` (end a mismatch look early)

use crate::rng::{seed_for, Rng};
use crate::Session;
use serde_json::{json, Value};

pub const SHAPES: u8 = 12;
pub const COLORS: u8 = 8;
pub const SHUFFLE_MS: f64 = 900.0;
const PAR_SIMS: usize = 200;
const PAIR_SIZES: [(usize, usize); 5] = [(3, 4), (4, 4), (4, 5), (5, 6), (6, 6)];
const TRIPLE_SIZES: [(usize, usize); 5] = [(3, 4), (3, 5), (3, 6), (4, 6), (5, 6)];

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Face {
    pub shape: u8,
    pub color: u8,
    pub detail: u8,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Params {
    pub cols: usize,
    pub rows: usize,
    pub group: usize,
    pub preview_ms: f64,
    pub confusable: u8,
    pub shuffle_every: u32,
    pub swaps: usize,
    pub limit_mult: Option<f64>,
    pub look_ms: f64,
}

/// Level → parameters (see the module docs for the curve).
pub fn params(level: u32) -> Params {
    let level = level.clamp(1, crate::MAX_LEVEL);
    let t = (level - 1) as f64 / 499.0;
    let base = match level {
        1..=40 => 0,
        41..=120 => 1,
        121..=220 => 2,
        221..=350 => 3,
        _ => 4,
    };
    let bump = level % 3 == 0 && base < 4;
    let tier = if bump { base + 1 } else { base };
    let triplets = level >= 100 && level % 7 == 0;
    let (cols, rows) = if triplets { TRIPLE_SIZES[tier] } else { PAIR_SIZES[tier] };
    let mut confusable: u8 = match level {
        1..=39 => 0,
        40..=129 => 1,
        130..=299 => 2,
        _ => 3,
    };
    if bump {
        confusable = confusable.saturating_sub(1);
    }
    let shuffles = level >= 70 && (level % 4 == 1 || (level >= 300 && level % 4 == 3));
    let limit = (level >= 90 && level % 6 == 3) || (level >= 420 && level % 2 == 0);
    Params {
        cols,
        rows,
        group: if triplets { 3 } else { 2 },
        preview_ms: (2000.0 - (level - 1) as f64 * 10.0).max(0.0),
        confusable,
        shuffle_every: if shuffles { (6.0 - 3.0 * t).round() as u32 } else { 0 },
        swaps: if shuffles { 1 + (2.999 * t) as usize } else { 0 },
        limit_mult: limit.then(|| 2.0 - 0.4 * t),
        look_ms: 900.0 - 300.0 * t,
    }
}

/// The level's face set: `n` distinct faces chosen by the confusability setting.
pub fn pick_faces(rng: &mut Rng, n: usize, confusable: u8) -> Vec<Face> {
    let mut shapes: Vec<u8> = (0..SHAPES).collect();
    let mut colors: Vec<u8> = (0..COLORS).collect();
    rng.shuffle(&mut shapes);
    rng.shuffle(&mut colors);
    let mut out: Vec<Face> = Vec::with_capacity(n);
    match confusable {
        0 => {
            for k in 0..n {
                let shape = shapes[k % SHAPES as usize];
                let color = colors[(k + 3 * (k / SHAPES as usize)) % COLORS as usize];
                out.push(Face { shape, color, detail: 0 });
            }
        }
        1 => {
            // Shape twins: each shape in two different colours.
            let mut k = 0;
            while out.len() < n {
                let shape = shapes[k % SHAPES as usize];
                let c0 = colors[(2 * k) % COLORS as usize];
                let c1 = colors[(2 * k + 1) % COLORS as usize];
                for c in [c0, c1] {
                    let f = Face { shape, color: c, detail: 0 };
                    if out.len() < n && !out.contains(&f) {
                        out.push(f);
                    }
                }
                k += 1;
            }
        }
        _ => {
            let details: usize = if confusable >= 3 { 2 } else { 1 };
            let per = n.div_ceil(details);
            let s = ((per as f64).sqrt().ceil() as usize).clamp(1, SHAPES as usize);
            let c = per.div_ceil(s).min(COLORS as usize);
            let mut all = vec![];
            for &sh in &shapes[..s] {
                for &co in &colors[..c] {
                    for d in 0..details {
                        all.push(Face { shape: sh, color: co, detail: d as u8 });
                    }
                }
            }
            rng.shuffle(&mut all);
            if details == 2 {
                // Keep detail twins together so the fine difference really matters.
                let mut base: Vec<(u8, u8)> = all.iter().map(|f| (f.shape, f.color)).collect();
                base.dedup();
                let mut seen = std::collections::HashSet::new();
                base.retain(|b| seen.insert(*b));
                for (sh, co) in base {
                    for d in 0..2 {
                        if out.len() < n {
                            out.push(Face { shape: sh, color: co, detail: d });
                        }
                    }
                }
            } else {
                out.extend(all.into_iter().take(n));
            }
        }
    }
    out
}

/// Mean moves of a perfect-memory player on `deal` (face index per position), over `sims` games.
pub fn perfect_par(deal: &[usize], group: usize, rng: &mut Rng, sims: usize) -> f64 {
    let n = deal.len();
    let faces = deal.iter().max().map(|m| m + 1).unwrap_or(0);
    let mut total = 0usize;
    for _ in 0..sims {
        let mut order: Vec<usize> = (0..n).collect();
        rng.shuffle(&mut order);
        let mut next = 0; // order[next..] are unknown
        let mut known: Vec<Vec<usize>> = vec![vec![]; faces]; // face → known unmatched positions
        let mut done = vec![false; faces];
        let mut left = faces;
        let mut moves = 0;
        while left > 0 {
            moves += 1;
            if let Some(f) = (0..faces).find(|&f| !done[f] && known[f].len() == group) {
                done[f] = true;
                left -= 1;
                continue;
            }
            let a = order[next];
            next += 1;
            let fa = deal[a];
            let mut count = 1 + known[fa].len();
            known[fa].push(a);
            let mut failed = false;
            while count < group {
                let b = order[next];
                next += 1;
                known[deal[b]].push(b);
                if deal[b] != fa {
                    failed = true;
                    break;
                }
                count += 1;
            }
            if !failed {
                done[fa] = true;
                left -= 1;
            }
        }
        total += moves;
    }
    total as f64 / sims as f64
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Phase {
    Intro,
    Preview,
    Play,
    Look,
    Shuffle,
    Done,
}

impl Phase {
    fn key(self) -> &'static str {
        match self {
            Phase::Intro => "intro",
            Phase::Preview => "preview",
            Phase::Play => "play",
            Phase::Look => "look",
            Phase::Shuffle => "shuffle",
            Phase::Done => "done",
        }
    }
}

pub struct Pairs {
    p: Params,
    rng: Rng,
    faces: Vec<Face>,
    /// Face index of each card id.
    card_face: Vec<usize>,
    /// Card id at each position.
    board: Vec<usize>,
    matched: Vec<bool>,
    /// Face-up, unmatched card ids of the current turn.
    open: Vec<usize>,
    phase: Phase,
    phase_ms: f64,
    preview_left: f64,
    moves: u32,
    par: f64,
    limit: Option<u32>,
    found: usize,
    moves_since_shuffle: u32,
    swaps: Vec<(usize, usize)>,
    shuffle_serial: u32,
    match_serial: u32,
    last_match: Vec<usize>,
    miss_serial: u32,
    last_miss: Vec<usize>,
    elapsed_ms: f64,
    won: bool,
}

pub fn create(level: u32, _mode: &str) -> Result<Box<dyn Session>, String> {
    Ok(Box::new(Pairs::level(level)))
}

impl Pairs {
    pub fn level(level: u32) -> Self {
        let p = params(level);
        let mut rng = Rng::new(seed_for("pairs", level, 0));
        let n = p.cols * p.rows;
        let groups = n / p.group;
        let faces = pick_faces(&mut rng, groups, p.confusable);
        let card_face: Vec<usize> = (0..n).map(|id| id / p.group).collect();
        let mut board: Vec<usize> = (0..n).collect();
        rng.shuffle(&mut board);
        let deal: Vec<usize> = board.iter().map(|&id| card_face[id]).collect();
        let mut sim = Rng::new(seed_for("pairs", level, 1));
        let par = perfect_par(&deal, p.group, &mut sim, PAR_SIMS);
        let limit = p.limit_mult.map(|m| (par * m).ceil() as u32);
        Pairs {
            preview_left: p.preview_ms,
            p,
            rng,
            faces,
            card_face,
            board,
            matched: vec![false; n],
            open: vec![],
            phase: Phase::Intro,
            phase_ms: 0.0,
            moves: 0,
            par,
            limit,
            found: 0,
            moves_since_shuffle: 0,
            swaps: vec![],
            shuffle_serial: 0,
            match_serial: 0,
            last_match: vec![],
            miss_serial: 0,
            last_miss: vec![],
            elapsed_ms: 0.0,
            won: false,
        }
    }

    fn groups(&self) -> usize {
        self.board.len() / self.p.group
    }

    pub fn par_moves(&self) -> u32 {
        self.par.round().max(self.groups() as f64) as u32
    }

    pub fn three_star(&self) -> u32 {
        (self.par * 1.15).ceil() as u32
    }

    pub fn two_star(&self) -> u32 {
        (self.par * 1.5).ceil() as u32
    }

    fn stars(&self) -> u32 {
        if !self.won {
            0
        } else if self.moves <= self.three_star() {
            3
        } else if self.moves <= self.two_star() {
            2
        } else {
            1
        }
    }

    fn pos_of(&self, id: usize) -> usize {
        self.board.iter().position(|&c| c == id).unwrap_or(0)
    }

    fn enter(&mut self, ph: Phase) {
        self.phase = ph;
        self.phase_ms = 0.0;
    }

    /// Bookkeeping after a finished turn: limit, shuffle, back to play.
    fn after_move(&mut self) {
        if self.found == self.groups() {
            self.won = true;
            self.enter(Phase::Done);
            return;
        }
        if let Some(l) = self.limit {
            if self.moves >= l {
                self.enter(Phase::Done);
                return;
            }
        }
        if self.p.shuffle_every > 0 {
            self.moves_since_shuffle += 1;
            if self.moves_since_shuffle >= self.p.shuffle_every && self.shuffle() {
                self.moves_since_shuffle = 0;
                self.enter(Phase::Shuffle);
                return;
            }
        }
        self.enter(Phase::Play);
    }

    /// Swap a few face-down cards (with different faces). Returns false if nothing could move.
    fn shuffle(&mut self) -> bool {
        let mut down: Vec<usize> = (0..self.board.len()).filter(|&p| !self.matched[self.board[p]]).collect();
        self.rng.shuffle(&mut down);
        let mut swaps = vec![];
        let mut used = vec![false; self.board.len()];
        for i in 0..down.len() {
            if swaps.len() >= self.p.swaps {
                break;
            }
            let a = down[i];
            if used[a] {
                continue;
            }
            let partner = down[i + 1..]
                .iter()
                .copied()
                .find(|&b| !used[b] && self.card_face[self.board[a]] != self.card_face[self.board[b]]);
            if let Some(b) = partner {
                used[a] = true;
                used[b] = true;
                self.board.swap(a, b);
                swaps.push((a, b));
            }
        }
        if swaps.is_empty() {
            return false;
        }
        self.swaps = swaps;
        self.shuffle_serial += 1;
        true
    }

    fn close_look(&mut self) {
        self.open.clear();
        self.after_move();
    }

    fn face_json(&self, id: usize) -> Value {
        let f = self.faces[self.card_face[id]];
        json!({"shape": f.shape, "color": f.color, "detail": f.detail})
    }

    fn status(&self) -> &'static str {
        match self.phase {
            Phase::Done if self.won => "won",
            Phase::Done => "lost",
            _ => "playing",
        }
    }

    fn time_str(&self) -> String {
        let s = (self.elapsed_ms / 1000.0).round() as u64;
        format!("{}:{:02}", s / 60, s % 60)
    }

    fn summary(&self) -> String {
        let unit = if self.p.group == 3 { "üçlü" } else { "çift" };
        if self.phase == Phase::Done && !self.won {
            return format!("Hamle sınırı doldu · Bulunan {}/{} {unit}", self.found, self.groups());
        }
        format!("Hamle {} · Kusursuz hafıza ≈ {} · Süre {}", self.moves, self.par_moves(), self.time_str())
    }

    fn title(&self) -> String {
        let mut t = format!("{}×{}", self.p.cols, self.p.rows);
        if self.p.group == 3 {
            t.push_str(" · üçlü");
        }
        if self.p.shuffle_every > 0 {
            t.push_str(" · karışan");
        }
        t
    }

    fn goal(&self) -> String {
        let unit = if self.p.group == 3 { "üçlüleri" } else { "çiftleri" };
        let mut g = format!("Bütün {unit} bul · 3 yıldız ≤ {} hamle", self.three_star());
        if let Some(l) = self.limit {
            g.push_str(&format!(" · sınır {l}"));
        }
        if self.p.shuffle_every > 0 {
            g.push_str(&format!(" · her {} hamlede karışır", self.p.shuffle_every));
        }
        g
    }
}

impl Session for Pairs {
    fn state(&self) -> Value {
        let preview = self.phase == Phase::Preview;
        let cards: Vec<Value> = self
            .board
            .iter()
            .map(|&id| {
                let up = preview || self.matched[id] || self.open.contains(&id);
                json!({
                    "id": id,
                    "face": if up || self.phase == Phase::Done { self.face_json(id) } else { Value::Null },
                    "up": up,
                    "matched": self.matched[id],
                })
            })
            .collect();
        json!({
            "status": self.status(),
            "stars": self.stars(),
            "phase": self.phase.key(),
            "title": self.title(),
            "goal": self.goal(),
            "summary": self.summary(),
            "cols": self.p.cols,
            "rows": self.p.rows,
            "group": self.p.group,
            "confusable": self.p.confusable,
            "cards": cards,
            "moves": self.moves,
            "par": self.par_moves(),
            "three_star": self.three_star(),
            "two_star": self.two_star(),
            "limit": self.limit,
            "found": self.found,
            "groups": self.groups(),
            "preview_ms": if preview { self.preview_left.max(0.0) } else { 0.0 },
            "preview_total": self.p.preview_ms,
            "look_ms": self.p.look_ms,
            "shuffle_every": self.p.shuffle_every,
            "moves_to_shuffle": (self.p.shuffle_every > 0).then(|| self.p.shuffle_every - self.moves_since_shuffle),
            "swaps": self.swaps.iter().map(|&(a, b)| json!([a, b])).collect::<Vec<_>>(),
            "shuffle_serial": self.shuffle_serial,
            "match_serial": self.match_serial,
            "last_match": self.last_match,
            "miss_serial": self.miss_serial,
            "last_miss": self.last_miss,
            "elapsed_ms": self.elapsed_ms,
        })
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if a["start"].as_bool() == Some(true) {
            if self.phase != Phase::Intro {
                return Err("Zaten başladı".into());
            }
            self.enter(if self.p.preview_ms > 0.0 { Phase::Preview } else { Phase::Play });
            return Ok(());
        }
        if a["close"].as_bool() == Some(true) {
            if self.phase != Phase::Look {
                return Err("Kapanacak kart yok".into());
            }
            self.close_look();
            return Ok(());
        }
        let Some(pos) = a["flip"].as_u64() else {
            return Err("Bilinmeyen hamle".into());
        };
        let pos = pos as usize;
        match self.phase {
            Phase::Play => {}
            Phase::Intro => return Err("Önce Başla'ya dokun".into()),
            Phase::Preview => return Err("Önizleme sürüyor".into()),
            Phase::Look => return Err("Kartlar kapanıyor".into()),
            Phase::Shuffle => return Err("Kartlar karışıyor".into()),
            Phase::Done => return Err("Bölüm bitti".into()),
        }
        if pos >= self.board.len() {
            return Err("Geçersiz kart".into());
        }
        let id = self.board[pos];
        if self.matched[id] {
            return Err(if self.p.group == 3 { "Bu üçlü zaten bulundu" } else { "Bu çift zaten bulundu" }.into());
        }
        if self.open.contains(&id) {
            return Err("Bu kart zaten açık".into());
        }
        if self.open.len() >= self.p.group {
            return Err("Bu turda başka kart açılamaz".into());
        }
        self.open.push(id);
        let first = self.card_face[self.open[0]];
        if self.card_face[id] != first {
            self.moves += 1;
            self.miss_serial += 1;
            self.last_miss = self.open.iter().map(|&c| self.pos_of(c)).collect();
            self.enter(Phase::Look);
        } else if self.open.len() == self.p.group {
            self.moves += 1;
            for &c in &self.open {
                self.matched[c] = true;
            }
            self.last_match = self.open.iter().map(|&c| self.pos_of(c)).collect();
            self.match_serial += 1;
            self.found += 1;
            self.open.clear();
            self.after_move();
        }
        Ok(())
    }

    fn tick(&mut self, dt_ms: f64) {
        self.phase_ms += dt_ms;
        if matches!(self.phase, Phase::Play | Phase::Look | Phase::Shuffle) {
            self.elapsed_ms += dt_ms;
        }
        match self.phase {
            Phase::Preview => {
                self.preview_left -= dt_ms;
                if self.preview_left <= 0.0 {
                    self.enter(Phase::Play);
                }
            }
            Phase::Look if self.phase_ms >= self.p.look_ms => self.close_look(),
            Phase::Shuffle if self.phase_ms >= SHUFFLE_MS => self.enter(Phase::Play),
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    const LEVELS: [u32; 9] = [1, 2, 3, 50, 137, 250, 400, 499, 500];

    fn begin(g: &mut Pairs) {
        g.act(&json!({"start": true})).unwrap();
        let mut guard = 0;
        while g.phase == Phase::Preview {
            g.tick(50.0);
            guard += 1;
            assert!(guard < 100);
        }
        assert_eq!(g.phase, Phase::Play);
    }

    fn settle(g: &mut Pairs) {
        let mut guard = 0;
        while matches!(g.phase, Phase::Look | Phase::Shuffle) {
            g.tick(50.0);
            guard += 1;
            assert!(guard < 100);
        }
    }

    /// Positions of each unmatched face, read from the board (a cheating, perfect player).
    fn groups_now(g: &Pairs) -> Vec<Vec<usize>> {
        let mut m: HashMap<usize, Vec<usize>> = HashMap::new();
        for (p, &id) in g.board.iter().enumerate() {
            if !g.matched[id] {
                m.entry(g.card_face[id]).or_default().push(p);
            }
        }
        let mut v: Vec<_> = m.into_values().collect();
        v.sort();
        v
    }

    fn solve(g: &mut Pairs) {
        let mut guard = 0;
        while g.phase != Phase::Done {
            let grp = groups_now(g).remove(0);
            for p in grp {
                g.act(&json!({ "flip": p })).unwrap();
            }
            settle(g);
            guard += 1;
            assert!(guard < 100);
        }
    }

    #[test]
    fn params_curve() {
        for l in LEVELS {
            let p = params(l);
            assert_eq!((p.cols * p.rows) % p.group, 0, "level {l}");
            assert!((0.0..=2000.0).contains(&p.preview_ms));
            assert!(p.cols <= 6 && p.rows <= 6);
        }
        let p1 = params(1);
        assert_eq!((p1.cols, p1.rows, p1.group, p1.preview_ms), (3, 4, 2, 2000.0));
        assert!(params(2).preview_ms < p1.preview_ms);
        assert_eq!((params(500).cols, params(500).rows), (6, 6));
        assert_eq!(params(201).preview_ms, 0.0);
        assert_eq!(params(105).group, 3);
        assert!(params(73).shuffle_every > 0 && params(72).shuffle_every == 0);
        assert!(params(93).limit_mult.is_some() && params(94).limit_mult.is_none());
        let sizes: std::collections::BTreeSet<_> = (1..=500).map(|l| (params(l).cols, params(l).rows)).collect();
        for s in PAIR_SIZES {
            assert!(sizes.contains(&s));
        }
    }

    #[test]
    fn boards_are_solvable_and_faces_distinct() {
        for l in 1..=500 {
            let g = Pairs::level(l);
            let n = g.board.len();
            assert_eq!(n, g.p.cols * g.p.rows);
            let mut count: HashMap<usize, usize> = HashMap::new();
            for &id in &g.board {
                *count.entry(g.card_face[id]).or_default() += 1;
            }
            assert!(count.values().all(|&c| c == g.p.group), "level {l}");
            assert_eq!(count.len(), g.groups());
            let mut f = g.faces.clone();
            f.sort_by_key(|f| (f.shape, f.color, f.detail));
            f.dedup();
            assert_eq!(f.len(), g.faces.len(), "level {l}: duplicate faces");
            assert!(g.faces.iter().all(|f| f.shape < SHAPES && f.color < COLORS && f.detail < 3));
            assert!(g.par >= g.groups() as f64 && g.par <= 2.2 * g.groups() as f64, "level {l}: par {}", g.par);
            let mut sorted = g.board.clone();
            sorted.sort_unstable();
            assert_eq!(sorted, (0..n).collect::<Vec<_>>());
        }
    }

    #[test]
    fn confusable_sets_share_features() {
        let mut r = Rng::new(3);
        let f = pick_faces(&mut r, 18, 2);
        // Every face shares its shape and its colour with some other face.
        for a in &f {
            assert!(f.iter().any(|b| b != a && b.shape == a.shape));
            assert!(f.iter().any(|b| b != a && b.color == a.color));
        }
        let f = pick_faces(&mut r, 18, 3);
        assert!(f.iter().any(|f| f.detail == 1));
        let f = pick_faces(&mut r, 18, 0);
        let shapes: std::collections::HashSet<_> = f.iter().map(|f| f.shape).collect();
        assert_eq!(shapes.len(), 12);
    }

    #[test]
    fn deterministic() {
        for l in LEVELS {
            let (a, b) = (Pairs::level(l), Pairs::level(l));
            assert_eq!(a.board, b.board);
            assert_eq!(a.faces, b.faces);
            assert_eq!(a.par, b.par);
            assert_eq!(a.state(), b.state());
        }
    }

    #[test]
    fn perfect_play_wins_three_stars() {
        for l in LEVELS {
            let mut g = Pairs::level(l);
            begin(&mut g);
            solve(&mut g);
            assert_eq!(g.status(), "won", "level {l}");
            assert_eq!(g.moves as usize, g.groups());
            assert_eq!(g.stars(), 3);
            assert!(g.state()["summary"].as_str().unwrap().contains("Hamle"));
        }
    }

    #[test]
    fn flip_rules() {
        let mut g = Pairs::level(1);
        assert!(g.act(&json!({"flip": 0})).is_err()); // intro
        g.act(&json!({"start": true})).unwrap();
        assert!(g.act(&json!({"flip": 0})).is_err()); // preview
        begin_from_preview(&mut g);
        let grp = groups_now(&g);
        // Match one pair.
        g.act(&json!({ "flip": grp[0][0] })).unwrap();
        let before = g.state();
        assert!(g.act(&json!({ "flip": grp[0][0] })).is_err()); // same card twice
        assert!(g.act(&json!({"flip": 99})).is_err());
        assert_eq!(g.state(), before);
        g.act(&json!({ "flip": grp[0][1] })).unwrap();
        assert_eq!(g.found, 1);
        let before = g.state();
        assert!(g.act(&json!({ "flip": grp[0][0] })).is_err()); // matched
        assert_eq!(g.state(), before);
        // Mismatch: a third card is refused while the two are showing.
        g.act(&json!({ "flip": grp[1][0] })).unwrap();
        g.act(&json!({ "flip": grp[2][0] })).unwrap();
        assert_eq!(g.phase, Phase::Look);
        assert_eq!(g.moves, 2);
        let before = g.state();
        assert!(g.act(&json!({ "flip": grp[3][0] })).is_err());
        assert_eq!(g.state(), before);
        assert_eq!(before["cards"][grp[1][0]]["up"], true);
        assert!(before["cards"][grp[3][0]]["face"].is_null()); // hidden faces stay hidden
        // Closing early flips them back.
        g.act(&json!({"close": true})).unwrap();
        assert_eq!(g.phase, Phase::Play);
        assert_eq!(g.state()["cards"][grp[1][0]]["up"], false);
        assert!(g.act(&json!({"close": true})).is_err());
        // Look also ends on its own.
        g.act(&json!({ "flip": grp[1][0] })).unwrap();
        g.act(&json!({ "flip": grp[2][0] })).unwrap();
        g.tick(g.p.look_ms + 1.0);
        assert_eq!(g.phase, Phase::Play);
    }

    fn begin_from_preview(g: &mut Pairs) {
        while g.phase == Phase::Preview {
            g.tick(100.0);
        }
    }

    #[test]
    fn triplets_need_three() {
        let l = (100..=500).find(|&l| params(l).group == 3 && params(l).shuffle_every == 0).unwrap();
        let mut g = Pairs::level(l);
        begin(&mut g);
        let grp = groups_now(&g);
        assert_eq!(grp[0].len(), 3);
        g.act(&json!({ "flip": grp[0][0] })).unwrap();
        g.act(&json!({ "flip": grp[0][1] })).unwrap();
        assert_eq!((g.phase, g.moves, g.found), (Phase::Play, 0, 0)); // two of three: keep going
        g.act(&json!({ "flip": grp[0][2] })).unwrap();
        assert_eq!((g.moves, g.found), (1, 1));
        // Second card wrong: the turn ends at once.
        g.act(&json!({ "flip": grp[1][0] })).unwrap();
        g.act(&json!({ "flip": grp[2][0] })).unwrap();
        assert_eq!((g.phase, g.moves), (Phase::Look, 2));
        assert!(g.act(&json!({ "flip": grp[1][1] })).is_err());
    }

    #[test]
    fn shuffle_keeps_groups() {
        let l = (70..=500).find(|&l| params(l).shuffle_every > 0 && params(l).limit_mult.is_none()).unwrap();
        let mut g = Pairs::level(l);
        begin(&mut g);
        let every = g.p.shuffle_every;
        // Match one group, then mismatch until a shuffle happens.
        let grp = groups_now(&g);
        for &p in &grp[0] {
            g.act(&json!({ "flip": p })).unwrap();
        }
        let matched_pos: Vec<usize> = grp[0].clone();
        let mut guard = 0;
        while g.shuffle_serial == 0 {
            let grp = groups_now(&g);
            g.act(&json!({ "flip": grp[0][0] })).unwrap();
            g.act(&json!({ "flip": grp[1][0] })).unwrap();
            g.act(&json!({"close": true})).unwrap();
            guard += 1;
            assert!(guard <= every);
        }
        assert_eq!(g.phase, Phase::Shuffle);
        assert!(g.act(&json!({"flip": 0})).is_err());
        let st = g.state();
        assert!(!g.swaps.is_empty() && g.swaps.len() <= g.p.swaps);
        for &(a, b) in &g.swaps {
            assert!(!g.matched[g.board[a]] && !g.matched[g.board[b]]);
            assert_ne!(g.card_face[g.board[a]], g.card_face[g.board[b]]);
            assert!(!matched_pos.contains(&a) && !matched_pos.contains(&b));
        }
        for &p in &matched_pos {
            assert_eq!(st["cards"][p]["matched"], true);
        }
        let mut count: HashMap<usize, usize> = HashMap::new();
        for &id in &g.board {
            *count.entry(g.card_face[id]).or_default() += 1;
        }
        assert!(count.values().all(|&c| c == g.p.group));
        settle(&mut g);
        solve(&mut g);
        assert_eq!(g.status(), "won");
    }

    #[test]
    fn scoring_thresholds() {
        let mut g = Pairs::level(1);
        g.won = true;
        g.moves = g.three_star();
        assert_eq!(g.stars(), 3);
        g.moves = g.three_star() + 1;
        assert_eq!(g.stars(), if g.three_star() < g.two_star() { 2 } else { 1 });
        g.moves = g.two_star();
        assert_eq!(g.stars(), 2);
        g.moves = g.two_star() + 1;
        assert_eq!(g.stars(), 1);
        assert!(g.three_star() >= g.groups() as u32);
    }

    #[test]
    fn move_limit_loses() {
        let l = (90..=500).find(|&l| params(l).limit_mult.is_some() && params(l).shuffle_every == 0).unwrap();
        let mut g = Pairs::level(l);
        let limit = g.limit.unwrap();
        assert!(limit > g.two_star());
        begin(&mut g);
        let mut guard = 0;
        while g.phase != Phase::Done {
            let grp = groups_now(&g);
            g.act(&json!({ "flip": grp[0][0] })).unwrap();
            g.act(&json!({ "flip": grp[1][0] })).unwrap();
            settle(&mut g);
            guard += 1;
            assert!(guard < 500);
        }
        assert_eq!(g.status(), "lost");
        assert_eq!(g.moves, limit);
        assert!(g.state()["summary"].as_str().unwrap().contains("sınır"));
        assert!(g.act(&json!({"flip": 0})).is_err());
    }

    #[test]
    #[ignore]
    fn timing_500_levels() {
        let t = std::time::Instant::now();
        for l in 1..=500 {
            let _ = Pairs::level(l);
        }
        println!("pairs: 500 levels in {:?}", t.elapsed());
        for l in LEVELS {
            let g = Pairs::level(l);
            println!(
                "L{l}: {}×{} group {} par {:.1} 3★≤{} 2★≤{} limit {:?} shuffle {}/{} conf {} preview {}",
                g.p.cols, g.p.rows, g.p.group, g.par, g.three_star(), g.two_star(), g.limit,
                g.p.shuffle_every, g.p.swaps, g.p.confusable, g.p.preview_ms
            );
        }
    }
}
