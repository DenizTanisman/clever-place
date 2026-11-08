//! Değişimi Yakala — change detection on procedural illustrated scenes (`scene.rs`).
//!
//! **Flicker variant** (the "flicker paradigm", Rensink, O'Regan & Clark 1997): picture A is shown
//! for `show_ms`, then a blank mask for `mask_ms`, then picture B (identical except for the
//! change), then the mask again, and so on, until the player taps the changed spot. The blank
//! wipes out the motion transient that would otherwise pop the change out, so it must be found by
//! attention — the effect known as *change blindness*. **Side-by-side variant**: A and B are shown
//! at the same time (one above the other); find every difference, no flicker. Taps on either
//! picture count.
//!
//! Changes (exactly one per round, or 2–3 in later levels): colour of an item or garment, a subtle
//! shade step, an object/animal/person appearing or disappearing, a position shift, hat on/off, hat
//! colour, top pattern, glasses on/off, held item, bag, hair colour, clock hour, curtains, fruit
//! kind. Rust knows each change's bounding box (part boxes for people); a tap hits when it lies
//! within that box inflated by the tolerance `tol`. Every change is verified to really alter the
//! description, to lie inside the canvas and to be at most 30% hidden by nearer items.
//!
//! Difficulty tier of a change (0 = obvious … 3 = subtle) = tier from the changed area (≥ 15000
//! canvas units² → 0, ≥ 5000 → 1, ≥ 1500 → 2, else 3) + modifiers (shade step +2, position shift
//! +1, glasses +1, pattern +1, background furniture/wall colour +1), clamped to 0..=3.
//!
//! Level curve (`params`, t = (level−1)/499):
//! - variant: every 4th level side-by-side, otherwise flicker.
//! - changes per round: flicker 1; from level 120 every 3rd flicker level 2; from 300 2 (every 3rd
//!   level 3). Side-by-side: 2 below level 150, then 3.
//! - rounds: 4 (< 100), 5 (< 300), 6 — one fewer in side-by-side levels.
//! - picture time 1100 → 420 ms, mask 260 → 140 ms; round limit flicker 40 → 24 s (+12 s per extra
//!   change), side-by-side 45 → 30 s (+10 s per change beyond 2).
//! - allowed tiers [⌊2.2t⌋ min 2, min(3, 1 + ⌊2.4t + 0.2⌋)]: level 1 = 0–1, level 500 = 2–3.
//! - scenes: people 2–3 → 5–7, clutter 0.2 → 1.0, animals 0–1 → 0–2; tap tolerance 62 → 36 units.
//!
//! Rounds and scoring: a round ends when every change is found, when its time runs out, or after
//! `MAX_WRONG` (3) wrong taps in it — the latter two count as a **missed round** and the change is
//! revealed. The level is **lost as soon as 2 rounds are missed** (so one miss is forgiven).
//! Stars: 3 = no missed round, ≤ 1 wrong tap in total and mean find time ≤ 40% of the round limit;
//! 2 = no missed round, or one missed round with ≤ 1 wrong tap and that speed; 1 = otherwise.
//!
//! State: `{status, stars, title, goal, summary?, phase: "intro"|"countdown"|"ready"|"run"|
//!          "reveal"|"done", variant: "flicker"|"side", round (1-based), rounds, found_rounds,
//!          missed_rounds, wrong, round_wrong, max_wrong, t_ms, round_ms, phase_ms, phase_len_ms,
//!          show_ms, mask_ms, frame: "a"|"mask"|"b", tol, n_changes, found_n, changes: [{found,
//!          bbox: [x,y,w,h]|null, label|null}], taps: [{x,y,hit}], result: "found"|"timeout"|
//!          "wrong"|null, scene_no, scene_a, scene_b}` (scenes: see `scene.rs`; omitted in intro, sent
//!          from the countdown on so the view can rasterise them before the first frame).
//! Actions: `{"start":true}` · `{"tap":{"x":..,"y":..}}` (canvas units) · `{"next":true}` (skip the
//!          reveal).

use crate::games::scene::*;
use crate::rng::{seed_for, Rng};
use crate::Session;
use serde_json::{json, Value};

