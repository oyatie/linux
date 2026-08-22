#!/bin/sh
# Build kvmhost inside the container.  Runs with /src = kernel tree,
# /repo = this repository, /out = artifact directory.
set -eu

SRC=${SRC:-/src}
REPO=${REPO:-/repo}
OUT=${OUT:-/out}
JOBS=${JOBS:-$(nproc)}
EXTRA=${KVMHOST_EXTRA:-}

# Refuse to build below the minimum supported version.  Every symbol below the
# floor would still "resolve" -- Kconfig would just drop the features that do
# not exist yet, and check-config would tell you.  Failing here says why.
if [ -n "${MSV:-}" ]; then
	kv_maj=$(echo "${KERNEL_VERSION:?}" | cut -d. -f1)
	kv_min=$(echo "$KERNEL_VERSION" | cut -d. -f2)
	msv_maj=$(echo "$MSV" | cut -d. -f1)
	msv_min=$(echo "$MSV" | cut -d. -f2)
	if [ "$kv_maj" -lt "$msv_maj" ] ||
		{ [ "$kv_maj" -eq "$msv_maj" ] && [ "$kv_min" -lt "$msv_min" ]; }; then
		echo "kernel $KERNEL_VERSION is below the minimum supported version $MSV" >&2
		echo "Live update (LIVEUPDATE/LIVEUPDATE_MEMFD) does not exist there." >&2
		echo "See docs/MSV.md; regenerate the floor with 'make msv'." >&2
		exit 1
	fi
fi

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
60-observability 70-liveupdate 90-strip 95-no-legacy"

fragments=""
for f in $base ${LAYERS:-}; do
	fragments="$fragments $REPO/configs/fragments/$f.config"
done

# NIC drivers: one fragment per vendor.  The default builds all of them so a
# generic image boots on anything; a fleet that knows its hardware should set
# KVMHOST_NICS to just what it buys.
# A profile may declare NICS (e.g. "none" for a guest); KVMHOST_NICS in the
# environment overrides it.
nics=${KVMHOST_NICS:-${NICS:-mellanox intel broadcom}}
[ "$nics" = "none" ] && nics=""
for nic in $nics; do
	f="$REPO/configs/fragments/hw-nic-$nic.config"
	[ -f "$f" ] || { echo "no such NIC fragment: hw-nic-$nic.config" >&2; exit 1; }
	fragments="$fragments $f"
done

# Hardware accelerators: per-fleet PCIe devices, selected like the NICs.  A
# driver for an accelerator the machine does not have is the same mistake as a
# driver for a NIC it does not have.
accel=${KVMHOST_ACCEL:-${ACCEL:-none}}
[ "$accel" = "none" ] && accel=""
for a in $accel; do
	f="$REPO/configs/fragments/hw-accel-$a.config"
	[ -f "$f" ] || { echo "no such accelerator fragment: hw-accel-$a.config" >&2; exit 1; }
	fragments="$fragments $f"
done

# Per-version overrides.  No kver-*.config ships today (there is one track),
# but the hook stays: symbols get renamed and retyped between releases, and
# the next version bump wants somewhere to put the delta.
kver=$(echo "${KERNEL_VERSION:?}" | cut -d. -f1,2)
if [ -f "$REPO/configs/fragments/kver-$kver.config" ]; then
	fragments="$fragments $REPO/configs/fragments/kver-$kver.config"
fi

# OVERRIDES last (after the NIC and version fragments), because an override
# that a later fragment can undo is not an override.  This bit us: opt-dpu
# strips the tc action layer, and hw-nic-mellanox re-requested the mlx5 TC
# offload that depends on it.
for f in ${OVERRIDES:-} $EXTRA; do
	fragments="$fragments $REPO/configs/fragments/$f.config"
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
