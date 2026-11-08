//! Kelime Listesi — classic verbal list learning (our own content, inspired by list-learning tests).
//!
//! Concrete Turkish nouns appear one at a time; the player then types back what they remember.
//! Every level is a fixed *script* of steps (study, recall, recognition, distractor) chosen by the
//! level's variant. Rust owns all timing (`tick`), checking and scoring.
//!
//! Level curve (`params(level)`, t = (level-1)/499):
//! - Words per list: 8 → 30 (`8 + round(22·t^0.9)`); serial recall uses 60 % of that (min 6).
//! - Presentation rate: 2.5 s → 0.8 s per word (`2500 − 1700·t^0.8` ms); the word is visible for
//!   85 % of the slot, then a short blank.
//! - Semantic structure: lists are built from categories, 2 → 4 words per category, interleaved so
//!   neighbours never share a category (clustering has to be done by the player). Recognition lures
//!   always come from the same categories as the targets; List B shares 30 % → 90 % of List A's
//!   categories (more intrusions).
//! - Variants rotate every level: (L-1) % 5 = 0 free recall (from level 100 every other cycle it is
//!   **serial** recall: in order, positional scoring), 1 learning curve (3 trials of the same list),
//!   2 recognition (targets + equally many related lures, yes/no), 3 interference (A, recall A,
//!   List B, recall B, recall A again), 4 delayed (A, recall A, 60 → 90 s arithmetic, recall A).
//!
//! Scoring (score = %):
//! - free / delayed / interference: words found over all recall rounds ÷ words asked;
//!   learning: the final trial; serial: words typed in their exact position; recognition:
//!   (hits + correct rejections) ÷ items.
//! - Stars: base thresholds by level (3★ 90 → 75 %, 2★ 75 → 60 %, 1★ 60 → 45 %), adjusted per
//!   variant (learning +8 pts, delayed/interference −5, serial −10; recognition uses 95/85/75 →
//!   92/82/70). Below the 1★ threshold the level is `lost`.
//!
//! Recall input tolerance: case is ignored (Turkish-aware: I/ı, İ/i), surrounding spaces are
//! ignored and **diacritics are optional** (ç=c, ğ=g, ı=i, ö=o, ş=s, ü=u, â=a): "kopek" counts as
//! "köpek" (shown as a corrected spelling). The word bank is checked so that no two words fold to the
//! same spelling. No other typos are accepted. A word already typed in this round is rejected (toast).
//!
//! State: `{status, stars, title, goal, summary?, score, phase:"intro"|"countdown"|"study"|"recall"|
//!   "recognize"|"distract"|"review"|"done", variant, words, rate_ms, step, steps,
//!   countdown?:{remaining_ms,total_ms,banner}, study?:{list,trial,index,total,word|null,slot_ms,t_ms},
//!   recall?:{label,list,serial,total,found,entries:[{text,result,word,fixed}],remaining_ms,limit_ms},
//!   recognize?:{index,total,word,correct,last:{serial,correct,said,target}|null},
//!   distract?:{text,remaining_ms,total_ms,right,wrong,serial,last_ok}, results?:{…}, thresholds}`
//! Entry results: `ok`, `misplaced` (serial: right word, wrong slot), `other_list` (a List B word
//! while recalling A or vice versa), `intrusion`, `skip` (serial blank).
//! Actions: `{"start":true}` · `{"word":"elma"}` · `{"skip_slot":true}` (serial) ·
//!   `{"done":true}` (end a recall round) · `{"answer":true|false}` (recognition) ·
//!   `{"judge":true|false}` (distractor) · `{"finish":true}` (review → final result).

use crate::rng::{seed_for, Rng};
use crate::Session;
use serde_json::{json, Value};

// ------------------------------------------------------------------ shared helpers

/// Case- and diacritic-insensitive key for Turkish text: lower-cased (İ/I → i), ç→c, ğ→g, ı→i,
/// ö→o, ş→s, ü→u, â→a, î→i, û→u; runs of whitespace collapse to one space, ends trimmed.
pub(crate) fn fold(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut gap = false;
    for ch in s.trim().chars() {
        if ch.is_whitespace() {
            gap = true;
            continue;
        }
        if gap && !out.is_empty() {
            out.push(' ');
        }
        gap = false;
        let c = match ch {
            'İ' | 'I' | 'ı' | 'i' | 'î' | 'Î' => 'i',
            'Ç' | 'ç' => 'c',
            'Ğ' | 'ğ' => 'g',
            'Ö' | 'ö' => 'o',
            'Ş' | 'ş' => 's',
            'Ü' | 'ü' | 'û' | 'Û' => 'u',
            'Â' | 'â' => 'a',
            c => c.to_lowercase().next().unwrap_or(c),
        };
        out.push(c);
    }
    out
}

/// Turkish-aware lower case (İ→i, I→ı) without diacritic folding; whitespace collapsed.
pub(crate) fn tr_lower(s: &str) -> String {
    let joined = s.split_whitespace().collect::<Vec<_>>().join(" ");
    joined
        .chars()
        .map(|c| match c {
            'İ' => 'i',
            'I' => 'ı',
            c => c.to_lowercase().next().unwrap_or(c),
        })
        .collect()
}

/// Distractor task: verify simple sums ("47 + 8 = 55?") with Doğru / Yanlış for a fixed time.
/// It blocks rehearsal between study and a delayed test; it is reported but never scored.
pub(crate) struct Distractor {
    rng: Rng,
    pub total_ms: f64,
    pub elapsed_ms: f64,
    text: String,
    truth: bool,
    pub right: u32,
    pub wrong: u32,
    serial: u32,
    last_ok: Option<bool>,
}

impl Distractor {
    pub(crate) fn new(seed: u64, total_ms: f64) -> Self {
        let mut d = Distractor {
            rng: Rng::new(seed),
            total_ms,
            elapsed_ms: 0.0,
            text: String::new(),
            truth: true,
            right: 0,
            wrong: 0,
            serial: 0,
            last_ok: None,
        };
        d.next();
        d
    }

    fn next(&mut self) {
        let r = &mut self.rng;
        let plus = r.chance(0.55);
        let (a, b) = if plus { (r.range(12, 79), r.range(3, 19)) } else { (r.range(25, 99), r.range(3, 19)) };
        let res = if plus { a + b } else { a - b };
        let truth = r.chance(0.5);
        let shown = if truth { res } else { res + *r.pick(&[-10i64, -2, -1, 1, 2, 10]) };
        self.truth = truth;
        self.text = format!("{a} {} {b} = {shown}", if plus { "+" } else { "−" });
    }

    pub(crate) fn judge(&mut self, said_true: bool) {
        let ok = said_true == self.truth;
        if ok {
            self.right += 1;
        } else {
            self.wrong += 1;
        }
        self.serial += 1;
        self.last_ok = Some(ok);
        self.next();
    }

    /// Advance the clock; true once time is up.
    pub(crate) fn tick(&mut self, dt: f64) -> bool {
        self.elapsed_ms = (self.elapsed_ms + dt).min(self.total_ms);
        self.done()
    }

    pub(crate) fn done(&self) -> bool {
        self.elapsed_ms >= self.total_ms
    }

    pub(crate) fn state(&self) -> Value {
        json!({
            "text": self.text,
            "remaining_ms": (self.total_ms - self.elapsed_ms).max(0.0).round(),
            "total_ms": self.total_ms,
            "right": self.right,
            "wrong": self.wrong,
            "serial": self.serial,
            "last_ok": self.last_ok,
        })
    }
}

pub(crate) fn lerp(a: f64, b: f64, t: f64) -> f64 {
    a + (b - a) * t
}

// ------------------------------------------------------------------ word bank

