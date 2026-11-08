#!/usr/bin/env python3
"""Merge the three section sources into app/assets/verbal_social/items.json, placing each correct
option at a randomly assigned position with exact quotas.

In the sources the correct option is always options[0]. For every (section, difficulty) group of N
items, the quota list holds each position 0..3 exactly N // 4 times. The N % 4 leftover slots go to
distinct positions picked at random, so the counts differ by at most 1. The list is shuffled with a
fixed seed and dealt to the items in id order. The correct option is inserted at its position and
the three distractors keep their authored order. Never hand-place an answer: edit the source and
rerun this script.

Usage: python3 -I app/tool/verbal_social/assign_positions.py
"""

import json
import random
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]  # app/
SRC = ROOT / "tool/verbal_social/src"
OUT = ROOT / "assets/verbal_social/items.json"
SECTIONS = ["sozel", "sosyal", "duygusal"]
SEED = 20261106
FIELDS = ["id", "section", "subtype", "difficulty", "prompt", "options", "answer", "why"]


def main():
    items = []
    for s in SECTIONS:
        src = json.loads((SRC / f"{s}.json").read_text(encoding="utf-8"))
        for it in src:
            assert it["answer"] == 0, f"{it['id']}: source answer must be 0"
        items += sorted(src, key=lambda i: i["id"])
    rng = random.Random(SEED)
    groups = defaultdict(list)
    for it in items:
        groups[(it["section"], it["difficulty"])].append(it)
    out = []
    for key in sorted(groups):
        group = groups[key]
        n = len(group)
        quota = [p for p in range(4) for _ in range(n // 4)] + rng.sample(range(4), n % 4)
        rng.shuffle(quota)
        for it, pos in zip(group, quota):
            correct, distractors = it["options"][0], it["options"][1:]
            opts = distractors[:pos] + [correct] + distractors[pos:]
            out.append({**{k: it[k] for k in FIELDS}, "options": opts, "answer": pos})
        print(key, n, sorted(Counter(quota).items()))
    order = {s: i for i, s in enumerate(SECTIONS)}
    out.sort(key=lambda i: (order[i["section"]], i["id"]))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"wrote {len(out)} items to {OUT}")


if __name__ == "__main__":
    main()
