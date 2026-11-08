#!/usr/bin/env python3
"""Mechanical checks for the Sözel ve Sosyal Zeka question bank.

Usage:
  python3 -I app/tool/verbal_social/check.py app/tool/verbal_social/src/sozel.json   # one section source
  python3 -I app/tool/verbal_social/check.py app/assets/verbal_social/items.json     # the merged bank

Prints every problem (FAIL = must fix, WARN = look at it) and the per-section statistics: counts per
subtype and difficulty, answer positions, and how often the correct option is the longest / shortest.
Exit code 1 when there is any FAIL. The Rust test in core/src/games/verbal_social.rs repeats the
hard checks on the merged bank.
"""

import json
import re
import sys
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path

SUBTYPES = {
    "sozel": ["analoji", "farkli_olan", "baglac", "deyim_atasozu", "es_zit_anlam", "paragraf_cikarim", "cumle_siralama"],
    "sosyal": ["zihin_kurami", "pot", "dolayli_anlatim", "durum_okuma", "sohbet", "ton"],
    "duygusal": ["duygu_anlama", "duygu_yonetimi", "duygu_sozcukleri", "duzenleme"],
}
PREFIX = {"sozel": "soz", "sosyal": "sos", "duygusal": "duy"}
TARGET_SUBTYPES = {
    "sozel": {"analoji": 25, "farkli_olan": 20, "baglac": 20, "deyim_atasozu": 25, "es_zit_anlam": 25,
              "paragraf_cikarim": 20, "cumle_siralama": 15},
    "sosyal": {"zihin_kurami": 30, "pot": 25, "dolayli_anlatim": 25, "durum_okuma": 25, "sohbet": 25, "ton": 20},
    "duygusal": {"duygu_anlama": 45, "duygu_yonetimi": 45, "duygu_sozcukleri": 30, "duzenleme": 30},
}
# Orta items fill levels 1–22 exactly (see the level builder): 74 / 73 / 73.
TARGET_ORTA = {"sozel": 74, "sosyal": 73, "duygusal": 73}

MAX_PROMPT_WORDS = 70
MAX_OPTION_WORDS = 22
MAX_WHY_WORDS = 75
LEN_SLACK = 3
MAX_EXTREME_PCT = 25
BANNED_OPTIONS =["hepsi", "hiçbiri", "yukarıdaki", "a ve b", "b ve c", "ikisi de"]
BANNED_GLYPHS = "→←↑↓●★☆♥✓✗✔✘•"


def jost_cmap():
    try:
        from fontTools.ttLib import TTFont  # optional
    except ImportError:
        return None
    root = Path(__file__).resolve().parents[2]
    cmap = set()
    for w in ["Regular", "SemiBold"]:
        cmap |= set(TTFont(root / f"assets/fonts/Jost-{w}.ttf").getBestCmap().keys())
    return cmap


def length_profile(it):
    """(correct option length, [distractor lengths]) in characters."""
    opts = it["options"]
    return len(opts[it["answer"]]), [len(o) for k, o in enumerate(opts) if k != it["answer"]]


def length_ok(c, others):
    """No length giveaway: the correct option stays within 0.75–1.33× the mean distractor length.
    Very short options (single words) may instead differ from that mean by at most LEN_SLACK chars."""
    mean = sum(others) / len(others)
    return 0.75 * mean <= c <= 1.33 * mean or abs(c - mean) <= LEN_SLACK


def words(s):
    return len(s.split())


def norm(s):
    s = unicodedata.normalize("NFC", s).lower()
    return re.sub(r"[^\wçğıöşüâîû]+", " ", s).strip()


