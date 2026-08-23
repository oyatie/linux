#!/bin/sh
# Prove the build is reproducible: same source + same fragments -> byte-
# identical bzImage.  We set SOURCE_DATE_EPOCH and KBUILD_BUILD_* in the
# image; this is what makes those claims testable rather than aspirational.
#
#   repro-check.sh [profile]
set -eu
cd "$(dirname "$0")/.."
PROFILE=${1:-fc-guest}
A=out/bzImage-$PROFILE

echo "==> build 1"
make PROFILE=$PROFILE KVMHOST_EXTRA=opt-lowmem build >/dev/null
h1=$(sha256sum "$A" | cut -d' ' -f1); echo "    $h1"
echo "==> scrubbing object tree"
make tree-clean >/dev/null 2>&1
echo "==> build 2"
make PROFILE=$PROFILE KVMHOST_EXTRA=opt-lowmem build >/dev/null
h2=$(sha256sum "$A" | cut -d' ' -f1); echo "    $h2"
echo
if [ "$h1" = "$h2" ]; then echo "==> REPRODUCIBLE: identical bzImage across clean rebuilds"; else
	echo "==> NOT reproducible: hashes differ"; exit 1; fi