/// Concrete, imageable Turkish nouns grouped by category (category label, words). Every word is a
/// single token and unique after [`fold`] across the whole bank (tested).
pub const BANK: &[(&str, &[&str])] = &[
    ("Meyve", &["elma", "armut", "muz", "çilek", "kiraz", "vişne", "üzüm", "karpuz", "kavun", "şeftali", "kayısı", "erik", "incir", "nar", "portakal", "mandalina", "limon", "ayva", "dut", "kivi", "ananas", "böğürtlen", "ahududu", "hurma"]),
    ("Sebze", &["domates", "salatalık", "biber", "patlıcan", "kabak", "havuç", "patates", "soğan", "sarımsak", "ıspanak", "marul", "lahana", "brokoli", "karnabahar", "pırasa", "bezelye", "fasulye", "turp", "pancar", "kereviz", "enginar", "bamya", "mısır"]),
    ("Hayvan", &["aslan", "kaplan", "fil", "zürafa", "zebra", "ayı", "kurt", "tilki", "tavşan", "sincap", "geyik", "at", "eşek", "inek", "koyun", "keçi", "deve", "maymun", "kedi", "köpek", "fare", "kirpi", "panda", "kanguru", "gergedan"]),
    ("Kuş", &["kartal", "şahin", "baykuş", "güvercin", "serçe", "karga", "leylek", "martı", "papağan", "akbaba", "flamingo", "penguen", "kuğu", "ördek", "kaz", "tavuk", "horoz", "hindi", "bülbül", "kanarya", "saksağan", "ağaçkakan", "pelikan", "devekuşu"]),
    ("Deniz canlısı", &["balina", "yunus", "köpekbalığı", "ahtapot", "kalamar", "denizanası", "denizyıldızı", "yengeç", "ıstakoz", "karides", "midye", "istiridye", "fok", "mors", "kaplumbağa", "hamsi", "palamut", "levrek", "çipura", "uskumru", "vatoz", "denizatı"]),
    ("Böcek", &["arı", "karınca", "kelebek", "sinek", "sivrisinek", "örümcek", "akrep", "uğurböceği", "çekirge", "ateşböceği", "yusufçuk", "salyangoz", "solucan", "tırtıl", "kırkayak", "güve", "pire", "eşekarısı", "hamamböceği", "sümüklüböcek"]),
    ("Mutfak", &["tencere", "tava", "kaşık", "çatal", "bıçak", "tabak", "bardak", "fincan", "demlik", "çaydanlık", "cezve", "kepçe", "rende", "tepsi", "sürahi", "kevgir", "oklava", "havan", "termos", "süzgeç", "fırın", "ocak"]),
    ("Mobilya", &["masa", "sandalye", "koltuk", "kanepe", "yatak", "dolap", "raf", "sehpa", "komodin", "kitaplık", "gardırop", "tabure", "beşik", "şifonyer", "abajur", "avize", "halı", "kilim", "perde", "yastık", "yorgan", "battaniye", "ayna"]),
    ("Giysi", &["gömlek", "pantolon", "etek", "elbise", "ceket", "mont", "palto", "kazak", "yelek", "tişört", "şort", "pijama", "çorap", "eldiven", "atkı", "bere", "şapka", "kravat", "kemer", "ayakkabı", "çizme", "terlik", "sandalet", "mayo"]),
    ("Aksesuar", &["yüzük", "kolye", "küpe", "bilezik", "broş", "saat", "gözlük", "şemsiye", "cüzdan", "çanta", "valiz", "taç", "madalya", "rozet", "tespih", "yelpaze", "anahtar", "baston", "toka"]),
    ("Alet", &["çekiç", "tornavida", "pense", "testere", "matkap", "keser", "balta", "kürek", "tırmık", "makas", "çivi", "vida", "metre", "mengene", "zımpara", "keski", "eğe", "fener", "halat", "zincir", "çapa"]),
    ("Müzik aleti", &["davul", "gitar", "keman", "piyano", "flüt", "saz", "ud", "ney", "zurna", "trompet", "klarnet", "akordeon", "arp", "def", "darbuka", "zil", "çello", "mızıka", "kaval", "obua", "trombon"]),
    ("Taşıt", &["araba", "otobüs", "kamyon", "tren", "uçak", "gemi", "vapur", "sandal", "kayık", "bisiklet", "motosiklet", "helikopter", "tramvay", "minibüs", "taksi", "traktör", "ambulans", "itfaiye", "roket", "denizaltı", "yat", "kano", "metro", "teleferik"]),
    ("Vücut", &["el", "ayak", "kol", "bacak", "diz", "dirsek", "omuz", "parmak", "tırnak", "burun", "kulak", "göz", "dudak", "diş", "dil", "saç", "kaş", "kirpik", "çene", "boyun", "kalp", "bilek", "topuk", "yanak"]),
    ("Doğa", &["dağ", "tepe", "vadi", "ova", "nehir", "ırmak", "göl", "deniz", "okyanus", "şelale", "mağara", "ada", "kumsal", "çöl", "orman", "bataklık", "volkan", "kanyon", "uçurum", "buzul", "pınar", "dere"]),
    ("Gökyüzü", &["güneş", "ay", "yıldız", "bulut", "yağmur", "kar", "dolu", "şimşek", "yıldırım", "gökkuşağı", "rüzgar", "sis", "fırtına", "kasırga", "gezegen", "hilal", "dolunay", "kuyrukluyıldız", "buz", "kartopu"]),
    ("Yapı", &["ev", "okul", "hastane", "cami", "kale", "köprü", "kule", "saray", "çadır", "kulübe", "ahır", "değirmen", "çeşme", "havuz", "stadyum", "müze", "kütüphane", "fabrika", "garaj", "ambar", "iglo", "piramit", "minare", "apartman"]),
    ("Yemek", &["çorba", "pilav", "makarna", "köfte", "kebap", "börek", "pide", "lahmacun", "mantı", "dolma", "pizza", "hamburger", "menemen", "kumpir", "musakka", "güveç", "döner"]),
    ("Kahvaltılık", &["ekmek", "simit", "poğaça", "peynir", "zeytin", "yumurta", "bal", "reçel", "tereyağı", "kaymak", "sucuk", "pastırma", "tost", "yoğurt"]),
    ("Tatlı", &["baklava", "lokum", "dondurma", "pasta", "kurabiye", "helva", "sütlaç", "kek", "çikolata", "şeker", "kadayıf", "aşure", "künefe", "gofret"]),
    ("İçecek", &["su", "süt", "çay", "kahve", "ayran", "limonata", "şerbet", "boza", "salep", "kola", "gazoz", "şıra", "kefir", "kakao", "soda", "kompot"]),
    ("Spor", &["top", "raket", "file", "sopa", "kask", "dambıl", "halter", "kayak", "paten", "kaykay", "düdük", "kupa", "ok", "yay", "olta", "frizbi", "bumerang", "kılıç", "kalkan"]),
    ("Kırtasiye", &["kalem", "silgi", "defter", "kitap", "cetvel", "pergel", "tebeşir", "zımba", "ataş", "yapıştırıcı", "kalemtıraş", "harita", "küre", "dosya", "zarf", "pul", "mürekkep", "fırça", "tuval", "ajanda", "gönye"]),
    ("Oyuncak", &["bebek", "ayıcık", "balon", "uçurtma", "topaç", "misket", "zar", "satranç", "tavla", "yapboz", "salıncak", "kaydırak", "tahterevalli", "robot", "kukla", "yoyo", "maske"]),
    ("Çiçek", &["gül", "lale", "papatya", "menekşe", "karanfil", "zambak", "orkide", "sümbül", "nergis", "ayçiçeği", "nilüfer", "yasemin", "leylak", "kaktüs", "sarmaşık", "yonca", "mantar", "lavanta", "manolya", "gelincik"]),
    ("Ağaç", &["çam", "meşe", "kavak", "çınar", "söğüt", "ladin", "sedir", "ardıç", "akasya", "palmiye", "ıhlamur", "gürgen", "kayın", "servi", "bambu", "okaliptüs", "baobab"]),
    ("Banyo", &["sabun", "şampuan", "havlu", "tarak", "jilet", "sünger", "kova", "paspas", "süpürge", "küvet", "lavabo", "musluk", "duş", "bornoz", "lif", "kese", "deterjan", "faraş", "mandal", "ütü", "leğen"]),
    ("Elektronik", &["telefon", "televizyon", "bilgisayar", "radyo", "kamera", "buzdolabı", "mikser", "ampul", "pil", "kablo", "priz", "hoparlör", "kulaklık", "mikrofon", "tablet", "klavye", "yazıcı", "vantilatör", "klima"]),
    ("Bilim aleti", &["dürbün", "teleskop", "mikroskop", "pusula", "termometre", "büyüteç", "mıknatıs", "terazi", "stetoskop", "şırınga", "kronometre", "prizma", "metronom", "huni"]),
    ("Taş ve maden", &["altın", "gümüş", "bakır", "demir", "elmas", "yakut", "zümrüt", "safir", "inci", "mercan", "kehribar", "kristal", "mermer", "kömür", "çakıl", "kum", "tuz", "akik", "firuze", "kurşun"]),
    ("Kişi", &["doktor", "hemşire", "öğretmen", "aşçı", "pilot", "asker", "polis", "itfaiyeci", "çiftçi", "balıkçı", "berber", "terzi", "ressam", "kaptan", "garson", "postacı", "marangoz", "kral", "kraliçe", "prenses", "şövalye", "korsan", "büyücü", "palyaço", "dalgıç", "astronot"]),
    ("Ev bölümü", &["kapı", "pencere", "merdiven", "çatı", "baca", "balkon", "bahçe", "şömine", "koridor", "bodrum", "tavan", "duvar", "kilit", "çit", "kuyu", "asansör", "tuğla", "kiremit", "panjur", "teras"]),
    ("Baharat", &["tarçın", "karabiber", "kimyon", "nane", "kekik", "safran", "zencefil", "sumak", "pulbiber", "fesleğen", "maydanoz", "dereotu", "roka", "vanilya", "susam", "kakule", "defne", "biberiye"]),
    ("Kuruyemiş", &["fındık", "fıstık", "badem", "leblebi", "çekirdek", "kaju", "ceviz", "kestane", "pirinç", "buğday", "arpa", "yulaf", "nohut", "mercimek", "bulgur", "darı", "çavdar"]),
];

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Word {
    pub cat: usize,
    pub idx: usize,
}

