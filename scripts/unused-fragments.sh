#!/bin/sh
# Two hygiene checks over the fragment tree.
#
# 1. REACHABILITY: a fragment nobody can select is a kernel nobody tested.
#    Reachable means: in build.sh's base list, named by a profile
#    (LAYERS/OVERRIDES/PLATFORM), or selected by a knob family
#    (hw-nic-*, hw-accel-*, hw-gpu-*, cpu-*, platform-*, kver-*, opt-*).
#    Docs mentions deliberately do NOT count -- a README comment must not be
#    able to keep a dead fragment alive.
#
# 2. DANGLING NAMES: the reverse.  Any fragment-shaped name in the operative
#    surfaces (README, Makefile, scripts/, profiles/, the fragments
#    themselves) must exist as a file, so renames cannot leave lying
#    references behind.  docs/ is exempt: audit records legitimately name
#    fragments that have since been retired.
set -eu
cd "$(dirname "$0")/.."

base=$(sed -n '/^base=/,/"$/p' scripts/build.sh | tr -d '\\\n' | sed 's/base=//;s/"//g')
fromprofiles=$(grep -hE '^(LAYERS|OVERRIDES|PLATFORM)=' profiles/*.profile |
	sed 's/^[A-Z]*="//; s/"$//' | tr ' ' '\n')

fail=0
unused=""
for f in configs/fragments/*.config; do
	n=$(basename "$f" .config)
	case " $base " in *" $n "*) continue;; esac
	echo "$fromprofiles" | grep -qx "$n" && continue
	echo "$fromprofiles" | grep -qx "${n#platform-}" && continue
	case $n in
	hw-nic-*|hw-accel-*|hw-gpu-*|cpu-*|platform-*|kver-*|opt-*) continue;; esac
	# 70-liveupdate is attached by build.sh's LIVEUPDATE gate, not the base.
	grep -q "add \"$n\"" scripts/build.sh && continue
	unused="$unused $n"
done
if [ -n "$unused" ]; then
	echo "unreferenced fragments:"
	for u in $unused; do echo "    configs/fragments/$u.config"; done
	echo "Wire them into a profile or knob, or delete them."
	fail=1
fi

dangling=$(grep -rhoE '\b(kver|opt|hw-nic|hw-accel|hw-gpu|cpu|platform|strip|layer)-[a-z0-9][a-z0-9-]*' \
	README.md Makefile scripts profiles configs/fragments configs/sysctl.d 2>/dev/null |
	sort -u | while IFS= read -r tok; do
		[ -f "configs/fragments/$tok.config" ] && continue
		# knob prefixes appearing bare in prose ("hw-nic- families") are
		# fine.  NB leading paren: a bare ) inside $() ends the substitution.
		case $tok in (*-) continue;; esac
		# English, not fragments.
		case $tok in (opt-in|opt-out|opt-ins) continue;; esac
		echo "$tok"
	done)
if [ -n "$dangling" ]; then
	echo "dangling fragment references (file does not exist):"
	echo "$dangling" | sed 's/^/    /'
	fail=1
fi

[ "$fail" -eq 0 ] && echo "fragment hygiene: all reachable, no dangling references"
exit $fail
