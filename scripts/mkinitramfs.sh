#!/bin/sh
# Build the smallest useful initramfs: one static binary that mounts the
# pseudo-filesystems, prints what the kernel actually enabled, and halts.
#
# This is a *test* rootfs.  A production host image is a signed, verity-backed
# erofs mounted by this same kind of init -- see docs/DESIGN.md.
set -eu

OUT=${OUT:-/out}
WORK=$(mktemp -d)
CC=${CROSS_COMPILE:-x86_64-linux-gnu-}gcc

mkdir -p "$WORK/root/proc" "$WORK/root/sys/kernel/security" "$WORK/root/dev"

cat >"$WORK/init.c" <<'EOF'
/* PID 1 for the smoke test.
 *
 * This asserts the design claims rather than printing facts: several of them
 * are proven by an *absence* (no /proc/swaps means CONFIG_SWAP really is off,
 * no modules_disabled sysctl means CONFIG_MODULES really is off), which is
 * easy to misread as "the test could not check it".
 */
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
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

int main(void)
{
	mount("proc", "/proc", "proc", 0, NULL);
	mount("sysfs", "/sys", "sysfs", 0, NULL);
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
	mount("securityfs", "/sys/kernel/security", "securityfs", 0, NULL);

	{
		char cl[1024] = "";
		slurp("/proc/cmdline", cl, sizeof(cl));
		guest = strstr(cl, "kvmhost.expect=guest") != NULL;
	}
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

	printf(failures ? "KVMHOST SMOKE-FAIL\n" : "KVMHOST SMOKE-OK\n");
	sync();
	reboot(RB_POWER_OFF);
	return 0;
}
EOF

"$CC" -static -Os -o "$WORK/root/init" "$WORK/init.c"
"${CROSS_COMPILE:-x86_64-linux-gnu-}strip" "$WORK/root/init"

mkdir -p "$OUT"
(cd "$WORK/root" && find . | cpio -o -H newc --quiet | gzip -9) >"$OUT/initramfs.cpio.gz"
rm -rf "$WORK"
printf '==> initramfs: %s bytes\n' "$(stat -c %s "$OUT/initramfs.cpio.gz")"
