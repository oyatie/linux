#!/bin/sh
# Show how the tree's current .config differs from the fragment-resolved
# baseline, printed as lines you can paste into a fragment.
#
# The workflow this supports: explore in menuconfig, then bring the decision
# back into configs/fragments/ with a comment explaining it.  The .config in
# the build tree is a build artifact and is overwritten on the next `make
# config` -- fragments are the source of truth.
set -eu

SRC=${SRC:-/src}
BASE=${BASE:-/out/kvmhost.config}
cur="$SRC/.config"

[ -f "$BASE" ] || { echo "no baseline at $BASE -- run 'make config' first" >&2; exit 1; }
[ -f "$cur" ] || { echo "no .config in $SRC" >&2; exit 1; }

norm() {
	grep -E '^(CONFIG_[A-Z0-9_]+=|# CONFIG_[A-Z0-9_]+ is not set)' "$1" | sort
}

added=$(comm -13 "$(norm "$BASE" >/tmp/base.n; echo /tmp/base.n)" \
	"$(norm "$cur" >/tmp/cur.n; echo /tmp/cur.n)")

if [ -z "$added" ]; then
	echo "config-diff: no changes against the fragment baseline"
	exit 0
fi

echo "config-diff: lines below differ from the fragments; fold them in"
echo "(remember dependencies Kconfig auto-enabled are NOT worth copying --"
echo " only the decisions you actually made)"
echo
echo "$added"
