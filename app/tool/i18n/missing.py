#!/usr/bin/env python3
"""Lists Clever Place texts wrapped in t('…') / tf('…', …) that have no English entry yet.

Usage: python3 tool/i18n/missing.py [path ...]   (default: lib/clever)
Reads the dictionaries in lib/clever/i18n/en_*.dart. Exit code 1 when something is missing.
"""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
LIT = r"'((?:[^'\\]|\\.)*)'"
# One literal, or adjacent literals Dart joins into one ('a ' 'b').
CALL = re.compile(r"\b(?:t|tf)\(\s*(" + LIT + r"(?:\s*" + LIT + r")*)")
PART = re.compile(LIT)
ENTRY = re.compile(r"^\s*" + LIT + r"\s*:", re.M)

def unescape(s):
    return re.sub(r"\\(.)", lambda m: {'n': '\n', 't': '\t'}.get(m.group(1), m.group(1)), s)

keys = set()
for f in (ROOT / 'lib/clever/i18n').glob('en_*.dart'):
    keys |= {unescape(k) for k in ENTRY.findall(f.read_text())}
paths = [pathlib.Path(p).resolve() for p in sys.argv[1:]] or [ROOT / "lib/clever"]
missing = []
for p in paths:
    for f in ([p] if p.is_file() else sorted(p.rglob('*.dart'))):
        if '/i18n/' in str(f):
            continue
        for m in CALL.finditer(f.read_text()):
            k = ''.join(unescape(x) for x in PART.findall(m.group(1)))
            if k not in keys:
                missing.append((f.relative_to(ROOT), k))
for f, k in missing:
    print(f'{f}: {k!r}')
print(f'{len(missing)} missing, {len(keys)} entries', file=sys.stderr)
sys.exit(1 if missing else 0)
