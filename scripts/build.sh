#!/bin/sh
# Build kvmhost inside the container.  Runs with /src = kernel tree,
# /repo = this repository, /out = artifact directory.
set -eu

SRC=${SRC:-/src}
REPO=${REPO:-/repo}
OUT=${OUT:-/out}
JOBS=${JOBS:-$(nproc)}
EXTRA=${KVMHOST_EXTRA:-}

PROFILE=${PROFILE:-hypervisor}
profile_file="$REPO/profiles/$PROFILE.profile"
[ -f "$profile_file" ] || {
	echo "no such profile: $PROFILE" >&2
	echo "available: $(ls "$REPO/profiles" | sed 's/\.profile//' | tr '\n' ' ')" >&2
	exit 1
}
# shellcheck disable=SC1090
. "$profile_file"

# Base: every layer in the fleet shares these.  If a decision differs between
# layers it does not belong here -- it belongs in that layer's fragment.
base="00-core 15-vm-boot 20-storage 30-net 40-platform 50-security 55-kspp \
60-observability 70-liveupdate 90-strip"

fragments=""
for f in $base ${LAYERS:-} ${OVERRIDES:-}; do
	fragments="$fragments $REPO/configs/fragments/$f.config"
done

# NIC drivers: one fragment per vendor.  The default builds all of them so a
# generic image boots on anything; a fleet that knows its hardware should set
# KVMHOST_NICS to just what it buys.
for nic in ${KVMHOST_NICS:-mellanox intel broadcom}; do
	f="$REPO/configs/fragments/hw-nic-$nic.config"
	[ -f "$f" ] || { echo "no such NIC fragment: hw-nic-$nic.config" >&2; exit 1; }
	fragments="$fragments $f"
done

# Per-version overrides.  Kconfig symbols are renamed, retyped and removed
# between releases; keeping those deltas in one small file per track is what
# lets a single fragment set target both LTS and mainline.
kver=$(echo "${KERNEL_VERSION:?}" | cut -d. -f1,2)
if [ -f "$REPO/configs/fragments/kver-$kver.config" ]; then
	fragments="$fragments $REPO/configs/fragments/kver-$kver.config"
fi

for e in $EXTRA; do
	fragments="$fragments $REPO/configs/fragments/$e.config"
done

cd "$SRC"

echo "==> profile: $PROFILE -- $DESC"
echo "==> baseline: allnoconfig (nothing is on until a fragment turns it on)"
make -s ARCH=x86_64 allnoconfig >/dev/null

echo "==> merging $(echo "$fragments" | wc -w) fragments"
# -m merges without running conf; olddefconfig then resolves defaults for
# everything the fragments did not mention.
./scripts/kconfig/merge_config.sh -m -O "$SRC" .config $fragments >/tmp/merge.log 2>&1 ||
	{ cat /tmp/merge.log; exit 1; }
make -s ARCH=x86_64 olddefconfig >/dev/null

echo "==> verifying intent survived Kconfig resolution"
sh "$REPO/scripts/check-config.sh" "$SRC/.config" $fragments

mkdir -p "$OUT"
cp "$SRC/.config" "$OUT/$PROFILE.config"

if [ "${CONFIG_ONLY:-0}" = "1" ]; then
	echo "==> CONFIG_ONLY=1, stopping before compile"
	exit 0
fi

echo "==> building with $JOBS jobs"
make -s ARCH=x86_64 -j"$JOBS" bzImage

cp "$SRC/arch/x86/boot/bzImage" "$OUT/bzImage-$PROFILE"
size=$(stat -c %s "$OUT/bzImage-$PROFILE")
printf '==> bzImage-%s: %s bytes (%s KiB)\n' "$PROFILE" "$size" "$((size / 1024))"
