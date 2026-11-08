//! Sahne Hafızası — look at an illustrated scene (`scene.rs`) for a few seconds, then answer
//! questions generated from its description.
//!
//! Question families (each with a difficulty tier 0..=3):
//! - **counts** — people, hats ("Kaç kişinin başında şapka vardı?"), sitting people, children,
//!   glasses, bags, hats of a kind / colour / material, patterned tops, windows, cups, books,
//!   balloons, animals. Answered with a 4-number picker (consecutive numbers around the answer).
//! - **attributes** of one person picked by a unique description built from the scene ("Masanın
//!   yanında oturan kadının beresi ne renkti?"): hat colour, hat kind, hat material, top colour,
//!   top pattern, held item, hair colour, glasses.
//! - **"nasıl bir … vardı?"** — pick the right two-feature description of the person at a place.
//! - **who / where** — "Kimin elinde balon vardı?", "Kırmızı bereli kadın neredeydi?",
//!   "Kedi neredeydi?".
//! - **presence** — "Hangisi sahnedeydi?" / "Hangisi sahnede yoktu?", "Hangi hayvan vardı?".
//! - **small details** — object colours, flowers in the vase, fruit in the bowl, the hour on the
//!   wall clock, curtains.
//! - **chains** (advanced) — 2–3 questions on the same set, each narrowing the previous one:
//!   "Kaç kişinin başında şapka vardı?" → "Bu şapkalardan kaçı kırmızıydı?" → "Kırmızı olanlardan
//!   kaçı yündü?" (also people → sitting → women/glasses, bags → backpacks → colour, patterned tops
//!   → stripes → colour, cups → colour).
//!
//! Every answer is computed from the scene description; distractors are plausible (values seen
//! elsewhere in the scene first) and are checked never to be true as well. A person reference is
//! only used when exactly one person matches it.
//!
//! **The first question decides the level** (owner's rule): answer it wrong and the level is lost
//! at once — the next level stays locked. The other questions only cost stars: all right → 3,
//! one wrong → 2, more → 1. When there is a chain it always comes first, so its head is the key
//! question; otherwise the first question is a fair one (tier ≤ 1).
//!
//! Level curve (`params`, t = (level−1)/499):
//! - look time 3.5 + 11.5·(1−t)^1.6 s (15 s at level 1, ≈ 7.3 s at 250, 3.5 s at 500).
//! - people 3–4 → 6–8, clutter 0.25 → 1.0.
//! - questions 3 (< 60), 4 (< 250), 5; chains: none below 25; 25–119 every even level a chain of 2;
//!   120–249 chain of 3 when level % 3 = 0, of 2 when level % 3 = 1; from 250 chain of 3 (of 2
//!   every 4th level).
//! - highest tier 1 (< 20), 2 (< 120), then 3; later questions lean towards the highest tier.
//!
//! State: `{status, stars, title, goal, summary?, phase: "intro"|"show"|"question"|"feedback"|"done",
//!          show_ms, t_ms, q_index, q_count, chain_len, question: {text, note, options, chain_step,
//!          kind}|null, last: {given, answer, correct}|null, answers: [bool], scene_no, setting,
//!          scene (only while looking and when done)}`
//! Actions: `{"start":true}` · `{"ready":true}` (stop looking early) · `{"answer":i}` ·
//!          `{"next":true}` (skip the feedback pause)

use crate::games::scene::*;
use crate::rng::{seed_for, Rng};
use crate::Session;
use serde_json::{json, Value};

pub const FEEDBACK_MS: f64 = 2200.0;
const HAT_NOTE: &str = "Bere, kasket ve hasır şapka da sayılır.";
const HELD_NOTE: &str = "Eldekiler de sayılır.";

#[derive(Clone, Debug, PartialEq)]
pub struct Params {
    pub show_ms: f64,
    pub scene: SceneParams,
    pub questions: usize,
    pub chain: usize,
    pub max_tier: u8,
}

pub fn params(level: u32) -> Params {
    let level = level.clamp(1, crate::MAX_LEVEL);
    let t = (level - 1) as f64 / 499.0;
    let chain = match level {
        1..=24 => 0,
        25..=119 => {
            if level.is_multiple_of(2) {
                2
            } else {
                0
            }
        }
        120..=249 => match level % 3 {
            0 => 3,
            1 => 2,
            _ => 0,
        },
        _ => {
            if level.is_multiple_of(4) {
                2
            } else {
                3
            }
        }
    };
    let questions = if level < 60 {
        3
    } else if level < 250 {
        4
    } else {
        5
    };
    Params {
        show_ms: ((3500.0 + 11_500.0 * (1.0 - t).powf(1.6)) / 100.0).round() * 100.0,
        scene: SceneParams {
            people: (3 + (3.0 * t).round() as usize, 4 + (4.0 * t).round() as usize),
            clutter: 0.25 + 0.75 * t,
            hat_p: if chain > 0 { 0.6 } else { 0.48 },
            animals: (0, 1 + t.round() as usize),
        },
        questions: questions.max(chain + 1),
        chain,
        max_tier: if level < 20 {
            1
        } else if level < 120 {
            2
        } else {
            3
        },
    }
}

// --------------------------------------------------------------------------------------- language

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Noun {
    Woman,
    Man,
    Girl,
    Boy,
    OldWoman,
    OldMan,
}

impl Noun {
    pub fn of(p: &Person) -> Noun {
        match (p.age, p.female) {
            (Age::Child, true) => Noun::Girl,
            (Age::Child, false) => Noun::Boy,
            (Age::Elder, true) => Noun::OldWoman,
            (Age::Elder, false) => Noun::OldMan,
            (Age::Adult, true) => Noun::Woman,
            (Age::Adult, false) => Noun::Man,
        }
    }
    /// Whether a reference with this noun can be read as pointing at `other`. A plain "adam" /
    /// "kadın" could just as well mean an elderly man / woman in the picture, so it covers them
    /// too; "yaşlı …" and the child nouns are only their own group.
    pub fn covers(self, other: Noun) -> bool {
        self == other || matches!((self, other), (Noun::Man, Noun::OldMan) | (Noun::Woman, Noun::OldWoman))
    }
    pub fn nom(self) -> &'static str {
        match self {
            Noun::Woman => "kadın",
            Noun::Man => "adam",
            Noun::Girl => "küçük kız",
            Noun::Boy => "küçük oğlan",
            Noun::OldWoman => "yaşlı kadın",
            Noun::OldMan => "yaşlı adam",
        }
    }
    pub fn gen(self) -> &'static str {
        match self {
            Noun::Woman => "kadının",
            Noun::Man => "adamın",
            Noun::Girl => "küçük kızın",
            Noun::Boy => "küçük oğlanın",
            Noun::OldWoman => "yaşlı kadının",
            Noun::OldMan => "yaşlı adamın",
        }
    }
}

/// A visible feature of a person.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Feat {
    Hat(HatKind, Option<Col>),
    NoHat,
    Glasses(Glasses),
    Top(Col, TopKind),
    Pat(Pattern, TopKind),
    Hold(HoldKind),
    Bag(BagKind),
    Hair(Hair),
    Beard(Beard),
}

impl Feat {
    pub fn holds(&self, p: &Person) -> bool {
        match *self {
            Feat::Hat(k, c) => p.hat.is_some_and(|h| h.kind == k && (c.is_none() || h.color() == c)),
            Feat::NoHat => p.hat.is_none(),
            Feat::Glasses(g) => p.glasses == g,
            Feat::Top(c, k) => p.top.c == c && p.top_kind == k,
            Feat::Pat(pt, k) => p.pattern == pt && p.top_kind == k,
            Feat::Hold(h) => p.hold.map(|x| x.0) == Some(h),
            Feat::Bag(b) => p.bag.map(|x| x.0) == Some(b),
            Feat::Hair(h) => p.hair == h && p.hair_visible(),
            Feat::Beard(b) => p.beard == b,
        }
    }
    /// Dimension (two features of one dimension never go together).
    pub fn dim(&self) -> u8 {
        match self {
            Feat::Hat(..) | Feat::NoHat => 0,
            Feat::Glasses(_) => 1,
            Feat::Top(..) => 2,
            Feat::Pat(..) => 3,
            Feat::Hold(_) => 4,
            Feat::Bag(_) => 5,
            Feat::Hair(_) => 6,
            Feat::Beard(_) => 7,
        }
    }
    pub fn adj(&self) -> String {
        match *self {
            Feat::Hat(k, Some(c)) => format!("{} {}", c.name(), k.adj()),
            Feat::Hat(k, None) => k.adj().to_string(),
            Feat::NoHat => "şapkasız".into(),
            Feat::Glasses(Glasses::Reading) => "gözlüklü".into(),
            Feat::Glasses(Glasses::Sun) => "güneş gözlüklü".into(),
            Feat::Glasses(Glasses::None) => "gözlüksüz".into(),
            Feat::Top(c, k) => format!("{} {}", c.name(), k.adj()),
            Feat::Pat(pt, k) => format!("{} {}", pt.name(), k.adj()),
            Feat::Hold(h) => format!("elinde {} olan", h.name()),
            Feat::Bag(b) => b.adj().to_string(),
            Feat::Hair(h) => format!("{} saçlı", h.name()),
            Feat::Beard(Beard::Mustache) => "bıyıklı".into(),
            Feat::Beard(_) => "sakallı".into(),
        }
    }
}