impl Word {
    pub fn text(self) -> &'static str {
        BANK[self.cat].1[self.idx]
    }
}

pub fn bank_size() -> usize {
    BANK.iter().map(|(_, w)| w.len()).sum()
}

// ------------------------------------------------------------------ level parameters

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Variant {
    Free,
    Serial,
    Learning,
    Recognition,
    Interference,
    Delayed,
}

impl Variant {
    fn key(self) -> &'static str {
        match self {
            Variant::Free => "free",
            Variant::Serial => "serial",
            Variant::Learning => "learning",
            Variant::Recognition => "recognition",
            Variant::Interference => "interference",
            Variant::Delayed => "delayed",
        }
    }
    fn title(self) -> &'static str {
        match self {
            Variant::Free => "Serbest hatırlama",
            Variant::Serial => "Sıralı hatırlama",
            Variant::Learning => "Öğrenme eğrisi",
            Variant::Recognition => "Tanıma",
            Variant::Interference => "Karışma",
            Variant::Delayed => "Gecikmeli",
        }
    }
}

#[derive(Clone, Debug)]
pub struct Params {
    pub variant: Variant,
    pub words: usize,
    pub rate_ms: f64,
    pub per_cat: usize,
    pub trials: usize,
    pub distract_ms: f64,
    pub b_overlap: f64,
    pub recall_ms: f64,
    /// Score fractions needed for 1★, 2★, 3★.
    pub thresholds: [f64; 3],
}

pub fn params(level: u32) -> Params {
    let level = level.clamp(1, crate::MAX_LEVEL);
    let t = (level - 1) as f64 / 499.0;
    let base_words = 8 + (22.0 * t.powf(0.9)).round() as usize;
    let rate_ms = (2500.0 - 1700.0 * t.powf(0.8)).round();
    let per_cat = 2 + (2.0 * t).round() as usize;
    let cycle = (level - 1) % 5;
    let variant = match cycle {
        0 if level >= 100 && ((level - 1) / 5) % 2 == 1 => Variant::Serial,
        0 => Variant::Free,
        1 => Variant::Learning,
        2 => Variant::Recognition,
        3 => Variant::Interference,
        _ => Variant::Delayed,
    };
    let words = if variant == Variant::Serial { ((base_words as f64 * 0.6).round() as usize).max(6) } else { base_words };
    let base = [lerp(0.60, 0.45, t), lerp(0.75, 0.60, t), lerp(0.90, 0.75, t)];
    let adj = |d: f64| base.map(|x| (x + d).clamp(0.2, 0.98));
    let thresholds = match variant {
        Variant::Free => base,
        Variant::Learning => adj(0.08),
        Variant::Delayed | Variant::Interference => adj(-0.05),
        Variant::Serial => adj(-0.10),
        Variant::Recognition => [lerp(0.75, 0.70, t), lerp(0.85, 0.82, t), lerp(0.95, 0.92, t)],
    };
    Params {
        variant,
        words,
        rate_ms,
        per_cat,
        trials: if variant == Variant::Learning { 3 } else { 1 },
        distract_ms: (lerp(60.0, 90.0, t) / 5.0).round() * 5000.0,
        b_overlap: lerp(0.3, 0.9, t),
        recall_ms: 45_000.0 + 3000.0 * words as f64,
        thresholds,
    }
}

// ------------------------------------------------------------------ list generation

/// Interleave so that neighbours never share a category when avoidable.
fn interleave(rng: &mut Rng, v: &mut [Word]) {
    rng.shuffle(v);
    for _ in 0..6 {
        let mut clean = true;
        for i in 1..v.len() {
            if v[i].cat == v[i - 1].cat {
                clean = false;
                // Swap with a later element that fits here.
                if let Some(j) = (0..v.len()).find(|&j| {
                    j != i
                        && j != i - 1
                        && v[j].cat != v[i - 1].cat
                        && (i + 1 >= v.len() || v[j].cat != v[i + 1].cat)
                        && (j == 0 || j - 1 == i || v[j - 1].cat != v[i].cat)
                        && (j + 1 >= v.len() || j + 1 == i || v[j + 1].cat != v[i].cat)
                }) {
                    v.swap(i, j);
                }
            }
        }
        if clean {
            break;
        }
    }
}

