//! Procedural illustrated scenes shared by `change_spot` (Değişimi Yakala) and `scene_quiz`
//! (Sahne Hafızası).
//!
//! A scene is a deterministic description generated from a 64-bit seed: a setting (kafe, park,
//! oturma odası, sokak, plaj, ofis, mutfak, istasyon), a back wall or open horizon, wall items
//! (windows with or without curtains, clocks that show an hour, paintings), furniture on three
//! depth rows (back → front, scale 0.74 / 0.87 / 1.0), small objects on furniture or on the ground,
//! animals and people with rich attributes: gender presentation, age group, pose, hair colour and
//! style, hat (fötr şapka / bere / kasket / hasır şapka, with colour and material: kumaş / hasır /
//! deri / yün), glasses, top (kind, colour, pattern), bottom, bag, held item, beard.
//!
//! **Geometry lives here, not in Flutter.** Every item carries its box in canvas units
//! (`W` × `H` = 1000 × 800, y grows downwards); people also carry their part boxes (hat, head,
//! hair, face, torso, legs, hand, bag, seat). `change_spot` knows exactly where a change is, and the
//! painter draws each part inside the same box. Items are emitted in draw order (back to front).
//!
//! **Readability rules** enforced by the placer: items in the same row never overlap (unless one is
//! `on` the other — a cup on a table, a person on a bench, a cat under a table, a bird in a tree),
//! and a nearer item may cover at most 12% of the *important part* of an item behind it (a
//! person's upper body with hat, hand and bag; a table top; a whole object or animal). Front-row
//! people may hide back-row legs, never faces, hats or tops; tall backdrops (trees, shelves, lamps,
//! parasols) may stand behind anything. So every attribute a question asks about is actually
//! visible, and every change can be seen.
//!
//! **Variety:** 8 settings × wall/floor/background palettes × 2–8 people with ~12 independent
//! attributes × furniture, object and animal layouts. A test checks ≥ 1000 distinct descriptions
//! over 1200 seeds (in practice every seed differs). `no` is a 6-digit scene number the views show
//! subtly in a corner.
//!
//! Scene JSON: `{no, key, set, w, h, wall, floor, bg, items: [item]}` with
//! `item = {id, k, r, x, y, w, h, s, t, t2, v, sy?, on?, p?}` — `k` kind, `r` row (0..2, 3 = wall),
//! box `x,y,w,h`, `s` scale, `t`/`t2` tones (`"kirmizi"`, shaded `"kirmizi:1"` / `"kirmizi:-1"`),
//! `v` variant (table shape, clock hour, fruit kind, …), `sy` support surface y, `on` supporting
//! item. People: `p = {g, age, sit, seat, skin, hair, hs, hat: {k,t,m}|null, gl, top, tk, pat, bot,
//! bk, bag: {k,t}|null, hold: {k,t}|null, beard, parts: {hat, head, hair, face, torso, legs, hand,
//! bag, seat?}}` (part boxes as `[x,y,w,h]`).

use crate::rng::Rng;
use serde_json::{json, Map, Value};

pub const W: f64 = 1000.0;
pub const H: f64 = 800.0;
/// Where the back wall meets the floor (indoor) or the sky meets the ground (outdoor).
pub const HORIZON: f64 = 440.0;
/// Foot line and scale of the three floor rows, back → front.
pub const ROW_FOOT: [f64; 3] = [478.0, 630.0, 790.0];
pub const ROW_SCALE: [f64; 3] = [0.72, 0.85, 1.0];
pub const WALL: u8 = 3;
/// Largest share of an item's important part a nearer item may cover.
pub const OCCLUSION: f64 = 0.12;
/// Hip height of a seated adult above the floor (× scale); chairs and bench seats use it too.
pub const SEAT_H: f64 = 87.0;

// ------------------------------------------------------------------------------------------ rect

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub fn new(x: f64, y: f64, w: f64, h: f64) -> Rect {
        Rect { x, y, w, h }
    }
    pub fn x1(&self) -> f64 {
        self.x + self.w
    }
    pub fn y1(&self) -> f64 {
        self.y + self.h
    }
    pub fn cx(&self) -> f64 {
        self.x + self.w / 2.0
    }
    pub fn cy(&self) -> f64 {
        self.y + self.h / 2.0
    }
    pub fn area(&self) -> f64 {
        self.w.max(0.0) * self.h.max(0.0)
    }
    /// Intersection area.
    pub fn inter(&self, o: &Rect) -> f64 {
        let w = self.x1().min(o.x1()) - self.x.max(o.x);
        let h = self.y1().min(o.y1()) - self.y.max(o.y);
        if w <= 0.0 || h <= 0.0 {
            0.0
        } else {
            w * h
        }
    }
    pub fn union(&self, o: &Rect) -> Rect {
        let x = self.x.min(o.x);
        let y = self.y.min(o.y);
        Rect::new(x, y, self.x1().max(o.x1()) - x, self.y1().max(o.y1()) - y)
    }
    pub fn inflate(&self, d: f64) -> Rect {
        Rect::new(self.x - d, self.y - d, self.w + 2.0 * d, self.h + 2.0 * d)
    }
    pub fn contains(&self, px: f64, py: f64) -> bool {
        px >= self.x && px <= self.x1() && py >= self.y && py <= self.y1()
    }
    /// Clipped to the canvas.
    pub fn clip(&self) -> Rect {
        let x = self.x.max(0.0);
        let y = self.y.max(0.0);
        Rect::new(x, y, (self.x1().min(W) - x).max(0.0), (self.y1().min(H) - y).max(0.0))
    }
    /// Horizontal gap between two boxes (negative when they overlap in x).
    pub fn gap_x(&self, o: &Rect) -> f64 {
        (o.x - self.x1()).max(self.x - o.x1())
    }
    pub fn json(&self) -> Value {
        json!([r1(self.x), r1(self.y), r1(self.w), r1(self.h)])
    }
}

fn r1(v: f64) -> f64 {
    (v * 10.0).round() / 10.0
}

// ---------------------------------------------------------------------------------------- colours

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Col {
    Kirmizi,
    Mavi,
    Yesil,
    Sari,
    Turuncu,
    Mor,
    Pembe,
    Siyah,
    Beyaz,
    Gri,
    Kahve,
}

pub const COLS: [Col; 11] =
    [Col::Kirmizi, Col::Mavi, Col::Yesil, Col::Sari, Col::Turuncu, Col::Mor, Col::Pembe, Col::Siyah, Col::Beyaz, Col::Gri, Col::Kahve];

impl Col {
    pub fn key(self) -> &'static str {
        match self {
            Col::Kirmizi => "kirmizi",
            Col::Mavi => "mavi",
            Col::Yesil => "yesil",
            Col::Sari => "sari",
            Col::Turuncu => "turuncu",
            Col::Mor => "mor",
            Col::Pembe => "pembe",
            Col::Siyah => "siyah",
            Col::Beyaz => "beyaz",
            Col::Gri => "gri",
            Col::Kahve => "kahve",
        }
    }
    /// Turkish adjective: "kırmızı".
    pub fn name(self) -> &'static str {
        match self {
            Col::Kirmizi => "kırmızı",
            Col::Mavi => "mavi",
            Col::Yesil => "yeşil",
            Col::Sari => "sarı",
            Col::Turuncu => "turuncu",
            Col::Mor => "mor",
            Col::Pembe => "pembe",
            Col::Siyah => "siyah",
            Col::Beyaz => "beyaz",
            Col::Gri => "gri",
            Col::Kahve => "kahverengi",
        }
    }
    /// Past copula: "kırmızıydı".
    pub fn was(self) -> &'static str {
        match self {
            Col::Kirmizi => "kırmızıydı",
            Col::Mavi => "maviydi",
            Col::Yesil => "yeşildi",
            Col::Sari => "sarıydı",
            Col::Turuncu => "turuncuydu",
            Col::Mor => "mordu",
            Col::Pembe => "pembeydi",
            Col::Siyah => "siyahtı",
            Col::Beyaz => "beyazdı",
            Col::Gri => "griydi",
            Col::Kahve => "kahverengiydi",
        }
    }
}

/// A colour plus a shade step (−1 darker, 0, +1 lighter). Shades only appear in `change_spot`'s
/// subtle changes; generated scenes always use shade 0.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Tone {
    pub c: Col,
    pub s: i8,
}

impl Tone {
    pub fn of(c: Col) -> Tone {
        Tone { c, s: 0 }
    }
    pub fn key(&self) -> String {
        if self.s == 0 {
            self.c.key().to_string()
        } else {
            format!("{}:{}", self.c.key(), self.s)
        }
    }
}

/// Turkish-aware capitalisation of the first letter ("ışık" → "Işık", "iki" → "İki").
pub fn cap(s: &str) -> String {
    let mut ch = s.chars();
    match ch.next() {
        None => String::new(),
        Some('i') => format!("İ{}", ch.as_str()),
        Some(c) => format!("{}{}", c.to_uppercase(), ch.as_str()),
    }
}

// --------------------------------------------------------------------------------------- settings

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Setting {
    Kafe,
    Park,
    Oda,
    Sokak,
    Plaj,
    Ofis,
    Mutfak,
    Istasyon,
}

pub const SETTINGS: [Setting; 8] =
    [Setting::Kafe, Setting::Park, Setting::Oda, Setting::Sokak, Setting::Plaj, Setting::Ofis, Setting::Mutfak, Setting::Istasyon];

impl Setting {
    pub fn key(self) -> &'static str {
        match self {
            Setting::Kafe => "kafe",
            Setting::Park => "park",
            Setting::Oda => "oda",
            Setting::Sokak => "sokak",
            Setting::Plaj => "plaj",
            Setting::Ofis => "ofis",
            Setting::Mutfak => "mutfak",
            Setting::Istasyon => "istasyon",
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            Setting::Kafe => "Kafe",
            Setting::Park => "Park",
            Setting::Oda => "Oturma odası",
            Setting::Sokak => "Sokak",
            Setting::Plaj => "Plaj",
            Setting::Ofis => "Ofis",
            Setting::Mutfak => "Mutfak",
            Setting::Istasyon => "İstasyon",
        }
    }
    /// Has a back wall (or a building facade) that carries windows, clocks and paintings.
    pub fn has_wall(self) -> bool {
        !matches!(self, Setting::Park | Setting::Plaj)
    }
    pub fn warm(self) -> bool {
        matches!(self, Setting::Park | Setting::Plaj)
    }
}

