//! Batak (İhaleli Batak) — four players, each for themselves; the owner is South (seat 0) against
//! three AI opponents (West = 1 Kerem, North = 2 Selin, East = 3 Murat). Play goes clockwise:
//! S → W → N → E.
//!
//! ## Rules
//! - 52 cards, 13 each. The dealer rotates clockwise every hand (the first dealer is random).
//! - **İhale** (bidding), clockwise from the dealer's left: bid a number of tricks `4..=13` higher
//!   than the current high bid, or pass (a pass is final). Bidding ends when everyone but the high
//!   bidder has passed, or at once on a bid of 13. If the first three players pass, the dealer must
//!   bid (at least 4) — no redeal.
//! - The high bidder (declarer, "ihaleci") names the trump suit (koz) and leads the first trick.
//! - Play: follow suit if you can. **Yükseltme**: if the trick is not trumped you must beat the
//!   highest card of the led suit when you can. Void in the led suit: you must trump if you hold a
//!   trump, and over-trump the highest trump already on the table when you can (otherwise any
//!   trump). Void with no trump: discard anything. A trump can't be **led** until trumps are broken
//!   (someone has played a trump) unless the leader holds nothing but trumps. The highest trump, or
//!   the highest card of the led suit, wins; the winner leads next.
//!
//! ## Scoring (per hand) and match
//! - Declarer who takes at least the bid: **+ tricks taken** (overtricks count — the common club
//!   rule). Fewer: **− bid** ("batma"). Every other player: + tricks taken.
//! - A match ends after the hand in which somebody reaches **51 points**, or after **10 hands**.
//!   Highest total wins: `won` if you are alone on top, `draw` if you share the top, else `lost`.
//!   Stars on a win: 3 = no hint and a lead of ≥ 10 points, 2 = no hint, 1 = hint used.
//!
//! ## AI (table modes `easy | normal | hard | impossible`)
//! - Information-set separation is structural: easy/normal/hard decide from an [`Info`] (own hand,
//!   public plays, bids, and the voids / "can't hold higher than" ceilings deduced from the rules),
//!   built by [`Batak::info_for`]. Only impossible gets an [`Omni`] with every hand.
//! - **easy**: the normal heuristics on a *forgetful* info set (no card counting, no void
//!   tracking), noisy hand evaluation, and ~12 % careless plays.
//! - **normal**: heuristics with full card counting: draws trumps with the boss trump, cashes boss
//!   cards that nobody can ruff, builds voids as declarer, wins cheaply in last seat, takes a trick
//!   in second/third seat only with a card no one behind can beat; hand-evaluation bidding.
//! - **hard**: Monte-Carlo determinization: samples hidden hands consistent with every inference
//!   (voids, ceilings, declarer's trump length), solves each world with the double-dummy solver
//!   and picks the card with the best average of (own tricks + weighted make/set chance). Bidding
//!   and trump choice by double-dummy evaluation of sampled deals.
//! - **impossible**: sees every hand and plays exact double-dummy: the declarer maximises its
//!   guaranteed tricks against a coalition of the other three; a defender first keeps the
//!   declarer below the bid whenever possible, then maximises its own guaranteed tricks. Bidding is
//!   perfect-information: it knows exactly how many tricks each trump would give it.
//!
//! ## Double-dummy solver
//! Two-sided (one seat vs. the other three) null-window alpha-beta over single cards with a
//! transposition table at trick boundaries (lower/upper bounds on tricks from here), equivalence of
//! touching cards (cards with no live card of another hand between them are one move), move
//! ordering (cheap winners / low cards when a team mate wins / bosses on lead), a quick-tricks
//! lower bound and an exact last-trick shortcut. Exact values by MTD(f)-style null-window probes.
//! A node budget caps every decision; if it runs out the AI falls back to the normal heuristics.
//! Hard's Monte-Carlo uses fewer, deeper worlds while the deal is big (one exact root solve plus
//! one probe per candidate) and many cheap exact worlds later, under a total node budget.
//!
//! Measured (M-series Mac, release, `batak_timing`, 4 AI seats, 12 hands): impossible avg 3 ms,
//! worst ≈ 170 ms per decision (1 budget fallback in 700 decisions); hard avg 23 ms, worst
//! ≈ 140 ms. Strength in duplicate play (same 100 deals, South vs three easy, South points):
//! easy 236 · normal 287 · hard 315 · impossible 355. A hard-strength South at the impossible
//! table won 1 of 12 full matches.
//!
//! ## State
//! `{status, stars, title, goal, summary, mode, seed, phase: "bid"|"trump"|"play"|"summary",
//!   hand_no, max_hands, target, dealer, names, hands: [4 × [[suit,rank]…]], counts, bids: [null |
//!   0 pass | n], passed, high_bid, high_seat, bid_options, can_pass, declarer, contract, trump,
//!   trump_broken, turn: "you"|"ai", seat, ai_pending, legal: [[s,r]…], trick: {leader, cards:
//!   [{seat, card}]}, last_trick: {no, leader, winner, cards} | null, trick_no, tricks, scores,
//!   last_action: {serial, seat, kind: "bid"|"pass"|"trump"|"play"|"deal", bid, trump, card,
//!   reason, trick_winner} | null, reasons: [4 × str|null], serial, hint: {kind, bid, trump, card,
//!   text} | null, hand_result: {declarer, contract, trump, made, tricks, deltas, batanlar} | null,
//!   sheet: [{hand, declarer, contract, trump, made, tricks, deltas, totals}], match_over,
//!   used_hint}`
//! Actions: `{"bid":n}` (`0` = pass) · `{"trump":s}` · `{"play":[suit,rank]}` · `{"ai":true}`
//! (one AI action for the seat on turn) · `{"hint":true}` · `{"next":true}` (deal the next hand
//! from the summary).

use crate::rng::{time_seed, Rng};
use crate::Session;
use serde_json::{json, Value};

pub const TARGET: i32 = 51;
pub const MAX_HANDS: u32 = 10;
pub const NAMES: [&str; 4] = ["Sen", "Kerem", "Selin", "Murat"];
const SUIT_TR: [&str; 4] = ["Maça", "Kupa", "Karo", "Sinek"];

const FULL: u64 = (1u64 << 52) - 1;
const SM: [u64; 4] = [0x1FFF, 0x1FFF << 13, 0x1FFF << 26, 0x1FFF << 39];

/// Card = suit * 13 + (rank − 2); suits 0 maça, 1 kupa, 2 karo, 3 sinek; ranks 2..=14 (14 = As).
pub type Card = u8;

#[inline]
fn suit(c: Card) -> usize {
    (c / 13) as usize
}
#[inline]
fn rank(c: Card) -> u8 {
    c % 13 + 2
}
#[inline]
fn bit(c: Card) -> u64 {
    1u64 << c
}
#[inline]
fn card(s: usize, r: u8) -> Card {
    s as u8 * 13 + (r - 2)
}
/// Cards of the same suit strictly higher than `c`.
#[inline]
fn above(c: Card) -> u64 {
    SM[suit(c)] & !((2u64 << c) - 1)
}
/// Cards of the same suit strictly lower than `c`.
#[inline]
fn below(c: Card) -> u64 {
    SM[suit(c)] & ((1u64 << c) - 1)
}
#[inline]
fn hi(m: u64) -> Card {
    (63 - m.leading_zeros()) as Card
}
#[inline]
fn lo(m: u64) -> Card {
    m.trailing_zeros() as Card
}
#[inline]
fn cnt(m: u64) -> u32 {
    m.count_ones()
}

fn bits(mut m: u64) -> impl Iterator<Item = Card> {
    std::iter::from_fn(move || {
        if m == 0 {
            None
        } else {
            let c = lo(m);
            m &= m - 1;
            Some(c)
        }
    })
}

fn rank_tr(r: u8) -> String {
    match r {
        14 => "As".into(),
        13 => "Papaz".into(),
        12 => "Kız".into(),
        11 => "Vale".into(),
        _ => r.to_string(),
    }
}

/// Turkish card name, e.g. "Kupa Papaz", "Maça 7".
pub fn card_name(c: Card) -> String {
    format!("{} {}", SUIT_TR[suit(c)], rank_tr(rank(c)))
}

fn cj(c: Card) -> Value {
    json!([suit(c), rank(c)])
}

/// One decimal with a Turkish comma.
fn dec(x: f64) -> String {
    format!("{x:.1}").replace('.', ",")
}

fn pct(x: f64) -> String {
    format!("%{}", (x * 100.0).round() as i32)
}

// =================================================================================================
// Rules

#[inline]
fn beats(a: Card, b: Card, trump: usize) -> bool {
    if suit(a) == suit(b) {
        a > b
    } else {
        suit(a) == trump
    }
}

fn winner_idx(t: &[Card], trump: usize) -> usize {
    let mut w = 0;
    for i in 1..t.len() {
        if beats(t[i], t[w], trump) {
            w = i;
        }
    }
    w
}

#[inline]
fn lead_mask(hand: u64, trump: usize, broken: bool) -> u64 {
    let non = hand & !SM[trump];
    if !broken && non != 0 {
        non
    } else {
        hand
    }
}

#[inline]
fn follow_mask(hand: u64, lead: usize, win: Card, trump: usize) -> u64 {
    let hs = hand & SM[lead];
    if hs != 0 {
        if suit(win) != lead {
            return hs; // trick already trumped: any card of the led suit
        }
        let h = hs & above(win);
        return if h != 0 { h } else { hs };
    }
    let ht = hand & SM[trump];
    if ht != 0 {
        if suit(win) == trump {
            let h = ht & above(win);
            if h != 0 {
                return h;
            }
        }
        return ht;
    }
    hand
}

/// Legal cards for `hand` given the cards already on the table (in play order).
pub fn legal_mask(hand: u64, trick: &[Card], trump: usize, broken: bool) -> u64 {
    if trick.is_empty() {
        lead_mask(hand, trump, broken)
    } else {
        follow_mask(hand, suit(trick[0]), trick[winner_idx(trick, trump)], trump)
    }
}

fn illegal_reason(hand: u64, trick: &[Card], trump: usize, c: Card) -> String {
    if trick.is_empty() {
        return "Koz kırılmadan koz açamazsın".into();
    }
    let lead = suit(trick[0]);
    if hand & SM[lead] != 0 && suit(c) != lead {
        return format!("{} rengine uymalısın", SUIT_TR[lead]);
    }
    if suit(c) == lead {
        return "Yükseltmek zorundasın: masadakini geçen kartın var".into();
    }
    if hand & SM[trump] != 0 && suit(c) != trump {
        return "Bu renk sende yok: kozla kesmek zorundasın".into();
    }
    "Masadaki kozu geçmek zorundasın".into()
}

/// What the play of `c` by `seat` (onto `before`) reveals to everybody.
fn infer(cannot: &mut [u64; 4], seat: usize, c: Card, before: &[Card], trump: usize, broken: bool) {
    if before.is_empty() {
        if suit(c) == trump && !broken {
            cannot[seat] |= FULL & !SM[trump]; // led trump unbroken → only trumps left
        }
        return;
    }
    let lead = suit(before[0]);
    let w = before[winner_idx(before, trump)];
    if suit(c) == lead {
        if suit(w) == lead && c < w {
            cannot[seat] |= above(w); // could not beat
        }
    } else {
        cannot[seat] |= SM[lead];
        if suit(c) == trump {
            if suit(w) == trump && c < w {
                cannot[seat] |= above(w); // could not over-trump
            }
        } else {
            cannot[seat] |= SM[trump];
        }
    }
}

// =================================================================================================
// Double-dummy solver