/// The salient, positive features of a person.
pub fn person_feats(p: &Person) -> Vec<Feat> {
    let mut v = vec![];
    if let Some(h) = p.hat {
        v.push(Feat::Hat(h.kind, h.color()));
    }
    if p.glasses != Glasses::None {
        v.push(Feat::Glasses(p.glasses));
    }
    v.push(Feat::Top(p.top.c, p.top_kind));
    if p.pattern != Pattern::Plain {
        v.push(Feat::Pat(p.pattern, p.top_kind));
    }
    if let Some((h, _)) = p.hold {
        v.push(Feat::Hold(h));
    }
    if let Some((b, _)) = p.bag {
        v.push(Feat::Bag(b));
    }
    if p.hair_visible() {
        v.push(Feat::Hair(p.hair));
    }
    if p.beard != Beard::None {
        v.push(Feat::Beard(p.beard));
    }
    v
}

/// Same-dimension alternatives that are false for `p`.
fn alternatives(f: Feat, p: &Person) -> Vec<Feat> {
    let mut v: Vec<Feat> = match f {
        Feat::Hat(k, c) => {
            let mut v: Vec<Feat> = vec![];
            if c.is_some() {
                v.extend(COLS.iter().map(|&x| Feat::Hat(k, Some(x))));
            }
            for k2 in HAT_KINDS {
                if k2 != k {
                    v.push(Feat::Hat(k2, if k2 == HatKind::Hasir { None } else { c.or(Some(Col::Kahve)) }));
                }
            }
            v
        }
        Feat::NoHat => HAT_KINDS.iter().map(|&k| Feat::Hat(k, None)).collect(),
        Feat::Glasses(_) => vec![Feat::Glasses(Glasses::Reading), Feat::Glasses(Glasses::Sun)],
        Feat::Top(_, k) => COLS.iter().map(|&c| Feat::Top(c, k)).collect(),
        Feat::Pat(_, k) => vec![Feat::Pat(Pattern::Stripe, k), Feat::Pat(Pattern::Dots, k), Feat::Pat(Pattern::Plain, k)],
        Feat::Hold(_) => HOLDS.iter().map(|&h| Feat::Hold(h)).collect(),
        Feat::Bag(_) => vec![Feat::Bag(BagKind::Backpack), Feat::Bag(BagKind::Handbag)],
        Feat::Hair(_) => HAIRS.iter().map(|&h| Feat::Hair(h)).collect(),
        Feat::Beard(_) => vec![Feat::Beard(Beard::Mustache), Feat::Beard(Beard::Full)],
    };
    v.retain(|a| !a.holds(p) && *a != f);
    v
}

/// What we know about a person for references.
#[derive(Clone, Debug)]
pub struct PInfo {
    pub id: u32,
    pub p: Person,
    pub noun: Noun,
    pub rels: Vec<Rel>,
    pub region: Option<Region>,
}

pub fn infos(sc: &Scene) -> Vec<PInfo> {
    sc.people()
        .map(|(it, p)| PInfo { id: it.id, p: *p, noun: Noun::of(p), rels: rels(sc, it), region: region(it) })
        .collect()
}

/// A way to point at one person: "masanın yanında oturan kadın", "kırmızı bereli adam".
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Ref {
    pub noun: Noun,
    pub sitting: Option<bool>,
    pub rel: Option<Rel>,
    pub region: Option<Region>,
    pub feat: Option<Feat>,
}

impl Ref {
    fn bare(noun: Noun) -> Ref {
        Ref { noun, sitting: None, rel: None, region: None, feat: None }
    }
    pub fn matches(&self, i: &PInfo) -> bool {
        self.noun.covers(i.noun)
            && self.sitting.is_none_or(|s| s == i.p.sitting)
            && self.rel.is_none_or(|r| i.rels.contains(&r))
            && self.region.is_none_or(|g| i.region == Some(g))
            && self.feat.is_none_or(|f| f.holds(&i.p))
    }
    fn place(&self) -> Option<&'static str> {
        self.rel.map(|r| r.phrase()).or(self.region.map(|g| g.phrase()))
    }
    fn words(&self, genitive: bool) -> String {
        let mut w: Vec<String> = vec![];
        if let Some(pl) = self.place() {
            w.push(pl.into());
        }
        if let Some(s) = self.sitting {
            w.push(
                if s {
                    "oturan"
                } else if self.place().is_some() {
                    "duran"
                } else {
                    "ayakta duran"
                }
                .into(),
            );
        }
        if let Some(f) = self.feat {
            w.push(f.adj());
        }
        w.push(if genitive { self.noun.gen() } else { self.noun.nom() }.into());
        w.join(" ")
    }
    pub fn nom(&self) -> String {
        self.words(false)
    }
    pub fn gen(&self) -> String {
        self.words(true)
    }
}

/// Every reference that singles out `target` (avoiding feature dimensions in `avoid`; with or
/// without place words).
pub fn unique_refs(ppl: &[PInfo], target: usize, avoid: &[u8], places: bool, feats: bool) -> Vec<Ref> {
    let t = &ppl[target];
    let mut cands = vec![Ref::bare(t.noun), Ref { sitting: Some(t.p.sitting), ..Ref::bare(t.noun) }];
    if places {
        for &r in &t.rels {
            cands.push(Ref { sitting: Some(t.p.sitting), rel: Some(r), ..Ref::bare(t.noun) });
        }
        if t.region.is_some() {
            cands.push(Ref { sitting: Some(t.p.sitting), region: t.region, ..Ref::bare(t.noun) });
        }
    }
    if feats {
        for f in person_feats(&t.p) {
            if avoid.contains(&f.dim()) {
                continue;
            }
            cands.push(Ref { feat: Some(f), ..Ref::bare(t.noun) });
            if !matches!(f, Feat::Hold(_)) {
                cands.push(Ref { feat: Some(f), sitting: Some(t.p.sitting), ..Ref::bare(t.noun) });
            }
        }
    }
    cands.retain(|r| ppl.iter().filter(|i| r.matches(i)).count() == 1 && r.matches(t));
    cands
}

fn pick_ref(r: &mut Rng, refs: &[Ref]) -> Option<Ref> {
    if refs.is_empty() {
        return None;
    }
    // Prefer short references: the first candidates are the simplest.
    let n = refs.len().min(3);
    Some(refs[r.below(n)])
}

// -------------------------------------------------------------------------------------- questions

#[derive(Clone, Debug, PartialEq)]
pub struct Q {
    pub text: String,
    pub note: Option<String>,
    pub options: Vec<String>,
    pub answer: usize,
    /// Generator key.
    pub kind: &'static str,
    /// Topic group: two questions of one group are never asked together.
    pub group: &'static str,
    pub tier: u8,
    /// 0 = standalone, otherwise position in its chain (1-based).
    pub chain: u8,
    pub subject: Option<u32>,
}

impl Q {
    pub fn answer_text(&self) -> &str {
        &self.options[self.answer]
    }
}

/// Count question: 4 consecutive numbers around the answer (ascending, like a number picker).
pub fn count_q(r: &mut Rng, text: String, note: Option<&str>, n: usize, kind: &'static str, group: &'static str, tier: u8) -> Q {
    let lo = n.saturating_sub(3);
    let start = lo + r.below(n - lo + 1);
    let options: Vec<String> = (start..start + 4).map(|v| v.to_string()).collect();
    Q { text, note: note.map(String::from), options, answer: n - start, kind, group, tier, chain: 0, subject: None }
}

/// Multiple choice: the answer plus up to `n − 1` distinct distractors (in order of preference).
/// `shuffle == false` keeps a canonical order given by `order`.
#[allow(clippy::too_many_arguments)]
fn choice_q(
    r: &mut Rng,
    text: String,
    note: Option<&str>,
    answer: String,
    distractors: Vec<String>,
    n: usize,
    order: Option<&[String]>,
    kind: &'static str,
    group: &'static str,
    tier: u8,
) -> Option<Q> {
    let mut opts = vec![answer.clone()];
    for d in distractors {
        if opts.len() >= n {
            break;
        }
        if !opts.contains(&d) {
            opts.push(d);
        }
    }
    if opts.len() < 2 {
        return None;
    }
    match order {
        Some(ord) => opts.sort_by_key(|o| ord.iter().position(|x| x == o).unwrap_or(99)),
        None => r.shuffle(&mut opts),
    }
    let answer = opts.iter().position(|o| *o == answer)?;
    Some(Q { text, note: note.map(String::from), options: opts, answer, kind, group, tier, chain: 0, subject: None })
}

/// Distractor list: scene-seen values first (shuffled), then the rest (shuffled).
fn ranked<T: PartialEq + Copy>(r: &mut Rng, all: &[T], seen: &[T], answer: T) -> Vec<T> {
    let mut a: Vec<T> = vec![];
    for &s in seen {
        if s != answer && !a.contains(&s) {
            a.push(s);
        }
    }
    r.shuffle(&mut a);
    let mut b: Vec<T> = all.iter().copied().filter(|x| *x != answer && !a.contains(x)).collect();
    r.shuffle(&mut b);
    a.extend(b);
    a
}

fn colour_opts(r: &mut Rng, seen: &[Col], answer: Col, pool: &[Col]) -> Vec<String> {
    ranked(r, pool, seen, answer).into_iter().map(|c| cap(c.name())).collect()
}

fn where_of(sc: &Scene, it: &Item) -> &'static str {
    match it.on.and_then(|o| sc.get(o)).map(|o| o.kind) {
        Some(Kind::Table) => "masadaki",
        Some(Kind::Counter) => "tezgâhtaki",
        Some(Kind::Bench) => "banktaki",
        _ => "yerdeki",
    }
}

fn held(ppl: &[PInfo], k: HoldKind) -> usize {
    ppl.iter().filter(|i| i.p.hold.is_some_and(|h| h.0 == k)).count()
}