// ------------------------------------------------------------------------------------------ kinds

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Kind {
    Window,
    Clock,
    Frame,
    Tree,
    Shelf,
    Lamp,
    Plant,
    Counter,
    Table,
    Bench,
    Parasol,
    Cup,
    Book,
    Bag,
    Umbrella,
    Ball,
    Fruit,
    Vase,
    Bottle,
    Laptop,
    Cat,
    Dog,
    Bird,
    Person,
}

impl Kind {
    pub fn key(self) -> &'static str {
        match self {
            Kind::Window => "window",
            Kind::Clock => "clock",
            Kind::Frame => "frame",
            Kind::Tree => "tree",
            Kind::Shelf => "shelf",
            Kind::Lamp => "lamp",
            Kind::Plant => "plant",
            Kind::Counter => "counter",
            Kind::Table => "table",
            Kind::Bench => "bench",
            Kind::Parasol => "parasol",
            Kind::Cup => "cup",
            Kind::Book => "book",
            Kind::Bag => "bag",
            Kind::Umbrella => "umbrella",
            Kind::Ball => "ball",
            Kind::Fruit => "fruit",
            Kind::Vase => "vase",
            Kind::Bottle => "bottle",
            Kind::Laptop => "laptop",
            Kind::Cat => "cat",
            Kind::Dog => "dog",
            Kind::Bird => "bird",
            Kind::Person => "person",
        }
    }
    /// Turkish noun (nominative).
    pub fn name(self) -> &'static str {
        match self {
            Kind::Window => "pencere",
            Kind::Clock => "duvar saati",
            Kind::Frame => "tablo",
            Kind::Tree => "ağaç",
            Kind::Shelf => "raf",
            Kind::Lamp => "lamba",
            Kind::Plant => "saksı",
            Kind::Counter => "tezgâh",
            Kind::Table => "masa",
            Kind::Bench => "bank",
            Kind::Parasol => "plaj şemsiyesi",
            Kind::Cup => "fincan",
            Kind::Book => "kitap",
            Kind::Bag => "çanta",
            Kind::Umbrella => "şemsiye",
            Kind::Ball => "top",
            Kind::Fruit => "meyve kasesi",
            Kind::Vase => "vazo",
            Kind::Bottle => "şişe",
            Kind::Laptop => "dizüstü bilgisayar",
            Kind::Cat => "kedi",
            Kind::Dog => "köpek",
            Kind::Bird => "kuş",
            Kind::Person => "kişi",
        }
    }
    /// Genitive: "fincanın".
    pub fn gen(self) -> &'static str {
        match self {
            Kind::Window => "pencerenin",
            Kind::Clock => "saatin",
            Kind::Frame => "tablonun",
            Kind::Tree => "ağacın",
            Kind::Shelf => "rafın",
            Kind::Lamp => "lambanın",
            Kind::Plant => "saksının",
            Kind::Counter => "tezgâhın",
            Kind::Table => "masanın",
            Kind::Bench => "bankın",
            Kind::Parasol => "plaj şemsiyesinin",
            Kind::Cup => "fincanın",
            Kind::Book => "kitabın",
            Kind::Bag => "çantanın",
            Kind::Umbrella => "şemsiyenin",
            Kind::Ball => "topun",
            Kind::Fruit => "kasenin",
            Kind::Vase => "vazonun",
            Kind::Bottle => "şişenin",
            Kind::Laptop => "bilgisayarın",
            Kind::Cat => "kedinin",
            Kind::Dog => "köpeğin",
            Kind::Bird => "kuşun",
            Kind::Person => "kişinin",
        }
    }
    pub fn is_object(self) -> bool {
        matches!(
            self,
            Kind::Cup | Kind::Book | Kind::Bag | Kind::Umbrella | Kind::Ball | Kind::Fruit | Kind::Vase | Kind::Bottle | Kind::Laptop
        )
    }
    pub fn is_animal(self) -> bool {
        matches!(self, Kind::Cat | Kind::Dog | Kind::Bird)
    }
    pub fn is_wall(self) -> bool {
        matches!(self, Kind::Window | Kind::Clock | Kind::Frame)
    }
    /// Tall items that may stand behind anything in a nearer row.
    pub fn backdrop(self) -> bool {
        matches!(self, Kind::Tree | Kind::Shelf | Kind::Lamp | Kind::Parasol)
    }
    pub fn is_furniture(self) -> bool {
        matches!(
            self,
            Kind::Tree | Kind::Shelf | Kind::Lamp | Kind::Plant | Kind::Counter | Kind::Table | Kind::Bench | Kind::Parasol
        )
    }
}