/// Pick `n` words, `per_cat` per category. `avoid` words are never used; `prefer` categories are
/// used for a fraction `overlap` of the categories (List B sharing List A's categories).
pub fn pick_list(rng: &mut Rng, n: usize, per_cat: usize, avoid: &[Word], prefer: &[usize], overlap: f64) -> Vec<Word> {
    let k = n.div_ceil(per_cat);
    let free_in = |cat: usize| BANK[cat].1.len() - avoid.iter().filter(|w| w.cat == cat).count();
    // Leave room for recognition lures (per_cat more per category).
    let usable = |cat: usize| free_in(cat) > per_cat * 2;
    let mut pref: Vec<usize> = prefer.iter().copied().filter(|&c| usable(c)).collect();
    pref.sort_unstable();
    pref.dedup();
    rng.shuffle(&mut pref);
    let want_pref = ((k as f64 * overlap).round() as usize).min(pref.len());
    let mut cats: Vec<usize> = pref[..want_pref].to_vec();
    let mut others: Vec<usize> = (0..BANK.len()).filter(|c| !prefer.contains(c) && usable(*c)).collect();
    rng.shuffle(&mut others);
    for c in others {
        if cats.len() >= k {
            break;
        }
        cats.push(c);
    }
    // Fallback (never expected with the bank sizes): any remaining usable categories.
    for c in pref.into_iter().skip(want_pref) {
        if cats.len() >= k {
            break;
        }
        cats.push(c);
    }
    let mut out = Vec::with_capacity(n);
    for (i, &cat) in cats.iter().enumerate() {
        let take = per_cat.min(n - out.len()).min(if i + 1 == cats.len() { n - out.len() } else { per_cat });
        let mut idx: Vec<usize> =
            (0..BANK[cat].1.len()).filter(|&j| !avoid.contains(&Word { cat, idx: j })).collect();
        rng.shuffle(&mut idx);
        out.extend(idx.into_iter().take(take).map(|j| Word { cat, idx: j }));
    }
    interleave(rng, &mut out);
    out
}

/// One related lure per target: same category, not in `exclude`, no repeats.
pub fn pick_lures(rng: &mut Rng, targets: &[Word], exclude: &[Word]) -> Vec<Word> {
    let mut used: Vec<Word> = Vec::new();
    for t in targets {
        let mut pool: Vec<Word> = (0..BANK[t.cat].1.len())
            .map(|j| Word { cat: t.cat, idx: j })
            .filter(|w| !targets.contains(w) && !exclude.contains(w) && !used.contains(w))
            .collect();
        if pool.is_empty() {
            // Any category of the list, then anything at all.
            pool = targets
                .iter()
                .flat_map(|x| (0..BANK[x.cat].1.len()).map(move |j| Word { cat: x.cat, idx: j }))
                .filter(|w| !targets.contains(w) && !exclude.contains(w) && !used.contains(w))
                .collect();
        }
        if pool.is_empty() {
            pool = (0..BANK.len())
                .flat_map(|c| (0..BANK[c].1.len()).map(move |j| Word { cat: c, idx: j }))
                .filter(|w| !targets.contains(w) && !exclude.contains(w) && !used.contains(w))
                .collect();
        }
        used.push(*rng.pick(&pool));
    }
    used
}

// ------------------------------------------------------------------ session

#[derive(Clone, Debug)]
enum Step {
    Countdown { ms: f64, banner: String },
    Study { list: usize, trial: usize },
    Recall { list: usize, serial: bool, label: String },
    Recognize,
    Distract,
}

#[derive(Clone, Debug)]
struct Entry {
    text: String,
    key: String,
    result: &'static str,
    word: Option<String>,
    fixed: bool,
}

#[derive(Clone, Debug)]
struct Round {
    label: String,
    list: usize,
    serial: bool,
    total: usize,
    /// List positions recalled (serial: in the right slot).
    positions: Vec<bool>,
    /// Recalled list indices in output order (for clustering).
    order: Vec<usize>,
    intrusions: Vec<String>,
    other_list: usize,
    misplaced: usize,
}

