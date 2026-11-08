//! Hafıza Sarayı — a method-of-loci trainer.
//!
//! The game supplies the palace: five built-in walks ([`PALACES`]: Ev, Yurt, Okul, Mahalle yolu,
//! Ofis), each 40 ordered stations. A level always walks the first N stations from the entrance,
//! like a real palace. A word bank of concrete, picturable Turkish nouns ([`BANK`], grouped into
//! categories that drive distractor similarity) supplies the items.
//!
//! Round: **show** — station by station the player sees "Durak 4 · Boy aynası → FİL" and taps
//! (or swipes) to place it; each item has a time limit, after which it is placed automatically.
//! **Recall** — for every station the player picks the item from a grid of candidates
//! (recognition) or types it (free recall at higher levels). Probe orders: forward, reverse, random
//! stations ("12. durakta ne vardı?"). Interference levels place two lists in the same palace:
//! list A is learned and recalled, the player "clears" the palace, then list B goes onto the same
//! stations and is recalled with A's item at each station offered as a lure.
//!
//! Candidates (recognition): the right item exactly once, plus lures from the same list (order /
//! binding errors; at higher similarity the neighbouring stations' items first), from the same
//! category (semantic similarity; at high similarity same first letter preferred), the other list's
//! item at that station (interference levels), and random fill. Items never share a word with any
//! station name of the palace (no "taksi" at "Taksi durağı").
//!
//! Typed answers are compared after Turkish case folding and dropping diacritics and spaces
//! ("kopek" = "Köpek"); words of 6+ letters also accept one typo (edit distance 1).
//!
//! Level curve (`params(level)`), t = (level−1)/499:
//! - list length 5 → 40: `round(5 + 35·t^0.9)` (≈ 9 at level 50, 16 at 137, 24 at 250, 34 at 400);
//!   typed levels use 70% of it, two-list levels 55% per list.
//! - time per item 12 s → 3 s: `12 − 9·t^0.75` seconds, in 0.5 s steps.
//! - candidates 6 → 9 (reached at level 250); similarity = t (more same-category and neighbour lures).
//! - 6-level cycle: forward · forward (typed from 200) · reverse (typed from 320) ·
//!   forward (typed from 60) · random stations (typed from 260) · two lists (from 24; before that
//!   reverse). The second list is probed in random order from level 200.
//! - palace changes every 10 levels: Ev, Yurt, Okul, Mahalle yolu, Ofis, Ev, …
//! - Major-system / number lists are taught in the tutorial only (not a game variant).
//!
//! Stars by accuracy (+ speed): ≥ 95% correct → 3, or ≥ 90% with an average placing time ≤ half
//! the limit → 3; ≥ 80% → 2; ≥ 60% → 1; below → `lost`.
//!
//! State: `{status, stars, mode, phase: "intro"|"countdown"|"show"|"recall"|"clear"|"done", title,
//!          goal, brief, summary?, score, palace, stations: [str], round, rounds, list_len, order,
//!          typed, countdown_ms, show: {index, total, number, station, item, elapsed_ms, limit_ms,
//!          remaining_ms}|null, probe: {pos, total, station_index, number, station,
//!          candidates: [str]|null}|null, marks: ["" | "placed" | "ok" | "bad"], correct, answered,
//!          total, round_correct: [n], last: {serial, correct, skipped, station_index, number,
//!          answer, given}|null}`
//! Actions: `{"start":true}` (intro / clear) · `{"next":true}` (place the shown item) ·
//!          `{"pick":i}` (candidate index) · `{"type":"fil"}` · `{"skip":true}` (don't remember)

use crate::rng::{seed_for, Rng};
use crate::Session;
use serde_json::{json, Value};

