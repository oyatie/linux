#!/bin/sh
# Reproduce docs/COMPARISON.md: download the kernels other people ship and
# measure them the same way we measure ours.
#
# Point being: "stripped down" is a claim, and claims about size are cheap.
# This downloads ~150MB of other people's artifacts and counts bytes.
set -eu

WORK=${WORK:-$(mktemp -d)}
cd "$WORK"
echo "==> working in $WORK"

echo "--- Talos"
tag=$(curl -fsSL https://api.github.com/repos/siderolabs/talos/releases/latest |
	python3 -c "import json,sys;print(json.load(sys.stdin)['tag_name'])")
curl -fsSL -o talos-vmlinuz \
	"https://github.com/siderolabs/talos/releases/download/$tag/vmlinuz-amd64"
printf '    talos %s vmlinuz: %s bytes\n' "$tag" "$(stat -f %z talos-vmlinuz 2>/dev/null || stat -c %s talos-vmlinuz)"

echo "--- Alpine linux-virt"
apk=$(curl -fsSL https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/ |
	grep -o 'linux-virt-[0-9][^"]*\.apk' | head -1)
curl -fsSL -o alpine.apk "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/$apk"
mkdir -p alpine && tar -xzf alpine.apk -C alpine 2>/dev/null || true
find alpine -name 'vmlinuz-virt' -exec ls -l {} \; |
	awk '{printf "    alpine vmlinuz: %s bytes\n", $5}'
printf '    alpine modules: %s\n' "$(find alpine -name '*.ko*' | wc -l | tr -d ' ')"

echo "--- Rocky 9"
base=https://dl.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/Packages/k
list=$(curl -fsSL $base/)
for p in kernel-core kernel-modules-core kernel-modules; do
	f=$(echo "$list" | grep -o "${p}-5\.14[^\"]*\.x86_64\.rpm" | sort -V | tail -1)
	curl -fsSL -o "$p.rpm" "$base/$f"
	mkdir -p "x-$p" && (cd "x-$p" && tar -xf "../$p.rpm" 2>/dev/null || true)
	n=$(find "x-$p" -name '*.ko*' | wc -l | tr -d ' ')
	printf '    %-20s %s modules\n' "$p" "$n"
	find "x-$p" -name 'vmlinuz' -exec ls -l {} \; |
		awk '{printf "    rocky vmlinuz: %s bytes\n", $5}'
done

echo
echo "==> ours, for comparison:"
echo "    make build && ls -l out/bzImage-*"
echo "    (default config uses zstd; opt-lowmem falls back to gzip, ~2MB larger)"