impl Round {
    fn found(&self) -> usize {
        self.positions.iter().filter(|&&b| b).count()
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Stage {
    Intro,
    Run,
    Review,
    Done,
}

pub struct WordList {
    level: u32,
    p: Params,
    lists: [Vec<Word>; 2],
    probe: Vec<(Word, bool)>,
    steps: Vec<Step>,
    step: usize,
    step_ms: f64,
    stage: Stage,
    entries: Vec<Entry>,
    rounds: Vec<Round>,
    rec_answers: Vec<bool>,
    rec_last: Option<(u32, bool, bool, bool)>,
    rec_serial: u32,
    distract: Option<Distractor>,
    distract_stats: Option<(u32, u32)>,
    score: f64,
    stars: u32,
}

pub fn create(level: u32, _mode: &str) -> Result<Box<dyn Session>, String> {
    Ok(Box::new(WordList::new(level)))
}

impl WordList {
    pub fn new(level: u32) -> Self {
        let level = level.clamp(1, crate::MAX_LEVEL);
        let p = params(level);
        let mut rng = Rng::new(seed_for("word_list", level, 0));
        let a = pick_list(&mut rng, p.words, p.per_cat, &[], &[], 0.0);
        let b = if p.variant == Variant::Interference {
            let cats: Vec<usize> = a.iter().map(|w| w.cat).collect();
            pick_list(&mut rng, p.words, p.per_cat, &a, &cats, p.b_overlap)
        } else {
            vec![]
        };
        let mut probe = Vec::new();
        if p.variant == Variant::Recognition {
            let lures = pick_lures(&mut rng, &a, &[]);
            probe.extend(a.iter().map(|&w| (w, true)));
            probe.extend(lures.into_iter().map(|w| (w, false)));
            rng.shuffle(&mut probe);
        }
        let cd = |ms: f64, s: &str| Step::Countdown { ms, banner: s.to_string() };
        let recall = |list: usize, label: &str| Step::Recall { list, serial: false, label: label.to_string() };
        let steps = match p.variant {
            Variant::Free => vec![cd(3000.0, "Liste geliyor"), Step::Study { list: 0, trial: 1 }, recall(0, "Hatırladıklarını yaz")],
            Variant::Serial => vec![
                cd(3000.0, "Sırayı aklında tut"),
                Step::Study { list: 0, trial: 1 },
                Step::Recall { list: 0, serial: true, label: "Sırayla yaz".into() },
            ],
            Variant::Learning => (1..=p.trials)
                .flat_map(|t| {
                    [
                        cd(if t == 1 { 3000.0 } else { 2500.0 }, &format!("{t}. deneme · aynı liste")),
                        Step::Study { list: 0, trial: t },
                        recall(0, &format!("{t}. deneme")),
                    ]
                })
                .collect(),
            Variant::Recognition => vec![cd(3000.0, "Liste geliyor"), Step::Study { list: 0, trial: 1 }, Step::Recognize],
            Variant::Interference => vec![
                cd(3000.0, "A listesi"),
                Step::Study { list: 0, trial: 1 },
                recall(0, "A listesi"),
                cd(2500.0, "Yeni liste: B"),
                Step::Study { list: 1, trial: 1 },
                recall(1, "B listesi"),
                recall(0, "Yeniden A listesi"),
            ],
            Variant::Delayed => vec![
                cd(3000.0, "Liste geliyor"),
                Step::Study { list: 0, trial: 1 },
                recall(0, "Hemen hatırla"),
                cd(2500.0, "Ara görev: işlemleri doğrula"),
                Step::Distract,
                recall(0, "Gecikmeli hatırlama"),
            ],
        };
        WordList {
            level,
            p,
            lists: [a, b],
            probe,
            steps,
            step: 0,
            step_ms: 0.0,
            stage: Stage::Intro,
            entries: vec![],
            rounds: vec![],
            rec_answers: vec![],
            rec_last: None,
            rec_serial: 0,
            distract: None,
            distract_stats: None,
            score: 0.0,
            stars: 0,
        }
    }

    fn cur(&self) -> Option<&Step> {
        if self.stage == Stage::Run {
            self.steps.get(self.step)
        } else {
            None
        }
    }

    fn advance(&mut self) {
        self.step += 1;
        self.step_ms = 0.0;
        self.entries.clear();
        if let Some(d) = self.distract.take() {
            self.distract_stats = Some((d.right, d.wrong));
        }
        match self.steps.get(self.step) {
            None => self.finish_run(),
            Some(Step::Distract) => {
                self.distract = Some(Distractor::new(seed_for("word_list", self.level, 7), self.p.distract_ms));
            }
            _ => {}
        }
    }

    fn end_recall(&mut self) {
        let Some(Step::Recall { list, serial, label }) = self.cur().cloned() else { return };
        let words = &self.lists[list];
        let mut positions = vec![false; words.len()];
        let mut order = Vec::new();
        let mut intrusions = Vec::new();
        let (mut other, mut misplaced) = (0, 0);
        for e in &self.entries {
            match e.result {
                "ok" => {
                    if let Some(i) = words.iter().position(|w| fold(w.text()) == e.key) {
                        positions[i] = true;
                        order.push(i);
                    }
                }
                "misplaced" => misplaced += 1,
                "other_list" => {
                    other += 1;
                    intrusions.push(e.word.clone().unwrap_or_else(|| e.text.clone()));
                }
                "intrusion" => intrusions.push(e.text.clone()),
                _ => {}
            }
        }
        self.rounds.push(Round {
            label,
            list,
            serial,
            total: words.len(),
            positions,
            order,
            intrusions,
            other_list: other,
            misplaced,
        });
        self.advance();
    }

    fn submit(&mut self, raw: &str) -> Result<(), String> {
        let Some(Step::Recall { list, serial, .. }) = self.cur().cloned() else {
            return Err("Şu an kelime yazma zamanı değil".into());
        };
        let key = fold(raw);
        if key.is_empty() {
            return Err("Önce kelimeyi yaz".into());
        }
        if self.entries.iter().any(|e| e.key == key) {
            return Err("Bunu zaten yazdın".into());
        }
        let words = &self.lists[list];
        if serial && self.entries.len() >= words.len() {
            return Err("Bütün sıralar doldu".into());
        }
        let hit = words.iter().position(|w| fold(w.text()) == key);
        let other = self.lists[1 - list].iter().find(|w| fold(w.text()) == key).copied();
        let (result, word) = match (hit, other) {
            (Some(i), _) if !serial || i == self.entries.len() => ("ok", Some(words[i].text())),
            (Some(i), _) => ("misplaced", Some(words[i].text())),
            (None, Some(w)) => ("other_list", Some(w.text())),
            (None, None) => ("intrusion", None),
        };
        let fixed = word.is_some_and(|w| tr_lower(raw) != w);
        self.entries.push(Entry {
            text: tr_lower(raw),
            key,
            result,
            word: word.map(str::to_string),
            fixed,
        });
        if serial && self.entries.len() >= words.len() {
            self.end_recall();
        }
        Ok(())
    }

    fn finish_run(&mut self) {
        self.stage = Stage::Review;
        let pct = |a: usize, b: usize| if b == 0 { 0.0 } else { a as f64 / b as f64 };
        self.score = match self.p.variant {
            Variant::Recognition => {
                let ok = self.probe.iter().zip(&self.rec_answers).filter(|((_, t), a)| t == *a).count();
                pct(ok, self.probe.len())
            }
            Variant::Learning => self.rounds.last().map(|r| pct(r.found(), r.total)).unwrap_or(0.0),
            _ => pct(self.rounds.iter().map(Round::found).sum(), self.rounds.iter().map(|r| r.total).sum()),
        };
        let th = self.p.thresholds;
        let s = self.score + 1e-9;
        self.stars = if s >= th[2] {
            3
        } else if s >= th[1] {
            2
        } else if s >= th[0] {
            1
        } else {
            0
        };
    }

    fn pct_label(x: f64) -> String {
        format!("%{}", (x * 100.0).round() as i64)
    }

    fn summary(&self) -> String {
        let pct = Self::pct_label(self.score);
        match self.p.variant {
            Variant::Recognition => {
                let hits = self.probe.iter().zip(&self.rec_answers).filter(|((_, t), a)| *t && **a).count();
                let fa = self.probe.iter().zip(&self.rec_answers).filter(|((_, t), a)| !*t && **a).count();
                format!("Doğru {pct} · İsabet {hits}/{} · Yanlış alarm {fa}", self.lists[0].len())
            }
            Variant::Learning => {
                let curve: Vec<String> = self.rounds.iter().map(|r| r.found().to_string()).collect();
                format!("Denemeler {} / {} · Son deneme {pct}", curve.join(" → "), self.lists[0].len())
            }
            Variant::Serial => {
                let r = self.rounds.first();
                format!("Doğru sırada {}/{} ({pct})", r.map(Round::found).unwrap_or(0), self.lists[0].len())
            }
            _ => {
                let found: usize = self.rounds.iter().map(Round::found).sum();
                let total: usize = self.rounds.iter().map(|r| r.total).sum();
                let intr: usize = self.rounds.iter().map(|r| r.intrusions.len()).sum();
                format!("Hatırlanan {found}/{total} ({pct}) · Araya giren {intr}")
            }
        }
    }

    fn results(&self) -> Value {
        let a = &self.lists[0];
        let n = a.len();
        // Serial position curve for List A: share of A-rounds (or the recognition hit) per slot.
        let a_rounds: Vec<&Round> = self.rounds.iter().filter(|r| r.list == 0).collect();
        let curve: Vec<f64> = if self.p.variant == Variant::Recognition {
            a.iter()
                .map(|w| {
                    let i = self.probe.iter().position(|(x, _)| x == w);
                    let said = i.and_then(|i| self.rec_answers.get(i)).copied().unwrap_or(false);
                    if said { 1.0 } else { 0.0 }
                })
                .collect()
        } else {
            (0..n)
                .map(|i| {
                    let k = a_rounds.iter().filter(|r| r.positions[i]).count();
                    if a_rounds.is_empty() { 0.0 } else { k as f64 / a_rounds.len() as f64 }
                })
                .collect()
        };
        let third = (n / 3).max(1);
        let mean = |s: &[f64]| if s.is_empty() { 0.0 } else { s.iter().sum::<f64>() / s.len() as f64 };
        let primacy = mean(&curve[..third.min(n)]);
        let recency = mean(&curve[n.saturating_sub(third)..]);
        let middle = mean(&curve[third.min(n)..n.saturating_sub(third).max(third.min(n))]);
        let mut intrusions: Vec<String> = Vec::new();
        for r in &self.rounds {
            for w in &r.intrusions {
                if !intrusions.contains(w) {
                    intrusions.push(w.clone());
                }
            }
        }
        let missed: Vec<&str> = a.iter().enumerate().filter(|(i, _)| curve[*i] == 0.0).map(|(_, w)| w.text()).collect();
        // Clustering: consecutive correct recalls from the same category, over possible pairs.
        let (mut same, mut pairs) = (0usize, 0usize);
        for r in self.rounds.iter().filter(|r| !r.serial) {
            let words = &self.lists[r.list];
            for w in r.order.windows(2) {
                pairs += 1;
                if words[w[0]].cat == words[w[1]].cat {
                    same += 1;
                }
            }
        }
        let false_alarms: Vec<&str> = self
            .probe
            .iter()
            .zip(&self.rec_answers)
            .filter(|((_, t), a)| !*t && **a)
            .map(|((w, _), _)| w.text())
            .collect();
        json!({
            "variant": self.p.variant.key(),
            "score_pct": (self.score * 100.0).round(),
            "rounds": self.rounds.iter().map(|r| json!({
                "label": r.label, "list": if r.list == 0 { "A" } else { "B" }, "found": r.found(), "total": r.total,
                "intrusions": r.intrusions.len(), "other_list": r.other_list, "misplaced": r.misplaced,
            })).collect::<Vec<_>>(),
            "learning": if self.p.variant == Variant::Learning {
                Some(self.rounds.iter().map(Round::found).collect::<Vec<_>>())
            } else { None },
            "serial_position": curve,
            "primacy": primacy, "middle": middle, "recency": recency,
            "intrusions": intrusions,
            "false_alarms": false_alarms,
            "missed": missed,
            "clustering": if pairs == 0 { None } else { Some(same as f64 / pairs as f64) },
            "list_a": a.iter().map(|w| w.text()).collect::<Vec<_>>(),
            "categories": a.iter().map(|w| BANK[w.cat].0).collect::<Vec<_>>(),
            "list_b": if self.lists[1].is_empty() { None } else { Some(self.lists[1].iter().map(|w| w.text()).collect::<Vec<_>>()) },
            "distract": self.distract_stats.map(|(r, w)| json!({"right": r, "wrong": w})),
            "thresholds": self.p.thresholds,
        })
    }

    fn status(&self) -> &'static str {
        match self.stage {
            Stage::Done if self.stars > 0 => "won",
            Stage::Done => "lost",
            _ => "playing",
        }
    }

    fn goal(&self) -> String {
        let n = self.p.words;
        let rate = format!("{:.1}", self.p.rate_ms / 1000.0).replace('.', ",");
        let tail = match self.p.variant {
            Variant::Free => "sonra hatırladıklarını yaz".to_string(),
            Variant::Serial => "sonra aynı sırayla yaz".to_string(),
            Variant::Learning => "3 deneme · son deneme sayılır".to_string(),
            Variant::Recognition => "sonra listede olanları seç".to_string(),
            Variant::Interference => "araya B listesi girer".to_string(),
            Variant::Delayed => format!("{} sn ara görevden sonra tekrar", (self.p.distract_ms / 1000.0).round()),
        };
        format!("{n} kelime · {rate} sn · {tail}")
    }

    fn phase(&self) -> &'static str {
        match self.stage {
            Stage::Intro => "intro",
            Stage::Review => "review",
            Stage::Done => "done",
            Stage::Run => match self.cur() {
                Some(Step::Countdown { .. }) => "countdown",
                Some(Step::Study { .. }) => "study",
                Some(Step::Recall { .. }) => "recall",
                Some(Step::Recognize) => "recognize",
                Some(Step::Distract) => "distract",
                None => "review",
            },
        }
    }
}

