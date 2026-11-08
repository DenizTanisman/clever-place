//! Blöf — the Turkish bluffing card game. You (seat 0) against three AI opponents.
//!
//! Seats clockwise: 0 you (bottom), 1 Selin (left), 2 Kerem (top), 3 Defne (right). A 52-card deck
//! is dealt 13 each; a random seat starts.
//!
//! Rules (the variant implemented here):
//! - **Lead**: the player who starts a round names a rank (2..A) and puts 1–4 cards face down on the
//!   pile, claiming they are all that rank ("Üç tane 7").
//! - **Follow**: in turn (clockwise) each player either plays 1–4 cards claiming the **same rank**,
//!   says **"Blöf!"** (challenges the *last* play), or **passes**. The last play stays open to a
//!   challenge from whoever's turn it is until somebody plays on top of it — so if the next player
//!   passes, the one after may still challenge it.
//! - **Challenge**: the last play is turned face up. If any card is not the claimed rank the liar
//!   takes the whole pile, otherwise the challenger takes it. The player who did *not* take the pile
//!   starts a new round with a free rank.
//! - **Everybody passes**: if the turn comes back to the last player (three passes in a row) the
//!   pile is set aside face down ("yanar", out of the game) and that player starts a new round.
//! - **Four of a kind**: whenever a hand holds all four cards of a rank (after the deal or after
//!   taking a pile) they are discarded face up. That rank is dead (cannot be named) and therefore no
//!   hand ever holds four of a rank: a claim of "dört tane" is always a lie.
//! - **Winning**: a player who plays their last cards has not won yet: every other player in turn
//!   order may still challenge that play (playing on top is not allowed). If all three pass, or the
//!   challenge shows the play was true, that player wins. If it was a lie, they take the pile and
//!   play on. (A hand emptied by a four-of-a-kind discard also wins.)
//! - A match = one game until someone empties their hand: "won" if you do, "lost" if an AI does.
//!   Safety net: after 2 000 actions the table is declared a draw (never seen in AI matches).
//!
//! AI (`mode` = table): every AI action is one `{"ai":true}` call and carries a Turkish `reason`.
//! - Easy, Normal and Hard decide from an [`Info`] — the seat's *information set* (own hand, counts,
//!   public claims, revealed cards, its own card-tracking memory [`K`]) built by [`Game::info`]. They
//!   never receive the [`Game`], so they cannot read hidden cards.
//! - **Kolay**: truthful whenever it holds the rank, otherwise a random one-card bluff or a pass;
//!   challenges on a whim, notices an impossible claim only sometimes.
//! - **Orta**: tracks its own cards, its own cards in the pile, dead ranks and every revealed card
//!   (who took it). Always challenges a claim that is impossible from what it knows, and often
//!   challenges claims that would need every remaining card of the rank or that exceed 4 for the
//!   round. Bluffs with its worst single card when the pile is small.
//! - **Zor**: Bayesian. The number m of the claimed rank in the claimer's hidden cards follows a
//!   hypergeometric over the cards it cannot place (corrected for earlier claims this round); the
//!   likelihood of "claims k" given m models holders (play what they have, sometimes padded with one
//!   junk card), non-holders (bluff with the claimer's profiled bluff propensity — revealed lies /
//!   revealed plays — mostly with a single card, else pass) and leaders (name their strongest rank).
//!   The posterior P(lie) feeds expected costs (cards taken, cards shed, lead value, the claimer
//!   being close to winning) of challenge / truthful play / partial bluff / pure bluff / pass, and it
//!   plays a softmax mixed strategy (T = 0.3), dumping its worst single cards inside bluffs, often
//!   opening with junk and following with the real cards later in the round.
//! - **İmkânsız**: omniscient (reads the [`Game`]): challenges exactly the lies (never a truth),
//!   lies only when no opponent who may get to challenge could profitably do so (an omniscient
//!   opponent always could — so at an İmkânsız table they practically never lie), leads the rank it
//!   holds most of and that the next seats lack.
//!
//! State: `{status, stars, title, goal, summary, mode, seed, names: [4], turn: "you"|"ai", seat,
//!          ai_pending, phase: "lead"|"follow"|"over", final, rank|null, hand: [[s,r]],
//!          hands: [4 × [[s,r]]] (hidden info — the view shows it only in open play), counts: [4],
//!          pile_count, pile: [{seat, count, rank, cards}] (current round, true cards), last_play
//!          {seat, count, rank, cards}|null, can_lead, can_play, can_challenge, can_pass,
//!          dead_ranks, discards: [{seat, rank}], burned, burned_cards, event: {serial, seat, kind:
//!          "lead"|"play"|"pass"|"challenge", count, rank, text, reason, cards, burned, win,
//!          reveal: {challenger, target, rank, cards, lie, taker, leader, count, discards}|null}|null,
//!          log: [{serial, seat, kind, text, reason}], odds: {...}|null, hint: {...}|null,
//!          stats: [4 × {plays, reveals, lies, challenges, wrong}], winner|null, used_help,
//!          actions, version}`
//! Cards are `[suit, rank]`: suit 0 maça, 1 kupa, 2 karo, 3 sinek; rank 2..14 (14 = As).
//! Actions: `{"play":[[s,r],...], "rank":r}` (rank only when you start a round) · `{"challenge":true}`
//! · `{"pass":true}` · `{"ai":true}` · `{"hint":true}`.
//! Stars on a win: 3 without hints, 1 if a hint was used.

use crate::rng::{time_seed, Rng};
use crate::Session;
use serde_json::{json, Value};

pub type Card = u8;

const NAMES: [&str; 4] = ["Sen", "Selin", "Kerem", "Defne"];
const GEN: [&str; 4] = ["Senin", "Selin'in", "Kerem'in", "Defne'nin"];
const MAX_ACTIONS: u32 = 2000;
const WIN: f64 = 30.0;
const LOG_KEEP: usize = 60;

fn rank_of(c: Card) -> u8 {
    c % 13 + 2
}
fn suit_of(c: Card) -> u8 {
    c / 13
}
fn card_id(s: u8, r: u8) -> Card {
    s * 13 + (r - 2)
}

fn rname(r: u8) -> String {
    match r {
        11 => "Vale".into(),
        12 => "Kız".into(),
        13 => "Papaz".into(),
        14 => "As".into(),
        _ => r.to_string(),
    }
}

fn cname(c: Card) -> String {
    const S: [&str; 4] = ["Maça", "Kupa", "Karo", "Sinek"];
    format!("{} {}", S[suit_of(c) as usize], rname(rank_of(c)))
}

/// Bubble text, e.g. "İki tane 7".
fn claim_text(k: usize, r: u8) -> String {
    const W: [&str; 5] = ["Hiç", "Bir", "İki", "Üç", "Dört"];
    format!("{} tane {}", W[k.min(4)], rname(r))
}

/// Mid-sentence form, e.g. "iki tane 7".
fn claim_lower(k: usize, r: u8) -> String {
    const W: [&str; 5] = ["hiç", "bir", "iki", "üç", "dört"];
    format!("{} tane {}", W[k.min(4)], rname(r))
}

fn pct(p: f64) -> u32 {
    (p.clamp(0.0, 1.0) * 100.0).round() as u32
}

fn sort_hand(h: &mut [Card]) {
    h.sort_by_key(|&c| (rank_of(c), suit_of(c)));
}

fn rank_counts(h: &[Card]) -> [usize; 15] {
    let mut n = [0; 15];
    for &c in h {
        n[rank_of(c) as usize] += 1;
    }
    n
}

fn cards_of(h: &[Card], r: u8, max: usize) -> Vec<Card> {
    h.iter().copied().filter(|&c| rank_of(c) == r).take(max).collect()
}

/// The `j` worst cards to dump inside a bluff: ranks held the fewest times first (singletons are
/// the hardest to ever play truthfully).
fn junk(h: &[Card], exclude: u8, j: usize) -> Vec<Card> {
    let n = rank_counts(h);
    let mut v: Vec<Card> = h.iter().copied().filter(|&c| rank_of(c) != exclude).collect();
    v.sort_by_key(|&c| (n[rank_of(c) as usize], rank_of(c), suit_of(c)));
    v.truncate(j);
    v
}

fn names_of(cs: &[Card]) -> String {
    cs.iter().map(|&c| cname(c)).collect::<Vec<_>>().join(", ")
}

// -------------------------------------------------------------------------------------------------
// Probability helpers

fn choose(n: usize, k: usize) -> f64 {
    if k > n {
        return 0.0;
    }
    let k = k.min(n - k);
    (0..k).fold(1.0, |acc, i| acc * (n - i) as f64 / (i + 1) as f64)
}

/// P(X = x) for X ~ Hypergeometric(`pop`, `a`, `n`).
fn hyper_pmf(pop: usize, a: usize, n: usize, x: usize) -> f64 {
    let n = n.min(pop);
    let a = a.min(pop);
    let total = choose(pop, n);
    if total <= 0.0 || x > a || x > n || n - x > pop - a {
        return 0.0;
    }
    choose(a, x) * choose(pop - a, n - x) / total
}

/// [`hyper_pmf`] linearly interpolated over a fractional success count.
fn hyper_pmf_f(pop: usize, a: f64, n: usize, x: usize) -> f64 {
    let a0 = a.floor();
    let w = a - a0;
    hyper_pmf(pop, a0 as usize, n, x) * (1.0 - w) + hyper_pmf(pop, a0 as usize + 1, n, x) * w
}

// -------------------------------------------------------------------------------------------------
// Core types

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Brain {
    Easy,
    Normal,
    Hard,
    Impossible,
}

impl Brain {
    fn from_mode(m: &str) -> Option<Brain> {
        match m {
            "easy" => Some(Brain::Easy),
            "normal" | "level" => Some(Brain::Normal),
            "hard" => Some(Brain::Hard),
            "impossible" => Some(Brain::Impossible),
            _ => None,
        }
    }
    fn label(self) -> &'static str {
        match self {
            Brain::Easy => "Kolay",
            Brain::Normal => "Orta",
            Brain::Hard => "Zor",
            Brain::Impossible => "İmkânsız",
        }
    }
}

/// What one seat knows about where a card is (its private card-tracking memory).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum K {
    Unknown,
    /// In my hand.
    Mine,
    /// I put it on the current pile myself.
    Pile,
    /// Out of the game for sure (public four-of-a-kind discard, or my own card in a burnt pile).
    Gone,
    /// Seat `q` received it (revealed or a pile I contributed to). `true` = q has not played since,
    /// so it is surely in q's hand; `false` = it is in q's hand or q played it face down. Either way
    /// it is in nobody else's hand.
    With(u8, bool),
}

#[derive(Clone, Debug)]
struct Play {
    seat: usize,
    cards: Vec<Card>,
    rank: u8,
}