#[inline]
const fn splitmix(x: u64) -> u64 {
    let mut z = x.wrapping_add(0x9E37_79B9_7F4A_7C15);
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

/// Transposition table: bounds on "tricks for `me` from this trick on" at trick boundaries,
/// keyed by the rank-canonical position (see [`Dd::key`]). Two-way buckets: slot 0 keeps the
/// entry with more tricks left, slot 1 is always replaced.
pub struct Tt {
    key: Vec<u64>,
    lb: Vec<u8>,
    ub: Vec<u8>,
    dep: Vec<u8>,
    mask: usize,
}

impl Tt {
    pub fn new(bits: u32) -> Tt {
        let n = 1usize << bits;
        Tt { key: vec![0; n], lb: vec![0; n], ub: vec![0; n], dep: vec![0; n], mask: (n - 1) & !1 }
    }
    #[inline]
    fn get(&self, k: u64) -> Option<(i32, i32)> {
        let i = k as usize & self.mask;
        if self.key[i] == k {
            return Some((self.lb[i] as i32, self.ub[i] as i32));
        }
        if self.key[i + 1] == k {
            return Some((self.lb[i + 1] as i32, self.ub[i + 1] as i32));
        }
        None
    }
    #[inline]
    fn put(&mut self, k: u64, lb: i32, ub: i32, dep: i32) {
        let i = k as usize & self.mask;
        let j = if self.key[i] == k {
            i
        } else if self.key[i + 1] == k {
            i + 1
        } else if dep as u8 >= self.dep[i] {
            self.key[i + 1] = self.key[i];
            self.lb[i + 1] = self.lb[i];
            self.ub[i + 1] = self.ub[i];
            self.dep[i + 1] = self.dep[i];
            i
        } else {
            i + 1
        };
        self.key[j] = k;
        self.lb[j] = lb as u8;
        self.ub[j] = ub as u8;
        self.dep[j] = dep as u8;
    }
}

/// A double-dummy position: remaining hands and the trick in progress.
#[derive(Clone, Copy, Debug)]
struct P {
    h: [u64; 4],
    leader: u8,
    n: u8,
    t: [Card; 4],
    win: u8,
    broken: bool,
}

impl P {
    fn new(h: [u64; 4], leader: usize, trick: &[Card], broken: bool, trump: usize) -> P {
        let mut t = [0; 4];
        t[..trick.len()].copy_from_slice(trick);
        let win = if trick.is_empty() { 0 } else { winner_idx(trick, trump) as u8 };
        P { h, leader: leader as u8, n: trick.len() as u8, t, win, broken }
    }
    #[inline]
    fn who(&self) -> usize {
        (self.leader + self.n) as usize & 3
    }
    #[inline]
    fn legal(&self, trump: usize) -> u64 {
        let h = self.h[self.who()];
        if self.n == 0 {
            lead_mask(h, trump, self.broken)
        } else {
            follow_mask(h, suit(self.t[0]), self.t[self.win as usize], trump)
        }
    }
    #[inline]
    fn live(&self) -> u64 {
        let mut l = self.h[0] | self.h[1] | self.h[2] | self.h[3];
        for i in 0..self.n as usize {
            l |= bit(self.t[i]);
        }
        l
    }
    /// Play `c` for the seat on turn; returns the new position and the trick winner if it closed.
    #[inline]
    fn play(&self, c: Card, trump: usize) -> (P, Option<usize>) {
        let who = self.who();
        let mut q = *self;
        q.h[who] &= !bit(c);
        if suit(c) == trump {
            q.broken = true;
        }
        let n = q.n as usize;
        q.t[n] = c;
        if n == 0 || beats(c, q.t[q.win as usize], trump) {
            q.win = n as u8;
        }
        q.n += 1;
        if q.n == 4 {
            let w = (q.leader + q.win) as usize & 3;
            q.leader = w as u8;
            q.n = 0;
            q.win = 0;
            return (q, Some(w));
        }
        (q, None)
    }
}

/// Keep one card per run of touching cards (no live card of another hand in between): the top.
#[inline]
fn reps_top(legal: u64, live: u64) -> u64 {
    let mut out = 0;
    for c in bits(legal) {
        let up = live & above(c);
        if up != 0 && legal & bit(lo(up)) != 0 {
            continue;
        }
        out |= bit(c);
    }
    out
}

/// The lowest card of the touching run whose top is `c`.
fn run_low(c: Card, legal: u64, live: u64) -> Card {
    let mut c = c;
    loop {
        let dn = live & below(c);
        if dn == 0 {
            return c;
        }
        let nx = hi(dn);
        if legal & bit(nx) == 0 {
            return c;
        }
        c = nx;
    }
}

struct Dd<'a> {
    trump: usize,
    me: usize,
    tt: &'a mut Tt,
    nodes: u64,
    budget: u64,
    abort: bool,
}

impl<'a> Dd<'a> {
    fn new(tt: &'a mut Tt, trump: usize, me: usize, budget: u64) -> Self {
        Dd { trump, me, tt, nodes: 0, budget, abort: false }
    }

    /// Rank-canonical key at a trick boundary: per suit, the owners of the remaining cards from
    /// high to low (only relative ranks matter once a trick is closed), plus leader, trump broken,
    /// the maximising seat and the trump suit.
    #[inline]
    fn key(&self, p: &P) -> u64 {
        let mut k = 0x5EED_BA7A_u64 ^ ((p.leader as u64) << 2 | (p.broken as u64) << 4 | (self.me as u64) << 5 | (self.trump as u64) << 7);
        for s in 0..4 {
            let sh = 13 * s;
            let m1 = (p.h[1] >> sh) as u32 & 0x1FFF;
            let m2 = (p.h[2] >> sh) as u32 & 0x1FFF;
            let m3 = (p.h[3] >> sh) as u32 & 0x1FFF;
            let mut l = ((p.h[0] >> sh) as u32 & 0x1FFF) | m1 | m2 | m3;
            let mut code: u64 = l.count_ones() as u64;
            while l != 0 {
                let b = 31 - l.leading_zeros();
                let owner = ((m1 >> b) & 1) | (((m2 >> b) & 1) << 1) | (((m3 >> b) & 1) * 3);
                code = code << 2 | owner as u64;
                l &= !(1 << b);
            }
            k = splitmix(k ^ code.wrapping_mul(0x9E37_79B9_7F4A_7C15 ^ s as u64));
        }
        k | 1
    }

    /// Can `me` take at least `target` tricks from `p` on (the trick in progress included)?
    fn search(&mut self, p: &P, target: i32) -> bool {
        if target <= 0 {
            return true;
        }
        let who = p.who();
        let rem = cnt(p.h[who]) as i32;
        if target > rem {
            return false;
        }
        self.nodes += 1;
        if self.nodes > self.budget {
            self.abort = true;
            return false;
        }
        let mut key = 0;
        let (mut lb, mut ub) = (0, rem);
        if p.n == 0 {
            key = self.key(p);
            if let Some((l, u)) = self.tt.get(key) {
                if l >= target {
                    return true;
                }
                if u < target {
                    return false;
                }
                lb = l;
                ub = u;
            }
            if rem == 1 {
                let mut q = *p;
                let mut w = None;
                for _ in 0..4 {
                    let c = lo(q.h[q.who()]);
                    (q, w) = q.play(c, self.trump);
                }
                return w == Some(self.me);
            }
            let (l, u) = self.bounds(p);
            if l >= target {
                self.tt.put(key, l.max(lb), ub, rem);
                return true;
            }
            if u < target {
                self.tt.put(key, lb, u.min(ub), rem);
                return false;
            }
            lb = lb.max(l);
            ub = ub.min(u);
        }
        let legal = p.legal(self.trump);
        let live = p.live();
        let mut mv = [0 as Card; 13];
        let n = self.order(p, who, legal, live, &mut mv);
        let max = who == self.me;
        let mut res = !max;
        for &c in &mv[..n] {
            let (q, w) = p.play(c, self.trump);
            let t2 = if w == Some(self.me) { target - 1 } else { target };
            let r = self.search(&q, t2);
            if self.abort {
                return false;
            }
            if r == max {
                res = max;
                break;
            }
        }
        if p.n == 0 {
            if res {
                lb = lb.max(target);
            } else {
                ub = ub.min(target - 1);
            }
            self.tt.put(key, lb, ub, rem);
        }
        res
    }

    /// Cheap bounds at a trick boundary (tricks for `me` from here).
    ///
    /// Lower: each of my trumps above every other trump wins its trick; on lead I can also cash,
    /// in every side suit, my cards above all enemy cards of that suit — as many rounds as every
    /// trump-holding enemy can still follow (all of them if no enemy holds a trump).
    /// Upper: symmetric for an enemy on lead (his cashable side winners, counting only cards
    /// above everybody's so the lead stays with him, plus his trumps above all mine); otherwise
    /// one enemy's trumps above all of mine (any trump, if I hold none) lie in different tricks
    /// that I can't win.
    #[inline]
    fn bounds(&self, p: &P) -> (i32, i32) {
        let me = self.me;
        let t = self.trump;
        let rem = cnt(p.h[me]) as i32;
        let mut others = 0;
        for s in 0..4 {
            if s != me {
                others |= p.h[s];
            }
        }
        let my_t = p.h[me] & SM[t];
        let opp_t = others & SM[t];
        let top_trumps = if opp_t == 0 { cnt(my_t) } else { cnt(my_t & above(hi(opp_t))) } as i32;
        let leader = p.leader as usize;
        let mut lb = top_trumps;
        if leader == me {
            lb += Self::cashable(p, me, t);
            lb = lb.min(rem);
        }
        let mut lost = 0;
        for s in 0..4 {
            if s == me {
                continue;
            }
            let ot = p.h[s] & SM[t];
            let k = if my_t == 0 { cnt(ot) } else { cnt(ot & above(hi(my_t))) } as i32;
            lost = lost.max(k);
        }
        if leader != me {
            let lt = p.h[leader] & SM[t];
            let k = if my_t == 0 { cnt(lt) } else { cnt(lt & above(hi(my_t))) } as i32;
            lost = lost.max(k + Self::cashable(p, leader, t));
        }
        (lb, rem - lost.min(rem))
    }

    /// Side-suit tricks `who` can cash in a row from the lead: per suit, its cards above every
    /// other player's cards of the suit, limited by how many rounds each other player holding a
    /// trump can follow (beyond that he could ruff).
    #[inline]
    fn cashable(p: &P, who: usize, t: usize) -> i32 {
        let mut q = 0;
        for s in 0..4 {
            if s == t {
                continue;
            }
            let mine = p.h[who] & SM[s];
            if mine == 0 {
                continue;
            }
            let mut oth = 0;
            let mut follow = u32::MAX;
            for o in 0..4 {
                if o == who {
                    continue;
                }
                let os = p.h[o] & SM[s];
                oth |= os;
                if p.h[o] & SM[t] != 0 {
                    follow = follow.min(cnt(os));
                }
            }
            let top = if oth == 0 { cnt(mine) } else { cnt(mine & above(hi(oth))) };
            q += top.min(follow) as i32;
        }
        q
    }

    fn order(&self, p: &P, who: usize, legal: u64, live: u64, out: &mut [Card; 13]) -> usize {
        let reps = reps_top(legal, live);
        let mut sc = [0i32; 13];
        let mut n = 0;
        let max = who == self.me;
        let t = self.trump;
        let (w, ws) = if p.n > 0 {
            (p.t[p.win as usize], (p.leader + p.win) as usize & 3)
        } else {
            (0, 0)
        };
        let enemies: u64 = if max {
            (0..4).filter(|&s| s != self.me).fold(0, |a, s| a | p.h[s])
        } else {
            p.h[self.me]
        };
        for c in bits(reps) {
            let r = rank(c) as i32;
            let s = suit(c);
            let sc_c = if p.n == 0 {
                let top = enemies & above(c) == 0;
                // Can an enemy ruff it?
                let ruff = s != t
                    && if max {
                        (0..4).any(|e| e != self.me && p.h[e] & SM[s] == 0 && p.h[e] & SM[t] != 0)
                    } else {
                        p.h[self.me] & SM[s] == 0 && p.h[self.me] & SM[t] != 0
                    };
                if top && !ruff {
                    70 + r + if s == t { 6 } else { 0 }
                } else if ruff {
                    -r
                } else {
                    30 - r + cnt(p.h[who] & SM[s]) as i32
                }
            } else {
                let friend = (ws == self.me) == max;
                let b = beats(c, w, t);
                if friend {
                    if b {
                        20 - r
                    } else {
                        50 - r
                    }
                } else if b {
                    80 - r
                } else {
                    40 - r
                }
            };
            let mut i = n;
            while i > 0 && sc[i - 1] < sc_c {
                sc[i] = sc[i - 1];
                out[i] = out[i - 1];
                i -= 1;
            }
            sc[i] = sc_c;
            out[i] = c;
            n += 1;
        }
        n
    }

    /// Root probe that also reports the deciding move: for `me` on turn, the first move (in
    /// search order) reaching `target`; for an enemy on turn, the first move that holds `me`
    /// below it. `None` when no single move decides (or the bound was trivial).
    fn root_probe(&mut self, p: &P, target: i32) -> (bool, Option<Card>) {
        let who = p.who();
        let rem = cnt(p.h[who]) as i32;
        if target <= 0 {
            return (true, None);
        }
        if target > rem {
            return (false, None);
        }
        let legal = p.legal(self.trump);
        let mut mv = [0 as Card; 13];
        let n = self.order(p, who, legal, p.live(), &mut mv);
        let max = who == self.me;
        for &c in &mv[..n] {
            let (q, w) = p.play(c, self.trump);
            let t2 = if w == Some(self.me) { target - 1 } else { target };
            let r = self.search(&q, t2);
            if self.abort {
                return (false, None);
            }
            if r == max {
                return (max, Some(c));
            }
        }
        (!max, None)
    }

