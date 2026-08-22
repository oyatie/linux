#!/bin/sh
# Build one profile inside the container.  /src = kernel tree, /repo = this
# repository, /out = artifacts.
#
# Fragment order (last mention of a symbol wins):
#   base -> platform -> layers -> cpu -> gpu -> accel -> nics -> kver
#        -> liveupdate (hosts, >= LUO_FLOOR) -> OVERRIDES -> KVMHOST_EXTRA
#
# platform comes BEFORE the layers: platform-vm states "you do not own the
# hardware" as a foundation, and a guest layer may then explicitly re-add the
# few pieces its VMM really does provide (Cloud Hypervisor ACPI hotplug, a
# virtio-iommu).  An override that must beat everything stays in OVERRIDES,
# which is applied last.
set -eu

SRC=${SRC:-/src}
REPO=${REPO:-/repo}
OUT=${OUT:-/out}
JOBS=${JOBS:-$(nproc)}
EXTRA=${KVMHOST_EXTRA:-}

vernum() { printf '%d%03d' "${1%%.*}" "$(echo "$1" | cut -d. -f2)"; }

# Hard floor.  Below it, symbols would not fail -- Kconfig silently drops
# what does not exist yet -- so we fail here, with the reason.
if [ -n "${MSV:-}" ] && [ "$(vernum "${KERNEL_VERSION:?}")" -lt "$(vernum "$MSV")" ]; then
	echo "kernel $KERNEL_VERSION is below the hard floor $MSV" >&2
	echo "(v1 feature set: iommufd/cdev, KVM TDX, PREEMPT_LAZY -- docs/MSV.md)" >&2
	exit 1
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

base="00-core 15-vm-boot 20-storage 30-net 40-platform 50-security 55-kspp \
60-observability 90-strip 95-no-legacy"

add() { fragments="$fragments $REPO/configs/fragments/$1.config"; }
fragments=""
for f in $base; do add "$f"; done

# --- platform: metal owns the machine; vm owns nothing ----------------------
platform=${KVMHOST_PLATFORM:-${PLATFORM:-metal}}
if [ "$platform" != "metal" ]; then
	f="$REPO/configs/fragments/platform-$platform.config"
	[ -f "$f" ] || { echo "no such platform fragment: platform-$platform.config" >&2; exit 1; }
	fragments="$fragments $f"
fi

# --- role layers -------------------------------------------------------------
for f in ${LAYERS:-}; do add "$f"; done

# --- CPU vendor.  Default builds both; single-vendor drops the other's
# KVM/IOMMU/EDAC/pstate stack AND its mitigations -- tie to the SKU in the
# pipeline, never to a human (CPU=amd on Intel silicon = L1TF compiled out).
cpu=${KVMHOST_CPU:-${CPU:-both}}
if [ "$cpu" != "both" ]; then
	f="$REPO/configs/fragments/cpu-$cpu.config"
	[ -f "$f" ] || { echo "no such CPU fragment: cpu-$cpu.config" >&2; exit 1; }
	fragments="$fragments $f"
fi

# --- GPUs: only for first-party training metal (trusted-compute GPU=...).
# gpu-node is a *passthrough host*: the GPU goes to a guest via VFIO, and a
# host vendor driver would claim the very device VFIO needs.
gpu=${KVMHOST_GPU:-${GPU:-none}}
[ "$gpu" = "none" ] && gpu=""
if [ -n "$gpu" ] && [ "$PROFILE" = "gpu-node" ]; then
	echo "PROFILE=gpu-node is a GPU *passthrough* host: it must not bind a host" >&2
	echo "GPU driver.  GPU=nvidia|amd belongs on trusted-compute training nodes." >&2
	exit 1
fi
if [ -n "$gpu" ]; then
	add "hw-gpu-common"
	for g in $gpu; do
		f="$REPO/configs/fragments/hw-gpu-$g.config"
		[ -f "$f" ] || { echo "no such GPU fragment: hw-gpu-$g.config" >&2; exit 1; }
		fragments="$fragments $f"
	done
fi

# --- accelerators (DSA/IAA, QAT): per-fleet PCIe parts, like the NICs -------
accel=${KVMHOST_ACCEL:-${ACCEL:-none}}
[ "$accel" = "none" ] && accel=""
for a in $accel; do
	f="$REPO/configs/fragments/hw-accel-$a.config"
	[ -f "$f" ] || { echo "no such accelerator fragment: hw-accel-$a.config" >&2; exit 1; }
	fragments="$fragments $f"
done

# --- NICs: host SKUs pin what the fleet buys (profile NICS=); guests are
# virtio-only (NICS=none).  The fallback soup exists for bring-up images.
nics=${KVMHOST_NICS:-${NICS:-mellanox intel broadcom}}
[ "$nics" = "none" ] && nics=""
for nic in $nics; do
	if [ "$nic" = "ena" ] && [ "$platform" = "metal" ]; then
		echo "hw-nic-ena is what a *guest* sees on EC2 (the Nitro card presents" >&2
		echo "it); it never belongs in a bare-metal image.  Use PLATFORM=vm." >&2
		exit 1
	fi
	f="$REPO/configs/fragments/hw-nic-$nic.config"
	[ -f "$f" ] || { echo "no such NIC fragment: hw-nic-$nic.config" >&2; exit 1; }
	fragments="$fragments $f"
done

# --- per-version deltas ------------------------------------------------------
kver=$(echo "$KERNEL_VERSION" | cut -d. -f1,2)
[ -f "$REPO/configs/fragments/kver-$kver.config" ] && add "kver-$kver"

# --- live update: host SKUs only, and only where LUO exists ------------------
# Guests are replaced, not handed over, so 70-liveupdate is NOT in base.
if [ "${LIVEUPDATE:-}" = "yes" ]; then
	if [ -n "${LUO_FLOOR:-}" ] && [ "$(vernum "$KERNEL_VERSION")" -ge "$(vernum "$LUO_FLOOR")" ]; then
		add "70-liveupdate"
	else
		echo "==> v1/LTS track: no LUO below $LUO_FLOOR -- update story is drain + livepatch"
	fi
fi

# --- profile overrides and ad-hoc extras, last so they win ------------------
for f in ${OVERRIDES:-} $EXTRA; do add "$f"; done

cd "$SRC"

echo "==> profile: $PROFILE -- $DESC"
echo "==> kernel:  $KERNEL_VERSION  platform: $platform  cpu: $cpu"
echo "==> baseline: allnoconfig (nothing is on until a fragment turns it on)"
make -s ARCH=x86_64 allnoconfig >/dev/null

echo "==> merging $(echo "$fragments" | wc -w) fragments"
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

# Guest profiles also ship a stripped ELF vmlinux: Firecracker boots ELF (or
# PVH), and Cloud Hypervisor prefers it.  A bzImage-only artifact cannot even
# be loaded by the plant VMMs.
if [ "${ARTIFACT:-}" = "vmlinux" ]; then
	"${CROSS_COMPILE:-}strip" -o "$OUT/vmlinux-$PROFILE" vmlinux
	vsize=$(stat -c %s "$OUT/vmlinux-$PROFILE")
	printf '==> vmlinux-%s: %s bytes (%s KiB, ELF for FC/CH direct boot)\n' \
		"$PROFILE" "$vsize" "$((vsize / 1024))"
fi