pub const COUNTDOWN_MS: f64 = 3000.0;
pub const READY_MS: f64 = 900.0;
pub const REVEAL_FOUND_MS: f64 = 1300.0;
pub const REVEAL_MISS_MS: f64 = 2800.0;
pub const MAX_WRONG: u32 = 3;
/// Missed rounds that end the level.
pub const LOSE_AT_MISSED: u32 = 2;
/// Star speed threshold: mean find time / round limit.
pub const FAST_RATIO: f64 = 0.4;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Variant {
    Flicker,
    Side,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Params {
    pub variant: Variant,
    pub rounds: usize,
    pub changes: usize,
    pub show_ms: f64,
    pub mask_ms: f64,
    pub round_ms: f64,
    pub tol: f64,
    pub tier: (u8, u8),
    pub scene: SceneParams,
}

pub fn params(level: u32) -> Params {
    let level = level.clamp(1, crate::MAX_LEVEL);
    let t = (level - 1) as f64 / 499.0;
    let variant = if level.is_multiple_of(4) { Variant::Side } else { Variant::Flicker };
    let changes = match variant {
        Variant::Side => {
            if level < 150 {
                2
            } else {
                3
            }
        }
        Variant::Flicker => {
            if level >= 300 {
                if level.is_multiple_of(3) {
                    3
                } else {
                    2
                }
            } else if level >= 120 && level.is_multiple_of(3) {
                2
            } else {
                1
            }
        }
    };
    let mut rounds = if level < 100 {
        4
    } else if level < 300 {
        5
    } else {
        6
    };
    if variant == Variant::Side {
        rounds -= 1;
    }
    let round_ms = match variant {
        Variant::Flicker => 40_000.0 - 16_000.0 * t + 12_000.0 * (changes - 1) as f64,
        Variant::Side => 45_000.0 - 15_000.0 * t + 10_000.0 * (changes - 2) as f64,
    };
    let lo = ((2.2 * t).floor() as u8).min(2);
    let hi = (1 + (2.4 * t + 0.2).floor() as u8).min(3);
    Params {
        variant,
        rounds,
        changes,
        show_ms: (1100.0 - 680.0 * t).round(),
        mask_ms: (260.0 - 120.0 * t).round(),
        round_ms: (round_ms / 100.0).round() * 100.0,
        tol: 62.0 - 26.0 * t,
        tier: (lo, hi.max(lo)),
        scene: SceneParams {
            people: (2 + (3.0 * t).round() as usize, 3 + (4.0 * t).round() as usize),
            clutter: 0.2 + 0.8 * t,
            hat_p: 0.45,
            animals: (0, 1 + t.round() as usize),
        },
    }
}

// ---------------------------------------------------------------------------------------- changes

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mut {
    TopColor,
    BottomColor,
    HatToggle,
    HatColor,
    Pattern,
    Glasses,
    Hold,
    Bag,
    HairColor,
    RemovePerson,
    Color,
    Color2,
    Shade,
    Remove,
    Move,
    Fruit,
    ClockHour,
    Curtains,
}

impl Mut {
    pub fn key(self) -> &'static str {
        match self {
            Mut::TopColor => "top_color",
            Mut::BottomColor => "bottom_color",
            Mut::HatToggle => "hat_toggle",
            Mut::HatColor => "hat_color",
            Mut::Pattern => "pattern",
            Mut::Glasses => "glasses",
            Mut::Hold => "hold",
            Mut::Bag => "bag",
            Mut::HairColor => "hair_color",
            Mut::RemovePerson => "remove_person",
            Mut::Color => "color",
            Mut::Color2 => "color2",
            Mut::Shade => "shade",
            Mut::Remove => "remove",
            Mut::Move => "move",
            Mut::Fruit => "fruit",
            Mut::ClockHour => "clock",
            Mut::Curtains => "curtains",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Change {
    pub item: u32,
    pub what: Mut,
    pub label: String,
    pub bbox: Rect,
    pub tier: u8,
}

/// Every mutation that makes sense for the items of `sc`.
pub fn candidates(sc: &Scene) -> Vec<(u32, Mut)> {
    let mut out = vec![];
    for it in &sc.items {
        let leaf = sc.children(it.id).count() == 0;
        let id = it.id;
        if let Some(p) = &it.person {
            out.extend([(id, Mut::TopColor), (id, Mut::BottomColor), (id, Mut::HatToggle), (id, Mut::Pattern)]);
            out.extend([(id, Mut::Glasses), (id, Mut::Hold), (id, Mut::Bag), (id, Mut::Shade)]);
            if p.hat.is_some_and(|h| h.kind != HatKind::Hasir) {
                out.push((id, Mut::HatColor));
            }
            if p.hair_visible() {
                out.push((id, Mut::HairColor));
            }
            if leaf {
                out.push((id, Mut::RemovePerson));
            }
            continue;
        }
        match it.kind {
            k if k.is_object() || k.is_animal() => {
                out.extend([(id, Mut::Color), (id, Mut::Shade)]);
                if leaf {
                    out.push((id, Mut::Remove));
                }
                let movable = matches!(it.on.and_then(|o| sc.get(o)).map(|o| o.kind), None | Some(Kind::Table | Kind::Counter | Kind::Bench));
                if movable {
                    out.push((id, Mut::Move));
                }
                if k == Kind::Fruit {
                    out.push((id, Mut::Fruit));
                }
                if k == Kind::Vase {
                    out.push((id, Mut::Color2));
                }
            }
            Kind::Table | Kind::Bench | Kind::Counter | Kind::Lamp | Kind::Parasol => {
                out.extend([(id, Mut::Color), (id, Mut::Shade)]);
            }
            Kind::Plant => {
                out.push((id, Mut::Color));
                if it.var == 1 {
                    out.push((id, Mut::Color2));
                }
                if leaf {
                    out.push((id, Mut::Remove));
                }
            }
            Kind::Window => {
                out.push((id, Mut::Curtains));
                if it.var & 1 == 1 {
                    out.push((id, Mut::Color));
                }
            }
            Kind::Clock => out.extend([(id, Mut::ClockHour), (id, Mut::Color), (id, Mut::Remove)]),
            Kind::Frame => out.extend([(id, Mut::Color), (id, Mut::Remove)]),
            _ => {}
        }
    }
    out
}

fn other_col(r: &mut Rng, choices: &[Col], cur: Col) -> Option<Col> {
    let c: Vec<Col> = choices.iter().copied().filter(|&c| c != cur).collect();
    (!c.is_empty()).then(|| *r.pick(&c))
}

/// Apply a mutation to a copy of `sc`. Returns the new scene and the reveal label for the two
/// orders (A = original, A = mutated).
pub fn apply(sc: &Scene, id: u32, m: Mut, r: &mut Rng) -> Option<(Scene, String, String)> {
    let mut out = sc.clone();
    let setting = sc.setting;
    let it = sc.get(id)?.clone();
    let same = |s: String| (s.clone(), s);
    let labels: (String, String);
    if let Some(p) = it.person {
        let mut q = p;
        labels = match m {
            Mut::TopColor => {
                q.top = Tone::of(other_col(r, &COLS, p.top.c)?);
                same(format!("{} rengi değişti", cap(p.top_kind.gen())))
            }
            Mut::Shade => {
                q.top = Tone { c: p.top.c, s: if r.chance(0.5) { 1 } else { -1 } };
                same(format!("{} tonu değişti", cap(p.top_kind.gen())))
            }
            Mut::BottomColor => {
                q.bottom = Tone::of(other_col(r, &COLS, p.bottom.c)?);
                same(format!("{} rengi değişti", cap(p.bottom_kind.gen())))
            }
            Mut::HatToggle => {
                if p.hat.is_some() {
                    q.hat = None;
                    ("Şapka kayboldu".into(), "Şapka belirdi".into())
                } else {
                    q.hat = Some(gen_hat(r, setting));
                    ("Şapka belirdi".into(), "Şapka kayboldu".into())
                }
            }
            Mut::HatColor => {
                let mut h = p.hat?;
                let choices: &[Col] = if h.mat == Mat::Deri { &[Col::Siyah, Col::Kahve, Col::Kirmizi] } else { &COLS };
                h.tone = Tone::of(other_col(r, choices, h.tone.c)?);
                q.hat = Some(h);
                same(format!("{} rengi değişti", cap(h.kind.gen())))
            }
            Mut::Pattern => {
                let pats: Vec<Pattern> = PATTERNS.iter().copied().filter(|&x| x != p.pattern).collect();
                q.pattern = *r.pick(&pats);
                same(format!("{} deseni değişti", cap(p.top_kind.gen())))
            }
            Mut::Glasses => match p.glasses {
                Glasses::None => {
                    q.glasses = if r.chance(0.7) { Glasses::Reading } else { Glasses::Sun };
                    ("Gözlük belirdi".into(), "Gözlük kayboldu".into())
                }
                _ => {
                    q.glasses = Glasses::None;
                    ("Gözlük kayboldu".into(), "Gözlük belirdi".into())
                }
            },
            Mut::Hold => match p.hold {
                Some((k, _)) => {
                    q.hold = None;
                    (format!("Elindeki {} kayboldu", k.name()), format!("Elinde {} belirdi", k.name()))
                }
                None => {
                    let h = gen_hold(r, setting, p.age);
                    q.hold = Some(h);
                    (format!("Elinde {} belirdi", h.0.name()), format!("Elindeki {} kayboldu", h.0.name()))
                }
            },
            Mut::Bag => match p.bag {
                Some(_) => {
                    q.bag = None;
                    ("Çanta kayboldu".into(), "Çanta belirdi".into())
                }
                None => {
                    let k = if r.chance(0.5) { BagKind::Backpack } else { BagKind::Handbag };
                    q.bag = Some((k, Tone::of(*r.pick(bag_tones()))));
                    ("Çanta belirdi".into(), "Çanta kayboldu".into())
                }
            },
            Mut::HairColor => {
                let hs: Vec<Hair> = HAIRS.iter().copied().filter(|&h| h != p.hair).collect();
                q.hair = *r.pick(&hs);
                same("Saçın rengi değişti".into())
            }
            Mut::RemovePerson => {
                out.items.retain(|i| i.id != id);
                return Some((out, "Bir kişi kayboldu".into(), "Bir kişi belirdi".into()));
            }
            _ => return None,
        };
        let o = out.get_mut(id)?;
        o.person = Some(q);
        o.tone = q.top;
        o.tone2 = q.top;
        // A new hand or bag item must not collide with neighbours.
        let moved = out.get(id)?.clone();
        if matches!(m, Mut::Hold | Mut::Bag) {
            let ex: Vec<u32> = moved.on.into_iter().collect();
            if !out.fits(&moved, &ex, Some(id)) {
                return None;
            }
        }
        return Some((out, labels.0, labels.1));
    }
    let name = cap(it.kind.name());
    let gen = cap(it.kind.gen());
    labels = match m {
        Mut::Color => {
            let c = other_col(r, tone_choices(it.kind), it.tone.c)?;
            out.get_mut(id)?.tone = Tone::of(c);
            same(match it.kind {
                Kind::Window => "Perdenin rengi değişti".into(),
                Kind::Plant => "Saksının rengi değişti".into(),
                Kind::Frame => "Tablodaki resim değişti".into(),
                Kind::Lamp => "Lamba başlığının rengi değişti".into(),
                _ => format!("{gen} rengi değişti"),
            })
        }
        Mut::Color2 => {
            let c = other_col(r, tone2_choices(it.kind), it.tone2.c)?;
            out.get_mut(id)?.tone2 = Tone::of(c);
            same("Çiçeklerin rengi değişti".into())
        }
        Mut::Shade => {
            out.get_mut(id)?.tone = Tone { c: it.tone.c, s: if r.chance(0.5) { 1 } else { -1 } };
            same(format!("{gen} tonu değişti"))
        }
        Mut::Remove => {
            out.items.retain(|i| i.id != id);
            (format!("{name} kayboldu"), format!("{name} belirdi"))
        }
        Mut::Fruit => {
            let v = (it.var as usize + 1 + r.below(FRUITS.len() - 1)) % FRUITS.len();
            out.get_mut(id)?.var = v as u8;
            same("Kasedeki meyve değişti".into())
        }
        Mut::ClockHour => {
            let h = 1 + (it.var as usize - 1 + 2 + r.below(8)) % 12;
            out.get_mut(id)?.var = h as u8;
            same("Saatin akrebi değişti".into())
        }
        Mut::Curtains => {
            let o = out.get_mut(id)?;
            o.var ^= 1;
            if o.var & 1 == 1 {
                ("Perde belirdi".into(), "Perde kayboldu".into())
            } else {
                ("Perde kayboldu".into(), "Perde belirdi".into())
            }
        }
        Mut::Move => {
            let s = it.s;
            let sup = it.on.and_then(|o| sc.get(o)).cloned();
            let (lo, hi) = match &sup {
                Some(sp) => (sp.b.x + 12.0 * s, sp.b.x1() - 12.0 * s - it.b.w),
                None => (20.0, W - 20.0 - it.b.w),
            };
            let mut done = false;
            for _ in 0..16 {
                let d = (50.0 + 90.0 * r.f64()) * s * if r.chance(0.5) { 1.0 } else { -1.0 };
                let nx = it.b.x + d;
                if nx < lo || nx > hi {
                    continue;
                }
                let mut moved = it.clone();
                moved.b.x = nx;
                let ex: Vec<u32> = it.on.into_iter().collect();
                if let Some(sp) = &sup {
                    if sc.children(sp.id).any(|c| c.id != id && c.full_box().inflate(6.0 * s).inter(&moved.b) > 0.0) {
                        continue;
                    }
                }
                if !sc.fits(&moved, &ex, Some(id)) {
                    continue;
                }
                out.get_mut(id)?.b.x = nx;
                done = true;
                break;
            }
            if !done {
                return None;
            }
            same(format!("{name} yer değiştirdi"))
        }
        _ => return None,
    };
    Some((out, labels.0, labels.1))
}

/// Where the change shows, in canvas units (union over both versions).
pub fn change_region(a: &Scene, b: &Scene, id: u32, m: Mut) -> Option<Rect> {
    let part = |sc: &Scene| -> Option<Rect> {
        let it = sc.get(id)?;
        let Some(pp) = it.parts() else { return Some(it.full_box()) };
        Some(match m {
            Mut::TopColor | Mut::Pattern | Mut::Shade => pp.torso,
            Mut::BottomColor => pp.legs,
            Mut::HatToggle | Mut::HatColor => pp.hat,
            Mut::Glasses => pp.face,
            Mut::Hold => pp.hand,
            Mut::Bag => pp.bag,
            Mut::HairColor => pp.hair,
            _ => it.full_box(),
        })
    };
    match (part(a), part(b)) {
        (Some(x), Some(y)) => Some(x.union(&y)),
        (Some(x), None) | (None, Some(x)) => Some(x),
        _ => None,
    }
}

/// Share of `region` hidden by items drawn in front of item `id` in `sc`.
fn hidden_share(sc: &Scene, id: u32, region: &Rect) -> f64 {
    let Some(pos) = sc.items.iter().position(|i| i.id == id) else { return 0.0 };
    let row = sc.items[pos].row;
    let mut hidden = 0.0;
    for it in &sc.items[pos + 1..] {
        if it.on == Some(id) || it.row == WALL {
            continue;
        }
        // Same-row neighbours never overlap; nearer rows and supported items can hide.
        if row != WALL && it.row == row && it.on.is_none() {
            continue;
        }
        hidden += it.occluder().inter(region);
    }
    hidden / region.area().max(1.0)
}

pub fn tier_of(sc: &Scene, id: u32, m: Mut, region: &Rect) -> u8 {
    let a = region.area();
    let mut t: i32 = if a >= 15_000.0 {
        0
    } else if a >= 5_000.0 {
        1
    } else if a >= 1_500.0 {
        2
    } else {
        3
    };
    let kind = sc.get(id).map(|i| i.kind).unwrap_or(Kind::Person);
    t += match m {
        Mut::Shade => 2,
        Mut::Move | Mut::Glasses | Mut::Pattern => 1,
        Mut::RemovePerson => -3,
        Mut::Color | Mut::Color2 | Mut::Curtains
            if matches!(kind, Kind::Table | Kind::Bench | Kind::Counter | Kind::Window | Kind::Frame | Kind::Lamp | Kind::Plant | Kind::Parasol) =>
        {
            1
        }
        _ => 0,
    };
    t.clamp(0, 3) as u8
}

/// Pick `k` changes for scene `base` within `tier` (relaxed if needed). Returns (A, B, changes).
pub fn make_round(base: &Scene, k: usize, tier: (u8, u8), r: &mut Rng) -> Option<(Scene, Scene, Vec<Change>)> {
    let mut cands = candidates(base);
    r.shuffle(&mut cands);
    for relax in 0..4u8 {
        let lo = tier.0.saturating_sub(relax);
        let hi = (tier.1 + relax).min(3);
        let mut cur = base.clone();
        let mut picked: Vec<(Change, String, String)> = vec![];
        let mut used_items: Vec<u32> = vec![];
        for &(id, m) in &cands {
            if picked.len() == k {
                break;
            }
            if used_items.contains(&id) || cur.get(id).is_none() {
                continue;
            }
            // Never change an item and the thing it stands on in the same round.
            let sup = cur.get(id).and_then(|i| i.on);
            if sup.is_some_and(|s| used_items.contains(&s)) || cur.children(id).any(|c| used_items.contains(&c.id)) {
                continue;
            }
            let mut rr = Rng::new(r.next_u64());
            let Some((next, la, lb)) = apply(&cur, id, m, &mut rr) else { continue };
            if next == cur {
                continue;
            }
            let Some(reg) = change_region(&cur, &next, id, m) else { continue };
            let clipped = reg.clip();
            if clipped.area() < reg.area() * 0.8 || clipped.area() < 120.0 {
                continue;
            }
            let t = tier_of(&cur, id, m, &clipped);
            if t < lo || t > hi {
                continue;
            }
            if hidden_share(&cur, id, &clipped) > 0.3 || hidden_share(&next, id, &clipped) > 0.3 {
                continue;
            }
            // Separate from the other changes so taps are unambiguous.
            if picked.iter().any(|(c, _, _)| c.bbox.inflate(40.0).inter(&clipped) > 0.0) {
                continue;
            }
            picked.push((Change { item: id, what: m, label: String::new(), bbox: clipped, tier: t }, la, lb));
            used_items.push(id);
            cur = next;
        }
        if picked.len() == k {
            let swap = r.chance(0.5);
            let (a, b) = if swap { (cur, base.clone()) } else { (base.clone(), cur) };
            let changes = picked
                .into_iter()
                .map(|(mut c, la, lb)| {
                    c.label = if swap { lb } else { la };
                    c
                })
                .collect();
            return Some((a, b, changes));
        }
    }
    None
}

// ---------------------------------------------------------------------------------------- session

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Phase {
    Intro,
    Countdown,
    Ready,
    Run,
    Reveal,
    Done,
}

impl Phase {
    fn key(self) -> &'static str {
        match self {
            Phase::Intro => "intro",
            Phase::Countdown => "countdown",
            Phase::Ready => "ready",
            Phase::Run => "run",
            Phase::Reveal => "reveal",
            Phase::Done => "done",
        }
    }
}

pub struct Round {
    pub a: Scene,
    pub b: Scene,
    pub changes: Vec<Change>,
}

pub fn gen_rounds(level: u32, p: &Params) -> Vec<Round> {
    let mut rng = Rng::new(seed_for("change_spot", level, 0));
    let mut out = vec![];
    let mut guard = 0;
    while out.len() < p.rounds && guard < p.rounds * 6 {
        guard += 1;
        let seed = rng.next_u64();
        let min = p.scene.people.0;
        let base = generate_where(seed, &p.scene, |s| s.people().count() >= min);
        let mut r = Rng::new(seed ^ 0xC4A9_5E3D_17F0_0B21);
        if let Some((a, b, changes)) = make_round(&base, p.changes, p.tier, &mut r) {
            out.push(Round { a, b, changes });
        }
    }
    out
}

pub struct ChangeSpot {
    level: u32,
    p: Params,
    rounds: Vec<Round>,
    round: usize,
    phase: Phase,
    phase_ms: f64,
    t_ms: f64,
    found: Vec<bool>,
    round_wrong: u32,
    wrong: u32,
    found_rounds: u32,
    missed_rounds: u32,
    /// Find time / round limit for every found round.
    ratios: Vec<f64>,
    times: Vec<f64>,
    taps: Vec<(f64, f64, bool)>,
    result: Option<&'static str>,
    status: &'static str,
    stars: u32,
}

pub fn create(level: u32, _mode: &str) -> Result<Box<dyn Session>, String> {
    Ok(Box::new(ChangeSpot::new(level)))
}

impl ChangeSpot {
    pub fn new(level: u32) -> Self {
        let p = params(level);
        let rounds = gen_rounds(level, &p);
        let n = rounds.first().map(|r| r.changes.len()).unwrap_or(1);
        ChangeSpot {
            level,
            p,
            rounds,
            round: 0,
            phase: Phase::Intro,
            phase_ms: 0.0,
            t_ms: 0.0,
            found: vec![false; n],
            round_wrong: 0,
            wrong: 0,
            found_rounds: 0,
            missed_rounds: 0,
            ratios: vec![],
            times: vec![],
            taps: vec![],
            result: None,
            status: "playing",
            stars: 0,
        }
    }

    fn cur(&self) -> &Round {
        &self.rounds[self.round.min(self.rounds.len() - 1)]
    }

    fn frame(&self) -> &'static str {
        if self.p.variant == Variant::Side || self.phase != Phase::Run {
            return "b";
        }
        let cycle = 2.0 * (self.p.show_ms + self.p.mask_ms);
        let m = self.t_ms % cycle;
        if m < self.p.show_ms {
            "a"
        } else if m < self.p.show_ms + self.p.mask_ms {
            "mask"
        } else if m < 2.0 * self.p.show_ms + self.p.mask_ms {
            "b"
        } else {
            "mask"
        }
    }

    fn reveal_len(&self) -> f64 {
        if self.result == Some("found") {
            REVEAL_FOUND_MS
        } else {
            REVEAL_MISS_MS
        }
    }

    fn end_round(&mut self, result: &'static str) {
        self.result = Some(result);
        if result == "found" {
            self.found_rounds += 1;
            self.times.push(self.t_ms);
            self.ratios.push(self.t_ms / self.p.round_ms);
        } else {
            self.missed_rounds += 1;
        }
        self.phase = Phase::Reveal;
        self.phase_ms = 0.0;
    }

    fn after_reveal(&mut self) {
        if self.missed_rounds >= LOSE_AT_MISSED || self.round + 1 >= self.rounds.len() {
            self.finish();
            return;
        }
        self.round += 1;
        self.found = vec![false; self.cur().changes.len()];
        self.round_wrong = 0;
        self.taps.clear();
        self.result = None;
        self.t_ms = 0.0;
        self.phase = Phase::Ready;
        self.phase_ms = 0.0;
    }

    fn mean_ratio(&self) -> f64 {
        if self.ratios.is_empty() {
            1.0
        } else {
            self.ratios.iter().sum::<f64>() / self.ratios.len() as f64
        }
    }

    fn finish(&mut self) {
        self.phase = Phase::Done;
        self.phase_ms = 0.0;
        if self.missed_rounds >= LOSE_AT_MISSED {
            self.status = "lost";
            self.stars = 0;
            return;
        }
        self.status = "won";
        let fast = self.mean_ratio() <= FAST_RATIO;
        self.stars = if self.missed_rounds == 0 && self.wrong <= 1 && fast {
            3
        } else if self.missed_rounds == 0 || (self.wrong <= 1 && fast) {
            2
        } else {
            1
        };
    }

    fn title(&self) -> String {
        let base = match self.p.variant {
            Variant::Flicker => "Yanıp sönme",
            Variant::Side => "Yan yana",
        };
        if self.p.changes > 1 {
            format!("{base} · {} fark", self.p.changes)
        } else {
            base.to_string()
        }
    }

    fn goal(&self) -> String {
        let n = self.rounds.len();
        match (self.p.variant, self.p.changes) {
            (Variant::Flicker, 1) => format!("Değişen yeri bul, dokun · {n} tur"),
            (Variant::Flicker, k) => format!("Değişen {k} yeri bul · {n} tur"),
            (Variant::Side, k) => format!("İki resim arasındaki {k} farkı bul · {n} tur"),
        }
    }

    fn summary(&self) -> String {
        let n = self.rounds.len();
        let mean = if self.times.is_empty() { 0.0 } else { self.times.iter().sum::<f64>() / self.times.len() as f64 / 1000.0 };
        let mean = format!("{mean:.1}").replace('.', ",");
        if self.status == "lost" {
            format!("{} tur kaçtı · Bulunan {}/{} · Yanlış {}", self.missed_rounds, self.found_rounds, n, self.wrong)
        } else {
            format!("Bulunan {}/{} · Yanlış {} · Ort. {} sn", self.found_rounds, n, self.wrong, mean)
        }
    }

    fn tap(&mut self, x: f64, y: f64) -> Result<(), String> {
        if self.phase != Phase::Run {
            return Err("Şimdi değil".into());
        }
        if !(0.0..=W).contains(&x) || !(0.0..=H).contains(&y) {
            return Err("Resmin dışına dokundun".into());
        }
        let tol = self.p.tol;
        let mut best: Option<(usize, f64)> = None;
        for (i, c) in self.cur().changes.iter().enumerate() {
            if self.found[i] || !c.bbox.inflate(tol).contains(x, y) {
                continue;
            }
            let d = (x - c.bbox.cx()).hypot(y - c.bbox.cy());
            if best.is_none_or(|(_, bd)| d < bd) {
                best = Some((i, d));
            }
        }
        match best {
            Some((i, _)) => {
                self.found[i] = true;
                self.taps.push((x, y, true));
                if self.found.iter().all(|&f| f) {
                    self.end_round("found");
                }
            }
            None => {
                self.taps.push((x, y, false));
                self.wrong += 1;
                self.round_wrong += 1;
                if self.round_wrong >= MAX_WRONG {
                    self.end_round("wrong");
                }
            }
        }
        Ok(())
    }
}

impl Session for ChangeSpot {
    fn state(&self) -> Value {
        let r = self.cur();
        let show_scene = self.phase != Phase::Intro;
        let reveal_all = matches!(self.phase, Phase::Reveal | Phase::Done);
        let changes: Vec<Value> = r
            .changes
            .iter()
            .enumerate()
            .map(|(i, c)| {
                let visible = self.found.get(i).copied().unwrap_or(false) || reveal_all;
                json!({
                    "found": self.found.get(i).copied().unwrap_or(false),
                    "bbox": visible.then(|| c.bbox.json()),
                    "label": visible.then(|| c.label.clone()),
                })
            })
            .collect();
        let phase_len = match self.phase {
            Phase::Countdown => COUNTDOWN_MS,
            Phase::Ready => READY_MS,
            Phase::Reveal => self.reveal_len(),
            _ => 0.0,
        };
        let mut v = json!({
            "status": self.status,
            "stars": self.stars,
            "title": self.title(),
            "goal": self.goal(),
            "level": self.level,
            "phase": self.phase.key(),
            "variant": match self.p.variant { Variant::Flicker => "flicker", Variant::Side => "side" },
            "round": self.round + 1,
            "rounds": self.rounds.len(),
            "found_rounds": self.found_rounds,
            "missed_rounds": self.missed_rounds,
            "wrong": self.wrong,
            "round_wrong": self.round_wrong,
            "max_wrong": MAX_WRONG,
            "t_ms": self.t_ms,
            "round_ms": self.p.round_ms,
            "phase_ms": self.phase_ms,
            "phase_len_ms": phase_len,
            "countdown_ms": if self.phase == Phase::Countdown { (COUNTDOWN_MS - self.phase_ms).max(0.0) } else { 0.0 },
            "show_ms": self.p.show_ms,
            "mask_ms": self.p.mask_ms,
            "frame": self.frame(),
            "tol": self.p.tol,
            "n_changes": r.changes.len(),
            "found_n": self.found.iter().filter(|&&f| f).count(),
            "changes": changes,
            "taps": self.taps.iter().map(|&(x, y, hit)| json!({"x": x, "y": y, "hit": hit})).collect::<Vec<_>>(),
            "result": self.result,
            "scene_no": r.a.no,
        });
        if self.phase == Phase::Done {
            v["summary"] = json!(self.summary());
        }
        if show_scene {
            let key = format!("cs{}-{}-{}", self.level, self.round, r.a.no);
            v["scene_a"] = r.a.json(&format!("{key}a"));
            v["scene_b"] = r.b.json(&format!("{key}b"));
        }
        v
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if self.status != "playing" {
            return Err("Bölüm bitti".into());
        }
        if a["start"].as_bool() == Some(true) {
            if self.phase != Phase::Intro {
                return Err("Zaten başladı".into());
            }
            self.phase = Phase::Countdown;
            self.phase_ms = 0.0;
            return Ok(());
        }
        if a["next"].as_bool() == Some(true) {
            if self.phase != Phase::Reveal {
                return Err("Şimdi değil".into());
            }
            self.after_reveal();
            return Ok(());
        }
        let tap = &a["tap"];
        if tap.is_object() {
            let x = tap["x"].as_f64().ok_or("x eksik")?;
            let y = tap["y"].as_f64().ok_or("y eksik")?;
            return self.tap(x, y);
        }
        Err("Bilinmeyen hamle".into())
    }

    fn tick(&mut self, dt: f64) {
        if self.status != "playing" {
            return;
        }
        match self.phase {
            Phase::Countdown => {
                self.phase_ms += dt;
                if self.phase_ms >= COUNTDOWN_MS {
                    self.phase = Phase::Run;
                    self.phase_ms = 0.0;
                    self.t_ms = 0.0;
                }
            }
            Phase::Ready => {
                self.phase_ms += dt;
                if self.phase_ms >= READY_MS {
                    self.phase = Phase::Run;
                    self.phase_ms = 0.0;
                    self.t_ms = 0.0;
                }
            }
            Phase::Run => {
                self.t_ms += dt;
                if self.t_ms >= self.p.round_ms {
                    self.t_ms = self.p.round_ms;
                    self.end_round("timeout");
                }
            }
            Phase::Reveal => {
                self.phase_ms += dt;
                if self.phase_ms >= self.reveal_len() {
                    self.after_reveal();
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

    fn run_to(g: &mut ChangeSpot, phase: Phase) {
        let mut guard = 0;
        while g.phase != phase && g.status == "playing" {
            g.tick(50.0);
            guard += 1;
            assert!(guard < 100_000);
        }
    }

    fn tap_change(g: &mut ChangeSpot, i: usize) {
        let b = g.cur().changes[i].bbox;
        g.act(&json!({"tap": {"x": b.cx(), "y": b.cy()}})).unwrap();
    }

    /// A point that hits no change (far from every inflated box).
    fn miss_point(g: &ChangeSpot) -> (f64, f64) {
        for gy in 0..16 {
            for gx in 0..20 {
                let (x, y) = (25.0 + gx as f64 * 50.0, 25.0 + gy as f64 * 50.0);
                if g.cur().changes.iter().all(|c| !c.bbox.inflate(g.p.tol + 5.0).contains(x, y)) {
                    return (x, y);
                }
            }
        }
        panic!("no miss point");
    }

    #[test]
    fn change_spot_params_for_levels() {
        for l in LEVELS {
            let p = params(l);
            assert!(p.rounds >= 3 && p.changes >= 1 && p.changes <= 3);
            assert!(p.show_ms >= 400.0 && p.mask_ms >= 120.0);
            assert!(p.tier.0 <= p.tier.1 && p.tier.1 <= 3);
        }
        assert_eq!(params(1).tier, (0, 1));
        assert_eq!(params(500).tier, (2, 3));
        assert_eq!(params(4).variant, Variant::Side);
    }

    #[test]
    fn change_spot_levels_generate_and_are_deterministic() {
        for l in LEVELS {
            let a = ChangeSpot::new(l);
            let b = ChangeSpot::new(l);
            assert_eq!(a.rounds.len(), a.p.rounds, "level {l}");
            assert_eq!(a.state(), b.state());
            for (ra, rb) in a.rounds.iter().zip(&b.rounds) {
                assert_eq!(ra.a, rb.a);
                assert_eq!(ra.b, rb.b);
                assert_eq!(ra.changes, rb.changes);
            }
        }
    }

    #[test]
    fn change_spot_every_change_really_differs_and_has_valid_bbox() {
        for l in (1..=500).step_by(7).chain(LEVELS) {
            let g = ChangeSpot::new(l);
            for r in &g.rounds {
                assert_ne!(r.a, r.b, "level {l}: identical pictures");
                assert_ne!(r.a.json("k"), r.b.json("k"));
                assert_eq!(r.changes.len(), g.p.changes);
                for c in &r.changes {
                    let ia = r.a.get(c.item).map(|i| i.json());
                    let ib = r.b.get(c.item).map(|i| i.json());
                    assert_ne!(ia, ib, "level {l}: change {:?} does not alter its item", c.what);
                    let b = c.bbox;
                    assert!(b.w > 0.0 && b.h > 0.0);
                    assert!(b.x >= 0.0 && b.y >= 0.0 && b.x1() <= W && b.y1() <= H, "bbox outside canvas");
                    assert!(!c.label.is_empty());
                }
                // Only the changed items differ.
                let changed: Vec<u32> = r.changes.iter().map(|c| c.item).collect();
                for it in &r.a.items {
                    if !changed.contains(&it.id) {
                        assert_eq!(Some(it), r.b.get(it.id), "level {l}: unrelated item changed");
                    }
                }
            }
        }
    }

    #[test]
    fn change_spot_tiers_follow_the_curve() {
        let mut early = 0.0;
        let mut late = 0.0;
        let mut n = 0.0;
        for l in 1..=20 {
            for r in ChangeSpot::new(l).rounds {
                early += r.changes.iter().map(|c| c.tier as f64).sum::<f64>() / r.changes.len() as f64;
            }
            for r in ChangeSpot::new(480 + l).rounds {
                late += r.changes.iter().map(|c| c.tier as f64).sum::<f64>() / r.changes.len() as f64;
                n += 1.0;
            }
        }
        assert!(late / n > early / (n * 4.0 / 6.0) + 0.5, "late {late} early {early}");
    }

    #[test]
    fn change_spot_win_with_three_stars() {
        for l in LEVELS {
            let mut g = ChangeSpot::new(l);
            assert!(g.act(&json!({"tap": {"x": 10, "y": 10}})).is_err(), "tap before start");
            g.act(&json!({"start": true})).unwrap();
            for _ in 0..g.rounds.len() {
                run_to(&mut g, Phase::Run);
                for i in 0..g.cur().changes.len() {
                    tap_change(&mut g, i);
                }
                assert_eq!(g.phase, Phase::Reveal);
                g.act(&json!({"next": true})).unwrap();
            }
            assert_eq!(g.status, "won", "level {l}");
            assert_eq!(g.stars, 3);
            assert!(g.state()["summary"].is_string());
        }
    }

    #[test]
    fn change_spot_flicker_alternates_with_mask() {
        let mut g = ChangeSpot::new(1);
        g.act(&json!({"start": true})).unwrap();
        run_to(&mut g, Phase::Run);
        let mut seen = vec![];
        for _ in 0..200 {
            let f = g.frame();
            if seen.last() != Some(&f) {
                seen.push(f);
            }
            g.tick(20.0);
        }
        assert!(seen.starts_with(&["a", "mask", "b", "mask", "a"]), "{seen:?}");
    }

    #[test]
    fn change_spot_wrong_taps_and_timeouts_lose() {
        let mut g = ChangeSpot::new(1);
        g.act(&json!({"start": true})).unwrap();
        run_to(&mut g, Phase::Run);
        // Three wrong taps miss the round.
        for k in 0..MAX_WRONG {
            let (x, y) = miss_point(&g);
            g.act(&json!({"tap": {"x": x, "y": y}})).unwrap();
            assert_eq!(g.round_wrong, k + 1);
        }
        assert_eq!(g.phase, Phase::Reveal);
        assert_eq!(g.missed_rounds, 1);
        assert!(g.state()["changes"][0]["bbox"].is_array(), "revealed");
        g.act(&json!({"next": true})).unwrap();
        // A timeout misses the second round → lost.
        run_to(&mut g, Phase::Run);
        let limit = g.p.round_ms;
        g.tick(limit / 2.0);
        g.tick(limit);
        assert_eq!(g.result, Some("timeout"));
        run_to(&mut g, Phase::Done);
        assert_eq!(g.status, "lost");
        assert_eq!(g.stars, 0);
        assert!(g.act(&json!({"start": true})).is_err());
    }

    #[test]
    fn change_spot_one_miss_is_forgiven() {
        let mut g = ChangeSpot::new(2);
        g.act(&json!({"start": true})).unwrap();
        run_to(&mut g, Phase::Run);
        let limit = g.p.round_ms;
        g.tick(limit);
        assert_eq!(g.missed_rounds, 1);
        for _ in 1..g.rounds.len() {
            run_to(&mut g, Phase::Run);
            for i in 0..g.cur().changes.len() {
                tap_change(&mut g, i);
            }
            g.act(&json!({"next": true})).unwrap();
        }
        assert_eq!(g.status, "won");
        assert!(g.stars <= 2 && g.stars >= 1);
    }

    #[test]
    fn change_spot_illegal_actions_leave_state() {
        let mut g = ChangeSpot::new(3);
        let before = g.state();
        assert!(g.act(&json!({"next": true})).is_err());
        assert!(g.act(&json!({"tap": {"x": 5, "y": 5}})).is_err());
        assert!(g.act(&json!({"foo": 1})).is_err());
        assert_eq!(g.state(), before);
        g.act(&json!({"start": true})).unwrap();
        run_to(&mut g, Phase::Run);
        let before = g.state();
        assert!(g.act(&json!({"tap": {"x": -5, "y": 5}})).is_err());
        assert_eq!(g.state(), before);
    }

    #[test]
    #[ignore]
    fn change_spot_timing() {
        let t0 = std::time::Instant::now();
        let mut worst = 0.0f64;
        for l in 1..=500 {
            let t = std::time::Instant::now();
            let _ = ChangeSpot::new(l);
            worst = worst.max(t.elapsed().as_secs_f64());
        }
        println!("500 levels: {:.2?}, worst {:.1} ms", t0.elapsed(), worst * 1000.0);
    }
}
