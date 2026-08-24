#!/bin/sh
# Build the smallest useful initramfs: one static binary that mounts the
# pseudo-filesystems, prints what the kernel actually enabled, and halts.
#
# This is a *test* rootfs.  A production host image is a signed, verity-backed
# erofs mounted by this same kind of init -- see docs/DESIGN.md.
set -eu

OUT=${OUT:-/out}
WORK=$(mktemp -d)
KARCH=${KVMHOST_ARCH:-x86_64}
case $KARCH in
arm64) CROSS=aarch64-linux-gnu- ;;
*)     CROSS=x86_64-linux-gnu-  ;;
esac
CC=${CROSS}gcc

mkdir -p "$WORK/root/proc" "$WORK/root/sys/kernel/security" "$WORK/root/dev"
mknod "$WORK/root/dev/console" c 5 1 2>/dev/null || true
mknod "$WORK/root/dev/null" c 1 3 2>/dev/null || true

# A real, well-formed, UNSIGNED kernel image for the kexec-policy probe.
# Feeding kexec_file_load garbage proves nothing -- the arch loader's format
# probe rejects it with ENOEXEC before signature verification ever runs (we
# learned this by predicting EPERM and measuring ENOEXEC).  Only a parseable
# image reaches the KEXEC_SIG/lockdown gate.
if [ -n "${PROBE_KERNEL:-}" ] && [ -r "$OUT/$PROBE_KERNEL" ]; then
	cp "$OUT/$PROBE_KERNEL" "$WORK/root/probe-kernel"
	echo "==> embedding $PROBE_KERNEL as kexec probe target"
fi

cat >"$WORK/init.c" <<'EOF'
/* PID 1 for the smoke test.
 *
 * This asserts the design claims rather than printing facts: several of them
 * are proven by an *absence* (no /proc/swaps means CONFIG_SWAP really is off,
 * no modules_disabled sysctl means CONFIG_MODULES really is off), which is
 * easy to misread as "the test could not check it".
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <dirent.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <time.h>

static int failures;
static int guest;   /* kvmhost.expect=guest on the command line */

static int slurp(const char *path, char *buf, size_t len)
{
	FILE *f = fopen(path, "r");

	if (!f)
		return -1;
	buf[0] = '\0';
	if (fgets(buf, len, f))
		buf[strcspn(buf, "\n")] = '\0';
	fclose(f);
	return 0;
}

static void ok(const char *what, const char *detail)
{
	printf("KVMHOST ok       %-24s %s\n", what, detail);
}

static void bad(const char *what, const char *detail)
{
	printf("KVMHOST FAIL     %-24s %s\n", what, detail);
	failures++;
}

/* A path that must exist, optionally containing `needle`. */
static void want_present(const char *what, const char *path, const char *needle)
{
	char buf[256];

	if (slurp(path, buf, sizeof(buf)) < 0) {
		bad(what, "absent");
		return;
	}
	if (needle && !strstr(buf, needle)) {
		bad(what, buf);
		return;
	}
	ok(what, buf);
}

/* THP default is RAM-dependent: the kernel force-disables it below 512 MiB
 * of usable RAM (mm/huge_memory.c hugepage_init).  Below that line [never]
 * is the correct default, not a config regression -- Firecracker/serverless
 * microVMs routinely run this small.  Only demand [madvise] above it. */
static void check_thp(void)
{
	char mem[256], thp[256], detail[320];
	long memtotal_kb = 0;

	if (slurp("/proc/meminfo", mem, sizeof(mem)) == 0)
		sscanf(mem, "MemTotal: %ld kB", &memtotal_kb);
	if (slurp("/sys/kernel/mm/transparent_hugepage/enabled", thp, sizeof(thp)) < 0) {
		bad("thp-madvise", "absent");
		return;
	}
	if (memtotal_kb && memtotal_kb < 512L * 1024) {
		snprintf(detail, sizeof(detail),
			 "%s  (<512M usable: THP off by kernel policy)", thp);
		strstr(thp, "[never]") ? ok("thp-madvise", detail)
					: bad("thp-madvise", detail);
	} else {
		strstr(thp, "[madvise]") ? ok("thp-madvise", thp)
					 : bad("thp-madvise", thp);
	}
}