/// Public per-seat statistics (the base of opponent profiling).
#[derive(Clone, Copy, Default, Debug)]
struct Profile {
    plays: u32,
    reveals: u32,
    lies: u32,
    chances: u32,
    challenges: u32,
    wrong: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Act {
    Lead(u8, Vec<Card>),
    Play(Vec<Card>),
    Challenge,
    Pass,
}

#[derive(Clone, Debug)]
struct Decision {
    act: Act,
    reason: String,
}

#[derive(Clone, Debug)]
struct Reveal {
    challenger: usize,
    target: usize,
    rank: u8,
    cards: Vec<Card>,
    lie: bool,
    taker: usize,
    leader: usize,
    count: usize,
    discards: Vec<u8>,
}

#[derive(Clone, Debug)]
struct Event {
    serial: u64,
    seat: usize,
    kind: &'static str,
    count: usize,
    rank: u8,
    text: String,
    reason: String,
    cards: Vec<Card>,
    burned: usize,
    win: bool,
    reveal: Option<Reveal>,
}

#[derive(Clone, Debug)]
struct LogLine {
    serial: u64,
    seat: usize,
    kind: &'static str,
    text: String,
    reason: String,
}

/// A seat's information set: everything that seat may legally know, and nothing else.
#[derive(Clone, Debug)]
struct Info {
    me: usize,
    hand: Vec<Card>,
    counts: [usize; 4],
    know: [K; 52],
    /// Current round: (seat, card count, claimed rank).
    plays: Vec<(usize, usize, u8)>,
    rank: Option<u8>,
    pile_count: usize,
    dead: [bool; 15],
    prof: [Profile; 4],
    /// The last play emptied its player's hand (only challenge / pass allowed).
    fin: bool,
}

#[derive(Clone)]
struct Game {
    seed: u64,
    brains: [Brain; 4],
    human: bool,
    hands: [Vec<Card>; 4],
    pile: Vec<Play>,
    rank: Option<u8>,
    turn: usize,
    passes: u8,
    dead: [bool; 15],
    discards: Vec<(usize, u8)>,
    burned: Vec<Card>,
    know: [[K; 52]; 4],
    prof: [Profile; 4],
    rng: Rng,
    winner: Option<usize>,
    draw: bool,
    actions: u32,
    rounds: u32,
    serial: u64,
    log: Vec<LogLine>,
    last: Option<Event>,
}

impl Game {
    fn new(seed: u64, brains: [Brain; 4], human: bool) -> Game {
        let mut rng = Rng::new(seed);
        let mut deck: Vec<Card> = (0..52).collect();
        rng.shuffle(&mut deck);
        let mut hands: [Vec<Card>; 4] = Default::default();
        let mut know = [[K::Unknown; 52]; 4];
        for (i, h) in hands.iter_mut().enumerate() {
            *h = deck[i * 13..(i + 1) * 13].to_vec();
            sort_hand(h);
            for &c in h.iter() {
                know[i][c as usize] = K::Mine;
            }
        }
        let turn = rng.below(4);
        let mut g = Game {
            seed,
            brains,
            human,
            hands,
            pile: vec![],
            rank: None,
            turn,
            passes: 0,
            dead: [false; 15],
            discards: vec![],
            burned: vec![],
            know,
            prof: [Profile::default(); 4],
            rng,
            winner: None,
            draw: false,
            actions: 0,
            rounds: 0,
            serial: 0,
            log: vec![],
            last: None,
        };
        for s in 0..4 {
            g.discard_quads(s);
        }
        g.note(turn, "start", format!("{} başlıyor", NAMES[turn]), String::new());
        g
    }

    fn over(&self) -> bool {
        self.winner.is_some() || self.draw
    }

    fn final_play(&self) -> bool {
        self.pile.last().is_some_and(|p| self.hands[p.seat].is_empty())
    }

    fn pile_count(&self) -> usize {
        self.pile.iter().map(|p| p.cards.len()).sum()
    }

    fn note(&mut self, seat: usize, kind: &'static str, text: String, reason: String) {
        self.log.push(LogLine { serial: self.serial, seat, kind, text, reason });
        if self.log.len() > 400 {
            self.log.drain(..100);
        }
    }

    /// Discard every complete four-of-a-kind in `seat`'s hand (public).
    fn discard_quads(&mut self, seat: usize) -> Vec<u8> {
        let n = rank_counts(&self.hands[seat]);
        let mut out = vec![];
        for r in 2..=14u8 {
            if n[r as usize] == 4 {
                self.hands[seat].retain(|&c| rank_of(c) != r);
                self.dead[r as usize] = true;
                for s in 0..4u8 {
                    let c = card_id(s, r) as usize;
                    for o in 0..4 {
                        self.know[o][c] = K::Gone;
                    }
                }
                self.discards.push((seat, r));
                out.push(r);
                let who = if seat == 0 { "Dörtlüyü attın".to_string() } else { format!("{} dörtlüyü attı", NAMES[seat]) };
                self.note(seat, "discard", format!("{who}: 4 tane {}", rname(r)), String::new());
            }
        }
        out
    }

    fn info(&self, seat: usize) -> Info {
        Info {
            me: seat,
            hand: self.hands[seat].clone(),
            counts: [self.hands[0].len(), self.hands[1].len(), self.hands[2].len(), self.hands[3].len()],
            know: self.know[seat],
            plays: self.pile.iter().map(|p| (p.seat, p.cards.len(), p.rank)).collect(),
            rank: self.rank,
            pile_count: self.pile_count(),
            dead: self.dead,
            prof: self.prof,
            fin: self.final_play(),
        }
    }

    fn validate_cards(&self, seat: usize, cards: &[Card]) -> Result<(), String> {
        if cards.is_empty() || cards.len() > 4 {
            return Err("1 ile 4 arasında kart seç".into());
        }
        for (i, c) in cards.iter().enumerate() {
            if cards[..i].contains(c) {
                return Err("Aynı kart iki kez seçildi".into());
            }
            if !self.hands[seat].contains(c) {
                return Err("Bu kart elinde yok".into());
            }
        }
        Ok(())
    }

    /// Apply one action for `seat` (the player whose turn it is). `Err` leaves the game unchanged.
    fn apply(&mut self, seat: usize, act: Act, reason: String) -> Result<(), String> {
        if self.over() {
            return Err("Oyun bitti".into());
        }
        if seat != self.turn {
            return Err(if seat == 0 { "Sıra rakipte".into() } else { "Sıra onda değil".into() });
        }
        match act {
            Act::Lead(r, cards) => {
                if self.rank.is_some() {
                    return Err("Tur sürüyor — sayı zaten söylendi".into());
                }
                if !(2..=14).contains(&r) {
                    return Err("Geçersiz sayı".into());
                }
                if self.dead[r as usize] {
                    return Err("Bu sayının dörtlüsü atıldı — söylenemez".into());
                }
                self.validate_cards(seat, &cards)?;
                self.do_play(seat, r, cards, reason, true);
            }
            Act::Play(cards) => {
                let Some(r) = self.rank else { return Err("Turu sen açıyorsun: önce bir sayı seç".into()) };
                if self.final_play() {
                    return Err("Son kartlara karar ver: Blöf! de ya da geç".into());
                }
                self.validate_cards(seat, &cards)?;
                self.do_play(seat, r, cards, reason, false);
            }
            Act::Challenge => {
                if self.pile.is_empty() {
                    return Err("İtiraz edilecek kart yok".into());
                }
                self.do_challenge(seat, reason);
            }
            Act::Pass => {
                if self.rank.is_none() {
                    return Err("Turu açan pas geçemez — kart koy".into());
                }
                self.do_pass(seat, reason);
            }
        }
        self.actions += 1;
        if self.actions >= MAX_ACTIONS && !self.over() {
            self.draw = true;
            self.note(seat, "draw", "Masa çok uzadı: berabere".into(), String::new());
        }
        Ok(())
    }

    fn do_play(&mut self, seat: usize, r: u8, cards: Vec<Card>, reason: String, lead: bool) {
        self.hands[seat].retain(|c| !cards.contains(c));
        for o in 0..4 {
            if o == seat {
                for &c in &cards {
                    self.know[o][c as usize] = K::Pile;
                }
            } else {
                for k in self.know[o].iter_mut() {
                    if *k == K::With(seat as u8, true) {
                        *k = K::With(seat as u8, false);
                    }
                }
            }
        }
        self.prof[seat].plays += 1;
        if lead {
            self.rank = Some(r);
            self.rounds += 1;
        } else {
            self.prof[seat].chances += 1;
        }
        let k = cards.len();
        self.pile.push(Play { seat, cards: cards.clone(), rank: r });
        self.passes = 0;
        self.serial += 1;
        let text = claim_text(k, r);
        self.note(seat, if lead { "lead" } else { "play" }, text.clone(), reason.clone());
        if self.hands[seat].is_empty() {
            let t = if seat == 0 { "Son kartlarını koydun!".to_string() } else { format!("{}: son kartları!", NAMES[seat]) };
            self.note(seat, "last", t, String::new());
        }
        self.last = Some(Event {
            serial: self.serial,
            seat,
            kind: if lead { "lead" } else { "play" },
            count: k,
            rank: r,
            text,
            reason,
            cards,
            burned: 0,
            win: false,
            reveal: None,
        });
        self.turn = (seat + 1) % 4;
    }

    fn do_pass(&mut self, seat: usize, reason: String) {
        let fin = self.final_play();
        self.prof[seat].chances += 1;
        self.passes += 1;
        self.serial += 1;
        let text = if fin { "Geç".to_string() } else { "Pas".to_string() };
        self.note(seat, "pass", text.clone(), reason.clone());
        let mut ev = Event {
            serial: self.serial,
            seat,
            kind: "pass",
            count: 0,
            rank: self.rank.unwrap_or(0),
            text,
            reason,
            cards: vec![],
            burned: 0,
            win: false,
            reveal: None,
        };
        self.turn = (seat + 1) % 4;
        if self.passes >= 3 {
            let last = self.pile.last().map(|p| p.seat).unwrap_or(self.turn);
            if self.hands[last].is_empty() {
                self.winner = Some(last);
                ev.win = true;
                let t = if last == 0 { "Kimse itiraz etmedi: kazandın!".to_string() } else { format!("Kimse itiraz etmedi: {} kazandı", NAMES[last]) };
                self.note(last, "win", t, String::new());
            } else {
                let n = self.pile_count();
                for p in std::mem::take(&mut self.pile) {
                    self.burned.extend(p.cards);
                }
                for o in 0..4 {
                    for k in self.know[o].iter_mut() {
                        if *k == K::Pile {
                            *k = K::Gone;
                        }
                    }
                }
                self.rank = None;
                self.passes = 0;
                self.turn = last;
                ev.burned = n;
                let who = if last == 0 { "Yeni turu sen açıyorsun".to_string() } else { format!("Yeni turu {} açıyor", NAMES[last]) };
                self.note(last, "burn", format!("Herkes pas geçti: {n} kart yandı. {who}"), String::new());
            }
        }
        self.last = Some(ev);
    }

