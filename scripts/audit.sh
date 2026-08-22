#!/bin/sh
# Audit resolved configs against a capability checklist.
#
# Reads out/<profile>.config (produced by `make config`) and prints a matrix of
# capability x profile.  The point is to answer "do we actually have X" from
# the artifact rather than from the fragment comments, which are intent.
#
# usage: audit.sh [checklist]     (default: isolation)
set -eu

OUT=${OUT:-out}
CHECKLIST=${1:-isolation}

isolation='
cgroup v2 core|CGROUPS
  cpu controller|CGROUP_SCHED
  cpu.weight (fair)|FAIR_GROUP_SCHED
  cpu.max (bandwidth)|CFS_BANDWIDTH
  cpuset|CPUSETS
  memory|MEMCG
  io|BLK_CGROUP
  io.cost|BLK_CGROUP_IOCOST
  io.latency|BLK_CGROUP_IOLATENCY
  pids|CGROUP_PIDS
  hugetlb|CGROUP_HUGETLB
  misc (SEV ASIDs)|CGROUP_MISC
  freezer|CGROUP_FREEZER
  bpf attach|CGROUP_BPF
  pressure (PSI)|PSI
cgroup v1 disabled|!MEMCG_V1
namespaces|NAMESPACES
  uts|UTS_NS
  ipc|IPC_NS
  pid|PID_NS
  net|NET_NS
  user|USER_NS
  time|TIME_NS
containment|SECCOMP
  seccomp filter|SECCOMP_FILTER
  landlock|SECURITY_LANDLOCK
  selinux|SECURITY_SELINUX
  bpf lsm|BPF_LSM
  lockdown|SECURITY_LOCKDOWN_LSM
  no modules|!MODULES
hardware isolation|X86_CPU_RESCTRL
  core scheduling|SCHED_CORE
  cpu isolation|CPU_ISOLATION
  full tickless|NO_HZ_FULL
  rcu offload|RCU_NOCB_CPU
  irq accounting|IRQ_TIME_ACCOUNTING
sandbox|KVM
  vhost datapath|VHOST_NET
  vsock|VHOST_VSOCK
'

network='
eBPF|BPF_SYSCALL
  JIT|BPF_JIT
  JIT always on|BPF_JIT_ALWAYS_ON
  unpriv bpf off|BPF_UNPRIV_DEFAULT_OFF
  CO-RE (BTF)|DEBUG_INFO_BTF
  cgroup attach|CGROUP_BPF
  tracing progs|BPF_EVENTS
  LSM progs|BPF_LSM
  tc classifier|NET_CLS_BPF
  AF_XDP|XDP_SOCKETS
  sockmap/sk_msg|BPF_STREAM_PARSER
  sock msg|NET_SOCK_MSG
TCP|INET
  BBR|TCP_CONG_BBR
  BBR default|DEFAULT_BBR
  fq qdisc|NET_SCH_FQ
  fq_codel|NET_SCH_FQ_CODEL
  socket diag|INET_DIAG
  busy poll|NET_RX_BUSY_POLL
  RPS|RPS
  RFS|RFS_ACCEL
  XPS|XPS
  MPTCP|MPTCP
kTLS offload|TLS
  NIC kTLS offload|TLS_DEVICE
  TLS toe|TLS_TOE
dataplane|NETDEVICES
  flow offload|NF_FLOW_TABLE
  switchdev|NET_SWITCHDEV
  page pool stats|PAGE_POOL_STATS
  devlink|NET_DEVLINK
  hw timestamping|NETWORK_PHY_TIMESTAMPING
  PTP|PTP_1588_CLOCK
'

memory='
HugeTLB|HUGETLBFS
  hugetlb pages|HUGETLB_PAGE
  vmemmap optimization|HUGETLB_PAGE_OPTIMIZE_VMEMMAP
  vmemmap opt ON by default|HUGETLB_PAGE_OPTIMIZE_VMEMMAP_DEFAULT_ON
  hugetlb cgroup|CGROUP_HUGETLB
THP|TRANSPARENT_HUGEPAGE
  madvise-only default|TRANSPARENT_HUGEPAGE_MADVISE
OOM containment|MEMCG
  pressure stall (PSI)|PSI
  psi enabled by default|!PSI_DEFAULT_DISABLED
  no swap to hide it|!SWAP
  no KSM cross-tenant|!KSM
memory failure|MEMORY_FAILURE
  corrected-error collector|RAS_CEC
  APEI memory failure|ACPI_APEI_MEMORY_FAILURE
  EDAC|EDAC
NUMA|NUMA
  ACPI NUMA|ACPI_NUMA
  balancing available|NUMA_BALANCING
  deferred page init|DEFERRED_STRUCT_PAGE_INIT
  sparse vmemmap|SPARSEMEM_VMEMMAP