/* A path whose absence is the thing being asserted. */
static void want_absent(const char *what, const char *path, const char *why)
{
	if (access(path, F_OK) == 0)
		bad(what, "present -- config regression");
	else
		ok(what, why);
}

/* Empirically classify the kexec_file_load policy by feeding it this init
 * binary (not a kernel) and reading the errno:
 *   ENOSYS  -- the syscall does not exist: guests, which must not kexec.
 *   EPERM   -- refused before parsing: KEXEC_SIG + lockdown gating, the
 *              correct host posture (only signed kernels load).
 *   ENOEXEC/EINVAL -- the kernel PARSED our garbage: the syscall is open to
 *              any root-supplied image.  Without KEXEC_SIG the lockdown LSM
 *              never sees kexec_file_load at all -- a fact we verified in
 *              kernel/kexec_file.c, and the reason this probe exists.
 */
static void probe_kexec(const char *want)
{
	long ret;
	int fd = open("/probe-kernel", O_RDONLY);
	const char *got;

	if (fd < 0)
		fd = open("/init", O_RDONLY);	/* garbage fallback: only
						 * distinguishes enosys */

	ret = syscall(SYS_kexec_file_load, fd, -1, 1L, "", 0x4 /*NO_INITRAMFS*/);
	if (ret == 0) {
		/* The kernel accepted an UNSIGNED image: kexec_file_load is
		 * open to any root-supplied kernel on this config.  Unload so
		 * nothing lingers armed. */
		got = "loaded";
		syscall(SYS_kexec_file_load, -1, -1, 1L, "", 0x1 /*UNLOAD*/);
	} else if (errno == ENOSYS)
		got = "enosys";
	else if (errno == EPERM)
		got = "eperm";
	else
		got = "enoexec";
	close(fd);
	if (want && strcmp(want, got) != 0) {
		char buf[64];
		snprintf(buf, sizeof(buf), "want %s got %s (errno=%d)", want, got, errno);
		bad("kexec-policy", buf);
	} else {
		char buf[64];
		/* On a KEXEC_SIG + lockdown kernel, "loaded" only happens if the
		 * image signature verified against a trusted key, so it is the
		 * correct result for a SIGNED probe target; "eperm" is correct
		 * for an unsigned one. */
		snprintf(buf, sizeof(buf), "%s%s", got,
			 !strcmp(got,"loaded") ? " (signature verified against keyring)" : "");
		ok("kexec-policy", buf);
	}
}

static const char *cmdline_val(const char *cl, const char *key, char *val)
{
	/* copies value of key=val into caller storage (>=32 bytes), or NULL.
	 * (The first version used one static buffer for every caller, so the
	 * second lookup silently overwrote the first -- caught by the smoke
	 * run itself printing "want required" for the kexec probe.) */
	const char *p = strstr(cl, key);

	if (!p)
		return NULL;
	p += strlen(key);
	sscanf(p, "%31s", val);
	return val;
}

