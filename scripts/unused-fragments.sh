#!/bin/sh
# Report config fragments that nothing can reach.
#
# A fragment tree accumulates dead files the same way any codebase does, and a
# dead fragment is worse than dead code: it looks like a supported option, so
# someone eventually builds with it and gets a kernel nobody has validated.
#
# Reachability, in order:
#   - the base list in scripts/build.sh
#   - LAYERS / OVERRIDES / PLATFORM in any profile
#   - a knob prefix (hw-nic-*, hw-accel-*, hw-gpu-*, cpu-*, platform-*)
#   - named in README/docs/Makefile as a KVMHOST_EXTRA option
set -eu

cd "$(dirname "$0")/.."

base=$(sed -n '/^base=/,/"$/p' scripts/build.sh | tr -d '\\\n' | sed 's/base=//;s/"//g')
# NB: grep -E then strip, rather than sed alternation -- BSD sed has no \| in
# basic regexes, and this script runs on developer laptops as well as CI.
fromprofiles=$(grep -hE '^(LAYERS|OVERRIDES|PLATFORM)=' profiles/*.profile |
	sed 's/^[A-Z]*="//; s/"$//' | tr ' ' '\n')
docs=$(grep -rhoE '(opt|hw-nic|hw-accel|hw-gpu|cpu|platform|strip|layer)-[a-z0-9-]+' \
	README.md docs/ Makefile scripts/ 2>/dev/null | sort -u)

unused=""
for f in configs/fragments/*.config; do
	n=$(basename "$f" .config)
	case " $base " in *" $n "*) continue;; esac
	echo "$fromprofiles" | grep -qx "$n" && continue
	# Knob-selected families are reachable by construction.
	case $n in
	hw-nic-*|hw-accel-*|hw-gpu-*|cpu-*|platform-*|kver-*) continue;; esac
	# PLATFORM="vm" names the suffix, not the fragment.
	echo "$fromprofiles" | grep -qx "${n#platform-}" && continue
	echo "$docs" | grep -qx "$n" && continue
	unused="$unused $n"
done

if [ -n "$unused" ]; then
	echo "unreferenced fragments:"
	for u in $unused; do echo "    configs/fragments/$u.config"; done
	echo
	echo "Either wire them into a profile/knob, document them as an option, or"
	echo "delete them.  A fragment nobody can select is a kernel nobody tested."
	exit 1
fi
echo "unused-fragments: every fragment is reachable"