impl Session for WordList {
    fn state(&self) -> Value {
        let mut st = json!({
            "status": self.status(),
            "stars": if self.stage == Stage::Done || self.stage == Stage::Review { self.stars } else { 0 },
            "title": self.p.variant.title(),
            "goal": self.goal(),
            "score": (self.score * 100.0).round() as i64,
            "phase": self.phase(),
            "variant": self.p.variant.key(),
            "level": self.level,
            "words": self.p.words,
            "rate_ms": self.p.rate_ms,
            "step": self.step,
            "steps": self.steps.len(),
            "thresholds": self.p.thresholds,
        });
        let o = st.as_object_mut().expect("object");
        match self.cur() {
            Some(Step::Countdown { ms, banner }) => {
                o.insert("countdown".into(), json!({"remaining_ms": (ms - self.step_ms).max(0.0).round(), "total_ms": ms, "banner": banner}));
            }
            Some(Step::Study { list, trial }) => {
                let slot = self.p.rate_ms;
                let idx = ((self.step_ms / slot) as usize).min(self.lists[*list].len() - 1);
                let into = self.step_ms - idx as f64 * slot;
                let word = if into < slot * 0.85 { Some(self.lists[*list][idx].text()) } else { None };
                o.insert(
                    "study".into(),
                    json!({
                        "list": if *list == 0 { "A" } else { "B" }, "trial": trial, "trials": self.p.trials,
                        "index": idx, "total": self.lists[*list].len(), "word": word,
                        "slot_ms": slot, "t_ms": into.round(),
                    }),
                );
            }
            Some(Step::Recall { list, serial, label }) => {
                o.insert(
                    "recall".into(),
                    json!({
                        "label": label, "list": if *list == 0 { "A" } else { "B" }, "serial": serial,
                        "total": self.lists[*list].len(),
                        "found": self.entries.iter().filter(|e| e.result == "ok").count(),
                        "entries": self.entries.iter().map(|e| json!({
                            "text": e.text, "result": e.result, "word": e.word, "fixed": e.fixed,
                        })).collect::<Vec<_>>(),
                        "remaining_ms": (self.p.recall_ms - self.step_ms).max(0.0).round(),
                        "limit_ms": self.p.recall_ms,
                    }),
                );
            }
            Some(Step::Recognize) => {
                let i = self.rec_answers.len();
                let correct = self.probe.iter().zip(&self.rec_answers).filter(|((_, t), a)| t == *a).count();
                o.insert(
                    "recognize".into(),
                    json!({
                        "index": i, "total": self.probe.len(),
                        "word": self.probe.get(i).map(|(w, _)| w.text()),
                        "correct": correct,
                        "last": self.rec_last.map(|(s, c, said, t)| json!({"serial": s, "correct": c, "said": said, "target": t})),
                    }),
                );
            }
            Some(Step::Distract) => {
                if let Some(d) = &self.distract {
                    o.insert("distract".into(), d.state());
                }
            }
            None => {}
        }
        if matches!(self.stage, Stage::Review | Stage::Done) {
            o.insert("results".into(), self.results());
        }
        if self.stage == Stage::Done {
            o.insert("summary".into(), json!(self.summary()));
        }
        st
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        match self.stage {
            Stage::Done => return Err("Bölüm bitti".into()),
            Stage::Intro => {
                if a["start"].as_bool() == Some(true) {
                    self.stage = Stage::Run;
                    self.step = 0;
                    self.step_ms = 0.0;
                    return Ok(());
                }
                return Err("Önce Başla'ya dokun".into());
            }
            Stage::Review => {
                if a["finish"].as_bool() == Some(true) {
                    self.stage = Stage::Done;
                    return Ok(());
                }
                return Err("Sonucu görmek için Bitir'e dokun".into());
            }
            Stage::Run => {}
        }
        if a["start"].as_bool() == Some(true) {
            return Err("Oyun zaten başladı".into());
        }
        match self.cur().cloned() {
            Some(Step::Recall { list, serial, .. }) => {
                if let Some(w) = a["word"].as_str() {
                    return self.submit(w);
                }
                if a["skip_slot"].as_bool() == Some(true) {
                    if !serial {
                        return Err("Sıra atlamak sadece sıralı hatırlamada var".into());
                    }
                    self.entries.push(Entry { text: String::new(), key: String::new(), result: "skip", word: None, fixed: false });
                    if self.entries.len() >= self.lists[list].len() {
                        self.end_recall();
                    }
                    return Ok(());
                }
                if a["done"].as_bool() == Some(true) {
                    self.end_recall();
                    return Ok(());
                }
                Err("Bilinmeyen hamle".into())
            }
            Some(Step::Recognize) => {
                let said = a["answer"].as_bool().ok_or("Evet ya da Hayır seç")?;
                let i = self.rec_answers.len();
                let target = self.probe[i].1;
                self.rec_answers.push(said);
                self.rec_serial += 1;
                self.rec_last = Some((self.rec_serial, said == target, said, target));
                if self.rec_answers.len() >= self.probe.len() {
                    self.advance();
                }
                Ok(())
            }
            Some(Step::Distract) => {
                let said = a["judge"].as_bool().ok_or("Doğru ya da Yanlış seç")?;
                let d = self.distract.as_mut().ok_or("Ara görev yok")?;
                if d.done() {
                    return Err("Süre doldu".into());
                }
                d.judge(said);
                Ok(())
            }
            Some(Step::Study { .. }) => Err("Kelimeleri izle; yazma sırası birazdan".into()),
            Some(Step::Countdown { .. }) => Err("Hazırlan…".into()),
            None => Err("Bilinmeyen hamle".into()),
        }
    }

