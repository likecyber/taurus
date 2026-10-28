# walks every chroma-lab lockscreen style, extracts every property, unit, function,
# selector and var() it uses, and prints the set: the conformance contract the engine
# must implement. run from the repo root: python harness/lockcard/properties.py
import json, glob, re, collections, sys, os, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
folder = os.path.join(root, 'chroma-lab', 'assets', 'lockscreen')

props = collections.Counter()
units = collections.Counter()
funcs = collections.Counter()
selectors = collections.Counter()
variables = collections.Counter()
colors = collections.Counter()
templates = {}

def scan(css):
    for m in re.finditer(r'(^|[;{\s])([-a-zA-Z]+)\s*:', css):
        props[m.group(2)] += 1
    for m in re.finditer(r'(-?\d*\.?\d+)(cqw|cqh|px|pt|em|rem|vw|vh|s|ms|%)\b', css):
        units[m.group(2)] += 1
    for m in re.finditer(r'([a-zA-Z][\w-]*)\(', css):
        funcs[m.group(1)] += 1
    for m in re.finditer(r'(^|\})\s*([^{}@]+?)\s*\{', css):
        for part in m.group(2).split(','):
            selectors[part.strip()] += 1
    for m in re.finditer(r'var\(\s*(--[\w-]+)', css):
        variables[m.group(1)] += 1
    for m in re.finditer(r'#[0-9a-fA-F]{3,8}\b|rgba?\([^)]*\)|\bhsla?\([^)]*\)', css):
        colors[m.group(0)] += 1

styles = []
for path in sorted(glob.glob(os.path.join(folder, '*.json'))):
    try:
        d = json.load(open(path, encoding='utf-8'))
    except Exception as e:
        print('BAD JSON', path, e); continue
    # entries wrap the style in a top-level "style" object; catalog.json is a bare array
    if isinstance(d, dict) and isinstance(d.get('style'), dict):
        d = d['style']
    if not isinstance(d, dict) or 'css' not in d:
        print('SKIP (no css):', os.path.basename(path)); continue
    styles.append(d)
    name = d.get('name') or os.path.basename(path)
    fonts = d.get('fonts') or []
    has_template = 'template' in d
    scan(d['css'])
    print(f'{name:24.24} fonts={fonts} template={"custom" if has_template else "-"} csslen={len(d["css"])}')

print()
print(f'{len(styles)} catalog styles scanned')

print()
print('=== PROPERTIES ===')
for p, n in sorted(props.items()):
    print(f'  {p:24} {n}')
print()
print('=== UNITS ===')
for u, n in sorted(units.items()):
    print(f'  {u:8} {n}')
print()
print('=== FUNCTIONS ===')
for f, n in sorted(funcs.items()):
    print(f'  {f:24} {n}')
print()
print('=== SELECTORS ===')
for s, n in sorted(selectors.items()):
    print(f'  {s:40} {n}')
print()
print('=== var() NAMES ===')
for v, n in sorted(variables.items()):
    print(f'  {v:24} {n}')
print()
print('=== COLOURS ===')
for c, n in sorted(colors.items()):
    print(f'  {c:32} {n}')