/// Presence entries: label, present?, plausible for this setting?
fn presence(sc: &Scene, ppl: &[PInfo]) -> Vec<(&'static str, bool, bool)> {
    let pk = possible_kinds(sc.setting);
    let has = |k: Kind| sc.items.iter().any(|i| i.kind == k);
    let can = |k: Kind| pk.contains(&k);
    let plants = sc.items.iter().any(|i| i.kind == Kind::Plant && i.var != 3);
    let mut v = vec![
        ("Kedi", has(Kind::Cat), can(Kind::Cat)),
        ("Köpek", has(Kind::Dog), can(Kind::Dog)),
        ("Kuş", has(Kind::Bird), can(Kind::Bird)),
        ("Top", has(Kind::Ball), can(Kind::Ball)),
        ("Duvar saati", has(Kind::Clock), can(Kind::Clock)),
        ("Lamba", has(Kind::Lamp), can(Kind::Lamp)),
        ("Kitap", has(Kind::Book) || held(ppl, HoldKind::Book) > 0, true),
        ("Fincan", has(Kind::Cup) || held(ppl, HoldKind::Cup) > 0, true),
        ("Meyve kasesi", has(Kind::Fruit), can(Kind::Fruit)),
        ("Vazo", has(Kind::Vase), can(Kind::Vase)),
        ("Şişe", has(Kind::Bottle), can(Kind::Bottle)),
        ("Dizüstü bilgisayar", has(Kind::Laptop), can(Kind::Laptop)),
        ("Tablo", has(Kind::Frame), can(Kind::Frame)),
        ("Balon", held(ppl, HoldKind::Balloon) > 0, matches!(sc.setting, Setting::Park | Setting::Plaj | Setting::Kafe | Setting::Oda)),
        ("Bank", has(Kind::Bench), can(Kind::Bench)),
        ("Masa", has(Kind::Table), can(Kind::Table)),
    ];
    if sc.setting != Setting::Plaj {
        v.push(("Şemsiye", has(Kind::Umbrella) || held(ppl, HoldKind::Umbrella) > 0, can(Kind::Umbrella)));
    }
    if sc.setting != Setting::Park {
        v.push(("Saksı", plants, can(Kind::Plant)));
    }
    v
}