allocator|COMPACTION
  migration|MIGRATION
  CMA (contig alloc)|CMA
  page shuffling|SHUFFLE_PAGE_ALLOCATOR
  init on alloc|INIT_ON_ALLOC_DEFAULT_ON
  init on free|INIT_ON_FREE_DEFAULT_ON
  freelist hardened|SLAB_FREELIST_HARDENED
  freelist randomized|SLAB_FREELIST_RANDOM
guest memory|USERFAULTFD
  memfd secret|SECRETMEM
  memory hotplug|MEMORY_HOTPLUG
  CXL bus|CXL_BUS
'

scheduling='
SMP|SMP
  max CPUs|NR_CPUS
  MAXSMP|MAXSMP
  SMT topology|SCHED_SMT
  MC topology|SCHED_MC
  cluster topology|SCHED_CLUSTER
  asym packing (P/E)|SCHED_MC_PRIO
  core scheduling|SCHED_CORE
preemption|PREEMPT_DYNAMIC
  lazy preempt|PREEMPT_LAZY
  tick rate|HZ
  full tickless|NO_HZ_FULL
  cpu isolation|CPU_ISOLATION
  rcu offload|RCU_NOCB_CPU
QoS|CGROUP_SCHED
  cpu.weight|FAIR_GROUP_SCHED
  cpu.max|CFS_BANDWIDTH
  util clamping|UCLAMP_TASK
  util clamp cgroup|UCLAMP_TASK_GROUP
  RT cgroup bandwidth|RT_GROUP_SCHED
  BPF schedulers (sched_ext)|SCHED_CLASS_EXT
  autogroup off|!SCHED_AUTOGROUP
accounting|SCHEDSTATS
  irq time|IRQ_TIME_ACCOUNTING
  virt cpu time|VIRT_CPU_ACCOUNTING_GEN
  delay accounting|TASK_DELAY_ACCT
  PSI|PSI
'

storage='
block layer|BLOCK
  multiqueue deadline|MQ_IOSCHED_DEADLINE
  writeback throttling|BLK_WBT
  data integrity|BLK_DEV_INTEGRITY
  io.cost|BLK_CGROUP_IOCOST
  io.latency|BLK_CGROUP_IOLATENCY
  zoned (ZNS)|BLK_DEV_ZONED
  SED/Opal|BLK_SED_OPAL
async IO|IO_URING
  POSIX aio|AIO
NVMe|BLK_DEV_NVME
  multipath|NVME_MULTIPATH
  fabrics|NVME_FABRICS
  TCP transport|NVME_TCP
  hwmon|NVME_HWMON
filesystems|EXT4_FS
  XFS|XFS_FS
  XFS online scrub|XFS_ONLINE_SCRUB
  XFS online repair|XFS_ONLINE_REPAIR
  Btrfs|BTRFS_FS
  overlayfs|OVERLAY_FS
  erofs|EROFS_FS
  squashfs|SQUASHFS
  FUSE|FUSE_FS
  DAX|FS_DAX
device mapper|BLK_DEV_DM
  dm-verity|DM_VERITY
  dm-crypt|DM_CRYPT
  dm-integrity|DM_INTEGRITY
'

case $CHECKLIST in
isolation) list=$isolation ;;
scheduling) list=$scheduling ;;
storage) list=$storage ;;
network) list=$network ;;
memory) list=$memory ;;
*) echo "unknown checklist: $CHECKLIST (have: isolation network memory scheduling storage)" >&2; exit 1 ;;
esac

profiles=""
for f in "$OUT"/*.config; do
	[ -e "$f" ] || continue
	profiles="$profiles $(basename "$f" .config)"
done
[ -n "$profiles" ] || { echo "no configs in $OUT -- run 'make validate-all' first" >&2; exit 1; }

printf '%-24s' "CAPABILITY"
for p in $profiles; do printf '%-14s' "$p"; done
printf '\n'
printf '%-24s' "------------------------"
for p in $profiles; do printf '%-14s' "-------------"; done
printf '\n'

echo "$list" | while IFS='|' read -r label sym; do
	[ -n "$label" ] || continue
	printf '%-24s' "$label"
	for p in $profiles; do
		case $sym in
		!*)  # capability is the ABSENCE of the symbol
			s=${sym#!}
			if grep -q "^CONFIG_$s=" "$OUT/$p.config" 2>/dev/null; then
				printf '%-14s' "no"
			else
				printf '%-14s' "yes"
			fi
			;;
		*)
			v=$(sed -n "s/^CONFIG_$sym=//p" "$OUT/$p.config" 2>/dev/null | head -1)
			case $v in
			y) printf '%-14s' "yes" ;;
			m) printf '%-14s' "module" ;;
			"") printf '%-14s' "-" ;;
			*) printf '%-14s' "$v" ;;
			esac
			;;
		esac
	done
	printf '\n'
done