    fn tick(&mut self, dt_ms: f64) {
        if self.stage != Stage::Run || !(dt_ms > 0.0) {
            return;
        }
        self.step_ms += dt_ms;
        match self.cur().cloned() {
            Some(Step::Countdown { ms, .. }) => {
                if self.step_ms >= ms {
                    self.advance();
                }
            }
            Some(Step::Study { list, .. }) => {
                if self.step_ms >= self.p.rate_ms * self.lists[list].len() as f64 {
                    self.advance();
                }
            }
            Some(Step::Recall { .. }) => {
                if self.step_ms >= self.p.recall_ms {
                    self.step_ms = self.p.recall_ms;
                    self.end_recall();
                }
            }
            Some(Step::Distract) => {
                if self.distract.as_mut().is_some_and(|d| d.tick(dt_ms)) {
                    self.advance();
                }
            }
            Some(Step::Recognize) | None => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LEVELS: [u32; 9] = [1, 2, 3, 50, 137, 250, 400, 499, 500];

    fn run_until(g: &mut WordList, phase: &str) {
        for _ in 0..200_000 {
            if g.phase() == phase {
                return;
            }
            g.tick(50.0);
        }
        panic!("never reached {phase}, stuck in {}", g.phase());
    }

    /// Perfect player: recalls every word in order, answers recognition and distractor correctly.
    fn play_perfect(level: u32) -> WordList {
        let mut g = WordList::new(level);
        g.act(&json!({"start": true})).unwrap();
        for _ in 0..1_000_000 {
            match g.phase() {
                "review" => break,
                "recall" => {
                    let Some(Step::Recall { list, .. }) = g.cur().cloned() else { unreachable!() };
                    let words: Vec<&str> = g.lists[list].iter().map(|w| w.text()).collect();
                    let done = g.entries.len();
                    for w in &words[done..] {
                        g.act(&json!({"word": w})).unwrap();
                    }
                    if g.phase() == "recall" {
                        g.act(&json!({"done": true})).unwrap();
                    }
                }
                "recognize" => {
                    let i = g.rec_answers.len();
                    let t = g.probe[i].1;
                    g.act(&json!({"answer": t})).unwrap();
                }
                "distract" => {
                    let truth = g.distract.as_ref().unwrap().truth;
                    g.act(&json!({"judge": truth})).unwrap();
                    g.tick(400.0);
                }
                _ => g.tick(40.0),
            }
        }
        assert_eq!(g.phase(), "review");
        g.act(&json!({"finish": true})).unwrap();
        g
    }

    #[test]
    fn bank_is_large_unique_and_single_words() {
        assert!(bank_size() >= 600, "bank has {}", bank_size());
        let mut seen = std::collections::HashMap::new();
        for (c, (_, words)) in BANK.iter().enumerate() {
            assert!(words.len() >= 13, "category {c} too small");
            for w in *words {
                assert!(!w.contains(' ') && !w.is_empty(), "{w}");
                assert_eq!(tr_lower(w), *w, "{w} must be lower case");
                if let Some(prev) = seen.insert(fold(w), *w) {
                    panic!("{w} folds like {prev}");
                }
            }
        }
    }

    #[test]
    fn fold_rules() {
        assert_eq!(fold("  KÖPEK "), "kopek");
        assert_eq!(fold("Işık"), "isik");
        assert_eq!(fold("İNCİR"), "incir");
        assert_eq!(fold("çiçek  bahçesi"), "cicek bahcesi");
        assert_eq!(tr_lower("IŞIK"), "ışık");
        assert_eq!(tr_lower("İzmir"), "izmir");
    }

    #[test]
    fn params_curve() {
        for l in LEVELS {
            let p = params(l);
            assert!((6..=30).contains(&p.words), "{l}: {}", p.words);
            assert!(p.rate_ms >= 800.0 && p.rate_ms <= 2500.0);
            assert!(p.thresholds[0] < p.thresholds[1] && p.thresholds[1] < p.thresholds[2]);
            assert!((60_000.0..=90_000.0).contains(&p.distract_ms));
        }
        assert_eq!(params(1).words, 8);
        assert_eq!(params(1).rate_ms, 2500.0);
        assert_eq!(params(497).words, 30);
        assert_eq!(params(500).words, 30);
        assert_eq!(params(500).rate_ms, 800.0);
        assert_eq!(params(1).variant, Variant::Free);
        assert_eq!(params(2).variant, Variant::Learning);
        assert_eq!(params(3).variant, Variant::Recognition);
        assert_eq!(params(4).variant, Variant::Interference);
        assert_eq!(params(5).variant, Variant::Delayed);
        assert!((100..=500).any(|l| params(l).variant == Variant::Serial));
        assert!((1..100).all(|l| params(l).variant != Variant::Serial));
    }

    #[test]
    fn levels_generate_deterministic_and_interleaved() {
        for l in LEVELS.iter().copied().chain(1..=10) {
            let g1 = WordList::new(l);
            let g2 = WordList::new(l);
            assert_eq!(g1.lists, g2.lists);
            assert_eq!(g1.probe, g2.probe);
            let a = &g1.lists[0];
            assert_eq!(a.len(), g1.p.words);
            let mut texts: Vec<&str> = g1.lists.iter().flatten().map(|w| w.text()).collect();
            let all = texts.len();
            texts.sort();
            texts.dedup();
            assert_eq!(texts.len(), all, "duplicate words in level {l}");
            let adjacent = a.windows(2).filter(|w| w[0].cat == w[1].cat).count();
            assert!(adjacent <= 1, "level {l}: {adjacent} same-category neighbours");
            if g1.p.variant == Variant::Interference {
                assert_eq!(g1.lists[1].len(), a.len());
                assert!(g1.lists[1].iter().all(|w| !a.contains(w)), "B overlaps A in level {l}");
            }
        }
    }

    #[test]
    fn lures_never_equal_targets_and_are_related() {
        for l in 1..=500u32 {
            let p = params(l);
            if p.variant != Variant::Recognition {
                continue;
            }
            let g = WordList::new(l);
            let targets: Vec<Word> = g.probe.iter().filter(|(_, t)| *t).map(|(w, _)| *w).collect();
            let lures: Vec<Word> = g.probe.iter().filter(|(_, t)| !*t).map(|(w, _)| *w).collect();
            assert_eq!(targets.len(), lures.len());
            for lure in &lures {
                assert!(!targets.contains(lure), "level {l}: lure is a target");
                assert!(targets.iter().any(|t| t.cat == lure.cat), "level {l}: lure unrelated");
                assert!(targets.iter().all(|t| fold(t.text()) != fold(lure.text())));
            }
            let mut u = lures.clone();
            u.dedup();
            assert_eq!(u.len(), lures.len());
        }
    }

    #[test]
    fn perfect_play_wins_three_stars_everywhere() {
        for l in LEVELS.iter().copied().chain(1..=10) {
            let g = play_perfect(l);
            assert_eq!(g.status(), "won", "level {l}");
            assert_eq!(g.stars, 3, "level {l}");
            assert!((g.score - 1.0).abs() < 1e-9);
            let st = g.state();
            assert!(st["summary"].is_string());
            assert_eq!(st["results"]["serial_position"].as_array().unwrap().len(), g.lists[0].len());
        }
    }

    #[test]
    fn recall_scoring_and_tolerance() {
        let mut g = WordList::new(1);
        g.act(&json!({"start": true})).unwrap();
        run_until(&mut g, "recall");
        let words: Vec<&str> = g.lists[0].iter().map(|w| w.text()).collect();
        // Upper case and missing diacritics are accepted.
        let w0 = words[0];
        let sloppy = fold(w0).to_uppercase();
        g.act(&json!({"word": sloppy})).unwrap();
        assert_eq!(g.entries[0].result, "ok");
        assert_eq!(g.entries[0].fixed, sloppy.to_lowercase() != w0);
        // Repeats are rejected and leave state unchanged.
        let before = g.state();
        assert!(g.act(&json!({"word": w0})).is_err());
        assert_eq!(before, g.state());
        // Empty input rejected.
        assert!(g.act(&json!({"word": "   "})).is_err());
        // A typo is not accepted: it is an intrusion.
        let typo = format!("{}x", words[1]);
        g.act(&json!({"word": typo})).unwrap();
        assert_eq!(g.entries[1].result, "intrusion");
        // A word from the bank but not in the list is an intrusion too.
        let outside = BANK.iter().flat_map(|(_, w)| w.iter()).find(|w| !words.contains(w)).unwrap();
        g.act(&json!({"word": outside})).unwrap();
        assert_eq!(g.entries[2].result, "intrusion");
        g.act(&json!({"word": words[2]})).unwrap();
        g.act(&json!({"done": true})).unwrap();
        assert_eq!(g.phase(), "review");
        assert_eq!(g.rounds[0].found(), 2);
        assert_eq!(g.rounds[0].intrusions.len(), 2);
        assert!((g.score - 2.0 / 8.0).abs() < 1e-9);
        g.act(&json!({"finish": true})).unwrap();
        assert_eq!(g.status(), "lost");
        assert!(g.state()["summary"].as_str().unwrap().contains("2/8"));
    }

    #[test]
    fn stars_follow_thresholds() {
        // Level 1: 8 words. 1★ ≥ 60 % (5), 2★ ≥ 75 % (6), 3★ ≥ 90 % (8).
        for (k, want) in [(4usize, 0u32), (5, 1), (6, 2), (7, 2), (8, 3)] {
            let mut g = WordList::new(1);
            g.act(&json!({"start": true})).unwrap();
            run_until(&mut g, "recall");
            let words: Vec<&str> = g.lists[0].iter().map(|w| w.text()).collect();
            for w in &words[..k] {
                g.act(&json!({"word": w})).unwrap();
            }
            g.act(&json!({"done": true})).unwrap();
            assert_eq!(g.stars, want, "k={k}");
        }
    }

    #[test]
    fn serial_scoring_is_positional() {
        let l = (100..=500).find(|&l| params(l).variant == Variant::Serial).unwrap();
        let mut g = WordList::new(l);
        g.act(&json!({"start": true})).unwrap();
        run_until(&mut g, "recall");
        let words: Vec<&str> = g.lists[0].iter().map(|w| w.text()).collect();
        g.act(&json!({"word": words[1]})).unwrap(); // wrong slot
        assert_eq!(g.entries[0].result, "misplaced");
        assert!(g.act(&json!({"skip_slot": true})).is_ok());
        g.act(&json!({"word": words[2]})).unwrap(); // right slot
        assert_eq!(g.entries[2].result, "ok");
        g.act(&json!({"done": true})).unwrap();
        assert_eq!(g.rounds[0].found(), 1);
        assert_eq!(g.rounds[0].misplaced, 1);
    }

    #[test]
    fn delayed_phase_runs_distractor_then_recall() {
        let mut g = WordList::new(5);
        assert_eq!(g.p.variant, Variant::Delayed);
        g.act(&json!({"start": true})).unwrap();
        run_until(&mut g, "recall");
        g.act(&json!({"done": true})).unwrap();
        run_until(&mut g, "distract");
        // Recall actions are illegal during the distractor.
        assert!(g.act(&json!({"word": "elma"})).is_err());
        g.act(&json!({"judge": true})).unwrap();
        assert_eq!(g.distract.as_ref().map(|d| d.serial), Some(1));
        let total = g.p.distract_ms;
        g.tick(total / 2.0);
        assert_eq!(g.phase(), "distract");
        g.tick(total);
        assert_eq!(g.phase(), "recall");
        assert!(g.state()["recall"]["label"].as_str().unwrap().contains("Gecikmeli"));
        // Running out of time ends the round.
        g.tick(g.p.recall_ms + 10.0);
        assert_eq!(g.phase(), "review");
        assert_eq!(g.rounds.len(), 2);
        assert!(g.results()["distract"].is_object());
    }

    #[test]
    fn interference_flags_b_words_while_recalling_a() {
        let mut g = WordList::new(4);
        assert_eq!(g.p.variant, Variant::Interference);
        g.act(&json!({"start": true})).unwrap();
        run_until(&mut g, "recall");
        g.act(&json!({"done": true})).unwrap();
        run_until(&mut g, "recall");
        assert_eq!(g.state()["recall"]["list"], "B");
        let b0 = g.lists[1][0].text();
        g.act(&json!({"word": b0})).unwrap();
        g.act(&json!({"done": true})).unwrap();
        assert_eq!(g.state()["recall"]["list"], "A");
        g.act(&json!({"word": b0})).unwrap();
        assert_eq!(g.entries[0].result, "other_list");
        g.act(&json!({"done": true})).unwrap();
        assert_eq!(g.phase(), "review");
        assert_eq!(g.rounds[2].other_list, 1);
    }

    #[test]
    fn learning_curve_and_recognition_paths() {
        // Learning: three rounds, the last one scores.
        let mut g = WordList::new(2);
        g.act(&json!({"start": true})).unwrap();
        for trial in 0..3 {
            run_until(&mut g, "recall");
            let words: Vec<&str> = g.lists[0].iter().map(|w| w.text()).collect();
            for w in &words[..4 + 2 * trial] {
                g.act(&json!({"word": w})).unwrap();
            }
            g.act(&json!({"done": true})).unwrap();
        }
        assert_eq!(g.phase(), "review");
        assert_eq!(g.results()["learning"], json!([4, 6, 8]));
        assert_eq!(g.stars, 3);
        // Recognition: saying yes to everything = 50 % → lost.
        let mut g = WordList::new(3);
        g.act(&json!({"start": true})).unwrap();
        run_until(&mut g, "recognize");
        assert!(g.act(&json!({"word": "elma"})).is_err());
        while g.phase() == "recognize" {
            g.act(&json!({"answer": true})).unwrap();
        }
        g.act(&json!({"finish": true})).unwrap();
        assert_eq!(g.status(), "lost");
    }

    #[test]
    fn illegal_actions_rejected_and_state_unchanged() {
        let mut g = WordList::new(1);
        let s0 = g.state();
        assert!(g.act(&json!({"word": "elma"})).is_err());
        g.tick(5000.0); // no clock before start
        assert_eq!(s0, g.state());
        g.act(&json!({"start": true})).unwrap();
        assert!(g.act(&json!({"start": true})).is_err());
        run_until(&mut g, "study");
        let s1 = g.state();
        assert!(g.act(&json!({"word": "elma"})).is_err());
        assert!(g.act(&json!({"answer": true})).is_err());
        assert_eq!(s1, g.state());
        let mut g = play_perfect(1);
        assert!(g.act(&json!({"word": "elma"})).is_err());
    }

    #[test]
    #[ignore]
    fn timing_500_levels() {
        let t0 = std::time::Instant::now();
        for l in 1..=500 {
            let g = WordList::new(l);
            assert!(!g.lists[0].is_empty());
        }
        let el = t0.elapsed();
        println!("word_list: 500 levels in {:?} ({:?}/level)", el, el / 500);
    }
}
