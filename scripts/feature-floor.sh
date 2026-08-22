#!/bin/sh
# Determine the minimum supported kernel version (MSV) for each feature this
# platform depends on, by probing whether the symbol's defining Kconfig
# contains it at each release tag.
#
# Why this exists: the fleet's kernel floor is not a preference, it is the max
# over the floors of every feature you actually rely on.  Guessing it wrong in
# either direction is expensive -- too high and you cannot use an LTS, too low
# and a profile silently loses a feature the design assumed.
#
# Caveat: symbol presence in Kconfig is a proxy for feature availability.  It
# does not capture a feature that landed incomplete, and renames must be
# listed explicitly (RETPOLINE -> MITIGATION_RETPOLINE at 6.9, for instance).
set -eu

TAGS=${TAGS:-"v6.1 v6.6 v6.12 v6.18 v7.0 v7.1 v7.2"}
RAW=https://raw.githubusercontent.com/torvalds/linux

# feature | symbols (alternates separated by ,) | candidate Kconfig paths
FEATURES='
Live Update Orchestrator|LIVEUPDATE|kernel/liveupdate/Kconfig
LUO memfd handover|LIVEUPDATE_MEMFD|kernel/liveupdate/Kconfig
Kexec handover (KHO)|KEXEC_HANDOVER|kernel/Kconfig.kexec kernel/liveupdate/Kconfig
KHO enable-by-default|KEXEC_HANDOVER_ENABLE_DEFAULT|kernel/Kconfig.kexec kernel/liveupdate/Kconfig
Intel TDX host|INTEL_TDX_HOST|arch/x86/Kconfig
KVM TDX|KVM_INTEL_TDX|arch/x86/kvm/Kconfig
AMD SEV (KVM)|KVM_AMD_SEV|arch/x86/kvm/Kconfig
Hyper-V enlightenments|KVM_HYPERV|arch/x86/kvm/Kconfig
iommufd|IOMMUFD|drivers/iommu/iommufd/Kconfig
VFIO cdev uAPI|VFIO_DEVICE_CDEV|drivers/vfio/Kconfig
mlx5 VF live migration|MLX5_VFIO_PCI|drivers/vfio/pci/mlx5/Kconfig
Core scheduling|SCHED_CORE|init/Kconfig kernel/Kconfig.preempt
Lazy preemption|PREEMPT_LAZY|kernel/Kconfig.preempt
Mitigation symbol rename|MITIGATION_RETPOLINE|arch/x86/Kconfig
hugetlb vmemmap optimization|HUGETLB_PAGE_OPTIMIZE_VMEMMAP|fs/Kconfig mm/Kconfig
cgroup v1 separable|MEMCG_V1|mm/Kconfig init/Kconfig
io.cost controller|BLK_CGROUP_IOCOST|block/Kconfig
Cache/MBA partitioning|X86_CPU_RESCTRL|arch/x86/Kconfig
User shadow stack (CET)|X86_USER_SHADOW_STACK|arch/x86/Kconfig
Zero call-used regs|ZERO_CALL_USED_REGS|security/Kconfig.hardening
Static usermode helper|STATIC_USERMODEHELPER|security/Kconfig init/Kconfig
Disable TIOCSTI|LEGACY_TIOCSTI|drivers/tty/Kconfig
Landlock|SECURITY_LANDLOCK|security/landlock/Kconfig
'

has_symbol() {
	tag=$1 syms=$2 paths=$3
	for path in $paths; do
		body=$(curl -fsSL --max-time 20 "$RAW/$tag/$path" 2>/dev/null) || continue
		for sym in $(echo "$syms" | tr ',' ' '); do
			if echo "$body" | grep -q "^config $sym\$"; then return 0; fi
		done
	done
	return 1
}

printf '%-30s %s\n' "FEATURE" "MINIMUM VERSION"
printf '%-30s %s\n' "------------------------------" "---------------"

echo "$FEATURES" | while IFS='|' read -r name syms paths; do
	[ -n "$name" ] || continue
	floor=""
	for tag in $TAGS; do
		if has_symbol "$tag" "$syms" "$paths"; then floor=$tag; break; fi
	done
	if [ -z "$floor" ]; then
		# Not found anywhere, including the newest tag: this is almost
		# always a stale Kconfig path, not a missing feature.  Say so
		# rather than reporting a floor nobody can meet.
		printf '%-30s %s\n' "$name" "PROBE BROKEN -- symbol not found at $(echo "$TAGS" | awk '{print $NF}'), check paths"
	elif [ "$floor" = "$(echo "$TAGS" | awk '{print $1}')" ]; then
		printf '%-30s %s\n' "$name" "<= $floor"
	else
		printf '%-30s %s\n' "$name" "$floor"
	fi
done
