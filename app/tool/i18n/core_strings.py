#!/usr/bin/env python3
"""Builds lib/clever/i18n/en_core.dart: English for the Turkish text the Rust core writes.

The core (../core/src) puts Turkish text into game state (goal, title, summary, labels, reasons …)
and into refusal messages. The app shows those through ct() (lib/clever/i18n/lang.dart), which looks
them up in enCoreExact (whole lines) and enCoreTemplates (lines with `{}` holes).

This script
  1. reads every .rs file under core/src and pulls out the user-visible string literals: format
     strings of format!/write! (holes {}, {:.1}, {name}, {0}, {:>2} … become `{}`, `{{`/`}}` become
     braces) and plain literals. Test code, asserts, panics, expect(), println!, JSON keys, indexes
     (a["key"]), match patterns and comparisons are skipped, and so is text that is not Turkish
     (ids, English developer messages).
  2. reads the translations in tool/i18n/core_en.json:
       "exact":      {turkish: english}          lines without holes
       "templates":  [[turkish, english], …]     lines with holes; English may use {0}, {1} … to reorder
       "keep":       [turkish, …]                left Turkish on purpose (language-bound content)
       "keep_rules": [{"file", "all"|"in", "why"}] content left Turkish by place: a whole file ("all": true)
                                                 or literals inside the given calls/macros/struct
                                                 literals or const/static items ("in": ["const", "pt"]);
                                                 strings listed in exact/templates are still translated
       "ignore":     [turkish, …]                not shown to the player (or nothing to translate)
     Entries in exact/templates that the core does not contain (composed lines, words that reach the
     app through a hole) are kept as written.
  3. writes lib/clever/i18n/en_core.dart (templates ordered most specific first: more literal text
     first, because the first matching template wins) and reports core strings with no entry yet.

Usage (from app/):
  python3 tool/i18n/core_strings.py            write en_core.dart, report missing strings
  python3 tool/i18n/core_strings.py --check    only report (exit 1 when something is missing)
  python3 tool/i18n/core_strings.py --dump F   also write every extracted string with file:line to F (JSON)
  python3 tool/i18n/core_strings.py --stale    also list JSON entries the core no longer contains
  --json A --json B   read these translation files (merged in order) instead of tool/i18n/core_en.json
  --files games/x.rs,games/iq/   report (and dump) only strings found in these files / folders
"""
import json
import pathlib
import re
import sys

APP = pathlib.Path(__file__).resolve().parents[2]
CORE = APP.parent / 'core' / 'src'
JSON_PATH = pathlib.Path(__file__).with_name('core_en.json')
DART_PATH = APP / 'lib' / 'clever' / 'i18n' / 'en_core.dart'

# ---------------------------------------------------------------------------------------------- lexer

RAW = re.compile(r'(b?r)(#*)"')
CHAR = re.compile(r"b?'(?:\\(?:x[0-9a-fA-F]{2}|u\{[0-9a-fA-F_]+\}|.)|[^\\'\n])'")
LIFETIME = re.compile(r"'[A-Za-z_]\w*")
IDENT = re.compile(r'(?:r#)?[A-Za-z_]\w*')
NUMBER = re.compile(r'\d[\w]*(?:\.\d[\w]*)?')
PUNCT = ('..=', '...', '=>', '==', '!=', '::', '->', '..', '<=', '>=', '&&', '||', '+=', '-=', '*=', '/=', '%=',
         '<<', '>>')
ESC = {'n': '\n', 't': '\t', 'r': '\r', '0': '\0', '\\': '\\', '"': '"', "'": "'"}