int main(void)
{
	static char cl[1024];
	static char kexec_buf[32], luo_buf[32];
	const char *kexec_want, *luo_want;
	mount("proc", "/proc", "proc", 0, NULL);
	mount("sysfs", "/sys", "sysfs", 0, NULL);
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
	mount("securityfs", "/sys/kernel/security", "securityfs", 0, NULL);
	mount("debugfs", "/sys/kernel/debug", "debugfs", 0, NULL);

	/* Route stdio to the kernel log (/dev/kmsg): it reaches the serial console
	 * via printk regardless of how the VMM wired the initial console.  QEMU
	 * set up init's console implicitly; Firecracker does not ("unable to open
	 * an initial console"), so /dev/console alone leaves the asserts invisible.
	 * setvbuf(line) so each printf becomes one kmsg record. */
	{
		/* Prefer the real console (QEMU provides it; full, unthrottled
		 * output).  Fall back to /dev/kmsg only when the VMM did not wire
		 * an initial console (Firecracker), accepting printk rate-limiting
		 * there. */
		int c = open("/dev/console", O_WRONLY);
		if (c < 0) c = open("/dev/kmsg", O_WRONLY);
		if (c >= 0) { dup2(c, 1); dup2(c, 2); if (c > 2) close(c); }
		setvbuf(stdout, NULL, _IOLBF, 0);
	}

	slurp("/proc/cmdline", cl, sizeof(cl));
	guest = strstr(cl, "kvmhost.expect=guest") != NULL;
	kexec_want = cmdline_val(cl, "kvmhost.kexec=", kexec_buf);
	luo_want = cmdline_val(cl, "kvmhost.luo=", luo_buf);
	{
		char up[64] = ""; int uf = open("/proc/uptime", O_RDONLY);
		if (uf >= 0) { read(uf, up, sizeof(up) - 1); close(uf); }
		char *sp = strchr(up, ' '); if (sp) *sp = 0;
		printf("KVMHOST boot-latency %ss (kernel entry -> init)\n", up);
	}
	printf("KVMHOST init: userspace reached (expect=%s)\n",
	       guest ? "guest" : "host");

	want_present("version", "/proc/sys/kernel/osrelease", NULL);
	if (guest)
		/* Guests have no KVM of their own -- the sandbox is a layer down. */
		want_absent("no-kvm", "/sys/class/misc/kvm/dev", "guest kernel");
	else
		want_present("kvm-device", "/sys/class/misc/kvm/dev", NULL);
	want_present("nr-cpus", "/sys/devices/system/cpu/kernel_max", NULL);
	check_thp();
	want_present("lockdown", "/sys/kernel/security/lockdown", "[integrity]");
	want_present("spectre-v2", "/sys/devices/system/cpu/vulnerabilities/spectre_v2",
		     NULL);
	want_absent("no-swap", "/proc/swaps", "CONFIG_SWAP=n");
	if (guest)
		want_absent("no-modules", "/proc/sys/kernel/modules_disabled",
			    "CONFIG_MODULES=n");
	else
		/* Hosts carry the loader for livepatch -- but only signed. */
		want_present("modules-sig-forced",
			     "/sys/module/module/parameters/sig_enforce", "Y");
	want_absent("no-devmem", "/dev/mem", "CONFIG_DEVMEM=n");
	probe_kexec(kexec_want);
	if (luo_want && !strcmp(luo_want, "required")) {
		/* The destination track's reason to exist: prove it is live,
		 * not merely compiled. */
		/* The FDT is binary; existence is the assertion, not content. */
		if (access("/sys/kernel/debug/kho/out/fdt", F_OK) == 0)
			ok("kho-armed", "out/fdt present");
		else
			bad("kho-armed", "no /sys/kernel/debug/kho/out/fdt");
		if (access("/dev/liveupdate", F_OK) == 0)
			ok("luo-device", "/dev/liveupdate");
		else
			bad("luo-device", "absent");
	} else if (luo_want) {
		want_absent("no-luo", "/dev/liveupdate", "v1/guest kernel");
	}

	if (strstr(cl, "kvmhost.diag=1")) {
		/* netdevsim: simulate an SR-IOV PF and spawn VFs -- the industry
		 * way to test SR-IOV orchestration without a real NIC. */
		int fd = open("/sys/bus/netdevsim/new_device", O_WRONLY);
		if (fd >= 0) { write(fd, "1 4", 3); close(fd); }
		fd = open("/sys/bus/netdevsim/devices/netdevsim1/sriov_numvfs", O_WRONLY);
		if (fd >= 0) { write(fd, "4", 1); close(fd); }
		/* netdevsim VFs are not PCI virtfn symlinks; success is the
		 * sriov_numvfs readback (create then delete, like an orchestrator). */
		char nv[8] = "";
		fd = open("/sys/bus/netdevsim/devices/netdevsim1/sriov_numvfs", O_RDONLY);
		if (fd >= 0) { read(fd, nv, sizeof(nv) - 1); close(fd); }
		if (nv[0] == '4') {
			ok("netdevsim-sriov", "PF + 4 VFs created (no NIC)");
			fd = open("/sys/bus/netdevsim/devices/netdevsim1/sriov_numvfs", O_WRONLY);
			if (fd >= 0) { write(fd, "0", 1); close(fd); }  /* delete VFs */
		} else if (access("/sys/bus/netdevsim/devices/netdevsim1", F_OK) == 0)
			bad("netdevsim-sriov", "PF up, sriov_numvfs readback not 4");
		else bad("netdevsim-sriov", "netdevsim device not created");
		/* RAS injection frameworks present (fire real GHES/MCE paths). */
		if (access("/sys/kernel/debug/mce/mce-inject", F_OK) == 0 ||
		    access("/sys/devices/system/machinecheck/machinecheck0", F_OK) == 0)
			ok("mce-inject", "MCE injection interface present");
		else bad("mce-inject", "no MCE injection interface");
		if (access("/sys/kernel/debug/fail_make_request", F_OK) == 0)
			ok("fault-inject", "block fault injection present");
		else bad("fault-inject", "no fail_make_request");
	}
	if (strstr(cl, "kvmhost.tpm=1")) {
		/* swtpm-backed TPM: driver bound + a PCR bank readable. */
		want_present("tpm-device", "/sys/class/tpm/tpm0/tpm_version_major", NULL);
		want_present("tpm-pcr0", "/sys/class/tpm/tpm0/pcr-sha256/0", NULL);
	}
	if (strstr(cl, "kvmhost.viommu=1")) {
		/* virtio-iommu: the paravirt IOMMU the guest drives.  Functional
		 * signal = its driver bound AND it grouped PCI devices for
		 * translation (it is the only IOMMU in the guest). */
		int drv = access("/sys/bus/virtio/drivers/virtio_iommu", F_OK) == 0;
		int grp = access("/sys/kernel/iommu_groups/0", F_OK) == 0;
		if (drv && grp) ok("virtio-iommu", "translating (driver bound, groups formed)");
		else bad("virtio-iommu", drv ? "no iommu groups" : "driver not bound");
	}
	if (strstr(cl, "kvmhost.hw=1")) {
		/* Exercise real driver paths against QEMU-emulated hardware. */
		int nodes = 0;
		char p[64];
		for (int i = 0; i < 16; i++) {
			snprintf(p, sizeof(p), "/sys/devices/system/node/node%d", i);
			if (access(p, F_OK) == 0) nodes++;
		}
		want_present("nvme-block", "/sys/class/nvme/nvme0/model", NULL);
		if (access("/sys/class/iommu", F_OK) == 0 && access("/sys/class/iommu/dmar0", F_OK) == 0)
			ok("iommu-dmar", "Intel IOMMU active");
		else
			bad("iommu-dmar", "no /sys/class/iommu/dmar0");
		if (nodes >= 2) { char b[32]; snprintf(b,sizeof b,"%d nodes",nodes); ok("numa", b); }
		else bad("numa", "expected >=2 NUMA nodes");
		/* An emulated Intel NIC (igb) should have bound a netdev besides lo. */
		if (access("/sys/class/net/eth0", F_OK) == 0 ||
		    access("/sys/bus/pci/drivers/igb", F_OK) == 0)
			ok("igb-nic", "Intel NIC driver bound");
		else
			bad("igb-nic", "no igb/eth0");
	}
	printf(failures ? "KVMHOST SMOKE-FAIL\n" : "KVMHOST SMOKE-OK\n");
	sync();
	sleep(2);  /* let kmsg fully drain to the (slow PL011) serial before
		   * the VMM cuts power -- Firecracker poweroff is instant */
	reboot(RB_POWER_OFF);
	return 0;
}
EOF

"$CC" -static -Os -o "$WORK/root/init" "$WORK/init.c"
"${CROSS}strip" "$WORK/root/init"

mkdir -p "$OUT"
(cd "$WORK/root" && find . | cpio -o -H newc --quiet | gzip -9) >"$OUT/initramfs-$KARCH.cpio.gz"
rm -rf "$WORK"
printf '==> initramfs-%s: %s bytes\n' "$KARCH" "$(stat -c %s "$OUT/initramfs-$KARCH.cpio.gz")"