    fn do_challenge(&mut self, seat: usize, reason: String) {
        let last = self.pile.last().cloned().expect("pile not empty");
        let lie = last.cards.iter().any(|&c| rank_of(c) != last.rank);
        let (taker, leader) = if lie { (last.seat, seat) } else { (seat, last.seat) };
        self.prof[seat].chances += 1;
        self.prof[seat].challenges += 1;
        self.prof[last.seat].reveals += 1;
        if lie {
            self.prof[last.seat].lies += 1;
        } else {
            self.prof[seat].wrong += 1;
        }
        let pile_seats: Vec<u8> = self.pile.iter().map(|p| p.seat as u8).collect();
        let all: Vec<Card> = std::mem::take(&mut self.pile).into_iter().flat_map(|p| p.cards).collect();
        let count = all.len();
        for o in 0..4 {
            if o == taker {
                for &c in &all {
                    self.know[o][c as usize] = K::Mine;
                }
            } else {
                for k in self.know[o].iter_mut() {
                    match *k {
                        K::Pile => *k = K::With(taker as u8, true),
                        K::With(q, false) if q as usize != o && pile_seats.contains(&q) => {
                            // Maybe still in q's hand, maybe in the pile (now in the taker's hand).
                            *k = if q as usize == taker { K::With(q, false) } else { K::Unknown };
                        }
                        _ => {}
                    }
                }
                for &c in &last.cards {
                    self.know[o][c as usize] = K::With(taker as u8, true);
                }
            }
        }
        self.hands[taker].extend(all);
        sort_hand(&mut self.hands[taker]);
        self.serial += 1;
        self.note(seat, "challenge", "Blöf!".into(), reason.clone());
        let verdict = if lie {
            format!(
                "Yalan! {} — {} yığını ({count} kart) aldı",
                names_of(&last.cards),
                if taker == 0 { "sen".to_string() } else { NAMES[taker].to_string() }
            )
        } else {
            format!(
                "Doğruymuş: {} — {} yığını ({count} kart) aldı",
                names_of(&last.cards),
                if taker == 0 { "sen".to_string() } else { NAMES[taker].to_string() }
            )
        };
        self.note(taker, "reveal", verdict, String::new());
        let discards = self.discard_quads(taker);
        self.rank = None;
        self.passes = 0;
        self.turn = leader;
        let mut win = false;
        if self.hands[leader].is_empty() {
            self.winner = Some(leader);
            win = true;
        } else if self.hands[taker].is_empty() {
            self.winner = Some(taker);
            win = true;
        }
        if let Some(w) = self.winner {
            let t = if w == 0 { "Elini bitirdin: kazandın!".to_string() } else { format!("{} elini bitirdi", NAMES[w]) };
            self.note(w, "win", t, String::new());
        }
        self.last = Some(Event {
            serial: self.serial,
            seat,
            kind: "challenge",
            count: last.cards.len(),
            rank: last.rank,
            text: "Blöf!".into(),
            reason,
            cards: vec![],
            burned: 0,
            win,
            reveal: Some(Reveal {
                challenger: seat,
                target: last.seat,
                rank: last.rank,
                cards: last.cards.clone(),
                lie,
                taker,
                leader,
                count,
                discards,
            }),
        });
    }

    /// The AI decision for `seat` (any seat — tests drive seat 0 too).
    fn decide(&mut self, seat: usize) -> Decision {
        let mut rng = self.rng.clone();
        let d = match self.brains[seat] {
            Brain::Impossible => decide_impossible(self, seat, &mut rng),
            b => {
                // Information-set boundary: the bounded brains only ever see `Info`.
                let info = self.info(seat);
                match b {
                    Brain::Easy => decide_easy(&info, &mut rng),
                    Brain::Normal => decide_normal(&info, &mut rng),
                    _ => pick(&hard_options(&info), 0.3, &mut rng),
                }
            }
        };
        self.rng = rng;
        d
    }