def lex(src):
    """Tokens of a Rust source: (kind, value, line). kind: str, ident, num, char, punct."""
    toks, i, n, line = [], 0, len(src), 1
    while i < n:
        c = src[i]
        if c == '\n':
            line += 1
            i += 1
            continue
        if c.isspace():
            i += 1
            continue
        if src.startswith('//', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
            continue
        if src.startswith('/*', i):
            depth, j = 1, i + 2
            while j < n and depth:
                if src.startswith('/*', j):
                    depth, j = depth + 1, j + 2
                elif src.startswith('*/', j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            line += src.count('\n', i, j)
            i = j
            continue
        m = RAW.match(src, i)
        if m:
            end = '"' + m.group(2)
            j = src.find(end, m.end())
            body = src[m.end():j]
            toks.append(('str', body, line, 'raw'))
            line += src.count('\n', i, j)
            i = j + len(end)
            continue
        if c == '"' or (c == 'b' and src.startswith('b"', i)):
            j = i + (2 if c == 'b' else 1)
            out = []
            start_line = line
            while src[j] != '"':
                ch = src[j]
                if ch == '\\':
                    e = src[j + 1]
                    if e == '\n':  # line continuation: skip the newline and the indentation
                        j += 1
                        while src[j].isspace():
                            if src[j] == '\n':
                                line += 1
                            j += 1
                        continue
                    if e == 'x':
                        out.append(chr(int(src[j + 2:j + 4], 16)))
                        j += 4
                        continue
                    if e == 'u':
                        k = src.index('}', j)
                        out.append(chr(int(src[j + 3:k].replace('_', ''), 16)))
                        j = k + 1
                        continue
                    out.append(ESC.get(e, e))
                    j += 2
                    continue
                if ch == '\n':
                    line += 1
                out.append(ch)
                j += 1
            toks.append(('str', ''.join(out), start_line, 'byte' if c == 'b' else 'plain'))
            i = j + 1
            continue
        if c == "'" or (c == 'b' and src.startswith("b'", i)):
            m = CHAR.match(src, i)
            if m:
                toks.append(('char', m.group(0), line, ''))
                i = m.end()
                continue
            m = LIFETIME.match(src, i)
            if m:
                toks.append(('ident', m.group(0), line, ''))
                i = m.end()
                continue
        m = IDENT.match(src, i)
        if m:
            toks.append(('ident', m.group(0), line, ''))
            i = m.end()
            continue
        m = NUMBER.match(src, i)
        if m:
            toks.append(('num', m.group(0), line, ''))
            i = m.end()
            continue
        for p in PUNCT:
            if src.startswith(p, i):
                toks.append(('punct', p, line, ''))
                i += len(p)
                break
        else:
            toks.append(('punct', c, line, ''))
            i += 1
    return toks


# --------------------------------------------------------------------------------------- extraction

OPEN = {'(': ')', '[': ']', '{': '}'}
CLOSE = set(OPEN.values())
FORMAT_FIRST = {'format!', 'panic!', 'print!', 'println!', 'eprint!', 'eprintln!', 'format_args!', 'unreachable!',
                'todo!', 'unimplemented!'}
FORMAT_SECOND = {'write!', 'writeln!'}
# Text inside these never reaches the player.
SKIP_FRAMES = {'assert!', 'assert_eq!', 'assert_ne!', 'debug_assert!', 'debug_assert_eq!', 'debug_assert_ne!',
               'panic!', 'unreachable!', 'todo!', 'unimplemented!', 'expect', 'expect_err', 'unwrap_or_else_panic',
               'println!', 'eprintln!', 'print!', 'eprint!', 'dbg!', 'include_str!', 'env!', 'matches!', 'cfg!',
               'seed_for', 'starts_with', 'ends_with', 'contains', 'strip_prefix', 'strip_suffix', 'split',
               'split_once', 'rsplit', 'find', 'rfind', 'trim_start_matches', 'trim_end_matches', 'matches',
               'get', 'remove', 'contains_key', 'entry', 'pointer'}
KEYWORDS = {'in', 'return', 'if', 'else', 'match', 'let', 'mut', 'for', 'while', 'loop', 'move', 'break', 'as',
            'where', 'impl', 'fn', 'pub', 'const', 'static', 'use', 'mod', 'struct', 'enum', 'type', 'ref', 'dyn',
            'unsafe', 'continue', 'yield', 'await'}
HOLE = re.compile(r'\{\{|\}\}|\{[^{}]*\}')


def test_mask(toks):
    """True for every token inside an item marked #[cfg(test)] or #[test]; also the names of test-only
    modules declared as `#[cfg(test)] mod name;`."""
    mask = [False] * len(toks)
    test_mods = set()
    k = 0
    while k < len(toks):
        v = [t[1] for t in toks[k:k + 7]]
        is_cfg = v[:7] == ['#', '[', 'cfg', '(', 'test', ')', ']']
        is_test = v[:4] == ['#', '[', 'test', ']']
        if not (is_cfg or is_test):
            k += 1
            continue
        start = k
        j = k + (7 if is_cfg else 4)
        depth = 0
        while j < len(toks):
            t = toks[j][1] if toks[j][0] == 'punct' else None
            if t in ('(', '['):
                depth += 1
            elif t in (')', ']'):
                depth -= 1
            elif depth == 0 and t == ';':
                if toks[j - 2][1] == 'mod':
                    paths = [toks[q + 2][1] for q in range(start, j) if toks[q][1] == 'path' and toks[q + 2][0] == 'str']
                    test_mods.add(paths[0] if paths else toks[j - 1][1] + '.rs')
                break
            elif depth == 0 and t == '{':
                d = 0
                while j < len(toks):
                    t2 = toks[j][1] if toks[j][0] == 'punct' else None
                    if t2 in OPEN:
                        d += 1
                    elif t2 in CLOSE:
                        d -= 1
                        if d == 0:
                            break
                    j += 1
                break
            j += 1
        for q in range(start, min(j + 1, len(toks))):
            mask[q] = True
        k = j + 1
    return mask, test_mods


def normalize_format(s):
    """A Rust format string as a ct() template: every hole becomes `{}`, `{{`/`}}` become braces."""
    return HOLE.sub(lambda m: '{' if m.group(0) == '{{' else '}' if m.group(0) == '}}' else '{}', s)


def extract_file(path):
    """(text, is_template, line, context) for every candidate literal of one file, plus test-only module names."""
    toks = lex(path.read_text(encoding='utf-8'))
    mask, test_mods = test_mask(toks)
    out = []
    stack = []  # frames: [open char, label, commas, is_index, last json key]
    const_depth = None  # stack depth of the const/static item being read, if any
    for k, tok in enumerate(toks):
        kind, val, line, flavour = tok
        prev = toks[k - 1] if k else ('', '', 0, '')
        nxt = toks[k + 1] if k + 1 < len(toks) else ('', '', 0, '')
        if kind == 'ident' and val in ('const', 'static') and const_depth is None and nxt[0] == 'ident' \
                and k + 2 < len(toks) and toks[k + 2][1] == ':':
            const_depth = len(stack)
        elif kind == 'punct' and val == ';' and const_depth == len(stack):
            const_depth = None
        if kind == 'punct' and val in OPEN:
            label, is_index = '', False
            if prev[1] == '!' and k >= 2 and toks[k - 2][0] == 'ident':
                label = toks[k - 2][1] + '!'
            elif prev[0] == 'ident' and prev[1] not in KEYWORDS:
                label = prev[1]
                is_index = val == '['
            elif val == '[' and prev[1] in (')', ']', '?'):
                is_index = True
            stack.append([val, label, 0, is_index, None])
            continue
        if kind == 'punct' and val in CLOSE:
            if stack:
                stack.pop()
            continue
        if kind == 'punct' and val == ',' and stack:
            stack[-1][2] += 1
            continue
        if kind != 'str' or flavour == 'byte' or mask[k]:
            continue
        frame = stack[-1] if stack else None
        if nxt[1] == ':' and nxt[0] == 'punct':  # JSON key
            if frame is not None:
                frame[4] = val
            continue
        if any(f[1] in SKIP_FRAMES for f in stack):
            continue
        if frame is not None and frame[3] and prev[1] == '[' and nxt[1] == ']':
            continue
        if prev[1] in ('==', '!=') or nxt[1] in ('==', '!=', '=>', '|') or (prev[1] == '|' and toks[k - 2][0] == 'str'):
            continue
        is_fmt = False
        if frame is not None and flavour in ('plain', 'raw'):
            if frame[1] in FORMAT_FIRST and frame[2] == 0 and prev[1] == '(':
                is_fmt = True
            elif frame[1] in FORMAT_SECOND and frame[2] == 1 and prev[1] == ',':
                is_fmt = True
        text = normalize_format(val) if is_fmt else val
        ctx = next((f[4] for f in reversed(stack) if f[4]), '') or next((f[1] for f in reversed(stack) if f[1]), '')
        frames = {f[1] for f in stack if f[1]} | ({'const'} if const_depth is not None else set())
        out.append((text, is_fmt and '{}' in text, line, ctx, frames))
    return out, test_mods


# ------------------------------------------------------------------------------------- what is Turkish

TR_CHARS = set('çğıöşüÇĞİÖŞÜâîûÂÎÛ')
TR_WORDS = {'ve', 'bu', 'bir', 'ile', 'yok', 'var', 'daha', 'her', 'hiç', 'da', 'de', 'ki', 'mi', 'ya', 'sen',
            'ben', 'sira', 'hamle', 'kez', 'tur', 'puan', 'el', 'kart', 'oyun', 'bolum', 'yeni', 'zaten', 'olmali',
            'gecersiz', 'bilinmeyen', 'eksik', 'bitti', 'kolay', 'orta', 'zor', 'uzman', 'usta', 'tas', 'kutu',
            'kutuda', 'rakam', 'sayi', 'dogru', 'yanlis', 'hata', 'ipucu', 'sure', 'skor', 'rakip', 'sonra', 'once',
            'kalan', 'toplam', 'en', 'iyi', 'seri', 'adim', 'soru', 'cevap', 'renk', 'kirmizi', 'mavi', 'yesil',
            'sari', 'siyah', 'beyaz', 'kazandin', 'kaybettin', 'berabere', 'sende', 'pas', 'kapali', 'acik',
            'sinir', 'bekle', 'dur', 'bas', 'tikla', 'sec', 'al', 'at', 'koy', 'ver'}
EN_WORDS = {'the', 'a', 'an', 'of', 'to', 'is', 'not', 'no', 'must', 'be', 'for', 'and', 'unknown', 'bad',
            'missing', 'invalid', 'game', 'level', 'mode', 'json', 'id', 'with', 'out', 'range', 'expected', 'empty',
            'unique', 'index', 'should', 'cannot', "can't", 'has', 'have', 'was', 'are', 'this', 'that', 'from',
            'only', 'already', 'over', 'action', 'cell', 'move', 'state', 'session', 'none', 'need', 'needs',
            'requires', 'too', 'many', 'few', 'wrong', 'player', 'card', 'turn', 'not', 'yet', 'got', 'found',
            'endless', 'support', 'supported', 'parse', 'error', 'failed', 'value', 'options', 'option', 'solutions',
            'duplicate', 'mismatch', 'floating', 'predicts', 'intended', 'oracle', 'says', 'answer', 'fitting',
            'series', 'typed', 'templates', 'mixed', 'palette', 'outside', 'frame', 'request', 'null', 'shape',
            'values', 'query', 'correct', 'grammar', 'predictions', 'balancing', 'outline', 'solution', 'solver',
            'puzzle', 'grid', 'seed', 'attempt', 'attempts', 'generator', 'unsolvable', 'overflow', 'debug'}


def fold(w):
    return w.lower().translate(str.maketrans('çğıöşüâîû', 'cgiosuaiu'))


def classify(text):
    """'tr' for player-facing Turkish, 'en' for English (developer) text, '' for ids and the like."""
    bare = text.replace('{}', ' ')
    if not re.search(r'[A-Za-zÀ-ž]', bare):
        return ''
    if any(ch in TR_CHARS for ch in bare):
        return 'tr'
    words = re.findall(r"[A-Za-z']+", bare)
    folded = [fold(w) for w in words]
    en = sum(w in EN_WORDS for w in folded)
    tr = sum(w in TR_WORDS for w in folded)
    if en > tr:
        return 'en'
    if tr:
        return 'tr'
    if len(words) == 1 and re.fullmatch(r'[a-z0-9_.\-/]+', text):  # ids, keys, file names
        return ''
    if re.fullmatch(r'[A-Za-z0-9_.\-/:#]+', text) and not re.fullmatch(r'[A-Z][a-z]+', text):
        return ''  # CamelCase, ids, codes
    return 'tr?'


def extract_all():
    """{text: {'tpl': bool, 'where': [file:line], 'ctx': set, 'cls': str}} for the whole core."""
    files = sorted(CORE.rglob('*.rs'))
    per_file = {f: extract_file(f) for f in files}
    test_files = set()
    for f, (_, mods) in per_file.items():
        for m in mods:
            if '/' in m or m != pathlib.Path(m).name or not m.endswith('.rs'):
                continue
            base = f.parent if f.name in ('mod.rs', 'lib.rs') or m in {x.name for x in f.parent.iterdir()} \
                else f.parent / f.stem
            test_files |= {base / m, base / m[:-3] / 'mod.rs'}
    found = {}
    for f, (items, _) in per_file.items():
        if f in test_files:
            continue
        rel = str(f.relative_to(CORE))
        for text, tpl, line, ctx, frames in items:
            cls = classify(text)
            if not cls or cls == 'en':
                continue
            e = found.setdefault(text, {'tpl': tpl, 'where': [], 'ctx': set(), 'cls': cls, 'occ': []})
            e['tpl'] = e['tpl'] or tpl
            e['where'].append(f'{rel}:{line}')
            e['occ'].append((rel, frames))
            if ctx:
                e['ctx'].add(ctx)
    return found


def kept_by_rules(e, rules):
    """True when every place the string appears is covered by a keep rule: {"file": …, "all": true} or
    {"file": …, "in": [frame labels or "const"]}."""
    def covered(rel, frames):
        return any(r['file'] == rel and (r.get('all') or frames & set(r.get('in', []))) for r in rules)
    return all(covered(rel, frames) for rel, frames in e['occ'])


# -------------------------------------------------------------------------------------------- output

def dart_str(s):
    s = s.replace('\\', '\\\\').replace("'", "\\'").replace('$', '\\$').replace('\n', '\\n').replace('\t', '\\t')
    return f"'{s}'"


def literal_len(tpl):
    return len(re.sub(r'\{\d*\}', '', tpl))


def holes(s):
    return len(re.findall(r'\{\d*\}', s))


def write_dart(exact, templates):
    lines = [
        '// English for the text the Rust core writes (goal lines, summaries, refusals, labels). See lang.dart.',
        '// Generated from core/src by tool/i18n/core_strings.py and translated; edit the translations in',
        '// tool/i18n/core_en.json and run the script again (python3 tool/i18n/core_strings.py).',
        '',
        '/// Lines without holes.',
        'const Map<String, String> enCoreExact = {',
    ]
    for tr in sorted(exact, key=lambda s: (fold(s), s)):
        lines.append(f'  {dart_str(tr)}: {dart_str(exact[tr])},')
    lines += [
        '};',
        '',
        '/// Lines with `{}` holes (Rust format holes, in order) or `{0}`, `{1}` … when English needs another order.',
        '/// Most specific first: the first template that matches wins.',
        'const List<(String, String)> enCoreTemplates = [',
    ]
    for tr, en in templates:
        lines.append(f'  ({dart_str(tr)}, {dart_str(en)}),')
    lines += ['];', '']
    DART_PATH.write_text('\n'.join(lines), encoding='utf-8')


def load_json(path, problems):
    def pairs(items):
        d = {}
        for k, v in items:
            if k in d and d[k] != v:
                problems.append(f'{path.name}: key listed twice with different values: {k!r}')
            d[k] = v
        return d
    return json.loads(path.read_text(encoding='utf-8'), object_pairs_hook=pairs) if path.exists() else {}


def other_dictionaries():
    """{turkish: english} of the other lib/clever/i18n/en_*.dart maps (ct() sees them too)."""
    lit = r"'((?:[^'\\]|\\.)*)'"
    entry = re.compile(r"^\s*" + lit + r"\s*:\s*" + lit + r"\s*,", re.M)
    unesc = lambda x: re.sub(r'\\(.)', lambda m: {'n': '\n', 't': '\t'}.get(m.group(1), m.group(1)), x)
    out = {}
    for f in sorted(DART_PATH.parent.glob('en_*.dart')):
        if f != DART_PATH:
            for k, v in entry.findall(f.read_text(encoding='utf-8')):
                out[unesc(k)] = (unesc(v), f.name)
    return out


def others_for_warn():
    return other_dictionaries()


def main(argv):
    check = '--check' in argv
    arg = lambda name: [argv[i + 1] for i, a in enumerate(argv) if a == name and i + 1 < len(argv)]
    dump = (arg('--dump') or [None])[0]
    only = [x for a in arg('--files') for x in a.split(',') if x]
    problems = []
    exact, tdict, keep, keep_rules, ignore = {}, {}, set(), [], set()
    for src in [pathlib.Path(x) for x in arg('--json')] or [JSON_PATH]:
        data = load_json(src, problems)
        for tr, en in data.get('exact', {}).items():
            if tr in exact and exact[tr] != en:
                problems.append(f'{src.name}: exact {tr!r} is {en!r} here but {exact[tr]!r} before')
            exact[tr] = en
        for tr, en in data.get('templates', []):
            if tr in tdict and tdict[tr] != en:
                problems.append(f'{src.name}: template {tr!r} is {en!r} here but {tdict[tr]!r} before')
            tdict[tr] = en
        keep |= set(data.get('keep', []))
        keep_rules += data.get('keep_rules', [])
        ignore |= set(data.get('ignore', []))

    for tr, en in tdict.items():
        if not re.sub(r'\{\d*\}', '', tr).strip():
            problems.append(f'template is only holes: {tr!r}')
        if holes(tr) == 0:
            problems.append(f'template without holes (put it in exact): {tr!r}')
        used = re.findall(r'\{(\d*)\}', en)
        if any(u for u in used) and any(not u for u in used):
            problems.append(f'template mixes {{}} and {{n}}: {en!r}')
        if any(u and int(u) >= holes(tr) for u in used):
            problems.append(f'template uses a hole it does not have: {en!r}')
        if not any(u for u in used) and len(used) != holes(tr):
            problems.append(f'template hole count differs ({holes(tr)} vs {len(used)}): {tr!r} -> {en!r}')
    for tr, en in exact.items():
        if not tr or not en:
            problems.append(f'empty exact key or value: {tr!r}')
        if re.search(r'\{\d*\}', tr):
            problems.append(f'exact entry with a hole (put it in templates): {tr!r}')
    warnings = []
    for tr, (en, fname) in others_for_warn().items():
        if tr in exact and exact[tr] != en:
            warnings.append(f'{tr!r}: {exact[tr]!r} here overrides {en!r} in {fname}')

    found = extract_all()
    others = other_dictionaries()
    missing = []
    for text, e in sorted(found.items(), key=lambda kv: kv[1]['where'][0]):
        if text in exact or text in tdict or text in keep or text in ignore or text in others:
            continue  # (the other en_*.dart maps are part of ct()'s dictionary too)
        if kept_by_rules(e, keep_rules):
            continue
        if only and not any(w.startswith(o) for w in e['where'] for o in only):
            continue
        missing.append((text, e))

    if dump:
        rows = [{'text': t, 'template': e['tpl'], 'class': e['cls'], 'where': e['where'], 'ctx': sorted(e['ctx']),
                 'frames': sorted(set().union(*(f for _, f in e['occ']))), 'done': t in exact or t in tdict,
                 'kept': t in keep or kept_by_rules(e, keep_rules), 'ignored': t in ignore}
                for t, e in sorted(found.items(), key=lambda kv: kv[1]['where'][0])
                if not only or any(w.startswith(o) for w in e['where'] for o in only)]
        pathlib.Path(dump).write_text(json.dumps(rows, ensure_ascii=False, indent=1), encoding='utf-8')

    if not check and not problems:
        ordered = sorted(tdict.items(), key=lambda kv: (-literal_len(kv[0]), holes(kv[0]), kv[0]))
        write_dart(exact, ordered)

    for p in problems:
        print('PROBLEM', p, file=sys.stderr)
    for w in warnings:
        print('WARNING', w, file=sys.stderr)
    for text, e in missing:
        print(f"{e['where'][0]}: {text!r}")
    if '--stale' in argv:
        for tr in list(exact) + list(tdict):
            if tr not in found:
                print(f'not in core (composed or hole word): {tr!r}', file=sys.stderr)
    print(f'{len(found)} core strings, {len(exact)} exact, {len(tdict)} templates, {len(keep)} kept Turkish, '
          f'{len(ignore)} ignored, {len(missing)} missing'
          + ('' if check or problems else f' -> wrote {DART_PATH.relative_to(APP)}'), file=sys.stderr)
    return 1 if problems or (check and missing) else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