    /// Exact value at a root where `me` is on turn, plus a move achieving it.
    fn exact_root(&mut self, p: &P, guess: i32) -> Option<(i32, Option<Card>)> {
        let rem = cnt(p.h[p.who()]) as i32;
        let (mut lb, mut ub) = (0, rem);
        let mut best = None;
        let mut g = guess;
        while lb < ub {
            let t = g.clamp(lb + 1, ub);
            let (r, c) = self.root_probe(p, t);
            if self.abort {
                return None;
            }
            if r {
                lb = t;
                best = c;
                g = t + 1;
            } else {
                ub = t - 1;
                g = t - 1;
            }
        }
        Some((lb, best))
    }

    /// The first move in search order (used when every move is worth the same).
    fn first_move(&self, p: &P) -> Card {
        let mut mv = [0 as Card; 13];
        let legal = p.legal(self.trump);
        let n = self.order(p, p.who(), legal, p.live(), &mut mv);
        if n == 0 {
            lo(legal)
        } else {
            mv[0]
        }
    }

    /// Exact tricks for `me` from `p` (None if the node budget ran out).
    fn exact(&mut self, p: &P, guess: i32) -> Option<i32> {
        let rem = cnt(p.h[p.who()]) as i32;
        let (mut lb, mut ub) = (0, rem);
        let mut g = guess;
        while lb < ub {
            let t = g.clamp(lb + 1, ub);
            let r = self.search(p, t);
            if self.abort {
                return None;
            }
            if r {
                lb = t;
                g = t + 1;
            } else {
                ub = t - 1;
                g = t - 1;
            }
        }
        Some(lb)
    }
}

/// Node budgets (deterministic, not wall time). Impossible: per decision; hard: per sampled world.
const OMNI_BUDGET: u64 = 6_000_000;
/// Hard: total nodes per decision across all sampled worlds.
const MC_DECISION_BUDGET: u64 = 5_000_000;

// =================================================================================================
// Information sets

/// Everything one seat legitimately knows. Easy/normal/hard AIs (and the player's hint) decide from
/// this alone.
#[derive(Clone, Debug)]
pub struct Info {
    seat: usize,
    hand: u64,
    /// Cards out of the hands: finished tricks and the trick on the table.
    played: u64,
    /// Cards each seat provably doesn't hold (voids and "couldn't beat" ceilings).
    cannot: [u64; 4],
    counts: [u32; 4],
    leader: usize,
    trick: Vec<Card>,
    trump: usize,
    broken: bool,
    declarer: usize,
    contract: u8,
    tricks: [u8; 4],
    trumps_played: [u32; 4],
    high: u8,
    forced: bool,
}

impl Info {
    fn unknown(&self) -> u64 {
        FULL & !self.played & !self.hand
    }
    fn legal(&self) -> u64 {
        legal_mask(self.hand, &self.trick, self.trump, self.broken)
    }
    /// Cards of `m` that `seat` might hold.
    fn may_hold(&self, seat: usize, m: u64) -> u64 {
        m & self.unknown() & !self.cannot[seat]
    }
    /// The easy opponent's view: no memory of earlier tricks and no void tracking.
    fn forgetful(&self) -> Info {
        let mut i = self.clone();
        let table: u64 = self.trick.iter().fold(0, |a, &c| a | bit(c));
        i.played = table;
        i.cannot = [0; 4];
        i
    }
    fn need(&self) -> u8 {
        let m = self.high.max(3) + 1;
        m.min(13)
    }
}

/// The omniscient view (impossible only).
pub struct Omni {
    info: Info,
    hands: [u64; 4],
}

// =================================================================================================
// AI

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Lv {
    Easy,
    Normal,
    Hard,
    Impossible,
}