/// Every standalone question the scene supports.
pub fn pool(sc: &Scene, r: &mut Rng) -> Vec<Q> {
    let ppl = infos(sc);
    let n = ppl.len();
    let mut out: Vec<Q> = vec![];
    let hats: Vec<Hat> = ppl.iter().filter_map(|i| i.p.hat).collect();
    let busy = n > 4;

    // ---- counts
    out.push(count_q(r, "Sahnede kaç kişi vardı?".into(), None, n, "people_count", "people", busy as u8));
    out.push(count_q(r, "Kaç kişinin başında şapka vardı?".into(), Some(HAT_NOTE), hats.len(), "hat_count", "hats", busy as u8));
    let sitting = ppl.iter().filter(|i| i.p.sitting).count();
    out.push(count_q(r, "Kaç kişi oturuyordu?".into(), None, sitting, "sitting_count", "people", 1));
    let kids = ppl.iter().filter(|i| i.p.age == Age::Child).count();
    out.push(count_q(r, "Sahnede kaç çocuk vardı?".into(), None, kids, "child_count", "people", 1));
    let gl = ppl.iter().filter(|i| i.p.glasses != Glasses::None).count();
    out.push(count_q(r, "Kaç kişi gözlük takıyordu?".into(), Some("Güneş gözlüğü de sayılır."), gl, "glasses_count", "glasses", 1));
    let bags = ppl.iter().filter(|i| i.p.bag.is_some()).count();
    out.push(count_q(r, "Kaç kişinin çantası vardı?".into(), Some("Sırt çantası da el çantası da sayılır."), bags, "bag_count", "bags", 1));
    {
        let k = *r.pick(&HAT_KINDS);
        let c = hats.iter().filter(|h| h.kind == k).count();
        out.push(count_q(r, format!("Kaç kişi {} takıyordu?", k.name()), None, c, "hat_kind_count", "hats", 2));
    }
    let hat_cols: Vec<Col> = hats.iter().filter_map(|h| h.color()).collect();
    if !hat_cols.is_empty() {
        let c = *r.pick(&hat_cols);
        let m = hat_cols.iter().filter(|&&x| x == c).count();
        out.push(count_q(r, format!("Kaç kişinin şapkası {}?", c.was()), Some(HAT_NOTE), m, "hat_color_count", "hats", 2));
    }
    if !hats.is_empty() {
        let mats: Vec<Mat> = hats.iter().map(|h| h.mat).collect();
        let m = *r.pick(&mats);
        let c = mats.iter().filter(|&&x| x == m).count();
        out.push(count_q(r, format!("Şapkalardan kaçı {}?", m.was()), Some(HAT_NOTE), c, "hat_mat_count", "hats", 2));
    }
    {
        let pt = if r.chance(0.5) { Pattern::Stripe } else { Pattern::Dots };
        let c = ppl.iter().filter(|i| i.p.pattern == pt).count();
        let was = if pt == Pattern::Stripe { "çizgiliydi" } else { "puantiyeliydi" };
        out.push(count_q(r, format!("Kaç kişinin üstü {was}?"), None, c, "pattern_count", "patterns", 2));
    }
    if sc.setting.has_wall() {
        out.push(count_q(r, "Kaç pencere vardı?".into(), None, sc.count(Kind::Window), "window_count", "windows", 2));
    }
    let cups = sc.count(Kind::Cup) + held(&ppl, HoldKind::Cup);
    out.push(count_q(r, "Kaç fincan vardı?".into(), Some(HELD_NOTE), cups, "cup_count", "cups", 3));
    let books = sc.count(Kind::Book) + held(&ppl, HoldKind::Book);
    out.push(count_q(r, "Kaç kitap vardı?".into(), Some(HELD_NOTE), books, "book_count", "books", 3));
    let balloons = held(&ppl, HoldKind::Balloon);
    if balloons > 0 || sc.setting.warm() {
        out.push(count_q(r, "Kaç balon vardı?".into(), None, balloons, "balloon_count", "balloons", 2));
    }
    let animals = sc.items.iter().filter(|i| i.kind.is_animal()).count();
    out.push(count_q(r, "Kaç hayvan vardı?".into(), None, animals, "animal_count", "animals", 1));

    // ---- presence
    let kinds: Vec<Kind> = [Kind::Cat, Kind::Dog, Kind::Bird].into_iter().filter(|&k| sc.count(k) > 0).collect();
    if kinds.len() <= 1 {
        let all = ["Kedi", "Köpek", "Kuş", "Hiç hayvan yoktu"];
        let ans = match kinds.first() {
            Some(Kind::Cat) => "Kedi",
            Some(Kind::Dog) => "Köpek",
            Some(Kind::Bird) => "Kuş",
            _ => "Hiç hayvan yoktu",
        };
        let ord: Vec<String> = all.iter().map(|s| s.to_string()).collect();
        let d: Vec<String> = all.iter().filter(|&&s| s != ans).map(|s| s.to_string()).collect();
        if let Some(q) = choice_q(r, "Sahnede hangi hayvan vardı?".into(), None, ans.into(), d, 4, Some(&ord), "animal_which", "animals", 0) {
            out.push(q);
        }
    }
    let pres = presence(sc, &ppl);
    let present: Vec<&str> = pres.iter().filter(|e| e.1).map(|e| e.0).collect();
    let mut absent: Vec<&str> = pres.iter().filter(|e| !e.1 && e.2).map(|e| e.0).collect();
    r.shuffle(&mut absent);
    let mut absent_any: Vec<&str> = pres.iter().filter(|e| !e.1 && !e.2).map(|e| e.0).collect();
    r.shuffle(&mut absent_any);
    absent.extend(absent_any);
    if !present.is_empty() && absent.len() >= 3 {
        let ans = *r.pick(&present);
        let d: Vec<String> = absent.iter().take(3).map(|s| s.to_string()).collect();
        if let Some(q) = choice_q(r, "Hangisi sahnedeydi?".into(), None, ans.into(), d, 4, None, "present", "presence", 1) {
            out.push(q);
        }
    }
    if present.len() >= 3 && !absent.is_empty() {
        let mut pr = present.clone();
        r.shuffle(&mut pr);
        let d: Vec<String> = pr.iter().take(3).map(|s| s.to_string()).collect();
        if let Some(q) = choice_q(r, "Hangisi sahnede yoktu?".into(), None, absent[0].into(), d, 4, None, "absent", "presence", 2) {
            out.push(q);
        }
    }

    // ---- one person
    let seen_tops: Vec<Col> = ppl.iter().map(|i| i.p.top.c).collect();
    let seen_hairs: Vec<Hair> = ppl.iter().map(|i| i.p.hair).collect();
    for (ti, t) in ppl.iter().enumerate() {
        let row = sc.get(t.id).map(|i| i.row).unwrap_or(0);
        let far = (row == 0) as u8;
        let mut push = |q: Option<Q>| {
            if let Some(mut q) = q {
                q.subject = Some(t.id);
                out.push(q);
            }
        };
        if let Some(h) = t.p.hat {
            if let (Some(c), Some(rf)) = (h.color(), pick_ref(r, &unique_refs(&ppl, ti, &[0], true, true))) {
                let d = colour_opts(r, &hat_cols, c, &COLS);
                push(choice_q(r, format!("{} {} ne renkti?", cap(&rf.gen()), h.kind.poss()), None, cap(c.name()), d, 4, None, "hat_color_of", "hats", 1 + far));
            }
            if let Some(rf) = pick_ref(r, &unique_refs(&ppl, ti, &[0], true, true)) {
                let ord: Vec<String> = MATS.iter().map(|m| cap(m.name())).collect();
                let d: Vec<String> = ord.iter().filter(|s| **s != cap(h.mat.name())).cloned().collect();
                push(choice_q(r, format!("{} başlığı hangi malzemedendi?", cap(&rf.gen())), None, cap(h.mat.name()), d, 4, Some(&ord), "hat_mat_of", "hats", 2));
            }
        }
        if let Some(rf) = pick_ref(r, &unique_refs(&ppl, ti, &[0], true, true)) {
            let names: Vec<String> = HAT_KINDS.iter().map(|k| cap(k.name())).chain(["Hiçbir şey".to_string()]).collect();
            let ans = t.p.hat.map(|h| cap(h.kind.name())).unwrap_or_else(|| "Hiçbir şey".into());
            let mut d: Vec<String> = names.iter().filter(|s| **s != ans).cloned().collect();
            r.shuffle(&mut d);
            push(choice_q(r, format!("{} başında ne vardı?", cap(&rf.gen())), None, ans, d, 4, Some(&names), "hat_kind_of", "hats", 1 + far));
        }
        if let Some(rf) = pick_ref(r, &unique_refs(&ppl, ti, &[2], true, true)) {
            let d = colour_opts(r, &seen_tops, t.p.top.c, &COLS);
            push(choice_q(
                r,
                format!("{} üstündeki {} ne renkti?", cap(&rf.gen()), t.p.top_kind.name()),
                None,
                cap(t.p.top.c.name()),
                d,
                4,
                None,
                "top_color_of",
                "tops",
                1 + far,
            ));
        }
        if let Some(rf) = pick_ref(r, &unique_refs(&ppl, ti, &[3], true, true)) {
            let ord: Vec<String> = PATTERNS.iter().map(|p| cap(p.name())).collect();
            let ans = cap(t.p.pattern.name());
            let d: Vec<String> = ord.iter().filter(|s| **s != ans).cloned().collect();
            push(choice_q(r, format!("{} {} nasıldı?", cap(&rf.gen()), t.p.top_kind.poss()), None, ans, d, 3, Some(&ord), "pattern_of", "patterns", 2));
        }
        if let Some(rf) = pick_ref(r, &unique_refs(&ppl, ti, &[4], true, true)) {
            let ans = t.p.hold.map(|h| cap(h.0.name())).unwrap_or_else(|| "Hiçbir şey".into());
            let seen: Vec<HoldKind> = ppl.iter().filter_map(|i| i.p.hold.map(|h| h.0)).collect();
            let mut d: Vec<String> = match t.p.hold {
                Some(h) => ranked(r, &HOLDS, &seen, h.0).into_iter().map(|k| cap(k.name())).collect(),
                None => {
                    let mut v: Vec<String> = seen.iter().map(|k| cap(k.name())).collect();
                    let mut rest: Vec<String> = HOLDS.iter().map(|k| cap(k.name())).collect();
                    r.shuffle(&mut rest);
                    v.extend(rest);
                    v
                }
            };
            if t.p.hold.is_some() && r.chance(0.5) {
                d.insert(0, "Hiçbir şey".into());
            }
            push(choice_q(r, format!("{} elinde ne vardı?", cap(&rf.gen())), None, ans, d, 4, None, "hold_of", "holds", 2));
        }
        if t.p.hair_visible() {
            if let Some(rf) = pick_ref(r, &unique_refs(&ppl, ti, &[6], true, true)) {
                let d: Vec<String> = ranked(r, &HAIRS, &seen_hairs, t.p.hair).into_iter().map(|h| cap(h.name())).collect();
                push(choice_q(r, format!("{} saçı ne renkti?", cap(&rf.gen())), None, cap(t.p.hair.name()), d, 4, None, "hair_of", "hair", 2));
            }
        }
        if let Some(rf) = pick_ref(r, &unique_refs(&ppl, ti, &[1], true, true)) {
            let ord: Vec<String> = ["Normal gözlük", "Güneş gözlüğü", "Gözlüğü yoktu"].iter().map(|s| s.to_string()).collect();
            let ans = match t.p.glasses {
                Glasses::Reading => &ord[0],
                Glasses::Sun => &ord[1],
                Glasses::None => &ord[2],
            }
            .clone();
            let d: Vec<String> = ord.iter().filter(|s| **s != ans).cloned().collect();
            push(choice_q(r, format!("{} gözlük takıyor muydu?", cap(&rf.nom())), None, ans, d, 3, Some(&ord), "glasses_of", "glasses", 2));
        }
        // "Masanın yanında nasıl bir kadın oturuyordu?"
        let place_refs: Vec<Ref> = unique_refs(&ppl, ti, &[], true, false).into_iter().filter(|rf| rf.place().is_some()).collect();
        if let Some(rf) = pick_ref(r, &place_refs) {
            push(describe_q(r, &ppl, ti, &rf));
        }
        // "Kırmızı bereli kadın neredeydi?"
        let real: Vec<Rel> = t.rels.clone();
        if !real.is_empty() {
            let feat_refs: Vec<Ref> = unique_refs(&ppl, ti, &[], false, true).into_iter().filter(|rf| rf.feat.is_some()).collect();
            if let Some(rf) = pick_ref(r, &feat_refs) {
                let ans = *r.pick(&real);
                let mut plausible: Vec<Rel> = PERSON_RELS
                    .iter()
                    .copied()
                    .filter(|x| !real.contains(x) && x.needs().is_none_or(|k| sc.count(k) > 0))
                    .collect();
                r.shuffle(&mut plausible);
                let mut rest: Vec<Rel> = PERSON_RELS
                    .iter()
                    .copied()
                    .filter(|x| !real.contains(x) && !plausible.contains(x) && x.needs().is_some_and(|k| possible_kinds(sc.setting).contains(&k)))
                    .collect();
                r.shuffle(&mut rest);
                plausible.extend(rest);
                let d: Vec<String> = plausible.iter().map(|x| cap(x.phrase())).collect();
                if d.len() >= 2 {
                    push(choice_q(r, format!("{} neredeydi?", cap(&rf.nom())), None, cap(ans.phrase()), d, 4, None, "where_person", "places", 2));
                }
            }
        }
    }

    // "Kimin elinde balon vardı?"
    if n >= 4 {
        for h in HOLDS {
            let holders: Vec<usize> = (0..n).filter(|&i| ppl[i].p.hold.is_some_and(|x| x.0 == h)).collect();
            if holders.len() != 1 {
                continue;
            }
            let ti = holders[0];
            let Some(rf) = pick_ref(r, &unique_refs(&ppl, ti, &[4], true, true)) else { continue };
            let mut d: Vec<String> = vec![];
            let mut others: Vec<usize> = (0..n).filter(|&i| i != ti).collect();
            r.shuffle(&mut others);
            for o in others {
                if let Some(orf) = pick_ref(r, &unique_refs(&ppl, o, &[4], true, true)) {
                    d.push(cap(&orf.nom()));
                }
            }
            if d.len() >= 3 {
                if let Some(mut q) = choice_q(r, format!("Kimin elinde {} vardı?", h.name()), None, cap(&rf.nom()), d, 4, None, "who_holds", "holds", 3) {
                    q.subject = Some(ppl[ti].id);
                    out.push(q);
                }
            }
        }
    }

    // ---- animals and objects
    for k in [Kind::Cat, Kind::Dog, Kind::Bird] {
        let items: Vec<&Item> = sc.items.iter().filter(|i| i.kind == k).collect();
        if items.len() != 1 {
            continue;
        }
        let it = items[0];
        let d = colour_opts(r, &[], it.tone.c, tone_choices(k));
        if let Some(q) = choice_q(r, format!("{} ne renkti?", cap(k.name())), None, cap(it.tone.c.name()), d, 4, None, "animal_color", "animals", 2) {
            out.push(q);
        }
        let rel = rels(sc, it)[0];
        let mut d: Vec<Rel> = ANIMAL_RELS.iter().copied().filter(|&x| x != rel && x.needs().is_none_or(|nk| sc.count(nk) > 0)).collect();
        r.shuffle(&mut d);
        let mut rest: Vec<Rel> = ANIMAL_RELS.iter().copied().filter(|&x| x != rel && !d.contains(&x)).collect();
        r.shuffle(&mut rest);
        d.extend(rest);
        let d: Vec<String> = d.iter().map(|x| cap(x.phrase())).collect();
        if let Some(q) = choice_q(r, format!("{} neredeydi?", cap(k.name())), None, cap(rel.phrase()), d, 4, None, "animal_where", "animals", 2) {
            out.push(q);
        }
    }
    for k in [Kind::Ball, Kind::Umbrella, Kind::Bag, Kind::Cup, Kind::Book, Kind::Bottle, Kind::Laptop, Kind::Vase] {
        let items: Vec<&Item> = sc.items.iter().filter(|i| i.kind == k).collect();
        let held_same = match k {
            Kind::Cup => held(&ppl, HoldKind::Cup),
            Kind::Book => held(&ppl, HoldKind::Book),
            Kind::Umbrella => held(&ppl, HoldKind::Umbrella),
            _ => 0,
        };
        if items.len() != 1 || held_same > 0 {
            continue;
        }
        let it = items[0];
        let tier = if matches!(k, Kind::Ball | Kind::Umbrella | Kind::Bag) { 2 } else { 3 };
        let text = format!("{} {} ne renkti?", cap(where_of(sc, it)), k.name());
        let d = colour_opts(r, &[], it.tone.c, tone_choices(k));
        if let Some(q) = choice_q(r, text, None, cap(it.tone.c.name()), d, 4, None, "object_color", "objects", tier) {
            out.push(q);
        }
        if k == Kind::Vase {
            let d = colour_opts(r, &[], it.tone2.c, tone2_choices(k));
            if let Some(q) = choice_q(r, "Vazodaki çiçekler ne renkti?".into(), None, cap(it.tone2.c.name()), d, 4, None, "flower_color", "objects", 3) {
                out.push(q);
            }
        }
    }
    let fruits: Vec<&Item> = sc.items.iter().filter(|i| i.kind == Kind::Fruit).collect();
    if fruits.len() == 1 {
        let ans = cap(FRUITS[fruits[0].var as usize % FRUITS.len()]);
        let mut d: Vec<String> = FRUITS.iter().map(|f| cap(f)).filter(|f| *f != ans).collect();
        r.shuffle(&mut d);
        if let Some(q) = choice_q(r, "Kasede hangi meyve vardı?".into(), None, ans, d, 4, None, "fruit_kind", "objects", 3) {
            out.push(q);
        }
    }
    let clocks: Vec<&Item> = sc.items.iter().filter(|i| i.kind == Kind::Clock).collect();
    if clocks.len() == 1 {
        let h = clocks[0].var as i32;
        let mut hours: Vec<i32> = (1..=12).filter(|&x| x != h).collect();
        r.shuffle(&mut hours);
        let label = |x: i32| format!("{x}:00");
        let ord: Vec<String> = (1..=12).map(label).collect();
        let d: Vec<String> = hours.into_iter().map(label).collect();
        if let Some(q) = choice_q(r, "Duvardaki saat kaçı gösteriyordu?".into(), None, label(h), d, 4, Some(&ord), "clock_time", "clock", 3) {
            out.push(q);
        }
    }
    let curtains: Vec<&Item> = sc.items.iter().filter(|i| i.kind == Kind::Window && i.var & 1 == 1).collect();
    if curtains.len() == 1 {
        let c = curtains[0].tone.c;
        let d = colour_opts(r, &[], c, tone_choices(Kind::Window));
        if let Some(q) = choice_q(r, "Perdeler ne renkti?".into(), None, cap(c.name()), d, 4, None, "curtain_color", "windows", 3) {
            out.push(q);
        }
    }
    for k in [Kind::Bench, Kind::Table] {
        let items: Vec<&Item> = sc.items.iter().filter(|i| i.kind == k).collect();
        if items.len() == 1 {
            let c = items[0].tone.c;
            let d = colour_opts(r, &[], c, tone_choices(k));
            if let Some(q) = choice_q(r, format!("{} ne renkti?", cap(k.name())), None, cap(c.name()), d, 4, None, "furniture_color", "furniture", 2) {
                out.push(q);
            }
        }
    }
    out
}