def main(path):
    items = json.loads(Path(path).read_text(encoding="utf-8"))
    cmap = jost_cmap()
    source = Path(path).resolve().parent.name == "src"
    fails, warns = [], []
    seen_ids, seen_prompts = {}, {}
    by_sec = defaultdict(list)
    for n, it in enumerate(items):
        iid = it.get("id", f"#{n}")
        sec = it.get("section")
        if iid in seen_ids:
            fails.append(f"{iid}: duplicate id")
        seen_ids[iid] = 1
        keys = {"id", "section", "subtype", "difficulty", "prompt", "options", "answer", "why"}
        extra = set(it) - keys
        missing = keys - set(it)
        if missing:
            fails.append(f"{iid}: missing fields {sorted(missing)}")
            continue
        if extra:
            fails.append(f"{iid}: unknown fields {sorted(extra)}")
        if sec not in SUBTYPES:
            fails.append(f"{iid}: bad section {sec!r}")
            continue
        if not str(iid).startswith(PREFIX[sec] + "-"):
            fails.append(f"{iid}: id must start with {PREFIX[sec]}-")
        if it["subtype"] not in SUBTYPES[sec]:
            fails.append(f"{iid}: bad subtype {it['subtype']!r} for {sec}")
        if it["difficulty"] not in ("orta", "zor"):
            fails.append(f"{iid}: bad difficulty {it['difficulty']!r}")
        opts = it["options"]
        if not isinstance(opts, list) or len(opts) != 4 or not all(isinstance(o, str) and o.strip() for o in opts):
            fails.append(f"{iid}: need exactly 4 non-empty string options")
            continue
        if len({norm(o) for o in opts}) != 4:
            fails.append(f"{iid}: options not distinct")
        if not isinstance(it["answer"], int) or not 0 <= it["answer"] < 4:
            fails.append(f"{iid}: answer out of range")
            continue
        if source and it["answer"] != 0:
            # Sources keep the correct option first; assign_positions.py places it.
            fails.append(f"{iid}: in a source file the correct option must be options[0] (answer 0)")
        p = norm(it["prompt"])
        if p in seen_prompts:
            fails.append(f"{iid}: duplicate prompt of {seen_prompts[p]}")
        seen_prompts[p] = iid
        if words(it["prompt"]) > MAX_PROMPT_WORDS:
            fails.append(f"{iid}: prompt has {words(it['prompt'])} words (max {MAX_PROMPT_WORDS})")
        for o in opts:
            if words(o) > MAX_OPTION_WORDS:
                fails.append(f"{iid}: option has {words(o)} words (max {MAX_OPTION_WORDS}): {o[:40]}")
            if any(b == norm(o) or norm(o).startswith(b + " ") for b in BANNED_OPTIONS):
                fails.append(f"{iid}: option refers to other options: {o}")
        why = it["why"]
        if not why.strip():
            fails.append(f"{iid}: empty why")
        if words(why) > MAX_WHY_WORDS:
            warns.append(f"{iid}: why has {words(why)} words")
        sentences = len(re.findall(r"[.!?…](\s|$)", why.strip()))
        if sentences > 3:
            warns.append(f"{iid}: why has {sentences} sentences (aim 1–3)")
        text = it["prompt"] + "".join(opts) + why
        bad = [c for c in text if c in BANNED_GLYPHS]
        if bad:
            fails.append(f"{iid}: glyphs Jost lacks: {''.join(sorted(set(bad)))}")
        if cmap is not None:
            miss = sorted({c for c in text if c not in "\n" and ord(c) not in cmap})
            if miss:
                fails.append(f"{iid}: characters missing from Jost: {miss}")
        if "  " in it["prompt"].replace("\n", " ") and "::" not in it["prompt"]:
            warns.append(f"{iid}: double space in prompt")
        by_sec[sec].append(it)

    for sec, its in by_sec.items():
        print(f"== {sec}: {len(its)} items")
        sub = Counter(i["subtype"] for i in its)
        dif = Counter(i["difficulty"] for i in its)
        for s in SUBTYPES[sec]:
            sd = Counter(i["difficulty"] for i in its if i["subtype"] == s)
            print(f"   {s:18} {sub[s]:3}  (orta {sd['orta']}, zor {sd['zor']})  target {TARGET_SUBTYPES[sec][s]}")
        print(f"   difficulty: orta {dif['orta']}, zor {dif['zor']}  (target orta {TARGET_ORTA[sec]})")
        pos = Counter(i["answer"] for i in its)
        print(f"   answer positions: {[pos[k] for k in range(4)]}")
        longest = shortest = 0
        for i in its:
            c, others = length_profile(i)
            if c > max(others):
                longest += 1
            if c < min(others):
                shortest += 1
            if not length_ok(c, others):
                mean = sum(others) / 3
                fails.append(f"{i['id']}: correct option length {c} vs distractor mean {mean:.1f} "
                             f"(ratio {c / mean:.2f}; keep 0.75–1.33 or within {LEN_SLACK} chars)")
        print(f"   correct is strictly longest: {longest} = {100 * longest / len(its):.0f}%  (max {MAX_EXTREME_PCT}%)")
        print(f"   correct is strictly shortest: {shortest} = {100 * shortest / len(its):.0f}%  (max {MAX_EXTREME_PCT}%)")
        for name, n in [("longest", longest), ("shortest", shortest)]:
            if n * 100 > MAX_EXTREME_PCT * len(its):
                fails.append(f"{sec}: correct option is strictly the {name} in {100 * n / len(its):.0f}% of items (max {MAX_EXTREME_PCT}%)")
        if len(its) == 150:
            for s, t in TARGET_SUBTYPES[sec].items():
                if sub[s] != t:
                    warns.append(f"{sec}: subtype {s} has {sub[s]}, target {t}")
            if dif["orta"] != TARGET_ORTA[sec]:
                fails.append(f"{sec}: {dif['orta']} orta items, need exactly {TARGET_ORTA[sec]}")

    for w in warns:
        print("WARN", w)
    for f in fails:
        print("FAIL", f)
    print(f"{len(fails)} FAIL, {len(warns)} WARN")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
