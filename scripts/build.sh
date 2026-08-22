#!/bin/sh
# Build kvmhost inside the container.  Runs with /src = kernel tree,
# /repo = this repository, /out = artifact directory.
set -eu

SRC=${SRC:-/src}
REPO=${REPO:-/repo}
OUT=${OUT:-/out}
JOBS=${JOBS:-$(nproc)}
EXTRA=${KVMHOST_EXTRA:-}

fragments="$REPO/configs/fragments/00-core.config \
$REPO/configs/fragments/10-virt.config \
$REPO/configs/fragments/15-vm-boot.config \
$REPO/configs/fragments/20-storage.config \
$REPO/configs/fragments/30-net.config \
$REPO/configs/fragments/40-platform.config \
$REPO/configs/fragments/50-security.config \
$REPO/configs/fragments/60-observability.config \
$REPO/configs/fragments/90-strip.config"

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
cp "$SRC/.config" "$OUT/kvmhost.config"

if [ "${CONFIG_ONLY:-0}" = "1" ]; then
	echo "==> CONFIG_ONLY=1, stopping before compile"
	exit 0
fi

echo "==> building with $JOBS jobs"
make -s ARCH=x86_64 -j"$JOBS" bzImage

cp "$SRC/arch/x86/boot/bzImage" "$OUT/bzImage"
size=$(stat -c %s "$OUT/bzImage")
printf '==> bzImage: %s bytes (%s KiB)\n' "$size" "$((size / 1024))"
