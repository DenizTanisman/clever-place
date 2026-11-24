#!/usr/bin/env python3
"""Build app/assets/zihin_asisi/bank.json from app/tool/zihin_asisi/{techniques.json,src/*.json}.

In the sources the correct option is always options[0]. Each set of 10 gets exact position quotas
(two positions three times, two positions twice), shuffled with a fixed seed. Never hand-place an
answer: edit the source and rerun this script.

Usage: python3 -I app/tool/zihin_asisi/build.py
"""

import json
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]  # app/
HERE = ROOT / "tool/zihin_asisi"
OUT = ROOT / "assets/zihin_asisi/bank.json"
SEED = 20261109
FIELDS = ["id", "set", "technique", "kind", "difficulty", "sender", "message", "ask", "options", "answer", "why"]


def main():
    techniques = json.loads((HERE / "techniques.json").read_text(encoding="utf-8"))
    rng = random.Random(SEED)
    out, problems = [], []
    for f in sorted((HERE / "src").glob("*.json")):
        items = json.loads(f.read_text(encoding="utf-8"))
        for start in range(0, len(items), 10):
            chunk = items[start:start + 10]
            quota = [p for p in range(4) for _ in range(len(chunk) // 4)] + rng.sample(range(4), len(chunk) % 4)
            rng.shuffle(quota)
            for it, pos in zip(chunk, quota):
                it = {**it, "answer": 0}
                correct, rest = it["options"][0], it["options"][1:]
                ratio = len(correct) / (sum(map(len, rest)) / 3)
                if not 0.6 <= ratio <= 1.45:
                    problems.append(f"{it['id']}: uzunluk oranı {ratio:.2f}")
                out.append({**{k: it[k] for k in FIELDS}, "options": rest[:pos] + [correct] + rest[pos:], "answer": pos})
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps({"techniques": techniques, "items": out}, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{len(techniques)} teknik, {len(out)} madde: {OUT}")
    for p in problems:
        print("SORUN", p)
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
