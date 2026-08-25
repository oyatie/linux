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

With --accept <file> --strict it becomes a GATE: every undecided *feature*
(a prompted symbol that no fragment requested and nothing enabled selects)
must appear in the accept-defaults ledger, or the run fails.  That makes
"purposefully scoped" an invariant -- the un-decided count is zero by
construction -- rather than a claim someone has to re-check by hand.

usage:
  unaudited.py <kernel-tree> <.config> <fragment>...              # report
  unaudited.py --accept F --strict <tree> <.config> <fragment>... # gate
  unaudited.py --list <tree> <.config> <fragment>...              # symbols only
"""
import re
import sys
from pathlib import Path

argv = sys.argv[1:]
accept_file = None
strict = False
list_only = False
while argv and argv[0].startswith("--"):
    opt = argv.pop(0)
    if opt == "--accept":
        accept_file = Path(argv.pop(0))
    elif opt == "--strict":
        strict = True
    elif opt == "--list":
        list_only = True
    else:
        sys.exit(f"unknown option {opt}")

tree, config = Path(argv[0]), Path(argv[1])
fragments = [Path(p) for p in argv[2:]]

accepted = set()
if accept_file and accept_file.exists():
    for line in accept_file.read_text().splitlines():
        m = re.match(r"^\s*CONFIG_([A-Z0-9_]+)", line)
        if m:
            accepted.add(m.group(1))

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

# --- when does a `select X if COND` actually fire? --------------------------
# `make olddefconfig` only honours a conditional select when COND is true.  If
# we ignored COND we would file a symbol conditionally selected by an enabled
# parent under "implied" even when COND is false -- masking a genuine default-on
# feature from the --strict gate.  A full Kconfig expression evaluator is out of
# scope; we only need to decide, *conservatively*, when a select may be inactive.
COND_HAS_OPERATOR = re.compile(r"[|!=<>]")  # ||  !  =  !=  <  >  <=  >=

def select_requires(cond):
    """Symbols that must ALL be enabled for `select X if cond` to fire.

    Empty set == "always fires".  We return it for an unconditional select
    (cond is None) and, deliberately, for any condition we cannot judge
    soundly.  We only interpret the one unambiguous shape: a *pure conjunction*
    of plain symbols (e.g. `NET && INET`), where "every named symbol is enabled"
    is exactly equivalent to "the condition is true" -- and so a missing symbol
    means the select is *clearly* inactive.  That is the soundness gap we fix.

    For OR (`||`), NOT (`!`) or any comparison (`=`, `!=`, `<`, `>`) we bail to
    the lenient empty set, because there a missing symbol does NOT make the
    condition false (`!FOO` holds precisely when FOO is off; `A || B` holds with
    only one side).  Treating those as inactive would demote a legitimately
    selected symbol to UNDECIDED and could fail --strict spuriously.  The
    asymmetry is intentional: being too lenient merely forgoes one audit line,
    while being too strict breaks the build -- so when in doubt, we stay lenient.
    """
    if cond is None:
        return set()                       # unconditional select: always fires
    cond = cond.split("#", 1)[0]           # drop any trailing comment
    if COND_HAS_OPERATOR.search(cond):
        return set()                       # not a pure AND -> lenient (always fires)
    # Pure conjunction: pull the bare symbol names.  Kconfig conditions use bare
    # names ("NET && INET"), but tolerate a stray CONFIG_ prefix just in case.
    return {t[7:] if t.startswith("CONFIG_") else t
            for t in re.findall(r"[A-Z0-9_]+", cond)}

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
        # `select X` or `select X if COND`.  No `$` anchor: keep the original
        # behaviour of tolerating trailing junk (e.g. a comment) after the line.
        m = re.match(r"^\s*select\s+([A-Z0-9_]+)(?:\s+if\s+(.+))?", line)
        if m:
            # Store (selected symbol, symbols its condition requires).  An empty
            # requirement set means the select always fires; see select_requires.
            selects.setdefault(cur, []).append(
                (m.group(1), select_requires(m.group(2))))
        if re.match(r"^\s*(end)?(menu|choice|if)\b", line):
            cur = None

implied = set()
for sym in enabled:
    for target, required in selects.get(sym, []):
        # `required` is empty for an unconditional (or too-complex-to-judge)
        # select, so `<= enabled` is trivially true and it always fires.  A
        # conjunctive `select X if A && B` fires only when every named symbol
        # (A, B) is itself enabled; otherwise the condition is clearly false and
        # X is left to surface as UNDECIDED -- the case this closes.
        if required <= enabled:
            implied.add(target)

undecided = sorted(enabled - requested - implied)
# Split the residue: a promptless symbol is internal plumbing (architecture
# capability flags, GENERIC_*/HAVE_*) that no human would ever choose.  A
# *prompted* symbol that nobody requested is a real feature that switched
# itself on -- that is the reviewable list.
undecided_features = [s for s in undecided if s in prompted]
undecided_internal = [s for s in undecided if s not in prompted]
noop = sorted(s for s in requested if s in enabled and s not in prompted
              and s not in implied)

# --list: just the undecided-feature symbols, for building the ledger.
if list_only:
    for s in undecided_features:
        print(f"CONFIG_{s}")
    sys.exit(0)

# The gate: undecided features not covered by the accept ledger.
unaccounted = [s for s in undecided_features if s not in accepted]

if strict:
    if unaccounted:
        print(f"AUDIT FAIL ({config.name}): {len(unaccounted)} default-on "
              f"feature(s) neither requested nor accepted:")
        for s in unaccounted:
            print(f"    CONFIG_{s}")
        print()
        print("Each must be: requested in a fragment (you want it), stripped "
              "(you don't),")
        print("or added to configs/accept-defaults.config with a reason (a "
              "reviewed default).")
        sys.exit(1)
    print(f"audit OK ({config.name}): every default-on feature is accounted "
          f"for ({len(undecided_features)} accepted, "
          f"{len(undecided_internal)} promptless internals ignored)")
    sys.exit(0)

print(f"profile config : {config.name}")
print(f"enabled        : {len(enabled)}")
print(f"  requested    : {len(enabled & requested)}  (a fragment named it)")
print(f"  implied      : {len(implied & enabled)}  (selected by something enabled)")
print(f"  UNDECIDED    : {len(undecided)}  (Kconfig default; nobody looked)")
print(f"    features   : {len(undecided_features)}  ({len(unaccounted)} not yet in the ledger)")
print(f"    internal   : {len(undecided_internal)}  (promptless plumbing; not a decision anyone makes)")
print()
print(f"UNDECIDED features not in the ledger ({len(unaccounted)}):")
for s in unaccounted:
    print(f"    {s}")