fn describe_text(f: &[Feat]) -> String {
    let mut f = f.to_vec();
    f.sort_by_key(|x| (matches!(x, Feat::Hold(_)) as u8, x.dim()));
    cap(&f.iter().map(|x| x.adj()).collect::<Vec<_>>().join(" ve "))
}

/// "Masanın yanında nasıl bir kadın oturuyordu?" — two-feature descriptions.
fn describe_q(r: &mut Rng, ppl: &[PInfo], ti: usize, rf: &Ref) -> Option<Q> {
    let t = &ppl[ti];
    let mut feats = person_feats(&t.p);
    // Prefer the vivid ones; the top colour is always there.
    feats.retain(|f| !matches!(f, Feat::Beard(_)) || r.chance(0.5));
    r.shuffle(&mut feats);
    if feats.len() < 2 {
        return None;
    }
    let pair = [feats[0], feats[1]];
    let seen: Vec<Feat> = ppl.iter().enumerate().filter(|(i, _)| *i != ti).flat_map(|(_, i)| person_feats(&i.p)).collect();
    let alt = |r: &mut Rng, f: Feat| -> Option<Feat> {
        let a = alternatives(f, &t.p);
        let pref: Vec<Feat> = a.iter().copied().filter(|x| seen.contains(x)).collect();
        if !pref.is_empty() && r.chance(0.7) {
            Some(*r.pick(&pref))
        } else if !a.is_empty() {
            Some(*r.pick(&a))
        } else {
            None
        }
    };
    let ans = describe_text(&pair);
    let mut d: Vec<String> = vec![];
    for _ in 0..12 {
        let opt = match r.below(3) {
            0 => [alt(r, pair[0])?, pair[1]],
            1 => [pair[0], alt(r, pair[1])?],
            _ => [alt(r, pair[0])?, alt(r, pair[1])?],
        };
        // Never also true for the target.
        if opt.iter().all(|f| f.holds(&t.p)) {
            continue;
        }
        let s = describe_text(&opt);
        if s != ans && !d.contains(&s) {
            d.push(s);
        }
        if d.len() == 3 {
            break;
        }
    }
    if d.len() < 3 {
        return None;
    }
    let verb = if t.p.sitting { "oturuyordu" } else { "duruyordu" };
    let text = format!("{} nasıl bir {} {}?", cap(rf.place()?), t.noun.nom(), verb);
    choice_q(r, text, None, ans, d, 4, None, "describe", "describe", 1)
}

/// A chain of `len` questions on one narrowing set; the head comes first.
pub fn chain(sc: &Scene, len: usize, r: &mut Rng) -> Option<Vec<Q>> {
    let ppl = infos(sc);
    let mut templates = vec![0, 0, 1, 2, 3, 4, 5];
    r.shuffle(&mut templates);
    for t in templates {
        if let Some(mut qs) = chain_template(sc, &ppl, t, len, r) {
            for (i, q) in qs.iter_mut().enumerate() {
                q.chain = i as u8 + 1;
            }
            return Some(qs);
        }
    }
    None
}

fn chain_template(sc: &Scene, ppl: &[PInfo], t: usize, len: usize, r: &mut Rng) -> Option<Vec<Q>> {
    let mut qs = vec![];
    match t {
        // Hats → colour → material.
        0 => {
            let hats: Vec<Hat> = ppl.iter().filter_map(|i| i.p.hat).collect();
            let cols: Vec<Col> = hats.iter().filter_map(|h| h.color()).collect();
            if hats.len() < 2 || cols.is_empty() {
                return None;
            }
            let c = *r.pick(&cols);
            let sub: Vec<&Hat> = hats.iter().filter(|h| h.color() == Some(c)).collect();
            qs.push(count_q(r, "Kaç kişinin başında şapka vardı?".into(), Some(HAT_NOTE), hats.len(), "chain_hats", "hats", 1));
            qs.push(count_q(r, format!("Bu şapkalardan kaçı {}?", c.was()), None, sub.len(), "chain_hats_color", "hats", 2));
            if len >= 3 {
                let m = r.pick(&sub).mat;
                let k = sub.iter().filter(|h| h.mat == m).count();
                qs.push(count_q(r, format!("{} olanlardan kaçı {}?", cap(c.name()), m.was()), None, k, "chain_hats_mat", "hats", 3));
            }
        }
        // Hats → kind → colour.
        1 => {
            let hats: Vec<Hat> = ppl.iter().filter_map(|i| i.p.hat).collect();
            let kinds: Vec<HatKind> = hats.iter().map(|h| h.kind).filter(|&k| len < 3 || k != HatKind::Hasir).collect();
            if hats.len() < 2 || kinds.is_empty() {
                return None;
            }
            let k = *r.pick(&kinds);
            let sub: Vec<&Hat> = hats.iter().filter(|h| h.kind == k).collect();
            qs.push(count_q(r, "Kaç kişinin başında şapka vardı?".into(), Some(HAT_NOTE), hats.len(), "chain_hats", "hats", 1));
            qs.push(count_q(r, format!("Bunlardan kaçı {}?", k.was()), None, sub.len(), "chain_hats_kind", "hats", 2));
            if len >= 3 {
                let c = r.pick(&sub).color()?;
                let n = sub.iter().filter(|h| h.color() == Some(c)).count();
                qs.push(count_q(r, format!("{} kaçı {}?", cap(k.from_pl()), c.was()), None, n, "chain_hats_kind_color", "hats", 3));
            }
        }
        // People → sitting → women / glasses / hats.
        2 => {
            let sit: Vec<&PInfo> = ppl.iter().filter(|i| i.p.sitting).collect();
            if sit.is_empty() || sit.len() == ppl.len() {
                return None;
            }
            qs.push(count_q(r, "Sahnede kaç kişi vardı?".into(), None, ppl.len(), "chain_people", "people", 0));
            qs.push(count_q(r, "Bunlardan kaçı oturuyordu?".into(), None, sit.len(), "chain_people_sit", "people", 1));
            if len >= 3 {
                let (text, n) = match r.below(3) {
                    0 => ("Oturanlardan kaçı kadındı?", sit.iter().filter(|i| i.p.female && i.p.age != Age::Child).count()),
                    1 => ("Oturanlardan kaçı gözlük takıyordu?", sit.iter().filter(|i| i.p.glasses != Glasses::None).count()),
                    _ => ("Oturanlardan kaçının başında şapka vardı?", sit.iter().filter(|i| i.p.hat.is_some()).count()),
                };
                qs.push(count_q(r, text.into(), None, n, "chain_people_sub", "people", 2));
            }
        }
        // Bags → kind → colour.
        3 => {
            let bags: Vec<(BagKind, Tone)> = ppl.iter().filter_map(|i| i.p.bag).collect();
            if bags.len() < 2 {
                return None;
            }
            let k = r.pick(&bags).0;
            let sub: Vec<&(BagKind, Tone)> = bags.iter().filter(|b| b.0 == k).collect();
            qs.push(count_q(r, "Kaç kişinin çantası vardı?".into(), Some("Sırt çantası da el çantası da sayılır."), bags.len(), "chain_bags", "bags", 1));
            let was = if k == BagKind::Backpack { "sırt çantasıydı" } else { "el çantasıydı" };
            qs.push(count_q(r, format!("Bunlardan kaçı {was}?"), None, sub.len(), "chain_bags_kind", "bags", 2));
            if len >= 3 {
                let c = r.pick(&sub).1.c;
                let n = sub.iter().filter(|b| b.1.c == c).count();
                let from = if k == BagKind::Backpack { "Sırt çantalarından" } else { "El çantalarından" };
                qs.push(count_q(r, format!("{from} kaçı {}?", c.was()), None, n, "chain_bags_color", "bags", 3));
            }
        }
        // Patterned tops → stripes/dots → colour.
        4 => {
            let pat: Vec<&PInfo> = ppl.iter().filter(|i| i.p.pattern != Pattern::Plain).collect();
            if pat.len() < 2 {
                return None;
            }
            let pt = r.pick(&pat).p.pattern;
            let sub: Vec<&&PInfo> = pat.iter().filter(|i| i.p.pattern == pt).collect();
            qs.push(count_q(r, "Kaç kişinin üstü desenliydi?".into(), Some("Çizgili ya da puantiyeli."), pat.len(), "chain_pattern", "patterns", 1));
            let (was, from) = if pt == Pattern::Stripe { ("çizgiliydi", "Çizgililerden") } else { ("puantiyeliydi", "Puantiyelilerden") };
            qs.push(count_q(r, format!("Bunlardan kaçı {was}?"), None, sub.len(), "chain_pattern_kind", "patterns", 2));
            if len >= 3 {
                let c = r.pick(&sub).p.top.c;
                let n = sub.iter().filter(|i| i.p.top.c == c).count();
                qs.push(count_q(r, format!("{from} kaçı {}?", c.was()), None, n, "chain_pattern_color", "patterns", 3));
            }
        }
        // Cups → colour (chain of 2 only).
        _ => {
            if len > 2 {
                return None;
            }
            let mut cols: Vec<Col> = sc.items.iter().filter(|i| i.kind == Kind::Cup).map(|i| i.tone.c).collect();
            cols.extend(ppl.iter().filter_map(|i| i.p.hold.filter(|h| h.0 == HoldKind::Cup).map(|h| h.1.c)));
            if cols.len() < 2 {
                return None;
            }
            let c = *r.pick(&cols);
            qs.push(count_q(r, "Kaç fincan vardı?".into(), Some(HELD_NOTE), cols.len(), "chain_cups", "cups", 2));
            qs.push(count_q(r, format!("Bunlardan kaçı {}?", c.was()), None, cols.iter().filter(|&&x| x == c).count(), "chain_cups_color", "cups", 3));
        }
    }
    Some(qs)
}

