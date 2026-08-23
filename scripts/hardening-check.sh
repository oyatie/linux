#!/bin/sh
# Independent hardening audit via a13xp0p0v/kernel-hardening-checker -- a
# third-party scorer of a resolved .config against the KSPP, CLIP OS, grsec
# and lockdown recommendation sets.  It is not vendored (it moves fast and
# pulling it in would be a supply-chain decision); this fetches a pinned tag
# into a cache and runs it against out/<profile>.config.
#
# usage: hardening-check.sh [profile]   (default: hypervisor)
set -eu
cd "$(dirname "$0")/.."

PROFILE=${1:-hypervisor}
CACHE=${KHC_CACHE:-/tmp/kvmhost-khc}
TAG=v0.6.17

if [ ! -d "$CACHE" ]; then
	echo "==> fetching kernel-hardening-checker $TAG"
	git clone --quiet --depth 1 --branch "$TAG" \
		https://github.com/a13xp0p0v/kernel-hardening-checker "$CACHE" 2>/dev/null ||
		git clone --quiet --depth 1 \
			https://github.com/a13xp0p0v/kernel-hardening-checker "$CACHE"
fi

cfg="out/$PROFILE.config"
[ -f "$cfg" ] || { echo "no $cfg -- run 'make PROFILE=$PROFILE config' first" >&2; exit 1; }

python3 "$CACHE/bin/kernel-hardening-checker" -c "$cfg" 2>/dev/null | tee /tmp/kvmhost-khc-out.txt |
	grep -E "Check is finished"
echo
echo "FAILs (deliberate divergences are catalogued in docs/HARDENING.md):"
grep 'FAIL:' /tmp/kvmhost-khc-out.txt | awk -F'|' '{gsub(/ /,"",$1);print "    "$1}' | sort | head -80