    fn ai_step(&mut self) -> Result<(), String> {
        let seat = self.turn;
        let d = self.decide(seat);
        self.apply(seat, d.act, d.reason)
    }
}

// -------------------------------------------------------------------------------------------------
// Claim analysis (shared by Normal, Hard, İmkânsız's lie-safety check and the player's hint/odds)

#[derive(Clone, Copy, Debug)]
struct ClaimEval {
    p: usize,
    k: usize,
    r: u8,
    /// Cards of the rank in my hand / that I put on this pile / out of the game / known in a third
    /// hand / known with the claimer.
    mine: u8,
    my_pile: u8,
    gone: u8,
    others: u8,
    withp: u8,
    /// The most cards of the rank the claimer can have played (never more than 3: no hand holds 4).
    max_possible: u8,
    certain: bool,
    p_cap: f64,
    p_lie: f64,
}

/// Evaluate "seat `p` played `k` cards claiming rank `r`" from `info`'s point of view. `hand_before`
/// = p's hand size before that play; `prior` = earlier plays of this round.
fn eval_claim(info: &Info, p: usize, k: usize, r: u8, hand_before: usize, prior: &[(usize, usize, u8)]) -> ClaimEval {
    let (mut mine, mut my_pile, mut gone, mut others, mut withp) = (0u8, 0u8, 0u8, 0u8, 0u8);
    let (mut withp_all, mut unknown, mut unknown_r) = (0usize, 0usize, 0usize);
    for c in 0..52u8 {
        let is_r = rank_of(c) == r;
        match info.know[c as usize] {
            K::Mine => mine += is_r as u8,
            K::Pile => my_pile += is_r as u8,
            K::Gone => gone += is_r as u8,
            K::With(q, _) if q as usize == p => {
                withp_all += 1;
                withp += is_r as u8;
            }
            K::With(_, _) => others += is_r as u8,
            K::Unknown => {
                unknown += 1;
                unknown_r += is_r as usize;
            }
        }
    }
    let max_possible = 4u8.saturating_sub(mine + my_pile + gone + others).min(3);
    let certain = k > max_possible as usize;
    let mut e = ClaimEval { p, k, r, mine, my_pile, gone, others, withp, max_possible, certain, p_cap: 0.0, p_lie: 1.0 };
    if certain {
        return e;
    }
    const TAU: f64 = 0.4; // how much of an unchallenged earlier claim we believe
    let (mut other_claims, mut p_prev) = (0.0, 0.0);
    for &(q, c, _) in prior {
        if q == info.me {
            continue;
        }
        if q == p {
            p_prev += c as f64;
        } else {
            other_claims += c as f64;
        }
    }
    let slots = hand_before.saturating_sub(withp_all);
    let a = (unknown_r as f64 - TAU * other_claims).max(0.0);
    let pop = ((unknown as f64 - other_claims).round().max(0.0) as usize).max(slots).max(a.ceil() as usize);
    let lead = prior.is_empty();
    // Likelihood of "p claims k" given p holds m cards of the rank: holders play what they have
    // (sometimes padded with one junk card, probability ε); players without the rank bluff with
    // propensity β (else they pass), mostly with a single card. A leader picks the rank it is
    // strongest in, so its m is weighted towards high counts.
    let pr = &info.prof[p];
    let beta = if lead { 1.0 } else { ((pr.lies as f64 + 1.5) / (pr.reveals as f64 + 3.0)).clamp(0.03, 0.85) };
    let mut eps = 0.12;
    if info.counts[p] <= 2 {
        eps *= 1.5;
    }
    let q = |k: usize| -> f64 {
        if lead {
            [0.0, 0.6, 0.3, 0.1, 0.01][k.min(4)]
        } else {
            [0.0, 0.75, 0.2, 0.05, 0.01][k.min(4)]
        }
    };
    // p's own earlier claims this round are deliberately ignored: "open with junk, follow with
    // the real cards" is a common pattern, so they say little about what p still holds.
    let _ = p_prev;
    let (mut lie_w, mut true_w) = (0.0, 0.0);
    for x in 0..=slots.min(a.ceil() as usize) {
        let pm = hyper_pmf_f(pop, a, slots, x);
        if pm <= 0.0 {
            continue;
        }
        let m = (x + withp as usize).min(3);
        let sel = if lead { [0.4, 1.5, 3.0, 4.0][m] } else { 1.0 };
        let l = if m >= k {
            if m == k {
                1.0 - eps
            } else {
                0.3
            }
        } else if m >= 1 && m + 1 == k {
            eps
        } else if m == 0 {
            beta * q(k)
        } else {
            0.03
        };
        if m >= k {
            true_w += pm * sel * l;
        } else {
            lie_w += pm * sel * l;
        }
    }
    let tot = lie_w + true_w;
    e.p_lie = if tot > 0.0 { (lie_w / tot).clamp(0.01, 1.0) } else { 1.0 };
    e.p_cap = 1.0 - e.p_lie;
    e
}

/// Evaluate the last play on the pile from `info`'s point of view.
fn eval_last(info: &Info) -> Option<ClaimEval> {
    let &(p, k, r) = info.plays.last()?;
    if p == info.me {
        return None;
    }
    Some(eval_claim(info, p, k, r, info.counts[p] + k, &info.plays[..info.plays.len() - 1]))
}

/// Facts behind a certain-lie verdict, as a sentence. `second` = addressed to the player.
fn certain_text(e: &ClaimEval, second: bool) -> String {
    let r = rname(e.r);
    let who = GEN[e.p];
    if e.k >= 4 {
        return format!("Dörtlüler atıldığı için kimse 4 tane {r} tutamaz → kesin Blöf!");
    }
    let mut facts = vec![];
    if e.mine > 0 {
        facts.push(format!("{} {} tane {r} var", if second { "Elinde" } else { "Elimde" }, e.mine));
    }
    if e.my_pile > 0 {
        facts.push(format!("{} tane {r} yığına {}", e.my_pile, if second { "senin koyduğun" } else { "benim koyduğum" }));
    }
    if e.gone > 0 {
        facts.push(format!("{} tane {r} oyun dışı", e.gone));
    }
    if e.others > 0 {
        facts.push(format!("{} tane {r} açılan kartlardan başka elde", e.others));
    }
    let base = if facts.is_empty() { String::new() } else { format!("{}; ", facts.join(", ")) };
    format!(
        "{base}{who} elinde en fazla {} tane {r} olabilir, {} dedi → kesin Blöf!",
        e.max_possible,
        e.k
    )
}

// -------------------------------------------------------------------------------------------------
// Easy

fn decide_easy(info: &Info, rng: &mut Rng) -> Decision {
    let n = rank_counts(&info.hand);
    let Some(r) = info.rank else {
        let max = (2..=14).map(|r| n[r]).max().unwrap_or(0);
        let ranks: Vec<u8> = (2..=14u8).filter(|&r| n[r as usize] == max && !info.dead[r as usize]).collect();
        let r = *rng.pick(&ranks);
        let mut cards = cards_of(&info.hand, r, 4);
        let mut reason = format!("En çok {} var elimde: {} tanesini açtım", rname(r), cards.len());
        let rest: Vec<Card> = info.hand.iter().copied().filter(|&c| rank_of(c) != r).collect();
        if !rest.is_empty() && cards.len() < 4 && rng.chance(0.1) {
            let c = *rng.pick(&rest);
            cards.push(c);
            reason.push_str(&format!(", araya rastgele bir {} kattım", cname(c)));
        }
        return Decision { act: Act::Lead(r, cards), reason };
    };
    let &(p, k, _) = info.plays.last().expect("follow has a last play");
    let mine = n[r as usize];
    let rn = rname(r);
    if info.fin {
        return if rng.chance(0.7) {
            Decision { act: Act::Challenge, reason: format!("{} son kartlarına güvenmedim → Blöf!", NAMES[p]) }
        } else {
            Decision { act: Act::Pass, reason: "Son kartlarına inandım".into() }
        };
    }
    if p != info.me && mine + k > 4 && rng.chance(0.7) {
        return Decision {
            act: Act::Challenge,
            reason: format!("Elimde {mine} tane {rn} var; {k} tane daha olamaz → Blöf!"),
        };
    }
    if p != info.me && rng.chance(0.07 + 0.05 * k as f64) {
        return Decision { act: Act::Challenge, reason: "İçimden bir ses yalan dedi → Blöf! (hesap yapmadım)".into() };
    }
    if mine > 0 {
        return Decision {
            act: Act::Play(cards_of(&info.hand, r, 4)),
            reason: format!("Elimde {mine} tane {rn} var: doğruyu söyledim"),
        };
    }
    if rng.chance(0.55) {
        let c = *rng.pick(&info.hand);
        return Decision {
            act: Act::Play(vec![c]),
            reason: format!("Elimde {rn} yok; rastgele bir kartı ({}) bir tane {rn} diye verdim", cname(c)),
        };
    }
    Decision { act: Act::Pass, reason: format!("Elimde {rn} yok: pas") }
}

// -------------------------------------------------------------------------------------------------
// Normal

fn decide_normal(info: &Info, rng: &mut Rng) -> Decision {
    let n = rank_counts(&info.hand);
    let Some(r) = info.rank else {
        let max = (2..=14).filter(|&r| !info.dead[r]).map(|r| n[r]).max().unwrap_or(0);
        let ranks: Vec<u8> = (2..=14u8).filter(|&r| n[r as usize] == max && !info.dead[r as usize]).collect();
        let r = *rng.pick(&ranks);
        let mut cards = cards_of(&info.hand, r, 4);
        let mut reason = format!("Elimde {} tane {} var: hepsini doğru açtım", cards.len(), rname(r));
        if cards.len() < 3 && info.hand.len() > cards.len() + 3 && rng.chance(0.3) {
            let j = junk(&info.hand, r, 1);
            reason = format!(
                "{} tane gerçek {} arasına tekli kartımı ({}) kattım; açılışta yakalansam az kaybederim",
                cards.len(),
                rname(r),
                names_of(&j)
            );
            cards.extend(j);
        }
        return Decision { act: Act::Lead(r, cards), reason };
    };
    let rn = rname(r);
    let mine = n[r as usize];
    let s = info.pile_count;
    if let Some(e) = eval_last(info) {
        if e.certain {
            return Decision { act: Act::Challenge, reason: certain_text(&e, false) };
        }
        if info.fin {
            return if e.withp as usize >= e.k {
                Decision {
                    act: Act::Pass,
                    reason: format!("{} tane {rn} yığından ona geçmişti, son kartları gerçek", e.withp),
                }
            } else {
                Decision {
                    act: Act::Challenge,
                    reason: format!("{} son kartları: itiraz etmezsem oyun biter → Blöf!", NAMES[e.p]),
                }
            };
        }
        let claims_others: usize = info.plays.iter().filter(|q| q.0 != info.me).map(|q| q.1).sum();
        let known = (e.mine + e.my_pile + e.gone) as usize;
        let over = claims_others + known > 4;
        let tight = e.k >= 2 && e.k == e.max_possible as usize;
        if (over || tight) && s <= 10 && rng.chance(0.65) {
            let reason = if over {
                format!("Bu turda {claims_others} tane {rn} söylendi, {known} tanesinin yerini biliyorum: biri yalan söylüyor → Blöf!")
            } else {
                if e.p == 0 {
                    format!("{} tane {rn} tutman için kalan bütün {rn} kartları sende olmalı → Blöf!", e.k)
                } else {
                    format!("{} {} tane {rn} tutması için kalan bütün {rn} kartları onda olmalı → Blöf!", GEN[e.p], e.k)
                }
            };
            return Decision { act: Act::Challenge, reason };
        }
    }
    if mine > 0 {
        return Decision {
            act: Act::Play(cards_of(&info.hand, r, 4)),
            reason: format!("Elimde {mine} tane {rn} var: doğruyu söyledim"),
        };
    }
    if rng.chance(if s <= 5 { 0.55 } else { 0.25 }) {
        let j = junk(&info.hand, r, 1);
        return Decision {
            act: Act::Play(j.clone()),
            reason: format!("Elimde {rn} yok; yığın {s} kart, tekli kartımı ({}) {rn} diye verdim", names_of(&j)),
        };
    }
    Decision { act: Act::Pass, reason: format!("Elimde {rn} yok; {s} kartlık yığında blöf riskli → pas") }
}

// -------------------------------------------------------------------------------------------------
// Hard (expected-cost options + softmax mixed strategy). Also used for the player's hint.

#[derive(Clone, Debug)]
enum Why {
    Certain(ClaimEval),
    Suspect(ClaimEval, usize),
    FinalCall(ClaimEval),
    Accept(ClaimEval),
    Finish(usize, u8),
    Truth(usize, u8),
    Partial(usize, u8, Card, f64),
    Bluff(Vec<Card>, u8, f64, usize),
    Pass(u8, usize, f64, bool),
    LeadTruth(usize, u8),
    LeadHold(usize, usize, u8),
    LeadBluff(usize, Vec<Card>, u8, f64),
    FinishLie(usize, u8, f64),
}

#[derive(Clone, Debug)]
struct Opt {
    act: Act,
    cost: f64,
    why: Why,
}

fn challenge_rate(p: &Profile) -> f64 {
    (p.challenges as f64 + 1.0) / (p.chances as f64 + 5.0)
}

/// Estimated chance that a lie of `claim` cards of rank `r` by `info.me` gets challenged.
fn caught(info: &Info, r: u8, claim: usize) -> f64 {
    let nx = (info.me + 1) % 4;
    let total: usize = info.plays.iter().filter(|p| p.2 == r).map(|p| p.1).sum::<usize>() + claim;
    if claim >= 4 {
        return 0.95;
    }
    let mut base = 0.10 + 0.09 * (claim as f64 - 1.0) + 0.16 * total.saturating_sub(3) as f64;
    if info.counts[nx] <= 2 {
        base += 0.12;
    }
    let f = (challenge_rate(&info.prof[nx]) / 0.2).clamp(0.5, 2.5);
    let mut pc = base * f + 0.06;
    // An opponent who challenges often and is never wrong catches every lie that reaches it.
    for q in (1..4).map(|d| (info.me + d) % 4) {
        let pr = &info.prof[q];
        if pr.challenges >= 3 && pr.wrong == 0 {
            pc = pc.max(if q == nx { 0.9 } else { 0.7 });
        }
    }
    pc.clamp(0.03, 0.95)
}

fn hard_options(info: &Info) -> Vec<Opt> {
    let n = rank_counts(&info.hand);
    let h = info.hand.len();
    let mut out = vec![];
    let Some(r) = info.rank else {
        // Lead: declare a rank, play t true cards of it plus j junk cards.
        for rr in 2..=14u8 {
            if info.dead[rr as usize] {
                continue;
            }
            let m = n[rr as usize];
            let spare = h - m;
            for t in 0..=m.min(4) {
                for j in 0..=2usize.min(spare) {
                    let k = t + j;
                    if k == 0 || k > 4 {
                        continue;
                    }
                    let mut cards = cards_of(&info.hand, rr, t);
                    let jc = junk(&info.hand, rr, j);
                    cards.extend(jc.iter().copied());
                    if k == h {
                        if j == 0 {
                            out.push(Opt { act: Act::Lead(rr, cards), cost: -100.0, why: Why::Finish(t, rr) });
                        } else {
                            let pcf = 0.92;
                            let cost = -WIN * (1.0 - pcf) + pcf * k as f64;
                            out.push(Opt { act: Act::Lead(rr, cards), cost, why: Why::FinishLie(k, rr, pcf) });
                        }
                        continue;
                    }
                    let pc = if j > 0 { caught(info, rr, k) } else { 0.0 };
                    let cost = -(k as f64) + pc * k as f64 - 0.55 * (m - t) as f64;
                    let why = if j > 0 {
                        Why::LeadBluff(t, jc, rr, pc)
                    } else if t < m {
                        Why::LeadHold(t, m - t, rr)
                    } else {
                        Why::LeadTruth(t, rr)
                    };
                    out.push(Opt { act: Act::Lead(rr, cards), cost, why });
                }
            }
        }
        return out;
    };
    let s = info.pile_count;
    let mine = n[r as usize];
    let e = eval_last(info);
    if let Some(e) = e {
        if e.certain {
            out.push(Opt { act: Act::Challenge, cost: -50.0, why: Why::Certain(e) });
            return out;
        }
        if info.fin {
            // Not challenging ends the game; a wrong challenge costs nothing that matters.
            if e.p_lie >= 0.01 {
                out.push(Opt { act: Act::Challenge, cost: -10.0, why: Why::FinalCall(e) });
            } else {
                out.push(Opt { act: Act::Pass, cost: 0.0, why: Why::Accept(e) });
            }
            return out;
        }
        let mut gain = -1.0 - 0.3 * s as f64;
        if info.counts[e.p] <= 3 {
            gain -= 0.4 * s as f64;
        }
        let cost = e.p_lie * gain + (1.0 - e.p_lie) * s as f64;
        out.push(Opt { act: Act::Challenge, cost, why: Why::Suspect(e, s) });
    }
    let t = mine.min(4);
    if t > 0 {
        let cards = cards_of(&info.hand, r, t);
        if t == h {
            out.push(Opt { act: Act::Play(cards), cost: -100.0, why: Why::Finish(t, r) });
            return out;
        }
        out.push(Opt { act: Act::Play(cards.clone()), cost: -(t as f64), why: Why::Truth(t, r) });
        if t < 4 && h > t {
            let jc = junk(&info.hand, r, 1);
            let k = t + 1;
            let mut c2 = cards;
            c2.extend(jc.iter().copied());
            if k == h {
                let pcf = 0.92;
                let cost = -WIN * (1.0 - pcf) + pcf * (s + k) as f64;
                out.push(Opt { act: Act::Play(c2), cost, why: Why::FinishLie(k, r, pcf) });
            } else {
                let pc = caught(info, r, k);
                let cost = -(k as f64) + pc * (s + k) as f64;
                out.push(Opt { act: Act::Play(c2), cost, why: Why::Partial(t, r, jc[0], pc) });
            }
        }
    } else {
        for j in 1..=2usize.min(h) {
            let jc = junk(&info.hand, r, j);
            if j == h {
                let pcf = 0.92;
                let cost = -WIN * (1.0 - pcf) + pcf * (s + j) as f64;
                out.push(Opt { act: Act::Play(jc), cost, why: Why::FinishLie(j, r, pcf) });
            } else {
                let pc = caught(info, r, j);
                let cost = -(j as f64) + pc * (s + j) as f64;
                out.push(Opt { act: Act::Play(jc.clone()), cost, why: Why::Bluff(jc, r, pc, s) });
            }
        }
    }
    let pc1 = caught(info, r, 1);
    out.push(Opt { act: Act::Pass, cost: 0.3, why: Why::Pass(r, s, pc1, mine > 0) });
    out
}

/// Explain an option, first person (AI reason) or second person (`second`, the player's hint).
fn say(why: &Why, second: bool) -> String {
    let el = if second { "Elinde" } else { "Elimde" };
    match why {
        Why::Certain(e) => certain_text(e, second),
        Why::Suspect(e, s) => format!(
            "{} {} tane {} tutma olasılığı %{}, yalan olasılığı ≈ %{}; yığın {} kart → Blöf! demeye değer",
            GEN[e.p],
            e.k,
            rname(e.r),
            pct(e.p_cap),
            pct(e.p_lie),
            s
        ),
        Why::FinalCall(e) => {
            let who = if e.p == 0 { "Senin".to_string() } else { GEN[e.p].to_string() };
            format!(
                "{who} son kartları: itiraz {} oyun biter, yalan olasılığı ≈ %{} → Blöf!",
                if second { "etmezsen" } else { "etmezsem" },
                pct(e.p_lie)
            )
        }
        Why::Accept(e) => format!(
            "Son kartlar büyük olasılıkla gerçek ({} tane {} ona geçmişti) → geç",
            e.withp,
            rname(e.r)
        ),
        Why::Finish(t, r) => format!(
            "{el} kalan {t} kart da {}: doğruyu söyle{} — itiraz gelse bile el biter",
            rname(*r),
            if second { "" } else { "dim" }
        ),
        Why::Truth(t, r) => {
            if second {
                format!("{el} {t} tane {} var: doğruyu söyle, {t} kart eksilt", rname(*r))
            } else {
                format!("{el} {t} tane {} var: doğruyu söyleyip {t} kart eksilttim", rname(*r))
            }
        }
        Why::Partial(t, r, c, pc) => format!(
            "{t} gerçek {} arasına kötü bir kartı ({}) sıkıştır{}: yakalanma riski ≈ %{}",
            rname(*r),
            cname(*c),
            if second { "" } else { "dım" },
            pct(*pc)
        ),
        Why::Bluff(cs, r, pc, s) => format!(
            "{el} hiç {} yok; yığın {s} kart, yakalanma riski ≈ %{} → {} ile blöf{}",
            rname(*r),
            pct(*pc),
            names_of(cs),
            if second { " yap" } else { "" }
        ),
        Why::Pass(r, _, _, true) => format!(
            "{} kartlarını sonraya sakla{}: pas",
            rname(*r),
            if second { "" } else { "dım" }
        ),
        Why::Pass(r, s, pc, false) => format!(
            "{el} {} yok; {s} kartlık yığında blöf riski ≈ %{} → pas",
            rname(*r),
            pct(*pc)
        ),
        Why::LeadTruth(t, r) => format!(
            "{el} {t} tane {} var: hepsini doğru aç{}",
            rname(*r),
            if second { "" } else { "tım" }
        ),
        Why::LeadHold(t, kept, r) => format!(
            "{t} tane {} ile aç, {kept} tanesini tur içinde doğru oynamak için sakla{}",
            rname(*r),
            if second { "" } else { "dım" }
        ),
        Why::LeadBluff(t, jc, r, pc) => format!(
            "{} diye açıp {}{} elden çıkar{}: yığında yalnızca {} kart var, yakalanma riski ≈ %{}",
            rname(*r),
            if *t > 0 { format!("{t} gerçek kartın yanında ") } else { String::new() },
            names_of(jc),
            if second { "" } else { "dım" },
            t + jc.len(),
            pct(*pc)
        ),
        Why::FinishLie(k, r, pcf) => format!(
            "Son {k} kartı {} diye koy{}: herkes itiraz edebilir (≈ %{}), ama tutarsa oyun biter",
            rname(*r),
            if second { "" } else { "dum" },
            pct(*pcf)
        ),
    }
}

fn pick(opts: &[Opt], temp: f64, rng: &mut Rng) -> Decision {
    let best = opts.iter().map(|o| o.cost).fold(f64::INFINITY, f64::min);
    let w: Vec<f64> = opts.iter().map(|o| (-(o.cost - best) / temp).exp()).collect();
    let total: f64 = w.iter().sum();
    let mut x = rng.f64() * total;
    let mut idx = 0;
    for (i, wi) in w.iter().enumerate() {
        idx = i;
        if x < *wi {
            break;
        }
        x -= wi;
    }
    let o = &opts[idx];
    Decision { act: o.act.clone(), reason: say(&o.why, false) }
}

fn best_opt(opts: &[Opt]) -> Option<&Opt> {
    opts.iter().min_by(|a, b| a.cost.partial_cmp(&b.cost).unwrap_or(std::cmp::Ordering::Equal))
}

// -------------------------------------------------------------------------------------------------
// İmkânsız (omniscient)

/// Would a lie of `claim` cards of rank `r` by `me` survive? Every opponent who may get to
/// challenge it is checked: an omniscient one always catches it; a bounded one is modelled with
/// its own information set (it would challenge a certain lie or a ≥ 25 % suspicion).
fn lie_safe(g: &Game, me: usize, r: u8, claim: usize) -> bool {
    if claim >= 4 {
        return false;
    }
    for q in (1..4).map(|d| (me + d) % 4) {
        if g.brains[q] == Brain::Impossible && !(q == 0 && g.human) {
            return false;
        }
        let info = g.info(q);
        let prior: Vec<(usize, usize, u8)> = info.plays.clone();
        let e = eval_claim(&info, me, claim, r, g.hands[me].len(), &prior);
        if e.certain || e.p_lie >= 0.25 {
            return false;
        }
    }
    true
}

fn decide_impossible(g: &Game, me: usize, _rng: &mut Rng) -> Decision {
    let hand = &g.hands[me];
    let n = rank_counts(hand);
    let nx = (me + 1) % 4;
    let Some(r) = g.rank else {
        if let Some(r) = (2..=14u8).find(|&r| n[r as usize] == hand.len()) {
            return Decision {
                act: Act::Lead(r, hand.clone()),
                reason: format!("Son {} kartım da {}: doğru açıyorum, itiraz gelse bile biterim", hand.len(), rname(r)),
            };
        }
        let mut best = (i64::MIN, 2u8);
        for rr in 2..=14u8 {
            let m = n[rr as usize] as i64;
            if m == 0 || g.dead[rr as usize] {
                continue;
            }
            let next_has = rank_counts(&g.hands[nx])[rr as usize] as i64;
            let others: i64 = (1..4).map(|d| rank_counts(&g.hands[(me + d) % 4])[rr as usize] as i64).sum();
            let score = 10 * m - 3 * next_has - others;
            if score > best.0 {
                best = (score, rr);
            }
        }
        let rr = best.1;
        let mut cards = cards_of(hand, rr, 4);
        let next_has = rank_counts(&g.hands[nx])[rr as usize];
        let mut reason = if next_has == 0 {
            format!(
                "{} tane {} ile doğru açtım; bütün elleri görüyorum, {} elinde hiç {} yok",
                cards.len(),
                rname(rr),
                GEN[nx],
                rname(rr)
            )
        } else {
            format!(
                "{} tane {} ile doğru açtım; bütün elleri görüyorum, {} elinde yalnızca {} tane {} var",
                cards.len(),
                rname(rr),
                GEN[nx],
                next_has,
                rname(rr)
            )
        };
        if cards.len() < 3 && hand.len() > cards.len() + 1 && lie_safe(g, me, rr, cards.len() + 1) {
            let j = junk(hand, rr, 1);
            reason = format!("{} tane {} arasına {} kattım: kimse bunu yakalayacak bilgiye sahip değil", cards.len(), rname(rr), names_of(&j));
            cards.extend(j);
        }
        return Decision { act: Act::Lead(rr, cards), reason };
    };
    let rn = rname(r);
    let last = g.pile.last().expect("follow has a last play");
    let lie = last.cards.iter().any(|&c| rank_of(c) != last.rank);
    if lie && last.seat != me {
        let bad: Vec<Card> = last.cards.iter().copied().filter(|&c| rank_of(c) != r).collect();
        let whose = if last.seat == 0 { "Senin koyduğun".to_string() } else { format!("{} koyduğu", GEN[last.seat]) };
        return Decision {
            act: Act::Challenge,
            reason: format!(
                "Yığını görüyorum: {whose} kartlarda {} var — {} değil → Blöf!",
                names_of(&bad),
                claim_lower(last.cards.len(), r)
            ),
        };
    }
    if g.final_play() {
        return Decision {
            act: Act::Pass,
            reason: format!("Son kartlar gerçekten {} — itiraz etmek boşa yığın almak olur", claim_lower(last.cards.len(), r)),
        };
    }
    let t = n[r as usize].min(4);
    if t > 0 {
        let mut cards = cards_of(hand, r, t);
        if t == hand.len() {
            return Decision { act: Act::Play(cards), reason: format!("Son {t} kartım da {rn}: doğruyu söyleyip bitiriyorum") };
        }
        let mut reason = format!("Elimde {t} tane {rn} var: doğruyu söyledim");
        if t < 3 && hand.len() > t + 1 && lie_safe(g, me, r, t + 1) {
            let j = junk(hand, r, 1);
            reason = format!("{t} gerçek {rn} arasına {} kattım: sıradakilerin hiçbiri bunu yakalayamaz", names_of(&j));
            cards.extend(j);
        }
        return Decision { act: Act::Play(cards), reason };
    }
    let s = g.pile_count();
    if s <= 6 && hand.len() > 1 && lie_safe(g, me, r, 1) {
        let j = junk(hand, r, 1);
        return Decision {
            act: Act::Play(j.clone()),
            reason: format!("Elimde {rn} yok; {} kartını {rn} diye verdim — sıradakilerin bilgisi bunu yakalamaya yetmez", names_of(&j)),
        };
    }
    let catcher = (1..4).map(|d| (me + d) % 4).find(|&q| g.brains[q] == Brain::Impossible && !(q == 0 && g.human));
    let reason = match catcher {
        Some(q) => format!("Elimde {rn} yok; yalan söylesem {} görür → pas", NAMES[q]),
        None => format!("Elimde {rn} yok; yalan güvenli değil → pas"),
    };
    Decision { act: Act::Pass, reason }
}

// -------------------------------------------------------------------------------------------------
// Session

pub struct Blof {
    g: Game,
    brain: Brain,
    hint: Option<Value>,
    used_help: bool,
    version: u64,
}

pub fn create(_level: u32, mode: &str) -> Result<Box<dyn Session>, String> {
    let b = Brain::from_mode(mode).ok_or("Bilinmeyen masa")?;
    Ok(Box::new(Blof::new(time_seed(), b)))
}

impl Blof {
    fn new(seed: u64, b: Brain) -> Blof {
        Blof { g: Game::new(seed, [Brain::Hard, b, b, b], true), brain: b, hint: None, used_help: false, version: 0 }
    }

