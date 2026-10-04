# Soft Structuralism adoption audit (guide section 9) plus the banned-pattern scan.
# Run from the project root: python tools/audit.py
import glob, io, re, sys

FILES = sorted(glob.glob('app/lib/**/*.dart', recursive=True))
SCALE = ['displayStyle', 'titleStyle', 'sectionStyle', 'rowTitleStyle',
         'bodyStyle', 'labelStyle', 'kickerStyle', 'numStyle']

print('%-26s %5s %5s | %5s %5s | %6s %5s %5s' %
      ('file', 'rawTS', 'scale', 'surf', 'deco', 'border', 'hardC', 'white'))
totals = [0] * 7
for p in FILES:
    s = io.open(p, encoding='utf-8').read()
    row = [
        len(re.findall(r'TextStyle\(\s*fontSize', s)),
        sum(len(re.findall(r'\b%s\b' % t, s)) for t in SCALE),
        len(re.findall(r'\bsurface\(|\bsunken\(', s)),
        len(re.findall(r'BoxDecoration\(', s)),
        len(re.findall(r'Border\.all\(', s)),
        len(re.findall(r'Color\(0x[0-9A-Fa-f]{8}\)', s)),
        len(re.findall(r'Colors\.white', s)),
    ]
    totals = [a + b for a, b in zip(totals, row)]
    name = p.replace('\\', '/').split('/')[-1]
    print('%-26s %5d %5d | %5d %5d | %6d %5d %5d' % (name, *row))
print('%-26s %5d %5d | %5d %5d | %6d %5d %5d' % ('TOTAL', *totals))

# Banned or rule-breaking patterns; theme.dart is the verbatim token file and is exempt.
BANNED = {
    'spinner / animated widget': r'CircularProgressIndicator|LinearProgressIndicator|AnimatedContainer|AnimatedOpacity|AnimationController|Hero\(|AnimatedSwitcher',
    'bottom sheet': r'showModalBottomSheet|BottomSheet\(|showBottomSheet',
    'snackbar': r'SnackBar\(|showSnackBar',
    'gradient': r'LinearGradient|RadialGradient|SweepGradient',
    'blur / glass': r'BackdropFilter|ImageFilter\.blur',
    'fromSeed': r'fromSeed',
    'banned font': r"Inter'|Roboto|Open Sans",
    # A fill, not text: a decoration or box painted with raw ink (measureFill is the guide's near-black bar).
    'raw ink fill': r'(BoxDecoration|ColoredBox|Container)\([^)]*\bcolor:\s*ink\b(?!\.)',
    'success as a button fill': r'PrimaryButton\([^)]*success',
    'emoji in copy': r'[\U0001F300-\U0001FAFF☀-➿]',
}
print('\nbanned-pattern scan')
problems = 0
for label, pattern in BANNED.items():
    hits = []
    for p in FILES:
        if p.replace('\\', '/').endswith('lib/theme.dart'):
            continue
        for i, line in enumerate(io.open(p, encoding='utf-8'), 1):
            if re.search(pattern, line):
                hits.append('%s:%d: %s' % (p.replace('\\', '/'), i, line.strip()[:90]))
    print('  %-26s %s' % (label, 'none' if not hits else '%d hit(s)' % len(hits)))
    for h in hits:
        print('      ' + h)
    problems += len(hits)

# The accent may only serve the AI paper reader.
accent_uses = []
for p in FILES:
    for i, line in enumerate(io.open(p, encoding='utf-8'), 1):
        if re.search(r'\baiAccent(Ink|Soft)?\b|Tone\.ai', line) and not p.endswith(('theme.dart', 'tokens.dart')):
            accent_uses.append('%s:%d' % (p.replace('\\', '/').split('/')[-1], i))
print('\naccent call sites (%d): %s' % (len(accent_uses), ', '.join(accent_uses)))
sys.exit(1 if problems else 0)
