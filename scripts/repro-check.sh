#!/bin/sh
# Test build reproducibility: same source + fragments -> byte-identical output.
# Hashes .config, vmlinux (ELF) and the compressed image SEPARATELY so a
# mismatch localises to a stage:
#   .config differs   -> fragment resolution is nondeterministic
#   vmlinux differs    -> compile/link (embedded path, timestamp, build-id)
#   only image differs -> the compression/piggy wrapper (usually a gzip mtime)
#
# STATUS: passing.  Reaching it needed SOURCE_DATE_EPOCH + KBUILD_BUILD_USER/
# HOST/TIMESTAMP *and* KBUILD_BUILD_VERSION (all in docker/Dockerfile) -- the
# last pins the .version build counter, which this test caught incrementing
# ("#1" vs "#17") and making every vmlinux differ.
#
#   repro-check.sh [profile]
set -eu
cd "$(dirname "$0")/.."
PROFILE=${1:-fc-guest}
V=$(sed -n 's/^KERNEL_VERSION=//p' configs/kernel.pin)

hashes() {
	docker run --rm -v kvmhost-src:/build "$(sed -n 's/^IMAGE *:= *//p' Makefile)" sh -c "
		cd /build/linux-$V
		sha256sum .config vmlinux arch/x86/boot/bzImage 2>/dev/null | sed 's# .*/# #'"
}

echo "==> build 1"; make PROFILE="$PROFILE" KVMHOST_EXTRA=opt-lowmem build >/dev/null
hashes >/tmp/kvmhost-r1
echo "==> scrub object tree + build 2"; make tree-clean >/dev/null 2>&1
make PROFILE="$PROFILE" KVMHOST_EXTRA=opt-lowmem build >/dev/null
hashes >/tmp/kvmhost-r2

echo; echo "stage           build1 vs build2"
paste /tmp/kvmhost-r1 /tmp/kvmhost-r2 | while read -r h1 n1 h2 n2; do
	[ "$h1" = "$h2" ] && echo "  SAME  $n1" || echo "  DIFF  $n1"
done
diff -q /tmp/kvmhost-r1 /tmp/kvmhost-r2 >/dev/null && echo "==> REPRODUCIBLE" || {
	echo "==> NOT reproducible (localised above)"; exit 1; }
