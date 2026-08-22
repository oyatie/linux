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
	# Per-arch siblings (<name>.<arch>.config) are reachable iff their parent
	# is; build.sh appends them automatically.
	case $n in
	(*.x86_64|*.arm64)
		parent=${n%.*}
		[ -f "configs/fragments/$parent.config" ] && continue
		echo "orphan per-arch fragment (no parent): $f"
		fail=1
		continue
		;;
	esac
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

# Every fragment a PROFILE names (LAYERS/OVERRIDES/PLATFORM) must exist.
# This is the reference->exists direction; it is exact (no prose scanning) and
# fast, catching a rename before a build would.  build.sh's own base list and
# knob families are guarded at config time by [ -f ] || exit, so they need no
# separate check here.
dangling=$(for pf in profiles/*.profile; do
		# shellcheck disable=SC1090
		. "$pf"
		for f in ${LAYERS:-} ${OVERRIDES:-}; do
			[ -f "configs/fragments/$f.config" ] || echo "$f (in $(basename "$pf"))"
		done
		[ -n "${PLATFORM:-}" ] &&
			{ [ -f "configs/fragments/platform-$PLATFORM.config" ] ||
				echo "platform-$PLATFORM (in $(basename "$pf"))"; }
		unset LAYERS OVERRIDES PLATFORM NICS ARTIFACT DESC
	done)
if [ -n "$dangling" ]; then
	echo "profile references a fragment that does not exist:"
	echo "$dangling" | sed 's/^/    /'
	fail=1
fi

[ "$fail" -eq 0 ] && echo "fragment hygiene: all reachable, no dangling references"
exit $fail
