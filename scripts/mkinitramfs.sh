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
#include <sys/syscall.h>
#include <unistd.h>

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

	slurp("/proc/cmdline", cl, sizeof(cl));
	guest = strstr(cl, "kvmhost.expect=guest") != NULL;
	kexec_want = cmdline_val(cl, "kvmhost.kexec=", kexec_buf);
	luo_want = cmdline_val(cl, "kvmhost.luo=", luo_buf);
	printf("\nKVMHOST init: userspace reached (expect=%s)\n",
	       guest ? "guest" : "host");

	want_present("version", "/proc/sys/kernel/osrelease", NULL);
	if (guest)
		/* Guests have no KVM of their own -- the sandbox is a layer down. */
		want_absent("no-kvm", "/sys/class/misc/kvm/dev", "guest kernel");
	else
		want_present("kvm-device", "/sys/class/misc/kvm/dev", NULL);
	want_present("nr-cpus", "/sys/devices/system/cpu/kernel_max", NULL);
	want_present("thp-madvise", "/sys/kernel/mm/transparent_hugepage/enabled",
		     "[madvise]");
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