    fn parse_cards(v: &Value) -> Result<Vec<Card>, String> {
        let arr = v.as_array().ok_or("Kart listesi bekleniyor")?;
        let mut out = vec![];
        for c in arr {
            let s = c[0].as_u64().ok_or("Geçersiz kart")?;
            let r = c[1].as_u64().ok_or("Geçersiz kart")?;
            if s > 3 || !(2..=14).contains(&r) {
                return Err("Geçersiz kart".into());
            }
            out.push(card_id(s as u8, r as u8));
        }
        Ok(out)
    }

    fn your_turn(&self) -> Result<(), String> {
        if self.g.over() {
            return Err("Oyun bitti".into());
        }
        if self.g.turn != 0 {
            return Err("Sıra rakipte".into());
        }
        Ok(())
    }

    fn compute_hint(&self) -> Value {
        let info = self.g.info(0);
        let opts = hard_options(&info);
        let Some(o) = best_opt(&opts) else { return Value::Null };
        let (kind, cards, rank) = match &o.act {
            Act::Lead(r, cs) => ("lead", cs.clone(), Some(*r)),
            Act::Play(cs) => ("play", cs.clone(), self.g.rank),
            Act::Challenge => ("challenge", vec![], self.g.rank),
            Act::Pass => ("pass", vec![], self.g.rank),
        };
        let mut text = say(&o.why, true);
        if let Some(odds) = self.odds() {
            if kind != "challenge" {
                if let Some(t) = odds["text"].as_str() {
                    text = format!("{text}. {t}");
                }
            }
        }
        json!({"kind": kind, "cards": cards_json(&cards), "rank": rank, "text": text})
    }