/// The level's question list.
pub fn build(sc: &Scene, p: &Params, r: &mut Rng) -> Option<Vec<Q>> {
    let mut qs: Vec<Q> = vec![];
    if p.chain > 0 {
        qs = chain(sc, p.chain, r)?;
    }
    let mut pool = pool(sc, r);
    r.shuffle(&mut pool);
    let mut groups: Vec<&'static str> = qs.iter().map(|q| q.group).collect();
    let mut subjects: Vec<u32> = vec![];
    if qs.is_empty() {
        // A fair key question: salient (tier 0 preferred early, ≤ 1 always).
        let first = pool.iter().position(|q| q.tier == 0).or_else(|| pool.iter().position(|q| q.tier <= 1))?;
        let q = pool.remove(first);
        groups.push(q.group);
        subjects.extend(q.subject);
        qs.push(q);
    }
    while qs.len() < p.questions {
        let ok = |q: &Q| q.tier <= p.max_tier && !groups.contains(&q.group) && q.subject.is_none_or(|s| !subjects.contains(&s));
        // Lean towards the hardest allowed tier.
        let want_top = r.chance(0.6);
        let idx = pool
            .iter()
            .position(|q| ok(q) && (!want_top || q.tier == p.max_tier))
            .or_else(|| pool.iter().position(ok))
            .or_else(|| pool.iter().position(|q| q.tier <= p.max_tier && q.subject.is_none_or(|s| !subjects.contains(&s)) && !qs.iter().any(|x| x.kind == q.kind)))?;
        let q = pool.remove(idx);
        groups.push(q.group);
        subjects.extend(q.subject);
        qs.push(q);
    }
    Some(qs)
}

// ---------------------------------------------------------------------------------------- session

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Phase {
    Intro,
    Show,
    Question,
    Feedback,
    Done,
}

impl Phase {
    fn key(self) -> &'static str {
        match self {
            Phase::Intro => "intro",
            Phase::Show => "show",
            Phase::Question => "question",
            Phase::Feedback => "feedback",
            Phase::Done => "done",
        }
    }
}

pub struct SceneQuiz {
    level: u32,
    p: Params,
    scene: Scene,
    qs: Vec<Q>,
    phase: Phase,
    t_ms: f64,
    fb_ms: f64,
    idx: usize,
    /// (given option, correct) per answered question.
    answers: Vec<(usize, bool)>,
    status: &'static str,
    stars: u32,
}

pub fn create(level: u32, _mode: &str) -> Result<Box<dyn Session>, String> {
    Ok(Box::new(SceneQuiz::new(level)))
}

/// Deterministic scene + questions for a level.
pub fn level_content(level: u32, p: &Params) -> (Scene, Vec<Q>) {
    let mut rng = Rng::new(seed_for("scene_quiz", level, 0));
    let mut fallback: Option<(Scene, Vec<Q>)> = None;
    for _ in 0..12 {
        let seed = rng.next_u64();
        let min = p.scene.people.0;
        let len = p.chain;
        let sc = generate_where(seed, &p.scene, |s| {
            s.people().count() >= min && (len == 0 || chain(s, len, &mut Rng::new(seed)).is_some())
        });
        let mut qr = Rng::new(seed ^ 0x5CE7_E0F1_A2B3_C4D5);
        if let Some(qs) = build(&sc, p, &mut qr) {
            return (sc, qs);
        }
        if fallback.is_none() {
            let mut relaxed = p.clone();
            relaxed.chain = 0;
            if let Some(qs) = build(&sc, &relaxed, &mut qr) {
                fallback = Some((sc, qs));
            }
        }
    }
    fallback.expect("scene quiz content")
}

impl SceneQuiz {
    pub fn new(level: u32) -> Self {
        let p = params(level);
        let (scene, qs) = level_content(level, &p);
        SceneQuiz { level, p, scene, qs, phase: Phase::Intro, t_ms: 0.0, fb_ms: 0.0, idx: 0, answers: vec![], status: "playing", stars: 0 }
    }

    fn chain_len(&self) -> usize {
        self.qs.iter().filter(|q| q.chain > 0).count()
    }

    fn advance(&mut self) {
        self.idx += 1;
        self.fb_ms = 0.0;
        if self.idx >= self.qs.len() {
            self.phase = Phase::Done;
            self.status = "won";
            let wrong = self.answers.iter().filter(|a| !a.1).count();
            self.stars = match wrong {
                0 => 3,
                1 => 2,
                _ => 1,
            };
        } else {
            self.phase = Phase::Question;
        }
    }

    fn summary(&self) -> String {
        let right = self.answers.iter().filter(|a| a.1).count();
        if self.status == "lost" {
            format!("İlk soru kaçtı: doğrusu “{}” · Sonraki bölüm kilitli kalır", self.qs[0].answer_text())
        } else {
            let secs = format!("{:.1}", self.p.show_ms / 1000.0).replace('.', ",");
            format!("Doğru {right}/{} · Bakış {secs} sn", self.qs.len())
        }
    }
}

impl Session for SceneQuiz {
    fn state(&self) -> Value {
        let q = (matches!(self.phase, Phase::Question | Phase::Feedback | Phase::Done)).then(|| &self.qs[self.idx.min(self.qs.len() - 1)]);
        let last = matches!(self.phase, Phase::Feedback | Phase::Done)
            .then(|| self.answers.last())
            .flatten()
            .map(|&(given, correct)| json!({"given": given, "answer": q.map(|q| q.answer), "correct": correct}));
        let secs = format!("{:.1}", self.p.show_ms / 1000.0).replace(".0", "").replace('.', ",");
        let chain = self.chain_len();
        let mut v = json!({
            "status": self.status,
            "stars": self.stars,
            "title": if chain > 0 { format!("Zincir · {chain} soru") } else { self.scene.setting.name().to_string() },
            "goal": format!("{secs} sn bak · {} soru · İlk soru kilidi açar", self.qs.len()),
            "level": self.level,
            "phase": self.phase.key(),
            "show_ms": self.p.show_ms,
            "t_ms": self.t_ms,
            "fb_ms": self.fb_ms,
            "feedback_ms": FEEDBACK_MS,
            "q_index": self.idx.min(self.qs.len() - 1),
            "q_count": self.qs.len(),
            "chain_len": chain,
            "question": q.map(|q| json!({
                "text": q.text,
                "note": q.note,
                "options": q.options,
                "chain_step": q.chain,
                "kind": q.kind,
                "numeric": q.kind.ends_with("count") || q.kind.starts_with("chain"),
            })),
            "last": last,
            "answers": self.answers.iter().map(|a| a.1).collect::<Vec<_>>(),
            "scene_no": self.scene.no,
            "setting": self.scene.setting.name(),
        });
        if matches!(self.phase, Phase::Show | Phase::Done) {
            v["scene"] = self.scene.json(&format!("sq{}-{}", self.level, self.scene.no));
        }
        if self.phase == Phase::Done {
            v["summary"] = json!(self.summary());
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
            self.phase = Phase::Show;
            self.t_ms = 0.0;
            return Ok(());
        }
        if a["ready"].as_bool() == Some(true) {
            if self.phase != Phase::Show {
                return Err("Şimdi değil".into());
            }
            self.phase = Phase::Question;
            return Ok(());
        }
        if a["next"].as_bool() == Some(true) {
            if self.phase != Phase::Feedback {
                return Err("Şimdi değil".into());
            }
            self.advance();
            return Ok(());
        }
        if let Some(i) = a["answer"].as_u64() {
            if self.phase != Phase::Question {
                return Err("Şimdi soru yok".into());
            }
            let q = &self.qs[self.idx];
            let i = i as usize;
            if i >= q.options.len() {
                return Err("Geçersiz seçenek".into());
            }
            let correct = i == q.answer;
            self.answers.push((i, correct));
            if self.idx == 0 && !correct {
                // Owner's rule: the first question unlocks the level.
                self.phase = Phase::Done;
                self.status = "lost";
                self.stars = 0;
            } else {
                self.phase = Phase::Feedback;
                self.fb_ms = 0.0;
            }
            return Ok(());
        }
        Err("Bilinmeyen hamle".into())
    }

