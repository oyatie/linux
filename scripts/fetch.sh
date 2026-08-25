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

PIN=${PIN_FILE:-/repo/configs/kernel.pin}
want=""
if [ -f "$PIN" ]; then
	pinned_v=$(sed -n 's/^KERNEL_VERSION=//p' "$PIN")
	dest_v=$(sed -n 's/^DESTINATION_VERSION=//p' "$PIN")
	case $V in
	"$pinned_v") want=$(sed -n 's/^KERNEL_SHA256=//p' "$PIN") ;;
	"$dest_v")   want=$(sed -n 's/^DESTINATION_SHA256=//p' "$PIN") ;;
	esac
fi
[ -n "$want" ] || {
	echo "no sha256 pin for linux-$V in $PIN -- refusing to build from" >&2
	echo "unverified source.  Add its hash (kernel.org sha256sums.asc)." >&2
	rm -f "$SRCROOT/linux-$V.tar.xz"; exit 1
}

echo "==> fetching $URL"
curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 30 -o "$SRCROOT/linux-$V.tar.xz" "$URL"

# --- MANDATORY source integrity --------------------------------------------
# The tarball must hash to the value pinned in configs/kernel.pin.  This is the
# anchor for everything downstream: Secure Boot, dm-verity, signed kexec and the
# promotion hash-chain all describe an artifact built FROM THIS SOURCE, so an
# unverified source makes each of them a statement about nothing.  There is no
# opt-out flag on purpose -- if the pin is missing for a version, the build
# stops and asks for it rather than proceeding unverified.
got=$(sha256sum "$SRCROOT/linux-$V.tar.xz" | awk '{print $1}')
[ "$got" = "$want" ] || {
	echo "SOURCE HASH MISMATCH for linux-$V" >&2
	echo "  pinned $want" >&2
	echo "  got    $got" >&2
	rm -f "$SRCROOT/linux-$V.tar.xz"; exit 1
}
echo "==> sha256 verified against configs/kernel.pin"

# kernel.org signs the .tar (not the .tar.xz).  GPG adds authenticity on top of
# the pin; it needs the release keyring provisioned in the image, so it stays
# opt-in via VERIFY_SIG=1 rather than silently passing when no key is present.
if [ "${VERIFY_SIG:-0}" = "1" ]; then
	curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 30 -o "$SRCROOT/linux-$V.tar.sign" "${URL%.xz}.sign"
	xz -cd "$SRCROOT/linux-$V.tar.xz" |
		gpg --verify "$SRCROOT/linux-$V.tar.sign" -
fi

tar -C "$SRCROOT" -xf "$SRCROOT/linux-$V.tar.xz"
rm -f "$SRCROOT/linux-$V.tar.xz"
echo "==> unpacked $SRCROOT/linux-$V"
