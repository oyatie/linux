#!/bin/sh
# Resolve + verify every shippable (profile x knob x kernel-track) tuple.
#
# This is the matrix that can actually reach a machine, which is a longer list
# than "every profile once": the CPU-vendor split changes which mitigations
# exist, GPU=amd turns DRM back on, opt-windows adds a second hypercall ABI,
# and the two kernel tracks (v1 LTS / destination) drift symbols.  A tuple
# that only resolves on the track nobody validated is a deploy-time surprise.
set -u

VERSIONS="${VALIDATE_VERSIONS:?set VALIDATE_VERSIONS (space-separated)}"

MATRIX='
hypervisor
hypervisor CPU=intel
hypervisor CPU=amd
hypervisor KVMHOST_EXTRA=opt-windows
hypervisor-dpu
gpu-node
trusted-compute
trusted-compute GPU=nvidia
trusted-compute GPU=amd
ch-guest
ch-guest-k8s
fc-guest
reclaim
hypervisor KARCH=arm64
ch-guest KARCH=arm64
fc-guest KARCH=arm64
reclaim KARCH=arm64
'

fail=0
echo "$MATRIX" | while IFS= read -r row; do
	[ -n "$row" ] || continue
	profile=${row%% *}
	vars=""
	[ "$row" != "$profile" ] && vars=${row#* }
	for v in $VERSIONS; do
		printf '\n=========== %-38s @ linux-%s ===========\n' "$row" "$v"
		# shellcheck disable=SC2086
		if make --no-print-directory KERNEL_VERSION="$v" PROFILE="$profile" $vars config; then
			if [ "${AUDIT:-1}" = "1" ]; then
				# the .config that config just wrote, plus arch-correct tree
				a=x86_64; case "$vars" in *KARCH=arm64*) a=arm64;; esac
				docker run --rm -v kvmhost-src:/build -v "$PWD":/repo:ro kvmhost-build \
					sh -c "python3 /repo/scripts/unaudited.py --strict \
						--accept /repo/configs/accept-defaults.config \
						/build/linux-$v /build/linux-$v/.config \
						/repo/configs/fragments/*.config" ||
					echo "AUDIT-FAILED: $row @ $v" >>/tmp/kvmhost-matrix-fail
			fi
		else
			echo "FAILED: $row @ $v" >>/tmp/kvmhost-matrix-fail
		fi
	done
done
if [ -s /tmp/kvmhost-matrix-fail ]; then
	echo; echo "==> matrix failures:"; cat /tmp/kvmhost-matrix-fail
	rm -f /tmp/kvmhost-matrix-fail
	exit 1
fi
rm -f /tmp/kvmhost-matrix-fail
echo; echo "==> matrix clean"