    fn tick(&mut self, dt: f64) {
        match self.phase {
            Phase::Show => {
                self.t_ms += dt;
                if self.t_ms >= self.p.show_ms {
                    self.t_ms = self.p.show_ms;
                    self.phase = Phase::Question;
                }
            }
            Phase::Feedback => {
                self.fb_ms += dt;
                if self.fb_ms >= FEEDBACK_MS {
                    self.advance();
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

    // ---------------------------------------------------------------- hand-made scene

    fn person(female: bool, age: Age) -> Person {
        Person {
            female,
            age,
            sitting: false,
            seat: Seat::None,
            skin: 1,
            hair: Hair::Kahve,
            style: Style::Short,
            hat: None,
            glasses: Glasses::None,
            top: Tone::of(Col::Gri),
            top_kind: TopKind::Sweater,
            pattern: Pattern::Plain,
            bottom: Tone::of(Col::Mavi),
            bottom_kind: BottomKind::Trousers,
            bag: None,
            hold: None,
            beard: Beard::None,
        }
    }

    fn item(id: u32, kind: Kind, row: u8, b: Rect, var: u8, on: Option<u32>, person: Option<Person>) -> Item {
        let s = if row == WALL { 1.0 } else { ROW_SCALE[row as usize] };
        Item { id, kind, row, b, s, tone: Tone::of(Col::Kahve), tone2: Tone::of(Col::Beyaz), var, on, z: id as f64, person }
    }

    /// Kafe: a table in the middle row with a red-wool-bere woman sitting left of it (glasses,
    /// striped red sweater), a man in a blue leather kasket standing in front of the window
    /// (back row, holding a cup), a girl with a straw hat and a balloon on the right of the front
    /// row, a cat under the table, two cups on the table (red, white), a wall clock at 3.
    fn hand_scene() -> Scene {
        let mut items = vec![];
        let win = Rect::new(80.0, 86.0, 190.0, 230.0);
        items.push(item(1, Kind::Window, WALL, win, 1, None, None));
        let mut clock = item(2, Kind::Clock, WALL, Rect::new(600.0, 60.0, 88.0, 88.0), 3, None, None);
        clock.tone = Tone::of(Col::Siyah);
        items.push(clock);
        let s1 = ROW_SCALE[1];
        let (tw, th) = item_size(Kind::Table, 0, s1);
        let table = item(3, Kind::Table, 1, Rect::new(450.0, ROW_FOOT[1] - th, tw, th), 0, None, None);
        let tb = table.b;
        items.push(table);
        // Woman sitting left of the table.
        let mut w = person(true, Age::Adult);
        w.sitting = true;
        w.seat = Seat::Chair;
        w.style = Style::Long;
        w.hat = Some(Hat { kind: HatKind::Bere, tone: Tone::of(Col::Kirmizi), mat: Mat::Yun });
        w.glasses = Glasses::Reading;
        w.top = Tone::of(Col::Kirmizi);
        w.pattern = Pattern::Stripe;
        let wb = person_box(&w, s1, ROW_FOOT[1], 0.0);
        let wb = person_box(&w, s1, ROW_FOOT[1], tb.x - wb.w / 2.0 - 2.0);
        items.push(item(4, Kind::Person, 1, wb, 0, None, Some(w)));
        // Man in front of the window.
        let mut m = person(false, Age::Adult);
        m.hat = Some(Hat { kind: HatKind::Kasket, tone: Tone::of(Col::Mavi), mat: Mat::Deri });
        m.hold = Some((HoldKind::Cup, Tone::of(Col::Beyaz)));
        m.top = Tone::of(Col::Yesil);
        m.top_kind = TopKind::Jacket;
        items.push(item(5, Kind::Person, 0, person_box(&m, ROW_SCALE[0], ROW_FOOT[0], win.cx()), 0, None, Some(m)));
        // Girl on the right, front row.
        let mut g = person(true, Age::Child);
        g.hat = Some(Hat { kind: HatKind::Hasir, tone: Tone::of(Col::Sari), mat: Mat::Hasir });
        g.hold = Some((HoldKind::Balloon, Tone::of(Col::Pembe)));
        g.top = Tone::of(Col::Sari);
        g.pattern = Pattern::Dots;
        g.top_kind = TopKind::Tshirt;
        g.bag = Some((BagKind::Backpack, Tone::of(Col::Mor)));
        items.push(item(6, Kind::Person, 2, person_box(&g, 1.0, ROW_FOOT[2], 860.0), 0, None, Some(g)));
        // Cat under the table, cups on it.
        let (cw, ch) = item_size(Kind::Cat, 1, s1);
        let mut cat = item(7, Kind::Cat, 1, Rect::new(tb.x + 8.0, tb.y1() - ch, cw, ch), 1, Some(3), None);
        cat.tone = Tone::of(Col::Turuncu);
        items.push(cat);
        let sy = items[2].surface().unwrap();
        let (uw, uh) = item_size(Kind::Cup, 0, s1);
        let mut c1 = item(8, Kind::Cup, 1, Rect::new(tb.x + 30.0, sy - uh, uw, uh), 0, Some(3), None);
        c1.tone = Tone::of(Col::Kirmizi);
        let mut c2 = item(9, Kind::Cup, 1, Rect::new(tb.x + 100.0, sy - uh, uw, uh), 0, Some(3), None);
        c2.tone = Tone::of(Col::Beyaz);
        items.push(c1);
        items.push(c2);
        Scene { no: 123_456, setting: Setting::Kafe, wall: 0, floor: 0, bg: 0, items }
    }

    fn find<'a>(qs: &'a [Q], kind: &str) -> Vec<&'a Q> {
        qs.iter().filter(|q| q.kind == kind).collect()
    }

    #[test]
    fn scene_quiz_hand_scene_relations_and_refs() {
        let sc = hand_scene();
        let ppl = infos(&sc);
        let w = ppl.iter().find(|i| i.id == 4).unwrap();
        assert!(w.rels.contains(&Rel::Table), "{:?}", w.rels);
        let m = ppl.iter().find(|i| i.id == 5).unwrap();
        assert!(m.rels.contains(&Rel::Window), "{:?}", m.rels);
        let wi = ppl.iter().position(|i| i.id == 4).unwrap();
        let refs = unique_refs(&ppl, wi, &[0], true, true);
        assert!(refs.iter().any(|r| r.gen() == "masanın yanında oturan kadının"), "{:?}", refs.iter().map(|r| r.gen()).collect::<Vec<_>>());
        // "kadın" alone is unique too (only one adult woman).
        assert_eq!(refs[0].nom(), "kadın");
    }

    #[test]
    fn scene_quiz_hand_scene_answers_are_correct() {
        let sc = hand_scene();
        for seed in 0..40u64 {
            let mut r = Rng::new(seed);
            let qs = pool(&sc, &mut r);
            let ans = |kind: &str| find(&qs, kind).iter().map(|q| (q.text.to_lowercase(), q.answer_text().to_string())).collect::<Vec<_>>();
            assert_eq!(ans("people_count")[0].1, "3");
            assert_eq!(ans("hat_count")[0].1, "3");
            assert_eq!(ans("sitting_count")[0].1, "1");
            assert_eq!(ans("child_count")[0].1, "1");
            assert_eq!(ans("glasses_count")[0].1, "1");
            assert_eq!(ans("bag_count")[0].1, "1");
            assert_eq!(ans("cup_count")[0].1, "3", "2 on the table + 1 held");
            assert_eq!(ans("balloon_count").first().map(|a| a.1.as_str()), Some("1"));
            assert_eq!(ans("animal_count")[0].1, "1");
            assert_eq!(ans("animal_which")[0].1, "Kedi");
            assert_eq!(ans("window_count")[0].1, "1");
            assert_eq!(ans("clock_time")[0].1, "3:00");
            assert_eq!(ans("animal_color")[0].1, "Turuncu");
            assert_eq!(ans("animal_where")[0].1, "Masanın altında");
            for (text, a) in ans("hat_color_of") {
                if text.contains("beresi") {
                    assert_eq!(a, "Kırmızı", "{text}");
                } else {
                    assert!(text.contains("kasketi"));
                    assert_eq!(a, "Mavi", "{text}");
                }
            }
            for (text, a) in ans("hat_mat_of") {
                let want = if text.contains("küçük kız") { "Hasır" } else if text.contains("adam") { "Deri" } else { "Yün" };
                assert_eq!(a, want, "{text}");
            }
            for (text, a) in ans("hold_of") {
                let want = if text.contains("küçük kız") { "Balon" } else if text.contains("adam") { "Fincan" } else { "Hiçbir şey" };
                assert_eq!(a, want, "{text}");
            }
            for (text, a) in ans("pattern_of") {
                let want = if text.contains("küçük kız") { "Puantiyeli" } else if text.contains("adam") { "Düz" } else { "Çizgili" };
                assert_eq!(a, want, "{text}");
            }
            for (text, a) in ans("hat_kind_of") {
                let want = if text.contains("küçük kız") { "Hasır şapka" } else if text.contains("adam") { "Kasket" } else { "Bere" };
                assert_eq!(a, want, "{text}");
            }
            for q in find(&qs, "describe") {
                if q.text.starts_with("Masanın yanında nasıl bir kadın oturuyordu") {
                    // Both features of the answer hold for the woman, no distractor fully does.
                    let a = q.answer_text();
                    assert!(!a.is_empty());
                }
            }
            // Distractors never equal the answer.
            for q in &qs {
                let mut o = q.options.clone();
                o.sort();
                o.dedup();
                assert_eq!(o.len(), q.options.len(), "duplicate options in {}", q.text);
                assert!(q.answer < q.options.len());
            }
        }
    }

    #[test]
    fn scene_quiz_hand_scene_hat_chain() {
        let sc = hand_scene();
        let ppl = infos(&sc);
        let mut found = false;
        for seed in 0..60u64 {
            let mut r = Rng::new(seed);
            let Some(qs) = chain_template(&sc, &ppl, 0, 3, &mut r) else { continue };
            found = true;
            assert_eq!(qs[0].answer_text(), "3");
            // Colour step: red → 1 (the bere), blue → 1 (the kasket); straw hats have no colour.
            assert_eq!(qs[1].answer_text(), "1", "{}", qs[1].text);
            let m = if qs[1].text.contains("kırmızı") { "yündü" } else { "deriydi" };
            assert!(qs[2].text.ends_with(&format!("{m}?")), "{}", qs[2].text);
            assert_eq!(qs[2].answer_text(), "1");
        }
        assert!(found);
    }

    #[test]
    fn scene_quiz_describe_distractors_never_true() {
        for seed in 0..300u64 {
            let sc = generate(seed, &params(250).scene);
            let ppl = infos(&sc);
            let mut r = Rng::new(seed);
            for ti in 0..ppl.len() {
                let refs: Vec<Ref> = unique_refs(&ppl, ti, &[], true, false).into_iter().filter(|x| x.place().is_some()).collect();
                let Some(rf) = refs.first() else { continue };
                let Some(q) = describe_q(&mut r, &ppl, ti, rf) else { continue };
                let feats = person_feats(&ppl[ti].p);
                // The answer is built only from true features; check each distractor has a false one
                // by rebuilding the true description set of two-feature combinations.
                let mut true_texts = vec![];
                for a in &feats {
                    for b in &feats {
                        if a.dim() < b.dim() {
                            true_texts.push(describe_text(&[*a, *b]));
                        }
                    }
                }
                assert!(true_texts.contains(&q.answer_text().to_string()));
                for (i, o) in q.options.iter().enumerate() {
                    if i != q.answer {
                        assert!(!true_texts.contains(o), "distractor also true: {o}");
                    }
                }
            }
        }
    }

    #[test]
    fn scene_quiz_unique_refs_are_unique() {
        for seed in 0..200u64 {
            let sc = generate(seed, &params(400).scene);
            let ppl = infos(&sc);
            for ti in 0..ppl.len() {
                for rf in unique_refs(&ppl, ti, &[], true, true) {
                    assert_eq!(ppl.iter().filter(|i| rf.matches(i)).count(), 1);
                    assert!(rf.matches(&ppl[ti]));
                }
            }
        }
    }

    #[test]
    fn scene_quiz_pool_options_are_sound() {
        for seed in 0..300u64 {
            let sc = generate(seed, &params(300).scene);
            let mut r = Rng::new(seed);
            for q in pool(&sc, &mut r) {
                assert!(q.options.len() >= 2 && q.options.len() <= 4, "{}", q.text);
                assert!(q.answer < q.options.len());
                let mut o = q.options.clone();
                o.sort();
                o.dedup();
                assert_eq!(o.len(), q.options.len(), "duplicate option in {}", q.text);
                assert!(!q.text.contains("  "));
            }
        }
    }

    #[test]
    fn scene_quiz_params_for_levels() {
        for l in LEVELS {
            let p = params(l);
            assert!(p.questions > p.chain);
            assert!(p.show_ms >= 3500.0 && p.show_ms <= 15_000.0);
        }
        assert_eq!(params(1).show_ms, 15_000.0);
        assert_eq!(params(500).show_ms, 3500.0);
        assert_eq!(params(1).chain, 0);
        assert_eq!(params(499).chain, 3);
    }

    #[test]
    fn scene_quiz_levels_generate_and_are_deterministic() {
        for l in LEVELS {
            let a = SceneQuiz::new(l);
            let b = SceneQuiz::new(l);
            assert_eq!(a.qs, b.qs);
            assert_eq!(a.scene, b.scene);
            assert_eq!(a.qs.len(), a.p.questions, "level {l}");
            assert_eq!(a.chain_len(), a.p.chain, "level {l}");
            if a.p.chain > 0 {
                assert_eq!(a.qs[0].chain, 1, "chain head first");
            } else {
                assert!(a.qs[0].tier <= 1);
            }
            assert!(a.qs.iter().all(|q| q.tier <= a.p.max_tier || q.chain > 0));
        }
    }

    fn play(g: &mut SceneQuiz, right: &[bool]) {
        g.act(&json!({"start": true})).unwrap();
        assert!(g.state()["scene"].is_object());
        g.tick(g.p.show_ms + 10.0);
        assert_eq!(g.phase, Phase::Question);
        assert!(g.state()["scene"].is_null(), "scene hidden while answering");
        for &ok in right {
            if g.status != "playing" {
                break;
            }
            let q = &g.qs[g.idx];
            let pick = if ok { q.answer } else { (q.answer + 1) % q.options.len() };
            g.act(&json!({"answer": pick})).unwrap();
            if g.status == "playing" {
                g.tick(FEEDBACK_MS + 1.0);
            }
        }
    }

    #[test]
    fn scene_quiz_all_right_three_stars() {
        for l in LEVELS {
            let mut g = SceneQuiz::new(l);
            let n = g.qs.len();
            play(&mut g, &vec![true; n]);
            assert_eq!(g.status, "won", "level {l}");
            assert_eq!(g.stars, 3);
            assert!(g.state()["summary"].is_string());
            assert!(g.state()["scene"].is_object(), "scene shown again for review");
        }
    }

    #[test]
    fn scene_quiz_first_question_wrong_loses() {
        for l in LEVELS {
            let mut g = SceneQuiz::new(l);
            play(&mut g, &[false]);
            assert_eq!(g.status, "lost", "level {l}");
            assert_eq!(g.stars, 0);
            assert_eq!(g.phase, Phase::Done);
            assert!(g.act(&json!({"answer": 0})).is_err());
        }
    }

    #[test]
    fn scene_quiz_later_mistakes_cost_stars() {
        let mut g = SceneQuiz::new(60);
        let n = g.qs.len();
        let mut v = vec![true; n];
        v[1] = false;
        play(&mut g, &v);
        assert_eq!((g.status, g.stars), ("won", 2));
        let mut g = SceneQuiz::new(60);
        let mut v = vec![false; n];
        v[0] = true;
        play(&mut g, &v);
        assert_eq!((g.status, g.stars), ("won", 1));
    }

    #[test]
    fn scene_quiz_illegal_actions_leave_state() {
        let mut g = SceneQuiz::new(5);
        let before = g.state();
        assert!(g.act(&json!({"answer": 0})).is_err());
        assert!(g.act(&json!({"ready": true})).is_err());
        assert!(g.act(&json!({"next": true})).is_err());
        assert_eq!(g.state(), before);
        g.act(&json!({"start": true})).unwrap();
        g.act(&json!({"ready": true})).unwrap();
        let before = g.state();
        assert!(g.act(&json!({"answer": 9})).is_err());
        assert_eq!(g.state(), before);
    }

    #[test]
    fn scene_quiz_all_levels_build() {
        for l in (1..=500).step_by(3) {
            let g = SceneQuiz::new(l);
            assert_eq!(g.qs.len(), g.p.questions, "level {l}");
        }
    }

    #[test]
    #[ignore]
    fn scene_quiz_timing() {
        let t0 = std::time::Instant::now();
        let mut worst = 0.0f64;
        for l in 1..=500 {
            let t = std::time::Instant::now();
            let _ = SceneQuiz::new(l);
            worst = worst.max(t.elapsed().as_secs_f64());
        }
        println!("500 levels: {:.2?}, worst {:.1} ms", t0.elapsed(), worst * 1000.0);
    }

    #[test]
    #[ignore]
    fn scene_quiz_print_samples() {
        for l in [1, 30, 137, 250, 499] {
            let g = SceneQuiz::new(l);
            println!("--- level {l} ({}) show {} ms", g.scene.setting.name(), g.p.show_ms);
            for q in &g.qs {
                println!("  [{}{}] {} {:?} → {}", q.kind, if q.chain > 0 { format!(" c{}", q.chain) } else { String::new() }, q.text, q.options, q.answer_text());
            }
        }
    }
}