impl Lv {
    fn from_mode(m: &str) -> Option<Lv> {
        match m {
            "easy" => Some(Lv::Easy),
            "normal" => Some(Lv::Normal),
            "hard" => Some(Lv::Hard),
            "impossible" => Some(Lv::Impossible),
            _ => None,
        }
    }
    fn label(self) -> &'static str {
        match self {
            Lv::Easy => "Kolay",
            Lv::Normal => "Orta",
            Lv::Hard => "Zor",
            Lv::Impossible => "İmkânsız",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Act {
    Bid(u8),
    Trump(usize),
    Play(Card),
}

// ---- Hand evaluation --------------------------------------------------------------------------

fn honor_tricks(hand: u64, s: usize) -> f64 {
    let m = hand & SM[s];
    let len = cnt(m);
    let has = |r: u8| m & bit(card(s, r)) != 0;
    let (a, k, q, j) = (has(14), has(13), has(12), has(11));
    let mut t = 0.0;
    if a {
        t += 1.0;
    }
    if k {
        t += if a { 0.9 } else if len >= 2 { 0.6 } else { 0.15 };
    }
    if q {
        t += if a && k {
            0.75
        } else if (a || k) && len >= 3 {
            0.4
        } else if len >= 3 {
            0.2
        } else {
            0.05
        };
    }
    if j && len >= 4 && (a || k || q) {
        t += 0.15;
    }
    t
}

/// Estimated tricks as declarer (leading first) with `trump`.
fn eval_trump(hand: u64, trump: usize) -> f64 {
    let tl = cnt(hand & SM[trump]) as f64;
    let mut e = 0.2;
    for s in 0..4 {
        e += honor_tricks(hand, s);
        if s == trump {
            continue;
        }
        let l = cnt(hand & SM[s]);
        if tl >= 3.0 {
            let ruff = match l {
                0 => 1.1,
                1 => 0.65,
                2 => 0.25,
                _ => 0.0,
            };
            e += f64::min(ruff, (tl - 2.0) * 0.45);
        }
        if l >= 5 {
            e += (l as f64 - 4.0) * 0.3;
        }
    }
    // Long trumps win tricks by themselves; honours already counted.
    let low_trumps = cnt(hand & SM[trump] & !(bit(card(trump, 14)) | bit(card(trump, 13)) | bit(card(trump, 12)))) as f64;
    e += (tl - 3.0).max(0.0).min(low_trumps) * 0.85;
    e
}

fn eval_all(hand: u64) -> [f64; 4] {
    [eval_trump(hand, 0), eval_trump(hand, 1), eval_trump(hand, 2), eval_trump(hand, 3)]
}

fn argmax(v: &[f64; 4]) -> usize {
    let mut b = 0;
    for s in 1..4 {
        if v[s] > v[b] {
            b = s;
        }
    }
    b
}

fn trump_desc(hand: u64, t: usize) -> String {
    let m = hand & SM[t];
    let mut desc: Vec<Card> = bits(m).collect();
    desc.reverse();
    let tops: Vec<String> = desc.into_iter().take(2).filter(|&c| rank(c) >= 11).map(|c| rank_tr(rank(c))).collect();
    if tops.is_empty() {
        format!("{} {} kart", cnt(m), SUIT_TR[t])
    } else {
        format!("{} {} kart ({})", cnt(m), SUIT_TR[t], tops.join(", "))
    }
}

fn heuristic_bid(i: &Info, lv: Lv, rng: &mut Rng) -> (Act, String) {
    let est = eval_all(i.hand);
    let t = argmax(&est);
    let mut e = est[t];
    if lv == Lv::Easy {
        e += (rng.f64() - 0.45) * 2.2;
    }
    let need = i.need();
    if i.forced {
        return (Act::Bid(4), format!("Herkes pas geçti: dağıtan olarak 4 almak zorunda (en iyi koz adayı {})", trump_desc(i.hand, t)));
    }
    let margin = if lv == Lv::Easy { 0.4 } else { -0.15 };
    if (need as f64) <= e + margin {
        (Act::Bid(need), format!("Eli ~{} el değerinde ({}): {} dedi", dec(est[t]), trump_desc(i.hand, t), need))
    } else {
        (Act::Bid(0), format!("Eli ~{} el değerinde, {} için yetmez: pas", dec(est[t]), need))
    }
}

fn heuristic_trump(i: &Info) -> (Act, String) {
    let est = eval_all(i.hand);
    let t = argmax(&est);
    (Act::Trump(t), format!("En güçlü rengi koz yaptı: {} — tahmini {} el", trump_desc(i.hand, t), dec(est[t])))
}

// ---- Heuristic play ---------------------------------------------------------------------------

/// Might `p` (who plays after us) beat `c` in a trick led in `lead`? Uses only the info set.
fn may_beat(i: &Info, p: usize, c: Card, lead: usize) -> bool {
    let t = i.trump;
    let unk = i.unknown();
    let short = |s: usize| i.may_hold(p, SM[s]) == 0 || cnt(unk & SM[s]) <= 2;
    if suit(c) == lead {
        if i.may_hold(p, above(c)) != 0 {
            return true;
        }
        lead != t && short(lead) && i.may_hold(p, SM[t]) != 0
    } else if suit(c) == t {
        short(lead) && i.may_hold(p, above(c)) != 0
    } else {
        true
    }
}

fn heuristic_play(i: &Info) -> (Card, String) {
    let legal = i.legal();
    let t = i.trump;
    let unk = i.unknown();
    let boss = |c: Card| unk & above(c) == 0;
    if cnt(legal) == 1 {
        let c = lo(legal);
        return (c, format!("Kurallar gereği tek seçeneği vardı: {}", card_name(c)));
    }
    if i.trick.is_empty() {
        let decl = i.seat == i.declarer;
        let opp_trumps = unk & SM[t];
        let my_t = i.hand & SM[t];
        // 1. Draw trumps with the boss trump.
        if legal & SM[t] != 0 && opp_trumps != 0 && my_t != 0 {
            let top = hi(my_t);
            if boss(top) && (decl || cnt(my_t) >= 2) {
                return (top, format!("Koz çekiyor: en büyük koz ({}) onda, rakiplerin kozlarını topluyor", card_name(top)));
            }
        }
        // 2. Cash a boss nobody can ruff.
        let mut best: Option<(i32, Card)> = None;
        for s in 0..4 {
            let m = legal & SM[s];
            if s == t || m == 0 {
                continue;
            }
            let top = hi(m);
            if !boss(top) {
                continue;
            }
            let risk = opp_trumps != 0
                && ((0..4).any(|p| p != i.seat && i.may_hold(p, SM[s]) == 0 && i.may_hold(p, SM[t]) != 0)
                    || cnt(unk & SM[s]) <= 1);
            if risk {
                continue;
            }
            let sc = cnt(i.hand & SM[s]) as i32 * 2 + rank(top) as i32;
            if best.is_none_or(|(b, _)| sc > b) {
                best = Some((sc, top));
            }
        }
        if let Some((_, c)) = best {
            return (c, format!("{} bu renkte kalan en büyük kart ve kimse kesemez: eli garantiliyor", card_name(c)));
        }
        // 3. Declarer: shorten a side suit to ruff later.
        if decl && cnt(my_t) >= 2 {
            for s in 0..4 {
                let m = legal & SM[s];
                if s != t && cnt(i.hand & SM[s]) == 1 && m != 0 && !boss(lo(m)) {
                    let c = lo(m);
                    return (c, format!("Tek kartlık rengini ({}) bitiriyor: bu renk gelince kozla kesecek", card_name(c)));
                }
            }
        }
        // 4. Low card from the longest side suit (defenders avoid the declarer's ruffing suits).
        let mut pick: Option<(i32, usize)> = None;
        for s in 0..4 {
            let m = legal & SM[s];
            if m == 0 || s == t {
                continue;
            }
            let mut sc = cnt(i.hand & SM[s]) as i32 * 10 - rank(lo(m)) as i32;
            let d = i.declarer;
            if !decl && d != i.seat && i.may_hold(d, SM[s]) == 0 && i.may_hold(d, SM[t]) != 0 {
                sc -= 100;
            }
            if pick.is_none_or(|(b, _)| sc > b) {
                pick = Some((sc, s));
            }
        }
        if let Some((sc, s)) = pick {
            let c = lo(legal & SM[s]);
            return if sc < -50 {
                (c, format!("Her renkte ihaleci kesebiliyor; en zararsızı: {}", card_name(c)))
            } else {
                (c, format!("Uzun renginden küçük kart ({}): büyüklerini sonraya saklıyor, arkadakileri yükseltmeye zorluyor", card_name(c)))
            };
        }
        let c = lo(legal);
        return (c, format!("Elinde yalnız koz kaldı: en küçüğü ({})", card_name(c)));
    }
    // Following.
    let lead = suit(i.trick[0]);
    let w = i.trick[winner_idx(&i.trick, t)];
    let beat: u64 = bits(legal).filter(|&c| beats(c, w, t)).fold(0, |a, c| a | bit(c));
    let n = i.trick.len();
    if beat == 0 {
        let c = if suit(lo(legal)) == lead || legal & !SM[t] == 0 {
            lo(legal)
        } else {
            // Discard: lowest card of the side suit we value least (no bosses, shortest).
            let mut b: Option<(i32, Card)> = None;
            for s in 0..4 {
                let m = legal & SM[s];
                if m == 0 {
                    continue;
                }
                let c = lo(m);
                let mut sc = -(rank(c) as i32) - cnt(m) as i32 * 2;
                if s == t {
                    sc -= 50;
                }
                if boss(hi(m)) && cnt(m) == 1 {
                    sc -= 30;
                }
                if b.is_none_or(|(x, _)| sc > x) {
                    b = Some((sc, c));
                }
            }
            b.map(|x| x.1).unwrap_or(lo(legal))
        };
        let why = if suit(c) == lead {
            format!("Yükseltemiyor: en küçük kartı ({}) verdi", card_name(c))
        } else if suit(c) == t {
            format!("Koz atmak zorunda ama masadakini geçemiyor: en küçük kozu ({})", card_name(c))
        } else {
            format!("Bu renk de koz da yok: en değersiz kartını ({}) attı", card_name(c))
        };
        return (c, why);
    }
    if n == 3 {
        let c = lo(beat);
        let why = if suit(c) == t && lead != t {
            format!("Son oyuncu, rengi yok: en küçük kozla ({}) kesip eli aldı", card_name(c))
        } else {
            format!("Son oyuncu: eli en ucuz kartla ({}) aldı", card_name(c))
        };
        return (c, why);
    }
    let later: Vec<usize> = (n + 1..4).map(|k| (i.leader + k) % 4).collect();
    let safe = bits(beat).find(|&c| later.iter().all(|&p| !may_beat(i, p, c, lead)));
    if let Some(c) = safe {
        let why = if suit(c) == t && lead != t {
            format!("Kozla kesti ({}): arkadan gelenler bu kozu geçemez", card_name(c))
        } else {
            format!("{} ile alıyor: arkadan gelen kimse geçemez", card_name(c))
        };
        return (c, why);
    }
    let c = lo(beat);
    let why = if suit(c) == t && lead != t {
        format!("Rengi yok, kesmek zorunda: en küçük kozla ({})", card_name(c))
    } else {
        format!("Yükseltmek zorunda: geçen en küçük kartı ({}) attı, büyükleri saklı", card_name(c))
    };
    (c, why)
}

// ---- Double-dummy objective -----------------------------------------------------------------

/// Root candidates: one card per touching run (the lowest of the run is the one played).
/// `finished` = cards of completed tricks; everything else (hands + table) is live.
fn root_cands(legal: u64, finished: u64) -> Vec<Card> {
    let live = FULL & !finished;
    bits(reps_top(legal, live)).map(|c| run_low(c, legal, live)).collect()
}

#[derive(Clone, Copy, Debug)]
struct Outcome {
    own: i32,
    /// Declarer: makes the contract; defender: the declarer is set (None: contract already decided).
    flag: Option<bool>,
}

/// Solve one complete world for every candidate. `budget` is decremented by the nodes used;
/// None if it ran out.
///
/// `fast`: solve the root exactly once (value V), then a single null-window probe per candidate
/// ("does it still reach V?"); a card that doesn't is scored V − 1. Used while the deal is big.
/// Otherwise every candidate gets its exact value.
fn solve_world(hands: [u64; 4], i: &Info, cands: &[Card], tt: &mut Tt, budget: &mut u64, fast: bool) -> Option<Vec<Outcome>> {
    let root = P::new(hands, i.leader, &i.trick, i.broken, i.trump);
    let me = i.seat;
    let d = i.declarer;
    let need = i.contract as i32 - i.tricks[d] as i32;
    let mut out = Vec::with_capacity(cands.len());
    let mut guess = (cnt(i.hand) as i32 + 1) / 3;
    let root_v = if fast {
        let mut dd = Dd::new(tt, i.trump, me, *budget);
        let r = dd.exact_root(&root, guess);
        *budget -= dd.nodes.min(*budget);
        Some(r?.0)
    } else {
        None
    };
    for &c in cands {
        let (q, w) = root.play(c, i.trump);
        let flag = if me != d && need > 0 {
            let mut dd = Dd::new(tt, i.trump, d, *budget);
            let can = dd.search(&q, need - (w == Some(d)) as i32);
            *budget -= dd.nodes.min(*budget);
            if dd.abort {
                return None;
            }
            Some(!can)
        } else {
            None
        };
        let mine = (w == Some(me)) as i32;
        let mut dd = Dd::new(tt, i.trump, me, *budget);
        let own = match root_v {
            Some(v) => {
                let ok = dd.search(&q, v - mine);
                if dd.abort {
                    *budget = 0;
                    return None;
                }
                if ok {
                    v
                } else {
                    v - 1
                }
            }
            None => {
                let v = dd.exact(&q, guess);
                let Some(v) = v else {
                    *budget = 0;
                    return None;
                };
                guess = v;
                v + mine
            }
        };
        *budget -= dd.nodes.min(*budget);
        let flag = if me == d { Some(i.tricks[d] as i32 + own >= i.contract as i32) } else { flag };
        out.push(Outcome { own, flag });
    }
    Some(out)
}

/// Reason when there is only one real choice: a single legal card, or legal cards that are all
/// equivalent (touching once the cards between them are gone).
fn single_reason(legal: u64, c: Card) -> String {
    if cnt(legal) == 1 {
        format!("Kurallar gereği tek seçenek: {}", card_name(c))
    } else {
        format!("Oynayabileceği kartlar eşdeğer (aradakiler oynandı): en küçüğü, {}", card_name(c))
    }
}

fn tactic(i: &Info, c: Card) -> String {
    let t = i.trump;
    if i.trick.is_empty() {
        if suit(c) == t {
            return format!("Koz açtı ({})", card_name(c));
        }
        return format!("{} açtı", card_name(c));
    }
    let lead = suit(i.trick[0]);
    let w = i.trick[winner_idx(&i.trick, t)];
    if beats(c, w, t) {
        if suit(c) == t && lead != t {
            format!("Kozla kesti ({})", card_name(c))
        } else {
            format!("{} ile masayı geçti", card_name(c))
        }
    } else if suit(c) == lead {
        format!("Küçük verdi ({})", card_name(c))
    } else {
        format!("{} attı", card_name(c))
    }
}

/// Omniscient play: exact double-dummy on the real deal.
///
/// Declarer: the move that guarantees the most tricks against the other three. Defender: if the
/// declarer can still be set, a move that sets him (the own-tricks optimum when it also sets);
/// otherwise the own-tricks optimum. Roughly three null-window root probes per decision.
fn omni_play(o: &Omni, tt: &mut Tt) -> Option<(Card, String)> {
    let i = &o.info;
    let legal = i.legal();
    let table: u64 = i.trick.iter().fold(0, |a, &c| a | bit(c));
    let live = FULL & !(i.played & !table);
    let low = |c: Card| run_low(c, legal, live);
    if cnt(reps_top(legal, live)) == 1 {
        let c = low(hi(legal));
        return Some((c, single_reason(legal, c)));
    }
    let root = P::new(o.hands, i.leader, &i.trick, i.broken, i.trump);
    let me = i.seat;
    let d = i.declarer;
    let need = i.contract as i32 - i.tricks[d] as i32;
    let mut left = OMNI_BUDGET;
    let guess = (cnt(i.hand) as i32 + 1) / 3;
    let (own, best) = {
        let mut dd = Dd::new(tt, i.trump, me, left);
        let r = dd.exact_root(&root, guess)?;
        left -= dd.nodes.min(left);
        (r.0, r.1.unwrap_or_else(|| dd.first_move(&root)))
    };
    if me == d {
        let c = low(best);
        let why = if i.tricks[d] as i32 + own >= i.contract as i32 {
            format!("{} — bütün kartları görüyor: bu kartla en az {} el daha garanti, ihale tutuyor", tactic(i, c), own)
        } else {
            format!("{} — bütün kartları görüyor: ihale kurtulmuyor, en çok {} el daha alabilir", tactic(i, c), own)
        };
        return Some((c, why));
    }
    if need <= 0 {
        let c = low(best);
        return Some((c, format!("{} — ihale tuttu; bütün kartları görerek kendine en az {} el daha topluyor", tactic(i, c), own)));
    }
    let mut dd = Dd::new(tt, i.trump, d, left);
    let (q, w) = root.play(best, i.trump);
    let own_sets = !dd.search(&q, need - (w == Some(d)) as i32);
    if dd.abort {
        return None;
    }
    if own_sets {
        let c = low(best);
        return Some((c, format!("{} — bütün kartları görüyor: ihaleci {} el daha bulamaz, batıyor; kendine en az {} el", tactic(i, c), need, own)));
    }
    let (makes, refute) = dd.root_probe(&root, need);
    if dd.abort {
        return None;
    }
    match (makes, refute) {
        (false, Some(r)) => {
            let c = low(r);
            Some((c, format!("{} — bütün kartları görüyor: kendi elinden önce batırmayı seçti, bu kartla ihaleci {} el daha bulamaz", tactic(i, c), need)))
        }
        _ => {
            let c = low(best);
            Some((c, format!("{} — ihaleci ne yapılsa tutturuyor; kendine en az {} el daha", tactic(i, c), own)))
        }
    }
}

/// Sample hidden hands consistent with the info set. `prior`: declarer started with ≥ 4 trumps.
fn sample_world(i: &Info, rng: &mut Rng, prior: bool) -> [u64; 4] {
    let pool: Vec<Card> = bits(i.unknown()).collect();
    let others: Vec<usize> = (0..4).filter(|&s| s != i.seat).collect();
    let tries = 48;
    for attempt in 0..tries {
        let use_cannot = attempt < tries - 1;
        let use_prior = prior && attempt < 24 && i.declarer != i.seat;
        let mut cap = i.counts;
        cap[i.seat] = 0;
        let mut h = [0u64; 4];
        h[i.seat] = i.hand;
        let mut order = pool.clone();
        rng.shuffle(&mut order);
        if use_cannot {
            order.sort_by_key(|&c| others.iter().filter(|&&s| i.cannot[s] & bit(c) == 0).count());
        }
        let ok_for = |s: usize, c: Card, cap: &[u32; 4]| cap[s] > 0 && (!use_cannot || i.cannot[s] & bit(c) == 0);
        let mut ok = true;
        for &c in &order {
            let tot: u32 = others.iter().filter(|&&s| ok_for(s, c, &cap)).map(|&s| cap[s]).sum();
            if tot == 0 {
                ok = false;
                break;
            }
            let mut r = rng.below(tot as usize) as u32;
            for &s in &others {
                if ok_for(s, c, &cap) {
                    if r < cap[s] {
                        h[s] |= bit(c);
                        cap[s] -= 1;
                        break;
                    }
                    r -= cap[s];
                }
            }
        }
        if !ok {
            continue;
        }
        if use_prior {
            let d = i.declarer;
            if cnt(h[d] & SM[i.trump]) + i.trumps_played[d] < 4 {
                continue;
            }
        }
        return h;
    }
    unreachable!("the unconstrained attempt always succeeds")
}

/// Sampled worlds and the node budget per world: few, deeper-budget worlds while the deal is
/// still big; many cheap ones near the end.
fn mc_cfg(cards_left: u32) -> (usize, u64) {
    match cards_left {
        44.. => (8, 1_400_000),
        32..=43 => (12, 700_000),
        20..=31 => (20, 400_000),
        _ => (32, 300_000),
    }
}

/// Monte-Carlo determinization: average the double-dummy outcome over sampled worlds.
fn mc_play(i: &Info, rng: &mut Rng, tt: &mut Tt, stats: &mut [u32; 2]) -> Option<(Card, String)> {
    let legal = i.legal();
    let table: u64 = i.trick.iter().fold(0, |a, &c| a | bit(c));
    let cands = root_cands(legal, i.played & !table);
    if cands.len() == 1 {
        let c = cands[0];
        return Some((c, single_reason(legal, c)));
    }
    let left: u32 = i.counts.iter().sum();
    let (n, budget) = mc_cfg(left);
    let mut own = vec![0.0; cands.len()];
    let mut flag = vec![0.0; cands.len()];
    let mut worlds = 0;
    let fast = left >= 32;
    let mut total = MC_DECISION_BUDGET;
    for _ in 0..n {
        if total < budget / 4 {
            break;
        }
        let h = sample_world(i, rng, true);
        let mut wb = budget.min(total);
        let before = wb;
        let solved = solve_world(h, i, &cands, tt, &mut wb, fast);
        total -= before - wb;
        if let Some(outs) = solved {
            worlds += 1;
            for (k, o) in outs.iter().enumerate() {
                own[k] += o.own as f64;
                flag[k] += o.flag.unwrap_or(false) as u8 as f64;
            }
        }
    }
    stats[0] += n as u32;
    stats[1] += worlds as u32;
    if worlds == 0 {
        return None;
    }
    let wn = worlds as f64;
    let d = i.declarer;
    let need = i.contract as i32 - i.tricks[d] as i32;
    let weight = if i.seat == d {
        1.5 * i.contract as f64
    } else if need > 0 {
        0.7 * i.contract as f64
    } else {
        0.0
    };
    let score = |k: usize| own[k] / wn + weight * flag[k] / wn - rank(cands[k]) as f64 * 1e-4;
    let mut best = 0;
    for k in 1..cands.len() {
        if score(k) > score(best) {
            best = k;
        }
    }
    let c = cands[best];
    let (o, f) = (own[best] / wn, flag[best] / wn);
    let why = if i.seat == d {
        format!("{} — {} olası dağılımı çözdü: ortalama {} el daha, ihaleyi tutma şansı {}", tactic(i, c), worlds, dec(o), pct(f))
    } else if need > 0 {
        format!("{} — {} olası dağılımda ihaleciyi batırma şansı {}, kendine ortalama {} el", tactic(i, c), worlds, pct(f), dec(o))
    } else {
        format!("{} — ihale tuttu; {} olası dağılımda kendine ortalama {} el daha", tactic(i, c), worlds, dec(o))
    };
    Some((c, why))
}

fn top_suits(hand: u64, k: usize) -> Vec<usize> {
    let e = eval_all(hand);
    let mut s = vec![0, 1, 2, 3];
    s.sort_by(|&a, &b| e[b].partial_cmp(&e[a]).unwrap_or(std::cmp::Ordering::Equal));
    s.truncate(k);
    s
}

/// Hard bidding / trump choice: in sampled deals, can I (declaring, leading) take `target`
/// tricks against the other three with each candidate trump? Returns per suit (made, decided).
fn mc_make_rate(i: &Info, rng: &mut Rng, tt: &mut Tt, suits: &[usize], target: i32, n: usize) -> Vec<(u32, u32)> {
    let mut res = vec![(0u32, 0u32); suits.len()];
    let mut total = MC_DECISION_BUDGET;
    for _ in 0..n {
        if total < 200_000 {
            break;
        }
        let h = sample_world(i, rng, false);
        for (k, &t) in suits.iter().enumerate() {
            let p = P::new(h, i.seat, &[], false, t);
            let mut dd = Dd::new(tt, t, i.seat, total.min(1_000_000));
            let ok = dd.search(&p, target);
            total -= dd.nodes.min(total);
            if !dd.abort {
                res[k].1 += 1;
                res[k].0 += ok as u32;
            }
        }
    }
    res
}

fn rate(x: (u32, u32)) -> f64 {
    if x.1 == 0 {
        -1.0
    } else {
        x.0 as f64 / x.1 as f64
    }
}

fn mc_bid(i: &Info, rng: &mut Rng, tt: &mut Tt) -> Option<(Act, String)> {
    let need = i.need();
    let suits = top_suits(i.hand, 2);
    if i.forced {
        let (a, w) = heuristic_bid(i, Lv::Normal, rng);
        return Some((a, w));
    }
    let res = mc_make_rate(i, rng, tt, &suits, need as i32, 8);
    let mut b = 0;
    for k in 1..suits.len() {
        if rate(res[k]) > rate(res[b]) {
            b = k;
        }
    }
    let (made, decided) = res[b];
    if decided < 3 {
        return None;
    }
    let t = suits[b];
    let r = rate(res[b]);
    let est = eval_trump(i.hand, t);
    // Worst-case (all three against me) double-dummy is pessimistic against real defenders, so a
    // 40 % make rate already carries a positive expectation; the hand estimate breaks ties.
    if r >= 0.5 || (r >= 0.35 && est >= need as f64 - 0.3) {
        Some((Act::Bid(need), format!("{decided} olası dağılımı çözdü: koz {} ile {made} tanesinde {need} el çıkıyor — {need} dedi", SUIT_TR[t])))
    } else {
        Some((Act::Bid(0), format!("{decided} olası dağılımda koz {} ile {need} el yalnız {made} kez çıkıyor: pas", SUIT_TR[t])))
    }
}

fn mc_trump(i: &Info, rng: &mut Rng, tt: &mut Tt) -> Option<(Act, String)> {
    let suits = top_suits(i.hand, 3);
    let target = i.contract.max(4) as i32;
    let res = mc_make_rate(i, rng, tt, &suits, target, 8);
    let mut b = 0;
    for k in 1..suits.len() {
        if rate(res[k]) > rate(res[b]) {
            b = k;
        }
    }
    if res[b].1 < 3 {
        return None;
    }
    let t = suits[b];
    Some((
        Act::Trump(t),
        format!(
            "Koz {}: {} olası dağılımın {} tanesinde ihaleyi ({target}) tutturuyor; {}",
            SUIT_TR[t],
            res[b].1,
            res[b].0,
            trump_desc(i.hand, t)
        ),
    ))
}

/// Perfect-information bidding: a null-window probe per trump suit ("with this trump, are
/// `need` tricks guaranteed if I declare and lead?"), strongest suit first. `None` if the budget
/// ran out before any suit was decided.
fn omni_bid(o: &Omni, tt: &mut Tt) -> Option<(Act, String)> {
    let i = &o.info;
    let need = i.need();
    let order = top_suits(i.hand, 4);
    if i.forced {
        let (t, v) = omni_best_trump(o, tt).unwrap_or((order[0], -1));
        let v = if v >= 0 { format!("{v} el garanti") } else { "en iyi koz adayı".into() };
        return Some((Act::Bid(4), format!("Herkes pas geçti, dağıtan 4 almak zorunda; bütün elleri görüyor: koz {} ile {v}", SUIT_TR[t])));
    }
    let mut left = OMNI_BUDGET;
    let mut decided = false;
    for &t in &order {
        let p = P::new(o.hands, i.seat, &[], false, t);
        let mut dd = Dd::new(tt, t, i.seat, left);
        let ok = dd.search(&p, need as i32);
        left -= dd.nodes.min(left);
        if dd.abort {
            continue;
        }
        decided = true;
        if ok {
            return Some((Act::Bid(need), format!("Bütün elleri görüyor: koz {} olursa en az {} el garanti — {} dedi", SUIT_TR[t], need, need)));
        }
    }
    if !decided {
        return None;
    }
    Some((Act::Bid(0), format!("Bütün elleri görüyor: hangi koz olsa {} el garanti değil, üç rakip birlikte batırır — pas", need)))
}

/// Exact guaranteed tricks for each trump (declarer leads); the best suit and its value.
fn omni_best_trump(o: &Omni, tt: &mut Tt) -> Option<(usize, i32)> {
    let i = &o.info;
    let mut left = OMNI_BUDGET;
    let mut best: Option<(usize, i32)> = None;
    for t in top_suits(i.hand, 4) {
        let p = P::new(o.hands, i.seat, &[], false, t);
        let mut dd = Dd::new(tt, t, i.seat, left);
        // Only a better suit matters: probe above the current best before solving exactly.
        let v = match best {
            None => dd.exact(&p, 4),
            Some((_, b)) => {
                let better = dd.search(&p, b + 1);
                if dd.abort {
                    break;
                }
                if better {
                    dd.exact(&p, b + 1)
                } else {
                    Some(-1)
                }
            }
        };
        match v {
            Some(v) if best.is_none_or(|(_, b)| v > b) => best = Some((t, v)),
            Some(_) => {}
            None => break,
        }
        left -= dd.nodes.min(left);
        if left == 0 {
            break;
        }
    }
    best
}

fn omni_trump(o: &Omni, tt: &mut Tt) -> Option<(Act, String)> {
    let (t, v) = omni_best_trump(o, tt)?;
    Some((Act::Trump(t), format!("Bütün elleri görüyor: en çok eli koz {} veriyor — üç rakibe karşı en az {} el garanti", SUIT_TR[t], v)))
}

// =================================================================================================
// Session

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Phase {
    Bid,
    Trump,
    Play,
    Summary,
}

#[derive(Clone, Debug)]
struct Deal {
    dealer: usize,
    hands: [u64; 4],
    bids: [Option<u8>; 4],
    passed: [bool; 4],
    high: u8,
    high_seat: Option<usize>,
    phase: Phase,
    turn: usize,
    declarer: usize,
    contract: u8,
    trump: Option<usize>,
    broken: bool,
    leader: usize,
    trick: Vec<Card>,
    tricks: [u8; 4],
    played: u64,
    played_by: [u64; 4],
    cannot: [u64; 4],
    last_trick: Option<(u32, usize, [Card; 4], usize)>,
    trick_no: u32,
}

#[derive(Clone, Debug)]
struct SheetRow {
    hand: u32,
    declarer: usize,
    contract: u8,
    trump: usize,
    made: bool,
    tricks: [u8; 4],
    deltas: [i32; 4],
    totals: [i32; 4],
}

#[derive(Clone, Debug)]
struct Last {
    serial: u64,
    seat: usize,
    act: Option<Act>,
    reason: Option<String>,
    trick_winner: Option<usize>,
}

#[derive(Clone, Debug)]
struct Hint {
    act: Act,
    text: String,
}

pub struct Batak {
    mode: Lv,
    levels: [Lv; 4],
    seed: u64,
    deal_rng: Rng,
    ai_rng: Rng,
    hand_no: u32,
    g: Deal,
    scores: [i32; 4],
    sheet: Vec<SheetRow>,
    serial: u64,
    last: Option<Last>,
    reasons: [Option<String>; 4],
    hint: Option<Hint>,
    used_hint: bool,
    status: &'static str,
    tt_omni: Option<Tt>,
    tt_mc: Option<Tt>,
    /// How often a search budget ran out and the heuristics decided instead (diagnostics).
    fallbacks: u32,
    /// Hard play: sampled worlds / worlds solved within budget (diagnostics).
    mc_stats: [u32; 2],
}

pub fn create(_level: u32, mode: &str) -> Result<Box<dyn Session>, String> {
    let lv = Lv::from_mode(mode).unwrap_or(Lv::Normal);
    Ok(Box::new(Batak::new(time_seed(), lv)))
}

impl Batak {
    pub fn new(seed: u64, lv: Lv) -> Batak {
        Batak::with_levels(seed, lv, [lv; 4])
    }

    /// `levels[0]` is only used when tests let the AI play the player's seat.
    pub fn with_levels(seed: u64, mode: Lv, levels: [Lv; 4]) -> Batak {
        let mut deal_rng = Rng::new(seed);
        let dealer = deal_rng.below(4);
        let g = Self::deal(&mut deal_rng, dealer);
        let mut b = Batak {
            mode,
            levels,
            seed,
            deal_rng,
            ai_rng: Rng::new(seed ^ 0xA1A1_5EED),
            hand_no: 1,
            g,
            scores: [0; 4],
            sheet: vec![],
            serial: 0,
            last: None,
            reasons: [None, None, None, None],
            hint: None,
            used_hint: false,
            status: "playing",
            tt_omni: None,
            tt_mc: None,
            fallbacks: 0,
            mc_stats: [0; 2],
        };
        b.serial += 1;
        b.last = Some(Last { serial: b.serial, seat: dealer, act: None, reason: None, trick_winner: None });
        b
    }

    fn deal(rng: &mut Rng, dealer: usize) -> Deal {
        let mut deck: Vec<Card> = (0..52).collect();
        rng.shuffle(&mut deck);
        let mut hands = [0u64; 4];
        for (k, &c) in deck.iter().enumerate() {
            hands[(dealer + 1 + k) % 4] |= bit(c);
        }
        Deal {
            dealer,
            hands,
            bids: [None; 4],
            passed: [false; 4],
            high: 0,
            high_seat: None,
            phase: Phase::Bid,
            turn: (dealer + 1) % 4,
            declarer: 0,
            contract: 0,
            trump: None,
            broken: false,
            leader: 0,
            trick: vec![],
            tricks: [0; 4],
            played: 0,
            played_by: [0; 4],
            cannot: [0; 4],
            last_trick: None,
            trick_no: 0,
        }
    }

    fn forced(&self) -> bool {
        let g = &self.g;
        g.high_seat.is_none() && g.passed.iter().filter(|&&p| p).count() == 3
    }

    fn min_bid(&self) -> u8 {
        (self.g.high.max(3) + 1).min(13)
    }

    fn ai_pending(&self) -> bool {
        self.status == "playing" && self.g.phase != Phase::Summary && self.g.turn != 0
    }

    /// The information set of `seat`: its own hand plus public knowledge only.
    pub fn info_for(&self, seat: usize) -> Info {
        let g = &self.g;
        let table: u64 = g.trick.iter().fold(0, |a, &c| a | bit(c));
        let trump = g.trump.unwrap_or(0);
        Info {
            seat,
            hand: g.hands[seat],
            played: g.played | table,
            cannot: g.cannot,
            counts: [cnt(g.hands[0]), cnt(g.hands[1]), cnt(g.hands[2]), cnt(g.hands[3])],
            leader: g.leader,
            trick: g.trick.clone(),
            trump,
            broken: g.broken,
            declarer: g.declarer,
            contract: g.contract,
            tricks: g.tricks,
            trumps_played: [0, 1, 2, 3].map(|s| cnt(g.played_by[s] & SM[trump])),
            high: g.high,
            forced: self.forced(),
        }
    }

    fn omni_for(&self, seat: usize) -> Omni {
        Omni { info: self.info_for(seat), hands: self.g.hands }
    }

    fn tt_mc(&mut self) -> &mut Tt {
        self.tt_mc.get_or_insert_with(|| Tt::new(19))
    }

    /// Decide for `seat` at level `lv`. Only the impossible branch sees other hands.
    fn decide(&mut self, seat: usize, lv: Lv) -> (Act, String) {
        let phase = self.g.phase;
        if lv == Lv::Impossible {
            if phase == Phase::Play {
                let o = self.omni_for(seat);
                let tt = self.tt_omni.get_or_insert_with(|| Tt::new(20));
                if let Some((c, w)) = omni_play(&o, tt) {
                    return (Act::Play(c), w);
                }
                self.fallbacks += 1;
                let (c, w) = heuristic_play(&o.info);
                return (Act::Play(c), w);
            }
            let o = self.omni_for(seat);
            let tt = self.tt_omni.get_or_insert_with(|| Tt::new(20));
            let r = if phase == Phase::Bid { omni_bid(&o, tt) } else { omni_trump(&o, tt) };
            if r.is_none() {
                self.fallbacks += 1;
            }
            return r.unwrap_or_else(|| {
                if phase == Phase::Bid {
                    heuristic_bid(&o.info, Lv::Normal, &mut self.ai_rng)
                } else {
                    heuristic_trump(&o.info)
                }
            });
        }
        let info = self.info_for(seat);
        match (phase, lv) {
            (Phase::Bid, Lv::Hard) => {
                let mut rng = self.ai_rng.clone();
                let r = mc_bid(&info, &mut rng, self.tt_mc());
                self.ai_rng = rng;
                r.unwrap_or_else(|| heuristic_bid(&info, Lv::Normal, &mut self.ai_rng))
            }
            (Phase::Bid, _) => heuristic_bid(&info, lv, &mut self.ai_rng),
            (Phase::Trump, Lv::Hard) => {
                let mut rng = self.ai_rng.clone();
                let r = mc_trump(&info, &mut rng, self.tt_mc());
                self.ai_rng = rng;
                r.unwrap_or_else(|| heuristic_trump(&info))
            }
            (Phase::Trump, _) => heuristic_trump(&info),
            (_, Lv::Hard) => {
                let mut rng = self.ai_rng.clone();
                let mut stats = self.mc_stats;
                let r = mc_play(&info, &mut rng, self.tt_mc(), &mut stats);
                self.mc_stats = stats;
                self.ai_rng = rng;
                let (c, w) = r.unwrap_or_else(|| heuristic_play(&info));
                (Act::Play(c), w)
            }
            (_, Lv::Easy) => {
                let legal = info.legal();
                if cnt(legal) > 1 && self.ai_rng.chance(0.12) {
                    let v: Vec<Card> = bits(legal).collect();
                    let c = *self.ai_rng.pick(&v);
                    return (Act::Play(c), format!("Dalgın oynadı: {} — daha iyisi vardı", card_name(c)));
                }
                let (c, w) = heuristic_play(&info.forgetful());
                (Act::Play(c), w)
            }
            _ => {
                let (c, w) = heuristic_play(&info);
                (Act::Play(c), w)
            }
        }
    }

    /// Validate an action for the seat on turn (no mutation).
    fn check(&self, a: Act) -> Result<(), String> {
        let g = &self.g;
        let seat = g.turn;
        match a {
            Act::Bid(n) => {
                if g.phase != Phase::Bid {
                    return Err("Şu an ihale zamanı değil".into());
                }
                if n == 0 {
                    if self.forced() {
                        return Err("Herkes pas dedi: dağıtan olarak en az 4 almak zorundasın".into());
                    }
                } else if n < self.min_bid() || n > 13 {
                    return Err(format!("En az {} demelisin (en çok 13)", self.min_bid()));
                }
                let _ = seat;
                Ok(())
            }
            Act::Trump(s) => {
                if g.phase != Phase::Trump {
                    return Err("Şu an koz seçilmiyor".into());
                }
                if s > 3 {
                    return Err("Geçersiz renk".into());
                }
                Ok(())
            }
            Act::Play(c) => {
                if g.phase != Phase::Play {
                    return Err("Şu an kart oynanmıyor".into());
                }
                let trump = g.trump.unwrap_or(0);
                let h = g.hands[seat];
                if h & bit(c) == 0 {
                    return Err("Bu kart elinde yok".into());
                }
                if legal_mask(h, &g.trick, trump, g.broken) & bit(c) == 0 {
                    return Err(illegal_reason(h, &g.trick, trump, c));
                }
                Ok(())
            }
        }
    }

    /// Apply a validated action for the seat on turn.
    fn apply(&mut self, a: Act, reason: Option<String>) {
        let seat = self.g.turn;
        self.serial += 1;
        if seat == 0 {
            self.hint = None;
        }
        let mut trick_winner = None;
        match a {
            Act::Bid(n) => {
                let g = &mut self.g;
                g.bids[seat] = Some(n);
                if n == 0 {
                    g.passed[seat] = true;
                } else {
                    g.high = n;
                    g.high_seat = Some(seat);
                }
                let active = g.passed.iter().filter(|&&p| !p).count();
                if g.high == 13 || (g.high_seat.is_some() && active == 1) {
                    let d = g.high_seat.unwrap_or(seat);
                    g.declarer = d;
                    g.contract = g.high;
                    g.phase = Phase::Trump;
                    g.turn = d;
                } else {
                    let mut t = (seat + 1) % 4;
                    while g.passed[t] {
                        t = (t + 1) % 4;
                    }
                    g.turn = t;
                }
            }
            Act::Trump(s) => {
                let g = &mut self.g;
                g.trump = Some(s);
                g.phase = Phase::Play;
                g.leader = g.declarer;
                g.turn = g.declarer;
            }
            Act::Play(c) => {
                let g = &mut self.g;
                let trump = g.trump.unwrap_or(0);
                infer(&mut g.cannot, seat, c, &g.trick, trump, g.broken);
                g.hands[seat] &= !bit(c);
                g.played_by[seat] |= bit(c);
                if suit(c) == trump {
                    g.broken = true;
                }
                g.trick.push(c);
                if g.trick.len() == 4 {
                    let wi = winner_idx(&g.trick, trump);
                    let w = (g.leader + wi) % 4;
                    g.tricks[w] += 1;
                    g.trick_no += 1;
                    let mut cards = [0; 4];
                    cards.copy_from_slice(&g.trick);
                    g.last_trick = Some((g.trick_no, g.leader, cards, w));
                    for &x in &g.trick {
                        g.played |= bit(x);
                    }
                    g.trick.clear();
                    g.leader = w;
                    g.turn = w;
                    trick_winner = Some(w);
                    if g.trick_no == 13 {
                        self.score_hand();
                    }
                } else {
                    g.turn = (seat + 1) % 4;
                }
            }
        }
        if let Some(r) = &reason {
            self.reasons[seat] = Some(r.clone());
        }
        self.last = Some(Last { serial: self.serial, seat, act: Some(a), reason, trick_winner });
    }

    fn score_hand(&mut self) {
        let g = &mut self.g;
        g.phase = Phase::Summary;
        g.turn = 0;
        let d = g.declarer;
        let made = g.tricks[d] >= g.contract;
        let mut deltas = [0i32; 4];
        for s in 0..4 {
            deltas[s] = g.tricks[s] as i32;
        }
        if !made {
            deltas[d] = -(g.contract as i32);
        }
        for s in 0..4 {
            self.scores[s] += deltas[s];
        }
        self.sheet.push(SheetRow {
            hand: self.hand_no,
            declarer: d,
            contract: g.contract,
            trump: g.trump.unwrap_or(0),
            made,
            tricks: g.tricks,
            deltas,
            totals: self.scores,
        });
        if self.hand_no >= MAX_HANDS || self.scores.iter().any(|&x| x >= TARGET) {
            let top = *self.scores.iter().max().unwrap_or(&0);
            let n_top = self.scores.iter().filter(|&&x| x == top).count();
            self.status = if self.scores[0] < top {
                "lost"
            } else if n_top > 1 {
                "draw"
            } else {
                "won"
            };
        }
    }

    fn next_hand(&mut self) {
        let dealer = (self.g.dealer + 1) % 4;
        self.g = Self::deal(&mut self.deal_rng, dealer);
        self.hand_no += 1;
        self.reasons = [None, None, None, None];
        self.serial += 1;
        self.last = Some(Last { serial: self.serial, seat: dealer, act: None, reason: None, trick_winner: None });
    }

    /// One AI action for the seat on turn (any seat — tests let the AI play South too).
    fn ai_step(&mut self) {
        let seat = self.g.turn;
        let (a, why) = self.decide(seat, self.levels[seat]);
        debug_assert!(self.check(a).is_ok(), "AI produced an illegal action {a:?}");
        if self.check(a).is_err() {
            // Never let a bug stall the table: fall back to the first legal action.
            let fallback = match self.g.phase {
                Phase::Bid => Act::Bid(if self.forced() { self.min_bid() } else { 0 }),
                Phase::Trump => Act::Trump(0),
                _ => {
                    let g = &self.g;
                    Act::Play(lo(legal_mask(g.hands[seat], &g.trick, g.trump.unwrap_or(0), g.broken)))
                }
            };
            self.apply(fallback, Some(why));
        } else {
            self.apply(a, Some(why));
        }
    }

    fn make_hint(&mut self) -> Result<(), String> {
        if self.g.phase == Phase::Summary || self.g.turn != 0 {
            return Err("İpucu yalnızca senin sıranda".into());
        }
        // The hint plays at hard strength from *your* information set — no peeking.
        let info = self.info_for(0);
        let mut rng = self.ai_rng.clone();
        let (act, text) = match self.g.phase {
            Phase::Bid => {
                let r = mc_bid(&info, &mut rng, self.tt_mc()).unwrap_or_else(|| heuristic_bid(&info, Lv::Normal, &mut Rng::new(1)));
                r
            }
            Phase::Trump => mc_trump(&info, &mut rng, self.tt_mc()).unwrap_or_else(|| heuristic_trump(&info)),
            _ => {
                let mut stats = [0; 2];
                let (c, w) = mc_play(&info, &mut rng, self.tt_mc(), &mut stats).unwrap_or_else(|| heuristic_play(&info));
                (Act::Play(c), w)
            }
        };
        self.ai_rng = rng;
        let text = match act {
            Act::Bid(0) => format!("Öneri: pas. {text}"),
            Act::Bid(n) => format!("Öneri: {n} de. {text}"),
            Act::Trump(s) => format!("Öneri: koz {}. {text}", SUIT_TR[s]),
            Act::Play(c) => format!("Öneri: {}. {text}", card_name(c)),
        };
        self.hint = Some(Hint { act, text });
        self.used_hint = true;
        Ok(())
    }

    fn parse(a: &Value) -> Result<Act, String> {
        if let Some(n) = a.get("bid") {
            let n = n.as_u64().ok_or("Geçersiz ihale")?;
            if n > 13 {
                return Err("En çok 13 diyebilirsin".into());
            }
            return Ok(Act::Bid(n as u8));
        }
        if let Some(s) = a.get("trump") {
            let s = s.as_u64().ok_or("Geçersiz renk")?;
            if s > 3 {
                return Err("Geçersiz renk".into());
            }
            return Ok(Act::Trump(s as usize));
        }
        if let Some(p) = a.get("play") {
            let s = p.get(0).and_then(|v| v.as_u64()).ok_or("Geçersiz kart")?;
            let r = p.get(1).and_then(|v| v.as_u64()).ok_or("Geçersiz kart")?;
            if s > 3 || !(2..=14).contains(&r) {
                return Err("Geçersiz kart".into());
            }
            return Ok(Act::Play(card(s as usize, r as u8)));
        }
        Err("Bilinmeyen hamle".into())
    }

    fn hand_json(m: u64) -> Value {
        let mut v: Vec<Card> = bits(m).collect();
        v.sort_by_key(|&c| (suit(c), std::cmp::Reverse(rank(c))));
        Value::Array(v.into_iter().map(cj).collect())
    }

    fn act_json(a: Option<Act>) -> (Value, Value, Value, Value) {
        match a {
            Some(Act::Bid(0)) => (json!("pass"), json!(0), Value::Null, Value::Null),
            Some(Act::Bid(n)) => (json!("bid"), json!(n), Value::Null, Value::Null),
            Some(Act::Trump(s)) => (json!("trump"), Value::Null, json!(s), Value::Null),
            Some(Act::Play(c)) => (json!("play"), Value::Null, Value::Null, cj(c)),
            None => (json!("deal"), Value::Null, Value::Null, Value::Null),
        }
    }
}

impl Session for Batak {
    fn state(&self) -> Value {
        let g = &self.g;
        let your_turn = self.status == "playing" && g.phase != Phase::Summary && g.turn == 0;
        let trump = g.trump.unwrap_or(0);
        let legal = if your_turn && g.phase == Phase::Play {
            Self::hand_json(legal_mask(g.hands[0], &g.trick, trump, g.broken))
        } else {
            json!([])
        };
        let bid_options: Vec<u8> = if your_turn && g.phase == Phase::Bid { (self.min_bid()..=13).collect() } else { vec![] };
        let trick_cards: Vec<Value> =
            g.trick.iter().enumerate().map(|(k, &c)| json!({"seat": (g.leader + k) % 4, "card": cj(c)})).collect();
        let last_trick = g.last_trick.map(|(no, leader, cards, w)| {
            json!({
                "no": no, "leader": leader, "winner": w,
                "cards": (0..4).map(|k| json!({"seat": (leader + k) % 4, "card": cj(cards[k])})).collect::<Vec<_>>(),
            })
        });
        let last = self.last.as_ref().map(|l| {
            let (kind, bid, tr, c) = Self::act_json(l.act);
            json!({"serial": l.serial, "seat": l.seat, "kind": kind, "bid": bid, "trump": tr, "card": c,
                   "reason": l.reason, "trick_winner": l.trick_winner})
        });
        let hint = self.hint.as_ref().map(|h| {
            let (kind, bid, tr, c) = Self::act_json(Some(h.act));
            json!({"kind": kind, "bid": bid, "trump": tr, "card": c, "text": h.text})
        });
        let sheet: Vec<Value> = self
            .sheet
            .iter()
            .map(|r| {
                json!({"hand": r.hand, "declarer": r.declarer, "contract": r.contract, "trump": r.trump,
                       "made": r.made, "tricks": r.tricks, "deltas": r.deltas, "totals": r.totals})
            })
            .collect();
        let hand_result = if g.phase == Phase::Summary {
            self.sheet.last().map(|r| {
                let bat: Vec<usize> = if r.made { vec![] } else { vec![r.declarer] };
                json!({"declarer": r.declarer, "contract": r.contract, "trump": r.trump, "made": r.made,
                       "tricks": r.tricks, "deltas": r.deltas, "batanlar": bat})
            })
        } else {
            None
        };
        let over = self.status != "playing";
        let stars = if self.status == "won" {
            let mut others = self.scores[1..].to_vec();
            others.sort();
            let margin = self.scores[0] - others[2];
            if self.used_hint {
                1
            } else if margin >= 10 {
                3
            } else {
                2
            }
        } else {
            0
        };
        let summary = if over {
            Some(format!(
                "Puanın {} · {} {} · {} {} · {} {} · {} el",
                self.scores[0], NAMES[1], self.scores[1], NAMES[2], self.scores[2], NAMES[3], self.scores[3], self.hand_no
            ))
        } else {
            None
        };
        let head = json!({
            "status": self.status,
            "stars": stars,
            "title": format!("El {}/{}", self.hand_no, MAX_HANDS),
            "goal": format!("{TARGET} puana ilk ulaşan ya da {MAX_HANDS} el sonunda en yüksek puan kazanır"),
            "summary": summary,
            "mode": self.mode.label(),
            "seed": self.seed.to_string(),
            "phase": match g.phase { Phase::Bid => "bid", Phase::Trump => "trump", Phase::Play => "play", Phase::Summary => "summary" },
        });
        let more = json!({
            "hand_no": self.hand_no,
            "max_hands": MAX_HANDS,
            "target": TARGET,
            "dealer": g.dealer,
            "names": NAMES,
            "hands": [Self::hand_json(g.hands[0]), Self::hand_json(g.hands[1]), Self::hand_json(g.hands[2]), Self::hand_json(g.hands[3])],
            "counts": [cnt(g.hands[0]), cnt(g.hands[1]), cnt(g.hands[2]), cnt(g.hands[3])],
            "bids": g.bids,
            "passed": g.passed,
            "high_bid": g.high,
            "high_seat": g.high_seat,
            "bid_options": bid_options,
            "can_pass": your_turn && g.phase == Phase::Bid && !self.forced(),
            "declarer": if g.phase == Phase::Bid { Value::Null } else { json!(g.declarer) },
            "contract": g.contract,
            "trump": g.trump,
            "trump_broken": g.broken,
            "turn": if g.turn == 0 { "you" } else { "ai" },
            "seat": g.turn,
            "ai_pending": self.ai_pending(),
            "legal": legal,
        });
        let rest = json!({
            "trick": {"leader": g.leader, "cards": trick_cards},
            "last_trick": last_trick,
            "trick_no": g.trick_no,
            "tricks": g.tricks,
            "scores": self.scores,
            "last_action": last,
            "reasons": self.reasons,
            "serial": self.serial,
            "hint": hint,
            "hand_result": hand_result,
            "sheet": sheet,
            "match_over": over,
            "used_hint": self.used_hint,
        });
        let mut out = head;
        if let (Some(o), Value::Object(a), Value::Object(b)) = (out.as_object_mut(), more, rest) {
            o.extend(a);
            o.extend(b);
        }
        out
    }

    fn act(&mut self, a: &Value) -> Result<(), String> {
        if self.status != "playing" {
            return Err("Maç bitti".into());
        }
        if a.get("hint").and_then(|v| v.as_bool()) == Some(true) {
            return self.make_hint();
        }
        if a.get("ai").and_then(|v| v.as_bool()) == Some(true) {
            if !self.ai_pending() {
                return Err("Sıra sende".into());
            }
            self.ai_step();
            return Ok(());
        }
        if a.get("next").and_then(|v| v.as_bool()) == Some(true) {
            if self.g.phase != Phase::Summary {
                return Err("El henüz bitmedi".into());
            }
            self.next_hand();
            return Ok(());
        }
        let act = Self::parse(a)?;
        if self.g.phase == Phase::Summary {
            return Err("El bitti: yeni ele geç".into());
        }
        if self.g.turn != 0 {
            return Err("Sıra sende değil".into());
        }
        self.check(act)?;
        self.apply(act, None);
        Ok(())
    }
}

// =================================================================================================
// Tests

#[cfg(test)]
mod tests {
    use super::*;

    fn c(s: usize, r: u8) -> Card {
        card(s, r)
    }
    fn m(cs: &[Card]) -> u64 {
        cs.iter().fold(0, |a, &x| a | bit(x))
    }

    /// Plain minimax over every legal card (no TT, no equivalence, no pruning).
    fn brute(p: &P, me: usize, trump: usize) -> i32 {
        let who = p.who();
        if p.h[who] == 0 {
            return 0;
        }
        let mut best: Option<i32> = None;
        for c in bits(p.legal(trump)) {
            let (q, w) = p.play(c, trump);
            let v = (w == Some(me)) as i32 + brute(&q, me, trump);
            best = Some(match best {
                None => v,
                Some(b) if who == me => b.max(v),
                Some(b) => b.min(v),
            });
        }
        best.unwrap_or(0)
    }

    /// Step whoever is on turn (South included) with its level; `next` from the summary.
    fn step_any(b: &mut Batak) {
        if b.g.phase == Phase::Summary {
            b.next_hand();
        } else {
            b.ai_step();
        }
    }

    #[test]
    fn batak_dealing() {
        for seed in 0..20 {
            let b = Batak::new(seed, Lv::Normal);
            let h = b.g.hands;
            let mut all = 0;
            for s in 0..4 {
                assert_eq!(cnt(h[s]), 13);
                assert_eq!(all & h[s], 0);
                all |= h[s];
            }
            assert_eq!(all, FULL);
            assert_eq!(b.g.turn, (b.g.dealer + 1) % 4);
            assert_eq!(b.g.phase, Phase::Bid);
        }
        assert_ne!(Batak::new(1, Lv::Easy).g.hands, Batak::new(2, Lv::Easy).g.hands);
        assert_eq!(Batak::new(7, Lv::Easy).g.hands, Batak::new(7, Lv::Hard).g.hands);
    }

    #[test]
    fn batak_follow_suit_and_must_beat() {
        let t = 0; // maça koz
        let hand = m(&[c(1, 5), c(1, 12), c(2, 9), c(0, 3)]);
        // Kupa 10 led: must follow kupa and beat it → only Kupa Kız.
        assert_eq!(legal_mask(hand, &[c(1, 10)], t, false), m(&[c(1, 12)]));
        // Kupa As led: can't beat → any kupa.
        assert_eq!(legal_mask(hand, &[c(1, 14)], t, false), m(&[c(1, 5), c(1, 12)]));
        // Kupa led and already trumped: any kupa, no need to beat.
        assert_eq!(legal_mask(hand, &[c(1, 3), c(0, 2)], t, true), m(&[c(1, 5), c(1, 12)]));
        // Must beat the highest card, not the led card.
        assert_eq!(legal_mask(hand, &[c(1, 3), c(1, 13)], t, false), m(&[c(1, 5), c(1, 12)]));
    }

    #[test]
    fn batak_must_trump_and_overtrump() {
        let t = 0;
        let hand = m(&[c(0, 4), c(0, 11), c(2, 9), c(3, 6)]);
        // Kupa led, void → must trump (any trump beats a kupa).
        assert_eq!(legal_mask(hand, &[c(1, 10)], t, false), m(&[c(0, 4), c(0, 11)]));
        // Trumped with Maça 8 → must over-trump with the Vale.
        assert_eq!(legal_mask(hand, &[c(1, 10), c(0, 8)], t, true), m(&[c(0, 11)]));
        // Trumped with Maça Kız → can't over-trump, still must play a trump.
        assert_eq!(legal_mask(hand, &[c(1, 10), c(0, 12)], t, true), m(&[c(0, 4), c(0, 11)]));
        // No kupa, no trump → anything.
        let h2 = m(&[c(2, 9), c(3, 6)]);
        assert_eq!(legal_mask(h2, &[c(1, 10)], t, false), h2);
    }

    #[test]
    fn batak_trump_breaking() {
        let t = 1;
        let hand = m(&[c(1, 14), c(1, 3), c(2, 5)]);
        assert_eq!(legal_mask(hand, &[], t, false), m(&[c(2, 5)]));
        assert_eq!(legal_mask(hand, &[], t, true), hand);
        let only = m(&[c(1, 14), c(1, 3)]);
        assert_eq!(legal_mask(only, &[], t, false), only);
    }

    fn to_play(b: &mut Batak) {
        // Drive bidding/trump with AI steps until the play phase (any seat).
        while b.g.phase != Phase::Play {
            step_any(b);
        }
    }

    #[test]
    fn batak_illegal_actions_rejected_unchanged() {
        let mut b = Batak::new(11, Lv::Normal);
        // Drive to South's bid turn.
        while b.g.turn != 0 {
            b.act(&json!({"ai": true})).unwrap();
        }
        let before = b.state();
        assert!(b.act(&json!({"bid": 3})).is_err());
        assert!(b.act(&json!({"bid": 14})).is_err());
        assert!(b.act(&json!({"trump": 1})).is_err());
        assert!(b.act(&json!({"play": [0, 14]})).is_err());
        assert!(b.act(&json!({"ai": true})).is_err());
        assert!(b.act(&json!({"next": true})).is_err());
        assert!(b.act(&json!({"foo": 1})).is_err());
        if b.g.high > 0 {
            assert!(b.act(&json!({"bid": b.g.high})).is_err());
        }
        assert_eq!(b.state(), before);

        // Play phase: a card South doesn't hold, and an off-suit card when following.
        let mut b = Batak::new(5, Lv::Normal);
        to_play(&mut b);
        loop {
            if b.g.turn == 0 && !b.g.trick.is_empty() {
                let h = b.g.hands[0];
                let lead = suit(b.g.trick[0]);
                let tr = b.g.trump.unwrap();
                let legal = legal_mask(h, &b.g.trick, tr, b.g.broken);
                if let Some(x) = bits(h & !legal).next() {
                    let before = b.state();
                    let e = b.act(&json!({"play": [suit(x), rank(x)]})).unwrap_err();
                    assert!(!e.is_empty());
                    assert_eq!(b.state(), before);
                    let not_mine = bits(FULL & !h).next().unwrap();
                    assert!(b.act(&json!({"play": [suit(not_mine), rank(not_mine)]})).is_err());
                    assert_eq!(b.state(), before);
                    let _ = lead;
                    break;
                }
            }
            step_any(&mut b);
            assert_eq!(b.status, "playing");
        }
    }

    #[test]
    fn batak_scoring_and_batma() {
        let mut b = Batak::new(3, Lv::Normal);
        b.g.declarer = 2;
        b.g.contract = 6;
        b.g.trump = Some(0);
        b.g.tricks = [3, 2, 5, 3];
        b.score_hand();
        assert_eq!(b.scores, [3, 2, -6, 3]);
        assert!(!b.sheet[0].made);
        let st = b.state();
        assert_eq!(st["phase"], "summary");
        assert_eq!(st["hand_result"]["batanlar"], json!([2]));
        b.next_hand();
        b.g.declarer = 1;
        b.g.contract = 5;
        b.g.tricks = [1, 7, 2, 3];
        b.score_hand();
        assert_eq!(b.scores, [4, 9, -4, 6]);
        assert!(b.sheet[1].made);
        assert_eq!(b.status, "playing");
        // Reaching 51 ends the match.
        b.next_hand();
        b.scores = [48, 20, 30, 10];
        b.g.declarer = 0;
        b.g.contract = 4;
        b.g.tricks = [5, 3, 3, 2];
        b.score_hand();
        assert_eq!(b.status, "won");
        assert!(b.act(&json!({"next": true})).is_err());
    }

    #[test]
    fn batak_forced_dealer_bid() {
        let mut b = Batak::new(9, Lv::Normal);
        let d = b.g.dealer;
        for _ in 0..3 {
            let a = Act::Bid(0);
            assert!(b.check(a).is_ok());
            b.apply(a, None);
        }
        assert_eq!(b.g.turn, d);
        assert!(b.forced());
        assert!(b.check(Act::Bid(0)).is_err());
        b.apply(Act::Bid(4), None);
        assert_eq!(b.g.phase, Phase::Trump);
        assert_eq!(b.g.declarer, d);
    }

    #[test]
    fn batak_inference_is_sound() {
        // Over many AI-played hands, no `cannot` bit is ever set for a card the seat holds.
        for seed in 0..6 {
            let mut b = Batak::new(100 + seed, Lv::Normal);
            for _ in 0..400 {
                if b.status != "playing" {
                    break;
                }
                step_any(&mut b);
                for s in 0..4 {
                    assert_eq!(b.g.cannot[s] & b.g.hands[s], 0, "seed {seed} seat {s}");
                }
            }
        }
    }

    #[test]
    fn batak_dds_matches_brute_force() {
        let mut rng = Rng::new(77);
        let mut tt = Tt::new(16);
        for case in 0..300 {
            let k = 2 + rng.below(3); // 2..4 cards each
            let mut deck: Vec<Card> = (0..52).collect();
            rng.shuffle(&mut deck);
            // Concentrate on two or three suits so that following/ruffing actually happens.
            let suits = 2 + rng.below(2);
            let mut pool: Vec<Card> = deck.into_iter().filter(|&c| suit(c) < suits).collect();
            pool.truncate(4 * k + 3);
            let mut h = [0u64; 4];
            for s in 0..4 {
                for _ in 0..k {
                    h[s] |= bit(pool.pop().unwrap());
                }
            }
            let trump = rng.below(suits);
            let leader = rng.below(4);
            let broken = rng.chance(0.5);
            let mut p = P::new(h, leader, &[], broken, trump);
            // Sometimes start mid-trick.
            let pre = rng.below(3);
            for _ in 0..pre {
                let l = p.legal(trump);
                let v: Vec<Card> = bits(l).collect();
                let c = v[rng.below(v.len())];
                p = p.play(c, trump).0;
            }
            for me in 0..4 {
                let want = brute(&p, me, trump);
                let mut dd = Dd::new(&mut tt, trump, me, u64::MAX);
                let got = dd.exact(&p, 1).unwrap();
                assert_eq!(got, want, "case {case} me {me}");
            }
        }
    }

    fn run_match(seed: u64, levels: [Lv; 4]) -> Batak {
        let mut b = Batak::with_levels(seed, levels[1], levels);
        let mut steps = 0;
        while b.status == "playing" {
            step_any(&mut b);
            steps += 1;
            assert!(steps < 10 * (4 * 13 + 30), "match did not terminate");
        }
        b
    }

    /// Every seat (South included) played by the AI; a match ends at 51 points or 10 hands.
    fn full_match_terminates(seed: u64, levels: [Lv; 4]) {
        let b = run_match(seed, levels);
        assert!(b.sheet.len() as u32 <= MAX_HANDS);
        assert!(b.sheet.len() as u32 == MAX_HANDS || b.scores.iter().any(|&x| x >= TARGET));
        assert!(["won", "lost", "draw"].contains(&b.status));
        let st = b.state();
        assert_eq!(st["match_over"], true);
        assert!(st["summary"].as_str().is_some());
    }

    #[test]
    fn batak_ai_match_terminates_easy() {
        full_match_terminates(500, [Lv::Easy; 4]);
    }

    #[test]
    fn batak_ai_match_terminates_normal() {
        full_match_terminates(501, [Lv::Normal; 4]);
    }

    #[test]
    fn batak_ai_match_terminates_hard() {
        // Monte-Carlo search is slow in debug builds: a full match with one hard seat, plus two
        // complete hands with hard at every seat.
        full_match_terminates(502, [Lv::Hard, Lv::Easy, Lv::Easy, Lv::Easy]);
        let mut b = Batak::with_levels(602, Lv::Hard, [Lv::Hard; 4]);
        while b.sheet.len() < 2 {
            step_any(&mut b);
        }
        assert_eq!(b.sheet.len(), 2);
    }

    #[test]
    fn batak_ai_match_terminates_impossible() {
        full_match_terminates(503, [Lv::Impossible; 4]);
    }

    #[test]
    fn batak_state_protocol() {
        let mut b = Batak::new(42, Lv::Normal);
        let st = b.state();
        assert_eq!(st["status"], "playing");
        assert_eq!(st["phase"], "bid");
        assert_eq!(st["hands"][0].as_array().unwrap().len(), 13);
        let mut guard = 0;
        while b.state()["phase"] != "summary" {
            if b.state()["ai_pending"] == true {
                b.act(&json!({"ai": true})).unwrap();
                assert!(b.state()["last_action"]["reason"].as_str().is_some_and(|r| !r.is_empty()));
            } else {
                let st = b.state();
                match st["phase"].as_str().unwrap() {
                    "bid" => {
                        let a = if st["can_pass"] == true { json!({"bid": 0}) } else { json!({"bid": st["bid_options"][0]}) };
                        b.act(&a).unwrap();
                    }
                    "trump" => b.act(&json!({"trump": 2})).unwrap(),
                    _ => {
                        let l = st["legal"][0].clone();
                        b.act(&json!({"play": l})).unwrap();
                    }
                }
            }
            guard += 1;
            assert!(guard < 200);
        }
        let st = b.state();
        let tr: u64 = st["tricks"].as_array().unwrap().iter().map(|v| v.as_u64().unwrap()).sum();
        assert_eq!(tr, 13);
        assert_eq!(st["sheet"].as_array().unwrap().len(), 1);
        b.act(&json!({"next": true})).unwrap();
        assert_eq!(b.state()["hand_no"], 2);
    }

    #[test]
    fn batak_hint_works() {
        let mut b = Batak::new(8, Lv::Easy);
        while b.g.turn != 0 {
            b.act(&json!({"ai": true})).unwrap();
        }
        b.act(&json!({"hint": true})).unwrap();
        let st = b.state();
        assert!(st["hint"]["text"].as_str().unwrap().starts_with("Öneri"));
        assert_eq!(st["used_hint"], true);
    }

    /// Duplicate comparison: the same deals with South played by `lv` and by an easy AI (the
    /// other three seats easy in both runs). Returns (South points with lv, with easy, hands).
    fn duplicate(lv: Lv, seeds: std::ops::Range<u64>, hands: usize) -> (i32, i32, usize) {
        let (mut a, mut e, mut n) = (0, 0, 0);
        for seed in seeds {
            for (k, south) in [lv, Lv::Easy].into_iter().enumerate() {
                let mut b = Batak::with_levels(seed, Lv::Easy, [south, Lv::Easy, Lv::Easy, Lv::Easy]);
                while b.sheet.len() < hands && b.status == "playing" {
                    step_any(&mut b);
                }
                let pts: i32 = b.sheet.iter().map(|r| r.deltas[0]).sum();
                if k == 0 {
                    a += pts;
                    n += b.sheet.len();
                } else {
                    e += pts;
                }
            }
        }
        (a, e, n)
    }

    #[test]
    fn batak_impossible_beats_easy() {
        let (imp, easy, n) = duplicate(Lv::Impossible, 900..904, 5);
        eprintln!("duplicate over {n} hands: South impossible {imp} vs South easy {easy}");
        assert!(imp as f64 >= easy as f64 * 1.3 + 5.0, "impossible {imp} vs easy {easy} over {n} hands");
    }

    /// Diagnostics: level strength per seat over many hands (release: `--ignored --nocapture`).
    #[test]
    #[ignore]
    fn batak_strength_table() {
        for (name, lv) in [("impossible", Lv::Impossible), ("hard", Lv::Hard), ("normal", Lv::Normal)] {
            let mut tot = [0i32; 4];
            let mut decl = [0; 4];
            let mut made = [0; 4];
            let mut hands = 0;
            for seed in 0..10u64 {
                let mut b = Batak::with_levels(2000 + seed, Lv::Easy, [lv, Lv::Easy, Lv::Easy, Lv::Easy]);
                while b.sheet.len() < 10 && b.status == "playing" {
                    step_any(&mut b);
                }
                for r in &b.sheet {
                    decl[r.declarer] += 1;
                    made[r.declarer] += r.made as i32;
                    for s in 0..4 {
                        tot[s] += r.deltas[s];
                    }
                    hands += 1;
                }
            }
            eprintln!("{name} vs 3 easy, {hands} hands: points {tot:?}, declared {decl:?}, made {made:?}");
            let (a, e, n) = duplicate(lv, 3000..3010, 10);
            eprintln!("  duplicate over {n} hands: South {name} {a} vs South easy {e}");
        }
    }

    /// Diagnostics: how often a strong South wins a full match at each table.
    #[test]
    #[ignore]
    fn batak_table_win_rates() {
        for table in [Lv::Easy, Lv::Normal, Lv::Hard, Lv::Impossible] {
            let mut res = std::collections::BTreeMap::new();
            let mut pts = [0i32; 4];
            for seed in 0..12u64 {
                let b = run_match(4000 + seed, [Lv::Hard, table, table, table]);
                *res.entry(b.status).or_insert(0) += 1;
                for s in 0..4 {
                    pts[s] += b.scores[s];
                }
            }
            eprintln!("hard South at {table:?} table: {res:?}, total points {pts:?}");
        }
    }

    #[test]
    #[ignore]
    fn batak_timing() {
        use std::time::Instant;
        for lv in [Lv::Impossible, Lv::Hard] {
            let mut worst = 0u128;
            let mut total = 0u128;
            let mut n = 0;
            let mut fb = 0;
            let mut early = [0u32; 2];
            for seed in 0..4u64 {
                let mut b = Batak::with_levels(1000 + seed, lv, [lv; 4]);
                while b.sheet.len() < 3 && b.status == "playing" {
                    let t0 = Instant::now();
                    let ph = b.g.phase;
                    let left: u32 = b.g.hands.iter().map(|&h| cnt(h)).sum();
                    step_any(&mut b);
                    let dt = t0.elapsed().as_micros();
                    if dt > 150_000 {
                        eprintln!("  slow {lv:?} {ph:?} cards_left {left}: {:.1} ms", dt as f64 / 1000.0);
                    }
                    if lv == Lv::Hard && ph == Phase::Play && b.mc_stats[0] > 0 && left >= 44 {
                        early[0] += b.mc_stats[0];
                        early[1] += b.mc_stats[1];
                    }
                    b.mc_stats = [0; 2];
                    worst = worst.max(dt);
                    total += dt;
                    n += 1;
                }
                fb += b.fallbacks;
            }
            eprintln!(
                "{lv:?}: {n} decisions, avg {:.1} ms, worst {:.1} ms, budget fallbacks {fb}, early MC worlds solved {}/{}",
                total as f64 / n as f64 / 1000.0,
                worst as f64 / 1000.0,
                early[1],
                early[0]
            );
        }
    }
}
