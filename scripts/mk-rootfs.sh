#!/bin/sh
# Build the read-only root the host actually boots: a tiny erofs image, sealed
# with dm-verity, its root hash signed by the verity key.  This is the artifact
# DM_VERITY_VERIFY_ROOTHASH_SIG (50-security via platform-metal) checks in the
# kernel, so a tampered root is refused at mount by the kernel, not trusted on
# userspace's word.
set -eu
OUT=${OUT:-/out}
REPO=${REPO:-/repo}
WORK=$(mktemp -d)

# Minimal rootfs content -- in production this is the JeOS userspace + agent;
# here it is enough to prove the seal-and-verify chain.
mkdir -p "$WORK/root/sbin" "$WORK/root/etc"
printf 'kvmhost verity root\n' > "$WORK/root/etc/os-release-marker"
cp "$OUT/init" "$WORK/root/sbin/init" 2>/dev/null || printf '#!/bin/sh\n' > "$WORK/root/sbin/init"

mkfs.erofs "$OUT/root.erofs" "$WORK/root"
size=$(stat -c %s "$OUT/root.erofs")

# Seal with verity; capture the root hash.
veritysetup format "$OUT/root.erofs" "$OUT/root.verity" > "$WORK/verity.txt" 2>&1
roothash=$(awk '/Root hash:/{print $3}' "$WORK/verity.txt")
echo "$roothash" > "$OUT/root.roothash"

# Sign the root hash (PKCS#7) with the verity key.
openssl smime -sign -nocerts -noattr -binary \
	-in "$OUT/root.roothash" -inkey "$OUT/pki/verity.key" -signer "$OUT/pki/verity.crt" \
	-outform DER -out "$OUT/root.roothash.p7s"

printf '==> root.erofs: %s bytes  roothash: %s\n' "$size" "$roothash"
printf '==> root hash signed (root.roothash.p7s) with the dev verity key\n'
rm -rf "$WORK"