pub struct PalaceDef {
    pub name: &'static str,
    pub stations: [&'static str; 40],
}

pub const PALACES: [PalaceDef; 5] = [
    PalaceDef {
        name: "Ev",
        stations: [
            "Dış kapı", "Paspas", "Ayakkabılık", "Vestiyer", "Boy aynası", "Şemsiyelik", "Mutfak kapısı",
            "Mutfak tezgâhı", "Evye", "Ocak", "Fırın", "Buzdolabı", "Kiler", "Yemek masası",
            "Bulaşık makinesi", "Çöp kovası", "Salon kapısı", "Koltuk", "Sehpa", "Televizyon", "Kitaplık",
            "Pencere önü", "Saksı", "Halı", "Balkon kapısı", "Balkon sandalyesi", "Koridor lambası",
            "Banyo kapısı", "Lavabo", "Banyo aynası", "Duş", "Çamaşır makinesi", "Havlu askısı",
            "Yatak odası kapısı", "Gardırop", "Yatak", "Komodin", "Çalışma masası", "Sandalye", "Perde",
        ],
    },
    PalaceDef {
        name: "Yurt",
        stations: [
            "Yurt kapısı", "Turnike", "Nöbetçi masası", "İlan panosu", "Lobi", "Kargo rafı", "Asansör",
            "Merdiven", "Kat koridoru", "Oda kapısı", "Ranza", "Dolap", "Çalışma masası", "Masa lambası",
            "Pencere", "Kalorifer", "Ortak banyo", "Lavabo sırası", "Duşakabin", "Çamaşırhane",
            "Kurutma makinesi", "Ütü odası", "Etüt salonu", "Kitap rafı", "Mescit", "Abdesthane",
            "Televizyon odası", "Bilardo masası", "Kantin", "Yemekhane", "Tepsi rafı", "Çay ocağı",
            "Spor odası", "Koşu bandı", "Bahçe", "Kamelya", "Bisiklet park yeri", "Otopark",
            "Servis durağı", "Ana yol",
        ],
    },
    PalaceDef {
        name: "Okul",
        stations: [
            "Okul kapısı", "Güvenlik kulübesi", "Bayrak direği", "Okul bahçesi", "Kantin", "Giriş holü",
            "Müdür odası", "Öğretmenler odası", "Duyuru panosu", "Merdiven", "Koridor", "Sınıf kapısı",
            "Yazı tahtası", "Öğretmen masası", "Ön sıra", "Arka sıra", "Sınıf penceresi", "Sınıf dolabı",
            "Kütüphane", "Okuma masası", "Fen laboratuvarı", "Mikroskop", "Bilgisayar sınıfı",
            "Resim atölyesi", "Müzik sınıfı", "Spor salonu", "Basketbol potası", "Soyunma odası", "Revir",
            "Yemekhane", "Dağıtım tezgâhı", "Konferans salonu", "Sahne", "Kulis", "Arşiv odası",
            "Çatı katı", "Arka bahçe", "Futbol sahası", "Kale direği", "Tribün",
        ],
    },
    PalaceDef {
        name: "Mahalle yolu",
        stations: [
            "Apartman kapısı", "Posta kutuları", "Bahçe kapısı", "Kaldırım", "Çöp konteyneri", "Bakkal",
            "Sokak lambası", "Fırın", "Eczane", "Berber", "Manav", "Kasap", "Muhtarlık", "Yaya geçidi",
            "Trafik lambası", "Otobüs durağı", "Gazete bayii", "Çiçekçi", "Kırtasiye", "Park girişi",
            "Salıncak", "Kaydırak", "Kum havuzu", "Park bankı", "Süs havuzu", "Cami avlusu", "Şadırvan",
            "Kafe", "Pastane", "Bankamatik", "Postane", "Taksi durağı", "Oto yıkama", "Benzinlik",
            "Spor salonu", "Market", "Otopark", "Köprü", "Sahil yolu", "İskele",
        ],
    },
    PalaceDef {
        name: "Ofis",
        stations: [
            "Bina girişi", "Döner kapı", "Danışma bankosu", "Turnike", "Asansör", "Kat koridoru",
            "Resepsiyon", "Bekleme koltuğu", "Su sebili", "Fotokopi makinesi", "Yazıcı", "Toplantı odası",
            "Projeksiyon", "Beyaz tahta", "Açık ofis", "Benim masam", "Monitör", "Klavye", "Çekmece",
            "Saksı bitkisi", "Dosya dolabı", "Yönetici odası", "Ofis mutfağı", "Kahve makinesi",
            "Mikrodalga", "Ofis buzdolabı", "Dinlenme köşesi", "Masa tenisi", "Telefon kabini",
            "Sunucu odası", "Arşiv", "Muhasebe", "İnsan kaynakları", "Teras", "Merdiven boşluğu",
            "Yangın dolabı", "Çatı", "Otopark girişi", "Bisiklet parkı", "Çıkış kapısı",
        ],
    },
];

/// Word bank: concrete, picturable nouns by category (category = semantic similarity for lures).
pub const BANK: &[(&str, &[&str])] = &[
    ("hayvan", &[
        "fil", "zürafa", "aslan", "kaplan", "leopar", "ayı", "kutup ayısı", "kurt", "tilki", "tavşan",
        "kirpi", "sincap", "maymun", "goril", "kanguru", "deve", "at", "eşek", "inek", "koyun", "keçi",
        "timsah", "kaplumbağa", "yılan", "kertenkele", "kurbağa", "zebra", "gergedan", "su aygırı",
        "panda", "koala", "kedi", "köpek", "fare", "yarasa", "geyik",
    ]),
    ("kuş", &[
        "kartal", "baykuş", "papağan", "tavuk", "horoz", "civciv", "ördek", "kaz", "kuğu", "leylek",
        "flamingo", "güvercin", "karga", "serçe", "martı", "tavus kuşu", "penguen", "devekuşu", "hindi",
        "şahin", "kanarya", "pelikan", "ağaçkakan", "kumru",
    ]),
    ("deniz", &[
        "balina", "yunus", "köpekbalığı", "ahtapot", "denizanası", "yengeç", "ıstakoz", "karides",
        "denizyıldızı", "istiridye", "midye", "fok", "mors", "denizatı", "hamsi", "levrek", "vatoz",
        "kalamar", "japon balığı", "kılıç balığı", "deniz kabuğu",
    ]),
    ("böcek", &[
        "arı", "karınca", "kelebek", "uğur böceği", "sivrisinek", "çekirge", "örümcek", "akrep",
        "ateş böceği", "yusufçuk", "tırtıl", "salyangoz", "solucan", "sinek", "hamam böceği",
        "ağustos böceği", "peygamber devesi",
    ]),
    ("meyve", &[
        "elma", "armut", "muz", "çilek", "kiraz", "karpuz", "kavun", "üzüm", "portakal", "mandalina",
        "limon", "ananas", "nar", "incir", "şeftali", "kayısı", "erik", "ayva", "kivi", "hindistancevizi",
        "avokado", "böğürtlen", "dut", "vişne", "greyfurt", "hurma", "ceviz", "fındık", "kestane", "fıstık",
    ]),
    ("sebze", &[
        "domates", "salatalık", "biber", "patlıcan", "havuç", "patates", "soğan", "sarımsak", "lahana",
        "karnabahar", "brokoli", "ıspanak", "marul", "kabak", "bal kabağı", "mısır koçanı", "bezelye",
        "turp", "pancar", "enginar", "mantar", "pırasa", "kereviz", "bamya",
    ]),
    ("yiyecek", &[
        "simit", "poğaça", "börek", "baklava", "lokum", "dondurma", "pizza", "hamburger", "sandviç",
        "peynir", "zeytin", "yumurta", "bal", "reçel", "çikolata", "pasta", "kurabiye", "ekmek", "makarna",
        "pilav", "çorba", "lahmacun", "döner", "kebap", "mantı", "köfte", "pamuk şeker", "patlamış mısır",
        "krep", "sucuk", "ayran", "limonata", "gofret", "pişmaniye", "tost",
    ]),
    ("mutfak", &[
        "tava", "tencere", "çaydanlık", "kaşık", "çatal", "bıçak", "tabak", "bardak", "fincan", "kepçe",
        "rende", "oklava", "süzgeç", "termos", "demlik", "sürahi", "tuzluk", "mikser", "tost makinesi",
        "kevgir", "cezve", "havan", "fırın eldiveni", "önlük", "düdüklü tencere", "kesme tahtası",
    ]),
    ("alet", &[
        "çekiç", "tornavida", "pense", "testere", "matkap", "ingiliz anahtarı", "çivi", "vida",
        "şerit metre", "kürek", "tırpan", "balta", "el arabası", "hortum", "tırmık", "mengene", "zımpara",
        "su terazisi", "boya fırçası", "boya kovası", "halat", "zincir", "asma kilit", "makas",
        "el feneri", "kazma", "orak",
    ]),
    ("giysi", &[
        "şapka", "kasket", "atkı", "eldiven", "ceket", "palto", "kazak", "gömlek", "kravat", "papyon",
        "pantolon", "etek", "elbise", "çorap", "ayakkabı", "çizme", "terlik", "sandalet", "yağmurluk",
        "mayo", "pijama", "kemer", "yelek", "bere", "smokin", "gelinlik", "sabahlık", "fular",
    ]),
    ("aksesuar", &[
        "yüzük", "kolye", "küpe", "bilezik", "kol saati", "gözlük", "güneş gözlüğü", "cüzdan",
        "el çantası", "sırt çantası", "bavul", "şemsiye", "yelpaze", "taç", "broş", "tespih",
        "anahtarlık", "baston", "rozet", "madalya", "peruk", "takma bıyık", "saç tokası", "tarak",
    ]),
    ("araç", &[
        "otomobil", "otobüs", "kamyon", "tren", "tramvay", "uçak", "helikopter", "gemi", "kayık",
        "yelkenli", "denizaltı", "bisiklet", "motosiklet", "traktör", "ambulans", "itfaiye aracı", "taksi",
        "roket", "sıcak hava balonu", "kızak", "at arabası", "vapur", "minibüs", "zeplin", "kano",
        "teleferik", "buldozer", "vinç",
    ]),
    ("müzik", &[
        "davul", "gitar", "keman", "piyano", "flüt", "trompet", "saksafon", "bağlama", "ud", "kanun",
        "ney", "zurna", "akordeon", "arp", "darbuka", "tef", "trampet", "mızıka", "org", "çello",
        "ksilofon", "metronom",
    ]),
    ("spor", &[
        "futbol topu", "basketbol topu", "tenis raketi", "bowling labutu", "dart oku", "frizbi", "kaykay",
        "paten", "kayak", "sörf tahtası", "boks eldiveni", "dambıl", "atlama ipi", "golf sopası",
        "beyzbol sopası", "kupa", "düdük", "kronometre", "olta", "çadır", "uyku tulumu", "pusula", "dürbün",
    ]),
    ("oyuncak", &[
        "uçurtma", "yoyo", "topaç", "misket", "zar", "satranç tahtası", "yapboz", "oyuncak ayı", "kukla",
        "maske", "sihirli değnek", "hazine sandığı", "su tabancası", "kum kovası", "balon", "iskambil",
        "oyuncak tren", "kurmalı fare", "tahta at",
    ]),
    ("ev eşyası", &[
        "avize", "abajur", "yastık", "yorgan", "battaniye", "vazo", "çerçeve", "mum", "şamdan", "sepet",
        "beşik", "hamak", "sandık", "kafes", "kova", "süpürge", "faraş", "mandal", "ütü",
        "elektrik süpürgesi", "duvar saati", "kum saati", "çalar saat", "akvaryum", "şömine", "kilim",
        "seccade", "minder", "termometre", "anahtar",
    ]),
    ("elektronik", &[
        "cep telefonu", "dizüstü bilgisayar", "tablet", "kulaklık", "hoparlör", "mikrofon", "kamera",
        "fotoğraf makinesi", "radyo", "kumanda", "şarj aleti", "pil", "ampul", "robot", "dron",
        "oyun konsolu", "hesap makinesi", "daktilo", "plak", "kaset", "uydu anteni", "gramofon", "lazer",
        "mıknatıs",
    ]),
    ("kırtasiye", &[
        "kalem", "silgi", "cetvel", "defter", "kitap", "zımba", "ataş", "pergel", "harita", "dünya küresi",
        "mektup", "zarf", "pul", "mühür", "tebeşir", "boya kalemi", "palet", "tuval", "mürekkep",
        "dolma kalem", "takvim", "bant", "yapıştırıcı", "büyüteç", "parşömen", "tüy kalem",
    ]),
    ("doğa", &[
        "güneş", "ay", "yıldız", "bulut", "şimşek", "gökkuşağı", "yanardağ", "şelale", "dağ", "ada",
        "mağara", "kaya", "buzdağı", "kardan adam", "çam ağacı", "palmiye", "kaktüs", "kozalak",
        "meşe palamudu", "inci", "elmas", "altın külçesi", "kar tanesi", "kuyruklu yıldız", "kum tepesi",
    ]),
    ("çiçek", &[
        "gül", "lale", "papatya", "ayçiçeği", "menekşe", "orkide", "karanfil", "nergis", "yonca",
        "sarmaşık", "nilüfer", "zambak", "lavanta", "sümbül", "bambu", "kardelen",
    ]),
    ("kişi", &[
        "itfaiyeci", "polis", "doktor", "hemşire", "aşçı", "garson", "pilot", "astronot", "dalgıç",
        "palyaço", "sihirbaz", "korsan", "şövalye", "prenses", "kral", "kraliçe", "padişah", "çiftçi",
        "balıkçı", "postacı", "ressam", "dansçı", "boksör", "hakem", "cambaz", "çoban", "dedektif",
        "kovboy", "ninja", "samuray", "cadı", "dev", "cüce", "peri", "deniz kızı", "ejderha", "mumya",
        "bekçi", "terzi",
    ]),
];

/// Palace for a level: changes every 10 levels.
const PALACE_ORDER: [usize; 5] = [0, 1, 2, 3, 4];

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Order {
    Forward,
    Reverse,
    Random,
}

impl Order {
    fn key(self) -> &'static str {
        match self {
            Order::Forward => "forward",
            Order::Reverse => "reverse",
            Order::Random => "random",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Params {
    pub palace: usize,
    /// Items per list.
    pub len: usize,
    /// Show-time limit per item.
    pub show_ms: f64,
    pub order: Order,
    pub typed: bool,
    pub choices: usize,
    pub sim: f64,
    /// 1, or 2 for the interference variant.
    pub lists: usize,
    /// Probe order of the second list.
    pub order2: Order,
}

pub fn params(level: u32) -> Params {
    let level = level.clamp(1, crate::MAX_LEVEL);
    let t = (level - 1) as f64 / 499.0;
    let base = (5.0 + 35.0 * t.powf(0.9)).round() as usize;
    let (order, typed, lists) = match (level - 1) % 6 {
        0 => (Order::Forward, false, 1),
        1 => (Order::Forward, level >= 200, 1),
        2 => (Order::Reverse, level >= 320, 1),
        3 => (Order::Forward, level >= 60, 1),
        4 => (Order::Random, level >= 260, 1),
        _ if level >= 24 => (Order::Forward, false, 2),
        _ => (Order::Reverse, false, 1),
    };
    let len = if typed {
        ((base as f64 * 0.7).round() as usize).max(5)
    } else if lists == 2 {
        ((base as f64 * 0.55).round() as usize).max(4)
    } else {
        base
    }
    .min(40);
    let show_ms = ((12000.0 - 9000.0 * t.powf(0.75)) / 500.0).round() * 500.0;
    let choices = 6 + (3.0 * (t / 0.5).min(1.0)).floor() as usize;
    let palace = PALACE_ORDER[((level - 1) / 10) as usize % PALACE_ORDER.len()];
    let order2 = if level >= 200 { Order::Random } else { Order::Forward };
    Params { palace, len, show_ms, order, typed, choices: choices.min(9), sim: t, lists, order2 }
}

/// Turkish case folding + diacritics removal; keeps letters and digits only.
pub fn fold(s: &str) -> String {
    let mut out = String::new();
    for c in s.chars() {
        let c = match c {
            'İ' | 'I' | 'ı' | 'î' | 'Î' => 'i',
            'Ç' | 'ç' => 'c',
            'Ğ' | 'ğ' => 'g',
            'Ö' | 'ö' => 'o',
            'Ş' | 'ş' => 's',
            'Ü' | 'ü' | 'û' | 'Û' => 'u',
            'Â' | 'â' => 'a',
            c => c.to_lowercase().next().unwrap_or(c),
        };
        if c.is_alphanumeric() {
            out.push(c);
        }
    }
    out
}

fn edit_distance(a: &str, b: &str) -> usize {
    let a: Vec<char> = a.chars().collect();
    let b: Vec<char> = b.chars().collect();
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    for i in 1..=a.len() {
        let mut cur = vec![i; b.len() + 1];
        for j in 1..=b.len() {
            let sub = prev[j - 1] + usize::from(a[i - 1] != b[j - 1]);
            cur[j] = sub.min(prev[j] + 1).min(cur[j - 1] + 1);
        }
        prev = cur;
    }
    prev[b.len()]
}

/// Does a typed answer count as the item?
pub fn typed_matches(given: &str, answer: &str) -> bool {
    let g = fold(given);
    let a = fold(answer);
    if g.is_empty() {
        return false;
    }
    g == a || (a.chars().count() >= 6 && edit_distance(&g, &a) <= 1)
}

/// Flattened bank: (word, category index).
pub fn words() -> Vec<(&'static str, usize)> {
    BANK.iter().enumerate().flat_map(|(ci, (_, ws))| ws.iter().map(move |w| (*w, ci))).collect()
}

fn tokens(s: &str) -> Vec<String> {
    s.split_whitespace().map(fold).filter(|t| t.len() >= 2).collect()
}

/// Bank words usable in a palace: no word may share a token with a station name.
fn allowed_words(palace: usize, bank: &[(&'static str, usize)]) -> Vec<bool> {
    let station_tokens: Vec<String> = PALACES[palace].stations.iter().flat_map(|s| tokens(s)).collect();
    bank.iter()
        .map(|(w, _)| {
            let wt = tokens(w);
            !wt.iter().any(|t| station_tokens.iter().any(|s| s == t || (t.len() >= 4 && s.starts_with(t.as_str()))))
        })
        .collect()
}

#[derive(Clone, Debug)]
pub struct Probe {
    pub station: usize,
    /// Word ids (None = typed recall).
    pub candidates: Option<Vec<usize>>,
}

#[allow(clippy::too_many_arguments)]
fn make_candidates(
    rng: &mut Rng,
    bank: &[(&'static str, usize)],
    allowed: &[bool],
    list: &[usize],
    station: usize,
    other: Option<usize>,
    n: usize,
    sim: f64,
) -> Vec<usize> {
    let answer = list[station];
    let mut c = vec![answer];
    let push = |c: &mut Vec<usize>, w: usize| {
        if c.len() < n && !c.contains(&w) {
            c.push(w);
        }
    };
    if let Some(o) = other {
        push(&mut c, o);
    }
    // Same-list lures: order / binding errors. Neighbours first as similarity rises.
    let n_in = ((n - 1) as f64 * (0.5 - 0.15 * sim)).round() as usize;
    let mut others: Vec<usize> = (0..list.len()).filter(|&i| i != station).collect();
    rng.shuffle(&mut others);
    if sim > 0.35 {
        others.sort_by_key(|&i| i.abs_diff(station));
    }
    for &i in others.iter().take(n_in) {
        push(&mut c, list[i]);
    }
    // Same-category lures: semantic similarity (same first letter preferred when similarity is high).
    let n_cat = ((n - 1) as f64 * (0.15 + 0.5 * sim)).round() as usize;
    let cat = bank[answer].1;
    let first = fold(bank[answer].0).chars().next();
    let mut pool: Vec<usize> = (0..bank.len()).filter(|&w| bank[w].1 == cat && allowed[w] && !c.contains(&w)).collect();
    rng.shuffle(&mut pool);
    if sim > 0.6 {
        pool.sort_by_key(|&w| fold(bank[w].0).chars().next() != first);
    }
    let target = (c.len() + n_cat).min(n);
    for w in pool {
        if c.len() >= target {
            break;
        }
        push(&mut c, w);
    }
    // Random fill.
    let mut guard = 0;
    while c.len() < n && guard < 10_000 {
        guard += 1;
        let w = rng.below(bank.len());
        if allowed[w] {
            push(&mut c, w);
        }
    }
    rng.shuffle(&mut c);
    c
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Phase {
    Intro,
    Countdown,
    Show,
    Recall,
    Clear,
    Done,
}

impl Phase {
    fn key(self) -> &'static str {
        match self {
            Phase::Intro => "intro",
            Phase::Countdown => "countdown",
            Phase::Show => "show",
            Phase::Recall => "recall",
            Phase::Clear => "clear",
            Phase::Done => "done",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Mark {
    None,
    Placed,
    Ok,
    Bad,
}

#[derive(Clone, Debug)]
struct Feedback {
    serial: u32,
    correct: bool,
    skipped: bool,
    station: usize,
    answer: String,
    given: String,
}

const COUNTDOWN_MS: f64 = 3000.0;

pub struct PalaceGame {
    level: u32,
    p: Params,
    bank: Vec<(&'static str, usize)>,
    stations: Vec<&'static str>,
    lists: Vec<Vec<usize>>,
    probes: Vec<Vec<Probe>>,
    round: usize,
    phase: Phase,
    countdown_ms: f64,
    show_idx: usize,
    show_t: f64,
    show_times: Vec<f64>,
    probe_pos: usize,
    marks: Vec<Mark>,
    correct: u32,
    answered: u32,
    round_correct: Vec<u32>,
    last: Option<Feedback>,
    serial: u32,
    stars: u32,
    won: bool,
}

pub fn create(level: u32, _mode: &str) -> Result<Box<dyn Session>, String> {
    // Levels only (no endless mode in the catalog).
    Ok(Box::new(PalaceGame::new(level)))
}

impl PalaceGame {
    pub fn new(level: u32) -> Self {
        let p = params(level);
        let mut rng = Rng::new(seed_for("palace", level, 0));
        let bank = words();
        let allowed = allowed_words(p.palace, &bank);
        let stations: Vec<&'static str> = PALACES[p.palace].stations[..p.len].to_vec();
        let mut ids: Vec<usize> = (0..bank.len()).filter(|&w| allowed[w]).collect();
        rng.shuffle(&mut ids);
        let lists: Vec<Vec<usize>> = (0..p.lists).map(|k| ids[k * p.len..(k + 1) * p.len].to_vec()).collect();
        let mut probes = vec![];
        for (k, list) in lists.iter().enumerate() {
            let order = if k == 0 { p.order } else { p.order2 };
            let mut seq: Vec<usize> = (0..p.len).collect();
            match order {
                Order::Forward => {}
                Order::Reverse => seq.reverse(),
                Order::Random => rng.shuffle(&mut seq),
            }
            let round: Vec<Probe> = seq
                .into_iter()
                .map(|s| Probe {
                    station: s,
                    candidates: (!p.typed).then(|| {
                        let other = if k > 0 { Some(lists[k - 1][s]) } else { None };
                        make_candidates(&mut rng, &bank, &allowed, list, s, other, p.choices, p.sim)
                    }),
                })
                .collect();
            probes.push(round);
        }
        PalaceGame {
            level,
            stations,
            marks: vec![Mark::None; p.len],
            round_correct: vec![0; p.lists],
            p,
            bank,
            lists,
            probes,
            round: 0,
            phase: Phase::Intro,
            countdown_ms: COUNTDOWN_MS,
            show_idx: 0,
            show_t: 0.0,
            show_times: vec![],
            probe_pos: 0,
            correct: 0,
            answered: 0,
            last: None,
            serial: 0,
            stars: 0,
            won: false,
        }
    }

    fn total(&self) -> u32 {
        (self.p.len * self.p.lists) as u32
    }

    fn word(&self, id: usize) -> &'static str {
        self.bank[id].0
    }

    fn place(&mut self) {
        self.show_times.push(self.show_t.min(self.p.show_ms));
        self.marks[self.show_idx] = Mark::Placed;
        self.show_idx += 1;
        self.show_t = 0.0;
        if self.show_idx >= self.p.len {
            self.phase = Phase::Recall;
            self.probe_pos = 0;
        }
    }

    fn answer(&mut self, correct: bool, skipped: bool, given: String) {
        let probe = &self.probes[self.round][self.probe_pos];
        let station = probe.station;
        let answer = self.word(self.lists[self.round][station]).to_string();
        self.marks[station] = if correct { Mark::Ok } else { Mark::Bad };
        self.answered += 1;
        if correct {
            self.correct += 1;
            self.round_correct[self.round] += 1;
        }
        self.serial += 1;
        self.last = Some(Feedback { serial: self.serial, correct, skipped, station, answer, given });
        self.probe_pos += 1;
        if self.probe_pos >= self.probes[self.round].len() {
            if self.round + 1 < self.p.lists {
                self.phase = Phase::Clear;
            } else {
                self.finish();
            }
        }
    }

    fn avg_show_ms(&self) -> f64 {
        if self.show_times.is_empty() {
            0.0
        } else {
            self.show_times.iter().sum::<f64>() / self.show_times.len() as f64
        }
    }

    fn finish(&mut self) {
        self.phase = Phase::Done;
        let acc = self.correct as f64 / self.total() as f64;
        let fast = self.avg_show_ms() <= 0.5 * self.p.show_ms;
        self.stars = if acc >= 0.95 - 1e-9 || (acc >= 0.9 - 1e-9 && fast) {
            3
        } else if acc >= 0.8 - 1e-9 {
            2
        } else if acc >= 0.6 - 1e-9 {
            1
        } else {
            0
        };
        self.won = self.stars > 0;
    }

    fn title(&self) -> String {
        let base = if self.p.lists == 2 {
            "Çift liste"
        } else {
            match self.p.order {
                Order::Forward => "İleri yürüyüş",
                Order::Reverse => "Geri yürüyüş",
                Order::Random => "Rastgele durak",
            }
        };
        if self.p.typed {
            format!("{base} · yazarak")
        } else {
            base.into()
        }
    }

    fn goal(&self) -> String {
        let secs = format!("{}", self.p.show_ms / 1000.0).replace('.', ",");
        let items = if self.p.lists == 2 { format!("2 × {} eşya", self.p.len) } else { format!("{} eşya", self.p.len) };
        format!("{} · {items} · eşya başına {secs} sn · ★★★ için %95", PALACES[self.p.palace].name)
    }

    fn brief(&self) -> String {
        let walk = format!(
            "{} sarayında {} durak. Her durağa bir eşya bırak: eşyayı durakla etkileşen canlı, tuhaf bir sahneye çevir.",
            PALACES[self.p.palace].name,
            self.p.len
        );
        let recall = if self.p.lists == 2 {
            "İki liste: önce ilk listeyi yerleştirip hatırla, sonra sarayı temizle ve ikinci listeyi aynı duraklara koy."
        } else {
            match self.p.order {
                Order::Forward => "Hatırlarken kapıdan başlayıp sırayla yürüyeceksin.",
                Order::Reverse => "Hatırlarken sondan başa, geriye doğru yürüyeceksin.",
                Order::Random => "Hatırlarken duraklar karışık sorulacak: doğrudan o durağa ışınlan.",
            }
        };
        let how = if self.p.typed { " Eşyanın adını yazacaksın." } else { " Eşyayı seçeneklerden seçeceksin." };
        format!("{walk} {recall}{how}")
    }

    fn summary(&self) -> String {
        let pct = (100.0 * self.correct as f64 / self.total() as f64).round();
        let avg = format!("{:.1}", self.avg_show_ms() / 1000.0).replace('.', ",");
        if self.p.lists == 2 {
            format!(
                "1. liste {}/{} · 2. liste {}/{} · %{pct} · Ort. yerleştirme {avg} sn",
                self.round_correct[0], self.p.len, self.round_correct[1], self.p.len
            )
        } else {
            format!("Doğru {}/{} · %{pct} · Ort. yerleştirme {avg} sn", self.correct, self.total())
        }
    }

    fn status(&self) -> &'static str {
        match self.phase {
            Phase::Done if self.won => "won",
            Phase::Done => "lost",
            _ => "playing",
        }
    }

    /// The right candidate index for the current probe (tests).
    #[cfg(test)]
    fn right_pick(&self) -> usize {
        let probe = &self.probes[self.round][self.probe_pos];
        let ans = self.lists[self.round][probe.station];
        probe.candidates.as_ref().unwrap().iter().position(|&w| w == ans).unwrap()
    }
}

impl Session for PalaceGame {
    fn state(&self) -> Value {
        let show = (self.phase == Phase::Show).then(|| {
            let i = self.show_idx;
            json!({
                "index": i,
                "total": self.p.len,
                "number": i + 1,
                "station": self.stations[i],
                "item": self.word(self.lists[self.round][i]),
                "elapsed_ms": self.show_t.round(),
                "limit_ms": self.p.show_ms,
                "remaining_ms": (self.p.show_ms - self.show_t).max(0.0).round(),
            })
        });
        let probe = (self.phase == Phase::Recall).then(|| {
            let pr = &self.probes[self.round][self.probe_pos];
            json!({
                "pos": self.probe_pos,
                "total": self.probes[self.round].len(),
                "station_index": pr.station,
                "number": pr.station + 1,
                "station": self.stations[pr.station],
                "candidates": pr.candidates.as_ref().map(|c| c.iter().map(|&w| self.word(w)).collect::<Vec<_>>()),
            })
        });
        let marks: Vec<&str> = self
            .marks
            .iter()
            .map(|m| match m {
                Mark::None => "",
                Mark::Placed => "placed",
                Mark::Ok => "ok",
                Mark::Bad => "bad",
            })
            .collect();
        let last = self.last.as_ref().map(|f| {
            json!({
                "serial": f.serial, "correct": f.correct, "skipped": f.skipped, "station_index": f.station,
                "number": f.station + 1, "answer": f.answer, "given": f.given,
            })
        });
        let order = if self.round == 0 { self.p.order } else { self.p.order2 };
        json!({
            "status": self.status(),
            "stars": self.stars,
            "mode": "level",
            "phase": self.phase.key(),
            "title": self.title(),
            "goal": self.goal(),
            "brief": self.brief(),
            "summary": (self.phase == Phase::Done).then(|| self.summary()),
            "score": self.correct * 10,
            "level": self.level,
            "palace": PALACES[self.p.palace].name,
            "stations": self.stations,
            "round": self.round,
            "rounds": self.p.lists,
            "list_len": self.p.len,
            "order": order.key(),
            "typed": self.p.typed,
            "countdown_ms": self.countdown_ms.max(0.0).round(),
            "show": show,
            "probe": probe,
            "marks": marks,
            "correct": self.correct,
            "answered": self.answered,
            "total": self.total(),
            "round_correct": self.round_correct,
            "last": last,
        })
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if self.phase == Phase::Done {
            return Err("Bölüm bitti".into());
        }
        if a["start"].as_bool() == Some(true) {
            match self.phase {
                Phase::Intro => {}
                Phase::Clear => {
                    self.round += 1;
                    self.show_idx = 0;
                    self.show_t = 0.0;
                    self.marks = vec![Mark::None; self.p.len];
                }
                _ => return Err("Oyun zaten başladı".into()),
            }
            self.phase = Phase::Countdown;
            self.countdown_ms = COUNTDOWN_MS;
            return Ok(());
        }
        match self.phase {
            Phase::Intro => return Err("Önce Başla'ya dokun".into()),
            Phase::Clear => return Err("Önce sarayı temizle".into()),
            _ => {}
        }
        if a["next"].as_bool() == Some(true) {
            if self.phase != Phase::Show {
                return Err("Şimdi yerleştirme sırası değil".into());
            }
            self.place();
            return Ok(());
        }
        let recall = a.get("pick").is_some() || a.get("type").is_some() || a.get("skip").is_some();
        if !recall {
            return Err("Bilinmeyen hamle".into());
        }
        if self.phase != Phase::Recall {
            return Err("Önce eşyaları yerleştir".into());
        }
        let probe = self.probes[self.round][self.probe_pos].clone();
        let answer = self.lists[self.round][probe.station];
        if a["skip"].as_bool() == Some(true) {
            self.answer(false, true, String::new());
            return Ok(());
        }
        if let Some(i) = a["pick"].as_u64() {
            let cands = probe.candidates.as_ref().ok_or("Bu bölümde cevabı yazmalısın")?;
            let &w = cands.get(i as usize).ok_or("Geçersiz seçenek")?;
            self.answer(w == answer, false, self.word(w).to_string());
            return Ok(());
        }
        if let Some(s) = a["type"].as_str() {
            if probe.candidates.is_some() {
                return Err("Bu bölümde seçeneklerden seç".into());
            }
            if fold(s).is_empty() {
                return Err("Önce bir kelime yaz".into());
            }
            let ok = typed_matches(s, self.word(answer));
            self.answer(ok, false, s.trim().to_string());
            return Ok(());
        }
        Err("Bilinmeyen hamle".into())
    }

    fn tick(&mut self, dt_ms: f64) {
        if dt_ms.is_nan() || dt_ms <= 0.0 {
            return;
        }
        match self.phase {
            Phase::Countdown => {
                self.countdown_ms -= dt_ms;
                if self.countdown_ms <= 0.0 {
                    self.countdown_ms = 0.0;
                    self.phase = Phase::Show;
                    self.show_t = 0.0;
                }
            }
            Phase::Show => {
                self.show_t += dt_ms;
                if self.show_t >= self.p.show_ms {
                    self.place();
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

    fn to_recall(g: &mut PalaceGame, think_ms: f64) {
        while g.phase == Phase::Countdown {
            g.tick(100.0);
        }
        while g.phase == Phase::Show {
            g.tick(think_ms);
            if g.phase == Phase::Show {
                g.act(&json!({"next": true})).unwrap();
            }
        }
        assert_eq!(g.phase, Phase::Recall);
    }

    /// Plays a whole level; `wrong(n)` decides whether probe n (0-based, over the level) is missed.
    fn play(level: u32, wrong: impl Fn(u32) -> bool, think_ms: f64) -> PalaceGame {
        let mut g = PalaceGame::new(level);
        g.act(&json!({"start": true})).unwrap();
        let mut n = 0;
        loop {
            to_recall(&mut g, think_ms);
            while g.phase == Phase::Recall {
                let probe = g.probes[g.round][g.probe_pos].clone();
                let ans = g.word(g.lists[g.round][probe.station]);
                let miss = wrong(n);
                if probe.candidates.is_some() {
                    let right = g.right_pick();
                    let pick = if miss { (right + 1) % g.p.choices } else { right };
                    g.act(&json!({"pick": pick})).unwrap();
                } else if miss {
                    g.act(&json!({"type": "qqqqqq"})).unwrap();
                } else {
                    g.act(&json!({"type": ans.to_uppercase()})).unwrap();
                }
                assert_eq!(g.last.as_ref().unwrap().correct, !miss);
                n += 1;
            }
            if g.phase == Phase::Clear {
                g.act(&json!({"start": true})).unwrap();
                continue;
            }
            break;
        }
        assert_eq!(g.phase, Phase::Done);
        assert_eq!(n, g.total());
        g
    }

    #[test]
    fn bank_is_large_unique_and_palaces_full() {
        let b = words();
        assert!(b.len() >= 400, "bank has {}", b.len());
        let mut seen = std::collections::HashSet::new();
        for (w, _) in &b {
            assert!(seen.insert(fold(w)), "duplicate word {w}");
            assert_eq!(w.to_string(), w.to_lowercase(), "lowercase: {w}");
        }
        for p in &PALACES {
            let mut s = std::collections::HashSet::new();
            for st in p.stations {
                assert!(s.insert(st), "{}: duplicate station {st}", p.name);
            }
            let allowed = allowed_words(PALACES.iter().position(|q| q.name == p.name).unwrap(), &b);
            assert!(allowed.iter().filter(|&&a| a).count() >= 360, "{}", p.name);
        }
    }

    #[test]
    fn params_follow_curve() {
        for level in LEVELS {
            let p = params(level);
            assert!((4..=40).contains(&p.len), "level {level}: {}", p.len);
            assert!((3000.0..=12000.0).contains(&p.show_ms));
            assert!((6..=9).contains(&p.choices));
        }
        let p1 = params(1);
        assert_eq!((p1.len, p1.show_ms, p1.order, p1.typed, p1.lists), (5, 12000.0, Order::Forward, false, 1));
        let p = params(499);
        assert_eq!((p.len, p.show_ms), (40, 3000.0));
        assert_eq!(params(3).order, Order::Reverse);
        assert_eq!(params(5).order, Order::Random);
        assert_eq!(params(30).lists, 2);
        assert!(params(64).typed);
        assert_eq!(params(11).palace, 1);
        assert_eq!(params(251).choices, 9);
    }

    #[test]
    fn levels_generate_and_are_deterministic() {
        for level in LEVELS {
            let a = PalaceGame::new(level);
            let b = PalaceGame::new(level);
            assert_eq!(a.lists, b.lists);
            assert_eq!(a.stations.len(), a.p.len);
            for (pa, pb) in a.probes.iter().flatten().zip(b.probes.iter().flatten()) {
                assert_eq!(pa.station, pb.station);
                assert_eq!(pa.candidates, pb.candidates);
            }
            assert_eq!(a.state()["phase"], "intro");
        }
        assert_ne!(PalaceGame::new(7).lists, PalaceGame::new(8).lists);
    }

    #[test]
    fn candidates_contain_correct_exactly_once_and_are_distinct() {
        for level in 1..=500 {
            let g = PalaceGame::new(level);
            // Lists of one level never share an item, and no item clashes with a station word.
            let all: Vec<usize> = g.lists.iter().flatten().copied().collect();
            let set: std::collections::HashSet<_> = all.iter().collect();
            assert_eq!(set.len(), all.len());
            for (k, round) in g.probes.iter().enumerate() {
                let mut stations: Vec<usize> = round.iter().map(|p| p.station).collect();
                stations.sort();
                assert_eq!(stations, (0..g.p.len).collect::<Vec<_>>());
                for pr in round {
                    let Some(c) = &pr.candidates else { continue };
                    assert_eq!(c.len(), g.p.choices, "level {level}");
                    let ans = g.lists[k][pr.station];
                    assert_eq!(c.iter().filter(|&&w| w == ans).count(), 1);
                    let uniq: std::collections::HashSet<_> = c.iter().collect();
                    assert_eq!(uniq.len(), c.len(), "level {level}: duplicate candidates");
                    let words: std::collections::HashSet<_> = c.iter().map(|&w| fold(g.word(w))).collect();
                    assert_eq!(words.len(), c.len());
                    if k == 1 {
                        assert!(c.contains(&g.lists[0][pr.station]), "interference lure missing");
                    }
                }
            }
        }
    }

    #[test]
    fn order_variants() {
        let fwd = PalaceGame::new(1);
        assert_eq!(fwd.probes[0].iter().map(|p| p.station).collect::<Vec<_>>(), (0..fwd.p.len).collect::<Vec<_>>());
        let rev = PalaceGame::new(3);
        assert_eq!(rev.probes[0].iter().map(|p| p.station).collect::<Vec<_>>(), (0..rev.p.len).rev().collect::<Vec<_>>());
        let rnd = PalaceGame::new(5);
        let order: Vec<usize> = rnd.probes[0].iter().map(|p| p.station).collect();
        assert_ne!(order, (0..rnd.p.len).collect::<Vec<_>>());
        // Reverse recall asks for the last station first.
        let mut g = PalaceGame::new(3);
        g.act(&json!({"start": true})).unwrap();
        to_recall(&mut g, 500.0);
        assert_eq!(g.state()["probe"]["number"], g.p.len);
    }

    #[test]
    fn perfect_play_gives_three_stars() {
        for level in [1, 2, 3, 4, 5, 6, 30, 50, 64, 137, 250, 400, 499, 500] {
            let g = play(level, |_| false, 900.0);
            assert_eq!(g.state()["status"], "won", "level {level}");
            assert_eq!(g.stars, 3);
            assert!(g.state()["summary"].is_string());
        }
    }

    #[test]
    fn stars_follow_accuracy_and_speed() {
        // Level 50: 9 items, 6 choices.
        let n = params(50).len as u32;
        assert_eq!(n, 9);
        // 8/9 = 89% → 2 stars.
        assert_eq!(play(50, |i| i == 0, 900.0).stars, 2);
        // 7/9 = 78% → 1 star.
        assert_eq!(play(50, |i| i < 2, 900.0).stars, 1);
        // 5/9 = 56% → lost.
        let g = play(50, |i| i < 4, 900.0);
        assert_eq!(g.state()["status"], "lost");
        // Level 397 (forward, grid) has 33 items: 30/33 = 91% → 3 stars when fast, 2 when slow.
        let len = params(397).len as u32;
        assert!(len >= 30);
        let limit = params(397).show_ms;
        assert_eq!(play(397, |i| i < 3, limit * 0.3).stars, 3);
        assert_eq!(play(397, |i| i < 3, limit * 0.8).stars, 2);
    }

    #[test]
    fn items_auto_place_when_time_runs_out() {
        let mut g = PalaceGame::new(1);
        g.act(&json!({"start": true})).unwrap();
        while g.phase != Phase::Recall {
            g.tick(250.0);
        }
        assert_eq!(g.show_times.len(), g.p.len);
        assert!(g.show_times.iter().all(|&t| t == g.p.show_ms));
    }

    #[test]
    fn typed_matching_is_forgiving_but_not_loose() {
        assert!(typed_matches("KÖPEK", "köpek"));
        assert!(typed_matches("kopek", "köpek"));
        assert!(typed_matches("  Tavus Kuşu ", "tavus kuşu"));
        assert!(typed_matches("tavuskusu", "tavus kuşu"));
        assert!(typed_matches("ISTAKOZ", "ıstakoz"));
        assert!(typed_matches("zürafaa", "zürafa"));
        assert!(!typed_matches("fil", "fal"));
        assert!(!typed_matches("", "fil"));
        assert!(!typed_matches("kedi", "köpek"));
    }

    #[test]
    fn interference_round_flow() {
        let mut g = PalaceGame::new(30);
        assert_eq!(g.p.lists, 2);
        g.act(&json!({"start": true})).unwrap();
        to_recall(&mut g, 500.0);
        while g.phase == Phase::Recall {
            let r = g.right_pick();
            g.act(&json!({"pick": r})).unwrap();
        }
        assert_eq!(g.phase, Phase::Clear);
        assert!(g.act(&json!({"next": true})).is_err());
        g.act(&json!({"start": true})).unwrap();
        assert_eq!(g.round, 1);
        assert!(g.marks.iter().all(|&m| m == Mark::None));
        to_recall(&mut g, 500.0);
        let st = g.state();
        assert_eq!(st["round"], 1);
        // Pick the old list's item: interference error.
        let probe = g.probes[1][0].clone();
        let lure = g.lists[0][probe.station];
        let idx = probe.candidates.as_ref().unwrap().iter().position(|&w| w == lure).unwrap();
        g.act(&json!({"pick": idx})).unwrap();
        assert!(!g.last.as_ref().unwrap().correct);
    }

    #[test]
    fn illegal_actions_rejected_and_state_unchanged() {
        let mut g = PalaceGame::new(1);
        let before = g.state();
        assert!(g.act(&json!({"next": true})).is_err());
        assert!(g.act(&json!({"pick": 0})).is_err());
        assert_eq!(g.state(), before);
        g.act(&json!({"start": true})).unwrap();
        assert!(g.act(&json!({"start": true})).is_err());
        while g.phase == Phase::Countdown {
            g.tick(100.0);
        }
        let before = g.state();
        assert!(g.act(&json!({"pick": 0})).is_err());
        assert!(g.act(&json!({"bogus": true})).is_err());
        assert_eq!(g.state(), before);
        to_recall(&mut g, 100.0);
        let before = g.state();
        assert!(g.act(&json!({"pick": 99})).is_err());
        assert!(g.act(&json!({"type": "fil"})).is_err()); // grid level
        assert!(g.act(&json!({"next": true})).is_err());
        assert_eq!(g.state(), before);
        // Typed level rejects picks and empty words.
        let lvl = (60..100).find(|&l| params(l).typed).unwrap();
        let mut t = PalaceGame::new(lvl);
        t.act(&json!({"start": true})).unwrap();
        to_recall(&mut t, 100.0);
        let before = t.state();
        assert!(t.act(&json!({"pick": 0})).is_err());
        assert!(t.act(&json!({"type": "  "})).is_err());
        assert_eq!(t.state(), before);
        assert!(t.state()["probe"]["candidates"].is_null());
        t.act(&json!({"skip": true})).unwrap();
        assert!(t.last.as_ref().unwrap().skipped);
    }

    #[test]
    #[ignore]
    fn timing_500_levels() {
        let t = std::time::Instant::now();
        for level in 1..=500 {
            let g = PalaceGame::new(level);
            assert!(!g.lists.is_empty());
        }
        println!("palace: 500 levels in {:?}", t.elapsed());
    }
}
