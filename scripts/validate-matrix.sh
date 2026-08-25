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
hypervisor ACCEL=intel-dsa
hypervisor ACCEL=intel-qat
hypervisor ACCEL=intel-iaa
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

FAILLOG=$(mktemp); trap 'rm -f "$FAILLOG"' EXIT
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
				# audit the .config this tuple just wrote
				docker run --rm -v kvmhost-src:/build -v "$PWD":/repo:ro kvmhost-build \
					sh -c "python3 /repo/scripts/unaudited.py --strict \
						--accept /repo/configs/accept-defaults.config \
						/build/linux-$v /build/linux-$v/.config \
						\$(cat /build/linux-$v/.kvmhost-fragments)" ||
					echo "AUDIT-FAILED: $row @ $v" >>"$FAILLOG"
			fi
		else
			echo "FAILED: $row @ $v" >>"$FAILLOG"
		fi
	done
done
if [ -s "$FAILLOG" ]; then
	echo; echo "==> matrix failures:"; cat "$FAILLOG"
	rm -f "$FAILLOG"
	exit 1
fi
rm -f "$FAILLOG"
echo; echo "==> matrix clean"
