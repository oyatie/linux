#!/bin/sh
# Fetch and unpack a kernel tarball into $SRCROOT/linux-$KERNEL_VERSION.
# Runs inside the build container; the tree lives in a Docker volume because
# the kernel source contains case-conflicting filenames that cannot be
# checked out on a case-insensitive host filesystem (macOS default).
set -eu

V=${KERNEL_VERSION:?}
SRCROOT=${SRCROOT:-/build}
BASE="v${V%%.*}.x"
URL="https://cdn.kernel.org/pub/linux/kernel/$BASE/linux-$V.tar.xz"

if [ -d "$SRCROOT/linux-$V" ]; then
	echo "==> linux-$V already unpacked"
	exit 0
fi

echo "==> fetching $URL"
curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 30 -o "$SRCROOT/linux-$V.tar.xz" "$URL"

# kernel.org signs the .tar (not the .tar.xz).  Verify if a key is present;
# a production build system should make this mandatory.
if [ "${VERIFY_SIG:-0}" = "1" ]; then
	curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 30 -o "$SRCROOT/linux-$V.tar.sign" "${URL%.xz}.sign"
	xz -cd "$SRCROOT/linux-$V.tar.xz" |
		gpg --verify "$SRCROOT/linux-$V.tar.sign" -
fi

tar -C "$SRCROOT" -xf "$SRCROOT/linux-$V.tar.xz"
rm -f "$SRCROOT/linux-$V.tar.xz"
echo "==> unpacked $SRCROOT/linux-$V"
