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
# arm64 floors probe the arm64 Kconfig paths; the shared/generic features
# above them apply to both architectures.
FEATURES_ARM64='
KHO arch support (arm64)|ARCH_SUPPORTS_KEXEC_HANDOVER|arch/arm64/Kconfig
Lazy preemption (arm64)|+ARCH_HAS_PREEMPT_LAZY|arch/arm64/Kconfig
kexec Image signature|KEXEC_IMAGE_VERIFY_SIG|kernel/Kconfig.kexec arch/arm64/Kconfig
SMMUv3 iommufd support|@drivers/iommu/arm/arm-smmu-v3/arm-smmu-v3-iommufd.c|-
Memory tagging (MTE)|ARM64_MTE|arch/arm64/Kconfig
Branch Target Id (BTI)|ARM64_BTI|arch/arm64/Kconfig
Pointer auth|ARM64_PTR_AUTH|arch/arm64/Kconfig
E0PD|ARM64_E0PD|arch/arm64/Kconfig
Spectre-BHB mitigation|MITIGATE_SPECTRE_BRANCH_HISTORY|arch/arm64/Kconfig
RAS extension|ARM64_RAS_EXTN|arch/arm64/Kconfig
CMN mesh PMU|ARM_CMN|drivers/perf/Kconfig
'

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
	# Probe modes: plain SYM greps `^config SYM`; +SYM greps `select SYM`
	# (for arch capability selects that never become prompts); @path tests
	# that the file itself exists at the tag.
	case $syms in
	@*)
		curl -fsSIL --max-time 20 "$RAW/$tag/${syms#@}" >/dev/null 2>&1
		return $? ;;
	esac
	for path in $paths; do
		body=$(curl -fsSL --max-time 20 "$RAW/$tag/$path" 2>/dev/null) || continue
		for sym in $(echo "$syms" | tr ',' ' '); do
			case $sym in
			+*) echo "$body" | grep -q "select ${sym#+}\b" && return 0 ;;
			*)  echo "$body" | grep -q "^config $sym\$" && return 0 ;;
			esac
		done
	done
	return 1
}

printf '%-30s %s\n' "FEATURE" "MINIMUM VERSION"
printf '%-30s %s\n' "------------------------------" "---------------"

list=$FEATURES
[ "${FLOOR_ARCH:-x86}" = "arm64" ] && list=$FEATURES_ARM64

echo "$list" | while IFS='|' read -r name syms paths; do
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