// ----------------------------------------------------------------------------------------- people

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Age {
    Child,
    Adult,
    Elder,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Hair {
    Siyah,
    Kahve,
    Sari,
    Kizil,
    Gri,
}

pub const HAIRS: [Hair; 5] = [Hair::Siyah, Hair::Kahve, Hair::Sari, Hair::Kizil, Hair::Gri];

impl Hair {
    pub fn key(self) -> &'static str {
        match self {
            Hair::Siyah => "siyah",
            Hair::Kahve => "kahve",
            Hair::Sari => "sari",
            Hair::Kizil => "kizil",
            Hair::Gri => "gri",
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            Hair::Siyah => "siyah",
            Hair::Kahve => "kahverengi",
            Hair::Sari => "sarı",
            Hair::Kizil => "kızıl",
            Hair::Gri => "kır",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Style {
    Short,
    Long,
    Bun,
    Ponytail,
    Curly,
    Bald,
}

impl Style {
    pub fn key(self) -> &'static str {
        match self {
            Style::Short => "short",
            Style::Long => "long",
            Style::Bun => "bun",
            Style::Ponytail => "ponytail",
            Style::Curly => "curly",
            Style::Bald => "bald",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum HatKind {
    Fotr,
    Bere,
    Kasket,
    Hasir,
}

pub const HAT_KINDS: [HatKind; 4] = [HatKind::Fotr, HatKind::Bere, HatKind::Kasket, HatKind::Hasir];

impl HatKind {
    pub fn key(self) -> &'static str {
        match self {
            HatKind::Fotr => "fotr",
            HatKind::Bere => "bere",
            HatKind::Kasket => "kasket",
            HatKind::Hasir => "hasir",
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            HatKind::Fotr => "fötr şapka",
            HatKind::Bere => "bere",
            HatKind::Kasket => "kasket",
            HatKind::Hasir => "hasır şapka",
        }
    }
    /// "-li" adjective: "bereli".
    pub fn adj(self) -> &'static str {
        match self {
            HatKind::Fotr => "fötr şapkalı",
            HatKind::Bere => "bereli",
            HatKind::Kasket => "kasketli",
            HatKind::Hasir => "hasır şapkalı",
        }
    }
    /// Genitive: "berenin".
    pub fn gen(self) -> &'static str {
        match self {
            HatKind::Fotr => "şapkanın",
            HatKind::Bere => "berenin",
            HatKind::Kasket => "kasketin",
            HatKind::Hasir => "hasır şapkanın",
        }
    }
    /// Possessive (3rd person): "beresi".
    pub fn poss(self) -> &'static str {
        match self {
            HatKind::Fotr => "şapkası",
            HatKind::Bere => "beresi",
            HatKind::Kasket => "kasketi",
            HatKind::Hasir => "hasır şapkası",
        }
    }
    /// Past copula: "bereydi".
    pub fn was(self) -> &'static str {
        match self {
            HatKind::Fotr => "fötr şapkaydı",
            HatKind::Bere => "bereydi",
            HatKind::Kasket => "kasketti",
            HatKind::Hasir => "hasır şapkaydı",
        }
    }
    /// Plural ablative: "berelerden".
    pub fn from_pl(self) -> &'static str {
        match self {
            HatKind::Fotr => "fötr şapkalardan",
            HatKind::Bere => "berelerden",
            HatKind::Kasket => "kasketlerden",
            HatKind::Hasir => "hasır şapkalardan",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Mat {
    Kumas,
    Hasir,
    Deri,
    Yun,
}

pub const MATS: [Mat; 4] = [Mat::Kumas, Mat::Hasir, Mat::Deri, Mat::Yun];

impl Mat {
    pub fn key(self) -> &'static str {
        match self {
            Mat::Kumas => "kumas",
            Mat::Hasir => "hasir",
            Mat::Deri => "deri",
            Mat::Yun => "yun",
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            Mat::Kumas => "kumaş",
            Mat::Hasir => "hasır",
            Mat::Deri => "deri",
            Mat::Yun => "yün",
        }
    }
    pub fn was(self) -> &'static str {
        match self {
            Mat::Kumas => "kumaştı",
            Mat::Hasir => "hasırdı",
            Mat::Deri => "deriydi",
            Mat::Yun => "yündü",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Hat {
    pub kind: HatKind,
    /// Straw hats are natural straw: their tone is decorative and never asked about.
    pub tone: Tone,
    pub mat: Mat,
}

impl Hat {
    /// The colour a player would name; `None` for natural straw.
    pub fn color(&self) -> Option<Col> {
        if self.kind == HatKind::Hasir {
            None
        } else {
            Some(self.tone.c)
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Glasses {
    None,
    Reading,
    Sun,
}

impl Glasses {
    pub fn key(self) -> &'static str {
        match self {
            Glasses::None => "none",
            Glasses::Reading => "reg",
            Glasses::Sun => "sun",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TopKind {
    Tshirt,
    Sweater,
    Jacket,
}

impl TopKind {
    pub fn key(self) -> &'static str {
        match self {
            TopKind::Tshirt => "tshirt",
            TopKind::Sweater => "sweater",
            TopKind::Jacket => "jacket",
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            TopKind::Tshirt => "tişört",
            TopKind::Sweater => "kazak",
            TopKind::Jacket => "ceket",
        }
    }
    pub fn adj(self) -> &'static str {
        match self {
            TopKind::Tshirt => "tişörtlü",
            TopKind::Sweater => "kazaklı",
            TopKind::Jacket => "ceketli",
        }
    }
    /// Genitive: "kazağın".
    pub fn gen(self) -> &'static str {
        match self {
            TopKind::Tshirt => "tişörtün",
            TopKind::Sweater => "kazağın",
            TopKind::Jacket => "ceketin",
        }
    }
    /// Possessive genitive: "kazağının".
    pub fn poss_gen(self) -> &'static str {
        match self {
            TopKind::Tshirt => "tişörtünün",
            TopKind::Sweater => "kazağının",
            TopKind::Jacket => "ceketinin",
        }
    }
    /// Possessive: "kazağı".
    pub fn poss(self) -> &'static str {
        match self {
            TopKind::Tshirt => "tişörtü",
            TopKind::Sweater => "kazağı",
            TopKind::Jacket => "ceketi",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Pattern {
    Plain,
    Stripe,
    Dots,
}

pub const PATTERNS: [Pattern; 3] = [Pattern::Plain, Pattern::Stripe, Pattern::Dots];

impl Pattern {
    pub fn key(self) -> &'static str {
        match self {
            Pattern::Plain => "plain",
            Pattern::Stripe => "stripe",
            Pattern::Dots => "dots",
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            Pattern::Plain => "düz",
            Pattern::Stripe => "çizgili",
            Pattern::Dots => "puantiyeli",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum BottomKind {
    Trousers,
    Skirt,
    Shorts,
}

impl BottomKind {
    /// Genitive: "eteğin".
    pub fn gen(self) -> &'static str {
        match self {
            BottomKind::Trousers => "pantolonun",
            BottomKind::Skirt => "eteğin",
            BottomKind::Shorts => "şortun",
        }
    }
    pub fn key(self) -> &'static str {
        match self {
            BottomKind::Trousers => "trousers",
            BottomKind::Skirt => "skirt",
            BottomKind::Shorts => "shorts",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum BagKind {
    Backpack,
    Handbag,
}

impl BagKind {
    pub fn key(self) -> &'static str {
        match self {
            BagKind::Backpack => "backpack",
            BagKind::Handbag => "handbag",
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            BagKind::Backpack => "sırt çantası",
            BagKind::Handbag => "el çantası",
        }
    }
    pub fn adj(self) -> &'static str {
        match self {
            BagKind::Backpack => "sırt çantalı",
            BagKind::Handbag => "el çantalı",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum HoldKind {
    Book,
    Cup,
    Umbrella,
    Balloon,
    Flower,
    Phone,
    IceCream,
}

pub const HOLDS: [HoldKind; 7] =
    [HoldKind::Book, HoldKind::Cup, HoldKind::Umbrella, HoldKind::Balloon, HoldKind::Flower, HoldKind::Phone, HoldKind::IceCream];

impl HoldKind {
    pub fn key(self) -> &'static str {
        match self {
            HoldKind::Book => "book",
            HoldKind::Cup => "cup",
            HoldKind::Umbrella => "umbrella",
            HoldKind::Balloon => "balloon",
            HoldKind::Flower => "flower",
            HoldKind::Phone => "phone",
            HoldKind::IceCream => "icecream",
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            HoldKind::Book => "kitap",
            HoldKind::Cup => "fincan",
            HoldKind::Umbrella => "şemsiye",
            HoldKind::Balloon => "balon",
            HoldKind::Flower => "çiçek",
            HoldKind::Phone => "telefon",
            HoldKind::IceCream => "dondurma",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Beard {
    None,
    Mustache,
    Full,
}

impl Beard {
    pub fn key(self) -> &'static str {
        match self {
            Beard::None => "none",
            Beard::Mustache => "mustache",
            Beard::Full => "full",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Seat {
    None,
    Chair,
    Bench,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Person {
    pub female: bool,
    pub age: Age,
    pub sitting: bool,
    pub seat: Seat,
    pub skin: u8,
    pub hair: Hair,
    pub style: Style,
    pub hat: Option<Hat>,
    pub glasses: Glasses,
    pub top: Tone,
    pub top_kind: TopKind,
    pub pattern: Pattern,
    pub bottom: Tone,
    pub bottom_kind: BottomKind,
    pub bag: Option<(BagKind, Tone)>,
    pub hold: Option<(HoldKind, Tone)>,
    pub beard: Beard,
}

impl Person {
    /// Hair colour is something a viewer could see and name (not bald, not hidden under a hat).
    pub fn hair_visible(&self) -> bool {
        self.style != Style::Bald && (self.hat.is_none() || matches!(self.style, Style::Long | Style::Ponytail | Style::Curly))
    }
}

/// Body measures at a given scale (canvas units).
#[derive(Clone, Copy, Debug)]
pub struct Geo {
    /// Hat zone above the head.
    pub hz: f64,
    /// Head radius.
    pub r: f64,
    pub neck: f64,
    /// Torso length and width.
    pub tl: f64,
    pub tw: f64,
    /// Leg length (standing).
    pub ll: f64,
    /// Box width.
    pub w: f64,
    pub s: f64,
}

pub fn geo(age: Age, s: f64) -> Geo {
    match age {
        Age::Child => Geo { hz: 28.0 * s, r: 27.0 * s, neck: 5.0 * s, tl: 78.0 * s, tw: 62.0 * s, ll: 92.0 * s, w: 100.0 * s, s },
        _ => Geo { hz: 32.0 * s, r: 30.0 * s, neck: 8.0 * s, tl: 112.0 * s, tw: 76.0 * s, ll: 140.0 * s, w: 118.0 * s, s },
    }
}

/// Person box with feet (or the floor under the seat) at `foot` and centre `cx`.
pub fn person_box(p: &Person, s: f64, foot: f64, cx: f64) -> Rect {
    let g = geo(p.age, s);
    let upper = g.hz + 2.0 * g.r + g.neck + g.tl;
    if p.sitting {
        let hip = foot - SEAT_H * s;
        let legs = (g.ll * 0.62).min(SEAT_H * s);
        Rect::new(cx - g.w / 2.0, hip - upper, g.w, upper + legs)
    } else {
        let h = upper + g.ll + 10.0 * s;
        Rect::new(cx - g.w / 2.0, foot - h, g.w, h)
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Parts {
    pub hat: Rect,
    pub head: Rect,
    pub hair: Rect,
    pub face: Rect,
    pub torso: Rect,
    pub legs: Rect,
    pub hand: Rect,
    pub bag: Rect,
    pub seat: Option<Rect>,
}

/// Part boxes of a person drawn in box `b` at scale `s`. The painter draws inside these.
pub fn parts(p: &Person, s: f64, b: &Rect) -> Parts {
    let g = geo(p.age, s);
    let cx = b.cx();
    let top = b.y;
    let head = Rect::new(cx - g.r, top + g.hz, 2.0 * g.r, 2.0 * g.r);
    let hat = Rect::new(cx - 1.5 * g.r, top, 3.0 * g.r, g.hz + 0.95 * g.r);
    let hair = Rect::new(cx - 1.25 * g.r, top + g.hz - 0.15 * g.r, 2.5 * g.r, 2.9 * g.r);
    let face = Rect::new(cx - 0.85 * g.r, top + g.hz + 0.6 * g.r, 1.7 * g.r, 0.75 * g.r);
    let ty = top + g.hz + 2.0 * g.r + g.neck;
    let torso = Rect::new(cx - g.tw / 2.0, ty, g.tw, g.tl);
    let hip = ty + g.tl;
    let legs = Rect::new(cx - g.tw * 0.42, hip, g.tw * 0.84, (b.y1() - hip).max(1.0));
    // Right hand (viewer's right) holds things; left side carries a handbag.
    let hx = cx + g.tw / 2.0 + 9.0 * s;
    let hy = ty + g.tl * 0.92;
    let hand = match p.hold.map(|h| h.0) {
        Some(HoldKind::Balloon) => {
            let by = top + g.hz + 0.4 * g.r - 21.0 * s;
            Rect::new(hx - 20.0 * s, by, 46.0 * s, hy + 14.0 * s - by)
        }
        Some(HoldKind::Umbrella) => Rect::new(hx - 14.0 * s, hy - 46.0 * s, 28.0 * s, 112.0 * s),
        _ => Rect::new(hx - 26.0 * s, hy - 50.0 * s, 52.0 * s, 76.0 * s),
    };
    let bag = match p.bag.map(|b| b.0) {
        Some(BagKind::Handbag) => {
            let lx = cx - g.tw / 2.0 - 9.0 * s;
            Rect::new(lx - 20.0 * s, hy - 18.0 * s, 38.0 * s, 46.0 * s)
        }
        _ => Rect::new(cx - g.tw / 2.0 - 17.0 * s, ty + 4.0 * s, 28.0 * s, g.tl * 0.8),
    };
    let seat = (p.seat == Seat::Chair).then(|| {
        let back = g.tl * 0.62;
        Rect::new(cx - g.tw * 0.62, hip - back, g.tw * 1.24, back + SEAT_H * s)
    });
    Parts { hat, head, hair, face, torso, legs, hand, bag, seat }
}

// ------------------------------------------------------------------------------------------ items

#[derive(Clone, Debug, PartialEq)]
pub struct Item {
    pub id: u32,
    pub kind: Kind,
    /// 0..=2 floor rows (back → front), `WALL` for wall items.
    pub row: u8,
    pub b: Rect,
    pub s: f64,
    pub tone: Tone,
    pub tone2: Tone,
    pub var: u8,
    pub on: Option<u32>,
    pub z: f64,
    pub person: Option<Person>,
}

impl Item {
    /// Support surface (where objects stand) for tables, counters and benches.
    pub fn surface(&self) -> Option<f64> {
        match self.kind {
            Kind::Table => Some(self.b.y + if self.var == 0 { 14.0 } else { 10.0 } * self.s),
            Kind::Counter => Some(self.b.y + 12.0 * self.s),
            Kind::Bench => Some(self.b.y1() - SEAT_H * self.s),
            _ => None,
        }
    }
    pub fn parts(&self) -> Option<Parts> {
        self.person.as_ref().map(|p| parts(p, self.s, &self.b))
    }
    /// The part that must stay visible: a person's upper body (hat to hips, hand, bag), a table's
    /// top, a whole object or animal. Backdrops have none.
    pub fn important(&self) -> Option<Rect> {
        if self.kind.backdrop() || self.kind.is_wall() {
            return None;
        }
        Some(match self.kind {
            Kind::Person => {
                let pp = self.parts()?;
                Rect::new(self.b.x, self.b.y, self.b.w, pp.torso.y1() - self.b.y).union(&pp.hand).union(&pp.bag)
            }
            Kind::Table | Kind::Counter | Kind::Bench => Rect::new(self.b.x, self.b.y, self.b.w, self.b.h * 0.35),
            _ => self.b,
        })
    }

    /// The opaque part that hides what is behind (a parasol's canopy, not its pole).
    pub fn occluder(&self) -> Rect {
        match self.kind {
            Kind::Parasol => Rect::new(self.b.x, self.b.y, self.b.w, self.b.h * 0.24),
            Kind::Lamp => Rect::new(self.b.cx() - self.b.w * 0.4, self.b.y, self.b.w * 0.8, self.b.h * 0.22),
            _ => self.full_box(),
        }
    }

    /// Box including every part (held balloons, handbags, chairs).
    pub fn full_box(&self) -> Rect {
        match self.parts() {
            Some(pp) => {
                let mut r = self.b.union(&pp.hand).union(&pp.bag);
                if let Some(seat) = pp.seat {
                    r = r.union(&seat);
                }
                r
            }
            None => self.b,
        }
    }

    pub fn json(&self) -> Value {
        let mut m = Map::new();
        m.insert("id".into(), json!(self.id));
        m.insert("k".into(), json!(self.kind.key()));
        m.insert("r".into(), json!(self.row));
        m.insert("x".into(), json!(r1(self.b.x)));
        m.insert("y".into(), json!(r1(self.b.y)));
        m.insert("w".into(), json!(r1(self.b.w)));
        m.insert("h".into(), json!(r1(self.b.h)));
        m.insert("s".into(), json!(r1(self.s * 100.0) / 100.0));
        m.insert("t".into(), json!(self.tone.key()));
        m.insert("t2".into(), json!(self.tone2.key()));
        m.insert("v".into(), json!(self.var));
        if let Some(sy) = self.surface() {
            m.insert("sy".into(), json!(r1(sy)));
        }
        if let Some(on) = self.on {
            m.insert("on".into(), json!(on));
        }
        if let Some(p) = &self.person {
            let pp = parts(p, self.s, &self.b);
            let mut parts_m = Map::new();
            parts_m.insert("hat".into(), pp.hat.json());
            parts_m.insert("head".into(), pp.head.json());
            parts_m.insert("hair".into(), pp.hair.json());
            parts_m.insert("face".into(), pp.face.json());
            parts_m.insert("torso".into(), pp.torso.json());
            parts_m.insert("legs".into(), pp.legs.json());
            parts_m.insert("hand".into(), pp.hand.json());
            parts_m.insert("bag".into(), pp.bag.json());
            if let Some(seat) = pp.seat {
                parts_m.insert("seat".into(), seat.json());
            }
            m.insert(
                "p".into(),
                json!({
                    "g": if p.female { "f" } else { "m" },
                    "age": match p.age { Age::Child => "child", Age::Adult => "adult", Age::Elder => "elder" },
                    "sit": p.sitting,
                    "seat": match p.seat { Seat::None => "none", Seat::Chair => "chair", Seat::Bench => "bench" },
                    "skin": p.skin,
                    "hair": p.hair.key(),
                    "hs": p.style.key(),
                    "hat": p.hat.map(|h| json!({"k": h.kind.key(), "t": h.tone.key(), "m": h.mat.key()})),
                    "gl": p.glasses.key(),
                    "top": p.top.key(),
                    "tk": p.top_kind.key(),
                    "pat": p.pattern.key(),
                    "bot": p.bottom.key(),
                    "bk": p.bottom_kind.key(),
                    "bag": p.bag.map(|(k, t)| json!({"k": k.key(), "t": t.key()})),
                    "hold": p.hold.map(|(k, t)| json!({"k": k.key(), "t": t.key()})),
                    "beard": p.beard.key(),
                    "parts": Value::Object(parts_m),
                }),
            );
        }
        Value::Object(m)
    }
}

// ----------------------------------------------------------------------------------------- scene

#[derive(Clone, Debug, PartialEq)]
pub struct Scene {
    pub no: u32,
    pub setting: Setting,
    pub wall: u8,
    pub floor: u8,
    pub bg: u8,
    /// In draw order (back → front).
    pub items: Vec<Item>,
}

impl Scene {
    pub fn get(&self, id: u32) -> Option<&Item> {
        self.items.iter().find(|i| i.id == id)
    }
    pub fn get_mut(&mut self, id: u32) -> Option<&mut Item> {
        self.items.iter_mut().find(|i| i.id == id)
    }
    pub fn people(&self) -> impl Iterator<Item = (&Item, &Person)> {
        self.items.iter().filter_map(|i| i.person.as_ref().map(|p| (i, p)))
    }
    pub fn count(&self, k: Kind) -> usize {
        self.items.iter().filter(|i| i.kind == k).count()
    }
    /// Items standing on `id`.
    pub fn children(&self, id: u32) -> impl Iterator<Item = &Item> {
        self.items.iter().filter(move |i| i.on == Some(id))
    }

    /// Placement test (see the module docs). `exempt` items (and items standing on them) are
    /// ignored; so is `ignore` (the item being moved).
    pub fn fits(&self, probe: &Item, exempt: &[u32], ignore: Option<u32>) -> bool {
        let b = probe.full_box();
        let row = probe.row;
        if b.x < 6.0 || b.x1() > W - 6.0 || b.y < 0.0 {
            return false;
        }
        let mine = probe.important();
        let my_occ = probe.occluder();
        for it in &self.items {
            if it.row == WALL || Some(it.id) == ignore || exempt.contains(&it.id) {
                continue;
            }
            if it.on.is_some_and(|o| exempt.contains(&o) || Some(o) == ignore) {
                continue;
            }
            if it.row == row {
                let ob = it.full_box();
                let gap = 8.0 * ROW_SCALE[row as usize];
                if b.x < ob.x1() + gap && ob.x < b.x1() + gap && b.y < ob.y1() && ob.y < b.y1() {
                    return false;
                }
            } else if it.row < row {
                // `it` is behind: we must not hide its important part.
                if let Some(imp) = it.important() {
                    if my_occ.inter(&imp) / imp.area().max(1.0) > OCCLUSION {
                        return false;
                    }
                }
            } else if let Some(imp) = mine {
                // `it` is in front: it must not hide our important part.
                if it.occluder().inter(&imp) / imp.area().max(1.0) > OCCLUSION {
                    return false;
                }
            }
        }
        true
    }

    /// Sort into draw order.
    pub fn sort(&mut self) {
        self.items.sort_by(|a, b| a.z.partial_cmp(&b.z).unwrap_or(std::cmp::Ordering::Equal).then(a.id.cmp(&b.id)));
    }

    pub fn json(&self, key: &str) -> Value {
        json!({
            "no": self.no,
            "key": key,
            "set": self.setting.key(),
            "w": W,
            "h": H,
            "wall": self.wall,
            "floor": self.floor,
            "bg": self.bg,
            "items": self.items.iter().map(|i| i.json()).collect::<Vec<_>>(),
        })
    }
}

// -------------------------------------------------------------------------------------- relations

/// A place relation a viewer would use ("masanın yanında", "bankta", "ağaçta", …).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Rel {
    Table,
    Bench,
    BenchSide,
    Shelf,
    Lamp,
    CounterFront,
    CounterSide,
    Plant,
    Tree,
    Parasol,
    Window,
    UnderTable,
    OnBench,
    InTree,
    OnLamp,
    Ground,
}

pub const PERSON_RELS: [Rel; 11] = [
    Rel::Table,
    Rel::Bench,
    Rel::BenchSide,
    Rel::Shelf,
    Rel::Lamp,
    Rel::CounterFront,
    Rel::CounterSide,
    Rel::Plant,
    Rel::Tree,
    Rel::Parasol,
    Rel::Window,
];
pub const ANIMAL_RELS: [Rel; 5] = [Rel::UnderTable, Rel::OnBench, Rel::InTree, Rel::OnLamp, Rel::Ground];

impl Rel {
    /// Locative phrase.
    pub fn phrase(self) -> &'static str {
        match self {
            Rel::Table => "masanın yanında",
            Rel::Bench => "bankta",
            Rel::BenchSide => "bankın yanında",
            Rel::Shelf => "rafın yanında",
            Rel::Lamp => "lambanın yanında",
            Rel::CounterFront => "tezgâhın önünde",
            Rel::CounterSide => "tezgâhın yanında",
            Rel::Plant => "saksının yanında",
            Rel::Tree => "ağacın altında",
            Rel::Parasol => "plaj şemsiyesinin altında",
            Rel::Window => "pencerenin önünde",
            Rel::UnderTable => "masanın altında",
            Rel::OnBench => "bankın üstünde",
            Rel::InTree => "ağaçta",
            Rel::OnLamp => "lambanın üstünde",
            Rel::Ground => "yerde",
        }
    }
    /// The furniture kind the relation needs (so distractors stay plausible for the setting).
    pub fn needs(self) -> Option<Kind> {
        match self {
            Rel::Table | Rel::UnderTable => Some(Kind::Table),
            Rel::Bench | Rel::BenchSide | Rel::OnBench => Some(Kind::Bench),
            Rel::Shelf => Some(Kind::Shelf),
            Rel::Lamp | Rel::OnLamp => Some(Kind::Lamp),
            Rel::CounterFront | Rel::CounterSide => Some(Kind::Counter),
            Rel::Plant => Some(Kind::Plant),
            Rel::Tree | Rel::InTree => Some(Kind::Tree),
            Rel::Parasol => Some(Kind::Parasol),
            Rel::Window => Some(Kind::Window),
            Rel::Ground => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Region {
    Left,
    Middle,
    Right,
}

impl Region {
    pub fn phrase(self) -> &'static str {
        match self {
            Region::Left => "solda",
            Region::Middle => "ortada",
            Region::Right => "sağda",
        }
    }
}

/// Left / middle / right third of the picture; `None` when the item stands too close to a border
/// between thirds to be named without doubt.
pub fn region(it: &Item) -> Option<Region> {
    let cx = it.b.cx();
    let third = W / 3.0;
    if (cx - third).abs() < 45.0 || (cx - 2.0 * third).abs() < 45.0 {
        None
    } else if cx < third {
        Some(Region::Left)
    } else if cx < 2.0 * third {
        Some(Region::Middle)
    } else {
        Some(Region::Right)
    }
}

/// Every place relation that is true for a person or animal.
pub fn rels(sc: &Scene, it: &Item) -> Vec<Rel> {
    let mut out = vec![];
    let s = it.s;
    if it.kind.is_animal() {
        let on = it.on.and_then(|o| sc.get(o));
        out.push(match on.map(|o| o.kind) {
            Some(Kind::Table) => Rel::UnderTable,
            Some(Kind::Bench) => Rel::OnBench,
            Some(Kind::Tree) => Rel::InTree,
            Some(Kind::Lamp) => Rel::OnLamp,
            _ => Rel::Ground,
        });
        return out;
    }
    if it.kind != Kind::Person {
        return out;
    }
    let cx = it.b.cx();
    for f in &sc.items {
        if f.id == it.id {
            continue;
        }
        if f.kind == Kind::Window {
            if it.row == 0 && cx > f.b.x && cx < f.b.x1() {
                out.push(Rel::Window);
            }
            continue;
        }
        if Some(f.id) == it.on {
            if f.kind == Kind::Bench {
                out.push(Rel::Bench);
            }
            continue;
        }
        if f.kind == Kind::Counter && f.row + 1 == it.row && cx > f.b.x && cx < f.b.x1() {
            out.push(Rel::CounterFront);
            continue;
        }
        if f.row != it.row {
            continue;
        }
        let gap = it.b.gap_x(&f.b);
        let rel = match f.kind {
            Kind::Table if gap <= 30.0 * s => Some(Rel::Table),
            Kind::Bench if gap <= 30.0 * s => Some(Rel::BenchSide),
            Kind::Shelf if gap <= 40.0 * s => Some(Rel::Shelf),
            Kind::Lamp if gap <= 40.0 * s => Some(Rel::Lamp),
            Kind::Counter if gap <= 40.0 * s => Some(Rel::CounterSide),
            Kind::Plant if gap <= 30.0 * s => Some(Rel::Plant),
            Kind::Tree if (cx - f.b.cx()).abs() < f.b.w * 0.38 => Some(Rel::Tree),
            Kind::Parasol if (cx - f.b.cx()).abs() < f.b.w * 0.42 => Some(Rel::Parasol),
            _ => None,
        };
        if let Some(r) = rel {
            if !out.contains(&r) {
                out.push(r);
            }
        }
    }
    out
}

// ------------------------------------------------------------------------------------- generation

#[derive(Clone, Debug, PartialEq)]
pub struct SceneParams {
    pub people: (usize, usize),
    /// 0..1: how much furniture and how many objects.
    pub clutter: f64,
    /// Chance that a person wears a hat.
    pub hat_p: f64,
    pub animals: (usize, usize),
}

/// 6-digit scene number from a seed.
pub fn scene_no(seed: u64) -> u32 {
    let mut h = seed ^ (seed >> 29);
    h = h.wrapping_mul(0xBF58_476D_1CE4_E5B9);
    h ^= h >> 32;
    100_000 + (h % 900_000) as u32
}

struct Furn {
    kind: Kind,
    var: u8,
    n: (u8, u8),
    rows: &'static [u8],
}

const fn fu(kind: Kind, var: u8, n: (u8, u8), rows: &'static [u8]) -> Furn {
    Furn { kind, var, n, rows }
}

fn furniture_plan(set: Setting) -> Vec<Furn> {
    use Kind::*;
    match set {
        Setting::Kafe => vec![
            fu(Counter, 0, (0, 1), &[0]),
            fu(Shelf, 0, (0, 1), &[0]),
            fu(Table, 0, (2, 3), &[0, 1, 2]),
            fu(Plant, 0, (1, 2), &[0, 1, 2]),
            fu(Lamp, 0, (0, 1), &[0]),
        ],
        Setting::Park => vec![
            fu(Tree, 0, (1, 3), &[0]),
            fu(Bench, 0, (1, 2), &[0, 1, 2]),
            fu(Lamp, 1, (0, 2), &[0]),
            fu(Plant, 3, (1, 2), &[0, 1, 2]),
        ],
        Setting::Oda => vec![
            fu(Shelf, 0, (1, 1), &[0]),
            fu(Table, 1, (1, 1), &[1, 2]),
            fu(Lamp, 0, (1, 1), &[0, 1]),
            fu(Plant, 0, (1, 2), &[0, 1, 2]),
        ],
        Setting::Sokak => vec![
            fu(Tree, 0, (0, 1), &[0]),
            fu(Lamp, 1, (1, 2), &[0]),
            fu(Bench, 0, (0, 1), &[0, 1]),
            fu(Plant, 0, (1, 2), &[0, 1, 2]),
        ],
        Setting::Plaj => vec![fu(Parasol, 0, (1, 3), &[0, 1, 2]), fu(Table, 0, (0, 1), &[1, 2])],
        Setting::Ofis => vec![
            fu(Shelf, 0, (1, 1), &[0]),
            fu(Table, 1, (2, 3), &[0, 1, 2]),
            fu(Plant, 0, (1, 2), &[0, 1, 2]),
            fu(Lamp, 0, (0, 1), &[0]),
        ],
        Setting::Mutfak => vec![
            fu(Counter, 0, (1, 1), &[0]),
            fu(Shelf, 0, (0, 1), &[0]),
            fu(Table, 1, (1, 1), &[1, 2]),
            fu(Plant, 0, (0, 1), &[0, 1, 2]),
        ],
        Setting::Istasyon => vec![
            fu(Bench, 1, (1, 2), &[0, 1, 2]),
            fu(Lamp, 1, (0, 1), &[0]),
            fu(Plant, 0, (0, 1), &[0, 1, 2]),
        ],
    }
}

/// (windows, clocks, frames) ranges per setting.
fn wall_plan(set: Setting) -> [(u8, u8); 3] {
    match set {
        Setting::Kafe => [(1, 2), (0, 1), (0, 1)],
        Setting::Oda => [(1, 2), (0, 1), (1, 2)],
        Setting::Sokak => [(2, 3), (0, 1), (0, 0)],
        Setting::Ofis => [(1, 2), (1, 1), (0, 1)],
        Setting::Mutfak => [(1, 1), (0, 1), (0, 1)],
        Setting::Istasyon => [(0, 1), (1, 1), (0, 1)],
        _ => [(0, 0), (0, 0), (0, 0)],
    }
}

/// Every kind a scene of this setting can contain (for plausible quiz distractors).
pub fn possible_kinds(set: Setting) -> Vec<Kind> {
    let mut v: Vec<Kind> = furniture_plan(set).iter().filter(|f| f.n.1 > 0).map(|f| f.kind).collect();
    let wall = wall_plan(set);
    for (k, n) in [Kind::Window, Kind::Clock, Kind::Frame].into_iter().zip(wall) {
        if n.1 > 0 {
            v.push(k);
        }
    }
    v.extend_from_slice(table_objects(set));
    v.extend_from_slice(ground_objects(set));
    v.extend_from_slice(setting_animals(set));
    v.extend_from_slice(&[Kind::Cup, Kind::Book, Kind::Bag]);
    v.sort_by_key(|k| *k as u8);
    v.dedup();
    v
}

pub fn table_objects(set: Setting) -> &'static [Kind] {
    use Kind::*;
    match set {
        Setting::Kafe => &[Cup, Cup, Book, Vase, Fruit, Bottle],
        Setting::Oda => &[Book, Cup, Vase, Fruit, Laptop],
        Setting::Plaj => &[Cup, Bottle, Fruit, Book],
        Setting::Ofis => &[Laptop, Cup, Book, Bottle, Vase],
        Setting::Mutfak => &[Fruit, Cup, Bottle, Vase, Cup],
        _ => &[Cup, Book, Bottle],
    }
}

pub fn ground_objects(set: Setting) -> &'static [Kind] {
    use Kind::*;
    match set {
        Setting::Kafe => &[Bag, Umbrella],
        Setting::Park => &[Ball, Bag, Book, Umbrella],
        Setting::Oda => &[Ball, Bag],
        Setting::Sokak => &[Bag, Umbrella, Ball],
        Setting::Plaj => &[Ball, Bag, Book, Bottle],
        Setting::Ofis => &[Bag],
        Setting::Mutfak => &[Bag],
        Setting::Istasyon => &[Bag, Umbrella, Book],
    }
}

pub fn setting_animals(set: Setting) -> &'static [Kind] {
    use Kind::*;
    match set {
        Setting::Kafe => &[Cat, Dog],
        Setting::Park => &[Dog, Bird, Cat, Bird],
        Setting::Oda => &[Cat, Dog],
        Setting::Sokak => &[Dog, Cat, Bird],
        Setting::Plaj => &[Bird, Dog, Bird],
        Setting::Ofis => &[Cat],
        Setting::Mutfak => &[Cat],
        Setting::Istasyon => &[Bird, Dog, Bird],
    }
}

/// Tones an item of this kind may take (first tone; second tone choices in `tone2_choices`).
pub fn tone_choices(kind: Kind) -> &'static [Col] {
    use Col::*;
    match kind {
        Kind::Window => &[Kirmizi, Mavi, Sari, Yesil, Beyaz, Mor, Pembe],
        Kind::Clock => &[Siyah, Kirmizi, Beyaz, Kahve, Yesil],
        Kind::Frame => &[Mavi, Kirmizi, Yesil, Sari, Turuncu, Mor],
        Kind::Tree => &[Yesil],
        Kind::Shelf => &[Kahve, Beyaz],
        Kind::Lamp => &[Sari, Beyaz, Yesil, Kirmizi, Turuncu],
        Kind::Plant => &[Turuncu, Beyaz, Mavi, Siyah],
        Kind::Counter => &[Kahve, Beyaz, Mavi, Yesil, Kirmizi],
        Kind::Table => &[Kahve, Beyaz, Siyah, Gri],
        Kind::Bench => &[Kahve, Yesil, Kirmizi, Mavi],
        Kind::Parasol => &[Kirmizi, Mavi, Sari, Yesil, Turuncu],
        Kind::Cup => &[Beyaz, Kirmizi, Mavi, Sari, Yesil, Turuncu, Pembe],
        Kind::Book => &[Kirmizi, Mavi, Yesil, Sari, Mor, Turuncu, Kahve],
        Kind::Bag => &[Siyah, Kahve, Kirmizi, Mavi, Yesil, Sari, Mor, Turuncu],
        Kind::Umbrella => &[Kirmizi, Mavi, Siyah, Sari, Yesil, Mor],
        Kind::Ball => &[Kirmizi, Mavi, Sari, Turuncu, Yesil, Beyaz],
        Kind::Fruit => &[Beyaz, Mavi, Kahve, Yesil],
        Kind::Vase => &[Mavi, Beyaz, Kirmizi, Yesil, Sari],
        Kind::Bottle => &[Yesil, Mavi, Kahve],
        Kind::Laptop => &[Gri, Siyah, Beyaz],
        Kind::Cat => &[Siyah, Beyaz, Gri, Turuncu],
        Kind::Dog => &[Kahve, Sari, Siyah, Beyaz],
        Kind::Bird => &[Mavi, Sari, Kirmizi, Yesil],
        Kind::Person => &COLS,
    }
}

pub fn tone2_choices(kind: Kind) -> &'static [Col] {
    use Col::*;
    match kind {
        Kind::Frame => &[Kahve, Siyah, Beyaz, Sari],
        Kind::Plant | Kind::Vase => &[Kirmizi, Sari, Pembe, Beyaz, Mor, Turuncu],
        Kind::Parasol | Kind::Ball => &[Beyaz],
        _ => &[Beyaz],
    }
}

pub const FRUITS: [&str; 5] = ["elma", "portakal", "muz", "armut", "üzüm"];

/// Item size at scale `s` (for the variant `var`).
pub fn item_size(kind: Kind, var: u8, s: f64) -> (f64, f64) {
    let (w, h) = match kind {
        Kind::Window => return (190.0, 230.0),
        Kind::Clock => return (88.0, 88.0),
        Kind::Frame => return (130.0, 96.0),
        Kind::Tree => (280.0, 460.0),
        Kind::Shelf => (170.0, 310.0),
        Kind::Lamp => {
            if var == 1 {
                (70.0, 400.0)
            } else {
                (80.0, 300.0)
            }
        }
        Kind::Plant => match var {
            2 => (90.0, 190.0),
            3 => (120.0, 90.0),
            _ => (84.0, 130.0),
        },
        Kind::Counter => (330.0, 150.0),
        Kind::Table => {
            if var == 0 {
                (190.0, 118.0)
            } else {
                (230.0, 112.0)
            }
        }
        Kind::Bench => (290.0, 170.0),
        Kind::Parasol => (250.0, 440.0),
        Kind::Cup => (30.0, 28.0),
        Kind::Book => (50.0, 16.0),
        Kind::Bag => (56.0, 58.0),
        Kind::Umbrella => (26.0, 100.0),
        Kind::Ball => (46.0, 46.0),
        Kind::Fruit => (76.0, 44.0),
        Kind::Vase => (38.0, 76.0),
        Kind::Bottle => (22.0, 62.0),
        Kind::Laptop => (74.0, 48.0),
        Kind::Cat => {
            if var == 1 {
                (86.0, 40.0)
            } else {
                (66.0, 62.0)
            }
        }
        Kind::Dog => (104.0, 84.0),
        Kind::Bird => (34.0, 30.0),
        Kind::Person => (150.0, 350.0),
    };
    (w * s, h * s)
}

/// A not-yet-placed item, for placement tests.
pub fn probe(kind: Kind, row: u8, b: Rect, s: f64, var: u8, on: Option<u32>, person: Option<Person>) -> Item {
    let t = Tone::of(Col::Beyaz);
    Item { id: 0, kind, row, b, s, tone: t, tone2: t, var, on, z: 0.0, person }
}

struct Gen {
    rng: Rng,
    sc: Scene,
    next: u32,
}

/// Base draw order inside a row.
fn layer(kind: Kind) -> f64 {
    if kind.backdrop() {
        0.0
    } else if kind.is_furniture() {
        100.0
    } else if kind == Kind::Person {
        200.0
    } else {
        300.0
    }
}

impl Gen {
    #[allow(clippy::too_many_arguments)]
    fn push(&mut self, kind: Kind, row: u8, b: Rect, s: f64, tone: Tone, tone2: Tone, var: u8, on: Option<u32>, person: Option<Person>) -> u32 {
        let id = self.next;
        self.next += 1;
        let z = if row == WALL {
            -1000.0 + id as f64
        } else if let Some(sup) = on.and_then(|o| self.sc.get(o)) {
            sup.z + 1.0 + id as f64 * 0.001
        } else {
            row as f64 * 10_000.0 + layer(kind) + b.cx() * 0.01
        };
        self.sc.items.push(Item { id, kind, row, b, s, tone, tone2, var, on, z, person });
        id
    }

    fn tone(&mut self, kind: Kind) -> Tone {
        Tone::of(*self.rng.pick(tone_choices(kind)))
    }

    fn tone2(&mut self, kind: Kind) -> Tone {
        Tone::of(*self.rng.pick(tone2_choices(kind)))
    }

    fn count(&mut self, n: (u8, u8), clutter: f64) -> usize {
        let span = (n.1 - n.0) as f64;
        n.0 as usize + (span * (0.35 * self.rng.f64() + 0.65 * clutter)).round() as usize
    }

    fn wall_items(&mut self, clutter: f64) {
        let plan = wall_plan(self.sc.setting);
        let kinds = [Kind::Window, Kind::Clock, Kind::Frame];
        let mut boxes: Vec<Rect> = vec![];
        for (k, n) in kinds.iter().zip(plan) {
            let count = self.count(n, clutter);
            for _ in 0..count {
                for _ in 0..30 {
                    let (mut w, mut h) = item_size(*k, 0, 1.0);
                    if self.sc.setting == Setting::Sokak && *k == Kind::Window {
                        w = 150.0;
                        h = 170.0;
                    }
                    if self.sc.setting == Setting::Istasyon && *k == Kind::Clock {
                        w = 110.0;
                        h = 110.0;
                    }
                    let y = match k {
                        Kind::Window => 86.0,
                        Kind::Clock => 58.0 + self.rng.f64() * 30.0,
                        _ => 110.0 + self.rng.f64() * 40.0,
                    };
                    let x = 30.0 + self.rng.f64() * (W - 60.0 - w);
                    let b = Rect::new(x, y, w, h);
                    if boxes.iter().any(|o| b.inflate(24.0).inter(o) > 0.0) {
                        continue;
                    }
                    boxes.push(b);
                    let var = match k {
                        Kind::Window => (self.rng.chance(0.7) as u8) | ((self.rng.below(2) as u8) << 1),
                        Kind::Clock => 1 + self.rng.below(12) as u8,
                        _ => self.rng.below(3) as u8,
                    };
                    let (t, t2) = (self.tone(*k), self.tone2(*k));
                    self.push(*k, WALL, b, 1.0, t, t2, var, None, None);
                    break;
                }
            }
        }
    }

    fn furniture(&mut self, clutter: f64) {
        for f in furniture_plan(self.sc.setting) {
            let n = self.count(f.n, clutter);
            for _ in 0..n {
                for _ in 0..40 {
                    let row = *self.rng.pick(f.rows);
                    let s = ROW_SCALE[row as usize];
                    let (w, h) = item_size(f.kind, f.var, s);
                    let x = 10.0 + self.rng.f64() * (W - 20.0 - w);
                    let b = Rect::new(x, ROW_FOOT[row as usize] - h, w, h);
                    let var = if f.kind == Kind::Plant && f.var == 0 { self.rng.below(3) as u8 } else { f.var };
                    let (w, h) = item_size(f.kind, var, s);
                    let b = Rect::new(b.x, ROW_FOOT[row as usize] - h, w, h);
                    if !self.sc.fits(&probe(f.kind, row, b, s, var, None, None), &[], None) {
                        continue;
                    }
                    let (t, t2) = (self.tone(f.kind), self.tone2(f.kind));
                    self.push(f.kind, row, b, s, t, t2, var, None, None);
                    break;
                }
            }
        }
    }

    fn people(&mut self, n: usize, hat_p: f64) {
        for _ in 0..n {
            let person = gen_person(&mut self.rng, self.sc.setting, hat_p);
            self.place_person(person);
        }
    }

    /// Try anchors (table, bench, near furniture, window, free) until one fits.
    fn place_person(&mut self, mut p: Person) -> bool {
        for attempt in 0..60 {
            let anchor = self.rng.below(10);
            let furniture: Vec<Item> = self.sc.items.iter().filter(|i| i.row != WALL && i.kind.is_furniture()).cloned().collect();
            let pick_f = |g: &mut Gen, k: &[Kind]| -> Option<Item> {
                let c: Vec<&Item> = furniture.iter().filter(|i| k.contains(&i.kind)).collect();
                (!c.is_empty()).then(|| c[g.rng.below(c.len())].clone())
            };
            // Late attempts fall back to free placement.
            let anchor = if attempt > 40 { 9 } else { anchor };
            let mut cand: Option<(Rect, u8, Option<u32>, Vec<u32>)> = None;
            match anchor {
                0..=2 => {
                    if let Some(t) = pick_f(self, &[Kind::Table]) {
                        let sit = self.rng.chance(0.7);
                        p.sitting = sit;
                        p.seat = if sit { Seat::Chair } else { Seat::None };
                        let pb = person_box(&p, t.s, ROW_FOOT[t.row as usize], 0.0);
                        let left = self.rng.chance(0.5);
                        let cx = if left { t.b.x - pb.w / 2.0 - 2.0 } else { t.b.x1() + pb.w / 2.0 + 2.0 };
                        cand = Some((person_box(&p, t.s, ROW_FOOT[t.row as usize], cx), t.row, None, vec![]));
                    }
                }
                3..=4 => {
                    if let Some(bn) = pick_f(self, &[Kind::Bench]) {
                        p.sitting = true;
                        p.seat = Seat::Bench;
                        let slot = if self.rng.chance(0.5) { 0.22 } else { 0.78 };
                        let cx = bn.b.x + bn.b.w * slot;
                        cand = Some((person_box(&p, bn.s, ROW_FOOT[bn.row as usize], cx), bn.row, Some(bn.id), vec![bn.id]));
                    }
                }
                5..=6 => {
                    if let Some(f) = pick_f(self, &[Kind::Shelf, Kind::Lamp, Kind::Counter, Kind::Plant, Kind::Tree, Kind::Parasol, Kind::Bench]) {
                        p.sitting = false;
                        p.seat = Seat::None;
                        let pb = person_box(&p, f.s, ROW_FOOT[f.row as usize], 0.0);
                        let cx = match f.kind {
                            Kind::Tree | Kind::Parasol => f.b.cx() + (self.rng.f64() - 0.5) * f.b.w * 0.5,
                            Kind::Counter if self.rng.chance(0.5) && f.row < 2 => {
                                // In front of the counter, one row nearer.
                                let row = f.row + 1;
                                let s = ROW_SCALE[row as usize];
                                let cx = f.b.x + f.b.w * (0.2 + 0.6 * self.rng.f64());
                                cand = Some((person_box(&p, s, ROW_FOOT[row as usize], cx), row, None, vec![]));
                                0.0
                            }
                            _ => {
                                if self.rng.chance(0.5) {
                                    f.b.x - pb.w / 2.0 - 4.0
                                } else {
                                    f.b.x1() + pb.w / 2.0 + 4.0
                                }
                            }
                        };
                        if cand.is_none() {
                            // People stand under trees and parasols (in front of the trunk / pole).
                            let ex = if matches!(f.kind, Kind::Tree | Kind::Parasol) { vec![f.id] } else { vec![] };
                            cand = Some((person_box(&p, f.s, ROW_FOOT[f.row as usize], cx), f.row, None, ex));
                        }
                    }
                }
                7 => {
                    let wins: Vec<Item> = self.sc.items.iter().filter(|i| i.kind == Kind::Window).cloned().collect();
                    if !wins.is_empty() {
                        let wi = &wins[self.rng.below(wins.len())];
                        p.sitting = false;
                        p.seat = Seat::None;
                        let cx = wi.b.cx() + (self.rng.f64() - 0.5) * wi.b.w * 0.4;
                        cand = Some((person_box(&p, ROW_SCALE[0], ROW_FOOT[0], cx), 0, None, vec![]));
                    }
                }
                _ => {
                    p.sitting = false;
                    p.seat = Seat::None;
                    // Rows 0 and 2 can share x (the front row only hides back-row legs).
                    let row = *self.rng.pick(&[0u8, 0, 1, 2, 2]);
                    let s = ROW_SCALE[row as usize];
                    let cx = 80.0 + self.rng.f64() * (W - 160.0);
                    cand = Some((person_box(&p, s, ROW_FOOT[row as usize], cx), row, None, vec![]));
                }
            }
            let Some((b, row, on, exempt)) = cand else { continue };
            let s = ROW_SCALE[row as usize];
            let probe = Item {
                id: 0,
                kind: Kind::Person,
                row,
                b,
                s,
                tone: p.top,
                tone2: p.top,
                var: 0,
                on,
                z: 0.0,
                person: Some(p),
            };
            if !self.sc.fits(&probe, &exempt, None) {
                continue;
            }
            // Two people on one bench must not share a slot.
            if let Some(bid) = on {
                if self.sc.children(bid).any(|c| c.full_box().inter(&probe.full_box()) > 0.0) {
                    continue;
                }
            }
            let tone = p.top;
            self.push(Kind::Person, row, b, s, tone, tone, 0, on, Some(p));
            return true;
        }
        false
    }

    fn objects(&mut self, clutter: f64) {
        let set = self.sc.setting;
        let supports: Vec<Item> =
            self.sc.items.iter().filter(|i| matches!(i.kind, Kind::Table | Kind::Counter)).cloned().collect();
        for sup in supports {
            let max = if sup.kind == Kind::Counter { 3 } else { 2 };
            let n = ((max as f64 + 0.6) * (0.35 + 0.65 * clutter) * self.rng.f64() + 0.6 * clutter).round() as usize;
            for _ in 0..n.min(max + 1) {
                let kind = *self.rng.pick(table_objects(set));
                self.place_on(&sup, kind);
            }
        }
        let benches: Vec<Item> = self.sc.items.iter().filter(|i| i.kind == Kind::Bench).cloned().collect();
        for bn in benches {
            if self.rng.chance(0.25 + 0.3 * clutter) {
                let kind = *self.rng.pick(&[Kind::Bag, Kind::Book, Kind::Cup]);
                self.place_on(&bn, kind);
            }
        }
        let ground = ((1.0 + 3.0 * clutter) * (0.5 + 0.5 * self.rng.f64())).round() as usize;
        for _ in 0..ground {
            let kind = *self.rng.pick(ground_objects(set));
            self.place_ground(kind);
        }
    }

    fn place_on(&mut self, sup: &Item, kind: Kind) -> bool {
        let Some(sy) = sup.surface() else { return false };
        let s = sup.s;
        let var = if kind == Kind::Fruit { self.rng.below(FRUITS.len()) as u8 } else { 0 };
        let (w, h) = item_size(kind, var, s);
        let (lo, hi) = if sup.kind == Kind::Bench {
            (sup.b.x + 20.0 * s, sup.b.x1() - 20.0 * s - w)
        } else {
            (sup.b.x + 12.0 * s, sup.b.x1() - 12.0 * s - w)
        };
        if hi <= lo {
            return false;
        }
        for _ in 0..12 {
            let x = lo + self.rng.f64() * (hi - lo);
            let b = Rect::new(x, sy - h, w, h);
            // Not on top of other objects or people on the same support.
            if self.sc.children(sup.id).any(|c| c.full_box().inflate(6.0 * s).inter(&b) > 0.0) {
                continue;
            }
            if !self.sc.fits(&probe(kind, sup.row, b, s, var, Some(sup.id), None), &[sup.id], None) {
                continue;
            }
            let (t, t2) = (self.tone(kind), self.tone2(kind));
            self.push(kind, sup.row, b, s, t, t2, var, Some(sup.id), None);
            return true;
        }
        false
    }

    fn place_ground(&mut self, kind: Kind) -> bool {
        for _ in 0..20 {
            let row = if kind.is_animal() { self.rng.below(3) as u8 } else { 1 + self.rng.below(2) as u8 };
            let s = ROW_SCALE[row as usize];
            let var = if kind == Kind::Cat { self.rng.below(2) as u8 } else { 0 };
            let (w, h) = item_size(kind, var, s);
            let x = 20.0 + self.rng.f64() * (W - 40.0 - w);
            let b = Rect::new(x, ROW_FOOT[row as usize] - h, w, h);
            if !self.sc.fits(&probe(kind, row, b, s, var, None, None), &[], None) {
                continue;
            }
            let (t, t2) = (self.tone(kind), self.tone2(kind));
            self.push(kind, row, b, s, t, t2, var, None, None);
            return true;
        }
        false
    }

    fn animals(&mut self, n: usize) {
        let set = self.sc.setting;
        for _ in 0..n {
            let kind = *self.rng.pick(setting_animals(set));
            let placed = match (kind, self.rng.below(3)) {
                (Kind::Cat, 0) => self.under_table(),
                (Kind::Cat | Kind::Bird, 1) => self.on_bench(kind),
                (Kind::Bird, 0) => self.in_tree_or_lamp(),
                _ => false,
            };
            if !placed {
                self.place_ground(kind);
            }
        }
    }

    fn under_table(&mut self) -> bool {
        let tables: Vec<Item> = self.sc.items.iter().filter(|i| i.kind == Kind::Table).cloned().collect();
        if tables.is_empty() {
            return false;
        }
        let t = tables[self.rng.below(tables.len())].clone();
        if self.sc.items.iter().any(|i| i.on == Some(t.id) && i.kind.is_animal()) {
            return false;
        }
        let s = t.s;
        let (w, h) = item_size(Kind::Cat, 1, s);
        let left = self.rng.chance(0.5);
        let x = if left { t.b.x + 8.0 * s } else { t.b.x1() - 8.0 * s - w };
        let b = Rect::new(x, t.b.y1() - h, w, h);
        if !self.sc.fits(&probe(Kind::Cat, t.row, b, s, 1, Some(t.id), None), &[t.id], None) {
            return false;
        }
        let tone = self.tone(Kind::Cat);
        self.push(Kind::Cat, t.row, b, s, tone, tone, 1, Some(t.id), None);
        true
    }

    fn on_bench(&mut self, kind: Kind) -> bool {
        let benches: Vec<Item> = self.sc.items.iter().filter(|i| i.kind == Kind::Bench).cloned().collect();
        if benches.is_empty() {
            return false;
        }
        let bn = benches[self.rng.below(benches.len())].clone();
        let s = bn.s;
        let (w, h) = item_size(kind, 0, s);
        let sy = bn.surface().unwrap_or(bn.b.y);
        for _ in 0..8 {
            let x = bn.b.x + 20.0 * s + self.rng.f64() * (bn.b.w - 40.0 * s - w);
            let y = if kind == Kind::Bird { bn.b.y - h + 4.0 * s } else { sy - h };
            let b = Rect::new(x, y, w, h);
            if self.sc.children(bn.id).any(|c| c.full_box().inflate(6.0 * s).inter(&b) > 0.0) {
                continue;
            }
            if !self.sc.fits(&probe(kind, bn.row, b, s, 0, Some(bn.id), None), &[bn.id], None) {
                continue;
            }
            let tone = self.tone(kind);
            self.push(kind, bn.row, b, s, tone, tone, 0, Some(bn.id), None);
            return true;
        }
        false
    }

    fn in_tree_or_lamp(&mut self) -> bool {
        let hosts: Vec<Item> =
            self.sc.items.iter().filter(|i| i.kind == Kind::Tree || (i.kind == Kind::Lamp && i.var == 1)).cloned().collect();
        if hosts.is_empty() {
            return false;
        }
        let hst = hosts[self.rng.below(hosts.len())].clone();
        if self.sc.children(hst.id).count() > 0 {
            return false;
        }
        let s = hst.s;
        let (w, h) = item_size(Kind::Bird, 0, s);
        let b = if hst.kind == Kind::Tree {
            let x = hst.b.x + hst.b.w * (0.22 + 0.5 * self.rng.f64());
            Rect::new(x, hst.b.y + hst.b.h * (0.25 + 0.15 * self.rng.f64()), w, h)
        } else {
            Rect::new(hst.b.cx() - w / 2.0, hst.b.y - h + 6.0 * s, w, h)
        };
        if !self.sc.fits(&probe(Kind::Bird, hst.row, b, s, 0, Some(hst.id), None), &[hst.id], None) {
            return false;
        }
        let tone = self.tone(Kind::Bird);
        self.push(Kind::Bird, hst.row, b, s, tone, tone, 0, Some(hst.id), None);
        true
    }
}

/// A random hat that suits the setting.
pub fn gen_hat(r: &mut Rng, set: Setting) -> Hat {
    use HatKind::*;
    let kind = match set {
        Setting::Plaj => *r.pick(&[Hasir, Hasir, Hasir, Fotr, Kasket, Bere]),
        Setting::Park => *r.pick(&[Fotr, Bere, Kasket, Hasir, Kasket, Bere]),
        _ => *r.pick(&[Fotr, Bere, Kasket, Fotr, Bere, Kasket, Hasir]),
    };
    let mat = match kind {
        Fotr => *r.pick(&[Mat::Kumas, Mat::Kumas, Mat::Deri]),
        Bere => *r.pick(&[Mat::Yun, Mat::Yun, Mat::Kumas]),
        Kasket => *r.pick(&[Mat::Kumas, Mat::Deri, Mat::Yun]),
        Hasir => Mat::Hasir,
    };
    let c = match mat {
        Mat::Deri => *r.pick(&[Col::Siyah, Col::Kahve, Col::Kirmizi]),
        Mat::Hasir => Col::Sari,
        _ => *r.pick(&COLS),
    };
    Hat { kind, tone: Tone::of(c), mat }
}

pub fn hold_tones(k: HoldKind) -> &'static [Col] {
    use Col::*;
    match k {
        HoldKind::Book => &[Kirmizi, Mavi, Yesil, Sari, Mor],
        HoldKind::Cup => &[Beyaz, Kirmizi, Mavi, Sari],
        HoldKind::Umbrella => &[Kirmizi, Mavi, Siyah, Sari, Mor, Yesil],
        HoldKind::Balloon => &[Kirmizi, Mavi, Sari, Yesil, Pembe, Mor, Turuncu],
        HoldKind::Flower => &[Kirmizi, Sari, Pembe, Beyaz, Mor],
        HoldKind::Phone => &[Siyah, Beyaz],
        HoldKind::IceCream => &[Pembe, Sari, Kahve, Beyaz],
    }
}

/// A random held item that suits the setting and age.
pub fn gen_hold(r: &mut Rng, set: Setting, age: Age) -> (HoldKind, Tone) {
    use HoldKind::*;
    let k = match set {
        Setting::Park | Setting::Plaj => {
            if age == Age::Child {
                *r.pick(&[Balloon, Balloon, IceCream, Book, Flower])
            } else {
                *r.pick(&[Book, IceCream, Balloon, Flower, Phone, Cup])
            }
        }
        Setting::Sokak | Setting::Istasyon => *r.pick(&[Umbrella, Umbrella, Phone, Book, Cup, Flower]),
        _ => {
            if age == Age::Child {
                *r.pick(&[Balloon, Book, Flower])
            } else {
                *r.pick(&[Book, Cup, Cup, Phone, Flower])
            }
        }
    };
    (k, Tone::of(*r.pick(hold_tones(k))))
}

pub fn bag_tones() -> &'static [Col] {
    tone_choices(Kind::Bag)
}

pub fn gen_person(r: &mut Rng, set: Setting, hat_p: f64) -> Person {
    let age = match r.below(100) {
        0..=13 => Age::Child,
        14..=31 => Age::Elder,
        _ => Age::Adult,
    };
    let female = r.chance(0.5);
    // Elders are always grey-haired so they read as old at phone size (questions say "yaşlı").
    let hair = if age == Age::Elder {
        Hair::Gri
    } else {
        *r.pick(&[Hair::Siyah, Hair::Siyah, Hair::Kahve, Hair::Kahve, Hair::Sari, Hair::Kizil])
    };
    let style = if female {
        *r.pick(&[Style::Long, Style::Long, Style::Bun, Style::Ponytail, Style::Short, Style::Curly])
    } else if age == Age::Elder && r.chance(0.4) {
        Style::Bald
    } else {
        *r.pick(&[Style::Short, Style::Short, Style::Curly, Style::Short])
    };
    let beard = if !female && age != Age::Child {
        *r.pick(&[Beard::None, Beard::None, Beard::None, Beard::Mustache, Beard::Full])
    } else {
        Beard::None
    };
    let hat = r.chance(hat_p).then(|| gen_hat(r, set));
    let glasses = match r.below(100) {
        n if n < (if set == Setting::Plaj { 25 } else { 7 }) => Glasses::Sun,
        n if n < (if age == Age::Child { 33 } else { 52 }) - if set == Setting::Plaj { 0 } else { 18 } => Glasses::Reading,
        _ => Glasses::None,
    };
    let top_kind = if set == Setting::Plaj {
        TopKind::Tshirt
    } else if set.warm() {
        *r.pick(&[TopKind::Tshirt, TopKind::Tshirt, TopKind::Sweater, TopKind::Jacket])
    } else {
        *r.pick(&[TopKind::Tshirt, TopKind::Sweater, TopKind::Sweater, TopKind::Jacket])
    };
    let pattern = match r.below(100) {
        0..=59 => Pattern::Plain,
        60..=81 => Pattern::Stripe,
        _ => Pattern::Dots,
    };
    let top = Tone::of(*r.pick(&COLS));
    let bottom_kind = if female && r.chance(0.38) {
        BottomKind::Skirt
    } else if set.warm() && r.chance(0.45) {
        BottomKind::Shorts
    } else {
        BottomKind::Trousers
    };
    let bottom = Tone::of(*r.pick(&[Col::Mavi, Col::Mavi, Col::Siyah, Col::Gri, Col::Kahve, Col::Beyaz, Col::Yesil, Col::Kirmizi]));
    let bag = r.chance(0.26).then(|| {
        let k = if r.chance(0.5) { BagKind::Backpack } else { BagKind::Handbag };
        (k, Tone::of(*r.pick(bag_tones())))
    });
    let hold = r.chance(0.32).then(|| gen_hold(r, set, age));
    Person {
        female,
        age,
        sitting: false,
        seat: Seat::None,
        skin: r.below(5) as u8,
        hair,
        style,
        hat,
        glasses,
        top,
        top_kind,
        pattern,
        bottom,
        bottom_kind,
        bag,
        hold,
        beard,
    }
}

/// Generate a scene from a seed.
pub fn generate(seed: u64, prm: &SceneParams) -> Scene {
    let mut rng = Rng::new(seed);
    let setting = *rng.pick(&SETTINGS);
    let wall = rng.below(4) as u8;
    let floor = rng.below(4) as u8;
    let bg = rng.below(4) as u8;
    let people = prm.people.0 + rng.below(prm.people.1.saturating_sub(prm.people.0) + 1);
    let animals = prm.animals.0 + rng.below(prm.animals.1.saturating_sub(prm.animals.0) + 1);
    let mut g = Gen { rng, sc: Scene { no: scene_no(seed), setting, wall, floor, bg, items: vec![] }, next: 1 };
    g.wall_items(prm.clutter);
    g.furniture(prm.clutter);
    g.people(people, prm.hat_p);
    g.objects(prm.clutter);
    g.animals(animals);
    g.sc.sort();
    g.sc
}

/// Generate until `accept` holds (at most 16 seed variants; deterministic). Falls back to the
/// variant with the most people.
pub fn generate_where(seed: u64, prm: &SceneParams, accept: impl Fn(&Scene) -> bool) -> Scene {
    let mut best: Option<Scene> = None;
    for k in 0..16u64 {
        let sc = generate(seed ^ k.wrapping_mul(0x9E37_79B9_7F4A_7C15), prm);
        if accept(&sc) {
            return sc;
        }
        let n = sc.people().count();
        if best.as_ref().is_none_or(|b| b.people().count() < n) {
            best = Some(sc);
        }
    }
    best.expect("at least one scene")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    fn prm() -> SceneParams {
        SceneParams { people: (3, 7), clutter: 0.6, hat_p: 0.5, animals: (0, 2) }
    }

    #[test]
    fn scene_generation_is_deterministic() {
        for seed in [1u64, 2, 99, 123_456_789] {
            assert_eq!(generate(seed, &prm()), generate(seed, &prm()));
            assert_eq!(generate(seed, &prm()).json("k"), generate(seed, &prm()).json("k"));
        }
    }

    #[test]
    fn scene_thousand_distinct_descriptions() {
        let mut seen = HashSet::new();
        for seed in 0..1200u64 {
            let sc = generate(seed, &prm());
            let mut v = sc.json("");
            v.as_object_mut().unwrap().remove("no");
            seen.insert(v.to_string());
        }
        assert!(seen.len() >= 1000, "only {} distinct scenes", seen.len());
    }

    #[test]
    fn scene_layout_is_readable() {
        for seed in 0..400u64 {
            let sc = generate(seed, &prm());
            assert!(!sc.items.is_empty());
            // Draw order sorted, boxes inside the canvas, ids unique.
            let mut ids = HashSet::new();
            for w in sc.items.windows(2) {
                assert!(w[0].z <= w[1].z);
            }
            for it in &sc.items {
                assert!(ids.insert(it.id));
                let b = it.full_box();
                assert!(b.x >= -1.0 && b.x1() <= W + 1.0 && b.y >= -1.0 && b.y1() <= H + 1.0, "{:?} out of canvas", it.kind);
                if let Some(o) = it.on {
                    assert!(sc.get(o).is_some(), "dangling support");
                }
            }
            // No two people in the same row overlap.
            let ppl: Vec<&Item> = sc.items.iter().filter(|i| i.kind == Kind::Person).collect();
            for (i, a) in ppl.iter().enumerate() {
                for b in &ppl[i + 1..] {
                    if a.row == b.row {
                        assert!(a.full_box().inter(&b.full_box()) <= 0.0, "people overlap in seed {seed}");
                    }
                }
            }
            assert!(ppl.len() >= 2, "seed {seed}: only {} people", ppl.len());
        }
    }

    #[test]
    fn scene_relations_make_sense() {
        let mut seen_table = false;
        for seed in 0..300u64 {
            let sc = generate(seed, &prm());
            for it in sc.items.iter().filter(|i| i.kind == Kind::Person) {
                let r = rels(&sc, it);
                if r.contains(&Rel::Bench) {
                    assert_eq!(sc.get(it.on.unwrap()).unwrap().kind, Kind::Bench);
                    assert!(it.person.unwrap().sitting);
                }
                seen_table |= r.contains(&Rel::Table);
            }
        }
        assert!(seen_table);
    }

    #[test]
    fn scene_cap_is_turkish() {
        assert_eq!(cap("iki"), "İki");
        assert_eq!(cap("ışık"), "Işık");
        assert_eq!(cap("çizgili"), "Çizgili");
    }

}
