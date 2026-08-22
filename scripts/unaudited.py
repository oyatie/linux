#!/usr/bin/env python3
"""Find enabled symbols that nobody decided.

A fragment tree gives the comfortable illusion that every symbol in the image
was chosen.  It was not: `make olddefconfig` fills in every symbol the
fragments did not mention, using its Kconfig default.  This script classifies
every enabled symbol in a resolved config into:

  requested  -- named by a fragment.  A decision, with a comment next to it.
  implied    -- `select`ed by some other enabled symbol.  A dependency, and
                legitimate: you asked for the parent.
  default    -- neither.  It is in your kernel because Kconfig's default said
                so and nobody looked.

The third category is the interesting one.  It is where XFS online repair and
MISC_FILESYSTEMS came from, and it is usually the majority of the image.

usage: unaudited.py <kernel-tree> <resolved .config> <fragment>...
"""
import re
import sys
from pathlib import Path

tree, config = Path(sys.argv[1]), Path(sys.argv[2])
fragments = [Path(p) for p in sys.argv[3:]]

# --- what the fragments asked for ------------------------------------------
requested = set()
for f in fragments:
    for line in f.read_text().splitlines():
        m = re.match(r"^(CONFIG_[A-Z0-9_]+)=", line)
        if m:
            requested.add(m.group(1)[7:])
        m = re.match(r"^# (CONFIG_[A-Z0-9_]+) is not set", line)
        if m:
            requested.add(m.group(1)[7:])

# --- what is actually on ----------------------------------------------------
enabled = set()
for line in config.read_text().splitlines():
    m = re.match(r"^CONFIG_([A-Z0-9_]+)=(y|m)$", line)
    if m:
        enabled.add(m.group(1))

# --- parse every Kconfig for selects and prompts ----------------------------
selects, prompted = {}, set()
cur = None
for kc in tree.rglob("Kconfig*"):
    if not kc.is_file():
        continue
    try:
        text = kc.read_text(errors="replace")
    except OSError:
        continue
    for line in text.splitlines():
        m = re.match(r"^\s*(?:menu)?config\s+([A-Z0-9_]+)", line)
        if m:
            cur = m.group(1)
            continue
        if cur is None:
            continue
        if re.match(r"^\s*(bool|tristate|string|int|hex)\s+\"", line) or \
           re.match(r"^\s*prompt\s+\"", line):
            prompted.add(cur)
        m = re.match(r"^\s*select\s+([A-Z0-9_]+)", line)
        if m:
            selects.setdefault(cur, set()).add(m.group(1))
        if re.match(r"^\s*(end)?(menu|choice|if)\b", line):
            cur = None

implied = set()
for sym in enabled:
    implied |= selects.get(sym, set())

undecided = sorted(enabled - requested - implied)
# Split the residue: a promptless symbol is internal plumbing (architecture
# capability flags, GENERIC_*/HAVE_*) that no human would ever choose.  A
# *prompted* symbol that nobody requested is a real feature that switched
# itself on -- that is the reviewable list.
undecided_features = [s for s in undecided if s in prompted]
undecided_internal = [s for s in undecided if s not in prompted]
noop = sorted(s for s in requested if s in enabled and s not in prompted
              and s not in implied)

print(f"profile config : {config.name}")
print(f"enabled        : {len(enabled)}")
print(f"  requested    : {len(enabled & requested)}  (a fragment named it)")
print(f"  implied      : {len(implied & enabled)}  (selected by something enabled)")
print(f"  UNDECIDED    : {len(undecided)}  (Kconfig default; nobody looked)")
print(f"    features   : {len(undecided_features)}  <-- reviewable: real options that defaulted on")
print(f"    internal   : {len(undecided_internal)}  (promptless plumbing; not a decision anyone makes)")
print()
if noop:
    print(f"requested but promptless ({len(noop)}) -- the request was a no-op,")
    print("the symbol was going to be set anyway:")
    for s in noop[:20]:
        print(f"    {s}")
    print()
print(f"UNDECIDED features ({len(undecided_features)}) -- real options nobody asked for:")
for s in undecided_features:
    print(f"    {s}")
