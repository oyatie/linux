#!/bin/sh
# Generate a DEV signing hierarchy for the boot/update chain.  These are
# TEST keys -- self-signed, unencrypted, in the repo's out/pki.  Production
# keys live in an HSM and never touch a developer disk; this exists to prove
# the mechanism end to end.
#
#   secureboot.{key,crt}  -- the UEFI db key: signs the UKI (sbsign).  Also
#                            baked into the kernel's trusted keyring so the
#                            same cert verifies a kexec_file_load target.
#   verity.{key,crt}      -- signs the dm-verity root hash.
set -eu
OUT=${OUT:-out}/pki
mkdir -p "$OUT"
gen() {
	name=$1 cn=$2
	[ -f "$OUT/$name.key" ] && { echo "==> $name exists"; return; }
	openssl req -new -x509 -newkey rsa:4096 -nodes -days 3650 \
		-keyout "$OUT/$name.key" -out "$OUT/$name.crt" \
		-subj "/CN=kvmhost dev $cn/O=kvmhost/OU=NOT FOR PRODUCTION" >/dev/null 2>&1
	# DER form for the kernel trusted keyring.
	openssl x509 -in "$OUT/$name.crt" -outform DER -out "$OUT/$name.der"
	echo "==> generated $name ($cn)"
}
gen secureboot "Secure Boot db"
gen verity     "dm-verity root"
echo "==> DEV keys in $OUT (NOT FOR PRODUCTION)"