    /// Probability helper for the player: what the last claim needs, from your information only.
    fn odds(&self) -> Option<Value> {
        let info = self.g.info(0);
        let e = eval_last(&info)?;
        let r = rname(e.r);
        let unseen = 4u8.saturating_sub(e.mine + e.my_pile + e.gone + e.others);
        let text = if e.certain {
            certain_text(&e, true)
        } else {
            format!(
                "{} {} tane {r} dedi. Bu sayıdan senin göremediğin en fazla {unseen} kart var; {} elinde en fazla {} tane {r} olabilir. Yalan olasılığı ≈ %{}",
                NAMES[e.p],
                e.k,
                GEN[e.p],
                e.max_possible,
                pct(e.p_lie)
            )
        };
        Some(json!({
            "seat": e.p,
            "rank": e.r,
            "claimed": e.k,
            "mine": e.mine,
            "unseen": unseen,
            "max_possible": e.max_possible,
            "certain": e.certain,
            "p_lie": (e.p_lie * 100.0).round() / 100.0,
            "text": text,
        }))
    }
}

fn cards_json(cs: &[Card]) -> Value {
    Value::Array(cs.iter().map(|&c| json!([suit_of(c), rank_of(c)])).collect())
}

fn event_json(e: &Event) -> Value {
    json!({
        "serial": e.serial,
        "seat": e.seat,
        "kind": e.kind,
        "count": e.count,
        "rank": e.rank,
        "text": e.text,
        "reason": e.reason,
        "cards": cards_json(&e.cards),
        "burned": e.burned,
        "win": e.win,
        "reveal": e.reveal.as_ref().map(|r| json!({
            "challenger": r.challenger,
            "target": r.target,
            "rank": r.rank,
            "cards": cards_json(&r.cards),
            "lie": r.lie,
            "taker": r.taker,
            "leader": r.leader,
            "count": r.count,
            "discards": r.discards,
        })),
    })
}

impl Session for Blof {
    fn state(&self) -> Value {
        let g = &self.g;
        let status = match g.winner {
            Some(0) => "won",
            Some(_) => "lost",
            None if g.draw => "draw",
            None => "playing",
        };
        let playing = !g.over();
        let your = playing && g.turn == 0;
        let fin = g.final_play();
        let phase = if !playing {
            "over"
        } else if g.rank.is_none() {
            "lead"
        } else {
            "follow"
        };
        let summary = match g.winner {
            Some(0) => Some(format!(
                "Elini ilk sen bitirdin · {} tur · Doğru itirazın: {}/{}",
                g.rounds,
                g.prof[0].challenges - g.prof[0].wrong,
                g.prof[0].challenges
            )),
            Some(w) => Some(format!("{} elini bitirdi · Elinde {} kart kaldı · {} tur", NAMES[w], g.hands[0].len(), g.rounds)),
            None if g.draw => Some("Masa çok uzadı: berabere".to_string()),
            None => None,
        };
        let stars = if g.winner == Some(0) {
            if self.used_help {
                1
            } else {
                3
            }
        } else {
            0
        };
        let pile: Vec<Value> = g
            .pile
            .iter()
            .map(|p| json!({"seat": p.seat, "count": p.cards.len(), "rank": p.rank, "cards": cards_json(&p.cards)}))
            .collect();
        let last_play = g
            .pile
            .last()
            .map(|p| json!({"seat": p.seat, "count": p.cards.len(), "rank": p.rank, "cards": cards_json(&p.cards)}));
        let start = g.log.len().saturating_sub(LOG_KEEP);
        let log: Vec<Value> = g.log[start..]
            .iter()
            .map(|l| json!({"serial": l.serial, "seat": l.seat, "kind": l.kind, "text": l.text, "reason": l.reason}))
            .collect();
        let stats: Vec<Value> = g
            .prof
            .iter()
            .map(|p| json!({"plays": p.plays, "reveals": p.reveals, "lies": p.lies, "challenges": p.challenges, "wrong": p.wrong}))
            .collect();
        let dead: Vec<u8> = (2..=14u8).filter(|&r| g.dead[r as usize]).collect();
        let odds = if playing { self.odds() } else { None };
        json!({
            "status": status,
            "stars": stars,
            "title": self.brain.label(),
            "goal": "Kartlarını ilk sen bitir · yalanları yakala",
            "summary": summary,
            "mode": self.brain.label(),
            "seed": g.seed,
            "names": NAMES,
            "turn": if g.turn == 0 { "you" } else { "ai" },
            "seat": g.turn,
            "ai_pending": playing && g.turn != 0,
            "phase": phase,
            "final": fin,
            "rank": g.rank,
            "hand": cards_json(&g.hands[0]),
            "hands": g.hands.iter().map(|h| cards_json(h)).collect::<Vec<_>>(),
            "counts": g.hands.iter().map(|h| h.len()).collect::<Vec<_>>(),
            "pile_count": g.pile_count(),
            "pile": pile,
            "last_play": last_play,
            "can_lead": your && g.rank.is_none(),
            "can_play": your && g.rank.is_some() && !fin,
            "can_challenge": your && !g.pile.is_empty(),
            "can_pass": your && g.rank.is_some(),
            "dead_ranks": dead,
            "discards": g.discards.iter().map(|&(s, r)| json!({"seat": s, "rank": r})).collect::<Vec<_>>(),
            "burned": g.burned.len(),
            "burned_cards": cards_json(&g.burned),
            "event": g.last.as_ref().map(event_json),
            "log": log,
            "odds": odds,
            "hint": self.hint,
            "stats": stats,
            "winner": g.winner,
            "used_help": self.used_help,
            "actions": g.actions,
            "version": self.version,
        })
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        let r = self.act_inner(a);
        if r.is_ok() {
            self.version += 1;
        }
        r
    }
}

impl Blof {
    fn act_inner(&mut self, a: &Value) -> Result<(), String> {
        if a["ai"].as_bool() == Some(true) {
            if self.g.over() {
                return Err("Oyun bitti".into());
            }
            if self.g.turn == 0 {
                return Err("Sıra sende".into());
            }
            self.g.ai_step()?;
            self.hint = None;
            return Ok(());
        }
        if a["hint"].as_bool() == Some(true) {
            self.your_turn()?;
            self.hint = Some(self.compute_hint());
            self.used_help = true;
            return Ok(());
        }
        let act = if a["challenge"].as_bool() == Some(true) {
            Act::Challenge
        } else if a["pass"].as_bool() == Some(true) {
            Act::Pass
        } else if !a["play"].is_null() {
            let cards = Self::parse_cards(&a["play"])?;
            let rank = a["rank"].as_u64();
            match (self.g.rank, rank) {
                (None, Some(r)) => Act::Lead(r.min(255) as u8, cards),
                (None, None) => return Err("Turu sen açıyorsun: bir sayı seç".into()),
                (Some(cur), Some(r)) if r != cur as u64 => {
                    return Err(format!("Bu turda sayı {} — değiştiremezsin", rname(cur)));
                }
                (Some(_), _) => Act::Play(cards),
            }
        } else {
            return Err("Bilinmeyen hamle".into());
        };
        self.your_turn()?;
        let had = self.hint.take();
        let r = self.g.apply(0, act, String::new());
        if r.is_err() {
            self.hint = had;
        }
        r
    }
}

// -------------------------------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn all_ai(seed: u64, brains: [Brain; 4]) -> Game {
        Game::new(seed, brains, false)
    }

    /// Play an AI-only match to the end; returns the game.
    fn run(mut g: Game) -> Game {
        while !g.over() {
            let seat = g.turn;
            let d = g.decide(seat);
            let snapshot = (d.act.clone(), d.reason.clone());
            if let Err(e) = g.apply(seat, d.act, d.reason) {
                panic!("AI seat {seat} ({:?}) made an illegal action {:?}: {e}", g.brains[seat], snapshot);
            }
        }
        g
    }

    fn c(s: u8, r: u8) -> Card {
        card_id(s, r)
    }

    /// A game with hand-picked hands, seat 0 to lead, nobody holding a four of a kind.
    fn custom(hands: [Vec<Card>; 4], turn: usize) -> Game {
        let mut g = all_ai(1, [Brain::Normal; 4]);
        g.hands = hands;
        g.know = [[K::Unknown; 52]; 4];
        for s in 0..4 {
            sort_hand(&mut g.hands[s]);
            for &cd in &g.hands[s] {
                g.know[s][cd as usize] = K::Mine;
            }
        }
        g.dead = [false; 15];
        g.discards.clear();
        g.turn = turn;
        g
    }

    fn total_cards(g: &Game) -> usize {
        g.hands.iter().map(|h| h.len()).sum::<usize>() + g.pile_count() + g.burned.len() + 4 * g.discards.len()
    }

    #[test]
    fn dealing() {
        for seed in 0..200 {
            let g = all_ai(seed, [Brain::Normal; 4]);
            let mut seen = [false; 52];
            for h in &g.hands {
                for &cd in h {
                    assert!(!seen[cd as usize]);
                    seen[cd as usize] = true;
                }
                // no four of a kind survives the deal
                assert!(rank_counts(h).iter().all(|&n| n < 4));
            }
            for &(s, r) in &g.discards {
                assert_eq!(rank_counts(&g.hands[s])[r as usize], 0);
                for su in 0..4 {
                    assert!(!seen[c(su, r) as usize]);
                    seen[c(su, r) as usize] = true;
                }
                assert!(g.dead[r as usize]);
            }
            assert!(seen.iter().all(|&b| b), "every card dealt exactly once");
            for (s, h) in g.hands.iter().enumerate() {
                let q = g.discards.iter().filter(|d| d.0 == s).count();
                assert_eq!(h.len(), 13 - 4 * q);
            }
            assert!(g.turn < 4 && g.rank.is_none());
        }
        // Different seeds deal differently; the same seed deals the same.
        assert_eq!(all_ai(5, [Brain::Easy; 4]).hands, all_ai(5, [Brain::Easy; 4]).hands);
        assert_ne!(all_ai(5, [Brain::Easy; 4]).hands, all_ai(6, [Brain::Easy; 4]).hands);
    }

    #[test]
    fn challenge_true_claim_challenger_takes_pile() {
        let mut g = custom(
            [
                vec![c(0, 7), c(1, 7), c(0, 9), c(0, 10)],
                vec![c(2, 7), c(1, 9), c(1, 10), c(0, 11)],
                vec![c(3, 7), c(2, 9), c(2, 10)],
                vec![c(3, 9), c(3, 10), c(1, 11)],
            ],
            0,
        );
        g.apply(0, Act::Lead(7, vec![c(0, 7), c(1, 7)]), String::new()).unwrap();
        assert_eq!(g.rank, Some(7));
        assert_eq!(g.turn, 1);
        g.apply(1, Act::Play(vec![c(2, 7)]), String::new()).unwrap();
        assert_eq!(g.pile_count(), 3);
        // Seat 2 challenges a true claim: seat 2 takes all 3 cards, seat 1 leads.
        g.apply(2, Act::Challenge, String::new()).unwrap();
        let rv = g.last.as_ref().unwrap().reveal.clone().unwrap();
        assert!(!rv.lie);
        assert_eq!((rv.taker, rv.leader, rv.count), (2, 1, 3));
        // Seat 2 now holds all four 7s → discarded, 7 is dead.
        assert!(g.dead[7]);
        assert_eq!(g.hands[2].len(), 2);
        assert_eq!(g.turn, 1);
        assert!(g.rank.is_none() && g.pile.is_empty());
        assert_eq!(total_cards(&g), 14);
        assert_eq!(g.prof[2].wrong, 1);
        // A dead rank can't be named.
        assert!(g.apply(1, Act::Lead(7, vec![c(1, 9)]), String::new()).is_err());
    }

    #[test]
    fn challenge_lie_liar_takes_pile_and_knowledge_updates() {
        let mut g = custom(
            [
                vec![c(0, 7), c(0, 9), c(0, 10)],
                vec![c(1, 9), c(1, 10), c(0, 11), c(0, 12)],
                vec![c(2, 9), c(2, 10)],
                vec![c(3, 9), c(3, 10), c(1, 11)],
            ],
            0,
        );
        g.apply(0, Act::Lead(7, vec![c(0, 7)]), String::new()).unwrap();
        // Seat 1 lies: "two 7s" with a jack and a queen.
        g.apply(1, Act::Play(vec![c(0, 11), c(0, 12)]), String::new()).unwrap();
        g.apply(2, Act::Challenge, String::new()).unwrap();
        let rv = g.last.as_ref().unwrap().reveal.clone().unwrap();
        assert!(rv.lie);
        assert_eq!((rv.taker, rv.leader, rv.count), (1, 2, 3));
        assert_eq!(g.hands[1].len(), 5);
        assert!(g.hands[1].contains(&c(0, 7)));
        assert_eq!(g.turn, 2);
        assert_eq!(g.prof[1].lies, 1);
        // Seat 0 knows its 7 went to seat 1; everybody saw the revealed jack and queen.
        assert_eq!(g.know[0][c(0, 7) as usize], K::With(1, true));
        assert_eq!(g.know[3][c(0, 11) as usize], K::With(1, true));
        assert_eq!(g.know[3][c(0, 7) as usize], K::Unknown);
        assert_eq!(g.know[1][c(0, 7) as usize], K::Mine);
        // When seat 1 plays, that knowledge becomes "maybe played".
        g.apply(2, Act::Lead(9, vec![c(2, 9)]), String::new()).unwrap();
        g.apply(3, Act::Pass, String::new()).unwrap();
        g.apply(0, Act::Pass, String::new()).unwrap();
        g.apply(1, Act::Play(vec![c(0, 7)]), String::new()).unwrap();
        assert_eq!(g.know[0][c(0, 7) as usize], K::With(1, false));
    }

    #[test]
    fn all_pass_burns_the_pile() {
        let mut g = custom(
            [vec![c(0, 7), c(0, 9)], vec![c(1, 9), c(1, 10)], vec![c(2, 9), c(2, 10)], vec![c(3, 9), c(3, 10)]],
            0,
        );
        g.apply(0, Act::Lead(7, vec![c(0, 7)]), String::new()).unwrap();
        for s in 1..4 {
            g.apply(s, Act::Pass, String::new()).unwrap();
        }
        assert!(g.pile.is_empty() && g.rank.is_none());
        assert_eq!(g.burned, vec![c(0, 7)]);
        assert_eq!(g.turn, 0);
        assert_eq!(g.know[0][c(0, 7) as usize], K::Gone);
        assert!(!g.over());
    }

    #[test]
    fn pass_keeps_last_play_open_to_the_next_seat() {
        let mut g = custom(
            [vec![c(0, 7), c(0, 9)], vec![c(1, 9), c(1, 10)], vec![c(2, 9), c(2, 10)], vec![c(3, 9), c(3, 10)]],
            0,
        );
        g.apply(0, Act::Lead(7, vec![c(0, 9)]), String::new()).unwrap();
        g.apply(1, Act::Pass, String::new()).unwrap();
        g.apply(2, Act::Challenge, String::new()).unwrap();
        let rv = g.last.as_ref().unwrap().reveal.clone().unwrap();
        assert!(rv.lie && rv.taker == 0 && rv.leader == 2);
    }

    #[test]
    fn winning_requires_surviving_the_last_play() {
        // Truthful last cards: everyone passes → win.
        let base = || {
            custom(
                [vec![c(0, 7), c(1, 7)], vec![c(1, 9), c(1, 10)], vec![c(2, 9), c(2, 10)], vec![c(3, 9), c(3, 10)]],
                0,
            )
        };
        let mut g = base();
        g.apply(0, Act::Lead(7, vec![c(0, 7), c(1, 7)]), String::new()).unwrap();
        assert!(g.final_play());
        assert!(g.apply(1, Act::Play(vec![c(1, 9)]), String::new()).is_err(), "no playing on a final play");
        for s in 1..4 {
            assert!(!g.over());
            g.apply(s, Act::Pass, String::new()).unwrap();
        }
        assert_eq!(g.winner, Some(0));

        // Truthful last cards, challenged → challenger takes the pile, player still wins.
        let mut g = base();
        g.apply(0, Act::Lead(7, vec![c(0, 7), c(1, 7)]), String::new()).unwrap();
        g.apply(1, Act::Pass, String::new()).unwrap();
        g.apply(2, Act::Challenge, String::new()).unwrap();
        assert_eq!(g.winner, Some(0));
        assert_eq!(g.hands[2].len(), 4);

        // A lie on the last cards, challenged → the liar takes the pile and plays on.
        let mut g = custom(
            [vec![c(0, 7), c(1, 8)], vec![c(1, 9), c(1, 10)], vec![c(2, 9), c(2, 10)], vec![c(3, 9), c(3, 10)]],
            0,
        );
        g.apply(0, Act::Lead(7, vec![c(0, 7), c(1, 8)]), String::new()).unwrap();
        g.apply(1, Act::Challenge, String::new()).unwrap();
        assert!(g.winner.is_none());
        assert_eq!(g.hands[0].len(), 2);
        assert_eq!(g.turn, 1);

        // A lie on the last cards nobody challenges still wins.
        let mut g = custom(
            [vec![c(0, 7), c(1, 8)], vec![c(1, 9), c(1, 10)], vec![c(2, 9), c(2, 10)], vec![c(3, 9), c(3, 10)]],
            0,
        );
        g.apply(0, Act::Lead(7, vec![c(0, 7), c(1, 8)]), String::new()).unwrap();
        for s in 1..4 {
            g.apply(s, Act::Pass, String::new()).unwrap();
        }
        assert_eq!(g.winner, Some(0));
    }

    #[test]
    fn illegal_actions_rejected_unchanged() {
        let mut s = Blof::new(42, Brain::Normal);
        // Make it the player's turn to lead.
        while s.g.turn != 0 {
            s.act(&json!({"ai": true})).unwrap();
        }
        // If the player must follow, test following errors after a lead; first the lead errors.
        let lead_phase = s.g.rank.is_none();
        let before = s.state();
        let hand0 = s.g.hands[0].clone();
        let not_mine = (0..52u8).find(|x| !hand0.contains(x)).unwrap();
        let mine = hand0[0];
        let bad: Vec<Value> = vec![
            json!({"play": [[suit_of(not_mine), rank_of(not_mine)]], "rank": 5}),
            json!({"play": [], "rank": 5}),
            json!({"play": [[suit_of(mine), rank_of(mine)], [suit_of(mine), rank_of(mine)]], "rank": 5}),
            json!({"play": hand0.iter().take(5).map(|&x| json!([suit_of(x), rank_of(x)])).collect::<Vec<_>>(), "rank": 5}),
            json!({"play": [[9, 3]], "rank": 5}),
            json!({"ai": true}),
            json!({"foo": 1}),
        ];
        for a in &bad {
            assert!(s.act(a).is_err(), "{a} should be rejected");
            assert_eq!(s.state(), before, "{a} changed the state");
        }
        if lead_phase {
            for a in [json!({"challenge": true}), json!({"pass": true}), json!({"play": [[suit_of(mine), rank_of(mine)]]})] {
                assert!(s.act(&a).is_err(), "{a}");
                assert_eq!(s.state(), before);
            }
            if let Some(&dr) = s.g.dead.iter().enumerate().find(|(_, &d)| d).map(|(r, _)| r).as_ref() {
                let a = json!({"play": [[suit_of(mine), rank_of(mine)]], "rank": dr});
                assert!(s.act(&a).is_err());
            }
            let r = (2..=14u8).find(|&r| !s.g.dead[r as usize]).unwrap();
            s.act(&json!({"play": [[suit_of(mine), rank_of(mine)]], "rank": r})).unwrap();
            // Now it's not the player's turn.
            let before = s.state();
            for a in [json!({"challenge": true}), json!({"pass": true}), json!({"hint": true})] {
                assert!(s.act(&a).is_err());
                assert_eq!(s.state(), before);
            }
        } else {
            let cur = s.g.rank.unwrap();
            let other = (2..=14u8).find(|&r| r != cur).unwrap();
            let a = json!({"play": [[suit_of(mine), rank_of(mine)]], "rank": other});
            assert!(s.act(&a).is_err());
            assert_eq!(s.state(), before);
        }
        // Game over: everything rejected.
        let mut s = Blof::new(43, Brain::Easy);
        s.g.winner = Some(1);
        let before = s.state();
        for a in [json!({"ai": true}), json!({"pass": true}), json!({"challenge": true}), json!({"hint": true})] {
            assert!(s.act(&a).is_err());
            assert_eq!(s.state(), before);
        }
        assert_eq!(before["status"], "lost");
    }

    #[test]
    fn session_protocol_and_hint() {
        for mode in ["easy", "normal", "hard", "impossible"] {
            assert!(create(1, mode).is_ok());
        }
        assert!(create(1, "nope").is_err());
        let mut s = Blof::new(7, Brain::Hard);
        let mut steps = 0;
        while !s.g.over() && steps < 3000 {
            steps += 1;
            let st = s.state();
            if st["ai_pending"] == true {
                assert_eq!(st["turn"], "ai");
                s.act(&json!({"ai": true})).unwrap();
                assert!(s.state()["event"]["reason"].as_str().is_some_and(|r| !r.is_empty()), "AI reason");
                continue;
            }
            // Player: follow the hint.
            s.act(&json!({"hint": true})).unwrap();
            let h = s.state()["hint"].clone();
            assert!(h["text"].as_str().is_some_and(|t| !t.is_empty()));
            let a = match h["kind"].as_str().unwrap() {
                "lead" => json!({"play": h["cards"], "rank": h["rank"]}),
                "play" => json!({"play": h["cards"]}),
                "challenge" => json!({"challenge": true}),
                _ => json!({"pass": true}),
            };
            s.act(&a).unwrap();
        }
        assert!(s.g.over());
        let st = s.state();
        assert!(st["summary"].is_string());
        if st["status"] == "won" {
            assert_eq!(st["stars"], 1);
        }
    }

    #[test]
    fn ai_matches_terminate() {
        let combos = [
            [Brain::Easy; 4],
            [Brain::Normal; 4],
            [Brain::Hard; 4],
            [Brain::Impossible; 4],
            [Brain::Hard, Brain::Impossible, Brain::Impossible, Brain::Impossible],
            [Brain::Easy, Brain::Normal, Brain::Hard, Brain::Impossible],
        ];
        let mut longest = 0;
        for brains in combos {
            for seed in 0..60 {
                let g = run(all_ai(seed, brains));
                assert!(!g.draw, "{brains:?} seed {seed} drew");
                assert!(g.winner.is_some());
                assert_eq!(total_cards(&g), 52);
                longest = longest.max(g.actions);
            }
        }
        assert!(longest < 1000, "longest match {longest} actions");
    }

    #[test]
    fn impossible_never_challenges_a_truth_and_catches_lies() {
        let mut challenges = 0;
        for seed in 0..120 {
            let brains = match seed % 3 {
                0 => [Brain::Impossible, Brain::Easy, Brain::Normal, Brain::Hard],
                1 => [Brain::Easy, Brain::Impossible, Brain::Hard, Brain::Impossible],
                _ => [Brain::Impossible; 4],
            };
            let mut g = all_ai(seed, brains);
            while !g.over() {
                let seat = g.turn;
                let d = g.decide(seat);
                if brains[seat] == Brain::Impossible {
                    let last = g.pile.last();
                    let lie = last.is_some_and(|p| p.cards.iter().any(|&x| rank_of(x) != p.rank));
                    if d.act == Act::Challenge {
                        assert!(lie, "seed {seed}: impossible challenged a truth");
                        challenges += 1;
                    } else if lie {
                        panic!("seed {seed}: impossible let a lie pass");
                    }
                }
                g.apply(seat, d.act, d.reason).unwrap();
            }
        }
        assert!(challenges > 50, "impossible challenged {challenges} times");
    }

    #[test]
    fn hard_beats_easy() {
        let (mut hard, mut easy) = (0, 0);
        for seed in 0..300 {
            let brains = if seed % 2 == 0 {
                [Brain::Hard, Brain::Easy, Brain::Hard, Brain::Easy]
            } else {
                [Brain::Easy, Brain::Hard, Brain::Easy, Brain::Hard]
            };
            let g = run(all_ai(1000 + seed, brains));
            match brains[g.winner.unwrap()] {
                Brain::Hard => hard += 1,
                _ => easy += 1,
            }
        }
        eprintln!("hard {hard} : easy {easy}");
        assert!(hard as f64 > 0.65 * (hard + easy) as f64, "hard {hard} vs easy {easy}");
    }

    #[test]
    fn normal_beats_easy_and_impossible_beats_hard() {
        let duel = |a: Brain, b: Brain| {
            let (mut wa, mut wb) = (0, 0);
            for seed in 0..200u64 {
                let brains = if seed % 2 == 0 { [a, b, a, b] } else { [b, a, b, a] };
                let g = run(all_ai(5000 + seed, brains));
                if brains[g.winner.unwrap()] == a {
                    wa += 1;
                } else {
                    wb += 1;
                }
            }
            (wa, wb)
        };
        let (n, e) = duel(Brain::Normal, Brain::Easy);
        eprintln!("normal {n} : easy {e}");
        assert!(n > e);
        let (i, h) = duel(Brain::Impossible, Brain::Hard);
        eprintln!("impossible {i} : hard {h}");
        assert!(i > h);
    }

    #[test]
    fn certain_lie_is_detected_from_own_hand() {
        let mut g = custom(
            [
                vec![c(0, 9), c(1, 9), c(0, 5)],
                vec![c(0, 7), c(1, 7), c(0, 8), c(0, 10)],
                vec![c(2, 9), c(2, 10), c(2, 11)],
                vec![c(3, 3), c(3, 10), c(1, 11)],
            ],
            3,
        );
        g.brains = [Brain::Normal, Brain::Easy, Brain::Hard, Brain::Easy];
        // Seat 3 claims three 9s while seat 0 holds two and seat 2 holds one.
        g.apply(3, Act::Lead(9, vec![c(3, 3), c(3, 10), c(1, 11)]), String::new()).unwrap();
        let d = g.decide(0);
        assert_eq!(d.act, Act::Challenge);
        assert!(d.reason.contains("Blöf"), "{}", d.reason);
        let info = g.info(0);
        let e = eval_last(&info).unwrap();
        assert!(e.certain);
        assert_eq!(e.max_possible, 2);
    }

    #[test]
    fn hypergeometric_sanity() {
        let total: f64 = (0..=4).map(|x| hyper_pmf(52, 4, 13, x)).sum();
        assert!((total - 1.0).abs() < 1e-9);
        assert!((hyper_pmf(52, 4, 13, 0) - choose(48, 13) / choose(52, 13)).abs() < 1e-12);
        assert_eq!(hyper_pmf(10, 2, 3, 3), 0.0);
        let mid = hyper_pmf_f(39, 2.5, 13, 0);
        assert!(mid < hyper_pmf(39, 2, 13, 0) && mid > hyper_pmf(39, 3, 13, 0));
        // A claim of three from a seat we know nothing about is far likelier a lie than a claim of one.
        let mut g = all_ai(3, [Brain::Hard; 4]);
        g.turn = 1;
        g.rank = None;
        let info = g.info(0);
        let one = eval_claim(&info, 1, 1, 9, 13, &[(2, 1, 9)]);
        let three = eval_claim(&info, 1, 3, 9, 13, &[(2, 1, 9)]);
        assert!(three.p_lie > one.p_lie + 0.2, "{} vs {}", three.p_lie, one.p_lie);
    }

    #[test]
    #[ignore]
    fn diagnostics() {
        let pairs = [(Brain::Hard, Brain::Easy), (Brain::Normal, Brain::Easy), (Brain::Hard, Brain::Normal), (Brain::Impossible, Brain::Hard)];
        for (a, b) in pairs {
            let (mut wa, mut wb) = (0, 0);
            let mut st = [[0u64; 8]; 2]; // per brain: plays, lies(rev), reveals, challenges, wrong, taken cards, passes, lies played
            for seed in 0..400u64 {
                let brains = if seed % 2 == 0 { [a, b, a, b] } else { [b, a, b, a] };
                let mut g = all_ai(9000 + seed, brains);
                while !g.over() {
                    let seat = g.turn;
                    let d = g.decide(seat);
                    let side = if brains[seat] == a { 0 } else { 1 };
                    match &d.act {
                        Act::Pass => st[side][6] += 1,
                        Act::Lead(r, cs) => { if cs.iter().any(|&x| rank_of(x) != *r) { st[side][7] += 1 } }
                        Act::Play(cs) => { let r = g.rank.unwrap(); if cs.iter().any(|&x| rank_of(x) != r) { st[side][7] += 1 } }
                        _ => {}
                    }
                    g.apply(seat, d.act, d.reason).unwrap();
                    if let Some(rv) = g.last.as_ref().and_then(|e| e.reveal.clone()) {
                        if g.last.as_ref().unwrap().seat == seat && g.last.as_ref().unwrap().kind == "challenge" {
                            let ts = if brains[rv.taker] == a { 0 } else { 1 };
                            st[ts][5] += rv.count as u64;
                        }
                    }
                }
                for s2 in 0..4 {
                    let side = if brains[s2] == a { 0 } else { 1 };
                    let p = g.prof[s2];
                    st[side][0] += p.plays as u64; st[side][1] += p.lies as u64; st[side][2] += p.reveals as u64;
                    st[side][3] += p.challenges as u64; st[side][4] += p.wrong as u64;
                }
                if brains[g.winner.unwrap()] == a { wa += 1 } else { wb += 1 }
            }
            eprintln!("{a:?} {wa} : {b:?} {wb}");
            for (i, n) in [(0, a), (1, b)] {
                let x = st[i];
                eprintln!("  {n:?}: plays {} liesPlayed {} caught {}/{} rev · challenges {} wrong {} · taken {} · passes {}", x[0], x[7], x[1], x[2], x[3], x[4], x[5], x[6]);
            }
        }
    }

    #[test]
    #[ignore]
    fn calibration() {
        let mut b = [[0u64; 2]; 10];
        let mut cert = [0u64; 2];
        for seed in 0..300u64 {
            let brains = if seed % 2 == 0 { [Brain::Hard, Brain::Easy, Brain::Hard, Brain::Easy] } else { [Brain::Hard, Brain::Normal, Brain::Hard, Brain::Normal] };
            let mut g = all_ai(seed, brains);
            while !g.over() {
                let seat = g.turn;
                if g.rank.is_some() {
                    let info = g.info(seat);
                    if let Some(e) = eval_last(&info) {
                        let last = g.pile.last().unwrap();
                        let lie = last.cards.iter().any(|&x| rank_of(x) != last.rank) as usize;
                        if e.certain { cert[lie] += 1 } else {
                            let i = ((e.p_lie * 10.0) as usize).min(9);
                            b[i][lie] += 1;
                        }
                    }
                }
                let d = g.decide(seat);
                g.apply(seat, d.act, d.reason).unwrap();
            }
        }
        for (i, x) in b.iter().enumerate() {
            let n = x[0] + x[1];
            if n > 0 { eprintln!("p_lie {:.1}-{:.1}: n {n} actual {:.2}", i as f64 / 10.0, (i + 1) as f64 / 10.0, x[1] as f64 / n as f64); }
        }
        eprintln!("certain: truth {} lie {}", cert[0], cert[1]);
    }

    #[test]
    #[ignore]
    fn sample_log() {
        for b in [Brain::Easy, Brain::Normal, Brain::Hard, Brain::Impossible] {
            let mut s = Blof::new(11, b);
            let mut n = 0;
            while !s.g.over() && n < 40 {
                n += 1;
                if s.g.turn == 0 {
                    s.act(&json!({"hint": true})).unwrap();
                    let h = s.state()["hint"].clone();
                    eprintln!("  HINT {}", h["text"]);
                    if let Some(o) = s.state()["odds"].as_object() { eprintln!("  ODDS {}", o["text"]); }
                    let a = match h["kind"].as_str().unwrap() {
                        "lead" => json!({"play": h["cards"], "rank": h["rank"]}),
                        "play" => json!({"play": h["cards"]}),
                        "challenge" => json!({"challenge": true}),
                        _ => json!({"pass": true}),
                    };
                    s.act(&a).unwrap();
                } else {
                    s.act(&json!({"ai": true})).unwrap();
                }
                let e = s.state()["event"].clone();
                eprintln!("{:?} {} {}: {} — {}", b, e["seat"], e["kind"], e["text"], e["reason"]);
            }
        }
    }

    #[test]
    #[ignore]
    fn timing_per_action() {
        for b in [Brain::Easy, Brain::Normal, Brain::Hard, Brain::Impossible] {
            let (mut n, mut total, mut worst, mut acts) = (0, 0.0f64, 0.0f64, 0u64);
            for seed in 0..100 {
                let mut g = all_ai(seed, [b; 4]);
                while !g.over() {
                    let t = std::time::Instant::now();
                    let seat = g.turn;
                    let d = g.decide(seat);
                    let ms = t.elapsed().as_secs_f64() * 1000.0;
                    total += ms;
                    worst = worst.max(ms);
                    n += 1;
                    g.apply(seat, d.act, d.reason).unwrap();
                }
                acts += g.actions as u64;
            }
            eprintln!(
                "{:?}: {n} decisions · avg {:.3} ms · worst {:.3} ms · avg match {:.0} actions",
                b,
                total / n as f64,
                worst,
                acts as f64 / 100.0
            );
        }
    }
}
